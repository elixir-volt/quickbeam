defmodule QuickBEAM.VM.Invocation do
  @moduledoc false

  import QuickBEAM.VM.Heap.Keys, only: [proto: 0]

  alias QuickBEAM.VM.{Builtin, Bytecode, Compiler, GlobalEnv, Heap, Runtime}
  alias QuickBEAM.VM.Compiler.Runner
  alias QuickBEAM.VM.Interpreter
  alias QuickBEAM.VM.Interpreter.Context
  alias QuickBEAM.VM.Invocation.Context, as: InvokeContext
  alias QuickBEAM.VM.ObjectModel.{Class, Get}

  def invoke(fun, args, gas \\ Runtime.gas_budget())

  def invoke(%Bytecode.Function{} = fun, args, gas) do
    case Compiler.invoke(fun, args) do
      {:ok, result} -> result
      :error -> Interpreter.invoke_function_fallback(fun, args, gas, active_ctx())
    end
  end

  def invoke({:closure, _, %Bytecode.Function{} = inner} = closure, args, gas) do
    if compiled_closure_callable?(inner) do
      case Runner.invoke(closure, args) do
        {:ok, result} -> result
        :error -> Interpreter.invoke_closure_fallback(closure, args, gas, active_ctx())
      end
    else
      Interpreter.invoke_closure_fallback(closure, args, gas, active_ctx())
    end
  end

  def invoke(other, args, _gas) when not is_tuple(other) or elem(other, 0) != :bound,
    do: Builtin.call(other, args, nil)

  def invoke({:bound, _, inner, _, _}, args, gas), do: invoke(inner, args, gas)

  def invoke_with_receiver(fun, args, this_obj),
    do: invoke_with_receiver(fun, args, Runtime.gas_budget(), this_obj)

  def invoke_with_receiver(fun, args, gas, this_obj) do
    prev = Heap.get_ctx()
    Heap.put_ctx(%{active_ctx() | this: this_obj} |> InvokeContext.attach_method_state())

    try do
      invoke_receiver_target(fun, args, gas, this_obj)
    after
      if prev, do: Heap.put_ctx(prev), else: Heap.put_ctx(nil)
    end
  end

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

  def dispatch(fun, args, gas, ctx, this) do
    case fun do
      %Bytecode.Function{} = bytecode_fun ->
        Interpreter.invoke_function_fallback(bytecode_fun, args, gas, ctx)

      {:closure, _, %Bytecode.Function{}} = closure ->
        Interpreter.invoke_closure_fallback(closure, args, gas, ctx)

      {:bound, _, inner, _, _} ->
        invoke(inner, args, gas)

      other ->
        Builtin.call(other, args, this)
    end
  end

  def call_callback(fun, args), do: call_callback(active_ctx(), fun, args)

  def call_callback(ctx, fun, args) do
    case fun do
      %Bytecode.Function{} = bytecode_fun ->
        callback_invoke(bytecode_fun, args, ctx)

      {:closure, _, %Bytecode.Function{}} = closure ->
        callback_invoke(closure, args, ctx)

      other ->
        try do
          Builtin.call(other, args, nil)
        catch
          {:js_throw, _} -> :undefined
        end
    end
  end

  def invoke_callback(fun, args), do: invoke_callback(active_ctx(), fun, args)

  def invoke_callback(ctx, fun, args) do
    case fun do
      %Bytecode.Function{} = bytecode_fun ->
        callback_invoke(bytecode_fun, args, ctx, fn -> List.first(args, :undefined) end)

      {:closure, _, %Bytecode.Function{}} = closure ->
        callback_invoke(closure, args, ctx, fn -> List.first(args, :undefined) end)

      _ ->
        try do
          Builtin.call(fun, args, nil)
        catch
          {:js_throw, _} -> List.first(args, :undefined)
        end
    end
  end

  def invoke_runtime(fun, args), do: invoke_runtime(active_ctx(), fun, args)

  def invoke_runtime(ctx, fun, args) do
    case fun do
      %Bytecode.Function{} = bytecode_fun ->
        case Runner.invoke(bytecode_fun, args, ctx) do
          {:ok, value} -> value
          :error -> Interpreter.invoke_function_fallback(bytecode_fun, args, ctx.gas, ctx)
        end

      {:closure, _, %Bytecode.Function{} = inner} = closure ->
        if compiled_closure_callable?(inner) do
          case Runner.invoke(closure, args, ctx) do
            {:ok, value} -> value
            :error -> Interpreter.invoke_closure_fallback(closure, args, ctx.gas, ctx)
          end
        else
          Interpreter.invoke_closure_fallback(closure, args, ctx.gas, ctx)
        end

      {:bound, _, inner, _, _} ->
        invoke_runtime(ctx, inner, args)

      other ->
        Builtin.call(other, args, nil)
    end
  end

  def invoke_method_runtime(fun, this_obj, args),
    do: invoke_method_runtime(active_ctx(), fun, this_obj, args)

  def invoke_method_runtime(ctx, fun, this_obj, args) do
    case fun do
      %Bytecode.Function{} = bytecode_fun ->
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

      {:closure, _, %Bytecode.Function{} = inner} = closure ->
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

      other ->
        Builtin.call(other, args, this_obj)
    end
  end

  def construct_runtime(ctor, new_target, args),
    do: construct_runtime(active_ctx(), ctor, new_target, args)

  def construct_runtime(ctx, ctor, new_target, args) do
    raw_ctor = unwrap_constructor_target(ctor)
    raw_new_target = unwrap_new_target(new_target)

    ctor_proto =
      constructor_prototype(raw_new_target) || constructor_prototype(raw_ctor) ||
        Heap.get_object_prototype()

    init = if ctor_proto, do: %{proto() => ctor_proto}, else: %{}
    this_obj = Heap.wrap(init)

    result =
      case ctor do
        %Bytecode.Function{} = fun ->
          case Runner.invoke_constructor(fun, args, this_obj, new_target, ctx) do
            {:ok, value} -> value
            :error -> invoke_constructor(fun, args, ctx.gas, this_obj, new_target)
          end

        {:closure, _, %Bytecode.Function{}} = closure ->
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

    Class.coalesce_this_result(result, this_obj)
  end

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

  defp invoke_receiver_target(%Bytecode.Function{} = fun, args, gas, this_obj) do
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
         {:closure, _, %Bytecode.Function{} = inner} = closure,
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

  defp callback_invoke(%Bytecode.Function{} = fun, args, ctx, on_throw) do
    try do
      case Runner.invoke(fun, args, ctx) do
        {:ok, value} -> value
        :error -> Interpreter.invoke_function_fallback(fun, args, ctx.gas, ctx)
      end
    catch
      {:js_throw, _} -> on_throw.()
    end
  end

  defp callback_invoke({:closure, _, %Bytecode.Function{} = inner} = closure, args, ctx, on_throw) do
    try do
      if compiled_closure_callable?(inner) do
        case Runner.invoke(closure, args, ctx) do
          {:ok, value} -> value
          :error -> Interpreter.invoke_closure_fallback(closure, args, ctx.gas, ctx)
        end
      else
        Interpreter.invoke_closure_fallback(closure, args, ctx.gas, ctx)
      end
    catch
      {:js_throw, _} -> on_throw.()
    end
  end

  defp compiled_closure_callable?(%Bytecode.Function{need_home_object: false}), do: true
  defp compiled_closure_callable?(_), do: false

  defp compiled_method_callable?(%Bytecode.Function{need_home_object: false}, {:obj, _}), do: true
  defp compiled_method_callable?(_, _), do: false

  defp unwrap_constructor_target({:closure, _, %Bytecode.Function{} = fun}), do: fun
  defp unwrap_constructor_target({:bound, _, inner, _, _}), do: unwrap_constructor_target(inner)
  defp unwrap_constructor_target(other), do: other

  defp unwrap_new_target({:closure, _, %Bytecode.Function{} = fun}), do: fun
  defp unwrap_new_target(%Bytecode.Function{} = fun), do: fun
  defp unwrap_new_target(_), do: nil

  defp constructor_prototype(nil), do: nil

  defp constructor_prototype(target) do
    case Heap.get_class_proto(target) do
      {:obj, _} = proto_obj -> proto_obj
      _ -> normalize_constructor_prototype(Get.get(target, "prototype"))
    end
  end

  defp normalize_constructor_prototype({:obj, _} = object_proto), do: object_proto
  defp normalize_constructor_prototype(_), do: nil
end
