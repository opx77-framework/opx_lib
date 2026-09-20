--- Covering the screen, and being certain the image comes back.
-- @author dop42
--
--   CreateThread(function()
--     local hidden = Lib.Screen.Black({ durationMs = 400, fadeInMs = 400 }, function()
--       moveThePlayerSomewhereElse()
--     end)
--     if not hidden.ok then print('no fade: ' .. hidden.error) end
--   end)
--
-- Wraps `Open77.screen.*`. The consumer must declare `screen.effects`.
--
-- THIS IS CYBERPUNK'S OWN QUEST FADE MANAGER, not an overlay. Nothing here
-- creates a WebUI layer, loads a quest, applies a status effect or touches
-- routing: it drives the engine's fade and reports what the engine says about
-- it. Completion comes from the native manager's own direction and remaining
-- duration rather than an estimated `Wait`, which is why the promises below
-- mean something.
--
-- A FADE NOBODY RETURNS IS INDISTINGUISHABLE FROM A CRASH to the player looking
-- at it, and the platform took that seriously enough to build a safety deadline
-- into every transition: `timeoutMs` is real time, the client enforces it, and
-- there is deliberately no "fade out forever" spelling of any of these calls.
-- So unlike the camera, the floor here is the platform's and not ours. What
-- `Screen.Black` adds on top is the same scope the camera's `Shot` adds: the
-- image is handed back on EVERY exit from the body -- a return, a raise, a
-- transition that ended underneath it -- rather than only when the deadline
-- finally expires, because fifteen seconds of black is a bug report either way.
--
-- THE SLOT IS SINGLE AND IT IS SHARED. Only one Open77 transition may be
-- active; a second request answers `screen_busy`. That one slot is shared with
-- the SERVER RELAY -- `Open77.players.fade` drives the same native through the
-- same arbitration -- so `screen_busy` is not necessarily another client
-- resource, and a server that faded this player is a perfectly ordinary cause.
-- A fade the GAME itself owns is a different answer again, `native_screen_busy`,
-- and Open77 will not clear it. Both refusals are rewritten here to say which.
--
-- WHICH IS WHY `IsFaded` EXISTS, and why it is the first call in a spawn or a
-- teleport. The screen may already be black because another resource faded it,
-- because the server did, or because a quest or loading fade took it, and
-- stacking a second fade on that is how a player ends up watching two fades in
-- a row. The platform is explicit that a wrong `false` is exactly what causes
-- that, so this reader fails to `true` -- see its own note.
--
-- OWNED AND UNOWNED READS ARE DIFFERENT QUESTIONS. `State` is about YOUR
-- transition and is scoped to this resource generation; `IsFaded` and
-- `NativeState` are about THE SCREEN and report a fade anybody put up. Reaching
-- for the first when you meant the second is how the two-fade bug gets written.
--
-- THE PROMISE IS A SECOND RETURN VALUE on `fadeOut`, `fadeIn` and `transition`,
-- so none of the three can go through `Native.Call` -- it keeps the first return
-- and drops the rest, the edge `client/native.lua` documents. They are reached
-- directly. ONE RULE, the same one `client/camera.lua` follows: the Result's
-- `value` is the native's FIRST return, untouched, and the promise rides on the
-- Result under a name that says what it settles on -- `covered`, `restored`,
-- `finished`. `IsFaded` is reached directly too, for the OTHER reason in
-- `native.lua`: its answer is legitimately `false`, and the falsy-means-refused
-- rule would turn "the screen is clear" into an error.
--
-- IDS ARE OPAQUE STRINGS. Not player ids, not native pointers, and not numbers:
-- another resource, another host or a reloaded generation cannot act on an old
-- one. Nothing here parses one, and a caller must not either.

local Native = require('@opx_lib/client.native')
local Validate = require('@opx_lib/pure.validate')
local Result = require('@opx_lib/pure.result')
local Colour = require('@opx_lib/pure.colour')
local Async = require('@opx_lib/client.async')

local Screen = {}

--- The manifest permission a consumer must declare to use this module.
---
--- There is no `UNGATED` list here and its absence is a claim, not an
--- oversight: all eight of the natives this module reaches are gated on
--- `screen.effects`, the unowned reads included. Reading whether the screen is
--- black is as privileged as making it black, which is a defensible line -- the
--- answer describes the player's whole view and not just this resource's corner
--- of it.
Screen.NEEDS = 'screen.effects'

