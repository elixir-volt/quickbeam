defmodule Bench.Support do
  @moduledoc false

  def start_app, do: Mix.Task.run("app.start")

  def env_integer(name, default) do
    case System.get_env(name) do
      nil -> default
      "" -> default
      value -> String.to_integer(value)
    end
  end

  def metric(name, value), do: IO.puts("METRIC #{name}=#{value}")

  def metrics(pairs) do
    Enum.each(pairs, fn {name, value} -> metric(name, value) end)
  end

  def format_float(value, decimals \\ 2), do: :erlang.float_to_binary(value, decimals: decimals)

  def benchee_options(defaults \\ []) do
    Keyword.merge(
      [
        warmup: env_integer("BENCH_WARMUP", 2),
        time: env_integer("BENCH_TIME", 5),
        memory_time: env_integer("BENCH_MEMORY_TIME", 2),
        print: [configuration: false]
      ],
      defaults
    )
  end

  def average_us(fun, iterations) when iterations > 0 do
    {elapsed_us, _result} = :timer.tc(fn -> Enum.each(1..iterations, fn _ -> fun.() end) end)
    elapsed_us / iterations
  end
end
