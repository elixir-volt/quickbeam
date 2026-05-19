defmodule QuickBEAM.VM.Runtime.DataViewTest do
  use QuickBEAM.VM.TestCase, async: true

  test "BigInt setters reject Number values", %{rt: rt} do
    assert beam!(rt, """
           let view = new DataView(new ArrayBuffer(8));
           try { view.setBigInt64(0, 1); false; }
           catch (e) { e instanceof TypeError; }
           """) == true
  end

  test "ToIndex rejects BigInt and coerced infinities", %{rt: rt} do
    assert beam!(
             rt,
             ~S|let view = new DataView(new ArrayBuffer(8)); try { view.getInt8("Infinity"); "ok"; } catch (e) { e.name; }|
           ) == "RangeError"

    assert beam!(
             rt,
             ~S|let view = new DataView(new ArrayBuffer(8)); try { view.getInt8(1n); "ok"; } catch (e) { e.name; }|
           ) == "TypeError"

    assert beam!(
             rt,
             ~S|try { new DataView(new ArrayBuffer(8), 1n); "ok"; } catch (e) { e.name; }|
           ) == "TypeError"
  end

  test "BigInt setters coerce Boolean, string, and object values with ToBigInt", %{rt: rt} do
    assert beam!(
             rt,
             ~S|let view = new DataView(new ArrayBuffer(24)); view.setBigInt64(0, true); view.setBigInt64(8, { valueOf() { return 2n; } }); view.setBigInt64(16, ""); [view.getUint8(7), view.getUint8(15), view.getUint8(23)].join(",")|
           ) == "1,2,0"
  end
end
