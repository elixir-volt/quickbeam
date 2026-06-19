defmodule QuickBEAM.VM.Heap.ProcessKeys do
  @moduledoc """
  Registry for process-dictionary keys used by the BEAM VM heap.

  QuickBEAM's BEAM VM stores runtime state in the owning BEAM process. The
  process dictionary is intentionally treated as a private heap backend: callers
  outside `QuickBEAM.VM.Heap`, `QuickBEAM.VM.Execution`, and runtime modules that
  model host APIs should not read or write these keys directly.

  ## Lifecycle groups

    * object storage: positive integer object references and reference-backed
      iterator/runtime state.
    * execution context: `:qb_ctx`, `:qb_fast_ctx`, atoms, globals, runtime mode,
      and persistent global write-back state.
    * shape/cache state: shape tables, wrap caches, compiled functions, function
      atom/capture metadata, prototype caches, and builtin-name caches.
    * object metadata: property descriptors, array named properties, constructor
      statics, prototype links, extensibility/frozen markers, and closure cells.
    * async/runtime queues: microtasks, promise waiters, timers, modules, symbols,
      trace frames, setter/constructor state, and Test262 realm state.

  `QuickBEAM.VM.Heap.reset/0` removes all keys owned by these groups while leaving
  Elixir module atoms and unrelated process dictionary entries alone.
  """

  @qb_prefix "qb_"

  @doc "Returns true when a process dictionary key is owned by QuickBEAM heap/runtime state."
  def owned?(id) when is_integer(id) and id > 0, do: true
  def owned?(ref) when is_reference(ref), do: false

  def owned?(key) when is_atom(key) do
    name = Atom.to_string(key)

    not String.starts_with?(name, "Elixir.QuickBEAM.VM.") and
      String.starts_with?(name, @qb_prefix)
  end

  def owned?(key) when is_tuple(key) and tuple_size(key) > 0 do
    case elem(key, 0) do
      atom when is_atom(atom) -> String.starts_with?(Atom.to_string(atom), @qb_prefix)
      _ -> false
    end
  end

  def owned?(_key), do: false

  @doc "Returns true when a process dictionary entry is owned by QuickBEAM heap/runtime state."
  def owned_entry?(key, _value) when is_integer(key) and key > 0, do: true
  def owned_entry?(key, _value) when is_reference(key), do: false
  def owned_entry?(key, _value), do: owned?(key)
end
