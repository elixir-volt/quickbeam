defmodule QuickBEAM.VM.Interpreter.Ops.Calls do
  @moduledoc "Function creation, call, and constructor opcodes."

  @doc "Installs the Function creation, call, and constructor opcodes helpers into the caller module."
  defmacro __using__(_opts) do
    quote location: :keep do
      alias QuickBEAM.VM.{Heap, Invocation, Names}
      alias QuickBEAM.VM.Interpreter.{ClosureBuilder, Context, Frame}
      alias QuickBEAM.VM.Semantics.Values
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

            case proxy_construct_result(ctx, ctor, new_target, rev_args) do
              {:ok, result} ->
                result

              :not_proxy_constructor ->
                construct_non_proxy(ctor, new_target, rev_args, gas, ctx)
            end
          end,
          true
        )
      end

      defp proxy_construct_result(ctx, {:obj, ref} = ctor, new_target, args) do
        case Heap.get_obj(ref, %{}) do
          %{proxy_target() => _target, proxy_handler() => _handler} ->
            {:ok, QuickBEAM.VM.Invocation.construct_runtime(ctx, ctor, new_target, args)}

          _ ->
            :not_proxy_constructor
        end
      end

      defp proxy_construct_result(_ctx, _ctor, _new_target, _args), do: :not_proxy_constructor

      defp bound_new_target({:bound, _, _inner, target, _} = ctor, new_target),
        do: if(new_target == ctor, do: target, else: new_target)

      defp bound_new_target(_ctor, new_target), do: new_target

      defp constructor_target({:closure, _, %QuickBEAM.VM.Function{} = f}), do: f
      defp constructor_target(%QuickBEAM.VM.Function{} = f), do: f
      defp constructor_target({:bound, _, inner, _, _}), do: constructor_target(inner)
      defp constructor_target({:builtin, _, _} = builtin), do: builtin
      defp constructor_target(_), do: nil

      defp constructor_prototype(new_target) do
        case Get.get(new_target, "prototype") do
          {:obj, _} = proto -> proto
          %QuickBEAM.VM.Function{} = proto -> proto
          {:closure, _, %QuickBEAM.VM.Function{}} = proto -> proto
          {:bound, _, _, _, _} = proto -> proto
          {:builtin, _, _} = proto -> proto
          _ -> nil
        end
      end

      defp prevalidate_builtin_construct_args!({:builtin, name, _}, args)
           when name in ["ArrayBuffer", "SharedArrayBuffer"],
           do: QuickBEAM.VM.Runtime.ArrayBuffer.prevalidate_construct_args!(args)

      defp prevalidate_builtin_construct_args!(_ctor, _args), do: :ok

      defp construct_non_proxy(ctor, new_target, rev_args, gas, ctx) do
        raw_ctor =
          case ctor do
            {:closure, _, %QuickBEAM.VM.Function{} = f} ->
              f

            {:bound, _, inner, _, _} ->
              inner

            %QuickBEAM.VM.Function{} = f ->
              f

            {:builtin, name, cb} = builtin when is_function(cb) ->
              case QuickBEAM.VM.Builtin.metadata_for(builtin) do
                %QuickBEAM.VM.Builtin.Meta{constructable?: false} ->
                  JSThrow.type_error!("#{name} is not a constructor")

                _ ->
                  ctor
              end

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
          %QuickBEAM.VM.Function{func_kind: fk}
          when fk in [@func_generator, @func_async_generator] ->
            name = raw_ctor.name || "anonymous"
            JSThrow.type_error!("#{name} is not a constructor")

          %QuickBEAM.VM.Function{has_prototype: false, name: name} = fun ->
            unless class_constructor_source?(fun) do
              JSThrow.type_error!("#{name || "function"} is not a constructor")
            end

          _ ->
            :ok
        end

        prevalidate_builtin_construct_args!(raw_ctor, rev_args)

        this_ref = make_ref()

        raw_new_target = constructor_target(new_target)

        proto =
          if raw_new_target != nil and raw_new_target != raw_ctor do
            constructor_prototype(new_target) ||
              QuickBEAM.VM.Realm.default_prototype(raw_ctor, raw_new_target) ||
              Heap.get_class_proto(raw_new_target) || Heap.get_class_proto(raw_ctor) ||
              Heap.get_or_create_prototype(ctor)
          else
            constructor_prototype(new_target) || Heap.get_class_proto(raw_ctor) ||
              Heap.get_or_create_prototype(ctor)
          end

        derived_constructor? =
          match?(%QuickBEAM.VM.Function{is_derived_class_constructor: true}, raw_ctor)

        pending_private_brand? =
          derived_constructor? or
            match?(%QuickBEAM.VM.Function{is_derived_class_constructor: true}, raw_new_target)

        init = if proto, do: %{proto() => proto}, else: %{}

        Heap.put_obj(this_ref, init)
        fresh_this = {:obj, this_ref}
        Heap.put_pending_private_brand(fresh_this, pending_private_brand?)

        this_obj =
          if derived_constructor? do
            {:uninitialized, fresh_this}
          else
            fresh_this
          end

        ctor_ctx =
          Context.mark_dirty(%{
            ctx
            | this: this_obj,
              new_target: bound_new_target(ctor, new_target)
          })

        result =
          case ctor do
            %QuickBEAM.VM.Function{} = f ->
              do_invoke(
                f,
                {:closure, %{}, f},
                rev_args,
                ClosureBuilder.ctor_var_refs(f),
                gas,
                ctor_ctx
              )

            {:closure, captured, %QuickBEAM.VM.Function{} = f} ->
              do_invoke(
                f,
                {:closure, captured, f},
                rev_args,
                ClosureBuilder.ctor_var_refs(f, captured),
                gas,
                ctor_ctx
              )

            {:bound, _, _, orig_fun, bound_args} ->
              Invocation.construct_runtime(
                ctx,
                orig_fun,
                bound_new_target(ctor, new_target),
                bound_args ++ rev_args
              )

            {:builtin, name, cb} when is_function(cb, 2) ->
              obj = cb.(rev_args, this_obj)

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

            if is_map(rmap) and not Map.has_key?(rmap, proto()) do
              Heap.put_obj(rref, Map.put(rmap, proto(), proto2))
            end

          _ ->
            :ok
        end

        result
      end

      defp run({@op_init_ctor, []}, pc, frame, stack, gas, %Context{arg_buf: arg_buf} = ctx) do
        raw =
          case ctx.current_func do
            {:closure, _, %QuickBEAM.VM.Function{} = f} -> f
            %QuickBEAM.VM.Function{} = f -> f
            other -> other
          end

        parent = Heap.get_parent_ctor(raw)
        args = Tuple.to_list(arg_buf)

        already_bound_this? = match?({:obj, _}, ctx.this)

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

            %QuickBEAM.VM.Function{} = f ->
              do_invoke(
                f,
                {:closure, %{}, f},
                args,
                ClosureBuilder.ctor_var_refs(f),
                gas,
                parent_ctx
              )

            {:closure, captured, %QuickBEAM.VM.Function{} = f} ->
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

        if already_bound_this? and parent != nil do
          JSThrow.reference_error!("this is already initialized")
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

      defp class_constructor_source?(%QuickBEAM.VM.Function{source: source})
           when is_binary(source) do
        source |> String.trim_leading() |> String.starts_with?("class")
      end

      defp class_constructor_source?(_), do: false
    end
  end
end
