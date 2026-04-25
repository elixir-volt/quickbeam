defmodule QuickBEAM.VM.Runtime.Web.Timers do
  @moduledoc "setTimeout, clearTimeout, setInterval, clearInterval builtins for BEAM mode."

  def bindings do
    %{
      "setTimeout" => {:builtin, "setTimeout", fn _, _ -> :erlang.unique_integer([:positive]) end},
      "clearTimeout" => {:builtin, "clearTimeout", fn _, _ -> :undefined end},
      "setInterval" =>
        {:builtin, "setInterval", fn _, _ -> :erlang.unique_integer([:positive]) end},
      "clearInterval" => {:builtin, "clearInterval", fn _, _ -> :undefined end}
    }
  end
end
