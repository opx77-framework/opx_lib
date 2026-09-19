--- The resource's own entry point, which is NOT how the library is delivered.
-- @author dop42
--
-- WHY THIS FILE EXISTS AT ALL, because the obvious reading is that it should
-- not. The library's modules are `files`: delivered to the client and executed
-- in the CONSUMER's VM when they import them. Nothing here loads them, nothing
-- here holds them, and this script is not the library.
--
-- It exists because the dedicated server REFUSES a resource that declares no
-- script: `Server startup failed: Resource contains no scripts.` -- and it
-- refuses it at startup, taking the whole server down with it rather than
-- skipping the resource. `open77_validate` reports the same thing as a warning
-- ("no client_script, server_script or shared_script: the resource does
-- nothing"), which reads as advisory and is not.
--
-- `polyzone`, the platform's own published library, is the proof of the shape:
-- it declares `client_script`, `server_script` AND `files`, with the library
-- modules in `files` exactly as they are here.
--
-- So this announces the library and does nothing else. It runs in opx_lib's own
-- VM, which no consumer ever sees.

local Lib = require('@opx_lib')

if type(Lib) == 'table' then
	Open77.log.info(('opx_lib %s up: %d modules delivered'):format(
		Lib.VERSION, (function()
			local count = 0
			for _ in pairs(Lib) do count = count + 1 end
			return count
		end)()))

	-- The line a consumer needs in their own manifest, printed once where an
	-- operator setting the server up will actually see it.
	local needed = Lib.Manifest()
	if needed then
		Open77.log.info('opx_lib: a consumer using every module declares ' .. needed)
	end
else
	-- Our own modules failing to load is a packaging fault, not a consumer's.
	Open77.log.error('opx_lib could not load its own entry point: ' .. tostring(Lib))
end
