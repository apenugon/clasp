# Clasp Spec v0

## Purpose

This document defines the first concrete implementation target for `Clasp`.

The long-term goal is a strongly typed, schema-first, AI-native language that spans frontend, backend, mobile, workflows, and LLM/agent systems. The first compiler should not attempt all of that at once. It should establish a small, regular core and a clean implementation pipeline.

## Scope

Version `v0` is intentionally narrow.

It is also intentionally bootstrap-oriented. The current syntax is meant to get the compiler pipeline moving, not to freeze the final surface language.

It includes:

- An optional module header when module identity can be inferred from the file path
- File-level imports
- Top-level type declarations
- Top-level record declarations
- Top-level domain-object and domain-event declarations bound to record schemas
- Top-level metric, goal, experiment, and rollout declarations bound to typed domain declarations
- Top-level workflow declarations for isolated long-running processes with typed durable state
- Top-level foreign capability declarations
- Top-level hook declarations for lifecycle triggers
- Top-level agent-role and agent declarations for named subagents
- Top-level tool-server and tool declarations for typed external tool contracts
- Top-level verifier-rule and merge-gate declarations for checked verification workflows
- Top-level route declarations
- Top-level declarations
- Declaration-level type signatures
- Nominal algebraic data types
- Nominal records used as the first schema-bearing product types
- Function definitions
- Basic literals
- Function application
- Block expressions
- Local `let` expressions
- Early `return` expressions inside function bodies
- Block-scoped `for` loops over list and string values
- Equality operators for `Int`, `Str`, and `Bool`
- Integer comparison operators for branching
- Field access
- JSON `decode` and `encode` boundary expressions
- Match expressions over constructors
- Compiler-known `Page` and `View` primitives for safe SSR-first HTML rendering
- Compiler-known `Prompt` primitives and typed prompt-building functions for AI-facing prompt composition
- Generated JavaScript page modules that export static-asset, head, and shared style-bundle metadata for compiler-known page/view output
- Compiler-known `AuthSession`, `Principal`, `Tenant`, `ResourceIdentity`, `AuditActor`, `AuditAction`, `AuditProvenance`, and `StandardAuditEnvelope` primitives for shared identity and audit metadata
- Compiler-known self-hosting stdlib helpers for text joining/splitting, path shaping, and file-loading host calls
- Minimal name resolution and typechecking
- A typed core IR produced by checking
- A stable AIR graph with compiler-known node identity and JSON serialization for tooling/replay
- A lowered backend IR between checking and emission
- Local inference for declarations whose types are constrained enough by usage
- Exhaustiveness checking for constructor matches
- Structured diagnostic codes
- JavaScript code generation

It does not yet include:

- Full module-wide polymorphic inference
- Type parameters
- Nested patterns
- Effects
- Dedicated schema syntax separate from records
- Agent control-plane declarations such as repo memory, policies, commands, hooks, agents, verifier rules, and traces
- External-objective declarations beyond the current domain, metric, goal, experiment, and rollout slices
- Compiler-emitted context graphs over declarations, capabilities, traces, and external-objective structure
- Rich LLM-specific syntax beyond foreign/runtime boundaries, including provider strategies

Those features remain part of the language direction, but they should be layered onto a stable front-end rather than mixed into the first parser/emitter prototype.

The current `module Main`-style surface should be treated as provisional. Future iterations may remove or compress syntax that adds little semantic value, especially when that information can be derived from file path, package metadata, or type information.

## Long-Term Static Semantics Direction

`Clasp` should eventually provide:

- algebraic data types
- exhaustive pattern matching
- strong local type inference
- explicit results for failure and absence
- informative compiler diagnostics that connect errors back to the shared type and schema model

The v0 compiler now implements a first slice of those features through nominal sum types and constructor-based match expressions, but the design should still assume a broader static-semantics story later.

`Option` is compiler-known in `v0` as a bootstrap absence model equivalent to `type Option = Some Str | None`. Modules may use `Option`, `Some`, and `None` without declaring the type locally.

`Result` is also compiler-known in `v0` as a bootstrap failure model equivalent to `type Result = Ok Str | Err Str`. Modules may use `Result`, `Ok`, and `Err` without declaring the type locally.

The self-hosting slice also reserves a small compiler-known stdlib surface:

