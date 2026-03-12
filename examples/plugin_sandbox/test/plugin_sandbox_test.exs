defmodule PluginSandboxTest do
  use ExUnit.Case

  setup do
    start_supervised!(PluginSandbox)
    :ok
  end

  test "pure computation plugin (no capabilities)" do
    :ok =
      PluginSandbox.load_plugin(:math, """
        function add(a, b) { return a + b }
        function factorial(n) { return n <= 1 ? 1 : n * factorial(n - 1) }
      """)

    assert {:ok, 7} = PluginSandbox.call_plugin(:math, "add", [3, 4])
    assert {:ok, 120} = PluginSandbox.call_plugin(:math, "factorial", [5])
  end

  test "kv capability provides per-plugin storage" do
    :ok =
      PluginSandbox.load_plugin(:store, """
        async function set(k, v) { await Beam.call("kv.set", k, v) }
        async function get(k) { return await Beam.call("kv.get", k) }
        async function keys() { return await Beam.call("kv.keys") }
      """, [:kv])

    PluginSandbox.call_plugin(:store, "set", ["name", "QuickBEAM"])
    assert {:ok, "QuickBEAM"} = PluginSandbox.call_plugin(:store, "get", ["name"])
    assert {:ok, ["name"]} = PluginSandbox.call_plugin(:store, "keys")
  end

  test "plugins are isolated from each other" do
    :ok =
      PluginSandbox.load_plugin(:a, """
        globalThis.secret = 42
        function get() { return globalThis.secret }
      """)

    :ok =
      PluginSandbox.load_plugin(:b, """
        function get() { return globalThis.secret }
      """)

    assert {:ok, 42} = PluginSandbox.call_plugin(:a, "get")
    assert {:ok, nil} = PluginSandbox.call_plugin(:b, "get")
  end

  test "memory limit kills runaway allocations" do
    :ok =
      PluginSandbox.load_plugin(:hog, """
        function hog() {
          const arr = []
          while (true) arr.push("x".repeat(1024))
        }
      """, [], memory_limit: 2 * 1024 * 1024)

    assert {:error, %{message: "out of memory"}} = PluginSandbox.call_plugin(:hog, "hog")
  end

  test "execution timeout stops infinite loops" do
    :ok =
      PluginSandbox.load_plugin(:looper, """
        function loop() { while (true) {} }
      """)

    assert {:error, %{message: "interrupted"}} =
             PluginSandbox.call_plugin(:looper, "loop", [], timeout: 500)
  end

  test "plugin without http capability has no fetch" do
    :ok =
      PluginSandbox.load_plugin(:nofetch, """
        function check() { return typeof fetch }
      """)

    assert {:ok, "undefined"} = PluginSandbox.call_plugin(:nofetch, "check")
  end

  test "plugin with http capability has fetch" do
    :ok =
      PluginSandbox.load_plugin(:withfetch, """
        function check() { return typeof fetch }
      """, [:http])

    assert {:ok, "function"} = PluginSandbox.call_plugin(:withfetch, "check")
  end

  test "unload removes plugin" do
    :ok = PluginSandbox.load_plugin(:temp, "function hi() { return 'hello' }")
    assert {:ok, "hello"} = PluginSandbox.call_plugin(:temp, "hi")

    :ok = PluginSandbox.unload_plugin(:temp)
    assert {:error, :not_found} = PluginSandbox.unload_plugin(:temp)
  end

  test "list_plugins returns all loaded IDs" do
    :ok = PluginSandbox.load_plugin(:p1, "")
    :ok = PluginSandbox.load_plugin(:p2, "")

    plugins = PluginSandbox.list_plugins()
    assert :p1 in plugins
    assert :p2 in plugins
  end

  test "duplicate load returns error" do
    :ok = PluginSandbox.load_plugin(:dup, "")
    assert {:error, :already_loaded} = PluginSandbox.load_plugin(:dup, "")
  end
end
