defmodule QuickBEAM.VM.Runtime.Web.TextEncoding do
  @moduledoc "TextEncoder and TextDecoder builtins for BEAM mode."

  import Bitwise
  import QuickBEAM.VM.Builtin, only: [arg: 3, argv: 2, object: 1]

  alias QuickBEAM.VM.{Heap, JSThrow, Runtime}
  alias QuickBEAM.VM.ObjectModel.{Get, Put}
  alias QuickBEAM.VM.Runtime.WebAPIs

  @supported_encodings ~w[utf-8 utf8 unicode-1-1-utf-8]

  def bindings do
    %{
      "TextEncoder" => WebAPIs.register("TextEncoder", &build_text_encoder/2),
      "TextDecoder" => WebAPIs.register("TextDecoder", &build_text_decoder/2)
    }
  end

  defp build_text_encoder(_args, _this) do
    object do
      prop("encoding", "utf-8")

      method "encode" do
        str =
          case arg(args, 0, "") do
            value when is_binary(value) -> value
            _ -> ""
          end

        bytes = encode_wtf8(str)
        make_uint8array(bytes)
      end

      method "encodeInto" do
        [source, dest] = argv(args, ["", nil])
        str = if is_binary(source), do: source, else: ""
        encode_into(str, dest)
      end
    end
  end

  defp build_text_decoder(args, _this) do
    label =
      case arg(args, 0, nil) do
        label when is_binary(label) -> String.downcase(label)
        _ -> "utf-8"
      end

    label = normalize_encoding_label(label)

    unless label in @supported_encodings do
      JSThrow.range_error!(
        "The encoding label provided ('#{arg(args, 0, :undefined)}') is invalid."
      )
    end

    fatal =
      case Get.get(arg(args, 1, nil), "fatal") do
        true -> true
        _ -> false
      end

    object do
      prop("encoding", "utf-8")
      prop("fatal", fatal)

      method "decode" do
        bytes = extract_bytes(args)

        if fatal do
          strict_decode_utf8!(bytes)
        else
          lenient_decode_utf8(bytes)
        end
      end
    end
  end

  # ── UTF-8 encoding with WTF-8 handling for surrogates ──

  defp encode_wtf8(str) do
    str
    |> decode_js_codepoints()
    |> Enum.flat_map(&codepoint_to_utf8_bytes/1)
  end

  defp decode_js_codepoints(str) do
    decode_js_codepoints_acc(str, [])
  end

  defp decode_js_codepoints_acc(<<>>, acc), do: Enum.reverse(acc)

  # WTF-8 surrogate sequence: 0xED followed by continuation bytes in surrogate range
  # These are lone surrogates stored as WTF-8 — replace with U+FFFD
  defp decode_js_codepoints_acc(<<0xED, b2, b3, rest::binary>>, acc)
       when b2 in 0xA0..0xBF and b3 in 0x80..0xBF do
    decode_js_codepoints_acc(rest, [0xFFFD | acc])
  end

  defp decode_js_codepoints_acc(<<cp::utf8, rest::binary>>, acc) do
    decode_js_codepoints_acc(rest, [cp | acc])
  end

  # Invalid UTF-8 byte - treat as replacement
  defp decode_js_codepoints_acc(<<_byte, rest::binary>>, acc) do
    decode_js_codepoints_acc(rest, [0xFFFD | acc])
  end

  # WTF-8 encoding: encode each codepoint to UTF-8 bytes, lone surrogates → FFFD bytes
  defp codepoint_to_utf8_bytes(cp) when cp <= 0x7F, do: [cp]

  defp codepoint_to_utf8_bytes(cp) when cp <= 0x7FF,
    do: [0xC0 ||| cp >>> 6, 0x80 ||| (cp &&& 0x3F)]

  defp codepoint_to_utf8_bytes(cp) when cp in 0xD800..0xDFFF do
    # Lone surrogate → U+FFFD
    [0xEF, 0xBF, 0xBD]
  end

  defp codepoint_to_utf8_bytes(cp) when cp <= 0xFFFF do
    [0xE0 ||| cp >>> 12, 0x80 ||| (cp >>> 6 &&& 0x3F), 0x80 ||| (cp &&& 0x3F)]
  end

  defp codepoint_to_utf8_bytes(cp) when cp <= 0x10FFFF do
    [
      0xF0 ||| cp >>> 18,
      0x80 ||| (cp >>> 12 &&& 0x3F),
      0x80 ||| (cp >>> 6 &&& 0x3F),
      0x80 ||| (cp &&& 0x3F)
    ]
  end

  defp codepoint_to_utf8_bytes(_), do: [0xEF, 0xBF, 0xBD]

  # ── encodeInto ──

  defp encode_into(str, dest) do
    codepoints = decode_js_codepoints(str)
    dest_len = get_typed_array_len(dest)
    {read, written, bytes} = encode_into_loop(codepoints, dest_len, 0, 0, [])

    bytes_list = Enum.reverse(bytes)

    Enum.with_index(bytes_list)
    |> Enum.each(fn {byte, i} -> Put.put_element(dest, i, byte) end)

    Heap.wrap(%{"read" => read, "written" => written})
  end

  defp encode_into_loop([], _dest_len, read, written, acc) do
    {read, written, acc}
  end

  defp encode_into_loop([cp | rest], dest_len, read, written, acc) do
    bytes = codepoint_to_utf8_bytes(cp)
    byte_len = length(bytes)

    if written + byte_len > dest_len do
      {read, written, acc}
    else
      # For surrogate pairs from the original JS string: the high surrogate produces
      # 3 FFFD bytes but counts as 1 JS char (read += 1), low surrogate same.
      # For supplementary codepoints (already merged): 4 bytes, read += 2.
      chars_consumed = if cp > 0xFFFF, do: 2, else: 1

      encode_into_loop(
        rest,
        dest_len,
        read + chars_consumed,
        written + byte_len,
        Enum.reverse(bytes) ++ acc
      )
    end
  end

  defp get_typed_array_len(arr) do
    case arr do
      {:obj, ref} ->
        case Heap.get_obj(ref, %{}) do
          m when is_map(m) -> Map.get(m, "length", 0) |> trunc_int()
          _ -> 0
        end

      _ ->
        0
    end
  end

  defp trunc_int(n) when is_integer(n), do: n
  defp trunc_int(n) when is_float(n), do: trunc(n)
  defp trunc_int(_), do: 0

  # ── UTF-8 decoding ──

  defp extract_bytes(args) do
    case args do
      [] -> <<>>
      [:undefined | _] -> <<>>
      [nil | _] -> <<>>
      [arr | _] -> typed_array_to_binary(arr)
    end
  end

  defp typed_array_to_binary({:obj, ref}) do
    case Heap.get_obj(ref, %{}) do
      map when is_map(map) ->
        cond do
          # ArrayBuffer
          Map.has_key?(map, "__buffer__") and not Map.has_key?(map, "__typed_array__") ->
            Map.get(map, "__buffer__", <<>>)

          # TypedArray
          Map.has_key?(map, "__typed_array__") ->
            case Map.get(map, "buffer") do
              {:obj, buf_ref} ->
                case Heap.get_obj(buf_ref, %{}) do
                  m when is_map(m) ->
                    ab_buf = Map.get(m, "__buffer__", <<>>)
                    offset = Map.get(map, "byteOffset", 0)
                    byte_len = Map.get(map, "byteLength", 0)

                    if byte_size(ab_buf) >= offset + byte_len and byte_len > 0 do
                      binary_part(ab_buf, offset, byte_len)
                    else
                      Map.get(map, "__buffer__", <<>>)
                    end

                  _ ->
                    Map.get(map, "__buffer__", <<>>)
                end

              _ ->
                Map.get(map, "__buffer__", <<>>)
            end

          true ->
            <<>>
        end

      _ ->
        <<>>
    end
  end

  defp typed_array_to_binary(list) when is_list(list) do
    :erlang.list_to_binary(list)
  end

  defp typed_array_to_binary(_), do: <<>>

  # Lenient UTF-8 decode: invalid sequences → U+FFFD
  # Also strips leading UTF-8 BOM (EF BB BF)
  defp lenient_decode_utf8(<<0xEF, 0xBB, 0xBF, rest::binary>>) do
    lenient_decode_utf8_acc(rest, [])
  end

  defp lenient_decode_utf8(bytes) do
    lenient_decode_utf8_acc(bytes, [])
  end

  defp lenient_decode_utf8_acc(<<>>, acc) do
    acc
    |> Enum.reverse()
    |> :unicode.characters_to_binary(:unicode)
  end

  defp lenient_decode_utf8_acc(<<0xED, b2, b3, rest::binary>>, acc)
       when b2 >= 0xA0 and b2 <= 0xBF and b3 >= 0x80 and b3 <= 0xBF do
    # Encoded surrogate (0xED 0xAx/0xBx ...) → U+FFFD
    lenient_decode_utf8_acc(rest, [0xFFFD | acc])
  end

  defp lenient_decode_utf8_acc(<<cp::utf8, rest::binary>>, acc) do
    lenient_decode_utf8_acc(rest, [cp | acc])
  end

  defp lenient_decode_utf8_acc(<<_byte, rest::binary>>, acc) do
    lenient_decode_utf8_acc(rest, [0xFFFD | acc])
  end

  # Strict UTF-8 decode: throw TypeError on any invalid byte sequence
  defp strict_decode_utf8!(bytes) do
    case strict_decode_utf8_acc(bytes, []) do
      {:ok, result} -> result
      :error -> JSThrow.type_error!("The encoded data was not valid for encoding utf-8")
    end
  end

  defp strict_decode_utf8_acc(<<>>, acc) do
    result =
      acc
      |> Enum.reverse()
      |> :unicode.characters_to_binary(:unicode)

    {:ok, result}
  end

  # Reject encoded surrogates (U+D800..U+DFFF) in strict mode
  defp strict_decode_utf8_acc(<<0xED, b2, _b3, _rest::binary>>, _acc)
       when b2 >= 0xA0 and b2 <= 0xBF do
    :error
  end

  # Reject overlong encodings
  # C0/C1 start bytes are always overlong
  defp strict_decode_utf8_acc(<<b, _rest::binary>>, _acc) when b in [0xC0, 0xC1] do
    :error
  end

  # E0 followed by continuation byte < 0xA0 is overlong
  defp strict_decode_utf8_acc(<<0xE0, b2, _rest::binary>>, _acc) when b2 < 0xA0 do
    :error
  end

  # F0 followed by continuation byte < 0x90 is overlong
  defp strict_decode_utf8_acc(<<0xF0, b2, _rest::binary>>, _acc) when b2 < 0x90 do
    :error
  end

  defp strict_decode_utf8_acc(<<cp::utf8, rest::binary>>, acc) do
    strict_decode_utf8_acc(rest, [cp | acc])
  end

  defp strict_decode_utf8_acc(_invalid, _acc), do: :error

  # ── Helpers ──

  defp normalize_encoding_label("utf-8"), do: "utf-8"
  defp normalize_encoding_label("utf8"), do: "utf-8"
  defp normalize_encoding_label("unicode-1-1-utf-8"), do: "utf-8"
  defp normalize_encoding_label(other), do: other

  defp make_uint8array(bytes) do
    case Runtime.global_bindings()["Uint8Array"] do
      {:builtin, _, cb} = ctor when is_function(cb, 2) ->
        result = cb.([bytes], nil)

        case result do
          {:obj, ref} ->
            class_proto = Heap.get_class_proto(ctor)

            if class_proto do
              map = Heap.get_obj(ref, %{})

              if is_map(map) and not Map.has_key?(map, "__proto__") do
                Heap.put_obj(ref, Map.put(map, "__proto__", class_proto))
              end
            end

            result

          _ ->
            result
        end

      _ ->
        Heap.wrap(bytes)
    end
  end
end
