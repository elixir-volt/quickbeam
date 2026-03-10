defmodule QuickBEAM.SupervisionTest do
  use ExUnit.Case, async: true

  describe "child_spec" do
    test "uses :name as child id" do
      spec = QuickBEAM.child_spec(name: :my_runtime)
      assert spec.id == :my_runtime
      assert spec.start == {QuickBEAM.Runtime, :start_link, [[name: :my_runtime]]}
    end

    test "uses :id over :name when both provided" do
      spec = QuickBEAM.child_spec(name: :my_runtime, id: :custom_id)
      assert spec.id == :custom_id
    end

    test "falls back to module name" do
      spec = QuickBEAM.child_spec([])
      assert spec.id == QuickBEAM.Runtime
    end
  end

  describe "supervision tree" do
    test "single runtime in supervisor" do
      children = [
        {QuickBEAM, name: :supervised_rt}
      ]

      {:ok, sup} = Supervisor.start_link(children, strategy: :one_for_one)

      assert {:ok, 42} = QuickBEAM.eval(:supervised_rt, "40 + 2")

      Supervisor.stop(sup)
    end

    test "multiple runtimes in supervisor" do
      children = [
        {QuickBEAM, name: :rt_a, id: :rt_a},
        {QuickBEAM, name: :rt_b, id: :rt_b}
      ]

      {:ok, sup} = Supervisor.start_link(children, strategy: :one_for_one)

      QuickBEAM.eval(:rt_a, "globalThis.origin = 'a'")
      QuickBEAM.eval(:rt_b, "globalThis.origin = 'b'")

      assert {:ok, "a"} = QuickBEAM.eval(:rt_a, "globalThis.origin")
      assert {:ok, "b"} = QuickBEAM.eval(:rt_b, "globalThis.origin")

      Supervisor.stop(sup)
    end

    test "runtime restarts on crash" do
      children = [
        {QuickBEAM, name: :restartable_rt}
      ]

      {:ok, sup} = Supervisor.start_link(children, strategy: :one_for_one)

      pid_before = Process.whereis(:restartable_rt)
      assert is_pid(pid_before)

      QuickBEAM.eval(:restartable_rt, "globalThis.state = 'before_crash'")
      assert {:ok, "before_crash"} = QuickBEAM.eval(:restartable_rt, "globalThis.state")

      Process.exit(pid_before, :kill)
      Process.sleep(50)

      pid_after = Process.whereis(:restartable_rt)
      assert is_pid(pid_after)
      assert pid_after != pid_before

      # State is fresh after restart
      {:ok, result} = QuickBEAM.eval(:restartable_rt, "typeof globalThis.state")
      assert result == "undefined"

      Supervisor.stop(sup)
    end

    test "runtime with handlers in supervisor" do
      children = [
        {QuickBEAM,
         name: :handler_rt,
         handlers: %{
           "add" => fn [a, b] -> a + b end
         }}
      ]

      {:ok, sup} = Supervisor.start_link(children, strategy: :one_for_one)

      assert {:ok, 7} = QuickBEAM.eval(:handler_rt, "await beam.call('add', 3, 4)")

      Supervisor.stop(sup)
    end
  end

  describe "script option" do
    test "loads a JS file on startup" do
      script_path = Path.join(System.tmp_dir!(), "quickbeam_test_#{:rand.uniform(100_000)}.js")
      File.write!(script_path, "globalThis.loaded = true; globalThis.version = 42;")

      {:ok, rt} = QuickBEAM.start(script: script_path)

      assert {:ok, true} = QuickBEAM.eval(rt, "globalThis.loaded")
      assert {:ok, 42} = QuickBEAM.eval(rt, "globalThis.version")

      QuickBEAM.stop(rt)
      File.rm!(script_path)
    end

    test "script with functions available for later calls" do
      script_path = Path.join(System.tmp_dir!(), "quickbeam_test_#{:rand.uniform(100_000)}.js")
      File.write!(script_path, "function greet(name) { return `Hello, ${name}!`; }")

      {:ok, rt} = QuickBEAM.start(script: script_path)

      assert {:ok, "Hello, World!"} = QuickBEAM.call(rt, "greet", ["World"])

      QuickBEAM.stop(rt)
      File.rm!(script_path)
    end

    test "script in supervised runtime" do
      script_path = Path.join(System.tmp_dir!(), "quickbeam_test_#{:rand.uniform(100_000)}.js")
      File.write!(script_path, "globalThis.initialized = true;")

      children = [
        {QuickBEAM, name: :scripted_rt, script: script_path}
      ]

      {:ok, sup} = Supervisor.start_link(children, strategy: :one_for_one)

      assert {:ok, true} = QuickBEAM.eval(:scripted_rt, "globalThis.initialized")

      Supervisor.stop(sup)
      File.rm!(script_path)
    end

    test "fails on missing script file" do
      Process.flag(:trap_exit, true)
      result = QuickBEAM.start(script: "/nonexistent/script.js")
      assert {:error, {:script_not_found, "/nonexistent/script.js", :enoent}} = result
    end

    test "fails on invalid JS in script" do
      Process.flag(:trap_exit, true)
      script_path = Path.join(System.tmp_dir!(), "quickbeam_test_#{:rand.uniform(100_000)}.js")
      File.write!(script_path, "this is not valid javascript }{}{")

      result = QuickBEAM.start(script: script_path)
      assert {:error, {:script_error, ^script_path, %QuickBEAM.JSError{}}} = result

      File.rm!(script_path)
    end
  end
end
