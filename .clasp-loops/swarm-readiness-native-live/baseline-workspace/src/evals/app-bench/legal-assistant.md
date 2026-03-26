# App-Bench Target: Legal Assistant

Source row:

- `src/evals/app-bench/vendor/app-bench/AppBench vExternal.csv`

Dataset description:

> A web application that answers legal questions using retrieval-augmented generation over an updatable document knowledge base, with full authentication, file uploads, web search integration, and an AI chat interface.

Why this is the best first App-Bench target for Clasp:

- It stresses typed boundaries across auth, uploads, document indexing, retrieval, web search, chat, and citation-bearing responses.
- It has clear policy and security requirements around sensitive uploaded documents.
- It depends on explicit context plumbing, especially `@` document references, which is exactly the kind of seam Clasp should make compiler-known.
- It is easier to isolate into a meaningful first slice than the more realtime-heavy dashboard, pharmacy, or drawing tasks.

## Prompt Features That Matter Most

The upstream task asks for:

- registration, login, logout
- durable storage for accounts, documents, and chat logs
- file upload and replacement
- Chroma-backed vector storage and retrieval
- AI chat with retrieval-augmented generation
- web search integration
- voice dictation and transcription
- `@`-referencing of documents as high-priority context
- explicit citation or reference to mentioned documents

## First Slice We Should Actually Optimize

Do not start with the entire App-Bench rubric.

Start with one narrow but representative slice:

- authenticated upload of legal documents
- durable metadata storage
- indexing trigger into retrieval storage
- chat query route
- explicit `@document` reference parsing
- retrieval plus web-search tool orchestration
- response payload that carries cited document references

If Clasp cannot show clear agent leverage on that slice, it is unlikely to show it on the full app.

## What We Should Try To Make Compiler-Known

For a Clasp-native version of this task, the differentiating surfaces should be:

- `record` schemas for users, documents, citations, chat turns, retrieval results, and indexed document references
- `route` boundaries for auth, uploads, conversations, retrieval, and search-backed answering
- `tool` boundaries for web search, embedding/indexing, retrieval, and transcription
- `workflow` state for ingestion, indexing, answer generation, and conversation persistence
- policy and capability boundaries for sensitive legal documents and provider access

## Why This Should Produce Real Signal

This app is not mainly a frontend contest. It is a seam-management contest:

- uploads become retrieval assets
- chat requests depend on auth, storage, retrieval, and search
- `@` references alter retrieval behavior
- responses should preserve citation obligations
- sensitive data handling matters

That is the category where "compiler-owned mechanics" has a plausible chance to beat prompt-only reasoning.
