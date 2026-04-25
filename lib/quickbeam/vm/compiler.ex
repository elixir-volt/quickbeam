defmodule QuickBEAM.VM.Compiler do
  @moduledoc "JIT compiler entry point: lowers bytecode to BEAM modules, caches them, and invokes compiled functions."

  alias QuickBEAM.VM.{Bytecode, Decoder, Heap}
  alias QuickBEAM.VM.Compiler.{Forms, Lowering, Optimizer, Runner}

  @type compiled_fun :: {module(), atom()}
  @type beam_file :: {:beam_file, module(), list(), list(), list(), list()}

  def invoke(fun, args) do
    depth = Heap.get_invoke_depth()
    Heap.put_invoke_depth(depth + 1)

    result = Runner.invoke(fun, args)

    Heap.put_invoke_depth(depth)

    if depth == 0 and Heap.gc_needed?() do
      extra =
        case result do
          {:ok, v} -> [v, fun | args]
          _ -> [fun | args]
        end

      Heap.gc(extra)
    end

    result
  end

  def compile(%Bytecode.Function{} = fun) do
    module = module_name(fun)
    entry = ctx_entry_name()

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
    ctx_entry = ctx_entry_name()

    with {:ok, instructions} <- Decoder.decode(fun.byte_code, fun.arg_count),
         optimized = Optimizer.optimize(instructions, fun.constants),
         {:ok, {slot_count, block_forms}} <- Lowering.lower(fun, optimized),
         {:ok, _module, binary} <-
           Forms.compile_module(
             module,
             entry,
             ctx_entry,
             fun,
             fun.arg_count,
             slot_count,
             block_forms
           ) do
      {:ok, module, ctx_entry, binary}
    end
  end

  @compiler_version 1

  defp module_name(fun) do
    atoms = Heap.get_fn_atoms(fun.byte_code, {})

    hash =
      :crypto.hash(:sha256, [
        <<@compiler_version>>,
        fun.byte_code,
        <<fun.arg_count::16, fun.var_count::16, fun.func_kind::8>>,
        :erlang.term_to_binary(Enum.map(fun.closure_vars, &closure_var_key/1)),
        :erlang.term_to_binary(Enum.map(fun.constants, &constant_key/1)),
        :erlang.term_to_binary(atoms)
      ])
      |> binary_part(0, 8)
      |> Base.encode16(case: :lower)

    Module.concat(QuickBEAM.VM.Compiled, "F#{hash}")
  end

  defp closure_var_key(%{closure_type: t, var_idx: i}), do: {t, i}

  defp constant_key(%Bytecode.Function{byte_code: bc, arg_count: ac, var_count: vc, func_kind: fk, closure_vars: cvs, constants: consts}),
    do: {:fn, bc, ac, vc, fk, Enum.map(cvs, &closure_var_key/1), Enum.map(consts, &constant_key/1)}

  defp constant_key(other), do: other

  defp entry_name, do: :run
  defp ctx_entry_name, do: :run_ctx
end
