defmodule QuickBEAM.VM.ABITest do
  use ExUnit.Case, async: true

  alias QuickBEAM.VM.{ABI, Opcodes}

  test "metadata is generated from the current vendored QuickJS sources" do
    assert ABI.bytecode_version() == 26
    assert byte_size(ABI.fingerprint()) == 64
    assert Opcodes.bc_version() == ABI.bytecode_version()
    assert Opcodes.num(:check_object) != nil
    assert Opcodes.num(:using_dispose) != nil
    assert Opcodes.info(Opcodes.num(:await)) == {:await, 1, 1, 1, :none}
  end

  test "predefined atom indexes include QuickJS v26 additions" do
    atoms = ABI.predefined_atoms()

    assert "using" in Map.values(atoms)
    assert "Symbol.dispose" in Map.values(atoms)
    assert Opcodes.js_atom_end() == map_size(atoms) + 1
  end
end
