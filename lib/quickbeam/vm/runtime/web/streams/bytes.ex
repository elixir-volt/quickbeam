defmodule QuickBEAM.VM.Runtime.Web.Streams.Bytes do
  @moduledoc "Byte extraction helpers for stream chunks."

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.Runtime.Web.BinaryData

  @doc "Wraps stream chunk bytes as a JavaScript `Uint8Array`."
  def uint8_array(bytes) when is_binary(bytes), do: BinaryData.uint8_array(bytes)

  @doc "Extracts raw bytes from stream chunk values."
  def extract({:obj, ref}) do
    case Heap.get_obj(ref, %{}) do
      map when is_map(map) -> extract_from_map(map)
      _ -> <<>>
    end
  end

  def extract(bytes) when is_binary(bytes), do: bytes
  def extract({:bytes, bytes}), do: bytes
  def extract(_), do: <<>>

  defp extract_from_map(map) do
    cond do
      Map.has_key?(map, "__typed_array__") -> extract_typed_array(map)
      Map.has_key?(map, "__buffer__") -> Map.get(map, "__buffer__", <<>>)
      true -> <<>>
    end
  end

  defp extract_typed_array(map) do
    with {:obj, buffer_ref} <- Map.get(map, "buffer"),
         buffer_map when is_map(buffer_map) <- Heap.get_obj(buffer_ref, %{}) do
      buffer = Map.get(buffer_map, "__buffer__", <<>>)
      offset = Map.get(map, "byteOffset", 0)
      length = Map.get(map, "byteLength", 0)

      if byte_size(buffer) >= offset + length and length > 0,
        do: binary_part(buffer, offset, length),
        else: <<>>
    else
      _ -> <<>>
    end
  end
end
