# VM bytecode fuzzing regressions

Persist minimized decoder safety findings here as paired `.bin` and `.txt`
files using `QuickBEAM.VM.Fuzz.persist/2`. The test suite replays every `.bin`
file twice under strict timeout and BEAM heap bounds and requires a stable typed
rejection.

The `.txt` sidecar records the corpus name, seed, iteration, mutation operation,
original outcome, and SHA-256 digest needed to reproduce and audit the input.
