#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="${CLASP_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
mkdir -p "$tmp_root"
export TMPDIR="$tmp_root"
test_root="$(mktemp -d "$TMPDIR/test-swarm-policy-helpers.XXXXXX")"
policy_helpers_run_binary_cache_dir="${CLASP_NATIVE_RUN_BINARY_CACHE_DIR:-$test_root/run-binary-cache-v2}"
export CLASP_NATIVE_RUN_BINARY_CACHE_DIR="$policy_helpers_run_binary_cache_dir"
mkdir -p "$CLASP_NATIVE_RUN_BINARY_CACHE_DIR"

cleanup() {
  if [[ -n "${allow_server_pid:-}" ]]; then
    kill "$allow_server_pid" 2>/dev/null || true
    wait "$allow_server_pid" 2>/dev/null || true
  fi
  if [[ -n "${deny_server_pid:-}" ]]; then
    kill "$deny_server_pid" 2>/dev/null || true
    wait "$deny_server_pid" 2>/dev/null || true
  fi
  rm -rf "$test_root"
}

trap cleanup EXIT

claspc_bin="$(env -u CLASP_CLASPC -u CLASPC_BIN -u RUSTC "$project_root/scripts/resolve-claspc.sh")"
state_root="$test_root/state"
policy_helpers_timeout_secs="${CLASP_SWARM_POLICY_HELPERS_TIMEOUT_SECS:-700}"
export CLASP_NATIVE_RUN_BINARY_CACHE_MAX_MB="${CLASP_NATIVE_RUN_BINARY_CACHE_MAX_MB:-512}"
node_bin="$(command -v node)"
network_mediator_path="$project_root/scripts/clasp-network-egress-enforcer.mjs"
network_backend_path="$project_root/scripts/clasp-network-egress-backend.mjs"
network_kernel_backend_path="$project_root/scripts/clasp-network-egress-kernel-backend.mjs"
network_guard_path="$project_root/scripts/clasp-network-egress-guard.c"
network_mediator_destinations_path="$test_root/network-mediator-destinations.json"
network_mediator_command_path="$test_root/network-mediator-command.json"
network_backend_allowlist_path="$test_root/network-backend-allowlist.txt"
network_mediator_no_backend_stderr="$test_root/network-mediator-no-backend.stderr"
network_mediator_json="$(node -e 'process.stdout.write(JSON.stringify([process.argv[1], process.argv[2]]))' "$node_bin" "$network_mediator_path")"
network_enforcer_backend_json="$(node -e 'process.stdout.write(JSON.stringify([process.argv[1], process.argv[2]]))' "$node_bin" "$network_backend_path")"
network_kernel_backend_json="$(node -e 'process.stdout.write(JSON.stringify([process.argv[1], process.argv[2]]))' "$node_bin" "$network_kernel_backend_path")"

node --check "$network_mediator_path" >/dev/null
node --check "$network_backend_path" >/dev/null
node --check "$network_kernel_backend_path" >/dev/null
cc -fsyntax-only "$network_guard_path" >/dev/null

if "$node_bin" "$network_mediator_path" \
  --network-access allowlisted \
  --destinations-json '["api.openai.com:443"]' \
  --cwd "$test_root" \
  --command-json '["bash","-lc","printf should-not-run"]' \
  -- bash -lc 'printf should-not-run' \
  >"$test_root/network-mediator-no-backend.stdout" 2>"$network_mediator_no_backend_stderr"; then
  printf 'network egress enforcer unexpectedly executed without a backend\n' >&2
  exit 1
fi
grep -F 'CLASP_SWARM_NETWORK_EGRESS_BACKEND_JSON is required' "$network_mediator_no_backend_stderr" >/dev/null

network_server_path="$test_root/network-server.mjs"
network_client_path="$test_root/network-client.mjs"
network_allow_port_path="$test_root/network-allow-port.txt"
network_deny_port_path="$test_root/network-deny-port.txt"

cat >"$network_server_path" <<'EOF'
import fs from "node:fs";
import net from "node:net";

