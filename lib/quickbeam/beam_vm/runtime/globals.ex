defmodule QuickBEAM.BeamVM.Runtime.Globals do
  @moduledoc false

  # ── Global functions ──

  def parse_int([s, radix | _]) when is_binary(s) and is_number(radix) do
    r = trunc(radix)
    s = String.trim_leading(s)

    case Integer.parse(s, r) do
      {n, _} -> n
      :error -> :nan
    end
  end

  def parse_int([s | _]) when is_binary(s) do
    s = String.trim_leading(s)

    cond do
      String.starts_with?(s, "0x") or String.starts_with?(s, "0X") ->
        case Integer.parse(String.slice(s, 2..-1//1), 16) do
          {n, _} -> n
          :error -> :nan
        end

      true ->
        case Integer.parse(s) do
          {n, _} -> n
          :error -> :nan
        end
    end
  end

  def parse_int([n | _]) when is_number(n), do: trunc(n)
  def parse_int(_), do: :nan

  def parse_float([s | _]) when is_binary(s) do
    case Float.parse(String.trim(s)) do
      {f, ""} -> f
      {f, _} -> f
      :error -> :nan
    end
  end

  def parse_float([n | _]) when is_number(n), do: n * 1.0
  def parse_float(_), do: :nan

  def is_nan([:nan | _]), do: true
  def is_nan([n | _]) when is_number(n), do: false

  def is_nan([s | _]) when is_binary(s) do
    case Float.parse(s) do
      :error -> true
      _ -> false
    end
  end

  def is_nan(_), do: true

  def is_finite([n | _])
      when is_number(n) and n != :infinity and n != :neg_infinity and n != :nan,
      do: true

  def is_finite(_), do: false
end
