--- `opx_lib` -- the entry point a consumer gets from `require('@opx_lib')`.
-- @author dop42
--
--   dependency "opx_lib"   -- in the CONSUMER's open77.lua. Without it, require
--                          -- answers nil, 'module_dependency_not_declared'.
--
--   local Lib = require('@opx_lib')
--   local name = Lib.Validate.Word(payload.name, 24)
--   Lib.Notify.Show('Welcome, ' .. name)
--
-- WHAT THIS IS. A client library, executed in the CONSUMER's VM. The platform
-- is explicit about what that means: `require` runs the code in the caller's
-- VM, with the caller's "permissions and budget". Three consequences run
-- through every module here, and they are why the library is shaped this way.
--
--   1. THE CONSUMER'S PERMISSIONS APPLY, not ours. A native called from this
--      library is checked against the IMPORTING resource's manifest, so this
--      resource declares none and could not usefully declare any. What a
--      consumer must add is answered by `Lib.Manifest()`.
--
--   2. THE CONSUMER OWNS WHAT IS CREATED. Markers, key mappings and callbacks
--      are resource-owned, and the owning resource is the importer. Two
--      resources using this library never collide, and neither can touch the
--      other's handles. That is free correctness, not a caveat.
--
--   3. THE CACHE IS PER CONSUMER VM. `require` caches by resolved file per
--      caller generation, so two resources get two independent copies of these
--      tables. No module may hold cross-resource state, because it cannot: a
--      table mutated by one consumer is not the table the next one sees.
--      `Locale`'s catalogue is per consumer for exactly this reason.
--
-- TWO TIERS, ONE DIRECTORY EACH, AND THE LINE IS WORTH KEEPING. `pure/` touches
-- nothing: arithmetic on values the caller already holds, identical on both
-- runtimes, safe to copy into a server resource by hand -- which matters,
-- because the server has no `require` and copying is the only way. `client/`
-- reaches the platform, so it is client-only, and each module names the
-- permission it needs. A helper that could be pure belongs in `pure/`.
--
-- SIBLING IMPORTS ARE PROVIDER-QUALIFIED, and they have to be. Inside a
-- library, `require('modules.table')` resolves against the CONSUMER's resource,
-- not this one -- the name is resolved relative to whoever is importing. The
-- short form would load a file belonging to somebody else, or nothing at all.
-- Every import below names `@opx_lib`, and a new module must do the same.
--
-- THERE IS NO SERVER HALF. The dedicated-server sandbox has no `require` at
-- all, so no mechanism exists to put this code into another server VM. A server
-- resource that wants the pure helpers copies them or calls an export; the
-- wrapper modules have no server meaning in any case.

local Permission = require('@opx_lib/pure.permission')

local Lib = {}

--- The library's own version, for a consumer that wants to branch on it.
--- Semantic: a new module or function is a minor, a changed answer is a major.
--- A consumer pinning behaviour compares this and not the resource's manifest
--- version, which an operator can edit.
Lib.VERSION = '0.3.0'

-- ── Pure: no natives, no permissions, no host ────────────────────────────────
Lib.Result = require('@opx_lib/pure.result')
Lib.Validate = require('@opx_lib/pure.validate')
Lib.Table = require('@opx_lib/pure.table')
Lib.String = require('@opx_lib/pure.string')
Lib.Math = require('@opx_lib/pure.math')
Lib.Class = require('@opx_lib/pure.class')
Lib.Locale = require('@opx_lib/pure.locale')
Lib.Text = require('@opx_lib/pure.text')
Lib.Array = require('@opx_lib/pure.array')
Lib.Colour = require('@opx_lib/pure.colour')
Lib.Permission = Permission

-- ── Wrappers: client-only, every call charged to the consumer ────────────────
Lib.Native = require('@opx_lib/client.native')
Lib.Timer = require('@opx_lib/client.timer')
Lib.Character = require('@opx_lib/client.character')
Lib.Notify = require('@opx_lib/client.notify')
Lib.Anim = require('@opx_lib/client.anim')
Lib.Input = require('@opx_lib/client.input')
Lib.Marker = require('@opx_lib/client.marker')
Lib.Callback = require('@opx_lib/client.callback')
Lib.Zone = require('@opx_lib/client.zone')
Lib.Rpc = require('@opx_lib/client.rpc')
Lib.Async = require('@opx_lib/client.async')
Lib.World = require('@opx_lib/client.world')
Lib.Players = require('@opx_lib/client.players')
Lib.Blip = require('@opx_lib/client.blip')
Lib.Store = require('@opx_lib/client.store')

--- Module name -> the manifest permission it needs, read off each module's own
--- `NEEDS`. Derived, never written out by hand: a list kept in two places is a
--- list that disagrees with itself by the third release.
Lib.NEEDS = Permission.Of(Lib)

--- The `permissions { ... }` line this consumer should have, or nil if they
--- need none. Printing it at start-up costs one line and removes the whole
--- class of "the marker just never appears".
-- @author dop42
-- @return string|nil
function Lib.Manifest()
	return Permission.Line(Lib.NEEDS)
end

return Lib
