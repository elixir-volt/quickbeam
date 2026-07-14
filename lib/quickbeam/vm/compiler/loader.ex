defmodule QuickBEAM.VM.Compiler.Loader do
  @moduledoc """
  Defines the bounded module-pool loading boundary.

  Compilation runs in a supervised task. Installation and retirement are
  serialized by the module pool. Retirement must use soft purge semantics and
  return an error rather than hard-purging live code.
  """

  @type artifact :: term()

  @doc "Builds a slot-specific artifact for a binary cache key."
  @callback compile(binary(), module(), term()) :: {:ok, artifact()} | {:error, term()}

  @doc "Installs a compiled artifact under its assigned static module."
  @callback install(module(), artifact()) :: :ok | {:error, term()}

  @doc "Safely retires code currently installed in a static module slot."
  @callback retire(module()) :: :ok | {:error, term()}
end
