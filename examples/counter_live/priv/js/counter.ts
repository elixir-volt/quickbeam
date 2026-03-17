const state = { count: 0 }

function increment(amount: number = 1): number {
  state.count += amount
  return state.count
}

function decrement(amount: number = 1): number {
  state.count -= amount
  return state.count
}

function reset(): number {
  state.count = 0
  return state.count
}

function getCount(): number {
  return state.count
}
