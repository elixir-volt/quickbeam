Mix.Task.run("app.start")

Code.require_file("../test/support/vm_compiler_audit.ex", __DIR__)

alias QuickBEAM.VM.{Bytecode, Compiler, Decoder, Heap}
alias QuickBEAM.VM.Compiler.Analysis.CFG
alias QuickBEAM.VM.Compiler.Diagnostics

compile_source = fn source ->
  Heap.reset()
  {:ok, rt} = QuickBEAM.start(apis: false)

  try do
    with {:ok, bytecode} <- QuickBEAM.compile(rt, source),
         {:ok, parsed} <- Bytecode.decode(bytecode) do
      {:ok, parsed}
    end
  after
    QuickBEAM.stop(rt)
  end
end

collect_functions = fn parsed ->
  collect = fn collect, %Bytecode.Function{} = fun ->
    [
      fun
      | Enum.flat_map(fun.constants, fn
          %Bytecode.Function{} = inner -> collect.(collect, inner)
          _ -> []
        end)
    ]
  end

  collect.(collect, parsed.value)
end

rows =
  for {case_name, source} <- QuickBEAM.VM.CompilerAudit.corpus_cases(), reduce: [] do
    acc ->
      case compile_source.(source) do
        {:ok, parsed} ->
          functions = collect_functions.(parsed)

          Enum.reduce(functions, acc, fn fun, acc ->
            compile_result = Compiler.compile(fun)
            capabilities = Diagnostics.capabilities(fun)

            opcodes =
              case Decoder.decode(fun.byte_code, fun.arg_count) do
                {:ok, instructions} ->
                  instructions
                  |> Enum.with_index()
                  |> Enum.map(fn {{op, _args}, pc} ->
                    name =
                      case CFG.opcode_name(op) do
                        {:ok, name} -> name
                        {:error, _} -> :unknown
                      end

                    %{pc: pc, opcode: name}
                  end)

                {:error, _} ->
                  []
              end

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

IO.puts(
  "compiler_opcode_functions=#{length(rows)} compiler_opcode_unique=#{length(opcode_counts)} compiler_opcode_unsupported=#{length(unsupported_counts)} compiler_compile_error_groups=#{length(compile_errors)}"
)

for {opcode, count} <- opcode_counts do
  IO.puts("COMPILER_OPCODE opcode=#{opcode} count=#{count}")
end

for {opcode, count} <- unsupported_counts do
  IO.puts("COMPILER_UNSUPPORTED_OPCODE opcode=#{opcode} count=#{count}")
end

for {reason, count} <- compile_errors do
  IO.puts("COMPILER_COMPILE_ERROR count=#{count} reason=#{reason}")
end

IO.puts("METRIC compiler_opcode_functions=#{length(rows)}")
IO.puts("METRIC compiler_opcode_unique=#{length(opcode_counts)}")
IO.puts("METRIC compiler_opcode_unsupported=#{length(unsupported_counts)}")
IO.puts("METRIC compiler_compile_error_groups=#{length(compile_errors)}")
