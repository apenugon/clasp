import {
  decodeLeadRequest,
  decodeLeadSummary,
  encodeLeadSummary,
  type LeadRequest,
  type LeadSummary
} from "../shared/lead.js";
import { serveRoutes, type JsonRoute } from "./runtime.js";

export interface LeadBindings {
  mockLeadSummaryModel(lead: LeadRequest): string;
}

export function summarizeLead(
  bindings: LeadBindings,
  lead: LeadRequest
): LeadSummary {
  return decodeLeadSummary(bindings.mockLeadSummaryModel(lead));
}

export function createRoutes(
  bindings: LeadBindings
): JsonRoute<LeadRequest, LeadSummary>[] {
  return [
    {
      method: "POST",
      path: "/lead/summary",
      decodeRequest: decodeLeadRequest,
      encodeResponse: encodeLeadSummary,
      handler: (lead) => summarizeLead(bindings, lead)
    }
  ];
}

export function createServer(
  bindings: LeadBindings,
  options: { port?: number } = {}
) {
  return serveRoutes(createRoutes(bindings), options);
}
