defmodule QuickBEAM.DOM.DOMElixirTest do
  use ExUnit.Case, async: true

  setup do
    {:ok, runtime} = QuickBEAM.start()

    QuickBEAM.eval(runtime, """
      document.body.innerHTML = [
        '<div id="app" class="container">',
          '<h1>Hello World</h1>',
          '<ul>',
            '<li class="item" data-index="0">First</li>',
            '<li class="item" data-index="1">Second</li>',
            '<li class="item" data-index="2">Third</li>',
          '</ul>',
          '<a href="/about" title="About page">About</a>',
          '<p>Some <strong>bold</strong> text</p>',
        '</div>'
      ].join('');
    """)

    on_exit(fn ->
      try do
        QuickBEAM.stop(runtime)
      catch
        :exit, _ -> :ok
      end
    end)

    %{runtime: runtime}
  end

  describe "dom_find" do
    test "returns Floki-compatible tuple for matched element", %{runtime: rt} do
      {:ok, {"h1", [], ["Hello World"]}} = QuickBEAM.dom_find(rt, "h1")
    end

    test "returns element with attributes", %{runtime: rt} do
      {:ok, {"div", attrs, _children}} = QuickBEAM.dom_find(rt, "#app")
      assert {"id", "app"} in attrs
      assert {"class", "container"} in attrs
    end

    test "returns nil when not found", %{runtime: rt} do
      {:ok, nil} = QuickBEAM.dom_find(rt, ".nonexistent")
    end

    test "returns nested children recursively", %{runtime: rt} do
      {:ok, {"p", [], children}} = QuickBEAM.dom_find(rt, "p")
      assert ["Some ", {"strong", [], ["bold"]}, " text"] = children
    end

    test "finds first match", %{runtime: rt} do
      {:ok, {"li", attrs, ["First"]}} = QuickBEAM.dom_find(rt, "li")
      assert {"data-index", "0"} in attrs
    end
  end

  describe "dom_find_all" do
    test "returns list of matched elements", %{runtime: rt} do
      {:ok, items} = QuickBEAM.dom_find_all(rt, "li.item")
      assert length(items) == 3
    end

    test "each element is a Floki-compatible tuple", %{runtime: rt} do
      {:ok, items} = QuickBEAM.dom_find_all(rt, "li.item")
      texts = Enum.map(items, fn {_, _, [text]} -> text end)
      assert texts == ["First", "Second", "Third"]
    end

    test "returns empty list when nothing matches", %{runtime: rt} do
      {:ok, []} = QuickBEAM.dom_find_all(rt, ".nope")
    end

    test "returns attributes for each element", %{runtime: rt} do
      {:ok, items} = QuickBEAM.dom_find_all(rt, "li.item")

      indices =
        Enum.map(items, fn {_, attrs, _} ->
          {_, idx} = List.keyfind(attrs, "data-index", 0)
          idx
        end)

      assert indices == ["0", "1", "2"]
    end
  end

  describe "dom_text" do
    test "extracts text content", %{runtime: rt} do
      {:ok, "Hello World"} = QuickBEAM.dom_text(rt, "h1")
    end

    test "extracts deep text content", %{runtime: rt} do
      {:ok, text} = QuickBEAM.dom_text(rt, "p")
      assert text == "Some bold text"
    end

    test "returns empty string when not found", %{runtime: rt} do
      {:ok, ""} = QuickBEAM.dom_text(rt, ".nope")
    end
  end

  describe "dom_attr" do
    test "returns attribute value", %{runtime: rt} do
      {:ok, "/about"} = QuickBEAM.dom_attr(rt, "a", "href")
    end

    test "returns nil for missing attribute", %{runtime: rt} do
      {:ok, nil} = QuickBEAM.dom_attr(rt, "a", "rel")
    end

    test "returns nil when element not found", %{runtime: rt} do
      {:ok, nil} = QuickBEAM.dom_attr(rt, ".nope", "id")
    end

    test "returns class attribute", %{runtime: rt} do
      {:ok, "container"} = QuickBEAM.dom_attr(rt, "#app", "class")
    end
  end

  describe "dom_html" do
    test "serializes the full document", %{runtime: rt} do
      {:ok, html} = QuickBEAM.dom_html(rt)
      assert html =~ "<h1>Hello World</h1>"
      assert html =~ "<html>"
      assert html =~ "<body>"
    end
  end

  describe "JS mutations visible from Elixir" do
    test "Elixir sees JS DOM changes", %{runtime: rt} do
      QuickBEAM.eval(rt, """
        const newEl = document.createElement('footer');
        newEl.id = 'ft';
        newEl.textContent = 'Footer content';
        document.body.appendChild(newEl);
      """)

      {:ok, {"footer", [{"id", "ft"}], ["Footer content"]}} =
        QuickBEAM.dom_find(rt, "footer#ft")
    end

    test "JS innerHTML replacement visible from Elixir", %{runtime: rt} do
      QuickBEAM.eval(rt, "document.body.innerHTML = '<section>New</section>'")
      {:ok, "New"} = QuickBEAM.dom_text(rt, "section")
      {:ok, nil} = QuickBEAM.dom_find(rt, "h1")
    end
  end

  describe "interleaved JS and Elixir access" do
    test "alternating eval and dom queries", %{runtime: rt} do
      {:ok, 3} = QuickBEAM.eval(rt, "document.querySelectorAll('li').length")
      {:ok, items} = QuickBEAM.dom_find_all(rt, "li")
      assert length(items) == 3

      QuickBEAM.eval(rt, """
        const li = document.createElement('li');
        li.setAttribute('class', 'item');
        li.textContent = 'Fourth';
        document.querySelector('ul').appendChild(li);
      """)

      {:ok, items} = QuickBEAM.dom_find_all(rt, "li")
      assert length(items) == 4
    end
  end
end
