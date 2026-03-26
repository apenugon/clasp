# Auth AIR Wave v0

This wave is the first focused implementation pass on stronger formal guarantees for agent-built applications.

It targets the smallest high-leverage slices needed to move `Clasp` toward:

- a compiler-known agent intermediate representation (`AIR`)
- first-class auth/session and principal or tenant identity primitives
- compiler-known authorization requirements with proof-carrying access
- field-level data classification and disclosure control

The goal is not to finish the entire long-range guarantee story in one wave. The goal is to land the first real semantic footholds so later policy, storage, and workflow work can build on them.

Lanes in this wave:

- `01-air-core`
- `02-auth-primitives`
- `03-auth-proofs`
- `04-data-classification`
