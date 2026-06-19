defmodule QuickBEAM.VM.Host.Web.Streams do
  @moduledoc "ReadableStream, WritableStream, and TransformStream builtins for BEAM mode."

  @behaviour QuickBEAM.VM.Runtime.BindingProvider

  import QuickBEAM.VM.Builtin, only: [arg: 3, object: 1]

  alias QuickBEAM.VM.{Heap, Promise}
  alias QuickBEAM.VM.ObjectModel.{Get, InternalMethods}
  alias QuickBEAM.VM.Host.Callback
  alias QuickBEAM.VM.Host.Web.IteratorResult
  alias QuickBEAM.VM.Host.Web.Streams.{Bytes, State}
  alias QuickBEAM.VM.Host.WebAPIs

  @doc "Returns the JavaScript global bindings provided by this module."
  def bindings do
    WebAPIs.register_constructors([
      {"ReadableStream", &build_readable_stream/2},
      {"WritableStream", &build_writable_stream/2},
      {"TransformStream", &build_transform_stream/2},
      {"TextEncoderStream", &build_text_encoder_stream/2},
      {"TextDecoderStream", &build_text_decoder_stream/2}
    ])
  end

  defp build_text_encoder_stream(_args, _this) do
    chunks_ref = State.new()

    sink =
      Heap.wrap(%{
        "write" =>
          {:builtin, "write",
           fn [chunk | _], _ ->
             str = if is_binary(chunk), do: chunk, else: to_string(chunk)
             bytes = :unicode.characters_to_binary(str)
             State.append_chunk(chunks_ref, bytes)
             :undefined
           end},
        "close" =>
          {:builtin, "close",
           fn _, _ ->
             State.close(chunks_ref)
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
    object do
      method "read" do
        case State.take_chunk(chunks_ref) do
          {:ok, chunk} -> chunk |> Bytes.uint8_array() |> IteratorResult.resolved_value()
          :empty -> IteratorResult.resolved_done()
        end
      end

      method "releaseLock" do
        :undefined
      end

      method "cancel" do
        Promise.resolved(:undefined)
      end
    end
  end

  defp build_text_decoder_stream(args, _this) do
    label =
      case args do
        [l | _] when is_binary(l) -> String.downcase(l)
        _ -> "utf-8"
      end

    chunks_ref = State.new()

    sink =
      Heap.wrap(%{
        "write" =>
          {:builtin, "write",
           fn [chunk | _], _ ->
             bytes = Bytes.extract(chunk)
             decoded = :unicode.characters_to_binary(bytes)
             State.append_chunk(chunks_ref, decoded)
             :undefined
           end},
        "close" =>
          {:builtin, "close",
           fn _, _ ->
             State.close(chunks_ref)
             :undefined
           end}
      })

    readable = build_readable_stream_from_ref(chunks_ref)
    writable = build_writable_stream([sink], nil)
    Heap.wrap(%{"readable" => readable, "writable" => writable, "encoding" => label})
  end

  defp build_readable_stream(args, _this) do
    source = arg(args, 0, nil)

    chunks_ref = State.new(%{locked: false})

    controller = build_controller(chunks_ref)

    case source do
      {:obj, _} ->
        start_fn = Get.get(source, "start")

        if start_fn != :undefined and start_fn != nil do
          try do
            Callback.invoke(start_fn, [controller])
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
         if State.locked?(chunks_ref) do
           QuickBEAM.VM.JSThrow.type_error!("ReadableStream is already locked")
         end

         State.set_locked(chunks_ref, true)
         InternalMethods.set(this, "locked", true)
         build_reader(chunks_ref)
       end}

    async_iter_fn =
      {:builtin, "[Symbol.asyncIterator]",
       fn _args, _this ->
         build_stream_async_iterator(chunks_ref)
       end}

    pipe_through_fn = pipe_through_fn(chunks_ref)
    pipe_to_fn = pipe_to_fn(chunks_ref)

    object do
      prop("locked", false)
      prop("getReader", reader_fn)
      prop(sym_async_iter, async_iter_fn)
      prop("pipeThrough", pipe_through_fn)
      prop("pipeTo", pipe_to_fn)
    end
  end

  defp pipe_through_fn(chunks_ref) do
    {:builtin, "pipeThrough",
     fn [ts | _], _this ->
       reader = build_reader(chunks_ref)
       writable = Get.get(ts, "writable")
       readable = Get.get(ts, "readable")
       writer = get_writer(writable)

       drain_loop(reader, writer)
       readable
     end}
  end

  defp pipe_to_fn(chunks_ref) do
    {:builtin, "pipeTo",
     fn [ws | _], _this ->
       reader = build_reader(chunks_ref)
       writer = get_writer(ws)

       drain_loop(reader, writer)
       Promise.resolved(:undefined)
     end}
  end

  defp get_writer(ws) do
    case ws do
      {:obj, _} ->
        write_fn = Get.get(ws, "getWriter")

        case write_fn do
          {:builtin, _, cb} -> cb.([], ws)
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp build_controller(chunks_ref) do
    object do
      method "enqueue" do
        value = arg(args, 0, :undefined)

        unless State.closed?(chunks_ref) do
          State.append_chunk(chunks_ref, value)
        end

        :undefined
      end

      method "close" do
        State.close(chunks_ref)
        :undefined
      end

      method "error" do
        err_reason = arg(args, 0, nil)
        State.error(chunks_ref, err_reason)
        :undefined
      end
    end
  end

  defp build_reader(chunks_ref) do
    object do
      method "read" do
        case State.take_chunk(chunks_ref) do
          {:ok, chunk} -> IteratorResult.resolved_value(chunk)
          :empty -> IteratorResult.resolved_done()
        end
      end

      method "releaseLock" do
        :undefined
      end

      method "cancel" do
        Promise.resolved(:undefined)
      end
    end
  end

  defp build_stream_async_iterator(chunks_ref) do
    sym_async_iter = {:symbol, "Symbol.asyncIterator"}

    iter =
      object do
        method "next" do
          case State.take_chunk(chunks_ref) do
            {:ok, chunk} -> IteratorResult.resolved_value(chunk)
            :empty -> IteratorResult.resolved_done()
          end
        end

        method "return" do
          IteratorResult.resolved_done()
        end
      end

    {:obj, ref} = iter

    Heap.update_obj(ref, %{}, fn m ->
      Map.put(m, sym_async_iter, {:builtin, "[Symbol.asyncIterator]", fn _, this -> this end})
    end)

    iter
  end

  defp build_writable_stream(args, _this) do
    sink = arg(args, 0, nil)

    write_fn =
      case sink do
        {:obj, _} ->
          case Get.get(sink, "write") do
            f when f != :undefined and f != nil -> f
            _ -> nil
          end

        _ ->
          nil
      end

    close_fn =
      case sink do
        {:obj, _} ->
          case Get.get(sink, "close") do
            f when f != :undefined and f != nil -> f
            _ -> nil
          end

        _ ->
          nil
      end

    ws_ref = make_ref()
    Heap.put_obj(ws_ref, %{locked: false})

    object do
      accessor "locked" do
        get do
          ws_ref
          |> Heap.get_obj(%{})
          |> Map.get(:locked, false)
        end
      end

      method "getWriter" do
        state = Heap.get_obj(ws_ref, %{})
        Heap.put_obj(ws_ref, Map.put(state, :locked, true))

        object do
          method "write" do
            chunk = arg(args, 0, :undefined)

            if write_fn != nil do
              try do
                Callback.invoke(write_fn, [chunk])
              rescue
                _ -> :ok
              catch
                _, _ -> :ok
              end
            end

            Promise.resolved(:undefined)
          end

          method "close" do
            if close_fn != nil do
              try do
                Callback.invoke(close_fn, [])
              rescue
                _ -> :ok
              catch
                _, _ -> :ok
              end
            end

            Promise.resolved(:undefined)
          end

          method "abort" do
            Promise.resolved(:undefined)
          end

          method "releaseLock" do
            state2 = Heap.get_obj(ws_ref, %{})
            Heap.put_obj(ws_ref, Map.put(state2, :locked, false))
            :undefined
          end
        end
      end

      method "abort" do
        Promise.resolved(:undefined)
      end

      method "close" do
        Promise.resolved(:undefined)
      end
    end
  end

  defp build_transform_stream(args, _this) do
    transformer = arg(args, 0, nil)
    chunks_ref = State.new(%{locked: false})

    transform_fn =
      case transformer do
        {:obj, _} ->
          case Get.get(transformer, "transform") do
            f when f != :undefined and f != nil -> f
            _ -> nil
          end

        _ ->
          nil
      end

    flush_fn =
      case transformer do
        {:obj, _} ->
          case Get.get(transformer, "flush") do
            f when f != :undefined and f != nil -> f
            _ -> nil
          end

        _ ->
          nil
      end

    controller = build_controller(chunks_ref)

    sink =
      Heap.wrap(%{
        "write" =>
          {:builtin, "write",
           fn [chunk | _], _ ->
             if transform_fn != nil do
               try do
                 Callback.invoke(transform_fn, [chunk, controller])
               rescue
                 _ ->
                   State.append_chunk(chunks_ref, chunk)
               catch
                 _, _ ->
                   State.append_chunk(chunks_ref, chunk)
               end
             else
               State.append_chunk(chunks_ref, chunk)
             end

             :undefined
           end},
        "close" =>
          {:builtin, "close",
           fn _, _ ->
             if flush_fn != nil do
               try do
                 Callback.invoke(flush_fn, [controller])
               rescue
                 _ -> :ok
               catch
                 _, _ -> :ok
               end
             end

             State.close(chunks_ref)
             :undefined
           end}
      })

    _readable = build_readable_stream([], nil)
    writable = build_writable_stream([sink], nil)
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

    pipe_through_fn = pipe_through_fn(chunks_ref)
    pipe_to_fn = pipe_to_fn(chunks_ref)

    object do
      prop("locked", false)
      prop("getReader", reader_fn)
      prop(sym_async_iter, async_iter_fn)
      prop("pipeThrough", pipe_through_fn)
      prop("pipeTo", pipe_to_fn)
    end
  end

  defp drain_loop(reader, writer) do
    drain_loop_impl(reader, writer, 1000)
  end

  defp drain_loop_impl(_reader, _writer, 0), do: :ok

  defp drain_loop_impl(reader, writer, n) do
    read_fn = Get.get(reader, "read")

    result =
      case read_fn do
        {:builtin, _, cb} ->
          prom = cb.([], reader)
          resolve_promise(prom)

        _ ->
          %{"done" => true}
      end

    done =
      case result do
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
      value =
        case result do
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
