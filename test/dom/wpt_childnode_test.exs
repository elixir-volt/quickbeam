defmodule QuickBEAM.DOM.WPT.ChildNodeTest do
  @moduledoc """
  Tests ported from Web Platform Tests (WPT) dom/nodes/ suite.
  ChildNode interface: before, after, remove, replaceWith.
  ParentNode interface: prepend, append.
  https://github.com/web-platform-tests/wpt/tree/master/dom/nodes
  """
  use ExUnit.Case, async: true

  setup do
    {:ok, rt} = QuickBEAM.start()

    on_exit(fn ->
      try do
        QuickBEAM.stop(rt)
      catch
        :exit, _ -> :ok
      end
    end)

    %{rt: rt}
  end

  defp eval!(rt, code) do
    {:ok, result} = QuickBEAM.eval(rt, code)
    result
  end

  # ─── ChildNode.remove (WPT: ChildNode-remove.js) ───

  describe "ChildNode.remove" do
    for {type, creator} <- [
          {"Element", "document.createElement('test')"},
          {"Text", "document.createTextNode('test')"},
          {"Comment", "document.createComment('test')"}
        ] do
      test "#{type}.remove() on orphan does nothing", %{rt: rt} do
        assert nil ==
                 eval!(rt, """
                 (() => {
                   const node = #{unquote(creator)}
                   node.remove()
                   return node.parentNode
                 })()
                 """)
      end

      test "#{type}.remove() detaches from parent", %{rt: rt} do
        assert [nil, 0] ==
                 eval!(rt, """
                 (() => {
                   const parent = document.createElement('div')
                   const node = #{unquote(creator)}
                   parent.appendChild(node)
                   node.remove()
                   return [node.parentNode, parent.childNodes.length]
                 })()
                 """)
      end

      test "#{type}.remove() preserves siblings", %{rt: rt} do
        assert [nil, 2] ==
                 eval!(rt, """
                 (() => {
                   const parent = document.createElement('div')
                   const before = document.createComment('before')
                   const node = #{unquote(creator)}
                   const after = document.createComment('after')
                   parent.appendChild(before)
                   parent.appendChild(node)
                   parent.appendChild(after)
                   node.remove()
                   return [node.parentNode, parent.childNodes.length]
                 })()
                 """)
      end
    end
  end

  # ─── ChildNode.before (WPT: ChildNode-before.html) ───

  describe "ChildNode.before" do
    test "before() without arguments does nothing", %{rt: rt} do
      assert "<test></test>" ==
               eval!(rt, """
               (() => {
                 const parent = document.createElement('div')
                 const child = document.createElement('test')
                 parent.appendChild(child)
                 child.before()
                 return parent.innerHTML
               })()
               """)
    end

    test "before() with text", %{rt: rt} do
      assert "text<test></test>" ==
               eval!(rt, """
               (() => {
                 const parent = document.createElement('div')
                 const child = document.createElement('test')
                 parent.appendChild(child)
                 child.before('text')
                 return parent.innerHTML
               })()
               """)
    end

    test "before() with element", %{rt: rt} do
      assert "<x></x><test></test>" ==
               eval!(rt, """
               (() => {
                 const parent = document.createElement('div')
                 const child = document.createElement('test')
                 parent.appendChild(child)
                 child.before(document.createElement('x'))
                 return parent.innerHTML
               })()
               """)
    end

    test "before() with element and text", %{rt: rt} do
      assert "<x></x>text<test></test>" ==
               eval!(rt, """
               (() => {
                 const parent = document.createElement('div')
                 const child = document.createElement('test')
                 parent.appendChild(child)
                 child.before(document.createElement('x'), 'text')
                 return parent.innerHTML
               })()
               """)
    end

    test "before() on Comment", %{rt: rt} do
      assert "text<!--test-->" ==
               eval!(rt, """
               (() => {
                 const parent = document.createElement('div')
                 const child = document.createComment('test')
                 parent.appendChild(child)
                 child.before('text')
                 return parent.innerHTML
               })()
               """)
    end

    test "before() on Text", %{rt: rt} do
      assert "beforetest" ==
               eval!(rt, """
               (() => {
                 const parent = document.createElement('div')
                 const child = document.createTextNode('test')
                 parent.appendChild(child)
                 child.before('before')
                 return parent.innerHTML
               })()
               """)
    end
  end

  # ─── ChildNode.after (WPT: ChildNode-after.html) ───

  describe "ChildNode.after" do
    test "after() without arguments does nothing", %{rt: rt} do
      assert "<test></test>" ==
               eval!(rt, """
               (() => {
                 const parent = document.createElement('div')
                 const child = document.createElement('test')
                 parent.appendChild(child)
                 child.after()
                 return parent.innerHTML
               })()
               """)
    end

    test "after() with text", %{rt: rt} do
      assert "<test></test>text" ==
               eval!(rt, """
               (() => {
                 const parent = document.createElement('div')
                 const child = document.createElement('test')
                 parent.appendChild(child)
                 child.after('text')
                 return parent.innerHTML
               })()
               """)
    end

    test "after() with element", %{rt: rt} do
      assert "<test></test><x></x>" ==
               eval!(rt, """
               (() => {
                 const parent = document.createElement('div')
                 const child = document.createElement('test')
                 parent.appendChild(child)
                 child.after(document.createElement('x'))
                 return parent.innerHTML
               })()
               """)
    end

    test "after() with element and text", %{rt: rt} do
      assert "<test></test><x></x>text" ==
               eval!(rt, """
               (() => {
                 const parent = document.createElement('div')
                 const child = document.createElement('test')
                 parent.appendChild(child)
                 child.after(document.createElement('x'), 'text')
                 return parent.innerHTML
               })()
               """)
    end
  end

  # ─── ChildNode.replaceWith (WPT: ChildNode-replaceWith.html) ───

  describe "ChildNode.replaceWith" do
    test "replaceWith() without arguments removes the node", %{rt: rt} do
      assert "" ==
               eval!(rt, """
               (() => {
                 const parent = document.createElement('div')
                 const child = document.createElement('test')
                 parent.appendChild(child)
                 child.replaceWith()
                 return parent.innerHTML
               })()
               """)
    end

    test "replaceWith() with text", %{rt: rt} do
      assert "replacement" ==
               eval!(rt, """
               (() => {
                 const parent = document.createElement('div')
                 const child = document.createElement('test')
                 parent.appendChild(child)
                 child.replaceWith('replacement')
                 return parent.innerHTML
               })()
               """)
    end

    test "replaceWith() with element", %{rt: rt} do
      assert "<x></x>" ==
               eval!(rt, """
               (() => {
                 const parent = document.createElement('div')
                 const child = document.createElement('test')
                 parent.appendChild(child)
                 child.replaceWith(document.createElement('x'))
                 return parent.innerHTML
               })()
               """)
    end

    test "replaceWith() with element and text", %{rt: rt} do
      assert "<x></x>text" ==
               eval!(rt, """
               (() => {
                 const parent = document.createElement('div')
                 const child = document.createElement('test')
                 parent.appendChild(child)
                 child.replaceWith(document.createElement('x'), 'text')
                 return parent.innerHTML
               })()
               """)
    end

    test "replaceWith() detaches old node", %{rt: rt} do
      assert nil ==
               eval!(rt, """
               (() => {
                 const parent = document.createElement('div')
                 const child = document.createElement('test')
                 parent.appendChild(child)
                 child.replaceWith(document.createElement('x'))
                 return child.parentNode
               })()
               """)
    end
  end

  # ─── ParentNode.append (WPT: ParentNode-append.html) ───

  describe "ParentNode.append" do
    test "append() without arguments does nothing", %{rt: rt} do
      assert 0 ==
               eval!(rt, """
               (() => {
                 const parent = document.createElement('div')
                 parent.append()
                 return parent.childNodes.length
               })()
               """)
    end

    test "append() with text creates a text node", %{rt: rt} do
      assert "text" ==
               eval!(rt, """
               (() => {
                 const parent = document.createElement('div')
                 parent.append('text')
                 return parent.textContent
               })()
               """)
    end

    test "append() with element", %{rt: rt} do
      assert 1 ==
               eval!(rt, """
               (() => {
                 const parent = document.createElement('div')
                 parent.append(document.createElement('x'))
                 return parent.children.length
               })()
               """)
    end

    test "append() preserves existing children", %{rt: rt} do
      assert 3 ==
               eval!(rt, """
               (() => {
                 const parent = document.createElement('div')
                 parent.appendChild(document.createElement('a'))
                 parent.append(document.createElement('x'), 'text')
                 return parent.childNodes.length
               })()
               """)
    end

    test "append() same element twice moves it", %{rt: rt} do
      assert 2 ==
               eval!(rt, """
               (() => {
                 const parent = document.createElement('div')
                 const x = document.createElement('x')
                 const y = document.createElement('y')
                 parent.append(x, y, x)
                 return parent.childNodes.length
               })()
               """)
    end

    test "append() on DocumentFragment", %{rt: rt} do
      assert "text" ==
               eval!(rt, """
               (() => {
                 const df = document.createDocumentFragment()
                 df.append('text')
                 return df.textContent
               })()
               """)
    end
  end

  # ─── ParentNode.prepend (WPT: ParentNode-prepend.html) ───

  describe "ParentNode.prepend" do
    test "prepend() without arguments does nothing", %{rt: rt} do
      assert 0 ==
               eval!(rt, """
               (() => {
                 const parent = document.createElement('div')
                 parent.prepend()
                 return parent.childNodes.length
               })()
               """)
    end

    test "prepend() with text creates a text node", %{rt: rt} do
      assert "text" ==
               eval!(rt, """
               (() => {
                 const parent = document.createElement('div')
                 parent.prepend('text')
                 return parent.textContent
               })()
               """)
    end

    test "prepend() inserts before existing children", %{rt: rt} do
      assert 3 ==
               eval!(rt, """
               (() => {
                 const parent = document.createElement('div')
                 parent.appendChild(document.createElement('a'))
                 parent.prepend(document.createElement('x'), 'text')
                 return parent.childNodes.length
               })()
               """)
    end

    test "prepend() on DocumentFragment", %{rt: rt} do
      assert "text" ==
               eval!(rt, """
               (() => {
                 const df = document.createDocumentFragment()
                 df.prepend('text')
                 return df.textContent
               })()
               """)
    end
  end
end
