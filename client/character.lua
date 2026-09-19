--- The local body: where it is, as a table.
-- @author dop42
--
--   local here = Lib.Character.Position()
--   if here.ok then print(here.value.x) end
--
-- No permission is checked for the reads in this module on this build.
--
-- WHY A WRAPPER FOR ONE CALL. `Open77.character.position()` answers THREE
-- VALUES -- `x, y, z` -- not a table. Every other geometry API on the platform
-- takes `{ x, y, z }`, so almost every call site immediately repacks it, and
-- the ones that forget pass `x` where a point was wanted and get a refusal
-- about the wrong argument. Doing it once, here, is the whole justification.
--
-- IT ALSO CANNOT GO THROUGH `Native.Call`, which keeps only the first return
-- value and would silently drop `y` and `z`. That is the same edge documented
-- in `modules/native.lua`: a native whose answer is not a single value has to
-- be reached directly.

local Native = require('@opx_lib/client.native')
local Result = require('@opx_lib/pure.result')

local Character = {}

--- No manifest permission is checked for these reads on this build.
Character.NEEDS = nil

--- The local body's world position as `{ x, y, z }`.
--
-- A read taken before the character exists answers nothing useful, so a missing
-- coordinate is a refusal rather than a table of nils that fails later, inside
-- somebody's distance check.
-- @author dop42
-- @return table a Result carrying { x, y, z }
function Character.Position()
	local native, missing = Native.Reach('character.position')
	if native == nil then
		return Result.Err(missing, 'Open77.character.position is not available on this build')
	end

	local ok, x, y, z = pcall(native)
	if not ok then return Result.Err('native_raised', tostring(x)) end
	if type(x) ~= 'number' or type(y) ~= 'number' or type(z) ~= 'number' then
		return Result.Err('no_character', 'the local character has no position yet')
	end

	return Result.Ok({ x = x, y = y, z = z })
end

return Character
