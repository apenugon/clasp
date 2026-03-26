const customer = Object.freeze({
  id: "cust-42",
  company: "Northwind Studio",
  contactEmail: "ops@northwind.example",
  plan: "pro"
});

const accessMetadata = Object.freeze({
  policyName: "SupportAccess",
  projectionSource: "Customer",
  readProofPolicy: "SupportAccess",
  writeProofPolicy: "SupportAccess",
  disclosureProofPolicy: "SupportAccess",
  disclosedField: "contactEmail",
  fields: Object.freeze({
    id: Object.freeze({ classification: "public" }),
    company: Object.freeze({ classification: "public" }),
    contactEmail: Object.freeze({ classification: "pii" }),
    plan: Object.freeze({ classification: "public" })
  })
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

function captureMessage(run) {
  try {
    run();
    return null;
  } catch (error) {
    return error instanceof Error ? error.message : String(error);
  }
}

export async function runAuthorizationDataAccessDemo() {
  const readProof = Object.freeze({
    policy: accessMetadata.readProofPolicy,
    action: "read",
    resource: "customer"
  });
  const writeProof = Object.freeze({
    policy: accessMetadata.writeProofPolicy,
    action: "write",
    resource: "customer"
  });
  const disclosureProof = Object.freeze({
    policy: accessMetadata.disclosureProofPolicy,
    action: "disclose",
    resource: "customer",
    field: accessMetadata.disclosedField
  });

  const readWithoutProof = captureMessage(() => readCustomer(accessMetadata.policyName, null));
  const writeWithoutProof = captureMessage(() =>
    writeCustomer(accessMetadata.policyName, { plan: "enterprise" }, null)
  );
  const discloseWithoutProof = captureMessage(() =>
    discloseField(accessMetadata.policyName, accessMetadata.disclosedField, null)
  );
  const wrongPolicy = captureMessage(() =>
    writeCustomer(
      accessMetadata.policyName,
      { plan: "enterprise" },
      { policy: "PublicAccess", action: "write", resource: "customer" }
    )
  );
  const wrongField = captureMessage(() =>
    discloseField(
      accessMetadata.policyName,
      "contactEmail",
      { policy: accessMetadata.policyName, action: "disclose", resource: "customer", field: "plan" }
    )
  );

  const readResult = readCustomer(accessMetadata.policyName, readProof);
  const writeResult = writeCustomer(accessMetadata.policyName, { plan: "enterprise" }, writeProof);
  const disclosedEmail = discloseField(
    accessMetadata.policyName,
    accessMetadata.disclosedField,
    disclosureProof
  );

  return {
    readWithoutProof,
    writeWithoutProof,
    discloseWithoutProof,
    readProofPolicy: readProof.policy,
    writeProofPolicy: writeProof.policy,
    disclosureProofPolicy: disclosureProof.policy,
    schemaClassificationPolicy: accessMetadata.policyName,
    projectionSource: accessMetadata.projectionSource,
    disclosedField: accessMetadata.disclosedField,
    disclosedFieldClassification: accessMetadata.fields[accessMetadata.disclosedField]?.classification ?? null,
    readCompany: readResult.company,
    updatedPlan: writeResult.plan,
    disclosedEmail,
    wrongPolicy,
    wrongField
  };
}
