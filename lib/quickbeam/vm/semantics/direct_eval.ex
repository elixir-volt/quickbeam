defmodule QuickBEAM.VM.Semantics.DirectEval do
  @moduledoc "Direct-eval preparation helpers kept outside the interpreter dispatch loop."

  alias QuickBEAM.JS.Error, as: JSError

  alias QuickBEAM.VM.{
    BytecodeParser,
    Function,
    JSThrow,
    Names,
    Opcodes,
    PredefinedAtoms,
    Value
  }

  alias QuickBEAM.VM.Semantics.Eval, as: EvalSemantics

  @op_define_var Opcodes.num(:define_var)
  @op_check_define_var Opcodes.num(:check_define_var)
  @op_define_func Opcodes.num(:define_func)

  def strict_code(ctx, code) do
    if strict_mode?(ctx), do: "\"use strict\";\n" <> code, else: code
  end

  def compile(nil, code), do: QuickBEAM.JS.Compiler.compile(code)

  def compile(runtime_pid, code) do
    case QuickBEAM.Runtime.compile(runtime_pid, code) do
      {:ok, bc} -> BytecodeParser.decode(bc)
      error -> error
    end
  end

  def reject_lexical_conflicts!(ctx, declared_names) do
    EvalSemantics.reject_lexical_conflicts!(ctx, declared_names, strict_mode?(ctx))
  end

  def declared_names(%Function{} = fun, atoms, instructions_fun)
      when is_function(instructions_fun, 1) do
    local_names =
      fun.locals
      |> Enum.map(&Names.resolve_display_name(&1.name))
      |> Enum.filter(&is_binary/1)

    instruction_names =
      case instructions_fun.(fun) do
        {:ok, insns} -> Enum.reduce(insns, [], &collect_declared_instruction_name(&1, &2, atoms))
        _ -> []
      end

    MapSet.new(local_names ++ instruction_names)
  end

  def declared_names(_, _, _), do: MapSet.new()

  def handle_compile_error({:error, {:parse_error, errors}}),
    do: JSThrow.syntax_error!(parse_error_message(errors))

  def handle_compile_error({:error, msg}) when is_binary(msg), do: JSThrow.syntax_error!(msg)

  def handle_compile_error({:error, %JSError{name: name, message: msg}}),
    do: throw({:js_throw, QuickBEAM.VM.Heap.make_error(msg, name)})

  def handle_compile_error(_), do: {:undefined, %{}}

  defp collect_declared_instruction_name({op, [atom_ref, _scope]}, acc, atoms)
       when op in [@op_define_var, @op_check_define_var] do
    prepend_declared_atom(atom_ref, acc, atoms)
  end

  defp collect_declared_instruction_name({@op_define_func, [atom_ref, _flags]}, acc, atoms) do
    prepend_declared_atom(atom_ref, acc, atoms)
  end

  defp collect_declared_instruction_name(_, acc, _atoms), do: acc

  defp prepend_declared_atom(atom_ref, acc, atoms) do
    case resolve_declared_atom(atom_ref, atoms) do
      name when is_binary(name) -> [name | acc]
      _ -> acc
    end
  end

  defp parse_error_message([%{message: message} | _]), do: message
  defp parse_error_message(_errors), do: "Syntax error"

  defp strict_mode?(ctx), do: Value.strict_context?(ctx)

  defp resolve_declared_atom({:predefined, idx}, _atoms), do: PredefinedAtoms.lookup(idx)

  defp resolve_declared_atom(idx, atoms)
       when is_integer(idx) and idx >= 0 and idx < tuple_size(atoms),
       do: elem(atoms, idx)

  defp resolve_declared_atom(name, _atoms) when is_binary(name), do: name
  defp resolve_declared_atom(_, _atoms), do: nil
end
