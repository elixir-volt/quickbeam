# Changelog

## 0.1.0

Initial release.

- Parse and match npm semver ranges: caret (`^`), tilde (`~`), x-ranges, hyphen ranges, comparators, `||` unions
- `matches?/3` — check if a version satisfies a range
- `max_satisfying/3` — find the highest matching version from a list
- `to_hex_constraint/2` — convert npm ranges to `hex_solver` constraints
- `to_elixir_requirement/2` — convert npm ranges to Elixir requirement strings
- Loose mode and `include_prerelease` option
- NimbleParsec-based tokenizer
- 216 test cases ported from [node-semver](https://github.com/npm/node-semver)
