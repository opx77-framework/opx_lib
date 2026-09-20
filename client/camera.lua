--- Taking the player's view, and being certain they get it back.
-- @author dop42
--
--   CreateThread(function()
--     local cam = Lib.Camera.Create({ position = corner, lookAt = 0, fov = 32 })
--     if not cam.ok then return end
--
--     -- The view is taken, the body runs, and the view is GIVEN BACK, whether
--     -- the body returns, raises, or the platform pulls the shot out from
--     -- under it.
--     local shot = Lib.Camera.Shot(cam.value, { blendMs = 600 }, function()
--       openCreatorUi()
--       Wait(8000)
--     end)
--     if not shot.ok then print('no shot: ' .. shot.error) end
--
--     Lib.Camera.Destroy(cam.value)
--   end)
--
-- Wraps `Open77.camera.*`. The consumer must declare `camera.script`.
--
-- A STUCK CAMERA IS INDISTINGUISHABLE FROM A CRASH, which is the sentence the
-- platform's own release rules open with and the reason this module exists.
-- Every other refusal here costs a caller a shot; this one costs a player their
-- session.
--
-- WHAT THE PLATFORM ALREADY GUARANTEES, and it is most of it. The view comes
-- back by itself on the next frame when the resource stops or reloads, when an
-- uncaught coroutine error kills the generation, when the player dies or their
-- body goes unreadable, when the world unloads, when the client shuts down,
-- when the held camera is destroyed, and when a different camera of your own is
-- activated. None of that is opt-in and none of it is this library's to
-- reimplement. `Camera.RELEASES` writes the list down so a rejected promise can
-- be turned into a sentence instead of a token.
--
-- WHAT IT DOES NOT COVER, AND WHAT `Shot` ADDS. Every rule above fires on a
-- generation that has ALREADY failed or gone away. A caller that is still very
-- much alive is not covered at all: a `pcall`-caught error, an early `return`
-- down a branch nobody tested, a UI that closes by a path that forgets the
-- hand-back. Those leave a live resource holding the view and a player looking
-- at a wall with nothing in the log. `Shot` is the scope that closes them: it
-- takes the view, runs a body under `pcall`, and hands the view back on every
-- exit, then waits for the hand-back blend to land before it returns. When
-- `Shot` returns, the player has their own view back.
--
-- It is not magic and it is not a substitute for the platform's rules: a body
-- that suspends forever never returns, so `Shot` never returns either, and the
-- release then comes from the platform when the resource stops. That is the
-- honest boundary. A caller who will not use `Shot` should at least treat every
-- early return as a `Release`.
--
-- THE PROMISE IS A SECOND RETURN VALUE, so `activate`, `deactivate`, `follow`
-- and `unfollow` cannot go through `Native.Call` -- it keeps the first return
-- and drops the rest, which is the edge `client/native.lua` documents and
-- `client/character.lua` already meets from the other side. They are reached
-- directly with `Native.Reach`. ONE RULE covers every one of them: the Result's
-- `value` is the native's FIRST return, exactly as the platform gives it, and
-- the promise rides on the Result under `blend`. A cut carries no promise
-- because a cut is already finished -- `blend` is then nil, and `Camera.Await`
-- answers Ok for a nil promise so a caller need not branch on which they got.
--
-- ONE VIEW, AND A REFUSAL THAT NAMES WHO HAS IT. A second resource asking for
-- the view is refused rather than served, because two resources each believing
-- they are driving is worse than one of them not getting the shot. The refusal
-- carries `camera_held_by:<resource>`, and where it does not -- the bare
-- `camera_held` -- this module asks `cameras()` and names the holder anyway.
-- `Camera.Holder()` is the same question asked before the attempt.
--
-- THE CAMERA IS A CHILD OF THE BODY. 2.31 has no creatable camera object, so
-- what a world position really does is drive the player's own camera component
-- through a per-frame conversion. If the body goes, the camera goes -- which is
-- why a death is a release and not a pause -- and the world streams around the
-- BODY, not the lens, which is why `activate` refuses a camera more than
-- `Camera.RANGE` metres away rather than handing back a grey frame.
--
-- ONE DISAGREEMENT IN THE SOURCES, LEFT VISIBLE. The reference for `cameras()`
-- says `holder` alone is not owner-scoped, which reads as "`held` is true only
-- for you"; the devkit's own example for the same native tests
-- `cams.held and cams.holder ~= <me>`, which reads as "`held` is true for
-- anybody". They cannot both be right and no game was available to settle it,
-- so `Camera.State` decides on `holder` -- a NAME, unambiguous under either
-- reading -- and falls back to `held` only when there is no name to compare.

local Native = require('@opx_lib/client.native')
local Validate = require('@opx_lib/pure.validate')
local Result = require('@opx_lib/pure.result')
local Async = require('@opx_lib/client.async')

local Camera = {}

--- The manifest permission a consumer must declare to use this module.
---
--- THE MAXIMUM AND NOT THE MINIMUM, for the reason `client/marker.lua` sets
--- out: `NEEDS` is one string, `Permission.Of` reads exactly that field, and a
--- consumer who declares a permission they never exercise loses nothing while
--- one who is never told loses the shot. `Ray` and `Owner` are gated on nothing
--- and are listed in `UNGATED`; they pass `nil` to `Native.Call` so a refusal
--- from one is never rewritten into "add camera.script", which would fix
--- nothing.
Camera.NEEDS = 'camera.script'

--- The functions in this module that need no permission.
Camera.UNGATED = { 'Ray', 'Owner' }

