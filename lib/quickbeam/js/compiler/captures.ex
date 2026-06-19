defmodule QuickBEAM.JS.Compiler.Captures do
  @moduledoc false

  alias QuickBEAM.JS.Compiler.{Scope, Slots}
  alias QuickBEAM.JS.Parser.AST

  def captured_names(
        %{body: %AST.BlockStatement{body: body}, params: params} = function,
        %Scope{} = scope
      ) do
    declared =
      params
      |> Enum.flat_map(&pattern_names/1)
      |> Kernel.++(self_name(function))
      |> Kernel.++(function_arguments_name(function))
      |> Kernel.++(function_local_names(body))
      |> MapSet.new()

    available = Scope.names(scope)

    [body | params]
    |> collect_identifiers([])
    |> Enum.reject(&MapSet.member?(declared, &1))
    |> Enum.filter(&(&1 in available))
    |> Enum.uniq()
  end

  def captured_names(_function, _scope), do: []

  def has_mutable_captures?(function, captured_names) do
    assigned = collect_assigned_identifiers(function.body, MapSet.new())
    Enum.any?(captured_names, &MapSet.member?(assigned, &1))
  end

  defp collect_assigned_identifiers(
         %AST.AssignmentExpression{left: %AST.Identifier{name: n}},
         acc
       ),
       do: MapSet.put(acc, n)

  defp collect_assigned_identifiers(
         %AST.UpdateExpression{argument: %AST.Identifier{name: n}},
         acc
       ),
       do: MapSet.put(acc, n)

  defp collect_assigned_identifiers(%{__struct__: _} = node, acc) do
    node |> Map.from_struct() |> Map.values() |> Enum.reduce(acc, &collect_assigned_identifiers/2)
  end

  defp collect_assigned_identifiers(list, acc) when is_list(list),
    do: Enum.reduce(list, acc, &collect_assigned_identifiers/2)

  defp collect_assigned_identifiers(_value, acc), do: acc

  def prepend_params(function, []), do: function

  def prepend_params(%{params: params} = function, captures) do
    capture_params = Enum.map(captures, &%AST.Identifier{type: :identifier, name: &1})
    %{function | params: capture_params ++ params}
  end

  def bind([], _scope, instructions, constants), do: {:ok, instructions, constants}

  def bind(captures, scope, instructions, constants) do
    captures
    |> Enum.reduce_while(
      {:ok, instructions ++ [{:get_field2, "bind"}, :undefined], constants},
      &bind_capture(&1, &2, scope)
    )
    |> case do
      {:ok, instructions, constants} ->
        {:ok, instructions ++ [{:call_method, length(captures) + 1}], constants}

      {:error, _} = error ->
        error
    end
  end

  defp bind_capture(name, {:ok, instructions, constants}, scope) do
    case Scope.resolve(scope, name) do
      :error -> {:halt, {:error, {:unsupported, {:unresolved_identifier, name}}}}
      slot -> {:cont, {:ok, instructions ++ [Slots.read(slot)], constants}}
    end
  end

  defp self_name(%AST.FunctionDeclaration{id: id}), do: [identifier_name(id)]
  defp self_name(%AST.FunctionExpression{id: %AST.Identifier{} = id}), do: [identifier_name(id)]
  defp self_name(_function), do: []

  defp function_arguments_name(%AST.ArrowFunctionExpression{}), do: []
  defp function_arguments_name(%{type: :arrow_function_expression}), do: []
  defp function_arguments_name(_function), do: ["arguments"]

  defp function_local_names(statements), do: collect_declaration_names(statements, [])

  defp collect_declaration_names([], acc), do: acc

  defp collect_declaration_names(
         [%AST.VariableDeclaration{declarations: declarations} | rest],
         acc
       ) do
    names = Enum.flat_map(declarations, &pattern_names(&1.id))
    collect_declaration_names(rest, names ++ acc)
  end

  defp collect_declaration_names([%AST.FunctionDeclaration{id: id} | rest], acc),
    do: collect_declaration_names(rest, [identifier_name(id) | acc])

  defp collect_declaration_names([_statement | rest], acc),
    do: collect_declaration_names(rest, acc)

  defp pattern_names(%AST.Identifier{} = identifier), do: [identifier_name(identifier)]
  defp pattern_names(%AST.AssignmentPattern{left: left}), do: pattern_names(left)
  defp pattern_names(%AST.RestElement{argument: argument}), do: pattern_names(argument)

  defp pattern_names(%AST.ObjectPattern{properties: properties}) do
    Enum.flat_map(properties, fn
      %AST.Property{value: value} -> pattern_names(value)
      _property -> []
    end)
  end

  defp pattern_names(%AST.ArrayPattern{elements: elements}) do
    elements
    |> Enum.reject(&is_nil/1)
    |> Enum.flat_map(&pattern_names/1)
  end

  defp pattern_names(_pattern), do: []

  defp collect_identifiers(list, acc) when is_list(list),
    do: Enum.reduce(list, acc, &collect_identifiers/2)

  defp collect_identifiers(%AST.FunctionExpression{}, acc), do: acc
  defp collect_identifiers(%AST.FunctionDeclaration{}, acc), do: acc
  defp collect_identifiers(%AST.ArrowFunctionExpression{}, acc), do: acc
  defp collect_identifiers(%AST.ClassExpression{}, acc), do: acc
  defp collect_identifiers(%AST.ClassDeclaration{}, acc), do: acc

  defp collect_identifiers(%AST.VariableDeclaration{declarations: declarations}, acc),
    do: collect_identifiers(declarations, acc)

  defp collect_identifiers(%AST.VariableDeclarator{init: init}, acc),
    do: collect_identifiers(init, acc)

  defp collect_identifiers(%AST.MemberExpression{computed: false, object: object}, acc),
    do: collect_identifiers(object, acc)

  defp collect_identifiers(
         %AST.CallExpression{
           callee: %AST.Identifier{name: "eval"},
           arguments: [%AST.Literal{value: code} | _]
         },
         acc
       )
       when is_binary(code) do
    case QuickBEAM.JS.Parser.parse(code) do
      {:ok, program} -> collect_identifiers(program, acc)
      _ -> acc
    end
  end

  defp collect_identifiers(%AST.Identifier{name: name}, acc), do: [name | acc]

  defp collect_identifiers(%_{} = node, acc) do
    node
    |> Map.from_struct()
    |> Map.values()
    |> collect_identifiers(acc)
  end

  defp collect_identifiers(_value, acc), do: acc

  defp identifier_name(%AST.Identifier{name: name}), do: name
  defp identifier_name(%AST.AssignmentPattern{left: left}), do: identifier_name(left)
  defp identifier_name(%AST.RestElement{argument: argument}), do: identifier_name(argument)
end
