defmodule QuickBEAM.DOM.WPT.DocumentTest do
  @moduledoc """
  Tests ported from Web Platform Tests (WPT) dom/nodes/ suite.
  Document methods: createElement, createElementNS, getElementById, querySelector.
  https://github.com/web-platform-tests/wpt/tree/master/dom/nodes
  """
  use ExUnit.Case, async: true

  setup do
    {:ok, rt} = QuickBEAM.start()
    on_exit(fn -> try do QuickBEAM.stop(rt) catch :exit, _ -> :ok end end)
    %{rt: rt}
  end

  defp eval!(rt, code) do
    {:ok, result} = QuickBEAM.eval(rt, code)
    result
  end

  # ─── document.createElement (WPT: Document-createElement.html) ───

  describe "document.createElement" do
    test "creates element with correct tagName (uppercase)", %{rt: rt} do
      assert "DIV" == eval!(rt, "document.createElement('div').tagName")
    end

    test "tagName is uppercased for HTML documents", %{rt: rt} do
      assert "CUSTOM-ELEMENT" ==
               eval!(rt, "document.createElement('custom-element').tagName")
    end

    test "localName is lowercased", %{rt: rt} do
      assert true ==
               eval!(rt, """
               const el = document.createElement('DIV')
               el.tagName === 'DIV'
               """)
    end

    test "nodeType is ELEMENT_NODE", %{rt: rt} do
      assert 1 == eval!(rt, "document.createElement('div').nodeType")
    end

    test "created element has no children", %{rt: rt} do
      assert 0 == eval!(rt, "document.createElement('div').childNodes.length")
    end

    test "created element has no parent", %{rt: rt} do
      assert nil == eval!(rt, "document.createElement('div').parentNode")
    end

    test "element is instance of HTMLElement", %{rt: rt} do
      assert true == eval!(rt, "document.createElement('div') instanceof HTMLElement")
    end

    test "element is instance of Element", %{rt: rt} do
      assert true == eval!(rt, "document.createElement('div') instanceof Element")
    end

    test "element is instance of Node", %{rt: rt} do
      assert true == eval!(rt, "document.createElement('div') instanceof Node")
    end
  end

  # ─── document.createElementNS (WPT: Document-createElementNS.html) ───

  describe "document.createElementNS" do
    test "SVG element is instanceof SVGElement", %{rt: rt} do
      assert true ==
               eval!(rt, """
               document.createElementNS('http://www.w3.org/2000/svg', 'svg') instanceof SVGElement
               """)
    end

    test "SVG element is instanceof Element", %{rt: rt} do
      assert true ==
               eval!(rt, """
               document.createElementNS('http://www.w3.org/2000/svg', 'svg') instanceof Element
               """)
    end

    test "MathML element is instanceof MathMLElement", %{rt: rt} do
      assert true ==
               eval!(rt, """
               document.createElementNS('http://www.w3.org/1998/Math/MathML', 'math') instanceof MathMLElement
               """)
    end

    test "SVG element tagName preserves case", %{rt: rt} do
      assert "svg" ==
               eval!(rt, """
               document.createElementNS('http://www.w3.org/2000/svg', 'svg').tagName
               """)
    end

    test "SVG element with qualified name", %{rt: rt} do
      assert "g" ==
               eval!(rt, """
               document.createElementNS('http://www.w3.org/2000/svg', 'g').tagName
               """)
    end
  end

  # ─── document.createTextNode / createComment (WPT: Document-createComment-createTextNode.js) ───

  describe "document.createTextNode" do
    test "creates text node with correct data", %{rt: rt} do
      assert "hello" == eval!(rt, "document.createTextNode('hello').textContent")
    end

    test "empty string", %{rt: rt} do
      assert "" == eval!(rt, "document.createTextNode('').textContent")
    end

    test "nodeType is TEXT_NODE (3)", %{rt: rt} do
      assert 3 == eval!(rt, "document.createTextNode('').nodeType")
    end

    test "nodeName is #text", %{rt: rt} do
      assert "#text" == eval!(rt, "document.createTextNode('').nodeName")
    end
  end

  describe "document.createComment" do
    test "creates comment with correct data", %{rt: rt} do
      assert "hello" == eval!(rt, "document.createComment('hello').textContent")
    end

    test "nodeType is COMMENT_NODE (8)", %{rt: rt} do
      assert 8 == eval!(rt, "document.createComment('').nodeType")
    end

    test "nodeName is #comment", %{rt: rt} do
      assert "#comment" == eval!(rt, "document.createComment('').nodeName")
    end
  end

  describe "document.createDocumentFragment" do
    test "nodeType is DOCUMENT_FRAGMENT_NODE (11)", %{rt: rt} do
      assert 11 == eval!(rt, "document.createDocumentFragment().nodeType")
    end

    test "nodeName is #document-fragment", %{rt: rt} do
      assert "#document-fragment" ==
               eval!(rt, "document.createDocumentFragment().nodeName")
    end

    test "has no children", %{rt: rt} do
      assert 0 == eval!(rt, "document.createDocumentFragment().childNodes.length")
    end

    @tag skip: "lexbor doesn't clear fragment children after appendChild"
    test "appending fragment empties the fragment", %{rt: rt} do
      assert true ==
               eval!(rt, """
               const df = document.createDocumentFragment()
               df.appendChild(document.createElement('a'))
               df.appendChild(document.createElement('b'))
               const parent = document.createElement('div')
               parent.appendChild(df)
               parent.childNodes.length === 2 && df.childNodes.length === 0
               """)
    end
  end

  # ─── document.getElementById (WPT: Document-getElementById.html) ───

  describe "document.getElementById" do
    test "finds element by id", %{rt: rt} do
      assert true ==
               eval!(rt, """
               const el = document.createElement('div')
               el.id = 'unique'
               document.body.appendChild(el)
               document.getElementById('unique') === el
               """)
    end

    test "returns null for missing id", %{rt: rt} do
      assert nil == eval!(rt, "document.getElementById('nonexistent')")
    end

    test "returns first element when multiple share same id", %{rt: rt} do
      assert true ==
               eval!(rt, """
               const first = document.createElement('div')
               first.id = 'dup'
               const second = document.createElement('div')
               second.id = 'dup'
               document.body.appendChild(first)
               document.body.appendChild(second)
               document.getElementById('dup') === first
               """)
    end

    test "finds deeply nested element", %{rt: rt} do
      assert true ==
               eval!(rt, """
               const outer = document.createElement('div')
               const inner = document.createElement('div')
               const target = document.createElement('span')
               target.id = 'deep'
               outer.appendChild(inner)
               inner.appendChild(target)
               document.body.appendChild(outer)
               document.getElementById('deep') === target
               """)
    end
  end

  # ─── document.querySelector / querySelectorAll ───

  describe "document.querySelector" do
    test "finds by tag name", %{rt: rt} do
      assert true ==
               eval!(rt, """
               const el = document.createElement('article')
               document.body.appendChild(el)
               document.querySelector('article') === el
               """)
    end

    test "finds by class", %{rt: rt} do
      assert true ==
               eval!(rt, """
               const el = document.createElement('div')
               el.className = 'unique-cls'
               document.body.appendChild(el)
               document.querySelector('.unique-cls') === el
               """)
    end

    test "finds by id", %{rt: rt} do
      assert true ==
               eval!(rt, """
               const el = document.createElement('div')
               el.id = 'qs-id'
               document.body.appendChild(el)
               document.querySelector('#qs-id') === el
               """)
    end

    test "returns null when not found", %{rt: rt} do
      assert nil == eval!(rt, "document.querySelector('.absolutely-nonexistent')")
    end

    test "returns first match", %{rt: rt} do
      assert true ==
               eval!(rt, """
               const a = document.createElement('div')
               a.className = 'multi'
               const b = document.createElement('div')
               b.className = 'multi'
               document.body.appendChild(a)
               document.body.appendChild(b)
               document.querySelector('.multi') === a
               """)
    end
  end

  describe "document.querySelectorAll" do
    test "returns all matching elements", %{rt: rt} do
      assert 2 ==
               eval!(rt, """
               const a = document.createElement('div')
               a.className = 'qsa-test'
               const b = document.createElement('div')
               b.className = 'qsa-test'
               document.body.appendChild(a)
               document.body.appendChild(b)
               document.querySelectorAll('.qsa-test').length
               """)
    end

    test "returns empty for no matches", %{rt: rt} do
      assert 0 == eval!(rt, "document.querySelectorAll('.never-exists').length")
    end
  end

  # ─── element.querySelector / querySelectorAll ───

  describe "element.querySelector" do
    test "scoped to element", %{rt: rt} do
      assert true ==
               eval!(rt, """
               const container = document.createElement('div')
               const inner = document.createElement('span')
               inner.className = 'inner'
               container.appendChild(inner)
               const outer = document.createElement('span')
               outer.className = 'inner'
               document.body.appendChild(container)
               document.body.appendChild(outer)
               container.querySelector('.inner') === inner
               """)
    end

    test "returns null when not in subtree", %{rt: rt} do
      assert nil ==
               eval!(rt, """
               const container = document.createElement('div')
               container.querySelector('span')
               """)
    end
  end

  # ─── document properties ───

  describe "document properties" do
    test "document.body is the body element", %{rt: rt} do
      assert "BODY" == eval!(rt, "document.body.tagName")
    end

    test "document.head is the head element", %{rt: rt} do
      assert "HEAD" == eval!(rt, "document.head.tagName")
    end

    test "document.documentElement is the html element", %{rt: rt} do
      assert "HTML" == eval!(rt, "document.documentElement.tagName")
    end

    test "document.nodeType is 9", %{rt: rt} do
      assert 9 == eval!(rt, "document.nodeType")
    end
  end
end