--- Camera definitions one resource may hold at once. The platform's number.
---
--- Not pre-checked. Counting would cost a `cameras()` call on every create and
--- the count would still be a guess by the time the create landed; the engine
--- enforces it exactly and `Create` only rewrites the refusal into one that
--- says what the numbers are.
Camera.LIMIT = 16

--- Camera definitions the WHOLE CLIENT may hold, shared with every other
--- resource. The limit a consumer cannot reason about locally: a resource well
--- inside its own 16 can still be refused because of somebody else's cameras.
Camera.CLIENT_LIMIT = 64

--- How far from the player a camera may be activated, in metres.
---
--- The platform's number, and the reason for it is not politeness: the world
--- streams around the player's body, so a camera parked further away renders
--- whatever is streamed for the BODY -- missing geometry, missing NPCs,
--- unloaded interiors. `activate` refuses past this so the failure is a named
--- refusal rather than a grey frame. Not pre-checked here, because the check
--- needs the camera's live position and the player's, and an attached camera
--- has neither until the engine resolves it; the refusal is rewritten instead.
Camera.RANGE = 250

--- The field of view the platform accepts, in degrees. `0` is also accepted and
--- means "leave the engine's own field of view alone", which is not the same as
--- 5 degrees and is why the bound is not simply 0..170.
Camera.MIN_FOV = 5
Camera.MAX_FOV = 170

--- The longest blend the platform accepts, in milliseconds. Sixty seconds.
Camera.MAX_BLEND = 60000

--- The four shake presets, in the platform's own order. An unknown name is
--- refused by the engine rather than defaulted, so it is refused here too --
--- one native call earlier, and naming the four that would have worked.
Camera.SHAKES = { 'hand', 'drunk', 'explosion', 'earthquake' }

--- The platform's cap on shake amplitude, and the duration it uses when none is
--- given. Documented, never filled in: a default this module sent would be a
--- library value masquerading as the engine's, and the two would drift.
Camera.MAX_AMPLITUDE = 4.0
Camera.SHAKE_MS = 500

--- The phases `cameras()` reports, in the order a shot passes through them.
Camera.PHASES = { 'idle', 'blending_in', 'holding', 'blending_out' }

--- Follow-camera offsets, in the TARGET's own frame. The platform's ranges.
Camera.FOLLOW = {
	distance = { 0, 100 },
	height = { -50, 50 },
	side = { -50, 50 },
}

--- Every documented reason a held view is released, and what it means.
---
--- This is the release-rules table, written down. It is data rather than prose
--- because it has a job: a rejected blend promise carries one of these tokens
--- and nothing else, and a caller reading `resource_error` in a log has no way
--- to know that their camera DEFINITIONS went with it and must be re-created.
--- Where the platform lists stop and reload separately they share a token, so
--- they share an entry.
---
--- A token that is not here is not an error: a newer build may add one, and
--- `Camera.Why` passes an unknown token through rather than claiming to know.
Camera.RELEASES = {
	resource_stopped = 'your resource stopped or was reloaded; the new generation starts with nothing',
	resource_error = 'a coroutine in your resource errored -- your camera definitions went with it, '
		.. 'so re-create them before putting the shot back up',
	player_died = 'the player died; the definition survives, so one activate puts the shot back',
	player_unavailable = 'the player\'s body was unreadable for about half a second',
	world_exit = 'the world unloaded, the player disconnected, or the session ended',
	client_shutdown = 'the client shut down',
	camera_destroyed = 'the camera being looked through was destroyed',
	camera_superseded = 'a different camera of yours was activated',
	camera_deactivated = 'the view was given back',
}

-- Every bound above is the platform's, from the scripted-camera reference: 16
-- cameras a resource and 64 a client, 250 m of streaming range, a field of view
-- of 5..170 degrees, a blend of 0..60000 ms, an amplitude capped at 4.0, and
-- the three follow offsets. They are enforced at this door so that a caller
-- learns which of THEIR numbers was out of range, rather than reading a token
-- back from the engine -- which answers `invalid_argument` for the streaming
-- range and for a non-finite field of view alike and so cannot tell them apart.

--- A finite { x, y, z }, or nil. Rebuilt rather than passed through, so a
--- caller's table cannot be mutated behind them and no extra key rides along.
local function point(value)
	if Validate.Table(value, 8) == nil then return nil end
	local x = Validate.Number(value.x, -100000, 100000)
	local y = Validate.Number(value.y, -100000, 100000)
	local z = Validate.Number(value.z, -100000, 100000)
	if x == nil or y == nil or z == nil then return nil end
	return { x = x, y = y, z = z }
end

--- A camera id, or nil.
---
--- A NUMBER AND NOT A STRING, unlike a marker or a blip handle: these are small
--- per-resource ids -- sixteen of them at most -- and the platform types the
--- argument as a number. `tostring(camId)` is therefore a caller error and is
--- refused here rather than at the engine, where it reads as `invalid_camera_id`
--- with no hint that the value merely had the wrong type.
local function camOf(value)
	if type(value) ~= 'number' then return nil end
	return Validate.Integer(value, 1, nil)
end

--- An entity id, or nil. `0` is the local player's own body and is valid.
local function entityOf(value)
	if type(value) ~= 'number' then return nil end
	return Validate.Integer(value, 0, nil)
end

