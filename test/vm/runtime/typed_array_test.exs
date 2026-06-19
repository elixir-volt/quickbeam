defmodule QuickBEAM.VM.Runtime.TypedArrayTest do
  use QuickBEAM.VM.TestCase, async: true

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

  test "shared typed-array write invalidation uses byte ranges", %{rt: rt} do
    assert_modes(
      rt,
      ~S|const ab = new ArrayBuffer(8); const u16 = new Uint16Array(ab, 2); const u8 = new Uint8Array(ab); u8[4]; u16[1] = 7; u8[4]|,
      7
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

  test "typed-array methods live on the shared prototype chain", %{rt: rt} do
    assert_modes(
      rt,
      ~S|[Uint8Array.prototype.hasOwnProperty("at"), Object.getPrototypeOf(Uint8Array.prototype).hasOwnProperty("at"), new Uint8Array().hasOwnProperty("values"), typeof Uint8Array.prototype.values].join(",")|,
      "false,true,false,function"
    )
  end

  test "typed-array constructors share the abstract constructor and prototype", %{rt: rt} do
    assert_modes(
      rt,
      ~S|[Object.getPrototypeOf(Uint8Array) === Object.getPrototypeOf(Int8Array), Object.getPrototypeOf(Uint8Array.prototype) === Object.getPrototypeOf(Int8Array.prototype)].join(",")|,
      "true,true"
    )
  end

  test "typed-array ArrayBuffer views validate offsets and lengths", %{rt: rt} do
    assert_modes(
      rt,
      ~S|const ab = new ArrayBuffer(4); [(() => { try { new Uint16Array(ab, 1); } catch (e) { return e.name; } })(), (() => { try { new Uint16Array(ab, 2, 2); } catch (e) { return e.name; } })(), new Uint16Array(ab, 2, 1).length].join(",")|,
      "RangeError,RangeError,1"
    )
  end

  test "typed-array ArrayBuffer view length distinguishes omitted and null", %{rt: rt} do
    assert_modes(
      rt,
      ~S|const ab = new ArrayBuffer(3); [new Uint16Array(ab, 0, null).length, (() => { try { new Uint16Array(ab); return "ok"; } catch (e) { return e.name; } })()].join(",")|,
      "0,RangeError"
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

  test "typed-array primitive constructor length uses ToIndex", %{rt: rt} do
    assert_modes(
      rt,
      ~S|[new Uint8Array("3").length, new Uint8Array(true).length, new Uint8Array(1.9).length, (() => { try { new Uint8Array(-1); return "ok"; } catch (e) { return e.name; } })()].join(",")|,
      "3,1,1,RangeError"
    )
  end

  test "typed-array metadata slots are not own properties until explicitly defined", %{rt: rt} do
    assert_modes(
      rt,
      ~S|let a = new Uint8Array(2); let before = [Object.hasOwn(a, "length"), Reflect.set(a, "length", 9), a.length, Object.getOwnPropertyDescriptor(a, "length")]; let defined = Reflect.defineProperty(a, "length", {value: 9}); let desc = Object.getOwnPropertyDescriptor(a, "length"); before.concat([defined, a.length, Object.hasOwn(a, "length"), desc.value]).join(",")|,
      "false,false,2,,true,9,true,9"
    )
  end

  test "typed-array integer-indexed keys do not fall back to ordinary properties", %{rt: rt} do
    assert_modes(
      rt,
      ~S|let a = new Uint8Array([5]); a["-1"] = 9; a["-0"] = 8; a["4294967295"] = 7; [a[0], a["-1"], a["-0"], a["4294967295"], Object.prototype.hasOwnProperty.call(a, "-1")].join(",")|,
      "5,,,,false"
    )
  end

  test "typed-array delete and defineProperty obey integer-indexed element rules", %{rt: rt} do
    assert_modes(
      rt,
      ~S|let a = new Uint8Array([5]); let del = delete a[0]; Object.defineProperty(a, "0", {value: null}); let afterNull = a[0]; let bad = (() => { try { Object.defineProperty(a, "0", {get(){return 1}}); return "ok"; } catch (e) { return e.name; } })(); [del, afterNull, bad].join(",")|,
      "false,0,TypeError"
    )
  end
end
