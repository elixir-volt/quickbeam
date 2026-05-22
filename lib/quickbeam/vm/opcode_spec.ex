defmodule QuickBEAM.VM.OpcodeSpec do
  @moduledoc "Authoritative opcode metadata facade used by decoding, analysis, and compiler dispatch."

  alias QuickBEAM.VM.Opcodes

  @type opcode :: non_neg_integer()
  @type opcode_name :: atom()

  def table, do: Opcodes.table()
  def all_opcodes, do: Opcodes.all_opcodes()
  def info(opcode), do: Opcodes.info(opcode)
  def num(name), do: Opcodes.num(name)
  def format_info(format), do: Opcodes.format_info(format)

  def name(opcode) do
    case info(opcode) do
      {name, _size, _pops, _pushes, _format} -> {:ok, name}
      nil -> {:error, {:unknown_opcode, opcode}}
    end
  end

  def stack_effect(opcode) do
    case info(opcode) do
      {_name, _size, pops, pushes, _format} -> {:ok, {pops, pushes}}
      nil -> {:error, {:unknown_opcode, opcode}}
    end
  end

  def short_form_operands(opcode, arg_count), do: Opcodes.short_form_operands(opcode, arg_count)
end