--- Integer milliseconds within a range, or nil.
---
--- `type(value) ~= 'number'` FIRST, and that line is the point of the helper.
--- `Validate.Number` runs `tonumber`, so `'600'` off a config file or a WebUI
--- payload would pass a bare range check -- and the platform's own word for a
--- blend is "not a number in 0..60000". A numeric string is not a number. NaN,
--- infinity and a fractional millisecond are refused by `Validate.Integer`
--- underneath, which is the whole reason to go through it.
local function millis(value, high)
	if type(value) ~= 'number' then return nil end
	return Validate.Integer(value, 0, high)
end

--- A rotation the native will take: a quaternion or Euler degrees, or nil.
---
--- WHICH ONE IS DECIDED BY `w`, because that is the only field the two forms do
--- not share. A quaternion needs all four components -- three of them is not a
--- rotation, it is a typo. Euler takes any subset of pitch, yaw and roll, which
--- is what the reference says, and no range: they are DEGREES and the engine
--- wraps them, so refusing 450 would be this module inventing a rule.
--- Finiteness is still checked, because a NaN angle is a shot that silently
--- points nowhere.
local function rotation(value)
	if Validate.Table(value, 8) == nil then return nil end

	if value.w ~= nil then
		local out = {}
		for _, key in ipairs({ 'x', 'y', 'z', 'w' }) do
			local number = Validate.Number(value[key], -100000, 100000)
			if number == nil then return nil end
			out[key] = number
		end
		return out
	end

	local out, named = {}, false
	for _, key in ipairs({ 'pitch', 'yaw', 'roll' }) do
		if value[key] ~= nil then
			local number = Validate.Number(value[key], -100000, 100000)
			if number == nil then return nil end
			out[key] = number
			named = true
		end
	end
	if not named then return nil end
	return out
end

--- A field of view the native will take, or nil. `0` passes through untouched:
--- it is the documented way to say "leave the engine's own alone".
local function fov(value)
	if type(value) ~= 'number' then return nil end
	if value == 0 then return 0 end
	return Validate.Number(value, Camera.MIN_FOV, Camera.MAX_FOV)
end

--- Every field `create` accepts. The set is closed on purpose: a misspelled
--- one -- `lookat`, `attach`, `offsets` -- is otherwise accepted by the engine,
--- ignored, and produces a shot that is subtly not the one that was asked for,
--- with no refusal anywhere.
local CREATE_FIELDS = {
	position = true, attachTo = true, offset = true,
	lookAt = true, rotation = true, fov = true,
}

--- Every field the table form of `setTransform` accepts.
local MOVE_FIELDS = { position = true, rotation = true, fov = true }

--- Validates a camera definition and answers the spec to send, or a refusal.
---
--- One function behind `Create` and `Move`, because the platform uses one field
--- vocabulary for both and two copies of the same six bounds would disagree by
--- the third release. `creating` decides two things: which fields are allowed,
--- and whether the definition must say where the camera is at all.
---
--- THE CODES REUSE THE PLATFORM'S OWN WORDS -- `invalid_camera_options`,
--- `invalid_camera_position`, `invalid_camera_offset`, `invalid_camera_look_at`,
--- `invalid_camera_rotation`, `invalid_camera_fov`, `invalid_entity_id`,
--- `empty_camera_transform` -- so a caller branching on a code writes one branch
--- whether the refusal came from this door or from the engine behind it.
-- @return table|nil spec, string|nil code, string|nil detail
local function definition(given, creating)
	local allowed = creating and CREATE_FIELDS or MOVE_FIELDS

	if Validate.Table(given, 16) == nil then
		return nil, 'invalid_camera_options', 'a camera definition is a plain table'
	end

	for key in pairs(given) do
		if not allowed[key] then
			return nil, 'invalid_camera_options',
				('camera field %q is not one this call takes'):format(tostring(key))
		end
	end

	local spec = {}

	if given.position ~= nil then
		spec.position = point(given.position)
		if spec.position == nil then
			return nil, 'invalid_camera_position', 'position is not a finite { x, y, z }'
		end
	end

	if creating then
		if given.attachTo ~= nil then
			spec.attachTo = entityOf(given.attachTo)
			if spec.attachTo == nil then
				return nil, 'invalid_entity_id',
					'attachTo is an entity id; 0 is the local player\'s own body'
			end
		end

		if given.offset ~= nil then
			spec.offset = point(given.offset)
			if spec.offset == nil then
				return nil, 'invalid_camera_offset',
					'offset is a finite { x, y, z } in the parent\'s frame (X right, Y forward, Z up)'
			end
		end

		-- A camera with neither is a camera with no pose at all. The platform
		-- states the rule as "position is required unless attachTo is given",
		-- and a definition that satisfies neither half never reaches it.
		if spec.position == nil and spec.attachTo == nil then
			return nil, 'invalid_camera_position',
				'a camera needs a world position, or an attachTo to hang off'
		end

		if given.lookAt ~= nil then
			if type(given.lookAt) == 'number' then
				-- A number is an ENTITY, and 0 is the local player. This is the
				-- one field where the two readings are both legal, so the type
				-- decides and a bad number is named as the entity it meant to be.
				spec.lookAt = entityOf(given.lookAt)
				if spec.lookAt == nil then
					return nil, 'invalid_entity_id',
						'a numeric lookAt is an entity id; 0 is the local player'
				end
			else
				spec.lookAt = point(given.lookAt)
				if spec.lookAt == nil then
					return nil, 'invalid_camera_look_at',
						'lookAt is a finite { x, y, z } world point, or an entity id'
				end
			end
		end
	end

	if given.rotation ~= nil then
		spec.rotation = rotation(given.rotation)
		if spec.rotation == nil then
			return nil, 'invalid_camera_rotation',
				'rotation is a quaternion { x, y, z, w } or Euler degrees { pitch, yaw, roll }'
		end
	end

	if given.fov ~= nil then
		spec.fov = fov(given.fov)
		if spec.fov == nil then
			return nil, 'invalid_camera_fov', ('fov is %d to %d degrees, or 0 to leave the '
				.. 'engine\'s own alone'):format(Camera.MIN_FOV, Camera.MAX_FOV)
		end
	end

	-- A rotation and a lookAt in one definition are two aims, and the engine
	-- resolves it by having the rotation clear the look-at. Accepting both here
	-- and letting one win silently is exactly the trap the platform avoided by
	-- documenting that behaviour, so the pair is refused and the caller picks.
	if spec.rotation ~= nil and spec.lookAt ~= nil then
		return nil, 'invalid_camera_rotation',
			'a rotation and a lookAt are two different aims; setting a rotation clears a '
			.. 'look-at, so name one'
	end

	return spec
