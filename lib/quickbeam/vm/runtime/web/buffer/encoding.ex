defmodule QuickBEAM.VM.Runtime.Web.Buffer.Encoding do
  @moduledoc "Encoding helpers for Node-compatible Buffer operations."

  import Bitwise

  def decode(str, "hex"), do: hex_decode(str)
  def decode(str, "base64"), do: base64_decode(str)
  def decode(str, "base64url"), do: base64url_decode(str)
  def decode(str, encoding) when encoding in ["latin1", "binary"], do: latin1_to_bytes(str)
  def decode(str, "ascii"), do: ascii_bytes(str)

  def decode(str, encoding) when encoding in ["utf16le", "ucs2", "ucs-2", "utf-16le"],
    do: utf16le_encode(str)

  def decode(str, _encoding), do: str

  def encode(bytes, encoding) when encoding in ["latin1", "binary"], do: bytes_to_latin1(bytes)
  def encode(bytes, "ascii"), do: bytes_to_ascii(bytes)
  def encode(bytes, "hex"), do: Base.encode16(bytes, case: :lower)
  def encode(bytes, "base64"), do: Base.encode64(bytes)
  def encode(bytes, "base64url"), do: Base.url_encode64(bytes, padding: false)
  def encode(bytes, _encoding), do: bytes

  def byte_length(str, "base64"), do: base64_byte_length(str)
  def byte_length(str, "base64url"), do: base64url_byte_length(str)
  def byte_length(str, encoding) when encoding in ["hex"], do: div(byte_size(str), 2)

  def byte_length(str, encoding) when encoding in ["utf16le", "ucs2", "ucs-2", "utf-16le"],
    do: byte_size(utf16le_encode(str))

  def byte_length(str, _encoding), do: byte_size(str)

  def fill(n, pattern) do
    pat_bytes = pattern |> String.to_charlist() |> Enum.map(&band(&1, 0xFF))
    pat_len = length(pat_bytes)

    if pat_len == 0 do
      :binary.copy(<<0>>, n)
    else
      Enum.map(0..(n - 1), fn i -> Enum.at(pat_bytes, rem(i, pat_len)) end)
      |> :erlang.list_to_binary()
    end
  end

  def compare(a, b) when a < b, do: -1
  def compare(a, b) when a > b, do: 1
  def compare(a, a), do: 0
  def compare(a, b) when a == b, do: 0

  def safe_slice(bytes, start_i, end_i) do
    total = byte_size(bytes)
    start = max(0, min(start_i, total))
    stop = max(start, min(end_i, total))
    binary_part(bytes, start, stop - start)
  end

  defp hex_decode(str) do
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
    str
    |> String.replace(~r/[\s]/, "")
    |> pad_base64()
    |> Base.decode64()
    |> case do
      {:ok, bytes} -> bytes
      _ -> <<>>
    end
  end

  defp base64url_decode(str) do
    clean = String.replace(str, ~r/[\s]/, "")

    case Base.url_decode64(clean, padding: false) do
      {:ok, bytes} -> bytes
      _ -> decode_padded_base64url(clean)
    end
  end

  defp decode_padded_base64url(str) do
    str
    |> String.replace("-", "+")
    |> String.replace("_", "/")
    |> pad_base64()
    |> Base.decode64()
    |> case do
      {:ok, bytes} -> bytes
      _ -> <<>>
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

  defp utf16le_encode(str), do: :unicode.characters_to_binary(str, :utf8, {:utf16, :little})

  defp bytes_to_latin1(bytes) do
    bytes
    |> :binary.bin_to_list()
    |> Enum.map(fn byte -> if byte < 128, do: <<byte>>, else: <<byte::utf8>> end)
    |> IO.iodata_to_binary()
  end

  defp bytes_to_ascii(bytes) do
    bytes
    |> :binary.bin_to_list()
    |> Enum.map(fn byte -> <<band(byte, 0x7F)>> end)
    |> IO.iodata_to_binary()
  end

  defp base64_byte_length(str) do
    str
    |> String.replace("=", "")
    |> byte_size()
    |> then(&div(&1 * 3, 4))
  end

  defp base64url_byte_length(str) do
    str
    |> String.replace(~r/[=]/, "")
    |> byte_size()
    |> then(&div(&1 * 3, 4))
  end
end
