defmodule QuickBEAM.VM do
  @moduledoc """
  Compiles and executes verified QuickJS bytecode with an isolated BEAM interpreter.

  Programs are immutable and version-locked. Each evaluation owns its frames,
  heap, Promise state, host operations, and resource limits. The optional BEAM
  compiler is an internal, release-quarantined subsystem and is not selected
  through this public facade.

  ## Execution model and limitations

  `eval/2` and `call/4` create fresh mutable JavaScript state for every request.
  `call/4` runs program initialization and then invokes its named global in that
  same fresh state; unlike `QuickBEAM.call/4`, mutations do not persist across
  calls. Programs and bytecode are locked to the exact vendored QuickJS ABI and
  must be recompiled after an incompatible upgrade.

  The interpreter implements bounded, explicitly tested bytecode and builtin
  profiles rather than every native QuickJS, browser, Node.js, DOM, WASM, or
  addon feature. Unsupported behavior fails without native fallback.
  `:memory_limit` governs deterministic logical VM allocation, while endpoint
  BEAM process memory is reported separately by measurement APIs. An
  evaluation may have at most 64 asynchronous BEAM handler operations
  outstanding at once. Pinned storage is fixed-capacity, explicitly retired,
  and never implicitly evicted.
  """

  alias QuickBEAM.VM.ABI
  alias QuickBEAM.VM.Bytecode.Decoder
  alias QuickBEAM.VM.Bytecode.Verifier
  alias QuickBEAM.VM.Measurement
  alias QuickBEAM.VM.Options
  alias QuickBEAM.VM.Program
  alias QuickBEAM.VM.Program.Function
  alias QuickBEAM.VM.Program.Identity
  alias QuickBEAM.VM.Program.Pinned
  alias QuickBEAM.VM.Program.Store
  alias QuickBEAM.VM.Runtime.Engine

  @type program :: Program.t()
  @type pinned_program :: Pinned.t()
  @type verifier_option ::
          {:max_atoms, pos_integer()}
          | {:max_constants_per_function, pos_integer()}
          | {:max_function_depth, pos_integer()}
          | {:max_functions, pos_integer()}
          | {:max_instructions, pos_integer()}
          | {:max_stack_size, pos_integer()}
  @type compile_option ::
          {:filename, String.t()} | {:max_bytecode_bytes, pos_integer()} | verifier_option()
  @type decode_option :: {:max_bytecode_bytes, pos_integer()} | verifier_option()
  @type evaluation_option ::
          {:vars, map()}
          | {:handlers, %{optional(String.t()) => ([term()] -> term())}}
          | {:profile, :core | :ssr}
          | {:timeout, pos_integer() | :infinity}
          | {:max_steps, pos_integer()}
          | {:max_stack_depth, pos_integer()}
          | {:memory_limit, pos_integer() | :infinity}
          | {:isolation, :process | :caller}
  @type error_reason ::
          :invalid_program
          | :invalid_source
          | :invalid_bytecode
          | :invalid_function_name
          | :invalid_arguments
          | :invalid_pinned_program
          | :pinned_program_capacity
          | :pinned_program_unavailable
          | :program_too_large
          | :residency_budget
          | {:invalid_options, term()}
          | {:unknown_option, atom()}
          | {:invalid_option, atom(), term()}
          | {:limit_exceeded, atom(), term()}
          | {:unsupported, term()}
          | {:evaluation_process_exit, term()}
          | tuple()
          | atom()
  @type result(value) :: {:ok, value} | {:error, QuickBEAM.JSError.t() | error_reason()}

  @max_bytecode_bytes 16 * 1024 * 1024
  @verifier_options [
    :max_atoms,
    :max_constants_per_function,
    :max_function_depth,
    :max_functions,
    :max_instructions,
    :max_stack_size
  ]
  @decode_options [:max_bytecode_bytes | @verifier_options]
  @compile_options [:filename | @decode_options]
  @evaluation_options [
    :handlers,
    :isolation,
    :max_stack_depth,
    :max_steps,
    :memory_limit,
    :profile,
    :timeout,
    :vars
  ]

  @doc """
  Compiles JavaScript with the vendored QuickJS compiler and returns a verified
  immutable program.

  Compilation uses a short-lived bare native runtime. Supported options are
  `:filename`, `:max_bytecode_bytes`, and the bounded verifier limit options.
  Use `decode/2` when bytecode has already been compiled by this exact QuickJS
  build.
  """
  @spec compile(String.t(), [compile_option()]) :: result(program())
  def compile(source, opts \\ [])

  def compile(source, opts) when is_binary(source) and is_list(opts) do
    with :ok <- Options.validate(opts, @compile_options),
         {filename, decode_options} = Keyword.pop(opts, :filename),
         :ok <- validate_filename(filename),
         {:ok, runtime} <- QuickBEAM.start(apis: false) do
      try do
        with {:ok, bytecode} <- QuickBEAM.compile(runtime, source),
             {:ok, program} <- decode(bytecode, decode_options) do
          program =
            program
            |> maybe_put_filename(filename)
            |> Map.put(:source_digest, :crypto.hash(:sha256, source))
            |> Identity.put()

          {:ok, program}
        end
      after
        QuickBEAM.stop(runtime)
      end
    end
  end

  def compile(source, _opts) when not is_binary(source), do: {:error, :invalid_source}
  def compile(_source, opts), do: {:error, {:invalid_options, opts}}

  @doc """
  Decodes and verifies bytecode from this exact QuickJS build.

  The `:max_bytecode_bytes` option and bounded verifier limits can only reduce
  the built-in maximums; unknown options fail explicitly.
  """
  @spec decode(binary(), [decode_option()]) :: result(program())
  def decode(bytecode, opts \\ [])

  def decode(bytecode, opts) when is_binary(bytecode) and is_list(opts) do
    with :ok <- Options.validate(opts, @decode_options),
         {max_bytecode_bytes, verifier_options} =
           Keyword.pop(opts, :max_bytecode_bytes, @max_bytecode_bytes),
         :ok <- validate_max_bytecode_bytes(max_bytecode_bytes),
         :ok <- within_bytecode_limit(bytecode, max_bytecode_bytes),
         {:ok, program} <- Decoder.decode(bytecode),
         :ok <- Verifier.verify(program, verifier_options) do
      {:ok, Identity.put(program)}
    end
  end

  def decode(bytecode, _opts) when not is_binary(bytecode), do: {:error, :invalid_bytecode}
  def decode(_bytecode, opts), do: {:error, {:invalid_options, opts}}

  @doc """
  Pins a verified program in bounded immutable storage.

  The default store has eight fixed slots. Serialized bytecode is limited to
  2 MiB, decoded external-term residency to 32 MiB per program, and total
  residency to 128 MiB. Concurrent pins of the same program identity are
  idempotent and return the same lightweight handle. The application-supervised
  store restores valid slots after its own restart; call `unpin/1` explicitly
  when the lifecycle owner no longer needs the program.
  """
  @spec pin(Program.t()) :: result(Pinned.t())
  def pin(%Program{} = program) do
    program = Identity.put(program)

    with :ok <- Verifier.verify(program) do
      case Store.pin(program) do
        {:ok, pinned} -> {:ok, pinned}
        {:error, reason} -> {:error, reason}
        :retiring -> {:error, :pinned_program_unavailable}
        :unavailable -> {:error, :pinned_program_capacity}
      end
    end
  end

  def pin(_program), do: {:error, :invalid_program}

  @doc """
  Evaluates a verified program with the isolated BEAM interpreter.

  Supported options are `:vars`, asynchronous `:handlers`, builtin `:profile`,
  `:timeout`, `:max_steps`, `:max_stack_depth`, `:memory_limit`, and
  `:isolation`. The default `isolation: :process` provides timeout, process-heap,
  and failure containment. `isolation: :caller` is only for trusted diagnostics.
  """
  @spec eval(Program.t() | Pinned.t(), [evaluation_option()]) :: result(term())
  def eval(program, opts \\ [])

  def eval(program, opts) when is_list(opts) do
    with :ok <- Options.validate(opts, @evaluation_options) do
      Engine.eval(program, Keyword.put(opts, :engine, :interpreter))
    end
  end

  def eval(_program, opts), do: {:error, {:invalid_options, opts}}

  @doc """
  Initializes a fresh isolated heap and calls a named global JavaScript function.

  Program initialization runs before every call, so globals mutated by one call
  are not visible to the next. Arguments and Promise results use the same value
  conversion, asynchronous handlers, isolation, and resource limits as `eval/2`.
  Missing globals produce `ReferenceError`; non-callable globals produce
  `TypeError`.
  """
  @spec call(Program.t() | Pinned.t(), String.t(), [term()], [evaluation_option()]) ::
          result(term())
  def call(program, name, arguments \\ [], opts \\ [])

  def call(program, name, arguments, opts)
      when is_binary(name) and is_list(arguments) and is_list(opts) do
    with :ok <- Options.validate(opts, @evaluation_options) do
      Engine.call(program, name, arguments, Keyword.put(opts, :engine, :interpreter))
    end
  end

  def call(_program, name, _arguments, _opts) when not is_binary(name),
    do: {:error, :invalid_function_name}

  def call(_program, _name, arguments, _opts) when not is_list(arguments),
    do: {:error, :invalid_arguments}

  def call(_program, _name, _arguments, opts), do: {:error, {:invalid_options, opts}}

  @doc """
  Evaluates with the same isolation and limits as `eval/2` and returns resource
  observations in a `QuickBEAM.VM.Measurement`.

  Evaluation failures are stored in `measurement.result`. Invalid programs or
  options return directly as `{:error, reason}` because no evaluation started.
  """
  @spec measure(Program.t() | Pinned.t(), [evaluation_option()]) :: result(Measurement.t())
  def measure(program, opts \\ [])

  def measure(program, opts) when is_list(opts) do
    with :ok <- Options.validate(opts, @evaluation_options),
         {:ok, measurement} <-
           Engine.measure(program, Keyword.put(opts, :engine, :interpreter)) do
      {:ok, public_measurement(measurement)}
    end
  end

  def measure(_program, opts), do: {:error, {:invalid_options, opts}}

  @doc """
  Calls a named global with the same fresh initialization and limits as `call/4`
  and returns resource observations in a `QuickBEAM.VM.Measurement`.

  Call failures are stored in `measurement.result`. Invalid names, arguments,
  programs, or options return directly because no evaluation started.
  """
  @spec measure_call(
          Program.t() | Pinned.t(),
          String.t(),
          [term()],
          [evaluation_option()]
        ) :: result(Measurement.t())
  def measure_call(program, name, arguments \\ [], opts \\ [])

  def measure_call(program, name, arguments, opts)
      when is_binary(name) and is_list(arguments) and is_list(opts) do
    with :ok <- Options.validate(opts, @evaluation_options),
         {:ok, measurement} <-
           Engine.measure_call(
             program,
             name,
             arguments,
             Keyword.put(opts, :engine, :interpreter)
           ) do
      {:ok, public_measurement(measurement)}
    end
  end

  def measure_call(_program, name, _arguments, _opts) when not is_binary(name),
    do: {:error, :invalid_function_name}

  def measure_call(_program, _name, arguments, _opts) when not is_list(arguments),
    do: {:error, :invalid_arguments}

  def measure_call(_program, _name, _arguments, opts),
    do: {:error, {:invalid_options, opts}}

  @doc """
  Unpins a handle after its current evaluations finish.

  Returns `{:error, :pinned_program_unavailable}` when the handle is stale.
  Because pins are idempotent by program identity rather than ownership-counted,
  one lifecycle owner should coordinate pinning and unpinning.
  """
  @spec unpin(Pinned.t()) ::
          :ok | {:error, :pinned_program_unavailable | :invalid_pinned_program}
  def unpin(%Pinned{} = pinned) do
    case Store.unpin(pinned) do
      :ok -> :ok
      :not_pinned -> {:error, :pinned_program_unavailable}
    end
  end

  def unpin(_pinned), do: {:error, :invalid_pinned_program}

  @doc "Returns the exact vendored QuickJS bytecode ABI fingerprint."
  @spec fingerprint() :: String.t()
  defdelegate fingerprint(), to: ABI

  @doc "Returns the vendored QuickJS bytecode version."
  @spec bytecode_version() :: non_neg_integer()
  defdelegate bytecode_version(), to: ABI

  defp public_measurement(measurement) do
    struct(Measurement, Map.from_struct(measurement))
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
end
