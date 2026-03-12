# NPMSemver

[![Hex.pm](https://img.shields.io/hexpm/v/npm_semver.svg)](https://hex.pm/packages/npm_semver)
[![CI](https://github.com/dannote/npm_semver/actions/workflows/ci.yml/badge.svg)](https://github.com/dannote/npm_semver/actions/workflows/ci.yml)

npm-compatible semantic versioning for Elixir.

Parse and match version ranges using npm's semver syntax: `^1.2.3`,
`~1.2.3`, `>=1.0.0 <2.0.0`, `1.x`, `1.0.0 - 2.0.0`, `||` unions.

## Installation

```elixir
def deps do
  [{:npm_semver, "~> 0.1.0"}]
end
```

## Usage

```elixir
NPMSemver.matches?("1.2.3", "^1.0.0")
# => true

NPMSemver.matches?("2.0.0", "^1.0.0")
# => false

NPMSemver.matches?("1.5.0", ">=1.2.3 <2.0.0")
# => true

NPMSemver.matches?("2.1.3", "2.x.x")
# => true
```

### Find best match

```elixir
NPMSemver.max_satisfying(["1.0.0", "1.5.0", "2.0.0"], "^1.0.0")
# => "1.5.0"
```

### hex_solver integration

Convert npm ranges to constraints for [hex_solver](https://hex.pm/packages/hex_solver) (PubGrub dependency resolver):

```elixir
{:ok, constraint} = NPMSemver.to_hex_constraint("^1.2.3")
```

Or get the Elixir requirement string directly:

```elixir
NPMSemver.to_elixir_requirement("^1.2.3")
# => {:ok, ">= 1.2.3 and < 2.0.0-0"}
```

## Supported syntax

| Syntax | Example | Expands to |
|--------|---------|------------|
| Caret | `^1.2.3` | `>=1.2.3 <2.0.0` |
| Tilde | `~1.2.3` | `>=1.2.3 <1.3.0` |
| X-range | `1.2.x`, `1.*`, `*` | `>=1.2.0 <1.3.0` |
| Comparator | `>=1.0.0 <2.0.0` | as written |
| Hyphen | `1.0.0 - 2.0.0` | `>=1.0.0 <=2.0.0` |
| Union | `^1.0 \|\| ^2.0` | either range |
| Intersection | `>=1.2.1 <=1.2.8` | space-separated AND |

## Options

- `loose: true` — accept `v`-prefixed versions and pre-release tags without `-` separator
- `include_prerelease: true` — x-ranges and `*` match pre-release versions

## Testing

216 test cases ported from [node-semver](https://github.com/npm/node-semver) fixtures.

## License

MIT
