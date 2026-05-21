defmodule QuickBEAM.VM.Builtin.Installer do
  @moduledoc "Installs declarative builtin definitions into the VM global heap."

  alias QuickBEAM.VM.Builtin.Definition
  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.Runtime.Constructors

  @doc "Installs all builtin definitions and returns a global binding map."
  def install_all(definitions, opts \\ []) do
    definitions
    |> Enum.filter(& &1.auto_install?)
    |> Enum.reduce(%{}, fn definition, bindings ->
      Map.put(bindings, definition.name, install(definition, opts))
    end)
  end

  @doc "Installs a single builtin definition and returns its constructor."
  def install(%Definition{} = definition, opts \\ []) do
    target = Keyword.get(opts, :target, :global)
    ctor = make_constructor(definition, target)

    install_constructor_metadata(ctor, definition)
    install_constructor_length(ctor, definition)
    Heap.put_ctor_prop_desc(ctor, "prototype", definition.prototype_descriptor)
    install_prototype(ctor, definition, target)
    run_after_install(ctor, definition, after_install_opts(target))

    ctor
  end

  defp make_constructor(definition, :global) do
    Constructors.register(definition.name, definition.constructor,
      module: definition.module,
      auto_proto: true
    )
  end

  defp make_constructor(definition, {:realm, opts}) when is_list(opts) do
    ctor = {:builtin, definition.name, definition.constructor}

    if definition.module do
      Heap.put_ctor_static(ctor, :__module__, definition.module)
    end

    proto =
      %{"constructor" => ctor}
      |> maybe_put_prototype_parent(
        Keyword.fetch!(opts, :object_proto),
        definition.prototype_parent
      )
      |> Heap.wrap()

    Constructors.put_prototype(ctor, proto)
    ctor
  end

  defp install_constructor_metadata(ctor, %Definition{} = definition) do
    Heap.put_ctor_static(
      ctor,
      :__builtin_meta__,
      QuickBEAM.VM.Builtin.meta(definition.name,
        length: definition.length || 0,
        constructable: definition.constructable?
      )
    )
  end

  defp install_constructor_length(_ctor, %Definition{length: nil}), do: :ok

  defp install_constructor_length(ctor, %Definition{length: length}) do
    Heap.put_ctor_static(ctor, "length", length)

    Heap.put_ctor_prop_desc(ctor, "length", %{
      writable: false,
      enumerable: false,
      configurable: true
    })
  end

  defp install_prototype(ctor, definition, target) do
    case Heap.get_ctor_statics(ctor)["prototype"] do
      {:obj, proto_ref} ->
        install_prototype_parent(proto_ref, definition.prototype_parent, target)
        Heap.put_prop_desc(proto_ref, "constructor", definition.constructor_descriptor)

        Enum.each(definition.prototype_properties, fn property ->
          Heap.put_obj_key(proto_ref, property.key, property.value)
          Heap.put_prop_desc(proto_ref, property.key, property.descriptor)
        end)

      _ ->
        :ok
    end
  end

  defp install_prototype_parent(proto_ref, prototype_parent, :global),
    do:
      install_prototype_parent(
        proto_ref,
        prototype_parent,
        {:realm, object_proto: Heap.get_object_prototype()}
      )

  defp install_prototype_parent(proto_ref, prototype_parent, {:realm, opts}),
    do:
      maybe_put_prototype_parent(
        {:obj, proto_ref},
        Keyword.fetch!(opts, :object_proto),
        prototype_parent
      )

  defp maybe_put_prototype_parent(target, object_proto, :object) do
    put_target_parent(target, object_proto)
  end

  defp maybe_put_prototype_parent(target, _object_proto, nil), do: target

  defp put_target_parent({:obj, ref} = object, parent) do
    Heap.put_obj_key(ref, "__proto__", parent)
    object
  end

  defp put_target_parent(map, parent) when is_map(map), do: Map.put(map, "__proto__", parent)

  defp after_install_opts(:global), do: []
  defp after_install_opts({:realm, opts}), do: opts

  defp run_after_install(ctor, %Definition{after_install: after_install}, opts)
       when is_function(after_install, 2),
       do: after_install.(ctor, opts)

  defp run_after_install(ctor, %Definition{after_install: after_install}, _opts)
       when is_function(after_install, 1),
       do: after_install.(ctor)

  defp run_after_install(_ctor, _definition, _opts), do: :ok
end
