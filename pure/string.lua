--- String helpers, weighted towards text that arrived from somewhere else.
-- @author dop42

local Str = {}

--- Whitespace off both ends.
--
-- `^%s*(.-)%s*$` is the idiom and it backtracks; this walks from each end
-- instead, which matters because trimming runs on every line of chat and every
-- field of every form.
-- @author dop42
-- @param value any
-- @return string
function Str.Trim(value)
	if type(value) ~= 'string' then return '' end
	local from = value:find('%S')
	if from == nil then return '' end
	local to = #value
	while to > from and value:sub(to, to):match('%s') do to = to - 1 end
	return value:sub(from, to)
end

--- A string with every control character replaced, capped, with an ellipsis when
--- it was cut.
--
-- THE SECURITY FUNCTION OF THIS MODULE, and the reason it is not just a `sub`. A
-- newline inside a value that reaches a format string forges a whole log line:
--
--   Open77.log.warn(('player said %s'):format(said))
--
-- with `said` carrying "\n[2026-01-01] [info] player was banned" writes two
-- lines, and the second is indistinguishable from one the runtime wrote. Every
-- value off a wire goes through here before it reaches a journal, a chat line or
-- a WebUI payload.
--
-- The replacement is a space rather than nothing: joining two words that were on
-- two lines invents a word that was never typed.
-- @author dop42
-- @param value any
-- @param limit integer|nil
-- @param ellipsis string|nil
-- @return string
function Str.Clean(value, limit, ellipsis)
	if type(value) ~= 'string' then return '' end

	-- `%c` is every control character: newline, carriage return, tab, escape and
	-- the rest. Not a blacklist of the ones seen so far.
	local clean = value:gsub('%c', ' ')
	if type(limit) ~= 'number' or #clean <= limit then return clean end

	local tail = type(ellipsis) == 'string' and ellipsis or ''
	local keep = limit - #tail
	if keep < 0 then keep = 0 end
	return clean:sub(1, keep) .. tail
end

--- Splits on a single-character separator, keeping empty fields.
--
-- Empty fields are KEPT because the caller asked for a split and not for a list
-- of words: `a,,b` is three fields, and a parser that silently loses the middle
-- one mis-numbers everything after it. A caller who wants words filters them.
--
-- The separator is one character and is matched literally, so a `.` or a `-`
-- behaves as typed rather than as a pattern.
-- @author dop42
-- @param value any
-- @param separator string
-- @return string[]
function Str.Split(value, separator)
	if type(value) ~= 'string' then return {} end
	if type(separator) ~= 'string' or #separator ~= 1 then return { value } end

	local out, from = {}, 1
	while true do
		local at = value:find(separator, from, true)
		if at == nil then
			out[#out + 1] = value:sub(from)
			return out
		end
		out[#out + 1] = value:sub(from, at - 1)
		from = at + 1
	end
end

--- Whether a string begins with a prefix, without allocating one.
-- @author dop42
-- @param value any
-- @param prefix string
-- @return boolean
function Str.Starts(value, prefix)
	if type(value) ~= 'string' or type(prefix) ~= 'string' then return false end
	return value:sub(1, #prefix) == prefix
end

--- A short, stable signature of a string, for "has this changed".
--
-- FNV-1a, 32-bit. It is NOT a checksum and never a security boundary: it exists
-- so a sender can skip a message whose payload is identical to the last one, and
-- a collision there costs one skipped redraw rather than anything that matters.
-- Use it to compare, never to prove.
--
-- Written with integer arithmetic masked to 32 bits, because Lua 5.4 integers
-- are 64-bit and an unmasked multiply walks off into the sign.
-- @author dop42
-- @param value any
-- @return integer
function Str.Signature(value)
	if type(value) ~= 'string' then return 0 end

	local hash = 2166136261
	for index = 1, #value do
		hash = hash ~ value:byte(index)
		hash = (hash * 16777619) & 0xFFFFFFFF
	end
	return hash
end

return Str
