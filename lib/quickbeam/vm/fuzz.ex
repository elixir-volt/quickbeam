defmodule QuickBEAM.VM.Fuzz.Mutation do
  @moduledoc """
  Describes one reproducible decoder or verifier mutation.

  The original corpus value is intentionally not retained. Replaying the same
  corpus entry with `seed` and `iteration` reconstructs `value` exactly.
  """

  @enforce_keys [:domain, :corpus, :seed, :iteration, :operation, :value]
  defstruct [:domain, :corpus, :seed, :iteration, :operation, :value, details: %{}]

  @type t :: %__MODULE__{
          domain: :bytecode | :program,
          corpus: String.t(),
          seed: non_neg_integer(),
          iteration: non_neg_integer(),
          operation: atom(),
          value: binary() | QuickBEAM.VM.Program.t(),
          details: map()
        }
end

defmodule QuickBEAM.VM.Fuzz.Finding do
  @moduledoc "A reproducible crash, timeout, nondeterminism, or verifier acceptance."

  @enforce_keys [:mutation, :outcome]
  defstruct [:mutation, :outcome]

  @type t :: %__MODULE__{
          mutation: QuickBEAM.VM.Fuzz.Mutation.t(),
          outcome: term()
        }
end

defmodule QuickBEAM.VM.Fuzz.Summary do
  @moduledoc "Aggregated result of a bounded mutation-fuzzing run."

  @enforce_keys [:domain, :seed, :iterations, :counts, :operation_counts, :findings]
  defstruct [:domain, :seed, :iterations, :counts, :operation_counts, :findings]

  @type t :: %__MODULE__{
          domain: :bytecode | :program,
          seed: non_neg_integer(),
          iterations: non_neg_integer(),
          counts: %{optional(atom()) => non_neg_integer()},
          operation_counts: %{optional(atom()) => non_neg_integer()},
          findings: [QuickBEAM.VM.Fuzz.Finding.t()]
        }
end

