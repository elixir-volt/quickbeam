defmodule QuickBEAM.VM.Interpreter do
  import QuickBEAM.VM.Builtin, only: [object: 1]
  import QuickBEAM.VM.Heap.Keys
  import QuickBEAM.VM.Value, only: [is_object: 1]

  alias QuickBEAM.VM.Execution.{SetterState, Trace}

  alias QuickBEAM.VM.{
    Builtin,
    GlobalEnvironment,
    Heap,
    Invocation,
    Names,
    Runtime,
    RuntimeState,
    Stacktrace,
    Value
  }

  alias QuickBEAM.VM.Invocation.Context, as: InvokeContext
  alias QuickBEAM.VM.JSThrow

  alias QuickBEAM.VM.ObjectModel.{
    Class,
    Copy,
    Functions,
    Get,
    Methods,
    Private,
    Static
  }

  alias QuickBEAM.VM.Promise, as: Promise
  alias QuickBEAM.VM.Semantics.DirectEval

  alias __MODULE__.{
    ArgumentsObject,
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
    - function:  `%QuickBEAM.VM.Function{}` | `{:closure, map(), %QuickBEAM.VM.Function{}}`
    - symbol:    `{:symbol, desc}` | `{:symbol, desc, ref}`
    - bigint:    `{:bigint, integer()}`
  """

  @compile {:inline, put_local: 3, list_iterator_next: 1, make_list_iterator: 1}

  for {num, {name, _, _, _, _}} <- QuickBEAM.VM.Opcodes.table() do
    Module.put_attribute(__MODULE__, :"op_#{name}", num)
  end

  @func_generator 1
  @func_async 2
  @func_async_generator 3
  @gc_check_interval 1000

  defp check_gas(_pc, frame, stack, gas, ctx),
    do: Gas.check(frame, stack, gas, ctx, @gc_check_interval)

  @spec eval(QuickBEAM.VM.Function.t()) :: {:ok, term()} | {:error, term()}
  @doc "Evaluates bytecode in the interpreter."
  def eval(%QuickBEAM.VM.Function{} = fun), do: eval(fun, [], %{})

  @spec eval(QuickBEAM.VM.Function.t(), [term()], map()) :: {:ok, term()} | {:error, term()}
  def eval(%QuickBEAM.VM.Function{} = fun, args, opts), do: eval(fun, args, opts, {})

  @spec eval(QuickBEAM.VM.Function.t(), [term()], map(), tuple()) ::
          {:ok, term()} | {:error, term()}
  def eval(%QuickBEAM.VM.Function{} = fun, args, opts, atoms) do
    case eval_with_ctx(fun, args, opts, atoms) do
      {:ok, value, _ctx} -> {:ok, value}
      {:error, _} = err -> err
    end
  end

  defp eval_with_ctx(%QuickBEAM.VM.Function{} = fun, args, opts, atoms) do
    gas = Map.get(opts, :gas, Context.default_gas())

    ctx = Setup.build_eval_context(opts, atoms, gas)

    Heap.put_atoms(atoms)
    Setup.store_function_atoms(fun, atoms)
    prev_ctx = RuntimeState.current()
    ctx = Context.mark_synced(%{ctx | current_func: fun})
    RuntimeState.install(ctx)

    if Heap.get_builtin_names() == nil do
      Heap.put_builtin_names(MapSet.new(Map.keys(Runtime.global_bindings())))
    end

    try do
      case function_instructions(fun) do
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

          Trace.push(fun)

          try do
            result = run(0, frame, args, gas, ctx)
            Promise.drain_microtasks()
            {:ok, unwrap_promise(result), RuntimeState.current()}
          catch
            {:js_throw, val} -> {:error, {:js_throw, val}}
            {:error, _} = err -> err
          after
            Trace.pop()
          end

        {:error, _} = err ->
          err
      end
    after
      RuntimeState.restore(prev_ctx)
    end
  end

  @doc "Invoke a VM function or closure from external code."
  def invoke(fun, args, gas), do: Invocation.invoke(fun, args, gas)

  @doc """
  Invokes a JS function with a specific `this` receiver.
  """
  def invoke_with_receiver(fun, args, gas, this_obj),
    do: Invocation.invoke_with_receiver(fun, args, gas, this_obj)

  def invoke_constructor(fun, args, gas, this_obj, new_target),
    do: Invocation.invoke_constructor(fun, args, gas, this_obj, new_target)

  defp catch_and_dispatch(pc, frame, rest, gas, ctx, fun, refresh_globals?) do
    RuntimeState.install(ctx)

    call_result =
      try do
        {:ok, fun.()}
      catch
        {:js_throw, val} -> {:throw, val}
      end

    call_ctx = RuntimeState.current_or(ctx)

    if refresh_globals? do
      persistent = Heap.get_persistent_globals() || %{}

      refreshed_ctx =
        %{call_ctx | globals: Map.merge(call_ctx.globals, persistent)}
        |> Context.mark_dirty()
        |> refresh_global_object_writes()

      refreshed_ctx = refresh_call_arg_buf(refreshed_ctx)

      case call_result do
        {:ok, result} ->
          synced_frame = sync_global_writes_to_frame(frame, refreshed_ctx)
          run(pc + 1, synced_frame, [result | rest], gas, refreshed_ctx)

        {:throw, val} ->
          synced_frame = sync_global_writes_to_frame(frame, refreshed_ctx)

          throw_or_catch(
            synced_frame,
            val,
            gas,
            close_active_iterators_on_abrupt(rest, refreshed_ctx)
          )
      end
    else
      updated_ctx = refresh_call_arg_buf(call_ctx)

      case call_result do
        {:ok, result} ->
          synced_frame = sync_global_writes_to_frame(frame, updated_ctx)
          run(pc + 1, synced_frame, [result | rest], gas, updated_ctx)

        {:throw, val} ->
          synced_frame = sync_global_writes_to_frame(frame, updated_ctx)

          throw_or_catch(
            synced_frame,
            val,
            gas,
            close_active_iterators_on_abrupt(rest, updated_ctx)
          )
      end
    end
  end

  # ── Helpers ──

  defp refresh_global_object_writes(ctx) do
    case Map.get(ctx.globals, "globalThis") do
      {:obj, ref} ->
        raw = Heap.get_obj_raw(ref)

        case Process.get(:qb_global_object_refresh_cache) do
          {^ref, cached_raw, cached_globals} when cached_raw == raw ->
            Context.mark_dirty(%{ctx | globals: cached_globals})

          _ ->
            refresh_global_object_writes(ctx, ref, raw)
        end

      _ ->
        ctx
    end
  end

  defp refresh_global_object_writes(ctx, ref, raw) do
    case QuickBEAM.VM.Heap.Store.shape_to_map(raw) do
      map when is_map(map) ->
        visible_globals = visible_global_properties(map)

        globals = Map.merge(ctx.globals, visible_globals)
        Heap.put_persistent_globals(globals)
        Heap.put_base_globals(globals)
        Process.put(:qb_global_object_refresh_cache, {ref, raw, globals})
        Context.mark_dirty(%{ctx | globals: globals})

      _ ->
        ctx
    end
  end

  defp visible_global_properties(map) do
    Map.drop(map, [
      "__proto__",
      "__promise_state__",
      "__promise_value__",
      "__map_data__",
      "__set_data__",
      "__typed_array__",
      "__date_ms__",
      "__proxy_target__",
      "__proxy_handler__",
      "__buffer__",
      :__key_order__,
      "__primitive_value__",
      "__type__",
      "__offset__"
    ])
  end

  defp sync_setter_globals_to_frame(frame, ctx) do
    if SetterState.consume_invoked?() do
      sync_global_writes_to_frame(frame, RuntimeState.current_or(ctx))
    else
      frame
    end
  end

  defp sync_global_writes_to_frame(frame, ctx) do
    case ctx.current_func do
      {:closure, _, %QuickBEAM.VM.Function{locals: local_defs, arg_count: arg_count}} ->
        sync_global_writes_to_frame(frame, ctx, local_defs, arg_count)

      %QuickBEAM.VM.Function{locals: local_defs, arg_count: arg_count} ->
        sync_global_writes_to_frame(frame, ctx, local_defs, arg_count)

      _ ->
        frame
    end
  end

  defp sync_global_writes_to_frame(frame, ctx, local_defs, arg_count) do
    locals = elem(frame, Frame.locals())

    updated =
      local_defs
      |> Enum.with_index()
      |> Enum.reduce(locals, fn {vd, idx}, acc ->
        name = Names.resolve_display_name(vd.name)

        with true <-
               idx >= arg_count and is_binary(name) and name != "arguments" and
                 idx < tuple_size(acc),
             {:ok, value} <- synced_global_value(ctx, name) do
          put_elem(acc, idx, value)
        else
          _ -> acc
        end
      end)

    put_elem(frame, Frame.locals(), updated)
  end

  defp synced_global_value(ctx, name) do
    global_this_result =
      if match?({:obj, _}, Map.get(ctx.globals, "globalThis")) do
        global_this_value(ctx, name)
      else
        :error
      end

    case global_this_result do
      {:ok, value} ->
        {:ok, value}

      :error ->
        if Map.has_key?(ctx.globals, name), do: {:ok, Map.fetch!(ctx.globals, name)}, else: :error
    end
  end

  defp global_this_value(ctx, name) do
    {:obj, ref} = Map.fetch!(ctx.globals, "globalThis")

    case Heap.get_obj(ref, %{}) do
      map when is_map(map) ->
        if Map.has_key?(map, name), do: {:ok, Map.fetch!(map, name)}, else: :error

      _ ->
        :error
    end
  end

  defp uninitialized_this_local?(ctx, idx), do: EvalEnv.current_local_name(ctx, idx) == "this"

  defp derived_this_uninitialized?(%Context{
         this: this,
         current_func: {:closure, _, %QuickBEAM.VM.Function{is_derived_class_constructor: true}}
       })
       when this == :uninitialized or
              (is_tuple(this) and tuple_size(this) == 2 and elem(this, 0) == :uninitialized),
       do: true

  defp derived_this_uninitialized?(%Context{
         this: this,
         current_func: %QuickBEAM.VM.Function{is_derived_class_constructor: true}
       })
       when this == :uninitialized or
              (is_tuple(this) and tuple_size(this) == 2 and elem(this, 0) == :uninitialized),
       do: true

  defp derived_this_uninitialized?(_), do: false

  defp current_var_ref_name(
         %Context{current_func: {:closure, _, %QuickBEAM.VM.Function{closure_vars: vars}}},
         idx
       )
       when idx >= 0 and idx < length(vars),
       do: vars |> Enum.at(idx) |> Map.get(:name) |> Names.resolve_display_name()

  defp current_var_ref_name(
         %Context{current_func: %QuickBEAM.VM.Function{closure_vars: vars}},
         idx
       )
       when idx >= 0 and idx < length(vars),
       do: vars |> Enum.at(idx) |> Map.get(:name) |> Names.resolve_display_name()

  defp current_var_ref_name(_, _), do: nil

  defp refresh_call_arg_buf(ctx) do
    case RuntimeState.current() do
      %{arg_buf: arg_buf} when is_tuple(arg_buf) -> Context.mark_dirty(%{ctx | arg_buf: arg_buf})
      _ -> ctx
    end
  end

  defp put_local(f, idx, val),
    do: put_elem(f, Frame.locals(), put_elem(elem(f, Frame.locals()), idx, val))

  defp trim_catch_stack(ctx, saved_stack) when is_list(saved_stack) do
    if ctx.catch_stack === saved_stack do
      ctx
    else
      Context.mark_dirty(%{ctx | catch_stack: saved_stack})
    end
  end

  def resume_throw(frame, error, gas, ctx), do: throw_or_catch(frame, error, gas, ctx)

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

  defp current_strict_mode?(ctx), do: Value.strict_context?(ctx)

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

  @doc "Resolves an awaited value for async interpreter execution."
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
        # Drain timers, then microtasks, then recheck
        drain_pending(ref, obj, 0)

      _ ->
        obj
    end
  end

  def resolve_awaited(val), do: val

  @max_timer_drain_ms 5000

  defp drain_pending(_ref, obj, elapsed_ms) when elapsed_ms > @max_timer_drain_ms, do: obj

  defp drain_pending(ref, obj, elapsed_ms) do
    did_fire = QuickBEAM.VM.Execution.EventLoop.drain_host_tasks()
    Promise.drain_microtasks()

    case Heap.get_obj(ref, %{}) do
      %{promise_state() => :resolved, promise_value() => val} ->
        val

      %{promise_state() => :rejected, promise_value() => val} ->
        throw({:js_throw, val})

      %{promise_state() => :pending} ->
        sleep_ms =
          if did_fire do
            0
          else
            QuickBEAM.VM.Execution.EventLoop.next_delay_ms() || 1
          end

        if sleep_ms > 0, do: :timer.sleep(sleep_ms)

        drain_pending(ref, obj, elapsed_ms + sleep_ms)

      _ ->
        obj
    end
  end

  defp list_iterator_next(pos_ref) do
    case Heap.get_obj_raw(pos_ref) do
      [head | tail] ->
        Heap.put_obj_raw(pos_ref, tail)
        Heap.wrap(%{"value" => head, "done" => false})

      _ ->
        Heap.wrap(%{"value" => :undefined, "done" => true})
    end
  end

  defp make_list_iterator(items) do
    pos_ref = make_ref()
    Heap.put_obj_raw(pos_ref, items)
    next_fn = {:builtin, "next", fn _, _ -> list_iterator_next(pos_ref) end}
    {object(do: prop("next", next_fn)), next_fn}
  end

  defp eval_code(code, caller_frame, gas, ctx, var_objs, keep_declared?) do
    DirectEval.eval(%DirectEval.Caller{
      code: code,
      ctx: ctx,
      locals: elem(caller_frame, Frame.locals()),
      var_refs: elem(caller_frame, Frame.var_refs()),
      l2v: elem(caller_frame, Frame.l2v()),
      gas: gas,
      var_objects: var_objs,
      keep_declared?: keep_declared?,
      eval_with_ctx: &eval_with_ctx/4,
      function_instructions: &function_instructions/1
    })
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

  defp materialize_constant({:template_object, elems, raw}) when is_list(elems) do
    raw_list =
      case raw do
        {:template_object, nested_raw, _} -> template_constant_elements(nested_raw)
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

  defp template_constant_elements({:array, elems}) when is_list(elems), do: elems
  defp template_constant_elements(elems) when is_list(elems), do: elems
  defp template_constant_elements(value), do: [value]

  defp with_has_property?(obj, key), do: Static.with_has_property?(obj, key)

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
           Builtin.arg(args, 0, :undefined),
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
      intrinsic_eval?(fun, ctx) and is_binary(code) ->
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

  defp intrinsic_eval?(fun, ctx) do
    fun == ctx.globals["eval"] or QuickBEAM.VM.Semantics.Eval.intrinsic_eval?(fun)
  end

  defp callable?(fun) do
    is_function(fun) or match?({:fn, _, _}, fun) or match?({:bound, _, _}, fun) or
      match?(%QuickBEAM.VM.Function{}, fun) or
      match?({:closure, _, %QuickBEAM.VM.Function{}}, fun)
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
    RuntimeState.install(ctx)
    ctx = Context.mark_synced(ctx)

    if ctx.trace_enabled, do: Trace.update_pc(pc)
    run(elem(elem(frame, Frame.insns()), pc), pc, frame, stack, gas, ctx)
  end

  defp run(pc, frame, stack, gas, ctx) do
    RuntimeState.install(ctx)
    if Map.get(ctx, :trace_enabled, false), do: Trace.update_pc(pc)
    run(elem(elem(frame, Frame.insns()), pc), pc, frame, stack, gas, ctx)
  end

  use QuickBEAM.VM.Interpreter.Ops.Stack

  use QuickBEAM.VM.Interpreter.Ops.Locals

  use QuickBEAM.VM.Interpreter.Ops.Control

  use QuickBEAM.VM.Interpreter.Ops.Arithmetic

  use QuickBEAM.VM.Interpreter.Ops.Calls

  use QuickBEAM.VM.Interpreter.Ops.TypePredicates
  use QuickBEAM.VM.Interpreter.Ops.RestArguments
  use QuickBEAM.VM.Interpreter.Ops.ThisValue
  use QuickBEAM.VM.Interpreter.Ops.ThrowErrors
  use QuickBEAM.VM.Interpreter.Ops.FunctionNaming
  use QuickBEAM.VM.Interpreter.Ops.ConstructorChecks
  use QuickBEAM.VM.Interpreter.Ops.PrototypeMutation
  use QuickBEAM.VM.Interpreter.Ops.PrivateSymbols
  use QuickBEAM.VM.Interpreter.Ops.ObjectConstruction
  use QuickBEAM.VM.Interpreter.Ops.FieldAccess
  use QuickBEAM.VM.Interpreter.Ops.ArrayElements
  use QuickBEAM.VM.Interpreter.Ops.SuperAccess
  use QuickBEAM.VM.Interpreter.Ops.PrivateFieldAccess
  use QuickBEAM.VM.Interpreter.Ops.DeleteVars
  use QuickBEAM.VM.Interpreter.Ops.NoopInvalid
  use QuickBEAM.VM.Interpreter.Ops.CopyDataAdapter
  use QuickBEAM.VM.Interpreter.Ops.DeleteProperty
  use QuickBEAM.VM.Interpreter.Ops.InOperatorAdapter
  use QuickBEAM.VM.Interpreter.Ops.InstanceOfAdapter

  use QuickBEAM.VM.Interpreter.Ops.Globals

  use QuickBEAM.VM.Interpreter.Ops.Iterators

  use QuickBEAM.VM.Interpreter.Ops.Generators

  use QuickBEAM.VM.Interpreter.Ops.Classes

  # ── Catch-all for unimplemented opcodes ──

  defp run({op, args}, _pc, _frame, _stack, _gas, _ctx) do
    throw({:error, {:unimplemented_opcode, op, args}})
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
        %QuickBEAM.VM.Function{} = f ->
          do_invoke(f, {:closure, %{}, f}, args, ClosureBuilder.ctor_var_refs(f), gas, ctor_ctx)

        {:closure, captured, %QuickBEAM.VM.Function{} = f} ->
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
    case Invocation.unwrap_constructor_target(fun) do
      %QuickBEAM.VM.Function{is_derived_class_constructor: true} -> {:uninitialized, pending_this}
      _ -> pending_this
    end
  end

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
    gas = check_gas(pc, frame, [fun | args] ++ rest, gas, ctx)

    with_suspended_roots(frame, stack, ctx, fn ->
      catch_and_dispatch(
        pc,
        frame,
        rest,
        gas,
        ctx,
        fn ->
          dispatch_call(fun, Enum.reverse(args), gas, ctx, nil)
        end,
        true
      )
    end)
  end

  defp call_method(pc, frame, stack, argc, gas, ctx) do
    {args, [fun, obj | rest]} = Enum.split(stack, argc)
    gas = check_gas(pc, frame, [obj, fun | args] ++ rest, gas, ctx)
    method_ctx = Context.mark_dirty(%{ctx | this: obj})

    with_suspended_roots(frame, stack, ctx, fn ->
      catch_and_dispatch(
        pc,
        frame,
        rest,
        gas,
        ctx,
        fn ->
          dispatch_call(fun, Enum.reverse(args), gas, method_ctx, obj)
        end,
        true
      )
    end)
  end

  defp with_suspended_roots(frame, stack, ctx, fun) do
    roots = [
      elem(frame, Frame.locals()),
      elem(frame, Frame.var_refs()),
      elem(frame, Frame.constants()),
      ctx.this,
      ctx.current_func,
      ctx.arg_buf,
      ctx.catch_stack,
      ctx.globals
      | stack
    ]

    RuntimeState.with_suspended_roots(roots, fun)
  end

  @doc "Invokes a VM constructor through the interpreter fallback path."
  def invoke_constructor_fallback(fun, args, gas, ctx, this_obj, new_target)

  def invoke_constructor_fallback(
        %QuickBEAM.VM.Function{} = fun,
        args,
        gas,
        ctx,
        this_obj,
        new_target
      ) do
    ctor_ctx = Context.mark_dirty(%{ctx | this: this_obj, new_target: new_target})
    do_invoke(fun, {:closure, %{}, fun}, args, ClosureBuilder.ctor_var_refs(fun), gas, ctor_ctx)
  end

  def invoke_constructor_fallback(
        {:closure, captured, %QuickBEAM.VM.Function{} = fun} = closure,
        args,
        gas,
        ctx,
        this_obj,
        new_target
      ) do
    ctor_ctx = Context.mark_dirty(%{ctx | this: this_obj, new_target: new_target})

    do_invoke(
      fun,
      closure,
      args,
      ClosureBuilder.ctor_var_refs(fun, captured),
      gas,
      ctor_ctx
    )
  end

  @doc "Invokes a VM function through the interpreter fallback path."
  def invoke_function_fallback(%QuickBEAM.VM.Function{} = fun, args, gas, ctx) do
    invoke_function(fun, args, gas, ctx)
  end

  def invoke_function_fallback(other, args, _gas, _ctx)
      when not is_tuple(other) or elem(other, 0) != :bound,
      do: Builtin.call(other, args, nil)

  def invoke_function_fallback({:bound, _, inner, _, _}, args, gas, _ctx),
    do: Invocation.invoke(inner, args, gas)

  @doc "Invokes a closure through the interpreter fallback path."
  def invoke_closure_fallback({:closure, _, %QuickBEAM.VM.Function{}} = closure, args, gas, ctx) do
    invoke_closure(closure, args, gas, ctx)
  end

  def invoke_closure_fallback(other, args, gas, ctx),
    do: invoke_function_fallback(other, args, gas, ctx)

  defp invoke_function(%QuickBEAM.VM.Function{} = fun, args, gas, ctx) do
    do_invoke(fun, {:closure, %{}, fun}, args, [], gas, ctx)
  end

  defp invoke_closure({:closure, captured, %QuickBEAM.VM.Function{} = fun} = self, args, gas, ctx) do
    var_refs =
      for cv <- fun.closure_vars do
        Map.get(captured, ClosureBuilder.capture_key(cv), :undefined)
      end

    do_invoke(fun, self, args, var_refs, gas, ctx)
  end

  defp function_instructions(fun), do: QuickBEAM.VM.Compiler.FunctionInfo.instructions(fun)

  defp do_invoke(%QuickBEAM.VM.Function{} = fun, self_ref, args, var_refs, gas, ctx) do
    RuntimeState.install(ctx)

    insns = fun.instructions

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

        fn_atoms = Heap.get_fn_atoms(fun, Heap.get_atoms())
        Heap.put_atoms(fn_atoms)

        base_inner_ctx =
          %{
            ctx
            | current_func: self_ref,
              arg_buf: List.to_tuple(args),
              catch_stack: [],
              atoms: fn_atoms
          }
          |> InvokeContext.attach_method_state()

        inner_ctx =
          base_inner_ctx
          |> ArgumentsObject.get(frame)
          |> then(&ArgumentsObject.store_global(base_inner_ctx, &1))

        prev_ctx = RuntimeState.current()
        RuntimeState.install(inner_ctx)
        inner_ctx = Context.mark_synced(inner_ctx)

        if inner_ctx.trace_enabled, do: Trace.push(self_ref)
        restore_mark = length(Heap.get_eval_restore_stack())

        try do
          case fun.func_kind do
            @func_generator ->
              Generator.invoke(frame, gas, inner_ctx, self_ref)

            @func_async ->
              Generator.invoke_async(frame, gas, inner_ctx)

            @func_async_generator ->
              Generator.invoke_async_generator(frame, gas, inner_ctx, self_ref)

            _ ->
              run(0, frame, [], gas, inner_ctx)
          end
        after
          DirectEval.restore_restores(restore_mark)
          if inner_ctx.trace_enabled, do: Trace.pop()
          if prev_ctx, do: RuntimeState.install(prev_ctx)
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
