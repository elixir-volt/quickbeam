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
      defined_arg_count: length(args),
      stack_size: Assembler.stack_size(instructions),
      locals: Enum.map(args ++ locals, &var_def/1),
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
    %{function | byte_code: Assembler.encode(instructions, atoms)}
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

  defp var_def(name) do
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
      if match?(%Function{}, constant), do: attach_atoms(constant, atoms), else: constant
    end
  end
end
