import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { createRequire } from "node:module";
import net from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createServer } from "../dist/server/main.js";

const require = createRequire(import.meta.url);

function formBody(fields) {
  return new URLSearchParams(fields).toString();
}

async function request(port, path, init = {}) {
  return fetch(`http://127.0.0.1:${port}${path}`, init);
}

async function allocatePort() {
  return await new Promise((resolve, reject) => {
    const socket = net.createServer();

    socket.once("error", reject);
    socket.listen(0, "127.0.0.1", () => {
      const address = socket.address();

      if (!address || typeof address === "string") {
        socket.close(() => reject(new Error("failed to allocate an ephemeral port")));
        return;
      }

      const { port } = address;
      socket.close((error) => {
        if (error) {
          reject(error);
          return;
        }

        resolve(port);
      });
    });
  });
}

async function withServer(binding, callback, options = {}) {
  const port = await allocatePort();
  const server = createServer(
    {
      mockLeadSummaryModel: binding
    },
    {
      databasePath: options.databasePath ?? ":memory:",
      port
    }
  );

  try {
    await callback(port);
  } finally {
    server.stop(true);
  }
}

async function withPersistentDatabase(callback) {
  const directory = await mkdtemp(join(tmpdir(), "lead-persistence-task-"));
  const databasePath = join(directory, "lead-app.sqlite");

  try {
    await callback(databasePath);
  } finally {
    await rm(directory, { force: true, recursive: true });
  }
}

function openDatabase(databasePath) {
  if (typeof Bun !== "undefined") {
    const { Database } = require("bun:sqlite");
    return new Database(databasePath);
  }

  const { DatabaseSync } = require("node:sqlite");
  return new DatabaseSync(databasePath);
}

function seedIncompatibleDatabase(databasePath) {
  const database = openDatabase(databasePath);

  try {
    database.exec(`
      CREATE TABLE IF NOT EXISTS app_meta (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      );

      INSERT OR REPLACE INTO app_meta (key, value)
      VALUES ('schema_version', '999');
    `);
  } finally {
    database.close();
  }
}

await withPersistentDatabase(async (databasePath) => {
  const binding = (lead) =>
    JSON.stringify({
      summary: `${lead.company} led by ${lead.contact} fits the persisted pipeline.`,
      priority: "high",
      segment: lead.segment,
      followUpRequired: true
    });

  await withServer(binding, async (port) => {
    const created = await request(port, "/leads", {
      method: "POST",
      headers: {
        "content-type": "application/x-www-form-urlencoded"
      },
      body: formBody({
        company: "Persisted Co",
        contact: "Riley",
        budget: "90000",
        segment: "enterprise"
      })
    });

    assert.equal(created.status, 200);

    const reviewed = await request(port, "/review", {
      method: "POST",
      headers: {
        "content-type": "application/x-www-form-urlencoded"
      },
      body: formBody({
        leadId: "lead-3",
        note: "Stored in sqlite."
      })
    });

    assert.equal(reviewed.status, 200);
  }, { databasePath });

  await withServer(binding, async (port) => {
    const inbox = await request(port, "/inbox");
    const inboxHtml = await inbox.text();
    assert.equal(inbox.status, 200);
    assert.match(inboxHtml, /Persisted Co \(high, enterprise\)/);

    const primaryLead = await request(port, "/lead/primary");
    const primaryLeadHtml = await primaryLead.text();
    assert.equal(primaryLead.status, 200);
    assert.match(primaryLeadHtml, /Persisted Co/);
    assert.match(primaryLeadHtml, /Stored in sqlite\./);
    assert.match(primaryLeadHtml, /Review status: reviewed/);
  }, { databasePath });
});

await withPersistentDatabase(async (databasePath) => {
  seedIncompatibleDatabase(databasePath);
  const port = await allocatePort();

  assert.throws(
    () =>
      createServer(
        {
          mockLeadSummaryModel() {
            return JSON.stringify({
              summary: "ignored",
              priority: "medium",
              segment: "growth",
              followUpRequired: false
            });
          }
        },
        {
          databasePath,
          port
        }
      ),
    /lead app schema version 999 is incompatible with expected version 1/
  );
});
