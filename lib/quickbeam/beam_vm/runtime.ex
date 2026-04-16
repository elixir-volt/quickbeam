defmodule QuickBEAM.BeamVM.Runtime do
  @moduledoc """
  JS built-in runtime: property resolution, shared helpers, global bindings.

  Domain-specific builtins live in sub-modules:
  - `Runtime.Array` — Array.prototype + Array static
  - `Runtime.StringProto` — String.prototype
  - `Runtime.JSON` — parse/stringify
  - `Runtime.Object` — Object static methods
  - `Runtime.RegExp` — RegExp prototype + exec
  - `Runtime.Builtins` — Math, Number, Boolean, Console, constructors, global functions
  """

  alias QuickBEAM.BeamVM.Runtime.{Array, StringProto, JSON, Object, RegExp, Builtins}

  # ── Global bindings ──

  def global_bindings do
    %{
      "Object" => {:builtin, "Object", Builtins.object_constructor()},
      "Array" => {:builtin, "Array", Builtins.array_constructor()},
      "String" => {:builtin, "String", Builtins.string_constructor()},
      "Number" => {:builtin, "Number", Builtins.number_constructor()},
      "Boolean" => {:builtin, "Boolean", Builtins.boolean_constructor()},
      "Function" => {:builtin, "Function", Builtins.function_constructor()},
      "Error" => {:builtin, "Error", Builtins.error_constructor()},
      "TypeError" => {:builtin, "TypeError", Builtins.error_constructor()},
      "RangeError" => {:builtin, "RangeError", Builtins.error_constructor()},
      "SyntaxError" => {:builtin, "SyntaxError", Builtins.error_constructor()},
      "ReferenceError" => {:builtin, "ReferenceError", Builtins.error_constructor()},
      "Math" => Builtins.math_object(),
      "JSON" => JSON.object(),
      "Date" => {:builtin, "Date", Builtins.date_constructor()},
      "Promise" => {:builtin, "Promise", Builtins.promise_constructor()},
      "RegExp" => {:builtin, "RegExp", Builtins.regexp_constructor()},
      "Map" => {:builtin, "Map", Builtins.map_constructor()},
      "Set" => {:builtin, "Set", Builtins.set_constructor()},
      "Symbol" => {:builtin, "Symbol", Builtins.symbol_constructor()},
      "parseInt" => {:builtin, "parseInt", fn args -> Builtins.parse_int(args) end},
      "parseFloat" => {:builtin, "parseFloat", fn args -> Builtins.parse_float(args) end},
      "isNaN" => {:builtin, "isNaN", fn args -> Builtins.is_nan(args) end},
      "isFinite" => {:builtin, "isFinite", fn args -> Builtins.is_finite(args) end},
      "NaN" => :nan,
      "Infinity" => :infinity,
      "undefined" => :undefined,
      "Map" => {:builtin, "Map", Builtins.map_constructor()},
      "Set" => {:builtin, "Set", Builtins.set_constructor()},
      "WeakMap" => {:builtin, "WeakMap", fn _ -> Runtime.obj_new() end},
      "WeakSet" => {:builtin, "WeakSet", fn _ -> Runtime.obj_new() end},
      "WeakRef" => {:builtin, "WeakRef", fn _ -> Runtime.obj_new() end},
      "Proxy" => {:builtin, "Proxy", fn _ -> Runtime.obj_new() end},
      "console" => Builtins.console_object(),
    }
  end

  # ── Property resolution (prototype chain) ──

  def get_property(value, key) when is_binary(key) do
    case get_own_property(value, key) do
      :undefined -> get_prototype_property(value, key)
      val -> val
    end
  end
  def get_property(value, key) when is_integer(key), do: get_property(value, Integer.to_string(key))
  def get_property(_, _), do: :undefined

  def js_string_length(s) do
    s
    |> String.to_charlist()
    |> Enum.reduce(0, fn cp, acc ->
      if cp > 0xFFFF, do: acc + 2, else: acc + 1
    end)
  end

  defp get_own_property({:obj, ref}, key) do
    case Process.get({:qb_obj, ref}) do
      nil -> :undefined
      list when is_list(list) -> get_own_property(list, key)
      map -> Map.get(map, key, :undefined)
    end
  end
  defp get_own_property(list, "length") when is_list(list), do: length(list)
  defp get_own_property(list, key) when is_list(list) and is_integer(key) do
    if key >= 0 and key < length(list), do: Enum.at(list, key), else: :undefined
  end
  defp get_own_property(list, key) when is_list(list) and is_binary(key) do
    case Integer.parse(key) do
      {idx, ""} when idx >= 0 -> Enum.at(list, idx, :undefined)
      _ -> :undefined
    end
  end
  defp get_own_property(s, "length") when is_binary(s), do: js_string_length(s)
  defp get_own_property(s, key) when is_binary(s), do: StringProto.proto_property(key)

  defp get_own_property(n, _) when is_number(n), do: :undefined
  defp get_own_property(true, _), do: :undefined
  defp get_own_property(false, _), do: :undefined
  defp get_own_property(nil, _), do: :undefined
  defp get_own_property(:undefined, _), do: :undefined
  defp get_own_property({:builtin, _name, map}, key) when is_map(map) do
    Map.get(map, key, :undefined)
  end
  defp get_own_property({:regexp, _, _}, key), do: RegExp.proto_property(key)
  defp get_own_property(_, _), do: :undefined

  defp get_prototype_property({:obj, ref}, key) do
    case Process.get({:qb_obj, ref}) do
      list when is_list(list) -> Array.proto_property(key)
      map when is_map(map) ->
        cond do
          Map.has_key?(map, "__map_data__") -> map_proto(key)
          Map.has_key?(map, "__set_data__") -> set_proto(key)
          true -> :undefined
        end
      _ -> :undefined
    end
  end
  defp get_prototype_property(list, key) when is_list(list), do: Array.proto_property(key)
  defp get_prototype_property(s, key) when is_binary(s), do: StringProto.proto_property(key)
  defp get_prototype_property(n, key) when is_number(n), do: Builtins.number_proto_property(key)
  defp get_prototype_property(true, key), do: Builtins.boolean_proto_property(key)
  defp get_prototype_property(false, key), do: Builtins.boolean_proto_property(key)
  defp get_prototype_property({:builtin, "Error", _}, key), do: Builtins.error_static_property(key)
  defp get_prototype_property({:builtin, "Array", _}, key), do: Array.static_property(key)
  defp get_prototype_property({:builtin, "Object", _}, key), do: Object.static_property(key)
  defp get_prototype_property({:builtin, "Map", _}, _key), do: :undefined
  defp get_prototype_property({:builtin, "Set", _}, _key), do: :undefined
  defp get_prototype_property({:builtin, "Number", _}, key), do: Builtins.number_static_property(key)
  defp get_prototype_property({:builtin, "String", _}, key), do: Builtins.string_static_property(key)
  defp get_prototype_property(_, _), do: :undefined

  defp map_proto("get"), do: {:builtin, "get", fn [key | _], {:obj, ref} ->
    data = Process.get({:qb_obj, ref}, %{}) |> Map.get("__map_data__", %{})
    Map.get(data, key, :undefined)
  end}
  defp map_proto("set"), do: {:builtin, "set", fn [key, val | _], {:obj, ref} ->
    obj = Process.get({:qb_obj, ref}, %{})
    data = Map.get(obj, "__map_data__", %{})
    new_data = Map.put(data, key, val)
    Process.put({:qb_obj, ref}, %{obj | "__map_data__" => new_data, "size" => map_size(new_data)})
    {:obj, ref}
  end}
  defp map_proto("has"), do: {:builtin, "has", fn [key | _], {:obj, ref} ->
    data = Process.get({:qb_obj, ref}, %{}) |> Map.get("__map_data__", %{})
    Map.has_key?(data, key)
  end}
  defp map_proto("delete"), do: {:builtin, "delete", fn [key | _], {:obj, ref} ->
    obj = Process.get({:qb_obj, ref}, %{})
    data = Map.get(obj, "__map_data__", %{})
    new_data = Map.delete(data, key)
    Process.put({:qb_obj, ref}, %{obj | "__map_data__" => new_data, "size" => map_size(new_data)})
    true
  end}
  defp map_proto("forEach"), do: {:builtin, "forEach", fn [cb | _], {:obj, ref}, interp ->
    data = Process.get({:qb_obj, ref}, %{}) |> Map.get("__map_data__", %{})
    Enum.each(data, fn {k, v} -> call_builtin_callback(cb, [v, k, {:obj, ref}], interp) end)
    :undefined
  end}
  defp map_proto(_), do: :undefined

  defp set_proto("has"), do: {:builtin, "has", fn [val | _], {:obj, ref} ->
    data = Process.get({:qb_obj, ref}, %{}) |> Map.get("__set_data__", [])
    val in data
  end}
  defp set_proto("add"), do: {:builtin, "add", fn [val | _], {:obj, ref} ->
    obj = Process.get({:qb_obj, ref}, %{})
    data = Map.get(obj, "__set_data__", [])
    unless val in data do
      new_data = data ++ [val]
      Process.put({:qb_obj, ref}, %{obj | "__set_data__" => new_data, "size" => length(new_data)})
    end
    {:obj, ref}
  end}
  defp set_proto("delete"), do: {:builtin, "delete", fn [val | _], {:obj, ref} ->
    obj = Process.get({:qb_obj, ref}, %{})
    data = Map.get(obj, "__set_data__", [])
    new_data = List.delete(data, val)
    Process.put({:qb_obj, ref}, %{obj | "__set_data__" => new_data, "size" => length(new_data)})
    true
  end}
  defp set_proto(_), do: :undefined

  # ── Callback dispatch (used by higher-order array methods) ──

  def call_builtin_callback(fun, args, interp) do
    case fun do
      {:builtin, _, cb} when is_function(cb, 1) -> cb.(args)
      {:builtin, _, cb} when is_function(cb, 2) -> cb.(args, nil)
      {:builtin, _, cb} when is_function(cb, 3) -> cb.(args, nil, interp)
      %QuickBEAM.BeamVM.Bytecode.Function{} = f ->
        QuickBEAM.BeamVM.Interpreter.invoke_function(f, args, 10_000_000)
      {:closure, _, %QuickBEAM.BeamVM.Bytecode.Function{}} = c ->
        QuickBEAM.BeamVM.Interpreter.invoke_closure(c, args, 10_000_000)
      f when is_function(f) -> apply(f, args)
      _ -> :undefined
    end
  end

  # ── Shared helpers (public for cross-module use) ──

  def obj_new do
    ref = make_ref()
    Process.put({:qb_obj, ref}, %{})
    {:obj, ref}
  end

  def js_truthy(nil), do: false
  def js_truthy(:undefined), do: false
  def js_truthy(false), do: false
  def js_truthy(0), do: false
  def js_truthy(""), do: false
  def js_truthy(_), do: true

  def js_strict_eq(a, b), do: a === b

  def js_to_string(:undefined), do: "undefined"
  def js_to_string(nil), do: "null"
  def js_to_string(true), do: "true"
  def js_to_string(false), do: "false"
  def js_to_string(n) when is_integer(n), do: Integer.to_string(n)
  def js_to_string(n) when is_float(n) do
    s = Float.to_string(n)
    if String.ends_with?(s, ".0"), do: String.slice(s, 0..-3//1), else: s
  end
  def js_to_string(s) when is_binary(s), do: s
  def js_to_string({:obj, _ref}), do: "[object Object]"
  def js_to_string(list) when is_list(list), do: Enum.map(list, &js_to_string/1) |> Enum.join(",")
  def js_to_string(_), do: ""

  def to_int(n) when is_integer(n), do: n
  def to_int(n) when is_float(n), do: trunc(n)
  def to_int(_), do: 0

  def to_float(n) when is_float(n), do: n
  def to_float(n) when is_integer(n), do: n * 1.0
  def to_float(_), do: 0.0

  def to_number(n) when is_number(n), do: n
  def to_number(true), do: 1
  def to_number(false), do: 0
  def to_number(nil), do: 0
  def to_number(:undefined), do: :nan
  def to_number(s) when is_binary(s) do
    case Float.parse(s) do
      {f, ""} -> f
      {f, _} -> f
      :error -> :nan
    end
  end
  def to_number(_), do: :nan

  def normalize_index(idx, len) when idx < 0, do: max(len + idx, 0)
  def normalize_index(idx, len), do: min(idx, len)
end
