defmodule QuickBEAM.VM.Runtime.Web.Buffer.BinaryCodec do
  @moduledoc "Integer and float binary codecs for Buffer read/write methods."

  import Bitwise

  @doc "Decodes an integer from a Buffer byte chunk using the requested signedness and endian mode."
  def decode_int(chunk, size, :unsigned, :big) do
    <<value::unsigned-big-integer-size(size)-unit(8)>> = chunk
    value
  end

  def decode_int(chunk, size, :signed, :big) do
    <<value::signed-big-integer-size(size)-unit(8)>> = chunk
    value
  end

  def decode_int(chunk, size, :unsigned, :little) do
    <<value::unsigned-little-integer-size(size)-unit(8)>> = chunk
    value
  end

  def decode_int(chunk, size, :signed, :little) do
    <<value::signed-little-integer-size(size)-unit(8)>> = chunk
    value
  end

  @doc "Encodes an integer for Buffer writes using the requested signedness and endian mode."
  def encode_int(value, size, :unsigned, :big) do
    int_value = band(trunc(value), max_uint(size))
    <<int_value::unsigned-big-integer-size(size)-unit(8)>>
  end

  def encode_int(value, size, :signed, :big) do
    int_value = to_signed(trunc(value), size)
    <<int_value::signed-big-integer-size(size)-unit(8)>>
  end

  def encode_int(value, size, :unsigned, :little) do
    int_value = band(trunc(value), max_uint(size))
    <<int_value::unsigned-little-integer-size(size)-unit(8)>>
  end

  def encode_int(value, size, :signed, :little) do
    int_value = to_signed(trunc(value), size)
    <<int_value::signed-little-integer-size(size)-unit(8)>>
  end

  @doc "Decodes a 32-bit or 64-bit float from a Buffer byte chunk."
  def decode_float(chunk, 4, :big) do
    <<value::float-big-32>> = chunk
    value
  end

  def decode_float(chunk, 4, :little) do
    <<value::float-little-32>> = chunk
    value
  end

  def decode_float(chunk, 8, :big) do
    <<value::float-big-64>> = chunk
    value
  end

  def decode_float(chunk, 8, :little) do
    <<value::float-little-64>> = chunk
    value
  end

  @doc "Encodes a 32-bit or 64-bit float for Buffer writes."
  def encode_float(value, 4, :big), do: <<value::float-big-32>>
  def encode_float(value, 4, :little), do: <<value::float-little-32>>
  def encode_float(value, 8, :big), do: <<value::float-big-64>>
  def encode_float(value, 8, :little), do: <<value::float-little-64>>

  defp max_uint(1), do: 0xFF
  defp max_uint(2), do: 0xFFFF
  defp max_uint(4), do: 0xFFFFFFFF

  defp to_signed(value, bytes) do
    bits = bytes * 8
    max_positive = 1 <<< (bits - 1)
    modulus = 1 <<< bits
    value = rem(value, modulus)
    value = if value < 0, do: value + modulus, else: value
    if value >= max_positive, do: value - modulus, else: value
  end
end
