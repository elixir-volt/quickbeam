defmodule AIAgent.AgentTest do
  use ExUnit.Case, async: false

  setup do
    agent_id = "test-agent-#{System.unique_integer([:positive])}"
    on_exit(fn -> cleanup(agent_id) end)
    %{agent_id: agent_id}
  end

  test "basic chat with default echo LLM", %{agent_id: agent_id} do
    {:ok, reply} = AIAgent.Agent.chat(agent_id, "Hello!")
    assert reply["role"] == "assistant"
    assert reply["content"] =~ "Echo"
    assert reply["content"] =~ "Hello!"
    assert is_binary(reply["id"])
    assert is_number(reply["timestamp"])
  end

  test "conversation history accumulates", %{agent_id: agent_id} do
    {:ok, _} = AIAgent.Agent.chat(agent_id, "First message")
    {:ok, _} = AIAgent.Agent.chat(agent_id, "Second message")

    {:ok, history} = AIAgent.Agent.get_history(agent_id)
    assert length(history) == 4

    roles = Enum.map(history, & &1["role"])
    assert roles == ["user", "assistant", "user", "assistant"]
  end

  test "status tracking", %{agent_id: agent_id} do
    {:ok, status} = AIAgent.Agent.get_status(agent_id)
    assert status["status"] == "idle"
    assert status["messageCount"] == 0

    {:ok, _} = AIAgent.Agent.chat(agent_id, "Hi")

    {:ok, status} = AIAgent.Agent.get_status(agent_id)
    assert status["status"] == "idle"
    assert status["messageCount"] == 2
  end

  test "clear history", %{agent_id: agent_id} do
    {:ok, _} = AIAgent.Agent.chat(agent_id, "Something")
    {:ok, _} = AIAgent.Agent.clear_history(agent_id)

    {:ok, history} = AIAgent.Agent.get_history(agent_id)
    assert history == []
  end

  test "configure system prompt", %{agent_id: agent_id} do
    {:ok, _} = AIAgent.Agent.configure(agent_id, "You are a pirate.")
    {:ok, reply} = AIAgent.Agent.chat(agent_id, "Hello")

    assert reply["content"] =~ "pirate"
  end

  test "streaming returns chunks", %{agent_id: agent_id} do
    {:ok, reply} = AIAgent.Agent.chat_stream(agent_id, "Tell me something")
    assert reply["role"] == "assistant"
    assert reply["content"] =~ "Streaming echo"
  end

  test "streaming notifies subscriber", %{agent_id: agent_id} do
    {:ok, _pid} =
      AIAgent.Agent.start_link(agent_id, subscriber: self())

    {:ok, _} = AIAgent.Agent.chat_stream(agent_id, "Hello stream")

    assert_receive {:agent_status, ^agent_id, "thinking"}, 1000
    assert_receive {:agent_chunk, ^agent_id, _chunk}, 1000
    assert_receive {:agent_done, ^agent_id, result}, 1000
    assert result["content"] =~ "Hello stream"
    assert_receive {:agent_status, ^agent_id, "idle"}, 1000
  end

  test "tool use with default echo", %{agent_id: agent_id} do
    tools = %{
      "get_weather" => fn %{"city" => city} -> %{"temp" => 20, "city" => city} end
    }

    {:ok, _pid} = AIAgent.Agent.start_link(agent_id, tools: tools)

    {:ok, reply} = AIAgent.Agent.chat_with_tools(agent_id, "What's the weather?")
    assert reply["role"] == "assistant"
    assert is_binary(reply["content"])
  end

  test "custom LLM backend", %{agent_id: agent_id} do
    custom_llm = fn %{"messages" => messages} ->
      "Custom LLM saw #{length(messages)} messages"
    end

    {:ok, _pid} = AIAgent.Agent.start_link(agent_id, llm: custom_llm)
    {:ok, reply} = AIAgent.Agent.chat(agent_id, "Test")

    assert reply["content"] == "Custom LLM saw 1 messages"
  end

  test "separate agents have separate state", %{agent_id: agent_id} do
    other_id = "#{agent_id}-other"
    on_exit(fn -> cleanup(other_id) end)

    {:ok, _} = AIAgent.Agent.chat(agent_id, "Agent 1")
    {:ok, _} = AIAgent.Agent.chat(other_id, "Agent 2")

    {:ok, h1} = AIAgent.Agent.get_history(agent_id)
    {:ok, h2} = AIAgent.Agent.get_history(other_id)

    assert hd(h1)["content"] == "Agent 1"
    assert hd(h2)["content"] == "Agent 2"
  end

  defp cleanup(agent_id) do
    case Registry.lookup(AIAgent.AgentRegistry, agent_id) do
      [{pid, _}] ->
        try do
          GenServer.stop(pid)
        catch
          :exit, _ -> :ok
        end

      [] ->
        :ok
    end
  end
end
