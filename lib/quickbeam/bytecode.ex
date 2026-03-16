defmodule QuickBEAM.Bytecode do
  @moduledoc """
  Disassembled QuickJS bytecode.

  Returned by `QuickBEAM.disasm/1` and `QuickBEAM.disasm/2`. Contains the
  function metadata, local/closure variable definitions, constant pool,
  and the decoded opcode stream.

  ## Opcodes

  Each opcode is a tuple of `{offset, name, ...operands}`:

      {0, "push_i32", 40}
      {5, "push_i32", 2}
      {10, "add"}
      {11, "return"}

  Labels in branch instructions are resolved to absolute byte offsets.
  Local/arg/closure-var operands use numeric indices matching the
  `locals`, `args`, and `closure_vars` lists.

  ## Constant pool

  Nested functions appear as `%QuickBEAM.Bytecode{}` structs in the
  `cpool` list. Other constant pool entries are plain Elixir terms.
  """

  defstruct [
    :name,
    :filename,
    :line,
    :column,
    :is_strict,
    :kind,
    :arg_count,
    :defined_arg_count,
    :var_count,
    :stack_size,
    :byte_code_len,
    :source,
    args: [],
    locals: [],
    closure_vars: [],
    opcodes: [],
    cpool: []
  ]

  @type local :: %{name: String.t(), kind: String.t()}

  @type closure_var :: %{
          name: String.t(),
          kind: String.t(),
          type: String.t(),
          index: integer()
        }

  @type t :: %__MODULE__{
          name: String.t() | nil,
          filename: String.t() | nil,
          line: integer() | nil,
          column: integer() | nil,
          is_strict: boolean(),
          kind: String.t(),
          arg_count: integer(),
          defined_arg_count: integer(),
          var_count: integer(),
          stack_size: integer(),
          byte_code_len: integer(),
          source: String.t() | nil,
          args: [String.t()],
          locals: [local()],
          closure_vars: [closure_var()],
          opcodes: [tuple()],
          cpool: [t() | term()]
        }

  @doc false
  def from_map(map) when is_map(map) do
    %__MODULE__{
      name: map["name"],
      filename: map["filename"],
      line: map["line"],
      column: map["column"],
      is_strict: map["is_strict"] || false,
      kind: map["kind"] || "normal",
      arg_count: map["arg_count"] || 0,
      defined_arg_count: map["defined_arg_count"] || 0,
      var_count: map["var_count"] || 0,
      stack_size: map["stack_size"] || 0,
      byte_code_len: map["byte_code_len"] || 0,
      source: map["source"],
      args: map["args"] || [],
      locals: map["locals"] || [],
      closure_vars: map["closure_vars"] || [],
      opcodes: build_opcodes(map["opcodes"] || []),
      cpool: build_cpool(map["cpool"] || [])
    }
  end

  defp build_opcodes(ops) do
    Enum.map(ops, fn
      [offset, name | operands] -> List.to_tuple([offset, name | operands])
      other -> other
    end)
  end

  defp build_cpool(items) do
    Enum.map(items, fn
      %{"__type" => "function", "value" => inner} -> from_map(inner)
      other -> other
    end)
  end
end
