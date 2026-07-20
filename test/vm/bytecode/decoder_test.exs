defmodule QuickBEAM.VM.Bytecode.DecoderTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.VM.ABI
  alias QuickBEAM.VM.Bytecode.Checksum
  alias QuickBEAM.VM.Bytecode.Decoder
  alias QuickBEAM.VM.Bytecode.Instruction
  alias QuickBEAM.VM.Bytecode.Opcode
  alias QuickBEAM.VM.Bytecode.Verifier
  alias QuickBEAM.VM.Program
  alias QuickBEAM.VM.Program.Function

  setup do
    {:ok, runtime} = QuickBEAM.start(apis: false)

    on_exit(fn ->
      try do
        QuickBEAM.stop(runtime)
      catch
        :exit, _ -> :ok
      end
    end)

    %{runtime: runtime}
  end

  test "public compile API returns a verified program with the requested filename" do
    source = "function render(){ return 'ok' } render()"
    assert {:ok, %Program{} = program} = QuickBEAM.VM.compile(source, filename: "server.js")

    assert program.source_digest == :crypto.hash(:sha256, source)
    assert byte_size(program.bytecode_digest) == 32
    assert program.root.filename == "server.js"
    assert Enum.all?(nested_functions(program.root), &(&1.filename == "server.js"))
  end

  test "decodes and verifies current QuickJS bytecode", %{runtime: runtime} do
    {:ok, bytecode} =
      QuickBEAM.compile(runtime, "function add(a, b) { return a + b } add(1, 2)")

    assert {:ok, %Program{} = program} = QuickBEAM.VM.decode(bytecode)
    assert program.version == ABI.bytecode_version()
    assert program.fingerprint == ABI.fingerprint()
    assert program.bytecode_digest == :crypto.hash(:sha256, bytecode)
    assert program.source_digest == nil
    assert %Function{id: 0} = program.root
    assert tuple_size(program.root.instructions) > 0
  end

  test "decodes source positions without inspecting source text", %{runtime: runtime} do
    source = "let marker = 'line 999, column 999';\nlet value = 2;\nvalue"
    {:ok, bytecode} = QuickBEAM.compile(runtime, source)

    assert {:ok, %Program{root: function}} = QuickBEAM.VM.decode(bytecode)
    positions = Tuple.to_list(function.source_positions)

    assert {3, 1} in positions
    refute {999, 999} in positions
  end

  test "decodes representative QuickJS v26 opcode families", %{runtime: runtime} do
    sources = [
      "function sum(n){ let x=0; for(let i=0;i<n;i++) x+=i; return x } sum(5)",
      "function outer(x){ return y => x+y } outer(1)(2)",
      "class A { constructor(x){ this.x=x } value(){ return this.x } } new A(1).value()",
      "try { throw new Error('x') } catch (error) { error.message } finally { 1 }",
      "async function f(){ return await Promise.resolve(3) } f()",
      ~S|/a+/gi.test("aaa")|
    ]

    for source <- sources do
      assert {:ok, bytecode} = QuickBEAM.compile(runtime, source)
      assert {:ok, %Program{}} = QuickBEAM.VM.decode(bytecode)
    end
  end

  test "assigns deterministic function identifiers", %{runtime: runtime} do
    source = "function outer(){ return function inner(){ return 1 } } outer()"
    {:ok, bytecode} = QuickBEAM.compile(runtime, source)

    assert {:ok, first} = QuickBEAM.VM.decode(bytecode)
    assert {:ok, second} = QuickBEAM.VM.decode(bytecode)
    assert first == second

    assert [0, 1, 2] == collect_function_ids(first.root)
  end

  test "rejects a stale QuickJS bytecode version before decoding", %{runtime: runtime} do
    {:ok, <<_version, checksum::binary-size(4), payload::binary>>} =
      QuickBEAM.compile(runtime, "42")

    stale = <<25, checksum::binary, payload::binary>>
    assert {:error, {:bad_version, 25}} = QuickBEAM.VM.decode(stale)
  end

  test "rejects bytecode with a checksum mismatch", %{runtime: runtime} do
    {:ok, bytecode} = QuickBEAM.compile(runtime, "42")
    last = :binary.last(bytecode)
    prefix = binary_part(bytecode, 0, byte_size(bytecode) - 1)
    corrupted = prefix <> <<Bitwise.bxor(last, 1)>>

    assert {:error, :checksum_mismatch} = QuickBEAM.VM.decode(corrupted)
  end

  test "decodes serialized object keys as atom references" do
    key = "key"
    atom_index = Opcode.js_atom_end()

    payload =
      IO.iodata_to_binary([
        Varint.LEB128.encode(1),
        <<1>>,
        encoded_string(key),
        <<Opcode.bc_tag_object()>>,
        Varint.LEB128.encode(1),
        Varint.LEB128.encode(atom_index * 2),
        <<Opcode.bc_tag_int32()>>,
        Varint.LEB128.encode(84)
      ])

    bytecode = bytecode_envelope(payload)
    assert {:ok, %Program{root: {:object, %{^key => 42}}}} = Decoder.decode(bytecode)
    assert {:error, :invalid_root_function} = QuickBEAM.VM.decode(bytecode)
  end

  test "rejects overlong LEB128 fields" do
    payload = <<0x80, 0x80, 0x80, 0x80, 0x80, 0>>
    assert {:error, :bad_leb128} = payload |> bytecode_envelope() |> QuickBEAM.VM.decode()
  end

  test "applies decoder and verifier limits", %{runtime: runtime} do
    {:ok, bytecode} = QuickBEAM.compile(runtime, "1 + 2")

    assert {:error, {:limit_exceeded, :bytecode_bytes, byte_count}} =
             QuickBEAM.VM.decode(bytecode, max_bytecode_bytes: 5)

    assert byte_count == byte_size(bytecode)

    assert {:error, {:limit_exceeded, :instructions, count}} =
             QuickBEAM.VM.decode(bytecode, max_instructions: 1)

    assert count > 1
  end

  test "rejects a truncated variable definition with a typed error" do
    fixture =
      Path.expand("../../fixtures/vm/fuzz/regressions/truncated-vardef-flags.bin", __DIR__)

    assert {:error, :unexpected_end} = fixture |> File.read!() |> QuickBEAM.VM.decode()
  end

  test "verifier rejects an invalid constant index", %{runtime: runtime} do
    {:ok, bytecode} = QuickBEAM.compile(runtime, "42")
    {:ok, program} = QuickBEAM.VM.decode(bytecode)
    opcode = Opcode.num(:push_const)

    bad_function = %{
      program.root
      | instructions: {{opcode, [999]}},
        source_positions: {{1, 1}}
    }

    bad_program = %{program | root: bad_function}

    assert {:error, {:invalid_instruction, 0, 0, {:invalid_index, :constant, 999}}} =
             Verifier.verify(bad_program)
  end

  test "verifier rejects invalid control-flow and stack metadata", %{runtime: runtime} do
    {:ok, bytecode} = QuickBEAM.compile(runtime, "42")
    {:ok, program} = QuickBEAM.VM.decode(bytecode)
    instruction_count = tuple_size(program.root.instructions)

    bad_jump = %{
      program.root
      | instructions:
          put_elem(program.root.instructions, 0, {Opcode.num(:goto), [instruction_count]})
    }

    assert {:error, {:invalid_instruction, 0, 0, {:invalid_index, :label, ^instruction_count}}} =
             Verifier.verify(%{program | root: bad_jump})

    underflow = %{
      program.root
      | instructions: {{Opcode.num(:drop), []}, {Opcode.num(:return_undef), []}},
        source_positions: {{1, 1}, {1, 1}},
        stack_size: 0
    }

    assert {:error, {:invalid_stack, 0, {:stack_underflow, 0, 0, 1}}} =
             Verifier.verify(%{program | root: underflow})

    declared = %{program.root | stack_size: program.root.stack_size + 1}

    assert {:error, {:invalid_stack, 0, {:stack_size_mismatch, _declared}}} =
             Verifier.verify(%{program | root: declared})

    invalid_operand = %{
      program.root
      | instructions:
          put_elem(program.root.instructions, 0, {Opcode.num(:push_i32), [:not_an_integer]})
    }

    assert {:error, {:invalid_instruction, 0, 0, :invalid_operand_type}} =
             Verifier.verify(%{program | root: invalid_operand})
  end

  test "verifier rejects malformed decoded container shapes without raising", %{runtime: runtime} do
    {:ok, bytecode} = QuickBEAM.compile(runtime, "42")
    {:ok, program} = QuickBEAM.VM.decode(bytecode)

    assert {:error, :invalid_root_function} = Verifier.verify(%{program | root: nil})

    assert {:error, {:invalid_function, 0, :constants}} =
             Verifier.verify(%{program | root: %{program.root | constants: :invalid}})

    malformed_locals = %{program.root | var_count: 1, locals: [nil]}

    assert {:error, :invalid_variable_metadata} =
             Verifier.verify(%{program | root: malformed_locals})

    malformed_constant = %{program.root | constants: [{:array, :invalid}]}

    assert {:error, :invalid_array_constant} =
             Verifier.verify(%{program | root: malformed_constant})

    assert {:error, {:invalid_options, :invalid}} = Verifier.verify(program, :invalid)
    assert {:error, {:invalid_option, :invalid}} = Verifier.verify(program, [:invalid])
    assert {:error, :invalid_root_function} = QuickBEAM.VM.eval(%{program | root: nil})
  end

  test "instruction decoder rejects labels inside an instruction" do
    goto = Opcode.num(:goto)

    assert {:error, {:invalid_label, 1}} =
             Instruction.decode(<<goto, 0::little-signed-32>>)
  end

  defp encoded_string(value),
    do: [Varint.LEB128.encode(byte_size(value) * 2), value]

  defp bytecode_envelope(payload) do
    checksum = Checksum.calculate(payload)
    <<ABI.bytecode_version(), checksum::little-unsigned-32, payload::binary>>
  end

  defp nested_functions(%Function{} = function) do
    [function | Enum.flat_map(function.constants, &nested_functions/1)]
  end

  defp nested_functions(_constant), do: []

  defp collect_function_ids(%Function{} = function) do
    [function.id | Enum.flat_map(function.constants, &collect_function_ids/1)]
  end

  defp collect_function_ids(_constant), do: []
end
