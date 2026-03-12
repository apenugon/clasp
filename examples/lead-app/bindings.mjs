const SEEDED_LEADS = [
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

export function createLeadDemoBindings(seedLeads = SEEDED_LEADS) {
  const leads = seedLeads.map((lead) => ({ ...lead }));

  return {
    mockLeadSummaryModel(intake) {
      const priority =
        intake.budget >= 50000 ? "High" : intake.budget >= 20000 ? "Medium" : "Low";

      return JSON.stringify({
        summary: `${intake.company} led by ${intake.contact} fits the ${priority.toLowerCase()} priority pipeline.`,
        priority: priority.toLowerCase(),
        segment: intake.segment ?? "startup",
        followUpRequired: intake.budget >= 20000
      });
    },
    storeLead(intake, summary) {
      const lead = {
        leadId: `lead-${leads.length + 1}`,
        company: intake.company,
        contact: intake.contact,
        summary: summary.summary,
        priority: summary.priority ?? "low",
        segment: summary.segment ?? "startup",
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

function leadLabel(lead) {
  return `${lead.company} (${lead.priority.toLowerCase()}, ${lead.segment.toLowerCase()})`;
}
