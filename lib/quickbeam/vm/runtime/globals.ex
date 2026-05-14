defmodule QuickBEAM.VM.Runtime.Globals do
  @moduledoc "JS global scope: constructors, global functions, and the binding map."

  alias QuickBEAM.VM.Heap

  alias QuickBEAM.VM.Runtime.WebAPIs

  alias QuickBEAM.VM.Runtime.{
    ArrayBufferInstaller,
    ArrayInstaller,
    CollectionInstaller,
    Console,
    CoreConstructorInstaller,
    DateInstaller,
    Errors,
    FunctionInstaller,
    GlobalFunctionInstaller,
    GlobalThisInstaller,
    JSON,
    Math,
    NumberInstaller,
    Object,
    ProxyInstaller,
    Reflect,
    RegExpInstaller,
    StringInstaller,
    Test262Host,
    TypedArrayInstaller
  }

  alias QuickBEAM.VM.Runtime.Constructors, as: ConstructorRegistry
  alias QuickBEAM.VM.Runtime.Globals.Constructors

  @doc "Builds the runtime value represented by this module."
  def build do
    obj_proto = ensure_object_prototype()
    obj_ctor = register("Object", &Constructors.object/2, module: Object, prototype: obj_proto)

    # Set constructor on Object.prototype
    {:obj, proto_ref} = obj_proto
    proto_data = Heap.get_obj(proto_ref, %{})

    if is_map(proto_data),
      do: Heap.put_obj(proto_ref, Map.put(proto_data, "constructor", obj_ctor))

    bindings()
    |> Map.put("Object", obj_ctor)
    |> Map.merge(TypedArrayInstaller.bindings())
    |> Map.merge(CollectionInstaller.bindings())
    |> Map.merge(CoreConstructorInstaller.bindings())
    |> Map.merge(Errors.bindings())
    |> tap(&Heap.put_global_cache/1)
    |> Map.merge(WebAPIs.bindings())
    |> tap(&GlobalThisInstaller.install/1)
    |> tap(&Heap.put_global_cache/1)
  end

  # ── Binding map ──

  defp bindings do
    %{
      "$262" => Test262Host.object(),
      "Array" => ArrayInstaller.constructor(),
      "String" => StringInstaller.constructor(),
      "Number" => NumberInstaller.constructor(),
      "Function" => FunctionInstaller.constructor(),
      "RegExp" => RegExpInstaller.constructor(),
      "Date" => DateInstaller.constructor(),
      "ArrayBuffer" => ArrayBufferInstaller.constructor(),
      "Proxy" => ProxyInstaller.constructor(),
      "Math" => Math.object(),
      "JSON" => JSON.object(),
      "Reflect" => Reflect.object() |> Reflect.install_metadata(),
      "console" => Console.object()
    }
    |> Map.merge(GlobalFunctionInstaller.bindings())
    |> Map.merge(QuickBEAM.VM.Builtin.Discovery.bindings())
  end

  # ── Registration helpers ──

  defp register(name, constructor, opts) do
    ConstructorRegistry.register(name, constructor, opts)
  end

  defp ensure_object_prototype do
    case Heap.get_object_prototype() do
      nil -> Object.build_prototype()
      existing -> existing
    end
  end
end
