defmodule QuickBEAM.JSCoverageHandler do
  @moduledoc """
  Beam.call handler that records JS coverage hits.

  This module is registered as a handler in QuickBEAM runtimes
  when coverage is enabled. The instrumented JS calls __qbCoverage_hit
  which routes to this handler.
  """

  @doc """
  Record a coverage hit for a JS file and line number.

  Called from instrumented JS via Beam.call("__qb_coverage_hit", [file, line]).
  """
  def hit([file, line]) when is_binary(file) and is_integer(line) do
    QuickBEAM.JSCoverage.record_hit(file, line)
    :ok
  end

  @doc """
  Record multiple coverage hits at once (more efficient for batch recording).
  """
  def hit_batch([pairs]) when is_list(pairs) do
    Enum.each(pairs, fn
      [file, line] when is_binary(file) and is_integer(line) ->
        QuickBEAM.JSCoverage.record_hit(file, line)

      %{file: file, line: line} ->
        QuickBEAM.JSCoverage.record_hit(file, line)
    end)

    :ok
  end
end
