defmodule Mix.Tasks.TestIsolated do
  @moduledoc false
  use Mix.Task

  @shortdoc "Run mix test in a subprocess (isolates NIF shutdown crashes)"
  def run(args) do
    {_, exit_code} = System.cmd("elixir", ["-S", "mix", "test" | args], into: IO.stream())

    if exit_code > 1 do
      System.halt(exit_code)
    end
  end
end
