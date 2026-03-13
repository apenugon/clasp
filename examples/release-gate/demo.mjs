import { pathToFileURL } from "node:url";
import {
  bindingContractFor,
  installCompiledModule,
  requestPayloadJson,
  responseForRouteResult
} from "../../runtime/bun/server.mjs";

function route(contract, name) {
  const found = contract.routes.find((candidate) => candidate.name === name);

  if (!found) {
    throw new Error(`Missing route ${name}`);
  }

  return found;
}

export async function runReleaseGateDemo(compiledModule) {
  installCompiledModule(compiledModule, {
    reviewRelease(request) {
      const approved = request.summary.toLowerCase().includes("ship");

      return JSON.stringify({
        releaseId: request.releaseId,
        status: approved ? "approved" : "rolledBack",
        note: approved
          ? "Approved after typed policy review."
          : "Rolled back pending follow-up.",
        audit: {
          session: {
            sessionId: "sess-release-204",
            principal: {
              id: "ops-9"
            },
            tenant: {
              id: "operations"
            },
            resource: {
              resourceType: "release",
              resourceId: request.releaseId
            }
          },
          resource: {
            resourceType: "release",
            resourceId: request.releaseId
          },
          releaseId: request.releaseId,
          status: approved ? "approved" : "rolledBack",
          note: approved
            ? "Approved after typed policy review."
            : "Rolled back pending follow-up."
        }
      });
    }
  });

  const contract = bindingContractFor(compiledModule);
  const gateRoute = route(contract, "releaseGateRoute");
  const auditRoute = route(contract, "releaseAuditRoute");
  const ackRoute = route(contract, "releaseAckRoute");
  const reviewRoute = route(contract, "releaseReviewRoute");
  const acceptRoute = route(contract, "releaseAcceptRoute");

  const dashboardHtml = gateRoute.encodeResponse(await gateRoute.handler({}));
  const audit = await auditRoute.handler({});
  const reviewPayload = reviewRoute.decodeRequest(
    await requestPayloadJson(
      reviewRoute,
      new Request("https://app.example.test/release/review", {
        method: "POST",
        headers: {
          "content-type": "application/x-www-form-urlencoded"
        },
        body: "releaseId=rel-204&summary=Ship+the+support+automation+pipeline."
      })
    )
  );
  const decision = compiledModule.reviewDecision(reviewPayload);
  const decisionHtml = reviewRoute.encodeResponse(await reviewRoute.handler(reviewPayload));
  const redirectResponse = responseForRouteResult(acceptRoute, await acceptRoute.handler({}));
  const ackHtml = ackRoute.encodeResponse(await ackRoute.handler({}));

  let invalid = null;

  try {
    reviewRoute.decodeRequest(
      await requestPayloadJson(
        reviewRoute,
        new Request("https://app.example.test/release/review", {
          method: "POST",
          headers: {
            "content-type": "application/x-www-form-urlencoded"
          },
          body: "summary=Ship+the+support+automation+pipeline."
        })
      )
    );
  } catch (error) {
    invalid = error instanceof Error ? error.message : String(error);
  }

  return {
    routeCount: contract.routes.length,
    routeNames: contract.routes.map((candidate) => candidate.name),
    hostBindingNames: contract.hostBindings.map((binding) => binding.name),
    dashboardHasReviewForm:
      dashboardHtml.includes('action="/release/review"') &&
      dashboardHtml.includes('action="/release/accept"') &&
      dashboardHtml.includes("operations"),
    auditTenant: audit.session.tenant.id,
    auditStatus: audit.status.$tag ?? audit.status,
    decisionStatus: decision.status.$tag ?? decision.status,
    decisionNote: decision.note,
    decisionPageHasBackLink:
      decisionHtml.includes("Approved after typed policy review.") &&
      decisionHtml.includes("Back to dashboard"),
    redirectStatus: redirectResponse.status,
    redirectLocation: redirectResponse.headers.get("location"),
    ackHasBackLink:
      ackHtml.includes("Release accepted") &&
      ackHtml.includes('href="/release-gate"'),
    invalid
  };
}

async function runCli() {
  const compiledPath = process.argv[2] ?? "./Main.js";
  const compiledUrl = new URL(compiledPath, pathToFileURL(`${process.cwd()}/`));
  const compiledModule = await import(compiledUrl.href);
  const summary = await runReleaseGateDemo(compiledModule);
  console.log(JSON.stringify(summary));
}

if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) {
  await runCli();
}
