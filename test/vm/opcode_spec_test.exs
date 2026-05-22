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

  test "control flow families are centralized" do
    assert OpcodeSpec.control_flow_family(:if_false) == {:branch, false}
    assert OpcodeSpec.control_flow_family(:if_true8) == {:branch, true}
    assert OpcodeSpec.control_flow_family(:goto16) == :goto
    assert OpcodeSpec.control_flow_family(:catch) == :finally_control
    assert OpcodeSpec.control_flow_family(:push_i32) == nil
  end

  test "compact slot operand metadata is centralized" do
    assert OpcodeSpec.compact_slot_index(:get_arg, [7]) == {:ok, 7}
    assert OpcodeSpec.compact_slot_index(:get_arg2, []) == {:ok, 2}
    assert OpcodeSpec.compact_slot_index(:put_loc3, []) == {:ok, 3}
    assert OpcodeSpec.compact_slot_index(:set_loc8, []) == :error
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
