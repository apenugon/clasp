# Weft Spec v0

## Purpose

This document defines the first concrete implementation target for `Weft`.

The long-term goal is a strongly typed, schema-first, AI-native language that spans frontend, backend, mobile, workflows, and LLM/agent systems. The first compiler should not attempt all of that at once. It should establish a small, regular core and a clean implementation pipeline.

## Scope

Version `v0` is intentionally narrow.

It is also intentionally bootstrap-oriented. The current syntax is meant to get the compiler pipeline moving, not to freeze the final surface language.

It includes:

- A module header
- Top-level declarations
- Declaration-level type signatures
- Function definitions
- Basic literals
- Function application
- Minimal name resolution and typechecking
- Structured diagnostic codes
- JavaScript code generation

It does not yet include:

- Full type inference
- Pattern matching
- Records
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

The v0 compiler does not implement those features yet, but the project should be scoped assuming they are central rather than optional.

## Design Constraints

- The syntax should be small and regular.
- Whitespace should stay lightweight and unsurprising.
- The compiler pipeline should separate parsing, syntax, and code generation cleanly.
- JavaScript is the first output target because it gives immediate reach across browser, server, workers, and React Native.
- The bootstrap syntax should not be mistaken for the final token-optimized source form.

## Source File Shape

Every `Weft` source file in `v0` has:

1. A required module declaration
2. One or more top-level declarations

Example:

```weft
module Main

hello = "Hello from Weft"

id : Str -> Str
id v = v

main = id hello
```

This example is intentionally more readable than the eventual target surface may be. Later versions of `Weft` should be evaluated for whether some of this ceremony can be removed without harming agent success rates.

## Grammar

```text
module      ::= "module" module-name top-level*
module-name ::= segment ("." segment)*
segment     ::= upper-ident

top-level   ::= signature | decl
signature   ::= ident ":" type
decl        ::= ident ident* "=" expr
expr        ::= atom atom*
atom        ::= ident
              | integer
              | string
              | "true"
              | "false"
              | "(" expr ")"
type        ::= type-atom ("->" type-atom)*
type-atom   ::= "Int" | "Str" | "Bool" | "(" type ")"
```

Notes:

- Function application is left-associative.
- Operators are intentionally absent in `v0`.
- Declarations are expression-bodied only.

## Semantics

- A declaration with no parameters becomes a JavaScript `const`.
- A declaration with parameters becomes a JavaScript `function`.
- Function application compiles to JavaScript function calls.
- Boolean, integer, string, and variable references map directly to JavaScript equivalents.
- Functions currently require declaration-level type signatures.
- The checker currently rejects duplicate declarations, unknown names, annotation arity mismatches, and simple type mismatches before code generation.

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
- Records and algebraic data types
- Exhaustive pattern matching
- A schema definition form
- Further diagnostic enrichment, including fix hints and normalization for agent-facing output
- A path toward compact canonical syntax with human-facing explain renderers
