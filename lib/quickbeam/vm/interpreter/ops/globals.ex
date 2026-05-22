defmodule QuickBEAM.VM.Interpreter.Ops.Globals do
  @moduledoc "Global variable access, ref values, eval, and with-statement opcodes."

  @doc "Installs the Global variable access, ref values, eval, and with-statement opcodes helpers into the caller module."
  defmacro __using__(_opts) do
    quote location: :keep do
      import QuickBEAM.VM.Value, only: [is_object: 1]
      alias QuickBEAM.VM.{GlobalEnvironment, Heap, Names, Runtime, RuntimeState}
      alias QuickBEAM.VM.Interpreter.{ArgumentsObject, Closures, Completion, Context, Frame}
      alias QuickBEAM.VM.JSThrow
      alias QuickBEAM.VM.ObjectModel.{Get, InternalMethods}
      alias QuickBEAM.VM.Promise, as: Promise
      alias QuickBEAM.VM.Semantics.Values

      # ── Globals: get_var, put_var, define_var, eval ──

      defp run({@op_get_var_undef, [atom_idx]}, pc, frame, stack, gas, ctx) do
        if Names.resolve_atom(ctx, atom_idx) == "arguments" do
          arguments = Map.get(ctx.globals, "arguments", make_arguments_object(ctx, frame))

          run(pc + 1, frame, [arguments | stack], gas, ctx)
        else
          val = GlobalEnvironment.get(ctx, atom_idx, :undefined)

          case maybe_global_this_get(ctx, atom_idx, val) do
            {:ok, value, ctx} -> run(pc + 1, frame, [value | stack], gas, ctx)
            {:throw, error, ctx} -> throw_or_catch(frame, error, gas, ctx)
          end
        end
      end

      defp run({@op_get_var, [atom_idx]}, pc, frame, stack, gas, ctx) do
        if delay_object_define_value?(pc, frame, stack) do
          run(pc + 1, frame, [{:qb_delayed_get_var, atom_idx} | stack], gas, ctx)
        else
          run_get_var(atom_idx, pc, frame, stack, gas, ctx)
        end
      end

      defp run_get_var(atom_idx, pc, frame, stack, gas, ctx) do
        if Names.resolve_atom(ctx, atom_idx) == "arguments" do
          {arguments, ctx} =
            case Map.fetch(ctx.globals, "arguments") do
              {:ok, arguments} ->
                {arguments, ctx}

              :error ->
                arguments = make_arguments_object(ctx, frame)

                {arguments, ArgumentsObject.store_global(ctx, arguments)}
            end

          run(pc + 1, frame, [arguments | stack], gas, ctx)
        else
          case GlobalEnvironment.fetch(ctx, atom_idx) do
            {:found, :__tdz__} ->
              name = Names.resolve_atom(ctx, atom_idx)

              throw_or_catch(
                frame,
                Heap.make_error("#{name} is not initialized", "ReferenceError"),
                gas,
                ctx
              )

            {:found, val} ->
              run(pc + 1, frame, [val | stack], gas, ctx)

            :not_found ->
              name = Names.resolve_atom(ctx, atom_idx)
              global_this = Map.get(ctx.globals, "globalThis")

              case global_this_get(ctx, global_this, name) do
                {:ok, :undefined, ctx} ->
                  throw_or_catch(
                    frame,
                    Heap.make_error("#{name} is not defined", "ReferenceError"),
                    gas,
                    ctx
                  )

                {:ok, val, ctx} ->
                  run(pc + 1, frame, [val | stack], gas, ctx)

                {:throw, error, ctx} ->
                  throw_or_catch(frame, error, gas, ctx)
              end
          end
        end
      end

      defp make_arguments_object(ctx, frame),
        do: ArgumentsObject.get(ctx, frame, var_ref_offset: :raw)

      defp maybe_global_this_get(ctx, atom_idx, :undefined) do
        name = Names.resolve_atom(ctx, atom_idx)
        global_this_get(ctx, Map.get(ctx.globals, "globalThis"), name)
      end

      defp maybe_global_this_get(ctx, _atom_idx, val), do: {:ok, val, ctx}

      defp global_this_get(ctx, {:obj, _} = global_this, name),
        do: Completion.capture(ctx, fn -> Get.get(global_this, name) end)

      defp global_this_get(ctx, _global_this, _name), do: {:ok, :undefined, ctx}

      defp delay_object_define_value?(pc, frame, [_key, {:obj, _} | _]) do
        instructions = elem(frame, Frame.insns())

        case pc + 1 < tuple_size(instructions) && elem(instructions, pc + 1) do
          {@op_define_array_el, []} -> true
          _ -> false
        end
      end

      defp delay_object_define_value?(_pc, _frame, _stack), do: false

      defp resolve_delayed_define_value({:qb_delayed_get_var, atom_idx}, ctx) do
        case GlobalEnvironment.fetch(ctx, atom_idx) do
          {:found, :__tdz__} ->
            name = Names.resolve_atom(ctx, atom_idx)
            JSThrow.reference_error!("#{name} is not initialized")

          {:found, val} ->
            val

          :not_found ->
            name = Names.resolve_atom(ctx, atom_idx)

            case Map.get(ctx.globals, "globalThis") do
              {:obj, _} = global_this ->
                case Get.get(global_this, name) do
                  :undefined -> JSThrow.reference_error!("#{name} is not defined")
                  val -> val
                end

              _ ->
                JSThrow.reference_error!("#{name} is not defined")
            end
        end
      end

      defp resolve_delayed_define_value(value, _ctx), do: value

      defp run({op, [atom_idx]}, pc, frame, [val | rest], gas, ctx)
           when op in [@op_put_var, @op_put_var_init] do
        persistent_before = Heap.get_persistent_globals()
        base_before = Heap.get_base_globals()

        try do
          new_ctx =
            GlobalEnvironment.put(ctx, atom_idx, val,
              init: op == @op_put_var_init,
              strict: current_strict_mode?(ctx),
              sync_global_this: false
            )

          name = Names.resolve_atom(ctx, atom_idx)

          unless GlobalEnvironment.lexical_global?(name) do
            case Map.get(ctx.globals, "globalThis") do
              {:obj, _} = gt ->
                validate_global_set_result!(ctx, name, InternalMethods.set(gt, name, val))

              _ ->
                :ok
            end
          end

          run(pc + 1, frame, rest, gas, new_ctx)
        catch
          {:js_throw, error} ->
            Heap.put_persistent_globals(persistent_before)
            Heap.put_base_globals(base_before)
            throw_or_catch(frame, error, gas, ctx)
        end
      end

      defp validate_global_set_result!(ctx, name, result) do
        if Values.truthy?(result) or not current_strict_mode?(ctx) do
          :ok
        else
          JSThrow.type_error!("Cannot assign to #{name}")
        end
      end

      defp run({@op_define_func, [atom_idx, _flags]}, pc, frame, [fun | rest], gas, ctx) do
        next_ctx = GlobalEnvironment.put(ctx, atom_idx, fun)
        run(pc + 1, frame, rest, gas, next_ctx)
      end

      defp run({@op_define_var, [atom_idx, scope]}, pc, frame, stack, gas, ctx) do
        ctx = GlobalEnvironment.define_var(ctx, atom_idx, scope)

        unless Bitwise.band(scope, 0x80) == 0x80 do
          case Map.get(ctx.globals, "globalThis") do
            {:obj, ref} ->
              name = Names.resolve_atom(ctx, atom_idx)
              stored = Heap.get_obj(ref)

              if is_map(stored) and not Map.has_key?(stored, name) do
                Heap.put_obj(ref, Map.put(stored, name, :undefined))

                Heap.put_prop_desc(ref, name, %{
                  writable: true,
                  enumerable: true,
                  configurable: false
                })
              end

            _ ->
              :ok
          end
        end

        run(pc + 1, frame, stack, gas, ctx)
      end

      defp run({@op_check_define_var, [atom_idx, _scope]}, pc, frame, stack, gas, ctx) do
        GlobalEnvironment.check_define_var(ctx, atom_idx)
        run(pc + 1, frame, stack, gas, ctx)
      end

      # ── Closure variable refs (mutable) ──

      defp run({@op_make_loc_ref, [atom_idx, var_idx]}, pc, frame, stack, gas, ctx) do
        ref = make_ref()
        Heap.put_cell(ref, elem(elem(frame, Frame.locals()), var_idx))
        prop_name = Names.resolve_atom(ctx, atom_idx)
        run(pc + 1, frame, [prop_name, {:cell, ref} | stack], gas, ctx)
      end

      defp run({@op_make_var_ref, [atom_idx]}, pc, frame, stack, gas, ctx) do
        name = Names.resolve_atom(ctx, atom_idx)
        val = Map.get(ctx.globals, name, :undefined)
        ref = make_ref()
        Heap.put_cell(ref, val)
        run(pc + 1, frame, [name, {:cell, ref} | stack], gas, ctx)
      end

      defp run({@op_make_arg_ref, [atom_idx, var_idx]}, pc, frame, stack, gas, ctx) do
        ref = make_ref()
        Heap.put_cell(ref, get_arg_value(ctx, var_idx))
        prop_name = Names.resolve_atom(ctx, atom_idx)
        run(pc + 1, frame, [prop_name, {:cell, ref} | stack], gas, ctx)
      end

      defp run({@op_make_var_ref_ref, [atom_idx, var_idx]}, pc, frame, stack, gas, ctx) do
        val = elem(elem(frame, Frame.var_refs()), var_idx)

        cell =
          case val do
            {:cell, _} ->
              val

            _ ->
              ref = make_ref()
              Heap.put_cell(ref, val)
              {:cell, ref}
          end

        prop_name = Names.resolve_atom(ctx, atom_idx)
        run(pc + 1, frame, [prop_name, cell | stack], gas, ctx)
      end

      defp run({@op_get_var_ref_check, [idx]}, pc, frame, stack, gas, ctx) do
        case elem(elem(frame, Frame.var_refs()), idx) do
          :__tdz__ ->
            message =
              if current_var_ref_name(ctx, idx) == "this",
                do: "this is not initialized",
                else: "Cannot access variable before initialization"

            JSThrow.reference_error!(message)

          {:cell, _} = cell ->
            val = Closures.read_cell(cell)

            if val == :__tdz__ and current_var_ref_name(ctx, idx) == "this" and
                 derived_this_uninitialized?(ctx) do
              JSThrow.reference_error!("this is not initialized")
            end

            run(pc + 1, frame, [val | stack], gas, ctx)

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

      defp run(
             {@op_get_ref_value, []},
             pc,
             frame,
             [_prop_name, {:cell, _} = ref | _] = stack,
             gas,
             ctx
           ) do
        run(pc + 1, frame, [Closures.read_cell(ref) | stack], gas, ctx)
      end

      defp run({@op_get_ref_value, []}, pc, frame, [prop_name, obj | _] = stack, gas, ctx)
           when is_binary(prop_name) do
        case Completion.capture(ctx, fn -> Get.get(obj, prop_name) end) do
          {:ok, value, ctx} -> run(pc + 1, frame, [value | stack], gas, ctx)
          {:throw, error, ctx} -> throw_or_catch(frame, error, gas, ctx)
        end
      end

      defp run(
             {@op_put_ref_value, []},
             pc,
             frame,
             [val, prop_name, {:cell, _} = ref | rest],
             gas,
             ctx
           ) do
        case put_ref_cell_global_write(ctx, prop_name, val) do
          {:ok, ctx} ->
            Closures.write_cell(ref, val)
            run(pc + 1, frame, rest, gas, ctx)

          {:throw, error, ctx} ->
            throw_or_catch(frame, error, gas, ctx)
        end
      end

      defp run({@op_put_ref_value, []}, pc, frame, [val, key, obj | rest], gas, ctx)
           when is_binary(key) do
        case put_ref_object_write(ctx, obj, key, val) do
          {:ok, ctx} ->
            frame = sync_setter_globals_to_frame(frame, ctx)
            run(pc + 1, frame, rest, gas, ctx)

          {:throw, error, ctx} ->
            throw_or_catch(frame, error, gas, ctx)
        end
      end

      defp put_ref_cell_global_write(ctx, prop_name, val) when is_binary(prop_name) do
        case Map.get(ctx.globals, "globalThis") do
          {:obj, _} = global_this ->
            case Completion.capture(ctx, fn ->
                   InternalMethods.set(global_this, prop_name, val)
                 end) do
              {:ok, _set_result, ctx} -> {:ok, commit_ref_global(ctx, prop_name, val)}
              {:throw, error, ctx} -> {:throw, error, ctx}
            end

          _ ->
            {:ok, commit_ref_global(ctx, prop_name, val)}
        end
      end

      defp put_ref_cell_global_write(ctx, _prop_name, _val), do: {:ok, ctx}

      defp commit_ref_global(ctx, prop_name, val) do
        new_globals = Map.put(ctx.globals, prop_name, val)
        Heap.put_persistent_globals(new_globals)
        Heap.put_base_globals(new_globals)
        Context.mark_dirty(%{ctx | globals: new_globals})
      end

      defp put_ref_object_write(ctx, obj, key, val) do
        result =
          Completion.capture(ctx, fn ->
            if current_strict_mode?(ctx) and is_object(obj) and
                 not InternalMethods.has_property(obj, key) do
              {:missing, Heap.make_error("#{key} is not defined", "ReferenceError")}
            else
              InternalMethods.set(obj, key, val)
              :ok
            end
          end)

        case result do
          {:ok, {:missing, error}, ctx} -> {:throw, error, ctx}
          {:ok, :ok, ctx} -> {:ok, ctx}
          {:throw, error, ctx} -> {:throw, error, ctx}
        end
      end

      # ── eval ──

      defp run({@op_import, []}, pc, frame, [specifier, _import_meta | rest], gas, ctx) do
        result =
          if is_binary(specifier) and ctx.runtime_pid != nil do
            case QuickBEAM.Runtime.load_module(ctx.runtime_pid, specifier, "") do
              :ok ->
                Promise.resolved(Runtime.new_object())

              {:error, _} ->
                Promise.rejected(
                  Heap.make_error("Cannot find module '#{specifier}'", "TypeError")
                )
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
        scope_depth = List.first(scope_args, -1)
        var_objs = eval_scope_var_objects(frame, ctx, scope_args != [], scope_depth)

        run_eval_or_call(pc, frame, rest, gas, ctx, eval_ref, call_args, scope_depth, var_objs)
      end

      defp run({@op_apply_eval, [scope_idx_raw]}, pc, frame, [arg_array, fun | rest], gas, ctx) do
        args = Heap.to_list(arg_array)
        scope_idx = scope_idx_raw - 1
        var_objs = eval_scope_var_objects(frame, ctx, scope_idx >= 0, scope_idx)

        run_eval_or_call(pc, frame, rest, gas, ctx, fun, args, scope_idx, var_objs)
      end

      # ── with statement ──

      defp run(
             {@op_with_get_var, [atom_idx, target, _is_with]},
             pc,
             frame,
             [obj | rest],
             gas,
             ctx
           ) do
        key = Names.resolve_atom(ctx, atom_idx)

        case Completion.capture(ctx, fn -> with_get_var_result(obj, key) end) do
          {:ok, {:found, value}, ctx} -> run(target, frame, [value | rest], gas, ctx)
          {:ok, :missing, ctx} -> run(pc + 1, frame, rest, gas, ctx)
          {:throw, error, ctx} -> throw_or_catch(frame, error, gas, ctx)
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
        key = Names.resolve_atom(ctx, atom_idx)

        case Completion.capture(ctx, fn -> with_put_var_result(obj, key, val) end) do
          {:ok, :written, ctx} ->
            frame = sync_setter_globals_to_frame(frame, ctx)
            run(target, frame, rest, gas, ctx)

          {:ok, :missing, ctx} ->
            run(pc + 1, frame, [val | rest], gas, ctx)

          {:throw, error, ctx} ->
            throw_or_catch(frame, error, gas, ctx)
        end
      end

      defp with_get_var_result(obj, key) do
        if with_has_property?(obj, key), do: {:found, Get.get(obj, key)}, else: :missing
      end

      defp with_put_var_result(obj, key, val) do
        if with_has_property?(obj, key) do
          InternalMethods.set(obj, key, val)
          :written
        else
          :missing
        end
      end

      defp with_delete_var_result(obj, key) do
        if with_has_property?(obj, key) do
          InternalMethods.delete(obj, key)
          :deleted
        else
          :missing
        end
      end

      defp run(
             {@op_with_delete_var, [atom_idx, target, _is_with]},
             pc,
             frame,
             [obj | rest],
             gas,
             ctx
           ) do
        key = Names.resolve_atom(ctx, atom_idx)

        case Completion.capture(ctx, fn -> with_delete_var_result(obj, key) end) do
          {:ok, :deleted, ctx} -> run(target, frame, [true | rest], gas, ctx)
          {:ok, :missing, ctx} -> run(pc + 1, frame, rest, gas, ctx)
          {:throw, error, ctx} -> throw_or_catch(frame, error, gas, ctx)
        end
      end

      defp run(
             {@op_with_make_ref, [atom_idx, target, _is_with]},
             pc,
             frame,
             [obj | rest],
             gas,
             ctx
           ) do
        key = Names.resolve_atom(ctx, atom_idx)

        case Completion.capture(ctx, fn -> with_has_property?(obj, key) end) do
          {:ok, true, ctx} -> run(target, frame, [key, obj | rest], gas, ctx)
          {:ok, false, ctx} -> run(pc + 1, frame, rest, gas, ctx)
          {:throw, error, ctx} -> throw_or_catch(frame, error, gas, ctx)
        end
      end

      defp run(
             {@op_with_get_ref, [atom_idx, target, _is_with]},
             pc,
             frame,
             [obj | rest],
             gas,
             ctx
           ) do
        key = Names.resolve_atom(ctx, atom_idx)

        case Completion.capture(ctx, fn -> with_get_var_result(obj, key) end) do
          {:ok, {:found, value}, ctx} -> run(target, frame, [value, obj | rest], gas, ctx)
          {:ok, :missing, ctx} -> run(pc + 1, frame, rest, gas, ctx)
          {:throw, error, ctx} -> throw_or_catch(frame, error, gas, ctx)
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
        key = Names.resolve_atom(ctx, atom_idx)

        case Completion.capture(ctx, fn -> with_get_var_result(obj, key) end) do
          {:ok, {:found, value}, ctx} -> run(target, frame, [value, :undefined | rest], gas, ctx)
          {:ok, :missing, ctx} -> run(pc + 1, frame, rest, gas, ctx)
          {:throw, error, ctx} -> throw_or_catch(frame, error, gas, ctx)
        end
      end
    end
  end
end
