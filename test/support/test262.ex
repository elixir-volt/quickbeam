defmodule QuickBEAM.Test262.Negative do
  @moduledoc "Defines the typed Test262 negative-test metadata contract."

  use JSONCodec, strict: true, fast_path: :json

  defstruct [:phase, :type]

  @type phase :: :parse | :early | :resolution | :runtime
  @type t :: %__MODULE__{
          phase: :parse | :early | :resolution | :runtime,
          type: String.t()
        }

  codec(:phase, atom: {:enum, [:parse, :early, :resolution, :runtime]})
end

defmodule QuickBEAM.Test262.Metadata do
  @moduledoc "Defines the typed subset of Test262 YAML front matter used by the runner."

  use JSONCodec, strict: true, fast_path: :json

  defstruct flags: [], includes: [], features: [], negative: nil

  @type t :: %__MODULE__{
          flags: [String.t()],
          includes: [String.t()],
          features: [String.t()],
          negative: QuickBEAM.Test262.Negative.t() | nil
        }
end

defmodule QuickBEAM.Test262 do
  @moduledoc """
  Runs a pinned, bounded Test262 manifest against native QuickJS and the BEAM VM.

  The external Test262 checkout is supplied through `TEST262_PATH`; the corpus
  is not vendored into the QuickBEAM package. Every result is classified rather
  than silently falling back to the native engine.
  """

  @minimal_harness """
  function Test262Error(message) {
    this.name = "Test262Error";
    this.message = message || "";
  }
  function assert(condition, message) {
    if (condition !== true) throw new Test262Error(message || "Expected true");
  }
  assert.sameValue = function(actual, expected, message) {
    var same = actual === expected && (actual !== 0 || 1 / actual === 1 / expected);
    if (!same) same = actual !== actual && expected !== expected;
    if (!same) throw new Test262Error(message || "Expected SameValue");
  };
  assert.notSameValue = function(actual, unexpected, message) {
    var same = actual === unexpected && (actual !== 0 || 1 / actual === 1 / unexpected);
    if (same || (actual !== actual && unexpected !== unexpected)) {
      throw new Test262Error(message || "Expected different values");
    }
  };
  assert.compareArray = function(actual, expected, message) {
    assert.sameValue(actual.length, expected.length, message || "Array lengths differ");
    for (var index = 0; index < expected.length; index++) {
      assert.sameValue(actual[index], expected[index], message || "Array values differ");
    }
  };
  function $DONOTEVALUATE() { throw new Test262Error("Test must not be evaluated"); }
  """

  @type classification ::
          :pass
          | :vm_failure
          | :native_failure
          | :unsupported_flag
          | :missing

  @type result :: %{
          path: String.t(),
          classification: classification(),
          vm: term(),
          native: term(),
          metadata: map()
        }

  @doc "Loads the pinned selected-test manifest."
  @spec load_manifest(Path.t()) :: keyword()
  def load_manifest(path), do: path |> File.read!() |> Code.eval_string() |> elem(0)

  @doc "Returns the Test262 root configured for the current test process."
  @spec configured_root() :: Path.t() | nil
  def configured_root, do: System.get_env("TEST262_PATH")

  @doc "Parses the metadata fields needed by the bounded runner."
  @spec parse_metadata(binary()) :: QuickBEAM.Test262.Metadata.t()
  def parse_metadata(source) do
    case Regex.run(~r/\/\*---\s*(.*?)\s*---\*\//s, source, capture: :all_but_first) do
      [yaml] ->
        yaml
        |> YamlElixir.read_from_string!()
        |> QuickBEAM.Test262.Metadata.from_map!()

      _no_metadata ->
        %QuickBEAM.Test262.Metadata{}
    end
  end

  @doc "Runs every entry in a selected manifest and returns classified results."
  @spec run_manifest(Path.t(), keyword(), keyword()) :: [result()]
  def run_manifest(root, manifest, opts \\ []) do
    Enum.map(manifest[:tests], &run(root, &1, opts))
  end

  @doc "Runs one Test262 path against native QuickJS and the selected BEAM engine."
  @spec run(Path.t(), Path.t(), keyword()) :: result()
  def run(root, relative_path, opts \\ []) do
    path = Path.join([root, "test", relative_path])

    if File.regular?(path) do
      source = File.read!(path)
      metadata = parse_metadata(source)

      case unsupported_flag(metadata.flags) do
        nil ->
          run_supported(root, relative_path, source, metadata, opts)

        flag ->
          result(relative_path, :unsupported_flag, {:unsupported_flag, flag}, :not_run, metadata)
      end
    else
      result(relative_path, :missing, :missing, :missing, %{})
    end
  end

  @doc "Summarizes classifications and computes the supported-test pass rate."
  @spec summarize([result()]) :: map()
  def summarize(results) do
    counts = Enum.frequencies_by(results, & &1.classification)
    supported = Map.get(counts, :pass, 0) + Map.get(counts, :vm_failure, 0)
    pass_rate = if supported == 0, do: 0.0, else: Map.get(counts, :pass, 0) / supported
    %{total: length(results), supported: supported, pass_rate: pass_rate, counts: counts}
  end

  defp run_supported(root, relative_path, source, metadata, opts) do
    full_source =
      harness_source(root, metadata.includes) <> strict_prefix(metadata.flags) <> source

    native = native_result(full_source, metadata.negative)
    vm = vm_result(full_source, metadata.negative, opts)

    classification =
      cond do
        native != :pass -> :native_failure
        vm == :pass -> :pass
        true -> :vm_failure
      end

    result(relative_path, classification, vm, native, metadata)
  end

  defp harness_source(root, includes) do
    includes
    |> Enum.reject(&(&1 in ["assert.js", "sta.js", "compareArray.js"]))
    |> Enum.map_join("\n", fn include ->
      path = Path.join([root, "harness", include])
      if File.regular?(path), do: File.read!(path), else: ""
    end)
    |> then(&(@minimal_harness <> "\n" <> &1 <> "\n"))
  end

  defp vm_result(source, negative, opts) do
    engine = Keyword.get(opts, :engine, :interpreter)
    compiler_profile = Keyword.get(opts, :compiler_profile, :pure_v1)

    case QuickBEAM.VM.compile(source, filename: "test262.js") do
      {:ok, program} ->
        result = QuickBEAM.VM.eval(program, engine: engine, compiler_profile: compiler_profile)
        classify_execution(result, negative, :runtime)

      {:error, error} ->
        classify_execution({:error, error}, negative, :parse)
    end
  end

  defp native_result(source, negative) do
    case QuickBEAM.start(apis: false) do
      {:ok, runtime} ->
        try do
          classify_execution(QuickBEAM.eval(runtime, source), negative, :runtime)
        after
          if Process.alive?(runtime), do: safe_stop(runtime)
        end

      {:error, reason} ->
        {:native_start, reason}
    end
  end

  defp classify_execution({:ok, _value}, nil, _phase), do: :pass

  defp classify_execution(
         {:error, error},
         %QuickBEAM.Test262.Negative{phase: phase, type: type},
         actual_phase
       ) do
    if normalize_phase(phase) == actual_phase and error_name(error) == type,
      do: :pass,
      else: {:wrong_negative, actual_phase, error_name(error), error}
  end

  defp classify_execution({:error, error}, nil, phase), do: {:unexpected_error, phase, error}
  defp classify_execution({:ok, _value}, negative, _phase), do: {:missing_negative, negative}

  defp normalize_phase(:early), do: :parse
  defp normalize_phase(phase) when phase in [:parse, :resolution, :runtime], do: phase

  defp error_name(%QuickBEAM.JSError{name: name}), do: name
  defp error_name(error) when is_map(error), do: error[:name] || error["name"]
  defp error_name(_error), do: nil

  defp unsupported_flag(flags) do
    Enum.find(flags, &(&1 in ["async", "module", "raw", "CanBlockIsFalse"]))
  end

  defp strict_prefix(flags), do: if("onlyStrict" in flags, do: "\"use strict\";\n", else: "")

  defp result(path, classification, vm, native, metadata),
    do: %{path: path, classification: classification, vm: vm, native: native, metadata: metadata}

  defp safe_stop(runtime) do
    try do
      QuickBEAM.stop(runtime)
    catch
      :exit, _reason -> :ok
    end
  end
end
