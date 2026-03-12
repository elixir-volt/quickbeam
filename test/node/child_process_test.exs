defmodule QuickBEAM.Node.ChildProcessTest do
  use ExUnit.Case, async: true

  setup do
    {:ok, rt} = QuickBEAM.start(apis: [:browser, :node])
    on_exit(fn -> try do QuickBEAM.stop(rt) catch :exit, _ -> :ok end end)
    %{rt: rt}
  end

  describe "execSync" do
    test "returns stdout from echo", %{rt: rt} do
      {:ok, result} = QuickBEAM.eval(rt, "child_process.execSync('echo hello')")
      assert result == "hello\n"
    end

    test "throws on non-zero exit", %{rt: rt} do
      result = QuickBEAM.eval(rt, "child_process.execSync('exit 1')")
      assert {:error, %{message: msg}} = result
      assert msg =~ "Command failed"
    end

    test "respects cwd option", %{rt: rt} do
      {:ok, result} = QuickBEAM.eval(rt, "child_process.execSync('pwd', { cwd: '/tmp' })")
      assert String.trim(result) =~ "/tmp"
    end

    test "returns empty string for empty output", %{rt: rt} do
      {:ok, result} = QuickBEAM.eval(rt, "child_process.execSync('cat /dev/null')")
      assert result == ""
    end

    test "throws on timeout", %{rt: rt} do
      result = QuickBEAM.eval(rt, "child_process.execSync('sleep 10', { timeout: 100 })")
      assert {:error, %{message: msg}} = result
      assert msg =~ "timed out"
    end

    test "throws on non-existent command", %{rt: rt} do
      result = QuickBEAM.eval(rt, "child_process.execSync('nonexistent_command_xyz_123')")
      assert {:error, %{message: msg}} = result
      assert msg =~ "Command failed"
    end
  end

  describe "exec" do
    test "calls callback with stdout", %{rt: rt} do
      {:ok, result} = QuickBEAM.eval(rt, """
        await new Promise((resolve) => {
          child_process.exec('echo hello', (err, stdout, stderr) => {
            resolve({ err, stdout: stdout.trim(), stderr })
          })
        })
      """)
      assert result["err"] == nil
      assert result["stdout"] == "hello"
      assert result["stderr"] == ""
    end

    test "calls callback with error on failure", %{rt: rt} do
      {:ok, result} = QuickBEAM.eval(rt, """
        await new Promise((resolve) => {
          child_process.exec('exit 1', (err, stdout, stderr) => {
            resolve({ hasErr: err !== null, errMsg: err?.message })
          })
        })
      """)
      assert result["hasErr"] == true
      assert result["errMsg"] =~ "Command failed"
    end
  end
end
