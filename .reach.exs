host_boundary_callers = [
  "QuickBEAM.VM.Host.*",
  "QuickBEAM.VM.Execution.EventLoop",
  "QuickBEAM.VM.Runtime.Globals.Builder"
]

builtin_installers = [
  "QuickBEAM.VM.Realm",
  "QuickBEAM.VM.Builtin.Discovery",
  "QuickBEAM.VM.Runtime.Errors"
]

class_proto_writers = [
  "QuickBEAM.VM.ObjectModel.Class",
  "QuickBEAM.VM.Realm",
  "QuickBEAM.VM.Runtime.ConstructorProperties",
  "QuickBEAM.VM.Runtime.ConstructorRegistry"
]

process_state_owners = [
  "QuickBEAM.VM.Heap",
  "QuickBEAM.VM.Heap.*",
  "QuickBEAM.VM.RuntimeState",
  "QuickBEAM.VM.Invocation.Context",
  "QuickBEAM.VM.Host.BeamAPI.State",
  "QuickBEAM.VM.Host.Web.BroadcastChannel.State",
  "QuickBEAM.VM.Host.Web.ConsoleAPI.State",
  "QuickBEAM.VM.Host.Web.EventSourceAPI.State",
  "QuickBEAM.VM.Host.Web.Worker.State",
  "QuickBEAM.VM.Execution.ConstructorStack",
  "QuickBEAM.VM.Execution.DefinitionState",
  "QuickBEAM.VM.Execution.GlobalBindingState",
  "QuickBEAM.VM.Execution.IteratorState",
  "QuickBEAM.VM.Execution.JSONState",
  "QuickBEAM.VM.Execution.PrimitivePrototypeState",
  "QuickBEAM.VM.Execution.PrototypeState",
  "QuickBEAM.VM.Execution.RealmState",
  "QuickBEAM.VM.Execution.RegexpState",
  "QuickBEAM.VM.Execution.SetterState",
  "QuickBEAM.VM.Execution.Trace"
]

