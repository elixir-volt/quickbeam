defmodule QuickBEAM.VM.Interpreter.Ops.Calls do
  @moduledoc "Function creation, call, and constructor opcodes."

  @doc "Installs the Function creation, call, and constructor opcodes helpers into the caller module."
  defmacro __using__(_opts) do
    quote location: :keep do
      alias QuickBEAM.VM.{Bytecode, Heap, Names}
      alias QuickBEAM.VM.Interpreter.{ClosureBuilder, Context, Frame, Values}
      alias QuickBEAM.VM.JSThrow
      alias QuickBEAM.VM.ObjectModel.{Class, Get}

      # ── Function creation / calls ──

      defp run({op, [idx]}, pc, frame, stack, gas, ctx)
           when op in [@op_fclosure, @op_fclosure8] do
        fun = Names.resolve_const(elem(frame, Frame.constants()), idx)
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

      # ── new / constructor ──

      defp run({@op_call_constructor, [argc]}, pc, frame, stack, gas, ctx) do
        {args, [new_target, ctor | rest]} = Enum.split(stack, argc)

        gas = check_gas(pc, frame, rest, gas, ctx)

        catch_and_dispatch(
          pc,
          frame,
          rest,
          gas,
          ctx,
          fn ->
            rev_args = Enum.reverse(args)

            raw_ctor =
              case ctor do
                {:closure, _, %Bytecode.Function{} = f} ->
                  f

                {:bound, _, inner, _, _} ->
                  inner

                %Bytecode.Function{} = f ->
                  f

                {:builtin, _, cb} when is_function(cb) ->
                  ctor

                {:builtin, _, map} when is_map(map) ->
                  throw(
                    {:js_throw,
                     Heap.make_error(
                       "#{Values.stringify(ctor)} is not a constructor",
                       "TypeError"
                     )}
                  )

                _ ->
                  throw(
                    {:js_throw,
                     Heap.make_error(
                       "#{Values.stringify(ctor)} is not a constructor",
                       "TypeError"
                     )}
                  )
              end

            case raw_ctor do
              %Bytecode.Function{func_kind: fk}
              when fk in [@func_generator, @func_async_generator] ->
                name = raw_ctor.name || "anonymous"
                JSThrow.type_error!("#{name} is not a constructor")

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

            init = if proto, do: %{proto() => proto}, else: %{}
            Heap.put_obj(this_ref, init)
            fresh_this = {:obj, this_ref}

            this_obj =
              case raw_ctor do
                %Bytecode.Function{is_derived_class_constructor: true} ->
                  {:uninitialized, fresh_this}

                _ ->
                  fresh_this
              end

            ctor_ctx = Context.mark_dirty(%{ctx | this: this_obj, new_target: new_target})

            result =
              case ctor do
                %Bytecode.Function{} = f ->
                  do_invoke(
                    f,
                    {:closure, %{}, f},
                    rev_args,
                    ClosureBuilder.ctor_var_refs(f),
                    gas,
                    ctor_ctx
                  )

                {:closure, captured, %Bytecode.Function{} = f} ->
                  do_invoke(
                    f,
                    {:closure, captured, f},
                    rev_args,
                    ClosureBuilder.ctor_var_refs(f, captured),
                    gas,
                    ctor_ctx
                  )

                {:bound, _, _, orig_fun, bound_args} ->
                  all_args = bound_args ++ rev_args

                  case orig_fun do
                    %Bytecode.Function{} = f ->
                      do_invoke(
                        f,
                        {:closure, %{}, f},
                        all_args,
                        ClosureBuilder.ctor_var_refs(f),
                        gas,
                        ctor_ctx
                      )

                    {:closure, captured, %Bytecode.Function{} = f} ->
                      do_invoke(
                        f,
                        {:closure, captured, f},
                        all_args,
                        ClosureBuilder.ctor_var_refs(f, captured),
                        gas,
                        ctor_ctx
                      )

                    {:builtin, _, cb} when is_function(cb, 2) ->
                      cb.(all_args, this_obj)

                    _ ->
                      this_obj
                  end

                {:builtin, name, cb} when is_function(cb, 2) ->
                  obj = cb.(rev_args, this_obj)

                  if name in ~w(Number String Boolean) do
                    existing = Heap.get_obj(this_ref, %{})
                    val_fn = {:builtin, "valueOf", fn _, _ -> obj end}

                    to_str_fn =
                      {:builtin, "toString", fn _, _ -> Values.stringify(obj) end}

                    Heap.put_obj(
                      this_ref,
                      existing
                      |> Map.merge(%{"valueOf" => val_fn, "toString" => to_str_fn})
                      |> Map.put(primitive_value(), obj)
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

            result = Class.coalesce_this_result(result, this_obj)

            if match?({:uninitialized, _}, result) do
              JSThrow.reference_error!("this is not initialized")
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
          end,
          true
        )
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

        pending_this =
          case ctx.this do
            {:uninitialized, {:obj, _} = obj} -> obj
            {:obj, _} = obj -> obj
            _ -> ctx.this
          end

        parent_ctx = Context.mark_dirty(%{ctx | this: pending_this})

        result =
          case parent do
            nil ->
              pending_this

            %Bytecode.Function{} = f ->
              do_invoke(
                f,
                {:closure, %{}, f},
                args,
                ClosureBuilder.ctor_var_refs(f),
                gas,
                parent_ctx
              )

            {:closure, captured, %Bytecode.Function{} = f} ->
              do_invoke(
                f,
                {:closure, captured, f},
                args,
                ClosureBuilder.ctor_var_refs(f, captured),
                gas,
                parent_ctx
              )

            {:builtin, _name, cb} when is_function(cb, 2) ->
              cb.(args, pending_this)

            _ ->
              pending_this
          end

        result =
          case result do
            {:obj, _} = obj -> obj
            _ -> pending_this
          end

        run(pc + 1, frame, [result | stack], gas, Context.mark_dirty(%{ctx | this: result}))
      end

      # ── Spread/rest via apply ──

      defp run({@op_apply, [1]}, pc, frame, [arg_array, new_target, fun | rest], gas, ctx) do
        result = invoke_super_constructor(fun, new_target, apply_args(arg_array), gas, ctx)
        persistent = Heap.get_persistent_globals() || %{}

        refreshed =
          Context.mark_dirty(%{ctx | globals: Map.merge(ctx.globals, persistent), this: result})

        run(pc + 1, frame, [result | rest], gas, refreshed)
      end

      defp run({@op_apply, [_magic]}, pc, frame, [arg_array, this_obj, fun | rest], gas, ctx) do
        args = apply_args(arg_array)
        apply_ctx = Context.mark_dirty(%{ctx | this: this_obj})

        catch_and_dispatch(
          pc,
          frame,
          rest,
          gas,
          ctx,
          fn ->
            dispatch_call(fun, args, gas, apply_ctx, this_obj)
          end,
          true
        )
      end
    end
  end
end
