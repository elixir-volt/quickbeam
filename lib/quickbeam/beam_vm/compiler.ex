defmodule QuickBEAM.BeamVM.Compiler do
  @moduledoc false

  alias QuickBEAM.BeamVM.{Bytecode, Decoder}
  alias QuickBEAM.BeamVM.Compiler.{Forms, Lowering, Optimizer, Runner}

  @type compiled_fun :: {module(), atom()}
  @type beam_file :: {:beam_file, module(), list(), list(), list(), list()}

  def invoke(fun, args), do: Runner.invoke(fun, args)

  def compile(%Bytecode.Function{} = fun) do
    module = module_name(fun)
    entry = entry_name()

    case :code.is_loaded(module) do
      {:file, _} ->
        {:ok, {module, entry}}

      false ->
        with {:ok, ^module, ^entry, binary} <- compile_binary(fun),
             {:module, ^module} <- :code.load_binary(module, ~c"quickbeam_compiler", binary) do
          {:ok, {module, entry}}
        else
          {:error, _} = error -> error
          other -> {:error, {:load_failed, other}}
        end
    end
  end

  def compile(_), do: {:error, :var_refs_not_supported}

  def disasm(%Bytecode.Function{} = fun) do
    case disasm_compiled(fun) do
      {:ok, _} = ok -> ok
      {:error, _} = error -> disasm_single_nested(fun.constants, error)
    end
  end

  def disasm(_), do: {:error, :var_refs_not_supported}

  defp disasm_compiled(%Bytecode.Function{} = fun) do
    with {:ok, _module, _entry, binary} <- compile_binary(fun),
         {:beam_file, _, _, _, _, _} = beam_file <- :beam_disasm.file(binary) do
      {:ok, beam_file}
    else
      {:error, _, _} = error -> {:error, error}
      {:error, _} = error -> error
    end
  end

  defp disasm_single_nested(constants, original_error) do
    case Enum.filter(constants, &match?(%Bytecode.Function{}, &1)) do
      [%Bytecode.Function{} = fun] -> disasm(fun)
      _ -> original_error
    end
  end

  defp compile_binary(%Bytecode.Function{} = fun) do
    module = module_name(fun)
    entry = entry_name()

    with {:ok, instructions} <- Decoder.decode(fun.byte_code, fun.arg_count),
         optimized = Optimizer.optimize(instructions, fun.constants),
         {:ok, {slot_count, block_forms}} <- Lowering.lower(fun, optimized),
         {:ok, _module, binary} <-
           Forms.compile_module(module, entry, fun.arg_count, slot_count, block_forms) do
      {:ok, module, entry, binary}
    end
  end

  defp module_name(fun) do
    hash =
      fun
      |> :erlang.term_to_binary()
      |> then(&:crypto.hash(:sha256, &1))
      |> binary_part(0, 8)
      |> Base.encode16(case: :lower)

    Module.concat(QuickBEAM.BeamVM.Compiled, "F#{hash}")
  end

  defp entry_name, do: :run
end
