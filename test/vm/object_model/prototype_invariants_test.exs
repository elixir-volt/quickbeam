defmodule QuickBEAM.VM.ObjectModel.PrototypeInvariantsTest do
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

    test "#{mode} object literal null prototype special form uses internal prototype" do
      assert {:ok, [true, true]} =
               eval(
                 ~S'''
                 var object = {__proto__: null};
                 [
                   Object.getPrototypeOf(object) === null,
                   Object.getOwnPropertyDescriptor(object, "__proto__") === undefined
                 ];
                 ''',
                 @mode
               )
    end

    test "#{mode} BigInt literal property names work in destructuring" do
      assert {:ok, "foo"} =
               eval(~S|let { 1n: a } = { "1": "foo" }; a|, @mode)
    end

    test "#{mode} setPrototypeOf rejects cycles" do
      assert {:ok, [false, false]} =
               eval(
                 ~S'''
                 var a = {};
                 var b = {};
                 Object.setPrototypeOf(b, a);
                 [Reflect.setPrototypeOf(a, b), Object.getPrototypeOf(a) === b];
                 ''',
                 @mode
               )
    end

    test "#{mode} setPrototypeOf rejects changing non-extensible object prototype" do
      assert {:ok, [false, false]} =
               eval(
                 ~S'''
                 var a = {};
                 var b = {};
                 Object.preventExtensions(a);
                 [Reflect.setPrototypeOf(a, b), Object.getPrototypeOf(a) === b];
                 ''',
                 @mode
               )
    end

    test "#{mode} proxy deleteProperty rejects deleting existing property on non-extensible target" do
      assert {:error, %QuickBEAM.JS.Error{name: "TypeError"}} =
               eval(
                 ~S'''
                 var target = { a: 1 };
                 Object.preventExtensions(target);
                 delete new Proxy(target, { deleteProperty: function() { return true; } }).a;
                 ''',
                 @mode
               )
    end
  end
end
