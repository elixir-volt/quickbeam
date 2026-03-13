defmodule QuickBEAM.DOM.WPT.ElementTest do
  @moduledoc """
  Tests ported from Web Platform Tests (WPT) dom/nodes/ suite.
  Element-level APIs: closest, matches, attributes, classList, children.
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

  # ─── Element.closest (WPT: Element-closest.html) ───

  describe "Element.closest" do
    test "closest finds self by class", %{rt: rt} do
      assert eval!(rt, """
             (() => {
               const div = document.createElement('div')
               div.className = 'target'
               document.body.appendChild(div)
               return div.closest('.target') !== null
             })()
             """)
    end

    test "closest traverses ancestors", %{rt: rt} do
      assert "outer" ==
               eval!(rt, """
               (() => {
                 const outer = document.createElement('div')
                 outer.className = 'outer'
                 outer.id = 'outer'
                 const inner = document.createElement('span')
                 outer.appendChild(inner)
                 document.body.appendChild(outer)
                 const found = inner.closest('.outer')
                 return found ? found.id : null
               })()
               """)
    end

    test "closest returns null when no match", %{rt: rt} do
      assert nil ==
               eval!(rt, """
               (() => {
                 const div = document.createElement('div')
                 document.body.appendChild(div)
                 return div.closest('.nonexistent')
               })()
               """)
    end

    test "closest with compound selector", %{rt: rt} do
      assert "myid" ==
               eval!(rt, """
               (() => {
                 const outer = document.createElement('div')
                 outer.id = 'myid'
                 outer.className = 'myclass'
                 const inner = document.createElement('span')
                 outer.appendChild(inner)
                 document.body.appendChild(outer)
                 const found = inner.closest('div#myid.myclass')
                 return found ? found.id : null
               })()
               """)
    end

    test "closest with tag selector", %{rt: rt} do
      assert eval!(rt, """
             (() => {
               const div = document.createElement('div')
               div.id = 'ct-div'
               const span = document.createElement('span')
               div.appendChild(span)
               document.body.appendChild(div)
               const found = span.closest('div')
               return found !== null && found.id === 'ct-div'
             })()
             """)
    end
  end

  # ─── Element.matches (WPT: Element-matches.html) ───

  describe "Element.matches" do
    test "matches by class", %{rt: rt} do
      assert eval!(rt, """
             (() => {
               const el = document.createElement('div')
               el.className = 'foo bar'
               document.body.appendChild(el)
               return el.matches('.foo')
             })()
             """)
    end

    test "matches by id", %{rt: rt} do
      assert eval!(rt, """
             (() => {
               const el = document.createElement('div')
               el.id = 'match-test'
               document.body.appendChild(el)
               return el.matches('#match-test')
             })()
             """)
    end

    test "matches by tag", %{rt: rt} do
      assert eval!(rt, """
             (() => {
               const el = document.createElement('span')
               document.body.appendChild(el)
               return el.matches('span')
             })()
             """)
    end

    test "no match returns false", %{rt: rt} do
      refute eval!(rt, """
             (() => {
               const el = document.createElement('div')
               document.body.appendChild(el)
               return el.matches('span')
             })()
             """)
    end

    test "matches with compound selector", %{rt: rt} do
      assert eval!(rt, """
             (() => {
               const el = document.createElement('div')
               el.className = 'active'
               el.id = 'main-match'
               document.body.appendChild(el)
               return el.matches('div#main-match.active')
             })()
             """)
    end
  end

  # ─── Element attributes (WPT: attributes.html) ───

  describe "Element attributes" do
    test "getAttribute returns null for missing attribute", %{rt: rt} do
      assert nil == eval!(rt, "document.createElement('div').getAttribute('x')")
    end

    test "setAttribute and getAttribute round-trip", %{rt: rt} do
      assert "bar" ==
               eval!(rt, """
               (() => {
                 const el = document.createElement('div')
                 el.setAttribute('foo', 'bar')
                 return el.getAttribute('foo')
               })()
               """)
    end

    test "hasAttribute returns false before set", %{rt: rt} do
      refute eval!(rt, "document.createElement('div').hasAttribute('foo')")
    end

    test "hasAttribute returns true after set", %{rt: rt} do
      assert eval!(rt, """
             (() => {
               const el = document.createElement('div')
               el.setAttribute('foo', 'bar')
               return el.hasAttribute('foo')
             })()
             """)
    end

    test "removeAttribute removes the attribute", %{rt: rt} do
      refute eval!(rt, """
            (() => {
              const el = document.createElement('div')
              el.setAttribute('foo', 'bar')
              el.removeAttribute('foo')
              return el.hasAttribute('foo')
            })()
            """)
    end

    test "setAttribute overwrites existing value", %{rt: rt} do
      assert "new" ==
               eval!(rt, """
               (() => {
                 const el = document.createElement('div')
                 el.setAttribute('foo', 'old')
                 el.setAttribute('foo', 'new')
                 return el.getAttribute('foo')
               })()
               """)
    end

    test "id property reflects id attribute", %{rt: rt} do
      assert "myid" ==
               eval!(rt, """
               (() => {
                 const el = document.createElement('div')
                 el.setAttribute('id', 'myid')
                 return el.id
               })()
               """)
    end

    test "className property reflects class attribute", %{rt: rt} do
      assert "a b" ==
               eval!(rt, """
               (() => {
                 const el = document.createElement('div')
                 el.setAttribute('class', 'a b')
                 return el.className
               })()
               """)
    end

    test "setting id reflects to getAttribute", %{rt: rt} do
      assert "test" ==
               eval!(rt, """
               (() => {
                 const el = document.createElement('div')
                 el.id = 'test'
                 return el.getAttribute('id')
               })()
               """)
    end
  end

  # ─── Element.classList (WPT: Element-classlist.html) ───

  describe "Element.classList" do
    test "add a class", %{rt: rt} do
      assert eval!(rt, """
             (() => {
               const el = document.createElement('div')
               el.classList.add('foo')
               return el.classList.contains('foo')
             })()
             """)
    end

    test "remove a class", %{rt: rt} do
      refute eval!(rt, """
            (() => {
              const el = document.createElement('div')
              el.classList.add('foo')
              el.classList.remove('foo')
              return el.classList.contains('foo')
            })()
            """)
    end

    test "toggle adds when absent", %{rt: rt} do
      assert eval!(rt, """
             (() => {
               const el = document.createElement('div')
               el.classList.toggle('foo')
               return el.classList.contains('foo')
             })()
             """)
    end

    test "toggle removes when present", %{rt: rt} do
      refute eval!(rt, """
            (() => {
              const el = document.createElement('div')
              el.classList.add('foo')
              el.classList.toggle('foo')
              return el.classList.contains('foo')
            })()
            """)
    end

    test "classList reflects on className", %{rt: rt} do
      assert "a b" ==
               eval!(rt, """
               (() => {
                 const el = document.createElement('div')
                 el.classList.add('a')
                 el.classList.add('b')
                 return el.className
               })()
               """)
    end

    test "classList.length", %{rt: rt} do
      assert 2 ==
               eval!(rt, """
               (() => {
                 const el = document.createElement('div')
                 el.classList.add('a', 'b')
                 return el.classList.length
               })()
               """)
    end
  end

  # ─── Element.children (WPT: Element-children.html) ───

  describe "Element.children" do
    test "empty element has no children", %{rt: rt} do
      assert 0 == eval!(rt, "document.createElement('div').children.length")
    end

    test "children only includes element children", %{rt: rt} do
      assert [1, "SPAN"] ==
               eval!(rt, """
               (() => {
                 const parent = document.createElement('div')
                 parent.appendChild(document.createTextNode('text'))
                 parent.appendChild(document.createElement('span'))
                 parent.appendChild(document.createComment('c'))
                 return [parent.children.length, parent.children[0].tagName]
               })()
               """)
    end

    test "children order matches append order", %{rt: rt} do
      assert "A,B,C" ==
               eval!(rt, """
               (() => {
                 const parent = document.createElement('div')
                 parent.appendChild(document.createElement('a'))
                 parent.appendChild(document.createElement('b'))
                 parent.appendChild(document.createElement('c'))
                 return Array.from(parent.children).map(c => c.tagName).join(',')
               })()
               """)
    end
  end

  # ─── Element.getElementsByTagName (WPT) ───

  describe "Element.getElementsByTagName" do
    test "finds direct children", %{rt: rt} do
      assert 2 ==
               eval!(rt, """
               (() => {
                 const parent = document.createElement('div')
                 parent.appendChild(document.createElement('span'))
                 parent.appendChild(document.createElement('span'))
                 parent.appendChild(document.createElement('a'))
                 return parent.getElementsByTagName('span').length
               })()
               """)
    end

    test "finds nested elements", %{rt: rt} do
      assert 2 ==
               eval!(rt, """
               (() => {
                 const outer = document.createElement('div')
                 const inner = document.createElement('div')
                 outer.appendChild(inner)
                 inner.appendChild(document.createElement('span'))
                 outer.appendChild(document.createElement('span'))
                 return outer.getElementsByTagName('span').length
               })()
               """)
    end
  end

  # ─── Element.getElementsByClassName (WPT) ───

  describe "Element.getElementsByClassName" do
    test "finds elements by class name", %{rt: rt} do
      assert 2 ==
               eval!(rt, """
               (() => {
                 const parent = document.createElement('div')
                 const a = document.createElement('span')
                 a.className = 'target'
                 const b = document.createElement('span')
                 b.className = 'target other'
                 const c = document.createElement('span')
                 c.className = 'other'
                 parent.appendChild(a)
                 parent.appendChild(b)
                 parent.appendChild(c)
                 return parent.getElementsByClassName('target').length
               })()
               """)
    end
  end

  # ─── Element.innerHTML (various WPT) ───

  describe "Element.innerHTML" do
    test "setting innerHTML replaces children", %{rt: rt} do
      assert [1, "SPAN"] ==
               eval!(rt, """
               (() => {
                 const el = document.createElement('div')
                 el.innerHTML = '<span>hello</span>'
                 return [el.children.length, el.firstChild.tagName]
               })()
               """)
    end

    test "getting innerHTML serializes children", %{rt: rt} do
      assert "<span></span>" ==
               eval!(rt, """
               (() => {
                 const el = document.createElement('div')
                 el.appendChild(document.createElement('span'))
                 return el.innerHTML
               })()
               """)
    end

    test "setting innerHTML to empty clears children", %{rt: rt} do
      assert 0 ==
               eval!(rt, """
               (() => {
                 const el = document.createElement('div')
                 el.appendChild(document.createElement('span'))
                 el.innerHTML = ''
                 return el.childNodes.length
               })()
               """)
    end
  end

  # ─── Element.outerHTML ───

  describe "Element.outerHTML" do
    test "outerHTML includes the element itself", %{rt: rt} do
      assert "<div><span></span></div>" ==
               eval!(rt, """
               (() => {
                 const el = document.createElement('div')
                 el.appendChild(document.createElement('span'))
                 return el.outerHTML
               })()
               """)
    end
  end

  # ─── Element.tagName ───
  # Note: QuickBEAM returns lowercase

  describe "Element.tagName" do
    test "tagName is uppercase for HTML", %{rt: rt} do
      assert "DIV" == eval!(rt, "document.createElement('div').tagName")
    end

    test "tagName for custom element is uppercase", %{rt: rt} do
      assert "MY-ELEMENT" == eval!(rt, "document.createElement('my-element').tagName")
    end
  end
end
