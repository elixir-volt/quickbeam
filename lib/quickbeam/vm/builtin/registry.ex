defmodule QuickBEAM.VM.Builtin.Registry do
  @moduledoc """
  Discovers builtin modules from QuickBEAM's compiled application manifest.

  Mix writes the complete module inventory into the `:quickbeam` application
  specification at compile time. Discovery filters that inventory for modules
  exporting `builtin_spec/0`, then orders their immutable specs by declared
  JavaScript dependencies. It does not depend on module loading order.

  The resulting profile registry is cached in `:persistent_term` and versions
  the immutable host templates shared structurally by isolated evaluations.
  """

  alias QuickBEAM.VM.Builtin.Spec

  @application :quickbeam
  @cache_key {__MODULE__, :profiles}
  @generation_key {__MODULE__, :generation}
  @profiles [:core, :ssr]

  @doc "Returns discovered builtin modules in deterministic dependency order."
  @spec modules(:core | :ssr) :: [module()]
  def modules(profile) when profile in @profiles do
    registry()
    |> Map.fetch!(profile)
    |> Enum.map(& &1.module)
  end

  @doc "Returns the cache generation for the current discovered registry."
  @spec generation() :: non_neg_integer()
  def generation do
    _registry = registry()
    :persistent_term.get(@generation_key, 0)
  end

  @doc "Refreshes and returns the builtin registry from the compiled application manifest."
  @spec refresh() :: %{required(:core) => [Spec.t()], required(:ssr) => [Spec.t()]}
  def refresh do
    specs = discover_specs()
    validate_unique_names!(specs)

    registry =
      Map.new(@profiles, fn profile ->
        selected = Enum.filter(specs, &profile_enabled?(&1, profile))
        {profile, dependency_order(selected, profile)}
      end)

    generation = :persistent_term.get(@generation_key, 0) + 1
    :persistent_term.put(@cache_key, registry)
    :persistent_term.put(@generation_key, generation)
    registry
  end

  defp registry do
    case :persistent_term.get(@cache_key, :missing) do
      :missing -> refresh()
      registry -> registry
    end
  end

  defp discover_specs do
    @application
    |> Application.spec(:modules)
    |> List.wrap()
    |> Enum.filter(&builtin_module?/1)
    |> Enum.map(& &1.builtin_spec())
    |> Enum.sort_by(&{&1.name, &1.module})
  end

  defp validate_unique_names!(specs) do
    duplicates =
      specs
      |> Enum.group_by(& &1.name)
      |> Enum.filter(fn {_name, definitions} -> length(definitions) > 1 end)
      |> Map.new(fn {name, definitions} -> {name, Enum.map(definitions, & &1.module)} end)

    if map_size(duplicates) > 0 do
      raise ArgumentError, "duplicate discovered builtin specs: #{inspect(duplicates)}"
    end
  end

  defp builtin_module?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :builtin_spec, 0)
  end

  defp profile_enabled?(%Spec{profiles: profiles}, :core), do: :core in profiles

  defp profile_enabled?(%Spec{profiles: profiles}, profile),
    do: :core in profiles or profile in profiles

  defp dependency_order(specs, profile),
    do: dependency_order(specs, profile, MapSet.new(), [])

  defp dependency_order([], _profile, _available, ordered), do: Enum.reverse(ordered)

  defp dependency_order(specs, profile, available, ordered) do
    {ready, blocked} =
      Enum.split_with(specs, fn spec ->
        Enum.all?(spec.depends_on, &MapSet.member?(available, &1))
      end)

    case ready do
      [] ->
        unresolved =
          Map.new(blocked, fn spec ->
            missing = Enum.reject(spec.depends_on, &MapSet.member?(available, &1))
            {spec.name, missing}
          end)

        raise ArgumentError,
              "cannot order #{inspect(profile)} builtin profile; " <>
                "missing or cyclic dependencies: #{inspect(unresolved)}"

      ready ->
        ready = Enum.sort_by(ready, &{&1.name, &1.module})
        available = Enum.reduce(ready, available, &MapSet.put(&2, &1.name))
        dependency_order(blocked, profile, available, Enum.reverse(ready, ordered))
    end
  end
end
