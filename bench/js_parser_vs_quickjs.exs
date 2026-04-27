cases = [
  {"empty", ""},
  {"small_expression", "let value = 1 + 2 * 3; value++;"},
  {"function_control", "function fib(n) { if (n <= 1) return n; return fib(n - 1) + fib(n - 2); } for (let i = 0; i < 10; i++) fib(i);"},
  {"class_private", "class Base { f() { return 1; } } class Derived extends Base { #x = 1; constructor() { super(); this.#x++; } get value() { return super.f() + this.#x; } }"},
  {"test_language", File.read!("test/vm/test_language.js")}
]

{:ok, rt} = QuickBEAM.start(mode: :native, web: false)

parse_elixir = fn source ->
  case QuickBEAM.JS.Parser.parse(source) do
    {:ok, _ast} -> :ok
    {:error, _ast, _errors} -> :error
  end
end

compile_quickjs = fn source ->
  case QuickBEAM.compile(rt, source) do
    {:ok, _bytecode} -> :ok
    {:error, _error} -> :error
  end
end

measure = fn fun, source, iterations ->
  for _ <- 1..3, do: fun.(source)
  :erlang.garbage_collect()

  samples =
    for _ <- 1..9 do
      {us, statuses} = :timer.tc(fn -> for _ <- 1..iterations, do: fun.(source) end)
      {us / iterations, Enum.frequencies(statuses)}
    end

  per_iter = samples |> Enum.map(&elem(&1, 0)) |> Enum.sort()
  median = Enum.at(per_iter, div(length(per_iter), 2))
  status = samples |> List.last() |> elem(1)
  {median, status}
end

IO.puts("case,bytes,iterations,elixir_parser_median_us,quickjs_compile_median_us,ratio_qjs_over_elixir,elixir_status,quickjs_status")

results =
  for {name, source} <- cases do
    iterations =
      cond do
        byte_size(source) == 0 -> 10_000
        byte_size(source) < 1_000 -> 5_000
        byte_size(source) < 10_000 -> 500
        true -> 10
      end

    {elixir_median, elixir_status} = measure.(parse_elixir, source, iterations)
    {quickjs_median, quickjs_status} = measure.(compile_quickjs, source, iterations)
    ratio = quickjs_median / max(elixir_median, 0.001)

    IO.puts(
      [
        name,
        Integer.to_string(byte_size(source)),
        Integer.to_string(iterations),
        :erlang.float_to_binary(elixir_median, decimals: 2),
        :erlang.float_to_binary(quickjs_median, decimals: 2),
        :erlang.float_to_binary(ratio, decimals: 2),
        inspect(elixir_status),
        inspect(quickjs_status)
      ]
      |> Enum.join(",")
    )

    {name, elixir_median, quickjs_median}
  end

test_language_us = results |> Enum.find(&(elem(&1, 0) == "test_language")) |> elem(1)
class_private_us = results |> Enum.find(&(elem(&1, 0) == "class_private")) |> elem(1)
function_control_us = results |> Enum.find(&(elem(&1, 0) == "function_control")) |> elem(1)

IO.puts("METRIC test_language_parser_us=#{round(test_language_us)}")
IO.puts("METRIC class_private_parser_us=#{round(class_private_us)}")
IO.puts("METRIC function_control_parser_us=#{round(function_control_us)}")
