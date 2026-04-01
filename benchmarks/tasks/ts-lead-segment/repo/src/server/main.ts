import {
  createSeedLeads,
  createStoredLeadRecord,
  decodeLeadIntakeForm,
  decodeLeadReviewForm,
  decodeLeadSummary,
  loadInboxSnapshot,
  requireLead,
  renderInboxPage,
  renderLandingPage,
  renderLeadPage,
  type LeadIntake,
  type LeadRecord,
  type LeadReview,
  reviewLeadRecord,
  type LeadSummary
} from "../shared/lead.js";
import { serveRoutes, type PageRoute } from "./runtime.js";

export interface LeadBindings {
  mockLeadSummaryModel(lead: LeadIntake): string;
}

function summarizeLead(bindings: LeadBindings, intake: LeadIntake): LeadSummary {
  return decodeLeadSummary(bindings.mockLeadSummaryModel(intake));
}

export function createRoutes(
  bindings: LeadBindings,
  leads: LeadRecord[] = createSeedLeads()
): PageRoute<unknown>[] {
  return [
    {
      method: "GET",
      path: "/",
      decodeRequest: async () => undefined,
      handler: async () => renderLandingPage(loadInboxSnapshot(leads))
    },
    {
      method: "GET",
      path: "/inbox",
      decodeRequest: async () => undefined,
      handler: async () => renderInboxPage(loadInboxSnapshot(leads))
    },
    {
      method: "GET",
      path: "/lead/primary",
      decodeRequest: async () => undefined,
      handler: async () => renderLeadPage(requireLead(leads, 0))
    },
    {
      method: "GET",
      path: "/lead/secondary",
      decodeRequest: async () => undefined,
      handler: async () => renderLeadPage(requireLead(leads, 1))
    },
    {
      method: "POST",
      path: "/leads",
      decodeRequest: async (request) =>
        decodeLeadIntakeForm(await request.text()),
      handler: async (intake) =>
        renderLeadPage(
          createStoredLeadRecord(
            leads,
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
        renderLeadPage(reviewLeadRecord(leads, review as LeadReview))
    }
  ];
}

export function createServer(
  bindings: LeadBindings,
  options: { port?: number } = {}
) {
  return serveRoutes(createRoutes(bindings), options);
}
