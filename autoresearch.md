# Autoresearch: JavaScript Parser Compatibility

## Objective
Close accepted-syntax compatibility gaps in the experimental hand-written JavaScript lexer/parser (`lib/quickbeam/js/parser*`) against QuickJS/Test262-style JavaScript while preserving VM/Web API behavior and the focused parser test suite.

This segment is compatibility-focused. Do not cheat by suppressing diagnostics, skipping validation, weakening tests, changing Test262 inputs, or special-casing benchmark files/strings. Fix the grammar/lexer behavior and add focused regression tests for each gap.

## Primary Metric
- **`test262_language_sample_errors`** (lower is better): total parser errors across a deterministic sample of the first 12000 non-negative `test/test262/test/language/**/*.js` files.

## Secondary Metrics
- `test262_language_sample_error_files` — sampled files with parser errors.
- `test262_language_sample_unique_errors` — unique diagnostic messages in sampled files.
- `test262_language_sample_files` — sample size; default should stay 12000.
- `test262_language_sample_module_files` — files parsed with `source_type: :module` by metadata/static-module detection.
- `test_language_errors` — parser errors on `test/vm/test_language.js`; must stay 0.
- `test_language_parse_ok` — must stay 1.
- `quickjs_parser_tests` — QuickJS-port coverage signal; must not regress intentionally.
- `parser_tests` — focused parser test count.
- `parser_test_ms` — focused parser suite duration.

## Commands
Run the compatibility loop with:

```sh
./autoresearch.sh
```

Useful optional environment variables:

```sh
TEST262_SAMPLE_LIMIT=16000 ./autoresearch.sh   # broaden the deterministic sample
TEST262_SAMPLE_OFFSET=12000 ./autoresearch.sh  # inspect a later slice
TEST262_ERROR_LIMIT=80 ./autoresearch.sh       # print more failing files
```

`autoresearch.sh` runs:
1. `mix test test/js/parser --formatter ExUnit.CLIFormatter`
2. `mix run bench/js_parser_compat.exs`

The benchmark prints:
- summary CSV rows for `test_language` and the Test262 sample
- top `ERROR_MESSAGE` clusters
- top `ERROR_DIR` clusters
- `ERROR_FILE ...` examples with source type and first diagnostic
- structured `METRIC ...` lines for autoresearch

## Source Type Rules
`bench/js_parser_compat.exs` parses files as modules when any of these are true:
- Test262 metadata has `flags: [... module ...]`
- path contains `/module-code/`
- source has top-level-looking static `import` / `export` syntax

Everything else is parsed as script source. This is benchmark setup only; do not edit Test262 files.

## Files in Scope
- `lib/quickbeam/js/parser.ex`
- `lib/quickbeam/js/parser/lexer.ex`
- `lib/quickbeam/js/parser/ast.ex`
- `lib/quickbeam/js/parser/token.ex`
- `lib/quickbeam/js/parser/error.ex`
- `test/js/parser/`
- `bench/js_parser_compat.exs`
- `autoresearch.sh`
- `autoresearch.md`

Benchmark inputs are read-only:
- `test/vm/test_language.js`
- `test/test262/test/language/**/*.js`

## Off Limits
- Zig/C/NIF files.
- External parser generators or native parser replacements.
- New dependencies for the parser compatibility loop.
- Benchmark overfitting or exact string/file special cases.

## Experiment Workflow
1. Run `./autoresearch.sh` or inspect current `ERROR_MESSAGE` / `ERROR_FILE` output.
2. Pick the broadest real syntax gap visible in the sample.
3. Add focused tests under `test/js/parser/<area>/..._test.exs` with `@moduletag :quickjs_port`.
4. Fix parser/lexer behavior generally.
5. Run `mix format`, `mix compile --warnings-as-errors`, `mix test test/js/parser`, then `./autoresearch.sh`.
6. Keep only changes that reduce the primary metric without regressing `test_language_errors`, parser tests, or QuickJS-port coverage.

## Current Known Gap Clusters
The first 8000-file sample is parse-clean. At the 12000-file sample, inspect the current `ERROR_MESSAGE` and `ERROR_FILE` output before choosing a gap.

When the 12000-file sample reaches zero, expand the default sample limit again or target a later slice using `TEST262_SAMPLE_OFFSET`.
