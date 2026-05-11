defmodule QuickBEAM.VM.ObjectModel.PropertyDescriptor do
  @moduledoc "Helpers for JavaScript property descriptor records and descriptor objects."

  use QuickBEAM.VM.Builtin

  alias QuickBEAM.VM.Interpreter.Values
  alias QuickBEAM.VM.ObjectModel.{Get, Put}

  def attrs(opts) do
    %{
      writable: Keyword.fetch!(opts, :writable),
      enumerable: Keyword.fetch!(opts, :enumerable),
      configurable: Keyword.fetch!(opts, :configurable)
    }
  end

  def data_object(value, attrs) do
    object do
      val("value", value)
      val("writable", attrs.writable)
      val("enumerable", attrs.enumerable)
      val("configurable", attrs.configurable)
    end
  end

  def accessor_object(getter, setter, attrs) do
    object do
      val("get", getter || :undefined)
      val("set", setter || :undefined)
      val("enumerable", attrs.enumerable)
      val("configurable", attrs.configurable)
    end
  end

  def present?(source_obj, raw_desc, "value") do
    Map.has_key?(raw_desc, "value") or Get.get(source_obj, "value") != :undefined or
      Put.has_property(source_obj, "value")
  end

  def present?(source_obj, raw_desc, key) do
    Map.has_key?(raw_desc, key) or Get.get(source_obj, key) != :undefined
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
  def accessor_slot(true, value, _existing) when value in [nil, :undefined], do: nil
  def accessor_slot(true, value, _existing), do: value

  defp get_value_or_default(source_obj, default) do
    case Get.get(source_obj, "value") do
      :undefined ->
        if Put.has_property(source_obj, "value"), do: :undefined, else: default

      value ->
        value
    end
  end

  defp get_or_default(source_obj, key, default) do
    case Get.get(source_obj, key) do
      :undefined -> default
      value -> value
    end
  end
end
