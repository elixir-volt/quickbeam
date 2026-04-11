defmodule QuickBEAM.WebSocket do
  @moduledoc false
  use GenServer

  alias Mint.HTTP

  # Mint.WebSocket.t() is @opaque — Dialyzer can't prove that new/4 returns
  # {:ok, _, _} so it considers handle_upgrade_success and its callees dead.
  @dialyzer {:nowarn_function,
             handle_response: 2, handle_upgrade_success: 3, response_header: 2, notify_open: 1}

  defstruct [
    :id,
    :owner,
    :owner_ref,
    :url,
    :protocols,
    :conn,
    :request_ref,
    :websocket,
    :upgrade_status,
    :pending_close,
    upgrade_headers: [],
    protocol: "",
    closed?: false,
    close_sent?: false
  ]


  @spec connect(args :: [String.t()], owner :: pid()) :: String.t()
  def connect([url, protocols], owner_pid) do
    id = Integer.to_string(System.unique_integer([:positive]))

    {:ok, pid} =
      GenServer.start_link(__MODULE__, %{
        id: id,
        owner: owner_pid,
        url: url,
        protocols: List.wrap(protocols)
      })

    send(owner_pid, {:websocket_started, id, pid})
    id
  end

  @spec send_frame(args :: [term()], owner :: pid()) :: nil
  def send_frame([id, [kind, payload]], owner_pid) do
    send(owner_pid, {:ws_send, id, kind, payload})
    nil
  end

  @spec close(args :: [term()], owner :: pid()) :: nil
  def close([id, code, reason], owner_pid) do
    send(owner_pid, {:ws_close, id, code, reason})
    nil
  end

  # -- GenServer --

  @impl true
  def init(%{id: id, owner: owner, url: url, protocols: protocols}) do
    owner_ref = Process.monitor(owner)
    send(self(), :connect)

    {:ok,
     %__MODULE__{
       id: id,
       owner: owner,
       owner_ref: owner_ref,
       url: url,
       protocols: protocols
     }}
  end

  @impl true
  def handle_info(:connect, state) do
    case open_connection(state) do
      {:ok, state} -> {:noreply, state}
      {:error, state, reason} -> {:stop, reason, emit_error_and_close(state, reason)}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state) do
    {:stop, :normal, state}
  end

  def handle_info(_message, %{conn: nil} = state) do
    {:noreply, state}
  end

  def handle_info(message, state) do
    case Mint.WebSocket.stream(state.conn, message) do
      {:ok, conn, responses} ->
        state = %{state | conn: conn}
        handle_responses(state, responses)

      {:error, conn, reason, responses} ->
        state = %{state | conn: conn}

        state =
          case handle_response_list(state, responses) do
            {:ok, state} -> state
            {:stop, state} -> state
          end

        {:stop, reason, emit_error_and_close(state, reason)}

      :unknown ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:send, _kind, _payload}, %{websocket: nil} = state) do
    {:noreply, state}
  end

  def handle_cast({:send, kind, payload}, state) do
    frame =
      case kind do
        "text" -> {:text, payload}
        "binary" -> {:binary, payload}
      end

    case stream_frame(state, frame) do
      {:ok, state} -> {:noreply, state}
      {:error, state, reason} -> {:stop, reason, emit_error_and_close(state, reason)}
    end
  end

  def handle_cast({:close, _code, _reason}, %{closed?: true} = state) do
    {:noreply, state}
  end

  def handle_cast({:close, code, reason}, %{websocket: nil} = state) do
    {:noreply, %{state | pending_close: {code, reason}}}
  end

  def handle_cast({:close, code, reason}, state) do
    case do_close(state, code, reason) do
      {:ok, state} -> {:noreply, state}
      {:error, state, error} -> {:stop, error, emit_error_and_close(state, error)}
    end
  end

  @impl true
  def terminate(_reason, state) do
    if state.conn do
      try do
        HTTP.close(state.conn)
      catch
        _, _ -> :ok
      end
    end

    :ok
  end

  # -- HTTP upgrade response handling --

  defp handle_responses(state, responses) do
    case handle_response_list(state, responses) do
      {:ok, state} -> {:noreply, state}
      {:stop, state} -> {:stop, :normal, state}
    end
  end

  defp handle_response_list(state, responses) do
    Enum.reduce_while(responses, {:ok, state}, fn response, {:ok, state} ->
      case handle_response(state, response) do
        {:ok, state} -> {:cont, {:ok, state}}
        {:stop, state} -> {:halt, {:stop, state}}
      end
    end)
  end

  defp handle_response(state, {:status, ref, status}) when ref == state.request_ref do
    {:ok, %{state | upgrade_status: status}}
  end

  defp handle_response(state, {:headers, ref, headers}) when ref == state.request_ref do
    {:ok, %{state | upgrade_headers: state.upgrade_headers ++ headers}}
  end

  defp handle_response(state, {:done, ref}) when ref == state.request_ref do
    case Mint.WebSocket.new(state.conn, ref, state.upgrade_status, state.upgrade_headers) do
      {:ok, conn, websocket} ->
        handle_upgrade_success(state, conn, websocket)

      {:error, conn, reason} ->
        {:stop, emit_error_and_close(%{state | conn: conn}, reason)}
    end
  end

  defp handle_response(state, {:data, ref, data})
       when ref == state.request_ref and not is_nil(state.websocket) do
    case Mint.WebSocket.decode(state.websocket, data) do
      {:ok, websocket, frames} ->
        handle_frames(%{state | websocket: websocket}, frames)

      {:error, websocket, reason} ->
        {:stop, emit_error_and_close(%{state | websocket: websocket}, reason)}
    end
  end

  defp handle_response(state, _response), do: {:ok, state}

  defp handle_frames(state, frames) do
    Enum.reduce_while(frames, {:ok, state}, fn frame, {:ok, state} ->
      case handle_frame(state, frame) do
        {:ok, state} -> {:cont, {:ok, state}}
        {:stop, state} -> {:halt, {:stop, state}}
      end
    end)
  end

  defp handle_upgrade_success(state, conn, websocket) do
    state = %{state | conn: conn, websocket: websocket, upgrade_status: nil}

    if state.pending_close do
      {:stop, emit_close(%{state | pending_close: nil, upgrade_headers: []}, 1006, "", false)}
    else
      protocol = response_header(state.upgrade_headers, "sec-websocket-protocol") || ""

      state =
        %{state | protocol: protocol, upgrade_headers: []}
        |> notify_open()

      {:ok, state}
    end
  end

  # -- Frame handling --

  defp handle_frame(state, {:text, text}), do: {:ok, notify_text_message(state, text)}
  defp handle_frame(state, {:binary, data}), do: {:ok, notify_binary_message(state, data)}
  defp handle_frame(state, {:pong, _data}), do: {:ok, state}

  defp handle_frame(state, {:ping, data}) do
    case stream_frame(state, {:pong, data}) do
      {:ok, state} -> {:ok, state}
      {:error, state, error} -> {:stop, emit_error_and_close(state, error)}
    end
  end

  defp handle_frame(state, {:close, code, reason}) do
    state =
      if state.close_sent? do
        state
      else
        case stream_frame(state, :close) do
          {:ok, state} -> state
          {:error, state, _reason} -> state
        end
      end

    {:stop, emit_close(%{state | close_sent?: true}, code || 1005, reason || "", true)}
  end

  # -- Connection setup --

  defp open_connection(state) do
    with {:ok, %{scheme: scheme, host: host, port: port, path: path} = info} <-
           parse_url(state.url),
         {:ok, conn} <- HTTP.connect(http_scheme(scheme), host, port, connect_opts(info)),
         {:ok, conn, ref} <-
           Mint.WebSocket.upgrade(
             websocket_scheme(scheme),
             conn,
             path,
             upgrade_headers(state.protocols)
           ) do
      {:ok, %{state | conn: conn, request_ref: ref}}
    else
      {:error, %Mint.TransportError{} = reason} -> {:error, state, reason}
      {:error, %Mint.HTTPError{} = reason} -> {:error, state, reason}
      {:error, %Mint.WebSocketError{} = reason} -> {:error, state, reason}
      {:error, conn, reason} -> {:error, %{state | conn: conn}, reason}
      {:error, reason} -> {:error, state, reason}
    end
  end

  # -- Close / send --

  defp do_close(%{websocket: nil} = state, _code, _reason), do: {:ok, state}

  defp do_close(state, code, reason) do
    frame = if code == 1000 and reason == "", do: :close, else: {:close, code, reason}

    case stream_frame(state, frame) do
      {:ok, state} -> {:ok, %{state | close_sent?: true}}
      {:error, state, error} -> {:error, state, error}
    end
  end

  defp stream_frame(state, frame) do
    case Mint.WebSocket.encode(state.websocket, frame) do
      {:ok, websocket, data} ->
        case Mint.WebSocket.stream_request_body(state.conn, state.request_ref, data) do
          {:ok, conn} ->
            {:ok, %{state | conn: conn, websocket: websocket}}

          {:error, conn, reason} ->
            {:error, %{state | conn: conn, websocket: websocket}, reason}
        end

      {:error, websocket, reason} ->
        {:error, %{state | websocket: websocket}, reason}
    end
  end

  # -- URL parsing --

  defp parse_url(url) do
    uri = URI.parse(url)

    cond do
      uri.scheme not in ["ws", "wss"] ->
        {:error, ArgumentError.exception("unsupported WebSocket scheme")}

      is_nil(uri.host) or uri.host == "" ->
        {:error, ArgumentError.exception("missing WebSocket host")}

      true ->
        {:ok,
         %{
           scheme: uri.scheme,
           host: uri.host,
           port: uri.port || default_port(uri.scheme),
           path: path_with_query(uri)
         }}
    end
  end

  defp path_with_query(%URI{path: path, query: nil}) when path in [nil, ""], do: "/"
  defp path_with_query(%URI{path: path, query: nil}), do: path
  defp path_with_query(%URI{path: path, query: query}) when path in [nil, ""], do: "/?" <> query
  defp path_with_query(%URI{path: path, query: query}), do: path <> "?" <> query

  defp connect_opts(%{scheme: "ws"}), do: [protocols: [:http1]]

  defp connect_opts(%{scheme: "wss", host: host}) do
    [
      protocols: [:http1],
      transport_opts: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        server_name_indication: String.to_charlist(host),
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
      ]
    ]
  end

  defp upgrade_headers([]), do: []
  defp upgrade_headers(protocols), do: [{"sec-websocket-protocol", Enum.join(protocols, ", ")}]

  defp http_scheme("ws"), do: :http
  defp http_scheme("wss"), do: :https

  defp websocket_scheme("ws"), do: :ws
  defp websocket_scheme("wss"), do: :wss

  defp default_port("ws"), do: 80
  defp default_port("wss"), do: 443

  # -- Event notifications --

  defp response_header(headers, name) do
    Enum.find_value(headers, fn
      {key, value} when is_binary(key) -> if String.downcase(key) == name, do: value
      _ -> nil
    end)
  end

  defp notify_open(state) do
    send(state.owner, {:websocket_event, ["__ws_open", state.id, state.protocol]})
    state
  end

  defp notify_text_message(state, payload) do
    send(state.owner, {:websocket_event, ["__ws_message", state.id, payload]})
    state
  end

  defp notify_binary_message(state, payload) do
    send(state.owner, {:websocket_event, ["__ws_message", state.id, {:bytes, payload}]})
    state
  end

  defp emit_error_and_close(state, reason) do
    state
    |> notify_error(reason)
    |> emit_close(1006, "", false)
  end

  defp notify_error(state, reason) do
    send(state.owner, {:websocket_event, ["__ws_error", state.id, Exception.message(reason)]})
    state
  end

  defp emit_close(%{closed?: true} = state, _code, _reason, _was_clean), do: state

  defp emit_close(state, code, reason, was_clean) do
    send(state.owner, {:websocket_event, ["__ws_close", state.id, code, reason, was_clean]})
    %{state | closed?: true}
  end
end
