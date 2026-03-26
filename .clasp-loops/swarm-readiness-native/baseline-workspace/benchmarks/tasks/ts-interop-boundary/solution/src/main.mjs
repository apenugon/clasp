import { inspectLead } from "../support/inspectLead.mjs";

function expectObject(value, path) {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new Error(`${path} expected an object`);
  }

  return value;
}

function expectString(value, path) {
  if (typeof value !== "string") {
    throw new Error(`${path} expected a string`);
  }

  return value;
}

function expectBoolean(value, path) {
  if (typeof value !== "boolean") {
    const fieldName = path.includes(".") ? path.split(".").at(-1) : path;
    throw new Error(`${fieldName} must be a boolean`);
  }

  return value;
}

function refineInspection(value, path = "result") {
  const objectValue = expectObject(value, path);
  const verdict = expectObject(objectValue.verdict, `${path}.verdict`);

  return {
    label: expectString(objectValue.label, `${path}.label`),
    verdict: {
      accepted: expectBoolean(verdict.accepted, `${path}.verdict.accepted`),
      reason: expectString(verdict.reason, `${path}.verdict.reason`)
    }
  };
}

function inspectWithBlame(request) {
  try {
    return refineInspection(inspectLead(request));
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    throw new Error(`foreign inspectLead via ./support/inspectLead.d.ts failed: ${message}`);
  }
}

export async function runInteropBoundaryDemo() {
  const valid = inspectWithBlame({ company: "Acme", budget: 42 });
  let invalid = null;

  try {
    inspectWithBlame({ company: "Globex", budget: 18 });
  } catch (error) {
    invalid = error instanceof Error ? error.message : String(error);
  }

  return {
    packageKind: "typescript",
    validLabel: valid.label,
    validAccepted: valid.verdict.accepted,
    invalid
  };
}
