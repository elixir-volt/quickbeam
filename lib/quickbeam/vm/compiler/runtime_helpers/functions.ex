defmodule QuickBEAM.VM.Compiler.RuntimeHelpers.Functions do
  @moduledoc "Function invocation, construction, class definition, method definition, error throwing."

  alias QuickBEAM.VM.{Bytecode, Heap, Invocation, JSThrow, Names}
  alias QuickBEAM.VM.Compiler.Runner
  alias QuickBEAM.VM.Compiler.RuntimeHelpers.Coercion
  alias QuickBEAM.VM.Interpreter.Context
  alias QuickBEAM.VM.Invocation.Context, as: InvokeContext
  alias QuickBEAM.VM.ObjectModel.{Class, Methods, Private}

  def construct_runtime(ctx, ctor, new_target, args),
    do: Invocation.construct_runtime(ctx, ctor, new_target, args)

  def construct_runtime(ctor, new_target, args),
    do: Invocation.construct_runtime(ctor, new_target, args)

  def init_ctor(ctx) do
    current_func = Coercion.context_current_func(ctx)

    raw =
      case current_func do
        {:closure, _, %Bytecode.Function{} = f} -> f
        %Bytecode.Function{} = f -> f
        other -> other
      end

    parent = Heap.get_parent_ctor(raw)
    args = Tuple.to_list(Coercion.context_arg_buf(ctx))

    pending_this =
      case Coercion.context_this(ctx) do
        {:uninitialized, {:obj, _} = obj} -> obj
        {:obj, _} = obj -> obj
        other -> other
      end

    parent_ctx = Context.mark_dirty(%{Coercion.ensure_context(ctx) | this: pending_this})

    result =
      case parent do
        nil ->
          pending_this

        %Bytecode.Function{} = f ->
          case Runner.invoke_constructor(
                 {:closure, %{}, f},
                 args,
                 pending_this,
                 Coercion.context_new_target(ctx),
                 parent_ctx
               ) do
            {:ok, val} ->
              val

            :error ->
              Invocation.invoke_with_receiver(
                {:closure, %{}, f},
                args,
                Coercion.context_gas(ctx),
                pending_this
              )
          end

        {:closure, _, %Bytecode.Function{}} = closure ->
          case Runner.invoke_constructor(
                 closure,
                 args,
                 pending_this,
                 Coercion.context_new_target(ctx),
                 parent_ctx
               ) do
            {:ok, val} ->
              val

            :error ->
              Invocation.invoke_with_receiver(
                closure,
                args,
                Coercion.context_gas(ctx),
                pending_this
              )
          end

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

    Heap.put_ctx(Context.mark_dirty(%{parent_ctx | this: result}))
    result
  end

  def invoke_runtime(ctx, fun, args), do: Invocation.invoke_runtime(ctx, fun, args)
  def invoke_runtime(fun, args), do: Invocation.invoke_runtime(fun, args)

  def invoke_method_runtime(ctx, fun, this_obj, args),
    do: Invocation.invoke_method_runtime(ctx, fun, this_obj, args)

  def invoke_method_runtime(fun, this_obj, args),
    do: Invocation.invoke_method_runtime(fun, this_obj, args)

  def invoke_tail_method(ctx, fun, this_obj, args),
    do: Invocation.invoke_method_runtime(ctx, fun, this_obj, args)

  def define_class(ctx, ctor, parent_ctor, atom_idx) do
    ctor_closure =
      case ctor do
        %Bytecode.Function{} = fun -> {:closure, %{}, fun}
        other -> other
      end

    Class.define_class(
      ctor_closure,
      parent_ctor,
      Names.resolve_atom(Coercion.context_atoms(ctx), atom_idx)
    )
  end

  def define_class(ctor, parent_ctor, atom_idx) do
    ctor_closure =
      case ctor do
        %Bytecode.Function{} = fun -> {:closure, %{}, fun}
        other -> other
      end

    Class.define_class(
      ctor_closure,
      parent_ctor,
      Names.resolve_atom(InvokeContext.current_atoms(), atom_idx)
    )
  end

  def define_method(_ctx, target, method, name, flags) when is_binary(name),
    do: define_method(target, method, name, flags)

  def define_method(ctx, target, method, atom_idx, flags),
    do:
      Methods.define_method(
        target,
        method,
        Names.resolve_atom(Coercion.context_atoms(ctx), atom_idx),
        flags
      )

  def define_method(target, method, name, flags) when is_binary(name),
    do: Methods.define_method(target, method, name, flags)

  def define_method(target, method, atom_idx, flags),
    do:
      Methods.define_method(
        target,
        method,
        Names.resolve_atom(InvokeContext.current_atoms(), atom_idx),
        flags
      )

  def define_method_computed(_ctx \\ nil, target, method, field_name, flags),
    do: Methods.define_method_computed(target, method, field_name, flags)

  def add_brand(_ctx \\ nil, target, brand), do: Private.add_brand(target, brand)

  def check_brand(_ctx, obj, brand) do
    case Private.ensure_brand(obj, brand) do
      :ok -> :ok
      :error -> throw({:js_throw, Private.brand_error()})
    end
  end

  def throw_error(ctx, atom_idx, reason) do
    name = Names.resolve_atom(Coercion.context_atoms(ctx), atom_idx)
    {error_type, message} = throw_error_message(name, reason)
    throw({:js_throw, Heap.make_error(message, error_type)})
  end

  def throw_error_message(name, reason) do
    case reason do
      0 -> {"TypeError", "'#{name}' is read-only"}
      1 -> {"SyntaxError", "redeclaration of '#{name}'"}
      2 -> {"ReferenceError", "cannot access '#{name}' before initialization"}
      3 -> {"ReferenceError", "unsupported reference to 'super'"}
      4 -> {"TypeError", "iterator does not have a throw method"}
      _ -> {"Error", name}
    end
  end

  def apply_super(ctx, fun, new_target, args),
    do: Invocation.construct_runtime(ctx, fun, new_target, args)

  def apply_super(fun, new_target, args),
    do: Invocation.construct_runtime(fun, new_target, args)

  def push_this(ctx) do
    case Coercion.context_this(ctx) do
      this
      when this == :uninitialized or
             (is_tuple(this) and tuple_size(this) == 2 and elem(this, 0) == :uninitialized) ->
        JSThrow.reference_error!("this is not initialized")

      this ->
        this
    end
  end

  def push_this do
    case InvokeContext.current_this() do
      this
      when this == :uninitialized or
             (is_tuple(this) and tuple_size(this) == 2 and elem(this, 0) == :uninitialized) ->
        JSThrow.reference_error!("this is not initialized")

      this ->
        this
    end
  end

  def special_object(ctx, type) do
    current_func = Coercion.context_current_func(ctx)
    arg_buf = Coercion.context_arg_buf(ctx)

    case type do
      0 -> Heap.wrap(Tuple.to_list(arg_buf))
      1 -> Heap.wrap(Tuple.to_list(arg_buf))
      2 -> current_func
      3 -> Coercion.context_new_target(ctx)
      4 -> Coercion.context_home_object(ctx, current_func)
      5 -> Heap.wrap(%{})
      6 -> Heap.wrap(%{})
      7 -> Heap.wrap(%{"__proto__" => nil})
      _ -> :undefined
    end
  end

  def special_object(type) do
    case InvokeContext.fast_ctx() do
      {_atoms, _globals, current_func, arg_buf, _this, new_target, home_object, _super} ->
        case type do
          0 -> Heap.wrap(Tuple.to_list(arg_buf))
          1 -> Heap.wrap(Tuple.to_list(arg_buf))
          2 -> current_func
          3 -> new_target
          4 -> home_object
          5 -> Heap.wrap(%{})
          6 -> Heap.wrap(%{})
          7 -> Heap.wrap(%{"__proto__" => nil})
          _ -> :undefined
        end

      _ ->
        current_func = InvokeContext.current_func()
        arg_buf = InvokeContext.current_arg_buf()

        case type do
          0 -> Heap.wrap(Tuple.to_list(arg_buf))
          1 -> Heap.wrap(Tuple.to_list(arg_buf))
          2 -> current_func
          3 -> InvokeContext.current_new_target()
          4 -> InvokeContext.current_home_object(current_func)
          5 -> Heap.wrap(%{})
          6 -> Heap.wrap(%{})
          7 -> Heap.wrap(%{"__proto__" => nil})
          _ -> :undefined
        end
    end
  end

  def update_this(ctx, this_val), do: Context.mark_dirty(%{ctx | this: this_val})

  def update_this(this_val) do
    case Heap.get_ctx() do
      %Context{} = ctx -> Context.mark_dirty(%{ctx | this: this_val})
      map when is_map(map) -> Context.mark_dirty(%{Coercion.context_struct(map) | this: this_val})
      _ -> Coercion.ensure_context(nil) |> Map.put(:this, this_val) |> Context.mark_dirty()
    end
  end

  def instanceof({:obj, _} = obj, ctor) do
    ctor_proto = QuickBEAM.VM.ObjectModel.Get.get(ctor, "prototype")
    prototype_chain_contains?(obj, ctor_proto)
  end

  def instanceof(_obj, _ctor), do: false

  def get_length(obj), do: QuickBEAM.VM.ObjectModel.Get.length_of(obj)

  def import_module(ctx, specifier) do
    if is_binary(specifier) and Map.get(ctx, :runtime_pid) != nil do
      QuickBEAM.VM.PromiseState.resolved(QuickBEAM.VM.Runtime.new_object())
    else
      QuickBEAM.VM.PromiseState.rejected(Heap.make_error("Cannot import #{specifier}", "TypeError"))
    end
  end

  def import_module(specifier) do
    QuickBEAM.VM.PromiseState.rejected(
      Heap.make_error("Cannot import #{specifier}", "TypeError")
    )
  end

  defp prototype_chain_contains?(_, :undefined), do: false
  defp prototype_chain_contains?(_, nil), do: false

  defp prototype_chain_contains?({:obj, ref}, target) do
    import QuickBEAM.VM.Heap.Keys, only: [proto: 0]

    case Heap.get_obj(ref, %{}) do
      map when is_map(map) ->
        case Map.get(map, proto()) do
          ^target -> true
          nil -> false
          :undefined -> false
          parent -> prototype_chain_contains?(parent, target)
        end

      _ ->
        false
    end
  end

  defp prototype_chain_contains?(_, _), do: false
end
