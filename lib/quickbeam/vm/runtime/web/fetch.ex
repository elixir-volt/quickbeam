defmodule QuickBEAM.VM.Runtime.Web.Fetch do
  @moduledoc "fetch, Request, and Response builtins for BEAM mode."

  import QuickBEAM.VM.Builtin, only: [build_methods: 1]

  alias QuickBEAM.VM.{Heap, JSThrow, PromiseState}
  alias QuickBEAM.VM.ObjectModel.{Get, Put}
  alias QuickBEAM.VM.Runtime.Web.Headers
  alias QuickBEAM.VM.Runtime.WebAPIs

  def bindings do
    request_ctor = WebAPIs.register("Request", &build_request/2)
    response_ctor = build_response_ctor()

    fetch_fn =
      {:builtin, "fetch",
       fn args, _ ->
         [url_or_req | rest] = args ++ [nil]
         opts_val = List.first(rest)

         {url, method, headers_map, body_val, signal} =
           extract_fetch_args(url_or_req, opts_val)

         if signal_aborted?(signal) do
           reason = Get.get(signal, "reason")
           PromiseState.rejected(reason)
         else
           fetch_id = System.unique_integer([:positive])
           result_ref = make_ref()
           Process.put(result_ref, :pending)

           parent = self()

           {actual_body, actual_headers} = prepare_body(body_val, headers_map)

           task_pid =
             spawn(fn ->
               try do
                 result = QuickBEAM.Fetch.fetch([%{
                   "fetchId" => fetch_id,
                   "url" => url,
                   "method" => method,
                   "headers" => Enum.map(actual_headers, fn {k, v} -> [k, v] end),
                   "body" => actual_body
                 }])

                 send(parent, {result_ref, {:ok, result}})
               rescue
                 e -> send(parent, {result_ref, {:error, e}})
               catch
                 :exit, reason -> send(parent, {result_ref, {:error, reason}})
               end
             end)

           if signal != nil do
             alias QuickBEAM.VM.Runtime.Web.Abort, as: AbortMod
             parent = self()
             AbortMod.add_abort_listener(signal, fn _reason ->
               Process.exit(task_pid, :kill)
               send(parent, {result_ref, {:aborted, Get.get(signal, "reason")}})
             end)
           end

           wait_for_fetch(result_ref, task_pid, signal, response_ctor, 60_000)
         end
       end}

    Heap.put_ctor_static(
      response_ctor,
      "json",
      {:builtin, "json",
       fn args, _ ->
         data = List.first(args, :undefined)
         json_str = json_encode(data)
         headers = Headers.build_from_map(%{"content-type" => "application/json"})
         build_response_obj(json_str, 200, "OK", headers, response_ctor)
       end}
    )

    Heap.put_ctor_static(
      response_ctor,
      "redirect",
      {:builtin, "redirect",
       fn args, _ ->
         url = args |> List.first("") |> to_string()
         status = args |> Enum.at(1, 302) |> coerce_int(302)
         headers = Headers.build_from_map(%{"location" => url})
         build_response_obj("", status, "", headers, response_ctor)
       end}
    )

    Heap.put_ctor_static(
      response_ctor,
      "error",
      {:builtin, "error",
       fn _args, _ ->
         headers = Headers.build_from_map(%{})
         build_response_obj("", 0, "", headers, response_ctor)
       end}
    )

    %{
      "fetch" => fetch_fn,
      "Request" => request_ctor,
      "Response" => response_ctor
    }
  end

  defp build_response_ctor do
    ctor = {:builtin, "Response", &build_response/2}
    proto = Heap.wrap(%{"constructor" => ctor})
    Heap.put_class_proto(ctor, proto)
    Heap.put_ctor_static(ctor, "prototype", proto)
    ctor
  end

  def build_request(args, _this) do
    url_val = List.first(args, "")

    {url_str, method, headers_val, body_val} =
      case url_val do
        {:obj, _} = req_obj ->
          u = req_obj |> Get.get("url") |> to_string()
          m = req_obj |> Get.get("method") |> coerce_string("GET")
          h = Get.get(req_obj, "headers")
          b = Get.get(req_obj, "body")
          {u, m, h, b}

        _ ->
          u = to_string(url_val)

          opts = Enum.at(args, 1)

          {m, h, b} =
            case opts do
              {:obj, _} ->
                method = opts |> Get.get("method") |> coerce_string("GET")
                headers = Get.get(opts, "headers")
                body = Get.get(opts, "body")
                {method, headers, body}

              _ ->
                {"GET", nil, nil}
            end

          {u, m, h, b}
      end

    headers =
      case headers_val do
        {:obj, _} = h -> Headers.build_from_map(extract_headers_map(h))
        _ -> Headers.build_from_map(%{})
      end

    body_ref = make_ref()
    Heap.put_obj(body_ref, %{consumed: false, data: body_val})

    request_ctor = get_request_ctor()

    Heap.wrap(
      build_methods do
        val("url", url_str)
        val("method", method)
        val("headers", headers)
        val("bodyUsed", false)

        method "text" do
          consume_body(body_ref, this, fn data ->
            case data do
              nil -> PromiseState.resolved("")
              :undefined -> PromiseState.resolved("")
              s when is_binary(s) -> PromiseState.resolved(s)
              _ -> PromiseState.resolved(to_string(data))
            end
          end)
        end

        method "json" do
          consume_body(body_ref, this, fn data ->
            str =
              case data do
                nil -> ""
                :undefined -> ""
                s when is_binary(s) -> s
                _ -> to_string(data)
              end

            parsed = json_parse(str)
            PromiseState.resolved(parsed)
          end)
        end

        method "arrayBuffer" do
          consume_body(body_ref, this, fn data ->
            bin =
              case data do
                nil -> ""
                :undefined -> ""
                s when is_binary(s) -> s
                _ -> to_string(data)
              end

            buf = make_array_buffer(bin)
            PromiseState.resolved(buf)
          end)
        end

        method "clone" do
          body_data = (Heap.get_obj(body_ref, %{}) || %{}) |> Map.get(:data)
          new_body_ref = make_ref()
          Heap.put_obj(new_body_ref, %{consumed: false, data: body_data})

          Heap.wrap(
            build_request_map(url_str, method, headers, new_body_ref, request_ctor)
          )
        end
      end
    )
  end

  defp build_request_map(url, method, headers, body_ref, request_ctor) do
    build_methods do
      val("url", url)
      val("method", method)
      val("headers", headers)
      val("bodyUsed", false)
      val("constructor", request_ctor)

      method "text" do
        consume_body(body_ref, this, fn data ->
          case data do
            nil -> PromiseState.resolved("")
            :undefined -> PromiseState.resolved("")
            s when is_binary(s) -> PromiseState.resolved(s)
            _ -> PromiseState.resolved(to_string(data))
          end
        end)
      end

      method "json" do
        consume_body(body_ref, this, fn data ->
          str = case data do
            nil -> ""
            :undefined -> ""
            s when is_binary(s) -> s
            _ -> to_string(data)
          end
          PromiseState.resolved(json_parse(str))
        end)
      end

      method "arrayBuffer" do
        consume_body(body_ref, this, fn data ->
          bin = case data do
            nil -> ""
            :undefined -> ""
            s when is_binary(s) -> s
            _ -> to_string(data)
          end
          PromiseState.resolved(make_array_buffer(bin))
        end)
      end

      method "clone" do
        body_data = (Heap.get_obj(body_ref, %{}) || %{}) |> Map.get(:data)
        new_body_ref = make_ref()
        Heap.put_obj(new_body_ref, %{consumed: false, data: body_data})
        Heap.wrap(build_request_map(url, method, headers, new_body_ref, request_ctor))
      end
    end
  end

  def build_response(args, _this) do
    body = List.first(args, "")

    {status, status_text, headers_init} =
      case Enum.at(args, 1) do
        {:obj, _} = o ->
          s = o |> Get.get("status") |> coerce_int(200)
          st = o |> Get.get("statusText") |> coerce_string("OK")
          h = Get.get(o, "headers")
          {s, st, h}

        _ ->
          {200, "OK", nil}
      end

    headers =
      case headers_init do
        {:obj, _} = h -> Headers.build_from_map(extract_headers_map(h))
        _ -> Headers.build_from_map(%{})
      end

    response_ctor = get_response_ctor()
    build_response_obj(body, status, status_text, headers, response_ctor)
  end

  defp build_response_obj(body, status, status_text, headers, response_ctor) do
    body_ref = make_ref()
    Heap.put_obj(body_ref, %{consumed: false, data: body})

    Heap.wrap(
      build_methods do
        val("status", status)
        val("statusText", status_text)
        val("ok", status >= 200 and status < 300)
        val("headers", headers)
        val("bodyUsed", false)
        val("redirected", false)
        val("url", "")
        val("constructor", response_ctor)

        method "text" do
          consume_body(body_ref, this, fn data ->
            case data do
              nil -> PromiseState.resolved("")
              :undefined -> PromiseState.resolved("")
              {:bytes, b} when is_binary(b) -> PromiseState.resolved(b)
              s when is_binary(s) -> PromiseState.resolved(s)
              _ -> PromiseState.resolved(to_string(data))
            end
          end)
        end

        method "json" do
          consume_body(body_ref, this, fn data ->
            str =
              case data do
                nil -> ""
                :undefined -> ""
                {:bytes, b} when is_binary(b) -> b
                s when is_binary(s) -> s
                _ -> to_string(data)
              end

            parsed = json_parse(str)
            PromiseState.resolved(parsed)
          end)
        end

        method "arrayBuffer" do
          consume_body(body_ref, this, fn data ->
            bin =
              case data do
                nil -> ""
                :undefined -> ""
                {:bytes, b} when is_binary(b) -> b
                s when is_binary(s) -> s
                _ -> to_string(data)
              end

            PromiseState.resolved(make_array_buffer(bin))
          end)
        end

        method "bytes" do
          consume_body(body_ref, this, fn data ->
            bin =
              case data do
                nil -> ""
                :undefined -> ""
                {:bytes, b} when is_binary(b) -> b
                s when is_binary(s) -> s
                _ -> to_string(data)
              end

            bytes = :binary.bin_to_list(bin)
            PromiseState.resolved(Heap.wrap(bytes))
          end)
        end

        method "clone" do
          body_data = (Heap.get_obj(body_ref, %{}) || %{}) |> Map.get(:data)
          new_body_ref = make_ref()
          Heap.put_obj(new_body_ref, %{consumed: false, data: body_data})
          build_response_obj(body_data, status, status_text, headers, response_ctor)
        end
      end
    )
  end

  defp consume_body(body_ref, this, fun) do
    case Heap.get_obj(body_ref, %{}) do
      %{consumed: true} ->
        JSThrow.type_error!("Body has already been consumed")

      %{consumed: false, data: data} ->
        Heap.put_obj(body_ref, %{consumed: true, data: data})
        Put.put(this, "bodyUsed", true)
        fun.(data)

      _ ->
        fun.(nil)
    end
  end

  defp extract_headers_map({:obj, ref}) do
    raw = Heap.get_obj(ref, %{})

    cond do
      is_list(raw) ->
        raw
        |> Enum.flat_map(fn item ->
          case item do
            {:obj, iref} ->
              case Heap.get_obj(iref, []) do
                [k, v | _] -> [{String.downcase(to_string(k)), to_string(v)}]
                _ -> []
              end

            [k, v | _] ->
              [{String.downcase(to_string(k)), to_string(v)}]

            _ ->
              []
          end
        end)
        |> Map.new()

      match?({:qb_arr, _}, raw) ->
        Heap.obj_to_list(ref)
        |> Enum.flat_map(fn item ->
          case item do
            {:obj, iref} ->
              case Heap.get_obj(iref, []) do
                [k, v | _] -> [{String.downcase(to_string(k)), to_string(v)}]
                _ -> []
              end

            _ ->
              []
          end
        end)
        |> Map.new()

      is_map(raw) ->
        case Map.get(raw, "__store__") do
          {:obj, store_ref} ->
            case Heap.get_obj(store_ref, %{}) do
              m when is_map(m) -> m
              _ -> %{}
            end

          _ ->
            raw
            |> Enum.reject(fn {k, _} -> not is_binary(k) or String.starts_with?(k, "__") end)
            |> Enum.map(fn {k, v} ->
              cond do
                is_binary(v) -> {String.downcase(k), v}
                is_atom(v) -> nil
                is_tuple(v) -> nil
                true -> {String.downcase(k), to_string(v)}
              end
            end)
            |> Enum.reject(&is_nil/1)
            |> Map.new()
        end

      true ->
        %{}
    end
  end

  defp extract_headers_map(_), do: %{}

  defp get_request_ctor do
    case Heap.get_global_cache() do
      nil -> nil
      globals -> Map.get(globals, "Request")
    end
  end

  defp get_response_ctor do
    case Heap.get_global_cache() do
      nil -> nil
      globals -> Map.get(globals, "Response")
    end
  end

  defp make_array_buffer(data) when is_binary(data) do
    byte_len = byte_size(data)

    case Heap.get_global_cache() do
      nil ->
        Heap.wrap(%{"__buffer__" => data, "byteLength" => byte_len})

      globals ->
        case Map.get(globals, "ArrayBuffer") do
          {:builtin, _, cb} = ctor ->
            result = cb.([byte_len], nil)
            proto = Heap.get_class_proto(ctor)

            case result do
              {:obj, ref} ->
                Heap.update_obj(ref, %{}, fn m ->
                  base = Map.put(m, "__buffer__", data)
                  if proto != nil and not Map.has_key?(base, "__proto__"),
                    do: Map.put(base, "__proto__", proto),
                    else: base
                end)

                result

              _ ->
                result
            end

          _ ->
            Heap.wrap(%{"__buffer__" => data, "byteLength" => byte_len})
        end
    end
  end

  defp coerce_string(:undefined, default), do: default
  defp coerce_string(nil, default), do: default
  defp coerce_string(s, _) when is_binary(s), do: s
  defp coerce_string(v, _), do: to_string(v)

  defp coerce_int(:undefined, default), do: default
  defp coerce_int(nil, default), do: default
  defp coerce_int(n, _) when is_integer(n), do: n
  defp coerce_int(n, _) when is_float(n), do: trunc(n)
  defp coerce_int(_, default), do: default

  defp extract_fetch_args(url_or_req, opts_val) do
    case url_or_req do
      {:obj, _} = req_obj ->
        u = req_obj |> Get.get("url") |> to_string()
        m = req_obj |> Get.get("method") |> coerce_string("GET")
        h_obj = Get.get(req_obj, "headers")
        b = Get.get(req_obj, "body")
        sig = get_signal_from_opts(opts_val)
        {u, m, extract_headers_map(h_obj), coerce_body(b), sig}

      url_val ->
        u = to_string(url_val)
        {m, h_obj, b, sig} =
          case opts_val do
            {:obj, _} ->
              method = opts_val |> Get.get("method") |> coerce_string("GET")
              headers = Get.get(opts_val, "headers")
              body = Get.get(opts_val, "body")
              signal = get_signal_from_opts(opts_val)
              {method, headers, body, signal}

            _ ->
              {"GET", nil, nil, nil}
          end

        h_map = if h_obj, do: extract_headers_map(h_obj), else: %{}
        {u, m, h_map, coerce_body(b), sig}
    end
  end

  defp get_signal_from_opts({:obj, _} = opts) do
    case Get.get(opts, "signal") do
      {:obj, _} = sig -> sig
      _ -> nil
    end
  end

  defp get_signal_from_opts(_), do: nil

  defp signal_aborted?(nil), do: false
  defp signal_aborted?(signal), do: signal != nil and Get.get(signal, "aborted") == true

  defp coerce_body(nil), do: nil
  defp coerce_body(:undefined), do: nil
  defp coerce_body(b) when is_binary(b), do: b

  defp coerce_body({:obj, _} = obj) do
    case Heap.get_obj(elem(obj, 1), %{}) do
      m when is_map(m) and is_map_key(m, "__fd_ref__") ->
        {:form_data, m["__fd_ref__"]}

      m when is_map(m) and is_map_key(m, "size") ->
        case Get.get(obj, "text") do
          {:builtin, "text", cb} ->
            promise = cb.([], obj)
            case promise do
              {:obj, pref} ->
                case Heap.get_obj(pref, %{}) do
                  %{"__promise_state__" => :resolved, "__promise_value__" => v} when is_binary(v) -> v
                  _ -> ""
                end
              v when is_binary(v) -> v
              _ -> ""
            end
          _ -> ""
        end

      _ ->
        inspect(obj)
    end
  end

  defp coerce_body(_), do: nil

  defp wait_for_fetch(result_ref, task_pid, signal, response_ctor, timeout_ms) do
    poll_interval = min(timeout_ms, 10)

    receive do
      {^result_ref, {:ok, resp}} ->
        build_response_from_fetch(resp, response_ctor)
        |> PromiseState.resolved()

      {^result_ref, {:error, error}} ->
        err = Heap.make_error("fetch failed: #{inspect(error)}", "TypeError")
        PromiseState.rejected(err)

      {^result_ref, {:aborted, reason}} ->
        PromiseState.rejected(reason)
    after
      poll_interval ->
        QuickBEAM.VM.Runtime.Web.Timers.drain_timers()

        if signal != nil and signal_aborted?(signal) do
          Process.exit(task_pid, :kill)
          reason = Get.get(signal, "reason")
          PromiseState.rejected(reason)
        else
          remaining = timeout_ms - poll_interval

          if remaining <= 0 do
            Process.exit(task_pid, :kill)
            err = Heap.make_error("fetch timed out", "TypeError")
            PromiseState.rejected(err)
          else
            wait_for_fetch(result_ref, task_pid, signal, response_ctor, remaining)
          end
        end
    end
  end

  defp prepare_body({:form_data, entries_ref}, headers_map) when is_reference(entries_ref) do
    alias QuickBEAM.VM.Runtime.Web.FormData, as: FD
    {body, content_type} = FD.encode_multipart(entries_ref)
    updated_headers = Map.put(headers_map, "content-type", content_type)
    {body, updated_headers}
  end

  defp prepare_body(nil, headers_map), do: {nil, headers_map}

  defp prepare_body(body, headers_map) when is_binary(body) do
    updated_headers =
      if Map.has_key?(headers_map, "content-type") do
        headers_map
      else
        Map.put(headers_map, "content-type", "text/plain;charset=UTF-8")
      end

    {body, updated_headers}
  end

  defp prepare_body(body, headers_map), do: {to_string(body), headers_map}

  defp build_response_from_fetch(%{"status" => status, "statusText" => st, "headers" => resp_headers, "body" => body, "url" => url}, response_ctor) do
    headers_map =
      resp_headers
      |> Enum.map(fn [k, v] -> {String.downcase(to_string(k)), to_string(v)} end)
      |> Map.new()

    headers = Headers.build_from_map(headers_map)
    status = if is_integer(status), do: status, else: 200
    status_text = to_string(st)

    body_data = case body do
      {:bytes, b} -> b
      b when is_binary(b) -> b
      _ -> ""
    end

    resp = build_response_obj(body_data, status, status_text, headers, response_ctor)

    {:obj, ref} = resp
    Heap.update_obj(ref, %{}, fn m -> Map.put(m, "url", url) end)
    resp
  end

  defp json_parse(str) when is_binary(str) do
    case Jason.decode(str) do
      {:ok, val} -> from_elixir(val)
      _ -> JSThrow.syntax_error!("Unexpected token in JSON")
    end
  end

  defp json_encode(val) do
    Jason.encode!(to_json_elixir(val))
  end

  defp from_elixir(val) when is_map(val) do
    Heap.wrap(Map.new(val, fn {k, v} -> {k, from_elixir(v)} end))
  end

  defp from_elixir(val) when is_list(val) do
    Heap.wrap(Enum.map(val, &from_elixir/1))
  end

  defp from_elixir(val), do: val

  defp to_json_elixir({:obj, ref}) do
    case Heap.get_obj(ref, %{}) do
      map when is_map(map) ->
        Map.new(
          Enum.reject(map, fn {k, _} -> not is_binary(k) or String.starts_with?(k, "__") end),
          fn {k, v} -> {k, to_json_elixir(v)} end
        )

      list when is_list(list) ->
        Enum.map(list, &to_json_elixir/1)

      _ ->
        nil
    end
  end

  defp to_json_elixir(v) when is_binary(v), do: v
  defp to_json_elixir(v) when is_number(v), do: v
  defp to_json_elixir(true), do: true
  defp to_json_elixir(false), do: false
  defp to_json_elixir(nil), do: nil
  defp to_json_elixir(:undefined), do: nil
  defp to_json_elixir(:nan), do: nil
  defp to_json_elixir(:infinity), do: nil
  defp to_json_elixir({:bigint, n}), do: n
  defp to_json_elixir(_), do: nil
end
