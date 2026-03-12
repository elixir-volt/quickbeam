defmodule Zig.Parser do
  require Pegasus
  import NimbleParsec

  defstruct [:doc_comment, code: [], dependencies: [], comments: []]

  @external_resource "lib/grammar/grammar.y"

  alias Zig.Parser.Asm
  alias Zig.Parser.AssignExpr
  alias Zig.Parser.Block
  alias Zig.Parser.Collected
  alias Zig.Parser.ComptimeDecl
  alias Zig.Parser.ContainerDecl
  alias Zig.Parser.ContainerDeclaration
  alias Zig.Parser.Decl
  alias Zig.Parser.ErrorUnionExpr
  alias Zig.Parser.Expr
  alias Zig.Parser.For
  alias Zig.Parser.GlobalVarDecl
  alias Zig.Parser.InitList
  alias Zig.Parser.Test
  alias Zig.Parser.Function
  alias Zig.Parser.ParamDecl
  alias Zig.Parser.ParseError
  alias Zig.Parser.PrimaryExpr
  alias Zig.Parser.PrimaryTypeExpr
  alias Zig.Parser.Statement
  alias Zig.Parser.TypeExpr
  alias Zig.Parser.VarDeclProto
  alias Zig.Parser.VarDeclExprStatement
  alias Zig.Parser.While

  @keywords ~w[addrspace align allowzero and anyframe anytype asm break callconv catch comptime const continue defer else enum errdefer error export extern fn for if inline noalias nosuspend noinline opaque or orelse packed pub resume return linksection struct suspend switch test threadlocal try union unreachable var volatile while]a
  @keyword_mapping Enum.map(@keywords, &{:"KEYWORD_#{&1}", [token: &1]})

  @sub_operators %{
    AMPERSAND: :&,
    AMPERSANDEQUAL: :"&=",
    ASTERISK: :*,
    ASTERISK2: :**,
    ASTERISKEQUAL: :"*=",
    ASTERISKPERCENT: :"*%",
    ASTERISKPERCENTEQUAL: :"*%=",
    ASTERISKPIPE: :"*|",
    ASTERISKPIPEEQUAL: :"*|=",
    CARET: :^,
    CARETEQUAL: :"^=",
    DOT3: :...,
    DOTASTERISK: :".*",
    DOTQUESTIONMARK: :".?",
    EQUAL: :=,
    EQUALEQUAL: :==,
    EQUALRARROW: :"=>",
    EXCLAMATIONMARK: :!,
    EXCLAMATIONMARKEQUAL: :!=,
    LARROW: :<,
    LARROW2: :"<<",
    LARROW2EQUAL: :"<<=",
    LARROW2PIPE: :"<<|",
    LARROW2PIPEEQUAL: :"<<|=",
    LARROWEQUAL: :<=,
    MINUS: :-,
    MINUSEQUAL: :"-=",
    MINUSPERCENT: :"-%",
    MINUSPERCENTEQUAL: :"-%=",
    MINUSPIPE: :"-|",
    MINUSPIPEEQUAL: :"-|",
    PERCENT: :%,
    PERCENTEQUAL: :"%=",
    PIPE: :|,
    PIPE2: :||,
    PIPEEQUAL: :"|=",
    PLUS: :+,
    PLUS2: :++,
    PLUSEQUAL: :"+=",
    PLUSPERCENT: :"+%",
    PLUSPERCENTEQUAL: :"+%=",
    PLUSPIPE: :"+|",
    PLUSPIPEEQUAL: :"+|=",
    RARROW: :>,
    RARROW2: :">>",
    RARROW2EQUAL: :">>=",
    RARROWEQUAL: :>=,
    SLASH: :/,
    SLASHEQUAL: :"/=",
    TILDE: :"~"
  }

  @sub_operator_mapping Enum.map(@sub_operators, fn {name, op} ->
                          {name, [token: op, start_position: true]}
                        end)

  @operators ~w[COMMA DOT DOT2 COLON LBRACE LBRACKET LPAREN MINUSRARROW LETTERC QUESTIONMARK RBRACE RBRACKET RPAREN SEMICOLON]a
  @operator_mapping Enum.map(@operators, &{&1, [token: true]})

  @collecteds ~w[INTEGER FLOAT BUILTINIDENTIFIER line_string]a
  @collected_mapping Enum.map(
                       @collecteds,
                       &{&1, [collect: true, post_traverse: {Collected, :post_traverse, [&1]}]}
                     )

  @lists ~w[IdentifierList SwitchProngList AsmOutputList AsmInputList StringList ParamDeclList ExprList]a
  @lists_mapping Enum.map(@lists, &{&1, tag: true})

  @parser_options [
                    container_doc_comment: [
                      tag: :doc_comment,
                      post_traverse: :doc_comment
                    ],
                    char_escape: [
                      post_traverse: :char_escape,
                      tag: true
                    ],
                    doc_comment: [post_traverse: :doc_comment, tag: true],
                    line_comment: [post_traverse: :line_comment, tag: true, start_position: true],
                    line_string: [post_traverse: :process_line_string],
                    AssignExpr: [
                      tag: true,
                      post_traverse: {AssignExpr, :post_traverse, []}
                    ],
                    SingleAssignExpr: [
                      tag: :AssignExpr,
                      post_traverse: {AssignExpr, :post_traverse, []}
                    ],
                    TestDecl: [
                      tag: true,
                      start_position: true,
                      post_traverse: {Test, :post_traverse, []}
                    ],
                    Decl: [
                      tag: true,
                      post_traverse: {Decl, :post_traverse, []}
                    ],
                    ContainerDecl: [
                      start_position: true,
                      tag: true,
                      post_traverse: {ContainerDecl, :post_traverse, []}
                    ],
                    ContainerDeclaration: [
                      tag: true,
                      post_traverse: {ContainerDeclaration, :post_traverse, []}
                    ],
                    PrimaryExpr: [
                      start_position: true,
                      tag: true,
                      post_traverse: {PrimaryExpr, :post_traverse, []}
                    ],
                    skip: [ignore: true],
                    line_string: [tag: true],
                    IDENTIFIER: [post_traverse: :identifier],
                    STRINGLITERALSINGLE: [
                      tag: :string,
                      post_traverse: :literal_stringlike
                    ],
                    CHAR_LITERAL: [
                      tag: :char,
                      post_traverse: :literal_stringlike
                    ],
                    STRINGLITERAL: [
                      post_traverse: :string_literal
                    ],
                    ComptimeDecl: [
                      tag: true,
                      post_traverse: {ComptimeDecl, :post_traverse, []}
                    ],
                    TypeExpr: [
                      tag: true,
                      post_traverse: {TypeExpr, :post_traverse, []}
                    ],
                    Expr: [
                      tag: true,
                      post_traverse: {Expr, :post_traverse, []}
                    ],
                    ErrorUnionExpr: [
                      tag: true,
                      post_traverse: {ErrorUnionExpr, :post_traverse, []}
                    ],
                    InitList: [
                      tag: true,
                      post_traverse: {InitList, :post_traverse, []}
                    ],
                    ParamDecl: [tag: true, post_traverse: {ParamDecl, :post_traverse, []}],
                    VarDeclProto: [
                      start_position: true,
                      tag: true,
                      post_traverse: {VarDeclProto, :post_traverse, []}
                    ],
                    PrefixTypeOp: [tag: true],
                    PrimaryTypeExpr: [
                      tag: true,
                      post_traverse: {PrimaryTypeExpr, :post_traverse, []}
                    ],
                    SwitchItem: [tag: true],
                    AsmExpr: [
                      start_position: true,
                      tag: true,
                      post_traverse: {Asm, :post_traverse, []}
                    ],
                    BlockExpr: [
                      start_position: true,
                      tag: true,
                      post_traverse: {Block, :post_traverse, []}
                    ],
                    Block: [
                      start_position: true,
                      tag: true,
                      post_traverse: {Block, :post_traverse, []}
                    ],
                    FnProto: [
                      start_position: true,
                      tag: true,
                      post_traverse: {Function, :post_traverse, []}
                    ],
                    ForStatement: [tag: true, post_traverse: {For, :post_traverse, []}],
                    WhileStatement: [tag: true, post_traverse: {While, :post_traverse, []}],
                    Statement: [tag: true, post_traverse: {Statement, :post_traverse, []}],
                    GlobalVarDecl: [post_traverse: {GlobalVarDecl, :post_traverse, []}],
                    VarDeclExprStatement: [
                      post_traverse: {VarDeclExprStatement, :post_traverse, []}
                    ],
                    # keywords that add inline
                    LoopStatement: [tag: true, post_traverse: :add_inline],
                    # basic pseudofunction keywords
                    CallConv: [tag: true, post_traverse: :pseudofunction],
                    ByteAlign: [tag: true, post_traverse: :pseudofunction],
                    LinkSection: [tag: true, post_traverse: :pseudofunction],
                    AddrSpace: [tag: true, post_traverse: :pseudofunction],
                    # substituted functions:
                    mb_utf8_literal: [alias: :utf8],
                    # Top level
                    Root: [tag: true, post_traverse: :post_traverse]
                  ] ++
                    @keyword_mapping ++
                    @operator_mapping ++
                    @sub_operator_mapping ++
                    @collected_mapping ++
                    @lists_mapping

  Pegasus.parser_from_file(Path.join(__DIR__, "grammar/grammar.y"), @parser_options)

  zig_parser =
    empty()
    |> post_traverse(empty(), :init)
    |> parsec(:Root)

  defparsecp(:parser, zig_parser)

  defparsecp(:utf8, utf8_char(not: 0..127) |> map(:char_to_string))

  defp char_to_string(char) do
    char
    |> List.wrap()
    |> List.to_string()
  end

  def parse(string) do
    string
    |> String.replace("\r\n", "\n")
    |> parser
    |> case do
      {:ok, _, "", parser, _, _} ->
        %{
          parser
          | comments: Enum.reverse(parser.comments),
            dependencies: Enum.uniq(parser.dependencies)
        }

      {:error, message, remainder, context, line, column} ->
        raise ParseError,
          message: message,
          remainder: remainder,
          context: context,
          line: line,
          column: column
    end
  end

  # parser combinators

  defp init(code, args, context, _, _) do
    {code, args, struct(__MODULE__, context)}
  end

  defp doc_comment(rest, [{:doc_comment, args} | rest_args], context, _, _) do
    doc_comment =
      args
      |> Enum.reverse()
      |> Enum.reduce({[], true}, &multiline_filter/2)
      |> elem(0)
      |> List.to_string()

    {rest, [{:doc_comment, doc_comment} | rest_args], context}
  end

  defp line_comment(
         rest,
         [{:line_comment, [position, "//" | comment]} | rest_args],
         context,
         _,
         _
       ) do
    comment_data = {List.to_string(comment), position}
    {rest, rest_args, %{context | comments: [comment_data | context.comments]}}
  end

  defp line_comment(
         rest,
         [{:line_comment, [position, "////" | comment]} | rest_args],
         context,
         _,
         _
       ) do
    comment_data = {List.to_string([?/, ?/, comment]), position}
    {rest, rest_args, %{context | comments: [comment_data | context.comments]}}
  end

  defp char_escape(rest, [{:char_escape, [~S"\x" | number]} | rest_args], context, _, _) do
    {rest, [<<List.to_integer(number, 16)>> | rest_args], context}
  end

  defp char_escape(rest, [{:char_escape, [~S"\u{" | descriptor]} | rest_args], context, _, _) do
    unicode =
      descriptor
      # removes trailing "}"
      |> Enum.slice(0..-2//1)
      |> List.to_integer(16)
      |> List.wrap()
      |> List.to_string()

    {rest, [unicode | rest_args], context}
  end

  @escaped %{?t => "\t", ?r => "\r", ?n => "\n", ?' => "'", ?" => "\"", ?\\ => "\\"}
  @escaped_chars Map.keys(@escaped)

  defp char_escape(rest, [{:char_escape, ["\\", escaped]} | rest_args], context, _, _)
       when escaped in @escaped_chars do
    {rest, [Map.fetch!(@escaped, escaped) | rest_args], context}
  end

  defp char_escape(_, _, _, _, _), do: {:error, "escape not recognized"}

  defp literal_stringlike(rest, [{tag, literal} | rest_args], context, _, _) do
    content =
      literal
      |> Enum.slice(1..-2//1)
      |> IO.iodata_to_binary()

    {rest, [{tag, content} | rest_args], context}
  end

  def post_traverse("", [Root: [{:doc_comment, doc_comment} | code]], context, _, _) do
    {"", [], struct(context, code: code, doc_comment: doc_comment)}
  end

  def post_traverse("", [Root: code], context, _, _) do
    {"", [], struct(context, code: code)}
  end

  defp add_inline(rest, [{_tag, [:inline, payload]} | rest_args], context, _loc, _col) do
    {rest, [%{payload | inline: true} | rest_args], context}
  end

  defp add_inline(rest, [{_tag, [payload]} | rest_args], context, _loc, _col) do
    {rest, [payload | rest_args], context}
  end

  defp identifier(rest, [{:string, identifier}, "@" | rest_args], context, _loc, _col) do
    {rest, [{:builtin, String.to_atom(identifier)} | rest_args], context}
  end

  defp identifier(rest, charlist, context, _loc, _col) do
    identifier =
      charlist
      |> Enum.reverse()
      |> List.to_atom()

    {rest, [identifier], context}
  end

  defp string_literal(rest, args, context, _loc, _col) do
    arg =
      case args do
        [{:string, _} = string] -> string
        string_list -> {:string, Enum.join(string_list, "")}
      end

    {rest, [arg], context}
  end

  defp pseudofunction(
         rest,
         [{_tag, [name, :LPAREN, payload, :RPAREN]} | rest_args],
         context,
         _loc,
         _col
       ) do
    {rest, [{name, payload} | rest_args], context}
  end

  defp process_line_string(rest, args, context, _loc, _col) do
    new_args =
      args
      |> Enum.reduce({[], false}, &multiline_filter/2)
      |> elem(0)
      |> List.to_string()

    {rest, [new_args], context}
  end

  defp multiline_filter("\\\\", {so_far, true}), do: {so_far, false}
  defp multiline_filter("///", {so_far, true}), do: {so_far, false}
  defp multiline_filter("//!", {so_far, true}), do: {so_far, false}
  defp multiline_filter(?\n, {so_far, false}), do: {[?\n | so_far], true}
  defp multiline_filter(_any, {so_far, false}), do: {so_far, false}
  defp multiline_filter(any, {so_far, true}), do: {[any | so_far], true}

  @doc false
  def put_location(%_{} = struct, location) do
    Map.replace!(struct, :location, {location.line, location.column})
  end

  def _parse_args([], _), do: []
  def _parse_args([arg], so_far), do: Enum.reverse([arg | so_far])
  def _parse_args([arg, :COMMA | rest], so_far), do: _parse_args(rest, [arg | so_far])
end