const portPath = process.argv[2];
const host = process.argv[3] || "127.0.0.1";
const server = net.createServer((socket) => {
  socket.on("error", () => {});
  socket.end("ok\n");
});

server.listen(0, host, () => {
  fs.writeFileSync(portPath, String(server.address().port));
});
EOF

cat >"$network_client_path" <<'EOF'
import net from "node:net";

const host = process.argv[2];
const port = Number.parseInt(process.argv[3], 10);
const mode = process.argv[4];
const socket = net.connect({ host, port });

const timer = setTimeout(() => {
  console.error("network client timed out");
  socket.destroy();
  process.exit(70);
}, 3000);

socket.on("connect", () => {
  clearTimeout(timer);
  socket.end();
  if (mode === "allow") {
    process.stdout.write("connected\n");
    process.exit(0);
  }
  console.error("disallowed connection unexpectedly succeeded");
  process.exit(71);
});

socket.on("error", (error) => {
  clearTimeout(timer);
  if (mode === "deny" && error.code === "EACCES") {
    process.stdout.write("denied\n");
    process.exit(0);
  }
  console.error(`unexpected network client error: ${error.code || error.message}`);
  process.exit(72);
});
EOF

"$node_bin" "$network_server_path" "$network_allow_port_path" &
allow_server_pid="$!"
"$node_bin" "$network_server_path" "$network_deny_port_path" "127.0.0.2" &
deny_server_pid="$!"

for _ in $(seq 1 100); do
  if [[ -s "$network_allow_port_path" && -s "$network_deny_port_path" ]]; then
    break
  fi
  sleep 0.05
done
if [[ ! -s "$network_allow_port_path" || ! -s "$network_deny_port_path" ]]; then
  printf 'network egress test servers did not start\n' >&2
  exit 1
fi

network_allow_port="$(cat "$network_allow_port_path")"
network_deny_port="$(cat "$network_deny_port_path")"
network_allowed_command_json="$(node -e 'process.stdout.write(JSON.stringify([process.argv[1], process.argv[2], "127.0.0.1", process.argv[3], "allow"]))' "$node_bin" "$network_client_path" "$network_allow_port")"
network_denied_command_json="$(node -e 'process.stdout.write(JSON.stringify([process.argv[1], process.argv[2], "127.0.0.2", process.argv[3], "deny"]))' "$node_bin" "$network_client_path" "$network_deny_port")"

CLASP_SWARM_NETWORK_EGRESS_BACKEND_JSON="$network_enforcer_backend_json" \
CLASP_SWARM_NETWORK_EGRESS_AUDIT_ALLOWLIST_PATH="$network_backend_allowlist_path" \
"$node_bin" "$network_mediator_path" \
  --network-access allowlisted \
  --destinations-json "[\"127.0.0.1:${network_allow_port}\"]" \
  --cwd "$test_root" \
  --command-json "$network_allowed_command_json" \
  -- "$node_bin" "$network_client_path" "127.0.0.1" "$network_allow_port" allow \
  >"$test_root/network-allowed.stdout"
grep -F 'connected' "$test_root/network-allowed.stdout" >/dev/null
grep -F "4,127.0.0.1,${network_allow_port}" "$network_backend_allowlist_path" >/dev/null

CLASP_SWARM_NETWORK_EGRESS_BACKEND_JSON="$network_enforcer_backend_json" \
"$node_bin" "$network_mediator_path" \
  --network-access allowlisted \
  --destinations-json "[\"127.0.0.1:${network_allow_port}\"]" \
  --cwd "$test_root" \
  --command-json "$network_denied_command_json" \
  -- "$node_bin" "$network_client_path" "127.0.0.2" "$network_deny_port" deny \
  >"$test_root/network-denied.stdout"
grep -F 'denied' "$test_root/network-denied.stdout" >/dev/null

network_direct_client_path="$test_root/network-direct-client"
cat >"$test_root/network-direct-client.c" <<'EOF'
#define _GNU_SOURCE

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <unistd.h>

