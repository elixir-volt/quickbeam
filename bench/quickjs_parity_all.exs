Mix.Task.run("app.start")

unless Code.ensure_loaded?(QuickBEAM.Test262) do
  Code.require_file("../test/support/test262.ex", __DIR__)
end

root = Path.join(QuickBEAM.Test262.root(), "test")

selected_categories =
  case System.get_env("TEST262_CATEGORY") do
    nil -> :all
    "" -> :all
    "all" -> :all
    value -> String.split(value, ",", trim: true)
  end

limit =
  case System.get_env("TEST262_LIMIT") do
    nil -> :infinity
    value -> String.to_integer(value)
  end

offset = String.to_integer(System.get_env("TEST262_OFFSET", "0"))

error_limit = String.to_integer(System.get_env("TEST262_ERROR_LIMIT", "40"))
case_timeout = String.to_integer(System.get_env("TEST262_CASE_TIMEOUT", "5000"))
progress_every = String.to_integer(System.get_env("TEST262_PROGRESS_EVERY", "0"))
slow_ms = String.to_integer(System.get_env("TEST262_SLOW_MS", "0"))
use_context_pool? = System.get_env("TEST262_CONTEXT_POOL", "1") not in ["0", "false", "FALSE"]
use_beam_direct? = System.get_env("TEST262_BEAM_DIRECT", "1") not in ["0", "false", "FALSE"]

if System.get_env("TEST262_COMPILER_CACHE", "1") not in ["0", "false", "FALSE"] do
  System.put_env("QUICKBEAM_COMPILER_CACHE", "1")
end

files =
  case selected_categories do
    :all ->
      Path.join([root, "**/*.js"])
      |> Path.wildcard()

    categories ->
      Enum.flat_map(categories, &QuickBEAM.Test262.find_tests/1)
  end
  |> Enum.reject(&String.contains?(&1, "_FIXTURE"))
  |> Enum.sort()

files = Enum.drop(files, offset)
files = if limit == :infinity, do: files, else: Enum.take(files, limit)

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

beam_runtimes =
  if use_beam_direct? do
    for mode <- [:beam, :beam_compiler], into: %{} do
      {:ok, runtime} = QuickBEAM.start(apis: false, mode: mode)
      {mode, runtime}
    end
  else
    %{}
  end

pooled_contexts =
  if use_context_pool? do
    pool_modes = if use_beam_direct?, do: [:native], else: [:native, :beam, :beam_compiler]

    for mode <- pool_modes, into: %{} do
      pool_mode = if mode == :native, do: :nif, else: mode
      {:ok, pool} = QuickBEAM.ContextPool.start_link(size: 1, mode: pool_mode)
      {:ok, context} = QuickBEAM.Context.start_link(pool: pool, apis: false)
      {mode, {pool, context}}
    end
  else
    %{}
  end

run_raw_case = fn full, mode ->
  cond do
    use_beam_direct? and mode in [:beam, :beam_compiler] ->
      runtime = Map.fetch!(beam_runtimes, mode)

      try do
        QuickBEAM.eval(runtime, full, mode: mode, timeout: case_timeout)
      after
        QuickBEAM.VM.Heap.reset()
        QuickBEAM.reset(runtime)
      end

    use_context_pool? ->
      {_pool, context} = Map.fetch!(pooled_contexts, mode)

      try do
        QuickBEAM.Context.eval(context, full, timeout: case_timeout)
      after
        QuickBEAM.Context.reset(context)
      end

    true ->
      {:ok, rt} = QuickBEAM.start(apis: false)

      try do
        case mode do
          :native -> QuickBEAM.eval(rt, full)
          mode -> QuickBEAM.eval(rt, full, mode: mode)
        end
      after
        QuickBEAM.stop(rt)
      end
  end
end

run_with_timeout = fn fun ->
  task =
    Task.async(fn ->
      try do
        fun.()
      rescue
        error -> {:crash, {:error, error, __STACKTRACE__}}
      catch
        kind, reason -> {:crash, {kind, reason, __STACKTRACE__}}
      end
    end)

  case Task.yield(task, case_timeout + 1_000) || Task.shutdown(task, :brutal_kill) do
    {:ok, result} -> result
    nil -> {:timeout, case_timeout}
  end
end

run_case = fn source, meta, mode ->
  includes = Map.get(meta, "includes", [])
  flags = Map.get(meta, "flags", [])
  negative? = meta["negative"] != nil
  strict_prefix = if "onlyStrict" in flags, do: "\"use strict\";\n", else: ""
  full = strict_prefix <> QuickBEAM.Test262.harness_source(includes) <> "\n" <> source

  raw = run_with_timeout.(fn -> run_raw_case.(full, mode) end)

  cond do
    match?({:timeout, _}, raw) ->
      {:timeout, raw}

    match?({:crash, _}, raw) ->
      {:crash, raw}

    mode == :beam_compiler and compiler_error?.(raw) ->
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

skipped? = fn meta ->
  flags = Map.get(meta, "flags", [])
  "async" in flags or "module" in flags
end

initial = %{
  seen: 0,
  summary: %{},
  failures: []
}

