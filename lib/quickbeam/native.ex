defmodule QuickBEAM.Native do
  @moduledoc false

  @c_src_dir Path.expand("../../priv/c_src", __DIR__)
  @lexbor_cflags [
    "-std=c99",
    "-DLEXBOR_STATIC",
    "-I#{@c_src_dir}",
    "-I#{@c_src_dir}/lexbor/ports/posix"
  ]

  @lexbor_src Path.wildcard("priv/c_src/lexbor/{core,dom,html,tag,ns,css,selectors}/**/*.c")
             |> Enum.concat(Path.wildcard("priv/c_src/lexbor/ports/posix/**/*.c"))
             |> Enum.sort()
             |> Enum.map(fn path ->
               {:priv, String.replace_prefix(path, "priv/", ""), @lexbor_cflags}
             end)

  use Zig,
    otp_app: :quickbeam,
    zig_code_path: "quickbeam.zig",
    optimize: :env,
    c: [
      include_dirs: [
        {:priv, "c_src"},
        {:priv, "c_src/lexbor/ports/posix"}
      ],
      src:
        [
          {:priv, "c_src/quickjs.c", ["-std=c11"]},
          {:priv, "c_src/libregexp.c", ["-std=c11"]},
          {:priv, "c_src/libunicode.c", ["-std=c11"]},
          {:priv, "c_src/dtoa.c", ["-std=c11"]},
          {:priv, "c_src/lexbor_bridge.c", @lexbor_cflags}
        ] ++ @lexbor_src
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
      memory_usage: [:dirty_io],
      dom_find: [:dirty_io],
      dom_find_all: [:dirty_io],
      dom_text: [:dirty_io],
      dom_attr: [:dirty_io],
      dom_html: [:dirty_io]
    ]
end
