defmodule QuickBEAM.FetchTest do
  use ExUnit.Case, async: false
  use Plug.Router

  @moduletag :fetch

  plug(Plug.Parsers, parsers: [:urlencoded], pass: ["*/*"])
  plug(:match)
  plug(:dispatch)

  get "/hello" do
    send_resp(conn, 200, "Hello!")
  end

  get "/json" do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, ~s|{"name":"beam","version":27}|)
  end

  get "/not-found" do
    send_resp(conn, 404, "Nope")
  end

  get "/headers" do
    conn
    |> put_resp_header("x-custom", "hello")
    |> send_resp(200, "ok")
  end

  get "/bytes" do
    conn
    |> put_resp_content_type("application/octet-stream")
    |> send_resp(200, <<0, 1, 2, 3>>)
  end

  post "/echo" do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    ct = Plug.Conn.get_req_header(conn, "content-type") |> List.first("")

    json = ~s|{"method":"POST","body":#{inspect(body)},"content_type":#{inspect(ct)}}|

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, json)
  end

  put "/echo" do
    {:ok, body, conn} = Plug.Conn.read_body(conn)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, ~s|{"method":"PUT","body":#{inspect(body)}}|)
  end

  delete "/item/:id" do
    send_resp(conn, 204, "")
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  setup_all do
    {:ok, server} = Bandit.start_link(plug: __MODULE__, port: 0, ip: :loopback)
    {:ok, {_addr, port}} = ThousandIsland.listener_info(server)
    %{base: "http://127.0.0.1:#{port}"}
  end

  setup do
    {:ok, rt} = QuickBEAM.start()
    on_exit(fn -> catch_exit(QuickBEAM.stop(rt)) end)
    %{rt: rt}
  end

  describe "basic GET" do
    test "returns status and body", %{rt: rt, base: base} do
      {:ok, result} =
        QuickBEAM.eval(rt, """
          const r = await fetch("#{base}/hello");
          ({ status: r.status, ok: r.ok, body: await r.text() })
        """)

      assert result == %{"status" => 200, "ok" => true, "body" => "Hello!"}
    end

    test "parses JSON response", %{rt: rt, base: base} do
      {:ok, result} =
        QuickBEAM.eval(rt, """
          const r = await fetch("#{base}/json");
          await r.json()
        """)

      assert result == %{"name" => "beam", "version" => 27}
    end

    test "non-200 status", %{rt: rt, base: base} do
      {:ok, result} =
        QuickBEAM.eval(rt, """
          const r = await fetch("#{base}/not-found");
          ({ status: r.status, ok: r.ok })
        """)

      assert result == %{"status" => 404, "ok" => false}
    end

    test "response headers", %{rt: rt, base: base} do
      {:ok, result} =
        QuickBEAM.eval(rt, """
          const r = await fetch("#{base}/headers");
          r.headers.get("x-custom")
        """)

      assert result == "hello"
    end

    test "response as bytes", %{rt: rt, base: base} do
      {:ok, result} =
        QuickBEAM.eval(rt, """
          const r = await fetch("#{base}/bytes");
          Array.from(await r.bytes())
        """)

      assert result == [0, 1, 2, 3]
    end

    test "response as arrayBuffer", %{rt: rt, base: base} do
      {:ok, result} =
        QuickBEAM.eval(rt, """
          const r = await fetch("#{base}/bytes");
          (await r.arrayBuffer()).byteLength
        """)

      assert result == 4
    end
  end

  describe "request methods and body" do
    test "POST with string body", %{rt: rt, base: base} do
      {:ok, result} =
        QuickBEAM.eval(rt, """
          const r = await fetch("#{base}/echo", {
            method: "POST",
            body: "hello world"
          });
          await r.json()
        """)

      assert result["method"] == "POST"
      assert result["body"] == "hello world"
      assert result["content_type"] =~ "text/plain"
    end

    test "POST with JSON body", %{rt: rt, base: base} do
      {:ok, result} =
        QuickBEAM.eval(rt, """
          const r = await fetch("#{base}/echo", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ key: "value" })
          });
          await r.json()
        """)

      assert result["method"] == "POST"
      assert result["body"] == ~s|{"key":"value"}|
      assert result["content_type"] =~ "application/json"
    end

    test "PUT method", %{rt: rt, base: base} do
      {:ok, result} =
        QuickBEAM.eval(rt, """
          const r = await fetch("#{base}/echo", { method: "PUT", body: "data" });
          await r.json()
        """)

      assert result["method"] == "PUT"
      assert result["body"] == "data"
    end

    test "DELETE method", %{rt: rt, base: base} do
      {:ok, result} =
        QuickBEAM.eval(rt, """
          const r = await fetch("#{base}/item/42", { method: "DELETE" });
          r.status
        """)

      assert result == 204
    end
  end

  describe "Request and Response objects" do
    test "Request constructor", %{rt: rt, base: base} do
      {:ok, 200} =
        QuickBEAM.eval(rt, """
          const req = new Request("#{base}/hello");
          (await fetch(req)).status
        """)
    end

    test "Request.clone()", %{rt: rt} do
      {:ok, "POST"} =
        QuickBEAM.eval(rt, """
          new Request("http://example.com", { method: "POST" }).clone().method
        """)
    end

    test "Response.json()", %{rt: rt} do
      {:ok, result} =
        QuickBEAM.eval(rt, """
          const r = Response.json({ hello: "world" });
          ({
            status: r.status,
            type: r.headers.get("content-type"),
            body: await r.json()
          })
        """)

      assert result["status"] == 200
      assert result["type"] == "application/json"
      assert result["body"] == %{"hello" => "world"}
    end

    test "Response.error()", %{rt: rt} do
      {:ok, 0} = QuickBEAM.eval(rt, "Response.error().status")
    end

    test "Response.redirect()", %{rt: rt} do
      {:ok, result} =
        QuickBEAM.eval(rt, """
          const r = Response.redirect("http://example.com", 301);
          ({ status: r.status, location: r.headers.get("location") })
        """)

      assert result == %{"status" => 301, "location" => "http://example.com"}
    end

    test "body consumed once", %{rt: rt} do
      {:ok, result} =
        QuickBEAM.eval(rt, """
          const r = Response.json({ a: 1 });
          await r.text();
          try { await r.text(); "no error" } catch(e) { e.message }
        """)

      assert result =~ "consumed"
    end

    test "clone preserves body", %{rt: rt} do
      {:ok, true} =
        QuickBEAM.eval(rt, """
          const r = Response.json({ a: 1 });
          const r2 = r.clone();
          (await r.text()) === (await r2.text())
        """)
    end
  end

  describe "error handling" do
    test "connection refused" do
      {:ok, rt} = QuickBEAM.start()

      {:error, error} =
        QuickBEAM.eval(rt, """
          await fetch("http://127.0.0.1:1/")
        """)

      assert error.message =~ "fetch failed"
      QuickBEAM.stop(rt)
    end
  end
end
