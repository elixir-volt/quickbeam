defmodule QuickBEAM.VM.ObjectToStringTagTest do
  use ExUnit.Case, async: true

  @source ~S'''
  var proxyArray = new Proxy([], {});
  var proxyFunction = new Proxy(function() {}, {});
  var big = 3n;
  var boxedBig = Object(3n);

  Object.defineProperty(BigInt.prototype, Symbol.toStringTag, { value: "BigInt", configurable: true });
  var defaultBig = Object.prototype.toString.call(big);
  var defaultBoxedBig = Object.prototype.toString.call(boxedBig);

  [
    Object.prototype.toString.call(proxyArray),
    Object.prototype.toString.call(proxyFunction),
    defaultBig,
    defaultBoxedBig
  ];
  '''

  for mode <- [:beam, :beam_compiler] do
    @mode mode

    test "#{mode} Object.prototype.toString handles proxies and BigInt tags" do
      {:ok, runtime} = QuickBEAM.start(apis: false)

      assert {:ok,
              [
                "[object Array]",
                "[object Function]",
                "[object BigInt]",
                "[object BigInt]"
              ]} = QuickBEAM.eval(runtime, @source, mode: @mode)

      QuickBEAM.stop(runtime)
    end
  end
end
