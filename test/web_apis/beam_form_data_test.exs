defmodule QuickBEAM.WebAPIs.BeamFormDataTest do
  @moduledoc "Merged from WPT: xhr/formdata + fetch integration tests"
  use ExUnit.Case, async: false
  use Plug.Router

  plug(:match)
  plug(:dispatch)

  post "/echo" do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    ct = Plug.Conn.get_req_header(conn, "content-type") |> List.first("")

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, "CT: #{ct}\n---\n#{body}")
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
    QuickBEAM.VM.Heap.reset()
    {:ok, rt} = QuickBEAM.start(mode: :beam)

    on_exit(fn ->
      try do
        QuickBEAM.stop(rt)
      catch
        :exit, _ -> :ok
      end
    end)

    %{rt: rt}
  end

  describe "FormData constructor" do
    test "creates empty FormData", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const fd = new FormData();
               fd.constructor.name === 'FormData'
               """)
    end
  end

  describe "append and get" do
    test "string value", %{rt: rt} do
      {:ok, "bar"} =
        QuickBEAM.eval(rt, """
          const fd = new FormData();
          fd.append("foo", "bar");
          fd.get("foo")
        """)
    end

    test "returns null for missing key", %{rt: rt} do
      {:ok, nil} =
        QuickBEAM.eval(rt, """
          const fd = new FormData();
          fd.get("missing")
        """)
    end

    test "returns first value for duplicate keys", %{rt: rt} do
      {:ok, "first"} =
        QuickBEAM.eval(rt, """
          const fd = new FormData();
          fd.append("key", "first");
          fd.append("key", "second");
          fd.get("key")
        """)
    end

    test "append adds entry, get retrieves it", %{rt: rt} do
      assert {:ok, "value"} =
               QuickBEAM.eval(rt, """
               const fd = new FormData();
               fd.append("key", "value");
               fd.get("key")
               """)
    end

    test "get returns null for missing key", %{rt: rt} do
      assert {:ok, nil} =
               QuickBEAM.eval(rt, """
               const fd = new FormData();
               fd.get("missing")
               """)
    end

    test "multiple append same key preserves all", %{rt: rt} do
      assert {:ok, "first"} =
               QuickBEAM.eval(rt, """
               const fd = new FormData();
               fd.append("key", "first");
               fd.append("key", "second");
               fd.get("key")
               """)
    end

    test "returns all values for key", %{rt: rt} do
      {:ok, ["a", "b", "c"]} =
        QuickBEAM.eval(rt, """
          const fd = new FormData();
          fd.append("x", "a");
          fd.append("x", "b");
          fd.append("x", "c");
          fd.getAll("x")
        """)
    end

    test "returns empty array for missing key", %{rt: rt} do
      {:ok, []} =
        QuickBEAM.eval(rt, """
          new FormData().getAll("nope")
        """)
    end

    test "getAll returns all values for a key", %{rt: rt} do
      assert {:ok, ["first", "second", "third"]} =
               QuickBEAM.eval(rt, """
               const fd = new FormData();
               fd.append("key", "first");
               fd.append("key", "second");
               fd.append("key", "third");
               fd.getAll("key")
               """)
    end

    test "getAll returns empty array for missing key", %{rt: rt} do
      assert {:ok, []} =
               QuickBEAM.eval(rt, """
               const fd = new FormData();
               fd.getAll("missing")
               """)
    end
  end

  describe "set" do
    test "replaces existing entries", %{rt: rt} do
      {:ok, result} =
        QuickBEAM.eval(rt, """
          const fd = new FormData();
          fd.append("key", "old1");
          fd.append("key", "old2");
          fd.set("key", "new");
          fd.getAll("key")
        """)

      assert result == ["new"]
    end

    test "adds entry when key does not exist", %{rt: rt} do
      {:ok, "val"} =
        QuickBEAM.eval(rt, """
          const fd = new FormData();
          fd.set("key", "val");
          fd.get("key")
        """)
    end

    test "set replaces existing entries", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const fd = new FormData();
               fd.append("key", "first");
               fd.append("key", "second");
               fd.set("key", "replaced");
               const all = fd.getAll("key");
               all.length === 1 && all[0] === "replaced"
               """)
    end

    test "set adds if key does not exist", %{rt: rt} do
      assert {:ok, "new"} =
               QuickBEAM.eval(rt, """
               const fd = new FormData();
               fd.set("key", "new");
               fd.get("key")
               """)
    end
  end

  describe "delete" do
    test "removes all entries with name", %{rt: rt} do
      {:ok, result} =
        QuickBEAM.eval(rt, """
          const fd = new FormData();
          fd.append("a", "1");
          fd.append("a", "2");
          fd.append("b", "3");
          fd.delete("a");
          ({ has: fd.has("a"), b: fd.get("b") })
        """)

      assert result == %{"has" => false, "b" => "3"}
    end

    test "delete removes all entries with key", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const fd = new FormData();
               fd.append("key", "a");
               fd.append("key", "b");
               fd.append("other", "c");
               fd.delete("key");
               fd.has("key") === false && fd.has("other") === true
               """)
    end
  end

  describe "has" do
    test "returns true when key exists", %{rt: rt} do
      {:ok, true} =
        QuickBEAM.eval(rt, """
          const fd = new FormData();
          fd.append("key", "val");
          fd.has("key")
        """)
    end

    test "returns false when key missing", %{rt: rt} do
      {:ok, false} =
        QuickBEAM.eval(rt, """
          new FormData().has("key")
        """)
    end

    test "has returns true for existing key", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const fd = new FormData();
               fd.append("key", "value");
               fd.has("key")
               """)
    end

    test "has returns false for missing key", %{rt: rt} do
      assert {:ok, false} =
               QuickBEAM.eval(rt, """
               const fd = new FormData();
               fd.has("missing")
               """)
    end
  end

  describe "Blob and File handling" do
    test "appending Blob wraps in File with name 'blob'", %{rt: rt} do
      {:ok, result} =
        QuickBEAM.eval(rt, """
          const fd = new FormData();
          fd.append("file", new Blob(["data"], { type: "text/plain" }));
          const f = fd.get("file");
          ({ isFile: f instanceof File, name: f.name, type: f.type, text: await f.text() })
        """)

      assert result == %{
               "isFile" => true,
               "name" => "blob",
               "type" => "text/plain",
               "text" => "data"
             }
    end

    test "appending Blob with filename", %{rt: rt} do
      {:ok, "custom.txt"} =
        QuickBEAM.eval(rt, """
          const fd = new FormData();
          fd.append("file", new Blob(["x"]), "custom.txt");
          fd.get("file").name
        """)
    end

    test "appending File preserves name", %{rt: rt} do
      {:ok, "test.txt"} =
        QuickBEAM.eval(rt, """
          const fd = new FormData();
          fd.append("file", new File(["content"], "test.txt"));
          fd.get("file").name
        """)
    end

    test "appending File with override filename", %{rt: rt} do
      {:ok, "override.txt"} =
        QuickBEAM.eval(rt, """
          const fd = new FormData();
          fd.append("file", new File(["content"], "original.txt"), "override.txt");
          fd.get("file").name
        """)
    end

    test "Blob value wrapped in File with name 'blob'", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const fd = new FormData();
               fd.append("file", new Blob(["data"], { type: "text/plain" }));
               const val = fd.get("file");
               val instanceof File && val.name === "blob" && val.type === "text/plain"
               """)
    end

    test "Blob value text content is preserved", %{rt: rt} do
      {:ok, result} =
        QuickBEAM.eval(rt, """
          const fd = new FormData();
          fd.append("file", new Blob(["data"], { type: "text/plain" }));
          const f = fd.get("file");
          ({ isFile: f instanceof File, name: f.name, type: f.type, text: await f.text() })
        """)

      assert result == %{
               "isFile" => true,
               "name" => "blob",
               "type" => "text/plain",
               "text" => "data"
             }
    end

    test "File values preserve original name", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const fd = new FormData();
               fd.append("file", new File(["data"], "test.txt", { type: "text/plain" }));
               const val = fd.get("file");
               val instanceof File && val.name === "test.txt"
               """)
    end

    test "custom filename overrides Blob default", %{rt: rt} do
      assert {:ok, "custom.txt"} =
               QuickBEAM.eval(rt, """
               const fd = new FormData();
               fd.append("file", new Blob(["data"]), "custom.txt");
               fd.get("file").name
               """)
    end

    test "custom filename overrides File name", %{rt: rt} do
      assert {:ok, "override.txt"} =
               QuickBEAM.eval(rt, """
               const fd = new FormData();
               fd.append("file", new File(["data"], "original.txt"), "override.txt");
               fd.get("file").name
               """)
    end
  end

  describe "iteration" do
    test "entries", %{rt: rt} do
      {:ok, result} =
        QuickBEAM.eval(rt, """
          const fd = new FormData();
          fd.append("a", "1");
          fd.append("b", "2");
          [...fd.entries()].map(([k, v]) => k + "=" + v)
        """)

      assert result == ["a=1", "b=2"]
    end

    test "keys", %{rt: rt} do
      {:ok, ["a", "b"]} =
        QuickBEAM.eval(rt, """
          const fd = new FormData();
          fd.append("a", "1");
          fd.append("b", "2");
          [...fd.keys()]
        """)
    end

    test "values", %{rt: rt} do
      {:ok, ["1", "2"]} =
        QuickBEAM.eval(rt, """
          const fd = new FormData();
          fd.append("a", "1");
          fd.append("b", "2");
          [...fd.values()]
        """)
    end

    test "Symbol.iterator", %{rt: rt} do
      {:ok, result} =
        QuickBEAM.eval(rt, """
          const fd = new FormData();
          fd.append("x", "y");
          [...fd].map(([k, v]) => k + ":" + v)
        """)

      assert result == ["x:y"]
    end

    test "forEach", %{rt: rt} do
      {:ok, ["a=1", "b=2"]} =
        QuickBEAM.eval(rt, """
          const fd = new FormData();
          fd.append("a", "1");
          fd.append("b", "2");
          const items = [];
          fd.forEach((v, k) => items.push(k + "=" + v));
          items
        """)
    end

    test "forEach works correctly", %{rt: rt} do
      assert {:ok, "a=1,b=2,c=3"} =
               QuickBEAM.eval(rt, """
               const fd = new FormData();
               fd.append("a", "1");
               fd.append("b", "2");
               fd.append("c", "3");
               const pairs = [];
               fd.forEach((value, name) => pairs.push(name + "=" + value));
               pairs.join(",")
               """)
    end

    test "iteration order matches insertion order", %{rt: rt} do
      assert {:ok, "first,second,third"} =
               QuickBEAM.eval(rt, """
               const fd = new FormData();
               fd.append("first", "1");
               fd.append("second", "2");
               fd.append("third", "3");
               const keys = [];
               for (const [key] of fd) keys.push(key);
               keys.join(",")
               """)
    end

    test "keys iterator", %{rt: rt} do
      assert {:ok, "a,b,c"} =
               QuickBEAM.eval(rt, """
               const fd = new FormData();
               fd.append("a", "1");
               fd.append("b", "2");
               fd.append("c", "3");
               [...fd.keys()].join(",")
               """)
    end

    test "values iterator", %{rt: rt} do
      assert {:ok, "1,2,3"} =
               QuickBEAM.eval(rt, """
               const fd = new FormData();
               fd.append("a", "1");
               fd.append("b", "2");
               fd.append("c", "3");
               [...fd.values()].join(",")
               """)
    end

    test "entries iterator", %{rt: rt} do
      assert {:ok, "a:1,b:2"} =
               QuickBEAM.eval(rt, """
               const fd = new FormData();
               fd.append("a", "1");
               fd.append("b", "2");
               const pairs = [];
               for (const [k, v] of fd.entries()) pairs.push(k + ":" + v);
               pairs.join(",")
               """)
    end

    test "Symbol.iterator works", %{rt: rt} do
      assert {:ok, "x:10,y:20"} =
               QuickBEAM.eval(rt, """
               const fd = new FormData();
               fd.append("x", "10");
               fd.append("y", "20");
               const pairs = [];
               for (const [k, v] of fd) pairs.push(k + ":" + v);
               pairs.join(",")
               """)
    end
  end

  describe "fetch integration" do
    test "FormData body sets multipart content type", %{rt: rt, base: base} do
      {:ok, result} =
        QuickBEAM.eval(rt, """
          const fd = new FormData();
          fd.append("field", "value");
          const r = await fetch("#{base}/echo", { method: "POST", body: fd });
          const text = await r.text();
          text.split("\\n")[0]
        """)

      assert result =~ "multipart/form-data; boundary="
    end

    test "FormData body encodes string entries", %{rt: rt, base: base} do
      {:ok, result} =
        QuickBEAM.eval(rt, """
          const fd = new FormData();
          fd.append("name", "alice");
          fd.append("age", "30");
          const r = await fetch("#{base}/echo", { method: "POST", body: fd });
          const text = await r.text();
          text.includes('name="name"') && text.includes("alice") &&
          text.includes('name="age"') && text.includes("30")
        """)

      assert result == true
    end

    test "FormData body encodes file entries", %{rt: rt, base: base} do
      {:ok, result} =
        QuickBEAM.eval(rt, """
          const fd = new FormData();
          fd.append("doc", new File(["hello"], "doc.txt", { type: "text/plain" }));
          const r = await fetch("#{base}/echo", { method: "POST", body: fd });
          const text = await r.text();
          text.includes('filename="doc.txt"') && text.includes("Content-Type: text/plain") && text.includes("hello")
        """)

      assert result == true
    end
  end
end
