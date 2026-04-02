defmodule QuickBEAM.WasmAPI do
  @moduledoc false

  use GenServer

  alias QuickBEAM.WASM.ImportRewriter

  @table :quickbeam_wasm_handles

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  def ensure_started do
    case Process.whereis(__MODULE__) do
      nil ->
        case GenServer.start(__MODULE__, :ok, name: __MODULE__) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end

      _pid ->
        :ok
    end
  end

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :set])
    {:ok, %{}}
  end

  def compile([bytes]) when is_binary(bytes) do
    ensure_started()

    case QuickBEAM.Native.wasm_compile(bytes) do
      {:ok, mod_ref} ->
        id = System.unique_integer([:positive])
        {exports, imports, custom_sections} = module_metadata(bytes)
        :ets.insert(@table, {id, :module, mod_ref, bytes, exports, imports, custom_sections})
        %{"ok" => id}

      {:error, msg} ->
        %{"error" => msg}
    end
  end

  def validate([bytes]) when is_binary(bytes) do
    ensure_started()

    case QuickBEAM.Native.wasm_compile(bytes) do
      {:ok, mod_ref} ->
        _ = mod_ref
        true

      {:error, _} ->
        false
    end
  end

  def start([mod_id]) when is_integer(mod_id), do: start([mod_id, []])

  def start([mod_id, import_payload]) when is_integer(mod_id) and is_list(import_payload) do
    ensure_started()

    case :ets.lookup(@table, mod_id) do
      [{^mod_id, :module, mod_ref, bytes, exports, imports, custom_sections}] ->
        with {:ok, compiled_mod_ref, memory_initializers} <-
               prepare_module(mod_ref, bytes, imports, import_payload),
             {:ok, inst_ref} <- QuickBEAM.Native.wasm_start(compiled_mod_ref, 65_536, 65_536),
             :ok <- initialize_imported_memories(inst_ref, memory_initializers) do
          id = System.unique_integer([:positive])

          :ets.insert(
            @table,
            {id, :instance, inst_ref, compiled_mod_ref, exports, imports, custom_sections}
          )

          %{"ok" => id}
        else
          {:error, msg} -> %{"error" => msg}
        end

      _ ->
        %{"error" => "module not found"}
    end
  end

  def call([inst_id, func_name, params])
      when is_integer(inst_id) and is_binary(func_name) and is_list(params) do
    ensure_started()

    case :ets.lookup(@table, inst_id) do
      [{^inst_id, :instance, inst_ref, _mod_ref, exports, _imports, _custom_sections}] ->
        export = find_export(exports, func_name)

        case QuickBEAM.Native.wasm_call(inst_ref, func_name, params) do
          {:ok, result} -> %{"ok" => encode_result(result, Map.get(export || %{}, "results", []))}
          {:error, msg} -> %{"error" => msg}
        end

      _ ->
        %{"error" => "instance not found"}
    end
  end

  def module_exports([mod_id]) when is_integer(mod_id) do
    ensure_started()

    case :ets.lookup(@table, mod_id) do
      [{^mod_id, :module, _mod_ref, _bytes, exports, _imports, _custom_sections}] -> exports
      _ -> []
    end
  end

  def module_imports([mod_id]) when is_integer(mod_id) do
    ensure_started()

    case :ets.lookup(@table, mod_id) do
      [{^mod_id, :module, _mod_ref, _bytes, _exports, imports, _custom_sections}] -> imports
      _ -> []
    end
  end

  def memory_size([inst_id]) when is_integer(inst_id) do
    ensure_started()

    with {:ok, inst_ref, _exports} <- fetch_instance(inst_id),
         {:ok, size} <- QuickBEAM.Native.wasm_memory_size(inst_ref) do
      %{"ok" => size}
    else
      {:error, msg} -> %{"error" => msg}
    end
  end

  def memory_grow([inst_id, delta])
      when is_integer(inst_id) and is_integer(delta) and delta >= 0 do
    ensure_started()

    with {:ok, inst_ref, _exports} <- fetch_instance(inst_id),
         {:ok, pages} <- QuickBEAM.Native.wasm_memory_grow(inst_ref, delta) do
      %{"ok" => pages}
    else
      {:error, msg} -> %{"error" => msg}
    end
  end

  def read_memory([inst_id, offset, length])
      when is_integer(inst_id) and is_integer(offset) and is_integer(length) and offset >= 0 and
             length >= 0 do
    ensure_started()

    with {:ok, inst_ref, _exports} <- fetch_instance(inst_id),
         {:ok, bytes} <- QuickBEAM.Native.wasm_read_memory(inst_ref, offset, length) do
      %{"ok" => {:bytes, bytes}}
    else
      {:error, msg} -> %{"error" => msg}
    end
  end

  def write_memory([inst_id, offset, data])
      when is_integer(inst_id) and is_integer(offset) and offset >= 0 and is_binary(data) do
    ensure_started()

    with {:ok, inst_ref, _exports} <- fetch_instance(inst_id),
         :ok <- QuickBEAM.Native.wasm_write_memory(inst_ref, offset, data) do
      %{"ok" => true}
    else
      {:error, msg} -> %{"error" => msg}
    end
  end

  def read_global([inst_id, name]) when is_integer(inst_id) and is_binary(name) do
    ensure_started()

    with {:ok, inst_ref, exports} <- fetch_instance(inst_id),
         export when not is_nil(export) <- find_global_export(exports, name),
         {:ok, value} <- QuickBEAM.Native.wasm_read_global(inst_ref, name) do
      %{"ok" => encode_scalar(value, export["type"])}
    else
      nil -> %{"error" => "global not found"}
      {:error, msg} -> %{"error" => msg}
    end
  end

  def write_global([inst_id, name, value]) when is_integer(inst_id) and is_binary(name) do
    ensure_started()

    with {:ok, inst_ref, exports} <- fetch_instance(inst_id),
         export when not is_nil(export) <- find_global_export(exports, name),
         :ok <- QuickBEAM.Native.wasm_write_global(inst_ref, name, value) do
      %{"ok" => encode_scalar(value, export["type"])}
    else
      nil -> %{"error" => "global not found"}
      {:error, msg} -> %{"error" => msg}
    end
  end

  defp prepare_module(mod_ref, _bytes, [], []), do: {:ok, mod_ref, []}

  defp prepare_module(_mod_ref, bytes, imports, import_payload) do
    case ImportRewriter.rewrite(bytes, imports, import_payload) do
      {:ok, rewritten_bytes, memory_initializers} ->
        case QuickBEAM.Native.wasm_compile(rewritten_bytes) do
          {:ok, rewritten_mod_ref} -> {:ok, rewritten_mod_ref, memory_initializers}
          {:error, msg} -> {:error, msg}
        end

      {:error, msg} ->
        {:error, msg}
    end
  end

  defp initialize_imported_memories(_inst_ref, []), do: :ok

  defp initialize_imported_memories(inst_ref, [bytes]) do
    case QuickBEAM.Native.wasm_write_memory(inst_ref, 0, bytes) do
      :ok -> :ok
      {:error, msg} -> {:error, msg}
    end
  end

  defp initialize_imported_memories(_inst_ref, _many),
    do: {:error, "multiple memory imports are not supported yet"}

  defp fetch_instance(inst_id) do
    case :ets.lookup(@table, inst_id) do
      [{^inst_id, :instance, inst_ref, _mod_ref, exports, _imports, _custom_sections}] ->
        {:ok, inst_ref, exports}

      _ ->
        {:error, "instance not found"}
    end
  end

  def module_custom_sections([mod_id, section_name])
      when is_integer(mod_id) and is_binary(section_name) do
    ensure_started()

    case :ets.lookup(@table, mod_id) do
      [{^mod_id, :module, _mod_ref, _bytes, _exports, _imports, custom_sections}] ->
        custom_sections
        |> Enum.filter(&(&1.name == section_name))
        |> Enum.map(&{:bytes, &1.data})

      _ ->
        []
    end
  end

  defp module_metadata(bytes) do
    case QuickBEAM.WASM.disasm(bytes) do
      {:ok, mod} ->
        {
          Enum.map(mod.exports, &normalize_desc/1),
          Enum.map(mod.imports, &normalize_desc/1),
          mod.custom_sections
        }

      {:error, _} ->
        {[], [], []}
    end
  end

  defp normalize_desc(desc) do
    Enum.into(desc, %{}, fn
      {:kind, :func} -> {"kind", "function"}
      {key, value} -> {to_string(key), normalize_value(value)}
    end)
  end

  defp normalize_value(nil), do: nil
  defp normalize_value(value) when is_boolean(value), do: value
  defp normalize_value(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_value(value) when is_list(value), do: Enum.map(value, &normalize_value/1)
  defp normalize_value(value) when is_map(value), do: normalize_desc(value)
  defp normalize_value(value), do: value

  defp find_export(exports, func_name) do
    Enum.find(exports, &(&1["name"] == func_name and &1["kind"] == "function"))
  end

  defp find_global_export(exports, name) do
    Enum.find(exports, &(&1["name"] == name and &1["kind"] == "global"))
  end

  defp encode_result(_result, []), do: nil
  defp encode_result(result, [type]), do: encode_scalar(result, type)

  defp encode_result(result, types) when is_list(result) do
    result
    |> Enum.zip(types)
    |> Enum.map(fn {value, type} -> encode_scalar(value, type) end)
  end

  defp encode_result(result, _types), do: result

  defp encode_scalar(value, "i64") when is_integer(value), do: Integer.to_string(value)
  defp encode_scalar(value, _type), do: value
end
