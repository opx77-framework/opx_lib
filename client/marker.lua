--- World markers: placing one, and finding out whether it actually drew.
-- @author dop42
--
--   local made = Lib.Marker.Place({ x = -1442.2, y = 127.4, z = 18.0 },
--     { shape = 'cylinder', style = 'objective', radius = 1.5, maxDistance = 80 })
--
--   CreateThread(function()
--     local drew = Lib.Marker.Await(made.value)   -- resolves, or says why not
--     if not drew.ok then print('no marker: ' .. drew.error) end
--   end)
--
-- Wraps `Open77.markers.*`. The consumer must declare `world.markers`.
--
-- A HANDLE IS NOT A MARKER, and this module exists mostly to say so. Creation
-- is asynchronous: `create` answers a handle the instant the definition is
-- accepted, long before the mesh, its material and its appearance have
-- streamed in. Every failure after that point -- a missing asset, a streaming
-- timeout, an entity that would not spawn -- arrives LATER, in the snapshot's
-- `failed` and `error`, and never as a second return value from the call the
-- consumer made. A resource that checks only the handle reports success for a
-- marker nobody can see. That is the same trap props set, and the platform
-- documents it here too, so `Await`, `State` and `Failures` below are the
-- point of the module rather than an afterthought.
--
-- `rendered` IS NOT "ON SCREEN". The platform is explicit: it means the native
-- mesh is attached and enabled. A rendered marker may be behind the camera,
-- behind a wall, or outside its own distance range. Nothing here can answer
-- "can the player see it" -- no native does -- so nothing here pretends to.
-- `State` classifies what the snapshot really knows and stops there.
--
-- THE HANDLE IS A DECIMAL STRING, not a number, and that is load-bearing: it
-- preserves the full 64-bit identity of the marker, which a Lua number would
-- round away past 2^53. Nothing here converts it, compares it numerically or
-- does arithmetic on it, and a consumer must not either. The handle checks
-- below are checks on the SHAPE of a string that is never converted; a caller
-- who passed `tonumber(handle)` is refused at the door rather than one build
-- later, when two markers start sharing an id.
--
-- MARKERS ARE RESOURCE-OWNED, and the owner is the CONSUMER, because this code
-- runs in their VM. `Marker.Clear()` therefore removes every marker the
-- consumer owns -- including ones they created without this module. That is the
-- right behaviour for a resource shutting down and the wrong one to reach for
-- casually, so it is named for what it does rather than given a softer word.
--
-- `Shapes()` NEEDS NO PERMISSION, ALONE IN THIS MODULE, and that asymmetry is
-- handled rather than hidden -- see `Marker.UNGATED`.
--
-- WHY `Move` IS STILL CALLED `Move` though it now patches colour, scale and
-- rotation as well. The name shipped in 0.2.0 and this library is installed
-- somewhere; renaming it would break a consumer's code to buy a better word.
-- It stays, and the docstring does the work the name no longer does.

local Native = require('@opx_lib/client.native')
local Validate = require('@opx_lib/pure.validate')
local Result = require('@opx_lib/pure.result')
local Colour = require('@opx_lib/pure.colour')
local Timer = require('@opx_lib/client.timer')

local Marker = {}

--- The manifest permission a consumer must declare to use this module.
---
--- DELIBERATELY THE MAXIMUM, NOT THE MINIMUM. `Shapes()` is gated on nothing --
--- it reads a static catalogue -- so a consumer who calls only that needs no
--- manifest line at all, and `Lib.Manifest()` will still tell them to add one.
--- That over-statement is the safe direction and the only one this field can
--- express: `NEEDS` is a single string, `Permission.Of` reads exactly that
--- field, and a declared permission nobody exercises costs a consumer nothing,
--- while a missing one costs them a marker that silently never appears. The
--- functions that need nothing are listed in `UNGATED` so the claim is still
--- written down, and each of them passes `nil` to `Native.Call` so that a
--- refusal from one is never rewritten into "add world.markers" -- which would
--- be advice that does not fix anything.
Marker.NEEDS = 'world.markers'

