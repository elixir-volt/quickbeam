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
    * `:memory_limit` — maximum JS heap in bytes (default: 256 MB)
    * `:max_stack_size` — maximum JS call stack in bytes (default: 1 MB)
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
  List all global names defined in the JS context.

  Returns `{:ok, [name]}` — a sorted list of all `globalThis` property names.
  """
  @spec globals(runtime()) :: {:ok, [String.t()]} | {:error, QuickBEAM.JSError.t()}
  def globals(runtime) do
    eval(runtime, "Object.getOwnPropertyNames(globalThis).sort()")
  end

  @doc """
  Inspect a JS global by name. Returns its type, value (for primitives),
  and properties (for objects/functions).

  ## Examples

      QuickBEAM.inspect_global(rt, "myVar")
      {:ok, %{name: "myVar", type: "number", value: 42}}

      QuickBEAM.inspect_global(rt, "console")
      {:ok, %{name: "console", type: "object", properties: ["log", "warn", "error"]}}
  """
  @spec inspect_global(runtime(), String.t()) :: {:ok, map()} | {:error, QuickBEAM.JSError.t()}
  def inspect_global(runtime, name) when is_binary(name) do
    case eval(runtime, inspect_global_js(name)) do
      {:ok, result} when is_map(result) -> {:ok, atomize_keys(result)}
      other -> other
    end
  end

  defp inspect_global_js(name) do
    """
    (() => {
      const name = #{inspect(name)};
      const v = globalThis[name];
      const t = typeof v;
      const info = { name, type: t };
      if (v === null) { info.type = "null"; info.value = null; }
      else if (t === "undefined") { info.value = null; }
      else if (t === "number" || t === "string" || t === "boolean" || t === "bigint") {
        info.value = v;
      } else if (t === "function") {
        info.length = v.length;
        const src = Function.prototype.toString.call(v);
        if (/^class\\s/.test(src)) info.kind = "class";
        else info.kind = "function";
      } else if (t === "object" && v !== null) {
        info.properties = Object.getOwnPropertyNames(v).sort();
      }
      return info;
    })()
    """
  end

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {String.to_atom(k), v} end)
  end
end