- `textConcat : [Str] -> Str`
- `textJoin : Str -> [Str] -> Str`
- `textSplit : Str -> Str -> [Str]`
- `textChars : Str -> [Str]`
- `pathJoin : [Str] -> Str`
- `pathDirname : Str -> Str`
- `pathBasename : Str -> Str`
- `fileExists : Str -> Bool`
- `readFile : Str -> Result`
- `sqliteOpen : Str -> SqliteConnection`
- `sqliteOpenReadonly : Str -> SqliteConnection`

The text and path helpers are emitted with default JavaScript behavior. The file helpers remain host/runtime bindings so compiler code can read from the surrounding environment without baking filesystem access into every target runtime. The SQLite helpers also stay host/runtime-backed. Bun hosts expose typed connection descriptors through `sqliteOpen` and `sqliteOpenReadonly`, typed query bindings can opt into `sqlite:queryOne` and `sqlite:queryAll` runtime names so declared return schemas validate and map query rows at the host boundary, typed mutation bindings can opt into `sqlite:mutateOne[:isolation]` and `sqlite:mutateAll[:isolation]` so semantic input and output schemas stay intact across transaction boundaries, explicit SQL escape hatches must use `foreign unsafe` plus `sqlite:unsafeQueryOne`, `sqlite:unsafeQueryAll`, `sqlite:unsafeMutateOne[:isolation]`, or `sqlite:unsafeMutateAll[:isolation]` so generated sqlite contracts keep row-contract and audit metadata attached to those bindings, `storage:*` host bindings must use named schema-bearing types instead of bare primitives, generated binding contracts derive storage table metadata and database constraints from those schemas, and `createSqliteRuntime` can now enforce app-level schema version compatibility, run host-supplied migrations when SQLite-backed apps open a database, and expose typed transaction descriptors with nested savepoint boundaries.

## Design Constraints

- The syntax should be small and regular.
- Whitespace should stay lightweight and unsurprising.
- The compiler pipeline should separate parsing, syntax, and code generation cleanly.
- JavaScript is the first output target because it gives immediate reach across browser, server, workers, and React Native.
- The bootstrap syntax should not be mistaken for the final token-optimized source form.

## Source File Shape

Every `Clasp` source file in `v0` has:

1. An optional module declaration
2. Zero or more imports, either attached to the module declaration through `with` or written as separate `import` lines
3. Zero or more top-level type, record, domain object, domain event, metric, goal, experiment, rollout, workflow, supervisor, guide, hook, role, agent, toolserver, tool, verifier, mergegate, foreign, or route declarations
4. One or more top-level declarations

When the module declaration is omitted, the compiler infers the module name from the project-relative file path. For example, `Main.clasp` infers `Main`, and `Shared/User.clasp` infers `Shared.User`.

When a module declaration is present, it may attach imports directly in the header:

```clasp
module Main with Shared.User, Shared.Team
```

Workflows declare a named durable state model with a record-backed `state` field. They can also attach optional `invariant`, `precondition`, and `postcondition` handlers, each typed as `State -> Bool`, so generated runtimes can enforce state-schema checks at checkpoint, resume, start, delivery, replay, and upgrade boundaries:

```clasp
module Main

record Counter = { value : Int }

nonNegative : Counter -> Bool
nonNegative counter = counter.value >= 0

workflow CounterFlow = {
  state : Counter,
  invariant : nonNegative
}
```

Domain declarations can bind business-facing objects and signals to typed record schemas:

```clasp
module Main

record CustomerRecord = { customerId : Str, tier : Str }
record CustomerChurnEvent = { customerId : Str, reason : Str }
record CustomerEscalationFeedback = { customerId : Str, severity : Str }
record CustomerMetric = { customerId : Str, churnRate : Int }

domain object Customer = CustomerRecord
domain event CustomerChurned = CustomerChurnEvent for Customer
feedback operational CustomerEscalation = CustomerEscalationFeedback for Customer
metric CustomerChurnRate = CustomerMetric for Customer
goal RetainCustomers = CustomerChurnRate
experiment RetentionPromptTrial = RetainCustomers
rollout RetentionPromptCanary = RetentionPromptTrial
```

Supervisor declarations define BEAM-style restart strategy metadata over workflow or nested supervisor children:

```clasp
supervisor RootSupervisor = one_for_all {
  workflow CounterFlow,
  supervisor WorkerSupervisor
}
```

Example:

```clasp
module Main

type Status = Idle | Busy Str

describe : Status -> Str
describe status = match status {
  Idle -> "idle",
  Busy note -> note
}

main : Str
main = describe (Busy "loading")
```

