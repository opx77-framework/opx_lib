--- Turning a value that came from somewhere else into one you can use.
-- @author dop42
--
-- Every function here answers the value or `nil`, and never raises. That shape
-- is the whole design: a caller writes
--
--   local slot = Lib.Validate.Integer(payload.slot, 1, 65535)
--   if slot == nil then return false, 'bad_request' end
--
-- and the refusal is the caller's to name, because the caller knows what the
-- value was for and this module does not.
--
-- WHY `nil` AND NOT A Result. These run on the hot path -- a payload has a dozen
-- fields and a handler validates all of them before doing anything -- and a
-- table per field per message is garbage the collector did not need. `Result` is
-- for an operation that can fail for several distinguishable reasons; this is
-- for "is this a slot number".
--
-- THE NUMERIC GUARDS REJECT NaN AND infinity, and that is the reason to use them
-- rather than `tonumber`. `tonumber('nan')` answers a number, `NaN < 1` is
-- false, `NaN > 65535` is false, and a range check written the obvious way lets
-- it through to become a table index that is never equal to itself. Every
-- comparison below is written so that NaN fails it.

-- `getmetatable` IS NOT IN THE OPEN77 CLIENT SANDBOX, and this line is what one
-- absent base global cost. `Validate.Table` called it, `Players.Nearby` calls
-- `Validate.Table`, and the name-tag pass calls `Players.Nearby` -- so every
-- pass raised `attempt to call a nil value (global 'getmetatable')`, the raise
-- unwound the scheduler job, and name tags stopped for the session. The wardrobe
-- died the same way and worse: its retry runs inside a `CreateThread`, and a
-- raise there unwinds the coroutine with NO error anywhere, which is why a
-- created character waited five minutes for a fitting room while the journal
-- said nothing at all. Two features, one missing global.
--
-- CAPTURED AT LOAD, which the rest of this library is forbidden from doing --
-- see the header of `client/native.lua`. The ban is about `Open77.*`, which does
-- not exist yet when an early module is imported and appears later. A BASE
-- global is the opposite: it is in the chunk's `_ENV` when the chunk loads or it
-- is never there at all, so reading it once is both correct and free. Reading an
-- absent global yields nil rather than raising, so this is safe on every host.
--
-- Absent, the check DEGRADES rather than refusing everything. Its purpose is
-- defensive -- "data from outside is plain, so a table carrying a metatable did
-- not come from outside" -- and on a host that cannot answer the question, the
-- honest behaviour is to stop asking it, not to reject every table and take the
-- caller's feature down with it. That is exactly the failure being fixed here.
local getmeta = getmetatable

local Validate = {}

--- A finite number within an inclusive range, or nil.
-- @author dop42
-- @param value any
-- @param low number
-- @param high number
-- @return number|nil
function Validate.Number(value, low, high)
	local number = tonumber(value)
	if number == nil then return nil end
	-- `number ~= number` is the NaN test: it is the only value unequal to
	-- itself, and the range comparisons below would both answer false for it.
	if number ~= number then return nil end
	if number == math.huge or number == -math.huge then return nil end
	if low ~= nil and number < low then return nil end
	if high ~= nil and number > high then return nil end
	return number
end

--- A whole number within an inclusive range, or nil.
--
-- A float that happens to be whole is accepted and narrowed -- `3.0` off a JSON
-- payload is the integer three, and refusing it would refuse every number a
-- WebUI ever sends. A float that is NOT whole is refused rather than rounded:
-- rounding a quantity the caller did not mean is how one item becomes two.
-- @author dop42
-- @param value any
-- @param low integer
-- @param high integer
-- @return integer|nil
function Validate.Integer(value, low, high)
	local number = Validate.Number(value, low, high)
	if number == nil then return nil end
	if number % 1 ~= 0 then return nil end
	return math.tointeger(number) or nil
end

--- A non-empty string no longer than `limit` bytes, or nil.
--
-- The limit is in BYTES and not characters, deliberately: it exists to bound
-- what reaches a buffer, a column or a log line, and a character count does not
-- bound any of those under UTF-8.
-- @author dop42
-- @param value any
-- @param limit integer
-- @return string|nil
function Validate.Text(value, limit)
	if type(value) ~= 'string' or value == '' then return nil end
	if type(limit) == 'number' and #value > limit then return nil end
	return value
end

--- A single word: letters, digits, underscore, hyphen and dot, or nil.
--
-- What this is for is an IDENTIFIER that arrived from outside and is about to be
-- used as one -- a key, a model name, a channel. The set is deliberately narrow:
-- no space, no slash, no control character, nothing that changes meaning when it
-- lands in a path, a format string or a log line.
-- @author dop42
-- @param value any
-- @param limit integer|nil
-- @return string|nil
function Validate.Word(value, limit)
	local text = Validate.Text(value, limit or 64)
	if text == nil then return nil end
	if text:match('^[%w_%-%.]+$') == nil then return nil end
	return text
end

--- One of a closed set, or nil.
--
-- `allowed` is a set (`{ trunk = true }`) or a list (`{ 'trunk', 'glovebox' }`);
-- both are accepted because both are how a closed set gets written in practice,
-- and making the caller remember which one this wanted is a worse API than
-- looking.
-- @author dop42
-- @param value any
-- @param allowed table
-- @return any|nil
function Validate.OneOf(value, allowed)
	if value == nil or type(allowed) ~= 'table' then return nil end
	if allowed[value] then return value end
	for index = 1, #allowed do
		if allowed[index] == value then return value end
	end
	return nil
end

--- A plain table with no more than `limit` entries, or nil.
--
-- The count is over `pairs` and not `#`: a payload from a page is a map as often
-- as a list, and `#` answers zero for one of those. A table with a metatable is
-- refused -- anything that arrived from outside is plain data, and one that is
-- not did not arrive from outside.
-- @author dop42
-- @param value any
-- @param limit integer|nil
-- @return table|nil
function Validate.Table(value, limit)
	if type(value) ~= 'table' then return nil end
	if getmeta ~= nil and getmeta(value) ~= nil then return nil end
	if limit == nil then return value end

	local count = 0
	for _ in pairs(value) do
		count = count + 1
		if count > limit then return nil end
	end
	return value
end

return Validate
