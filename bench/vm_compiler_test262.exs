if is_nil(System.get_env("QUICKBEAM_COMPILER_CACHE")) do
  System.put_env("QUICKBEAM_COMPILER_CACHE", "1")
end

Mix.Task.run("app.start")

unless Code.ensure_loaded?(QuickBEAM.Test262) do
  Code.require_file("../test/support/test262.ex", __DIR__)
end

categories = ~w(
  language/expressions/addition
  language/expressions/subtraction
  language/expressions/multiplication
  language/expressions/division
  language/expressions/modulus
  language/expressions/typeof
  language/expressions/void
  language/expressions/comma
  language/expressions/conditional
  language/expressions/logical-and
  language/expressions/logical-or
  language/expressions/logical-not
  language/expressions/equals
  language/expressions/does-not-equals
  language/expressions/strict-equals
  language/expressions/strict-does-not-equal
  language/expressions/greater-than
  language/expressions/greater-than-or-equal
  language/expressions/less-than
  language/expressions/less-than-or-equal
  language/expressions/bitwise-and
  language/expressions/bitwise-or
  language/expressions/bitwise-xor
  language/expressions/bitwise-not
  language/expressions/left-shift
  language/expressions/right-shift
  language/expressions/unsigned-right-shift
  language/expressions/in
  language/expressions/instanceof
  language/expressions/new
  language/expressions/this
  language/expressions/delete
  language/expressions/prefix-increment
  language/expressions/prefix-decrement
  language/expressions/postfix-increment
  language/expressions/postfix-decrement
  language/expressions/unary-minus
  language/expressions/unary-plus
  language/statements/if
  language/statements/return
  language/statements/switch
  language/statements/throw
  language/statements/try
  language/statements/do-while
  language/statements/while
  language/statements/for
  language/statements/for-in
  language/statements/break
  language/statements/continue
  language/statements/block
  language/statements/empty
  language/statements/labeled
  language/statements/with
)

selected_categories =
  case System.get_env("TEST262_CATEGORY") do
    nil -> categories
    value -> String.split(value, ",", trim: true)
  end

limit =
  case System.get_env("TEST262_LIMIT") do
    nil -> :infinity
    value -> String.to_integer(value)
  end

offset =
  case System.get_env("TEST262_OFFSET") do
    nil -> 0
    value -> String.to_integer(value)
  end

skip_list =
  if QuickBEAM.Test262.available?(), do: QuickBEAM.Test262.load_skip_list(), else: MapSet.new()

cases =
  if QuickBEAM.Test262.available?() do
    selected_categories
    |> Enum.flat_map(fn category ->
      category
      |> QuickBEAM.Test262.find_tests()
      |> Enum.map(fn file -> {category, file} end)
    end)
    |> Enum.reduce([], fn {category, file}, acc ->
      source = File.read!(file)
      relative = QuickBEAM.Test262.relative_path(file)
      meta = QuickBEAM.Test262.parse_metadata(source)
      flags = Map.get(meta, "flags", [])

      cond do
        "async" in flags -> acc
        "module" in flags -> acc
        MapSet.member?(skip_list, relative) -> acc
        true -> [{category, file, source, relative, meta} | acc]
      end
    end)
    |> Enum.reverse()
  else
    []
  end

cases = Enum.drop(cases, offset)
cases = if limit == :infinity, do: cases, else: Enum.take(cases, limit)

js_error? = fn
  {:error, %QuickBEAM.JS.Error{}} -> true
  {:error, {:js_throw, _}} -> true
  _ -> false
end

compiler_error? = fn
  {:error, {:beam_compiler_unsupported, _}} -> true
  {:error, {:beam_compiler_error, _}} -> true
  _ -> false
end

case_timeout = String.to_integer(System.get_env("TEST262_CASE_TIMEOUT", "5000"))
use_context_pool? = System.get_env("TEST262_CONTEXT_POOL", "1") not in ["0", "false", "FALSE"]

pooled_contexts =
  if use_context_pool? do
    for mode <- [:beam, :beam_compiler], into: %{} do
      {:ok, pool} = QuickBEAM.ContextPool.start_link(size: 1, mode: mode)
      {:ok, context} = QuickBEAM.Context.start_link(pool: pool, apis: false)
      {mode, {pool, context}}
    end
  else
    %{}
  end

