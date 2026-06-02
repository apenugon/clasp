#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

node - "$project_root/examples/swarm-native/ResourceGuardPolicy.clasp" <<'NODE'
const fs = require("node:fs");

const [policyPath] = process.argv.slice(2);
const source = fs.readFileSync(policyPath, "utf8");

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function includes(text) {
  assert(source.includes(text), `missing policy source: ${text}`);
}

function launchRequired(minAvailableMb, childReserveMb) {
  return childReserveMb < 1 ? minAvailableMb : minAvailableMb + childReserveMb;
}

function projectedLaunchRequired(minAvailableMb, childReserveMb, projectedActiveChildren) {
  const projected = projectedActiveChildren < 1 ? 1 : projectedActiveChildren;
  return childReserveMb < 1 ? minAvailableMb : minAvailableMb + childReserveMb * projected;
}

function externalAgentReserve(externalAgentReserveMb, externalAgentCount) {
  if (externalAgentReserveMb < 1 || externalAgentCount < 1) return 0;
  return externalAgentReserveMb * externalAgentCount;
}

function externalAgentReservedMemory(externalAgentReserveMb, externalAgentCount, externalAgentRssMb) {
  if (externalAgentReserveMb < 1 || externalAgentCount < 1) return 0;
  return Math.max(0, externalAgentRssMb) + externalAgentReserve(externalAgentReserveMb, externalAgentCount);
}

function projectedLaunchRequiredWithExternal(
  minAvailableMb,
  childReserveMb,
  projectedActiveChildren,
  externalAgentReserveMb,
  externalAgentCount,
) {
  return (
    projectedLaunchRequired(minAvailableMb, childReserveMb, projectedActiveChildren) +
    externalAgentReserve(externalAgentReserveMb, externalAgentCount)
  );
}

function projectedLaunchRequiredWithExternalStats(
  minAvailableMb,
  childReserveMb,
  projectedActiveChildren,
  externalAgentReserveMb,
  externalAgentCount,
  externalAgentRssMb,
) {
  return (
    projectedLaunchRequired(minAvailableMb, childReserveMb, projectedActiveChildren) +
    externalAgentReservedMemory(externalAgentReserveMb, externalAgentCount, externalAgentRssMb)
  );
}

function launchError(minAvailableMb, childReserveMb, availableMb) {
  if (minAvailableMb > 0 && availableMb < minAvailableMb) {
    return `memory reserve unmet: availableMb=${availableMb}:requiredMb=${minAvailableMb}`;
  }
  const requiredMb = launchRequired(minAvailableMb, childReserveMb);
  if (childReserveMb > 0 && availableMb < requiredMb) {
    const headroomMb = availableMb - minAvailableMb;
    return `memory child reserve unmet: availableMb=${availableMb}:requiredMb=${minAvailableMb}:childReserveMb=${childReserveMb}:launchRequiredMb=${requiredMb}:launchHeadroomMb=${headroomMb}`;
  }
  return "";
}

function projectedLaunchError(minAvailableMb, childReserveMb, projectedActiveChildren, availableMb) {
  if (minAvailableMb > 0 && availableMb < minAvailableMb) {
    return `memory reserve unmet: availableMb=${availableMb}:requiredMb=${minAvailableMb}`;
  }
  const projected = projectedActiveChildren < 1 ? 1 : projectedActiveChildren;
  const requiredMb = projectedLaunchRequired(minAvailableMb, childReserveMb, projected);
  if (childReserveMb > 0 && availableMb < requiredMb) {
    const headroomMb = availableMb - minAvailableMb;
    return `memory projected child reserve unmet: availableMb=${availableMb}:requiredMb=${minAvailableMb}:childReserveMb=${childReserveMb}:projectedActiveChildren=${projected}:launchRequiredMb=${requiredMb}:launchHeadroomMb=${headroomMb}`;
  }
  return "";
}

function projectedLaunchErrorWithExternal(
  minAvailableMb,
  childReserveMb,
  projectedActiveChildren,
  externalAgentReserveMb,
  externalAgentCount,
  availableMb,
) {
  const childError = projectedLaunchError(
    minAvailableMb,
    childReserveMb,
    projectedActiveChildren,
    availableMb,
  );
  if (childError) return childError;

  const requiredMb = projectedLaunchRequiredWithExternal(
    minAvailableMb,
    childReserveMb,
    projectedActiveChildren,
    externalAgentReserveMb,
    externalAgentCount,
  );
  if (externalAgentReserveMb > 0 && availableMb < requiredMb) {
    const projected = projectedActiveChildren < 1 ? 1 : projectedActiveChildren;
    return (
      `memory external agent reserve unmet: availableMb=${availableMb}:requiredMb=${minAvailableMb}` +
      `:childReserveMb=${childReserveMb}:projectedActiveChildren=${projected}` +
      `:externalAgentReserveMb=${externalAgentReserveMb}:externalAgentCount=${externalAgentCount}` +
      `:externalAgentReservedMb=${externalAgentReserve(externalAgentReserveMb, externalAgentCount)}` +
      `:launchRequiredMb=${requiredMb}:launchHeadroomMb=${availableMb - minAvailableMb}`
    );
  }
  return "";
}

