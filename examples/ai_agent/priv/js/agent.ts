interface Message {
  id: string
  role: 'user' | 'assistant' | 'system'
  content: string
  timestamp: number
}

interface ToolCall {
  name: string
  args: Record<string, unknown>
}

interface ToolResult {
  name: string
  result: unknown
}

const state = {
  messages: [] as Message[],
  status: 'idle' as 'idle' | 'thinking' | 'error',
  systemPrompt: 'You are a helpful assistant. Be concise.',
}

function configure(systemPrompt: string) {
  state.systemPrompt = systemPrompt
}

async function chat(userMessage: string): Promise<Message> {
  const userMsg: Message = {
    id: Beam.randomUUIDv7(),
    role: 'user',
    content: userMessage,
    timestamp: Date.now(),
  }
  state.messages.push(userMsg)

  state.status = 'thinking'
  Beam.callSync('status_changed', state.status)

  try {
    const response = await Beam.call('llm_complete', buildPrompt()) as string

    const assistantMsg: Message = {
      id: Beam.randomUUIDv7(),
      role: 'assistant',
      content: response,
      timestamp: Date.now(),
    }
    state.messages.push(assistantMsg)

    state.status = 'idle'
    Beam.callSync('status_changed', state.status)

    return assistantMsg
  } catch (error) {
    state.status = 'error'
    Beam.callSync('status_changed', state.status)
    throw error
  }
}

async function chatStream(userMessage: string): Promise<Message> {
  const userMsg: Message = {
    id: Beam.randomUUIDv7(),
    role: 'user',
    content: userMessage,
    timestamp: Date.now(),
  }
  state.messages.push(userMsg)

  const assistantMsg: Message = {
    id: Beam.randomUUIDv7(),
    role: 'assistant',
    content: '',
    timestamp: Date.now(),
  }
  state.messages.push(assistantMsg)

  state.status = 'thinking'
  Beam.callSync('status_changed', state.status)

  try {
    const chunks = await Beam.call('llm_stream', buildPrompt()) as string[]

    for (const chunk of chunks) {
      assistantMsg.content += chunk
      Beam.callSync('stream_chunk', { id: assistantMsg.id, delta: chunk, content: assistantMsg.content })
    }

    Beam.callSync('stream_done', { id: assistantMsg.id, content: assistantMsg.content })

    state.status = 'idle'
    Beam.callSync('status_changed', state.status)

    return assistantMsg
  } catch (error) {
    state.status = 'error'
    Beam.callSync('status_changed', state.status)
    throw error
  }
}

async function chatWithTools(userMessage: string): Promise<Message> {
  const userMsg: Message = {
    id: Beam.randomUUIDv7(),
    role: 'user',
    content: userMessage,
    timestamp: Date.now(),
  }
  state.messages.push(userMsg)

  state.status = 'thinking'
  Beam.callSync('status_changed', state.status)

  try {
    const maxRounds = 5
    let lastResponse = ''

    for (let round = 0; round < maxRounds; round++) {
      const result = await Beam.call('llm_complete_with_tools', buildPrompt()) as
        | { type: 'text', content: string }
        | { type: 'tool_calls', calls: ToolCall[] }

      if (result.type === 'text') {
        lastResponse = result.content
        break
      }

      const toolResults: ToolResult[] = []
      for (const call of result.calls) {
        const toolResult = await Beam.call('tool_call', call.name, call.args)
        toolResults.push({ name: call.name, result: toolResult })
      }

      state.messages.push({
        id: Beam.randomUUIDv7(),
        role: 'system',
        content: `Tool results: ${JSON.stringify(toolResults)}`,
        timestamp: Date.now(),
      })
    }

    const assistantMsg: Message = {
      id: Beam.randomUUIDv7(),
      role: 'assistant',
      content: lastResponse,
      timestamp: Date.now(),
    }
    state.messages.push(assistantMsg)

    state.status = 'idle'
    Beam.callSync('status_changed', state.status)

    return assistantMsg
  } catch (error) {
    state.status = 'error'
    Beam.callSync('status_changed', state.status)
    throw error
  }
}

function getHistory(): Message[] {
  return state.messages
}

function getStatus() {
  return { status: state.status, messageCount: state.messages.length }
}

function clearHistory() {
  state.messages = []
  state.status = 'idle'
}

function buildPrompt(): { system: string, messages: { role: string, content: string }[] } {
  return {
    system: state.systemPrompt,
    messages: state.messages.map(m => ({ role: m.role, content: m.content })),
  }
}
