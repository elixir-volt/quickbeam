defmodule QuickBEAM.VM.TestCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      import QuickBEAM.VM.TestCase
    end
  end

  setup do
    {:ok, rt} = QuickBEAM.start()
    %{rt: rt}
  end

  def beam!(rt, code) do
    case QuickBEAM.eval(rt, code, mode: :beam) do
      {:ok, value} ->
        value

      {:error, error} ->
        flunk("Expected BEAM eval success, got #{inspect(error)}")
    end
  end

  def compiler!(rt, code) do
    case QuickBEAM.eval(rt, code, mode: :beam_compiler) do
      {:ok, value} ->
        value

      {:error, error} ->
        flunk("Expected BEAM compiler eval success, got #{inspect(error)}")
    end
  end

  def assert_beam_error(rt, code, name) do
    assert {:error, %QuickBEAM.JS.Error{name: ^name}} =
             QuickBEAM.eval(rt, code, mode: :beam)
  end

  def assert_modes(rt, code, expected) do
    assert beam!(rt, code) == expected
    assert compiler!(rt, code) == expected
  end
end