static int direct_connect(const char *host, int port) {
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  struct sockaddr_in addr;
  if (fd < 0) {
    return -1;
  }
  memset(&addr, 0, sizeof(addr));
  addr.sin_family = AF_INET;
  addr.sin_port = htons((unsigned short)port);
  if (inet_pton(AF_INET, host, &addr.sin_addr) != 1) {
    return -2;
  }
  return (int)syscall(SYS_connect, fd, (struct sockaddr *)&addr, sizeof(addr));
}

int main(int argc, char **argv) {
  const char *allow_host = argv[1];
  int allow_port = atoi(argv[2]);
  const char *deny_host = argv[3];
  int deny_port = atoi(argv[4]);
  if (direct_connect(allow_host, allow_port) != 0) {
    perror("allowed direct connect failed");
    return 10;
  }
  if (direct_connect(deny_host, deny_port) == 0) {
    fprintf(stderr, "denied direct connect unexpectedly succeeded\n");
    return 11;
  }
  printf("kernel-egress-direct-syscall-ok\n");
  return 0;
}
EOF
cc -O2 -o "$network_direct_client_path" "$test_root/network-direct-client.c"
network_direct_command_json="$(node -e 'process.stdout.write(JSON.stringify([process.argv[1], "127.0.0.1", process.argv[2], "127.0.0.2", process.argv[3]]))' "$network_direct_client_path" "$network_allow_port" "$network_deny_port")"

CLASP_SWARM_NETWORK_EGRESS_BACKEND_JSON="$network_kernel_backend_json" \
"$node_bin" "$network_mediator_path" \
  --network-access allowlisted \
  --destinations-json "[\"127.0.0.1:${network_allow_port}\"]" \
  --cwd "$test_root" \
  --command-json "$network_direct_command_json" \
  -- "$network_direct_client_path" "127.0.0.1" "$network_allow_port" "127.0.0.2" "$network_deny_port" \
  >"$test_root/network-kernel-direct.stdout"
grep -F 'kernel-egress-direct-syscall-ok' "$test_root/network-kernel-direct.stdout" >/dev/null

network_hostname_direct_client_path="$test_root/network-hostname-direct-client"
cat >"$test_root/network-hostname-direct-client.c" <<'EOF'
#define _GNU_SOURCE

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <sys/time.h>
#include <unistd.h>

static int direct_connect_sockaddr(struct sockaddr_in *addr) {
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0) {
    return -1;
  }
  return (int)syscall(SYS_connect, fd, (struct sockaddr *)addr, sizeof(*addr));
}

static int append_dns_name(unsigned char *query, int offset, const char *host) {
  const char *start = host;
  const char *cursor = host;
  while (1) {
    if (*cursor == '.' || *cursor == '\0') {
      int length = (int)(cursor - start);
      if (length <= 0 || length > 63 || offset + 1 + length >= 250) {
        return -1;
      }
      query[offset++] = (unsigned char)length;
      memcpy(query + offset, start, (size_t)length);
      offset += length;
      if (*cursor == '\0') {
        query[offset++] = 0;
        return offset;
      }
      start = cursor + 1;
    }
    cursor++;
  }
}

