defmodule QuickBEAM.VM.Runtime.Web.BeamAPI do
  @moduledoc "Beam object builtin for BEAM mode — provides Beam.self, Beam.onMessage, Beam.send, Beam.call, Beam.monitor, Beam.demonitor."

  import QuickBEAM.VM.Builtin, only: [build_object: 1]

  import QuickBEAM.VM.Heap.Keys
  alias QuickBEAM.VM.{Heap, Invocation, JSThrow, PromiseState}
  alias QuickBEAM.VM.ObjectModel.Get

  @on_message_key :qb_beam_on_message
  @monitors_key :qb_beam_monitors
  @pending_messages_key :qb_beam_pending_messages

  def bindings do
    %{"Beam" => beam_object()}
  end

  defp beam_object do
    build_object do
      method "self" do
        ctx = Heap.get_ctx()
        runtime_pid = if ctx, do: Map.get(ctx, :runtime_pid), else: nil
        runtime_pid || :undefined
      end

      method "onMessage" do
        case args do
          [handler | _] when not is_nil(handler) and handler != :undefined ->
            # Validate it's a function
            unless QuickBEAM.VM.Builtin.callable?(handler) do
              JSThrow.type_error!("Beam.onMessage requires a function argument")
            end

            Process.put(@on_message_key, handler)

            # Deliver any pending messages
            pending = Process.get(@pending_messages_key, [])
            Process.delete(@pending_messages_key)

            Enum.each(pending, fn msg ->
              deliver_message(handler, msg)
            end)

            :undefined

          _ ->
            JSThrow.type_error!("Beam.onMessage requires a function argument")
        end
      end

      method "send" do
        case args do
          [pid, msg | _] when is_pid(pid) ->
            elixir_msg = js_to_elixir(msg)
            send(pid, elixir_msg)
            :undefined

          [nil | _] ->
            JSThrow.type_error!("Beam.send requires a pid and a message")

          [:undefined | _] ->
            JSThrow.type_error!("Beam.send requires a pid and a message")

          [] ->
            JSThrow.type_error!("Beam.send requires a pid and a message")

          [_, _ | _] ->
            JSThrow.type_error!("Value is not a valid PID")

          [_pid_like | _] ->
            JSThrow.type_error!("Value is not a valid PID")
        end
      end

      method "call" do
        case args do
          [handler_name | call_args] when is_binary(handler_name) ->
            ctx = Heap.get_ctx()
            runtime_pid = if ctx, do: Map.get(ctx, :runtime_pid), else: nil

            handler_globals = Heap.get_handler_globals() || %{}
            flat_args = call_args

            case Map.get(handler_globals, handler_name) do
              {:builtin, _, cb} ->
                result = cb.(flat_args)
                PromiseState.resolved(result)

              _ ->
                # Try via GenServer
                if runtime_pid do
                  try do
                    result = GenServer.call(runtime_pid, {:beam_call, handler_name, flat_args}, 30_000)
                    PromiseState.resolved(result)
                  catch
                    :exit, _ -> PromiseState.rejected(Heap.make_error("Handler not found: #{handler_name}"))
                  end
                else
                  PromiseState.rejected(Heap.make_error("Handler not found: #{handler_name}"))
                end
            end

          _ ->
            JSThrow.type_error!("Beam.call requires a handler name")
        end
      end

      method "callSync" do
        case args do
          [handler_name | call_args] when is_binary(handler_name) ->
            handler_globals = Heap.get_handler_globals() || %{}

            case Map.get(handler_globals, handler_name) do
              {:builtin, _, cb} -> cb.(call_args)
              _ -> :undefined
            end

          _ ->
            :undefined
        end
      end

      method "monitor" do
        case args do
          [pid, callback | _] when is_pid(pid) ->
            ref = Process.monitor(pid)
            monitors = Process.get(@monitors_key, %{})
            Process.put(@monitors_key, Map.put(monitors, ref, callback))
            ref

          _ ->
            JSThrow.type_error!("Beam.monitor requires a pid and a callback")
        end
      end

      method "demonitor" do
        case args do
          [ref | _] when is_reference(ref) ->
            Process.demonitor(ref, [:flush])
            monitors = Process.get(@monitors_key, %{})
            Process.put(@monitors_key, Map.delete(monitors, ref))
            :undefined

          _ ->
            :undefined
        end
      end

      method "receive_pending" do
        # Drain pending BEAM messages and deliver to handler
        drain_beam_messages()
        :undefined
      end
    end
  end

  defp deliver_message(handler, msg) do
    try do
      Invocation.invoke_with_receiver(handler, [msg], :undefined)
    rescue
      _ -> :ok
    catch
      {:js_throw, _} -> :ok
      _, _ -> :ok
    end
  end

  defp drain_beam_messages do
    handler = Process.get(@on_message_key)
    receive do
      {:beam_message, msg} ->
        if handler, do: deliver_message(handler, msg)
        drain_beam_messages()

      {:DOWN, ref, :process, _pid, reason} ->
        monitors = Process.get(@monitors_key, %{})
        case Map.get(monitors, ref) do
          nil -> :ok
          callback ->
            reason_str = case reason do
              :normal -> "normal"
              :killed -> "killed"
              other when is_atom(other) -> Atom.to_string(other)
              _ -> inspect(reason)
            end
            try do
              Invocation.invoke_with_receiver(callback, [reason_str], :undefined)
            rescue
              _ -> :ok
            catch
              _, _ -> :ok
            end
            monitors2 = Process.get(@monitors_key, %{})
            Process.put(@monitors_key, Map.delete(monitors2, ref))
        end
        drain_beam_messages()

      _other ->
        drain_beam_messages()
    after
      0 -> :ok
    end
  end

  defp js_to_elixir({:obj, ref}) do
    case Heap.get_obj(ref, %{}) do
      {:qb_arr, arr} ->
        :array.to_list(arr) |> Enum.map(&js_to_elixir/1)

      list when is_list(list) ->
        Enum.map(list, &js_to_elixir/1)

      map when is_map(map) ->
        map
        |> Map.drop([key_order()])
        |> Map.new(fn {k, v} -> {js_to_elixir_key(k), js_to_elixir(v)} end)
        |> Map.reject(fn {k, _} ->
          is_binary(k) and String.starts_with?(k, "__") and String.ends_with?(k, "__")
        end)

      _ -> nil
    end
  end

  defp js_to_elixir(:undefined), do: nil
  defp js_to_elixir(nil), do: nil
  defp js_to_elixir(v) when is_pid(v), do: v
  defp js_to_elixir(v) when is_reference(v), do: v
  defp js_to_elixir(v) when is_binary(v), do: v
  defp js_to_elixir(v) when is_number(v), do: v
  defp js_to_elixir(v) when is_boolean(v), do: v
  defp js_to_elixir(list) when is_list(list), do: Enum.map(list, &js_to_elixir/1)
  defp js_to_elixir(v), do: v

  defp js_to_elixir_key(k) when is_binary(k), do: k
  defp js_to_elixir_key(k) when is_integer(k), do: Integer.to_string(k)
  defp js_to_elixir_key(k), do: inspect(k)

  @doc "Called from the Elixir side to deliver a message to JS"
  def deliver_beam_message(js_msg) do
    handler = Process.get(@on_message_key)
    if handler do
      deliver_message(handler, js_msg)
    else
      pending = Process.get(@pending_messages_key, [])
      Process.put(@pending_messages_key, pending ++ [js_msg])
    end
  end
end
