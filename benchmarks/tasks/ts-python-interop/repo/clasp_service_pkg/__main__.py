import json
import sys

for raw in sys.stdin:
    message = json.loads(raw)
    request = message["request"]
    response = {
        "summary": f"py:{request['company']}:{request['budget']}",
        "accepted": request["budget"] >= 40
    }
    sys.stdout.write(json.dumps({"response": response}) + "\n")
    sys.stdout.flush()