end

--- The blend options a call takes, or a refusal.
local function blend(options, what)
	if options == nil then return {} end
	if Validate.Table(options, 8) == nil then
		return nil, 'invalid_camera_options', what .. ' options is not a plain table'
	end
	for key in pairs(options) do
		if key ~= 'blendMs' then
			return nil, 'invalid_camera_options',
				('%s takes blendMs and nothing else; %q is not a field it has')
					:format(what, tostring(key))
		end
	end
	if options.blendMs == nil then return {} end

	local ms = millis(options.blendMs, Camera.MAX_BLEND)
	if ms == nil then
		return nil, 'invalid_blend_ms', ('blendMs is a whole number of milliseconds, 0 to %d; '
			.. 'NaN, infinity and a numeric string are not numbers')
			:format(Camera.MAX_BLEND)
	end
	return { blendMs = ms }
end

--- Calls a native that answers a value AND a promise, and packs both.
---
--- The shape every promise-carrying call in this module goes through. It cannot
--- be `Native.Call`: that keeps the first return and drops the rest, so the
--- promise -- the only thing that says when the shot is actually up -- would
--- vanish between the engine and the caller.
-- @return table a Result whose `value` is the first return and whose `blend`
--         is the promise, or nil for a cut
local function reachWithPromise(path, ...)
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
		-- `second` is the reason on a refusal and the promise on an answer. The
		-- two never overlap, because a refusal has no promise to give.
		return Native.Refusal(path, Camera.NEEDS, second)
	end

	local made = Result.Ok(answer)
	if type(second) == 'table' then made.blend = second end
	return made
end

--- Names the resource that holds the view, in a refusal that only hinted at it.
---
--- `camera_held_by:<resource>` already carries the answer and is passed through
--- with the name lifted into the detail. The bare `camera_held` does not, and
--- that is the refusal worth spending a native call on: "somebody has the view"
--- is not actionable and "open77_creator has the view" is. The extra call
--- happens only on the failure path, so a shot that works pays nothing.
local function named(failure)
	if type(failure.error) ~= 'string' then return failure end
	if failure.error:find('camera_held', 1, true) ~= 1 then return failure end

	local holder = failure.error:match('^camera_held_by:(.+)$')
	if holder == nil then
		local read = Camera.Holder()
		if read.ok then holder = read.value end
	end

	failure.holder = holder
	failure.detail = holder ~= nil
		and ('%s has the view; it is refused rather than stolen, because two resources each '
			.. 'believing they are driving is worse than one of them not getting the shot')
			:format(holder)
		or 'another resource has the view, and this build would not say which'
	return failure
end

-- ── Who has the view ─────────────────────────────────────────────────────────

--- This resource's own name, or nil on a build that will not say.
---
--- Ungated and immutable for the lifetime of the resource definition, which is
--- what makes it safe to ask on a read path. A plain value and not a Result:
--- the only question a caller has is "is this string the holder", and nil
--- answers it honestly.
-- @author dop42
-- @return string|nil
function Camera.Owner()
	local native = Native.Reach('resource.name')
	if native == nil then return nil end

	local read, name = pcall(native)
	if not read or type(name) ~= 'string' or name == '' then return nil end
	return name
end

--- Who owns the view, as one word, from a snapshot the caller already holds.
---
---   'mine'    this resource has the view
---   'theirs'  another resource has it; `snap.holder` names them
---   'held'    somebody has it and this build would not say who
---   'free'    nobody has it
---   'unknown' not a snapshot
---
--- A plain string and not a Result: it reads a table the caller already has,
--- cannot fail, and is asked once per decision. The same argument
--- `client/input.lua` and `client/marker.lua` make for their readers.
---
--- IT DECIDES ON `holder`, NOT `held`, and the header says why: the two sources
--- disagree about whether `held` is owner-scoped, and a name compared against
--- our own name is right under either reading. `held` is consulted only when
--- there is no name -- and then the answer is the deliberately vague 'held',
--- because that is genuinely all that is known.
-- @author dop42
-- @param snap table a snapshot from `Cameras`
-- @return string
function Camera.State(snap)
	if type(snap) ~= 'table' then return 'unknown' end

	local holder = Validate.Text(snap.holder, 128)
	if holder == nil then
		-- No name. `held` is the only evidence left, and it does not say whose.
		if snap.held == true then return 'held' end
		return 'free'
	end

	local me = Camera.Owner()
	if me == nil then return 'held' end
	if holder == me then return 'mine' end
	return 'theirs'
