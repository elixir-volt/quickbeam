defmodule Zig.Parser.Array do
  defstruct [:count, :sentinel, :type, :location]

  def parse([:LBRACKET, count, :RBRACKET], type) do
    %__MODULE__{count: count, type: type}
  end

  def parse([:LBRACKET, count, :COLON, sentinel, :RBRACKET], type) do
    %__MODULE__{count: count, sentinel: sentinel, type: type}
  end
end
