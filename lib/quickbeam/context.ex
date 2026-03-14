defmodule QuickBEAM.Context do
  @moduledoc """
  A lightweight JS execution context on a shared runtime thread.

  Unlike a full runtime, a context does not spawn a dedicated OS thread.
  Many contexts share a single `JSRuntime` thread managed by a
  `QuickBEAM.ContextPool`. This makes each context ~58 KB (bare) to
  ~429 KB (full browser APIs) vs ~2 MB+ for a full runtime — ideal for
  per-connection state in Phoenix LiveView.

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

  `start_link/1` links the context to the calling process, so it
  automatically terminates (and cleans up its JS context) when the
  LiveView process exits. No explicit `terminate` callback needed.
  """
  use GenServer
  use QuickBEAM.Server

  @enforce_keys [:pool_resource, :context_id]
  defstruct [
    :pool_resource,
    :context_id,
    :pool,
    handlers: %{},
    pending: %{},
    workers: %{},
    next_worker_id: 1
  ]

  @type t :: %__MODULE__{
          pool_resource: reference(),
          context_id: pos_integer(),
          pool: GenServer.server() | nil,
          handlers: map(),
          pending: map(),
          workers: map(),
          next_worker_id: pos_integer()
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

  @spec reset(GenServer.server()) :: :ok | {:error, String.t()}
  def reset(server) do
    GenServer.call(server, :reset, :infinity)
  end

  @spec stop(GenServer.server()) :: :ok
  def stop(server) do
    GenServer.stop(server)
  end

  @spec get_global(GenServer.server(), String.t()) :: {:ok, term()}
  def get_global(server, name) when is_binary(name) do
    GenServer.call(server, {:get_global, name}, :infinity)
  end

  @spec set_global(GenServer.server(), String.t(), term()) :: :ok
  def set_global(server, name, value) when is_binary(name) do
    GenServer.call(server, {:set_global, name, value}, :infinity)
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

  @spec memory_usage(GenServer.server()) :: {:ok, map()}
  def memory_usage(server) do
    GenServer.call(server, :memory_usage, :infinity)
  end

  @beam_js QuickBEAM.JS.beam_js()
  @node_js QuickBEAM.JS.node_js()

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

    has_browser_apis = Enum.any?(apis, &(&1 not in [:beam, :node]))

    builtin_handlers = QuickBEAM.Runtime.beam_handlers()

    builtin_handlers =
      if has_browser_apis,
        do: Map.merge(builtin_handlers, QuickBEAM.Runtime.browser_handlers()),
        else: builtin_handlers

    builtin_handlers =
      if :node in apis,
        do: Map.merge(builtin_handlers, QuickBEAM.Runtime.node_handlers()),
        else: builtin_handlers

    worker_handlers =
      if has_browser_apis do
        %{
          "__worker_spawn" => {:context_worker, :spawn},
          "__worker_terminate" => {:context_worker, :terminate},
          "__worker_post_to_child" => {:context_worker, :post_to_child}
        }
      else
        %{}
      end

    merged_handlers = builtin_handlers |> Map.merge(worker_handlers) |> Map.merge(user_handlers)

    memory_limit = Keyword.get(opts, :memory_limit, 0)
    max_reductions = Keyword.get(opts, :max_reductions, 0)

    {pool_resource, context_id} =
      QuickBEAM.ContextPool.create_context(pool, self(),
        memory_limit: memory_limit,
        max_reductions: max_reductions
      )

    state = %__MODULE__{
      pool_resource: pool_resource,
      context_id: context_id,
      pool: pool,
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
    js_sources = QuickBEAM.JS.js_for_apis(apis)

    for bc <- get_bytecode(apis, js_sources), do: sync_load_bytecode(state, bc)

    if :node in apis do
      for bc <- get_bytecode_for(:node, @node_js), do: sync_load_bytecode(state, bc)
    end

    if apis != [] do
      for bc <- get_bytecode_for(:beam, @beam_js), do: sync_load_bytecode(state, bc)
    end
  end

  defp get_bytecode(apis, js_sources) do
    key = {__MODULE__, :bytecode, :crypto.hash(:md5, :erlang.term_to_binary(apis))}

    case :persistent_term.get(key, nil) do
      nil ->
        bytecodes = compile_to_bytecode(js_sources)
        :persistent_term.put(key, bytecodes)
        bytecodes

      cached ->
        cached
    end
  end

  defp get_bytecode_for(group, source) do
    key = {__MODULE__, :bytecode, group}

    case :persistent_term.get(key, nil) do
      nil ->
        bytecodes = compile_to_bytecode(source)
        :persistent_term.put(key, bytecodes)
        bytecodes

      cached ->
        cached
    end
  end

  defp compile_to_bytecode(source_list) do
    {:ok, rt} = QuickBEAM.start(apis: false)

    bytecodes =
      Enum.map(source_list, fn js ->
        {:ok, bc} = QuickBEAM.compile(rt, js)
        bc
      end)

    QuickBEAM.stop(rt)
    bytecodes
  end

  defp sync_load_bytecode(state, bytecode) do
    ref =
      QuickBEAM.Native.pool_load_bytecode(
        state.pool_resource,
        state.context_id,
        bytecode
      )

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

  def handle_call(:memory_usage, from, state) do
    ref = QuickBEAM.Native.pool_memory_usage(state.pool_resource, state.context_id)
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

  def handle_call({:get_global, name}, from, state) do
    ref = QuickBEAM.Native.pool_get_global(state.pool_resource, state.context_id, name)
    {:noreply, put_pending(state, ref, from, nil)}
  end

  def handle_call({:set_global, name, value}, _from, state) do
    QuickBEAM.Native.pool_define_global(state.pool_resource, state.context_id, name, value)
    {:reply, :ok, state}
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

        {:noreply, state}

      {:context_worker, action} ->
        handle_worker_call(action, args, call_id, state)

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

        {:noreply, state}
    end
  end

  def handle_info({:worker_started, worker_id, child_pid}, state) do
    ref = Process.monitor(child_pid)
    workers = Map.put(state.workers, ref, {child_pid, worker_id})
    {:noreply, %{state | workers: workers}}
  end

  def handle_info({:worker_msg, worker_id, data}, state) do
    QuickBEAM.Native.pool_send_message(
      state.pool_resource,
      state.context_id,
      ["__worker_msg", worker_id, data]
    )

    {:noreply, state}
  end

  def handle_info({:worker_error, worker_id, error}, state) do
    message =
      if is_struct(error), do: Map.get(error, :message, "Worker error"), else: "Worker error"

    QuickBEAM.Native.pool_send_message(
      state.pool_resource,
      state.context_id,
      ["__worker_err", worker_id, message]
    )

    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {_worker_id, workers} = Map.pop(state.workers, ref)
    {:noreply, %{state | workers: workers}}
  end

  def handle_info({ref, result}, state) when is_reference(ref) do
    handle_pending_ref(ref, result, state)
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    for {_ref, {pid, _id}} <- state.workers do
      Process.exit(pid, :shutdown)
    end

    QuickBEAM.Native.pool_destroy_context(state.pool_resource, state.context_id)
    :ok
  end

  # ── Worker lifecycle ──

  @worker_bootstrap """
  globalThis.self = globalThis;
  self.postMessage = function(data) {
    Beam.call("__worker_post", data);
  };
  Object.defineProperty(self, "onmessage", {
    set(handler) {
      Beam.onMessage(msg => handler({ data: msg }));
    },
    configurable: true,
  });
  """

  defp handle_worker_call(:spawn, args, call_id, state) do
    [script] = if is_list(args), do: args, else: [args]
    parent_pid = self()
    resource = state.pool_resource
    pool = state.pool

    worker_id = state.next_worker_id

    Task.start(fn ->
      {:ok, child} =
        QuickBEAM.Context.start_link(
          pool: pool,
          apis: false,
          handlers: %{
            "__worker_post" => fn [data] ->
              send(parent_pid, {:worker_msg, worker_id, data})
              nil
            end
          }
        )

      send(parent_pid, {:worker_started, worker_id, child})

      QuickBEAM.Context.eval(child, @worker_bootstrap)

      case QuickBEAM.Context.eval(child, script) do
        {:ok, _} -> :ok
        {:error, err} -> send(parent_pid, {:worker_error, worker_id, err})
      end
    end)

    QuickBEAM.Native.pool_resolve_call_term(resource, state.context_id, call_id, worker_id)
    {:noreply, %{state | next_worker_id: worker_id + 1}}
  end

  defp handle_worker_call(:terminate, args, call_id, state) do
    [worker_id] = if is_list(args), do: args, else: [args]

    case find_worker(state.workers, worker_id) do
      {ref, pid} ->
        Process.demonitor(ref, [:flush])

        Task.start(fn ->
          try do
            QuickBEAM.Context.stop(pid)
          catch
            :exit, _ -> :ok
          end
        end)

        workers = Map.delete(state.workers, ref)

        QuickBEAM.Native.pool_resolve_call_term(
          state.pool_resource,
          state.context_id,
          call_id,
          nil
        )

        {:noreply, %{state | workers: workers}}

      nil ->
        QuickBEAM.Native.pool_resolve_call_term(
          state.pool_resource,
          state.context_id,
          call_id,
          nil
        )

        {:noreply, state}
    end
  end

  defp handle_worker_call(:post_to_child, args, call_id, state) do
    [worker_id, data] = if is_list(args), do: args, else: [args]

    case find_worker(state.workers, worker_id) do
      {_ref, pid} ->
        QuickBEAM.Context.send_message(pid, data)

      nil ->
        :ok
    end

    QuickBEAM.Native.pool_resolve_call_term(
      state.pool_resource,
      state.context_id,
      call_id,
      nil
    )

    {:noreply, state}
  end

  defp find_worker(workers, worker_id) do
    Enum.find_value(workers, fn {ref, {pid, id}} ->
      if id == worker_id, do: {ref, pid}
    end)
  end

end
