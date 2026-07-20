defmodule QuickBEAM.VM.Bytecode.Checksum do
  @moduledoc "Computes stable checksums for decoded VM program artifacts."

  import Bitwise

  @factor 0x9E370001
  @mask 0xFFFFFFFF

  @doc "Verifies the checksum embedded in a serialized QuickJS bytecode envelope."
  @spec verify(binary()) :: :ok | {:error, :unexpected_end | :checksum_mismatch}
  def verify(<<_version, expected::little-unsigned-32, payload::binary>>) do
    if calculate(payload) == expected, do: :ok, else: {:error, :checksum_mismatch}
  end

  def verify(_binary), do: {:error, :unexpected_end}

  @doc "Calculates QuickJS's stable 32-bit bytecode payload checksum."
  @spec calculate(binary()) :: non_neg_integer()
  def calculate(payload) when is_binary(payload), do: checksum_words(payload, 0)

  defp checksum_words(<<word::little-unsigned-32, rest::binary>>, checksum)
       when byte_size(rest) > 0 do
    checksum = band(checksum + word, @mask)
    checksum_words(rest, band(checksum * @factor, @mask))
  end

  defp checksum_words(rest, checksum) do
    tail =
      case rest do
        <<a>> -> a
        <<a, b>> -> a ||| b <<< 8
        <<a, b, c>> -> a ||| b <<< 8 ||| c <<< 16
        _ -> 0
      end

    checksum |> then(&band(&1 + tail, @mask)) |> then(&band(&1 * @factor, @mask))
  end
end
