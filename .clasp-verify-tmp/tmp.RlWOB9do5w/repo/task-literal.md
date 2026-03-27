# PX-001 Prompt literal

## Goal

Keep shell markers literal: $(printf prompt-substitution) `${HOME}` `touch /tmp/prompt`.

## Why

Regression coverage should catch prompt interpolation bugs.

## Scope

- Preserve $(printf scope-substitution) and ${USER} literally

## Likely Files

- `scripts/clasp-builder.sh`

## Dependencies

- None

## Acceptance

- Preserve `$(printf acceptance-substitution)` and `${PATH}` in the prompt

## Verification

```sh
bash scripts/verify-all.sh
```
