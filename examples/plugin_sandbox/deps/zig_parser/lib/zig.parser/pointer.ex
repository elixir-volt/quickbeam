defmodule Zig.Parser.Pointer do
  defstruct [
    :alignment,
    :sentinel,
    :type,
    :count,
    :location,
    :addrspace,
    const: false,
    volatile: false,
    allowzero: false
  ]

  def parse([:LBRACKET, :RBRACKET | rest], type) do
    %{parse(rest, type) | count: :slice}
  end

  def parse([:LBRACKET, :COLON, sentinel, :RBRACKET | rest], type) do
    %{parse(rest, type) | count: :slice, sentinel: sentinel}
  end

  def parse([:LBRACKET, :*, :RBRACKET | rest], type) do
    %{parse(rest, type) | count: :many}
  end

  def parse([:LBRACKET, :*, :COLON, sentinel, :RBRACKET | rest], type) do
    %{parse(rest, type) | count: :many, sentinel: sentinel}
  end

  def parse([:LBRACKET, :*, :LETTERC, :RBRACKET | rest], type) do
    %{parse(rest, type) | count: :c}
  end

  def parse([:* | rest], type) do
    %{parse(rest, type) | count: :one}
  end

  def parse([{:align, alignment} | rest], type) do
    %{parse(rest, type) | alignment: alignment}
  end

  def parse([:align, :LPAREN, alignment, :RPAREN | rest], type) do
    %{parse(rest, type) | alignment: alignment}
  end

  def parse([:align, :LPAREN, align1, :COLON, align2, :COLON, align3, :RPAREN | rest], type) do
    %{parse(rest, type) | alignment: {align1, align2, align3}}
  end

  for qualifier <- ~w[const volatile allowzero]a do
    def parse([unquote(qualifier) | rest], type) do
      %{parse(rest, type) | unquote(qualifier) => true}
    end
  end

  for property <- ~w[addrspace]a do
    def parse([{unquote(property), value} | rest], type) do
      %{parse(rest, type) | unquote(property) => value}
    end
  end

  def parse([], type), do: %__MODULE__{type: type}
end