run_raw_case = fn full, mode ->
  if use_context_pool? do
    {_pool, context} = Map.fetch!(pooled_contexts, mode)

    try do
      QuickBEAM.Context.eval(context, full, timeout: case_timeout)
    after
      QuickBEAM.Context.reset(context)
    end
  else
    {:ok, rt} = QuickBEAM.start(apis: false)

    try do
      QuickBEAM.eval(rt, full, mode: mode)
    after
      QuickBEAM.stop(rt)
    end
  end
end

run_case = fn source, meta, mode ->
  includes = Map.get(meta, "includes", [])
  flags = Map.get(meta, "flags", [])
  negative? = meta["negative"] != nil
  strict_prefix = if "onlyStrict" in flags, do: "\"use strict\";\n", else: ""
  full = strict_prefix <> QuickBEAM.Test262.harness_source(includes) <> "\n" <> source

  raw =
    try do
      task =
        Task.async(fn ->
          try do
            run_raw_case.(full, mode)
          rescue
            error -> {:crash, {:error, error, __STACKTRACE__}}
          catch
            kind, reason -> {:crash, {kind, reason, __STACKTRACE__}}
          end
        end)

      Task.await(task, case_timeout + 1_000)
    catch
      kind, reason -> {:crash, {kind, reason, __STACKTRACE__}}
    end

  cond do
    match?({:crash, _}, raw) ->
      {:crash, raw}

    compiler_error?.(raw) ->
      {:compiler_error, raw}

    negative? and js_error?.(raw) ->
      {:pass, raw}

    negative? ->
      {:fail, raw}

    match?({:ok, _}, raw) ->
      {:pass, raw}

    true ->
      {:fail, raw}
  end
end

results =
  Enum.map(cases, fn {_category, _file, source, relative, meta} ->
    interpreter = run_case.(source, meta, :beam)
    compiler = run_case.(source, meta, :beam_compiler)

    status =
      case {interpreter, compiler} do
        {{:pass, _}, {:pass, _}} -> :pass
        {{:pass, _}, {:compiler_error, _}} -> :compiler_error
        {{:pass, _}, {:crash, _}} -> :compiler_crash
        {{:pass, _}, {:fail, _}} -> :compiler_fail
        {{:fail, _}, {:pass, _}} -> :interpreter_fail_compiler_pass
        {{:fail, _}, {:fail, _}} -> :both_fail
        {{:compiler_error, _}, _} -> :interpreter_infra_error
        {{:crash, _}, _} -> :interpreter_crash
        _ -> :mismatch
      end

    %{relative: relative, status: status, interpreter: interpreter, compiler: compiler}
  end)

summary = Enum.frequencies_by(results, & &1.status)
count = fn status -> Map.get(summary, status, 0) end
failures = Enum.reject(results, &(&1.status == :pass))

IO.puts(
  "compiler_test262_cases=#{length(results)} compiler_test262_pass=#{count.(:pass)} compiler_test262_failures=#{length(failures)} compiler_test262_compiler_errors=#{count.(:compiler_error)} compiler_test262_compiler_crashes=#{count.(:compiler_crash)} compiler_test262_compiler_fails=#{count.(:compiler_fail)} compiler_test262_both_fail=#{count.(:both_fail)} compiler_test262_interpreter_fail_compiler_pass=#{count.(:interpreter_fail_compiler_pass)}"
)

for result <- Enum.take(failures, String.to_integer(System.get_env("TEST262_ERROR_LIMIT", "40"))) do
  IO.puts("COMPILER_TEST262_#{String.upcase(to_string(result.status))} #{result.relative}")
  IO.puts("  interpreter=#{inspect(result.interpreter, limit: 80)}")
  IO.puts("  compiler=#{inspect(result.compiler, limit: 80)}")
end

IO.puts("METRIC compiler_test262_cases=#{length(results)}")
IO.puts("METRIC compiler_test262_pass=#{count.(:pass)}")
IO.puts("METRIC compiler_test262_failures=#{length(failures)}")
IO.puts("METRIC compiler_test262_compiler_errors=#{count.(:compiler_error)}")
IO.puts("METRIC compiler_test262_compiler_crashes=#{count.(:compiler_crash)}")
IO.puts("METRIC compiler_test262_compiler_fails=#{count.(:compiler_fail)}")
IO.puts("METRIC compiler_test262_both_fail=#{count.(:both_fail)}")

IO.puts(
  "METRIC compiler_test262_interpreter_fail_compiler_pass=#{count.(:interpreter_fail_compiler_pass)}"
)

for {_mode, {pool, context}} <- pooled_contexts do
  QuickBEAM.Context.stop(context)
  GenServer.stop(pool)
end
