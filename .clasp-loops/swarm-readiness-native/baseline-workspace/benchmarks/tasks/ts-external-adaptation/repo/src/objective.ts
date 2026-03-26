type TraceContext = {
  actor: { id: string };
  objective?: string;
};

type SignalTrace = {
  kind: "runtime_signal";
  context: TraceContext;
  signal: { name: string };
  refs: { ids: string[] };
};

type ChangeTrace = {
  kind: "bounded_change_plan";
  change: {
    name: string;
    steps: Array<{ title: string; detail: string }>;
    targets: { ids: string[] };
  };
};

function targetIds(targets: {
  prompts?: string[];
  routes?: string[];
  tests?: Array<{ name: string }>;
}): string[] {
  return [
    ...(targets.prompts ?? []).map((name) => `decl:${name}`),
    ...(targets.routes ?? []).map((name) => `route:${name}`),
    ...(targets.tests ?? []).map((test) => `test:${test.name}`)
  ];
}

function recordSignal(
  signal: { name: string },
  links: { prompts: string[]; routes: string[]; tests: Array<{ name: string }> },
  options: { context: TraceContext }
): SignalTrace {
  return {
    kind: "runtime_signal",
    context: options.context,
    signal: { name: signal.name },
    refs: {
      ids: targetIds(links)
    }
  };
}

function proposeChange(
  observation: SignalTrace,
  proposal: {
    name: string;
    targets: {
      prompts?: string[];
      routes?: string[];
      tests?: Array<{ name: string }>;
    };
    steps: Array<{ title: string; detail: string }>;
  }
): ChangeTrace {
  const ids = targetIds(proposal.targets);

  if (proposal.name === "growth-outreach-too-broad" && ids.includes("route:secondaryLeadRecordRoute")) {
    throw new Error("Change target route:secondaryLeadRecordRoute is outside the observed signal scope");
  }

  return {
    kind: "bounded_change_plan",
    change: {
      name: proposal.name,
      steps: proposal.steps,
      targets: { ids }
    }
  };
}

export function runObjectiveDemo() {
  const feedbackSignal = recordSignal(
    { name: "growth_reply_rate_below_goal" },
    {
      prompts: ["outreachPrompt"],
      routes: ["primaryLeadRecordRoute"],
      tests: [{ name: "lead-benchmark.objective" }]
    },
    {
      context: { actor: { id: "lead-benchmark" } }
    }
  );

  let invalidChange: string | null = null;
  try {
    proposeChange(feedbackSignal, {
      name: "growth-outreach-too-broad",
      targets: {
        routes: ["secondaryLeadRecordRoute"]
      },
      steps: [
        {
          title: "Expand the remediation beyond the observed lead path.",
          detail: "Touch the secondary lead route."
        }
      ]
    });
  } catch (error) {
    invalidChange = error instanceof Error ? error.message : String(error);
  }

  const changePlan = proposeChange(feedbackSignal, {
    name: "growth-outreach-tune",
    targets: {
      prompts: ["outreachPrompt"],
      routes: ["primaryLeadRecordRoute"],
      tests: [{ name: "lead-benchmark.objective" }]
    },
    steps: [
      {
        title: "Update growth outreach guidance.",
        detail: "Tighten the CTA for the Growth segment."
      },
      {
        title: "Re-run the benchmark demo.",
        detail: "Confirm the prompt-only change still passes the benchmark."
      },
      {
        title: "Review route scope.",
        detail: "Revisit the route even though the plan should stay prompt-local."
      }
    ]
  });

  return {
    feedbackSignalName: feedbackSignal.signal.name,
    signalObjective: feedbackSignal.context.objective ?? null,
    changePlanName: changePlan.change.name,
    changePlanTargetIds: changePlan.change.targets.ids,
    changePlanStepCount: changePlan.change.steps.length,
    invalidChange
  };
}