--- The presets the catalogue currently contains. Exactly one.
---
--- Held statically so an unknown preset is refused WITHOUT a native call, and
--- so the refusal names the one that would have worked. `glitch` is the name
--- people try: it answers `unsupported_screen_preset` because the loading-screen
--- glitch has not been isolated safely, which is a different thing from a typo
--- and is why the door forwards it rather than pretending the name is unknown.
--- `Catalog()` is what THIS BUILD supports; this is what the door will accept.
Screen.PRESETS = { 'fade' }

--- The preset the platform documents as unsupported, and why the door lets it
--- through to the engine instead of rejecting it locally: the answer a caller
--- wants for `glitch` is the platform's own `unsupported_screen_preset`, which
--- says "not yet", and not "misspelled".
Screen.KNOWN = { 'fade', 'glitch' }

--- The platform's defaults, used for CHECKING and never sent.
---
--- The timeout rule below is cross-field -- a deadline has to exceed the
--- sequence it bounds -- so checking a `transition` that named only `holdMs`
--- needs to know what the other two will be. These are that knowledge. They are
--- not merged into what is sent: forwarding them would turn the engine's
--- default into this library's copy of it, and the copy is what goes stale.
Screen.DEFAULTS = { durationMs = 500, holdMs = 250, fadeInMs = 500 }

--- The bounds the reference gives, in integer milliseconds throughout.
Screen.MAX_FADE_MS = 10000
Screen.MAX_HOLD_MS = 30000
Screen.MIN_TIMEOUT_MS = 1000
Screen.MAX_TIMEOUT_MS = 60000

--- How far a safety deadline must exceed the sequence it bounds, in ms.
---
--- The platform's number, and the reason it is not zero: a deadline that
--- expires on the same tick the return fade completes is a coin toss between
--- `finished` and `timeout`, and a caller cannot write a branch against a coin.
Screen.TIMEOUT_MARGIN_MS = 500

--- The alpha the platform demands. Not a default -- the only accepted value.
--- A colour is a TINT on the engine's own fade, and a translucent one would be
--- a fade that does not fade.
Screen.ALPHA = 255

--- The phases a transition passes through, in order.
Screen.PHASES = {
	'fading_out', 'covered', 'fading_in', 'finished', 'cancelled', 'failed',
}

--- The three phases from which nothing more happens.
---
--- Read by `Screen.Over`, and the set is deliberately the TERMINAL ones rather
--- than the live ones -- see that function for why the difference decides what
--- an unrecognised phase from a newer build means.
Screen.TERMINAL = { finished = true, cancelled = true, failed = true }

--- Every documented reason a promise rejects, and what it means.
---
--- Data rather than prose because a rejection carries the token and nothing
--- else, and `never_covered` in particular is unreadable without this table:
--- it is OURS rather than the engine's, raised when a `fadeOut` returned the
--- image without ever reaching black. The engine calls that case `completed`,
--- which would read as success to a caller who was waiting to do something
--- invisible.
Screen.REASONS = {
	requested = 'something asked for it: a cancel, or a fadeIn that reversed the outgoing fade',
	timeout = 'the client\'s real-time safety deadline expired and gave the image back',
	native_interrupted = 'a vanilla game fade took priority; Open77 dropped ownership rather than fight it',
	world_unavailable = 'the world went away under the transition',
	restore_failed = 'a native restoration failed',
	resource_error = 'a coroutine in your resource errored, which releases its own fade',
	resource_stopped = 'your resource stopped or was reloaded',
	never_covered = 'the transition returned the image without ever reaching black -- the engine '
		.. 'reports that as completed, which would read as success',
}

-- Every bound above is the platform's, from the screen-transition options
-- table: durations 0..10000 ms, a hold 0..30000, a deadline 1000..60000 that
-- must clear the planned sequence by 500 ms, and integer colour channels whose
-- alpha must be 255. They are enforced at this door so a caller learns which of
-- THEIR numbers was wrong, rather than reading `invalid_screen_option:<key>`
-- back from the engine -- which names the key but not the rule it broke.

