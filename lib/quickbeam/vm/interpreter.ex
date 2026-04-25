defmodule QuickBEAM.VM.Interpreter do
  import Bitwise, only: [&&&: 2]
  import QuickBEAM.VM.Builtin, only: [build_methods: 1, build_object: 1]
  import QuickBEAM.VM.Heap.Keys
  import QuickBEAM.VM.Value, only: [is_object: 1, is_closure: 1]

  alias QuickBEAM.VM.Execution.Trace

  alias QuickBEAM.VM.{
    Builtin,
    Bytecode,
    Decoder,
    GlobalEnv,
    Heap,
    Invocation,
    Names,
    PredefinedAtoms,
    Runtime,
    Stacktrace
  }

  alias QuickBEAM.JSError
  alias QuickBEAM.VM.Invocation.Context, as: InvokeContext
  alias QuickBEAM.VM.JSThrow
  alias QuickBEAM.VM.ObjectModel.{Class, Copy, Delete, Functions, Get, Methods, Private, Put}
  alias QuickBEAM.VM.PromiseState, as: Promise

  alias __MODULE__.{
    ClosureBuilder,
    Closures,
    Context,
    EvalEnv,
    Frame,
    Gas,
    Generator,
    Setup,
    Values
  }

  require Frame

  @moduledoc """
  Executes decoded QuickJS bytecode via multi-clause function dispatch.

  The interpreter pre-decodes bytecode into instruction tuples for O(1) indexed
  access, then runs a tail-recursive dispatch loop with one `defp run/5` clause
  per opcode family.

  ## JS value representation

    - number:    Elixir integer or float
    - string:    Elixir binary
    - boolean:   `true` / `false`
    - null:      `nil`
    - undefined: `:undefined`
    - object:    `{:obj, reference()}`
    - function:  `%Bytecode.Function{}` | `{:closure, map(), %Bytecode.Function{}}`
    - symbol:    `{:symbol, desc}` | `{:symbol, desc, ref}`
    - bigint:    `{:bigint, integer()}`
  """

  @compile {:inline,
            put_local: 3,
            list_iterator_next: 1,
            make_list_iterator: 1,
            check_prototype_chain: 2}

  for {num, {name, _, _, _, _}} <- QuickBEAM.VM.Opcodes.table() do
    Module.put_attribute(__MODULE__, :"op_#{name}", num)
  end

  @func_generator 1
  @func_async 2
  @func_async_generator 3
  @gc_check_interval 1000

  defp check_gas(_pc, frame, stack, gas, ctx),
    do: Gas.check(frame, stack, gas, ctx, @gc_check_interval)

  @spec eval(Bytecode.Function.t()) :: {:ok, term()} | {:error, term()}
  def eval(%Bytecode.Function{} = fun), do: eval(fun, [], %{})

  @spec eval(Bytecode.Function.t(), [term()], map()) :: {:ok, term()} | {:error, term()}
  def eval(%Bytecode.Function{} = fun, args, opts), do: eval(fun, args, opts, {})

  @spec eval(Bytecode.Function.t(), [term()], map(), tuple()) :: {:ok, term()} | {:error, term()}
  def eval(%Bytecode.Function{} = fun, args, opts, atoms) do
    case eval_with_ctx(fun, args, opts, atoms) do
      {:ok, value, _ctx} -> {:ok, value}
      {:error, _} = err -> err
    end
  end

  defp eval_with_ctx(%Bytecode.Function{} = fun, args, opts, atoms) do
    gas = Map.get(opts, :gas, Context.default_gas())

    ctx = Setup.build_eval_context(opts, atoms, gas)

    Heap.put_atoms(atoms)
    Setup.store_function_atoms(fun, atoms)
    prev_ctx = Heap.get_ctx()
    Heap.put_ctx(ctx)

    if Heap.get_builtin_names() == nil do
      Heap.put_builtin_names(MapSet.new(Map.keys(Runtime.global_bindings())))
    end

    ctx = Context.mark_synced(ctx)

    try do
      case Decoder.decode(fun.byte_code, fun.arg_count) do
        {:ok, instructions} ->
          instructions = List.to_tuple(instructions)
          locals = :erlang.make_tuple(max(fun.arg_count + fun.var_count, 1), :undefined)

          {locals, var_refs_tuple, l2v} =
            Closures.setup_captured_locals(fun, locals, [], args)

          frame =
            Frame.new(
              locals,
              List.to_tuple(fun.constants),
              var_refs_tuple,
              fun.stack_size,
              instructions,
              l2v
            )

          if ctx.trace_enabled, do: Trace.push(fun)

          try do
            result = run(0, frame, args, gas, ctx)
            Promise.drain_microtasks()
            {:ok, unwrap_promise(result), Heap.get_ctx()}
          catch
            {:js_throw, val} -> {:error, {:js_throw, val}}
            {:error, _} = err -> err
          after
            if ctx.trace_enabled, do: Trace.pop()
          end

        {:error, _} = err ->
          err
      end
    after
      if prev_ctx, do: Heap.put_ctx(prev_ctx), else: Heap.put_ctx(nil)
    end
  end

  @doc "Invoke a bytecode function or closure from external code."
  def invoke(fun, args, gas), do: Invocation.invoke(fun, args, gas)

  @doc """
  Invokes a JS function with a specific `this` receiver.
  """
  def invoke_with_receiver(fun, args, gas, this_obj),
    do: Invocation.invoke_with_receiver(fun, args, gas, this_obj)

  def invoke_constructor(fun, args, gas, this_obj, new_target),
    do: Invocation.invoke_constructor(fun, args, gas, this_obj, new_target)

  defp catch_and_dispatch(pc, frame, rest, gas, ctx, fun, refresh_globals?) do
    Heap.put_ctx(ctx)

    call_result =
      try do
        {:ok, fun.()}
      catch
        {:js_throw, val} -> {:throw, val}
      end

    if refresh_globals? do
      persistent = Heap.get_persistent_globals() || %{}
      refreshed_ctx = Context.mark_dirty(%{ctx | globals: Map.merge(ctx.globals, persistent)})

      case call_result do
        {:ok, result} -> run(pc + 1, frame, [result | rest], gas, refreshed_ctx)
        {:throw, val} -> throw_or_catch(frame, val, gas, refreshed_ctx)
      end
    else
      case call_result do
        {:ok, result} -> run(pc + 1, frame, [result | rest], gas, ctx)
        {:throw, val} -> throw_or_catch(frame, val, gas, ctx)
      end
    end
  end

  # ── Helpers ──

  defp clean_eval_globals(pre_eval_globals) do
    post = Heap.get_persistent_globals() || %{}

    cleaned =
      Enum.reduce(post, post, fn {key, _val}, acc ->
        case Map.fetch(pre_eval_globals, key) do
          {:ok, old_val} -> Map.put(acc, key, old_val)
          :error -> Map.delete(acc, key)
        end
      end)

    Heap.put_persistent_globals(cleaned)
  end

  defp uninitialized_this_local?(ctx, idx), do: EvalEnv.current_local_name(ctx, idx) == "this"

  defp derived_this_uninitialized?(%Context{
         this: this,
         current_func: {:closure, _, %Bytecode.Function{is_derived_class_constructor: true}}
       })
       when this == :uninitialized or
              (is_tuple(this) and tuple_size(this) == 2 and elem(this, 0) == :uninitialized),
       do: true

  defp derived_this_uninitialized?(%Context{
         this: this,
         current_func: %Bytecode.Function{is_derived_class_constructor: true}
       })
       when this == :uninitialized or
              (is_tuple(this) and tuple_size(this) == 2 and elem(this, 0) == :uninitialized),
       do: true

  defp derived_this_uninitialized?(_), do: false

  defp current_var_ref_name(
         %Context{current_func: {:closure, _, %Bytecode.Function{closure_vars: vars}}},
         idx
       )
       when idx >= 0 and idx < length(vars),
       do: vars |> Enum.at(idx) |> Map.get(:name) |> Names.resolve_display_name()

  defp current_var_ref_name(%Context{current_func: %Bytecode.Function{closure_vars: vars}}, idx)
       when idx >= 0 and idx < length(vars),
       do: vars |> Enum.at(idx) |> Map.get(:name) |> Names.resolve_display_name()

  defp current_var_ref_name(_, _), do: nil

  defp put_local(f, idx, val),
    do: put_elem(f, Frame.locals(), put_elem(elem(f, Frame.locals()), idx, val))

  defp trim_catch_stack(ctx, saved_stack) when is_list(saved_stack) do
    if ctx.catch_stack === saved_stack do
      ctx
    else
      Context.mark_dirty(%{ctx | catch_stack: saved_stack})
    end
  end

  defp throw_or_catch(frame, error, gas, ctx) do
    error = maybe_refresh_error_stack(error)

    case ctx.catch_stack do
      [{target, saved_stack} | rest_catch] ->
        run(
          target,
          frame,
          [error | saved_stack],
          gas,
          Context.mark_dirty(%{ctx | catch_stack: rest_catch})
        )

      [] ->
        throw({:js_throw, error})
    end
  end

  defp sync_global_this_write(ctx, obj, name, val) when is_binary(name) do
    case Map.get(ctx.globals, "globalThis") do
      ^obj ->
        new_globals = Map.put(ctx.globals, name, val)
        Heap.put_persistent_globals(new_globals)
        Context.mark_dirty(%{ctx | globals: new_globals})

      _ ->
        ctx
    end
  end

  defp sync_global_this_write(ctx, _obj, _name, _val), do: ctx

  defp refresh_persistent_globals(ctx) do
    case Heap.get_persistent_globals() do
      nil -> ctx
      p when map_size(p) == 0 -> ctx
      p -> Context.mark_dirty(%{ctx | globals: Map.merge(ctx.globals, p)})
    end
  end

  defp current_strict_mode?(%{current_func: {:closure, _, %Bytecode.Function{is_strict_mode: s}}}),
    do: s

  defp current_strict_mode?(%{current_func: %Bytecode.Function{is_strict_mode: s}}), do: s
  defp current_strict_mode?(_), do: false

  defp maybe_refresh_error_stack({:obj, ref} = error) do
    case Heap.get_obj(ref, %{}) do
      %{"name" => _, "message" => _} -> Stacktrace.attach_stack(error)
      _ -> error
    end
  end

  defp maybe_refresh_error_stack(error), do: error

  defp get_arg_value(%Context{arg_buf: arg_buf}, idx) do
    if idx < tuple_size(arg_buf), do: elem(arg_buf, idx), else: :undefined
  end

  defp throw_null_property_error(frame, obj, atom_idx, gas, ctx) do
    prop = Names.resolve_atom(ctx, atom_idx)
    nullish = if obj == nil, do: "null", else: "undefined"

    error =
      Heap.make_error("Cannot read properties of #{nullish} (reading '#{prop}')", "TypeError")

    throw_or_catch(frame, error, gas, ctx)
  end

  defp unwrap_promise(val, depth \\ 0)

  defp unwrap_promise({:obj, ref}, depth) when depth < 10 do
    case Heap.get_obj(ref, %{}) do
      %{
        promise_state() => :resolved,
        promise_value() => val
      } ->
        unwrap_promise(val, depth + 1)

      _ ->
        {:obj, ref}
    end
  end

  defp unwrap_promise(val, _depth), do: val

  def resolve_awaited({:obj, ref} = obj) do
    Promise.drain_microtasks()

    case Heap.get_obj(ref, %{}) do
      %{
        promise_state() => :resolved,
        promise_value() => val
      } ->
        val

      %{
        promise_state() => :rejected,
        promise_value() => val
      } ->
        throw({:js_throw, val})

      %{promise_state() => :pending} ->
        # Drain again in case resolution was queued
        Promise.drain_microtasks()

        case Heap.get_obj(ref, %{}) do
          %{
            promise_state() => :resolved,
            promise_value() => val
          } ->
            val

          %{
            promise_state() => :rejected,
            promise_value() => val
          } ->
            throw({:js_throw, val})

          _ ->
            obj
        end

      _ ->
        obj
    end
  end

  def resolve_awaited(val), do: val

  defp list_iterator_next(pos_ref) do
    case Heap.get_obj_raw(pos_ref) do
      [head | tail] ->
        Heap.put_obj_raw(pos_ref, tail)
        Heap.wrap(%{"value" => head, "done" => false})

      _ ->
        Heap.wrap(%{"value" => :undefined, "done" => true})
    end
  end

  defp array_proto_iterator(_obj) do
    sym_iter = {:symbol, "Symbol.iterator"}

    case Heap.get_array_proto() do
      {:obj, proto_ref} ->
        proto_data = Heap.get_obj(proto_ref, %{})

        case is_map(proto_data) && Map.get(proto_data, sym_iter) do
          nil -> :deleted
          false -> :deleted
          :deleted -> :deleted
          {:builtin, "[Symbol.iterator]", _} -> :default
          other -> other
        end

      _ ->
        :default
    end
  end

  defp invoke_custom_iterator(iter_fn, obj) do
    iter_obj = Invocation.invoke_with_receiver(iter_fn, [], Runtime.gas_budget(), obj)

    unless is_object(iter_obj) do
      throw(
        {:js_throw,
         Heap.make_error("Result of the Symbol.iterator method is not an object", "TypeError")}
      )
    end

    {iter_obj, Get.get(iter_obj, "next")}
  end

  defp make_list_iterator(items) do
    pos_ref = make_ref()
    Heap.put_obj_raw(pos_ref, items)
    next_fn = {:builtin, "next", fn _, _ -> list_iterator_next(pos_ref) end}
    {build_object(do: val("next", next_fn)), next_fn}
  end

  defp eval_code(code, caller_frame, gas, ctx, var_objs, keep_declared?) do
    with {:ok, bc} <- QuickBEAM.Runtime.compile(ctx.runtime_pid, code),
         {:ok, parsed} <- Bytecode.decode(bc) do
      declared_names = eval_declared_names(parsed.value, parsed.atoms)
      eval_globals = collect_caller_locals(caller_frame, ctx)
      captured_globals = collect_captured_globals(ctx.current_func)

      eval_scope_globals =
        merge_var_object_globals(Map.merge(eval_globals, captured_globals), var_objs)

      base_globals =
        if keep_declared?,
          do: Map.drop(ctx.globals, MapSet.to_list(declared_names)),
          else: ctx.globals

      scoped_globals =
        if keep_declared?,
          do: Map.drop(eval_scope_globals, MapSet.to_list(declared_names)),
          else: eval_scope_globals

      eval_ctx_globals =
        base_globals
        |> Map.merge(scoped_globals)
        |> Map.put("arguments", Heap.wrap(Tuple.to_list(ctx.arg_buf)))

      visible_declared_names =
        base_globals
        |> Map.merge(eval_scope_globals)
        |> Map.put("arguments", :present)
        |> Map.keys()
        |> Enum.filter(&is_binary/1)
        |> MapSet.new()
        |> MapSet.intersection(declared_names)

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

      case eval_with_ctx(parsed.value, [], eval_opts, parsed.atoms) do
        {:ok, val, final_ctx} ->
          post_eval_globals = Heap.get_persistent_globals() || %{}

          transient_globals =
            post_eval_globals
            |> Map.merge(Map.get(final_ctx || %{}, :globals, %{}))
            |> Map.take(MapSet.to_list(visible_declared_names))

          apply_eval_transients(ctx.current_func, var_objs, transient_globals, keep_declared?)
          write_back_eval_vars(caller_frame, ctx, pre_eval_globals, var_objs, declared_names)

          clean_eval_globals(pre_eval_globals)
          {val, transient_globals}

        {:error, {:js_throw, val}} ->
          write_back_eval_vars(caller_frame, ctx, pre_eval_globals, var_objs, declared_names)

          clean_eval_globals(pre_eval_globals)
          throw({:js_throw, val})

        _ ->
          {:undefined, %{}}
      end
    else
      {:error, msg} when is_binary(msg) ->
        JSThrow.syntax_error!(msg)

      {:error, %JSError{name: name, message: msg}} ->
        throw({:js_throw, Heap.make_error(msg, name)})

      _ ->
        {:undefined, %{}}
    end
  end

  defp merge_var_object_globals(globals, []), do: globals

  defp merge_var_object_globals(globals, var_objs) do
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

  defp captured_var_objects({:closure, captured, _}) do
    captured
    |> Map.values()
    |> Enum.flat_map(fn
      {:cell, ref} ->
        case Heap.get_cell(ref) do
          {:obj, _} = obj -> [obj]
          _ -> []
        end

      _ ->
        []
    end)
  end

  defp captured_var_objects(_), do: []

  defp collect_captured_globals({:closure, captured, %Bytecode.Function{closure_vars: cvs}}) do
    Enum.reduce(cvs, %{}, fn cv, acc ->
      case Names.resolve_display_name(cv.name) do
        name when is_binary(name) ->
          val =
            case Map.get(captured, ClosureBuilder.capture_key(cv), :undefined) do
              {:cell, ref} -> Heap.get_cell(ref)
              other -> other
            end

          Map.put(acc, name, val)

        _ ->
          acc
      end
    end)
  end

  defp collect_captured_globals(_), do: %{}

  defp write_back_eval_vars(caller_frame, ctx, original_globals, var_objs, declared_names) do
    new_globals = Heap.get_persistent_globals() || %{}

    if current_strict_mode?(ctx) do
      func_name = EvalEnv.current_func_name(ctx)

      if func_name && Map.has_key?(new_globals, func_name) do
        old_val =
          case ctx.current_func do
            {:closure, _, %Bytecode.Function{} = f} -> Heap.get_parent_ctor(f)
            _ -> nil
          end

        new_val = Map.get(new_globals, func_name)

        if old_val == nil and new_val != ctx.current_func and new_val != :undefined do
          JSThrow.type_error!("Assignment to constant variable.")
        end
      end
    end

    vrefs = elem(caller_frame, Frame.var_refs())
    l2v = elem(caller_frame, Frame.l2v())

    case ctx.current_func do
      {:closure, _, %Bytecode.Function{locals: local_defs}} ->
        do_write_back(local_defs, vrefs, l2v, new_globals, ctx, original_globals, declared_names)

      %Bytecode.Function{locals: local_defs} ->
        do_write_back(local_defs, vrefs, l2v, new_globals, ctx, original_globals, declared_names)

      _ ->
        :ok
    end

    if is_closure(ctx.current_func) do
      write_back_captured_vars(ctx.current_func, new_globals, original_globals, declared_names)
    end

    if var_objs != [] do
      for {name, val} <- new_globals,
          is_binary(name),
          Map.has_key?(original_globals, name),
          Map.get(original_globals, name) != val do
        for var_obj <- var_objs, do: Put.put(var_obj, name, val)
      end
    end
  end

  defp apply_eval_transients(current_func, var_objs, transient_globals, keep_declared?) do
    if transient_globals != %{} do
      if var_objs != [] do
        for {name, val} <- transient_globals, var_obj <- var_objs do
          Put.put(var_obj, name, val)
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

  defp write_back_captured_vars(
         {:closure, captured, %Bytecode.Function{closure_vars: cvs}},
         new_globals,
         original_globals,
         declared_names
       ) do
    for cv <- cvs,
        name = Names.resolve_display_name(cv.name),
        is_binary(name),
        not MapSet.member?(declared_names, name),
        Map.has_key?(new_globals, name),
        Map.get(original_globals, name) != Map.get(new_globals, name) do
      case Map.get(captured, ClosureBuilder.capture_key(cv)) do
        {:cell, ref} -> Heap.put_cell(ref, Map.get(new_globals, name))
        _ -> :ok
      end
    end
  end

  defp write_back_captured_vars(_, _, _, _), do: :ok

  defp apply_transient_captured_vars(
         {:closure, captured, %Bytecode.Function{closure_vars: cvs}},
         new_globals,
         declared_names
       ) do
    for cv <- cvs,
        name = Names.resolve_display_name(cv.name),
        is_binary(name),
        MapSet.member?(declared_names, name),
        Map.has_key?(new_globals, name) do
      case Map.get(captured, ClosureBuilder.capture_key(cv)) do
        {:cell, ref} ->
          old_val = Heap.get_cell(ref)
          restore_stack = Process.get(:qb_eval_restore_stack, [])
          Process.put(:qb_eval_restore_stack, [{ref, old_val} | restore_stack])
          Heap.put_cell(ref, Map.get(new_globals, name))

        _ ->
          :ok
      end
    end
  end

  defp apply_transient_captured_vars(_, _, _), do: :ok

  defp restore_eval_restores(mark) do
    restores = Process.get(:qb_eval_restore_stack, [])
    {to_restore, keep} = Enum.split(restores, length(restores) - mark)

    Enum.each(to_restore, fn {ref, old_val} ->
      Heap.put_cell(ref, old_val)
    end)

    Process.put(:qb_eval_restore_stack, keep)
  end

  defp eval_declared_names(%Bytecode.Function{} = fun, atoms) do
    local_names =
      fun.locals
      |> Enum.map(&Names.resolve_display_name(&1.name))
      |> Enum.filter(&is_binary/1)

    instruction_names =
      case Decoder.decode(fun.byte_code, fun.arg_count) do
        {:ok, insns} ->
          insns
          |> Enum.reduce([], fn
            {op, [atom_ref, _scope]}, acc when op in [@op_define_var, @op_check_define_var] ->
              case resolve_declared_atom(atom_ref, atoms) do
                name when is_binary(name) -> [name | acc]
                _ -> acc
              end

            {op, [atom_ref, _flags]}, acc when op == @op_define_func ->
              case resolve_declared_atom(atom_ref, atoms) do
                name when is_binary(name) -> [name | acc]
                _ -> acc
              end

            _, acc ->
              acc
          end)

        _ ->
          []
      end

    MapSet.new(local_names ++ instruction_names)
  end

  defp eval_declared_names(_, _), do: MapSet.new()

  defp resolve_declared_atom({:predefined, idx}, _atoms),
    do: PredefinedAtoms.lookup(idx)

  defp resolve_declared_atom(idx, atoms)
       when is_integer(idx) and idx >= 0 and idx < tuple_size(atoms), do: elem(atoms, idx)

  defp resolve_declared_atom(name, _atoms) when is_binary(name), do: name
  defp resolve_declared_atom(_, _atoms), do: nil

  defp do_write_back(local_defs, vrefs, l2v, new_globals, ctx, original_globals, declared_names) do
    func_name = EvalEnv.current_func_name(ctx)

    for {vd, idx} <- Enum.with_index(local_defs),
        name = Names.resolve_display_name(vd.name),
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
            {:cell, ref} -> Closures.write_cell({:cell, ref}, new_val)
            _ -> :ok
          end

        _ ->
          :ok
      end
    end
  end

  defp collect_caller_locals(frame, ctx) do
    locals = elem(frame, Frame.locals())

    case ctx.current_func do
      {:closure, _, %Bytecode.Function{locals: local_defs, arg_count: ac}} ->
        build_local_map(local_defs, ac, locals, ctx)

      %Bytecode.Function{locals: local_defs, arg_count: ac} ->
        build_local_map(local_defs, ac, locals, ctx)

      _ ->
        %{}
    end
  end

  defp build_local_map(local_defs, arg_count, locals, ctx) do
    arg_buf = ctx.arg_buf

    local_defs
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {vd, idx}, acc ->
      with name when is_binary(name) <- vd.name,
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

  defp collect_iterator(iter_obj, acc) do
    next_fn = Get.get(iter_obj, "next")

    case Runtime.call_callback(next_fn, []) do
      {:obj, _} = result_obj ->
        done = Get.get(result_obj, "done")

        if done == true do
          Enum.reverse(acc)
        else
          val = Get.get(result_obj, "value")
          collect_iterator(iter_obj, [val | acc])
        end

      _ ->
        Enum.reverse(acc)
    end
  end

  defp materialize_constant({:template_object, elems, raw}) when is_list(elems) do
    raw_list =
      case raw do
        {:array, l} when is_list(l) -> l
        l when is_list(l) -> l
        :undefined -> elems
        _ -> elems
      end

    raw_ref = make_ref()

    raw_map =
      raw_list
      |> Enum.with_index()
      |> Enum.reduce(%{"length" => length(raw_list)}, fn {v, i}, acc ->
        Map.put(acc, Integer.to_string(i), v)
      end)

    Heap.put_obj(raw_ref, raw_map)

    ref = make_ref()

    map =
      elems
      |> Enum.with_index()
      |> Enum.reduce(%{"length" => length(elems), "raw" => {:obj, raw_ref}}, fn {v, i}, acc ->
        Map.put(acc, Integer.to_string(i), v)
      end)

    Heap.put_obj(ref, map)
    {:obj, ref}
  end

  defp materialize_constant({:template_object, {:array, elems}, raw}) do
    materialize_constant({:template_object, elems, raw})
  end

  defp materialize_constant({:template_object, elems, raw}) when not is_list(elems) do
    materialize_constant({:template_object, [elems], raw})
  end

  defp materialize_constant(val), do: val

  defp function_value?({:closure, _, _}), do: true
  defp function_value?(%Bytecode.Function{}), do: true
  defp function_value?({:builtin, _, _}), do: true
  defp function_value?({:bound, _, _, _, _}), do: true
  defp function_value?(_), do: false

  @dialyzer {:nowarn_function, check_prototype_chain: 2}
  defp check_prototype_chain(_, :undefined), do: false
  defp check_prototype_chain(_, nil), do: false

  defp check_prototype_chain({:obj, ref}, target) do
    case Heap.get_obj(ref, %{}) do
      map when is_map(map) ->
        case Map.get(map, proto()) do
          ^target -> true
          nil -> false
          :undefined -> false
          proto -> check_prototype_chain(proto, target)
        end

      data when is_list(data) ->
        array_proto_matches?(target)

      {:qb_arr, _} ->
        array_proto_matches?(target)

      _ ->
        false
    end
  end

  defp check_prototype_chain(_, _), do: false

  defp array_proto_matches?(target) do
    case Heap.get_ctx() do
      %{globals: globals} ->
        array_ctor = Map.get(globals, "Array")

        if array_ctor do
          array_proto = Get.get(array_ctor, "prototype")

          if array_proto == target do
            true
          else
            object_ctor = Map.get(globals, "Object")

            if object_ctor do
              Get.get(object_ctor, "prototype") == target
            else
              false
            end
          end
        else
          false
        end

      _ ->
        false
    end
  end

  defp with_has_property?({:obj, _} = obj, key) do
    if Put.has_property(obj, key) do
      unscopables = Get.get(obj, {:symbol, "Symbol.unscopables"})

      case unscopables do
        {:obj, _} -> not Values.truthy?(Get.get(unscopables, key))
        _ -> true
      end
    else
      false
    end
  end

  defp with_has_property?(_, _), do: false

  defp delete_static(fun, key) do
    key_str = if is_binary(key), do: key, else: Values.stringify(key)
    statics = Heap.get_ctor_statics(fun)

    if Map.has_key?(statics, key_str) do
      Heap.put_ctor_statics(fun, Map.delete(statics, key_str))
      true
    else
      case fun do
        {:builtin, _, _} ->
          val = Get.get(fun, key_str)

          cond do
            val == :undefined ->
              true

            is_number(val) or val == :infinity or val == :neg_infinity or val == :nan ->
              false

            true ->
              Heap.put_ctor_statics(fun, Map.put(statics, key_str, :deleted))
              true
          end

        _ ->
          true
      end
    end
  end

  defp ensure_initialized_local!(ctx, idx, val) do
    if val == :__tdz__ or
         (val == :undefined and uninitialized_this_local?(ctx, idx) and
            derived_this_uninitialized?(ctx)) do
      message =
        if uninitialized_this_local?(ctx, idx) and derived_this_uninitialized?(ctx),
          do: "this is not initialized",
          else: "Cannot access variable before initialization"

      JSThrow.reference_error!(message)
    end
  end

  defp eval_scope_var_objects(frame, ctx, enabled?, scope_idx) do
    if enabled? do
      locals = elem(frame, Frame.locals())

      obj_locals =
        for i <- 0..(tuple_size(locals) - 1),
            obj = elem(locals, i),
            is_object(obj),
            do: obj

      obj_locals = if scope_idx == 0, do: Enum.take(obj_locals, 1), else: obj_locals
      Enum.uniq(obj_locals ++ captured_var_objects(ctx.current_func))
    else
      []
    end
  end

  defp run_eval_or_call(pc, frame, rest, gas, ctx, fun, args, scope_idx, var_objs) do
    case eval_or_call(
           fun,
           List.first(args, :undefined),
           args,
           scope_idx,
           frame,
           gas,
           ctx,
           var_objs
         ) do
      {:ok, {result, new_ctx}} -> run(pc + 1, frame, [result | rest], gas, new_ctx)
      {:error, error} -> throw_or_catch(frame, error, gas, ctx)
    end
  end

  defp eval_or_call(fun, code, args, scope_idx, frame, gas, ctx, var_objs) do
    try do
      {:ok, eval_or_call_result(fun, code, args, scope_idx, frame, gas, ctx, var_objs)}
    catch
      {:js_throw, error} -> {:error, error}
    end
  end

  defp eval_or_call_result(fun, code, args, scope_idx, frame, gas, ctx, var_objs) do
    cond do
      fun == ctx.globals["eval"] and is_binary(code) and ctx.runtime_pid != nil ->
        keep_declared? = scope_idx > 0
        {value, transient_globals} = eval_code(code, frame, gas, ctx, var_objs, keep_declared?)
        {value, Context.mark_dirty(%{ctx | globals: Map.merge(ctx.globals, transient_globals)})}

      callable?(fun) ->
        persistent = Heap.get_persistent_globals() || %{}

        {dispatch_call(fun, args, gas, ctx, :undefined),
         Context.mark_dirty(%{ctx | globals: Map.merge(ctx.globals, persistent)})}

      true ->
        {:undefined, ctx}
    end
  end

  defp callable?(fun) do
    is_function(fun) or match?({:fn, _, _}, fun) or match?({:bound, _, _}, fun) or
      match?(%Bytecode.Function{}, fun) or match?({:closure, _, %Bytecode.Function{}}, fun)
  end

  defp run_arg_update(pc, frame, stack, gas, %Context{arg_buf: arg_buf} = ctx, idx, val) do
    locals = elem(frame, Frame.locals())

    frame =
      if idx < tuple_size(locals) do
        Closures.write_captured_local(
          elem(frame, Frame.l2v()),
          idx,
          val,
          locals,
          elem(frame, Frame.var_refs())
        )

        put_local(frame, idx, val)
      else
        frame
      end

    ctx = put_arg_value(ctx, idx, val, arg_buf)
    run(pc + 1, frame, stack, gas, ctx)
  end

  # ── Main dispatch loop ──

  defp run(pc, frame, stack, gas, %Context{pd_synced: true} = ctx) do
    if ctx.trace_enabled, do: Trace.update_pc(pc)
    run(elem(elem(frame, Frame.insns()), pc), pc, frame, stack, gas, ctx)
  end

  defp run(pc, frame, stack, gas, %Context{pd_synced: false} = ctx) do
    Heap.put_ctx(ctx)
    ctx = Context.mark_synced(ctx)

    if ctx.trace_enabled, do: Trace.update_pc(pc)
    run(elem(elem(frame, Frame.insns()), pc), pc, frame, stack, gas, ctx)
  end

  defp run(pc, frame, stack, gas, ctx) do
    Heap.put_ctx(ctx)
    if Map.get(ctx, :trace_enabled, false), do: Trace.update_pc(pc)
    run(elem(elem(frame, Frame.insns()), pc), pc, frame, stack, gas, ctx)
  end

  use QuickBEAM.VM.Interpreter.Ops.Stack

  use QuickBEAM.VM.Interpreter.Ops.Locals

  use QuickBEAM.VM.Interpreter.Ops.Control

  use QuickBEAM.VM.Interpreter.Ops.Arithmetic

  use QuickBEAM.VM.Interpreter.Ops.Calls

  use QuickBEAM.VM.Interpreter.Ops.Objects

  use QuickBEAM.VM.Interpreter.Ops.Globals

  use QuickBEAM.VM.Interpreter.Ops.Iterators

  use QuickBEAM.VM.Interpreter.Ops.Generators

  use QuickBEAM.VM.Interpreter.Ops.Classes

  # ── Catch-all for unimplemented opcodes ──

  defp run({op, args}, _pc, _frame, _stack, _gas, _ctx) do
    throw({:error, {:unimplemented_opcode, op, args}})
  end

  defp for_of_start_iter(obj) do
    case obj do
      list when is_list(list) ->
        make_list_iterator(list)

      {:obj, ref} ->
        stored = Heap.get_obj(ref)

        case stored do
          {:qb_arr, arr} ->
            case array_proto_iterator(obj) do
              :default ->
                make_list_iterator(:array.to_list(arr))

              :deleted ->
                throw(
                  {:js_throw,
                   Heap.make_error("[Symbol.iterator] is not a function", "TypeError")}
                )

              custom_fn ->
                invoke_custom_iterator(custom_fn, obj)
            end

          list when is_list(list) ->
            case array_proto_iterator(obj) do
              :default ->
                make_list_iterator(list)

              :deleted ->
                throw(
                  {:js_throw,
                   Heap.make_error("[Symbol.iterator] is not a function", "TypeError")}
                )

              custom_fn ->
                invoke_custom_iterator(custom_fn, obj)
            end

          map when is_map(map) ->
            sym_iter = {:symbol, "Symbol.iterator"}

            cond do
              Map.has_key?(map, sym_iter) ->
                raw_iter = Map.get(map, sym_iter)

                iter_fn =
                  case raw_iter do
                    {:accessor, getter, _} when getter != nil -> Get.call_getter(getter, obj)
                    _ -> raw_iter
                  end

                iter_obj =
                  Invocation.invoke_with_receiver(iter_fn, [], Runtime.gas_budget(), obj)

                unless is_object(iter_obj) do
                  throw(
                    {:js_throw,
                     Heap.make_error(
                       "Result of the Symbol.iterator method is not an object",
                       "TypeError"
                     )}
                  )
                end

                {iter_obj, Get.get(iter_obj, "next")}

              Map.has_key?(map, "next") ->
                {obj, Get.get(obj, "next")}

              true ->
                make_list_iterator([])
            end

          _ ->
            make_list_iterator([])
        end

      s when is_binary(s) ->
        make_list_iterator(String.codepoints(s))

      nil ->
        throw(
          {:js_throw,
           Heap.make_error(
             "Cannot read properties of null (reading 'Symbol(Symbol.iterator)')",
             "TypeError"
           )}
        )

      :undefined ->
        throw(
          {:js_throw,
           Heap.make_error(
             "Cannot read properties of undefined (reading 'Symbol(Symbol.iterator)')",
             "TypeError"
           )}
        )

      other ->
        throw(
          {:js_throw,
           Heap.make_error("#{Values.stringify(other)} is not iterable", "TypeError")}
        )
    end
  end

  defp apply_args(arg_array) do
    case arg_array do
      {:qb_arr, arr} -> :array.to_list(arr)
      list when is_list(list) -> list
      {:obj, ref} -> Heap.to_list({:obj, ref})
      _ -> []
    end
  end

  defp invoke_super_constructor(fun, new_target, args, gas, ctx) do
    pending_this = pending_constructor_this(ctx.this)

    ctor_ctx =
      Context.mark_dirty(%{
        ctx
        | this: super_constructor_this(fun, pending_this),
          new_target: new_target
      })

    result =
      case fun do
        %Bytecode.Function{} = f ->
          do_invoke(f, {:closure, %{}, f}, args, ClosureBuilder.ctor_var_refs(f), gas, ctor_ctx)

        {:closure, captured, %Bytecode.Function{} = f} ->
          do_invoke(
            f,
            {:closure, captured, f},
            args,
            ClosureBuilder.ctor_var_refs(f, captured),
            gas,
            ctor_ctx
          )

        {:bound, _, _, orig_fun, bound_args} ->
          invoke_super_constructor(orig_fun, new_target, bound_args ++ args, gas, ctx)

        {:builtin, _name, cb} when is_function(cb, 2) ->
          cb.(args, pending_this)

        _ ->
          pending_this
      end

    result = Class.coalesce_this_result(result, ctor_ctx.this)

    case result do
      {:uninitialized, _} ->
        JSThrow.reference_error!("this is not initialized")

      other ->
        other
    end
  end

  defp pending_constructor_this({:uninitialized, {:obj, _} = obj}), do: obj
  defp pending_constructor_this({:obj, _} = obj), do: obj
  defp pending_constructor_this(other), do: other

  defp super_constructor_this(fun, pending_this) do
    case unwrap_constructor_target(fun) do
      %Bytecode.Function{is_derived_class_constructor: true} -> {:uninitialized, pending_this}
      _ -> pending_this
    end
  end

  defp unwrap_constructor_target({:closure, _, %Bytecode.Function{} = f}), do: f
  defp unwrap_constructor_target({:bound, _, inner, _, _}), do: unwrap_constructor_target(inner)
  defp unwrap_constructor_target(other), do: other

  defp put_arg_value(ctx, idx, val, arg_buf) do
    padded = Tuple.to_list(arg_buf)

    padded =
      if idx < length(padded),
        do: padded,
        else: padded ++ List.duplicate(:undefined, idx + 1 - length(padded))

    Context.mark_dirty(%{ctx | arg_buf: List.to_tuple(List.replace_at(padded, idx, val))})
  end

  defp dispatch_call(fun, args, gas, ctx, this),
    do: Invocation.dispatch(fun, args, gas, ctx, this)

  # ── Tail calls ──

  defp tail_call(stack, argc, gas, ctx) do
    {args, [fun | _]} = Enum.split(stack, argc)
    dispatch_call(fun, Enum.reverse(args), gas, ctx, nil)
  end

  defp tail_call_method(stack, argc, gas, ctx) do
    {args, [fun, obj | _]} = Enum.split(stack, argc)
    dispatch_call(fun, Enum.reverse(args), gas, Context.mark_dirty(%{ctx | this: obj}), obj)
  end

  # ── Closure construction ──

  defp build_closure(fun, locals, vrefs, l2v, ctx),
    do: ClosureBuilder.build(fun, locals, vrefs, l2v, ctx)

  defp inherit_parent_vrefs(closure, parent_vrefs),
    do: ClosureBuilder.inherit_parent_vrefs(closure, parent_vrefs)

  # ── Function calls ──

  defp call_function(pc, frame, stack, argc, gas, ctx) do
    {args, [fun | rest]} = Enum.split(stack, argc)
    gas = check_gas(pc, frame, rest, gas, ctx)

    catch_and_dispatch(pc, frame, rest, gas, ctx, fn ->
      dispatch_call(fun, Enum.reverse(args), gas, ctx, nil)
    end, true)
  end

  defp call_method(pc, frame, stack, argc, gas, ctx) do
    {args, [fun, obj | rest]} = Enum.split(stack, argc)
    gas = check_gas(pc, frame, rest, gas, ctx)
    method_ctx = Context.mark_dirty(%{ctx | this: obj})

    catch_and_dispatch(pc, frame, rest, gas, ctx, fn ->
      dispatch_call(fun, Enum.reverse(args), gas, method_ctx, obj)
    end, true)
  end

  def invoke_function_fallback(%Bytecode.Function{} = fun, args, gas, ctx) do
    invoke_function(fun, args, gas, ctx)
  end

  def invoke_function_fallback(other, args, _gas, _ctx)
      when not is_tuple(other) or elem(other, 0) != :bound,
      do: Builtin.call(other, args, nil)

  def invoke_function_fallback({:bound, _, inner, _, _}, args, gas, _ctx),
    do: Invocation.invoke(inner, args, gas)

  def invoke_closure_fallback({:closure, _, %Bytecode.Function{}} = closure, args, gas, ctx) do
    invoke_closure(closure, args, gas, ctx)
  end

  def invoke_closure_fallback(other, args, gas, ctx),
    do: invoke_function_fallback(other, args, gas, ctx)

  defp invoke_function(%Bytecode.Function{} = fun, args, gas, ctx) do
    do_invoke(fun, {:closure, %{}, fun}, args, [], gas, ctx)
  end

  defp invoke_closure({:closure, captured, %Bytecode.Function{} = fun} = self, args, gas, ctx) do
    var_refs =
      for cv <- fun.closure_vars do
        Map.get(captured, ClosureBuilder.capture_key(cv), :undefined)
      end

    do_invoke(fun, self, args, var_refs, gas, ctx)
  end

  defp do_invoke(%Bytecode.Function{} = fun, self_ref, args, var_refs, gas, ctx) do
    Heap.put_ctx(ctx)
    cache_key = {fun.byte_code, fun.arg_count}

    insns =
      case Heap.get_decoded(cache_key) do
        nil ->
          case Decoder.decode(fun.byte_code, fun.arg_count) do
            {:ok, instructions} ->
              t = List.to_tuple(instructions)
              Heap.put_decoded(cache_key, t)
              t

            {:error, _} = err ->
              throw(err)
          end

        cached ->
          cached
      end

    case insns do
      insns when is_tuple(insns) ->
        locals = :erlang.make_tuple(max(fun.arg_count + fun.var_count, 1), :undefined)

        {locals, var_refs_tuple, l2v} =
          Closures.setup_captured_locals(fun, locals, var_refs, args)

        frame =
          Frame.new(
            locals,
            List.to_tuple(fun.constants),
            var_refs_tuple,
            fun.stack_size,
            insns,
            l2v
          )

        fn_atoms = Heap.get_fn_atoms(fun.byte_code, Heap.get_atoms())
        Heap.put_atoms(fn_atoms)

        inner_ctx =
          %{
            ctx
            | current_func: self_ref,
              arg_buf: List.to_tuple(args),
              catch_stack: [],
              atoms: fn_atoms
          }
          |> InvokeContext.attach_method_state()

        prev_ctx = Heap.get_ctx()
        Heap.put_ctx(inner_ctx)
        inner_ctx = Context.mark_synced(inner_ctx)

        if inner_ctx.trace_enabled, do: Trace.push(self_ref)
        restore_mark = length(Process.get(:qb_eval_restore_stack, []))

        try do
          case fun.func_kind do
            @func_generator -> Generator.invoke(frame, gas, inner_ctx)
            @func_async -> Generator.invoke_async(frame, gas, inner_ctx)
            @func_async_generator -> Generator.invoke_async_generator(frame, gas, inner_ctx)
            _ -> run(0, frame, [], gas, inner_ctx)
          end
        after
          restore_eval_restores(restore_mark)
          if inner_ctx.trace_enabled, do: Trace.pop()
          if prev_ctx, do: Heap.put_ctx(prev_ctx)
        end
    end
  end

  @doc """
  Runs a bytecode frame — entry point for external callers.
  """
  def run_frame(frame, stack, gas, ctx), do: run(0, frame, stack, gas, ctx)
  def run_frame(pc, frame, stack, gas, ctx), do: run(pc, frame, stack, gas, ctx)

  @doc """
  Invokes a callback function from built-in code (e.g. Array.prototype.map).
  """
  def invoke_callback(fun, args), do: Invocation.invoke_callback(fun, args)
end
