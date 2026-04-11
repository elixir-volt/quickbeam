defmodule QuickBEAM.Buffer do
  @moduledoc false

  @spec encode(list()) :: String.t()
  def encode([{:bytes, binary}, encoding]) when is_binary(binary) do
    do_encode(binary, encoding)
  end

  @spec encode(list()) :: String.t()
  def encode([binary, encoding]) when is_binary(binary) do
    do_encode(binary, encoding)
  end

  @spec decode(list()) :: {:bytes, binary()}
  def decode([string, encoding]) when is_binary(string) do
    {:bytes, do_decode(string, encoding)}
  end

  @spec byte_length(list()) :: non_neg_integer()
  def byte_length([string, encoding]) when is_binary(string) do
    byte_size(do_decode(string, encoding))
  end

  defp do_encode(binary, "hex"), do: Base.encode16(binary, case: :lower)
  defp do_encode(binary, "base64"), do: Base.encode64(binary)
  defp do_encode(binary, "base64url"), do: Base.url_encode64(binary, padding: false)

  defp do_encode(binary, encoding) when encoding in ["utf16le", "ucs2", "ucs-2", "utf-16le"] do
    :unicode.characters_to_binary(binary, {:utf16, :little}, :utf8)
  end

  defp do_decode(string, "hex"), do: Base.decode16!(string, case: :mixed)
  defp do_decode(string, "base64"), do: Base.decode64!(string)

  defp do_decode(string, "base64url") do
    Base.url_decode64!(string, padding: false)
  end

  defp do_decode(string, encoding) when encoding in ["utf16le", "ucs2", "ucs-2", "utf-16le"] do
    :unicode.characters_to_binary(string, :utf8, {:utf16, :little})
  end
end
