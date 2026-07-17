defmodule QuickBEAM.VM do
  @moduledoc """
  Compile and validate QuickJS bytecode for execution by the BEAM engine.

  Programs are immutable and version-locked; each evaluation owns its frames,
  heap, Promise state, host operations, and resource limits.
  """

  alias QuickBEAM.VM.{
    ABI,
    Compiler,
    Decoder,
    Evaluator,
    Function,
    Measurement,
    Program,
    ProgramStore,
    PinnedProgram,
    Verifier
  }

  @type program :: QuickBEAM.VM.Program.t()
  @type pinned_program :: QuickBEAM.VM.PinnedProgram.t()

  @max_bytecode_bytes 16 * 1024 * 1024
  @default_timeout 5_000
  @default_memory_limit 64 * 1024 * 1024
  @worker_heap_overhead 4 * 1024 * 1024

  @doc """
  Compiles JavaScript with the vendored QuickJS compiler and returns a verified
  immutable program.

  A bare temporary native runtime is used until the dedicated compiler pool is
  introduced. Use `decode/2` when bytecode has already been compiled.
  """
  @spec compile(String.t(), keyword()) :: {:ok, program()} | {:error, term()}
  def compile(source, opts \\ []) when is_binary(source) and is_list(opts) do
    {runtime_options, opts} = Keyword.pop(opts, :runtime_options, [])
    {filename, decode_options} = Keyword.pop(opts, :filename)
    runtime_options = Keyword.put(runtime_options, :apis, false)

    with :ok <- validate_filename(filename),
         {:ok, runtime} <- QuickBEAM.start(runtime_options) do
      try do
        with {:ok, bytecode} <- QuickBEAM.compile(runtime, source),
             {:ok, program} <- decode(bytecode, decode_options) do
          program =
            program
            |> maybe_put_filename(filename)
            |> Map.put(:source_digest, :crypto.hash(:sha256, source))
            |> Program.put_pin_key()

          {:ok, program}
        end
      after
        QuickBEAM.stop(runtime)
      end
    end
  end

  @doc "Pins a verified program in bounded storage and returns a lightweight handle."
  @spec pin(Program.t()) :: {:ok, PinnedProgram.t()} | {:error, term()}
  def pin(%Program{} = program) do
    program = Program.put_pin_key(program)

    with :ok <- Verifier.verify(program) do
      case ProgramStore.pin(program) do
        {:ok, pinned} -> {:ok, pinned}
        {:error, reason} -> {:error, reason}
        :unavailable -> {:error, :pinned_program_capacity}
      end
    end
  end

  @doc "Decodes and verifies bytecode from this exact QuickJS build."
  @spec decode(binary(), keyword()) :: {:ok, program()} | {:error, term()}
  def decode(bytecode, opts \\ []) when is_binary(bytecode) and is_list(opts) do
    {max_bytecode_bytes, verifier_options} =
      Keyword.pop(opts, :max_bytecode_bytes, @max_bytecode_bytes)

    with :ok <- validate_max_bytecode_bytes(max_bytecode_bytes),
         :ok <- within_bytecode_limit(bytecode, max_bytecode_bytes),
         {:ok, program} <- Decoder.decode(bytecode),
         :ok <- Verifier.verify(program, verifier_options) do
      {:ok, Program.put_pin_key(program)}
    end
  end

  defp validate_max_bytecode_bytes(limit)
       when is_integer(limit) and limit > 0 and limit <= @max_bytecode_bytes,
       do: :ok

  defp validate_max_bytecode_bytes(limit),
    do: {:error, {:invalid_option, :max_bytecode_bytes, limit}}

  defp within_bytecode_limit(bytecode, limit) when byte_size(bytecode) <= limit, do: :ok

  defp within_bytecode_limit(bytecode, _limit),
    do: {:error, {:limit_exceeded, :bytecode_bytes, byte_size(bytecode)}}

  defp validate_filename(nil), do: :ok
  defp validate_filename(filename) when is_binary(filename), do: :ok
  defp validate_filename(filename), do: {:error, {:invalid_option, :filename, filename}}

  defp maybe_put_filename(program, nil), do: program

  defp maybe_put_filename(program, filename) when is_binary(filename),
    do: update_filename(program, filename)

  defp update_filename(%Function{} = function, filename) do
    constants = Enum.map(function.constants, &update_filename(&1, filename))
    %{function | filename: filename, constants: constants}
  end

  defp update_filename(%{root: root} = program, filename),
    do: %{program | root: update_filename(root, filename)}

  defp update_filename(value, _filename), do: value

  @doc """
  Evaluates a verified program in an isolated BEAM process.

  Supported options include the explicit `:engine` (`:interpreter` or
  `:compiler`), the experimental compiler `:compiler_profile` (`:pure_v1` by
  default or opt-in `:scalar_v1`), the quarantined `:compiler_regions` experiment,
  `:vars`, asynchronous `:handlers`, the builtin `:profile`
  (`:core` or `:ssr`), `:timeout`, `:max_steps`, `:max_stack_depth`, and the
  JavaScript allocation budget `:memory_limit`. Isolated workers also receive a
  BEAM process heap ceiling. `isolation: :caller` is available for trusted
  diagnostics. The compiler engine requires a supervised `QuickBEAM.VM.Compiler`.
  """
  @spec eval(Program.t() | PinnedProgram.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def eval(program, opts \\ [])

  def eval(%PinnedProgram{} = pinned, opts) when is_list(opts) do
    with {:ok, options} <- evaluation_options(opts),
         {:ok, lease} <- pinned_lease(pinned) do
      try do
        case options.isolation do
          :caller -> evaluate_pinned_caller(lease, options)
          :process -> eval_isolated_pinned(lease, options)
        end
      after
        ProgramStore.checkin(lease)
      end
    end
  end

  def eval(%Program{} = program, opts) when is_list(opts) do
    with :ok <- Verifier.verify(program),
         {:ok, options} <- evaluation_options(opts) do
      case options.isolation do
        :caller -> evaluate(program, options)
        :process -> eval_isolated(program, options)
      end
    end
  end

  @doc """
  Evaluates a program with the same isolation and limits as `eval/2`, returning
  its result together with deterministic step/logical-memory counters, bounded
  compiler telemetry when selected, and endpoint process observations.

  Evaluation failures, including resource limits, are stored in
  `measurement.result`. Invalid programs or options are returned directly as
  `{:error, reason}` because no evaluation was started.
  """
  @spec measure(Program.t() | PinnedProgram.t(), keyword()) ::
          {:ok, Measurement.t()} | {:error, term()}
  def measure(program, opts \\ [])

  def measure(%PinnedProgram{} = pinned, opts) when is_list(opts) do
    with {:ok, options} <- evaluation_options(opts),
         {:ok, lease} <- pinned_lease(pinned) do
      started = System.monotonic_time()

      payload =
        try do
          case options.isolation do
            :caller -> measure_pinned_caller(lease, options)
            :process -> measure_isolated_pinned(lease, options)
          end
        after
          ProgramStore.checkin(lease)
        end

      elapsed = System.monotonic_time() - started
      wall_time_us = System.convert_time_unit(elapsed, :native, :microsecond)
      {:ok, measurement(payload, wall_time_us)}
    end
  end

  def measure(%Program{} = program, opts) when is_list(opts) do
    with :ok <- Verifier.verify(program),
         {:ok, options} <- evaluation_options(opts) do
      started = System.monotonic_time()

      payload =
        case options.isolation do
          :caller -> safe_measure(program, options)
          :process -> measure_isolated(program, options)
        end

      elapsed = System.monotonic_time() - started
      wall_time_us = System.convert_time_unit(elapsed, :native, :microsecond)
      {:ok, measurement(payload, wall_time_us)}
    end
  end

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

    case Keyword.keys(opts) -- allowed do
      [] -> validate_evaluation_options(opts)
      [unknown | _] -> {:error, {:unknown_option, unknown}}
    end
  end

  defp validate_evaluation_options(opts) do
    isolation = Keyword.get(opts, :isolation, :process)
    engine = Keyword.get(opts, :engine, :interpreter)
    compiler_pool = Keyword.get(opts, :compiler_pool, QuickBEAM.VM.Compiler.ModulePool)
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

    cond do
      isolation not in [:caller, :process] ->
        {:error, {:invalid_option, :isolation, isolation}}

      engine not in [:interpreter, :compiler] ->
        {:error, {:invalid_option, :engine, engine}}

      not (is_atom(compiler_pool) or is_pid(compiler_pool)) ->
        {:error, {:invalid_option, :compiler_pool, compiler_pool}}

      compiler_profile not in [:pure_v1, :scalar_v1] ->
        {:error, {:invalid_option, :compiler_profile, compiler_profile}}

      not is_boolean(compiler_region_probe) ->
        {:error, {:invalid_option, :compiler_region_probe, compiler_region_probe}}

      not is_boolean(compiler_regions) ->
        {:error, {:invalid_option, :compiler_regions, compiler_regions}}

      timeout != :infinity and (not is_integer(timeout) or timeout <= 0) ->
        {:error, {:invalid_option, :timeout, timeout}}

      not is_integer(max_steps) or max_steps <= 0 ->
        {:error, {:invalid_option, :max_steps, max_steps}}

      not is_integer(max_stack_depth) or max_stack_depth <= 0 ->
        {:error, {:invalid_option, :max_stack_depth, max_stack_depth}}

      memory_limit != :infinity and (not is_integer(memory_limit) or memory_limit <= 0) ->
        {:error, {:invalid_option, :memory_limit, memory_limit}}

      profile not in [:core, :ssr] ->
        {:error, {:invalid_option, :profile, profile}}

      not is_map(vars) ->
        {:error, {:invalid_option, :vars, vars}}

      not is_map(handlers) or
          not Enum.all?(handlers, fn {name, handler} ->
            is_binary(name) and is_function(handler, 1)
          end) ->
        {:error, {:invalid_option, :handlers, handlers}}

      true ->
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

  defp pinned_lease(pinned) do
    case ProgramStore.checkout(pinned) do
      {:ok, lease} -> {:ok, lease}
      :unavailable -> {:error, :pinned_program_unavailable}
    end
  end

  defp evaluate_pinned_caller(lease, options) do
    with {:ok, program} <- ProgramStore.fetch(lease),
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

  defp eval_isolated(program, options), do: eval_isolated_program(program, options)

  defp eval_isolated_pinned(lease, options) do
    with {:ok, program} <- ProgramStore.fetch(lease),
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

  defp evaluate(program, %{engine: :interpreter, interpreter: options}),
    do: Evaluator.eval(program, Map.to_list(options))

  defp evaluate(program, %{engine: :compiler, interpreter: options}),
    do: Compiler.eval(program, Map.to_list(options))

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

  defp measure_isolated(program, options), do: measure_isolated_program(program, options)

  defp measure_isolated_pinned(lease, options) do
    case fetch_verified_pinned(lease) do
      {:ok, program} -> measure_isolated_program(program, options)
      {:error, reason} -> {:measured, {:error, reason}, nil}
    end
  end

  defp fetch_verified_pinned(lease) do
    with {:ok, program} <- ProgramStore.fetch(lease),
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

  defp safe_measure(program, %{engine: engine, interpreter: options}) do
    {result, metrics} = measure_engine(engine, program, Map.to_list(options))

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

  defp measure_engine(:interpreter, program, options),
    do: Evaluator.eval_with_metrics(program, options)

  defp measure_engine(:compiler, program, options),
    do: Compiler.eval_with_metrics(program, options)

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

  @doc "Unpins a bounded program slot after its current evaluations finish."
  @spec unpin(Program.t() | PinnedProgram.t()) :: :ok | :not_pinned
  def unpin(program)
      when is_struct(program, Program) or is_struct(program, PinnedProgram),
      do: ProgramStore.unpin(program)

  @doc "Returns the monitored worker spawn options for an evaluation memory limit."
  def worker_spawn_options(:infinity), do: [:monitor]

  def worker_spawn_options(memory_limit) do
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

  @doc "Returns the exact vendored QuickJS bytecode ABI fingerprint."
  defdelegate fingerprint(), to: ABI

  @doc "Returns the vendored QuickJS bytecode version."
  defdelegate bytecode_version(), to: ABI
end