This example is intentionally more readable than the eventual target surface may be. Later versions of `Clasp` should be evaluated for whether some of this ceremony can be removed without harming agent success rates.

An unannotated function can now typecheck when the body constrains it enough:

```clasp
module Main

type Status = Idle | Busy Str

makeBusy note = Busy note

describe status = match status {
  Idle -> "idle",
  Busy note -> note
}

main : Str
main = describe (makeBusy "loading")
```

Type declarations, record schemas, and annotated functions may also introduce type parameters:

```clasp
module Main

type Option a = Some a | None

record Box a = { value : a }

unwrapOr : Option a -> a -> a
unwrapOr value fallback = match value {
  Some present -> present,
  None -> fallback
}
```

Local bindings are also available inside expressions:

```clasp
module Main

greeting : Str
greeting = let message = "Ada" in message
```

Block expressions are also available as a lightweight imperative-adjacent surface form. A block evaluates to its final expression, and it may introduce local variables with leading `let` declarations. Reassignment is supported only for locals declared with `let mut`:

```clasp
module Main

greeting : Str
greeting = {
  let mut message = "Ada";
  message = "Grace";
  message
}
```

Blocks may also include `for` loops over list and string values. The loop binder is scoped to the loop body, the body result is ignored, and outer `let mut` locals can be updated from inside the loop. String iteration yields one-character `Str` values:

```clasp
module Main

pickLast : [Str] -> Str
pickLast names = {
  let mut current = "nobody";
  for name in names {
    current = name;
    current
  };
  current
}
```

```clasp
module Main

pickLastChar : Str -> Str
pickLastChar name = {
  let mut current = "";
  for char in name {
    current = char;
    current
  };
  current
}
```

Function bodies may also use `return` to exit early from nested expressions such as blocks or match branches:

```clasp
module Main

type Decision = Exit | Continue

choose : Decision -> Str -> Str
choose decision name = match decision {
  Exit -> return name,
  Continue -> "fallback"
}
```

Primitive equality is also available for `Int`, `Str`, and `Bool`:

```clasp
module Main

sameNumber : Int -> Int -> Bool
sameNumber left right = left == right

differentFlag : Bool -> Bool -> Bool
differentFlag left right = left != right
```

Comparison binds tighter than equality, so `1 < 2 == 3 > 2` parses as `(1 < 2) == (3 > 2)`. Equality also remains restricted to concrete `Int`, `Str`, and `Bool` operands rather than unconstrained inferred values.

Integer comparisons are currently available for `Int` values:

```clasp
module Main

isEarlier : Int -> Int -> Bool
isEarlier left right = left < right

isLatest : Int -> Int -> Bool
isLatest left right = left >= right
```

Records and field access are also part of the current `v0` surface:

```clasp
module Main

record User = {
  name : Str,
  active : Bool
}

defaultUser = User {
  name = "Ada",
  active = true
}

showName user = user.name

main : Str
main = showName defaultUser
```

List types use square brackets around any type expression:

```clasp
module Main

record UserDirectory = {
  names : [Str],
  scoreBuckets : [[Int]]
}

type BatchResult = Batch [UserDirectory]
```

List literals use the same brackets and must stay homogeneous. Empty lists need surrounding type information from an annotation or another checked context:

```clasp
module Main

roster : [Str]
roster = ["Ada", "Grace"]

emptyRoster : [Str]
emptyRoster = []
```

The first backend-boundary slice is also part of `v0`:

```clasp
module Main

record LeadRequest = {
  company : Str,
  budget : Int
}

record LeadSummary = {
  summary : Str,
  priority : Str,
  followUpRequired : Bool
}

foreign mockLeadSummaryModel : LeadRequest -> Str = "mockLeadSummaryModel"

summarizeLead : LeadRequest -> LeadSummary
summarizeLead lead = decode LeadSummary (mockLeadSummaryModel lead)

route summarizeLeadRoute = POST "/lead/summary" LeadRequest -> LeadSummary summarizeLead
```

## Grammar

