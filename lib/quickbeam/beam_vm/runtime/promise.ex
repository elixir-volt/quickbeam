defmodule QuickBEAM.BeamVM.Runtime.Promise do
  @moduledoc false

  alias QuickBEAM.BeamVM.Runtime.PromiseBuiltins

  defdelegate constructor(), to: PromiseBuiltins
  defdelegate static_property(name), to: PromiseBuiltins
end
