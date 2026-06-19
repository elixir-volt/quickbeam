defmodule QuickBEAM.VM.Compiler.LoweringRegistryTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.VM.Compiler.Lowering.Ops.{
    Arithmetic,
    Calls,
    Classes,
    Control,
    Generators,
    Globals,
    Iterators,
    Locals,
    Objects,
    Stack,
    WithScope
  }

  alias QuickBEAM.VM.OpcodeSpec

  test "stack handlers match stack lowering family" do
    assert_registered_family(Stack.registered_opcodes(), :stack)
  end

  test "local handlers match locals lowering family" do
    assert_registered_family(Locals.registered_opcodes(), :locals)
  end

  test "arithmetic handlers match arithmetic lowering family" do
    assert_registered_family(Arithmetic.registered_opcodes(), :arithmetic)
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

  test "class handlers match classes lowering family" do
    assert_registered_family(Classes.registered_opcodes(), :classes)
  end

  test "generator handlers match generators lowering family" do
    assert_registered_family(Generators.registered_opcodes(), :generators)
  end

  test "control handlers match control lowering family" do
    assert_registered_family(Control.registered_opcodes(), :control)
  end

  test "with-scope handlers match with-scope lowering family" do
    assert_registered_family(WithScope.registered_opcodes(), :with_scope)
  end

  test "global handlers match globals lowering family" do
    assert_registered_family(Globals.registered_opcodes(), :globals)
  end

  test "every lowered opcode has one registered handler" do
    registered = all_registered_opcodes()

    missing =
      for {name, _num} <- OpcodeSpec.all_opcodes(),
          family = OpcodeSpec.lowering_family(name),
          family != nil,
          not MapSet.member?(registered, name),
          do: {name, family}

    assert missing == []
  end

  test "opcode specs point registered handlers at their lowering modules" do
    mismatches =
      registered_modules()
      |> Enum.flat_map(fn module ->
        module.registered_opcodes()
        |> Enum.flat_map(fn opcode ->
          case OpcodeSpec.opcode(opcode) do
            {:ok, spec} -> [{opcode, spec.lowering_module, module}]
            :error -> []
          end
        end)
      end)
      |> Enum.reject(fn {_opcode, expected, actual} -> expected == actual end)

    assert mismatches == []
  end

  test "lowering handlers are unique across families" do
    registered =
      registered_modules()
      |> Enum.flat_map(fn module ->
        Enum.map(module.registered_opcodes(), &{&1, module})
      end)

    duplicates =
      registered
      |> Enum.frequencies_by(&elem(&1, 0))
      |> Enum.filter(fn {_opcode, count} -> count > 1 end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    assert duplicates == []
  end

  defp assert_registered_family(opcodes, family) do
    unexpected =
      opcodes
      |> Enum.reject(&(OpcodeSpec.lowering_family(&1) == family))
      |> Enum.sort()

    assert unexpected == []
    assert Enum.sort(opcodes) == Enum.uniq(Enum.sort(opcodes))
  end

  defp all_registered_opcodes do
    registered_modules()
    |> Enum.flat_map(& &1.registered_opcodes())
    |> MapSet.new()
  end

  defp registered_modules do
    [
      Stack,
      Locals,
      Globals,
      Arithmetic,
      Objects,
      Calls,
      Control,
      Iterators,
      Classes,
      Generators,
      WithScope
    ]
  end
end
