import { createRequire } from "node:module";
import {
  decodeLeadRecord,
  leadLabel,
  type InboxSnapshot,
  type LeadIntake,
  type LeadRecord,
  type LeadReview,
  type LeadSummary
} from "../shared/lead.js";

const SCHEMA_VERSION = 1;
const require = createRequire(import.meta.url);

type DatabaseHandle = {
  close(): void;
  exec(sql: string): void;
  prepare(sql: string): StatementHandle;
};

type StatementHandle = {
  all(...parameters: unknown[]): unknown[];
  get(...parameters: unknown[]): unknown;
  run(...parameters: unknown[]): {
    changes: number;
    lastInsertRowid: number | bigint;
  };
};

type LeadRow = {
  lead_number: number;
  company: string;
  contact: string;
  summary: string;
  priority: string;
  segment: string;
  follow_up_required: number;
  review_status: string;
  review_note: string;
};

export interface LeadStore {
  close(): void;
  createLeadRecord(intake: LeadIntake, summary: LeadSummary): LeadRecord;
  loadInbox(): InboxSnapshot;
  loadLead(offset: number): LeadRecord;
  reviewLead(review: LeadReview): LeadRecord;
}

export function createLeadStore(
  databasePath: string,
  seedLeads: LeadRecord[] = createSeedLeads()
): LeadStore {
  const database = openDatabase(databasePath);

  try {
    migrate(database);
    seed(database, seedLeads);
    return createStore(database);
  } catch (error) {
    database.close();
    throw error;
  }
}

function createStore(database: DatabaseHandle): LeadStore {
  const insertLead = database.prepare(`
    INSERT INTO leads (
      company,
      contact,
      summary,
      priority,
      segment,
      follow_up_required,
      review_status,
      review_note
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
  `);
  const selectLeadByOffset = database.prepare(`
    SELECT
      lead_number,
      company,
      contact,
      summary,
      priority,
      segment,
      follow_up_required,
      review_status,
      review_note
    FROM leads
    ORDER BY lead_number DESC
    LIMIT 1 OFFSET ?
  `);
  const updateReview = database.prepare(`
    UPDATE leads
    SET review_status = ?, review_note = ?
    WHERE lead_number = ?
  `);
  const selectInbox = database.prepare(`
    SELECT
      lead_number,
      company,
      contact,
      summary,
      priority,
      segment,
      follow_up_required,
      review_status,
      review_note
    FROM leads
    ORDER BY lead_number DESC
    LIMIT 2
  `);

  return {
    close() {
      database.close();
    },
    createLeadRecord(intake, summary) {
      const inserted = insertLead.run(
        intake.company,
        intake.contact,
        summary.summary,
        summary.priority,
        summary.segment,
        summary.followUpRequired ? 1 : 0,
        "new",
        ""
      );

      return loadLeadNumber(database, Number(inserted.lastInsertRowid));
    },
    loadInbox() {
      const leads = selectInbox.all() as LeadRow[];
      const primaryLead = decodeLeadRow(leads[0]);
      const secondaryLead = decodeLeadRow(leads[1] ?? leads[0]);

      return {
        headline: "Priority inbox",
        primaryLeadLabel: leadLabel(primaryLead),
        secondaryLeadLabel: leadLabel(secondaryLead)
      };
    },
    loadLead(offset) {
      const row = selectLeadByOffset.get(offset) as LeadRow | undefined;

      if (!row) {
        throw new Error("lead store is empty");
      }

      return decodeLeadRow(row);
    },
    reviewLead(review) {
      const leadNumber = parseLeadId(review.leadId);
      const existing = loadLeadNumber(database, leadNumber);
      updateReview.run("reviewed", review.note, leadNumber);

      return {
        ...existing,
        reviewStatus: "reviewed",
        reviewNote: review.note
      };
    }
  };
}

