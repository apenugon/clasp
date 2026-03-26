The repository models one small Clasp authoring microbenchmark.

Add explicit lead priority across the source surface.

Requirements:
- Introduce `type Priority = Low | Medium | High`.
- Add `priority : Priority` to the `Lead` record.
- Set `defaultLead.priority = High`.
- Add `priorityLabel`.
- Update `leadSummary` so it returns `<company> [<priority>]`, for example `SynthSpeak [high]`.

Constraints:
- Keep the change inside the app-owned source surface.
- Do not edit benchmark harness files unless verification proves the task is impossible without a harness fix.

Verification:

```sh
bash scripts/verify.sh
```
