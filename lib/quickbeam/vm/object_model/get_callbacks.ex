defmodule QuickBEAM.VM.ObjectModel.GetCallbacks do
  @moduledoc "Callback-map factories for ObjectModel.Get helper modules."

  def ordinary(call_getter, explicit_own?, get_own, get_prototype_raw) do
    %{
      call_getter: call_getter,
      explicit_own?: explicit_own?,
      get_own: get_own,
      get_prototype_raw: get_prototype_raw
    }
  end

  def symbol(call_getter, explicit_own?, get_from_prototype, get_own) do
    %{
      call_getter: call_getter,
      explicit_own?: explicit_own?,
      get_from_prototype: get_from_prototype,
      get_own: get_own
    }
  end

  def length(get, get_map_property, shape_value) do
    %{
      get: get,
      get_map_property: get_map_property,
      shape_value: shape_value
    }
  end

  def own(
        array_object,
        builtin_object,
        call_getter,
        object_map,
        proxy_get,
        raw_object,
        typed_array
      ) do
    %{
      array_object: array_object,
      builtin_object: builtin_object,
      call_getter: call_getter,
      object_map: object_map,
      proxy_get: proxy_get,
      raw_object: raw_object,
      typed_array: typed_array
    }
  end

  def typed_array(get_map_property), do: %{get_map_property: get_map_property}

  def builtin_object(get_map_property, receiver) do
    %{get_map_property: fn map, key -> get_map_property.(map, key, receiver) end}
  end

  def object_map(array_prototype_length, get_map_property) do
    %{
      array_prototype_length: array_prototype_length,
      get_map_property: get_map_property
    }
  end

  def raw_object(array_prototype_raw?, array_prototype_length, wrapped_raw_proto_property) do
    %{
      array_prototype_raw?: array_prototype_raw?,
      array_prototype_length: array_prototype_length,
      wrapped_raw_proto_property: wrapped_raw_proto_property
    }
  end

  def array_object(get_own, get_from_prototype) do
    %{
      get_own: get_own,
      get_from_prototype: get_from_prototype
    }
  end

  def prototype(call_getter, get_own, prototype_property_with_receiver, string_proto_property) do
    %{
      call_getter: call_getter,
      get_own: get_own,
      prototype_property_with_receiver: prototype_property_with_receiver,
      string_proto_property: string_proto_property
    }
  end

  def traversal(call_getter, get, get_from_prototype, get_own_value) do
    %{
      call_getter: call_getter,
      get: get,
      get_from_prototype: get_from_prototype,
      get_own_value: get_own_value
    }
  end
end
