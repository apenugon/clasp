import * as compiled from "./Main.js";
import { installRuntime, serveCompiledModule } from "../../runtime/bun/server.mjs";

installRuntime({
  mockLeadSummaryModel(lead) {
    const priority = lead.budget >= 50000 ? "high" : lead.budget >= 20000 ? "medium" : "low";
    const followUpRequired = lead.budget >= 20000;

    return JSON.stringify({
      summary: `${lead.company} led by ${lead.contact} fits the ${priority} priority pipeline`,
      priority,
      followUpRequired
    });
  }
});

const server = serveCompiledModule(compiled, {
  port: Number(process.env.PORT ?? "3001")
});

console.log(`Clasp lead app listening on http://localhost:${server.port}`);
