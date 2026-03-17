IO.puts("""
╔══════════════════════════════════════════════════════╗
║            QuickBEAM AI Agent Example                ║
║  Agents = supervised QuickBEAM runtimes              ║
║  LLM calls via Beam.call → pluggable Elixir backend  ║
╚══════════════════════════════════════════════════════╝
""")

agent_id = "demo"

IO.puts("Creating agent...")
{:ok, _} = AIAgent.Agent.configure(agent_id, "You are a helpful assistant.")

IO.puts("\n--- Basic chat ---")
{:ok, reply} = AIAgent.Agent.chat(agent_id, "What is Elixir?")
IO.puts("Assistant: #{reply["content"]}")

IO.puts("\n--- Streaming ---")
{:ok, _pid} = AIAgent.Agent.start_link("stream-demo", subscriber: self())
{:ok, _reply} = AIAgent.Agent.chat_stream("stream-demo", "Tell me about BEAM")

receive_loop = fn receive_loop ->
  receive do
    {:agent_chunk, _, %{"delta" => delta}} ->
      IO.write(delta)
      receive_loop.(receive_loop)
    {:agent_done, _, _} ->
      IO.puts("\n(stream complete)")
    {:agent_status, _, _} ->
      receive_loop.(receive_loop)
  after
    2000 -> IO.puts("\n(timeout)")
  end
end

receive_loop.(receive_loop)

IO.puts("\n--- Tool use ---")
tools = %{
  "get_weather" => fn %{"city" => city} ->
    IO.puts("  [tool] Fetching weather for #{city}...")
    %{"temp" => 18, "condition" => "cloudy", "city" => city}
  end
}

{:ok, _pid} = AIAgent.Agent.start_link("tool-demo", tools: tools)
{:ok, reply} = AIAgent.Agent.chat_with_tools("tool-demo", "What's the weather in London?")
IO.puts("Assistant: #{reply["content"]}")

IO.puts("\n--- History ---")
{:ok, history} = AIAgent.Agent.get_history(agent_id)
IO.puts("#{length(history)} messages in conversation")

for msg <- history do
  IO.puts("  #{msg["role"]}: #{String.slice(msg["content"], 0..60)}...")
end
