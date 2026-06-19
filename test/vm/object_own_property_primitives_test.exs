defmodule QuickBEAM.VM.ObjectOwnPropertyPrimitivesTest do
  use ExUnit.Case, async: true

  @source ~S'''
  var indexDesc = Object.getOwnPropertyDescriptor('foo', '0');
  var lengthDesc = Object.getOwnPropertyDescriptor('foo', 'length');
  var names = Object.getOwnPropertyNames('ab').join(',');
  var descriptors = Object.getOwnPropertyDescriptors('ab');
  var threwNames = false;
  var threwDescriptors = false;
  var threwSymbols = false;

  try { Object.getOwnPropertyNames(undefined); } catch (e) { threwNames = e.constructor === TypeError; }
  try { Object.getOwnPropertyDescriptors(null); } catch (e) { threwDescriptors = e.constructor === TypeError; }
  try { Object.getOwnPropertySymbols(undefined); } catch (e) { threwSymbols = e.constructor === TypeError; }

  [
    indexDesc.value,
    indexDesc.writable,
    indexDesc.enumerable,
    indexDesc.configurable,
    lengthDesc.value,
    names,
    descriptors[0].value,
    descriptors.length.value,
    threwNames,
    threwDescriptors,
    threwSymbols
  ];
  '''

  for mode <- [:beam, :beam_compiler] do
    @mode mode

    test "#{mode} Object own-property APIs coerce string primitives and reject nullish" do
      {:ok, runtime} = QuickBEAM.start(apis: false)

      assert {:ok, ["f", false, true, false, 3, "0,1,length", "a", 2, true, true, true]} =
               QuickBEAM.eval(runtime, @source, mode: @mode)

      QuickBEAM.stop(runtime)
    end
  end
end
