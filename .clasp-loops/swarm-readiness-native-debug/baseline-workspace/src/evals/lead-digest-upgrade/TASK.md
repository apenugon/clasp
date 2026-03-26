# Task

The lead follow-up slice needs a contract upgrade.

Make the following product change:

1. Rename `LeadSummary` to `LeadDigest`.
2. Replace the old digest fields with this exact schema:
   - `company : Str`
   - `priorityLabel : Str`
   - `owner : Str`
   - `needsFollowUp : Bool`
3. Update `LeadPlaybookLookup` so it no longer uses `status`.
   It should now use:
   - `owner : Str`
   - `needsFollowUp : Bool`
4. Update the workflow state so it stores a `digest : LeadDigest`.
5. Update the route so `summarizeLeadApi` returns `LeadDigest`.
6. Keep the program compiling.
7. Keep `main` working. After the change, `main` should evaluate to `"senior-ae"`.

The validator will check that the upgrade propagated through:

- shared schemas
- route metadata
- tool metadata
- workflow metadata
- context graph output
- the compiled module's `main`
