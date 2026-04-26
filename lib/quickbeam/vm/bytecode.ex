defmodule QuickBEAM.VM.Bytecode do
  @moduledoc """
  Parses QuickJS bytecode binaries into Elixir data structures.

  Binary format matches JS_WriteObjectAtoms / JS_ReadObjectAtoms / JS_ReadFunctionTag
  in priv/c_src/quickjs.c exactly.
  """

  alias QuickBEAM.VM.{LEB128, Opcodes}
  import Bitwise

  # JS_ATOM_NULL=0, plus 228 DEF entries from quickjs-atom.h
  @js_atom_end Opcodes.js_atom_end()

  # Pre-compute tag constants for use in match clauses
  @tag_null Opcodes.bc_tag_null()
  @tag_undefined Opcodes.bc_tag_undefined()
  @tag_bool_false Opcodes.bc_tag_bool_false()
  @tag_bool_true Opcodes.bc_tag_bool_true()
  @tag_int32 Opcodes.bc_tag_int32()
  @tag_float64 Opcodes.bc_tag_float64()
  @tag_string Opcodes.bc_tag_string()
  @tag_function_bytecode Opcodes.bc_tag_function_bytecode()
  @tag_object Opcodes.bc_tag_object()
  @tag_array Opcodes.bc_tag_array()
  @tag_big_int Opcodes.bc_tag_big_int()
  @tag_template_object Opcodes.bc_tag_template_object()
  @tag_regexp Opcodes.bc_tag_regexp()

  defmodule Function do
    @moduledoc "Decoded QuickJS function bytecode and metadata used by the VM interpreter."
    @type t :: %__MODULE__{}
    defstruct [
      :name,
      :filename,
      line_num: 1,
      col_num: 1,
      pc2line: <<>>,
      source: <<>>,
      arg_count: 0,
      var_count: 0,
      defined_arg_count: 0,
      stack_size: 0,
      var_ref_count: 0,
      locals: [],
      closure_vars: [],
      constants: [],
      byte_code: <<>>,
      has_prototype: false,
      has_simple_parameter_list: false,
      is_derived_class_constructor: false,
      need_home_object: false,
      func_kind: 0,
      new_target_allowed: false,
      super_call_allowed: false,
      super_allowed: false,
      arguments_allowed: false,
      is_strict_mode: false,
      has_debug_info: false
    ]
  end

  defmodule VarDef do
    @moduledoc "Decoded QuickJS local variable definition metadata."
    defstruct [
      :name,
      :scope_level,
      :scope_next,
      :var_kind,
      :is_const,
      :is_lexical,
      :is_captured,
      :var_ref_idx
    ]
  end

  defmodule ClosureVar do
    @moduledoc "Decoded QuickJS closure capture metadata."
    defstruct [:name, :var_idx, :closure_type, :is_const, :is_lexical, :var_kind]
  end

  defstruct [:version, :atoms, :value]

  @doc "Decodes a QuickJS bytecode binary into a `%QuickBEAM.VM.Bytecode{}` structure."
  @spec decode(binary()) :: {:ok, struct()} | {:error, term()}
  def decode(data) when is_binary(data) do
    with {:ok, version, rest} <- LEB128.read_u8(data),
         :ok <- validate_version(version),
         <<_checksum::little-unsigned-32, rest2::binary>> <- rest,
         {:ok, atoms, rest3} <- read_atoms(rest2),
         {:ok, value, _rest4} <- read_object(rest3, atoms) do
      {:ok, %__MODULE__{version: version, atoms: atoms, value: value}}
    else
      {:error, _} = err -> err
      _ -> {:error, :unexpected_end}
    end
  end

  # ── Atom table ──
  # Matches JS_ReadObjectAtoms: reads idx_to_atom_count entries.
  # Each entry: type=0 → const atom (u32), type≠0 → string atom.

  defp read_atoms(data) do
    with {:ok, count, rest} <- LEB128.read_unsigned(data) do
      read_atom_list(rest, count, [])
    end
  end

  defp read_atom_list(data, 0, acc), do: {:ok, List.to_tuple(Enum.reverse(acc)), data}

  defp read_atom_list(data, count, acc) do
    with {:ok, type, rest} <- LEB128.read_u8(data) do
      if type == 0 do
        with {:ok, _atom_id, rest2} <- LEB128.read_u32(rest) do
          read_atom_list(rest2, count - 1, [:__const_atom__ | acc])
        end
      else
        with {:ok, str, rest2} <- read_string_raw(rest) do
          read_atom_list(rest2, count - 1, [str | acc])
        end
      end
    end
  end

  # bc_get_atom: reads LEB128 value v.
  # If v & 1 → tagged int (v >> 1).
  # If v even → idx = v >> 1:
  #   idx < JS_ATOM_END → predefined runtime atom (return as {:predefined, idx})
  #   idx >= JS_ATOM_END → atom table at idx - JS_ATOM_END
  defp read_atom_ref(data, atoms) do
    with {:ok, v, rest} <- LEB128.read_unsigned(data) do
      if band(v, 1) == 1 do
        {:ok, {:tagged_int, bsr(v, 1)}, rest}
      else
        idx = bsr(v, 1)

        name =
          case idx do
            0 ->
              ""

            n when n < @js_atom_end ->
              {:predefined, n}

            _ ->
              local_idx = idx - @js_atom_end

              if local_idx < tuple_size(atoms),
                do: elem(atoms, local_idx),
                else: {:unknown_atom, idx}
          end

        {:ok, name, rest}
      end
    end
  end

  # ── String reading ──
  # bc_get_leb128 for len (where bit0=is_wide, bits1+=actual_len), then raw bytes.

  defp read_binary_raw(data) do
    with {:ok, len_encoded, rest} <- LEB128.read_unsigned(data) do
      byte_len = bsr(len_encoded, 1)

      if byte_size(rest) < byte_len do
        {:error, :unexpected_end}
      else
        <<raw::binary-size(byte_len), rest2::binary>> = rest
        {:ok, raw, rest2}
      end
    end
  end

  defp read_string_raw(data) do
    with {:ok, len_encoded, rest} <- LEB128.read_unsigned(data) do
      is_wide = band(len_encoded, 1) == 1
      char_len = bsr(len_encoded, 1)
      byte_len = if is_wide, do: char_len * 2, else: char_len

      if byte_size(rest) < byte_len do
        {:error, :unexpected_end}
      else
        <<str::binary-size(byte_len), rest2::binary>> = rest

        if is_wide do
          {:ok, wide_to_utf8(str), rest2}
        else
          {:ok, latin1_to_utf8(str), rest2}
        end
      end
    end
  end

  defp latin1_to_utf8(data) do
    for <<b <- data>>, into: <<>>, do: <<b::utf8>>
  end

  defp wide_to_utf8(data) do
    data
    |> decode_utf16_le()
    |> codepoints_to_binary()
  end

  defp codepoints_to_binary(codepoints) do
    IO.iodata_to_binary(
      for cp <- codepoints do
        if cp >= 0xD800 and cp <= 0xDFFF do
          # Lone surrogate: encode as CESU-8 (3-byte UTF-8-like encoding)
          <<0xE0 ||| cp >>> 12, 0x80 ||| (cp >>> 6 &&& 0x3F), 0x80 ||| (cp &&& 0x3F)>>
        else
          <<cp::utf8>>
        end
      end
    )
  end

  defp decode_utf16_le(data, acc \\ [])
  defp decode_utf16_le(<<>>, acc), do: Enum.reverse(acc)

  defp decode_utf16_le(<<hi::little-16, lo::little-16, rest::binary>>, acc)
       when hi >= 0xD800 and hi <= 0xDBFF and lo >= 0xDC00 and lo <= 0xDFFF do
    cp = (hi - 0xD800) * 0x400 + (lo - 0xDC00) + 0x10000
    decode_utf16_le(rest, [cp | acc])
  end

  defp decode_utf16_le(<<c::little-16, rest::binary>>, acc) do
    decode_utf16_le(rest, [c | acc])
  end

  # ── Object deserialization ──
  # Matches JS_ReadObjectRec switch(tag).

  defp read_object(<<@tag_null, rest::binary>>, _atoms), do: {:ok, nil, rest}
  defp read_object(<<@tag_undefined, rest::binary>>, _atoms), do: {:ok, :undefined, rest}
  defp read_object(<<@tag_bool_false, rest::binary>>, _atoms), do: {:ok, false, rest}
  defp read_object(<<@tag_bool_true, rest::binary>>, _atoms), do: {:ok, true, rest}

  defp read_object(<<@tag_int32, rest::binary>>, _atoms) do
    LEB128.read_signed(rest)
  end

  defp read_object(<<@tag_float64, rest::binary>>, _atoms) do
    case rest do
      <<val::little-float-64, rest2::binary>> -> {:ok, val, rest2}
      _ -> {:error, :unexpected_end}
    end
  end

  defp read_object(<<@tag_string, rest::binary>>, _atoms), do: read_string_raw(rest)

  defp read_object(<<@tag_function_bytecode, rest::binary>>, atoms),
    do: read_function(rest, atoms)

  defp read_object(<<@tag_object, rest::binary>>, atoms), do: read_plain_object(rest, atoms)
  defp read_object(<<@tag_array, rest::binary>>, atoms), do: read_array(rest, atoms)

  defp read_object(<<@tag_big_int, rest::binary>>, _atoms) do
    with {:ok, len, rest2} <- LEB128.read_unsigned(rest) do
      if byte_size(rest2) < len do
        {:error, :unexpected_end}
      else
        <<bytes::binary-size(len), rest3::binary>> = rest2
        value = decode_bigint_twos_complement(bytes)
        {:ok, {:bigint, value}, rest3}
      end
    end
  end

  defp read_object(<<@tag_template_object, rest::binary>>, atoms) do
    with {:ok, count, rest2} <- LEB128.read_unsigned(rest),
         {:ok, elems, rest3} <- read_array_elems(rest2, count, [], atoms),
         {:ok, raw, rest4} <- read_object(rest3, atoms) do
      {:ok, {:template_object, elems, raw}, rest4}
    end
  end

  defp read_object(<<@tag_regexp, rest::binary>>, _atoms) do
    with {:ok, bytecode, rest2} <- read_binary_raw(rest),
         {:ok, source, rest3} <- read_string_raw(rest2) do
      {:ok, {:regexp, bytecode, source}, rest3}
    end
  end

  defp read_object(<<tag, _rest::binary>>, _atoms), do: {:error, {:unknown_tag, tag}}
  defp read_object(<<>>, _atoms), do: {:error, :unexpected_end}

  defp decode_bigint_twos_complement(<<>>), do: 0

  defp decode_bigint_twos_complement(bytes) do
    # QuickJS stores bigint as little-endian two's complement bytes
    size = byte_size(bytes)
    <<value::little-unsigned-integer-size(size)-unit(8)>> = bytes
    # Check sign bit
    if band(binary_part(bytes, size - 1, 1) |> :binary.decode_unsigned(), 0x80) != 0 do
      value - (1 <<< (size * 8))
    else
      value
    end
  end

  defp read_plain_object(data, atoms) do
    with {:ok, count, rest} <- LEB128.read_unsigned(data) do
      read_props(rest, count, %{}, atoms)
    end
  end

  defp read_array(data, atoms) do
    with {:ok, count, rest} <- LEB128.read_unsigned(data) do
      read_array_elems(rest, count, [], atoms)
    end
  end

  defp read_props(data, 0, acc, _atoms), do: {:ok, {:object, acc}, data}

  defp read_props(data, count, acc, atoms) do
    with {:ok, key, rest} <- read_prop_key(data, atoms),
         {:ok, val, rest2} <- read_object(rest, atoms) do
      read_props(rest2, count - 1, Map.put(acc, key, val), atoms)
    end
  end

  defp read_array_elems(data, 0, acc, _atoms), do: {:ok, {:array, Enum.reverse(acc)}, data}

  defp read_array_elems(data, count, acc, atoms) do
    with {:ok, val, rest} <- read_object(data, atoms) do
      read_array_elems(rest, count - 1, [val | acc], atoms)
    end
  end

  # Property keys: JS_ReadObjectRec handles them as full objects.
  # In practice: tag=BC_TAG_INT32 for integer keys, or tag=BC_TAG_STRING/atom.
  defp read_prop_key(data, atoms), do: read_object(data, atoms)

  # ── Function bytecode ──
  # Matches JS_ReadFunctionTag exactly.
  #
  # Layout:
  #   flags (u16 raw LE)
  #   is_strict_mode (u8)
  #   func_name (bc_get_atom → LEB128)
  #   arg_count (leb128_u16)
  #   var_count (leb128_u16)
  #   defined_arg_count (leb128_u16)
  #   stack_size (leb128_u16)
  #   var_ref_count (leb128_u16)
  #   closure_var_count (leb128_u16)
  #   cpool_count (leb128_int)
  #   byte_code_len (leb128_int)
  #   local_count (leb128_int)
  #   [vardefs × local_count]
  #   [closure_vars × closure_var_count]
  #   [cpool × cpool_count]  — cpool written BEFORE bytecode
  #   [bytecode × byte_code_len]
  #   [debug_info if has_debug_info: filename_atom + line_num]

  defp read_function(data, atoms) do
    # flags: raw u16 little-endian (bc_put_u16 / bc_get_u16)
    case data do
      <<flags::little-unsigned-16, rest::binary>> ->
        read_function_body(flags, rest, atoms)

      _ ->
        {:error, :unexpected_end}
    end
  end

  defp validate_version(version) do
    if version == Opcodes.bc_version(), do: :ok, else: {:error, {:bad_version, version}}
  end

  defp read_function_body(flags, data, atoms) do
    flags_map = decode_func_flags(flags)

    with {:ok, strict, rest} <- LEB128.read_u8(data),
         {:ok, func_name, rest} <- read_atom_ref(rest, atoms),
         {:ok, arg_count, rest} <- LEB128.read_unsigned(rest),
         {:ok, var_count, rest} <- LEB128.read_unsigned(rest),
         {:ok, defined_arg_count, rest} <- LEB128.read_unsigned(rest),
         {:ok, stack_size, rest} <- LEB128.read_unsigned(rest),
         {:ok, var_ref_count, rest} <- LEB128.read_unsigned(rest),
         {:ok, closure_var_count, rest} <- LEB128.read_unsigned(rest),
         {:ok, cpool_count, rest} <- LEB128.read_signed(rest),
         {:ok, byte_code_len, rest} <- LEB128.read_signed(rest),
         {:ok, local_count, rest} <- LEB128.read_signed(rest),
         {:ok, locals, rest} <- read_vardefs(rest, local_count, atoms),
         {:ok, closure_vars, rest} <- read_closure_vars(rest, closure_var_count, atoms),
         {:ok, cpool, rest} <- read_cpool(rest, cpool_count, atoms) do
      if byte_size(rest) < byte_code_len do
        {:error, :unexpected_end}
      else
        <<byte_code::binary-size(byte_code_len), rest::binary>> = rest

        {debug_info, rest} = read_debug_info(rest, flags_map.has_debug_info, atoms)

        fun = %Function{
          name: func_name,
          arg_count: arg_count,
          var_count: var_count,
          defined_arg_count: defined_arg_count,
          stack_size: stack_size,
          var_ref_count: var_ref_count,
          locals: locals,
          closure_vars: closure_vars,
          constants: cpool,
          byte_code: byte_code,
          filename: debug_info.filename,
          line_num: debug_info.line_num,
          col_num: debug_info.col_num,
          pc2line: debug_info.pc2line,
          source: debug_info.source,
          is_strict_mode: strict > 0,
          has_prototype: flags_map.has_prototype,
          has_simple_parameter_list: flags_map.has_simple_parameter_list,
          is_derived_class_constructor: flags_map.is_derived_class_constructor,
          need_home_object: flags_map.need_home_object,
          func_kind: flags_map.func_kind,
          new_target_allowed: flags_map.new_target_allowed,
          super_call_allowed: flags_map.super_call_allowed,
          super_allowed: flags_map.super_allowed,
          arguments_allowed: flags_map.arguments_allowed,
          has_debug_info: flags_map.has_debug_info
        }

        {:ok, fun, rest}
      end
    end
  end

  # Must match JS_WriteFunctionTag bit layout:
  #   bit 0: has_prototype
  #   bit 1: has_simple_parameter_list
  #   bit 2: is_derived_class_constructor
  #   bit 3: need_home_object
  #   bits 4-5: func_kind (2 bits)
  #   bit 6: new_target_allowed
  #   bit 7: super_call_allowed
  #   bit 8: super_allowed
  #   bit 9: arguments_allowed
  #   bit 10: has_debug_info (backtrace_barrier in writer, has_debug_info in reader)
  defp decode_func_flags(v16) do
    %{
      has_prototype: band(bsr(v16, 0), 1) == 1,
      has_simple_parameter_list: band(bsr(v16, 1), 1) == 1,
      is_derived_class_constructor: band(bsr(v16, 2), 1) == 1,
      need_home_object: band(bsr(v16, 3), 1) == 1,
      func_kind: band(bsr(v16, 4), 0x3),
      new_target_allowed: band(bsr(v16, 6), 1) == 1,
      super_call_allowed: band(bsr(v16, 7), 1) == 1,
      super_allowed: band(bsr(v16, 8), 1) == 1,
      arguments_allowed: band(bsr(v16, 9), 1) == 1,
      backtrace_barrier: band(bsr(v16, 10), 1) == 1,
      has_debug_info: band(bsr(v16, 11), 1) == 1
    }
  end

  # ── Vardefs ──
  # Matches JS_ReadFunctionTag vardef loop:
  #   var_name (bc_get_atom), scope_level (leb128_int), scope_next (leb128_int, then -1),
  #   flags (u8): var_kind(4), is_const(1), is_lexical(1), is_captured(1)
  #   if is_captured: var_ref_idx (leb128_u16)

  defp read_vardefs(data, 0, _atoms), do: {:ok, [], data}

  defp read_vardefs(data, count, atoms) do
    read_vardefs_loop(data, count, atoms, [])
  end

  defp read_vardefs_loop(data, 0, _atoms, acc), do: {:ok, Enum.reverse(acc), data}

  defp read_vardefs_loop(data, count, atoms, acc) do
    with {:ok, name, rest} <- read_atom_ref(data, atoms),
         {:ok, scope_level, rest} <- LEB128.read_signed(rest),
         {:ok, scope_next_raw, rest} <- LEB128.read_signed(rest),
         <<flags, rest::binary>> <- rest do
      scope_next = scope_next_raw - 1
      var_kind = band(flags, 0xF)
      is_const = band(bsr(flags, 4), 1) == 1
      is_lexical = band(bsr(flags, 5), 1) == 1
      is_captured = band(bsr(flags, 6), 1) == 1

      {var_ref_idx, rest} =
        if is_captured do
          with {:ok, idx, rest} <- LEB128.read_unsigned(rest), do: {idx, rest}
        else
          {nil, rest}
        end

      vd = %VarDef{
        name: name,
        scope_level: scope_level,
        scope_next: scope_next,
        var_kind: var_kind,
        is_const: is_const,
        is_lexical: is_lexical,
        is_captured: is_captured,
        var_ref_idx: var_ref_idx
      }

      read_vardefs_loop(rest, count - 1, atoms, [vd | acc])
    end
  end

  # ── Closure vars ──
  # Matches JS_ReadFunctionTag closure_var loop:
  #   var_name (bc_get_atom), var_idx (leb128_int), flags (leb128_int):
  #     closure_type(3), is_const(1), is_lexical(1), var_kind(4)

  defp read_closure_vars(data, 0, _atoms), do: {:ok, [], data}
  defp read_closure_vars(data, count, atoms), do: read_closure_vars_loop(data, count, atoms, [])

  defp read_closure_vars_loop(data, 0, _atoms, acc), do: {:ok, Enum.reverse(acc), data}

  defp read_closure_vars_loop(data, count, atoms, acc) do
    with {:ok, name, rest} <- read_atom_ref(data, atoms),
         {:ok, var_idx, rest} <- LEB128.read_signed(rest),
         {:ok, flags, rest} <- LEB128.read_signed(rest) do
      closure_type = band(flags, 0x7)
      is_const = band(bsr(flags, 3), 1) == 1
      is_lexical = band(bsr(flags, 4), 1) == 1
      var_kind = band(bsr(flags, 5), 0xF)

      cv = %ClosureVar{
        name: name,
        var_idx: var_idx,
        closure_type: closure_type,
        is_const: is_const,
        is_lexical: is_lexical,
        var_kind: var_kind
      }

      read_closure_vars_loop(rest, count - 1, atoms, [cv | acc])
    end
  end

  defp read_cpool(data, 0, _atoms), do: {:ok, [], data}
  defp read_cpool(data, count, atoms), do: read_cpool_loop(data, count, atoms, [])

  defp read_cpool_loop(data, 0, _atoms, acc), do: {:ok, Enum.reverse(acc), data}

  defp read_cpool_loop(data, count, atoms, acc) do
    case read_object(data, atoms) do
      {:ok, val, rest} -> read_cpool_loop(rest, count - 1, atoms, [val | acc])
      {:error, _} = err -> err
    end
  end

  defp read_debug_info(data, false, _atoms) do
    {%{filename: nil, line_num: 1, col_num: 1, pc2line: <<>>, source: <<>>}, data}
  end

  defp read_debug_info(data, true, atoms) do
    with {:ok, filename, rest} <- read_atom_ref(data, atoms),
         {:ok, line_num, rest} <- LEB128.read_signed(rest),
         {:ok, col_num, rest} <- LEB128.read_signed(rest),
         {:ok, pc2line_len, rest} <- LEB128.read_signed(rest),
         true <- byte_size(rest) >= pc2line_len,
         <<pc2line::binary-size(pc2line_len), rest::binary>> <- rest,
         {:ok, source_len, rest} <- LEB128.read_signed(rest),
         true <- byte_size(rest) >= source_len,
         <<source::binary-size(source_len), rest::binary>> <- rest do
      {%{
         filename: filename,
         line_num: line_num,
         col_num: col_num,
         pc2line: pc2line,
         source: source
       }, rest}
    else
      _ -> {%{filename: nil, line_num: 1, col_num: 1, pc2line: <<>>, source: <<>>}, data}
    end
  end

  @pc2line_base -1
  @pc2line_range 5
  @pc2line_op_first 1

  @doc "Returns the byte offset of the instruction at `insn_index` within a function bytecode blob."
  def instruction_offset(byte_code, insn_index)
      when is_binary(byte_code) and is_integer(insn_index) do
    do_instruction_offset(byte_code, byte_size(byte_code), 0, 0, insn_index)
  end

  defp do_instruction_offset(_bc, _len, pos, idx, target) when idx >= target, do: pos

  defp do_instruction_offset(bc, len, pos, idx, target) when pos < len do
    op = :binary.at(bc, pos)

    case Opcodes.info(op) do
      {_name, size, _n_pop, _n_push, _fmt} ->
        do_instruction_offset(bc, len, pos + size, idx + 1, target)

      _ ->
        pos
    end
  end

  defp do_instruction_offset(_bc, _len, pos, _idx, _target), do: pos

  @doc "Resolves a decoded function instruction index to source line and column information."
  def source_position(%Function{} = fun, insn_index) do
    pc = instruction_offset(fun.byte_code, insn_index)

    fun
    |> decode_pc2line(pc)
    |> maybe_apply_source_hint(fun)
  end

  defp decode_pc2line(%Function{pc2line: <<>>} = fun, _pc), do: {fun.line_num, fun.col_num}

  defp decode_pc2line(%Function{} = fun, target_pc) do
    do_decode_pc2line(fun.pc2line, target_pc, 0, fun.line_num, fun.col_num)
  end

  defp do_decode_pc2line(<<>>, _target_pc, _pc, line_num, col_num), do: {line_num, col_num}

  defp do_decode_pc2line(data, target_pc, pc, line_num, col_num) do
    <<op_byte, rest::binary>> = data

    {next_pc, next_line, next_col, rest2} =
      if op_byte == 0 do
        {:ok, diff_pc, rest1} = LEB128.read_unsigned(rest)
        {:ok, diff_line, rest2} = LEB128.read_signed(rest1)
        {:ok, diff_col, rest3} = LEB128.read_signed(rest2)
        {pc + diff_pc, line_num + diff_line, col_num + diff_col, rest3}
      else
        op = op_byte - @pc2line_op_first
        {:ok, diff_col, rest3} = LEB128.read_signed(rest)

        {pc + div(op, @pc2line_range), line_num + rem(op, @pc2line_range) + @pc2line_base,
         col_num + diff_col, rest3}
      end

    if target_pc < next_pc do
      {line_num, col_num}
    else
      do_decode_pc2line(rest2, target_pc, next_pc, next_line, next_col)
    end
  end

  defp maybe_apply_source_hint(pos, %Function{source: source}) when is_binary(source) do
    case Regex.scan(~r/line\s+(\d+),\s*column\s+(\d+)/, source, capture: :all_but_first) do
      [[hint_line, hint_col]] ->
        hint = {String.to_integer(hint_line), String.to_integer(hint_col)}
        if pos > hint, do: hint, else: pos

      _ ->
        pos
    end
  end

  defp maybe_apply_source_hint(pos, _fun), do: pos
end
