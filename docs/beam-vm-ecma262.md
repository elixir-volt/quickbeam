# BEAM VM and ECMA-262 Mapping

QuickBEAM has two execution engines:

- the native QuickJS-NG engine, accessed through NIFs;
- a BEAM VM mode that executes decoded QuickJS bytecode with Elixir modules.

This document maps the BEAM VM to ECMA-262 terminology. It is a contributor guide, not a claim that every spec abstraction is represented by a dedicated runtime struct.

## What QuickBEAM delegates to QuickJS

The BEAM VM does **not** implement ECMA-262 grammar productions directly. QuickJS-NG parses ECMAScript source and emits QuickJS bytecode. The BEAM VM decodes and executes that bytecode.

Delegated to QuickJS:

- lexical and syntactic grammar;
- parsing scripts/functions/classes/modules;
- many early errors;
- source-to-bytecode compilation;
- bytecode instruction selection.

Owned by the BEAM VM:

- VM value representation;
- object model and internal-method behavior;
- property access, definition, deletion, and enumeration;
- function call/construct dispatch;
- global bindings and runtime context state required by bytecode execution;
- promises, reactions, and microtask draining;
- standard built-ins and host API glue used in BEAM mode.

## Clause mapping

| ECMA-262 area | QuickBEAM modules |
|---|---|
| §6 Values and specification types | `QuickBEAM.VM.Value`, `QuickBEAM.VM.Heap`, `ObjectModel.PropertyDescriptor` |
| §7.1 Type Conversion | `Semantics.Coercion`, `ObjectModel.PropertyKey` |
| §7.2 Testing and comparison | `Semantics.Equality`, `Semantics.Comparison`, `ObjectModel.Semantics` |
| §7.3 Operations on objects | `ObjectModel.*`, `Invocation` |
| §7.4 Iterator operations | `Semantics.Iterators`, `Runtime.Iterator` |
| §9 Execution contexts / environments | `Interpreter.Context`, `GlobalEnvironment`, `EvalEnv`, `Environment.Captures` |
| §9.5 Jobs | `Promise`, heap async state |
| §10 Object internal methods | `ObjectModel.Get`, `Put`, `Define`, `Delete`, `OwnProperty`, `HasProperty`, `ArrayExotic`, `Prototype` |
| §18–28 Standard built-ins | `Runtime.Object`, `Function`, `Array`, `String`, `Number`, `Date`, `RegExp`, `Map`, `Set`, `TypedArray`, `Promise`, `Reflect`, etc. |
| Host APIs | `Host.Web.*`, `Host.Test262`, BEAM/native integration helpers |

## Spec terminology glossary

| Spec term | QuickBEAM representation |
|---|---|
| `undefined` | `:undefined` |
| `null` | `nil` |
| Object identity | `{:obj, heap_ref}` |
| Built-in function object | `{:builtin, name, callback}` |
| ECMAScript function object | `%QuickBEAM.VM.Function{}` or closure tuple |
| Bound function exotic object | `{:bound, ...}` |
| Completion Record | raw return value or `throw({:js_throw, value})` |
| Reference Record | bytecode local/global/property operations plus helpers |
| Realm Record | global bindings, intrinsic caches, globalThis, Test262 realm helpers |
| Job Queue | promise/microtask state in `Promise` and heap async state |
| Internal slots | heap maps and keys from `QuickBEAM.VM.Heap.Keys` |

## Internal slot storage

| ECMA internal slot | QuickBEAM representation |
|---|---|
| `[[Prototype]]` | `"__proto__"` and heap prototype helpers |
| `[[Extensible]]` | heap non-extensible side table |
| `[[PromiseState]]` | `promise_state()` heap key; Promise reactions are scheduled through `QuickBEAM.VM.JobQueue` |
| `[[PromiseResult]]` | `promise_value()` heap key |
| `[[ViewedArrayBuffer]]` | typed-array buffer keys in heap object maps |
| `[[ArrayLength]]` | array storage plus length descriptor/side-table behavior |
| RegExp internal matcher state | regexp tuple plus `Execution.RegexpState` side table |

## Boundary rule

Opcode modules are bytecode-oriented. Shared semantic modules are spec-oriented. Host APIs are outside ECMA-262.

When a bytecode operation needs observable ECMAScript behavior, it should call the shared semantic/object-model/invocation/runtime layer rather than duplicating builtin-specific or object-model logic in opcode handlers.
