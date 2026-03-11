defmodule QuickBEAM do
  @moduledoc """
  QuickJS-NG JavaScript engine embedded in the BEAM.

  Each runtime is a GenServer holding a persistent JS context.
  State, functions, and variables survive across `eval/2` and `call/3` calls.

      iex> {:ok, rt} = QuickBEAM.start()
      iex> {:ok, 3} = QuickBEAM.eval(rt, "1 + 2")
      iex> QuickBEAM.stop(rt)
      :ok

  ## Handlers

  JS code can call Elixir functions via `beam.call` and `beam.callSync`:

      iex> {:ok, rt} = QuickBEAM.start(handlers: %{
      ...>   "greet" => fn [name] -> "Hello, \#{name}!" end
      ...> })
      iex> QuickBEAM.eval(rt, ~s[beam.callSync("greet", "world")])
      {:ok, "Hello, world!"}
      iex> QuickBEAM.stop(rt)
      :ok

  ## Supervision

  Runtimes work as OTP children:

      children = [
        {QuickBEAM, name: :app, script: "priv/js/app.js", handlers: %{...}},
      ]
      Supervisor.start_link(children, strategy: :one_for_one)

  ## Options

    * `:name` — GenServer name registration
    * `:id` — child spec ID (defaults to `:name`, then module)
    * `:handlers` — map of handler name → function for `beam.call`/`beam.callSync`
    * `:script` — path to a JS/TS file evaluated on startup. TypeScript files
      are automatically transformed. Files with `import` statements are
      automatically bundled — imports are resolved from the filesystem and
      `node_modules/`, then compiled into a single script via OXC.
    * `:memory_limit` — maximum JS heap in bytes (default: 256 MB)
    * `:max_stack_size` — maximum JS call stack in bytes (default: 1 MB)

  ## DOM

  Each runtime has a live DOM tree backed by lexbor. JS gets `document`,
  `querySelector`, `createElement`, etc. Elixir can read the DOM directly
  via `dom_find/2`, `dom_find_all/2`, `dom_text/2`, `dom_attr/3`, and
  `dom_html/1` — returning Floki-compatible `{tag, attrs, children}` tuples.
  """

  @type runtime :: GenServer.server()
  @type js_result :: {:ok, term()} | {:error, QuickBEAM.JSError.t()}

  @doc false
  def child_spec(opts) do
    QuickBEAM.Runtime.child_spec(opts)
  end

  @doc """
  Start a new JavaScript runtime.

  Returns `{:ok, pid}` on success.

  ## Options

    * `:name` — register the GenServer under this name
    * `:handlers` — `%{String.t() => function}` map for `beam.call`/`beam.callSync`
    * `:script` — path to a JS file to evaluate on startup
    * `:memory_limit` — maximum JS heap in bytes (default: 256 MB)
    * `:max_stack_size` — maximum JS call stack in bytes (default: 1 MB)
  """
  @spec start(keyword()) :: GenServer.on_start()
  def start(opts \\ []) do
    QuickBEAM.Runtime.start_link(opts)
  end

  @doc """
  Evaluate JavaScript code and return the result.

  Top-level `await` is supported.

      iex> {:ok, rt} = QuickBEAM.start()
      iex> QuickBEAM.eval(rt, "40 + 2")
      {:ok, 42}
      iex> QuickBEAM.eval(rt, "await Promise.all([1, 2].map(x => Promise.resolve(x)))")
      {:ok, [1, 2]}
      iex> QuickBEAM.stop(rt)
      :ok

  ## Options

    * `:timeout` — maximum execution time in milliseconds (default: no limit).
      If exceeded, the JS execution is interrupted and an error is returned.
      The runtime remains usable after a timeout.

          QuickBEAM.eval(rt, "while(true) {}", timeout: 1000)
          # => {:error, %QuickBEAM.JSError{message: "interrupted", ...}}
  """
  @spec eval(runtime(), String.t(), keyword()) :: js_result()
  def eval(runtime, code, opts \\ []) do
    QuickBEAM.Runtime.eval(runtime, code, opts)
  end

  @doc """
  Call a global JavaScript function by name.

  Arguments are converted to JS values; the return value is converted back.
  Promise-returning functions are automatically awaited.

      iex> {:ok, rt} = QuickBEAM.start()
      iex> QuickBEAM.eval(rt, "function add(a, b) { return a + b }")
      iex> QuickBEAM.call(rt, "add", [2, 3])
      {:ok, 5}
      iex> QuickBEAM.stop(rt)
      :ok

  ## Options

    * `:timeout` — maximum execution time in milliseconds (default: no limit)
  """
  @spec call(runtime(), String.t(), list(), keyword()) :: js_result()
  def call(runtime, fn_name, args \\ [], opts \\ []) do
    QuickBEAM.Runtime.call(runtime, fn_name, args, opts)
  end

  @doc """
  Compile JavaScript source to bytecode without executing it.

  Returns `{:ok, bytecode}` where `bytecode` is a binary that can be loaded
  into any runtime with `load_bytecode/2`. Useful for precompilation, caching,
  and transferring compiled code between runtimes or nodes.
  """
  @spec compile(runtime(), String.t()) :: {:ok, binary()} | {:error, QuickBEAM.JSError.t()}
  def compile(runtime, code) do
    QuickBEAM.Runtime.compile(runtime, code)
  end

  @doc """
  Execute precompiled bytecode from `compile/2`.

  The bytecode runs in the current runtime's context, with access to all
  globals, handlers, and builtins.
  """
  @spec load_bytecode(runtime(), binary()) :: js_result()
  def load_bytecode(runtime, bytecode) do
    QuickBEAM.Runtime.load_bytecode(runtime, bytecode)
  end

  @doc """
  Load an ES module into the runtime.

      iex> {:ok, rt} = QuickBEAM.start()
      iex> code = "export function add(a, b) { return a + b; }"
      iex> QuickBEAM.load_module(rt, "math", code)
      :ok
      iex> QuickBEAM.stop(rt)
      :ok
  """
  @spec load_module(runtime(), String.t(), String.t()) :: :ok | {:error, String.t()}
  def load_module(runtime, name, code) do
    QuickBEAM.Runtime.load_module(runtime, name, code)
  end

  @doc """
  Reset the runtime to a fresh JS context. Clears all state and functions.

      iex> {:ok, rt} = QuickBEAM.start()
      iex> QuickBEAM.eval(rt, "globalThis.x = 42")
      iex> QuickBEAM.reset(rt)
      :ok
      iex> QuickBEAM.eval(rt, "typeof x")
      {:ok, "undefined"}
      iex> QuickBEAM.stop(rt)
      :ok
  """
  @spec reset(runtime()) :: :ok | {:error, String.t()}
  def reset(runtime) do
    QuickBEAM.Runtime.reset(runtime)
  end

  @doc "Stop a runtime and free its resources."
  @spec stop(runtime()) :: :ok
  def stop(runtime) do
    QuickBEAM.Runtime.stop(runtime)
  end

  @doc """
  Evaluate TypeScript code by transforming it to JavaScript first.

  Equivalent to `OXC.transform!/2` followed by `eval/3`, but in a single call.

      iex> {:ok, rt} = QuickBEAM.start()
      iex> QuickBEAM.eval_ts(rt, "const x: number = 40 + 2; x")
      {:ok, 42}
      iex> QuickBEAM.stop(rt)
      :ok

  ## Options

  Accepts the same options as `eval/3` (e.g., `:timeout`).
  """
  @spec eval_ts(runtime(), String.t(), keyword()) :: js_result()
  def eval_ts(runtime, ts_code, opts \\ []) do
    js = OXC.transform!(ts_code, "eval.ts")
    eval(runtime, js, opts)
  end

  @doc "Return QuickJS memory usage statistics."
  @spec memory_usage(runtime()) :: map()
  def memory_usage(runtime) do
    QuickBEAM.Runtime.memory_usage(runtime)
  end

  @doc """
  Send a message to the runtime's JS handler.

  The message is delivered to the callback registered via `Process.onMessage`
  in JS. If no handler is registered, the message is silently discarded.
  """
  @spec send_message(runtime(), term()) :: :ok
  def send_message(runtime, message) do
    QuickBEAM.Runtime.send_message(runtime, message)
  end

  @user_globals_js """
  (() => {
    const names = Object.getOwnPropertyNames(globalThis).sort();
    return names.filter(k => !k.startsWith("__qb_") && !(k in globalThis.__qb_builtins));
  })()
  """

  @doc """
  List global names defined in the JS context.

  By default returns all `globalThis` property names. Pass `user_only: true`
  to exclude JS builtins and QuickBEAM internals — only names defined by
  your scripts.

  ## Examples

      {:ok, all} = QuickBEAM.globals(rt)
      # ["Array", "Boolean", "Buffer", "Object", "console", "myVar", ...]

      {:ok, mine} = QuickBEAM.globals(rt, user_only: true)
      # ["myVar", "myFunc"]
  """
  @spec globals(runtime(), keyword()) :: {:ok, [String.t()]} | {:error, QuickBEAM.JSError.t()}
  def globals(runtime, opts \\ []) do
    if Keyword.get(opts, :user_only, false) do
      eval(runtime, @user_globals_js)
    else
      eval(runtime, "Object.getOwnPropertyNames(globalThis).sort()")
    end
  end

  @doc """
  Get the value of a JS global. Works like `eval(rt, "name")` but safer —
  the name is accessed as a property, not evaluated as code.

  Returns the value converted to Elixir terms. For objects, returns a map
  of enumerable own properties. For functions, returns a map with metadata.

  ## Examples

      QuickBEAM.get_global(rt, "myVar")
      {:ok, 42}

      QuickBEAM.get_global(rt, "myObj")
      {:ok, %{"x" => 1, "y" => 2}}

      QuickBEAM.get_global(rt, "nonexistent")
      {:ok, nil}
  """
  @spec get_global(runtime(), String.t()) :: js_result()
  def get_global(runtime, name) when is_binary(name) do
    eval(runtime, "globalThis[#{inspect(name)}]")
  end

  @doc """
  Return runtime diagnostics: registered handlers, memory stats, and JS global count.
  """
  @spec info(runtime()) :: map()
  def info(runtime) do
    handlers = GenServer.call(runtime, :info, :infinity)
    mem = memory_usage(runtime)
    {:ok, global_count} = eval(runtime, "Object.getOwnPropertyNames(globalThis).length")

    %{
      handlers: handlers,
      memory: mem,
      global_count: global_count
    }
  end

  @doc """
  Find the first element matching a CSS selector in the runtime's DOM.

  Returns the element as a Floki-compatible `{tag, attrs, children}` tuple,
  or `nil` if no match is found. This reads the live DOM tree directly from
  the native layer — no JS execution or HTML re-parsing.

      {:ok, rt} = QuickBEAM.start()
      QuickBEAM.eval(rt, "document.body.innerHTML = '<p class=\"intro\">Hello</p>'")
      {:ok, {"p", [{"class", "intro"}], ["Hello"]}} = QuickBEAM.dom_find(rt, "p.intro")
  """
  @spec dom_find(runtime(), String.t()) :: {:ok, tuple() | nil}
  def dom_find(runtime, selector) do
    QuickBEAM.Runtime.dom_find(runtime, selector)
  end

  @doc """
  Find all elements matching a CSS selector in the runtime's DOM.

  Returns a list of Floki-compatible `{tag, attrs, children}` tuples.

      {:ok, rt} = QuickBEAM.start()
      QuickBEAM.eval(rt, ~s[document.body.innerHTML = '<ul><li>a</li><li>b</li></ul>'])
      {:ok, items} = QuickBEAM.dom_find_all(rt, "li")
      length(items) # => 2
  """
  @spec dom_find_all(runtime(), String.t()) :: {:ok, list()}
  def dom_find_all(runtime, selector) do
    QuickBEAM.Runtime.dom_find_all(runtime, selector)
  end

  @doc """
  Extract text content from the first element matching a CSS selector.

      {:ok, rt} = QuickBEAM.start()
      QuickBEAM.eval(rt, "document.body.innerHTML = '<h1>Title</h1>'")
      {:ok, "Title"} = QuickBEAM.dom_text(rt, "h1")
  """
  @spec dom_text(runtime(), String.t()) :: {:ok, String.t()}
  def dom_text(runtime, selector) do
    QuickBEAM.Runtime.dom_text(runtime, selector)
  end

  @doc """
  Get an attribute value from the first element matching a CSS selector.

  Returns `nil` if the element or attribute is not found.

      {:ok, rt} = QuickBEAM.start()
      QuickBEAM.eval(rt, ~s[document.body.innerHTML = '<a href="/page">link</a>'])
      {:ok, "/page"} = QuickBEAM.dom_attr(rt, "a", "href")
  """
  @spec dom_attr(runtime(), String.t(), String.t()) :: {:ok, String.t() | nil}
  def dom_attr(runtime, selector, attr_name) do
    QuickBEAM.Runtime.dom_attr(runtime, selector, attr_name)
  end

  @doc """
  Serialize the entire DOM tree to an HTML string.

      {:ok, rt} = QuickBEAM.start()
      QuickBEAM.eval(rt, "document.body.innerHTML = '<p>Hello</p>'")
      {:ok, html} = QuickBEAM.dom_html(rt)
  """
  @spec dom_html(runtime()) :: {:ok, String.t()}
  def dom_html(runtime) do
    QuickBEAM.Runtime.dom_html(runtime)
  end
end
