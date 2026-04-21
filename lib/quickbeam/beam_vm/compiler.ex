defmodule QuickBEAM.BeamVM.Compiler do
  @moduledoc false

  alias QuickBEAM.BeamDisasm
  alias QuickBEAM.BeamVM.{Bytecode, Decoder, Names}
  alias QuickBEAM.BeamVM.Compiler.{Forms, Lowering, Optimizer, Runner}

  @type compiled_fun :: {module(), atom()}

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
    with {:ok, children} <- disasm_children(fun.constants) do
      case compile_binary(fun) do
        {:ok, _module, entry, binary} ->
          case :beam_disasm.file(binary) do
            {:beam_file, _, _, _, _, _} = beam_file ->
              {:ok,
               BeamDisasm.from_beam_file(
                 beam_file,
                 entry: entry,
                 js_name: display_name(fun.name),
                 children: children
               )}

            {:error, _, _} = error ->
              {:ok, unsupported_disasm(fun.name, children, error)}
          end

        {:error, _} = error ->
          {:ok, unsupported_disasm(fun.name, children, error)}
      end
    end
  end

  def disasm(_), do: {:error, :var_refs_not_supported}

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

  defp disasm_children(constants) do
    constants
    |> Enum.filter(&match?(%Bytecode.Function{}, &1))
    |> Enum.reduce_while({:ok, []}, fn fun, {:ok, acc} ->
      case disasm(fun) do
        {:ok, child} -> {:cont, {:ok, [child | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, children} -> {:ok, Enum.reverse(children)}
      error -> error
    end
  end

  defp unsupported_disasm(js_name, children, error) do
    %BeamDisasm{js_name: display_name(js_name), children: children, error: error}
  end

  defp display_name(name), do: Names.resolve_display_name(name) || "<anonymous>"

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
