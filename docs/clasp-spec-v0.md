# Clasp Spec v0

## Purpose

This document defines the first concrete implementation target for `Clasp`.

The long-term goal is a strongly typed, schema-first, AI-native language that spans frontend, backend, mobile, workflows, and LLM/agent systems. The first compiler should not attempt all of that at once. It should establish a small, regular core and a clean implementation pipeline.

## Scope

Version `v0` is intentionally narrow.

It is also intentionally bootstrap-oriented. The current syntax is meant to get the compiler pipeline moving, not to freeze the final surface language.

It includes:

- A module header
- File-level imports
- Top-level type declarations
- Top-level record declarations
- Top-level foreign capability declarations
- Top-level route declarations
- Top-level declarations
- Declaration-level type signatures
- Nominal algebraic data types
- Nominal records used as the first schema-bearing product types
- Function definitions
- Basic literals
- Function application
- Field access
- JSON `decode` and `encode` boundary expressions
- Match expressions over constructors
- Compiler-known `Page` and `View` primitives for safe SSR-first HTML rendering
- Minimal name resolution and typechecking
- A typed core IR produced by checking
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
- Workflows
- Agent control-plane declarations such as repo memory, policies, commands, hooks, agents, verifier rules, and traces
- External-objective declarations such as goals, metrics, experiments, and rollout policies
- Compiler-emitted context graphs over declarations, capabilities, traces, and external-objective structure
- Rich LLM-specific syntax beyond foreign/runtime boundaries, including typed prompt functions and provider strategies

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

## Design Constraints

- The syntax should be small and regular.
- Whitespace should stay lightweight and unsurprising.
- The compiler pipeline should separate parsing, syntax, and code generation cleanly.
- JavaScript is the first output target because it gives immediate reach across browser, server, workers, and React Native.
- The bootstrap syntax should not be mistaken for the final token-optimized source form.

## Source File Shape

Every `Clasp` source file in `v0` has:

1. A required module declaration
2. Zero or more file-level imports
3. Zero or more top-level type, record, foreign, or route declarations
4. One or more top-level declarations

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
module      ::= "module" module-name import* top-level+
module-name ::= segment ("." segment)*
segment     ::= upper-ident
import      ::= "import" module-name

top-level   ::= type-decl | record-decl | foreign-decl | route-decl | signature | decl
type-decl   ::= "type" upper-ident "=" constructor ("|" constructor)*
constructor ::= upper-ident type-atom*
record-decl ::= "record" upper-ident "=" "{" record-field-decl ("," record-field-decl)* "}"
record-field-decl ::= lower-ident ":" type
foreign-decl ::= "foreign" lower-ident ":" type "=" string
route-decl  ::= "route" lower-ident "=" method string upper-ident "->" upper-ident lower-ident
method      ::= "GET" | "POST"
signature   ::= lower-ident ":" type
decl        ::= lower-ident lower-ident* "=" expr
expr        ::= term term*
term        ::= atom ("." lower-ident)*
atom        ::= lower-ident
              | upper-ident
              | integer
              | string
              | "true"
              | "false"
              | decode-expr
              | encode-expr
              | record-expr
              | match-expr
              | "(" expr ")"
decode-expr ::= "decode" type-atom expr
encode-expr ::= "encode" expr
record-expr ::= upper-ident "{" record-field-expr ("," record-field-expr)* "}"
record-field-expr ::= lower-ident "=" expr
match-expr  ::= "match" expr "{" match-branch ("," match-branch)* "}"
match-branch ::= pattern "->" expr
pattern     ::= upper-ident lower-ident*
type        ::= type-atom ("->" type-atom)*
type-atom   ::= "Int" | "Str" | "Bool" | upper-ident | "(" type ")"
```

Notes:

- Function application is left-associative.
- Field access binds tighter than function application.
- Operators are intentionally absent in `v0`.
- Declarations are expression-bodied only.
- Constructor names and type names are currently uppercase; value names are lowercase.

## Semantics

- A declaration with no parameters becomes a JavaScript `const`.
- A declaration with parameters becomes a JavaScript `function`.
- A nullary constructor becomes an exported tagged JavaScript object.
- A constructor with fields becomes an exported JavaScript function returning a tagged object.
- A record literal becomes a plain JavaScript object literal.
- Record field access becomes JavaScript property access.
- `decode` validates and decodes JSON text into a primitive or record type.
- `encode` serializes a primitive or record value into JSON text.
- Foreign declarations bind typed runtime capabilities through a host-provided runtime object.
- Route declarations emit typed route metadata with generated request decoders and response encoders.
- Function application compiles to JavaScript function calls.
- Match expressions compile to a JavaScript `switch` over constructor tags.
- Boolean, integer, string, and variable references map directly to JavaScript equivalents.
- Declarations may omit type signatures when local inference can resolve all parameter and result types.
- Ambiguous declarations still require explicit signatures.
- The current import loader resolves `Foo.Bar` to `Foo/Bar.clasp` relative to the entry module and flattens imported declarations into one checked module.
- Records are currently restricted to primitive and nested-record fields so generated JSON codecs stay valid.
- Foreign declarations are currently restricted to function capabilities.
- Routes currently require record request and response types.
- Routes may also return compiler-known `Page` values, which emit inert HTML rather than JSON.
- `Page` and `View` are compiler-known types; the current safe view surface is `page`, `text`, `empty`, `append`, `element`, and `styled`.
- Safe views escape text content, reject raw `script`/`style` tags, and keep styling explicit through `styled` references instead of raw host `class` or `style` strings.
- The checker currently rejects duplicate declarations, duplicate parameters, duplicate record fields, duplicate route names/endpoints, unknown names, unknown types, annotation arity mismatches, ambiguous declarations, non-exhaustive matches, wrong constructors in match branches, duplicate match branches, missing record fields, unknown record fields, unsupported JSON boundary types, wrong route handler signatures, and simple type mismatches before code generation.

## Compiler Pipeline

The current compiler pipeline is:

```text
Source -> Parser -> AST -> Typed Core IR -> Lowered IR -> JavaScript Emitter
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
- Type parameters
- Richer pattern forms, including nested destructuring and wildcards
- Stronger Bun/runtime interop and eventually non-JS server runtimes
- Typed workflows, hot-swap checkpoints, and self-update compatibility rules
- Further diagnostic enrichment, including fix hints and normalization for agent-facing output
- A path toward compact canonical syntax with human-facing explain renderers
