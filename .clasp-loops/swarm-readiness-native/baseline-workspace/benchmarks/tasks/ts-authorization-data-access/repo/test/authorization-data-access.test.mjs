import assert from "node:assert/strict";

import { runAuthorizationDataAccessDemo } from "../src/main.mjs";

const result = await runAuthorizationDataAccessDemo();

assert.deepStrictEqual(result, {
  readWithoutProof: "Missing policy proof for read customer",
  writeWithoutProof: "Missing policy proof for write customer",
  discloseWithoutProof: "Missing policy proof for disclose customer.contactEmail",
  readProofPolicy: "SupportAccess",
  writeProofPolicy: "SupportAccess",
  disclosureProofPolicy: "SupportAccess",
  schemaClassificationPolicy: "SupportAccess",
  projectionSource: "Customer",
  disclosedField: "contactEmail",
  disclosedFieldClassification: "pii",
  readCompany: "Northwind Studio",
  updatedPlan: "enterprise",
  disclosedEmail: "ops@northwind.example",
  wrongPolicy: "Policy proof PublicAccess does not satisfy SupportAccess for write customer",
  wrongField: "Policy proof field plan cannot authorize customer.contactEmail"
});

console.log(JSON.stringify(result));
