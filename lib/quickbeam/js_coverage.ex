defmodule QuickBEAM.JSCoverage do
  @moduledoc """
  JavaScript coverage instrumentation and collection.

  Tracks which lines of JS code are executed during tests, then
  exports coverage data for combination with ExUnit coverage.

  ## Usage

  1. Enable coverage instrumentation in your test setup:

      def setup do
        QuickBEAM.JSCoverage.start()
        on_exit(fn -> QuickBEAM.JSCoverage.stop() end)
      end

  2. After tests run, export coverage:

      QuickBEAM.JSCoverage.export()

  3. Combine with ExUnit coverage in mix.exs:

      test_coverage: [
        tools: [
          {ExUnit.Coverage.Writers.HTMLWriter, output: "cover"},
          {QuickBEAM.JSCoverage.Writer, output: "cover/js.html"}
        ]
      ]

  ## How It Works

  At compile-time, JS bundles are instrumented by wrapping each
  executable statement with __qcov(line_number). At runtime, the
  QuickJS context tracks which lines execute. When exported, the
  coverage data is converted to the same format as ExUnit's coverage.

  ┌─────────────────────────────────────────────────────────────┐
  │ Compile Time: priv/ts/fetch.ts                             │
  │   async function fetch(url) {      // line 1              │
  │     return fetch_impl(url);        // line 2              │
  │   }                                // line 3              │
  │                                                             │
  │   ↓ Instrumented                                          │
  │                                                             │
  │   async function fetch(url) {      // line 1              │
  │     __qcov(2); return fetch_impl(url);  // line 2        │
  │   }                                // line 3              │
  └─────────────────────────────────────────────────────────────┘
                              │
                              ▼
  ┌─────────────────────────────────────────────────────────────┐
  │ Runtime: QuickBEAM.Runtime with instrumented JS            │
  │   __qcov(2) → coverage["fetch.ts:2"]++                    │
  └─────────────────────────────────────────────────────────────┘
                              │
                              ▼
  ┌─────────────────────────────────────────────────────────────┐
  │ Export: Combined coverage report                           │
  │   { "priv/ts/fetch.ts" => [0, 1, 0, 1, 1, ...],          │
  │     "priv/ts/url.ts" => [1, 1, 1, 0, ...],                │
  │     :total => %{covered: 142, not_covered: 38} }          │
  └─────────────────────────────────────────────────────────────┘
  """

  @doc """
  Start coverage instrumentation for all new runtimes.

  When enabled, newly created runtimes will load instrumented versions
  of the JS polyfills, tracking which lines execute.

  Returns a cleanup function that can be passed to `on_exit/1`.
  """
  @spec start() :: (-> :ok)
  def start do
    Application.put_env(:quickbeam, :js_coverage, true)
    Application.put_env(:quickbeam, :js_coverage_data, %{})

    fn ->
      Application.delete_env(:quickbeam, :js_coverage)
      Application.delete_env(:quickbeam, :js_coverage_data)
    end
  end

  @doc """
  Stop coverage instrumentation.
  """
  @spec stop() :: :ok
  def stop do
    Application.delete_env(:quickbeam, :js_coverage)
  end

  @doc """
  Check if coverage instrumentation is enabled.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(:quickbeam, :js_coverage, false)
  end

  @doc """
  Record a line hit for a JS file.

  Called automatically by instrumented JS code via Beam.call.
  """
  @spec record_hit(String.t(), non_neg_integer()) :: :ok
  def record_hit(file, line) do
    if enabled?() do
      data = Application.get_env(:quickbeam, :js_coverage_data, %{})

      file_data =
        Map.get_and_update(data, file, fn
          nil ->
            lines = Enum.reduce(1..line, [], fn _, acc -> [0 | acc] end)
            lines = List.replace_at(lines, line - 1, 1)
            {nil, lines}

          existing when is_list(existing) ->
            lines =
              if line > length(existing) do
                # Extend the array if we hit a higher line number
                existing ++ List.duplicate(0, line - length(existing) - 1) ++ [1]
              else
                List.update_at(existing, line - 1, &(&1 + 1))
              end

            {existing, lines}
        end)
        |> elem(1)

      Application.put_env(:quickbeam, :js_coverage_data, Map.put(data, file, file_data))
    end

    :ok
  end

  @doc """
  Export coverage data in ExUnit-compatible format.

  Returns a map with file paths as keys and line hit counts as values,
  compatible with `ExUnit.Coverage` format.

  ## Return Format

      %{
        "priv/ts/fetch.ts" => [0, 5, 3, 0, 1, ...],  # hits per line
        "priv/ts/url.ts" => [1, 1, 0, 0, ...],
        :total => %{covered: 142, not_covered: 38},
        :summary => %{
          "priv/ts/fetch.ts" => {covered: 4, not_covered: 2, total: 6},
          ...
        }
      }
  """
  @spec export() :: %{
          optional(String.t()) => [non_neg_integer()],
          :total => %{covered: non_neg_integer(), not_covered: non_neg_integer()},
          :summary => %{optional(String.t()) => {non_neg_integer(), non_neg_integer(), non_neg_integer()}}
        }
  def export do
    data = Application.get_env(:quickbeam, :js_coverage_data, %{})

    # Calculate per-file coverage
    summary =
      Enum.map(data, fn {file, hits} ->
        {file, calculate_file_coverage(hits)}
      end)
      |> Map.new()

    # Calculate totals
    {covered, not_covered} =
      Enum.reduce(summary, {0, 0}, fn {_file, {cov, not_cov}}, {c, n} ->
        {c + cov, n + not_cov}
      end)

    %{
      :total => %{covered: covered, not_covered: not_covered},
      :summary => summary
    }
    |> Map.merge(data)
  end

  @doc """
  Export coverage as LCOV format for CI integration.

  LCOV format is supported by many CI tools (GitLab, Codecov, etc.)
  """
  @spec export_lcov() :: String.t()
  def export_lcov do
    data = export()

    Enum.map(data, fn
      {file, hits} when is_list(hits) ->
        lines = Enum.with_index(hits, 1)

        line_data =
          Enum.map(lines, fn {count, line_no} ->
            "DA:#{line_no},#{count}"
          end)
          |> Enum.join("\n")

        """
        SF:#{file}
        #{line_data}
        end_of_record
        """

      _ ->
        ""
    end)
    |> Enum.join("\n")
  end

  @doc """
  Export coverage as JSON for programmatic access.
  """
  @spec export_json() :: String.t()
  def export_json do
    data = export()
    Jason.encode!(data, pretty: true)
  end

  @doc """
  Reset coverage data. Call between test runs.
  """
  @spec reset() :: :ok
  def reset do
    Application.put_env(:quickbeam, :js_coverage_data, %{})
  end

  @doc """
  Combine JS coverage with ExUnit coverage data.

  Useful for generating a unified report.
  """
  @spec combine_with_exunit(ExUnit.Coverage.t()) :: ExUnit.Coverage.t()
  def combine_with_exunit(ex_unit_coverage) do
    js_coverage = export()

    # Convert JS coverage to ExUnit format and merge
    js_as_ex_unit =
      Enum.map(js_coverage, fn
        {file, hits} when is_list(hits) ->
          {file, calculate_line_coverage(hits)}

        _ ->
          nil
      end)
      |> Enum.reject(&is_nil/1)
      |> Map.new()

    Map.merge(ex_unit_coverage, js_as_ex_unit)
  end

  # Calculate {covered, not_covered, total} for a file
  defp calculate_file_coverage(hits) do
    total = length(hits)

    covered =
      Enum.count(hits, &(&1 > 0))

    {covered, total - covered, total}
  end

  # Convert to ExUnit's {cov, not_cov} per-line format
  defp calculate_line_coverage(hits) do
    Enum.map(hits, fn
      0 -> {0, 1}  # not covered
      _ -> {1, 0}  # covered
    end)
  end

  # ─────────────────────────────────────────────────────────────────
  # HTML Writer for ExUnit integration
  # ─────────────────────────────────────────────────────────────────

  defmodule Writer do
    @moduledoc """
    ExUnit.Coverage writer that generates HTML for JS coverage.

    Add to your mix.exs:

        test_coverage: [
          summary: [threshold: 70],
          tools: [
            {QuickBEAM.JSCoverage.Writer, output: "cover/js.html"}
          ]
        ]
    """

    @behaviour ExUnit.Coverage.Writer

    @impl true
    def init(opts) do
      output = Keyword.fetch!(opts, :output)
      {:ok, %{output: output}}
    end

    @impl true
    def write(coverage, %{output: output} = state) do
      # coverage here is the ExUnit coverage format
      # We need to combine with our JS coverage
      js_data = QuickBEAM.JSCoverage.export()

      html = generate_html(js_data)

      File.write!(output, html)
      {:ok, state}
    end

    @impl true
    def finish(state) do
      state
    end

    defp generate_html(data) do
      summary = Map.get(data, :summary, %{})
      total = Map.get(data, :total, %{covered: 0, not_covered: 0})

      files_html =
        Enum.map(summary, fn {file, {covered, not_covered, total_lines}} ->
          pct = if total_lines > 0, do: div(covered * 100, total_lines), else: 0
          color = if pct >= 80, do: "green", else: if pct >= 50, do: "orange", else: "red"

          """
          <tr>
            <td>#{file}</td>
            <td>#{covered}/#{total_lines}</td>
            <td style="color: #{color}">#{pct}%</td>
          </tr>
          """
        end)
        |> Enum.join("\n")

      total_pct =
        if total.covered + total.not_covered > 0 do
          div(total.covered * 100, total.covered + total.not_covered)
        else
          0
        end

      """
      <!DOCTYPE html>
      <html>
      <head>
        <meta charset="utf-8">
        <title>QuickBEAM JS Coverage</title>
        <style>
          body { font: 14px/1.6 Arial, sans-serif; margin: 40px; }
          table { border-collapse: collapse; width: 100%; max-width: 800px; }
          th, td { border: 1px solid #ddd; padding: 8px 12px; text-align: left; }
          th { background: #f5f5f5; }
          h1 { color: #333; }
          .total { font-size: 1.5em; margin: 20px 0; }
        </style>
      </head>
      <body>
        <h1>QuickBEAM JS Coverage</h1>
        <p class="total">Total: #{total.covered} lines covered, #{total.not_covered} not covered</p>
        <table>
          <thead>
            <tr>
              <th>File</th>
              <th>Lines</th>
              <th>Coverage</th>
            </tr>
          </thead>
          <tbody>
            #{files_html}
          </tbody>
        </table>
      </body>
      </html>
      """
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # JS Instrumentation (for use during bundling)
  # ─────────────────────────────────────────────────────────────────

  @doc """
  Instrument JavaScript source code with coverage counters.

  Wraps executable statements with __qcov(line_number) calls.

  ## Example

      iex> QuickBEAM.JSCoverage.instrument("const x = 1;\\nreturn x;", "test.js")
      "const x = __qcov(1), 1;\\n__qcov(2);return x;"

  """
  @spec instrument(String.t(), String.t()) :: String.t()
  def instrument(js_source, filename) do
    case OXC.parse(js_source, filename) do
      {:ok, ast} ->
        instrumented = instrument_node(ast, filename)
        OXC.transform!(instrumented, filename)

      {:error, errors} ->
        raise "Failed to parse JS for coverage instrumentation: #{inspect(errors)}"
    end
  end

  # Recursively walk the AST and add coverage markers
  defp instrument_node(node, filename) when is_map(node) do
    type = Map.get(node, :type)

    cond do
      # Skip certain node types that shouldn't have coverage
      type in ["Program", "File"] ->
        Map.update!(node, "body", fn body ->
          Enum.map(body, &instrument_node(&1, filename))
        end)

      # Function declarations and expressions
      type in ["FunctionDeclaration", "FunctionExpression", "ArrowFunctionExpression"] ->
        instrument_function(node, filename)

      # Statements that are worth tracking
      type in ["ExpressionStatement", "ReturnStatement", "ThrowStatement",
               "IfStatement", "SwitchStatement", "ForStatement", "ForInStatement",
               "ForOfStatement", "WhileStatement", "DoWhileStatement",
               "TryStatement", "WithStatement", "LabeledStatement",
               "VariableDeclaration", "EmptyStatement"] ->
        instrument_statement(node, filename)

      # Block statements
      type == "BlockStatement" ->
        Map.update!(node, "body", fn body ->
          Enum.map(body, &instrument_node(&1, filename))
        end)

      # Default: recurse into children
      true ->
        node
        |> Map.keys()
        |> Enum.reduce(node, fn key, acc ->
          case Map.get(acc, key) do
            val when is_list(val) ->
              Map.put(acc, key, Enum.map(val, &instrument_node(&1, filename)))

            val when is_map(val) ->
              Map.put(acc, key, instrument_node(val, filename))

            _ ->
              acc
          end
        end)
    end
  end

  defp instrument_node(other, _), do: other

  # Add coverage call before function body
  defp instrument_function(node, filename) do
    start = Map.get(node, "start", %{})
    line = Map.get(start, "line", 1)

    # Wrap the body
    body =
      case Map.get(node, "body") do
        %{"type" => "BlockStatement"} = block ->
          Map.update!(block, "body", fn statements ->
            coverage_call(line, filename) ++ statements
          end)

        other ->
          # Arrow functions with expression bodies
          coverage_call(line, filename) ++ [other]
      end

    Map.put(node, "body", body)
  end

  # Add coverage call for statements
  defp instrument_statement(node, filename) do
    start = Map.get(node, "start", %{})
    line = Map.get(start, "line", 1)

    # For expression statements, wrap the expression
    if Map.get(node, "type") == "ExpressionStatement" do
      Map.update!(node, "expression", fn expr ->
        wrap_expression(expr, line, filename)
      end)
    else
      # For other statements, prepend a coverage call
      [%{"type" => "ExpressionStatement", "expression" => coverage_call_expr(line, filename)},
       node]
      |> Enum.reject(&is_nil/1)
      |> then(fn [first | rest] ->
        Map.merge(node, %{"start" => start})
      end)
    end
  end

  # Wrap an expression with a sequence expression that includes coverage
  defp wrap_expression(expr, line, filename) do
    %{"type" => "SequenceExpression",
      "expressions" => [coverage_call_expr(line, filename), expr]}
  end

  # Generate the coverage call as an AST node
  defp coverage_call_expr(line, filename) do
    %{
      "type" => "CallExpression",
      "callee" => %{
        "type" => "MemberExpression",
        "object" => %{"type" => "Identifier", "name" => "__qbCoverage"},
        "property" => %{"type" => "Identifier", "name" => "hit"}
      },
      "arguments" => [
        %{"type" => "Literal", "value" => filename},
        %{"type" => "Literal", "value" => line}
      ]
    }
  end

  # Generate the coverage call as a list (for prepending to arrays)
  defp coverage_call(line, filename) do
    [%{
       "type" => "ExpressionStatement",
       "expression" => coverage_call_expr(line, filename)
     }]
  end
end
