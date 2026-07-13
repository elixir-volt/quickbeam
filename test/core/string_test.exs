defmodule QuickBEAM.StringTest do
  use ExUnit.Case, async: true

  setup do
    {:ok, runtime} = QuickBEAM.start()
    %{runtime: runtime}
  end

  test "normalizes an empty string repeatedly in every Unicode normalization form", %{
    runtime: runtime
  } do
    for _ <- 1..10, form <- ~w[NFC NFD NFKC NFKD] do
      assert {:ok, ""} = QuickBEAM.eval(runtime, ~s/"".normalize("#{form}")/)
    end
  end

  test "normalizes empty strings in concurrent runtimes" do
    1..16
    |> Task.async_stream(
      fn _ ->
        {:ok, runtime} = QuickBEAM.start()
        QuickBEAM.eval(runtime, ~s/"".normalize("NFC")/)
      end,
      max_concurrency: 16
    )
    |> Enum.each(fn result -> assert {:ok, {:ok, ""}} = result end)
  end

  test "normalizes non-empty strings", %{runtime: runtime} do
    assert {:ok, "é"} = QuickBEAM.eval(runtime, ~s/"e\\u0301".normalize("NFC")/)
    assert {:ok, "é"} = QuickBEAM.eval(runtime, ~s/"é".normalize("NFD")/)
    assert {:ok, "HfiA"} = QuickBEAM.eval(runtime, ~s/"ℌﬁＡ".normalize("NFKC")/)
    assert {:ok, "HfiA"} = QuickBEAM.eval(runtime, ~s/"ℌﬁＡ".normalize("NFKD")/)
  end
end
