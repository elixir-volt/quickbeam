defmodule QuickBEAM.VM.Compiler do
  @moduledoc "JIT compiler entry point: lowers bytecode to BEAM modules, caches them, and invokes compiled functions."

  import QuickBEAM.VM.Heap.Keys, only: [promise_state: 0, promise_value: 0]

  alias QuickBEAM.VM.Compiler.{Forms, Lowering, Optimizer, Runner}
  alias QuickBEAM.VM.Compiler.Analysis.CFG
  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.PromiseState

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

  @doc "Compiles a VM function for optimized execution."
  def compile(%QuickBEAM.VM.Function{} = fun) do
    atoms = Heap.get_fn_atoms(fun, Heap.get_atoms())
    module = module_name(fun, atoms)
    entry = ctx_entry_name()

    case :code.is_loaded(module) do
      {:file, _} ->
        {:ok, {module, entry}}

      false ->
        with {:ok, binary} <- cached_or_compile_binary(module, fun),
             {:module, ^module} <- :code.load_binary(module, ~c"quickbeam_compiler", binary) do
          {:ok, {module, entry}}
        else
          {:error, _} = error -> error
          other -> {:error, {:load_failed, other}}
        end
    end
  end

  def compile(_), do: {:error, :var_refs_not_supported}

  defp cached_or_compile_binary(module, fun) do
    case read_cached_binary(module) do
      {:ok, binary} ->
        {:ok, binary}

      :miss ->
        with {:ok, ^module, _entry, binary} <- compile_binary(fun) do
          write_cached_binary(module, binary)
          {:ok, binary}
        end
    end
  end

  defp read_cached_binary(module) do
    with dir when is_binary(dir) <- compiler_cache_dir(),
         path = compiler_cache_path(dir, module),
         {:ok, binary} <- File.read(path) do
      {:ok, binary}
    else
      _ -> :miss
    end
  end

  defp write_cached_binary(module, binary) do
    with dir when is_binary(dir) <- compiler_cache_dir(),
         :ok <- File.mkdir_p(dir) do
      File.write(compiler_cache_path(dir, module), binary)
    else
      _ -> :ok
    end

    :ok
  end

  defp compiler_cache_dir do
    if System.get_env("QUICKBEAM_COMPILER_CACHE") in ["1", "true", "TRUE"] do
      System.get_env("QUICKBEAM_COMPILER_CACHE_DIR") ||
        Path.join(System.tmp_dir!(), "quickbeam-compiler-cache-v1")
    end
  end

  defp compiler_cache_path(dir, module) do
    module_name = module |> Atom.to_string() |> String.replace_prefix("Elixir.", "")
    Path.join(dir, module_name <> ".beam")
  end

  @doc "Returns a disassembly of bytecode for diagnostics."
  def disasm(%QuickBEAM.VM.Function{} = fun) do
    case disasm_compiled(fun) do
      {:ok, _} = ok -> ok
      {:error, _} = error -> disasm_single_nested(fun.constants, error)
    end
  end

  def disasm(_), do: {:error, :var_refs_not_supported}

  defp disasm_compiled(%QuickBEAM.VM.Function{} = fun) do
    with {:ok, _module, _entry, binary} <- compile_binary(fun),
         {:beam_file, _, _, _, _, _} = beam_file <- :beam_disasm.file(binary) do
      {:ok, beam_file}
    else
      {:error, _, _} = error -> {:error, error}
      {:error, _} = error -> error
    end
  end

  defp disasm_single_nested(constants, original_error) do
    case Enum.filter(constants, &match?(%QuickBEAM.VM.Function{}, &1)) do
      [%QuickBEAM.VM.Function{} = fun] -> disasm(fun)
      _ -> original_error
    end
  end

  defp compile_binary(%QuickBEAM.VM.Function{} = fun) do
    atoms = Heap.get_fn_atoms(fun, Heap.get_atoms())
    module = module_name(fun, atoms)
    entry = entry_name()
    ctx_entry = ctx_entry_name()

    with :ok <- reject_mapped_arguments(fun),
         :ok <- reject_generator_cleanup_resume(fun),
         {:instructions, {:ok, instructions}} <- {:instructions, instructions(fun)},
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
      {:error, :mapped_arguments} -> {:error, :mapped_arguments}
      {:error, :generator_cleanup_resume} -> {:error, :generator_cleanup_resume}
      {:instructions, {:error, reason}} -> {:error, {:decode_failed, reason}}
      {:lower, {:error, reason}} -> {:error, reason}
      {:forms, {:error, reason}} -> {:error, {:beam_compile_failed, reason}}
    end
  end

  defp reject_mapped_arguments(%QuickBEAM.VM.Function{arg_count: arg_count, source: source})
       when arg_count > 0 and is_binary(source) do
    if String.contains?(source, "arguments"), do: {:error, :mapped_arguments}, else: :ok
  end

  defp reject_mapped_arguments(_fun), do: :ok

  defp reject_generator_cleanup_resume(%QuickBEAM.VM.Function{func_kind: 1} = fun) do
    instructions = fun |> instructions() |> elem(1)

    if generator_cleanup_resume?(instructions),
      do: {:error, :generator_cleanup_resume},
      else: :ok
  end

  defp reject_generator_cleanup_resume(_fun), do: :ok

  defp generator_cleanup_resume?(instructions) do
    has_yield? = Enum.any?(instructions, &opcode?(&1, [:yield, :yield_star, :async_yield_star]))
    has_cleanup? = Enum.any?(instructions, &opcode?(&1, [:iterator_close, :gosub]))
    has_yield? and has_cleanup?
  end

  defp opcode?({op, _args}, names) do
    case CFG.opcode_name(op) do
      {:ok, name} -> name in names
      _ -> false
    end
  end

  defp instructions(fun), do: QuickBEAM.VM.Compiler.FunctionInfo.instructions(fun)

  defp module_name(fun, atoms) do
    hash =
      {stable_function_key(fun), atoms}
      |> :erlang.term_to_binary()
      |> then(&:crypto.hash(:sha256, &1))
      |> binary_part(0, 8)
      |> Base.encode16(case: :lower)

    Module.concat(QuickBEAM.VM.Compiled, "F#{hash}")
  end

  defp stable_function_key(%QuickBEAM.VM.Function{} = fun) do
    %{
      fun
      | id: 0,
        constants: Enum.map(fun.constants, &stable_constant_key/1)
    }
  end

  defp stable_constant_key(%QuickBEAM.VM.Function{} = fun), do: stable_function_key(fun)
  defp stable_constant_key(value), do: value

  defp entry_name, do: :run
  defp ctx_entry_name, do: :run_ctx
end
