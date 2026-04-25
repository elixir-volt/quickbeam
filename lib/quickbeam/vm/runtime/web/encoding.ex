defmodule QuickBEAM.VM.Runtime.Web.Encoding do
  @moduledoc "atob and btoa builtins for BEAM mode."

  import Bitwise

  alias QuickBEAM.VM.JSThrow

  def bindings do
    %{
      "btoa" => {:builtin, "btoa", &btoa/2},
      "atob" => {:builtin, "atob", &atob/2}
    }
  end

  defp btoa([arg | _], _) do
    str = coerce_to_string(arg)

    if has_non_latin1?(str) do
      JSThrow.type_error!("Failed to execute 'btoa': The string to be encoded contains characters outside of the Latin1 range.")
    end

    bytes = for <<cp::utf8 <- str>>, do: cp &&& 0xFF
    Base.encode64(:erlang.list_to_binary(bytes))
  end

  defp atob([arg | _], _) do
    # Per WebIDL: undefined doesn't coerce — it throws directly
    if arg == :undefined do
      JSThrow.type_error!("Failed to execute 'atob': The string to be decoded is not correctly encoded.")
    end

    str = coerce_to_string(arg)

    # Strip ASCII whitespace per HTML spec
    stripped = :binary.replace(str, [" ", "\t", "\n", "\r", "\f"], "", [:global])

    # Validate: only valid base64 chars
    unless valid_base64?(stripped) do
      JSThrow.type_error!("Failed to execute 'atob': The string to be decoded is not correctly encoded.")
    end

    padded = pad_base64(stripped)

    case Base.decode64(padded) do
      {:ok, decoded} ->
        latin1_to_js_string(decoded)

      :error ->
        JSThrow.type_error!("Failed to execute 'atob': The string to be decoded is not correctly encoded.")
    end
  end

  defp coerce_to_string(:undefined), do: "undefined"
  defp coerce_to_string(nil), do: "null"
  defp coerce_to_string(true), do: "true"
  defp coerce_to_string(false), do: "false"
  defp coerce_to_string(:nan), do: "NaN"
  defp coerce_to_string(:infinity), do: "Infinity"
  defp coerce_to_string(:neg_infinity), do: "-Infinity"
  defp coerce_to_string(n) when is_float(n) and n == 0.0, do: "0"
  defp coerce_to_string(n) when is_integer(n), do: Integer.to_string(n)
  defp coerce_to_string(n) when is_float(n), do: format_float(n)
  defp coerce_to_string(s) when is_binary(s), do: s
  defp coerce_to_string(_), do: "[object Object]"

  defp has_non_latin1?(str) do
    String.to_charlist(str) |> Enum.any?(&(&1 > 255))
  end

  defp valid_base64?(<<>>), do: true
  defp valid_base64?(<<c, rest::binary>>) when c in ?A..?Z or c in ?a..?z or c in ?0..?9 or c == ?+ or c == ?/ do
    valid_base64?(rest)
  end
  defp valid_base64?(<<"=", rest::binary>>), do: all_padding?(rest)
  defp valid_base64?(_), do: false

  defp all_padding?(<<>>), do: true
  defp all_padding?(<<"=", rest::binary>>), do: all_padding?(rest)
  defp all_padding?(_), do: false

  defp pad_base64(str) do
    case rem(byte_size(str), 4) do
      0 -> str
      1 -> str <> "==="
      2 -> str <> "=="
      3 -> str <> "="
    end
  end

  defp latin1_to_js_string(binary) do
    binary
    |> :erlang.binary_to_list()
    |> Enum.map(fn byte ->
      if byte < 128, do: <<byte>>, else: <<byte::utf8>>
    end)
    |> IO.iodata_to_binary()
  end

  defp format_float(n) when is_float(n) do
    cond do
      Float.floor(n) == n and abs(n) < 1.0e15 ->
        Integer.to_string(trunc(n))

      true ->
        :erlang.float_to_binary(n, [:compact, {:decimals, 20}])
    end
  end
end
