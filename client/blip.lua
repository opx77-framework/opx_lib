--- Map pins, which on this platform are the game's own.
-- @author dop42
--
--   local pin = Lib.Blip.Place({ x = 10, y = 20, z = 30 }, { label = 'Street race' })
--
-- Wraps `Open77.blips.*`. The consumer must declare `ui.vanilla.map`.
--
-- THESE ARE REAL CYBERPUNK MAPPINS, not a drawn overlay. Depending on the
-- vanilla profile behind the sprite, one blip can appear in the HUD, the
-- minimap and the world map at once -- which is a feature no overlay gets, and
-- the reason to use this rather than draw your own.
--
-- THE HANDLE IS A DECIMAL STRING, for the same reason a marker's is: it carries
-- a 64-bit generation handle, and a Lua number rounds that away past 2^53.
-- Never compare one numerically.
--
-- BLIPS ARE RESOURCE-OWNED, and the owner is the CONSUMER, because this code
-- runs in their VM. They are cleaned up automatically when the consumer stops,
-- so a resource that forgets to tidy up does not leave pins on the map. One
-- package cannot erase another's map state.
--
-- `routable` IS NOT DECORATION. A plain blip that you `Track` is selected, but
-- REDengine calculates no road path for it. Only a positional blip created with
-- `routable = true` uses the trusted custom-waypoint definition, and only that
-- one starts native GPS routing when tracked. Getting this wrong produces a
-- marked destination with no route and no error.

local Native = require('@opx_lib/client.native')
local Validate = require('@opx_lib/pure.validate')
local Result = require('@opx_lib/pure.result')

local Blip = {}

--- The manifest permission a consumer must declare to use this module.
Blip.NEEDS = 'ui.vanilla.map'

local function point(value)
	if Validate.Table(value, 8) == nil then return nil end
	local x = Validate.Number(value.x, -100000, 100000)
	local y = Validate.Number(value.y, -100000, 100000)
	local z = Validate.Number(value.z, -100000, 100000)
	if x == nil or y == nil or z == nil then return nil end
	return { x = x, y = y, z = z }
end

--- Merges options over a base spec, refusing to let options win the key the
--- caller's positional argument already decided.
local function specFrom(base, options, owned)
	if options == nil then return base end
	if Validate.Table(options, 16) == nil then return nil end

	for key, value in pairs(options) do
		if key ~= owned then base[key] = value end
	end
	return base
end

--- Creates a blip at a world position.
-- @author dop42
-- @param position table { x, y, z }
-- @param options table|nil sprite, label, icon, active, visibleThroughWalls, routable, range
-- @return table a Result carrying the handle string
function Blip.Place(position, options)
	local at = point(position)
	if at == nil then
		return Result.Err('invalid_position', 'position is not a finite { x, y, z }')
	end

	local spec = specFrom({ position = at }, options, 'position')
	if spec == nil then return Result.Err('invalid_options', 'blip options is not a plain table') end

	-- `entity` and `position` are exclusive at the native, and a spec carrying
	-- both is refused there with a reason that does not say which one to drop.
	spec.entity = nil
	return Native.Call('blips.create', Blip.NEEDS, spec)
end

--- Creates a blip that follows an entity.
-- @author dop42
-- @param entity any
-- @param options table|nil
-- @return table a Result carrying the handle string
function Blip.Follow(entity, options)
	if entity == nil then return Result.Err('invalid_entity', 'no entity given') end

	local spec = specFrom({ entity = entity }, options, 'entity')
	if spec == nil then return Result.Err('invalid_options', 'blip options is not a plain table') end

	spec.position = nil
	return Native.Call('blips.create', Blip.NEEDS, spec)
end

--- Patches a blip. Only the fields supplied change.
-- @author dop42
-- @param handle string
-- @param patch table
-- @return table a Result
function Blip.Move(handle, patch)
	if Validate.Text(handle, 64) == nil then
		return Result.Err('invalid_handle', 'no blip handle given')
	end
	if Validate.Table(patch, 16) == nil then
		return Result.Err('invalid_patch', 'blip patch is not a plain table')
	end
	return Native.Call('blips.update', Blip.NEEDS, handle, patch)
end

--- Reads one blip this consumer owns.
-- @author dop42
-- @param handle string
-- @return table a Result
function Blip.Get(handle)
	if Validate.Text(handle, 64) == nil then
		return Result.Err('invalid_handle', 'no blip handle given')
	end
	return Native.Call('blips.get', Blip.NEEDS, handle)
end

--- Switches a blip on or off without removing it.
--
-- Cheaper than remove-and-recreate, and it keeps the handle valid -- which
-- matters for anything that toggles with distance or time of day.
-- @author dop42
-- @param handle string
-- @param active boolean
-- @return table a Result
function Blip.SetActive(handle, active)
	if Validate.Text(handle, 64) == nil then
		return Result.Err('invalid_handle', 'no blip handle given')
	end
	return Native.Call('blips.setActive', Blip.NEEDS, handle, active == true)
end

--- Selects a blip as the vanilla tracked destination.
--
-- Starts native GPS routing only if the blip was created `routable = true`; see
-- the header. There is one tracked destination for the whole game, so tracking
-- takes it from whoever had it.
-- @author dop42
-- @param handle string
-- @return table a Result
function Blip.Track(handle)
	if Validate.Text(handle, 64) == nil then
		return Result.Err('invalid_handle', 'no blip handle given')
	end
	return Native.Call('blips.track', Blip.NEEDS, handle)
end

--- Removes one blip.
-- @author dop42
-- @param handle string
-- @return table a Result
function Blip.Remove(handle)
	if Validate.Text(handle, 64) == nil then
		return Result.Err('invalid_handle', 'no blip handle given')
	end
	return Native.Call('blips.remove', Blip.NEEDS, handle)
end

--- Every blip this consumer owns.
-- @author dop42
-- @return table a Result carrying an array
function Blip.List()
	return Native.Call('blips.list', Blip.NEEDS)
end

--- Removes EVERY blip the consumer owns, this module's or not.
-- @author dop42
-- @return table a Result
function Blip.Clear()
	return Native.Call('blips.clear', Blip.NEEDS)
end

return Blip
