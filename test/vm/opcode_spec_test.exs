defmodule QuickBEAM.VM.OpcodeSpecTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.VM.{Opcodes, OpcodeSpec}

  test "short-form opcodes expand to canonical opcodes" do
    short_formats = MapSet.new([:none_loc, :none_arg, :none_var_ref, :none_int, :npopx])

    invalid =
      for {num, {name, _size, _pops, _pushes, format}} <- Opcodes.table(),
          MapSet.member?(short_formats, format),
          {canonical, _operands} = Opcodes.expand_short_form(name, [], 0),
          canonical != name,
          Opcodes.num(canonical) == nil,
          do: {num, name, canonical}

    assert invalid == []
  end

  test "every opcode row has format metadata" do
    missing =
      for {_num, {_name, _size, _pops, _pushes, format}} <- Opcodes.table(),
          Opcodes.format_info(format) == nil,
          do: format

    assert Enum.uniq(missing) == []
  end

  test "opcode names are unique" do
    names = for {_num, {name, _size, _pops, _pushes, _format}} <- Opcodes.table(), do: name
    assert names == Enum.uniq(names)
  end

  test "opcode byte sizes agree with fixed-width operand metadata" do
    mismatches =
      for {_num, {name, byte_size, _pops, _pushes, format}} <- Opcodes.table(),
          expected = 1 + format_byte_width(format),
          byte_size != expected,
          do: {name, byte_size, format, expected}

    assert mismatches == []
  end

  test "opcode records centralize metadata" do
    assert {:ok, info} = OpcodeSpec.opcode(:if_false)
    assert info.name == :if_false
    assert is_integer(info.opcode)
    assert info.stack_effect == {1, 0}
    assert info.format_info == Opcodes.format_info(:label)
    assert info.operand_decoder == {:fixed, 4}
    assert info.symbolic_stack_effect == :error
    assert info.lowering_family == :control
    assert info.lowering_module == QuickBEAM.VM.Compiler.Lowering.Ops.Control
    assert info.lowering_handler == {:branch, false}
    assert info.control_flow_family == {:branch, false}
    assert info.control_flow_metadata == %{kind: :branch, sense: false}
    assert info.branch_metadata == %{sense: false}

    assert {:ok, call} = OpcodeSpec.opcode(:call2)
    assert call.call_metadata == %{arity: 2}

    assert {:ok, slot} = OpcodeSpec.opcode(:get_loc3)
    assert slot.slot_metadata == %{operation: :get, space: :local, index: 3}

    assert {:ok, push} = OpcodeSpec.opcode(:push_0)
    assert push.small_int_push == 0
    assert push.operand_decoder == {:fixed, []}
    assert push.canonical == :push_i32
    assert push.canonical_operands == [0]
    assert push.short_form?
    assert OpcodeSpec.opcode(push.opcode) == {:ok, push}
    assert OpcodeSpec.opcode(:not_an_opcode) == :error
  end

  test "control flow families are centralized" do
    assert OpcodeSpec.control_flow_family(:if_false) == {:branch, false}
    assert OpcodeSpec.control_flow_family(:if_true8) == {:branch, true}
    assert OpcodeSpec.control_flow_family(:goto16) == :goto
    assert OpcodeSpec.control_flow_family(:catch) == :finally_control
    refute OpcodeSpec.family(:goto, :finally_control)
    assert OpcodeSpec.control_flow_family(:push_i32) == nil
    assert OpcodeSpec.control_flow_metadata(:if_true) == %{kind: :branch, sense: true}
    assert OpcodeSpec.control_flow_metadata(:goto) == %{kind: :goto}
  end

  test "branch target metadata is centralized" do
    assert OpcodeSpec.branch_target(:if_false, [12]) == {:ok, {:branch, false, 12}}
    assert OpcodeSpec.branch_target(:if_true8, [4]) == {:ok, {:branch, true, 4}}
    assert OpcodeSpec.branch_target(:goto16, [9]) == {:ok, {:goto, 9}}
    assert OpcodeSpec.branch_target(:push_0, []) == :error
  end

  test "every label opcode exposes control-flow target metadata" do
    label_formats = MapSet.new([:label, :label8, :label16])

    missing =
      for {_num, {name, _size, _pops, _pushes, format}} <- Opcodes.table(),
          MapSet.member?(label_formats, format),
          OpcodeSpec.branch_target(name, [0]) == :error,
          OpcodeSpec.control_flow_family(name) != :finally_control,
          do: name

    assert missing == []
  end

  test "call arity metadata is centralized" do
    assert OpcodeSpec.call_arity(:call, [4]) == {:ok, 4}
    assert OpcodeSpec.call_arity(:call2, []) == {:ok, 2}
    assert OpcodeSpec.call_arity(:call2, [2]) == {:ok, 2}
    assert OpcodeSpec.call_arity(:call2, [3]) == :error
    assert OpcodeSpec.call_metadata(:call) == %{arity: :operand}
    assert OpcodeSpec.call_metadata(:call3) == %{arity: 3}
  end

  test "compact slot operand metadata is centralized" do
    assert OpcodeSpec.compact_slot_index(:get_arg, [7]) == {:ok, 7}
    assert OpcodeSpec.compact_slot_index(:get_arg2, []) == {:ok, 2}
    assert OpcodeSpec.compact_slot_index(:put_loc3, []) == {:ok, 3}
    assert OpcodeSpec.compact_slot_index(:set_loc8, []) == :error
    assert OpcodeSpec.slot_metadata(:put_arg1) == %{operation: :put, space: :arg, index: 1}

    assert OpcodeSpec.slot_metadata(:set_loc8) == %{
             operation: :set,
             space: :local,
             index: :operand
           }
  end

  test "small integer push metadata is centralized" do
    assert OpcodeSpec.small_int_push(:push_0) == {:ok, 0}
    assert OpcodeSpec.small_int_push?(:push_0)
    refute OpcodeSpec.small_int_push?(:push_i8)
  end

  test "symbolic instruction stack effects are centralized" do
    assert OpcodeSpec.symbolic_stack_effect({:call, 2}) == {:ok, {3, 1}}
    assert OpcodeSpec.symbolic_stack_effect({:define_method, "m", 0}) == {:ok, {2, 1}}
    assert OpcodeSpec.symbolic_stack_effect(:push_this) == :error
  end

  test "lowering handler metadata is centralized" do
    assert OpcodeSpec.lowering_handler(:push_0) == {:push_small_int, :push_0}
    assert OpcodeSpec.lowering_handler(:get_field) == :get_field
    assert OpcodeSpec.lowering_handler(:ret) == :ret
    assert OpcodeSpec.lowering_handler(:invalid) == nil
  end

  defp format_byte_width(format) do
    case Opcodes.format_info(format) do
      :zero -> 0
      {:bytes, bytes} -> bytes
    end
  end

  test "concrete opcode lowering families are stable atoms" do
    valid_families =
      MapSet.new([
        :arithmetic,
        :calls,
        :classes,
        :control,
        :generators,
        :globals,
        :iterators,
        :locals,
        :objects,
        :stack,
        :with_scope,
        nil
      ])

    unexpected =
      for {name, _num} <- OpcodeSpec.all_opcodes(),
          family = OpcodeSpec.lowering_family(name),
          not MapSet.member?(valid_families, family),
          do: {name, family}

    assert unexpected == []
  end
end
