defmodule QuickBEAM.VM.Interpreter.ClosureBuilder do
  @moduledoc "Closure construction: captures parent locals and var-refs into a `{:closure, captured, fun}` tuple."

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.Interpreter.Context

  @doc "Builds the runtime value represented by this module."
  def build(%QuickBEAM.VM.Function{} = fun, locals, vrefs, l2v, %Context{} = ctx) do
    parent_arg_count = current_function_arg_count(ctx)

    captured =
      for cv <- fun.closure_vars, into: %{} do
        {capture_key(cv), capture_var(cv, locals, vrefs, l2v, parent_arg_count, ctx)}
      end
      |> maybe_mark_class_field_initializer(ctx)

    {:closure, captured, fun}
  end

  def build(other, _locals, _vrefs, _l2v, _ctx), do: other

  @doc "Helper for closure construction: captures parent locals and var-refs into a `{:closure, captured, fun}` tuple."
  def inherit_parent_vrefs({:closure, captured, %QuickBEAM.VM.Function{} = fun}, parent_vrefs)
      when is_tuple(parent_vrefs) do
    extra =
      if tuple_size(parent_vrefs) == 0 do
        %{}
      else
        for i <- 0..(tuple_size(parent_vrefs) - 1),
            not Map.has_key?(captured, capture_key(2, i)),
            into: %{} do
          {capture_key(2, i), elem(parent_vrefs, i)}
        end
      end

    {:closure, Map.merge(extra, captured), fun}
  end

  def inherit_parent_vrefs(closure, _parent_vrefs), do: closure

  @doc "Helper for closure construction: captures parent locals and var-refs into a `{:closure, captured, fun}` tuple."
  def ctor_var_refs(%QuickBEAM.VM.Function{} = fun, captured \\ %{}) do
    cell_ref = make_ref()
    Heap.put_cell(cell_ref, :__tdz__)

    case fun.closure_vars do
      [] ->
        [{:cell, cell_ref}]

      closure_vars ->
        Enum.map(closure_vars, &Map.get(captured, capture_key(&1), {:cell, cell_ref}))
    end
  end

  @doc "Helper for closure construction: captures parent locals and var-refs into a `{:closure, captured, fun}` tuple."
  def capture_key(%{closure_type: type, var_idx: idx}), do: capture_key(type, idx)
  def capture_key(type, idx), do: {type, idx}

  defp capture_var(%{closure_type: 2, var_idx: idx}, _locals, vrefs, _l2v, _arg_count, _ctx)
       when idx < tuple_size(vrefs) do
    case elem(vrefs, idx) do
      {:cell, _} = existing ->
        existing

      val ->
        ref = make_ref()
        Heap.put_cell(ref, val)
        {:cell, ref}
    end
  end

  defp capture_var(%{closure_type: 0, var_idx: idx} = cv, locals, vrefs, l2v, arg_count, ctx) do
    capture_local_var(idx + arg_count, locals, vrefs, l2v, cv, ctx)
  end

  defp capture_var(%{var_idx: idx} = cv, locals, vrefs, l2v, _arg_count, ctx) do
    capture_local_var(idx, locals, vrefs, l2v, cv, ctx)
  end

  defp capture_local_var(idx, locals, vrefs, l2v, cv, ctx) do
    case Map.get(l2v, idx) do
      nil ->
        val = captured_local_value(idx, locals, cv, ctx)
        ref = make_ref()
        Heap.put_cell(ref, val)
        {:cell, ref}

      vref_idx ->
        case elem(vrefs, vref_idx) do
          {:cell, _} = existing ->
            existing

          _ ->
            val = elem(locals, idx)
            ref = make_ref()
            Heap.put_cell(ref, val)
            {:cell, ref}
        end
    end
  end

  defp captured_local_value(idx, locals, cv, %Context{this: {:uninitialized, _}}) do
    if QuickBEAM.VM.Names.resolve_display_name(cv.name) == "this" do
      :__tdz__
    else
      local_value(idx, locals)
    end
  end

  defp captured_local_value(idx, locals, _cv, _ctx), do: local_value(idx, locals)

  defp local_value(idx, locals),
    do: if(idx < tuple_size(locals), do: elem(locals, idx), else: :undefined)

  defp maybe_mark_class_field_initializer(captured, %Context{current_func: current_func}) do
    if class_field_initializer_context?(current_func) do
      Map.put(captured, :__class_field_initializer__, true)
    else
      captured
    end
  end

  defp maybe_mark_class_field_initializer(captured, _ctx), do: captured

  defp class_field_initializer_context?({:closure, captured, %QuickBEAM.VM.Function{} = fun}),
    do:
      Map.get(captured, :__class_field_initializer__, false) or synthetic_field_initializer?(fun)

  defp class_field_initializer_context?(%QuickBEAM.VM.Function{} = fun),
    do: synthetic_field_initializer?(fun)

  defp class_field_initializer_context?(_), do: false

  defp synthetic_field_initializer?(%QuickBEAM.VM.Function{source: "", locals: locals}) do
    names = MapSet.new(Enum.map(locals, &QuickBEAM.VM.Names.resolve_display_name(&1.name)))
    MapSet.subset?(MapSet.new(["this", "<home_object>"]), names)
  end

  defp synthetic_field_initializer?(_), do: false

  defp current_function_arg_count(%Context{
         current_func: {:closure, _, %QuickBEAM.VM.Function{arg_count: n}}
       }),
       do: n

  defp current_function_arg_count(%Context{current_func: %QuickBEAM.VM.Function{arg_count: n}}),
    do: n

  defp current_function_arg_count(%Context{arg_buf: arg_buf}), do: tuple_size(arg_buf)
end