end

--- This resource's cameras and whether it holds the view, with `state` added.
---
--- The snapshot is ANNOTATED, not rebuilt: rebuilding would silently drop every
--- field a newer build added, which is backwards for a value whose whole job is
--- diagnosis. The camera LIST is owner-scoped; `holder` is not, and that
--- asymmetry is the point of the call.
-- @author dop42
-- @return table a Result carrying the snapshot
function Camera.Cameras()
	local read = Native.Call('camera.cameras', Camera.NEEDS)
	if not read.ok then return read end
	if type(read.value) == 'table' then read.value.state = Camera.State(read.value) end
	return read
end

--- The resource holding the view, or Ok(nil) when nobody is.
---
--- THE ONE QUESTION A `camera_held_by:` REFUSAL LEAVES YOU ASKING, asked before
--- the attempt instead of after it. `Ok(nil)` is an answer -- the view is free
--- -- which is exactly the case `Result` exists for.
-- @author dop42
-- @return table a Result carrying the holder's name, or nil
function Camera.Holder()
	local read = Native.Call('camera.cameras', Camera.NEEDS)
	if not read.ok then return read end
	if type(read.value) ~= 'table' then
		return Result.Err('invalid_camera_snapshot', 'camera.cameras did not answer a table')
	end
	return Result.Ok(Validate.Text(read.value.holder, 128))
end

-- ── Definitions ──────────────────────────────────────────────────────────────

--- Creates a camera and answers its id. Nothing is rendered until `Take`.
---
--- A CAMERA IS A DEFINITION, NOT A VIEW. Sixteen of these may exist at once and
--- exactly one of them can be live, so creating one costs a player nothing and
--- is safe to do up front -- the character creator in the platform's own example
--- builds both shots before it takes the view.
-- @author dop42
-- @param options table position, attachTo, offset, lookAt, rotation, fov
-- @return table a Result carrying the camera id
function Camera.Create(options)
	local spec, code, detail = definition(options, true)
	if spec == nil then return Result.Err(code, detail) end

	local made = Native.Call('camera.create', Camera.NEEDS, spec)
	if not made.ok and made.error == 'camera_budget_exhausted' then
		return Result.Err('camera_budget_exhausted', ('this resource may hold %d camera '
			.. 'definitions at once and the client shares %d; destroy one you are finished '
			.. 'with -- a definition costs nothing to re-create'):format(
				Camera.LIMIT, Camera.CLIENT_LIMIT))
	end
	return made
end

--- Moves and/or turns a camera. Cheap enough to call every frame: that is how a
--- dolly is written.
---
--- The TABLE form of `setTransform` only, because the positional form cannot
--- carry a field of view and two doors onto one native is two places for a
--- bound to go stale. Setting a rotation clears a previous look-at, which is
--- why the door refuses a patch carrying both.
-- @author dop42
-- @param camId number
-- @param patch table position, rotation, fov
-- @return table a Result
function Camera.Move(camId, patch)
	local id = camOf(camId)
	if id == nil then
		return Result.Err('invalid_camera_id', 'a camera id is a whole number')
	end

	local spec, code, detail = definition(patch, false)
	if spec == nil then return Result.Err(code, detail) end
	if next(spec) == nil then
		-- The platform's own word for it, so a caller writes one branch whether
		-- the empty patch was caught here or one native call later.
		return Result.Err('empty_camera_transform', 'a patch with no fields changes nothing')
	end

	return Native.Call('camera.setTransform', Camera.NEEDS, id, spec)
end

--- Points a camera at a world point or at an entity. Entity `0` is the player.
---
--- The aim is re-solved EVERY frame, so a tracked entity that moves stays
--- centred and an entity that streams out holds the last aim rather than
--- snapping the shot to the world origin.
-- @author dop42
-- @param camId number
-- @param target table|number { x, y, z } or an entity id
-- @return table a Result
function Camera.LookAt(camId, target)
	local id = camOf(camId)
	if id == nil then
		return Result.Err('invalid_camera_id', 'a camera id is a whole number')
	end

	if type(target) == 'number' then
		local entity = entityOf(target)
		if entity == nil then
			return Result.Err('invalid_entity_id',
				'a numeric target is an entity id; 0 is the local player')
		end
		return Native.Call('camera.lookAt', Camera.NEEDS, id, entity)
	end

	local at = point(target)
	if at == nil then
		return Result.Err('invalid_camera_look_at',
			'a target is a finite { x, y, z } world point, or an entity id')
	end
	return Native.Call('camera.lookAt', Camera.NEEDS, id, at)
end

--- Parents a camera to an entity: it follows the parent's position AND
--- rotation, so this plus a fixed rotation is a dealership turntable.
---
--- BOTH ARGUMENTS ARE REQUIRED HERE, though the native's are optional, and that
--- is deliberate. `Open77.camera.attach()` with no arguments is an older call
--- that means something else entirely -- restore the player's own camera -- and
--- a caller who forgot an argument would reach it by accident. A door that
--- cannot be fallen through is worth one refused call.
-- @author dop42
-- @param camId number
-- @param entity number an entity id; 0 is the local player's own body
-- @param offset table|nil { x, y, z } in the parent's frame
-- @return table a Result
function Camera.Attach(camId, entity, offset)
	local id = camOf(camId)
	if id == nil then
		return Result.Err('invalid_camera_id', 'a camera id is a whole number')
	end

	local parent = entityOf(entity)
	if parent == nil then
		return Result.Err('invalid_entity_id',
			'attach needs an entity id; 0 is the local player\'s own body')
	end

	if offset == nil then
		return Native.Call('camera.attach', Camera.NEEDS, id, parent)
	end

	local at = point(offset)
	if at == nil then
		return Result.Err('invalid_camera_offset',
			'offset is a finite { x, y, z } in the parent\'s frame (X right, Y forward, Z up)')
	end
	return Native.Call('camera.attach', Camera.NEEDS, id, parent, at)