function projectedLaunchErrorWithExternalStats(
  minAvailableMb,
  childReserveMb,
  projectedActiveChildren,
  externalAgentReserveMb,
  externalAgentCount,
  externalAgentRssMb,
  availableMb,
) {
  const childError = projectedLaunchError(
    minAvailableMb,
    childReserveMb,
    projectedActiveChildren,
    availableMb,
  );
  if (childError) return childError;

  const requiredMb = projectedLaunchRequiredWithExternalStats(
    minAvailableMb,
    childReserveMb,
    projectedActiveChildren,
    externalAgentReserveMb,
    externalAgentCount,
    externalAgentRssMb,
  );
  if (externalAgentReserveMb > 0 && availableMb < requiredMb) {
    const projected = projectedActiveChildren < 1 ? 1 : projectedActiveChildren;
    return (
      `memory external agent reserve unmet: availableMb=${availableMb}:requiredMb=${minAvailableMb}` +
      `:childReserveMb=${childReserveMb}:projectedActiveChildren=${projected}` +
      `:externalAgentReserveMb=${externalAgentReserveMb}:externalAgentCount=${externalAgentCount}` +
      `:externalAgentRssMb=${externalAgentRssMb}` +
      `:externalAgentReservedMb=${externalAgentReservedMemory(externalAgentReserveMb, externalAgentCount, externalAgentRssMb)}` +
      `:launchRequiredMb=${requiredMb}:launchHeadroomMb=${availableMb - minAvailableMb}`
    );
  }
  return "";
}

function admissionReason(
  minAvailableMb,
  childReserveMb,
  projectedActiveChildren,
  externalAgentReserveMb,
  externalAgentCount,
  externalAgentRssMb,
  availableMb,
) {
  if (minAvailableMb > 0 && availableMb < minAvailableMb) return "host-memory-reserve";
  if (childReserveMb > 0 && availableMb < projectedLaunchRequired(minAvailableMb, childReserveMb, projectedActiveChildren)) {
    return "projected-child-memory-reserve";
  }
  if (
    externalAgentReserveMb > 0 &&
    availableMb < projectedLaunchRequiredWithExternalStats(
      minAvailableMb,
      childReserveMb,
      projectedActiveChildren,
      externalAgentReserveMb,
      externalAgentCount,
      externalAgentRssMb,
    )
  ) {
    return "external-agent-memory-reserve";
  }
  return "admitted";
}

function admissionRecommendedAction(reason) {
  if (reason === "admitted") return "launch-managed-job";
  if (reason === "host-memory-reserve") return "wait-for-memory-or-stop-only-managed-jobs-by-metadata";
  if (reason === "projected-child-memory-reserve") return "lower-concurrency-or-child-memory-budget";
  if (reason === "external-agent-memory-reserve") return "wait-for-external-agent-pressure-or-lower-concurrency";
  return "reduce-memory-pressure-without-killing-unrelated-processes";
}

function admissionDecision(
  minAvailableMb,
  childReserveMb,
  projectedActiveChildren,
  externalAgentReserveMb,
  externalAgentCount,
  externalAgentRssMb,
  availableMb,
) {
  const projected = projectedActiveChildren < 1 ? 1 : projectedActiveChildren;
  const blockingMessage = projectedLaunchErrorWithExternalStats(
    minAvailableMb,
    childReserveMb,
    projected,
    externalAgentReserveMb,
    externalAgentCount,
    externalAgentRssMb,
    availableMb,
  );
  const reason = blockingMessage
    ? admissionReason(
        minAvailableMb,
        childReserveMb,
        projected,
        externalAgentReserveMb,
        externalAgentCount,
        externalAgentRssMb,
        availableMb,
      )
    : "admitted";
  return {
    admitted: blockingMessage === "",
    status: blockingMessage === "" ? "admitted" : "blocked",
    reason,
    availableMb,
    requiredMb: projectedLaunchRequiredWithExternalStats(
      minAvailableMb,
      childReserveMb,
      projected,
      externalAgentReserveMb,
      externalAgentCount,
      externalAgentRssMb,
    ),
    headroomMb: availableMb - minAvailableMb,
    projectedActiveChildren: projected,
    externalAgentReservedMb: externalAgentReservedMemory(externalAgentReserveMb, externalAgentCount, externalAgentRssMb),
    blockingMessage,
    recommendedAction: admissionRecommendedAction(reason),
  };
}

