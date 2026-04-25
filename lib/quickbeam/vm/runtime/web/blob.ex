defmodule QuickBEAM.VM.Runtime.Web.Blob do
  @moduledoc "Blob constructor builtin for BEAM mode."

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.Interpreter.Values
  alias QuickBEAM.VM.ObjectModel.Get
  alias QuickBEAM.VM.Runtime.WebAPIs

  def bindings do
    %{"Blob" => WebAPIs.register("Blob", &build_blob/2)}
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
          arr |> Heap.to_list() |> Enum.map_join("", &Values.stringify/1)

        list when is_list(list) ->
          Enum.map_join(list, "", &Values.stringify/1)

        _ ->
          ""
      end

    mime_type =
      case opts_val do
        {:obj, _} = obj ->
          case obj |> Get.get("type") |> Values.stringify() do
            "undefined" -> ""
            "null" -> ""
            s -> s
          end

        _ ->
          ""
      end

    Heap.wrap(%{"size" => byte_size(content), "type" => mime_type})
  end
end
