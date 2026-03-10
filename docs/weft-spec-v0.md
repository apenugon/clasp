# Weft Spec v0

## Purpose

This document defines the first concrete implementation target for `Weft`.

The long-term goal is a strongly typed, schema-first, AI-native language that spans frontend, backend, mobile, workflows, and LLM/agent systems. The first compiler should not attempt all of that at once. It should establish a small, regular core and a clean implementation pipeline.

## Scope

Version `v0` is intentionally narrow.

It is also intentionally bootstrap-oriented. The current syntax is meant to get the compiler pipeline moving, not to freeze the final surface language.

It includes:

- A module header
- Top-level type declarations
- Top-level declarations
- Declaration-level type signatures
- Nominal algebraic data types
- Function definitions
- Basic literals
- Function application
- Match expressions over constructors
- Minimal name resolution and typechecking
- Exhaustiveness checking for constructor matches
- Structured diagnostic codes
- JavaScript code generation

It does not yet include:

- Full type inference
- Records
- Type parameters
- Nested patterns
- Effects
- Schemas
- Workflows
- LLM-specific syntax

Those features remain part of the language direction, but they should be layered onto a stable front-end rather than mixed into the first parser/emitter prototype.

The current `module Main`-style surface should be treated as provisional. Future iterations may remove or compress syntax that adds little semantic value, especially when that information can be derived from file path, package metadata, or type information.

## Long-Term Static Semantics Direction

`Weft` should eventually provide:

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

Every `Weft` source file in `v0` has:

1. A required module declaration
2. Zero or more top-level type declarations
3. One or more top-level declarations

Example:

```weft
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

This example is intentionally more readable than the eventual target surface may be. Later versions of `Weft` should be evaluated for whether some of this ceremony can be removed without harming agent success rates.

## Grammar

```text
module      ::= "module" module-name top-level*
module-name ::= segment ("." segment)*
segment     ::= upper-ident

top-level   ::= type-decl | signature | decl
type-decl   ::= "type" upper-ident "=" constructor ("|" constructor)*
constructor ::= upper-ident type-atom*
signature   ::= lower-ident ":" type
decl        ::= lower-ident lower-ident* "=" expr
expr        ::= atom atom*
atom        ::= lower-ident
              | upper-ident
              | integer
              | string
              | "true"
              | "false"
              | match-expr
              | "(" expr ")"
match-expr  ::= "match" expr "{" match-branch ("," match-branch)* "}"
match-branch ::= pattern "->" expr
pattern     ::= upper-ident lower-ident*
type        ::= type-atom ("->" type-atom)*
type-atom   ::= "Int" | "Str" | "Bool" | upper-ident | "(" type ")"
```

Notes:

- Function application is left-associative.
- Operators are intentionally absent in `v0`.
- Declarations are expression-bodied only.
- Constructor names and type names are currently uppercase; value names are lowercase.

## Semantics

- A declaration with no parameters becomes a JavaScript `const`.
- A declaration with parameters becomes a JavaScript `function`.
- A nullary constructor becomes an exported tagged JavaScript object.
- A constructor with fields becomes an exported JavaScript function returning a tagged object.
- Function application compiles to JavaScript function calls.
- Match expressions compile to a JavaScript `switch` over constructor tags.
- Boolean, integer, string, and variable references map directly to JavaScript equivalents.
- Functions currently require declaration-level type signatures.
- The checker currently rejects duplicate declarations, unknown names, unknown types, annotation arity mismatches, non-exhaustive matches, wrong constructors in match branches, duplicate match branches, and simple type mismatches before code generation.

## Compiler Pipeline

The initial compiler pipeline is:

```text
Source -> Parser -> AST -> JavaScript Emitter
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

- Richer local inference so fewer declarations require explicit annotations
- Records and type parameters
- Richer pattern forms, including nested destructuring and wildcards
- A schema definition form
- Further diagnostic enrichment, including fix hints and normalization for agent-facing output
- A path toward compact canonical syntax with human-facing explain renderers
