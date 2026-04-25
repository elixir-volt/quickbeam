defmodule QuickBEAM.VM.Runtime.Web.Compression do
  @moduledoc "compression global object and CompressionStream/DecompressionStream for BEAM mode."

  import QuickBEAM.VM.Builtin, only: [build_object: 1]

  alias QuickBEAM.VM.{Heap, JSThrow}
  alias QuickBEAM.VM.Runtime.Web.Buffer
  alias QuickBEAM.VM.Runtime.WebAPIs

  def bindings do
    %{
      "compression" => build_compression_global(),
      "CompressionStream" => WebAPIs.register("CompressionStream", &build_compression_stream/2),
      "DecompressionStream" => WebAPIs.register("DecompressionStream", &build_decompression_stream/2)
    }
  end

  defp build_compression_global do
    build_object do
      method "compress" do
        [format, data | _] = args ++ [nil, nil]
        format_str = to_string(format)
        validate_format!(format_str)
        bytes = Buffer.extract_buf_bytes(data)

        result =
          try do
            QuickBEAM.Compression.compress([format_str, bytes])
          rescue
            e -> JSThrow.type_error!(Exception.message(e))
          end

        bytes_to_uint8(result)
      end

      method "decompress" do
        [format, data | _] = args ++ [nil, nil]
        format_str = to_string(format)
        validate_format!(format_str)
        bytes = Buffer.extract_buf_bytes(data)

        result =
          try do
            QuickBEAM.Compression.decompress([format_str, bytes])
          rescue
            e -> JSThrow.type_error!(Exception.message(e))
          end

        bytes_to_uint8(result)
      end
    end
  end

  defp build_compression_stream([format | _], _this) do
    format_str = to_string(format)
    validate_format!(format_str)

    chunks_ref = make_ref()
    Heap.put_obj(chunks_ref, %{chunks: [], closed: false})

    controller = build_transform_controller(chunks_ref, format_str, :compress)
    {readable, writable} = build_transform_streams(chunks_ref, format_str, :compress, controller)

    Heap.wrap(%{"readable" => readable, "writable" => writable})
  end

  defp build_compression_stream([], _this) do
    JSThrow.type_error!("CompressionStream requires a format argument")
  end

  defp build_decompression_stream([format | _], _this) do
    format_str = to_string(format)
    validate_format!(format_str)

    chunks_ref = make_ref()
    Heap.put_obj(chunks_ref, %{chunks: [], closed: false})

    controller = build_transform_controller(chunks_ref, format_str, :decompress)
    {readable, writable} = build_transform_streams(chunks_ref, format_str, :decompress, controller)

    Heap.wrap(%{"readable" => readable, "writable" => writable})
  end

  defp build_decompression_stream([], _this) do
    JSThrow.type_error!("DecompressionStream requires a format argument")
  end

  defp build_transform_controller(chunks_ref, format, op) do
    Heap.wrap(%{
      "enqueue" =>
        {:builtin, "enqueue",
         fn [chunk | _], _ ->
           state = Heap.get_obj(chunks_ref, %{})
           chunks = Map.get(state, :chunks, [])
           Heap.put_obj(chunks_ref, Map.put(state, :chunks, chunks ++ [chunk]))
           :undefined
         end},
      "terminate" =>
        {:builtin, "terminate",
         fn _, _ ->
           state = Heap.get_obj(chunks_ref, %{})
           Heap.put_obj(chunks_ref, Map.put(state, :closed, true))
           :undefined
         end}
    })
  end

  defp build_transform_streams(chunks_ref, format, op, _controller) do
    import QuickBEAM.VM.Builtin, only: [build_methods: 1]
    alias QuickBEAM.VM.PromiseState

    writable = Heap.wrap(build_methods do
      method "getWriter" do
        Heap.wrap(build_methods do
          method "write" do
            [chunk | _] = args ++ [nil]
            bytes = Buffer.extract_buf_bytes(chunk)

            transformed = case op do
              :compress ->
                case QuickBEAM.Compression.compress([format, bytes]) do
                  {:bytes, b} -> b
                  b when is_binary(b) -> b
                end
              :decompress ->
                case QuickBEAM.Compression.decompress([format, bytes]) do
                  {:bytes, b} -> b
                  b when is_binary(b) -> b
                end
            end

            state = Heap.get_obj(chunks_ref, %{})
            existing = Map.get(state, :chunks, [])
            Heap.put_obj(chunks_ref, Map.put(state, :chunks, existing ++ [transformed]))
            PromiseState.resolved(:undefined)
          end

          method "close" do
            state = Heap.get_obj(chunks_ref, %{})
            Heap.put_obj(chunks_ref, Map.put(state, :closed, true))
            PromiseState.resolved(:undefined)
          end

          method "abort" do
            PromiseState.resolved(:undefined)
          end

          method "releaseLock" do
            :undefined
          end
        end)
      end

      method "abort" do
        PromiseState.resolved(:undefined)
      end
    end)

    readable = Heap.wrap(build_methods do
      method "getReader" do
        Heap.wrap(build_methods do
          method "read" do
            state = Heap.get_obj(chunks_ref, %{})
            chunks = Map.get(state, :chunks, [])

            case chunks do
              [chunk | rest] ->
                Heap.put_obj(chunks_ref, Map.put(state, :chunks, rest))
                val = case chunk do
                  b when is_binary(b) -> bytes_to_uint8({:bytes, b})
                  _ -> chunk
                end
                PromiseState.resolved(Heap.wrap(%{"value" => val, "done" => false}))
              [] ->
                if Map.get(state, :closed, false) do
                  PromiseState.resolved(Heap.wrap(%{"value" => :undefined, "done" => true}))
                else
                  PromiseState.resolved(Heap.wrap(%{"value" => :undefined, "done" => true}))
                end
            end
          end

          method "releaseLock" do
            :undefined
          end

          method "cancel" do
            PromiseState.resolved(:undefined)
          end
        end)
      end
    end)

    {readable, writable}
  end

  defp validate_format!("gzip"), do: :ok
  defp validate_format!("deflate"), do: :ok
  defp validate_format!("deflate-raw"), do: :ok
  defp validate_format!(fmt), do: JSThrow.type_error!("Unsupported compression format: #{fmt}")

  defp bytes_to_uint8({:bytes, bytes}), do: bytes_to_uint8(bytes)
  defp bytes_to_uint8(bytes) when is_binary(bytes) do
    byte_list = :binary.bin_to_list(bytes)
    case Heap.get_global_cache() do
      nil -> Heap.wrap(byte_list)
      globals ->
        case Map.get(globals, "Uint8Array") do
          {:builtin, _, cb} = ctor ->
            result = cb.([byte_list], nil)
            case result do
              {:obj, ref} ->
                class_proto = Heap.get_class_proto(ctor)
                if class_proto do
                  m = Heap.get_obj(ref, %{})
                  if is_map(m) and not Map.has_key?(m, "__proto__") do
                    Heap.put_obj(ref, Map.put(m, "__proto__", class_proto))
                  end
                end
                result
              _ -> result
            end
          _ -> Heap.wrap(byte_list)
        end
    end
  end
end
