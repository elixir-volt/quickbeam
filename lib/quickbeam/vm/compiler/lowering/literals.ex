defmodule QuickBEAM.VM.Compiler.Lowering.Literals do
  @moduledoc "Shared literal extraction helpers for compiler lowering."

  @doc "Extracts a literal string from Erlang abstract syntax, returning nil on non-literals."
  def string({:string, _, chars}) when is_list(chars), do: List.to_string(chars)

  def string({:bin, _, elements}) when is_list(elements) do
    elements
    |> Enum.map(&bin_element_chars/1)
    |> literal_chars()
  end

  def string(_), do: nil

  @doc "Extracts a literal string, ignoring unrecognized binary elements."
  def string_lossy({:string, _, chars}) when is_list(chars), do: List.to_string(chars)

  def string_lossy({:bin, _, elements}) when is_list(elements) do
    elements
    |> Enum.map(fn element -> bin_element_chars(element) || [] end)
    |> List.flatten()
    |> List.to_string()
  end

  def string_lossy(_), do: nil

  defp bin_element_chars({:bin_element, _, {:integer, _, c}, _, _}), do: c
  defp bin_element_chars({:bin_element, _, {:string, _, chars}, _, _}), do: chars
  defp bin_element_chars(_), do: nil

  defp literal_chars(chars) do
    if Enum.any?(chars, &is_nil/1) do
      nil
    else
      chars |> List.flatten() |> List.to_string()
    end
  end
end
