defmodule QuickBEAM.VM.BuiltinDSLTest do
  use ExUnit.Case, async: true

  defmodule StructuredSample do
    use QuickBEAM.VM.Builtin

    @ecma "99.1"
    defintrinsic "StructuredSample" do
      constructor length: 1 do
        {args, this}
      end

      install do
        send(self(), {:structured_install, ctor, opts})
      end
    end

    static_methods do
      @ecma "99.1.2.1"
      method "from", length: 1 do
        :from
      end

      @ecma "99.1.2.2"
      property("answer", value: 42, writable: false, configurable: false)
    end

    prototype_methods do
      @ecma "99.1.3.1"
      method "valueOf", length: 0 do
        this
      end

      @ecma "99.1.3.2"
      property("label", value: "structured", writable: false)
    end
  end

  defmodule PrototypeBlockSample do
    use QuickBEAM.VM.Builtin

    @ecma "99.2"
    defintrinsic "PrototypeBlockSample" do
      constructor length: 0 do
        this
      end

      prototype extends: :object do
        slot(:BooleanData, false)

        @ecma "99.2.3.1"
        method "flag", receiver: :boolean, length: 0 do
          this
        end

        @ecma "99.2.3.2"
        getter "label" do
          "prototype"
        end

        symbol :iterator do
          method do
            this
          end
        end

        symbol :toStringTag do
          get do
            "PrototypeBlockSample"
          end
        end
      end
    end
  end

  defmodule MultiIntrinsicSample do
    use QuickBEAM.VM.Builtin

    defintrinsics do
      intrinsic("MultiMap",
        constructor: fn _args, this -> this end,
        length: 0,
        phase: :collections
      )

      intrinsic("MultiWeakMap",
        constructor: fn _args, this -> this end,
        length: 0,
        phase: :collections,
        after_install: fn _ctor, _opts -> :ok end
      )

      intrinsic "MultiSet" do
        constructor(fn _args, this -> this end, length: 0, phase: :collections)

        install do
          send(self(), {:multi_set_install, ctor, opts})
        end
      end
    end
  end

  defmodule Sample do
    use QuickBEAM.VM.Builtin

    @ecma "20.1"
    builtin_definition("Sample", constructor: fn _args, this -> this end, length: 1)

    @ecma "20.1.2.19"
    static "keys", length: 1 do
      :ok
    end

    @ecma "B.3.1"
    @annex :b
    static "annexMethod", length: 0 do
      :ok
    end

    @ecma "20.1.3.6"
    proto "toString", length: 0 do
      "[object Sample]"
    end

    static "withoutEcma", length: 0 do
      :ok
    end

    def object_with_parent(parent) do
      object extends: parent do
        method "next" do
          :next
        end

        symbol :toStringTag do
          data("Sample Iterator", writable: false, enumerable: false, configurable: true)
        end
      end
    end

    def inline_methods do
      build_methods do
        @ecma "20.1.3.6"
        method "toString", length: 0 do
          "[object Sample]"
        end

        @ecma "B.3.1"
        @annex :b
        method "annexMethod", length: 0 do
          :ok
        end
      end
    end
  end

  test "defintrinsics emits grouped runtime definitions" do
    assert [strong, weak, set] = MultiIntrinsicSample.builtin_definitions()
    assert strong.name == "MultiMap"
    assert strong.length == 0
    assert strong.phase == :collections
    assert weak.name == "MultiWeakMap"
    assert is_function(weak.after_install, 2)
    assert set.name == "MultiSet"
    assert is_function(set.after_install, 2)

    set.after_install.(:ctor, target: :multi)
    assert_received {:multi_set_install, :ctor, [target: :multi]}
  end

  test "defintrinsic and contextual method blocks expose first-class specs" do
    definition = StructuredSample.builtin_definition()
    assert %QuickBEAM.VM.Builtin.Definition{ecma: "99.1", length: 1} = definition
    assert definition.constructor.([:value], :receiver) == {[:value], :receiver}

    definition.after_install.(:ctor, target: :test)
    assert_received {:structured_install, :ctor, [target: :test]}

    assert %QuickBEAM.VM.Builtin.FunctionSpec{ecma: "99.1.2.1", kind: :static} =
             StructuredSample.static_property_spec("from")

    assert %QuickBEAM.VM.Builtin.FunctionSpec{ecma: "99.1.3.1", kind: :prototype} =
             StructuredSample.proto_property_spec("valueOf")

    assert %QuickBEAM.VM.Builtin.PropertySpec{
             ecma: "99.1.2.2",
             kind: :data,
             value: 42,
             descriptor: %{writable: false, enumerable: false, configurable: false}
           } = StructuredSample.static_property_spec("answer")

    assert %QuickBEAM.VM.Builtin.PropertySpec{
             ecma: "99.1.3.2",
             value: "structured",
             descriptor: %{writable: false, enumerable: false, configurable: true}
           } = StructuredSample.proto_property_spec("label")

    assert %QuickBEAM.VM.Builtin.IntrinsicSpec{} = spec = StructuredSample.builtin_spec()
    assert spec.name == "StructuredSample"
    assert spec.constructor.ecma == "99.1"

    assert [
             %QuickBEAM.VM.Builtin.PropertySpec{key: "from", ecma: "99.1.2.1"},
             %QuickBEAM.VM.Builtin.PropertySpec{key: "answer", ecma: "99.1.2.2"}
           ] = spec.statics

    assert [
             %QuickBEAM.VM.Builtin.PropertySpec{key: "valueOf", ecma: "99.1.3.1"},
             %QuickBEAM.VM.Builtin.PropertySpec{key: "label", ecma: "99.1.3.2"}
           ] = spec.prototype.properties
  end

  test "defintrinsic prototype block declares and installs prototype shape" do
    definition = PrototypeBlockSample.builtin_definition()
    assert %QuickBEAM.VM.Builtin.Definition{ecma: "99.2"} = definition
    assert is_function(definition.after_install, 2)

    assert %QuickBEAM.VM.Builtin.FunctionSpec{ecma: "99.2.3.1", kind: :prototype} =
             PrototypeBlockSample.proto_property_spec("flag")

    assert %QuickBEAM.VM.Builtin.PropertySpec{ecma: "99.2.3.2", kind: :accessor} =
             PrototypeBlockSample.proto_property_spec("label")

    assert %QuickBEAM.VM.Builtin.FunctionSpec{kind: :prototype} =
             PrototypeBlockSample.proto_property_spec({:symbol, "Symbol.iterator"})

    assert %QuickBEAM.VM.Builtin.PropertySpec{kind: :accessor} =
             PrototypeBlockSample.proto_property_spec({:symbol, "Symbol.toStringTag"})

    ctor =
      QuickBEAM.VM.Builtin.Installer.install(definition,
        target: {:realm, object_proto: QuickBEAM.VM.Heap.get_object_prototype()}
      )

    {:obj, ref} = QuickBEAM.VM.Heap.get_ctor_statics(ctor)["prototype"]
    proto = QuickBEAM.VM.Heap.get_obj(ref)

    assert proto[QuickBEAM.VM.Builtin.slot_key(:BooleanData)] == false
    assert proto["constructor"] == ctor
    assert {:builtin, "flag", _} = proto["flag"]
    assert {:accessor, {:builtin, "get label", _}, nil} = proto["label"]
    assert {:builtin, "[Symbol.iterator]", _} = proto[{:symbol, "Symbol.iterator"}]

    assert {:accessor, {:builtin, "get [Symbol.toStringTag]", _}, nil} =
             proto[{:symbol, "Symbol.toStringTag"}]

    refute Map.has_key?(QuickBEAM.VM.Heap.get_prop_desc(ref, "label"), :writable)
    assert QuickBEAM.VM.Heap.get_prop_desc(ref, "label").configurable == true

    assert %QuickBEAM.VM.Builtin.Meta{ecma: "99.2.3.1"} =
             QuickBEAM.VM.Builtin.metadata_for(proto["flag"])
  end

  test "builtin installer can install declared property specs" do
    spec = StructuredSample.builtin_spec()
    ctor = {:builtin, "StructuredSample", fn _args, this -> this end}
    {:obj, proto_ref} = QuickBEAM.VM.Heap.wrap(%{})

    QuickBEAM.VM.Builtin.Installer.install_property_specs(
      {:constructor, ctor},
      StructuredSample,
      spec.statics,
      :static
    )

    QuickBEAM.VM.Builtin.Installer.install_property_specs(
      {:object, proto_ref},
      StructuredSample,
      spec.prototype.properties,
      :prototype
    )

    statics = QuickBEAM.VM.Heap.get_ctor_statics(ctor)
    proto = QuickBEAM.VM.Heap.get_obj(proto_ref)

    assert statics["answer"] == 42
    assert QuickBEAM.VM.Heap.get_ctor_prop_desc(ctor, "answer").writable == false
    assert {:builtin, "from", _} = statics["from"]
    assert QuickBEAM.VM.Builtin.metadata_for(statics["from"]).ecma == "99.1.2.1"

    assert proto["label"] == "structured"
    assert QuickBEAM.VM.Heap.get_prop_desc(proto_ref, "label").writable == false
    assert {:builtin, "valueOf", _} = proto["valueOf"]
    assert QuickBEAM.VM.Builtin.metadata_for(proto["valueOf"]).ecma == "99.1.3.1"
  end

  test "@ecma annotates builtin definitions" do
    assert %QuickBEAM.VM.Builtin.Definition{ecma: "20.1"} = Sample.builtin_definition()
  end

  test "@ecma annotates the next static builtin metadata" do
    assert %QuickBEAM.VM.Builtin.Meta{ecma: "20.1.2.19"} =
             Sample.static_property_meta("keys")

    assert %QuickBEAM.VM.Builtin.Meta{ecma: nil} = Sample.static_property_meta("withoutEcma")
  end

  test "@annex annotates the next builtin metadata" do
    assert %QuickBEAM.VM.Builtin.Meta{ecma: "B.3.1", annex: :b} =
             Sample.static_property_meta("annexMethod")
  end

  test "@ecma annotates the next prototype builtin metadata" do
    assert %QuickBEAM.VM.Builtin.Meta{ecma: "20.1.3.6"} =
             Sample.proto_property_meta("toString")
  end

  test "@ecma annotates inline method metadata" do
    method = Sample.inline_methods()["toString"]

    assert %QuickBEAM.VM.Builtin.Meta{ecma: "20.1.3.6", length: 0} =
             QuickBEAM.VM.Builtin.metadata_for(method)

    annex_method = Sample.inline_methods()["annexMethod"]

    assert %QuickBEAM.VM.Builtin.Meta{ecma: "B.3.1", annex: :b} =
             QuickBEAM.VM.Builtin.metadata_for(annex_method)
  end

  test "runtime builtins can expose ECMA clause metadata" do
    assert %QuickBEAM.VM.Builtin.Definition{ecma: "20.1"} =
             QuickBEAM.VM.Runtime.Object.builtin_definition()

    assert %QuickBEAM.VM.Builtin.Meta{ecma: "20.1.2.19"} =
             QuickBEAM.VM.Runtime.Object.static_property_meta("keys")

    {:obj, ref} = QuickBEAM.VM.Runtime.Object.build_prototype()
    method = QuickBEAM.VM.Heap.get_obj(ref)["toString"]

    assert %QuickBEAM.VM.Builtin.Meta{ecma: "20.1.3.6"} =
             QuickBEAM.VM.Builtin.metadata_for(method)
  end

  test "array prototype installation preserves ECMA clause metadata" do
    assert %QuickBEAM.VM.Builtin.Definition{ecma: "23.1"} =
             QuickBEAM.VM.Runtime.Array.builtin_definition()

    assert %QuickBEAM.VM.Builtin.Meta{ecma: "23.1.3.23"} =
             QuickBEAM.VM.Runtime.Array.proto_property_meta("push")

    {:obj, ref} = QuickBEAM.VM.Runtime.Array.prototype()
    method = QuickBEAM.VM.Heap.get_obj(ref)["push"]

    assert %QuickBEAM.VM.Builtin.Meta{ecma: "23.1.3.23"} =
             QuickBEAM.VM.Builtin.metadata_for(method)
  end

  test "prototype specs preserve ECMA metadata" do
    assert %QuickBEAM.VM.Builtin.Definition{ecma: "22.1"} =
             QuickBEAM.VM.Runtime.String.builtin_definition()

    assert %QuickBEAM.VM.Builtin.FunctionSpec{ecma: "22.1.3.2"} =
             QuickBEAM.VM.Runtime.String.proto_property_spec("charAt")

    assert %QuickBEAM.VM.Builtin.FunctionSpec{ecma: "22.1.3.36"} =
             QuickBEAM.VM.Runtime.String.proto_property_spec({:symbol, "Symbol.iterator"})

    assert %QuickBEAM.VM.Builtin.Meta{ecma: "B.2.2.1", annex: :b} =
             QuickBEAM.VM.Runtime.String.proto_property_meta("substr")
  end

  test "runtime builtin declarations expose audited ECMA sections" do
    assert %QuickBEAM.VM.Builtin.Meta{ecma: "24.1.3.6"} =
             QuickBEAM.VM.Runtime.Map.proto_property_meta("get")

    assert %QuickBEAM.VM.Builtin.PropertySpec{ecma: "24.2.3.2"} =
             QuickBEAM.VM.Runtime.Set.static_property_spec({:symbol, "Symbol.species"})

    assert %QuickBEAM.VM.Builtin.Meta{ecma: "24.2.4.16"} =
             QuickBEAM.VM.Runtime.Set.proto_property_meta("union")

    assert %QuickBEAM.VM.Builtin.Meta{ecma: "27.2.4.1"} =
             QuickBEAM.VM.Runtime.Promise.static_property_meta("all")

    assert %QuickBEAM.VM.Builtin.FunctionSpec{ecma: "22.2.6.8"} =
             QuickBEAM.VM.Runtime.RegExp.proto_property_spec({:symbol, "Symbol.match"})

    assert %QuickBEAM.VM.Builtin.FunctionSpec{ecma: "23.2.3.22"} =
             QuickBEAM.VM.Runtime.TypedArray.proto_property_spec("map")

    assert %QuickBEAM.VM.Builtin.FunctionSpec{ecma: "25.3.4.10"} =
             QuickBEAM.VM.Runtime.DataView.proto_property_spec("getInt8")

    assert %QuickBEAM.VM.Builtin.Meta{ecma: nil} =
             QuickBEAM.VM.Runtime.Map.proto_property_meta("getOrInsert")

    assert %QuickBEAM.VM.Builtin.Meta{ecma: nil} =
             QuickBEAM.VM.Runtime.Iterator.static_property_meta("concat")

    raw_json = QuickBEAM.VM.Runtime.JSON.object() |> elem(2) |> Map.fetch!("rawJSON")
    assert %QuickBEAM.VM.Builtin.Meta{ecma: nil} = QuickBEAM.VM.Builtin.metadata_for(raw_json)
  end

  test "object DSL supports declarative parents and symbol data" do
    parent = QuickBEAM.VM.Heap.wrap(%{"kind" => "parent"})

    {:obj, ref} =
      QuickBEAM.VM.BuiltinDSLTest.Sample.object_with_parent(parent)

    obj = QuickBEAM.VM.Heap.get_obj(ref)
    assert obj["__proto__"] == parent
    assert obj[{:symbol, "Symbol.toStringTag"}] == "Sample Iterator"
    assert {:builtin, "next", _} = obj["next"]

    assert QuickBEAM.VM.Heap.get_prop_desc(ref, "next") ==
             QuickBEAM.VM.ObjectModel.PropertyDescriptor.method()

    assert QuickBEAM.VM.Heap.get_prop_desc(ref, {:symbol, "Symbol.toStringTag"}) ==
             QuickBEAM.VM.ObjectModel.PropertyDescriptor.hidden_readonly()
  end

  test "builtin object metadata installs descriptors and tags" do
    object_proto = QuickBEAM.VM.Heap.wrap(%{})
    QuickBEAM.VM.Heap.put_object_prototype(object_proto)

    math = QuickBEAM.VM.Runtime.Math.object()
    QuickBEAM.VM.Runtime.Math.install_metadata(math)

    abs = QuickBEAM.VM.Heap.get_ctor_statics(math)["abs"]

    assert QuickBEAM.VM.Heap.get_ctor_statics(abs)["length"] == 1

    assert QuickBEAM.VM.Heap.get_ctor_prop_desc(abs, "length") == %{
             configurable: true,
             enumerable: false,
             writable: false
           }

    assert QuickBEAM.VM.Heap.get_ctor_statics(math)[{:symbol, "Symbol.toStringTag"}] == "Math"

    assert QuickBEAM.VM.Heap.get_ctor_prop_desc(math, "PI") == %{
             configurable: false,
             enumerable: false,
             writable: false
           }

    assert {:obj, _} = QuickBEAM.VM.Heap.get_ctor_statics(math)["__proto__"]
  end
end
