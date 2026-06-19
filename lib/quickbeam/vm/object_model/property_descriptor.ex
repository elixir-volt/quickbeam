defmodule QuickBEAM.VM.ObjectModel.PropertyDescriptor do
  @moduledoc "Helpers for JavaScript property descriptor records and descriptor objects."

  use QuickBEAM.VM.Builtin

  import QuickBEAM.VM.Heap.Keys, only: [key_order: 0]

  import QuickBEAM.VM.Value, only: [is_nullish: 1]

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.Semantics.Values
  alias QuickBEAM.VM.ObjectModel.{Get, HasProperty}

  @doc "Descriptor attributes for a normal ECMAScript method property."
  def method, do: attrs(writable: true, enumerable: false, configurable: true)

  @doc "Descriptor attributes for non-enumerable writable constructor links."
  def constructor, do: method()

  @doc "Descriptor attributes for constructor `.prototype` properties."
  def prototype, do: attrs(writable: false, enumerable: false, configurable: false)

  @doc "Descriptor attributes for non-enumerable readonly builtin metadata."
  def hidden_readonly, do: attrs(writable: false, enumerable: false, configurable: true)

  @doc "Descriptor attributes for ordinary enumerable data properties."
  def enumerable_data, do: attrs(writable: true, enumerable: true, configurable: true)

  @doc "Descriptor attributes for non-enumerable configurable accessor properties."
  def accessor, do: %{enumerable: false, configurable: true}

  @doc "Descriptor attributes for non-enumerable non-configurable writable data properties."
  def fixed_data, do: attrs(writable: true, enumerable: false, configurable: false)

  def attrs(opts) do
    %{
      writable: Keyword.fetch!(opts, :writable),
      enumerable: Keyword.fetch!(opts, :enumerable),
      configurable: Keyword.fetch!(opts, :configurable)
    }
  end

  def data_object(value, attrs) do
    object extends: Heap.get_object_prototype() do
      prop("value", value)
      prop("writable", attrs.writable)
      prop("enumerable", attrs.enumerable)
      prop("configurable", attrs.configurable)
      prop(key_order(), ["configurable", "enumerable", "writable", "value"])
    end
  end

  def accessor_object(getter, setter, attrs) do
    object extends: Heap.get_object_prototype() do
      prop("get", getter || :undefined)
      prop("set", setter || :undefined)
      prop("enumerable", attrs.enumerable)
      prop("configurable", attrs.configurable)
      prop(key_order(), ["configurable", "enumerable", "set", "get"])
    end
  end

  def present?(source_obj, raw_desc, key) do
    Map.has_key?(raw_desc, key) or HasProperty.has_property?(source_obj, key)
  end

  def field(source_obj, raw_desc, "value", default) do
    case Map.fetch(raw_desc, "value") do
      {:ok, {:accessor, _, _}} -> Get.get(source_obj, "value")
      {:ok, value} -> value
      :error -> get_value_or_default(source_obj, default)
    end
  end

  def field(source_obj, raw_desc, key, default) do
    case Map.fetch(raw_desc, key) do
      {:ok, {:accessor, _, _}} -> Get.get(source_obj, key)
      {:ok, value} -> value
      :error -> get_or_default(source_obj, key, default)
    end
  end

  def attribute(source_obj, raw_desc, key, existing_attrs, default) do
    atom_key = String.to_existing_atom(key)

    value =
      cond do
        Map.has_key?(raw_desc, key) and match?({:accessor, _, _}, Map.get(raw_desc, key)) ->
          Get.get(source_obj, key)

        Map.has_key?(raw_desc, key) ->
          Map.get(raw_desc, key)

        (value = Get.get(source_obj, key)) != :undefined ->
          value

        is_map(existing_attrs) and Map.has_key?(existing_attrs, atom_key) ->
          Map.get(existing_attrs, atom_key)

        true ->
          default
      end

    Values.truthy?(value)
  end

  def accessor_slot(false, _value, existing), do: existing
  def accessor_slot(true, value, _existing) when is_nullish(value), do: nil
  def accessor_slot(true, value, _existing), do: value

  defp get_value_or_default(source_obj, default) do
    case Get.get(source_obj, "value") do
      :undefined ->
        if HasProperty.has_property?(source_obj, "value"), do: :undefined, else: default

      value ->
        value
    end
  end

  defp get_or_default(source_obj, key, default) do
    case Get.get(source_obj, key) do
      :undefined ->
        if HasProperty.has_property?(source_obj, key), do: :undefined, else: default

      value ->
        value
    end
  end
end
