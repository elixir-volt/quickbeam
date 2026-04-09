defmodule QuickBEAM.WASM.Parser do
  @moduledoc false

  alias QuickBEAM.WASM.{Function, Module}

  @wasm_magic <<0x00, 0x61, 0x73, 0x6D>>
  @wasm_version_1 <<0x01, 0x00, 0x00, 0x00>>

  @section_custom 0
  @section_type 1
  @section_import 2
  @section_function 3
  @section_table 4
  @section_memory 5
  @section_global 6
  @section_export 7
  @section_start 8
  @section_element 9
  @section_code 10
  @section_data 11
  @section_data_count 12
  @section_tag 13

  # ── Public API ─────────────────────────────────────────

  @spec parse(binary()) :: {:ok, Module.t()} | {:error, String.t()}
  def parse(<<@wasm_magic, @wasm_version_1, rest::binary>>) do
    mod = %Module{version: 1}
    parse_sections(rest, mod)
  end

  def parse(<<@wasm_magic, v1, v2, v3, v4, _::binary>>),
    do: {:error, "unsupported WASM version: #{v1}.#{v2}.#{v3}.#{v4}"}

  def parse(_), do: {:error, "not a WASM binary (missing magic header)"}

  @spec validate(binary()) :: boolean()
  def validate(binary) do
    case parse(binary) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  # ── Section dispatch ───────────────────────────────────

  defp parse_sections(<<>>, mod), do: {:ok, finalize(mod)}

  defp parse_sections(<<id, rest::binary>>, mod) do
    {size, rest} = decode_u32(rest)
    <<section_data::binary-size(size), rest::binary>> = rest

    mod = parse_section(id, section_data, mod)
    parse_sections(rest, mod)
  rescue
    MatchError -> {:error, "truncated section (id=#{id})"}
  end

  defp parse_section(@section_custom, data, mod) do
    {name, data} = decode_name(data)
    custom = %{name: name, data: data}
    %{mod | custom_sections: mod.custom_sections ++ [custom]}
  end

  defp parse_section(@section_type, data, mod) do
    {types, <<>>} = decode_vec(data, &decode_functype/1)
    %{mod | types: types}
  end

  defp parse_section(@section_import, data, mod) do
    {imports, <<>>} = decode_vec(data, &decode_import/1)
    %{mod | imports: imports}
  end

  defp parse_section(@section_function, data, mod) do
    {type_indices, <<>>} = decode_vec(data, &decode_u32/1)
    funcs = Enum.with_index(type_indices, fn type_idx, i -> {i, type_idx} end)
    Map.put(mod, :_func_type_indices, funcs)
  end

  defp parse_section(@section_table, data, mod) do
    {tables, <<>>} = decode_vec(data, &decode_table/1)
    %{mod | tables: tables}
  end

  defp parse_section(@section_memory, data, mod) do
    {memories, <<>>} = decode_vec(data, &decode_memory/1)
    %{mod | memories: memories}
  end

  defp parse_section(@section_global, data, mod) do
    {globals, <<>>} = decode_vec(data, &decode_global/1)
    %{mod | globals: globals}
  end

  defp parse_section(@section_export, data, mod) do
    {exports, <<>>} = decode_vec(data, &decode_export/1)
    %{mod | exports: exports}
  end

  defp parse_section(@section_start, data, mod) do
    {func_idx, <<>>} = decode_u32(data)
    %{mod | start: func_idx}
  end

  defp parse_section(@section_element, data, mod) do
    {elements, <<>>} = decode_vec(data, &decode_element/1)
    %{mod | elements: elements}
  end

  defp parse_section(@section_code, data, mod) do
    {bodies, <<>>} = decode_vec(data, &decode_code_body/1)
    Map.put(mod, :_code_bodies, bodies)
  end

  defp parse_section(@section_data, data, mod) do
    {segments, <<>>} = decode_vec(data, &decode_data_segment/1)
    %{mod | data: segments}
  end

  defp parse_section(@section_data_count, data, mod) do
    {count, <<>>} = decode_u32(data)
    Map.put(mod, :_data_count, count)
  end

  defp parse_section(@section_tag, data, mod) do
    {tags, <<>>} = decode_vec(data, &decode_tag/1)
    %{mod | tags: tags}
  end

  defp parse_section(_id, _data, mod), do: mod

  # ── Finalization ───────────────────────────────────────

  defp finalize(mod) do
    func_type_indices = Map.get(mod, :_func_type_indices, [])
    code_bodies = Map.get(mod, :_code_bodies, [])
    names = extract_names(mod.custom_sections)

    num_imports = Enum.count(mod.imports, &(&1.kind == :func))

    functions =
      Enum.zip(func_type_indices, code_bodies)
      |> Enum.map(fn {{local_idx, type_idx}, {locals, opcodes}} ->
        func_idx = num_imports + local_idx
        type = Enum.at(mod.types, type_idx, %{params: [], results: []})

        %Function{
          index: func_idx,
          name: Map.get(names, func_idx),
          type_idx: type_idx,
          params: type.params,
          results: type.results,
          locals: locals,
          opcodes: opcodes
        }
      end)

    mod =
      mod
      |> Map.delete(:_func_type_indices)
      |> Map.delete(:_code_bodies)
      |> Map.delete(:_data_count)

    imports = Enum.map(mod.imports, &enrich_import(&1, mod.types))
    exports = Enum.map(mod.exports, &enrich_export(&1, mod, func_type_indices))

    %{mod | functions: functions, imports: imports, exports: exports}
  end

  defp extract_names(custom_sections) do
    case Enum.find(custom_sections, &(&1.name == "name")) do
      nil -> %{}
      %{data: data} -> parse_name_section(data)
    end
  end

  defp parse_name_section(data), do: parse_name_subsections(data, %{})

  defp parse_name_subsections(<<>>, names), do: names

  defp parse_name_subsections(<<id, rest::binary>>, names) do
    {size, rest} = decode_u32(rest)
    <<subsection::binary-size(size), rest::binary>> = rest

    names =
      case id do
        1 -> parse_name_map(subsection)
        _ -> names
      end

    parse_name_subsections(rest, names)
  rescue
    _ -> names
  end

  defp parse_name_map(data) do
    {entries, _} =
      decode_vec(data, fn bin ->
        {idx, bin} = decode_u32(bin)
        {name, bin} = decode_name(bin)
        {{idx, name}, bin}
      end)

    Map.new(entries)
  end

  defp enrich_import(%{kind: :func, type_idx: type_idx} = import, types) do
    type = Enum.at(types, type_idx, %{params: [], results: []})
    Map.merge(import, %{params: type.params, results: type.results})
  end

  defp enrich_import(import, _types), do: import

  defp enrich_export(%{kind: :func, index: index} = export, mod, func_type_indices) do
    type_idx = function_type_idx(mod.imports, func_type_indices, index)
    type = Enum.at(mod.types, type_idx || -1, %{params: [], results: []})
    Map.merge(export, %{params: type.params, results: type.results})
  end

  defp enrich_export(%{kind: :memory, index: index} = export, mod, _func_type_indices) do
    Map.merge(export, Enum.at(mod.memories, index, %{}))
  end

  defp enrich_export(%{kind: :table, index: index} = export, mod, _func_type_indices) do
    Map.merge(export, Enum.at(mod.tables, index, %{}))
  end

  defp enrich_export(%{kind: :global, index: index} = export, mod, _func_type_indices) do
    global = mod.globals |> Enum.at(index, %{}) |> Map.drop([:init])
    Map.merge(export, global)
  end

  defp enrich_export(export, _mod, _func_type_indices), do: export

  defp function_type_idx(imports, func_type_indices, index) do
    import_type_indices =
      imports
      |> Enum.filter(&(&1.kind == :func))
      |> Enum.map(& &1.type_idx)

    if index < length(import_type_indices) do
      Enum.at(import_type_indices, index)
    else
      local_idx = index - length(import_type_indices)

      case Enum.at(func_type_indices, local_idx) do
        {_, type_idx} -> type_idx
        _ -> nil
      end
    end
  end

  # ── Type decoders ──────────────────────────────────────

  defp decode_functype(<<0x60, rest::binary>>) do
    {params, rest} = decode_vec(rest, &decode_valtype/1)
    {results, rest} = decode_vec(rest, &decode_valtype/1)
    {%{params: params, results: results}, rest}
  end

  defp decode_valtype(<<0x7F, rest::binary>>), do: {:i32, rest}
  defp decode_valtype(<<0x7E, rest::binary>>), do: {:i64, rest}
  defp decode_valtype(<<0x7D, rest::binary>>), do: {:f32, rest}
  defp decode_valtype(<<0x7C, rest::binary>>), do: {:f64, rest}
  defp decode_valtype(<<0x7B, rest::binary>>), do: {:v128, rest}
  defp decode_valtype(<<0x70, rest::binary>>), do: {:funcref, rest}
  defp decode_valtype(<<0x6F, rest::binary>>), do: {:externref, rest}

  defp decode_valtype(<<byte, rest::binary>>),
    do: {:unknown_valtype, <<byte, rest::binary>>}

  # ── Import decoders ────────────────────────────────────

  defp decode_import(data) do
    {module_name, data} = decode_name(data)
    {field_name, data} = decode_name(data)
    {desc, data} = decode_import_desc(data)
    {Map.merge(%{module: module_name, name: field_name}, desc), data}
  end

  defp decode_import_desc(<<0x00, rest::binary>>) do
    {type_idx, rest} = decode_u32(rest)
    {%{kind: :func, type_idx: type_idx}, rest}
  end

  defp decode_import_desc(<<0x01, rest::binary>>) do
    {table, rest} = decode_table_type(rest)
    {Map.put(table, :kind, :table), rest}
  end

  defp decode_import_desc(<<0x02, rest::binary>>) do
    {mem, rest} = decode_limits(rest)
    {Map.put(mem, :kind, :memory), rest}
  end

  defp decode_import_desc(<<0x03, rest::binary>>) do
    {global, rest} = decode_global_type(rest)
    {Map.put(global, :kind, :global), rest}
  end

  defp decode_import_desc(<<0x04, rest::binary>>) do
    {tag, rest} = decode_tag_type(rest)
    {Map.put(tag, :kind, :tag), rest}
  end

  # ── Export decoders ────────────────────────────────────

  defp decode_export(data) do
    {name, data} = decode_name(data)
    <<kind_byte, data::binary>> = data
    {index, data} = decode_u32(data)

    kind =
      case kind_byte do
        0x00 -> :func
        0x01 -> :table
        0x02 -> :memory
        0x03 -> :global
        0x04 -> :tag
      end

    {%{name: name, kind: kind, index: index}, data}
  end

  # ── Table / Memory / Global decoders ───────────────────

  defp decode_table(data), do: decode_table_type(data)

  defp decode_table_type(data) do
    {elem_type, data} = decode_valtype(data)
    {limits, data} = decode_limits(data)
    {Map.put(limits, :element, elem_type), data}
  end

  defp decode_memory(data), do: decode_limits(data)

  defp decode_limits(<<0x00, rest::binary>>) do
    {min, rest} = decode_u32(rest)
    {%{min: min, max: nil}, rest}
  end

  defp decode_limits(<<0x01, rest::binary>>) do
    {min, rest} = decode_u32(rest)
    {max, rest} = decode_u32(rest)
    {%{min: min, max: max}, rest}
  end

  defp decode_global(data) do
    {type, data} = decode_global_type(data)
    {init_opcodes, data} = decode_expr(data)
    {Map.put(type, :init, init_opcodes), data}
  end

  defp decode_global_type(data) do
    {valtype, data} = decode_valtype(data)
    <<mutability, data::binary>> = data
    {%{type: valtype, mutable: mutability == 1}, data}
  end

  defp decode_tag_type(<<0x00, rest::binary>>) do
    {type_idx, rest} = decode_u32(rest)
    {%{type_idx: type_idx}, rest}
  end

  defp decode_tag(data), do: decode_tag_type(data)

  # ── Element decoders ───────────────────────────────────

  defp decode_element(<<0x00, rest::binary>>) do
    {offset, rest} = decode_expr(rest)
    {func_indices, rest} = decode_vec(rest, &decode_u32/1)
    {%{mode: :active, table_idx: 0, offset: offset, init: func_indices}, rest}
  end

  defp decode_element(<<kind, rest::binary>>) when kind in 1..7 do
    {%{mode: :unhandled_element_kind, kind: kind, data: rest}, <<>>}
  end

  # ── Data segment decoders ──────────────────────────────

  defp decode_data_segment(<<0x00, rest::binary>>) do
    {offset, rest} = decode_expr(rest)
    {size, rest} = decode_u32(rest)
    <<bytes::binary-size(size), rest::binary>> = rest
    {%{memory_idx: 0, offset: offset, bytes: bytes}, rest}
  end

  defp decode_data_segment(<<0x01, rest::binary>>) do
    {size, rest} = decode_u32(rest)
    <<bytes::binary-size(size), rest::binary>> = rest
    {%{memory_idx: nil, offset: nil, bytes: bytes}, rest}
  end

  defp decode_data_segment(<<0x02, rest::binary>>) do
    {mem_idx, rest} = decode_u32(rest)
    {offset, rest} = decode_expr(rest)
    {size, rest} = decode_u32(rest)
    <<bytes::binary-size(size), rest::binary>> = rest
    {%{memory_idx: mem_idx, offset: offset, bytes: bytes}, rest}
  end

  # ── Code body decoder ──────────────────────────────────

  defp decode_code_body(data) do
    {body_size, data} = decode_u32(data)
    <<body::binary-size(body_size), rest::binary>> = data
    {locals, body} = decode_locals(body)
    opcodes = decode_instructions(body)
    {{locals, opcodes}, rest}
  end

  defp decode_locals(data) do
    {groups, data} =
      decode_vec(data, fn bin ->
        {count, bin} = decode_u32(bin)
        {type, bin} = decode_valtype(bin)
        {{count, type}, bin}
      end)

    locals = Enum.flat_map(groups, fn {count, type} -> List.duplicate(type, count) end)
    {locals, data}
  end

  # ── Expression decoder (for init exprs) ────────────────

  defp decode_expr(data) do
    {opcodes, rest} = decode_instructions_until_end(data, 0, [])
    {opcodes, rest}
  end

  # ── Instruction decoder ────────────────────────────────

  defp decode_instructions(data) do
    {opcodes, _} = decode_instructions_until_end(data, 0, [])
    opcodes
  end

  defp decode_instructions_until_end(<<>>, _offset, acc), do: {Enum.reverse(acc), <<>>}

  defp decode_instructions_until_end(<<0x0B, rest::binary>>, offset, acc) do
    {Enum.reverse([{offset, :end} | acc]), rest}
  end

  defp decode_instructions_until_end(data, offset, acc) do
    {opcode, rest} = decode_one_instruction(data, offset)
    next_offset = offset + (byte_size(data) - byte_size(rest))
    decode_instructions_until_end(rest, next_offset, [opcode | acc])
  end

  # Control
  defp decode_one_instruction(<<0x00, rest::binary>>, off), do: {{off, :unreachable}, rest}
  defp decode_one_instruction(<<0x01, rest::binary>>, off), do: {{off, :nop}, rest}

  defp decode_one_instruction(<<0x02, rest::binary>>, off) do
    {bt, rest} = decode_blocktype(rest)
    {{off, :block, bt}, rest}
  end

  defp decode_one_instruction(<<0x03, rest::binary>>, off) do
    {bt, rest} = decode_blocktype(rest)
    {{off, :loop, bt}, rest}
  end

  defp decode_one_instruction(<<0x04, rest::binary>>, off) do
    {bt, rest} = decode_blocktype(rest)
    {{off, :if, bt}, rest}
  end

  defp decode_one_instruction(<<0x05, rest::binary>>, off), do: {{off, :else}, rest}
  defp decode_one_instruction(<<0x0B, rest::binary>>, off), do: {{off, :end}, rest}

  defp decode_one_instruction(<<0x0C, rest::binary>>, off) do
    {label, rest} = decode_u32(rest)
    {{off, :br, label}, rest}
  end

  defp decode_one_instruction(<<0x0D, rest::binary>>, off) do
    {label, rest} = decode_u32(rest)
    {{off, :br_if, label}, rest}
  end

  defp decode_one_instruction(<<0x0E, rest::binary>>, off) do
    {labels, rest} = decode_vec(rest, &decode_u32/1)
    {default, rest} = decode_u32(rest)
    {{off, :br_table, labels, default}, rest}
  end

  defp decode_one_instruction(<<0x0F, rest::binary>>, off), do: {{off, :return}, rest}

  defp decode_one_instruction(<<0x10, rest::binary>>, off) do
    {idx, rest} = decode_u32(rest)
    {{off, :call, idx}, rest}
  end

  defp decode_one_instruction(<<0x11, rest::binary>>, off) do
    {type_idx, rest} = decode_u32(rest)
    {table_idx, rest} = decode_u32(rest)
    {{off, :call_indirect, table_idx, type_idx}, rest}
  end

  defp decode_one_instruction(<<0x12, rest::binary>>, off) do
    {idx, rest} = decode_u32(rest)
    {{off, :return_call, idx}, rest}
  end

  defp decode_one_instruction(<<0x13, rest::binary>>, off) do
    {type_idx, rest} = decode_u32(rest)
    {table_idx, rest} = decode_u32(rest)
    {{off, :return_call_indirect, table_idx, type_idx}, rest}
  end

  # Parametric
  defp decode_one_instruction(<<0x1A, rest::binary>>, off), do: {{off, :drop}, rest}
  defp decode_one_instruction(<<0x1B, rest::binary>>, off), do: {{off, :select}, rest}

  defp decode_one_instruction(<<0x1C, rest::binary>>, off) do
    {types, rest} = decode_vec(rest, &decode_valtype/1)
    {{off, :select, types}, rest}
  end

  # Variable
  defp decode_one_instruction(<<0x20, rest::binary>>, off) do
    {idx, rest} = decode_u32(rest)
    {{off, :local_get, idx}, rest}
  end

  defp decode_one_instruction(<<0x21, rest::binary>>, off) do
    {idx, rest} = decode_u32(rest)
    {{off, :local_set, idx}, rest}
  end

  defp decode_one_instruction(<<0x22, rest::binary>>, off) do
    {idx, rest} = decode_u32(rest)
    {{off, :local_tee, idx}, rest}
  end

  defp decode_one_instruction(<<0x23, rest::binary>>, off) do
    {idx, rest} = decode_u32(rest)
    {{off, :global_get, idx}, rest}
  end

  defp decode_one_instruction(<<0x24, rest::binary>>, off) do
    {idx, rest} = decode_u32(rest)
    {{off, :global_set, idx}, rest}
  end

  # Table
  defp decode_one_instruction(<<0x25, rest::binary>>, off) do
    {idx, rest} = decode_u32(rest)
    {{off, :table_get, idx}, rest}
  end

  defp decode_one_instruction(<<0x26, rest::binary>>, off) do
    {idx, rest} = decode_u32(rest)
    {{off, :table_set, idx}, rest}
  end

  # Memory load/store
  defp decode_one_instruction(<<opcode, rest::binary>>, off) when opcode in 0x28..0x3E do
    {align, rest} = decode_u32(rest)
    {mem_offset, rest} = decode_u32(rest)
    name = memory_op_name(opcode)
    {{off, name, align, mem_offset}, rest}
  end

  # Memory size/grow
  defp decode_one_instruction(<<0x3F, 0x00, rest::binary>>, off),
    do: {{off, :memory_size, 0}, rest}

  defp decode_one_instruction(<<0x40, 0x00, rest::binary>>, off),
    do: {{off, :memory_grow, 0}, rest}

  # Numeric constants
  defp decode_one_instruction(<<0x41, rest::binary>>, off) do
    {val, rest} = decode_i32(rest)
    {{off, :i32_const, val}, rest}
  end

  defp decode_one_instruction(<<0x42, rest::binary>>, off) do
    {val, rest} = decode_i64(rest)
    {{off, :i64_const, val}, rest}
  end

  defp decode_one_instruction(<<0x43, val::little-float-32, rest::binary>>, off),
    do: {{off, :f32_const, val}, rest}

  defp decode_one_instruction(<<0x44, val::little-float-64, rest::binary>>, off),
    do: {{off, :f64_const, val}, rest}

  # i32 comparison/arithmetic
  defp decode_one_instruction(<<0x45, rest::binary>>, off), do: {{off, :i32_eqz}, rest}
  defp decode_one_instruction(<<0x46, rest::binary>>, off), do: {{off, :i32_eq}, rest}
  defp decode_one_instruction(<<0x47, rest::binary>>, off), do: {{off, :i32_ne}, rest}
  defp decode_one_instruction(<<0x48, rest::binary>>, off), do: {{off, :i32_lt_s}, rest}
  defp decode_one_instruction(<<0x49, rest::binary>>, off), do: {{off, :i32_lt_u}, rest}
  defp decode_one_instruction(<<0x4A, rest::binary>>, off), do: {{off, :i32_gt_s}, rest}
  defp decode_one_instruction(<<0x4B, rest::binary>>, off), do: {{off, :i32_gt_u}, rest}
  defp decode_one_instruction(<<0x4C, rest::binary>>, off), do: {{off, :i32_le_s}, rest}
  defp decode_one_instruction(<<0x4D, rest::binary>>, off), do: {{off, :i32_le_u}, rest}
  defp decode_one_instruction(<<0x4E, rest::binary>>, off), do: {{off, :i32_ge_s}, rest}
  defp decode_one_instruction(<<0x4F, rest::binary>>, off), do: {{off, :i32_ge_u}, rest}

  # i64 comparison
  defp decode_one_instruction(<<0x50, rest::binary>>, off), do: {{off, :i64_eqz}, rest}
  defp decode_one_instruction(<<0x51, rest::binary>>, off), do: {{off, :i64_eq}, rest}
  defp decode_one_instruction(<<0x52, rest::binary>>, off), do: {{off, :i64_ne}, rest}
  defp decode_one_instruction(<<0x53, rest::binary>>, off), do: {{off, :i64_lt_s}, rest}
  defp decode_one_instruction(<<0x54, rest::binary>>, off), do: {{off, :i64_lt_u}, rest}
  defp decode_one_instruction(<<0x55, rest::binary>>, off), do: {{off, :i64_gt_s}, rest}
  defp decode_one_instruction(<<0x56, rest::binary>>, off), do: {{off, :i64_gt_u}, rest}
  defp decode_one_instruction(<<0x57, rest::binary>>, off), do: {{off, :i64_le_s}, rest}
  defp decode_one_instruction(<<0x58, rest::binary>>, off), do: {{off, :i64_le_u}, rest}
  defp decode_one_instruction(<<0x59, rest::binary>>, off), do: {{off, :i64_ge_s}, rest}
  defp decode_one_instruction(<<0x5A, rest::binary>>, off), do: {{off, :i64_ge_u}, rest}

  # f32 comparison
  defp decode_one_instruction(<<0x5B, rest::binary>>, off), do: {{off, :f32_eq}, rest}
  defp decode_one_instruction(<<0x5C, rest::binary>>, off), do: {{off, :f32_ne}, rest}
  defp decode_one_instruction(<<0x5D, rest::binary>>, off), do: {{off, :f32_lt}, rest}
  defp decode_one_instruction(<<0x5E, rest::binary>>, off), do: {{off, :f32_gt}, rest}
  defp decode_one_instruction(<<0x5F, rest::binary>>, off), do: {{off, :f32_le}, rest}
  defp decode_one_instruction(<<0x60, rest::binary>>, off), do: {{off, :f32_ge}, rest}

  # f64 comparison
  defp decode_one_instruction(<<0x61, rest::binary>>, off), do: {{off, :f64_eq}, rest}
  defp decode_one_instruction(<<0x62, rest::binary>>, off), do: {{off, :f64_ne}, rest}
  defp decode_one_instruction(<<0x63, rest::binary>>, off), do: {{off, :f64_lt}, rest}
  defp decode_one_instruction(<<0x64, rest::binary>>, off), do: {{off, :f64_gt}, rest}
  defp decode_one_instruction(<<0x65, rest::binary>>, off), do: {{off, :f64_le}, rest}
  defp decode_one_instruction(<<0x66, rest::binary>>, off), do: {{off, :f64_ge}, rest}

  # i32 arithmetic
  defp decode_one_instruction(<<0x67, rest::binary>>, off), do: {{off, :i32_clz}, rest}
  defp decode_one_instruction(<<0x68, rest::binary>>, off), do: {{off, :i32_ctz}, rest}
  defp decode_one_instruction(<<0x69, rest::binary>>, off), do: {{off, :i32_popcnt}, rest}
  defp decode_one_instruction(<<0x6A, rest::binary>>, off), do: {{off, :i32_add}, rest}
  defp decode_one_instruction(<<0x6B, rest::binary>>, off), do: {{off, :i32_sub}, rest}
  defp decode_one_instruction(<<0x6C, rest::binary>>, off), do: {{off, :i32_mul}, rest}
  defp decode_one_instruction(<<0x6D, rest::binary>>, off), do: {{off, :i32_div_s}, rest}
  defp decode_one_instruction(<<0x6E, rest::binary>>, off), do: {{off, :i32_div_u}, rest}
  defp decode_one_instruction(<<0x6F, rest::binary>>, off), do: {{off, :i32_rem_s}, rest}
  defp decode_one_instruction(<<0x70, rest::binary>>, off), do: {{off, :i32_rem_u}, rest}
  defp decode_one_instruction(<<0x71, rest::binary>>, off), do: {{off, :i32_and}, rest}
  defp decode_one_instruction(<<0x72, rest::binary>>, off), do: {{off, :i32_or}, rest}
  defp decode_one_instruction(<<0x73, rest::binary>>, off), do: {{off, :i32_xor}, rest}
  defp decode_one_instruction(<<0x74, rest::binary>>, off), do: {{off, :i32_shl}, rest}
  defp decode_one_instruction(<<0x75, rest::binary>>, off), do: {{off, :i32_shr_s}, rest}
  defp decode_one_instruction(<<0x76, rest::binary>>, off), do: {{off, :i32_shr_u}, rest}
  defp decode_one_instruction(<<0x77, rest::binary>>, off), do: {{off, :i32_rotl}, rest}
  defp decode_one_instruction(<<0x78, rest::binary>>, off), do: {{off, :i32_rotr}, rest}

  # i64 arithmetic
  defp decode_one_instruction(<<0x79, rest::binary>>, off), do: {{off, :i64_clz}, rest}
  defp decode_one_instruction(<<0x7A, rest::binary>>, off), do: {{off, :i64_ctz}, rest}
  defp decode_one_instruction(<<0x7B, rest::binary>>, off), do: {{off, :i64_popcnt}, rest}
  defp decode_one_instruction(<<0x7C, rest::binary>>, off), do: {{off, :i64_add}, rest}
  defp decode_one_instruction(<<0x7D, rest::binary>>, off), do: {{off, :i64_sub}, rest}
  defp decode_one_instruction(<<0x7E, rest::binary>>, off), do: {{off, :i64_mul}, rest}
  defp decode_one_instruction(<<0x7F, rest::binary>>, off), do: {{off, :i64_div_s}, rest}
  defp decode_one_instruction(<<0x80, rest::binary>>, off), do: {{off, :i64_div_u}, rest}
  defp decode_one_instruction(<<0x81, rest::binary>>, off), do: {{off, :i64_rem_s}, rest}
  defp decode_one_instruction(<<0x82, rest::binary>>, off), do: {{off, :i64_rem_u}, rest}
  defp decode_one_instruction(<<0x83, rest::binary>>, off), do: {{off, :i64_and}, rest}
  defp decode_one_instruction(<<0x84, rest::binary>>, off), do: {{off, :i64_or}, rest}
  defp decode_one_instruction(<<0x85, rest::binary>>, off), do: {{off, :i64_xor}, rest}
  defp decode_one_instruction(<<0x86, rest::binary>>, off), do: {{off, :i64_shl}, rest}
  defp decode_one_instruction(<<0x87, rest::binary>>, off), do: {{off, :i64_shr_s}, rest}
  defp decode_one_instruction(<<0x88, rest::binary>>, off), do: {{off, :i64_shr_u}, rest}
  defp decode_one_instruction(<<0x89, rest::binary>>, off), do: {{off, :i64_rotl}, rest}
  defp decode_one_instruction(<<0x8A, rest::binary>>, off), do: {{off, :i64_rotr}, rest}

  # f32 arithmetic
  defp decode_one_instruction(<<0x8B, rest::binary>>, off), do: {{off, :f32_abs}, rest}
  defp decode_one_instruction(<<0x8C, rest::binary>>, off), do: {{off, :f32_neg}, rest}
  defp decode_one_instruction(<<0x8D, rest::binary>>, off), do: {{off, :f32_ceil}, rest}
  defp decode_one_instruction(<<0x8E, rest::binary>>, off), do: {{off, :f32_floor}, rest}
  defp decode_one_instruction(<<0x8F, rest::binary>>, off), do: {{off, :f32_trunc}, rest}
  defp decode_one_instruction(<<0x90, rest::binary>>, off), do: {{off, :f32_nearest}, rest}
  defp decode_one_instruction(<<0x91, rest::binary>>, off), do: {{off, :f32_sqrt}, rest}
  defp decode_one_instruction(<<0x92, rest::binary>>, off), do: {{off, :f32_add}, rest}
  defp decode_one_instruction(<<0x93, rest::binary>>, off), do: {{off, :f32_sub}, rest}
  defp decode_one_instruction(<<0x94, rest::binary>>, off), do: {{off, :f32_mul}, rest}
  defp decode_one_instruction(<<0x95, rest::binary>>, off), do: {{off, :f32_div}, rest}
  defp decode_one_instruction(<<0x96, rest::binary>>, off), do: {{off, :f32_min}, rest}
  defp decode_one_instruction(<<0x97, rest::binary>>, off), do: {{off, :f32_max}, rest}
  defp decode_one_instruction(<<0x98, rest::binary>>, off), do: {{off, :f32_copysign}, rest}

  # f64 arithmetic
  defp decode_one_instruction(<<0x99, rest::binary>>, off), do: {{off, :f64_abs}, rest}
  defp decode_one_instruction(<<0x9A, rest::binary>>, off), do: {{off, :f64_neg}, rest}
  defp decode_one_instruction(<<0x9B, rest::binary>>, off), do: {{off, :f64_ceil}, rest}
  defp decode_one_instruction(<<0x9C, rest::binary>>, off), do: {{off, :f64_floor}, rest}
  defp decode_one_instruction(<<0x9D, rest::binary>>, off), do: {{off, :f64_trunc}, rest}
  defp decode_one_instruction(<<0x9E, rest::binary>>, off), do: {{off, :f64_nearest}, rest}
  defp decode_one_instruction(<<0x9F, rest::binary>>, off), do: {{off, :f64_sqrt}, rest}
  defp decode_one_instruction(<<0xA0, rest::binary>>, off), do: {{off, :f64_add}, rest}
  defp decode_one_instruction(<<0xA1, rest::binary>>, off), do: {{off, :f64_sub}, rest}
  defp decode_one_instruction(<<0xA2, rest::binary>>, off), do: {{off, :f64_mul}, rest}
  defp decode_one_instruction(<<0xA3, rest::binary>>, off), do: {{off, :f64_div}, rest}
  defp decode_one_instruction(<<0xA4, rest::binary>>, off), do: {{off, :f64_min}, rest}
  defp decode_one_instruction(<<0xA5, rest::binary>>, off), do: {{off, :f64_max}, rest}
  defp decode_one_instruction(<<0xA6, rest::binary>>, off), do: {{off, :f64_copysign}, rest}

  # Conversions
  defp decode_one_instruction(<<0xA7, rest::binary>>, off), do: {{off, :i32_wrap_i64}, rest}
  defp decode_one_instruction(<<0xA8, rest::binary>>, off), do: {{off, :i32_trunc_f32_s}, rest}
  defp decode_one_instruction(<<0xA9, rest::binary>>, off), do: {{off, :i32_trunc_f32_u}, rest}
  defp decode_one_instruction(<<0xAA, rest::binary>>, off), do: {{off, :i32_trunc_f64_s}, rest}
  defp decode_one_instruction(<<0xAB, rest::binary>>, off), do: {{off, :i32_trunc_f64_u}, rest}
  defp decode_one_instruction(<<0xAC, rest::binary>>, off), do: {{off, :i64_extend_i32_s}, rest}
  defp decode_one_instruction(<<0xAD, rest::binary>>, off), do: {{off, :i64_extend_i32_u}, rest}
  defp decode_one_instruction(<<0xAE, rest::binary>>, off), do: {{off, :i64_trunc_f32_s}, rest}
  defp decode_one_instruction(<<0xAF, rest::binary>>, off), do: {{off, :i64_trunc_f32_u}, rest}
  defp decode_one_instruction(<<0xB0, rest::binary>>, off), do: {{off, :i64_trunc_f64_s}, rest}
  defp decode_one_instruction(<<0xB1, rest::binary>>, off), do: {{off, :i64_trunc_f64_u}, rest}
  defp decode_one_instruction(<<0xB2, rest::binary>>, off), do: {{off, :f32_convert_i32_s}, rest}
  defp decode_one_instruction(<<0xB3, rest::binary>>, off), do: {{off, :f32_convert_i32_u}, rest}
  defp decode_one_instruction(<<0xB4, rest::binary>>, off), do: {{off, :f32_convert_i64_s}, rest}
  defp decode_one_instruction(<<0xB5, rest::binary>>, off), do: {{off, :f32_convert_i64_u}, rest}
  defp decode_one_instruction(<<0xB6, rest::binary>>, off), do: {{off, :f32_demote_f64}, rest}
  defp decode_one_instruction(<<0xB7, rest::binary>>, off), do: {{off, :f64_convert_i32_s}, rest}
  defp decode_one_instruction(<<0xB8, rest::binary>>, off), do: {{off, :f64_convert_i32_u}, rest}
  defp decode_one_instruction(<<0xB9, rest::binary>>, off), do: {{off, :f64_convert_i64_s}, rest}
  defp decode_one_instruction(<<0xBA, rest::binary>>, off), do: {{off, :f64_convert_i64_u}, rest}
  defp decode_one_instruction(<<0xBB, rest::binary>>, off), do: {{off, :f64_promote_f32}, rest}

  defp decode_one_instruction(<<0xBC, rest::binary>>, off),
    do: {{off, :i32_reinterpret_f32}, rest}

  defp decode_one_instruction(<<0xBD, rest::binary>>, off),
    do: {{off, :i64_reinterpret_f64}, rest}

  defp decode_one_instruction(<<0xBE, rest::binary>>, off),
    do: {{off, :f32_reinterpret_i32}, rest}

  defp decode_one_instruction(<<0xBF, rest::binary>>, off),
    do: {{off, :f64_reinterpret_i64}, rest}

  # Sign extension
  defp decode_one_instruction(<<0xC0, rest::binary>>, off), do: {{off, :i32_extend8_s}, rest}
  defp decode_one_instruction(<<0xC1, rest::binary>>, off), do: {{off, :i32_extend16_s}, rest}
  defp decode_one_instruction(<<0xC2, rest::binary>>, off), do: {{off, :i64_extend8_s}, rest}
  defp decode_one_instruction(<<0xC3, rest::binary>>, off), do: {{off, :i64_extend16_s}, rest}
  defp decode_one_instruction(<<0xC4, rest::binary>>, off), do: {{off, :i64_extend32_s}, rest}

  # Reference instructions
  defp decode_one_instruction(<<0xD0, rest::binary>>, off) do
    {ht, rest} = decode_valtype(rest)
    {{off, :ref_null, ht}, rest}
  end

  defp decode_one_instruction(<<0xD1, rest::binary>>, off), do: {{off, :ref_is_null}, rest}

  defp decode_one_instruction(<<0xD2, rest::binary>>, off) do
    {idx, rest} = decode_u32(rest)
    {{off, :ref_func, idx}, rest}
  end

  # 0xFC prefix — saturating truncation + bulk memory + table ops
  defp decode_one_instruction(<<0xFC, rest::binary>>, off) do
    {sub, rest} = decode_u32(rest)
    decode_fc_instruction(sub, rest, off)
  end

  # Catch-all for unknown opcodes
  defp decode_one_instruction(<<byte, rest::binary>>, off),
    do: {{off, :unknown, byte}, rest}

  # ── 0xFC sub-opcodes ───────────────────────────────────

  defp decode_fc_instruction(0, rest, off), do: {{off, :i32_trunc_sat_f32_s}, rest}
  defp decode_fc_instruction(1, rest, off), do: {{off, :i32_trunc_sat_f32_u}, rest}
  defp decode_fc_instruction(2, rest, off), do: {{off, :i32_trunc_sat_f64_s}, rest}
  defp decode_fc_instruction(3, rest, off), do: {{off, :i32_trunc_sat_f64_u}, rest}
  defp decode_fc_instruction(4, rest, off), do: {{off, :i64_trunc_sat_f32_s}, rest}
  defp decode_fc_instruction(5, rest, off), do: {{off, :i64_trunc_sat_f32_u}, rest}
  defp decode_fc_instruction(6, rest, off), do: {{off, :i64_trunc_sat_f64_s}, rest}
  defp decode_fc_instruction(7, rest, off), do: {{off, :i64_trunc_sat_f64_u}, rest}

  defp decode_fc_instruction(8, rest, off) do
    {data_idx, rest} = decode_u32(rest)
    <<0x00, rest::binary>> = rest
    {{off, :memory_init, data_idx, 0}, rest}
  end

  defp decode_fc_instruction(9, rest, off) do
    {data_idx, rest} = decode_u32(rest)
    {{off, :data_drop, data_idx}, rest}
  end

  defp decode_fc_instruction(10, <<0x00, 0x00, rest::binary>>, off),
    do: {{off, :memory_copy, 0, 0}, rest}

  defp decode_fc_instruction(11, <<0x00, rest::binary>>, off),
    do: {{off, :memory_fill, 0}, rest}

  defp decode_fc_instruction(12, rest, off) do
    {elem_idx, rest} = decode_u32(rest)
    {table_idx, rest} = decode_u32(rest)
    {{off, :table_init, table_idx, elem_idx}, rest}
  end

  defp decode_fc_instruction(13, rest, off) do
    {elem_idx, rest} = decode_u32(rest)
    {{off, :elem_drop, elem_idx}, rest}
  end

  defp decode_fc_instruction(14, rest, off) do
    {dst, rest} = decode_u32(rest)
    {src, rest} = decode_u32(rest)
    {{off, :table_copy, dst, src}, rest}
  end

  defp decode_fc_instruction(15, rest, off) do
    {table_idx, rest} = decode_u32(rest)
    {{off, :table_grow, table_idx}, rest}
  end

  defp decode_fc_instruction(16, rest, off) do
    {table_idx, rest} = decode_u32(rest)
    {{off, :table_size, table_idx}, rest}
  end

  defp decode_fc_instruction(17, rest, off) do
    {table_idx, rest} = decode_u32(rest)
    {{off, :table_fill, table_idx}, rest}
  end

  defp decode_fc_instruction(sub, rest, off),
    do: {{off, :unknown_fc, sub}, rest}

  # ── Block type decoder ─────────────────────────────────

  defp decode_blocktype(<<0x40, rest::binary>>), do: {:void, rest}
  defp decode_blocktype(<<0x7F, rest::binary>>), do: {:i32, rest}
  defp decode_blocktype(<<0x7E, rest::binary>>), do: {:i64, rest}
  defp decode_blocktype(<<0x7D, rest::binary>>), do: {:f32, rest}
  defp decode_blocktype(<<0x7C, rest::binary>>), do: {:f64, rest}
  defp decode_blocktype(<<0x7B, rest::binary>>), do: {:v128, rest}
  defp decode_blocktype(<<0x70, rest::binary>>), do: {:funcref, rest}
  defp decode_blocktype(<<0x6F, rest::binary>>), do: {:externref, rest}

  defp decode_blocktype(data) do
    {idx, rest} = decode_s33(data)
    {{:type, idx}, rest}
  end

  # ── Memory op name lookup ──────────────────────────────

  @memory_ops %{
    0x28 => :i32_load,
    0x29 => :i64_load,
    0x2A => :f32_load,
    0x2B => :f64_load,
    0x2C => :i32_load8_s,
    0x2D => :i32_load8_u,
    0x2E => :i32_load16_s,
    0x2F => :i32_load16_u,
    0x30 => :i64_load8_s,
    0x31 => :i64_load8_u,
    0x32 => :i64_load16_s,
    0x33 => :i64_load16_u,
    0x34 => :i64_load32_s,
    0x35 => :i64_load32_u,
    0x36 => :i32_store,
    0x37 => :i64_store,
    0x38 => :f32_store,
    0x39 => :f64_store,
    0x3A => :i32_store8,
    0x3B => :i32_store16,
    0x3C => :i64_store8,
    0x3D => :i64_store16,
    0x3E => :i64_store32
  }

  defp memory_op_name(opcode), do: Map.fetch!(@memory_ops, opcode)

  # ── LEB128 decoders ────────────────────────────────────

  defp decode_u32(data), do: decode_uleb128(data, 0, 0)

  defp decode_uleb128(<<byte, rest::binary>>, result, shift) do
    value = Bitwise.bor(result, Bitwise.bsl(Bitwise.band(byte, 0x7F), shift))

    if Bitwise.band(byte, 0x80) == 0 do
      {value, rest}
    else
      decode_uleb128(rest, value, shift + 7)
    end
  end

  defp decode_i32(data), do: decode_sleb128(data, 0, 0, 32)
  defp decode_i64(data), do: decode_sleb128(data, 0, 0, 64)
  defp decode_s33(data), do: decode_sleb128(data, 0, 0, 33)

  defp decode_sleb128(<<byte, rest::binary>>, result, shift, size) do
    value = Bitwise.bor(result, Bitwise.bsl(Bitwise.band(byte, 0x7F), shift))
    shift = shift + 7

    if Bitwise.band(byte, 0x80) == 0 do
      value =
        if shift < size and Bitwise.band(byte, 0x40) != 0 do
          Bitwise.bor(value, Bitwise.bsl(-1, shift))
        else
          value
        end

      {value, rest}
    else
      decode_sleb128(rest, value, shift, size)
    end
  end

  # ── Vec / Name decoders ────────────────────────────────

  defp decode_vec(data, decoder) do
    {count, data} = decode_u32(data)
    decode_n(data, count, decoder, [])
  end

  defp decode_n(data, 0, _decoder, acc), do: {Enum.reverse(acc), data}

  defp decode_n(data, n, decoder, acc) do
    {item, data} = decoder.(data)
    decode_n(data, n - 1, decoder, [item | acc])
  end

  defp decode_name(data) do
    {len, data} = decode_u32(data)
    <<name::binary-size(len), data::binary>> = data
    {name, data}
  end
end
