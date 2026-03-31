defmodule QuickBEAM.WPT.WebSocketTest do
  @moduledoc "Ported from WPT: Create-http-urls.any.js, Create-invalid-urls.any.js, Create-valid-url-array-protocols.any.js, Create-valid-url-binaryType-blob.any.js, Create-valid-url-protocol-empty.any.js, Create-valid-url-protocol-setCorrectly.any.js, Create-protocol-with-space.any.js, Create-protocols-repeated.any.js, Create-nonAscii-protocol-string.any.js, binaryType-wrong-value.any.js, close-invalid.any.js, Close-onlyReason.any.js, Close-server-initiated-close.any.js, Close-undefined.any.js, Send-binary-arraybuffer.any.js, Send-binary-blob.any.js"
  use ExUnit.Case, async: false
  use Plug.Router

  plug(:match)
  plug(:dispatch)

  defmodule EchoSocket do
    @behaviour WebSock

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_in({"Goodbye", opcode: :text}, state),
      do: {:stop, :normal, {1000, "Goodbye"}, state}

    def handle_in({data, opcode: opcode}, state), do: {:push, {opcode, data}, state}

    @impl true
    def handle_info(_msg, state), do: {:ok, state}

    @impl true
    def terminate(_reason, _state), do: :ok
  end

  get "/echo" do
    WebSockAdapter.upgrade(conn, EchoSocket, %{}, [])
  end

  get "/protocol" do
    conn =
      case get_req_header(conn, "sec-websocket-protocol") do
        [header] ->
          case negotiated_protocol(header) do
            nil -> conn
            protocol -> put_resp_header(conn, "sec-websocket-protocol", protocol)
          end

        _ ->
          conn
      end

    WebSockAdapter.upgrade(conn, EchoSocket, %{}, [])
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  setup_all do
    {:ok, server} =
      Bandit.start_link(plug: __MODULE__, port: 0, ip: :loopback, startup_log: false)

    {:ok, {_addr, port}} = ThousandIsland.listener_info(server)
    {:ok, pool} = QuickBEAM.ContextPool.start_link()

    base_host = "127.0.0.1:#{port}"

    %{
      pool: pool,
      ws_echo_url: "ws://#{base_host}/echo",
      http_echo_url: "http://#{base_host}/echo",
      protocol_url: "ws://#{base_host}/protocol"
    }
  end

  setup do
    {:ok, rt} = QuickBEAM.start()

    on_exit(fn ->
      try do
        QuickBEAM.stop(rt)
      catch
        :exit, _ -> :ok
      end
    end)

    %{rt: rt}
  end

  describe "WPT WebSocket constructor" do
    test "http URLs normalize to ws", %{
      rt: rt,
      http_echo_url: http_echo_url,
      ws_echo_url: ws_echo_url
    } do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const ws = new WebSocket(#{inspect(http_echo_url)});
               const ok = ws.url === #{inspect(ws_echo_url)};
               ws.close();
               ok;
               """)
    end

    test "invalid URLs throw SyntaxError", %{rt: rt, http_echo_url: http_echo_url} do
      fragment_url = http_echo_url <> "#test"

      assert {:ok, [true, true, true, true, true, true]} =
               QuickBEAM.eval(rt, """
               const inputs = [
                 'ws://foo bar.com/',
                 'ftp://example.com/',
                 'mailto:example@example.org',
                 'about:blank',
                 #{inspect(fragment_url)},
                 '#test'
               ];

               inputs.map((input) => {
                 try {
                   new WebSocket(input);
                   return false;
                 } catch (e) {
                   return e instanceof DOMException && e.name === 'SyntaxError';
                 }
               });
               """)
    end

    test "protocol is empty before connection is established", %{rt: rt, ws_echo_url: ws_echo_url} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const ws = new WebSocket(#{inspect(ws_echo_url)});
               const ok = ws.protocol === '';
               ws.close();
               ok;
               """)
    end

    test "repeated protocols throw SyntaxError", %{rt: rt, ws_echo_url: ws_echo_url} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               try {
                 new WebSocket(#{inspect(ws_echo_url)}, ['echo', 'echo']);
                 false;
               } catch (e) {
                 e instanceof DOMException && e.name === 'SyntaxError';
               }
               """)
    end

    test "protocols with spaces throw SyntaxError", %{rt: rt, ws_echo_url: ws_echo_url} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               try {
                 new WebSocket(#{inspect(ws_echo_url)}, 'ec ho');
                 false;
               } catch (e) {
                 e instanceof DOMException && e.name === 'SyntaxError';
               }
               """)
    end

    test "non-ascii protocols throw SyntaxError", %{rt: rt, ws_echo_url: ws_echo_url} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               try {
                 new WebSocket(#{inspect(ws_echo_url)}, '\u0080echo');
                 false;
               } catch (e) {
                 e instanceof DOMException && e.name === 'SyntaxError';
               }
               """)
    end
  end

  describe "WPT WebSocket connection state" do
    test "binaryType defaults to blob", %{rt: rt, ws_echo_url: ws_echo_url} do
      assert {:ok, true} =
               QuickBEAM.eval(
                 rt,
                 """
                 await new Promise((resolve, reject) => {
                   const ws = new WebSocket(#{inspect(ws_echo_url)});
                   ws.onopen = () => {
                     const ok = ws.binaryType === 'blob';
                     ws.close();
                     resolve(ok);
                   };
                   ws.onerror = () => reject(new Error('unexpected error'));
                 });
                 """,
                 timeout: 5000
               )
    end

    test "invalid binaryType assignment is ignored", %{rt: rt, ws_echo_url: ws_echo_url} do
      assert {:ok, true} =
               QuickBEAM.eval(
                 rt,
                 """
                 await new Promise((resolve, reject) => {
                   const ws = new WebSocket(#{inspect(ws_echo_url)});
                   ws.onopen = () => {
                     ws.binaryType = 'notBlobOrArrayBuffer';
                     const ok = ws.binaryType === 'blob';
                     ws.close();
                     resolve(ok);
                   };
                   ws.onerror = () => reject(new Error('unexpected error'));
                 });
                 """,
                 timeout: 5000
               )
    end

    test "string protocol is negotiated", %{rt: rt, protocol_url: protocol_url} do
      assert {:ok, true} =
               QuickBEAM.eval(
                 rt,
                 """
                 await new Promise((resolve, reject) => {
                   const ws = new WebSocket(#{inspect(protocol_url)}, 'echo');
                   ws.onopen = () => {
                     const ok = ws.protocol === 'echo';
                     ws.close();
                     resolve(ok);
                   };
                   ws.onerror = () => reject(new Error('unexpected error'));
                 });
                 """,
                 timeout: 5000
               )
    end

    test "array protocols are accepted", %{rt: rt, protocol_url: protocol_url} do
      assert {:ok, true} =
               QuickBEAM.eval(
                 rt,
                 """
                 await new Promise((resolve, reject) => {
                   const ws = new WebSocket(#{inspect(protocol_url)}, ['echo', 'chat']);
                   ws.onopen = () => {
                     const ok = ws.readyState === WebSocket.OPEN && ws.protocol === 'echo';
                     ws.close();
                     resolve(ok);
                   };
                   ws.onerror = () => reject(new Error('unexpected error'));
                 });
                 """,
                 timeout: 5000
               )
    end
  end

  describe "WPT WebSocket close" do
    test "invalid close codes throw InvalidAccessError", %{rt: rt, ws_echo_url: ws_echo_url} do
      assert {:ok, [true, true, true, true, true, true]} =
               QuickBEAM.eval(
                 rt,
                 """
                 await Promise.all([
                   0,
                   500,
                   NaN,
                   'string',
                   null,
                   0x10000 + 1000
                 ].map((value) => new Promise((resolve, reject) => {
                   const ws = new WebSocket(#{inspect(ws_echo_url)});
                   ws.onopen = () => {
                     let ok = false;
                     try {
                       ws.close(value);
                     } catch (e) {
                       ok = e instanceof DOMException && e.name === 'InvalidAccessError';
                     }
                     ws.close();
                     resolve(ok);
                   };
                   ws.onerror = () => reject(new Error('unexpected error'));
                 })));
                 """,
                 timeout: 5000
               )
    end

    test "close with only reason throws InvalidAccessError", %{rt: rt, ws_echo_url: ws_echo_url} do
      assert {:ok, true} =
               QuickBEAM.eval(
                 rt,
                 """
                 await new Promise((resolve, reject) => {
                   const ws = new WebSocket(#{inspect(ws_echo_url)});
                   ws.onopen = () => {
                     let ok = false;
                     try {
                       ws.close(undefined, 'Close with only reason');
                     } catch (e) {
                       ok = e instanceof DOMException && e.name === 'InvalidAccessError';
                     }
                     ws.close();
                     resolve(ok);
                   };
                   ws.onerror = () => reject(new Error('unexpected error'));
                 });
                 """,
                 timeout: 5000
               )
    end

    test "close(undefined) succeeds", %{rt: rt, ws_echo_url: ws_echo_url} do
      assert {:ok, true} =
               QuickBEAM.eval(
                 rt,
                 """
                 await new Promise((resolve, reject) => {
                   const ws = new WebSocket(#{inspect(ws_echo_url)});
                   ws.onopen = () => ws.close(undefined);
                   ws.onclose = () => resolve(true);
                   ws.onerror = () => reject(new Error('unexpected error'));
                 });
                 """,
                 timeout: 5000
               )
    end

    test "server initiated close is clean", %{rt: rt, ws_echo_url: ws_echo_url} do
      assert {:ok, true} =
               QuickBEAM.eval(
                 rt,
                 """
                 await new Promise((resolve, reject) => {
                   const ws = new WebSocket(#{inspect(ws_echo_url)});
                   let opened = false;
                   ws.onopen = () => {
                     opened = true;
                     ws.send('Goodbye');
                   };
                   ws.onclose = (event) => {
                     resolve(opened && ws.readyState === WebSocket.CLOSED && event.wasClean === true);
                   };
                   ws.onerror = () => reject(new Error('unexpected error'));
                 });
                 """,
                 timeout: 5000
               )
    end
  end

  describe "WPT WebSocket binary sending" do
    test "ArrayBuffer echoes as ArrayBuffer when binaryType is arraybuffer", %{
      rt: rt,
      ws_echo_url: ws_echo_url
    } do
      assert {:ok, true} =
               QuickBEAM.eval(
                 rt,
                 """
                 await new Promise((resolve, reject) => {
                   const ws = new WebSocket(#{inspect(ws_echo_url)});
                   ws.binaryType = 'arraybuffer';
                   ws.onopen = () => {
                     const data = new ArrayBuffer(15);
                     ws.send(data);
                     if (ws.bufferedAmount !== 15) {
                       reject(new Error(`expected bufferedAmount 15, got ${ws.bufferedAmount}`));
                     }
                   };
                   ws.onmessage = (event) => {
                     const ok = event.data instanceof ArrayBuffer && event.data.byteLength === 15;
                     ws.close();
                     resolve(ok);
                   };
                   ws.onerror = () => reject(new Error('unexpected error'));
                 });
                 """,
                 timeout: 5000
               )
    end

    test "Blob echoes as Blob by default", %{rt: rt, ws_echo_url: ws_echo_url} do
      assert {:ok, true} =
               QuickBEAM.eval(
                 rt,
                 """
                 await new Promise((resolve, reject) => {
                   const ws = new WebSocket(#{inspect(ws_echo_url)});
                   ws.onopen = () => {
                     const data = new Blob([new Uint8Array(65000)]);
                     ws.send(data);
                   };
                   ws.onmessage = (event) => {
                     const ok = event.data instanceof Blob && event.data.size === 65000;
                     ws.close();
                     resolve(ok);
                   };
                   ws.onerror = () => reject(new Error('unexpected error'));
                 });
                 """,
                 timeout: 5000
               )
    end
  end

  describe "Context integration" do
    test "WebSocket works in contexts", %{pool: pool, ws_echo_url: ws_echo_url} do
      {:ok, ctx} = QuickBEAM.Context.start_link(pool: pool)

      on_exit(fn ->
        try do
          QuickBEAM.Context.stop(ctx)
        catch
          :exit, _ -> :ok
        end
      end)

      assert {:ok, "context"} =
               QuickBEAM.Context.eval(
                 ctx,
                 """
                 await new Promise((resolve, reject) => {
                   const ws = new WebSocket(#{inspect(ws_echo_url)});
                   ws.onopen = () => ws.send('context');
                   ws.onmessage = (event) => {
                     ws.close();
                     resolve(event.data);
                   };
                   ws.onerror = () => reject(new Error('unexpected error'));
                 });
                 """,
                 timeout: 5000
               )
    end
  end

  defp negotiated_protocol(header) do
    header
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.find(&(&1 == "echo"))
  end
end
