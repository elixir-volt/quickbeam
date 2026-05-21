[
  calls: [
    forbidden: [
      {"QuickBEAM.VM.*", ["QuickBEAM.VM.Host.Test262.*"], except: ["QuickBEAM.VM.Host.*"]},
      {"QuickBEAM.VM.*", ["QuickBEAM.VM.Heap.get_ctx", "QuickBEAM.VM.Heap.put_ctx"],
       except: ["QuickBEAM.VM.RuntimeState"]},
      {"QuickBEAM.VM.*", ["QuickBEAM.VM.Builtin.Installer.install"],
       except: [
         "QuickBEAM.VM.Realm",
         "QuickBEAM.VM.Builtin.Discovery",
         "QuickBEAM.VM.Runtime.Errors"
       ]},
      {"QuickBEAM.VM.*", ["QuickBEAM.VM.Builtin.named_meta"], except: ["QuickBEAM.VM.Builtin"]}
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
