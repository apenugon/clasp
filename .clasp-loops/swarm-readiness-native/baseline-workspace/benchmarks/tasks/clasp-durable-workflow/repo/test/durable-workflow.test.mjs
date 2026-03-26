import assert from "node:assert/strict";

import { runDurableWorkflowDemo } from "../demo.mjs";

const [sourceCompiledModulePath, targetCompiledModulePath, stateDirectory] = process.argv.slice(2);

if (!sourceCompiledModulePath || !targetCompiledModulePath) {
  throw new Error(
    "usage: node test/durable-workflow.test.mjs <compiled-v1> <compiled-v2> [state-dir]"
  );
}

const result = await runDurableWorkflowDemo(
  sourceCompiledModulePath,
  targetCompiledModulePath,
  stateDirectory
);

assert.equal(result.handoffStatus, "handoff");
assert.equal(result.handoffOperator, "release-bot");
assert.equal(result.overlapStatus, "overlap");
assert.equal(result.overlapStartedAt, 1000);
assert.equal(result.drainingStatus, "draining");
assert.equal(result.drainingVersionTagged, true);
assert.equal(result.activatedStatus, "activated");
assert.equal(result.activatedHealthStatus, "healthy");
assert.equal(result.activatedRollbackAvailable, true);
assert.equal(result.activatedCount, 8);
assert.equal(result.activatedTargetTagged, true);
assert.equal(result.blockedStatus, "blocked");
assert.equal(result.blockedHealthStatus, "probe-warming");
assert.equal(result.blockedRollbackAvailable, true);
assert.equal(result.blockedCount, 8);
assert.equal(result.autoRollbackStatus, "rolled_back");
assert.equal(result.autoRollbackTriggerKind, "health_check_failed");
assert.equal(result.autoRollbackTriggerReason, "probe-failed");
assert.equal(result.autoRollbackTriggerAt, 1004);
assert.equal(result.autoRollbackCount, 5);
assert.equal(result.manualRollbackStatus, "rolled_back");
assert.equal(result.manualRollbackTriggerKind, "error_budget");
assert.equal(result.manualRollbackTriggerReason, "latency-spike");
assert.equal(result.manualRollbackTriggerAt, 1005);
assert.equal(result.manualRollbackCount, 5);
assert.equal(result.manualRollbackSupervisor, "RollbackSupervisor");
assert.equal(result.autoRollbackAuditType, "rollback");
assert.equal(result.autoRollbackAuditTriggerKind, "health_check_failed");
assert.equal(result.manualRollbackAuditType, "rollback");
assert.equal(result.manualRollbackAuditTriggerKind, "error_budget");
assert.equal(result.retiredStatus, "retired");
assert.equal(result.retiredReason, "drained");
assert.equal(result.remainingVersionCount, 1);

console.log(JSON.stringify(result));
