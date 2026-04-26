defmodule QuickBEAM.VM.Runtime.Web.Buffer do
  @moduledoc "Node.js Buffer class builtin for BEAM mode."

  @behaviour QuickBEAM.VM.Runtime.BindingProvider

  import Bitwise
  import QuickBEAM.VM.Builtin, only: [arg: 3, argv: 2, builtin_args: 2]

  alias QuickBEAM.VM.{Heap, JSThrow, Runtime}
  alias QuickBEAM.VM.ObjectModel.{Get, Put}
  alias QuickBEAM.VM.Runtime.Constructors
  alias QuickBEAM.VM.Runtime.Web.Buffer.{BinaryCodec, Encoding}

  @known_encodings ~w[utf8 utf-8 ascii latin1 binary base64 base64url hex ucs2 utf16le utf-16le ucs-2]

  @doc "Returns the JavaScript global bindings provided by this module."
  def bindings do
    ctor = build_buffer_ctor()
    %{"Buffer" => ctor}
  end

  defp build_buffer_ctor do
    ctor = {:builtin, "Buffer", &build_buffer_from/2}
    proto = build_buffer_proto(ctor)
    Constructors.put_prototype(ctor, proto)

    put_static_methods(ctor, %{
      "from" => &buffer_from/1,
      "alloc" => &buffer_alloc/1,
      "allocUnsafe" => &buffer_alloc_unsafe/1,
      "allocUnsafeSlow" => &buffer_alloc_unsafe/1,
      "concat" => &buffer_concat/1,
      "compare" => &buffer_compare/1,
      "isBuffer" => &buffer_is_buffer/1,
      "isEncoding" => &buffer_is_encoding/1,
      "byteLength" => &buffer_byte_length/1
    })

    ctor
  end

  defp put_static_methods(ctor, methods) do
    Enum.each(methods, fn {name, callback} ->
      Heap.put_ctor_static(ctor, name, builtin_args("Buffer." <> name, callback))
    end)
  end

  defp build_buffer_proto(ctor) do
    proto_ref = make_ref()

    proto_map =
      nil
      |> buffer_methods()
      |> Map.merge(%{"constructor" => ctor, "__is_buffer__" => true})
      |> put_if_present("__proto__", get_uint8_proto())

    Heap.put_obj(proto_ref, proto_map)
    {:obj, proto_ref}
  end

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  defp get_uint8_proto, do: Runtime.global_class_proto("Uint8Array")

  # Constructor call (new Buffer is deprecated but we still need to handle it)
  defp build_buffer_from(args, _this), do: buffer_from(args)

  # ── Buffer.from ──

  @doc "Creates a Buffer value from supported JavaScript input types."
  def buffer_from([src | rest]) do
    bytes =
      case src do
        b when is_binary(b) ->
          encoding = get_encoding(rest, 0)

          case encoding do
            "hex" ->
              Encoding.decode(b, "hex")

            "base64" ->
              Encoding.decode(b, "base64")

            "base64url" ->
              Encoding.decode(b, "base64url")

            "latin1" ->
              Encoding.decode(b, "latin1")

            "binary" ->
              Encoding.decode(b, "latin1")

            "ascii" ->
              Encoding.decode(b, "ascii")

            enc when enc in ["utf16le", "ucs2", "ucs-2", "utf-16le"] ->
              Encoding.decode(b, "utf16le")

            # utf8
            _ ->
              b
          end

        {:bytes, bin} when is_binary(bin) ->
          bin

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

        list when is_list(list) ->
          list_to_bytes_raw(list)

        _ ->
          <<>>
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

    bytes =
      case fill do
        0 ->
          :binary.copy(<<0>>, n)

        f when is_integer(f) ->
          byte_val = band(f, 0xFF)
          :binary.copy(<<byte_val>>, n)

        f when is_float(f) ->
          byte_val = band(trunc(f), 0xFF)
          :binary.copy(<<byte_val>>, n)

        f when is_binary(f) ->
          Encoding.fill(n, f)

        _ ->
          :binary.copy(<<0>>, n)
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
    total_limit =
      case rest do
        [n | _] when is_integer(n) -> n
        [n | _] when is_float(n) -> trunc(n)
        _ -> nil
      end

    items =
      case list do
        {:obj, _} -> Heap.to_list(list)
        l when is_list(l) -> l
        _ -> []
      end

    combined = for item <- items, into: <<>>, do: extract_buf_bytes(item)

    final =
      case total_limit do
        nil ->
          combined

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
    Encoding.compare(ba, bb)
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
      "base64" -> Encoding.byte_length(str, "base64")
      "base64url" -> Encoding.byte_length(str, "base64url")
      # 1 char = 1 byte (approx via UTF8 encoding)
      "latin1" -> byte_size(str) |> div(1)
      "binary" -> String.length(str)
      enc when enc in ["utf16le", "ucs2", "ucs-2", "utf-16le"] -> String.length(str) * 2
      # UTF-8
      _ -> byte_size(str)
    end
  end

  defp buffer_byte_length([{:obj, _} = arr | _]) do
    byte_size(extract_buf_bytes(arr))
  end

  defp buffer_byte_length(_), do: 0

  # ── Instance methods ──

  defp buf_to_string(this, args) do
    bytes = extract_buf_bytes(this)

    enc =
      case args do
        [e | _] when is_binary(e) -> String.downcase(e)
        _ -> "utf-8"
      end

    start_idx =
      case args do
        [_, s | _] when is_integer(s) -> max(0, s)
        [_, s | _] when is_float(s) -> max(0, trunc(s))
        _ -> 0
      end

    end_idx =
      case args do
        [_, _, e | _] when is_integer(e) -> min(e, byte_size(bytes))
        [_, _, e | _] when is_float(e) -> min(trunc(e), byte_size(bytes))
        _ -> byte_size(bytes)
      end

    slice =
      if start_idx < byte_size(bytes) and end_idx > start_idx do
        binary_part(bytes, start_idx, end_idx - start_idx)
      else
        <<>>
      end

    case enc do
      "hex" ->
        Base.encode16(slice, case: :lower)

      "base64" ->
        Base.encode64(slice)

      "base64url" ->
        Base.url_encode64(slice, padding: false)

      "latin1" ->
        Encoding.encode(slice, "latin1")

      "binary" ->
        Encoding.encode(slice, "latin1")

      "ascii" ->
        Encoding.encode(slice, "ascii")

      enc when enc in ["utf16le", "ucs2", "ucs-2", "utf-16le"] ->
        :unicode.characters_to_binary(slice, {:utf16, :little}, :utf8)

      # utf8 — already binary
      _ ->
        slice
    end
  end

  defp buf_write(this, args) do
    [str, offset_arg, max_len_arg, enc_arg] = argv(args, ["", 0, nil, "utf-8"])
    offset = to_int(offset_arg)
    buf_len = get_buf_len(this)

    _max_len =
      case max_len_arg do
        n when is_integer(n) -> n
        n when is_float(n) -> trunc(n)
        _ -> buf_len - offset
      end

    enc =
      case enc_arg do
        e when is_binary(e) -> String.downcase(e)
        _ -> "utf-8"
      end

    str_bin = if is_binary(str), do: str, else: to_string(str)

    write_bytes =
      case enc do
        "hex" -> Encoding.decode(str_bin, "hex")
        "base64" -> Encoding.decode(str_bin, "base64")
        "base64url" -> Encoding.decode(str_bin, "base64url")
        "latin1" -> Encoding.decode(str_bin, "latin1")
        "binary" -> Encoding.decode(str_bin, "latin1")
        "ascii" -> Encoding.decode(str_bin, "ascii")
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

    start_idx = args |> arg(0, 0) |> normalize_idx(total)
    end_idx = args |> arg(1, total) |> normalize_idx(total)

    len = max(0, end_idx - start_idx)

    sliced =
      if start_idx <= total and len > 0 do
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

    a_slice = Encoding.safe_slice(a_bytes, a_start, a_end)
    b_slice = Encoding.safe_slice(b_bytes, b_start, b_end)
    Encoding.compare(a_slice, b_slice)
  end

  defp buf_equals(this, [other | _]) do
    extract_buf_bytes(this) == extract_buf_bytes(other)
  end

  defp buf_index_of(this, [needle | rest]) do
    bytes = extract_buf_bytes(this)
    offset = to_int(Enum.at(rest, 0, 0))
    search_from = max(0, min(offset, byte_size(bytes)))
    haystack = binary_part(bytes, search_from, byte_size(bytes) - search_from)

    needle_bytes =
      case needle do
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

    needle_bytes =
      case needle do
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
    buf_len = get_buf_len(this)
    [fill_val, offset_arg, end_arg] = argv(args, [0, 0, buf_len])
    offset = to_int(offset_arg)
    end_pos = to_int(end_arg)

    fill_bytes =
      case fill_val do
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

    swapped = for <<a, b <- bytes>>, into: <<>>, do: <<b, a>>

    Enum.each(Enum.with_index(:binary.bin_to_list(swapped)), fn {byte, i} ->
      Put.put_element(this, i, byte)
    end)

    this
  end

  defp buf_swap32(this) do
    bytes = extract_buf_bytes(this)
    len = byte_size(bytes)
    if rem(len, 4) != 0, do: JSThrow.range_error!("Buffer size must be a multiple of 32-bits")

    swapped = for <<a, b, c, d <- bytes>>, into: <<>>, do: <<d, c, b, a>>

    Enum.each(Enum.with_index(:binary.bin_to_list(swapped)), fn {byte, i} ->
      Put.put_element(this, i, byte)
    end)

    this
  end

  defp buf_swap64(this) do
    bytes = extract_buf_bytes(this)
    len = byte_size(bytes)
    if rem(len, 8) != 0, do: JSThrow.range_error!("Buffer size must be a multiple of 64-bits")

    swapped =
      for <<a, b, c, d, e, f, g, h <- bytes>>, into: <<>>, do: <<h, g, f, e, d, c, b, a>>

    Enum.each(Enum.with_index(:binary.bin_to_list(swapped)), fn {byte, i} ->
      Put.put_element(this, i, byte)
    end)

    this
  end

  defp buf_read_uint(this, args, size, sign, endian) do
    offset = args |> arg(0, 0) |> to_int()
    bytes = extract_buf_bytes(this)

    if byte_size(bytes) < offset + size do
      JSThrow.range_error!("Attempt to access memory outside buffer bounds")
    end

    chunk = binary_part(bytes, offset, size)
    BinaryCodec.decode_int(chunk, size, sign, endian)
  end

  defp buf_read_float(this, args, size, endian) do
    offset = args |> arg(0, 0) |> to_int()
    bytes = extract_buf_bytes(this)

    if byte_size(bytes) < offset + size do
      JSThrow.range_error!("Attempt to access memory outside buffer bounds")
    end

    chunk = binary_part(bytes, offset, size)
    BinaryCodec.decode_float(chunk, size, endian)
  end

  defp buf_write_uint(this, args, size, sign, endian) do
    [val, offset_arg] = argv(args, [0, 0])
    offset = to_int(offset_arg)
    n = to_number(val)
    encoded = BinaryCodec.encode_int(n, size, sign, endian)

    Enum.each(0..(size - 1), fn i ->
      Put.put_element(this, offset + i, :binary.at(encoded, i))
    end)

    offset + size
  end

  defp buf_write_float(this, args, size, endian) do
    [val, offset_arg] = argv(args, [0, 0])
    offset = to_int(offset_arg)
    n = to_float(val)
    encoded = BinaryCodec.encode_float(n, size, endian)

    Enum.each(0..(size - 1), fn i ->
      Put.put_element(this, offset + i, :binary.at(encoded, i))
    end)

    offset + size
  end

  # ── Wrap buffer as Uint8Array-like object ──

  defp wrap_buffer(bytes) when is_binary(bytes) do
    uint8_ctor = get_uint8_ctor()
    buf_ctor = get_buf_ctor()
    buf_proto = Runtime.global_class_proto("Buffer")

    case uint8_ctor do
      {:builtin, _, cb} ->
        byte_list = :binary.bin_to_list(bytes)
        result = cb.([byte_list], nil)

        case result do
          {:obj, ref} ->
            Heap.update_obj(ref, %{}, fn m ->
              base = Map.merge(m, build_instance_methods(ref))
              base = Map.put(base, "__is_buffer__", true)
              base = if buf_proto, do: Map.put(base, "__proto__", buf_proto), else: base
              if buf_ctor, do: Map.put(base, "constructor", buf_ctor), else: base
            end)

            result

          _ ->
            result
        end

      _ ->
        Heap.wrap(%{
          "__buffer__" => bytes,
          "byteLength" => byte_size(bytes),
          "__is_buffer__" => true
        })
    end
  end

  defp build_instance_methods(ref), do: buffer_methods({:obj, ref})

  defp buffer_methods(bound_this) do
    %{}
    |> Map.merge(receiver_methods(bound_this))
    |> Map.merge(this_methods(bound_this))
    |> Map.merge(integer_read_methods(bound_this))
    |> Map.merge(float_read_methods(bound_this))
    |> Map.merge(integer_write_methods(bound_this))
    |> Map.merge(float_write_methods(bound_this))
  end

  defp receiver_methods(bound_this) do
    [
      {"toString", &buf_to_string/2},
      {"write", &buf_write/2},
      {"slice", &buf_slice/2},
      {"subarray", &buf_slice/2},
      {"copy", &buf_copy/2},
      {"compare", &buf_compare_instance/2},
      {"equals", &buf_equals/2},
      {"indexOf", &buf_index_of/2},
      {"lastIndexOf", &buf_last_index_of/2},
      {"includes", &buf_includes/2}
    ]
    |> Map.new(fn {name, callback} -> {name, receiver_builtin(name, callback, bound_this)} end)
    |> Map.put("fill", fill_builtin(bound_this))
  end

  defp this_methods(bound_this) do
    [
      {"toJSON", &buf_to_json/1},
      {"swap16", &buf_swap16/1},
      {"swap32", &buf_swap32/1},
      {"swap64", &buf_swap64/1}
    ]
    |> Map.new(fn {name, callback} -> {name, this_builtin(name, callback, bound_this)} end)
  end

  defp integer_read_methods(bound_this) do
    [
      {"readUInt8", 1, :unsigned, :big},
      {"readUInt16BE", 2, :unsigned, :big},
      {"readUInt16LE", 2, :unsigned, :little},
      {"readUInt32BE", 4, :unsigned, :big},
      {"readUInt32LE", 4, :unsigned, :little},
      {"readInt8", 1, :signed, :big},
      {"readInt16BE", 2, :signed, :big},
      {"readInt16LE", 2, :signed, :little},
      {"readInt32BE", 4, :signed, :big},
      {"readInt32LE", 4, :signed, :little},
      {"readBigUInt64BE", 8, :unsigned, :big},
      {"readBigUInt64LE", 8, :unsigned, :little},
      {"readBigInt64BE", 8, :signed, :big},
      {"readBigInt64LE", 8, :signed, :little}
    ]
    |> Map.new(fn {name, size, signed, endian} ->
      {name,
       receiver_builtin(
         name,
         fn this, args -> buf_read_uint(this, args, size, signed, endian) end,
         bound_this
       )}
    end)
  end

  defp float_read_methods(bound_this) do
    [
      {"readFloatBE", 4, :big},
      {"readFloatLE", 4, :little},
      {"readDoubleBE", 8, :big},
      {"readDoubleLE", 8, :little}
    ]
    |> Map.new(fn {name, size, endian} ->
      {name,
       receiver_builtin(
         name,
         fn this, args -> buf_read_float(this, args, size, endian) end,
         bound_this
       )}
    end)
  end

  defp integer_write_methods(bound_this) do
    [
      {"writeUInt8", 1, :unsigned, :big},
      {"writeUInt16BE", 2, :unsigned, :big},
      {"writeUInt16LE", 2, :unsigned, :little},
      {"writeUInt32BE", 4, :unsigned, :big},
      {"writeUInt32LE", 4, :unsigned, :little},
      {"writeInt8", 1, :signed, :big},
      {"writeInt16BE", 2, :signed, :big},
      {"writeInt16LE", 2, :signed, :little},
      {"writeInt32BE", 4, :signed, :big},
      {"writeInt32LE", 4, :signed, :little}
    ]
    |> Map.new(fn {name, size, signed, endian} ->
      {name,
       receiver_builtin(
         name,
         fn this, args -> buf_write_uint(this, args, size, signed, endian) end,
         bound_this
       )}
    end)
  end

  defp float_write_methods(bound_this) do
    [
      {"writeFloatBE", 4, :big},
      {"writeFloatLE", 4, :little},
      {"writeDoubleBE", 8, :big},
      {"writeDoubleLE", 8, :little}
    ]
    |> Map.new(fn {name, size, endian} ->
      {name,
       receiver_builtin(
         name,
         fn this, args -> buf_write_float(this, args, size, endian) end,
         bound_this
       )}
    end)
  end

  defp receiver_builtin(name, callback, bound_this) do
    {:builtin, name, fn args, this -> callback.(bound_this || this, args) end}
  end

  defp this_builtin(name, callback, bound_this) do
    {:builtin, name, fn _args, this -> callback.(bound_this || this) end}
  end

  defp fill_builtin(bound_this) do
    {:builtin, "fill",
     fn args, this ->
       this = bound_this || this
       buf_fill(this, args)
       this
     end}
  end

  defp get_uint8_ctor, do: Runtime.global_constructor("Uint8Array")

  defp get_buf_ctor, do: Runtime.global_constructor("Buffer")

  # ── Extract raw bytes from various sources ──

  @doc "Extracts raw bytes from a Buffer-like VM value."
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

                  _ ->
                    <<>>
                end

              _ ->
                Map.get(m, "__buffer__", <<>>)
            end

          Map.has_key?(m, "__buffer__") ->
            Map.get(m, "__buffer__", <<>>)

          true ->
            len = Map.get(m, "length", 0) |> to_int()

            array_like_to_bytes(m, len)
        end

      list when is_list(list) ->
        list_to_bytes_raw(list)

      _ ->
        <<>>
    end
  end

  def extract_buf_bytes(b) when is_binary(b), do: b
  def extract_buf_bytes({:bytes, b}) when is_binary(b), do: b

  def extract_buf_bytes(list) when is_list(list), do: list_to_bytes_raw(list)

  def extract_buf_bytes(_), do: <<>>

  defp get_obj_type({:obj, ref}) do
    case Heap.get_obj(ref, %{}) do
      {:qb_arr, _} ->
        :array_like

      m when is_map(m) ->
        cond do
          Map.has_key?(m, "__typed_array__") -> :typed_array
          Map.has_key?(m, "__buffer__") -> :array_buffer
          Map.get(m, "type") == "Buffer" and Map.has_key?(m, "data") -> :json_buffer
          true -> :array_like
        end

      _ ->
        :other
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

              _ ->
                <<>>
            end

          _ ->
            len = Map.get(m, "length", 0) |> to_int()

            array_like_to_bytes(m, len)
        end

      _ ->
        <<>>
    end
  end

  defp list_to_bytes({:obj, _} = arr) do
    items = Heap.to_list(arr)
    list_to_bytes_raw(items)
  end

  defp list_to_bytes(list) when is_list(list), do: list_to_bytes_raw(list)
  defp list_to_bytes(_), do: <<>>

  defp list_to_bytes_raw(list) do
    for value <- list, into: <<>>, do: <<byte_value(value)>>
  end

  defp array_like_to_bytes(_map, len) when len <= 0, do: <<>>

  defp array_like_to_bytes(map, len) do
    for index <- 0..(len - 1), into: <<>>, do: <<byte_value(Map.get(map, index))>>
  end

  defp byte_value(n) when is_integer(n), do: band(n, 0xFF)
  defp byte_value(n) when is_float(n), do: band(trunc(n), 0xFF)
  defp byte_value(_), do: 0

  # ── Encoding helpers ──

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