function migrate(database: DatabaseHandle) {
  database.exec(`
    CREATE TABLE IF NOT EXISTS app_meta (
      key TEXT PRIMARY KEY,
      value TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS leads (
      lead_number INTEGER PRIMARY KEY,
      company TEXT NOT NULL,
      contact TEXT NOT NULL,
      summary TEXT NOT NULL,
      priority TEXT NOT NULL,
      segment TEXT NOT NULL,
      follow_up_required INTEGER NOT NULL,
      review_status TEXT NOT NULL,
      review_note TEXT NOT NULL DEFAULT ''
    );
  `);

  const versionRow = database
    .prepare(`SELECT value FROM app_meta WHERE key = 'schema_version'`)
    .get() as { value: string } | undefined;

  if (!versionRow) {
    database
      .prepare(`INSERT INTO app_meta (key, value) VALUES ('schema_version', ?)`)
      .run(String(SCHEMA_VERSION));
    return;
  }

  if (Number(versionRow.value) !== SCHEMA_VERSION) {
    throw new Error(
      `lead app schema version ${versionRow.value} is incompatible with expected version ${SCHEMA_VERSION}`
    );
  }
}

function seed(database: DatabaseHandle, leads: LeadRecord[]) {
  const row = database.prepare("SELECT COUNT(*) AS count FROM leads").get() as {
    count: number;
  };

  if (row.count > 0) {
    return;
  }

  const insert = database.prepare(`
    INSERT INTO leads (
      lead_number,
      company,
      contact,
      summary,
      priority,
      segment,
      follow_up_required,
      review_status,
      review_note
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
  `);

  for (const lead of [...leads].reverse()) {
    insert.run(
      parseLeadId(lead.leadId),
      lead.company,
      lead.contact,
      lead.summary,
      lead.priority,
      lead.segment,
      lead.followUpRequired ? 1 : 0,
      lead.reviewStatus,
      lead.reviewNote
    );
  }
}

function loadLeadNumber(database: DatabaseHandle, leadNumber: number): LeadRecord {
  const row = database
    .prepare(`
      SELECT
        lead_number,
        company,
        contact,
        summary,
        priority,
        segment,
        follow_up_required,
        review_status,
        review_note
      FROM leads
      WHERE lead_number = ?
    `)
    .get(leadNumber) as LeadRow | undefined;

  if (!row) {
    throw new Error(`Unknown lead: lead-${leadNumber}`);
  }

  return decodeLeadRow(row);
}

function decodeLeadRow(row: LeadRow | undefined): LeadRecord {
  if (!row) {
    throw new Error("lead store is empty");
  }

  return decodeLeadRecord(
    JSON.stringify({
      leadId: `lead-${row.lead_number}`,
      company: row.company,
      contact: row.contact,
      summary: row.summary,
      priority: row.priority,
      segment: row.segment,
      followUpRequired: row.follow_up_required === 1,
      reviewStatus: row.review_status,
      reviewNote: row.review_note
    })
  );
}

function parseLeadId(leadId: string): number {
  const match = /^lead-(\d+)$/.exec(leadId);

  if (!match) {
    throw new Error(`Unknown lead: ${leadId}`);
  }

  return Number(match[1]);
}

function createSeedLeads(): LeadRecord[] {
  return [
    {
      leadId: "lead-2",
      company: "Northwind Studio",
      contact: "Morgan Lee",
      summary:
        "Northwind Studio is ready for a design-system migration this quarter.",
      priority: "medium",
      segment: "growth",
      followUpRequired: true,
      reviewStatus: "reviewed",
      reviewNote: "Confirmed budget window and asked for a migration timeline."
    },
    {
      leadId: "lead-1",
      company: "Acme Labs",
      contact: "Jordan Kim",
      summary:
        "Acme Labs is exploring an internal AI pilot for support operations.",
      priority: "high",
      segment: "enterprise",
      followUpRequired: true,
      reviewStatus: "new",
      reviewNote: ""
    }
  ];
}

function openDatabase(databasePath: string): DatabaseHandle {
  if (typeof Bun !== "undefined" && Object.prototype.hasOwnProperty.call(Bun, "version")) {
    const { Database } = require("bun:sqlite") as {
      Database: new (location: string) => {
        close(): void;
        exec(sql: string): void;
        query(sql: string): StatementHandle;
      };
    };
    const database = new Database(databasePath);

    return {
      close() {
        database.close();
      },
      exec(sql) {
        database.exec(sql);
      },
      prepare(sql) {
        return database.query(sql);
      }
    };
  }

  const { DatabaseSync } = require("node:sqlite") as {
    DatabaseSync: new (location: string) => DatabaseHandle;
  };

  return new DatabaseSync(databasePath);
}
