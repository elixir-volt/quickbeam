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
      %{scheme: scheme} = parsed ->
        host = Map.get(parsed, :host, "")
        port = Map.get(parsed, :port, :undefined)
        path = Map.get(parsed, :path, "")
        query = Map.get(parsed, :query, :undefined)
        fragment = Map.get(parsed, :fragment, :undefined)
        userinfo = Map.get(parsed, :userinfo, "")

        {username, password} = split_userinfo(userinfo)

        scheme_lower = String.downcase(scheme)

        port_str =
          cond do
            port == :undefined -> ""
            is_default_port?(scheme_lower, port) -> ""
            true -> Integer.to_string(port)
          end

        actual_port =
          cond do
            port != :undefined -> port
            true -> Map.get(@default_ports, scheme_lower)
          end

        path =
          if host != "" and path == "" do
            "/"
          else
            path
          end

        {:ok,
         %{
           "protocol" => scheme_lower <> ":",
           "hostname" => String.downcase(host),
           "port" => port_str,
           "pathname" => path,
           "search" => if(query != :undefined and query != "", do: "?" <> query, else: ""),
           "hash" => if(fragment != :undefined and fragment != "", do: "#" <> fragment, else: ""),
           "username" => username,
           "password" => password,
           "origin" => build_origin(scheme_lower, host, port_str),
           "href" =>
             build_href(scheme_lower, username, password, host, port_str, path, query, fragment),
           "_port" => actual_port
         }}

      %{} ->
        {:error, "Invalid URL"}
    end
  end

  defp split_userinfo(""), do: {"", ""}

  defp split_userinfo(userinfo) do
    case String.split(userinfo, ":", parts: 2) do
      [user, pass] -> {user, pass}
      [user] -> {user, ""}
    end
  end

  defp is_default_port?(scheme, port) do
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
    result = scheme <> "://"

    result =
      if username != "" do
        if password != "" do
          result <> username <> ":" <> password <> "@"
        else
          result <> username <> "@"
        end
      else
        result
      end

    result = result <> String.downcase(host)

    result =
      if port_str != "" do
        result <> ":" <> port_str
      else
        result
      end

    result = result <> path

    result =
      if query != :undefined and query != "" do
        result <> "?" <> query
      else
        result
      end

    if fragment != :undefined and fragment != "" do
      result <> "#" <> fragment
    else
      result
    end
  end

  defp do_recompose(c) do
    scheme = String.trim_trailing(c["protocol"] || "", ":")
    host = c["hostname"] || ""
    port = c["port"] || ""
    path = c["pathname"] || "/"
    search = c["search"] || ""
    hash = c["hash"] || ""
    username = c["username"] || ""
    password = c["password"] || ""

    query =
      if String.starts_with?(search, "?"), do: String.slice(search, 1..-1//1), else: search

    fragment =
      if String.starts_with?(hash, "#"), do: String.slice(hash, 1..-1//1), else: hash

    parts = %{scheme: scheme, host: host, path: path}

    parts =
      if port != "" do
        Map.put(parts, :port, String.to_integer(port))
      else
        parts
      end

    parts =
      if query != "" do
        Map.put(parts, :query, query)
      else
        parts
      end

    parts =
      if fragment != "" do
        Map.put(parts, :fragment, fragment)
      else
        parts
      end

    userinfo =
      cond do
        username != "" and password != "" -> username <> ":" <> password
        username != "" -> username
        true -> ""
      end

    parts =
      if userinfo != "" do
        Map.put(parts, :userinfo, userinfo)
      else
        parts
      end

    :uri_string.recompose(parts)
  end
end
