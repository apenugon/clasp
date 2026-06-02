#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

node - "$project_root" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");

const [projectRoot] = process.argv.slice(2);

function read(relativePath) {
  return fs.readFileSync(path.join(projectRoot, relativePath), "utf8");
}

function assert(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}

const backend = read("examples/swarm-native/AgentBackend.clasp");
const harness = read("examples/swarm-native/AgentBackendHarness.clasp");
const feedbackLoop = read("examples/swarm-native/FeedbackLoop.clasp");
const localAgent = read("examples/swarm-native/LocalAgent.clasp");
const localPlanner = read("examples/swarm-native/LocalPlanner.clasp");
const managerConfig = read("examples/swarm-native/GoalManagerConfig.clasp");
const managerBackendConfig = read("examples/swarm-native/GoalManagerAgentBackendConfig.clasp");
const managerTypes = read("examples/swarm-native/GoalManagerTypes.clasp");
const managerPreludeProject = read("examples/swarm-native/GoalManagerPreludeProject.clasp");
const managerPlanner = read("examples/swarm-native/GoalManagerBootstrapPlanner.clasp");
const managerPlannerFlow = read("examples/swarm-native/GoalManagerPlannerFlow.clasp");
const managerStateView = read("examples/swarm-native/GoalManagerStateView.clasp");
const managerReports = read("examples/swarm-native/GoalManagerManagerReports.clasp");
const managerTasks = read("examples/swarm-native/GoalManagerBootstrapTasks.clasp");
const managerService = read("examples/swarm-native/GoalManagerServiceMain.clasp");
const agentCommandTest = read("scripts/test-agent-command-template.sh");
const policyRecord = backend.match(/record AgentBackendPolicy = \{([\s\S]*?)\n\}/)?.[1] ?? "";
const policySummaryRecord = backend.match(/record AgentBackendPolicySummary = \{([\s\S]*?)\n\}/)?.[1] ?? "";
const capabilitySummaryRecord = backend.match(/record AgentBackendCapabilitySummary = \{([\s\S]*?)\n\}/)?.[1] ?? "";

