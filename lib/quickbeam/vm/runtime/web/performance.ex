defmodule QuickBEAM.VM.Runtime.Web.Performance do
  @moduledoc "performance object builtin for BEAM mode."

  import QuickBEAM.VM.Builtin, only: [build_object: 1]

  def bindings do
    %{"performance" => performance_object()}
  end

  defp performance_object do
    build_object do
      method "now" do
        :erlang.monotonic_time(:microsecond) / 1000.0
      end

      val("timeOrigin", :erlang.system_time(:millisecond) / 1.0)
    end
  end
end
