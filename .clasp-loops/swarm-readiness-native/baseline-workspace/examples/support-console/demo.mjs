import { compileNativeBinary, runRoute, withNativeServer, fetchText } from "../native-demo.mjs";

export async function runSupportConsoleDemo(binaryPath) {
  const compiled = compileNativeBinary(
    "examples/support-console/Main.clasp",
    binaryPath,
    "support-console-demo"
  );

  try {
    const customer = JSON.parse(runRoute(compiled.binaryPath, "GET", "/support/customer"));
    const customerPage = JSON.parse(
      runRoute(compiled.binaryPath, "GET", "/support/customer/page")
    );

    return await withNativeServer(compiled.binaryPath, "/support", async ({ baseUrl }) => {
      const dashboard = await fetchText(baseUrl, "/support");
      const preview = await fetchText(baseUrl, "/support/preview", {
        method: "POST",
        headers: {
          "content-type": "application/x-www-form-urlencoded",
        },
        body: "customerId=cust-42&summary=Renewal+is+blocked+on+legal+review.",
      });

      return {
        status: "ok",
        implementation: "clasp-native",
        example: "support-console",
        customerCompany: customer.company,
        customerEmail: customer.contactEmail,
        customerPageHasExport: customerPage.title === "Customer export",
        dashboardHasPreviewForm: dashboard.text.includes('"/support/preview"'),
        previewPageHasReply: preview.text.includes("Thanks for the update."),
      };
    });
  } finally {
    compiled.cleanup();
  }
}

async function runCli() {
  const summary = await runSupportConsoleDemo(process.argv[2]);
  console.log(JSON.stringify(summary));
}

if (import.meta.url === new URL(process.argv[1], "file:").href) {
  await runCli();
}
