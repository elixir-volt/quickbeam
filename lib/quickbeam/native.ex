defmodule QuickBEAM.Native do
  @moduledoc false
  use Zig,
    otp_app: :quickbeam,
    zig_code_path: "quickbeam.zig",
    optimize: :env,
    c: [
      include_dirs: {:priv, "c_src"},
      src: [
        {:priv, "c_src/quickjs.c", ["-std=c11"]},
        {:priv, "c_src/libregexp.c", ["-std=c11"]},
        {:priv, "c_src/libunicode.c", ["-std=c11"]},
        {:priv, "c_src/dtoa.c", ["-std=c11"]}
      ]
    ],
    resources: [:RuntimeResource],
    nifs: [
      eval: [:dirty_io],
      call_function: [:dirty_io],
      load_module: [:dirty_io],
      reset_runtime: [:dirty_io],
      stop_runtime: [:dirty_io],
      start_runtime: [],
      resolve_call: [],
      reject_call: [],
      resolve_call_term: [],
      reject_call_term: [],
      send_message: [],
      memory_usage: [:dirty_io]
    ]
end
