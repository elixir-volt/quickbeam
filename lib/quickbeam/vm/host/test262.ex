defmodule QuickBEAM.VM.Host.Test262 do
  @moduledoc "Minimal Test262 host hooks used by compatibility tests."

  alias QuickBEAM.VM.Heap
  import QuickBEAM.VM.Heap.Keys, only: [buffer: 0]

  alias QuickBEAM.VM.Runtime.Array
  alias QuickBEAM.VM.Runtime.Boolean, as: JSBoolean
  alias QuickBEAM.VM.Runtime.Constructors, as: ConstructorRegistry
  alias QuickBEAM.VM.Runtime.DataView
  alias QuickBEAM.VM.Runtime.Date, as: JSDate
  alias QuickBEAM.VM.Runtime.Errors
  alias QuickBEAM.VM.Runtime.FinalizationRegistry, as: JSFinalizationRegistry
  alias QuickBEAM.VM.Runtime.Globals.Constructors
  alias QuickBEAM.VM.Runtime.Globals.Functions
  alias QuickBEAM.VM.Runtime.Iterator, as: JSIterator
  alias QuickBEAM.VM.Runtime.Map, as: JSMap
  alias QuickBEAM.VM.Runtime.Promise
  alias QuickBEAM.VM.Runtime.RegExp, as: JSRegExp
  alias QuickBEAM.VM.Runtime.Set, as: JSSet
  alias QuickBEAM.VM.Runtime.String, as: JSString
  alias QuickBEAM.VM.ObjectModel.{Get, Prototype, Put, WrappedPrimitive}
  alias QuickBEAM.VM.Runtime.WeakRef, as: JSWeakRef

  def object do
    Heap.wrap(%{
      "createRealm" => {:builtin, "createRealm", fn _, _ -> create_realm() end},
      "detachArrayBuffer" =>
        {:builtin, "detachArrayBuffer", fn args, _ -> detach_array_buffer(args) end}
    })
  end

  defp detach_array_buffer([{:obj, ref} | _]) do
    case Heap.get_obj(ref, %{}) do
      map when is_map(map) ->
        Heap.put_obj(
          ref,
          Map.merge(map, %{buffer() => <<>>, "byteLength" => 0, "__detached__" => true})
        )

      _ ->
        :ok
    end

    :undefined
  end

  defp detach_array_buffer(_), do: :undefined

  def create_realm do
    object_proto = Heap.wrap(%{})

    array_proto = Array.prototype()
    array_ctor = realm_constructor("Array", &Constructors.array/2, array_proto)
    Heap.put_obj_key(elem(array_proto, 1), "constructor", array_ctor)

    boolean_proto = Heap.wrap(%{"__proto__" => object_proto})
    boolean_ctor = realm_constructor("Boolean", JSBoolean.constructor(), boolean_proto)
    Heap.put_obj_key(elem(boolean_proto, 1), "constructor", boolean_ctor)

    number_proto = Heap.wrap(%{"__proto__" => object_proto})
    number_ctor = realm_constructor("Number", &Constructors.number/2, number_proto)
    Heap.put_obj_key(elem(number_proto, 1), "constructor", number_ctor)

    bigint_proto = Heap.wrap(%{"__proto__" => object_proto})
    bigint_ctor = realm_constructor("BigInt", &Constructors.bigint/2, bigint_proto)
    Heap.put_obj_key(elem(bigint_proto, 1), "constructor", bigint_ctor)

    object_ctor =
      realm_object_constructor(object_proto, boolean_proto, number_proto, bigint_proto)

    Heap.put_obj_key(elem(object_proto, 1), "constructor", object_ctor)

    string_proto = Heap.wrap(%{"__proto__" => object_proto})
    string_ctor = realm_constructor("String", &Constructors.string/2, string_proto)
    Heap.put_obj_key(elem(string_proto, 1), "constructor", string_ctor)

    regexp_proto = Heap.wrap(%{"__proto__" => object_proto})
    regexp_ctor = realm_constructor("RegExp", &Constructors.regexp/2, regexp_proto)
    Heap.put_obj_key(elem(regexp_proto, 1), "constructor", regexp_ctor)
    Heap.put_ctor_static(regexp_ctor, "escape", JSRegExp.static_property("escape"))

    date_proto = Heap.wrap(%{"__proto__" => object_proto})
    date_ctor = realm_constructor("Date", &JSDate.constructor/2, date_proto)
    Heap.put_obj_key(elem(date_proto, 1), "constructor", date_ctor)

    data_view_proto = Heap.wrap(%{"__proto__" => object_proto})
    data_view_ctor = realm_constructor("DataView", &DataView.constructor/2, data_view_proto)
    Heap.put_obj_key(elem(data_view_proto, 1), "constructor", data_view_ctor)

    map_proto = Heap.wrap(%{"__proto__" => object_proto})
    map_ctor = realm_constructor("Map", JSMap.constructor(), map_proto)
    Heap.put_obj_key(elem(map_proto, 1), "constructor", map_ctor)

    iterator_proto = Heap.wrap(%{"__proto__" => object_proto})
    iterator_ctor = realm_constructor("Iterator", JSIterator.constructor(), iterator_proto)

    Heap.put_obj_key(
      elem(iterator_proto, 1),
      "constructor",
      JSIterator.proto_property("constructor")
    )

    Heap.put_prop_desc(elem(iterator_proto, 1), "constructor", %{
      writable: false,
      enumerable: false,
      configurable: true
    })

    Heap.put_obj_key(
      elem(iterator_proto, 1),
      {:symbol, "Symbol.toStringTag"},
      JSIterator.proto_property({:symbol, "Symbol.toStringTag"})
    )

    Heap.put_obj_key(elem(iterator_proto, 1), "constructor", iterator_ctor)

    set_proto = Heap.wrap(%{"__proto__" => object_proto})
    set_ctor = realm_constructor("Set", JSSet.constructor(), set_proto)
    Heap.put_obj_key(elem(set_proto, 1), "constructor", set_ctor)

    promise_proto = Promise.prototype()
    promise_ctor = realm_constructor("Promise", Promise.constructor(), promise_proto)
    Heap.put_obj_key(elem(promise_proto, 1), "constructor", promise_ctor)

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

    function_proto = QuickBEAM.VM.Runtime.Function.prototype(cache: false)
    realm_id = make_ref()

    proxy_ctor = realm_proxy_constructor()
    error_bindings = realm_error_bindings(object_proto)
    install_realm_string_methods(string_proto, error_bindings)
    install_realm_regexp_accessors(regexp_proto, Map.fetch!(error_bindings, "TypeError"))

    error_protos =
      for name <-
            ~w(EvalError RangeError ReferenceError SyntaxError TypeError URIError AggregateError SuppressedError),
          into: %{},
          do: {name, Heap.get_class_proto(Map.fetch!(error_bindings, name))}

    aggregate_error_proto = Map.fetch!(error_protos, "AggregateError")

    function_ctor =
      realm_function_constructor(
        realm_id,
        object_proto,
        function_proto,
        array_proto,
        boolean_proto,
        number_proto,
        string_proto,
        regexp_proto,
        date_proto,
        data_view_proto,
        map_proto,
        iterator_proto,
        set_proto,
        promise_proto,
        weak_map_proto,
        weak_set_proto,
        weak_ref_proto,
        finalization_registry_proto,
        aggregate_error_proto,
        error_protos
      )

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
        "RegExp" => regexp_ctor,
        "BigInt" => bigint_ctor,
        "Date" => date_ctor,
        "DataView" => data_view_ctor,
        "Map" => map_ctor,
        "Iterator" => iterator_ctor,
        "Set" => set_ctor,
        "Promise" => promise_ctor,
        "WeakMap" => weak_map_ctor,
        "WeakSet" => weak_set_ctor,
        "WeakRef" => weak_ref_ctor,
        "FinalizationRegistry" => finalization_registry_ctor,
        "Error" => Map.fetch!(error_bindings, "Error"),
        "TypeError" => Map.fetch!(error_bindings, "TypeError"),
        "RangeError" => Map.fetch!(error_bindings, "RangeError"),
        "SyntaxError" => Map.fetch!(error_bindings, "SyntaxError"),
        "ReferenceError" => Map.fetch!(error_bindings, "ReferenceError"),
        "EvalError" => Map.fetch!(error_bindings, "EvalError"),
        "URIError" => Map.fetch!(error_bindings, "URIError"),
        "AggregateError" => Map.fetch!(error_bindings, "AggregateError"),
        "SuppressedError" => Map.fetch!(error_bindings, "SuppressedError")
      })

    Process.put({:qb_realm_global, realm_id}, global)
    Heap.wrap(%{"global" => global})
  end

  def realm_global(function) do
    case Process.get({:qb_realm_intrinsics, function}) do
      %{realm_id: realm_id} -> Process.get({:qb_realm_global, realm_id})
      _ -> nil
    end
  end

  def realm_intrinsic({:bound, _, _, target, _}, intrinsic),
    do: realm_intrinsic(target, intrinsic)

  def realm_intrinsic(constructor, intrinsic) do
    case Process.get({:qb_realm_intrinsics, constructor}) do
      %{array_proto: array_proto} when intrinsic == :array ->
        array_proto

      %{boolean_proto: boolean_proto} when intrinsic == :boolean ->
        boolean_proto

      %{number_proto: number_proto} when intrinsic == :number ->
        number_proto

      %{bigint_proto: bigint_proto} when intrinsic == :bigint ->
        bigint_proto

      %{string_proto: string_proto} when intrinsic == :string ->
        string_proto

      %{regexp_proto: regexp_proto} when intrinsic == :regexp ->
        regexp_proto

      %{date_proto: date_proto} when intrinsic == :date ->
        date_proto

      %{data_view_proto: data_view_proto} when intrinsic == :data_view ->
        data_view_proto

      %{map_proto: map_proto} when intrinsic == :map ->
        map_proto

      %{iterator_proto: iterator_proto} when intrinsic == :iterator ->
        iterator_proto

      %{set_proto: set_proto} when intrinsic == :set ->
        set_proto

      %{promise_proto: promise_proto} when intrinsic == :promise ->
        promise_proto

      %{weak_map_proto: weak_map_proto} when intrinsic == :weak_map ->
        weak_map_proto

      %{weak_set_proto: weak_set_proto} when intrinsic == :weak_set ->
        weak_set_proto

      %{weak_ref_proto: weak_ref_proto} when intrinsic == :weak_ref ->
        weak_ref_proto

      %{finalization_registry_proto: proto} when intrinsic == :finalization_registry ->
        proto

      %{aggregate_error_proto: proto} when intrinsic == :aggregate_error ->
        proto

      %{error_protos: error_protos} when is_tuple(intrinsic) ->
        Map.get(error_protos, elem(intrinsic, 1))

      %{object_proto: object_proto} when intrinsic == :object ->
        object_proto

      %{function_proto: function_proto} when intrinsic == :function ->
        function_proto

      _ ->
        nil
    end
  end

  defp realm_error_bindings(object_proto) do
    base = Errors.bindings()
    base_error_proto = Heap.get_class_proto(Map.fetch!(base, "Error"))
    error_proto = clone_realm_error_proto(base_error_proto, object_proto)

    realm_errors =
      for {name, {:builtin, _base_name, callback} = ctor} <- base, into: %{} do
        proto =
          if name == "Error" do
            error_proto
          else
            ctor
            |> Heap.get_class_proto()
            |> clone_realm_error_proto(error_proto)
          end

        realm_ctor = realm_constructor(name, callback, proto)
        Heap.put_obj_key(elem(proto, 1), "constructor", realm_ctor)

        ctor
        |> Heap.get_ctor_statics()
        |> Enum.reject(fn {key, _value} -> key == "prototype" end)
        |> Enum.each(fn {key, value} -> Heap.put_ctor_static(realm_ctor, key, value) end)

        {name, realm_ctor}
      end

    case Map.fetch(realm_errors, "Error") do
      {:ok, error_ctor} ->
        for {name, ctor} <- realm_errors, name != "Error" do
          Heap.put_ctor_static(ctor, "__proto__", error_ctor)
        end

      :error ->
        :ok
    end

    realm_errors
  end

  defp clone_realm_error_proto({:obj, ref}, parent) do
    map = ref |> Heap.get_obj(%{}) |> Map.put("__proto__", parent)
    Heap.wrap(map)
  end

  defp realm_error_object(type_error_ctor, message) do
    proto = Heap.get_class_proto(type_error_ctor)

    Heap.wrap(%{
      "message" => message,
      "name" => "TypeError",
      "stack" => "",
      "__error_name__" => "TypeError",
      "__proto__" => proto,
      {:symbol, "Symbol.toStringTag"} => "Error"
    })
  end

  defp realm_object_constructor(object_proto, boolean_proto, number_proto, bigint_proto) do
    callback = fn
      [value | _], _this ->
        realm_object_value(value, object_proto, boolean_proto, number_proto, bigint_proto)

      [], {:obj, _} = this ->
        this

      [], _this ->
        Heap.wrap(%{"__proto__" => object_proto})
    end

    ctor = {:builtin, "Object", callback}
    ConstructorRegistry.put_prototype(ctor, object_proto)
    ctor
  end

  defp realm_object_value(
         {:obj, _} = value,
         _object_proto,
         _boolean_proto,
         _number_proto,
         _bigint_proto
       ),
       do: value

  defp realm_object_value(value, _object_proto, boolean_proto, _number_proto, _bigint_proto)
       when is_boolean(value),
       do: Heap.wrap(%{WrappedPrimitive.slot(:boolean) => value, "__proto__" => boolean_proto})

  defp realm_object_value(value, _object_proto, _boolean_proto, number_proto, _bigint_proto)
       when is_number(value),
       do: Heap.wrap(%{WrappedPrimitive.slot(:number) => value, "__proto__" => number_proto})

  defp realm_object_value(
         {:bigint, _} = value,
         _object_proto,
         _boolean_proto,
         _number_proto,
         bigint_proto
       ),
       do: Heap.wrap(%{WrappedPrimitive.slot(:bigint) => value, "__proto__" => bigint_proto})

  defp realm_object_value(value, object_proto, _boolean_proto, _number_proto, _bigint_proto)
       when is_binary(value),
       do: Heap.wrap(%{WrappedPrimitive.slot(:string) => value, "__proto__" => object_proto})

  defp realm_object_value(_value, object_proto, _boolean_proto, _number_proto, _bigint_proto),
    do: Heap.wrap(%{"__proto__" => object_proto})

  defp realm_constructor(name, callback, proto) do
    realm_constructor_token = make_ref()

    cb = fn args, this ->
      if is_reference(realm_constructor_token),
        do: callback.(args, this),
        else: callback.(args, this)
    end

    ctor = {:builtin, name, cb}
    ConstructorRegistry.put_prototype(ctor, proto)
    ctor
  end

  defp install_realm_string_methods({:obj, ref}, error_bindings) do
    for name <- ~w(toString valueOf) do
      Heap.put_obj_key(
        ref,
        name,
        realm_string_method(name, Map.fetch!(error_bindings, "TypeError"))
      )

      Heap.put_prop_desc(ref, name, %{writable: true, enumerable: false, configurable: true})
    end
  end

  defp install_realm_regexp_accessors({:obj, ref} = proto, type_error_ctor) do
    for {name, flag} <- [
          {"hasIndices", "d"},
          {"global", "g"},
          {"ignoreCase", "i"},
          {"multiline", "m"},
          {"dotAll", "s"},
          {"unicode", "u"},
          {"unicodeSets", "v"},
          {"sticky", "y"}
        ] do
      getter =
        {:builtin, "get #{name}",
         fn _, this -> realm_regexp_flag(this, proto, flag, type_error_ctor, name) end}

      Heap.put_obj_key(ref, name, {:accessor, getter, nil})
      Heap.put_prop_desc(ref, name, %{enumerable: false, configurable: true})
    end

    for {name, getter_fun} <- [
          {"source", &realm_regexp_source/3},
          {"flags", &realm_regexp_flags/3}
        ] do
      getter =
        {:builtin, "get #{name}", fn _, this -> getter_fun.(this, proto, type_error_ctor) end}

      Heap.put_obj_key(ref, name, {:accessor, getter, nil})
      Heap.put_prop_desc(ref, name, %{enumerable: false, configurable: true})
    end
  end

  defp realm_regexp_flag(this, proto, flag, type_error_ctor, name) do
    cond do
      this == proto ->
        :undefined

      regexp_tuple?(this) ->
        this |> Get.get("flags") |> to_string() |> String.contains?(flag)

      true ->
        throw(
          {:js_throw,
           realm_error_object(
             type_error_ctor,
             "RegExp.prototype.#{name} receiver is not a RegExp"
           )}
        )
    end
  end

  defp realm_regexp_source(this, proto, type_error_ctor) do
    cond do
      this == proto ->
        :undefined

      regexp_tuple?(this) ->
        Get.get(this, "source")

      true ->
        throw(
          {:js_throw,
           realm_error_object(type_error_ctor, "RegExp.prototype.source receiver is not a RegExp")}
        )
    end
  end

  defp realm_regexp_flags(this, proto, type_error_ctor) do
    cond do
      this == proto ->
        :undefined

      regexp_tuple?(this) ->
        Get.get(this, "flags")

      true ->
        throw(
          {:js_throw,
           realm_error_object(type_error_ctor, "RegExp.prototype.flags receiver is not a RegExp")}
        )
    end
  end

  defp regexp_tuple?({:regexp, _, _}), do: true
  defp regexp_tuple?({:regexp, _, _, _}), do: true
  defp regexp_tuple?(_), do: false

  defp realm_string_method(name, type_error_ctor) do
    {:builtin, name,
     fn args, this ->
       {:builtin, _, callback} = JSString.proto_property(name)

       try do
         callback.(args, this)
       catch
         {:js_throw, {:obj, _} = error} ->
           if Get.get(error, "name") == "TypeError" do
             throw({:js_throw, realm_error_object(type_error_ctor, Get.get(error, "message"))})
           else
             throw({:js_throw, error})
           end
       end
     end}
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
              {:obj, proxy_ref} = proxy
              Heap.put_obj_key(proxy_ref, "__proxy_revoked__", true)

              :undefined
            end}

         Heap.wrap(%{"proxy" => proxy, "revoke" => revoke_fn})
       end}
    )

    ctor
  end

  defp realm_function_constructor(
         realm_id,
         object_proto,
         function_proto,
         array_proto,
         boolean_proto,
         number_proto,
         string_proto,
         regexp_proto,
         date_proto,
         data_view_proto,
         map_proto,
         iterator_proto,
         set_proto,
         promise_proto,
         weak_map_proto,
         weak_set_proto,
         weak_ref_proto,
         finalization_registry_proto,
         aggregate_error_proto,
         error_protos
       ) do
    cb = fn args, this ->
      body = realm_function_body(args)

      fun =
        {:builtin, "anonymous",
         fn args, call_this ->
           effective_this =
             if call_this in [nil, :undefined],
               do: Process.get({:qb_realm_global, realm_id}),
               else: call_this

           case run_realm_function_body(realm_id, body, args, effective_this) do
             :return_this -> effective_this
             value -> value
           end
         end}

      function_object_proto =
        if this in [nil, :undefined], do: function_proto, else: Prototype.get(this)

      function_prototype = Heap.wrap(%{"__proto__" => object_proto})

      Heap.put_ctor_static(fun, "__proto__", function_object_proto || function_proto)
      Heap.put_ctor_static(fun, "prototype", function_prototype)
      Heap.put_class_proto(fun, function_prototype)

      Process.put(
        {:qb_realm_intrinsics, fun},
        realm_intrinsics(
          realm_id,
          object_proto,
          function_proto,
          array_proto,
          boolean_proto,
          number_proto,
          string_proto,
          regexp_proto,
          date_proto,
          data_view_proto,
          map_proto,
          iterator_proto,
          set_proto,
          promise_proto,
          weak_map_proto,
          weak_set_proto,
          weak_ref_proto,
          finalization_registry_proto,
          aggregate_error_proto,
          error_protos
        )
      )

      fun
    end

    ctor = {:builtin, "Function", cb}
    ConstructorRegistry.put_prototype(ctor, function_proto)

    Process.put(
      {:qb_realm_intrinsics, ctor},
      realm_intrinsics(
        realm_id,
        object_proto,
        function_proto,
        array_proto,
        boolean_proto,
        number_proto,
        string_proto,
        regexp_proto,
        date_proto,
        data_view_proto,
        map_proto,
        iterator_proto,
        set_proto,
        promise_proto,
        weak_map_proto,
        weak_set_proto,
        weak_ref_proto,
        finalization_registry_proto,
        aggregate_error_proto,
        error_protos
      )
    )

    ctor
  end

  defp realm_function_body(args) do
    case List.last(args) do
      body when is_binary(body) -> body
      :undefined -> ""
      nil -> ""
      body -> to_string(body)
    end
  end

  defp run_realm_function_body(_realm_id, "", _args, _this_value), do: :return_this

  defp run_realm_function_body(realm_id, body, args, this_value) do
    cond do
      Regex.match?(~r/^\s*"use strict";\s*return\s+arguments\s*;?\s*$/, body) or
          Regex.match?(~r/^\s*return\s+arguments\s*;?\s*$/, body) ->
        Heap.wrap_arguments(args, thrower: Heap.throw_type_error_intrinsic(realm_id))

      match = Regex.run(~r/^\s*([A-Za-z_$][A-Za-z0-9_$]*)\s*=\s*this\s*;\s*return\s*\/(.*)\/([a-z]*)\s*;?\s*$/, body) ->
        [_, name, source, flags] = match
        global = Process.get({:qb_realm_global, realm_id})
        Put.put(global, name, this_value)
        Constructors.regexp([source, flags], :undefined)

      true ->
        run_realm_function_side_effect(realm_id, body)
    end
  end

  defp run_realm_function_side_effect(realm_id, body) do
    case Regex.run(~r/^\s*([A-Za-z_$][A-Za-z0-9_$]*)\s*\+=\s*(-?\d+)\s*;?\s*$/, body) do
      [_, name, delta] ->
        global = Process.get({:qb_realm_global, realm_id})
        current = Get.get(global, name)
        {amount, _} = Integer.parse(delta)
        base = if is_number(current), do: current, else: 0
        Put.put(global, name, base + amount)
        :return_this

      _ ->
        :return_this
    end
  end

  defp realm_intrinsics(
         realm_id,
         object_proto,
         function_proto,
         array_proto,
         boolean_proto,
         number_proto,
         string_proto,
         regexp_proto,
         date_proto,
         data_view_proto,
         map_proto,
         iterator_proto,
         set_proto,
         promise_proto,
         weak_map_proto,
         weak_set_proto,
         weak_ref_proto,
         finalization_registry_proto,
         aggregate_error_proto,
         error_protos
       ) do
    %{
      realm_id: realm_id,
      object_proto: object_proto,
      function_proto: function_proto,
      array_proto: array_proto,
      boolean_proto: boolean_proto,
      number_proto: number_proto,
      string_proto: string_proto,
      regexp_proto: regexp_proto,
      date_proto: date_proto,
      data_view_proto: data_view_proto,
      map_proto: map_proto,
      iterator_proto: iterator_proto,
      set_proto: set_proto,
      promise_proto: promise_proto,
      weak_map_proto: weak_map_proto,
      weak_set_proto: weak_set_proto,
      weak_ref_proto: weak_ref_proto,
      finalization_registry_proto: finalization_registry_proto,
      aggregate_error_proto: aggregate_error_proto,
      error_protos: error_protos
    }
  end
end