function configuredChildLimit(configuredMaxChildren) {
  if (configuredMaxChildren < 1) return 1;
  return Math.min(configuredMaxChildren, 64);
}

function admittedChildCapacityWithExternalStats(
  minAvailableMb,
  childReserveMb,
  configuredMaxChildren,
  externalAgentReserveMb,
  externalAgentCount,
  externalAgentRssMb,
  availableMb,
) {
  const limit = configuredChildLimit(configuredMaxChildren);
  if (minAvailableMb > 0 && availableMb < minAvailableMb) return 0;
  const externalReservedMb = externalAgentReservedMemory(externalAgentReserveMb, externalAgentCount, externalAgentRssMb);
  let remainingMb = availableMb - minAvailableMb - externalReservedMb;
  if (remainingMb < 0) return 0;
  if (childReserveMb < 1) return limit;
  let capacity = 0;
  while (capacity < limit && remainingMb >= childReserveMb) {
    capacity += 1;
    remainingMb -= childReserveMb;
  }
  return capacity;
}

function concurrencyReason(configuredMaxChildren, admittedChildCapacity) {
  const limit = configuredChildLimit(configuredMaxChildren);
  if (admittedChildCapacity >= limit) return "configured-concurrency-admitted";
  if (admittedChildCapacity < 1) return "no-child-memory-capacity";
  return "configured-concurrency-exceeds-memory-capacity";
}

function concurrencyStatus(configuredMaxChildren, admittedChildCapacity) {
  const reason = concurrencyReason(configuredMaxChildren, admittedChildCapacity);
  if (reason === "configured-concurrency-admitted") return "admitted";
  if (reason === "no-child-memory-capacity") return "blocked";
  return "reduced";
}

function concurrencyRecommendedAction(reason) {
  if (reason === "configured-concurrency-admitted") return "launch-managed-job";
  if (reason === "configured-concurrency-exceeds-memory-capacity") return "lower-concurrency-to-admitted-child-capacity";
  if (reason === "no-child-memory-capacity") return "wait-for-memory-or-lower-concurrency-before-launch";
  return "inspect-memory-concurrency-admission";
}

function concurrencyDecision(
  minAvailableMb,
  childReserveMb,
  configuredMaxChildren,
  externalAgentReserveMb,
  externalAgentCount,
  externalAgentRssMb,
  availableMb,
) {
  const limit = configuredChildLimit(configuredMaxChildren);
  const capacity = admittedChildCapacityWithExternalStats(
    minAvailableMb,
    childReserveMb,
    configuredMaxChildren,
    externalAgentReserveMb,
    externalAgentCount,
    externalAgentRssMb,
    availableMb,
  );
  const reason = concurrencyReason(configuredMaxChildren, capacity);
  return {
    status: concurrencyStatus(configuredMaxChildren, capacity),
    reason,
    configuredMaxChildren,
    capacityLimit: limit,
    admittedChildCapacity: capacity,
    effectiveMaxChildren: capacity,
    requiredMb: projectedLaunchRequiredWithExternalStats(
      minAvailableMb,
      childReserveMb,
      limit,
      externalAgentReserveMb,
      externalAgentCount,
      externalAgentRssMb,
    ),
    recommendedAction: concurrencyRecommendedAction(reason),
  };
}

