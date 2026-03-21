import { pathToFileURL } from "node:url";

import { createWorkerRuntime } from "../../deprecated/runtime/worker.mjs";
import { installCompiledModule } from "../../deprecated/runtime/server.mjs";
import { createLeadDemoBindings } from "./bindings.mjs";

export async function runLeadWorkflowDemo(compiledModule, options = {}) {
  installCompiledModule(compiledModule, createLeadDemoBindings(options.seedLeads));

  const createLeadRoute = findRoute(compiledModule, "createLeadRecordRoute");
  const reviewLeadRoute = findRoute(compiledModule, "reviewLeadRecordRoute");
  const created = await createLeadRoute.handler(
    createLeadRoute.decodeRequest(
      JSON.stringify({
        company: "SynthSpeak Workflow",
        contact: "Riley Chen",
        budget: 90000,
        segment: "enterprise"
      })
    )
  );
  const runtime = createWorkerRuntime(compiledModule);
  const workflow = runtime.workflow("LeadFollowUpFlow");
  const checkpoint = workflow.checkpoint({
    leadId: created.leadId,
    company: created.company,
    priority: created.priority,
    segment: created.segment,
    reviewStatus: created.reviewStatus,
    reviewNote: created.reviewNote,
    nextAction: "score-intake",
    touchCount: 0
  });
  const queued = workflow.start(checkpoint, {
    mailbox: [
      {
        id: "followup-1",
        payload: {
          type: "prepare-outreach"
        }
      }
    ]
  });
  const prepared = workflow.processNext(queued, reduceFollowUp, { now: 1000 });
  const reviewed = await reviewLeadRoute.handler(
    reviewLeadRoute.decodeRequest(
      JSON.stringify({
        leadId: created.leadId,
        note: "Schedule executive discovery"
      })
    )
  );
  const completed = workflow.deliver(
    prepared.run,
    {
      id: "review-1",
      payload: {
        type: "review-complete",
        reviewStatus: reviewed.reviewStatus,
        reviewNote: reviewed.reviewNote
      }
    },
    reduceFollowUp,
    { now: 1001 }
  );

  return {
    workflowCount: runtime.contract.module.compatibility.workflowCount,
    workflowName: workflow.name,
    checkpointLeadId: workflow.resume(checkpoint).leadId,
    createdLeadId: created.leadId,
    createdPriority: normalizeTag(created.priority),
    preparedStatus: prepared.status,
    preparedResult: prepared.delivery?.result ?? null,
    reviewedStatus: normalizeTag(reviewed.reviewStatus),
    finalNextAction: completed.run.state.nextAction,
    finalTouchCount: completed.run.state.touchCount,
    finalReviewNote: completed.run.state.reviewNote,
    remainingMailboxSize: completed.run.mailbox.length
  };
}

function findRoute(compiledModule, name) {
  const route = compiledModule.__claspRoutes?.find(
    (candidate) => candidate.name === name
  );

  if (!route) {
    throw new Error(`Missing route ${name}`);
  }

  return route;
}

function reduceFollowUp(state, payload) {
  if (payload?.type === "prepare-outreach") {
    return {
      state: {
        ...state,
        nextAction:
          normalizeTag(state.priority) === "High"
            ? "schedule-discovery"
            : "send-nurture",
        touchCount: state.touchCount + 1
      },
      result: "schedule-discovery"
    };
  }

  if (payload?.type === "review-complete") {
    return {
      state: {
        ...state,
        reviewStatus: payload.reviewStatus,
        reviewNote: payload.reviewNote,
        nextAction: "await-reply",
        touchCount: state.touchCount + 1
      },
      result: "await-reply"
    };
  }

  return {
    state,
    result: "ignored"
  };
}

function normalizeTag(value) {
  return value?.$tag ?? value;
}

async function runCli() {
  const compiledPath = process.argv[2] ?? "./Main.js";
  const compiledUrl = new URL(compiledPath, pathToFileURL(`${process.cwd()}/`));
  const compiledModule = await import(compiledUrl.href);
  const summary = await runLeadWorkflowDemo(compiledModule);
  console.log(JSON.stringify(summary));
}

if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) {
  await runCli();
}
