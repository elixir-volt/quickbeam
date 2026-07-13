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
      "(()=>{try{Promise(()=>{})}catch(error){return error.name}})()",
      "(()=>{try{new Promise()}catch(error){return error.name}})()",
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
      "Promise.any([Promise.reject(1),Promise.reject(2)]).catch(error=>error.errors.join(','))",
      "Promise.all('ab').then(values=>values.join(''))",
      "Promise.all(new Set([2,1,2])).then(values=>values.join(','))",
      "Promise.all(Array(2)).then(values=>[values.length,values[0]===void 0,values[1]===void 0])",
      "Promise.all(1).catch(error=>error.name)",
      "Promise.all({[Symbol.iterator](){let i=0;return {next(){i++;return i<=3?{value:i,done:false}:{done:true}}}}}).then(values=>values.join(','))",
      "Promise.all({[Symbol.iterator]:function(){let done=false;return {next(){if(done)return {done:true};done=true;return {value:42,done:false}}}}}).then(values=>values[0])",
      "(()=>{let reads=0;let iterable={get [Symbol.iterator](){reads++;return function(){let done=false;return {next(){if(done)return {done:true};done=true;return {value:42,done:false}}}}}};return Promise.all(iterable).then(values=>[values[0],reads])})()",
      "Promise.all({get [Symbol.iterator](){throw 41}}).catch(value=>value+1)",
      "Promise.all({[Symbol.iterator](){throw 42}}).catch(value=>value)",
      "Promise.all({[Symbol.iterator](){let iterator={done:false,get next(){return function(){if(this.done)return {done:true};this.done=true;return {value:42,done:false}}}};return iterator}}).then(values=>values[0])",
      "Promise.all({[Symbol.iterator](){return {next(){throw 42}}}}).catch(value=>value)",
      "Promise.all({[Symbol.iterator](){return {next(){return {get done(){throw 42}}}}}}).catch(value=>value)",
      "Promise.all({[Symbol.iterator](){let done=false;return {next(){if(done)return {done:true};done=true;return {done:false,get value(){throw 42}}}}}}).catch(value=>value)",
      "(()=>{let closed=false;let iterable={[Symbol.iterator](){return {next(){throw 1},return(){closed=true;return {done:true}}}}};return Promise.all(iterable).catch(()=>closed)})()",
      "(()=>{let closed=false;let iterable={[Symbol.iterator](){return {next(){return 1},return(){closed=true;return {done:true}}}}};return Promise.all(iterable).catch(()=>closed)})()",
      "(()=>{let log='';let iterable={[Symbol.iterator](){let index=0;return {next(){index++;if(index===1)return {value:{get then(){log+='t';return resolve=>resolve(1)}},done:false};log+='n';return {done:true}}}}};return Promise.all(iterable).then(()=>log)})()"
    ]

    for source <- sources do
      assert_vm_matches_native(runtime, source)
    end
  end

  test "reads thenable accessors synchronously and invokes returned then functions as jobs", %{
    runtime: runtime
  } do
    sources = [
      "(()=>{let order='';Promise.resolve({get then(){order+='a';return resolve=>{order+='c';resolve()}}});order+='b';return order})()",
      "(async()=>{let order='';Promise.resolve({get then(){order+='a';return resolve=>{order+='c';resolve()}}});order+='b';await 0;return order})()",
      "Promise.resolve({get then(){return resolve=>resolve(42)}})",
      "Promise.resolve({get then(){throw 42}}).catch(value=>value)",
      "Promise.resolve({get then(){return 42}}).then(value=>value.then)"
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

  test "bounds custom iterators with the shared step limit" do
    source =
      "Promise.all({[Symbol.iterator](){return {next(){return {value:1,done:false}}}}})"

    assert {:ok, program} = QuickBEAM.VM.compile(source)

    assert {:error, {:limit_exceeded, :steps, 200}} =
             QuickBEAM.VM.eval(program, max_steps: 200)
  end

  defp assert_vm_matches_native(runtime, source) do
    assert {:ok, program} = QuickBEAM.VM.compile(source)
    assert {:ok, expected} = QuickBEAM.eval(runtime, "await (#{source})")
    assert {:ok, ^expected} = QuickBEAM.VM.eval(program)
  end
end
