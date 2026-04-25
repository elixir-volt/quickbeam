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
      "TransformStream" => WebAPIs.register("TransformStream", &build_transform_stream/2)
    }
  end

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

    Heap.wrap(
      build_methods do
        val("locked", false)
      end
      |> Map.merge(%{
        "getReader" => reader_fn,
        sym_async_iter => async_iter_fn
      })
    )
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

  defp build_writable_stream(_args, _this) do
    Heap.wrap(
      build_methods do
        method "getWriter" do
          Heap.wrap(
            build_methods do
              method "write" do
                PromiseState.resolved(:undefined)
              end

              method "close" do
                PromiseState.resolved(:undefined)
              end

              method "abort" do
                PromiseState.resolved(:undefined)
              end

              method "releaseLock" do
                :undefined
              end
            end
          )
        end

        method "abort" do
          PromiseState.resolved(:undefined)
        end

        method "close" do
          PromiseState.resolved(:undefined)
        end
      end
    )
  end

  defp build_transform_stream(_args, _this) do
    chunks_ref = make_ref()
    Heap.put_obj(chunks_ref, %{chunks: [], closed: false, locked: false})

    readable = build_readable_stream([], nil)
    writable = build_writable_stream([], nil)

    Heap.wrap(%{
      "readable" => readable,
      "writable" => writable
    })
  end

end
