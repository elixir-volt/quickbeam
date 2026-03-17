# AI Agent

Conversational AI agent with streaming, tool use, and pluggable LLM backends — all orchestrated by a QuickBEAM runtime.

## Architecture

```
  Elixir caller
       │
       ▼
  ┌──────────────────────────────────────────────────┐
  │  DynamicSupervisor + Registry                    │
  │  ┌──────────────┐  ┌──────────────┐             │
  │  │ Agent "alice" │  │ Agent "bob"  │  ...        │
  │  │ (QuickBEAM)  │  │ (QuickBEAM)  │             │
  │  └──────┬───────┘  └──────────────┘             │
  └─────────┼───────────────────────────────────────┘
            │
  ┌─────────▼───────────────────────────────────────┐
  │     QuickJS context                              │
  │                                                  │
  │  state.messages = [{role, content, id}, ...]     │
  │  state.status = "idle" | "thinking" | "error"    │
  │                                                  │
  │  chat(msg)                                       │
  │    └→ Beam.call("llm_complete", prompt)          │
  │         → Elixir calls OpenAI / Anthropic / etc  │
  │                                                  │
  │  chatStream(msg)                                 │
  │    └→ Beam.call("llm_stream", prompt)            │
  │         → returns chunks                         │
  │         → Beam.callSync("stream_chunk", delta)   │
  │              → send(subscriber, {:agent_chunk})   │
  │                                                  │
  │  chatWithTools(msg)                              │
  │    └→ Beam.call("llm_complete_with_tools", prompt)
  │    └→ Beam.call("tool_call", name, args)         │
  │         → Elixir executes tool                   │
  │    └→ loop until text response                   │
  └──────────────────────────────────────────────────┘
```

## How it works

1. **Agent per runtime** — each agent is a QuickBEAM runtime with its own conversation history in JS memory.
2. **JS orchestrates the loop** — the conversation state machine (user → LLM → tools → LLM → response) lives in TypeScript.
3. **Elixir provides the I/O** — LLM calls, tool execution, and streaming delivery are all Elixir functions injected via handlers.
4. **Pluggable backends** — swap `llm:` option to use OpenAI, Anthropic, Ollama, or any Elixir HTTP client.
5. **Streaming via messages** — chunks are delivered to a subscriber process via `send/2`, fitting naturally into GenServer / LiveView / Channel patterns.
6. **Tool use** — JS calls `Beam.call("tool_call", name, args)` → Elixir dispatches to the registered tool function → result feeds back into the conversation.

## Usage

```elixir
# Basic chat
{:ok, reply} = AIAgent.Agent.chat("my-agent", "What is Elixir?")
reply["content"]  #=> "Elixir is a dynamic, functional language..."

# With a real LLM
{:ok, _} = AIAgent.Agent.start_link("my-agent",
  llm: fn %{"system" => sys, "messages" => msgs} ->
    Req.post!("https://api.openai.com/v1/chat/completions",
      json: %{model: "gpt-4o-mini", messages: [%{role: "system", content: sys} | msgs]},
      headers: [{"authorization", "Bearer #{api_key}"}]
    ).body["choices"] |> hd() |> get_in(["message", "content"])
  end
)

# Streaming with subscriber
{:ok, _} = AIAgent.Agent.start_link("stream-agent", subscriber: self())
AIAgent.Agent.chat_stream("stream-agent", "Tell me a story")
# Receive: {:agent_chunk, "stream-agent", %{"delta" => "Once...", ...}}
# Receive: {:agent_done, "stream-agent", %{"content" => "Once upon..."}}

# Tool use
{:ok, _} = AIAgent.Agent.start_link("tool-agent",
  tools: %{
    "search" => fn %{"query" => q} -> MyApp.Search.run(q) end,
    "get_weather" => fn %{"city" => c} -> WeatherAPI.fetch(c) end
  }
)
AIAgent.Agent.chat_with_tools("tool-agent", "Search for Elixir tutorials")
```

## Run

```sh
mix deps.get
mix run run.exs
```

## Test

```sh
mix test
```

## Key features demonstrated

- **Pluggable LLM** — inject any Elixir function as the completion backend
- **Streaming** — chunks delivered via BEAM messages, subscriber pattern
- **Tool use** — multi-round tool calling loop managed in JS
- **Conversation memory** — full history in JS state, survives across calls
- **Actor-per-agent** — separate runtimes via Registry + DynamicSupervisor
- **Status tracking** — idle/thinking/error state machine with notifications