[
  calls: [
    forbidden: [
      {"QuickBEAM.VM.*", ["QuickBEAM.VM.Host.*"], except: host_boundary_callers},
      {"QuickBEAM.VM.*", ["QuickBEAM.VM.Host.Test262.*"], except: ["QuickBEAM.VM.Host.*"]},
      {"QuickBEAM.VM.*", ["QuickBEAM.VM.Heap.get_ctx", "QuickBEAM.VM.Heap.put_ctx"],
       except: ["QuickBEAM.VM.RuntimeState"]},
      {"QuickBEAM.VM.*", ["QuickBEAM.VM.Heap.put_class_proto"], except: class_proto_writers},
      {"QuickBEAM.VM.*", ["Process.get", "Process.put", "Process.delete"],
       except: process_state_owners},
      {"QuickBEAM.VM.*", ["QuickBEAM.VM.Builtin.Installer.install"], except: builtin_installers},
      {"QuickBEAM.VM.*", ["QuickBEAM.VM.Builtin.named_meta"], except: ["QuickBEAM.VM.Builtin"]},
      {"QuickBEAM.VM.ObjectModel.*", ["QuickBEAM.VM.Compiler.*"]},
      {"QuickBEAM.VM.ObjectModel.*", ["QuickBEAM.VM.Interpreter.*"]},
      {"QuickBEAM.VM.ObjectModel.*", ["QuickBEAM.VM.Runtime.Globals.*"]},
      {"QuickBEAM.VM.Semantics.*", ["QuickBEAM.VM.Compiler.*", "QuickBEAM.VM.Interpreter.*"]},
      {"QuickBEAM.VM.Compiler.*", ["QuickBEAM.VM.Host.*"]},
      {"QuickBEAM.VM.Interpreter.*", ["QuickBEAM.VM.Host.Test262.*"]},
      {"QuickBEAM.VM.Runtime.*", ["QuickBEAM.VM.Compiler.*"]},
      {"QuickBEAM.VM.Runtime.*", ["QuickBEAM.VM.Interpreter.*"]},
      {"QuickBEAM.VM.Runtime.Globals.Registry", ["QuickBEAM.VM.Host.*"]}
    ]
  ],
  boundaries: [
    public: [
      "QuickBEAM.VM.Builtin",
      "QuickBEAM.VM.Builtin.Definition",
      "QuickBEAM.VM.Builtin.Installer",
      "QuickBEAM.VM.Builtin.Discovery",
      "QuickBEAM.VM.Realm",
      "QuickBEAM.VM.RuntimeState",
      "QuickBEAM.VM.Value",
      "QuickBEAM.VM.Heap.Keys",
      "QuickBEAM.VM.ObjectModel.PropertyKey",
      "QuickBEAM.VM.ObjectModel.Semantics",
      "QuickBEAM.VM.Runtime.Collections"
    ],
    internal: [
      "QuickBEAM.VM.Host.Test262",
      "QuickBEAM.VM.Execution.JSONState",
      "QuickBEAM.VM.Execution.RealmState",
      "QuickBEAM.VM.Execution.GlobalBindingState",
      "QuickBEAM.VM.Execution.EventLoop",
      "QuickBEAM.VM.Execution.Eval",
      "QuickBEAM.VM.Execution.ClosureCells",
      "QuickBEAM.VM.Runtime.Construction",
      "QuickBEAM.VM.Runtime.ConstructorProperties",
      "QuickBEAM.VM.Interpreter.Ops.ObjectLiterals",
      "QuickBEAM.VM.Interpreter.Ops.Delete",
      "QuickBEAM.VM.ObjectModel.ProxyTrap",
      "QuickBEAM.VM.Interpreter.Ops.PropertyKeys",
      "QuickBEAM.VM.Host.BeamAPI.State",
      "QuickBEAM.VM.Host.Web.BroadcastChannel.State",
      "QuickBEAM.VM.Host.Web.ConsoleAPI.State",
      "QuickBEAM.VM.Host.Web.EventSourceAPI.State",
      "QuickBEAM.VM.Host.Web.Worker.State",
      "QuickBEAM.VM.Host.Web.Streams.State",
      "QuickBEAM.VM.Host.Web.FormData.State",
      "QuickBEAM.VM.Host.Web.MessageChannel.State"
    ],
    internal_callers: [
      {"QuickBEAM.VM.Host.Test262", ["QuickBEAM.VM.Host.*"]},
      {"QuickBEAM.VM.Execution.JSONState", ["QuickBEAM.VM.Runtime.JSON"]},
      {"QuickBEAM.VM.Execution.RealmState", ["QuickBEAM.VM.Realm"]},
      {"QuickBEAM.VM.Execution.GlobalBindingState", ["QuickBEAM.VM.GlobalEnvironment"]},
      {"QuickBEAM.VM.Execution.EventLoop", ["QuickBEAM.VM.Interpreter"]},
      {"QuickBEAM.VM.Execution.Eval",
       ["QuickBEAM.VM.Runtime.Globals.Functions", "QuickBEAM.VM.Runtime.ConstructorCallbacks"]},
      {"QuickBEAM.VM.Execution.ClosureCells", ["QuickBEAM.VM.ObjectModel.*"]},
      {"QuickBEAM.VM.Runtime.Construction", ["QuickBEAM.VM.Runtime"]},
      {"QuickBEAM.VM.Runtime.ConstructorProperties", ["QuickBEAM.VM.ObjectModel.Get"]},
      {"QuickBEAM.VM.Interpreter.Ops.Delete", ["QuickBEAM.VM.Interpreter.Ops.Objects"]},
      {"QuickBEAM.VM.ObjectModel.ProxyTrap",
       ["QuickBEAM.VM.ObjectModel.*", "QuickBEAM.VM.Runtime.Object"]},
      {"QuickBEAM.VM.Interpreter.Ops.ObjectLiterals", ["QuickBEAM.VM.Interpreter.Ops.Objects"]},
      {"QuickBEAM.VM.Interpreter.Ops.PropertyKeys", ["QuickBEAM.VM.Interpreter.Ops.Objects"]},
      {"QuickBEAM.VM.Host.BeamAPI.State", ["QuickBEAM.VM.Host.BeamAPI"]},
      {"QuickBEAM.VM.Host.Web.BroadcastChannel.State",
       ["QuickBEAM.VM.Host.Web.BroadcastChannel"]},
      {"QuickBEAM.VM.Host.Web.ConsoleAPI.State", ["QuickBEAM.VM.Host.Web.ConsoleAPI"]},
      {"QuickBEAM.VM.Host.Web.EventSourceAPI.State", ["QuickBEAM.VM.Host.Web.EventSourceAPI"]},
      {"QuickBEAM.VM.Host.Web.Worker.State", ["QuickBEAM.VM.Host.Web.Worker"]},
      {"QuickBEAM.VM.Host.Web.Streams.State", ["QuickBEAM.VM.Host.Web.Streams"]},
      {"QuickBEAM.VM.Host.Web.FormData.State", ["QuickBEAM.VM.Host.Web.FormData"]},
      {"QuickBEAM.VM.Host.Web.MessageChannel.State", ["QuickBEAM.VM.Host.Web.MessageChannel"]}
    ]
  ],
  tests: [
    hints: [
      {"lib/quickbeam/vm/builtin/**", ["test/vm/realm_test.exs", "test/vm/runtime"]},
      {"lib/quickbeam/vm/realm.ex", ["test/vm/realm_test.exs", "test/vm/host/test262_test.exs"]},
      {"lib/quickbeam/vm/runtime/**", ["test/vm/runtime", "test/vm/realm_test.exs"]},
      {"lib/quickbeam/vm/object_model/**",
       ["test/vm/object_*_test.exs", "test/vm/reflect_define_callable_test.exs"]},
      {"lib/quickbeam/vm/runtime_state.ex", ["test/vm", "test/core/context_snapshot_test.exs"]}
    ]
  ]
]
