defmodule QuickBEAM.VM.Runtime.DataView do
  @moduledoc "DataView constructor, prototype accessors, and scalar reads/writes."

  use QuickBEAM.VM.Builtin

  import Bitwise
  import QuickBEAM.VM.Heap.Keys, only: [buffer: 0, typed_array: 0]

  alias QuickBEAM.VM.{Heap, JSThrow, Runtime}
  alias QuickBEAM.VM.Semantics.Values
  alias QuickBEAM.VM.Semantics.Coercion

  @slot "__data_view__"
  defintrinsic "DataView" do
    constructor(&__MODULE__.constructor/2,
      length: 1,
      phase: :fundamental
    )

    prototype extends: :object do
      @ecma "25.3.4.1"
      getter "buffer" do
        view_field!(this, "buffer")
      end

      @ecma "25.3.4.2"
      getter "byteLength" do
        view_field!(this, "byteLength")
      end

      @ecma "25.3.4.3"
      getter "byteOffset" do
        view_field!(this, "byteOffset")
      end

      to_string_tag("DataView")
    end
  end

  def prevalidate_construct_args!([{:obj, buffer_ref}, offset | rest])
      when is_integer(offset) or is_float(offset) do
    buffer_map = Heap.get_obj(buffer_ref, %{})

    if is_map(buffer_map) and is_map_key(buffer_map, buffer()) and
         not is_map_key(buffer_map, typed_array()) do
      buffer_len = byte_size(Map.get(buffer_map, buffer(), <<>>))
      integer_offset = trunc(offset)

      view_len =
        if rest == [],
          do: buffer_len - integer_offset,
          else: data_view_length([nil, nil | rest], buffer_len, integer_offset)

      cond do
        integer_offset < 0 ->
          JSThrow.range_error!("DataView byteOffset out of range")

        integer_offset > buffer_len ->
          JSThrow.range_error!("DataView byteOffset out of range")

        integer_offset + view_len > buffer_len ->
          JSThrow.range_error!("DataView byteLength out of range")

        true ->
          :ok
      end
    end
  end

  def prevalidate_construct_args!(_), do: :ok

  def constructor(args, this \\ nil) do
    buffer_obj = List.first(args) || :undefined
    buffer_ref = require_array_buffer!(buffer_obj)
    buffer_map = Heap.get_obj(buffer_ref, %{})

    buffer_len = byte_size(Map.get(buffer_map, buffer(), <<>>))
    offset = to_index(args |> Enum.at(1, 0))
    length_tracking? = length(args) < 3 or Enum.at(args, 2) == :undefined
    view_len = data_view_length(args, buffer_len, offset)

    if Map.get(buffer_map, "__detached__") do
      JSThrow.type_error!("ArrayBuffer is detached")
    end

    cond do
      offset > buffer_len -> JSThrow.range_error!("DataView byteOffset out of range")
      view_len < 0 -> JSThrow.range_error!("DataView byteLength out of range")
      offset + view_len > buffer_len -> JSThrow.range_error!("DataView byteLength out of range")
      true -> :ok
    end

    obj = if match?({:obj, _}, this), do: this, else: Runtime.new_object()
    {:obj, ref} = obj

    Heap.put_obj(
      ref,
      Map.merge(Heap.get_obj(ref, %{}), %{
        @slot => true,
        "__viewed_buffer__" => buffer_obj,
        "__byteOffset__" => offset,
        "__byteLength__" => view_len,
        "__length_tracking__" => length_tracking?
      })
    )

    obj
  end

  @ecma "25.3.4.10"
  proto "getInt8", length: 1 do
    read(this, args, :int8)
  end

  @ecma "25.3.4.13"
  proto "getUint8", length: 1 do
    read(this, args, :uint8)
  end

  @ecma "25.3.4.11"
  proto "getInt16", length: 1 do
    read(this, args, :int16)
  end

  @ecma "25.3.4.14"
  proto "getUint16", length: 1 do
    read(this, args, :uint16)
  end

  @ecma "25.3.4.12"
  proto "getInt32", length: 1 do
    read(this, args, :int32)
  end

  @ecma "25.3.4.15"
  proto "getUint32", length: 1 do
    read(this, args, :uint32)
  end

  @ecma "25.3.4.7"
  proto "getFloat16", length: 1 do
    read(this, args, :float16)
  end

  @ecma "25.3.4.8"
  proto "getFloat32", length: 1 do
    read(this, args, :float32)
  end

  @ecma "25.3.4.9"
  proto "getFloat64", length: 1 do
    read(this, args, :float64)
  end

  @ecma "25.3.4.5"
  proto "getBigInt64", length: 1 do
    read(this, args, :bigint64)
  end

  @ecma "25.3.4.6"
  proto "getBigUint64", length: 1 do
    read(this, args, :biguint64)
  end

  @ecma "25.3.4.21"
  proto "setInt8", length: 2 do
    write(this, args, :int8)
  end

  @ecma "25.3.4.24"
  proto "setUint8", length: 2 do
    write(this, args, :uint8)
  end

  @ecma "25.3.4.22"
  proto "setInt16", length: 2 do
    write(this, args, :int16)
  end

  @ecma "25.3.4.25"
  proto "setUint16", length: 2 do
    write(this, args, :uint16)
  end

  @ecma "25.3.4.23"
  proto "setInt32", length: 2 do
    write(this, args, :int32)
  end

  @ecma "25.3.4.26"
  proto "setUint32", length: 2 do
    write(this, args, :uint32)
  end

  @ecma "25.3.4.18"
  proto "setFloat16", length: 2 do
    write(this, args, :float16)
  end

  @ecma "25.3.4.19"
  proto "setFloat32", length: 2 do
    write(this, args, :float32)
  end

  @ecma "25.3.4.20"
  proto "setFloat64", length: 2 do
    write(this, args, :float64)
  end

  @ecma "25.3.4.16"
  proto "setBigInt64", length: 2 do
    write(this, args, :bigint64)
  end

  @ecma "25.3.4.17"
  proto "setBigUint64", length: 2 do
    write(this, args, :biguint64)
  end

  defp read(this, args, type) do
    view = require_view!(this)
    offset = to_index(List.first(args) || 0)
    little? = Runtime.truthy?(Enum.at(args, 1, false))
    {buf, byte_offset, byte_length} = view_buffer_state!(view)
    size = elem_size(type)

    if offset + size > byte_length do
      JSThrow.range_error!("DataView offset out of range")
    end

    read_scalar(buf, byte_offset + offset, type, little?)
  end

  defp write(this, args, type) do
    view = require_view!(this)
    assert_view_buffer_mutable!(view)
    offset = to_index(List.first(args) || 0)
    value = convert_write_value(Enum.at(args, 1, :undefined), type)
    little? = Runtime.truthy?(Enum.at(args, 2, false))
    {buf, byte_offset, byte_length, buffer_ref} = view_buffer_state_for_write!(view)
    size = elem_size(type)

    if offset + size > byte_length do
      JSThrow.range_error!("DataView offset out of range")
    end

    new_buf = write_scalar(buf, byte_offset + offset, value, type, little?)
    update_buffer(buffer_ref, new_buf)
    :undefined
  end

  defp require_array_buffer!({:obj, ref}) do
    case Heap.get_obj(ref, %{}) do
      map when is_map(map) and is_map_key(map, buffer()) and not is_map_key(map, typed_array()) ->
        ref

      _ ->
        JSThrow.type_error!("DataView buffer must be an ArrayBuffer")
    end
  end

  defp require_array_buffer!(_), do: JSThrow.type_error!("DataView buffer must be an ArrayBuffer")

  defp data_view_length(args, buffer_len, offset) do
    case Enum.fetch(args, 2) do
      {:ok, :undefined} -> buffer_len - offset
      {:ok, value} -> to_index(value)
      :error -> buffer_len - offset
    end
  end

  defp to_index({:bigint, _}),
    do: JSThrow.type_error!("Cannot convert a BigInt value to a number")

  defp to_index(value) do
    case Runtime.to_number(value) do
      :infinity ->
        JSThrow.range_error!("DataView index out of range")

      :neg_infinity ->
        JSThrow.range_error!("DataView index out of range")

      :nan ->
        0

      number when is_number(number) ->
        index = trunc(number)
        if index < 0, do: JSThrow.range_error!("DataView index out of range"), else: index
    end
  end

  defp view_field!({:obj, ref}, field) do
    case Heap.get_obj(ref, %{}) do
      %{@slot => true} = view ->
        if field in ["byteLength", "byteOffset"] do
          assert_view_buffer_attached!(view)
        end

        case field do
          "buffer" -> Map.get(view, "__viewed_buffer__")
          "byteLength" -> current_byte_length(view)
          "byteOffset" -> Map.get(view, "__byteOffset__")
        end

      _ ->
        JSThrow.type_error!("DataView method called on incompatible receiver")
    end
  end

  defp view_field!(_, _field),
    do: JSThrow.type_error!("DataView method called on incompatible receiver")

  defp require_view!({:obj, ref}) do
    case Heap.get_obj(ref, %{}) do
      %{@slot => true} = view -> view
      _ -> JSThrow.type_error!("DataView method called on incompatible receiver")
    end
  end

  defp require_view!(_),
    do: JSThrow.type_error!("DataView method called on incompatible receiver")

  defp view_buffer_state!(%{"__viewed_buffer__" => {:obj, buffer_ref}} = view) do
    case Heap.get_obj(buffer_ref, %{}) do
      %{"__detached__" => true} ->
        JSThrow.type_error!("ArrayBuffer is detached")

      map when is_map(map) ->
        {Map.get(map, buffer(), <<>>), Map.get(view, "__byteOffset__", 0),
         current_byte_length(view)}
    end
  end

  defp view_buffer_state_for_write!(%{"__viewed_buffer__" => {:obj, buffer_ref}} = view) do
    case Heap.get_obj(buffer_ref, %{}) do
      %{"__detached__" => true} ->
        JSThrow.type_error!("ArrayBuffer is detached")

      map when is_map(map) ->
        {Map.get(map, buffer(), <<>>), Map.get(view, "__byteOffset__", 0),
         current_byte_length(view), buffer_ref}
    end
  end

  defp current_byte_length(
         %{"__length_tracking__" => true, "__viewed_buffer__" => {:obj, buffer_ref}} = view
       ) do
    case Heap.get_obj(buffer_ref, %{}) do
      map when is_map(map) ->
        max(byte_size(Map.get(map, buffer(), <<>>)) - Map.get(view, "__byteOffset__", 0), 0)

      _ ->
        0
    end
  end

  defp current_byte_length(view), do: Map.get(view, "__byteLength__", 0)

  defp assert_view_buffer_attached!(%{"__viewed_buffer__" => {:obj, buffer_ref}}) do
    case Heap.get_obj(buffer_ref, %{}) do
      %{"__detached__" => true} -> JSThrow.type_error!("ArrayBuffer is detached")
      _ -> :ok
    end
  end

  defp assert_view_buffer_attached!(_), do: :ok

  defp assert_view_buffer_mutable!(%{"__viewed_buffer__" => {:obj, buffer_ref}}) do
    case Heap.get_obj(buffer_ref, %{}) do
      %{"__immutable__" => true} -> JSThrow.type_error!("ArrayBuffer is immutable")
      _ -> :ok
    end
  end

  defp assert_view_buffer_mutable!(_), do: :ok

  defp update_buffer(buffer_ref, new_buf) do
    Heap.update_obj(buffer_ref, %{}, fn map -> Map.put(map, buffer(), new_buf) end)
  end

  defp elem_size(:int8), do: 1
  defp elem_size(:uint8), do: 1
  defp elem_size(:int16), do: 2
  defp elem_size(:uint16), do: 2
  defp elem_size(:float16), do: 2
  defp elem_size(:int32), do: 4
  defp elem_size(:uint32), do: 4
  defp elem_size(:float32), do: 4
  defp elem_size(:float64), do: 8
  defp elem_size(:bigint64), do: 8
  defp elem_size(:biguint64), do: 8

  defp read_scalar(buf, pos, :int8, _), do: signed(:binary.at(buf, pos), 8)
  defp read_scalar(buf, pos, :uint8, _), do: :binary.at(buf, pos)
  defp read_scalar(buf, pos, :int16, little?), do: signed(read_uint(buf, pos, 2, little?), 16)
  defp read_scalar(buf, pos, :uint16, little?), do: read_uint(buf, pos, 2, little?)
  defp read_scalar(buf, pos, :int32, little?), do: signed(read_uint(buf, pos, 4, little?), 32)
  defp read_scalar(buf, pos, :uint32, little?), do: read_uint(buf, pos, 4, little?)

  defp read_scalar(buf, pos, :float16, little?),
    do: decode_float16(read_uint(buf, pos, 2, little?))

  defp read_scalar(buf, pos, :float32, little?) do
    bytes = part_endian(buf, pos, 4, little?)
    bits = :binary.decode_unsigned(bytes, :big)

    cond do
      bits == 0x7F800000 ->
        :infinity

      bits == 0xFF800000 ->
        :neg_infinity

      band(bits, 0x7F800000) == 0x7F800000 and band(bits, 0x007FFFFF) != 0 ->
        :nan

      true ->
        <<f::big-float-32>> = bytes
        f
    end
  end

  defp read_scalar(buf, pos, :float64, little?) do
    bytes = part_endian(buf, pos, 8, little?)
    bits = :binary.decode_unsigned(bytes, :big)

    cond do
      bits == 0x7FF0000000000000 ->
        :infinity

      bits == 0xFFF0000000000000 ->
        :neg_infinity

      band(bits, 0x7FF0000000000000) == 0x7FF0000000000000 and band(bits, 0x000FFFFFFFFFFFFF) != 0 ->
        :nan

      true ->
        <<f::big-float-64>> = bytes
        f
    end
  end

  defp read_scalar(buf, pos, :bigint64, little?),
    do: {:bigint, signed(read_uint(buf, pos, 8, little?), 64)}

  defp read_scalar(buf, pos, :biguint64, little?), do: {:bigint, read_uint(buf, pos, 8, little?)}

  defp write_scalar(buf, pos, value, type, little?) do
    bytes = encode_scalar(value, type)
    write_bytes(buf, pos, maybe_reverse(bytes, little?))
  end

  defp convert_write_value(value, type) when type in [:bigint64, :biguint64],
    do: bigint_value(value)

  defp convert_write_value(value, _type), do: Runtime.to_number(value)

  defp encode_scalar(value, :int8), do: <<trunc_number(value)::signed-8>>
  defp encode_scalar(value, :uint8), do: <<band(trunc_number(value), 0xFF)::8>>
  defp encode_scalar(value, :int16), do: <<trunc_number(value)::signed-16>>
  defp encode_scalar(value, :uint16), do: <<band(trunc_number(value), 0xFFFF)::16>>
  defp encode_scalar(value, :int32), do: <<trunc_number(value)::signed-32>>
  defp encode_scalar(value, :uint32), do: <<band(trunc_number(value), 0xFFFFFFFF)::32>>
  defp encode_scalar(value, :float16), do: <<encode_float16(value)::16>>
  defp encode_scalar(value, :float32), do: <<float32_bits(value)::32>>
  defp encode_scalar(value, :float64), do: <<float64_bits(value)::64>>
  defp encode_scalar(value, :bigint64), do: <<value::signed-64>>
  defp encode_scalar(value, :biguint64), do: <<value::unsigned-64>>

  defp read_uint(buf, pos, size, little?),
    do: :binary.decode_unsigned(part_endian(buf, pos, size, little?), :big)

  defp part_endian(buf, pos, size, true),
    do:
      binary_part(buf, pos, size)
      |> :binary.bin_to_list()
      |> Enum.reverse()
      |> :binary.list_to_bin()

  defp part_endian(buf, pos, size, false), do: binary_part(buf, pos, size)

  defp maybe_reverse(bytes, true),
    do: bytes |> :binary.bin_to_list() |> Enum.reverse() |> :binary.list_to_bin()

  defp maybe_reverse(bytes, false), do: bytes

  defp write_bytes(buf, pos, bytes) do
    size = byte_size(bytes)
    <<pre::binary-size(pos), _::binary-size(size), rest::binary>> = buf
    <<pre::binary, bytes::binary, rest::binary>>
  end

  defp signed(value, bits) do
    limit = 1 <<< (bits - 1)
    if value >= limit, do: value - (1 <<< bits), else: value
  end

  defp trunc_number(value) do
    case value do
      n when is_integer(n) -> n
      n when is_float(n) -> trunc(n)
      _ -> 0
    end
  end

  defp bigint_value({:bigint, n}), do: n
  defp bigint_value(true), do: 1
  defp bigint_value(false), do: 0

  defp bigint_value(value) when is_binary(value) do
    value
    |> String.trim()
    |> parse_bigint_string()
    |> case do
      {:ok, n} -> n
      :error -> JSThrow.syntax_error!("Cannot convert value to BigInt")
    end
  end

  defp bigint_value({:obj, _} = value),
    do: value |> Coercion.to_primitive("number") |> bigint_value()

  defp bigint_value(_value), do: JSThrow.type_error!("Cannot convert value to BigInt")

  defp parse_bigint_string(""), do: {:ok, 0}
  defp parse_bigint_string("0x" <> digits), do: parse_bigint_digits(digits, 16)
  defp parse_bigint_string("0X" <> digits), do: parse_bigint_digits(digits, 16)
  defp parse_bigint_string("0o" <> digits), do: parse_bigint_digits(digits, 8)
  defp parse_bigint_string("0O" <> digits), do: parse_bigint_digits(digits, 8)
  defp parse_bigint_string("0b" <> digits), do: parse_bigint_digits(digits, 2)
  defp parse_bigint_string("0B" <> digits), do: parse_bigint_digits(digits, 2)
  defp parse_bigint_string("+" <> digits), do: parse_bigint_digits(digits, 10)

  defp parse_bigint_string("-" <> digits) do
    case parse_bigint_digits(digits, 10) do
      {:ok, n} -> {:ok, -n}
      :error -> :error
    end
  end

  defp parse_bigint_string(digits), do: parse_bigint_digits(digits, 10)

  defp parse_bigint_digits("", _base), do: :error

  defp parse_bigint_digits(digits, base) do
    case Integer.parse(digits, base) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  defp float32_bits(:nan), do: 0x7FC00000
  defp float32_bits(:infinity), do: 0x7F800000
  defp float32_bits(:neg_infinity), do: 0xFF800000

  defp float32_bits(value) do
    <<bits::32>> = <<Runtime.to_float(value)::big-float-32>>
    bits
  end

  defp float64_bits(:nan), do: 0x7FF8000000000000
  defp float64_bits(:infinity), do: 0x7FF0000000000000
  defp float64_bits(:neg_infinity), do: 0xFFF0000000000000

  defp float64_bits(value) do
    <<bits::64>> = <<Runtime.to_float(value)::big-float-64>>
    bits
  end

  defp decode_float16(bits) do
    sign = if band(bits, 0x8000) == 0, do: 1.0, else: -1.0
    exp = band(bits >>> 10, 0x1F)
    frac = band(bits, 0x03FF)

    cond do
      exp == 0 and frac == 0 -> if sign < 0, do: -0.0, else: 0.0
      exp == 0 -> sign * :math.pow(2, -14) * (frac / 1024)
      exp == 31 and frac == 0 -> if sign < 0, do: :neg_infinity, else: :infinity
      exp == 31 -> :nan
      true -> sign * :math.pow(2, exp - 15) * (1 + frac / 1024)
    end
  end

  defp encode_float16(:nan), do: 0x7E00
  defp encode_float16(:infinity), do: 0x7C00
  defp encode_float16(:neg_infinity), do: 0xFC00

  defp encode_float16(value) do
    f = Runtime.to_float(value)

    cond do
      f == 0.0 -> if Values.neg_zero?(f), do: 0x8000, else: 0
      f >= 65_520 -> 0x7C00
      f <= -65_520 -> 0xFC00
      true -> encode_normal_float16(f)
    end
  end

  defp encode_normal_float16(f) do
    sign = if f < 0, do: 0x8000, else: 0
    abs_f = abs(f)
    exp = :math.floor(:math.log2(abs_f)) |> trunc()

    cond do
      exp < -14 ->
        rounded = round_ties_even(abs_f / :math.pow(2, -24))
        sign ||| min(0x0400, rounded)

      true ->
        frac = round_ties_even((abs_f / :math.pow(2, exp) - 1) * 1024)
        {exp, frac} = if frac == 1024, do: {exp + 1, 0}, else: {exp, frac}

        if exp > 15 do
          sign ||| 0x7BFF
        else
          sign ||| (exp + 15) <<< 10 ||| band(frac, 0x03FF)
        end
    end
  end

  defp round_ties_even(value) do
    floor = Float.floor(value)
    fraction = value - floor

    cond do
      fraction < 0.5 -> trunc(floor)
      fraction > 0.5 -> trunc(floor) + 1
      rem(trunc(floor), 2) == 0 -> trunc(floor)
      true -> trunc(floor) + 1
    end
  end
end
