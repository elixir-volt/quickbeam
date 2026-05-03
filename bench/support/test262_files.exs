Code.require_file("common.exs", __DIR__)

defmodule Bench.Test262Files do
  @moduledoc false

  @default_glob "test/test262/test/**/*.js"

  def sample(opts \\ []) do
    glob = Keyword.get(opts, :glob, System.get_env("TEST262_GLOB", @default_glob))
    offset = Keyword.get(opts, :offset, Bench.Support.env_integer("TEST262_SAMPLE_OFFSET", 0))
    limit = Keyword.get(opts, :limit, Bench.Support.env_integer("TEST262_SAMPLE_LIMIT", 60_000))
    include_negative? = Keyword.get(opts, :include_negative?, false)

    glob
    |> Path.wildcard()
    |> Enum.sort()
    |> reject_support_fixtures()
    |> maybe_reject_negative(include_negative?)
    |> Enum.drop(offset)
    |> Enum.take(limit)
  end

  def metadata(source) do
    yaml =
      case Regex.run(~r{/\*---\n(.*?)\n---\*/}s, source, capture: :all_but_first) do
        [yaml] -> yaml
        _ -> ""
      end

    %{
      yaml: yaml,
      flags: metadata_field(yaml, ~r/^flags:\s*\[(.*?)\]$/m) || "",
      negative_phase: metadata_field(yaml, ~r/negative:\s*\n\s*phase:\s*(\w+)/)
    }
  end

  def source_type(path, source) do
    cond do
      module?(path, source) -> :module
      true -> :script
    end
  end

  def module?(path, source) do
    meta = metadata(source)

    String.contains?(meta.flags, "module") or
      module_code_fixture?(path) or
      Regex.match?(~r/^\s*(?:import\s+(?:[\w*{]|["'])|export\s+)/m, source)
  end

  def negative?(path), do: path |> File.read!() |> String.contains?("negative:")

  def support_fixture?(path), do: String.ends_with?(path, "_FIXTURE.js")

  defp metadata_field(yaml, regex) do
    case Regex.run(regex, yaml, capture: :all_but_first) do
      [value] -> value
      _ -> nil
    end
  end

  defp module_code_fixture?(path) do
    String.contains?(path, "/module-code/") and
      not String.contains?(Path.basename(path), "script-code")
  end

  defp reject_support_fixtures(paths), do: Enum.reject(paths, &support_fixture?/1)

  defp maybe_reject_negative(paths, true), do: paths
  defp maybe_reject_negative(paths, false), do: Enum.reject(paths, &negative?/1)
end
