defmodule QuickBEAM.WASM.ImportRewriter do
  @moduledoc false

  import Bitwise

  @magic <<0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00>>

  @section_import 2
  @section_memory 5
  @section_global 6

  def rewrite(bytes, [], []), do: {:ok, bytes, []}

  def rewrite(bytes, expected_imports, provided_imports)
      when is_binary(bytes) and is_list(expected_imports) and is_list(provided_imports) do
    with {:ok, sections} <- split_sections(bytes),
         {:ok, validated} <- validate_imports(expected_imports, provided_imports) do
      sections = remove_import_section(sections)
      sections = prepend_memory_imports(sections, validated)
      sections = prepend_global_imports(sections, validated)
      memory_initializers = Enum.map(memory_imports(validated), &Map.fetch!(&1, "bytes"))
      {:ok, rebuild(sections), memory_initializers}
    end
  end

  defp validate_imports(expected_imports, provided_imports) do
    expected_imports
    |> Enum.reduce_while({provided_imports, []}, fn import, {remaining, acc} ->
      case validate_import(import, remaining) do
        {:ok, payload, rest} -> {:cont, {rest, [payload | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:error, _} = error -> error
      {[], validated} -> {:ok, Enum.reverse(validated)}
      {_extra, _validated} -> {:error, "unexpected extra imports"}
    end
  end

  defp validate_import(%{"kind" => "function", "module" => mod, "name" => name}, _remaining) do
    {:error, "function imports are not supported yet (#{mod}.#{name})"}
  end

  defp validate_import(%{"kind" => "table", "module" => mod, "name" => name}, _remaining) do
    {:error, "table imports are not supported yet (#{mod}.#{name})"}
  end

  defp validate_import(expected, [provided | rest]) do
    with :ok <- validate_name_match(expected, provided),
         :ok <- validate_kind_match(expected, provided),
         :ok <- validate_import_value(expected, provided) do
      {:ok, provided, rest}
    end
  end

  defp validate_import(%{"module" => mod, "name" => name}, []) do
    {:error, "missing import #{mod}.#{name}"}
  end

  defp validate_name_match(%{"module" => mod, "name" => name}, %{
         "module" => mod,
         "name" => name
       }),
       do: :ok

  defp validate_name_match(_expected, _provided), do: {:error, "import order mismatch"}

  defp validate_kind_match(%{"kind" => kind}, %{"kind" => kind}), do: :ok
  defp validate_kind_match(_expected, _provided), do: {:error, "import kind mismatch"}

  defp validate_import_value(%{"kind" => "memory", "min" => min, "max" => max}, provided) do
    bytes = Map.get(provided, "bytes", <<>>)

    cond do
      not is_binary(bytes) ->
        {:error, "memory import bytes must be a binary"}

      rem(byte_size(bytes), 65_536) != 0 ->
        {:error, "memory import size must be page-aligned"}

      true ->
        actual_min = div(byte_size(bytes), 65_536)
        actual_max = Map.get(provided, "max")

        cond do
          actual_min < min ->
            {:error, "memory import minimum too small"}

          max != nil and actual_min > max ->
            {:error, "memory import current size exceeds declared maximum"}

          max != nil and (is_nil(actual_max) or actual_max > max) ->
            {:error, "memory import maximum too large"}

          true ->
            :ok
        end
    end
  end

  defp validate_import_value(
         %{"kind" => "global", "type" => type, "mutable" => mutable},
         %{"type" => type, "mutable" => mutable, "value" => value}
       ) do
    validate_global_value(type, value)
  end

  defp validate_import_value(%{"kind" => "global"}, _provided),
    do: {:error, "global import type mismatch"}

  defp validate_global_value("i32", value) when is_integer(value), do: :ok
  defp validate_global_value("i64", value) when is_integer(value) or is_binary(value), do: :ok
  defp validate_global_value("f32", value) when is_number(value), do: :ok
  defp validate_global_value("f64", value) when is_number(value), do: :ok
  defp validate_global_value(_type, _value), do: {:error, "invalid global import value"}

  defp memory_imports(validated), do: Enum.filter(validated, &(&1["kind"] == "memory"))
  defp global_imports(validated), do: Enum.filter(validated, &(&1["kind"] == "global"))

  defp prepend_memory_imports(sections, validated) do
    imports = memory_imports(validated)

    case imports do
      [] ->
        sections

      [_ | _] = entries ->
        prepend_section_entries(
          sections,
          @section_memory,
          entries,
          &encode_memory_import/1,
          &decode_memory_entries/1
        )
    end
  end

  defp prepend_global_imports(sections, validated) do
    imports = global_imports(validated)

    case imports do
      [] ->
        sections

      [_ | _] = entries ->
        prepend_section_entries(
          sections,
          @section_global,
          entries,
          &encode_global_import/1,
          &decode_global_entries/1
        )
    end
  end

  defp prepend_section_entries(sections, section_id, imports, encode_fun, decode_fun) do
    new_entries = Enum.map(imports, encode_fun)

    case List.keytake(sections, section_id, 0) do
      {{^section_id, payload}, rest} ->
        existing_entries = decode_fun.(payload)
        insert_section(rest, {section_id, encode_vec_raw(new_entries ++ existing_entries)})

      nil ->
        insert_section(sections, {section_id, encode_vec_raw(new_entries)})
    end
  end

  defp remove_import_section(sections) do
    Enum.reject(sections, fn {id, _payload} -> id == @section_import end)
  end

  defp split_sections(@magic <> rest), do: parse_sections(rest, [])
  defp split_sections(_bytes), do: {:error, "not a WASM binary"}

  defp parse_sections(<<>>, acc), do: {:ok, Enum.reverse(acc)}

  defp parse_sections(<<id, rest::binary>>, acc) do
    with {size, rest} <- decode_u32(rest),
         true <- byte_size(rest) >= size,
         <<payload::binary-size(size), tail::binary>> <- rest do
      parse_sections(tail, [{id, payload} | acc])
    else
      _ -> {:error, "truncated WASM section"}
    end
  end

  defp rebuild(sections) do
    encoded_sections =
      Enum.map(sections, fn {id, payload} ->
        <<id>> <> encode_u32(byte_size(payload)) <> payload
      end)

    IO.iodata_to_binary([@magic | encoded_sections])
  end

  defp insert_section([], section), do: [section]

  defp insert_section([{id, _payload} = current | rest], {new_id, _} = section)
       when id > new_id and id != 0 do
    [section, current | rest]
  end

  defp insert_section([current | rest], section), do: [current | insert_section(rest, section)]

  defp decode_memory_entries(payload) do
    {entries, <<>>} = decode_vec_raw(payload, &take_limits_raw/1)
    entries
  end

  defp decode_global_entries(payload) do
    {entries, <<>>} = decode_vec_raw(payload, &take_global_raw/1)
    entries
  end

  defp encode_memory_import(import) do
    encode_limits(div(byte_size(Map.fetch!(import, "bytes")), 65_536), Map.get(import, "max"))
  end

  defp encode_global_import(import) do
    type = Map.fetch!(import, "type")
    mutable = Map.get(import, "mutable", false)
    value = Map.fetch!(import, "value")

    encode_valtype(type) <>
      <<if(mutable, do: 1, else: 0)>> <>
      encode_global_init(type, value) <>
      <<0x0B>>
  end

  defp encode_global_init("i32", value), do: <<0x41>> <> encode_sleb128(value)
  defp encode_global_init("i64", value), do: <<0x42>> <> encode_sleb128(parse_i64(value))
  defp encode_global_init("f32", value), do: <<0x43, value::float-little-32>>
  defp encode_global_init("f64", value), do: <<0x44, value::float-little-64>>

  defp encode_valtype("i32"), do: <<0x7F>>
  defp encode_valtype("i64"), do: <<0x7E>>
  defp encode_valtype("f32"), do: <<0x7D>>
  defp encode_valtype("f64"), do: <<0x7C>>

  defp encode_limits(min, nil), do: <<0x00>> <> encode_u32(min)
  defp encode_limits(min, max), do: <<0x01>> <> encode_u32(min) <> encode_u32(max)

  defp take_limits_raw(<<0x00, rest::binary>> = data) do
    {_min, rest} = decode_u32(rest)
    consumed = byte_size(data) - byte_size(rest)
    <<raw::binary-size(consumed), tail::binary>> = data
    {raw, tail}
  end

  defp take_limits_raw(<<0x01, rest::binary>> = data) do
    {_min, rest} = decode_u32(rest)
    {_max, rest} = decode_u32(rest)
    consumed = byte_size(data) - byte_size(rest)
    <<raw::binary-size(consumed), tail::binary>> = data
    {raw, tail}
  end

  defp take_global_raw(<<_type, _mutable, rest::binary>> = data) do
    case :binary.match(rest, <<0x0B>>) do
      {expr_size, 1} ->
        raw_size = 2 + expr_size + 1
        <<raw::binary-size(raw_size), tail::binary>> = data
        {raw, tail}

      :nomatch ->
        raise MatchError
    end
  end

  defp decode_vec_raw(data, decoder) do
    {count, rest} = decode_u32(data)
    decode_vec_raw_items(rest, count, decoder, [])
  end

  defp decode_vec_raw_items(rest, 0, _decoder, acc), do: {Enum.reverse(acc), rest}

  defp decode_vec_raw_items(data, count, decoder, acc) do
    {item, rest} = decoder.(data)
    decode_vec_raw_items(rest, count - 1, decoder, [item | acc])
  end

  defp encode_vec_raw(entries), do: encode_u32(length(entries)) <> IO.iodata_to_binary(entries)

  defp decode_u32(data), do: decode_u32(data, 0, 0)

  defp decode_u32(<<byte, rest::binary>>, acc, shift) do
    value = acc ||| (byte &&& 0x7F) <<< shift

    if (byte &&& 0x80) == 0 do
      {value, rest}
    else
      decode_u32(rest, value, shift + 7)
    end
  end

  defp encode_u32(value), do: encode_uleb128(value)

  defp encode_uleb128(value) when value >= 0 do
    encode_uleb128(value, [])
  end

  defp encode_uleb128(value, acc) when value < 0x80 do
    IO.iodata_to_binary(Enum.reverse([value | acc]))
  end

  defp encode_uleb128(value, acc) do
    encode_uleb128(value >>> 7, [0x80 ||| (value &&& 0x7F) | acc])
  end

  defp encode_sleb128(value), do: encode_sleb128(value, [])

  defp encode_sleb128(value, acc) do
    byte = value &&& 0x7F
    next = value >>> 7
    sign_bit = byte &&& 0x40

    done =
      (next == 0 and sign_bit == 0) or
        (next == -1 and sign_bit != 0)

    byte = if done, do: byte, else: byte ||| 0x80

    if done do
      IO.iodata_to_binary(Enum.reverse([byte | acc]))
    else
      encode_sleb128(next, [byte | acc])
    end
  end

  defp parse_i64(value) when is_integer(value), do: value
  defp parse_i64(value) when is_binary(value), do: String.to_integer(value)
end
