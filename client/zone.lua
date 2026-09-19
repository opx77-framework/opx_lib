--- Zones: is the player in it, and tell me when that changes.
-- @author dop42
--
--   local watch = Lib.Zone.Watch(
--     { position = { x = -1442.2, y = 127.4, z = 18.0 }, radius = 8.0 },
--     { onEnter = function() ... end, onExit = function() ... end })
--
-- Built on `Open77.zones.contains`, which is the containment implementation
-- BOTH RUNTIMES SHARE. That matters more than it looks: a client and a server
-- that disagreed at a boundary would leave a place the player can stand where
-- the prompt appears but the grant is refused. Reimplementing a circle test
-- here would recreate exactly that bug, so this module does not own one.
--
-- NO PERMISSION IS NEEDED. `contains` is pure geometry and the position read is
-- ungated, so a consumer adds nothing to their manifest for this module.
--
-- A CLIENT ZONE IS PRESENTATION, NEVER PROOF. It runs on a machine the player
-- owns and can say anything. `onEnter` is a cue to draw something; a grant that
-- depends on standing somewhere must be re-tested on the server with the
-- server's own copy of the same definition.
--
-- ONE POLL THREAD FOR EVERY WATCH. Not one per zone: a thread per zone costs a
-- coroutine and a `Wait` each, and the client's per-resume instruction budget
-- is the consumer's to spend, not this library's to consume by the handful. The
-- thread stops itself when the last watch goes away and starts again with the
-- next one, so a consumer who never calls `Watch` pays nothing at all.

local Native = require('@opx_lib/client.native')
local Validate = require('@opx_lib/pure.validate')
local Result = require('@opx_lib/pure.result')
local Character = require('@opx_lib/client.character')

local Zone = {}

--- No manifest permission is needed for this module.
Zone.NEEDS = nil

--- How often the shared thread re-tests every watch, in milliseconds.
--
-- 250 ms is four tests a second: fast enough that a player walking at running
-- speed cannot cross a small zone unnoticed, slow enough to be invisible in a
-- budget. A caller who needs tighter timing is describing an interaction
-- prompt, which the platform has a purpose-built service for.
Zone.INTERVAL = 250

local watches = {}
local nextHandle = 0
local running = false

--- Is a point inside a zone?
--
-- REACHED DIRECTLY rather than through `Native.Call`, and this is the clearest
-- case for that rule in the library: `contains` answers a genuine boolean, so
-- `false` is an ANSWER -- the point is outside -- and the falsy-means-refused
-- convention would turn every negative test into an error. It is the same trap
-- `modules/result.lua` was written about, met in the wild.
-- @author dop42
-- @param definition table a zone definition
-- @param point table { x, y, z }
-- @param options table|nil grace, origin, rotation
-- @return table a Result carrying a boolean
function Zone.Contains(definition, point, options)
	local native, missing = Native.Reach('zones.contains')
	if native == nil then
		return Result.Err(missing, 'Open77.zones.contains is not available on this build')
	end

	local ok, inside, reason = pcall(native, definition, point, options)
	if not ok then return Result.Err('native_raised', tostring(inside)) end
	if inside == nil then
		-- Only nil is a refusal here. `false` never means "could not tell":
		-- the platform is explicit that it always means outside.
		return Result.Err(type(reason) == 'string' and reason or 'invalid_definition',
			'the zone definition or the point was refused')
	end

	return Result.Ok(inside == true)
end

--- Is the local player inside a zone, right now?
-- @author dop42
-- @param definition table
-- @param options table|nil
-- @return table a Result carrying a boolean
function Zone.Here(definition, options)
	local here = Character.Position()
	if not here.ok then return here end
	return Zone.Contains(definition, here.value, options)
end

--- Runs the shared poll until the last watch is removed.
local function poll()
	running = true

	CreateThread(function()
		while running do
			local here = Character.Position()
			if here.ok then
				for _, watch in pairs(watches) do
					local inside = Zone.Contains(watch.definition, here.value, watch.options)
					if inside.ok and inside.value ~= watch.inside then
						watch.inside = inside.value
						local edge = inside.value and watch.onEnter or watch.onExit
						-- Guarded: a consumer's handler that raises must not stop
						-- the shared thread, which every other watch depends on.
						if edge then pcall(edge, watch.handle) end
					end
				end
			end

			-- Never absent: a poll loop with no Wait exhausts the client's
			-- per-resume instruction budget, and the coroutine dies silently.
			Wait(Zone.INTERVAL)

			if next(watches) == nil then running = false end
		end
	end)
end

--- Calls `onEnter` and `onExit` as the local player crosses a zone's boundary.
--
-- The first test is deferred to the poll rather than run here, so a player who
-- is ALREADY inside when the watch is created still gets an `onEnter`. Doing it
-- the other way -- seeding `inside` from a test at creation time -- silently
-- skips the entry for every zone a player is standing in at resource start,
-- which is most of them after a reload.
-- @author dop42
-- @param definition table a zone definition
-- @param handlers table { onEnter, onExit, grace }
-- @return table a Result carrying a watch handle
function Zone.Watch(definition, handlers)
	if Validate.Table(definition, 64) == nil then
		return Result.Err('invalid_definition', 'a zone definition is a plain table')
	end
	if Validate.Table(handlers, 8) == nil then
		return Result.Err('invalid_handlers', 'pass { onEnter = ..., onExit = ... }')
	end
	if handlers.onEnter == nil and handlers.onExit == nil then
		return Result.Err('no_handlers', 'a watch with neither onEnter nor onExit does nothing')
	end
	for _, name in ipairs({ 'onEnter', 'onExit' }) do
		local held = handlers[name]
		if held ~= nil and type(held) ~= 'function' then
			return Result.Err('invalid_handlers', name .. ' is not a function')
		end
	end

	-- Checked once, here, rather than four times a second forever: a definition
	-- the platform refuses would otherwise fail silently on every poll.
	local valid = Zone.Contains(definition, { x = 0.0, y = 0.0, z = 0.0 })
	if not valid.ok then return valid end

	nextHandle = nextHandle + 1
	local handle = nextHandle

	watches[handle] = {
		handle = handle,
		definition = definition,
		options = handlers.grace and { grace = handlers.grace } or nil,
		onEnter = handlers.onEnter,
		onExit = handlers.onExit,
		-- `false` and not nil: the first poll inside the zone is then a real
		-- edge, which is what makes an already-inside player get an onEnter.
		inside = false,
	}

	if not running then poll() end
	return Result.Ok(handle)
end

--- Stops a watch. The shared thread stops itself once the last one goes.
-- @author dop42
-- @param handle any
-- @return table a Result
function Zone.Unwatch(handle)
	if watches[handle] == nil then
		return Result.Err('no_such_watch', 'that watch is not running')
	end
	watches[handle] = nil
	return Result.Ok(true)
end

--- How many watches are running. For a consumer's own diagnostics.
-- @author dop42
-- @return integer
function Zone.Count()
	local count = 0
	for _ in pairs(watches) do count = count + 1 end
	return count
end

return Zone
