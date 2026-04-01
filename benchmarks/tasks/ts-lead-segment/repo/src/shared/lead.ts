export type LeadPriority = "low" | "medium" | "high";
export type ReviewStatus = "new" | "reviewed";

export interface LeadIntake {
  company: string;
  contact: string;
  budget: number;
}

export interface LeadSummary {
  summary: string;
  priority: LeadPriority;
  followUpRequired: boolean;
}

export interface LeadRecord {
  leadId: string;
  company: string;
  contact: string;
  summary: string;
  priority: LeadPriority;
  followUpRequired: boolean;
  reviewStatus: ReviewStatus;
  reviewNote: string;
}

export interface InboxSnapshot {
  headline: string;
  primaryLeadLabel: string;
  secondaryLeadLabel: string;
}

export interface LeadReview {
  leadId: string;
  note: string;
}

type JsonRecord = Record<string, unknown>;

function isRecord(value: unknown): value is JsonRecord {
  return typeof value === "object" && value !== null;
}

function expectString(record: JsonRecord, field: string): string {
  const value = record[field];
  if (typeof value !== "string") {
    throw new Error(`${field} must be a string`);
  }
  return value;
}

function expectBoolean(record: JsonRecord, field: string): boolean {
  const value = record[field];
  if (typeof value !== "boolean") {
    throw new Error(`${field} must be a boolean`);
  }
  return value;
}

function expectInteger(record: JsonRecord, field: string): number {
  const value = record[field];
  if (typeof value !== "number" || !Number.isInteger(value)) {
    throw new Error(`${field} must be an integer`);
  }
  return value;
}

function expectPriority(record: JsonRecord, field: string): LeadPriority {
  const value = record[field];
  if (value === "low" || value === "medium" || value === "high") {
    return value;
  }
  throw new Error(`${field} must be one of: low, medium, high`);
}

function parseJson(text: string): unknown {
  try {
    return JSON.parse(text);
  } catch (error) {
    throw new Error(`invalid JSON: ${errorMessage(error)}`);
  }
}