```text
module      ::= module-header? import* top-level+
module-header ::= "module" module-name ("with" module-name ("," module-name)*)?
module-name ::= segment ("." segment)*
segment     ::= upper-ident
import      ::= "import" module-name

top-level   ::= type-decl | record-decl | guide-decl | hook-decl | role-decl | agent-decl | policy-decl | toolserver-decl | tool-decl | verifier-decl | mergegate-decl | projection-decl | foreign-decl | route-decl | signature | decl
type-decl   ::= "type" upper-ident lower-ident* "=" constructor ("|" constructor)*
constructor ::= upper-ident constructor-field*
constructor-field ::= type-base | "(" type ")"
record-decl ::= "record" upper-ident lower-ident* "=" "{" record-field-decl ("," record-field-decl)* "}"
record-field-decl ::= lower-ident ":" type ("classified" lower-ident)?
guide-decl ::= "guide" upper-ident ("extends" upper-ident)? "=" "{" guide-entry-decl ("," guide-entry-decl)* "}"
guide-entry-decl ::= lower-ident ":" string
hook-decl ::= "hook" lower-ident "=" string upper-ident "->" upper-ident lower-ident
role-decl ::= "role" upper-ident "=" "guide" ":" upper-ident "," "policy" ":" upper-ident
agent-decl ::= "agent" lower-ident "=" upper-ident
policy-decl ::= "policy" upper-ident "=" lower-ident ("," lower-ident)* ("permits" "{" policy-permission-decl ("," policy-permission-decl)* "}")?
policy-permission-decl ::= ("file" | "network" | "process" | "secret") string
toolserver-decl ::= "toolserver" upper-ident "=" string string "with" upper-ident
tool-decl ::= "tool" lower-ident "=" upper-ident string upper-ident "->" upper-ident
verifier-decl ::= "verifier" lower-ident "=" lower-ident
mergegate-decl ::= "mergegate" lower-ident "=" lower-ident ("," lower-ident)*
projection-decl ::= "projection" upper-ident "=" upper-ident "with" upper-ident "{" lower-ident ("," lower-ident)* "}"
foreign-decl ::= "foreign" ["unsafe"] lower-ident ":" type "=" string foreign-package-import?
foreign-package-import ::= "from" ("npm" | "typescript") string "declaration" string
route-decl  ::= "route" lower-ident "=" method string upper-ident "->" upper-ident lower-ident
method      ::= "GET" | "POST"
signature   ::= lower-ident ":" type
decl        ::= lower-ident lower-ident* "=" expr
block-expr  ::= "{" block-let* expr "}"
block-let   ::= ("let" ["mut"] lower-ident "=" expr | lower-ident "=" expr | "for" lower-ident "in" for-iterable-expr block-expr) block-separator
block-separator ::= ";" | newline+
let-expr    ::= "let" lower-ident "=" expr "in" expr
expr        ::= let-expr | equality-expr
for-iterable-expr ::= let-expr | for-equality-expr
for-equality-expr ::= for-comparison-expr (("==" | "!=") for-comparison-expr)*
for-comparison-expr ::= for-app-expr (("<" | "<=" | ">" | ">=") for-app-expr)?
for-app-expr ::= for-term for-term*
for-term    ::= for-atom ("." lower-ident)*
for-atom    ::= lower-ident | upper-ident | integer | string | list-expr | "true" | "false" | decode-expr | encode-expr | return-expr | "(" expr ")"
equality-expr ::= comparison-expr (("==" | "!=") comparison-expr)*
comparison-expr ::= app-expr (("<" | "<=" | ">" | ">=") app-expr)?
app-expr    ::= term term*
term        ::= atom ("." lower-ident)*
atom        ::= lower-ident
              | upper-ident
              | integer
              | string
              | list-expr
              | "true"
              | "false"
              | decode-expr
              | encode-expr
              | return-expr
              | record-expr
              | match-expr
              | block-expr
              | "(" expr ")"
decode-expr ::= "decode" type-atom expr
encode-expr ::= "encode" expr
return-expr ::= "return" expr
record-expr ::= upper-ident "{" record-field-expr ("," record-field-expr)* "}"
list-expr   ::= "[" (expr ("," expr)*)? "]"
record-field-expr ::= lower-ident "=" expr
match-expr  ::= "match" expr "{" match-branch ("," match-branch)* "}"
match-branch ::= pattern "->" expr
pattern     ::= upper-ident lower-ident*
type        ::= type-atom ("->" type-atom)*
type-atom   ::= type-base type-base*
type-base   ::= "Int" | "Str" | "Bool" | upper-ident | lower-ident | "[" type "]" | "(" type ")"
```

Notes:

