Mix.Task.run("app.start")

Code.require_file("../test/support/vm_compiler_audit.ex", __DIR__)

alias QuickBEAM.VM.{BytecodeParser, Compiler, InstructionDecoder, Heap, Opcodes}
alias QuickBEAM.VM.Compiler.Analysis.CFG
alias QuickBEAM.VM.Compiler.Diagnostics

compile_source = fn source ->
  Heap.reset()
  {:ok, rt} = QuickBEAM.start(apis: false)

  try do
    with {:ok, bytecode} <- QuickBEAM.compile(rt, source),
         {:ok, parsed} <- BytecodeParser.decode(bytecode) do
      {:ok, parsed}
    end
  after
    QuickBEAM.stop(rt)
  end
end

collect_functions = fn parsed ->
  collect = fn collect, %QuickBEAM.VM.Function{} = fun ->
    [
      fun
      | Enum.flat_map(fun.constants, fn
          %QuickBEAM.VM.Function{} = inner -> collect.(collect, inner)
          _ -> []
        end)
    ]
  end

  collect.(collect, parsed.value)
end

opcode_rows = fn %QuickBEAM.VM.Function{instructions: instructions} when is_tuple(instructions) ->
  instructions
  |> Tuple.to_list()
  |> Enum.with_index()
  |> Enum.map(fn {{op, _args}, pc} ->
    name =
      case CFG.opcode_name(op) do
        {:ok, name} -> name
        {:error, _} -> :unknown
      end

    %{pc: pc, opcode: name}
  end)
end

synthetic_function = fn byte_code ->
  {:ok, instructions} = InstructionDecoder.decode(byte_code, 0)

  %QuickBEAM.VM.Function{
    id: :erlang.unique_integer([:positive, :monotonic]),
    name: "quickjs-reference-opcode",
    filename: "<quickjs-reference-opcode>",
    line_num: 1,
    col_num: 1,
    arg_count: 0,
    var_count: 0,
    defined_arg_count: 0,
    stack_size: 8,
    instructions: List.to_tuple(instructions)
  }
end

reference_opcode_functions = [
  {"quickjs reference nip1/nop",
   synthetic_function.(
     <<181, 182, 183, Opcodes.num(:nip1), Opcodes.num(:nop), Opcodes.num(:add),
       Opcodes.num(:return)>>
   )},
  {"quickjs reference with_get_ref_undef",
   synthetic_function.(<<
     Opcodes.num(:object),
     185,
     Opcodes.num(:define_field),
     1::little-32,
     Opcodes.num(:with_get_ref_undef),
     1::little-32,
     7::signed-little-32,
     1,
     181,
     Opcodes.num(:return),
     Opcodes.num(:return)
   >>)}
]

rows =
  for {case_name, source} <- QuickBEAM.VM.CompilerAudit.corpus_cases(), reduce: [] do
    acc ->
      case compile_source.(source) do
        {:ok, parsed} ->
          functions = collect_functions.(parsed)

          Enum.reduce(functions, acc, fn fun, acc ->
            compile_result = Compiler.compile(fun)
            capabilities = Diagnostics.capabilities(fun)

            opcodes = opcode_rows.(fun)

            row = %{
              case: case_name,
              compilable?: match?({:ok, _}, compile_result),
              compile_error:
                if(match?({:error, _}, compile_result), do: elem(compile_result, 1), else: nil),
              capability_compilable?: capabilities.compilable?,
              unsupported_opcodes: capabilities.unsupported_opcodes,
              opcodes: opcodes
            }

            [row | acc]
          end)

        {:error, reason} ->
          [%{case: case_name, compile_input_error: reason, opcodes: []} | acc]
      end
  end
  |> Enum.reverse()

reference_rows =
  for {case_name, fun} <- reference_opcode_functions do
    Heap.put_fn_atoms(fun, {"<quickjs-reference-opcode>"})
    compile_result = Compiler.compile(fun)
    capabilities = Diagnostics.capabilities(fun)

    opcodes = opcode_rows.(fun)

    %{
      case: case_name,
      compilable?: match?({:ok, _}, compile_result),
      compile_error:
        if(match?({:error, _}, compile_result), do: elem(compile_result, 1), else: nil),
      capability_compilable?: capabilities.compilable?,
      unsupported_opcodes: capabilities.unsupported_opcodes,
      opcodes: opcodes
    }
  end

