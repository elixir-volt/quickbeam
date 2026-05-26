defmodule QuickBEAM.VM.Builtin.Installer do
  @moduledoc "Installs declarative builtin definitions into the VM global heap."

  alias QuickBEAM.VM.Builtin
  alias QuickBEAM.VM.Builtin.{Definition, FunctionSpec, PropertySpec}
  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.Runtime.ConstructorRegistry, as: Constructors

  @doc "Installs all builtin definitions and returns a global binding map."
  def install_all(definitions, opts \\ []) do
    definitions
    |> Enum.filter(& &1.auto_install?)
    |> Enum.reduce(%{}, fn definition, bindings ->
      Map.put(bindings, definition.name, install(definition, opts))
    end)
  end

  @doc "Installs a builtin module's declared static specs on a constructor."
  def install_static_specs(ctor, module) when is_atom(module) do
    spec = module.builtin_spec()
    install_property_specs({:constructor, ctor}, module, spec.statics, :static)
  end

  @doc "Installs a builtin module's declared prototype specs on an object reference."
  def install_prototype_specs(proto_ref, module) when is_atom(module) do
    spec = module.builtin_spec()
    install_property_specs({:object, proto_ref}, module, spec.prototype.properties, :prototype)
  end

  @doc "Installs property specs on a constructor or object target."
  def install_property_specs(target, module, specs, namespace) when is_list(specs) do
    Enum.each(specs, &install_property_spec(target, module, &1, namespace))
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

  defp install_property_spec(target, module, %PropertySpec{} = spec, namespace) do
    value = property_value(spec, module, namespace)
    put_property(target, spec.key, value)
    put_property_descriptor(target, spec.key, spec.descriptor)
  end

  defp property_value(
         %PropertySpec{value: %FunctionSpec{} = function_spec, key: key},
         module,
         :prototype
       ) do
    module.proto_property(key)
    |> attach_function_spec(function_spec)
  end

  defp property_value(
         %PropertySpec{value: %FunctionSpec{} = function_spec, key: key},
         module,
         :static
       ) do
    module.static_property(key)
    |> attach_function_spec(function_spec)
  end

  defp property_value(%PropertySpec{value: value}, _module, _namespace), do: value

  defp attach_function_spec({:builtin, name, callback}, %FunctionSpec{} = function_spec) do
    Builtin.builtin(name, callback, Builtin.function_meta(function_spec))
  end

  defp attach_function_spec(value, _function_spec), do: value

  defp put_property({:object, ref}, key, value), do: Heap.put_obj_key(ref, key, value)
  defp put_property({:constructor, ctor}, key, value), do: Heap.put_ctor_static(ctor, key, value)

  defp put_property_descriptor({:object, ref}, key, descriptor),
    do: Heap.put_prop_desc(ref, key, descriptor)

  defp put_property_descriptor({:constructor, ctor}, key, descriptor),
    do: Heap.put_ctor_prop_desc(ctor, key, descriptor)

  defp make_constructor(definition, :global) do
    Constructors.register(definition.name, definition.constructor,
      module: definition.module,
      auto_proto: true
    )
  end

  defp make_constructor(definition, {:realm, opts}) when is_list(opts) do
    constructor_token = make_ref()
    constructor = definition.constructor

    ctor =
      {:builtin, definition.name,
       fn args, this -> {constructor_token, constructor.(args, this)} |> elem(1) end}

    if definition.module do
      Heap.put_ctor_static(ctor, :__module__, definition.module)
    end

    proto =
      case Keyword.get(opts, :prototype) do
        {:obj, _} = existing ->
          Heap.put_obj_key(elem(existing, 1), "constructor", ctor)
          existing

        _ ->
          %{"constructor" => ctor}
          |> maybe_put_prototype_parent(
            Keyword.fetch!(opts, :object_proto),
            definition.prototype_parent
          )
          |> Heap.wrap()
      end

    Constructors.put_prototype(ctor, proto)
    ctor
  end

  defp install_constructor_metadata(ctor, %Definition{} = definition) do
    QuickBEAM.VM.Builtin.put_builtin_metadata(
      ctor,
      QuickBEAM.VM.Builtin.meta(definition.name,
        length: definition.length || 0,
        constructable: definition.constructable?,
        ecma: definition.ecma,
        annex: definition.annex
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

  defp after_install_opts(:global), do: [target: :global]
  defp after_install_opts({:realm, opts}), do: Keyword.put(opts, :target, :realm)

  defp run_after_install(ctor, %Definition{after_install: after_install}, opts)
       when is_function(after_install, 2),
       do: after_install.(ctor, opts)

  defp run_after_install(ctor, %Definition{after_install: after_install}, _opts)
       when is_function(after_install, 1),
       do: after_install.(ctor)

  defp run_after_install(_ctor, _definition, _opts), do: :ok
end
