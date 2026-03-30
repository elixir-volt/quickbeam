defmodule QuickBEAM.WASM.Module do
  @moduledoc """
  A decoded WebAssembly module.

  Returned by `QuickBEAM.WASM.disasm/1`. Contains the module's type
  signatures, imports, exports, function bodies with decoded opcodes,
  memories, tables, globals, data segments, and custom sections.

  ## Functions

  Each function is a `%QuickBEAM.WASM.Function{}` struct with decoded
  opcodes in the same `{offset, name, ...operands}` tuple format used
  by `QuickBEAM.Bytecode`:

      %QuickBEAM.WASM.Function{
        index: 0,
        name: "add",
        type_idx: 0,
        params: [:i32, :i32],
        results: [:i32],
        locals: [],
        opcodes: [
          {0, :local_get, 0},
          {2, :local_get, 1},
          {4, :i32_add},
          {5, :end}
        ]
      }
  """

  defstruct [
    :version,
    :start,
    types: [],
    imports: [],
    exports: [],
    functions: [],
    memories: [],
    tables: [],
    globals: [],
    data: [],
    elements: [],
    tags: [],
    custom_sections: []
  ]

  @type import_desc :: %{
          module: String.t(),
          name: String.t(),
          kind: :func | :table | :memory | :global | :tag,
          type_idx: non_neg_integer() | nil,
          type: term()
        }

  @type export_desc :: %{
          name: String.t(),
          kind: :func | :table | :memory | :global | :tag,
          index: non_neg_integer()
        }

  @type t :: %__MODULE__{
          version: non_neg_integer(),
          start: non_neg_integer() | nil,
          types: [map()],
          imports: [import_desc()],
          exports: [export_desc()],
          functions: [QuickBEAM.WASM.Function.t()],
          memories: [map()],
          tables: [map()],
          globals: [map()],
          data: [map()],
          elements: [map()],
          tags: [map()],
          custom_sections: [map()]
        }
end
