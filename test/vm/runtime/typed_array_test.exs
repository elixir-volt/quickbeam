defmodule QuickBEAM.VM.Runtime.TypedArrayTest do
  use QuickBEAM.VMCase, async: true

  test "for-of reads typed-array elements live during iteration", %{rt: rt} do
    assert_modes(
      rt,
      ~S|var array = new Int8Array([3, 2, 4, 1]); var out = []; for (var value of array) { out.push(value); array[1] = 64; } out.join(",")|,
      "3,64,4,1"
    )
  end

  test "defineProperty treats integer-index keys beyond array-index range as typed-array indexes",
       %{
         rt: rt
       } do
    assert_modes(
      rt,
      ~S|let a = new Uint8Array(1); try { Object.defineProperty(a, "4294967295", {value: 1}); "ok"; } catch (e) { e.name; }|,
      "TypeError"
    )
  end
end