includes("module ResourceGuardPolicy");
includes("record ResourceGuardAdmissionDecision =");
includes("record ResourceGuardConcurrencyDecision =");
includes("resourceGuardMaxConcurrencyCapacityLimit");
includes("resourceGuardMemoryLaunchRequiredMb");
includes("intAdd minAvailableMb childReserveMb");
includes("intSubtract availableMb minAvailableMb");
includes("resourceGuardMemoryProjectedLaunchRequiredMb");
includes("resourceGuardMemoryProjectedLaunchRequiredWithExternalMb");
includes("resourceGuardMemoryProjectedLaunchRequiredWithExternalStatsMb");
includes("resourceGuardExternalAgentReserveMb");
includes("resourceGuardExternalAgentReservedMemoryMb");
includes("resourceGuardExternalAgentMemoryStatsReserveBlockMessage");
includes("resourceGuardProjectedChildCount");
includes("resourceGuardMemoryLaunchReserveMet");
includes("resourceGuardMemoryLaunchErrorFromAvailable");
includes("resourceGuardMemoryProjectedLaunchErrorFromAvailable");
includes("resourceGuardMemoryProjectedLaunchErrorWithExternalFromAvailable");
includes("resourceGuardMemoryProjectedLaunchErrorWithExternalStatsFromAvailable");
includes("resourceGuardAdmissionReason");
includes("resourceGuardAdmissionRecommendedAction");
includes("resourceGuardMemoryAdmissionDecisionWithExternalStats");
includes("resourceGuardMemoryAdmittedChildCapacityWithExternalStats");
includes("resourceGuardMemoryConcurrencyDecisionWithExternalStats");
includes("configured-concurrency-exceeds-memory-capacity");
includes("lower-concurrency-to-admitted-child-capacity");
includes("wait-for-memory-or-stop-only-managed-jobs-by-metadata");
includes("lower-concurrency-or-child-memory-budget");
includes("wait-for-external-agent-pressure-or-lower-concurrency");
includes("memory child reserve unmet");
includes("memory projected child reserve unmet");
includes("memory external agent reserve unmet");
includes("projectedActiveChildren=");
includes("externalAgentReserveMb=");
includes("externalAgentRssMb=");
includes("externalAgentReservedMb=");
includes("launchRequiredMb=");
includes("launchHeadroomMb=");

assert(launchRequired(1000, 256) === 1256, "child reserve should add to launch requirement");
assert(projectedLaunchRequired(1000, 256, 2) === 1512, "second child should reserve two child budgets");
assert(externalAgentReserve(512, 3) === 1536, "external agent reserve should scale by process count");
assert(
  externalAgentReservedMemory(512, 3, 64) === 1600,
  "external agent reserved memory should include current RSS plus reserve headroom",
);
assert(
  externalAgentReservedMemory(0, 3, 64) === 0,
  "zero external reserve should disable external agent accounting",
);
assert(
  projectedLaunchRequiredWithExternal(1000, 256, 2, 512, 3) === 3048,
  "external reserve should add to projected launch requirement",
);
assert(
  projectedLaunchRequiredWithExternalStats(1000, 256, 2, 512, 3, 64) === 3112,
  "external RSS should add to projected launch requirement",
);
assert(
  projectedLaunchRequiredWithExternalStats(1000, 256, 2, 0, 3, 64) === 1512,
  "zero external reserve should ignore unmanaged RSS",
);
assert(launchRequired(1000, 0) === 1000, "zero child reserve should keep the global floor");
assert(launchError(1000, 256, 999).includes("memory reserve unmet"), "below global reserve should block first");
assert(launchError(1000, 256, 1000).includes("memory child reserve unmet"), "global floor alone should not launch a child");
assert(launchError(1000, 256, 1000).includes("launchHeadroomMb=0"), "child reserve block should include headroom");
assert(launchError(1000, 256, 1256) === "", "launch requirement should allow the child");
assert(projectedLaunchError(1000, 256, 2, 1256).includes("memory projected child reserve unmet"), "first-child floor should not launch a second projected child");
assert(projectedLaunchError(1000, 256, 2, 1256).includes("projectedActiveChildren=2"), "projected child block should report projected count");
assert(projectedLaunchError(1000, 256, 2, 1512) === "", "projected launch requirement should allow the second child");
assert(
  projectedLaunchErrorWithExternal(1000, 256, 2, 512, 3, 1512).includes("memory external agent reserve unmet"),
  "projected requirement alone should not launch beside unmanaged agents",
);
assert(
  projectedLaunchErrorWithExternal(1000, 256, 2, 512, 3, 1512).includes("externalAgentReservedMb=1536"),
  "external reserve block should report reserved memory",
);
assert(
  projectedLaunchErrorWithExternalStats(1000, 256, 2, 512, 3, 64, 3048).includes("memory external agent reserve unmet"),
  "stats external reserve should block when RSS pushes requirement higher",
);
assert(
  projectedLaunchErrorWithExternalStats(1000, 256, 2, 512, 3, 64, 3048).includes("externalAgentRssMb=64"),
  "stats external reserve block should report RSS",
);
assert(
  projectedLaunchErrorWithExternalStats(1000, 256, 2, 512, 3, 64, 3048).includes("externalAgentReservedMb=1600"),
  "stats external reserve block should report RSS plus headroom",
);
assert(
  projectedLaunchErrorWithExternalStats(1000, 256, 2, 0, 3, 64, 1512) === "",
  "zero external reserve should not report a stats external block",
);
assert(
  projectedLaunchErrorWithExternal(1000, 256, 2, 512, 3, 3048) === "",
  "projected plus external reserve should allow launch",
);
assert(
  projectedLaunchErrorWithExternalStats(1000, 256, 2, 512, 3, 64, 3112) === "",
  "projected plus stats external reserve should allow launch",
);
const admittedDecision = admissionDecision(1000, 256, 2, 512, 3, 64, 3112);
assert(admittedDecision.admitted === true, "admitted decision should allow launch");
assert(admittedDecision.status === "admitted", "admitted decision should report admitted status");
assert(admittedDecision.reason === "admitted", "admitted decision should use admitted reason");
assert(admittedDecision.recommendedAction === "launch-managed-job", "admitted decision should launch managed job");
assert(admittedDecision.requiredMb === 3112, "admitted decision should report total requirement");
assert(admittedDecision.externalAgentReservedMb === 1600, "admitted decision should report external reserve");

