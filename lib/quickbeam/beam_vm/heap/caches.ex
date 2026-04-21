defmodule QuickBEAM.BeamVM.Heap.Caches do
  @moduledoc false

  def get_decoded(byte_code), do: Process.get({:qb_decoded, byte_code})

  def put_decoded(byte_code, instructions),
    do: Process.put({:qb_decoded, byte_code}, instructions)

  def get_compiled(key), do: Process.get({:qb_compiled, key})
  def put_compiled(key, compiled), do: Process.put({:qb_compiled, key}, compiled)
end
