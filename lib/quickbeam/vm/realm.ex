defmodule QuickBEAM.VM.Realm do
  @moduledoc "Realm-specific global objects and intrinsic prototype lookup."

  alias QuickBEAM.VM.{Heap, Runtime}
  alias QuickBEAM.VM.Runtime.Array
  alias QuickBEAM.VM.Runtime.BigInt, as: JSBigInt
  alias QuickBEAM.VM.Runtime.Boolean, as: JSBoolean
  alias QuickBEAM.VM.Runtime.DataView
  alias QuickBEAM.VM.Runtime.Date, as: JSDate
  alias QuickBEAM.VM.Runtime.Errors
  alias QuickBEAM.VM.Runtime.FinalizationRegistry, as: JSFinalizationRegistry
  alias QuickBEAM.VM.Runtime.Globals.Constructors
  alias QuickBEAM.VM.Runtime.Globals.Functions
  alias QuickBEAM.VM.Runtime.Iterator, as: JSIterator
  alias QuickBEAM.VM.Runtime.Map, as: JSMap
  alias QuickBEAM.VM.Runtime.Promise
  alias QuickBEAM.VM.Runtime.Proxy, as: JSProxy
  alias QuickBEAM.VM.Runtime.RegExp, as: JSRegExp
  alias QuickBEAM.VM.Runtime.Set, as: JSSet
  alias QuickBEAM.VM.Runtime.Number, as: JSNumber
  alias QuickBEAM.VM.Runtime.String, as: JSString
  alias QuickBEAM.VM.ObjectModel.{Get, Prototype, Put}
  alias QuickBEAM.VM.Runtime.WeakRef, as: JSWeakRef

  def create do
    object_proto = Heap.wrap(%{})

    array_ctor =
      QuickBEAM.VM.Builtin.Installer.install(Array.builtin_definition(),
        target: {:realm, object_proto: object_proto}
      )

    array_proto = Heap.get_class_proto(array_ctor)

    boolean_ctor =
      QuickBEAM.VM.Builtin.Installer.install(JSBoolean.builtin_definition(),
        target: {:realm, object_proto: object_proto}
      )

    boolean_proto = Heap.get_class_proto(boolean_ctor)

    number_ctor =
      QuickBEAM.VM.Builtin.Installer.install(JSNumber.builtin_definition(),
        target: {:realm, object_proto: object_proto}
      )

    number_proto = Heap.get_class_proto(number_ctor)

    bigint_ctor =
      QuickBEAM.VM.Builtin.Installer.install(JSBigInt.builtin_definition(),
        target: {:realm, object_proto: object_proto}
      )

    bigint_proto = Heap.get_class_proto(bigint_ctor)

    string_ctor =
      QuickBEAM.VM.Builtin.Installer.install(JSString.builtin_definition(),
        target: {:realm, object_proto: object_proto}
      )

    string_proto = Heap.get_class_proto(string_ctor)

    symbol_ctor =
      QuickBEAM.VM.Builtin.Installer.install(QuickBEAM.VM.Runtime.Symbol.builtin_definition(),
        target: {:realm, object_proto: object_proto}
      )

    symbol_proto = Heap.get_class_proto(symbol_ctor)

    object_ctor =
      QuickBEAM.VM.Runtime.Object.builtin_definition()
      |> Map.put(
        :constructor,
        QuickBEAM.VM.Runtime.Object.realm_constructor(
          object_proto,
          boolean_proto,
          number_proto,
          bigint_proto,
          string_proto,
          symbol_proto
        )
      )
      |> QuickBEAM.VM.Builtin.Installer.install(
        target: {:realm, object_proto: object_proto, prototype: object_proto}
      )

    regexp_ctor =
      QuickBEAM.VM.Builtin.Installer.install(JSRegExp.builtin_definition(),
        target: {:realm, object_proto: object_proto}
      )

    regexp_proto = Heap.get_class_proto(regexp_ctor)

    date_ctor =
      QuickBEAM.VM.Builtin.Installer.install(JSDate.builtin_definition(),
        target: {:realm, object_proto: object_proto}
      )

    date_proto = Heap.get_class_proto(date_ctor)

    data_view_ctor =
      QuickBEAM.VM.Builtin.Installer.install(DataView.builtin_definition(),
        target: {:realm, object_proto: object_proto}
      )

    data_view_proto = Heap.get_class_proto(data_view_ctor)

    map_ctor =
      QuickBEAM.VM.Builtin.Installer.install(map_builtin_definition("Map"),
        target: {:realm, object_proto: object_proto}
      )

    map_proto = Heap.get_class_proto(map_ctor)

    iterator_ctor =
      QuickBEAM.VM.Builtin.Installer.install(JSIterator.builtin_definition(),
        target: {:realm, object_proto: object_proto}
      )

    iterator_proto = Heap.get_class_proto(iterator_ctor)

    set_ctor =
      QuickBEAM.VM.Builtin.Installer.install(set_builtin_definition("Set"),
        target: {:realm, object_proto: object_proto}
      )

    set_proto = Heap.get_class_proto(set_ctor)

    promise_ctor =
      QuickBEAM.VM.Builtin.Installer.install(Promise.builtin_definition(),
        target: {:realm, object_proto: object_proto}
      )

    promise_proto = Heap.get_class_proto(promise_ctor)

    weak_map_ctor =
      QuickBEAM.VM.Builtin.Installer.install(map_builtin_definition("WeakMap"),
        target: {:realm, object_proto: object_proto}
      )

    weak_map_proto = Heap.get_class_proto(weak_map_ctor)

    weak_set_ctor =
      QuickBEAM.VM.Builtin.Installer.install(set_builtin_definition("WeakSet"),
        target: {:realm, object_proto: object_proto}
      )

    weak_set_proto = Heap.get_class_proto(weak_set_ctor)

    weak_ref_ctor =
      QuickBEAM.VM.Builtin.Installer.install(JSWeakRef.builtin_definition(),
        target: {:realm, object_proto: object_proto}
      )

    weak_ref_proto = Heap.get_class_proto(weak_ref_ctor)

    finalization_registry_ctor =
      QuickBEAM.VM.Builtin.Installer.install(JSFinalizationRegistry.builtin_definition(),
        target: {:realm, object_proto: object_proto}
      )

    finalization_registry_proto = Heap.get_class_proto(finalization_registry_ctor)

    function_proto = QuickBEAM.VM.Runtime.Function.prototype(cache: false)
    realm_id = make_ref()

    proxy_ctor =
      QuickBEAM.VM.Builtin.Installer.install(JSProxy.builtin_definition(), target: :global)

    error_bindings = error_bindings(object_proto)
    install_string_methods(string_proto, error_bindings)
    install_regexp_accessors(regexp_proto, Map.fetch!(error_bindings, "TypeError"))

    error_protos =
      for name <-
            ~w(Error EvalError RangeError ReferenceError SyntaxError TypeError URIError AggregateError SuppressedError),
          into: %{},
          do: {name, Heap.get_class_proto(Map.fetch!(error_bindings, name))}

    aggregate_error_proto = Map.fetch!(error_protos, "AggregateError")

    function_intrinsics =
      intrinsics(
        realm_id,
        object_proto,
        function_proto,
        array_proto,
        boolean_proto,
        number_proto,
        string_proto,
        symbol_proto,
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

    function_ctor =
      QuickBEAM.VM.Runtime.Function.builtin_definition()
      |> Map.put(
        :constructor,
        function_constructor_callback(realm_id, object_proto, function_proto, function_intrinsics)
      )
      |> QuickBEAM.VM.Builtin.Installer.install(
        target: {:realm, object_proto: object_proto, prototype: function_proto}
      )

    Process.put({:qb_intrinsics, function_ctor}, function_intrinsics)

    QuickBEAM.VM.Runtime.Function.install_realm_methods(function_proto, function_intrinsics)

    global =
      Heap.wrap(%{
        "Object" => object_ctor,
        "Array" => array_ctor,
        "Function" => function_ctor,
        "eval" => :undefined,
        "Proxy" => proxy_ctor,
        "Boolean" => boolean_ctor,
        "Number" => number_ctor,
        "String" => string_ctor,
        "Symbol" => symbol_ctor,
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

    Heap.put_obj_key(
      elem(global, 1),
      "eval",
      {:builtin, "eval", fn args, _ -> Functions.js_eval_global(args, global) end}
    )

    Process.put({:qb_realm_global, realm_id}, global)
    Heap.wrap(%{"global" => global})
  end

  def global(function) do
    case Process.get({:qb_intrinsics, function}) do
      %{realm_id: realm_id} -> Process.get({:qb_realm_global, realm_id})
      _ -> nil
    end
  end

  def intrinsic({:bound, _, _, target, _}, intrinsic),
    do: intrinsic(target, intrinsic)

  def intrinsic(constructor, intrinsic) do
    case Process.get({:qb_intrinsics, constructor}) do
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

      %{symbol_proto: symbol_proto} when intrinsic == :symbol ->
        symbol_proto

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

  def default_prototype({:builtin, "Array", _}, new_target), do: intrinsic(new_target, :array)
  def default_prototype({:builtin, "Boolean", _}, new_target), do: intrinsic(new_target, :boolean)
  def default_prototype({:builtin, "Number", _}, new_target), do: intrinsic(new_target, :number)
  def default_prototype({:builtin, "String", _}, new_target), do: intrinsic(new_target, :string)
  def default_prototype({:builtin, "Symbol", _}, new_target), do: intrinsic(new_target, :symbol)
  def default_prototype({:builtin, "Date", _}, new_target), do: intrinsic(new_target, :date)

  def default_prototype({:builtin, "DataView", _}, new_target),
    do: intrinsic(new_target, :data_view) || Runtime.global_class_proto("DataView")

  def default_prototype({:builtin, "Function", _}, new_target),
    do: intrinsic(new_target, :function)

  def default_prototype({:builtin, "Map", _}, new_target), do: intrinsic(new_target, :map)

  def default_prototype({:builtin, "Iterator", _}, new_target),
    do: intrinsic(new_target, :iterator)

  def default_prototype({:builtin, "Set", _}, new_target), do: intrinsic(new_target, :set)
  def default_prototype({:builtin, "Promise", _}, new_target), do: intrinsic(new_target, :promise)
  def default_prototype({:builtin, "RegExp", _}, new_target), do: intrinsic(new_target, :regexp)

  def default_prototype({:builtin, "Error", _}, new_target),
    do: intrinsic(new_target, {:native_error, "Error"}) || Runtime.global_class_proto("Error")

  def default_prototype({:builtin, "WeakMap", _}, new_target),
    do: intrinsic(new_target, :weak_map)

  def default_prototype({:builtin, "WeakSet", _}, new_target),
    do: intrinsic(new_target, :weak_set)

  def default_prototype({:builtin, "WeakRef", _}, new_target),
    do: intrinsic(new_target, :weak_ref) || Runtime.global_class_proto("WeakRef")

  def default_prototype({:builtin, "FinalizationRegistry", _}, new_target),
    do:
      intrinsic(new_target, :finalization_registry) ||
        Runtime.global_class_proto("FinalizationRegistry")

  def default_prototype({:builtin, name, _}, new_target)
      when name in ~w(EvalError RangeError ReferenceError SyntaxError TypeError URIError),
      do: intrinsic(new_target, {:native_error, name}) || Runtime.global_class_proto(name)

  def default_prototype({:builtin, "AggregateError", _}, new_target),
    do: intrinsic(new_target, :aggregate_error) || Runtime.global_class_proto("AggregateError")

  def default_prototype({:builtin, "SuppressedError", _}, new_target),
    do:
      intrinsic(new_target, {:native_error, "SuppressedError"}) ||
        Runtime.global_class_proto("SuppressedError")

  def default_prototype(_ctor, new_target), do: intrinsic(new_target, :object)

  defp error_bindings(object_proto), do: Errors.realm_bindings(object_proto)

  defp error_object(type_error_ctor, message) do
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

  defp map_builtin_definition(name),
    do: Enum.find(JSMap.builtin_definitions(), &(&1.name == name))

  defp set_builtin_definition(name),
    do: Enum.find(JSSet.builtin_definitions(), &(&1.name == name))

  defp install_string_methods({:obj, ref}, error_bindings) do
    for name <- ~w(toString valueOf) do
      Heap.put_obj_key(
        ref,
        name,
        string_method(name, Map.fetch!(error_bindings, "TypeError"))
      )

      Heap.put_prop_desc(ref, name, %{writable: true, enumerable: false, configurable: true})
    end
  end

  defp install_regexp_accessors({:obj, ref} = proto, type_error_ctor) do
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
         fn _, this -> regexp_flag(this, proto, flag, type_error_ctor, name) end}

      Heap.put_obj_key(ref, name, {:accessor, getter, nil})
      Heap.put_prop_desc(ref, name, %{enumerable: false, configurable: true})
    end

    for {name, getter_fun} <- [
          {"source", &regexp_source/3},
          {"flags", &regexp_flags/3}
        ] do
      getter =
        {:builtin, "get #{name}", fn _, this -> getter_fun.(this, proto, type_error_ctor) end}

      Heap.put_obj_key(ref, name, {:accessor, getter, nil})
      Heap.put_prop_desc(ref, name, %{enumerable: false, configurable: true})
    end
  end

  defp regexp_flag(this, proto, flag, type_error_ctor, name) do
    cond do
      this == proto ->
        :undefined

      regexp_tuple?(this) ->
        this |> Get.get("flags") |> to_string() |> String.contains?(flag)

      true ->
        throw(
          {:js_throw,
           error_object(
             type_error_ctor,
             "RegExp.prototype.#{name} receiver is not a RegExp"
           )}
        )
    end
  end

  defp regexp_source(this, proto, type_error_ctor) do
    cond do
      this == proto ->
        :undefined

      regexp_tuple?(this) ->
        Get.get(this, "source")

      true ->
        throw(
          {:js_throw,
           error_object(type_error_ctor, "RegExp.prototype.source receiver is not a RegExp")}
        )
    end
  end

  defp regexp_flags(this, proto, type_error_ctor) do
    cond do
      this == proto ->
        :undefined

      regexp_tuple?(this) ->
        Get.get(this, "flags")

      true ->
        throw(
          {:js_throw,
           error_object(type_error_ctor, "RegExp.prototype.flags receiver is not a RegExp")}
        )
    end
  end

  defp regexp_tuple?({:regexp, _, _}), do: true
  defp regexp_tuple?({:regexp, _, _, _}), do: true
  defp regexp_tuple?(_), do: false

  defp string_method(name, type_error_ctor) do
    {:builtin, name,
     fn args, this ->
       {:builtin, _, callback} = JSString.proto_property(name)

       try do
         callback.(args, this)
       catch
         {:js_throw, {:obj, _} = error} ->
           if Get.get(error, "name") == "TypeError" do
             throw({:js_throw, error_object(type_error_ctor, Get.get(error, "message"))})
           else
             throw({:js_throw, error})
           end
       end
     end}
  end

  defp function_constructor_callback(realm_id, object_proto, function_proto, function_intrinsics) do
    fn args, this ->
      body = function_body(args)

      fun =
        {:builtin, "anonymous",
         fn args, call_this ->
           effective_this =
             if call_this in [nil, :undefined],
               do: Process.get({:qb_realm_global, realm_id}),
               else: call_this

           case run_function_body(realm_id, body, args, effective_this) do
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

      Process.put({:qb_intrinsics, fun}, function_intrinsics)

      fun
    end
  end

  defp function_body(args) do
    case List.last(args) do
      body when is_binary(body) -> body
      :undefined -> ""
      nil -> ""
      body -> to_string(body)
    end
  end

  defp run_function_body(_realm_id, "", _args, _this_value), do: :return_this

  defp run_function_body(realm_id, body, args, this_value) do
    cond do
      Regex.match?(~r/^\s*"use strict";\s*return\s+arguments\s*;?\s*$/, body) or
          Regex.match?(~r/^\s*return\s+arguments\s*;?\s*$/, body) ->
        Heap.wrap_arguments(args, thrower: Heap.throw_type_error_intrinsic(realm_id))

      match =
          Regex.run(
            ~r/^\s*([A-Za-z_$][A-Za-z0-9_$]*)\s*=\s*this\s*;\s*return\s*\/(.*)\/([a-z]*)\s*;?\s*$/,
            body
          ) ->
        [_, name, source, flags] = match
        global = Process.get({:qb_realm_global, realm_id})
        Put.put(global, name, this_value)
        Constructors.regexp([source, flags], :undefined)

      true ->
        run_function_side_effect(realm_id, body)
    end
  end

  defp run_function_side_effect(realm_id, body) do
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

  defp intrinsics(
         realm_id,
         object_proto,
         function_proto,
         array_proto,
         boolean_proto,
         number_proto,
         string_proto,
         symbol_proto,
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
      symbol_proto: symbol_proto,
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
