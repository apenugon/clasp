import path from "node:path";
import { pathToFileURL } from "node:url";

const customer = Object.freeze({
  id: "cust-42",
  company: "Northwind Studio",
  contactEmail: "ops@northwind.example",
  plan: "pro"
});

function requireProof(policyName, action, resourceLabel, proof, expectedField = null) {
  if (!proof) {
    throw new Error(`Missing policy proof for ${action} ${resourceLabel}`);
  }

  if (proof.policy !== policyName) {
    throw new Error(
      `Policy proof ${proof.policy} does not satisfy ${policyName} for ${action} ${resourceLabel}`
    );
  }

  if (proof.action !== action) {
    throw new Error(`Policy proof action ${proof.action} cannot authorize ${action} ${resourceLabel}`);
  }

  if (expectedField !== null && proof.field !== expectedField) {
    throw new Error(`Policy proof field ${proof.field ?? "none"} cannot authorize ${resourceLabel}`);
  }
}

function readCustomer(policyName, proof) {
  requireProof(policyName, "read", "customer", proof);
  return Object.freeze({ id: customer.id, company: customer.company, plan: customer.plan });
}

function writeCustomer(policyName, patch, proof) {
  requireProof(policyName, "write", "customer", proof);
  return Object.freeze({ ...customer, ...patch });
}

function discloseField(policyName, fieldName, proof) {
  requireProof(policyName, "disclose", `customer.${fieldName}`, proof, fieldName);
  return customer[fieldName];
}

function collectFieldMetadata(schemaEntry, fieldName) {
  const schema = schemaEntry?.schema ?? null;
  const fieldEntry = schema?.fields?.[fieldName];

  return Object.freeze({
    classificationPolicy: schema?.classificationPolicy ?? null,
    projectionSource: schema?.projectionSource ?? null,
    classification: fieldEntry?.classification ?? null
  });
}

function captureMessage(run) {
  try {
    run();
    return null;
  } catch (error) {
    return error instanceof Error ? error.message : String(error);
  }
}

export async function runAuthorizationDataAccessDemo(compiledModulePath) {
  const compiledModule = await import(pathToFileURL(path.resolve(compiledModulePath)).href);
  const policyName = compiledModule.__claspAgents?.[0]?.policy?.name ?? null;
  const schemaEntry = compiledModule.__claspSchemas?.SupportCustomer ?? null;
  const fieldMetadata = collectFieldMetadata(schemaEntry, compiledModule.disclosureField);
  const readProof = Object.freeze({
    policy: compiledModule.readProofPolicy,
    action: "read",
    resource: "customer"
  });
  const writeProof = Object.freeze({
    policy: compiledModule.writeProofPolicy,
    action: "write",
    resource: "customer"
  });
  const disclosureProof = Object.freeze({
    policy: compiledModule.disclosureProofPolicy,
    action: "disclose",
    resource: "customer",
    field: compiledModule.disclosureField
  });

  const readWithoutProof = captureMessage(() => readCustomer(policyName, null));
  const writeWithoutProof = captureMessage(() => writeCustomer(policyName, { plan: "enterprise" }, null));
  const discloseWithoutProof = captureMessage(() =>
    discloseField(policyName, compiledModule.disclosureField, null)
  );
  const wrongPolicy = captureMessage(() =>
    writeCustomer(
      policyName,
      { plan: "enterprise" },
      { policy: "PublicAccess", action: "write", resource: "customer" }
    )
  );
  const wrongField = captureMessage(() =>
    discloseField(
      policyName,
      "contactEmail",
      { policy: policyName, action: "disclose", resource: "customer", field: "plan" }
    )
  );

  const readResult = readCustomer(policyName, readProof);
  const writeResult = writeCustomer(policyName, { plan: "enterprise" }, writeProof);
  const disclosedEmail = discloseField(policyName, compiledModule.disclosureField, disclosureProof);

  return {
    readWithoutProof,
    writeWithoutProof,
    discloseWithoutProof,
    readProofPolicy: readProof.policy,
    writeProofPolicy: writeProof.policy,
    disclosureProofPolicy: disclosureProof.policy,
    schemaClassificationPolicy: fieldMetadata.classificationPolicy,
    projectionSource: fieldMetadata.projectionSource,
    disclosedField: compiledModule.disclosureField,
    disclosedFieldClassification: fieldMetadata.classification,
    readCompany: readResult.company,
    updatedPlan: writeResult.plan,
    disclosedEmail,
    wrongPolicy,
    wrongField
  };
}

const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : null;

if (invokedPath === path.resolve(new URL(import.meta.url).pathname)) {
  const compiledModulePath = process.argv[2];

  if (!compiledModulePath) {
    throw new Error("usage: node demo.mjs <compiled-module>");
  }

  console.log(JSON.stringify(await runAuthorizationDataAccessDemo(compiledModulePath)));
}
