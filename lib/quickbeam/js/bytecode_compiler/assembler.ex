defmodule QuickBEAM.JS.BytecodeCompiler.Assembler do
  @moduledoc false

  alias QuickBEAM.VM.Opcodes

  @js_atom_end Opcodes.js_atom_end()

  def encode(instructions, atoms \\ {}) when is_list(instructions) do
    widths = jump_widths(instructions)
    labels = label_offsets(instructions, widths)

    instructions
    |> Enum.with_index()
    |> Enum.reject(fn {instruction, _idx} -> match?({:label, _name}, instruction) end)
    |> Enum.map(fn {instruction, idx} ->
      encode_instruction(
        instruction,
        instruction_offset(instructions, idx, widths),
        labels,
        widths[idx],
        atoms
      )
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

  def atoms(instructions) do
    instructions
    |> Enum.flat_map(fn
      {:define_field, name} -> [name]
      {:get_var, name} -> [name]
      {:get_field, name} -> [name]
      {:get_field2, name} -> [name]
      {:put_field, name} -> [name]
      _ -> []
    end)
    |> Enum.uniq()
  end

  defp jump_widths(instructions), do: widen_jumps(instructions, %{})

  defp widen_jumps(instructions, widths) do
    labels = label_offsets(instructions, widths)

    next_widths =
      instructions
      |> Enum.with_index()
      |> Enum.reduce(widths, fn
        {{op, label}, idx}, acc when op in [:jump, :jump_if_false, :jump_if_true] ->
          offset = instruction_offset(instructions, idx, widths)
          diff = Map.fetch!(labels, label) - (offset + 1)

          if diff in -128..127, do: acc, else: Map.put(acc, idx, :wide)

        _entry, acc ->
          acc
      end)

    if next_widths == widths, do: widths, else: widen_jumps(instructions, next_widths)
  end

  defp label_offsets(instructions, widths) do
    instructions
    |> Enum.with_index()
    |> Enum.reduce({%{}, 0}, fn
      {{:label, name}, _idx}, {labels, offset} ->
        {Map.put(labels, name, offset), offset}

      {instruction, idx}, {labels, offset} ->
        {labels, offset + instruction_size(instruction, widths[idx])}
    end)
    |> elem(0)
  end

  defp instruction_offset(instructions, target_idx, widths) do
    instructions
    |> Enum.with_index()
    |> Enum.take(target_idx)
    |> Enum.reject(fn {instruction, _idx} -> match?({:label, _name}, instruction) end)
    |> Enum.reduce(0, fn {instruction, idx}, offset ->
      offset + instruction_size(instruction, widths[idx])
    end)
  end

  defp instruction_size({op, _label}, width) when op in [:jump, :jump_if_false, :jump_if_true],
    do: jump_size(op, width || :short)

  defp instruction_size({op, _name}, _width)
       when op in [:define_field, :get_var, :get_field, :get_field2, :put_field],
       do: 5

  defp instruction_size(instruction, _width), do: byte_size(encode_instruction(instruction))

  defp jump_size(_op, :short), do: 2
  defp jump_size(_op, :wide), do: 5

  defp encode_instruction({:jump, label}, offset, labels, width, _atoms),
    do: encode_jump(:goto8, :goto, label, offset, labels, width || :short)

  defp encode_instruction({:jump_if_false, label}, offset, labels, width, _atoms),
    do: encode_jump(:if_false8, :if_false, label, offset, labels, width || :short)

  defp encode_instruction({:jump_if_true, label}, offset, labels, width, _atoms),
    do: encode_jump(:if_true8, :if_true, label, offset, labels, width || :short)

  defp encode_instruction(instruction, _offset, _labels, _width, atoms),
    do: encode_instruction(instruction, atoms)

  defp encode_jump(short_op, _wide_op, label, offset, labels, :short) do
    diff = Map.fetch!(labels, label) - (offset + 1)
    <<Opcodes.num(short_op), diff::signed-8>>
  end

  defp encode_jump(_short_op, wide_op, label, offset, labels, :wide) do
    diff = Map.fetch!(labels, label) - (offset + 1)
    <<Opcodes.num(wide_op), diff::signed-little-32>>
  end

  defp encode_instruction(instruction), do: encode_instruction(instruction, {})

  defp encode_instruction({:push_int, value}, _atoms) when value in 0..7 do
    <<Opcodes.num(String.to_atom("push_#{value}"))>>
  end

  defp encode_instruction({:push_int, value}, _atoms) when value in -128..127 do
    <<Opcodes.num(:push_i8), value::signed-8>>
  end

  defp encode_instruction({:push_int, value}, _atoms) when value in -32_768..32_767 do
    <<Opcodes.num(:push_i16), value::signed-little-16>>
  end

  defp encode_instruction({:constant, index}, _atoms) when index in 0..255,
    do: <<Opcodes.num(:push_const8), index>>

  defp encode_instruction({:constant, index}, _atoms),
    do: <<Opcodes.num(:push_const), index::little-32>>

  defp encode_instruction({:closure, index}, _atoms) when index in 0..255,
    do: <<Opcodes.num(:fclosure8), index>>

  defp encode_instruction({:get_arg, index}, _atoms) when index in 0..3 do
    <<Opcodes.num(String.to_atom("get_arg#{index}"))>>
  end

  defp encode_instruction({:get_loc, index}, _atoms) when index in 0..3 do
    <<Opcodes.num(String.to_atom("get_loc#{index}"))>>
  end

  defp encode_instruction({:get_loc, index}, _atoms) when index in 0..255,
    do: <<Opcodes.num(:get_loc8), index>>

  defp encode_instruction({:set_arg, index}, _atoms) when index in 0..255,
    do: <<Opcodes.num(:set_arg), index::little-16>>

  defp encode_instruction({:put_arg, index}, _atoms) when index in 0..255,
    do: <<Opcodes.num(:put_arg), index::little-16>>

  defp encode_instruction({:put_loc, index}, _atoms) when index in 0..3 do
    <<Opcodes.num(String.to_atom("put_loc#{index}"))>>
  end

  defp encode_instruction({:put_loc, index}, _atoms) when index in 0..255,
    do: <<Opcodes.num(:put_loc8), index>>

  defp encode_instruction({:set_loc, index}, _atoms) when index in 0..3 do
    <<Opcodes.num(String.to_atom("set_loc#{index}"))>>
  end

  defp encode_instruction({:set_loc, index}, _atoms) when index in 0..255,
    do: <<Opcodes.num(:set_loc8), index>>

  defp encode_instruction({:call, argc}, _atoms) when argc in 0..3 do
    <<Opcodes.num(String.to_atom("call#{argc}"))>>
  end

  defp encode_instruction({:call, argc}, _atoms) when argc in 0..65_535,
    do: <<Opcodes.num(:call), argc::little-16>>

  defp encode_instruction({:call_method, argc}, _atoms) when argc in 0..65_535,
    do: <<Opcodes.num(:call_method), argc::little-16>>

  defp encode_instruction({:array_from, count}, _atoms) when count in 0..65_535,
    do: <<Opcodes.num(:array_from), count::little-16>>

  defp encode_instruction({:define_field, name}, atoms),
    do: <<Opcodes.num(:define_field), atom_index!(atoms, name)::little-32>>

  defp encode_instruction({:get_var, name}, atoms),
    do: <<Opcodes.num(:get_var), atom_index!(atoms, name)::little-32>>

  defp encode_instruction({:get_field, name}, atoms),
    do: <<Opcodes.num(:get_field), atom_index!(atoms, name)::little-32>>

  defp encode_instruction({:get_field2, name}, atoms),
    do: <<Opcodes.num(:get_field2), atom_index!(atoms, name)::little-32>>

  defp encode_instruction({:put_field, name}, atoms),
    do: <<Opcodes.num(:put_field), atom_index!(atoms, name)::little-32>>

  defp encode_instruction({:jump, _label}, _atoms), do: <<Opcodes.num(:goto8), 0>>
  defp encode_instruction({:jump_if_false, _label}, _atoms), do: <<Opcodes.num(:if_false8), 0>>
  defp encode_instruction({:jump_if_true, _label}, _atoms), do: <<Opcodes.num(:if_true8), 0>>
  defp encode_instruction(:push_this, _atoms), do: <<Opcodes.num(:push_this)>>
  defp encode_instruction(:undefined, _atoms), do: <<Opcodes.num(:undefined)>>
  defp encode_instruction(:null, _atoms), do: <<Opcodes.num(:null)>>
  defp encode_instruction(true, _atoms), do: <<Opcodes.num(:push_true)>>
  defp encode_instruction(false, _atoms), do: <<Opcodes.num(:push_false)>>
  defp encode_instruction(:object, _atoms), do: <<Opcodes.num(:object)>>
  defp encode_instruction(:insert2, _atoms), do: <<Opcodes.num(:insert2)>>
  defp encode_instruction(:insert3, _atoms), do: <<Opcodes.num(:insert3)>>
  defp encode_instruction(:dup, _atoms), do: <<Opcodes.num(:dup)>>
  defp encode_instruction(:drop, _atoms), do: <<Opcodes.num(:drop)>>
  defp encode_instruction(:add, _atoms), do: <<Opcodes.num(:add)>>
  defp encode_instruction(:sub, _atoms), do: <<Opcodes.num(:sub)>>
  defp encode_instruction(:mul, _atoms), do: <<Opcodes.num(:mul)>>
  defp encode_instruction(:div, _atoms), do: <<Opcodes.num(:div)>>
  defp encode_instruction(:mod, _atoms), do: <<Opcodes.num(:mod)>>
  defp encode_instruction(:shl, _atoms), do: <<Opcodes.num(:shl)>>
  defp encode_instruction(:sar, _atoms), do: <<Opcodes.num(:sar)>>
  defp encode_instruction(:shr, _atoms), do: <<Opcodes.num(:shr)>>
  defp encode_instruction(:band, _atoms), do: <<Opcodes.num(:band)>>
  defp encode_instruction(:bxor, _atoms), do: <<Opcodes.num(:bxor)>>
  defp encode_instruction(:bor, _atoms), do: <<Opcodes.num(:bor)>>
  defp encode_instruction(:inc, _atoms), do: <<Opcodes.num(:inc)>>
  defp encode_instruction(:dec, _atoms), do: <<Opcodes.num(:dec)>>
  defp encode_instruction(:post_inc, _atoms), do: <<Opcodes.num(:post_inc)>>
  defp encode_instruction(:post_dec, _atoms), do: <<Opcodes.num(:post_dec)>>
  defp encode_instruction(:neg, _atoms), do: <<Opcodes.num(:neg)>>
  defp encode_instruction(:plus, _atoms), do: <<Opcodes.num(:plus)>>
  defp encode_instruction(:lnot, _atoms), do: <<Opcodes.num(:lnot)>>
  defp encode_instruction(:not, _atoms), do: <<Opcodes.num(:not)>>
  defp encode_instruction(:typeof, _atoms), do: <<Opcodes.num(:typeof)>>
  defp encode_instruction(:get_array_el, _atoms), do: <<Opcodes.num(:get_array_el)>>
  defp encode_instruction(:get_array_el2, _atoms), do: <<Opcodes.num(:get_array_el2)>>
  defp encode_instruction(:put_array_el, _atoms), do: <<Opcodes.num(:put_array_el)>>
  defp encode_instruction(:define_array_el, _atoms), do: <<Opcodes.num(:define_array_el)>>
  defp encode_instruction(:get_length, _atoms), do: <<Opcodes.num(:get_length)>>

  defp encode_instruction(:is_undefined_or_null, _atoms),
    do: <<Opcodes.num(:is_undefined_or_null)>>

  defp encode_instruction(:lt, _atoms), do: <<Opcodes.num(:lt)>>
  defp encode_instruction(:lte, _atoms), do: <<Opcodes.num(:lte)>>
  defp encode_instruction(:gt, _atoms), do: <<Opcodes.num(:gt)>>
  defp encode_instruction(:gte, _atoms), do: <<Opcodes.num(:gte)>>
  defp encode_instruction(:eq, _atoms), do: <<Opcodes.num(:eq)>>
  defp encode_instruction(:neq, _atoms), do: <<Opcodes.num(:neq)>>
  defp encode_instruction(:strict_eq, _atoms), do: <<Opcodes.num(:strict_eq)>>
  defp encode_instruction(:strict_neq, _atoms), do: <<Opcodes.num(:strict_neq)>>
  defp encode_instruction(:in, _atoms), do: <<Opcodes.num(:in)>>
  defp encode_instruction(:delete, _atoms), do: <<Opcodes.num(:delete)>>
  defp encode_instruction(:return, _atoms), do: <<Opcodes.num(:return)>>
  defp encode_instruction(:return_undef, _atoms), do: <<Opcodes.num(:return_undef)>>

  defp stack_effect({:call, argc}), do: {1 + argc, 1}
  defp stack_effect({:call_method, argc}), do: {2 + argc, 1}
  defp stack_effect({:get_var, _name}), do: {0, 1}
  defp stack_effect({:array_from, count}), do: {count, 1}
  defp stack_effect({:define_field, _name}), do: {2, 1}
  defp stack_effect({:get_field, _name}), do: {1, 1}
  defp stack_effect({:get_field2, _name}), do: {1, 2}
  defp stack_effect({:put_field, _name}), do: {2, 0}

  defp stack_effect({_op, _arg} = instruction),
    do: instruction |> encode_instruction() |> opcode_stack_effect()

  defp stack_effect(instruction), do: instruction |> encode_instruction() |> opcode_stack_effect()

  defp opcode_stack_effect(<<op, _rest::binary>>) do
    {_name, _size, pops, pushes, _format} = Opcodes.info(op)
    {pops, pushes}
  end

  defp atom_index!(atoms, name) do
    local_idx = atoms |> Tuple.to_list() |> Enum.find_index(&(&1 == name))

    if local_idx == nil do
      raise ArgumentError, "atom not collected: #{inspect(name)}"
    end

    @js_atom_end + local_idx
  end
end
