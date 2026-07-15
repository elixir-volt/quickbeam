defmodule QuickBEAM.VM.Compiler.GeneratedModule do
  @moduledoc """
  Provides the production generated-code backend for the bounded module pool.

  Emission and code-server lifecycle are separate components behind this small
  backend facade, keeping cache and lease ownership independent from generated
  form validation and code loading.
  """

  @behaviour QuickBEAM.VM.Compiler.ModulePool.Backend

  alias QuickBEAM.VM.Compiler.GeneratedModule.{CodeLifecycle, Emitter}

  @impl true
  def compile(key, module, template), do: Emitter.emit(key, module, template)

  @impl true
  def install(module, artifact), do: CodeLifecycle.install(module, artifact)

  @impl true
  def retire(module), do: CodeLifecycle.retire(module)
end
