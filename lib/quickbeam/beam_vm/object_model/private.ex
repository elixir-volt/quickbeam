defmodule QuickBEAM.BeamVM.ObjectModel.Private do
  @moduledoc false

  import QuickBEAM.BeamVM.Heap.Keys, only: [proto: 0]

  alias QuickBEAM.BeamVM.{Bytecode, Heap}
  alias QuickBEAM.BeamVM.ObjectModel.Functions

  def private_symbol(name) when is_binary(name), do: {:private_symbol, name, make_ref()}

  def get_field({:obj, ref}, key) do
    Map.get(Heap.get_obj(ref, %{}), {:private, key}, :missing)
  end

  def get_field({:closure, _, %Bytecode.Function{}} = ctor, key),
    do: Map.get(Heap.get_ctor_statics(ctor), {:private, key}, :missing)

  def get_field(%Bytecode.Function{} = ctor, key),
    do: Map.get(Heap.get_ctor_statics(ctor), {:private, key}, :missing)

  def get_field({:builtin, _, _} = ctor, key),
    do: Map.get(Heap.get_ctor_statics(ctor), {:private, key}, :missing)

  def get_field(_, _key), do: :missing

  def has_field?(target, key), do: get_field(target, key) != :missing

  def put_field!(target, key, val) do
    if has_field?(target, key) do
      define_field!(target, key, val)
    else
      :error
    end
  end

  def define_field!({:obj, ref}, key, val) do
    Heap.update_obj(ref, %{}, &Map.put(&1, {:private, key}, val))
    :ok
  end

  def define_field!({:closure, _, %Bytecode.Function{}} = ctor, key, val) do
    Heap.put_ctor_static(ctor, {:private, key}, val)
    :ok
  end

  def define_field!(%Bytecode.Function{} = ctor, key, val) do
    Heap.put_ctor_static(ctor, {:private, key}, val)
    :ok
  end

  def define_field!({:builtin, _, _} = ctor, key, val) do
    Heap.put_ctor_static(ctor, {:private, key}, val)
    :ok
  end

  def define_field!(_, _key, _val), do: :error

  def brands({:obj, ref}), do: Map.get(Heap.get_obj(ref, %{}), :__brands__, [])

  def brands({:closure, _, %Bytecode.Function{}} = ctor),
    do: Map.get(Heap.get_ctor_statics(ctor), :__brands__, [])

  def brands(%Bytecode.Function{} = ctor),
    do: Map.get(Heap.get_ctor_statics(ctor), :__brands__, [])

  def brands({:builtin, _, _} = ctor), do: Map.get(Heap.get_ctor_statics(ctor), :__brands__, [])
  def brands(_), do: []

  def add_brand({:obj, ref}, brand) do
    Heap.update_obj(ref, %{}, fn map ->
      existing = Map.get(map, :__brands__, [])
      Map.put(map, :__brands__, [brand | existing])
    end)

    :ok
  end

  def add_brand({:closure, _, %Bytecode.Function{}} = ctor, brand) do
    add_ctor_brand(ctor, brand)
    :ok
  end

  def add_brand(%Bytecode.Function{} = ctor, brand) do
    add_ctor_brand(ctor, brand)
    :ok
  end

  def add_brand({:builtin, _, _} = ctor, brand) do
    add_ctor_brand(ctor, brand)
    :ok
  end

  def add_brand(_obj, _brand), do: :ok

  def ensure_brand(target, brand) do
    if brand_match?(target, brand), do: :ok, else: :error
  end

  def brand_error, do: Heap.make_error("invalid brand on object", "TypeError")

  defp brand_match?(target, brand) do
    target_brands = brands(target)
    home_object = Process.get({:qb_home_object, Functions.home_object_key(brand)})

    brand in target_brands or
      (home_object not in [nil, :undefined] and
         (home_object in target_brands or brand_home_match?(target, home_object)))
  end

  defp brand_home_match?({:obj, ref}, home_object) do
    parent = Map.get(Heap.get_obj(ref, %{}), proto(), :undefined)
    parent == home_object or brand_home_match?(parent, home_object)
  end

  defp brand_home_match?(:undefined, _home_object), do: false
  defp brand_home_match?(nil, _home_object), do: false
  defp brand_home_match?(_, _home_object), do: false

  defp add_ctor_brand(ctor, brand) do
    existing = Map.get(Heap.get_ctor_statics(ctor), :__brands__, [])
    Heap.put_ctor_static(ctor, :__brands__, [brand | existing])
  end
end
