defmodule QuickBEAM.BeamVM.Compiler do
  @moduledoc false

  alias QuickBEAM.BeamVM.{Bytecode, Decoder}
  alias QuickBEAM.BeamVM.Compiler.{Forms, Lowering, Runner}

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
             {:ok, {slot_count, block_forms}} <- Lowering.lower(fun, instructions),
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
      :crypto.hash(:sha256, [fun.byte_code, <<fun.arg_count::32, fun.var_count::32>>])
      |> binary_part(0, 8)
      |> Base.encode16(case: :lower)

    Module.concat(QuickBEAM.BeamVM.Compiled, "F#{hash}")
  end

  defp entry_name, do: :run
end
