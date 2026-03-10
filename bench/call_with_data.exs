# Benchmark 2: Function call with data serialization
#
# Call a JS function with structured arguments, get structured result.
# Measures: argument conversion + JS call + result conversion.
# QuickBEAM uses native term bridge, QuickJSEx uses JSON.

{:ok, qb} = QuickBEAM.start()
{:ok, qjs} = QuickJSEx.start()

setup = """
function transform(user) {
  return {
    full_name: user.first + " " + user.last,
    age_next_year: user.age + 1,
    tags: user.tags.map(t => t.toUpperCase()),
    active: user.active
  };
}

function identity(x) { return x; }
"""

{:ok, _} = QuickBEAM.eval(qb, setup)
{:ok, _} = QuickJSEx.eval(qjs, setup)

small = %{"first" => "Alice", "last" => "Smith", "age" => 30, "active" => true, "tags" => ["elixir", "js"]}

medium =
  for i <- 1..20, into: %{} do
    {"key_#{i}", %{"value" => i, "label" => "item #{i}", "nested" => %{"flag" => rem(i, 2) == 0}}}
  end

large =
  for i <- 1..100 do
    %{"id" => i, "name" => "User #{i}", "email" => "user#{i}@example.com", "scores" => Enum.to_list(1..10)}
  end

Benchee.run(
  %{
    "QuickBEAM — small map" => fn -> {:ok, _} = QuickBEAM.call(qb, "transform", [small]) end,
    "QuickJSEx — small map" => fn -> {:ok, _} = QuickJSEx.call(qjs, "transform", [small]) end,
    "QuickBEAM — medium map (20 keys)" => fn -> {:ok, _} = QuickBEAM.call(qb, "identity", [medium]) end,
    "QuickJSEx — medium map (20 keys)" => fn -> {:ok, _} = QuickJSEx.call(qjs, "identity", [medium]) end,
    "QuickBEAM — large array (100 objects)" => fn -> {:ok, _} = QuickBEAM.call(qb, "identity", [large]) end,
    "QuickJSEx — large array (100 objects)" => fn -> {:ok, _} = QuickJSEx.call(qjs, "identity", [large]) end
  },
  warmup: 2,
  time: 5,
  memory_time: 2,
  print: [configuration: false]
)

QuickBEAM.stop(qb)
QuickJSEx.stop(qjs)
