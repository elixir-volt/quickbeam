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
