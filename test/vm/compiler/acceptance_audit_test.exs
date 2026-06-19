defmodule QuickBEAM.VM.CompilerAcceptanceAuditTest do
  use ExUnit.Case, async: false

  @moduletag :compiler_acceptance_audit

  test "reports compiled bytecode parity against the interpreter" do
    results = QuickBEAM.VM.CompilerAudit.run_all()
    summary = QuickBEAM.VM.CompilerAudit.summary(results)

    for {reason, count} <- Enum.sort(summary.fallback_reasons) do
      IO.puts("COMPILER_FALLBACK count=#{count} reason=#{reason}")
    end

    assert summary.crashes == 0
  end
end