static int resolve_dns_ipv4(const char *host, char *out, size_t out_size) {
  int fd = socket(AF_INET, SOCK_DGRAM, 0);
  unsigned char query[512];
  unsigned char response[512];
  struct sockaddr_in dns_addr;
  struct timeval timeout;
  int offset;
  ssize_t received;
  if (fd < 0) {
    return -1;
  }
  timeout.tv_sec = 2;
  timeout.tv_usec = 0;
  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
  memset(query, 0, sizeof(query));
  query[0] = 0x12;
  query[1] = 0x34;
  query[2] = 0x01;
  query[5] = 0x01;
  offset = append_dns_name(query, 12, host);
  if (offset < 0 || offset + 4 >= (int)sizeof(query)) {
    close(fd);
    return -2;
  }
  query[offset++] = 0;
  query[offset++] = 1;
  query[offset++] = 0;
  query[offset++] = 1;
  memset(&dns_addr, 0, sizeof(dns_addr));
  dns_addr.sin_family = AF_INET;
  dns_addr.sin_port = htons(53);
  inet_pton(AF_INET, "127.0.0.53", &dns_addr.sin_addr);
  if (sendto(fd, query, (size_t)offset, 0, (struct sockaddr *)&dns_addr, sizeof(dns_addr)) < 0) {
    close(fd);
    return -3;
  }
  received = recv(fd, response, sizeof(response), 0);
  close(fd);
  if (received < 16 || response[0] != 0x12 || response[1] != 0x34) {
    return -4;
  }
  for (int index = 12; index + 16 <= received; index++) {
    if (response[index] == 0xc0 && response[index + 1] == 0x0c &&
        response[index + 2] == 0 && response[index + 3] == 1 &&
        response[index + 4] == 0 && response[index + 5] == 1 &&
        response[index + 10] == 0 && response[index + 11] == 4) {
      snprintf(out, out_size, "%u.%u.%u.%u",
        response[index + 12],
        response[index + 13],
        response[index + 14],
        response[index + 15]);
      return 0;
    }
  }
  return -5;
}

static int direct_connect_ip(const char *host, int port) {
  struct sockaddr_in addr;
  memset(&addr, 0, sizeof(addr));
  addr.sin_family = AF_INET;
  addr.sin_port = htons((unsigned short)port);
  if (inet_pton(AF_INET, host, &addr.sin_addr) != 1) {
    return -2;
  }
  return direct_connect_sockaddr(&addr);
}

int main(int argc, char **argv) {
  const char *allow_host = argv[1];
  int allow_port = atoi(argv[2]);
  const char *deny_host = argv[3];
  int deny_port = atoi(argv[4]);
  char allowed_ip[64];
  if (resolve_dns_ipv4(allow_host, allowed_ip, sizeof(allowed_ip)) != 0) {
    fprintf(stderr, "allowed hostname resolution failed\n");
    return 20;
  }
  if (direct_connect_ip(allowed_ip, allow_port) != 0) {
    perror("allowed hostname direct connect failed");
    return 21;
  }
  if (direct_connect_ip(deny_host, deny_port) == 0) {
    fprintf(stderr, "denied direct connect unexpectedly succeeded\n");
    return 22;
  }
  printf("kernel-egress-hostname-direct-syscall-ok\n");
  return 0;
}
EOF
cc -O2 -o "$network_hostname_direct_client_path" "$test_root/network-hostname-direct-client.c"
network_hostname_direct_command_json="$(node -e 'process.stdout.write(JSON.stringify([process.argv[1], "clasp-allowed.test", process.argv[2], "127.0.0.2", process.argv[3]]))' "$network_hostname_direct_client_path" "$network_allow_port" "$network_deny_port")"

CLASP_SWARM_NETWORK_EGRESS_BACKEND_JSON="$network_kernel_backend_json" \
CLASP_NETWORK_EGRESS_RESOLUTION_OVERRIDES_JSON='{"clasp-allowed.test":["127.0.0.1"]}' \
"$node_bin" "$network_mediator_path" \
  --network-access allowlisted \
  --destinations-json "[\"clasp-allowed.test:${network_allow_port}\"]" \
  --cwd "$test_root" \
  --command-json "$network_hostname_direct_command_json" \
  -- "$network_hostname_direct_client_path" "clasp-allowed.test" "$network_allow_port" "127.0.0.2" "$network_deny_port" \
  >"$test_root/network-kernel-hostname-direct.stdout"
grep -F 'kernel-egress-hostname-direct-syscall-ok' "$test_root/network-kernel-hostname-direct.stdout" >/dev/null

env RUSTC=/definitely-missing-rustc \
  timeout "$policy_helpers_timeout_secs" \
  "$claspc_bin" run "$project_root/examples/swarm-native/PolicyHarness.clasp" -- "$state_root" \
  >"$test_root/policy-harness.json"

