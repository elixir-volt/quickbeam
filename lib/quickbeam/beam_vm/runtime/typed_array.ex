defmodule QuickBEAM.BeamVM.Runtime.TypedArray do
  import QuickBEAM.BeamVM.Heap.Keys
  @moduledoc false

  use QuickBEAM.BeamVM.Builtin
  alias QuickBEAM.BeamVM.Runtime
  alias QuickBEAM.BeamVM.Heap

  def array_buffer_constructor(args, _this \\ nil) do
    byte_length =
      case args do
        [n | _] when is_integer(n) -> n
        _ -> 0
      end

    Heap.wrap(%{buffer() => :binary.copy(<<0>>, byte_length), "byteLength" => byte_length})
  end

  def typed_array_constructor(type) do
    fn args, _this ->
      {buf, offset, len, orig_buf} = parse_ta_args(args, type)
      ref = make_ref()

      methods =
        build_methods do
          method "set" do
            ta_set(ref, args)
          end

          method "subarray" do
            ta_subarray(ref, args)
          end

          method "join" do
            ta_join(ref, args)
          end

          method "forEach" do
            ta_for_each(ref, args, this)
          end

          method "map" do
            ta_map(ref, args, this)
          end

          method "filter" do
            ta_filter(ref, args, this)
          end

          method "every" do
            ta_every(ref, args, this)
          end

          method "some" do
            ta_some(ref, args, this)
          end

          method "reduce" do
            ta_reduce(ref, args, this)
          end

          method "indexOf" do
            ta_index_of(ref, args)
          end

          method "find" do
            ta_find(ref, args, this)
          end

          method "sort" do
            ta_sort(ref)
          end

          method "reverse" do
            ta_reverse(ref)
          end

          method "slice" do
            ta_slice(ref, args)
          end

          method "fill" do
            ta_fill(ref, args)
          end
        end

      obj =
        Map.merge(methods, %{
          typed_array() => true,
          type_key() => type,
          buffer() => buf,
          offset() => offset,
          "length" => len,
          "byteLength" => len * elem_size(type),
          "byteOffset" => offset,
          "buffer" => orig_buf || make_buffer_ref(buf)
        })

      Heap.put_obj(ref, obj)
      {:obj, ref}
    end
  end

  # ── Read helpers ──

  defp ta(ref), do: Heap.get_obj(ref, %{})
  defp ta_buf(ref), do: Map.get(ta(ref), buffer(), <<>>)
  defp ta_len(ref), do: Map.get(ta(ref), "length", 0)
  defp ta_type(ref), do: Map.get(ta(ref), type_key(), :uint8)

  # ── Method implementations ──

  defp ta_set(ref, [source | _]) do
    src_list = Heap.to_list(source)
    t = ta_type(ref)

    new_buf =
      Enum.with_index(src_list)
      |> Enum.reduce(ta_buf(ref), fn {v, i}, acc -> write_element(acc, i, v, t) end)

    Heap.put_obj(ref, Map.put(ta(ref), buffer(), new_buf))
    :undefined
  end

  defp ta_subarray(ref, args) do
    len = ta_len(ref)
    t = ta_type(ref)
    s = max(0, min(to_idx(Enum.at(args, 0, 0)), len))
    e = min(to_idx(Enum.at(args, 1, len)), len)
    new_len = max(0, e - s)
    es = elem_size(t)

    Heap.wrap(%{
      typed_array() => true,
      type_key() => t,
      buffer() => binary_part(ta_buf(ref), s * es, new_len * es),
      offset() => 0,
      "length" => new_len,
      "byteLength" => new_len * es,
      "byteOffset" => 0,
      "buffer" => Map.get(ta(ref), "buffer")
    })
  end

  defp ta_join(ref, args) do
    sep =
      case args do
        [s | _] when is_binary(s) -> s
        _ -> ","
      end

    {buf, len, t} = {ta_buf(ref), ta_len(ref), ta_type(ref)}
    Enum.map_join(0..max(0, len - 1), sep, &Integer.to_string(trunc(read_element(buf, &1, t))))
  end

  defp ta_for_each(ref, [cb | _], this) do
    {buf, len, t} = {ta_buf(ref), ta_len(ref), ta_type(ref)}
    for i <- 0..(len - 1), do: cb_call(cb, [read_element(buf, i, t), i, this])
    :undefined
  end

  defp ta_map(ref, [cb | _], this) do
    {buf, len, t} = {ta_buf(ref), ta_len(ref), ta_type(ref)}

    new_buf =
      Enum.reduce(0..(len - 1), buf, fn i, acc ->
        write_element(acc, i, cb_call(cb, [read_element(acc, i, t), i, this]), t)
      end)

    Heap.wrap(%{
      typed_array() => true,
      type_key() => t,
      buffer() => new_buf,
      offset() => 0,
      "length" => len,
      "byteLength" => byte_size(new_buf),
      "byteOffset" => 0
    })
  end

  defp ta_filter(ref, [cb | _], this) do
    {buf, len, t} = {ta_buf(ref), ta_len(ref), ta_type(ref)}

    vals =
      for i <- 0..(len - 1),
          (
            v = read_element(buf, i, t)
            truthy?(cb_call(cb, [v, i, this]))
          ),
          do: v

    new_buf =
      vals
      |> Enum.with_index()
      |> Enum.reduce(:binary.copy(<<0>>, length(vals) * elem_size(t)), fn {v, i}, acc ->
        write_element(acc, i, v, t)
      end)

    Heap.wrap(%{
      typed_array() => true,
      type_key() => t,
      buffer() => new_buf,
      offset() => 0,
      "length" => length(vals),
      "byteLength" => byte_size(new_buf),
      "byteOffset" => 0
    })
  end

  defp ta_every(ref, [cb | _], this) do
    {buf, len, t} = {ta_buf(ref), ta_len(ref), ta_type(ref)}
    Enum.all?(0..max(0, len - 1), &truthy?(cb_call(cb, [read_element(buf, &1, t), &1, this])))
  end

  defp ta_some(ref, [cb | _], this) do
    {buf, len, t} = {ta_buf(ref), ta_len(ref), ta_type(ref)}
    Enum.any?(0..max(0, len - 1), &truthy?(cb_call(cb, [read_element(buf, &1, t), &1, this])))
  end

  defp ta_reduce(ref, args, this) do
    {buf, len, t} = {ta_buf(ref), ta_len(ref), ta_type(ref)}
    cb = List.first(args)
    init = Enum.at(args, 1)
    {start, acc} = if init != nil, do: {0, init}, else: {1, read_element(buf, 0, t)}

    Enum.reduce(start..max(start, len - 1), acc, fn i, a ->
      cb_call(cb, [a, read_element(buf, i, t), i, this])
    end)
  end

  defp ta_index_of(ref, [target | _]) do
    {buf, len, t} = {ta_buf(ref), ta_len(ref), ta_type(ref)}

    Enum.find_value(0..max(0, len - 1), -1, fn i ->
      if read_element(buf, i, t) == target, do: i
    end)
  end

  defp ta_find(ref, [cb | _], this) do
    {buf, len, t} = {ta_buf(ref), ta_len(ref), ta_type(ref)}

    Enum.find_value(0..max(0, len - 1), :undefined, fn i ->
      v = read_element(buf, i, t)
      if truthy?(cb_call(cb, [v, i, this])), do: v
    end)
  end

  defp ta_sort(ref) do
    {buf, len, t} = {ta_buf(ref), ta_len(ref), ta_type(ref)}
    vals = Enum.map(0..max(0, len - 1), &read_element(buf, &1, t)) |> Enum.sort()

    new_buf =
      vals
      |> Enum.with_index()
      |> Enum.reduce(buf, fn {v, i}, acc -> write_element(acc, i, v, t) end)

    Heap.put_obj(ref, Map.put(ta(ref), buffer(), new_buf))
    {:obj, ref}
  end

  defp ta_reverse(ref) do
    {buf, len, t} = {ta_buf(ref), ta_len(ref), ta_type(ref)}
    vals = Enum.map(0..max(0, len - 1), &read_element(buf, &1, t)) |> Enum.reverse()

    new_buf =
      vals
      |> Enum.with_index()
      |> Enum.reduce(buf, fn {v, i}, acc -> write_element(acc, i, v, t) end)

    Heap.put_obj(ref, Map.put(ta(ref), buffer(), new_buf))
    {:obj, ref}
  end

  defp ta_slice(ref, args) do
    len = ta_len(ref)
    t = ta_type(ref)
    s = max(0, to_idx(Enum.at(args, 0, 0)))
    e = min(len, to_idx(Enum.at(args, 1, len)))
    new_len = max(0, e - s)
    es = elem_size(t)
    new_buf = if new_len > 0, do: binary_part(ta_buf(ref), s * es, new_len * es), else: <<>>

    Heap.wrap(%{
      typed_array() => true,
      type_key() => t,
      buffer() => new_buf,
      offset() => 0,
      "length" => new_len,
      "byteLength" => byte_size(new_buf),
      "byteOffset" => 0
    })
  end

  defp ta_fill(ref, [val | _]) do
    {len, t} = {ta_len(ref), ta_type(ref)}
    new_buf = Enum.reduce(0..(len - 1), ta_buf(ref), &write_element(&2, &1, val, t))
    Heap.put_obj(ref, Map.put(ta(ref), buffer(), new_buf))
    {:obj, ref}
  end

  # ── Shared helpers ──

  defp cb_call(cb, args), do: Runtime.call_callback(cb, args, :no_interp)
  defp truthy?(v), do: v not in [false, nil, :undefined, 0, ""]
  defp to_idx(n) when is_integer(n), do: n
  defp to_idx(n) when is_float(n), do: trunc(n)
  defp to_idx(_), do: 0

  defp parse_ta_args(args, type) do
    case args do
      [{:obj, buf_ref} = buf_obj | rest] ->
        buf = Heap.get_obj(buf_ref, %{})

        cond do
          is_list(buf) ->
            {list_to_buffer(buf, type), 0, length(buf), nil}

          is_map(buf) and Map.has_key?(buf, buffer()) ->
            bin = Map.get(buf, buffer())
            off = Enum.at(rest, 0) || 0
            len = Enum.at(rest, 1) || div(byte_size(bin) - off, elem_size(type))
            {bin, off, len, buf_obj}

          true ->
            {<<>>, 0, 0, nil}
        end

      [n | _] when is_integer(n) ->
        {:binary.copy(<<0>>, n * elem_size(type)), 0, n, nil}

      [list | _] when is_list(list) ->
        {list_to_buffer(list, type), 0, length(list), nil}

      _ ->
        {<<>>, 0, 0, nil}
    end
  end

  # ── Element read/write ──

  def get_element({:obj, ref}, idx) do
    ta = Heap.get_obj(ref, %{})
    read_element(Map.get(ta, buffer(), <<>>), idx, Map.get(ta, type_key(), :uint8))
  end

  def set_element({:obj, ref}, idx, val) do
    ta = Heap.get_obj(ref, %{})
    t = Map.get(ta, type_key(), :uint8)

    Heap.put_obj(
      ref,
      Map.put(ta, buffer(), write_element(Map.get(ta, buffer(), <<>>), idx, val, t))
    )
  end

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
  defp read_element(buf, pos, :uint8_clamped) when pos < byte_size(buf), do: :binary.at(buf, pos)

  defp read_element(buf, pos, :int8) when pos < byte_size(buf) do
    v = :binary.at(buf, pos)
    if v >= 128, do: v - 256, else: v
  end

  defp read_element(buf, pos, :uint16) when pos * 2 + 1 < byte_size(buf),
    do: :binary.decode_unsigned(:binary.part(buf, pos * 2, 2), :little)

  defp read_element(buf, pos, :int16) when pos * 2 + 1 < byte_size(buf) do
    v = :binary.decode_unsigned(:binary.part(buf, pos * 2, 2), :little)
    if v >= 0x8000, do: v - 0x10000, else: v
  end

  defp read_element(buf, pos, :uint32) when pos * 4 + 3 < byte_size(buf),
    do: :binary.decode_unsigned(:binary.part(buf, pos * 4, 4), :little)

  defp read_element(buf, pos, :int32) when pos * 4 + 3 < byte_size(buf) do
    v = :binary.decode_unsigned(:binary.part(buf, pos * 4, 4), :little)
    if v >= 0x80000000, do: v - 0x100000000, else: v
  end

  defp read_element(buf, pos, :float32) when pos * 4 + 3 < byte_size(buf) do
    <<f::little-float-32>> = :binary.part(buf, pos * 4, 4)
    f
  end

  defp read_element(buf, pos, :float64) when pos * 8 + 7 < byte_size(buf) do
    <<f::little-float-64>> = :binary.part(buf, pos * 8, 8)
    f
  end

  defp read_element(_, _, _), do: :undefined

  defp write_element(buf, pos, val, :uint8_clamped) when pos < byte_size(buf) do
    v = trunc(max(0, min(255, val || 0)))
    <<pre::binary-size(pos), _::8, rest::binary>> = buf
    <<pre::binary, v::8, rest::binary>>
  end

  defp write_element(buf, pos, val, :uint8) when pos < byte_size(buf) do
    v = trunc(val || 0) |> Bitwise.band(0xFF)
    <<pre::binary-size(pos), _::8, rest::binary>> = buf
    <<pre::binary, v::8, rest::binary>>
  end

  defp write_element(buf, pos, val, :int8) when pos < byte_size(buf) do
    <<pre::binary-size(pos), _::8, rest::binary>> = buf
    <<pre::binary, trunc(val || 0)::signed-8, rest::binary>>
  end

  defp write_element(buf, pos, val, :int32) when pos * 4 + 3 < byte_size(buf) do
    bp = pos * 4
    <<pre::binary-size(bp), _::32, rest::binary>> = buf
    <<pre::binary, trunc(val || 0)::little-signed-32, rest::binary>>
  end

  defp write_element(buf, pos, val, :float64) when pos * 8 + 7 < byte_size(buf) do
    bp = pos * 8
    <<pre::binary-size(bp), _::64, rest::binary>> = buf
    <<pre::binary, (val || 0.0) * 1.0::little-float-64, rest::binary>>
  end

  defp write_element(buf, pos, val, :float32) when pos * 4 + 3 < byte_size(buf) do
    bp = pos * 4
    <<pre::binary-size(bp), _::32, rest::binary>> = buf
    <<pre::binary, (val || 0.0) * 1.0::little-float-32, rest::binary>>
  end

  defp write_element(buf, pos, val, type) do
    es = elem_size(type)
    bp = pos * es

    if bp + es <= byte_size(buf) do
      <<pre::binary-size(bp), _::binary-size(es), rest::binary>> = buf
      <<pre::binary, trunc(val || 0)::little-unsigned-size(es * 8), rest::binary>>
    else
      buf
    end
  end

  defp list_to_buffer(list, type) do
    es = elem_size(type)
    buf = :binary.copy(<<0>>, length(list) * es)

    list
    |> Enum.with_index()
    |> Enum.reduce(buf, fn {val, i}, acc -> write_element(acc, i, val, type) end)
  end

  defp make_buffer_ref(buffer) do
    Heap.wrap(%{buffer() => buffer, "byteLength" => byte_size(buffer)})
  end
end
