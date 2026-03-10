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
    * `:script` — path to a JS file evaluated on startup
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
  """
  @spec eval(runtime(), String.t()) :: js_result()
  def eval(runtime, code) do
    QuickBEAM.Runtime.eval(runtime, code)
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
  """
  @spec call(runtime(), String.t(), list()) :: js_result()
  def call(runtime, fn_name, args \\ []) do
    QuickBEAM.Runtime.call(runtime, fn_name, args)
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
