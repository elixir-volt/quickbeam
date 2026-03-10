defmodule QuickbeamTest do
  use ExUnit.Case
  doctest Quickbeam

  test "greets the world" do
    assert Quickbeam.hello() == :world
  end
end
