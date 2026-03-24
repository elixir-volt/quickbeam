defmodule QuickBEAM.NapiTest do
  use ExUnit.Case, async: true

  @test_addon Path.expand("support/test_addon.node", __DIR__)
  @node_modules Path.expand("../node_modules", __DIR__)

  defp napi_target do
    arch_str = :erlang.system_info(:system_architecture) |> to_string()
    arch = if String.contains?(arch_str, "aarch64"), do: "arm64", else: "x64"

    platform =
      case :os.type() do
        {:unix, :darwin} -> "darwin"
        {:unix, :linux} -> "linux"
        {:win32, _} -> "win32"
        _ -> "linux"
      end

    {platform, arch}
  end

  defp addon_path(name) do
    {platform, arch} = napi_target()
    target = "#{platform}-#{arch}"
    basename = name |> String.split("/") |> List.last()
    Path.join([@node_modules, "#{name}-#{target}", "#{basename}.#{target}.node"])
  end

  defp sqlite_path do
    {platform, arch} = napi_target()
    suffix = if platform == "linux", do: "-gnu", else: ""
    Path.join(@node_modules, "sqlite-napi/sqlite-napi.#{platform}-#{arch}#{suffix}.node")
  end

  describe "test addon" do
    test "load and inspect exports" do
      {:ok, rt} = QuickBEAM.start()
      {:ok, exports} = QuickBEAM.load_addon(rt, @test_addon, as: "addon")
      assert Map.has_key?(exports, "hello")
      assert Map.has_key?(exports, "add")
      assert Map.has_key?(exports, "concat")
      assert Map.has_key?(exports, "createObject")
      assert Map.has_key?(exports, "getType")
      assert Map.has_key?(exports, "makeArray")
      assert exports["version"] == 42
      QuickBEAM.stop(rt)
    end

    test "call string function" do
      {:ok, rt} = QuickBEAM.start()
      {:ok, _} = QuickBEAM.load_addon(rt, @test_addon, as: "addon")
      assert {:ok, "hello from napi"} = QuickBEAM.eval(rt, "addon.hello()")
      QuickBEAM.stop(rt)
    end

    test "call numeric function" do
      {:ok, rt} = QuickBEAM.start()
      {:ok, _} = QuickBEAM.load_addon(rt, @test_addon, as: "addon")
      assert {:ok, 7} = QuickBEAM.eval(rt, "addon.add(3, 4)")
      assert {:ok, 0} = QuickBEAM.eval(rt, "addon.add(-5, 5)")
      assert {:ok, result} = QuickBEAM.eval(rt, "addon.add(1.5, 2.5)")
      assert result == 4.0
      QuickBEAM.stop(rt)
    end

    test "call string concatenation" do
      {:ok, rt} = QuickBEAM.start()
      {:ok, _} = QuickBEAM.load_addon(rt, @test_addon, as: "addon")
      assert {:ok, "foobar"} = QuickBEAM.eval(rt, ~s[addon.concat("foo", "bar")])
      assert {:ok, ""} = QuickBEAM.eval(rt, ~s[addon.concat("", "")])
      QuickBEAM.stop(rt)
    end

    test "call typeof checker" do
      {:ok, rt} = QuickBEAM.start()
      {:ok, _} = QuickBEAM.load_addon(rt, @test_addon, as: "addon")
      assert {:ok, "number"} = QuickBEAM.eval(rt, "addon.getType(42)")
      assert {:ok, "string"} = QuickBEAM.eval(rt, ~s[addon.getType("hi")])
      assert {:ok, "boolean"} = QuickBEAM.eval(rt, "addon.getType(true)")
      assert {:ok, "null"} = QuickBEAM.eval(rt, "addon.getType(null)")
      assert {:ok, "undefined"} = QuickBEAM.eval(rt, "addon.getType(undefined)")
      assert {:ok, "object"} = QuickBEAM.eval(rt, "addon.getType({})")
      assert {:ok, "function"} = QuickBEAM.eval(rt, "addon.getType(() => {})")
      QuickBEAM.stop(rt)
    end

    test "call object creator" do
      {:ok, rt} = QuickBEAM.start()
      {:ok, _} = QuickBEAM.load_addon(rt, @test_addon, as: "addon")

      assert {:ok, %{"key" => "name", "value" => "QuickBEAM"}} =
               QuickBEAM.eval(rt, ~s[addon.createObject("name", "QuickBEAM")])

      QuickBEAM.stop(rt)
    end

    test "call array creator" do
      {:ok, rt} = QuickBEAM.start()
      {:ok, _} = QuickBEAM.load_addon(rt, @test_addon, as: "addon")
      assert {:ok, [10, 20, 30]} = QuickBEAM.eval(rt, "addon.makeArray(10, 20, 30)")
      QuickBEAM.stop(rt)
    end

    test "access scalar export" do
      {:ok, rt} = QuickBEAM.start()
      {:ok, _} = QuickBEAM.load_addon(rt, @test_addon, as: "addon")
      assert {:ok, 42} = QuickBEAM.eval(rt, "addon.version")
      QuickBEAM.stop(rt)
    end

    test "buffers are exposed as Uint8Array and buffer info reads bytes" do
      {:ok, rt} = QuickBEAM.start()
      {:ok, _} = QuickBEAM.load_addon(rt, @test_addon, as: "addon")
      assert {:ok, "Uint8Array"} = QuickBEAM.eval(rt, "addon.bufferKind()")
      assert {:ok, [10, 20, 30, 40]} = QuickBEAM.eval(rt, "addon.bufferInfo()")

      assert {:ok, %{"isBuffer" => true, "isTypedArray" => true}} =
               QuickBEAM.eval(rt, "addon.typedarrayChecks()")

      QuickBEAM.stop(rt)
    end

    test "coerce to object preserves JS wrapper semantics" do
      {:ok, rt} = QuickBEAM.start()
      {:ok, _} = QuickBEAM.load_addon(rt, @test_addon, as: "addon")
      assert {:ok, "String"} = QuickBEAM.eval(rt, ~s[addon.coerceObjectType("hello")])
      assert {:ok, "Number"} = QuickBEAM.eval(rt, "addon.coerceObjectType(123)")
      QuickBEAM.stop(rt)
    end

    test "wrap and unwrap round-trip native pointer" do
      {:ok, rt} = QuickBEAM.start()
      {:ok, _} = QuickBEAM.load_addon(rt, @test_addon, as: "addon")
      assert {:ok, 1234} = QuickBEAM.eval(rt, "addon.wrapAndUnwrap()")
      assert {:ok, 5678} = QuickBEAM.eval(rt, "addon.removeWrapValue()")
      QuickBEAM.stop(rt)
    end

    test "reset remains stable after wrapped objects and external buffers" do
      {:ok, rt} = QuickBEAM.start()
      {:ok, _} = QuickBEAM.load_addon(rt, @test_addon, as: "addon")

      assert {:ok, %{"wraps" => _wraps_before, "externalBuffers" => _buffers_before}} =
               QuickBEAM.eval(rt, "addon.finalizedCounts()")

      assert {:ok, 1234} = QuickBEAM.eval(rt, "addon.wrapAndUnwrap()")
      assert {:ok, 1} = QuickBEAM.eval(rt, "addon.clearWrapKeepalive()")

      assert {:ok, [7, 8, 9, 10]} =
               QuickBEAM.eval(rt, "Array.from(addon.addExternalBufferFinalizer())")

      assert {:ok, 1} = QuickBEAM.eval(rt, "addon.clearExternalBufferKeepalive()")

      assert :ok = QuickBEAM.reset(rt)
      {:ok, _} = QuickBEAM.load_addon(rt, @test_addon, as: "addon")

      assert {:ok, %{"wraps" => _wraps_after, "externalBuffers" => _buffers_after}} =
               QuickBEAM.eval(rt, "addon.finalizedCounts()")

      QuickBEAM.stop(rt)
    end
  end

  describe "error handling" do
    test "invalid path" do
      {:ok, rt} = QuickBEAM.start()
      assert {:error, _} = QuickBEAM.load_addon(rt, "/nonexistent/addon.node")
      QuickBEAM.stop(rt)
    end

    test "runtime remains functional after failed load" do
      {:ok, rt} = QuickBEAM.start()
      {:error, _} = QuickBEAM.load_addon(rt, "/nonexistent/addon.node")
      assert {:ok, 42} = QuickBEAM.eval(rt, "42")
      QuickBEAM.stop(rt)
    end

    test "multiple addon loads" do
      {:ok, rt} = QuickBEAM.start()
      {:ok, _} = QuickBEAM.load_addon(rt, @test_addon, as: "a")
      {:ok, _} = QuickBEAM.load_addon(rt, @test_addon, as: "b")
      assert {:ok, "hello from napi"} = QuickBEAM.eval(rt, "a.hello()")
      assert {:ok, "hello from napi"} = QuickBEAM.eval(rt, "b.hello()")
      QuickBEAM.stop(rt)
    end
  end

  describe "@node-rs/crc32" do
    @describetag :napi_addon

    test "load and export functions" do
      path = addon_path("@node-rs/crc32")
      if !File.exists?(path), do: flunk("addon not found at #{path} — run mix npm.install")

      {:ok, rt} = QuickBEAM.start()
      {:ok, exports} = QuickBEAM.load_addon(rt, path, as: "crc32mod")
      assert Map.has_key?(exports, "crc32")
      assert Map.has_key?(exports, "crc32c")
      QuickBEAM.stop(rt)
    end

    test "compute crc32 of a string" do
      path = addon_path("@node-rs/crc32")
      if !File.exists?(path), do: flunk("addon not found at #{path} — run mix npm.install")

      {:ok, rt} = QuickBEAM.start()
      {:ok, _} = QuickBEAM.load_addon(rt, path, as: "crc32mod")
      assert {:ok, 907_060_870} = QuickBEAM.eval(rt, ~s[crc32mod.crc32("hello")])
      QuickBEAM.stop(rt)
    end

    test "crc32c" do
      path = addon_path("@node-rs/crc32")
      if !File.exists?(path), do: flunk("addon not found at #{path} — run mix npm.install")

      {:ok, rt} = QuickBEAM.start()
      {:ok, _} = QuickBEAM.load_addon(rt, path, as: "crc32mod")
      assert {:ok, result} = QuickBEAM.eval(rt, ~s[crc32mod.crc32c("hello")])
      assert is_integer(result) and result > 0
      QuickBEAM.stop(rt)
    end

    test "crc32 of empty string" do
      path = addon_path("@node-rs/crc32")
      if !File.exists?(path), do: flunk("addon not found at #{path} — run mix npm.install")

      {:ok, rt} = QuickBEAM.start()
      {:ok, _} = QuickBEAM.load_addon(rt, path, as: "crc32mod")
      assert {:ok, 0} = QuickBEAM.eval(rt, ~s[crc32mod.crc32("")])
      QuickBEAM.stop(rt)
    end
  end

  describe "@node-rs/argon2" do
    @describetag :napi_addon

    test "load and export functions" do
      path = addon_path("@node-rs/argon2")
      if !File.exists?(path), do: flunk("addon not found at #{path} — run mix npm.install")

      {:ok, rt} = QuickBEAM.start()
      {:ok, exports} = QuickBEAM.load_addon(rt, path, as: "argon2")
      assert Map.has_key?(exports, "hashSync")
      assert Map.has_key?(exports, "verifySync")
      assert exports["Algorithm"] == %{"Argon2d" => 0, "Argon2i" => 1, "Argon2id" => 2}
      QuickBEAM.stop(rt)
    end

    test "hash and verify password" do
      path = addon_path("@node-rs/argon2")
      if !File.exists?(path), do: flunk("addon not found at #{path} — run mix npm.install")

      {:ok, rt} = QuickBEAM.start()
      {:ok, _} = QuickBEAM.load_addon(rt, path, as: "argon2")

      {:ok, hash} = QuickBEAM.eval(rt, ~s[argon2.hashSync("password123")])
      assert String.starts_with?(hash, "$argon2")

      {:ok, true} = QuickBEAM.eval(rt, ~s[argon2.verifySync("#{hash}", "password123")])
      {:ok, false} = QuickBEAM.eval(rt, ~s[argon2.verifySync("#{hash}", "wrong")])

      QuickBEAM.stop(rt)
    end
  end

  describe "@node-rs/bcrypt" do
    @describetag :napi_addon

    test "load and export functions" do
      path = addon_path("@node-rs/bcrypt")
      if !File.exists?(path), do: flunk("addon not found at #{path} — run mix npm.install")

      {:ok, rt} = QuickBEAM.start()
      {:ok, exports} = QuickBEAM.load_addon(rt, path, as: "bcrypt")
      assert Map.has_key?(exports, "hashSync")
      assert Map.has_key?(exports, "verifySync")
      assert exports["DEFAULT_COST"] == 12
      QuickBEAM.stop(rt)
    end

    test "hash and verify password" do
      path = addon_path("@node-rs/bcrypt")
      if !File.exists?(path), do: flunk("addon not found at #{path} — run mix npm.install")

      {:ok, rt} = QuickBEAM.start()
      {:ok, _} = QuickBEAM.load_addon(rt, path, as: "bcrypt")

      {:ok, hash} = QuickBEAM.eval(rt, ~s[bcrypt.hashSync("password123", 4)])
      assert String.starts_with?(hash, "$2")

      {:ok, true} = QuickBEAM.eval(rt, ~s[bcrypt.verifySync("password123", "#{hash}")])
      {:ok, false} = QuickBEAM.eval(rt, ~s[bcrypt.verifySync("wrong", "#{hash}")])

      QuickBEAM.stop(rt)
    end

    test "generate salt" do
      path = addon_path("@node-rs/bcrypt")
      if !File.exists?(path), do: flunk("addon not found at #{path} — run mix npm.install")

      {:ok, rt} = QuickBEAM.start()
      {:ok, _} = QuickBEAM.load_addon(rt, path, as: "bcrypt")
      {:ok, salt} = QuickBEAM.eval(rt, "bcrypt.genSaltSync(4)")
      assert String.starts_with?(salt, "$2b$04$")
      QuickBEAM.stop(rt)
    end
  end

  describe "sqlite-napi" do
    @describetag :napi_sqlite

    test "create database and execute SQL" do
      path = sqlite_path()
      if !File.exists?(path), do: flunk("addon not found at #{path} — run mix npm.install")

      {:ok, rt} = QuickBEAM.start()
      {:ok, _} = QuickBEAM.load_addon(rt, path, as: "sqlite")

      assert {:ok, "ok"} =
               QuickBEAM.eval(rt, """
                 const db = new sqlite.Database(":memory:");
                 db.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)");
                 db.exec("INSERT INTO t VALUES (1, 'hello')");
                 db.exec("INSERT INTO t VALUES (2, 'world')");
                 "ok"
               """)

      QuickBEAM.stop(rt)
    end

    test "parameterized insert with db.run" do
      path = sqlite_path()
      if !File.exists?(path), do: flunk("addon not found at #{path} — run mix npm.install")

      {:ok, rt} = QuickBEAM.start()
      {:ok, _} = QuickBEAM.load_addon(rt, path, as: "sqlite")

      assert {:ok, "ok"} =
               QuickBEAM.eval(rt, """
                 const db = new sqlite.Database(":memory:");
                 db.exec("CREATE TABLE kv (key TEXT, val TEXT)");
                 db.run("INSERT INTO kv VALUES (?, ?)", "greeting", "hello");
                 db.run("INSERT INTO kv VALUES (?, ?)", "target", "world");
                 "ok"
               """)

      QuickBEAM.stop(rt)
    end
  end
end
