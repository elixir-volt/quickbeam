defmodule QuickBEAM.VM.Compiler.ArgumentsTest do
  use QuickBEAM.VM.TestCase, async: true

  test "compiled arguments object is iterable in spread and for-of", %{rt: rt} do
    assert compiler!(rt, "function f(){ return [...arguments].join(','); } f(1,2,3)") == "1,2,3"

    assert compiler!(
             rt,
             "function f(){ let r=[]; for (let x of arguments) r.push(x); return r.join(','); } f(1,2,3)"
           ) == "1,2,3"
  end

  test "compiled sloppy arguments iteration observes parameter aliasing", %{rt: rt} do
    assert compiler!(
             rt,
             ~S|(function(a, b, c) { var out = []; for (var value of arguments) { a = b; b = c; c = out.length; out.push(value); } return out.join(","); })(1, 2, 3)|
           ) == "1,3,1"
  end
end
