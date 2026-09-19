--- Which permissions a consumer has to declare, answered before they find out.
-- @author dop42
--
--   print(Lib.Permission.Line())
--   --> permissions { "input.actions", "network.events", "ui.vanilla.hud", "world.markers" }
--
-- THE PROBLEM THIS SOLVES. Permissions are checked against the CALLING
-- resource's manifest, and a library call runs in the caller's VM -- so a
-- consumer importing `Lib.Marker` must declare `world.markers` themselves, and
-- nothing tells them so until a marker silently fails to appear, at run time,
-- from a line inside code they did not write. The failure is late, quiet, and
-- points at the wrong file.
--
-- So the library states its requirements as DATA. Every module that needs a
-- permission carries `NEEDS`; this module reads those fields and answers the
-- manifest line to paste. Nothing is duplicated: a new wrapper module declares
-- `NEEDS` once and appears here automatically, which is the only arrangement
-- that cannot drift.
--
-- IT CANNOT CHECK, ONLY TELL. There is no native that answers "does my manifest
-- declare X" -- the runtime knows, but it does not say -- so a real preflight
-- is impossible and pretending otherwise would be worse than this. What is left
-- is making the requirement impossible to miss: printable at start-up, and
-- named again in the refusal if the consumer ignored it.

local Permission = {}

--- Reads the `NEEDS` field off a table of modules.
--
-- Skips a module with no `NEEDS`, which is how the pure ones and the ungated
-- wrappers declare "nothing to add to your manifest".
-- @author dop42
-- @param modules table name -> module table
-- @return table name -> permission
function Permission.Of(modules)
	local needs = {}
	if type(modules) ~= 'table' then return needs end

	for name, held in pairs(modules) do
		if type(held) == 'table' and type(held.NEEDS) == 'string' then
			needs[name] = held.NEEDS
		end
	end
	return needs
end

--- Every distinct permission in a needs map, sorted.
--
-- Sorted so two runs print the same line: a start-up diagnostic whose output
-- reorders itself looks like a change every time anyone reads it.
-- @author dop42
-- @param needs table name -> permission
-- @return string[]
function Permission.List(needs)
	local seen, out = {}, {}
	for _, permission in pairs(needs or {}) do
		if not seen[permission] then
			seen[permission] = true
			out[#out + 1] = permission
		end
	end
	table.sort(out)
	return out
end

--- The manifest line a consumer can paste, or nil if nothing is needed.
--
-- Answers nil rather than an empty `permissions { }` because an empty directive
-- is not a thing to paste; a caller printing this should print nothing.
-- @author dop42
-- @param needs table name -> permission
-- @return string|nil
function Permission.Line(needs)
	local list = Permission.List(needs)
	if #list == 0 then return nil end

	local quoted = {}
	for index = 1, #list do quoted[index] = ('%q'):format(list[index]) end
	return ('permissions { %s }'):format(table.concat(quoted, ', '))
end

return Permission
