defmodule QuickBEAM.VM.Builtins do
  @moduledoc """
  Installs and dispatches the JavaScript built-ins supported by the VM profile.
  """

  import Bitwise

  alias QuickBEAM.VM.{Execution, Heap, Object, Property, Reference, RegExp, UTF16, Value}

  @constructors %{
    "Array" => ["isArray"],
    "Boolean" => [],
    "Object" => [
      "assign",
      "create",
      "defineProperty",
      "getOwnPropertyDescriptor",
      "getPrototypeOf",
      "keys",
      "setPrototypeOf"
    ],
    "Function" => [],
    "Math" => ["floor", "max", "min", "random", "round"],
    "Number" => [],
    "String" => ["fromCharCode"],
    "Error" => [],
    "Promise" => ["all", "allSettled", "any", "race", "reject", "resolve"],
    "Set" => []
  }

  @spec install(Execution.t()) :: Execution.t()
  def install(execution) do
    @constructors
    |> Enum.sort_by(fn {name, _methods} ->
      if name == "Object", do: {0, name}, else: {1, name}
    end)
    |> Enum.reduce(execution, fn {name, methods}, execution ->
      {object, execution} = Heap.allocate(execution, :function, callable: {:builtin, name})

      execution =
        Enum.reduce(methods, execution, fn method, execution ->
          {:ok, execution} =
            Heap.define(execution, object, method, {:builtin_method, name, method},
              enumerable: false
            )

          execution
        end)

      execution = maybe_install_prototype(name, object, execution)
      %{execution | globals: Map.put_new(execution.globals, name, object)}
    end)
    |> link_constructor_prototypes()
  end

  @spec callable(Execution.t(), Reference.t()) :: term() | nil
  def callable(execution, %Reference{} = reference) do
    case Heap.fetch_object(execution, reference) do
      {:ok, %Object{callable: callable}} -> callable
      :error -> nil
    end
  end

  @spec call(term(), term(), [term()], Execution.t()) ::
          {:ok, term(), Execution.t()} | {:error, term(), Execution.t()}
  def call({:builtin_method, "Array", "isArray"}, _this, [value], execution),
    do: {:ok, array?(value, execution), execution}

  def call({:builtin_method, "Object", "keys"}, _this, [value], execution) do
    with {:ok, keys} <- own_keys(value, execution) do
      keys = Enum.map(keys, &Value.to_string_value/1)
      {array, execution} = array_from(keys, execution)
      {:ok, array, execution}
    else
      {:error, reason} -> {:error, reason, execution}
    end
  end

  def call({:builtin_method, "Object", "create"}, _this, [prototype], execution)
      when is_nil(prototype) or is_struct(prototype, Reference) do
    {object, execution} = Heap.allocate(execution, :ordinary, prototype: prototype)
    {:ok, object, execution}
  end

  def call({:builtin_method, "Object", "create"}, _this, [_prototype], execution),
    do: {:error, :invalid_prototype, execution}

  def call(
        {:builtin_method, "Object", "defineProperty"},
        _this,
        [%Reference{} = target, key, descriptor | _],
        execution
      ) do
    with {:ok, current} <- Heap.own_property(execution, target, key),
         {:ok, definition} <- descriptor_definition(descriptor, current, execution),
         {:ok, execution} <- define_property(execution, target, key, definition) do
      {:ok, target, execution}
    else
      {:error, reason} -> {:error, reason, execution}
    end
  end

  def call(
        {:builtin_method, "Object", "getOwnPropertyDescriptor"},
        _this,
        [%Reference{} = target, key | _],
        execution
      ) do
    case Heap.own_property(execution, target, key) do
      {:ok, nil} ->
        {:ok, :undefined, execution}

      {:ok, property} ->
        {descriptor, execution} = descriptor_object(property, execution)
        {:ok, descriptor, execution}

      {:error, reason} ->
        {:error, reason, execution}
    end
  end

  def call(
        {:builtin_method, "Object", "getPrototypeOf"},
        _this,
        [%Reference{} = target | _],
        execution
      ) do
    case Heap.prototype(execution, target) do
      {:ok, prototype} -> {:ok, prototype, execution}
      {:error, reason} -> {:error, reason, execution}
    end
  end

  def call(
        {:builtin_method, "Object", "setPrototypeOf"},
        _this,
        [%Reference{} = target, prototype | _],
        execution
      )
      when is_nil(prototype) or is_struct(prototype, Reference) do
    case Heap.set_prototype(execution, target, prototype) do
      {:ok, execution} -> {:ok, target, execution}
      {:error, reason} -> {:error, reason, execution}
    end
  end

  def call({:builtin_method, "Object", "assign"}, _this, [target | sources], execution) do
    Enum.reduce_while(sources, {:ok, target, execution}, fn source, {:ok, target, execution} ->
      case assign(target, source, execution) do
        {:ok, execution} -> {:cont, {:ok, target, execution}}
        {:error, reason} -> {:halt, {:error, reason, execution}}
      end
    end)
  end

  def call({:builtin_method, "Math", "floor"}, _this, [value], execution),
    do: {:ok, value |> Value.to_number() |> floor_number(), execution}

  def call({:builtin_method, "Math", "round"}, _this, [value], execution),
    do: {:ok, value |> Value.to_number() |> round_number(), execution}

  def call({:builtin_method, "Math", "random"}, _this, [], execution),
    do: {:ok, 0.5, execution}

  def call({:builtin_method, "Math", "min"}, _this, values, execution),
    do: {:ok, numeric_extreme(values, &min/2, :infinity), execution}

  def call({:builtin_method, "Math", "max"}, _this, values, execution),
    do: {:ok, numeric_extreme(values, &max/2, :neg_infinity), execution}

  def call({:builtin_method, "String", "fromCharCode"}, _this, values, execution) do
    string = values |> Enum.map(&(Value.to_int32(&1) &&& 0xFFFF)) |> UTF16.from_units()
    {:ok, string, execution}
  end

  def call({:builtin_method, "Promise", method}, _this, [iterable | _], execution)
      when method in ["all", "allSettled", "any", "race"] do
    case array_values(iterable, execution) do
      {:ok, values} ->
        kind =
          %{"all" => :all, "allSettled" => :all_settled, "any" => :any, "race" => :race}[method]

        {promise, execution} = QuickBEAM.VM.Promise.aggregate(execution, kind, values)
        {:ok, promise, execution}

      {:error, reason} ->
        {:error, reason, execution}
    end
  end

  def call(
        {:builtin_method, "Promise", "resolve"},
        _this,
        [%QuickBEAM.VM.PromiseReference{} = promise | _],
        execution
      ),
      do: {:ok, promise, execution}

  def call({:builtin_method, "Promise", "resolve"}, _this, values, execution) do
    {promise, execution} = QuickBEAM.VM.Promise.new(execution)

    value =
      case values do
        [value | _] -> value
        [] -> :undefined
      end

    execution = QuickBEAM.VM.Promise.settle(execution, promise, {:ok, value})
    {:ok, promise, execution}
  end

  def call({:builtin_method, "Promise", "reject"}, _this, values, execution) do
    {promise, execution} = QuickBEAM.VM.Promise.new(execution)

    reason =
      case values do
        [reason | _] -> reason
        [] -> :undefined
      end

    execution = QuickBEAM.VM.Promise.settle(execution, promise, {:error, reason})
    {:ok, promise, execution}
  end

  def call(
        {:primitive_method, :object, "hasOwnProperty"},
        %Reference{} = object,
        [key | _],
        execution
      ) do
    case Heap.own_property(execution, object, key) do
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
    case Heap.own_property(execution, object, key) do
      {:ok, %Property{enumerable: enumerable}} -> {:ok, enumerable, execution}
      {:ok, nil} -> {:ok, false, execution}
      {:error, reason} -> {:error, reason, execution}
    end
  end

  def call({:primitive_method, :object, "toString"}, _object, _arguments, execution),
    do: {:ok, "[object Object]", execution}

  def call({:primitive_method, :number, "toString"}, value, arguments, execution) do
    radix =
      case arguments do
        [radix | _] -> Value.to_int32(radix)
        [] -> 10
      end

    {:ok, number_to_string(value, radix), execution}
  end

  def call({:primitive_method, :number, "toFixed"}, value, arguments, execution) do
    digits =
      case arguments do
        [digits | _] -> Value.to_int32(digits)
        [] -> 0
      end

    {:ok, :erlang.float_to_binary(value / 1, decimals: digits), execution}
  end

  def call({:primitive_method, :string, method}, %Reference{} = receiver, arguments, execution) do
    case primitive_value(receiver, :string, execution) do
      {:ok, value} -> call({:primitive_method, :string, method}, value, arguments, execution)
      :error -> {:error, :incompatible_string_receiver, execution}
    end
  end

  def call({:primitive_method, :string, "toString"}, value, _arguments, execution),
    do: {:ok, value, execution}

  def call({:primitive_method, :string, "toLowerCase"}, value, _arguments, execution),
    do: {:ok, String.downcase(value), execution}

  def call({:primitive_method, :string, "startsWith"}, value, [prefix | _], execution),
    do: {:ok, String.starts_with?(value, Value.to_string_value(prefix)), execution}

  def call({:primitive_method, :string, "includes"}, value, [part | _], execution),
    do: {:ok, String.contains?(value, Value.to_string_value(part)), execution}

  def call({:primitive_method, :string, "charCodeAt"}, value, [index | _], execution) do
    result = UTF16.char_code_at(value, Value.to_int32(index))
    {:ok, result, execution}
  end

  def call({:primitive_method, :string, "slice"}, value, arguments, execution) do
    {start, length} = slice_range(UTF16.length(value), arguments)
    {:ok, UTF16.slice(value, start, length), execution}
  end

  def call({:primitive_method, :string, "replace"}, value, [pattern, replacement | _], execution) do
    {:ok, replace_string(value, pattern, Value.to_string_value(replacement)), execution}
  end

  def call({:primitive_method, :string, "split"}, value, arguments, execution) do
    parts =
      case arguments do
        [] -> [value]
        [separator | _] -> String.split(value, Value.to_string_value(separator))
      end

    {array, execution} = array_from(parts, execution)
    {:ok, array, execution}
  end

  def call({:primitive_method, :regexp, "test"}, %RegExp{} = regexp, [value | _], execution),
    do: {:ok, regex_match?(regexp, Value.to_string_value(value)), execution}

  def call({:primitive_method, :array, "join"}, value, arguments, execution) do
    separator =
      case arguments do
        [separator | _] -> Value.to_string_value(separator)
        [] -> ","
      end

    with {:ok, values} <- array_values(value, execution) do
      {:ok, Enum.map_join(values, separator, &Value.to_string_value/1), execution}
    else
      {:error, reason} -> {:error, reason, execution}
    end
  end

  def call({:primitive_method, :array, "slice"}, value, arguments, execution) do
    with {:ok, values} <- array_values(value, execution) do
      {start, length} = slice_range(length(values), arguments)
      {array, execution} = array_from(Enum.slice(values, start, length), execution)
      {:ok, array, execution}
    else
      {:error, reason} -> {:error, reason, execution}
    end
  end

  def call({:primitive_method, :array, "concat"}, value, arguments, execution) do
    with {:ok, values} <- array_values(value, execution) do
      values =
        Enum.reduce(arguments, values, fn item, values ->
          values ++ concat_values(item, execution)
        end)

      {array, execution} = array_from(values, execution)
      {:ok, array, execution}
    else
      {:error, reason} -> {:error, reason, execution}
    end
  end

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

    {set, execution} = Heap.allocate(execution, :set, internal: MapSet.new(entries))
    {:ok, set, execution}
  end

  def call({:primitive_method, :set, "has"}, %Reference{} = set, [value | _], execution) do
    case Heap.fetch_object(execution, set) do
      {:ok, %Object{kind: :set, internal: entries}} ->
        {:ok, MapSet.member?(entries, value), execution}

      _ ->
        {:error, :not_a_set, execution}
    end
  end

  def call({:primitive_method, :set, "add"}, %Reference{} = set, [value | _], execution) do
    case Heap.update_object(execution, set, fn object ->
           %{object | internal: MapSet.put(object.internal, value)}
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

  def call({:builtin, "Error"}, _this, values, execution),
    do:
      {:ok, %{name: "Error", message: Value.to_string_value(List.first(values) || "")}, execution}

  def call(callable, _this, _arguments, execution),
    do: {:error, {:unsupported_builtin, callable}, execution}

  defp link_constructor_prototypes(execution) do
    case execution.default_prototypes do
      %{function: function_prototype} ->
        Enum.reduce(Map.keys(@constructors), execution, fn name, execution ->
          constructor = Map.fetch!(execution.globals, name)
          {:ok, execution} = Heap.set_prototype(execution, constructor, function_prototype)
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
          Heap.define(execution, prototype, method, {:primitive_method, :object, method},
            enumerable: false
          )

        execution
      end)

    {:ok, execution} =
      Heap.define(execution, prototype, "constructor", constructor, enumerable: false)

    {:ok, execution} =
      Heap.define(execution, constructor, "prototype", prototype, enumerable: false)

    %{
      execution
      | default_prototypes: Map.put(execution.default_prototypes, :ordinary, prototype)
    }
  end

  defp maybe_install_prototype("Function", constructor, execution) do
    {prototype, execution} =
      Heap.allocate(execution, :function,
        callable: {:builtin, "FunctionPrototype"},
        prototype: Map.get(execution.default_prototypes, :ordinary)
      )

    {:ok, execution} =
      Heap.define(execution, constructor, "prototype", prototype, enumerable: false)

    %{
      execution
      | default_prototypes: Map.put(execution.default_prototypes, :function, prototype)
    }
  end

  defp maybe_install_prototype("Array", constructor, execution) do
    install_primitive_prototype(
      constructor,
      :array,
      ["concat", "filter", "forEach", "join", "map", "reduce", "slice", "some"],
      execution
    )
  end

  defp maybe_install_prototype("String", constructor, execution) do
    install_primitive_prototype(
      constructor,
      :string,
      [
        "charCodeAt",
        "includes",
        "replace",
        "slice",
        "split",
        "startsWith",
        "toLowerCase",
        "toString"
      ],
      execution
    )
  end

  defp maybe_install_prototype("Promise", constructor, execution) do
    {prototype, execution} = Heap.allocate(execution)

    {:ok, execution} =
      Heap.define(execution, prototype, "then", {:promise_method, "then"}, enumerable: false)

    {:ok, execution} =
      Heap.define(execution, constructor, "prototype", prototype, enumerable: false)

    execution
  end

  defp maybe_install_prototype(_name, _constructor, execution), do: execution

  defp install_primitive_prototype(constructor, kind, methods, execution) do
    {prototype, execution} = Heap.allocate(execution)

    execution =
      Enum.reduce(methods, execution, fn method, execution ->
        {:ok, execution} =
          Heap.define(execution, prototype, method, {:primitive_method, kind, method},
            enumerable: false
          )

        execution
      end)

    {:ok, execution} =
      Heap.define(execution, constructor, "prototype", prototype, enumerable: false)

    if kind == :array do
      %{
        execution
        | default_prototypes: Map.put(execution.default_prototypes, :array, prototype)
      }
    else
      execution
    end
  end

  defp descriptor_definition(descriptor, current, execution) do
    with {:ok, getter, getter?} <- descriptor_field(descriptor, "get", execution),
         {:ok, setter, setter?} <- descriptor_field(descriptor, "set", execution),
         {:ok, value, value?} <- descriptor_field(descriptor, "value", execution),
         {:ok, writable, writable?} <- descriptor_field(descriptor, "writable", execution),
         {:ok, enumerable, enumerable?} <- descriptor_field(descriptor, "enumerable", execution),
         {:ok, configurable, configurable?} <-
           descriptor_field(descriptor, "configurable", execution),
         :ok <- compatible_descriptor_kinds(getter? or setter?, value? or writable?),
         {:ok, getter} <- accessor_function(getter, getter?, execution),
         {:ok, setter} <- accessor_function(setter, setter?, execution) do
      current = current || %Property{writable: false, enumerable: false, configurable: false}
      accessor? = getter? or setter? or (not value? and not writable? and accessor?(current))

      {:ok,
       if accessor? do
         %Property{
           kind: :accessor,
           value: :undefined,
           writable: false,
           enumerable: if(enumerable?, do: Value.truthy?(enumerable), else: current.enumerable),
           configurable:
             if(configurable?, do: Value.truthy?(configurable), else: current.configurable),
           getter: if(getter?, do: getter, else: current.getter),
           setter: if(setter?, do: setter, else: current.setter)
         }
       else
         %Property{
           value: if(value?, do: value, else: current.value),
           writable: if(writable?, do: Value.truthy?(writable), else: current.writable),
           enumerable: if(enumerable?, do: Value.truthy?(enumerable), else: current.enumerable),
           configurable:
             if(configurable?, do: Value.truthy?(configurable), else: current.configurable)
         }
       end}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp compatible_descriptor_kinds(true, true), do: {:error, :invalid_property_descriptor}
  defp compatible_descriptor_kinds(_accessor?, _data?), do: :ok

  defp accessor_function(_value, false, _execution), do: {:ok, nil}
  defp accessor_function(:undefined, true, _execution), do: {:ok, nil}

  defp accessor_function(value, true, execution) do
    if callable_value?(value, execution),
      do: {:ok, value},
      else: {:error, :accessor_not_callable}
  end

  defp callable_value?(%Reference{} = reference, execution),
    do: not is_nil(callable(execution, reference))

  defp callable_value?(value, _execution) when is_tuple(value),
    do:
      elem(value, 0) in [
        :bound_function,
        :builtin,
        :builtin_method,
        :host_function,
        :primitive_method,
        :promise_method,
        :promise_resolver
      ]

  defp callable_value?(_value, _execution), do: false

  defp accessor?(%Property{kind: :accessor}), do: true
  defp accessor?(_property), do: false

  defp define_property(execution, target, key, %Property{} = property) do
    if accessor?(property) do
      Heap.define_descriptor(execution, target, key, property)
    else
      Heap.define(execution, target, key, property.value,
        writable: property.writable,
        enumerable: property.enumerable,
        configurable: property.configurable
      )
    end
  end

  defp descriptor_field(%Reference{} = descriptor, key, execution) do
    if Heap.has_property?(execution, descriptor, key) do
      case Heap.get(execution, descriptor, key) do
        {:ok, {:accessor, _getter, _receiver}} -> {:error, :accessor_descriptor_field}
        {:ok, value} -> {:ok, value, true}
        {:error, reason} -> {:error, reason}
      end
    else
      {:ok, :undefined, false}
    end
  end

  defp descriptor_field(descriptor, key, _execution) when is_map(descriptor) do
    if Map.has_key?(descriptor, key),
      do: {:ok, Map.fetch!(descriptor, key), true},
      else: {:ok, :undefined, false}
  end

  defp descriptor_field(_descriptor, _key, _execution), do: {:error, :invalid_descriptor}

  defp descriptor_object(property, execution) do
    {descriptor, execution} = Heap.allocate(execution)

    fields =
      if accessor?(property) do
        [
          {"get", property.getter || :undefined},
          {"set", property.setter || :undefined},
          {"enumerable", property.enumerable},
          {"configurable", property.configurable}
        ]
      else
        [
          {"value", property.value},
          {"writable", property.writable},
          {"enumerable", property.enumerable},
          {"configurable", property.configurable}
        ]
      end

    execution =
      fields
      |> Enum.reduce(execution, fn {key, value}, execution ->
        {:ok, execution} = Heap.define(execution, descriptor, key, value)
        execution
      end)

    {descriptor, execution}
  end

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

  defp primitive_value(reference, kind, execution) do
    case Heap.fetch_object(execution, reference) do
      {:ok, %Object{internal: {:primitive, ^kind, value}}} -> {:ok, value}
      _other -> :error
    end
  end

  defp array?(%Reference{} = reference, execution) do
    match?({:ok, %Object{kind: :array}}, Heap.fetch_object(execution, reference))
  end

  defp array?(value, _execution), do: is_list(value)

  defp array_from(values, execution) do
    {array, execution} = Heap.allocate(execution, :array)

    execution =
      values
      |> Enum.with_index()
      |> Enum.reduce(execution, fn {value, index}, execution ->
        {:ok, execution} = Heap.define(execution, array, index, value)
        execution
      end)

    {array, execution}
  end

  defp own_keys(%Reference{} = reference, execution), do: Heap.own_keys(execution, reference)
  defp own_keys(value, _execution) when is_map(value), do: {:ok, Map.keys(value)}
  defp own_keys([], _execution), do: {:ok, []}

  defp own_keys(value, _execution) when is_list(value),
    do: {:ok, Enum.to_list(0..(length(value) - 1))}

  defp own_keys(_value, _execution), do: {:ok, []}

  defp assign(%Reference{} = target, source, execution) do
    with {:ok, keys} <- own_keys(source, execution) do
      Enum.reduce_while(keys, {:ok, execution}, fn key, {:ok, execution} ->
        with {:ok, value} <- property(source, key, execution),
             {:ok, execution} <- Heap.put(execution, target, key, value) do
          {:cont, {:ok, execution}}
        else
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp assign(_target, _source, _execution), do: {:error, :not_an_object}

  defp property(%Reference{} = reference, key, execution) do
    case Heap.get(execution, reference, key) do
      {:ok, {:accessor, _getter, _receiver}} -> {:error, :accessor_in_object_assign}
      result -> result
    end
  end

  defp property(value, key, _execution) when is_map(value),
    do: {:ok, Map.get(value, key, :undefined)}

  defp property(value, key, _execution) when is_list(value),
    do: {:ok, Enum.at(value, key, :undefined)}

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

  defp concat_values(value, execution) do
    case array_values(value, execution) do
      {:ok, values} -> values
      {:error, _} -> [value]
    end
  end

  defp property_value(properties, index) do
    case Map.get(properties, index) do
      %Property{value: value} -> value
      nil -> :undefined
    end
  end

  defp slice_range(size, arguments) do
    start =
      case arguments do
        [start | _] -> normalize_slice_index(start, size)
        [] -> 0
      end

    finish =
      case arguments do
        [_start, finish | _] -> normalize_slice_index(finish, size)
        _ -> size
      end

    {start, max(finish - start, 0)}
  end

  defp normalize_slice_index(value, size) do
    case Value.to_number(value) do
      :infinity -> size
      :neg_infinity -> 0
      :nan -> 0
      index when is_number(index) -> normalize_index(trunc(index), size)
      _value -> 0
    end
  end

  defp normalize_index(index, size) when index < 0, do: max(size + index, 0)
  defp normalize_index(index, size), do: min(index, size)

  defp number_to_string(value, 10), do: Value.to_string_value(value)

  defp number_to_string(value, radix) when is_integer(value) and radix in 2..36,
    do: Integer.to_string(value, radix)

  defp number_to_string(value, _radix), do: Value.to_string_value(value)

  defp regex_match?(%RegExp{source: source}, value) do
    case Regex.compile(source) do
      {:ok, regex} -> Regex.match?(regex, value)
      {:error, _} -> false
    end
  end

  defp replace_string(value, %RegExp{source: source}, replacement) do
    case Regex.compile(source) do
      {:ok, regex} -> Regex.replace(regex, value, replacement)
      {:error, _} -> value
    end
  end

  defp replace_string(value, pattern, replacement),
    do: String.replace(value, Value.to_string_value(pattern), replacement, global: false)

  defp floor_number(value) when is_number(value), do: floor(value)
  defp floor_number(value), do: value
  defp round_number(value) when is_number(value), do: round(value)
  defp round_number(value), do: value

  defp numeric_extreme(values, operation, initial) do
    Enum.reduce(values, initial, fn value, result ->
      operation.(Value.to_number(value), result)
    end)
  end
end
