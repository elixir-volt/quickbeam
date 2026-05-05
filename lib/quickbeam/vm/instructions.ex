defmodule QuickBEAM.VM.Instructions do
  @moduledoc false

  alias QuickBEAM.VM.Opcodes

  @op Opcodes.all_opcodes()

  def collect_atoms(instructions) do
    instructions
    |> Enum.flat_map(fn
      {:define_field, name} when is_binary(name) -> [name]
      {:get_var, name} -> [name]
      {:get_var_undef, name} -> [name]
      {:put_var, name} -> [name]
      {:get_field, name} -> [name]
      {:get_field2, name} -> [name]
      {:put_field, name} -> [name]
      {:set_name, name} -> [name]
      {:define_method, name, _flags} -> [name]
      {:define_class, name, _flags} -> [name]
      {:private_symbol, name} -> [name]
      {:throw_error, _type, atom} -> [atom]
      {:with_get_var, name, _label} -> [name]
      {:with_put_var, name, _label} -> [name]
      {:with_delete_var, name, _label} -> [name]
      _ -> []
    end)
    |> Enum.uniq()
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

  def finalize(instructions, atoms, arg_count) do
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
              :get_var_undef,
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
  defp atom_operand(name, atoms), do: Map.fetch!(atoms, name)

  defp stack_effect({:call, argc}), do: {1 + argc, 1}
  defp stack_effect({:call_method, argc}), do: {2 + argc, 1}
  defp stack_effect({:call_constructor, argc}), do: {2 + argc, 1}
  defp stack_effect({:get_var, _name}), do: {0, 1}
  defp stack_effect({:get_var_undef, _name}), do: {0, 1}
  defp stack_effect({:put_var, _name}), do: {1, 0}
  defp stack_effect({:array_from, count}), do: {count, 1}
  defp stack_effect({:define_field, _name}), do: {2, 1}
  defp stack_effect({:get_field, _name}), do: {1, 1}
  defp stack_effect({:get_field2, _name}), do: {1, 2}
  defp stack_effect({:put_field, _name}), do: {2, 0}
  defp stack_effect({:set_name, _name}), do: {1, 1}
  defp stack_effect({:define_method, _name, _flags}), do: {2, 1}
  defp stack_effect({:define_class, _name, _flags}), do: {2, 2}
  defp stack_effect({:define_method_computed, _flags}), do: {3, 1}
  defp stack_effect({:close_loc, _idx}), do: {0, 0}
  defp stack_effect({:set_loc_uninitialized, _idx}), do: {0, 0}
  defp stack_effect(:set_home_object), do: {2, 2}
  defp stack_effect(:check_ctor), do: {0, 0}
  defp stack_effect(:check_ctor_return), do: {1, 2}
  defp stack_effect(:add_brand), do: {2, 0}
  defp stack_effect(:private_in), do: {2, 1}
  defp stack_effect(:for_of_start), do: {1, 3}
  defp stack_effect({:for_of_next, _idx}), do: {0, 2}
  defp stack_effect({:with_get_var, _name, _label}), do: {1, 1}
  defp stack_effect({:with_put_var, _name, _label}), do: {2, 1}
  defp stack_effect({:with_delete_var, _name, _label}), do: {1, 1}
  defp stack_effect(:check_brand), do: {2, 2}
  defp stack_effect(:get_private_field), do: {2, 1}
  defp stack_effect(:put_private_field), do: {3, 0}
  defp stack_effect(:define_private_field), do: {3, 1}
  defp stack_effect({:private_symbol, _name}), do: {0, 1}
  defp stack_effect(:set_name_computed), do: {2, 2}
  defp stack_effect({:catch, _label}), do: {0, 1}
  defp stack_effect({:gosub, _label}), do: {0, 0}
  defp stack_effect(:nip_catch), do: {2, 1}
  defp stack_effect(:ret), do: {1, 0}
  defp stack_effect({:eval, argc, _scope}), do: {1 + argc, 1}
  defp stack_effect({op, _label}) when op in [:jump, :gosub], do: {0, 0}
  defp stack_effect({op, _label}) when op in [:jump_if_false, :jump_if_true], do: {1, 0}
  defp stack_effect({:catch, _label}), do: {0, 1}
  defp stack_effect({:throw_error, _type, _atom}), do: {0, 0}
  defp stack_effect({:rest, _start}), do: {0, 1}

  defp stack_effect({_op, _arg} = instruction),
    do: opcode_stack_effect(to_op(instruction, %{}, %{}, 0))

  defp stack_effect(instruction), do: opcode_stack_effect(to_op(instruction, %{}, %{}, 0))

  defp opcode_stack_effect({op, _args}) do
    {_name, _size, pops, pushes, _format} = Opcodes.info(op)
    {pops, pushes}
  end
end
