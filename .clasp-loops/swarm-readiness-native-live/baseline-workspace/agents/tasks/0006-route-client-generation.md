# 0006 Route Client Generation

## Goal

Generate typed JavaScript client helpers from route declarations.

## Scope

- Derive a small client surface from existing route metadata
- Keep request and response codec validation at the boundary
- Add a demo path showing server and generated client sharing the same route definition
- Add tests

## Acceptance

- `bash scripts/verify-all.sh` passes

## Notes

Do not add a large framework. Extend the existing route/runtime surface narrowly.
