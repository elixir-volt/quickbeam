defmodule QuickBEAM.VM.Compiler.Diagnostics do
  @moduledoc "Introspection tools for compiler mode: capability checking, helper call analysis."

  alias QuickBEAM.VM.{Bytecode, Decoder}
  alias QuickBEAM.VM.Compiler
  alias QuickBEAM.VM.Compiler.Analysis.CFG

  @doc "Check if a function can be compiled. Returns :ok or {:error, reasons}."
  def check(%Bytecode.Function{} = fun) do
    case Compiler.compile(fun) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  def check(_), do: {:error, :var_refs_not_supported}

  @doc "Explain why a function can/cannot be compiled, with details."
  def explain(%Bytecode.Function{} = fun) do
    compile_result = Compiler.compile(fun)

    {compilable?, error} =
      case compile_result do
        {:ok, _} -> {true, nil}
        {:error, reason} -> {false, reason}
      end

    {opcode_count, all_opcode_names} =
      case Decoder.decode(fun.byte_code, fun.arg_count) do
        {:ok, instructions} ->
          names =
            for {op, _args} <- instructions,
                match?({:ok, _}, CFG.opcode_name(op)),
                do: elem(CFG.opcode_name(op), 1),
                uniq: true

          {length(instructions), names}

        _ ->
          {0, []}
      end

    unsupported =
      case error do
        {:unsupported_opcode, name} -> [name]
        _ -> Enum.filter(all_opcode_names, &known_unsupported?/1)
      end

    %{
      compilable?: compilable?,
      error: error,
      opcode_count: opcode_count,
      unsupported_opcodes: unsupported
    }
  end

  def explain(_),
    do: %{
      compilable?: false,
      error: :var_refs_not_supported,
      opcode_count: 0,
      unsupported_opcodes: []
    }

  @doc "Count helper calls in compiled output."
  def helper_call_counts(%Bytecode.Function{} = fun) do
    case Compiler.disasm(fun) do
      {:ok, beam_file} ->
        beam_file
        |> extract_ext_calls()
        |> Enum.frequencies()

      {:error, _} ->
        %{}
    end
  end

  def helper_call_counts(_), do: %{}

  defp extract_ext_calls({:beam_file, _module, _exports, _attributes, _compile_info, code}) do
    for {:function, _name, _arity, _label, instructions} <- code,
        {op, _argc, {:extfunc, mod, fn_name, arity}} <- instructions,
        op in [:call_ext, :call_ext_last, :call_ext_only] do
      {mod, fn_name, arity}
    end
  end

  @with_scope_opcodes [
    :with_get_var,
    :with_put_var,
    :with_delete_var,
    :with_make_ref,
    :with_get_ref,
    :with_get_ref_undef
  ]

  defp known_unsupported?(name), do: name == :invalid or name in @with_scope_opcodes
end
