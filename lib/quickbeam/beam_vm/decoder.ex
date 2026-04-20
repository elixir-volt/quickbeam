defmodule QuickBEAM.BeamVM.Decoder do
  @compile {:inline,
            get_u8: 2,
            get_i8: 2,
            get_u16: 2,
            get_i16: 2,
            get_u32: 2,
            get_i32: 2,
            get_atom_u32: 2,
            resolve_label: 2,
            short_form_operands: 2}
  @moduledoc """
  Decodes raw QuickJS bytecode bytes into instruction tuples.

  Returns a tuple of {opcode_integer, args} indexed by instruction position
  (NOT byte offset). Labels are resolved to instruction indices via a
  byte-offset-to-index map. Opcodes are raw integer tags for O(1) BEAM JIT
  jump-table dispatch.
  """

  alias QuickBEAM.BeamVM.Opcodes
  import Bitwise

  @type instruction :: {non_neg_integer(), [term()]}

  @spec decode(binary()) :: {:ok, [instruction()]} | {:error, term()}
  def decode(byte_code, arg_count \\ 0) when is_binary(byte_code) do
    case build_offset_map(byte_code) do
      {:ok, offset_map} ->
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

      {_name, size, _n_pop, _n_push, fmt} ->
        if pos + size > len do
          {:error, {:truncated_instruction, op, pos}}
        else
          operands =
            case fmt do
              :none_loc -> short_form_operands(op, ac)
              :none_arg -> short_form_operands(op, ac)
              :none_var_ref -> short_form_operands(op, ac)
              :none_int -> short_form_operands(op, ac)
              :npopx -> short_form_operands(op, ac)
              _ -> decode_operands(bc, pos + 1, fmt, offset_map, ac)
            end

          decode_pass2(
            bc,
            len,
            pos + size,
            idx + 1,
            offset_map,
            [
              {op, operands} | acc
            ],
            ac
          )
        end
    end
  end

  # Short-form opcodes with implicit operands
  # loc variants add arg_count offset; arg/var_ref/call/push don't

  # get_loc0..3 (197-200)
  defp short_form_operands(197, ac), do: [0 + ac]
  defp short_form_operands(198, ac), do: [1 + ac]
  defp short_form_operands(199, ac), do: [2 + ac]
  defp short_form_operands(200, ac), do: [3 + ac]
  # put_loc0..3 (201-204)
  defp short_form_operands(201, ac), do: [0 + ac]
  defp short_form_operands(202, ac), do: [1 + ac]
  defp short_form_operands(203, ac), do: [2 + ac]
  defp short_form_operands(204, ac), do: [3 + ac]
  # set_loc0..3 (205-208)
  defp short_form_operands(205, ac), do: [0 + ac]
  defp short_form_operands(206, ac), do: [1 + ac]
  defp short_form_operands(207, ac), do: [2 + ac]
  defp short_form_operands(208, ac), do: [3 + ac]
  # get_loc0_loc1 (196)
  defp short_form_operands(196, ac), do: [0 + ac, 1 + ac]
  # get_arg0..3 (209-212)
  defp short_form_operands(209, _ac), do: [0]
  defp short_form_operands(210, _ac), do: [1]
  defp short_form_operands(211, _ac), do: [2]
  defp short_form_operands(212, _ac), do: [3]
  # put_arg0..3 (213-216)
  defp short_form_operands(213, _ac), do: [0]
  defp short_form_operands(214, _ac), do: [1]
  defp short_form_operands(215, _ac), do: [2]
  defp short_form_operands(216, _ac), do: [3]
  # set_arg0..3 (217-220)
  defp short_form_operands(217, _ac), do: [0]
  defp short_form_operands(218, _ac), do: [1]
  defp short_form_operands(219, _ac), do: [2]
  defp short_form_operands(220, _ac), do: [3]
  # get_var_ref0..3 (221-224)
  defp short_form_operands(221, _ac), do: [0]
  defp short_form_operands(222, _ac), do: [1]
  defp short_form_operands(223, _ac), do: [2]
  defp short_form_operands(224, _ac), do: [3]
  # put_var_ref0..3 (225-228)
  defp short_form_operands(225, _ac), do: [0]
  defp short_form_operands(226, _ac), do: [1]
  defp short_form_operands(227, _ac), do: [2]
  defp short_form_operands(228, _ac), do: [3]
  # set_var_ref0..3 (229-232)
  defp short_form_operands(229, _ac), do: [0]
  defp short_form_operands(230, _ac), do: [1]
  defp short_form_operands(231, _ac), do: [2]
  defp short_form_operands(232, _ac), do: [3]
  # call0..3 (238-241)
  defp short_form_operands(238, _ac), do: [0]
  defp short_form_operands(239, _ac), do: [1]
  defp short_form_operands(240, _ac), do: [2]
  defp short_form_operands(241, _ac), do: [3]
  # push_minus1 (179), push_0..7 (180-187)
  defp short_form_operands(179, _ac), do: [-1]
  defp short_form_operands(180, _ac), do: [0]
  defp short_form_operands(181, _ac), do: [1]
  defp short_form_operands(182, _ac), do: [2]
  defp short_form_operands(183, _ac), do: [3]
  defp short_form_operands(184, _ac), do: [4]
  defp short_form_operands(185, _ac), do: [5]
  defp short_form_operands(186, _ac), do: [6]
  defp short_form_operands(187, _ac), do: [7]
  # push_empty_string (192) — no operands
  defp short_form_operands(192, _ac), do: []
  # Fallback
  defp short_form_operands(_op, _ac), do: []

  # ── Operand decoding ──

  defp decode_operands(bc, pos, :u8, _om, _ac), do: [get_u8(bc, pos)]
  defp decode_operands(bc, pos, :i8, _om, _ac), do: [get_i8(bc, pos)]
  defp decode_operands(bc, pos, :u16, _om, _ac), do: [get_u16(bc, pos)]
  defp decode_operands(bc, pos, :i16, _om, _ac), do: [get_i16(bc, pos)]
  defp decode_operands(bc, pos, :i32, _om, _ac), do: [get_i32(bc, pos)]
  defp decode_operands(bc, pos, :u32, _om, _ac), do: [get_u32(bc, pos)]

  defp decode_operands(bc, pos, :u32x2, _om, _ac) do
    [get_u32(bc, pos), get_u32(bc, pos + 4)]
  end

  defp decode_operands(_bc, _pos, :none, _om, _ac), do: []
  defp decode_operands(bc, pos, :npop, _om, _ac), do: [get_u16(bc, pos)]

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
