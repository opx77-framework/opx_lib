--- Lists, treated as lists.
-- @author dop42
--
-- `pure/table.lua` is about tables as a whole -- copying them, comparing them,
-- counting their keys. This is about the ORDERED part: the things a gameplay
-- resource does to a list of rows it just got back from somewhere.
--
-- EVERY FUNCTION ANSWERS A NEW LIST and never edits the one it was given,
-- except `Push` and `Remove`, which are named for mutation. A filter that
-- quietly emptied the caller's array is the kind of bug that surfaces three
-- frames later in an unrelated draw call.
--
-- NOTHING HERE RAISES on a value that is not a list: it answers an empty list.
-- These run on data that came off a wire as often as not, and a chain like
-- `Map(Filter(rows, f), g)` should degrade to empty rather than take down the
-- handler at whichever link got nil.

local Array = {}

--- The entries a test keeps, in order.
-- @author dop42
-- @param list table
-- @param test function (value, index) -> boolean
-- @return table
function Array.Filter(list, test)
	if type(list) ~= 'table' or type(test) ~= 'function' then return {} end

	local out = {}
	for index = 1, #list do
		local value = list[index]
		if test(value, index) then out[#out + 1] = value end
	end
	return out
end

--- Each entry through a function, in order.
-- @author dop42
-- @param list table
-- @param change function (value, index) -> any
-- @return table
function Array.Map(list, change)
	if type(list) ~= 'table' or type(change) ~= 'function' then return {} end

	local out = {}
	for index = 1, #list do
		out[index] = change(list[index], index)
	end
	return out
end

--- The first entry a test accepts, and its index.
--
-- Two returns rather than one, because the index is what a caller needs next
-- often enough -- to remove it, to replace it -- that finding it twice is the
-- common shape of the code this replaces.
-- @author dop42
-- @param list table
-- @param test function
-- @return any|nil, integer|nil
function Array.Find(list, test)
	if type(list) ~= 'table' or type(test) ~= 'function' then return nil end

	for index = 1, #list do
		local value = list[index]
		if test(value, index) then return value, index end
	end
	return nil
end

--- Whether any entry passes.
-- @author dop42
-- @param list table
-- @param test function
-- @return boolean
function Array.Any(list, test)
	return Array.Find(list, test) ~= nil
end

--- Whether every entry passes. An empty list passes, as it must.
-- @author dop42
-- @param list table
-- @param test function
-- @return boolean
function Array.All(list, test)
	if type(list) ~= 'table' or type(test) ~= 'function' then return false end

	for index = 1, #list do
		if not test(list[index], index) then return false end
	end
	return true
end

--- Folds the list into one value.
-- @author dop42
-- @param list table
-- @param step function (carried, value, index) -> any
-- @param initial any
-- @return any
function Array.Fold(list, step, initial)
	if type(list) ~= 'table' or type(step) ~= 'function' then return initial end

	local carried = initial
	for index = 1, #list do
		carried = step(carried, list[index], index)
	end
	return carried
end

--- A copy with the order reversed.
-- @author dop42
-- @param list table
-- @return table
function Array.Reverse(list)
	if type(list) ~= 'table' then return {} end

	local out, size = {}, #list
	for index = 1, size do out[index] = list[size - index + 1] end
	return out
end

--- A sorted COPY, so the caller's order survives.
--
-- `table.sort` sorts in place, which is the right default for the standard
-- library and the wrong one for a list that arrived from somewhere and may be
-- being read elsewhere.
-- @author dop42
-- @param list table
-- @param before function|nil
-- @return table
function Array.Sorted(list, before)
	if type(list) ~= 'table' then return {} end

	local out = {}
	for index = 1, #list do out[index] = list[index] end
	if before ~= nil then table.sort(out, before) else table.sort(out) end
	return out
end

--- A copy with duplicates dropped, first occurrence winning.
--
-- `by` derives the key to compare on, for rows that are tables: without it,
-- two rows describing the same thing are two different tables and neither is a
-- duplicate of the other.
-- @author dop42
-- @param list table
-- @param by function|nil (value) -> any
-- @return table
function Array.Unique(list, by)
	if type(list) ~= 'table' then return {} end

	local seen, out = {}, {}
	for index = 1, #list do
		local value = list[index]
		local key = by and by(value) or value
		if key ~= nil and not seen[key] then
			seen[key] = true
			out[#out + 1] = value
		end
	end
	return out
end

--- Entries grouped into lists under a derived key.
-- @author dop42
-- @param list table
-- @param by function (value) -> any
-- @return table
function Array.GroupBy(list, by)
	if type(list) ~= 'table' or type(by) ~= 'function' then return {} end

	local out = {}
	for index = 1, #list do
		local value = list[index]
		local key = by(value, index)
		if key ~= nil then
			out[key] = out[key] or {}
			local bucket = out[key]
			bucket[#bucket + 1] = value
		end
	end
	return out
end

--- Up to `count` entries from the front.
-- @author dop42
-- @param list table
-- @param count integer
-- @return table
function Array.Take(list, count)
	if type(list) ~= 'table' then return {} end

	local limit = math.min(tonumber(count) or 0, #list)
	local out = {}
	for index = 1, limit do out[index] = list[index] end
	return out
end

--- Appends to the list IN PLACE and answers its new length.
-- @author dop42
-- @param list table
-- @param value any
-- @return integer
function Array.Push(list, value)
	if type(list) ~= 'table' then return 0 end
	list[#list + 1] = value
	return #list
end

--- Removes the first entry equal to `value`, IN PLACE.
--
-- `table.remove` shifts everything after it, which is what keeps the list a
-- list -- setting the slot to nil instead leaves a hole that `#` and `ipairs`
-- both stop at, and that is the bug this function exists to avoid.
-- @author dop42
-- @param list table
-- @param value any
-- @return boolean whether anything was removed
function Array.Remove(list, value)
	if type(list) ~= 'table' then return false end

	for index = 1, #list do
		if list[index] == value then
			table.remove(list, index)
			return true
		end
	end
	return false
end

--- Whether the list holds a value.
-- @author dop42
-- @param list table
-- @param value any
-- @return boolean
function Array.Holds(list, value)
	if type(list) ~= 'table' then return false end

	for index = 1, #list do
		if list[index] == value then return true end
	end
	return false
end

return Array
