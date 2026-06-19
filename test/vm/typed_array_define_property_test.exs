defmodule QuickBEAM.VM.TypedArrayDefinePropertyTest do
  use ExUnit.Case, async: true

  @source ~S'''
  var rab = new ArrayBuffer(4, { maxByteLength: 8 });
  var fixed = new Uint8Array(rab, 0, 4);
  var tracking = new Uint8Array(rab, 0);

  Object.defineProperties(fixed, {"0": {value: 1}});
  Object.defineProperties(tracking, {"1": {value: 2}});

  rab.resize(2);

  var fixedThrew = false;
  try {
    Object.defineProperties(fixed, {"0": {value: 3}});
  } catch (error) {
    fixedThrew = error.constructor === TypeError;
  }

  Object.defineProperties(tracking, {"1": {value: 4}});

  var trackingThrew = false;
  try {
    Object.defineProperties(tracking, {"2": {value: 5}});
  } catch (error) {
    trackingThrew = error.constructor === TypeError;
  }

  [fixedThrew, tracking[1], trackingThrew];
  '''

  for mode <- [:beam, :beam_compiler] do
    @mode mode

    test "#{mode} typed array defineProperties rejects out-of-bounds resizable views" do
      {:ok, runtime} = QuickBEAM.start(apis: false)
      assert {:ok, [true, 4, true]} = QuickBEAM.eval(runtime, @source, mode: @mode)
      QuickBEAM.stop(runtime)
    end
  end
end
