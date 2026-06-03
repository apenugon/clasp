#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="${CLASP_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
mkdir -p "$tmp_root"
export TMPDIR="$tmp_root"
export CLASP_NATIVE_JOBS_MAX="${CLASP_NATIVE_JOBS_MAX:-1}"
export CLASP_NATIVE_BUNDLE_JOBS="${CLASP_NATIVE_BUNDLE_JOBS:-1}"
export CLASP_NATIVE_IMAGE_SECTION_JOBS_MAX="${CLASP_NATIVE_IMAGE_SECTION_JOBS_MAX:-1}"
export CLASP_NATIVE_IMAGE_MODULE_DECL_FRESH_PROCESS="${CLASP_NATIVE_IMAGE_MODULE_DECL_FRESH_PROCESS:-1}"
export CLASP_NATIVE_IMAGE_MODULE_DECL_CHUNK_SIZE="${CLASP_NATIVE_IMAGE_MODULE_DECL_CHUNK_SIZE:-8}"
test_root="$(mktemp -d "$TMPDIR/test-swarm-memory.XXXXXX")"

cleanup() {
  rm -rf "$test_root"
}

trap cleanup EXIT

claspc_bin="$(env -u CLASP_CLASPC -u CLASPC_BIN -u RUSTC "$project_root/scripts/resolve-claspc.sh")"
cli_state_root="$test_root/cli-state"
program_state_root="$test_root/program-state"
embedding_provider_bin="$test_root/fake-embedding-provider"

cat >"$embedding_provider_bin" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

provider=""
model=""
input=""
scale=""
fail=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --provider)
      provider="${2:-}"
      shift 2
      ;;
    --model)
      model="${2:-}"
      shift 2
      ;;
    --input)
      input="${2:-}"
      shift 2
      ;;
    --scale)
      scale="${2:-}"
      shift 2
      ;;
    --fail)
      fail=1
      shift
      ;;
    *)
      printf 'unexpected embedding provider argument: %s\n' "$1" >&2
      exit 64
      ;;
  esac
done

if [[ "$fail" == "1" ]]; then
  printf 'fixture embedding provider failed on request\n' >&2
  exit 42
fi

if [[ -z "$provider" || -z "$model" || -z "$input" || -z "$scale" ]]; then
  printf 'missing provider/model/input/scale\n' >&2
  exit 65
fi

node - "$model" "$scale" "$input" <<'NODE'
const [model, scaleRaw, input] = process.argv.slice(2);
const dimensions = [];

function addIfPresent(needle, name, weight) {
  if (input.includes(needle)) dimensions.push({ name, weight });
}

addIfPresent("compiler", "compiler", 800);
addIfPresent("runtime", "runtime", 700);
addIfPresent("verifier", "verification", 500);
addIfPresent("guard", "resource-guard", 600);
addIfPresent("swarm", "swarm", 400);

process.stdout.write(JSON.stringify({
  model,
  scale: Number.parseInt(scaleRaw, 10),
  dimensions,
}));
NODE
EOF
chmod +x "$embedding_provider_bin"

"$claspc_bin" --json swarm objective create "$cli_state_root" memory-cli \
  --detail "Persist memory through the native CLI." \
  --max-tasks 1 \
  --max-runs 4 \
  >"$test_root/cli-objective.json"

"$claspc_bin" --json swarm task create "$cli_state_root" memory-cli memory-task \
  --detail "Record and query a native memory item." \
  --max-runs 4 \
  >"$test_root/cli-task.json"

"$claspc_bin" --json swarm memory put "$cli_state_root" lesson cli-memory \
  --objective memory-cli \
  --task memory-task \
  --actor cli-agent \
  >"$test_root/cli-memory-put.json"

"$claspc_bin" --json swarm memory query "$cli_state_root" \
  --objective memory-cli \
  --task memory-task \
  --key lesson \
  --limit 10 \
  >"$test_root/cli-memory-query.json"

"$claspc_bin" --json swarm memory search "$cli_state_root" "cli memory" \
  --objective memory-cli \
  --limit 10 \
  >"$test_root/cli-memory-search.json"

node - "$test_root/cli-memory-put.json" "$test_root/cli-memory-query.json" "$test_root/cli-memory-search.json" <<'EOF'
const fs = require("node:fs");

const put = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const query = JSON.parse(fs.readFileSync(process.argv[3], "utf8"));
const search = JSON.parse(fs.readFileSync(process.argv[4], "utf8"));

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

