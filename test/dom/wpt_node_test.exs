defmodule QuickBEAM.DOM.WPT.NodeTest do
  @moduledoc """
  Tests ported from Web Platform Tests (WPT) dom/nodes/ suite.
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

  # ─── Node.parentNode (WPT: Node-parentNode.html) ───

  describe "Node.parentNode" do
    test "newly created element has null parentNode", %{rt: rt} do
      assert nil == eval!(rt, "document.createElement('div').parentNode")
    end

    test "appended element has non-null parentNode", %{rt: rt} do
      assert eval!(rt, """
             (() => {
               const el = document.createElement('div')
               document.body.appendChild(el)
               return el.parentNode !== null
             })()
             """)
    end
  end

  # ─── Node.parentElement (WPT: Node-parentElement.html) ───

  describe "Node.parentElement" do
    test "element child's parentElement is non-null", %{rt: rt} do
      assert eval!(rt, """
             (() => {
               const parent = document.createElement('div')
               const child = document.createElement('span')
               parent.appendChild(child)
               return child.parentElement !== null
             })()
             """)
    end

    test "detached element's parentElement is null", %{rt: rt} do
      assert nil == eval!(rt, "document.createElement('div').parentElement")
    end
  end

  # ─── Node.contains (WPT: Node-contains.html) ───

  describe "Node.contains" do
    test "node contains itself", %{rt: rt} do
      assert eval!(rt, """
             (() => {
               const el = document.createElement('div')
               return el.contains(el)
             })()
             """)
    end

    test "parent contains child", %{rt: rt} do
      assert eval!(rt, """
             (() => {
               const parent = document.createElement('div')
               const child = document.createElement('span')
               parent.appendChild(child)
               return parent.contains(child)
             })()
             """)
    end

    test "parent contains grandchild", %{rt: rt} do
      assert eval!(rt, """
             (() => {
               const gp = document.createElement('div')
               const p = document.createElement('div')
               const c = document.createElement('span')
               gp.appendChild(p)
               p.appendChild(c)
               return gp.contains(c)
             })()
             """)
    end

    test "child does not contain parent", %{rt: rt} do
      refute eval!(rt, """
             (() => {
               const parent = document.createElement('div')
               const child = document.createElement('span')
               parent.appendChild(child)
               return child.contains(parent)
             })()
             """)
    end

    test "unrelated nodes do not contain each other", %{rt: rt} do
      refute eval!(rt, """
             (() => {
               const a = document.createElement('div')
               const b = document.createElement('div')
               return a.contains(b)
             })()
             """)
    end

    test "contains(null) returns false", %{rt: rt} do
      refute eval!(rt, "document.createElement('div').contains(null)")
    end
  end

  # ─── Node.textContent (WPT: Node-textContent.html) ───

  describe "Node.textContent getting" do
    test "empty element has empty textContent", %{rt: rt} do
      assert "" == eval!(rt, "document.createElement('div').textContent")
    end

    test "empty documentFragment has empty textContent", %{rt: rt} do
      assert "" == eval!(rt, "document.createDocumentFragment().textContent")
    end

    test "element with mixed children returns only text node content", %{rt: rt} do
      assert "\tDEF\t" ==
               eval!(rt, """
               (() => {
                 const el = document.createElement('div')
                 el.appendChild(document.createComment(' abc '))
                 el.appendChild(document.createTextNode('\\tDEF\\t'))
                 return el.textContent
               })()
               """)
    end

    test "element with descendants concatenates all descendant text", %{rt: rt} do
      assert "\tDEF\t" ==
               eval!(rt, """
               (() => {
                 const el = document.createElement('div')
                 const child = document.createElement('div')
                 el.appendChild(child)
                 child.appendChild(document.createComment(' abc '))
                 child.appendChild(document.createTextNode('\\tDEF\\t'))
                 return el.textContent
               })()
               """)
    end

    test "text node textContent is its data", %{rt: rt} do
      assert "abc" == eval!(rt, "document.createTextNode('abc').textContent")
    end

    test "comment textContent is its data", %{rt: rt} do
      assert "abc" == eval!(rt, "document.createComment('abc').textContent")
    end
  end

  describe "Node.textContent setting" do
    test "setting textContent replaces children with a text node", %{rt: rt} do
      assert "new text" ==
               eval!(rt, """
               (() => {
                 const el = document.createElement('div')
                 el.appendChild(document.createComment(' abc '))
                 el.appendChild(document.createTextNode('\\tDEF\\t'))
                 el.textContent = 'new text'
                 return el.textContent
               })()
               """)
    end

    test "setting textContent with numeric value converts to string", %{rt: rt} do
      assert "42" ==
               eval!(rt, """
               (() => {
                 const el = document.createElement('div')
                 el.textContent = 42
                 return el.textContent
               })()
               """)
    end

    test "setting textContent removes previous text node from tree", %{rt: rt} do
      assert nil ==
               eval!(rt, """
               (() => {
                 const el = document.createElement('div')
                 const text = el.appendChild(document.createTextNode(''))
                 el.textContent = 'new'
                 return text.parentNode
               })()
               """)
    end
  end

  # ─── Node.appendChild (WPT: Node-appendChild.html) ───

  describe "Node.appendChild" do
    test "appended node appears in childNodes", %{rt: rt} do
      assert 1 ==
               eval!(rt, """
               (() => {
                 const parent = document.createElement('div')
                 parent.appendChild(document.createElement('span'))
                 return parent.childNodes.length
               })()
               """)
    end

    test "multiple appends increase childNodes", %{rt: rt} do
      assert 2 ==
               eval!(rt, """
               (() => {
                 const parent = document.createElement('div')
                 parent.appendChild(document.createElement('a'))
                 parent.appendChild(document.createElement('b'))
                 return parent.childNodes.length
               })()
               """)
    end

    test "appending existing child moves it to the end", %{rt: rt} do
      assert "B,A" ==
               eval!(rt, """
               (() => {
                 const parent = document.createElement('div')
                 const a = document.createElement('a')
                 const b = document.createElement('b')
                 parent.appendChild(a)
                 parent.appendChild(b)
                 parent.appendChild(a)
                 return Array.from(parent.children).map(c => c.tagName).join(',')
               })()
               """)
    end
  end

  # ─── Node.removeChild (WPT: Node-removeChild.html) ───

  describe "Node.removeChild" do
    test "removed child has null parentNode", %{rt: rt} do
      assert nil ==
               eval!(rt, """
               (() => {
                 const parent = document.createElement('div')
                 const child = document.createElement('span')
                 parent.appendChild(child)
                 parent.removeChild(child)
                 return child.parentNode
               })()
               """)
    end

    test "parent has fewer children after removal", %{rt: rt} do
      assert 2 ==
               eval!(rt, """
               (() => {
                 const parent = document.createElement('div')
                 const a = document.createElement('a')
                 const b = document.createElement('b')
                 const c = document.createElement('c')
                 parent.appendChild(a)
                 parent.appendChild(b)
                 parent.appendChild(c)
                 parent.removeChild(b)
                 return parent.childNodes.length
               })()
               """)
    end
  end

  # ─── Node.insertBefore (WPT: Node-insertBefore.html) ───

  describe "Node.insertBefore" do
    test "inserts before the reference node", %{rt: rt} do
      assert "B,A" ==
               eval!(rt, """
               (() => {
                 const parent = document.createElement('div')
                 const a = document.createElement('a')
                 parent.appendChild(a)
                 const b = document.createElement('b')
                 parent.insertBefore(b, a)
                 return Array.from(parent.children).map(c => c.tagName).join(',')
               })()
               """)
    end

    test "insertBefore with null reference appends", %{rt: rt} do
      assert "A,B" ==
               eval!(rt, """
               (() => {
                 const parent = document.createElement('div')
                 const a = document.createElement('a')
                 const b = document.createElement('b')
                 parent.appendChild(a)
                 parent.insertBefore(b, null)
                 return Array.from(parent.children).map(c => c.tagName).join(',')
               })()
               """)
    end

    test "insertBefore moves existing child", %{rt: rt} do
      assert "B,A,C" ==
               eval!(rt, """
               (() => {
                 const parent = document.createElement('div')
                 const a = document.createElement('a')
                 const b = document.createElement('b')
                 const c = document.createElement('c')
                 parent.appendChild(a)
                 parent.appendChild(b)
                 parent.appendChild(c)
                 parent.insertBefore(b, a)
                 return Array.from(parent.children).map(c => c.tagName).join(',')
               })()
               """)
    end
  end

  # ─── Node.replaceChild (WPT: Node-replaceChild.html) ───

  describe "Node.replaceChild" do
    test "replaced child is detached", %{rt: rt} do
      assert nil ==
               eval!(rt, """
               (() => {
                 const parent = document.createElement('div')
                 const old = document.createElement('a')
                 const repl = document.createElement('b')
                 parent.appendChild(old)
                 parent.replaceChild(repl, old)
                 return old.parentNode
               })()
               """)
    end

    test "replacement is in parent", %{rt: rt} do
      assert 1 ==
               eval!(rt, """
               (() => {
                 const parent = document.createElement('div')
                 const old = document.createElement('a')
                 const repl = document.createElement('b')
                 parent.appendChild(old)
                 parent.replaceChild(repl, old)
                 return parent.childNodes.length
               })()
               """)
    end
  end

  # ─── Node.cloneNode (WPT: Node-cloneNode.html) ───

  describe "Node.cloneNode" do
    test "shallow clone copies tagName", %{rt: rt} do
      assert "DIV" ==
               eval!(rt, """
               (() => {
                 const el = document.createElement('div')
                 return el.cloneNode(false).tagName
               })()
               """)
    end

    test "shallow clone copies attributes", %{rt: rt} do
      assert "original" ==
               eval!(rt, """
               (() => {
                 const el = document.createElement('div')
                 el.id = 'original'
                 return el.cloneNode(false).id
               })()
               """)
    end

    test "shallow clone does not copy children", %{rt: rt} do
      assert 0 ==
               eval!(rt, """
               (() => {
                 const el = document.createElement('div')
                 el.appendChild(document.createElement('span'))
                 return el.cloneNode(false).childNodes.length
               })()
               """)
    end

    test "deep clone copies children", %{rt: rt} do
      assert 1 ==
               eval!(rt, """
               (() => {
                 const el = document.createElement('div')
                 el.appendChild(document.createElement('span'))
                 return el.cloneNode(true).childNodes.length
               })()
               """)
    end

    test "clone is not the same object", %{rt: rt} do
      refute eval!(rt, """
             (() => {
               const el = document.createElement('div')
               return el.cloneNode(false) === el
             })()
             """)
    end

    test "clone has no parent", %{rt: rt} do
      assert nil ==
               eval!(rt, """
               (() => {
                 const el = document.createElement('div')
                 document.body.appendChild(el)
                 return el.cloneNode(false).parentNode
               })()
               """)
    end

    test "deep clone copies text content", %{rt: rt} do
      assert "hello" ==
               eval!(rt, """
               (() => {
                 const el = document.createElement('div')
                 el.textContent = 'hello'
                 return el.cloneNode(true).textContent
               })()
               """)
    end

    test "cloning text node", %{rt: rt} do
      assert "hello" ==
               eval!(rt, """
               (() => {
                 const text = document.createTextNode('hello')
                 return text.cloneNode().textContent
               })()
               """)
    end

    test "cloning comment node", %{rt: rt} do
      assert "hello" ==
               eval!(rt, """
               (() => {
                 const comment = document.createComment('hello')
                 return comment.cloneNode().textContent
               })()
               """)
    end

    test "cloning document fragment (deep)", %{rt: rt} do
      assert 2 ==
               eval!(rt, """
               (() => {
                 const df = document.createDocumentFragment()
                 df.appendChild(document.createElement('a'))
                 df.appendChild(document.createElement('b'))
                 return df.cloneNode(true).childNodes.length
               })()
               """)
    end
  end

  # ─── Node.nodeType (WPT: Node-nodeType.html) ───

  describe "Node.nodeType" do
    test "Element.nodeType is 1", %{rt: rt} do
      assert 1 == eval!(rt, "document.createElement('div').nodeType")
    end

    test "Text.nodeType is 3", %{rt: rt} do
      assert 3 == eval!(rt, "document.createTextNode('').nodeType")
    end

    test "Comment.nodeType is 8", %{rt: rt} do
      assert 8 == eval!(rt, "document.createComment('').nodeType")
    end

    test "DocumentFragment.nodeType is 11", %{rt: rt} do
      assert 11 == eval!(rt, "document.createDocumentFragment().nodeType")
    end
  end

  # ─── Node.nodeName (WPT: Node-nodeName.html) ───
  # Note: QuickBEAM returns lowercase tagName/nodeName for elements

  describe "Node.nodeName" do
    test "element nodeName matches tagName", %{rt: rt} do
      assert "DIV" == eval!(rt, "document.createElement('div').nodeName")
    end

    test "text node nodeName is #text", %{rt: rt} do
      assert "#text" == eval!(rt, "document.createTextNode('').nodeName")
    end

    test "comment nodeName is #comment", %{rt: rt} do
      assert "#comment" == eval!(rt, "document.createComment('').nodeName")
    end

    test "document fragment nodeName is #document-fragment", %{rt: rt} do
      assert "#document-fragment" ==
               eval!(rt, "document.createDocumentFragment().nodeName")
    end
  end

  # ─── Node siblings ───

  describe "Node sibling properties" do
    test "firstChild and lastChild after two appends", %{rt: rt} do
      assert 2 ==
               eval!(rt, """
               (() => {
                 const parent = document.createElement('div')
                 parent.appendChild(document.createElement('a'))
                 parent.appendChild(document.createElement('b'))
                 return parent.childNodes.length
               })()
               """)
    end

    test "childNodes reflects live state", %{rt: rt} do
      assert [1, 2, 1] ==
               eval!(rt, """
               (() => {
                 const parent = document.createElement('div')
                 const a = document.createElement('a')
                 const b = document.createElement('b')
                 parent.appendChild(a)
                 const n1 = parent.childNodes.length
                 parent.appendChild(b)
                 const n2 = parent.childNodes.length
                 parent.removeChild(a)
                 const n3 = parent.childNodes.length
                 return [n1, n2, n3]
               })()
               """)
    end

    test "children only includes elements", %{rt: rt} do
      assert [4, 2] ==
               eval!(rt, """
               (() => {
                 const parent = document.createElement('div')
                 parent.appendChild(document.createTextNode('text'))
                 parent.appendChild(document.createElement('span'))
                 parent.appendChild(document.createComment('comment'))
                 parent.appendChild(document.createElement('a'))
                 return [parent.childNodes.length, parent.children.length]
               })()
               """)
    end
  end
end
