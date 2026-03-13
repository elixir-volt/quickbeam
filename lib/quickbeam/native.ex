defmodule QuickBEAM.Native do
  @moduledoc false

  @version Mix.Project.config()[:version]

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
                    do: [
                      "-std=c11",
                      "-D_GNU_SOURCE",
                      "-fsanitize=undefined",
                      "-fno-sanitize=function,unsigned-integer-overflow",
                      "-fsanitize-trap=undefined"
                    ],
                    else: ["-std=c11", "-D_GNU_SOURCE"]

  use ZiglerPrecompiled,
    otp_app: :quickbeam,
    base_url: "https://github.com/dannote/quickbeam/releases/download/v#{@version}",
    version: @version,
    force_build: System.get_env("QUICKBEAM_BUILD") in ["1", "true"],
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
    resources: [:RuntimeResource, :PoolResource],
    nifs: [
      eval: 3,
      compile: 2,
      call_function: 4,
      load_module: 3,
      load_bytecode: 2,
      reset_runtime: 1,
      stop_runtime: 1,
      start_runtime: 2,
      resolve_call: 3,
      reject_call: 3,
      resolve_call_term: 3,
      reject_call_term: 3,
      send_message: 2,
      define_global: 3,
      get_global: 2,
      delete_globals: 2,
      snapshot_globals: 1,
      list_globals: 2,
      memory_usage: 1,
      dom_find: 2,
      dom_find_all: 2,
      dom_text: 2,
      dom_attr: 3,
      dom_html: 1,
      pool_start: 1,
      pool_stop: 1,
      pool_create_context: 3,
      pool_destroy_context: 2,
      pool_eval: 4,
      pool_call_function: 5,
      pool_reset_context: 2,
      pool_send_message: 3,
      pool_define_global: 4,
      pool_load_bytecode: 3,
      pool_get_global: 3,
      pool_memory_usage: 2,
      pool_resolve_call_term: 4,
      pool_reject_call_term: 4,
      pool_dom_find: 3,
      pool_dom_find_all: 3,
      pool_dom_text: 3,
      pool_dom_html: 2
    ]
end
