defmodule QuickBEAM.VM.Compiler do
  @moduledoc "JIT compiler entry point: lowers bytecode to BEAM modules, caches them, and invokes compiled functions."

  import QuickBEAM.VM.Heap.Keys, only: [promise_state: 0, promise_value: 0]

  alias QuickBEAM.VM.{Bytecode, Decoder, Heap, PromiseState}
  alias QuickBEAM.VM.Compiler.{Forms, Lowering, Optimizer, Runner}

  @type compiled_fun :: {module(), atom()}
  @type beam_file :: {:beam_file, module(), list(), list(), list(), list()}

  @doc "Invokes the runtime object represented by this module."
  def invoke(fun, args), do: invoke(fun, args, nil)

  def invoke(fun, args, base_ctx) do
    depth = Heap.get_invoke_depth()
    Heap.put_invoke_depth(depth + 1)

    result =
      try do
        Runner.invoke(fun, args, base_ctx)
      catch
        {:js_throw, error} -> {:error, {:js_throw, error}}
      after
        Heap.put_invoke_depth(depth)
      end

    result = if depth == 0, do: settle_top_level_result(result), else: result

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

  defp settle_top_level_result({:ok, value}) do
    unless Heap.microtasks_empty?() do
      PromiseState.drain_microtasks()
    end

    {:ok, unwrap_resolved_promise(value)}
  end

  defp settle_top_level_result(result), do: result

  defp unwrap_resolved_promise(value, depth \\ 0)

  defp unwrap_resolved_promise({:obj, ref}, depth) when depth < 10 do
    case Heap.get_obj(ref, %{}) do
      %{promise_state() => :resolved, promise_value() => value} ->
        unwrap_resolved_promise(value, depth + 1)

      _ ->
        {:obj, ref}
    end
  end

  defp unwrap_resolved_promise(value, _depth), do: value

  @doc "Compiles a bytecode function for optimized execution."
  def compile(%Bytecode.Function{} = fun) do
    atoms = Heap.get_fn_atoms(fun, Heap.get_atoms())
    module = module_name(fun, atoms)
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

  @doc "Returns a disassembly of bytecode for diagnostics."
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
    atoms = Heap.get_fn_atoms(fun, Heap.get_atoms())
    module = module_name(fun, atoms)
    entry = entry_name()
    ctx_entry = ctx_entry_name()

    with {:decode, {:ok, instructions}} <- {:decode, Decoder.decode(fun.byte_code, fun.arg_count)},
         optimized = Optimizer.optimize(instructions, fun.constants),
         {:lower, {:ok, {slot_count, block_forms}}} <- {:lower, Lowering.lower(fun, optimized)},
         {:forms, {:ok, _module, binary}} <-
           {:forms,
            Forms.compile_module(
              module,
              entry,
              ctx_entry,
              fun,
              fun.arg_count,
              slot_count,
              block_forms
            )} do
      {:ok, module, ctx_entry, binary}
    else
      {:decode, {:error, reason}} -> {:error, {:decode_failed, reason}}
      {:lower, {:error, reason}} -> {:error, reason}
      {:forms, {:error, reason}} -> {:error, {:beam_compile_failed, reason}}
    end
  end

  defp module_name(fun, atoms) do
    hash =
      {fun, atoms}
      |> :erlang.term_to_binary()
      |> then(&:crypto.hash(:sha256, &1))
      |> binary_part(0, 8)
      |> Base.encode16(case: :lower)

    Module.concat(QuickBEAM.VM.Compiled, "F#{hash}")
  end

  defp entry_name, do: :run
  defp ctx_entry_name, do: :run_ctx
end
