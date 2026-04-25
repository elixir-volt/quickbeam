defmodule QuickBEAM.VM.Compiler.RuntimeHelpers.Objects do
  @moduledoc "Object and array field access, function naming, prototype manipulation."

  import QuickBEAM.VM.Heap.Keys, only: [proto: 0]

  alias QuickBEAM.VM.Compiler.RuntimeHelpers.Coercion
  alias QuickBEAM.VM.{Heap, Names}
  alias QuickBEAM.VM.Invocation.Context, as: InvokeContext
  alias QuickBEAM.VM.ObjectModel.{Copy, Delete, Functions, Get, Methods, Private, Put}

  def get_field(obj, key) when is_binary(key), do: Get.get(obj, key)

  def get_field(obj, atom_idx),
    do: Get.get(obj, Names.resolve_atom(InvokeContext.current_atoms(), atom_idx))

  def get_array_el2(_ctx \\ nil, obj, idx), do: {Get.get(obj, idx), obj}

  def get_private_field(_ctx, obj, key) do
    case Private.get_field(obj, key) do
      :missing -> throw({:js_throw, Private.brand_error()})
      val -> val
    end
  end

  def put_field(_ctx, obj, key, val) when is_binary(key), do: put_field(obj, key, val)

  def put_field(ctx, obj, atom_idx, val),
    do: put_field(obj, Names.resolve_atom(Coercion.context_atoms(ctx), atom_idx), val)

  def put_field(obj, key, val) when is_binary(key) do
    Put.put(obj, key, val)
    :ok
  end

  def put_field(obj, atom_idx, val),
    do: put_field(obj, Names.resolve_atom(InvokeContext.current_atoms(), atom_idx), val)

  def put_array_el(_ctx \\ nil, obj, idx, val) do
    Put.put_element(obj, idx, val)
    :ok
  end

  def define_array_el(_ctx \\ nil, obj, idx, val), do: Put.define_array_el(obj, idx, val)

  def define_field(_ctx, obj, key, val) when is_binary(key), do: define_field(obj, key, val)

  def define_field(ctx, obj, atom_idx, val),
    do: define_field(obj, Names.resolve_atom(Coercion.context_atoms(ctx), atom_idx), val)

  def define_field(obj, key, val) when is_binary(key) do
    Put.put(obj, key, val)
    obj
  end

  def define_field(obj, atom_idx, val),
    do: define_field(obj, Names.resolve_atom(InvokeContext.current_atoms(), atom_idx), val)

  def put_private_field(_ctx, obj, key, val) do
    case Private.put_field!(obj, key, val) do
      :ok -> :ok
      :error -> throw({:js_throw, Private.brand_error()})
    end
  end

  def define_private_field(_ctx, obj, key, val) do
    case Private.define_field!(obj, key, val) do
      :ok -> :ok
      :error -> throw({:js_throw, Private.brand_error()})
    end
  end

  def set_function_name(_ctx \\ nil, fun, name), do: Functions.rename(fun, name)

  def set_function_name_atom(ctx, fun, atom_idx),
    do: Functions.set_name_atom(fun, atom_idx, Coercion.context_atoms(ctx))

  def set_function_name_atom(fun, atom_idx),
    do: Functions.set_name_atom(fun, atom_idx, InvokeContext.current_atoms())

  def set_function_name_computed(_ctx \\ nil, fun, name_val),
    do: Functions.set_name_computed(fun, name_val)

  def set_home_object(_ctx \\ nil, method, target), do: Methods.set_home_object(method, target)

  def set_name_computed(_ctx \\ nil, fun, name_val), do: Functions.set_name_computed(fun, name_val)

  def get_super(ctx, func) do
    if Coercion.context_home_object(ctx, Coercion.context_current_func(ctx)) == func,
      do: Coercion.context_super(ctx),
      else: QuickBEAM.VM.ObjectModel.Class.get_super(func)
  end

  def get_super(func) do
    case InvokeContext.fast_ctx() do
      {_atoms, _globals, _current_func, _arg_buf, _this, _new_target, ^func, super} ->
        super

      _ ->
        if InvokeContext.current_home_object(InvokeContext.current_func()) == func,
          do: InvokeContext.current_super(),
          else: QuickBEAM.VM.ObjectModel.Class.get_super(func)
    end
  end

  def copy_data_properties(_ctx \\ nil, target, source) do
    Copy.copy_data_properties(target, source)
    target
  end

  def new_object(_ctx \\ nil) do
    object_proto = Heap.get_object_prototype()
    init = if object_proto, do: %{proto() => object_proto}, else: %{}
    Heap.wrap(init)
  end

  def array_from(_ctx \\ nil, list), do: Heap.wrap(list)

  def delete_property(_ctx \\ nil, obj, key), do: Delete.delete_property(obj, key)

  def set_proto(_ctx \\ nil, obj, proto)

  def set_proto(_ctx, {:obj, ref} = _obj, proto) do
    map = Heap.get_obj(ref, %{})
    if is_map(map), do: Heap.put_obj(ref, Map.put(map, proto(), proto))
    :ok
  end

  def set_proto(_ctx, _obj, _proto), do: :ok
end
