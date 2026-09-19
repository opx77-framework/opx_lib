--- A result: something answered, or a reason it was not.
-- @author dop42
--
-- Lua's own convention is `value, reason`, and it breaks in exactly one place:
-- a function that legitimately answers `nil` or `false`. `Store.Read` answering
-- `nil` means "no row" and `nil, 'query-failed'` means the database is down, and
-- a caller writing `if not value then` cannot tell them apart. Every wrapper
-- that has ever tried has ended up checking the REASON to decide whether the
-- VALUE was real, which is the tail wagging the dog.
--
-- A Result answers that by making the question `ok` rather than `value`:
--
--   local read = Lib.Result.Ok(nil)
--   read.ok      --> true
--   read.value   --> nil, and that is an answer
--
-- IT IS A PLAIN TABLE, with no metatable and no methods, and that is not
-- laziness. A Result frequently crosses an export boundary, where only plain
-- data survives -- `exports.other:thing()` copies its arguments and results, so
-- a metatable would be silently stripped and a method call on the far side would
-- fail on a table that looks right. Keeping it plain means the same value works
-- in a VM, across `require`, and across an export.
--
-- `error` IS A STABLE CODE, never a sentence: a catalogue key, a wire code,
-- something a caller can branch on and a locale can translate. `detail` is the
-- human half and may be anything -- it is for a log line, never for a decision.

local Result = {}

--- An answer. `value` may be nil: that is what `ok` is for.
-- @author dop42
-- @param value any
-- @return table
function Result.Ok(value)
	return { ok = true, value = value }
end

--- A refusal. `code` is stable and branchable; `detail` is for the journal.
-- @author dop42
-- @param code string
-- @param detail any|nil
-- @return table
function Result.Err(code, detail)
	return { ok = false, error = code, detail = detail }
end

--- Whether a value is a Result at all.
--
-- Checked by shape rather than by identity, because a Result that crossed an
-- export is a copy: it is equal in content and shares nothing else with the one
-- that was sent.
-- @author dop42
-- @param value any
-- @return boolean
function Result.Is(value)
	return type(value) == 'table' and type(value.ok) == 'boolean'
end

--- The value of a successful result, or `fallback` for a failed one.
--
-- For a caller that has a sensible default and does not care why: a missing row
-- and a broken query both become the default, deliberately. A caller that needs
-- to tell them apart reads `ok` instead.
-- @author dop42
-- @param result table
-- @param fallback any|nil
-- @return any
function Result.Or(result, fallback)
	if Result.Is(result) and result.ok then return result.value end
	return fallback
end

--- Applies `fn` to a successful value, passing a failure straight through.
--
-- The point is that a chain of these carries the FIRST failure to the end
-- untouched, so a caller writes the happy path once and checks `ok` once. `fn`
-- is not called at all on a failure, so it may assume its argument is real.
--
-- A raise inside `fn` becomes a failure rather than unwinding the caller: a
-- library that lets a mapper blow up the stack it was called on is a library
-- that has to be wrapped everywhere it is used.
-- @author dop42
-- @param result table
-- @param fn function
-- @return table
function Result.Map(result, fn)
	if not Result.Is(result) then return Result.Err('not-a-result') end
	if not result.ok then return result end
	if type(fn) ~= 'function' then return Result.Err('not-a-function') end

	local ran, answered = pcall(fn, result.value)
	if not ran then return Result.Err('map-raised', tostring(answered)) end
	return Result.Ok(answered)
end

return Result
