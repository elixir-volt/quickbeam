defmodule QuickBEAM.VM.Compiler do
  @moduledoc """
  Supervises and orchestrates the optional bounded BEAM compiler tier.

  Add this module to a supervision tree before selecting `engine: :compiler`:

      children = [
        {QuickBEAM.VM.Compiler, capacity: 8}
      ]

  Compiler execution remains explicit. Unsupported instructions deopt into the
  interpreter; compilation, capacity, loading, and lease failures are returned
  as typed compiler errors and never invoke native QuickJS.
  """

  alias QuickBEAM.VM.Compiler.Context
  alias QuickBEAM.VM.Compiler.Contract
  alias QuickBEAM.VM.Compiler.Counter
  alias QuickBEAM.VM.Compiler.Deopt
  alias QuickBEAM.VM.Compiler.Code
  alias QuickBEAM.VM.Compiler.Pool
  alias QuickBEAM.VM.Compiler.Region.Probe

  alias QuickBEAM.VM.Compiler.Profile.Pure
  alias QuickBEAM.VM.Runtime
  alias QuickBEAM.VM.Runtime.State
  alias QuickBEAM.VM.Runtime.Frame
  alias QuickBEAM.VM.Program.Function
  alias QuickBEAM.VM.Runtime.Interpreter
  alias QuickBEAM.VM.Program

  @type result :: {:ok, term()} | {:error, term()} | {:suspended, term()}
  @type frame_action ::
          {:deopt, term()}
          | {:invoke, term(), [term()], term(), struct(), struct(), false}
          | {:skip, struct(), struct()}
          | {:error, term()}

  @doc "Returns a child specification for the singleton generated-module pool."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: Pool,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  @doc "Starts the singleton compiler pool with the production generated-module backend."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    opts =
      opts
      |> Keyword.put_new(:backend, Code)
      |> Keyword.put_new(:task_supervisor, QuickBEAM.VM.TaskSupervisor)

    Pool.start_link(opts)
  end

  @doc "Evaluates a verified program through the selected bounded compiler profile."
  @spec eval(Program.t(), keyword()) :: result()
  def eval(%Program{} = program, opts \\ []) when is_list(opts) do
    program
    |> start(opts)
    |> Runtime.drive()
  end

  @doc "Evaluates through the compiler while collecting the standard deterministic counters."
  @spec eval_with_metrics(Program.t(), keyword()) :: {result(), map() | nil}
  def eval_with_metrics(%Program{} = program, opts \\ []) when is_list(opts) do
    reference = make_ref()
    result = eval(program, Keyword.put(opts, :measurement_target, {self(), reference}))

    receive do
      {:quickbeam_vm_measurement, ^reference, metrics} -> {result, metrics}
    after
      0 -> {result, nil}
    end
  end

  @doc "Starts compiled execution and returns a raw owner-local machine result."
  @spec start(Program.t(), keyword()) :: term()
  def start(%Program{root: %Function{}} = program, opts \\ []) when is_list(opts) do
    {frame, execution} = Interpreter.initialize(program, opts)
    pool = Keyword.get(opts, :compiler_pool, Pool)
    {:ok, artifact_namespace} = Contract.program_identity(program)

    context = %Context{
      artifact_namespace: artifact_namespace,
      counters: if(execution.measurement_target, do: Counter.new()),
      pool: pool,
      profile: Keyword.get(opts, :compiler_profile, :pure_v1),
      program: program,
      region_probe: if(Keyword.get(opts, :compiler_region_probe) == true, do: Probe.new()),
      regions: Keyword.get(opts, :compiler_regions, false)
    }

    execution = %{execution | compiler_context: context}

    frame
    |> Map.put(:compiler_entered, true)
    |> execute_frame(execution)
    |> resume_action(execution)
  end

  @doc "Compiles and invokes one entry block for a canonical bytecode frame."
  @spec execute_frame(struct(), struct()) :: frame_action()
  def execute_frame(
        %Frame{function: %Function{id: function_id} = function} = frame,
        %State{compiler_context: %Context{pool: pool}} = execution
      ) do
    execution = Counter.increment(execution, :frame_attempts)
    context = execution.compiler_context

    action =
      with :ok <- ensure_pool_available(pool) do
        case Map.fetch(context.decisions, function_id) do
          {:ok, :skip} ->
            prepare_region_frame(function, frame, execution)

          {:ok, {:compile, key, template}} ->
            invoke_frame(pool, key, template, frame, execution)

          {:ok, {:cached, key}} ->
            invoke_cached(pool, key, function, frame, execution)

          :error ->
            prepare_frame(function, frame, execution)
        end
      end

    observe_action(action)
  end

  defp prepare_frame(
         %Function{} = function,
         frame,
         %State{
           compiler_context: %Context{
             program: %Program{root: %Function{} = root} = program,
             min_nested_instructions: nested_minimum,
             profile: profile
           }
         } = execution
       ) do
    minimum = if function.id == root.id, do: 1, else: nested_minimum

    if Pure.candidate?(function, minimum, profile) do
      prepare_keyed_frame(program, function, minimum, profile, frame, execution)
    else
      execution = Counter.increment(execution, :skipped_functions)
      execution = cache_decision(execution, function.id, :skip)
      prepare_region_frame(function, frame, execution)
    end
  end

  defp prepare_keyed_frame(program, function, minimum, profile, frame, execution) do
    with {:ok, key} <- artifact_key(execution.compiler_context, program, function, profile) do
      case Pool.checkout_cached(execution.compiler_context.pool, key) do
        {:ok, lease} ->
          execution = Counter.increment(execution, :cached_functions)
          execution = cache_decision(execution, function.id, {:cached, key})
          invoke_lease(execution.compiler_context.pool, lease, frame, execution)

        :skip ->
          execution = Counter.increment(execution, :skipped_functions)
          execution = cache_decision(execution, function.id, :skip)
          prepare_region_frame(function, frame, execution)

        :miss ->
          prepare_uncached_frame(function, minimum, profile, key, frame, execution)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp artifact_key(
         %Context{artifact_namespace: namespace} = context,
         _program,
         function,
         profile
       )
       when is_binary(namespace),
       do:
         Contract.artifact_key_from_identity(namespace, function,
           profile: profile,
           region_preferred: context.regions and profile == :scalar_v1
         )

  defp artifact_key(context, program, function, profile),
    do:
      Contract.artifact_key(program, function,
        profile: profile,
        region_preferred: context.regions and profile == :scalar_v1
      )

  defp prepare_uncached_frame(function, minimum, profile, key, frame, execution) do
    case Pure.prepare(function, minimum, profile) do
      {:ok, template, _count} ->
        prepare_template(function, profile, key, template, frame, execution)

      {:skip, _count} ->
        skip_uncached_frame(function, key, frame, execution)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp prepare_template(function, :scalar_v1, key, template, frame, execution) do
    if Pure.scalar_template?(template) or not execution.compiler_context.regions do
      prepare_compiled_template(function, key, template, frame, execution)
    else
      skip_uncached_frame(function, key, frame, execution)
    end
  end

  defp prepare_template(function, _profile, key, template, frame, execution),
    do: prepare_compiled_template(function, key, template, frame, execution)

  defp prepare_compiled_template(function, key, template, frame, execution) do
    execution = Counter.increment(execution, :compiled_functions)
    execution = cache_decision(execution, function.id, {:compile, key, template})
    invoke_frame(execution.compiler_context.pool, key, template, frame, execution)
  end

  defp skip_uncached_frame(function, key, frame, execution) do
    with :ok <- Pool.remember_skip(execution.compiler_context.pool, key) do
      execution = Counter.increment(execution, :skipped_functions)
      execution = cache_decision(execution, function.id, :skip)
      prepare_region_frame(function, frame, execution)
    end
  end

  defp invoke_cached(pool, key, function, frame, execution) do
    case Pool.checkout_cached(pool, key) do
      {:ok, lease} ->
        invoke_lease(pool, lease, frame, execution)

      :skip ->
        execution = Counter.increment(execution, :skipped_functions)
        execution = cache_decision(execution, function.id, :skip)
        prepare_region_frame(function, frame, execution)

      :miss ->
        prepare_frame(function, frame, execution)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp prepare_region_frame(
         %Function{id: function_id} = function,
         %Frame{pc: 0} = frame,
         %State{compiler_context: %Context{profile: :scalar_v1, regions: true} = context} =
           execution
       ) do
    decision_key = {:region, function_id, 0}
    execution = Counter.increment(execution, :region_attempts)

    case Map.fetch(context.decisions, decision_key) do
      {:ok, :skip} ->
        {:skip, frame, execution}

      {:ok, {:compile, key, template}} ->
        invoke_frame(context.pool, key, template, frame, execution)

      {:ok, {:cached, key}} ->
        invoke_cached_region(key, decision_key, function, frame, execution)

      :error ->
        admit_region(decision_key, function, frame, execution)
    end
  end

  defp prepare_region_frame(_function, frame, execution), do: {:skip, frame, execution}

  defp admit_region(
         decision_key,
         %Function{id: function_id} = function,
         frame,
         %State{
           compiler_context: %Context{
             artifact_namespace: namespace,
             pool: pool,
             profile: profile
           }
         } = execution
       ) do
    with {:ok, admission_key} <-
           Contract.region_admission_key(namespace, function_id, frame.pc, profile) do
      case Pool.admit_region(pool, admission_key) do
        :cold ->
          {:skip, frame, Counter.increment(execution, :region_cold)}

        :hot ->
          execution = Counter.increment(execution, :region_hot)
          prepare_region_keyed(decision_key, function, frame, execution)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp prepare_region_keyed(
         decision_key,
         function,
         frame,
         %State{
           compiler_context: %Context{
             artifact_namespace: namespace,
             pool: pool,
             profile: profile
           }
         } = execution
       ) do
    with {:ok, key} <-
           Contract.artifact_key_from_identity(namespace, function,
             profile: profile,
             region_entry: frame.pc
           ) do
      case Pool.checkout_cached(pool, key) do
        {:ok, lease} ->
          execution = Counter.increment(execution, :cached_functions)
          execution = cache_decision(execution, decision_key, {:cached, key})
          invoke_lease(pool, lease, frame, execution)

        :skip ->
          execution = cache_decision(execution, decision_key, :skip)
          {:skip, frame, execution}

        :miss ->
          prepare_uncached_region(decision_key, key, function, frame, execution)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp prepare_uncached_region(decision_key, key, function, frame, execution) do
    profile = execution.compiler_context.profile

    case Pure.prepare_region(function, frame.pc, profile) do
      {:ok, template, _count} ->
        execution = Counter.increment(execution, :compiled_functions)
        execution = Counter.increment(execution, :region_compiled)
        execution = cache_decision(execution, decision_key, {:compile, key, template})

        case invoke_frame(execution.compiler_context.pool, key, template, frame, execution) do
          {:error, reason} -> {:error, {:region_compile_failed, function.id, frame.pc, reason}}
          action -> action
        end

      {:skip, _count} ->
        with :ok <- Pool.remember_skip(execution.compiler_context.pool, key) do
          {:skip, frame, cache_decision(execution, decision_key, :skip)}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp invoke_cached_region(key, decision_key, function, frame, execution) do
    pool = execution.compiler_context.pool

    case Pool.checkout_cached(pool, key) do
      {:ok, lease} -> invoke_lease(pool, lease, frame, execution)
      :skip -> {:skip, frame, cache_decision(execution, decision_key, :skip)}
      :miss -> prepare_region_keyed(decision_key, function, frame, execution)
      {:error, reason} -> {:error, reason}
    end
  end

  defp invoke_frame(pool, key, template, frame, execution) do
    with {:ok, lease} <- Pool.checkout(pool, key, template),
         do: invoke_lease(pool, lease, frame, execution)
  end

  defp invoke_lease(pool, lease, frame, execution) do
    execution = Counter.increment(execution, :generated_entries)
    remaining_steps = execution.remaining_steps

    pool
    |> Code.invoke(lease, frame, execution)
    |> add_generated_steps(remaining_steps)
  after
    safe_checkin(pool, lease)
  end

  defp cache_decision(%State{compiler_context: context} = execution, function_id, decision) do
    if map_size(context.decisions) < context.max_decisions do
      context = %{context | decisions: Map.put(context.decisions, function_id, decision)}
      %{execution | compiler_context: context}
    else
      execution
    end
  end

  defp observe_action({:deopt, %Deopt{} = deopt}) do
    execution = Counter.deopt(deopt.execution, deopt.reason, deopt.frame)
    {:deopt, %{deopt | execution: execution}}
  end

  defp observe_action({:invoke, callable, arguments, this, caller, execution, false}) do
    execution = Counter.increment(execution, :invocation_actions)
    {:invoke, callable, arguments, this, caller, execution, false}
  end

  defp observe_action({:skip, frame, execution}) do
    {:skip, frame, Counter.increment(execution, :skipped_frames)}
  end

  defp observe_action(action), do: action

  defp add_generated_steps(action, before) do
    update_action_execution(action, fn execution ->
      Counter.add_generated_steps(execution, max(before - execution.remaining_steps, 0))
    end)
  end

  defp update_action_execution({:deopt, %Deopt{} = deopt}, update) do
    {:deopt, %{deopt | execution: update.(deopt.execution)}}
  end

  defp update_action_execution(
         {:invoke, callable, arguments, this, caller, execution, false},
         update
       ) do
    {:invoke, callable, arguments, this, caller, update.(execution), false}
  end

  defp update_action_execution({status, value, %State{} = execution}, update)
       when status in [:ok, :error],
       do: {status, value, update.(execution)}

  defp update_action_execution(action, _update), do: action

  defp resume_action({:deopt, deopt}, _execution), do: Interpreter.resume_deopt_raw(deopt)

  defp resume_action(
         {:invoke, callable, arguments, this, caller, execution, false},
         _initial
       ),
       do: Interpreter.resume_compiler_invoke(callable, arguments, this, caller, execution)

  defp resume_action({:skip, frame, execution}, _initial),
    do: Interpreter.run_frame(frame, execution)

  defp resume_action({status, _value, %State{}} = result, _execution)
       when status in [:ok, :error], do: result

  defp resume_action({:suspended, _continuation} = result, _execution), do: result

  defp resume_action({:error, reason}, execution),
    do: {:error, {:compiler_error, reason}, execution}

  defp resume_action(action, execution),
    do: {:error, {:compiler_error, {:invalid_generated_action, action}}, execution}

  defp ensure_pool_available(pool) when is_pid(pool) do
    if Process.alive?(pool), do: :ok, else: {:error, {:compiler_pool_unavailable, pool}}
  end

  defp ensure_pool_available(pool) when is_atom(pool) do
    if is_pid(Process.whereis(pool)), do: :ok, else: {:error, {:compiler_pool_unavailable, pool}}
  end

  defp ensure_pool_available(pool), do: {:error, {:compiler_pool_unavailable, pool}}

  defp safe_checkin(pool, lease) do
    Pool.checkin_active(pool, lease)
  catch
    :exit, _reason -> :ok
  end
end
