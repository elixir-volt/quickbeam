defmodule QuickBEAM.VM.Builtin.Installer do
  @moduledoc """
  Installs declarative builtin specs into one owner-local VM execution.

  Installation is deterministic and threads `%QuickBEAM.VM.Runtime.State{}` through
  the canonical heap and property layers. Installed function objects carry
  stable module/handler tokens rather than captured closures.
  """

  alias QuickBEAM.VM.Builtin.Spec.Accessor, as: AccessorSpec
  alias QuickBEAM.VM.Builtin.Spec.Alias, as: AliasSpec
  alias QuickBEAM.VM.Builtin.Spec.Function, as: FunctionSpec
  alias QuickBEAM.VM.Builtin.Spec.Property, as: PropertySpec
  alias QuickBEAM.VM.Builtin.Spec.Prototype, as: PrototypeSpec
  alias QuickBEAM.VM.Builtin.Spec

  alias QuickBEAM.VM.Runtime.State
  alias QuickBEAM.VM.Runtime.Heap
  alias QuickBEAM.VM.Runtime.Property
  alias QuickBEAM.VM.Runtime.Reference

  @doc "Installs registered builtin modules for the selected profile."
  @spec install_all(State.t(), [module()], atom()) :: State.t()
  def install_all(execution, modules, profile \\ :core) do
    specs =
      modules
      |> Enum.map(& &1.builtin_spec())
      |> Enum.filter(&(:core in &1.profiles or profile in &1.profiles))

    validate_registry!(specs, execution)
    Enum.reduce(specs, execution, &install(&2, &1))
  end

  @doc "Installs one immutable builtin specification."
  @spec install(State.t(), Spec.t()) :: State.t()
  def install(execution, %Spec{kind: :namespace} = spec) do
    {target, execution} = Heap.allocate(execution)
    execution = install_entries(execution, target, spec.module, spec.statics)
    put_global(execution, spec.name, target)
  end

  def install(execution, %Spec{kind: :function} = spec) do
    token = {:declared_builtin, spec.module, :call}
    {target, execution} = allocate_function(execution, spec.name, spec.length, token)
    execution = install_entries(execution, target, spec.module, spec.statics)
    put_global(execution, spec.name, target)
  end

  def install(execution, %Spec{kind: :intrinsic} = spec) do
    target = Map.fetch!(execution.globals, spec.name)
    execution = install_entries(execution, target, spec.module, spec.statics)
    install_prototype_entries(execution, target, spec)
  end

  def install(execution, %Spec{kind: :constructor} = spec) do
    token = {:declared_builtin, spec.module, spec.constructor}
    {constructor, execution} = allocate_function(execution, spec.name, spec.length, token)
    topology = spec.prototype_spec
    parent = resolve_prototype_parent(execution, topology.extends)

    prototype_callable =
      if topology.callable,
        do: {:declared_builtin, spec.module, topology.callable},
        else: nil

    prototype_internal =
      case topology.primitive do
        {kind, value} -> {:primitive, kind, value}
        nil -> nil
      end

    {prototype, execution} =
      Heap.allocate(execution, topology.kind,
        prototype: parent,
        callable: prototype_callable,
        internal: prototype_internal
      )

    {:ok, execution} =
      Property.define(prototype, "constructor", constructor, execution,
        writable: true,
        enumerable: false,
        configurable: true
      )

    {:ok, execution} =
      Property.define(constructor, "prototype", prototype, execution,
        writable: false,
        enumerable: false,
        configurable: false
      )

    execution = install_entries(execution, constructor, spec.module, spec.statics)
    execution = install_entries(execution, prototype, spec.module, spec.prototype)
    execution = put_global(execution, spec.name, constructor)
    register_prototype(execution, prototype, topology)
  end

  defp install_prototype_entries(execution, _target, %Spec{prototype: []}), do: execution

  defp install_prototype_entries(execution, %Reference{} = constructor, spec) do
    case Property.get(constructor, "prototype", execution) do
      {:ok, %Reference{} = prototype} ->
        install_entries(execution, prototype, spec.module, spec.prototype)

      _missing ->
        raise ArgumentError, "builtin extension #{spec.name} has no prototype object"
    end
  end

  defp install_entries(execution, target, module, entries) do
    Enum.reduce(entries, execution, fn entry, execution ->
      install_entry(execution, target, module, entry)
    end)
  end

  defp install_entry(execution, target, module, %FunctionSpec{} = spec) do
    token = {:declared_builtin, module, spec.handler}
    {function, execution} = allocate_function(execution, to_string(spec.key), spec.length, token)

    {:ok, execution} =
      Property.define(target, spec.key, function, execution,
        writable: spec.writable,
        enumerable: spec.enumerable,
        configurable: spec.configurable
      )

    execution
  end

  defp install_entry(execution, target, module, %AccessorSpec{} = spec) do
    {getter, execution} = allocate_optional_function(execution, module, spec.getter, spec.key)
    {setter, execution} = allocate_optional_function(execution, module, spec.setter, spec.key)

    {:ok, execution} =
      Property.define_accessor(target, spec.key, :getter, getter, execution,
        enumerable: spec.enumerable,
        configurable: spec.configurable
      )

    {:ok, execution} =
      Property.define_accessor(target, spec.key, :setter, setter, execution,
        enumerable: spec.enumerable,
        configurable: spec.configurable
      )

    execution
  end

  defp install_entry(execution, target, _module, %AliasSpec{} = spec) do
    {:ok, value} = Property.get(target, spec.target, execution)

    if value == :undefined do
      raise ArgumentError,
            "builtin alias #{inspect(spec.key)} has missing target #{inspect(spec.target)}"
    end

    {:ok, execution} =
      Property.define(target, spec.key, value, execution,
        writable: spec.writable,
        enumerable: spec.enumerable,
        configurable: spec.configurable
      )

    execution
  end

  defp install_entry(execution, target, _module, %PropertySpec{} = spec) do
    {:ok, execution} =
      Property.define(target, spec.key, spec.value, execution,
        writable: spec.writable,
        enumerable: spec.enumerable,
        configurable: spec.configurable
      )

    execution
  end

  defp allocate_function(execution, name, length, callable) do
    {function, execution} = Heap.allocate(execution, :function, callable: callable)

    {:ok, execution} =
      Property.define(function, "name", name, execution,
        writable: false,
        enumerable: false,
        configurable: true
      )

    {:ok, execution} =
      Property.define(function, "length", length, execution,
        writable: false,
        enumerable: false,
        configurable: true
      )

    {function, execution}
  end

  defp allocate_optional_function(execution, _module, nil, _key),
    do: {nil, execution}

  defp allocate_optional_function(execution, module, handler, key) do
    token = {:declared_builtin, module, handler}
    allocate_function(execution, to_string(key), 0, token)
  end

  defp resolve_prototype_parent(execution, :default),
    do: Map.get(execution.default_prototypes, :ordinary)

  defp resolve_prototype_parent(_execution, nil), do: nil

  defp resolve_prototype_parent(execution, parent_name) do
    constructor = Map.fetch!(execution.globals, parent_name)
    {:ok, %Reference{} = prototype} = Property.get(constructor, "prototype", execution)
    prototype
  end

  defp register_prototype(execution, prototype, %PrototypeSpec{} = topology) do
    execution = register_default_prototype(execution, prototype, topology.default_for)

    if topology.error_type,
      do: %{
        execution
        | error_prototypes: Map.put(execution.error_prototypes, topology.error_type, prototype)
      },
      else: execution
  end

  defp register_default_prototype(execution, _prototype, nil), do: execution

  defp register_default_prototype(execution, prototype, :function) do
    execution = %{
      execution
      | default_prototypes: Map.put(execution.default_prototypes, :function, prototype)
    }

    Enum.reduce(execution.heap, execution, fn
      {id, %{kind: :function, prototype: nil}}, execution ->
        {:ok, execution} =
          Property.set_prototype(%Reference{id: id}, prototype, execution)

        execution

      {_id, _object}, execution ->
        execution
    end)
  end

  defp register_default_prototype(execution, prototype, kind),
    do: %{execution | default_prototypes: Map.put(execution.default_prototypes, kind, prototype)}

  defp put_global(execution, name, value),
    do: %{execution | globals: Map.put(execution.globals, name, value)}

  defp validate_registry!(specs, execution) do
    names = Enum.map(specs, & &1.name)

    case names -- Enum.uniq(names) do
      [] ->
        :ok

      duplicates ->
        raise ArgumentError, "duplicate builtin specs: #{inspect(Enum.uniq(duplicates))}"
    end

    Enum.reduce(specs, MapSet.new(Map.keys(execution.globals)), fn spec, available ->
      missing = Enum.reject(spec.depends_on, &MapSet.member?(available, &1))

      if missing != [] do
        raise ArgumentError,
              "builtin #{spec.name} has unavailable dependencies: #{inspect(missing)}"
      end

      if spec.kind == :intrinsic and not MapSet.member?(available, spec.name) do
        raise ArgumentError, "builtin intrinsic #{spec.name} is not installed"
      end

      if spec.kind in [:namespace, :function, :constructor] and
           MapSet.member?(available, spec.name) do
        raise ArgumentError, "builtin #{spec.name} conflicts with an installed global"
      end

      MapSet.put(available, spec.name)
    end)

    :ok
  end
end