const childBlockedDecision = admissionDecision(1000, 256, 2, 0, 0, 0, 1256);
assert(childBlockedDecision.admitted === false, "child blocked decision should block");
assert(childBlockedDecision.status === "blocked", "child blocked decision should report blocked status");
assert(childBlockedDecision.reason === "projected-child-memory-reserve", "child blocked decision should explain child reserve");
assert(childBlockedDecision.recommendedAction === "lower-concurrency-or-child-memory-budget", "child block should lower concurrency");
assert(childBlockedDecision.blockingMessage.includes("memory projected child reserve unmet"), "child block should carry block message");

const externalBlockedDecision = admissionDecision(1000, 256, 2, 512, 3, 64, 3048);
assert(externalBlockedDecision.admitted === false, "external blocked decision should block");
assert(externalBlockedDecision.reason === "external-agent-memory-reserve", "external block should explain external pressure");
assert(
  externalBlockedDecision.recommendedAction === "wait-for-external-agent-pressure-or-lower-concurrency",
  "external block should wait or lower concurrency",
);
assert(externalBlockedDecision.blockingMessage.includes("externalAgentRssMb=64"), "external block should carry RSS evidence");

const admittedConcurrency = concurrencyDecision(1000, 256, 2, 512, 3, 64, 3112);
assert(admittedConcurrency.status === "admitted", "configured concurrency should be admitted when both children fit");
assert(admittedConcurrency.reason === "configured-concurrency-admitted", "admitted concurrency should explain configured fit");
assert(admittedConcurrency.admittedChildCapacity === 2, "admitted concurrency should report capacity");
assert(admittedConcurrency.effectiveMaxChildren === 2, "admitted concurrency should keep configured limit");
assert(admittedConcurrency.requiredMb === 3112, "admitted concurrency should report configured requirement");

const reducedConcurrency = concurrencyDecision(1000, 256, 2, 0, 0, 0, 1256);
assert(reducedConcurrency.status === "reduced", "configured concurrency should reduce when only one child fits");
assert(
  reducedConcurrency.reason === "configured-concurrency-exceeds-memory-capacity",
  "reduced concurrency should explain configured excess",
);
assert(reducedConcurrency.admittedChildCapacity === 1, "reduced concurrency should report the safe capacity");
assert(
  reducedConcurrency.recommendedAction === "lower-concurrency-to-admitted-child-capacity",
  "reduced concurrency should tell planners to lower concurrency",
);

const blockedConcurrency = concurrencyDecision(1000, 256, 2, 0, 0, 0, 999);
assert(blockedConcurrency.status === "blocked", "configured concurrency should block when no child fits");
assert(blockedConcurrency.reason === "no-child-memory-capacity", "blocked concurrency should explain no child capacity");
assert(
  blockedConcurrency.recommendedAction === "wait-for-memory-or-lower-concurrency-before-launch",
  "blocked concurrency should wait before launching",
);

const cappedConcurrency = concurrencyDecision(1000, 1, 1000, 0, 0, 0, 2000);
assert(cappedConcurrency.configuredMaxChildren === 1000, "configured concurrency should report the original limit");
assert(cappedConcurrency.capacityLimit === 64, "configured concurrency capacity should be capped");
assert(cappedConcurrency.admittedChildCapacity === 64, "capacity calculation should stop at the cap");

console.log("resource-guard-policy-ok");
NODE
