defmodule QuickBEAM.VM.Runtime.String.UTF16 do
  @moduledoc """
  Implements JavaScript string indexing over UTF-16 code units.

  Lone surrogate values are represented as WTF-8 binaries, matching the native
  QuickJS conversion boundary while remaining ordinary Elixir binaries.
  """

  import Bitwise

  @doc "Returns the number of UTF-16 code units in a JavaScript string."
  @spec length(binary()) :: non_neg_integer()
  def length(value), do: value |> units() |> Kernel.length()

  @doc "Returns one UTF-16 code unit encoded as WTF-8, or `:undefined`."
  @spec at(binary(), integer()) :: binary() | :undefined
  def at(_value, index) when index < 0, do: :undefined

  def at(value, index) do
    case Enum.at(units(value), index) do
      nil -> :undefined
      unit -> encode_unit(unit)
    end
  end

  @doc "Returns the numeric UTF-16 code unit at an index, or `:nan`."
  @spec char_code_at(binary(), integer()) :: non_neg_integer() | :nan
  def char_code_at(_value, index) when index < 0, do: :nan
  def char_code_at(value, index), do: Enum.at(units(value), index, :nan)

  @doc "Encodes UTF-16 code units as a JavaScript string represented with WTF-8."
  @spec from_units([non_neg_integer()]) :: binary()
  def from_units(units), do: encode_units(units)

  @doc "Slices a JavaScript string by UTF-16 code-unit offsets."
  @spec slice(binary(), non_neg_integer(), non_neg_integer()) :: binary()
  def slice(value, start, length) do
    value
    |> units()
    |> Enum.slice(start, length)
    |> encode_units()
  end

  defp units(value), do: decode(value, [])

  defp decode(<<>>, units), do: Enum.reverse(units)

  defp decode(<<codepoint, rest::binary>>, units) when codepoint < 0x80,
    do: decode(rest, [codepoint | units])

  defp decode(<<first, second, rest::binary>>, units) when first in 0xC2..0xDF do
    codepoint = (first &&& 0x1F) <<< 6 ||| (second &&& 0x3F)
    decode(rest, [codepoint | units])
  end

  defp decode(<<first, second, third, rest::binary>>, units) when first in 0xE0..0xEF do
    codepoint =
      (first &&& 0x0F) <<< 12 ||| (second &&& 0x3F) <<< 6 ||| (third &&& 0x3F)

    decode(rest, [codepoint | units])
  end

  defp decode(<<first, second, third, fourth, rest::binary>>, units)
       when first in 0xF0..0xF4 do
    codepoint =
      (first &&& 0x07) <<< 18 ||| (second &&& 0x3F) <<< 12 |||
        (third &&& 0x3F) <<< 6 ||| (fourth &&& 0x3F)

    scalar = codepoint - 0x10000
    high = 0xD800 + (scalar >>> 10)
    low = 0xDC00 + (scalar &&& 0x3FF)
    decode(rest, [low, high | units])
  end

  defp decode(<<byte, rest::binary>>, units), do: decode(rest, [byte | units])

  defp encode_units(units), do: encode_units(units, []) |> IO.iodata_to_binary()

  defp encode_units([high, low | rest], encoded)
       when high in 0xD800..0xDBFF and low in 0xDC00..0xDFFF do
    codepoint = 0x10000 + ((high - 0xD800) <<< 10) + (low - 0xDC00)
    encode_units(rest, [encode_scalar(codepoint) | encoded])
  end

  defp encode_units([unit | rest], encoded),
    do: encode_units(rest, [encode_unit(unit) | encoded])

  defp encode_units([], encoded), do: Enum.reverse(encoded)

  defp encode_unit(unit) when unit < 0x80, do: <<unit>>

  defp encode_unit(unit) when unit < 0x800,
    do: <<0xC0 ||| unit >>> 6, 0x80 ||| (unit &&& 0x3F)>>

  defp encode_unit(unit),
    do: <<0xE0 ||| unit >>> 12, 0x80 ||| (unit >>> 6 &&& 0x3F), 0x80 ||| (unit &&& 0x3F)>>

  defp encode_scalar(codepoint) do
    <<0xF0 ||| codepoint >>> 18, 0x80 ||| (codepoint >>> 12 &&& 0x3F),
      0x80 ||| (codepoint >>> 6 &&& 0x3F), 0x80 ||| (codepoint &&& 0x3F)>>
  end
end