--- The functions in this module that need no permission.
Marker.UNGATED = { 'Shapes' }

--- The eight shapes the platform ships, in the catalogue's own order.
---
--- Held statically because the door has to refuse an unknown shape WITHOUT
--- reaching the platform -- the refusal `unsupported_shape` costs a native call
--- and names nothing the caller can fix -- and because `markers.shapes` does
--- not exist on every build this library runs on. It is what this module will
--- accept; `Shapes()` is what the build supports. On the builds these were
--- written against the two agree, and a ninth shape is a library update.
Marker.SHAPES = {
	'ring', 'cylinder', 'checkpoint', 'arrow', 'chevron', 'cone', 'diamond', 'sphere',
}

--- The four style palettes: cyan, gold, green, red, in that order.
Marker.STYLES = { 'interaction', 'objective', 'spawn', 'danger' }

--- Logical markers one resource may own at once. The platform's number.
---
--- Not pre-checked here. Counting would cost a `list` call on every create, and
--- the count it answered would still be a guess the moment a retiring entity
--- released a slot. The engine enforces it exactly; `Place` only rewrites the
--- refusal into one that says what the number is, and `Count()` answers it for
--- a caller who wants to look before placing.
Marker.LIMIT = 64

--- Native material slots, shared by the WHOLE CLIENT and not by this resource.
---
--- Documented because it is the limit a consumer cannot reason about locally: a
--- resource well inside its own 64 can still be refused because retiring
--- entities elsewhere have not released their slots yet. Repeatedly creating,
--- recolouring and removing markers is the way to hit it.
Marker.SLOTS = 256

--- The platform's cap on an effective dimension, in metres.
Marker.MAX_EXTENT = 200

--- The alpha the platform applies when a colour omits one.
---
--- Documented, never filled in here: a colour this module completed would be a
--- library default masquerading as the engine's, and the two would drift. A
--- caller computing a fade needs the baseline, which is what this is for.
Marker.ALPHA = 180

--- The platform's documented defaults, used for CHECKING and never sent.
---
--- `minDistance < maxDistance` and the 200 m extent cap are cross-field rules,
--- so checking a create that named only `radius` needs to know what the other
--- half will be. These are that knowledge. They are not merged into the spec:
--- forwarding them would turn the engine's default into this library's copy of
--- it, and the copy is what goes stale.
Marker.DEFAULTS = {
	radius = 1.5,
	height = 1.5,
	scale = { x = 1, y = 1, z = 1 },
	minDistance = 0,
	maxDistance = 100,
}

--- Every field `create` and `update` accept. The set is closed on purpose.
---
--- A misspelled field is otherwise the quietest bug in the API: `colour` (which
--- is how this library spells it everywhere else), `maxDist`, `hidden` -- each
--- one is accepted by the engine, ignored, and produces a marker that is
--- subtly not what was asked for, with no refusal anywhere. Refusing an unknown
--- key names the typo instead. The cost is that a field a newer build adds is
--- refused until this list grows, which is a library update and not a silence.
local ALLOWED = {
	position = true, shape = true, style = true, radius = true, height = true,
	scale = true, rotation = true, color = true, visible = true,
	minDistance = true, maxDistance = true,
}

-- Every bound below is the platform's, from the marker options table: radius
-- 0.1..50 m, height and each scale axis 0.01..100, maxDistance 1..500 m,
-- minDistance non-negative, colour channels 0..255. They are enforced here so
-- that a caller learns which of THEIR numbers was out of range, rather than
-- reading `invalid_argument` back from the engine -- which the platform returns
-- for radius, height and both distances alike and so cannot tell them apart.

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

