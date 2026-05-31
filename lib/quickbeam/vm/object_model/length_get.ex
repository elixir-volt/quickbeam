defmodule QuickBEAM.VM.ObjectModel.LengthGet do
  @moduledoc "JavaScript length lookup helpers for array-like, string, and callable values."

  import Bitwise
  import QuickBEAM.VM.Heap.Keys, only: [typed_array: 0]

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.ObjectModel.{PrimitiveWrapperGet, PropertyKey, Semantics}
  alias QuickBEAM.VM.Runtime.String, as: JSString
  alias QuickBEAM.VM.Runtime.TypedArray

  def of(obj, callbacks) do
    case obj do
      {:obj, ref} ->
        object_length(ref, callbacks)

      {:qb_arr, arr} ->
        :array.size(arr)

      list when is_list(list) ->
        length(list)

      string when is_binary(string) ->
        string_length(string)

      %QuickBEAM.VM.Function{} = fun ->
        callable_length(fun, fun.defined_arg_count)

      {:closure, _, %QuickBEAM.VM.Function{} = fun} = closure ->
        callable_length(closure, callable_length(fun, fun.defined_arg_count))

      {:bound, len, _, _, _} = bound ->
        callable_length(bound, len)

      {:builtin, _, _} = builtin ->
        callable_length(builtin, QuickBEAM.VM.Builtin.declared_length(builtin))

      _ ->
        :undefined
    end
  end

  def string_length(string), do: JSString.utf16_length(string)

  def array_prototype_length(ref) do
    stored_length = Heap.get_array_prop(ref, "length")
    raw = Heap.get_obj_raw(ref)

    if array_prototype_raw?(raw) do
      if is_integer(stored_length),
        do: stored_length,
        else: array_prototype_index_length(raw_keys(raw))
    end
  end

  def virtual_array_length(ref) do
    case Heap.get_array_prop(ref, "length") do
      len when is_integer(len) -> len
      _ -> nil
    end
  end

  defp object_length(ref, callbacks) do
    case Heap.get_obj_raw(ref) do
      {:qb_arr, arr} ->
        array_prototype_length(ref) || virtual_array_length(ref) || :array.size(arr)

      list when is_list(list) ->
        array_prototype_length(ref) || virtual_array_length(ref) || length(list)

      raw when is_tuple(raw) ->
        raw_length(ref, raw, callbacks)

      %{typed_array() => true} = map ->
        if Heap.get_prop_desc(ref, "length") do
          callbacks.get_map_property.(map, "length", {:obj, ref})
        else
          typed_array_length({:obj, ref})
        end

      map when is_map(map) ->
        map_length(ref, map, callbacks)

      _ ->
        0
    end
  end

  defp raw_length(ref, raw, callbacks) do
    if array_prototype_raw?(raw) do
      array_prototype_length(ref) || 0
    else
      case Heap.raw_fetch(raw, "length") do
        {:ok, value} ->
          callbacks.shape_value.(value, {:obj, ref})

        :error ->
          inherited_or_wrapped_length({:obj, ref}, PrimitiveWrapperGet.raw_length(raw), callbacks)
      end
    end
  end

  defp map_length(ref, map, callbacks) do
    if array_prototype_raw?(map) do
      array_prototype_length(ref) || 0
    else
      case Map.fetch(map, "length") do
        {:ok, _} ->
          callbacks.get_map_property.(map, "length", {:obj, ref})

        :error ->
          inherited_or_wrapped_length({:obj, ref}, PrimitiveWrapperGet.map_length(map), callbacks)
      end
    end
  end

  defp typed_array_length(obj),
    do: if(TypedArray.out_of_bounds?(obj), do: 0, else: TypedArray.element_count(obj))

  defp callable_length(callable, default) do
    case Map.get(Heap.get_ctor_statics(callable), "length", :not_found) do
      :deleted -> 0
      :not_found -> default
      value -> value
    end
  end

  defp inherited_or_wrapped_length(obj, fallback, callbacks) do
    case callbacks.get.(obj, "length") do
      :undefined -> fallback
      value -> value
    end
  end

  def array_prototype_raw?(raw), do: Semantics.array_prototype_object?(raw)
  defp raw_keys(raw) when is_map(raw), do: Map.keys(raw)
  defp raw_keys(raw), do: raw |> Heap.shape_offsets() |> Map.keys()

  defp array_prototype_index_length(keys) do
    Enum.reduce(keys, 0, fn key, length ->
      case array_index_key(key) do
        index when is_integer(index) -> max(length, index + 1)
        nil -> length
      end
    end)
  end

  defp array_index_key(key) do
    case PropertyKey.array_index(key) do
      {:ok, index} -> index
      :error -> nil
    end
  end

  def regexp_flags(bytecode) when is_binary(bytecode) do
    case regexp_header_bytes(bytecode) do
      {flags_byte, unicode_sets_byte} ->
        base =
          [{1, "g"}, {2, "i"}, {4, "m"}, {8, "s"}, {16, "u"}, {32, "y"}, {64, "d"}]
          |> Enum.reduce("", fn {bit, ch}, acc ->
            if band(flags_byte, bit) != 0, do: acc <> ch, else: acc
          end)

        if band(unicode_sets_byte, 1) != 0, do: base <> "v", else: base

      :error ->
        ""
    end
  end

  def regexp_flags(_), do: ""

  defp regexp_header_bytes(bytecode) do
    case regexp_latin1_bytes(bytecode, 2, []) do
      [flags_byte, unicode_sets_byte] -> {flags_byte, unicode_sets_byte}
      [flags_byte] -> {flags_byte, 0}
      _ -> :error
    end
  end

  defp regexp_latin1_bytes(_bytecode, 0, acc), do: Enum.reverse(acc)
  defp regexp_latin1_bytes(<<>>, _count, acc), do: Enum.reverse(acc)

  defp regexp_latin1_bytes(<<cp::utf8, rest::binary>>, count, acc) when cp <= 0xFF,
    do: regexp_latin1_bytes(rest, count - 1, [cp | acc])

  defp regexp_latin1_bytes(<<byte, rest::binary>>, count, acc),
    do: regexp_latin1_bytes(rest, count - 1, [byte | acc])
end