assert(backend.includes("record AgentBackendPolicy ="), "agent backend should expose a typed backend policy");
assert(backend.includes("record AgentBackendPolicySummary ="), "agent backend should expose policy summary evidence");
assert(backend.includes("record AgentBackendCapabilityProfile ="), "agent backend should expose a typed backend capability profile");
assert(backend.includes("record AgentBackendCapabilitySummary ="), "agent backend should expose capability summary evidence");
assert(!policyRecord.includes("blockingGaps"), "backend policy should stay declarative; diagnostics belong on the summary");
assert(!policyRecord.includes("requiredClosure"), "backend policy should stay declarative; closure belongs on the summary");
assert(policySummaryRecord.includes("blockingGaps : [Str]"), "policy summary should include blocking gaps");
assert(policySummaryRecord.includes("requiredClosure : [Str]"), "policy summary should include required closure");
assert(policySummaryRecord.includes("missingPlaceholders : [Str]"), "policy summary should include missing placeholders");
assert(policySummaryRecord.includes("recommendedTemplate : [Str]"), "policy summary should include recommended template");
assert(policySummaryRecord.includes("validationMessages : [Str]"), "policy summary should include all validation messages");
assert(capabilitySummaryRecord.includes("standaloneReady : Bool"), "capability summary should expose standalone readiness");
assert(capabilitySummaryRecord.includes("roleCoverage : [Str]"), "capability summary should expose role coverage");
assert(capabilitySummaryRecord.includes("supportsChildTaskPlanning : Bool"), "capability summary should expose child-task planning support");
assert(capabilitySummaryRecord.includes("supportsStructuredReports : Bool"), "capability summary should expose structured-report support");
assert(capabilitySummaryRecord.includes("requiresExternalModel : Bool"), "capability summary should expose external model dependency");
assert(backend.includes("agentBackendStandalonePolicy : AgentBackendPolicy"), "agent backend should expose standalone policy");
assert(backend.includes("agentBackendLocalClaspCapabilityProfile : AgentBackendCapabilityProfile"), "agent backend should expose a local Clasp capability profile");
assert(backend.includes("agentBackendCodexCapabilityProfile : AgentBackendCapabilityProfile"), "agent backend should expose a Codex capability profile");
assert(backend.includes("agentBackendBuilderVerifierCapabilityProfile : AgentBackendCapabilityProfile"), "agent backend should expose a builder/verifier-only capability profile");
assert(backend.includes("agentBackendUnknownCapabilityProfile : Str -> AgentBackendCapabilityProfile"), "agent backend should expose unknown capability profiles for configured names");
assert(backend.includes("agentBackendInferredCapabilityProfile : AgentBackendSpec -> AgentBackendCapabilityProfile"), "agent backend should infer capability profiles from backend shape");
assert(backend.includes("agentBackendCapabilityProfileNamedOrDefault : Str -> AgentBackendCapabilityProfile -> AgentBackendCapabilityProfile"), "agent backend should resolve named capability profiles with a fallback");
assert(backend.includes("agentBackendCapabilityProfileForBackend : Str -> AgentBackendSpec -> AgentBackendCapabilityProfile"), "agent backend should resolve capability profiles for runtime backends");
assert(backend.includes("agentBackendCapabilityRoleCoverage : AgentBackendCapabilityProfile -> [Str]"), "agent backend should expose capability role coverage");
assert(backend.includes("agentBackendStandaloneCapabilityValidationMessages : AgentBackendCapabilityProfile -> AgentBackendSpec -> [Str]"), "agent backend should validate standalone capability profiles");
assert(backend.includes("agentBackendStandaloneCapabilitySummary : AgentBackendCapabilityProfile -> AgentBackendSpec -> AgentBackendCapabilitySummary"), "agent backend should summarize standalone capability profiles");
assert(backend.includes("agentBackendPolicyValidationMessage : AgentBackendPolicy -> AgentBackendSpec -> Str"), "agent backend should validate a backend against a policy");
assert(backend.includes("agentBackendPolicyValidationMessages : AgentBackendPolicy -> AgentBackendSpec -> [Str]"), "agent backend should expose all policy validation messages");
assert(backend.includes("agentBackendPolicyValid : AgentBackendPolicy -> AgentBackendSpec -> Bool"), "agent backend should expose policy validity");
assert(backend.includes("agentBackendPolicySummary : Str -> AgentBackendPolicy -> AgentBackendSpec -> AgentBackendPolicySummary"), "agent backend should summarize policy compliance");
assert(backend.includes("agentBackendStandalonePolicySummary : AgentBackendSpec -> AgentBackendPolicySummary"), "agent backend should summarize standalone policy compliance");
assert(backend.includes("agentBackendPolicyBlockingGapsForMessage : Str -> [Str]"), "agent backend should expose policy blocking-gap diagnostics");
assert(backend.includes("agentBackendPolicyRequiredClosureForMessage : Str -> [Str]"), "agent backend should expose policy closure diagnostics");
assert(backend.includes("agentBackendPolicyBlockingGapsForMessages : [Str] -> [Str]"), "agent backend should expose all policy blocking-gap diagnostics");
assert(backend.includes("agentBackendPolicyRequiredClosureForMessages : [Str] -> [Str]"), "agent backend should expose all policy closure diagnostics");
assert(backend.includes("agentBackendStandaloneRequiredPlaceholders : [Str]"), "agent backend should expose standalone required placeholders");
assert(backend.includes("agentBackendStandaloneRecommendedTemplate : [Str]"), "agent backend should expose a reusable standalone command template");
assert(backend.includes("agentBackendClaspRunTemplate : Str -> [Str]"), "agent backend should expose a Clasp run command template helper");
assert(backend.includes("agentBackendLocalAgentTemplate : [Str]"), "agent backend should expose a reusable local-agent Clasp template");
assert(backend.includes("agentBackendLocalPlannerTemplate : [Str]"), "agent backend should expose a reusable local-planner Clasp template");
assert(backend.includes("agentBackendPolicyMissingPlaceholders : AgentBackendPolicy -> AgentBackendSpec -> [Str]"), "agent backend should expose policy-specific missing placeholders");
assert(backend.includes("agentBackendPolicyRecommendedTemplate : AgentBackendPolicy -> [Str]"), "agent backend should expose policy-specific recommended templates");
assert(backend.includes("blockingGaps : [Str]"), "policy summary should include blocking gaps");
assert(backend.includes("requiredClosure : [Str]"), "policy summary should include required closure steps");
assert(backend.includes("missingPlaceholders : [Str]"), "policy summary should include missing placeholders");
assert(backend.includes("recommendedTemplate : [Str]"), "policy summary should include a recommended template");
assert(backend.includes("validationMessages : [Str]"), "policy summary should include all validation messages");
assert(backend.includes("agentBackendStandaloneCapable : AgentBackendSpec -> Bool"), "agent backend should expose standalone capability");
assert(backend.includes("agent-backend-policy-disallows-codex-fallback"), "standalone policy should reject Codex fallback");
assert(backend.includes("agent-backend-policy-requires-prompt-path"), "standalone policy should require durable prompt-path transport");
assert(backend.includes("agent-backend-policy-requires-schema-path"), "policy should be able to require schema transport");
assert(backend.includes("agent-backend-policy-requires-workspace-root"), "policy should be able to require workspace transport");
assert(backend.includes("agent-backend-capability-missing-planner-role"), "capability profile should reject plannerless standalone backends");
assert(backend.includes("agent-backend-capability-missing-structured-reports"), "capability profile should reject backends without structured reports");
assert(backend.includes("backend policy requires a configured non-Codex command template"), "standalone policy diagnostics should explain Codex fallback blockers");
assert(backend.includes("Set CLASP_LOOP_AGENT_COMMAND_JSON or CLASP_MANAGER_PLANNER_AGENT_COMMAND_JSON to a non-Codex backend template."), "standalone policy diagnostics should give a repair step");
assert(backend.includes("Use agentBackendStandaloneRecommendedTemplate as the minimum command shape for standalone agents."), "standalone policy diagnostics should point to the reusable template");
assert(backend.includes("\"{schema_path}\""), "standalone backend template should include schema placeholder");
assert(backend.includes("\"{report_path}\""), "standalone backend template should include report placeholder");
assert(backend.includes("\"{workspace_root}\""), "standalone backend template should include workspace placeholder");

