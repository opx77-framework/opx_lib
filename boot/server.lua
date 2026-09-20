--- The server half, which deliberately provides nothing.
-- @author dop42
--
-- THERE IS NO SERVER LIBRARY HERE, and this file is not the beginning of one.
-- The dedicated-server sandbox has no `require`, no `load`, no `loadfile` and no
-- `dofile`, and `LoadResourceFile` reads only the CALLING resource's own files
-- -- naming another answers `cross_resource_read_denied`. There is therefore no
-- mechanism, anywhere, by which this resource's Lua could reach another server
-- VM. A server resource that wants the pure helpers copies them.
--
-- This file exists for the same reason `boot/client.lua` does: the server
-- refuses a resource that declares no script, and it refuses it by failing
-- startup rather than by skipping the resource. Declaring the script here as
-- well as on the client matches `polyzone`, the platform's own published
-- library, which is the only shape proven to load on this build.
--
-- One line in the journal, so an operator who added `opx_lib` to
-- `resources.load` can see that it took.

-- Stated as a literal because it cannot be read from anywhere: the dedicated
-- server sandbox has no `require`. `tests/run.lua` holds this line against
-- `init.lua` and the manifest, because it was already stale once -- 0.2.0 under
-- a 0.3.0 library -- and the only symptom was a wrong number in a journal,
-- which costs somebody an hour and never gets reported.
local VERSION = '0.4.0'

Open77.log.info(('opx_lib %s present. The library is client-side: the server '
	.. 'sandbox has no module loader, so nothing is published here.'):format(VERSION))
