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

  @quickjs_cflags if System.get_env("QUICKBEAM_UBSAN") == "1",
                    do: ["-std=c11", "-D_GNU_SOURCE", "-fsanitize=undefined", "-fno-sanitize=function,unsigned-integer-overflow", "-fsanitize-trap=undefined"],
                    else: ["-std=c11", "-D_GNU_SOURCE"]

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
          {:priv, "c_src/quickjs.c", @quickjs_cflags},
          {:priv, "c_src/libregexp.c", @quickjs_cflags},
          {:priv, "c_src/libunicode.c", @quickjs_cflags},
          {:priv, "c_src/dtoa.c", @quickjs_cflags},
          {:priv, "c_src/lexbor_bridge.c", @lexbor_cflags}
        ] ++ @lexbor_src
    ],
    resources: [:RuntimeResource],
    nifs: [
      eval: [],
      compile: [],
      call_function: [],
      load_module: [],
      load_bytecode: [],
      reset_runtime: [],
      stop_runtime: [:dirty_io],
      start_runtime: [],
      resolve_call: [],
      reject_call: [],
      resolve_call_term: [],
      reject_call_term: [],
      send_message: [],
      define_global: [],
      memory_usage: [],
      dom_find: [],
      dom_find_all: [],
      dom_text: [],
      dom_attr: [],
      dom_html: []
    ]
end
