import { compileNativeBinary, runRoute, withNativeServer, fetchText } from "../native-demo.mjs";

export async function runReleaseGateDemo(binaryPath) {
  const compiled = compileNativeBinary(
    "examples/release-gate/Main.clasp",
    binaryPath,
    "release-gate-demo"
  );

  try {
    const audit = JSON.parse(runRoute(compiled.binaryPath, "GET", "/release/audit"));

    return await withNativeServer(compiled.binaryPath, "/release-gate", async ({ baseUrl }) => {
      const dashboard = await fetchText(baseUrl, "/release-gate");
      const review = await fetchText(baseUrl, "/release/review", {
        method: "POST",
        headers: {
          "content-type": "application/x-www-form-urlencoded",
        },
        body: "releaseId=rel-204&summary=Ship+the+support+automation+pipeline.",
      });
      const accept = await fetchText(baseUrl, "/release/accept", {
        method: "POST",
        redirect: "manual",
      });
      const ack = await fetchText(baseUrl, "/release/ack");

      return {
        status: "ok",
        implementation: "clasp-native",
        example: "release-gate",
        auditTenant: audit.session.tenant.id,
        auditStatus: audit.status.$tag ?? audit.status,
        dashboardHasReviewForm: dashboard.text.includes('"/release/review"'),
        decisionNote: review.text.includes("Approved after typed policy review.")
          ? "Approved after typed policy review."
          : null,
        redirectStatus: accept.status,
        redirectLocation: accept.headers.get("location"),
        ackHasBackLink: ack.text.includes("/release-gate"),
      };
    });
  } finally {
    compiled.cleanup();
  }
}

async function runCli() {
  const summary = await runReleaseGateDemo(process.argv[2]);
  console.log(JSON.stringify(summary));
}

if (import.meta.url === new URL(process.argv[1], "file:").href) {
  await runCli();
}
