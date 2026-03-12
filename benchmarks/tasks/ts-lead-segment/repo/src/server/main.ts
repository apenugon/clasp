import {
  decodeLeadIntakeForm,
  decodeLeadRecord,
  decodeLeadReviewForm,
  decodeLeadSummary,
  leadLabel,
  renderInboxPage,
  renderLandingPage,
  renderLeadPage,
  type InboxSnapshot,
  type LeadIntake,
  type LeadRecord,
  type LeadReview,
  type LeadSummary
} from "../shared/lead.js";
import { serveRoutes, type PageRoute } from "./runtime.js";

export interface LeadBindings {
  mockLeadSummaryModel(lead: LeadIntake): string;
}

function createSeedLeads(): LeadRecord[] {
  return [
    {
      leadId: "lead-2",
      company: "Northwind Studio",
      contact: "Morgan Lee",
      summary:
        "Northwind Studio is ready for a design-system migration this quarter.",
      priority: "medium",
      segment: "growth",
      followUpRequired: true,
      reviewStatus: "reviewed",
      reviewNote: "Confirmed budget window and asked for a migration timeline."
    },
    {
      leadId: "lead-1",
      company: "Acme Labs",
      contact: "Jordan Kim",
      summary:
        "Acme Labs is exploring an internal AI pilot for support operations.",
      priority: "high",
      segment: "enterprise",
      followUpRequired: true,
      reviewStatus: "new",
      reviewNote: ""
    }
  ];
}

function summarizeLead(bindings: LeadBindings, intake: LeadIntake): LeadSummary {
  return decodeLeadSummary(bindings.mockLeadSummaryModel(intake));
}

function createLeadRecord(
  bindings: LeadBindings,
  leads: LeadRecord[],
  intake: LeadIntake
): LeadRecord {
  const summary = summarizeLead(bindings, intake);
  const stored = decodeLeadRecord(
    JSON.stringify({
      leadId: `lead-${leads.length + 1}`,
      company: intake.company,
      contact: intake.contact,
      summary: summary.summary,
      priority: summary.priority,
      segment: summary.segment,
      followUpRequired: summary.followUpRequired,
      reviewStatus: "new",
      reviewNote: ""
    })
  );

  leads.unshift(stored);
  return stored;
}

function loadInbox(leads: LeadRecord[]): InboxSnapshot {
  return {
    headline: "Priority inbox",
    primaryLeadLabel: leadLabel(leads[0]),
    secondaryLeadLabel: leadLabel(leads[1] ?? leads[0])
  };
}

function requireLead(leads: LeadRecord[], index: number): LeadRecord {
  const lead = leads[index] ?? leads[0];
  if (!lead) {
    throw new Error("lead store is empty");
  }
  return lead;
}

function reviewLead(leads: LeadRecord[], review: LeadReview): LeadRecord {
  const lead = leads.find((candidate) => candidate.leadId === review.leadId);
  if (!lead) {
    throw new Error(`Unknown lead: ${review.leadId}`);
  }

  lead.reviewStatus = "reviewed";
  lead.reviewNote = review.note;
  return lead;
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
      handler: async () => renderLandingPage(loadInbox(leads))
    },
    {
      method: "GET",
      path: "/inbox",
      decodeRequest: async () => undefined,
      handler: async () => renderInboxPage(loadInbox(leads))
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
        renderLeadPage(createLeadRecord(bindings, leads, intake as LeadIntake))
    },
    {
      method: "POST",
      path: "/review",
      decodeRequest: async (request) =>
        decodeLeadReviewForm(await request.text()),
      handler: async (review) =>
        renderLeadPage(reviewLead(leads, review as LeadReview))
    }
  ];
}

export function createServer(
  bindings: LeadBindings,
  options: { port?: number } = {}
) {
  return serveRoutes(createRoutes(bindings), options);
}
