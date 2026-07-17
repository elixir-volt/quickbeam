defmodule QuickBEAM.VM.Bytecode.Verifier do
  @moduledoc """
  Structurally verifies decoded programs before interpreter execution.

  Verification rejects malformed control flow, operands, references, and stack
  behavior before untrusted bytecode reaches mutable evaluation state.
  """

  alias QuickBEAM.VM.ABI
  alias QuickBEAM.VM.Bytecode.Opcode
  alias QuickBEAM.VM.Bytecode.Verifier.Stack
  alias QuickBEAM.VM.Program
  alias QuickBEAM.VM.Program.Function
  alias QuickBEAM.VM.Program.Variable
  alias QuickBEAM.VM.Program.Variable.Closure

  @js_atom_end Opcode.js_atom_end()

  @default_limits %{
    max_atoms: 100_000,
    max_constants_per_function: 100_000,
    max_function_depth: 128,
    max_functions: 10_000,
    max_instructions: 1_000_000,
    max_stack_size: 100_000
  }

  @doc "Verifies a decoded program under bounded structural limits."
  @spec verify(Program.t(), keyword()) :: :ok | {:error, term()}
  def verify(program, opts \\ [])

  def verify(%Program{} = program, opts) do
    with {:ok, limits} <- limits(opts),
         :ok <- verify_header(program),
         :ok <- verify_root(program.root),
         :ok <- within(tuple_size(program.atoms), limits.max_atoms, :atoms),
         :ok <- verify_atoms(program.atoms),
         {:ok, _counts} <-
           verify_value(program.root, program.atoms, limits, 0, %{functions: 0, instructions: 0}) do
      :ok
    end
  end

  def verify(_program, _opts), do: {:error, :invalid_program}

  @doc "Checks the constant-time ABI identity of an already verified pinned program."
  @spec verify_identity(Program.t()) :: :ok | {:error, term()}
  def verify_identity(%Program{} = program), do: verify_header(program)
  def verify_identity(_program), do: {:error, :invalid_program}

  defp limits(opts) when is_list(opts) do
    Enum.reduce_while(opts, {:ok, @default_limits}, fn
      {key, value}, {:ok, limits} when is_map_key(@default_limits, key) ->
        maximum = Map.fetch!(@default_limits, key)

        if is_integer(value) and value > 0 and value <= maximum,
          do: {:cont, {:ok, Map.put(limits, key, value)}},
          else: {:halt, {:error, {:invalid_limit, key}}}

      {key, _value}, _acc ->
        {:halt, {:error, {:unknown_option, key}}}

      option, _acc ->
        {:halt, {:error, {:invalid_option, option}}}
    end)
  end

  defp limits(opts), do: {:error, {:invalid_options, opts}}

  defp verify_header(%Program{version: version, fingerprint: fingerprint, atoms: atoms}) do
    cond do
      version != ABI.bytecode_version() -> {:error, {:bad_version, version}}
      fingerprint != ABI.fingerprint() -> {:error, {:bad_fingerprint, fingerprint}}
      not is_tuple(atoms) -> {:error, :invalid_atom_table}
      true -> :ok
    end
  end

  defp verify_value(%Function{} = function, atoms, limits, depth, counts) do
    with :ok <- verify_function_container_shape(function),
         :ok <- within(depth, limits.max_function_depth, :function_depth),
         :ok <- within(length(function.constants), limits.max_constants_per_function, :constants),
         :ok <- within(function.stack_size, limits.max_stack_size, :stack_size),
         :ok <- verify_function_shape(function),
         :ok <- verify_instructions(function, atoms),
         :ok <- verify_stack(function),
         {:ok, counts} <- add_counts(function, limits, counts) do
      verify_values(function.constants, atoms, limits, depth + 1, counts)
    end
  end

  defp verify_value({:array, values}, atoms, limits, depth, counts) when is_list(values) do
    with :ok <- within(depth, limits.max_function_depth, :constant_depth),
         :ok <- within(length(values), limits.max_constants_per_function, :constants) do
      verify_values(values, atoms, limits, depth + 1, counts)
    end
  end

  defp verify_value({:array, _values}, _atoms, _limits, _depth, _counts),
    do: {:error, :invalid_array_constant}

  defp verify_value({:object, values}, atoms, limits, depth, counts) when is_map(values) do
    with :ok <- within(depth, limits.max_function_depth, :constant_depth),
         :ok <- within(map_size(values), limits.max_constants_per_function, :constants) do
      verify_values(Map.values(values), atoms, limits, depth + 1, counts)
    end
  end

  defp verify_value({:object, _values}, _atoms, _limits, _depth, _counts),
    do: {:error, :invalid_object_constant}

  defp verify_value({:template_object, {:array, values}, raw}, atoms, limits, depth, counts)
       when is_list(values) do
    with :ok <- within(depth, limits.max_function_depth, :constant_depth),
         :ok <- within(length(values), limits.max_constants_per_function, :constants),
         {:ok, counts} <- verify_values(values, atoms, limits, depth + 1, counts) do
      verify_value(raw, atoms, limits, depth + 1, counts)
    end
  end

  defp verify_value({:template_object, _cooked, _raw}, _atoms, _limits, _depth, _counts),
    do: {:error, :invalid_template_constant}

  defp verify_value(_value, _atoms, _limits, _depth, counts), do: {:ok, counts}

  defp verify_values(values, atoms, limits, depth, counts) do
    Enum.reduce_while(values, {:ok, counts}, fn value, {:ok, counts} ->
      case verify_value(value, atoms, limits, depth, counts) do
        {:ok, counts} -> {:cont, {:ok, counts}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp verify_atoms(atoms) do
    if atoms |> Tuple.to_list() |> Enum.all?(&is_binary/1),
      do: :ok,
      else: {:error, :invalid_atom_table}
  end

  defp verify_root(%Function{}), do: :ok
  defp verify_root(_root), do: {:error, :invalid_root_function}

  defp verify_function_container_shape(%Function{} = function) do
    with :ok <- require_type(function.constants, :list, function.id, :constants),
         :ok <- require_type(function.locals, :list, function.id, :locals),
         :ok <- require_type(function.closure_vars, :list, function.id, :closure_variables),
         :ok <- require_type(function.instructions, :tuple, function.id, :instructions),
         :ok <- require_type(function.source_positions, :tuple, function.id, :source_positions),
         :ok <- require_type(function.pc2line, :binary, function.id, :pc2line),
         :ok <- require_type(function.source, :binary, function.id, :source),
         :ok <- require_filename(function.filename, function.id),
         true <- valid_function_flags?(function) do
      :ok
    else
      false -> {:error, {:invalid_function, function.id, :flags}}
      {:error, _reason} = error -> error
    end
  end

  defp require_type(value, :list, _id, _field) when is_list(value), do: :ok
  defp require_type(value, :tuple, _id, _field) when is_tuple(value), do: :ok
  defp require_type(value, :binary, _id, _field) when is_binary(value), do: :ok
  defp require_type(_value, _type, id, field), do: {:error, {:invalid_function, id, field}}

  defp require_filename(nil, _id), do: :ok
  defp require_filename(filename, _id) when is_binary(filename), do: :ok
  defp require_filename(_filename, id), do: {:error, {:invalid_function, id, :filename}}

  defp valid_function_flags?(function) do
    Enum.all?(
      [
        function.has_prototype,
        function.has_simple_parameter_list,
        function.is_derived_class_constructor,
        function.need_home_object,
        function.new_target_allowed,
        function.super_call_allowed,
        function.super_allowed,
        function.arguments_allowed,
        function.is_strict_mode,
        function.has_debug_info
      ],
      &is_boolean/1
    ) and is_integer(function.func_kind) and function.func_kind >= 0
  end

  defp verify_function_shape(%Function{} = function) do
    instruction_count =
      if is_tuple(function.instructions), do: tuple_size(function.instructions), else: -1

    cond do
      instruction_count < 0 ->
        {:error, {:invalid_function, function.id, :instructions}}

      invalid_non_negative_fields?(function) ->
        {:error, {:invalid_function, function.id, :negative_count}}

      length(function.locals) != function.arg_count + function.var_count ->
        {:error, {:invalid_function, function.id, :locals}}

      function.defined_arg_count > function.arg_count ->
        {:error, {:invalid_function, function.id, :defined_arguments}}

      not is_tuple(function.source_positions) ->
        {:error, {:invalid_function, function.id, :source_positions}}

      tuple_size(function.source_positions) != instruction_count ->
        {:error, {:invalid_function, function.id, :source_positions}}

      true ->
        with :ok <- verify_source_metadata(function),
             :ok <- verify_variables(function.locals),
             :ok <- verify_closure_variables(function.closure_vars) do
          verify_capture_indexes(function)
        end
    end
  end

  defp invalid_non_negative_fields?(function) do
    Enum.any?(
      [
        function.id,
        function.arg_count,
        function.var_count,
        function.defined_arg_count,
        function.stack_size,
        function.var_ref_count
      ],
      &(not is_integer(&1) or &1 < 0)
    )
  end

  defp verify_source_metadata(function) do
    valid_positions? =
      function.source_positions
      |> Tuple.to_list()
      |> Enum.all?(fn
        {line, column}
        when is_integer(line) and line >= 0 and is_integer(column) and column >= 0 ->
          true

        _position ->
          false
      end)

    if is_integer(function.line_num) and function.line_num >= 0 and
         is_integer(function.col_num) and function.col_num >= 0 and valid_positions?,
       do: :ok,
       else: {:error, {:invalid_function, function.id, :source_positions}}
  end

  defp verify_variables(variables) do
    if Enum.all?(variables, &valid_variable?/1),
      do: :ok,
      else: {:error, :invalid_variable_metadata}
  end

  defp valid_variable?(%Variable{} = variable) do
    valid_variable_indexes?(variable) and valid_variable_flags?(variable)
  end

  defp valid_variable?(_variable), do: false

  defp valid_variable_indexes?(variable) do
    is_integer(variable.scope_level) and variable.scope_level >= 0 and
      is_integer(variable.scope_next) and is_integer(variable.var_kind) and variable.var_kind >= 0 and
      valid_optional_index?(variable.var_ref_idx)
  end

  defp valid_variable_flags?(variable) do
    is_boolean(variable.is_const) and is_boolean(variable.is_lexical) and
      is_boolean(variable.is_captured)
  end

  defp valid_optional_index?(nil), do: true
  defp valid_optional_index?(index), do: is_integer(index) and index >= 0

  defp verify_closure_variables(variables) do
    if Enum.all?(variables, &valid_closure_variable?/1),
      do: :ok,
      else: {:error, :invalid_closure_variable_metadata}
  end

  defp valid_closure_variable?(%Closure{} = variable) do
    is_integer(variable.var_idx) and variable.var_idx >= 0 and
      is_integer(variable.closure_type) and variable.closure_type >= 0 and
      is_integer(variable.var_kind) and variable.var_kind >= 0 and
      is_boolean(variable.is_const) and is_boolean(variable.is_lexical)
  end

  defp valid_closure_variable?(_variable), do: false

  defp verify_capture_indexes(function) do
    Enum.reduce_while(function.locals, :ok, fn variable, :ok ->
      if variable.is_captured and
           (not is_integer(variable.var_ref_idx) or variable.var_ref_idx < 0 or
              variable.var_ref_idx >= function.var_ref_count) do
        {:halt, {:error, {:invalid_var_ref, function.id, variable.var_ref_idx}}}
      else
        {:cont, :ok}
      end
    end)
  end

  defp verify_instructions(function, atoms) do
    function.instructions
    |> Tuple.to_list()
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {instruction, index}, :ok ->
      case verify_instruction(instruction, function, atoms) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:invalid_instruction, function.id, index, reason}}}
      end
    end)
  end

  defp verify_instruction({opcode, operands}, function, atoms)
       when is_integer(opcode) and is_list(operands) do
    case Opcode.info(opcode) do
      nil ->
        {:error, {:unknown_opcode, opcode}}

      {name, _size, _pops, _pushes, format} ->
        with :ok <- verify_operand_count(format, operands),
             :ok <- verify_operand_types(format, operands) do
          verify_operands(name, format, operands, function, atoms)
        end
    end
  end

  defp verify_instruction(instruction, _function, _atoms),
    do: {:error, {:invalid_shape, instruction}}

  defp verify_stack(function) do
    case Stack.verify(function) do
      :ok -> :ok
      {:error, reason} -> {:error, {:invalid_stack, function.id, reason}}
    end
  end

  defp verify_operand_count(format, operands) do
    expected =
      case format do
        :none -> 0
        format when format in [:u32x2, :npop_u16, :atom_u8, :atom_u16, :label_u16] -> 2
        format when format in [:atom_label_u8, :atom_label_u16] -> 3
        :none_loc -> if(length(operands) == 2, do: 2, else: 1)
        format when format in [:none_int, :none_arg, :none_var_ref, :npopx] -> 1
        _ -> 1
      end

    if length(operands) == expected,
      do: :ok,
      else: {:error, {:operand_count, expected, length(operands)}}
  end

  defp verify_operand_types(format, [_atom | operands])
       when format in [:atom, :atom_u8, :atom_u16, :atom_label_u8, :atom_label_u16],
       do: verify_integer_operands(operands)

  defp verify_operand_types(_format, operands), do: verify_integer_operands(operands)

  defp verify_integer_operands(operands) do
    if Enum.all?(operands, &is_integer/1), do: :ok, else: {:error, :invalid_operand_type}
  end

  defp verify_operands(_name, format, [index], function, _atoms)
       when format in [:loc, :loc8],
       do: index_within(index, function.arg_count + function.var_count, :local)

  defp verify_operands(_name, :arg, [index], function, _atoms),
    do: index_within(index, function.arg_count, :argument)

  defp verify_operands(_name, :var_ref, [index], function, _atoms),
    do: index_within(index, length(function.closure_vars), :closure_variable)

  defp verify_operands(_name, format, [index], function, _atoms)
       when format in [:const, :const8],
       do: index_within(index, length(function.constants), :constant)

  defp verify_operands(name, format, operands, function, atoms)
       when format in [:atom, :atom_u8, :atom_u16, :atom_label_u8, :atom_label_u16] do
    with :ok <- verify_atom_operand(List.first(operands), atoms),
         :ok <- verify_secondary_operand(name, operands, function) do
      verify_embedded_label(format, operands, function)
    end
  end

  defp verify_operands(_name, format, operands, function, _atoms)
       when format in [:label8, :label16, :label, :label_u16],
       do: verify_label(List.first(operands), function)

  defp verify_operands(_name, _format, _operands, _function, _atoms), do: :ok

  defp verify_atom_operand(index, atoms) when is_integer(index),
    do: index_within(index, tuple_size(atoms), :atom)

  defp verify_atom_operand({:predefined, index}, _atoms)
       when is_integer(index) and index >= 0 and index < @js_atom_end,
       do: :ok

  defp verify_atom_operand({:tagged_int, value}, _atoms)
       when is_integer(value) and value >= 0,
       do: :ok

  defp verify_atom_operand(_operand, _atoms), do: {:error, :invalid_atom}

  defp verify_secondary_operand(:make_loc_ref, [_atom, index], function),
    do: index_within(index, function.arg_count + function.var_count, :local)

  defp verify_secondary_operand(:make_arg_ref, [_atom, index], function),
    do: index_within(index, function.arg_count, :argument)

  defp verify_secondary_operand(:make_var_ref_ref, [_atom, index], function),
    do: index_within(index, length(function.closure_vars), :closure_variable)

  defp verify_secondary_operand(_name, _operands, _function), do: :ok

  defp verify_embedded_label(format, [_atom, label | _rest], function)
       when format in [:atom_label_u8, :atom_label_u16],
       do: verify_label(label, function)

  defp verify_embedded_label(_format, _operands, _function), do: :ok

  defp verify_label(label, function),
    do: index_within(label, tuple_size(function.instructions), :label)

  defp index_within(index, count, _kind)
       when is_integer(index) and index >= 0 and index < count,
       do: :ok

  defp index_within(index, _count, kind), do: {:error, {:invalid_index, kind, index}}

  defp add_counts(function, limits, counts) do
    counts = %{
      functions: counts.functions + 1,
      instructions: counts.instructions + tuple_size(function.instructions)
    }

    with :ok <- within(counts.functions, limits.max_functions, :functions),
         :ok <- within(counts.instructions, limits.max_instructions, :instructions) do
      {:ok, counts}
    end
  end

  defp within(value, maximum, _kind) when value <= maximum, do: :ok
  defp within(value, _maximum, kind), do: {:error, {:limit_exceeded, kind, value}}
end
