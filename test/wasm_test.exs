defmodule QuickBEAM.WASMTest do
  use ExUnit.Case, async: false

  alias QuickBEAM.WASM
  alias QuickBEAM.WASM.{Function, Module}

  # Minimal "add" module in WAT:
  #   (module
  #     (func (export "add") (param i32 i32) (result i32)
  #       local.get 0
  #       local.get 1
  #       i32.add))
  #
  # Hand-assembled WASM binary:
  @add_wasm <<
    # Magic + version
    0x00,
    0x61,
    0x73,
    0x6D,
    0x01,
    0x00,
    0x00,
    0x00,
    # Type section (id=1, 7 bytes)
    0x01,
    0x07,
    # 1 type: (i32, i32) -> (i32)
    0x01,
    0x60,
    0x02,
    0x7F,
    0x7F,
    0x01,
    0x7F,
    # Function section (id=3, 2 bytes)
    0x03,
    0x02,
    # 1 function, type index 0
    0x01,
    0x00,
    # Export section (id=7, 7 bytes)
    0x07,
    0x07,
    # 1 export: "add", func index 0
    0x01,
    0x03,
    0x61,
    0x64,
    0x64,
    0x00,
    0x00,
    # Code section (id=10, 9 bytes)
    0x0A,
    0x09,
    # 1 body
    0x01,
    # body: 7 bytes
    0x07,
    # 0 local declarations
    0x00,
    # local.get 0, local.get 1, i32.add, end
    0x20,
    0x00,
    0x20,
    0x01,
    0x6A,
    0x0B
  >>

  @add_i64_wasm <<
    0x00,
    0x61,
    0x73,
    0x6D,
    0x01,
    0x00,
    0x00,
    0x00,
    0x01,
    0x07,
    0x01,
    0x60,
    0x02,
    0x7E,
    0x7E,
    0x01,
    0x7E,
    0x03,
    0x02,
    0x01,
    0x00,
    0x07,
    0x09,
    0x01,
    0x05,
    0x61,
    0x64,
    0x64,
    0x36,
    0x34,
    0x00,
    0x00,
    0x0A,
    0x09,
    0x01,
    0x07,
    0x00,
    0x20,
    0x00,
    0x20,
    0x01,
    0x7C,
    0x0B
  >>

  @add_f64_wasm <<
    0x00,
    0x61,
    0x73,
    0x6D,
    0x01,
    0x00,
    0x00,
    0x00,
    0x01,
    0x07,
    0x01,
    0x60,
    0x02,
    0x7C,
    0x7C,
    0x01,
    0x7C,
    0x03,
    0x02,
    0x01,
    0x00,
    0x07,
    0x0A,
    0x01,
    0x06,
    0x61,
    0x64,
    0x64,
    0x66,
    0x36,
    0x34,
    0x00,
    0x00,
    0x0A,
    0x09,
    0x01,
    0x07,
    0x00,
    0x20,
    0x00,
    0x20,
    0x01,
    0xA0,
    0x0B
  >>

  # Module with an import:
  #   (module
  #     (import "env" "log" (func (param i32)))
  #     (func (export "run") (param i32)
  #       local.get 0
  #       call 0))
  @import_wasm <<
    0x00,
    0x61,
    0x73,
    0x6D,
    0x01,
    0x00,
    0x00,
    0x00,
    # Type section: 2 types
    0x01,
    0x09,
    0x02,
    # type 0: (i32) -> ()
    0x60,
    0x01,
    0x7F,
    0x00,
    # type 1: (i32) -> ()
    0x60,
    0x01,
    0x7F,
    0x00,
    # Import section
    0x02,
    0x0B,
    0x01,
    # "env"."log", func type 0
    0x03,
    0x65,
    0x6E,
    0x76,
    0x03,
    0x6C,
    0x6F,
    0x67,
    0x00,
    0x00,
    # Function section
    0x03,
    0x02,
    0x01,
    0x01,
    # Export section: "run" -> func 1
    0x07,
    0x07,
    0x01,
    0x03,
    0x72,
    0x75,
    0x6E,
    0x00,
    0x01,
    # Code section
    0x0A,
    0x08,
    0x01,
    0x06,
    0x00,
    # local.get 0, call 0, end
    0x20,
    0x00,
    0x10,
    0x00,
    0x0B
  >>

  @import_func_wasm <<
    0x00,
    0x61,
    0x73,
    0x6D,
    0x01,
    0x00,
    0x00,
    0x00,
    0x01,
    0x06,
    0x01,
    0x60,
    0x01,
    0x7F,
    0x01,
    0x7F,
    0x02,
    0x0B,
    0x01,
    0x03,
    0x65,
    0x6E,
    0x76,
    0x03,
    0x6C,
    0x6F,
    0x67,
    0x00,
    0x00,
    0x03,
    0x02,
    0x01,
    0x00,
    0x07,
    0x07,
    0x01,
    0x03,
    0x72,
    0x75,
    0x6E,
    0x00,
    0x01,
    0x0A,
    0x08,
    0x01,
    0x06,
    0x00,
    0x20,
    0x00,
    0x10,
    0x00,
    0x0B
  >>

  @import_global_wasm <<
    0x00,
    0x61,
    0x73,
    0x6D,
    0x01,
    0x00,
    0x00,
    0x00,
    0x02,
    0x0D,
    0x01,
    0x03,
    0x65,
    0x6E,
    0x76,
    0x04,
    0x62,
    0x61,
    0x73,
    0x65,
    0x03,
    0x7F,
    0x00,
    0x07,
    0x08,
    0x01,
    0x04,
    0x62,
    0x61,
    0x73,
    0x65,
    0x03,
    0x00
  >>

  @import_mutable_global_wasm <<
    0x00,
    0x61,
    0x73,
    0x6D,
    0x01,
    0x00,
    0x00,
    0x00,
    0x02,
    0x0D,
    0x01,
    0x03,
    0x65,
    0x6E,
    0x76,
    0x04,
    0x62,
    0x61,
    0x73,
    0x65,
    0x03,
    0x7F,
    0x01,
    0x07,
    0x08,
    0x01,
    0x04,
    0x62,
    0x61,
    0x73,
    0x65,
    0x03,
    0x00
  >>

  @import_memory_wasm <<
    0x00,
    0x61,
    0x73,
    0x6D,
    0x01,
    0x00,
    0x00,
    0x00,
    0x02,
    0x0F,
    0x01,
    0x03,
    0x65,
    0x6E,
    0x76,
    0x06,
    0x6D,
    0x65,
    0x6D,
    0x6F,
    0x72,
    0x79,
    0x02,
    0x00,
    0x01,
    0x07,
    0x0A,
    0x01,
    0x06,
    0x6D,
    0x65,
    0x6D,
    0x6F,
    0x72,
    0x79,
    0x02,
    0x00
  >>

  # Module with memory, global, and data segment (for parser tests)
  @memory_wasm <<
    0x00,
    0x61,
    0x73,
    0x6D,
    0x01,
    0x00,
    0x00,
    0x00,
    # Type section: 0 types
    0x01,
    0x01,
    0x00,
    # Memory section: 1 memory, min=1, no max
    0x05,
    0x03,
    0x01,
    0x00,
    0x01,
    # Global section: 1 global, i32 mutable, init=42
    0x06,
    0x06,
    0x01,
    0x7F,
    0x01,
    0x41,
    0x2A,
    0x0B,
    # Data section: "Hello"
    0x0B,
    0x0B,
    0x01,
    # active, memory 0, offset i32.const 0
    0x00,
    0x41,
    0x00,
    0x0B,
    # 5 bytes: "Hello"
    0x05,
    0x48,
    0x65,
    0x6C,
    0x6C,
    0x6F
  >>

  # Module with memory + data + a dummy exported function (for runtime tests)
  # (module
  #   (memory (export "memory") 1)
  #   (data (i32.const 0) "Hello")
  #   (func (export "nop") (nop)))
  # Module with exported memory and a get function (for runtime memory tests)
  # (module
  #   (memory (export "memory") 1)
  #   (func (export "get") (result i32) i32.const 0))
  # Type section: () -> (i32)
  # Function section: 1 func type 0
  # Memory section: 1 memory min=1
  # Export section: "memory" mem 0, "get" func 0
  # Code section: i32.const 0, end
  @memory_func_wasm <<0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00>> <>
                      <<0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7F>> <>
                      <<0x03, 0x02, 0x01, 0x00>> <>
                      <<0x05, 0x03, 0x01, 0x00, 0x01>> <>
                      <<0x07, 0x10, 0x02, 0x06>> <>
                      "memory" <>
                      <<0x02, 0x00, 0x03>> <>
                      "get" <>
                      <<0x00, 0x00>> <>
                      <<0x0A, 0x06, 0x01, 0x04, 0x00, 0x41, 0x00, 0x0B>>

  @custom_section_wasm <<0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00, 0x00, 0x08, 0x04, 0x6D,
                         0x65, 0x74, 0x61, 0x61, 0x62, 0x63>>

  # Bulk-memory regression fixture. Exercises every opcode gated by the WAMR
  # config flags WASM_ENABLE_BULK_MEMORY / _OPT (priv/c_src/wamr/config.h):
  #   memory.fill (fc 0b), memory.copy (fc 0a)   <- _OPT  (fc 0a is the blocker)
  #   memory.init (fc 08), data.drop  (fc 09)    <- BULK_MEMORY
  # Toolchains like Go's GOOS=js GOARCH=wasm, TinyGo, and Rust wasm-bindgen emit
  # these unconditionally; with the gates off WAMR rejects them at compile time
  # with "unsupported opcode fc 0a".
  #
  # WAT (assembled with wat2wasm, byte-exact-verified against a reference runtime):
  #   (module
  #     (memory (export "mem") 1)
  #     (data $seg "\de\ad\be\ef")
  #     (func (export "run") (result i32)
  #       (memory.fill (i32.const 0)   (i32.const 0xAB) (i32.const 16))
  #       (memory.copy (i32.const 100) (i32.const 0)    (i32.const 16))
  #       (memory.init $seg (i32.const 200) (i32.const 0) (i32.const 4))
  #       (data.drop $seg)
  #       (i32.add
  #         (i32.mul (i32.load8_u (i32.const 100)) (i32.const 256))
  #         (i32.load8_u (i32.const 200)))))
  # run() = load8_u(100)*256 + load8_u(200) = 0xAB*256 + 0xDE = 171*256 + 222 = 43998.
  @bulk_memory_wasm <<0, 97, 115, 109, 1, 0, 0, 0, 1, 5, 1, 96, 0, 1, 127, 3, 2, 1, 0, 5, 3, 1, 0,
                      1, 7, 13, 2, 3, 109, 101, 109, 2, 0, 3, 114, 117, 110, 0, 0, 12, 1, 1, 10,
                      56, 1, 54, 0, 65, 0, 65, 171, 1, 65, 16, 252, 11, 0, 65, 228, 0, 65, 0, 65,
                      16, 252, 10, 0, 0, 65, 200, 1, 65, 0, 65, 4, 252, 8, 0, 0, 252, 9, 0, 65,
                      228, 0, 45, 0, 0, 65, 128, 2, 108, 65, 200, 1, 45, 0, 0, 106, 11, 11, 7, 1,
                      1, 4, 222, 173, 190, 239>>

  describe "disasm/1" do
    test "parses a minimal add module" do
      assert {:ok, %Module{} = mod} = WASM.disasm(@add_wasm)
      assert mod.version == 1
      assert length(mod.types) == 1
      assert hd(mod.types) == %{params: [:i32, :i32], results: [:i32]}
      assert length(mod.functions) == 1

      [func] = mod.functions
      assert %Function{} = func
      assert func.index == 0
      assert func.type_idx == 0
      assert func.params == [:i32, :i32]
      assert func.results == [:i32]
      assert func.locals == []

      assert func.opcodes == [
               {0, :local_get, 0},
               {2, :local_get, 1},
               {4, :i32_add},
               {5, :end}
             ]
    end

    test "parses exports" do
      {:ok, mod} = WASM.disasm(@add_wasm)
      assert [%{name: "add", kind: :func, index: 0}] = mod.exports
    end

    test "parses imports" do
      {:ok, mod} = WASM.disasm(@import_wasm)
      assert [%{module: "env", name: "log", kind: :func, type_idx: 0}] = mod.imports
    end

    test "function indices account for imports" do
      {:ok, mod} = WASM.disasm(@import_wasm)
      [func] = mod.functions
      assert func.index == 1
    end

    test "parses memory section" do
      {:ok, mod} = WASM.disasm(@memory_wasm)
      assert [%{min: 1, max: nil}] = mod.memories
    end

    test "parses global section" do
      {:ok, mod} = WASM.disasm(@memory_wasm)
      assert [%{type: :i32, mutable: true}] = mod.globals
    end

    test "parses data segments" do
      {:ok, mod} = WASM.disasm(@memory_wasm)
      assert [%{memory_idx: 0, bytes: "Hello"}] = mod.data
    end

    test "opcodes use {offset, name, ...operands} tuples" do
      {:ok, mod} = WASM.disasm(@import_wasm)
      [func] = mod.functions

      assert func.opcodes == [
               {0, :local_get, 0},
               {2, :call, 0},
               {4, :end}
             ]
    end
  end

  describe "validate/1" do
    test "valid WASM returns true" do
      assert WASM.validate(@add_wasm) == true
    end

    test "invalid binary returns false" do
      assert WASM.validate("not wasm") == false
      assert WASM.validate(<<>>) == false
    end

    test "truncated WASM returns false" do
      assert WASM.validate(binary_part(@add_wasm, 0, 10)) == false
    end
  end

  describe "exports/1" do
    test "from binary" do
      exports = WASM.exports(@add_wasm)
      assert [%{name: "add", kind: :func, index: 0}] = exports
    end

    test "from parsed module" do
      {:ok, mod} = WASM.disasm(@add_wasm)
      assert [%{name: "add", kind: :func, index: 0}] = WASM.exports(mod)
    end

    test "returns error for invalid binary" do
      assert {:error, _} = WASM.exports("garbage")
    end
  end

  describe "imports/1" do
    test "from binary" do
      imports = WASM.imports(@import_wasm)
      assert [%{module: "env", name: "log", kind: :func}] = imports
    end

    test "empty imports" do
      assert [] = WASM.imports(@add_wasm)
    end
  end

  describe "start + call + stop" do
    test "start and call add function" do
      {:ok, pid} = WASM.start(module: @add_wasm)
      {:ok, 42} = WASM.call(pid, "add", [40, 2])
      WASM.stop(pid)
    end

    test "start returns error for invalid binary" do
      Process.flag(:trap_exit, true)
      assert {:error, _} = WASM.start(module: "not wasm")
    end

    test "call returns error for missing function" do
      {:ok, pid} = WASM.start(module: @add_wasm)
      {:error, msg} = WASM.call(pid, "nonexistent", [])
      assert msg =~ "not found"
      WASM.stop(pid)
    end

    test "multiple calls on same instance" do
      {:ok, pid} = WASM.start(module: @add_wasm)
      {:ok, 3} = WASM.call(pid, "add", [1, 2])
      {:ok, 100} = WASM.call(pid, "add", [75, 25])
      {:ok, 0} = WASM.call(pid, "add", [0, 0])
      WASM.stop(pid)
    end

    test "supports i64 parameters and results" do
      {:ok, pid} = WASM.start(module: @add_i64_wasm)
      {:ok, 42} = WASM.call(pid, "add64", [40, 2])
      WASM.stop(pid)
    end

    test "supports floating point parameters and results" do
      {:ok, pid} = WASM.start(module: @add_f64_wasm)
      {:ok, result} = WASM.call(pid, "addf64", [1.5, 2.25])
      assert_in_delta result, 3.75, 1.0e-6
      WASM.stop(pid)
    end

    test "named instance" do
      {:ok, _} = WASM.start(module: @add_wasm, name: :wasm_add_test)
      {:ok, 42} = WASM.call(:wasm_add_test, "add", [40, 2])
      WASM.stop(:wasm_add_test)
    end
  end

  describe "memory" do
    test "write_memory and read back" do
      {:ok, pid} = WASM.start(module: @memory_func_wasm)
      :ok = WASM.write_memory(pid, 100, "world")
      {:ok, "world"} = WASM.read_memory(pid, 100, 5)
      WASM.stop(pid)
    end

    test "memory_size returns bytes" do
      {:ok, pid} = WASM.start(module: @memory_func_wasm)
      {:ok, size} = WASM.memory_size(pid)
      assert size == 65_536
      WASM.stop(pid)
    end

    test "read out of bounds returns error" do
      {:ok, pid} = WASM.start(module: @memory_func_wasm)
      {:error, _} = WASM.read_memory(pid, 65_530, 100)
      WASM.stop(pid)
    end
  end

  describe "bulk memory opcodes (WASM_ENABLE_BULK_MEMORY_OPT)" do
    test "runs memory.fill/copy/init + data.drop (fc 08–0b)" do
      # run() = load8_u(100)*256 + load8_u(200) after fill→copy→init→data.drop.
      # Without WASM_ENABLE_BULK_MEMORY_OPT this module fails to compile with
      # "unsupported opcode fc 0a".
      {:ok, pid} = WASM.start(module: @bulk_memory_wasm)
      assert {:ok, 43_998} = WASM.call(pid, "run", [])
      WASM.stop(pid)
    end
  end

  describe "supervision" do
    test "child_spec works" do
      spec = QuickBEAM.WASM.child_spec(name: :test_wasm, module: @add_wasm)
      assert spec.id == :test_wasm
    end

    test "works in a supervisor" do
      children = [
        {QuickBEAM.WASM, name: :supervised_add, module: @add_wasm, id: :supervised_add}
      ]

      {:ok, sup} = Supervisor.start_link(children, strategy: :one_for_one)
      {:ok, 42} = WASM.call(:supervised_add, "add", [40, 2])
      Supervisor.stop(sup)
    end
  end

  describe "JS WebAssembly API" do
    setup do
      {:ok, rt} = QuickBEAM.start()
      %{rt: rt}
    end

    @wasm_js_bytes """
    new Uint8Array([
      0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
      0x01, 0x07, 0x01, 0x60, 0x02, 0x7f, 0x7f, 0x01, 0x7f,
      0x03, 0x02, 0x01, 0x00,
      0x07, 0x07, 0x01, 0x03, 0x61, 0x64, 0x64, 0x00, 0x00,
      0x0a, 0x09, 0x01, 0x07, 0x00, 0x20, 0x00, 0x20, 0x01, 0x6a, 0x0b
    ])
    """

    test "WebAssembly.instantiate with buffer", %{rt: rt} do
      {:ok, 42} =
        QuickBEAM.eval(rt, """
          const bytes = #{@wasm_js_bytes};
          const {instance} = await WebAssembly.instantiate(bytes);
          instance.exports.add(40, 2);
        """)
    end

    # The tests below prove the JS `WebAssembly.instantiate` path honors the
    # runtime/pool `:wasm_stack_size` by reusing the `add` guest above
    # (`@wasm_js_bytes`): a tiny operand stack makes its very first call overflow,
    # a generous one lets it run. The probe is the *contrast* between stack sizes,
    # not a deep guest.
    #
    # Why a too-small stack rather than a deep-recursion guest: under the Debug
    # build (MIX_ENV=test => Zig UBSan on the vendored WAMR C), executing a guest
    # whose call frame lands a `WASMBranchBlock` on WAMR's 4-byte-aligned
    # `csp_bottom` trips a UBSan alignment trap and aborts the BEAM instead of
    # raising a catchable error — a pre-existing WAMR/UBSan interaction unrelated
    # to this feature. A too-small stack instead overflows at frame *allocation*
    # (`wasm_exec_env_alloc_wasm_frame` returns NULL => "wasm operand stack
    # overflow") before any branch block is touched, so it fails safely, and the
    # generous-stack path reuses a guest the existing suite already runs cleanly.
    @tiny_wasm_stack 32

    test "JS instantiate path overflows a too-small :wasm_stack_size" do
      {:ok, rt} = QuickBEAM.start(wasm_stack_size: @tiny_wasm_stack)

      {:error, err} =
        QuickBEAM.eval(rt, """
          const bytes = #{@wasm_js_bytes};
          const {instance} = await WebAssembly.instantiate(bytes);
          instance.exports.add(40, 2);
        """)

      assert err.message =~ "stack"

      QuickBEAM.stop(rt)
    end

    test "JS instantiate path honors a raised :wasm_stack_size" do
      {:ok, rt} = QuickBEAM.start(wasm_stack_size: 8 * 1024 * 1024)

      assert {:ok, 42} =
               QuickBEAM.eval(rt, """
                 const bytes = #{@wasm_js_bytes};
                 const {instance} = await WebAssembly.instantiate(bytes);
                 instance.exports.add(40, 2);
               """)

      QuickBEAM.stop(rt)
    end

    test "ContextPool propagates :wasm_stack_size to the pooled JS instantiate path" do
      # Exercises the pool threading path (PoolData -> RuntimeData copy in
      # context_worker), which the standalone QuickBEAM.start/1 test above does
      # not cover. The tiny-stack pool below proves the pooled context applies the
      # value rather than silently keeping the 64 KB default.
      {:ok, big_pool} =
        QuickBEAM.ContextPool.start_link(size: 1, wasm_stack_size: 8 * 1024 * 1024)

      {:ok, big_ctx} = QuickBEAM.Context.start_link(pool: big_pool)

      assert {:ok, 42} =
               QuickBEAM.Context.eval(big_ctx, """
                 const bytes = #{@wasm_js_bytes};
                 const {instance} = await WebAssembly.instantiate(bytes);
                 instance.exports.add(40, 2);
               """)

      QuickBEAM.Context.stop(big_ctx)

      {:ok, tiny_pool} =
        QuickBEAM.ContextPool.start_link(size: 1, wasm_stack_size: @tiny_wasm_stack)

      {:ok, tiny_ctx} = QuickBEAM.Context.start_link(pool: tiny_pool)

      {:error, err} =
        QuickBEAM.Context.eval(tiny_ctx, """
          const bytes = #{@wasm_js_bytes};
          const {instance} = await WebAssembly.instantiate(bytes);
          instance.exports.add(40, 2);
        """)

      assert err.message =~ "stack"

      QuickBEAM.Context.stop(tiny_ctx)
    end

    test "JS instantiate path accepts a custom :wasm_heap_size" do
      {:ok, rt} = QuickBEAM.start(wasm_heap_size: 128 * 1024)

      assert {:ok, 42} =
               QuickBEAM.eval(rt, """
                 const bytes = #{@wasm_js_bytes};
                 const {instance} = await WebAssembly.instantiate(bytes);
                 instance.exports.add(40, 2);
               """)

      QuickBEAM.stop(rt)
    end

    test "ContextPool propagates :wasm_heap_size to pooled JS instantiate contexts" do
      {:ok, pool} = QuickBEAM.ContextPool.start_link(size: 1, wasm_heap_size: 128 * 1024)
      {:ok, ctx} = QuickBEAM.Context.start_link(pool: pool)

      assert {:ok, 42} =
               QuickBEAM.Context.eval(ctx, """
                 const bytes = #{@wasm_js_bytes};
                 const {instance} = await WebAssembly.instantiate(bytes);
                 instance.exports.add(40, 2);
               """)

      QuickBEAM.Context.stop(ctx)
    end

    # No behavioral test for the sibling `:wasm_heap_size` option beyond accepting
    # a custom value in both start paths above: it has no effect that the JS
    # `WebAssembly.instantiate` path can observe, so any stronger test would pass
    # whether or not the value is honored (a false green). The value sizes WAMR's host
    # *app heap*, and on this path nothing reaches it:
    #   * The app heap only backs `wasm_runtime_module_malloc` / a guest-exported
    #     malloc. A plain instantiated module called from JS never allocates from it.
    #   * It cannot fail instantiation: WAMR clamps it to APP_HEAP_SIZE_MAX (1 GiB,
    #     wasm_runtime.c ~2451) and the insertion guards only trip near UINT32_MAX
    #     or >DEFAULT_MAX_PAGES, unreachable after the clamp.
    #   * It is not visible as memory size: `memory.buffer.byteLength` reports the
    #     app-visible page count (`cur_page_count * 65536`), which excludes the
    #     appended app heap — see "WebAssembly exposes exported memory" below, where
    #     the default 64 KiB heap still yields byteLength 65536, not 131072.
    # `:wasm_stack_size` is observable (tiny stack => first call overflows), hence
    # tested above; `:wasm_heap_size` is covered only at the plumbing level.

    test "WebAssembly.compile + instantiate", %{rt: rt} do
      {:ok, 300} =
        QuickBEAM.eval(rt, """
          const bytes = #{@wasm_js_bytes};
          const mod = await WebAssembly.compile(bytes);
          const inst = await WebAssembly.instantiate(mod);
          inst.exports.add(100, 200);
        """)
    end

    test "WebAssembly.validate", %{rt: rt} do
      {:ok, true} =
        QuickBEAM.eval(rt, """
          WebAssembly.validate(#{@wasm_js_bytes});
        """)

      {:ok, false} =
        QuickBEAM.eval(rt, """
          WebAssembly.validate(new Uint8Array([0, 0, 0, 0]));
        """)
    end

    test "WebAssembly.Module.exports", %{rt: rt} do
      {:ok, result} =
        QuickBEAM.eval(rt, """
          const mod = new WebAssembly.Module(#{@wasm_js_bytes});
          WebAssembly.Module.exports(mod);
        """)

      assert [
               %{
                 "kind" => "function",
                 "name" => "add",
                 "params" => ["i32", "i32"],
                 "results" => ["i32"]
               }
             ] = result
    end

    test "WebAssembly.Module.imports", %{rt: rt} do
      {:ok, result} =
        QuickBEAM.eval(rt, """
          const mod = new WebAssembly.Module(new Uint8Array([
            0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
            0x01, 0x09, 0x02, 0x60, 0x01, 0x7f, 0x00, 0x60, 0x01, 0x7f, 0x00,
            0x02, 0x0b, 0x01, 0x03, 0x65, 0x6e, 0x76, 0x03, 0x6c, 0x6f, 0x67, 0x00, 0x00,
            0x03, 0x02, 0x01, 0x01,
            0x07, 0x07, 0x01, 0x03, 0x72, 0x75, 0x6e, 0x00, 0x01,
            0x0a, 0x08, 0x01, 0x06, 0x00, 0x20, 0x00, 0x10, 0x00, 0x0b
          ]));
          WebAssembly.Module.imports(mod);
        """)

      assert [
               %{
                 "kind" => "function",
                 "module" => "env",
                 "name" => "log",
                 "params" => ["i32"],
                 "results" => []
               }
             ] = result
    end

    test "new WebAssembly.Module + Instance", %{rt: rt} do
      {:ok, 7} =
        QuickBEAM.eval(rt, """
          const mod = new WebAssembly.Module(#{@wasm_js_bytes});
          const inst = new WebAssembly.Instance(mod);
          inst.exports.add(3, 4);
        """)
    end

    test "WebAssembly.CompileError on invalid bytes", %{rt: rt} do
      {:error, err} =
        QuickBEAM.eval(rt, """
          await WebAssembly.compile(new Uint8Array([0, 0, 0, 0]));
        """)

      assert err.name == "CompileError"
    end

    test "multiple instances from same module", %{rt: rt} do
      {:ok, result} =
        QuickBEAM.eval(rt, """
          const bytes = #{@wasm_js_bytes};
          const mod = await WebAssembly.compile(bytes);
          const i1 = await WebAssembly.instantiate(mod);
          const i2 = await WebAssembly.instantiate(mod);
          [i1.exports.add(1, 2), i2.exports.add(10, 20)];
        """)

      assert result == [3, 30]
    end

    test "WebAssembly exports i64 values as BigInt", %{rt: rt} do
      {:ok, true} =
        QuickBEAM.eval(rt, """
          const bytes = new Uint8Array([
            0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
            0x01, 0x07, 0x01, 0x60, 0x02, 0x7e, 0x7e, 0x01, 0x7e,
            0x03, 0x02, 0x01, 0x00,
            0x07, 0x09, 0x01, 0x05, 0x61, 0x64, 0x64, 0x36, 0x34, 0x00, 0x00,
            0x0a, 0x09, 0x01, 0x07, 0x00, 0x20, 0x00, 0x20, 0x01, 0x7c, 0x0b
          ]);
          const {instance} = await WebAssembly.instantiate(bytes);
          const result = instance.exports.add64(40n, 2n);
          typeof result === 'bigint' && result === 42n;
        """)
    end

    test "WebAssembly exports floating point values", %{rt: rt} do
      {:ok, result} =
        QuickBEAM.eval(rt, """
          const bytes = new Uint8Array([
            0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
            0x01, 0x07, 0x01, 0x60, 0x02, 0x7c, 0x7c, 0x01, 0x7c,
            0x03, 0x02, 0x01, 0x00,
            0x07, 0x0a, 0x01, 0x06, 0x61, 0x64, 0x64, 0x66, 0x36, 0x34, 0x00, 0x00,
            0x0a, 0x09, 0x01, 0x07, 0x00, 0x20, 0x00, 0x20, 0x01, 0xa0, 0x0b
          ]);
          const {instance} = await WebAssembly.instantiate(bytes);
          instance.exports.addf64(1.5, 2.25);
        """)

      assert_in_delta result, 3.75, 1.0e-6
    end

    test "WebAssembly exposes exported memory", %{rt: rt} do
      {:ok, 65_536} =
        QuickBEAM.eval(rt, """
          const bytes = new Uint8Array([
            0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
            0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f,
            0x03, 0x02, 0x01, 0x00,
            0x05, 0x03, 0x01, 0x00, 0x01,
            0x07, 0x10, 0x02, 0x06, 0x6d, 0x65, 0x6d, 0x6f, 0x72, 0x79, 0x02, 0x00, 0x03, 0x67, 0x65, 0x74, 0x00, 0x00,
            0x0a, 0x06, 0x01, 0x04, 0x00, 0x41, 0x00, 0x0b
          ]);
          const {instance} = await WebAssembly.instantiate(bytes);
          instance.exports.memory.buffer.byteLength;
        """)
    end

    test "WebAssembly.instantiate imports immutable globals", %{rt: rt} do
      {:ok, result} =
        QuickBEAM.eval(rt, """
          const bytes = new Uint8Array([#{Enum.join(:binary.bin_to_list(@import_global_wasm), ", ")}]);
          const global = new WebAssembly.Global({value: 'i32'}, 42);
          const {instance} = await WebAssembly.instantiate(bytes, {env: {base: global}});
          [instance.exports.base === global, instance.exports.base.value];
        """)

      assert result == [true, 42]
    end

    test "WebAssembly.instantiate binds mutable imported globals", %{rt: rt} do
      {:ok, result} =
        QuickBEAM.eval(rt, """
          const bytes = new Uint8Array([#{Enum.join(:binary.bin_to_list(@import_mutable_global_wasm), ", ")}]);
          const global = new WebAssembly.Global({value: 'i32', mutable: true}, 42);
          const {instance} = await WebAssembly.instantiate(bytes, {env: {base: global}});
          global.value = 7;
          [instance.exports.base === global, instance.exports.base.value, global.value];
        """)

      assert result == [true, 7, 7]
    end

    test "WebAssembly.instantiate imports functions", %{rt: rt} do
      {:ok, 42} =
        QuickBEAM.eval(rt, """
          const bytes = new Uint8Array([#{Enum.join(:binary.bin_to_list(@import_func_wasm), ", ")}]);
          const {instance} = await WebAssembly.instantiate(bytes, {env: {log(value) { return value + 1 }}});
          instance.exports.run(41);
        """)
    end

    test "WebAssembly.instantiate imports async functions", %{rt: rt} do
      {:ok, 42} =
        QuickBEAM.eval(rt, """
          const bytes = new Uint8Array([#{Enum.join(:binary.bin_to_list(@import_func_wasm), ", ")}]);
          const {instance} = await WebAssembly.instantiate(bytes, {env: {async log(value) { return value + 1 }}});
          instance.exports.run(41);
        """)
    end

    test "WebAssembly.instantiate imports memories", %{rt: rt} do
      {:ok, result} =
        QuickBEAM.eval(rt, """
          const bytes = new Uint8Array([#{Enum.join(:binary.bin_to_list(@import_memory_wasm), ", ")}]);
          const memory = new WebAssembly.Memory({initial: 1, maximum: 1});
          new Uint8Array(memory.buffer)[0] = 65;
          const {instance} = await WebAssembly.instantiate(bytes, {env: {memory}});
          [instance.exports.memory === memory, new Uint8Array(memory.buffer)[0]];
        """)

      assert result == [true, 65]
    end

    test "WebAssembly.instantiate rejects non-function imports", %{rt: rt} do
      {:error, err} =
        QuickBEAM.eval(rt, """
          const bytes = new Uint8Array([
            0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
            0x01, 0x09, 0x02, 0x60, 0x01, 0x7f, 0x00, 0x60, 0x01, 0x7f, 0x00,
            0x02, 0x0b, 0x01, 0x03, 0x65, 0x6e, 0x76, 0x03, 0x6c, 0x6f, 0x67, 0x00, 0x00,
            0x03, 0x02, 0x01, 0x01,
            0x07, 0x07, 0x01, 0x03, 0x72, 0x75, 0x6e, 0x00, 0x01,
            0x0a, 0x08, 0x01, 0x06, 0x00, 0x20, 0x00, 0x10, 0x00, 0x0b
          ]);
          await WebAssembly.instantiate(bytes, {env: {log: {}}});
        """)

      assert err.name == "TypeError"
    end

    test "WebAssembly.Module.customSections", %{rt: rt} do
      {:ok, result} =
        QuickBEAM.eval(rt, """
          const mod = new WebAssembly.Module(new Uint8Array([#{Enum.join(:binary.bin_to_list(@custom_section_wasm), ", ")} ]));
          WebAssembly.Module.customSections(mod, 'meta').map((section) => new TextDecoder().decode(section));
        """)

      assert result == ["abc"]
    end

    test "WebAssembly.instantiate compiles bulk-memory opcodes (memory.copy, fc 0a)", %{rt: rt} do
      {:ok, 43_998} =
        QuickBEAM.eval(rt, """
          const bytes = new Uint8Array([#{Enum.join(:binary.bin_to_list(@bulk_memory_wasm), ", ")}]);
          const {instance} = await WebAssembly.instantiate(bytes);
          instance.exports.run();
        """)
    end

    test "WebAssembly.compileStreaming", %{rt: rt} do
      {:ok, result} =
        QuickBEAM.eval(rt, """
          const response = { arrayBuffer: async () => #{@wasm_js_bytes}.buffer };
          const mod = await WebAssembly.compileStreaming(response);
          WebAssembly.Module.exports(mod)[0].name;
        """)

      assert result == "add"
    end

    test "WebAssembly.instantiateStreaming", %{rt: rt} do
      {:ok, result} =
        QuickBEAM.eval(rt, """
          const response = { arrayBuffer: async () => #{@wasm_js_bytes}.buffer };
          const {instance} = await WebAssembly.instantiateStreaming(response);
          instance.exports.add(5, 6);
        """)

      assert result == 11
    end
  end

  describe "live Memory.buffer + TextDecoder DataView (Go-wasm host memory)" do
    setup do
      {:ok, rt} = QuickBEAM.start()
      %{rt: rt}
    end

    # (module
    #   (import "env" "fill" (func $fill (param i32)))
    #   (memory (export "mem") 1)
    #   (func (export "test") (result i32)
    #     (call $fill (i32.const 16))   ;; host writes at mem[16] via mem.buffer
    #     (i32.load (i32.const 16))))   ;; guest reads it back
    @memwrite_bytes """
    new Uint8Array([
      0,97,115,109,1,0,0,0,1,9,2,96,1,127,0,96,0,1,127,2,12,1,3,101,110,118,
      4,102,105,108,108,0,0,3,2,1,1,5,3,1,0,1,7,14,2,3,109,101,109,2,0,4,116,
      101,115,116,0,1,10,13,1,11,0,65,16,16,0,65,16,40,2,0,11
    ])
    """

    # (module
    #   (import "env" "capture" (func $capture))   ;; host grabs mem.buffer
    #   (import "env" "check"   (func $check))      ;; host re-entry after grow
    #   (memory (export "mem") 1)
    #   (func (export "test")
    #     (call $capture)                  ;; capture mem.buffer (pre-grow)
    #     (drop (memory.grow (i32.const 1)));; grow → backing store moves
    #     (call $check)))                  ;; host re-entry; alias must be detached
    @reentry_bytes """
    new Uint8Array([
      0,97,115,109,1,0,0,0,1,4,1,96,0,0,2,27,2,3,101,110,118,7,99,97,112,116,
      117,114,101,0,0,3,101,110,118,5,99,104,101,99,107,0,0,3,2,1,0,5,3,1,0,1,
      7,14,2,3,109,101,109,2,0,4,116,101,115,116,0,2,10,13,1,11,0,16,0,65,1,64,
      0,26,16,1,11
    ])
    """

    # (module (memory (export "mem") 0))  ;; zero-page memory
    @zeropage_bytes """
    new Uint8Array([0,97,115,109,1,0,0,0,5,3,1,0,0,7,7,1,3,109,101,109,2,0])
    """

    test "host writes through Memory.buffer DataView are visible to the guest", %{rt: rt} do
      # The import callback writes 123456 at mem[16] via new DataView(mem.buffer);
      # the guest then i32.load's mem[16]. A copy-based buffer would read 0.
      assert {:ok, 123_456} =
               QuickBEAM.eval(rt, """
                 const bytes = #{@memwrite_bytes};
                 const holder = {};
                 const imp = { env: { fill: (ptr) => {
                   new DataView(holder.inst.exports.mem.buffer).setInt32(ptr, 123456, true);
                 }}};
                 const { instance } = await WebAssembly.instantiate(bytes, imp);
                 holder.inst = instance;
                 instance.exports.test();
               """)
    end

    test "Memory.buffer has stable identity until grow", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
                 const bytes = #{@memwrite_bytes};
                 const { instance } = await WebAssembly.instantiate(bytes, {env: {fill() {}}});
                 instance.exports.mem.buffer === instance.exports.mem.buffer;
               """)
    end

    test "memory.grow detaches the old buffer; a fresh buffer reflects the new size", %{rt: rt} do
      # Browser detach-on-grow: after grow the previously handed-out buffer is
      # detached (byteLength 0) and a fresh alias reflects the grown memory.
      assert {:ok, [65_536, 0, 131_072, true]} =
               QuickBEAM.eval(rt, """
                 const bytes = #{@memwrite_bytes};
                 const { instance } = await WebAssembly.instantiate(bytes, {env: {fill() {}}});
                 const mem = instance.exports.mem;
                 const buf0 = mem.buffer;
                 const before = buf0.byteLength;
                 mem.grow(1);
                 const detached = buf0.byteLength;
                 const buf1 = mem.buffer;
                 [before, detached, buf1.byteLength, buf0 !== buf1];
               """)
    end

    test "memory.grow(0) still detaches the buffer (browser-faithful)", %{rt: rt} do
      # Browsers detach on EVERY grow call, including a no-op grow(0) where the
      # backing store neither moves nor resizes.
      assert {:ok, [0, 65_536, true]} =
               QuickBEAM.eval(rt, """
                 const bytes = #{@memwrite_bytes};
                 const { instance } = await WebAssembly.instantiate(bytes, {env: {fill() {}}});
                 const mem = instance.exports.mem;
                 const buf0 = mem.buffer;
                 mem.grow(0);
                 const buf1 = mem.buffer;
                 [buf0.byteLength, buf1.byteLength, buf0 !== buf1];
               """)
    end

    test "a buffer captured before an in-call grow is detached at the next host re-entry", %{rt: rt} do
      # test() calls capture (host grabs mem.buffer), then grows memory, then
      # calls check (a second host re-entry) — all within one guest call. The
      # fix detaches the moved alias at the host-import boundary, so the captured
      # buffer reads byteLength 0 by the time check runs (instead of aliasing
      # freed/moved memory, as Go's wasm_exec.js cached DataView would).
      assert {:ok, [65_536, 0]} =
               QuickBEAM.eval(rt, """
                 const bytes = #{@reentry_bytes};
                 const holder = {};
                 const imp = { env: {
                   capture: () => { holder.buf = holder.inst.exports.mem.buffer; holder.before = holder.buf.byteLength; },
                   check:   () => { holder.after = holder.buf.byteLength; },
                 }};
                 const { instance } = await WebAssembly.instantiate(bytes, imp);
                 holder.inst = instance;
                 instance.exports.test();
                 [holder.before, holder.after];
               """)
    end

    test "zero-page memory exposes a stable 0-length buffer instead of throwing", %{rt: rt} do
      # The 0-length buffer must also honor the stable-identity contract:
      # repeated `.buffer` access returns the SAME object (browser-faithful),
      # so the empty buffer is cached like a live alias, not re-minted per call.
      assert {:ok, [true, 0]} =
               QuickBEAM.eval(rt, """
                 const bytes = #{@zeropage_bytes};
                 const { instance } = await WebAssembly.instantiate(bytes);
                 const a = instance.exports.mem.buffer;
                 const b = instance.exports.mem.buffer;
                 [a === b, a.byteLength];
               """)
    end

    test "growing zero-page memory replaces the cached empty buffer with a live alias", %{rt: rt} do
      # The cached 0-length buffer must be invalidated on a 0 -> N grow: the
      # pre-grow object is no longer returned, and a fresh stably-cached alias
      # of the grown size takes its place. Exercises the zero-page cache's
      # detach-on-grow path (the live-alias detach itself is covered above for
      # non-zero memory; here byteLength-0 is degenerate, so we assert via
      # object identity + the grown size).
      assert {:ok, [true, true, 65_536, true]} =
               QuickBEAM.eval(rt, """
                 const bytes = #{@zeropage_bytes};
                 const { instance } = await WebAssembly.instantiate(bytes);
                 const mem = instance.exports.mem;
                 const buf0 = mem.buffer;
                 const stableBefore = buf0 === mem.buffer;
                 mem.grow(1);
                 const buf1 = mem.buffer;
                 [stableBefore, buf0 !== buf1, buf1.byteLength, buf1 === mem.buffer];
               """)
    end

    test "TextDecoder.decode accepts a DataView, including a non-zero byteOffset", %{rt: rt} do
      assert {:ok, "ello"} =
               QuickBEAM.eval(rt, """
                 const buf = new Uint8Array([72, 101, 108, 108, 111]).buffer;
                 new TextDecoder().decode(new DataView(buf, 1, 4));
               """)
    end
  end

  describe "edge cases" do
    test "empty module" do
      wasm = <<0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00>>
      assert {:ok, %Module{functions: [], exports: [], imports: []}} = WASM.disasm(wasm)
    end

    test "wrong magic" do
      assert {:error, "not a WASM binary" <> _} = WASM.disasm(<<0xFF, 0xFF, 0xFF, 0xFF>>)
    end

    test "unsupported version" do
      assert {:error, "unsupported WASM version" <> _} =
               WASM.disasm(<<0x00, 0x61, 0x73, 0x6D, 0x02, 0x00, 0x00, 0x00>>)
    end
  end
end
