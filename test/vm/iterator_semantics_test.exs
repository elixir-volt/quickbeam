defmodule QuickBEAM.VM.IteratorSemanticsTest do
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

    test "#{mode} for-of does not treat next-only objects as iterable" do
      assert {:error, %QuickBEAM.JS.Error{name: "TypeError"}} =
               eval(
                 ~S|for (var value of { next: function() { return { done: true }; } }) {}|,
                 @mode
               )
    end

    test "#{mode} iterator result and return result may be callable objects" do
      assert {:ok, [1]} =
               eval(
                 ~S'''
                 var result = function() {};
                 result.value = 1;
                 result.done = false;
                 var returnResult = function() {};
                 var iterator = {
                   count: 0,
                   next: function() {
                     this.count++;
                     return this.count === 1 ? result : { done: true };
                   },
                   return: function() { return returnResult; },
                   [Symbol.iterator]: function() { return this; }
                 };
                 var out = [];
                 for (var value of iterator) { out.push(value); break; }
                 out;
                 ''',
                 @mode
               )
    end

    test "#{mode} Object.fromEntries closes iterator when next result is not object" do
      assert {:ok, true} =
               eval(
                 ~S'''
                 var closed = false;
                 var iterator = {
                   next: function() { return 1; },
                   return: function() { closed = true; return {}; }
                 };
                 var iterable = { [Symbol.iterator]: function() { return iterator; } };
                 try { Object.fromEntries(iterable); } catch (_) {}
                 closed;
                 ''',
                 @mode
               )
    end
  end
end
