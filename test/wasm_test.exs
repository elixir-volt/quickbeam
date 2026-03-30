defmodule QuickBEAM.WASMTest do
  use ExUnit.Case, async: true

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

  # Module with memory, global, and data segment
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
