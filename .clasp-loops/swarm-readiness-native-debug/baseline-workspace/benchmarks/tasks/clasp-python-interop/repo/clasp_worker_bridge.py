import json
import sys

for raw in sys.stdin:
    message = json.loads(raw)
    request = message["request"]
    response = {
        "accepted": True,
        "workerLabel": f"py:{request['workerId']}"
    }
    sys.stdout.write(json.dumps({"response": response}) + "\n")
    sys.stdout.flush()
