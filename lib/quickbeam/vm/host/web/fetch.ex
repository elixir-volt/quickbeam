defmodule QuickBEAM.VM.Host.Web.Fetch do
  @moduledoc "fetch, Request, and Response builtins for BEAM mode."

  @behaviour QuickBEAM.VM.Runtime.BindingProvider

  import QuickBEAM.VM.Builtin,
    only: [arg: 3, argv: 2, constructor: 3, object: 1, object: 2]

  alias QuickBEAM.VM.{Heap, Promise, Runtime}
  alias QuickBEAM.VM.ObjectModel.{Get, InternalMethods, PropertyDescriptor}
  alias QuickBEAM.VM.Host.Web.Body
  alias QuickBEAM.VM.Host.Web.Fetch.JSON
  alias QuickBEAM.VM.Host.Web.Headers
  alias QuickBEAM.VM.Host.WebAPIs

  @doc "Returns the JavaScript global bindings provided by this module."
  def bindings do
    request_ctor = WebAPIs.register("Request", &build_request/2)
    response_ctor = build_response_ctor()

    fetch_fn =
      {:builtin, "fetch",
       fn args, _ ->
         [url_or_req, opts_val] = argv(args, [nil, nil])

         {url, method, headers_map, body_val, signal} =
           extract_fetch_args(url_or_req, opts_val)

         if signal_aborted?(signal) do
           reason = Get.get(signal, "reason")
           Promise.rejected(reason)
         else
           fetch_id = System.unique_integer([:positive])
           result_ref = make_ref()

           parent = self()

           {actual_body, actual_headers} = prepare_body(body_val, headers_map)

           task_pid =
             spawn(fn ->
               try do
                 result =
                   QuickBEAM.Fetch.fetch([
                     %{
                       "fetchId" => fetch_id,
                       "url" => url,
                       "method" => method,
                       "headers" => Enum.map(actual_headers, fn {k, v} -> [k, v] end),
                       "body" => actual_body
                     }
                   ])

                 send(parent, {result_ref, {:ok, result}})
               rescue
                 e -> send(parent, {result_ref, {:error, e}})
               catch
                 :exit, reason -> send(parent, {result_ref, {:error, reason}})
               end
             end)

           if signal != nil do
             alias QuickBEAM.VM.Host.Web.Abort, as: AbortMod
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
         data = arg(args, 0, :undefined)
         json_str = JSON.encode(data)
         headers = Headers.build_from_map(%{"content-type" => "application/json"})
         build_response_obj(json_str, 200, "OK", headers, response_ctor)
       end}
    )

    Heap.put_ctor_static(
      response_ctor,
      "redirect",
      {:builtin, "redirect",
       fn args, _ ->
         url = args |> arg(0, "") |> to_string()
         status = args |> arg(1, 302) |> coerce_int(302)
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
    constructor "Response", &build_response/2 do
      proto do
      end
    end
  end

  @doc "Builds a Request object backed by VM heap state."
  def build_request(args, _this) do
    url_val = arg(args, 0, "")

    {url_str, method, headers_val, body_val} =
      case url_val do
        {:obj, _} = req_obj ->
          u = req_obj |> Get.get("url") |> to_string()
          m = req_obj |> Get.get("method") |> coerce_string("GET")
          h = Get.get(req_obj, "headers")
          b = clone_request_body(req_obj)
          {u, m, h, b}

        _ ->
          u = to_string(url_val)

          opts = arg(args, 1, nil)

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
        {:obj, _} = h -> Headers.build_from_map(Headers.to_map(h, skip_internal_values: true))
        _ -> Headers.build_from_map(%{})
      end

    body_ref = if is_reference(body_val), do: body_val, else: Body.new(body_val)

    request_ctor = get_request_ctor()

    request =
      object do
        prop("url", url_str)
        prop("method", method)
        prop("headers", headers)
        prop("body", Body.data(body_ref))
        prop("__body_ref__", body_ref)
        prop("bodyUsed", false)

        method "text" do
          Body.consume(body_ref, this, &Body.text_response/1)
        end

        method "json" do
          Body.consume(body_ref, this, fn data ->
            data
            |> Body.text()
            |> JSON.parse()
            |> Promise.resolved()
          end)
        end

        method "arrayBuffer" do
          Body.consume(body_ref, this, &Body.array_buffer_response/1)
        end

        method "clone" do
          clone_request(url_str, method, headers, body_ref, request_ctor)
        end
      end

    protect_body_ref(request)
    request
  end

  defp clone_request(url, method, headers, body_ref, request_ctor) do
    request =
      Heap.wrap(
        build_request_map(url, method, clone_headers(headers), Body.clone(body_ref), request_ctor)
      )

    protect_body_ref(request)
    request
  end

  defp build_request_map(url, method, headers, body_ref, request_ctor) do
    object heap: false do
      prop("url", url)
      prop("method", method)
      prop("headers", headers)
      prop("body", Body.data(body_ref))
      prop("__body_ref__", body_ref)
      prop("bodyUsed", false)
      prop("constructor", request_ctor)

      method "text" do
        Body.consume(body_ref, this, &Body.text_response/1)
      end

      method "json" do
        Body.consume(body_ref, this, fn data ->
          Promise.resolved(JSON.parse(Body.text(data)))
        end)
      end

      method "arrayBuffer" do
        Body.consume(body_ref, this, &Body.array_buffer_response/1)
      end

      method "clone" do
        clone_request(url, method, headers, body_ref, request_ctor)
      end
    end
  end

  @doc "Builds a Response object backed by VM heap state."
  def build_response(args, _this) do
    body = arg(args, 0, "")

    {status, status_text, headers_init} =
      case arg(args, 1, nil) do
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
        {:obj, _} = h -> Headers.build_from_map(Headers.to_map(h, skip_internal_values: true))
        _ -> Headers.build_from_map(%{})
      end

    response_ctor = get_response_ctor()
    build_response_obj(body, status, status_text, headers, response_ctor)
  end

  defp build_response_obj(body, status, status_text, headers, response_ctor) do
    body_ref = Body.new(body)

    object do
      prop("status", status)
      prop("statusText", status_text)
      prop("ok", status >= 200 and status < 300)
      prop("headers", headers)
      prop("bodyUsed", false)
      prop("redirected", false)
      prop("url", "")
      prop("constructor", response_ctor)

      method "text" do
        Body.consume(body_ref, this, &Body.text_response/1)
      end

      method "json" do
        Body.consume(body_ref, this, fn data ->
          Promise.resolved(JSON.parse(Body.text(data)))
        end)
      end

      method "arrayBuffer" do
        Body.consume(body_ref, this, &Body.array_buffer_response/1)
      end

      method "bytes" do
        Body.consume(body_ref, this, &Body.bytes_response/1)
      end

      method "clone" do
        build_response_obj(
          Body.data(Body.clone(body_ref)),
          status,
          status_text,
          clone_headers(headers),
          response_ctor
        )
      end
    end
  end

  defp get_request_ctor, do: Runtime.global_constructor("Request")
  defp get_response_ctor, do: Runtime.global_constructor("Response")

  defp clone_headers(headers) do
    headers
    |> Headers.to_map(skip_internal_values: true)
    |> Headers.build_from_map()
  end

  defp clone_request_body(req_obj) do
    case Get.get(req_obj, "__body_ref__") do
      ref when is_reference(ref) -> Body.clone(ref)
      _ -> Get.get(req_obj, "body")
    end
  end

  defp consume_request_body(req_obj) do
    case Get.get(req_obj, "__body_ref__") do
      ref when is_reference(ref) -> consume_request_body_ref(req_obj, ref)
      _ -> Get.get(req_obj, "body")
    end
  end

  defp consume_request_body_ref(req_obj, ref) do
    if Body.has_body?(ref) do
      data = Body.consume_payload!(ref)
      InternalMethods.set(req_obj, "bodyUsed", true)
      data
    else
      Body.data(ref)
    end
  end

  defp protect_body_ref({:obj, ref} = request) do
    Heap.put_prop_desc(ref, "__body_ref__", %{
      PropertyDescriptor.hidden_readonly()
      | configurable: false
    })

    request
  end

  defp protect_body_ref(request), do: request

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
        b = consume_request_body(req_obj)
        sig = get_signal_from_opts(opts_val)
        {u, m, Headers.to_map(h_obj, skip_internal_values: true), coerce_body(b), sig}

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

        h_map = if h_obj, do: Headers.to_map(h_obj, skip_internal_values: true), else: %{}
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
                  %{"__promise_state__" => :resolved, "__promise_value__" => v}
                  when is_binary(v) ->
                    v

                  _ ->
                    ""
                end

              v when is_binary(v) ->
                v

              _ ->
                ""
            end

          _ ->
            ""
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
        |> Promise.resolved()

      {^result_ref, {:error, error}} ->
        err = Heap.make_error("fetch failed: #{inspect(error)}", "TypeError")
        Promise.rejected(err)

      {^result_ref, {:aborted, reason}} ->
        Promise.rejected(reason)
    after
      poll_interval ->
        QuickBEAM.VM.Host.Web.Timers.drain_timers()

        if signal != nil and signal_aborted?(signal) do
          Process.exit(task_pid, :kill)
          reason = Get.get(signal, "reason")
          Promise.rejected(reason)
        else
          remaining = timeout_ms - poll_interval

          if remaining <= 0 do
            Process.exit(task_pid, :kill)
            err = Heap.make_error("fetch timed out", "TypeError")
            Promise.rejected(err)
          else
            wait_for_fetch(result_ref, task_pid, signal, response_ctor, remaining)
          end
        end
    end
  end

  defp prepare_body({:form_data, entries_ref}, headers_map) when is_reference(entries_ref) do
    alias QuickBEAM.VM.Host.Web.FormData, as: FD
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

  defp build_response_from_fetch(
         %{
           "status" => status,
           "statusText" => st,
           "headers" => resp_headers,
           "body" => body,
           "url" => url
         },
         response_ctor
       ) do
    headers_map =
      resp_headers
      |> Enum.reduce(%{}, fn [k, v], acc -> Headers.append_to_map(acc, k, v) end)

    headers = Headers.build_from_map(headers_map)
    status = if is_integer(status), do: status, else: 200
    status_text = to_string(st)

    body_data =
      case body do
        {:bytes, b} -> b
        b when is_binary(b) -> b
        _ -> ""
      end

    resp = build_response_obj(body_data, status, status_text, headers, response_ctor)

    {:obj, ref} = resp
    Heap.update_obj(ref, %{}, fn m -> Map.put(m, "url", url) end)
    resp
  end
end
