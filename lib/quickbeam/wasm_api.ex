defmodule QuickBEAM.WasmAPI do
  @moduledoc false

  use GenServer

  alias QuickBEAM.WASM.ImportRewriter

  @type module_handle :: {reference(), binary(), [map()], [map()], list()}
  @type instance_handle :: {reference(), reference(), [map()], [map()], list()}
  @type state :: %{
          next_id: pos_integer(),
          modules: %{integer() => module_handle()},
          instances: %{integer() => instance_handle()}
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  @doc false
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
    {:ok, %{next_id: 1, modules: %{}, instances: %{}}}
  end

  @spec compile([binary()]) :: map()
  def compile([bytes]) when is_binary(bytes) do
    ensure_started()
    GenServer.call(__MODULE__, {:compile, bytes}, :infinity)
  end

  @spec validate([binary()]) :: boolean()
  def validate([bytes]) when is_binary(bytes) do
    case QuickBEAM.Native.wasm_compile(bytes) do
      {:ok, mod_ref} ->
        _ = mod_ref
        true

      {:error, _} ->
        false
    end
  end

  @spec prepare(list()) :: map()
  def prepare([bytes, import_payload]) when is_binary(bytes) and is_list(import_payload) do
    case prepare_bytes(bytes, import_payload) do
      {:ok, rewritten_bytes, memory_initializers, function_imports} ->
        %{
          "ok" => %{
            "bytes" => {:bytes, rewritten_bytes},
            "memory_initializers" => Enum.map(memory_initializers, &{:bytes, &1}),
            "function_imports" => Enum.map(function_imports, &normalize_desc/1)
          }
        }

      {:error, msg} ->
        %{"error" => msg}
    end
  end

  @spec start(list(), pid() | nil) :: map()
  def start([mod_id]) when is_integer(mod_id), do: start([mod_id, []], nil)

  def start([mod_id, import_payload], caller)
      when is_integer(mod_id) and is_list(import_payload) do
    ensure_started()
    GenServer.call(__MODULE__, {:start, mod_id, import_payload, runtime_resource(caller)}, :infinity)
  end

  @spec call(list()) :: map()
  def call([inst_id, func_name, params])
      when is_integer(inst_id) and is_binary(func_name) and is_list(params) do
    ensure_started()
    GenServer.call(__MODULE__, {:call, inst_id, func_name, params}, :infinity)
  end

  @spec module_exports([integer()]) :: [map()]
  def module_exports([mod_id]) when is_integer(mod_id) do
    ensure_started()
    GenServer.call(__MODULE__, {:module_exports, mod_id}, :infinity)
  end

  @spec module_imports([integer()]) :: [map()]
  def module_imports([mod_id]) when is_integer(mod_id) do
    ensure_started()
    GenServer.call(__MODULE__, {:module_imports, mod_id}, :infinity)
  end

  @spec memory_size([integer()]) :: map()
  def memory_size([inst_id]) when is_integer(inst_id) do
    ensure_started()
    GenServer.call(__MODULE__, {:memory_size, inst_id}, :infinity)
  end

  @spec memory_grow(list()) :: map()
  def memory_grow([inst_id, delta])
      when is_integer(inst_id) and is_integer(delta) and delta >= 0 do
    ensure_started()
    GenServer.call(__MODULE__, {:memory_grow, inst_id, delta}, :infinity)
  end

  @spec read_memory(list()) :: map()
  def read_memory([inst_id, offset, length])
      when is_integer(inst_id) and is_integer(offset) and is_integer(length) and offset >= 0 and
             length >= 0 do
    ensure_started()
    GenServer.call(__MODULE__, {:read_memory, inst_id, offset, length}, :infinity)
  end

  @spec write_memory(list()) :: map()
  def write_memory([inst_id, offset, data])
      when is_integer(inst_id) and is_integer(offset) and offset >= 0 and is_binary(data) do
    ensure_started()
    GenServer.call(__MODULE__, {:write_memory, inst_id, offset, data}, :infinity)
  end

  @spec read_global(list()) :: map()
  def read_global([inst_id, name]) when is_integer(inst_id) and is_binary(name) do
    ensure_started()
    GenServer.call(__MODULE__, {:read_global, inst_id, name}, :infinity)
  end

  @spec write_global(list()) :: map()
  def write_global([inst_id, name, value]) when is_integer(inst_id) and is_binary(name) do
    ensure_started()
    GenServer.call(__MODULE__, {:write_global, inst_id, name, value}, :infinity)
  end

  @spec module_custom_sections(list()) :: [{:bytes, binary()}]
  def module_custom_sections([mod_id, section_name])
      when is_integer(mod_id) and is_binary(section_name) do
    ensure_started()
    GenServer.call(__MODULE__, {:module_custom_sections, mod_id, section_name}, :infinity)
  end

  @impl true
  def handle_call({:compile, bytes}, _from, state) do
    case QuickBEAM.Native.wasm_compile(bytes) do
      {:ok, mod_ref} ->
        {exports, imports, custom_sections} = module_metadata(bytes)
        {id, next_state} = put_module(state, {mod_ref, bytes, exports, imports, custom_sections})
        {:reply, %{"ok" => id}, next_state}

      {:error, msg} ->
        {:reply, %{"error" => msg}, state}
    end
  end

  def handle_call({:start, mod_id, import_payload, runtime_resource}, _from, state) do
    case Map.fetch(state.modules, mod_id) do
      {:ok, {mod_ref, bytes, exports, imports, custom_sections}} ->
        with {:ok, compiled_mod_ref, memory_initializers, function_imports} <-
               prepare_module(mod_ref, bytes, imports, import_payload),
             {:ok, inst_ref} <-
               start_instance(compiled_mod_ref, runtime_resource, function_imports),
             :ok <- initialize_imported_memories(inst_ref, memory_initializers) do
          instance = {inst_ref, compiled_mod_ref, exports, imports, custom_sections}
          {id, next_state} = put_instance(state, instance)
          {:reply, %{"ok" => id}, next_state}
        else
          {:error, msg} -> {:reply, %{"error" => msg}, state}
        end

      :error ->
        {:reply, %{"error" => "module not found"}, state}
    end
  end

  def handle_call({:call, inst_id, func_name, params}, _from, state) do
    case fetch_instance(state, inst_id) do
      {:ok, inst_ref, exports} ->
        export = find_export(exports, func_name)

        reply =
          case QuickBEAM.Native.wasm_call(inst_ref, func_name, params) do
            {:ok, result} -> %{"ok" => encode_result(result, Map.get(export || %{}, "results", []))}
            {:error, msg} -> %{"error" => msg}
          end

        {:reply, reply, state}

      {:error, msg} ->
        {:reply, %{"error" => msg}, state}
    end
  end

  def handle_call({:module_exports, mod_id}, _from, state) do
    exports =
      case Map.fetch(state.modules, mod_id) do
        {:ok, {_mod_ref, _bytes, exports, _imports, _custom_sections}} -> exports
        :error -> []
      end

    {:reply, exports, state}
  end

  def handle_call({:module_imports, mod_id}, _from, state) do
    imports =
      case Map.fetch(state.modules, mod_id) do
        {:ok, {_mod_ref, _bytes, _exports, imports, _custom_sections}} -> imports
        :error -> []
      end

    {:reply, imports, state}
  end

  def handle_call({:memory_size, inst_id}, _from, state) do
    reply =
      with {:ok, inst_ref, _exports} <- fetch_instance(state, inst_id),
           {:ok, size} <- QuickBEAM.Native.wasm_memory_size(inst_ref) do
        %{"ok" => size}
      else
        {:error, msg} -> %{"error" => msg}
      end

    {:reply, reply, state}
  end

  def handle_call({:memory_grow, inst_id, delta}, _from, state) do
    reply =
      with {:ok, inst_ref, _exports} <- fetch_instance(state, inst_id),
           {:ok, pages} <- QuickBEAM.Native.wasm_memory_grow(inst_ref, delta) do
        %{"ok" => pages}
      else
        {:error, msg} -> %{"error" => msg}
      end

    {:reply, reply, state}
  end

  def handle_call({:read_memory, inst_id, offset, length}, _from, state) do
    reply =
      with {:ok, inst_ref, _exports} <- fetch_instance(state, inst_id),
           {:ok, bytes} <- QuickBEAM.Native.wasm_read_memory(inst_ref, offset, length) do
        %{"ok" => {:bytes, bytes}}
      else
        {:error, msg} -> %{"error" => msg}
      end

    {:reply, reply, state}
  end

  def handle_call({:write_memory, inst_id, offset, data}, _from, state) do
    reply =
      with {:ok, inst_ref, _exports} <- fetch_instance(state, inst_id),
           :ok <- QuickBEAM.Native.wasm_write_memory(inst_ref, offset, data) do
        %{"ok" => true}
      else
        {:error, msg} -> %{"error" => msg}
      end

    {:reply, reply, state}
  end

  def handle_call({:read_global, inst_id, name}, _from, state) do
    reply =
      with {:ok, inst_ref, exports} <- fetch_instance(state, inst_id),
           export when not is_nil(export) <- find_global_export(exports, name),
           {:ok, value} <- QuickBEAM.Native.wasm_read_global(inst_ref, name) do
        %{"ok" => encode_scalar(value, export["type"])}
      else
        nil -> %{"error" => "global not found"}
        {:error, msg} -> %{"error" => msg}
      end

    {:reply, reply, state}
  end

  def handle_call({:write_global, inst_id, name, value}, _from, state) do
    reply =
      with {:ok, inst_ref, exports} <- fetch_instance(state, inst_id),
           export when not is_nil(export) <- find_global_export(exports, name),
           :ok <- QuickBEAM.Native.wasm_write_global(inst_ref, name, value) do
        %{"ok" => encode_scalar(value, export["type"])}
      else
        nil -> %{"error" => "global not found"}
        {:error, msg} -> %{"error" => msg}
      end

    {:reply, reply, state}
  end

  def handle_call({:module_custom_sections, mod_id, section_name}, _from, state) do
    sections =
      case Map.fetch(state.modules, mod_id) do
        {:ok, {_mod_ref, _bytes, _exports, _imports, custom_sections}} ->
          custom_sections
          |> Enum.filter(&(&1.name == section_name))
          |> Enum.map(&{:bytes, &1.data})

        :error ->
          []
      end

    {:reply, sections, state}
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.instances, fn {_id, {inst_ref, _mod_ref, _exports, _imports, _custom_sections}} ->
      QuickBEAM.Native.wasm_stop(inst_ref)
    end)

    :ok
  end

  defp put_module(state, module_handle) do
    id = state.next_id
    next_state = %{state | next_id: id + 1, modules: Map.put(state.modules, id, module_handle)}
    {id, next_state}
  end

  defp put_instance(state, instance_handle) do
    id = state.next_id
    next_state = %{state | next_id: id + 1, instances: Map.put(state.instances, id, instance_handle)}
    {id, next_state}
  end

  defp prepare_bytes(bytes, import_payload) do
    {_exports, imports, _custom_sections} = module_metadata(bytes)

    case ImportRewriter.rewrite(bytes, imports, import_payload) do
      {:ok, rewritten_bytes, memory_initializers, function_imports} ->
        {:ok, rewritten_bytes, memory_initializers, function_imports}

      {:error, msg} ->
        {:error, msg}
    end
  end

  defp prepare_module(mod_ref, _bytes, [], []), do: {:ok, mod_ref, [], []}

  defp prepare_module(_mod_ref, bytes, imports, import_payload) do
    case ImportRewriter.rewrite(bytes, imports, import_payload) do
      {:ok, rewritten_bytes, memory_initializers, function_imports} ->
        case QuickBEAM.Native.wasm_compile(rewritten_bytes) do
          {:ok, rewritten_mod_ref} ->
            {:ok, rewritten_mod_ref, memory_initializers,
             atomize_function_imports(function_imports)}

          {:error, msg} ->
            {:error, msg}
        end

      {:error, msg} ->
        {:error, msg}
    end
  end

  defp initialize_imported_memories(_inst_ref, []), do: :ok

  defp initialize_imported_memories(inst_ref, [bytes]) do
    QuickBEAM.Native.wasm_write_memory(inst_ref, 0, bytes)
  end

  defp initialize_imported_memories(_inst_ref, _many),
    do: {:error, "multiple memory imports are not supported yet"}

  defp start_instance(mod_ref, nil, []), do: QuickBEAM.Native.wasm_start(mod_ref, 65_536, 65_536)

  defp start_instance(mod_ref, _runtime_resource, []),
    do: QuickBEAM.Native.wasm_start(mod_ref, 65_536, 65_536)

  defp start_instance(_mod_ref, nil, [_ | _]),
    do: {:error, "runtime resource not available for function imports"}

  defp start_instance(mod_ref, runtime_resource, function_imports) do
    QuickBEAM.Native.wasm_start_with_imports(
      mod_ref,
      runtime_resource,
      function_imports,
      65_536,
      65_536
    )
  end

  defp runtime_resource(nil), do: nil
  defp runtime_resource(caller) when is_pid(caller), do: QuickBEAM.Runtime.resource(caller)

  defp atomize_function_imports(function_imports) do
    Enum.map(function_imports, fn import ->
      %{
        module_name: import.module_name,
        symbol: import.symbol,
        signature: import.signature,
        callback_name: import.callback_name
      }
    end)
  end

  defp fetch_instance(state, inst_id) do
    case Map.fetch(state.instances, inst_id) do
      {:ok, {inst_ref, _mod_ref, exports, _imports, _custom_sections}} ->
        {:ok, inst_ref, exports}

      :error ->
        {:error, "instance not found"}
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
