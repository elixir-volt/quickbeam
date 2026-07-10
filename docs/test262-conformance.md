# Selected Test262 Conformance

QuickBEAM uses a pinned, bounded Test262 manifest as a differential correctness
gate for `QuickBEAM.VM`. Full Test262 compliance is not claimed.

## Baseline

- Test262 revision: `d1d583db95a521218f3eb8341a887fd63eda8ff1`
- Selected tests: 22
- Explicitly unsupported by flags: 4 asynchronous tests
- Supported tests: 18
- Passing: 16
- Known failures: 2
- Supported-test pass rate: **88.9%**
- Required pass rate: **85%**

The exact paths and classified known failures live in
`test/test262/manifest.exs`. A newly passing known failure and an unclassified
new failure both fail the gate, so the manifest cannot silently hide changes.

Current known failures are:

1. `language/expressions/object/setter-prop-desc.js` — harness incompatibility;
   the official `propertyHelper.js` requires `Object.getOwnPropertyNames` and a
   broader `Function` method surface.
2. `language/expressions/instanceof/S11.8.6_A2.1_T2.js` — interpreter bug;
   generated `ReferenceError` values do not yet carry JavaScript constructor
   identity.

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

The runner supplies a small assertion harness for `assert`, `sameValue`,
`notSameValue`, and `compareArray`. Additional official harness includes are
loaded only when requested by a selected test. Tests that depend on unsupported
harness APIs remain explicitly classified rather than being rewritten to pass.
