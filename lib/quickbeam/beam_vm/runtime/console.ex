defmodule QuickBEAM.BeamVM.Runtime.Console do
  @moduledoc false

  use QuickBEAM.BeamVM.Builtin

  alias QuickBEAM.BeamVM.Runtime

  js_object "console" do
    method "log" do
      IO.puts(args |> Enum.map(&Runtime.js_to_string/1) |> Enum.join(" "))
      :undefined
    end

    method "warn" do
      IO.warn(args |> Enum.map(&Runtime.js_to_string/1) |> Enum.join(" "))
      :undefined
    end

    method "error" do
      IO.puts(:stderr, args |> Enum.map(&Runtime.js_to_string/1) |> Enum.join(" "))
      :undefined
    end

    method "info" do
      IO.puts(args |> Enum.map(&Runtime.js_to_string/1) |> Enum.join(" "))
      :undefined
    end

    method "debug" do
      IO.puts(args |> Enum.map(&Runtime.js_to_string/1) |> Enum.join(" "))
      :undefined
    end
  end
end
