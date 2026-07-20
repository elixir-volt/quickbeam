defmodule QuickBEAM.VM.Compiler.Code do
  @moduledoc """
  Provides the production generated-code backend for the bounded module pool.

  Emission and code-server lifecycle are separate components behind this small
  backend facade, keeping cache and lease ownership independent from generated
  form validation and code loading.
  """

  @behaviour QuickBEAM.VM.Compiler.Pool.Backend

  alias QuickBEAM.VM.Compiler.Code.Emitter
  alias QuickBEAM.VM.Compiler.Code.Lifecycle
  alias QuickBEAM.VM.Compiler.Pool
  alias QuickBEAM.VM.Compiler.Pool.Lease
  alias QuickBEAM.VM.Runtime.Frame
  alias QuickBEAM.VM.Runtime.State

  @doc "Compiles a validated template for one fixed generated-module slot."
  @impl true
  def compile(key, module, template), do: Emitter.emit(key, module, template)

  @doc "Installs a validated artifact into its fixed module slot."
  @impl true
  def install(module, artifact), do: Lifecycle.install(module, artifact)

  @doc "Soft-purges a generated module slot without deleting live code."
  @impl true
  def retire(module), do: Lifecycle.retire(module)

  @doc "Invokes generated code after validating its owner-local active lease."
  @spec invoke(Pool.server(), Lease.t(), Frame.t(), State.t()) :: term()
  def invoke(pool, %Lease{} = lease, %Frame{} = frame, %State{} = execution) do
    with :ok <- Pool.validate_lease(pool, lease) do
      lease.module.run(lease, frame, execution)
    end
  end
end
