defmodule QuickBEAM.Core.BeamAPITest do
  use ExUnit.Case, async: true

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

  describe "Beam.version" do
    test "returns QuickBEAM version string", %{rt: rt} do
      {:ok, version} = QuickBEAM.eval(rt, "Beam.version")
      assert is_binary(version)
      assert version =~ ~r/^\d+\.\d+\.\d+/
    end

    test "is read-only", %{rt: rt} do
      QuickBEAM.eval(rt, "Beam.version = 'hacked'")
      {:ok, version} = QuickBEAM.eval(rt, "Beam.version")
      assert version =~ ~r/^\d+\.\d+\.\d+/
    end
  end

  describe "Beam.sleep" do
    test "returns a promise that resolves after delay", %{rt: rt} do
      {:ok, elapsed} =
        QuickBEAM.eval(rt, """
        const start = performance.now();
        await Beam.sleep(50);
        const elapsed = performance.now() - start;
        elapsed >= 40
        """)

      assert elapsed == true
    end
  end

  describe "Beam.sleepSync" do
    test "blocks for the given duration", %{rt: rt} do
      {:ok, elapsed} =
        QuickBEAM.eval(rt, """
        const start = performance.now();
        Beam.sleepSync(50);
        performance.now() - start >= 40
        """)

      assert elapsed == true
    end
  end

  describe "Beam.hash" do
    test "returns an integer", %{rt: rt} do
      {:ok, result} = QuickBEAM.eval(rt, "Beam.hash('hello')")
      assert is_integer(result)
    end

    test "same input produces same hash", %{rt: rt} do
      {:ok, a} = QuickBEAM.eval(rt, "Beam.hash('test')")
      {:ok, b} = QuickBEAM.eval(rt, "Beam.hash('test')")
      assert a == b
    end

    test "different input produces different hash", %{rt: rt} do
      {:ok, a} = QuickBEAM.eval(rt, "Beam.hash('hello')")
      {:ok, b} = QuickBEAM.eval(rt, "Beam.hash('world')")
      assert a != b
    end

    test "with range parameter", %{rt: rt} do
      {:ok, result} = QuickBEAM.eval(rt, "Beam.hash('test', 100)")
      assert is_integer(result)
      assert result >= 0 and result < 100
    end

    test "hashes objects", %{rt: rt} do
      {:ok, result} = QuickBEAM.eval(rt, "Beam.hash({a: 1, b: 2})")
      assert is_integer(result)
    end

    test "hashes arrays", %{rt: rt} do
      {:ok, result} = QuickBEAM.eval(rt, "Beam.hash([1, 2, 3])")
      assert is_integer(result)
    end
  end

  describe "Beam.escapeHTML" do
    test "escapes all five characters", %{rt: rt} do
      {:ok, result} = QuickBEAM.eval(rt, ~s[Beam.escapeHTML('<div class="a">it\\'s &</div>')])
      assert result == "&lt;div class=&quot;a&quot;&gt;it&#x27;s &amp;&lt;/div&gt;"
    end

    test "leaves safe strings unchanged", %{rt: rt} do
      {:ok, result} = QuickBEAM.eval(rt, "Beam.escapeHTML('hello world')")
      assert result == "hello world"
    end

    test "handles empty string", %{rt: rt} do
      {:ok, result} = QuickBEAM.eval(rt, "Beam.escapeHTML('')")
      assert result == ""
    end

    test "escapes only special chars", %{rt: rt} do
      {:ok, result} = QuickBEAM.eval(rt, "Beam.escapeHTML('a & b')")
      assert result == "a &amp; b"
    end
  end

  describe "Beam.which" do
    test "finds an executable on PATH", %{rt: rt} do
      {:ok, result} = QuickBEAM.eval(rt, "Beam.which('ls')")
      assert is_binary(result)
      assert String.contains?(result, "ls")
    end

    test "returns null for nonexistent binary", %{rt: rt} do
      {:ok, result} = QuickBEAM.eval(rt, "Beam.which('nonexistent_binary_xyz')")
      assert result == nil
    end
  end

  describe "Beam.peek" do
    test "returns resolved value synchronously", %{rt: rt} do
      {:ok, result} = QuickBEAM.eval(rt, "Beam.peek(Promise.resolve(42))")
      assert result == 42
    end

    test "returns the promise itself if still pending", %{rt: rt} do
      {:ok, result} =
        QuickBEAM.eval(rt, """
        const p = new Promise(() => {});
        Beam.peek(p) === p
        """)

      assert result == true
    end

    test "returns non-promise values as-is", %{rt: rt} do
      {:ok, result} = QuickBEAM.eval(rt, "Beam.peek(42)")
      assert result == 42
    end

    test "peek.status returns fulfilled for resolved promise", %{rt: rt} do
      {:ok, result} = QuickBEAM.eval(rt, "Beam.peek.status(Promise.resolve(1))")
      assert result == "fulfilled"
    end

    test "peek.status returns rejected for rejected promise", %{rt: rt} do
      {:ok, result} =
        QuickBEAM.eval(rt, """
        const p = Promise.reject(new Error('x'));
        const s = Beam.peek.status(p);
        p.catch(() => {});
        s
        """)

      assert result == "rejected"
    end

    test "peek.status returns pending for unresolved", %{rt: rt} do
      {:ok, result} = QuickBEAM.eval(rt, "Beam.peek.status(new Promise(() => {}))")
      assert result == "pending"
    end

    test "peek.status returns fulfilled for non-promise", %{rt: rt} do
      {:ok, result} = QuickBEAM.eval(rt, "Beam.peek.status(42)")
      assert result == "fulfilled"
    end
  end

  describe "Beam.randomUUIDv7" do
    test "returns a valid UUID string", %{rt: rt} do
      {:ok, uuid} = QuickBEAM.eval(rt, "Beam.randomUUIDv7()")
      assert is_binary(uuid)
      assert uuid =~ ~r/^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
    end

    test "generates unique values", %{rt: rt} do
      {:ok, uuids} =
        QuickBEAM.eval(rt, """
        [Beam.randomUUIDv7(), Beam.randomUUIDv7(), Beam.randomUUIDv7()]
        """)

      assert length(Enum.uniq(uuids)) == 3
    end

    test "is monotonically sortable", %{rt: rt} do
      {:ok, uuids} =
        QuickBEAM.eval(rt, """
        const ids = [];
        for (let i = 0; i < 5; i++) ids.push(Beam.randomUUIDv7());
        ids
        """)

      assert uuids == Enum.sort(uuids)
    end
  end

  describe "Beam.deepEquals" do
    test "equal objects", %{rt: rt} do
      {:ok, result} = QuickBEAM.eval(rt, "Beam.deepEquals({a: 1, b: [2, 3]}, {a: 1, b: [2, 3]})")
      assert result == true
    end

    test "unequal objects", %{rt: rt} do
      {:ok, result} = QuickBEAM.eval(rt, "Beam.deepEquals({a: 1}, {a: 2})")
      assert result == false
    end

    test "nested equality", %{rt: rt} do
      {:ok, result} = QuickBEAM.eval(rt, "Beam.deepEquals({x: {y: {z: 1}}}, {x: {y: {z: 1}}})")
      assert result == true
    end

    test "array equality", %{rt: rt} do
      {:ok, result} = QuickBEAM.eval(rt, "Beam.deepEquals([1, 2, 3], [1, 2, 3])")
      assert result == true
    end

    test "different types", %{rt: rt} do
      {:ok, result} = QuickBEAM.eval(rt, "Beam.deepEquals(1, '1')")
      assert result == false
    end

    test "null handling", %{rt: rt} do
      {:ok, result} = QuickBEAM.eval(rt, "Beam.deepEquals(null, null)")
      assert result == true
    end
  end

  describe "Beam.semver" do
    test "satisfies returns true for matching version", %{rt: rt} do
      {:ok, result} = QuickBEAM.eval(rt, ~s[Beam.semver.satisfies("1.5.0", "~> 1.4")])
      assert result == true
    end

    test "satisfies returns false for non-matching version", %{rt: rt} do
      {:ok, result} = QuickBEAM.eval(rt, ~s[Beam.semver.satisfies("2.0.0", "~> 1.4")])
      assert result == false
    end

    test "satisfies with exact match", %{rt: rt} do
      {:ok, result} = QuickBEAM.eval(rt, ~s[Beam.semver.satisfies("1.0.0", "== 1.0.0")])
      assert result == true
    end

    test "satisfies returns false for invalid version", %{rt: rt} do
      {:ok, result} = QuickBEAM.eval(rt, ~s[Beam.semver.satisfies("not-a-version", "~> 1.0")])
      assert result == false
    end

    test "order returns -1 for lesser", %{rt: rt} do
      {:ok, result} = QuickBEAM.eval(rt, ~s[Beam.semver.order("1.0.0", "2.0.0")])
      assert result == -1
    end

    test "order returns 0 for equal", %{rt: rt} do
      {:ok, result} = QuickBEAM.eval(rt, ~s[Beam.semver.order("1.0.0", "1.0.0")])
      assert result == 0
    end

    test "order returns 1 for greater", %{rt: rt} do
      {:ok, result} = QuickBEAM.eval(rt, ~s[Beam.semver.order("2.0.0", "1.0.0")])
      assert result == 1
    end

    test "order returns null for invalid input", %{rt: rt} do
      {:ok, result} = QuickBEAM.eval(rt, ~s[Beam.semver.order("invalid", "1.0.0")])
      assert result == nil
    end
  end

  describe "Beam.nodes" do
    test "returns a list with at least the local node", %{rt: rt} do
      {:ok, nodes} = QuickBEAM.eval(rt, "Beam.nodes()")
      assert is_list(nodes)
      assert length(nodes) >= 1
      assert Enum.all?(nodes, &is_binary/1)
    end
  end

  describe "Beam.spawn" do
    test "spawns a new runtime and returns a PID", %{rt: rt} do
      {:ok, pid} = QuickBEAM.eval(rt, "Beam.spawn('1 + 1')")
      assert is_pid(pid)
    end

    test "spawned runtime evaluates the script", %{rt: rt} do
      {:ok, pid} =
        QuickBEAM.eval(rt, """
        Beam.spawn("globalThis.x = 42")
        """)

      assert is_pid(pid)
      {:ok, 42} = QuickBEAM.eval(pid, "x")
      QuickBEAM.stop(pid)
    end
  end

  describe "Beam.register / Beam.whereis" do
    test "register and look up a runtime", %{rt: rt} do
      name = "test_runtime_#{System.unique_integer([:positive])}"

      {:ok, result} = QuickBEAM.eval(rt, "Beam.register('#{name}')")
      assert result == true

      {:ok, pid} = QuickBEAM.eval(rt, "Beam.whereis('#{name}')")
      assert pid == rt
    end

    test "whereis returns null for unknown name", %{rt: rt} do
      {:ok, result} =
        QuickBEAM.eval(rt, "Beam.whereis('nonexistent_#{System.unique_integer([:positive])}')")

      assert result == nil
    end

    test "register returns false for already-taken name", %{rt: rt} do
      name = "taken_#{System.unique_integer([:positive])}"
      {:ok, true} = QuickBEAM.eval(rt, "Beam.register('#{name}')")

      {:ok, rt2} = QuickBEAM.start()
      {:ok, result} = QuickBEAM.eval(rt2, "Beam.register('#{name}')")
      assert result == false
      QuickBEAM.stop(rt2)
    end
  end

  describe "Beam.link / Beam.unlink" do
    test "link and unlink a process", %{rt: rt} do
      pid = spawn(fn -> Process.sleep(5000) end)

      QuickBEAM.eval(rt, """
      Beam.onMessage((pid) => {
        globalThis.linked = Beam.link(pid);
        globalThis.unlinked = Beam.unlink(pid);
      });
      """)

      QuickBEAM.send_message(rt, pid)
      Process.sleep(50)

      {:ok, linked} = QuickBEAM.eval(rt, "linked")
      {:ok, unlinked} = QuickBEAM.eval(rt, "unlinked")
      assert linked == true
      assert unlinked == true

      Process.exit(pid, :kill)
    end
  end

  describe "Beam.systemInfo" do
    test "returns system information", %{rt: rt} do
      {:ok, info} = QuickBEAM.eval(rt, "Beam.systemInfo()")
      assert is_map(info)
      assert is_integer(info["schedulers"])
      assert is_integer(info["schedulers_online"])
      assert is_integer(info["process_count"])
      assert is_integer(info["process_limit"])
      assert is_integer(info["atom_count"])
      assert is_integer(info["atom_limit"])
      assert is_binary(info["otp_release"])
      assert is_map(info["memory"])
      assert is_integer(info["memory"]["total"])
    end
  end

  describe "Beam.processInfo" do
    test "returns process information", %{rt: rt} do
      {:ok, info} = QuickBEAM.eval(rt, "Beam.processInfo()")
      assert is_map(info)
      assert is_integer(info["memory"])
      assert is_integer(info["message_queue_len"])
      assert is_integer(info["reductions"])
      assert is_binary(info["status"])
    end
  end
end
