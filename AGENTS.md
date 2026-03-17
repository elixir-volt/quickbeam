# AGENTS.md

## Build

```sh
QUICKBEAM_BUILD=1 mix compile   # build NIF from source (requires Zig 0.15+)
mix compile                     # use precompiled NIF
mix test                        # full suite (1300+ tests)
```

Set `QUICKBEAM_BUILD=1` for any compilation that touches Zig/C code.

## Architecture

Elixir → GenServer (`Runtime`/`Context`) → Zig NIFs (`quickbeam.zig`) → QuickJS-NG C engine.

- `lib/quickbeam.ex` — public API
- `lib/quickbeam/runtime.ex` — GenServer, handler dispatch, message loop
- `lib/quickbeam/server.ex` — shared GenServer code for Runtime and Context
- `lib/quickbeam/quickbeam.zig` — NIF entry points
- `lib/quickbeam/worker.zig` — JS worker thread (eval, compile, call, DOM ops)
- `lib/quickbeam/types.zig` — message queue, payloads, reply helpers
- `lib/quickbeam/js_to_beam.zig` / `beam_to_js.zig` — value conversion
- `priv/c_src/quickjs.c` — QuickJS-NG engine (vendored, patched)
- `priv/ts/` — TypeScript polyfills (Web APIs, Node compat)

## Adding a NIF

1. Add the function in `quickbeam.zig` (or `worker.zig` for async ops)
2. Register it in `native.ex` under `nifs:`
3. If async: add a message variant to `types.zig`, dispatch in `worker.zig`

## Release

1. Bump `@version` in `mix.exs`
2. Update `CHANGELOG.md` (rename "Unreleased" → version)
3. Set placeholder checksums in `checksum-QuickBEAM.Native.exs`
4. Commit: `git commit -m "Release vX.Y.Z"`
5. Tag and push: `git tag vX.Y.Z && git push && git push --tags`
6. Wait for the precompile workflow (builds NIFs for linux-x64, macos-arm64)
7. Download artifacts, compute checksums:
   ```sh
   gh release download vX.Y.Z --dir /tmp/release
   for f in /tmp/release/*.tar.gz; do
     echo "{\"$(basename $f)\", \"sha256:$(shasum -a 256 $f | cut -d' ' -f1)\"},"
   done
   ```
8. Update `checksum-QuickBEAM.Native.exs` with real hashes
9. Commit and push: `git commit -am "Update precompiled NIF checksums for vX.Y.Z" && git push`
10. Publish: `mix hex.publish`
