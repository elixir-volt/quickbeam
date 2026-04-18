defmodule QuickBEAM.SharedAPIBeamTest do
  use ExUnit.Case, async: true
  use QuickBEAM.SharedAPITests, mode: :beam

  setup_all do
    {:ok, rt} = QuickBEAM.start()
    %{rt: rt}
  end
end
