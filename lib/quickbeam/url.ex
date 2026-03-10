defmodule QuickBEAM.URL do
  @moduledoc false

  @default_ports %{
    "http" => 80,
    "https" => 443,
    "ftp" => 21,
    "ws" => 80,
    "wss" => 443
  }

  @special_schemes ~w(http https ftp ws wss file)

  def parse(args) do
    [input | rest] = args
    base = List.first(rest)

    input = String.trim(input)

    case resolve_and_parse(input, base) do
      {:ok, components} ->
        %{"ok" => true, "components" => components}

      {:error, reason} ->
        %{"ok" => false, "error" => reason}
    end
  end

  def recompose(args) do
    [components] = args
    do_recompose(components)
  end

  def dissect_query([qs]) when is_binary(qs) do
    qs
    |> :uri_string.dissect_query()
    |> Enum.map(fn
      {k, true} -> [to_string(k), ""]
      {k, v} -> [to_string(k), to_string(v)]
    end)
  end

  def compose_query([entries]) when is_list(entries) do
    entries
    |> Enum.map(fn [k, v] -> {k, v} end)
    |> :uri_string.compose_query()
  end

  defp resolve_and_parse(input, nil) do
    parse_absolute(input)
  end

  defp resolve_and_parse(input, base) do
    case parse_absolute(base) do
      {:ok, _base_components} ->
        resolved = :uri_string.resolve(input, base)

        if is_binary(resolved) do
          parse_absolute(resolved)
        else
          {:error, "Invalid URL"}
        end

      {:error, _} ->
        {:error, "Invalid base URL"}
    end
  end

  defp parse_absolute(input) do
    case :uri_string.parse(input) do
      %{scheme: scheme} = parsed -> {:ok, build_components(parsed, scheme)}
      %{} -> {:error, "Invalid URL"}
    end
  end

  defp build_components(parsed, scheme) do
    host = Map.get(parsed, :host, "")
    port = Map.get(parsed, :port, :undefined)
    path = Map.get(parsed, :path, "")
    query = Map.get(parsed, :query, :undefined)
    fragment = Map.get(parsed, :fragment, :undefined)
    {username, password} = split_userinfo(Map.get(parsed, :userinfo, ""))

    scheme_lower = String.downcase(scheme)
    port_str = format_port(port, scheme_lower)
    path = if(host != "" and path == "", do: "/", else: path)

    %{
      "protocol" => scheme_lower <> ":",
      "hostname" => String.downcase(host),
      "port" => port_str,
      "pathname" => path,
      "search" => prefix_if_present("?", query),
      "hash" => prefix_if_present("#", fragment),
      "username" => username,
      "password" => password,
      "origin" => build_origin(scheme_lower, host, port_str),
      "href" =>
        build_href(scheme_lower, username, password, host, port_str, path, query, fragment),
      "_port" => if(port != :undefined, do: port, else: Map.get(@default_ports, scheme_lower))
    }
  end

  defp format_port(:undefined, _scheme), do: ""

  defp format_port(port, scheme) when is_integer(port) do
    if default_port?(scheme, port), do: "", else: Integer.to_string(port)
  end

  defp prefix_if_present(_prefix, :undefined), do: ""
  defp prefix_if_present(_prefix, ""), do: ""
  defp prefix_if_present(prefix, value), do: prefix <> value

  defp split_userinfo(""), do: {"", ""}

  defp split_userinfo(userinfo) do
    case String.split(userinfo, ":", parts: 2) do
      [user, pass] -> {user, pass}
      [user] -> {user, ""}
    end
  end

  defp default_port?(scheme, port) do
    Map.get(@default_ports, scheme) == port
  end

  defp build_origin(scheme, host, port_str) when scheme in @special_schemes do
    base = scheme <> "://" <> String.downcase(host)

    if port_str != "" do
      base <> ":" <> port_str
    else
      base
    end
  end

  defp build_origin(_scheme, _host, _port_str), do: "null"

  defp build_href(scheme, username, password, host, port_str, path, query, fragment) do
    [
      scheme,
      "://",
      build_userinfo_prefix(username, password),
      String.downcase(host),
      if(port_str != "", do: ":" <> port_str, else: ""),
      path,
      prefix_if_present("?", query),
      prefix_if_present("#", fragment)
    ]
    |> IO.iodata_to_binary()
  end

  defp build_userinfo_prefix("", _), do: ""
  defp build_userinfo_prefix(username, ""), do: username <> "@"
  defp build_userinfo_prefix(username, password), do: username <> ":" <> password <> "@"

  defp do_recompose(c) do
    %{
      scheme: String.trim_trailing(c["protocol"] || "", ":"),
      host: c["hostname"] || "",
      path: c["pathname"] || "/"
    }
    |> put_unless_empty(:port, c["port"], &String.to_integer/1)
    |> put_unless_empty(:query, strip_prefix("?", c["search"] || ""))
    |> put_unless_empty(:fragment, strip_prefix("#", c["hash"] || ""))
    |> put_unless_empty(:userinfo, build_userinfo(c["username"] || "", c["password"] || ""))
    |> :uri_string.recompose()
  end

  defp put_unless_empty(map, _key, "", _transform), do: map
  defp put_unless_empty(map, key, value, transform), do: Map.put(map, key, transform.(value))
  defp put_unless_empty(map, _key, ""), do: map
  defp put_unless_empty(map, key, value), do: Map.put(map, key, value)

  defp strip_prefix(prefix, value) do
    if String.starts_with?(value, prefix), do: String.slice(value, 1..-1//1), else: value
  end

  defp build_userinfo("", _), do: ""
  defp build_userinfo(username, ""), do: username
  defp build_userinfo(username, password), do: username <> ":" <> password
end
