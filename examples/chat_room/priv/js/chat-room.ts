interface Message {
  sender: string
  text: string
  timestamp: number
}

const state = {
  messages: [] as Message[],
}

function sendMessage(sender: string, text: string): Message {
  const message = { sender, text, timestamp: Date.now() }
  state.messages.push(message)
  Beam.callSync('broadcast', message)
  return message
}

function getHistory(): Message[] {
  return state.messages
}

function getState() {
  return { messageCount: state.messages.length }
}
