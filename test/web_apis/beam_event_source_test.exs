defmodule QuickBEAM.WebAPIs.BeamEventSourceTest do
  use ExUnit.Case, async: false
  use Plug.Router

  plug(:match)
  plug(:dispatch)

  get "/sse" do
    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> send_chunked(200)

    {:ok, conn} = chunk(conn, "data: hello\n\n")
    {:ok, conn} = chunk(conn, "data: world\n\n")
    {:ok, conn} = chunk(conn, "event: custom\ndata: payload\n\n")
    conn
  end

  get "/sse-with-id" do
    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> send_chunked(200)

    {:ok, conn} = chunk(conn, "id: 42\ndata: identified\n\n")
    conn
  end

  setup_all do
    {:ok, server} = Bandit.start_link(plug: __MODULE__, port: 0, ip: :loopback)
    {:ok, {_addr, port}} = ThousandIsland.listener_info(server)
    %{base_url: "http://127.0.0.1:#{port}"}
  end

  setup do
    QuickBEAM.VM.Heap.reset()
    {:ok, rt} = QuickBEAM.start(mode: :beam)

    on_exit(fn ->
      try do
        QuickBEAM.stop(rt)
      catch
        :exit, _ -> :ok
      end
    end)

    {:ok, rt: rt}
  end

  test "receives SSE messages", %{rt: rt, base_url: base_url} do
    assert {:ok, ["hello", "world"]} =
             QuickBEAM.eval(
               rt,
               """
               await new Promise((resolve) => {
                 const messages = [];
                 const es = new EventSource("#{base_url}/sse");
                 es.onmessage = (e) => {
                   messages.push(e.data);
                   if (messages.length === 2) {
                     es.close();
                     resolve(messages);
                   }
                 };
               })
               """,
               timeout: 5000
             )
  end

  test "receives custom event types", %{rt: rt, base_url: base_url} do
    assert {:ok, "payload"} =
             QuickBEAM.eval(
               rt,
               """
               await new Promise((resolve) => {
                 const es = new EventSource("#{base_url}/sse");
                 es.addEventListener("custom", (e) => {
                   es.close();
                   resolve(e.data);
                 });
               })
               """,
               timeout: 5000
             )
  end

  test "lastEventId is set", %{rt: rt, base_url: base_url} do
    assert {:ok, "42"} =
             QuickBEAM.eval(
               rt,
               """
               await new Promise((resolve) => {
                 const es = new EventSource("#{base_url}/sse-with-id");
                 es.onmessage = (e) => {
                   es.close();
                   resolve(e.lastEventId);
                 };
               })
               """,
               timeout: 5000
             )
  end

  test "readyState transitions", %{rt: rt, base_url: base_url} do
    assert {:ok, states} =
             QuickBEAM.eval(
               rt,
               """
               await new Promise((resolve) => {
                 const states = [];
                 const es = new EventSource("#{base_url}/sse");
                 states.push(es.readyState);
                 es.onopen = () => states.push(es.readyState);
                 es.onmessage = () => {
                   states.push(es.readyState);
                   es.close();
                   states.push(es.readyState);
                   resolve(states);
                 };
               })
               """,
               timeout: 5000
             )

    assert hd(states) == 0
    assert List.last(states) == 2
  end
end
