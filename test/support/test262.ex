defmodule QuickBEAM.Test262 do
  @moduledoc false

  @root Path.expand("../test262", __DIR__)
  @harness_dir Path.join(@root, "harness")

  def root, do: @root
  def available?, do: File.dir?(Path.join(@root, "test"))

  def find_tests(category) do
    Path.join([@root, "test", category, "**/*.js"])
    |> Path.wildcard()
    |> Enum.reject(&String.contains?(&1, "_FIXTURE"))
    |> Enum.sort()
  end

  def relative_path(file), do: Path.relative_to(file, Path.join(@root, "test"))

  def parse_metadata(source) do
    with [_, rest] <- String.split(source, "/*---", parts: 2),
         [yaml, _] <- String.split(rest, "---*/", parts: 2) do
      YamlElixir.read_from_string!(yaml)
    else
      _ -> %{}
    end
  end

  def harness_source(includes \\ []) do
    extra = Enum.map_join(includes, "\n", &read_harness/1)
    test262_error() <> "\n" <> read_harness("sta.js") <> "\n" <> read_harness("assert.js") <> "\n" <> extra
  end

  def load_skip_list do
    Path.expand("../test262_skip.txt", __DIR__)
    |> File.stream!()
    |> Stream.map(&String.trim/1)
    |> Stream.reject(&(String.starts_with?(&1, "#") or &1 == ""))
    |> MapSet.new()
  end

  def build_nif_failures(rt, categories) do
    for category <- categories,
        file <- find_tests(category),
        reduce: MapSet.new() do
      acc ->
        source = File.read!(file)
        meta = parse_metadata(source)

        if "async" in flags(meta) or "module" in flags(meta) do
          acc
        else
          full = "(function(){" <> harness_source(includes(meta)) <> "\n" <> source <> "\n})()"
          pass = try do match?({:ok, _}, QuickBEAM.eval(rt, full)) catch _, _ -> false end
          if pass, do: acc, else: MapSet.put(acc, relative_path(file))
        end
    end
  end

  defp flags(meta), do: Map.get(meta, "flags", [])
  defp includes(meta), do: Map.get(meta, "includes", [])

  defp read_harness(name) do
    path = Path.join(@harness_dir, name)
    if File.exists?(path), do: File.read!(path), else: ""
  end

  defp test262_error do
    ~s[function Test262Error(m){this.message=m||"";this.name="Test262Error"}] <>
      ~s[Test262Error.prototype.toString=function(){return "Test262Error: "+this.message};]
  end
end