Package-backed foreign declarations are checked against the referenced declaration file when the package type is structurally known. Unchecked package leaves such as `any`, untyped parameters or returns, and opaque named package types require an explicit `foreign unsafe` marker, but that marker does not waive surrounding function, record, or list structure checks.

- Function application is left-associative.
- Field access binds tighter than function application.
- Operators are intentionally absent in `v0`.
- Declarations are expression-bodied only.
- Blocks return their final expression and may contain leading local `let` declarations, `for` loops over list or string values, or assignments to previously declared `let mut` locals.
- `return` is only valid inside function bodies and exits the enclosing function immediately.
- `let` binds as a full expression; use parentheses when passing a `let` as a function argument.
- Constructor names and type names are currently uppercase; value names are lowercase.

## Semantics

- A declaration with no parameters becomes a JavaScript `const`.
- A declaration with parameters becomes a JavaScript `function`.
- A nullary constructor becomes an exported tagged JavaScript object.
- A constructor with fields becomes an exported JavaScript function returning a tagged object.
- A record literal becomes a plain JavaScript object literal.
- A list literal becomes a JavaScript array, and every element in the literal must have the same type. Empty list literals must be checked against an expected list type.
- `if condition then left else right` requires a `Bool` condition and matching branch types.
- `append left right` is overloaded by the checker: list operands lower to array concatenation, while `View` operands keep the view-append surface.
- Record field access becomes JavaScript property access.
- Record fields may carry a classification label; unlabeled fields default to `public`.
- Policies list the field classifications a disclosure boundary may expose, and may also declare file, network, process, and secret permission grants for generated control-plane enforcement helpers.
- `Prompt` host values carry prompt-message content only; authority-bearing policy, permission, and tool-grant metadata must remain on declared control-plane surfaces instead of being embedded into prompt payloads.
- Projections derive boundary-facing record schemas from a source record plus a policy, and the checker rejects projected fields whose classifications are not allowed by that policy.
- `decode` validates and decodes JSON text into a primitive, record, or list type.
- `encode` serializes a primitive, record, or list value into JSON text.
- Foreign declarations bind typed runtime capabilities through a host-provided runtime object.
- Foreign declarations also emit structured host-binding manifests plus generated host-binding adapters so host code can register schema-shaped implementations without hand-written runtime glue.
- Foreign declarations also emit a versioned `__claspNativeInterop` manifest with generated binding-module references, capability identifiers, default `Rust` crate or native-library naming, and target-aware build descriptors for Bun, workers, and future mobile-native bridges.
- Foreign declarations may also bind compiler-managed `npm` or `TypeScript` package exports; entry compilation ingests the referenced `.d.ts` export signature, records it in the emitted manifest, and exposes generated package-backed host adapters through the same runtime surface.
- Hook declarations bind a lifecycle trigger string to typed request/response schemas and a checked handler function.
- Agent role declarations bind a reusable role to one guide and one policy declaration.
- Agent declarations bind a named agent identity to a checked role declaration.
- Tool-server declarations bind an external transport/location pair to one policy declaration.
- Tool declarations bind a typed request/response contract to one declared tool server and operation name.
- Tool declarations also emit typed JSON-RPC call contracts so hosts can validate and format tool requests and result envelopes from the same schema-owned boundary.
- Verifier declarations bind a named verification rule to one declared tool contract.
- Merge-gate declarations bind a named integration gate to one or more declared verifier rules.
- Generated JavaScript modules also export versioned control-plane manifests for guides, hooks, agents, policies, tool servers, tools, tool-call contracts, verifiers, and merge gates, plus executable protocol helpers for hook invocation and tool or verifier request shaping.
- Generated JavaScript modules also export compiler-owned `__claspAuditLogs` declarations with sink-routing metadata, retention rules, redaction policy, and `createRuntime` helpers so policy decisions, secret access, hook/tool/workflow events, and traceability records can be routed through one stable audit surface instead of ad hoc host logging.
- Generated JavaScript modules also export compiler-known `__claspSecretDeclarations` plus derived `__claspSecretInputs` and `__claspSecretBoundaries` registries so hosts can trace secret access back to declared policy grants and consuming agent-role or tool-server boundaries, map declarations onto environment-variable keys, and emit missing-secret diagnostics with the same provenance.
- Generated JavaScript modules also expose app-facing secret-consumer helpers on agent, route, tool, and workflow contracts plus reusable provider-binding adapters and `__claspSecretInjectors.environment(...)` / `provider(...)` factories, so hosts inject declared secret handles from environment variables or host secret providers instead of reaching into ambient process state.
- Resolved secret values are emitted as opaque runtime wrappers: implicit property reads, string coercion, serialization, inspection, and logging fail with provenance-carrying diagnostics, while explicit `reveal({ reason })` and `redact({ reason })` calls define the disclosure boundary.
- Secret consumers may delegate declared secret handles across agent, tool, and workflow handoffs, yielding audience-bound handoff metadata instead of raw secret values while preserving delegation-aware secret audit provenance including delegator identity, attenuation metadata, and the consuming boundary that resolved the handle.
- Generated JavaScript modules also export versioned human-readable control-plane docs derived from the same declarations and bundled into the stable `__claspBindings` surface, including declared policy permission grants.
- Generated JavaScript modules also export `__claspModule`, a module-level durable workflow contract with a derived version identifier, bounded upgrade-window metadata, and per-workflow compatibility descriptors for checkpoint replay and supervised hot-swap planning.
- The Bun worker runtime also exposes a supervised `hotSwap` protocol that stages one bounded old/new module overlap, validates module and workflow compatibility against `__claspModule`, supports operator handoff and draining before authority switches, health-gates upgrade activation, keeps explicit rollback paths and trigger metadata live while the old version remains active, and now latches a kill-switch path that can force rollback, mark the workflow run as operator-controlled, and disable further swap operations on that protocol instance.
- The Bun worker runtime also exposes `parallel(...)`, a runtime-managed scheduler that executes isolated workflow or generic process units with per-unit ordering and pluggable executors, so hosts can scale mailbox, supervision, and hot-upgrade execution from concurrency-only delivery to multicore-backed scheduling without changing the programming model.
- Route declarations emit typed route metadata with generated request decoders and response encoders.
- Route declarations also emit generated route-client manifests with typed request preparation and response parsing helpers derived from the same schemas.
- Generated JavaScript modules also export a versioned `__claspBindings` contract that collects host bindings, native interop metadata, routes, route clients, tool-call contracts, schema contracts, mobile bridge descriptors, seeded fixtures, assets, head strategy, and page-flow metadata behind one stable Bun-facing surface.
- The Bun runtime also exposes a browser/client helper layer for generated route clients, plus server helpers that consume the generated binding contract for host-binding installation, asset serving, request decoding, and redirect-aware response handling.
- The React runtime helper also exposes `createReactNativeBridge` and `createExpoBridge`, which turn compiler-owned `Page` and `View` values into stable mobile-friendly models without forcing React Native or Expo-specific rendering decisions into generated code.
- Generated JavaScript modules also export `__claspSchemas`, a schema-contract registry with shared schema references, seed values, and host/JSON adapters that Bun worker runtimes can use to register typed jobs without re-declaring boundary shapes.
- Generated JavaScript modules also export compiler-owned binary schema codecs plus `__claspBoundaryTransports`, so the same schema registry can drive framed binary service, worker, tool, workflow-checkpoint, and agent-to-agent transport without handwritten adapters.
- The Bun worker simulation runtime also exposes `worldSnapshot(...)` plus per-dry-run snapshot capture so replay and simulation outputs can carry the seeded fixtures, storage slices, environment or deployment state, provider responses, and simulated time they depended on.
- Generated JavaScript modules also export `__claspPythonInterop`, a versioned Python boundary contract that maps hook and JSON route schemas into compiler-managed worker and service descriptors, and the Bun runtime exposes lifecycle-managed Python module or package adapters that reuse the same schema registry for typed stdio interop.
- Route declarations also emit compiler-owned `__claspSeededFixtures` entries so hosts can inspect stable request and response seed shapes for benchmark and dogfood surfaces.
- Function application compiles to JavaScript function calls.
- Block-scoped `for` loops compile to JavaScript `for...of` loops over checked list or string values.
- Match expressions compile to a JavaScript `switch` over constructor tags.
- Boolean, integer, string, and variable references map directly to JavaScript equivalents.
- Declarations may omit type signatures when local inference can resolve all parameter and result types.
- Ambiguous declarations still require explicit signatures.
- The current import loader resolves `Foo.Bar` to `Foo/Bar.clasp` relative to the entry module and flattens imported declarations into one checked module.
- Records are currently restricted to primitive and nested-record fields so generated JSON codecs stay valid.
- Foreign declarations are currently restricted to function capabilities.
- Hooks currently require record request and response types.
- Routes currently require record request and response types.
- Routes may also return compiler-known `Page` values, which emit stable default SSR HTML rather than JSON.
- `Page` and `View` are compiler-known types; the current safe view surface is `page`, `text`, `empty`, `append`, `element`, and `styled`, with `append` remaining valid for view composition even though the same surface now also concatenates lists.
- Generated JavaScript page modules also export `__claspStyleIR`, a compiler-owned style contract with stable style refs, default design tokens, baseline variants, per-target lowering for web and native runtimes, and explicit raw host styling escape-hatch metadata.
- Page-flow machine metadata is emitted through generated sidecar exports such as `__claspUiGraph`, `__claspNavigationGraph`, and `__claspActionGraph`; HTML flow attributes are available only through the opt-in `__claspRenderPage(value, __claspPageRenderModes.htmlWithFlowMetadata)` projection.
- `AuthSession`, `Principal`, `Tenant`, `ResourceIdentity`, `AuditActor`, `AuditAction`, `AuditProvenance`, `StandardAuditEnvelope`, and `SqliteConnection` are compiler-known record-shaped types. The current constructor surface is `authSession`, `principal`, `tenant`, `resourceIdentity`, `auditActor`, `auditAction`, `auditProvenance`, and `auditEnvelope`; `SqliteConnection` values currently come from `sqliteOpen` and `sqliteOpenReadonly`.
- Safe views escape text content, reject raw `script`/`style` tags, keep styling explicit through `styled` references instead of raw host `class` or `style` strings, and record `hostClass` or `hostStyle` only as explicit escape-hatch metadata outside the safe default renderer.
- The checker currently rejects duplicate declarations, duplicate parameters, duplicate record fields, duplicate hook names, duplicate agent-role names, duplicate agent names, duplicate verifier and merge-gate names, duplicate route names/endpoints, unknown names, unknown types, unknown guide/policy references in roles, unknown role references in agents, unknown tool references in verifiers, unknown verifier references in merge gates, annotation arity mismatches, ambiguous declarations, non-exhaustive matches, wrong constructors in match branches, duplicate match branches, missing record fields, unknown record fields, unsupported JSON boundary types, wrong hook or route handler signatures, and simple type mismatches before code generation.
- AIR JSON is emitted as `clasp-air-v1`, with stable node IDs, explicit `ref` edges, root node IDs, and a module-level node count so tools can replay declaration, policy, projection, route, and expression graphs without reconstructing them from raw files.
- The CLI can persist that graph directly with `claspc air <input.clasp> [-o output.air.json]`.
- `claspc native` currently writes an inspectable `.native.ir` artifact and, on the bootstrap-native path, a companion `.native.image.json` artifact that carries generated export entrypoint symbols, a native compatibility fingerprint, and explicit migration metadata including workflow snapshot and handoff symbols so the Rust runtime can activate compatible module generations, require declared typed state snapshots plus state-handoff hooks for type-surface upgrades, resolve those symbols, bind native entrypoints, dispatch the newest live generation, and retire older generations without reparsing debug text.

