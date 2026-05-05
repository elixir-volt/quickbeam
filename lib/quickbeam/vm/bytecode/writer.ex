defmodule QuickBEAM.VM.Bytecode.Writer do
  @moduledoc """
  Serializes decoded QuickJS bytecode structs back to QuickJS bytecode binaries.

  The writer intentionally mirrors `QuickBEAM.VM.Bytecode.decode/1` and the
  vendored QuickJS `JS_WriteObject*` format. It currently covers simple decoded
  functions.
  """

  import Bitwise

  alias QuickBEAM.VM.Opcodes

  @js_atom_end Opcodes.js_atom_end()

  @spec encode(QuickBEAM.VM.Program.t()) :: {:ok, binary()} | {:error, term()}
  def encode(%QuickBEAM.VM.Program{value: value}) do
    with {:ok, atoms} <- collect_atoms(value),
         {:ok, payload} <- write_object(value, atoms) do
      body =
        [write_unsigned(tuple_size(atoms)), write_atoms(atoms), payload] |> IO.iodata_to_binary()

      without_checksum = <<Opcodes.bc_version(), 0::little-32, body::binary>>
      checksum = checksum(binary_part(without_checksum, 5, byte_size(without_checksum) - 5))
      {:ok, <<Opcodes.bc_version(), checksum::little-32, body::binary>>}
    end
  end

  defp collect_atoms(value) do
    atoms = value |> do_collect_atoms([]) |> Enum.uniq() |> List.to_tuple()
    {:ok, atoms}
  end

  defp do_collect_atoms(%QuickBEAM.VM.Function{} = function, acc) do
    acc = collect_atom(function.name, acc)
    acc = collect_atom(function.filename, acc)
    acc = Enum.reduce(function.extra_atoms || [], acc, &collect_atom/2)

    acc =
      Enum.reduce(function.locals, acc, fn %QuickBEAM.VM.VarDef{name: name}, acc -> collect_atom(name, acc) end)

    acc =
      Enum.reduce(function.closure_vars, acc, fn %QuickBEAM.VM.ClosureVar{name: name}, acc ->
        collect_atom(name, acc)
      end)

    Enum.reduce(function.constants, acc, &do_collect_atoms/2)
  end

  defp do_collect_atoms(value, acc) when is_binary(value), do: collect_atom(value, acc)
  defp do_collect_atoms({:array, values}, acc), do: Enum.reduce(values, acc, &do_collect_atoms/2)

  defp do_collect_atoms({:object, properties}, acc) do
    Enum.reduce(properties, acc, fn {key, value}, acc ->
      value |> do_collect_atoms(collect_atom(key, acc))
    end)
  end

  defp do_collect_atoms(_value, acc), do: acc

  defp collect_atom(nil, acc), do: acc
  defp collect_atom({:predefined, _idx}, acc), do: acc
  defp collect_atom(value, acc) when is_binary(value), do: [value | acc]
  defp collect_atom(_value, acc), do: acc

  defp write_atoms(atoms) do
    atoms
    |> Tuple.to_list()
    |> Enum.map(fn atom -> [1, write_string_payload(atom)] end)
  end

  defp write_object(nil, _atoms), do: {:ok, <<Opcodes.bc_tag_null()>>}
  defp write_object(:undefined, _atoms), do: {:ok, <<Opcodes.bc_tag_undefined()>>}
  defp write_object(false, _atoms), do: {:ok, <<Opcodes.bc_tag_bool_false()>>}
  defp write_object(true, _atoms), do: {:ok, <<Opcodes.bc_tag_bool_true()>>}

  defp write_object(value, _atoms) when is_integer(value),
    do: {:ok, [Opcodes.bc_tag_int32(), write_signed(value)] |> IO.iodata_to_binary()}

  defp write_object(value, _atoms) when is_float(value),
    do: {:ok, <<Opcodes.bc_tag_float64(), value::little-float-64>>}

  defp write_object(value, _atoms) when is_binary(value),
    do: {:ok, [Opcodes.bc_tag_string(), write_string_payload(value)] |> IO.iodata_to_binary()}

  defp write_object({:array, values}, atoms) do
    with {:ok, encoded} <- map_values(values, &write_object(&1, atoms)) do
      {:ok,
       [Opcodes.bc_tag_array(), write_unsigned(length(values)), encoded] |> IO.iodata_to_binary()}
    end
  end

  defp write_object({:template_object, cooked, raw}, atoms) do
    {:array, cooked_values} = cooked

    with {:ok, cooked_encoded} <- map_values(cooked_values, &write_object(&1, atoms)),
         {:ok, raw_encoded} <- write_object(raw, atoms) do
      {:ok,
       [
         Opcodes.bc_tag_template_object(),
         write_unsigned(length(cooked_values)),
         cooked_encoded,
         raw_encoded
       ]
       |> IO.iodata_to_binary()}
    end
  end

  defp write_object({:object, properties}, atoms) when is_map(properties) do
    pairs = Map.to_list(properties)

    with {:ok, encoded} <-
           map_values(pairs, fn {key, value} ->
             with {:ok, key} <- write_object(key, atoms),
                  {:ok, value} <- write_object(value, atoms) do
               {:ok, [key, value]}
             end
           end) do
      {:ok,
       [Opcodes.bc_tag_object(), write_unsigned(length(pairs)), encoded] |> IO.iodata_to_binary()}
    end
  end

  defp write_object(%QuickBEAM.VM.Function{} = function, atoms), do: write_function(function, atoms)
  defp write_object(value, _atoms), do: {:error, {:unsupported_value, value}}

  defp write_function(%QuickBEAM.VM.Function{} = function, atoms) do
    with {:ok, constants} <- map_values(function.constants, &write_object(&1, atoms)) do
      flags = function_flags(function)

      encoded = [
        Opcodes.bc_tag_function_bytecode(),
        <<flags::little-16>>,
        if(function.is_strict_mode, do: 1, else: 0),
        write_atom(function.name, atoms),
        write_unsigned(function.arg_count),
        write_unsigned(function.var_count),
        write_unsigned(function.defined_arg_count),
        write_unsigned(function.stack_size),
        write_unsigned(function.var_ref_count),
        write_unsigned(length(function.closure_vars)),
        write_signed(length(function.constants)),
        write_signed(byte_size(function.byte_code)),
        write_signed(length(function.locals)),
        Enum.map(function.locals, &write_vardef(&1, atoms)),
        Enum.map(function.closure_vars, &write_closure_var(&1, atoms)),
        constants,
        function.byte_code,
        write_debug_info(function, atoms)
      ]

      {:ok, IO.iodata_to_binary(encoded)}
    end
  end

  defp function_flags(function) do
    0
    |> set_flag(0, function.has_prototype)
    |> set_flag(1, function.has_simple_parameter_list)
    |> set_flag(2, function.is_derived_class_constructor)
    |> set_flag(3, function.need_home_object)
    |> bor((function.func_kind || 0) <<< 4)
    |> set_flag(6, function.new_target_allowed)
    |> set_flag(7, function.super_call_allowed)
    |> set_flag(8, function.super_allowed)
    |> set_flag(9, function.arguments_allowed)
    |> set_flag(10, false)
    |> set_flag(11, function.has_debug_info)
  end

  defp set_flag(flags, bit, true), do: flags ||| 1 <<< bit
  defp set_flag(flags, _bit, _), do: flags

  defp write_vardef(%QuickBEAM.VM.VarDef{} = vardef, atoms) do
    flags =
      (vardef.var_kind || 0)
      |> set_flag(4, vardef.is_const)
      |> set_flag(5, vardef.is_lexical)
      |> set_flag(6, vardef.is_captured)

    [
      write_atom(vardef.name, atoms),
      write_signed(vardef.scope_level || 0),
      write_signed((vardef.scope_next || -1) + 1),
      flags,
      if(vardef.is_captured, do: write_unsigned(vardef.var_ref_idx || 0), else: [])
    ]
  end

  defp write_closure_var(%QuickBEAM.VM.ClosureVar{} = var, atoms) do
    flags =
      (var.closure_type || 0)
      |> set_flag(3, var.is_const)
      |> set_flag(4, var.is_lexical)
      |> bor((var.var_kind || 0) <<< 5)

    [write_atom(var.name, atoms), write_signed(var.var_idx || 0), write_signed(flags)]
  end

  defp write_debug_info(%QuickBEAM.VM.Function{has_debug_info: false}, _atoms), do: []

  defp write_debug_info(%QuickBEAM.VM.Function{} = function, atoms) do
    [
      write_atom(function.filename, atoms),
      write_signed(function.line_num || 1),
      write_signed(function.col_num || 1),
      write_signed(byte_size(function.pc2line || <<>>)),
      function.pc2line || <<>>,
      write_signed(byte_size(function.source || <<>>)),
      function.source || <<>>
    ]
  end

  defp write_atom(nil, _atoms), do: write_unsigned(0)
  defp write_atom({:predefined, idx}, _atoms), do: write_unsigned(idx <<< 1)

  defp write_atom(name, atoms) when is_binary(name) do
    index = find_atom!(atoms, name) + @js_atom_end
    write_unsigned(index <<< 1)
  end

  defp find_atom!(atoms, name) do
    atoms
    |> Tuple.to_list()
    |> Enum.find_index(&(&1 == name))
    |> case do
      nil -> raise ArgumentError, "atom not collected: #{inspect(name)}"
      index -> index
    end
  end

  defp write_string_payload(value) when is_binary(value) do
    codepoints = String.to_charlist(value)

    if Enum.all?(codepoints, &(&1 <= 0xFF)) do
      [
        write_unsigned(length(codepoints) <<< 1),
        :unicode.characters_to_binary(codepoints, :latin1, :latin1)
      ]
    else
      [write_unsigned(length(codepoints) <<< 1 ||| 1), Enum.map(codepoints, &<<&1::little-16>>)]
    end
  end

  defp map_values(values, fun) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case fun.(value) do
        {:ok, encoded} -> {:cont, {:ok, [encoded | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, _} = error -> error
    end
  end

  defp write_unsigned(value) when value >= 0 do
    value
    |> unsigned_bytes([])
    |> IO.iodata_to_binary()
  end

  defp unsigned_bytes(value, acc) when value < 0x80, do: Enum.reverse([value | acc])

  defp unsigned_bytes(value, acc) do
    unsigned_bytes(value >>> 7, [0x80 ||| (value &&& 0x7F) | acc])
  end

  defp write_signed(value) do
    value
    |> signed_bytes([])
    |> IO.iodata_to_binary()
  end

  defp signed_bytes(value, acc) do
    byte = value &&& 0x7F
    next = value >>> 7
    sign_set? = (byte &&& 0x40) != 0
    done? = (next == 0 and not sign_set?) or (next == -1 and sign_set?)

    if done? do
      Enum.reverse([byte | acc])
    else
      signed_bytes(next, [byte ||| 0x80 | acc])
    end
  end

  defp checksum(data) do
    {h, rest} = checksum_words(data, 0)

    value =
      case rest do
        <<a, b, c>> -> a ||| b <<< 8 ||| c <<< 16
        <<a, b>> -> a ||| b <<< 8
        <<a>> -> a
        <<>> -> 0
      end

    rem32((h + value) * 0x9E37_0001)
  end

  defp checksum_words(<<word::little-32, rest::binary>>, h) when byte_size(rest) > 0,
    do: checksum_words(rest, rem32((h + word) * 0x9E37_0001))

  defp checksum_words(rest, h), do: {h, rest}

  defp rem32(value), do: value &&& 0xFFFF_FFFF
end