function parseForm(text: string): JsonRecord {
  const params = new URLSearchParams(text);
  return Object.fromEntries(params.entries());
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

export function decodeLeadSummary(text: string): LeadSummary {
  const value = parseJson(text);
  if (!isRecord(value)) {
    throw new Error("LeadSummary must be an object");
  }

  return {
    summary: expectString(value, "summary"),
    priority: expectPriority(value, "priority"),
    followUpRequired: expectBoolean(value, "followUpRequired")
  };
}

export function decodeLeadIntakeForm(text: string): LeadIntake {
  const value = parseForm(text);
  const budgetText = expectString(value, "budget");
  const budget = Number(budgetText);

  if (!Number.isInteger(budget)) {
    throw new Error("budget must be an integer");
  }

  return {
    company: expectString(value, "company"),
    contact: expectString(value, "contact"),
    budget
  };
}

export function decodeLeadReviewForm(text: string): LeadReview {
  const value = parseForm(text);
  return {
    leadId: expectString(value, "leadId"),
    note: expectString(value, "note")
  };
}

export function decodeLeadRecord(text: string): LeadRecord {
  const value = parseJson(text);
  if (!isRecord(value)) {
    throw new Error("LeadRecord must be an object");
  }

  const reviewStatus = value.reviewStatus;
  if (reviewStatus !== "new" && reviewStatus !== "reviewed") {
    throw new Error("reviewStatus must be one of: new, reviewed");
  }

  return {
    leadId: expectString(value, "leadId"),
    company: expectString(value, "company"),
    contact: expectString(value, "contact"),
    summary: expectString(value, "summary"),
    priority: expectPriority(value, "priority"),
    followUpRequired: expectBoolean(value, "followUpRequired"),
    reviewStatus,
    reviewNote: expectString(value, "reviewNote")
  };
}

export function createSeedLeads(): LeadRecord[] {
  return [
    {
      leadId: "lead-2",
      company: "Northwind Studio",
      contact: "Morgan Lee",
      summary:
        "Northwind Studio is ready for a design-system migration this quarter.",
      priority: "medium",
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
      followUpRequired: true,
      reviewStatus: "new",
      reviewNote: ""
    }
  ];
}

export function createStoredLeadRecord(
  leads: LeadRecord[],
  intake: LeadIntake,
  summary: LeadSummary
): LeadRecord {
  const stored = decodeLeadRecord(
    JSON.stringify({
      leadId: `lead-${leads.length + 1}`,
      company: intake.company,
      contact: intake.contact,
      summary: summary.summary,
      priority: summary.priority,
      followUpRequired: summary.followUpRequired,
      reviewStatus: "new",
      reviewNote: ""
    })
  );

  leads.unshift(stored);
  return stored;
}

export function loadInboxSnapshot(leads: LeadRecord[]): InboxSnapshot {
  return {
    headline: "Priority inbox",
    primaryLeadLabel: leadLabel(leads[0]),
    secondaryLeadLabel: leadLabel(leads[1] ?? leads[0])
  };
}

export function requireLead(leads: LeadRecord[], index: number): LeadRecord {
  const lead = leads[index] ?? leads[0];
  if (!lead) {
    throw new Error("lead store is empty");
  }
  return lead;
}

export function reviewLeadRecord(
  leads: LeadRecord[],
  review: LeadReview
): LeadRecord {
  const lead = leads.find((candidate) => candidate.leadId === review.leadId);
  if (!lead) {
    throw new Error(`Unknown lead: ${review.leadId}`);
  }

  lead.reviewStatus = "reviewed";
  lead.reviewNote = review.note;
  return lead;
}

export function encodePage(title: string, body: string): string {
  return `<!DOCTYPE html><html><head><meta charset="utf-8"><title>${escapeHtml(title)}</title></head><body>${body}</body></html>`;
}

export function escapeHtml(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

export function renderLandingPage(inbox: InboxSnapshot): string {
  return encodePage(
    "Lead inbox",
    `<main data-app="lead-shell"><h1>Lead inbox</h1><p>Capture a lead, score it once, and review it on the server.</p><section><h2>New lead</h2><form method="POST" action="/leads"><label>Company<input name="company" type="text" value=""></label><label>Contact<input name="contact" type="text" value=""></label><label>Budget<input name="budget" type="number" value=""></label><button type="submit">Create lead</button></form></section><h2>${escapeHtml(inbox.headline)}</h2>${renderInboxLinks(inbox)}<p><a href="/inbox">Open the inbox page</a></p></main>`
  );
}

export function renderInboxPage(inbox: InboxSnapshot): string {
  return encodePage(
    "Inbox",
    `<main data-app="lead-shell"><h1>${escapeHtml(inbox.headline)}</h1><p>Open a seeded lead or create a new one from the intake page.</p>${renderInboxLinks(inbox)}<p><a href="/">Back to intake</a></p></main>`
  );
}

export function renderLeadPage(lead: LeadRecord): string {
  const reviewDetails =
    lead.reviewStatus === "reviewed"
      ? `<section><p>Review status: reviewed</p><p>${escapeHtml(lead.reviewNote)}</p></section>`
      : `<section><p>Review status: new</p><p>Add an internal note before handing this lead off.</p></section>`;

  return encodePage(
    lead.company,
    `<main data-app="lead-shell"><h1>${escapeHtml(lead.company)}</h1><p>${escapeHtml(lead.contact)}</p><p>Priority: ${escapeHtml(lead.priority)}</p><p>${escapeHtml(lead.summary)}</p>${reviewDetails}<form method="POST" action="/review"><input name="leadId" type="hidden" value="${escapeHtml(lead.leadId)}"><label>Review note<input name="note" type="text" value="${escapeHtml(lead.reviewNote)}"></label><button type="submit">Save review</button></form><p><a href="/inbox">Back to inbox</a></p></main>`
  );
}

function renderInboxLinks(inbox: InboxSnapshot): string {
  return `<nav><p><a href="/lead/primary">${escapeHtml(inbox.primaryLeadLabel)}</a></p><p><a href="/lead/secondary">${escapeHtml(inbox.secondaryLeadLabel)}</a></p></nav>`;
}

export function leadLabel(lead: LeadRecord): string {
  return `${lead.company} (${lead.priority})`;
}
