defmodule QuickBEAM.BeamVM.Interpreter do
  @compile {:inline,
            advance: 1,
            jump: 2,
            put_local: 3,
            make_error_obj: 2,
            active_ctx: 0,
            list_iterator_next: 1,
            make_list_iterator: 1,
            with_has_property?: 2,
            check_prototype_chain: 2}
  @moduledoc """
  Executes decoded QuickJS bytecode via multi-clause function dispatch.

  The interpreter pre-decodes bytecode into instruction tuples for O(1) indexed
  access, then runs a tail-recursive dispatch loop with one `defp run/5` clause
  per opcode family.

  ## JS value representation
    - number: Elixir integer or float
    - string: Elixir binary
    - boolean: true / false
    - null: nil
    - undefined: :undefined
    - object: {:ref, reference()}
    - function: {:function, Bytecode.Function.t()} | {:closure, map(), Bytecode.Function.t()}
    - array: {:array, list(), reference()}
  """

  alias QuickBEAM.BeamVM.{Bytecode, Decoder, Runtime}
  alias __MODULE__.{Frame, Ctx}
  require Frame

  alias QuickBEAM.BeamVM.Heap
  alias __MODULE__.{Values, Objects, Closures, Scope}
  import Bitwise, only: [bnot: 1, &&&: 2]

  @default_gas 1_000_000_000
  @func_generator 1
  @func_async 2
  @func_async_generator 3

  @spec eval(Bytecode.Function.t()) :: {:ok, term()} | {:error, term()}
  def eval(%Bytecode.Function{} = fun), do: eval(fun, [], %{})

  @spec eval(Bytecode.Function.t(), [term()], map()) :: {:ok, term()} | {:error, term()}
  def eval(%Bytecode.Function{} = fun, args, opts), do: eval(fun, args, opts, {})

  @spec eval(Bytecode.Function.t(), [term()], map(), tuple()) :: {:ok, term()} | {:error, term()}
  def eval(%Bytecode.Function{} = fun, args, opts, atoms) do
    gas = Map.get(opts, :gas, @default_gas)

    persistent = Process.get(:qb_persistent_globals, %{})

    ctx = %Ctx{
      atoms: atoms,
      globals:
        Runtime.global_bindings()
        |> Map.merge(persistent)
        |> Map.merge(Map.get(opts, :globals, %{})),
      runtime_pid: Map.get(opts, :runtime_pid)
    }

    prev_ctx = Heap.get_ctx()
    Heap.put_ctx(ctx)

    try do
      case Decoder.decode(fun.byte_code) do
        {:ok, instructions} ->
          instructions = List.to_tuple(instructions)
          locals = :erlang.make_tuple(max(fun.arg_count + fun.var_count, 1), :undefined)

          frame =
            Frame.new(
              0,
              locals,
              List.to_tuple(fun.constants),
              {},
              fun.stack_size,
              instructions,
              %{}
            )

          try do
            result = run(frame, args, gas, ctx)
            drain_microtask_queue()
            {:ok, unwrap_promise(result)}
          catch
            {:js_throw, val} -> {:error, {:js_throw, val}}
            {:error, _} = err -> err
          end

        {:error, _} = err ->
          err
      end
    after
      if prev_ctx, do: Heap.put_ctx(prev_ctx), else: Heap.put_ctx(nil)
    end
  end

  @doc "Invoke a bytecode function or closure from external code."
  def invoke(%Bytecode.Function{} = fun, args, gas),
    do: invoke_function(fun, args, gas, active_ctx())

  def invoke({:closure, _, %Bytecode.Function{}} = c, args, gas),
    do: invoke_closure(c, args, gas, active_ctx())

  @doc false
  def invoke_with_receiver(fun, args, gas, this_obj) do
    prev = Heap.get_ctx()
    Heap.put_ctx(%{active_ctx() | this: this_obj})

    try do
      invoke(fun, args, gas)
    after
      if prev, do: Heap.put_ctx(prev)
    end
  end

  defp active_ctx, do: Heap.get_ctx() || %Ctx{}

  defp invoke_callback(fun, args) do
    case fun do
      %Bytecode.Function{} = f -> invoke_function(f, args, 10_000_000, active_ctx())
      {:closure, _, %Bytecode.Function{}} = c -> invoke_closure(c, args, 10_000_000, active_ctx())
      {:builtin, _, cb} when is_function(cb, 1) -> cb.(args)
      _ -> List.first(args, :undefined)
    end
  end

  defp catch_js_throw(frame, rest, gas, ctx, fun) do
    try do
      result = fun.()
      run(advance(frame), [result | rest], gas - 1, ctx)
    catch
      {:js_throw, val} ->
        case ctx.catch_stack do
          [{target, saved_stack} | rest_catch] ->
            run(jump(frame, target), [val | saved_stack], gas - 1, %{
              ctx
              | catch_stack: rest_catch
            })

          [] ->
            throw({:js_throw, val})
        end
    end
  end

  # ── Helpers ──

  defp advance(f), do: put_elem(f, Frame.pc(), elem(f, Frame.pc()) + 1)
  defp jump(f, target), do: put_elem(f, Frame.pc(), target)

  defp put_local(f, idx, val),
    do: put_elem(f, Frame.locals(), put_elem(elem(f, Frame.locals()), idx, val))

  defp make_error_obj(message, name) do
    ref = make_ref()
    Heap.put_obj(ref, %{"message" => message, "name" => name, "stack" => ""})
    {:obj, ref}
  end

  @compile {:inline, unwrap_promise: 2}
  defp unwrap_promise(val, depth \\ 0)

  defp unwrap_promise({:obj, ref}, depth) when depth < 10 do
    case Heap.get_obj(ref, %{}) do
      %{"__promise_state__" => :resolved, "__promise_value__" => val} ->
        unwrap_promise(val, depth + 1)

      _ ->
        {:obj, ref}
    end
  end

  defp unwrap_promise(val, _depth), do: val

  defp resolve_awaited({:obj, ref} = obj) do
    drain_microtask_queue()

    case Heap.get_obj(ref, %{}) do
      %{"__promise_state__" => :resolved, "__promise_value__" => val} ->
        val

      %{"__promise_state__" => :rejected, "__promise_value__" => val} ->
        throw({:js_throw, val})

      %{"__promise_state__" => :pending} ->
        # Drain again in case resolution was queued
        drain_microtask_queue()

        case Heap.get_obj(ref, %{}) do
          %{"__promise_state__" => :resolved, "__promise_value__" => val} ->
            val

          %{"__promise_state__" => :rejected, "__promise_value__" => val} ->
            throw({:js_throw, val})

          _ ->
            obj
        end

      _ ->
        obj
    end
  end

  defp resolve_awaited(val), do: val

  defp list_iterator_next(pos_ref) do
    state = Heap.get_obj(pos_ref, %{pos: 0, list: []})

    if state.pos < length(state.list) do
      val = Enum.at(state.list, state.pos)
      Heap.put_obj(pos_ref, %{state | pos: state.pos + 1})
      ref = make_ref()
      Heap.put_obj(ref, %{"value" => val, "done" => false})
      {:obj, ref}
    else
      ref = make_ref()
      Heap.put_obj(ref, %{"value" => :undefined, "done" => true})
      {:obj, ref}
    end
  end

  defp make_list_iterator(items) do
    pos_ref = make_ref()
    Heap.put_obj(pos_ref, %{pos: 0, list: items})
    next_fn = {:builtin, "next", fn _, _ -> list_iterator_next(pos_ref) end}
    iter_ref = make_ref()
    Heap.put_obj(iter_ref, %{"next" => next_fn})
    {{:obj, iter_ref}, next_fn}
  end

  defp eval_code(code, caller_frame, gas, ctx) do
    case QuickBEAM.Runtime.compile(ctx.runtime_pid, code) do
      {:ok, bc} ->
        case Bytecode.decode(bc) do
          {:ok, parsed} ->
            # Inject caller's named locals into eval's global scope
            eval_globals = collect_caller_locals(caller_frame, ctx)
            eval_ctx_globals = Map.merge(ctx.globals, eval_globals)

            __MODULE__.eval(
              parsed.value,
              [],
              %{gas: gas, runtime_pid: ctx.runtime_pid, globals: eval_ctx_globals},
              parsed.atoms
            )
            |> case do
              {:ok, val} -> val
              {:error, {:js_throw, val}} -> throw({:js_throw, val})
              {:error, _} -> :undefined
            end

          _ ->
            :undefined
        end

      _ ->
        :undefined
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
      name =
        case vd.name do
          s when is_binary(s) -> s
          _ -> nil
        end

      if name do
        val =
          if idx < arg_count do
            if idx < tuple_size(arg_buf), do: elem(arg_buf, idx), else: :undefined
          else
            var_idx = idx - arg_count
            if var_idx < tuple_size(locals), do: elem(locals, var_idx), else: :undefined
          end

        if val != :undefined, do: Map.put(acc, name, val), else: acc
      else
        acc
      end
    end)
  end

  defp check_prototype_chain(_, :undefined), do: false
  defp check_prototype_chain(_, nil), do: false

  defp check_prototype_chain({:obj, ref}, target) do
    case Heap.get_obj(ref, %{}) do
      map when is_map(map) ->
        case Map.get(map, "__proto__") do
          ^target -> true
          nil -> false
          :undefined -> false
          proto -> check_prototype_chain(proto, target)
        end

      _ ->
        false
    end
  end

  defp check_prototype_chain(_, _), do: false

  defp with_has_property?({:obj, _} = obj, key) do
    Runtime.get_property(obj, key) != :undefined
  end

  defp with_has_property?(_, _), do: false

  # ── Main dispatch loop ──

  defp run(_frame, _stack, gas, _ctx) when gas <= 0 do
    throw({:error, {:out_of_gas, gas}})
  end

  defp run(frame, stack, gas, ctx) do
    if rem(gas, 1000) == 0 and Heap.gc_needed?() do
      roots =
        [
          elem(frame, Frame.locals()),
          elem(frame, Frame.var_refs()),
          elem(frame, Frame.constants()),
          ctx.this,
          ctx.current_func,
          ctx.arg_buf,
          ctx.catch_stack,
          ctx.globals
          | stack
        ] ++ Heap.all_module_exports()

      Heap.mark_and_sweep(roots)
    end

    run(elem(elem(frame, Frame.insns()), elem(frame, Frame.pc())), frame, stack, gas, ctx)
  end

  # ── Push constants ──

  defp run({:push_i32, [val]}, frame, stack, gas, ctx),
    do: run(advance(frame), [val | stack], gas - 1, ctx)

  defp run({:push_i8, [val]}, frame, stack, gas, ctx),
    do: run(advance(frame), [val | stack], gas - 1, ctx)

  defp run({:push_i16, [val]}, frame, stack, gas, ctx),
    do: run(advance(frame), [val | stack], gas - 1, ctx)

  defp run({:push_minus1, _}, frame, stack, gas, ctx),
    do: run(advance(frame), [-1 | stack], gas - 1, ctx)

  defp run({:push_0, _}, frame, stack, gas, ctx),
    do: run(advance(frame), [0 | stack], gas - 1, ctx)

  defp run({:push_1, _}, frame, stack, gas, ctx),
    do: run(advance(frame), [1 | stack], gas - 1, ctx)

  defp run({:push_2, _}, frame, stack, gas, ctx),
    do: run(advance(frame), [2 | stack], gas - 1, ctx)

  defp run({:push_3, _}, frame, stack, gas, ctx),
    do: run(advance(frame), [3 | stack], gas - 1, ctx)

  defp run({:push_4, _}, frame, stack, gas, ctx),
    do: run(advance(frame), [4 | stack], gas - 1, ctx)

  defp run({:push_5, _}, frame, stack, gas, ctx),
    do: run(advance(frame), [5 | stack], gas - 1, ctx)

  defp run({:push_6, _}, frame, stack, gas, ctx),
    do: run(advance(frame), [6 | stack], gas - 1, ctx)

  defp run({:push_7, _}, frame, stack, gas, ctx),
    do: run(advance(frame), [7 | stack], gas - 1, ctx)

  defp run({op, [idx]}, frame, stack, gas, ctx) when op in [:push_const, :push_const8] do
    run(
      advance(frame),
      [Scope.resolve_const(elem(frame, Frame.constants()), idx) | stack],
      gas - 1,
      ctx
    )
  end

  defp run({:push_atom_value, [atom_idx]}, frame, stack, gas, ctx) do
    run(advance(frame), [Scope.resolve_atom(ctx, atom_idx) | stack], gas - 1, ctx)
  end

  defp run({:undefined, []}, frame, stack, gas, ctx),
    do: run(advance(frame), [:undefined | stack], gas - 1, ctx)

  defp run({:null, []}, frame, stack, gas, ctx),
    do: run(advance(frame), [nil | stack], gas - 1, ctx)

  defp run({:push_false, []}, frame, stack, gas, ctx),
    do: run(advance(frame), [false | stack], gas - 1, ctx)

  defp run({:push_true, []}, frame, stack, gas, ctx),
    do: run(advance(frame), [true | stack], gas - 1, ctx)

  defp run({:push_empty_string, []}, frame, stack, gas, ctx),
    do: run(advance(frame), ["" | stack], gas - 1, ctx)

  defp run({:push_bigint_i32, [val]}, frame, stack, gas, ctx),
    do: run(advance(frame), [{:bigint, val} | stack], gas - 1, ctx)

  # ── Stack manipulation ──

  defp run({:drop, []}, frame, [_ | rest], gas, ctx), do: run(advance(frame), rest, gas - 1, ctx)

  defp run({:nip, []}, frame, [a, _b | rest], gas, ctx),
    do: run(advance(frame), [a | rest], gas - 1, ctx)

  defp run({:nip1, []}, frame, [a, b, _c | rest], gas, ctx),
    do: run(advance(frame), [a, b | rest], gas - 1, ctx)

  defp run({:dup, []}, frame, [a | _] = stack, gas, ctx),
    do: run(advance(frame), [a | stack], gas - 1, ctx)

  defp run({:dup1, []}, frame, [a, b | _] = stack, gas, ctx) do
    run(advance(frame), [a, b | stack], gas - 1, ctx)
  end

  defp run({:dup2, []}, frame, [a, b | _] = stack, gas, ctx) do
    run(advance(frame), [a, b, a, b | stack], gas - 1, ctx)
  end

  defp run({:dup3, []}, frame, [a, b, c | _] = stack, gas, ctx) do
    run(advance(frame), [a, b, c, a, b, c | stack], gas - 1, ctx)
  end

  defp run({:insert2, []}, frame, [a, b | rest], gas, ctx),
    do: run(advance(frame), [a, b, a | rest], gas - 1, ctx)

  defp run({:insert3, []}, frame, [a, b, c | rest], gas, ctx),
    do: run(advance(frame), [a, b, c, a | rest], gas - 1, ctx)

  defp run({:insert4, []}, frame, [a, b, c, d | rest], gas, ctx),
    do: run(advance(frame), [a, b, c, d, a | rest], gas - 1, ctx)

  defp run({:perm3, []}, frame, [a, b, c | rest], gas, ctx),
    do: run(advance(frame), [c, a, b | rest], gas - 1, ctx)

  defp run({:perm4, []}, frame, [a, b, c, d | rest], gas, ctx),
    do: run(advance(frame), [d, a, b, c | rest], gas - 1, ctx)

  defp run({:perm5, []}, frame, [a, b, c, d, e | rest], gas, ctx),
    do: run(advance(frame), [e, a, b, c, d | rest], gas - 1, ctx)

  defp run({:swap, []}, frame, [a, b | rest], gas, ctx),
    do: run(advance(frame), [b, a | rest], gas - 1, ctx)

  defp run({:swap2, []}, frame, [a, b, c, d | rest], gas, ctx),
    do: run(advance(frame), [c, d, a, b | rest], gas - 1, ctx)

  defp run({:rot3l, []}, frame, [a, b, c | rest], gas, ctx),
    do: run(advance(frame), [b, c, a | rest], gas - 1, ctx)

  defp run({:rot3r, []}, frame, [a, b, c | rest], gas, ctx),
    do: run(advance(frame), [c, a, b | rest], gas - 1, ctx)

  defp run({:rot4l, []}, frame, [a, b, c, d | rest], gas, ctx),
    do: run(advance(frame), [b, c, d, a | rest], gas - 1, ctx)

  defp run({:rot5l, []}, frame, [a, b, c, d, e | rest], gas, ctx),
    do: run(advance(frame), [b, c, d, e, a | rest], gas - 1, ctx)

  # ── Args ──

  defp run({:get_arg, [idx]}, frame, stack, gas, ctx),
    do: run(advance(frame), [Scope.get_arg_value(ctx, idx) | stack], gas - 1, ctx)

  defp run({:get_arg0, []}, frame, stack, gas, ctx),
    do: run(advance(frame), [Scope.get_arg_value(ctx, 0) | stack], gas - 1, ctx)

  defp run({:get_arg1, []}, frame, stack, gas, ctx),
    do: run(advance(frame), [Scope.get_arg_value(ctx, 1) | stack], gas - 1, ctx)

  defp run({:get_arg2, []}, frame, stack, gas, ctx),
    do: run(advance(frame), [Scope.get_arg_value(ctx, 2) | stack], gas - 1, ctx)

  defp run({:get_arg3, []}, frame, stack, gas, ctx),
    do: run(advance(frame), [Scope.get_arg_value(ctx, 3) | stack], gas - 1, ctx)

  # ── Locals ──

  defp run({:get_loc, [idx]}, frame, stack, gas, ctx) do
    run(
      advance(frame),
      [
        Closures.read_captured_local(
          elem(frame, Frame.l2v()),
          idx,
          elem(frame, Frame.locals()),
          elem(frame, Frame.var_refs())
        )
        | stack
      ],
      gas - 1,
      ctx
    )
  end

  defp run({:put_loc, [idx]}, frame, [val | rest], gas, ctx) do
    Closures.write_captured_local(
      elem(frame, Frame.l2v()),
      idx,
      val,
      elem(frame, Frame.locals()),
      elem(frame, Frame.var_refs())
    )

    run(advance(put_local(frame, idx, val)), rest, gas - 1, ctx)
  end

  defp run({:set_loc, [idx]}, frame, [val | rest], gas, ctx) do
    Closures.write_captured_local(
      elem(frame, Frame.l2v()),
      idx,
      val,
      elem(frame, Frame.locals()),
      elem(frame, Frame.var_refs())
    )

    run(advance(put_local(frame, idx, val)), [val | rest], gas - 1, ctx)
  end

  defp run({:set_loc_uninitialized, [idx]}, frame, stack, gas, ctx) do
    run(advance(put_local(frame, idx, :undefined)), stack, gas - 1, ctx)
  end

  defp run({:get_loc_check, [idx]}, frame, stack, gas, ctx) do
    val = elem(elem(frame, Frame.locals()), idx)
    if val == :undefined, do: throw({:error, {:uninitialized_local, idx}})
    run(advance(frame), [val | stack], gas - 1, ctx)
  end

  defp run({:put_loc_check, [idx]}, frame, [val | rest], gas, ctx) do
    if val == :undefined, do: throw({:error, {:uninitialized_local, idx}})
    run(advance(put_local(frame, idx, val)), rest, gas - 1, ctx)
  end

  defp run({:put_loc_check_init, [idx]}, frame, [val | rest], gas, ctx) do
    run(advance(put_local(frame, idx, val)), rest, gas - 1, ctx)
  end

  defp run({:get_loc0_loc1, []}, frame, stack, gas, ctx) do
    locals = elem(frame, Frame.locals())
    run(advance(frame), [elem(locals, 1), elem(locals, 0) | stack], gas - 1, ctx)
  end

  # ── Variable references (closures) ──

  defp run({:get_var_ref, [idx]}, frame, stack, gas, ctx) do
    val =
      case elem(elem(frame, Frame.var_refs()), idx) do
        {:cell, _} = cell -> Closures.read_cell(cell)
        other -> other
      end

    run(advance(frame), [val | stack], gas - 1, ctx)
  end

  defp run({:put_var_ref, [idx]}, frame, [val | rest], gas, ctx) do
    case elem(elem(frame, Frame.var_refs()), idx) do
      {:cell, ref} -> Closures.write_cell({:cell, ref}, val)
      _ -> :ok
    end

    run(advance(frame), rest, gas - 1, ctx)
  end

  defp run({:set_var_ref, [idx]}, frame, [val | rest], gas, ctx) do
    case elem(elem(frame, Frame.var_refs()), idx) do
      {:cell, ref} -> Closures.write_cell({:cell, ref}, val)
      _ -> :ok
    end

    run(advance(frame), [val | rest], gas - 1, ctx)
  end

  defp run({:close_loc, [_idx]}, frame, stack, gas, ctx),
    do: run(advance(frame), stack, gas - 1, ctx)

  # ── Control flow ──

  defp run({op, [target]}, frame, [val | rest], gas, ctx) when op in [:if_false, :if_false8] do
    if Values.falsy?(val),
      do: run(jump(frame, target), rest, gas - 1, ctx),
      else: run(advance(frame), rest, gas - 1, ctx)
  end

  defp run({op, [target]}, frame, [val | rest], gas, ctx) when op in [:if_true, :if_true8] do
    if Values.truthy?(val),
      do: run(jump(frame, target), rest, gas - 1, ctx),
      else: run(advance(frame), rest, gas - 1, ctx)
  end

  defp run({op, [target]}, frame, stack, gas, ctx) when op in [:goto, :goto8, :goto16] do
    run(jump(frame, target), stack, gas - 1, ctx)
  end

  defp run({:return, []}, _frame, [val | _], _gas, _ctx), do: val

  defp run({:return_undef, []}, _frame, _stack, _gas, _ctx), do: :undefined

  # ── Arithmetic ──

  defp run({:add, []}, frame, [b, a | rest], gas, ctx),
    do: run(advance(frame), [Values.add(a, b) | rest], gas - 1, ctx)

  defp run({:sub, []}, frame, [b, a | rest], gas, ctx),
    do: run(advance(frame), [Values.sub(a, b) | rest], gas - 1, ctx)

  defp run({:mul, []}, frame, [b, a | rest], gas, ctx),
    do: run(advance(frame), [Values.mul(a, b) | rest], gas - 1, ctx)

  defp run({:div, []}, frame, [b, a | rest], gas, ctx),
    do: run(advance(frame), [Values.div(a, b) | rest], gas - 1, ctx)

  defp run({:mod, []}, frame, [b, a | rest], gas, ctx),
    do: run(advance(frame), [Values.mod(a, b) | rest], gas - 1, ctx)

  defp run({:pow, []}, frame, [b, a | rest], gas, ctx),
    do: run(advance(frame), [Values.pow(a, b) | rest], gas - 1, ctx)

  # ── Bitwise ──

  defp run({:band, []}, frame, [b, a | rest], gas, ctx),
    do: run(advance(frame), [Values.band(a, b) | rest], gas - 1, ctx)

  defp run({:bor, []}, frame, [b, a | rest], gas, ctx),
    do: run(advance(frame), [Values.bor(a, b) | rest], gas - 1, ctx)

  defp run({:bxor, []}, frame, [b, a | rest], gas, ctx),
    do: run(advance(frame), [Values.bxor(a, b) | rest], gas - 1, ctx)

  defp run({:shl, []}, frame, [b, a | rest], gas, ctx),
    do: run(advance(frame), [Values.shl(a, b) | rest], gas - 1, ctx)

  defp run({:sar, []}, frame, [b, a | rest], gas, ctx),
    do: run(advance(frame), [Values.sar(a, b) | rest], gas - 1, ctx)

  defp run({:shr, []}, frame, [b, a | rest], gas, ctx),
    do: run(advance(frame), [Values.shr(a, b) | rest], gas - 1, ctx)

  # ── Comparison ──

  defp run({:lt, []}, frame, [b, a | rest], gas, ctx),
    do: run(advance(frame), [Values.lt(a, b) | rest], gas - 1, ctx)

  defp run({:lte, []}, frame, [b, a | rest], gas, ctx),
    do: run(advance(frame), [Values.lte(a, b) | rest], gas - 1, ctx)

  defp run({:gt, []}, frame, [b, a | rest], gas, ctx),
    do: run(advance(frame), [Values.gt(a, b) | rest], gas - 1, ctx)

  defp run({:gte, []}, frame, [b, a | rest], gas, ctx),
    do: run(advance(frame), [Values.gte(a, b) | rest], gas - 1, ctx)

  defp run({:eq, []}, frame, [b, a | rest], gas, ctx),
    do: run(advance(frame), [Values.eq(a, b) | rest], gas - 1, ctx)

  defp run({:neq, []}, frame, [b, a | rest], gas, ctx),
    do: run(advance(frame), [Values.neq(a, b) | rest], gas - 1, ctx)

  defp run({:strict_eq, []}, frame, [b, a | rest], gas, ctx),
    do: run(advance(frame), [Values.strict_eq(a, b) | rest], gas - 1, ctx)

  defp run({:strict_neq, []}, frame, [b, a | rest], gas, ctx),
    do: run(advance(frame), [not Values.strict_eq(a, b) | rest], gas - 1, ctx)

  # ── Unary ──

  defp run({:neg, []}, frame, [a | rest], gas, ctx),
    do: run(advance(frame), [Values.neg(a) | rest], gas - 1, ctx)

  defp run({:plus, []}, frame, [a | rest], gas, ctx),
    do: run(advance(frame), [Values.to_number(a) | rest], gas - 1, ctx)

  defp run({:inc, []}, frame, [a | rest], gas, ctx),
    do: run(advance(frame), [Values.add(a, 1) | rest], gas - 1, ctx)

  defp run({:dec, []}, frame, [a | rest], gas, ctx),
    do: run(advance(frame), [Values.sub(a, 1) | rest], gas - 1, ctx)

  defp run({:post_inc, []}, frame, [a | rest], gas, ctx),
    do: run(advance(frame), [Values.add(a, 1), a | rest], gas - 1, ctx)

  defp run({:post_dec, []}, frame, [a | rest], gas, ctx),
    do: run(advance(frame), [Values.sub(a, 1), a | rest], gas - 1, ctx)

  defp run({:inc_loc, [idx]}, frame, stack, gas, ctx) do
    locals = elem(frame, Frame.locals())
    vrefs = elem(frame, Frame.var_refs())
    l2v = elem(frame, Frame.l2v())
    new_val = Values.add(elem(locals, idx), 1)
    Closures.write_captured_local(l2v, idx, new_val, locals, vrefs)
    run(advance(put_local(frame, idx, new_val)), stack, gas - 1, ctx)
  end

  defp run({:dec_loc, [idx]}, frame, stack, gas, ctx) do
    locals = elem(frame, Frame.locals())
    vrefs = elem(frame, Frame.var_refs())
    l2v = elem(frame, Frame.l2v())
    new_val = Values.sub(elem(locals, idx), 1)
    Closures.write_captured_local(l2v, idx, new_val, locals, vrefs)
    run(advance(put_local(frame, idx, new_val)), stack, gas - 1, ctx)
  end

  defp run({:add_loc, [idx]}, frame, [val | rest], gas, ctx) do
    locals = elem(frame, Frame.locals())
    vrefs = elem(frame, Frame.var_refs())
    l2v = elem(frame, Frame.l2v())
    new_val = Values.add(elem(locals, idx), val)
    Closures.write_captured_local(l2v, idx, new_val, locals, vrefs)
    run(advance(put_local(frame, idx, new_val)), rest, gas - 1, ctx)
  end

  defp run({:not, []}, frame, [a | rest], gas, ctx),
    do: run(advance(frame), [bnot(Values.to_int32(a)) | rest], gas - 1, ctx)

  defp run({:lnot, []}, frame, [a | rest], gas, ctx),
    do: run(advance(frame), [not Values.truthy?(a) | rest], gas - 1, ctx)

  defp run({:typeof, []}, frame, [a | rest], gas, ctx),
    do: run(advance(frame), [Values.typeof(a) | rest], gas - 1, ctx)

  # ── Function creation / calls ──

  defp run({op, [idx]}, frame, stack, gas, ctx) when op in [:fclosure, :fclosure8] do
    fun = Scope.resolve_const(elem(frame, Frame.constants()), idx)

    closure =
      build_closure(
        fun,
        elem(frame, Frame.locals()),
        elem(frame, Frame.var_refs()),
        elem(frame, Frame.l2v()),
        ctx
      )

    run(advance(frame), [closure | stack], gas - 1, ctx)
  end

  defp run({:call, [argc]}, frame, stack, gas, ctx),
    do: call_function(frame, stack, argc, gas, ctx)

  defp run({:tail_call, [argc]}, _frame, stack, gas, ctx), do: tail_call(stack, argc, gas, ctx)

  defp run({:call_method, [argc]}, frame, stack, gas, ctx),
    do: call_method(frame, stack, argc, gas, ctx)

  defp run({:tail_call_method, [argc]}, _frame, stack, gas, ctx),
    do: tail_call_method(stack, argc, gas, ctx)

  # ── Objects ──

  defp run({:object, []}, frame, stack, gas, ctx) do
    ref = make_ref()
    Heap.put_obj(ref, %{})
    run(advance(frame), [{:obj, ref} | stack], gas - 1, ctx)
  end

  defp run({:get_field, [atom_idx]}, frame, [obj | _rest], gas, ctx)
       when obj == nil or obj == :undefined do
    prop = Scope.resolve_atom(ctx, atom_idx)
    nullish = if obj == nil, do: "null", else: "undefined"

    error =
      make_error_obj("Cannot read properties of #{nullish} (reading '#{prop}')", "TypeError")

    case ctx.catch_stack do
      [{target, saved_stack} | rest_catch] ->
        run(jump(frame, target), [error | saved_stack], gas - 1, %{ctx | catch_stack: rest_catch})

      [] ->
        throw({:js_throw, error})
    end
  end

  defp run({:get_field, [atom_idx]}, frame, [obj | rest], gas, ctx) do
    run(
      advance(frame),
      [Runtime.get_property(obj, Scope.resolve_atom(ctx, atom_idx)) | rest],
      gas - 1,
      ctx
    )
  end

  defp run({:put_field, [atom_idx]}, frame, [val, obj | rest], gas, ctx) do
    Objects.put(obj, Scope.resolve_atom(ctx, atom_idx), val)
    run(advance(frame), [obj | rest], gas - 1, ctx)
  end

  defp run({:define_field, [atom_idx]}, frame, [val, obj | rest], gas, ctx) do
    Objects.put(obj, Scope.resolve_atom(ctx, atom_idx), val)
    run(advance(frame), [obj | rest], gas - 1, ctx)
  end

  defp run({:get_array_el, []}, frame, [idx, obj | rest], gas, ctx) do
    run(advance(frame), [Objects.get_array_el(obj, idx) | rest], gas - 1, ctx)
  end

  defp run({:put_array_el, []}, frame, [val, idx, obj | rest], gas, ctx) do
    Objects.put_array_el(obj, idx, val)
    run(advance(frame), [obj | rest], gas - 1, ctx)
  end

  defp run({:get_super_value, []}, frame, [key, proto, _this_obj | rest], gas, ctx) do
    val = Runtime.get_property(proto, key)
    run(advance(frame), [val | rest], gas - 1, ctx)
  end

  defp run({:put_super_value, []}, frame, [val, key, _proto, this_obj | rest], gas, ctx) do
    Objects.put(this_obj, key, val)
    run(advance(frame), rest, gas - 1, ctx)
  end

  defp run({:get_private_field, []}, frame, [key, obj | rest], gas, ctx) do
    val =
      case obj do
        {:obj, ref} ->
          map = Heap.get_obj(ref, %{})
          Map.get(map, {:private, key}, :undefined)

        _ ->
          :undefined
      end

    run(advance(frame), [val | rest], gas - 1, ctx)
  end

  defp run({:put_private_field, []}, frame, [key, val, obj | rest], gas, ctx) do
    case obj do
      {:obj, ref} ->
        Heap.update_obj(ref, %{}, &Map.put(&1, {:private, key}, val))

      _ ->
        :ok
    end

    run(advance(frame), rest, gas - 1, ctx)
  end

  defp run({:define_private_field, []}, frame, [val, key, obj | rest], gas, ctx) do
    case obj do
      {:obj, ref} ->
        Heap.update_obj(ref, %{}, &Map.put(&1, {:private, key}, val))

      _ ->
        :ok
    end

    run(advance(frame), [obj | rest], gas - 1, ctx)
  end

  defp run({:private_in, []}, frame, [key, obj | rest], gas, ctx) do
    result =
      case obj do
        {:obj, ref} ->
          map = Heap.get_obj(ref, %{})
          Map.has_key?(map, {:private, key})

        _ ->
          false
      end

    run(advance(frame), [result | rest], gas - 1, ctx)
  end

  defp run({:get_length, []}, frame, [obj | rest], gas, ctx) do
    len =
      case obj do
        {:obj, ref} ->
          case Heap.get_obj(ref) do
            list when is_list(list) -> length(list)
            map when is_map(map) -> Map.get(map, "length", map_size(map))
            _ -> 0
          end

        list when is_list(list) ->
          length(list)

        s when is_binary(s) ->
          Runtime.js_string_length(s)

        %Bytecode.Function{} = f ->
          f.defined_arg_count

        {:closure, _, %Bytecode.Function{} = f} ->
          f.defined_arg_count

        _ ->
          :undefined
      end

    run(advance(frame), [len | rest], gas - 1, ctx)
  end

  defp run({:array_from, [argc]}, frame, stack, gas, ctx) do
    {elems, rest} = Enum.split(stack, argc)
    ref = make_ref()
    Heap.put_obj(ref, Enum.reverse(elems))
    run(advance(frame), [{:obj, ref} | rest], gas - 1, ctx)
  end

  # ── Misc / no-op ──

  defp run({:nop, []}, frame, stack, gas, ctx), do: run(advance(frame), stack, gas - 1, ctx)
  defp run({:to_object, []}, frame, stack, gas, ctx), do: run(advance(frame), stack, gas - 1, ctx)

  defp run({:to_propkey, []}, frame, stack, gas, ctx),
    do: run(advance(frame), stack, gas - 1, ctx)

  defp run({:to_propkey2, []}, frame, stack, gas, ctx),
    do: run(advance(frame), stack, gas - 1, ctx)

  defp run({:check_ctor, []}, frame, stack, gas, ctx),
    do: run(advance(frame), stack, gas - 1, ctx)

  defp run({:check_ctor_return, []}, frame, [val | rest], gas, %Ctx{this: this} = ctx) do
    result =
      case val do
        {:obj, _} = obj -> obj
        _ -> this
      end

    run(advance(frame), [result | rest], gas - 1, ctx)
  end

  defp run({:set_name, [_atom_idx]}, frame, stack, gas, ctx),
    do: run(advance(frame), stack, gas - 1, ctx)

  defp run({:throw, []}, frame, [val | _], gas, %Ctx{catch_stack: catch_stack} = ctx) do
    case catch_stack do
      [{target, saved_stack} | rest_catch] ->
        run(jump(frame, target), [val | saved_stack], gas - 1, %{ctx | catch_stack: rest_catch})

      [] ->
        throw({:js_throw, val})
    end
  end

  defp run({:is_undefined, []}, frame, [a | rest], gas, ctx),
    do: run(advance(frame), [a == :undefined | rest], gas - 1, ctx)

  defp run({:is_null, []}, frame, [a | rest], gas, ctx),
    do: run(advance(frame), [a == nil | rest], gas - 1, ctx)

  defp run({:is_undefined_or_null, []}, frame, [a | rest], gas, ctx),
    do: run(advance(frame), [a == :undefined or a == nil | rest], gas - 1, ctx)

  defp run({:invalid, []}, _frame, _stack, _gas, _ctx), do: throw({:error, :invalid_opcode})

  defp run({:get_var_undef, [atom_idx]}, frame, stack, gas, ctx) do
    val =
      case Scope.resolve_global(ctx, atom_idx) do
        {:found, v} -> v
        :not_found -> :undefined
      end

    run(advance(frame), [val | stack], gas - 1, ctx)
  end

  defp run({:get_var, [atom_idx]}, frame, stack, gas, ctx) do
    case Scope.resolve_global(ctx, atom_idx) do
      {:found, val} ->
        run(advance(frame), [val | stack], gas - 1, ctx)

      :not_found ->
        error =
          make_error_obj("#{Scope.resolve_atom(ctx, atom_idx)} is not defined", "ReferenceError")

        case ctx.catch_stack do
          [{target, saved_stack} | rest_catch] ->
            run(jump(frame, target), [error | saved_stack], gas - 1, %{
              ctx
              | catch_stack: rest_catch
            })

          [] ->
            throw({:js_throw, error})
        end
    end
  end

  defp run({:put_var, [atom_idx]}, frame, [val | rest], gas, ctx) do
    new_ctx = Scope.set_global(ctx, atom_idx, val)
    Process.put(:qb_persistent_globals, new_ctx.globals)
    run(advance(frame), rest, gas - 1, new_ctx)
  end

  defp run({:put_var_init, [atom_idx]}, frame, [val | rest], gas, ctx) do
    new_ctx = Scope.set_global(ctx, atom_idx, val)
    Process.put(:qb_persistent_globals, new_ctx.globals)
    run(advance(frame), rest, gas - 1, new_ctx)
  end

  # define_func: global scope function hoisting (sloppy mode)
  defp run({:define_func, [atom_idx, _flags]}, frame, [fun | rest], gas, ctx) do
    ctx = Scope.set_global(ctx, atom_idx, fun)
    Process.put(:qb_persistent_globals, ctx.globals)
    run(advance(frame), rest, gas - 1, ctx)
  end

  defp run({:define_var, [atom_idx, _scope]}, frame, stack, gas, ctx) do
    Heap.put_var(Scope.resolve_atom(ctx, atom_idx), :undefined)
    run(advance(frame), stack, gas - 1, ctx)
  end

  defp run({:check_define_var, [atom_idx, _scope]}, frame, stack, gas, ctx) do
    Heap.delete_var(Scope.resolve_atom(ctx, atom_idx))
    run(advance(frame), stack, gas - 1, ctx)
  end

  defp run({:get_field2, [atom_idx]}, frame, [obj | _rest], gas, ctx)
       when obj == nil or obj == :undefined do
    prop = Scope.resolve_atom(ctx, atom_idx)
    nullish = if obj == nil, do: "null", else: "undefined"

    error =
      make_error_obj("Cannot read properties of #{nullish} (reading '#{prop}')", "TypeError")

    case ctx.catch_stack do
      [{target, saved_stack} | rest_catch] ->
        run(jump(frame, target), [error | saved_stack], gas - 1, %{ctx | catch_stack: rest_catch})

      [] ->
        throw({:js_throw, error})
    end
  end

  defp run({:get_field2, [atom_idx]}, frame, [obj | rest], gas, ctx) do
    val = Runtime.get_property(obj, Scope.resolve_atom(ctx, atom_idx))
    run(advance(frame), [val, obj | rest], gas - 1, ctx)
  end

  # ── try/catch ──

  defp run({:catch, [target]}, frame, stack, gas, %Ctx{catch_stack: catch_stack} = ctx) do
    ctx = %{ctx | catch_stack: [{target, stack} | catch_stack]}
    run(advance(frame), [target | stack], gas - 1, ctx)
  end

  defp run(
         {:nip_catch, []},
         frame,
         [a, _catch_offset | rest],
         gas,
         %Ctx{catch_stack: [_ | rest_catch]} = ctx
       ) do
    run(advance(frame), [a | rest], gas - 1, %{ctx | catch_stack: rest_catch})
  end

  # ── for-in ──

  defp run({:for_in_start, []}, frame, [obj | rest], gas, ctx) do
    keys =
      case obj do
        {:obj, ref} ->
          map = Heap.get_obj(ref, %{})

          raw_keys =
            case Map.get(map, :__key_order__) do
              order when is_list(order) -> Enum.reverse(order)
              _ -> Map.keys(map)
            end

          raw_keys
          |> Enum.reject(fn k ->
            (is_binary(k) and String.starts_with?(k, "__")) or
              is_tuple(k) or is_atom(k) or
              not Map.has_key?(map, k) or
              match?(%{enumerable: false}, Heap.get_prop_desc(ref, k))
          end)
          |> then(fn keys ->
            {numeric, strings} =
              Enum.split_with(keys, fn
                k when is_integer(k) -> true
                k when is_binary(k) -> match?({_, ""}, Integer.parse(k))
                _ -> false
              end)

            sorted_numeric =
              Enum.sort_by(numeric, fn
                k when is_integer(k) -> k
                k when is_binary(k) -> elem(Integer.parse(k), 0)
              end)
              |> Enum.map(fn
                k when is_integer(k) -> Integer.to_string(k)
                k -> k
              end)

            sorted_numeric ++ Enum.filter(strings, &is_binary/1)
          end)

        map when is_map(map) ->
          Map.keys(map)

        _ ->
          []
      end

    run(advance(frame), [{:for_in_iterator, keys} | rest], gas - 1, ctx)
  end

  defp run({:for_in_next, []}, frame, [{:for_in_iterator, [key | rest_keys]} | rest], gas, ctx) do
    run(advance(frame), [false, key, {:for_in_iterator, rest_keys} | rest], gas - 1, ctx)
  end

  defp run({:for_in_next, []}, frame, [iter | rest], gas, ctx) do
    run(advance(frame), [true, :undefined, iter | rest], gas - 1, ctx)
  end

  # ── new / constructor ──

  defp run({:call_constructor, [argc]}, frame, stack, gas, ctx) do
    {args, [new_target, ctor | rest]} = Enum.split(stack, argc)
    rev_args = Enum.reverse(args)

    raw_ctor =
      case ctor do
        {:closure, _, %Bytecode.Function{} = f} -> f
        other -> other
      end

    this_ref = make_ref()
    proto = Heap.get_class_proto(raw_ctor)
    init = if proto, do: %{"__proto__" => proto}, else: %{}
    Heap.put_obj(this_ref, init)
    this_obj = {:obj, this_ref}

    ctor_ctx = %{ctx | this: this_obj, new_target: new_target}

    result =
      case ctor do
        %Bytecode.Function{} = f ->
          do_invoke(f, rev_args, ctor_var_refs(f), gas, ctor_ctx)

        {:closure, captured, %Bytecode.Function{} = f} ->
          do_invoke(f, rev_args, ctor_var_refs(f, captured), gas, ctor_ctx)

        {:builtin, name, cb} when is_function(cb, 1) ->
          obj = cb.(rev_args)

          if name in ~w(Error TypeError RangeError SyntaxError ReferenceError URIError EvalError) do
            case obj do
              {:obj, ref} ->
                existing = Heap.get_obj(ref, %{})

                if is_map(existing) and not Map.has_key?(existing, "name") do
                  Heap.put_obj(ref, Map.put(existing, "name", name))
                end

              _ ->
                :ok
            end
          end

          obj

        _ ->
          this_obj
      end

    result =
      case result do
        {:obj, _} = obj -> obj
        _ -> this_obj
      end

    case {result, Heap.get_class_proto(raw_ctor)} do
      {{:obj, rref}, {:obj, _} = proto2} ->
        rmap = Heap.get_obj(rref, %{})

        unless Map.has_key?(rmap, "__proto__") do
          Heap.put_obj(rref, Map.put(rmap, "__proto__", proto2))
        end

      _ ->
        :ok
    end

    run(advance(frame), [result | rest], gas - 1, ctx)
  end

  defp run({:init_ctor, []}, frame, stack, gas, %Ctx{arg_buf: arg_buf} = ctx) do
    raw =
      case ctx.current_func do
        {:closure, _, %Bytecode.Function{} = f} -> f
        %Bytecode.Function{} = f -> f
        other -> other
      end

    parent = Heap.get_parent_ctor(raw)
    args = Tuple.to_list(arg_buf)

    result =
      case parent do
        nil ->
          ctx.this

        %Bytecode.Function{} = f ->
          do_invoke(f, args, ctor_var_refs(f), gas, ctx)

        {:closure, captured, %Bytecode.Function{} = f} ->
          do_invoke(f, args, ctor_var_refs(f, captured), gas, ctx)

        {:builtin, _name, cb} when is_function(cb, 1) ->
          cb.(args)

        _ ->
          ctx.this
      end

    result =
      case result do
        {:obj, _} = obj -> obj
        _ -> ctx.this
      end

    run(advance(frame), [result | stack], gas - 1, %{ctx | this: result})
  end

  # ── instanceof ──

  defp run({:instanceof, []}, frame, [ctor, obj | rest], gas, ctx) do
    result =
      case obj do
        {:obj, _} ->
          ctor_proto = Runtime.get_property(ctor, "prototype")
          check_prototype_chain(obj, ctor_proto)

        _ ->
          false
      end

    run(advance(frame), [result | rest], gas - 1, ctx)
  end

  # ── delete ──

  defp run({:delete, []}, frame, [key, obj | rest], gas, ctx) do
    case obj do
      {:obj, ref} ->
        map = Heap.get_obj(ref, %{})
        if is_map(map), do: Heap.put_obj(ref, Map.delete(map, key))

      _ ->
        :ok
    end

    run(advance(frame), [true | rest], gas - 1, ctx)
  end

  defp run({:delete_var, [_atom_idx]}, frame, stack, gas, ctx),
    do: run(advance(frame), [true | stack], gas - 1, ctx)

  # ── in operator ──

  defp run({:in, []}, frame, [obj, key | rest], gas, ctx) do
    run(advance(frame), [Objects.has_property(obj, key) | rest], gas - 1, ctx)
  end

  # ── regexp literal ──

  defp run({:regexp, []}, frame, [pattern, flags | rest], gas, ctx) do
    run(advance(frame), [{:regexp, pattern, flags} | rest], gas - 1, ctx)
  end

  # ── spread / array construction ──

  defp run({:append, []}, frame, [obj, idx, arr | rest], gas, ctx) do
    src_list =
      case obj do
        list when is_list(list) -> list
        {:obj, ref} -> Heap.get_obj(ref, [])
        _ -> []
      end

    arr_list =
      case arr do
        list when is_list(list) -> list
        {:obj, ref} -> Heap.get_obj(ref, [])
        _ -> []
      end

    merged = arr_list ++ src_list
    new_idx = if(is_integer(idx), do: idx, else: Runtime.to_int(idx)) + length(src_list)

    merged_obj =
      case arr do
        {:obj, ref} ->
          Heap.put_obj(ref, merged)
          {:obj, ref}

        _ ->
          merged
      end

    run(advance(frame), [new_idx, merged_obj | rest], gas - 1, ctx)
  end

  defp run({:define_array_el, []}, frame, [val, idx, obj | rest], gas, ctx) do
    obj2 =
      case obj do
        list when is_list(list) ->
          i = if is_integer(idx), do: idx, else: Runtime.to_int(idx)
          Objects.list_set_at(list, i, val)

        {:obj, ref} ->
          stored = Heap.get_obj(ref, [])

          cond do
            is_list(stored) ->
              i = if is_integer(idx), do: idx, else: Runtime.to_int(idx)
              Heap.put_obj(ref, Objects.list_set_at(stored, i, val))

            is_map(stored) ->
              key =
                case idx do
                  i when is_integer(i) -> Integer.to_string(i)
                  {:symbol, _} = sym -> sym
                  {:symbol, _, _} = sym -> sym
                  s when is_binary(s) -> s
                  other -> Kernel.to_string(other)
                end

              Heap.put_obj_key(ref, key, val)

            true ->
              :ok
          end

          {:obj, ref}

        _ ->
          obj
      end

    run(advance(frame), [idx, obj2 | rest], gas - 1, ctx)
  end

  # ── Closure variable refs (mutable) ──

  defp run({:make_var_ref, [idx]}, frame, stack, gas, ctx) do
    ref = make_ref()
    Heap.put_cell(ref, elem(elem(frame, Frame.locals()), idx))
    run(advance(frame), [{:cell, ref} | stack], gas - 1, ctx)
  end

  defp run({:make_arg_ref, [idx]}, frame, stack, gas, ctx) do
    ref = make_ref()
    Heap.put_cell(ref, Scope.get_arg_value(ctx, idx))
    run(advance(frame), [{:cell, ref} | stack], gas - 1, ctx)
  end

  defp run({:make_loc_ref, [idx]}, frame, stack, gas, ctx) do
    ref = make_ref()
    Heap.put_cell(ref, elem(elem(frame, Frame.locals()), idx))
    run(advance(frame), [{:cell, ref} | stack], gas - 1, ctx)
  end

  defp run({:get_var_ref_check, [idx]}, frame, stack, gas, ctx) do
    case elem(elem(frame, Frame.var_refs()), idx) do
      :undefined -> throw({:error, {:uninitialized_var_ref, idx}})
      {:cell, _} = cell -> run(advance(frame), [Closures.read_cell(cell) | stack], gas - 1, ctx)
      val -> run(advance(frame), [val | stack], gas - 1, ctx)
    end
  end

  defp run({:put_var_ref_check, [idx]}, frame, [val | rest], gas, ctx) do
    case elem(elem(frame, Frame.var_refs()), idx) do
      {:cell, ref} -> Closures.write_cell({:cell, ref}, val)
      _ -> :ok
    end

    run(advance(frame), rest, gas - 1, ctx)
  end

  defp run({:put_var_ref_check_init, [idx]}, frame, [val | rest], gas, ctx) do
    case elem(elem(frame, Frame.var_refs()), idx) do
      {:cell, ref} -> Closures.write_cell({:cell, ref}, val)
      _ -> :ok
    end

    run(advance(frame), rest, gas - 1, ctx)
  end

  defp run({:get_ref_value, []}, frame, [ref | rest], gas, ctx) do
    run(advance(frame), [Closures.read_cell(ref) | rest], gas - 1, ctx)
  end

  defp run({:put_ref_value, []}, frame, [val, {:cell, _} = ref | rest], gas, ctx) do
    Closures.write_cell(ref, val)
    run(advance(frame), [val | rest], gas - 1, ctx)
  end

  defp run({:put_ref_value, []}, frame, [val, key, obj | rest], gas, ctx) when is_binary(key) do
    Objects.put(obj, key, val)
    run(advance(frame), rest, gas - 1, ctx)
  end

  # ── gosub/ret (finally blocks) ──

  defp run({:gosub, [target]}, frame, stack, gas, ctx) do
    run(jump(frame, target), [{:return_addr, elem(frame, Frame.pc()) + 1} | stack], gas - 1, ctx)
  end

  defp run({:ret, []}, frame, [{:return_addr, ret_pc} | rest], gas, ctx) do
    run(jump(frame, ret_pc), rest, gas - 1, ctx)
  end

  # ── eval ──

  defp run({:import, []}, frame, [specifier, _import_meta | rest], gas, ctx) do
    result =
      if is_binary(specifier) and ctx.runtime_pid != nil do
        case QuickBEAM.Runtime.load_module(ctx.runtime_pid, specifier, "") do
          :ok ->
            # Module loaded — create a module namespace object
            # For now, return an empty object (module exports would need linking)
            make_resolved_promise(Runtime.obj_new())

          {:error, _} ->
            make_rejected_promise(
              make_error_obj("Cannot find module '#{specifier}'", "TypeError")
            )
        end
      else
        make_rejected_promise(make_error_obj("Invalid module specifier", "TypeError"))
      end

    run(advance(frame), [result | rest], gas - 1, ctx)
  end

  defp run({:eval, [argc | _]}, frame, stack, gas, ctx) do
    {args, rest} = Enum.split(stack, argc)
    code = List.first(Enum.reverse(args), :undefined)

    result =
      if is_binary(code) and ctx.runtime_pid != nil do
        eval_code(code, frame, gas, ctx)
      else
        :undefined
      end

    run(advance(frame), [result | rest], gas - 1, ctx)
  end

  # ── Iterators ──

  defp run({:for_of_start, []}, frame, [obj | rest], gas, ctx) do
    {iter_obj, next_fn} =
      case obj do
        list when is_list(list) ->
          make_list_iterator(list)

        {:obj, ref} ->
          stored = Heap.get_obj(ref, [])

          case stored do
            list when is_list(list) ->
              make_list_iterator(list)

            map when is_map(map) ->
              sym_iter = {:symbol, "Symbol.iterator"}

              cond do
                Map.has_key?(map, sym_iter) ->
                  iter_fn = Map.get(map, sym_iter)
                  iter_obj = Runtime.call_builtin_callback(iter_fn, [], :no_interp)
                  {iter_obj, Runtime.get_property(iter_obj, "next")}

                Map.has_key?(map, "next") ->
                  {obj, Runtime.get_property(obj, "next")}

                true ->
                  make_list_iterator([])
              end

            _ ->
              make_list_iterator([])
          end

        s when is_binary(s) ->
          make_list_iterator(String.codepoints(s))

        _ ->
          make_list_iterator([])
      end

    run(advance(frame), [0, next_fn, iter_obj | rest], gas - 1, ctx)
  end

  defp run({:for_of_next, [idx]}, frame, stack, gas, ctx) do
    offset = 3 + idx
    iter_obj = Enum.at(stack, offset - 1)
    next_fn = Enum.at(stack, offset - 2)

    if iter_obj == :undefined do
      run(advance(frame), [true, :undefined | stack], gas - 1, ctx)
    else
      result = Runtime.call_builtin_callback(next_fn, [], :no_interp)
      done = Runtime.get_property(result, "done")
      value = Runtime.get_property(result, "value")

      if done == true do
        cleared = List.replace_at(stack, offset - 1, :undefined)
        run(advance(frame), [true, :undefined | cleared], gas - 1, ctx)
      else
        run(advance(frame), [false, value | stack], gas - 1, ctx)
      end
    end
  end

  # iterator_next: stack is [val, catch_offset, next_fn, iter_obj | rest]
  # Calls next_fn(iter_obj, val), replaces val (top) with raw result object
  defp run({:iterator_next, []}, frame, [val, catch_offset, next_fn, iter_obj | rest], gas, ctx) do
    result = Runtime.call_builtin_callback(next_fn, [val], :no_interp)
    run(advance(frame), [result, catch_offset, next_fn, iter_obj | rest], gas - 1, ctx)
  end

  defp run({:iterator_get_value_done, []}, frame, [result | rest], gas, ctx) do
    done = Runtime.get_property(result, "done")
    value = Runtime.get_property(result, "value")

    if done == true do
      run(advance(frame), [true, :undefined | rest], gas - 1, ctx)
    else
      run(advance(frame), [false, value | rest], gas - 1, ctx)
    end
  end

  defp run({:iterator_close, []}, frame, [_catch_offset, _next_fn, iter_obj | rest], gas, ctx) do
    if iter_obj != :undefined do
      return_fn = Runtime.get_property(iter_obj, "return")

      if return_fn != :undefined and return_fn != nil do
        Runtime.call_builtin_callback(return_fn, [], :no_interp)
      end
    end

    run(advance(frame), rest, gas - 1, ctx)
  end

  defp run({:iterator_check_object, []}, frame, stack, gas, ctx),
    do: run(advance(frame), stack, gas - 1, ctx)

  defp run({:iterator_call, [flags]}, frame, stack, gas, ctx) do
    [_val, _catch_offset, _next_fn, iter_obj | _] = stack
    method_name = if Bitwise.band(flags, 1) == 1, do: "throw", else: "return"
    method = Runtime.get_property(iter_obj, method_name)

    if method == :undefined or method == nil do
      run(advance(frame), [true | stack], gas - 1, ctx)
    else
      result =
        if Bitwise.band(flags, 2) == 2 do
          Runtime.call_builtin_callback(method, [], :no_interp)
        else
          [val | _] = stack
          Runtime.call_builtin_callback(method, [val], :no_interp)
        end

      [_ | rest] = stack
      run(advance(frame), [false, result | rest], gas - 1, ctx)
    end
  end

  defp run({:iterator_call, []}, frame, stack, gas, ctx),
    do: run(advance(frame), stack, gas - 1, ctx)

  # ── Misc stubs ──

  defp run({:put_arg, [idx]}, frame, [val | rest], gas, %Ctx{arg_buf: arg_buf} = ctx) do
    padded = Tuple.to_list(arg_buf)

    padded =
      if idx < length(padded),
        do: padded,
        else: padded ++ List.duplicate(:undefined, idx + 1 - length(padded))

    ctx = %{ctx | arg_buf: List.to_tuple(List.replace_at(padded, idx, val))}
    run(advance(frame), rest, gas - 1, ctx)
  end

  defp run({:set_home_object, []}, frame, stack, gas, ctx),
    do: run(advance(frame), stack, gas - 1, ctx)

  defp run({:set_proto, []}, frame, stack, gas, ctx), do: run(advance(frame), stack, gas - 1, ctx)

  defp run(
         {:special_object, [type]},
         frame,
         stack,
         gas,
         %Ctx{arg_buf: arg_buf, current_func: current_func} = ctx
       ) do
    val =
      case type do
        1 ->
          args_list = Tuple.to_list(arg_buf)
          ref = make_ref()
          Heap.put_obj(ref, args_list)
          {:obj, ref}

        2 ->
          current_func

        3 ->
          ctx.new_target

        4 ->
          case ctx.this do
            {:obj, ref} ->
              case Heap.get_obj(ref, %{}) do
                %{"__proto__" => proto} -> proto
                _ -> :undefined
              end

            _ ->
              :undefined
          end

        _ ->
          :undefined
      end

    run(advance(frame), [val | stack], gas - 1, ctx)
  end

  defp run({:rest, [start_idx]}, frame, stack, gas, %Ctx{arg_buf: arg_buf} = ctx) do
    rest_args =
      if start_idx < tuple_size(arg_buf) do
        Tuple.to_list(arg_buf) |> Enum.drop(start_idx)
      else
        []
      end

    ref = make_ref()
    Heap.put_obj(ref, rest_args)
    run(advance(frame), [{:obj, ref} | stack], gas - 1, ctx)
  end

  defp run({:typeof_is_function, [_atom_idx]}, frame, stack, gas, ctx),
    do: run(advance(frame), [false | stack], gas - 1, ctx)

  defp run({:typeof_is_undefined, [_atom_idx]}, frame, stack, gas, ctx),
    do: run(advance(frame), [false | stack], gas - 1, ctx)

  defp run({:throw_error, []}, _frame, [val | _], _gas, _ctx), do: throw({:js_throw, val})

  defp run({:set_name_computed, []}, frame, stack, gas, ctx),
    do: run(advance(frame), stack, gas - 1, ctx)

  defp run({:copy_data_properties, []}, frame, stack, gas, ctx),
    do: run(advance(frame), stack, gas - 1, ctx)

  defp run({:get_super, []}, frame, [func | rest], gas, ctx) do
    parent =
      case func do
        {:obj, ref} ->
          case Heap.get_obj(ref, %{}) do
            map when is_map(map) -> Map.get(map, "__proto__", :undefined)
            _ -> :undefined
          end

        {:closure, _, %Bytecode.Function{} = f} ->
          Heap.get_parent_ctor(f) || :undefined

        %Bytecode.Function{} = f ->
          Heap.get_parent_ctor(f) || :undefined

        _ ->
          :undefined
      end

    run(advance(frame), [parent | rest], gas - 1, ctx)
  end

  defp run({:push_this, []}, frame, stack, gas, %Ctx{this: this} = ctx) do
    run(advance(frame), [this | stack], gas - 1, ctx)
  end

  defp run({:private_symbol, [atom_idx]}, frame, stack, gas, ctx) do
    name = Scope.resolve_atom(ctx, atom_idx)
    run(advance(frame), [{:private_symbol, name, make_ref()} | stack], gas - 1, ctx)
  end

  # ── Argument mutation ──

  defp run({:set_arg, [idx]}, frame, [val | rest], gas, %Ctx{arg_buf: arg_buf} = ctx) do
    list = Tuple.to_list(arg_buf)

    padded =
      if idx < length(list),
        do: list,
        else: list ++ List.duplicate(:undefined, idx + 1 - length(list))

    ctx = %{ctx | arg_buf: List.to_tuple(List.replace_at(padded, idx, val))}
    run(advance(frame), [val | rest], gas - 1, ctx)
  end

  defp run({:set_arg0, []}, frame, [val | rest], gas, %Ctx{arg_buf: arg_buf} = ctx) do
    run(advance(frame), [val | rest], gas - 1, %{ctx | arg_buf: put_elem(arg_buf, 0, val)})
  end

  defp run({:set_arg1, []}, frame, [val | rest], gas, %Ctx{arg_buf: arg_buf} = ctx) do
    ctx = if tuple_size(arg_buf) > 1, do: %{ctx | arg_buf: put_elem(arg_buf, 1, val)}, else: ctx
    run(advance(frame), [val | rest], gas - 1, ctx)
  end

  defp run({:set_arg2, []}, frame, [val | rest], gas, %Ctx{arg_buf: arg_buf} = ctx) do
    ctx = if tuple_size(arg_buf) > 2, do: %{ctx | arg_buf: put_elem(arg_buf, 2, val)}, else: ctx
    run(advance(frame), [val | rest], gas - 1, ctx)
  end

  defp run({:set_arg3, []}, frame, [val | rest], gas, %Ctx{arg_buf: arg_buf} = ctx) do
    ctx = if tuple_size(arg_buf) > 3, do: %{ctx | arg_buf: put_elem(arg_buf, 3, val)}, else: ctx
    run(advance(frame), [val | rest], gas - 1, ctx)
  end

  # ── Array element access (2-element push) ──

  defp run({:get_array_el2, []}, frame, [idx, obj | rest], gas, ctx) do
    run(advance(frame), [Runtime.get_property(obj, idx), obj | rest], gas - 1, ctx)
  end

  # ── Spread/rest via apply ──

  defp run({:apply, [_magic]}, frame, [arg_array, this_obj, fun | rest], gas, ctx) do
    args =
      case arg_array do
        list when is_list(list) ->
          list

        {:obj, ref} ->
          stored = Heap.get_obj(ref, [])
          if is_list(stored), do: stored, else: []

        _ ->
          []
      end

    apply_ctx = %{ctx | this: this_obj}

    result =
      case fun do
        %Bytecode.Function{} = f -> invoke_function(f, args, gas, apply_ctx)
        {:closure, _, %Bytecode.Function{}} = c -> invoke_closure(c, args, gas, apply_ctx)
        {:builtin, _name, cb} when is_function(cb, 2) -> cb.(args, this_obj)
        {:builtin, _name, cb} when is_function(cb, 3) -> cb.(args, this_obj, self())
        {:builtin, _name, cb} when is_function(cb, 1) -> cb.(args)
        f when is_function(f) -> apply(f, [this_obj | args])
        _ -> throw({:js_throw, make_error_obj("not a function", "TypeError")})
      end

    run(advance(frame), [result | rest], gas - 1, ctx)
  end

  # ── Object spread (copy_data_properties with mask) ──

  defp run({:copy_data_properties, [mask]}, frame, stack, gas, ctx) do
    target_idx = mask &&& 3
    source_idx = Bitwise.bsr(mask, 2) &&& 7
    target = Enum.at(stack, target_idx)
    source = Enum.at(stack, source_idx)

    src_props =
      case source do
        {:obj, ref} -> Heap.get_obj(ref, %{})
        map when is_map(map) -> map
        _ -> %{}
      end

    case target do
      {:obj, ref} ->
        existing = Heap.get_obj(ref, %{})
        Heap.put_obj(ref, Map.merge(existing, src_props))

      _ ->
        :ok
    end

    run(advance(frame), stack, gas - 1, ctx)
  end

  # ── Class definitions ──

  defp run({:define_class, [_atom_idx, _flags]}, frame, [ctor, parent_ctor | rest], gas, ctx) do
    locals = elem(frame, Frame.locals())
    vrefs = elem(frame, Frame.var_refs())
    l2v = elem(frame, Frame.l2v())

    ctor_closure =
      case ctor do
        %Bytecode.Function{} = f -> build_closure(f, locals, vrefs, l2v, ctx)
        already_closure -> already_closure
      end

    raw =
      case ctor_closure do
        {:closure, _, %Bytecode.Function{} = f} -> f
        %Bytecode.Function{} = f -> f
        other -> other
      end

    proto_ref = make_ref()
    proto_map = %{"constructor" => ctor_closure}
    parent_proto = Heap.get_class_proto(parent_ctor)

    proto_map =
      if parent_proto, do: Map.put(proto_map, "__proto__", parent_proto), else: proto_map

    Heap.put_obj(proto_ref, proto_map)
    proto = {:obj, proto_ref}
    Heap.put_class_proto(raw, proto)
    Heap.put_ctor_static(ctor_closure, "prototype", proto)

    if parent_ctor != :undefined do
      Heap.put_parent_ctor(raw, parent_ctor)
    end

    run(advance(frame), [proto, ctor_closure | rest], gas - 1, ctx)
  end

  defp run({:add_brand, []}, frame, [obj, brand | rest], gas, ctx) do
    case obj do
      {:obj, ref} ->
        Heap.update_obj(ref, %{}, fn map ->
          brands = Map.get(map, :__brands__, [])
          Map.put(map, :__brands__, [brand | brands])
        end)

      _ ->
        :ok
    end

    run(advance(frame), rest, gas - 1, ctx)
  end

  defp run({:check_brand, []}, frame, [_brand, obj | _] = stack, gas, ctx) do
    # Permissive: verify obj is an object (skip full brand check for perf)
    case obj do
      {:obj, _} -> run(advance(frame), stack, gas - 1, ctx)
      _ -> throw({:js_throw, make_error_obj("invalid brand on object", "TypeError")})
    end
  end

  defp run(
         {:define_class_computed, [atom_idx, flags]},
         frame,
         [ctor, parent_ctor, _computed_name | rest],
         gas,
         ctx
       ) do
    run({:define_class, [atom_idx, flags]}, frame, [ctor, parent_ctor | rest], gas, ctx)
  end

  defp run({:define_method, [atom_idx, flags]}, frame, [method_closure, target | rest], gas, ctx) do
    name = Scope.resolve_atom(ctx, atom_idx)
    method_type = Bitwise.band(flags, 3)

    case method_type do
      1 -> Objects.put_getter(target, name, method_closure)
      2 -> Objects.put_setter(target, name, method_closure)
      _ -> Objects.put(target, name, method_closure)
    end

    run(advance(frame), [target | rest], gas - 1, ctx)
  end

  defp run(
         {:define_method_computed, [_flags]},
         frame,
         [method_closure, target, field_name | rest],
         gas,
         ctx
       ) do
    case target do
      {:obj, ref} ->
        proto = Heap.get_obj(ref, %{})
        Heap.put_obj(ref, Map.put(proto, field_name, method_closure))

      _ ->
        :ok
    end

    run(advance(frame), rest, gas - 1, ctx)
  end

  # ── Generators ──

  defp run({:initial_yield, []}, frame, stack, gas, ctx) do
    throw({:generator_yield, :undefined, advance(frame), stack, gas - 1, ctx})
  end

  defp run({:yield, []}, frame, [val | rest], gas, ctx) do
    throw({:generator_yield, val, advance(frame), rest, gas - 1, ctx})
  end

  defp run({:yield_star, []}, frame, [val | rest], gas, ctx) do
    throw({:generator_yield_star, val, advance(frame), rest, gas - 1, ctx})
  end

  defp run({:async_yield_star, []}, frame, [val | rest], gas, ctx) do
    throw({:generator_yield_star, val, advance(frame), rest, gas - 1, ctx})
  end

  defp run({:await, []}, frame, [val | rest], gas, ctx) do
    resolved = resolve_awaited(val)
    run(advance(frame), [resolved | rest], gas - 1, ctx)
  end

  defp run({:return_async, []}, _frame, [val | _], _gas, _ctx) do
    throw({:generator_return, val})
  end

  # ── with statement ──

  defp run({:with_get_var, [atom_idx, target, _is_with]}, frame, [obj | rest], gas, ctx) do
    key = Scope.resolve_atom(ctx, atom_idx)

    if with_has_property?(obj, key) do
      run(jump(frame, target), [Runtime.get_property(obj, key) | rest], gas - 1, ctx)
    else
      run(advance(frame), rest, gas - 1, ctx)
    end
  end

  defp run({:with_put_var, [atom_idx, target, _is_with]}, frame, [obj, val | rest], gas, ctx) do
    key = Scope.resolve_atom(ctx, atom_idx)

    if with_has_property?(obj, key) do
      Objects.put(obj, key, val)
      run(jump(frame, target), rest, gas - 1, ctx)
    else
      run(advance(frame), [val | rest], gas - 1, ctx)
    end
  end

  defp run({:with_delete_var, [atom_idx, target, _is_with]}, frame, [obj | rest], gas, ctx) do
    key = Scope.resolve_atom(ctx, atom_idx)

    if with_has_property?(obj, key) do
      case obj do
        {:obj, ref} -> Heap.update_obj(ref, %{}, &Map.delete(&1, key))
        _ -> :ok
      end

      run(jump(frame, target), [true | rest], gas - 1, ctx)
    else
      run(advance(frame), rest, gas - 1, ctx)
    end
  end

  defp run({:with_make_ref, [atom_idx, target, _is_with]}, frame, [obj | rest], gas, ctx) do
    key = Scope.resolve_atom(ctx, atom_idx)

    if with_has_property?(obj, key) do
      run(jump(frame, target), [key, obj | rest], gas - 1, ctx)
    else
      run(advance(frame), rest, gas - 1, ctx)
    end
  end

  defp run({:with_get_ref, [atom_idx, target, _is_with]}, frame, [obj | rest], gas, ctx) do
    key = Scope.resolve_atom(ctx, atom_idx)

    if with_has_property?(obj, key) do
      run(jump(frame, target), [Runtime.get_property(obj, key), obj | rest], gas - 1, ctx)
    else
      run(advance(frame), rest, gas - 1, ctx)
    end
  end

  defp run({:with_get_ref_undef, [atom_idx, target, _is_with]}, frame, [obj | rest], gas, ctx) do
    key = Scope.resolve_atom(ctx, atom_idx)

    if with_has_property?(obj, key) do
      run(jump(frame, target), [Runtime.get_property(obj, key), :undefined | rest], gas - 1, ctx)
    else
      run(advance(frame), rest, gas - 1, ctx)
    end
  end

  defp run({:for_await_of_start, []}, frame, [obj | rest], gas, ctx) do
    {iter_obj, next_fn} =
      case obj do
        {:obj, ref} ->
          stored = Heap.get_obj(ref, [])

          cond do
            is_list(stored) ->
              pos_ref = make_ref()
              Heap.put_obj(pos_ref, %{pos: 0, list: stored})
              next = {:builtin, "next", fn _, _ -> list_iterator_next(pos_ref) end}
              iter_ref = make_ref()
              Heap.put_obj(iter_ref, %{"next" => next})
              {{:obj, iter_ref}, next}

            is_map(stored) and Map.has_key?(stored, "next") ->
              {obj, Runtime.get_property(obj, "next")}

            true ->
              {obj, :undefined}
          end

        _ ->
          {obj, :undefined}
      end

    run(advance(frame), [0, next_fn, iter_obj | rest], gas - 1, ctx)
  end

  # ── Catch-all for unimplemented opcodes ──

  defp run({name, args}, _frame, _stack, _gas, _ctx) do
    throw({:error, {:unimplemented_opcode, name, args}})
  end

  # ── Tail calls ──

  defp tail_call(stack, argc, gas, ctx) do
    {args, [fun | _rest]} = Enum.split(stack, argc)
    rev_args = Enum.reverse(args)

    case fun do
      %Bytecode.Function{} = f -> invoke_function(f, rev_args, gas, ctx)
      {:closure, _, %Bytecode.Function{}} = c -> invoke_closure(c, rev_args, gas, ctx)
      {:builtin, _name, cb} when is_function(cb, 2) -> cb.(rev_args, nil)
      {:builtin, _name, cb} when is_function(cb, 1) -> cb.(rev_args)
      f when is_function(f) -> apply(f, rev_args)
      _ -> throw({:js_throw, make_error_obj("not a function", "TypeError")})
    end
  end

  defp tail_call_method(stack, argc, gas, ctx) do
    {args, [fun, obj | _rest]} = Enum.split(stack, argc)
    rev_args = Enum.reverse(args)
    method_ctx = %{ctx | this: obj}

    case fun do
      %Bytecode.Function{} = f -> invoke_function(f, rev_args, gas, method_ctx)
      {:closure, _, %Bytecode.Function{}} = c -> invoke_closure(c, rev_args, gas, method_ctx)
      {:builtin, _name, cb} when is_function(cb, 2) -> cb.(rev_args, obj)
      {:builtin, _name, cb} when is_function(cb, 3) -> cb.(rev_args, obj, :no_interp)
      {:builtin, _name, cb} when is_function(cb, 2) -> cb.(rev_args, nil)
      {:builtin, _name, cb} when is_function(cb, 1) -> cb.(rev_args)
      f when is_function(f) -> apply(f, [obj | rev_args])
      _ -> throw({:js_throw, make_error_obj("not a function", "TypeError")})
    end
  end

  # ── Closure construction ──

  defp build_closure(%Bytecode.Function{} = fun, locals, vrefs, l2v, %Ctx{arg_buf: arg_buf}) do
    captured =
      for cv <- fun.closure_vars do
        cell =
          case Map.get(l2v, cv.var_idx) do
            nil ->
              val =
                cond do
                  cv.var_idx < tuple_size(arg_buf) -> elem(arg_buf, cv.var_idx)
                  cv.var_idx < tuple_size(locals) -> elem(locals, cv.var_idx)
                  true -> :undefined
                end

              ref = make_ref()
              Heap.put_cell(ref, val)
              {:cell, ref}

            vref_idx ->
              case elem(vrefs, vref_idx) do
                {:cell, _} = existing ->
                  existing

                _ ->
                  val = elem(locals, cv.var_idx)
                  ref = make_ref()
                  Heap.put_cell(ref, val)
                  {:cell, ref}
              end
          end

        {cv.var_idx, cell}
      end

    {:closure, Map.new(captured), fun}
  end

  defp build_closure(other, _locals, _vrefs, _l2v, _ctx), do: other

  defp ctor_var_refs(%Bytecode.Function{} = f, captured \\ %{}) do
    cell_ref = make_ref()
    Heap.put_cell(cell_ref, false)

    case f.closure_vars do
      [] -> [{:cell, cell_ref}]
      cvs -> Enum.map(cvs, &Map.get(captured, &1.var_idx, {:cell, cell_ref}))
    end
  end

  # ── Function calls ──

  defp call_function(frame, stack, argc, gas, ctx) do
    {args, [fun | rest]} = Enum.split(stack, argc)
    rev_args = Enum.reverse(args)

    catch_js_throw(frame, rest, gas, ctx, fn ->
      case fun do
        %Bytecode.Function{} = f -> invoke_function(f, rev_args, gas, ctx)
        {:closure, _, %Bytecode.Function{}} = c -> invoke_closure(c, rev_args, gas, ctx)
        {:builtin, _name, cb} when is_function(cb, 2) -> cb.(rev_args, nil)
        {:builtin, _name, cb} when is_function(cb, 1) -> cb.(rev_args)
        f when is_function(f) -> apply(f, rev_args)
        _ -> throw({:js_throw, make_error_obj("not a function", "TypeError")})
      end
    end)
  end

  defp call_method(frame, stack, argc, gas, ctx) do
    {args, [fun, obj | rest]} = Enum.split(stack, argc)
    rev_args = Enum.reverse(args)
    method_ctx = %{ctx | this: obj}

    catch_js_throw(frame, rest, gas, ctx, fn ->
      case fun do
        %Bytecode.Function{} = f -> invoke_function(f, rev_args, gas, method_ctx)
        {:closure, _, %Bytecode.Function{}} = c -> invoke_closure(c, rev_args, gas, method_ctx)
        {:builtin, _name, cb} when is_function(cb, 2) -> cb.(rev_args, obj)
        {:builtin, _name, cb} when is_function(cb, 3) -> cb.(rev_args, obj, :no_interp)
        {:builtin, _name, cb} when is_function(cb, 2) -> cb.(rev_args, nil)
        {:builtin, _name, cb} when is_function(cb, 1) -> cb.(rev_args)
        f when is_function(f) -> apply(f, [obj | rev_args])
        _ -> throw({:js_throw, make_error_obj("not a function", "TypeError")})
      end
    end)
  end

  defp invoke_function(%Bytecode.Function{} = fun, args, gas, ctx) do
    do_invoke(fun, args, [], gas, ctx)
  end

  defp invoke_closure({:closure, captured, %Bytecode.Function{} = fun}, args, gas, ctx) do
    var_refs =
      for cv <- fun.closure_vars do
        Map.get(captured, cv.var_idx, :undefined)
      end

    do_invoke(fun, args, var_refs, gas, ctx)
  end

  defp do_invoke(%Bytecode.Function{} = fun, args, var_refs, gas, ctx) do
    self_ref =
      if var_refs != [] or fun.closure_vars != [] do
        {:closure, %{}, fun}
      else
        fun
      end

    insns =
      case Heap.get_decoded(fun.byte_code) do
        nil ->
          case Decoder.decode(fun.byte_code) do
            {:ok, instructions} ->
              t = List.to_tuple(instructions)
              Heap.put_decoded(fun.byte_code, t)
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
            0,
            locals,
            List.to_tuple(fun.constants),
            var_refs_tuple,
            fun.stack_size,
            insns,
            l2v
          )

        inner_ctx = %{ctx | current_func: self_ref, arg_buf: List.to_tuple(args), catch_stack: []}
        prev_ctx = Heap.get_ctx()
        Heap.put_ctx(inner_ctx)

        try do
          case fun.func_kind do
            @func_generator -> invoke_generator(frame, gas, inner_ctx)
            @func_async -> invoke_async(frame, gas, inner_ctx)
            @func_async_generator -> invoke_async_generator(frame, gas, inner_ctx)
            _ -> run(frame, [], gas, inner_ctx)
          end
        after
          if prev_ctx, do: Heap.put_ctx(prev_ctx)
        end
    end
  end

  defp invoke_generator(frame, gas, ctx) do
    gen_ref = make_ref()

    try do
      run(frame, [], gas, ctx)
    catch
      {:generator_yield_star, _val, suspended_frame, suspended_stack, suspended_gas,
       suspended_ctx} ->
        state = %{
          state: :suspended,
          frame: suspended_frame,
          stack: suspended_stack,
          gas: suspended_gas,
          ctx: suspended_ctx
        }

        Heap.put_obj(gen_ref, state)

      {:generator_yield, _val, suspended_frame, suspended_stack, suspended_gas, suspended_ctx} ->
        state = %{
          state: :suspended,
          frame: suspended_frame,
          stack: suspended_stack,
          gas: suspended_gas,
          ctx: suspended_ctx
        }

        Heap.put_obj(gen_ref, state)
    end

    next_fn =
      {:builtin, "next",
       fn
         [arg | _], _this -> generator_next(gen_ref, arg)
         [], _this -> generator_next(gen_ref, :undefined)
       end}

    return_fn =
      {:builtin, "return",
       fn
         [val | _], _this -> generator_return(gen_ref, val)
         [], _this -> generator_return(gen_ref, :undefined)
       end}

    obj_ref = make_ref()

    Heap.put_obj(obj_ref, %{
      "next" => next_fn,
      "return" => return_fn
    })

    {:obj, obj_ref}
  end

  defp invoke_async_generator(frame, gas, ctx) do
    gen_ref = make_ref()

    try do
      run(frame, [], gas, ctx)
    catch
      {:generator_yield, _val, sf, ss, sg, sc} ->
        Heap.put_obj(gen_ref, %{state: :suspended, frame: sf, stack: ss, gas: sg, ctx: sc})
    end

    next_fn =
      {:builtin, "next",
       fn
         [arg | _], _this -> async_generator_next(gen_ref, arg)
         [], _this -> async_generator_next(gen_ref, :undefined)
       end}

    return_fn =
      {:builtin, "return",
       fn
         [val | _], _this -> make_resolved_promise(done_result(val))
         [], _this -> make_resolved_promise(done_result(:undefined))
       end}

    obj_ref = make_ref()
    Heap.put_obj(obj_ref, %{"next" => next_fn, "return" => return_fn})
    {:obj, obj_ref}
  end

  defp async_generator_next(gen_ref, arg) do
    case Heap.get_obj(gen_ref) do
      %{state: :suspended, frame: frame, stack: stack, gas: gas, ctx: ctx} ->
        prev_ctx = Heap.get_ctx()
        Heap.put_ctx(ctx)

        try do
          result = run(frame, [false, arg | stack], gas, ctx)
          Heap.put_obj(gen_ref, %{state: :completed})
          make_resolved_promise(done_result(result))
        catch
          {:generator_yield, val, sf, ss, sg, sc} ->
            Heap.put_obj(gen_ref, %{state: :suspended, frame: sf, stack: ss, gas: sg, ctx: sc})
            make_resolved_promise(yield_result(val))

          {:generator_return, val} ->
            Heap.put_obj(gen_ref, %{state: :completed})
            make_resolved_promise(done_result(val))

          {:js_throw, _} = thrown ->
            Heap.put_obj(gen_ref, %{state: :completed})
            throw(thrown)
        after
          if prev_ctx, do: Heap.put_ctx(prev_ctx)
        end

      _ ->
        make_resolved_promise(done_result(:undefined))
    end
  end

  defp invoke_async(frame, gas, ctx) do
    try do
      result = run(frame, [], gas, ctx)
      make_resolved_promise(result)
    catch
      {:generator_return, val} -> make_resolved_promise(val)
      {:js_throw, val} -> make_rejected_promise(val)
    end
  end

  @doc false
  def make_resolved_promise(val) do
    promise_ref = make_ref()

    Heap.put_obj(promise_ref, %{
      "__promise_state__" => :resolved,
      "__promise_value__" => val,
      "then" => make_then_fn(promise_ref),
      "catch" => make_catch_fn(promise_ref)
    })

    {:obj, promise_ref}
  end

  @doc false
  def make_rejected_promise(val) do
    promise_ref = make_ref()

    Heap.put_obj(promise_ref, %{
      "__promise_state__" => :rejected,
      "__promise_value__" => val,
      "then" => make_then_fn(promise_ref),
      "catch" => make_catch_fn(promise_ref)
    })

    {:obj, promise_ref}
  end

  def make_then_fn(promise_ref) do
    {:builtin, "then",
     fn args, _this ->
       on_fulfilled = Enum.at(args, 0)
       on_rejected = Enum.at(args, 1)

       case Heap.get_obj(promise_ref, %{}) do
         %{"__promise_state__" => :resolved, "__promise_value__" => val} ->
           if on_fulfilled && on_fulfilled != :undefined do
             child_ref = make_ref()

             Heap.put_obj(child_ref, %{
               "__promise_state__" => :pending,
               "then" => make_then_fn(child_ref),
               "catch" => make_catch_fn(child_ref)
             })

             Heap.enqueue_microtask({:resolve, child_ref, on_fulfilled, val})
             {:obj, child_ref}
           else
             make_resolved_promise(val)
           end

         %{"__promise_state__" => :rejected, "__promise_value__" => val} ->
           if on_rejected && on_rejected != :undefined do
             child_ref = make_ref()

             Heap.put_obj(child_ref, %{
               "__promise_state__" => :pending,
               "then" => make_then_fn(child_ref),
               "catch" => make_catch_fn(child_ref)
             })

             Heap.enqueue_microtask({:resolve, child_ref, on_rejected, val})
             {:obj, child_ref}
           else
             make_rejected_promise(val)
           end

         %{"__promise_state__" => :pending} ->
           child_ref = make_ref()

           Heap.put_obj(child_ref, %{
             "__promise_state__" => :pending,
             "then" => make_then_fn(child_ref),
             "catch" => make_catch_fn(child_ref)
           })

           # Queue for when parent resolves
           waiters = Process.get({:qb_promise_waiters, promise_ref}, [])

           Process.put({:qb_promise_waiters, promise_ref}, [
             {on_fulfilled, on_rejected, child_ref} | waiters
           ])

           {:obj, child_ref}

         _ ->
           make_resolved_promise(:undefined)
       end
     end}
  end

  def make_catch_fn(promise_ref) do
    {:builtin, "catch",
     fn args, this ->
       handler = List.first(args)
       then_fn = make_then_fn(promise_ref)

       case then_fn do
         {:builtin, _, cb} -> cb.([nil, handler], this)
       end
     end}
  end

  @doc false
  def drain_microtask_queue do
    case Heap.dequeue_microtask() do
      nil ->
        :ok

      {:resolve, child_ref, callback, val} ->
        result =
          try do
            invoke_callback(callback, [val])
          catch
            {:js_throw, err} -> {:rejected, err}
          end

        case result do
          {:rejected, err} ->
            resolve_promise(child_ref, :rejected, err)

          result_val ->
            # If result is a promise, chain it
            case result_val do
              {:obj, r} ->
                case Heap.get_obj(r, %{}) do
                  %{"__promise_state__" => :resolved, "__promise_value__" => v} ->
                    resolve_promise(child_ref, :resolved, v)

                  %{"__promise_state__" => :rejected, "__promise_value__" => v} ->
                    resolve_promise(child_ref, :rejected, v)

                  %{"__promise_state__" => :pending} ->
                    waiters = Process.get({:qb_promise_waiters, r}, [])

                    Process.put({:qb_promise_waiters, r}, [
                      {fn v -> resolve_promise(child_ref, :resolved, v) end, nil, child_ref}
                      | waiters
                    ])

                  _ ->
                    resolve_promise(child_ref, :resolved, result_val)
                end

              _ ->
                resolve_promise(child_ref, :resolved, result_val)
            end
        end

        drain_microtask_queue()
    end
  end

  def resolve_promise(ref, state, val) do
    Heap.put_obj(ref, %{
      "__promise_state__" => state,
      "__promise_value__" => val,
      "then" => make_then_fn(ref),
      "catch" => make_catch_fn(ref)
    })

    # Notify waiters
    waiters = Process.get({:qb_promise_waiters, ref}, [])
    Process.delete({:qb_promise_waiters, ref})

    for {on_fulfilled, on_rejected, child_ref} <- waiters do
      case state do
        :resolved when on_fulfilled != nil and on_fulfilled != :undefined ->
          Heap.enqueue_microtask({:resolve, child_ref, on_fulfilled, val})

        :rejected when on_rejected != nil and on_rejected != :undefined ->
          Heap.enqueue_microtask({:resolve, child_ref, on_rejected, val})

        :resolved ->
          Heap.enqueue_microtask({:resolve, child_ref, fn v -> v end, val})

        :rejected ->
          Heap.enqueue_microtask({:resolve, child_ref, fn v -> v end, val})
      end
    end
  end

  defp generator_next(gen_ref, arg) do
    case Heap.get_obj(gen_ref) do
      %{state: :suspended, frame: frame, stack: stack, gas: gas, ctx: ctx} ->
        Heap.put_ctx(ctx)

        try do
          # QuickJS yield protocol: [is_return_or_throw, value | saved_stack]
          result = run(frame, [false, arg | stack], gas, ctx)
          Heap.put_obj(gen_ref, %{state: :completed})
          done_result(result)
        catch
          {:generator_yield, val, sf, ss, sg, sc} ->
            Heap.put_obj(gen_ref, %{state: :suspended, frame: sf, stack: ss, gas: sg, ctx: sc})
            yield_result(val)

          {:generator_yield_star, val, sf, ss, sg, sc} ->
            Heap.put_obj(gen_ref, %{state: :suspended, frame: sf, stack: ss, gas: sg, ctx: sc})
            val

          {:generator_return, val} ->
            Heap.put_obj(gen_ref, %{state: :completed})
            done_result(val)

          {:js_throw, _} = thrown ->
            Heap.put_obj(gen_ref, %{state: :completed})
            throw(thrown)
        end

      _ ->
        done_result(:undefined)
    end
  end

  defp generator_return(gen_ref, val) do
    Heap.put_obj(gen_ref, %{state: :completed})
    done_result(val)
  end

  defp yield_result(val) do
    ref = make_ref()
    Heap.put_obj(ref, %{"value" => val, "done" => false})
    {:obj, ref}
  end

  defp done_result(val) do
    ref = make_ref()
    Heap.put_obj(ref, %{"value" => val, "done" => true})
    {:obj, ref}
  end
end
