defmodule QuickBEAM.WebAPIs.IntlTest do
  use ExUnit.Case, async: true

  setup do
    {:ok, runtime} = QuickBEAM.start()
    %{runtime: runtime}
  end

  test "is included in the default browser APIs", %{runtime: runtime} do
    assert {:ok, %{"intl" => "object", "segmenter" => "function"}} =
             QuickBEAM.eval(runtime, """
             ({
               intl: typeof Intl,
               segmenter: typeof Intl.Segmenter
             })
             """)
  end

  test "can be loaded as a granular API group" do
    {:ok, runtime} = QuickBEAM.start(apis: [:intl])

    assert {:ok, ["é", "🇵🇱"]} =
             QuickBEAM.eval(runtime, """
             [...new Intl.Segmenter().segment('é🇵🇱')].map(({ segment }) => segment)
             """)

    assert {:ok, "undefined"} = QuickBEAM.eval(runtime, "typeof fetch")
  end

  test "is absent from a bare runtime" do
    {:ok, runtime} = QuickBEAM.start(apis: false)
    assert {:ok, "undefined"} = QuickBEAM.eval(runtime, "typeof Intl")
  end

  test "segments extended grapheme clusters and reports UTF-16 indexes", %{runtime: runtime} do
    assert {:ok,
            [
              %{"index" => 0, "input" => "Aé🇵🇱👨‍👩‍👧‍👦", "segment" => "A"},
              %{"index" => 1, "input" => "Aé🇵🇱👨‍👩‍👧‍👦", "segment" => "é"},
              %{"index" => 3, "input" => "Aé🇵🇱👨‍👩‍👧‍👦", "segment" => "🇵🇱"},
              %{"index" => 7, "input" => "Aé🇵🇱👨‍👩‍👧‍👦", "segment" => "👨‍👩‍👧‍👦"}
            ]} =
             QuickBEAM.eval(runtime, "[...new Intl.Segmenter().segment('Aé🇵🇱👨‍👩‍👧‍👦')]")
  end

  test "handles empty input", %{runtime: runtime} do
    assert {:ok, []} = QuickBEAM.eval(runtime, "[...new Intl.Segmenter().segment('')]")
  end

  test "supports containing()", %{runtime: runtime} do
    assert {:ok, %{"index" => 1, "input" => "A🇵🇱B", "segment" => "🇵🇱"}} =
             QuickBEAM.eval(runtime, "new Intl.Segmenter().segment('A🇵🇱B').containing(3)")

    assert {:ok, nil} =
             QuickBEAM.eval(runtime, "new Intl.Segmenter().segment('A🇵🇱B').containing(6)")
  end

  test "reports resolved options", %{runtime: runtime} do
    assert {:ok, %{"granularity" => "grapheme", "locale" => "pl"}} =
             QuickBEAM.eval(runtime, "new Intl.Segmenter('pl').resolvedOptions()")
  end

  test "rejects unsupported granularities", %{runtime: runtime} do
    for granularity <- ~w[word sentence] do
      assert {:error, %QuickBEAM.JSError{name: "TypeError"}} =
               QuickBEAM.eval(
                 runtime,
                 "new Intl.Segmenter('en', { granularity: '#{granularity}' })"
               )
    end
  end
end
