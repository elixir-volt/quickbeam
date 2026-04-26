defmodule QuickBEAM.VM.Runtime.Web.BinaryData do
  @moduledoc "Helpers for exposing BEAM binaries as Web binary JS objects."

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.Runtime.Constructors

  def uint8_array(bytes) when is_binary(bytes) do
    bytes
    |> :binary.bin_to_list()
    |> uint8_array()
  end

  def uint8_array(bytes) when is_list(bytes) do
    Constructors.construct("Uint8Array", [bytes], fn -> Heap.wrap(bytes) end)
  end

  def array_buffer(bytes) when is_binary(bytes) do
    byte_len = byte_size(bytes)

    Constructors.construct(
      "ArrayBuffer",
      [byte_len],
      fn -> Heap.wrap(%{"__buffer__" => bytes, "byteLength" => byte_len}) end,
      &Map.put(&1, "__buffer__", bytes)
    )
  end
end
