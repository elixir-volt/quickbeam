defmodule QuickBEAM.VM.Runtime.Web.Performance do
  @moduledoc "performance object builtin for BEAM mode."

  import QuickBEAM.VM.Builtin, only: [build_object: 1]

  def bindings do
    %{"performance" => performance_object()}
  end

  defp performance_object do
    # Capture the current system time as the origin when the object is first created.
    # This ensures performance.now() returns a small positive millisecond count.
    time_origin_us = :erlang.system_time(:microsecond)

    build_object do
      method "now" do
        (:erlang.system_time(:microsecond) - time_origin_us) / 1000.0
      end

      val("timeOrigin", time_origin_us / 1000.0)
    end
  end
end
