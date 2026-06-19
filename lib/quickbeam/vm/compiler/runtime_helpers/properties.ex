defmodule QuickBEAM.VM.Compiler.RuntimeHelpers.Properties do
  @moduledoc "Object property, private-field, and object-literal helpers used by BEAM-compiled JavaScript."

  import QuickBEAM.VM.Heap.Keys, only: [proto: 0]
  import QuickBEAM.VM.Value, only: [is_object: 1]

  alias QuickBEAM.VM.{Heap, JSThrow, Names, RuntimeState}
  alias QuickBEAM.VM.Compiler.RuntimeHelpers.Bindings
  alias QuickBEAM.VM.Compiler.RuntimeHelpers.Context, as: RuntimeContext
  alias QuickBEAM.VM.Interpreter.Context
  alias QuickBEAM.VM.Invocation.Context, as: InvokeContext

  alias QuickBEAM.VM.ObjectModel.{
    Class,
    Copy,
    Define,
    Functions,
    InternalMethods,
    Methods,
    Private,
    Put,
    Static
  }

  alias QuickBEAM.VM.Semantics.{Construction, PropertyAccess}
  alias QuickBEAM.VM.Semantics.Values

  @doc "Reads a JavaScript property value."
  def get_field(object, key) when is_binary(key), do: PropertyAccess.get_property(object, key)

  def get_field(object, atom_idx),
    do:
      PropertyAccess.get_property(
        object,
        Names.resolve_atom(InvokeContext.current_atoms(), atom_idx)
      )

  def get_field(ctx, object, key) when is_binary(key),
    do: PropertyAccess.get_property(ctx, object, key)

  def get_field(ctx, object, atom_idx),
    do:
      PropertyAccess.get_property(
        ctx,
        object,
        Names.resolve_atom(RuntimeContext.atoms(ctx), atom_idx)
      )

  def get_array_el2(ctx \\ nil, object, idx),
    do: {PropertyAccess.get_property(ctx, object, idx), object}

  def get_private_field(_ctx, object, key) do
    case Private.get_field(object, key) do
      :missing -> throw({:js_throw, Private.brand_error()})
      value -> value
    end
  end

  @doc "Writes a JavaScript property value."
  def put_field(ctx, object, key, value) when is_binary(key) do
    with_runtime_ctx(ctx, fn -> PropertyAccess.set_property(ctx, object, key, value) end)
    sync_global_field_write(ctx, object, key, value)
    :ok
  end

  def put_field(ctx, object, atom_idx, value),
    do: put_field(ctx, object, Names.resolve_atom(RuntimeContext.atoms(ctx), atom_idx), value)

  def put_field(object, key, value) when is_binary(key) do
    PropertyAccess.set_property(object, key, value)
    :ok
  end

  def put_field(object, atom_idx, value),
    do: put_field(object, Names.resolve_atom(InvokeContext.current_atoms(), atom_idx), value)

  def get_array_el(ctx \\ nil, object, idx),
    do: with_runtime_ctx(ctx, fn -> PropertyAccess.get_property(ctx, object, idx) end)

  @doc "Writes a JavaScript array element."
  def put_array_el(ctx \\ nil, object, idx, value) do
    with_runtime_ctx(ctx, fn -> PropertyAccess.set_property(ctx, object, idx, value) end)
    :ok
  end

  def define_array_el(_ctx \\ nil, object, idx, value),
    do: Put.define_array_el(object, idx, value)

  def define_field(_ctx, object, key, value) when is_binary(key) or is_number(key),
    do: define_field(object, key, value)

  def define_field(ctx, object, atom_idx, value),
    do: define_field(object, Names.resolve_atom(RuntimeContext.atoms(ctx), atom_idx), value)

  def define_field(object, "__proto__", value) do
    Put.define_array_el(object, "__proto__", value)
    object
  end

  def define_field(object, atom_idx, value) when is_tuple(atom_idx),
    do: define_field(object, Names.resolve_atom(InvokeContext.current_atoms(), atom_idx), value)

  def define_field(object, key, value),
    do: Define.create_data_property_or_throw(object, key, value)

  def define_static_method(ctx, ctor, atom_idx, method)
      when is_integer(atom_idx) or is_tuple(atom_idx),
      do:
        define_static_method(
          ctx,
          ctor,
          Names.resolve_atom(RuntimeContext.atoms(ctx), atom_idx),
          method
        )

  def define_static_method(_ctx, ctor, key, method) do
    Put.put_field(ctor, key, method)
    Heap.put_ctor_prop_desc(ctor, key, %{writable: true, enumerable: false, configurable: true})
    :ok
  end

  @doc "Writes an existing private class field or throws when absent."
  def put_private_field(_ctx, object, key, value) do
    case Private.put_field!(object, key, value) do
      :ok -> :ok
      :error -> throw({:js_throw, Private.brand_error()})
    end
  end

  def define_private_field(_ctx, object, key, value) do
    case Private.define_field!(object, key, value) do
      :ok -> :ok
      :error -> throw({:js_throw, Private.brand_error()})
    end
  end

  @doc "Assigns a JavaScript function display name."
  def set_function_name(_ctx \\ nil, fun, name), do: Functions.rename(fun, name)

  def set_function_name_atom(ctx, fun, atom_idx),
    do: Functions.set_name_atom(fun, atom_idx, RuntimeContext.atoms(ctx))

  def set_function_name_atom(fun, atom_idx),
    do: Functions.set_name_atom(fun, atom_idx, InvokeContext.current_atoms())

  @doc "Assigns a function display name from a computed property value."
  def set_function_name_computed(_ctx \\ nil, fun, name_value),
    do: Functions.set_name_computed(fun, name_value)

  def set_home_object(_ctx \\ nil, method, target), do: Methods.set_home_object(method, target)

  def get_super(ctx, func) do
    if context_home_object(ctx, RuntimeContext.current_func(ctx)) == func,
      do: context_super(ctx),
      else: Class.get_super(func)
  end

  def get_super(func) do
    case InvokeContext.fast_ctx() do
      {_atoms, _globals, _current_func, _arg_buf, _this, _new_target, ^func, super, _ctx} ->
        super

      _ ->
        if InvokeContext.current_home_object(InvokeContext.current_func()) == func,
          do: InvokeContext.current_super(),
          else: Class.get_super(func)
    end
  end

  @doc "Copies enumerable object-spread properties."
  def copy_data_properties(ctx \\ nil, target, source, exclude \\ nil) do
    with_runtime_ctx(ctx, fn -> Copy.copy_data_properties(target, source, exclude) end)
    target
  end

  def new_object(_ctx \\ nil), do: Construction.new_object()

  @doc "Converts an iterable or array-like value to a JavaScript array object."
  def array_from(_ctx \\ nil, list) do
    {:obj, ref} = object = Heap.wrap(list)

    list
    |> Enum.with_index()
    |> Enum.each(fn {_value, index} ->
      Heap.put_prop_desc(ref, Integer.to_string(index), %{
        writable: true,
        enumerable: true,
        configurable: true
      })
    end)

    object
  end

  def delete_property(ctx \\ nil, object, key)

  def delete_property(ctx, object, key) when is_map(ctx) or is_struct(ctx) do
    key_str = if is_binary(key), do: key, else: Values.stringify(key)

    if object == RuntimeContext.this(ctx) and Map.has_key?(RuntimeContext.globals(ctx), key_str) do
      case Map.fetch!(RuntimeContext.globals(ctx), key_str) do
        {:builtin, _, _} -> true
        _ -> false
      end
    else
      result = delete_property(nil, object, key)

      if result == false and Bindings.current_strict_mode?(ctx),
        do: JSThrow.type_error!("Cannot delete property")

      result
    end
  end

  def delete_property(_ctx, {:builtin, _name, map} = fun, key) when is_map(map),
    do: Static.delete_static(fun, key)

  def delete_property(_ctx, {:builtin, _name, _} = fun, key), do: Static.delete_static(fun, key)
  def delete_property(_ctx, {:closure, _, _} = fun, key), do: Static.delete_static(fun, key)

  def delete_property(_ctx, %QuickBEAM.VM.Function{} = fun, key),
    do: Static.delete_static(fun, key)

  def delete_property(_ctx, object, key), do: InternalMethods.delete(object, key)

  def set_proto(ctx \\ nil, object, proto)

  def set_proto(_ctx, {:obj, ref}, proto) do
    map = Heap.get_obj(ref, %{})

    if is_map(map) and (is_object(proto) or proto == nil) do
      Heap.put_obj(ref, Map.put(map, proto(), proto))
    end

    :ok
  end

  def set_proto(_ctx, _object, _proto), do: :ok

  defp context_home_object(ctx, current_func) do
    case Map.get(ctx, :home_object, :undefined) do
      :undefined -> Functions.current_home_object(current_func)
      home_object -> home_object
    end
  end

  defp context_super(ctx) do
    case Map.get(ctx, :super, :undefined) do
      :undefined -> Class.get_super(context_home_object(ctx, RuntimeContext.current_func(ctx)))
      super -> super
    end
  end

  defp sync_global_field_write(%{globals: globals} = ctx, object, key, value) do
    if Map.get(globals, "globalThis") == object do
      new_globals = Map.put(globals, key, value)
      Heap.put_persistent_globals(new_globals)
      Heap.put_base_globals(new_globals)
      RuntimeState.install(%{ctx | globals: new_globals} |> Context.mark_dirty())
    end
  end

  defp sync_global_field_write(_ctx, _object, _key, _value), do: :ok

  defp with_runtime_ctx(nil, fun), do: fun.()

  defp with_runtime_ctx(ctx, fun), do: RuntimeState.with_context(ctx, fun)
end
