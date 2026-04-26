defmodule QuickBEAM.VM.Runtime.TypedArray do
  @moduledoc "JS TypedArray built-ins: constructors and prototype methods for all numeric array types (Uint8Array through Float64Array)."

  import QuickBEAM.VM.Heap.Keys

  use QuickBEAM.VM.Builtin

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.Runtime

  @types %{
    "Uint8Array" => :uint8,
    "Int8Array" => :int8,
    "Uint8ClampedArray" => :uint8_clamped,
    "Uint16Array" => :uint16,
    "Int16Array" => :int16,
    "Uint32Array" => :uint32,
    "Int32Array" => :int32,
    "Float32Array" => :float32,
    "Float64Array" => :float64,
    "Float16Array" => :float16
  }

  def types, do: @types

  def constructor(type) do
    fn args, _this ->
      {buf, offset, len, orig_buf} = parse_args(args, type)
      ref = make_ref()

      methods =
        object heap: false do
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
          method("toString", do: join(ref, [","]))
        end

      sym_iter = {:symbol, "Symbol.iterator"}

      obj =
        Map.merge(methods, %{
          typed_array() => true,
          type_key() => type,
          buffer() => buf,
          offset() => offset,
          "length" => len,
          "byteLength" => len * elem_size(type),
          "byteOffset" => offset,
          "BYTES_PER_ELEMENT" => elem_size(type),
          "buffer" => orig_buf || make_buffer_ref(buf),
          sym_iter =>
            {:builtin, "[Symbol.iterator]",
             fn _args, this ->
               case this do
                 {:obj, iter_ref} ->
                   l = Map.get(Heap.get_obj(iter_ref, %{}), "length", 0)

                   list =
                     if l > 0,
                       do: for(i <- 0..(l - 1), do: get_element({:obj, iter_ref}, i)),
                       else: []

                   Heap.wrap_iterator(list)

                 _ ->
                   Heap.wrap_iterator([])
               end
             end}
        })

      Heap.put_obj(ref, obj)
      {:obj, ref}
    end
  end

  # ── Element access (public, used by ObjectModel.Put) ──

  def immutable?({:obj, ref}) do
    is_immutable_buffer?(Heap.get_obj(ref, %{}))
  end

  def get_element({:obj, ref}, idx) do
    b = buf(ref)
    if b == nil, do: :undefined, else: read_element(b, idx, type(ref))
  end

  def set_element({:obj, ref}, idx, val) do
    ta = Heap.get_obj(ref, %{})

    if Map.get(ta, "__immutable__") || is_immutable_buffer?(ta) do
      :ok
    else
      t = Map.get(ta, type_key(), :uint8)
      new_buf = write_element(buf(ref) || <<>>, idx, val, t)
      update_buffer(ref, new_buf)
    end
  end

  # credo:disable-for-next-line Credo.Check.Readability.PredicateFunctionNames
  defp is_immutable_buffer?(ta) do
    case Map.get(ta, "buffer") do
      {:obj, buf_ref} ->
        case Heap.get_obj(buf_ref, %{}) do
          m when is_map(m) -> Map.get(m, "__immutable__", false)
          _ -> false
        end

      _ ->
        false
    end
  end

  # ── State readers ──

  defp state(ref), do: Heap.get_obj(ref, %{})

  defp buf(ref) do
    s = state(ref)

    case Map.get(s, "buffer") do
      {:obj, buf_ref} ->
        case Heap.get_obj(buf_ref, %{}) do
          m when is_map(m) ->
            if Map.get(m, "__detached__") do
              nil
            else
              ab_buf = Map.get(m, buffer(), <<>>)
              offset = Map.get(s, "byteOffset", 0)
              byte_len = Map.get(s, "byteLength", byte_size(ab_buf) - offset)

              if offset == 0 and byte_len == byte_size(ab_buf) do
                ab_buf
              else
                binary_part(ab_buf, offset, min(byte_len, byte_size(ab_buf) - offset))
              end
            end

          _ ->
            Map.get(s, buffer(), <<>>)
        end

      _ ->
        Map.get(s, buffer(), <<>>)
    end
  end

  defp len(ref), do: Map.get(state(ref), "length", 0)
  defp type(ref), do: Map.get(state(ref), type_key(), :uint8)

  # ── Method implementations ──

  defp set(ref, args) do
    {source, offset} =
      case args do
        [s, o | _] when is_number(o) -> {s, trunc(o)}
        [s | _] -> {s, 0}
        _ -> {nil, 0}
      end

    src_list = Heap.to_list(source)
    t = type(ref)

    new_buf =
      src_list
      |> Enum.with_index(offset)
      |> Enum.reduce(buf(ref), fn {v, i}, acc -> write_element(acc, i, v, t) end)

    update_buffer(ref, new_buf)
    :undefined
  end

  defp subarray(ref, args) do
    l = len(ref)
    t = type(ref)
    s = max(0, min(to_idx(arg(args, 0, 0)), l))
    e = min(to_idx(arg(args, 1, l)), l)
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
    sep =
      case args do
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

    elements = for i <- 0..(l - 1), do: read_element(new_buf, i, t)
    constructor(t).([elements], nil)
  end

  defp filter(ref, [cb | _], this) do
    {b, l, t} = {buf(ref), len(ref), type(ref)}

    vals =
      for i <- 0..(l - 1),
          (
            v = read_element(b, i, t)
            Runtime.truthy?(call(cb, [v, i, this]))
          ),
          do: v

    constructor(t).([vals], nil)
  end

  defp every(ref, [cb | _], this) do
    {b, l, t} = {buf(ref), len(ref), type(ref)}
    Enum.all?(0..max(0, l - 1), &Runtime.truthy?(call(cb, [read_element(b, &1, t), &1, this])))
  end

  defp some(ref, [cb | _], this) do
    {b, l, t} = {buf(ref), len(ref), type(ref)}
    Enum.any?(0..max(0, l - 1), &Runtime.truthy?(call(cb, [read_element(b, &1, t), &1, this])))
  end

  defp reduce(ref, args, this) do
    {b, l, t} = {buf(ref), len(ref), type(ref)}
    cb = arg(args, 0, nil)
    init = arg(args, 1, nil)
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
      if Runtime.truthy?(call(cb, [v, i, this])), do: v
    end)
  end

  defp sort(ref) do
    {b, l, t} = {buf(ref), len(ref), type(ref)}
    vals = Enum.map(0..max(0, l - 1), &read_element(b, &1, t)) |> Enum.sort()
    new_buf = rebuild_buffer(vals, b, t)
    update_buffer(ref, new_buf)
    {:obj, ref}
  end

  defp reverse(ref) do
    {b, l, t} = {buf(ref), len(ref), type(ref)}
    vals = Enum.map(0..max(0, l - 1), &read_element(b, &1, t)) |> Enum.reverse()
    new_buf = rebuild_buffer(vals, b, t)
    update_buffer(ref, new_buf)
    {:obj, ref}
  end

  defp slice(ref, args) do
    l = len(ref)
    t = type(ref)
    s = max(0, to_idx(arg(args, 0, 0)))
    e = min(l, to_idx(arg(args, 1, l)))
    new_len = max(0, e - s)
    es = elem_size(t)
    new_buf = if new_len > 0, do: binary_part(buf(ref), s * es, new_len * es), else: <<>>

    species_ctor = get_species_ctor({:obj, ref})

    if species_ctor do
      result = Runtime.call_callback(species_ctor, [new_len])

      case result do
        {:obj, _result_ref} ->
          for i <- 0..(new_len - 1) do
            val = read_element(new_buf, i, t)
            set_element(result, i, val)
          end

        _ ->
          :ok
      end

      result
    else
      elements = for i <- 0..(new_len - 1), do: read_element(new_buf, i, t)
      constructor(t).([elements], nil)
    end
  end

  defp get_species_ctor({:obj, ref}) do
    map = Heap.get_obj(ref, %{})
    ctor = Map.get(map, "constructor")

    case ctor do
      {:obj, ctor_ref} ->
        ctor_map = Heap.get_obj(ctor_ref, %{})
        species = Map.get(ctor_map, {:symbol, "Symbol.species"})
        if species != nil, do: species, else: nil

      _ ->
        nil
    end
  end

  defp fill(ref, [val | _]) do
    {l, t} = {len(ref), type(ref)}
    new_buf = Enum.reduce(0..(l - 1), buf(ref) || <<>>, &write_element(&2, &1, val, t))
    update_buffer(ref, new_buf)
    {:obj, ref}
  end

  defp update_buffer(ref, new_buf) do
    s = state(ref)
    Heap.put_obj(ref, Map.put(s, buffer(), new_buf))

    case Map.get(s, "buffer") do
      {:obj, buf_ref} ->
        buf_map = Heap.get_obj(buf_ref, %{})

        if is_map(buf_map) do
          offset = Map.get(s, "byteOffset", 0)
          ab_buf = Map.get(buf_map, buffer(), <<>>)

          before =
            if offset > 0, do: binary_part(ab_buf, 0, min(offset, byte_size(ab_buf))), else: <<>>

          after_offset = offset + byte_size(new_buf)

          after_part =
            if after_offset < byte_size(ab_buf),
              do: binary_part(ab_buf, after_offset, byte_size(ab_buf) - after_offset),
              else: <<>>

          merged = before <> new_buf <> after_part
          Heap.put_obj(buf_ref, Map.put(buf_map, buffer(), merged))
        end

      _ ->
        :ok
    end
  end

  # ── Helpers ──

  defp decode_float16(bits) do
    sign = Bitwise.bsr(bits, 15) |> Bitwise.band(1)
    exp = Bitwise.bsr(bits, 10) |> Bitwise.band(0x1F)
    frac = Bitwise.band(bits, 0x3FF)
    s = if sign == 1, do: -1.0, else: 1.0

    cond do
      exp == 0 and frac == 0 -> s * 0.0
      exp == 0 -> s * frac * :math.pow(2, -24)
      exp == 31 and frac == 0 -> if(s == -1.0, do: :neg_infinity, else: :infinity)
      exp == 31 -> :nan
      true -> s * :math.pow(2, exp - 15) * (1 + frac / 1024)
    end
  end

  defp encode_float16(n) when n in [:nan, :NaN], do: 0x7E00
  defp encode_float16(:infinity), do: 0x7C00
  defp encode_float16(:neg_infinity), do: 0xFC00

  defp encode_float16(n) when is_number(n) do
    f = n * 1.0
    sign = if f < 0, do: 1, else: 0
    abs_f = abs(f)

    cond do
      abs_f == 0.0 ->
        Bitwise.bsl(sign, 15)

      abs_f >= 65_520.0 ->
        Bitwise.bsl(sign, 15) |> Bitwise.bor(0x7C00)

      true ->
        exp = trunc(:math.floor(:math.log2(abs_f)))
        exp = max(-14, min(15, exp))
        frac = trunc((abs_f / :math.pow(2, exp) - 1) * 1024 + 0.5) |> Bitwise.band(0x3FF)
        exp_biased = exp + 15

        Bitwise.bsl(sign, 15)
        |> Bitwise.bor(Bitwise.bsl(exp_biased, 10))
        |> Bitwise.bor(frac)
    end
  end

  defp encode_float16(_), do: 0

  defp bankers_round(n) when is_float(n) do
    floor = trunc(n)
    frac = n - floor

    cond do
      frac > 0.5 -> floor + 1
      frac < 0.5 -> floor
      rem(floor, 2) == 0 -> floor
      true -> floor + 1
    end
  end

  defp bankers_round(n) when is_integer(n), do: n
  defp bankers_round(_), do: 0

  defp call(cb, args), do: Runtime.call_callback(cb, args)
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
          match?({:qb_arr, _}, buf) ->
            list = :array.to_list(elem(buf, 1))
            {list_to_buffer(list, type), 0, length(list), nil}

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

      [{:qb_arr, arr} | _] ->
        list = :array.to_list(arr)
        {list_to_buffer(list, type), 0, length(list), nil}

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
  defp elem_size(:float16), do: 2
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

  defp read_element(buf, pos, :float16) when pos * 2 + 1 < byte_size(buf) do
    <<_::binary-size(pos * 2), half::16-little, _::binary>> = buf
    decode_float16(half)
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
    v = max(0, min(255, bankers_round(val || 0)))
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

  defp write_element(buf, pos, val, :float16) when pos * 2 + 1 < byte_size(buf) do
    half = encode_float16(val || 0)
    <<pre::binary-size(pos * 2), _::16, rest::binary>> = buf
    <<pre::binary, half::16-little, rest::binary>>
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
