defmodule QuickBEAM.VM.Opcodes.Objects do
  @moduledoc """
  Executes object construction, property access, descriptors, and enumeration opcodes.

  Property behavior delegates to `QuickBEAM.VM.Properties`. Accessor-backed
  operations return explicit invocation actions so the interpreter can preserve
  resumable frames and JavaScript exception boundaries.
  """

  import Bitwise

  alias QuickBEAM.VM.{
    Execution,
    Frame,
    Function,
    Heap,
    Invocation,
    Iterator,
    Properties,
    Property,
    Reference,
    RegExp,
    Symbol,
    Value
  }

  alias QuickBEAM.VM.Opcodes.Locals

  @opcodes [
    :regexp,
    :private_symbol,
    :get_private_field,
    :get_super,
    :put_private_field,
    :define_private_field,
    :add_brand,
    :check_brand,
    :set_home_object,
    :special_object,
    :object,
    :array_from,
    :define_class,
    :define_class_computed,
    :define_method,
    :define_method_computed,
    :define_field,
    :define_array_el,
    :append,
    :copy_data_properties,
    :get_field,
    :get_field2,
    :get_array_el,
    :get_length,
    :put_field,
    :put_array_el,
    :delete,
    :for_in_start,
    :for_in_next,
    :for_of_start,
    :for_of_next,
    :iterator_close
  ]

  @type action ::
          {:next, Frame.t(), Execution.t()}
          | {:throw, term(), Frame.t(), Execution.t()}
          | {:invoke_getter, term(), term(), Frame.t(), Execution.t()}
          | {:invoke_setter, term(), term(), term(), Frame.t(), Execution.t()}

  @doc "Returns the opcode names handled by this family."
  @spec opcodes() :: [atom()]
  def opcodes, do: @opcodes

  @doc "Executes one supported object or property opcode."
  @spec execute(atom(), [term()], Frame.t(), Execution.t()) :: action()
  def execute(:regexp, [], %{stack: [bytecode, source | stack]} = frame, execution) do
    {regexp, execution} =
      Heap.allocate(execution, :regexp, internal: %RegExp{source: source, bytecode: bytecode})

    {:ok, execution} = Properties.define(regexp, "lastIndex", 0, execution)
    push(%{frame | stack: stack}, execution, regexp)
  end

  def execute(:private_symbol, [atom], frame, execution) do
    id = execution.next_symbol_id
    description = Locals.resolve_atom(atom, execution) |> Value.to_string_value()
    symbol = %Symbol{id: {:local, id}, description: description}
    push(frame, %{execution | next_symbol_id: id + 1}, symbol)
  end

  def execute(:get_super, [], %{stack: [%Reference{} = object | stack]} = frame, execution) do
    case Heap.prototype(execution, object) do
      {:ok, prototype} -> next(%{frame | stack: [prototype || nil | stack]}, execution)
      {:error, reason} -> {:throw, {:type_error, reason}, frame, execution}
    end
  end

  def execute(
        :get_private_field,
        [],
        %{stack: [%Symbol{} = key, %Reference{} = object | stack]} = frame,
        execution
      ) do
    case Heap.own_property(execution, object, key) do
      {:ok, %Property{value: value}} -> next(%{frame | stack: [value | stack]}, execution)
      {:ok, nil} -> {:throw, {:type_error, :missing_private_field}, frame, execution}
      {:error, reason} -> {:throw, {:type_error, reason}, frame, execution}
    end
  end

  def execute(
        :put_private_field,
        [],
        %{stack: [%Symbol{} = key, value, %Reference{} = object | stack]} = frame,
        execution
      ) do
    case Heap.own_property(execution, object, key) do
      {:ok, %Property{}} ->
        case Properties.put(object, key, value, execution) do
          {:ok, execution} -> next(%{frame | stack: stack}, execution)
          {:error, reason} -> {:throw, {:type_error, reason}, frame, execution}
        end

      {:ok, nil} ->
        {:throw, {:type_error, :missing_private_field}, frame, execution}

      {:error, reason} ->
        {:throw, {:type_error, reason}, frame, execution}
    end
  end

  def execute(
        :define_private_field,
        [],
        %{stack: [value, %Symbol{} = key, %Reference{} = object | stack]} = frame,
        execution
      ) do
    case Heap.own_property(execution, object, key) do
      {:ok, nil} ->
        case Properties.define(object, key, value, execution) do
          {:ok, execution} -> next(%{frame | stack: [object | stack]}, execution)
          {:error, reason} -> {:throw, {:type_error, reason}, frame, execution}
        end

      {:ok, %Property{}} ->
        {:throw, {:type_error, :duplicate_private_field}, frame, execution}

      {:error, reason} ->
        {:throw, {:type_error, reason}, frame, execution}
    end
  end

  def execute(
        :set_home_object,
        [],
        %{stack: [%Reference{} = function, %Reference{} = home | _stack]} = frame,
        execution
      ) do
    case Properties.define(function, :home_object, home, execution) do
      {:ok, execution} -> next(frame, execution)
      {:error, reason} -> {:throw, {:type_error, reason}, frame, execution}
    end
  end

  def execute(
        :add_brand,
        [],
        %{stack: [%Reference{} = home, object | stack]} = frame,
        execution
      )
      when object in [nil, :undefined] or is_struct(object, Reference) do
    {brand, execution} = private_brand(home, execution)

    result =
      case object do
        %Reference{} -> Properties.define(object, {:private_brand, brand}, true, execution)
        object when object in [nil, :undefined] -> {:ok, execution}
      end

    case result do
      {:ok, execution} -> next(%{frame | stack: stack}, execution)
      {:error, reason} -> {:throw, {:type_error, reason}, frame, execution}
    end
  end

  def execute(
        :check_brand,
        [],
        %{stack: [%Reference{} = function, %Reference{} = object | _stack]} = frame,
        execution
      ) do
    with {:ok, %Property{value: %Reference{} = home}} <-
           Heap.own_property(execution, function, :home_object),
         {:ok, %Property{value: %Symbol{} = brand}} <-
           Heap.own_property(execution, home, :private_brand_token),
         {:ok, %Property{}} <-
           Heap.own_property(execution, object, {:private_brand, brand}) do
      next(frame, execution)
    else
      {:ok, nil} -> {:throw, {:type_error, :invalid_private_brand}, frame, execution}
      {:error, reason} -> {:throw, {:type_error, reason}, frame, execution}
    end
  end

  def execute(:special_object, [type], frame, execution) when type in [0, 1] do
    values = Tuple.to_list(frame.args)
    {arguments, execution} = Heap.allocate(execution, :array)

    execution =
      values
      |> Enum.with_index()
      |> Enum.reduce(execution, fn {value, index}, execution ->
        {:ok, execution} =
          Properties.define(arguments, index, Locals.read_slot(value, execution), execution)

        execution
      end)

    push(frame, execution, arguments)
  end

  def execute(:special_object, [2], frame, execution),
    do: push(frame, execution, frame.callable)

  def execute(:special_object, [3], frame, execution),
    do: push(frame, execution, frame.callable)

  def execute(:special_object, [4], frame, execution) do
    value =
      case frame.callable do
        %Reference{} = callable ->
          case Heap.own_property(execution, callable, :home_object) do
            {:ok, %Property{value: home}} -> home
            _other -> :undefined
          end

        _other ->
          :undefined
      end

    push(frame, execution, value)
  end

  def execute(:special_object, [type], frame, execution) when type in [5, 7] do
    {object, execution} = Heap.allocate(execution, :ordinary, prototype: nil)
    push(frame, execution, object)
  end

  def execute(:special_object, [_type], frame, execution),
    do: push(frame, execution, :undefined)

  def execute(:object, [], frame, execution) do
    {reference, execution} = Heap.allocate(execution)
    push(frame, execution, reference)
  end

  def execute(:array_from, [count], frame, execution) do
    {elements, stack} = Enum.split(frame.stack, count)
    {reference, execution} = Heap.allocate_array(execution, Enum.reverse(elements))
    push(%{frame | stack: stack}, execution, reference)
  end

  def execute(
        :define_class,
        [atom, _flags],
        %{stack: [constructor, parent | stack]} = frame,
        execution
      ),
      do:
        define_class(
          constructor,
          parent,
          Locals.resolve_atom(atom, execution),
          stack,
          frame,
          execution
        )

  def execute(
        :define_class_computed,
        [_atom, _flags],
        %{stack: [constructor, parent, name | stack]} = frame,
        execution
      ),
      do:
        define_class(
          constructor,
          parent,
          Value.to_string_value(name),
          [name | stack],
          frame,
          execution
        )

  def execute(
        :define_method,
        [atom, kind],
        %{stack: [callable, %Reference{} = object | stack]} = frame,
        execution
      ) do
    key = Locals.resolve_atom(atom, execution)
    result = define_method_property(object, key, callable, kind, execution)

    case result do
      {:ok, execution} -> next(%{frame | stack: [object | stack]}, execution)
      {:error, reason} -> {:throw, {:type_error, reason}, frame, execution}
    end
  end

  def execute(
        :define_method_computed,
        [kind],
        %{stack: [callable, key, %Reference{} = object | stack]} = frame,
        execution
      ) do
    result = define_method_property(object, key, callable, kind, execution)

    case result do
      {:ok, execution} -> next(%{frame | stack: [object | stack]}, execution)
      {:error, reason} -> {:throw, {:type_error, reason}, frame, execution}
    end
  end

  def execute(
        :define_field,
        [atom],
        %{stack: [value, %Reference{} = object | stack]} = frame,
        execution
      ) do
    key = Locals.resolve_atom(atom, execution)

    case Properties.define(object, key, value, execution) do
      {:ok, execution} -> next(%{frame | stack: [object | stack]}, execution)
      {:error, reason} -> {:throw, {:type_error, reason}, frame, execution}
    end
  end

  def execute(
        :define_array_el,
        [],
        %{stack: [value, key, %Reference{} = object | stack]} = frame,
        execution
      ) do
    case Properties.define(object, key, value, execution) do
      {:ok, execution} -> next(%{frame | stack: [key, object | stack]}, execution)
      {:error, reason} -> {:throw, {:type_error, reason}, frame, execution}
    end
  end

  def execute(
        :append,
        [],
        %{stack: [iterable, index, %Reference{} = array | stack]} = frame,
        execution
      ) do
    case Iterator.values(iterable, execution) do
      {:ok, values} ->
        index = Value.to_number(index)

        execution =
          values
          |> Enum.with_index(index)
          |> Enum.reduce(execution, fn {value, position}, execution ->
            {:ok, execution} = Properties.define(array, position, value, execution)
            execution
          end)

        next(%{frame | stack: [index + length(values), array | stack]}, execution)

      {:error, reason} ->
        {:throw, {:type_error, reason}, frame, execution}

      {:resumable} ->
        {:throw, {:type_error, :unsupported_resumable_spread}, frame, execution}
    end
  end

  def execute(:copy_data_properties, [mask], %{stack: stack} = frame, execution) do
    target = Enum.at(stack, band(mask, 3))
    source = Enum.at(stack, band(mask >>> 2, 7))
    excluded = Enum.at(stack, band(mask >>> 5, 3))

    with %Reference{} <- target,
         {:ok, keys} <- Properties.enumerable_keys(source, execution),
         {:ok, excluded_keys} <- copy_excluded_keys(excluded, execution),
         {:ok, execution} <-
           copy_data_properties(keys -- excluded_keys, target, source, execution) do
      next(frame, execution)
    else
      {:error, reason} -> {:throw, {:type_error, reason}, frame, execution}
      _invalid_target -> {:throw, {:type_error, :invalid_copy_target}, frame, execution}
    end
  end

  def execute(:get_field, [atom], %{stack: [object | stack]} = frame, execution),
    do: get(object, Locals.resolve_atom(atom, execution), stack, frame, execution)

  def execute(:get_field2, [atom], %{stack: [object | stack]} = frame, execution),
    do: get(object, Locals.resolve_atom(atom, execution), [object | stack], frame, execution)

  def execute(:get_array_el, [], %{stack: [key, object | stack]} = frame, execution),
    do: get(object, key, stack, frame, execution)

  def execute(:get_length, [], %{stack: [object | stack]} = frame, execution),
    do: get(object, "length", stack, frame, execution)

  def execute(:put_field, [atom], %{stack: [value, object | stack]} = frame, execution),
    do:
      put(
        object,
        Locals.resolve_atom(atom, execution),
        value,
        stack,
        frame,
        execution
      )

  def execute(:put_array_el, [], %{stack: [value, key, object | stack]} = frame, execution),
    do: put(object, key, value, stack, frame, execution)

  def execute(:delete, [], %{stack: [key, %Reference{} = object | stack]} = frame, execution) do
    case Properties.delete(object, key, execution) do
      {:ok, deleted?, execution} -> next(%{frame | stack: [deleted? | stack]}, execution)
      {:error, reason} -> {:throw, {:type_error, reason}, frame, execution}
    end
  end

  def execute(:for_in_start, [], %{stack: [object | stack]} = frame, execution) do
    case Properties.enumerable_keys(object, execution) do
      {:ok, keys} -> next(%{frame | stack: [{:for_in, keys, 0} | stack]}, execution)
      {:error, reason} -> {:throw, {:type_error, reason}, %{frame | stack: stack}, execution}
    end
  end

  def execute(:for_in_next, [], %{stack: [{:for_in, keys, index} | stack]} = frame, execution) do
    if index < length(keys) do
      iterator = {:for_in, keys, index + 1}
      next(%{frame | stack: [false, Enum.at(keys, index), iterator | stack]}, execution)
    else
      next(%{frame | stack: [true, :undefined, {:for_in, keys, index} | stack]}, execution)
    end
  end

  def execute(:for_of_start, [], %{stack: [iterable | stack]} = frame, execution) do
    case Iterator.values(iterable, execution) do
      {:ok, values} ->
        iterator = {:for_of, values, 0}
        next(%{frame | stack: [0, :direct_iterator, iterator | stack]}, execution)

      {:error, reason} ->
        {:throw, {:type_error, reason}, frame, execution}

      {:resumable} ->
        {:throw, {:type_error, :unsupported_resumable_for_of}, frame, execution}
    end
  end

  def execute(:for_of_next, [depth], %{stack: stack} = frame, execution) do
    iterator_offset = depth + 2

    case Enum.at(stack, iterator_offset) do
      {:for_of, values, index} ->
        done? = index >= length(values)
        value = if done?, do: :undefined, else: Enum.at(values, index)
        next_index = if done?, do: index, else: index + 1
        stack = List.replace_at(stack, iterator_offset, {:for_of, values, next_index})
        next(%{frame | stack: [done?, value | stack]}, execution)

      _other ->
        {:throw, {:type_error, :invalid_for_of_iterator}, frame, execution}
    end
  end

  def execute(
        :iterator_close,
        [],
        %{stack: [_index, _next, _iterator | stack]} = frame,
        execution
      ),
      do: next(%{frame | stack: stack}, execution)

  defp copy_excluded_keys(value, _execution) when value in [:undefined, nil], do: {:ok, []}
  defp copy_excluded_keys(value, execution), do: Properties.enumerable_keys(value, execution)

  defp copy_data_properties(keys, target, source, execution) do
    Enum.reduce_while(keys, {:ok, execution}, fn key, {:ok, execution} ->
      case Properties.get(source, key, execution) do
        {:ok, {:accessor, _getter, _receiver}} ->
          {:halt, {:error, :unsupported_copy_accessor}}

        {:ok, value} ->
          case Properties.put(target, key, value, execution) do
            {:ok, execution} -> {:cont, {:ok, execution}}
            {:error, reason} -> {:halt, {:error, reason}}
          end

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp private_brand(home, execution) do
    case Heap.own_property(execution, home, :private_brand_token) do
      {:ok, %Property{value: %Symbol{} = brand}} ->
        {brand, execution}

      {:ok, nil} ->
        id = execution.next_symbol_id
        brand = %Symbol{id: {:local, id}, description: "brand"}
        execution = %{execution | next_symbol_id: id + 1}
        {:ok, execution} = Properties.define(home, :private_brand_token, brand, execution)
        {brand, execution}
    end
  end

  defp define_method_property(object, key, callable, flags, execution) do
    opts = [enumerable: band(flags, 4) != 0]

    case band(flags, 3) do
      0 -> Properties.define(object, key, callable, execution, opts)
      1 -> Properties.define_accessor(object, key, :getter, callable, execution, opts)
      2 -> Properties.define_accessor(object, key, :setter, callable, execution, opts)
      kind -> {:error, {:unsupported_method_kind, kind}}
    end
  end

  defp define_class(constructor, parent, name, stack, frame, execution) do
    {constructor, frame, execution} = instantiate_class_constructor(constructor, frame, execution)

    with :ok <- validate_class_parent(parent, execution),
         {:ok, parent_prototype} <- class_parent_prototype(parent, execution) do
      {prototype, execution} = Heap.allocate(execution, prototype: parent_prototype)

      {:ok, execution} =
        Properties.define(prototype, "constructor", constructor, execution,
          writable: true,
          enumerable: false,
          configurable: true
        )

      {:ok, execution} =
        Properties.define(constructor, "prototype", prototype, execution,
          writable: false,
          enumerable: false,
          configurable: false
        )

      {:ok, execution} =
        Heap.update_object(execution, constructor, fn object ->
          %{object | internal: :class_constructor}
        end)

      {:ok, execution} =
        Properties.define(constructor, "name", name, execution,
          writable: false,
          enumerable: false,
          configurable: true
        )

      execution =
        case parent do
          %Reference{} = parent ->
            case Heap.set_prototype(execution, constructor, parent) do
              {:ok, execution} -> execution
              {:error, _reason} -> execution
            end

          _other ->
            execution
        end

      next(%{frame | stack: [prototype, constructor | stack]}, execution)
    else
      {:error, reason} -> {:throw, {:type_error, reason}, frame, execution}
    end
  end

  defp instantiate_class_constructor(%Function{} = function, frame, execution),
    do: Locals.instantiate_function(function, frame, execution, prototype?: false)

  defp instantiate_class_constructor(%Reference{} = constructor, frame, execution),
    do: {constructor, frame, execution}

  defp validate_class_parent(parent, _execution) when parent in [:undefined, nil], do: :ok

  defp validate_class_parent(parent, execution) do
    if Invocation.constructable?(parent, execution),
      do: :ok,
      else: {:error, :class_parent_not_constructor}
  end

  defp class_parent_prototype(:undefined, execution),
    do: {:ok, Map.get(execution.default_prototypes, :ordinary)}

  defp class_parent_prototype(nil, _execution), do: {:ok, nil}

  defp class_parent_prototype(parent, execution) do
    case Properties.get(parent, "prototype", execution) do
      {:ok, %Reference{} = prototype} -> {:ok, prototype}
      {:ok, nil} -> {:ok, nil}
      _other -> {:error, :invalid_class_parent_prototype}
    end
  end

  defp get(object, key, stack, frame, execution) do
    frame = %{frame | stack: stack}

    case Properties.get(object, key, execution) do
      {:ok, {:accessor, getter, receiver}} ->
        {:invoke_getter, getter, receiver, frame, execution}

      {:ok, value} ->
        next(%{frame | stack: [value | stack]}, execution)

      {:error, reason} ->
        {:throw, {:type_error, reason}, frame, execution}
    end
  end

  defp put(object, key, value, stack, frame, execution) do
    frame = %{frame | stack: stack}

    case Properties.put(object, key, value, execution) do
      {:ok, execution} ->
        next(frame, execution)

      {:error, {:invoke_setter, setter}} ->
        {:invoke_setter, setter, value, object, frame, execution}

      {:error, reason} ->
        {:throw, {:type_error, reason}, frame, execution}
    end
  end

  defp push(frame, execution, value), do: next(%{frame | stack: [value | frame.stack]}, execution)
  defp next(frame, execution), do: {:next, frame, execution}
end
