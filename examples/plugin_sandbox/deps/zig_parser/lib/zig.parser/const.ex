defmodule Zig.Parser.Const do
  defstruct [
    :name,
    :type,
    :value,
    :location,
    :linksection,
    :addrspace,
    :doc_comment,
    pub: false,
    export: false,
    extern: false,
    comptime: false
  ]

  @terminators [[], [:SEMICOLON]]

  def parse([:COLON, type | terminator]) when terminator in @terminators do
    %__MODULE__{type: type}
  end

  def parse([:COLON, type | rest]) do
    %{parse(rest) | type: type}
  end

  def parse([name | rest]) do
    %{parse(rest) | name: name}
  end

  def parse([]), do: %__MODULE__{}

  def extend(const, [:=, value, :SEMICOLON | rest]) do
    {%{const | value: value}, rest}
  end

  def extend(const, [:SEMICOLON | rest]), do: {const, rest}
end
