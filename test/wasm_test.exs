defmodule QuickBEAM.WASMTest do
  use ExUnit.Case, async: false

  alias QuickBEAM.WASM
  alias QuickBEAM.WASM.{Module, Function}

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
    0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00,
    # Type section (id=1, 7 bytes)
    0x01, 0x07,
    # 1 type: (i32, i32) -> (i32)
    0x01, 0x60, 0x02, 0x7F, 0x7F, 0x01, 0x7F,
    # Function section (id=3, 2 bytes)
    0x03, 0x02,
    # 1 function, type index 0
    0x01, 0x00,
    # Export section (id=7, 7 bytes)
    0x07, 0x07,
    # 1 export: "add", func index 0
    0x01, 0x03, 0x61, 0x64, 0x64, 0x00, 0x00,
    # Code section (id=10, 9 bytes)
    0x0A, 0x09,
    # 1 body
    0x01,
    # body: 7 bytes
    0x07,
    # 0 local declarations
    0x00,
    # local.get 0, local.get 1, i32.add, end
    0x20, 0x00, 0x20, 0x01, 0x6A, 0x0B
  >>

  # Module with an import:
  #   (module
  #     (import "env" "log" (func (param i32)))
  #     (func (export "run") (param i32)
  #       local.get 0
  #       call 0))
  @import_wasm <<
    0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00,
    # Type section: 2 types
    0x01, 0x09,
    0x02,
    # type 0: (i32) -> ()
    0x60, 0x01, 0x7F, 0x00,
    # type 1: (i32) -> ()
    0x60, 0x01, 0x7F, 0x00,
    # Import section
    0x02, 0x0B,
    0x01,
    # "env"."log", func type 0
    0x03, 0x65, 0x6E, 0x76, 0x03, 0x6C, 0x6F, 0x67, 0x00, 0x00,
    # Function section
    0x03, 0x02,
    0x01, 0x01,
    # Export section: "run" -> func 1
    0x07, 0x07,
    0x01, 0x03, 0x72, 0x75, 0x6E, 0x00, 0x01,
    # Code section
    0x0A, 0x08,
    0x01,
    0x06,
    0x00,
    # local.get 0, call 0, end
    0x20, 0x00, 0x10, 0x00, 0x0B
  >>

  # Module with memory, global, and data segment (for parser tests)
  @memory_wasm <<
    0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00,
    # Type section: 0 types
    0x01, 0x01, 0x00,
    # Memory section: 1 memory, min=1, no max
    0x05, 0x03, 0x01, 0x00, 0x01,
    # Global section: 1 global, i32 mutable, init=42
    0x06, 0x06, 0x01, 0x7F, 0x01, 0x41, 0x2A, 0x0B,
    # Data section: "Hello"
    0x0B, 0x0B, 0x01,
    # active, memory 0, offset i32.const 0
    0x00, 0x41, 0x00, 0x0B,
    # 5 bytes: "Hello"
    0x05, 0x48, 0x65, 0x6C, 0x6C, 0x6F
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
  @memory_func_wasm (
    <<0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00>> <>
    # Type section: () -> (i32)
    <<0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7F>> <>
    # Function section: 1 func type 0
    <<0x03, 0x02, 0x01, 0x00>> <>
    # Memory section: 1 memory min=1
    <<0x05, 0x03, 0x01, 0x00, 0x01>> <>
    # Export section: "memory" mem 0, "get" func 0
    <<0x07, 0x10, 0x02,
      0x06>> <> "memory" <> <<0x02, 0x00,
      0x03>> <> "get" <> <<0x00, 0x00>> <>
    # Code section: i32.const 0, end
    <<0x0A, 0x06, 0x01, 0x04, 0x00, 0x41, 0x00, 0x0B>>
  )

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
      assert size == 65536
      WASM.stop(pid)
    end

    test "read out of bounds returns error" do
      {:ok, pid} = WASM.start(module: @memory_func_wasm)
      {:error, _} = WASM.read_memory(pid, 65530, 100)
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
      {:ok, 42} = QuickBEAM.eval(rt, """
        const bytes = #{@wasm_js_bytes};
        const {instance} = await WebAssembly.instantiate(bytes);
        instance.exports.add(40, 2);
      """)
    end

    test "WebAssembly.compile + instantiate", %{rt: rt} do
      {:ok, 300} = QuickBEAM.eval(rt, """
        const bytes = #{@wasm_js_bytes};
        const mod = await WebAssembly.compile(bytes);
        const inst = await WebAssembly.instantiate(mod);
        inst.exports.add(100, 200);
      """)
    end

    test "WebAssembly.validate", %{rt: rt} do
      {:ok, true} = QuickBEAM.eval(rt, """
        WebAssembly.validate(#{@wasm_js_bytes});
      """)

      {:ok, false} = QuickBEAM.eval(rt, """
        WebAssembly.validate(new Uint8Array([0, 0, 0, 0]));
      """)
    end

    test "WebAssembly.Module.exports", %{rt: rt} do
      {:ok, result} = QuickBEAM.eval(rt, """
        const mod = new WebAssembly.Module(#{@wasm_js_bytes});
        WebAssembly.Module.exports(mod);
      """)

      assert [%{"kind" => "function", "name" => "add"}] = result
    end

    test "new WebAssembly.Module + Instance", %{rt: rt} do
      {:ok, 7} = QuickBEAM.eval(rt, """
        const mod = new WebAssembly.Module(#{@wasm_js_bytes});
        const inst = new WebAssembly.Instance(mod);
        inst.exports.add(3, 4);
      """)
    end

    test "WebAssembly.CompileError on invalid bytes", %{rt: rt} do
      {:error, err} = QuickBEAM.eval(rt, """
        await WebAssembly.compile(new Uint8Array([0, 0, 0, 0]));
      """)

      assert err.name == "CompileError"
    end

    test "multiple instances from same module", %{rt: rt} do
      {:ok, result} = QuickBEAM.eval(rt, """
        const bytes = #{@wasm_js_bytes};
        const mod = await WebAssembly.compile(bytes);
        const i1 = await WebAssembly.instantiate(mod);
        const i2 = await WebAssembly.instantiate(mod);
        [i1.exports.add(1, 2), i2.exports.add(10, 20)];
      """)

      assert result == [3, 30]
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
