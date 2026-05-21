defmodule QuickBEAM.VM.Compiler.RuntimeHelpers do
  @moduledoc "Runtime support for BEAM-compiled JavaScript bytecode."

  import QuickBEAM.VM.Heap.Keys, only: [date_ms: 0, proto: 0]
  import QuickBEAM.VM.Value, only: [is_object: 1]

  alias QuickBEAM.VM.{
    Builtin,
    GlobalEnvironment,
    Heap,
    Invocation,
    JSThrow,
    Names,
    RuntimeState,
    Value
  }

  alias QuickBEAM.VM.Compiler.RuntimeHelpers.Bindings
  alias QuickBEAM.VM.Compiler.RuntimeHelpers.Context, as: RuntimeContext
  alias QuickBEAM.VM.Compiler.RuntimeHelpers.Errors
  alias QuickBEAM.VM.Interpreter.Context
  alias QuickBEAM.VM.Semantics.Values
  alias QuickBEAM.VM.Invocation.Context, as: InvokeContext

  alias QuickBEAM.VM.ObjectModel.{
    Class,
    Copy,
    Functions,
    Get,
    Static
  }

  alias QuickBEAM.VM.Runtime
  alias QuickBEAM.VM.Semantics.{Construction, PropertyAccess}

  # ── Coercion ──

  @tdz :__tdz__
  @generator_return_resume :__quickbeam_generator_return_resume__

  def generator_return_resume(value), do: {@generator_return_resume, value}
  def generator_resume_return?({@generator_return_resume, _value}), do: true
  def generator_resume_return?(_value), do: false
  def generator_resume_value({@generator_return_resume, value}), do: value
  def generator_resume_value(value), do: value

  @doc "Returns a dirty interpreter context suitable for entry into compiled code."
  def entry_ctx do
    case RuntimeState.current() do
      %Context{} = ctx ->
        Context.mark_dirty(ctx)

      map when is_map(map) ->
        map |> context_struct() |> Context.mark_dirty()

      _ ->
        %Context{atoms: Heap.get_atoms(), globals: GlobalEnvironment.base_globals()}
        |> Context.mark_dirty()
    end
  end

  @doc "Raises a JavaScript ReferenceError when a local is still in the temporal dead zone."
  def ensure_initialized_local!(_ctx \\ nil, val) do
    if val == @tdz do
      throw(
        {:js_throw,
         Heap.make_error("Cannot access variable before initialization", "ReferenceError")}
      )
    end

    val
  end

  def to_property_key(value), do: PropertyAccess.to_property_key(value)

  def to_property_key(ctx, value),
    do: with_runtime_ctx(ctx, fn -> PropertyAccess.to_property_key(value) end)

  def to_property_key_for_access(ctx, receiver, key),
    do: with_runtime_ctx(ctx, fn -> PropertyAccess.to_property_key_for_access(receiver, key) end)

  def to_object(:undefined), do: JSThrow.type_error!("Cannot convert undefined to object")
  def to_object(nil), do: JSThrow.type_error!("Cannot convert null to object")
  def to_object(value), do: value

  defp with_runtime_ctx(nil, fun), do: fun.()

  defp with_runtime_ctx(ctx, fun), do: RuntimeState.with_context(ctx, fun)

  @doc "Returns whether a value is JavaScript `undefined`."
  def undefined?(_ctx \\ nil, val), do: val == :undefined
  def null?(_ctx \\ nil, val), do: val == nil
  def typeof_is_undefined(_ctx \\ nil, val), do: Value.nullish?(val)
  def typeof_is_function(_ctx \\ nil, val), do: Builtin.callable?(val)

  def strict_neq(_ctx \\ nil, a, b), do: not Values.strict_eq(a, b)

  def bit_not(_ctx \\ nil, a), do: Values.bnot(a)

  def in_operator(_ctx \\ nil, key, obj) do
    unless instanceof_object?(obj) do
      JSThrow.type_error!("right-hand side of 'in' should be an object")
    end

    QuickBEAM.VM.ObjectModel.HasProperty.has_property?(obj, Names.normalize_property_key(key))
  end

  @doc "Applies JavaScript logical NOT."
  def lnot(_ctx \\ nil, a), do: not Values.truthy?(a)

  def inc(ctx \\ nil, value)
  def inc(_ctx, {:bigint, n}), do: {:bigint, n + 1}
  def inc(_ctx, a) when is_number(a), do: Values.add(a, 1)
  def inc(_ctx, a), do: Values.add(Values.to_number(a), 1)

  def dec(ctx \\ nil, value)
  def dec(_ctx, {:bigint, n}), do: {:bigint, n - 1}
  def dec(_ctx, a) when is_number(a), do: Values.sub(a, 1)
  def dec(_ctx, a), do: Values.sub(Values.to_number(a), 1)

  def post_inc(ctx \\ nil, value)
  def post_inc(_ctx, {:bigint, n} = old), do: {{:bigint, n + 1}, old}

  def post_inc(_ctx, a) do
    num = Values.to_number(a)
    {Values.add(num, 1), num}
  end

  @doc "Applies JavaScript postfix decrement and returns `{new_value, old_value}`."
  def post_dec(ctx \\ nil, value)
  def post_dec(_ctx, {:bigint, n} = old), do: {{:bigint, n - 1}, old}

  def post_dec(_ctx, a) do
    num = Values.to_number(a)
    {Values.sub(num, 1), num}
  end

  @doc "Resolves an awaited JavaScript value for compiled async code."
  def await(_ctx \\ nil, val), do: QuickBEAM.VM.Interpreter.resolve_awaited(val)

  defdelegate context_struct(ctx), to: RuntimeContext, as: :struct_context

  @doc "Returns the atom table from a context-like value."
  defdelegate context_atoms(ctx), to: RuntimeContext, as: :atoms
  defdelegate context_globals(ctx), to: RuntimeContext, as: :globals
  defdelegate context_current_func(ctx), to: RuntimeContext, as: :current_func
  defdelegate context_arg_buf(ctx), to: RuntimeContext, as: :arg_buf

  @doc "Returns the JavaScript `this` value from a context-like value."
  defdelegate context_this(ctx), to: RuntimeContext, as: :this
  defdelegate context_new_target(ctx), to: RuntimeContext, as: :new_target
  defdelegate context_gas(ctx), to: RuntimeContext, as: :gas
  defdelegate ensure_context(ctx), to: RuntimeContext, as: :ensure

  @doc "Returns the home object associated with the current function."
  def context_home_object(ctx, current_func) do
    case Map.get(ctx, :home_object, :undefined) do
      :undefined -> QuickBEAM.VM.ObjectModel.Functions.current_home_object(current_func)
      home_object -> home_object
    end
  end

  def context_super(ctx) do
    case Map.get(ctx, :super, :undefined) do
      :undefined ->
        QuickBEAM.VM.ObjectModel.Class.get_super(
          context_home_object(ctx, context_current_func(ctx))
        )

      super ->
        super
    end
  end

  @doc "Throws a JavaScript error value."
  def throw_error(ctx, atom_idx, reason),
    do: Errors.throw(ctx, atom_idx, reason, &Names.resolve_atom(context_atoms(&1), &2))

  def push_this(ctx) do
    case context_this(ctx) do
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

  @doc "Creates special object forms used by compiled object/class bytecode."
  def special_object(ctx, type) when type in [0, 1], do: Bindings.get_var(ctx, "arguments")

  def special_object(ctx, type) do
    current_func = context_current_func(ctx)

    Construction.special_object(
      type,
      current_func,
      context_arg_buf(ctx),
      context_new_target(ctx),
      context_home_object(ctx, current_func)
    )
  end

  def special_object(type) do
    case InvokeContext.fast_ctx() do
      {_atoms, _globals, current_func, arg_buf, _this, new_target, home_object, _super, _ctx} ->
        Construction.special_object(type, current_func, arg_buf, new_target, home_object)

      _ ->
        current_func = InvokeContext.current_func()
        arg_buf = InvokeContext.current_arg_buf()

        Construction.special_object(
          type,
          current_func,
          arg_buf,
          InvokeContext.current_new_target(),
          InvokeContext.current_home_object(current_func)
        )
    end
  end

  @doc "Updates the active `this` value in a context."
  def update_this(ctx, this_val), do: Context.mark_dirty(%{ctx | this: this_val})

  def update_this(this_val) do
    case RuntimeState.current() do
      %Context{} = ctx -> Context.mark_dirty(%{ctx | this: this_val})
      map when is_map(map) -> Context.mark_dirty(%{context_struct(map) | this: this_val})
      _ -> ensure_context(nil) |> Map.put(:this, this_val) |> Context.mark_dirty()
    end
  end

  @doc "Applies JavaScript `instanceof` semantics."
  def instanceof(obj, ctor) do
    has_instance = Get.get(ctor, {:symbol, "Symbol.hasInstance"})

    if has_instance != :undefined and has_instance != nil and Builtin.callable?(has_instance) do
      has_instance
      |> Invocation.invoke_with_receiver([obj], Runtime.gas_budget(), ctor)
      |> Values.truthy?()
    else
      ordinary_instanceof(obj, ctor)
    end
  end

  defp ordinary_instanceof(obj, ctor) do
    unless Builtin.callable?(ctor) or is_object(ctor) do
      JSThrow.type_error!("Right-hand side of instanceof is not callable")
    end

    unless callable_instanceof_target?(ctor) do
      JSThrow.type_error!("Right-hand side of instanceof is not callable")
    end

    cond do
      not instanceof_object?(obj) ->
        false

      special_builtin_instance?(obj, ctor) ->
        true

      true ->
        ctor_proto = Get.get(ctor, "prototype")

        case ctor_proto do
          {:obj, _} ->
            prototype_chain_contains?(obj, ctor_proto)

          _ ->
            JSThrow.type_error!(
              "Function has non-object prototype '#{Values.stringify(ctor_proto)}' in instanceof check"
            )
        end
    end
  end

  def get_length(obj), do: Get.length_of(obj)

  @doc "Loads a registered VM module by name."
  def import_module(ctx, specifier) do
    if is_binary(specifier) and Map.get(ctx, :runtime_pid) != nil do
      case QuickBEAM.Runtime.load_module(ctx.runtime_pid, specifier, "") do
        :ok ->
          QuickBEAM.VM.Promise.resolved(QuickBEAM.VM.Runtime.new_object())

        {:error, _} ->
          QuickBEAM.VM.Promise.rejected(
            Errors.make_error_with_ctx(ctx, "Cannot find module '#{specifier}'", "TypeError")
          )
      end
    else
      QuickBEAM.VM.Promise.rejected(
        Errors.make_error_with_ctx(ctx, "Invalid module specifier", "TypeError")
      )
    end
  end

  def import_module(_specifier) do
    QuickBEAM.VM.Promise.rejected(Heap.make_error("Invalid module specifier", "TypeError"))
  end

  defp instanceof_object?({:qb_arr, _}), do: true
  defp instanceof_object?(value) when is_map(value), do: true
  defp instanceof_object?(value) when is_list(value), do: true
  defp instanceof_object?(value), do: Value.object_like?(value)

  defp callable_instanceof_target?({:builtin, _, map}) when is_map(map), do: false
  defp callable_instanceof_target?({:obj, ref}), do: Get.get({:obj, ref}, "call") != :undefined
  defp callable_instanceof_target?(ctor), do: Builtin.callable?(ctor)

  defp special_builtin_instance?(obj, ctor) when not is_object(obj) do
    Builtin.callable?(obj) and Builtin.name(ctor) in ["Function", "Object"]
  end

  defp special_builtin_instance?({:obj, ref}, ctor) do
    case Builtin.name(ctor) do
      "Array" ->
        match?({:qb_arr, _}, Heap.get_obj(ref)) or is_list(Heap.get_obj(ref))

      "BigInt" ->
        match?(
          {:ok, _},
          QuickBEAM.VM.ObjectModel.WrappedPrimitive.value(Heap.get_obj(ref, %{}), :bigint)
        )

      name when is_binary(name) ->
        data = Heap.get_obj(ref, %{})

        typed_array_instance?(data, name) or
          (name == "Date" and Map.has_key?(data, date_ms()))

      "Object" ->
        true

      _ ->
        false
    end
  end

  defp special_builtin_instance?(_, _), do: false

  defp typed_array_instance?(map, constructor_name),
    do: QuickBEAM.VM.Runtime.TypedArray.instance_for_constructor?(map, constructor_name)

  def with_has_property(_ctx, obj, key), do: Static.with_has_property?(obj, key)

  @doc "Appends spread values into an array-like target."
  def append_spread(_ctx \\ nil, arr, idx, obj), do: Copy.append_spread(arr, idx, obj)

  # ── Misc ──

  @doc "Returns whether a value is either `undefined` or `null`."
  def undefined_or_null?(val), do: Value.nullish?(val)

  def set_name_computed(_ctx \\ nil, fun, name_val),
    do: Functions.set_name_computed(fun, name_val)

  # ── Private helpers ──

  defp prototype_chain_contains?({:obj, ref} = obj, target) do
    case Heap.get_obj(ref, %{}) do
      map when is_map(map) ->
        if Map.has_key?(map, proto()) do
          case Map.get(map, proto()) do
            ^target -> true
            nil -> false
            :undefined -> false
            parent -> prototype_chain_contains?(parent, target)
          end
        else
          parent = Heap.get_object_prototype()

          cond do
            obj == parent -> false
            parent == target -> true
            true -> prototype_chain_contains?(parent, target)
          end
        end

      {:qb_arr, _} ->
        parent = Heap.get_array_proto(ref)
        parent == target or prototype_chain_contains?(parent, target)

      list when is_list(list) ->
        parent = Heap.get_array_proto(ref)
        parent == target or prototype_chain_contains?(parent, target)

      _ ->
        false
    end
  end

  defp prototype_chain_contains?(fun, target) when is_tuple(fun) or is_struct(fun) do
    parent = Class.get_super(fun)

    cond do
      parent == target -> true
      Value.nullish?(parent) -> false
      true -> prototype_chain_contains?(parent, target)
    end
  end

  defp prototype_chain_contains?(_, _), do: false
end
