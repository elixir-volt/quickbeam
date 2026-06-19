defmodule QuickBEAM.VM.ObjectRefactorSemanticsTest do
  use ExUnit.Case, async: true

  defp eval(source, mode) do
    {:ok, runtime} = QuickBEAM.start(apis: false)

    try do
      QuickBEAM.eval(runtime, source, mode: mode)
    after
      QuickBEAM.stop(runtime)
    end
  end

  for mode <- [:beam, :beam_compiler] do
    @mode mode

    test "#{mode} Object.assign throws when proxy target set returns false" do
      assert {:error, %QuickBEAM.JS.Error{name: "TypeError"}} =
               eval(
                 ~S'''
                 var target = new Proxy({}, { set: function() { return false; } });
                 Object.assign(target, { a: 1 });
                 ''',
                 @mode
               )
    end

    test "#{mode} Object.assign reads proxy enumerable keys through internal methods" do
      assert {:ok, [1, ["ownKeys", "desc:a", "get:a"]]} =
               eval(
                 ~S'''
                 var log = [];
                 var source = new Proxy({ a: 1 }, {
                   ownKeys: function(target) { log.push("ownKeys"); return Reflect.ownKeys(target); },
                   getOwnPropertyDescriptor: function(target, key) {
                     log.push("desc:" + key);
                     return Reflect.getOwnPropertyDescriptor(target, key);
                   },
                   get: function(target, key, receiver) {
                     log.push("get:" + key);
                     return Reflect.get(target, key, receiver);
                   }
                 });
                 var out = Object.assign({}, source);
                 [out.a, log];
                 ''',
                 @mode
               )
    end

    test "#{mode} Object.defineProperties collects descriptors before mutating target" do
      assert {:ok, false} =
               eval(
                 ~S'''
                 var target = {};
                 var props = {};
                 Object.defineProperty(props, "a", { enumerable: true, value: { value: 1 } });
                 Object.defineProperty(props, "b", {
                   enumerable: true,
                   get: function() { throw new Error("boom"); }
                 });
                 try { Object.defineProperties(target, props); } catch (_) {}
                 Object.prototype.hasOwnProperty.call(target, "a");
                 ''',
                 @mode
               )
    end

    test "#{mode} Object.defineProperties includes enumerable symbol descriptor keys" do
      assert {:ok, true} =
               eval(
                 ~S'''
                 var key = Symbol("k");
                 var target = {};
                 var props = {};
                 props[key] = { value: 42, enumerable: true };
                 Object.defineProperties(target, props);
                 target[key] === 42;
                 ''',
                 @mode
               )
    end

    test "#{mode} Object statics handle missing argument as undefined" do
      assert {:ok, [true, false, true, true, true]} =
               eval(
                 ~S'''
                 [
                   Object.freeze() === undefined,
                   Object.isExtensible(),
                   Object.isFrozen(),
                   Object.isSealed(),
                   Object.preventExtensions() === undefined && Object.seal() === undefined
                 ];
                 ''',
                 @mode
               )
    end

    test "#{mode} Object.getOwnPropertyDescriptor requires an object argument" do
      assert {:error, %QuickBEAM.JS.Error{name: "TypeError"}} =
               eval("Object.getOwnPropertyDescriptor();", @mode)
    end

    test "#{mode} Object.entries excludes enumerable symbol keys on callables" do
      assert {:ok, []} =
               eval(
                 ~S'''
                 var f = function() {};
                 f[Symbol("x")] = 1;
                 Object.entries(f);
                 ''',
                 @mode
               )
    end

    test "#{mode} Object.fromEntries accepts wrapped string entry objects" do
      assert {:ok, %{"a" => "b"}} =
               eval(~S|Object.fromEntries([new String("ab")]);|, @mode)
    end

    test "#{mode} Object.defineProperty normalizes callable numeric keys" do
      assert {:ok, true} =
               eval(
                 ~S'''
                 var f = function() {};
                 Object.defineProperty(f, 0, { value: 7, configurable: true });
                 f[0] === 7 && Object.getOwnPropertyDescriptor(f, "0").value === 7;
                 ''',
                 @mode
               )
    end

    test "#{mode} Object.seal reports callable properties as non-configurable" do
      assert {:ok, false} =
               eval(
                 ~S'''
                 var f = function() {};
                 f.x = 1;
                 Object.seal(f);
                 Object.getOwnPropertyDescriptor(f, "x").configurable;
                 ''',
                 @mode
               )
    end
  end
end
