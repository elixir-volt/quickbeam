defmodule QuickBEAM.VM.Interpreter.Ops.Objects do
  @moduledoc "Object creation, field access, array element access, and misc object stubs."

  @doc "Installs the Object creation, field access, array element access, and misc object stubs helpers into the caller module."
  defmacro __using__(_opts) do
    quote location: :keep do
      alias QuickBEAM.VM.{
        Builtin,
        GlobalEnvironment,
        Heap,
        Invocation,
        Names,
        Runtime,
        RuntimeState
      }

      alias QuickBEAM.VM.Interpreter.{Context, Frame}
      alias QuickBEAM.VM.Semantics.Values

      alias QuickBEAM.VM.ObjectModel.{
        Class,
        Copy,
        Delete,
        Functions,
        Get,
        Private,
        PropertyKey,
        Put
      }

      alias QuickBEAM.VM.Operands.CopyDataProperties
      alias QuickBEAM.VM.Semantics.{Construction, PropertyAccess}

      # ── Objects ──

      defp run({@op_object, []}, pc, frame, stack, gas, ctx) do
        run(pc + 1, frame, [Construction.new_object() | stack], gas, ctx)
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
            PropertyAccess.set_property(ctx, obj, name, val)
            :ok
          catch
            {:js_throw, error} -> {:throw, error}
          end

        case result do
          :ok ->
            ctx =
              if QuickBEAM.VM.Execution.SetterState.invoked?(),
                do: ctx,
                else: sync_global_this_write(ctx, obj, name, val)

            ctx = refresh_persistent_globals(ctx)
            frame = sync_setter_globals_to_frame(frame, ctx)
            run(pc + 1, frame, rest, gas, ctx)

          {:throw, error} ->
            throw_or_catch(frame, error, gas, close_active_iterators_on_abrupt(rest, ctx))
        end
      end

      defp run({@op_define_field, [atom_idx]}, pc, frame, [val, obj | rest], gas, ctx) do
        try do
          Put.define_array_el(obj, Names.resolve_atom(ctx, atom_idx), val)
          run(pc + 1, frame, [obj | rest], gas, ctx)
        catch
          {:js_throw, error} ->
            ctx = RuntimeState.current() || ctx
            throw_or_catch(frame, error, gas, ctx)
        end
      end

      defp run({@op_get_array_el, []}, pc, frame, [idx, obj | rest], gas, ctx) do
        try do
          run(pc + 1, frame, [PropertyAccess.get_property(obj, idx) | rest], gas, ctx)
        catch
          {:js_throw, error} ->
            ctx = RuntimeState.current() || ctx
            throw_or_catch(frame, error, gas, ctx)
        end
      end

      defp run({@op_put_array_el, []}, pc, frame, [val, idx, obj | rest], gas, ctx) do
        try do
          PropertyAccess.set_property(ctx, obj, idx, val)

          ctx =
            case Heap.get_persistent_globals() do
              nil -> ctx
              p when map_size(p) == 0 -> ctx
              p -> Context.mark_dirty(%{ctx | globals: Map.merge(ctx.globals, p)})
            end

          frame = sync_setter_globals_to_frame(frame, ctx)
          run(pc + 1, frame, rest, gas, ctx)
        catch
          {:js_throw, error} ->
            ctx = RuntimeState.current() || ctx
            throw_or_catch(frame, error, gas, close_active_iterators_on_abrupt(rest, ctx))
        end
      end

      defp run({@op_get_super_value, []}, pc, frame, [key, proto, this_obj | rest], gas, ctx) do
        val = Class.get_super_value(proto, this_obj, key)
        run(pc + 1, frame, [val | rest], gas, ctx)
      end

      defp run(
             {@op_put_super_value, []},
             pc,
             frame,
             [val, key, proto_obj, this_obj | rest],
             gas,
             ctx
           ) do
        try do
          Class.put_super_value(proto_obj, this_obj, key, val)
          run(pc + 1, frame, rest, gas, ctx)
        catch
          {:js_throw, error} ->
            ctx = RuntimeState.current() || ctx
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
        values = Enum.reverse(elems)
        Heap.put_obj(ref, values)

        values
        |> Enum.with_index()
        |> Enum.each(fn {_value, index} ->
          Heap.put_prop_desc(ref, Integer.to_string(index), %{
            writable: true,
            enumerable: true,
            configurable: true
          })
        end)

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
        try do
          run(pc + 1, frame, [PropertyAccess.get_property(obj, idx), obj | rest], gas, ctx)
        catch
          {:js_throw, error} ->
            ctx = RuntimeState.current() || ctx
            throw_or_catch(frame, error, gas, ctx)
        end
      end

      # ── Misc / no-op ──

      defp run({@op_nop, []}, pc, frame, stack, gas, ctx),
        do: run(pc + 1, frame, stack, gas, ctx)

      defp run({@op_to_object, []}, _pc, frame, [nil | _rest], gas, ctx) do
        throw_or_catch(
          frame,
          Heap.make_error("Cannot convert null to object", "TypeError"),
          gas,
          ctx
        )
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

      defp run({@op_to_propkey, []}, pc, frame, [key | rest], gas, ctx) do
        try do
          prop_key = PropertyKey.to_property_key(key)

          run(
            pc + 1,
            frame,
            [prop_key | rest],
            gas,
            GlobalEnvironment.refresh(RuntimeState.current() || ctx)
          )
        catch
          {:js_throw, error} -> throw_or_catch(frame, error, gas, RuntimeState.current() || ctx)
        end
      end

      defp run({@op_to_propkey2, []}, pc, frame, [key, obj | rest], gas, ctx) do
        try do
          prop_key = PropertyAccess.to_property_key_for_access(obj, key)

          run(
            pc + 1,
            frame,
            [prop_key, obj | rest],
            gas,
            GlobalEnvironment.refresh(RuntimeState.current() || ctx)
          )
        catch
          {:js_throw, error} -> throw_or_catch(frame, error, gas, RuntimeState.current() || ctx)
        end
      end

      defp run({@op_check_ctor, []}, pc, frame, stack, gas, ctx),
        do: run(pc + 1, frame, stack, gas, ctx)

      defp run({@op_check_ctor_return, []}, pc, frame, [val | rest], gas, ctx) do
        case Construction.check_ctor_return(val) do
          {:ok, replace_with_this?, checked_val} ->
            run(pc + 1, frame, [replace_with_this?, checked_val | rest], gas, ctx)

          {:error, message} ->
            throw_or_catch(frame, Heap.make_error(message, "TypeError"), gas, ctx)
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

            if is_map(map) and (is_object(proto) or proto == nil) do
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
            type when type in [0, 1] ->
              special_object_arguments_object(ctx, frame, arg_buf, current_func)

            _ ->
              Construction.special_object(
                type,
                current_func,
                arg_buf,
                ctx.new_target,
                home_object
              )
          end

        ctx =
          if type in [0, 1] do
            %{
              ctx
              | globals: Map.put(ctx.globals, {:qb_arguments_object, current_func, arg_buf}, val)
            }
          else
            ctx
          end

        run(pc + 1, frame, [val | stack], gas, ctx)
      end

      defp special_object_arguments_object(ctx, frame, arg_buf, current_func) do
        case Map.fetch(ctx.globals, {:qb_arguments_object, current_func, arg_buf}) do
          {:ok, arguments} ->
            arguments

          :error ->
            key = {:qb_arguments_object, current_func, arg_buf}

            case Process.get(key) do
              nil ->
                arguments =
                  Heap.wrap_arguments(Tuple.to_list(arg_buf),
                    strict: current_strict_mode?(ctx),
                    callee: current_func,
                    mapped: special_object_mapped_argument_cells(ctx, frame)
                  )

                Process.put(key, arguments)
                arguments

              arguments ->
                arguments
            end
        end
      end

      defp special_object_mapped_argument_cells(ctx, frame) do
        if special_object_mapped_arguments?(ctx) do
          locals = special_object_function_locals(ctx)
          closure_ref_count = special_object_closure_ref_count(ctx)
          var_refs = elem(frame, Frame.var_refs())
          count = min(tuple_size(ctx.arg_buf), length(locals))

          if count == 0 do
            %{}
          else
            last_parameter_index = special_object_last_parameter_index_by_var_ref(locals, count)

            0..(count - 1)//1
            |> Enum.reduce(%{}, fn index, acc ->
              case Enum.at(locals, index) do
                %{var_ref_idx: ref_idx}
                when is_integer(ref_idx) and closure_ref_count + ref_idx < tuple_size(var_refs) ->
                  if Map.get(last_parameter_index, ref_idx) == index do
                    case elem(var_refs, closure_ref_count + ref_idx) do
                      {:cell, _} = cell -> Map.put(acc, index, cell)
                      _ -> acc
                    end
                  else
                    acc
                  end

                _ ->
                  acc
              end
            end)
          end
        else
          %{}
        end
      end

      defp special_object_last_parameter_index_by_var_ref(locals, count) do
        0..(count - 1)//1
        |> Enum.reduce(%{}, fn index, acc ->
          case Enum.at(locals, index) do
            %{var_ref_idx: ref_idx} when is_integer(ref_idx) -> Map.put(acc, ref_idx, index)
            _ -> acc
          end
        end)
      end

      defp special_object_mapped_arguments?(ctx) do
        case ctx.current_func do
          {:closure, _, %QuickBEAM.VM.Function{} = fun} ->
            not fun.is_strict_mode and fun.has_simple_parameter_list

          %QuickBEAM.VM.Function{} = fun ->
            not fun.is_strict_mode and fun.has_simple_parameter_list

          _ ->
            false
        end
      end

      defp special_object_function_locals(ctx) do
        case ctx.current_func do
          {:closure, _, %QuickBEAM.VM.Function{locals: locals}} -> locals
          %QuickBEAM.VM.Function{locals: locals} -> locals
          _ -> []
        end
      end

      defp special_object_closure_ref_count(ctx) do
        case ctx.current_func do
          {:closure, captured, _} when is_map(captured) -> map_size(captured)
          _ -> 0
        end
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

        {error_type, message} = QuickBEAM.VM.Compiler.RuntimeHelpers.Errors.message(name, reason)

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
        throw_or_catch(
          frame,
          Heap.make_error("this is not initialized", "ReferenceError"),
          gas,
          ctx
        )
      end

      defp run(
             {@op_push_this, []},
             pc,
             frame,
             stack,
             gas,
             %Context{
               this: this,
               current_func: %QuickBEAM.VM.Function{is_strict_mode: true}
             } = ctx
           )
           when this in [:undefined, nil] do
        run(pc + 1, frame, [this | stack], gas, ctx)
      end

      defp run(
             {@op_push_this, []},
             pc,
             frame,
             stack,
             gas,
             %Context{
               this: this,
               current_func: {:closure, _, %QuickBEAM.VM.Function{is_strict_mode: true}}
             } = ctx
           )
           when this in [:undefined, nil] do
        run(pc + 1, frame, [this | stack], gas, ctx)
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
        catch_and_dispatch(
          pc,
          frame,
          rest,
          gas,
          ctx,
          fn ->
            has_instance = Get.get(ctor, {:symbol, "Symbol.hasInstance"})

            if has_instance != :undefined and has_instance != nil and
                 function_value?(has_instance) do
              result =
                Invocation.invoke_with_receiver(has_instance, [obj], Runtime.gas_budget(), ctor)

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
                builtin_instance? =
                  case {obj, ctor} do
                    {{:obj, ref}, {:builtin, "Array", _}} ->
                      data = Heap.get_obj(ref)
                      match?({:qb_arr, _}, data) or is_list(data)

                    {{:obj, ref}, {:builtin, "BigInt", _}} ->
                      match?(
                        {:ok, _},
                        QuickBEAM.VM.ObjectModel.WrappedPrimitive.value(
                          Heap.get_obj(ref, %{}),
                          :bigint
                        )
                      )

                    {{:obj, ref}, {:builtin, name, _}} when is_binary(name) ->
                      data = Heap.get_obj(ref, %{})

                      typed_array_instance?(data, name) or
                        (name == "Date" and Map.has_key?(data, date_ms()))

                    {{:obj, _}, {:builtin, "Object", _}} ->
                      true

                    {value, {:builtin, name, _}} ->
                      function_value?(value) and name in ["Function", "Object"]

                    _ ->
                      false
                  end

                if builtin_instance? do
                  true
                else
                  ctor_proto = Get.get(ctor, "prototype")

                  case ctor_proto do
                    {:obj, _} ->
                      check_prototype_chain(obj, ctor_proto)

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
                end
              else
                false
              end
            end
          end,
          true
        )
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
            {:obj, _} = obj ->
              Delete.delete_property(obj, key)

            {:closure, _, _} = fun ->
              delete_static(fun, key)

            %QuickBEAM.VM.Function{} = fun ->
              delete_static(fun, key)

            {:builtin, _, _} = fun ->
              delete_static(fun, key)

            {:bound, _, _, _, _} = fun ->
              delete_static(fun, key)

            _ ->
              true
          end

        if result == false and current_strict_mode?(ctx) do
          throw_or_catch(frame, Heap.make_error("Cannot delete property", "TypeError"), gas, ctx)
        else
          run(pc + 1, frame, [result | rest], gas, ctx)
        end
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

      defp typed_array_instance?(
             %{"__typed_array__" => true, "__type__" => type},
             constructor_name
           ) do
        typed_array_constructor_type(constructor_name) == type
      end

      defp typed_array_instance?(_, _), do: false

      defp typed_array_constructor_type("Uint8Array"), do: :uint8
      defp typed_array_constructor_type("Int8Array"), do: :int8
      defp typed_array_constructor_type("Uint16Array"), do: :uint16
      defp typed_array_constructor_type("Int16Array"), do: :int16
      defp typed_array_constructor_type("Uint32Array"), do: :uint32
      defp typed_array_constructor_type("Int32Array"), do: :int32
      defp typed_array_constructor_type("Float16Array"), do: :float16
      defp typed_array_constructor_type("Float32Array"), do: :float32
      defp typed_array_constructor_type("Float64Array"), do: :float64
      defp typed_array_constructor_type("Uint8ClampedArray"), do: :uint8_clamped
      defp typed_array_constructor_type("BigUint64Array"), do: :biguint64
      defp typed_array_constructor_type("BigInt64Array"), do: :bigint64
      defp typed_array_constructor_type(_), do: nil

      # ── in operator ──

      defp run({@op_in, []}, pc, frame, [obj, key | rest], gas, ctx) do
        catch_and_dispatch(
          pc,
          frame,
          rest,
          gas,
          ctx,
          fn ->
            unless is_object(obj) or match?({:builtin, _, _}, obj) or
                     is_closure(obj) or match?(%QuickBEAM.VM.Function{}, obj) or
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

            coerced_key =
              case key do
                {:symbol, _} -> key
                {:symbol, _, _} -> key
                key when is_binary(key) or is_integer(key) -> key
                _ -> Values.stringify(key)
              end

            QuickBEAM.VM.ObjectModel.HasProperty.has_property?(obj, coerced_key)
          end,
          false
        )
      end

      # ── regexp literal ──

      defp run({@op_regexp, []}, pc, frame, [pattern, flags | rest], gas, ctx) do
        run(pc + 1, frame, [{:regexp, pattern, flags, make_ref()} | rest], gas, ctx)
      end

      # ── Object spread (copy_data_properties with mask) ──

      defp run({@op_copy_data_properties, [mask]}, pc, frame, stack, gas, ctx) do
        %{target_idx: target_idx, source_idx: source_idx, exclude_idx: exclude_idx} =
          CopyDataProperties.decode(mask)

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
            ctx = RuntimeState.current() || ctx
            throw_or_catch(frame, error, gas, ctx)
        end
      end
    end
  end
end