end

--- Un-parents a camera. It keeps the pose it had; the next `Move` places it.
---
--- Not spelled `Detach`, for the platform's own reason: `Open77.camera.detach()`
--- already means "move the player's own camera off their eyes".
-- @author dop42
-- @param camId number
-- @return table a Result
function Camera.DetachFrom(camId)
	local id = camOf(camId)
	if id == nil then
		return Result.Err('invalid_camera_id', 'a camera id is a whole number')
	end
	return Native.Call('camera.detachFrom', Camera.NEEDS, id)
end

--- Destroys a camera. If it is the live one, the view comes back.
---
--- Destroying the camera being looked through is legal and IS a release: the
--- pending blend promise rejects with `camera_destroyed` rather than hanging.
-- @author dop42
-- @param camId number
-- @return table a Result
function Camera.Destroy(camId)
	local id = camOf(camId)
	if id == nil then
		return Result.Err('invalid_camera_id', 'a camera id is a whole number')
	end
	return Native.Call('camera.destroy', Camera.NEEDS, id)
end

-- ── Holding the view ─────────────────────────────────────────────────────────

--- Takes the view. `blendMs` interpolates from wherever the view is now.
---
--- The Result's `value` is the platform's own `true`; the blend promise is
--- `.blend`, and it is nil for a cut because a cut has already settled by the
--- time the call returns. `Camera.Await` takes either.
---
--- A REFUSAL NAMES THE HOLDER. `camera_held_by:<resource>` carries the name and
--- it is lifted into `.holder` and into the detail; a bare `camera_held` costs
--- one extra read of `cameras()` to answer the same question.
---
--- `camera_unavailable` means the player is dead or unreadable, or a perspective
--- transition is in flight. Retry a frame later -- taking the camera mid
--- transition would leave the body and the view disagreeing for as long as the
--- transition runs.
-- @author dop42
-- @param camId number
-- @param options table|nil { blendMs = 0..60000 }
-- @return table a Result; `.blend` is the promise, or nil for a cut
function Camera.Take(camId, options)
	local id = camOf(camId)
	if id == nil then
		return Result.Err('invalid_camera_id', 'a camera id is a whole number')
	end

	local settings, code, detail = blend(options, 'Take')
	if settings == nil then return Result.Err(code, detail) end

	local took = reachWithPromise('camera.activate', id, settings)
	if took.ok then return took end

	if took.error == 'invalid_argument' then
		-- The one refusal the engine cannot name: `invalid_blend_ms` covers the
		-- blend and this door covers every other argument, so what is left is
		-- the streaming ceiling.
		return Result.Err('invalid_argument', ('the camera is further than %d m from the '
			.. 'player; the world streams around the BODY and not the lens, so a shot that '
			.. 'far away would render unstreamed space -- move the player, not just the '
			.. 'camera'):format(Camera.RANGE))
	end
	return named(took)
end

--- Gives the view back, blending to the player's own eyes. Only the holder may.
---
--- A blended hand-back finishes exactly on the player's eyes, so the restore
--- writes the value already on screen and there is no jump at the end.
-- @author dop42
-- @param options table|nil { blendMs = 0..60000 }
-- @return table a Result; `.blend` is the promise, or nil for an instant one
function Camera.Release(options)
	local settings, code, detail = blend(options, 'Release')
	if settings == nil then return Result.Err(code, detail) end
	return reachWithPromise('camera.deactivate', settings)
end

--- Waits for a blend to land, and says which release rule ended it if it did.
---
--- MUST RUN INSIDE A `CreateThread`: it suspends. A nil promise answers Ok
--- immediately, because that is what a cut is -- already finished, nothing left
--- to wait for -- and making the caller branch on which they got would put the
--- same `if` at every call site.
---
--- A REJECTION IS NOT AN ERROR IN THE CALLER'S CODE. It is one of the release
--- rules: the player died, the resource was reloaded, a different camera of
--- theirs was activated. `Camera.RELEASES` turns the token into the sentence,
--- and the token itself stays as the Result's code so a caller can still branch
--- on it. Never `await` one of these without a failure branch -- every release
--- rejects the promise rather than dropping it, precisely so the coroutine that
--- was going to tidy up wakes up and does.
-- @author dop42
-- @param promise table|nil the `.blend` off a Take, Release, Follow or Unfollow
-- @return table a Result
function Camera.Await(promise)
	if promise == nil then return Result.Ok(nil) end

	local settled = Async.All({ promise })
	if settled.ok then return Result.Ok(settled.value[1]) end

	return Result.Err(settled.error, Camera.Why(settled.error))
end

--- What a release token means, as a sentence.
---
--- An unknown token is passed through rather than guessed at: a newer build may
--- release for a reason this library has never heard of, and inventing a
--- sentence for it would be worse than repeating the token.
-- @author dop42
-- @param reason any
-- @return string
function Camera.Why(reason)
	local token = type(reason) == 'string' and reason or 'unknown'
	return Camera.RELEASES[token] or ('the shot ended: ' .. token)
end

