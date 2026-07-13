defmodule QuickBEAM.VM.Opcodes.Locals do
  @moduledoc """
  Executes argument, local, closure-cell, function-closure, and global opcodes.

  Mutable cells and globals remain fields of the owner-local execution state.
  The module returns explicit frame actions and never owns interpreter stepping.
  """

  alias QuickBEAM.VM.{
    Execution,
    Frame,
    Function,
    Heap,
    Memory,
    PredefinedAtoms,
    Properties,
    Value
  }

  @get_reference_ops [
    :get_var_ref,
    :get_var_ref0,
    :get_var_ref1,
    :get_var_ref2,
    :get_var_ref3,
    :get_var_ref_check
  ]

  @put_reference_ops [
    :put_var_ref,
    :put_var_ref0,
    :put_var_ref1,
    :put_var_ref2,
    :put_var_ref3,
    :put_var_ref_check,
    :put_var_ref_check_init
  ]

  @opcodes [
             :get_arg,
             :put_arg,
             :set_arg,
             :get_loc,
             :get_loc0_loc1,
             :put_loc,
             :set_loc,
             :set_loc_uninitialized,
             :get_loc_check,
             :put_loc_check_init,
             :put_loc_check,
             :close_loc,
             :inc_loc,
             :dec_loc,
             :add_loc,
             :fclosure,
             :fclosure8,
             :set_var_ref,
             :get_var,
             :get_var_undef,
             :put_var,
             :put_var_init,
             :define_func,
             :define_var,
             :check_define_var
           ] ++ @get_reference_ops ++ @put_reference_ops

  @type action ::
          {:next, Frame.t(), Execution.t()}
          | {:throw, term(), Frame.t(), Execution.t()}

  @doc "Returns the opcode names handled by this family."
  @spec opcodes() :: [atom()]
  def opcodes, do: @opcodes

  @doc "Executes one supported local, closure, argument, or global opcode."
  @spec execute(atom(), [term()], Frame.t(), Execution.t()) :: action()
  def execute(:get_arg, [index], frame, execution),
    do: push(frame, execution, read_slot(tuple_get(frame.args, index), execution))

  def execute(:put_arg, [index], %{stack: [value | stack]} = frame, execution) do
    {args, execution} = write_tuple_slot(frame.args, index, value, execution)
    next(%{frame | args: args, stack: stack}, execution)
  end

  def execute(:set_arg, [index], %{stack: [value | _]} = frame, execution) do
    {args, execution} = write_tuple_slot(frame.args, index, value, execution)
    next(%{frame | args: args}, execution)
  end

  def execute(:get_loc, [index], frame, execution),
    do: push(frame, execution, read_slot(elem(frame.locals, index), execution))

  def execute(:get_loc0_loc1, [first, second], frame, execution) do
    first = read_slot(elem(frame.locals, first), execution)
    second = read_slot(elem(frame.locals, second), execution)
    next(%{frame | stack: [first, second | frame.stack]}, execution)
  end

  def execute(:put_loc, [index], %{stack: [value | stack]} = frame, execution) do
    {locals, execution} = write_tuple_slot(frame.locals, index, value, execution)
    next(%{frame | locals: locals, stack: stack}, execution)
  end

  def execute(:set_loc, [index], %{stack: [value | _]} = frame, execution) do
    {locals, execution} = write_tuple_slot(frame.locals, index, value, execution)
    next(%{frame | locals: locals}, execution)
  end

  def execute(:set_loc_uninitialized, [index], frame, execution) do
    {locals, execution} = write_tuple_slot(frame.locals, index, :uninitialized, execution)
    next(%{frame | locals: locals}, execution)
  end

  def execute(:get_loc_check, [index], frame, execution) do
    case read_slot(elem(frame.locals, index), execution) do
      :uninitialized -> {:throw, {:reference_error, index}, frame, execution}
      value -> push(frame, execution, value)
    end
  end

  def execute(name, [index], frame, execution) when name in [:put_loc_check_init, :put_loc_check],
    do: execute(:put_loc, [index], frame, execution)

  def execute(:close_loc, [_index], frame, execution), do: next(frame, execution)

  def execute(:inc_loc, [index], frame, execution),
    do: update_local(frame, execution, index, &Value.unary(:inc, &1))

  def execute(:dec_loc, [index], frame, execution),
    do: update_local(frame, execution, index, &Value.unary(:dec, &1))

  def execute(:add_loc, [index], %{stack: [value | stack]} = frame, execution) do
    current = read_slot(elem(frame.locals, index), execution)

    {locals, execution} =
      write_tuple_slot(frame.locals, index, Value.binary(:add, current, value), execution)

    next(%{frame | locals: locals, stack: stack}, execution)
  end

  def execute(name, [index], frame, execution) when name in @get_reference_ops do
    value = read_reference(elem(frame.closure_refs, index), execution)

    if name == :get_var_ref_check and value == :uninitialized,
      do: {:throw, {:reference_error, index}, frame, execution},
      else: push(frame, execution, value)
  end

  def execute(name, [index], %{stack: [value | stack]} = frame, execution)
      when name in @put_reference_ops do
    execution = write_reference(elem(frame.closure_refs, index), value, execution)
    next(%{frame | stack: stack}, execution)
  end

  def execute(:set_var_ref, [index], %{stack: [value | _]} = frame, execution) do
    execution = write_reference(elem(frame.closure_refs, index), value, execution)
    next(frame, execution)
  end

  def execute(:get_var, [atom], frame, execution) do
    name = resolve_atom(atom, execution)

    case Map.fetch(execution.globals, name) do
      {:ok, value} -> push(frame, execution, value)
      :error -> {:throw, {:reference_error, name}, frame, execution}
    end
  end

  def execute(:get_var_undef, [atom], frame, execution) do
    name = resolve_atom(atom, execution)
    push(frame, execution, Map.get(execution.globals, name, :undefined))
  end

  def execute(name, [atom | _flags], %{stack: [value | stack]} = frame, execution)
      when name in [:put_var, :put_var_init, :define_func] do
    name = resolve_atom(atom, execution)
    execution = %{execution | globals: Map.put(execution.globals, name, value)}
    next(%{frame | stack: stack}, execution)
  end

  def execute(name, [_atom | _flags], frame, execution)
      when name in [:define_var, :check_define_var],
      do: next(frame, execution)

  def execute(name, [index], frame, execution) when name in [:fclosure, :fclosure8] do
    function = Enum.at(frame.function.constants, index)
    {callable, frame, execution} = capture_closure(function, frame, execution)
    {reference, execution} = allocate_function(callable, function, execution)
    push(frame, execution, reference)
  end

  @doc "Reads a direct value or owner-local cell/global slot."
  @spec read_slot(term(), Execution.t()) :: term()
  def read_slot({:cell, _id} = reference, execution), do: read_reference(reference, execution)
  def read_slot({:global, _name} = reference, execution), do: read_reference(reference, execution)
  def read_slot(value, _execution), do: value

  @doc "Resolves a decoded QuickJS atom operand against an execution's atom table."
  @spec resolve_atom(term(), Execution.t()) :: term()
  def resolve_atom(:empty_string, _execution), do: ""
  def resolve_atom({:tagged_int, value}, _execution), do: value

  def resolve_atom({:predefined, index}, _execution),
    do: PredefinedAtoms.lookup(index) || {:predefined, index}

  def resolve_atom(index, execution) when is_integer(index) and index >= 0 do
    if index < tuple_size(execution.atoms),
      do: elem(execution.atoms, index),
      else: {:atom, index}
  end

  def resolve_atom(value, _execution), do: value

  defp update_local(frame, execution, index, operation) do
    value = read_slot(elem(frame.locals, index), execution)
    {locals, execution} = write_tuple_slot(frame.locals, index, operation.(value), execution)
    next(%{frame | locals: locals}, execution)
  end

  defp allocate_function(callable, function, execution) do
    {reference, execution} = Heap.allocate(execution, :function, callable: callable)

    if function.has_prototype do
      {prototype, execution} = Heap.allocate(execution)

      {:ok, execution} =
        Properties.define(prototype, "constructor", reference, execution,
          enumerable: false,
          configurable: true
        )

      {:ok, execution} =
        Properties.define(reference, "prototype", prototype, execution,
          enumerable: false,
          configurable: false
        )

      {reference, execution}
    else
      {reference, execution}
    end
  end

  defp capture_closure(%Function{closure_vars: []} = function, frame, execution),
    do: {function, frame, execution}

  defp capture_closure(%Function{} = function, frame, execution) do
    {references, frame, execution} =
      Enum.reduce(function.closure_vars, {[], frame, execution}, fn closure_var,
                                                                    {references, frame, execution} ->
        {reference, frame, execution} = capture_reference(closure_var, frame, execution)
        {[reference | references], frame, execution}
      end)

    {{:closure, function, references |> Enum.reverse() |> List.to_tuple()}, frame, execution}
  end

  defp capture_reference(%{closure_type: 0, var_idx: index}, frame, execution) do
    index = frame.function.arg_count + index
    {reference, locals, execution} = promote_tuple_slot(frame.locals, index, execution)
    {reference, %{frame | locals: locals}, execution}
  end

  defp capture_reference(%{closure_type: 1, var_idx: index}, frame, execution) do
    {reference, args, execution} = promote_tuple_slot(frame.args, index, execution)
    {reference, %{frame | args: args}, execution}
  end

  defp capture_reference(%{closure_type: 2, var_idx: index}, frame, execution),
    do: {elem(frame.closure_refs, index), frame, execution}

  defp capture_reference(%{name: name}, frame, execution),
    do: {{:global, name}, frame, execution}

  defp promote_tuple_slot(tuple, index, execution) do
    case elem(tuple, index) do
      {:cell, _id} = reference ->
        {reference, tuple, execution}

      value ->
        id = execution.next_cell_id
        reference = {:cell, id}
        execution = Memory.charge_cell(execution, value)

        execution = %{
          execution
          | cells: Map.put(execution.cells, id, value),
            next_cell_id: id + 1
        }

        {reference, put_elem(tuple, index, reference), execution}
    end
  end

  defp read_reference({:cell, id}, execution), do: Map.fetch!(execution.cells, id)

  defp read_reference({:global, name}, execution),
    do: Map.get(execution.globals, name, :undefined)

  defp write_reference({:cell, id}, value, execution),
    do: %{execution | cells: Map.put(execution.cells, id, value)}

  defp write_reference({:global, name}, value, execution),
    do: %{execution | globals: Map.put(execution.globals, name, value)}

  defp write_tuple_slot(tuple, index, value, execution) do
    case elem(tuple, index) do
      {:cell, _id} = reference -> {tuple, write_reference(reference, value, execution)}
      {:global, _name} = reference -> {tuple, write_reference(reference, value, execution)}
      _value -> {put_elem(tuple, index, value), execution}
    end
  end

  defp tuple_get(tuple, index) when index < tuple_size(tuple), do: elem(tuple, index)
  defp tuple_get(_tuple, _index), do: :undefined

  defp push(frame, execution, value), do: next(%{frame | stack: [value | frame.stack]}, execution)
  defp next(frame, execution), do: {:next, frame, execution}
end
