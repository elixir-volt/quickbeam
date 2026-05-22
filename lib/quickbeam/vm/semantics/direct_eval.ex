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

  alias QuickBEAM.VM.Semantics.Eval, as: EvalSemantics

  @op_define_var Opcodes.num(:define_var)
  @op_check_define_var Opcodes.num(:check_define_var)
  @op_define_func Opcodes.num(:define_func)

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

  def apply_transients(current_func, var_objs, transient_globals, keep_declared?) do
    if transient_globals != %{} do
      if var_objs != [] do
        for {name, val} <- transient_globals, var_obj <- var_objs do
          QuickBEAM.VM.ObjectModel.Put.put(var_obj, name, val)
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

    write_back_var_objects(var_objs, new_globals, original_globals)
  end

  def restore_restores(mark) do
    restores = Heap.get_eval_restore_stack()
    {to_restore, keep} = Enum.split(restores, length(restores) - mark)

    Enum.each(to_restore, fn {ref, old_val} ->
      Heap.put_cell(ref, old_val)
    end)

    Heap.put_eval_restore_stack(keep)
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

  defp write_back_var_objects([], _new_globals, _original_globals), do: :ok

  defp write_back_var_objects(var_objs, new_globals, original_globals) do
    for {name, val} <- new_globals,
        is_binary(name),
        Map.has_key?(original_globals, name),
        Map.get(original_globals, name) != val do
      for var_obj <- var_objs, do: QuickBEAM.VM.ObjectModel.Put.put(var_obj, name, val)
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

  defp resolve_declared_atom({:predefined, idx}, _atoms), do: PredefinedAtoms.lookup(idx)

  defp resolve_declared_atom(idx, atoms)
       when is_integer(idx) and idx >= 0 and idx < tuple_size(atoms),
       do: elem(atoms, idx)

  defp resolve_declared_atom(name, _atoms) when is_binary(name), do: name
  defp resolve_declared_atom(_, _atoms), do: nil
end
