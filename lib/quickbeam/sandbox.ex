defmodule QuickBEAM.Sandbox do
  @moduledoc """
  Small runtime option presets for sandboxed JavaScript execution.

  These helpers do not hide `QuickBEAM.start/1`; they produce ordinary keyword
  options that can be inspected, extended, and passed to `QuickBEAM.start/1` or
  `QuickBEAM.new/1`.
  """

  import Kernel, except: [node: 0, node: 1]

  @strict_limits [
    memory_limit: 16 * 1024 * 1024,
    max_stack_size: 1 * 1024 * 1024,
    max_convert_depth: 16,
    max_convert_nodes: 2_000
  ]

  @doc "Returns a bare runtime preset: no browser/node polyfills, with conservative limits."
  def strict(opts \\ []), do: merge([apis: false] ++ @strict_limits, opts)

  @doc "Returns a browser-like sandbox preset with Web APIs enabled."
  def browser(opts \\ []), do: merge([apis: [:browser]] ++ @strict_limits, opts)

  @doc "Returns a Node-compat sandbox preset."
  def node(opts \\ []), do: merge([apis: [:node]] ++ @strict_limits, opts)

  @doc "Returns a bare runtime preset without the strict resource defaults."
  def bare(opts \\ []), do: merge([apis: false], opts)

  @doc false
  def options(:strict, opts), do: strict(opts)
  def options(:browser, opts), do: browser(opts)
  def options(:node, opts), do: node(opts)
  def options(:bare, opts), do: bare(opts)
  def options(nil, opts), do: opts
  def options(false, opts), do: merge([apis: false], opts)
  def options(true, opts), do: strict(opts)

  defp merge(defaults, overrides) do
    Keyword.merge(defaults, overrides)
  end
end
