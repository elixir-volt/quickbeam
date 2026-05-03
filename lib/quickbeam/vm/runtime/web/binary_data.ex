defmodule QuickBEAM.VM.Runtime.Web.BinaryData do
  @moduledoc "Helpers for exposing BEAM binaries as Web binary JS objects."

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.Runtime.Constructors

  @doc "Constructs a JavaScript `Uint8Array` from a binary."
  def uint8_array(bytes) when is_binary(bytes) do
    bytes
    |> :binary.bin_to_list()
    |> uint8_array()
  end

  def uint8_array(bytes) when is_list(bytes) do
    Constructors.construct("Uint8Array", [bytes], fn -> Heap.wrap(bytes) end)
  end

  def typed_array_bytes(map) when is_map(map) do
    case Map.get(map, "buffer") do
      {:obj, buf_ref} ->
        case Heap.get_obj(buf_ref, %{}) do
          buffer_map when is_map(buffer_map) ->
            slice_buffer_bytes(buffer_map, map)

          _ ->
            Map.get(map, "__buffer__", <<>>)
        end

      _ ->
        Map.get(map, "__buffer__", <<>>)
    end
  end

  @doc "Constructs a JavaScript `ArrayBuffer` containing `bytes`."
  def array_buffer(bytes) when is_binary(bytes) do
    byte_len = byte_size(bytes)

    Constructors.construct(
      "ArrayBuffer",
      [byte_len],
      fn -> Heap.wrap(%{"__buffer__" => bytes, "byteLength" => byte_len}) end,
      &Map.put(&1, "__buffer__", bytes)
    )
  end

  defp slice_buffer_bytes(buffer_map, view_map) do
    ab_buf = Map.get(buffer_map, "__buffer__", <<>>)
    offset = Map.get(view_map, "byteOffset", 0)
    byte_len = Map.get(view_map, "byteLength", 0)

    if byte_size(ab_buf) >= offset + byte_len and byte_len > 0 do
      binary_part(ab_buf, offset, byte_len)
    else
      Map.get(view_map, "__buffer__", <<>>)
    end
  end
end
