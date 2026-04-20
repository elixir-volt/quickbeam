defmodule QuickBEAM.BeamVM.Interpreter do
  import Bitwise, only: [bnot: 1, &&&: 2]
  import QuickBEAM.BeamVM.Heap.Keys

  alias QuickBEAM.BeamVM.{Builtin, Bytecode, Decoder, Heap, PredefinedAtoms, Runtime}
  alias QuickBEAM.BeamVM.Runtime.Property
  alias __MODULE__.{Closures, Context, Frame, Generator, Objects, Promise, Scope, Values}

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
            active_ctx: 0,
            list_iterator_next: 1,
            make_list_iterator: 1,
            with_has_property?: 2,
            check_prototype_chain: 2}

  @op_invalid 0
  @op_push_i32 1
  @op_push_const 2
  @op_fclosure 3
  @op_push_atom_value 4
  @op_private_symbol 5
  @op_undefined 6
  @op_null 7
  @op_push_this 8
  @op_push_false 9
  @op_push_true 10
  @op_object 11
  @op_special_object 12
  @op_rest 13
  @op_drop 14
  @op_nip 15
  @op_nip1 16
  @op_dup 17
  @op_dup1 18
  @op_dup2 19
  @op_dup3 20
  @op_insert2 21
  @op_insert3 22
  @op_insert4 23
  @op_perm3 24
  @op_perm4 25
  @op_perm5 26
  @op_swap 27
  @op_swap2 28
  @op_rot3l 29
  @op_rot3r 30
  @op_rot4l 31
  @op_rot5l 32
  @op_call_constructor 33
  @op_call 34
  @op_tail_call 35
  @op_call_method 36
  @op_tail_call_method 37
  @op_array_from 38
  @op_apply 39
  @op_return 40
  @op_return_undef 41
  @op_check_ctor_return 42
  @op_check_ctor 43
  @op_init_ctor 44
  @op_check_brand 45
  @op_add_brand 46
  @op_return_async 47
  @op_throw 48
  @op_throw_error 49
  @op_eval 50
  @op_apply_eval 51
  @op_regexp 52
  @op_get_super 53
  @op_import 54
  @op_get_var_undef 55
  @op_get_var 56
  @op_put_var 57
  @op_put_var_init 58
  @op_get_ref_value 59
  @op_put_ref_value 60
  @op_define_var 61
  @op_check_define_var 62
  @op_define_func 63
  @op_get_field 64
  @op_get_field2 65
  @op_put_field 66
  @op_get_private_field 67
  @op_put_private_field 68
  @op_define_private_field 69
  @op_get_array_el 70
  @op_get_array_el2 71
  @op_put_array_el 72
  @op_get_super_value 73
  @op_put_super_value 74
  @op_define_field 75
  @op_set_name 76
  @op_set_name_computed 77
  @op_set_proto 78
  @op_set_home_object 79
  @op_define_array_el 80
  @op_append 81
  @op_copy_data_properties 82
  @op_define_method 83
  @op_define_method_computed 84
  @op_define_class 85
  @op_define_class_computed 86
  @op_get_loc 87
  @op_put_loc 88
  @op_set_loc 89
  @op_get_arg 90
  @op_put_arg 91
  @op_set_arg 92
  @op_get_var_ref 93
  @op_put_var_ref 94
  @op_set_var_ref 95
  @op_set_loc_uninitialized 96
  @op_get_loc_check 97
  @op_put_loc_check 98
  @op_put_loc_check_init 99
  @op_get_var_ref_check 100
  @op_put_var_ref_check 101
  @op_put_var_ref_check_init 102
  @op_close_loc 103
  @op_if_false 104
  @op_if_true 105
  @op_goto 106
  @op_catch 107
  @op_gosub 108
  @op_ret 109
  @op_nip_catch 110
  @op_to_object 111
  @op_to_propkey 112
  @op_to_propkey2 113
  @op_with_get_var 114
  @op_with_put_var 115
  @op_with_delete_var 116
  @op_with_make_ref 117
  @op_with_get_ref 118
  @op_with_get_ref_undef 119
  @op_make_loc_ref 120
  @op_make_arg_ref 121
  @op_make_var_ref 123
  @op_for_in_start 124
  @op_for_of_start 125
  @op_for_await_of_start 126
  @op_for_in_next 127
  @op_for_of_next 128
  @op_iterator_check_object 129
  @op_iterator_get_value_done 130
  @op_iterator_close 131
  @op_iterator_next 132
  @op_iterator_call 133
  @op_initial_yield 134
  @op_yield 135
  @op_yield_star 136
  @op_async_yield_star 137
  @op_await 138
  @op_neg 139
  @op_plus 140
  @op_dec 141
  @op_inc 142
  @op_post_dec 143
  @op_post_inc 144
  @op_dec_loc 145
  @op_inc_loc 146
  @op_add_loc 147
  @op_not 148
  @op_lnot 149
  @op_typeof 150
  @op_delete 151
  @op_delete_var 152
  @op_mul 153
  @op_div 154
  @op_mod 155
  @op_add 156
  @op_sub 157
  @op_shl 158
  @op_sar 159
  @op_shr 160
  @op_band 161
  @op_bxor 162
  @op_bor 163
  @op_pow 164
  @op_lt 165
  @op_lte 166
  @op_gt 167
  @op_gte 168
  @op_instanceof 169
  @op_in 170
  @op_eq 171
  @op_neq 172
  @op_strict_eq 173
  @op_strict_neq 174
  @op_is_undefined_or_null 175
  @op_private_in 176
  @op_push_bigint_i32 177
  @op_nop 178
  @op_push_minus1 179
  @op_push_0 180
  @op_push_1 181
  @op_push_2 182
  @op_push_3 183
  @op_push_4 184
  @op_push_5 185
  @op_push_6 186
  @op_push_7 187
  @op_push_i8 188
  @op_push_i16 189
  @op_push_const8 190
  @op_fclosure8 191
  @op_push_empty_string 192
  @op_get_loc8 193
  @op_put_loc8 194
  @op_set_loc8 195
  @op_get_loc0_loc1 196
  @op_get_loc0 197
  @op_get_loc1 198
  @op_get_loc2 199
  @op_get_loc3 200
  @op_put_loc0 201
  @op_put_loc1 202
  @op_put_loc2 203
  @op_put_loc3 204
  @op_set_loc0 205
  @op_set_loc1 206
  @op_set_loc2 207
  @op_set_loc3 208
  @op_get_arg0 209
  @op_get_arg1 210
  @op_get_arg2 211
  @op_get_arg3 212
  @op_put_arg0 213
  @op_put_arg1 214
  @op_put_arg2 215
  @op_put_arg3 216
  @op_set_arg0 217
  @op_set_arg1 218
  @op_set_arg2 219
  @op_set_arg3 220
  @op_get_var_ref0 221
  @op_get_var_ref1 222
  @op_get_var_ref2 223
  @op_get_var_ref3 224
  @op_put_var_ref0 225
  @op_put_var_ref1 226
  @op_put_var_ref2 227
  @op_put_var_ref3 228
  @op_set_var_ref0 229
  @op_set_var_ref1 230
  @op_set_var_ref2 231
  @op_set_var_ref3 232
  @op_get_length 233
  @op_if_false8 234
  @op_if_true8 235
  @op_goto8 236
  @op_goto16 237
  @op_call0 238
  @op_call1 239
  @op_call2 240
  @op_call3 241
  @op_is_undefined 242
  @op_is_null 243
  @op_typeof_is_undefined 244
  @op_typeof_is_function 245

  @func_generator 1
  @func_async 2
  @func_async_generator 3
  @gc_check_interval 1000

  defp check_gas(_pc, frame, stack, gas, ctx) do
    gas = gas - 1

    if gas <= 0 do
      throw({:error, {:out_of_gas, gas}})
    end

    if rem(gas, @gc_check_interval) == 0 and Heap.gc_needed?() do
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

    gas
  end

  @spec eval(Bytecode.Function.t()) :: {:ok, term()} | {:error, term()}
  def eval(%Bytecode.Function{} = fun), do: eval(fun, [], %{})

  @spec eval(Bytecode.Function.t(), [term()], map()) :: {:ok, term()} | {:error, term()}
  def eval(%Bytecode.Function{} = fun, args, opts), do: eval(fun, args, opts, {})

  @spec eval(Bytecode.Function.t(), [term()], map(), tuple()) :: {:ok, term()} | {:error, term()}
  def eval(%Bytecode.Function{} = fun, args, opts, atoms) do
    gas = Map.get(opts, :gas, Context.default_gas())

    persistent = Heap.get_persistent_globals()

    ctx = %Context{
      atoms: atoms,
      gas: gas,
      globals:
        Runtime.global_bindings()
        |> Map.merge(persistent)
        |> Map.merge(Map.get(opts, :globals, %{})),
      runtime_pid: Map.get(opts, :runtime_pid),
      this: Map.get(opts, :this, :undefined),
      arg_buf: Map.get(opts, :arg_buf, {}),
      current_func: Map.get(opts, :current_func, :undefined),
      new_target: Map.get(opts, :new_target, :undefined)
    }

    Heap.put_atoms(atoms)
    store_function_atoms(fun, atoms)
    prev_ctx = Heap.get_ctx()
    Heap.put_ctx(ctx)

    try do
      case Decoder.decode(fun.byte_code, fun.arg_count) do
        {:ok, instructions} ->
          instructions = List.to_tuple(instructions)
          locals = :erlang.make_tuple(max(fun.arg_count + fun.var_count, 1), :undefined)

          frame =
            Frame.new(
              locals,
              List.to_tuple(fun.constants),
              {},
              fun.stack_size,
              instructions,
              %{}
            )

          push_active_frame(fun)

          try do
            result = run(0, frame, args, gas, ctx)
            Promise.drain_microtasks()
            {:ok, unwrap_promise(result)}
          catch
            {:js_throw, val} -> {:error, {:js_throw, val}}
            {:error, _} = err -> err
          after
            pop_active_frame()
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

  def invoke(other, args, _gas) when not is_tuple(other) or elem(other, 0) != :bound,
    do: Builtin.call(other, args, nil)

  def invoke({:bound, _, inner, _, _}, args, gas), do: invoke(inner, args, gas)

  @doc """
  Invokes a JS function with a specific `this` receiver.
  """
  def invoke_with_receiver(fun, args, gas, this_obj) do
    prev = Heap.get_ctx()
    Heap.put_ctx(%{active_ctx() | this: this_obj})

    try do
      invoke(fun, args, gas)
    after
      if prev, do: Heap.put_ctx(prev)
    end
  end

  defp store_function_atoms(%Bytecode.Function{} = fun, atoms) do
    Process.put({:qb_fn_atoms, fun.byte_code}, atoms)

    for %Bytecode.Function{} = inner <- fun.constants do
      store_function_atoms(inner, atoms)
    end

    :ok
  end

  defp store_function_atoms(_, _), do: :ok

  defp active_ctx do
    case Heap.get_ctx() do
      nil ->
        atoms = Heap.get_atoms()
        %Context{atoms: atoms}

      ctx ->
        ctx
    end
  end

  defp catch_js_throw(pc, frame, rest, gas, ctx, fun) do
    result = fun.()
    run(pc + 1, frame, [result | rest], gas, ctx)
  catch
    {:js_throw, val} -> throw_or_catch(frame, val, gas, ctx)
  end

  defp catch_js_throw_refresh_globals(pc, frame, rest, gas, ctx, fun) do
    result = fun.()
    persistent = Heap.get_persistent_globals() || %{}
    run(pc + 1, frame, [result | rest], gas, %{ctx | globals: Map.merge(ctx.globals, persistent)})
  catch
    {:js_throw, val} -> throw_or_catch(frame, val, gas, ctx)
  end

  defp push_active_frame(fun) do
    Process.put(:qb_active_frames, [%{fun: fun, pc: 0} | Process.get(:qb_active_frames, [])])
  end

  defp pop_active_frame do
    case Process.get(:qb_active_frames, []) do
      [_ | rest] -> Process.put(:qb_active_frames, rest)
      [] -> :ok
    end
  end

  defp update_active_frame_pc(pc) do
    case Process.get(:qb_active_frames, []) do
      [frame | rest] -> Process.put(:qb_active_frames, [%{frame | pc: pc} | rest])
      [] -> :ok
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

  defp resolve_local_name(name) when is_binary(name), do: name
  defp resolve_local_name({:predefined, idx}), do: PredefinedAtoms.lookup(idx)
  defp resolve_local_name(_), do: nil

  defp caller_is_strict?(%Context{current_func: func}) do
    case func do
      {:closure, _, %Bytecode.Function{is_strict_mode: s}} -> s
      %Bytecode.Function{is_strict_mode: s} -> s
      _ -> false
    end
  end

  defp home_object_key({:closure, _, %Bytecode.Function{byte_code: bc}}), do: bc
  defp home_object_key(%Bytecode.Function{byte_code: bc}), do: bc
  defp home_object_key(_), do: nil

  defp current_func_name(%Context{current_func: func}) do
    case func do
      {:closure, _, %Bytecode.Function{name: n}} -> n
      %Bytecode.Function{name: n} -> n
      _ -> nil
    end
  end

  defp set_function_name({:closure, captured, %Bytecode.Function{} = f}, name),
    do: {:closure, captured, %{f | name: name}}

  defp set_function_name(%Bytecode.Function{} = f, name),
    do: %{f | name: name}

  defp set_function_name({:builtin, _, cb}, name),
    do: {:builtin, name, cb}

  defp set_function_name(other, _name), do: other

  defp put_local(f, idx, val),
    do: put_elem(f, Frame.locals(), put_elem(elem(f, Frame.locals()), idx, val))

  defp collect_proto_keys(nil, acc), do: acc
  defp collect_proto_keys(:undefined, acc), do: acc

  defp collect_proto_keys({:obj, ref}, acc) do
    case Heap.get_obj(ref, %{}) do
      map when is_map(map) ->
        keys =
          Map.keys(map)
          |> Enum.filter(&is_binary/1)
          |> Enum.reject(fn k ->
            k == "constructor" or String.starts_with?(k, "__") or k in acc or
              match?(%{enumerable: false}, Heap.get_prop_desc(ref, k))
          end)

        collect_proto_keys(Map.get(map, proto()), acc ++ keys)

      _ ->
        acc
    end
  end

  defp collect_proto_keys(_, acc), do: acc

  defp throw_or_catch(frame, error, gas, ctx) do
    case ctx.catch_stack do
      [{target, saved_stack} | rest_catch] ->
        run(target, frame, [error | saved_stack], gas, %{ctx | catch_stack: rest_catch})

      [] ->
        throw({:js_throw, error})
    end
  end

  defp set_private_field({:obj, ref}, key, val),
    do: Heap.update_obj(ref, %{}, &Map.put(&1, {:private, key}, val))

  defp set_private_field(_, _, _), do: :ok

  defp throw_null_property_error(frame, obj, atom_idx, gas, ctx) do
    prop = Scope.resolve_atom(ctx, atom_idx)
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

  defp resolve_awaited({:obj, ref} = obj) do
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

  defp resolve_awaited(val), do: val

  defp list_iterator_next(pos_ref) do
    state = Heap.get_obj(pos_ref, %{pos: 0, list: []})

    if state.pos < length(state.list) do
      val = Enum.at(state.list, state.pos)
      Heap.put_obj(pos_ref, %{state | pos: state.pos + 1})
      Heap.wrap(%{"value" => val, "done" => false})
    else
      Heap.wrap(%{"value" => :undefined, "done" => true})
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

  defp eval_code(code, caller_frame, gas, ctx, var_objs, keep_declared? \\ false) do
    with {:ok, bc} <- QuickBEAM.Runtime.compile(ctx.runtime_pid, code),
         {:ok, parsed} <- Bytecode.decode(bc) do
      declared_names = eval_declared_names(parsed.value)
      eval_globals = collect_caller_locals(caller_frame, ctx)
      captured_globals = collect_captured_globals(ctx.current_func)
      eval_scope_globals = merge_var_object_globals(Map.merge(eval_globals, captured_globals), var_objs)

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

      case __MODULE__.eval(parsed.value, [], eval_opts, parsed.atoms) do
        {:ok, val} ->
          post_eval_globals = Heap.get_persistent_globals() || %{}

          transient_globals =
            if keep_declared?, do: Map.take(post_eval_globals, MapSet.to_list(declared_names)), else: %{}

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
      {:error, %{message: msg}} -> throw({:js_throw, Heap.make_error(msg, "SyntaxError")})
      {:error, msg} when is_binary(msg) -> throw({:js_throw, Heap.make_error(msg, "SyntaxError")})
      _ -> {:undefined, %{}}
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
      case resolve_local_name(cv.name) do
        name when is_binary(name) ->
          val =
            case Map.get(captured, closure_capture_key(cv), :undefined) do
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

  defp write_back_eval_vars(caller_frame, ctx, original_globals, var_objs, declared_names \\ MapSet.new()) do
    new_globals = Heap.get_persistent_globals() || %{}

    if caller_is_strict?(ctx) do
      func_name = current_func_name(ctx)

      if func_name && Map.has_key?(new_globals, func_name) do
        old_val =
          case ctx.current_func do
            {:closure, _, %Bytecode.Function{} = f} -> Heap.get_parent_ctor(f)
            _ -> nil
          end

        new_val = Map.get(new_globals, func_name)

        if old_val == nil and new_val != ctx.current_func and new_val != :undefined do
          throw({:js_throw, Heap.make_error("Assignment to constant variable.", "TypeError")})
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

    if match?({:closure, _, %Bytecode.Function{}}, ctx.current_func) do
      write_back_captured_vars(ctx.current_func, new_globals, original_globals, declared_names)
    end

    if var_objs != [] do
      for {name, val} <- new_globals,
          is_binary(name),
          not MapSet.member?(declared_names, name),
          Map.has_key?(original_globals, name),
          Map.get(original_globals, name) != val do
        for var_obj <- var_objs, do: Objects.put(var_obj, name, val)
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
        name = resolve_local_name(cv.name),
        is_binary(name),
        not MapSet.member?(declared_names, name),
        Map.has_key?(new_globals, name),
        Map.get(original_globals, name) != Map.get(new_globals, name) do
      case Map.get(captured, closure_capture_key(cv)) do
        {:cell, ref} -> Heap.put_cell(ref, Map.get(new_globals, name))
        _ -> :ok
      end
    end
  end

  defp write_back_captured_vars(_, _, _, _), do: :ok

  defp eval_declared_names(%Bytecode.Function{locals: locals}) do
    locals
    |> Enum.map(&resolve_local_name(&1.name))
    |> Enum.filter(&is_binary/1)
    |> MapSet.new()
  end

  defp eval_declared_names(_), do: MapSet.new()

  defp do_write_back(local_defs, vrefs, l2v, new_globals, ctx, original_globals, declared_names) do
    func_name = current_func_name(ctx)

    for {vd, idx} <- Enum.with_index(local_defs),
        name = resolve_local_name(vd.name),
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
    next_fn = Property.get(iter_obj, "next")

    case Runtime.call_callback(next_fn, []) do
      {:obj, ref} ->
        result = Heap.get_obj(ref, %{})
        done = Map.get(result, "done", false)

        if done == true do
          Enum.reverse(acc)
        else
          val = Map.get(result, "value", :undefined)
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

      _ ->
        false
    end
  end

  defp check_prototype_chain(_, _), do: false

  defp with_has_property?({:obj, _} = obj, key) do
    Property.get(obj, key) != :undefined
  end

  defp with_has_property?(_, _), do: false

  # ── Main dispatch loop ──

  defp run(pc, frame, stack, gas, ctx) do
    update_active_frame_pc(pc)
    run(elem(elem(frame, Frame.insns()), pc), pc, frame, stack, gas, ctx)
  end

  # ── Push constants ──

  defp run({op, [val]}, pc, frame, stack, gas, ctx)
       when op in [
              @op_push_i32,
              @op_push_i8,
              @op_push_i16,
              @op_push_minus1,
              @op_push_0,
              @op_push_1,
              @op_push_2,
              @op_push_3,
              @op_push_4,
              @op_push_5,
              @op_push_6,
              @op_push_7
            ],
       do: run(pc + 1, frame, [val | stack], gas, ctx)

  defp run({op, [idx]}, pc, frame, stack, gas, ctx)
       when op in [@op_push_const, @op_push_const8] do
    val = Scope.resolve_const(elem(frame, Frame.constants()), idx)
    val = materialize_constant(val)
    run(pc + 1, frame, [val | stack], gas, ctx)
  end

  defp run({@op_push_atom_value, [atom_idx]}, pc, frame, stack, gas, ctx) do
    run(pc + 1, frame, [Scope.resolve_atom(ctx, atom_idx) | stack], gas, ctx)
  end

  defp run({@op_undefined, []}, pc, frame, stack, gas, ctx),
    do: run(pc + 1, frame, [:undefined | stack], gas, ctx)

  defp run({@op_null, []}, pc, frame, stack, gas, ctx),
    do: run(pc + 1, frame, [nil | stack], gas, ctx)

  defp run({@op_push_false, []}, pc, frame, stack, gas, ctx),
    do: run(pc + 1, frame, [false | stack], gas, ctx)

  defp run({@op_push_true, []}, pc, frame, stack, gas, ctx),
    do: run(pc + 1, frame, [true | stack], gas, ctx)

  defp run({@op_push_empty_string, []}, pc, frame, stack, gas, ctx),
    do: run(pc + 1, frame, ["" | stack], gas, ctx)

  defp run({@op_push_bigint_i32, [val]}, pc, frame, stack, gas, ctx),
    do: run(pc + 1, frame, [{:bigint, val} | stack], gas, ctx)

  # ── Stack manipulation ──

  defp run({@op_drop, []}, pc, frame, [_ | rest], gas, ctx),
    do: run(pc + 1, frame, rest, gas, ctx)

  defp run({@op_nip, []}, pc, frame, [a, _b | rest], gas, ctx),
    do: run(pc + 1, frame, [a | rest], gas, ctx)

  defp run({@op_nip1, []}, pc, frame, [a, b, _c | rest], gas, ctx),
    do: run(pc + 1, frame, [a, b | rest], gas, ctx)

  defp run({@op_dup, []}, pc, frame, [a | _] = stack, gas, ctx),
    do: run(pc + 1, frame, [a | stack], gas, ctx)

  defp run({@op_dup1, []}, pc, frame, [a, b | _] = stack, gas, ctx) do
    run(pc + 1, frame, [a, b | stack], gas, ctx)
  end

  defp run({@op_dup2, []}, pc, frame, [a, b | _] = stack, gas, ctx) do
    run(pc + 1, frame, [a, b, a, b | stack], gas, ctx)
  end

  defp run({@op_dup3, []}, pc, frame, [a, b, c | _] = stack, gas, ctx) do
    run(pc + 1, frame, [a, b, c, a, b, c | stack], gas, ctx)
  end

  defp run({@op_insert2, []}, pc, frame, [a, b | rest], gas, ctx),
    do: run(pc + 1, frame, [a, b, a | rest], gas, ctx)

  defp run({@op_insert3, []}, pc, frame, [a, b, c | rest], gas, ctx),
    do: run(pc + 1, frame, [a, b, c, a | rest], gas, ctx)

  defp run({@op_insert4, []}, pc, frame, [a, b, c, d | rest], gas, ctx),
    do: run(pc + 1, frame, [a, b, c, d, a | rest], gas, ctx)

  defp run({@op_perm3, []}, pc, frame, [a, b, c | rest], gas, ctx),
    do: run(pc + 1, frame, [a, c, b | rest], gas, ctx)

  defp run({@op_perm4, []}, pc, frame, [a, b, c, d | rest], gas, ctx),
    do: run(pc + 1, frame, [a, c, d, b | rest], gas, ctx)

  defp run({@op_perm5, []}, pc, frame, [a, b, c, d, e | rest], gas, ctx),
    do: run(pc + 1, frame, [a, c, d, e, b | rest], gas, ctx)

  defp run({@op_swap, []}, pc, frame, [a, b | rest], gas, ctx),
    do: run(pc + 1, frame, [b, a | rest], gas, ctx)

  defp run({@op_swap2, []}, pc, frame, [a, b, c, d | rest], gas, ctx),
    do: run(pc + 1, frame, [c, d, a, b | rest], gas, ctx)

  defp run({@op_rot3l, []}, pc, frame, [a, b, c | rest], gas, ctx),
    do: run(pc + 1, frame, [c, a, b | rest], gas, ctx)

  defp run({@op_rot3r, []}, pc, frame, [a, b, c | rest], gas, ctx),
    do: run(pc + 1, frame, [b, c, a | rest], gas, ctx)

  defp run({@op_rot4l, []}, pc, frame, [a, b, c, d | rest], gas, ctx),
    do: run(pc + 1, frame, [d, a, b, c | rest], gas, ctx)

  defp run({@op_rot5l, []}, pc, frame, [a, b, c, d, e | rest], gas, ctx),
    do: run(pc + 1, frame, [e, a, b, c, d | rest], gas, ctx)

  # ── Args ──

  defp run({op, [idx]}, pc, frame, stack, gas, ctx)
       when op in [@op_get_arg, @op_get_arg0, @op_get_arg1, @op_get_arg2, @op_get_arg3],
       do: run(pc + 1, frame, [Scope.get_arg_value(ctx, idx) | stack], gas, ctx)

  # ── Locals ──

  defp run({op, [idx]}, pc, frame, stack, gas, ctx)
       when op in [
              @op_get_loc,
              @op_get_loc0,
              @op_get_loc1,
              @op_get_loc2,
              @op_get_loc3,
              @op_get_loc8
            ] do
    run(
      pc + 1,
      frame,
      [
        Closures.read_captured_local(
          elem(frame, Frame.l2v()),
          idx,
          elem(frame, Frame.locals()),
          elem(frame, Frame.var_refs())
        )
        | stack
      ],
      gas,
      ctx
    )
  end

  defp run({op, [idx]}, pc, frame, [val | rest], gas, ctx)
       when op in [
              @op_put_loc,
              @op_put_loc0,
              @op_put_loc1,
              @op_put_loc2,
              @op_put_loc3,
              @op_put_loc8
            ] do
    Closures.write_captured_local(
      elem(frame, Frame.l2v()),
      idx,
      val,
      elem(frame, Frame.locals()),
      elem(frame, Frame.var_refs())
    )

    run(pc + 1, put_local(frame, idx, val), rest, gas, ctx)
  end

  defp run({op, [idx]}, pc, frame, [val | rest], gas, ctx)
       when op in [
              @op_set_loc,
              @op_set_loc0,
              @op_set_loc1,
              @op_set_loc2,
              @op_set_loc3,
              @op_set_loc8
            ] do
    Closures.write_captured_local(
      elem(frame, Frame.l2v()),
      idx,
      val,
      elem(frame, Frame.locals()),
      elem(frame, Frame.var_refs())
    )

    run(pc + 1, put_local(frame, idx, val), [val | rest], gas, ctx)
  end

  defp run({@op_set_loc_uninitialized, [idx]}, pc, frame, stack, gas, ctx) do
    run(pc + 1, put_local(frame, idx, :__tdz__), stack, gas, ctx)
  end

  defp run({@op_get_loc_check, [idx]}, pc, frame, stack, gas, ctx) do
    val = elem(elem(frame, Frame.locals()), idx)

    if val == :__tdz__,
      do:
        throw(
          {:js_throw,
           %{
             "message" => "Cannot access variable before initialization",
             "name" => "ReferenceError"
           }}
        )

    run(pc + 1, frame, [val | stack], gas, ctx)
  end

  defp run({@op_put_loc_check, [idx]}, pc, frame, [val | rest], gas, ctx) do
    if val == :__tdz__,
      do:
        throw(
          {:js_throw,
           %{
             "message" => "Cannot access variable before initialization",
             "name" => "ReferenceError"
           }}
        )

    Closures.write_captured_local(
      elem(frame, Frame.l2v()),
      idx,
      val,
      elem(frame, Frame.locals()),
      elem(frame, Frame.var_refs())
    )

    run(pc + 1, put_local(frame, idx, val), rest, gas, ctx)
  end

  defp run({@op_put_loc_check_init, [idx]}, pc, frame, [val | rest], gas, ctx) do
    run(pc + 1, put_local(frame, idx, val), rest, gas, ctx)
  end

  defp run({@op_get_loc0_loc1, [idx0, idx1]}, pc, frame, stack, gas, ctx) do
    locals = elem(frame, Frame.locals())
    run(pc + 1, frame, [elem(locals, idx1), elem(locals, idx0) | stack], gas, ctx)
  end

  # ── Variable references (closures) ──

  defp run({op, [idx]}, pc, frame, stack, gas, ctx)
       when op in [
              @op_get_var_ref,
              @op_get_var_ref0,
              @op_get_var_ref1,
              @op_get_var_ref2,
              @op_get_var_ref3
            ] do
    val =
      case elem(elem(frame, Frame.var_refs()), idx) do
        {:cell, _} = cell -> Closures.read_cell(cell)
        other -> other
      end

    run(pc + 1, frame, [val | stack], gas, ctx)
  end

  defp run({op, [idx]}, pc, frame, [val | rest], gas, ctx)
       when op in [
              @op_put_var_ref,
              @op_put_var_ref0,
              @op_put_var_ref1,
              @op_put_var_ref2,
              @op_put_var_ref3
            ] do
    case elem(elem(frame, Frame.var_refs()), idx) do
      {:cell, ref} -> Closures.write_cell({:cell, ref}, val)
      _ -> :ok
    end

    run(pc + 1, frame, rest, gas, ctx)
  end

  defp run({op, [idx]}, pc, frame, [val | rest], gas, ctx)
       when op in [
              @op_set_var_ref,
              @op_set_var_ref0,
              @op_set_var_ref1,
              @op_set_var_ref2,
              @op_set_var_ref3
            ] do
    case elem(elem(frame, Frame.var_refs()), idx) do
      {:cell, ref} -> Closures.write_cell({:cell, ref}, val)
      _ -> :ok
    end

    run(pc + 1, frame, [val | rest], gas, ctx)
  end

  defp run({@op_close_loc, [idx]}, pc, frame, stack, gas, ctx) do
    case Map.get(elem(frame, Frame.l2v()), idx) do
      nil ->
        run(pc + 1, frame, stack, gas, ctx)

      vref_idx ->
        vrefs = elem(frame, Frame.var_refs())
        old_cell = elem(vrefs, vref_idx)
        val = Closures.read_cell(old_cell)
        new_ref = make_ref()
        Heap.put_cell(new_ref, val)
        frame = put_elem(frame, Frame.var_refs(), put_elem(vrefs, vref_idx, {:cell, new_ref}))
        run(pc + 1, frame, stack, gas, ctx)
    end
  end

  # ── Control flow ──

  defp run({op, [target]}, pc, frame, [val | rest], gas, ctx)
       when op in [@op_if_false, @op_if_false8] do
    if Values.falsy?(val) do
      gas = if target <= pc, do: check_gas(pc, frame, rest, gas, ctx), else: gas
      run(target, frame, rest, gas, ctx)
    else
      run(pc + 1, frame, rest, gas, ctx)
    end
  end

  defp run({op, [target]}, pc, frame, [val | rest], gas, ctx)
       when op in [@op_if_true, @op_if_true8] do
    if Values.truthy?(val) do
      gas = if target <= pc, do: check_gas(pc, frame, rest, gas, ctx), else: gas
      run(target, frame, rest, gas, ctx)
    else
      run(pc + 1, frame, rest, gas, ctx)
    end
  end

  defp run({op, [target]}, __pc, frame, stack, gas, ctx)
       when op in [@op_goto, @op_goto8, @op_goto16] do
    run(target, frame, stack, gas, ctx)
  end

  defp run({@op_return, []}, _pc, _frame, [val | _], _gas, _ctx), do: val

  defp run({@op_return_undef, []}, _pc, _frame, _stack, _gas, _ctx), do: :undefined

  # ── Arithmetic ──

  defp run({@op_add, []}, pc, frame, [b, a | rest], gas, %Context{catch_stack: [_ | _]} = ctx) do
    run(pc + 1, frame, [Values.add(a, b) | rest], gas, ctx)
  catch
    {:js_throw, val} -> throw_or_catch(frame, val, gas, ctx)
  end

  defp run({@op_add, []}, pc, frame, [b, a | rest], gas, ctx),
    do: run(pc + 1, frame, [Values.add(a, b) | rest], gas, ctx)

  defp run({@op_sub, []}, pc, frame, [b, a | rest], gas, ctx),
    do: run(pc + 1, frame, [Values.sub(a, b) | rest], gas, ctx)

  defp run({@op_mul, []}, pc, frame, [b, a | rest], gas, ctx),
    do: run(pc + 1, frame, [Values.mul(a, b) | rest], gas, ctx)

  defp run({@op_div, []}, pc, frame, [b, a | rest], gas, ctx),
    do: run(pc + 1, frame, [Values.div(a, b) | rest], gas, ctx)

  defp run({@op_mod, []}, pc, frame, [b, a | rest], gas, ctx),
    do: run(pc + 1, frame, [Values.mod(a, b) | rest], gas, ctx)

  defp run({@op_pow, []}, pc, frame, [b, a | rest], gas, ctx),
    do: run(pc + 1, frame, [Values.pow(a, b) | rest], gas, ctx)

  # ── Bitwise ──

  defp run({@op_band, []}, pc, frame, [b, a | rest], gas, ctx),
    do: run(pc + 1, frame, [Values.band(a, b) | rest], gas, ctx)

  defp run({@op_bor, []}, pc, frame, [b, a | rest], gas, ctx),
    do: run(pc + 1, frame, [Values.bor(a, b) | rest], gas, ctx)

  defp run({@op_bxor, []}, pc, frame, [b, a | rest], gas, ctx),
    do: run(pc + 1, frame, [Values.bxor(a, b) | rest], gas, ctx)

  defp run({@op_shl, []}, pc, frame, [b, a | rest], gas, ctx),
    do: run(pc + 1, frame, [Values.shl(a, b) | rest], gas, ctx)

  defp run({@op_sar, []}, pc, frame, [b, a | rest], gas, ctx),
    do: run(pc + 1, frame, [Values.sar(a, b) | rest], gas, ctx)

  defp run({@op_shr, []}, pc, frame, [b, a | rest], gas, ctx),
    do: run(pc + 1, frame, [Values.shr(a, b) | rest], gas, ctx)

  # ── Comparison ──

  defp run({@op_lt, []}, pc, frame, [b, a | rest], gas, ctx),
    do: run(pc + 1, frame, [Values.lt(a, b) | rest], gas, ctx)

  defp run({@op_lte, []}, pc, frame, [b, a | rest], gas, ctx),
    do: run(pc + 1, frame, [Values.lte(a, b) | rest], gas, ctx)

  defp run({@op_gt, []}, pc, frame, [b, a | rest], gas, ctx),
    do: run(pc + 1, frame, [Values.gt(a, b) | rest], gas, ctx)

  defp run({@op_gte, []}, pc, frame, [b, a | rest], gas, ctx),
    do: run(pc + 1, frame, [Values.gte(a, b) | rest], gas, ctx)

  defp run({@op_eq, []}, pc, frame, [b, a | rest], gas, ctx),
    do: run(pc + 1, frame, [Values.eq(a, b) | rest], gas, ctx)

  defp run({@op_neq, []}, pc, frame, [b, a | rest], gas, ctx),
    do: run(pc + 1, frame, [Values.neq(a, b) | rest], gas, ctx)

  defp run({@op_strict_eq, []}, pc, frame, [b, a | rest], gas, ctx),
    do: run(pc + 1, frame, [Values.strict_eq(a, b) | rest], gas, ctx)

  defp run({@op_strict_neq, []}, pc, frame, [b, a | rest], gas, ctx),
    do: run(pc + 1, frame, [not Values.strict_eq(a, b) | rest], gas, ctx)

  # ── Unary ──

  defp run({@op_neg, []}, pc, frame, [a | rest], gas, ctx),
    do: run(pc + 1, frame, [Values.neg(a) | rest], gas, ctx)

  defp run({@op_plus, []}, pc, frame, [a | rest], gas, ctx),
    do: run(pc + 1, frame, [Values.to_number(a) | rest], gas, ctx)

  defp run({@op_inc, []}, pc, frame, [a | rest], gas, ctx),
    do: run(pc + 1, frame, [Values.add(a, 1) | rest], gas, ctx)

  defp run({@op_dec, []}, pc, frame, [a | rest], gas, ctx),
    do: run(pc + 1, frame, [Values.sub(a, 1) | rest], gas, ctx)

  defp run({@op_post_inc, []}, pc, frame, [a | rest], gas, ctx) do
    num = Values.to_number(a)
    run(pc + 1, frame, [Values.add(num, 1), num | rest], gas, ctx)
  end

  defp run({@op_post_dec, []}, pc, frame, [a | rest], gas, ctx) do
    num = Values.to_number(a)
    run(pc + 1, frame, [Values.sub(num, 1), num | rest], gas, ctx)
  end

  defp run({@op_inc_loc, [idx]}, pc, frame, stack, gas, ctx) do
    locals = elem(frame, Frame.locals())
    vrefs = elem(frame, Frame.var_refs())
    l2v = elem(frame, Frame.l2v())
    new_val = Values.add(elem(locals, idx), 1)
    Closures.write_captured_local(l2v, idx, new_val, locals, vrefs)
    run(pc + 1, put_local(frame, idx, new_val), stack, gas, ctx)
  end

  defp run({@op_dec_loc, [idx]}, pc, frame, stack, gas, ctx) do
    locals = elem(frame, Frame.locals())
    vrefs = elem(frame, Frame.var_refs())
    l2v = elem(frame, Frame.l2v())
    new_val = Values.sub(elem(locals, idx), 1)
    Closures.write_captured_local(l2v, idx, new_val, locals, vrefs)
    run(pc + 1, put_local(frame, idx, new_val), stack, gas, ctx)
  end

  defp run({@op_add_loc, [idx]}, pc, frame, [val | rest], gas, ctx) do
    locals = elem(frame, Frame.locals())
    vrefs = elem(frame, Frame.var_refs())
    l2v = elem(frame, Frame.l2v())
    new_val = Values.add(elem(locals, idx), val)
    Closures.write_captured_local(l2v, idx, new_val, locals, vrefs)
    run(pc + 1, put_local(frame, idx, new_val), rest, gas, ctx)
  end

  defp run({@op_not, []}, pc, frame, [a | rest], gas, ctx),
    do: run(pc + 1, frame, [Values.to_int32(bnot(Values.to_int32(a))) | rest], gas, ctx)

  defp run({@op_lnot, []}, pc, frame, [a | rest], gas, ctx),
    do: run(pc + 1, frame, [not Values.truthy?(a) | rest], gas, ctx)

  defp run({@op_typeof, []}, pc, frame, [a | rest], gas, ctx),
    do: run(pc + 1, frame, [Values.typeof(a) | rest], gas, ctx)

  # ── Function creation / calls ──

  defp run({op, [idx]}, pc, frame, stack, gas, ctx) when op in [@op_fclosure, @op_fclosure8] do
    fun = Scope.resolve_const(elem(frame, Frame.constants()), idx)
    vrefs = elem(frame, Frame.var_refs())

    closure =
      build_closure(
        fun,
        elem(frame, Frame.locals()),
        vrefs,
        elem(frame, Frame.l2v()),
        ctx
      )

    run(pc + 1, frame, [closure | stack], gas, ctx)
  end

  defp run({op, [argc]}, pc, frame, stack, gas, ctx)
       when op in [@op_call, @op_call0, @op_call1, @op_call2, @op_call3],
       do: call_function(pc, frame, stack, argc, gas, ctx)

  defp run({@op_tail_call, [argc]}, _pc, _frame, stack, gas, ctx),
    do: tail_call(stack, argc, gas, ctx)

  defp run({@op_call_method, [argc]}, pc, frame, stack, gas, ctx),
    do: call_method(pc, frame, stack, argc, gas, ctx)

  defp run({@op_tail_call_method, [argc]}, _pc, _frame, stack, gas, ctx),
    do: tail_call_method(stack, argc, gas, ctx)

  # ── Objects ──

  defp run({@op_object, []}, pc, frame, stack, gas, ctx) do
    ref = make_ref()
    proto = Heap.get_object_prototype()
    init = if proto, do: %{proto() => proto}, else: %{}
    Heap.put_obj(ref, init)
    run(pc + 1, frame, [{:obj, ref} | stack], gas, ctx)
  end

  defp run({@op_get_field, [atom_idx]}, __pc, frame, [obj | _rest], gas, ctx)
       when obj == nil or obj == :undefined do
    throw_null_property_error(frame, obj, atom_idx, gas, ctx)
  end

  defp run({@op_get_field, [atom_idx]}, pc, frame, [obj | rest], gas, ctx) do
    run(
      pc + 1,
      frame,
      [Property.get(obj, Scope.resolve_atom(ctx, atom_idx)) | rest],
      gas,
      ctx
    )
  end

  defp run({@op_put_field, [atom_idx]}, pc, frame, [val, obj | rest], gas, ctx) do
    try do
      Objects.put(obj, Scope.resolve_atom(ctx, atom_idx), val)
      run(pc + 1, frame, rest, gas, ctx)
    catch
      {:js_throw, error} -> throw_or_catch(frame, error, gas, ctx)
    end
  end

  defp run({@op_define_field, [atom_idx]}, pc, frame, [val, obj | rest], gas, ctx) do
    try do
      Objects.put(obj, Scope.resolve_atom(ctx, atom_idx), val)
      run(pc + 1, frame, [obj | rest], gas, ctx)
    catch
      {:js_throw, error} -> throw_or_catch(frame, error, gas, ctx)
    end
  end

  defp run({@op_get_array_el, []}, pc, frame, [idx, obj | rest], gas, ctx) do
    run(pc + 1, frame, [Objects.get_element(obj, idx) | rest], gas, ctx)
  end

  defp run({@op_put_array_el, []}, pc, frame, [val, idx, obj | rest], gas, ctx) do
    try do
      Objects.put_element(obj, idx, val)
      run(pc + 1, frame, rest, gas, ctx)
    catch
      {:js_throw, error} -> throw_or_catch(frame, error, gas, ctx)
    end
  end

  defp run({@op_get_super_value, []}, pc, frame, [key, proto, _this_obj | rest], gas, ctx) do
    val = Property.get(proto, key)
    run(pc + 1, frame, [val | rest], gas, ctx)
  end

  defp run({@op_put_super_value, []}, pc, frame, [val, key, _proto, this_obj | rest], gas, ctx) do
    try do
      Objects.put(this_obj, key, val)
      run(pc + 1, frame, rest, gas, ctx)
    catch
      {:js_throw, error} -> throw_or_catch(frame, error, gas, ctx)
    end
  end

  defp run({@op_get_private_field, []}, pc, frame, [key, obj | rest], gas, ctx) do
    val =
      case obj do
        {:obj, ref} ->
          map = Heap.get_obj(ref, %{})
          Map.get(map, {:private, key}, :undefined)

        _ ->
          :undefined
      end

    run(pc + 1, frame, [val | rest], gas, ctx)
  end

  defp run({@op_put_private_field, []}, pc, frame, [key, val, obj | rest], gas, ctx) do
    set_private_field(obj, key, val)
    run(pc + 1, frame, rest, gas, ctx)
  end

  defp run({@op_define_private_field, []}, pc, frame, [val, key, obj | rest], gas, ctx) do
    set_private_field(obj, key, val)
    run(pc + 1, frame, rest, gas, ctx)
  end

  defp run({@op_private_in, []}, pc, frame, [key, obj | rest], gas, ctx) do
    result =
      case obj do
        {:obj, ref} ->
          map = Heap.get_obj(ref, %{})
          Map.has_key?(map, {:private, key})

        _ ->
          false
      end

    run(pc + 1, frame, [result | rest], gas, ctx)
  end

  defp run({@op_get_length, []}, pc, frame, [obj | rest], gas, ctx) do
    len =
      case obj do
        {:obj, ref} ->
          case Heap.get_obj(ref) do
            {:qb_arr, arr} -> :array.size(arr)
            list when is_list(list) -> length(list)
            map when is_map(map) -> Map.get(map, "length", map_size(map))
            _ -> 0
          end

        {:qb_arr, arr} ->
          :array.size(arr)

        list when is_list(list) ->
          length(list)

        s when is_binary(s) ->
          Property.string_length(s)

        %Bytecode.Function{} = f ->
          f.defined_arg_count

        {:closure, _, %Bytecode.Function{} = f} ->
          f.defined_arg_count

        {:bound, len, _, _, _} ->
          len

        _ ->
          :undefined
      end

    run(pc + 1, frame, [len | rest], gas, ctx)
  end

  defp run({@op_array_from, [argc]}, pc, frame, stack, gas, ctx) do
    {elems, rest} = Enum.split(stack, argc)
    ref = make_ref()
    Heap.put_obj(ref, Enum.reverse(elems))
    run(pc + 1, frame, [{:obj, ref} | rest], gas, ctx)
  end

  # ── Misc / no-op ──

  defp run({@op_nop, []}, pc, frame, stack, gas, ctx),
    do: run(pc + 1, frame, stack, gas, ctx)

  defp run({@op_to_object, []}, pc, frame, stack, gas, ctx),
    do: run(pc + 1, frame, stack, gas, ctx)

  defp run({@op_to_propkey, []}, pc, frame, stack, gas, ctx),
    do: run(pc + 1, frame, stack, gas, ctx)

  defp run({@op_to_propkey2, []}, pc, frame, stack, gas, ctx),
    do: run(pc + 1, frame, stack, gas, ctx)

  defp run({@op_check_ctor, []}, pc, frame, stack, gas, ctx),
    do: run(pc + 1, frame, stack, gas, ctx)

  defp run({@op_check_ctor_return, []}, pc, frame, [val | rest], gas, %Context{this: this} = ctx) do
    result =
      case val do
        {:obj, _} = obj -> obj
        _ -> this
      end

    run(pc + 1, frame, [result | rest], gas, ctx)
  end

  defp run({@op_set_name, [atom_idx]}, pc, frame, [fun | rest], gas, ctx) do
    name = Scope.resolve_atom(ctx, atom_idx)

    named = set_function_name(fun, name)

    run(pc + 1, frame, [named | rest], gas, ctx)
  end

  defp run({@op_throw, []}, __pc, frame, [val | _], gas, ctx) do
    throw_or_catch(frame, val, gas, ctx)
  end

  defp run({@op_is_undefined, []}, pc, frame, [a | rest], gas, ctx),
    do: run(pc + 1, frame, [a == :undefined | rest], gas, ctx)

  defp run({@op_is_null, []}, pc, frame, [a | rest], gas, ctx),
    do: run(pc + 1, frame, [a == nil | rest], gas, ctx)

  defp run({@op_is_undefined_or_null, []}, pc, frame, [a | rest], gas, ctx),
    do: run(pc + 1, frame, [a == :undefined or a == nil | rest], gas, ctx)

  defp run({@op_invalid, []}, _pc, _frame, _stack, _gas, _ctx),
    do: throw({:error, :invalid_opcode})

  defp run({@op_get_var_undef, [atom_idx]}, pc, frame, stack, gas, ctx) do
    val =
      case Scope.resolve_global(ctx, atom_idx) do
        {:found, v} -> v
        :not_found -> :undefined
      end

    run(pc + 1, frame, [val | stack], gas, ctx)
  end

  defp run({@op_get_var, [atom_idx]}, pc, frame, stack, gas, ctx) do
    case Scope.resolve_global(ctx, atom_idx) do
      {:found, val} ->
        run(pc + 1, frame, [val | stack], gas, ctx)

      :not_found ->
        error =
          Heap.make_error("#{Scope.resolve_atom(ctx, atom_idx)} is not defined", "ReferenceError")

        throw_or_catch(frame, error, gas, ctx)
    end
  end

  defp run({op, [atom_idx]}, pc, frame, [val | rest], gas, ctx)
       when op in [@op_put_var, @op_put_var_init] do
    new_ctx = Scope.set_global(ctx, atom_idx, val)
    Heap.put_persistent_globals(new_ctx.globals)
    run(pc + 1, frame, rest, gas, new_ctx)
  end

  # define_func: global scope function hoisting (sloppy mode)
  defp run({@op_define_func, [atom_idx, _flags]}, pc, frame, [fun | rest], gas, ctx) do
    ctx = Scope.set_global(ctx, atom_idx, fun)
    Heap.put_persistent_globals(ctx.globals)
    run(pc + 1, frame, rest, gas, ctx)
  end

  defp run({@op_define_var, [atom_idx, _scope]}, pc, frame, stack, gas, ctx) do
    Heap.put_var(Scope.resolve_atom(ctx, atom_idx), :undefined)
    run(pc + 1, frame, stack, gas, ctx)
  end

  defp run({@op_check_define_var, [atom_idx, _scope]}, pc, frame, stack, gas, ctx) do
    Heap.delete_var(Scope.resolve_atom(ctx, atom_idx))
    run(pc + 1, frame, stack, gas, ctx)
  end

  defp run({@op_get_field2, [atom_idx]}, __pc, frame, [obj | _rest], gas, ctx)
       when obj == nil or obj == :undefined do
    throw_null_property_error(frame, obj, atom_idx, gas, ctx)
  end

  defp run({@op_get_field2, [atom_idx]}, pc, frame, [obj | rest], gas, ctx) do
    val = Property.get(obj, Scope.resolve_atom(ctx, atom_idx))
    run(pc + 1, frame, [val, obj | rest], gas, ctx)
  end

  # ── try/catch ──

  defp run({@op_catch, [target]}, pc, frame, stack, gas, %Context{catch_stack: catch_stack} = ctx) do
    ctx = %{ctx | catch_stack: [{target, stack} | catch_stack]}
    run(pc + 1, frame, [target | stack], gas, ctx)
  end

  defp run(
         {@op_nip_catch, []},
         pc,
         frame,
         [a, _catch_offset | rest],
         gas,
         %Context{catch_stack: [_ | rest_catch]} = ctx
       ) do
    run(pc + 1, frame, [a | rest], gas, %{ctx | catch_stack: rest_catch})
  end

  # ── for-in ──

  defp run({@op_for_in_start, []}, pc, frame, [obj | rest], gas, ctx) do
    keys =
      case obj do
        {:obj, ref} ->
          map = Heap.get_obj(ref, %{})

          case map do
            %{proxy_target() => _target, proxy_handler() => handler} ->
              own_keys_fn = Property.get(handler, "ownKeys")

              if own_keys_fn != :undefined and own_keys_fn != nil do
                result = Runtime.call_callback(own_keys_fn, [obj])
                Heap.to_list(result) |> Enum.map(&to_string/1)
              else
                []
              end

            _ ->
              raw_keys =
                case Map.get(map, key_order()) do
                  order when is_list(order) -> Enum.reverse(order)
                  _ -> Map.keys(map)
                end

              own_keys =
                raw_keys
                |> Enum.reject(fn k ->
                  (is_binary(k) and String.starts_with?(k, "__")) or
                    is_tuple(k) or is_atom(k) or
                    not Map.has_key?(map, k) or
                    match?(%{enumerable: false}, Heap.get_prop_desc(ref, k))
                end)

              proto_keys = collect_proto_keys(Map.get(map, proto()), [])
              all_keys = own_keys ++ Enum.reject(proto_keys, &(&1 in own_keys))
              Runtime.sort_numeric_keys(all_keys)
          end

        map when is_map(map) ->
          Map.keys(map)

        _ ->
          []
      end

    run(pc + 1, frame, [{:for_in_iterator, keys} | rest], gas, ctx)
  end

  defp run(
         {@op_for_in_next, []},
         pc,
         frame,
         [{:for_in_iterator, [key | rest_keys]} | rest],
         gas,
         ctx
       ) do
    run(pc + 1, frame, [false, key, {:for_in_iterator, rest_keys} | rest], gas, ctx)
  end

  defp run({@op_for_in_next, []}, pc, frame, [iter | rest], gas, ctx) do
    run(pc + 1, frame, [true, :undefined, iter | rest], gas, ctx)
  end

  # ── new / constructor ──

  defp run({@op_call_constructor, [argc]}, pc, frame, stack, gas, ctx) do
    {args, [new_target, ctor | rest]} = Enum.split(stack, argc)

    gas = check_gas(pc, frame, rest, gas, ctx)

    catch_js_throw(pc, frame, rest, gas, ctx, fn ->
      rev_args = Enum.reverse(args)

      raw_ctor =
        case ctor do
          {:closure, _, %Bytecode.Function{} = f} -> f
          {:bound, _, inner, _, _} -> inner
          other -> other
        end

      # Generators and async generators cannot be constructors
      case raw_ctor do
        %Bytecode.Function{func_kind: fk} when fk in [@func_generator, @func_async_generator] ->
          name = raw_ctor.name || "anonymous"
          throw({:js_throw, Heap.make_error("#{name} is not a constructor", "TypeError")})

        _ ->
          :ok
      end

      this_ref = make_ref()

      raw_new_target =
        case new_target do
          {:closure, _, %Bytecode.Function{} = f} -> f
          %Bytecode.Function{} = f -> f
          _ -> nil
        end

      proto =
        if raw_new_target != nil and raw_new_target != raw_ctor do
          Heap.get_class_proto(raw_new_target) || Heap.get_class_proto(raw_ctor) ||
            Heap.get_or_create_prototype(ctor)
        else
          Heap.get_class_proto(raw_ctor) || Heap.get_or_create_prototype(ctor)
        end

      this_obj =
        case raw_ctor do
          %Bytecode.Function{is_derived_class_constructor: true} ->
            :uninitialized

          _ ->
            init = if proto, do: %{proto() => proto}, else: %{}
            Heap.put_obj(this_ref, init)
            {:obj, this_ref}
        end

      ctor_ctx = %{ctx | this: this_obj, new_target: new_target}

      result =
        case ctor do
          %Bytecode.Function{} = f ->
            do_invoke(f, {:closure, %{}, f}, rev_args, ctor_var_refs(f), gas, ctor_ctx)

          {:closure, captured, %Bytecode.Function{} = f} ->
            do_invoke(
              f,
              {:closure, captured, f},
              rev_args,
              ctor_var_refs(f, captured),
              gas,
              ctor_ctx
            )

          {:bound, _, _, orig_fun, bound_args} ->
            all_args = bound_args ++ rev_args

            case orig_fun do
              %Bytecode.Function{} = f ->
                do_invoke(f, {:closure, %{}, f}, all_args, ctor_var_refs(f), gas, ctor_ctx)

              {:closure, captured, %Bytecode.Function{} = f} ->
                do_invoke(
                  f,
                  {:closure, captured, f},
                  all_args,
                  ctor_var_refs(f, captured),
                  gas,
                  ctor_ctx
                )

              {:builtin, _, cb} when is_function(cb, 2) ->
                cb.(all_args, this_obj)

              _ ->
                this_obj
            end

          {:builtin, name, cb} when is_function(cb, 2) ->
            obj = cb.(rev_args, nil)

            if name in ~w(Number String Boolean) do
              # Store primitive value for valueOf() on wrapper objects
              existing = Heap.get_obj(this_ref, %{})
              val_fn = {:builtin, "valueOf", fn _, _ -> obj end}

              to_str_fn =
                {:builtin, "toString", fn _, _ -> Values.stringify(obj) end}

              Heap.put_obj(
                this_ref,
                Map.merge(existing, %{
                  primitive_value() => obj,
                  "valueOf" => val_fn,
                  "toString" => to_str_fn
                })
              )
            end

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
          %Bytecode.Function{} = f -> f
          {:closure, _, %Bytecode.Function{}} = c -> c
          _ -> this_obj
        end

      case {result, Heap.get_class_proto(raw_ctor)} do
        {{:obj, rref}, {:obj, _} = proto2} ->
          rmap = Heap.get_obj(rref, %{})

          unless Map.has_key?(rmap, proto()) do
            Heap.put_obj(rref, Map.put(rmap, proto(), proto2))
          end

        _ ->
          :ok
      end

      result
    end)
  end

  defp run({@op_init_ctor, []}, pc, frame, stack, gas, %Context{arg_buf: arg_buf} = ctx) do
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
          do_invoke(f, {:closure, %{}, f}, args, ctor_var_refs(f), gas, ctx)

        {:closure, captured, %Bytecode.Function{} = f} ->
          do_invoke(f, {:closure, captured, f}, args, ctor_var_refs(f, captured), gas, ctx)

        {:builtin, _name, cb} when is_function(cb, 2) ->
          cb.(args, nil)

        _ ->
          ctx.this
      end

    result =
      case result do
        {:obj, _} = obj -> obj
        _ -> ctx.this
      end

    run(pc + 1, frame, [result | stack], gas, %{ctx | this: result})
  end

  # ── instanceof ──

  defp run({@op_instanceof, []}, pc, frame, [ctor, obj | rest], gas, ctx) do
    result =
      case obj do
        {:obj, _} ->
          ctor_proto = Property.get(ctor, "prototype")
          check_prototype_chain(obj, ctor_proto)

        _ ->
          false
      end

    run(pc + 1, frame, [result | rest], gas, ctx)
  end

  # ── delete ──

  defp run({@op_delete, []}, __pc, frame, [key, obj | _rest], gas, ctx)
       when obj == nil or obj == :undefined do
    nullish = if obj == nil, do: "null", else: "undefined"

    error =
      Heap.make_error("Cannot delete properties of #{nullish} (deleting '#{key}')", "TypeError")

    throw_or_catch(frame, error, gas, ctx)
  end

  defp run({@op_delete, []}, pc, frame, [key, obj | rest], gas, ctx) do
    result =
      case obj do
        {:obj, ref} ->
          map = Heap.get_obj(ref, %{})

          if is_map(map) do
            desc = Heap.get_prop_desc(ref, key)

            if match?(%{configurable: false}, desc) do
              false
            else
              new_map = Map.delete(map, key)
              Heap.put_obj(ref, new_map)
              true
            end
          else
            true
          end

        _ ->
          true
      end

    run(pc + 1, frame, [result | rest], gas, ctx)
  end

  defp run({@op_delete_var, [_atom_idx]}, pc, frame, stack, gas, ctx),
    do: run(pc + 1, frame, [true | stack], gas, ctx)

  # ── in operator ──

  defp run({@op_in, []}, pc, frame, [obj, key | rest], gas, ctx) do
    run(pc + 1, frame, [Objects.has_property(obj, key) | rest], gas, ctx)
  end

  # ── regexp literal ──

  defp run({@op_regexp, []}, pc, frame, [pattern, flags | rest], gas, ctx) do
    run(pc + 1, frame, [{:regexp, pattern, flags} | rest], gas, ctx)
  end

  # ── spread / array construction ──

  defp run({@op_append, []}, pc, frame, [obj, idx, arr | rest], gas, ctx) do
    src_list =
      case obj do
        {:qb_arr, arr} ->
          :array.to_list(arr)

        list when is_list(list) ->
          list

        {:obj, ref} ->
          stored = Heap.get_obj(ref)

          cond do
            match?({:qb_arr, _}, stored) ->
              Heap.to_list({:obj, ref})

            is_list(stored) ->
              stored

            is_map(stored) and Map.has_key?(stored, {:symbol, "Symbol.iterator"}) ->
              iter_fn = Map.get(stored, {:symbol, "Symbol.iterator"})
              iter_obj = Runtime.call_callback(iter_fn, [])
              collect_iterator(iter_obj, [])

            is_map(stored) and Map.has_key?(stored, set_data()) ->
              Map.get(stored, set_data(), [])

            is_map(stored) and Map.has_key?(stored, map_data()) ->
              Map.get(stored, map_data(), [])

            true ->
              []
          end

        _ ->
          []
      end

    arr_list =
      case arr do
        {:qb_arr, arr_data} -> :array.to_list(arr_data)
        list when is_list(list) -> list
        {:obj, ref} -> Heap.to_list({:obj, ref})
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

    run(pc + 1, frame, [new_idx, merged_obj | rest], gas, ctx)
  end

  defp run({@op_define_array_el, []}, pc, frame, [val, idx, obj | rest], gas, ctx) do
    obj2 =
      case obj do
        list when is_list(list) ->
          i = if is_integer(idx), do: idx, else: Runtime.to_int(idx)
          Objects.set_list_at(list, i, val)

        {:obj, ref} ->
          stored = Heap.get_obj(ref, [])

          cond do
            match?({:qb_arr, _}, stored) ->
              i = if is_integer(idx), do: idx, else: Runtime.to_int(idx)
              Heap.array_set(ref, i, val)

            is_list(stored) ->
              i = if is_integer(idx), do: idx, else: Runtime.to_int(idx)
              Heap.put_obj(ref, Objects.set_list_at(stored, i, val))

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

    run(pc + 1, frame, [idx, obj2 | rest], gas, ctx)
  end

  # ── Closure variable refs (mutable) ──

  defp run({op, [idx]}, pc, frame, stack, gas, ctx)
       when op in [@op_make_var_ref, @op_make_loc_ref] do
    ref = make_ref()
    Heap.put_cell(ref, elem(elem(frame, Frame.locals()), idx))
    run(pc + 1, frame, [{:cell, ref} | stack], gas, ctx)
  end

  defp run({@op_make_arg_ref, [idx]}, pc, frame, stack, gas, ctx) do
    ref = make_ref()
    Heap.put_cell(ref, Scope.get_arg_value(ctx, idx))
    run(pc + 1, frame, [{:cell, ref} | stack], gas, ctx)
  end

  defp run({@op_get_var_ref_check, [idx]}, pc, frame, stack, gas, ctx) do
    case elem(elem(frame, Frame.var_refs()), idx) do
      :__tdz__ ->
        throw(
          {:js_throw,
           %{
             "message" => "Cannot access variable before initialization",
             "name" => "ReferenceError"
           }}
        )

      {:cell, _} = cell ->
        run(pc + 1, frame, [Closures.read_cell(cell) | stack], gas, ctx)

      val ->
        run(pc + 1, frame, [val | stack], gas, ctx)
    end
  end

  defp run({op, [idx]}, pc, frame, [val | rest], gas, ctx)
       when op in [@op_put_var_ref_check, @op_put_var_ref_check_init] do
    case elem(elem(frame, Frame.var_refs()), idx) do
      {:cell, ref} -> Closures.write_cell({:cell, ref}, val)
      _ -> :ok
    end

    run(pc + 1, frame, rest, gas, ctx)
  end

  defp run({@op_get_ref_value, []}, pc, frame, [ref | rest], gas, ctx) do
    run(pc + 1, frame, [Closures.read_cell(ref) | rest], gas, ctx)
  end

  defp run({@op_put_ref_value, []}, pc, frame, [val, {:cell, _} = ref | rest], gas, ctx) do
    Closures.write_cell(ref, val)
    run(pc + 1, frame, [val | rest], gas, ctx)
  end

  defp run({@op_put_ref_value, []}, pc, frame, [val, key, obj | rest], gas, ctx)
       when is_binary(key) do
    try do
      Objects.put(obj, key, val)
      run(pc + 1, frame, rest, gas, ctx)
    catch
      {:js_throw, error} -> throw_or_catch(frame, error, gas, ctx)
    end
  end

  # ── gosub/ret (finally blocks) ──

  defp run({@op_gosub, [target]}, pc, frame, stack, gas, ctx) do
    run(target, frame, [{:return_addr, pc + 1} | stack], gas, ctx)
  end

  defp run({@op_ret, []}, __pc, frame, [{:return_addr, ret_pc} | rest], gas, ctx) do
    run(ret_pc, frame, rest, gas, ctx)
  end

  # ── eval ──

  defp run({@op_import, []}, pc, frame, [specifier, _import_meta | rest], gas, ctx) do
    result =
      if is_binary(specifier) and ctx.runtime_pid != nil do
        case QuickBEAM.Runtime.load_module(ctx.runtime_pid, specifier, "") do
          :ok ->
            # Module loaded — create a module namespace object
            # For now, return an empty object (module exports would need linking)
            Promise.resolved(Runtime.new_object())

          {:error, _} ->
            Promise.rejected(Heap.make_error("Cannot find module '#{specifier}'", "TypeError"))
        end
      else
        Promise.rejected(Heap.make_error("Invalid module specifier", "TypeError"))
      end

    run(pc + 1, frame, [result | rest], gas, ctx)
  end

  defp run({@op_eval, [argc | scope_args]}, pc, frame, stack, gas, ctx) do
    {args, rest} = Enum.split(stack, argc + 1)
    eval_ref = List.last(args)
    call_args = Enum.take(args, argc) |> Enum.reverse()
    code = List.first(call_args, :undefined)
    scope_depth = List.first(scope_args, -1)

    var_objs =
      if scope_args != [] do
        locals = elem(frame, Frame.locals())

        obj_locals =
          for i <- 0..(tuple_size(locals) - 1),
              obj = elem(locals, i),
              match?({:obj, _}, obj),
              do: obj

        obj_locals = if scope_depth == 0, do: Enum.take(obj_locals, 1), else: obj_locals
        Enum.uniq(obj_locals ++ captured_var_objects(ctx.current_func))
      else
        []
      end

    try do
      {result, new_ctx} =
        cond do
          eval_ref == ctx.globals["eval"] and is_binary(code) and ctx.runtime_pid != nil ->
            keep_declared? = scope_depth > 0
            {value, transient_globals} = eval_code(code, frame, gas, ctx, var_objs, keep_declared?)
            {value, %{ctx | globals: Map.merge(ctx.globals, transient_globals)}}

          is_function(eval_ref) or match?({:fn, _, _}, eval_ref) or match?({:bound, _, _}, eval_ref) or
              match?(%Bytecode.Function{}, eval_ref) or
              match?({:closure, _, %Bytecode.Function{}}, eval_ref) ->
            persistent = Heap.get_persistent_globals() || %{}
            {dispatch_call(eval_ref, call_args, gas, ctx, :undefined),
             %{ctx | globals: Map.merge(ctx.globals, persistent)}}

          true ->
            {:undefined, ctx}
        end

      run(pc + 1, frame, [result | rest], gas, new_ctx)
    catch
      {:js_throw, error} -> throw_or_catch(frame, error, gas, ctx)
    end
  end

  defp run({@op_apply_eval, [scope_idx_raw]}, pc, frame, [arg_array, fun | rest], gas, ctx) do
    args = Heap.to_list(arg_array)
    code = List.first(args, :undefined)
    scope_idx = scope_idx_raw - 1

    var_objs =
      if scope_idx >= 0 do
        locals = elem(frame, Frame.locals())

        obj_locals =
          for i <- 0..(tuple_size(locals) - 1),
              obj = elem(locals, i),
              match?({:obj, _}, obj),
              do: obj

        obj_locals = if scope_idx == 0, do: Enum.take(obj_locals, 1), else: obj_locals
        Enum.uniq(obj_locals ++ captured_var_objects(ctx.current_func))
      else
        []
      end

    try do
      {result, new_ctx} =
        cond do
          fun == ctx.globals["eval"] and is_binary(code) and ctx.runtime_pid != nil ->
            keep_declared? = scope_idx > 0
            {value, transient_globals} = eval_code(code, frame, gas, ctx, var_objs, keep_declared?)
            {value, %{ctx | globals: Map.merge(ctx.globals, transient_globals)}}

          is_function(fun) or match?({:fn, _, _}, fun) or match?({:bound, _, _}, fun) or
              match?(%Bytecode.Function{}, fun) or
              match?({:closure, _, %Bytecode.Function{}}, fun) ->
            persistent = Heap.get_persistent_globals() || %{}
            {dispatch_call(fun, args, gas, ctx, :undefined),
             %{ctx | globals: Map.merge(ctx.globals, persistent)}}

          true ->
            {:undefined, ctx}
        end

      run(pc + 1, frame, [result | rest], gas, new_ctx)
    catch
      {:js_throw, error} -> throw_or_catch(frame, error, gas, ctx)
    end
  end

  # ── Iterators ──

  defp run({@op_for_of_start, []}, pc, frame, [obj | rest], gas, ctx) do
    {iter_obj, next_fn} =
      case obj do
        list when is_list(list) ->
          make_list_iterator(list)

        {:obj, ref} ->
          stored = Heap.get_obj(ref)

          case stored do
            {:qb_arr, arr} ->
              make_list_iterator(:array.to_list(arr))

            list when is_list(list) ->
              make_list_iterator(list)

            map when is_map(map) ->
              sym_iter = {:symbol, "Symbol.iterator"}

              cond do
                Map.has_key?(map, sym_iter) ->
                  iter_fn = Map.get(map, sym_iter)
                  iter_obj = Runtime.call_callback(iter_fn, [])
                  {iter_obj, Property.get(iter_obj, "next")}

                Map.has_key?(map, "next") ->
                  {obj, Property.get(obj, "next")}

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

    run(pc + 1, frame, [0, next_fn, iter_obj | rest], gas, ctx)
  end

  defp run({@op_for_of_next, [idx]}, pc, frame, stack, gas, ctx) do
    offset = 3 + idx
    iter_obj = Enum.at(stack, offset - 1)
    next_fn = Enum.at(stack, offset - 2)

    if iter_obj == :undefined do
      run(pc + 1, frame, [true, :undefined | stack], gas, ctx)
    else
      result = Runtime.call_callback(next_fn, [])
      done = Property.get(result, "done")
      value = Property.get(result, "value")

      if done == true do
        cleared = List.replace_at(stack, offset - 1, :undefined)
        run(pc + 1, frame, [true, :undefined | cleared], gas, ctx)
      else
        run(pc + 1, frame, [false, value | stack], gas, ctx)
      end
    end
  end

  # iterator_next: stack is [val, catch_offset, next_fn, iter_obj | rest]
  # Calls next_fn(iter_obj, val), replaces val (top) with raw result object
  defp run(
         {@op_iterator_next, []},
         pc,
         frame,
         [val, catch_offset, next_fn, iter_obj | rest],
         gas,
         ctx
       ) do
    result = Runtime.call_callback(next_fn, [val])
    run(pc + 1, frame, [result, catch_offset, next_fn, iter_obj | rest], gas, ctx)
  end

  defp run({@op_iterator_get_value_done, []}, pc, frame, [result | rest], gas, ctx) do
    done = Property.get(result, "done")
    value = Property.get(result, "value")

    if done == true do
      run(pc + 1, frame, [true, :undefined | rest], gas, ctx)
    else
      run(pc + 1, frame, [false, value | rest], gas, ctx)
    end
  end

  defp run(
         {@op_iterator_close, []},
         pc,
         frame,
         [_catch_offset, _next_fn, iter_obj | rest],
         gas,
         ctx
       ) do
    if iter_obj != :undefined do
      return_fn = Property.get(iter_obj, "return")

      if return_fn != :undefined and return_fn != nil do
        Runtime.call_callback(return_fn, [])
      end
    end

    run(pc + 1, frame, rest, gas, ctx)
  end

  defp run({@op_iterator_check_object, []}, pc, frame, stack, gas, ctx),
    do: run(pc + 1, frame, stack, gas, ctx)

  defp run({@op_iterator_call, [flags]}, pc, frame, stack, gas, ctx) do
    [_val, _catch_offset, _next_fn, iter_obj | _] = stack
    method_name = if Bitwise.band(flags, 1) == 1, do: "throw", else: "return"
    method = Property.get(iter_obj, method_name)

    if method == :undefined or method == nil do
      run(pc + 1, frame, [true | stack], gas, ctx)
    else
      result =
        if Bitwise.band(flags, 2) == 2 do
          Runtime.call_callback(method, [])
        else
          [val | _] = stack
          Runtime.call_callback(method, [val])
        end

      [_ | rest] = stack
      run(pc + 1, frame, [false, result | rest], gas, ctx)
    end
  end

  defp run({@op_iterator_call, []}, pc, frame, stack, gas, ctx),
    do: run(pc + 1, frame, stack, gas, ctx)

  # ── Misc stubs ──

  defp run({op, [idx]}, pc, frame, [val | rest], gas, %Context{arg_buf: arg_buf} = ctx)
       when op in [@op_put_arg, @op_put_arg0, @op_put_arg1, @op_put_arg2, @op_put_arg3] do
    ctx = put_arg_value(ctx, idx, val, arg_buf)
    run(pc + 1, frame, rest, gas, ctx)
  end

  defp run({@op_set_home_object, []}, pc, frame, [method, target | _] = stack, gas, ctx) do
    key = {:qb_home_object, home_object_key(method)}
    if key != {:qb_home_object, nil}, do: Process.put(key, target)
    run(pc + 1, frame, stack, gas, ctx)
  end

  defp run({@op_set_proto, []}, pc, frame, [proto, obj | rest], gas, ctx) do
    case obj do
      {:obj, ref} ->
        map = Heap.get_obj(ref, %{})

        if is_map(map) do
          Heap.put_obj(ref, Map.put(map, proto(), proto))
        end

      _ ->
        :ok
    end

    run(pc + 1, frame, [obj | rest], gas, ctx)
  end

  defp run(
         {@op_special_object, [type]},
         pc,
         frame,
         stack,
         gas,
         %Context{arg_buf: arg_buf, current_func: current_func} = ctx
       ) do
    val =
      case type do
        0 ->
          args_list = Tuple.to_list(arg_buf)
          Heap.wrap(args_list)

        1 ->
          args_list = Tuple.to_list(arg_buf)
          Heap.wrap(args_list)

        2 ->
          current_func

        3 ->
          ctx.new_target

        4 ->
          key = {:qb_home_object, home_object_key(current_func)}
          Process.get(key, :undefined)

        5 ->
          Heap.wrap(%{})

        6 ->
          Heap.wrap(%{})

        7 ->
          Heap.wrap(%{"__proto__" => nil})

        _ ->
          :undefined
      end

    run(pc + 1, frame, [val | stack], gas, ctx)
  end

  defp run({@op_rest, [start_idx]}, pc, frame, stack, gas, %Context{arg_buf: arg_buf} = ctx) do
    rest_args =
      if start_idx < tuple_size(arg_buf) do
        Tuple.to_list(arg_buf) |> Enum.drop(start_idx)
      else
        []
      end

    ref = make_ref()
    Heap.put_obj(ref, rest_args)
    run(pc + 1, frame, [{:obj, ref} | stack], gas, ctx)
  end

  defp run({@op_typeof_is_function, []}, pc, frame, [val | rest], gas, ctx) do
    result = Builtin.callable?(val)

    run(pc + 1, frame, [result | rest], gas, ctx)
  end

  defp run({@op_typeof_is_undefined, []}, pc, frame, [val | rest], gas, ctx) do
    result = val == :undefined or val == nil
    run(pc + 1, frame, [result | rest], gas, ctx)
  end

  defp run({@op_throw_error, []}, _pc, _frame, [val | _], _gas, _ctx), do: throw({:js_throw, val})

  defp run({@op_throw_error, [atom_idx, reason]}, __pc, frame, _stack, gas, ctx) do
    name = Scope.resolve_atom(ctx, atom_idx)

    {error_type, message} =
      case reason do
        0 -> {"TypeError", "'#{name}' is read-only"}
        1 -> {"SyntaxError", "redeclaration of '#{name}'"}
        2 -> {"ReferenceError", "cannot access '#{name}' before initialization"}
        3 -> {"ReferenceError", "unsupported reference to 'super'"}
        4 -> {"TypeError", "iterator does not have a throw method"}
        _ -> {"Error", name}
      end

    throw_or_catch(frame, Heap.make_error(message, error_type), gas, ctx)
  end

  defp run({@op_set_name_computed, []}, pc, frame, [fun, name_val | rest], gas, ctx) do
    name =
      case name_val do
        s when is_binary(s) -> s
        n when is_number(n) -> Values.stringify(n)
        {:symbol, desc, _} -> "[" <> desc <> "]"
        {:symbol, desc} -> "[" <> desc <> "]"
        _ -> ""
      end

    named = set_function_name(fun, name)

    run(pc + 1, frame, [named, name_val | rest], gas, ctx)
  end

  defp run({@op_copy_data_properties, []}, pc, frame, stack, gas, ctx),
    do: run(pc + 1, frame, stack, gas, ctx)

  defp run({@op_get_super, []}, pc, frame, [func | rest], gas, ctx) do
    parent =
      case func do
        {:obj, ref} ->
          case Heap.get_obj(ref, %{}) do
            map when is_map(map) ->
              Map.get(map, proto(), :undefined)

            _ ->
              :undefined
          end

        {:closure, _, %Bytecode.Function{} = f} ->
          Heap.get_parent_ctor(f) || :undefined

        %Bytecode.Function{} = f ->
          Heap.get_parent_ctor(f) || :undefined

        {:builtin, _, _} = b ->
          Map.get(Heap.get_ctor_statics(b), "__proto__", :undefined)

        _ ->
          :undefined
      end

    run(pc + 1, frame, [parent | rest], gas, ctx)
  end

  defp run({@op_push_this, []}, _pc, frame, _stack, gas, %Context{this: :uninitialized} = ctx) do
    throw_or_catch(frame, Heap.make_error("this is not initialized", "ReferenceError"), gas, ctx)
  end

  defp run({@op_push_this, []}, pc, frame, stack, gas, %Context{this: this} = ctx) do
    run(pc + 1, frame, [this | stack], gas, ctx)
  end

  defp run({@op_private_symbol, [atom_idx]}, pc, frame, stack, gas, ctx) do
    name = Scope.resolve_atom(ctx, atom_idx)
    run(pc + 1, frame, [{:private_symbol, name, make_ref()} | stack], gas, ctx)
  end

  # ── Argument mutation ──

  defp run({op, [idx]}, pc, frame, [val | rest], gas, %Context{arg_buf: arg_buf} = ctx)
       when op in [@op_set_arg, @op_set_arg0, @op_set_arg1, @op_set_arg2, @op_set_arg3] do
    ctx = put_arg_value(ctx, idx, val, arg_buf)
    run(pc + 1, frame, [val | rest], gas, ctx)
  end

  # ── Array element access (2-element push) ──

  defp run({@op_get_array_el2, []}, pc, frame, [idx, obj | rest], gas, ctx) do
    run(pc + 1, frame, [Property.get(obj, idx), obj | rest], gas, ctx)
  end

  # ── Spread/rest via apply ──

  defp run({@op_apply, [_magic]}, pc, frame, [arg_array, this_obj, fun | rest], gas, ctx) do
    args =
      case arg_array do
        {:qb_arr, arr} ->
          :array.to_list(arr)

        list when is_list(list) ->
          list

        {:obj, ref} ->
          Heap.to_list({:obj, ref})

        _ ->
          []
      end

    apply_ctx = %{ctx | this: this_obj}

    result =
      case fun do
        %Bytecode.Function{} = f -> invoke_function(f, args, gas, apply_ctx)
        {:closure, _, %Bytecode.Function{}} = c -> invoke_closure(c, args, gas, apply_ctx)
        other -> Builtin.call(other, args, this_obj)
      end

    run(pc + 1, frame, [result | rest], gas, ctx)
  end

  # ── Object spread (copy_data_properties with mask) ──

  defp run({@op_copy_data_properties, [mask]}, pc, frame, stack, gas, ctx) do
    target_idx = mask &&& 3
    source_idx = Bitwise.bsr(mask, 2) &&& 7
    target = Enum.at(stack, target_idx)
    source = Enum.at(stack, source_idx)

    try do
      src_props =
        case source do
          {:obj, ref} = source_obj ->
            case Heap.get_obj(ref, %{}) do
              {:qb_arr, _} ->
                Enum.reduce(0..max(Heap.array_size(ref) - 1, 0), %{}, fn i, acc ->
                  Map.put(acc, Integer.to_string(i), Property.get(source_obj, Integer.to_string(i)))
                end)

              list when is_list(list) ->
                Enum.reduce(0..max(length(list) - 1, 0), %{}, fn i, acc ->
                  Map.put(acc, Integer.to_string(i), Property.get(source_obj, Integer.to_string(i)))
                end)

              map when is_map(map) ->
                map
                |> Map.keys()
                |> Enum.filter(&is_binary/1)
                |> Enum.reject(fn k -> String.starts_with?(k, "__") and String.ends_with?(k, "__") end)
                |> Enum.reduce(%{}, fn k, acc -> Map.put(acc, k, Property.get(source_obj, k)) end)

              _ ->
                %{}
            end

          map when is_map(map) ->
            map

          _ ->
            %{}
        end

      case target do
        {:obj, ref} ->
          existing = Heap.get_obj(ref, %{})
          existing = if is_map(existing), do: existing, else: %{}
          Heap.put_obj(ref, Map.merge(existing, src_props))

        _ ->
          :ok
      end

      run(pc + 1, frame, stack, gas, ctx)
    catch
      {:js_throw, error} -> throw_or_catch(frame, error, gas, ctx)
    end
  end

  # ── Class definitions ──

  defp run(
         {@op_define_class, [_atom_idx, _flags]},
         pc,
         frame,
         [ctor, parent_ctor | rest],
         gas,
         ctx
       ) do
    locals = elem(frame, Frame.locals())
    vrefs = elem(frame, Frame.var_refs())
    l2v = elem(frame, Frame.l2v())

    ctor_closure =
      case ctor do
        %Bytecode.Function{} = f ->
          base = build_closure(f, locals, vrefs, l2v, ctx)
          inherit_parent_vrefs(base, vrefs)

        already_closure ->
          already_closure
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
      if parent_proto,
        do: Map.put(proto_map, proto(), parent_proto),
        else: proto_map

    Heap.put_obj(proto_ref, proto_map)
    proto = {:obj, proto_ref}
    Heap.put_class_proto(raw, proto)
    Heap.put_ctor_static(ctor_closure, "prototype", proto)

    if parent_ctor != :undefined do
      Heap.put_parent_ctor(raw, parent_ctor)
    end

    run(pc + 1, frame, [proto, ctor_closure | rest], gas, ctx)
  end

  defp run({@op_add_brand, []}, pc, frame, [obj, brand | rest], gas, ctx) do
    case obj do
      {:obj, ref} ->
        Heap.update_obj(ref, %{}, fn map ->
          brands = Map.get(map, :__brands__, [])
          Map.put(map, :__brands__, [brand | brands])
        end)

      _ ->
        :ok
    end

    run(pc + 1, frame, rest, gas, ctx)
  end

  defp run({@op_check_brand, []}, pc, frame, [_brand, obj | _] = stack, gas, ctx) do
    # Permissive: verify obj is an object (skip full brand check for perf)
    case obj do
      {:obj, _} -> run(pc + 1, frame, stack, gas, ctx)
      _ -> throw({:js_throw, Heap.make_error("invalid brand on object", "TypeError")})
    end
  end

  defp run(
         {@op_define_class_computed, [atom_idx, flags]},
         pc,
         frame,
         [ctor, parent_ctor, _computed_name | rest],
         gas,
         ctx
       ) do
    run({@op_define_class, [atom_idx, flags]}, pc, frame, [ctor, parent_ctor | rest], gas, ctx)
  end

  defp run(
         {@op_define_method, [atom_idx, flags]},
         pc,
         frame,
         [method_closure, target | rest],
         gas,
         ctx
       ) do
    name = Scope.resolve_atom(ctx, atom_idx)
    method_type = Bitwise.band(flags, 3)

    named_method =
      set_function_name(
        method_closure,
        case method_type do
          1 -> "get " <> name
          2 -> "set " <> name
          _ -> name
        end
      )

    needs_home =
      match?({:closure, _, %Bytecode.Function{need_home_object: true}}, named_method) or
        match?(%Bytecode.Function{need_home_object: true}, named_method)

    if needs_home do
      key = {:qb_home_object, home_object_key(named_method)}
      if key != {:qb_home_object, nil}, do: Process.put(key, target)
    end

    case method_type do
      1 -> Objects.put_getter(target, name, named_method)
      2 -> Objects.put_setter(target, name, named_method)
      _ -> Objects.put(target, name, named_method)
    end

    run(pc + 1, frame, [target | rest], gas, ctx)
  end

  defp run(
         {@op_define_method_computed, [_flags]},
         pc,
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

    run(pc + 1, frame, rest, gas, ctx)
  end

  # ── Generators ──

  defp run({@op_initial_yield, []}, pc, frame, stack, gas, ctx) do
    throw({:generator_yield, :undefined, pc + 1, frame, stack, gas, ctx})
  end

  defp run({@op_yield, []}, pc, frame, [val | rest], gas, ctx) do
    throw({:generator_yield, val, pc + 1, frame, rest, gas, ctx})
  end

  defp run({@op_yield_star, []}, pc, frame, [val | rest], gas, ctx) do
    throw({:generator_yield_star, val, pc + 1, frame, rest, gas, ctx})
  end

  defp run({@op_async_yield_star, []}, pc, frame, [val | rest], gas, ctx) do
    throw({:generator_yield_star, val, pc + 1, frame, rest, gas, ctx})
  end

  defp run({@op_await, []}, pc, frame, [val | rest], gas, ctx) do
    resolved = resolve_awaited(val)
    run(pc + 1, frame, [resolved | rest], gas, ctx)
  end

  defp run({@op_return_async, []}, _pc, _frame, [val | _], _gas, _ctx) do
    throw({:generator_return, val})
  end

  # ── with statement ──

  defp run({@op_with_get_var, [atom_idx, target, _is_with]}, pc, frame, [obj | rest], gas, ctx) do
    key = Scope.resolve_atom(ctx, atom_idx)

    if with_has_property?(obj, key) do
      run(target, frame, [Property.get(obj, key) | rest], gas, ctx)
    else
      run(pc + 1, frame, rest, gas, ctx)
    end
  end

  defp run(
         {@op_with_put_var, [atom_idx, target, _is_with]},
         pc,
         frame,
         [obj, val | rest],
         gas,
         ctx
       ) do
    key = Scope.resolve_atom(ctx, atom_idx)

    if with_has_property?(obj, key) do
      Objects.put(obj, key, val)
      run(target, frame, rest, gas, ctx)
    else
      run(pc + 1, frame, [val | rest], gas, ctx)
    end
  end

  defp run({@op_with_delete_var, [atom_idx, target, _is_with]}, pc, frame, [obj | rest], gas, ctx) do
    key = Scope.resolve_atom(ctx, atom_idx)

    if with_has_property?(obj, key) do
      case obj do
        {:obj, ref} -> Heap.update_obj(ref, %{}, &Map.delete(&1, key))
        _ -> :ok
      end

      run(target, frame, [true | rest], gas, ctx)
    else
      run(pc + 1, frame, rest, gas, ctx)
    end
  end

  defp run({@op_with_make_ref, [atom_idx, target, _is_with]}, pc, frame, [obj | rest], gas, ctx) do
    key = Scope.resolve_atom(ctx, atom_idx)

    if with_has_property?(obj, key) do
      run(target, frame, [key, obj | rest], gas, ctx)
    else
      run(pc + 1, frame, rest, gas, ctx)
    end
  end

  defp run({@op_with_get_ref, [atom_idx, target, _is_with]}, pc, frame, [obj | rest], gas, ctx) do
    key = Scope.resolve_atom(ctx, atom_idx)

    if with_has_property?(obj, key) do
      run(target, frame, [Property.get(obj, key), obj | rest], gas, ctx)
    else
      run(pc + 1, frame, rest, gas, ctx)
    end
  end

  defp run(
         {@op_with_get_ref_undef, [atom_idx, target, _is_with]},
         pc,
         frame,
         [obj | rest],
         gas,
         ctx
       ) do
    key = Scope.resolve_atom(ctx, atom_idx)

    if with_has_property?(obj, key) do
      run(target, frame, [Property.get(obj, key), :undefined | rest], gas, ctx)
    else
      run(pc + 1, frame, rest, gas, ctx)
    end
  end

  defp run({@op_for_await_of_start, []}, pc, frame, [obj | rest], gas, ctx) do
    {iter_obj, next_fn} =
      case obj do
        {:obj, ref} ->
          stored = Heap.get_obj(ref, [])

          cond do
            match?({:qb_arr, _}, stored) ->
              make_list_iterator(Heap.to_list({:obj, ref}))

            match?({:qb_arr, _}, stored) ->
              make_list_iterator(Heap.to_list({:obj, ref}))

            is_list(stored) ->
              make_list_iterator(stored)

            is_map(stored) and Map.has_key?(stored, "next") ->
              {obj, Property.get(obj, "next")}

            true ->
              {obj, :undefined}
          end

        _ ->
          {obj, :undefined}
      end

    run(pc + 1, frame, [0, next_fn, iter_obj | rest], gas, ctx)
  end

  # ── Catch-all for unimplemented opcodes ──

  defp run({op, args}, _pc, _frame, _stack, _gas, _ctx) do
    throw({:error, {:unimplemented_opcode, op, args}})
  end

  defp put_arg_value(ctx, idx, val, arg_buf) do
    padded = Tuple.to_list(arg_buf)

    padded =
      if idx < length(padded),
        do: padded,
        else: padded ++ List.duplicate(:undefined, idx + 1 - length(padded))

    %{ctx | arg_buf: List.to_tuple(List.replace_at(padded, idx, val))}
  end

  defp dispatch_call(fun, args, gas, ctx, this) do
    case fun do
      %Bytecode.Function{} = f -> invoke_function(f, args, gas, ctx)
      {:closure, _, %Bytecode.Function{}} = c -> invoke_closure(c, args, gas, ctx)
      {:bound, _, inner, _, _} -> invoke(inner, args, gas)
      other -> Builtin.call(other, args, this)
    end
  end

  # ── Tail calls ──

  defp tail_call([fun | _rest], 0, gas, ctx) do
    dispatch_call(fun, [], gas, ctx, nil)
  end

  defp tail_call([a0, fun | _], 1, gas, ctx) do
    dispatch_call(fun, [a0], gas, ctx, nil)
  end

  defp tail_call([a1, a0, fun | _], 2, gas, ctx) do
    dispatch_call(fun, [a0, a1], gas, ctx, nil)
  end

  defp tail_call(stack, argc, gas, ctx) do
    {args, [fun | _]} = Enum.split(stack, argc)
    dispatch_call(fun, Enum.reverse(args), gas, ctx, nil)
  end

  defp tail_call_method([fun, obj | _], 0, gas, ctx) do
    dispatch_call(fun, [], gas, %{ctx | this: obj}, obj)
  end

  defp tail_call_method([a0, fun, obj | _], 1, gas, ctx) do
    dispatch_call(fun, [a0], gas, %{ctx | this: obj}, obj)
  end

  defp tail_call_method(stack, argc, gas, ctx) do
    {args, [fun, obj | _]} = Enum.split(stack, argc)
    dispatch_call(fun, Enum.reverse(args), gas, %{ctx | this: obj}, obj)
  end

  # ── Closure construction ──

  defp build_closure(%Bytecode.Function{} = fun, locals, vrefs, l2v, %Context{} = ctx) do
    parent_arg_count = current_function_arg_count(ctx)

    captured =
      for cv <- fun.closure_vars, into: %{} do
        {closure_capture_key(cv), capture_var(cv, locals, vrefs, l2v, parent_arg_count)}
      end

    {:closure, captured, fun}
  end

  defp build_closure(other, _locals, _vrefs, _l2v, _ctx), do: other

  defp inherit_parent_vrefs({:closure, captured, %Bytecode.Function{} = f}, parent_vrefs)
       when is_tuple(parent_vrefs) do
    extra =
      for i <- 0..(tuple_size(parent_vrefs) - 1),
          not Map.has_key?(captured, closure_capture_key(2, i)),
          into: %{} do
        {closure_capture_key(2, i), elem(parent_vrefs, i)}
      end

    {:closure, Map.merge(extra, captured), f}
  end

  defp inherit_parent_vrefs(closure, _), do: closure

  defp capture_var(%{closure_type: 2, var_idx: idx}, _locals, vrefs, _l2v, _arg_count)
       when idx < tuple_size(vrefs) do
    case elem(vrefs, idx) do
      {:cell, _} = existing ->
        existing

      val ->
        ref = make_ref()
        Heap.put_cell(ref, val)
        {:cell, ref}
    end
  end

  defp capture_var(%{closure_type: 0, var_idx: idx}, locals, vrefs, l2v, arg_count) do
    capture_local_var(idx + arg_count, locals, vrefs, l2v)
  end

  defp capture_var(%{var_idx: idx}, locals, vrefs, l2v, _arg_count) do
    capture_local_var(idx, locals, vrefs, l2v)
  end

  defp capture_local_var(idx, locals, vrefs, l2v) do
    case Map.get(l2v, idx) do
      nil ->
        val = if idx < tuple_size(locals), do: elem(locals, idx), else: :undefined
        ref = make_ref()
        Heap.put_cell(ref, val)
        {:cell, ref}

      vref_idx ->
        case elem(vrefs, vref_idx) do
          {:cell, _} = existing ->
            existing

          _ ->
            val = elem(locals, idx)
            ref = make_ref()
            Heap.put_cell(ref, val)
            {:cell, ref}
        end
    end
  end

  defp closure_capture_key(%{closure_type: type, var_idx: idx}),
    do: closure_capture_key(type, idx)

  defp closure_capture_key(type, idx), do: {type, idx}

  defp current_function_arg_count(%Context{
         current_func: {:closure, _, %Bytecode.Function{arg_count: n}}
       }),
       do: n

  defp current_function_arg_count(%Context{current_func: %Bytecode.Function{arg_count: n}}), do: n
  defp current_function_arg_count(%Context{arg_buf: arg_buf}), do: tuple_size(arg_buf)

  defp ctor_var_refs(%Bytecode.Function{} = f, captured \\ %{}) do
    cell_ref = make_ref()
    Heap.put_cell(cell_ref, false)

    case f.closure_vars do
      [] -> [{:cell, cell_ref}]
      cvs -> Enum.map(cvs, &Map.get(captured, closure_capture_key(&1), {:cell, cell_ref}))
    end
  end

  # ── Function calls ──

  defp call_function(pc, frame, stack, 0, gas, ctx) do
    [fun | rest] = stack
    gas = check_gas(pc, frame, rest, gas, ctx)

    catch_js_throw_refresh_globals(pc, frame, rest, gas, ctx, fn ->
      dispatch_call(fun, [], gas, ctx, nil)
    end)
  end

  defp call_function(pc, frame, [a0, fun | rest], 1, gas, ctx) do
    gas = check_gas(pc, frame, rest, gas, ctx)

    catch_js_throw_refresh_globals(pc, frame, rest, gas, ctx, fn ->
      dispatch_call(fun, [a0], gas, ctx, nil)
    end)
  end

  defp call_function(pc, frame, [a1, a0, fun | rest], 2, gas, ctx) do
    gas = check_gas(pc, frame, rest, gas, ctx)

    catch_js_throw_refresh_globals(pc, frame, rest, gas, ctx, fn ->
      dispatch_call(fun, [a0, a1], gas, ctx, nil)
    end)
  end

  defp call_function(pc, frame, [a2, a1, a0, fun | rest], 3, gas, ctx) do
    gas = check_gas(pc, frame, rest, gas, ctx)

    catch_js_throw_refresh_globals(pc, frame, rest, gas, ctx, fn ->
      dispatch_call(fun, [a0, a1, a2], gas, ctx, nil)
    end)
  end

  defp call_function(pc, frame, stack, argc, gas, ctx) do
    {args, [fun | rest]} = Enum.split(stack, argc)
    gas = check_gas(pc, frame, rest, gas, ctx)

    catch_js_throw_refresh_globals(pc, frame, rest, gas, ctx, fn ->
      dispatch_call(fun, Enum.reverse(args), gas, ctx, nil)
    end)
  end

  defp call_method(pc, frame, [fun, obj | rest], 0, gas, ctx) do
    gas = check_gas(pc, frame, rest, gas, ctx)
    method_ctx = %{ctx | this: obj}

    catch_js_throw_refresh_globals(pc, frame, rest, gas, ctx, fn ->
      dispatch_call(fun, [], gas, method_ctx, obj)
    end)
  end

  defp call_method(pc, frame, [a0, fun, obj | rest], 1, gas, ctx) do
    gas = check_gas(pc, frame, rest, gas, ctx)
    method_ctx = %{ctx | this: obj}

    catch_js_throw_refresh_globals(pc, frame, rest, gas, ctx, fn ->
      dispatch_call(fun, [a0], gas, method_ctx, obj)
    end)
  end

  defp call_method(pc, frame, [a1, a0, fun, obj | rest], 2, gas, ctx) do
    gas = check_gas(pc, frame, rest, gas, ctx)
    method_ctx = %{ctx | this: obj}

    catch_js_throw_refresh_globals(pc, frame, rest, gas, ctx, fn ->
      dispatch_call(fun, [a0, a1], gas, method_ctx, obj)
    end)
  end

  defp call_method(pc, frame, [a2, a1, a0, fun, obj | rest], 3, gas, ctx) do
    gas = check_gas(pc, frame, rest, gas, ctx)
    method_ctx = %{ctx | this: obj}

    catch_js_throw_refresh_globals(pc, frame, rest, gas, ctx, fn ->
      dispatch_call(fun, [a0, a1, a2], gas, method_ctx, obj)
    end)
  end

  defp call_method(pc, frame, stack, argc, gas, ctx) do
    gas = check_gas(pc, frame, stack, gas, ctx)
    {args, [fun, obj | rest]} = Enum.split(stack, argc)
    method_ctx = %{ctx | this: obj}

    catch_js_throw_refresh_globals(pc, frame, rest, gas, ctx, fn ->
      dispatch_call(fun, Enum.reverse(args), gas, method_ctx, obj)
    end)
  end

  defp invoke_function(%Bytecode.Function{} = fun, args, gas, ctx) do
    do_invoke(fun, {:closure, %{}, fun}, args, [], gas, ctx)
  end

  defp invoke_closure({:closure, captured, %Bytecode.Function{} = fun} = self, args, gas, ctx) do
    var_refs =
      for cv <- fun.closure_vars do
        Map.get(captured, closure_capture_key(cv), :undefined)
      end

    do_invoke(fun, self, args, var_refs, gas, ctx)
  end

  defp do_invoke(%Bytecode.Function{} = fun, self_ref, args, var_refs, gas, ctx) do
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

        fn_atoms = Process.get({:qb_fn_atoms, fun.byte_code}, Heap.get_atoms())
        Heap.put_atoms(fn_atoms)

        inner_ctx = %{
          ctx
          | current_func: self_ref,
            arg_buf: List.to_tuple(args),
            catch_stack: [],
            atoms: fn_atoms
        }

        prev_ctx = Heap.get_ctx()
        Heap.put_ctx(inner_ctx)

        push_active_frame(self_ref)

        try do
          case fun.func_kind do
            @func_generator -> Generator.invoke(frame, gas, inner_ctx)
            @func_async -> Generator.invoke_async(frame, gas, inner_ctx)
            @func_async_generator -> Generator.invoke_async_generator(frame, gas, inner_ctx)
            _ -> run(0, frame, [], gas, inner_ctx)
          end
        after
          pop_active_frame()
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
  def invoke_callback(fun, args) do
    case fun do
      %Bytecode.Function{} = f ->
        invoke_function(f, args, active_ctx().gas, active_ctx())

      {:closure, _, %Bytecode.Function{}} = c ->
        invoke_closure(c, args, active_ctx().gas, active_ctx())

      _ ->
        try do
          Builtin.call(fun, args, nil)
        catch
          {:js_throw, _} -> List.first(args, :undefined)
        end
    end
  end
end
