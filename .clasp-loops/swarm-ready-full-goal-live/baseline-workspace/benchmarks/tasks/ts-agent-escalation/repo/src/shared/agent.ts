export type AgentAction = "reply" | "ask_followup";

export interface AgentDecision {
  action: AgentAction;
  summary: string;
  confidence: number;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

export function isAgentDecision(value: unknown): value is AgentDecision {
  if (!isRecord(value)) {
    return false;
  }

  return (
    (value.action === "reply" || value.action === "ask_followup") &&
    typeof value.summary === "string" &&
    typeof value.confidence === "number" &&
    value.confidence >= 0 &&
    value.confidence <= 1
  );
}

