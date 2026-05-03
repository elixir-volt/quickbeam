defmodule QuickBEAM.JS.BytecodeCompiler.Assembler do
  @moduledoc false

  alias QuickBEAM.VM.Opcodes

  def encode(instructions) when is_list(instructions) do
    labels = label_offsets(instructions)

    instructions
    |> Enum.with_index()
    |> Enum.reject(fn {instruction, _idx} -> match?({:label, _name}, instruction) end)
    |> Enum.map(fn {instruction, idx} ->
      encode_instruction(instruction, instruction_offset(instructions, idx), labels)
    end)
    |> IO.iodata_to_binary()
  end

  def stack_size(instructions) when is_list(instructions) do
    instructions
    |> Enum.reject(&match?({:label, _name}, &1))
    |> Enum.reduce({0, 0}, fn instruction, {depth, max_depth} ->
      {pops, pushes} = stack_effect(instruction)
      depth = max(depth - pops, 0) + pushes
      {depth, max(max_depth, depth)}
    end)
    |> elem(1)
  end

  defp label_offsets(instructions) do
    instructions
    |> Enum.reduce({%{}, 0}, fn
      {:label, name}, {labels, offset} ->
        {Map.put(labels, name, offset), offset}

      instruction, {labels, offset} ->
        {labels, offset + byte_size(encode_instruction(instruction))}
    end)
    |> elem(0)
  end

  defp instruction_offset(instructions, target_idx) do
    instructions
    |> Enum.take(target_idx)
    |> Enum.reject(&match?({:label, _name}, &1))
    |> Enum.reduce(0, fn instruction, offset ->
      offset + byte_size(encode_instruction(instruction))
    end)
  end

  defp encode_instruction({:jump, label}, offset, labels),
    do: encode_jump(:goto8, label, offset, labels)

  defp encode_instruction({:jump_if_false, label}, offset, labels),
    do: encode_jump(:if_false8, label, offset, labels)

  defp encode_instruction(instruction, _offset, _labels), do: encode_instruction(instruction)

  defp encode_jump(op, label, offset, labels) do
    target = Map.fetch!(labels, label)
    diff = target - (offset + 1)

    unless diff in -128..127 do
      raise ArgumentError, "#{op} target #{inspect(label)} is outside 8-bit jump range"
    end

    <<Opcodes.num(op), diff::signed-8>>
  end

  defp encode_instruction({:push_int, value}) when value in 0..7 do
    <<Opcodes.num(String.to_atom("push_#{value}"))>>
  end

  defp encode_instruction({:push_int, value}) when value in -128..127 do
    <<Opcodes.num(:push_i8), value::signed-8>>
  end

  defp encode_instruction({:push_int, value}) when value in -32_768..32_767 do
    <<Opcodes.num(:push_i16), value::signed-little-16>>
  end

  defp encode_instruction({:constant, index}) when index in 0..255,
    do: <<Opcodes.num(:push_const8), index>>

  defp encode_instruction({:constant, index}),
    do: <<Opcodes.num(:push_const), index::little-32>>

  defp encode_instruction({:closure, index}) when index in 0..255,
    do: <<Opcodes.num(:fclosure8), index>>

  defp encode_instruction({:get_arg, index}) when index in 0..3 do
    <<Opcodes.num(String.to_atom("get_arg#{index}"))>>
  end

  defp encode_instruction({:get_loc, index}) when index in 0..3 do
    <<Opcodes.num(String.to_atom("get_loc#{index}"))>>
  end

  defp encode_instruction({:get_loc, index}) when index in 0..255,
    do: <<Opcodes.num(:get_loc8), index>>

  defp encode_instruction({:set_arg, index}) when index in 0..255,
    do: <<Opcodes.num(:set_arg), index::little-16>>

  defp encode_instruction({:put_arg, index}) when index in 0..255,
    do: <<Opcodes.num(:put_arg), index::little-16>>

  defp encode_instruction({:put_loc, index}) when index in 0..3 do
    <<Opcodes.num(String.to_atom("put_loc#{index}"))>>
  end

  defp encode_instruction({:put_loc, index}) when index in 0..255,
    do: <<Opcodes.num(:put_loc8), index>>

  defp encode_instruction({:set_loc, index}) when index in 0..3 do
    <<Opcodes.num(String.to_atom("set_loc#{index}"))>>
  end

  defp encode_instruction({:set_loc, index}) when index in 0..255,
    do: <<Opcodes.num(:set_loc8), index>>

  defp encode_instruction({:call, argc}) when argc in 0..3 do
    <<Opcodes.num(String.to_atom("call#{argc}"))>>
  end

  defp encode_instruction({:array_from, count}) when count in 0..65_535,
    do: <<Opcodes.num(:array_from), count::little-16>>

  defp encode_instruction({:jump, _label}), do: <<Opcodes.num(:goto8), 0>>
  defp encode_instruction({:jump_if_false, _label}), do: <<Opcodes.num(:if_false8), 0>>
  defp encode_instruction(:undefined), do: <<Opcodes.num(:undefined)>>
  defp encode_instruction(:null), do: <<Opcodes.num(:null)>>
  defp encode_instruction(true), do: <<Opcodes.num(:push_true)>>
  defp encode_instruction(false), do: <<Opcodes.num(:push_false)>>
  defp encode_instruction(:add), do: <<Opcodes.num(:add)>>
  defp encode_instruction(:sub), do: <<Opcodes.num(:sub)>>
  defp encode_instruction(:mul), do: <<Opcodes.num(:mul)>>
  defp encode_instruction(:div), do: <<Opcodes.num(:div)>>
  defp encode_instruction(:mod), do: <<Opcodes.num(:mod)>>
  defp encode_instruction(:neg), do: <<Opcodes.num(:neg)>>
  defp encode_instruction(:plus), do: <<Opcodes.num(:plus)>>
  defp encode_instruction(:not), do: <<Opcodes.num(:not)>>
  defp encode_instruction(:lnot), do: <<Opcodes.num(:lnot)>>
  defp encode_instruction(:typeof), do: <<Opcodes.num(:typeof)>>
  defp encode_instruction(:get_array_el), do: <<Opcodes.num(:get_array_el)>>
  defp encode_instruction(:get_length), do: <<Opcodes.num(:get_length)>>
  defp encode_instruction(:lt), do: <<Opcodes.num(:lt)>>
  defp encode_instruction(:lte), do: <<Opcodes.num(:lte)>>
  defp encode_instruction(:gt), do: <<Opcodes.num(:gt)>>
  defp encode_instruction(:gte), do: <<Opcodes.num(:gte)>>
  defp encode_instruction(:eq), do: <<Opcodes.num(:eq)>>
  defp encode_instruction(:neq), do: <<Opcodes.num(:neq)>>
  defp encode_instruction(:strict_eq), do: <<Opcodes.num(:strict_eq)>>
  defp encode_instruction(:strict_neq), do: <<Opcodes.num(:strict_neq)>>
  defp encode_instruction(:return), do: <<Opcodes.num(:return)>>
  defp encode_instruction(:return_undef), do: <<Opcodes.num(:return_undef)>>

  defp stack_effect({:call, argc}), do: {1 + argc, 1}

  defp stack_effect({_op, _arg} = instruction),
    do: instruction |> encode_instruction() |> opcode_stack_effect()

  defp stack_effect(instruction), do: instruction |> encode_instruction() |> opcode_stack_effect()

  defp opcode_stack_effect(<<op, _rest::binary>>) do
    {_name, _size, pops, pushes, _format} = Opcodes.info(op)
    {pops, pushes}
  end
end
