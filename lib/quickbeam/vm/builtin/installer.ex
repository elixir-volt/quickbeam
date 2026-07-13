defmodule QuickBEAM.VM.Builtin.Installer do
  @moduledoc """
  Installs declarative builtin specs into one owner-local VM execution.

  Installation is deterministic and threads `%QuickBEAM.VM.Execution{}` through
  the canonical heap and property layers. Installed function objects carry
  stable module/handler tokens rather than captured closures.
  """

  alias QuickBEAM.VM.Builtin.{FunctionSpec, PropertySpec, Spec}
  alias QuickBEAM.VM.{Execution, Heap, Properties, Reference}

  @doc "Installs registered builtin modules for the selected profile."
  @spec install_all(Execution.t(), [module()], atom()) :: Execution.t()
  def install_all(execution, modules, profile \\ :core) do
    specs =
      modules
      |> Enum.map(& &1.builtin_spec())
      |> Enum.filter(&(&1.profile == profile))

    validate_registry!(specs)
    Enum.reduce(specs, execution, &install(&2, &1))
  end

  @doc "Installs one immutable builtin specification."
  @spec install(Execution.t(), Spec.t()) :: Execution.t()
  def install(execution, %Spec{kind: :object} = spec) do
    {target, execution} = Heap.allocate(execution)
    execution = install_entries(execution, target, spec.module, spec.statics)
    put_global(execution, spec.name, target)
  end

  def install(execution, %Spec{kind: :extension} = spec) do
    target = Map.fetch!(execution.globals, spec.name)
    execution = install_entries(execution, target, spec.module, spec.statics)
    install_prototype_entries(execution, target, spec)
  end

  def install(execution, %Spec{kind: :constructor} = spec) do
    token = {:declared_builtin, spec.module, spec.constructor}
    {constructor, execution} = allocate_function(execution, spec.name, spec.length, token)
    {prototype, execution} = Heap.allocate(execution)

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

    execution = install_entries(execution, constructor, spec.module, spec.statics)
    execution = install_entries(execution, prototype, spec.module, spec.prototype)
    put_global(execution, spec.name, constructor)
  end

  defp install_prototype_entries(execution, _target, %Spec{prototype: []}), do: execution

  defp install_prototype_entries(execution, %Reference{} = constructor, spec) do
    case Properties.get(constructor, "prototype", execution) do
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
      Properties.define(target, spec.key, function, execution,
        writable: spec.writable,
        enumerable: spec.enumerable,
        configurable: spec.configurable
      )

    execution
  end

  defp install_entry(execution, target, _module, %PropertySpec{} = spec) do
    {:ok, execution} =
      Properties.define(target, spec.key, spec.value, execution,
        writable: spec.writable,
        enumerable: spec.enumerable,
        configurable: spec.configurable
      )

    execution
  end

  defp allocate_function(execution, name, length, callable) do
    {function, execution} = Heap.allocate(execution, :function, callable: callable)

    {:ok, execution} =
      Properties.define(function, "name", name, execution,
        writable: false,
        enumerable: false,
        configurable: true
      )

    {:ok, execution} =
      Properties.define(function, "length", length, execution,
        writable: false,
        enumerable: false,
        configurable: true
      )

    {function, execution}
  end

  defp put_global(execution, name, value),
    do: %{execution | globals: Map.put(execution.globals, name, value)}

  defp validate_registry!(specs) do
    names = Enum.map(specs, & &1.name)

    case names -- Enum.uniq(names) do
      [] ->
        :ok

      duplicates ->
        raise ArgumentError, "duplicate builtin specs: #{inspect(Enum.uniq(duplicates))}"
    end
  end
end
