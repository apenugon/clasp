# Clasp Agent Ergonomics Notes

## What Feels Better Than TS/Python

Clasp is already good at the control-plane part of agent systems. For a goal manager or other control-plane program with explicit state transitions, typed records, JSON decode/encode, process handling, and durable status files, it feels more disciplined than Python and less glue-heavy than TypeScript.

Positive points:

- State-machine code is readable and mechanically checkable.
- Native compilation is a good fit for long-lived autonomous loops.
- The runtime shape is coherent: service supervision, task state, benchmark checkpoints, planner reports, and verifier feedback feel like one system.
- The language pushes explicit contracts, which is a real advantage for swarms because postmortem reconstruction matters.

If the target is "language for agent infrastructure," Clasp is pointed in the right direction.

## What Still Makes Iteration Slow

The main issue is not expressiveness. It is the feedback loop.

The biggest friction points so far:

- Large native compiles are still too slow for swarm-manager work.
- Startup and config ergonomics are rough. A lot of behavior is threaded through JSON-encoded env vars.
- Debugging is too artifact-driven. Understanding failures still means reading status files, feedback files, planner artifacts, heartbeat files, and supervisor logs.
- Failure surfacing is not sharp enough yet. Planner hangs, detached launch failures, and planner-manager budget mismatches should be obvious sooner and in one place.
- The system still leaks too much operational complexity to the user. If the promise is "the swarm just runs," the runtime needs better built-in handling for retries, replans, respawns, and waiting-state explanation.

So the practical pain is: too much time spent understanding runtime behavior relative to time spent changing runtime behavior.

## What I Would Change First

1. Faster iteration primitives.

- Much faster incremental compile and check for large manager programs.
- Cheap logic-only rebuilds for orchestration-heavy code.
- Stronger compile caching for common manager and example paths.

2. First-class runtime introspection.

- A built-in "why am I waiting?" view for manager, planner, and task states.
- A live event stream over current artifact spelunking.
- Clear distinctions between running, hung, retrying, replanning, blocked-by-budget, and waiting-for-benchmark.

3. Stronger static and preflight validation.

- Catch budget mismatches like "planner can emit 3 tasks, manager only allows 2" before the run starts.
- Catch impossible scheduling and resource configurations early.
- Push more swarm invariants out of runtime failure and into compile-time or launch-time validation.

4. Better typed configuration surface.

- Fewer JSON env vars.
- More typed config modules, launch manifests, or generated CLI surfaces.
- One canonical launch path for manager, service, and benchmark modes.

5. Better long-running service ergonomics.

- Native hot-swap and restart story that is normal, not special-case.
- Supervisor behavior that is inspectable and predictable from the language level.
- Built-in bounded cache and data-retention policies so autonomous loops do not accumulate garbage unless explicitly told to.

## Condensed Judgment

Clasp already feels directionally better than general-purpose scripting languages for agent control planes.

It does not yet feel better for day-to-day iteration.

The next 20 percent should go into compile speed, observability, and static launch validation, not more expressive power. Those are the changes most likely to make Clasp genuinely pleasant for building swarms.
