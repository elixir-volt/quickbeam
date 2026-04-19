defmodule QuickBEAM.BeamVM.Runtime.Console do
  @moduledoc false

  alias QuickBEAM.BeamVM.Heap

  # ── Console ──

  def object do
    ref = make_ref()

    Heap.put_obj(ref, %{
      "log" =>
        {:builtin, "log",
         fn args, _this ->
           IO.puts(Enum.map(args, &QuickBEAM.BeamVM.Runtime.js_to_string/1) |> Enum.join(" "))
           :undefined
         end},
      "warn" =>
        {:builtin, "warn",
         fn args, _this ->
           IO.warn(Enum.map(args, &QuickBEAM.BeamVM.Runtime.js_to_string/1) |> Enum.join(" "))
           :undefined
         end},
      "error" =>
        {:builtin, "error",
         fn args, _this ->
           IO.puts(
             :stderr,
             Enum.map(args, &QuickBEAM.BeamVM.Runtime.js_to_string/1) |> Enum.join(" ")
           )

           :undefined
         end},
      "info" =>
        {:builtin, "info",
         fn args, _this ->
           IO.puts(Enum.map(args, &QuickBEAM.BeamVM.Runtime.js_to_string/1) |> Enum.join(" "))
           :undefined
         end},
      "debug" =>
        {:builtin, "debug",
         fn args, _this ->
           IO.puts(Enum.map(args, &QuickBEAM.BeamVM.Runtime.js_to_string/1) |> Enum.join(" "))
           :undefined
         end}
    })

    {:obj, ref}
  end
end
