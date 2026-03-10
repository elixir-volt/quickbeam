defmodule QuickBEAM.Compression do
  @moduledoc false

  def compress([format, data]) when is_list(data) do
    bytes = :erlang.list_to_binary(data)

    result =
      case format do
        "gzip" -> :zlib.gzip(bytes)
        "deflate" -> :zlib.compress(bytes)
        "deflate-raw" -> raw_deflate(bytes)
        _ -> raise "Unsupported format: #{format}"
      end

    {:bytes, result}
  end

  def decompress([format, data]) when is_list(data) do
    bytes = :erlang.list_to_binary(data)

    result =
      case format do
        "gzip" -> :zlib.gunzip(bytes)
        "deflate" -> :zlib.uncompress(bytes)
        "deflate-raw" -> raw_inflate(bytes)
        _ -> raise "Unsupported format: #{format}"
      end

    {:bytes, result}
  end

  defp raw_deflate(data) do
    z = :zlib.open()

    try do
      :zlib.deflateInit(z, :default, :deflated, -15, 8, :default)
      result = :zlib.deflate(z, data, :finish)
      :zlib.deflateEnd(z)
      IO.iodata_to_binary(result)
    after
      :zlib.close(z)
    end
  end

  defp raw_inflate(data) do
    z = :zlib.open()

    try do
      :zlib.inflateInit(z, -15)
      result = :zlib.inflate(z, data)
      :zlib.inflateEnd(z)
      IO.iodata_to_binary(result)
    after
      :zlib.close(z)
    end
  end
end
