defmodule QuickBEAM.VM.Runtime.Web.Encoding do
  @moduledoc "atob and btoa builtins for BEAM mode."

  @behaviour QuickBEAM.VM.Runtime.BindingProvider

  alias QuickBEAM.VM.Interpreter.Values
  alias QuickBEAM.VM.JSThrow

  @doc "Returns the JavaScript global bindings provided by this module."
  def bindings do
    %{
      "btoa" => {:builtin, "btoa", &btoa/2},
      "atob" => {:builtin, "atob", &atob/2}
    }
  end

  defp btoa([arg | _], _) do
    str = Values.stringify(arg)

    if has_non_latin1?(str) do
      JSThrow.type_error!(
        "Failed to execute 'btoa': The string to be encoded contains characters outside of the Latin1 range."
      )
    end

    bytes = for <<cp::utf8 <- str>>, into: <<>>, do: <<cp>>
    Base.encode64(bytes)
  end

  defp atob([arg | _], _) do
    if arg == :undefined do
      JSThrow.type_error!(
        "Failed to execute 'atob': The string to be decoded is not correctly encoded."
      )
    end

    str = Values.stringify(arg)

    case Base.decode64(str, ignore: :whitespace, padding: false) do
      {:ok, decoded} ->
        latin1_to_js_string(decoded)

      :error ->
        JSThrow.type_error!(
          "Failed to execute 'atob': The string to be decoded is not correctly encoded."
        )
    end
  end

  defp has_non_latin1?(<<>>), do: false
  defp has_non_latin1?(<<cp::utf8, rest::binary>>) when cp <= 255, do: has_non_latin1?(rest)
  defp has_non_latin1?(_), do: true

  defp latin1_to_js_string(binary) do
    for <<byte <- binary>>, into: "", do: <<byte::utf8>>
  end
end
