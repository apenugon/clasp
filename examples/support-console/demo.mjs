import { pathToFileURL } from "node:url";
import {
  bindingContractFor,
  createProviderRuntime,
  installCompiledModule,
  requestPayloadJson
} from "../../runtime/bun/server.mjs";

function route(contract, name) {
  const found = contract.routes.find((candidate) => candidate.name === name);

  if (!found) {
    throw new Error(`Missing route ${name}`);
  }

  return found;
}

export async function runSupportConsoleDemo(compiledModule) {
  const providerCalls = [];
  const storageCalls = [];
  const providerOnlyRuntime = createProviderRuntime(compiledModule, {
    providers: {
      provider: {
        replyPreview(draft) {
          providerCalls.push({
            source: "provider-runtime",
            keys: Object.keys(draft).sort(),
            contactEmail: Object.prototype.hasOwnProperty.call(draft, "contactEmail")
          });
          return {
            customerId: draft.customerId,
            suggestedReply: `Thanks for the update. ${draft.summary} We will send the next renewal step today.`,
            escalationNeeded: draft.summary.toLowerCase().includes("blocked")
          };
        }
      }
    }
  });
  const providerOnlyPreview = await providerOnlyRuntime.call("generateReplyPreview", {
    customerId: "cust-42",
    summary: "Renewal is blocked on legal review."
  });
  let providerDeniedStorage = null;

  try {
    await providerOnlyRuntime.call("publishCustomer", {
      id: "cust-42",
      company: "Northwind Studio",
      contactEmail: "ops@northwind.example",
      plan: "enterprise",
      renewalRisk: "high"
    });
  } catch (error) {
    providerDeniedStorage = error instanceof Error ? error.message : String(error);
  }

  installCompiledModule(compiledModule, {
    generateReplyPreview(draft) {
      providerCalls.push({
        source: "app-runtime",
        keys: Object.keys(draft).sort(),
        contactEmail: Object.prototype.hasOwnProperty.call(draft, "contactEmail")
      });
      return {
        customerId: draft.customerId,
        suggestedReply: `Thanks for the update. ${draft.summary} We will send the next renewal step today.`,
        escalationNeeded: draft.summary.toLowerCase().includes("blocked")
      };
    },
    publishCustomer(customer) {
      storageCalls.push({
        keys: Object.keys(customer).sort(),
        contactEmail: customer.contactEmail,
        plan: customer.plan
      });
      return customer;
    }
  });

  const contract = bindingContractFor(compiledModule);
  const dashboardRoute = route(contract, "supportDashboardRoute");
  const customerRoute = route(contract, "supportCustomerRoute");
  const customerPageRoute = route(contract, "supportCustomerPageRoute");
  const previewRoute = route(contract, "previewReplyRoute");

  const dashboardHtml = dashboardRoute.encodeResponse(await dashboardRoute.handler({}));
  const customer = await customerRoute.handler({});
  const customerPageHtml = customerPageRoute.encodeResponse(await customerPageRoute.handler({}));
  const previewPayload = previewRoute.decodeRequest(
    await requestPayloadJson(
      previewRoute,
      new Request("https://app.example.test/support/preview", {
        method: "POST",
        headers: {
          "content-type": "application/x-www-form-urlencoded"
        },
        body: "customerId=cust-42&summary=Renewal+is+blocked+on+legal+review."
      })
    )
  );
  const previewTicket = compiledModule.previewTicket(previewPayload);
  const previewHtml = previewRoute.encodeResponse(await previewRoute.handler(previewPayload));

  let invalid = null;

  try {
    previewRoute.decodeRequest(
      await requestPayloadJson(
        previewRoute,
        new Request("https://app.example.test/support/preview", {
          method: "POST",
          headers: {
            "content-type": "application/x-www-form-urlencoded"
          },
          body: "customerId=cust-42"
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
    hostBindingRuntimeNames: contract.hostBindings.map((binding) => binding.runtimeName),
    dashboardHasPreviewForm:
      dashboardHtml.includes('action="/support/preview"') &&
      dashboardHtml.includes("Conversation summary") &&
      dashboardHtml.includes("support"),
    dashboardHasCustomerLink: dashboardHtml.includes('href="/support/customer/page"'),
    customerCompany: customer.company,
    customerEmail: customer.contactEmail,
    customerPageHasExport:
      customerPageHtml.includes("Northwind Studio") &&
      customerPageHtml.includes("ops@northwind.example") &&
      customerPageHtml.includes("enterprise"),
    previewReply: previewTicket.suggestedReply,
    previewEscalationNeeded: previewTicket.escalationNeeded,
    previewPageHasReply:
      previewHtml.includes("Thanks for the update.") &&
      previewHtml.includes("Back to dashboard"),
    providerOnlyPreviewKeys: Object.keys(providerOnlyPreview).sort(),
    providerOnlyDeniedStorage: providerDeniedStorage,
    providerOnlyBindings: providerOnlyRuntime.bindings.map((binding) => binding.name),
    providerObservedDraft: providerCalls[providerCalls.length - 1] ?? null,
    storageObservedCustomer: storageCalls[0] ?? null,
    invalid
  };
}

async function runCli() {
  const compiledPath = process.argv[2] ?? "./Main.js";
  const compiledUrl = new URL(compiledPath, pathToFileURL(`${process.cwd()}/`));
  const compiledModule = await import(compiledUrl.href);
  const summary = await runSupportConsoleDemo(compiledModule);
  console.log(JSON.stringify(summary));
}

if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) {
  await runCli();
}
