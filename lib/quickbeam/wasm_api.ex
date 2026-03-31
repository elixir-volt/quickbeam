defmodule QuickBEAM.WasmAPI do
  @moduledoc false

  @table :quickbeam_wasm_handles

  def init do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set])
    end

    :ok
  end

  def compile([bytes]) when is_binary(bytes) do
    init()

    case QuickBEAM.WASM.compile(bytes) do
      {:ok, mod_ref} ->
        id = System.unique_integer([:positive])
        exports = case QuickBEAM.WASM.disasm(bytes) do
          {:ok, mod} -> Enum.map(mod.exports, fn exp ->
            kind = case exp.kind do
              :func -> "function"
              :memory -> "memory"
              :table -> "table"
              :global -> "global"
              other -> to_string(other)
            end
            %{"name" => exp.name, "kind" => kind}
          end)
          _ -> []
        end
        :ets.insert(@table, {id, :module, mod_ref, exports})
        %{"ok" => id}

      {:error, msg} ->
        %{"error" => msg}
    end
  end

  def validate([bytes]) when is_binary(bytes) do
    init()

    case QuickBEAM.WASM.compile(bytes) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  def start([mod_id]) when is_integer(mod_id) do
    case :ets.lookup(@table, mod_id) do
      [{^mod_id, :module, mod_ref, _exports}] ->
        case QuickBEAM.WASM.start(mod_ref) do
          {:ok, inst_ref} ->
            id = System.unique_integer([:positive])
            :ets.insert(@table, {id, :instance, inst_ref})
            %{"ok" => id}

          {:error, msg} ->
            %{"error" => msg}
        end

      _ ->
        %{"error" => "module not found"}
    end
  end

  def call([inst_id, func_name, params])
      when is_integer(inst_id) and is_binary(func_name) and is_list(params) do
    case :ets.lookup(@table, inst_id) do
      [{^inst_id, :instance, inst_ref}] ->
        case QuickBEAM.WASM.call(inst_ref, func_name, Enum.map(params, &trunc/1)) do
          {:ok, result} -> %{"ok" => result}
          {:error, msg} -> %{"error" => msg}
        end

      _ ->
        %{"error" => "instance not found"}
    end
  end

  def module_exports([mod_id]) when is_integer(mod_id) do
    case :ets.lookup(@table, mod_id) do
      [{^mod_id, :module, _mod_ref, exports}] -> exports
      _ -> []
    end
  end

  def module_imports([mod_id]) when is_integer(mod_id) do
    case :ets.lookup(@table, mod_id) do
      [{^mod_id, :module, _mod_ref, _exports}] -> []
      _ -> []
    end
  end
end
