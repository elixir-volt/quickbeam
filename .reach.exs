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

process_state_owners = [
  "QuickBEAM.VM.Heap",
  "QuickBEAM.VM.Heap.*",
  "QuickBEAM.VM.RuntimeState",
  "QuickBEAM.VM.Execution.*",
  "QuickBEAM.VM.Invocation.Context",
  "QuickBEAM.VM.GlobalEnvironment",
  "QuickBEAM.VM.Host.*",
  "QuickBEAM.VM.Realm",
  "QuickBEAM.VM.ObjectModel.ArrayExotic",
  "QuickBEAM.VM.ObjectModel.Get",
  "QuickBEAM.VM.ObjectModel.Prototype",
  "QuickBEAM.VM.Runtime.Function",
  "QuickBEAM.VM.Runtime.JSON",
  "QuickBEAM.VM.Runtime.Map",
  "QuickBEAM.VM.Runtime.RegExp",
  "QuickBEAM.VM.Runtime.Set",
  "QuickBEAM.VM.Runtime.TypedArray"
]

interpreter_bridges = [
  "QuickBEAM.VM.ObjectModel.ArrayExotic",
  "QuickBEAM.VM.ObjectModel.Get",
  "QuickBEAM.VM.ObjectModel.Put",
  "QuickBEAM.VM.Runtime.Globals.Constructors",
  "QuickBEAM.VM.Runtime.Globals.Functions",
  "QuickBEAM.VM.Runtime.Reflect",
  "QuickBEAM.VM.Runtime.Set"
]

global_constructor_bridges = [
  "QuickBEAM.VM.ObjectModel.Get",
  "QuickBEAM.VM.ObjectModel.Prototype"
]

[
  calls: [
    forbidden: [
      {"QuickBEAM.VM.*", ["QuickBEAM.VM.Host.*"], except: host_boundary_callers},
      {"QuickBEAM.VM.*", ["QuickBEAM.VM.Host.Test262.*"], except: ["QuickBEAM.VM.Host.*"]},
      {"QuickBEAM.VM.*", ["QuickBEAM.VM.Heap.get_ctx", "QuickBEAM.VM.Heap.put_ctx"],
       except: ["QuickBEAM.VM.RuntimeState"]},
      {"QuickBEAM.VM.*", ["Process.get", "Process.put", "Process.delete"],
       except: process_state_owners},
      {"QuickBEAM.VM.*", ["QuickBEAM.VM.Builtin.Installer.install"], except: builtin_installers},
      {"QuickBEAM.VM.*", ["QuickBEAM.VM.Builtin.named_meta"], except: ["QuickBEAM.VM.Builtin"]},
      {"QuickBEAM.VM.ObjectModel.*", ["QuickBEAM.VM.Compiler.*"]},
      {"QuickBEAM.VM.ObjectModel.*", ["QuickBEAM.VM.Interpreter.*"], except: interpreter_bridges},
      {"QuickBEAM.VM.ObjectModel.*", ["QuickBEAM.VM.Runtime.Globals.*"],
       except: global_constructor_bridges},
      {"QuickBEAM.VM.Semantics.*", ["QuickBEAM.VM.Compiler.*", "QuickBEAM.VM.Interpreter.*"]},
      {"QuickBEAM.VM.Compiler.*", ["QuickBEAM.VM.Host.*"]},
      {"QuickBEAM.VM.Interpreter.*", ["QuickBEAM.VM.Host.Test262.*"]},
      {"QuickBEAM.VM.Runtime.*", ["QuickBEAM.VM.Compiler.*"]},
      {"QuickBEAM.VM.Runtime.*", ["QuickBEAM.VM.Interpreter.*"], except: interpreter_bridges},
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
      "QuickBEAM.VM.Host.Test262"
    ],
    internal_callers: [
      {"QuickBEAM.VM.Host.Test262", ["QuickBEAM.VM.Host.*"]}
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
