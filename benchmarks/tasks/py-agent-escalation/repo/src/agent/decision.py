from src.shared.agent import AgentDecision, is_agent_decision


def parse_agent_decision(value: object) -> AgentDecision:
    if not is_agent_decision(value):
        raise ValueError("Invalid agent decision")

    return value


def should_escalate(decision: AgentDecision) -> bool:
    return decision["action"] == "ask_followup" and decision["confidence"] < 0.5
