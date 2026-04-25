defmodule QuickBEAM.WebAPIs.BeamWebAPIsTest do
  @moduledoc "Web API tests running in BEAM mode (no NIF). Mirrors web_apis_test.exs."
  use ExUnit.Case, async: true
  @moduletag :beam_web_apis

  setup do
    QuickBEAM.VM.Heap.reset()
    {:ok, rt} = QuickBEAM.start(mode: :beam)
    {:ok, rt: rt}
  end

  defp eval(rt, js), do: QuickBEAM.eval(rt, js, mode: :beam)

  # ── TextEncoder ──

  describe "TextEncoder" do
    test "encoding property is utf-8", %{rt: rt} do
      assert {:ok, "utf-8"} = eval(rt, "new TextEncoder().encoding")
    end

    test "encode ASCII", %{rt: rt} do
      assert {:ok, [72, 101, 108, 108, 111]} =
               eval(rt, "[...new TextEncoder().encode('Hello')]")
    end

    test "encode empty string", %{rt: rt} do
      assert {:ok, []} = eval(rt, "[...new TextEncoder().encode('')]")
    end

    test "encode unicode", %{rt: rt} do
      assert {:ok, [240, 159, 154, 128]} =
               eval(rt, "[...new TextEncoder().encode('🚀')]")
    end

    test "encode returns Uint8Array", %{rt: rt} do
      assert {:ok, true} =
               eval(rt, "new TextEncoder().encode('test') instanceof Uint8Array")
    end
  end

  # ── TextDecoder ──

  describe "TextDecoder" do
    test "decode ASCII", %{rt: rt} do
      assert {:ok, "Hello"} =
               eval(rt, "new TextDecoder().decode(new Uint8Array([72,101,108,108,111]))")
    end

    test "encoding property", %{rt: rt} do
      assert {:ok, "utf-8"} = eval(rt, "new TextDecoder().encoding")
    end
  end

  # ── URL ──

  describe "URL" do
    test "parse basic URL", %{rt: rt} do
      assert {:ok, "https://example.com/"} = eval(rt, "new URL('https://example.com').href")
    end

    test "pathname", %{rt: rt} do
      assert {:ok, "/path"} = eval(rt, "new URL('https://example.com/path').pathname")
    end

    test "searchParams", %{rt: rt} do
      assert {:ok, "1"} = eval(rt, "new URL('https://example.com?q=1').searchParams.get('q')")
    end

    test "hash", %{rt: rt} do
      assert {:ok, "#frag"} = eval(rt, "new URL('https://example.com#frag').hash")
    end

    test "origin", %{rt: rt} do
      assert {:ok, "https://example.com"} = eval(rt, "new URL('https://example.com/p').origin")
    end
  end

  # ── URLSearchParams ──

  describe "URLSearchParams" do
    test "construct from string", %{rt: rt} do
      assert {:ok, "1"} = eval(rt, "new URLSearchParams('a=1&b=2').get('a')")
    end

    test "append and toString", %{rt: rt} do
      assert {:ok, "a=1&b=2"} =
               eval(rt, "var p = new URLSearchParams(); p.append('a','1'); p.append('b','2'); p.toString()")
    end
  end

  # ── atob / btoa ──

  describe "atob/btoa" do
    test "btoa encodes", %{rt: rt} do
      assert {:ok, "SGVsbG8="} = eval(rt, "btoa('Hello')")
    end

    test "atob decodes", %{rt: rt} do
      assert {:ok, "Hello"} = eval(rt, "atob('SGVsbG8=')")
    end

    test "roundtrip", %{rt: rt} do
      assert {:ok, "test"} = eval(rt, "atob(btoa('test'))")
    end
  end

  # ── setTimeout / clearTimeout ──

  describe "setTimeout" do
    test "setTimeout returns numeric id", %{rt: rt} do
      assert {:ok, true} = eval(rt, "typeof setTimeout(() => {}, 0) === 'number'")
    end

    test "clearTimeout accepts id", %{rt: rt} do
      assert {:ok, nil} = eval(rt, "clearTimeout(setTimeout(() => {}, 1000))")
    end
  end

  # ── Headers ──

  describe "Headers" do
    test "construct empty", %{rt: rt} do
      assert {:ok, ""} = eval(rt, "new Headers().get('x')||''")
    end

    test "set and get", %{rt: rt} do
      assert {:ok, "bar"} = eval(rt, "var h = new Headers(); h.set('foo','bar'); h.get('foo')")
    end

    test "construct from object", %{rt: rt} do
      assert {:ok, "val"} = eval(rt, "new Headers({'key':'val'}).get('key')")
    end
  end

  # ── AbortController ──

  describe "AbortController" do
    test "signal starts not aborted", %{rt: rt} do
      assert {:ok, false} = eval(rt, "new AbortController().signal.aborted")
    end

    test "abort sets signal", %{rt: rt} do
      assert {:ok, true} =
               eval(rt, "var ac = new AbortController(); ac.abort(); ac.signal.aborted")
    end
  end

  # ── performance ──

  describe "performance" do
    test "performance.now returns number", %{rt: rt} do
      assert {:ok, true} = eval(rt, "typeof performance.now() === 'number'")
    end
  end

  # ── Blob ──

  describe "Blob" do
    test "construct with string", %{rt: rt} do
      assert {:ok, 5} = eval(rt, "new Blob(['Hello']).size")
    end

    test "type property", %{rt: rt} do
      assert {:ok, "text/plain"} =
               eval(rt, "new Blob(['x'], {type: 'text/plain'}).type")
    end
  end

  # ── crypto ──

  describe "crypto" do
    test "getRandomValues fills array", %{rt: rt} do
      assert {:ok, 16} =
               eval(rt, "crypto.getRandomValues(new Uint8Array(16)).length")
    end

    test "randomUUID returns string", %{rt: rt} do
      assert {:ok, true} = eval(rt, "typeof crypto.randomUUID() === 'string'")
    end
  end

  # ── fetch basic ──

  describe "fetch" do
    test "fetch is a function", %{rt: rt} do
      assert {:ok, "function"} = eval(rt, "typeof fetch")
    end

    test "Request constructor", %{rt: rt} do
      assert {:ok, "https://example.com/"} = eval(rt, "new Request('https://example.com').url")
    end

    test "Response constructor", %{rt: rt} do
      assert {:ok, 200} = eval(rt, "new Response('ok').status")
    end
  end
end
