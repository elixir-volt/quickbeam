defmodule QuickBEAM.BeamVM.Decoder do
  @compile {:inline,
            get_u8: 2,
            get_i8: 2,
            get_u16: 2,
            get_i16: 2,
            get_u32: 2,
            get_i32: 2,
            get_atom_u32: 2,
            resolve_label: 2}
  @moduledoc """
  Decodes raw QuickJS bytecode bytes into instruction tuples.

  Returns a tuple of {name, args} indexed by instruction position (NOT byte offset).
  Labels are resolved to instruction indices via a byte-offset-to-index map.
  """

  alias QuickBEAM.BeamVM.Opcodes
  import Bitwise

  @type instruction :: {atom(), [term()]}

  @spec decode(binary()) :: {:ok, {[instruction()], tuple()}} | {:error, term()}
  def decode(byte_code, arg_count \\ 0) when is_binary(byte_code) do
    # First pass: build byte-offset → instruction-index map
    case build_offset_map(byte_code) do
      {:ok, offset_map} ->
        # Second pass: decode and resolve labels
        decode_pass2(byte_code, byte_size(byte_code), 0, 0, offset_map, [], arg_count)

      {:error, _} = err ->
        err
    end
  end

  defp build_offset_map(bc) do
    build_offset_map(bc, byte_size(bc), 0, 0, %{})
  end

  defp build_offset_map(_bc, len, pos, _idx, acc) when pos >= len do
    {:ok, acc}
  end

  defp build_offset_map(bc, len, pos, idx, acc) do
    op = :binary.at(bc, pos)

    case Opcodes.info(op) do
      nil ->
        {:error, {:unknown_opcode, op, pos}}

      {_name, size, _n_pop, _n_push, _fmt} ->
        if pos + size > len do
          {:error, {:truncated_instruction, op, pos}}
        else
          build_offset_map(bc, len, pos + size, idx + 1, Map.put(acc, pos, idx))
        end
    end
  end

  defp decode_pass2(_bc, len, pos, _idx, _offset_map, acc, _ac) when pos >= len do
    {:ok, Enum.reverse(acc)}
  end

  defp decode_pass2(bc, len, pos, idx, offset_map, acc, ac) do
    op = :binary.at(bc, pos)

    case Opcodes.info(op) do
      nil ->
        {:error, {:unknown_opcode, op, pos}}

      {name, size, _n_pop, _n_push, fmt} ->
        if pos + size > len do
          {:error, {:truncated_instruction, name, pos}}
        else
          operands = decode_operands(bc, pos + 1, fmt, offset_map, ac)
          {canonical_name, final_args} = Opcodes.expand_short_form(name, operands, ac)

          decode_pass2(bc, len, pos + size, idx + 1, offset_map, [
            {canonical_name, final_args} | acc
          ], ac)
        end
    end
  end

  # ── Operand decoding ──

  defp decode_operands(_bc, _pos, :none, _om, _ac), do: []
  defp decode_operands(_bc, _pos, :none_int, _om, _ac), do: []
  defp decode_operands(_bc, _pos, :none_loc, _om, _ac), do: []
  defp decode_operands(_bc, _pos, :none_arg, _om, _ac), do: []
  defp decode_operands(_bc, _pos, :none_var_ref, _om, _ac), do: []

  defp decode_operands(bc, pos, :u8, _om, _ac), do: [get_u8(bc, pos)]
  defp decode_operands(bc, pos, :i8, _om, _ac), do: [get_i8(bc, pos)]
  defp decode_operands(bc, pos, :u16, _om, _ac), do: [get_u16(bc, pos)]
  defp decode_operands(bc, pos, :i16, _om, _ac), do: [get_i16(bc, pos)]
  defp decode_operands(bc, pos, :i32, _om, _ac), do: [get_i32(bc, pos)]
  defp decode_operands(bc, pos, :u32, _om, _ac), do: [get_u32(bc, pos)]

  defp decode_operands(bc, pos, :u32x2, _om, _ac) do
    [get_u32(bc, pos), get_u32(bc, pos + 4)]
  end

  defp decode_operands(bc, pos, :npop, _om, _ac), do: [get_u16(bc, pos)]
  defp decode_operands(_bc, _pos, :npopx, _om, _ac), do: []

  defp decode_operands(bc, pos, :npop_u16, _om, _ac) do
    [get_u16(bc, pos), get_u16(bc, pos + 2)]
  end

  defp decode_operands(bc, pos, :loc8, _om, ac), do: [get_u8(bc, pos) + ac]
  defp decode_operands(bc, pos, :const8, _om, _ac), do: [get_u8(bc, pos)]
  defp decode_operands(bc, pos, :loc, _om, ac), do: [get_u16(bc, pos) + ac]
  defp decode_operands(bc, pos, :arg, _om, _ac), do: [get_u16(bc, pos)]
  defp decode_operands(bc, pos, :var_ref, _om, _ac), do: [get_u16(bc, pos)]
  defp decode_operands(bc, pos, :const, _om, _ac), do: [get_u32(bc, pos)]

  defp decode_operands(bc, pos, :label8, om, _ac) do
    target_byte = pos + get_i8(bc, pos)
    [resolve_label(target_byte, om)]
  end

  defp decode_operands(bc, pos, :label16, om, _ac) do
    target_byte = pos + get_i16(bc, pos)
    [resolve_label(target_byte, om)]
  end

  defp decode_operands(bc, pos, :label, om, _ac) do
    # label: i32 RELATIVE byte offset from pos → resolve to instruction index
    byte_off = pos + get_i32(bc, pos)
    [resolve_label(byte_off, om)]
  end

  defp decode_operands(bc, pos, :label_u16, om, _ac) do
    byte_off = pos + get_i32(bc, pos)
    [resolve_label(byte_off, om), get_u16(bc, pos + 4)]
  end

  defp decode_operands(bc, pos, :atom, _om, _ac) do
    [get_atom_u32(bc, pos)]
  end

  defp decode_operands(bc, pos, :atom_u8, _om, _ac) do
    [get_atom_u32(bc, pos), get_u8(bc, pos + 4)]
  end

  defp decode_operands(bc, pos, :atom_u16, _om, _ac) do
    [get_atom_u32(bc, pos), get_u16(bc, pos + 4)]
  end

  defp decode_operands(bc, pos, :atom_label_u8, om, _ac) do
    byte_off = pos + 4 + get_i32(bc, pos + 4)
    [get_atom_u32(bc, pos), resolve_label(byte_off, om), get_u8(bc, pos + 8)]
  end

  defp decode_operands(bc, pos, :atom_label_u16, om, _ac) do
    byte_off = pos + 4 + get_i32(bc, pos + 4)
    [get_atom_u32(bc, pos), resolve_label(byte_off, om), get_u16(bc, pos + 8)]
  end

  defp resolve_label(byte_off, offset_map) do
    Map.get(offset_map, byte_off, byte_off)
  end

  # ── Byte accessors (little-endian) ──

  defp get_u8(bc, pos), do: :binary.at(bc, pos)

  defp get_i8(bc, pos) do
    v = :binary.at(bc, pos)
    if v >= 128, do: v - 256, else: v
  end

  defp get_u16(bc, pos), do: :binary.decode_unsigned(:binary.part(bc, pos, 2), :little)

  defp get_i16(bc, pos) do
    v = get_u16(bc, pos)
    if v >= 0x8000, do: v - 0x10000, else: v
  end

  defp get_u32(bc, pos), do: :binary.decode_unsigned(:binary.part(bc, pos, 4), :little)

  defp get_i32(bc, pos) do
    v = get_u32(bc, pos)
    if v >= 0x80000000, do: v - 0x100000000, else: v
  end

  # Atoms in bytecode instructions use bc_atom_to_idx format (raw u32):
  #   u32 < JS_ATOM_END (229) → predefined runtime atom
  #   u32 >= JS_ATOM_END → atom table at (u32 - 229)
  # Tagged int atoms (odd values) are rare but possible.
  @js_atom_end Opcodes.js_atom_end()
  defp get_atom_u32(bc, pos) do
    v = get_u32(bc, pos)

    cond do
      band(v, 0x80000000) != 0 -> {:tagged_int, band(v, 0x7FFFFFFF)}
      v >= 1 and v < @js_atom_end -> {:predefined, v}
      v >= @js_atom_end -> v - @js_atom_end
      true -> {:predefined, v}
    end
  end
end
