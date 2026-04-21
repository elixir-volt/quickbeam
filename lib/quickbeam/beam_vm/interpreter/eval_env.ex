defmodule QuickBEAM.BeamVM.Interpreter.EvalEnv do
  @moduledoc false

  alias QuickBEAM.BeamVM.{Bytecode, Names}
  alias QuickBEAM.BeamVM.Interpreter.{Closures, Context, Frame}

  require Frame

  def resolve_local_name(name), do: Names.resolve_display_name(name)

  def seed_class_binding(frame, ctx, atom_idx, ctor_closure) do
    case class_binding_local_index(ctx, atom_idx) do
      nil ->
        frame

      idx ->
        Closures.write_captured_local(
          elem(frame, Frame.l2v()),
          idx,
          ctor_closure,
          elem(frame, Frame.locals()),
          elem(frame, Frame.var_refs())
        )

        put_local(frame, idx, ctor_closure)
    end
  end

  def current_func_name(%Context{current_func: func}) do
    case func do
      {:closure, _, %Bytecode.Function{name: name}} -> name
      %Bytecode.Function{name: name} -> name
      _ -> nil
    end
  end

  def current_local_name(
        %Context{current_func: {:closure, _, %Bytecode.Function{locals: locals}}},
        idx
      )
      when idx >= 0 and idx < length(locals),
      do: locals |> Enum.at(idx) |> Map.get(:name) |> resolve_local_name()

  def current_local_name(%Context{current_func: %Bytecode.Function{locals: locals}}, idx)
      when idx >= 0 and idx < length(locals),
      do: locals |> Enum.at(idx) |> Map.get(:name) |> resolve_local_name()

  def current_local_name(_, _), do: nil

  defp class_binding_local_index(%Context{current_func: current_func}, atom_idx) do
    class_name = resolve_local_name(atom_idx)

    current_func
    |> current_bytecode_function()
    |> case do
      %Bytecode.Function{locals: locals} ->
        locals
        |> Enum.with_index()
        |> Enum.filter(fn {%{name: name, scope_level: scope_level, is_lexical: is_lexical}, _idx} ->
          is_lexical and scope_level > 1 and resolve_local_name(name) == class_name
        end)
        |> Enum.max_by(fn {%{scope_level: scope_level}, _idx} -> scope_level end, fn -> nil end)
        |> case do
          nil -> nil
          {_local, idx} -> idx
        end

      _ ->
        nil
    end
  end

  defp class_binding_local_index(_, _), do: nil

  defp current_bytecode_function({:closure, _, %Bytecode.Function{} = fun}), do: fun
  defp current_bytecode_function(%Bytecode.Function{} = fun), do: fun
  defp current_bytecode_function(_), do: nil

  defp put_local(frame, idx, val),
    do: put_elem(frame, Frame.locals(), put_elem(elem(frame, Frame.locals()), idx, val))
end
