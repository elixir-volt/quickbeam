defmodule QuickBEAM.WPT.FormDataTest do
  @moduledoc "Ported from WPT: xhr/formdata"
  use ExUnit.Case, async: true

  setup do
    {:ok, rt} = QuickBEAM.start()
    on_exit(fn -> try do QuickBEAM.stop(rt) catch :exit, _ -> :ok end end)
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
    test "Blob value wrapped in File with name 'blob'", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const fd = new FormData();
               fd.append("file", new Blob(["data"], { type: "text/plain" }));
               const val = fd.get("file");
               val instanceof File && val.name === "blob" && val.type === "text/plain"
               """)
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
end
