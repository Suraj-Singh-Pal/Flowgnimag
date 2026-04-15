const path = require("path");
const Database = require("better-sqlite3");
const { MongoClient } = require("mongodb");
const dotenv = require("dotenv");

dotenv.config();

const DB_PATH =
  process.env.DB_PATH || path.join(process.cwd(), "data", "flowgnimag.db");
const MONGODB_URI = process.env.MONGODB_URI || "";
const MONGODB_DB_NAME = process.env.MONGODB_DB_NAME || "";

function parseMongoDbName() {
  if (MONGODB_DB_NAME.trim()) return MONGODB_DB_NAME.trim();
  if (!MONGODB_URI.trim()) return "flowgnimag";
  try {
    const uri = new URL(MONGODB_URI);
    const pathname = (uri.pathname || "").replace(/^\//, "").trim();
    return pathname || "flowgnimag";
  } catch {
    return "flowgnimag";
  }
}

async function main() {
  if (!MONGODB_URI.trim()) {
    throw new Error("MONGODB_URI is missing in backend/.env");
  }

  const sqlite = new Database(DB_PATH, { readonly: true });
  const client = new MongoClient(MONGODB_URI, {
    maxPoolSize: 10,
    serverSelectionTimeoutMS: 10000,
  });

  await client.connect();
  const mongoDb = client.db(parseMongoDbName());

  const tables = [
    "users",
    "chat_sessions",
    "chat_messages",
    "notes",
    "tasks",
    "user_memories",
    "google_oauth_states",
    "google_calendar_tokens",
    "push_devices",
    "google_push_state",
    "auth_refresh_tokens",
    "knowledge_documents",
    "assistant_jobs",
  ];

  for (const table of tables) {
    const exists = sqlite
      .prepare(
        "SELECT name FROM sqlite_master WHERE type='table' AND name = ? LIMIT 1"
      )
      .get(table);
    if (!exists) {
      console.log(`[skip] ${table} table not found in sqlite`);
      continue;
    }

    const rows = sqlite.prepare(`SELECT * FROM ${table}`).all();
    const collection = mongoDb.collection(table);

    await collection.deleteMany({});
    if (rows.length > 0) {
      await collection.insertMany(rows, { ordered: false });
    }
    console.log(`[ok] ${table}: ${rows.length} rows migrated`);
  }

  await client.close();
  sqlite.close();
  console.log("SQLite -> MongoDB migration completed.");
}

main().catch((error) => {
  console.error("Migration failed:", error?.message || error);
  process.exitCode = 1;
});
