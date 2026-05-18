defmodule QuickBEAM.VM.Runtime.TypedArrayTest do
  use QuickBEAM.VMCase, async: true

  test "for-of reads typed-array elements live during iteration", %{rt: rt} do
    assert_modes(
      rt,
      ~S|var array = new Int8Array([3, 2, 4, 1]); var out = []; for (var value of array) { out.push(value); array[1] = 64; } out.join(",")|,
      "3,64,4,1"
    )
  end

  test "typed-array views observe writes through shared resizable buffers", %{rt: rt} do
    assert_modes(
      rt,
      ~S|var rab = new ArrayBuffer(10, { maxByteLength: 20 }); var ta = new Uint8Array(rab); for (var i = 0; i < 10; i++) ta[i] = i; var fixed = new Uint8Array(rab, 0, 3); var offset = new Uint8Array(rab, 2, 3); [fixed[1], offset[0]].join(",")|,
      "1,2"
    )
  end

  test "TypedArray.prototype.at reads relative elements", %{rt: rt} do
    assert_modes(
      rt,
      ~S|[new Uint8Array([1, 2, 3]).at(-1), new Float64Array([0, , 2]).at(1)].join(",")|,
      "3,NaN"
    )
  end

  test "TypedArray.prototype.at validates borrowed receivers and BigInt indices", %{rt: rt} do
    assert_modes(
      rt,
      ~S|const a = new Uint8Array([10]); const b = new Uint8Array([20]); [a.at.call(b, 0), (() => { try { a.at.call({}, 0); } catch (e) { return e.name; } })(), (() => { try { a.at(0n); } catch (e) { return e.name; } })()].join(",")|,
      "20,TypeError,TypeError"
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
