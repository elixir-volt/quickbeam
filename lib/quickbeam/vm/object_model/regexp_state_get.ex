defmodule QuickBEAM.VM.ObjectModel.RegExpStateGet do
  @moduledoc "RegExp own-property lookup backed by regexp instance state."

  alias QuickBEAM.VM.Execution.RegexpState
  alias QuickBEAM.VM.ObjectModel.RegExpExoticGet
  alias QuickBEAM.VM.Runtime.RegExp

  @accessor_keys [
    "source",
    "flags",
    "hasIndices",
    "global",
    "ignoreCase",
    "multiline",
    "dotAll",
    "unicode",
    "unicodeSets",
    "sticky"
  ]

  def own_property({:regexp, _, _, ref} = regexp, "flags", call_getter),
    do: state_or_instance(ref, "flags", regexp, call_getter)

  def own_property({:regexp, _bytecode, source, ref} = regexp, "source", call_getter)
      when is_binary(source),
      do: state_or_instance(ref, "source", regexp, call_getter)

  def own_property({:regexp, _, _, ref} = regexp, "lastIndex", call_getter),
    do: state_or_default(ref, "lastIndex", regexp, 0, call_getter)

  def own_property({:regexp, _, _} = regexp, "flags", _call_getter),
    do: instance_property(regexp, "flags")

  def own_property({:regexp, _bytecode, source} = regexp, "source", _call_getter)
      when is_binary(source),
      do: instance_property(regexp, "source")

  def own_property({:regexp, _, _}, "lastIndex", _call_getter), do: 0

  def own_property({:regexp, _, _, ref} = regexp, key, call_getter),
    do: state_or_instance(ref, key, regexp, call_getter)

  def own_property({:regexp, _, _}, key, _call_getter),
    do: RegExpExoticGet.prototype_property(key)

  defp state_or_instance(ref, key, regexp, call_getter) do
    case RegexpState.fetch(ref, key) do
      {:ok, value} -> state_value(value, regexp, call_getter)
      :error -> instance_property(regexp, key)
    end
  end

  defp state_or_default(ref, key, regexp, default, call_getter) do
    case RegexpState.fetch(ref, key) do
      {:ok, value} -> state_value(value, regexp, call_getter)
      :error -> default
    end
  end

  defp state_value({:accessor, getter, _}, receiver, call_getter) when getter != nil,
    do: call_getter.(getter, receiver)

  defp state_value({:accessor, nil, _}, _receiver, _call_getter), do: :undefined
  defp state_value(value, _receiver, _call_getter), do: value

  defp instance_property(_regexp, key) when key in @accessor_keys, do: RegExp.proto_accessor(key)
  defp instance_property(regexp, key), do: RegExpExoticGet.instance_property(regexp, key)
end
