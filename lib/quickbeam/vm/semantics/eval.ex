defmodule QuickBEAM.VM.Semantics.Eval do
  @moduledoc "Shared helpers for direct-eval semantics across interpreter and compiler paths."

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST
  alias QuickBEAM.VM.{EvalLexical, Heap, Names}
  alias QuickBEAM.VM.Interpreter.Context
  alias QuickBEAM.VM.JSThrow
  alias QuickBEAM.VM.ObjectModel.InternalMethods

  def simple_delete_identifier(code, globals) when is_map(globals) do
    case Parser.parse(code) do
      {:ok,
       %AST.Program{
         body: [
           %AST.ExpressionStatement{
             expression: %AST.UnaryExpression{
               operator: "delete",
               argument: %AST.Identifier{name: name}
             }
           }
         ]
       }} ->
        {:ok, not Map.has_key?(globals, name)}

      _ ->
        :error
    end
  end

  def simple_assigned_names(code) do
    case Parser.parse(code) do
      {:ok, %AST.Program{} = program} ->
        program
        |> assigned_names_from_node([])
        |> MapSet.new()

      _ ->
        MapSet.new()
    end
  end

  def declared_local_names(%QuickBEAM.VM.Function{locals: locals}) do
    locals
    |> Enum.map(&Names.resolve_display_name(&1.name))
    |> Enum.filter(&is_binary/1)
    |> MapSet.new()
  end

  def declared_local_names(_), do: MapSet.new()

  def lexical_conflict?(%Context{} = ctx, declared_names) do
    ctx
    |> EvalLexical.current_lexical_names()
    |> MapSet.disjoint?(declared_names)
    |> Kernel.not()
  end

  def lexical_conflict?(_ctx, _declared_names), do: false

  def reject_lexical_conflicts!(ctx, declared_names, strict?) do
    if not strict? and lexical_conflict?(ctx, declared_names) do
      JSThrow.syntax_error!("Identifier has already been declared")
    end
  end

  def reject_class_field_initializer_eval!(ctx, code) when is_binary(code) do
    if class_field_initializer_context?(ctx) and initializer_eval_forbidden_syntax?(code) do
      JSThrow.syntax_error!("Invalid direct eval in class field initializer")
    end
  end

  def reject_class_field_initializer_eval!(_ctx, _code), do: :ok

  def normalize_class_field_initializer_eval_code(_ctx, code) when is_binary(code), do: code

  def normalize_class_field_initializer_eval_code(_ctx, code), do: code

  def class_field_initializer_context?(%{current_func: current_func}) do
    case current_func do
      {:closure, captured, %QuickBEAM.VM.Function{} = fun} ->
        Map.get(captured, :__class_field_initializer__, false) or
          synthetic_field_initializer?(fun)

      %QuickBEAM.VM.Function{} = fun ->
        synthetic_field_initializer?(fun)

      _ ->
        false
    end
  end

  def class_field_initializer_context?(_), do: false

  def class_field_initializer_eval_ast(ctx, code) when is_binary(code) do
    if class_field_initializer_context?(ctx) do
      case Parser.parse(code) do
        {:error, %AST.Program{} = program, errors} ->
          if class_initializer_recoverable_errors?(errors) do
            {:ok, eval_initializer_program(program)}
          else
            :continue
          end

        _ ->
          :continue
      end
    else
      :continue
    end
  end

  def class_field_initializer_eval_ast(_ctx, _code), do: :continue

  def intrinsic_eval?({:builtin, "eval", _}), do: true
  def intrinsic_eval?(_), do: false

  def commit_class_field_initializer_eval_globals(ctx_globals, globals) when is_map(globals) do
    merged = Map.merge(Heap.get_persistent_globals() || %{}, globals)
    Heap.put_persistent_globals(merged)
    Heap.put_base_globals(merged)

    case Map.get(ctx_globals || %{}, "globalThis") || Map.get(merged, "globalThis") do
      {:obj, _} = global_this ->
        Enum.each(globals, fn {name, value} -> InternalMethods.set(global_this, name, value) end)

      _ ->
        :ok
    end
  end

  defp class_initializer_recoverable_errors?(errors) do
    Enum.all?(errors, fn %{message: message} ->
      message in [
        "new.target not allowed outside function",
        "super not allowed outside class method"
      ]
    end)
  end

  defp eval_initializer_program(%AST.Program{body: body}) do
    Enum.reduce(body, {:undefined, %{}}, &eval_initializer_statement/2)
  catch
    :unsupported_initializer_eval -> :unsupported
  end

  defp eval_initializer_statement(
         %AST.ExpressionStatement{expression: expression},
         {_value, globals}
       ) do
    eval_initializer_expression(expression, globals)
  end

  defp eval_initializer_statement(_statement, _acc), do: throw(:unsupported_initializer_eval)

  defp eval_initializer_expression(
         %AST.AssignmentExpression{
           operator: "=",
           left: %AST.Identifier{name: name},
           right: right
         },
         globals
       ) do
    {value, globals} = eval_initializer_expression(right, globals)
    {value, Map.put(globals, name, value)}
  end

  defp eval_initializer_expression(%AST.Literal{value: value}, globals), do: {value, globals}

  defp eval_initializer_expression(%AST.Identifier{name: name}, globals),
    do: {Map.get(globals, name, :undefined), globals}

  defp eval_initializer_expression(
         %AST.MetaProperty{
           meta: %AST.Identifier{name: "new"},
           property: %AST.Identifier{name: "target"}
         },
         globals
       ),
       do: {:undefined, globals}

  defp eval_initializer_expression(
         %AST.MemberExpression{object: %AST.Identifier{name: "super"}},
         globals
       ),
       do: {:undefined, globals}

  defp eval_initializer_expression(%AST.ArrowFunctionExpression{body: body}, globals) do
    fun =
      {:builtin, "", fn _args, _this -> elem(eval_initializer_expression(body, globals), 0) end}

    {fun, globals}
  end

  defp eval_initializer_expression(_expression, _globals),
    do: throw(:unsupported_initializer_eval)

  defp synthetic_field_initializer?(%QuickBEAM.VM.Function{source: "", locals: locals}) do
    local_names = MapSet.new(Enum.map(locals, &Names.resolve_display_name(&1.name)))
    MapSet.subset?(MapSet.new(["this", "<home_object>"]), local_names)
  end

  defp synthetic_field_initializer?(_), do: false

  defp initializer_eval_forbidden_syntax?(code) do
    case Parser.parse(code) do
      {:ok, program} -> forbidden_initializer_node?(program)
      {:error, program, _errors} -> forbidden_initializer_node?(program)
      _ -> false
    end
  end

  defp forbidden_initializer_node?(%AST.Identifier{name: "arguments"}), do: true

  defp forbidden_initializer_node?(%AST.CallExpression{callee: %AST.Identifier{name: "super"}}),
    do: true

  defp forbidden_initializer_node?(%_{} = node) do
    node
    |> Map.from_struct()
    |> Map.values()
    |> Enum.any?(&forbidden_initializer_node?/1)
  end

  defp forbidden_initializer_node?(list) when is_list(list),
    do: Enum.any?(list, &forbidden_initializer_node?/1)

  defp forbidden_initializer_node?(_), do: false

  defp assigned_names_from_node(
         %AST.AssignmentExpression{left: %AST.Identifier{name: name}} = node,
         acc
       ) do
    node
    |> Map.from_struct()
    |> Map.delete(:left)
    |> assigned_names_from_map([name | acc])
  end

  defp assigned_names_from_node(%_{} = node, acc),
    do: node |> Map.from_struct() |> assigned_names_from_map(acc)

  defp assigned_names_from_node(list, acc) when is_list(list),
    do: Enum.reduce(list, acc, &assigned_names_from_node/2)

  defp assigned_names_from_node(_, acc), do: acc

  defp assigned_names_from_map(map, acc),
    do: map |> Map.values() |> Enum.reduce(acc, &assigned_names_from_node/2)
end