--- Three bounded axes, absent ones filled with `fill`, or nil.
---
--- FILLING IS A JUDGEMENT CALL the platform's documentation does not make. It
--- gives `scale` a default of `{1,1,1}` but does not say what a `{ x = 1.2 }`
--- means, and the two readings -- "the other axes stay 1" and "the other axes
--- are unset, whatever that does" -- are not the same marker. Completing it to
--- the documented default is the charitable one and, more to the point, the
--- deterministic one: what reaches the engine no longer depends on a behaviour
--- nobody has written down.
local function axes(value, low, high, fill)
	if Validate.Table(value, 8) == nil then return nil end

	local out = {}
	for _, key in ipairs({ 'x', 'y', 'z' }) do
		if value[key] == nil then
			out[key] = fill
		else
			local number = Validate.Number(value[key], low, high)
			if number == nil then return nil end
			out[key] = number
		end
	end
	return out
end

--- An RGBA colour the native will take, `false`, or nil.
---
--- `false` IS A VALUE HERE, not a bad colour: the platform uses it in a patch
--- to drop a custom colour and go back to the style palette. A validator that
--- treated it as garbage would make the documented way to undo a recolour
--- impossible.
---
--- A `#RRGGBB` STRING IS ACCEPTED AND CONVERTED, though the native refuses one.
--- Hex is how a colour arrives from a config file or a WebUI, the conversion is
--- `Lib.Colour.Parse` and therefore strict, and the alternative is every
--- consumer writing the same three `tonumber(_, 16)` calls. What reaches the
--- engine is integers either way.
local function colour(value)
	if value == false then return false end

	if type(value) == 'string' then
		local parsed = Colour.Parse(value)
		if parsed == nil then return nil end
		-- No alpha: six hex digits carry none, and the engine's own 180 is a
		-- better answer than one invented here.
		return { r = parsed.r, g = parsed.g, b = parsed.b }
	end

	if Validate.Table(value, 8) == nil then return nil end
	local r = Validate.Integer(value.r, 0, 255)
	local g = Validate.Integer(value.g, 0, 255)
	local b = Validate.Integer(value.b, 0, 255)
	if r == nil or g == nil or b == nil then return nil end

	if value.a == nil then return { r = r, g = g, b = b } end
	local a = Validate.Integer(value.a, 0, 255)
	if a == nil then return nil end
	return { r = r, g = g, b = b, a = a }
end

