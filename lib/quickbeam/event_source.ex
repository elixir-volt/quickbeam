defmodule QuickBEAM.EventSource do
  @moduledoc false

  @spec open(list(), pid()) :: pid()
  def open([url, id], caller_pid) do
    parent = caller_pid

    {:ok, task_pid} =
      Task.start(fn ->
        headers = [
          {~c"Accept", ~c"text/event-stream"},
          {~c"Cache-Control", ~c"no-cache"}
        ]

        url_charlist = String.to_charlist(url)

        case :httpc.request(:get, {url_charlist, headers}, [], [{:sync, false}, {:stream, :self}]) do
          {:ok, request_id} ->
            send(parent, {:eventsource_open, id})
            stream_loop(request_id, parent, id, "")

          {:error, reason} ->
            send(parent, {:eventsource_error, id, inspect(reason)})
        end
      end)

    Process.monitor(task_pid)
    task_pid
  end

  @spec close([pid()]) :: nil
  def close([task_pid]) do
    Process.exit(task_pid, :normal)
    nil
  end

  defp stream_loop(request_id, parent, id, buffer) do
    receive do
      {:http, {^request_id, :stream_start, _headers}} ->
        stream_loop(request_id, parent, id, buffer)

      {:http, {^request_id, :stream, chunk}} ->
        new_buffer = buffer <> to_string(chunk)
        {events, remaining} = parse_sse_events(new_buffer)

        for event <- events do
          send(parent, {:eventsource_event, id, event})
        end

        stream_loop(request_id, parent, id, remaining)

      {:http, {^request_id, :stream_end, _headers}} ->
        send(parent, {:eventsource_error, id, "connection closed"})

      {:http, {^request_id, {:error, reason}}} ->
        send(parent, {:eventsource_error, id, inspect(reason)})
    after
      30_000 ->
        send(parent, {:eventsource_error, id, "timeout"})
    end
  end

  defp parse_sse_events(buffer) do
    parts = String.split(buffer, "\n\n")

    case parts do
      [single] ->
        {[], single}

      chunks ->
        {complete, [remaining]} = Enum.split(chunks, -1)

        events =
          for block <- complete,
              block != "",
              do: parse_sse_block(block)

        {Enum.reject(events, &is_nil/1), remaining}
    end
  end

  defp parse_sse_block(block) do
    lines = String.split(block, "\n")

    Enum.reduce(lines, %{type: "message", data: [], id: nil}, fn line, acc ->
      cond do
        String.starts_with?(line, "data: ") ->
          %{acc | data: acc.data ++ [String.trim_leading(line, "data: ")]}

        String.starts_with?(line, "data:") ->
          %{acc | data: acc.data ++ [String.trim_leading(line, "data:")]}

        String.starts_with?(line, "event: ") ->
          %{acc | type: String.trim_leading(line, "event: ")}

        String.starts_with?(line, "event:") ->
          %{acc | type: String.trim_leading(line, "event:")}

        String.starts_with?(line, "id: ") ->
          %{acc | id: String.trim_leading(line, "id: ")}

        String.starts_with?(line, "id:") ->
          %{acc | id: String.trim_leading(line, "id:")}

        String.starts_with?(line, ":") ->
          acc

        true ->
          acc
      end
    end)
    |> then(fn
      %{data: []} -> nil
      %{data: data} = event -> %{event | data: Enum.join(data, "\n")}
    end)
  end
end
