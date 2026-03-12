# NPM

[![Hex.pm](https://img.shields.io/hexpm/v/npm.svg)](https://hex.pm/packages/npm)
[![CI](https://github.com/dannote/npm_ex/actions/workflows/ci.yml/badge.svg)](https://github.com/dannote/npm_ex/actions/workflows/ci.yml)

npm package manager for Elixir — no Node.js required.

Resolve, fetch, cache, and link npm packages directly from Mix.

## Installation

```elixir
def deps do
  [{:npm, "~> 0.3.0"}]
end
```

## Usage

```sh
# Install all deps from package.json
mix npm.install

# Add a package (latest)
mix npm.install lodash

# Add with version range
mix npm.install lodash@^4.0

# Scoped packages
mix npm.install @types/node@^20

# Remove a package
mix npm.remove lodash

# List installed packages
mix npm.list

# Fetch locked deps without re-resolving
mix npm.get

# CI mode — fail if lockfile is stale
mix npm.install --frozen
```

## How it works

1. Reads dependencies from `package.json`
2. Resolves the full dependency tree using [PubGrub](https://hex.pm/packages/hex_solver) with [npm semver](https://hex.pm/packages/npm_semver)
3. Downloads tarballs from the npm registry with SHA-512 integrity verification
4. Caches packages globally in `~/.npm_ex/cache/` — download once, reuse across projects
5. Links into `node_modules/` via symlinks (macOS/Linux) or copies (Windows)
6. Locks versions in `npm.lock` for reproducible installs

## License

MIT © 2026 Danila Poyarkov
