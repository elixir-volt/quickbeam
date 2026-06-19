defmodule QuickBEAM.VM.ECMAMetadataTest do
  use ExUnit.Case, async: true

  @section_file Path.expand("../support/ecma_sections.txt", __DIR__)
  @valid_sections @section_file |> File.read!() |> String.split("\n", trim: true) |> MapSet.new()
  @runtime_files Path.wildcard("lib/quickbeam/vm/runtime/**/*.ex") ++
                   Path.wildcard("lib/quickbeam/vm/runtime.ex")

  @proposal_or_host_declarations [
    {QuickBEAM.VM.Runtime.Map, :proto_property_meta, "getOrInsert"},
    {QuickBEAM.VM.Runtime.Map, :proto_property_meta, "getOrInsertComputed"},
    {QuickBEAM.VM.Runtime.Iterator, :static_property_meta, "concat"},
    {QuickBEAM.VM.Runtime.Iterator, :static_property_meta, "zip"},
    {QuickBEAM.VM.Runtime.Iterator, :static_property_meta, "zipKeyed"}
  ]

  test "runtime @ecma annotations point at known ECMA-262 sections" do
    invalid =
      for file <- @runtime_files,
          {line, line_number} <- file |> File.read!() |> String.split("\n") |> Enum.with_index(1),
          [section] <- Regex.scan(~r/@ecma\s+"([^"]+)"/, line, capture: :all_but_first),
          not MapSet.member?(@valid_sections, section),
          do: {file, line_number, section}

    assert invalid == []
  end

  test "specialized Function prototype methods expose ECMA metadata" do
    {:obj, ref} = QuickBEAM.VM.Runtime.Function.prototype(cache: false)
    proto = QuickBEAM.VM.Heap.get_obj(ref)

    assert %{ecma: "20.2.3.1"} = QuickBEAM.VM.Builtin.metadata_for(proto["apply"])
    assert %{ecma: "20.2.3.2"} = QuickBEAM.VM.Builtin.metadata_for(proto["bind"])
    assert %{ecma: "20.2.3.3"} = QuickBEAM.VM.Builtin.metadata_for(proto["call"])
    assert %{ecma: "20.2.3.5"} = QuickBEAM.VM.Builtin.metadata_for(proto["toString"])

    assert %{ecma: "20.2.3.6"} =
             QuickBEAM.VM.Builtin.metadata_for(proto[{:symbol, "Symbol.hasInstance"}])
  end

  test "specialized Error definitions expose ECMA metadata where standard" do
    definitions = Map.new(QuickBEAM.VM.Runtime.Errors.builtin_definitions(), &{&1.name, &1.ecma})

    assert definitions["Error"] == "20.5.1.1"
    assert definitions["TypeError"] == "20.5.6.1.1"
    assert definitions["AggregateError"] == "20.5.7.1.1"
    assert definitions["SuppressedError"] == nil
  end

  test "proposal and host declarations stay out of ECMA metadata" do
    for {module, function, key} <- @proposal_or_host_declarations do
      assert %{ecma: nil} = apply(module, function, [key])
    end

    raw_json = QuickBEAM.VM.Runtime.JSON.object() |> elem(2) |> Map.fetch!("rawJSON")
    is_raw_json = QuickBEAM.VM.Runtime.JSON.object() |> elem(2) |> Map.fetch!("isRawJSON")
    sum_precise = QuickBEAM.VM.Runtime.Math.object() |> elem(2) |> Map.fetch!("sumPrecise")

    assert %{ecma: nil} = QuickBEAM.VM.Builtin.metadata_for(raw_json)
    assert %{ecma: nil} = QuickBEAM.VM.Builtin.metadata_for(is_raw_json)
    assert %{ecma: nil} = QuickBEAM.VM.Builtin.metadata_for(sum_precise)
  end
end
