defmodule QuickBEAM.BeamVM.Runtime.TypedArray do
  alias QuickBEAM.BeamVM.Heap

  def array_buffer_constructor(args) do
    byte_length = case args do
      [n | _] when is_integer(n) -> n
      _ -> 0
    end
    ref = make_ref()
    Heap.put_obj(ref, %{
      "__buffer__" => :binary.copy(<<0>>, byte_length),
      "byteLength" => byte_length
    })
    {:obj, ref}
  end

  def typed_array_constructor(type) do
    fn args ->
      {buffer, offset, length_val} = case args do
        [{:obj, buf_ref} | rest] ->
          buf = Heap.get_obj(buf_ref, %{})
          cond do
            is_list(buf) ->
              len = length(buf)
              {list_to_buffer(buf, type), 0, len}
            is_map(buf) and Map.has_key?(buf, "__buffer__") ->
              bin = Map.get(buf, "__buffer__")
              offset = Enum.at(rest, 0) || 0
              len = Enum.at(rest, 1) || div(byte_size(bin) - offset, elem_size(type))
              {bin, offset, len}
            true -> {:binary.copy(<<0>>, 0), 0, 0}
          end
        [n | _] when is_integer(n) ->
          {:binary.copy(<<0>>, n * elem_size(type)), 0, n}
        [list | _] when is_list(list) ->
          len = length(list)
          buf = list_to_buffer(list, type)
          {buf, 0, len}
        [] ->
          {:binary.copy(<<0>>, 0), 0, 0}
        _ -> {:binary.copy(<<0>>, 0), 0, 0}
      end
      ref = make_ref()
      Heap.put_obj(ref, %{
        "__typed_array__" => true,
        "__type__" => type,
        "__buffer__" => buffer,
        "__offset__" => offset,
        "length" => length_val,
        "byteLength" => length_val * elem_size(type),
        "byteOffset" => offset,
        "buffer" => make_buffer_ref(buffer)
      })
      {:obj, ref}
    end
  end

  def get_element({:obj, ref}, idx) when is_integer(idx) do
    map = Heap.get_obj(ref, %{})
    case map do
      %{"__typed_array__" => true, "__type__" => type, "__buffer__" => buf, "__offset__" => offset} ->
        read_element(buf, offset + idx * elem_size(type), type)
      _ -> :undefined
    end
  end
  def get_element(_, _), do: :undefined

  def set_element({:obj, ref}, idx, val) when is_integer(idx) do
    map = Heap.get_obj(ref, %{})
    case map do
      %{"__typed_array__" => true, "__type__" => type, "__buffer__" => buf, "__offset__" => offset} ->
        new_buf = write_element(buf, offset + idx * elem_size(type), type, val)
        Heap.put_obj(ref, %{map | "__buffer__" => new_buf})
      _ -> :ok
    end
  end
  def set_element(_, _, _), do: :ok

  def typed_array?({:obj, ref}) do
    case Heap.get_obj(ref, %{}) do
      %{"__typed_array__" => true} -> true
      _ -> false
    end
  end
  def typed_array?(_), do: false

  defp elem_size(:uint8), do: 1
  defp elem_size(:int8), do: 1
  defp elem_size(:uint8_clamped), do: 1
  defp elem_size(:uint16), do: 2
  defp elem_size(:int16), do: 2
  defp elem_size(:uint32), do: 4
  defp elem_size(:int32), do: 4
  defp elem_size(:float32), do: 4
  defp elem_size(:float64), do: 8
  defp elem_size(:bigint64), do: 8
  defp elem_size(:biguint64), do: 8

  defp read_element(buf, pos, :uint8) when pos < byte_size(buf), do: :binary.at(buf, pos)
  defp read_element(buf, pos, :int8) when pos < byte_size(buf) do
    <<_::binary-size(pos), v::signed-8, _::binary>> = buf; v
  end
  defp read_element(buf, pos, :uint16) when pos + 1 < byte_size(buf) do
    <<_::binary-size(pos), v::little-unsigned-16, _::binary>> = buf; v
  end
  defp read_element(buf, pos, :int16) when pos + 1 < byte_size(buf) do
    <<_::binary-size(pos), v::little-signed-16, _::binary>> = buf; v
  end
  defp read_element(buf, pos, :uint32) when pos + 3 < byte_size(buf) do
    <<_::binary-size(pos), v::little-unsigned-32, _::binary>> = buf; v
  end
  defp read_element(buf, pos, :int32) when pos + 3 < byte_size(buf) do
    <<_::binary-size(pos), v::little-signed-32, _::binary>> = buf; v
  end
  defp read_element(buf, pos, :float32) when pos + 3 < byte_size(buf) do
    <<_::binary-size(pos), v::little-float-32, _::binary>> = buf; v
  end
  defp read_element(buf, pos, :float64) when pos + 7 < byte_size(buf) do
    <<_::binary-size(pos), v::little-float-64, _::binary>> = buf; v
  end
  defp read_element(_, _, _), do: :undefined

  defp write_element(buf, pos, :uint8, val) when pos < byte_size(buf) do
    v = trunc(val) |> Bitwise.band(0xFF)
    <<pre::binary-size(pos), _::8, post::binary>> = buf
    <<pre::binary, v::8, post::binary>>
  end
  defp write_element(buf, pos, :int8, val) when pos < byte_size(buf) do
    <<pre::binary-size(pos), _::8, post::binary>> = buf
    <<pre::binary, trunc(val)::signed-8, post::binary>>
  end
  defp write_element(buf, pos, :int32, val) when pos + 3 < byte_size(buf) do
    <<pre::binary-size(pos), _::32, post::binary>> = buf
    <<pre::binary, trunc(val)::little-signed-32, post::binary>>
  end
  defp write_element(buf, pos, :float64, val) when pos + 7 < byte_size(buf) do
    v = val * 1.0
    <<pre::binary-size(pos), _::64, post::binary>> = buf
    <<pre::binary, v::little-float-64, post::binary>>
  end
  defp write_element(buf, pos, type, val) do
    size = elem_size(type) * 8
    if pos + div(size, 8) - 1 < byte_size(buf) do
      <<pre::binary-size(pos), _::size(size), post::binary>> = buf
      <<pre::binary, trunc(val)::little-size(size), post::binary>>
    else
      buf
    end
  end

  defp list_to_buffer(list, type) do
    list
    |> Enum.map(fn
      n when is_number(n) -> n
      _ -> 0
    end)
    |> Enum.reduce(<<>>, fn val, acc ->
      acc <> encode_element(val, type)
    end)
  end

  defp encode_element(val, :uint8), do: <<trunc(val) |> Bitwise.band(0xFF)::8>>
  defp encode_element(val, :int8), do: <<trunc(val)::signed-8>>
  defp encode_element(val, :int32), do: <<trunc(val)::little-signed-32>>
  defp encode_element(val, :float64), do: <<(val * 1.0)::little-float-64>>
  defp encode_element(val, type) do
    size = elem_size(type) * 8
    <<trunc(val)::little-size(size)>>
  end

  defp make_buffer_ref(buffer) do
    ref = make_ref()
    Heap.put_obj(ref, %{"__buffer__" => buffer, "byteLength" => byte_size(buffer)})
    {:obj, ref}
  end
end
