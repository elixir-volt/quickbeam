defmodule QuickBEAM.VM.BuiltinDSLTest do
  use ExUnit.Case, async: true

  defmodule StructuredSample do
    use QuickBEAM.VM.Builtin

    @ecma "99.1"
    defintrinsic "StructuredSample" do
      constructor length: 1 do
        {args, this}
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
    static "legacy", length: 0 do
      :ok
    end

    @ecma "20.1.3.6"
    proto "toString", length: 0 do
      "[object Sample]"
    end

    static "withoutEcma", length: 0 do
      :ok
    end

    def inline_methods do
      build_methods do
        @ecma "20.1.3.6"
        method "toString", length: 0 do
          "[object Sample]"
        end

        @ecma "B.3.1"
        @annex :b
        method "legacy", length: 0 do
          :ok
        end
      end
    end
  end

  test "defintrinsic and contextual method blocks expose first-class specs" do
    definition = StructuredSample.builtin_definition()
    assert %QuickBEAM.VM.Builtin.Definition{ecma: "99.1", length: 1} = definition
    assert definition.constructor.([:value], :receiver) == {[:value], :receiver}

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
             Sample.static_property_meta("legacy")
  end

  test "@ecma annotates the next prototype builtin metadata" do
    assert %QuickBEAM.VM.Builtin.Meta{ecma: "20.1.3.6"} =
             Sample.proto_property_meta("toString")
  end

  test "@ecma annotates inline method metadata" do
    method = Sample.inline_methods()["toString"]

    assert %QuickBEAM.VM.Builtin.Meta{ecma: "20.1.3.6", length: 0} =
             QuickBEAM.VM.Builtin.metadata_for(method)

    legacy = Sample.inline_methods()["legacy"]

    assert %QuickBEAM.VM.Builtin.Meta{ecma: "B.3.1", annex: :b} =
             QuickBEAM.VM.Builtin.metadata_for(legacy)
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

  test "installer helpers preserve prototype ECMA metadata" do
    ctor = {:builtin, "String", fn _args, this -> this end}
    proto = QuickBEAM.VM.Heap.wrap(%{})
    QuickBEAM.VM.Runtime.ConstructorRegistry.put_prototype(ctor, proto)

    QuickBEAM.VM.Runtime.String.install_builtin(ctor)

    {:obj, ref} = proto
    method = QuickBEAM.VM.Heap.get_obj(ref)["charAt"]
    iterator = QuickBEAM.VM.Heap.get_obj(ref)[{:symbol, "Symbol.iterator"}]

    assert %QuickBEAM.VM.Builtin.Definition{ecma: "22.1"} =
             QuickBEAM.VM.Runtime.String.builtin_definition()

    assert %QuickBEAM.VM.Builtin.Meta{ecma: "22.1.3.2"} =
             QuickBEAM.VM.Builtin.metadata_for(method)

    assert %QuickBEAM.VM.Builtin.Meta{ecma: "22.1.3.36"} =
             QuickBEAM.VM.Builtin.metadata_for(iterator)

    assert %QuickBEAM.VM.Builtin.Meta{ecma: "B.2.2.1", annex: :b} =
             QuickBEAM.VM.Runtime.String.proto_property_meta("substr")
  end
end
