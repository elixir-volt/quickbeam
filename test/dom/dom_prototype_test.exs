defmodule QuickBEAM.DOM.DOMPrototypeTest do
  use ExUnit.Case, async: true

  setup do
    {:ok, runtime} = QuickBEAM.start()

    on_exit(fn ->
      try do
        QuickBEAM.stop(runtime)
      catch
        :exit, _ -> :ok
      end
    end)

    %{runtime: runtime}
  end

  describe "Symbol.toStringTag" do
    test "HTMLDivElement", %{runtime: rt} do
      assert {:ok, "[object HTMLDivElement]"} =
               QuickBEAM.eval(rt, "Object.prototype.toString.call(document.createElement('div'))")
    end

    test "HTMLSpanElement", %{runtime: rt} do
      assert {:ok, "[object HTMLSpanElement]"} =
               QuickBEAM.eval(
                 rt,
                 "Object.prototype.toString.call(document.createElement('span'))"
               )
    end

    test "HTMLAnchorElement", %{runtime: rt} do
      assert {:ok, "[object HTMLAnchorElement]"} =
               QuickBEAM.eval(rt, "Object.prototype.toString.call(document.createElement('a'))")
    end

    test "HTMLImageElement", %{runtime: rt} do
      assert {:ok, "[object HTMLImageElement]"} =
               QuickBEAM.eval(rt, "Object.prototype.toString.call(document.createElement('img'))")
    end

    test "HTMLInputElement", %{runtime: rt} do
      assert {:ok, "[object HTMLInputElement]"} =
               QuickBEAM.eval(
                 rt,
                 "Object.prototype.toString.call(document.createElement('input'))"
               )
    end

    test "HTMLUnknownElement for custom tags", %{runtime: rt} do
      assert {:ok, "[object HTMLUnknownElement]"} =
               QuickBEAM.eval(
                 rt,
                 "Object.prototype.toString.call(document.createElement('my-component'))"
               )
    end

    test "generic HTMLElement for semantic tags", %{runtime: rt} do
      assert {:ok, "[object HTMLElement]"} =
               QuickBEAM.eval(rt, "Object.prototype.toString.call(document.createElement('nav'))")
    end

    test "Text node", %{runtime: rt} do
      assert {:ok, "[object Text]"} =
               QuickBEAM.eval(rt, "Object.prototype.toString.call(document.createTextNode('hi'))")
    end

    test "Comment node", %{runtime: rt} do
      assert {:ok, "[object Comment]"} =
               QuickBEAM.eval(rt, "Object.prototype.toString.call(document.createComment('hi'))")
    end

    test "DocumentFragment", %{runtime: rt} do
      assert {:ok, "[object DocumentFragment]"} =
               QuickBEAM.eval(
                 rt,
                 "Object.prototype.toString.call(document.createDocumentFragment())"
               )
    end

    test "Document", %{runtime: rt} do
      assert {:ok, "[object Document]"} =
               QuickBEAM.eval(rt, "Object.prototype.toString.call(document)")
    end
  end

  describe "instanceof" do
    test "div instanceof HTMLElement", %{runtime: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, "document.createElement('div') instanceof HTMLElement")
    end

    test "div instanceof Element", %{runtime: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, "document.createElement('div') instanceof Element")
    end

    test "div instanceof Node", %{runtime: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, "document.createElement('div') instanceof Node")
    end

    test "document instanceof Document", %{runtime: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, "document instanceof Document")
    end

    test "document instanceof Node", %{runtime: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, "document instanceof Node")
    end

    test "text instanceof Text", %{runtime: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, "document.createTextNode('hi') instanceof Text")
    end

    test "text instanceof Node", %{runtime: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, "document.createTextNode('hi') instanceof Node")
    end

    test "fragment instanceof DocumentFragment", %{runtime: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, "document.createDocumentFragment() instanceof DocumentFragment")
    end

    test "comment instanceof Comment", %{runtime: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, "document.createComment('hi') instanceof Comment")
    end

    test "SVGElement instanceof", %{runtime: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg')
               svg instanceof SVGElement && svg instanceof Element && svg instanceof Node
               """)
    end

    test "MathMLElement instanceof", %{runtime: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const math = document.createElementNS('http://www.w3.org/1998/Math/MathML', 'math')
               math instanceof MathMLElement && math instanceof Element
               """)
    end

    test "HTMLElement is not SVGElement", %{runtime: rt} do
      assert {:ok, false} =
               QuickBEAM.eval(rt, "document.createElement('div') instanceof SVGElement")
    end
  end

  describe "constructor globals" do
    test "all constructors are functions", %{runtime: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               [Node, Element, HTMLElement, SVGElement, MathMLElement,
                Document, DocumentFragment, Text, Comment]
                 .every(c => typeof c === 'function')
               """)
    end
  end
end
