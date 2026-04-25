defmodule QuickBEAM.VM.Runtime.Web.Blob do
  @moduledoc "Blob constructor builtin for BEAM mode."

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.ObjectModel.Get

  def bindings do
    %{"Blob" => register("Blob", &build_blob/2)}
  end

  defp build_blob(args, _this) do
    {parts_val, opts_val} =
      case args do
        [p, o | _] -> {p, o}
        [p | _] -> {p, nil}
        _ -> {nil, nil}
      end

    content =
      case parts_val do
        nil ->
          ""

        :undefined ->
          ""

        {:obj, _} = arr ->
          arr |> Heap.to_list() |> Enum.map_join("", &to_binary_value/1)

        list when is_list(list) ->
          Enum.map_join(list, "", &to_binary_value/1)

        _ ->
          ""
      end

    mime_type =
      case opts_val do
        {:obj, _} = obj -> obj |> Get.get("type") |> to_string_or_empty()
        _ -> ""
      end

    Heap.wrap(%{"size" => byte_size(content), "type" => mime_type})
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

  defp register(name, constructor) do
    ctor = {:builtin, name, constructor}
    proto = Heap.wrap(%{"constructor" => ctor})
    Heap.put_class_proto(ctor, proto)
    Heap.put_ctor_static(ctor, "prototype", proto)
    ctor
  end
end
