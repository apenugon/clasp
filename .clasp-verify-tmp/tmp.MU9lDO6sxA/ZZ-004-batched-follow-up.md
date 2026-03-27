# ZZ-004 Batched follow up

## Goal

Wait for the full foundation batch to finish.

## Why

This task proves dependency labels wait for every task in the batch.

## Scope

- Wait for the foundation label

## Likely Files

- `src/batched-follow-up`

## Dependencies

- None

## Dependency Labels

- foundation

## Acceptance

- done

## Verification

```sh
bash scripts/verify-all.sh
```