if grep -F 'error:' "$test_root/policy-harness.json" >/dev/null; then
  cat "$test_root/policy-harness.json" >&2
  exit 1
fi

node - "$test_root/policy-harness.json" "$state_root/workspace" <<'EOF'
const fs = require("node:fs");
const report = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const workspaceRoot = fs.realpathSync(process.argv[3]);

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function sameList(actual, expected, label) {
  assert(Array.isArray(actual), `${label} is not an array`);
  assert(
    JSON.stringify(actual) === JSON.stringify(expected),
    `${label} expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`,
  );
}

assert(report.taskId === "policy-helper-task", `task id ${report.taskId}`);
assert(report.mergegateName === "typed-policy", `mergegate ${report.mergegateName}`);
sameList(report.requiredApprovals, ["review"], "required approvals");
sameList(report.requiredVerifiers, ["typed-policy-smoke"], "required verifiers");
sameList(report.allowedProcesses, ["bash"], "allowed processes");
sameList(report.allowedWorkspaceRoots, [workspaceRoot], "allowed workspace roots");
assert(report.networkAccess === "denied", `network access ${report.networkAccess}`);
sameList(report.allowedNetworkDestinations, [], "allowed network destinations");
assert(report.allowlistedNetworkAccess === "allowlisted", `allowlisted network ${report.allowlistedNetworkAccess}`);
sameList(report.allowlistedNetworkDestinations, ["api.openai.com:443"], "allowlisted network destinations");
assert(report.allowlistedNetworkBlocked === true, "allowlisted network run should fail closed");
assert(report.allowlistedNetworkMediated === false, "unmediated allowlisted network run should not be marked mediated");
assert(report.allowlistedNetworkStatus === "blocked", `unmediated status ${report.allowlistedNetworkStatus}`);
assert(report.allowlistedNetworkExitCode === 125, `unmediated exit ${report.allowlistedNetworkExitCode}`);
assert(report.allowlistedNetworkFileExists === false, "unmediated allowlisted network command should not run");
assert(report.allowedRunStatus === "passed", `allowed run status ${report.allowedRunStatus}`);
assert(report.allowedRunExitCode === 0, `allowed run exit ${report.allowedRunExitCode}`);
assert(report.deniedProcessBlocked === true, "denied process should be blocked");
assert(report.deniedWorkspaceBlocked === true, "denied workspace should be blocked");
assert(report.eventKinds.includes("tool_run_finished"), `tool_run_finished event missing ${JSON.stringify(report.eventKinds)}`);
assert(report.eventKinds.includes("process_permission_denied"), `process denial event missing ${JSON.stringify(report.eventKinds)}`);
assert(report.eventKinds.includes("workspace_permission_denied"), `workspace denial event missing ${JSON.stringify(report.eventKinds)}`);
assert(report.networkEventKinds.includes("network_permission_denied"), `network denial event missing ${JSON.stringify(report.networkEventKinds)}`);
EOF

CLASP_SWARM_NETWORK_MEDIATOR_JSON="$network_mediator_json" \
CLASP_SWARM_NETWORK_EGRESS_BACKEND_JSON="$network_enforcer_backend_json" \
CLASP_SWARM_NETWORK_EGRESS_AUDIT_DESTINATIONS_PATH="$network_mediator_destinations_path" \
CLASP_SWARM_NETWORK_EGRESS_AUDIT_COMMAND_PATH="$network_mediator_command_path" \
env RUSTC=/definitely-missing-rustc \
  timeout "$policy_helpers_timeout_secs" \
  "$claspc_bin" run "$project_root/examples/swarm-native/PolicyHarness.clasp" -- "$state_root/mediated" \
  >"$test_root/policy-harness-mediated.json"

if grep -F 'error:' "$test_root/policy-harness-mediated.json" >/dev/null; then
  cat "$test_root/policy-harness-mediated.json" >&2
  exit 1
