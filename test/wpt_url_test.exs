defmodule QuickBEAM.WPT.URLTest do
  @moduledoc "Ported from WPT: url-searchparams.any.js, url-tojson.any.js"
  use ExUnit.Case, async: true

  setup do
    {:ok, rt} = QuickBEAM.start()
    on_exit(fn -> try do QuickBEAM.stop(rt) catch :exit, _ -> :ok end end)
    %{rt: rt}
  end

  # ── URL.searchParams (url-searchparams.any.js) ──

  describe "WPT URL.searchParams" do
    test "getter returns same object", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const url = new URL('http://example.org/?a=b');
               url.searchParams === url.searchParams
               """)
    end

    test "searchParams.toString reflects URL", %{rt: rt} do
      assert {:ok, "a=b"} =
               QuickBEAM.eval(rt, """
               new URL('http://example.org/?a=b').searchParams.toString()
               """)
    end

    test "setting search propagates to searchParams", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const url = new URL('http://example.org/file?a=b&c=d');
               url.search = 'e=f&g=h';
               url.searchParams.toString() === 'e=f&g=h'
               """)
    end

    test "setting search with leading ? works", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const url = new URL('http://example.org/file?a=b');
               url.search = '?e=f&g=h';
               url.searchParams.toString() === 'e=f&g=h'
               """)
    end

    test "searchParams.append propagates to URL.search", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const url = new URL('http://example.org/file?e=f&g=h');
               url.searchParams.append('i', ' j ');
               url.search === '?e=f&g=h&i=+j+'
               """)
    end

    test "searchParams.set propagates to URL.search", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const url = new URL('http://example.org/file?e=f&g=h');
               url.searchParams.set('e', 'updated');
               url.searchParams.get('e') === 'updated'
               """)
    end

    test "clearing search clears searchParams", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const url = new URL('http://example.org/?a=b');
               url.search = '';
               url.searchParams.toString() === '' && url.search === ''
               """)
    end

    test "double ? in query string", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const url = new URL('http://example.org/file??a=b&c=d');
               url.search === '??a=b&c=d' &&
                 url.searchParams.toString() === '%3Fa=b&c=d'
               """)
    end
  end

  # ── URL.toJSON (url-tojson.any.js) ──

  describe "WPT URL.toJSON" do
    test "JSON.stringify uses toJSON", %{rt: rt} do
      assert {:ok, "\"https://example.com/\""} =
               QuickBEAM.eval(rt, """
               JSON.stringify(new URL('https://example.com/'))
               """)
    end
  end

  # ── URL constructor edge cases ──

  describe "WPT URL constructor edge cases" do
    test "invalid URL throws TypeError", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               try { new URL('not a url'); false; } catch (e) { e instanceof TypeError; }
               """)
    end

    test "relative URL with base", %{rt: rt} do
      assert {:ok, "http://example.com/path"} =
               QuickBEAM.eval(rt, "new URL('/path', 'http://example.com').href")
    end

    test "URL properties", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const url = new URL('https://user:pass@example.com:8080/path?q=1#hash');
               url.protocol === 'https:' &&
               url.username === 'user' &&
               url.password === 'pass' &&
               url.hostname === 'example.com' &&
               url.port === '8080' &&
               url.pathname === '/path' &&
               url.search === '?q=1' &&
               url.hash === '#hash'
               """)
    end

    test "URL.canParse", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               URL.canParse('https://example.com') === true &&
               URL.canParse('not valid') === false
               """)
    end
  end
end
