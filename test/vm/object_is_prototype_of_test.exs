defmodule QuickBEAM.VM.ObjectIsPrototypeOfTest do
  use ExUnit.Case, async: true

  @source ~S'''
  var threw = false;
  try { Object.prototype.isPrototypeOf.call(null, function() {}); } catch (error) { threw = error.constructor === TypeError; }

  var proxyProto = [];
  var proxy = new Proxy({}, {
    getPrototypeOf: function() { return proxyProto; }
  });

  [threw, proxyProto.isPrototypeOf(proxy)];
  '''

  for mode <- [:beam, :beam_compiler] do
    @mode mode

    test "#{mode} Object.prototype.isPrototypeOf handles nullish receiver and proxy argument" do
      {:ok, runtime} = QuickBEAM.start(apis: false)
      assert {:ok, [true, true]} = QuickBEAM.eval(runtime, @source, mode: @mode)
      QuickBEAM.stop(runtime)
    end
  end
end
