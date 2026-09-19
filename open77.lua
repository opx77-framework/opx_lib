--- Resource manifest: a library, not a service.
-- @author dop42
--
-- THIS RESOURCE RUNS NO CODE OF ITS OWN. It declares no `client_script`, no
-- `server_script` and no `shared_script`, and that is the whole point: a
-- library's modules must be DELIVERED to the consumer and executed in the
-- consumer's VM, not executed here. A module listed as a script would run once,
-- in this resource, at start -- which is an entry point, not a library.
--
-- So the modules are `files`: delivered to the client, loaded on demand by
-- `require('@opx_lib')` from whoever declared us as a dependency. The consumer
-- pays the instruction budget and the consumer's permissions apply.
--
-- `auto_start` is TRUE and has to be: `require('@opx_lib')` answers
-- `module_dependency_not_running` if this resource is not up when a consumer
-- asks. A library that starts lazily is a library that fails at the first call
-- of every session.
--
-- NO PERMISSIONS, AND NOT BECAUSE NOTHING HERE TOUCHES THE PLATFORM. Several
-- modules do -- toasts, key mappings, world markers, network callbacks. But a
-- permission is checked against the CALLING resource's manifest, and the caller
-- is always the consumer, so a permission declared here would be checked for
-- nobody and grant nothing. Declaring one would be theatre.
--
-- What a consumer must declare is therefore stated as data instead: every
-- wrapper module carries a `NEEDS` field, and `Lib.Manifest()` answers the
-- `permissions { ... }` line to paste. See `modules/native.lua`, which is where
-- the refusal gets rewritten into something that names the missing line.
--
-- THERE IS NO SERVER HALF, and it is not an omission. The dedicated-server
-- sandbox has no `require` at all, and `LoadResourceFile` reads only the calling
-- resource's own files, so no mechanism exists to put this code in another
-- server VM. A server resource that wants the pure helpers copies them or calls
-- an export; `modules/class.lua` explains what an export does to a metatable.

resource "opx_lib"
version "0.3.0"

-- `>=0.0.1`, which is what every resource that has ever installed on this
-- platform declares. A range carrying build metadata is accepted by the server
-- parser and refused by the client at activation, which surfaces only as
-- `resource_activation_failed` with no server-side trace.
open77_version ">=0.0.1"
auto_start true

-- THE RESOURCE MUST CARRY A SCRIPT. The dedicated server refuses one that
-- does not -- `Server startup failed: Resource contains no scripts.` -- and it
-- refuses by failing startup, not by skipping the resource. `open77_validate`
-- reports this as a WARNING, which reads as advisory and is not. `polyzone`,
-- the platform's own published library, declares both scripts alongside its
-- `files` for the same reason. Neither script below is the library: they
-- announce it and nothing more.
client_script "boot/client.lua"
server_script "boot/server.lua"

-- Delivered, never executed here. Two tiers, two directories, and the split is
-- the library's main organising idea rather than filing:
--
--   pure/     no natives, no host, no permission. Identical on both runtimes,
--             so a server resource -- which has no `require` at all -- can copy
--             one of these files verbatim and it works.
--   client/   reaches the platform. Client-only by construction, and each
--             module names the permission the CONSUMER must declare.
--
-- A bare `require('@opx_lib')` resolves to `init.lua` at the resource root;
-- individual modules are `@opx_lib/pure.<name>` and `@opx_lib/client.<name>`,
-- though a consumer should prefer the table `init.lua` hands back.
files {
	"init.lua",
	"pure/*.lua",
	"client/*.lua",
}
