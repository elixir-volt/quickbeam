defmodule QuickBEAM.VM.EvalLexical do
  @moduledoc "Shared helpers for eval lexical-name checks."

  alias QuickBEAM.VM.Interpreter.Context
  alias QuickBEAM.VM.Names

  def current_lexical_names(%Context{
        current_func: {:closure, _, %QuickBEAM.VM.Function{locals: locals}}
      }),
      do: lexical_names(locals)

  def current_lexical_names(%Context{current_func: %QuickBEAM.VM.Function{locals: locals}}),
    do: lexical_names(locals)

  def current_lexical_names(_ctx), do: MapSet.new()

  def lexical_names(locals) do
    locals
    |> Enum.filter(& &1.is_lexical)
    |> Enum.map(&Names.resolve_display_name(&1.name))
    |> Enum.filter(&is_binary/1)
    |> MapSet.new()
  end
end
