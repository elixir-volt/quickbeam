defmodule QuickBEAM.VM.Interpreter.Ops.Globals do
  @moduledoc "Global variable access, ref values, eval, and with-statement opcodes."

  @doc "Installs the Global variable access, ref values, eval, and with-statement opcodes helpers into the caller module."
  defmacro __using__(_opts) do
    quote location: :keep do
      alias QuickBEAM.VM.{GlobalEnv, Heap, Names, Runtime}
      alias QuickBEAM.VM.Interpreter.{Closures, Context, Frame}
      alias QuickBEAM.VM.JSThrow
      alias QuickBEAM.VM.ObjectModel.{Delete, Get, Put}
      alias QuickBEAM.VM.PromiseState, as: Promise

      # ── Globals: get_var, put_var, define_var, eval ──

      defp run({@op_get_var_undef, [atom_idx]}, pc, frame, stack, gas, ctx) do
        if Names.resolve_atom(ctx, atom_idx) == "arguments" do
          arguments = Map.get(ctx.globals, "arguments", make_arguments_object(ctx, frame))

          run(pc + 1, frame, [arguments | stack], gas, ctx)
        else
          val = GlobalEnv.get(ctx, atom_idx, :undefined)

          val =
            if val == :undefined do
              name = Names.resolve_atom(ctx, atom_idx)
              global_this = Map.get(ctx.globals, "globalThis")

              case global_this do
                {:obj, _} -> Get.get(global_this, name)
                _ -> :undefined
              end
            else
              val
            end

          run(pc + 1, frame, [val | stack], gas, ctx)
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
                {arguments, %{ctx | globals: Map.put(ctx.globals, "arguments", arguments)}}
            end

          run(pc + 1, frame, [arguments | stack], gas, ctx)
        else
          case GlobalEnv.fetch(ctx, atom_idx) do
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

              case global_this do
                {:obj, _} ->
                  val = Get.get(global_this, name)

                  if val != :undefined do
                    run(pc + 1, frame, [val | stack], gas, ctx)
                  else
                    throw_or_catch(
                      frame,
                      Heap.make_error("#{name} is not defined", "ReferenceError"),
                      gas,
                      ctx
                    )
                  end

                _ ->
                  throw_or_catch(
                    frame,
                    Heap.make_error("#{name} is not defined", "ReferenceError"),
                    gas,
                    ctx
                  )
              end
          end
        end
      end

      defp make_arguments_object(ctx, frame) do
        Heap.wrap_arguments(Tuple.to_list(ctx.arg_buf),
          strict: current_strict_mode?(ctx),
          callee: ctx.current_func,
          mapped: mapped_argument_cells(ctx, frame)
        )
      end

      defp mapped_argument_cells(ctx, frame) do
        if mapped_arguments_object?(ctx) do
          locals = function_locals(ctx)
          var_refs = elem(frame, Frame.var_refs())
          count = min(tuple_size(ctx.arg_buf), length(locals))

          if count == 0 do
            %{}
          else
            last_parameter_index = last_parameter_index_by_var_ref(locals, count)

            0..(count - 1)//1
            |> Enum.reduce(%{}, fn index, acc ->
              case Enum.at(locals, index) do
                %{var_ref_idx: ref_idx}
                when is_integer(ref_idx) and ref_idx < tuple_size(var_refs) ->
                  if Map.get(last_parameter_index, ref_idx) == index do
                    case elem(var_refs, ref_idx) do
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

      defp last_parameter_index_by_var_ref(locals, count) do
        0..(count - 1)//1
        |> Enum.reduce(%{}, fn index, acc ->
          case Enum.at(locals, index) do
            %{var_ref_idx: ref_idx} when is_integer(ref_idx) -> Map.put(acc, ref_idx, index)
            _ -> acc
          end
        end)
      end

      defp mapped_arguments_object?(ctx) do
        case ctx.current_func do
          {:closure, _, %QuickBEAM.VM.Function{} = fun} ->
            not fun.is_strict_mode and fun.has_simple_parameter_list

          %QuickBEAM.VM.Function{} = fun ->
            not fun.is_strict_mode and fun.has_simple_parameter_list

          _ ->
            false
        end
      end

      defp function_locals(ctx) do
        case ctx.current_func do
          {:closure, _, %QuickBEAM.VM.Function{locals: locals}} -> locals
          %QuickBEAM.VM.Function{locals: locals} -> locals
          _ -> []
        end
      end

      defp delay_object_define_value?(pc, frame, [_key, {:obj, _} | _]) do
        instructions = elem(frame, Frame.insns())

        case pc + 1 < tuple_size(instructions) && elem(instructions, pc + 1) do
          {@op_define_array_el, []} -> true
          _ -> false
        end
      end

      defp delay_object_define_value?(_pc, _frame, _stack), do: false

      defp resolve_delayed_define_value({:qb_delayed_get_var, atom_idx}, ctx) do
        case GlobalEnv.fetch(ctx, atom_idx) do
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
        try do
          new_ctx =
            GlobalEnv.put(ctx, atom_idx, val,
              init: op == @op_put_var_init,
              strict: current_strict_mode?(ctx)
            )

          name = Names.resolve_atom(ctx, atom_idx)

          unless GlobalEnv.lexical_global?(name) do
            case Map.get(ctx.globals, "globalThis") do
              {:obj, _} = gt -> Put.put(gt, name, val)
              _ -> :ok
            end
          end

          run(pc + 1, frame, rest, gas, new_ctx)
        catch
          {:js_throw, error} -> throw_or_catch(frame, error, gas, ctx)
        end
      end

      defp run({@op_define_func, [atom_idx, _flags]}, pc, frame, [fun | rest], gas, ctx) do
        next_ctx = GlobalEnv.put(ctx, atom_idx, fun)
        run(pc + 1, frame, rest, gas, next_ctx)
      end

      defp run({@op_define_var, [atom_idx, scope]}, pc, frame, stack, gas, ctx) do
        ctx = GlobalEnv.define_var(ctx, atom_idx, scope)

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
        GlobalEnv.check_define_var(ctx, atom_idx)
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
        run(pc + 1, frame, [Get.get(obj, prop_name) | stack], gas, ctx)
      end

      defp run(
             {@op_put_ref_value, []},
             pc,
             frame,
             [val, prop_name, {:cell, _} = ref | rest],
             gas,
             ctx
           ) do
        Closures.write_cell(ref, val)

        ctx =
          if is_binary(prop_name) do
            new_globals = Map.put(ctx.globals, prop_name, val)
            Heap.put_persistent_globals(new_globals)
            Heap.put_base_globals(new_globals)

            case Map.get(ctx.globals, "globalThis") do
              {:obj, _} = gt -> Put.put(gt, prop_name, val)
              _ -> :ok
            end

            Context.mark_dirty(%{ctx | globals: new_globals})
          else
            ctx
          end

        run(pc + 1, frame, rest, gas, ctx)
      end

      defp run({@op_put_ref_value, []}, pc, frame, [val, key, obj | rest], gas, ctx)
           when is_binary(key) do
        if current_strict_mode?(ctx) and is_object(obj) and
             not QuickBEAM.VM.ObjectModel.HasProperty.has_property?(obj, key) do
          throw_or_catch(
            frame,
            Heap.make_error("#{key} is not defined", "ReferenceError"),
            gas,
            ctx
          )
        else
          try do
            Put.put(obj, key, val)
            frame = sync_setter_globals_to_frame(frame, ctx)
            run(pc + 1, frame, rest, gas, ctx)
          catch
            {:js_throw, error} ->
              ctx = Heap.get_ctx() || ctx
              throw_or_catch(frame, error, gas, ctx)
          end
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

        result =
          try do
            {:ok, with_has_property?(obj, key)}
          catch
            {:js_throw, error} -> {:throw, error}
          end

        case result do
          {:ok, true} ->
            ctx = refresh_persistent_globals(ctx)
            run(target, frame, [Get.get(obj, key) | rest], gas, ctx)

          {:ok, false} ->
            ctx = refresh_persistent_globals(ctx)
            run(pc + 1, frame, rest, gas, ctx)

          {:throw, error} ->
            throw_or_catch(frame, error, gas, ctx)
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

        if with_has_property?(obj, key) do
          Put.put(obj, key, val)
          frame = sync_setter_globals_to_frame(frame, ctx)
          run(target, frame, rest, gas, ctx)
        else
          run(pc + 1, frame, [val | rest], gas, ctx)
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

        if with_has_property?(obj, key) do
          Delete.delete_property(obj, key)
          run(target, frame, [true | rest], gas, ctx)
        else
          run(pc + 1, frame, rest, gas, ctx)
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

        if with_has_property?(obj, key) do
          ctx = refresh_persistent_globals(ctx)
          run(target, frame, [key, obj | rest], gas, ctx)
        else
          ctx = refresh_persistent_globals(ctx)
          run(pc + 1, frame, rest, gas, ctx)
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

        if with_has_property?(obj, key) do
          ctx = refresh_persistent_globals(ctx)
          run(target, frame, [Get.get(obj, key), obj | rest], gas, ctx)
        else
          ctx = refresh_persistent_globals(ctx)
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
        key = Names.resolve_atom(ctx, atom_idx)

        if with_has_property?(obj, key) do
          ctx = refresh_persistent_globals(ctx)
          run(target, frame, [Get.get(obj, key), :undefined | rest], gas, ctx)
        else
          ctx = refresh_persistent_globals(ctx)
          run(pc + 1, frame, rest, gas, ctx)
        end
      end
    end
  end
end
