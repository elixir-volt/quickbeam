defmodule QuickBEAM.Context do
  @moduledoc """
  A lightweight JS execution context on a shared runtime thread.

  Unlike `QuickBEAM.Runtime`, a context does not spawn a dedicated OS thread.
  Many contexts share a single `JSRuntime` thread managed by a
  `QuickBEAM.ContextPool`. This makes each context ~50KB vs ~2MB+
  for a full runtime — ideal for per-connection state in Phoenix LiveView.

  ## Example

      {:ok, pool} = QuickBEAM.ContextPool.start_link()
      {:ok, ctx} = QuickBEAM.Context.start_link(pool: pool)
      {:ok, 3} = QuickBEAM.Context.eval(ctx, "1 + 2")
      QuickBEAM.Context.stop(ctx)

  ## With LiveView

      def mount(_params, _session, socket) do
        {:ok, ctx} = QuickBEAM.Context.start_link(
          pool: MyApp.JSPool,
          handlers: %{"db.query" => &MyApp.query/1}
        )
        {:ok, assign(socket, js: ctx)}
      end

      def handle_event("click", params, socket) do
        {:ok, html} = QuickBEAM.Context.call(socket.assigns.js, "handleClick", [params])
        {:noreply, push_event(socket, "update", %{html: html})}
      end

      def terminate(_reason, socket) do
        QuickBEAM.Context.stop(socket.assigns.js)
      end
  """
  use GenServer

  @enforce_keys [:pool_resource, :context_id]
  defstruct [:pool_resource, :context_id, handlers: %{}, pending: %{}]

  @type t :: %__MODULE__{
          pool_resource: reference(),
          context_id: pos_integer(),
          handlers: map(),
          pending: map()
        }

  def child_spec(opts) do
    id = Keyword.get(opts, :id, Keyword.get(opts, :name, __MODULE__))

    %{
      id: id,
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {pool, opts} = Keyword.pop!(opts, :pool)

    GenServer.start_link(__MODULE__, [{:pool, pool} | opts], Keyword.take(opts, [:name]))
  end

  @spec eval(GenServer.server(), String.t(), keyword()) :: {:ok, term()} | {:error, String.t()}
  def eval(server, code, opts \\ []) when is_binary(code) do
    timeout_ms = Keyword.get(opts, :timeout, 0)
    GenServer.call(server, {:eval, code, timeout_ms}, :infinity)
  end

  @spec call(GenServer.server(), String.t(), list(), keyword()) ::
          {:ok, term()} | {:error, String.t()}
  def call(server, fn_name, args \\ [], opts \\ []) when is_binary(fn_name) and is_list(args) do
    timeout_ms = Keyword.get(opts, :timeout, 0)
    GenServer.call(server, {:call, fn_name, args, timeout_ms}, :infinity)
  end

  @spec reset(GenServer.server()) :: :ok | {:error, String.t()}
  def reset(server) do
    GenServer.call(server, :reset, :infinity)
  end

  @spec stop(GenServer.server()) :: :ok
  def stop(server) do
    GenServer.stop(server)
  end

  @spec send_message(GenServer.server(), term()) :: :ok
  def send_message(server, message) do
    GenServer.cast(server, {:send_message, message})
  end

  @spec dom_find(GenServer.server(), String.t()) :: {:ok, tuple() | nil}
  def dom_find(server, selector) do
    GenServer.call(server, {:dom_find, selector}, :infinity)
  end

  @spec dom_find_all(GenServer.server(), String.t()) :: {:ok, list()}
  def dom_find_all(server, selector) do
    GenServer.call(server, {:dom_find_all, selector}, :infinity)
  end

  @spec dom_text(GenServer.server(), String.t()) :: {:ok, String.t()}
  def dom_text(server, selector) do
    GenServer.call(server, {:dom_text, selector}, :infinity)
  end

  @spec dom_html(GenServer.server()) :: {:ok, String.t()}
  def dom_html(server) do
    GenServer.call(server, :dom_html, :infinity)
  end

  @browser_js QuickBEAM.JS.browser_js()
  @beam_js QuickBEAM.JS.beam_js()
  @node_js QuickBEAM.JS.node_js()
  @snapshot_builtins_js QuickBEAM.JS.snapshot_builtins_js()

  @impl true
  def init(opts) do
    pool = Keyword.fetch!(opts, :pool)
    user_handlers = Keyword.get(opts, :handlers, %{})

    apis =
      case Keyword.get(opts, :apis, [:browser]) do
        false -> []
        nil -> []
        api when is_atom(api) -> [api]
        list when is_list(list) -> list
      end

    builtin_handlers =
      Enum.reduce(apis, QuickBEAM.Runtime.beam_handlers(), fn
        :browser, acc -> Map.merge(acc, QuickBEAM.Runtime.browser_handlers())
        :node, acc -> Map.merge(acc, QuickBEAM.Runtime.node_handlers())
        _, acc -> acc
      end)

    merged_handlers = builtin_handlers |> Map.merge(user_handlers)

    {pool_resource, context_id} =
      QuickBEAM.ContextPool.create_context(pool, self())

    state = %__MODULE__{
      pool_resource: pool_resource,
      context_id: context_id,
      handlers: merged_handlers
    }

    install_builtins(state, apis)

    case Keyword.fetch(opts, :script) do
      :error ->
        {:ok, state}

      {:ok, path} ->
        case load_script(state, path) do
          {:ok, state} -> {:ok, state}
          {:error, reason} -> {:stop, reason}
        end
    end
  end

  defp install_builtins(state, apis) do
    if :browser in apis do
      for js <- @browser_js, do: sync_eval(state, js)
    end

    if :node in apis do
      for js <- @node_js, do: sync_eval(state, js)
    end

    if apis != [] do
      for js <- @beam_js, do: sync_eval(state, js)
    end

    sync_eval(state, @snapshot_builtins_js)
  end

  defp sync_eval(state, code) do
    ref = QuickBEAM.Native.pool_eval(state.pool_resource, state.context_id, code, 0)

    receive do
      {^ref, result} -> result
    after
      30_000 -> {:error, "NIF timeout"}
    end
  end

  defp load_script(state, path) do
    case File.read(path) do
      {:ok, code} ->
        ref = QuickBEAM.Native.pool_eval(state.pool_resource, state.context_id, code, 0)
        await_eval_ref(ref, state)

      {:error, reason} ->
        {:error, {:script_not_found, path, reason}}
    end
  end

  defp await_eval_ref(ref, state) do
    receive do
      {^ref, {:ok, _}} ->
        {:ok, state}

      {^ref, {:error, reason}} ->
        {:error, {:script_error, reason}}

      {:beam_call, _call_id, _handler, _args} = msg ->
        {:noreply, state} = handle_info(msg, state)
        await_eval_ref(ref, state)
    after
      30_000 -> {:error, :script_timeout}
    end
  end

  @impl true
  def handle_call({:eval, code, timeout_ms}, from, state) do
    ref = QuickBEAM.Native.pool_eval(state.pool_resource, state.context_id, code, timeout_ms)

    transform = fn
      {:ok, value} -> {:ok, value}
      {:error, value} -> {:error, QuickBEAM.JSError.from_js_value(value)}
    end

    {:noreply, put_pending(state, ref, from, transform)}
  end

  def handle_call({:call, fn_name, args, timeout_ms}, from, state) do
    ref =
      QuickBEAM.Native.pool_call_function(
        state.pool_resource,
        state.context_id,
        fn_name,
        args,
        timeout_ms
      )

    transform = fn
      {:ok, value} -> {:ok, value}
      {:error, value} -> {:error, QuickBEAM.JSError.from_js_value(value)}
    end

    {:noreply, put_pending(state, ref, from, transform)}
  end

  def handle_call({:dom_find, selector}, from, state) do
    ref = QuickBEAM.Native.pool_dom_find(state.pool_resource, state.context_id, selector)
    {:noreply, put_pending(state, ref, from, nil)}
  end

  def handle_call({:dom_find_all, selector}, from, state) do
    ref = QuickBEAM.Native.pool_dom_find_all(state.pool_resource, state.context_id, selector)
    {:noreply, put_pending(state, ref, from, nil)}
  end

  def handle_call({:dom_text, selector}, from, state) do
    ref = QuickBEAM.Native.pool_dom_text(state.pool_resource, state.context_id, selector)
    {:noreply, put_pending(state, ref, from, nil)}
  end

  def handle_call(:dom_html, from, state) do
    ref = QuickBEAM.Native.pool_dom_html(state.pool_resource, state.context_id)
    {:noreply, put_pending(state, ref, from, nil)}
  end

  def handle_call(:reset, from, state) do
    ref = QuickBEAM.Native.pool_reset_context(state.pool_resource, state.context_id)

    transform = fn
      {:ok, _} -> :ok
      {:error, msg} -> {:error, msg}
    end

    {:noreply, put_pending(state, ref, from, transform)}
  end

  @impl true
  def handle_cast({:send_message, message}, state) do
    QuickBEAM.Native.pool_send_message(state.pool_resource, state.context_id, message)
    {:noreply, state}
  end

  @impl true
  def handle_info({:beam_call, call_id, handler_name, args}, state) do
    resource = state.pool_resource
    context_id = state.context_id
    handlers = state.handlers

    case Map.get(handlers, handler_name) do
      nil ->
        QuickBEAM.Native.pool_reject_call_term(
          resource,
          context_id,
          call_id,
          "Unknown handler: #{handler_name}"
        )

      handler ->
        Task.start(fn ->
          try do
            args = if is_list(args), do: args, else: [args]
            result = handler.(args)

            QuickBEAM.Native.pool_resolve_call_term(resource, context_id, call_id, result)
          rescue
            e ->
              QuickBEAM.Native.pool_reject_call_term(
                resource,
                context_id,
                call_id,
                Exception.message(e)
              )
          end
        end)
    end

    {:noreply, state}
  end

  def handle_info({ref, result}, state) when is_reference(ref) do
    case Map.pop(state.pending, ref) do
      {nil, _} ->
        {:noreply, state}

      {{from, nil}, pending} ->
        GenServer.reply(from, result)
        {:noreply, %{state | pending: pending}}

      {{from, transform}, pending} ->
        GenServer.reply(from, transform.(result))
        {:noreply, %{state | pending: pending}}
    end
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    QuickBEAM.Native.pool_destroy_context(state.pool_resource, state.context_id)
    :ok
  end

  defp put_pending(state, ref, from, transform) do
    %{state | pending: Map.put(state.pending, ref, {from, transform})}
  end
end
