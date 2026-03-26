import pathlib
import sys
import unittest


PROJECT_ROOT = pathlib.Path(__file__).resolve().parents[1]
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

from src.agent.decision import parse_agent_decision, should_escalate


class AgentEscalationTest(unittest.TestCase):
    def test_parse_agent_decision_accepts_escalate_and_marks_escalation(self) -> None:
        decision = parse_agent_decision(
            {
                "action": "escalate",
                "summary": "A human needs to review this request",
                "confidence": 0.18,
                "reason": "billing_dispute",
            }
        )

        self.assertEqual(decision["action"], "escalate")
        self.assertEqual(decision["reason"], "billing_dispute")
        self.assertTrue(should_escalate(decision))

    def test_parse_agent_decision_reports_informative_validation_errors(self) -> None:
        with self.assertRaisesRegex(
            ValueError, r"summary.*string.*confidence.*0 and 1"
        ):
            parse_agent_decision(
                {
                    "action": "escalate",
                    "summary": 42,
                    "confidence": 2,
                }
            )


if __name__ == "__main__":
    unittest.main()
