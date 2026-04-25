defmodule QuickBEAM.VM.Runtime.Web.Encoding do
  @moduledoc "atob and btoa builtins for BEAM mode."

  import Bitwise

  alias QuickBEAM.VM.Interpreter.Values
  alias QuickBEAM.VM.JSThrow

  def bindings do
    %{
      "btoa" => {:builtin, "btoa", &btoa/2},
      "atob" => {:builtin, "atob", &atob/2}
    }
  end

  defp btoa([arg | _], _) do
    str = Values.stringify(arg)

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

    str = Values.stringify(arg)

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

end
