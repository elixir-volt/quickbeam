# Selected Test262 Conformance

QuickBEAM uses a pinned, bounded Test262 manifest as a differential correctness
gate for `QuickBEAM.VM`. Full Test262 compliance is not claimed.

## Baseline

- Test262 revision: `d1d583db95a521218f3eb8341a887fd63eda8ff1`
- Selected tests: 69
- Explicitly unsupported by flags: 4 asynchronous tests
- Supported tests: 65
- Passing: 65
- Known failures: 0
- Supported-test pass rate: **100%**
- Required pass rate: **100%**

The exact paths and classified known failures live in
`test/test262/manifest.exs`. A newly passing known failure and an unclassified
new failure both fail the gate, so the manifest cannot silently hide changes.

The selected supported set currently has no known failures. It covers the
previous `propertyHelper.js` dependency gap and generated `ReferenceError`
constructor identity failure, plus declarative constructor/prototype metadata,
Function calls, Error descriptors, Symbol keys, Set insertion and identity
semantics, and Promise resolution and iterator behavior.

## Running the gate

Create a checkout at the pinned revision and provide its path explicitly:

```sh
git clone --filter=blob:none --sparse https://github.com/tc39/test262.git /tmp/test262
git -C /tmp/test262 checkout d1d583db95a521218f3eb8341a887fd63eda8ff1
git -C /tmp/test262 sparse-checkout set harness test

TEST262_PATH=/tmp/test262 \
  mix test test/vm/test262_test.exs --include test262
```

Without `TEST262_PATH`, metadata-parser and summary tests still run while the
external corpus gate is reported as skipped.

## Classification

Each selected path is run in a fresh native QuickJS runtime and an isolated
BEAM VM evaluation. Results are classified as:

- `pass` — both engines satisfy the Test262 expectation;
- `vm_failure` — native QuickJS passes and the BEAM VM fails;
- `native_failure` — the selected test or harness is incompatible with the
  vendored native engine;
- `unsupported_flag` — module, raw, or asynchronous harness behavior is outside
  the current bounded runner;
- `missing` — the pinned corpus does not contain a manifest path.

There is no automatic native fallback during BEAM evaluation. The native result
is used only as a differential oracle.

The selected SSR profile does not currently claim generator or async-generator
opcodes, Proxy/Reflect semantics, weak collections, the global Symbol registry,
constructor species/subclassing, or dynamic `Function` source compilation.
Those features remain explicit profile exclusions until pinned tests and
resource-bounded implementations are added; a passing test carrying a broad
feature tag does not imply blanket support for that feature.

Test262 YAML front matter is parsed by `YamlElixir` and decoded into strict,
typed metadata structs by `JSONCodec`. Flags, includes, features, negative-test
shape, and the finite phase enum therefore have one explicit boundary contract;
unknown phases produce structured codec errors rather than fallback atoms.

The runner supplies a small assertion harness for `assert`, `sameValue`,
`notSameValue`, and `compareArray`. Additional official harness includes are
loaded only when requested by a selected test. Tests that depend on unsupported
harness APIs remain explicitly classified rather than being rewritten to pass.
