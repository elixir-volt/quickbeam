Mix.Task.run("app.start")
Code.require_file("support/compiler_audit.exs", __DIR__)

Bench.CompilerAudit.run(
  &QuickBEAM.VM.CompilerAudit.corpus_cases/0,
  "compiler_corpus",
  "COMPILER_CORPUS"
)
