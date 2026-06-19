defmodule QuickBEAM.VM.Compiler do
  @moduledoc """
  BEAM-code compiler entry point.

  The compiler lowers QuickJS bytecode to Erlang abstract forms, loads the
  resulting BEAM module, caches it, and invokes compiled functions. It does not
  compile ECMA parse nodes directly: QuickJS-NG owns parsing, early bytecode
  generation, and most syntax-directed work. Observable ECMAScript semantics are
  preserved through `QuickBEAM.VM.Compiler.RuntimeABI`, shared semantic modules,
  `ObjectModel`, `Invocation`, `GlobalEnvironment`, and interpreter fallback.

  Unsupported bytecode patterns fall back to the interpreter when correctness
  requires it; permanently unsupported compiler results are cached as unsupported.
  """

  import QuickBEAM.VM.Heap.Keys, only: [promise_state: 0, promise_value: 0]

  alias QuickBEAM.VM.Compiler.{Forms, Lowering, Optimizer, Runner}
  alias QuickBEAM.VM.Compiler.Analysis.CFG
  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.Promise

  @type compiled_fun :: {module(), atom()}
  @type beam_file :: {:beam_file, module(), list(), list(), list(), list()}

  @compiler_cache_version "v6"
  @exception_fallback_min_instruction_count 100
  @max_instruction_count 20_000
  @max_atom_count 10_000
  @max_constant_count 10_000
  @max_block_form_count 5_000

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
      Promise.drain_microtasks()
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
    if interpreter_exception_region_fallback?(fun) do
      {:error, :compiler_resource_limit}
    else
      compile_supported(fun)
    end
  end

  def compile(_), do: {:error, :var_refs_not_supported}

  defp compile_supported(%QuickBEAM.VM.Function{} = fun) do
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

  defp interpreter_exception_region_fallback?(%QuickBEAM.VM.Function{
         func_kind: 1,
         instructions: instructions
       }) do
    instructions
    |> tuple_to_list()
    |> Enum.any?(&catch_opcode?/1)
  end

  defp interpreter_exception_region_fallback?(%QuickBEAM.VM.Function{instructions: instructions}) do
    instruction_list = tuple_to_list(instructions)

    Enum.any?(instruction_list, &computed_method_opcode?/1) or
      large_exception_region_fallback?(instruction_list)
  end

  defp large_exception_region_fallback?(instruction_list) do
    length(instruction_list) >= @exception_fallback_min_instruction_count and
      Enum.any?(instruction_list, &catch_opcode?/1)
  end

  defp tuple_to_list(instructions) when is_tuple(instructions), do: Tuple.to_list(instructions)
  defp tuple_to_list(instructions) when is_list(instructions), do: instructions
  defp tuple_to_list(_), do: []

  defp catch_opcode?({opcode, _operands}) do
    case QuickBEAM.VM.OpcodeSpec.name(opcode) do
      {:ok, :catch} -> true
      _ -> false
    end
  end

  defp catch_opcode?(_), do: false

  defp computed_method_opcode?({opcode, _operands}) do
    case QuickBEAM.VM.OpcodeSpec.name(opcode) do
      {:ok, :define_method_computed} -> true
      _ -> false
    end
  end

  defp computed_method_opcode?(_), do: false

  @doc "Returns the compiler cache directory when disk caching is enabled."
  def cache_dir, do: compiler_cache_dir()

  @doc "Deletes cached compiled BEAM modules from disk."
  def clear_cache do
    case compiler_cache_dir() do
      dir when is_binary(dir) ->
        case File.rm_rf(dir) do
          {:ok, _} -> :ok
          {:error, reason, path} -> {:error, {reason, path}}
        end

      nil ->
        :ok
    end
  end

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
        Path.join(
          :filename.basedir(:user_cache, "quickbeam"),
          "compiler-cache/#{@compiler_cache_version}"
        )
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
         :ok <- reject_resource_limits(fun, atoms, instructions),
         optimized = Optimizer.optimize(instructions, fun.constants),
         {:lower, {:ok, {slot_count, block_forms}}} <- {:lower, Lowering.lower(fun, optimized)},
         :ok <- reject_block_form_limit(block_forms),
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
      {:error, :compiler_resource_limit} -> {:error, :compiler_resource_limit}
      {:instructions, {:error, reason}} -> {:error, {:decode_failed, reason}}
      {:lower, {:error, reason}} -> {:error, reason}
      {:forms, {:error, reason}} -> {:error, {:beam_compile_failed, reason}}
    end
  end

  defp reject_resource_limits(fun, atoms, instructions) do
    cond do
      length(instructions) > @max_instruction_count -> {:error, :compiler_resource_limit}
      tuple_size(atoms) > @max_atom_count -> {:error, :compiler_resource_limit}
      length(List.wrap(fun.constants)) > @max_constant_count -> {:error, :compiler_resource_limit}
      true -> :ok
    end
  end

  defp reject_block_form_limit(block_forms) do
    if length(block_forms) > @max_block_form_count,
      do: {:error, :compiler_resource_limit},
      else: :ok
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
      {@compiler_cache_version, stable_function_key(fun), atoms}
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
