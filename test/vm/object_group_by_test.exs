defmodule QuickBEAM.VM.ObjectGroupByTest do
  use ExUnit.Case, async: true

  @source ~S'''
  var calls = [];
  var grouped = Object.groupBy([1, 2, 3], function(value, index) {
    calls.push([value, index]);
    return value % 2 === 0 ? 'even' : 'odd';
  });

  [
    Object.getPrototypeOf(grouped),
    grouped.hasOwnProperty,
    grouped.odd.join(','),
    grouped.even.join(','),
    calls[0].join(','),
    calls[2].join(',')
  ];
  '''

  for mode <- [:beam, :beam_compiler] do
    @mode mode

    test "#{mode} Object.groupBy groups iterable values into a null-prototype object" do
      {:ok, runtime} = QuickBEAM.start(apis: false)

      assert {:ok, [nil, nil, "1,3", "2", "1,0", "3,2"]} =
               QuickBEAM.eval(runtime, @source, mode: @mode)

      QuickBEAM.stop(runtime)
    end
  end
end