assert(harness.includes("standaloneTemplateValidationMessage"), "agent backend harness should report standalone template validation");
assert(harness.includes("standaloneCodexValidationMessage"), "agent backend harness should report standalone Codex validation");
assert(harness.includes("strictPromptPathValidationMessage"), "agent backend harness should report strict prompt-path validation");
assert(harness.includes("standaloneTemplatePolicy : AgentBackendPolicySummary"), "agent backend harness should report template policy summary");
assert(harness.includes("standaloneCodexPolicy : AgentBackendPolicySummary"), "agent backend harness should report Codex policy summary");
assert(harness.includes("strictWarningPolicy : AgentBackendPolicySummary"), "agent backend harness should report multi-gap warning policy summary");
assert(harness.includes("standaloneTemplateCapability : AgentBackendCapabilitySummary"), "agent backend harness should report local Clasp capability summary");
assert(harness.includes("standaloneCodexCapability : AgentBackendCapabilitySummary"), "agent backend harness should report Codex capability summary");
assert(harness.includes("builderVerifierCapability : AgentBackendCapabilitySummary"), "agent backend harness should report a builder/verifier-only capability summary");
assert(harness.includes("agentBackendCapabilityProfileForBackend : Str -> AgentBackendSpec -> AgentBackendCapabilityProfile"), "agent backend harness should mirror runtime capability profile resolution");
assert(harness.includes("agentBackendStandaloneCapabilitySummary agentBackendLocalClaspCapabilityProfile templateBackend"), "agent backend harness should summarize local Clasp standalone capabilities");
assert(harness.includes("agentBackendStandaloneCapabilitySummary agentBackendBuilderVerifierCapabilityProfile templateBackend"), "agent backend harness should summarize missing planner capability evidence");
assert(harness.includes("agentBackendStandaloneRecommendedTemplate : [Str]"), "agent backend harness should mirror the standalone command template");
assert(harness.includes("claspRunCommand : [Str]"), "agent backend harness should report a rendered Clasp run backend command");
assert(harness.includes("localAgentTemplate : [Str]"), "agent backend harness should report the reusable local-agent template");
assert(harness.includes("localPlannerTemplate : [Str]"), "agent backend harness should report the reusable local-planner template");
assert(agentCommandTest.includes("Clasp run backend should use the ordinary run entrypoint"), "agent backend runtime harness should assert Clasp run command rendering");
assert(agentCommandTest.includes("agent-backend-policy-disallows-codex-fallback"), "agent backend runtime harness should assert Codex fallback rejection");
assert(agentCommandTest.includes("agent-backend-policy-requires-prompt-path"), "agent backend runtime harness should assert prompt-path policy rejection");
assert(agentCommandTest.includes("standaloneTemplatePolicy.policyName"), "agent backend runtime harness should assert policy summary evidence");
assert(agentCommandTest.includes("standaloneCodexPolicy.blockingGaps.includes"), "agent backend runtime harness should assert policy blocking gaps");
assert(agentCommandTest.includes("standaloneCodexPolicy.validationMessages.includes"), "agent backend runtime harness should assert policy validation messages");
assert(agentCommandTest.includes("standaloneCodexPolicy.requiredClosure.includes"), "agent backend runtime harness should assert policy closure steps");
assert(agentCommandTest.includes("standaloneCodexPolicy.missingPlaceholders.includes"), "agent backend runtime harness should assert policy missing placeholders");
assert(agentCommandTest.includes("standaloneCodexPolicy.recommendedTemplate.includes"), "agent backend runtime harness should assert policy recommended template");
assert(agentCommandTest.includes("strictWarningPolicy.validationMessages.includes"), "agent backend runtime harness should assert multi-gap policy validation messages");
assert(agentCommandTest.includes("standaloneTemplateCapability.profileName"), "agent backend runtime harness should assert capability profile names");
assert(agentCommandTest.includes("standaloneCodexCapability.requiresExternalModel"), "agent backend runtime harness should assert external model capability evidence");
assert(agentCommandTest.includes("builderVerifierCapability.validationMessages.includes"), "agent backend runtime harness should assert missing capability messages");

