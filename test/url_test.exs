defmodule QuickBEAM.URLTest do
  use ExUnit.Case, async: true

  setup do
    {:ok, rt} = QuickBEAM.start()
    {:ok, rt: rt}
  end

  describe "URL constructor" do
    test "parses basic URL", %{rt: rt} do
      assert {:ok, "https://example.com/path"} =
               QuickBEAM.eval(rt, "new URL('https://example.com/path').href")
    end

    test "parses URL with all components", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const u = new URL('https://user:pass@example.com:8080/path?q=1#frag');
               u.protocol === 'https:' &&
               u.username === 'user' &&
               u.password === 'pass' &&
               u.hostname === 'example.com' &&
               u.port === '8080' &&
               u.pathname === '/path' &&
               u.search === '?q=1' &&
               u.hash === '#frag';
               """)
    end

    test "throws TypeError on invalid URL", %{rt: rt} do
      assert {:error, %QuickBEAM.JSError{name: "TypeError"}} =
               QuickBEAM.eval(rt, "new URL('not-a-url')")
    end

    test "resolves relative URL against base", %{rt: rt} do
      assert {:ok, "https://example.com/bar"} =
               QuickBEAM.eval(rt, "new URL('/bar', 'https://example.com/foo').href")
    end

    test "resolves .. segments", %{rt: rt} do
      assert {:ok, "https://example.com/bar"} =
               QuickBEAM.eval(rt, "new URL('../bar', 'https://example.com/foo/baz').href")
    end

    test "absolute URL ignores base", %{rt: rt} do
      assert {:ok, "https://other.com/"} =
               QuickBEAM.eval(rt, "new URL('https://other.com/', 'https://example.com/').href")
    end

    test "throws on invalid base", %{rt: rt} do
      assert {:error, %QuickBEAM.JSError{}} =
               QuickBEAM.eval(rt, "new URL('/path', 'not-a-url')")
    end
  end

  describe "URL properties" do
    test "protocol", %{rt: rt} do
      assert {:ok, "https:"} = QuickBEAM.eval(rt, "new URL('https://example.com').protocol")
    end

    test "hostname is lowercased", %{rt: rt} do
      assert {:ok, "example.com"} =
               QuickBEAM.eval(rt, "new URL('https://EXAMPLE.COM').hostname")
    end

    test "default port is empty string", %{rt: rt} do
      assert {:ok, ""} = QuickBEAM.eval(rt, "new URL('https://example.com').port")
      assert {:ok, ""} = QuickBEAM.eval(rt, "new URL('http://example.com').port")
    end

    test "non-default port is returned", %{rt: rt} do
      assert {:ok, "8080"} = QuickBEAM.eval(rt, "new URL('https://example.com:8080').port")
    end

    test "explicit default port 443 is omitted", %{rt: rt} do
      assert {:ok, ""} = QuickBEAM.eval(rt, "new URL('https://example.com:443').port")
    end

    test "pathname defaults to /", %{rt: rt} do
      assert {:ok, "/"} = QuickBEAM.eval(rt, "new URL('https://example.com').pathname")
    end

    test "search includes ?", %{rt: rt} do
      assert {:ok, "?q=1"} = QuickBEAM.eval(rt, "new URL('https://example.com?q=1').search")
    end

    test "empty search is empty string", %{rt: rt} do
      assert {:ok, ""} = QuickBEAM.eval(rt, "new URL('https://example.com').search")
    end

    test "hash includes #", %{rt: rt} do
      assert {:ok, "#frag"} = QuickBEAM.eval(rt, "new URL('https://example.com#frag').hash")
    end

    test "empty hash is empty string", %{rt: rt} do
      assert {:ok, ""} = QuickBEAM.eval(rt, "new URL('https://example.com').hash")
    end

    test "host includes port when non-default", %{rt: rt} do
      assert {:ok, "example.com:8080"} =
               QuickBEAM.eval(rt, "new URL('https://example.com:8080').host")
    end

    test "host omits default port", %{rt: rt} do
      assert {:ok, "example.com"} =
               QuickBEAM.eval(rt, "new URL('https://example.com:443').host")
    end

    test "origin for http/https", %{rt: rt} do
      assert {:ok, "https://example.com"} =
               QuickBEAM.eval(rt, "new URL('https://example.com/path').origin")
    end

    test "origin with non-default port", %{rt: rt} do
      assert {:ok, "https://example.com:8080"} =
               QuickBEAM.eval(rt, "new URL('https://example.com:8080').origin")
    end
  end

  describe "URL setters" do
    test "set pathname updates href", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const u = new URL('https://example.com/foo');
               u.pathname = '/bar';
               u.pathname === '/bar' && u.href.includes('/bar');
               """)
    end

    test "set search updates href", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const u = new URL('https://example.com/path');
               u.search = '?q=hello';
               u.search === '?q=hello' && u.href.includes('?q=hello');
               """)
    end

    test "set hash updates href", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const u = new URL('https://example.com/path');
               u.hash = '#section';
               u.hash === '#section' && u.href.includes('#section');
               """)
    end

    test "set hostname updates href", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const u = new URL('https://example.com/path');
               u.hostname = 'other.com';
               u.hostname === 'other.com' && u.href.includes('other.com');
               """)
    end

    test "set port updates href and host", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const u = new URL('https://example.com/path');
               u.port = '9090';
               u.port === '9090' && u.host === 'example.com:9090';
               """)
    end
  end

  describe "URL.toString and toJSON" do
    test "toString returns href", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const u = new URL('https://example.com/path');
               u.toString() === u.href;
               """)
    end

    test "toJSON returns href", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const u = new URL('https://example.com/path');
               u.toJSON() === u.href;
               """)
    end
  end

  describe "URL.canParse" do
    test "returns true for valid URL", %{rt: rt} do
      assert {:ok, true} = QuickBEAM.eval(rt, "URL.canParse('https://example.com')")
    end

    test "returns false for invalid URL", %{rt: rt} do
      assert {:ok, false} = QuickBEAM.eval(rt, "URL.canParse('not-a-url')")
    end

    test "returns true with valid base", %{rt: rt} do
      assert {:ok, true} = QuickBEAM.eval(rt, "URL.canParse('/path', 'https://example.com')")
    end
  end

  describe "URLSearchParams" do
    test "constructor from string", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const p = new URLSearchParams('a=1&b=2');
               p.get('a') === '1' && p.get('b') === '2';
               """)
    end

    test "constructor from string with leading ?", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const p = new URLSearchParams('?a=1&b=2');
               p.get('a') === '1' && p.get('b') === '2';
               """)
    end

    test "constructor from array", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const p = new URLSearchParams([['a', '1'], ['b', '2']]);
               p.get('a') === '1' && p.get('b') === '2';
               """)
    end

    test "constructor from object", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const p = new URLSearchParams({a: '1', b: '2'});
               p.get('a') === '1' && p.get('b') === '2';
               """)
    end

    test "append", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const p = new URLSearchParams();
               p.append('key', 'val');
               p.get('key') === 'val' && p.toString() === 'key=val';
               """)
    end

    test "delete by name", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const p = new URLSearchParams('a=1&b=2&a=3');
               p.delete('a');
               p.get('a') === null && p.get('b') === '2';
               """)
    end

    test "delete by name and value", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const p = new URLSearchParams('a=1&b=2&a=3');
               p.delete('a', '1');
               p.getAll('a').length === 1 && p.getAll('a')[0] === '3';
               """)
    end

    test "has", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const p = new URLSearchParams('a=1');
               p.has('a') && !p.has('b');
               """)
    end

    test "set overwrites first, removes rest", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const p = new URLSearchParams('a=1&b=2&a=3');
               p.set('a', 'updated');
               p.getAll('a').length === 1 && p.get('a') === 'updated';
               """)
    end

    test "sort", %{rt: rt} do
      assert {:ok, "a=1&a=2&b=3"} =
               QuickBEAM.eval(rt, """
               const p = new URLSearchParams('b=3&a=1&a=2');
               p.sort();
               p.toString();
               """)
    end

    test "size", %{rt: rt} do
      assert {:ok, 3} =
               QuickBEAM.eval(rt, "new URLSearchParams('a=1&b=2&c=3').size")
    end

    test "iteration", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const p = new URLSearchParams('a=1&b=2');
               const pairs = [...p];
               pairs.length === 2 && pairs[0][0] === 'a' && pairs[0][1] === '1';
               """)
    end

    test "forEach", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const p = new URLSearchParams('a=1&b=2');
               const collected = [];
               p.forEach((v, k) => collected.push([k, v]));
               collected.length === 2 && collected[0][0] === 'a';
               """)
    end

    test "keys/values", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const p = new URLSearchParams('a=1&b=2');
               [...p.keys()].join(',') === 'a,b' &&
               [...p.values()].join(',') === '1,2';
               """)
    end

    test "plus decodes as space", %{rt: rt} do
      assert {:ok, " "} =
               QuickBEAM.eval(rt, "new URLSearchParams('key=+').get('key')")
    end

    test "percent-encoded values", %{rt: rt} do
      assert {:ok, "hello world"} =
               QuickBEAM.eval(rt, "new URLSearchParams('key=hello%20world').get('key')")
    end
  end

  describe "URL.searchParams integration" do
    test "searchParams reflects URL query", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const u = new URL('https://example.com?a=1&b=2');
               u.searchParams.get('a') === '1' && u.searchParams.get('b') === '2';
               """)
    end

    test "searchParams identity", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const u = new URL('https://example.com?a=b');
               u.searchParams === u.searchParams;
               """)
    end

    test "searchParams mutation updates URL", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const u = new URL('https://example.com/path?a=1');
               u.searchParams.set('a', 'updated');
               u.search === '?a=updated' && u.href.includes('?a=updated');
               """)
    end

    test "searchParams.append updates URL", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const u = new URL('https://example.com/path?a=1');
               u.searchParams.append('b', '2');
               u.search.includes('b=2');
               """)
    end

    test "URL.search setter updates searchParams", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const u = new URL('https://example.com/path?a=b');
               u.search = 'e=f&g=h';
               u.searchParams.get('e') === 'f' && u.searchParams.get('g') === 'h';
               """)
    end

    test "clearing search clears searchParams", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const u = new URL('https://example.com/path?a=b');
               u.search = '';
               u.search === '' && u.searchParams.toString() === '';
               """)
    end
  end
end
