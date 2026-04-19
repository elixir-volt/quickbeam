defmodule QuickBEAM.BeamVM.Runtime.TypedArray do
  @moduledoc false

  import QuickBEAM.BeamVM.Heap.Keys

  use QuickBEAM.BeamVM.Builtin

  alias QuickBEAM.BeamVM.Heap
  alias QuickBEAM.BeamVM.Runtime

  def constructor(type) do
    fn args, _this ->
      {buf, offset, len, orig_buf} = parse_args(args, type)
      ref = make_ref()

      methods =
        build_methods do
          method("set", do: set(ref, args))
          method("subarray", do: subarray(ref, args))
          method("join", do: join(ref, args))
          method("forEach", do: for_each(ref, args, this))
          method("map", do: map(ref, args, this))
          method("filter", do: filter(ref, args, this))
          method("every", do: every(ref, args, this))
          method("some", do: some(ref, args, this))
          method("reduce", do: reduce(ref, args, this))
          method("indexOf", do: index_of(ref, args))
          method("find", do: find(ref, args, this))
          method("sort", do: sort(ref))
          method("reverse", do: reverse(ref))
          method("slice", do: slice(ref, args))
          method("fill", do: fill(ref, args))
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

  # ── Element access (public, used by Interpreter.Objects) ──

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

  # ── State readers ──

  defp state(ref), do: Heap.get_obj(ref, %{})
  defp buf(ref), do: Map.get(state(ref), buffer(), <<>>)
  defp len(ref), do: Map.get(state(ref), "length", 0)
  defp type(ref), do: Map.get(state(ref), type_key(), :uint8)

  # ── Method implementations ──

  defp set(ref, [source | _]) do
    src_list = Heap.to_list(source)
    t = type(ref)

    new_buf =
      src_list
      |> Enum.with_index()
      |> Enum.reduce(buf(ref), fn {v, i}, acc -> write_element(acc, i, v, t) end)

    Heap.put_obj(ref, Map.put(state(ref), buffer(), new_buf))
    :undefined
  end

  defp subarray(ref, args) do
    l = len(ref)
    t = type(ref)
    s = max(0, min(to_idx(Enum.at(args, 0, 0)), l))
    e = min(to_idx(Enum.at(args, 1, l)), l)
    new_len = max(0, e - s)
    es = elem_size(t)

    Heap.wrap(%{
      typed_array() => true,
      type_key() => t,
      buffer() => binary_part(buf(ref), s * es, new_len * es),
      offset() => 0,
      "length" => new_len,
      "byteLength" => new_len * es,
      "byteOffset" => 0,
      "buffer" => Map.get(state(ref), "buffer")
    })
  end

  defp join(ref, args) do
    sep = case args do
      [s | _] when is_binary(s) -> s
      _ -> ","
    end

    {b, l, t} = {buf(ref), len(ref), type(ref)}
    Enum.map_join(0..max(0, l - 1), sep, &Integer.to_string(trunc(read_element(b, &1, t))))
  end

  defp for_each(ref, [cb | _], this) do
    {b, l, t} = {buf(ref), len(ref), type(ref)}
    for i <- 0..(l - 1), do: call(cb, [read_element(b, i, t), i, this])
    :undefined
  end

  defp map(ref, [cb | _], this) do
    {b, l, t} = {buf(ref), len(ref), type(ref)}

    new_buf =
      Enum.reduce(0..(l - 1), b, fn i, acc ->
        write_element(acc, i, call(cb, [read_element(acc, i, t), i, this]), t)
      end)

    Heap.wrap(%{
      typed_array() => true,
      type_key() => t,
      buffer() => new_buf,
      offset() => 0,
      "length" => l,
      "byteLength" => byte_size(new_buf),
      "byteOffset" => 0
    })
  end

  defp filter(ref, [cb | _], this) do
    {b, l, t} = {buf(ref), len(ref), type(ref)}

    vals =
      for i <- 0..(l - 1),
          (v = read_element(b, i, t); truthy?(call(cb, [v, i, this]))),
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

  defp every(ref, [cb | _], this) do
    {b, l, t} = {buf(ref), len(ref), type(ref)}
    Enum.all?(0..max(0, l - 1), &truthy?(call(cb, [read_element(b, &1, t), &1, this])))
  end

  defp some(ref, [cb | _], this) do
    {b, l, t} = {buf(ref), len(ref), type(ref)}
    Enum.any?(0..max(0, l - 1), &truthy?(call(cb, [read_element(b, &1, t), &1, this])))
  end

  defp reduce(ref, args, this) do
    {b, l, t} = {buf(ref), len(ref), type(ref)}
    cb = List.first(args)
    init = Enum.at(args, 1)
    {start, acc} = if init != nil, do: {0, init}, else: {1, read_element(b, 0, t)}

    Enum.reduce(start..max(start, l - 1), acc, fn i, a ->
      call(cb, [a, read_element(b, i, t), i, this])
    end)
  end

  defp index_of(ref, [target | _]) do
    {b, l, t} = {buf(ref), len(ref), type(ref)}

    Enum.find_value(0..max(0, l - 1), -1, fn i ->
      if read_element(b, i, t) == target, do: i
    end)
  end

  defp find(ref, [cb | _], this) do
    {b, l, t} = {buf(ref), len(ref), type(ref)}

    Enum.find_value(0..max(0, l - 1), :undefined, fn i ->
      v = read_element(b, i, t)
      if truthy?(call(cb, [v, i, this])), do: v
    end)
  end

  defp sort(ref) do
    {b, l, t} = {buf(ref), len(ref), type(ref)}
    vals = Enum.map(0..max(0, l - 1), &read_element(b, &1, t)) |> Enum.sort()
    new_buf = rebuild_buffer(vals, b, t)
    Heap.put_obj(ref, Map.put(state(ref), buffer(), new_buf))
    {:obj, ref}
  end

  defp reverse(ref) do
    {b, l, t} = {buf(ref), len(ref), type(ref)}
    vals = Enum.map(0..max(0, l - 1), &read_element(b, &1, t)) |> Enum.reverse()
    new_buf = rebuild_buffer(vals, b, t)
    Heap.put_obj(ref, Map.put(state(ref), buffer(), new_buf))
    {:obj, ref}
  end

  defp slice(ref, args) do
    l = len(ref)
    t = type(ref)
    s = max(0, to_idx(Enum.at(args, 0, 0)))
    e = min(l, to_idx(Enum.at(args, 1, l)))
    new_len = max(0, e - s)
    es = elem_size(t)
    new_buf = if new_len > 0, do: binary_part(buf(ref), s * es, new_len * es), else: <<>>

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

  defp fill(ref, [val | _]) do
    {l, t} = {len(ref), type(ref)}
    new_buf = Enum.reduce(0..(l - 1), buf(ref), &write_element(&2, &1, val, t))
    Heap.put_obj(ref, Map.put(state(ref), buffer(), new_buf))
    {:obj, ref}
  end

  # ── Helpers ──

  defp call(cb, args), do: Runtime.call_callback(cb, args)
  defp truthy?(v), do: v not in [false, nil, :undefined, 0, ""]
  defp to_idx(n) when is_integer(n), do: n
  defp to_idx(n) when is_float(n), do: trunc(n)
  defp to_idx(_), do: 0

  defp rebuild_buffer(vals, buf, type) do
    vals
    |> Enum.with_index()
    |> Enum.reduce(buf, fn {v, i}, acc -> write_element(acc, i, v, type) end)
  end

  defp parse_args(args, type) do
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

  defp make_buffer_ref(buffer_data) do
    Heap.wrap(%{buffer() => buffer_data, "byteLength" => byte_size(buffer_data)})
  end
end
