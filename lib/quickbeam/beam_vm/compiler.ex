defmodule QuickBEAM.BeamVM.Compiler do
  @moduledoc false

  alias QuickBEAM.BeamVM.{Bytecode, Decoder}
  alias QuickBEAM.BeamVM.Compiler.{Forms, Lowering, Optimizer, Runner}

  @type compiled_fun :: {module(), atom()}

  def invoke(fun, args), do: Runner.invoke(fun, args)

  def compile(%Bytecode.Function{closure_vars: []} = fun) do
    module = module_name(fun)
    entry = entry_name()

    case :code.is_loaded(module) do
      {:file, _} ->
        {:ok, {module, entry}}

      false ->
        with {:ok, instructions} <- Decoder.decode(fun.byte_code, fun.arg_count),
             optimized = Optimizer.optimize(instructions, fun.constants),
             {:ok, {slot_count, block_forms}} <- Lowering.lower(fun, optimized),
             {:ok, _module, binary} <-
               Forms.compile_module(module, entry, fun.arg_count, slot_count, block_forms),
             {:module, ^module} <- :code.load_binary(module, ~c"quickbeam_compiler", binary) do
          {:ok, {module, entry}}
        else
          {:error, _} = error -> error
          other -> {:error, {:load_failed, other}}
        end
    end
  end

  def compile(_), do: {:error, :closure_not_supported}

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
