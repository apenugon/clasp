from typing import Literal, TypedDict


AgentAction = Literal["reply", "ask_followup"]


class AgentDecision(TypedDict):
    action: AgentAction
    summary: str
    confidence: float


def is_agent_decision(value: object) -> bool:
    if not isinstance(value, dict):
        return False

    action = value.get("action")
    summary = value.get("summary")
    confidence = value.get("confidence")

    return (
        action in ("reply", "ask_followup")
        and isinstance(summary, str)
        and isinstance(confidence, (int, float))
        and 0 <= confidence <= 1
    )
