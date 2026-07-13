defmodule QuickBEAM.VM do
  @moduledoc """
  Compile and validate QuickJS bytecode for execution by the BEAM engine.

  Programs are immutable and version-locked; each evaluation owns its frames,
  heap, Promise state, host operations, and resource limits.
  """

  alias QuickBEAM.VM.{ABI, Decoder, Evaluator, Function, Measurement, Program, Verifier}

  @type program :: QuickBEAM.VM.Program.t()

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
          {:ok, maybe_put_filename(program, filename)}
        end
      after
        QuickBEAM.stop(runtime)
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
      {:ok, program}
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

  Supported options include `:vars`, asynchronous `:handlers`, the builtin
  `:profile` (`:core` or `:ssr`), `:timeout`, `:max_steps`, `:max_stack_depth`, and the JavaScript allocation budget
  `:memory_limit`. Isolated workers also receive a BEAM process heap ceiling.
  `isolation: :caller` is available for
  trusted diagnostics.
  """
  @spec eval(Program.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def eval(%Program{} = program, opts \\ []) when is_list(opts) do
    with :ok <- Verifier.verify(program),
         {:ok, options} <- evaluation_options(opts) do
      case options.isolation do
        :caller -> Evaluator.eval(program, Map.to_list(options.interpreter))
        :process -> eval_isolated(program, options)
      end
    end
  end

  @doc """
  Evaluates a program with the same isolation and limits as `eval/2`, returning
  its result together with deterministic step/logical-memory counters and
  endpoint process observations.

  Evaluation failures, including resource limits, are stored in
  `measurement.result`. Invalid programs or options are returned directly as
  `{:error, reason}` because no evaluation was started.
  """
  @spec measure(Program.t(), keyword()) :: {:ok, Measurement.t()} | {:error, term()}
  def measure(%Program{} = program, opts \\ []) when is_list(opts) do
    with :ok <- Verifier.verify(program),
         {:ok, options} <- evaluation_options(opts) do
      started = System.monotonic_time()

      payload =
        case options.isolation do
          :caller -> safe_measure(program, options.interpreter)
          :process -> measure_isolated(program, options)
        end

      elapsed = System.monotonic_time() - started
      wall_time_us = System.convert_time_unit(elapsed, :native, :microsecond)
      {:ok, measurement(payload, wall_time_us)}
    end
  end

  defp evaluation_options(opts) do
    allowed = [
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
           memory_limit: memory_limit,
           timeout: timeout,
           interpreter: %{
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

  defp eval_isolated(program, options) do
    caller = self()
    reply_ref = make_ref()

    worker = fn ->
      result = safe_interpret(program, options.interpreter)
      send(caller, {reply_ref, result})
    end

    {pid, monitor_ref} = :erlang.spawn_opt(worker, worker_spawn_options(options.memory_limit))

    await_evaluation(pid, monitor_ref, reply_ref, options.timeout, options.memory_limit)
  end

  defp safe_interpret(program, options) do
    case Evaluator.eval(program, Map.to_list(options)) do
      {:suspended, _continuation} -> {:error, {:unsupported, :async_wait}}
      result -> result
    end
  rescue
    exception -> {:error, {:interpreter_crash, exception, __STACKTRACE__}}
  catch
    kind, reason -> {:error, {:interpreter_crash, {kind, reason}, __STACKTRACE__}}
  end

  defp measure_isolated(program, options) do
    caller = self()
    reply_ref = make_ref()

    worker = fn ->
      payload = safe_measure(program, options.interpreter)
      send(caller, {reply_ref, payload})
    end

    {pid, monitor_ref} = :erlang.spawn_opt(worker, worker_spawn_options(options.memory_limit))

    case await_evaluation(pid, monitor_ref, reply_ref, options.timeout, options.memory_limit) do
      {:measured, _result, _metrics} = measured -> measured
      {:error, _reason} = error -> {:measured, error, nil}
    end
  end

  defp safe_measure(program, options) do
    {result, metrics} = Evaluator.eval_with_metrics(program, Map.to_list(options))

    result =
      if match?({:suspended, _continuation}, result),
        do: {:error, {:unsupported, :async_wait}},
        else: result

    {:measured, result, metrics}
  rescue
    exception -> {:measured, {:error, {:interpreter_crash, exception, __STACKTRACE__}}, nil}
  catch
    kind, reason ->
      {:measured, {:error, {:interpreter_crash, {kind, reason}, __STACKTRACE__}}, nil}
  end

  defp measurement({:measured, result, metrics}, wall_time_us) do
    metrics = metrics || %{}

    %Measurement{
      result: result,
      wall_time_us: wall_time_us,
      steps: Map.get(metrics, :steps),
      logical_memory_bytes: Map.get(metrics, :logical_memory_bytes),
      process_memory_bytes: Map.get(metrics, :process_memory_bytes),
      reductions: Map.get(metrics, :reductions)
    }
  end

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