--- Integer milliseconds within a range, or nil.
---
--- `type(value) ~= 'number'` FIRST, and that line is the whole helper.
--- `Validate.Number` runs `tonumber`, so `'500'` off a config file or a WebUI
--- payload would pass a bare range check -- and the platform is explicit that
--- numeric strings are rejected, alongside NaN and infinity, which
--- `Validate.Integer` refuses underneath. Durations here are integer
--- milliseconds, never seconds and never fractions of one.
local function millis(value, low, high)
	if type(value) ~= 'number' then return nil end
	return Validate.Integer(value, low, high)
end

--- An RGBA colour the native will take, or nil.
---
--- ALPHA MUST BE 255 AND IS CHECKED AS AN EQUALITY, not a range: the platform
--- says so, and a caller who passed 128 meant a translucent fade, which this
--- API does not have. Refusing it by name beats sending it and watching the
--- engine pick something.
---
--- A `#RRGGBB` STRING IS ACCEPTED AND CONVERTED, exactly as `client/marker.lua`
--- accepts one and for the same reason: hex is how a colour arrives from a
--- config file or a WebUI, the conversion is `Lib.Colour.Parse` and therefore
--- strict, and the alternative is every consumer writing the same three
--- `tonumber(_, 16)` calls. What reaches the engine is integers either way, and
--- six hex digits carry no alpha, so the engine's own 255 stands.
---
--- OMITTED CHANNELS KEEP THEIR DEFAULTS, which is the platform's rule and the
--- reason a partial colour is not completed here. Note the engine controls how
--- a non-black colour renders: a tinted fade can keep a blurred scene rather
--- than produce a flat rectangle, so black is the only one that conceals the
--- 3D world. Nothing here can enforce that; it is said instead.
local function colour(value)
	if type(value) == 'string' then
		local parsed = Colour.Parse(value)
		if parsed == nil then return nil end
		return { r = parsed.r, g = parsed.g, b = parsed.b }
	end

	if Validate.Table(value, 8) == nil then return nil end

	local out = {}
	for _, key in ipairs({ 'r', 'g', 'b' }) do
		if value[key] ~= nil then
			local channel = Validate.Integer(value[key], 0, 255)
			if channel == nil then return nil end
			out[key] = channel
		end
	end

	if value.a ~= nil then
		if value.a ~= Screen.ALPHA then return nil end
		out.a = Screen.ALPHA
	end

	if next(out) == nil then return nil end
	return out
end

