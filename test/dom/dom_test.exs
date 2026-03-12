defmodule QuickBEAM.DOM.DOMTest do
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

  describe "document global" do
    test "document exists", %{runtime: rt} do
      assert {:ok, "object"} = QuickBEAM.eval(rt, "typeof document")
    end

    test "document.body exists", %{runtime: rt} do
      assert {:ok, "object"} = QuickBEAM.eval(rt, "typeof document.body")
    end

    test "document.head exists", %{runtime: rt} do
      assert {:ok, "object"} = QuickBEAM.eval(rt, "typeof document.head")
    end

    test "document.documentElement exists", %{runtime: rt} do
      assert {:ok, "object"} = QuickBEAM.eval(rt, "typeof document.documentElement")
    end
  end

  describe "createElement" do
    test "creates element with correct tagName", %{runtime: rt} do
      assert {:ok, "div"} =
               QuickBEAM.eval(rt, """
                 const el = document.createElement('div');
                 el.tagName;
               """)
    end

    test "setAttribute and getAttribute", %{runtime: rt} do
      assert {:ok, "bar"} =
               QuickBEAM.eval(rt, """
                 const el = document.createElement('div');
                 el.setAttribute('foo', 'bar');
                 el.getAttribute('foo');
               """)
    end

    test "hasAttribute returns true", %{runtime: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
                 (() => {
                   const el = document.createElement('div');
                   el.setAttribute('data-x', 'y');
                   return el.hasAttribute('data-x');
                 })()
               """)
    end

    test "hasAttribute returns false", %{runtime: rt} do
      assert {:ok, false} =
               QuickBEAM.eval(rt, """
                 (() => {
                   const el = document.createElement('div');
                   return el.hasAttribute('nope');
                 })()
               """)
    end

    test "removeAttribute", %{runtime: rt} do
      assert {:ok, nil} =
               QuickBEAM.eval(rt, """
                 const el = document.createElement('div');
                 el.setAttribute('x', '1');
                 el.removeAttribute('x');
                 el.getAttribute('x');
               """)
    end

    test "id getter/setter", %{runtime: rt} do
      assert {:ok, "myid"} =
               QuickBEAM.eval(rt, """
                 const el = document.createElement('div');
                 el.id = 'myid';
                 el.id;
               """)
    end

    test "className getter", %{runtime: rt} do
      assert {:ok, "a b"} =
               QuickBEAM.eval(rt, """
                 const el = document.createElement('div');
                 el.setAttribute('class', 'a b');
                 el.className;
               """)
    end
  end

  describe "tree manipulation" do
    test "appendChild", %{runtime: rt} do
      assert {:ok, "span"} =
               QuickBEAM.eval(rt, """
                 const parent = document.createElement('div');
                 const child = document.createElement('span');
                 parent.appendChild(child);
                 parent.firstChild.tagName;
               """)
    end

    test "removeChild", %{runtime: rt} do
      assert {:ok, 0} =
               QuickBEAM.eval(rt, """
                 const parent = document.createElement('div');
                 const child = document.createElement('span');
                 parent.appendChild(child);
                 parent.removeChild(child);
                 parent.children.length;
               """)
    end

    test "textContent", %{runtime: rt} do
      assert {:ok, "Hello"} =
               QuickBEAM.eval(rt, """
                 const el = document.createElement('p');
                 el.textContent = 'Hello';
                 el.textContent;
               """)
    end

    test "innerHTML getter", %{runtime: rt} do
      assert {:ok, "<span></span>"} =
               QuickBEAM.eval(rt, """
                 const div = document.createElement('div');
                 const span = document.createElement('span');
                 div.appendChild(span);
                 div.innerHTML;
               """)
    end

    test "innerHTML setter", %{runtime: rt} do
      assert {:ok, "p"} =
               QuickBEAM.eval(rt, """
                 const div = document.createElement('div');
                 div.innerHTML = '<p>Hello</p>';
                 div.firstChild.tagName;
               """)
    end
  end

  describe "body manipulation" do
    test "appendChild to body and innerHTML", %{runtime: rt} do
      assert {:ok, html} =
               QuickBEAM.eval(rt, """
                 const div = document.createElement('div');
                 div.id = 'root';
                 document.body.appendChild(div);
                 document.body.innerHTML;
               """)

      assert html =~ ~r/<div id="root"><\/div>/
    end
  end

  describe "getElementById" do
    test "finds element by id", %{runtime: rt} do
      assert {:ok, "div"} =
               QuickBEAM.eval(rt, """
                 const div = document.createElement('div');
                 div.id = 'test';
                 document.body.appendChild(div);
                 const found = document.getElementById('test');
                 found.tagName;
               """)
    end

    test "returns null for missing id", %{runtime: rt} do
      assert {:ok, nil} = QuickBEAM.eval(rt, "document.getElementById('nope')")
    end
  end

  describe "querySelector" do
    test "finds element by class", %{runtime: rt} do
      assert {:ok, "span"} =
               QuickBEAM.eval(rt, """
                 const div = document.createElement('div');
                 const span = document.createElement('span');
                 span.setAttribute('class', 'target');
                 div.appendChild(span);
                 document.body.appendChild(div);
                 const found = document.querySelector('.target');
                 found.tagName;
               """)
    end

    test "returns null when not found", %{runtime: rt} do
      assert {:ok, nil} = QuickBEAM.eval(rt, "document.querySelector('.nonexistent')")
    end
  end

  describe "querySelectorAll" do
    test "finds multiple elements", %{runtime: rt} do
      assert {:ok, 3} =
               QuickBEAM.eval(rt, """
                 for (let i = 0; i < 3; i++) {
                   const li = document.createElement('li');
                   li.setAttribute('class', 'item');
                   document.body.appendChild(li);
                 }
                 document.querySelectorAll('.item').length;
               """)
    end
  end

  describe "createTextNode" do
    test "creates text node and appends", %{runtime: rt} do
      assert {:ok, "Hello World"} =
               QuickBEAM.eval(rt, """
                 const p = document.createElement('p');
                 const text = document.createTextNode('Hello World');
                 p.appendChild(text);
                 p.textContent;
               """)
    end
  end

  describe "tree navigation" do
    test "parentNode", %{runtime: rt} do
      assert {:ok, "div"} =
               QuickBEAM.eval(rt, """
                 const div = document.createElement('div');
                 const span = document.createElement('span');
                 div.appendChild(span);
                 span.parentNode.tagName;
               """)
    end

    test "children filters element nodes only", %{runtime: rt} do
      assert {:ok, 1} =
               QuickBEAM.eval(rt, """
                 const div = document.createElement('div');
                 const span = document.createElement('span');
                 const text = document.createTextNode('hello');
                 div.appendChild(text);
                 div.appendChild(span);
                 div.children.length;
               """)
    end

    test "childNodes includes all nodes", %{runtime: rt} do
      assert {:ok, 2} =
               QuickBEAM.eval(rt, """
                 const div = document.createElement('div');
                 const span = document.createElement('span');
                 const text = document.createTextNode('hello');
                 div.appendChild(text);
                 div.appendChild(span);
                 div.childNodes.length;
               """)
    end

    test "nextSibling", %{runtime: rt} do
      assert {:ok, "b"} =
               QuickBEAM.eval(rt, """
                 const div = document.createElement('div');
                 const a = document.createElement('a');
                 const b = document.createElement('b');
                 div.appendChild(a);
                 div.appendChild(b);
                 a.nextSibling.tagName;
               """)
    end
  end

  describe "outerHTML" do
    test "serializes element with attributes", %{runtime: rt} do
      assert {:ok, html} =
               QuickBEAM.eval(rt, """
                 const div = document.createElement('div');
                 div.id = 'x';
                 div.setAttribute('class', 'y');
                 div.outerHTML;
               """)

      assert html =~ "div"
      assert html =~ ~s(id="x")
      assert html =~ ~s(class="y")
    end
  end

  describe "error handling" do
    test "createElement without arguments throws", %{runtime: rt} do
      assert {:error, _} = QuickBEAM.eval(rt, "document.createElement()")
    end

    test "getElementById without arguments throws", %{runtime: rt} do
      assert {:error, _} = QuickBEAM.eval(rt, "document.getElementById()")
    end

    test "querySelector without arguments throws", %{runtime: rt} do
      assert {:error, _} = QuickBEAM.eval(rt, "document.querySelector()")
    end

    test "setAttribute without value throws", %{runtime: rt} do
      assert {:error, _} =
               QuickBEAM.eval(rt, """
                 const el = document.createElement('div');
                 el.setAttribute('x');
               """)
    end

    test "appendChild without arguments throws", %{runtime: rt} do
      assert {:error, _} =
               QuickBEAM.eval(rt, """
                 const el = document.createElement('div');
                 el.appendChild();
               """)
    end

    test "querySelector with invalid selector returns null", %{runtime: rt} do
      assert {:ok, nil} = QuickBEAM.eval(rt, "document.querySelector('[')")
    end

    test "querySelectorAll with invalid selector returns empty array", %{runtime: rt} do
      assert {:ok, 0} = QuickBEAM.eval(rt, "document.querySelectorAll('[').length")
    end
  end

  describe "querySelector on elements" do
    test "querySelector scoped to element subtree", %{runtime: rt} do
      assert {:ok, "found"} =
               QuickBEAM.eval(rt, """
                 const outer = document.createElement('div');
                 const inner = document.createElement('div');
                 const target = document.createElement('span');
                 target.setAttribute('class', 'x');
                 inner.appendChild(target);
                 outer.appendChild(inner);
                 document.body.appendChild(outer);
                 const result = inner.querySelector('.x');
                 result ? 'found' : 'not found';
               """)
    end

    test "querySelectorAll scoped to element subtree", %{runtime: rt} do
      assert {:ok, 2} =
               QuickBEAM.eval(rt, """
                 const container = document.createElement('div');
                 for (let i = 0; i < 2; i++) {
                   const p = document.createElement('p');
                   p.setAttribute('class', 'scoped');
                   container.appendChild(p);
                 }
                 const outside = document.createElement('p');
                 outside.setAttribute('class', 'scoped');
                 document.body.appendChild(outside);
                 document.body.appendChild(container);
                 container.querySelectorAll('.scoped').length;
               """)
    end
  end

  describe "innerHTML replacement" do
    test "innerHTML replaces existing children", %{runtime: rt} do
      assert {:ok, "new"} =
               QuickBEAM.eval(rt, """
                 const div = document.createElement('div');
                 div.innerHTML = '<p>old</p>';
                 div.innerHTML = '<span>new</span>';
                 div.firstChild.textContent;
               """)
    end

    test "innerHTML setter clears previous child count", %{runtime: rt} do
      assert {:ok, 1} =
               QuickBEAM.eval(rt, """
                 const div = document.createElement('div');
                 div.innerHTML = '<a></a><b></b><c></c>';
                 div.innerHTML = '<p>only one</p>';
                 div.children.length;
               """)
    end

    test "empty innerHTML clears children", %{runtime: rt} do
      assert {:ok, 0} =
               QuickBEAM.eval(rt, """
                 const div = document.createElement('div');
                 div.innerHTML = '<p>content</p>';
                 div.innerHTML = '';
                 div.children.length;
               """)
    end
  end

  describe "empty and edge values" do
    test "empty textContent", %{runtime: rt} do
      assert {:ok, ""} =
               QuickBEAM.eval(rt, """
                 const el = document.createElement('div');
                 el.textContent = '';
                 el.textContent;
               """)
    end

    test "textContent with HTML entities", %{runtime: rt} do
      assert {:ok, "<script>alert(1)</script>"} =
               QuickBEAM.eval(rt, """
                 const el = document.createElement('div');
                 el.textContent = '<script>alert(1)</script>';
                 el.textContent;
               """)
    end

    test "innerHTML escapes textContent correctly", %{runtime: rt} do
      assert {:ok, html} =
               QuickBEAM.eval(rt, """
                 const el = document.createElement('div');
                 el.textContent = '<b>bold</b>';
                 el.innerHTML;
               """)

      assert html =~ "&lt;b&gt;"
    end

    test "getAttribute returns null for missing attribute", %{runtime: rt} do
      assert {:ok, nil} =
               QuickBEAM.eval(rt, """
                 const el = document.createElement('div');
                 el.getAttribute('missing');
               """)
    end

    test "id defaults to empty string", %{runtime: rt} do
      assert {:ok, ""} =
               QuickBEAM.eval(rt, """
                 const el = document.createElement('div');
                 el.id;
               """)
    end

    test "className defaults to empty string", %{runtime: rt} do
      assert {:ok, ""} =
               QuickBEAM.eval(rt, """
                 const el = document.createElement('div');
                 el.className;
               """)
    end

    test "firstChild returns null on empty element", %{runtime: rt} do
      assert {:ok, nil} =
               QuickBEAM.eval(rt, """
                 const el = document.createElement('div');
                 el.firstChild;
               """)
    end

    test "nextSibling returns null on last child", %{runtime: rt} do
      assert {:ok, nil} =
               QuickBEAM.eval(rt, """
                 const div = document.createElement('div');
                 const span = document.createElement('span');
                 div.appendChild(span);
                 span.nextSibling;
               """)
    end

    test "parentNode returns null on detached element", %{runtime: rt} do
      assert {:ok, nil} =
               QuickBEAM.eval(rt, """
                 const el = document.createElement('div');
                 el.parentNode;
               """)
    end
  end

  describe "multiple children ordering" do
    test "appendChild preserves insertion order", %{runtime: rt} do
      assert {:ok, "a,b,c"} =
               QuickBEAM.eval(rt, """
                 const div = document.createElement('div');
                 ['a', 'b', 'c'].forEach(tag => {
                   const el = document.createElement(tag);
                   div.appendChild(el);
                 });
                 Array.from(div.children).map(c => c.tagName).join(',');
               """)
    end

    test "removeChild from middle preserves order of remaining", %{runtime: rt} do
      assert {:ok, "a,c"} =
               QuickBEAM.eval(rt, """
                 (() => {
                   const div = document.createElement('div');
                   const a = document.createElement('a');
                   const b = document.createElement('b');
                   const c = document.createElement('c');
                   div.appendChild(a);
                   div.appendChild(b);
                   div.appendChild(c);
                   div.removeChild(b);
                   return Array.from(div.children).map(c => c.tagName).join(',');
                 })()
               """)
    end
  end

  describe "nested DOM trees" do
    test "deeply nested querySelector", %{runtime: rt} do
      assert {:ok, "deep"} =
               QuickBEAM.eval(rt, """
                 const l1 = document.createElement('div');
                 const l2 = document.createElement('div');
                 const l3 = document.createElement('div');
                 const l4 = document.createElement('span');
                 l4.setAttribute('class', 'deep');
                 l4.textContent = 'deep';
                 l3.appendChild(l4);
                 l2.appendChild(l3);
                 l1.appendChild(l2);
                 document.body.appendChild(l1);
                 document.querySelector('.deep').textContent;
               """)
    end

    test "innerHTML with nested structure", %{runtime: rt} do
      assert {:ok, 1} =
               QuickBEAM.eval(rt, """
                 const div = document.createElement('div');
                 div.innerHTML = '<ul><li><a href="#">link</a></li></ul>';
                 div.querySelectorAll('a').length;
               """)
    end
  end

  describe "concurrent runtime isolation" do
    test "separate runtimes have independent DOMs", _context do
      {:ok, rt1} = QuickBEAM.start()
      {:ok, rt2} = QuickBEAM.start()

      on_exit(fn ->
        try do
          QuickBEAM.stop(rt1)
        catch
          :exit, _ -> :ok
        end

        try do
          QuickBEAM.stop(rt2)
        catch
          :exit, _ -> :ok
        end
      end)

      QuickBEAM.eval(rt1, """
        const div = document.createElement('div');
        div.id = 'only-in-rt1';
        document.body.appendChild(div);
      """)

      assert {:ok, nil} = QuickBEAM.eval(rt2, "document.getElementById('only-in-rt1')")
      assert {:ok, "div"} = QuickBEAM.eval(rt1, "document.getElementById('only-in-rt1').tagName")
    end
  end

  describe "removed node access" do
    test "removed node is still accessible", %{runtime: rt} do
      assert {:ok, "span"} =
               QuickBEAM.eval(rt, """
                 (() => {
                   const div = document.createElement('div');
                   const span = document.createElement('span');
                   div.appendChild(span);
                   div.removeChild(span);
                   return span.tagName;
                 })()
               """)
    end

    test "removed node attributes are preserved", %{runtime: rt} do
      assert {:ok, "val"} =
               QuickBEAM.eval(rt, """
                 (() => {
                   const div = document.createElement('div');
                   const span = document.createElement('span');
                   span.setAttribute('data-x', 'val');
                   div.appendChild(span);
                   div.removeChild(span);
                   return span.getAttribute('data-x');
                 })()
               """)
    end

    test "node survives innerHTML replacement", %{runtime: rt} do
      assert {:ok, "old-child"} =
               QuickBEAM.eval(rt, """
                 (() => {
                   const div = document.createElement('div');
                   const child = document.createElement('span');
                   child.id = 'old-child';
                   div.appendChild(child);
                   div.innerHTML = '<p>new</p>';
                   return child.id;
                 })()
               """)
    end
  end

  describe "re-attachment" do
    test "removed node can be re-appended", %{runtime: rt} do
      assert {:ok, "span"} =
               QuickBEAM.eval(rt, """
                 (() => {
                   const div = document.createElement('div');
                   const span = document.createElement('span');
                   div.appendChild(span);
                   div.removeChild(span);
                   div.appendChild(span);
                   return div.firstChild.tagName;
                 })()
               """)
    end

    test "moving a node between parents", %{runtime: rt} do
      assert {:ok, "0,1"} =
               QuickBEAM.eval(rt, """
                 (() => {
                   const a = document.createElement('div');
                   const b = document.createElement('div');
                   const child = document.createElement('span');
                   a.appendChild(child);
                   b.appendChild(child);
                   return a.children.length + ',' + b.children.length;
                 })()
               """)
    end
  end
end
