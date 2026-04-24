defmodule QuickBEAM.VM.Runtime.GlobalNumeric do
  @moduledoc false
  alias QuickBEAM.VM.Interpreter.Values

  def parse_int([string, radix | _], _) when is_binary(string) and is_number(radix) do
    base = trunc(radix)
    string = String.trim_leading(string)

    if base == 0 or base == 10 do
      parse_int([string], nil)
    else
      cond do
        base == 16 ->
          string = string |> String.replace_prefix("0x", "") |> String.replace_prefix("0X", "")

          case Integer.parse(string, 16) do
            {n, _} -> n
            :error -> :nan
          end

        base in 2..36 ->
          case Integer.parse(string, base) do
            {n, _} -> n
            :error -> :nan
          end

        true ->
          :nan
      end
    end
  end

  def parse_int([string | _], _) when is_binary(string) do
    string = String.trim_leading(string)

    if String.starts_with?(string, "0x") or String.starts_with?(string, "0X") do
      case Integer.parse(binary_part(string, 2, byte_size(string) - 2), 16) do
        {n, _} -> n
        :error -> :nan
      end
    else
      case Integer.parse(string) do
        {n, _} -> n
        :error -> :nan
      end
    end
  end

  def parse_int([n | _], _) when is_number(n), do: trunc(n)
  def parse_int(_, _), do: :nan

  def parse_float([string | _], _) when is_binary(string) do
    string = String.trim(string)

    cond do
      String.starts_with?(string, "Infinity") or String.starts_with?(string, "+Infinity") ->
        :infinity

      String.starts_with?(string, "-Infinity") ->
        :neg_infinity

      true ->
        case Float.parse(string) do
          {n, _} -> n
          :error -> :nan
        end
    end
  end

  def parse_float([n | _], _) when is_number(n), do: n * 1.0
  def parse_float(_, _), do: :nan

  def nan?([:nan | _], _), do: true
  def nan?([:infinity | _], _), do: false
  def nan?([:neg_infinity | _], _), do: false
  def nan?([n | _], _) when is_number(n), do: false

  def nan?([string | _], _) when is_binary(string) do
    case Float.parse(String.trim_leading(string)) do
      {_, _} -> false
      :error -> true
    end
  end

  def nan?([val | _], _) do
    case Values.to_number(val) do
      :nan -> true
      n when is_number(n) -> false
      _ -> true
    end
  end

  def nan?(_, _), do: true

  def finite?([n | _], _) when is_number(n), do: true
  def finite?([:infinity | _], _), do: false
  def finite?([:neg_infinity | _], _), do: false
  def finite?([:nan | _], _), do: false

  def finite?([val | _], _) do
    case Values.to_number(val) do
      n when is_number(n) -> true
      _ -> false
    end
  end

  def finite?(_, _), do: false
end
