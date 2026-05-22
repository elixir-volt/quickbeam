defmodule QuickBEAM.VM.Compiler.LoweringRegistryTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.VM.Compiler.Lowering.Ops.{Arithmetic, Locals, Objects, Stack}
  alias QuickBEAM.VM.OpcodeSpec

  test "stack handlers match stack lowering family" do
    assert_registered_family(Stack.registered_opcodes(), :stack)
  end

  test "local handlers match locals lowering family" do
    assert_registered_family(Locals.registered_opcodes(), :locals)
  end

  test "arithmetic handlers match arithmetic lowering family" do
    aliases = %{band: :and, bxor: :xor, bor: :or}
    assert_registered_family(Arithmetic.registered_opcodes(), :arithmetic, aliases)
  end

  test "object handlers match object lowering family" do
    assert_registered_family(Objects.registered_opcodes(), :objects)
  end

  defp assert_registered_family(opcodes, family, aliases \\ %{}) do
    unexpected =
      opcodes
      |> Enum.reject(&(OpcodeSpec.lowering_family(Map.get(aliases, &1, &1)) == family))
      |> Enum.sort()

    assert unexpected == []
    assert Enum.sort(opcodes) == Enum.uniq(Enum.sort(opcodes))
  end
end
