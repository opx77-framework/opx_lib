--- Display text: measured and cut in CHARACTERS, not bytes.
-- @author dop42
--
--   Lib.Text.Clean(typed, 24, '...')
--
-- WHY THIS IS NOT `String`, AND WHY BOTH EXIST. They bound different things,
-- and the unit is the whole difference.
--
--   `String.Clean` bounds BYTES. It is for a log line, a database column, a
--   wire payload -- things whose limit is a buffer, and a character count does
--   not bound a buffer under UTF-8.
--
--   `Text.Clean` bounds CHARACTERS. It is for a label, a name plate, a chat
--   line -- things whose limit is the width of a box, where a byte count cuts
--   a name with an accent in it several letters early and looks like a bug.
--
-- A caller who picks the wrong one gets a label that is mysteriously short, or
-- a column that overflows on the first player with a non-ASCII name. Naming
-- them for the unit they bound is the cheapest way to make the choice visible.
--
-- NOTHING HERE SPLITS A CHARACTER. Continuation bytes are 0x80..0xBF, so a byte
-- outside that range opens a new character, and every cut below is taken only
-- there. A cut through the middle of a multi-byte character produces a string
-- that is not valid UTF-8, which some renderers draw as a replacement glyph and
-- others refuse entirely.

local Text = {}

--- Byte length of the first `maximum` characters.
--
-- The scan is bounded at four bytes a character BEFORE it starts, so cutting a
-- long string to a short limit costs the limit rather than the string. Four is
-- the most bytes a UTF-8 character can occupy, so the bound can never cut early.
-- @author dop42
-- @param text string
-- @param maximum integer characters, not bytes
-- @return integer
function Text.Span(text, maximum)
	if type(text) ~= 'string' then return 0 end

	local size = #text
	local ceiling = (tonumber(maximum) or 0) * 4
	if size > ceiling then size = ceiling end

	local characters, index = 0, 1
	while index <= size do
		local byte = text:byte(index)
		if byte < 0x80 or byte > 0xBF then
			if characters >= maximum then return index - 1 end
			characters = characters + 1
		end
		index = index + 1
	end
	return size
end

--- How many characters a string holds.
--
-- `#value` answers bytes, which is the wrong answer for every name with an
-- accent in it, and the one people reach for by reflex.
-- @author dop42
-- @param value any
-- @return integer
function Text.Length(value)
	if type(value) ~= 'string' then return 0 end

	local characters = 0
	for index = 1, #value do
		local byte = value:byte(index)
		if byte < 0x80 or byte > 0xBF then characters = characters + 1 end
	end
	return characters
end

--- Control characters replaced, cut to `maximum` characters, ellipsis if cut.
--
-- A number is accepted and stringified, because a display helper is called on
-- whatever a caller has to show and refusing `42` would be pedantry.
-- @author dop42
-- @param value any
-- @param maximum integer characters, not bytes
-- @param ellipsis string|nil appended when the text was cut
-- @return string|nil
function Text.Clean(value, maximum, ellipsis)
	if value == nil then return nil end
	if type(value) == 'number' then value = tostring(value) end
	if type(value) ~= 'string' then return nil end

	-- `%c` is every control character, not a blacklist of the ones seen so far.
	-- A space and not nothing: joining two words that were on two lines invents
	-- a word nobody typed.
	local clean = value:gsub('%c', ' ')

	-- A byte length inside the limit is a character length inside it too, since
	-- a character is at least one byte. Cheap check first, on the common path.
	if #clean <= maximum then return clean end

	local cut = Text.Span(clean, maximum)
	if cut >= #clean then return clean end
	return clean:sub(1, cut) .. (ellipsis or '')
end

--- Cuts to a byte limit without splitting a character.
--
-- The one place both units meet: the limit is a buffer, so it is in bytes, but
-- the cut still has to land on a character boundary or the result is not valid
-- UTF-8. Walks back while the byte that would FOLLOW the cut is a continuation.
-- @author dop42
-- @param text string
-- @param limit integer bytes to keep
-- @return string
function Text.Bytes(text, limit)
	if type(text) ~= 'string' then return '' end
	if #text <= limit then return text end

	local cut = limit
	while cut > 0 do
		local following = text:byte(cut + 1)
		if following == nil or following < 0x80 or following > 0xBF then break end
		cut = cut - 1
	end
	return text:sub(1, cut)
end

--- A lower-cased name of letters, digits, underscores and hyphens, or nil.
--
-- For turning something a person typed into something usable as a key. Refuses
-- rather than mangles: a slug that silently dropped half the input would key
-- two different names to the same row.
-- @author dop42
-- @param value any
-- @param limit integer|nil bytes, default 64
-- @return string|nil
function Text.Slug(value, limit)
	if type(value) ~= 'string' then return nil end

	local slug = value:lower():gsub('%s+', '-')
	if slug == '' or #slug > (limit or 64) then return nil end
	if slug:match('^[%w_%-]+$') == nil then return nil end
	return slug
end

--- Joins the words from one position on into a sentence.
--
-- What a chat command wants: `/me walks in slowly` is one message, not four
-- arguments, and every command that forgets this drops everything after the
-- first space.
-- @author dop42
-- @param words table a list of strings
-- @param first integer|nil the index to start at, default 1
-- @return string
function Text.Rest(words, first)
	if type(words) ~= 'table' then return '' end

	local held = {}
	for index = (first or 1), #words do
		held[#held + 1] = tostring(words[index])
	end
	return table.concat(held, ' ')
end

--- Reads on/off and their synonyms; nil when the value says neither.
--
-- nil and not false, so a caller can tell "they asked for off" from "they did
-- not say" -- which is the difference between setting a flag and leaving it.
-- @author dop42
-- @param value any
-- @return boolean|nil
function Text.Switch(value)
	if type(value) == 'boolean' then return value end
	if type(value) ~= 'string' then return nil end

	local word = value:lower()
	if word == 'on' or word == 'true' or word == '1' or word == 'yes' then return true end
	if word == 'off' or word == 'false' or word == '0' or word == 'no' then return false end
	return nil
end

return Text
