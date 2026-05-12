defmodule QuickBEAM.VM.Invocation do
  @moduledoc "Unified JS function invocation: dispatches to compiled modules, interpreter fallback, builtins, and native callbacks."

  import QuickBEAM.VM.Heap.Keys, only: [proto: 0, proxy_handler: 0, proxy_target: 0]

  alias QuickBEAM.VM.{Builtin, Compiler, GlobalEnv, Heap, Runtime}
  alias QuickBEAM.VM.Compiler.Runner
  alias QuickBEAM.VM.Interpreter
  alias QuickBEAM.VM.Interpreter.Context
  alias QuickBEAM.VM.Invocation.Context, as: InvokeContext
  alias QuickBEAM.VM.ObjectModel.{Class, Get}

  @doc "Invokes a JavaScript callable with positional arguments and a gas budget."
  def invoke(fun, args, gas \\ Runtime.gas_budget())

  def invoke(%QuickBEAM.VM.Function{} = fun, args, gas) do
    track_invoke_depth()

    result =
      case Compiler.invoke(fun, args, call_context(fun)) do
        {:ok, result} -> result
        :error -> Interpreter.invoke_function_fallback(fun, args, gas, call_context(fun))
      end

    maybe_gc(result, [fun | args])
  end

  def invoke({:closure, _, %QuickBEAM.VM.Function{} = inner} = closure, args, gas) do
    track_invoke_depth()

    result =
      if compiled_closure_callable?(inner) do
        case Runner.invoke(closure, args, call_context(inner)) do
          {:ok, result} -> result
          :error -> Interpreter.invoke_closure_fallback(closure, args, gas, call_context(inner))
        end
      else
        Interpreter.invoke_closure_fallback(closure, args, gas, call_context(inner))
      end

    maybe_gc(result, [closure | args])
  end

  def invoke(other, args, _gas) when not is_tuple(other) or elem(other, 0) != :bound,
    do: Builtin.call(other, args, nil)

  def invoke({:bound, _, inner, _, _}, args, gas), do: invoke(inner, args, gas)

  @doc "Invokes a JavaScript callable with an explicit `this` receiver."
  def invoke_with_receiver(fun, args, this_obj),
    do: invoke_with_receiver(fun, args, Runtime.gas_budget(), this_obj)

  def invoke_with_receiver(fun, args, gas, this_obj) do
    prev = Heap.get_ctx()
    Heap.put_ctx(%{active_ctx() | this: this_obj} |> InvokeContext.attach_method_state())

    try do
      invoke_receiver_target(fun, args, gas, this_obj)
    after
      if prev do
        refreshed = GlobalEnv.refresh(prev)
        Heap.put_ctx(refreshed)
      else
        Heap.put_ctx(nil)
      end
    end
  end

  @doc "Invokes a JavaScript constructor with `this` and `new.target` context."
  def invoke_constructor(fun, args, this_obj, new_target),
    do: invoke_constructor(fun, args, Runtime.gas_budget(), this_obj, new_target)

  def invoke_constructor(fun, args, gas, this_obj, new_target) do
    prev = Heap.get_ctx()

    ctor_ctx =
      %{active_ctx() | this: this_obj, new_target: new_target}
      |> InvokeContext.attach_method_state()

    Heap.put_ctx(ctor_ctx)

    try do
      dispatch(fun, args, gas, ctor_ctx, this_obj)
    after
      if prev, do: Heap.put_ctx(prev), else: Heap.put_ctx(nil)
    end
  end

  @doc "Dispatches a callable to bytecode, closure, bound-function, or builtin execution."
  def dispatch(fun, args, gas, ctx, this) do
    case fun do
      %QuickBEAM.VM.Function{} = bytecode_fun ->
        Interpreter.invoke_function_fallback(
          bytecode_fun,
          args,
          gas,
          dispatch_context(bytecode_fun, ctx, this)
        )

      {:closure, _, %QuickBEAM.VM.Function{} = inner} = closure ->
        Interpreter.invoke_closure_fallback(
          closure,
          args,
          gas,
          dispatch_context(inner, ctx, this)
        )

      {:bound, _, inner, _, _} ->
        invoke(inner, args, gas)

      {:obj, _} = obj ->
        dispatch_proxy_call(obj, args, ctx, this)

      other ->
        Builtin.call(other, args, this)
    end
  end

  @doc "Invokes a callback and propagates JavaScript throws to the caller."
  def invoke_callback_or_throw(fun, args, this_obj \\ nil) do
    ctx = active_ctx()

    case fun do
      {:closure, _, %QuickBEAM.VM.Function{need_home_object: false}} = closure ->
        case Runner.invoke(closure, args, ctx) do
          {:ok, value} -> value
          :error -> Interpreter.invoke_closure_fallback(closure, args, ctx.gas, ctx)
        end

      {:closure, _, %QuickBEAM.VM.Function{}} = closure ->
        Interpreter.invoke_closure_fallback(closure, args, ctx.gas, ctx)

      %QuickBEAM.VM.Function{} = bytecode_fun ->
        case Runner.invoke(bytecode_fun, args, ctx) do
          {:ok, value} -> value
          :error -> Interpreter.invoke_function_fallback(bytecode_fun, args, ctx.gas, ctx)
        end

      {:obj, _} = obj ->
        dispatch_proxy_call(obj, args, ctx, this_obj)

      other ->
        Builtin.call(other, args, this_obj)
    end
  end

  @doc "Invokes a callback, converting JavaScript throws to `:undefined`."
  def call_callback(fun, args), do: call_callback(active_ctx(), fun, args)

  def call_callback(ctx, fun, args) do
    case fun do
      %QuickBEAM.VM.Function{} = bytecode_fun ->
        callback_invoke(bytecode_fun, args, ctx)

      {:closure, _, %QuickBEAM.VM.Function{}} = closure ->
        callback_invoke(closure, args, ctx)

      other ->
        try do
          Builtin.call(other, args, nil)
        catch
          {:js_throw, _} -> :undefined
        end
    end
  end

  @doc "Helper for unified js function invocation: dispatches to compiled modules, interpreter fallback, builtins, and native callbacks."
  def invoke_callback(fun, args), do: invoke_callback(active_ctx(), fun, args)

  def invoke_callback(ctx, fun, args) do
    case fun do
      %QuickBEAM.VM.Function{} = bytecode_fun ->
        callback_invoke(bytecode_fun, args, ctx, fn -> Builtin.arg(args, 0, :undefined) end)

      {:closure, _, %QuickBEAM.VM.Function{}} = closure ->
        callback_invoke(closure, args, ctx, fn -> Builtin.arg(args, 0, :undefined) end)

      _ ->
        try do
          Builtin.call(fun, args, nil)
        catch
          {:js_throw, _} -> Builtin.arg(args, 0, :undefined)
        end
    end
  end

  @doc "Invokes a callable from compiler-generated runtime helper code."
  def invoke_runtime(fun, args), do: invoke_runtime(active_ctx(), fun, args)

  def invoke_runtime(
        %Context{} = ctx,
        {:closure, _, %QuickBEAM.VM.Function{need_home_object: false} = inner} = closure,
        args
      ) do
    atoms = Heap.get_fn_atoms(inner, ctx.atoms)

    key =
      {function_code_key(inner), inner.arg_count, :erlang.phash2(inner), :erlang.phash2(atoms)}

    case Heap.get_compiled(key) do
      {:compiled, {mod, name}, atoms} ->
        nargs = Runner.normalize_args(args, inner.arg_count)

        base_ctx = runtime_call_context(inner, ctx)

        fast_ctx = %{
          base_ctx
          | current_func: closure,
            arg_buf: List.to_tuple(args),
            globals:
              Map.put(
                base_ctx.globals,
                "arguments",
                Heap.wrap_arguments(args)
              ),
            atoms: atoms || base_ctx.atoms,
            pd_synced: false
        }

        apply(mod, name, [fast_ctx | nargs])

      _ ->
        invoke_runtime_full(ctx, closure, args)
    end
  end

  def invoke_runtime(ctx, fun, args), do: invoke_runtime_full(ctx, fun, args)

  defp invoke_runtime_full(ctx, fun, args) do
    case fun do
      %QuickBEAM.VM.Function{} = bytecode_fun ->
        call_ctx = runtime_call_context(bytecode_fun, ctx)

        case Runner.invoke(bytecode_fun, args, call_ctx) do
          {:ok, value} ->
            value

          :error ->
            Interpreter.invoke_function_fallback(bytecode_fun, args, call_ctx.gas, call_ctx)
        end

      {:closure, _, %QuickBEAM.VM.Function{} = inner} = closure ->
        invoke_closure(closure, inner, args, runtime_call_context(inner, ctx))

      {:bound, _, inner, _, _} ->
        invoke_runtime(ctx, inner, args)

      {:obj, _} = obj ->
        dispatch_proxy_call(obj, args, ctx, nil)

      other ->
        with_ctx(ctx, fn -> Builtin.call(other, args, nil) end)
    end
  end

  @doc "Invokes a method from compiler-generated runtime helper code with an explicit receiver."
  def invoke_method_runtime(fun, this_obj, args),
    do: invoke_method_runtime(active_ctx(), fun, this_obj, args)

  def invoke_method_runtime(ctx, fun, this_obj, args) do
    case fun do
      %QuickBEAM.VM.Function{} = bytecode_fun ->
        if compiled_method_callable?(bytecode_fun, this_obj) do
          case Runner.invoke_with_receiver(bytecode_fun, args, this_obj, ctx) do
            {:ok, value} ->
              value

            :error ->
              Interpreter.invoke_function_fallback(
                bytecode_fun,
                args,
                ctx.gas,
                Context.mark_dirty(%{ctx | this: this_obj})
              )
          end
        else
          Interpreter.invoke_function_fallback(
            bytecode_fun,
            args,
            ctx.gas,
            Context.mark_dirty(%{ctx | this: this_obj})
          )
        end

      {:closure, _, %QuickBEAM.VM.Function{} = inner} = closure ->
        if compiled_method_callable?(inner, this_obj) do
          case Runner.invoke_with_receiver(closure, args, this_obj, ctx) do
            {:ok, value} ->
              value

            :error ->
              Interpreter.invoke_closure_fallback(
                closure,
                args,
                ctx.gas,
                Context.mark_dirty(%{ctx | this: this_obj})
              )
          end
        else
          Interpreter.invoke_closure_fallback(
            closure,
            args,
            ctx.gas,
            Context.mark_dirty(%{ctx | this: this_obj})
          )
        end

      {:bound, _, inner, _, _} ->
        invoke_method_runtime(ctx, inner, this_obj, args)

      {:obj, _} = obj ->
        dispatch_proxy_call(obj, args, ctx, this_obj)

      other ->
        with_ctx(ctx, fn -> Builtin.call(other, args, this_obj) end)
    end
  end

  @doc "Constructs a value from compiler-generated runtime helper code."
  def construct_runtime(ctor, new_target, args),
    do: construct_runtime(active_ctx(), ctor, new_target, args)

  def construct_runtime(ctx, ctor, new_target, args) do
    with_ctx(ctx, fn ->
      validate_constructor!(ctor)
      validate_constructor!(new_target)

      raw_ctor = unwrap_constructor_target(ctor)
      raw_new_target = unwrap_new_target(new_target)

      ctor_proto =
        if raw_new_target != nil and raw_new_target != raw_ctor do
          normalize_constructor_prototype(Get.get(new_target, "prototype")) ||
            realm_default_prototype(raw_ctor, raw_new_target) ||
            Heap.get_class_proto(raw_new_target) ||
            Heap.get_class_proto(raw_ctor) || Heap.get_or_create_prototype(ctor)
        else
          Heap.get_class_proto(raw_ctor) || Heap.get_or_create_prototype(ctor)
        end

      init = if ctor_proto, do: %{proto() => ctor_proto}, else: %{}
      this_obj = Heap.wrap(init)

      result =
        case ctor do
          {:obj, _} = obj ->
            construct_proxy_runtime(ctx, obj, new_target, args)

          %QuickBEAM.VM.Function{} = fun ->
            case Runner.invoke_constructor(fun, args, this_obj, new_target, ctx) do
              {:ok, value} -> value
              :error -> invoke_constructor(fun, args, ctx.gas, this_obj, new_target)
            end

          {:closure, _, %QuickBEAM.VM.Function{}} = closure ->
            case Runner.invoke_constructor(closure, args, this_obj, new_target, ctx) do
              {:ok, value} ->
                value

              :error ->
                invoke_constructor(closure, args, ctx.gas, this_obj, new_target)
            end

          {:bound, _, _inner, orig_fun, bound_args} ->
            construct_runtime(orig_fun, new_target, bound_args ++ args)

          {:builtin, _name, cb} when is_function(cb, 2) ->
            cb.(args, this_obj)

          _ ->
            this_obj
        end

      case raw_ctor do
        {:builtin, "Object", _} -> result
        _ -> Class.coalesce_this_result(result, this_obj)
      end
    end)
  end

  defp construct_proxy_runtime(ctx, {:obj, ref} = proxy, new_target, args) do
    case Heap.get_obj(ref, %{}) do
      %{proxy_target() => target, proxy_handler() => handler} ->
        construct_trap = Get.get(handler, "construct")

        if construct_trap == :undefined or construct_trap == nil do
          construct_runtime(ctx, target, new_target, args)
        else
          result =
            dispatch(
              construct_trap,
              [target, Heap.wrap_arguments(args), new_target],
              ctx.gas,
              ctx,
              handler
            )

          case result do
            {:obj, _} ->
              result

            _ ->
              throw(
                {:js_throw,
                 Heap.make_error("proxy construct trap must return an object", "TypeError")}
              )
          end
        end

      _ ->
        throw(
          {:js_throw,
           Heap.make_error(
             "#{QuickBEAM.VM.Interpreter.Values.stringify(proxy)} is not a constructor",
             "TypeError"
           )}
        )
    end
  end

  defp dispatch_proxy_call({:obj, ref}, args, ctx, this) do
    case Heap.get_obj(ref, %{}) do
      %{proxy_target() => target, proxy_handler() => handler} ->
        apply_trap = Get.get(handler, "apply")

        if apply_trap == :undefined or apply_trap == nil do
          dispatch(target, args, ctx.gas, ctx, this)
        else
          dispatch(
            apply_trap,
            [target, this || :undefined, Heap.wrap_arguments(args)],
            ctx.gas,
            ctx,
            handler
          )
        end

      _ ->
        QuickBEAM.VM.JSThrow.type_error!("not a function")
    end
  end

  defp maybe_gc(result, extra_roots) do
    depth = Heap.get_invoke_depth() - 1
    Heap.put_invoke_depth(depth)

    if depth == 0 and Heap.gc_needed?() do
      Heap.gc([result | extra_roots])
    end

    result
  end

  defp track_invoke_depth do
    Heap.put_invoke_depth(Heap.get_invoke_depth() + 1)
  end

  defp call_context(%QuickBEAM.VM.Function{is_strict_mode: true}) do
    Context.mark_dirty(%{active_ctx() | this: :undefined})
  end

  defp call_context(_fun), do: active_ctx()

  defp dispatch_context(%QuickBEAM.VM.Function{is_strict_mode: true}, ctx, nil),
    do: Context.mark_dirty(%{ctx | this: :undefined})

  defp dispatch_context(_fun, ctx, _this), do: ctx

  defp runtime_call_context(%QuickBEAM.VM.Function{is_strict_mode: true}, ctx),
    do: Context.mark_dirty(%{ctx | this: :undefined})

  defp runtime_call_context(_fun, ctx), do: ctx

  defp active_ctx do
    base_globals = GlobalEnv.base_globals()

    case Heap.get_ctx() do
      %Context{} = ctx when ctx.globals == %{} ->
        Context.mark_dirty(%{ctx | globals: base_globals})

      %Context{} = ctx ->
        ctx

      nil ->
        %Context{atoms: Heap.get_atoms(), globals: base_globals}

      map ->
        struct(
          Context,
          Map.merge(Map.from_struct(%Context{}), Map.put(map, :globals, base_globals))
        )
    end
  end

  defp function_code_key(%QuickBEAM.VM.Function{id: id}) when is_integer(id), do: {:function, id}

  defp function_code_key(%QuickBEAM.VM.Function{instructions: instructions})
       when is_tuple(instructions),
       do: {:instructions, :erlang.phash2(instructions)}

  defp invoke_receiver_target(%QuickBEAM.VM.Function{} = fun, args, gas, this_obj) do
    if compiled_method_callable?(fun, this_obj) do
      case Runner.invoke_with_receiver(fun, args, this_obj) do
        {:ok, value} -> value
        :error -> Interpreter.invoke_function_fallback(fun, args, gas, Heap.get_ctx())
      end
    else
      Interpreter.invoke_function_fallback(fun, args, gas, Heap.get_ctx())
    end
  end

  defp invoke_receiver_target(
         {:closure, _, %QuickBEAM.VM.Function{} = inner} = closure,
         args,
         gas,
         this_obj
       ) do
    if compiled_method_callable?(inner, this_obj) do
      case Runner.invoke_with_receiver(closure, args, this_obj) do
        {:ok, value} -> value
        :error -> Interpreter.invoke_closure_fallback(closure, args, gas, Heap.get_ctx())
      end
    else
      Interpreter.invoke_closure_fallback(closure, args, gas, Heap.get_ctx())
    end
  end

  defp invoke_receiver_target(other, args, gas, this_obj),
    do: dispatch(other, args, gas, Heap.get_ctx(), this_obj)

  defp callback_invoke(fun, args, ctx, on_throw \\ fn -> :undefined end)

  defp callback_invoke(%QuickBEAM.VM.Function{} = fun, args, ctx, on_throw) do
    try do
      case Runner.invoke(fun, args, ctx) do
        {:ok, value} -> value
        :error -> Interpreter.invoke_function_fallback(fun, args, ctx.gas, ctx)
      end
    catch
      {:js_throw, _} -> on_throw.()
    end
  end

  defp callback_invoke(
         {:closure, _, %QuickBEAM.VM.Function{} = inner} = closure,
         args,
         ctx,
         on_throw
       ) do
    try do
      invoke_closure(closure, inner, args, ctx)
    catch
      {:js_throw, _} -> on_throw.()
    end
  end

  defp invoke_closure(closure, %QuickBEAM.VM.Function{need_home_object: false}, args, ctx) do
    case Runner.invoke(closure, args, ctx) do
      {:ok, value} -> value
      :error -> Interpreter.invoke_closure_fallback(closure, args, ctx.gas, ctx)
    end
  end

  defp invoke_closure(closure, _inner, args, ctx) do
    Interpreter.invoke_closure_fallback(closure, args, ctx.gas, ctx)
  end

  defp compiled_closure_callable?(%QuickBEAM.VM.Function{need_home_object: false}), do: true
  defp compiled_closure_callable?(_), do: false

  defp compiled_method_callable?(
         %QuickBEAM.VM.Function{need_home_object: false, func_kind: kind},
         {:obj, _}
       )
       when kind in [0, 2],
       do: true

  defp compiled_method_callable?(_, _), do: false

  defp validate_constructor!(%QuickBEAM.VM.Function{func_kind: kind, name: name})
       when kind in [1, 2, 3],
       do:
         throw(
           {:js_throw, Heap.make_error("#{name || "function"} is not a constructor", "TypeError")}
         )

  defp validate_constructor!(%QuickBEAM.VM.Function{has_prototype: false, name: name} = fun) do
    unless class_constructor_source?(fun) do
      throw(
        {:js_throw, Heap.make_error("#{name || "function"} is not a constructor", "TypeError")}
      )
    end
  end

  defp validate_constructor!(%QuickBEAM.VM.Function{}), do: :ok

  defp validate_constructor!({:closure, _, %QuickBEAM.VM.Function{func_kind: kind, name: name}})
       when kind in [1, 2, 3],
       do:
         throw(
           {:js_throw, Heap.make_error("#{name || "function"} is not a constructor", "TypeError")}
         )

  defp validate_constructor!(
         {:closure, _, %QuickBEAM.VM.Function{has_prototype: false, name: name} = fun}
       ) do
    unless class_constructor_source?(fun) do
      throw(
        {:js_throw, Heap.make_error("#{name || "function"} is not a constructor", "TypeError")}
      )
    end
  end

  defp validate_constructor!({:closure, _, %QuickBEAM.VM.Function{}}), do: :ok
  defp validate_constructor!({:bound, _, _inner, _orig_fun, _bound_args}), do: :ok

  defp validate_constructor!({:builtin, name, cb}) when is_function(cb, 2) do
    case QuickBEAM.VM.Builtin.named_meta(name) do
      %QuickBEAM.VM.Builtin.Meta{constructable?: false} ->
        throw({:js_throw, Heap.make_error("#{name} is not a constructor", "TypeError")})

      _ ->
        :ok
    end
  end

  defp validate_constructor!({:obj, _}), do: :ok

  defp validate_constructor!(ctor) do
    throw(
      {:js_throw,
       Heap.make_error(
         "#{QuickBEAM.VM.Interpreter.Values.stringify(ctor)} is not a constructor",
         "TypeError"
       )}
    )
  end

  defp class_constructor_source?(%QuickBEAM.VM.Function{source: source}) when is_binary(source) do
    source |> String.trim_leading() |> String.starts_with?("class")
  end

  defp class_constructor_source?(_), do: false

  def unwrap_constructor_target({:closure, _, %QuickBEAM.VM.Function{} = fun}), do: fun
  def unwrap_constructor_target({:bound, _, inner, _, _}), do: unwrap_constructor_target(inner)
  def unwrap_constructor_target(other), do: other

  defp unwrap_new_target({:closure, _, %QuickBEAM.VM.Function{} = fun}), do: fun
  defp unwrap_new_target({:bound, _, _, _, _} = bound), do: bound
  defp unwrap_new_target(%QuickBEAM.VM.Function{} = fun), do: fun
  defp unwrap_new_target({:builtin, _, _} = builtin), do: builtin
  defp unwrap_new_target(_), do: nil

  defp with_ctx(ctx, fun) do
    previous = Heap.get_ctx()
    Heap.put_ctx(ctx)

    try do
      fun.()
    after
      if previous, do: Heap.put_ctx(previous), else: Heap.put_ctx(nil)
    end
  end

  defp realm_default_prototype({:builtin, "Array", _}, new_target),
    do: QuickBEAM.VM.Runtime.Test262Host.realm_intrinsic(new_target, :array)

  defp realm_default_prototype({:builtin, "Map", _}, new_target),
    do: QuickBEAM.VM.Runtime.Test262Host.realm_intrinsic(new_target, :map)

  defp realm_default_prototype({:builtin, "Set", _}, new_target),
    do: QuickBEAM.VM.Runtime.Test262Host.realm_intrinsic(new_target, :set)

  defp realm_default_prototype({:builtin, "WeakMap", _}, new_target),
    do: QuickBEAM.VM.Runtime.Test262Host.realm_intrinsic(new_target, :weak_map)

  defp realm_default_prototype({:builtin, "WeakSet", _}, new_target),
    do: QuickBEAM.VM.Runtime.Test262Host.realm_intrinsic(new_target, :weak_set)

  defp realm_default_prototype({:builtin, "WeakRef", _}, new_target),
    do: QuickBEAM.VM.Runtime.Test262Host.realm_intrinsic(new_target, :weak_ref)

  defp realm_default_prototype({:builtin, "FinalizationRegistry", _}, new_target),
    do: QuickBEAM.VM.Runtime.Test262Host.realm_intrinsic(new_target, :finalization_registry)

  defp realm_default_prototype(_ctor, new_target),
    do: QuickBEAM.VM.Runtime.Test262Host.realm_intrinsic(new_target, :object)

  defp normalize_constructor_prototype({:obj, _} = object_proto), do: object_proto
  defp normalize_constructor_prototype(_), do: nil
end
