defmodule QuickBEAM.JS.BytecodeCompiler.FunctionBuilder do
  @moduledoc false

  alias QuickBEAM.JS.BytecodeCompiler.Assembler
  alias QuickBEAM.VM.Bytecode.Function
  alias QuickBEAM.VM.Bytecode.VarDef

  def build(opts) do
    instructions = Keyword.fetch!(opts, :instructions)
    args = Keyword.fetch!(opts, :args)
    locals = Keyword.fetch!(opts, :locals)
    extra_atoms = Assembler.atoms(instructions)

    function = %Function{
      name: Keyword.fetch!(opts, :name),
      filename: "<elixir-bytecode-compiler>",
      line_num: 1,
      col_num: 1,
      arg_count: length(args),
      var_count: length(locals),
      defined_arg_count: Keyword.get(opts, :defined_arg_count, length(args)),
      stack_size: Assembler.stack_size(instructions),
      locals: Keyword.get(opts, :local_defs, Enum.map(args ++ locals, &var_def/1)),
      var_ref_count: Keyword.get(opts, :var_ref_count, 0),
      closure_vars: Keyword.get(opts, :closure_vars, []),
      constants: Keyword.fetch!(opts, :constants),
      extra_atoms: extra_atoms,
      byte_code: <<>>,
      has_prototype: Keyword.fetch!(opts, :has_prototype),
      has_simple_parameter_list: Keyword.fetch!(opts, :has_simple_parameter_list),
      new_target_allowed: Keyword.fetch!(opts, :new_target_allowed),
      arguments_allowed: true,
      is_strict_mode: false,
      has_debug_info: false,
      source: Keyword.fetch!(opts, :source)
    }

    atoms = collect_atoms(function)
    resolved = to_vm_instructions(instructions, atoms, function.arg_count)

    %{function | atoms: atoms, instructions: resolved}
    |> attach_own_constant_atoms()
  end

  defp to_vm_instructions(instructions, atoms, arg_count) do
    atom_map =
      atoms
      |> Tuple.to_list()
      |> Enum.with_index()
      |> Map.new()

    {labels, _} =
      Enum.reduce(instructions, {%{}, 0}, fn
        {:label, name}, {map, pc} -> {Map.put(map, name, pc), pc}
        _, {map, pc} -> {map, pc + 1}
      end)

    instructions
    |> Enum.reject(&match?({:label, _}, &1))
    |> Enum.map(&to_op(&1, labels, atom_map, arg_count))
    |> List.to_tuple()
  end

  @op QuickBEAM.VM.Opcodes.all_opcodes()

  defp to_op(true, _labels, _atoms, _arg_count), do: op(:push_true)
  defp to_op(false, _labels, _atoms, _arg_count), do: op(:push_false)
  defp to_op(:undefined, _labels, _atoms, _arg_count), do: op(:undefined)
  defp to_op(:null, _labels, _atoms, _arg_count), do: op(:null)
  defp to_op(:push_this, _labels, _atoms, _arg_count), do: op(:push_this)

  defp to_op({:push_int, value}, _labels, _atoms, _arg_count), do: op(:push_i32, [value])
  defp to_op({:constant, index}, _labels, _atoms, _arg_count), do: op(:push_const, [index])
  defp to_op({:closure, index}, _labels, _atoms, _arg_count), do: op(:fclosure, [index])
  defp to_op({:rest, start}, _labels, _atoms, _arg_count), do: op(:rest, [start])

  defp to_op({:get_arg, index}, _labels, _atoms, _arg_count), do: op(:get_arg, [index])
  defp to_op({:put_arg, index}, _labels, _atoms, _arg_count), do: op(:put_arg, [index])
  defp to_op({:set_arg, index}, _labels, _atoms, _arg_count), do: op(:set_arg, [index])

  defp to_op({:get_loc, index}, _labels, _atoms, arg_count), do: op(:get_loc, [index + arg_count])
  defp to_op({:put_loc, index}, _labels, _atoms, arg_count), do: op(:put_loc, [index + arg_count])
  defp to_op({:set_loc, index}, _labels, _atoms, arg_count), do: op(:set_loc, [index + arg_count])

  defp to_op({:close_loc, index}, _labels, _atoms, arg_count),
    do: op(:close_loc, [index + arg_count])

  defp to_op({:set_loc_uninitialized, index}, _labels, _atoms, arg_count),
    do: op(:set_loc_uninitialized, [index + arg_count])

  defp to_op({:get_var_ref, index}, _labels, _atoms, _arg_count), do: op(:get_var_ref, [index])
  defp to_op({:put_var_ref, index}, _labels, _atoms, _arg_count), do: op(:put_var_ref, [index])

  defp to_op({:get_var_ref_check, index}, _labels, _atoms, _arg_count),
    do: op(:get_var_ref_check, [index])

  defp to_op({:put_var_ref_check, index}, _labels, _atoms, _arg_count),
    do: op(:put_var_ref_check, [index])

  defp to_op({:jump, target}, labels, _atoms, _arg_count),
    do: op(:goto, [Map.fetch!(labels, target)])

  defp to_op({:jump_if_false, target}, labels, _atoms, _arg_count),
    do: op(:if_false, [Map.fetch!(labels, target)])

  defp to_op({:jump_if_true, target}, labels, _atoms, _arg_count),
    do: op(:if_true, [Map.fetch!(labels, target)])

  defp to_op({:catch, target}, labels, _atoms, _arg_count),
    do: op(:catch, [Map.fetch!(labels, target)])

  defp to_op({:gosub, target}, labels, _atoms, _arg_count),
    do: op(:gosub, [Map.fetch!(labels, target)])

  defp to_op({name, atom}, _labels, atoms, _arg_count)
       when name in [
              :get_var,
              :put_var,
              :get_field,
              :get_field2,
              :put_field,
              :define_field,
              :set_name,
              :private_symbol
            ] do
    op(name, [atom_operand(atom, atoms)])
  end

  defp to_op({:define_method, atom, flags}, _labels, atoms, _arg_count),
    do: op(:define_method, [atom_operand(atom, atoms), flags])

  defp to_op({:define_method_computed, flags}, _labels, _atoms, _arg_count),
    do: op(:define_method_computed, [flags])

  defp to_op({:define_class, atom, flags}, _labels, atoms, _arg_count),
    do: op(:define_class, [atom_operand(atom, atoms), flags])

  defp to_op({:throw_error, type, atom}, _labels, atoms, _arg_count),
    do: op(:throw_error, [atom_operand(atom, atoms), type])

  defp to_op({name, atom, target}, labels, atoms, _arg_count)
       when name in [:with_get_var, :with_put_var, :with_delete_var] do
    op(name, [atom_operand(atom, atoms), Map.fetch!(labels, target), 1])
  end

  defp to_op({:eval, argc, scope}, _labels, _atoms, _arg_count), do: op(:eval, [argc, scope])
  defp to_op({:call, argc}, _labels, _atoms, _arg_count), do: op(:call, [argc])
  defp to_op({:call_method, argc}, _labels, _atoms, _arg_count), do: op(:call_method, [argc])

  defp to_op({:call_constructor, argc}, _labels, _atoms, _arg_count),
    do: op(:call_constructor, [argc])

  defp to_op({:array_from, count}, _labels, _atoms, _arg_count), do: op(:array_from, [count])

  defp to_op({:special_object, type}, _labels, _atoms, _arg_count),
    do: op(:special_object, [type])

  defp to_op({:for_of_next, index}, _labels, _atoms, _arg_count), do: op(:for_of_next, [index])

  defp to_op({:copy_data_properties, mask}, _labels, _atoms, _arg_count),
    do: op(:copy_data_properties, [mask])

  defp to_op(name, _labels, _atoms, _arg_count) when is_atom(name), do: op(name)

  defp op(name, args \\ []), do: {Map.fetch!(@op, name), args}

  defp atom_operand(index, _atoms) when is_integer(index) and index >= 0,
    do: {:tagged_int, index}

  defp atom_operand({:predefined, _} = predefined, _atoms), do: predefined

  defp atom_operand(name, atoms) do
    Map.fetch!(atoms, name)
  end

  defp attach_own_constant_atoms(%Function{atoms: atoms, constants: constants} = function) do
    constants =
      for c <- constants do
        case c do
          %Function{atoms: nil} -> attach_atoms(c, atoms)
          %Function{} -> c
          _ -> c
        end
      end

    %{function | constants: constants}
  end

  def collect_atoms(%Function{} = function) do
    function
    |> do_collect_atoms([])
    |> Enum.reject(&(match?({:predefined, _}, &1) or is_nil(&1)))
    |> Enum.uniq()
    |> List.to_tuple()
  end

  def attach_atoms(%Function{} = function, atoms) do
    function
    |> Map.put(:atoms, atoms)
    |> Map.update!(:constants, &attach_constant_atoms(&1, atoms))
  end

  def var_def(name) do
    %VarDef{
      name: name,
      scope_level: 0,
      scope_next: 0,
      var_kind: 0,
      is_const: false,
      is_lexical: false,
      is_captured: false
    }
  end

  defp do_collect_atoms(%Function{} = function, acc) do
    acc = [function.name, function.filename | acc]
    acc = Enum.reduce(function.extra_atoms || [], acc, &[&1 | &2])
    acc = Enum.reduce(function.locals, acc, fn %VarDef{name: name}, acc -> [name | acc] end)

    Enum.reduce(function.constants, acc, fn
      %Function{} = inner, acc -> do_collect_atoms(inner, acc)
      value, acc when is_binary(value) -> [value | acc]
      _value, acc -> acc
    end)
  end

  defp attach_constant_atoms(constants, atoms) do
    for constant <- constants do
      case constant do
        %Function{atoms: own} when own != nil and own != {} -> constant
        %Function{} -> attach_atoms(constant, atoms)
        _ -> constant
      end
    end
  end
end
