import { createServer, type LeadBindings } from "./main.js";

declare const process:
  | {
      env: Record<string, string | undefined>;
    }
  | undefined;

function defaultBindings(): LeadBindings {
  return {
    mockLeadSummaryModel(intake) {
      const priority =
        intake.budget >= 50000
          ? "high"
          : intake.budget >= 20000
            ? "medium"
            : "low";

      return JSON.stringify({
        summary: `${intake.company} led by ${intake.contact} fits the ${priority} priority pipeline.`,
        priority,
        segment: intake.segment,
        followUpRequired: intake.budget >= 20000
      });
    }
  };
}

const server = createServer(defaultBindings(), {
  databasePath: process?.env.LEAD_APP_DB_PATH ?? "./lead-app.sqlite",
  port: Number(process?.env.PORT ?? "3002")
});

console.log(`TypeScript lead app listening on http://localhost:${server.port}`);