rows = rows ++ reference_rows

opcode_counts =
  rows
  |> Enum.flat_map(& &1.opcodes)
  |> Enum.frequencies_by(& &1.opcode)
  |> Enum.sort_by(fn {opcode, _count} -> Atom.to_string(opcode) end)

unsupported_counts =
  rows
  |> Enum.flat_map(&Map.get(&1, :unsupported_opcodes, []))
  |> Enum.frequencies_by(& &1.opcode)
  |> Enum.sort_by(fn {opcode, _count} -> Atom.to_string(opcode) end)

compile_errors =
  rows
  |> Enum.filter(&Map.get(&1, :compile_error))
  |> Enum.frequencies_by(&inspect(&1.compile_error))
  |> Enum.sort_by(fn {_reason, count} -> -count end)

all_opcodes =
  Opcodes.table()
  |> Enum.map(fn {_opcode, {name, _fmt, _size, _stack_effect, _flags}} -> name end)
  |> Enum.uniq()
  |> Enum.sort_by(&Atom.to_string/1)

covered_opcodes = opcode_counts |> Enum.map(&elem(&1, 0)) |> MapSet.new()
missing_opcodes = Enum.reject(all_opcodes, &MapSet.member?(covered_opcodes, &1))
coverage_percent = Float.round(length(opcode_counts) / max(length(all_opcodes), 1) * 100, 2)

family_for = fn opcode ->
  name = Atom.to_string(opcode)

  cond do
    String.starts_with?(name, "with_") -> "with"
    String.contains?(name, "ref") -> "ref"
    name in ["nop", "nip1", "invalid"] -> "control"
    true -> name |> String.split("_") |> hd()
  end
end

missing_groups =
  missing_opcodes
  |> Enum.group_by(family_for)
  |> Enum.sort_by(fn {family, _opcodes} -> family end)

known_blockers = %{
  invalid: "intentional sentinel; do not fabricate invalid bytecode for coverage"
}

IO.puts(
  "compiler_opcode_functions=#{length(rows)} compiler_opcode_unique=#{length(opcode_counts)} compiler_opcode_total=#{length(all_opcodes)} compiler_opcode_missing=#{length(missing_opcodes)} compiler_opcode_coverage_percent=#{coverage_percent} compiler_opcode_unsupported=#{length(unsupported_counts)} compiler_compile_error_groups=#{length(compile_errors)}"
)

for {opcode, count} <- opcode_counts do
  IO.puts("COMPILER_OPCODE opcode=#{opcode} count=#{count}")
end

for {opcode, count} <- unsupported_counts do
  IO.puts("COMPILER_UNSUPPORTED_OPCODE opcode=#{opcode} count=#{count}")
end

for {family, opcodes} <- missing_groups do
  names = Enum.map_join(opcodes, ",", &Atom.to_string/1)

  IO.puts(
    "COMPILER_MISSING_OPCODE_GROUP family=#{family} count=#{length(opcodes)} opcodes=#{names}"
  )
end

for opcode <- missing_opcodes, note = Map.get(known_blockers, opcode) do
  IO.puts("COMPILER_MISSING_OPCODE_NOTE opcode=#{opcode} note=#{note}")
end

for {reason, count} <- compile_errors do
  IO.puts("COMPILER_COMPILE_ERROR count=#{count} reason=#{reason}")
end

IO.puts("METRIC compiler_opcode_functions=#{length(rows)}")
IO.puts("METRIC compiler_opcode_unique=#{length(opcode_counts)}")
IO.puts("METRIC compiler_opcode_total=#{length(all_opcodes)}")
IO.puts("METRIC compiler_opcode_missing=#{length(missing_opcodes)}")
IO.puts("METRIC compiler_opcode_coverage_percent=#{coverage_percent}")
IO.puts("METRIC compiler_opcode_report_fields=9")
IO.puts("METRIC compiler_opcode_unsupported=#{length(unsupported_counts)}")
IO.puts("METRIC compiler_compile_error_groups=#{length(compile_errors)}")
