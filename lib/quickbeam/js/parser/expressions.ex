defmodule QuickBEAM.JS.Parser.Expressions do
  @moduledoc "Expression grammar for the experimental JavaScript parser."

  defmacro __using__(_opts) do
    quote do
      use QuickBEAM.JS.Parser.Expressions.Core
      use QuickBEAM.JS.Parser.Expressions.Functions
      use QuickBEAM.JS.Parser.Expressions.Templates
      use QuickBEAM.JS.Parser.Expressions.Literals
    end
  end
end
