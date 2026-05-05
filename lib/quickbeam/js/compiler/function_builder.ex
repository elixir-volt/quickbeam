defmodule QuickBEAM.JS.Compiler.FunctionBuilder do
  @moduledoc false

  alias QuickBEAM.VM.Instructions

  def build(opts) do
    instructions = Keyword.fetch!(opts, :instructions)
    args = Keyword.fetch!(opts, :args)
    locals = Keyword.fetch!(opts, :locals)
    extra_atoms = Instructions.collect_atoms(instructions)

    function = %QuickBEAM.VM.Function{
      id: :erlang.unique_integer([:positive, :monotonic]),
      name: Keyword.fetch!(opts, :name),
      filename: "<elixir-js-compiler>",
      line_num: 1,
      col_num: 1,
      arg_count: length(args),
      var_count: length(locals),
      defined_arg_count: Keyword.get(opts, :defined_arg_count, length(args)),
      stack_size: Instructions.stack_size(instructions),
      locals: Keyword.get(opts, :local_defs, Enum.map(args ++ locals, &var_def/1)),
      var_ref_count: Keyword.get(opts, :var_ref_count, 0),
      closure_vars: Keyword.get(opts, :closure_vars, []),
      constants: Keyword.fetch!(opts, :constants),
      extra_atoms: extra_atoms,
      has_prototype: Keyword.fetch!(opts, :has_prototype),
      has_simple_parameter_list: Keyword.fetch!(opts, :has_simple_parameter_list),
      new_target_allowed: Keyword.fetch!(opts, :new_target_allowed),
      arguments_allowed: true,
      is_strict_mode: false,
      has_debug_info: false,
      source: Keyword.fetch!(opts, :source)
    }

    atoms = collect_atoms(function)
    resolved = Instructions.finalize(instructions, atoms, function.arg_count)

    %{function | atoms: atoms, instructions: resolved}
    |> attach_own_constant_atoms()
  end

  defp attach_own_constant_atoms(
         %QuickBEAM.VM.Function{atoms: atoms, constants: constants} = function
       ) do
    constants =
      for c <- constants do
        case c do
          %QuickBEAM.VM.Function{atoms: nil} -> attach_atoms(c, atoms)
          %QuickBEAM.VM.Function{} -> c
          _ -> c
        end
      end

    %{function | constants: constants}
  end

  def collect_atoms(%QuickBEAM.VM.Function{} = function) do
    function
    |> do_collect_atoms([])
    |> Enum.reject(&(match?({:predefined, _}, &1) or is_nil(&1)))
    |> Enum.uniq()
    |> List.to_tuple()
  end

  def attach_atoms(%QuickBEAM.VM.Function{} = function, atoms) do
    function
    |> Map.put(:atoms, atoms)
    |> Map.update!(:constants, &attach_constant_atoms(&1, atoms))
  end

  def var_def(name) do
    %QuickBEAM.VM.VarDef{
      name: name,
      scope_level: 0,
      scope_next: 0,
      var_kind: 0,
      is_const: false,
      is_lexical: false,
      is_captured: false
    }
  end

  defp do_collect_atoms(%QuickBEAM.VM.Function{} = function, acc) do
    acc = [function.name, function.filename | acc]
    acc = Enum.reduce(function.extra_atoms || [], acc, &[&1 | &2])

    acc =
      Enum.reduce(function.locals, acc, fn %QuickBEAM.VM.VarDef{name: name}, acc ->
        [name | acc]
      end)

    Enum.reduce(function.constants, acc, fn
      %QuickBEAM.VM.Function{} = inner, acc -> do_collect_atoms(inner, acc)
      value, acc when is_binary(value) -> [value | acc]
      _value, acc -> acc
    end)
  end

  defp attach_constant_atoms(constants, atoms) do
    for constant <- constants do
      case constant do
        %QuickBEAM.VM.Function{atoms: own} when own != nil and own != {} -> constant
        %QuickBEAM.VM.Function{} -> attach_atoms(constant, atoms)
        _ -> constant
      end
    end
  end
end
