defmodule QuickBEAM.VM.Interpreter.Ops.Objects do
  @moduledoc "Object creation, field access, array element access, and misc object stubs."

  defmacro __using__(_opts) do
    quote location: :keep do
      import Bitwise, only: [&&&: 2, bsr: 2]
      alias QuickBEAM.VM.{Builtin, Bytecode, Heap, Invocation, Names, Runtime}
      alias QuickBEAM.VM.Interpreter.{Context, Values}
      alias QuickBEAM.VM.ObjectModel.{Class, Copy, Delete, Functions, Get, Private, Put}

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
          [Get.get(obj, Names.resolve_atom(ctx, atom_idx)) | rest],
          gas,
          ctx
        )
      end

      defp run({@op_put_field, [atom_idx]}, pc, frame, [val, obj | rest], gas, ctx) do
        name = Names.resolve_atom(ctx, atom_idx)

        result =
          try do
            Put.put(obj, name, val)
            :ok
          catch
            {:js_throw, error} -> {:throw, error}
          end

        case result do
          :ok ->
            ctx = sync_global_this_write(ctx, obj, name, val)
            run(pc + 1, frame, rest, gas, ctx)

          {:throw, error} ->
            throw_or_catch(frame, error, gas, ctx)
        end
      end

      defp run({@op_define_field, [atom_idx]}, pc, frame, [val, obj | rest], gas, ctx) do
        try do
          Put.put(obj, Names.resolve_atom(ctx, atom_idx), val)
          run(pc + 1, frame, [obj | rest], gas, ctx)
        catch
          {:js_throw, error} ->
            ctx = Heap.get_ctx() || ctx
            throw_or_catch(frame, error, gas, ctx)
        end
      end

      defp run({@op_get_array_el, []}, pc, frame, [idx, obj | rest], gas, ctx) do
        try do
          run(pc + 1, frame, [Put.get_element(obj, idx) | rest], gas, ctx)
        catch
          {:js_throw, error} ->
            ctx = Heap.get_ctx() || ctx
            throw_or_catch(frame, error, gas, ctx)
        end
      end

      defp run({@op_put_array_el, []}, pc, frame, [val, idx, obj | rest], gas, ctx) do
        try do
          Put.put_element(obj, idx, val)

          ctx =
            case Heap.get_persistent_globals() do
              nil -> ctx
              p when map_size(p) == 0 -> ctx
              p -> Context.mark_dirty(%{ctx | globals: Map.merge(ctx.globals, p)})
            end

          run(pc + 1, frame, rest, gas, ctx)
        catch
          {:js_throw, error} ->
            ctx = Heap.get_ctx() || ctx
            throw_or_catch(frame, error, gas, ctx)
        end
      end

      defp run({@op_get_super_value, []}, pc, frame, [key, proto, this_obj | rest], gas, ctx) do
        val = Class.get_super_value(proto, this_obj, key)
        run(pc + 1, frame, [val | rest], gas, ctx)
      end

      defp run({@op_put_super_value, []}, pc, frame, [val, key, proto_obj, this_obj | rest], gas, ctx) do
        try do
          Class.put_super_value(proto_obj, this_obj, key, val)
          run(pc + 1, frame, rest, gas, ctx)
        catch
          {:js_throw, error} ->
            ctx = Heap.get_ctx() || ctx
            throw_or_catch(frame, error, gas, ctx)
        end
      end

      defp run({@op_get_private_field, []}, pc, frame, [key, obj | rest], gas, ctx) do
        case Private.get_field(obj, key) do
          :missing -> throw_or_catch(frame, Private.brand_error(), gas, ctx)
          val -> run(pc + 1, frame, [val | rest], gas, ctx)
        end
      end

      defp run({@op_put_private_field, []}, pc, frame, [key, val, obj | rest], gas, ctx) do
        case Private.put_field!(obj, key, val) do
          :ok -> run(pc + 1, frame, rest, gas, ctx)
          :error -> throw_or_catch(frame, Private.brand_error(), gas, ctx)
        end
      end

      defp run({@op_define_private_field, []}, pc, frame, [val, key, obj | rest], gas, ctx) do
        case Private.define_field!(obj, key, val) do
          :ok -> run(pc + 1, frame, rest, gas, ctx)
          :error -> throw_or_catch(frame, Private.brand_error(), gas, ctx)
        end
      end

      defp run({@op_private_in, []}, pc, frame, [key, obj | rest], gas, ctx) do
        result = Private.has_field?(obj, key) or Private.has_brand?(obj, key)
        run(pc + 1, frame, [result | rest], gas, ctx)
      end

      defp run({@op_get_length, []}, pc, frame, [obj | rest], gas, ctx) do
        run(pc + 1, frame, [Get.length_of(obj) | rest], gas, ctx)
      end

      defp run({@op_array_from, [argc]}, pc, frame, stack, gas, ctx) do
        {elems, rest} = Enum.split(stack, argc)
        ref = make_ref()
        Heap.put_obj(ref, Enum.reverse(elems))
        run(pc + 1, frame, [{:obj, ref} | rest], gas, ctx)
      end

      defp run({@op_get_field2, [atom_idx]}, __pc, frame, [obj | _rest], gas, ctx)
           when obj == nil or obj == :undefined do
        throw_null_property_error(frame, obj, atom_idx, gas, ctx)
      end

      defp run({@op_get_field2, [atom_idx]}, pc, frame, [obj | rest], gas, ctx) do
        val = Get.get(obj, Names.resolve_atom(ctx, atom_idx))
        run(pc + 1, frame, [val, obj | rest], gas, ctx)
      end

      # ── Array element access (2-element push) ──

      defp run({@op_get_array_el2, []}, pc, frame, [idx, obj | rest], gas, ctx) do
        run(pc + 1, frame, [Get.get(obj, idx), obj | rest], gas, ctx)
      end

      # ── Misc / no-op ──

      defp run({@op_nop, []}, pc, frame, stack, gas, ctx),
        do: run(pc + 1, frame, stack, gas, ctx)

      defp run({@op_to_object, []}, _pc, frame, [nil | _rest], gas, ctx) do
        throw_or_catch(frame, Heap.make_error("Cannot convert null to object", "TypeError"), gas, ctx)
      end

      defp run({@op_to_object, []}, _pc, frame, [:undefined | _rest], gas, ctx) do
        throw_or_catch(
          frame,
          Heap.make_error("Cannot convert undefined to object", "TypeError"),
          gas,
          ctx
        )
      end

      defp run({@op_to_object, []}, pc, frame, stack, gas, ctx),
        do: run(pc + 1, frame, stack, gas, ctx)

      defp run({@op_to_propkey, []}, pc, frame, stack, gas, ctx),
        do: run(pc + 1, frame, stack, gas, ctx)

      defp run({@op_to_propkey2, []}, _pc, frame, [_key, obj | _rest], gas, ctx)
           when obj == nil or obj == :undefined do
        nullish = if obj == nil, do: "null", else: "undefined"

        throw_or_catch(
          frame,
          Heap.make_error("Cannot read properties of #{nullish}", "TypeError"),
          gas,
          ctx
        )
      end

      defp run({@op_to_propkey2, []}, pc, frame, stack, gas, ctx),
        do: run(pc + 1, frame, stack, gas, ctx)

      defp run({@op_check_ctor, []}, pc, frame, stack, gas, ctx),
        do: run(pc + 1, frame, stack, gas, ctx)

      defp run({@op_check_ctor_return, []}, pc, frame, [val | rest], gas, ctx) do
        case Class.check_ctor_return(val) do
          {replace_with_this?, checked_val} ->
            run(pc + 1, frame, [replace_with_this?, checked_val | rest], gas, ctx)

          :error ->
            throw_or_catch(
              frame,
              Heap.make_error(
                "Derived constructors may only return object or undefined",
                "TypeError"
              ),
              gas,
              ctx
            )
        end
      end

      defp run({@op_set_name, [atom_idx]}, pc, frame, [fun | rest], gas, ctx) do
        named = Functions.set_name_atom(fun, atom_idx, ctx.atoms)
        run(pc + 1, frame, [named | rest], gas, ctx)
      end

      defp run({@op_is_undefined, []}, pc, frame, [a | rest], gas, ctx),
        do: run(pc + 1, frame, [a == :undefined | rest], gas, ctx)

      defp run({@op_is_null, []}, pc, frame, [a | rest], gas, ctx),
        do: run(pc + 1, frame, [a == nil | rest], gas, ctx)

      defp run({@op_is_undefined_or_null, []}, pc, frame, [a | rest], gas, ctx),
        do: run(pc + 1, frame, [a == :undefined or a == nil | rest], gas, ctx)

      defp run({@op_invalid, []}, _pc, _frame, _stack, _gas, _ctx),
        do: throw({:error, :invalid_opcode})

      # ── Misc stubs ──

      defp run({@op_set_home_object, []}, pc, frame, [method, target | _] = stack, gas, ctx) do
        Functions.put_home_object(method, target)
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
             %Context{arg_buf: arg_buf, current_func: current_func, home_object: home_object} =
               ctx
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
              if home_object == :undefined do
                Functions.current_home_object(current_func)
              else
                home_object
              end

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

      defp run({@op_throw_error, []}, _pc, frame, [val | _], gas, ctx),
        do: throw_or_catch(frame, val, gas, ctx)

      defp run({@op_throw_error, [atom_idx, reason]}, __pc, frame, _stack, gas, ctx) do
        name = Names.resolve_atom(ctx, atom_idx)
        {error_type, message} = QuickBEAM.VM.Compiler.RuntimeHelpers.throw_error_message(name, reason)
        throw_or_catch(frame, Heap.make_error(message, error_type), gas, ctx)
      end

      defp run({@op_set_name_computed, []}, pc, frame, [fun, name_val | rest], gas, ctx) do
        named = Functions.set_name_computed(fun, name_val)
        run(pc + 1, frame, [named, name_val | rest], gas, ctx)
      end

      defp run({@op_copy_data_properties, []}, pc, frame, [source, target | rest], gas, ctx) do
        try do
          QuickBEAM.VM.ObjectModel.Copy.copy_data_properties(target, source)
        catch
          {:js_throw, error} -> throw_or_catch(frame, error, gas, ctx)
        end

        ctx =
          case Heap.get_persistent_globals() do
            nil -> ctx
            p when map_size(p) == 0 -> ctx
            p -> Context.mark_dirty(%{ctx | globals: Map.merge(ctx.globals, p)})
          end

        run(pc + 1, frame, [source, target | rest], gas, ctx)
      end

      defp run(
             {@op_get_super, []},
             pc,
             frame,
             [func | rest],
             gas,
             %Context{home_object: home_object, super: super} = ctx
           ) do
        val = if func == home_object, do: super, else: Class.get_super(func)
        run(pc + 1, frame, [val | rest], gas, ctx)
      end

      defp run({@op_push_this, []}, _pc, frame, _stack, gas, %Context{this: this} = ctx)
           when this == :uninitialized or
                  (is_tuple(this) and tuple_size(this) == 2 and elem(this, 0) == :uninitialized) do
        throw_or_catch(frame, Heap.make_error("this is not initialized", "ReferenceError"), gas, ctx)
      end

      defp run({@op_push_this, []}, pc, frame, stack, gas, %Context{this: this} = ctx)
           when this == :undefined or this == nil do
        global_this = Map.get(ctx.globals, "globalThis", :undefined)
        run(pc + 1, frame, [global_this | stack], gas, ctx)
      end

      defp run({@op_push_this, []}, pc, frame, stack, gas, %Context{this: this} = ctx) do
        run(pc + 1, frame, [this | stack], gas, ctx)
      end

      defp run({@op_private_symbol, [atom_idx]}, pc, frame, stack, gas, ctx) do
        name = Names.resolve_atom(ctx, atom_idx)
        run(pc + 1, frame, [Private.private_symbol(name) | stack], gas, ctx)
      end

      # ── Argument mutation ──

      defp run({op, [idx]}, pc, frame, [val | rest], gas, %Context{} = ctx)
           when op in [@op_put_arg, @op_put_arg0, @op_put_arg1, @op_put_arg2, @op_put_arg3] do
        run_arg_update(pc, frame, rest, gas, ctx, idx, val)
      end

      defp run({op, [idx]}, pc, frame, [val | rest], gas, %Context{} = ctx)
           when op in [@op_set_arg, @op_set_arg0, @op_set_arg1, @op_set_arg2, @op_set_arg3] do
        run_arg_update(pc, frame, [val | rest], gas, ctx, idx, val)
      end

      # ── instanceof ──

      defp run({@op_instanceof, []}, pc, frame, [ctor, obj | rest], gas, ctx) do
        catch_and_dispatch(pc, frame, rest, gas, ctx, fn ->
          has_instance = Get.get(ctor, {:symbol, "Symbol.hasInstance"})

          if has_instance != :undefined and has_instance != nil and function_value?(has_instance) do
            result = Invocation.invoke_with_receiver(has_instance, [obj], Runtime.gas_budget(), ctor)
            Values.truthy?(result)
          else
            is_obj = function_value?(ctor) or is_object(ctor)

            unless is_obj do
              throw(
                {:js_throw,
                 Heap.make_error("Right-hand side of instanceof is not callable", "TypeError")}
              )
            end

            is_callable_ctor =
              case ctor do
                {:builtin, _, map} when is_map(map) -> false
                {:obj, ref} -> Get.get({:obj, ref}, "call") != :undefined
                _ -> true
              end

            unless is_callable_ctor do
              throw(
                {:js_throw,
                 Heap.make_error("Right-hand side of instanceof is not callable", "TypeError")}
              )
            end

            obj_is_object = is_object(obj) or function_value?(obj)

            if obj_is_object do
              ctor_proto = Get.get(ctor, "prototype")

              case ctor_proto do
                {:obj, _} ->
                  case obj do
                    {:obj, ref} ->
                      ctor_name =
                        case ctor do
                          {:builtin, n, _} -> n
                          _ -> nil
                        end

                      if ctor_name in ["Array", "Object"] do
                        data = Heap.get_obj(ref)
                        is_arr = match?({:qb_arr, _}, data) or is_list(data)

                        if (is_arr and ctor_name == "Array") or ctor_name == "Object",
                          do: true,
                          else: check_prototype_chain(obj, ctor_proto)
                      else
                        check_prototype_chain(obj, ctor_proto)
                      end

                    _ ->
                      is_fn = function_value?(obj)

                      if is_fn do
                        ctor_name =
                          case ctor do
                            {:builtin, name, _} -> name
                            _ -> nil
                          end

                        ctor_name == "Function" or ctor_name == "Object"
                      else
                        false
                      end
                  end

                _ ->
                  if is_object(ctor) do
                    throw(
                      {:js_throw,
                       Heap.make_error(
                         "Right-hand side of instanceof is not callable",
                         "TypeError"
                       )}
                    )
                  else
                    throw(
                      {:js_throw,
                       Heap.make_error(
                         "Function has non-object prototype '#{Values.stringify(ctor_proto)}' in instanceof check",
                         "TypeError"
                       )}
                    )
                  end
              end
            else
              false
            end
          end
        end, true)
      end

      # ── delete ──

      defp run({@op_delete, []}, __pc, frame, [key, obj | _rest], gas, ctx)
           when obj == nil or obj == :undefined do
        nullish = if obj == nil, do: "null", else: "undefined"

        error =
          Heap.make_error(
            "Cannot delete properties of #{nullish} (deleting '#{Values.stringify(key)}')",
            "TypeError"
          )

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
                key_str = if is_binary(key), do: key, else: Values.stringify(key)

                cond do
                  key_str == "length" ->
                    false

                  match?({:qb_arr, _}, map) or is_list(map) ->
                    case Integer.parse(key_str) do
                      {idx, ""} when idx >= 0 ->
                        Heap.array_set(ref, idx, :undefined)
                        true

                      _ ->
                        true
                    end

                  true ->
                    true
                end
              end

            {:closure, _, _} = fun ->
              delete_static(fun, key)

            %Bytecode.Function{} = fun ->
              delete_static(fun, key)

            {:builtin, _, _} = fun ->
              delete_static(fun, key)

            _ ->
              true
          end

        run(pc + 1, frame, [result | rest], gas, ctx)
      end

      @non_configurable_globals MapSet.new(~w(NaN undefined Infinity globalThis))

      defp run({@op_delete_var, [atom_idx]}, pc, frame, stack, gas, ctx) do
        name = Names.resolve_atom(ctx.atoms, atom_idx)
        builtins = Heap.get_builtin_names() || MapSet.new()

        result =
          case Map.fetch(ctx.globals, name) do
            {:ok, _} ->
              if MapSet.member?(@non_configurable_globals, name) do
                false
              else
                MapSet.member?(builtins, name)
              end

            :error ->
              true
          end

        run(pc + 1, frame, [result | stack], gas, ctx)
      end

      # ── in operator ──

      defp run({@op_in, []}, pc, frame, [obj, key | rest], gas, ctx) do
        catch_and_dispatch(pc, frame, rest, gas, ctx, fn ->
          unless is_object(obj) or match?({:builtin, _, _}, obj) or
                   is_closure(obj) or match?(%Bytecode.Function{}, obj) or
                   match?({:bound, _, _, _, _}, obj) or match?({:qb_arr, _}, obj) or
                   is_list(obj) or is_map(obj) do
            throw(
              {:js_throw,
               Heap.make_error(
                 "Cannot use 'in' operator to search for '#{Values.stringify(key)}' in #{Values.stringify(obj)}",
                 "TypeError"
               )}
            )
          end

          coerced_key = if is_binary(key) or is_integer(key), do: key, else: Values.stringify(key)
          Put.has_property(obj, coerced_key)
        end, false)
      end

      # ── regexp literal ──

      defp run({@op_regexp, []}, pc, frame, [pattern, flags | rest], gas, ctx) do
        run(pc + 1, frame, [{:regexp, pattern, flags} | rest], gas, ctx)
      end

      # ── Object spread (copy_data_properties with mask) ──

      defp run({@op_copy_data_properties, [mask]}, pc, frame, stack, gas, ctx) do
        target_idx = mask &&& 3
        source_idx = bsr(mask, 2) &&& 7
        exclude_idx = bsr(mask, 5) &&& 7
        target = Enum.at(stack, target_idx)
        source = Enum.at(stack, source_idx)
        exclude = Enum.at(stack, exclude_idx)

        try do
          Copy.copy_data_properties(target, source, exclude)

          ctx =
            case Heap.get_persistent_globals() do
              nil -> ctx
              p when map_size(p) == 0 -> ctx
              p -> Context.mark_dirty(%{ctx | globals: Map.merge(ctx.globals, p)})
            end

          run(pc + 1, frame, stack, gas, ctx)
        catch
          {:js_throw, error} ->
            ctx = Heap.get_ctx() || ctx
            throw_or_catch(frame, error, gas, ctx)
        end
      end
    end
  end
end
