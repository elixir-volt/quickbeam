defmodule QuickBEAM.VM.Runtime.Test262Host do
  @moduledoc "Minimal Test262 host hooks used by compatibility tests."

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.Runtime.Array
  alias QuickBEAM.VM.Runtime.Boolean, as: JSBoolean
  alias QuickBEAM.VM.Runtime.Errors
  alias QuickBEAM.VM.Runtime.FinalizationRegistry, as: JSFinalizationRegistry
  alias QuickBEAM.VM.Runtime.Globals.Functions
  alias QuickBEAM.VM.Runtime.Map, as: JSMap
  alias QuickBEAM.VM.Runtime.Set, as: JSSet
  alias QuickBEAM.VM.Runtime.WeakRef, as: JSWeakRef
  alias QuickBEAM.VM.Runtime.Globals.Constructors
  alias QuickBEAM.VM.Runtime.Constructors, as: ConstructorRegistry

  def object do
    Heap.wrap(%{
      "createRealm" => {:builtin, "createRealm", fn _, _ -> create_realm() end}
    })
  end

  def create_realm do
    object_proto = Heap.wrap(%{})
    object_ctor = realm_constructor("Object", &Constructors.object/2, object_proto)
    Heap.put_obj_key(elem(object_proto, 1), "constructor", object_ctor)

    array_proto = Array.prototype()
    array_ctor = realm_constructor("Array", &Constructors.array/2, array_proto)
    Heap.put_obj_key(elem(array_proto, 1), "constructor", array_ctor)

    boolean_proto = Heap.wrap(%{"__proto__" => object_proto})
    boolean_ctor = realm_constructor("Boolean", JSBoolean.constructor(), boolean_proto)
    Heap.put_obj_key(elem(boolean_proto, 1), "constructor", boolean_ctor)

    number_proto = Heap.wrap(%{"__proto__" => object_proto})
    number_ctor = realm_constructor("Number", &Constructors.number/2, number_proto)
    Heap.put_obj_key(elem(number_proto, 1), "constructor", number_ctor)

    string_proto = Heap.wrap(%{"__proto__" => object_proto})
    string_ctor = realm_constructor("String", &Constructors.string/2, string_proto)
    Heap.put_obj_key(elem(string_proto, 1), "constructor", string_ctor)

    map_proto = Heap.wrap(%{"__proto__" => object_proto})
    map_ctor = realm_constructor("Map", JSMap.constructor(), map_proto)
    Heap.put_obj_key(elem(map_proto, 1), "constructor", map_ctor)

    set_proto = Heap.wrap(%{"__proto__" => object_proto})
    set_ctor = realm_constructor("Set", JSSet.constructor(), set_proto)
    Heap.put_obj_key(elem(set_proto, 1), "constructor", set_ctor)

    weak_map_proto = Heap.wrap(%{"__proto__" => object_proto})
    weak_map_ctor = realm_constructor("WeakMap", JSMap.weak_constructor(), weak_map_proto)
    Heap.put_obj_key(elem(weak_map_proto, 1), "constructor", weak_map_ctor)

    weak_set_proto = Heap.wrap(%{"__proto__" => object_proto})
    weak_set_ctor = realm_constructor("WeakSet", JSSet.weak_constructor(), weak_set_proto)
    Heap.put_obj_key(elem(weak_set_proto, 1), "constructor", weak_set_ctor)

    weak_ref_proto = Heap.wrap(%{"__proto__" => object_proto})
    weak_ref_ctor = realm_constructor("WeakRef", JSWeakRef.constructor(), weak_ref_proto)
    Heap.put_obj_key(elem(weak_ref_proto, 1), "constructor", weak_ref_ctor)

    finalization_registry_proto = Heap.wrap(%{"__proto__" => object_proto})

    finalization_registry_ctor =
      realm_constructor(
        "FinalizationRegistry",
        JSFinalizationRegistry.constructor(),
        finalization_registry_proto
      )

    Heap.put_obj_key(
      elem(finalization_registry_proto, 1),
      "constructor",
      finalization_registry_ctor
    )

    function_proto = QuickBEAM.VM.Runtime.Function.prototype()

    function_ctor =
      realm_function_constructor(
        object_proto,
        function_proto,
        array_proto,
        boolean_proto,
        number_proto,
        string_proto,
        map_proto,
        set_proto,
        weak_map_proto,
        weak_set_proto,
        weak_ref_proto,
        finalization_registry_proto
      )

    proxy_ctor = realm_proxy_constructor()
    error_bindings = Errors.bindings()

    global =
      Heap.wrap(%{
        "Object" => object_ctor,
        "Array" => array_ctor,
        "Function" => function_ctor,
        "eval" => {:builtin, "eval", &Functions.js_eval/2},
        "Proxy" => proxy_ctor,
        "Boolean" => boolean_ctor,
        "Number" => number_ctor,
        "String" => string_ctor,
        "Map" => map_ctor,
        "Set" => set_ctor,
        "WeakMap" => weak_map_ctor,
        "WeakSet" => weak_set_ctor,
        "WeakRef" => weak_ref_ctor,
        "FinalizationRegistry" => finalization_registry_ctor,
        "Error" => Map.fetch!(error_bindings, "Error"),
        "TypeError" => Map.fetch!(error_bindings, "TypeError"),
        "RangeError" => Map.fetch!(error_bindings, "RangeError"),
        "SyntaxError" => Map.fetch!(error_bindings, "SyntaxError"),
        "ReferenceError" => Map.fetch!(error_bindings, "ReferenceError")
      })

    Heap.wrap(%{"global" => global})
  end

  def realm_intrinsic(constructor, intrinsic) do
    case Process.get({:qb_realm_intrinsics, constructor}) do
      %{array_proto: array_proto} when intrinsic == :array -> array_proto
      %{boolean_proto: boolean_proto} when intrinsic == :boolean -> boolean_proto
      %{number_proto: number_proto} when intrinsic == :number -> number_proto
      %{string_proto: string_proto} when intrinsic == :string -> string_proto
      %{map_proto: map_proto} when intrinsic == :map -> map_proto
      %{set_proto: set_proto} when intrinsic == :set -> set_proto
      %{weak_map_proto: weak_map_proto} when intrinsic == :weak_map -> weak_map_proto
      %{weak_set_proto: weak_set_proto} when intrinsic == :weak_set -> weak_set_proto
      %{weak_ref_proto: weak_ref_proto} when intrinsic == :weak_ref -> weak_ref_proto
      %{finalization_registry_proto: proto} when intrinsic == :finalization_registry -> proto
      %{object_proto: object_proto} when intrinsic == :object -> object_proto
      _ -> nil
    end
  end

  defp realm_constructor(name, callback, proto) do
    cb = fn args, this -> callback.(args, this) end
    ctor = {:builtin, name, cb}
    ConstructorRegistry.put_prototype(ctor, proto)
    ctor
  end

  defp realm_proxy_constructor do
    ctor = realm_constructor("Proxy", &Constructors.proxy/2, nil)

    Heap.put_ctor_static(
      ctor,
      "revocable",
      {:builtin, "revocable",
       fn [target, handler | _], _ ->
         proxy = Constructors.proxy([target, handler], nil)

         revoke_fn =
           {:builtin, "revoke",
            fn _, _ ->
              case proxy do
                {:obj, proxy_ref} -> Heap.put_obj_key(proxy_ref, "__proxy_revoked__", true)
                _ -> :ok
              end

              :undefined
            end}

         Heap.wrap(%{"proxy" => proxy, "revoke" => revoke_fn})
       end}
    )

    ctor
  end

  defp realm_function_constructor(
         object_proto,
         function_proto,
         array_proto,
         boolean_proto,
         number_proto,
         string_proto,
         map_proto,
         set_proto,
         weak_map_proto,
         weak_set_proto,
         weak_ref_proto,
         finalization_registry_proto
       ) do
    cb = fn _args, _this ->
      fun = {:builtin, "anonymous", fn _, this -> this end}
      Heap.put_class_proto(fun, object_proto)
      Heap.put_ctor_static(fun, "prototype", :undefined)

      Process.put({:qb_realm_intrinsics, fun}, %{
        object_proto: object_proto,
        array_proto: array_proto,
        boolean_proto: boolean_proto,
        number_proto: number_proto,
        string_proto: string_proto,
        map_proto: map_proto,
        set_proto: set_proto,
        weak_map_proto: weak_map_proto,
        weak_set_proto: weak_set_proto,
        weak_ref_proto: weak_ref_proto,
        finalization_registry_proto: finalization_registry_proto
      })

      fun
    end

    ctor = {:builtin, "Function", cb}
    ConstructorRegistry.put_prototype(ctor, function_proto)

    Process.put({:qb_realm_intrinsics, ctor}, %{
      object_proto: object_proto,
      array_proto: array_proto,
      boolean_proto: boolean_proto,
      number_proto: number_proto,
      string_proto: string_proto,
      map_proto: map_proto,
      set_proto: set_proto,
      weak_map_proto: weak_map_proto,
      weak_set_proto: weak_set_proto,
      weak_ref_proto: weak_ref_proto,
      finalization_registry_proto: finalization_registry_proto
    })

    ctor
  end
end
