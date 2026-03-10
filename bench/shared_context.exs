# Benchmark 6: Shared context — preloaded function calls
#
# The typical usage pattern: load JS once, call functions many times.
# Shows the per-call cost after initialization is paid.

{:ok, qb} = QuickBEAM.start()
{:ok, qjs} = QuickJSEx.start()

setup = """
const state = { count: 0, items: [] };

function increment(n) {
  state.count += n;
  return state.count;
}

function add_item(item) {
  state.items.push(item);
  return state.items.length;
}

function get_state() {
  return { count: state.count, total_items: state.items.length };
}

function process_batch(users) {
  return users.map(u => ({
    id: u.id,
    display: u.first + " " + u.last,
    active: u.age >= 18
  }));
}
"""

{:ok, _} = QuickBEAM.eval(qb, setup)
{:ok, _} = QuickJSEx.eval(qjs, setup)

users = for i <- 1..50, do: %{"id" => i, "first" => "User", "last" => "#{i}", "age" => 10 + i}

Benchee.run(
  %{
    "QuickBEAM — call (no args)" => fn -> {:ok, _} = QuickBEAM.call(qb, "get_state", []) end,
    "QuickJSEx — call (no args)" => fn -> {:ok, _} = QuickJSEx.call(qjs, "get_state", []) end,
    "QuickBEAM — call (scalar)" => fn -> {:ok, _} = QuickBEAM.call(qb, "increment", [1]) end,
    "QuickJSEx — call (scalar)" => fn -> {:ok, _} = QuickJSEx.call(qjs, "increment", [1]) end,
    "QuickBEAM — call (50 objects)" => fn -> {:ok, _} = QuickBEAM.call(qb, "process_batch", [users]) end,
    "QuickJSEx — call (50 objects)" => fn -> {:ok, _} = QuickJSEx.call(qjs, "process_batch", [users]) end
  },
  warmup: 2,
  time: 5,
  memory_time: 2,
  print: [configuration: false]
)

QuickBEAM.stop(qb)
QuickJSEx.stop(qjs)
