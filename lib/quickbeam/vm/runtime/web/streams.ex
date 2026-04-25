defmodule QuickBEAM.VM.Runtime.Web.Streams do
  @moduledoc "ReadableStream, WritableStream, and TransformStream builtins for BEAM mode."

  import QuickBEAM.VM.Builtin, only: [build_methods: 1]

  alias QuickBEAM.VM.{Heap, Invocation, PromiseState}
  alias QuickBEAM.VM.ObjectModel.{Get, Put}
  alias QuickBEAM.VM.Runtime.WebAPIs

  def bindings do
    %{
      "ReadableStream" => WebAPIs.register("ReadableStream", &build_readable_stream/2),
      "WritableStream" => WebAPIs.register("WritableStream", &build_writable_stream/2),
      "TransformStream" => WebAPIs.register("TransformStream", &build_transform_stream/2),
      "TextEncoderStream" => WebAPIs.register("TextEncoderStream", &build_text_encoder_stream/2),
      "TextDecoderStream" => WebAPIs.register("TextDecoderStream", &build_text_decoder_stream/2)
    }
  end

  defp build_text_encoder_stream(_args, _this) do
    chunks_ref = make_ref()
    Heap.put_obj(chunks_ref, %{chunks: [], closed: false})

    sink = Heap.wrap(%{
      "write" => {:builtin, "write", fn [chunk | _], _ ->
        str = if is_binary(chunk), do: chunk, else: to_string(chunk)
        bytes = :unicode.characters_to_binary(str)
        state = Heap.get_obj(chunks_ref, %{})
        existing = Map.get(state, :chunks, [])
        Heap.put_obj(chunks_ref, Map.put(state, :chunks, existing ++ [bytes]))
        :undefined
      end},
      "close" => {:builtin, "close", fn _, _ ->
        state = Heap.get_obj(chunks_ref, %{})
        Heap.put_obj(chunks_ref, Map.put(state, :closed, true))
        :undefined
      end}
    })

    readable = build_readable_stream_from_ref_encoded(chunks_ref)
    writable = build_writable_stream([sink], nil)
    Heap.wrap(%{"readable" => readable, "writable" => writable, "encoding" => "utf-8"})
  end

  defp build_readable_stream_from_ref_encoded(chunks_ref) do
    reader_fn = {:builtin, "getReader", fn _, _ -> build_uint8_reader(chunks_ref) end}
    Heap.wrap(%{"getReader" => reader_fn, "locked" => false})
  end

  defp build_uint8_reader(chunks_ref) do
    Heap.wrap(
      build_methods do
        method "read" do
          state = Heap.get_obj(chunks_ref, %{})
          chunks = Map.get(state, :chunks, [])
          case chunks do
            [chunk | rest] ->
              Heap.put_obj(chunks_ref, Map.put(state, :chunks, rest))
              val = bytes_to_uint8array(chunk)
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
      end
    )
  end

  defp build_text_decoder_stream(args, _this) do
    label = case args do
      [l | _] when is_binary(l) -> String.downcase(l)
      _ -> "utf-8"
    end

    chunks_ref = make_ref()
    Heap.put_obj(chunks_ref, %{chunks: [], closed: false})

    sink = Heap.wrap(%{
      "write" => {:builtin, "write", fn [chunk | _], _ ->
        bytes = extract_bytes(chunk)
        decoded = :unicode.characters_to_binary(bytes)
        state = Heap.get_obj(chunks_ref, %{})
        existing = Map.get(state, :chunks, [])
        Heap.put_obj(chunks_ref, Map.put(state, :chunks, existing ++ [decoded]))
        :undefined
      end},
      "close" => {:builtin, "close", fn _, _ ->
        state = Heap.get_obj(chunks_ref, %{})
        Heap.put_obj(chunks_ref, Map.put(state, :closed, true))
        :undefined
      end}
    })

    readable = build_readable_stream_from_ref(chunks_ref)
    writable = build_writable_stream([sink], nil)
    Heap.wrap(%{"readable" => readable, "writable" => writable, "encoding" => label})
  end

  defp bytes_to_uint8array(bytes) when is_binary(bytes) do
    case Heap.get_global_cache() do
      nil -> Heap.wrap(:binary.bin_to_list(bytes))
      globals ->
        case Map.get(globals, "Uint8Array") do
          {:builtin, _, cb} -> cb.([bytes], nil)
          _ -> Heap.wrap(:binary.bin_to_list(bytes))
        end
    end
  end

  defp extract_bytes({:obj, ref}) do
    case Heap.get_obj(ref, %{}) do
      m when is_map(m) ->
        cond do
          Map.has_key?(m, "__typed_array__") ->
            case Map.get(m, "buffer") do
              {:obj, buf_ref} ->
                case Heap.get_obj(buf_ref, %{}) do
                  bm when is_map(bm) ->
                    ab = Map.get(bm, "__buffer__", <<>>)
                    off = Map.get(m, "byteOffset", 0)
                    blen = Map.get(m, "byteLength", 0)
                    if byte_size(ab) >= off + blen and blen > 0,
                      do: binary_part(ab, off, blen),
                      else: <<>>
                  _ -> <<>>
                end
              _ -> <<>>
            end
          Map.has_key?(m, "__buffer__") -> Map.get(m, "__buffer__", <<>>)
          true -> <<>>
        end
      _ -> <<>>
    end
  end

  defp extract_bytes(b) when is_binary(b), do: b
  defp extract_bytes({:bytes, b}), do: b
  defp extract_bytes(_), do: <<>>

  defp build_readable_stream(args, _this) do
    source = List.first(args)

    chunks_ref = make_ref()
    Heap.put_obj(chunks_ref, %{chunks: [], closed: false, locked: false})

    controller = build_controller(chunks_ref)

    case source do
      {:obj, _} ->
        start_fn = Get.get(source, "start")

        if start_fn != :undefined and start_fn != nil do
          try do
            Invocation.invoke_with_receiver(start_fn, [controller], :undefined)
          rescue
            _ -> :ok
          catch
            _, _ -> :ok
          end
        end

      _ ->
        :ok
    end

    sym_async_iter = {:symbol, "Symbol.asyncIterator"}

    reader_fn =
      {:builtin, "getReader",
       fn _args, this ->
         state = Heap.get_obj(chunks_ref, %{})

         if Map.get(state, :locked, false) do
           QuickBEAM.VM.JSThrow.type_error!("ReadableStream is already locked")
         end

         Heap.put_obj(chunks_ref, Map.put(state, :locked, true))
         Put.put(this, "locked", true)
         build_reader(chunks_ref)
       end}

    async_iter_fn =
      {:builtin, "[Symbol.asyncIterator]",
       fn _args, _this ->
         build_stream_async_iterator(chunks_ref)
       end}

    pipe_through_fn =
      {:builtin, "pipeThrough",
       fn [ts | _], _this ->
         reader = build_reader(chunks_ref)
         writable = Get.get(ts, "writable")
         readable = Get.get(ts, "readable")

         writer = get_writer(writable)
         drain_loop(reader, writer)
         readable
       end}

    pipe_to_fn =
      {:builtin, "pipeTo",
       fn [ws | _], _this ->
         reader = build_reader(chunks_ref)
         writer = get_writer(ws)
         drain_loop(reader, writer)
         PromiseState.resolved(:undefined)
       end}

    Heap.wrap(
      build_methods do
        val("locked", false)
      end
      |> Map.merge(%{
        "getReader" => reader_fn,
        sym_async_iter => async_iter_fn,
        "pipeThrough" => pipe_through_fn,
        "pipeTo" => pipe_to_fn
      })
    )
  end

  defp get_writer(ws) do
    case ws do
      {:obj, _} ->
        write_fn = Get.get(ws, "getWriter")
        case write_fn do
          {:builtin, _, cb} -> cb.([], ws)
          _ -> nil
        end
      _ -> nil
    end
  end

  defp build_controller(chunks_ref) do
    Heap.wrap(
      build_methods do
        method "enqueue" do
          value = List.first(args, :undefined)
          state = Heap.get_obj(chunks_ref, %{})

          unless Map.get(state, :closed, false) do
            chunks = Map.get(state, :chunks, [])
            Heap.put_obj(chunks_ref, Map.put(state, :chunks, chunks ++ [value]))
          end

          :undefined
        end

        method "close" do
          state = Heap.get_obj(chunks_ref, %{})
          Heap.put_obj(chunks_ref, Map.put(state, :closed, true))
          :undefined
        end

        method "error" do
          err_reason = List.first(args)
          state = Heap.get_obj(chunks_ref, %{})
          Heap.put_obj(chunks_ref, Map.merge(state, %{closed: true, error: err_reason}))
          :undefined
        end
      end
    )
  end

  defp build_reader(chunks_ref) do
    Heap.wrap(
      build_methods do
        method "read" do
          state = Heap.get_obj(chunks_ref, %{})
          chunks = Map.get(state, :chunks, [])

          case chunks do
            [chunk | rest] ->
              Heap.put_obj(chunks_ref, Map.put(state, :chunks, rest))
              result = Heap.wrap(%{"value" => chunk, "done" => false})
              PromiseState.resolved(result)

            [] ->
              if Map.get(state, :closed, false) do
                result = Heap.wrap(%{"value" => :undefined, "done" => true})
                PromiseState.resolved(result)
              else
                result = Heap.wrap(%{"value" => :undefined, "done" => true})
                PromiseState.resolved(result)
              end
          end
        end

        method "releaseLock" do
          :undefined
        end

        method "cancel" do
          PromiseState.resolved(:undefined)
        end
      end
    )
  end

  defp build_stream_async_iterator(chunks_ref) do
    sym_async_iter = {:symbol, "Symbol.asyncIterator"}

    iter =
      Heap.wrap(
        build_methods do
          method "next" do
            state = Heap.get_obj(chunks_ref, %{})
            chunks = Map.get(state, :chunks, [])

            case chunks do
              [chunk | rest] ->
                Heap.put_obj(chunks_ref, Map.put(state, :chunks, rest))
                result = Heap.wrap(%{"value" => chunk, "done" => false})
                PromiseState.resolved(result)

              [] ->
                result = Heap.wrap(%{"value" => :undefined, "done" => true})
                PromiseState.resolved(result)
            end
          end

          method "return" do
            result = Heap.wrap(%{"value" => :undefined, "done" => true})
            PromiseState.resolved(result)
          end
        end
      )

    case iter do
      {:obj, ref} ->
        Heap.update_obj(ref, %{}, fn m ->
          Map.put(m, sym_async_iter, {:builtin, "[Symbol.asyncIterator]", fn _, this -> this end})
        end)

        iter

      _ ->
        iter
    end
  end

  defp build_writable_stream(args, _this) do
    sink = List.first(args)
    locked_ref = make_ref()
    Heap.put_obj(locked_ref, false)

    write_fn = case sink do
      {:obj, _} ->
        case Get.get(sink, "write") do
          f when f != :undefined and f != nil -> f
          _ -> nil
        end
      _ -> nil
    end

    close_fn = case sink do
      {:obj, _} ->
        case Get.get(sink, "close") do
          f when f != :undefined and f != nil -> f
          _ -> nil
        end
      _ -> nil
    end

    ws_ref = make_ref()
    Heap.put_obj(ws_ref, %{locked: false})

    locked_accessor = {:accessor,
      {:builtin, "get locked", fn _, _ ->
         state = Heap.get_obj(ws_ref, %{})
         Map.get(state, :locked, false)
       end},
      nil}

    Heap.wrap(
      %{
        "locked" => locked_accessor,
        "getWriter" => {:builtin, "getWriter", fn _, _ ->
          state = Heap.get_obj(ws_ref, %{})
          Heap.put_obj(ws_ref, Map.put(state, :locked, true))

          Heap.wrap(
            build_methods do
              method "write" do
                chunk = List.first(args, :undefined)
                if write_fn != nil do
                  try do
                    Invocation.invoke_with_receiver(write_fn, [chunk], :undefined)
                  rescue
                    _ -> :ok
                  catch
                    _, _ -> :ok
                  end
                end
                PromiseState.resolved(:undefined)
              end

              method "close" do
                if close_fn != nil do
                  try do
                    Invocation.invoke_with_receiver(close_fn, [], :undefined)
                  rescue
                    _ -> :ok
                  catch
                    _, _ -> :ok
                  end
                end
                PromiseState.resolved(:undefined)
              end

              method "abort" do
                PromiseState.resolved(:undefined)
              end

              method "releaseLock" do
                state2 = Heap.get_obj(ws_ref, %{})
                Heap.put_obj(ws_ref, Map.put(state2, :locked, false))
                :undefined
              end
            end
          )
        end},
        "abort" => {:builtin, "abort", fn _, _ -> PromiseState.resolved(:undefined) end},
        "close" => {:builtin, "close", fn _, _ -> PromiseState.resolved(:undefined) end}
      }
    )
  end

  defp build_transform_stream(args, _this) do
    transformer = List.first(args)
    chunks_ref = make_ref()
    Heap.put_obj(chunks_ref, %{chunks: [], closed: false, locked: false})

    transform_fn = case transformer do
      {:obj, _} ->
        case Get.get(transformer, "transform") do
          f when f != :undefined and f != nil -> f
          _ -> nil
        end
      _ -> nil
    end

    flush_fn = case transformer do
      {:obj, _} ->
        case Get.get(transformer, "flush") do
          f when f != :undefined and f != nil -> f
          _ -> nil
        end
      _ -> nil
    end

    controller = build_controller(chunks_ref)

    sink = Heap.wrap(%{
      "write" => {:builtin, "write", fn [chunk | _], _ ->
        if transform_fn != nil do
          try do
            Invocation.invoke_with_receiver(transform_fn, [chunk, controller], :undefined)
          rescue
            _ ->
              state = Heap.get_obj(chunks_ref, %{})
              chunks = Map.get(state, :chunks, [])
              Heap.put_obj(chunks_ref, Map.put(state, :chunks, chunks ++ [chunk]))
          catch
            _, _ ->
              state = Heap.get_obj(chunks_ref, %{})
              chunks = Map.get(state, :chunks, [])
              Heap.put_obj(chunks_ref, Map.put(state, :chunks, chunks ++ [chunk]))
          end
        else
          state = Heap.get_obj(chunks_ref, %{})
          chunks = Map.get(state, :chunks, [])
          Heap.put_obj(chunks_ref, Map.put(state, :chunks, chunks ++ [chunk]))
        end
        :undefined
      end},
      "close" => {:builtin, "close", fn _, _ ->
        if flush_fn != nil do
          try do
            Invocation.invoke_with_receiver(flush_fn, [controller], :undefined)
          rescue
            _ -> :ok
          catch
            _, _ -> :ok
          end
        end
        state = Heap.get_obj(chunks_ref, %{})
        Heap.put_obj(chunks_ref, Map.put(state, :closed, true))
        :undefined
      end}
    })

    readable = build_readable_stream([], nil)
    writable = build_writable_stream([sink], nil)

    # Override readable to read from our chunks_ref
    readable_from_chunks = build_readable_stream_from_ref(chunks_ref)

    Heap.wrap(%{
      "readable" => readable_from_chunks,
      "writable" => writable
    })
  end

  defp build_readable_stream_from_ref(chunks_ref) do
    sym_async_iter = {:symbol, "Symbol.asyncIterator"}

    reader_fn =
      {:builtin, "getReader",
       fn _args, _this ->
         build_reader(chunks_ref)
       end}

    async_iter_fn =
      {:builtin, "[Symbol.asyncIterator]",
       fn _args, _this ->
         build_stream_async_iterator(chunks_ref)
       end}

    pipe_through_fn =
      {:builtin, "pipeThrough",
       fn [ts | _], _this ->
         reader = build_reader(chunks_ref)
         writable = Get.get(ts, "writable")
         readable = Get.get(ts, "readable")

         writer = case writable do
           {:obj, _} ->
             write_fn = Get.get(writable, "getWriter")
             case write_fn do
               {:builtin, _, cb} -> cb.([], writable)
               _ -> nil
             end
           _ -> nil
         end

         drain_loop(reader, writer)
         readable
       end}

    pipe_to_fn =
      {:builtin, "pipeTo",
       fn [ws | _], _this ->
         reader = build_reader(chunks_ref)
         writer = case ws do
           {:obj, _} ->
             write_fn = Get.get(ws, "getWriter")
             case write_fn do
               {:builtin, _, cb} -> cb.([], ws)
               _ -> nil
             end
           _ -> nil
         end

         drain_loop(reader, writer)
         PromiseState.resolved(:undefined)
       end}

    Heap.wrap(
      build_methods do
        val("locked", false)
      end
      |> Map.merge(%{
        "getReader" => reader_fn,
        sym_async_iter => async_iter_fn,
        "pipeThrough" => pipe_through_fn,
        "pipeTo" => pipe_to_fn
      })
    )
  end

  defp drain_loop(reader, writer) do
    drain_loop_impl(reader, writer, 1000)
  end

  defp drain_loop_impl(_reader, _writer, 0), do: :ok
  defp drain_loop_impl(reader, writer, n) do
    read_fn = Get.get(reader, "read")
    result = case read_fn do
      {:builtin, _, cb} ->
        prom = cb.([], reader)
        resolve_promise(prom)
      _ -> %{"done" => true}
    end

    done = case result do
      {:obj, ref} -> Heap.get_obj(ref, %{}) |> Map.get("done", false)
      %{"done" => d} -> d
      _ -> true
    end

    if done do
      if writer != nil do
        close_fn = Get.get(writer, "close")
        case close_fn do
          {:builtin, _, cb} -> cb.([], writer)
          _ -> :ok
        end
      end
      :ok
    else
      value = case result do
        {:obj, ref} -> Heap.get_obj(ref, %{}) |> Map.get("value", :undefined)
        _ -> :undefined
      end

      if writer != nil do
        write_fn = Get.get(writer, "write")
        case write_fn do
          {:builtin, _, cb} -> cb.([value], writer)
          _ -> :ok
        end
      end

      drain_loop_impl(reader, writer, n - 1)
    end
  end

  defp resolve_promise({:obj, ref}) do
    import QuickBEAM.VM.Heap.Keys
    case Heap.get_obj(ref, %{}) do
      %{promise_state() => :resolved, promise_value() => val} -> val
      _ -> %{"done" => true}
    end
  end
  defp resolve_promise(v), do: v

end
