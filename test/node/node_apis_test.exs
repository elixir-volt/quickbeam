defmodule QuickBEAM.Node.NodeAPIsTest do
  use ExUnit.Case, async: true

  setup do
    {:ok, rt} = QuickBEAM.start(apis: [:node])
    on_exit(fn -> try do QuickBEAM.stop(rt) catch :exit, _ -> :ok end end)
    %{rt: rt}
  end

  describe "process" do
    test "process.platform", %{rt: rt} do
      {:ok, platform} = QuickBEAM.eval(rt, "process.platform")
      assert platform in ["darwin", "linux", "freebsd", "win32"]
    end

    test "process.arch", %{rt: rt} do
      {:ok, arch} = QuickBEAM.eval(rt, "process.arch")
      assert arch in ["arm64", "x64", "arm", "ia32"]
    end

    test "process.pid", %{rt: rt} do
      {:ok, pid} = QuickBEAM.eval(rt, "process.pid")
      assert is_integer(pid)
      assert pid > 0
    end

    test "process.cwd()", %{rt: rt} do
      {:ok, cwd} = QuickBEAM.eval(rt, "process.cwd()")
      assert is_binary(cwd)
      assert cwd == File.cwd!()
    end

    test "process.version", %{rt: rt} do
      {:ok, version} = QuickBEAM.eval(rt, "process.version")
      assert String.starts_with?(version, "v")
    end

    test "process.versions", %{rt: rt} do
      {:ok, versions} = QuickBEAM.eval(rt, "process.versions")
      assert is_map(versions)
      assert Map.has_key?(versions, "node")
      assert Map.has_key?(versions, "quickbeam")
    end

    test "process.env get/set", %{rt: rt} do
      unique = "QB_TEST_#{:rand.uniform(1_000_000)}"
      System.put_env(unique, "hello")

      {:ok, val} = QuickBEAM.eval(rt, "process.env.#{unique}")
      assert val == "hello"

      QuickBEAM.eval(rt, "process.env.#{unique} = 'world'")
      assert System.get_env(unique) == "world"
    after
      System.delete_env("QB_TEST_#{:rand.uniform(1_000_000)}")
    end

    test "process.nextTick", %{rt: rt} do
      {:ok, result} = QuickBEAM.eval(rt, """
        let x = 0;
        process.nextTick(() => { x = 42 });
        await new Promise(r => setTimeout(r, 10));
        x
      """)
      assert result == 42
    end

    test "process.argv", %{rt: rt} do
      {:ok, argv} = QuickBEAM.eval(rt, "process.argv")
      assert is_list(argv)
    end

    test "process.hrtime()", %{rt: rt} do
      {:ok, result} = QuickBEAM.eval(rt, """
        const t = process.hrtime();
        [typeof t[0], typeof t[1], t[0] >= 0, t[1] >= 0]
      """)
      assert result == ["number", "number", true, true]
    end

    test "process.hrtime.bigint()", %{rt: rt} do
      {:ok, result} = QuickBEAM.eval(rt, """
        const t = process.hrtime.bigint();
        typeof t === 'bigint' && t > 0n
      """)
      assert result == true
    end
  end

  describe "path" do
    test "path.join", %{rt: rt} do
      {:ok, result} = QuickBEAM.eval(rt, "path.join('/foo', 'bar', 'baz')")
      assert result == "/foo/bar/baz"
    end

    test "path.join normalizes", %{rt: rt} do
      {:ok, result} = QuickBEAM.eval(rt, "path.join('/foo', 'bar', '..', 'baz')")
      assert result == "/foo/baz"
    end

    test "path.basename", %{rt: rt} do
      {:ok, result} = QuickBEAM.eval(rt, "path.basename('/foo/bar/baz.txt')")
      assert result == "baz.txt"
    end

    test "path.basename with ext", %{rt: rt} do
      {:ok, result} = QuickBEAM.eval(rt, "path.basename('/foo/bar/baz.txt', '.txt')")
      assert result == "baz"
    end

    test "path.dirname", %{rt: rt} do
      {:ok, result} = QuickBEAM.eval(rt, "path.dirname('/foo/bar/baz.txt')")
      assert result == "/foo/bar"
    end

    test "path.extname", %{rt: rt} do
      {:ok, result} = QuickBEAM.eval(rt, "path.extname('/foo/bar/baz.txt')")
      assert result == ".txt"
    end

    test "path.extname no extension", %{rt: rt} do
      {:ok, result} = QuickBEAM.eval(rt, "path.extname('/foo/bar/baz')")
      assert result == ""
    end

    test "path.isAbsolute", %{rt: rt} do
      {:ok, abs} = QuickBEAM.eval(rt, "path.isAbsolute('/foo')")
      {:ok, rel} = QuickBEAM.eval(rt, "path.isAbsolute('foo')")
      assert abs == true
      assert rel == false
    end

    test "path.resolve", %{rt: rt} do
      {:ok, result} = QuickBEAM.eval(rt, "path.resolve('/foo/bar', './baz')")
      assert result == "/foo/bar/baz"
    end

    test "path.parse", %{rt: rt} do
      {:ok, parsed} = QuickBEAM.eval(rt, "path.parse('/home/user/file.txt')")
      assert parsed["root"] == "/"
      assert parsed["dir"] == "/home/user"
      assert parsed["base"] == "file.txt"
      assert parsed["ext"] == ".txt"
      assert parsed["name"] == "file"
    end

    test "path.relative", %{rt: rt} do
      {:ok, result} = QuickBEAM.eval(rt, "path.relative('/data/orandea/test/aaa', '/data/orandea/impl/bbb')")
      assert result == "../../impl/bbb"
    end

    test "path.sep and path.delimiter", %{rt: rt} do
      {:ok, sep} = QuickBEAM.eval(rt, "path.sep")
      {:ok, delim} = QuickBEAM.eval(rt, "path.delimiter")
      assert sep == "/"
      assert delim == ":"
    end
  end

  describe "fs" do
    setup do
      dir = Path.join(System.tmp_dir!(), "qb_fs_test_#{:rand.uniform(1_000_000)}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      %{dir: dir}
    end

    test "readFileSync / writeFileSync", %{rt: rt, dir: dir} do
      file = Path.join(dir, "test.txt")
      File.write!(file, "hello world")

      {:ok, content} = QuickBEAM.eval(rt, "fs.readFileSync(#{inspect(file)}, 'utf8')")
      assert content == "hello world"

      QuickBEAM.eval(rt, "fs.writeFileSync(#{inspect(file)}, 'new content')")
      assert File.read!(file) == "new content"
    end

    test "readFileSync returns binary without encoding", %{rt: rt, dir: dir} do
      file = Path.join(dir, "test.bin")
      File.write!(file, <<1, 2, 3>>)

      {:ok, data} = QuickBEAM.eval(rt, "fs.readFileSync(#{inspect(file)})")
      assert data == <<1, 2, 3>>
    end

    test "readFileSync throws on missing file", %{rt: rt} do
      result = QuickBEAM.eval(rt, "fs.readFileSync('/nonexistent/file.txt')")
      assert {:error, %{message: msg}} = result
      assert msg =~ "ENOENT"
    end

    test "existsSync", %{rt: rt, dir: dir} do
      file = Path.join(dir, "exists.txt")
      File.write!(file, "x")

      {:ok, true} = QuickBEAM.eval(rt, "fs.existsSync(#{inspect(file)})")
      {:ok, false} = QuickBEAM.eval(rt, "fs.existsSync(#{inspect(file <> ".nope")})")
    end

    test "mkdirSync", %{rt: rt, dir: dir} do
      sub = Path.join(dir, "subdir")
      QuickBEAM.eval(rt, "fs.mkdirSync(#{inspect(sub)})")
      assert File.dir?(sub)
    end

    test "mkdirSync recursive", %{rt: rt, dir: dir} do
      deep = Path.join([dir, "a", "b", "c"])
      QuickBEAM.eval(rt, "fs.mkdirSync(#{inspect(deep)}, { recursive: true })")
      assert File.dir?(deep)
    end

    test "readdirSync", %{rt: rt, dir: dir} do
      File.write!(Path.join(dir, "a.txt"), "")
      File.write!(Path.join(dir, "b.txt"), "")

      {:ok, entries} = QuickBEAM.eval(rt, "fs.readdirSync(#{inspect(dir)})")
      assert "a.txt" in entries
      assert "b.txt" in entries
    end

    test "statSync", %{rt: rt, dir: dir} do
      file = Path.join(dir, "stat.txt")
      File.write!(file, "hello")

      {:ok, stat} = QuickBEAM.eval(rt, """
        const s = fs.statSync(#{inspect(file)});
        ({ isFile: s.isFile(), isDir: s.isDirectory(), size: s.size })
      """)
      assert stat["isFile"] == true
      assert stat["isDir"] == false
      assert stat["size"] == 5
    end

    test "unlinkSync", %{rt: rt, dir: dir} do
      file = Path.join(dir, "del.txt")
      File.write!(file, "bye")

      QuickBEAM.eval(rt, "fs.unlinkSync(#{inspect(file)})")
      refute File.exists?(file)
    end

    test "renameSync", %{rt: rt, dir: dir} do
      src = Path.join(dir, "old.txt")
      dst = Path.join(dir, "new.txt")
      File.write!(src, "data")

      QuickBEAM.eval(rt, "fs.renameSync(#{inspect(src)}, #{inspect(dst)})")
      refute File.exists?(src)
      assert File.read!(dst) == "data"
    end

    test "appendFileSync", %{rt: rt, dir: dir} do
      file = Path.join(dir, "append.txt")
      File.write!(file, "hello")

      QuickBEAM.eval(rt, "fs.appendFileSync(#{inspect(file)}, ' world')")
      assert File.read!(file) == "hello world"
    end

    test "copyFileSync", %{rt: rt, dir: dir} do
      src = Path.join(dir, "src.txt")
      dst = Path.join(dir, "dst.txt")
      File.write!(src, "copy me")

      QuickBEAM.eval(rt, "fs.copyFileSync(#{inspect(src)}, #{inspect(dst)})")
      assert File.read!(dst) == "copy me"
    end
  end

  describe "os" do
    test "os.platform()", %{rt: rt} do
      {:ok, platform} = QuickBEAM.eval(rt, "os.platform()")
      assert platform in ["darwin", "linux", "freebsd", "win32"]
    end

    test "os.arch()", %{rt: rt} do
      {:ok, arch} = QuickBEAM.eval(rt, "os.arch()")
      assert arch in ["arm64", "x64", "arm", "ia32"]
    end

    test "os.type()", %{rt: rt} do
      {:ok, type} = QuickBEAM.eval(rt, "os.type()")
      assert type in ["Darwin", "Linux", "FreeBSD", "Windows_NT"]
    end

    test "os.hostname()", %{rt: rt} do
      {:ok, hostname} = QuickBEAM.eval(rt, "os.hostname()")
      assert is_binary(hostname)
      assert String.length(hostname) > 0
    end

    test "os.homedir()", %{rt: rt} do
      {:ok, home} = QuickBEAM.eval(rt, "os.homedir()")
      assert is_binary(home)
      assert home == (System.user_home() || "/tmp")
    end

    test "os.tmpdir()", %{rt: rt} do
      {:ok, tmp} = QuickBEAM.eval(rt, "os.tmpdir()")
      assert is_binary(tmp)
    end

    test "os.cpus()", %{rt: rt} do
      {:ok, cpus} = QuickBEAM.eval(rt, "os.cpus()")
      assert is_list(cpus)
      assert length(cpus) == System.schedulers_online()
    end

    test "os.EOL", %{rt: rt} do
      {:ok, eol} = QuickBEAM.eval(rt, "os.EOL")
      assert eol == "\n"
    end

    test "os.totalmem()", %{rt: rt} do
      {:ok, mem} = QuickBEAM.eval(rt, "os.totalmem()")
      assert is_integer(mem)
      assert mem > 0
    end

    test "os.uptime()", %{rt: rt} do
      {:ok, uptime} = QuickBEAM.eval(rt, "os.uptime()")
      assert is_integer(uptime) or is_float(uptime)
      assert uptime >= 0
    end

    test "os.endianness()", %{rt: rt} do
      {:ok, endian} = QuickBEAM.eval(rt, "os.endianness()")
      assert endian in ["BE", "LE"]
    end
  end

  describe "apis option" do
    test "apis: [:browser] does not have process global" do
      {:ok, rt} = QuickBEAM.start(apis: [:browser])
      {:ok, result} = QuickBEAM.eval(rt, "typeof process")
      assert result == "undefined"
      QuickBEAM.stop(rt)
    end

    test "apis: [:node] does not have fetch" do
      {:ok, rt} = QuickBEAM.start(apis: [:node])
      {:ok, result} = QuickBEAM.eval(rt, "typeof fetch")
      assert result == "undefined"
      QuickBEAM.stop(rt)
    end

    test "apis: [:browser, :node] has both" do
      {:ok, rt} = QuickBEAM.start(apis: [:browser, :node])
      {:ok, has_fetch} = QuickBEAM.eval(rt, "typeof fetch")
      {:ok, has_process} = QuickBEAM.eval(rt, "typeof process")
      assert has_fetch == "function"
      assert has_process == "object"
      QuickBEAM.stop(rt)
    end

    test "apis: [] has neither" do
      {:ok, rt} = QuickBEAM.start(apis: [])
      {:ok, no_fetch} = QuickBEAM.eval(rt, "typeof fetch")
      {:ok, no_process} = QuickBEAM.eval(rt, "typeof process")
      assert no_fetch == "undefined"
      assert no_process == "undefined"
      QuickBEAM.stop(rt)
    end

    test "apis: false has neither" do
      {:ok, rt} = QuickBEAM.start(apis: false)
      {:ok, no_fetch} = QuickBEAM.eval(rt, "typeof fetch")
      {:ok, no_process} = QuickBEAM.eval(rt, "typeof process")
      assert no_fetch == "undefined"
      assert no_process == "undefined"
      QuickBEAM.stop(rt)
    end
  end
end
