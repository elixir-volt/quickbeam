# Chat Room

Real-time chat with Phoenix Channels, where each room is a supervised QuickBEAM runtime.

## Architecture

```
  Browser A ──┐                              ┌── Browser B
  (WebSocket) │                              │ (WebSocket)
              ▼                              ▼
        ┌──────────────────────────────────────┐
        │          Phoenix.Endpoint             │
        │   Socket → Channel ("room:general")   │
        └──────────────┬───────────────────────┘
                       │
          Phoenix.PubSub ("room:general")
                       │
        ┌──────────────▼───────────────────────┐
        │      DynamicSupervisor               │
        │  ┌──────────┐  ┌──────────┐          │
        │  │ Room      │  │ Room      │  ...    │
        │  │ "general" │  │ "random"  │         │
        │  │ (QuickBEAM│  │ (QuickBEAM│         │
        │  │  runtime) │  │  runtime) │         │
        │  └─────┬─────┘  └──────────┘         │
        └────────┼─────────────────────────────┘
                 │
        ┌────────▼─────────────────────────────┐
        │     QuickJS context                   │
        │  state.messages = [...]               │
        │  BroadcastChannel("chat")             │
        │     │                                 │
        │     └→ Beam.callSync("broadcast", msg)│
        │          → Phoenix.PubSub.broadcast!  │
        └──────────────────────────────────────┘
```

## How it works

1. **Room per runtime** — each chat room is a QuickBEAM runtime registered via `Registry`, supervised by `DynamicSupervisor`. Created on first message (lazy).
2. **JS manages state** — message history lives in the JS context as a plain array. No external database.
3. **BroadcastChannel → PubSub** — when JS calls `channel.postMessage(msg)`, the `BroadcastChannel` (backed by `:pg`) triggers a handler that calls `Phoenix.PubSub.broadcast!`. All subscribed Phoenix Channels push the message to their WebSocket clients.
4. **Phoenix Channels** — clients connect via WebSocket, join `room:<id>`, receive history on join, and get live updates via PubSub.
5. **Crash recovery** — kill a room's process and it's cleaned up (transient restart). Next message to that room starts a fresh runtime.

## Run

```sh
mix deps.get
mix run run.exs
```

Open http://localhost:4000 in multiple browser tabs.

## Test

```sh
mix test
```

## Key features demonstrated

- **Actor-per-entity** — one QuickBEAM runtime per room via Registry + DynamicSupervisor
- **BroadcastChannel → Phoenix.PubSub** — JS broadcasts become real-time WebSocket pushes
- **Phoenix Channels** — standard Phoenix real-time integration
- **Lazy creation** — rooms start on first use, no pre-provisioning
- **OTP supervision** — rooms are supervised, crash recovery is automatic
- **Zero database** — state lives in JS memory (add persistence via `Beam.call` handlers if needed)
