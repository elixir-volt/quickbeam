defmodule QuickBEAM.VM.Runtime.WebAPIs do
  @moduledoc "Web API builtins for BEAM mode: TextEncoder, TextDecoder, URL, URLSearchParams, atob/btoa, timers, Headers, AbortController, performance, Blob, crypto, fetch/Request/Response."

  import Bitwise
  import QuickBEAM.VM.Heap.Keys

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.ObjectModel.{Get, Put}
  alias QuickBEAM.VM.Runtime

  def bindings do
    %{
      "TextEncoder" => text_encoder_ctor(),
      "TextDecoder" => text_decoder_ctor(),
      "URL" => url_ctor(),
      "URLSearchParams" => url_search_params_ctor(),
      "btoa" => builtin("btoa", fn [str | _], _ -> Base.encode64(str) end),
      "atob" => builtin("atob", fn [str | _], _ -> Base.decode64!(str) end),
      "setTimeout" => builtin("setTimeout", fn _, _ -> :erlang.unique_integer([:positive]) end),
      "clearTimeout" => builtin("clearTimeout", fn _, _ -> :undefined end),
      "setInterval" => builtin("setInterval", fn _, _ -> :erlang.unique_integer([:positive]) end),
      "clearInterval" => builtin("clearInterval", fn _, _ -> :undefined end),
      "Headers" => headers_ctor(),
      "AbortController" => abort_controller_ctor(),
      "performance" => performance_object(),
      "Blob" => blob_ctor(),
      "crypto" => crypto_object(),
      "fetch" => builtin("fetch", fn _args, _ -> :undefined end),
      "Request" => request_ctor(),
      "Response" => response_ctor()
    }
  end

  # ── TextEncoder ──

  defp text_encoder_ctor do
    register("TextEncoder", fn _args, _this ->
      Heap.wrap(%{
        "encoding" => "utf-8",
        "encode" => builtin("encode", fn args, _this ->
          str = case args do
            [s | _] when is_binary(s) -> s
            _ -> ""
          end
          bytes = :binary.bin_to_list(str)
          make_uint8array(bytes)
        end)
      })
    end)
  end

  defp text_decoder_ctor do
    register("TextDecoder", fn _args, _this ->
      Heap.wrap(%{
        "encoding" => "utf-8",
        "decode" => builtin("decode", fn args, _this ->
          case args do
            [arr | _] ->
              bytes = typed_array_to_list(arr)
              List.to_string(bytes)
            _ -> ""
          end
        end)
      })
    end)
  end

  # ── URL ──

  defp url_ctor do
    register("URL", fn args, _this ->
      [input | rest] = case args do
        [] -> [""]
        a -> a
      end

      input_str = to_string(input)
      base_str = case rest do
        [b | _] when is_binary(b) -> b
        _ -> nil
      end

      parse_args = if base_str, do: [input_str, base_str], else: [input_str]

      case QuickBEAM.URL.parse(parse_args) do
        %{"ok" => true, "components" => c} ->
          make_url_object(c)
        _ ->
          throw({:js_throw, Heap.make_error("Invalid URL: #{input_str}", "TypeError")})
      end
    end)
  end

  defp make_url_object(c) do
    search_params_obj = make_search_params_object(c["search"] || "")

    Heap.wrap(%{
      "href" => c["href"] || "",
      "origin" => c["origin"] || "",
      "protocol" => c["protocol"] || "",
      "username" => c["username"] || "",
      "password" => c["password"] || "",
      "hostname" => c["hostname"] || "",
      "port" => c["port"] || "",
      "pathname" => c["pathname"] || "",
      "search" => c["search"] || "",
      "hash" => c["hash"] || "",
      "searchParams" => search_params_obj,
      "toString" => builtin("toString", fn _, this -> Get.get(this, "href") end)
    })
  end

  # ── URLSearchParams ──

  defp url_search_params_ctor do
    register("URLSearchParams", fn args, _this ->
      init = List.first(args, "")
      make_search_params_from_input(init)
    end)
  end

  defp make_search_params_object(search_str) do
    query = case search_str do
      "?" <> q -> q
      q -> q
    end
    make_search_params_from_input(query)
  end

  defp make_search_params_from_input(input) do
    entries = case input do
      s when is_binary(s) and s != "" ->
        QuickBEAM.URL.dissect_query([s])
      _ -> []
    end

    entries_ref = make_ref()
    Process.put(entries_ref, entries)

    Heap.wrap(%{
      "__entries__" => {:obj, entries_ref},
      "get" => builtin("get", fn [name | _], this ->
        entries = load_entries(this)
        case Enum.find(entries, fn [k, _] -> k == to_string(name) end) do
          [_, v] -> v
          nil -> nil
        end
      end),
      "getAll" => builtin("getAll", fn [name | _], this ->
        entries = load_entries(this)
        entries
        |> Enum.filter(fn [k, _] -> k == to_string(name) end)
        |> Enum.map(fn [_, v] -> v end)
      end),
      "set" => builtin("set", fn [name, val | _], this ->
        n = to_string(name)
        v = to_string(val)
        entries = load_entries(this) |> Enum.reject(fn [k, _] -> k == n end)
        save_entries(this, entries ++ [[n, v]])
        :undefined
      end),
      "append" => builtin("append", fn [name, val | _], this ->
        n = to_string(name)
        v = to_string(val)
        entries = load_entries(this)
        save_entries(this, entries ++ [[n, v]])
        :undefined
      end),
      "delete" => builtin("delete", fn [name | _], this ->
        n = to_string(name)
        entries = load_entries(this) |> Enum.reject(fn [k, _] -> k == n end)
        save_entries(this, entries)
        :undefined
      end),
      "has" => builtin("has", fn [name | _], this ->
        n = to_string(name)
        entries = load_entries(this)
        Enum.any?(entries, fn [k, _] -> k == n end)
      end),
      "toString" => builtin("toString", fn _, this ->
        entries = load_entries(this)
        QuickBEAM.URL.compose_query([entries])
      end),
      "keys" => builtin("keys", fn _, this ->
        load_entries(this) |> Enum.map(fn [k, _] -> k end)
      end),
      "values" => builtin("values", fn _, this ->
        load_entries(this) |> Enum.map(fn [_, v] -> v end)
      end)
    })
  end

  defp load_entries(this) do
    case Get.get(this, "__entries__") do
      {:obj, ref} -> Process.get(ref, [])
      _ -> []
    end
  end

  defp save_entries(this, entries) do
    case Get.get(this, "__entries__") do
      {:obj, ref} -> Process.put(ref, entries)
      _ -> :ok
    end
  end

  # ── Headers ──

  defp headers_ctor do
    register("Headers", fn args, _this ->
      init = List.first(args, nil)

      initial_map = extract_headers_map(init)

      store_ref = make_ref()
      Heap.put_obj(store_ref, initial_map)

      Heap.wrap(%{
        "__store__" => {:obj, store_ref},
        "get" => builtin("get", fn [name | _], this ->
          store = load_store(this)
          Map.get(store, String.downcase(to_string(name)), nil)
        end),
        "set" => builtin("set", fn [name, val | _], this ->
          store = load_store(this)
          save_store(this, Map.put(store, String.downcase(to_string(name)), to_string(val)))
          :undefined
        end),
        "append" => builtin("append", fn [name, val | _], this ->
          k = String.downcase(to_string(name))
          store = load_store(this)
          existing = Map.get(store, k, nil)
          new_val = if existing, do: existing <> ", " <> to_string(val), else: to_string(val)
          save_store(this, Map.put(store, k, new_val))
          :undefined
        end),
        "delete" => builtin("delete", fn [name | _], this ->
          store = load_store(this)
          save_store(this, Map.delete(store, String.downcase(to_string(name))))
          :undefined
        end),
        "has" => builtin("has", fn [name | _], this ->
          store = load_store(this)
          Map.has_key?(store, String.downcase(to_string(name)))
        end)
      })
    end)
  end

  defp extract_headers_map(nil), do: %{}
  defp extract_headers_map(:undefined), do: %{}

  defp extract_headers_map({:obj, ref}) do
    case Heap.get_obj(ref, %{}) do
      map when is_map(map) ->
        map
        |> Enum.filter(fn {k, _} -> is_binary(k) and not String.starts_with?(k, "__") end)
        |> Enum.map(fn {k, v} -> {String.downcase(k), to_string(v)} end)
        |> Map.new()
      _ -> %{}
    end
  end

  defp extract_headers_map(_), do: %{}

  defp load_store(this) do
    case Get.get(this, "__store__") do
      {:obj, ref} ->
        case Heap.get_obj(ref, %{}) do
          m when is_map(m) -> m
          _ -> %{}
        end
      _ -> %{}
    end
  end

  defp save_store(this, store) do
    case Get.get(this, "__store__") do
      {:obj, ref} -> Heap.put_obj(ref, store)
      _ -> :ok
    end
  end

  # ── AbortController ──

  defp abort_controller_ctor do
    register("AbortController", fn _args, _this ->
      signal = Heap.wrap(%{"aborted" => false, "reason" => :undefined})

      Heap.wrap(%{
        "signal" => signal,
        "abort" => builtin("abort", fn args, this ->
          sig = Get.get(this, "signal")
          reason = List.first(args, :undefined)
          Put.put(sig, "aborted", true)
          Put.put(sig, "reason", reason)
          :undefined
        end)
      })
    end)
  end

  # ── performance ──

  defp performance_object do
    Heap.wrap(%{
      "now" => builtin("now", fn _, _ ->
        :erlang.monotonic_time(:microsecond) / 1000.0
      end),
      "timeOrigin" => :erlang.system_time(:millisecond) / 1.0
    })
  end

  # ── Blob ──

  defp blob_ctor do
    register("Blob", fn args, _this ->
      {parts_val, opts_val} = case args do
        [p, o | _] -> {p, o}
        [p | _] -> {p, nil}
        _ -> {nil, nil}
      end

      content = case parts_val do
        nil -> ""
        :undefined -> ""
        {:obj, _} = arr ->
          Heap.to_list(arr)
          |> Enum.map_join("", &to_binary_value/1)
        list when is_list(list) ->
          Enum.map_join(list, "", &to_binary_value/1)
        _ -> ""
      end

      mime_type = case opts_val do
        {:obj, _} = obj -> Get.get(obj, "type") |> to_string_or_empty()
        _ -> ""
      end

      Heap.wrap(%{
        "size" => byte_size(content),
        "type" => mime_type
      })
    end)
  end

  defp to_binary_value(v) when is_binary(v), do: v
  defp to_binary_value(v) when is_integer(v), do: Integer.to_string(v)
  defp to_binary_value(v) when is_float(v), do: Float.to_string(v)
  defp to_binary_value(:undefined), do: "undefined"
  defp to_binary_value(nil), do: "null"
  defp to_binary_value(v), do: to_string(v)

  defp to_string_or_empty(nil), do: ""
  defp to_string_or_empty(:undefined), do: ""
  defp to_string_or_empty(s) when is_binary(s), do: s
  defp to_string_or_empty(_), do: ""

  # ── crypto ──

  defp crypto_object do
    Heap.wrap(%{
      "getRandomValues" => builtin("getRandomValues", fn [arr | _], _ ->
        len = case Get.get(arr, "length") do
          n when is_integer(n) -> n
          n when is_float(n) -> trunc(n)
          _ -> 0
        end
        bytes = :crypto.strong_rand_bytes(len)
        for i <- 0..(len - 1) do
          Put.put_element(arr, i, :binary.at(bytes, i))
        end
        arr
      end),
      "randomUUID" => builtin("randomUUID", fn _, _ ->
        <<b0::32, b1::16, _::4, b2::12, _::2, b3::14, b4::48>> = :crypto.strong_rand_bytes(16)
        :io_lib.format(
          "~8.16.0b-~4.16.0b-4~3.16.0b-~4.16.0b-~12.16.0b",
          [b0, b1, b2, 0x8000 ||| b3, b4]
        )
        |> IO.iodata_to_binary()
      end),
      "subtle" => Heap.wrap(%{})
    })
  end

  # ── fetch/Request/Response ──

  defp request_ctor do
    register("Request", fn args, _this ->
      url_val = List.first(args, "")
      url_str = case url_val do
        s when is_binary(s) ->
          # Normalize: parse and recompose
          case QuickBEAM.URL.parse([s]) do
            %{"ok" => true, "components" => c} -> c["href"] || s
            _ -> s
          end
        {:obj, _} = obj -> Get.get(obj, "url") |> to_string()
        _ -> to_string(url_val)
      end

      opts = Enum.at(args, 1, nil)
      method = case opts do
        {:obj, _} = o -> Get.get(o, "method") |> to_string_or_get("GET")
        _ -> "GET"
      end

      Heap.wrap(%{
        "url" => url_str,
        "method" => method,
        "headers" => make_headers_obj(%{})
      })
    end)
  end

  defp to_string_or_get(:undefined, default), do: default
  defp to_string_or_get(nil, default), do: default
  defp to_string_or_get(s, _) when is_binary(s), do: s
  defp to_string_or_get(v, _), do: to_string(v)

  defp response_ctor do
    register("Response", fn args, _this ->
      body = List.first(args, "")
      opts = Enum.at(args, 1, nil)

      {status, status_text} = case opts do
        {:obj, _} = o ->
          s = case Get.get(o, "status") do
            n when is_integer(n) -> n
            n when is_float(n) -> trunc(n)
            _ -> 200
          end
          st = case Get.get(o, "statusText") do
            t when is_binary(t) -> t
            _ -> "OK"
          end
          {s, st}
        _ -> {200, "OK"}
      end

      Heap.wrap(%{
        "status" => status,
        "statusText" => status_text,
        "ok" => status >= 200 and status < 300,
        "body" => body,
        "headers" => make_headers_obj(%{})
      })
    end)
  end

  defp make_headers_obj(initial_map) do
    store_ref = make_ref()
    Heap.put_obj(store_ref, initial_map)

    Heap.wrap(%{
      "__store__" => {:obj, store_ref},
      "get" => builtin("get", fn [name | _], this ->
        store = load_store(this)
        Map.get(store, String.downcase(to_string(name)), nil)
      end),
      "set" => builtin("set", fn [name, val | _], this ->
        store = load_store(this)
        save_store(this, Map.put(store, String.downcase(to_string(name)), to_string(val)))
        :undefined
      end),
      "has" => builtin("has", fn [name | _], this ->
        store = load_store(this)
        Map.has_key?(store, String.downcase(to_string(name)))
      end),
      "append" => builtin("append", fn [name, val | _], this ->
        k = String.downcase(to_string(name))
        store = load_store(this)
        existing = Map.get(store, k, nil)
        new_val = if existing, do: existing <> ", " <> to_string(val), else: to_string(val)
        save_store(this, Map.put(store, k, new_val))
        :undefined
      end)
    })
  end

  # ── Uint8Array construction helper ──

  defp make_uint8array(bytes) when is_list(bytes) do
    case Runtime.global_bindings()["Uint8Array"] do
      {:builtin, _, cb} = ctor when is_function(cb, 2) ->
        result = cb.([ bytes ], nil)
        case result do
          {:obj, ref} ->
            class_proto = Heap.get_class_proto(ctor)
            if class_proto do
              map = Heap.get_obj(ref, %{})
              if is_map(map) and not Map.has_key?(map, proto()) do
                Heap.put_obj(ref, Map.put(map, proto(), class_proto))
              end
            end
            result
          _ -> result
        end
      _ ->
        Heap.wrap(bytes)
    end
  end

  defp typed_array_to_list({:obj, ref}) do
    case Heap.get_obj(ref, %{}) do
      map when is_map(map) and :erlang.is_map_key("__typed_array__", map) ->
        len = Map.get(map, "length", 0)
        buf = Map.get(map, "__buffer__", <<>>)
        for i <- 0..(len - 1), do: :binary.at(buf, min(i, byte_size(buf) - 1))
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp typed_array_to_list(list) when is_list(list), do: list
  defp typed_array_to_list(_), do: []

  # ── Helpers ──

  defp builtin(name, fun), do: {:builtin, name, fun}

  defp register(name, constructor) do
    ctor = {:builtin, name, constructor}

    proto = Heap.wrap(%{"constructor" => ctor})
    Heap.put_class_proto(ctor, proto)
    Heap.put_ctor_static(ctor, "prototype", proto)

    ctor
  end
end