fi

node - "$test_root/policy-harness-mediated.json" "$state_root/mediated/workspace" "$network_mediator_destinations_path" "$network_mediator_command_path" <<'EOF'
const fs = require("node:fs");
const report = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const workspaceRoot = fs.realpathSync(process.argv[3]);
const mediatedDestinations = JSON.parse(fs.readFileSync(process.argv[4], "utf8"));
const mediatedCommand = JSON.parse(fs.readFileSync(process.argv[5], "utf8"));

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function sameList(actual, expected, label) {
  assert(Array.isArray(actual), `${label} is not an array`);
  assert(
    JSON.stringify(actual) === JSON.stringify(expected),
    `${label} expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`,
  );
}

sameList(report.allowedWorkspaceRoots, [workspaceRoot], "mediated allowed workspace roots");
assert(report.allowlistedNetworkAccess === "allowlisted", `mediated network ${report.allowlistedNetworkAccess}`);
sameList(report.allowlistedNetworkDestinations, ["api.openai.com:443"], "mediated network destinations");
assert(report.allowlistedNetworkBlocked === false, "mediated allowlisted network run should not fail closed");
assert(report.allowlistedNetworkMediated === true, "mediated allowlisted network run should be marked mediated");
assert(report.allowlistedNetworkStatus === "passed", `mediated status ${report.allowlistedNetworkStatus}`);
assert(report.allowlistedNetworkExitCode === 0, `mediated exit ${report.allowlistedNetworkExitCode}`);
assert(report.allowlistedNetworkFileExists === true, "mediated allowlisted network command should run");
assert(report.networkEventKinds.includes("network_mediation_started"), `network mediation event missing ${JSON.stringify(report.networkEventKinds)}`);
assert(report.networkEventKinds.includes("tool_run_finished"), `mediated tool finish event missing ${JSON.stringify(report.networkEventKinds)}`);
assert(!report.networkEventKinds.includes("network_permission_denied"), `mediated run should not emit denial ${JSON.stringify(report.networkEventKinds)}`);
sameList(mediatedDestinations, ["api.openai.com:443"], "mediator destinations");
sameList(mediatedCommand, ["bash", "-lc", "printf allowlisted-network-ran > allowlisted-network.txt"], "mediator command");
EOF

env RUSTC=/definitely-missing-rustc \
  timeout "$policy_helpers_timeout_secs" \
  "$claspc_bin" run "$project_root/examples/swarm-native/CapabilityPolicyHarness.clasp" -- "$state_root/capability-policy" \
  >"$test_root/capability-policy-harness.json"

if grep -F 'error:' "$test_root/capability-policy-harness.json" >/dev/null; then
  cat "$test_root/capability-policy-harness.json" >&2
  exit 1
fi

node - "$test_root/capability-policy-harness.json" "$state_root/capability-policy/workspace" "$state_root/capability-policy/readonly-dependencies" <<'EOF'
const fs = require("node:fs");
const report = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const workspaceRoot = fs.realpathSync(process.argv[3]);
const readonlyRoot = fs.realpathSync(process.argv[4]);

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function sameList(actual, expected, label) {
  assert(Array.isArray(actual), `${label} is not an array`);
  assert(
    JSON.stringify(actual) === JSON.stringify(expected),
    `${label} expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`,
  );
}

