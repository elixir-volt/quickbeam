defmodule QuickBEAM.VM.Builtin.Console do
  @moduledoc "Defines the minimal SSR console namespace."

  use QuickBEAM.VM.Builtin

  alias QuickBEAM.VM.Builtin.Call

  builtin "console",
    kind: :namespace,
    profiles: [:ssr],
    depends_on: ["Object", "Function"] do
    static :error, length: 1
    static :info, length: 1
    static :log, length: 1
    static :warn, length: 1
  end

  @doc "Accepts a console error message without writing outside the evaluation."
  def error(%Call{execution: execution}), do: {:ok, :undefined, execution}

  @doc "Accepts a console informational message without writing outside the evaluation."
  def info(%Call{execution: execution}), do: {:ok, :undefined, execution}

  @doc "Accepts a console log message without writing outside the evaluation."
  def log(%Call{execution: execution}), do: {:ok, :undefined, execution}

  @doc "Accepts a console warning without writing outside the evaluation."
  def warn(%Call{execution: execution}), do: {:ok, :undefined, execution}
end
