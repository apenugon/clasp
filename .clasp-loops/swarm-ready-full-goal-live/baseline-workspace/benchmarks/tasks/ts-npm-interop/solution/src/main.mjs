import { upperCase } from "../node_modules/local-upper/index.mjs";
import { formatLead } from "../support/formatLead.mjs";

export async function runInteropDemo() {
  return {
    packageKinds: ["npm", "typescript"],
    upper: upperCase("hello ada"),
    formatted: formatLead({ company: "Acme Labs", budget: 7 })
  };
}