--- Validates one call's options and answers what to send, or a refusal.
---
--- One function behind all three calls, because they draw from one option
--- vocabulary and three copies of the same five bounds would disagree by the
--- third release. `allowed` is what THIS call takes, and it is the whole
--- difference between them: `fadeIn` takes a duration and nothing else, and
--- accepting `holdMs` there would be a hold nobody ever performs.
---
--- THE CODE IS THE PLATFORM'S OWN, `invalid_screen_option:<key>`, parameterised
--- exactly as the engine parameterises it, so a caller branching on a prefix
--- writes one branch whether the refusal came from this door or from behind it.
-- @return table|nil spec, string|nil code, string|nil detail
local function options(given, allowed, what)
	if given == nil then return {} end
	if Validate.Table(given, 8) == nil then
		return nil, 'invalid_screen_options', what .. ' options is not a plain table'
	end

	for key in pairs(given) do
		if not allowed[key] then
			local names = {}
			for name in pairs(allowed) do names[#names + 1] = name end
			table.sort(names)
			return nil, 'invalid_screen_option:' .. tostring(key),
				('%s takes %s; %q is not one of them'):format(
					what, table.concat(names, ', '), tostring(key))
		end
	end

	local spec = {}

	for _, key in ipairs({ 'durationMs', 'fadeInMs' }) do
		if allowed[key] and given[key] ~= nil then
			spec[key] = millis(given[key], 0, Screen.MAX_FADE_MS)
			if spec[key] == nil then
				return nil, 'invalid_screen_option:' .. key,
					('%s is a whole number of milliseconds, 0 to %d; zero is an instant cut, '
						.. 'and NaN, infinity and a numeric string are not numbers')
						:format(key, Screen.MAX_FADE_MS)
			end
		end
	end

	if allowed.holdMs and given.holdMs ~= nil then
		spec.holdMs = millis(given.holdMs, 0, Screen.MAX_HOLD_MS)
		if spec.holdMs == nil then
			return nil, 'invalid_screen_option:holdMs',
				('holdMs is a whole number of milliseconds, 0 to %d, and it starts after the '
					.. 'outgoing fade completes'):format(Screen.MAX_HOLD_MS)
		end
	end

	if allowed.timeoutMs and given.timeoutMs ~= nil then
		spec.timeoutMs = millis(given.timeoutMs, Screen.MIN_TIMEOUT_MS, Screen.MAX_TIMEOUT_MS)
		if spec.timeoutMs == nil then
			return nil, 'invalid_screen_option:timeoutMs',
				('timeoutMs is a whole number of milliseconds, %d to %d')
					:format(Screen.MIN_TIMEOUT_MS, Screen.MAX_TIMEOUT_MS)
		end
	end

	if allowed.color and given.color ~= nil then
		spec.color = colour(given.color)
		if spec.color == nil then
			return nil, 'invalid_screen_color', 'color is { r, g, b } bytes 0..255 or a '
				.. '"#RRGGBB" string, and an alpha, if given, must be exactly 255'
		end
	end

	-- ── cross-field: the deadline must clear the sequence ────────────────────
	-- The rule is the platform's and the arithmetic has to happen somewhere,
	-- because the engine answers `screen_timeout_too_short` without saying what
	-- the sequence added up to -- which is the only number a caller needs to
	-- fix it. Omitted durations take their documented defaults, so the sum is
	-- always knowable at this door.
	if spec.timeoutMs ~= nil then
		local planned = 0
		for _, key in ipairs({ 'durationMs', 'holdMs', 'fadeInMs' }) do
			if allowed[key] then
				planned = planned + (spec[key] or Screen.DEFAULTS[key])
			end
		end

		if spec.timeoutMs < planned + Screen.TIMEOUT_MARGIN_MS then
			return nil, 'screen_timeout_too_short',
				('timeoutMs %d must exceed the %d ms this call plans by at least %d ms')
					:format(spec.timeoutMs, planned, Screen.TIMEOUT_MARGIN_MS)
		end
	end

	return spec
end

--- An opaque transition id, checked without ever being interpreted.
---
--- The platform says these are opaque strings, so the only check worth making
--- is that it IS a string: a caller who ran the id through `tonumber` is
--- stopped here rather than reading `transition_not_found` back and concluding
--- their transition had ended.
local function idOf(value)
	return Validate.Text(value, 64)
end

--- Rewrites the two busy refusals into ones that say WHO is busy.
---
--- `screen_busy` and `native_screen_busy` are one word apart and mean entirely
--- different things to the caller: the first is an Open77 transition that may
--- well be the server's relay and will end, the second is the game's own fade
--- or loading screen, which Open77 deliberately does not clear. Telling them
--- apart decides whether retrying is sensible.
local function busy(failure)
	if failure.error == 'screen_busy' then
		failure.detail = 'the single Open77 transition slot is taken -- by another resource, or '
			.. 'by the server relay, which shares it. Open77.screen.isFaded() says whether the '
			.. 'screen is already black; if it is, you may not need a fade of your own'
	elseif failure.error == 'native_screen_busy' then
		failure.detail = 'the game itself owns a fade or a loading operation. Open77 does not '
			.. 'take that over and will not clear it afterwards; wait for it'
	end
	return failure
end

--- Calls a native that answers a value AND a promise, and packs both.
---
--- It cannot be `Native.Call`: that keeps the first return and drops the rest,
--- so the promise -- the only thing that says when the screen is actually
--- covered -- would vanish between the engine and the caller.
-- @return table a Result whose `value` is the first return, plus the promise
--         under `field`
local function reachWithPromise(path, field, ...)
	local native, missing = Native.Reach(path)
	if native == nil then
		return Result.Err(missing, ('Open77.%s is not available on this build'):format(path))
	end

	local held = table.pack(pcall(native, ...))
	if not held[1] then
		return Result.Err('native_raised', ('Open77.%s raised: %s'):format(path, tostring(held[2])))
	end

	local answer, second = held[2], held[3]
	if answer == nil or answer == false then
		return busy(Native.Refusal(path, Screen.NEEDS, second))
	end

	local made = Result.Ok(answer)
	if type(second) == 'table' then made[field] = second end
	return made
end

-- ── Covering ─────────────────────────────────────────────────────────────────

--- Fades the screen out and HOLDS it until this resource gives it back.
---
--- The Result's `value` is the opaque id, which `FadeIn` and `Cancel` need;
--- `.covered` is the promise, and it settles when the screen is actually black
--- on the engine's own timing. AN ID IS NOT A BLACK SCREEN: the call returns as
--- soon as the request is accepted, so anything that must happen unseen happens
--- after the promise, not after the call.
---
--- THE SAFETY DEADLINE IS NOT OPTIONAL. Whatever `timeoutMs` says, the client
--- gives the image back when it expires, and a `FadeIn` does not extend it.
--- That is the floor under every path through a caller's code, including the
--- ones nobody wrote.
-- @author dop42
-- @param spec table|nil durationMs, color, timeoutMs
-- @return table a Result carrying the id; `.covered` is the promise
function Screen.FadeOut(spec)
	local sent, code, detail = options(spec,
		{ durationMs = true, color = true, timeoutMs = true }, 'fadeOut')
	if sent == nil then return Result.Err(code, detail) end

	return reachWithPromise('screen.fadeOut', 'covered', sent)
end

--- Gives the image back for this resource's active transition.
---
--- Can reverse an outgoing fade: a caller who changed their mind mid-fade does
--- not have to wait for black first. `.restored` settles when the image is back.
--- `durationMs` and nothing else -- a hold or a colour here would be a value
--- that never gets used, which is worse than a refusal.
-- @author dop42
-- @param id string the id `FadeOut` or `Transition` answered
-- @param spec table|nil { durationMs }
-- @return table a Result; `.restored` is the promise
function Screen.FadeIn(id, spec)
	local transition = idOf(id)
	if transition == nil then
		return Result.Err('invalid_transition_id', 'a transition id is the opaque string the '
			.. 'fade answered; do not convert it')
	end

	local sent, code, detail = options(spec, { durationMs = true }, 'fadeIn')
	if sent == nil then return Result.Err(code, detail) end

	return reachWithPromise('screen.fadeIn', 'restored', transition, sent)
end

--- Runs the whole fade, hold and return sequence in one call.
---
--- For a scene change with nothing to do in the dark. When there IS something
--- to do in the dark, `Screen.Black` is the call: a hold is a fixed number of
--- milliseconds and a server round trip is not.
---
--- `.finished` settles when the sequence has finished, not when the screen
--- turns black.
-- @author dop42
-- @param preset string currently `fade`
-- @param spec table|nil durationMs, holdMs, fadeInMs, timeoutMs, color
-- @return table a Result carrying the id; `.finished` is the promise
function Screen.Transition(preset, spec)
	local named = Validate.OneOf(preset, Screen.KNOWN)
	if named == nil then
		return Result.Err('unsupported_screen_preset', ('screen preset %q is not one this '
			.. 'platform has; the catalogue currently contains: %s')
			:format(tostring(preset), table.concat(Screen.PRESETS, ', ')))
	end

	local sent, code, detail = options(spec, {
		durationMs = true, holdMs = true, fadeInMs = true,
		timeoutMs = true, color = true,
	}, 'transition')
	if sent == nil then return Result.Err(code, detail) end

	return reachWithPromise('screen.transition', 'finished', named, sent)
end

--- Restores the image immediately, including during the return fade.
---
--- Terminal the moment it returns, so it carries no promise: there is nothing
--- left to wait for.
-- @author dop42
-- @param id string
-- @return table a Result
function Screen.Cancel(id)
	local transition = idOf(id)
	if transition == nil then
		return Result.Err('invalid_transition_id', 'a transition id is an opaque string')
	end
	return Native.Call('screen.cancel', Screen.NEEDS, transition)
end

-- ── Waiting ──────────────────────────────────────────────────────────────────

--- Waits for a fade to settle, and says why if it ended some other way.
---
--- MUST RUN INSIDE A `CreateThread`: it suspends. A nil promise answers Ok, so
--- a caller need not branch on whether the call they made hands one back.
---
--- A REJECTION IS NOT A BUG IN THE CALLER'S CODE. It is one of the documented
--- endings -- cancelled, timed out, a vanilla fade taking over, the resource
--- stopping -- and `Screen.REASONS` turns the token into the sentence while the
--- token stays as the Result's code so a caller can still branch on it. The
--- platform rejects rather than leaving a promise pending precisely so the
--- coroutine that was going to call `FadeIn` wakes up instead of parking
--- forever.
-- @author dop42
-- @param promise table|nil `.covered`, `.restored` or `.finished`
-- @return table a Result carrying the state table
function Screen.Await(promise)
	if promise == nil then return Result.Ok(nil) end

	local settled = Async.All({ promise })
	if settled.ok then return Result.Ok(settled.value[1]) end

	return Result.Err(settled.error, Screen.Why(settled.error))
end

--- What a rejection token means, as a sentence.
---
--- An unknown token is passed through rather than guessed at: a newer build may
--- end a transition for a reason this library has never heard of.
-- @author dop42
-- @param reason any
-- @return string
function Screen.Why(reason)
	local token = type(reason) == 'string' and reason or 'unknown'
	return Screen.REASONS[token] or ('the transition ended: ' .. token)
end

--- Covers the screen, runs `body`, and gives the image back whatever happens.
---
--- THE GUARANTEE. When `Black` returns, the image is coming back or is already
--- back: the return fade is issued on every exit from `body` -- a return, a
--- raise, or a transition that ended underneath it -- and awaited. The
--- platform's safety deadline remains the floor beneath that, which is what
--- makes the pair sound: this call removes the fifteen-second stare, and the
--- deadline covers the case where this call never gets to run at all.
---
--- IT DOES NOT CHECK `IsFaded` FOR YOU, deliberately. Whether an already-black
--- screen means "skip my fade" or "fade anyway" is the caller's decision and
--- depends on what put it there; guessing would be this library writing policy.
--- If the slot is taken the refusal is `screen_busy` and says so.
---
--- MUST RUN INSIDE A `CreateThread`: it awaits both halves.
---
--- A RAISE IN `body` BECOMES A RESULT, `screen_body_raised`, rather than an
--- unwind -- for the same reason the camera's `Shot` catches one: letting it
--- propagate after the image was restored is the ordering that loses the error
--- and keeps the symptom. `.restored` says whether the return was accepted.
-- @author dop42
-- @param spec table|nil durationMs, color, timeoutMs, fadeInMs
-- @param body function run while the screen is covered
-- @return table a Result carrying whatever `body` answered
function Screen.Black(spec, body)
	if type(spec) == 'function' and body == nil then
		spec, body = nil, spec
	end
	if type(body) ~= 'function' then
		return Result.Err('invalid_body', 'Black runs a function while the screen is covered')
	end

	local back
	if spec ~= nil then
		if Validate.Table(spec, 8) == nil then
			return Result.Err('invalid_screen_options', 'Black options is not a plain table')
		end
		-- `fadeInMs` belongs to the RETURN and is not a `fadeOut` option, so it
		-- is lifted out here rather than forwarded and refused.
		back = spec.fadeInMs
		if back ~= nil then
			local copy = {}
			for key, value in pairs(spec) do
				if key ~= 'fadeInMs' then copy[key] = value end
			end
			spec = copy
		end
	end

	local out = Screen.FadeOut(spec)
	if not out.ok then return out end

	-- Hands the image back and waits for it to land. Tolerant on purpose: the
	-- transition may already be over, which is the outcome we wanted anyway.
	local function restore()
		local given = Screen.FadeIn(out.value, back ~= nil and { durationMs = back } or nil)
		if not given.ok then
			return given.error == 'transition_not_active'
				or given.error == 'transition_not_found'
				or given.error == 'already_fading_in'
		end
		Screen.Await(given.restored)
		return true
	end

	local covered = Screen.Await(out.covered)
	if not covered.ok then
		-- The screen never went black. `body` is NOT run: it was written to
		-- happen unseen, and running it now would run it in plain view.
		local failed = Result.Err(covered.error, covered.detail)
		failed.restored = restore()
		return failed
	end

	local ran, answered = pcall(body)
	local restored = restore()

	local done = ran and Result.Ok(answered)
		or Result.Err('screen_body_raised', tostring(answered))
	done.restored = restored
	return done
end

-- ── Reading ──────────────────────────────────────────────────────────────────

--- Is the screen covered right now, whoever covered it?
---
--- UNOWNED: true for a fade this resource put up, one another resource put up,
--- one the server relay put up, and a vanilla quest or loading fade. That is
--- the whole point of it -- the question before a spawn or a teleport is about
--- the screen, not about your transition.
---
--- A PLAIN BOOLEAN AND NOT A RESULT, on the argument `client/input.lua` makes
--- for its readers: this is asked on a decision path, once per spawn, and the
--- caller's next line is an `if`.
---
--- IT FAILS TO `true`, AND THAT IS THE ENTIRE DESIGN OF THE FUNCTION. The
--- native answers `nil, reason` rather than a confident `false` when the
--- guarded backend is unavailable, precisely because the platform's own note
--- says a wrong `false` here is what stacks two fades on one player. Collapsing
--- that `nil` to `false` would reintroduce the bug the native was shaped to
--- avoid, so it collapses to `true`: the cost of a wrong `true` is one fade
--- skipped on a host where fades do not work anyway, and the cost of a wrong
--- `false` is the player watching two. A caller who must tell "black" from
--- "could not tell" asks `NativeState`, which keeps the distinction.
-- @author dop42
-- @return boolean
function Screen.IsFaded()
	-- Reached directly: `false` is a real answer here -- the screen is clear --
	-- and `Native.Call`'s falsy-means-refused rule would turn it into an error.
	-- The same edge `Open77.zones.contains` meets in `client/zone.lua`.
	local native = Native.Reach('screen.isFaded')
	if native == nil then return true end

	local read, faded = pcall(native)
	if not read then return true end
	if faded == nil then return true end
	return faded == true
end

--- The engine's own fade state: faded, fading, out, busy, ready, remainingMs.
---
--- The detailed form of `IsFaded`, and a Result rather than a plain value
--- because the distinction `IsFaded` gives up -- "could not tell" against "not
--- black" -- is exactly what a caller comes here for. `fading` separates *on
--- its way to black* from *already black*, so a caller that must not interrupt
--- an incoming fade can wait for it instead of racing it.
---
--- Engine truth, not an estimate. It is still not a GPU presentation fence and
--- not proof that streaming has finished.
-- @author dop42
-- @return table a Result carrying the state
function Screen.NativeState()
	return Native.Call('screen.nativeState', Screen.NEEDS)
end

--- This resource generation's own transition, with `over` added.
---
--- OWNER-SCOPED, and that is the difference from the two readers above: it
--- answers for your transition and nothing else. A stale id from a previous
--- generation is not yours and does not resolve. Terminal history is bounded to
--- 64 entries across the whole client and is dropped when a resource stops, so
--- a read of a long-finished transition can legitimately answer nothing.
---
--- The snapshot is ANNOTATED, not rebuilt, so a newer build's extra fields
--- survive.
-- @author dop42
-- @param id string
-- @return table a Result carrying the snapshot
function Screen.State(id)
	local transition = idOf(id)
	if transition == nil then
		return Result.Err('invalid_transition_id', 'a transition id is an opaque string')
	end

	local read = Native.Call('screen.state', Screen.NEEDS, transition)
	if not read.ok then return read end
	if type(read.value) == 'table' then read.value.over = Screen.Over(read.value) end
	return read
end

--- Is this transition finished with, so the id can be dropped?
---
--- The question a caller holding an id actually has: the platform's own worked
--- example clears its stored id on `finished`, `cancelled` and `failed` and
--- keeps it on everything else, and this is that rule in one place instead of
--- three event handlers.
---
--- A plain boolean, over a snapshot the caller already holds: it cannot fail.
---
--- IT TESTS THE TERMINAL SET, NOT THE LIVE ONE, and the direction matters. A
--- phase this library has never heard of -- a newer build's -- reads as NOT
--- over, so a caller keeps the id and still calls `FadeIn`. The other way round,
--- an unrecognised phase would look terminal, the caller would drop the id, and
--- nobody would ever hand the image back. One of those errors is a redundant
--- call and the other is a black screen.
-- @author dop42
-- @param snap table a snapshot from `State`, or an event's state table
-- @return boolean
function Screen.Over(snap)
	if type(snap) ~= 'table' then return false end
	return Screen.TERMINAL[snap.phase] == true
end

--- The presets this BUILD supports, and whether each backend is available.
---
--- Answers the platform and not the static `Screen.PRESETS`, deliberately: the
--- native is newer than some builds this library runs on, and falling back to
--- the static list would claim `fade` works on a build that has none of this.
--- `available` verifies the guarded native entry on this executable -- not that
--- a world is ready, and not that the slot is free.
-- @author dop42
-- @return table a Result carrying the catalogue
function Screen.Catalog()
	return Native.Call('screen.catalog', Screen.NEEDS)
end

return Screen
