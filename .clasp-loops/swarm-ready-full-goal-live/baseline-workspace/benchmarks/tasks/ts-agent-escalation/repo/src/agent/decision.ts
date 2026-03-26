import { AgentDecision, isAgentDecision } from "../shared/agent.js";

export function parseAgentDecision(value: unknown): AgentDecision {
  if (!isAgentDecision(value)) {
    throw new Error("Invalid agent decision");
  }

  return value;
}

export function shouldEscalate(decision: AgentDecision): boolean {
  return decision.action === "ask_followup" && decision.confidence < 0.5;
}