assert(feedbackLoop.includes("CLASP_LOOP_REQUIRE_STANDALONE_AGENT_BACKEND_JSON"), "feedback loop should have a standalone backend requirement switch");
assert(feedbackLoop.includes("CLASP_REQUIRE_STANDALONE_AGENT_BACKEND_JSON"), "feedback loop should inherit the common standalone backend switch");
assert(feedbackLoop.includes("loopAgentBackendValidationMessage : Str"), "feedback loop should centralize backend validation");
assert(feedbackLoop.includes("agentBackendPolicy : AgentBackendPolicySummary"), "feedback loop status should expose backend policy summary");
assert(feedbackLoop.includes("agentBackendCapability : AgentBackendCapabilitySummary"), "feedback loop status should expose backend capability summary");
assert(feedbackLoop.includes("loopAgentBackendPolicySummary : AgentBackendPolicySummary"), "feedback loop should compute backend policy summary");
assert(feedbackLoop.includes("agentCapabilityProfileName : Str"), "feedback loop should read the configured capability profile");
assert(feedbackLoop.includes("loopAgentBackendCapabilityProfile : AgentBackendCapabilityProfile"), "feedback loop should resolve the configured capability profile");
assert(feedbackLoop.includes("loopAgentBackendCapabilitySummary : AgentBackendCapabilitySummary"), "feedback loop should compute backend capability summary");
assert(feedbackLoop.includes("loopAgentBackendPolicyPromptSection : Str"), "feedback loop prompts should expose backend policy repair context");
assert(feedbackLoop.includes("loopAgentBackendCapabilityPromptSection : Str"), "feedback loop prompts should expose backend capability repair context");
assert(feedbackLoop.includes("loopAgentBackendConfigRepairReport : Str -> Str"), "feedback loop should expose machine-actionable config repair reports");
assert(feedbackLoop.includes("\"backendConfigRepair=agent-backend\""), "feedback loop config failures should identify backend repair action");
assert(feedbackLoop.includes("loopAgentBackendConfigRepairReport backendError"), "feedback loop readiness should return structured backend repair evidence");
assert(feedbackLoop.includes("agentBackendPolicyValidationMessage agentBackendStandalonePolicy loopAgentBackend"), "feedback loop should enforce standalone policy when requested");
assert(feedbackLoop.includes("policyBlockingGaps="), "feedback loop prompts should expose backend policy blocking gaps");
assert(feedbackLoop.includes("policyMessages="), "feedback loop prompts should expose all backend policy messages");
assert(feedbackLoop.includes("policyRequiredClosure="), "feedback loop prompts should expose backend policy closure");
assert(feedbackLoop.includes("policyMissingPlaceholders="), "feedback loop prompts should expose backend policy missing placeholders");
assert(feedbackLoop.includes("policyRecommendedTemplate="), "feedback loop prompts should expose backend policy recommended template");
assert(feedbackLoop.includes("Agent backend capability repair:"), "feedback loop prompts should include a capability repair section");
assert(feedbackLoop.includes("capabilityMessages="), "feedback loop prompts should expose capability validation messages");
assert(feedbackLoop.includes("capabilityRequiredClosure="), "feedback loop prompts should expose capability closure steps");
assert(feedbackLoop.includes("builderFeedbackSection,\n  loopAgentBackendPolicyPromptSection"), "builder prompt should include backend policy repair context");
assert(feedbackLoop.includes("verifierPolicySection,\n  loopAgentBackendPolicyPromptSection"), "verifier prompt should include backend policy repair context");
assert(feedbackLoop.includes("loopAgentBackendPolicyPromptSection,\n  loopAgentBackendCapabilityPromptSection"), "builder and verifier prompts should include backend capability repair context after policy context");
assert(localAgent.includes("promptHasAgentBackendPolicyRepair : Str -> Bool"), "local agent should detect backend policy repair context");
assert(localAgent.includes("textIncludes prompt \"backendConfigRepair=agent-backend\""), "local agent should detect compact backend config repair markers");
assert(localAgent.includes("textIncludes prompt \"policyMessages=\""), "local agent should require all backend policy messages before claiming repair-context coverage");
assert(localAgent.includes("clasp-local-agent-backend-policy-repair"), "local agent should record backend policy repair coverage");
assert(localAgent.includes("local Clasp agent consumed backend policy repair context"), "local agent should report backend policy repair evidence");
assert(localPlanner.includes("promptHasPlannerBackendPolicyRepair : Str -> Bool"), "local planner should detect backend policy repair context");
assert(localPlanner.includes("textIncludes prompt \"plannerBackendConfigRepair=agent-backend\""), "local planner should detect compact planner backend config repair markers");
assert(localPlanner.includes("textIncludes prompt \"backendConfigRepair=agent-backend\""), "local planner should detect compact loop backend config repair markers");
assert(localPlanner.includes("clasp-local-planner-backend-policy-repair"), "local planner should record backend policy repair coverage");
assert(agentCommandTest.includes("local builder should record backend policy repair coverage"), "agent backend runtime harness should assert local builder backend policy repair coverage");
assert(agentCommandTest.includes("local verifier should report backend policy repair evidence"), "agent backend runtime harness should assert local verifier backend policy repair evidence");

