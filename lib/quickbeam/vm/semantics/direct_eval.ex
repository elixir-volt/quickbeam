defmodule QuickBEAM.VM.Semantics.DirectEval do
  @moduledoc "Direct-eval preparation helpers kept outside the interpreter dispatch loop."

  alias QuickBEAM.JS.Error, as: JSError

  alias QuickBEAM.VM.{
    BytecodeParser,
    Function,
    Heap,
    JSThrow,
    Names,
    Opcodes,
    PredefinedAtoms,
    RuntimeState,
    Value
  }

  alias QuickBEAM.VM.ObjectModel.InternalMethods
  alias QuickBEAM.VM.Semantics.Eval, as: EvalSemantics
  alias QuickBEAM.VM.Semantics.Values

  @op_define_var Opcodes.num(:define_var)
  @op_check_define_var Opcodes.num(:check_define_var)
  @op_define_func Opcodes.num(:define_func)

  defmodule Caller do
    @moduledoc false
    defstruct [
      :code,
      :ctx,
      :locals,
      :var_refs,
      :l2v,
      :gas,
      :var_objects,
      :keep_declared?,
      :eval_with_ctx,
      :function_instructions
    ]
  end

  def eval(%Caller{} = caller) do
    %Caller{
      code: code,
      ctx: ctx,
      locals: locals,
      var_refs: var_refs,
      l2v: l2v,
      gas: gas,
      var_objects: var_objs,
      keep_declared?: keep_declared?,
      eval_with_ctx: eval_with_ctx,
      function_instructions: function_instructions
    } = caller

    case compile(ctx.runtime_pid, strict_code(ctx, code)) do
      {:ok, parsed} ->
        run_compiled_eval(
          parsed,
          code,
          ctx,
          locals,
          var_refs,
          l2v,
          gas,
          var_objs,
          keep_declared?,
          eval_with_ctx,
          function_instructions
        )

      error ->
        handle_compile_error(error)
    end
  end

  def strict_code(ctx, code) do
    if strict_mode?(ctx), do: "\"use strict\";\n" <> code, else: code
  end

  def compile(nil, code), do: QuickBEAM.JS.Compiler.compile(code)

  def compile(runtime_pid, code) do
    case QuickBEAM.Runtime.compile(runtime_pid, code) do
      {:ok, bc} -> BytecodeParser.decode(bc)
      error -> error
    end
  end

  def reject_lexical_conflicts!(ctx, declared_names) do
    EvalSemantics.reject_lexical_conflicts!(ctx, declared_names, strict_mode?(ctx))
  end

  def declared_names(%Function{} = fun, atoms, instructions_fun)
      when is_function(instructions_fun, 1) do
    local_names =
      fun.locals
      |> Enum.map(&Names.resolve_display_name(&1.name))
      |> Enum.filter(&is_binary/1)

    instruction_names =
      case instructions_fun.(fun) do
        {:ok, insns} -> Enum.reduce(insns, [], &collect_declared_instruction_name(&1, &2, atoms))
        _ -> []
      end

    MapSet.new(local_names ++ instruction_names)
  end

  def declared_names(_, _, _), do: MapSet.new()

  def handle_compile_error({:error, {:parse_error, errors}}),
    do: JSThrow.syntax_error!(parse_error_message(errors))

  def handle_compile_error({:error, msg}) when is_binary(msg), do: JSThrow.syntax_error!(msg)

  def handle_compile_error({:error, %JSError{name: name, message: msg}}),
    do: throw({:js_throw, QuickBEAM.VM.Heap.make_error(msg, name)})

  def handle_compile_error(_), do: {:undefined, %{}}

  def merge_var_object_globals(globals, []), do: globals

  def merge_var_object_globals(globals, var_objs) do
    Enum.reduce(var_objs, globals, fn
      {:obj, ref}, acc ->
        case Heap.get_obj(ref, %{}) do
          map when is_map(map) -> Map.merge(acc, map)
          _ -> acc
        end

      _, acc ->
        acc
    end)
  end

  def collect_captured_globals({:closure, captured, %Function{closure_vars: closure_vars}}) do
    Enum.reduce(closure_vars, %{}, fn closure_var, acc ->
      case Names.resolve_display_name(closure_var.name) do
        name when is_binary(name) ->
          val =
            case Map.get(captured, capture_key(closure_var), :undefined) do
              {:cell, ref} -> Heap.get_cell(ref)
              other -> other
            end

          Map.put(acc, name, val)

        _ ->
          acc
      end
    end)
  end

  def collect_captured_globals(_), do: %{}

  def collect_caller_locals(locals, %{current_func: current_func, arg_buf: arg_buf}) do
    case current_func do
      {:closure, _, %Function{locals: local_defs, arg_count: arg_count}} ->
        build_local_map(local_defs, arg_count, arg_buf, locals)

      %Function{locals: local_defs, arg_count: arg_count} ->
        build_local_map(local_defs, arg_count, arg_buf, locals)

      _ ->
        %{}
    end
  end

  def scoped_globals(ctx_globals, eval_scope_globals, declared_names, keep_declared?) do
    base_globals =
      if keep_declared?,
        do: Map.drop(ctx_globals, MapSet.to_list(declared_names)),
        else: ctx_globals

    scoped_globals =
      if keep_declared?,
        do: Map.drop(eval_scope_globals, MapSet.to_list(declared_names)),
        else: eval_scope_globals

    {base_globals, scoped_globals, Map.merge(base_globals, scoped_globals)}
  end

  def install_eval_arguments(merged_globals, ctx) do
    arguments_key = RuntimeState.arguments_object_key(ctx.current_func, ctx.arg_buf)
    {arguments_obj, created?} = eval_arguments_object(merged_globals, ctx, arguments_key)
    {Map.put(merged_globals, "arguments", arguments_obj), arguments_key, arguments_obj, created?}
  end

  def visible_declared_names(base_globals, eval_scope_globals, declared_names, assigned_names) do
    base_globals
    |> Map.merge(eval_scope_globals)
    |> Map.put("arguments", :present)
    |> Map.keys()
    |> Enum.filter(&is_binary/1)
    |> MapSet.new()
    |> MapSet.intersection(MapSet.union(declared_names, assigned_names))
  end

  def abrupt_visible_names(base_globals, eval_scope_globals) do
    base_globals
    |> Map.merge(eval_scope_globals)
    |> Map.put("arguments", :present)
    |> Map.keys()
    |> Enum.filter(&is_binary/1)
    |> MapSet.new()
  end

  def put_created_arguments(globals, true, key, arguments), do: Map.put(globals, key, arguments)
  def put_created_arguments(globals, false, _key, _arguments), do: globals

  def filter_local_transients(%{current_func: current_func}, transients) do
    case current_func do
      %Function{name: {:predefined, 81}} -> transients
      {:closure, _, %Function{name: {:predefined, 81}}} -> transients
      %Function{locals: locals} -> Map.drop(transients, local_names(locals))
      {:closure, _, %Function{locals: locals}} -> Map.drop(transients, local_names(locals))
      _ -> transients
    end
  end

  def apply_transients(ctx, current_func, var_objs, transient_globals, keep_declared?) do
    if transient_globals != %{} do
      if var_objs != [] do
        for {name, val} <- transient_globals, var_obj <- var_objs do
          write_var_object!(ctx, var_obj, name, val)
        end
      end

      if keep_declared? do
        apply_transient_captured_vars(
          current_func,
          transient_globals,
          MapSet.new(Map.keys(transient_globals))
        )
      end
    end
  end

  def write_back_vars(ctx, original_globals, var_objs, declared_names, vrefs, l2v) do
    new_globals = Heap.get_persistent_globals() || %{}

    validate_strict_function_assignment!(ctx, new_globals)

    write_back_locals(
      ctx.current_func,
      vrefs,
      l2v,
      new_globals,
      ctx,
      original_globals,
      declared_names
    )

    if match?({:closure, _, %Function{}}, ctx.current_func) do
      write_back_captured_vars(ctx.current_func, new_globals, original_globals, declared_names)
    end

    write_back_var_objects(ctx, var_objs, new_globals, original_globals)
  end

  def restore_restores(mark) do
    restores = Heap.get_eval_restore_stack()
    {to_restore, keep} = Enum.split(restores, length(restores) - mark)

    Enum.each(to_restore, fn {ref, old_val} ->
      Heap.put_cell(ref, old_val)
    end)

    Heap.put_eval_restore_stack(keep)
  end

  defp run_compiled_eval(
         parsed,
         code,
         ctx,
         locals,
         var_refs,
         l2v,
         gas,
         var_objs,
         keep_declared?,
         eval_with_ctx,
         function_instructions
       ) do
    declared_names = declared_names(parsed.value, parsed.atoms, function_instructions)
    assigned_names = EvalSemantics.simple_assigned_names(code)
    reject_lexical_conflicts!(ctx, declared_names)

    eval_globals = collect_caller_locals(locals, ctx)
    captured_globals = collect_captured_globals(ctx.current_func)

    eval_scope_globals =
      merge_var_object_globals(Map.merge(eval_globals, captured_globals), var_objs)

    {base_globals, _scoped_globals, merged_globals} =
      scoped_globals(ctx.globals, eval_scope_globals, declared_names, keep_declared?)

    {eval_ctx_globals, arguments_key, arguments_obj, created_arguments?} =
      install_eval_arguments(merged_globals, ctx)

    visible_declared_names =
      visible_declared_names(base_globals, eval_scope_globals, declared_names, assigned_names)

    abrupt_visible_names = abrupt_visible_names(base_globals, eval_scope_globals)

    eval_opts = %{
      gas: gas,
      runtime_pid: ctx.runtime_pid,
      globals: eval_ctx_globals,
      this: ctx.this,
      arg_buf: ctx.arg_buf,
      current_func: ctx.current_func,
      new_target: ctx.new_target
    }

    pre_eval_globals = Heap.get_persistent_globals() || %{}

    case eval_with_ctx.(parsed.value, [], eval_opts, parsed.atoms) do
      {:ok, val, final_ctx} ->
        returned_transients =
          commit_eval_transients(
            ctx,
            var_objs,
            keep_declared?,
            pre_eval_globals,
            declared_names,
            assigned_names,
            var_refs,
            l2v,
            success_transients(
              final_ctx,
              visible_declared_names,
              created_arguments?,
              arguments_key,
              arguments_obj
            )
          )

        {val, returned_transients}

      {:error, {:js_throw, val}} ->
        commit_eval_transients(
          ctx,
          var_objs,
          keep_declared?,
          pre_eval_globals,
          declared_names,
          assigned_names,
          var_refs,
          l2v,
          abrupt_transients(
            abrupt_visible_names,
            created_arguments?,
            arguments_key,
            arguments_obj
          )
        )

        throw({:js_throw, val})

      _ ->
        {:undefined, %{}}
    end
  end

  defp success_transients(
         final_ctx,
         visible_declared_names,
         created_arguments?,
         arguments_key,
         arguments_obj
       ) do
    (Heap.get_persistent_globals() || %{})
    |> Map.merge(Map.get(final_ctx || %{}, :globals, %{}))
    |> Map.take(MapSet.to_list(visible_declared_names))
    |> put_created_arguments(created_arguments?, arguments_key, arguments_obj)
  end

  defp abrupt_transients(abrupt_visible_names, created_arguments?, arguments_key, arguments_obj) do
    (Heap.get_persistent_globals() || %{})
    |> Map.take(MapSet.to_list(abrupt_visible_names))
    |> put_created_arguments(created_arguments?, arguments_key, arguments_obj)
  end

  defp commit_eval_transients(
         ctx,
         var_objs,
         keep_declared?,
         pre_eval_globals,
         declared_names,
         assigned_names,
         var_refs,
         l2v,
         transient_globals
       ) do
    returned_transients = filter_local_transients(ctx, transient_globals)

    apply_transients(ctx, ctx.current_func, var_objs, transient_globals, keep_declared?)

    write_back_vars(
      ctx,
      pre_eval_globals,
      var_objs,
      declared_names,
      var_refs,
      l2v
    )

    cleanup_names = MapSet.union(declared_names, assigned_names)
    clean_eval_globals(pre_eval_globals, returned_transients, cleanup_names)
    returned_transients
  end

  defp clean_eval_globals(pre_eval_globals, preserved_globals, cleanup_names) do
    post = Heap.get_persistent_globals() || %{}
    preserved_existing = Map.take(preserved_globals, Map.keys(pre_eval_globals))

    cleaned =
      Enum.reduce(post, post, fn {key, _val}, acc ->
        case Map.fetch(pre_eval_globals, key) do
          {:ok, old_val} -> Map.put(acc, key, Map.get(preserved_existing, key, old_val))
          :error -> Map.delete(acc, key)
        end
      end)

    Heap.put_persistent_globals(cleaned)
    clean_eval_global_object(pre_eval_globals, preserved_globals, cleanup_names)
  end

  defp clean_eval_global_object(pre_eval_globals, preserved_globals, cleanup_names) do
    case Map.get(pre_eval_globals, "globalThis") do
      {:obj, ref} ->
        case Heap.get_obj(ref, %{}) do
          map when is_map(map) ->
            preserved_existing = Map.take(preserved_globals, Map.keys(pre_eval_globals))

            cleaned =
              Enum.reduce(map, map, fn
                {key, _val}, acc when is_binary(key) ->
                  case Map.fetch(pre_eval_globals, key) do
                    {:ok, old_val} ->
                      Map.put(acc, key, Map.get(preserved_existing, key, old_val))

                    :error ->
                      if Map.has_key?(preserved_globals, key) or
                           not MapSet.member?(cleanup_names, key),
                         do: acc,
                         else: Map.delete(acc, key)
                  end

                _entry, acc ->
                  acc
              end)

            Heap.put_obj(ref, cleaned)

          _ ->
            :ok
        end

      _ ->
        :ok
    end
  end

  defp eval_arguments_object(merged_globals, ctx, arguments_key) do
    case Map.fetch(merged_globals, arguments_key) do
      {:ok, arguments} ->
        {arguments, false}

      :error ->
        case Map.fetch(merged_globals, "arguments") do
          {:ok, arguments} -> {arguments, false}
          :error -> cached_or_new_arguments(ctx, arguments_key)
        end
    end
  end

  defp cached_or_new_arguments(ctx, arguments_key) do
    case RuntimeState.get_arguments_object(arguments_key) do
      nil ->
        arguments =
          Heap.wrap_arguments(Tuple.to_list(ctx.arg_buf),
            strict: strict_mode?(ctx),
            callee: ctx.current_func
          )

        RuntimeState.put_arguments_object(arguments_key, arguments)
        {arguments, true}

      arguments ->
        {arguments, true}
    end
  end

  defp local_names(locals) do
    locals
    |> Enum.map(&Names.resolve_display_name(&1.name))
    |> Enum.filter(&is_binary/1)
  end

  defp validate_strict_function_assignment!(ctx, new_globals) do
    if strict_mode?(ctx) do
      func_name = current_func_name(ctx.current_func)

      if func_name && Map.has_key?(new_globals, func_name) do
        old_val =
          case ctx.current_func do
            {:closure, _, %Function{} = function} -> Heap.get_parent_ctor(function)
            _ -> nil
          end

        new_val = Map.get(new_globals, func_name)

        if old_val == nil and new_val != ctx.current_func and new_val != :undefined do
          JSThrow.type_error!("Assignment to constant variable.")
        end
      end
    end
  end

  defp write_back_locals(
         {:closure, _, %Function{locals: local_defs}},
         vrefs,
         l2v,
         new_globals,
         ctx,
         original_globals,
         declared_names
       ) do
    do_write_back(local_defs, vrefs, l2v, new_globals, ctx, original_globals, declared_names)
  end

  defp write_back_locals(
         %Function{locals: local_defs},
         vrefs,
         l2v,
         new_globals,
         ctx,
         original_globals,
         declared_names
       ) do
    do_write_back(local_defs, vrefs, l2v, new_globals, ctx, original_globals, declared_names)
  end

  defp write_back_locals(_, _, _, _, _, _, _), do: :ok

  defp do_write_back(local_defs, vrefs, l2v, new_globals, ctx, original_globals, declared_names) do
    func_name = current_func_name(ctx.current_func)

    for {local, idx} <- Enum.with_index(local_defs),
        name = Names.resolve_display_name(local.name),
        is_binary(name),
        not MapSet.member?(declared_names, name),
        name != func_name,
        Map.has_key?(new_globals, name),
        new_val = Map.get(new_globals, name),
        Map.get(original_globals, name) != new_val do
      case Map.get(l2v, idx) do
        nil ->
          :ok

        vref_idx when vref_idx < tuple_size(vrefs) ->
          case elem(vrefs, vref_idx) do
            {:cell, ref} -> Heap.put_cell(ref, new_val)
            _ -> :ok
          end

        _ ->
          :ok
      end
    end
  end

  defp write_back_captured_vars(
         {:closure, captured, %Function{closure_vars: closure_vars}},
         new_globals,
         original_globals,
         declared_names
       ) do
    for closure_var <- closure_vars,
        name = Names.resolve_display_name(closure_var.name),
        is_binary(name),
        not MapSet.member?(declared_names, name),
        Map.has_key?(new_globals, name),
        Map.get(original_globals, name) != Map.get(new_globals, name) do
      case Map.get(captured, capture_key(closure_var)) do
        {:cell, ref} -> Heap.put_cell(ref, Map.get(new_globals, name))
        _ -> :ok
      end
    end
  end

  defp write_back_captured_vars(_, _, _, _), do: :ok

  defp write_back_var_objects(_ctx, [], _new_globals, _original_globals), do: :ok

  defp write_back_var_objects(ctx, var_objs, new_globals, original_globals) do
    for {name, val} <- new_globals,
        is_binary(name),
        Map.has_key?(original_globals, name),
        Map.get(original_globals, name) != val do
      for var_obj <- var_objs, do: write_var_object!(ctx, var_obj, name, val)
    end
  end

  defp apply_transient_captured_vars(
         {:closure, captured, %Function{closure_vars: closure_vars}},
         new_globals,
         declared_names
       ) do
    for closure_var <- closure_vars,
        name = Names.resolve_display_name(closure_var.name),
        is_binary(name),
        MapSet.member?(declared_names, name),
        Map.has_key?(new_globals, name) do
      case Map.get(captured, capture_key(closure_var)) do
        {:cell, ref} ->
          old_val = Heap.get_cell(ref)
          Heap.put_eval_restore_stack([{ref, old_val} | Heap.get_eval_restore_stack()])
          Heap.put_cell(ref, Map.get(new_globals, name))

        _ ->
          :ok
      end
    end
  end

  defp apply_transient_captured_vars(_, _, _), do: :ok

  defp current_func_name({:closure, _, %Function{name: name}}), do: name
  defp current_func_name(%Function{name: name}), do: name
  defp current_func_name(_), do: nil

  defp build_local_map(local_defs, arg_count, arg_buf, locals) do
    local_defs
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {local, idx}, acc ->
      with name when is_binary(name) <- local.name,
           val when val != :undefined <- local_value(idx, arg_count, arg_buf, locals) do
        Map.put(acc, name, val)
      else
        _ -> acc
      end
    end)
  end

  defp local_value(idx, _arg_count, arg_buf, _locals) when idx < tuple_size(arg_buf) do
    elem(arg_buf, idx)
  end

  defp local_value(idx, _arg_count, _arg_buf, locals) do
    if idx < tuple_size(locals), do: elem(locals, idx), else: :undefined
  end

  defp capture_key(%{closure_type: type, var_idx: idx}), do: {type, idx}

  defp collect_declared_instruction_name({op, [atom_ref, _scope]}, acc, atoms)
       when op in [@op_define_var, @op_check_define_var] do
    prepend_declared_atom(atom_ref, acc, atoms)
  end

  defp collect_declared_instruction_name({@op_define_func, [atom_ref, _flags]}, acc, atoms) do
    prepend_declared_atom(atom_ref, acc, atoms)
  end

  defp collect_declared_instruction_name(_, acc, _atoms), do: acc

  defp prepend_declared_atom(atom_ref, acc, atoms) do
    case resolve_declared_atom(atom_ref, atoms) do
      name when is_binary(name) -> [name | acc]
      _ -> acc
    end
  end

  defp parse_error_message([%{message: message} | _]), do: message
  defp parse_error_message(_errors), do: "Syntax error"

  defp strict_mode?(ctx), do: Value.strict_context?(ctx)

  defp write_var_object!(ctx, var_obj, name, val) do
    if Values.truthy?(InternalMethods.set(var_obj, name, val)) do
      :ok
    else
      if strict_mode?(ctx), do: JSThrow.type_error!("Cannot assign to #{name}"), else: :ok
    end
  end

  defp resolve_declared_atom({:predefined, idx}, _atoms), do: PredefinedAtoms.lookup(idx)

  defp resolve_declared_atom(idx, atoms)
       when is_integer(idx) and idx >= 0 and idx < tuple_size(atoms),
       do: elem(atoms, idx)

  defp resolve_declared_atom(name, _atoms) when is_binary(name), do: name
  defp resolve_declared_atom(_, _atoms), do: nil
end
