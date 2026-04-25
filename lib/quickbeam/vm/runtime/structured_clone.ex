defmodule QuickBEAM.VM.Runtime.StructuredClone do
  @moduledoc "structuredClone() implementation for BEAM mode."

  import QuickBEAM.VM.Heap.Keys

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.JSThrow

  def clone(val) do
    deep_clone(val)
  end

  defp deep_clone(val) when is_number(val), do: val
  defp deep_clone(val) when is_binary(val), do: val
  defp deep_clone(val) when is_boolean(val), do: val
  defp deep_clone(nil), do: nil
  defp deep_clone(:undefined), do: :undefined
  defp deep_clone(:nan), do: :nan
  defp deep_clone(:infinity), do: :infinity
  defp deep_clone(:neg_infinity), do: :neg_infinity

  defp deep_clone({:closure, _, _} = f) do
    JSThrow.type_error!("#{format_val(f)} could not be cloned.")
  end

  defp deep_clone(%QuickBEAM.VM.Bytecode.Function{} = f) do
    JSThrow.type_error!("#{format_val(f)} could not be cloned.")
  end

  defp deep_clone({:builtin, name, _}) do
    JSThrow.type_error!("function #{name} could not be cloned.")
  end

  defp deep_clone({:regexp, bc, src}) do
    clone_regexp(bc, src)
  end

  defp deep_clone({:obj, ref}) do
    case Heap.get_obj(ref, %{}) do
      {:qb_arr, arr} ->
        new_list = :array.to_list(arr) |> Enum.map(&deep_clone/1)
        new_ref = make_ref()
        Heap.put_obj(new_ref, new_list)
        {:obj, new_ref}

      list when is_list(list) ->
        new_list = Enum.map(list, &deep_clone/1)
        new_ref = make_ref()
        Heap.put_obj(new_ref, new_list)
        {:obj, new_ref}

      map when is_map(map) ->
        clone_object(map)

      other ->
        other
    end
  end

  defp deep_clone(list) when is_list(list) do
    Enum.map(list, &deep_clone/1)
  end

  defp deep_clone({:qb_arr, arr}) do
    new_list = :array.to_list(arr) |> Enum.map(&deep_clone/1)
    new_ref = make_ref()
    Heap.put_obj(new_ref, new_list)
    {:obj, new_ref}
  end

  defp deep_clone(other), do: other

  defp clone_object(map) when is_map(map) do
    cond do
      # Date
      Map.has_key?(map, date_ms()) ->
        clone_date(map)

      # ArrayBuffer
      Map.has_key?(map, buffer()) and not Map.has_key?(map, typed_array()) ->
        clone_array_buffer(map)

      # TypedArray
      Map.has_key?(map, typed_array()) ->
        clone_typed_array(map)

      # Map
      Map.has_key?(map, map_data()) ->
        clone_map(map)

      # Set
      Map.has_key?(map, set_data()) ->
        clone_set(map)

      true ->
        clone_plain_object(map)
    end
  end

  defp clone_object(other), do: other

  defp clone_date(map) do
    ms = Map.get(map, date_ms(), 0)
    new_ref = make_ref()
    proto = get_ctor_proto("Date")
    base = %{date_ms() => ms}
    base = if proto, do: Map.put(base, "__proto__", proto), else: base
    Heap.put_obj(new_ref, base)
    {:obj, new_ref}
  end

  defp clone_array_buffer(map) do
    buf = Map.get(map, buffer(), <<>>)
    new_buf = :binary.copy(buf)
    new_ref = make_ref()
    proto = get_ctor_proto("ArrayBuffer")
    base = %{buffer() => new_buf, "byteLength" => byte_size(new_buf)}
    base = if proto, do: Map.put(base, "__proto__", proto), else: base
    Heap.put_obj(new_ref, base)
    {:obj, new_ref}
  end

  defp clone_typed_array(map) do
    buf = Map.get(map, buffer(), <<>>)
    new_buf = :binary.copy(buf)
    new_ref = make_ref()

    new_ab_ref = make_ref()
    ab_proto = get_ctor_proto("ArrayBuffer")
    ab_base = %{buffer() => new_buf, "byteLength" => byte_size(new_buf)}
    ab_base = if ab_proto, do: Map.put(ab_base, "__proto__", ab_proto), else: ab_base
    Heap.put_obj(new_ab_ref, ab_base)

    new_map =
      Map.merge(map, %{
        buffer() => new_buf,
        "buffer" => {:obj, new_ab_ref}
      })

    Heap.put_obj(new_ref, new_map)
    {:obj, new_ref}
  end

  defp clone_map(map) do
    data = Map.get(map, map_data(), %{})

    new_data =
      Map.new(data, fn {k, v} ->
        {deep_clone(k), deep_clone(v)}
      end)

    new_ref = make_ref()
    proto = get_ctor_proto("Map")
    base = %{map_data() => new_data, "size" => map_size(new_data)}
    base = if proto, do: Map.put(base, "__proto__", proto), else: base
    Heap.put_obj(new_ref, base)
    {:obj, new_ref}
  end

  defp clone_set(map) do
    data = Map.get(map, set_data(), %{})

    new_data =
      Map.new(data, fn {k, _v} ->
        cloned = deep_clone(k)
        {cloned, true}
      end)

    new_ref = make_ref()
    proto = get_ctor_proto("Set")
    base = %{set_data() => new_data, "size" => map_size(new_data)}
    base = if proto, do: Map.put(base, "__proto__", proto), else: base
    Heap.put_obj(new_ref, base)
    {:obj, new_ref}
  end

  defp get_ctor_proto(name) do
    case Heap.get_global_cache() do
      %{^name => ctor} -> Heap.get_class_proto(ctor)
      _ -> nil
    end
  end

  defp clone_plain_object(map) when is_map(map) do
    new_ref = make_ref()

    cloned =
      Map.new(map, fn
        {k, {:builtin, _, _} = fn_val} -> {k, fn_val}
        {k, {:closure, _, _} = fn_val} -> {k, fn_val}
        {k, v} -> {k, deep_clone(v)}
      end)

    Heap.put_obj(new_ref, cloned)
    {:obj, new_ref}
  end

  defp clone_regexp(bc, src) do
    # Wrap the clone in an {obj, ref} so that clone !== original.
    # The object stores the regexp value and also the source/flags as direct properties.
    flags = QuickBEAM.VM.ObjectModel.Get.regexp_flags(bc)
    new_ref = make_ref()

    proto =
      case Heap.get_global_cache() do
        %{"RegExp" => ctor} -> Heap.get_class_proto(ctor)
        _ -> nil
      end

    map = %{
      "__regexp_inner__" => {:regexp, bc, src},
      "source" => src,
      "flags" => flags
    }

    map = if proto, do: Map.put(map, "__proto__", proto), else: map
    Heap.put_obj(new_ref, map)
    {:obj, new_ref}
  end

  defp format_val({:closure, _, _}), do: "function"
  defp format_val(%QuickBEAM.VM.Bytecode.Function{}), do: "function"
  defp format_val(_), do: "value"
end