--- Validates a whole definition and answers the spec to send, or a refusal.
---
--- One function for both calls because the platform uses one field set for
--- both, and two copies of eleven bounds would disagree by the third release.
--- `creating` decides only two things: whether `position` is required, and
--- whether an absent field may be assumed to take its documented default for
--- the cross-field checks at the bottom.
---
--- THE CODES REUSE THE PLATFORM'S OWN WORDS wherever the platform has one --
--- `invalid_position`, `invalid_scale`, `invalid_rotation`, `invalid_color`,
--- `unsupported_shape`, `unknown_marker_style` -- so that a caller branching on
--- a code writes one branch whether the refusal came from this door or from the
--- engine behind it. Where the platform has only `invalid_argument`, this
--- splits it, because "which number was wrong" is the entire value of checking
--- here at all.
-- @return table|nil spec, string|nil code, string|nil detail
local function definition(given, creating)
	if Validate.Table(given, 16) == nil then
		return nil, 'invalid_options', 'a marker definition is a plain table'
	end

	for key in pairs(given) do
		if not ALLOWED[key] then
			return nil, 'unknown_field', ('marker field %q is not one this API has; '
				.. 'note the colour channel table is spelled "color"'):format(tostring(key))
		end
	end

	local spec = {}

	if given.position ~= nil or creating then
		if given.position == nil then
			return nil, 'position_required', 'a marker needs a position to be created at'
		end
		spec.position = point(given.position)
		if spec.position == nil then
			return nil, 'invalid_position', 'position is not a finite { x, y, z }'
		end
	end

	if given.shape ~= nil then
		spec.shape = Validate.OneOf(given.shape, Marker.SHAPES)
		if spec.shape == nil then
			return nil, 'unsupported_shape', ('shape %q is not one of: %s')
				:format(tostring(given.shape), table.concat(Marker.SHAPES, ', '))
		end
	end

	if given.style ~= nil then
		spec.style = Validate.OneOf(given.style, Marker.STYLES)
		if spec.style == nil then
			return nil, 'unknown_marker_style', ('style %q is not one of: %s')
				:format(tostring(given.style), table.concat(Marker.STYLES, ', '))
		end
	end

	if given.radius ~= nil then
		spec.radius = Validate.Number(given.radius, 0.1, 50)
		if spec.radius == nil then
			return nil, 'invalid_radius', 'radius is a number of metres, 0.1 to 50'
		end
	end

	if given.height ~= nil then
		spec.height = Validate.Number(given.height, 0.01, 100)
		if spec.height == nil then
			return nil, 'invalid_height', 'height is a multiplier, 0.01 to 100'
		end
	end

	if given.scale ~= nil then
		spec.scale = axes(given.scale, 0.01, 100, 1)
		if spec.scale == nil then
			return nil, 'invalid_scale', 'scale is { x, y, z } multipliers, 0.01 to 100'
		end
	end

	if given.rotation ~= nil then
		-- No range: these are Euler DEGREES and the engine wraps them, so 450
		-- and 90 are the same marker and refusing one of them would be this
		-- module inventing a rule. Finiteness is still checked -- a NaN angle
		-- is a mesh that never appears with no refusal anywhere.
		spec.rotation = axes(given.rotation, -100000, 100000, 0)
		if spec.rotation == nil then
			return nil, 'invalid_rotation', 'rotation is { x, y, z } finite degrees'
		end
	end

	if given.color ~= nil then
		spec.color = colour(given.color)
		if spec.color == nil then
			return nil, 'invalid_color', 'color is { r, g, b, a } bytes 0..255, a '
				.. '"#RRGGBB" string, or false to restore the style palette'
		end
	end

	if given.visible ~= nil then
		if type(given.visible) ~= 'boolean' then
			return nil, 'invalid_argument', 'visible is a boolean'
		end
		spec.visible = given.visible
	end

	if given.minDistance ~= nil then
		spec.minDistance = Validate.Number(given.minDistance, 0, nil)
		if spec.minDistance == nil then
			return nil, 'invalid_distance', 'minDistance is a non-negative number of metres'
		end
	end

	if given.maxDistance ~= nil then
		spec.maxDistance = Validate.Number(given.maxDistance, 1, 500)
		if spec.maxDistance == nil then
			return nil, 'invalid_distance', 'maxDistance is a number of metres, 1 to 500'
		end
	end

	-- ── cross-field ──────────────────────────────────────────────────────────
	-- On a create, an absent field will take its documented default, so both
	-- halves are always known. On a PATCH they are not: a patch that sets only
	-- `minDistance` is checked against a `maxDistance` this module was never
	-- told and must not guess at, so the pair is skipped and the engine -- which
	-- holds the stored value -- does the check. Half a rule enforced honestly
	-- beats a whole one enforced against a value that was made up.
	local function settled(name)
		if spec[name] ~= nil then return spec[name] end
		if creating then return Marker.DEFAULTS[name] end
		return nil
	end

	local low, high = settled('minDistance'), settled('maxDistance')
	if low ~= nil and high ~= nil and low >= high then
		return nil, 'invalid_distance',
			('minDistance %g must be less than maxDistance %g'):format(low, high)
	end

	local radius, scale = settled('radius'), settled('scale')
	if radius ~= nil and scale ~= nil then
		for _, key in ipairs({ 'x', 'y' }) do
			local extent = 2 * radius * scale[key]
			if extent > Marker.MAX_EXTENT then
				return nil, 'invalid_scale', ('2 * radius * scale.%s is %g m, over the '
					.. '%d m cap on an effective dimension')
					:format(key, extent, Marker.MAX_EXTENT)
			end
		end
	end
	-- The VERTICAL extent is `height * scale.z` times the MESH's authored
	-- height, and no native answers that number, so the same cap cannot be
	-- checked here. The engine checks it; this is the one bound the door has to
	-- let through.

	return spec
