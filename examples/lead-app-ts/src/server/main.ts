import {
  decodeLeadIntakeForm,
  decodeLeadReviewForm,
  decodeLeadSummary,
  renderInboxPage,
  renderLandingPage,
  renderLeadPage,
  type LeadIntake,
  type LeadReview,
  type LeadSummary
} from "../shared/lead.js";
import { serveRoutes, type PageRoute } from "./runtime.js";
import { createLeadStore, type LeadStore } from "./store.js";

export interface LeadBindings {
  mockLeadSummaryModel(lead: LeadIntake): string;
}

function summarizeLead(bindings: LeadBindings, intake: LeadIntake): LeadSummary {
  return decodeLeadSummary(bindings.mockLeadSummaryModel(intake));
}

export function createRoutes(
  bindings: LeadBindings,
  store: LeadStore
): PageRoute<unknown>[] {
  return [
    {
      method: "GET",
      path: "/",
      decodeRequest: async () => undefined,
      handler: async () => renderLandingPage(store.loadInbox())
    },
    {
      method: "GET",
      path: "/inbox",
      decodeRequest: async () => undefined,
      handler: async () => renderInboxPage(store.loadInbox())
    },
    {
      method: "GET",
      path: "/lead/primary",
      decodeRequest: async () => undefined,
      handler: async () => renderLeadPage(store.loadLead(0))
    },
    {
      method: "GET",
      path: "/lead/secondary",
      decodeRequest: async () => undefined,
      handler: async () => renderLeadPage(store.loadLead(1))
    },
    {
      method: "POST",
      path: "/leads",
      decodeRequest: async (request) =>
        decodeLeadIntakeForm(await request.text()),
      handler: async (intake) =>
        renderLeadPage(
          store.createLeadRecord(
            intake as LeadIntake,
            summarizeLead(bindings, intake as LeadIntake)
          )
        )
    },
    {
      method: "POST",
      path: "/review",
      decodeRequest: async (request) =>
        decodeLeadReviewForm(await request.text()),
      handler: async (review) =>
        renderLeadPage(store.reviewLead(review as LeadReview))
    }
  ];
}

export function createServer(
  bindings: LeadBindings,
  options: { databasePath?: string; port?: number } = {}
) {
  const store = createLeadStore(options.databasePath ?? "./lead-app.sqlite");
  const server = serveRoutes(createRoutes(bindings, store), options);
  const stop = server.stop.bind(server);

  return {
    ...server,
    stop(force?: boolean) {
      try {
        stop(force);
      } finally {
        store.close();
      }
    }
  };
}
