defmodule QuickBEAM.VM.PromiseTest do
  use ExUnit.Case, async: false

  setup do
    assert {:ok, runtime} = QuickBEAM.start(apis: false)

    on_exit(fn ->
      if Process.alive?(runtime) do
        try do
          QuickBEAM.stop(runtime)
        catch
          :exit, _reason -> :ok
        end
      end
    end)

    %{runtime: runtime}
  end

  test "matches native fulfillment chains and returned-Promise assimilation", %{runtime: runtime} do
    sources = [
      "Promise.resolve(1).then(x=>x+1).then(x=>x*2)",
      "Promise.resolve(1).then(async x=>{await 0;return x+41})",
      "(async()=>{return (async()=>42)()})()"
    ]

    for source <- sources do
      assert_vm_matches_native(runtime, source)
    end
  end

  test "supports Promise construction, resolver idempotence, and static helpers", %{
    runtime: runtime
  } do
    sources = [
      "new Promise(resolve=>resolve(42))",
      "new Promise((resolve,reject)=>{resolve(42);reject(1)})",
      "new Promise(resolve=>{resolve({then: next=>next(42)});resolve(1)})",
      "(()=>{let release;let source=new Promise(resolve=>release=resolve);let result=new Promise(resolve=>{resolve(source);resolve(42)});release(1);return result})()",
      "new Promise((resolve,reject)=>reject(41)).catch(value=>value+1)",
      "new Promise(()=>{throw 42}).catch(value=>value)",
      "new Promise(async resolve=>{await 0;resolve(42)})",
      "Promise.reject(42).catch(value=>value)",
      "(()=>{let promise=Promise.resolve(1);return Promise.resolve(promise)===promise})()"
    ]

    for source <- sources do
      assert_vm_matches_native(runtime, source)
    end
  end

  test "assimilates thenables returned from resolution and reactions", %{runtime: runtime} do
    sources = [
      "Promise.resolve({then: resolve=>resolve(42)})",
      "Promise.resolve(1).then(()=>({then: resolve=>resolve(42)}))",
      "Promise.resolve({then: ()=>{throw 42}}).catch(value=>value)"
    ]

    for source <- sources do
      assert_vm_matches_native(runtime, source)
    end
  end

  test "matches native Promise combinators", %{runtime: runtime} do
    sources = [
      "Promise.all([Promise.resolve(1),2,Promise.resolve(3)]).then(values=>values.join(','))",
      "Promise.race([Promise.resolve(42),Promise.resolve(1)])",
      "Promise.allSettled([Promise.resolve(1),Promise.reject(2)]).then(values=>values[1].reason)",
      "Promise.any([Promise.reject(1),Promise.resolve(42)])",
      "Promise.any([Promise.reject(1),Promise.reject(2)]).catch(error=>error.errors.join(','))"
    ]

    for source <- sources do
      assert_vm_matches_native(runtime, source)
    end
  end

  test "runs reactions as FIFO microtasks after synchronous code", %{runtime: runtime} do
    source = """
    (async()=>{
      let order = ""
      let promise = Promise.resolve().then(() => order += "b")
      order += "a"
      await promise
      return order
    })()
    """

    assert_vm_matches_native(runtime, source)
    assert {:ok, program} = QuickBEAM.VM.compile(source)
    assert {:ok, "ab"} = QuickBEAM.VM.eval(program)
  end

  test "detaches nested async frames and resumes their caller independently", %{runtime: runtime} do
    source = """
    (async()=>{
      let order = ""
      let promise = (async()=>{ order += "a"; await 0; order += "c" })()
      order += "b"
      await promise
      return order
    })()
    """

    assert_vm_matches_native(runtime, source)
    assert {:ok, program} = QuickBEAM.VM.compile(source)
    assert {:ok, "abc"} = QuickBEAM.VM.eval(program)
  end

  test "propagates rejection through catch and preserves primitive throws", %{runtime: runtime} do
    sources = [
      "(async()=>{throw 41})().catch(value=>value+1)",
      "Promise.resolve(1).finally(()=>{throw 42}).catch(value=>value)",
      "(async()=>{try{return await (async()=>{await 0;throw 41})()}catch(value){return value+1}})()"
    ]

    for source <- sources do
      assert_vm_matches_native(runtime, source)
    end
  end

  test "finally preserves completion and waits for returned Promises", %{runtime: runtime} do
    sources = [
      "Promise.resolve(42).finally(()=>1)",
      "Promise.resolve(42).finally(()=>Promise.resolve(1))",
      "Promise.resolve(42).finally(()=>({then: resolve=>resolve(1)}))",
      "(async()=>{throw 42})().finally(()=>Promise.resolve()).catch(value=>value)"
    ]

    for source <- sources do
      assert_vm_matches_native(runtime, source)
    end
  end

  test "rejects Promise self-resolution", %{runtime: runtime} do
    source = """
    (async()=>{
      let promise
      promise = Promise.resolve().then(() => promise)
      try { await promise } catch (error) { return error.name }
    })()
    """

    assert_vm_matches_native(runtime, source)
    assert {:ok, program} = QuickBEAM.VM.compile(source)
    assert {:ok, "TypeError"} = QuickBEAM.VM.eval(program)
  end

  test "releases caller depth before detached reactions run" do
    assert {:ok, program} = QuickBEAM.VM.compile("Promise.resolve(42).then(value=>value)")
    assert {:ok, 42} = QuickBEAM.VM.eval(program, max_stack_depth: 1)
  end

  test "preserves deterministic limits across detached continuations" do
    source = "(async()=>{await 0;while(true){}})()"
    assert {:ok, program} = QuickBEAM.VM.compile(source)

    assert {:error, {:limit_exceeded, :steps, 100}} =
             QuickBEAM.VM.eval(program, max_steps: 100)
  end

  defp assert_vm_matches_native(runtime, source) do
    assert {:ok, program} = QuickBEAM.VM.compile(source)
    assert {:ok, expected} = QuickBEAM.eval(runtime, "await (#{source})")
    assert {:ok, ^expected} = QuickBEAM.VM.eval(program)
  end
end
