defmodule QuickBEAM.VM.Runtime.Web.Buffer do
  @moduledoc "Node.js Buffer class builtin for BEAM mode."

  import Bitwise
  import QuickBEAM.VM.Builtin, only: [build_methods: 1]

  alias QuickBEAM.VM.{Heap, JSThrow}
  alias QuickBEAM.VM.ObjectModel.{Get, Put}
  alias QuickBEAM.VM.Runtime.WebAPIs

  @known_encodings ~w[utf8 utf-8 ascii latin1 binary base64 base64url hex ucs2 utf16le utf-16le ucs-2]

  def bindings do
    ctor = build_buffer_ctor()
    %{"Buffer" => ctor}
  end

  defp build_buffer_ctor do
    ctor = {:builtin, "Buffer", &build_buffer_from/2}
    proto = build_buffer_proto(ctor)
    Heap.put_class_proto(ctor, proto)
    Heap.put_ctor_static(ctor, "prototype", proto)

    # Static methods
    Heap.put_ctor_static(ctor, "from", {:builtin, "Buffer.from", fn args, _ -> buffer_from(args) end})
    Heap.put_ctor_static(ctor, "alloc", {:builtin, "Buffer.alloc", fn args, _ -> buffer_alloc(args) end})
    Heap.put_ctor_static(ctor, "allocUnsafe", {:builtin, "Buffer.allocUnsafe", fn args, _ -> buffer_alloc_unsafe(args) end})
    Heap.put_ctor_static(ctor, "allocUnsafeSlow", {:builtin, "Buffer.allocUnsafeSlow", fn args, _ -> buffer_alloc_unsafe(args) end})
    Heap.put_ctor_static(ctor, "concat", {:builtin, "Buffer.concat", fn args, _ -> buffer_concat(args) end})
    Heap.put_ctor_static(ctor, "compare", {:builtin, "Buffer.compare", fn args, _ -> buffer_compare(args) end})
    Heap.put_ctor_static(ctor, "isBuffer", {:builtin, "Buffer.isBuffer", fn args, _ -> buffer_is_buffer(args) end})
    Heap.put_ctor_static(ctor, "isEncoding", {:builtin, "Buffer.isEncoding", fn args, _ -> buffer_is_encoding(args) end})
    Heap.put_ctor_static(ctor, "byteLength", {:builtin, "Buffer.byteLength", fn args, _ -> buffer_byte_length(args) end})

    ctor
  end

  defp build_buffer_proto(ctor) do
    proto_ref = make_ref()
    methods = build_methods do
      val("constructor", ctor)
    end

    proto_map = Map.merge(methods, %{
      "toString" => {:builtin, "toString", fn args, this -> buf_to_string(this, args) end},
      "write" => {:builtin, "write", fn args, this -> buf_write(this, args) end},
      "slice" => {:builtin, "slice", fn args, this -> buf_slice(this, args) end},
      "subarray" => {:builtin, "subarray", fn args, this -> buf_slice(this, args) end},
      "copy" => {:builtin, "copy", fn args, this -> buf_copy(this, args) end},
      "compare" => {:builtin, "compare", fn args, this -> buf_compare_instance(this, args) end},
      "equals" => {:builtin, "equals", fn args, this -> buf_equals(this, args) end},
      "indexOf" => {:builtin, "indexOf", fn args, this -> buf_index_of(this, args) end},
      "lastIndexOf" => {:builtin, "lastIndexOf", fn args, this -> buf_last_index_of(this, args) end},
      "includes" => {:builtin, "includes", fn args, this -> buf_includes(this, args) end},
      "fill" => {:builtin, "fill", fn args, this -> buf_fill(this, args); this end},
      "toJSON" => {:builtin, "toJSON", fn _args, this -> buf_to_json(this) end},
      "swap16" => {:builtin, "swap16", fn _args, this -> buf_swap16(this) end},
      "swap32" => {:builtin, "swap32", fn _args, this -> buf_swap32(this) end},
      "swap64" => {:builtin, "swap64", fn _args, this -> buf_swap64(this) end},
      "readUInt8" => {:builtin, "readUInt8", fn args, this -> buf_read_uint(this, args, 1, :unsigned, :big) end},
      "readUInt16BE" => {:builtin, "readUInt16BE", fn args, this -> buf_read_uint(this, args, 2, :unsigned, :big) end},
      "readUInt16LE" => {:builtin, "readUInt16LE", fn args, this -> buf_read_uint(this, args, 2, :unsigned, :little) end},
      "readUInt32BE" => {:builtin, "readUInt32BE", fn args, this -> buf_read_uint(this, args, 4, :unsigned, :big) end},
      "readUInt32LE" => {:builtin, "readUInt32LE", fn args, this -> buf_read_uint(this, args, 4, :unsigned, :little) end},
      "readInt8" => {:builtin, "readInt8", fn args, this -> buf_read_uint(this, args, 1, :signed, :big) end},
      "readInt16BE" => {:builtin, "readInt16BE", fn args, this -> buf_read_uint(this, args, 2, :signed, :big) end},
      "readInt16LE" => {:builtin, "readInt16LE", fn args, this -> buf_read_uint(this, args, 2, :signed, :little) end},
      "readInt32BE" => {:builtin, "readInt32BE", fn args, this -> buf_read_uint(this, args, 4, :signed, :big) end},
      "readInt32LE" => {:builtin, "readInt32LE", fn args, this -> buf_read_uint(this, args, 4, :signed, :little) end},
      "readBigUInt64BE" => {:builtin, "readBigUInt64BE", fn args, this -> buf_read_uint(this, args, 8, :unsigned, :big) end},
      "readBigUInt64LE" => {:builtin, "readBigUInt64LE", fn args, this -> buf_read_uint(this, args, 8, :unsigned, :little) end},
      "readBigInt64BE" => {:builtin, "readBigInt64BE", fn args, this -> buf_read_uint(this, args, 8, :signed, :big) end},
      "readBigInt64LE" => {:builtin, "readBigInt64LE", fn args, this -> buf_read_uint(this, args, 8, :signed, :little) end},
      "readFloatBE" => {:builtin, "readFloatBE", fn args, this -> buf_read_float(this, args, 4, :big) end},
      "readFloatLE" => {:builtin, "readFloatLE", fn args, this -> buf_read_float(this, args, 4, :little) end},
      "readDoubleBE" => {:builtin, "readDoubleBE", fn args, this -> buf_read_float(this, args, 8, :big) end},
      "readDoubleLE" => {:builtin, "readDoubleLE", fn args, this -> buf_read_float(this, args, 8, :little) end},
      "writeUInt8" => {:builtin, "writeUInt8", fn args, this -> buf_write_uint(this, args, 1, :unsigned, :big) end},
      "writeUInt16BE" => {:builtin, "writeUInt16BE", fn args, this -> buf_write_uint(this, args, 2, :unsigned, :big) end},
      "writeUInt16LE" => {:builtin, "writeUInt16LE", fn args, this -> buf_write_uint(this, args, 2, :unsigned, :little) end},
      "writeUInt32BE" => {:builtin, "writeUInt32BE", fn args, this -> buf_write_uint(this, args, 4, :unsigned, :big) end},
      "writeUInt32LE" => {:builtin, "writeUInt32LE", fn args, this -> buf_write_uint(this, args, 4, :unsigned, :little) end},
      "writeInt8" => {:builtin, "writeInt8", fn args, this -> buf_write_uint(this, args, 1, :signed, :big) end},
      "writeInt16BE" => {:builtin, "writeInt16BE", fn args, this -> buf_write_uint(this, args, 2, :signed, :big) end},
      "writeInt16LE" => {:builtin, "writeInt16LE", fn args, this -> buf_write_uint(this, args, 2, :signed, :little) end},
      "writeInt32BE" => {:builtin, "writeInt32BE", fn args, this -> buf_write_uint(this, args, 4, :signed, :big) end},
      "writeInt32LE" => {:builtin, "writeInt32LE", fn args, this -> buf_write_uint(this, args, 4, :signed, :little) end},
      "writeFloatBE" => {:builtin, "writeFloatBE", fn args, this -> buf_write_float(this, args, 4, :big) end},
      "writeFloatLE" => {:builtin, "writeFloatLE", fn args, this -> buf_write_float(this, args, 4, :little) end},
      "writeDoubleBE" => {:builtin, "writeDoubleBE", fn args, this -> buf_write_float(this, args, 8, :big) end},
      "writeDoubleLE" => {:builtin, "writeDoubleLE", fn args, this -> buf_write_float(this, args, 8, :little) end},
      "__is_buffer__" => true
    })

    # Inherit typed array proto methods (forEach, map, every, etc.)
    uint8_proto = get_uint8_proto()
    final_map = if uint8_proto do
      Map.put(proto_map, "__proto__", uint8_proto)
    else
      proto_map
    end

    Heap.put_obj(proto_ref, final_map)
    {:obj, proto_ref}
  end

  defp get_uint8_proto do
    case Heap.get_global_cache() do
      nil -> nil
      globals ->
        case Map.get(globals, "Uint8Array") do
          {:builtin, _, _} = ctor -> Heap.get_class_proto(ctor)
          _ -> nil
        end
    end
  end

  # Constructor call (new Buffer is deprecated but we still need to handle it)
  defp build_buffer_from(args, _this), do: buffer_from(args)

  # ── Buffer.from ──

  def buffer_from([src | rest]) do
    bytes = case src do
      b when is_binary(b) ->
        encoding = get_encoding(rest, 0)
        case encoding do
          "hex" -> hex_decode(b)
          "base64" -> base64_decode(b)
          "base64url" -> base64url_decode(b)
          "latin1" -> latin1_to_bytes(b)
          "binary" -> latin1_to_bytes(b)
          "ascii" -> ascii_bytes(b)
          enc when enc in ["utf16le", "ucs2", "ucs-2", "utf-16le"] -> utf16le_encode(b)
          _ -> b  # utf8
        end

      {:bytes, bin} when is_binary(bin) -> bin

      {:obj, _} = arr ->
        case get_obj_type(arr) do
          :array_buffer ->
            ab_data = extract_ab(arr)
            offset = to_int(Enum.at(rest, 0, 0))
            ab_len = byte_size(ab_data)
            len = to_int(Enum.at(rest, 1, ab_len - offset))
            start = min(offset, ab_len)
            actual_len = min(len, ab_len - start)
            if actual_len > 0, do: binary_part(ab_data, start, actual_len), else: <<>>

          :typed_array ->
            extract_typed_bytes(arr)

          :json_buffer ->
            data = Get.get(arr, "data")
            list_to_bytes(data)

          :array_like ->
            list_to_bytes(arr)

          _ ->
            <<>>
        end

      {:qb_arr, _} = arr ->
        items = Heap.to_list(arr)
        list_to_bytes_raw(items)

      list when is_list(list) -> list_to_bytes_raw(list)
      _ -> <<>>
    end

    wrap_buffer(bytes)
  end

  def buffer_from([]) do
    wrap_buffer(<<>>)
  end

  # ── Buffer.alloc ──

  defp buffer_alloc([size | rest]) do
    n = to_int(size)
    fill = Enum.at(rest, 0, 0)
    _enc = get_encoding(rest, 2)

    bytes = case fill do
      0 -> :binary.copy(<<0>>, n)
      f when is_integer(f) ->
        byte_val = band(f, 0xFF)
        :binary.copy(<<byte_val>>, n)
      f when is_float(f) ->
        byte_val = band(trunc(f), 0xFF)
        :binary.copy(<<byte_val>>, n)
      f when is_binary(f) ->
        fill_with_string(n, f)
      _ -> :binary.copy(<<0>>, n)
    end

    wrap_buffer(bytes)
  end

  defp buffer_alloc([]), do: wrap_buffer(<<>>)

  defp buffer_alloc_unsafe([size | _]) do
    n = to_int(size)
    wrap_buffer(:binary.copy(<<0>>, n))
  end

  defp buffer_alloc_unsafe([]), do: wrap_buffer(<<>>)

  # ── Buffer.concat ──

  defp buffer_concat([list | rest]) do
    total_limit = case rest do
      [n | _] when is_integer(n) -> n
      [n | _] when is_float(n) -> trunc(n)
      _ -> nil
    end

    items = case list do
      {:obj, _} -> Heap.to_list(list)
      l when is_list(l) -> l
      _ -> []
    end

    combined = Enum.map_join(items, "", &extract_buf_bytes/1)

    final = case total_limit do
      nil -> combined
      n ->
        limit = min(n, byte_size(combined))
        binary_part(combined, 0, limit)
    end

    wrap_buffer(final)
  end

  defp buffer_concat([]), do: wrap_buffer(<<>>)

  # ── Buffer.compare (static) ──

  defp buffer_compare([a, b | _]) do
    ba = extract_buf_bytes(a)
    bb = extract_buf_bytes(b)
    compare_bytes(ba, bb)
  end

  defp buffer_compare(_), do: 0

  # ── Buffer.isBuffer ──

  defp buffer_is_buffer([{:obj, ref} | _]) do
    case Heap.get_obj(ref, %{}) do
      m when is_map(m) -> Map.get(m, "__is_buffer__", false) == true
      _ -> false
    end
  end

  defp buffer_is_buffer(_), do: false

  # ── Buffer.isEncoding ──

  defp buffer_is_encoding([enc | _]) when is_binary(enc) do
    String.downcase(enc) in @known_encodings
  end

  defp buffer_is_encoding(_), do: false

  # ── Buffer.byteLength ──

  defp buffer_byte_length([str | rest]) when is_binary(str) do
    enc = get_encoding(rest, 0)
    case enc do
      "hex" -> div(byte_size(str), 2)
      "base64" -> base64_byte_length(str)
      "base64url" -> base64url_byte_length(str)
      "latin1" -> byte_size(str) |> div(1)  # 1 char = 1 byte (approx via UTF8 encoding)
      "binary" -> String.length(str)
      enc when enc in ["utf16le", "ucs2", "ucs-2", "utf-16le"] -> String.length(str) * 2
      _ -> byte_size(str)  # UTF-8
    end
  end

  defp buffer_byte_length([{:obj, _} = arr | _]) do
    byte_size(extract_buf_bytes(arr))
  end

  defp buffer_byte_length(_), do: 0

  # ── Instance methods ──

  defp buf_to_string(this, args) do
    bytes = extract_buf_bytes(this)
    enc = case args do
      [e | _] when is_binary(e) -> String.downcase(e)
      _ -> "utf-8"
    end

    start_idx = case args do
      [_, s | _] when is_integer(s) -> max(0, s)
      [_, s | _] when is_float(s) -> max(0, trunc(s))
      _ -> 0
    end

    end_idx = case args do
      [_, _, e | _] when is_integer(e) -> min(e, byte_size(bytes))
      [_, _, e | _] when is_float(e) -> min(trunc(e), byte_size(bytes))
      _ -> byte_size(bytes)
    end

    slice = if start_idx < byte_size(bytes) and end_idx > start_idx do
      binary_part(bytes, start_idx, end_idx - start_idx)
    else
      <<>>
    end

    case enc do
      "hex" -> Base.encode16(slice, case: :lower)
      "base64" -> Base.encode64(slice)
      "base64url" -> Base.url_encode64(slice, padding: false)
      "latin1" -> bytes_to_latin1(slice)
      "binary" -> bytes_to_latin1(slice)
      "ascii" -> bytes_to_ascii(slice)
      enc when enc in ["utf16le", "ucs2", "ucs-2", "utf-16le"] ->
        :unicode.characters_to_binary(slice, {:utf16, :little}, :utf8)
      _ -> slice  # utf8 — already binary
    end
  end

  defp buf_write(this, args) do
    [str | rest] = args ++ [""]
    offset = to_int(Enum.at(rest, 0, 0))
    buf_len = get_buf_len(this)
    _max_len = case Enum.at(rest, 1) do
      n when is_integer(n) -> n
      n when is_float(n) -> trunc(n)
      _ -> buf_len - offset
    end
    enc = case Enum.at(rest, 2) do
      e when is_binary(e) -> String.downcase(e)
      _ -> "utf-8"
    end

    str_bin = if is_binary(str), do: str, else: to_string(str)
    write_bytes = case enc do
      "hex" -> hex_decode(str_bin)
      "base64" -> base64_decode(str_bin)
      "base64url" -> base64url_decode(str_bin)
      "latin1" -> latin1_to_bytes(str_bin)
      "binary" -> latin1_to_bytes(str_bin)
      "ascii" -> ascii_bytes(str_bin)
      _ -> str_bin
    end

    available = max(0, buf_len - offset)
    actual_write = min(byte_size(write_bytes), available)

    Enum.each(0..(actual_write - 1), fn i ->
      Put.put_element(this, offset + i, :binary.at(write_bytes, i))
    end)

    actual_write
  end

  defp buf_slice(this, args) do
    bytes = extract_buf_bytes(this)
    total = byte_size(bytes)

    start_idx = normalize_idx(Enum.at(args, 0, 0), total)
    end_idx = normalize_idx(Enum.at(args, 1, total), total)

    len = max(0, end_idx - start_idx)
    sliced = if start_idx <= total and len > 0 do
      binary_part(bytes, start_idx, min(len, total - start_idx))
    else
      <<>>
    end

    wrap_buffer(sliced)
  end

  defp buf_copy(this, [target | rest]) do
    src = extract_buf_bytes(this)
    target_offset = to_int(Enum.at(rest, 0, 0))
    src_start = to_int(Enum.at(rest, 1, 0))
    src_end = to_int(Enum.at(rest, 2, byte_size(src)))

    actual_start = max(0, min(src_start, byte_size(src)))
    actual_end = max(actual_start, min(src_end, byte_size(src)))
    len = actual_end - actual_start

    Enum.each(0..(len - 1), fn i ->
      Put.put_element(target, target_offset + i, :binary.at(src, actual_start + i))
    end)

    len
  end

  defp buf_compare_instance(this, [other | rest]) do
    a_bytes = extract_buf_bytes(this)
    b_bytes = extract_buf_bytes(other)

    b_start = to_int(Enum.at(rest, 0, 0))
    b_end = to_int(Enum.at(rest, 1, byte_size(b_bytes)))
    a_start = to_int(Enum.at(rest, 2, 0))
    a_end = to_int(Enum.at(rest, 3, byte_size(a_bytes)))

    a_slice = safe_slice(a_bytes, a_start, a_end)
    b_slice = safe_slice(b_bytes, b_start, b_end)
    compare_bytes(a_slice, b_slice)
  end

  defp buf_equals(this, [other | _]) do
    extract_buf_bytes(this) == extract_buf_bytes(other)
  end

  defp buf_index_of(this, [needle | rest]) do
    bytes = extract_buf_bytes(this)
    offset = to_int(Enum.at(rest, 0, 0))
    search_from = max(0, min(offset, byte_size(bytes)))
    haystack = binary_part(bytes, search_from, byte_size(bytes) - search_from)

    needle_bytes = case needle do
      n when is_integer(n) -> <<band(n, 0xFF)>>
      n when is_float(n) -> <<band(trunc(n), 0xFF)>>
      s when is_binary(s) -> s
      {:obj, _} -> extract_buf_bytes(needle)
      _ -> <<>>
    end

    case :binary.match(haystack, needle_bytes) do
      {pos, _} -> pos + search_from
      :nomatch -> -1
    end
  end

  defp buf_last_index_of(this, [needle | rest]) do
    bytes = extract_buf_bytes(this)
    offset = to_int(Enum.at(rest, 0, byte_size(bytes)))
    search_to = max(0, min(offset, byte_size(bytes)))
    haystack = binary_part(bytes, 0, search_to)

    needle_bytes = case needle do
      n when is_integer(n) -> <<band(n, 0xFF)>>
      n when is_float(n) -> <<band(trunc(n), 0xFF)>>
      s when is_binary(s) -> s
      {:obj, _} -> extract_buf_bytes(needle)
      _ -> <<>>
    end

    positions = :binary.matches(haystack, needle_bytes)
    case List.last(positions) do
      {pos, _} -> pos
      nil -> -1
    end
  end

  defp buf_includes(this, [needle | rest]) do
    buf_index_of(this, [needle | rest]) != -1
  end

  defp buf_fill(this, args) do
    [fill_val | rest] = args ++ [0]
    buf_len = get_buf_len(this)
    offset = to_int(Enum.at(rest, 0, 0))
    end_pos = to_int(Enum.at(rest, 1, buf_len))

    fill_bytes = case fill_val do
      n when is_integer(n) -> <<band(n, 0xFF)>>
      n when is_float(n) -> <<band(trunc(n), 0xFF)>>
      s when is_binary(s) -> if byte_size(s) > 0, do: s, else: <<0>>
      _ -> <<0>>
    end

    actual_end = min(end_pos, buf_len)
    len = max(0, actual_end - offset)
    fill_len = byte_size(fill_bytes)

    Enum.each(0..(len - 1), fn i ->
      byte = :binary.at(fill_bytes, rem(i, fill_len))
      Put.put_element(this, offset + i, byte)
    end)

    this
  end

  defp buf_to_json(this) do
    bytes = extract_buf_bytes(this)
    data = :binary.bin_to_list(bytes)
    Heap.wrap(%{"type" => "Buffer", "data" => data})
  end

  defp buf_swap16(this) do
    bytes = extract_buf_bytes(this)
    len = byte_size(bytes)
    if rem(len, 2) != 0, do: JSThrow.range_error!("Buffer size must be a multiple of 16-bits")
    swapped = for i <- 0..(div(len, 2) - 1) do
      a = :binary.at(bytes, i * 2)
      b = :binary.at(bytes, i * 2 + 1)
      {b, a}
    end |> Enum.flat_map(fn {a, b} -> [a, b] end)

    Enum.each(Enum.with_index(swapped), fn {byte, i} ->
      Put.put_element(this, i, byte)
    end)
    this
  end

  defp buf_swap32(this) do
    bytes = extract_buf_bytes(this)
    len = byte_size(bytes)
    if rem(len, 4) != 0, do: JSThrow.range_error!("Buffer size must be a multiple of 32-bits")
    swapped = for i <- 0..(div(len, 4) - 1) do
      a = :binary.at(bytes, i * 4)
      b = :binary.at(bytes, i * 4 + 1)
      c = :binary.at(bytes, i * 4 + 2)
      d = :binary.at(bytes, i * 4 + 3)
      [d, c, b, a]
    end |> List.flatten()

    Enum.each(Enum.with_index(swapped), fn {byte, i} ->
      Put.put_element(this, i, byte)
    end)
    this
  end

  defp buf_swap64(this) do
    bytes = extract_buf_bytes(this)
    len = byte_size(bytes)
    if rem(len, 8) != 0, do: JSThrow.range_error!("Buffer size must be a multiple of 64-bits")
    swapped = for i <- 0..(div(len, 8) - 1) do
      chunk = binary_part(bytes, i * 8, 8)
      :binary.bin_to_list(chunk) |> Enum.reverse()
    end |> List.flatten()

    Enum.each(Enum.with_index(swapped), fn {byte, i} ->
      Put.put_element(this, i, byte)
    end)
    this
  end

  defp buf_read_uint(this, args, size, sign, endian) do
    offset = to_int(Enum.at(args, 0, 0))
    bytes = extract_buf_bytes(this)

    if byte_size(bytes) < offset + size do
      JSThrow.range_error!("Attempt to access memory outside buffer bounds")
    end

    chunk = binary_part(bytes, offset, size)
    decode_int(chunk, size, sign, endian)
  end

  defp buf_read_float(this, args, size, endian) do
    offset = to_int(Enum.at(args, 0, 0))
    bytes = extract_buf_bytes(this)

    if byte_size(bytes) < offset + size do
      JSThrow.range_error!("Attempt to access memory outside buffer bounds")
    end

    chunk = binary_part(bytes, offset, size)
    decode_float(chunk, size, endian)
  end

  defp buf_write_uint(this, args, size, sign, endian) do
    [val | rest] = args ++ [0]
    offset = to_int(Enum.at(rest, 0, 0))
    n = to_number(val)
    encoded = encode_int(n, size, sign, endian)
    Enum.each(0..(size - 1), fn i ->
      Put.put_element(this, offset + i, :binary.at(encoded, i))
    end)
    offset + size
  end

  defp buf_write_float(this, args, size, endian) do
    [val | rest] = args ++ [0]
    offset = to_int(Enum.at(rest, 0, 0))
    n = to_float(val)
    encoded = encode_float(n, size, endian)
    Enum.each(0..(size - 1), fn i ->
      Put.put_element(this, offset + i, :binary.at(encoded, i))
    end)
    offset + size
  end

  # ── Binary encoding/decoding ──

  defp decode_int(chunk, size, :unsigned, :big) do
    <<n::unsigned-big-integer-size(size)-unit(8)>> = chunk
    n
  end

  defp decode_int(chunk, size, :signed, :big) do
    <<n::signed-big-integer-size(size)-unit(8)>> = chunk
    n
  end

  defp decode_int(chunk, size, :unsigned, :little) do
    <<n::unsigned-little-integer-size(size)-unit(8)>> = chunk
    n
  end

  defp decode_int(chunk, size, :signed, :little) do
    <<n::signed-little-integer-size(size)-unit(8)>> = chunk
    n
  end

  defp encode_int(n, size, :unsigned, :big) do
    int_val = band(trunc(n), max_uint(size))
    <<int_val::unsigned-big-integer-size(size)-unit(8)>>
  end

  defp encode_int(n, size, :signed, :big) do
    int_val = to_signed(trunc(n), size)
    <<int_val::signed-big-integer-size(size)-unit(8)>>
  end

  defp encode_int(n, size, :unsigned, :little) do
    int_val = band(trunc(n), max_uint(size))
    <<int_val::unsigned-little-integer-size(size)-unit(8)>>
  end

  defp encode_int(n, size, :signed, :little) do
    int_val = to_signed(trunc(n), size)
    <<int_val::signed-little-integer-size(size)-unit(8)>>
  end

  defp decode_float(chunk, 4, :big) do
    <<n::float-big-32>> = chunk
    n
  end
  defp decode_float(chunk, 4, :little) do
    <<n::float-little-32>> = chunk
    n
  end
  defp decode_float(chunk, 8, :big) do
    <<n::float-big-64>> = chunk
    n
  end
  defp decode_float(chunk, 8, :little) do
    <<n::float-little-64>> = chunk
    n
  end

  defp encode_float(n, 4, :big), do: <<n::float-big-32>>
  defp encode_float(n, 4, :little), do: <<n::float-little-32>>
  defp encode_float(n, 8, :big), do: <<n::float-big-64>>
  defp encode_float(n, 8, :little), do: <<n::float-little-64>>

  defp max_uint(1), do: 0xFF
  defp max_uint(2), do: 0xFFFF
  defp max_uint(4), do: 0xFFFFFFFF
  defp max_uint(8), do: 0xFFFFFFFFFFFFFFFF

  defp to_signed(n, bytes) do
    bits = bytes * 8
    max_pos = 1 <<< (bits - 1)
    mod = 1 <<< bits
    n = rem(n, mod)
    n = if n < 0, do: n + mod, else: n
    if n >= max_pos, do: n - mod, else: n
  end

  # ── Wrap buffer as Uint8Array-like object ──

  defp wrap_buffer(bytes) when is_binary(bytes) do
    uint8_ctor = get_uint8_ctor()
    buf_ctor = get_buf_ctor()
    buf_proto = if buf_ctor, do: Heap.get_class_proto(buf_ctor), else: nil

    case uint8_ctor do
      {:builtin, _, cb} ->
        # TypedArray constructor expects a list of integers, not a raw binary
        byte_list = :binary.bin_to_list(bytes)
        result = cb.([byte_list], nil)

        case result do
          {:obj, ref} ->
            Heap.update_obj(ref, %{}, fn m ->
              # Add buffer-specific methods directly on the instance
              # (overriding TypedArray's toString etc.)
              buffer_methods = build_instance_methods(ref)
              base = Map.merge(m, buffer_methods)
              base = Map.put(base, "__is_buffer__", true)
              base = if buf_proto, do: Map.put(base, "__proto__", buf_proto), else: base
              if buf_ctor, do: Map.put(base, "constructor", buf_ctor), else: base
            end)
            result
          _ -> result
        end

      _ ->
        Heap.wrap(%{"__buffer__" => bytes, "byteLength" => byte_size(bytes), "__is_buffer__" => true})
    end
  end

  defp build_instance_methods(ref) do
    this = {:obj, ref}
    %{
      "toString" => {:builtin, "toString", fn args, _ -> buf_to_string(this, args) end},
      "write" => {:builtin, "write", fn args, _ -> buf_write(this, args) end},
      "slice" => {:builtin, "slice", fn args, _ -> buf_slice(this, args) end},
      "subarray" => {:builtin, "subarray", fn args, _ -> buf_slice(this, args) end},
      "copy" => {:builtin, "copy", fn args, _ -> buf_copy(this, args) end},
      "compare" => {:builtin, "compare", fn args, _ -> buf_compare_instance(this, args) end},
      "equals" => {:builtin, "equals", fn args, _ -> buf_equals(this, args) end},
      "indexOf" => {:builtin, "indexOf", fn args, _ -> buf_index_of(this, args) end},
      "lastIndexOf" => {:builtin, "lastIndexOf", fn args, _ -> buf_last_index_of(this, args) end},
      "includes" => {:builtin, "includes", fn args, _ -> buf_includes(this, args) end},
      "fill" => {:builtin, "fill", fn args, _ -> buf_fill(this, args); this end},
      "toJSON" => {:builtin, "toJSON", fn _, _ -> buf_to_json(this) end},
      "swap16" => {:builtin, "swap16", fn _, _ -> buf_swap16(this) end},
      "swap32" => {:builtin, "swap32", fn _, _ -> buf_swap32(this) end},
      "swap64" => {:builtin, "swap64", fn _, _ -> buf_swap64(this) end},
      "readUInt8" => {:builtin, "readUInt8", fn args, _ -> buf_read_uint(this, args, 1, :unsigned, :big) end},
      "readUInt16BE" => {:builtin, "readUInt16BE", fn args, _ -> buf_read_uint(this, args, 2, :unsigned, :big) end},
      "readUInt16LE" => {:builtin, "readUInt16LE", fn args, _ -> buf_read_uint(this, args, 2, :unsigned, :little) end},
      "readUInt32BE" => {:builtin, "readUInt32BE", fn args, _ -> buf_read_uint(this, args, 4, :unsigned, :big) end},
      "readUInt32LE" => {:builtin, "readUInt32LE", fn args, _ -> buf_read_uint(this, args, 4, :unsigned, :little) end},
      "readInt8" => {:builtin, "readInt8", fn args, _ -> buf_read_uint(this, args, 1, :signed, :big) end},
      "readInt16BE" => {:builtin, "readInt16BE", fn args, _ -> buf_read_uint(this, args, 2, :signed, :big) end},
      "readInt16LE" => {:builtin, "readInt16LE", fn args, _ -> buf_read_uint(this, args, 2, :signed, :little) end},
      "readInt32BE" => {:builtin, "readInt32BE", fn args, _ -> buf_read_uint(this, args, 4, :signed, :big) end},
      "readInt32LE" => {:builtin, "readInt32LE", fn args, _ -> buf_read_uint(this, args, 4, :signed, :little) end},
      "readFloatBE" => {:builtin, "readFloatBE", fn args, _ -> buf_read_float(this, args, 4, :big) end},
      "readFloatLE" => {:builtin, "readFloatLE", fn args, _ -> buf_read_float(this, args, 4, :little) end},
      "readDoubleBE" => {:builtin, "readDoubleBE", fn args, _ -> buf_read_float(this, args, 8, :big) end},
      "readDoubleLE" => {:builtin, "readDoubleLE", fn args, _ -> buf_read_float(this, args, 8, :little) end},
      "writeUInt8" => {:builtin, "writeUInt8", fn args, _ -> buf_write_uint(this, args, 1, :unsigned, :big) end},
      "writeUInt16BE" => {:builtin, "writeUInt16BE", fn args, _ -> buf_write_uint(this, args, 2, :unsigned, :big) end},
      "writeUInt16LE" => {:builtin, "writeUInt16LE", fn args, _ -> buf_write_uint(this, args, 2, :unsigned, :little) end},
      "writeUInt32BE" => {:builtin, "writeUInt32BE", fn args, _ -> buf_write_uint(this, args, 4, :unsigned, :big) end},
      "writeUInt32LE" => {:builtin, "writeUInt32LE", fn args, _ -> buf_write_uint(this, args, 4, :unsigned, :little) end},
      "writeInt8" => {:builtin, "writeInt8", fn args, _ -> buf_write_uint(this, args, 1, :signed, :big) end},
      "writeInt16BE" => {:builtin, "writeInt16BE", fn args, _ -> buf_write_uint(this, args, 2, :signed, :big) end},
      "writeInt16LE" => {:builtin, "writeInt16LE", fn args, _ -> buf_write_uint(this, args, 2, :signed, :little) end},
      "writeInt32BE" => {:builtin, "writeInt32BE", fn args, _ -> buf_write_uint(this, args, 4, :signed, :big) end},
      "writeInt32LE" => {:builtin, "writeInt32LE", fn args, _ -> buf_write_uint(this, args, 4, :signed, :little) end},
      "writeFloatBE" => {:builtin, "writeFloatBE", fn args, _ -> buf_write_float(this, args, 4, :big) end},
      "writeFloatLE" => {:builtin, "writeFloatLE", fn args, _ -> buf_write_float(this, args, 4, :little) end},
      "writeDoubleBE" => {:builtin, "writeDoubleBE", fn args, _ -> buf_write_float(this, args, 8, :big) end},
      "writeDoubleLE" => {:builtin, "writeDoubleLE", fn args, _ -> buf_write_float(this, args, 8, :little) end}
    }
  end

  defp get_uint8_ctor do
    case Heap.get_global_cache() do
      nil -> nil
      globals -> Map.get(globals, "Uint8Array")
    end
  end

  defp get_buf_ctor do
    case Heap.get_global_cache() do
      nil -> nil
      globals -> Map.get(globals, "Buffer")
    end
  end

  # ── Extract raw bytes from various sources ──

  def extract_buf_bytes({:obj, ref}) do
    case Heap.get_obj(ref, %{}) do
      m when is_map(m) ->
        cond do
          Map.has_key?(m, "__typed_array__") ->
            case Map.get(m, "buffer") do
              {:obj, buf_ref} ->
                case Heap.get_obj(buf_ref, %{}) do
                  bm when is_map(bm) ->
                    ab_buf = Map.get(bm, "__buffer__", <<>>)
                    offset = Map.get(m, "byteOffset", 0)
                    byte_len = Map.get(m, "byteLength", 0)
                    if byte_size(ab_buf) >= offset + byte_len and byte_len > 0 do
                      binary_part(ab_buf, offset, byte_len)
                    else
                      Map.get(m, "__buffer__", <<>>)
                    end
                  _ -> <<>>
                end
              _ -> Map.get(m, "__buffer__", <<>>)
            end
          Map.has_key?(m, "__buffer__") ->
            Map.get(m, "__buffer__", <<>>)
          true ->
            len = Map.get(m, "length", 0) |> to_int()
            Enum.map(0..(len - 1), fn i ->
              case Map.get(m, i) do
                n when is_integer(n) -> n
                n when is_float(n) -> trunc(n) |> band(0xFF)
                _ -> 0
              end
            end) |> :erlang.list_to_binary()
        end
      list when is_list(list) -> :erlang.list_to_binary(Enum.map(list, fn
        n when is_integer(n) -> band(n, 0xFF)
        n when is_float(n) -> band(trunc(n), 0xFF)
        _ -> 0
      end))
      _ -> <<>>
    end
  end

  def extract_buf_bytes(b) when is_binary(b), do: b
  def extract_buf_bytes({:bytes, b}) when is_binary(b), do: b
  def extract_buf_bytes(list) when is_list(list) do
    :erlang.list_to_binary(Enum.map(list, fn
      n when is_integer(n) -> band(n, 0xFF)
      _ -> 0
    end))
  end
  def extract_buf_bytes(_), do: <<>>

  defp get_obj_type({:obj, ref}) do
    case Heap.get_obj(ref, %{}) do
      {:qb_arr, _} -> :array_like

      m when is_map(m) ->
        cond do
          Map.has_key?(m, "__typed_array__") -> :typed_array
          Map.has_key?(m, "__buffer__") -> :array_buffer
          Map.get(m, "type") == "Buffer" and Map.has_key?(m, "data") -> :json_buffer
          true -> :array_like
        end

      _ -> :other
    end
  end

  defp extract_ab({:obj, ref}) do
    case Heap.get_obj(ref, %{}) do
      m when is_map(m) -> Map.get(m, "__buffer__", <<>>)
      _ -> <<>>
    end
  end

  defp extract_typed_bytes({:obj, ref}) do
    case Heap.get_obj(ref, %{}) do
      m when is_map(m) ->
        case Map.get(m, "buffer") do
          {:obj, buf_ref} ->
            case Heap.get_obj(buf_ref, %{}) do
              bm when is_map(bm) ->
                ab = Map.get(bm, "__buffer__", <<>>)
                offset = Map.get(m, "byteOffset", 0)
                byte_len = Map.get(m, "byteLength", 0)
                if byte_size(ab) >= offset + byte_len and byte_len > 0 do
                  binary_part(ab, offset, byte_len)
                else
                  <<>>
                end
              _ -> <<>>
            end
          _ ->
            len = Map.get(m, "length", 0) |> to_int()
            Enum.map(0..(len - 1), fn i ->
              case Map.get(m, i) do
                n when is_integer(n) -> n
                n when is_float(n) -> band(trunc(n), 0xFF)
                _ -> 0
              end
            end) |> :erlang.list_to_binary()
        end
      _ -> <<>>
    end
  end

  defp list_to_bytes({:obj, _} = arr) do
    items = Heap.to_list(arr)
    list_to_bytes_raw(items)
  end

  defp list_to_bytes(list) when is_list(list), do: list_to_bytes_raw(list)
  defp list_to_bytes(_), do: <<>>

  defp list_to_bytes_raw(list) do
    Enum.map(list, fn
      n when is_integer(n) -> band(n, 0xFF)
      n when is_float(n) -> band(trunc(n), 0xFF)
      _ -> 0
    end) |> :erlang.list_to_binary()
  end

  # ── Encoding helpers ──

  defp hex_decode(str) do
    # Remove invalid chars and ensure even length
    clean = str |> String.replace(~r/[^0-9a-fA-F]/, "") |> truncate_even()
    case Base.decode16(clean, case: :mixed) do
      {:ok, bytes} -> bytes
      _ -> <<>>
    end
  end

  defp truncate_even(str) do
    len = byte_size(str)
    if rem(len, 2) == 0, do: str, else: binary_part(str, 0, len - 1)
  end

  defp base64_decode(str) do
    # Strip whitespace
    clean = String.replace(str, ~r/[\s]/, "")
    padded = pad_base64(clean)
    case Base.decode64(padded) do
      {:ok, bytes} -> bytes
      _ -> <<>>
    end
  end

  defp base64url_decode(str) do
    clean = String.replace(str, ~r/[\s]/, "")
    case Base.url_decode64(clean, padding: false) do
      {:ok, bytes} -> bytes
      _ ->
        padded = pad_base64(String.replace(clean, "-", "+") |> String.replace("_", "/"))
        case Base.decode64(padded) do
          {:ok, bytes} -> bytes
          _ -> <<>>
        end
    end
  end

  defp pad_base64(str) do
    case rem(byte_size(str), 4) do
      0 -> str
      1 -> str <> "==="
      2 -> str <> "=="
      3 -> str <> "="
    end
  end

  defp latin1_to_bytes(str) do
    str
    |> String.to_charlist()
    |> Enum.map(fn cp -> band(cp, 0xFF) end)
    |> :erlang.list_to_binary()
  end

  defp ascii_bytes(str) do
    str
    |> String.to_charlist()
    |> Enum.map(fn cp -> band(cp, 0x7F) end)
    |> :erlang.list_to_binary()
  end

  defp utf16le_encode(str) do
    :unicode.characters_to_binary(str, :utf8, {:utf16, :little})
  end

  defp bytes_to_latin1(bytes) do
    bytes
    |> :binary.bin_to_list()
    |> Enum.map(fn byte ->
      if byte < 128, do: <<byte>>, else: <<byte::utf8>>
    end)
    |> IO.iodata_to_binary()
  end

  defp bytes_to_ascii(bytes) do
    bytes
    |> :binary.bin_to_list()
    |> Enum.map(fn byte -> <<band(byte, 0x7F)>> end)
    |> IO.iodata_to_binary()
  end

  defp base64_byte_length(str) do
    clean = String.replace(str, "=", "")
    len = byte_size(clean)
    div(len * 3, 4)
  end

  defp base64url_byte_length(str) do
    clean = String.replace(str, ~r/[=]/, "")
    len = byte_size(clean)
    div(len * 3, 4)
  end

  defp fill_with_string(n, pattern) do
    pat_bytes = pattern |> String.to_charlist() |> Enum.map(&band(&1, 0xFF))
    pat_len = length(pat_bytes)
    if pat_len == 0 do
      :binary.copy(<<0>>, n)
    else
      Enum.map(0..(n - 1), fn i -> Enum.at(pat_bytes, rem(i, pat_len)) end)
      |> :erlang.list_to_binary()
    end
  end

  defp compare_bytes(a, b) when a < b, do: -1
  defp compare_bytes(a, b) when a > b, do: 1
  defp compare_bytes(a, a), do: 0
  defp compare_bytes(a, b) when a == b, do: 0

  defp safe_slice(bytes, start_i, end_i) do
    total = byte_size(bytes)
    s = max(0, min(start_i, total))
    e = max(s, min(end_i, total))
    binary_part(bytes, s, e - s)
  end

  defp normalize_idx(v, total) when is_integer(v) do
    if v < 0, do: max(0, total + v), else: min(v, total)
  end
  defp normalize_idx(v, total) when is_float(v), do: normalize_idx(trunc(v), total)
  defp normalize_idx(:undefined, total), do: total
  defp normalize_idx(nil, total), do: total
  defp normalize_idx(_, _), do: 0

  defp get_buf_len(this) do
    case Get.get(this, "length") do
      n when is_integer(n) -> n
      n when is_float(n) -> trunc(n)
      _ -> 0
    end
  end

  defp get_encoding(list, skip) do
    case Enum.at(list, skip) do
      e when is_binary(e) -> String.downcase(e)
      _ -> "utf-8"
    end
  end

  defp to_int(n) when is_integer(n), do: n
  defp to_int(n) when is_float(n), do: trunc(n)
  defp to_int(:undefined), do: 0
  defp to_int(nil), do: 0
  defp to_int(_), do: 0

  defp to_number(n) when is_integer(n), do: n
  defp to_number(n) when is_float(n), do: n
  defp to_number(_), do: 0

  defp to_float(n) when is_float(n), do: n
  defp to_float(n) when is_integer(n), do: n * 1.0
  defp to_float(_), do: 0.0
end
