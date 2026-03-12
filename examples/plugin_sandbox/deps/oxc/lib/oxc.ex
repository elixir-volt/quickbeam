defmodule OXC do
  @moduledoc """
  Elixir bindings for the [OXC](https://oxc.rs) JavaScript toolchain.

  Provides fast JavaScript and TypeScript parsing, transformation, and
  minification via Rust NIFs. The file extension determines the dialect —
  `.js`, `.jsx`, `.ts`, `.tsx`.

      iex> {:ok, ast} = OXC.parse("const x = 1 + 2", "test.js")
      iex> ast.type
      "Program"

      iex> {:ok, js} = OXC.transform("const x: number = 42", "test.ts")
      iex> js
      "const x = 42;\\n"

  AST nodes are maps with atom keys, following the ESTree specification.
  """

  @type ast :: map()
  @type error :: %{message: String.t()}
  @type parse_result :: {:ok, ast()} | {:error, [error()]}

  @doc """
  Parse JavaScript or TypeScript source code into an ESTree AST.

  The filename extension determines the dialect:
  - `.js` — JavaScript
  - `.jsx` — JavaScript with JSX
  - `.ts` — TypeScript
  - `.tsx` — TypeScript with JSX

  Returns `{:ok, ast}` where `ast` is a map with atom keys, or
  `{:error, errors}` with a list of parse error maps.

  ## Examples

      iex> {:ok, ast} = OXC.parse("const x = 1", "test.js")
      iex> [decl] = ast.body
      iex> decl.type
      "VariableDeclaration"

      iex> {:error, [%{message: msg} | _]} = OXC.parse("const = ;", "bad.js")
      iex> is_binary(msg)
      true
  """
  @spec parse(String.t(), String.t()) :: parse_result()
  def parse(source, filename) do
    OXC.Native.parse(source, filename)
  end

  @doc """
  Like `parse/2` but raises on parse errors.

  ## Examples

      iex> ast = OXC.parse!("const x = 1", "test.js")
      iex> ast.type
      "Program"
  """
  @spec parse!(String.t(), String.t()) :: ast()
  def parse!(source, filename) do
    case parse(source, filename) do
      {:ok, ast} -> ast
      {:error, errors} -> raise "OXC parse error: #{inspect(errors)}"
    end
  end

  @doc """
  Check if source code is syntactically valid.

  Faster than `parse/2` — skips AST serialization.

  ## Examples

      iex> OXC.valid?("const x = 1", "test.js")
      true

      iex> OXC.valid?("const = ;", "bad.js")
      false
  """
  @spec valid?(String.t(), String.t()) :: boolean()
  def valid?(source, filename) do
    OXC.Native.valid(source, filename)
  end

  @doc """
  Transform TypeScript/JSX source code into plain JavaScript.

  Strips type annotations, transforms JSX, and lowers syntax features.
  The filename extension determines the source dialect.

  ## Options

    * `:jsx` — JSX runtime, `:automatic` (default) or `:classic`
    * `:jsx_factory` — function for classic JSX (default: `"React.createElement"`)
    * `:jsx_fragment` — fragment for classic JSX (default: `"React.Fragment"`)
    * `:import_source` — JSX import source (e.g. `"vue"`, `"preact"`)
    * `:target` — downlevel target (e.g. `"es2019"`, `"chrome80"`)
    * `:sourcemap` — generate a source map (default: `false`). When `true`,
      returns `%{code: String.t(), sourcemap: String.t()}` instead of a plain string.

  ## Examples

      iex> {:ok, js} = OXC.transform("const x: number = 42", "test.ts")
      iex> js
      "const x = 42;\\n"

      iex> {:ok, js} = OXC.transform("<div />", "c.jsx", jsx: :classic)
      iex> js =~ "createElement"
      true
  """
  @spec transform(String.t(), String.t(), keyword()) ::
          {:ok, String.t() | %{code: String.t(), sourcemap: String.t()}} | {:error, [String.t()]}
  def transform(source, filename, opts \\ []) do
    jsx_runtime = opts |> Keyword.get(:jsx, :automatic) |> Atom.to_string()
    jsx_factory = Keyword.get(opts, :jsx_factory, "")
    jsx_fragment = Keyword.get(opts, :jsx_fragment, "")
    import_source = Keyword.get(opts, :import_source, "")
    target = Keyword.get(opts, :target, "")
    sourcemap = Keyword.get(opts, :sourcemap, false)

    OXC.Native.transform(
      source,
      filename,
      jsx_runtime,
      jsx_factory,
      jsx_fragment,
      import_source,
      target,
      sourcemap
    )
  end

  @doc """
  Like `transform/3` but raises on errors.

  ## Examples

      iex> OXC.transform!("const x: number = 42", "test.ts")
      "const x = 42;\\n"
  """
  @spec transform!(String.t(), String.t(), keyword()) ::
          String.t() | %{code: String.t(), sourcemap: String.t()}
  def transform!(source, filename, opts \\ []) do
    case transform(source, filename, opts) do
      {:ok, code} -> code
      {:error, errors} -> raise "OXC transform error: #{inspect(errors)}"
    end
  end

  @doc """
  Minify JavaScript source code.

  Applies dead code elimination, constant folding, and whitespace removal.
  Optionally mangles variable names for smaller output.

  ## Options

    * `:mangle` — rename variables for shorter names (default: `true`)

  ## Examples

      iex> {:ok, min} = OXC.minify("if (false) { x() } y();", "test.js")
      iex> min =~ "y()"
      true
      iex> min =~ "x()"
      false
  """
  @spec minify(String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, [String.t()]}
  def minify(source, filename, opts \\ []) do
    mangle = Keyword.get(opts, :mangle, true)
    OXC.Native.minify(source, filename, mangle)
  end

  @doc """
  Like `minify/3` but raises on errors.

  ## Examples

      iex> min = OXC.minify!("const x = 1 + 2;", "test.js")
      iex> is_binary(min)
      true
  """
  @spec minify!(String.t(), String.t(), keyword()) :: String.t()
  def minify!(source, filename, opts \\ []) do
    case minify(source, filename, opts) do
      {:ok, code} -> code
      {:error, errors} -> raise "OXC minify error: #{inspect(errors)}"
    end
  end

  @doc """
  Extract import specifiers from JavaScript/TypeScript source.

  Faster than `parse/2` + `collect/2` — skips full AST serialization
  and returns only the import source strings. Type-only imports
  (`import type { ... }`) are excluded.

  ## Examples

      iex> {:ok, imports} = OXC.imports("import { ref } from 'vue'\\nimport type { Ref } from 'vue'", "test.ts")
      iex> imports
      ["vue"]
  """
  @spec imports(String.t(), String.t()) :: {:ok, [String.t()]} | {:error, [String.t()]}
  def imports(source, filename) do
    OXC.Native.imports(source, filename)
  end

  @doc "Like `imports/2` but raises on errors."
  @spec imports!(String.t(), String.t()) :: [String.t()]
  def imports!(source, filename) do
    case imports(source, filename) do
      {:ok, list} -> list
      {:error, errors} -> raise "OXC imports error: #{inspect(errors)}"
    end
  end

  @doc """
  Bundle multiple TypeScript/JavaScript modules into a single IIFE script.

  Takes a list of `{filename, source}` tuples representing modules that import
  from each other via relative paths (e.g. `import { Foo } from './foo'`).

  The bundler:
  1. Transforms each module (strips TypeScript, JSX)
  2. Resolves the dependency graph from import statements
  3. Topologically sorts modules
  4. Strips `import`/`export` syntax (declarations are kept in scope)
  5. Concatenates in dependency order, wrapped in `(() => { ... })()`
  6. Optionally applies define replacements and minification

  ## Options

    * `:minify` — minify the output (default: `false`)
    * `:banner` — string to prepend before the IIFE (e.g. `"/* v1.0 */"`)
    * `:footer` — string to append after the IIFE
    * `:define` — compile-time replacements, map of `%{"process.env.NODE_ENV" => ~s("production")}`
    * `:sourcemap` — generate a source map (default: `false`). When `true`,
      returns `%{code: String.t(), sourcemap: String.t()}` instead of a plain string.
    * `:drop_console` — remove `console.*` calls during minification (default: `false`)
    * `:jsx` — JSX runtime, `:automatic` (default) or `:classic`
    * `:jsx_factory` — function for classic JSX (default: `"React.createElement"`)
    * `:jsx_fragment` — fragment for classic JSX (default: `"React.Fragment"`)
    * `:import_source` — JSX import source (e.g. `"vue"`, `"preact"`)
    * `:target` — downlevel target (e.g. `"es2019"`, `"chrome80"`)

  ## Examples

      iex> files = [
      ...>   {"event.ts", "export class Event { type: string; constructor(type: string) { this.type = type } }"},
      ...>   {"target.ts", "import { Event } from './event'\\nexport class Target { dispatch(e: Event) { return e.type } }"}
      ...> ]
      iex> {:ok, js} = OXC.bundle(files)
      iex> js =~ "class Event"
      true
      iex> js =~ "class Target"
      true
      iex> js =~ "import"
      false
  """
  @spec bundle([{String.t(), String.t()}], keyword()) ::
          {:ok, String.t() | %{code: String.t(), sourcemap: String.t()}}
          | {:error, [String.t()]}
  def bundle(files, opts \\ []) do
    OXC.Native.bundle(files, opts)
  end

  @doc """
  Like `bundle/2` but raises on errors.
  """
  @spec bundle!([{String.t(), String.t()}], keyword()) ::
          String.t() | %{code: String.t(), sourcemap: String.t()}
  def bundle!(files, opts \\ []) do
    case bundle(files, opts) do
      {:ok, result} -> result
      {:error, errors} -> raise "OXC bundle error: #{inspect(errors)}"
    end
  end

  @doc """
  Walk an AST tree, calling `fun` on every node (any map with a `type` key).

  ## Examples

      iex> {:ok, ast} = OXC.parse("const x = 1", "test.js")
      iex> OXC.walk(ast, fn
      ...>   %{type: "Identifier", name: name} -> send(self(), {:id, name})
      ...>   _ -> :ok
      ...> end)
      iex> receive do {:id, name} -> name end
      "x"
  """
  @spec walk(ast(), (map() -> any())) :: :ok
  def walk(node, fun) when is_map(node) do
    if Map.has_key?(node, :type), do: fun.(node)

    node
    |> Map.values()
    |> Enum.each(fn
      child when is_map(child) -> walk(child, fun)
      children when is_list(children) -> Enum.each(children, &walk_child(&1, fun))
      _ -> :ok
    end)
  end

  def walk(_node, _fun), do: :ok

  defp walk_child(node, fun) when is_map(node), do: walk(node, fun)
  defp walk_child(_node, _fun), do: :ok

  @doc """
  Collect AST nodes that match a filter function.

  The function receives each node (map with `type` key) and should return
  `{:keep, value}` to include it in results, or `:skip` to exclude it.

  ## Examples

      iex> {:ok, ast} = OXC.parse("const x = y + z", "test.js")
      iex> OXC.collect(ast, fn
      ...>   %{type: "Identifier", name: name} -> {:keep, name}
      ...>   _ -> :skip
      ...> end)
      ["x", "y", "z"]
  """
  @spec collect(ast(), (map() -> {:keep, any()} | :skip)) :: [any()]
  def collect(node, fun) do
    acc = :ets.new(:oxc_collect, [:set, :private])

    try do
      walk(node, fn n ->
        case fun.(n) do
          {:keep, value} -> :ets.insert(acc, {:erlang.unique_integer([:monotonic]), value})
          :skip -> :ok
        end
      end)

      acc
      |> :ets.tab2list()
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(&elem(&1, 1))
    after
      :ets.delete(acc)
    end
  end
end
