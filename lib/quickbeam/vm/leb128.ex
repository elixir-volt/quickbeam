defmodule QuickBEAM.VM.LEB128 do
  @moduledoc false
  import Bitwise

  @spec read_unsigned(binary()) :: {:ok, non_neg_integer(), binary()} | {:error, :bad_leb128}
  def read_unsigned(<<rest::binary>>), do: read_unsigned(rest, 0, 0)

  defp read_unsigned(<<1::1, value::7, rest::binary>>, acc, shift) when shift < 64 do
    read_unsigned(rest, acc + (value <<< shift), shift + 7)
  end

  defp read_unsigned(<<0::1, value::7, rest::binary>>, acc, shift) do
    {:ok, acc + (value <<< shift), rest}
  end

  defp read_unsigned(_, _, _), do: {:error, :bad_leb128}

  @spec read_signed(binary()) :: {:ok, integer(), binary()} | {:error, :bad_sleb128}
  def read_signed(<<rest::binary>>), do: read_signed(rest, 0, 0)

  defp read_signed(<<1::1, value::7, rest::binary>>, acc, shift) when shift < 64 do
    read_signed(rest, acc + (value <<< shift), shift + 7)
  end

  defp read_signed(<<0::1, value::7, rest::binary>>, acc, shift) do
    result = acc + (value <<< shift)
    # Sign extend if the last byte's high bit is set
    size = shift + 7
    # Sign-extend: shift left to put sign bit at position 63, then arithmetic shift right
    {:ok, (result <<< (64 - size)) >>> (64 - size), rest}
  end

  defp read_signed(_, _, _), do: {:error, :bad_sleb128}

  @spec read_u16(binary()) :: {:ok, non_neg_integer(), binary()} | {:error, term()}
  def read_u16(bin) do
    with {:ok, val, rest} <- read_unsigned(bin) do
      {:ok, band(val, 0xFFFF), rest}
    end
  end

  @spec read_u8(binary()) :: {:ok, byte(), binary()} | {:error, :unexpected_end}
  def read_u8(<<val, rest::binary>>), do: {:ok, val, rest}
  def read_u8(_), do: {:error, :unexpected_end}

  @spec read_u32(binary()) :: {:ok, non_neg_integer(), binary()} | {:error, term()}
  def read_u32(bin) do
    with {:ok, val, rest} <- read_unsigned(bin) do
      {:ok, band(val, 0xFFFFFFFF), rest}
    end
  end

  @spec read_u64(binary()) :: {:ok, non_neg_integer(), binary()} | {:error, term()}
  def read_u64(<<val::little-unsigned-64, rest::binary>>), do: {:ok, val, rest}
  def read_u64(_), do: {:error, :unexpected_end}

  @spec read_i32(binary()) :: {:ok, integer(), binary()} | {:error, term()}
  def read_i32(bin), do: read_signed(bin)
end