record = fn status, acc ->
  %{acc | seen: acc.seen + 1, summary: Map.update(acc.summary, status, 1, &(&1 + 1))}
end

record_result = fn result, acc ->
  acc = record.(result.status, acc)

  if result.status not in [:pass, :native_rejected, :skipped] and
       length(acc.failures) < error_limit do
    %{acc | failures: [result | acc.failures]}
  else
    acc
  end
end

acc =
  Enum.reduce(files, initial, fn file, acc ->
    if progress_every > 0 and acc.seen > 0 and rem(acc.seen, progress_every) == 0 do
      IO.puts("PROGRESS quickjs_parity_all_seen=#{acc.seen}/#{length(files)}")
    end

    started_at = System.monotonic_time(:millisecond)
    source = File.read!(file)
    meta = QuickBEAM.Test262.parse_metadata(source)
    relative = QuickBEAM.Test262.relative_path(file)

    result =
      if skipped?.(meta) do
        %{
          relative: relative,
          status: :skipped,
          native: :skipped,
          interpreter: :skipped,
          compiler: :skipped
        }
      else
        native = run_case.(source, meta, :native)

        if match?({:pass, _}, native) do
          interpreter = run_case.(source, meta, :beam)
          compiler = run_case.(source, meta, :beam_compiler)

          status =
            case {interpreter, compiler} do
              {{:pass, _}, {:pass, _}} -> :pass
              {{:pass, _}, {:compiler_error, _}} -> :compiler_error
              {{:pass, _}, {:timeout, _}} -> :compiler_timeout
              {{:pass, _}, {:crash, _}} -> :compiler_crash
              {{:pass, _}, {:fail, _}} -> :compiler_fail
              {{:fail, _}, {:pass, _}} -> :interpreter_fail_compiler_pass
              {{:fail, _}, {:fail, _}} -> :both_fail
              {{:timeout, _}, _} -> :interpreter_timeout
              {{:crash, _}, _} -> :interpreter_crash
              {{:compiler_error, _}, _} -> :interpreter_infra_error
              _ -> :mismatch
            end

          %{
            relative: relative,
            status: status,
            native: native,
            interpreter: interpreter,
            compiler: compiler
          }
        else
          %{
            relative: relative,
            status: :native_rejected,
            native: native,
            interpreter: :not_run,
            compiler: :not_run
          }
        end
      end

    elapsed_ms = System.monotonic_time(:millisecond) - started_at

    if slow_ms > 0 and elapsed_ms >= slow_ms do
      IO.puts("SLOW quickjs_parity_all_case_ms=#{elapsed_ms} #{relative}")
    end

    record_result.(result, acc)
  end)

summary = acc.summary
count = fn status -> Map.get(summary, status, 0) end
accepted = acc.seen - count.(:native_rejected) - count.(:skipped)
failures = accepted - count.(:pass)

IO.puts(
  "quickjs_parity_all_cases=#{acc.seen} quickjs_parity_all_native_accepted=#{accepted} quickjs_parity_all_pass=#{count.(:pass)} quickjs_parity_all_failures=#{failures} quickjs_parity_all_native_rejected=#{count.(:native_rejected)} quickjs_parity_all_skipped=#{count.(:skipped)}"
)

for result <- Enum.reverse(acc.failures) do
  IO.puts("QUICKJS_PARITY_ALL_#{String.upcase(to_string(result.status))} #{result.relative}")
  IO.puts("  native=#{inspect(result.native, limit: 80)}")
  IO.puts("  interpreter=#{inspect(result.interpreter, limit: 80)}")
  IO.puts("  compiler=#{inspect(result.compiler, limit: 80)}")
end

IO.puts("METRIC quickjs_parity_all_cases=#{acc.seen}")
IO.puts("METRIC quickjs_parity_all_native_accepted=#{accepted}")
IO.puts("METRIC quickjs_parity_all_pass=#{count.(:pass)}")
IO.puts("METRIC quickjs_parity_all_failures=#{failures}")
IO.puts("METRIC quickjs_parity_all_native_rejected=#{count.(:native_rejected)}")
IO.puts("METRIC quickjs_parity_all_skipped=#{count.(:skipped)}")
IO.puts("METRIC compiler_errors=#{count.(:compiler_error)}")
IO.puts("METRIC compiler_timeouts=#{count.(:compiler_timeout)}")
IO.puts("METRIC compiler_crashes=#{count.(:compiler_crash)}")
IO.puts("METRIC compiler_fails=#{count.(:compiler_fail)}")
IO.puts("METRIC both_fail=#{count.(:both_fail)}")
IO.puts("METRIC interpreter_fail_compiler_pass=#{count.(:interpreter_fail_compiler_pass)}")
IO.puts("METRIC interpreter_timeouts=#{count.(:interpreter_timeout)}")
IO.puts("METRIC interpreter_crashes=#{count.(:interpreter_crash)}")

for {_mode, {pool, context}} <- pooled_contexts do
  QuickBEAM.Context.stop(context)
  GenServer.stop(pool)
end

for {_mode, runtime} <- beam_runtimes do
  QuickBEAM.stop(runtime)
end
