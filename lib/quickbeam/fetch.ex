defmodule QuickBEAM.Fetch do
  @moduledoc false

  @known_methods %{
    "GET" => :get,
    "POST" => :post,
    "PUT" => :put,
    "DELETE" => :delete,
    "PATCH" => :patch,
    "HEAD" => :head,
    "OPTIONS" => :options
  }

  @table :quickbeam_fetch_requests

  @spec fetch([map()]) :: map()
  def fetch([%{"url" => url, "method" => method, "headers" => headers} = opts]) do
    :ok = ensure_httpc_started()
    :ok = ensure_table()

    fetch_id = opts["fetchId"] || System.unique_integer([:positive])
    body = opts["body"]
    redirect = opts["redirect"] || "follow"

    uri = URI.parse(url)
    url_charlist = String.to_charlist(url)

    req_headers =
      Enum.map(headers, fn [k, v] -> {String.to_charlist(k), String.to_charlist(v)} end)

    http_opts = [
      ssl: ssl_opts(uri.host),
      autoredirect: redirect == "follow",
      relaxed: true,
      timeout: 30_000,
      connect_timeout: 10_000
    ]

    request = build_request(url_charlist, req_headers, method, body)

    case :httpc.request(
           atomize_method(method),
           request,
           http_opts,
           [sync: false, body_format: :binary],
           :quickbeam
         ) do
      {:ok, request_id} ->
        :ets.insert(@table, {fetch_id, request_id})

        result =
          receive do
            {:http, {^request_id, {{_, status, reason}, resp_headers, resp_body}}} ->
              %{
                "status" => status,
                "statusText" => List.to_string(reason),
                "headers" =>
                  Enum.map(resp_headers, fn {k, v} -> [to_string(k), to_string(v)] end),
                "body" => {:bytes, IO.iodata_to_binary(resp_body)},
                "url" => url,
                "redirected" => false
              }

            {:http, {^request_id, {:error, reason}}} ->
              raise "fetch failed: #{inspect(reason)}"
          after
            30_000 ->
              cancel_httpc(request_id)
              raise "fetch timed out"
          end

        :ets.delete(@table, fetch_id)
        result

      {:error, reason} ->
        raise "fetch failed: #{inspect(reason)}"
    end
  end

  @spec cancel([integer()]) :: nil
  def cancel([fetch_id]) when is_integer(fetch_id) do
    case :ets.take(@table, fetch_id) do
      [{^fetch_id, request_id}] -> cancel_httpc(request_id)
      [] -> :ok
    end

    nil
  end

  defp cancel_httpc(request_id) do
    try do
      :httpc.cancel_request(request_id, :quickbeam)
    catch
      :error, :badarg -> :ok
    end
  end

  defp build_request(url, headers, method, body)
       when method in ["GET", "HEAD", "OPTIONS", "DELETE"] or is_nil(body) do
    {url, headers}
  end

  defp build_request(url, headers, _method, body) do
    content_type =
      Enum.find_value(headers, ~c"application/octet-stream", fn
        {k, v} -> if :string.lowercase(k) == ~c"content-type", do: v
      end)

    {url, headers, content_type, to_binary(body)}
  end

  defp atomize_method(method) do
    Map.get(@known_methods, method) ||
      raise ArgumentError, "unsupported HTTP method: #{method}"
  end

  defp to_binary(data) when is_binary(data), do: data
  defp to_binary(data) when is_list(data), do: :erlang.list_to_binary(data)
  defp to_binary(_), do: <<>>

  defp ssl_opts(host) do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      server_name_indication: String.to_charlist(host || ""),
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ]
    ]
  end

  @doc false
  def init do
    ensure_table()
  end

  defp ensure_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    end
    :ok
  end

  defp ensure_httpc_started do
    case :inets.start(:httpc, profile: :quickbeam) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end
  end
end