assert(put.objectiveId === "memory-cli", `put objective ${put.objectiveId}`);
assert(put.taskId === "memory-task", `put task ${put.taskId}`);
assert(put.actor === "cli-agent", `put actor ${put.actor}`);
assert(put.key === "lesson", `put key ${put.key}`);
assert(put.value === "cli-memory", `put value ${put.value}`);
assert(Array.isArray(query), "query is not an array");
assert(query.length === 1, `query length ${query.length}`);
assert(query[0].memoryId === put.memoryId, "query did not return inserted record");
assert(query[0].value === "cli-memory", `query value ${query[0].value}`);
assert(Array.isArray(search), "search is not an array");
assert(search.length >= 1, `search length ${search.length}`);
assert(search[0].memory.memoryId === put.memoryId, "search did not rank inserted record first");
assert(search[0].score > 0, `search score ${search[0].score}`);
assert(search[0].matchedText === "cli-memory", `search matched text ${search[0].matchedText}`);
EOF

env RUSTC=/definitely-missing-rustc \
  timeout 120 \
  "$claspc_bin" run "$project_root/examples/swarm-native/MemoryHarness.clasp" -- "$program_state_root" \
  >"$test_root/memory-harness.json"

if grep -F 'error:' "$test_root/memory-harness.json" >/dev/null; then
  cat "$test_root/memory-harness.json" >&2
  exit 1
fi

node - "$test_root/memory-harness.json" <<'EOF'
const fs = require("node:fs");

const report = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));

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

assert(report.objectiveMemory.objectiveId === "memory-objective", "objective memory objective id");
assert(report.objectiveMemory.taskId === "", "objective memory should not have a task id");
assert(report.objectiveMemory.value === "prefer-durable-objective-memory", "objective memory value");
assert(report.taskMemory.taskId === "memory-task", "task memory task id");
assert(report.taskMemory.actor === "memory-agent", "task memory actor");
assert(report.taskMemory.value === "prefer-durable-task-memory", "task memory value");
sameList(report.objectiveValues, ["prefer-durable-objective-memory"], "objective values");
sameList(report.taskValues, ["prefer-durable-task-memory"], "task values");
assert(report.allValues.includes("prefer-durable-objective-memory"), "all values missing objective memory");
assert(report.allValues.includes("prefer-durable-task-memory"), "all values missing task memory");
sameList(report.searchValues, ["prefer-durable-task-memory", "prefer-durable-objective-memory"], "search values");
assert(report.searchScores[0] > report.searchScores[1], `search scores ${JSON.stringify(report.searchScores)}`);
sameList(report.mailboxValues, ["prefer-durable-task-memory"], "mailbox memory values");
assert(report.mailboxMemoryCount === 1, `mailbox memory count ${report.mailboxMemoryCount}`);
assert(report.semanticMemoryCount === 4, `semantic memory count ${report.semanticMemoryCount}`);
assert(report.semanticDecodedCount === 3, `decoded semantic memory count ${report.semanticDecodedCount}`);
assert(report.semanticSkippedInvalidCount === 1, `skipped invalid count ${report.semanticSkippedInvalidCount}`);
assert(report.semanticEncodedHasEmbedding === true, "encoded semantic memory should carry embedding field");
sameList(report.semanticSearchTexts, ["compiler runtime verifier lesson", "runtime guard lesson"], "semantic search texts");
sameList(report.semanticSearchScores, [3, 1], "semantic search scores");
sameList(report.semanticTopMatchedDimensions, ["compiler", "runtime", "verification"], "top matched dimensions");
assert(report.semanticTopModel === "sparse-semantic-v1", `top model ${report.semanticTopModel}`);
EOF

env RUSTC=/definitely-missing-rustc \
  timeout 60 \
  "$claspc_bin" run "$project_root/examples/swarm-native/WeightedMemoryHarness.clasp" \
  >"$test_root/weighted-memory-harness.json"

if grep -F 'error:' "$test_root/weighted-memory-harness.json" >/dev/null; then
  cat "$test_root/weighted-memory-harness.json" >&2
  exit 1
fi

node - "$test_root/weighted-memory-harness.json" <<'EOF'
const fs = require("node:fs");

const report = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));

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

assert(report.weightedMemoryCount === 5, `weighted memory count ${report.weightedMemoryCount}`);
assert(report.weightedDecodedCount === 4, `weighted decoded count ${report.weightedDecodedCount}`);
assert(report.weightedSkippedInvalidCount === 1, `weighted skipped invalid count ${report.weightedSkippedInvalidCount}`);
assert(report.weightedEncodedHasDimensions === true, "weighted memory should carry dimensions field");
sameList(report.weightedSearchTexts, ["compiler runtime verifier dense lesson", "runtime guard weighted lesson"], "weighted search texts");
sameList(report.weightedSearchScores, [1600, 600], "weighted search scores");
sameList(report.weightedTopMatchedDimensions, ["compiler", "runtime", "verification"], "weighted top matched dimensions");
assert(report.weightedTopModel === "fixed-point-semantic-v1", `weighted top model ${report.weightedTopModel}`);
assert(report.weightedTopScale === 1000, `weighted top scale ${report.weightedTopScale}`);
EOF

