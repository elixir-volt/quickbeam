defmodule QuickBEAM.JS do
  @moduledoc """
  JavaScript and TypeScript toolchain powered by OXC.

  Provides parsing, transformation, minification, and bundling of JS/TS
  code via Rust NIFs — no Node.js or Bun required.

  These are thin wrappers around the `OXC` library. See `OXC` module docs
  for full option details.
  """

  # ── Polyfill compilation (compile-time only) ──

  @ts_dir Path.join([__DIR__, "../../priv/ts"]) |> Path.expand()

  for ts <- Path.wildcard(Path.join(@ts_dir, "*.ts")),
      not String.ends_with?(ts, ".d.ts") do
    @external_resource ts
  end

  defmodule Compiler do
    @moduledoc false

    def standalone(ts_dir, names) do
      for name <- names do
        path = Path.join(ts_dir, "#{name}.ts")
        source = File.read!(path)

        OXC.transform!(source, Path.basename(path))
        |> then(&"(() => {\n#{&1}\n})();\n")
      end
    end

    def bundle(ts_dir, barrel) do
      barrel_source = File.read!(Path.join(ts_dir, barrel))
      {:ok, specifiers} = OXC.imports(barrel_source, barrel)

      import_names =
        specifiers
        |> Enum.filter(&String.starts_with?(&1, "./"))
        |> Enum.map(&String.trim_leading(&1, "./"))

      all_names = Enum.uniq([Path.rootname(barrel) | import_names])

      files =
        for name <- all_names do
          path = Path.join(ts_dir, "#{name}.ts")
          {"#{name}.ts", File.read!(path)}
        end

      OXC.bundle!(files)
    end

    def bundle_modules(ts_dir, modules, exports_barrel) do
      files =
        for mod <- modules do
          path = Path.join(ts_dir, "#{mod}.ts")
          {"#{mod}.ts", File.read!(path)}
        end

      barrel = {"_barrel.ts", exports_barrel}
      OXC.bundle!([barrel | files])
    end
  end

  # ── Granular API groups ──
  #
  # Core events (Event, EventTarget, AbortController, DOMException) are
  # auto-included when any group that needs them is requested.
  # Each group's barrel assigns its exports to globalThis.

  @core_js [Compiler.bundle_modules(
    @ts_dir,
    ~w[event dom-exception event-target abort],
    """
    import { AbortSignal, AbortController } from './abort'
    import { DOMException } from './dom-exception'
    import { Event, MessageEvent, CloseEvent, ErrorEvent } from './event'
    import { EventTarget } from './event-target'
    Object.assign(globalThis, {
      DOMException, Event, MessageEvent, CloseEvent, ErrorEvent,
      EventTarget, AbortSignal, AbortController
    })
    """
  )]

  @process_js Compiler.standalone(@ts_dir, ~w[process])

  # Groups that need core events — loaded automatically
  @needs_core ~w[fetch websocket worker channel eventsource console locks dom]a
  # Groups that need process.ts (message dispatcher)
  @needs_process ~w[worker websocket eventsource]a

  @api_groups %{
    fetch: [Compiler.bundle_modules(
      @ts_dir,
      ~w[event dom-exception event-target abort headers blob streams form-data fetch text-streams],
      """
      import { Blob, File } from './blob'
      import { Request, Response, fetch } from './fetch'
      import { FormData } from './form-data'
      import { Headers } from './headers'
      import { ReadableStream, ReadableStreamDefaultReader, WritableStream, WritableStreamDefaultWriter, TransformStream } from './streams'
      import { TextDecoderStream, TextEncoderStream } from './text-streams'
      Object.assign(globalThis, {
        ReadableStream, ReadableStreamDefaultReader,
        WritableStream, WritableStreamDefaultWriter, TransformStream,
        TextEncoderStream, TextDecoderStream, Blob, File, FormData, Headers,
        Request, Response, fetch
      })
      """
    )],
    websocket: [Compiler.bundle_modules(
      @ts_dir,
      ~w[event dom-exception event-target abort blob streams websocket],
      """
      import { WebSocket } from './websocket'
      globalThis.WebSocket = WebSocket
      """
    )],
    worker: [Compiler.bundle_modules(
      @ts_dir,
      ~w[event dom-exception event-target worker],
      """
      import { Worker } from './worker'
      globalThis.Worker = Worker
      """
    )],
    channel: [Compiler.bundle_modules(
      @ts_dir,
      ~w[event dom-exception event-target broadcast-channel message-channel],
      """
      import { BroadcastChannel } from './broadcast-channel'
      import { MessageChannel, MessagePort } from './message-channel'
      Object.assign(globalThis, { BroadcastChannel, MessageChannel, MessagePort })
      """
    )],
    eventsource: [Compiler.bundle_modules(
      @ts_dir,
      ~w[event dom-exception event-target event-source],
      """
      import { EventSource } from './event-source'
      globalThis.EventSource = EventSource
      """
    )],
    url: Compiler.standalone(@ts_dir, ~w[url]),
    crypto: Compiler.standalone(@ts_dir, ~w[crypto-subtle]),
    compression: Compiler.standalone(@ts_dir, ~w[compression]),
    buffer: Compiler.standalone(@ts_dir, ~w[buffer]),
    dom: Compiler.standalone(@ts_dir, ~w[class-list style dom-events performance mutation-observer]),
    console: [Compiler.bundle_modules(
      @ts_dir,
      ~w[console-ext],
      "import './console-ext'"
    )],
    storage: [Compiler.bundle_modules(
      @ts_dir,
      ~w[storage],
      "import './storage'"
    )],
    locks: [Compiler.bundle_modules(
      @ts_dir,
      ~w[event dom-exception event-target locks],
      "import './locks'"
    )],
  }

  @browser_groups ~w[fetch websocket worker channel eventsource url crypto compression buffer dom console storage locks]a

  @browser_js Compiler.standalone(
                @ts_dir,
                ~w[url crypto-subtle compression buffer process class-list style]
              ) ++
                [Compiler.bundle(@ts_dir, "web-apis.ts")] ++
                Compiler.standalone(@ts_dir, ~w[dom-events performance mutation-observer])

  @beam_js Compiler.standalone(@ts_dir, ~w[beam-api])

  @node_js Compiler.standalone(
             @ts_dir,
             ~w[node-process node-path node-fs node-os node-child-process]
           )

  @doc false
  def browser_js, do: @browser_js
  @doc false
  def beam_js, do: @beam_js
  @doc false
  def node_js, do: @node_js
  @doc false
  def core_js, do: @core_js
  @doc false
  def process_js, do: @process_js
  @doc false
  def api_group(name), do: Map.fetch!(@api_groups, name)
  @doc false
  def browser_groups, do: @browser_groups
  @doc false
  def needs_core, do: @needs_core
  @doc false
  def needs_process, do: @needs_process

  @doc false
  def js_for_apis(apis) do
    if :browser in apis do
      @browser_js
    else
      groups = expand_apis(apis)
      needs_core? = Enum.any?(groups, &(&1 in @needs_core))
      needs_process? = Enum.any?(groups, &(&1 in @needs_process))

      js = if needs_core?, do: @core_js, else: []
      js = if needs_process?, do: js ++ @process_js, else: js

      js ++
        Enum.flat_map(groups, fn group ->
          Map.fetch!(@api_groups, group)
        end)
    end
  end

  defp expand_apis(apis) do
    Enum.flat_map(apis, fn
      :browser -> @browser_groups
      :beam -> []
      :node -> []
      group when is_atom(group) -> [group]
    end)
    |> Enum.uniq()
  end

  # ── OXC toolchain delegations ──

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
  Extract import specifiers from JS/TS source.

  Faster than `parse/2` + `collect/2` — skips full AST serialization
  and returns only the import source strings. Type-only imports
  (`import type { ... }`) are excluded.

      {:ok, imports} = QuickBEAM.JS.imports("import { ref } from 'vue'", "test.ts")
      # => {:ok, ["vue"]}
  """
  @spec imports(String.t(), String.t()) :: {:ok, [String.t()]} | {:error, [String.t()]}
  defdelegate imports(source, filename), to: OXC

  @doc "Like `imports/2` but raises on errors."
  @spec imports!(String.t(), String.t()) :: [String.t()]
  defdelegate imports!(source, filename), to: OXC

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
  Depth-first post-order AST traversal. Like `Macro.postwalk/2`.

  See `OXC.postwalk/2` for details.
  """
  @spec postwalk(map(), (map() -> map())) :: map()
  defdelegate postwalk(node, fun), to: OXC

  @doc """
  Depth-first post-order AST traversal with accumulator. Like `Macro.postwalk/3`.

  See `OXC.postwalk/3` for details.
  """
  @spec postwalk(map(), acc, (map(), acc -> {map(), acc})) :: {map(), acc} when acc: term()
  defdelegate postwalk(node, acc, fun), to: OXC

  @doc """
  Collect values from an AST tree by walking and filtering nodes.

  See `OXC.collect/2` for details.
  """
  @spec collect(map(), (map() -> {:keep, any()} | :skip)) :: [any()]
  defdelegate collect(node, fun), to: OXC

  @doc """
  Apply position-based patches to a source string.

  See `OXC.patch_string/2` for details.
  """
  @spec patch_string(String.t(), [map()]) :: String.t()
  defdelegate patch_string(source, patches), to: OXC
end
