defmodule QuickBEAM.VM.Varint do
  @moduledoc """
  Bounded QuickJS integer decoding backed by `Varint.LEB128` and
  `Varint.SLEB128`.

  QuickJS serializes these fields as 32-bit values, so accepting an unbounded
  varint would make malformed bytecode unnecessarily expensive to decode.
  """

  import Bitwise

  @max_encoded_bytes 5
  @max_u32 0xFFFFFFFF
  @min_i32 -0x80000000
  @max_i32 0x7FFFFFFF

  @spec read_unsigned(binary()) ::
          {:ok, non_neg_integer(), binary()} | {:error, :bad_leb128 | :integer_overflow}
  def read_unsigned(binary) when is_binary(binary) do
    with :ok <- terminated_within_limit(binary, @max_encoded_bytes, :bad_leb128),
         {:ok, value, rest} <- decode_unsigned(binary),
         true <- value <= @max_u32 do
      {:ok, value, rest}
    else
      false -> {:error, :integer_overflow}
      {:error, _} = error -> error
    end
  end

  @spec read_signed(binary()) ::
          {:ok, integer(), binary()} | {:error, :bad_sleb128 | :integer_overflow}
  def read_signed(binary) when is_binary(binary) do
    with :ok <- terminated_within_limit(binary, @max_encoded_bytes, :bad_sleb128),
         {:ok, value, rest} <- decode_signed(binary),
         true <- value >= @min_i32 and value <= @max_i32 do
      {:ok, value, rest}
    else
      false -> {:error, :integer_overflow}
      {:error, _} = error -> error
    end
  end

  @spec read_u8(binary()) :: {:ok, byte(), binary()} | {:error, :unexpected_end}
  def read_u8(<<value, rest::binary>>), do: {:ok, value, rest}
  def read_u8(_binary), do: {:error, :unexpected_end}

  @spec read_fixed_u32(binary()) ::
          {:ok, non_neg_integer(), binary()} | {:error, :unexpected_end}
  def read_fixed_u32(<<value::little-unsigned-32, rest::binary>>), do: {:ok, value, rest}
  def read_fixed_u32(_binary), do: {:error, :unexpected_end}

  defp decode_unsigned(binary) do
    try do
      {value, rest} = Varint.LEB128.decode(binary)
      {:ok, value, rest}
    rescue
      ArgumentError -> {:error, :bad_leb128}
    end
  end

  defp decode_signed(binary) do
    try do
      {value, rest} = Varint.SLEB128.decode(binary)
      {:ok, value, rest}
    rescue
      ArgumentError -> {:error, :bad_sleb128}
    end
  end

  defp terminated_within_limit(_binary, 0, error), do: {:error, error}
  defp terminated_within_limit(<<>>, _remaining, error), do: {:error, error}

  defp terminated_within_limit(<<byte, _rest::binary>>, _remaining, _error)
       when band(byte, 0x80) == 0,
       do: :ok

  defp terminated_within_limit(<<_byte, rest::binary>>, remaining, error),
    do: terminated_within_limit(rest, remaining - 1, error)
end
