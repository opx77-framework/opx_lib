# Contributing to opx_lib

Thanks for helping. The organization-wide guide is
[here](https://github.com/opx77-framework/.github/blob/main/CONTRIBUTING.md); this file
adds what is specific to the library. Reviewer rules are on the docs site:
[Contributing](https://opx77-framework.github.io/opx77_doc/docs/guides/contributing).

Questions go to [Discord](https://discord.gg/xpSuYgEYsU). Vulnerabilities go through a
[private security advisory](https://github.com/opx77-framework/opx_lib/security/advisories/new).

## Branches and pull requests

Nothing is pushed to `main` directly: branch (`feat/<thing>`, `fix/<thing>`,
`audit/<thing>`, `docs/<thing>`), push, open a pull request and fill in the template.

## Before you push

```bash
lua tests/run.lua                                         # must be green
luac -p $(find . -name '*.lua' -not -name 'open77.lua')   # syntax
```

Then run `opx_infinity`'s suite against your checkout, because the framework loads the
real library in its tests:

```bash
cd ../opx_infinity && OPX_LIB_PATH=../opx_lib lua tests/run.lua
```

## The rules of this library

CI enforces most of these; know them before you write a module.

- **Two tiers, one directory each.** `pure/` reaches nothing: no `Open77`, no `_G`, no
  `CreateThread`, `Wait`, `SetTimeout`, and no import from `client/`. A server resource
  must be able to copy a pure file verbatim. A helper that could be pure belongs there.
- **Every import names the provider**: `require('@opx_lib/pure.table')`, never
  `require('pure.table')`, which would resolve against the *consumer's* resource.
- **Every file is delivered or declared.** Library modules are `files` in `open77.lua`;
  only `boot/` holds scripts.
- **Reach the platform through `Native.Reach` / `Native.Call`**, at call time. Never
  capture a native at load and never index `_G` outside `client/native.lua`.
- **Every client module declares `NEEDS`**, even when the answer is none
  (`NEEDS = nil` is a checked claim). `Lib.Manifest()` is built from them.
- **Answer, don't raise.** Wrappers answer a Result with a stable `error` code; `detail`
  is for logs.
- **No cross-resource state.** Each consumer gets its own copy of every table.
- **The client sandbox** has no `setmetatable` / `getmetatable`, and a resume that runs
  past its instruction budget is killed silently. Keep per-call work bounded.
- **Never guess a native**: look it up with the Open77 devkit for the build you target.

## Versioning

`Lib.VERSION` in `init.lua`, `version` in `open77.lua` and the version `boot/` logs stay
equal. Semantic: a new module or function is a minor, a changed answer is a major.

## House style

Lua 5.4 (not CfxLua), **tabs**, **single quotes**, LF. Each file opens with a `---`
summary and `-- @author <name>`, then a comment block that argues *why*; public
functions carry a `---` summary and `-- @param` / `-- @return`.

Commit messages: `<area>: <what is true now>` in plain lowercase words, and a body that
says why it was wrong before (for example
`native: the platform was raw-read, so a host with a metatable answered nothing`).

## Licence

By contributing you agree that your contribution is licensed under the
[MIT License](LICENSE) of this repository.
