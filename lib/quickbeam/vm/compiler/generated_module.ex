defmodule QuickBEAM.VM.Compiler.GeneratedModule do
  @moduledoc """
  Provides the production generated-code backend for the bounded module pool.

  Emission and code-server lifecycle are separate components behind this small
  backend facade, keeping cache and lease ownership independent from generated
  form validation and code loading.
  """

  @behaviour QuickBEAM.VM.Compiler.ModulePool.Backend

  alias QuickBEAM.VM.Compiler.GeneratedModule.{CodeLifecycle, Emitter}
  alias QuickBEAM.VM.Compiler.ModulePool
  alias QuickBEAM.VM.Compiler.ModulePool.Lease
  alias QuickBEAM.VM.{Execution, Frame}

  @impl true
  def compile(key, module, template), do: Emitter.emit(key, module, template)

  @impl true
  def install(module, artifact), do: CodeLifecycle.install(module, artifact)

  @impl true
  def retire(module), do: CodeLifecycle.retire(module)

  @doc "Invokes generated code after validating its owner-local active lease."
  @spec invoke(ModulePool.server(), Lease.t(), Frame.t(), Execution.t()) :: term()
  def invoke(pool, %Lease{} = lease, %Frame{} = frame, %Execution{} = execution) do
    with :ok <- ModulePool.validate_lease(pool, lease) do
      lease.module.run(lease, frame, execution)
    end
  end
end