assert(report.taskId === "capability-policy-task", `capability task id ${report.taskId}`);
assert(report.mergegateName === "capability-policy", `capability mergegate ${report.mergegateName}`);
sameList(report.configuredCapabilities.processes, ["bash"], "configured capability processes");
sameList(report.configuredCapabilities.filesystemRoots, [process.argv[3]], "configured capability filesystem roots");
sameList(report.configuredCapabilities.readonlyFilesystemRoots, [process.argv[4]], "configured capability read-only roots");
assert(report.configuredCapabilities.networkAccess === "allowlisted", `configured capability network ${report.configuredCapabilities.networkAccess}`);
sameList(report.configuredCapabilities.networkDestinations, ["api.openai.com:443"], "configured capability network destinations");
sameList(report.configuredCapabilities.approvals, ["review"], "configured capability approvals");
sameList(report.configuredCapabilities.verifiers, ["typed-policy-smoke"], "configured capability verifiers");
sameList(report.accessPolicy.allowedProcesses, ["bash"], "access policy processes");
sameList(report.accessPolicy.allowedWorkspaceRoots, [process.argv[3]], "access policy filesystem roots");
sameList(report.accessPolicy.allowedReadonlyRoots, [process.argv[4]], "access policy read-only roots");
assert(report.accessPolicy.networkAccess === "allowlisted", `access policy network ${report.accessPolicy.networkAccess}`);
sameList(report.accessPolicy.allowedNetworkDestinations, ["api.openai.com:443"], "access policy network destinations");
sameList(report.verificationPolicy.requiredApprovals, ["review"], "verification policy approvals");
sameList(report.verificationPolicy.requiredVerifiers, ["typed-policy-smoke"], "verification policy verifiers");
sameList(report.policy.requiredApprovals, ["review"], "policy approvals");
sameList(report.policy.requiredVerifiers, ["typed-policy-smoke"], "policy verifiers");
sameList(report.policy.allowedProcesses, ["bash"], "policy processes");
sameList(report.policy.allowedWorkspaceRoots, [workspaceRoot], "policy filesystem roots");
sameList(report.policy.allowedReadonlyRoots, [readonlyRoot], "policy read-only roots");
assert(report.policy.networkAccess === "allowlisted", `policy network ${report.policy.networkAccess}`);
sameList(report.policy.allowedNetworkDestinations, ["api.openai.com:443"], "policy network destinations");
sameList(report.policy.capabilities.processes, ["bash"], "policy capability processes");
sameList(report.policy.capabilities.filesystemRoots, [workspaceRoot], "policy capability filesystem roots");
sameList(report.policy.capabilities.readonlyFilesystemRoots, [readonlyRoot], "policy capability read-only roots");
assert(report.policy.capabilities.networkAccess === "allowlisted", `policy capability network ${report.policy.capabilities.networkAccess}`);
sameList(report.policy.capabilities.networkDestinations, ["api.openai.com:443"], "policy capability network destinations");
sameList(report.policy.capabilities.approvals, ["review"], "policy capability approvals");
sameList(report.policy.capabilities.verifiers, ["typed-policy-smoke"], "policy capability verifiers");
EOF

env RUSTC=/definitely-missing-rustc \
  timeout "$policy_helpers_timeout_secs" \
  "$claspc_bin" run "$project_root/examples/swarm-native/GoalManagerTaskPolicyHarness.clasp" -- "$state_root/default-policy" \
  >"$test_root/goal-manager-task-policy-default.json"

CLASP_MANAGER_TASK_APPROVAL_JSON='"policy-review"' \
CLASP_MANAGER_TASK_MERGEGATE_JSON='"policy-trunk"' \
CLASP_MANAGER_TASK_REQUIRED_APPROVALS_JSON='["policy-review","audit"]' \
CLASP_MANAGER_TASK_REQUIRED_VERIFIERS_JSON='["focused-native","scenario"]' \
CLASP_MANAGER_TASK_ALLOWED_PROCESSES_JSON='["bash","claspc"]' \
CLASP_MANAGER_TASK_ALLOWED_WORKSPACE_ROOTS_JSON='["/tmp/policy-workspace","/tmp/policy-cache"]' \
CLASP_MANAGER_TASK_ALLOWED_READONLY_ROOTS_JSON='["/nix/store/example-readonly-root"]' \
CLASP_MANAGER_TASK_NETWORK_ACCESS_JSON='"allowlisted"' \
CLASP_MANAGER_TASK_ALLOWED_NETWORK_DESTINATIONS_JSON='["api.openai.com:443","github.com:443"]' \
env RUSTC=/definitely-missing-rustc \
  timeout "$policy_helpers_timeout_secs" \
  "$claspc_bin" run "$project_root/examples/swarm-native/GoalManagerTaskPolicyHarness.clasp" -- "$state_root/configured-policy" \
  >"$test_root/goal-manager-task-policy-configured.json"

