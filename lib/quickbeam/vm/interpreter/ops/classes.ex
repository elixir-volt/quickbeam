defmodule QuickBEAM.VM.Interpreter.Ops.Classes do
  @moduledoc "Class definition, method definition, brand, and private field opcodes."

  @doc "Installs the Class definition, method definition, brand, and private field opcodes helpers into the caller module."
  defmacro __using__(_opts) do
    quote location: :keep do
      alias QuickBEAM.VM.{Heap, Names}
      alias QuickBEAM.VM.Interpreter.{Context, EvalEnv, Frame}
      alias QuickBEAM.VM.ObjectModel.{Class, Methods, Private}

      # ── Class definitions ──

      defp run(
             {@op_define_class, [atom_idx, _flags]},
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
            %QuickBEAM.VM.Function{} = f ->
              base = build_closure(f, locals, vrefs, l2v, ctx)
              inherit_parent_vrefs(base, vrefs)

            already_closure ->
              already_closure
          end

        class_name = Names.resolve_atom(ctx, atom_idx)

        try do
          {proto, ctor_closure} = Class.define_class(ctor_closure, parent_ctor, class_name)
          frame = EvalEnv.seed_class_binding(frame, ctx, atom_idx, ctor_closure)
          run(pc + 1, frame, [proto, ctor_closure | rest], gas, ctx)
        catch
          {:js_throw, error} -> throw_or_catch(frame, error, gas, ctx)
        end
      end

      defp run({@op_add_brand, []}, pc, frame, [obj, brand | rest], gas, ctx) do
        Private.add_brand(obj, brand)
        run(pc + 1, frame, rest, gas, ctx)
      end

      defp run({@op_check_brand, []}, pc, frame, [brand, obj | _] = stack, gas, ctx) do
        case Private.ensure_brand(obj, brand) do
          :ok -> run(pc + 1, frame, stack, gas, ctx)
          :error -> throw_or_catch(frame, Private.brand_error(), gas, ctx)
        end
      end

      defp run(
             {@op_define_class_computed, [_atom_idx, _flags]},
             pc,
             frame,
             [ctor, parent_ctor, computed_name | rest],
             gas,
             ctx
           ) do
        locals = elem(frame, Frame.locals())
        vrefs = elem(frame, Frame.var_refs())
        l2v = elem(frame, Frame.l2v())

        ctor_closure =
          case ctor do
            %QuickBEAM.VM.Function{} = f ->
              base = build_closure(f, locals, vrefs, l2v, ctx)
              inherit_parent_vrefs(base, vrefs)

            already_closure ->
              already_closure
          end

        class_name = QuickBEAM.VM.ObjectModel.Functions.function_name(computed_name)

        try do
          {proto, ctor_closure} = Class.define_class(ctor_closure, parent_ctor, class_name)
          run(pc + 1, frame, [proto, ctor_closure, computed_name | rest], gas, ctx)
        catch
          {:js_throw, error} -> throw_or_catch(frame, error, gas, ctx)
        end
      end

      defp run(
             {@op_define_method, [atom_idx, flags]},
             pc,
             frame,
             [method_closure, target | rest],
             gas,
             ctx
           ) do
        method_name =
          case atom_idx do
            {:tagged_int, _} -> QuickBEAM.VM.ObjectModel.PropertyKey.normalize(atom_idx)
            _ -> Names.resolve_atom(ctx, atom_idx)
          end

        Methods.define_method(target, method_closure, method_name, flags)
        run(pc + 1, frame, [target | rest], gas, ctx)
      end

      defp run(
             {@op_define_method_computed, [flags]},
             pc,
             frame,
             [method_closure, field_name, target | rest],
             gas,
             ctx
           ) do
        Methods.define_method_computed(target, method_closure, field_name, flags)
        run(pc + 1, frame, [target | rest], gas, ctx)
      end
    end
  end
end
