defmodule QuickBEAM.JS.Parser.QuickJSAcceptanceAuditTest do
  use ExUnit.Case, async: false

  @moduletag :quickjs_acceptance_audit

  @default_glob "test/test262/test/**/*.js"
  @default_limit 2_000
  @default_offset 0
  @default_timeout 5_000

  env_int = fn name, default ->
    case System.get_env(name) do
      nil -> default
      "" -> default
      value -> String.to_integer(value)
    end
  end

  @audit_file_timeout env_int.("AUDIT_FILE_TIMEOUT", @default_timeout)

  @selected_files System.get_env("AUDIT_GLOB", @default_glob)
                  |> Path.wildcard()
                  |> Enum.reject(&String.ends_with?(&1, "_FIXTURE.js"))
                  |> Enum.sort()
                  |> Enum.drop(env_int.("AUDIT_OFFSET", @default_offset))
                  |> Enum.take(env_int.("AUDIT_LIMIT", @default_limit))

  metadata = fn source ->
    yaml =
      case Regex.run(~r{/\*---\r?\n(.*?)\r?\n---\*/}s, source, capture: :all_but_first) do
        [yaml] -> yaml
        _ -> ""
      end

    flags =
      case Regex.run(~r/^flags:\s*\[(.*?)\]\r?$/m, yaml, capture: :all_but_first) do
        [flags] ->
          flags

        _ ->
          if Regex.match?(~r/^flags:\s*\r?\n(?:\s*-\s*\S+\s*\r?\n?)+/m, yaml), do: yaml, else: ""
      end

    features =
      case Regex.run(~r/^features:\s*\[(.*?)\]\r?$/m, yaml, capture: :all_but_first) do
        [features] ->
          features

        _ ->
          if Regex.match?(~r/^features:\s*\r?\n(?:\s*-\s*\S+\s*\r?\n?)+/m, yaml),
            do: yaml,
            else: ""
      end

    %{flags: flags, features: features}
  end

  module_file? = fn path, source, flags ->
    String.contains?(flags, "module") or
      (String.contains?(path, "/module-code/") and
         not String.contains?(Path.basename(path), "script-code")) or
      Regex.match?(~r/^\s*(import|export)\b/m, source)
  end

  unsupported_quickjs_feature? = fn features ->
    String.contains?(features, "decorators") or
      String.contains?(features, "explicit-resource-management") or
      String.contains?(features, "source-phase-imports") or
      String.contains?(features, "regexp-modifiers") or
      String.contains?(features, "regexp-v-flag")
  end

  unsupported_quickjs_syntax_gap? = fn source ->
    Regex.match?(~r/\b(?:static\s+)?(?:get|set)\s*\R\s*\*/, source) or
      String.contains?(source, "sec-runtime-errors-for-function-call-assignment-targets") or
      Regex.match?(~r/\\[pP]\{(?:Script|sc|Script_Extensions|scx)=(?:Unknown|Zzzz)\}/, source)
  end

  audit_source = fn source, flags ->
    if String.contains?(flags, "onlyStrict"), do: ~s("use strict";\n) <> source, else: source
  end

  relative_path = fn file ->
    Path.relative_to(file, Path.join(["test", "test262", "test"]))
  end

  setup_all do
    {:ok, rt} = QuickBEAM.start(apis: false)

    on_exit(fn ->
      QuickBEAM.stop(rt)
    end)

    %{rt: rt}
  end

  for file <- @selected_files do
    source = File.read!(file)
    relative = relative_path.(file)
    meta = metadata.(source)

    cond do
      module_file?.(file, source, meta.flags) ->
        @tag skip: "module input"
        test "QuickJS parser acceptance #{relative}" do
        end

      unsupported_quickjs_feature?.(meta.features) ->
        @tag skip: "unsupported QuickJS feature"
        test "QuickJS parser acceptance #{relative}" do
        end

      unsupported_quickjs_syntax_gap?.(source) ->
        @tag skip: "unsupported QuickJS syntax edge"
        test "QuickJS parser acceptance #{relative}" do
        end

      true ->
        source = audit_source.(source, meta.flags)
        @tag timeout: @audit_file_timeout
        test "QuickJS parser acceptance #{relative}", %{rt: rt} do
          source = unquote(source)
          relative = unquote(relative)

          quickjs =
            case QuickBEAM.compile(rt, source) do
              {:ok, _} ->
                :ok

              {:error, %QuickBEAM.JS.Error{name: name, message: message}} ->
                {:error, name, message}
            end

          parser =
            case QuickBEAM.JS.Parser.parse(source) do
              {:ok, _} -> :ok
              {:error, _program, errors} -> {:error, Enum.map(errors, & &1.message)}
            end

          quickjs_accepted? = quickjs == :ok
          parser_accepted? = parser == :ok

          assert quickjs_accepted? == parser_accepted?, """
          Acceptance mismatch for #{relative}
          QuickJS: #{inspect(quickjs, limit: :infinity)}
          Parser:  #{inspect(parser, limit: :infinity)}
          """
        end
    end
  end
end
