defmodule QuickBEAM.BeamVM.Heap do
  @moduledoc """
  Mutable heap storage for JS runtime values.

  Wraps process dictionary access for JS objects, closure cells,
  class metadata, and variable bindings. Centralizes all heap
  mutations so callers don't access the process dictionary directly.

  ## Storage keys
    - `{:qb_obj, ref}` — JS object/array properties
    - `{:qb_cell, ref}` — closure variable cells
    - `{:qb_class_proto, hash}` — class prototype objects
    - `{:qb_parent_ctor, hash}` — parent constructor references
    - `{:qb_var, name}` — global variable bindings
  """

  # ── Objects ──

  def get_obj(ref), do: Process.get({:qb_obj, ref})
  def get_obj(ref, default), do: Process.get({:qb_obj, ref}, default)
  def put_obj(ref, val), do: Process.put({:qb_obj, ref}, val)

  def update_obj(ref, default, fun) do
    Process.put({:qb_obj, ref}, fun.(Process.get({:qb_obj, ref}, default)))
  end

  # ── Closure cells ──

  def get_cell(ref), do: Process.get({:qb_cell, ref}, :undefined)
  def put_cell(ref, val), do: Process.put({:qb_cell, ref}, val)

  # ── Class metadata ──

  def get_class_proto(ctor), do: Process.get({:qb_class_proto, :erlang.phash2(ctor)})
  def put_class_proto(ctor, proto), do: Process.put({:qb_class_proto, :erlang.phash2(ctor)}, proto)

  def get_parent_ctor(ctor), do: Process.get({:qb_parent_ctor, :erlang.phash2(ctor)})
  def put_parent_ctor(ctor, parent), do: Process.put({:qb_parent_ctor, :erlang.phash2(ctor)}, parent)

  # ── Variable bindings ──

  def get_var(name), do: Process.get({:qb_var, name})
  def put_var(name, val), do: Process.put({:qb_var, name}, val)
  def delete_var(name), do: Process.delete({:qb_var, name})
end
