defmodule QuickBEAM.Native do
  @moduledoc false

  @version Mix.Project.config()[:version]

  @c_src_dir Path.expand("../../priv/c_src", __DIR__)
  @hidden_cflags ["-fvisibility=hidden"]
  @lexbor_cflags [
    "-std=c99",
    "-DLEXBOR_STATIC",
    "-I#{@c_src_dir}",
    "-I#{@c_src_dir}/lexbor/ports/posix"
  ] ++ @hidden_cflags

  @lexbor_src Path.wildcard("priv/c_src/lexbor/{core,dom,html,tag,ns,css,selectors}/**/*.c")
              |> Enum.concat(Path.wildcard("priv/c_src/lexbor/ports/posix/**/*.c"))
              |> Enum.sort()
              |> Enum.map(fn path ->
                {:priv, String.replace_prefix(path, "priv/", ""), @lexbor_cflags}
              end)

  @wamr_cflags [
    "-std=c11",
    "-D_GNU_SOURCE",
    "-DWASM_ENABLE_INTERP=1",
    "-DWASM_ENABLE_AOT=0",
    "-DWASM_ENABLE_FAST_INTERP=0",
    "-DWASM_ENABLE_LIBC_BUILTIN=0",
    "-DWASM_ENABLE_LIBC_WASI=0",
    "-DWASM_ENABLE_MULTI_MODULE=0",
    "-DWASM_ENABLE_BULK_MEMORY=1",
    "-DWASM_ENABLE_REF_TYPES=1",
    "-DWASM_ENABLE_SIMD=0",
    "-DWASM_ENABLE_TAIL_CALL=1",
    "-DWASM_ENABLE_MEMORY64=0",
    "-DWASM_ENABLE_GC=0",
    "-DWASM_ENABLE_THREAD_MGR=0",
    "-DWASM_ENABLE_SHARED_MEMORY=0",
    "-DWASM_ENABLE_EXCE_HANDLING=0",
    "-DWASM_ENABLE_MINI_LOADER=0",
    "-DWASM_ENABLE_WAMR_COMPILER=0",
    "-DWASM_ENABLE_JIT=0",
    "-DWASM_ENABLE_FAST_JIT=0",
    "-DWASM_ENABLE_DEBUG_INTERP=0",
    "-DWASM_ENABLE_INSTRUCTION_METERING=1",
    "-DWASM_ENABLE_DUMP_CALL_STACK=0",
    "-DWASM_ENABLE_PERF_PROFILING=0",
    "-DWASM_ENABLE_LOAD_CUSTOM_SECTION=0",
    "-DWASM_ENABLE_CUSTOM_NAME_SECTION=1",
    "-DWASM_ENABLE_GLOBAL_HEAP_POOL=0",
    "-DWASM_ENABLE_SPEC_TEST=0",
    "-DWASM_ENABLE_LABELS_AS_VALUES=1",
    "-DWASM_ENABLE_WASM_CACHE=0",
    "-DWASM_ENABLE_STRINGREF=0",
    "-DWASM_MEM_ALLOC_WITH_SYSTEM_ALLOCATOR=1",
    "-DWASM_API_EXTERN=",
    "-DWASM_RUNTIME_API_EXTERN=",
    "-DBH_MALLOC=wasm_runtime_malloc",
    "-DBH_FREE=wasm_runtime_free",
    "-I#{@c_src_dir}",
    "-I#{@c_src_dir}/wamr/include",
    "-I#{@c_src_dir}/wamr/interpreter",
    "-I#{@c_src_dir}/wamr/common",
    "-I#{@c_src_dir}/wamr/shared/utils",
    "-I#{@c_src_dir}/wamr/shared/platform/include",
    "-I#{@c_src_dir}/wamr/shared/mem-alloc",
    "-I#{@c_src_dir}/wamr/shared/platform/#{if(:os.type() == {:unix, :darwin}, do: "darwin", else: "linux")}"
  ] ++ @hidden_cflags

  @wamr_src (Path.wildcard("priv/c_src/wamr/interpreter/wasm_loader.c") ++
               Path.wildcard("priv/c_src/wamr/interpreter/wasm_interp_classic.c") ++
               Path.wildcard("priv/c_src/wamr/interpreter/wasm_runtime.c") ++
               Path.wildcard("priv/c_src/wamr/common/wasm_runtime_common.c") ++
               Path.wildcard("priv/c_src/wamr/common/wasm_exec_env.c") ++
               Path.wildcard("priv/c_src/wamr/common/wasm_memory.c") ++
               Path.wildcard("priv/c_src/wamr/common/wasm_native.c") ++
               Path.wildcard("priv/c_src/wamr/common/wasm_application.c") ++
               Path.wildcard("priv/c_src/wamr/common/wasm_loader_common.c") ++
               Path.wildcard("priv/c_src/wamr/common/wasm_blocking_op.c") ++
               Path.wildcard("priv/c_src/wamr/common/wasm_c_api.c") ++
               Path.wildcard("priv/c_src/wamr/shared/utils/bh_assert.c") ++
               Path.wildcard("priv/c_src/wamr/shared/utils/bh_common.c") ++
               Path.wildcard("priv/c_src/wamr/shared/utils/bh_hashmap.c") ++
               Path.wildcard("priv/c_src/wamr/shared/utils/bh_leb128.c") ++
               Path.wildcard("priv/c_src/wamr/shared/utils/bh_list.c") ++
               Path.wildcard("priv/c_src/wamr/shared/utils/bh_log.c") ++
               Path.wildcard("priv/c_src/wamr/shared/utils/bh_queue.c") ++
               Path.wildcard("priv/c_src/wamr/shared/utils/bh_vector.c") ++
               Path.wildcard("priv/c_src/wamr/shared/utils/bh_bitmap.c") ++
               Path.wildcard("priv/c_src/wamr/shared/utils/runtime_timer.c") ++
               Path.wildcard("priv/c_src/wamr/shared/mem-alloc/mem_alloc.c") ++
               Path.wildcard("priv/c_src/wamr/shared/mem-alloc/ems/*.c") ++
               Path.wildcard("priv/c_src/wamr/shared/platform/common/posix/posix_malloc.c") ++
               Path.wildcard("priv/c_src/wamr/shared/platform/common/posix/posix_memmap.c") ++
               Path.wildcard("priv/c_src/wamr/shared/platform/common/posix/posix_thread.c") ++
               Path.wildcard("priv/c_src/wamr/shared/platform/common/posix/posix_time.c") ++
               Path.wildcard("priv/c_src/wamr/shared/platform/common/posix/posix_blocking_op.c") ++
               [
                 if(:os.type() == {:unix, :darwin},
                   do: "priv/c_src/wamr/shared/platform/darwin/platform_init.c",
                   else: "priv/c_src/wamr/shared/platform/linux/platform_init.c"
                 )
               ] ++
               ["priv/c_src/wamr/common/arch/invokeNative_general.c"] ++
               ["priv/c_src/wamr/shared/platform/common/memory/mremap.c"] ++
               ["priv/c_src/wamr_bridge.c"])
            |> Enum.sort()
            |> Enum.map(fn path ->
              {:priv, String.replace_prefix(path, "priv/", ""), @wamr_cflags}
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

  @quickjs_cflags @quickjs_cflags ++ @hidden_cflags

  if System.get_env("QUICKBEAM_BUILD") in ["1", "true"] and
       is_nil(System.get_env("ZIG_LOCAL_CACHE_DIR")) do
    zig_local_cache_dir = Path.expand(Path.join(Mix.Project.build_path(), "zig-cache"))
    File.mkdir_p!(zig_local_cache_dir)
    System.put_env("ZIG_LOCAL_CACHE_DIR", zig_local_cache_dir)
  end

  use ZiglerPrecompiled,
    otp_app: :quickbeam,
    base_url: "https://github.com/elixir-volt/quickbeam/releases/download/v#{@version}",
    version: @version,
    force_build: System.get_env("QUICKBEAM_BUILD") in ["1", "true"],
    targets: ~w(x86_64-linux-gnu aarch64-macos-none),
    zig_code_path: "quickbeam.zig",
    optimize: :env,
    c: [
      include_dirs: [
        {:priv, "c_src"},
        {:priv, "c_src/lexbor/ports/posix"},
        {:priv, "c_src/wamr/include"},
        {:priv, "c_src/wamr/interpreter"},
        {:priv, "c_src/wamr/common"},
        {:priv, "c_src/wamr/shared/utils"},
        {:priv, "c_src/wamr/shared/platform/include"},
        {:priv, "c_src/wamr/shared/mem-alloc"}
      ],
      src:
        [
          {:priv, "c_src/quickjs.c", @quickjs_cflags},
          {:priv, "c_src/libregexp.c", @quickjs_cflags},
          {:priv, "c_src/libunicode.c", @quickjs_cflags},
          {:priv, "c_src/dtoa.c", @quickjs_cflags},
          {:priv, "c_src/lexbor_bridge.c", @lexbor_cflags}
        ] ++ @lexbor_src ++ @wamr_src
    ],
    resources: [:RuntimeResource, :PoolResource, :WasmModuleResource, :WasmInstanceResource],
    nifs: [
      eval: 4,
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
      pool_create_context: 5,
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
      pool_dom_html: 2,
      disasm_bytecode: 1,
      load_addon: 3,
      wasm_compile: 1,
      wasm_start: 3,
      wasm_start_with_imports: 5,
      wasm_stop: 1,
      wasm_call: 3,
      wasm_memory_size: 1,
      wasm_memory_grow: 2,
      wasm_read_memory: 3,
      wasm_write_memory: 3,
      wasm_read_global: 2,
      wasm_write_global: 3,
      enable_coverage: 1,
      get_coverage: 1,
      reset_coverage: 1
    ]
end
