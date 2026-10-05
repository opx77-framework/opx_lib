<h1 align="center">OPX//77 · opx_lib</h1>

<p align="center">
  <strong>A client library for <a href="https://open2077.net">Open77</a> resources: native wrappers that answer instead of raising, and pure helpers you can trust on both runtimes.</strong>
</p>

<p align="center">
  <a href="https://github.com/opx77-framework/opx_lib/actions/workflows/check.yml"><img alt="check" src="https://github.com/opx77-framework/opx_lib/actions/workflows/check.yml/badge.svg?branch=main"></a>
  <a href="LICENSE"><img alt="License: MIT" src="https://img.shields.io/github/license/opx77-framework/opx_lib"></a>
  <img alt="Version 0.4.0" src="https://img.shields.io/badge/version-0.4.0-informational">
  <img alt="Status: alpha" src="https://img.shields.io/badge/status-alpha-orange">
  <a href="https://opx77-framework.github.io/opx77_doc/docs/opx_lib"><img alt="Documentation" src="https://img.shields.io/badge/docs-opx__lib-c5003c"></a>
  <a href="https://discord.gg/xpSuYgEYsU"><img alt="Discord" src="https://img.shields.io/badge/discord-join-5865F2?logo=discord&logoColor=white"></a>
</p>

---

## What it is

`opx_lib` is the library the [OPX//77 framework](https://github.com/opx77-framework/opx_infinity)
is built on, and any Open77 resource can use it. It is loaded with
`require('@opx_lib')` and **runs inside the resource that requires it**: your
permissions, your instruction budget, and every marker, blip, key mapping or callback
it creates belongs to you.

- **Wrappers that answer, never raise.** Markers, blips, key bindings, cameras, screen
  effects, raycasts, network callbacks: each call answers a Result —
  `{ ok = true, value }` or `{ ok = false, error, detail }` — with stable codes such
  as `native_not_found` (older build) or `permission_denied`, whose `detail` names the
  manifest line you are missing.
- **A pure tier.** `pure/` touches neither the platform nor the host: text, numbers,
  tables, arrays, colours, classes, validation, translations, results. Identical on
  both runtimes, so a server resource (which has no `require`) can copy a file verbatim.
- **Permissions stated as data.** Every client module declares the permission it needs
  in `NEEDS`; `Lib.Manifest()` answers the exact `permissions { ... }` line to paste.
- **Natives resolved at call time**, never captured at load, so a native missing on an
  older client is a refusal, not a crash.

| Tier | Modules |
|---|---|
| `pure/` | `Result`, `Validate`, `Table`, `String`, `Math`, `Class`, `Locale`, `Text`, `Array`, `Colour`, `Permission` |
| `client/` | `Native`, `Timer`, `Character`, `Notify`, `Anim`, `Input`, `Marker`, `Callback`, `Zone`, `Rpc`, `Async`, `World`, `Players`, `Blip`, `Store`, `Camera`, `Screen` |

Every module is documented on the [docs site](https://opx77-framework.github.io/opx77_doc/docs/opx_lib).

## Quick start

1. **Install** the folder as `resources/opx_lib/` on the Open77 server (the folder name
   must be `opx_lib`) and load it **before** any resource that uses it:

   ```jsonc
   // server.jsonc
   "resources": { "load": [ /* ... */ "opx_lib", "your_resource" ] }
   ```

2. **Declare it** in your resource's manifest, with only the permissions you use:

   ```lua
   -- open77.lua
   dependency "opx_lib"
   permissions { "world.markers", "input.actions" }
   ```

3. **Require it** from a client script:

   ```lua
   local Lib = require('@opx_lib')

   local name = Lib.Validate.Word(payload.name, 24)
   Lib.Notify.Show('Welcome, ' .. name)

   print(Lib.Manifest())   -- the permissions line this library needs from you
   ```

| Module | Permission you declare |
|---|---|
| `Notify` | `ui.vanilla.hud` |
| `Input` | `input.actions` |
| `Marker` | `world.markers` (not for `Shapes`) |
| `Callback` | `network.events` |
| `World` | `world.query` |
| `Blip` | `ui.vanilla.map` |
| `Camera` | `camera.script` (not for `Ray`, `Owner`) |
| `Screen` | `screen.effects` |
| every other module | none |

**Client only.** The dedicated-server sandbox has no `require` and `LoadResourceFile`
reads only the caller's own files, so no server script can load this library. The
server half (`boot/server.lua`) only announces that it is present.

## Documentation

- **[opx_lib on the docs site](https://opx77-framework.github.io/opx77_doc/docs/opx_lib)**: one page per module, with parameters, results and examples.
- The design is argued in the file headers: [`init.lua`](init.lua) (what running in the
  consumer's VM implies), [`open77.lua`](open77.lua) (why the modules are `files`, not
  scripts), [`client/native.lua`](client/native.lua) (how a native is reached).

## Development

Requirements: desktop **Lua 5.4**.

```bash
lua tests/run.lua                                       # must be green
luac -p $(find . -name '*.lua' -not -name 'open77.lua') # syntax
```

The suite loads the library the way a consumer does, through a `require` shim that
refuses an import that does not name `@opx_lib`, against a fake host whose natives are
resolved by path. CI ([`check.yml`](.github/workflows/check.yml)) also checks that every
module is delivered or declared, every import names the provider, `pure/` touches no
platform global and imports nothing from `client/`, only `client/native.lua` touches
`_G`, and every client module declares `NEEDS`.

`opx_infinity`'s suite runs against this library too (`OPX_LIB_PATH`), so a change here
should also be checked there.

## Contributing

Read [`CONTRIBUTING.md`](CONTRIBUTING.md). Nothing is pushed to `main` directly.
Everyone taking part follows the
[Code of Conduct](https://github.com/opx77-framework/.github/blob/main/CODE_OF_CONDUCT.md).
Questions go to [Discord](https://discord.gg/xpSuYgEYsU).

## Security

Please **do not** report vulnerabilities in public issues. Use a
[private security advisory](https://github.com/opx77-framework/opx_lib/security/advisories/new);
see the [security policy](https://github.com/opx77-framework/.github/blob/main/SECURITY.md).

## License

[MIT](LICENSE). Copyright © 2026 Luís MOUTA.

## Credits

Built by **dop42** and the OPX//77 contributors, for [Open77](https://open2077.net).
Support the project on [Tipeee](https://fr.tipeee.com/dop42/).

<sub>OPX//77 is an independent community project and is not affiliated with or endorsed by CD PROJEKT RED.</sub>