## Compiler Pipeline

The current compiler pipeline is:

```text
Source -> Parser -> AST -> Typed Core IR -> AIR Graph -> Lowered IR -> JavaScript Emitter
```

The intended expanded pipeline is:

```text
Source -> CST -> AST -> Resolved AST -> Typed Core IR -> Lowered IR -> Target Emitter
```

The current scaffold should be written so later phases can add name resolution, typechecking, schema derivation, and effects without forcing a rewrite.

The intended backend path is:

- JavaScript as the first emitter
- a target-independent lowered representation under the typechecker
- future server/native emitters, potentially including an LLVM-oriented backend, once the type system and runtime model are stable

In other words, JavaScript is the first practical target, not the final architectural ceiling.

## Immediate Next Features

Once `v0` is stable, the next additions should be:

- More complete inference, especially around higher-order code and future generic types
- Dedicated schema syntax once records no longer need to carry the entire boundary story alone
- Multi-file namespace control beyond the current flattened import model
- Richer pattern forms, including nested destructuring and wildcards
- Stronger Bun/runtime interop and eventually non-JS server runtimes
- Typed workflows, hot-swap checkpoints, and self-update compatibility rules
- Further diagnostic normalization for agent-facing output
- A path toward compact canonical syntax with human-facing explain renderers
