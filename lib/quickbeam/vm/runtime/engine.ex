defmodule QuickBEAM.VM.Runtime.Engine do
  @moduledoc """
  Contains internal interpreter/compiler selection and evaluation containment.

  The public `QuickBEAM.VM` facade selects only the interpreter. Compiler tests
  and benchmarks use this module explicitly while the compiler remains
  release-quarantined and filtered from public ExDoc output.
  """

  alias QuickBEAM.VM.Bytecode.Verifier
  alias QuickBEAM.VM.Compiler
  alias QuickBEAM.VM.Options
  alias QuickBEAM.VM.Program
  alias QuickBEAM.VM.Program.Pinned
  alias QuickBEAM.VM.Program.Store
  alias QuickBEAM.VM.Runtime
  alias QuickBEAM.VM.Runtime.Engine.Measurement

  @default_timeout 5_000
  @default_memory_limit 64 * 1024 * 1024
  @worker_heap_overhead 4 * 1024 * 1024

  @type option ::
          QuickBEAM.VM.evaluation_option()
          | {:engine, :interpreter | :compiler}
          | {:compiler_pool, GenServer.server()}
          | {:compiler_profile, :pure_v1 | :scalar_v1}
          | {:compiler_region_probe, boolean()}
          | {:compiler_regions, boolean()}

  @doc "Evaluates through an explicitly selected internal engine."
  @spec eval(Program.t() | Pinned.t(), [option()]) :: QuickBEAM.VM.result(term())
  def eval(program, opts \\ []), do: execute(program, opts, :eval)

  @doc "Calls a named global through an explicitly selected internal engine."
  @spec call(Program.t() | Pinned.t(), String.t(), [term()], [option()]) ::
          QuickBEAM.VM.result(term())
  def call(program, name, arguments \\ [], opts \\ [])

  def call(program, name, arguments, opts)
      when is_binary(name) and is_list(arguments),
      do: execute(program, opts, {:call, name, arguments})

  def call(_program, name, _arguments, _opts) when not is_binary(name),
    do: {:error, :invalid_function_name}

  def call(_program, _name, arguments, _opts) when not is_list(arguments),
    do: {:error, :invalid_arguments}

  @doc "Measures an explicitly selected internal engine evaluation."
  @spec measure(Program.t() | Pinned.t(), [option()]) :: QuickBEAM.VM.result(Measurement.t())
  def measure(program, opts \\ []), do: measure_request(program, opts, :eval)

  @doc "Measures a named global call through an explicitly selected internal engine."
  @spec measure_call(Program.t() | Pinned.t(), String.t(), [term()], [option()]) ::
          QuickBEAM.VM.result(Measurement.t())
  def measure_call(program, name, arguments \\ [], opts \\ [])

  def measure_call(program, name, arguments, opts)
      when is_binary(name) and is_list(arguments),
      do: measure_request(program, opts, {:call, name, arguments})

  def measure_call(_program, name, _arguments, _opts) when not is_binary(name),
    do: {:error, :invalid_function_name}

  def measure_call(_program, _name, arguments, _opts) when not is_list(arguments),
    do: {:error, :invalid_arguments}

  defp execute(%Pinned{} = pinned, opts, request) when is_list(opts) do
    with {:ok, options} <- evaluation_options(opts),
         {:ok, lease} <- pinned_lease(pinned) do
      options = Map.put(options, :request, request)

      try do
        case options.isolation do
          :caller -> evaluate_pinned_caller(lease, options)
          :process -> eval_isolated_pinned(lease, options)
        end
      after
        Store.checkin(lease)
      end
    end
  end

  defp execute(%Program{} = program, opts, request) when is_list(opts) do
    with :ok <- Verifier.verify(program),
         {:ok, options} <- evaluation_options(opts) do
      options = Map.put(options, :request, request)

      case options.isolation do
        :caller -> evaluate(program, options)
        :process -> eval_isolated_program(program, options)
      end
    end
  end

  defp execute(program, _opts, _request)
       when not is_struct(program, Program) and not is_struct(program, Pinned),
       do: {:error, :invalid_program}

  defp execute(_program, opts, _request), do: {:error, {:invalid_options, opts}}

  defp measure_request(%Pinned{} = pinned, opts, request) when is_list(opts) do
    with {:ok, options} <- evaluation_options(opts),
         {:ok, lease} <- pinned_lease(pinned) do
      options = Map.put(options, :request, request)
      started = System.monotonic_time()

      payload =
        try do
          case options.isolation do
            :caller -> measure_pinned_caller(lease, options)
            :process -> measure_isolated_pinned(lease, options)
          end
        after
          Store.checkin(lease)
        end

      elapsed = System.monotonic_time() - started
      wall_time_us = System.convert_time_unit(elapsed, :native, :microsecond)
      {:ok, measurement(payload, wall_time_us)}
    end
  end

  defp measure_request(%Program{} = program, opts, request) when is_list(opts) do
    with :ok <- Verifier.verify(program),
         {:ok, options} <- evaluation_options(opts) do
      options = Map.put(options, :request, request)
      started = System.monotonic_time()

      payload =
        case options.isolation do
          :caller -> safe_measure(program, options)
          :process -> measure_isolated_program(program, options)
        end

      elapsed = System.monotonic_time() - started
      wall_time_us = System.convert_time_unit(elapsed, :native, :microsecond)
      {:ok, measurement(payload, wall_time_us)}
    end
  end

  defp measure_request(program, _opts, _request)
       when not is_struct(program, Program) and not is_struct(program, Pinned),
       do: {:error, :invalid_program}

  defp measure_request(_program, opts, _request), do: {:error, {:invalid_options, opts}}

  defp evaluation_options(opts) do
    allowed = [
      :compiler_pool,
      :compiler_profile,
      :compiler_region_probe,
      :compiler_regions,
      :engine,
      :handlers,
      :isolation,
      :max_stack_depth,
      :max_steps,
      :memory_limit,
      :profile,
      :timeout,
      :vars
    ]

    with :ok <- Options.validate(opts, allowed) do
      validate_evaluation_options(opts)
    end
  end

  defp validate_evaluation_options(opts) do
    isolation = Keyword.get(opts, :isolation, :process)
    engine = Keyword.get(opts, :engine, :interpreter)
    compiler_pool = Keyword.get(opts, :compiler_pool, QuickBEAM.VM.Compiler.Pool)
    compiler_profile = Keyword.get(opts, :compiler_profile, :pure_v1)
    compiler_region_probe = Keyword.get(opts, :compiler_region_probe, false)
    compiler_regions = Keyword.get(opts, :compiler_regions, false)
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    max_steps = Keyword.get(opts, :max_steps, 5_000_000)
    max_stack_depth = Keyword.get(opts, :max_stack_depth, 1_000)
    memory_limit = Keyword.get(opts, :memory_limit, @default_memory_limit)
    profile = Keyword.get(opts, :profile, :core)
    vars = Keyword.get(opts, :vars, %{})
    handlers = Keyword.get(opts, :handlers, %{})

    with :ok <- validate_member(:isolation, isolation, [:caller, :process]),
         :ok <- validate_member(:engine, engine, [:interpreter, :compiler]),
         :ok <- validate_server(compiler_pool),
         :ok <- validate_member(:compiler_profile, compiler_profile, [:pure_v1, :scalar_v1]),
         :ok <- validate_boolean(:compiler_region_probe, compiler_region_probe),
         :ok <- validate_boolean(:compiler_regions, compiler_regions),
         :ok <- validate_limit(:timeout, timeout),
         :ok <- validate_positive(:max_steps, max_steps),
         :ok <- validate_positive(:max_stack_depth, max_stack_depth),
         :ok <- validate_limit(:memory_limit, memory_limit),
         :ok <- validate_member(:profile, profile, [:core, :ssr]),
         :ok <- validate_map(:vars, vars),
         :ok <- validate_handlers(handlers) do
      {:ok,
       %{
         isolation: isolation,
         engine: engine,
         memory_limit: memory_limit,
         timeout: timeout,
         interpreter: %{
           compiler_pool: compiler_pool,
           compiler_profile: compiler_profile,
           compiler_region_probe: compiler_region_probe,
           compiler_regions: compiler_regions,
           handlers: handlers,
           max_steps: max_steps,
           max_stack_depth: max_stack_depth,
           memory_limit: memory_limit,
           profile: profile,
           vars: vars
         }
       }}
    end
  end

  defp validate_member(name, value, allowed) do
    if value in allowed, do: :ok, else: {:error, {:invalid_option, name, value}}
  end

  defp validate_server(server) when is_atom(server) or is_pid(server), do: :ok
  defp validate_server(server), do: {:error, {:invalid_option, :compiler_pool, server}}

  defp validate_boolean(_name, value) when is_boolean(value), do: :ok
  defp validate_boolean(name, value), do: {:error, {:invalid_option, name, value}}

  defp validate_limit(_name, :infinity), do: :ok
  defp validate_limit(name, value), do: validate_positive(name, value)

  defp validate_positive(_name, value) when is_integer(value) and value > 0, do: :ok
  defp validate_positive(name, value), do: {:error, {:invalid_option, name, value}}

  defp validate_map(_name, value) when is_map(value), do: :ok
  defp validate_map(name, value), do: {:error, {:invalid_option, name, value}}

  defp validate_handlers(handlers) when is_map(handlers) do
    if Enum.all?(handlers, fn {name, handler} ->
         is_binary(name) and is_function(handler, 1)
       end),
       do: :ok,
       else: {:error, {:invalid_option, :handlers, handlers}}
  end

  defp validate_handlers(handlers), do: {:error, {:invalid_option, :handlers, handlers}}

  defp pinned_lease(pinned) do
    case Store.checkout(pinned) do
      {:ok, lease} -> {:ok, lease}
      :unavailable -> {:error, :pinned_program_unavailable}
    end
  end

  defp evaluate_pinned_caller(lease, options) do
    with {:ok, program} <- Store.fetch(lease),
         :ok <- Verifier.verify_identity(program) do
      evaluate(program, options)
    end
  end

  defp measure_pinned_caller(lease, options) do
    case fetch_verified_pinned(lease) do
      {:ok, program} -> safe_measure(program, options)
      {:error, reason} -> {:measured, {:error, reason}, nil}
    end
  end

  defp eval_isolated_pinned(lease, options) do
    with {:ok, program} <- Store.fetch(lease),
         :ok <- Verifier.verify_identity(program) do
      eval_isolated_program(program, options)
    end
  end

  defp eval_isolated_program(program, options) do
    caller = self()
    reply_ref = make_ref()

    worker = fn -> send(caller, {reply_ref, safe_evaluate(program, options)}) end
    {pid, monitor_ref} = :erlang.spawn_opt(worker, worker_spawn_options(options.memory_limit))
    await_evaluation(pid, monitor_ref, reply_ref, options.timeout, options.memory_limit)
  end

  defp evaluate(program, %{engine: :interpreter, interpreter: options, request: :eval}),
    do: Runtime.eval(program, Map.to_list(options))

  defp evaluate(
         program,
         %{engine: :interpreter, interpreter: options, request: {:call, name, arguments}}
       ),
       do: Runtime.call(program, name, arguments, Map.to_list(options))

  defp evaluate(program, %{engine: :compiler, interpreter: options, request: :eval}),
    do: Compiler.eval(program, Map.to_list(options))

  defp evaluate(_program, %{engine: :compiler, request: {:call, _name, _arguments}}),
    do: {:error, {:unsupported, :compiler_call}}

  defp safe_evaluate(program, options) do
    case evaluate(program, options) do
      {:suspended, _continuation} -> {:error, {:unsupported, :async_wait}}
      result -> result
    end
  rescue
    exception -> {:error, {engine_crash(options.engine), exception, __STACKTRACE__}}
  catch
    kind, reason -> {:error, {engine_crash(options.engine), {kind, reason}, __STACKTRACE__}}
  end

  defp measure_isolated_pinned(lease, options) do
    case fetch_verified_pinned(lease) do
      {:ok, program} -> measure_isolated_program(program, options)
      {:error, reason} -> {:measured, {:error, reason}, nil}
    end
  end

  defp fetch_verified_pinned(lease) do
    with {:ok, program} <- Store.fetch(lease),
         :ok <- Verifier.verify_identity(program),
         do: {:ok, program}
  end

  defp measure_isolated_program(program, options) do
    caller = self()
    reply_ref = make_ref()
    worker = fn -> send(caller, {reply_ref, safe_measure(program, options)}) end
    {pid, monitor_ref} = :erlang.spawn_opt(worker, worker_spawn_options(options.memory_limit))
    await_measurement(pid, monitor_ref, reply_ref, options)
  end

  defp await_measurement(pid, monitor_ref, reply_ref, options) do
    case await_evaluation(pid, monitor_ref, reply_ref, options.timeout, options.memory_limit) do
      {:measured, _result, _metrics} = measured -> measured
      {:error, _reason} = error -> {:measured, error, nil}
    end
  end

  defp safe_measure(program, %{engine: engine, interpreter: options, request: request}) do
    {result, metrics} = measure_engine(engine, program, Map.to_list(options), request)

    result =
      if match?({:suspended, _continuation}, result),
        do: {:error, {:unsupported, :async_wait}},
        else: result

    {:measured, result, metrics}
  rescue
    exception -> {:measured, {:error, {engine_crash(engine), exception, __STACKTRACE__}}, nil}
  catch
    kind, reason ->
      {:measured, {:error, {engine_crash(engine), {kind, reason}, __STACKTRACE__}}, nil}
  end

  defp measure_engine(:interpreter, program, options, :eval),
    do: Runtime.eval_with_metrics(program, options)

  defp measure_engine(:interpreter, program, options, {:call, name, arguments}),
    do: Runtime.call_with_metrics(program, name, arguments, options)

  defp measure_engine(:compiler, program, options, :eval),
    do: Compiler.eval_with_metrics(program, options)

  defp measure_engine(:compiler, _program, _options, {:call, _name, _arguments}),
    do: {{:error, {:unsupported, :compiler_call}}, nil}

  defp engine_crash(:interpreter), do: :interpreter_crash
  defp engine_crash(:compiler), do: :compiler_crash

  defp measurement({:measured, result, metrics}, wall_time_us) do
    metrics = metrics || %{}

    %Measurement{
      result: result,
      wall_time_us: wall_time_us,
      steps: Map.get(metrics, :steps),
      logical_memory_bytes: Map.get(metrics, :logical_memory_bytes),
      compiler_counters: Map.get(metrics, :compiler_counters),
      compiler_regions: Map.get(metrics, :compiler_regions),
      process_memory_bytes: Map.get(metrics, :process_memory_bytes),
      reductions: Map.get(metrics, :reductions)
    }
  end

  defp worker_spawn_options(:infinity), do: [:monitor]

  defp worker_spawn_options(memory_limit) do
    word_size = :erlang.system_info(:wordsize)
    max_heap_words = div(memory_limit + @worker_heap_overhead + word_size - 1, word_size)

    [
      :monitor,
      {:max_heap_size, %{size: max_heap_words, kill: true, error_logger: false}}
    ]
  end

  defp await_evaluation(pid, monitor_ref, reply_ref, :infinity, memory_limit) do
    receive do
      {^reply_ref, result} ->
        Process.demonitor(monitor_ref, [:flush])
        result

      {:DOWN, ^monitor_ref, :process, ^pid, reason} ->
        evaluation_exit(reason, memory_limit)
    end
  end

  defp await_evaluation(pid, monitor_ref, reply_ref, timeout, memory_limit) do
    receive do
      {^reply_ref, result} ->
        Process.demonitor(monitor_ref, [:flush])
        result

      {:DOWN, ^monitor_ref, :process, ^pid, reason} ->
        evaluation_exit(reason, memory_limit)
    after
      timeout ->
        Process.exit(pid, :kill)
        await_down(monitor_ref, pid)
        flush_reply(reply_ref)
        {:error, {:limit_exceeded, :timeout, timeout}}
    end
  end

  defp evaluation_exit(:killed, memory_limit) when is_integer(memory_limit),
    do: {:error, {:limit_exceeded, :memory_bytes, memory_limit}}

  defp evaluation_exit(reason, _memory_limit),
    do: {:error, {:evaluation_process_exit, reason}}

  defp await_down(monitor_ref, pid) do
    receive do
      {:DOWN, ^monitor_ref, :process, ^pid, _reason} -> :ok
    after
      1_000 -> Process.demonitor(monitor_ref, [:flush])
    end
  end

  defp flush_reply(reply_ref) do
    receive do
      {^reply_ref, _result} -> :ok
    after
      0 -> :ok
    end
  end
end