assert(managerConfig.includes("import GoalManagerAgentBackendConfig"), "GoalManager config should import backend config");
assert(managerBackendConfig.includes("requireStandaloneAgentBackend : Bool"), "GoalManager backend config should read common standalone backend policy");
assert(managerBackendConfig.includes("loopRequireStandaloneAgentBackend : Bool"), "GoalManager backend config should read child-loop standalone backend policy");
assert(managerBackendConfig.includes("plannerRequireStandaloneAgentBackend : Bool"), "GoalManager backend config should read planner standalone backend policy");
assert(managerBackendConfig.includes("CLASP_MANAGER_REQUIRE_STANDALONE_PLANNER_AGENT_BACKEND_JSON"), "GoalManager backend config should expose planner-specific standalone policy");
assert(managerBackendConfig.includes("agentCapabilityProfileName : Str"), "GoalManager backend config should read the child agent capability profile");
assert(managerBackendConfig.includes("plannerAgentCapabilityProfileName : Str"), "GoalManager backend config should read the planner capability profile");
assert(managerTypes.includes("plannerBackend : AgentBackendSummary"), "GoalManager status should expose planner backend summary");
assert(managerTypes.includes("plannerBackendPolicy : AgentBackendPolicySummary"), "GoalManager status should expose planner backend policy summary");
assert(managerTypes.includes("plannerBackendCapability : AgentBackendCapabilitySummary"), "GoalManager status should expose planner backend capability summary");
assert(managerPreludeProject.includes("managerPlannerBackendPolicySummary : AgentBackendPolicySummary"), "GoalManager should compute reusable planner backend policy summary");
assert(managerPreludeProject.includes("managerPlannerBackendCapabilitySummary : AgentBackendCapabilitySummary"), "GoalManager should compute reusable planner backend capability summary");
assert(managerStateView.includes("plannerBackend = managerPlannerBackendSummary"), "GoalManager status view should include planner backend summary");
assert(managerStateView.includes("plannerBackendPolicy = managerPlannerBackendPolicySummary"), "GoalManager status view should include planner backend policy summary");
assert(managerStateView.includes("plannerBackendCapability = managerPlannerBackendCapabilitySummary"), "GoalManager status view should include planner backend capability summary");
assert(managerReports.includes("plannerBackend = managerPlannerBackendSummary"), "GoalManager manager reports should include planner backend summary");
assert(managerReports.includes("plannerBackendPolicy = managerPlannerBackendPolicySummary"), "GoalManager manager reports should include planner backend policy summary");
assert(managerReports.includes("plannerBackendCapability = managerPlannerBackendCapabilitySummary"), "GoalManager manager reports should include planner backend capability summary");
assert(managerPlanner.includes("agentBackendPolicyValidationMessage agentBackendStandalonePolicy plannerAgentBackend"), "GoalManager planner should enforce standalone policy when requested");
assert(managerPlanner.includes("plannerAgentBackendPolicySummary : AgentBackendPolicySummary"), "GoalManager planner should compute policy summary");
assert(managerPlanner.includes("plannerAgentBackendPolicyRepairText : Str"), "GoalManager planner should render policy repair evidence");
assert(managerPlanner.includes("plannerAgentBackendCapabilitySummary : AgentBackendCapabilitySummary"), "GoalManager planner should compute capability summary");
assert(managerPlanner.includes("plannerAgentBackendCapabilityText : Str"), "GoalManager planner should render capability repair evidence");
assert(managerPlanner.includes("plannerAgentBackendConfigRepairText : Str -> Str"), "GoalManager planner should render machine-actionable config repair reports");
assert(managerPlanner.includes("\"plannerBackendConfigRepair=agent-backend\""), "GoalManager planner config failures should identify backend repair action");
assert(managerPlannerFlow.includes("plannerAgentBackendConfigRepairText plannerBackendError"), "GoalManager planner launch failure should include structured backend repair evidence");
assert(managerPlanner.includes("policyValid="), "GoalManager planner prompt/status should surface policy validity");
assert(managerPlanner.includes("policyMessage="), "GoalManager planner prompt/status should surface policy message");
assert(managerPlanner.includes("standaloneRequired="), "GoalManager planner prompt/status should surface standalone requirement");
assert(managerPlanner.includes("policyBlockingGaps="), "GoalManager planner prompt/status should surface blocking gaps");
assert(managerPlanner.includes("policyMessages="), "GoalManager planner prompt/status should surface all policy messages");
assert(managerPlanner.includes("policyRequiredClosure="), "GoalManager planner prompt/status should surface required closure");
assert(managerPlanner.includes("policyMissingPlaceholders="), "GoalManager planner prompt/status should surface missing placeholders");
assert(managerPlanner.includes("policyRecommendedTemplate="), "GoalManager planner prompt/status should surface recommended templates");
assert(managerPlanner.includes("Planner agent backend capability repair:"), "GoalManager planner prompt/status should surface capability repair context");
assert(managerPlanner.includes("capabilityMessages="), "GoalManager planner prompt/status should surface capability messages");
assert(managerPlanner.includes("capabilityRequiredClosure="), "GoalManager planner prompt/status should surface capability closure");
assert(managerTasks.includes("CLASP_LOOP_REQUIRE_STANDALONE_AGENT_BACKEND_JSON"), "GoalManager child loop env should propagate standalone policy");
assert(managerTasks.includes("CLASP_LOOP_AGENT_CAPABILITY_PROFILE_JSON"), "GoalManager child loop env should propagate child capability profiles");
assert(managerService.includes("CLASP_LOOP_REQUIRE_STANDALONE_AGENT_BACKEND_JSON"), "GoalManager service env should propagate standalone policy");
assert(managerService.includes("CLASP_LOOP_AGENT_CAPABILITY_PROFILE_JSON"), "GoalManager service env should propagate child capability profiles");
assert(managerService.includes("CLASP_MANAGER_PLANNER_AGENT_CAPABILITY_PROFILE_JSON"), "GoalManager service env should propagate planner capability profiles");

console.log("agent-backend-static-ok");
NODE
