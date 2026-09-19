--- Table helpers, and the one that matters is the copy.
-- @author dop42

local Table = {}

--- A deep copy with no shared reference to the original.
--
-- WHY A LIBRARY NEEDS THIS AT ALL. A resource that hands a caller one of its own
-- tables has handed them a handle on its state: the caller keeps it, mutates it
-- three ticks later, and the owner's copy changes with no assignment anywhere
-- near the bug. Across `require` this is a live reference, so it really happens;
-- across an export it does not, because exports copy -- which means the same
-- code is safe one way and unsafe the other, and the only way to stop caring is
-- to copy at the boundary.
--
-- CYCLES ARE HANDLED. `seen` maps an original to its copy, so a table that
-- points at itself -- or two that point at each other -- comes out the same
-- shape rather than recursing until the stack ends. The parameter is internal;
-- a caller passes one argument.
--
-- A metatable is NOT copied, and neither is a key that is a table. Both would
-- make this a different function: the first shares behaviour the copy was meant
-- to break, and the second has no well-defined answer.
-- @author dop42
-- @param value any
-- @param seen table|nil
-- @return any
function Table.Copy(value, seen)
	if type(value) ~= 'table' then return value end

	seen = seen or {}
	if seen[value] then return seen[value] end

	local copy = {}
	seen[value] = copy
	for key, held in pairs(value) do
		copy[key] = Table.Copy(held, seen)
	end
	return copy
end

--- Whether two values are the same data, to any depth.
--
-- By CONTENT and never by identity, which is the only question worth asking
-- about a value that crossed an export: the copy that arrives shares nothing
-- with the one that was sent, so `==` is always false and always unhelpful.
--
-- Cycles are not handled here and the omission is deliberate: a comparison walks
-- both sides at once, so guarding it costs a table per call on the hot path to
-- answer a question about values that, in this runtime, come off a wire and
-- cannot contain a cycle.
-- @author dop42
-- @param left any
-- @param right any
-- @return boolean
function Table.Same(left, right)
	if left == right then return true end
	if type(left) ~= 'table' or type(right) ~= 'table' then return false end

	for key, held in pairs(left) do
		if not Table.Same(held, right[key]) then return false end
	end
	for key in pairs(right) do
		if left[key] == nil then return false end
	end
	return true
end

--- Every key, sorted, so a walk is the same twice.
--
-- `pairs` has no order and is not required to answer the same order twice in one
-- process. Anything a person reads -- a diagnostic, a log line, a signature
-- compared against the last one -- has to walk keys in a fixed order or it
-- reports a change that did not happen. Mixed key types sort by type name first
-- so the comparison never raises.
-- @author dop42
-- @param value table
-- @return any[]
function Table.Keys(value)
	if type(value) ~= 'table' then return {} end

	local keys = {}
	for key in pairs(value) do keys[#keys + 1] = key end
	table.sort(keys, function(left, right)
		local leftType, rightType = type(left), type(right)
		if leftType ~= rightType then return leftType < rightType end
		if leftType == 'number' or leftType == 'string' then return left < right end
		return tostring(left) < tostring(right)
	end)
	return keys
end

--- How many entries a table holds, counting map keys as well as list ones.
-- `#` answers zero for a map, which is the wrong answer often enough to be worth
-- a function that never gives it.
-- @author dop42
-- @param value table
-- @return integer
function Table.Count(value)
	if type(value) ~= 'table' then return 0 end
	local count = 0
	for _ in pairs(value) do count = count + 1 end
	return count
end

--- A shallow, read-only view: reading works, writing raises.
--
-- For handing a caller a catalogue or a configuration without copying it on
-- every call. It is SHALLOW -- a nested table reached through this one is still
-- writable -- because a deep freeze allocates a proxy per table and this exists
-- to avoid allocating.
--
-- The raise is the point. A silent no-op write is worse than the sharing it
-- prevents: the caller believes the value changed, and nothing says otherwise
-- until something far away reads the old one.
-- @author dop42
-- @param value table
-- @return table
function Table.Freeze(value)
	if type(value) ~= 'table' then return value end
	return setmetatable({}, {
		__index = value,
		__len = function() return #value end,
		__pairs = function() return pairs(value) end,
		__newindex = function(_, key)
			error(('opx_lib: %s is read-only'):format(tostring(key)), 2)
		end,
	})
end

return Table
