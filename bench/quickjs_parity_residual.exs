Mix.Task.run("app.start")

unless Code.ensure_loaded?(QuickBEAM.Test262) do
  Code.require_file("../test/support/test262.ex", __DIR__)
end

files = ~w(
  built-ins/RegExp/CharacterClassEscapes/character-class-digit-class-escape-negative-cases.js
  built-ins/RegExp/CharacterClassEscapes/character-class-non-digit-class-escape-positive-cases.js
  built-ins/RegExp/CharacterClassEscapes/character-class-non-whitespace-class-escape-positive-cases.js
  built-ins/RegExp/CharacterClassEscapes/character-class-non-word-class-escape-positive-cases.js
  built-ins/RegExp/CharacterClassEscapes/character-class-whitespace-class-escape-negative-cases.js
  built-ins/RegExp/CharacterClassEscapes/character-class-word-class-escape-negative-cases.js
  built-ins/RegExp/match-indices/indices-array-non-unicode-match.js
  built-ins/RegExp/match-indices/indices-array-unicode-match.js
  built-ins/RegExp/match-indices/indices-array-unicode-property-names.js
  built-ins/RegExp/named-groups/functional-replace-global.js
  built-ins/RegExp/named-groups/functional-replace-non-global.js
  built-ins/Set/prototype/difference/set-like-class-order.js
  built-ins/Set/prototype/intersection/set-like-class-order.js
  built-ins/Set/prototype/isDisjointFrom/set-like-class-order.js
  built-ins/Set/prototype/isSupersetOf/set-like-class-order.js
  built-ins/Object/defineProperties/typedarray-backed-by-resizable-buffer.js
  built-ins/Object/defineProperty/typedarray-backed-by-resizable-buffer.js
)

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

case_timeout = String.to_integer(System.get_env("TEST262_CASE_TIMEOUT", "15000"))

run_raw_case = fn full, mode ->
  {:ok, rt} = QuickBEAM.start(apis: false)

  try do
    QuickBEAM.eval(rt, full, mode: mode)
  after
    QuickBEAM.stop(rt)
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
    match?({:crash, _}, raw) -> {:crash, raw}
    compiler_error?.(raw) -> {:compiler_error, raw}
    negative? and js_error?.(raw) -> {:pass, raw}
    negative? -> {:fail, raw}
    match?({:ok, _}, raw) -> {:pass, raw}
    true -> {:fail, raw}
  end
end

results =
  Enum.map(files, fn relative ->
    file = Path.join([QuickBEAM.Test262.root(), "test", relative])
    source = File.read!(file)
    meta = QuickBEAM.Test262.parse_metadata(source)
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
  "quickjs_parity_cases=#{length(results)} quickjs_parity_pass=#{count.(:pass)} quickjs_parity_failures=#{length(failures)}"
)

for result <- failures do
  IO.puts("QUICKJS_PARITY_#{String.upcase(to_string(result.status))} #{result.relative}")
  IO.puts("  interpreter=#{inspect(result.interpreter, limit: 80)}")
  IO.puts("  compiler=#{inspect(result.compiler, limit: 80)}")
end

IO.puts("METRIC quickjs_parity_cases=#{length(results)}")
IO.puts("METRIC quickjs_parity_pass=#{count.(:pass)}")
IO.puts("METRIC quickjs_parity_failures=#{length(failures)}")
IO.puts("METRIC compatibility_failures=#{length(failures)}")
IO.puts("METRIC compatibility_pass=#{count.(:pass)}")
IO.puts("METRIC compatibility_cases=#{length(results)}")
IO.puts("METRIC compiler_errors=#{count.(:compiler_error)}")
IO.puts("METRIC compiler_crashes=#{count.(:compiler_crash)}")
IO.puts("METRIC compiler_fails=#{count.(:compiler_fail)}")
IO.puts("METRIC both_fail=#{count.(:both_fail)}")
IO.puts("METRIC interpreter_fail_compiler_pass=#{count.(:interpreter_fail_compiler_pass)}")
