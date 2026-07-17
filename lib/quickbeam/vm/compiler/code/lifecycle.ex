defmodule QuickBEAM.VM.Compiler.Code.Lifecycle do
  @moduledoc """
  Installs and safely retires generated modules in the Erlang code server.

  Retirement uses only `:code.soft_purge/1`. Live references return an error so
  the module pool can quarantine their slot instead of killing a process with
  hard purge.
  """

  alias QuickBEAM.VM.Compiler.Code.Artifact
  alias QuickBEAM.VM.Compiler.Code.Import
  alias QuickBEAM.VM.Compiler.Contract

  @source ~c"quickbeam_compiler"

  @doc "Installs a revalidated artifact under its assigned static module name."
  @spec install(module(), Artifact.t()) :: :ok | {:error, term()}
  def install(module, %Artifact{module: module, binary: binary} = artifact) do
    with :ok <- validate_module(module),
         :ok <- Artifact.validate(artifact),
         :ok <- Import.validate(binary),
         :ok <- ensure_slot_available(module),
         {:module, ^module} <- :code.load_binary(module, @source, binary) do
      :ok
    else
      {:error, _reason} = error -> error
      other -> {:error, {:generated_module_load_failed, other}}
    end
  end

  def install(module, artifact),
    do: {:error, {:invalid_generated_module_artifact, module, artifact}}

  @doc "Deletes current code and soft-purges old code for one reserved module."
  @spec retire(module()) :: :ok | {:error, term()}
  def retire(module) do
    with :ok <- validate_module(module),
         :ok <- soft_purge(module, :old),
         :ok <- delete_current(module) do
      soft_purge(module, :current)
    end
  end

  defp validate_module(module) do
    if module in Contract.pool_modules(),
      do: :ok,
      else: {:error, {:invalid_compiler_module, module}}
  end

  defp ensure_slot_available(module) do
    case :code.is_loaded(module) do
      false -> soft_purge(module, :install)
      _loaded -> {:error, {:compiler_slot_not_retired, module}}
    end
  end

  defp soft_purge(module, phase) do
    if :code.soft_purge(module),
      do: :ok,
      else: {:error, {:live_generated_code, module, phase}}
  end

  defp delete_current(module) do
    case :code.is_loaded(module) do
      false ->
        :ok

      _loaded ->
        if :code.delete(module),
          do: :ok,
          else: {:error, {:generated_module_delete_failed, module}}
    end
  end
end
