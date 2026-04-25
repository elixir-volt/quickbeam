defmodule QuickBEAM.VM.Runtime.Web.Encoding do
  @moduledoc "atob and btoa builtins for BEAM mode."

  def bindings do
    %{
      "btoa" => {:builtin, "btoa", fn [str | _], _ -> Base.encode64(str) end},
      "atob" => {:builtin, "atob", fn [str | _], _ -> Base.decode64!(str) end}
    }
  end
end
