defmodule AIAgent.Agent do
  @moduledoc """
  An AI agent backed by a QuickBEAM runtime.

  JS manages conversation state and orchestrates the LLM loop.
  Elixir provides the LLM backend, tool implementations, and streaming delivery.
  """

  @script Path.expand("../../priv/js/agent.ts", __DIR__)

  def child_spec({agent_id, opts}) do
    %{
      id: {__MODULE__, agent_id},
      start: {__MODULE__, :start_link, [agent_id, opts]},
      restart: :transient
    }
  end

  def start_link(agent_id, opts \\ []) do
    llm = Keyword.get(opts, :llm, &default_llm/1)
    llm_stream = Keyword.get(opts, :llm_stream, &default_llm_stream/1)
    llm_with_tools = Keyword.get(opts, :llm_with_tools, &default_llm_with_tools/1)
    tools = Keyword.get(opts, :tools, %{})
    subscriber = Keyword.get(opts, :subscriber, nil)

    QuickBEAM.start(
      name: via(agent_id),
      script: @script,
      handlers: %{
        "llm_complete" => fn [prompt] -> llm.(prompt) end,
        "llm_stream" => fn [prompt] -> llm_stream.(prompt) end,
        "llm_complete_with_tools" => fn [prompt] -> llm_with_tools.(prompt) end,
        "tool_call" => fn [name, args] ->
          case Map.get(tools, name) do
            nil -> %{"error" => "unknown tool: #{name}"}
            func -> func.(args)
          end
        end,
        "status_changed" => fn [status] ->
          if subscriber, do: send(subscriber, {:agent_status, agent_id, status})
          nil
        end,
        "stream_chunk" => fn [chunk] ->
          if subscriber, do: send(subscriber, {:agent_chunk, agent_id, chunk})
          nil
        end,
        "stream_done" => fn [result] ->
          if subscriber, do: send(subscriber, {:agent_done, agent_id, result})
          nil
        end
      }
    )
  end

  def chat(agent_id, message) do
    agent_id |> ensure_started()
    QuickBEAM.call(via(agent_id), "chat", [message])
  end

  def chat_stream(agent_id, message) do
    agent_id |> ensure_started()
    QuickBEAM.call(via(agent_id), "chatStream", [message])
  end

  def chat_with_tools(agent_id, message) do
    agent_id |> ensure_started()
    QuickBEAM.call(via(agent_id), "chatWithTools", [message])
  end

  def configure(agent_id, system_prompt) do
    agent_id |> ensure_started()
    QuickBEAM.call(via(agent_id), "configure", [system_prompt])
  end

  def get_history(agent_id) do
    agent_id |> ensure_started()
    QuickBEAM.call(via(agent_id), "getHistory")
  end

  def get_status(agent_id) do
    agent_id |> ensure_started()
    QuickBEAM.call(via(agent_id), "getStatus")
  end

  def clear_history(agent_id) do
    agent_id |> ensure_started()
    QuickBEAM.call(via(agent_id), "clearHistory")
  end

  defp ensure_started(agent_id) do
    case Registry.lookup(AIAgent.AgentRegistry, agent_id) do
      [{_pid, _}] -> :ok
      [] -> DynamicSupervisor.start_child(AIAgent.AgentSupervisor, {__MODULE__, {agent_id, []}})
    end
  end

  defp via(agent_id) do
    {:via, Registry, {AIAgent.AgentRegistry, agent_id}}
  end

  defp default_llm(%{"system" => system, "messages" => messages}) do
    prompt =
      messages
      |> Enum.map(fn %{"role" => role, "content" => content} -> "#{role}: #{content}" end)
      |> Enum.join("\n")

    "Echo (#{length(messages)} messages, system: #{String.slice(system, 0..30)}...): #{String.slice(prompt, -100..-1//1) || prompt}"
  end

  defp default_llm_stream(%{"system" => _system, "messages" => messages}) do
    user_msgs = Enum.filter(messages, &(&1["role"] == "user"))
    last_msg = (List.last(user_msgs) || %{})["content"] || ""
    response = "Streaming echo: #{last_msg}"
    String.graphemes(response)
  end

  defp default_llm_with_tools(%{"system" => _system, "messages" => messages}) do
    user_msgs = Enum.filter(messages, &(&1["role"] == "user"))
    tool_msgs = Enum.filter(messages, &(&1["role"] == "system" and String.contains?(&1["content"] || "", "Tool results")))
    last_user = (List.last(user_msgs) || %{})["content"] || ""

    cond do
      length(tool_msgs) > 0 ->
        %{"type" => "text", "content" => "Based on tool results: #{last_user}"}

      String.contains?(last_user, "weather") ->
        %{"type" => "tool_calls", "calls" => [%{"name" => "get_weather", "args" => %{"city" => "London"}}]}

      true ->
        %{"type" => "text", "content" => "Echo with tools: #{last_user}"}
    end
  end
end
