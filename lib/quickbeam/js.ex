defmodule QuickBEAM.JS do
  @moduledoc """
  JavaScript and TypeScript toolchain powered by OXC.

  Provides parsing, transformation, minification, and bundling of JS/TS
  code via Rust NIFs — no Node.js or Bun required.

  These are thin wrappers around the `OXC` library. See `OXC` module docs
  for full option details.
  """

  @doc """
  Parse JS/TS source into an AST.

      {:ok, ast} = QuickBEAM.JS.parse("const x: number = 1", "file.ts")
  """
  @spec parse(String.t(), String.t()) :: {:ok, map()} | {:error, [String.t()]}
  defdelegate parse(source, filename), to: OXC

  @doc """
  Parse JS/TS source into an AST, raising on error.
  """
  @spec parse!(String.t(), String.t()) :: map()
  defdelegate parse!(source, filename), to: OXC

  @doc """
  Check if JS/TS source is syntactically valid.

      QuickBEAM.JS.valid?("const x = 1", "file.js")
      # => true
  """
  @spec valid?(String.t(), String.t()) :: boolean()
  defdelegate valid?(source, filename), to: OXC

  @doc """
  Transform TypeScript/JSX to plain JavaScript.

      {:ok, js} = QuickBEAM.JS.transform("const x: number = 1", "file.ts")
      # => {:ok, "const x = 1;\\n"}

  ## Options

    * `:jsx` — enable JSX transformation (default: auto-detected from filename)
  """
  @spec transform(String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, [String.t()]}
  defdelegate transform(source, filename, opts \\ []), to: OXC

  @doc """
  Transform TypeScript/JSX to plain JavaScript, raising on error.
  """
  @spec transform!(String.t(), String.t(), keyword()) :: String.t()
  defdelegate transform!(source, filename, opts \\ []), to: OXC

  @doc """
  Minify JavaScript source code.

      {:ok, min} = QuickBEAM.JS.minify("const x = 1 + 2;", "file.js")

  ## Options

    * `:compress` — apply compression optimizations (default: true)
    * `:mangle` — mangle variable names (default: true)
  """
  @spec minify(String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, [String.t()]}
  defdelegate minify(source, filename, opts \\ []), to: OXC

  @doc """
  Minify JavaScript source code, raising on error.
  """
  @spec minify!(String.t(), String.t(), keyword()) :: String.t()
  defdelegate minify!(source, filename, opts \\ []), to: OXC

  @doc """
  Bundle multiple TS/JS modules into a single self-executing script.

  Accepts a list of `{filename, source}` tuples. Resolves imports between
  them, topologically sorts by dependencies, strips module syntax, and
  wraps the result in an IIFE.

      files = [
        {"utils.ts", "export function add(a: number, b: number) { return a + b }"},
        {"main.ts", "import { add } from './utils'\\nconsole.log(add(1, 2))"}
      ]
      {:ok, js} = QuickBEAM.JS.bundle(files)

  ## Options

    * `:minify` — minify the output (default: false)
    * `:banner` — string to prepend before the IIFE
    * `:footer` — string to append after the IIFE
    * `:sourcemap` — generate source map (returns `%{code, sourcemap}`)
    * `:define` — compile-time identifier replacements
    * `:drop_console` — remove `console.*` calls (default: false)
  """
  @spec bundle([{String.t(), String.t()}], keyword()) ::
          {:ok, String.t() | map()} | {:error, String.t()}
  defdelegate bundle(files, opts \\ []), to: OXC

  @doc """
  Bundle multiple TS/JS modules, raising on error.
  """
  @spec bundle!([{String.t(), String.t()}], keyword()) :: String.t() | map()
  defdelegate bundle!(files, opts \\ []), to: OXC

  @doc """
  Bundle an entry file from disk with all its dependencies.

  Recursively resolves imports — both relative paths (`./utils`) and
  bare specifiers (`lodash-es`) via `node_modules/`. Reads all sources,
  then bundles them with `OXC.bundle/2`.

      {:ok, js} = QuickBEAM.JS.bundle_file("src/main.ts")

  The `node_modules/` directory is found by walking up from the entry file.
  Override with the `:node_modules` option.

  Accepts all options from `bundle/2` plus:

    * `:node_modules` — explicit path to `node_modules/` directory
  """
  @spec bundle_file(String.t(), keyword()) ::
          {:ok, String.t() | map()} | {:error, term()}
  defdelegate bundle_file(path, opts \\ []), to: QuickBEAM.JS.Bundler

  @doc """
  Walk an AST tree, calling `fun` on every node.

  See `OXC.walk/2` for details.
  """
  @spec walk(map(), (map() -> any())) :: :ok
  defdelegate walk(node, fun), to: OXC

  @doc """
  Collect values from an AST tree by walking and filtering nodes.

  See `OXC.collect/2` for details.
  """
  @spec collect(map(), (map() -> {:keep, any()} | :skip)) :: [any()]
  defdelegate collect(node, fun), to: OXC
end