env RUSTC=/definitely-missing-rustc \
  timeout 180 \
  "$claspc_bin" run "$project_root/examples/swarm-native/EmbeddingProviderHarness.clasp" -- "$embedding_provider_bin" \
  >"$test_root/embedding-provider-harness.json"

if grep -F 'error:' "$test_root/embedding-provider-harness.json" >/dev/null; then
  cat "$test_root/embedding-provider-harness.json" >&2
  exit 1
fi

node - "$test_root/embedding-provider-harness.json" "$embedding_provider_bin" <<'EOF'
const fs = require("node:fs");

const report = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const providerBin = process.argv[3];

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

assert(report.providerValidated === true, "provider output should validate");
assert(report.providerTrust === "validated", `provider trust ${report.providerTrust}`);
assert(report.pretrustedRejected === true, "pretrusted provider output should be rejected");
assert(report.providerMismatchRejected === true, "provider mismatch should be rejected");
assert(report.failedStatusRejected === true, "failed provider status should be rejected");
assert(report.payloadScaleRejected === true, "payload scale mismatch should be rejected");
sameList(report.generatedDimensionNames, ["compiler", "runtime", "verification", "swarm"], "generated dimension names");
sameList(report.generatedDimensionWeights, [800, 700, 500, 400], "generated dimension weights");
assert(report.vectorMemoryCount === 6, `vector memory count ${report.vectorMemoryCount}`);
assert(report.vectorIndexEntryCount === 3, `vector index entry count ${report.vectorIndexEntryCount}`);
assert(report.vectorIndexSkippedInvalidCount === 3, `vector index skipped invalid count ${report.vectorIndexSkippedInvalidCount}`);
assert(report.vectorIndexRoundTripDecoded === true, "vector index should decode after JSON round trip");
assert(report.vectorIndexEncodedHasEntries === true, "encoded vector index should carry entries");
sameList(
  report.vectorIndexSearchTexts,
  ["compiler runtime verifier dense lesson", "runtime guard weighted lesson", "swarm routing memory"],
  "vector index search texts",
);
sameList(report.vectorIndexSearchScores, [2000, 700, 400], "vector index search scores");
sameList(report.vectorIndexTopMatchedDimensions, ["compiler", "runtime", "verification"], "vector index top matched dimensions");
assert(report.vectorIndexTopProvider === "local-fixture-embedding-provider", `vector index top provider ${report.vectorIndexTopProvider}`);
assert(report.vectorIndexTopModel === "fixed-point-semantic-v1", `vector index top model ${report.vectorIndexTopModel}`);
assert(report.vectorIndexTopScale === 1000, `vector index top scale ${report.vectorIndexTopScale}`);
sameList(
  report.renderedCommand,
  [
    providerBin,
    "--provider",
    "fixture-command-provider",
    "--model",
    "fixed-point-semantic-v1",
    "--input",
    "compiler runtime verifier dense lesson",
    "--scale",
    "1000",
  ],
  "rendered embedding provider command",
);
assert(report.commandValid === true, "embedding provider command should be valid");
assert(report.networkAdapterValid === true, "embedding provider network adapter should be valid");
assert(report.networkAdapterStatus === "valid", `network adapter status ${report.networkAdapterStatus}`);
assert(report.networkAdapterAuthenticated === true, "network adapter should require auth env");
assert(report.networkAdapterAllowlisted === true, "network adapter should require allowlisted destination");
assert(report.networkAdapterEndpointHttps === true, "network adapter endpoint should be https");
assert(report.networkAdapterCommandHasEndpoint === true, "network adapter command should receive endpoint");
assert(report.networkAdapterCommandHasAuthEnv === true, "network adapter command should receive auth env var name");
assert(report.networkAdapterCommandHasNetworkDestination === true, "network adapter command should receive network destination");
assert(report.networkAdapterValidationMessage === "", `network adapter validation ${report.networkAdapterValidationMessage}`);
assert(report.invalidNetworkAdapterValidationMessage === "embedding-provider-network-adapter-endpoint-not-https", `invalid network adapter validation ${report.invalidNetworkAdapterValidationMessage}`);
sameList(
  report.renderedNetworkAdapterCommand,
  [
    providerBin,
    "--endpoint",
    "https://embeddings.example.test/v1/embeddings",
    "--auth-env",
    "CLASP_TEST_EMBEDDING_API_KEY",
    "--network-destination",
    "embeddings.example.test:443",
    "--provider",
    "fixture-command-provider",
    "--model",
    "fixed-point-semantic-v1",
    "--input",
    "compiler runtime verifier dense lesson",
    "--scale",
    "1000",
  ],
  "rendered embedding provider network adapter command",
);
assert(report.presetNetworkAdapterValid === true, "preset network adapter should be valid");
assert(report.presetNetworkAdapterProvider === "openai", `preset provider ${report.presetNetworkAdapterProvider}`);
assert(report.presetNetworkAdapterAuthEnvVar === "OPENAI_API_KEY", `preset auth env ${report.presetNetworkAdapterAuthEnvVar}`);
assert(report.presetNetworkAdapterAllowedDestination === "api.openai.com:443", `preset allowed destination ${report.presetNetworkAdapterAllowedDestination}`);
sameList(
  report.renderedPresetNetworkAdapterCommand,
  [
    providerBin,
    "--endpoint",
    "https://api.openai.com/v1/embeddings",
    "--auth-env",
    "OPENAI_API_KEY",
    "--network-destination",
    "api.openai.com:443",
    "--provider",
    "openai",
    "--model",
    "fixed-point-semantic-v1",
    "--input",
    "compiler runtime verifier dense lesson",
    "--scale",
    "1000",
  ],
  "rendered preset network adapter command",
);
assert(report.externalTransportValidated === true, "external embedding provider command should validate");
assert(report.externalTransportTrust === "validated", `transport trust ${report.externalTransportTrust}`);
assert(report.externalTransportModel === "fixed-point-semantic-v1", `transport model ${report.externalTransportModel}`);
assert(report.externalTransportScale === 1000, `transport scale ${report.externalTransportScale}`);
sameList(report.externalGeneratedDimensionNames, ["compiler", "runtime", "verification"], "transport generated dimension names");
sameList(report.externalGeneratedDimensionWeights, [800, 700, 500], "transport generated dimension weights");
assert(report.externalPayloadModelRejected === true, "provider payload model mismatch should be rejected");
assert(report.externalMissingInputTemplateRejected === true, "missing input placeholder should be rejected");
assert(report.externalExitRejected === true, "failing provider command should be rejected");
assert(report.externalTransportIndexEntryCount === 3, `transport vector index entry count ${report.externalTransportIndexEntryCount}`);
sameList(
  report.externalTransportIndexSearchTexts,
  ["compiler runtime verifier dense lesson", "runtime guard weighted lesson", "swarm routing memory"],
  "transport vector index search texts",
);
sameList(report.externalTransportIndexSearchScores, [2000, 700, 400], "transport vector index search scores");
assert(report.externalTransportIndexTopProvider === "fixture-command-provider", `transport top provider ${report.externalTransportIndexTopProvider}`);
assert(report.externalTransportIndexTopModel === "fixed-point-semantic-v1", `transport top model ${report.externalTransportIndexTopModel}`);
assert(report.externalTransportIndexTopScale === 1000, `transport top scale ${report.externalTransportIndexTopScale}`);
assert(report.vectorStoreShardCount === 2, `vector store shard count ${report.vectorStoreShardCount}`);
assert(report.vectorStoreEntryCount === 6, `vector store entry count ${report.vectorStoreEntryCount}`);
assert(report.vectorStoreRoundTripDecoded === true, "vector store should decode after JSON round trip");
assert(report.vectorStoreLocalShardMatches === 1, `vector store local shard matches ${report.vectorStoreLocalShardMatches}`);
assert(report.vectorStoreExternalShardMatches === 1, `vector store external shard matches ${report.vectorStoreExternalShardMatches}`);
sameList(
  report.vectorStoreLocalSearchTexts,
  ["compiler runtime verifier dense lesson", "runtime guard weighted lesson", "swarm routing memory"],
  "vector store local search texts",
);
sameList(report.vectorStoreLocalSearchScores, [2000, 700, 400], "vector store local search scores");
sameList(
  report.vectorStoreExternalSearchTexts,
  ["compiler runtime verifier dense lesson", "runtime guard weighted lesson", "swarm routing memory"],
  "vector store external search texts",
);
sameList(report.vectorStoreExternalSearchScores, [2000, 700, 400], "vector store external search scores");
EOF

printf 'swarm-memory-ok\n'
