--- Asking the world three questions: what is on this line, what is around me,
--- and where is the ground.
-- @author dop42
--
--   local hit = Lib.World.Ray(from, to)
--   if hit.ok and hit.value.hit then print(hit.value.material) end
--
-- Wraps `Open77.world.*`. The consumer must declare `world.query`.
--
-- THESE RUN SYNCHRONOUSLY ON THE GAME THREAD, one or two engine calls each.
-- That is the whole cost model and it decides how they may be used: a raycast
-- in a tick is a raycast every frame, and the client's per-resume instruction
-- budget is the consumer's to spend. Nothing here starts a thread or caches on
-- the caller's behalf -- a helper that quietly memoised would be wrong the
-- first time the player moved.
--
-- `nearby` IS CENTRED ON THE LOCAL PLAYER AND CANNOT BE MOVED. The engine's
-- search takes a source object, not a point, so "look around over there" is not
-- a thing this API can do -- the platform's own advice is to stand there. That
-- is stated here because the obvious `origin` argument is conspicuously absent
-- and a caller will otherwise go looking for it. `Lib.Players.Nearby` DOES take
-- an origin, because it is a different search over replicated positions.
--
-- A MISS IS NOT A FAILURE. `Ray` answers Ok with `hit = false` when the line
-- crossed nothing: that is an answer about the world, and turning it into an
-- error would make every clear line of sight an exception to handle.

local Native = require('@opx_lib/client.native')
local Validate = require('@opx_lib/pure.validate')
local Result = require('@opx_lib/pure.result')

local World = {}

--- The manifest permission a consumer must declare to use this module.
World.NEEDS = 'world.query'

--- The engine's ceiling on a search radius, in metres.
World.MAX_RADIUS = 1000

--- A finite { x, y, z }, rebuilt so no extra key rides along, or nil.
local function point(value)
	if Validate.Table(value, 8) == nil then return nil end
	local x = Validate.Number(value.x, -100000, 100000)
	local y = Validate.Number(value.y, -100000, 100000)
	local z = Validate.Number(value.z, -100000, 100000)
	if x == nil or y == nil or z == nil then return nil end
	return { x = x, y = y, z = z }
end

--- Traces a ray between two points and answers the nearest blocking surface.
--
-- `options.entities = true` also attributes the hit to an object when the ray
-- stopped on one. It is off by default because it is not free: the entity is
-- NOT read out of the trace, which carries none -- it is found by running the
-- same object search `nearest` uses. So asking for it turns one engine call
-- into two, and a hit beyond 250 m cannot be attributed at all.
-- @author dop42
-- @param from table { x, y, z }
-- @param to table { x, y, z }
-- @param options table|nil { static, dynamic, entities }
-- @return table a Result carrying { hit, position, normal, material, distance, entity? }
function World.Ray(from, to, options)
	local start, finish = point(from), point(to)
	if start == nil then return Result.Err('invalid_from', 'from is not a finite { x, y, z }') end
	if finish == nil then return Result.Err('invalid_to', 'to is not a finite { x, y, z }') end
	if options ~= nil and Validate.Table(options, 8) == nil then
		return Result.Err('invalid_options', 'ray options is not a plain table')
	end

	return Native.Call('world.raycast', World.NEEDS, start, finish, options)
end

--- Whether the line between two points is blocked, as a plain boolean.
--
-- The question almost every caller of `Ray` actually had. Answers false when
-- the read failed as well as when the line is clear, which is the safe value
-- for the thing this is used for: a prompt that appears through a wall is worse
-- than one that does not appear.
-- @author dop42
-- @param from table
-- @param to table
-- @return boolean
function World.Blocked(from, to)
	local traced = World.Ray(from, to)
	if not traced.ok then return false end
	return traced.value.hit == true
end

--- Every object within a radius of the LOCAL PLAYER, nearest first.
--
-- `filter` narrows by class (`player`, `puppet`, `sensor`, `device`, `other`)
-- or widens by attitude and state (`friendly`, `hostile`, `neutral`, `alive`,
-- `dead`, `turnedOn`, `turnedOff`, `quickHackable`). A name, a list, or a mask.
--
-- Each row answers two separate questions, and confusing them is the mistake
-- this comment exists to prevent. WHAT IS IT: `kind` is refined by ownership --
-- an Open77 body is `npc`, a vanilla crowd body is `populationNpc` -- and
-- `family` is the unrefined answer for a caller who means "is this a ped at
-- all". WHOSE IS IT: exactly one of `playerId`, `vehicleId`, `npcId` when
-- Open77 owns it, and none of them when it does not. A row with no identity is
-- local scenery: nothing replicates it, every client sees a different one, and
-- it can be gone next frame. Never send one to the server as if it named a
-- thing the server knows.
-- @author dop42
-- @param radius number metres, 0 < r <= 1000
-- @param filter string|table|number|nil
-- @return table a Result carrying an array of rows
function World.Nearby(radius, filter)
	local metres = Validate.Number(radius, 0.01, World.MAX_RADIUS)
	if metres == nil then
		return Result.Err('invalid_radius',
			('radius is not a number in 0..%d'):format(World.MAX_RADIUS))
	end
	return Native.Call('world.nearby', World.NEEDS, metres, filter)
end

--- The closest object within a radius of the local player, or a refusal.
--
-- Nothing found is `not_found` and not an empty Ok: the caller wanted one
-- object, and an Ok carrying nil would put the nil check back exactly where
-- `Result` was meant to remove it.
-- @author dop42
-- @param radius number
-- @param filter string|table|number|nil
-- @return table a Result carrying one row
function World.Nearest(radius, filter)
	local metres = Validate.Number(radius, 0.01, World.MAX_RADIUS)
	if metres == nil then
		return Result.Err('invalid_radius',
			('radius is not a number in 0..%d'):format(World.MAX_RADIUS))
	end

	local found = Native.Call('world.nearest', World.NEEDS, metres, filter)
	if not found.ok then
		-- The native answers nil for "nothing there", which `Native.Call` cannot
		-- tell from a refusal. A refusal carries a reason; absence does not.
		if found.error == 'refused' then
			return Result.Err('not_found', 'nothing within the radius matched')
		end
		return found
	end
	return found
end

--- The height of the static ground below a point, by a downward ray.
-- @author dop42
-- @param position table { x, y, z }
-- @param options table|nil
-- @return table a Result carrying a number
function World.GroundZ(position, options)
	local at = point(position)
	if at == nil then
		return Result.Err('invalid_position', 'position is not a finite { x, y, z }')
	end
	return Native.Call('world.groundZ', World.NEEDS, at, options)
end

return World
