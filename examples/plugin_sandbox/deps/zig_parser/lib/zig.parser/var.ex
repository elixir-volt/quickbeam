defmodule Zig.Parser.Var do
  defstruct [
    :name,
    :type,
    :value,
    :location,
    :doc_comment,
    :alignment,
    :linksection,
    :addrspace,
    extern: false,
    export: false,
    pub: false,
    threadlocal: false,
    comptime: false
  ]

  def parse([:COLON, type | rest]) do
    %{parse(rest) | type: type}
  end

  def parse([{:linksection, {:enum_literal, section}} | rest]) do
    %{parse(rest) | linksection: section}
  end

  def parse([{:addrspace, {:enum_literal, section}} | rest]) do
    %{parse(rest) | addrspace: section}
  end

  def parse([{:align, alignment} | rest]) do
    %{parse(rest) | alignment: alignment}
  end

  def parse([name | rest]) do
    %{parse(rest) | name: name}
  end

  def parse([]), do: %__MODULE__{}

  def extend(var, [:=, value, :SEMICOLON | rest]) do
    {%{var | value: value}, rest}
  end

  def extend(var, [:SEMICOLON | rest]), do: {var, rest}
end
