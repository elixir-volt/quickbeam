defmodule QuickBEAM.VM.Compiler.LoweringRegistryTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.VM.Compiler.Lowering.Ops.{
    Arithmetic,
    Calls,
    Globals,
    Iterators,
    Locals,
    Objects,
    Stack
  }

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

  test "call handlers match calls lowering family" do
    assert_registered_family(Calls.registered_opcodes(), :calls)
  end

  test "iterator handlers match iterators lowering family" do
    assert_registered_family(Iterators.registered_opcodes(), :iterators)
  end

  test "global handlers match globals lowering family" do
    var_ref_opcodes =
      MapSet.new([
        :get_var_ref,
        :get_var_ref0,
        :get_var_ref1,
        :get_var_ref2,
        :get_var_ref3,
        :get_var_ref_check,
        :put_var_ref,
        :put_var_ref0,
        :put_var_ref1,
        :put_var_ref2,
        :put_var_ref3,
        :put_var_ref_check,
        :put_var_ref_check_init,
        :set_var_ref,
        :set_var_ref0,
        :set_var_ref1,
        :set_var_ref2,
        :set_var_ref3
      ])

    unexpected =
      Globals.registered_opcodes()
      |> Enum.reject(
        &(OpcodeSpec.lowering_family(&1) == :globals or MapSet.member?(var_ref_opcodes, &1))
      )
      |> Enum.sort()

    assert unexpected == []

    assert Enum.sort(Globals.registered_opcodes()) ==
             Enum.uniq(Enum.sort(Globals.registered_opcodes()))
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
