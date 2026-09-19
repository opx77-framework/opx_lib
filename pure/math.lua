--- Arithmetic a gameplay resource writes over and over.
-- @author dop42
--
-- Pure: no natives, no permission, no state. Every function is guarded the same
-- way `Validate` is, because these run on values that came off a wire as often
-- as not, and a NaN reaching a distance comparison makes every branch false.

local Maths = {}

--- Holds a number inside a range.
-- @author dop42
-- @param value number
-- @param low number
-- @param high number
-- @return number
function Maths.Clamp(value, low, high)
	local number = tonumber(value)
	if number == nil or number ~= number then return low end
	if number < low then return low end
	if number > high then return high end
	return number
end

--- Rounds to a number of decimal places, away from zero at the halfway point.
--
-- `math.floor(n + 0.5)` is the usual one-liner and it is wrong for negatives:
-- it rounds -2.5 to -2, so a symmetric pair of offsets stops being symmetric.
-- @author dop42
-- @param value number
-- @param places integer|nil default 0
-- @return number
function Maths.Round(value, places)
	local number = tonumber(value)
	if number == nil or number ~= number then return 0 end

	local scale = 10 ^ (tonumber(places) or 0)
	if number < 0 then return -math.floor(-number * scale + 0.5) / scale end
	return math.floor(number * scale + 0.5) / scale
end

--- Linear interpolation between two numbers.
-- `amount` is clamped, so a caller feeding it an unclamped elapsed/duration
-- ratio cannot overshoot the target and then come back.
-- @author dop42
-- @param from number
-- @param to number
-- @param amount number 0..1
-- @return number
function Maths.Lerp(from, to, amount)
	local start, finish = tonumber(from), tonumber(to)
	if start == nil or finish == nil then return 0 end
	return start + (finish - start) * Maths.Clamp(amount, 0, 1)
end

--- The distance between two { x, y, z } points.
--
-- Answers nil for a malformed point rather than 0, because 0 is "they are in
-- the same place" and a caller comparing against a radius would treat a broken
-- read as the closest possible thing.
-- @author dop42
-- @param left table
-- @param right table
-- @return number|nil
function Maths.Distance(left, right)
	if type(left) ~= 'table' or type(right) ~= 'table' then return nil end

	local dx = tonumber(right.x or 0) - tonumber(left.x or 0)
	local dy = tonumber(right.y or 0) - tonumber(left.y or 0)
	local dz = tonumber(right.z or 0) - tonumber(left.z or 0)
	if dx ~= dx or dy ~= dy or dz ~= dz then return nil end

	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

--- The distance between two points, ignoring height.
--
-- The one a gameplay check usually wants: a shop counter does not care that the
-- player is on the floor above, but a 3-D distance does, and the difference is
-- how a prompt appears through a ceiling.
-- @author dop42
-- @param left table
-- @param right table
-- @return number|nil
function Maths.Distance2D(left, right)
	if type(left) ~= 'table' or type(right) ~= 'table' then return nil end
	return Maths.Distance({ x = left.x, y = left.y, z = 0 }, { x = right.x, y = right.y, z = 0 })
end

--- Whether two points are within `radius` of each other, ignoring height.
-- @author dop42
-- @param left table
-- @param right table
-- @param radius number
-- @return boolean
function Maths.Near(left, right, radius)
	local apart = Maths.Distance2D(left, right)
	local limit = tonumber(radius)
	if apart == nil or limit == nil then return false end
	return apart <= limit
end

return Maths