end

--- A handle, checked without ever being converted.
local function handleOf(value)
	local text = Validate.Text(value, 64)
	-- `Validate.Text` refusing a non-string is the check that matters: a caller
	-- who ran the handle through `tonumber` is stopped here rather than losing
	-- the low bits silently. The digit pattern is the platform's "decimal
	-- string" written down; widening it is a library update.
	if text == nil or text:match('^%d+$') == nil then return nil end
	return text
end

--- Adds the derived `state` to a snapshot and answers it.
---
--- The platform's table is ANNOTATED, not rebuilt. Rebuilding would silently
--- drop every field a newer build added, which is exactly backwards for a
--- value whose whole purpose is diagnosis.
local function annotate(snap)
	if type(snap) ~= 'table' then return snap end
	snap.state = Marker.State(snap)
	return snap
end

-- ── Reading the catalogue ────────────────────────────────────────────────────

--- The shapes THIS BUILD supports, straight from the platform.
---
--- The one function here that needs no permission: it reads a static catalogue
--- and touches no marker, so it passes `nil` as the permission and a refusal
--- from it is never rewritten into manifest advice.
---
--- Answers a Result and NOT the static `Marker.SHAPES`, deliberately. The
--- native is newer than some builds this library runs on, and a fallback to the
--- static list would answer eight shapes on a build that supports none of them
--- through this native -- a confident wrong answer where `native_not_found` is
--- a true one. A caller who wants the documented list regardless reads
--- `Marker.SHAPES`, which does not claim to describe their build.
-- @author dop42
-- @return table a Result carrying an array of shape names
function Marker.Shapes()
	return Native.Call('markers.shapes', nil)
end

-- ── Placing ──────────────────────────────────────────────────────────────────

--- Creates a marker and answers its handle.
---
--- THE HANDLE DOES NOT MEAN THE MARKER DREW. See the header; use `Await` or
--- `Get` if that matters, which for anything a player is meant to walk to it
--- does.
---
--- The position is the mesh's BOTTOM ORIGIN and there is no terrain snap, so a
--- ground marker wants to sit slightly above the floor or it z-fights with it.
--- Nothing here can add that offset: the floor height is a world query this
--- module does not make, and guessing a few centimetres would be wrong indoors.
-- @author dop42
-- @param position table { x, y, z }
-- @param options table|nil shape, style, radius, height, scale, rotation, color,
--                 visible, minDistance, maxDistance
-- @return table a Result carrying the handle string
function Marker.Place(position, options)
	local given = {}
	if options ~= nil then
		if Validate.Table(options, 16) == nil then
			return Result.Err('invalid_options', 'marker options is not a plain table')
		end
		for key, value in pairs(options) do
			-- `position` is the one field this function owns. Letting options
			-- carry a second one would make which of the two wins a coin toss.
			if key ~= 'position' then given[key] = value end
		end
	end
	given.position = position

	local spec, code, detail = definition(given, true)
	if spec == nil then return Result.Err(code, detail) end

	local made = Native.Call('markers.create', Marker.NEEDS, spec)
	if not made.ok and made.error == 'quota_exceeded' then
		return Result.Err('quota_exceeded', ('this resource may own %d markers at once, '
			.. 'and the client shares %d native material slots; remove one, or wait for '
			.. 'a retiring marker to release its slot and try again')
			:format(Marker.LIMIT, Marker.SLOTS))
	end
	return made
end

