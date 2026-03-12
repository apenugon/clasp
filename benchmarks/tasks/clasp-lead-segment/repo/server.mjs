import { pathToFileURL } from "node:url";
import * as compiled from "./build/Main.js";
import { installRuntime, serveCompiledModule } from "./runtime/server.mjs";

function createSeedLeads() {
  return [
    {
      leadId: "lead-2",
      company: "Northwind Studio",
      contact: "Morgan Lee",
      summary: "Northwind Studio is ready for a design-system migration this quarter.",
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
      summary: "Acme Labs is exploring an internal AI pilot for support operations.",
      priority: "high",
      segment: "enterprise",
      followUpRequired: true,
      reviewStatus: "new",
      reviewNote: ""
    }
  ];
}

function toWirePriority(value) {
  if (typeof value === "string") {
    return value;
  }

  if (typeof value === "object" && value !== null && typeof value.$tag === "string") {
    return value.$tag.toLowerCase();
  }

  return undefined;
}

function toWireSegment(value) {
  if (typeof value === "string") {
    return value;
  }

  if (typeof value === "object" && value !== null && typeof value.$tag === "string") {
    return value.$tag.toLowerCase();
  }

  return undefined;
}

function defaultMockLeadSummaryModel(intake) {
  const priority =
    intake.budget >= 50000 ? "High" : intake.budget >= 20000 ? "Medium" : "Low";

  return JSON.stringify({
    summary: `${intake.company} led by ${intake.contact} fits the ${priority.toLowerCase()} priority pipeline.`,
    priority: priority.toLowerCase(),
    segment: toWireSegment(intake.segment) ?? "startup",
    followUpRequired: intake.budget >= 20000
  });
}

function createBindings({ mockLeadSummaryModel = defaultMockLeadSummaryModel } = {}) {
  const leads = createSeedLeads();

  return {
    mockLeadSummaryModel,
    storeLead(intake, summary) {
      const lead = {
        leadId: `lead-${leads.length + 1}`,
        company: intake.company,
        contact: intake.contact,
        summary: summary.summary,
        priority: toWirePriority(summary.priority) ?? "low",
        segment: toWireSegment(summary.segment) ?? "startup",
        followUpRequired: summary.followUpRequired,
        reviewStatus: "new",
        reviewNote: ""
      };

      leads.unshift(lead);
      return JSON.stringify(lead);
    },
    loadInbox() {
      return JSON.stringify({
        headline: "Priority inbox",
        primaryLeadLabel: leadLabel(leads[0]),
        secondaryLeadLabel: leadLabel(leads[1] ?? leads[0])
      });
    },
    loadPrimaryLead() {
      return JSON.stringify(leads[0]);
    },
    loadSecondaryLead() {
      return JSON.stringify(leads[1] ?? leads[0]);
    },
    reviewLead(review) {
      const lead = leads.find((candidate) => candidate.leadId === review.leadId);

      if (!lead) {
        throw new Error(`Unknown lead: ${review.leadId}`);
      }

      lead.reviewStatus = "reviewed";
      lead.reviewNote = review.note;
      return JSON.stringify(lead);
    }
  };
}

export function createServer(bindings = {}, options = {}) {
  installRuntime(createBindings(bindings));
  return serveCompiledModule(compiled, options);
}

function leadLabel(lead) {
  return `${lead.company} (${lead.priority.toLowerCase()}, ${lead.segment.toLowerCase()})`;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const server = createServer({}, {
    port: Number(process.env.PORT ?? "3001")
  });

  console.log(`Clasp lead app listening on http://localhost:${server.port}`);
}
