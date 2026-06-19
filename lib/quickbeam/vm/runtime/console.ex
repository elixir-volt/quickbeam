defmodule QuickBEAM.VM.Runtime.Console do
  @moduledoc "Minimal core `console` builtin used outside the richer Web console API."

  use QuickBEAM.VM.Builtin

  alias QuickBEAM.VM.Runtime

  js_object "console" do
    method "log" do
      IO.puts(Enum.map_join(args, " ", &Runtime.stringify/1))
      :undefined
    end

    method "warn" do
      IO.puts(:stderr, Enum.map_join(args, " ", &Runtime.stringify/1))
      :undefined
    end

    method "error" do
      IO.puts(:stderr, Enum.map_join(args, " ", &Runtime.stringify/1))
      :undefined
    end

    method "info" do
      IO.puts(Enum.map_join(args, " ", &Runtime.stringify/1))
      :undefined
    end

    method "debug" do
      IO.puts(Enum.map_join(args, " ", &Runtime.stringify/1))
      :undefined
    end
  end
end
