defmodule QuickBEAM.VM.Runtime.Web.Fetch do
  @moduledoc "fetch, Request, and Response builtins for BEAM mode."

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.ObjectModel.Get
  alias QuickBEAM.VM.Runtime.Web.Headers

  def bindings do
    %{
      "fetch" => {:builtin, "fetch", fn _args, _ -> :undefined end},
      "Request" => register("Request", &build_request/2),
      "Response" => register("Response", &build_response/2)
    }
  end

  defp build_request(args, _this) do
    url_val = List.first(args, "")

    url_str =
      case url_val do
        s when is_binary(s) ->
          case QuickBEAM.URL.parse([s]) do
            %{"ok" => true, "components" => c} -> c["href"] || s
            _ -> s
          end

        {:obj, _} = obj ->
          obj |> Get.get("url") |> to_string()

        _ ->
          to_string(url_val)
      end

    method =
      case Enum.at(args, 1) do
        {:obj, _} = o -> o |> Get.get("method") |> coerce_string("GET")
        _ -> "GET"
      end

    Heap.wrap(%{
      "url" => url_str,
      "method" => method,
      "headers" => Headers.build_from_map(%{})
    })
  end

  defp build_response(args, _this) do
    body = List.first(args, "")

    {status, status_text} =
      case Enum.at(args, 1) do
        {:obj, _} = o ->
          s =
            case Get.get(o, "status") do
              n when is_integer(n) -> n
              n when is_float(n) -> trunc(n)
              _ -> 200
            end

          st =
            case Get.get(o, "statusText") do
              t when is_binary(t) -> t
              _ -> "OK"
            end

          {s, st}

        _ ->
          {200, "OK"}
      end

    Heap.wrap(%{
      "status" => status,
      "statusText" => status_text,
      "ok" => status >= 200 and status < 300,
      "body" => body,
      "headers" => Headers.build_from_map(%{})
    })
  end

  defp coerce_string(:undefined, default), do: default
  defp coerce_string(nil, default), do: default
  defp coerce_string(s, _) when is_binary(s), do: s
  defp coerce_string(v, _), do: to_string(v)

  defp register(name, constructor) do
    ctor = {:builtin, name, constructor}
    proto = Heap.wrap(%{"constructor" => ctor})
    Heap.put_class_proto(ctor, proto)
    Heap.put_ctor_static(ctor, "prototype", proto)
    ctor
  end
end
