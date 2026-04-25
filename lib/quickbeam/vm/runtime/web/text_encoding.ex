defmodule QuickBEAM.VM.Runtime.Web.TextEncoding do
  @moduledoc "TextEncoder and TextDecoder builtins for BEAM mode."

  import QuickBEAM.VM.Builtin, only: [build_methods: 1]

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.Runtime

  def bindings do
    %{
      "TextEncoder" => register("TextEncoder", &build_text_encoder/2),
      "TextDecoder" => register("TextDecoder", &build_text_decoder/2)
    }
  end

  defp build_text_encoder(_args, _this) do
    Heap.wrap(%{
      "encoding" => "utf-8",
      "encode" =>
        {:builtin, "encode",
         fn args, _this ->
           str =
             case args do
               [s | _] when is_binary(s) -> s
               _ -> ""
             end

           make_uint8array(:binary.bin_to_list(str))
         end}
    })
  end

  defp build_text_decoder(_args, _this) do
    Heap.wrap(
      build_methods do
        val("encoding", "utf-8")

        method "decode" do
          case args do
            [arr | _] -> List.to_string(typed_array_to_list(arr))
            _ -> ""
          end
        end
      end
    )
  end

  defp make_uint8array(bytes) do
    case Runtime.global_bindings()["Uint8Array"] do
      {:builtin, _, cb} = ctor when is_function(cb, 2) ->
        result = cb.([bytes], nil)

        case result do
          {:obj, ref} ->
            class_proto = Heap.get_class_proto(ctor)

            if class_proto do
              map = Heap.get_obj(ref, %{})

              if is_map(map) and not Map.has_key?(map, "__proto__") do
                Heap.put_obj(ref, Map.put(map, "__proto__", class_proto))
              end
            end

            result

          _ ->
            result
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

      list when is_list(list) ->
        list

      _ ->
        []
    end
  end

  defp typed_array_to_list(list) when is_list(list), do: list
  defp typed_array_to_list(_), do: []

  defp register(name, constructor) do
    ctor = {:builtin, name, constructor}
    proto = Heap.wrap(%{"constructor" => ctor})
    Heap.put_class_proto(ctor, proto)
    Heap.put_ctor_static(ctor, "prototype", proto)
    ctor
  end
end
