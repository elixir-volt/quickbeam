defmodule QuickBEAM.NapiTest do
  use ExUnit.Case, async: true

  @test_addon Path.expand("support/test_addon.node", __DIR__)

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

  @napi_addons Path.expand("support/napi_addons/node_modules", __DIR__)

  defp addon_path(name) do
    arch = if :erlang.system_info(:system_architecture) |> to_string() |> String.contains?("aarch64"),
      do: "darwin-arm64",
      else: "darwin-x64"
    Path.join([@napi_addons, name <> "-" <> arch, Path.basename(name) <> "." <> arch <> ".node"])
  end

  defp addon_available?(name), do: File.exists?(addon_path(name))

  defp sqlite_napi_path do
    arch = if :erlang.system_info(:system_architecture) |> to_string() |> String.contains?("aarch64"),
      do: "darwin-arm64",
      else: "darwin-x64"
    Path.join([@napi_addons, "sqlite-napi", "sqlite-napi.#{arch}.node"])
  end

  describe "@node-rs/crc32" do
    @describetag :napi_addon

    setup do
      if addon_available?("@node-rs/crc32"), do: :ok, else: :skip
    end

    test "load and export functions" do
      {:ok, rt} = QuickBEAM.start()
      {:ok, exports} = QuickBEAM.load_addon(rt, addon_path("@node-rs/crc32"), as: "crc32mod")
      assert Map.has_key?(exports, "crc32")
      assert Map.has_key?(exports, "crc32c")
      QuickBEAM.stop(rt)
    end

    test "compute crc32 of a string" do
      {:ok, rt} = QuickBEAM.start()
      {:ok, _} = QuickBEAM.load_addon(rt, addon_path("@node-rs/crc32"), as: "crc32mod")
      assert {:ok, result} = QuickBEAM.eval(rt, ~s[crc32mod.crc32("hello")])
      assert is_integer(result)
      assert result == 907_060_870
      QuickBEAM.stop(rt)
    end

    test "compute crc32c of a string" do
      {:ok, rt} = QuickBEAM.start()
      {:ok, _} = QuickBEAM.load_addon(rt, addon_path("@node-rs/crc32"), as: "crc32mod")
      assert {:ok, result} = QuickBEAM.eval(rt, ~s[crc32mod.crc32c("hello")])
      assert is_integer(result)
      assert is_integer(result)
      assert result > 0
      QuickBEAM.stop(rt)
    end

    test "crc32 of empty string" do
      {:ok, rt} = QuickBEAM.start()
      {:ok, _} = QuickBEAM.load_addon(rt, addon_path("@node-rs/crc32"), as: "crc32mod")
      assert {:ok, 0} = QuickBEAM.eval(rt, ~s[crc32mod.crc32("")])
      QuickBEAM.stop(rt)
    end
  end

  describe "@node-rs/argon2" do
    @describetag :napi_addon

    setup do
      if addon_available?("@node-rs/argon2"), do: :ok, else: :skip
    end

    test "load and export functions" do
      {:ok, rt} = QuickBEAM.start()
      {:ok, exports} = QuickBEAM.load_addon(rt, addon_path("@node-rs/argon2"), as: "argon2")
      assert Map.has_key?(exports, "hashSync")
      assert Map.has_key?(exports, "verifySync")
      assert Map.has_key?(exports, "Algorithm")
      assert exports["Algorithm"] == %{"Argon2d" => 0, "Argon2i" => 1, "Argon2id" => 2}
      QuickBEAM.stop(rt)
    end

    test "hash and verify password" do
      {:ok, rt} = QuickBEAM.start()
      {:ok, _} = QuickBEAM.load_addon(rt, addon_path("@node-rs/argon2"), as: "argon2")

      {:ok, hash} = QuickBEAM.eval(rt, ~s[argon2.hashSync("password123")])
      assert is_binary(hash)
      assert String.starts_with?(hash, "$argon2")

      {:ok, valid} = QuickBEAM.eval(rt, ~s[argon2.verifySync("#{hash}", "password123")])
      assert valid == true

      {:ok, invalid} = QuickBEAM.eval(rt, ~s[argon2.verifySync("#{hash}", "wrongpassword")])
      assert invalid == false

      QuickBEAM.stop(rt)
    end
  end

  describe "@node-rs/bcrypt" do
    @describetag :napi_addon

    setup do
      if addon_available?("@node-rs/bcrypt"), do: :ok, else: :skip
    end

    test "load and export functions" do
      {:ok, rt} = QuickBEAM.start()
      {:ok, exports} = QuickBEAM.load_addon(rt, addon_path("@node-rs/bcrypt"), as: "bcrypt")
      assert Map.has_key?(exports, "hashSync")
      assert Map.has_key?(exports, "verifySync")
      assert Map.has_key?(exports, "genSaltSync")
      assert exports["DEFAULT_COST"] == 12
      QuickBEAM.stop(rt)
    end

    test "hash and verify password" do
      {:ok, rt} = QuickBEAM.start()
      {:ok, _} = QuickBEAM.load_addon(rt, addon_path("@node-rs/bcrypt"), as: "bcrypt")

      {:ok, hash} = QuickBEAM.eval(rt, ~s[bcrypt.hashSync("password123", 4)])
      assert is_binary(hash)
      assert String.starts_with?(hash, "$2")

      {:ok, valid} = QuickBEAM.eval(rt, ~s[bcrypt.verifySync("password123", "#{hash}")])
      assert valid == true

      {:ok, invalid} = QuickBEAM.eval(rt, ~s[bcrypt.verifySync("wrongpassword", "#{hash}")])
      assert invalid == false

      QuickBEAM.stop(rt)
    end

    test "generate salt" do
      {:ok, rt} = QuickBEAM.start()
      {:ok, _} = QuickBEAM.load_addon(rt, addon_path("@node-rs/bcrypt"), as: "bcrypt")
      {:ok, salt} = QuickBEAM.eval(rt, "bcrypt.genSaltSync(4)")
      assert is_binary(salt)
      assert String.starts_with?(salt, "$2b$04$")
      QuickBEAM.stop(rt)
    end
  end

  describe "sqlite-napi" do
    @describetag :napi_sqlite

    setup do
      if File.exists?(sqlite_napi_path()), do: :ok, else: :skip
    end

    test "load and export classes" do
      {:ok, rt} = QuickBEAM.start()
      {:ok, exports} = QuickBEAM.load_addon(rt, sqlite_napi_path(), as: "sqlite")
      assert Map.has_key?(exports, "Database")
      QuickBEAM.stop(rt)
    end

    test "create in-memory database and execute DDL" do
      {:ok, rt} = QuickBEAM.start()
      {:ok, _} = QuickBEAM.load_addon(rt, sqlite_napi_path(), as: "sqlite")

      assert {:ok, _} = QuickBEAM.eval(rt, """
        const db = new sqlite.Database(":memory:");
        db.exec("CREATE TABLE test (id INTEGER PRIMARY KEY, name TEXT)");
        "ok"
      """)

      QuickBEAM.stop(rt)
    end

    test "insert and query data" do
      {:ok, rt} = QuickBEAM.start()
      {:ok, _} = QuickBEAM.load_addon(rt, sqlite_napi_path(), as: "sqlite")

      {:ok, result} = QuickBEAM.eval(rt, """
        const db = new sqlite.Database(":memory:");
        db.exec("CREATE TABLE test (id INTEGER PRIMARY KEY, name TEXT)");
        db.exec("INSERT INTO test VALUES (1, 'hello')");
        db.exec("INSERT INTO test VALUES (2, 'world')");
        JSON.stringify(db.query("SELECT * FROM test ORDER BY id"));
      """)

      assert is_binary(result)
      parsed = Jason.decode!(result)
      assert length(parsed) == 2
      assert hd(parsed)["name"] == "hello"

      QuickBEAM.stop(rt)
    end

    test "parameterized queries" do
      {:ok, rt} = QuickBEAM.start()
      {:ok, _} = QuickBEAM.load_addon(rt, sqlite_napi_path(), as: "sqlite")

      {:ok, result} = QuickBEAM.eval(rt, """
        const db = new sqlite.Database(":memory:");
        db.exec("CREATE TABLE kv (key TEXT PRIMARY KEY, val TEXT)");
        db.run("INSERT INTO kv VALUES (?, ?)", "greeting", "hello");
        db.run("INSERT INTO kv VALUES (?, ?)", "target", "world");
        JSON.stringify(db.query("SELECT * FROM kv WHERE key = ?", "greeting"));
      """)

      parsed = Jason.decode!(result)
      assert length(parsed) == 1
      assert hd(parsed)["val"] == "hello"

      QuickBEAM.stop(rt)
    end
  end
end