--- Takes the view, runs `body`, and gives the view back whatever happens.
---
--- THE GUARANTEE THIS MODULE EXISTS FOR, and it is worth stating exactly.
--- When `Shot` returns, the player has their own view back: the hand-back is
--- issued on every exit from `body` -- a return, a raise, or a release the
--- platform performed underneath it -- and the returning blend is awaited, so
--- the view is back on the eyes and not halfway there.
---
--- WHAT IT DOES NOT COVER, said plainly. A `body` that never returns -- an
--- infinite loop, a `Wait` that is never satisfied -- is never left by any
--- path, so nothing here runs and the release comes from the platform when the
--- resource stops. And a caller who does not use `Shot` gets exactly the
--- platform's own rules and no more.
---
--- MUST RUN INSIDE A `CreateThread`: it awaits both blends.
---
--- A RAISE IN `body` BECOMES A RESULT, not an unwind: `shot_raised`, carrying
--- the message. Letting it propagate would take down the consumer's handler
--- AFTER the view was restored, which is the one ordering that loses the error
--- and keeps the symptom. `.released` says whether the hand-back was accepted;
--- it is false only when the platform refused it for a reason other than "you
--- do not hold the view", which is itself a success -- something released the
--- shot first, and the view is back either way.
-- @author dop42
-- @param camId number
-- @param options table|nil { blendMs, releaseMs }
-- @param body function run while the view is held
-- @return table a Result carrying whatever `body` answered
function Camera.Shot(camId, options, body)
	-- `Shot(cam, fn)` is the common case and reads better than `Shot(cam, nil, fn)`.
	if type(options) == 'function' and body == nil then
		options, body = nil, options
	end
	if type(body) ~= 'function' then
		return Result.Err('invalid_body', 'Shot runs a function while it holds the view')
	end

	local takeMs, releaseMs
	if options ~= nil then
		if Validate.Table(options, 8) == nil then
			return Result.Err('invalid_camera_options', 'Shot options is not a plain table')
		end
		for key in pairs(options) do
			if key ~= 'blendMs' and key ~= 'releaseMs' then
				return Result.Err('invalid_camera_options',
					('Shot takes blendMs and releaseMs; %q is not a field it has')
						:format(tostring(key)))
			end
		end
		takeMs, releaseMs = options.blendMs, options.releaseMs
		-- The hand-back defaults to the same blend as the take. A shot that
		-- eases in over 600 ms and cuts out is the one thing a player notices.
		if releaseMs == nil then releaseMs = takeMs end
	end

	local took = Camera.Take(camId, takeMs ~= nil and { blendMs = takeMs } or nil)
	if not took.ok then return took end

	-- Hands the view back and waits for it to land. Tolerant on purpose.
	local function handBack()
		local gave = Camera.Release(releaseMs ~= nil and { blendMs = releaseMs } or nil)
		if not gave.ok then
			-- We no longer hold it, which is the outcome we wanted anyway: a
			-- release rule got there first and the view is already back.
			return gave.error == 'camera_not_active'
		end
		Camera.Await(gave.blend)
		return true
	end

	local reached = Camera.Await(took.blend)
	if not reached.ok then
		-- The shot never happened. `body` is NOT run: it would draw a UI over a
		-- view somebody else now owns.
		local failed = Result.Err(reached.error, reached.detail)
		failed.released = handBack()
		return failed
	end

	local ran, answered = pcall(body)
	local released = handBack()

	local out = ran and Result.Ok(answered)
		or Result.Err('shot_raised', tostring(answered))
	out.released = released
	return out
end

-- ── Following ────────────────────────────────────────────────────────────────

--- Rides an entity: the camera sits behind it and aims at it, both re-solved
--- every frame. Entity `0` is the local player's own body.
---
--- ONE CAMERA PER RESOURCE, REUSED. Calling this again with a different entity
--- retargets the same camera and answers the same id rather than creating a
--- second one -- a resource that follows the nearest player once a second would
--- otherwise exhaust its sixteen definitions in sixteen seconds and start
--- failing for a reason that has nothing to do with what it asked for. Each
--- call supersedes the previous call's blend promise, which settles as
--- `camera_superseded`.
---
--- `distance`, `height` and `side` are in the TARGET's own frame, which is what
--- makes `distance` mean "behind him" rather than "north of him".
---
--- NOT A NEW WAY TO HOLD THE VIEW: this is create plus lookAt plus activate, so
--- every release rule applies to it unchanged, and so does the streaming
--- ceiling -- following a target three hundred metres away gives a correctly
--- aimed camera looking at unstreamed space, which is an empty frame and not an
--- error. Move the body first.
-- @author dop42
-- @param entity number an entity id; 0 is the local player
-- @param options table|nil distance, height, side, fov, blendMs
-- @return table a Result carrying the camera id; `.blend` is the promise
function Camera.Follow(entity, options)
	local target = entityOf(entity)
	if target == nil then
		-- `invalid_entity`, not `invalid_entity_id`: `follow` is the one native
		-- in this namespace that spells it the short way, and reusing the
		-- platform's own word per call beats one tidy word of our own.
		return Result.Err('invalid_entity',
			'follow needs an entity id; 0 is the local player\'s own body')
	end

	local spec = {}
	if options ~= nil then
		if Validate.Table(options, 8) == nil then
			return Result.Err('invalid_camera_options', 'follow options is not a plain table')
		end

		for key in pairs(options) do
			if key ~= 'distance' and key ~= 'height' and key ~= 'side'
				and key ~= 'fov' and key ~= 'blendMs' then
				return Result.Err('invalid_camera_options',
					('follow field %q is not one this call takes'):format(tostring(key)))
			end
		end

		for _, key in ipairs({ 'distance', 'height', 'side' }) do
			if options[key] ~= nil then
				local range = Camera.FOLLOW[key]
				local number = Validate.Number(options[key], range[1], range[2])
				if number == nil then
					return Result.Err('invalid_follow_' .. key,
						('%s is a number of metres, %g to %g'):format(key, range[1], range[2]))
				end
				spec[key] = number
			end
		end

		if options.fov ~= nil then
			spec.fov = fov(options.fov)
			if spec.fov == nil then
				return Result.Err('invalid_camera_fov', ('fov is %d to %d degrees, or 0 to '
					.. 'leave the engine\'s own alone'):format(Camera.MIN_FOV, Camera.MAX_FOV))
			end
		end

		if options.blendMs ~= nil then
			spec.blendMs = millis(options.blendMs, Camera.MAX_BLEND)
			if spec.blendMs == nil then
				return Result.Err('invalid_blend_ms', ('blendMs is a whole number of '
					.. 'milliseconds, 0 to %d'):format(Camera.MAX_BLEND))
			end
		end
	end

	local followed = reachWithPromise('camera.follow', target, spec)
	if followed.ok then return followed end
	return named(followed)
