defmodule QuickBEAM.DOMExtendedTest do
  use ExUnit.Case, async: true

  setup do
    {:ok, runtime} = QuickBEAM.start()
    on_exit(fn -> try do QuickBEAM.stop(runtime) catch :exit, _ -> :ok end end)
    %{runtime: runtime}
  end

  describe "element.style" do
    test "setProperty and getPropertyValue", %{runtime: rt} do
      assert {:ok, "red"} = QuickBEAM.eval(rt, """
        (() => {
          const el = document.createElement('div');
          el.style.setProperty('color', 'red');
          return el.style.getPropertyValue('color');
        })()
      """)
    end

    test "camelCase property access", %{runtime: rt} do
      assert {:ok, result} = QuickBEAM.eval(rt, """
        (() => {
          const el = document.createElement('div');
          el.style.backgroundColor = 'blue';
          return {
            get: el.style.backgroundColor,
            attr: el.getAttribute('style')
          };
        })()
      """)
      assert result["get"] == "blue"
      assert result["attr"] =~ "background-color"
      assert result["attr"] =~ "blue"
    end

    test "cssText getter roundtrips", %{runtime: rt} do
      assert {:ok, css} = QuickBEAM.eval(rt, """
        (() => {
          const el = document.createElement('div');
          el.setAttribute('style', 'color: red; display: flex');
          return el.style.cssText;
        })()
      """)
      assert css =~ "color"
      assert css =~ "red"
      assert css =~ "display"
      assert css =~ "flex"
    end

    test "cssText setter", %{runtime: rt} do
      assert {:ok, "green"} = QuickBEAM.eval(rt, """
        (() => {
          const el = document.createElement('div');
          el.style.cssText = 'color: green';
          return el.style.getPropertyValue('color');
        })()
      """)
    end

    test "removeProperty", %{runtime: rt} do
      assert {:ok, result} = QuickBEAM.eval(rt, """
        (() => {
          const el = document.createElement('div');
          el.style.setProperty('color', 'red');
          el.style.setProperty('display', 'flex');
          const old = el.style.removeProperty('color');
          return { old, remaining: el.getAttribute('style') };
        })()
      """)
      assert result["old"] == "red"
      refute result["remaining"] =~ "color"
      assert result["remaining"] =~ "display"
    end

    test "getPropertyPriority", %{runtime: rt} do
      assert {:ok, "important"} = QuickBEAM.eval(rt, """
        (() => {
          const el = document.createElement('div');
          el.style.setProperty('color', 'red', 'important');
          return el.style.getPropertyPriority('color');
        })()
      """)
    end

    test "length and item", %{runtime: rt} do
      assert {:ok, result} = QuickBEAM.eval(rt, """
        (() => {
          const el = document.createElement('div');
          el.setAttribute('style', 'color: red; display: flex');
          return { len: el.style.length, first: el.style.item(0) };
        })()
      """)
      assert result["len"] == 2
      assert result["first"] in ["color", "display"]
    end

    test "style persists on DOM element", %{runtime: rt} do
      assert {:ok, "red"} = QuickBEAM.eval(rt, """
        (() => {
          const el = document.createElement('div');
          el.style.color = 'red';
          document.body.appendChild(el);
          return document.body.firstChild.style.getPropertyValue('color');
        })()
      """)
    end

    test "empty style returns empty string", %{runtime: rt} do
      assert {:ok, ""} = QuickBEAM.eval(rt, """
        (() => {
          const el = document.createElement('div');
          return el.style.getPropertyValue('color');
        })()
      """)
    end
  end

  describe "getComputedStyle" do
    test "returns style declaration", %{runtime: rt} do
      assert {:ok, "red"} = QuickBEAM.eval(rt, """
        (() => {
          const el = document.createElement('div');
          el.style.color = 'red';
          return getComputedStyle(el).getPropertyValue('color');
        })()
      """)
    end

    test "exists as global function", %{runtime: rt} do
      assert {:ok, "function"} = QuickBEAM.eval(rt, "typeof getComputedStyle")
    end
  end

  describe "addEventListener / dispatchEvent" do
    test "basic listener fires", %{runtime: rt} do
      assert {:ok, "clicked"} = QuickBEAM.eval(rt, """
        (() => {
          const el = document.createElement('div');
          let result = '';
          el.addEventListener('click', () => { result = 'clicked'; });
          el.dispatchEvent(new Event('click'));
          return result;
        })()
      """)
    end

    test "multiple listeners fire in order", %{runtime: rt} do
      assert {:ok, "ab"} = QuickBEAM.eval(rt, """
        (() => {
          const el = document.createElement('div');
          let result = '';
          el.addEventListener('x', () => { result += 'a'; });
          el.addEventListener('x', () => { result += 'b'; });
          el.dispatchEvent(new Event('x'));
          return result;
        })()
      """)
    end

    test "removeEventListener", %{runtime: rt} do
      assert {:ok, ""} = QuickBEAM.eval(rt, """
        (() => {
          const el = document.createElement('div');
          let result = '';
          const fn = () => { result = 'fired'; };
          el.addEventListener('x', fn);
          el.removeEventListener('x', fn);
          el.dispatchEvent(new Event('x'));
          return result;
        })()
      """)
    end

    test "once option", %{runtime: rt} do
      assert {:ok, 1} = QuickBEAM.eval(rt, """
        (() => {
          const el = document.createElement('div');
          let count = 0;
          el.addEventListener('x', () => { count++; }, { once: true });
          el.dispatchEvent(new Event('x'));
          el.dispatchEvent(new Event('x'));
          return count;
        })()
      """)
    end

    test "duplicate listener ignored", %{runtime: rt} do
      assert {:ok, 1} = QuickBEAM.eval(rt, """
        (() => {
          const el = document.createElement('div');
          let count = 0;
          const fn = () => { count++; };
          el.addEventListener('x', fn);
          el.addEventListener('x', fn);
          el.dispatchEvent(new Event('x'));
          return count;
        })()
      """)
    end

    test "event.target and event.type", %{runtime: rt} do
      assert {:ok, result} = QuickBEAM.eval(rt, """
        (() => {
          const el = document.createElement('div');
          let target = null, type = '';
          el.addEventListener('foo', (e) => { target = e.target; type = e.type; });
          el.dispatchEvent(new Event('foo'));
          return { same: target === el, type };
        })()
      """)
      assert result["same"] == true
      assert result["type"] == "foo"
    end

    test "preventDefault and return value", %{runtime: rt} do
      assert {:ok, false} = QuickBEAM.eval(rt, """
        (() => {
          const el = document.createElement('div');
          el.addEventListener('x', (e) => { e.preventDefault(); });
          return el.dispatchEvent(new Event('x', { cancelable: true }));
        })()
      """)
    end

    test "stopImmediatePropagation", %{runtime: rt} do
      assert {:ok, "a"} = QuickBEAM.eval(rt, """
        (() => {
          const el = document.createElement('div');
          let result = '';
          el.addEventListener('x', (e) => { result += 'a'; e.stopImmediatePropagation(); });
          el.addEventListener('x', () => { result += 'b'; });
          el.dispatchEvent(new Event('x'));
          return result;
        })()
      """)
    end

    test "document.addEventListener", %{runtime: rt} do
      assert {:ok, "doc"} = QuickBEAM.eval(rt, """
        (() => {
          let result = '';
          document.addEventListener('custom', () => { result = 'doc'; });
          document.dispatchEvent(new Event('custom'));
          return result;
        })()
      """)
    end

    test "CustomEvent with detail", %{runtime: rt} do
      assert {:ok, 42} = QuickBEAM.eval(rt, """
        (() => {
          const el = document.createElement('div');
          let detail = null;
          el.addEventListener('msg', (e) => { detail = e.detail; });
          el.dispatchEvent(new CustomEvent('msg', { detail: 42 }));
          return detail;
        })()
      """)
    end

    test "handleEvent object listener", %{runtime: rt} do
      assert {:ok, "handled"} = QuickBEAM.eval(rt, """
        (() => {
          const el = document.createElement('div');
          let result = '';
          const obj = { handleEvent() { result = 'handled'; } };
          el.addEventListener('x', obj);
          el.dispatchEvent(new Event('x'));
          return result;
        })()
      """)
    end
  end

  describe "createElementNS" do
    test "creates SVG element", %{runtime: rt} do
      assert {:ok, "svg"} = QuickBEAM.eval(rt, """
        document.createElementNS('http://www.w3.org/2000/svg', 'svg').tagName;
      """)
    end

    test "creates element with prefix", %{runtime: rt} do
      assert {:ok, result} = QuickBEAM.eval(rt, """
        (() => {
          const el = document.createElementNS('http://www.w3.org/1999/xlink', 'xlink:href');
          return { tag: el.tagName, nodeType: el.nodeType };
        })()
      """)
      assert result["nodeType"] == 1
    end

    test "null namespace creates element like createElement", %{runtime: rt} do
      assert {:ok, "div"} = QuickBEAM.eval(rt, """
        document.createElementNS(null, 'div').tagName;
      """)
    end

    test "element can be appended to DOM", %{runtime: rt} do
      assert {:ok, html} = QuickBEAM.eval(rt, """
        (() => {
          const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
          const rect = document.createElementNS('http://www.w3.org/2000/svg', 'rect');
          svg.appendChild(rect);
          document.body.appendChild(svg);
          return document.body.innerHTML;
        })()
      """)
      assert html =~ "svg"
      assert html =~ "rect"
    end

    test "throws without required arguments", %{runtime: rt} do
      assert {:error, _} = QuickBEAM.eval(rt, "document.createElementNS('http://www.w3.org/2000/svg')")
    end
  end

  describe "createDocumentFragment" do
    test "creates a fragment that can hold children", %{runtime: rt} do
      assert {:ok, 2} = QuickBEAM.eval(rt, """
        (() => {
          const frag = document.createDocumentFragment();
          frag.appendChild(document.createElement('a'));
          frag.appendChild(document.createElement('b'));
          return frag.childNodes.length;
        })()
      """)
    end

    test "appending fragment moves its children to parent", %{runtime: rt} do
      assert {:ok, "a,b"} = QuickBEAM.eval(rt, """
        (() => {
          const frag = document.createDocumentFragment();
          frag.appendChild(document.createElement('a'));
          frag.appendChild(document.createElement('b'));
          const div = document.createElement('div');
          div.appendChild(frag);
          return Array.from(div.children).map(c => c.tagName).join(',');
        })()
      """)
    end

    test "fragment nodeType is 11", %{runtime: rt} do
      assert {:ok, 11} = QuickBEAM.eval(rt, "document.createDocumentFragment().nodeType")
    end
  end

  describe "createComment" do
    test "creates a comment node", %{runtime: rt} do
      assert {:ok, 8} = QuickBEAM.eval(rt, "document.createComment('test').nodeType")
    end

    test "comment has correct nodeValue", %{runtime: rt} do
      assert {:ok, "hello"} = QuickBEAM.eval(rt, "document.createComment('hello').nodeValue")
    end

    test "comment serializes in innerHTML", %{runtime: rt} do
      assert {:ok, html} = QuickBEAM.eval(rt, """
        (() => {
          const div = document.createElement('div');
          div.appendChild(document.createComment('test'));
          return div.innerHTML;
        })()
      """)
      assert html =~ "<!--test-->"
    end

    test "empty comment", %{runtime: rt} do
      assert {:ok, 8} = QuickBEAM.eval(rt, "document.createComment().nodeType")
    end
  end

  describe "getElementsByClassName" do
    test "finds elements by class on document", %{runtime: rt} do
      assert {:ok, 2} = QuickBEAM.eval(rt, """
        (() => {
          document.body.innerHTML = '';
          const a = document.createElement('div');
          a.setAttribute('class', 'foo');
          const b = document.createElement('span');
          b.setAttribute('class', 'foo bar');
          const c = document.createElement('p');
          document.body.appendChild(a);
          document.body.appendChild(b);
          document.body.appendChild(c);
          return document.getElementsByClassName('foo').length;
        })()
      """)
    end

    test "scoped to element", %{runtime: rt} do
      assert {:ok, 1} = QuickBEAM.eval(rt, """
        (() => {
          const container = document.createElement('div');
          const inner = document.createElement('span');
          inner.setAttribute('class', 'x');
          container.appendChild(inner);
          const outer = document.createElement('span');
          outer.setAttribute('class', 'x');
          document.body.appendChild(outer);
          document.body.appendChild(container);
          return container.getElementsByClassName('x').length;
        })()
      """)
    end
  end

  describe "getElementsByTagName" do
    test "finds elements by tag on document", %{runtime: rt} do
      assert {:ok, 3} = QuickBEAM.eval(rt, """
        (() => {
          document.body.innerHTML = '';
          for (let i = 0; i < 3; i++) {
            document.body.appendChild(document.createElement('span'));
          }
          return document.getElementsByTagName('span').length;
        })()
      """)
    end

    test "scoped to element", %{runtime: rt} do
      assert {:ok, 1} = QuickBEAM.eval(rt, """
        (() => {
          const div = document.createElement('div');
          div.appendChild(document.createElement('p'));
          document.body.appendChild(div);
          document.body.appendChild(document.createElement('p'));
          return div.getElementsByTagName('p').length;
        })()
      """)
    end
  end

  describe "insertBefore" do
    test "inserts before reference node", %{runtime: rt} do
      assert {:ok, "a,c,b"} = QuickBEAM.eval(rt, """
        (() => {
          const div = document.createElement('div');
          const a = document.createElement('a');
          const b = document.createElement('b');
          const c = document.createElement('c');
          div.appendChild(a);
          div.appendChild(b);
          div.insertBefore(c, b);
          return Array.from(div.children).map(c => c.tagName).join(',');
        })()
      """)
    end

    test "inserts at end when reference is null", %{runtime: rt} do
      assert {:ok, "a,b"} = QuickBEAM.eval(rt, """
        (() => {
          const div = document.createElement('div');
          const a = document.createElement('a');
          const b = document.createElement('b');
          div.appendChild(a);
          div.insertBefore(b, null);
          return Array.from(div.children).map(c => c.tagName).join(',');
        })()
      """)
    end
  end

  describe "replaceChild" do
    test "replaces old child with new", %{runtime: rt} do
      assert {:ok, "a,c"} = QuickBEAM.eval(rt, """
        (() => {
          const div = document.createElement('div');
          const a = document.createElement('a');
          const b = document.createElement('b');
          const c = document.createElement('c');
          div.appendChild(a);
          div.appendChild(b);
          div.replaceChild(c, b);
          return Array.from(div.children).map(c => c.tagName).join(',');
        })()
      """)
    end

    test "returns the replaced node", %{runtime: rt} do
      assert {:ok, "a"} = QuickBEAM.eval(rt, """
        (() => {
          const div = document.createElement('div');
          const a = document.createElement('a');
          const b = document.createElement('b');
          div.appendChild(a);
          const old = div.replaceChild(b, a);
          return old.tagName;
        })()
      """)
    end
  end

  describe "cloneNode" do
    test "shallow clone copies element and attributes", %{runtime: rt} do
      assert {:ok, result} = QuickBEAM.eval(rt, """
        (() => {
          const el = document.createElement('div');
          el.setAttribute('class', 'test');
          el.appendChild(document.createElement('span'));
          const clone = el.cloneNode(false);
          return { tag: clone.tagName, cls: clone.getAttribute('class'), children: clone.childNodes.length };
        })()
      """)
      assert result["tag"] == "div"
      assert result["cls"] == "test"
      assert result["children"] == 0
    end

    test "deep clone copies children", %{runtime: rt} do
      assert {:ok, 1} = QuickBEAM.eval(rt, """
        (() => {
          const el = document.createElement('div');
          el.appendChild(document.createElement('span'));
          const clone = el.cloneNode(true);
          return clone.childNodes.length;
        })()
      """)
    end
  end

  describe "contains" do
    test "parent contains child", %{runtime: rt} do
      assert {:ok, true} = QuickBEAM.eval(rt, """
        (() => {
          const div = document.createElement('div');
          const span = document.createElement('span');
          div.appendChild(span);
          return div.contains(span);
        })()
      """)
    end

    test "contains itself", %{runtime: rt} do
      assert {:ok, true} = QuickBEAM.eval(rt, """
        (() => {
          const div = document.createElement('div');
          return div.contains(div);
        })()
      """)
    end

    test "does not contain unrelated node", %{runtime: rt} do
      assert {:ok, false} = QuickBEAM.eval(rt, """
        (() => {
          const a = document.createElement('div');
          const b = document.createElement('div');
          return a.contains(b);
        })()
      """)
    end

    test "contains deeply nested", %{runtime: rt} do
      assert {:ok, true} = QuickBEAM.eval(rt, """
        (() => {
          const a = document.createElement('div');
          const b = document.createElement('div');
          const c = document.createElement('div');
          a.appendChild(b);
          b.appendChild(c);
          return a.contains(c);
        })()
      """)
    end
  end

  describe "remove" do
    test "removes self from parent", %{runtime: rt} do
      assert {:ok, 0} = QuickBEAM.eval(rt, """
        (() => {
          const div = document.createElement('div');
          const span = document.createElement('span');
          div.appendChild(span);
          span.remove();
          return div.children.length;
        })()
      """)
    end
  end

  describe "before/after" do
    test "before inserts sibling before", %{runtime: rt} do
      assert {:ok, "a,b"} = QuickBEAM.eval(rt, """
        (() => {
          const div = document.createElement('div');
          const b = document.createElement('b');
          div.appendChild(b);
          const a = document.createElement('a');
          b.before(a);
          return Array.from(div.children).map(c => c.tagName).join(',');
        })()
      """)
    end

    test "after inserts sibling after", %{runtime: rt} do
      assert {:ok, "a,b"} = QuickBEAM.eval(rt, """
        (() => {
          const div = document.createElement('div');
          const a = document.createElement('a');
          div.appendChild(a);
          const b = document.createElement('b');
          a.after(b);
          return Array.from(div.children).map(c => c.tagName).join(',');
        })()
      """)
    end
  end

  describe "prepend/append" do
    test "prepend adds to beginning", %{runtime: rt} do
      assert {:ok, "a,b"} = QuickBEAM.eval(rt, """
        (() => {
          const div = document.createElement('div');
          const b = document.createElement('b');
          div.appendChild(b);
          const a = document.createElement('a');
          div.prepend(a);
          return Array.from(div.children).map(c => c.tagName).join(',');
        })()
      """)
    end

    test "append adds to end", %{runtime: rt} do
      assert {:ok, "a,b"} = QuickBEAM.eval(rt, """
        (() => {
          const div = document.createElement('div');
          const a = document.createElement('a');
          div.appendChild(a);
          const b = document.createElement('b');
          div.append(b);
          return Array.from(div.children).map(c => c.tagName).join(',');
        })()
      """)
    end
  end

  describe "replaceWith" do
    test "replaces self with another node", %{runtime: rt} do
      assert {:ok, "b"} = QuickBEAM.eval(rt, """
        (() => {
          const div = document.createElement('div');
          const a = document.createElement('a');
          div.appendChild(a);
          const b = document.createElement('b');
          a.replaceWith(b);
          return div.firstChild.tagName;
        })()
      """)
    end
  end

  describe "matches" do
    test "matches a selector", %{runtime: rt} do
      assert {:ok, true} = QuickBEAM.eval(rt, """
        (() => {
          const div = document.createElement('div');
          div.setAttribute('class', 'foo');
          document.body.appendChild(div);
          return div.matches('.foo');
        })()
      """)
    end

    test "does not match wrong selector", %{runtime: rt} do
      assert {:ok, false} = QuickBEAM.eval(rt, """
        (() => {
          const div = document.createElement('div');
          div.setAttribute('class', 'foo');
          document.body.appendChild(div);
          return div.matches('.bar');
        })()
      """)
    end
  end

  describe "closest" do
    test "finds closest ancestor matching selector", %{runtime: rt} do
      assert {:ok, "section"} = QuickBEAM.eval(rt, """
        (() => {
          const section = document.createElement('section');
          section.setAttribute('class', 'container');
          const div = document.createElement('div');
          const span = document.createElement('span');
          section.appendChild(div);
          div.appendChild(span);
          document.body.appendChild(section);
          return span.closest('.container').tagName;
        })()
      """)
    end

    test "returns null when no match", %{runtime: rt} do
      assert {:ok, nil} = QuickBEAM.eval(rt, """
        (() => {
          const div = document.createElement('div');
          document.body.appendChild(div);
          return div.closest('.nonexistent');
        })()
      """)
    end

    test "can match self", %{runtime: rt} do
      assert {:ok, "div"} = QuickBEAM.eval(rt, """
        (() => {
          const div = document.createElement('div');
          div.setAttribute('class', 'self');
          document.body.appendChild(div);
          return div.closest('.self').tagName;
        })()
      """)
    end
  end

  describe "lastChild" do
    test "returns last child node", %{runtime: rt} do
      assert {:ok, "b"} = QuickBEAM.eval(rt, """
        (() => {
          const div = document.createElement('div');
          div.appendChild(document.createElement('a'));
          div.appendChild(document.createElement('b'));
          return div.lastChild.tagName;
        })()
      """)
    end

    test "returns null on empty element", %{runtime: rt} do
      assert {:ok, nil} = QuickBEAM.eval(rt, """
        document.createElement('div').lastChild;
      """)
    end
  end

  describe "previousSibling" do
    test "returns previous sibling", %{runtime: rt} do
      assert {:ok, "a"} = QuickBEAM.eval(rt, """
        (() => {
          const div = document.createElement('div');
          const a = document.createElement('a');
          const b = document.createElement('b');
          div.appendChild(a);
          div.appendChild(b);
          return b.previousSibling.tagName;
        })()
      """)
    end

    test "returns null on first child", %{runtime: rt} do
      assert {:ok, nil} = QuickBEAM.eval(rt, """
        (() => {
          const div = document.createElement('div');
          const a = document.createElement('a');
          div.appendChild(a);
          return a.previousSibling;
        })()
      """)
    end
  end

  describe "nodeType" do
    test "element nodeType is 1", %{runtime: rt} do
      assert {:ok, 1} = QuickBEAM.eval(rt, "document.createElement('div').nodeType")
    end

    test "text nodeType is 3", %{runtime: rt} do
      assert {:ok, 3} = QuickBEAM.eval(rt, "document.createTextNode('hi').nodeType")
    end

    test "comment nodeType is 8", %{runtime: rt} do
      assert {:ok, 8} = QuickBEAM.eval(rt, "document.createComment('c').nodeType")
    end

    test "fragment nodeType is 11", %{runtime: rt} do
      assert {:ok, 11} = QuickBEAM.eval(rt, "document.createDocumentFragment().nodeType")
    end
  end

  describe "nodeName" do
    test "element nodeName is tag name", %{runtime: rt} do
      assert {:ok, "div"} = QuickBEAM.eval(rt, "document.createElement('div').nodeName")
    end

    test "text nodeName is #text", %{runtime: rt} do
      assert {:ok, "#text"} = QuickBEAM.eval(rt, "document.createTextNode('hi').nodeName")
    end

    test "comment nodeName is #comment", %{runtime: rt} do
      assert {:ok, "#comment"} = QuickBEAM.eval(rt, "document.createComment('c').nodeName")
    end
  end

  describe "parentElement" do
    test "returns parent element", %{runtime: rt} do
      assert {:ok, "div"} = QuickBEAM.eval(rt, """
        (() => {
          const div = document.createElement('div');
          const span = document.createElement('span');
          div.appendChild(span);
          return span.parentElement.tagName;
        })()
      """)
    end

    test "returns null when parent is document", %{runtime: rt} do
      assert {:ok, nil} = QuickBEAM.eval(rt, """
        document.documentElement.parentElement;
      """)
    end
  end

  describe "className setter" do
    test "sets class attribute", %{runtime: rt} do
      assert {:ok, "foo bar"} = QuickBEAM.eval(rt, """
        (() => {
          const el = document.createElement('div');
          el.className = 'foo bar';
          return el.getAttribute('class');
        })()
      """)
    end
  end

  describe "classList" do
    test "add and contains", %{runtime: rt} do
      assert {:ok, true} = QuickBEAM.eval(rt, """
        (() => {
          const el = document.createElement('div');
          el.classList.add('foo');
          return el.classList.contains('foo');
        })()
      """)
    end

    test "remove", %{runtime: rt} do
      assert {:ok, false} = QuickBEAM.eval(rt, """
        (() => {
          const el = document.createElement('div');
          el.classList.add('foo', 'bar');
          el.classList.remove('foo');
          return el.classList.contains('foo');
        })()
      """)
    end

    test "toggle", %{runtime: rt} do
      assert {:ok, result} = QuickBEAM.eval(rt, """
        (() => {
          const el = document.createElement('div');
          const added = el.classList.toggle('foo');
          const removed = el.classList.toggle('foo');
          return { added, removed, has: el.classList.contains('foo') };
        })()
      """)
      assert result["added"] == true
      assert result["removed"] == false
      assert result["has"] == false
    end

    test "replace", %{runtime: rt} do
      assert {:ok, "bar"} = QuickBEAM.eval(rt, """
        (() => {
          const el = document.createElement('div');
          el.classList.add('foo');
          el.classList.replace('foo', 'bar');
          return el.getAttribute('class');
        })()
      """)
    end

    test "length", %{runtime: rt} do
      assert {:ok, 2} = QuickBEAM.eval(rt, """
        (() => {
          const el = document.createElement('div');
          el.classList.add('a', 'b');
          return el.classList.length;
        })()
      """)
    end

    test "iteration", %{runtime: rt} do
      assert {:ok, "a,b,c"} = QuickBEAM.eval(rt, """
        (() => {
          const el = document.createElement('div');
          el.classList.add('a', 'b', 'c');
          return [...el.classList].join(',');
        })()
      """)
    end
  end

  describe "nodeValue" do
    test "text node has nodeValue", %{runtime: rt} do
      assert {:ok, "hello"} = QuickBEAM.eval(rt, "document.createTextNode('hello').nodeValue")
    end

    test "element nodeValue is null", %{runtime: rt} do
      assert {:ok, nil} = QuickBEAM.eval(rt, "document.createElement('div').nodeValue")
    end
  end
end
