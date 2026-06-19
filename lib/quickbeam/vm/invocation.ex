defmodule QuickBEAM.VM.Invocation do
  @moduledoc """
  Unified JavaScript function invocation.

  Spec relation:
  - ECMA-262 §7.3.13 Call
  - ECMA-262 §7.3.14 Construct
  - ECMA-262 §10.2.1 [[Call]]
  - ECMA-262 §10.2.2 [[Construct]]
  - ECMA-262 §10.4.1 Bound Function Exotic Objects

  This module dispatches to compiled modules, interpreter fallback, built-ins,
  constructors, bound functions, and native callbacks while preserving the VM's
  shared call/construct semantics.
  """

  import QuickBEAM.VM.Heap.Keys, only: [proto: 0, proxy_handler: 0, proxy_target: 0]

  alias QuickBEAM.VM.{
    Builtin,
    Compiler,
    GlobalEnvironment,
    Heap,
    Realm,
    Runtime,
    RuntimeState,
    Value
  }

  alias QuickBEAM.VM.Compiler.FunctionInfo
  alias QuickBEAM.VM.Compiler.Runner
  alias QuickBEAM.VM.Interpreter
  alias QuickBEAM.VM.Interpreter.Context
  alias QuickBEAM.VM.Invocation.Context, as: InvokeContext
  alias QuickBEAM.VM.ObjectModel.{Class, Get}

  @doc "Invokes a JavaScript callable with positional arguments and a gas budget."
  def invoke(fun, args, gas \\ Runtime.gas_budget())

  def invoke(%QuickBEAM.VM.Function{} = fun, args, gas) do
    with_invoke_depth([fun | args], fn ->
      case Compiler.invoke(fun, args, call_context(fun)) do
        {:ok, result} -> result
        {:error, {:js_throw, error}} -> throw({:js_throw, error})
        :error -> Interpreter.invoke_function_fallback(fun, args, gas, call_context(fun))
      end
    end)
  end

  def invoke({:closure, _, %QuickBEAM.VM.Function{} = inner} = closure, args, gas) do
    with_invoke_depth([closure | args], fn ->
      if compiled_closure_callable?(inner) do
        case Runner.invoke(closure, args, call_context(inner)) do
          {:ok, result} -> result
          :error -> Interpreter.invoke_closure_fallback(closure, args, gas, call_context(inner))
        end
      else
        Interpreter.invoke_closure_fallback(closure, args, gas, call_context(inner))
      end
    end)
  end

  def invoke(other, args, _gas) when not is_tuple(other) or elem(other, 0) != :bound,
    do: Builtin.call(other, args, nil)

  def invoke({:bound, _, inner, _, _}, args, gas), do: invoke(inner, args, gas)

  @doc "Invokes a JavaScript callable with an explicit `this` receiver."
  def invoke_with_receiver(fun, args, this_obj),
    do: invoke_with_receiver(fun, args, Runtime.gas_budget(), this_obj)

  def invoke_with_receiver(fun, args, gas, this_obj) do
    with_invoke_depth([fun, this_obj | args], fn ->
      prev = RuntimeState.current()

      RuntimeState.install(
        %{active_ctx() | this: this_obj}
        |> InvokeContext.attach_method_state()
      )

      try do
        invoke_receiver_target(fun, args, gas, this_obj)
      after
        if prev do
          prev |> GlobalEnvironment.refresh() |> RuntimeState.install()
        else
          RuntimeState.restore(nil)
        end
      end
    end)
  end

  @doc "Returns true when a value can be used as an ECMAScript constructor."
  def constructor?(value) do
    validate_constructor!(value)
    true
  catch
    {:js_throw, _error} -> false
  end

  @doc "Invokes a JavaScript constructor with `this` and `new.target` context."
  def invoke_constructor(fun, args, this_obj, new_target),
    do: invoke_constructor(fun, args, Runtime.gas_budget(), this_obj, new_target)

  def invoke_constructor(fun, args, gas, this_obj, new_target) do
    prev = RuntimeState.current()

    ctor_ctx =
      %{active_ctx() | this: this_obj, new_target: new_target}
      |> InvokeContext.attach_method_state()

    RuntimeState.install(ctor_ctx)

    try do
      dispatch(fun, args, gas, ctor_ctx, this_obj)
    after
      RuntimeState.restore(prev)
    end
  end

  @doc "Dispatches a callable to bytecode, closure, bound-function, or builtin execution."
  def dispatch(fun, args, gas, ctx, this) do
    case fun do
      %QuickBEAM.VM.Function{} = bytecode_fun ->
        reject_class_constructor_call!(bytecode_fun)

        Interpreter.invoke_function_fallback(
          bytecode_fun,
          args,
          gas,
          dispatch_context(bytecode_fun, ctx, this)
        )

      {:closure, _, %QuickBEAM.VM.Function{} = inner} = closure ->
        reject_class_constructor_call!(inner)

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
  def call_callback!(fun, args, this_obj \\ nil)

  def call_callback!(fun, args, this_obj) do
    ctx = active_ctx()

    callback_ctx =
      if this_obj == nil, do: ctx, else: %{ctx | this: this_obj} |> Context.mark_dirty()

    case fun do
      {:closure, _, %QuickBEAM.VM.Function{need_home_object: false, closure_vars: []}} = closure ->
        case Runner.invoke(closure, args, callback_ctx) do
          {:ok, value} ->
            value

          :error ->
            Interpreter.invoke_closure_fallback(closure, args, callback_ctx.gas, callback_ctx)
        end

      {:closure, _, %QuickBEAM.VM.Function{}} = closure ->
        Interpreter.invoke_closure_fallback(closure, args, callback_ctx.gas, callback_ctx)

      %QuickBEAM.VM.Function{} = bytecode_fun ->
        case Runner.invoke(bytecode_fun, args, callback_ctx) do
          {:ok, value} ->
            value

          :error ->
            Interpreter.invoke_function_fallback(
              bytecode_fun,
              args,
              callback_ctx.gas,
              callback_ctx
            )
        end

      {:obj, _} = obj ->
        dispatch_proxy_call(obj, args, callback_ctx, this_obj)

      other ->
        Builtin.call(other, args, this_obj)
    end
  end

  @doc "Compatibility wrapper for call_callback!/3."
  def invoke_callback_or_throw(fun, args, this_obj \\ nil),
    do: call_callback!(fun, args, this_obj)

  @doc "Invokes a callback, converting JavaScript throws to `:undefined`."
  def call_callback_or_undefined(fun, args),
    do: call_callback_or_undefined(active_ctx(), fun, args)

  def call_callback_or_undefined(ctx, fun, args) do
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

  @doc "Compatibility wrapper for call_callback_or_undefined/2."
  def call_callback(fun, args), do: call_callback_or_undefined(fun, args)

  def call_callback(ctx, fun, args), do: call_callback_or_undefined(ctx, fun, args)

  @doc "Invokes a callback, returning the first callback argument when JavaScript throws."
  def call_callback_or_first_arg(fun, args),
    do: call_callback_or_first_arg(active_ctx(), fun, args)

  def call_callback_or_first_arg(ctx, fun, args) do
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

  @doc "Compatibility wrapper for call_callback_or_first_arg/2."
  def invoke_callback(fun, args), do: call_callback_or_first_arg(fun, args)

  def invoke_callback(ctx, fun, args), do: call_callback_or_first_arg(ctx, fun, args)

  @doc "Invokes a callable from compiler-generated runtime helper code."
  def invoke_runtime(fun, args), do: invoke_runtime(active_ctx(), fun, args)

  def invoke_runtime(
        %Context{} = ctx,
        {:closure, _, %QuickBEAM.VM.Function{need_home_object: false, closure_vars: []} = inner} =
          closure,
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
                Heap.wrap_arguments(args, callee: closure)
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
    with_invoke_depth([fun, this_obj | args], fn ->
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
    end)
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
      prevalidate_builtin_construct_args!(raw_ctor, args)

      new_target_proto = Get.get(new_target, "prototype")
      reject_revoked_proxy_new_target!(new_target, new_target_proto)

      ctor_proto =
        if raw_new_target != nil and raw_new_target != raw_ctor do
          normalize_constructor_prototype(new_target_proto) ||
            QuickBEAM.VM.Realm.default_prototype(raw_ctor, raw_new_target) ||
            Heap.get_class_proto(raw_new_target) ||
            Heap.get_class_proto(raw_ctor) || Heap.get_or_create_prototype(ctor)
        else
          normalize_constructor_prototype(new_target_proto) ||
            QuickBEAM.VM.Realm.default_prototype(raw_ctor, raw_new_target) ||
            Heap.get_class_proto(raw_ctor) || Heap.get_or_create_prototype(ctor)
        end

      derived_constructor? =
        match?(%QuickBEAM.VM.Function{is_derived_class_constructor: true}, raw_ctor)

      pending_private_brand? =
        derived_constructor? or
          match?(%QuickBEAM.VM.Function{is_derived_class_constructor: true}, raw_new_target)

      init = if ctor_proto, do: %{proto() => ctor_proto}, else: %{}
      this_obj = Heap.wrap(init)
      Heap.put_pending_private_brand(this_obj, pending_private_brand?)

      result =
        case ctor do
          {:obj, _} = obj ->
            construct_proxy_runtime(ctx, obj, new_target, args)

          %QuickBEAM.VM.Function{} = fun ->
            if Class.default_derived_constructor?(fun) do
              super_this =
                fun
                |> Class.get_super()
                |> construct_runtime(new_target, args)

              initialize_default_derived_fields(ctx, fun, super_this)
              super_this
            else
              case Runner.invoke_constructor(fun, args, this_obj, new_target, ctx) do
                {:ok, value} ->
                  value

                :error ->
                  Interpreter.invoke_constructor_fallback(
                    fun,
                    args,
                    ctx.gas,
                    ctx,
                    this_obj,
                    new_target
                  )
              end
            end

          {:closure, _, %QuickBEAM.VM.Function{} = fun} = closure ->
            if Class.default_derived_constructor?(fun) do
              super_this =
                closure
                |> Class.get_super()
                |> construct_runtime(new_target, args)

              initialize_default_derived_fields(ctx, closure, super_this)
              super_this
            else
              case Runner.invoke_constructor(closure, args, this_obj, new_target, ctx) do
                {:ok, value} ->
                  value

                :error ->
                  Interpreter.invoke_constructor_fallback(
                    closure,
                    args,
                    ctx.gas,
                    ctx,
                    this_obj,
                    new_target
                  )
              end
            end

          {:bound, _, _inner, orig_fun, bound_args} ->
            adjusted_new_target = if new_target == ctor, do: orig_fun, else: new_target
            construct_runtime(orig_fun, adjusted_new_target, bound_args ++ args)

          {:builtin, _name, cb} when is_function(cb, 2) ->
            ctor_ctx = Context.mark_dirty(%{ctx | this: this_obj, new_target: new_target})
            with_ctx(ctor_ctx, fn -> cb.(args, this_obj) end)

          _ ->
            this_obj
        end

      case raw_ctor do
        {:builtin, "Object", _} -> result
        _ -> Class.coalesce_this_result(result, this_obj)
      end
    end)
  end

  defp initialize_default_derived_fields(ctx, ctor, this_obj) do
    case default_derived_field_initializer(ctor) do
      nil -> :ok
      :undefined -> :ok
      initializer -> invoke_method_runtime(ctx, initializer, this_obj, [])
    end
  end

  defp default_derived_field_initializer({:closure, captured, %QuickBEAM.VM.Function{} = fun}) do
    fun
    |> default_derived_field_initializer_key()
    |> then(fn
      nil -> nil
      key -> captured_value(Map.get(captured, key))
    end)
  end

  defp default_derived_field_initializer(%QuickBEAM.VM.Function{}), do: nil

  defp default_derived_field_initializer_key(%QuickBEAM.VM.Function{} = fun) do
    Enum.find_value(fun.closure_vars, fn closure_var ->
      if QuickBEAM.VM.Names.resolve_display_name(closure_var.name) == "<class_fields_init>" do
        {closure_var.closure_type, closure_var.var_idx}
      end
    end)
  end

  defp captured_value({:cell, ref}), do: Heap.get_cell(ref)
  defp captured_value(value), do: value

  defp construct_proxy_runtime(ctx, {:obj, ref} = proxy, new_target, args) do
    case Heap.get_obj(ref, %{}) do
      %{"__proxy_revoked__" => true} ->
        QuickBEAM.VM.JSThrow.type_error!("Cannot perform operation on a revoked proxy")

      %{proxy_target() => target, proxy_handler() => handler} ->
        validate_constructor!(target)
        construct_trap = Get.get(handler, "construct")

        if Value.nullish?(construct_trap) do
          construct_runtime(ctx, target, new_target, args)
        else
          result =
            dispatch(
              construct_trap,
              [target, Heap.wrap(args), new_target],
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
             "#{QuickBEAM.VM.Semantics.Values.stringify(proxy)} is not a constructor",
             "TypeError"
           )}
        )
    end
  end

  defp dispatch_proxy_call({:obj, ref}, args, ctx, this) do
    case Heap.get_obj(ref, %{}) do
      %{"__proxy_revoked__" => true} ->
        QuickBEAM.VM.JSThrow.type_error!("Cannot perform operation on a revoked proxy")

      %{proxy_target() => target, proxy_handler() => handler} ->
        unless Builtin.callable?(target) do
          QuickBEAM.VM.JSThrow.type_error!("not a function")
        end

        apply_trap = Get.get(handler, "apply")

        if Value.nullish?(apply_trap) do
          dispatch(target, args, ctx.gas, ctx, this)
        else
          dispatch(
            apply_trap,
            [target, this || :undefined, Heap.wrap(args)],
            ctx.gas,
            ctx,
            handler
          )
        end

      _ ->
        if {:obj, ref} == Heap.get_func_proto() do
          :undefined
        else
          QuickBEAM.VM.JSThrow.type_error!("not a function")
        end
    end
  end

  defp with_invoke_depth(extra_roots, callback) when is_function(callback, 0) do
    track_invoke_depth()

    try do
      result = callback.()
      maybe_gc(result, extra_roots)
    catch
      kind, reason ->
        maybe_gc(reason, extra_roots)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp maybe_gc(result, extra_roots) do
    depth = max(Heap.get_invoke_depth() - 1, 0)
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

  defp call_context(fun) do
    ctx = active_ctx()
    Context.mark_dirty(%{ctx | this: default_call_this(fun, ctx)})
  end

  defp dispatch_context(%QuickBEAM.VM.Function{is_strict_mode: true}, ctx, nil),
    do: Context.mark_dirty(%{ctx | this: :undefined})

  defp dispatch_context(fun, ctx, nil),
    do: Context.mark_dirty(%{ctx | this: default_call_this(fun, ctx)})

  defp dispatch_context(_fun, ctx, this), do: Context.mark_dirty(%{ctx | this: this})

  defp runtime_call_context(%QuickBEAM.VM.Function{is_strict_mode: true}, ctx),
    do: Context.mark_dirty(%{ctx | this: :undefined})

  defp runtime_call_context(fun, ctx),
    do: Context.mark_dirty(%{ctx | this: default_call_this(fun, ctx)})

  defp default_call_this(fun, ctx) do
    Realm.global(fun) || Map.get(ctx.globals, "globalThis", ctx.this)
  end

  defp active_ctx do
    base_globals = GlobalEnvironment.base_globals()

    case RuntimeState.current() do
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

  defp function_code_key(fun), do: FunctionInfo.code_key(fun)

  defp invoke_receiver_target(%QuickBEAM.VM.Function{} = fun, args, gas, this_obj) do
    if compiled_method_callable?(fun, this_obj) do
      case Runner.invoke_with_receiver(fun, args, this_obj) do
        {:ok, value} -> value
        :error -> Interpreter.invoke_function_fallback(fun, args, gas, RuntimeState.current())
      end
    else
      Interpreter.invoke_function_fallback(fun, args, gas, RuntimeState.current())
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
        :error -> Interpreter.invoke_closure_fallback(closure, args, gas, RuntimeState.current())
      end
    else
      Interpreter.invoke_closure_fallback(closure, args, gas, RuntimeState.current())
    end
  end

  defp invoke_receiver_target(other, args, gas, this_obj),
    do: dispatch(other, args, gas, RuntimeState.current(), this_obj)

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

  defp invoke_closure(
         closure,
         %QuickBEAM.VM.Function{need_home_object: false, closure_vars: []},
         args,
         ctx
       ) do
    case Runner.invoke(closure, args, ctx) do
      {:ok, value} -> value
      :error -> Interpreter.invoke_closure_fallback(closure, args, ctx.gas, ctx)
    end
  end

  defp invoke_closure(closure, _inner, args, ctx) do
    Interpreter.invoke_closure_fallback(closure, args, ctx.gas, ctx)
  end

  defp compiled_closure_callable?(%QuickBEAM.VM.Function{
         need_home_object: false,
         closure_vars: []
       }),
       do: true

  defp compiled_closure_callable?(_), do: false

  defp compiled_method_callable?(
         %QuickBEAM.VM.Function{need_home_object: false, func_kind: kind, closure_vars: []},
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

  defp validate_constructor!({:builtin, name, cb} = ctor) when is_function(cb, 2) do
    case QuickBEAM.VM.Builtin.metadata_for(ctor) do
      %QuickBEAM.VM.Builtin.Meta{constructable?: false} ->
        throw({:js_throw, Heap.make_error("#{name} is not a constructor", "TypeError")})

      _ ->
        :ok
    end
  end

  defp validate_constructor!({:obj, ref} = ctor) do
    case Heap.get_obj(ref, %{}) do
      %{proxy_target() => target} ->
        validate_constructor!(target)

      _ ->
        throw(
          {:js_throw,
           Heap.make_error(
             "#{QuickBEAM.VM.Semantics.Values.stringify(ctor)} is not a constructor",
             "TypeError"
           )}
        )
    end
  end

  defp validate_constructor!(ctor) do
    throw(
      {:js_throw,
       Heap.make_error(
         "#{QuickBEAM.VM.Semantics.Values.stringify(ctor)} is not a constructor",
         "TypeError"
       )}
    )
  end

  defp class_constructor_source?(%QuickBEAM.VM.Function{source: source}) when is_binary(source) do
    source |> String.trim_leading() |> String.starts_with?("class")
  end

  defp class_constructor_source?(_), do: false

  defp reject_class_constructor_call!(%QuickBEAM.VM.Function{} = fun) do
    if class_constructor_source?(fun) do
      throw(
        {:js_throw,
         Heap.make_error("Class constructor cannot be invoked without 'new'", "TypeError")}
      )
    end
  end

  def unwrap_constructor_target({:closure, _, %QuickBEAM.VM.Function{} = fun}), do: fun
  def unwrap_constructor_target({:bound, _, inner, _, _}), do: unwrap_constructor_target(inner)
  def unwrap_constructor_target(other), do: other

  defp unwrap_new_target({:closure, _, %QuickBEAM.VM.Function{} = fun}), do: fun
  defp unwrap_new_target({:bound, _, _, _, _} = bound), do: bound
  defp unwrap_new_target(%QuickBEAM.VM.Function{} = fun), do: fun
  defp unwrap_new_target({:builtin, _, _} = builtin), do: builtin

  defp unwrap_new_target({:obj, ref} = obj) do
    case Heap.get_obj(ref, %{}) do
      %{proxy_target() => _target} -> obj
      _ -> nil
    end
  end

  defp unwrap_new_target(_), do: nil

  defp with_ctx(ctx, fun), do: RuntimeState.with_context(ctx, fun)

  defp reject_revoked_proxy_new_target!({:obj, ref}, proto) do
    if normalize_constructor_prototype(proto) == nil do
      case Heap.get_obj(ref, %{}) do
        %{"__proxy_revoked__" => true, proxy_target() => _target} ->
          QuickBEAM.VM.JSThrow.type_error!("Cannot perform operation on a revoked proxy")

        _ ->
          :ok
      end
    end
  end

  defp reject_revoked_proxy_new_target!(_new_target, _proto), do: :ok

  defp prevalidate_builtin_construct_args!({:builtin, name, _}, args)
       when name in ["ArrayBuffer", "SharedArrayBuffer"],
       do: QuickBEAM.VM.Runtime.ArrayBuffer.prevalidate_construct_args!(args)

  defp prevalidate_builtin_construct_args!({:builtin, "DataView", _}, args),
    do: QuickBEAM.VM.Runtime.DataView.prevalidate_construct_args!(args)

  defp prevalidate_builtin_construct_args!({:builtin, "Promise", _}, args) do
    executor = QuickBEAM.VM.Builtin.arg(args, 0, :undefined)

    unless QuickBEAM.VM.Builtin.callable?(executor) do
      QuickBEAM.VM.JSThrow.type_error!("Promise resolver is not a function")
    end
  end

  defp prevalidate_builtin_construct_args!({:builtin, name, _}, args) do
    if QuickBEAM.VM.Runtime.TypedArray.constructor_type(name) != nil do
      QuickBEAM.VM.Runtime.TypedArray.prevalidate_construct_args!(args)
    end
  end

  defp prevalidate_builtin_construct_args!(_ctor, _args), do: :ok

  defp normalize_constructor_prototype({:obj, _} = object_proto), do: object_proto
  defp normalize_constructor_prototype(%QuickBEAM.VM.Function{} = fun), do: fun
  defp normalize_constructor_prototype({:closure, _, %QuickBEAM.VM.Function{}} = fun), do: fun
  defp normalize_constructor_prototype({:bound, _, _, _, _} = fun), do: fun
  defp normalize_constructor_prototype({:builtin, _, _} = fun), do: fun
  defp normalize_constructor_prototype(_), do: nil
end