defmodule QuickBEAM.VM.Fuzz do
  @moduledoc """
  Deterministic, bounded mutation fuzzing for the VM decoder and verifier.

  Every case executes twice in a monitored process with a wall-clock timeout
  and BEAM maximum-heap limit. Decoder mutations preserve the QuickJS envelope
  checksum unless checksum or version handling is the mutation target. Program
  mutations are deliberately invalid and therefore must be rejected by the
  verifier.

  A failure is replayed from its corpus name, seed, and iteration. The PRNG is
  implemented here rather than delegated to `:rand`, keeping corpus generation
  stable across OTP upgrades.
  """

  import Bitwise

  alias QuickBEAM.VM.Checksum
  alias QuickBEAM.VM.Fuzz.Finding
  alias QuickBEAM.VM.Fuzz.Mutation
  alias QuickBEAM.VM.Fuzz.Summary
  alias QuickBEAM.VM.Opcodes
  alias QuickBEAM.VM.Program
  alias QuickBEAM.VM.Verifier

  @mask 0xFFFFFFFFFFFFFFFF
  @default_iterations 1_000
  @default_timeout 100
  @default_max_heap_bytes 16 * 1024 * 1024
  @default_max_findings 20
  @max_iterations 1_000_000
  @run_options [:iterations, :max_findings, :max_heap_bytes, :seed, :timeout, :verify_options]

  @bytecode_operations [
    :truncate,
    :delete,
    :insert,
    :duplicate,
    :flip_bit,
    :overwrite,
    :unterminated_leb128,
    :overflowing_leb128,
    :oversized_count,
    :unknown_byte,
    :trailing_byte,
    :bad_checksum,
    :bad_version
  ]

  @default_sources [
    {"control-flow", "function choose(x) { return x > 2 ? x * 3 : x - 1 } choose(4)"},
    {"closures", "function outer(x) { return y => x + y } outer(20)(22)"},
    {"objects", "const value = {a: [1, , 3], r: /a+/gi, n: 12345678901234567890n}; value.a[2]"},
    {"exceptions",
     "function guarded(x) { try { if (x) throw new Error('x'); } catch (e) { return e.message; } } guarded(true)"},
    {"async",
     "async function answer() { const x = await Promise.resolve(40); return x + 2 } answer()"}
  ]

  @program_operations [
    :bad_version,
    :bad_fingerprint,
    :invalid_atom_table,
    :invalid_source_positions,
    :invalid_local_count,
    :invalid_defined_args,
    :negative_stack_size,
    :unknown_opcode,
    :invalid_instruction_shape,
    :invalid_operand_type,
    :invalid_constant,
    :invalid_atom,
    :invalid_jump,
    :invalid_exception_target,
    :stack_underflow,
    :stack_size_mismatch,
    :invalid_capture
  ]

  @doc "Returns the representative source corpus used by CI and the Mix task."
  @spec default_sources() :: [{String.t(), String.t()}]
  def default_sources, do: @default_sources

  @doc "Runs deterministic mutations over named serialized-bytecode seeds."
  @spec run_bytecode([{String.t(), binary()}], keyword()) ::
          {:ok, Summary.t()} | {:error, term()}
  def run_bytecode(corpus, opts \\ []) do
    with {:ok, config} <- validate_run(corpus, opts),
         :ok <- validate_bytecode_corpus(corpus) do
      run(:bytecode, corpus, config, fn {name, bytecode}, iteration ->
        bytecode_mutation(name, bytecode, config.seed, iteration)
      end)
    end
  end

  @doc "Runs deliberately invalid mutations over named verified programs."
  @spec run_verifier([{String.t(), Program.t()}], keyword()) ::
          {:ok, Summary.t()} | {:error, term()}
  def run_verifier(corpus, opts \\ []) do
    with {:ok, config} <- validate_run(corpus, opts),
         :ok <- validate_program_corpus(corpus) do
      run(:program, corpus, config, fn {name, program}, iteration ->
        program_mutation(name, program, config.seed, iteration)
      end)
    end
  end

  @doc "Builds one reproducible checksum-aware bytecode mutation."
  @spec bytecode_mutation(String.t(), binary(), non_neg_integer(), non_neg_integer()) ::
          Mutation.t()
  def bytecode_mutation(name, bytecode, seed, iteration)
      when is_binary(name) and is_binary(bytecode) and is_integer(seed) and seed >= 0 and
             is_integer(iteration) and iteration >= 0 do
    state = initial_state(seed, iteration)
    operation = Enum.at(@bytecode_operations, rem(iteration, length(@bytecode_operations)))
    {value, details} = mutate_bytecode(bytecode, operation, state)

    %Mutation{
      domain: :bytecode,
      corpus: name,
      seed: seed,
      iteration: iteration,
      operation: operation,
      value: value,
      details: details
    }
  end

  @doc "Builds one reproducible invalid program mutation."
  @spec program_mutation(String.t(), Program.t(), non_neg_integer(), non_neg_integer()) ::
          Mutation.t()
  def program_mutation(name, %Program{} = program, seed, iteration)
      when is_binary(name) and is_integer(seed) and seed >= 0 and is_integer(iteration) and
             iteration >= 0 do
    operation = Enum.at(@program_operations, rem(iteration, length(@program_operations)))
    value = mutate_program(program, operation, initial_state(seed, iteration))

    %Mutation{
      domain: :program,
      corpus: name,
      seed: seed,
      iteration: iteration,
      operation: operation,
      value: value
    }
  end

  @doc "Runs one serialized input twice under the harness resource bounds."
  @spec probe_bytecode(binary(), keyword()) :: {:ok, term()} | {:error, term()}
  def probe_bytecode(bytecode, opts \\ [])

  def probe_bytecode(bytecode, opts) when is_binary(bytecode) do
    with {:ok, config} <-
           validate_run([{"probe", bytecode}], Keyword.put(opts, :iterations, 1)) do
      mutation = %Mutation{
        domain: :bytecode,
        corpus: "probe",
        seed: 0,
        iteration: 0,
        operation: :replay,
        value: bytecode
      }

      {:ok, execute(mutation, config)}
    end
  end

  def probe_bytecode(bytecode, _opts), do: {:error, {:invalid_bytecode, bytecode}}

  @doc "Returns true when a completed run found no safety or verification failures."
  @spec safe?(Summary.t()) :: boolean()
  def safe?(%Summary{findings: findings}), do: findings == []

  @doc """
  Minimizes a bytecode safety finding with bounded deletion-based reduction.

  Reduction preserves the failure category rather than an unstable exception
  stack. `:max_attempts` defaults to 256 and uses the same timeout and heap
  options as a normal run.
  """
  @spec minimize(Finding.t(), keyword()) :: {:ok, Finding.t()} | {:error, term()}
  def minimize(finding, opts \\ [])

  def minimize(%Finding{mutation: %Mutation{domain: :bytecode} = mutation} = finding, opts) do
    with {:ok, config} <- minimizer_config(opts),
         target when target in [:crash, :timeout, :nondeterministic] <-
           outcome_category(finding.outcome),
         :ok <- ensure_reproduced(mutation, target, config) do
      {value, _attempts} =
        minimize_binary(mutation.value, target, config, 2, 0)

      minimized = %{mutation | value: value, details: Map.put(mutation.details, :minimized, true)}
      {:ok, %Finding{finding | mutation: minimized, outcome: execute(minimized, config)}}
    else
      category when is_atom(category) -> {:error, {:not_a_safety_finding, category}}
      {:error, _} = error -> error
    end
  end

  def minimize(%Finding{}, _opts), do: {:error, :unsupported_finding}

  defp ensure_reproduced(mutation, target, config) do
    actual = mutation |> execute(config) |> outcome_category()
    if actual == target, do: :ok, else: {:error, {:not_reproducible, target, actual}}
  end

  @doc "Persists a minimized bytecode finding and human-readable replay metadata."
  @spec persist(Finding.t(), Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def persist(%Finding{mutation: %Mutation{domain: :bytecode} = mutation} = finding, directory)
      when is_binary(directory) do
    digest = :crypto.hash(:sha256, mutation.value) |> Base.encode16(case: :lower)

    basename =
      "#{safe_name(mutation.corpus)}-#{mutation.seed}-#{mutation.iteration}-#{String.slice(digest, 0, 12)}"

    binary_path = Path.join(directory, basename <> ".bin")
    metadata_path = Path.join(directory, basename <> ".txt")

    metadata = """
    corpus: #{mutation.corpus}
    seed: #{mutation.seed}
    iteration: #{mutation.iteration}
    operation: #{mutation.operation}
    outcome: #{inspect(finding.outcome)}
    sha256: #{digest}
    """

    with :ok <- File.mkdir_p(directory),
         :ok <- File.write(binary_path, mutation.value),
         :ok <- File.write(metadata_path, metadata) do
      {:ok, binary_path}
    end
  end

  def persist(%Finding{}, directory), do: {:error, {:invalid_directory, directory}}

  @simple_error_classes %{
    unexpected_end: :truncated,
    malformed_debug_info: :truncated,
    checksum_mismatch: :checksum,
    bad_leb128: :malformed_integer,
    bad_sleb128: :malformed_integer,
    integer_overflow: :malformed_integer
  }

  @doc "Maps decoder and verifier errors to stable, coarse failure classes."
  @spec classify_error(term()) :: atom()
  def classify_error(reason) when is_atom(reason),
    do: Map.get(@simple_error_classes, reason, :other_rejection)

  def classify_error({:bad_version, _version}), do: :version
  def classify_error({:limit_exceeded, _kind, _count}), do: :limit
  def classify_error({:unknown_tag, _tag}), do: :unknown_tag
  def classify_error({:unknown_opcode, _opcode, _offset}), do: :unknown_opcode
  def classify_error({:truncated_instruction, _opcode, _offset}), do: :truncated_instruction
  def classify_error({:invalid_label, _label}), do: :invalid_jump
  def classify_error({:trailing_bytes, _count}), do: :trailing_data

  def classify_error({:invalid_instruction, _function, _index, nested}),
    do: classify_error(nested)

  def classify_error({:invalid_stack, _function, nested}), do: classify_error(nested)
  def classify_error({:stack_underflow, _index, _depth, _pops}), do: :stack_underflow
  def classify_error({:stack_size_mismatch, _declared}), do: :invalid_stack
  def classify_error({:inconsistent_stack, _index, _existing, _incoming}), do: :invalid_stack
  def classify_error({:invalid_fallthrough, _index}), do: :invalid_stack
  def classify_error({:missing_catch, _index}), do: :invalid_stack
  def classify_error({:unknown_opcode, _opcode}), do: :unknown_opcode
  def classify_error({:invalid_index, :label, _index}), do: :invalid_jump
  def classify_error({:invalid_index, _kind, _index}), do: :invalid_reference
  def classify_error({:invalid_var_ref, _function, _index}), do: :invalid_reference
  def classify_error({:invalid_function, _function, _reason}), do: :invalid_structure
  def classify_error({:invalid_program, _reason}), do: :invalid_structure
  def classify_error({:invalid_local_count, _actual, _expected}), do: :invalid_structure
  def classify_error(_reason), do: :other_rejection

  defp run(domain, corpus, config, mutation_fun) do
    initial = %Summary{
      domain: domain,
      seed: config.seed,
      iterations: config.iterations,
      counts: %{},
      operation_counts: %{},
      findings: []
    }

    summary =
      Enum.reduce(0..(config.iterations - 1), initial, fn iteration, summary ->
        corpus_entry = Enum.at(corpus, rem(iteration, length(corpus)))
        mutation = mutation_fun.(corpus_entry, iteration)
        outcome = execute(mutation, config)
        record(summary, mutation, outcome, config.max_findings)
      end)

    {:ok, %{summary | findings: Enum.reverse(summary.findings)}}
  end

  defp execute(%Mutation{domain: domain, value: value}, config) do
    operation = fn -> normalize_result(domain, value, config.verify_options) end
    isolated_repeat(operation, config.timeout, config.max_heap_bytes)
  end

  defp normalize_result(:bytecode, bytecode, verify_options) do
    case QuickBEAM.VM.decode(bytecode, verify_options) do
      {:ok, _program} -> :accepted
      {:error, reason} -> {:rejected, classify_error(reason), reason}
    end
  end

  defp normalize_result(:program, program, verify_options) do
    case Verifier.verify(program, verify_options) do
      :ok -> :accepted_invalid_program
      {:error, reason} -> {:rejected, classify_error(reason), reason}
    end
  end

  defp isolated_repeat(operation, timeout, max_heap_bytes) do
    parent = self()
    words = max(div(max_heap_bytes, :erlang.system_info(:wordsize)), 1)

    {pid, monitor} =
      :erlang.spawn_opt(
        fn ->
          first = operation.()
          second = operation.()

          send(
            parent,
            {self(), if(first == second, do: first, else: {:nondeterministic, first, second})}
          )
        end,
        [:monitor, {:max_heap_size, %{size: words, kill: true, error_logger: false}}]
      )

    receive do
      {^pid, outcome} ->
        Process.demonitor(monitor, [:flush])
        outcome

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        {:crash, reason}
    after
      timeout ->
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
        after
          timeout -> :ok
        end

        {:timeout, timeout}
    end
  end

  defp record(summary, mutation, outcome, max_findings) do
    category = outcome_category(outcome)

    summary = %{
      summary
      | counts: Map.update(summary.counts, category, 1, &(&1 + 1)),
        operation_counts: Map.update(summary.operation_counts, mutation.operation, 1, &(&1 + 1))
    }

    if finding?(mutation.domain, outcome) and length(summary.findings) < max_findings do
      %{summary | findings: [%Finding{mutation: mutation, outcome: outcome} | summary.findings]}
    else
      summary
    end
  end

  defp outcome_category(:accepted), do: :accepted
  defp outcome_category(:accepted_invalid_program), do: :accepted_invalid_program
  defp outcome_category({:rejected, category, _reason}), do: category
  defp outcome_category({:timeout, _}), do: :timeout
  defp outcome_category({:crash, _}), do: :crash
  defp outcome_category({:nondeterministic, _, _}), do: :nondeterministic

  defp finding?(:bytecode, outcome),
    do:
      match?({kind, _} when kind in [:timeout, :crash], outcome) or
        match?({:nondeterministic, _, _}, outcome)

  defp finding?(:program, :accepted_invalid_program), do: true
  defp finding?(:program, outcome), do: finding?(:bytecode, outcome)

  defp mutate_bytecode(<<version, checksum::binary-size(4), payload::binary>>, operation, state) do
    case operation do
      :bad_checksum ->
        {<<version, flip_checksum(checksum)::binary, payload::binary>>, %{offset: 1}}

      :bad_version ->
        {envelope(rem(version + 1, 256), payload), %{offset: 0}}

      _ ->
        {mutated, details} = mutate_payload(payload, operation, state)
        {envelope(version, mutated), details}
    end
  end

  defp mutate_bytecode(bytecode, operation, state) do
    mutate_payload(bytecode, operation, state)
  end

  defp mutate_payload(payload, :truncate, state) do
    {length, _state} = choose(state, byte_size(payload) + 1)
    {binary_part(payload, 0, length), %{offset: length}}
  end

  defp mutate_payload(payload, :delete, state) do
    with_nonempty(payload, state, fn offset, state ->
      {extra, _state} = choose(state, min(8, byte_size(payload) - offset))
      count = extra + 1
      {remove(payload, offset, count), %{offset: offset, count: count}}
    end)
  end

  defp mutate_payload(payload, :insert, state) do
    {offset, state} = choose(state, byte_size(payload) + 1)
    {count0, state} = choose(state, 8)
    {bytes, _state} = random_bytes(state, count0 + 1)
    {insert(payload, offset, bytes), %{offset: offset, count: byte_size(bytes)}}
  end

  defp mutate_payload(payload, :duplicate, state) do
    with_nonempty(payload, state, fn offset, state ->
      {extra, state} = choose(state, min(8, byte_size(payload) - offset))
      count = extra + 1
      {target, _state} = choose(state, byte_size(payload) + 1)
      bytes = binary_part(payload, offset, count)
      {insert(payload, target, bytes), %{offset: target, source_offset: offset, count: count}}
    end)
  end

  defp mutate_payload(payload, :flip_bit, state) do
    with_nonempty(payload, state, fn offset, state ->
      {bit, _state} = choose(state, 8)
      original = :binary.at(payload, offset)
      {replace(payload, offset, 1, <<bxor(original, 1 <<< bit)>>), %{offset: offset, bit: bit}}
    end)
  end

  defp mutate_payload(payload, :overwrite, state) do
    with_nonempty(payload, state, fn offset, state ->
      {value, _state} = choose(state, 256)
      {replace(payload, offset, 1, <<value>>), %{offset: offset, value: value}}
    end)
  end

  defp mutate_payload(payload, :unterminated_leb128, state),
    do: insert_sequence(payload, state, <<0x80, 0x80, 0x80, 0x80, 0x80>>)

  defp mutate_payload(payload, :overflowing_leb128, state),
    do: insert_sequence(payload, state, <<0xFF, 0xFF, 0xFF, 0xFF, 0x1F>>)

  defp mutate_payload(payload, :oversized_count, state),
    do: insert_sequence(payload, state, <<0xA1, 0x8D, 0x06>>)

  defp mutate_payload(payload, :unknown_byte, state),
    do: insert_sequence(payload, state, <<0xFF>>)

  defp mutate_payload(payload, :trailing_byte, state),
    do: {payload <> <<elem(choose(state, 256), 0)>>, %{offset: byte_size(payload)}}

  defp mutate_payload(payload, _operation, _state), do: {payload, %{}}

  defp insert_sequence(payload, state, bytes) do
    {offset, _state} = choose(state, byte_size(payload) + 1)
    {insert(payload, offset, bytes), %{offset: offset, count: byte_size(bytes)}}
  end

  defp with_nonempty(<<>>, _state, _fun), do: {<<0>>, %{offset: 0}}

  defp with_nonempty(payload, state, fun) do
    {offset, state} = choose(state, byte_size(payload))
    fun.(offset, state)
  end

  defp envelope(version, payload) do
    checksum = Checksum.calculate(payload)
    <<version, checksum::little-unsigned-32, payload::binary>>
  end

  defp flip_checksum(<<first, rest::binary>>), do: <<bxor(first, 1), rest::binary>>

  defp insert(binary, offset, bytes) do
    <<left::binary-size(^offset), right::binary>> = binary
    left <> bytes <> right
  end

  defp remove(binary, offset, count), do: replace(binary, offset, count, <<>>)

  defp replace(binary, offset, count, replacement) do
    <<left::binary-size(^offset), _removed::binary-size(^count), right::binary>> = binary
    left <> replacement <> right
  end

  defp mutate_program(program, :bad_version, _state),
    do: %{program | version: program.version + 1}

  defp mutate_program(program, :bad_fingerprint, _state),
    do: %{program | fingerprint: program.fingerprint <> "-mutated"}

  defp mutate_program(program, :invalid_atom_table, _state), do: %{program | atoms: []}

  defp mutate_program(program, operation, state) do
    %{program | root: mutate_function(program.root, operation, program.atoms, state)}
  end

  defp mutate_function(function, :invalid_source_positions, _atoms, _state),
    do: %{function | source_positions: {}}

  defp mutate_function(function, :invalid_local_count, _atoms, _state),
    do: %{function | var_count: function.var_count + 1}

  defp mutate_function(function, :invalid_defined_args, _atoms, _state),
    do: %{function | defined_arg_count: function.arg_count + 1}

  defp mutate_function(function, :negative_stack_size, _atoms, _state),
    do: %{function | stack_size: -1}

  defp mutate_function(function, :unknown_opcode, _atoms, _state),
    do: replace_instruction(function, {256, []})

  defp mutate_function(function, :invalid_instruction_shape, _atoms, _state),
    do: replace_instruction(function, :not_an_instruction)

  defp mutate_function(function, :invalid_operand_type, _atoms, _state),
    do: replace_instruction(function, {Opcodes.num(:push_i32), [:not_an_integer]})

  defp mutate_function(function, :invalid_constant, _atoms, _state) do
    instruction = {Opcodes.num(:push_const), [length(function.constants)]}
    replace_instruction(function, instruction)
  end

  defp mutate_function(function, :invalid_atom, atoms, _state) do
    instruction = {Opcodes.num(:get_var), [tuple_size(atoms)]}
    replace_instruction(function, instruction)
  end

  defp mutate_function(function, :invalid_jump, _atoms, _state) do
    instruction = {Opcodes.num(:goto), [tuple_size(function.instructions)]}
    replace_instruction(function, instruction)
  end

  defp mutate_function(function, :invalid_exception_target, _atoms, _state) do
    instruction = {Opcodes.num(:catch), [tuple_size(function.instructions)]}
    replace_instruction(function, instruction)
  end

  defp mutate_function(function, :stack_underflow, _atoms, _state),
    do: replace_instruction(function, {Opcodes.num(:drop), []})

  defp mutate_function(function, :stack_size_mismatch, _atoms, _state),
    do: %{function | stack_size: function.stack_size + 1}

  defp mutate_function(function, :invalid_capture, _atoms, _state) do
    case function.locals do
      [local | rest] ->
        local = %{local | is_captured: true, var_ref_idx: function.var_ref_count}
        %{function | locals: [local | rest]}

      [] ->
        replace_instruction(
          function,
          {Opcodes.num(:get_var_ref), [length(function.closure_vars)]}
        )
    end
  end

  defp mutate_function(function, _operation, _atoms, _state), do: function

  defp replace_instruction(function, instruction) do
    instructions =
      case tuple_size(function.instructions) do
        0 -> {instruction}
        _ -> put_elem(function.instructions, 0, instruction)
      end

    %{function | instructions: instructions}
  end

  defp minimizer_config(opts) when is_list(opts) do
    {max_attempts, run_options} = Keyword.pop(opts, :max_attempts, 256)

    with true <- is_integer(max_attempts) and max_attempts > 0 and max_attempts <= 10_000,
         {:ok, config} <-
           validate_run([{"minimizer", <<>>}], Keyword.put(run_options, :iterations, 1)) do
      {:ok, Map.put(config, :max_attempts, max_attempts)}
    else
      false -> invalid_option(:max_attempts, max_attempts)
      {:error, _} = error -> error
    end
  end

  defp minimizer_config(opts), do: invalid_option(:options, opts)

  defp minimize_binary(binary, _target, config, _granularity, attempts)
       when attempts >= config.max_attempts or byte_size(binary) <= 6,
       do: {binary, attempts}

  defp minimize_binary(
         <<version, _checksum::binary-size(4), payload::binary>> = binary,
         target,
         config,
         granularity,
         attempts
       ) do
    payload_size = byte_size(payload)
    granularity = min(granularity, max(payload_size, 1))
    chunk_size = max(div(payload_size + granularity - 1, granularity), 1)

    result =
      0..(granularity - 1)
      |> Enum.reduce_while({:none, attempts}, fn index, accumulator ->
        attempt_reduction(
          index,
          accumulator,
          version,
          payload,
          payload_size,
          chunk_size,
          target,
          config
        )
      end)

    case result do
      {{:reduced, candidate}, attempts} ->
        minimize_binary(candidate, target, config, max(granularity - 1, 2), attempts)

      {:none, attempts} when granularity < payload_size ->
        minimize_binary(binary, target, config, min(granularity * 2, payload_size), attempts)

      {:none, attempts} ->
        {binary, attempts}
    end
  end

  defp minimize_binary(binary, _target, _config, _granularity, attempts), do: {binary, attempts}

  defp attempt_reduction(
         index,
         {:none, attempts},
         version,
         payload,
         payload_size,
         chunk_size,
         target,
         config
       ) do
    offset = index * chunk_size
    count = min(chunk_size, max(payload_size - offset, 0))

    if count == 0 or attempts >= config.max_attempts do
      {:halt, {:none, attempts}}
    else
      reduction_outcome(version, payload, offset, count, attempts, target, config)
    end
  end

  defp reduction_outcome(version, payload, offset, count, attempts, target, config) do
    candidate = envelope(version, remove(payload, offset, count))

    mutation = %Mutation{
      domain: :bytecode,
      corpus: "minimizer",
      seed: 0,
      iteration: attempts,
      operation: :delete,
      value: candidate
    }

    if mutation |> execute(config) |> outcome_category() == target,
      do: {:halt, {{:reduced, candidate}, attempts + 1}},
      else: {:cont, {:none, attempts + 1}}
  end

  defp safe_name(name) do
    name
    |> String.to_charlist()
    |> Enum.reduce({[], false}, fn character, {characters, separator?} ->
      cond do
        safe_name_character?(character) -> {[character | characters], false}
        separator? -> {characters, true}
        true -> {[?- | characters], true}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
    |> to_string()
    |> String.trim("-")
    |> case do
      "" -> "corpus"
      safe -> safe
    end
  end

  defp safe_name_character?(character) when character in ?a..?z, do: true
  defp safe_name_character?(character) when character in ?A..?Z, do: true
  defp safe_name_character?(character) when character in ?0..?9, do: true
  defp safe_name_character?(character) when character in [?_, ?-], do: true
  defp safe_name_character?(_character), do: false

  defp validate_run(corpus, opts) when is_list(corpus) and is_list(opts) do
    if Keyword.keyword?(opts),
      do: do_validate_run(corpus, opts),
      else: {:error, :invalid_arguments}
  end

  defp validate_run(_corpus, _opts), do: {:error, :invalid_arguments}

  defp do_validate_run(corpus, opts) do
    config = %{
      seed: Keyword.get(opts, :seed, 0x51424D),
      iterations: Keyword.get(opts, :iterations, @default_iterations),
      timeout: Keyword.get(opts, :timeout, @default_timeout),
      max_heap_bytes: Keyword.get(opts, :max_heap_bytes, @default_max_heap_bytes),
      max_findings: Keyword.get(opts, :max_findings, @default_max_findings),
      verify_options: Keyword.get(opts, :verify_options, [])
    }

    with :ok <- validate_corpus_names(corpus),
         :ok <- validate_option_keys(opts),
         :ok <- validate_seed(config.seed),
         :ok <- validate_iterations(config.iterations),
         :ok <- validate_timeout(config.timeout),
         :ok <- validate_max_heap_bytes(config.max_heap_bytes),
         :ok <- validate_max_findings(config.max_findings),
         :ok <- validate_verify_options(config.verify_options) do
      {:ok, config}
    end
  end

  defp validate_corpus_names([]), do: {:error, :empty_corpus}

  defp validate_corpus_names(corpus) do
    if Enum.all?(corpus, &valid_corpus_entry?/1),
      do: :ok,
      else: {:error, :invalid_corpus}
  end

  defp validate_option_keys(opts) do
    case Keyword.keys(opts) -- @run_options do
      [] -> :ok
      [key | _rest] -> {:error, {:unknown_option, key}}
    end
  end

  defp validate_seed(value) when is_integer(value) and value >= 0, do: :ok
  defp validate_seed(value), do: invalid_option(:seed, value)

  defp validate_iterations(value)
       when is_integer(value) and value > 0 and value <= @max_iterations,
       do: :ok

  defp validate_iterations(value), do: invalid_option(:iterations, value)

  defp validate_timeout(value) when is_integer(value) and value > 0 and value <= 5_000, do: :ok
  defp validate_timeout(value), do: invalid_option(:timeout, value)

  defp validate_max_heap_bytes(value) when is_integer(value) and value >= 1024 * 1024,
    do: :ok

  defp validate_max_heap_bytes(value), do: invalid_option(:max_heap_bytes, value)

  defp validate_max_findings(value) when is_integer(value) and value > 0, do: :ok
  defp validate_max_findings(value), do: invalid_option(:max_findings, value)

  defp validate_verify_options(value) when is_list(value), do: :ok
  defp validate_verify_options(value), do: invalid_option(:verify_options, value)

  defp valid_corpus_entry?({name, _value}), do: is_binary(name)
  defp valid_corpus_entry?(_entry), do: false

  defp validate_bytecode_corpus(corpus) do
    if Enum.all?(corpus, fn {_name, value} -> is_binary(value) end),
      do: :ok,
      else: {:error, :invalid_corpus}
  end

  defp validate_program_corpus(corpus) do
    if Enum.all?(corpus, fn {_name, value} -> match?(%Program{}, value) end),
      do: :ok,
      else: {:error, :invalid_corpus}
  end

  defp invalid_option(name, value), do: {:error, {:invalid_option, name, value}}

  defp initial_state(seed, iteration) do
    mixed = band(seed + iteration * 0x9E3779B97F4A7C15, @mask)
    if mixed == 0, do: 0xA0761D6478BD642F, else: mixed
  end

  defp next_state(state) do
    state = bxor(state, state <<< 13) |> band(@mask)
    state = bxor(state, state >>> 7)
    bxor(state, state <<< 17) |> band(@mask)
  end

  defp choose(state, upper_bound) when upper_bound > 0 do
    state = next_state(state)
    {rem(state, upper_bound), state}
  end

  defp random_bytes(state, count), do: random_bytes(state, count, [])
  defp random_bytes(state, 0, bytes), do: {:erlang.list_to_binary(Enum.reverse(bytes)), state}

  defp random_bytes(state, count, bytes) do
    {byte, state} = choose(state, 256)
    random_bytes(state, count - 1, [byte | bytes])
  end
end
