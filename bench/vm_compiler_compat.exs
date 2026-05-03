Mix.Task.run("app.start")
Code.require_file("support/compiler_audit.exs", __DIR__)

Bench.CompilerAudit.run_all("compiler", "COMPILER")
