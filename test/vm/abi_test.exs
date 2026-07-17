defmodule QuickBEAM.VM.ABITest do
  use ExUnit.Case, async: true

  alias QuickBEAM.VM.ABI
  alias QuickBEAM.VM.ABI.Generator
  alias QuickBEAM.VM.ABI.Source
  alias QuickBEAM.VM.Bytecode.Opcode

  test "metadata is generated from the current vendored QuickJS sources" do
    assert ABI.bytecode_version() == 26
    assert byte_size(ABI.fingerprint()) == 64
    assert Opcode.bc_version() == ABI.bytecode_version()
    assert Opcode.num(:check_object) != nil
    assert Opcode.num(:using_dispose) != nil
    assert Opcode.info(Opcode.num(:await)) == {:await, 1, 1, 1, :none}
  end

  test "parses exact C declarations with the bounded source parser" do
    source = """
    #define BC_VERSION 26
    typedef enum BCTagEnum {
      BC_TAG_NULL = 1,
      BC_TAG_UNDEFINED,
    } BCTagEnum;
    """

    assert Source.define!(source, "BC_VERSION") == "26"

    assert Source.enum_entries!(source, "BCTagEnum") == [
             "BC_TAG_NULL = 1",
             "BC_TAG_UNDEFINED"
           ]

    assert Source.macro_arguments(~S|DEF(name, "value,with,commas") /* comment */|, "DEF") == [
             ["name", ~s("value,with,commas")]
           ]
  end

  test "rejects unterminated C declarations" do
    assert_raise ArgumentError, fn -> Source.enum_entries!("typedef enum Broken {", "Broken") end
    assert_raise ArgumentError, fn -> Source.macro_arguments("DEF(name, value", "DEF") end
  end

  test "rejects unknown ABI identifiers without creating atoms" do
    source = """
    typedef enum BCTagEnum {
      BC_TAG_QUICKBEAM_UNKNOWN_IDENTIFIER = 1,
    } BCTagEnum;
    """

    identifier = "quickbeam_unknown_identifier"

    assert_raise ArgumentError, fn -> String.to_existing_atom(identifier) end
    assert_raise ArgumentError, ~r/unknown tag identifier/, fn -> Generator.tags!(source) end
    assert_raise ArgumentError, fn -> String.to_existing_atom(identifier) end
  end

  test "predefined atom indexes include QuickJS v26 additions" do
    atoms = ABI.predefined_atoms()

    assert "using" in Map.values(atoms)
    assert "Symbol.dispose" in Map.values(atoms)
    assert Opcode.js_atom_end() == map_size(atoms) + 1
  end
end