node - "$test_root/goal-manager-task-policy-default.json" "$test_root/goal-manager-task-policy-configured.json" <<'EOF'
const fs = require("node:fs");
const [defaultPath, configuredPath] = process.argv.slice(2);
const defaults = JSON.parse(fs.readFileSync(defaultPath, "utf8"));
const configured = JSON.parse(fs.readFileSync(configuredPath, "utf8"));

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function sameList(actual, expected, label) {
  assert(Array.isArray(actual), `${label} is not an array`);
  assert(
    JSON.stringify(actual) === JSON.stringify(expected),
    `${label} expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`,
  );
}

assert(defaults.approvalName === "merge-ready", `default approval ${defaults.approvalName}`);
assert(defaults.mergegateName === "trunk", `default mergegate ${defaults.mergegateName}`);
sameList(defaults.requiredApprovals, ["merge-ready"], "default approvals");
sameList(defaults.requiredVerifiers, [], "default verifiers");
sameList(defaults.allowedProcesses, [], "default allowed processes");
sameList(defaults.allowedWorkspaceRoots, [], "default workspace roots");
sameList(defaults.allowedReadonlyRoots, [], "default read-only roots");
assert(defaults.networkAccess === "ambient", `default network ${defaults.networkAccess}`);
sameList(defaults.allowedNetworkDestinations, [], "default network destinations");

assert(configured.approvalName === "policy-review", `configured approval ${configured.approvalName}`);
assert(configured.mergegateName === "policy-trunk", `configured mergegate ${configured.mergegateName}`);
sameList(configured.requiredApprovals, ["policy-review", "audit"], "configured approvals");
sameList(configured.requiredVerifiers, ["focused-native", "scenario"], "configured verifiers");
sameList(configured.allowedProcesses, ["bash", "claspc"], "configured allowed processes");
sameList(configured.allowedWorkspaceRoots, ["/tmp/policy-workspace", "/tmp/policy-cache"], "configured workspace roots");
sameList(configured.allowedReadonlyRoots, ["/nix/store/example-readonly-root"], "configured read-only roots");
assert(configured.networkAccess === "allowlisted", `configured network ${configured.networkAccess}`);
sameList(configured.allowedNetworkDestinations, ["api.openai.com:443", "github.com:443"], "configured network destinations");
EOF

if [[ "$CLASP_NATIVE_RUN_BINARY_CACHE_MAX_MB" =~ ^[0-9]+$ ]]; then
  if [[ -n "${CLASP_NATIVE_RUN_BINARY_CACHE_DIR:-}" ]]; then
    run_binary_cache_dir="$CLASP_NATIVE_RUN_BINARY_CACHE_DIR"
  elif [[ -n "${XDG_CACHE_HOME:-}" ]]; then
    run_binary_cache_dir="$XDG_CACHE_HOME/claspc-native/run-binary-cache-v2"
  else
    run_binary_cache_dir="/tmp/clasp-nix-cache/claspc-native/run-binary-cache-v2"
  fi
  run_binary_cache_kb="$(du -sk "$run_binary_cache_dir" 2>/dev/null | awk '{print $1}')"
  run_binary_cache_kb="${run_binary_cache_kb:-0}"
  # Allow one current protected binary to keep the cache slightly above the configured cap.
  run_binary_cache_limit_kb="$(((CLASP_NATIVE_RUN_BINARY_CACHE_MAX_MB + 64) * 1024))"
  if (( run_binary_cache_kb > run_binary_cache_limit_kb )); then
    printf 'run binary cache exceeded cap: %s KiB > %s KiB\n' "$run_binary_cache_kb" "$run_binary_cache_limit_kb" >&2
    exit 1
  fi
fi

printf 'swarm-policy-helpers-ok\n'