--- Patches a marker. Only the fields supplied change.
---
--- Despite the name this patches every field `Place` takes, colour, scale and
--- rotation included -- see the header for why it kept a narrower one.
---
--- A REJECTED PATCH CHANGES NOTHING. The platform applies one atomically, so a
--- patch with a good colour and a bad radius leaves the marker exactly as it
--- was rather than half-updated, and this door refuses the whole patch for the
--- same reason.
---
--- `{ color = false }` restores the style palette. Omitting `color` keeps
--- whatever custom colour is on the marker, which is the opposite thing.
-- @author dop42
-- @param handle string
-- @param patch table
-- @return table a Result
function Marker.Move(handle, patch)
	local id = handleOf(handle)
	if id == nil then
		return Result.Err('invalid_marker_id', 'a marker handle is a decimal string')
	end

	local spec, code, detail = definition(patch, false)
	if spec == nil then return Result.Err(code, detail) end
	if next(spec) == nil then
		return Result.Err('invalid_argument', 'an empty patch changes nothing')
	end

	return Native.Call('markers.update', Marker.NEEDS, id, spec)
end

-- ── Reading back ─────────────────────────────────────────────────────────────

--- What a snapshot actually knows about a marker, as one word.
---
--- A plain string and not a Result: it reads a table the caller already holds,
--- cannot fail, and is asked once per marker per diagnostic pass. The same
--- argument `client/input.lua` makes for its readers.
---
---   'failed'   the native could not load it. `snap.error` says why.
---   'hidden'   it loaded, and the caller asked for it to be invisible.
---   'rendered' the mesh is attached and enabled.
---   'pending'  none of the above: still streaming, or culled by distance.
---   'unknown'  not a snapshot.
---
--- THE ORDER IS THE POINT. `failed` is tested first because a marker can be
--- marked visible and failed at once, and reporting that one as merely hidden
--- is how a missing asset gets mistaken for a deliberate choice. `pending`
--- deliberately conflates "still loading" with "outside its distance range":
--- the snapshot does not distinguish them, and a name that implied it did would
--- be a lie in the interface.
---
--- NOTE that on a build whose snapshot carries no `failed` field at all, a
--- marker that failed reads as `pending` forever. That is the honest answer --
--- the build genuinely cannot tell -- and it is why `Await` times out rather
--- than claiming success there.
-- @author dop42
-- @param snap table a snapshot from `Get` or `List`
-- @return string
function Marker.State(snap)
	if type(snap) ~= 'table' then return 'unknown' end
	if snap.failed == true then return 'failed' end
	if snap.visible == false then return 'hidden' end
	if snap.rendered == true then return 'rendered' end
	return 'pending'
end

--- Reads one marker this consumer owns, with `state` added.
---
--- The snapshot carries the effective `color`, whether it was a `customColor`,
--- and the three fields this module is written around: `rendered`, `failed` and
--- an optional `error`.
-- @author dop42
-- @param handle string
-- @return table a Result carrying the snapshot
function Marker.Get(handle)
	local id = handleOf(handle)
	if id == nil then
		return Result.Err('invalid_marker_id', 'a marker handle is a decimal string')
	end

	local read = Native.Call('markers.get', Marker.NEEDS, id)
	if not read.ok then return read end
	return Result.Ok(annotate(read.value))
end

--- Every marker this consumer owns, each with `state` added.
-- @author dop42
-- @return table a Result carrying an array of snapshots
function Marker.List()
	local all = Native.Call('markers.list', Marker.NEEDS)
	if not all.ok then return all end
	if type(all.value) ~= 'table' then
		return Result.Err('invalid_answer', 'markers.list did not answer an array')
	end

	for index = 1, #all.value do annotate(all.value[index]) end
	return Result.Ok(all.value)
end

