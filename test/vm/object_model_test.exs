defmodule QuickBEAM.VM.ObjectModelTest do
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

  test "matches native array length and sparse deletion semantics", %{runtime: runtime} do
    sources = [
      "(()=>{let value=[1,2,3];value.length=1;return [value.length,value[1]===void 0,Object.keys(value).join(',')]})()",
      "(()=>{let value=[];value[3]=4;delete value[3];return [value.length,Object.keys(value).length]})()",
      "(()=>{let value=Array(3);value[1]=2;return [value.length,Object.keys(value).join(',')]})()",
      "(()=>{let value=[1];Object.defineProperty(value,'length',{writable:false});try{value[1]=2}catch(error){}return [value.length,value[1]===void 0]})()",
      "(()=>{let value=[0,1,2];Object.defineProperty(value,'2',{configurable:false});try{value.length=1}catch(error){}return [value.length,value[2]]})()"
    ]

    for source <- sources do
      assert_vm_matches_native(runtime, source)
    end
  end

  test "matches native sparse-array callback and hole-preservation semantics", %{runtime: runtime} do
    sources = [
      "(()=>{let value=Array(4);value[1]=2;let calls=[];let mapped=value.map((item,index)=>{calls.push(index);return item*2});return [calls.join(','),mapped.length,Object.keys(mapped).join(','),mapped[1]]})()",
      "(()=>{let value=Array(5);value[1]=1;value[3]=3;let each=[];value.forEach((item,index)=>each.push(index));let filtered=value.filter(item=>item>1);let some=value.some((item,index)=>index===2);return [each.join(','),filtered.length,filtered[0],some]})()",
      "(()=>{let value=Array(5);value[2]=4;value[4]=6;let calls=[];let result=value.reduce((sum,item,index)=>{calls.push(index);return sum+item});return [result,calls.join(',')]})()",
      "(()=>{let value=Array(3);let calls=0;let initial=value.reduce(()=>{calls++;return 0},42);let error='';try{value.reduce(()=>0)}catch(reason){error=reason.name}return [initial,calls,error]})()",
      "(()=>{let value=Array(4);value[1]=2;let sliced=value.slice(0);let joined=value.join('-');let extra=Array(2);extra[1]=3;let combined=value.concat(extra);return [sliced.length,Object.keys(sliced).join(','),joined,combined.length,Object.keys(combined).join(',')]})()",
      "(()=>{let value=Array(3);value[0]=void 0;value[1]=null;return value.join(',')})()"
    ]

    for source <- sources do
      assert_vm_matches_native(runtime, source)
    end
  end

  test "matches native data descriptors and inherited write restrictions", %{runtime: runtime} do
    sources = [
      "(()=>{let value={};Object.defineProperty(value,'hidden',{value:42});let descriptor=Object.getOwnPropertyDescriptor(value,'hidden');return [value.hidden,Object.keys(value).length,descriptor.writable,descriptor.enumerable,descriptor.configurable]})()",
      "(()=>{let prototype={};Object.defineProperty(prototype,'fixed',{value:1,writable:false});let value=Object.create(prototype);try{value.fixed=2}catch(error){}return [value.fixed,Object.keys(value).length]})()",
      "(()=>{let value={};Object.defineProperty(value,'fixed',{value:1,writable:false,configurable:false});try{Object.defineProperty(value,'fixed',{value:2})}catch(error){return error.name}})()"
    ]

    for source <- sources do
      assert_vm_matches_native(runtime, source)
    end
  end

  test "matches native own and inherited accessor invocation", %{runtime: runtime} do
    sources = [
      "(()=>{let value={get answer(){return 42}};return value.answer})()",
      "(()=>{let prototype={get answer(){return this.value}};let value=Object.create(prototype);value.value=42;return value.answer})()",
      "(()=>{let seen=0;let prototype={set answer(value){seen=value}};let object=Object.create(prototype);object.answer=42;return seen})()",
      "(()=>{let value={get answer(){throw 42}};try{return value.answer}catch(error){return error}})()",
      "(()=>{let value={set answer(next){throw next}};try{value.answer=42}catch(error){return error}})()"
    ]

    for source <- sources do
      assert_vm_matches_native(runtime, source)
    end
  end

  test "matches native accessor descriptors and descriptor reflection", %{runtime: runtime} do
    sources = [
      "(()=>{let value={};let getter=function(){return 42};Object.defineProperty(value,'answer',{get:getter,enumerable:true});let descriptor=Object.getOwnPropertyDescriptor(value,'answer');return [value.answer,descriptor.get===getter,descriptor.set===void 0,descriptor.enumerable,('value' in descriptor)]})()",
      "(()=>{let stored=0;let value={};Object.defineProperty(value,'answer',{get:function(){return stored},set:function(next){stored=next}});value.answer=42;return value.answer})()",
      "(()=>{let value={};Object.defineProperty(value,'answer',{get:void 0});let descriptor=Object.getOwnPropertyDescriptor(value,'answer');return [value.answer===void 0,('get' in descriptor),('value' in descriptor)]})()",
      "(async()=>{let value={};Object.defineProperty(value,'answer',{get:async function(){await 0;return 42}});return await value.answer})()"
    ]

    for source <- sources do
      assert_vm_matches_native(runtime, source)
    end
  end

  test "resumes Object.assign through source getters and target setters", %{runtime: runtime} do
    sources = [
      "(()=>{let source={get answer(){return 42}};return Object.assign({},source).answer})()",
      "(()=>{let seen=0;let target={set answer(value){seen=value}};Object.assign(target,{answer:42});return seen})()",
      "(()=>{let source={get answer(){throw 42}};try{Object.assign({},source)}catch(error){return error}})()",
      "(()=>{let symbol=Symbol.iterator;let source={[symbol]:42,answer:1};let target=Object.assign({},source);return [Object.keys(source).join(','),target[symbol]]})()",
      "(()=>({[Symbol.iterator]:42,answer:1}))()"
    ]

    for source <- sources do
      assert_vm_matches_native(runtime, source)
    end
  end

  test "matches native prototype mutation and cycle rejection", %{runtime: runtime} do
    sources = [
      "(()=>{let prototype={answer:42};let value={};Object.setPrototypeOf(value,prototype);return [value.answer,Object.getPrototypeOf(value)===prototype]})()",
      "(()=>{let first={},second={};Object.setPrototypeOf(first,second);try{Object.setPrototypeOf(second,first)}catch(error){return error.name}})()"
    ]

    for source <- sources do
      assert_vm_matches_native(runtime, source)
    end
  end

  test "matches native constructor returns and instanceof", %{runtime: runtime} do
    sources = [
      "(()=>{function Value(){this.answer=42}let value=new Value();return [value.answer,value instanceof Value]})()",
      "(()=>{function Value(){this.answer=1;return {answer:42}}return new Value().answer})()",
      "(()=>{function Value(){this.answer=42;return 1}return new Value().answer})()",
      "(()=>{function Value(){}let Bound=Value.bind(null);let value=new Bound();return [value instanceof Value,value instanceof Bound]})()",
      "(()=>{try{new (async function(){})()}catch(error){return error.name}})()"
    ]

    for source <- sources do
      assert_vm_matches_native(runtime, source)
    end
  end

  test "indexes and slices strings as UTF-16 code units", %{runtime: runtime} do
    sources = [
      ~S|["😀".length,"😀".charCodeAt(0),"😀".charCodeAt(1)]|,
      ~S|["😀x".slice(0,2),"😀x".slice(1,2),"😀x"[0]]|,
      ~S|String.fromCharCode(55357,56832)|
    ]

    for source <- sources do
      assert_vm_matches_native(runtime, source)
    end
  end

  test "returns enumerable keys separately from all own property names", %{runtime: runtime} do
    sources = [
      "(()=>{let value={visible:1};Object.defineProperty(value,'hidden',{value:2});return [Object.keys(value).join(','),Object.getOwnPropertyNames(value).join(',')]})()",
      "(()=>{let value=[];value[2]=2;Object.defineProperty(value,'hidden',{value:1});return Object.getOwnPropertyNames(value).join(',')})()"
    ]

    for source <- sources do
      assert_vm_matches_native(runtime, source)
    end
  end

  test "orders integer properties before string insertion order", %{runtime: runtime} do
    sources = [
      "(()=>{let value={second:2};value[4]=4;value.first=1;value[1]=1;return Object.keys(value).join(',')})()",
      "(()=>{let value=[];value[4294967295]=1;return [value.length,Object.keys(value).join(',')]})()"
    ]

    for source <- sources do
      assert_vm_matches_native(runtime, source)
    end
  end

  defp assert_vm_matches_native(runtime, source) do
    assert {:ok, program} = QuickBEAM.VM.compile(source)
    assert {:ok, expected} = QuickBEAM.eval(runtime, "await (#{source})")
    assert {:ok, ^expected} = QuickBEAM.VM.eval(program)
  end
end
