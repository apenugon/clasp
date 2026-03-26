export function inspectLead(request) {
  if (request.company === "Globex") {
    return {
      label: "foreign:Globex",
      verdict: {
        accepted: "escalate",
        reason: "manual-review"
      }
    };
  }

  return {
    label: `foreign:${request.company}`,
    verdict: {
      accepted: request.budget >= 40,
      reason: "ship"
    }
  };
}
