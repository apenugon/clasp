export interface LeadRequest {
  company: string;
  contact: string;
  budget: number;
}

export interface LeadSummary {
  summary: string;
  followUpRequired: boolean;
}

type JsonRecord = Record<string, unknown>;

function isRecord(value: unknown): value is JsonRecord {
  return typeof value === "object" && value !== null;
}

function expectString(record: JsonRecord, field: string): string {
  const value = record[field];
  if (typeof value !== "string") {
    throw new Error(`${field} must be a string`);
  }
  return value;
}

function expectNumber(record: JsonRecord, field: string): number {
  const value = record[field];
  if (typeof value !== "number" || !Number.isFinite(value)) {
    throw new Error(`${field} must be a number`);
  }
  return value;
}

function expectBoolean(record: JsonRecord, field: string): boolean {
  const value = record[field];
  if (typeof value !== "boolean") {
    throw new Error(`${field} must be a boolean`);
  }
  return value;
}

function parseJson(text: string): unknown {
  try {
    return JSON.parse(text);
  } catch (error) {
    throw new Error(`Invalid JSON: ${errorMessage(error)}`);
  }
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

export function parseLeadRequest(value: unknown): LeadRequest {
  if (!isRecord(value)) {
    throw new Error("LeadRequest must be an object");
  }

  return {
    company: expectString(value, "company"),
    contact: expectString(value, "contact"),
    budget: expectNumber(value, "budget")
  };
}

export function decodeLeadRequest(text: string): LeadRequest {
  return parseLeadRequest(parseJson(text));
}

export function parseLeadSummary(value: unknown): LeadSummary {
  if (!isRecord(value)) {
    throw new Error("LeadSummary must be an object");
  }

  return {
    summary: expectString(value, "summary"),
    followUpRequired: expectBoolean(value, "followUpRequired")
  };
}

export function decodeLeadSummary(text: string): LeadSummary {
  return parseLeadSummary(parseJson(text));
}

export function encodeLeadSummary(value: LeadSummary): string {
  return JSON.stringify(parseLeadSummary(value));
}
