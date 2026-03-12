defmodule Zig.Parser.ParseError do
  defexception [:message, :remainder, :context, :line, :column]

  def message(e = %{line: {line, _}}) do
    "#{e.message} at (#{line}:#{e.column})"
  end
end