--- How many markers this consumer owns, against `Marker.LIMIT`.
---
--- Counts what the PLATFORM owns for this resource, not what this module
--- created: a consumer who also places markers by hand is over the same quota,
--- and a count that ignored those would encourage exactly the create that gets
--- refused.
-- @author dop42
-- @return table a Result carrying an integer
function Marker.Count()
	local all = Marker.List()
	if not all.ok then return all end
	return Result.Ok(#all.value)
end

--- Every marker of this consumer's that the native renderer could not load.
---
--- The triage call. "Nothing is showing" has two very different causes -- the
--- marker failed to load, or it loaded and you cannot see it -- and this
--- separates them in one call rather than a loop the consumer writes each time.
--- An empty array is the good answer and is Ok, not a failure.
-- @author dop42
-- @return table a Result carrying an array of failed snapshots
function Marker.Failures()
	local all = Marker.List()
	if not all.ok then return all end

	local failed = {}
	for index = 1, #all.value do
		local snap = all.value[index]
		if Marker.State(snap) == 'failed' then failed[#failed + 1] = snap end
	end
	return Result.Ok(failed)
end

--- Waits until a marker has drawn, or says why it never will.
---
--- THIS IS WHAT THE MODULE IS FOR. `Place` answers a handle; this answers
--- whether there is a marker. A resource that puts a checkpoint down and tells
--- the player to walk to it has no business doing either until this resolves.
---
--- MUST RUN INSIDE A `CreateThread`: it suspends, like everything built on
--- `Lib.Timer.Until`. It does not block the create -- placing is still
--- immediate -- so the usual shape is to place markers, then await them in one
--- thread while the rest of the resource carries on.
---
--- A `hidden` marker RESOLVES Ok. It loaded; the caller is the one who asked
--- for it to be invisible, and waiting for a marker you turned off to render
--- would time out every time.
---
--- The default deadline is five seconds because streaming a mesh, a material
--- and an appearance is tens to hundreds of milliseconds on a warm client and
--- seconds on a cold one; the default poll is 100 ms rather than `Until`'s 50
--- because each try is a real native call and twice as many of them buys
--- nothing a human can perceive.
-- @author dop42
-- @param handle string
-- @param timeout integer|nil milliseconds, default 5000
-- @return table a Result carrying the snapshot, or the reason it did not draw
function Marker.Await(handle, timeout)
	local id = handleOf(handle)
	if id == nil then
		return Result.Err('invalid_marker_id', 'a marker handle is a decimal string')
	end

	local last
	local settled = Timer.Until(function()
		last = Marker.Get(id)
		-- A marker that is gone, or a read that was refused, is an answer too:
		-- stop waiting for it rather than spending the whole deadline.
		if not last.ok then return true end

		local state = Marker.State(last.value)
		if state == 'pending' then return false end
		return state
	end, timeout or 5000, 100)

	if settled == nil then
		-- The platform's own word for it, so a caller writes one branch whether
		-- the wait ran out here or the engine reported the timeout itself.
		return Result.Err('marker_streaming_timeout',
			('marker %s had not drawn after %d ms'):format(id, timeout or 5000))
	end

	if last == nil or not last.ok then return last end

	if settled == 'failed' then
		local why = Validate.Text(last.value.error, 128)
		return Result.Err(why or 'marker_load_failed',
			('marker %s failed to load: %s'):format(id, why or 'no reason given'))
	end

	return Result.Ok(last.value)
end

-- ── Removing ─────────────────────────────────────────────────────────────────

--- Removes one marker.
-- @author dop42
-- @param handle string
-- @return table a Result
function Marker.Remove(handle)
	local id = handleOf(handle)
	if id == nil then
		return Result.Err('invalid_marker_id', 'a marker handle is a decimal string')
	end
	return Native.Call('markers.remove', Marker.NEEDS, id)
end

--- Removes EVERY marker the consumer owns, this module's or not.
-- @author dop42
-- @return table a Result
function Marker.Clear()
	return Native.Call('markers.clear', Marker.NEEDS)
end

return Marker