end

--- Gives the view back AND destroys the follow camera.
---
--- The camera is destroyed even when the view had already been released by
--- something else, so a follow can never be left behind. A second call answers
--- `not_following`, which is the honest word for it rather than a silent Ok.
-- @author dop42
-- @param options table|nil { blendMs = 0..60000 }
-- @return table a Result; `.blend` is the promise, or nil for an instant one
function Camera.Unfollow(options)
	local settings, code, detail = blend(options, 'Unfollow')
	if settings == nil then return Result.Err(code, detail) end
	return reachWithPromise('camera.unfollow', settings)
end

-- ── Shake ────────────────────────────────────────────────────────────────────

--- Shakes a camera with one of the four presets.
---
--- Additive on top of the resolved pose, so it composes with a blend and with a
--- look-at instead of fighting either, and it decays exactly to rest. Pass nil
--- for `camId` to shake whichever camera this resource currently holds.
-- @author dop42
-- @param camId number|nil
-- @param preset string hand, drunk, explosion or earthquake
-- @param amplitude number|nil 0 to 4.0, the platform's own default is 1.0
-- @param ms number|nil the platform's own default is 500
-- @return table a Result
function Camera.Shake(camId, preset, amplitude, ms)
	local id
	if camId ~= nil then
		id = camOf(camId)
		if id == nil then
			return Result.Err('invalid_camera_id',
				'a camera id is a whole number, or nil for the camera you hold')
		end
	end

	local shake = Validate.OneOf(preset, Camera.SHAKES)
	if shake == nil then
		return Result.Err('invalid_shake_preset', ('shake preset %q is not one of: %s')
			:format(tostring(preset), table.concat(Camera.SHAKES, ', ')))
	end

	local force
	if amplitude ~= nil then
		if type(amplitude) ~= 'number' then
			return Result.Err('invalid_shake_argument', 'amplitude is a number')
		end
		force = Validate.Number(amplitude, 0, Camera.MAX_AMPLITUDE)
		if force == nil then
			return Result.Err('invalid_shake_argument',
				('amplitude is 0 to %g'):format(Camera.MAX_AMPLITUDE))
		end
	end

	local duration
	if ms ~= nil then
		duration = millis(ms, Camera.MAX_BLEND)
		if duration == nil then
			return Result.Err('invalid_shake_argument',
				('ms is a whole number of milliseconds, 0 to %d'):format(Camera.MAX_BLEND))
		end
	end

	return Native.Call('camera.shake', Camera.NEEDS, id, shake, force, duration)
end

--- Stops a shake. The camera stays exactly where it is: this is not a release.
---
--- A camera with no shake running accepts it without complaint, so a tidy-up
--- path may call it unconditionally.
-- @author dop42
-- @param camId number
-- @return table a Result
function Camera.StopShake(camId)
	local id = camOf(camId)
	if id == nil then
		return Result.Err('invalid_camera_id', 'a camera id is a whole number')
	end
	return Native.Call('camera.stopShake', Camera.NEEDS, id)
end

-- ── Reading the view ─────────────────────────────────────────────────────────

--- The world ray behind a screen point, `0..1` from the TOP LEFT.
---
--- The second of the two functions here that need no permission: it reads the
--- camera, it does not move it. It passes `nil` to `Native.Call` so a refusal
--- from it is never rewritten into "add camera.script", which would be advice
--- that fixes nothing.
---
--- The frame is exactly the one `Open77.camera.project` answers, so the two
--- round-trip: project a world point, unproject the screen point, and the
--- direction points from the origin back at the point you started with.
-- @author dop42
-- @param x number 0..1
-- @param y number 0..1
-- @return table a Result carrying { origin, direction }
function Camera.Ray(x, y)
	-- The platform's own word, and the bound is the documented frame. A
	-- coordinate outside it is not a point on the screen.
	local across, down = Validate.Number(x, 0, 1), Validate.Number(y, 0, 1)
	if across == nil or down == nil then
		return Result.Err('invalid_screen_point',
			'x and y are finite numbers 0..1, with the origin at the top left')
	end
	return Native.Call('camera.unproject', nil, across, down)
end

return Camera
