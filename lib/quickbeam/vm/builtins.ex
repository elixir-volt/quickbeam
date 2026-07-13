defmodule QuickBEAM.VM.Builtins do
  @moduledoc """
  Installs and dispatches the JavaScript built-ins supported by the VM profile.
  """

  alias QuickBEAM.VM.{
    Execution,
    Heap,
    Object,
    Properties,
    Property,
    Reference,
    RegExp,
    Value
  }

  alias QuickBEAM.VM.Builtin.{Installer, Registry}

  @error_types ~w(Error EvalError RangeError ReferenceError SyntaxError TypeError URIError)

  @constructors %{
    "Array" => [],
    "Boolean" => [],
    "Object" => [],
    "EvalError" => [],
    "Function" => [],
    "Number" => [],
    "RangeError" => [],
    "ReferenceError" => [],
    "String" => [],
    "SyntaxError" => [],
    "TypeError" => [],
    "URIError" => [],
    "Error" => [],
    "Set" => []
  }

  @spec install(Execution.t()) :: Execution.t()
  def install(execution) do
    execution =
      @constructors
      |> Enum.sort_by(fn {name, _methods} ->
        if name == "Object", do: {0, name}, else: {1, name}
      end)
      |> Enum.reduce(execution, fn {name, methods}, execution ->
        {object, execution} = Heap.allocate(execution, :function, callable: {:builtin, name})

        execution =
          Enum.reduce(methods, execution, fn method, execution ->
            {:ok, execution} =
              Properties.define(object, method, {:builtin_method, name, method}, execution,
                enumerable: false
              )

            execution
          end)

        execution = maybe_install_prototype(name, object, execution)
        %{execution | globals: Map.put_new(execution.globals, name, object)}
      end)
      |> link_constructor_prototypes()

    Installer.install_all(execution, Registry.modules(:core))
  end

  @spec callable(Execution.t(), Reference.t()) :: term() | nil
  def callable(execution, %Reference{} = reference) do
    case Heap.fetch_object(execution, reference) do
      {:ok, %Object{callable: callable}} -> callable
      :error -> nil
    end
  end

  @doc "Allocates a catchable JavaScript error object in the current evaluation heap."
  @spec new_error(Execution.t(), String.t(), String.t()) :: {Reference.t(), Execution.t()}
  def new_error(execution, name, message) do
    prototype =
      Map.get(execution.error_prototypes, name) || Map.get(execution.error_prototypes, "Error")

    {error, execution} =
      Heap.allocate(execution, :ordinary, prototype: prototype, internal: {:error, name})

    {:ok, execution} =
      Properties.define(error, "message", message, execution,
        enumerable: false,
        configurable: true,
        writable: true
      )

    {error, execution}
  end

  @spec call(term(), term(), [term()], Execution.t()) ::
          {:ok, term(), Execution.t()} | {:error, term(), Execution.t()}
  def call(
        {:primitive_method, :object, "hasOwnProperty"},
        %Reference{} = object,
        [key | _],
        execution
      ) do
    case Properties.own_property(object, key, execution) do
      {:ok, property} -> {:ok, not is_nil(property), execution}
      {:error, reason} -> {:error, reason, execution}
    end
  end

  def call(
        {:primitive_method, :object, "propertyIsEnumerable"},
        %Reference{} = object,
        [key | _],
        execution
      ) do
    case Properties.own_property(object, key, execution) do
      {:ok, %Property{enumerable: enumerable}} -> {:ok, enumerable, execution}
      {:ok, nil} -> {:ok, false, execution}
      {:error, reason} -> {:error, reason, execution}
    end
  end

  def call({:primitive_method, :object, "toString"}, _object, _arguments, execution),
    do: {:ok, "[object Object]", execution}

  def call({:primitive_method, :error, "toString"}, %Reference{} = error, _arguments, execution) do
    with {:ok, name} <- Properties.get(error, "name", execution),
         {:ok, message} <- Properties.get(error, "message", execution) do
      name = if name in [:undefined, nil], do: "Error", else: Value.to_string_value(name)
      message = if message in [:undefined, nil], do: "", else: Value.to_string_value(message)

      result =
        cond do
          name == "" -> message
          message == "" -> name
          true -> name <> ": " <> message
        end

      {:ok, result, execution}
    else
      {:error, reason} -> {:error, reason, execution}
    end
  end

  def call({:primitive_method, :regexp, "test"}, %RegExp{} = regexp, [value | _], execution),
    do: {:ok, regex_match?(regexp, Value.to_string_value(value)), execution}

  def call({:builtin, "Boolean"}, %Reference{} = receiver, values, execution) do
    value = values |> List.first() |> Value.truthy?()
    maybe_box_primitive(receiver, :boolean, value, execution)
  end

  def call({:builtin, "Boolean"}, _this, values, execution),
    do: {:ok, values |> List.first() |> Value.truthy?(), execution}

  def call({:builtin, "Number"}, %Reference{} = receiver, values, execution) do
    value =
      case values do
        [value | _] -> Value.to_number(value)
        [] -> 0
      end

    maybe_box_primitive(receiver, :number, value, execution)
  end

  def call({:builtin, "Number"}, _this, [value], execution),
    do: {:ok, Value.to_number(value), execution}

  def call({:builtin, "Number"}, _this, [], execution), do: {:ok, 0, execution}

  def call({:builtin, "String"}, %Reference{} = receiver, values, execution) do
    value =
      case values do
        [value | _] -> Value.to_string_value(value)
        [] -> ""
      end

    maybe_box_primitive(receiver, :string, value, execution)
  end

  def call({:builtin, "String"}, _this, [value], execution),
    do: {:ok, Value.to_string_value(value), execution}

  def call({:builtin, "String"}, _this, [], execution), do: {:ok, "", execution}

  def call({:builtin, "Set"}, _this, values, execution) do
    entries =
      case values do
        [value | _] ->
          case array_values(value, execution) do
            {:ok, entries} -> entries
            _ -> []
          end

        [] ->
          []
      end

    entries = Enum.uniq(entries)
    internal = %{values: entries, index: MapSet.new(entries)}
    {set, execution} = Heap.allocate(execution, :set, internal: internal)
    {:ok, set, execution}
  end

  def call({:primitive_method, :set, "has"}, %Reference{} = set, [value | _], execution) do
    case Heap.fetch_object(execution, set) do
      {:ok, %Object{kind: :set, internal: %{index: entries}}} ->
        {:ok, MapSet.member?(entries, value), execution}

      _ ->
        {:error, :not_a_set, execution}
    end
  end

  def call({:primitive_method, :set, "add"}, %Reference{} = set, [value | _], execution) do
    case Heap.update_object(execution, set, fn object ->
           %{values: values, index: index} = object.internal

           if MapSet.member?(index, value) do
             object
           else
             %{object | internal: %{values: values ++ [value], index: MapSet.put(index, value)}}
           end
         end) do
      {:ok, execution} -> {:ok, set, execution}
      {:error, reason} -> {:error, reason, execution}
    end
  end

  def call({:builtin, "FunctionPrototype"}, _this, _arguments, execution),
    do: {:ok, :undefined, execution}

  def call({:builtin, "Function"}, _this, _arguments, execution),
    do: {:error, :dynamic_function_unsupported, execution}

  def call({:builtin, "Array"}, _this, [length], execution)
      when is_integer(length) and length >= 0 do
    {array, execution} = Heap.allocate(execution, :array, length: length)
    {:ok, array, execution}
  end

  def call({:builtin, "Array"}, _this, values, execution) do
    {array, execution} = array_from(values, execution)
    {:ok, array, execution}
  end

  def call({:builtin, "Object"}, _this, [value], execution) when value not in [nil, :undefined],
    do: {:ok, value, execution}

  def call({:builtin, "Object"}, _this, _values, execution) do
    {object, execution} = Heap.allocate(execution)
    {:ok, object, execution}
  end

  def call({:builtin, name}, this, values, execution)
      when name in @error_types do
    message =
      case values do
        [value | _] -> Value.to_string_value(value)
        [] -> ""
      end

    case constructor_instance?(this, execution) do
      true ->
        prototype = Map.get(execution.error_prototypes, name)

        {:ok, execution} =
          Heap.update_object(execution, this, fn object ->
            %{object | prototype: prototype, internal: {:error, name}}
          end)

        {:ok, execution} =
          Properties.define(this, "message", message, execution,
            enumerable: false,
            configurable: true,
            writable: true
          )

        {:ok, this, execution}

      false ->
        {error, execution} = new_error(execution, name, message)
        {:ok, error, execution}
    end
  end

  def call(callable, _this, _arguments, execution),
    do: {:error, {:unsupported_builtin, callable}, execution}

  defp link_constructor_prototypes(execution) do
    case execution.default_prototypes do
      %{function: function_prototype} ->
        Enum.reduce(Map.keys(@constructors), execution, fn name, execution ->
          constructor = Map.fetch!(execution.globals, name)

          {:ok, execution} =
            Properties.set_prototype(constructor, function_prototype, execution)

          execution
        end)

      _no_function_prototype ->
        execution
    end
  end

  defp maybe_install_prototype("Object", constructor, execution) do
    {prototype, execution} = Heap.allocate(execution, :ordinary, prototype: nil)

    execution =
      Enum.reduce(["hasOwnProperty", "propertyIsEnumerable", "toString"], execution, fn method,
                                                                                        execution ->
        {:ok, execution} =
          Properties.define(prototype, method, {:primitive_method, :object, method}, execution,
            enumerable: false
          )

        execution
      end)

    {:ok, execution} =
      Properties.define(prototype, "constructor", constructor, execution, enumerable: false)

    {:ok, execution} =
      Properties.define(constructor, "prototype", prototype, execution, enumerable: false)

    %{
      execution
      | default_prototypes: Map.put(execution.default_prototypes, :ordinary, prototype)
    }
  end

  defp maybe_install_prototype("Error", constructor, execution) do
    object_prototype = Map.get(execution.default_prototypes, :ordinary)
    {prototype, execution} = Heap.allocate(execution, :ordinary, prototype: object_prototype)

    execution =
      [
        {"name", "Error"},
        {"message", ""},
        {"constructor", constructor},
        {"toString", {:primitive_method, :error, "toString"}}
      ]
      |> Enum.reduce(execution, fn {key, value}, execution ->
        {:ok, execution} =
          Properties.define(prototype, key, value, execution, enumerable: false)

        execution
      end)

    {:ok, execution} =
      Properties.define(constructor, "prototype", prototype, execution, enumerable: false)

    %{execution | error_prototypes: Map.put(execution.error_prototypes, "Error", prototype)}
  end

  defp maybe_install_prototype(name, constructor, execution)
       when name in @error_types do
    error_prototype = Map.fetch!(execution.error_prototypes, "Error")
    {prototype, execution} = Heap.allocate(execution, :ordinary, prototype: error_prototype)

    execution =
      [{"name", name}, {"message", ""}, {"constructor", constructor}]
      |> Enum.reduce(execution, fn {key, value}, execution ->
        {:ok, execution} =
          Properties.define(prototype, key, value, execution, enumerable: false)

        execution
      end)

    {:ok, execution} =
      Properties.define(constructor, "prototype", prototype, execution, enumerable: false)

    %{execution | error_prototypes: Map.put(execution.error_prototypes, name, prototype)}
  end

  defp maybe_install_prototype("Function", constructor, execution) do
    {prototype, execution} =
      Heap.allocate(execution, :function,
        callable: {:builtin, "FunctionPrototype"},
        prototype: Map.get(execution.default_prototypes, :ordinary)
      )

    {:ok, execution} =
      Properties.define(constructor, "prototype", prototype, execution, enumerable: false)

    %{
      execution
      | default_prototypes: Map.put(execution.default_prototypes, :function, prototype)
    }
  end

  defp maybe_install_prototype("Array", constructor, execution) do
    install_primitive_prototype(
      constructor,
      :array,
      [],
      execution
    )
  end

  defp maybe_install_prototype("String", constructor, execution),
    do: install_primitive_prototype(constructor, :string, [], execution)

  defp maybe_install_prototype("Number", constructor, execution),
    do: install_primitive_prototype(constructor, :number, [], execution)

  defp maybe_install_prototype(_name, _constructor, execution), do: execution

  defp install_primitive_prototype(constructor, kind, methods, execution) do
    {prototype, execution} = Heap.allocate(execution)

    execution =
      Enum.reduce(methods, execution, fn method, execution ->
        {:ok, execution} =
          Properties.define(prototype, method, {:primitive_method, kind, method}, execution,
            enumerable: false
          )

        execution
      end)

    {:ok, execution} =
      Properties.define(constructor, "prototype", prototype, execution, enumerable: false)

    if kind == :array do
      %{
        execution
        | default_prototypes: Map.put(execution.default_prototypes, :array, prototype)
      }
    else
      execution
    end
  end

  defp constructor_instance?(%Reference{} = receiver, execution) do
    match?(
      {:ok, %Object{internal: :constructor_instance}},
      Heap.fetch_object(execution, receiver)
    )
  end

  defp constructor_instance?(_receiver, _execution), do: false

  defp maybe_box_primitive(receiver, kind, value, execution) do
    case Heap.fetch_object(execution, receiver) do
      {:ok, %Object{internal: :constructor_instance}} ->
        {:ok, execution} =
          Heap.update_object(execution, receiver, &%{&1 | internal: {:primitive, kind, value}})

        {:ok, receiver, execution}

      _not_constructor ->
        {:ok, value, execution}
    end
  end

  defp array_from(values, execution) do
    {array, execution} = Heap.allocate(execution, :array)

    execution =
      values
      |> Enum.with_index()
      |> Enum.reduce(execution, fn {value, index}, execution ->
        {:ok, execution} = Properties.define(array, index, value, execution)
        execution
      end)

    {array, execution}
  end

  defp array_values(value, _execution) when is_list(value), do: {:ok, value}

  defp array_values(%Reference{} = reference, execution) do
    case Heap.fetch_object(execution, reference) do
      {:ok, %Object{kind: :array, length: length, properties: properties}} ->
        values =
          if length == 0,
            do: [],
            else: for(index <- 0..(length - 1), do: property_value(properties, index))

        {:ok, values}

      _ ->
        {:error, :not_an_array}
    end
  end

  defp array_values(_value, _execution), do: {:error, :not_an_array}

  defp property_value(properties, index) do
    case Map.get(properties, index) do
      %Property{value: value} -> value
      nil -> :undefined
    end
  end

  defp regex_match?(%RegExp{source: source}, value) do
    case Regex.compile(source) do
      {:ok, regex} -> Regex.match?(regex, value)
      {:error, _} -> false
    end
  end
end
