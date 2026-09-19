--- Translations, with the missing-key case made loud.
-- @author dop42
--
--   Lib.Locale.Load({ greet = 'Hello %s', items = '%d items' })
--   Lib.Locale.Get('greet', 'V')     --> 'Hello V'
--   Lib.Locale.Get('nope')           --> 'nope' , and a key you can see
--
-- Pure: no natives, no permission. State is a table of strings, and because a
-- library's state is PER CONSUMER VM, one resource's catalogue is never another
-- resource's. A consumer loads their own and cannot break anyone else's.
--
-- A MISSING KEY ANSWERS THE KEY, never an empty string. An empty string renders
-- as a gap nobody reports; the key itself renders as `shop.buy.confirm` on the
-- screen, which gets reported the first time anyone sees it. That is the whole
-- design decision in this module.
--
-- FORMATTING IS GUARDED. `('%d'):format('x')` raises, and a locale file is
-- exactly the kind of data that drifts out of step with its call sites. A
-- raised format would take down whatever was drawing the text, so a bad format
-- answers the untranslated key instead -- visibly wrong, never fatal.

local Validate = require('@opx_lib/pure.validate')

local Locale = {}

local strings = {}

--- Replaces the catalogue.
--
-- Copied key by key rather than kept by reference, so a caller mutating the
-- table they passed does not silently change what is on screen -- and so a
-- non-string value is refused at load, where it can be found, rather than at
-- the draw call.
-- @author dop42
-- @param catalogue table key -> string
-- @return integer how many entries were accepted
function Locale.Load(catalogue)
	strings = {}
	if type(catalogue) ~= 'table' then return 0 end

	local count = 0
	for key, value in pairs(catalogue) do
		if type(key) == 'string' and type(value) == 'string' then
			strings[key] = value
			count = count + 1
		end
	end
	return count
end

--- Adds or replaces one entry.
-- @author dop42
-- @param key string
-- @param value string
-- @return boolean whether it was accepted
function Locale.Set(key, value)
	if Validate.Text(key, 256) == nil or type(value) ~= 'string' then return false end
	strings[key] = value
	return true
end

--- The translation for a key, formatted with any arguments.
-- @author dop42
-- @param key string
-- @param ... any arguments for the format
-- @return string never nil
function Locale.Get(key, ...)
	if type(key) ~= 'string' then return '' end

	local line = strings[key]
	if line == nil then return key end
	if select('#', ...) == 0 then return line end

	local ok, formatted = pcall(string.format, line, ...)
	if not ok then return key end
	return formatted
end

--- Whether a key is in the catalogue. For a consumer's own start-up check.
-- @author dop42
-- @param key string
-- @return boolean
function Locale.Has(key)
	return type(key) == 'string' and strings[key] ~= nil
end

return Locale
