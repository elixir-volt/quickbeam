defmodule QuickBEAM.VM.Builtins.Object do
  @moduledoc "Defines declarative low-risk and resumable `Object` static methods."

  use QuickBEAM.VM.Builtin

  alias QuickBEAM.VM.Builtin
  alias QuickBEAM.VM.Builtin.Call
  alias QuickBEAM.VM.{Heap, Invocation, Properties, Property, Reference, Value}

  builtin "Object", kind: :intrinsic do
    static :assign, length: 2
    static :create, length: 2
    static :define_property, js: "defineProperty", length: 3
    static :get_own_property_descriptor, js: "getOwnPropertyDescriptor", length: 2
    static :get_own_property_names, js: "getOwnPropertyNames", length: 1
    static :get_prototype_of, js: "getPrototypeOf", length: 1
    static :keys, length: 1
    static :set_prototype_of, js: "setPrototypeOf", length: 2

    prototype do
      method :has_own_property, js: "hasOwnProperty", length: 1
      method :property_is_enumerable, js: "propertyIsEnumerable", length: 1
      method :to_string_method, js: "toString", length: 0
    end
  end

  @doc "Implements `Object.prototype.hasOwnProperty`."
  def has_own_property(%Call{
        this: %Reference{} = object,
        arguments: arguments,
        execution: execution
      }) do
    key = List.first(arguments, :undefined)

    case Properties.own_property(object, key, execution) do
      {:ok, property} -> {:ok, not is_nil(property), execution}
      {:error, reason} -> {:error, reason, execution}
    end
  end

  def has_own_property(%Call{execution: execution}),
    do: {:error, :incompatible_object_receiver, execution}

  @doc "Implements `Object.prototype.propertyIsEnumerable`."
  def property_is_enumerable(%Call{
        this: %Reference{} = object,
        arguments: arguments,
        execution: execution
      }) do
    key = List.first(arguments, :undefined)

    case Properties.own_property(object, key, execution) do
      {:ok, %Property{enumerable: enumerable}} -> {:ok, enumerable, execution}
      {:ok, nil} -> {:ok, false, execution}
      {:error, reason} -> {:error, reason, execution}
    end
  end

  def property_is_enumerable(%Call{execution: execution}),
    do: {:error, :incompatible_object_receiver, execution}

  @doc "Implements the core `Object.prototype.toString` result."
  def to_string_method(%Call{execution: execution}),
    do: {:ok, "[object Object]", execution}

  @doc "Plans resumable `Object.assign` property reads and writes."
  def assign(%Call{
        arguments: [%Reference{} = target | sources],
        caller: caller,
        tail?: tail?,
        execution: execution
      }),
      do: Builtin.action({:object_assign, target, sources, caller, execution, tail?})

  def assign(%Call{execution: execution}), do: {:error, :not_an_object, execution}

  @doc "Implements `Object.create` for null or owner-local prototypes."
  def create(%Call{arguments: [prototype | _], execution: execution})
      when is_nil(prototype) or is_struct(prototype, Reference) do
    {object, execution} = Heap.allocate(execution, :ordinary, prototype: prototype)
    {:ok, object, execution}
  end

  def create(%Call{execution: execution}), do: {:error, :invalid_prototype, execution}

  @doc "Implements `Object.defineProperty` with canonical descriptor validation."
  def define_property(%Call{
        arguments: [%Reference{} = target, key, descriptor | _],
        execution: execution
      }) do
    with {:ok, current} <- Properties.own_property(target, key, execution),
         {:ok, definition} <- descriptor_definition(descriptor, current, execution),
         {:ok, execution} <- apply_property_definition(execution, target, key, definition) do
      {:ok, target, execution}
    else
      {:error, reason} -> {:error, reason, execution}
    end
  end

  def define_property(%Call{execution: execution}),
    do: {:error, :invalid_property_target, execution}

  @doc "Implements `Object.getOwnPropertyDescriptor`."
  def get_own_property_descriptor(%Call{
        arguments: [%Reference{} = target, key | _],
        execution: execution
      }) do
    case Properties.own_property(target, key, execution) do
      {:ok, nil} ->
        {:ok, :undefined, execution}

      {:ok, property} ->
        {descriptor, execution} = descriptor_object(property, execution)
        {:ok, descriptor, execution}

      {:error, reason} ->
        {:error, reason, execution}
    end
  end

  def get_own_property_descriptor(%Call{execution: execution}),
    do: {:error, :invalid_property_target, execution}

  @doc "Implements `Object.getOwnPropertyNames`."
  def get_own_property_names(%Call{
        arguments: [%Reference{} = target | _],
        execution: execution
      }) do
    case Properties.own_property_names(target, execution) do
      {:ok, keys} ->
        {array, execution} = array_from(keys, execution)
        {:ok, array, execution}

      {:error, reason} ->
        {:error, reason, execution}
    end
  end

  def get_own_property_names(%Call{execution: execution}),
    do: {:error, :not_an_object, execution}

  @doc "Implements `Object.getPrototypeOf`."
  def get_prototype_of(%Call{arguments: [%Reference{} = target | _], execution: execution}) do
    case Properties.prototype(target, execution) do
      {:ok, prototype} -> {:ok, prototype, execution}
      {:error, reason} -> {:error, reason, execution}
    end
  end

  def get_prototype_of(%Call{execution: execution}), do: {:error, :not_an_object, execution}

  @doc "Implements `Object.keys` with canonical enumerable-key ordering."
  def keys(%Call{arguments: [value | _], execution: execution}) do
    with {:ok, keys} <- own_keys(value, execution) do
      keys = Enum.map(keys, &Value.to_string_value/1)
      {array, execution} = array_from(keys, execution)
      {:ok, array, execution}
    else
      {:error, reason} -> {:error, reason, execution}
    end
  end

  def keys(%Call{execution: execution}), do: {:error, :missing_argument, execution}

  @doc "Implements `Object.setPrototypeOf` with owner-local cycle validation."
  def set_prototype_of(%Call{
        arguments: [%Reference{} = target, prototype | _],
        execution: execution
      })
      when is_nil(prototype) or is_struct(prototype, Reference) do
    case Properties.set_prototype(target, prototype, execution) do
      {:ok, execution} -> {:ok, target, execution}
      {:error, reason} -> {:error, reason, execution}
    end
  end

  def set_prototype_of(%Call{execution: execution}),
    do: {:error, :invalid_prototype, execution}

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
    if Invocation.callable?(value, execution),
      do: {:ok, value},
      else: {:error, :accessor_not_callable}
  end

  defp accessor?(%Property{kind: :accessor}), do: true
  defp accessor?(_property), do: false

  defp apply_property_definition(execution, target, key, %Property{} = property) do
    if accessor?(property) do
      Properties.define_descriptor(target, key, property, execution)
    else
      Properties.define(target, key, property.value, execution,
        writable: property.writable,
        enumerable: property.enumerable,
        configurable: property.configurable
      )
    end
  end

  defp descriptor_field(%Reference{} = descriptor, key, execution) do
    if Properties.has_property?(descriptor, key, execution) do
      case Properties.get(descriptor, key, execution) do
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
      Enum.reduce(fields, execution, fn {key, value}, execution ->
        {:ok, execution} = Properties.define(descriptor, key, value, execution)
        execution
      end)

    {descriptor, execution}
  end

  defp own_keys(%Reference{} = reference, execution),
    do: Properties.enumerable_keys(reference, execution)

  defp own_keys(value, _execution) when is_map(value), do: {:ok, Map.keys(value)}
  defp own_keys([], _execution), do: {:ok, []}

  defp own_keys(value, _execution) when is_list(value),
    do: {:ok, Enum.to_list(0..(length(value) - 1))}

  defp own_keys(_value, _execution), do: {:ok, []}

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
end
