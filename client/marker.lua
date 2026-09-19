--- World markers, created and removed safely.
-- @author dop42
--
--   local made = Lib.Marker.Place({ x = -1442.2, y = 127.4, z = 18.0 }, { radius = 1.5 })
--   if made.ok then Lib.Marker.Remove(made.value) end
--
-- Wraps `Open77.markers.*`. The consumer must declare `world.markers`.
--
-- THE HANDLE IS A DECIMAL STRING, not a number, and that is load-bearing: it
-- preserves the full 64-bit identity of the marker, which a Lua number would
-- round away past 2^53. Nothing here converts it, compares it numerically or
-- does arithmetic on it, and a consumer must not either.
--
-- MARKERS ARE RESOURCE-OWNED, and the owner is the CONSUMER, because this code
-- runs in their VM. `Marker.Clear()` therefore removes every marker the
-- consumer owns -- including ones they created without this module. That is the
-- right behaviour for a resource shutting down and the wrong one to reach for
-- casually, so it is named for what it does rather than given a softer word.

local Native = require('@opx_lib/client.native')
local Validate = require('@opx_lib/pure.validate')
local Result = require('@opx_lib/pure.result')

local Marker = {}

--- The manifest permission a consumer must declare to use this module.
Marker.NEEDS = 'world.markers'

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

--- Creates a marker and answers its handle.
-- @author dop42
-- @param position table { x, y, z }
-- @param options table|nil shape, style, radius, maxDistance, minDistance, visible
-- @return table a Result carrying the handle string
function Marker.Place(position, options)
	local at = point(position)
	if at == nil then
		return Result.Err('invalid_position', 'position is not a finite { x, y, z }')
	end

	local spec = { position = at }
	if options ~= nil then
		if Validate.Table(options, 16) == nil then
			return Result.Err('invalid_options', 'marker options is not a plain table')
		end
		for key, value in pairs(options) do
			-- `position` is the one field this function owns. Letting options
			-- carry a second one would make which of the two wins a coin toss.
			if key ~= 'position' then spec[key] = value end
		end
	end

	return Native.Call('markers.create', Marker.NEEDS, spec)
end

--- Patches a marker. Only the fields supplied change.
-- @author dop42
-- @param handle string
-- @param patch table
-- @return table a Result
function Marker.Move(handle, patch)
	if Validate.Text(handle, 64) == nil then
		return Result.Err('invalid_handle', 'no marker handle given')
	end
	if Validate.Table(patch, 16) == nil then
		return Result.Err('invalid_patch', 'marker patch is not a plain table')
	end
	return Native.Call('markers.update', Marker.NEEDS, handle, patch)
end

--- Removes one marker.
-- @author dop42
-- @param handle string
-- @return table a Result
function Marker.Remove(handle)
	if Validate.Text(handle, 64) == nil then
		return Result.Err('invalid_handle', 'no marker handle given')
	end
	return Native.Call('markers.remove', Marker.NEEDS, handle)
end

--- Removes EVERY marker the consumer owns, this module's or not.
-- @author dop42
-- @return table a Result
function Marker.Clear()
	return Native.Call('markers.clear', Marker.NEEDS)
end

return Marker
