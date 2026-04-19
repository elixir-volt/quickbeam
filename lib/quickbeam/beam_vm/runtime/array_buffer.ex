defmodule QuickBEAM.BeamVM.Runtime.ArrayBuffer do
  @moduledoc false

  import QuickBEAM.BeamVM.Heap.Keys

  alias QuickBEAM.BeamVM.Heap

  def constructor(args, _this \\ nil) do
    byte_length =
      case args do
        [n | _] when is_integer(n) -> n
        _ -> 0
      end

    Heap.wrap(%{buffer() => :binary.copy(<<0>>, byte_length), "byteLength" => byte_length})
  end
end
