const express = require("express");
const cors = require("cors");
const dotenv = require("dotenv");
const OpenAI = require("openai");
const crypto = require("crypto");
const path = require("path");
const fs = require("fs");
const dns = require("dns").promises;
const Database = require("better-sqlite3");
const { MongoClient } = require("mongodb");
const bcrypt = require("bcryptjs");
const jwt = require("jsonwebtoken");
const { track: trackPulseIQ } = require("./utils/pulseiq");
let firebaseAdmin = null;
try {
  firebaseAdmin = require("firebase-admin");
} catch {
  firebaseAdmin = null;
}

dotenv.config();

const app = express();

app.use(cors());
app.use(express.json({ limit: "30mb" }));

const RATE_LIMIT_WINDOW_MS = Number(process.env.RATE_LIMIT_WINDOW_MS || 60_000);
const RATE_LIMIT_MAX = Number(process.env.RATE_LIMIT_MAX || 80);
const RATE_LIMIT_PATHS = new Set(["/chat", "/generate-image", "/generate-video"]);
const rateBuckets = new Map();

const metrics = {
  startedAt: new Date().toISOString(),
  totalRequests: 0,
  totalErrors: 0,
  rateLimitedRequests: 0,
  byPath: {},
};

function buildProjectStatusReport() {
  const modules = [
    {
      id: "chat_assistant",
      title: "AI Chat + NLP Intent Routing",
      status: "complete",
      mappedSynopsis: ["Abstract", "Objectives", "Methodology"],
      evidence: ["/chat", "detectIntent()", "handleChatIntent()"],
    },
    {
      id: "notes_tasks",
      title: "Notes + Task Management",
      status: "complete",
      mappedSynopsis: ["Objectives", "Problem Statement", "Expected Results"],
      evidence: ["/notes", "/tasks"],
    },
    {
      id: "offline_online_mode",
      title: "Online + Offline Functionality",
      status: "complete",
      mappedSynopsis: ["Abstract", "Objectives", "Expected Results"],
      evidence: ["offline command handling in chat screen", "/chat isOnlineMode"],
    },
    {
      id: "cross_platform_flutter",
      title: "Cross Platform Frontend (Flutter)",
      status: "complete",
      mappedSynopsis: ["Methodology", "System Architecture"],
      evidence: ["frontend/flutter_app"],
    },
    {
      id: "node_backend_architecture",
      title: "Node.js Modular Backend",
      status: "complete",
      mappedSynopsis: ["Methodology", "System Architecture"],
      evidence: ["/health", "Express API modules"],
    },
    {
      id: "advanced_integrations",
      title: "Google Integrations + Push + Workflows + Knowledge",
      status: "complete",
      mappedSynopsis: ["Conclusion", "Expected Results"],
      evidence: [
        "/integrations/google/*",
        "/notifications/*",
        "/assistant/jobs",
        "/knowledge/*",
      ],
    },
    {
      id: "testing_quality",
      title: "Automated Test Coverage",
      status: "partial",
      mappedSynopsis: ["Implementation Plan"],
      evidence: ["backend/tests/notifications.test.js"],
      remaining: "Expand to full assistant regression + API contract tests.",
    },
    {
      id: "production_deployment_observability",
      title: "Production Deployment + Observability",
      status: "remaining",
      mappedSynopsis: ["Implementation Plan", "Conclusion"],
      remaining:
        "Managed deployment, external monitoring, secrets vault, staged release.",
    },
    {
      id: "native_realtime_voice",
      title: "Native Always-on Wake Word + Realtime Duplex Voice",
      status: "remaining",
      mappedSynopsis: ["Conclusion (Future Enhancements)"],
      remaining: "Requires platform-native voice pipeline beyond current scope.",
    },
    {
      id: "vector_rag_documents",
      title: "Vector RAG for PDF/DOCX",
      status: "remaining",
      mappedSynopsis: ["Future Enhancements"],
      remaining: "Requires embedding index + advanced document parser pipeline.",
    },
  ];

  const completed = modules.filter((m) => m.status === "complete").length;
  const partial = modules.filter((m) => m.status === "partial").length;
  const total = modules.length;
  const completionPercent = Math.round(((completed + partial * 0.5) / total) * 100);

  return {
    generatedAt: nowIso(),
    completionPercent,
    completedModules: completed,
    partialModules: partial,
    totalModules: total,
    modules,
  };
}

function buildSynopsisAlignmentReport() {
  const report = buildProjectStatusReport();
  const sectionMap = [
    {
      section: "Abstract",
      status: "aligned",
      notes:
        "Multi-task AI assistant with chat, notes, tasks, intelligent responses, and online/offline behavior is implemented.",
    },
    {
      section: "Introduction",
      status: "aligned",
      notes:
        "Unified assistant experience is present and reduces app switching for users.",
    },
    {
      section: "Problem Statement",
      status: "aligned",
      notes:
        "Single platform combines chat, notes, tasks, and assistant automation.",
    },
    {
      section: "Objectives",
      status: "aligned",
      notes:
        "Core objective features are implemented with cross-platform Flutter + backend AI routing.",
    },
    {
      section: "Literature Review",
      status: "partial",
      notes:
        "References exist in synopsis; can still add comparative benchmark table in docs.",
    },
    {
      section: "Proposed Methodology",
      status: "aligned",
      notes:
        "Modular Flutter + Node.js architecture with API integration and local/offline storage is implemented.",
    },
    {
      section: "System Architecture",
      status: "aligned",
      notes:
        "Client-server flow with backend processing and storage is implemented.",
    },
    {
      section: "Implementation Plan",
      status: "partial",
      notes:
        "Most phases completed; production deployment/observability and broad test automation remain.",
    },
    {
      section: "Expected Results",
      status: "aligned",
      notes:
        "Functional assistant behavior meets expected chat/notes/tasks productivity outcomes.",
    },
    {
      section: "Conclusion/Future Work",
      status: "partial",
      notes:
        "Future enhancements still pending: native realtime voice and vector RAG documents.",
    },
  ];

  return {
    generatedAt: nowIso(),
    overallCompletionPercent: report.completionPercent,
    sections: sectionMap,
    remainingHighPriority: report.modules
      .filter((m) => m.status === "remaining")
      .map((m) => ({
        id: m.id,
        title: m.title,
        remaining: m.remaining || "",
      })),
  };
}

const JWT_SECRET = process.env.JWT_SECRET || "flowgnimag_dev_secret_change_me";
const JWT_EXPIRES_IN = process.env.JWT_EXPIRES_IN || "7d";
const ACCESS_TOKEN_EXPIRES_SECONDS = Number(
  process.env.ACCESS_TOKEN_EXPIRES_SECONDS || 900
);
const REFRESH_TOKEN_EXPIRES_DAYS = Number(
  process.env.REFRESH_TOKEN_EXPIRES_DAYS || 30
);
const DB_PATH =
  process.env.DB_PATH || path.join(process.cwd(), "data", "flowgnimag.db");
const MONGODB_URI = process.env.MONGODB_URI || "";
const MONGODB_DB_NAME = process.env.MONGODB_DB_NAME || "";
const MONGODB_RUNTIME_MODE =
  (process.env.MONGODB_RUNTIME_MODE || "sqlite").trim().toLowerCase();
const GOOGLE_CLIENT_ID = process.env.GOOGLE_CLIENT_ID || "";
const GOOGLE_CLIENT_SECRET = process.env.GOOGLE_CLIENT_SECRET || "";
const GOOGLE_OAUTH_REDIRECT_URI = process.env.GOOGLE_OAUTH_REDIRECT_URI || "";
const GOOGLE_OAUTH_SCOPES =
  process.env.GOOGLE_OAUTH_SCOPES ||
  "https://www.googleapis.com/auth/calendar.events https://www.googleapis.com/auth/calendar.readonly https://www.googleapis.com/auth/gmail.send https://www.googleapis.com/auth/gmail.readonly https://www.googleapis.com/auth/contacts.readonly https://www.googleapis.com/auth/userinfo.email";
const GOOGLE_OAUTH_SUCCESS_REDIRECT =
  process.env.GOOGLE_OAUTH_SUCCESS_REDIRECT || "";
const GOOGLE_TOKEN_URL = "https://oauth2.googleapis.com/token";
const GOOGLE_AUTH_URL = "https://accounts.google.com/o/oauth2/v2/auth";
const GOOGLE_CALENDAR_API_BASE = "https://www.googleapis.com/calendar/v3";
const GOOGLE_GMAIL_API_BASE = "https://gmail.googleapis.com/gmail/v1";
const GOOGLE_PEOPLE_API_BASE = "https://people.googleapis.com/v1";
const GOOGLE_OAUTH_USERINFO_URL =
  "https://www.googleapis.com/oauth2/v2/userinfo";
const FIREBASE_PROJECT_ID = process.env.FIREBASE_PROJECT_ID || "";
const FIREBASE_CLIENT_EMAIL = process.env.FIREBASE_CLIENT_EMAIL || "";
const FIREBASE_PRIVATE_KEY = process.env.FIREBASE_PRIVATE_KEY || "";
const GOOGLE_PUSH_POLL_INTERVAL_MS = Number(
  process.env.GOOGLE_PUSH_POLL_INTERVAL_MS || 180_000
);
const ALLOW_FAKE_FCM_FOR_TESTS =
  process.env.ALLOW_FAKE_FCM_FOR_TESTS === "1";

let db = null;
let mongoClient = null;
let mongoDb = null;
let mongoMirrorSyncInProgress = false;
let mongoMirrorBootstrapComplete = false;
let mongoMirrorLastSyncAt = "";
let mongoMirrorSyncQueued = false;
let mongoMirrorSyncTimer = null;
let firebaseMessaging = null;
let googlePushIntervalRef = null;

const SQLITE_MIRROR_TABLES = [
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

function ensureDbDirectory() {
  const dir = path.dirname(DB_PATH);
  require("fs").mkdirSync(dir, { recursive: true });
}

function parseMongoDbName() {
  if (MONGODB_DB_NAME.trim()) {
    return MONGODB_DB_NAME.trim();
  }
  if (!MONGODB_URI.trim()) {
    return "flowgnimag";
  }
  try {
    const uri = new URL(MONGODB_URI);
    const pathname = (uri.pathname || "").replace(/^\//, "").trim();
    if (pathname) return pathname;
  } catch {}
  return "flowgnimag";
}

function redactMongoUri(uri = "") {
  if (!uri || typeof uri !== "string") return "";
  return uri.replace(/\/\/([^:@\/]+):([^@\/]+)@/g, "//$1:***@");
}

function parseMongoHostFromUri(uri = "") {
  if (!uri || typeof uri !== "string") return "";
  const trimmed = uri.trim();
  if (!trimmed.startsWith("mongodb+srv://")) return "";
  const noScheme = trimmed.replace("mongodb+srv://", "");
  const afterCreds = noScheme.includes("@") ? noScheme.split("@")[1] : noScheme;
  const host = afterCreds.split("/")[0] || "";
  return host.trim();
}

async function initializeMongo() {
  if (!MONGODB_URI.trim()) return false;
  if (mongoDb) return true;
  try {
    mongoClient = new MongoClient(MONGODB_URI, {
      maxPoolSize: 10,
      minPoolSize: 0,
      serverSelectionTimeoutMS: 10000,
    });
    await mongoClient.connect();
    mongoDb = mongoClient.db(parseMongoDbName());
    return true;
  } catch (error) {
    console.error("Mongo initialization failed:", error?.message);
    mongoDb = null;
    if (mongoClient) {
      try {
        await mongoClient.close();
      } catch {}
    }
    mongoClient = null;
    return false;
  }
}

function isMongoMirrorModeEnabled() {
  return (
    MONGODB_RUNTIME_MODE === "mirror" &&
    Boolean(mongoDb) &&
    Boolean(db)
  );
}

function sqliteTableExists(table) {
  const row = db
    .prepare(
      "SELECT name FROM sqlite_master WHERE type='table' AND name = ? LIMIT 1"
    )
    .get(table);
  return Boolean(row?.name);
}

function getSqliteTableColumns(table) {
  if (!sqliteTableExists(table)) return [];
  return db
    .prepare(`PRAGMA table_info(${table})`)
    .all()
    .map((row) => String(row.name || ""))
    .filter((name) => name.length > 0);
}

async function syncSqliteTableToMongo(table) {
  if (!mongoDb || !db || !sqliteTableExists(table)) return;
  const rows = db.prepare(`SELECT * FROM ${table}`).all();
  const collection = mongoDb.collection(table);
  await collection.deleteMany({});
  if (rows.length > 0) {
    await collection.insertMany(rows, { ordered: false });
  }
}

async function syncSqliteToMongo({ force = false } = {}) {
  if (!isMongoMirrorModeEnabled()) return false;
  if (mongoMirrorSyncInProgress && !force) return false;
  mongoMirrorSyncInProgress = true;
  try {
    for (const table of SQLITE_MIRROR_TABLES) {
      await syncSqliteTableToMongo(table);
    }
    mongoMirrorLastSyncAt = nowIso();
    return true;
  } catch (error) {
    console.error("Mongo mirror sync failed:", error?.message);
    return false;
  } finally {
    mongoMirrorSyncInProgress = false;
  }
}

function sanitizeMongoRowsForSqlite(table, rows) {
  const columns = new Set(getSqliteTableColumns(table));
  return rows.map((row) => {
    const next = {};
    for (const [key, value] of Object.entries(row || {})) {
      if (key === "_id") continue;
      if (!columns.has(key)) continue;
      next[key] = value;
    }
    return next;
  });
}

function replaceSqliteTableData(table, rows) {
  if (!sqliteTableExists(table)) return;
  const columns = getSqliteTableColumns(table);
  if (columns.length === 0) return;

  db.prepare(`DELETE FROM ${table}`).run();
  if (!Array.isArray(rows) || rows.length === 0) return;

  const validRows = sanitizeMongoRowsForSqlite(table, rows);
  if (validRows.length === 0) return;

  const insertColumns = columns.filter((col) =>
    Object.prototype.hasOwnProperty.call(validRows[0], col)
  );
  if (insertColumns.length === 0) return;

  const placeholders = insertColumns.map(() => "?").join(",");
  const sql = `INSERT INTO ${table} (${insertColumns.join(",")}) VALUES (${placeholders})`;
  const stmt = db.prepare(sql);
  const tx = db.transaction((payload) => {
    for (const row of payload) {
      const values = insertColumns.map((col) => row[col]);
      stmt.run(...values);
    }
  });
  tx(validRows);
}

async function restoreMongoIntoSqlite() {
  if (!isMongoMirrorModeEnabled()) return false;
  try {
    for (const table of SQLITE_MIRROR_TABLES) {
      if (!sqliteTableExists(table)) continue;
      const rows = await mongoDb
        .collection(table)
        .find({}, { projection: { _id: 0 } })
        .toArray();
      replaceSqliteTableData(table, rows);
    }
    return true;
  } catch (error) {
    console.error("Mongo restore into sqlite failed:", error?.message);
    return false;
  }
}

async function bootstrapMongoMirror() {
  if (!isMongoMirrorModeEnabled()) return false;
  try {
    let mongoTotal = 0;
    for (const table of SQLITE_MIRROR_TABLES) {
      const count = await mongoDb.collection(table).countDocuments();
      mongoTotal += count;
      if (mongoTotal > 0) break;
    }

    if (mongoTotal > 0) {
      await restoreMongoIntoSqlite();
      mongoMirrorLastSyncAt = nowIso();
      mongoMirrorBootstrapComplete = true;
      return true;
    }

    await syncSqliteToMongo({ force: true });
    mongoMirrorBootstrapComplete = true;
    return true;
  } catch (error) {
    console.error("Mongo mirror bootstrap failed:", error?.message);
    return false;
  }
}

function scheduleMongoMirrorSync() {
  if (!isMongoMirrorModeEnabled()) return;
  mongoMirrorSyncQueued = true;
  if (mongoMirrorSyncTimer) return;
  mongoMirrorSyncTimer = setTimeout(async () => {
    mongoMirrorSyncTimer = null;
    if (!mongoMirrorSyncQueued) return;
    mongoMirrorSyncQueued = false;
    await syncSqliteToMongo();
  }, 350);
}

function initializeDatabase() {
  ensureDbDirectory();
  db = new Database(DB_PATH);
  db.pragma("journal_mode = WAL");
  db.pragma("foreign_keys = ON");

  db.exec(`
    CREATE TABLE IF NOT EXISTS users (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL,
      email TEXT NOT NULL UNIQUE,
      password_hash TEXT NOT NULL,
      created_at TEXT NOT NULL DEFAULT (datetime('now'))
    );

    CREATE TABLE IF NOT EXISTS chat_sessions (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id INTEGER NOT NULL,
      title TEXT NOT NULL,
      is_pinned INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      updated_at TEXT NOT NULL DEFAULT (datetime('now')),
      FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
    );

    CREATE TABLE IF NOT EXISTS chat_messages (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      session_id INTEGER NOT NULL,
      role TEXT NOT NULL,
      text TEXT NOT NULL,
      type TEXT NOT NULL DEFAULT 'chat',
      code TEXT NOT NULL DEFAULT '',
      image_prompt TEXT NOT NULL DEFAULT '',
      video_prompt TEXT NOT NULL DEFAULT '',
      action TEXT NOT NULL DEFAULT '',
      url TEXT NOT NULL DEFAULT '',
      info TEXT NOT NULL DEFAULT '',
      suggestions_json TEXT NOT NULL DEFAULT '[]',
      starred INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      FOREIGN KEY (session_id) REFERENCES chat_sessions(id) ON DELETE CASCADE
    );

    CREATE TABLE IF NOT EXISTS notes (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id INTEGER NOT NULL,
      text TEXT NOT NULL,
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      updated_at TEXT NOT NULL DEFAULT (datetime('now')),
      FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
    );

    CREATE TABLE IF NOT EXISTS tasks (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id INTEGER NOT NULL,
      title TEXT NOT NULL,
      done INTEGER NOT NULL DEFAULT 0,
      priority TEXT NOT NULL DEFAULT 'Medium',
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      updated_at TEXT NOT NULL DEFAULT (datetime('now')),
      FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
    );

    CREATE TABLE IF NOT EXISTS user_memories (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id INTEGER NOT NULL,
      memory_key TEXT NOT NULL,
      memory_text TEXT NOT NULL,
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      updated_at TEXT NOT NULL DEFAULT (datetime('now')),
      FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
      UNIQUE(user_id, memory_key)
    );

    CREATE TABLE IF NOT EXISTS knowledge_documents (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id INTEGER NOT NULL,
      title TEXT NOT NULL,
      content TEXT NOT NULL,
      tags_json TEXT NOT NULL DEFAULT '[]',
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      updated_at TEXT NOT NULL DEFAULT (datetime('now')),
      FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
    );

    CREATE TABLE IF NOT EXISTS assistant_jobs (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id INTEGER NOT NULL,
      title TEXT NOT NULL,
      goal TEXT NOT NULL,
      status TEXT NOT NULL DEFAULT 'active',
      steps_json TEXT NOT NULL DEFAULT '[]',
      current_step_index INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      updated_at TEXT NOT NULL DEFAULT (datetime('now')),
      FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
    );

    CREATE TABLE IF NOT EXISTS google_oauth_states (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id INTEGER NOT NULL,
      state TEXT NOT NULL UNIQUE,
      used INTEGER NOT NULL DEFAULT 0,
      expires_at TEXT NOT NULL,
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
    );

    CREATE TABLE IF NOT EXISTS google_calendar_tokens (
      user_id INTEGER PRIMARY KEY,
      access_token TEXT NOT NULL,
      refresh_token TEXT NOT NULL DEFAULT '',
      token_type TEXT NOT NULL DEFAULT 'Bearer',
      scope TEXT NOT NULL DEFAULT '',
      expiry_date TEXT NOT NULL,
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      updated_at TEXT NOT NULL DEFAULT (datetime('now')),
      FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
    );

    CREATE TABLE IF NOT EXISTS push_devices (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id INTEGER NOT NULL,
      token TEXT NOT NULL,
      platform TEXT NOT NULL DEFAULT 'unknown',
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      updated_at TEXT NOT NULL DEFAULT (datetime('now')),
      FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
      UNIQUE(user_id, token)
    );

    CREATE TABLE IF NOT EXISTS google_push_state (
      user_id INTEGER PRIMARY KEY,
      gmail_ids_json TEXT NOT NULL DEFAULT '[]',
      event_ids_json TEXT NOT NULL DEFAULT '[]',
      updated_at TEXT NOT NULL DEFAULT (datetime('now')),
      FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
    );

    CREATE TABLE IF NOT EXISTS auth_refresh_tokens (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id INTEGER NOT NULL,
      token_hash TEXT NOT NULL UNIQUE,
      expires_at TEXT NOT NULL,
      revoked_at TEXT NOT NULL DEFAULT '',
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      last_used_at TEXT NOT NULL DEFAULT (datetime('now')),
      user_agent TEXT NOT NULL DEFAULT '',
      ip_address TEXT NOT NULL DEFAULT '',
      FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
    );
  `);

  const chatMessageColumns = db
    .prepare("PRAGMA table_info(chat_messages)")
    .all()
    .map((row) => String(row.name || "").toLowerCase());

  if (!chatMessageColumns.includes("suggestions_json")) {
    db.exec(
      "ALTER TABLE chat_messages ADD COLUMN suggestions_json TEXT NOT NULL DEFAULT '[]'"
    );
  }
}

function nowIso() {
  return new Date().toISOString();
}

function secondsFromNow(seconds) {
  const ms = Math.max(1, Math.floor(seconds)) * 1000;
  return new Date(Date.now() + ms).toISOString();
}

function daysFromNow(days) {
  const ms = Math.max(1, Math.floor(days)) * 24 * 60 * 60 * 1000;
  return new Date(Date.now() + ms).toISOString();
}

function hashOpaqueToken(value) {
  return crypto.createHash("sha256").update(String(value || "")).digest("hex");
}

function createOpaqueToken() {
  return crypto.randomBytes(48).toString("base64url");
}

function getRequestIp(req) {
  const forwarded = String(req.headers["x-forwarded-for"] || "")
    .split(",")[0]
    .trim();
  return cleanText(forwarded || req.socket?.remoteAddress || "", 120);
}

function signToken(user, expiresIn = `${ACCESS_TOKEN_EXPIRES_SECONDS}s`) {
  return jwt.sign(
    {
      sub: String(user.id),
      email: user.email,
      name: user.name,
      tokenType: "access",
    },
    JWT_SECRET,
    { expiresIn }
  );
}

function issueRefreshToken(userId, req) {
  const raw = createOpaqueToken();
  const tokenHash = hashOpaqueToken(raw);
  const now = nowIso();
  const expiresAt = daysFromNow(REFRESH_TOKEN_EXPIRES_DAYS);

  db.prepare(
    `INSERT INTO auth_refresh_tokens
     (user_id, token_hash, expires_at, revoked_at, created_at, last_used_at, user_agent, ip_address)
     VALUES (?, ?, ?, '', ?, ?, ?, ?)`
  ).run(
    userId,
    tokenHash,
    expiresAt,
    now,
    now,
    cleanText(req.headers["user-agent"], 500),
    getRequestIp(req)
  );

  return raw;
}

function revokeRefreshToken(rawToken) {
  const tokenHash = hashOpaqueToken(rawToken);
  db.prepare(
    "UPDATE auth_refresh_tokens SET revoked_at = ? WHERE token_hash = ? AND revoked_at = ''"
  ).run(nowIso(), tokenHash);
}

function revokeUserRefreshTokens(userId) {
  db.prepare(
    "UPDATE auth_refresh_tokens SET revoked_at = ? WHERE user_id = ? AND revoked_at = ''"
  ).run(nowIso(), userId);
}

function issueAuthSession(user, req) {
  const accessToken = signToken(
    { id: user.id, name: user.name, email: user.email },
    `${ACCESS_TOKEN_EXPIRES_SECONDS}s`
  );
  const refreshToken = issueRefreshToken(user.id, req);
  return {
    token: accessToken,
    refreshToken,
    accessTokenExpiresAt: secondsFromNow(ACCESS_TOKEN_EXPIRES_SECONDS),
    refreshTokenExpiresAt: daysFromNow(REFRESH_TOKEN_EXPIRES_DAYS),
  };
}

function getUserById(userId) {
  return db
    .prepare("SELECT id, name, email, created_at FROM users WHERE id = ?")
    .get(userId);
}

function rotateRefreshSession(refreshToken, req) {
  const tokenHash = hashOpaqueToken(refreshToken);
  const row = db
    .prepare(
      `SELECT id, user_id, expires_at, revoked_at
       FROM auth_refresh_tokens
       WHERE token_hash = ?`
    )
    .get(tokenHash);

  if (!row) {
    return { ok: false, status: 401, error: "Invalid refresh token" };
  }
  if (cleanText(row.revoked_at, 80)) {
    return { ok: false, status: 401, error: "Refresh token revoked" };
  }

  const expiresAt = Date.parse(String(row.expires_at || ""));
  if (!Number.isFinite(expiresAt) || expiresAt <= Date.now()) {
    db.prepare("UPDATE auth_refresh_tokens SET revoked_at = ? WHERE id = ?").run(
      nowIso(),
      row.id
    );
    return { ok: false, status: 401, error: "Refresh token expired" };
  }

  db.prepare(
    "UPDATE auth_refresh_tokens SET revoked_at = ?, last_used_at = ? WHERE id = ? AND revoked_at = ''"
  ).run(nowIso(), nowIso(), row.id);

  const user = getUserById(Number(row.user_id));
  if (!user) {
    return { ok: false, status: 404, error: "User not found" };
  }

  const session = issueAuthSession(user, req);
  return { ok: true, user, session };
}

function getAuthToken(req) {
  const header = req.headers.authorization || "";
  if (!header.toLowerCase().startsWith("bearer ")) {
    return "";
  }
  return header.slice(7).trim();
}

function requireAuth(req, res, next) {
  try {
    const token = getAuthToken(req);
    if (!token) {
      return res.status(401).json({ error: "Missing auth token" });
    }
    const payload = jwt.verify(token, JWT_SECRET);
    const tokenType = String(payload.tokenType || "");
    if (tokenType && tokenType !== "access") {
      return res.status(401).json({ error: "Invalid auth token" });
    }
    const userId = Number(payload.sub);
    if (!Number.isFinite(userId) || userId <= 0) {
      return res.status(401).json({ error: "Invalid auth token" });
    }
    req.auth = { userId };
    return next();
  } catch {
    return res.status(401).json({ error: "Invalid or expired token" });
  }
}

function getOptionalAuthUserId(req) {
  try {
    const token = getAuthToken(req);
    if (!token) return null;
    const payload = jwt.verify(token, JWT_SECRET);
    const tokenType = String(payload.tokenType || "");
    if (tokenType && tokenType !== "access") return null;
    const userId = Number(payload.sub);
    if (!Number.isFinite(userId) || userId <= 0) return null;
    return userId;
  } catch {
    return null;
  }
}

function validEmail(email) {
  const value = String(email || "").trim().toLowerCase();
  if (!value) return "";
  const ok = /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value);
  return ok ? value : "";
}

function cleanText(value, max = 4000) {
  const text = String(value || "").trim();
  if (!text) return "";
  return text.length > max ? text.slice(0, max) : text;
}

function normalizeSuggestions(value) {
  if (!Array.isArray(value)) return [];
  return value
    .map((item) => cleanText(item, 120))
    .filter((item) => item.length > 0)
    .slice(0, 6);
}

function serializeSuggestions(value) {
  return JSON.stringify(normalizeSuggestions(value));
}

function parseSuggestionsJson(value) {
  if (typeof value !== "string" || !value.trim()) return [];
  try {
    return normalizeSuggestions(JSON.parse(value));
  } catch {
    return [];
  }
}

function parseStringListJson(value, max = 100, itemMaxLen = 300) {
  if (typeof value !== "string" || !value.trim()) return [];
  try {
    const decoded = JSON.parse(value);
    if (!Array.isArray(decoded)) return [];
    return decoded
      .map((item) => cleanText(item, itemMaxLen))
      .filter((item) => item.length > 0)
      .slice(0, max);
  } catch {
    return [];
  }
}

function isFcmConfigured() {
  return Boolean(
    firebaseAdmin &&
      FIREBASE_PROJECT_ID.trim() &&
      FIREBASE_CLIENT_EMAIL.trim() &&
      FIREBASE_PRIVATE_KEY.trim()
  );
}

function isFakeFcmTestMode() {
  return (
    ALLOW_FAKE_FCM_FOR_TESTS &&
    String(process.env.NODE_ENV || "").toLowerCase() === "test"
  );
}

function fileExistsSafe(filePath) {
  try {
    return fs.existsSync(filePath);
  } catch {
    return false;
  }
}

function detectFirebaseConfigFiles() {
  const roots = [
    process.cwd(),
    path.resolve(process.cwd(), ".."),
    path.resolve(process.cwd(), "../.."),
  ];

  const androidRel = path.join(
    "frontend",
    "flutter_app",
    "android",
    "app",
    "google-services.json"
  );
  const iosRel = path.join(
    "frontend",
    "flutter_app",
    "ios",
    "Runner",
    "GoogleService-Info.plist"
  );

  const androidCandidates = roots.map((root) => path.join(root, androidRel));
  const iosCandidates = roots.map((root) => path.join(root, iosRel));

  const androidPath = androidCandidates.find((item) => fileExistsSafe(item)) || "";
  const iosPath = iosCandidates.find((item) => fileExistsSafe(item)) || "";

  return {
    androidGoogleServicesPresent: Boolean(androidPath),
    iosGoogleServiceInfoPresent: Boolean(iosPath),
    androidGoogleServicesPath: androidPath,
    iosGoogleServiceInfoPath: iosPath,
  };
}

function initializeFirebaseAdmin() {
  if (!isFcmConfigured()) return false;
  if (firebaseMessaging) return true;

  try {
    const privateKey = FIREBASE_PRIVATE_KEY.replace(/\\n/g, "\n");
    const credential = firebaseAdmin.credential.cert({
      projectId: FIREBASE_PROJECT_ID,
      clientEmail: FIREBASE_CLIENT_EMAIL,
      privateKey,
    });

    if (firebaseAdmin.apps.length === 0) {
      firebaseAdmin.initializeApp({
        credential,
        projectId: FIREBASE_PROJECT_ID,
      });
    }

    firebaseMessaging = firebaseAdmin.messaging();
    return true;
  } catch (error) {
    console.error("Firebase admin initialization failed:", error?.message);
    firebaseMessaging = null;
    return false;
  }
}

function getGooglePushStateRow(userId) {
  return db
    .prepare(
      `SELECT user_id, gmail_ids_json, event_ids_json, updated_at
       FROM google_push_state
       WHERE user_id = ?`
    )
    .get(userId);
}

function loadGooglePushState(userId) {
  const row = getGooglePushStateRow(userId);
  return {
    gmailIds: parseStringListJson(row?.gmail_ids_json || "[]", 100, 300),
    eventIds: parseStringListJson(row?.event_ids_json || "[]", 100, 300),
  };
}

function saveGooglePushState(userId, gmailIds = [], eventIds = []) {
  const nextGmail = (Array.isArray(gmailIds) ? gmailIds : [])
    .map((item) => cleanText(item, 300))
    .filter((item) => item.length > 0)
    .slice(0, 80);
  const nextEvents = (Array.isArray(eventIds) ? eventIds : [])
    .map((item) => cleanText(item, 300))
    .filter((item) => item.length > 0)
    .slice(0, 80);
  const now = nowIso();
  const existing = getGooglePushStateRow(userId);

  if (existing) {
    db.prepare(
      `UPDATE google_push_state
       SET gmail_ids_json = ?, event_ids_json = ?, updated_at = ?
       WHERE user_id = ?`
    ).run(JSON.stringify(nextGmail), JSON.stringify(nextEvents), now, userId);
    return;
  }

  db.prepare(
    `INSERT INTO google_push_state (user_id, gmail_ids_json, event_ids_json, updated_at)
     VALUES (?, ?, ?, ?)`
  ).run(userId, JSON.stringify(nextGmail), JSON.stringify(nextEvents), now);
}

async function sendFcmToUserDevices(userId, payload) {
  const tokens = db
    .prepare("SELECT token FROM push_devices WHERE user_id = ?")
    .all(userId)
    .map((row) => cleanText(row.token, 800))
    .filter((item) => item.length > 0);

  if (tokens.length === 0) return { sent: 0, invalid: 0 };
  if (isFakeFcmTestMode()) {
    return { sent: tokens.length, invalid: 0 };
  }
  if (!initializeFirebaseAdmin()) return { sent: 0, invalid: 0 };

  const response = await firebaseMessaging.sendEachForMulticast({
    tokens,
    notification: {
      title: cleanText(payload?.title, 120) || "FLOWGNIMAG Alert",
      body: cleanText(payload?.body, 240) || "",
    },
    data: {
      type: cleanText(payload?.type, 40) || "google_alert",
      ts: String(Date.now()),
    },
    android: {
      priority: "high",
      notification: {
        channelId: "flowgnimag_google_alerts",
      },
    },
  });

  let invalid = 0;
  const invalidTokens = [];
  response.responses.forEach((result, index) => {
    if (result.success) return;
    const code = result.error?.code || "";
    const isInvalid =
      String(code).includes("registration-token-not-registered") ||
      String(code).includes("invalid-registration-token");
    if (isInvalid) {
      invalid += 1;
      invalidTokens.push(tokens[index]);
    }
  });

  for (const token of invalidTokens) {
    db.prepare("DELETE FROM push_devices WHERE user_id = ? AND token = ?").run(
      userId,
      token
    );
  }

  return { sent: response.successCount, invalid };
}

function formatPushEmailSummary(item = {}) {
  const subject = cleanText(item.subject, 80) || "(No subject)";
  const from = cleanText(item.from, 80) || "Unknown sender";
  return `${subject} - ${from}`;
}

function formatPushEventSummary(item = {}) {
  const summary = cleanText(item.summary, 80) || "Upcoming event";
  const start = cleanText(item.start, 40).replace("T", " ");
  const shortStart = start.length > 16 ? start.slice(0, 16) : start;
  return shortStart ? `${summary} at ${shortStart}` : summary;
}

async function runGooglePushCycle() {
  if (!initializeFirebaseAdmin()) return;

  const users = db
    .prepare(
      `SELECT DISTINCT t.user_id AS user_id
       FROM google_calendar_tokens t
       JOIN push_devices p ON p.user_id = t.user_id`
    )
    .all();

  for (const row of users) {
    const userId = Number(row.user_id);
    if (!Number.isFinite(userId) || userId <= 0) continue;

    try {
      const emails = await listGmailMessages(userId, { maxResults: 8 });
      const events = await listGoogleCalendarEvents(userId, { maxResults: 8 });

      const currentEmailIds = emails
        .map((item) => cleanText(item.id, 200))
        .filter((item) => item.length > 0);
      const currentEventIds = events
        .map((item) => cleanText(item.id, 200))
        .filter((item) => item.length > 0);

      const state = loadGooglePushState(userId);
      const firstBaseline = state.gmailIds.length === 0 && state.eventIds.length === 0;

      if (!firstBaseline) {
        const newEmails = emails
          .filter((item) => {
            const id = cleanText(item.id, 200);
            return id && !state.gmailIds.includes(id);
          })
          .slice(0, 2);

        for (const item of newEmails) {
          await sendFcmToUserDevices(userId, {
            type: "gmail_new",
            title: "New Gmail",
            body: formatPushEmailSummary(item),
          });
        }

        const newEvents = events
          .filter((item) => {
            const id = cleanText(item.id, 200);
            return id && !state.eventIds.includes(id);
          })
          .slice(0, 2);

        for (const item of newEvents) {
          await sendFcmToUserDevices(userId, {
            type: "calendar_new",
            title: "Calendar Update",
            body: formatPushEventSummary(item),
          });
        }
      }

      saveGooglePushState(userId, currentEmailIds, currentEventIds);
    } catch (error) {
      console.error(`Google push cycle failed for user ${userId}:`, error?.message);
    }
  }
}

function startGooglePushScheduler() {
  if (!initializeFirebaseAdmin()) return;
  if (googlePushIntervalRef) return;

  googlePushIntervalRef = setInterval(() => {
    runGooglePushCycle().catch((error) => {
      console.error("Google push scheduler cycle failed:", error?.message);
    });
  }, Math.max(60_000, GOOGLE_PUSH_POLL_INTERVAL_MS));

  setTimeout(() => {
    runGooglePushCycle().catch((error) => {
      console.error("Google push scheduler bootstrap failed:", error?.message);
    });
  }, 5_000);
}

function buildPushDoctorReport(userId) {
  const files = detectFirebaseConfigFiles();
  const envChecks = {
    firebaseProjectId: FIREBASE_PROJECT_ID.trim().length > 0,
    firebaseClientEmail: FIREBASE_CLIENT_EMAIL.trim().length > 0,
    firebasePrivateKey: FIREBASE_PRIVATE_KEY.trim().length > 0,
  };

  const tokenRows = db
    .prepare(
      `SELECT platform, updated_at
       FROM push_devices
       WHERE user_id = ?
       ORDER BY updated_at DESC`
    )
    .all(userId);

  const checks = [
    {
      id: "backend_env",
      ok: envChecks.firebaseProjectId && envChecks.firebaseClientEmail && envChecks.firebasePrivateKey,
      detail: "FIREBASE_PROJECT_ID, FIREBASE_CLIENT_EMAIL, FIREBASE_PRIVATE_KEY",
    },
    {
      id: "firebase_admin_ready",
      ok:
        isFakeFcmTestMode() ||
        Boolean(firebaseMessaging) ||
        initializeFirebaseAdmin(),
      detail: "firebase-admin initialized on backend",
    },
    {
      id: "android_file",
      ok: files.androidGoogleServicesPresent,
      detail: "android/app/google-services.json present",
    },
    {
      id: "ios_file",
      ok: files.iosGoogleServiceInfoPresent,
      detail: "ios/Runner/GoogleService-Info.plist present",
    },
    {
      id: "device_registered",
      ok: tokenRows.length > 0,
      detail: "at least one push device token is registered for this account",
    },
  ];

  const missing = checks.filter((item) => !item.ok).map((item) => item.detail);
  const recommendedActions = [];
  if (!checks.find((item) => item.id === "backend_env")?.ok) {
    recommendedActions.push(
      "Set FIREBASE_PROJECT_ID, FIREBASE_CLIENT_EMAIL, and FIREBASE_PRIVATE_KEY in backend/.env then restart backend."
    );
  }
  if (!checks.find((item) => item.id === "android_file")?.ok) {
    recommendedActions.push(
      "Download Firebase Android config and place it at frontend/flutter_app/android/app/google-services.json."
    );
  }
  if (!checks.find((item) => item.id === "ios_file")?.ok) {
    recommendedActions.push(
      "Download Firebase iOS config and place it at frontend/flutter_app/ios/Runner/GoogleService-Info.plist."
    );
  }
  if (!checks.find((item) => item.id === "device_registered")?.ok) {
    recommendedActions.push(
      "Login in app and keep Settings open once so device token can register via /notifications/register."
    );
  }

  return {
    ready: missing.length === 0,
    summary:
      missing.length === 0
        ? "Push pipeline looks ready."
        : `Missing ${missing.length} item(s).`,
    missing,
    recommendedActions,
    checks,
    devices: tokenRows.map((item) => ({
      platform: cleanText(item.platform, 40) || "unknown",
      updatedAt: item.updated_at || "",
    })),
  };
}

function isGoogleCalendarConfigured() {
  return Boolean(
    GOOGLE_CLIENT_ID.trim() &&
      GOOGLE_CLIENT_SECRET.trim() &&
      GOOGLE_OAUTH_REDIRECT_URI.trim()
  );
}

function cleanupExpiredGoogleOAuthStates() {
  db.prepare(
    "DELETE FROM google_oauth_states WHERE used = 1 OR expires_at < ?"
  ).run(nowIso());
}

function buildGoogleCalendarAuthUrl(userId) {
  if (!isGoogleCalendarConfigured()) {
    return { ok: false, error: "Google Calendar integration is not configured" };
  }

  cleanupExpiredGoogleOAuthStates();

  const state = crypto.randomBytes(24).toString("hex");
  const expiresAt = new Date(Date.now() + 10 * 60 * 1000).toISOString();
  db.prepare(
    "INSERT INTO google_oauth_states (user_id, state, used, expires_at, created_at) VALUES (?, ?, 0, ?, ?)"
  ).run(userId, state, expiresAt, nowIso());

  const params = new URLSearchParams({
    client_id: GOOGLE_CLIENT_ID,
    redirect_uri: GOOGLE_OAUTH_REDIRECT_URI,
    response_type: "code",
    scope: GOOGLE_OAUTH_SCOPES,
    access_type: "offline",
    include_granted_scopes: "true",
    prompt: "consent",
    state,
  });

  return {
    ok: true,
    state,
    url: `${GOOGLE_AUTH_URL}?${params.toString()}`,
    expiresAt,
  };
}

function getGoogleTokenRow(userId) {
  return db
    .prepare(
      `SELECT user_id, access_token, refresh_token, token_type, scope, expiry_date, created_at, updated_at
       FROM google_calendar_tokens
       WHERE user_id = ?`
    )
    .get(userId);
}

function saveGoogleTokens(userId, tokenData = {}, existingRefreshToken = "") {
  const accessToken = cleanText(tokenData.access_token, 4000);
  const refreshToken =
    cleanText(tokenData.refresh_token, 4000) || existingRefreshToken || "";
  const tokenType = cleanText(tokenData.token_type, 30) || "Bearer";
  const scope = cleanText(tokenData.scope, 1000);
  const expiresIn = Number(tokenData.expires_in || 3600);
  const expiryDate = new Date(
    Date.now() + Math.max(60, expiresIn) * 1000
  ).toISOString();
  const now = nowIso();

  if (!accessToken) {
    throw new Error("Google access token missing");
  }

  const existing = getGoogleTokenRow(userId);
  if (existing) {
    db.prepare(
      `UPDATE google_calendar_tokens
       SET access_token = ?, refresh_token = ?, token_type = ?, scope = ?, expiry_date = ?, updated_at = ?
       WHERE user_id = ?`
    ).run(accessToken, refreshToken, tokenType, scope, expiryDate, now, userId);
    return getGoogleTokenRow(userId);
  }

  db.prepare(
    `INSERT INTO google_calendar_tokens
     (user_id, access_token, refresh_token, token_type, scope, expiry_date, created_at, updated_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?)`
  ).run(userId, accessToken, refreshToken, tokenType, scope, expiryDate, now, now);
  return getGoogleTokenRow(userId);
}

async function exchangeGoogleAuthCode(code) {
  const params = new URLSearchParams({
    code: String(code || ""),
    client_id: GOOGLE_CLIENT_ID,
    client_secret: GOOGLE_CLIENT_SECRET,
    redirect_uri: GOOGLE_OAUTH_REDIRECT_URI,
    grant_type: "authorization_code",
  });

  const response = await fetch(GOOGLE_TOKEN_URL, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: params.toString(),
  });

  const data = await response.json();
  if (!response.ok) {
    throw new Error(
      data?.error_description || data?.error || "Google OAuth exchange failed"
    );
  }

  return data;
}

async function refreshGoogleAccessToken(userId, refreshToken) {
  const token = cleanText(refreshToken, 4000);
  if (!token) {
    throw new Error("Missing Google refresh token");
  }

  const params = new URLSearchParams({
    refresh_token: token,
    client_id: GOOGLE_CLIENT_ID,
    client_secret: GOOGLE_CLIENT_SECRET,
    grant_type: "refresh_token",
  });

  const response = await fetch(GOOGLE_TOKEN_URL, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: params.toString(),
  });
  const data = await response.json();
  if (!response.ok) {
    throw new Error(
      data?.error_description || data?.error || "Google token refresh failed"
    );
  }

  return saveGoogleTokens(userId, data, token);
}

async function getValidGoogleAccessToken(userId) {
  if (!isGoogleCalendarConfigured()) {
    throw new Error("Google Calendar integration is not configured");
  }

  const row = getGoogleTokenRow(userId);
  if (!row) {
    throw new Error("Google Calendar is not connected");
  }

  const expiryTs = Date.parse(String(row.expiry_date || ""));
  const shouldRefresh =
    !Number.isFinite(expiryTs) || expiryTs <= Date.now() + 60 * 1000;

  if (!shouldRefresh) {
    return { accessToken: row.access_token, tokenRow: row };
  }

  const refreshed = await refreshGoogleAccessToken(userId, row.refresh_token);
  return { accessToken: refreshed.access_token, tokenRow: refreshed };
}

async function googleCalendarRequest(userId, method, path, query = {}, body = null) {
  const requestUrl = new URL(`${GOOGLE_CALENDAR_API_BASE}${path}`);
  for (const [key, value] of Object.entries(query || {})) {
    if (value == null || value === "") continue;
    requestUrl.searchParams.set(key, String(value));
  }

  const runRequest = async (accessToken) => {
    const response = await fetch(requestUrl.toString(), {
      method,
      headers: {
        Authorization: `Bearer ${accessToken}`,
        "Content-Type": "application/json",
      },
      body: body == null ? undefined : JSON.stringify(body),
    });
    const data = await response.json().catch(() => ({}));
    return { response, data };
  };

  let { accessToken } = await getValidGoogleAccessToken(userId);
  let { response, data } = await runRequest(accessToken);

  if (response.status === 401) {
    const row = getGoogleTokenRow(userId);
    if (row?.refresh_token) {
      const refreshed = await refreshGoogleAccessToken(userId, row.refresh_token);
      accessToken = refreshed.access_token;
      ({ response, data } = await runRequest(accessToken));
    }
  }

  if (!response.ok) {
    const message =
      data?.error?.message || data?.error || `Google Calendar API error ${response.status}`;
    throw new Error(String(message));
  }

  return data;
}

async function googleServiceRequest(
  userId,
  {
    baseUrl,
    method = "GET",
    path = "",
    query = {},
    body = null,
    headers = {},
    parseJson = true,
  } = {}
) {
  const requestUrl = new URL(`${baseUrl}${path}`);
  for (const [key, value] of Object.entries(query || {})) {
    if (value == null || value === "") continue;
    requestUrl.searchParams.set(key, String(value));
  }

  const runRequest = async (accessToken) => {
    const response = await fetch(requestUrl.toString(), {
      method,
      headers: {
        Authorization: `Bearer ${accessToken}`,
        ...(body != null ? { "Content-Type": "application/json" } : {}),
        ...headers,
      },
      body: body == null ? undefined : JSON.stringify(body),
    });
    const data = parseJson ? await response.json().catch(() => ({})) : null;
    return { response, data };
  };

  let { accessToken } = await getValidGoogleAccessToken(userId);
  let { response, data } = await runRequest(accessToken);

  if (response.status === 401) {
    const row = getGoogleTokenRow(userId);
    if (row?.refresh_token) {
      const refreshed = await refreshGoogleAccessToken(userId, row.refresh_token);
      accessToken = refreshed.access_token;
      ({ response, data } = await runRequest(accessToken));
    }
  }

  if (!response.ok) {
    const message =
      data?.error?.message || data?.error || `Google API error ${response.status}`;
    throw new Error(String(message));
  }

  return parseJson ? data : { success: true };
}

async function listGoogleCalendarEvents(userId, { timeMin, timeMax, maxResults = 10 } = {}) {
  const minValue =
    cleanText(timeMin, 80) || new Date(Date.now() - 5 * 60 * 1000).toISOString();
  const maxValue =
    cleanText(timeMax, 80) || new Date(Date.now() + 7 * 24 * 60 * 60 * 1000).toISOString();

  const data = await googleCalendarRequest(userId, "GET", "/calendars/primary/events", {
    singleEvents: "true",
    orderBy: "startTime",
    timeMin: minValue,
    timeMax: maxValue,
    maxResults: Math.max(1, Math.min(50, Number(maxResults) || 10)),
  });

  const items = Array.isArray(data?.items) ? data.items : [];
  return items.map((item) => ({
    id: String(item.id || ""),
    summary: String(item.summary || "Untitled event"),
    start:
      item?.start?.dateTime ||
      item?.start?.date ||
      "",
    end:
      item?.end?.dateTime ||
      item?.end?.date ||
      "",
    htmlLink: String(item.htmlLink || ""),
  }));
}

async function createGoogleCalendarEvent(userId, { title, startIso, endIso }) {
  const summary = cleanText(title, 200) || "New Event";
  const startDate = new Date(startIso);
  const endDate = new Date(endIso);
  if (!Number.isFinite(startDate.getTime()) || !Number.isFinite(endDate.getTime())) {
    throw new Error("Invalid event date/time");
  }
  if (endDate.getTime() <= startDate.getTime()) {
    throw new Error("Event end time must be after start time");
  }

  const data = await googleCalendarRequest(
    userId,
    "POST",
    "/calendars/primary/events",
    {},
    {
      summary,
      start: {
        dateTime: startDate.toISOString(),
      },
      end: {
        dateTime: endDate.toISOString(),
      },
    }
  );

  return {
    id: String(data?.id || ""),
    summary: String(data?.summary || summary),
    start: data?.start?.dateTime || "",
    end: data?.end?.dateTime || "",
    htmlLink: String(data?.htmlLink || ""),
  };
}

async function updateGoogleCalendarEvent(userId, eventId, { title, startIso, endIso }) {
  const eventKey = cleanText(eventId, 400);
  if (!eventKey) {
    throw new Error("Invalid event id");
  }

  const summary = cleanText(title, 200) || "Updated Event";
  const startDate = new Date(startIso);
  const endDate = new Date(endIso);
  if (!Number.isFinite(startDate.getTime()) || !Number.isFinite(endDate.getTime())) {
    throw new Error("Invalid event date/time");
  }
  if (endDate.getTime() <= startDate.getTime()) {
    throw new Error("Event end time must be after start time");
  }

  const data = await googleCalendarRequest(
    userId,
    "PATCH",
    `/calendars/primary/events/${encodeURIComponent(eventKey)}`,
    {},
    {
      summary,
      start: { dateTime: startDate.toISOString() },
      end: { dateTime: endDate.toISOString() },
    }
  );

  return {
    id: String(data?.id || eventKey),
    summary: String(data?.summary || summary),
    start: data?.start?.dateTime || "",
    end: data?.end?.dateTime || "",
    htmlLink: String(data?.htmlLink || ""),
  };
}

async function deleteGoogleCalendarEvent(userId, eventId) {
  const eventKey = cleanText(eventId, 400);
  if (!eventKey) {
    throw new Error("Invalid event id");
  }
  await googleCalendarRequest(
    userId,
    "DELETE",
    `/calendars/primary/events/${encodeURIComponent(eventKey)}`
  );
  return { success: true };
}

function toBase64Url(input) {
  return Buffer.from(String(input || ""), "utf8")
    .toString("base64")
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/g, "");
}

function getHeaderValue(headers = [], key = "") {
  const target = String(key || "").toLowerCase().trim();
  for (const item of headers) {
    if (!item || typeof item !== "object") continue;
    if (String(item.name || "").toLowerCase() === target) {
      return String(item.value || "");
    }
  }
  return "";
}

async function getGoogleUserProfile(userId) {
  const data = await googleServiceRequest(userId, {
    baseUrl: "https://www.googleapis.com",
    method: "GET",
    path: "/oauth2/v2/userinfo",
  });

  return {
    id: String(data?.id || ""),
    email: String(data?.email || ""),
    verifiedEmail: data?.verified_email === true,
    name: String(data?.name || ""),
    picture: String(data?.picture || ""),
  };
}

async function listGmailMessages(userId, { maxResults = 10 } = {}) {
  const listData = await googleServiceRequest(userId, {
    baseUrl: GOOGLE_GMAIL_API_BASE,
    method: "GET",
    path: "/users/me/messages",
    query: {
      maxResults: Math.max(1, Math.min(20, Number(maxResults) || 10)),
    },
  });

  const messages = Array.isArray(listData?.messages) ? listData.messages : [];
  const results = [];
  for (const msg of messages.slice(0, 10)) {
    const id = cleanText(msg?.id, 300);
    if (!id) continue;
    const detail = await googleServiceRequest(userId, {
      baseUrl: GOOGLE_GMAIL_API_BASE,
      method: "GET",
      path: `/users/me/messages/${encodeURIComponent(id)}`,
      query: {
        format: "metadata",
        metadataHeaders: ["From", "Subject", "Date"].join(","),
      },
    });

    const payloadHeaders = detail?.payload?.headers || [];
    results.push({
      id,
      threadId: String(detail?.threadId || ""),
      snippet: String(detail?.snippet || ""),
      from: getHeaderValue(payloadHeaders, "from"),
      subject: getHeaderValue(payloadHeaders, "subject"),
      date: getHeaderValue(payloadHeaders, "date"),
      labelIds: Array.isArray(detail?.labelIds) ? detail.labelIds : [],
    });
  }

  return results;
}

async function sendGmailMessage(userId, { to, subject, bodyText }) {
  const toValue = cleanText(to, 320);
  const subjectValue = cleanText(subject, 300);
  const bodyValue = cleanText(bodyText, 20000);
  if (!toValue || !subjectValue || !bodyValue) {
    throw new Error("to, subject, body are required");
  }

  const rawMessage = [
    `To: ${toValue}`,
    `Subject: ${subjectValue}`,
    "Content-Type: text/plain; charset=utf-8",
    "",
    bodyValue,
  ].join("\r\n");

  const payload = {
    raw: toBase64Url(rawMessage),
  };

  const data = await googleServiceRequest(userId, {
    baseUrl: GOOGLE_GMAIL_API_BASE,
    method: "POST",
    path: "/users/me/messages/send",
    body: payload,
  });

  return {
    id: String(data?.id || ""),
    threadId: String(data?.threadId || ""),
    labelIds: Array.isArray(data?.labelIds) ? data.labelIds : [],
  };
}

async function listGoogleContacts(userId, { maxResults = 20 } = {}) {
  const data = await googleServiceRequest(userId, {
    baseUrl: GOOGLE_PEOPLE_API_BASE,
    method: "GET",
    path: "/people/me/connections",
    query: {
      personFields: "names,emailAddresses,phoneNumbers",
      pageSize: Math.max(1, Math.min(100, Number(maxResults) || 20)),
      sortOrder: "FIRST_NAME_ASCENDING",
    },
  });

  const connections = Array.isArray(data?.connections) ? data.connections : [];
  return connections.map((person) => ({
    resourceName: String(person?.resourceName || ""),
    displayName: String(person?.names?.[0]?.displayName || ""),
    email: String(person?.emailAddresses?.[0]?.value || ""),
    phone: String(person?.phoneNumbers?.[0]?.value || ""),
  }));
}

function normalizeMemoryKey(value = "") {
  return String(value || "")
    .toLowerCase()
    .trim()
    .replace(/\s+/g, " ")
    .slice(0, 180);
}

function mapMemoryRow(row) {
  return {
    id: String(row.id),
    text: row.memory_text,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}

function getUserMemories(userId, limit = 8) {
  return db
    .prepare(
      `SELECT id, memory_text, created_at, updated_at
       FROM user_memories
       WHERE user_id = ?
       ORDER BY updated_at DESC
       LIMIT ?`
    )
    .all(userId, limit)
    .map(mapMemoryRow);
}

function normalizeKnowledgeTags(value) {
  if (Array.isArray(value)) {
    return value
      .map((item) => cleanText(item, 40).toLowerCase())
      .filter((item) => item.length > 0)
      .slice(0, 10);
  }
  if (typeof value === "string") {
    return value
      .split(",")
      .map((item) => cleanText(item, 40).toLowerCase())
      .filter((item) => item.length > 0)
      .slice(0, 10);
  }
  return [];
}

function mapKnowledgeDocRow(row) {
  return {
    id: String(row.id),
    title: row.title,
    content: row.content,
    tags: parseStringListJson(row.tags_json || "[]", 12, 40),
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}

function normalizeJobSteps(value) {
  if (!Array.isArray(value)) return [];
  return value
    .map((item, index) => {
      if (!item || typeof item !== "object") return null;
      const title = cleanText(item.title, 240);
      if (!title) return null;
      return {
        id: cleanText(item.id, 40) || `S${index + 1}`,
        title,
        done: item.done === true,
      };
    })
    .filter(Boolean)
    .slice(0, 30);
}

function mapAssistantJobRow(row) {
  let parsedSteps = [];
  try {
    parsedSteps = normalizeJobSteps(JSON.parse(row.steps_json || "[]"));
  } catch {
    parsedSteps = [];
  }
  return {
    id: String(row.id),
    title: row.title,
    goal: row.goal,
    status: row.status,
    currentStepIndex: Number(row.current_step_index) || 0,
    steps: parsedSteps,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}

function getAssistantJobById(userId, jobId) {
  const row = db
    .prepare(
      `SELECT id, title, goal, status, steps_json, current_step_index, created_at, updated_at
       FROM assistant_jobs
       WHERE id = ? AND user_id = ?`
    )
    .get(jobId, userId);
  return row ? mapAssistantJobRow(row) : null;
}

function listAssistantJobs(userId, limit = 20) {
  const safeLimit = Math.max(1, Math.min(100, Number(limit) || 20));
  return db
    .prepare(
      `SELECT id, title, goal, status, steps_json, current_step_index, created_at, updated_at
       FROM assistant_jobs
       WHERE user_id = ?
       ORDER BY updated_at DESC
       LIMIT ?`
    )
    .all(userId, safeLimit)
    .map(mapAssistantJobRow);
}

function createAssistantJob(userId, { title = "", goal = "", steps = [] } = {}) {
  const cleanGoal = cleanText(goal, 500);
  const cleanTitle = cleanText(title, 180) || cleanGoal || "Assistant Workflow";
  const normalizedSteps = normalizeJobSteps(steps);
  if (!cleanGoal || normalizedSteps.length === 0) return null;
  const now = nowIso();
  const inserted = db
    .prepare(
      `INSERT INTO assistant_jobs
       (user_id, title, goal, status, steps_json, current_step_index, created_at, updated_at)
       VALUES (?, ?, ?, 'active', ?, 0, ?, ?)`
    )
    .run(userId, cleanTitle, cleanGoal, JSON.stringify(normalizedSteps), now, now);
  return getAssistantJobById(userId, inserted.lastInsertRowid);
}

function advanceAssistantJob(userId, jobId) {
  const existing = getAssistantJobById(userId, jobId);
  if (!existing) return null;
  if (existing.status === "cancelled" || existing.status === "completed") {
    return existing;
  }
  const nextIndex = Math.min(
    existing.steps.length,
    Math.max(0, Number(existing.currentStepIndex) + 1)
  );
  const status = nextIndex >= existing.steps.length ? "completed" : "active";
  const now = nowIso();
  db.prepare(
    `UPDATE assistant_jobs
     SET current_step_index = ?, status = ?, updated_at = ?
     WHERE id = ? AND user_id = ?`
  ).run(nextIndex, status, now, jobId, userId);
  return getAssistantJobById(userId, jobId);
}

function cancelAssistantJob(userId, jobId) {
  const existing = getAssistantJobById(userId, jobId);
  if (!existing) return null;
  const now = nowIso();
  db.prepare(
    "UPDATE assistant_jobs SET status = 'cancelled', updated_at = ? WHERE id = ? AND user_id = ?"
  ).run(now, jobId, userId);
  return getAssistantJobById(userId, jobId);
}

function listKnowledgeDocuments(userId, limit = 30) {
  const safeLimit = Math.max(1, Math.min(100, Number(limit) || 30));
  return db
    .prepare(
      `SELECT id, title, content, tags_json, created_at, updated_at
       FROM knowledge_documents
       WHERE user_id = ?
       ORDER BY updated_at DESC
       LIMIT ?`
    )
    .all(userId, safeLimit)
    .map(mapKnowledgeDocRow);
}

function createKnowledgeDocument(userId, { title = "", content = "", tags = [] } = {}) {
  const cleanTitle = cleanText(title, 180) || "Knowledge Note";
  const cleanContent = cleanText(content, 12000);
  if (!cleanContent) return null;
  const cleanTags = normalizeKnowledgeTags(tags);
  const now = nowIso();
  const inserted = db
    .prepare(
      `INSERT INTO knowledge_documents
       (user_id, title, content, tags_json, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, ?)`
    )
    .run(userId, cleanTitle, cleanContent, JSON.stringify(cleanTags), now, now);

  return db
    .prepare(
      `SELECT id, title, content, tags_json, created_at, updated_at
       FROM knowledge_documents
       WHERE id = ?`
    )
    .get(inserted.lastInsertRowid);
}

function decodeKnowledgeFileText({
  filename = "",
  mimeType = "",
  base64Data = "",
}) {
  const cleanName = cleanText(filename, 180);
  const cleanMime = cleanText(mimeType, 120).toLowerCase();
  const rawBase64 = String(base64Data || "").trim();
  if (!rawBase64) return { ok: false, error: "base64Data is required" };

  let buffer = null;
  try {
    buffer = Buffer.from(rawBase64, "base64");
  } catch {
    return { ok: false, error: "Invalid base64 data" };
  }
  if (!buffer || buffer.length === 0) {
    return { ok: false, error: "Decoded file is empty" };
  }

  const extension = cleanName.includes(".")
    ? cleanName.split(".").pop().toLowerCase()
    : "";
  const isTextLike =
    cleanMime.startsWith("text/") ||
    cleanMime.includes("json") ||
    cleanMime.includes("xml") ||
    cleanMime.includes("csv") ||
    ["txt", "md", "markdown", "json", "csv", "xml", "yaml", "yml", "log"].includes(
      extension
    );

  if (!isTextLike) {
    return {
      ok: false,
      error:
        "Unsupported file type for direct ingestion. Use text/json/csv/md/log files.",
    };
  }

  const text = cleanText(buffer.toString("utf8"), 12000);
  if (!text) {
    return { ok: false, error: "File content is empty after parsing" };
  }

  return {
    ok: true,
    title: cleanName || "Knowledge File",
    content: text,
  };
}

function tokenizeForSearch(value = "", maxTokens = 24) {
  const text = String(value || "").toLowerCase();
  const tokens = text
    .replace(/[^a-z0-9\u0900-\u097F\s]/g, " ")
    .split(/\s+/)
    .map((item) => item.trim())
    .filter((item) => item.length >= 2)
    .slice(0, maxTokens);
  return Array.from(new Set(tokens));
}

function scoreMemoryForQuery(memoryText = "", queryTokens = []) {
  if (!Array.isArray(queryTokens) || queryTokens.length === 0) return 0;
  const memoryTokens = new Set(tokenizeForSearch(memoryText, 60));
  if (memoryTokens.size === 0) return 0;

  let score = 0;
  for (const token of queryTokens) {
    if (!token) continue;
    if (memoryTokens.has(token)) {
      score += 2;
      continue;
    }
    for (const mt of memoryTokens) {
      if (mt.startsWith(token) || token.startsWith(mt)) {
        score += 1;
        break;
      }
    }
  }
  return score;
}

function getRelevantUserMemories(userId, queryText = "", limit = 6) {
  const safeLimit = Math.max(1, Math.min(20, Number(limit) || 6));
  const recent = getUserMemories(userId, 80);
  if (recent.length === 0) return [];

  const queryTokens = tokenizeForSearch(queryText, 24);
  if (queryTokens.length === 0) {
    return recent.slice(0, safeLimit);
  }

  const scored = recent
    .map((item) => ({
      ...item,
      _score: scoreMemoryForQuery(item.text, queryTokens),
    }))
    .filter((item) => item._score > 0)
    .sort((a, b) => {
      if (a._score !== b._score) return b._score - a._score;
      return String(b.updatedAt || "").localeCompare(String(a.updatedAt || ""));
    })
    .slice(0, safeLimit)
    .map(({ _score, ...item }) => item);

  if (scored.length > 0) return scored;
  return recent.slice(0, safeLimit);
}

function searchKnowledgeDocuments(userId, queryText = "", limit = 5) {
  const docs = listKnowledgeDocuments(userId, 120);
  if (docs.length === 0) return [];
  const safeLimit = Math.max(1, Math.min(20, Number(limit) || 5));
  const queryTokens = tokenizeForSearch(queryText, 28);
  if (queryTokens.length === 0) {
    return docs.slice(0, safeLimit);
  }

  const scored = docs
    .map((doc) => {
      const haystack = `${doc.title} ${doc.content} ${(doc.tags || []).join(" ")}`;
      return {
        ...doc,
        _score: scoreMemoryForQuery(haystack, queryTokens),
      };
    })
    .filter((item) => item._score > 0)
    .sort((a, b) => {
      if (a._score !== b._score) return b._score - a._score;
      return String(b.updatedAt || "").localeCompare(String(a.updatedAt || ""));
    })
    .slice(0, safeLimit)
    .map(({ _score, ...item }) => item);

  if (scored.length > 0) return scored;
  return docs.slice(0, safeLimit);
}

function upsertUserMemory(userId, memoryText) {
  const text = cleanText(memoryText, 1200);
  if (!text) return null;

  const memoryKey = normalizeMemoryKey(text);
  if (!memoryKey) return null;

  const now = nowIso();
  const existing = db
    .prepare("SELECT id FROM user_memories WHERE user_id = ? AND memory_key = ?")
    .get(userId, memoryKey);

  if (existing) {
    db.prepare(
      "UPDATE user_memories SET memory_text = ?, updated_at = ? WHERE id = ?"
    ).run(text, now, existing.id);
    return db
      .prepare(
        "SELECT id, memory_text, created_at, updated_at FROM user_memories WHERE id = ?"
      )
      .get(existing.id);
  }

  const inserted = db
    .prepare(
      "INSERT INTO user_memories (user_id, memory_key, memory_text, created_at, updated_at) VALUES (?, ?, ?, ?, ?)"
    )
    .run(userId, memoryKey, text, now, now);

  return db
    .prepare(
      "SELECT id, memory_text, created_at, updated_at FROM user_memories WHERE id = ?"
    )
    .get(inserted.lastInsertRowid);
}

function buildMemoryContext(userId, queryText = "") {
  if (!userId) return "";
  const memories = getRelevantUserMemories(userId, queryText, 8);
  if (memories.length === 0) return "";

  const lines = memories.map((item, index) => `${index + 1}. ${item.text}`);
  return [
    "",
    "Known user memories (use only when relevant and never invent details):",
    ...lines,
  ].join("\n");
}

function buildKnowledgeContext(userId, queryText = "") {
  if (!userId) return "";
  const docs = searchKnowledgeDocuments(userId, queryText, 4);
  if (docs.length === 0) return "";

  const lines = docs.map((item, index) => {
    const snippet = cleanText(item.content, 260);
    return `${index + 1}. ${item.title}: ${snippet}`;
  });
  return [
    "",
    "Relevant user knowledge docs (cite only if relevant and avoid fabrication):",
    ...lines,
  ].join("\n");
}

function mapSessionRow(row) {
  return {
    id: String(row.id),
    title: row.title,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
    isPinned: row.is_pinned === 1,
  };
}

function mapMessageRow(row) {
  return {
    id: String(row.id),
    role: row.role,
    text: row.text,
    time: row.created_at,
    type: row.type,
    code: row.code,
    imagePrompt: row.image_prompt,
    videoPrompt: row.video_prompt,
    action: row.action,
    url: row.url,
    info: row.info,
    suggestions: parseSuggestionsJson(row.suggestions_json),
    starred: row.starred === 1,
  };
}

function getRequestId() {
  return crypto.randomUUID();
}

function getClientIp(req) {
  const forwarded = req.headers["x-forwarded-for"];
  if (typeof forwarded === "string" && forwarded.trim()) {
    return forwarded.split(",")[0].trim();
  }
  return req.ip || req.socket?.remoteAddress || "unknown";
}

function updateMetricsForPath(path) {
  metrics.totalRequests += 1;
  metrics.byPath[path] = (metrics.byPath[path] || 0) + 1;
}

function cleanupRateBuckets(now) {
  for (const [ip, timestamps] of rateBuckets.entries()) {
    const filtered = timestamps.filter((ts) => now - ts <= RATE_LIMIT_WINDOW_MS);
    if (filtered.length === 0) {
      rateBuckets.delete(ip);
    } else {
      rateBuckets.set(ip, filtered);
    }
  }
}

app.use((req, res, next) => {
  req.requestId = getRequestId();
  req.startedAt = Date.now();
  res.setHeader("x-request-id", req.requestId);

  const originalJson = res.json.bind(res);
  res.json = (payload) => {
    if (payload && typeof payload === "object" && !Array.isArray(payload)) {
      return originalJson({
        ...payload,
        requestId: req.requestId,
      });
    }
    return originalJson(payload);
  };

  res.on("finish", () => {
    const durationMs = Date.now() - req.startedAt;
    updateMetricsForPath(req.path);
    if (res.statusCode >= 500) {
      metrics.totalErrors += 1;
    }
    console.log(
      `[${new Date().toISOString()}] ${req.method} ${req.path} ${res.statusCode} ${durationMs}ms reqId=${req.requestId}`
    );
  });

  next();
});

app.use((req, res, next) => {
  if (!isMongoMirrorModeEnabled()) {
    return next();
  }

  const shouldWatchWrite =
    req.method === "POST" ||
    req.method === "PUT" ||
    req.method === "PATCH" ||
    req.method === "DELETE";

  if (!shouldWatchWrite) {
    return next();
  }

  res.on("finish", () => {
    if (res.statusCode >= 400) return;
    if (req.path === "/metrics" || req.path === "/health") return;
    scheduleMongoMirrorSync();
  });

  next();
});

app.use((req, res, next) => {
  if (!RATE_LIMIT_PATHS.has(req.path)) {
    return next();
  }

  const now = Date.now();
  if (rateBuckets.size > 5000) {
    cleanupRateBuckets(now);
  }

  const ip = getClientIp(req);
  const existing = rateBuckets.get(ip) || [];
  const recent = existing.filter((ts) => now - ts <= RATE_LIMIT_WINDOW_MS);

  if (recent.length >= RATE_LIMIT_MAX) {
    metrics.rateLimitedRequests += 1;
    return res.status(429).json({
      error: "Too many requests",
      details: `Rate limit exceeded. Max ${RATE_LIMIT_MAX} requests per ${Math.round(
        RATE_LIMIT_WINDOW_MS / 1000
      )} seconds.`,
      retryAfterSeconds: Math.ceil(RATE_LIMIT_WINDOW_MS / 1000),
    });
  }

  recent.push(now);
  rateBuckets.set(ip, recent);
  next();
});

initializeDatabase();
initializeMongo().catch((error) => {
  console.error("Mongo bootstrap failed:", error?.message);
});
setTimeout(() => {
  bootstrapMongoMirror().catch((error) => {
    console.error("Mongo mirror bootstrap failed:", error?.message);
  });
}, 300);
initializeFirebaseAdmin();
startGooglePushScheduler();

function detectLanguage(message = "") {
  const text = message.toLowerCase().trim();

  const hindiRegex = /[\u0900-\u097F]/;
  if (hindiRegex.test(message)) return "hi";

  const hinglishWords = [
    "kya",
    "kaise",
    "mujhe",
    "mera",
    "meri",
    "hai",
    "kar",
    "karo",
    "batao",
    "dikhao",
    "note",
    "task",
    "banao",
    "show",
    "add",
    "open",
    "search",
  ];

  for (const word of hinglishWords) {
    if (text.includes(word)) return "hinglish";
  }

  return "en";
}

function detectIntent(message = "", isOnlineMode = true) {
  const text = message.toLowerCase().trim();

  if (!isOnlineMode) return "offline_command";

  const commandKeywords = [
    "open youtube",
    "open google",
    "open github",
    "open linkedin",
    "open spotify",
    "open whatsapp",
    "open gmail",
    "search ",
    "weather in ",
    "weather at ",
    "forecast in ",
    "forecast for ",
    "temperature in ",
    "what is the time",
    "current time",
    "what is today's date",
    "today date",
    "daily briefing",
    "my briefing",
    "status report",
    "add knowledge ",
    "save knowledge ",
    "search knowledge ",
    "find in knowledge ",
    "create workflow for ",
    "start workflow for ",
    "workflow for ",
    "list workflows",
    "create plan for ",
    "make plan for ",
    "roadmap for ",
    "plan for ",
    "goal plan ",
    "calculate ",
    "open website",
    "add note ",
    "create note ",
    "note add ",
    "create task ",
    "add task ",
    "task create ",
    "set timer ",
    "remind me ",
    "set reminder ",
    "create routine ",
    "save routine ",
    "run routine ",
    "start routine ",
    "list routines",
    "create event ",
    "add event ",
    "schedule event ",
    "list events",
    "my agenda",
    "delete event ",
    "connect google calendar",
    "disconnect google calendar",
    "google calendar status",
    "list google events",
    "show google events",
    "create google event ",
    "list google contacts",
    "show google contacts",
    "show my contacts",
    "find contact ",
    "recent emails",
    "show inbox",
    "check inbox",
    "send email to ",
    "email to ",
    "undo last action",
    "undo",
    "action history",
    "show action history",
  ];

  const codeKeywords = [
    "code",
    "program",
    "java",
    "python",
    "javascript",
    "js",
    "c++",
    "cpp",
    "html",
    "css",
    "sql",
    "flutter",
    "react",
    "node",
    "express",
    "bug fix",
    "fix this code",
    "write a function",
    "generate code",
  ];

  const imageKeywords = [
    "generate image",
    "create image",
    "make image",
    "draw",
    "poster",
    "logo",
    "banner",
    "thumbnail",
    "illustration",
    "anime image",
    "prompt for image",
    "image prompt",
  ];

  const videoKeywords = [
    "generate video",
    "create video",
    "make video",
    "video prompt",
    "text to video",
    "cinematic video",
    "animate this",
    "short video",
    "reel idea",
  ];

  for (const word of commandKeywords) {
    if (text.includes(word)) return "command";
  }

  for (const word of codeKeywords) {
    if (text.includes(word)) return "code";
  }

  for (const word of imageKeywords) {
    if (text.includes(word)) return "image";
  }

  for (const word of videoKeywords) {
    if (text.includes(word)) return "video";
  }

  return "chat";
}

function parseMemoryCommand(message = "") {
  const raw = String(message || "").trim();
  const text = raw.toLowerCase();

  const listPatterns = [
    "what do you remember",
    "what do you know about me",
    "show memories",
    "list memories",
    "my memories",
    "yaad hai",
  ];

  if (listPatterns.some((p) => text.includes(p))) {
    return { kind: "list" };
  }

  const clearPatterns = [
    "forget all memories",
    "clear all memories",
    "clear memory",
    "delete all memories",
    "forget everything about me",
    "sab bhool jao",
  ];

  if (clearPatterns.some((p) => text.includes(p))) {
    return { kind: "clear" };
  }

  const rememberMatch =
    raw.match(/^remember(?:\s+that)?\s+(.+)$/i) ||
    raw.match(/^save to memory:?\s*(.+)$/i) ||
    raw.match(/^yaad rakho\s+(.+)$/i) ||
    raw.match(/^yaad rakhna\s+(.+)$/i);

  if (rememberMatch && rememberMatch[1]) {
    return {
      kind: "add",
      text: rememberMatch[1].trim(),
    };
  }

  const forgetMatch = raw.match(/^forget(?:\s+memory)?\s+(.+)$/i);
  if (forgetMatch && forgetMatch[1]) {
    const target = forgetMatch[1].trim();
    if (
      target &&
      !["all", "everything", "all memories"].includes(target.toLowerCase())
    ) {
      return { kind: "remove", text: target };
    }
  }

  return { kind: "none" };
}

function createOpenRouterClient() {
  if (!process.env.OPENROUTER_API_KEY) return null;

  return new OpenAI({
    apiKey: process.env.OPENROUTER_API_KEY,
    baseURL: "https://openrouter.ai/api/v1",
    defaultHeaders: {
      "HTTP-Referer": "http://localhost:5000",
      "X-Title": "FLOWGNIMAG",
    },
  });
}

function createOpenAIClient() {
  if (!process.env.OPENAI_API_KEY) return null;

  return new OpenAI({
    apiKey: process.env.OPENAI_API_KEY,
  });
}

function getSimpleReplyInstruction(language) {
  if (language === "hi") {
    return "Jawaab bahut aasaan, chhota aur seedha rakho.";
  }
  if (language === "hinglish") {
    return "Reply in very simple Hinglish. Keep it short and direct.";
  }
  return "Reply in very simple language. Keep it short and direct.";
}

function normalizeAssistantMode(value = "") {
  const raw = String(value || "")
    .trim()
    .toLowerCase();

  if (raw === "jarvis" || raw === "creative" || raw === "precise") {
    return raw;
  }
  return "jarvis";
}

function getAssistantModeInstruction(mode, language) {
  if (mode === "creative") {
    if (language === "hi" || language === "hinglish") {
      return "Tone imaginative rakho, ideas do, but practical bhi raho.";
    }
    return "Be imaginative and idea-rich, while staying practical.";
  }

  if (mode === "precise") {
    if (language === "hi" || language === "hinglish") {
      return "Tone concise, accurate, aur structured rakho. Extra fluff avoid karo.";
    }
    return "Be concise, accurate, and structured. Avoid unnecessary fluff.";
  }

  if (language === "hi" || language === "hinglish") {
    return "Jarvis-style proactive assistant raho: short, confident, actionable.";
  }
  return "Use a Jarvis-style proactive assistant tone: short, confident, actionable.";
}

function getSmartReplyInstruction(language) {
  if (language === "hi") {
    return "Jawaab aasaan, saaf, upyogi aur zarurat par step-by-step do.";
  }
  if (language === "hinglish") {
    return "Reply in simple Hinglish. Keep it clear, helpful, and step-by-step when needed.";
  }
  return "Reply clearly, helpfully, and step-by-step when needed.";
}

function getChatSystemPrompt(language, smartReply, assistantMode = "jarvis") {
  const modeInstruction = smartReply
    ? getSmartReplyInstruction(language)
    : getSimpleReplyInstruction(language);
  const assistantInstruction = getAssistantModeInstruction(
    normalizeAssistantMode(assistantMode),
    language
  );

  if (language === "hi") {
    return `
You are FLOWGNIMAG, a helpful AI assistant.
Reply in simple Hindi/Hinglish style.
${modeInstruction}
${assistantInstruction}
Do not make the answer unnecessarily long.
`;
  }

  if (language === "hinglish") {
    return `
You are FLOWGNIMAG, a helpful AI assistant.
Always reply in simple Hinglish.
${modeInstruction}
${assistantInstruction}
Do not make the answer unnecessarily long.
`;
  }

  return `
You are FLOWGNIMAG, a helpful AI assistant.
Always reply in the same language as the user when possible.
${modeInstruction}
${assistantInstruction}
Do not make the answer unnecessarily long.
`;
}

function getCodeSystemPrompt(language, smartReply, assistantMode = "jarvis") {
  const explanationStyle = smartReply
    ? language === "hi"
      ? "Chhota lekin useful explanation do."
      : language === "hinglish"
        ? "Give a short but useful Hinglish explanation."
        : "Give a short but useful explanation."
    : language === "hi"
      ? "Bahut chhota explanation do."
      : language === "hinglish"
        ? "Give a very short Hinglish explanation."
        : "Give a very short explanation.";
  const assistantInstruction = getAssistantModeInstruction(
    normalizeAssistantMode(assistantMode),
    language
  );

  if (language === "hi") {
    return `
You are FLOWGNIMAG. User wants code.
Try to reply in JSON format:
{
  "reply": "easy explanation",
  "code": "full usable code",
  "language": "java/python/javascript/etc"
}
${explanationStyle}
${assistantInstruction}
Code must be clean, correct, and usable.
If strict JSON is not possible, still return explanation + code.
`;
  }

  if (language === "hinglish") {
    return `
You are FLOWGNIMAG. User wants code.
Try to reply in JSON format:
{
  "reply": "easy Hinglish explanation",
  "code": "full usable code",
  "language": "java/python/javascript/etc"
}
${explanationStyle}
${assistantInstruction}
Code must be clean, correct, and usable.
If strict JSON is not possible, still return explanation + code.
`;
  }

  return `
You are FLOWGNIMAG. User wants code.
Try to reply in JSON format:
{
  "reply": "easy explanation",
  "code": "full usable code",
  "language": "java/python/javascript/etc"
}
${explanationStyle}
${assistantInstruction}
Code must be clean, correct, and usable.
If strict JSON is not possible, still return explanation + code.
`;
}

function safeCalculate(expression) {
  const cleaned = expression.replace(/[^0-9+\-*/().%\s]/g, "").trim();
  if (!cleaned) return null;

  try {
    const result = Function(`"use strict"; return (${cleaned})`)();
    if (typeof result !== "number" || !isFinite(result)) return null;
    return result;
  } catch {
    return null;
  }
}

function actionRequiresApproval(action = "") {
  const normalized = String(action || "").trim().toLowerCase();
  if (!normalized) return false;
  const riskyActions = new Set([
    "open_url",
    "delete_event",
    "google_gmail_send_confirm",
    "execute_goal_plan",
  ]);
  return riskyActions.has(normalized);
}

function buildCommandResponse(reply, action = null, data = {}) {
  return {
    type: "command",
    reply,
    action,
    requiresApproval: actionRequiresApproval(action),
    ...data,
  };
}

function buildFollowupSuggestions({
  intent = "chat",
  result = {},
  language = "en",
}) {
  const isHindiStyle = language === "hi" || language === "hinglish";
  const suggestions = [];

  if (intent === "code") {
    suggestions.push(
      "Explain this code step by step",
      "Add error handling to this code",
      "Write test cases for this code"
    );
  } else if (intent === "image") {
    suggestions.push(
      "Make the prompt more cinematic",
      "Create a logo version",
      "Generate 3 style variations"
    );
  } else if (intent === "video") {
    suggestions.push(
      "Make this a 15-second reel",
      "Add camera movement details",
      "Create a storyboard from this prompt"
    );
  } else if (intent === "memory_command") {
    suggestions.push(
      "What do you remember about me?",
      "Remember that my timezone is IST",
      "Forget all memories"
    );
  } else if (intent === "command") {
    const action = String(result?.action || "");
    if (action === "create_routine") {
      suggestions.push("Run routine morning", "List routines");
    } else if (action === "create_event") {
      suggestions.push("List events", "Delete event Team sync");
    } else if (action === "create_reminder") {
      suggestions.push("Set timer for 10 minutes", "Action history");
    } else if (action === "execute_goal_plan") {
      suggestions.push("Action history", "Daily briefing", "Run routine morning");
    } else if (action === "create_workflow_job") {
      suggestions.push("List workflows", "Daily briefing", "Action history");
    } else if (action === "search_knowledge") {
      suggestions.push("Add knowledge project architecture", "Daily briefing");
    } else if (action === "run_push_doctor") {
      suggestions.push("Run full push self test", "Push status");
    } else if (action === "run_push_self_test") {
      suggestions.push("Push doctor", "Push status");
    } else if (action === "show_info") {
      suggestions.push("Daily briefing", "Weather in Mumbai");
    } else {
      suggestions.push("Daily briefing", "Action history", "Undo last action");
    }
  } else {
    suggestions.push(
      isHindiStyle ? "Daily briefing" : "Daily briefing",
      "Weather in Mumbai",
      "Action history"
    );
  }

  return Array.from(
    new Set(
      suggestions
        .map((item) => cleanText(item, 120))
        .filter((item) => item.length > 0)
    )
  ).slice(0, 4);
}

function parseRoutineStep(segment = "") {
  const raw = cleanText(segment, 600);
  if (!raw) return null;
  const text = raw.trim();
  const lower = text.toLowerCase();

  const openMap = {
    "open youtube": "https://www.youtube.com",
    "open google": "https://www.google.com",
    "open github": "https://github.com",
    "open linkedin": "https://www.linkedin.com",
    "open spotify": "https://open.spotify.com",
    "open whatsapp": "https://web.whatsapp.com",
    "open gmail": "https://mail.google.com",
  };
  for (const [phrase, url] of Object.entries(openMap)) {
    if (lower === phrase) {
      return { kind: "open_url", title: text, url };
    }
  }

  const urlMatch = text.match(/^open\s+(https?:\/\/\S+)$/i);
  if (urlMatch) {
    return { kind: "open_url", title: text, url: cleanText(urlMatch[1], 2000) };
  }

  const noteMatch = text.match(/^(add note|create note|note add)\s+(.+)$/i);
  if (noteMatch) {
    return { kind: "create_note", title: text, text: cleanText(noteMatch[2], 1200) };
  }

  const taskMatch = text.match(/^(create task|add task|task create)\s+(.+)$/i);
  if (taskMatch) {
    return { kind: "create_task", title: text, text: cleanText(taskMatch[2], 600) };
  }

  const timerMatch = text.match(
    /^set timer(?:\s+for)?\s+(\d+)\s*(seconds?|secs?|minutes?|mins?)$/i
  );
  if (timerMatch) {
    const amount = Number(timerMatch[1] || 0);
    const unit = String(timerMatch[2] || "").toLowerCase();
    const multiplier = unit.startsWith("min") ? 60 : 1;
    const totalSeconds = amount * multiplier;
    if (Number.isFinite(totalSeconds) && totalSeconds > 0 && totalSeconds <= 86_400) {
      return { kind: "set_timer", title: text, seconds: totalSeconds };
    }
  }

  const reminderMatch = text.match(
    /^(remind me to|set reminder(?: for)?)\s+(.+?)\s+(?:in|after)\s+(\d+)\s*(seconds?|secs?|minutes?|mins?|hours?|hrs?)$/i
  );
  if (reminderMatch) {
    const reminderText = cleanText(reminderMatch[2], 600);
    const amount = Number(reminderMatch[3] || 0);
    const unit = String(reminderMatch[4] || "").toLowerCase();
    const multiplier = unit.startsWith("hour")
      ? 3600
      : unit.startsWith("hr")
        ? 3600
        : unit.startsWith("min")
          ? 60
          : 1;
    const totalSeconds = amount * multiplier;
    if (reminderText && Number.isFinite(totalSeconds) && totalSeconds > 0 && totalSeconds <= 604800) {
      return {
        kind: "create_reminder",
        title: text,
        reminderText,
        secondsFromNow: totalSeconds,
      };
    }
  }

  return null;
}

function weatherCodeToText(code) {
  const mapping = {
    0: "Clear sky",
    1: "Mainly clear",
    2: "Partly cloudy",
    3: "Overcast",
    45: "Fog",
    48: "Depositing rime fog",
    51: "Light drizzle",
    53: "Moderate drizzle",
    55: "Dense drizzle",
    56: "Freezing drizzle",
    57: "Dense freezing drizzle",
    61: "Slight rain",
    63: "Moderate rain",
    65: "Heavy rain",
    66: "Freezing rain",
    67: "Heavy freezing rain",
    71: "Slight snow",
    73: "Moderate snow",
    75: "Heavy snow",
    77: "Snow grains",
    80: "Rain showers",
    81: "Moderate rain showers",
    82: "Violent rain showers",
    85: "Snow showers",
    86: "Heavy snow showers",
    95: "Thunderstorm",
    96: "Thunderstorm with hail",
    99: "Heavy thunderstorm with hail",
  };
  return mapping[Number(code)] || "Unknown weather";
}

async function getWeatherSummary(location) {
  const query = cleanText(location, 120) || "Delhi";

  const geoRes = await fetch(
    `https://geocoding-api.open-meteo.com/v1/search?name=${encodeURIComponent(
      query
    )}&count=1&language=en&format=json`
  );
  const geoData = await geoRes.json();
  const place = geoData?.results?.[0];
  if (!place) {
    return { ok: false, error: "Location not found" };
  }

  const latitude = Number(place.latitude);
  const longitude = Number(place.longitude);
  const forecastRes = await fetch(
    `https://api.open-meteo.com/v1/forecast?latitude=${latitude}&longitude=${longitude}&current=temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m&timezone=auto`
  );
  const forecastData = await forecastRes.json();
  const current = forecastData?.current;
  if (!current) {
    return { ok: false, error: "Weather data unavailable" };
  }

  return {
    ok: true,
    city: place.name,
    country: place.country || "",
    temperature: current.temperature_2m,
    feelsLike: current.apparent_temperature,
    humidity: current.relative_humidity_2m,
    wind: current.wind_speed_10m,
    weatherCode: current.weather_code,
    weatherText: weatherCodeToText(current.weather_code),
  };
}

function buildDailyBriefing(userId, language) {
  const now = new Date();
  const dateText = now.toLocaleDateString();
  const timeText = now.toLocaleTimeString();

  if (!userId) {
    if (language === "hi" || language === "hinglish") {
      return {
        reply: `Aaj ka briefing:\nDate: ${dateText}\nTime: ${timeText}\nCloud login karoge to tasks, notes aur memory summary bhi de sakta hoon.`,
        info: `Date: ${dateText} | Time: ${timeText}`,
      };
    }
    return {
      reply: `Daily briefing:\nDate: ${dateText}\nTime: ${timeText}\nSign in to cloud for tasks, notes, and memory summary.`,
      info: `Date: ${dateText} | Time: ${timeText}`,
    };
  }

  const pendingTasks = db
    .prepare("SELECT COUNT(*) AS total FROM tasks WHERE user_id = ? AND done = 0")
    .get(userId)?.total;
  const notesCount = db
    .prepare("SELECT COUNT(*) AS total FROM notes WHERE user_id = ?")
    .get(userId)?.total;
  const sessionsCount = db
    .prepare("SELECT COUNT(*) AS total FROM chat_sessions WHERE user_id = ?")
    .get(userId)?.total;
  const memoryCount = db
    .prepare("SELECT COUNT(*) AS total FROM user_memories WHERE user_id = ?")
    .get(userId)?.total;

  if (language === "hi" || language === "hinglish") {
    return {
      reply: `Aaj ka briefing:\nDate: ${dateText}\nTime: ${timeText}\nPending tasks: ${pendingTasks}\nNotes: ${notesCount}\nSaved chats: ${sessionsCount}\nMemories: ${memoryCount}`,
      info: `Tasks ${pendingTasks} | Notes ${notesCount} | Chats ${sessionsCount} | Memories ${memoryCount}`,
    };
  }

  return {
    reply: `Daily briefing:\nDate: ${dateText}\nTime: ${timeText}\nPending tasks: ${pendingTasks}\nNotes: ${notesCount}\nSaved chats: ${sessionsCount}\nMemories: ${memoryCount}`,
    info: `Tasks ${pendingTasks} | Notes ${notesCount} | Chats ${sessionsCount} | Memories ${memoryCount}`,
  };
}

function buildGoalPlan(goalText = "") {
  const goal = cleanText(goalText, 300);
  if (!goal) return null;

  const lower = goal.toLowerCase();
  let steps = [];

  if (/(interview|placement|job)/.test(lower)) {
    steps = [
      "Define target role and company list",
      "Revise core CS subjects and one DSA set daily",
      "Build 2 strong project stories with metrics",
      "Practice 3 mock interviews and refine weak areas",
      "Prepare resume + outreach message for referrals",
      "Track applications and follow-ups in a checklist",
    ];
  } else if (/(flutter|app|project|saas|startup|mvp|product)/.test(lower)) {
    steps = [
      "Write scope, success metric, and non-goals",
      "Break scope into week-wise milestones",
      "Ship core user flow first as a thin MVP",
      "Add analytics, error handling, and tests",
      "Collect feedback from first 5 users",
      "Iterate and prepare release checklist",
    ];
  } else if (/(exam|study|semester|gate|cat|upsc)/.test(lower)) {
    steps = [
      "Split syllabus into modules and set deadlines",
      "Create daily study blocks with revision slots",
      "Solve previous-year and timed practice sets",
      "Analyze mistakes and maintain weak-topic log",
      "Run weekly full-length mocks",
      "Finalize last-week revision strategy",
    ];
  } else {
    steps = [
      "Define the exact outcome and success metric",
      "Break the goal into 5-7 execution steps",
      "Prioritize first 2 high-impact steps",
      "Time-block tasks on calendar for this week",
      "Review progress and remove blockers",
      "Ship first measurable result",
    ];
  }

  const planSteps = steps.slice(0, 8).map((title, index) => ({
    id: `S${index + 1}`,
    title,
    done: false,
  }));

  return {
    goal,
    estimatedDays: Math.max(5, planSteps.length * 2),
    steps: planSteps,
  };
}

function buildWorkflowPlan(goalText = "") {
  const base = buildGoalPlan(goalText);
  if (!base) return null;
  return {
    title: `Workflow: ${base.goal}`,
    goal: base.goal,
    steps: base.steps,
    estimatedDays: base.estimatedDays,
  };
}

function buildWorkflowCommandResponse(goalText, language = "en") {
  const workflow = buildWorkflowPlan(goalText);
  if (!workflow) {
    return buildCommandResponse(
      language === "hi" || language === "hinglish"
        ? "Workflow banane ke liye clear goal do."
        : "Please provide a clear goal to create workflow.",
      "show_info",
      { info: "Workflow goal missing" }
    );
  }

  const preview = workflow.steps.map((item) => `- ${item.title}`).join("\n");
  const reply =
    language === "hi" || language === "hinglish"
      ? `Workflow ready:\nGoal: ${workflow.goal}\n${preview}\n\nRun dabao to workflow job create kar do.`
      : `Workflow ready:\nGoal: ${workflow.goal}\n${preview}\n\nTap Run to create workflow job.`;

  return buildCommandResponse(reply, "create_workflow_job", {
    info: JSON.stringify(workflow),
  });
}

function buildGoalPlanCommandResponse(goalText, language = "en") {
  const plan = buildGoalPlan(goalText);
  if (!plan) {
    return buildCommandResponse(
      language === "hi" || language === "hinglish"
        ? "Goal plan banane ke liye clear goal do."
        : "Please provide a clear goal to create a plan.",
      "show_info",
      { info: "Goal text missing" }
    );
  }

  const preview = plan.steps.map((item) => `- ${item.title}`).join("\n");
  const reply =
    language === "hi" || language === "hinglish"
      ? `Goal plan ready:\nGoal: ${plan.goal}\nEstimated: ${plan.estimatedDays} days\n${preview}\n\nRun dabao to tasks auto-create kar do.`
      : `Goal plan ready:\nGoal: ${plan.goal}\nEstimated: ${plan.estimatedDays} days\n${preview}\n\nTap Run to auto-create this plan as tasks.`;

  return buildCommandResponse(reply, "execute_goal_plan", {
    info: JSON.stringify(plan),
  });
}

function normalizeChatHistory(chatHistory = []) {
  if (!Array.isArray(chatHistory)) return [];

  const normalized = [];

  for (const item of chatHistory) {
    if (!item || typeof item !== "object") continue;

    const roleRaw = String(item.role || "")
      .trim()
      .toLowerCase();
    const role = roleRaw === "assistant" || roleRaw === "user" ? roleRaw : "";
    if (!role) continue;

    const content = String(item.content || "").trim();
    if (!content) continue;

    normalized.push({
      role,
      content: content.slice(0, 4000),
    });
  }

  return normalized;
}

function buildConversationMessages(systemPrompt, message, chatHistory = []) {
  const history = normalizeChatHistory(chatHistory);
  const trimmedHistory = history.slice(-12);
  const latest = trimmedHistory[trimmedHistory.length - 1];
  const currentUserMessage = String(message || "").trim().slice(0, 4000);
  const shouldAppendCurrent =
    currentUserMessage &&
    !(
      latest &&
      latest.role === "user" &&
      latest.content.trim() === currentUserMessage
    );

  return [
    { role: "system", content: systemPrompt },
    ...trimmedHistory,
    ...(shouldAppendCurrent
      ? [{ role: "user", content: currentUserMessage }]
      : []),
  ];
}

async function handleCommandIntent(message, language, userId = null) {
  const text = message.toLowerCase().trim();

  if (text.includes("open youtube")) {
    return buildCommandResponse(
      language === "hi"
        ? "YouTube khol raha hoon."
        : language === "hinglish"
          ? "YouTube open kar raha hoon."
          : "Opening YouTube.",
      "open_url",
      { url: "https://www.youtube.com" }
    );
  }

  if (text.includes("open google")) {
    return buildCommandResponse(
      language === "hi"
        ? "Google khol raha hoon."
        : language === "hinglish"
          ? "Google open kar raha hoon."
          : "Opening Google.",
      "open_url",
      { url: "https://www.google.com" }
    );
  }

  if (text.includes("open github")) {
    return buildCommandResponse(
      language === "hi"
        ? "GitHub khol raha hoon."
        : language === "hinglish"
          ? "GitHub open kar raha hoon."
          : "Opening GitHub.",
      "open_url",
      { url: "https://github.com" }
    );
  }

  if (text.includes("open linkedin")) {
    return buildCommandResponse(
      language === "hi"
        ? "LinkedIn khol raha hoon."
        : language === "hinglish"
          ? "LinkedIn open kar raha hoon."
          : "Opening LinkedIn.",
      "open_url",
      { url: "https://www.linkedin.com" }
    );
  }

  if (text.includes("open spotify")) {
    return buildCommandResponse(
      language === "hi"
        ? "Spotify khol raha hoon."
        : language === "hinglish"
          ? "Spotify open kar raha hoon."
          : "Opening Spotify.",
      "open_url",
      { url: "https://open.spotify.com" }
    );
  }

  if (text.includes("open whatsapp")) {
    return buildCommandResponse(
      language === "hi"
        ? "WhatsApp Web khol raha hoon."
        : language === "hinglish"
          ? "WhatsApp Web open kar raha hoon."
          : "Opening WhatsApp Web.",
      "open_url",
      { url: "https://web.whatsapp.com" }
    );
  }

  if (text.includes("open gmail")) {
    return buildCommandResponse(
      language === "hi"
        ? "Gmail khol raha hoon."
        : language === "hinglish"
          ? "Gmail open kar raha hoon."
          : "Opening Gmail.",
      "open_url",
      { url: "https://mail.google.com" }
    );
  }

  if (text.startsWith("search ")) {
    const query = message.trim().substring(7).trim();
    const url = `https://www.google.com/search?q=${encodeURIComponent(query)}`;

    return buildCommandResponse(
      language === "hi"
        ? `"${query}" ke liye search kar raha hoon.`
        : language === "hinglish"
          ? `"${query}" ke liye search kar raha hoon.`
          : `Searching for "${query}".`,
      "open_url",
      { url }
    );
  }

  if (text.includes("current time") || text.includes("what is the time")) {
    const now = new Date().toLocaleTimeString();
    return buildCommandResponse(
      language === "hi"
        ? `Abhi time ${now} hai.`
        : language === "hinglish"
          ? `Abhi time ${now} hai.`
          : `The current time is ${now}.`,
      "show_info",
      { info: now }
    );
  }

  if (text.includes("today date") || text.includes("what is today's date")) {
    const today = new Date().toLocaleDateString();
    return buildCommandResponse(
      language === "hi"
        ? `Aaj ki date ${today} hai.`
        : language === "hinglish"
          ? `Aaj ki date ${today} hai.`
          : `Today's date is ${today}.`,
      "show_info",
      { info: today }
    );
  }

  if (
    text.includes("daily briefing") ||
    text.includes("my briefing") ||
    text.includes("status report")
  ) {
    const briefing = buildDailyBriefing(userId, language);
    return buildCommandResponse(briefing.reply, "show_info", {
      info: briefing.info,
    });
  }

  const goalPlanMatch =
    message.match(/^(?:create plan for|make plan for|roadmap for|plan for)\s+(.+)$/i) ||
    message.match(/^goal plan\s+(.+)$/i);
  if (goalPlanMatch && goalPlanMatch[1]) {
    return buildGoalPlanCommandResponse(goalPlanMatch[1], language);
  }

  const workflowMatch =
    message.match(
      /^(?:create workflow for|start workflow for|workflow for)\s+(.+)$/i
    ) || message.match(/^workflow\s+(.+)$/i);
  if (workflowMatch && workflowMatch[1]) {
    return buildWorkflowCommandResponse(workflowMatch[1], language);
  }

  if (text === "list workflows" || text === "show workflows") {
    if (!userId) {
      return buildCommandResponse(
        language === "hi" || language === "hinglish"
          ? "Workflow dekhne ke liye pehle cloud login karo."
          : "Please sign in first to list workflows.",
        "show_info",
        { info: "Authentication required" }
      );
    }
    return buildCommandResponse(
      language === "hi" || language === "hinglish"
        ? "Workflows dekhne ke liye Run dabao."
        : "Tap Run to list workflows.",
      "list_workflow_jobs",
      { info: "jobs" }
    );
  }

  const addKnowledgeMatch = message.match(
    /^(?:add knowledge|save knowledge)\s+(.+?)(?:\s*::\s*(.+))?$/i
  );
  if (addKnowledgeMatch) {
    if (!userId) {
      return buildCommandResponse(
        language === "hi" || language === "hinglish"
          ? "Knowledge save karne ke liye pehle cloud login karo."
          : "Please sign in first to save knowledge.",
        "show_info",
        { info: "Authentication required" }
      );
    }
    const title = cleanText(addKnowledgeMatch[1], 180);
    const content = cleanText(addKnowledgeMatch[2] || addKnowledgeMatch[1], 12000);
    if (!content) {
      return buildCommandResponse(
        language === "hi" || language === "hinglish"
          ? "Knowledge content missing hai."
          : "Knowledge content is missing.",
        "show_info",
        { info: "Missing content" }
      );
    }
    return buildCommandResponse(
      language === "hi" || language === "hinglish"
        ? "Knowledge note ready hai. Run dabao save karne ke liye."
        : "Knowledge note is ready. Tap Run to save.",
      "add_knowledge",
      { info: JSON.stringify({ title, content }) }
    );
  }

  const searchKnowledgeMatch = message.match(
    /^(?:search knowledge|find in knowledge)\s+(.+)$/i
  );
  if (searchKnowledgeMatch && searchKnowledgeMatch[1]) {
    if (!userId) {
      return buildCommandResponse(
        language === "hi" || language === "hinglish"
          ? "Knowledge search ke liye pehle cloud login karo."
          : "Please sign in first to search knowledge.",
        "show_info",
        { info: "Authentication required" }
      );
    }
    const query = cleanText(searchKnowledgeMatch[1], 240);
    return buildCommandResponse(
      language === "hi" || language === "hinglish"
        ? "Knowledge search ready hai. Run dabao."
        : "Knowledge search is ready. Tap Run.",
      "search_knowledge",
      { info: JSON.stringify({ query }) }
    );
  }

  const weatherMatch = message.match(
    /(?:weather|forecast|temperature)\s+(?:in|at|for)\s+([a-zA-Z\s-]{2,80})$/i
  );
  if (weatherMatch) {
    const location = cleanText(weatherMatch[1], 80);
    const weather = await getWeatherSummary(location);

    if (!weather.ok) {
      return buildCommandResponse(
        language === "hi" || language === "hinglish"
          ? "Weather data abhi nahi mil paaya."
          : "Could not fetch weather right now.",
        "show_info",
        { info: weather.error || "Weather unavailable" }
      );
    }

    const placeLabel = weather.country
      ? `${weather.city}, ${weather.country}`
      : weather.city;

    const reply =
      language === "hi" || language === "hinglish"
        ? `${placeLabel} ka weather: ${weather.weatherText}. Temp ${weather.temperature}°C, feels ${weather.feelsLike}°C, humidity ${weather.humidity}%, wind ${weather.wind} km/h.`
        : `Weather in ${placeLabel}: ${weather.weatherText}. Temp ${weather.temperature}°C, feels like ${weather.feelsLike}°C, humidity ${weather.humidity}%, wind ${weather.wind} km/h.`;

    return buildCommandResponse(reply, "show_info", {
      info: `${placeLabel} | ${weather.weatherText} | ${weather.temperature}°C`,
    });
  }

  if (text.startsWith("calculate ")) {
    const expression = message.trim().substring(10).trim();
    const result = safeCalculate(expression);

    if (result === null) {
      return buildCommandResponse(
        language === "hi"
          ? "Yeh calculation sahi tarah se nahi ho saki."
          : language === "hinglish"
            ? "Ye calculation sahi tarah se nahi ho saki."
            : "I could not calculate that correctly."
      );
    }

    return buildCommandResponse(
      `Calculation result: ${result}`,
      "show_info",
      { info: String(result) }
    );
  }

  const noteMatch = message.match(/^(add note|create note|note add)\s+(.+)$/i);
  if (noteMatch && noteMatch[2]) {
    const noteText = cleanText(noteMatch[2], 1200);
    return buildCommandResponse(
      language === "hi"
        ? "Note ready hai. Run dabao to save ho jayega."
        : language === "hinglish"
          ? "Note ready hai. Run dabao to save ho jayega."
          : "Note is ready. Tap Run to save it.",
      "create_note",
      { info: noteText }
    );
  }

  const taskMatch = message.match(/^(create task|add task|task create)\s+(.+)$/i);
  if (taskMatch && taskMatch[2]) {
    const taskText = cleanText(taskMatch[2], 600);
    return buildCommandResponse(
      language === "hi"
        ? "Task ready hai. Run dabao to add ho jayega."
        : language === "hinglish"
          ? "Task ready hai. Run dabao to add ho jayega."
          : "Task is ready. Tap Run to add it.",
      "create_task",
      { info: taskText }
    );
  }

  const timerMatch = message.match(
    /^set timer(?:\s+for)?\s+(\d+)\s*(seconds?|secs?|minutes?|mins?)$/i
  );
  if (timerMatch) {
    const amount = Number(timerMatch[1] || 0);
    const unit = String(timerMatch[2] || "").toLowerCase();
    const multiplier = unit.startsWith("min") ? 60 : 1;
    const totalSeconds = amount * multiplier;

    if (Number.isFinite(totalSeconds) && totalSeconds > 0 && totalSeconds <= 86_400) {
      return buildCommandResponse(
        language === "hi"
          ? `${amount} ${unit} ka timer set karne ke liye Run dabao.`
          : language === "hinglish"
            ? `${amount} ${unit} ka timer set karne ke liye Run dabao.`
            : `Tap Run to start a ${amount} ${unit} timer.`,
        "set_timer",
        { info: String(totalSeconds) }
      );
    }
  }

  const reminderMatch = message.match(
    /^(remind me to|set reminder(?: for)?)\s+(.+?)\s+(?:in|after)\s+(\d+)\s*(seconds?|secs?|minutes?|mins?|hours?|hrs?)$/i
  );
  if (reminderMatch) {
    const reminderText = cleanText(reminderMatch[2], 600);
    const amount = Number(reminderMatch[3] || 0);
    const unit = String(reminderMatch[4] || "").toLowerCase();
    const multiplier = unit.startsWith("hour")
      ? 3600
      : unit.startsWith("hr")
        ? 3600
        : unit.startsWith("min")
          ? 60
          : 1;
    const totalSeconds = amount * multiplier;

    if (reminderText && Number.isFinite(totalSeconds) && totalSeconds > 0 && totalSeconds <= 604800) {
      const triggerAtIso = new Date(Date.now() + totalSeconds * 1000).toISOString();
      const payload = JSON.stringify({
        title: reminderText,
        secondsFromNow: totalSeconds,
        triggerAtIso,
      });

      return buildCommandResponse(
        language === "hi"
          ? `Reminder ready hai. "${reminderText}" ${amount} ${unit} baad schedule karne ke liye Run dabao.`
          : language === "hinglish"
            ? `Reminder ready hai. "${reminderText}" ${amount} ${unit} baad schedule karne ke liye Run dabao.`
            : `Reminder ready. Tap Run to schedule "${reminderText}" in ${amount} ${unit}.`,
        "create_reminder",
        { info: payload }
      );
    }
  }

  const createRoutineMatch = message.match(
    /^(create routine|save routine)\s+([a-zA-Z0-9 _-]{2,50})\s*:\s*(.+)$/i
  );
  if (createRoutineMatch) {
    const routineName = cleanText(createRoutineMatch[2], 50);
    const stepsRaw = createRoutineMatch[3]
      .split(";")
      .map((s) => s.trim())
      .filter(Boolean)
      .slice(0, 12);
    const steps = stepsRaw
      .map((segment) => parseRoutineStep(segment))
      .filter(Boolean);

    if (routineName && steps.length > 0) {
      return buildCommandResponse(
        language === "hi"
          ? `Routine "${routineName}" ready hai. Run dabao to save karo.`
          : language === "hinglish"
            ? `Routine "${routineName}" ready hai. Run dabao to save karo.`
            : `Routine "${routineName}" is ready. Tap Run to save it.`,
        "create_routine",
        {
          info: JSON.stringify({
            name: routineName,
            steps,
          }),
        }
      );
    }
  }

  const runRoutineMatch = message.match(/^(run routine|start routine)\s+(.+)$/i);
  if (runRoutineMatch) {
    const routineName = cleanText(runRoutineMatch[2], 50);
    if (routineName) {
      return buildCommandResponse(
        language === "hi"
          ? `Routine "${routineName}" run karne ke liye Run dabao.`
          : language === "hinglish"
            ? `Routine "${routineName}" run karne ke liye Run dabao.`
            : `Tap Run to start routine "${routineName}".`,
        "run_routine",
        {
          info: JSON.stringify({ name: routineName }),
        }
      );
    }
  }

  if (text === "list routines" || text === "show routines") {
    return buildCommandResponse(
      language === "hi"
        ? "Saved routines dekhne ke liye Run dabao."
        : language === "hinglish"
          ? "Saved routines dekhne ke liye Run dabao."
          : "Tap Run to list your saved routines.",
      "list_routines",
      { info: "local" }
    );
  }

  if (text === "connect google calendar") {
    if (!userId) {
      return buildCommandResponse(
        language === "hi" || language === "hinglish"
          ? "Google Calendar connect karne ke liye pehle cloud login karo."
          : "Please sign in first to connect Google Calendar.",
        "show_info",
        { info: "Authentication required" }
      );
    }

    const auth = buildGoogleCalendarAuthUrl(userId);
    if (!auth.ok) {
      return buildCommandResponse(
        language === "hi" || language === "hinglish"
          ? "Google Calendar integration backend me configured nahi hai."
          : "Google Calendar integration is not configured on backend.",
        "show_info",
        { info: auth.error || "Not configured" }
      );
    }

    return buildCommandResponse(
      language === "hi" || language === "hinglish"
        ? "Google Calendar connect karne ke liye link open karo."
        : "Open the link to connect Google Calendar.",
      "open_url",
      { url: auth.url }
    );
  }

  if (text === "google calendar status") {
    if (!userId) {
      return buildCommandResponse(
        language === "hi" || language === "hinglish"
          ? "Status dekhne ke liye pehle cloud login karo."
          : "Please sign in first to check Google Calendar status.",
        "show_info",
        { info: "Authentication required" }
      );
    }

    const row = getGoogleTokenRow(userId);
    if (!row) {
      return buildCommandResponse(
        language === "hi" || language === "hinglish"
          ? "Google Calendar connected nahi hai."
          : "Google Calendar is not connected.",
        "show_info",
        { info: "Disconnected" }
      );
    }

    return buildCommandResponse(
      language === "hi" || language === "hinglish"
        ? "Google Calendar connected hai."
        : "Google Calendar is connected.",
      "show_info",
      { info: `Connected | Expires: ${row.expiry_date}` }
    );
  }

  if (
    text === "push doctor" ||
    text === "run push doctor" ||
    text === "push diagnostics"
  ) {
    if (!userId) {
      return buildCommandResponse(
        language === "hi" || language === "hinglish"
          ? "Push diagnostics ke liye pehle cloud login karo."
          : "Please sign in first to run push diagnostics.",
        "show_info",
        { info: "Authentication required" }
      );
    }

    return buildCommandResponse(
      language === "hi" || language === "hinglish"
        ? "Push Doctor chalane ke liye Run dabao."
        : "Tap Run to execute Push Doctor.",
      "run_push_doctor",
      { info: "doctor" }
    );
  }

  if (
    text === "push self test" ||
    text === "run push self test" ||
    text === "run full push self test" ||
    text === "test push pipeline"
  ) {
    if (!userId) {
      return buildCommandResponse(
        language === "hi" || language === "hinglish"
          ? "Push self-test ke liye pehle cloud login karo."
          : "Please sign in first to run push self-test.",
        "show_info",
        { info: "Authentication required" }
      );
    }

    return buildCommandResponse(
      language === "hi" || language === "hinglish"
        ? "Full Push Self-Test chalane ke liye Run dabao."
        : "Tap Run to execute full push self-test.",
      "run_push_self_test",
      { info: "self_test" }
    );
  }

  if (text === "disconnect google calendar") {
    if (!userId) {
      return buildCommandResponse(
        language === "hi" || language === "hinglish"
          ? "Disconnect ke liye pehle cloud login karo."
          : "Please sign in first to disconnect Google Calendar.",
        "show_info",
        { info: "Authentication required" }
      );
    }

    const result = db
      .prepare("DELETE FROM google_calendar_tokens WHERE user_id = ?")
      .run(userId);
    return buildCommandResponse(
      language === "hi" || language === "hinglish"
        ? "Google Calendar disconnect ho gaya."
        : "Google Calendar disconnected.",
      "show_info",
      { info: result.changes > 0 ? "Disconnected" : "Already disconnected" }
    );
  }

  if (text === "list google events" || text === "show google events") {
    if (!userId) {
      return buildCommandResponse(
        language === "hi" || language === "hinglish"
          ? "Google events dekhne ke liye pehle cloud login karo."
          : "Please sign in first to list Google Calendar events.",
        "show_info",
        { info: "Authentication required" }
      );
    }
    try {
      const events = await listGoogleCalendarEvents(userId, { maxResults: 8 });
      if (events.length === 0) {
        return buildCommandResponse(
          language === "hi" || language === "hinglish"
            ? "Google Calendar me upcoming events nahi mile."
            : "No upcoming Google Calendar events found.",
          "show_info",
          { info: "No upcoming events" }
        );
      }

      const lines = events.map((e, i) => {
        const when = String(e.start || "").replace("T", " ").slice(0, 16);
        return `${i + 1}. ${e.summary} (${when})`;
      });

      return buildCommandResponse(
        language === "hi" || language === "hinglish"
          ? `Google events:\n${lines.join("\n")}`
          : `Google events:\n${lines.join("\n")}`,
        "show_info",
        { info: `Events: ${events.length}` }
      );
    } catch (error) {
      return buildCommandResponse(
        language === "hi" || language === "hinglish"
          ? "Google events fetch nahi ho paaye."
          : "Could not fetch Google Calendar events.",
        "show_info",
        { info: error?.message || "Fetch failed" }
      );
    }
  }

  if (
    text === "recent emails" ||
    text === "show inbox" ||
    text === "check inbox" ||
    text === "show recent emails"
  ) {
    if (!userId) {
      return buildCommandResponse(
        language === "hi" || language === "hinglish"
          ? "Inbox dekhne ke liye pehle cloud login karo."
          : "Please sign in first to view inbox.",
        "show_info",
        { info: "Authentication required" }
      );
    }

    try {
      const emails = await listGmailMessages(userId, { maxResults: 8 });
      if (emails.length === 0) {
        return buildCommandResponse(
          language === "hi" || language === "hinglish"
            ? "Recent emails nahi mile."
            : "No recent emails found.",
          "show_info",
          { info: "No recent emails" }
        );
      }

      const lines = emails.map((item, index) => {
        const subject = cleanText(item.subject, 80) || "(No subject)";
        const from = cleanText(item.from, 80) || "Unknown";
        return `${index + 1}. ${subject} - ${from}`;
      });

      return buildCommandResponse(
        language === "hi" || language === "hinglish"
          ? `Recent emails:\n${lines.join("\n")}`
          : `Recent emails:\n${lines.join("\n")}`,
        "show_info",
        { info: `Emails: ${emails.length}` }
      );
    } catch (error) {
      return buildCommandResponse(
        language === "hi" || language === "hinglish"
          ? "Inbox fetch nahi ho paaya."
          : "Could not fetch inbox.",
        "show_info",
        { info: error?.message || "Inbox fetch failed" }
      );
    }
  }

  if (
    text === "list google contacts" ||
    text === "show google contacts" ||
    text === "show my contacts" ||
    text === "list contacts"
  ) {
    if (!userId) {
      return buildCommandResponse(
        language === "hi" || language === "hinglish"
          ? "Contacts dekhne ke liye pehle cloud login karo."
          : "Please sign in first to view contacts.",
        "show_info",
        { info: "Authentication required" }
      );
    }

    try {
      const contacts = await listGoogleContacts(userId, { maxResults: 12 });
      if (contacts.length === 0) {
        return buildCommandResponse(
          language === "hi" || language === "hinglish"
            ? "Contacts nahi mile."
            : "No contacts found.",
          "show_info",
          { info: "No contacts" }
        );
      }

      const lines = contacts.map((item, index) => {
        const name = cleanText(item.displayName, 60) || "(No name)";
        const email = cleanText(item.email, 80);
        const phone = cleanText(item.phone, 50);
        const value = email || phone || "No email/phone";
        return `${index + 1}. ${name} - ${value}`;
      });

      return buildCommandResponse(
        language === "hi" || language === "hinglish"
          ? `Contacts:\n${lines.join("\n")}`
          : `Contacts:\n${lines.join("\n")}`,
        "show_info",
        { info: `Contacts: ${contacts.length}` }
      );
    } catch (error) {
      return buildCommandResponse(
        language === "hi" || language === "hinglish"
          ? "Contacts fetch nahi ho paaya."
          : "Could not fetch contacts.",
        "show_info",
        { info: error?.message || "Contacts fetch failed" }
      );
    }
  }

  const findContactMatch = message.match(/^(find contact|search contact)\s+(.+)$/i);
  if (findContactMatch) {
    if (!userId) {
      return buildCommandResponse(
        language === "hi" || language === "hinglish"
          ? "Contact search ke liye pehle cloud login karo."
          : "Please sign in first to search contacts.",
        "show_info",
        { info: "Authentication required" }
      );
    }
    const query = cleanText(findContactMatch[2], 80).toLowerCase();
    try {
      const contacts = await listGoogleContacts(userId, { maxResults: 80 });
      const matched = contacts.filter((item) => {
        const name = String(item.displayName || "").toLowerCase();
        const email = String(item.email || "").toLowerCase();
        const phone = String(item.phone || "").toLowerCase();
        return (
          name.includes(query) || email.includes(query) || phone.includes(query)
        );
      });

      if (matched.length === 0) {
        return buildCommandResponse(
          language === "hi" || language === "hinglish"
            ? `"${query}" ke liye koi contact nahi mila.`
            : `No contacts found for "${query}".`,
          "show_info",
          { info: "No match" }
        );
      }

      const lines = matched.slice(0, 8).map((item, index) => {
        const name = cleanText(item.displayName, 60) || "(No name)";
        const value = cleanText(item.email, 80) || cleanText(item.phone, 50) || "No email/phone";
        return `${index + 1}. ${name} - ${value}`;
      });

      return buildCommandResponse(
        language === "hi" || language === "hinglish"
          ? `Matched contacts:\n${lines.join("\n")}`
          : `Matched contacts:\n${lines.join("\n")}`,
        "show_info",
        { info: `Matches: ${matched.length}` }
      );
    } catch (error) {
      return buildCommandResponse(
        language === "hi" || language === "hinglish"
          ? "Contact search fail ho gaya."
          : "Contact search failed.",
        "show_info",
        { info: error?.message || "Search failed" }
      );
    }
  }

  const sendEmailMatch =
    message.match(
      /^(?:send email to|email to)\s+([^\s]+@[^\s]+)\s+subject\s+(.+?)\s+(?:body|message)\s+([\s\S]+)$/i
    ) ||
    message.match(
      /^send email\s+to\s+([^\s]+@[^\s]+)\s+(.+?)\s+(?:body|message)\s+([\s\S]+)$/i
    );
  if (sendEmailMatch) {
    if (!userId) {
      return buildCommandResponse(
        language === "hi" || language === "hinglish"
          ? "Email send karne ke liye pehle cloud login karo."
          : "Please sign in first to send email.",
        "show_info",
        { info: "Authentication required" }
      );
    }

    const to = cleanText(sendEmailMatch[1], 320);
    const subject = cleanText(sendEmailMatch[2], 300);
    const body = cleanText(sendEmailMatch[3], 8000);
    const validTo = validEmail(to);

    if (!validTo || !subject || !body) {
      return buildCommandResponse(
        language === "hi" || language === "hinglish"
          ? "Email format invalid hai. Use: send email to <email> subject <text> body <text>"
          : "Invalid email format. Use: send email to <email> subject <text> body <text>",
        "show_info",
        { info: "Invalid email command format" }
      );
    }

    return buildCommandResponse(
      language === "hi" || language === "hinglish"
        ? `Draft ready hai: ${validTo}. Confirm karke send karo.`
        : `Email draft ready for ${validTo}. Confirm to send.`,
      "google_gmail_send_confirm",
      {
        info: JSON.stringify({
          to: validTo,
          subject,
          body,
        }),
      }
    );
  }

  const createGoogleEventMatch = message.match(
    /^(create google event|add google event)\s+(.+?)\s+on\s+(\d{4}-\d{2}-\d{2})\s+at\s+(\d{1,2}:\d{2})$/i
  );
  if (createGoogleEventMatch) {
    if (!userId) {
      return buildCommandResponse(
        language === "hi" || language === "hinglish"
          ? "Google event banane ke liye pehle cloud login karo."
          : "Please sign in first to create Google Calendar events.",
        "show_info",
        { info: "Authentication required" }
      );
    }

    const title = cleanText(createGoogleEventMatch[2], 200);
    const dateText = cleanText(createGoogleEventMatch[3], 20);
    const timeText = cleanText(createGoogleEventMatch[4], 10);
    const startAt = new Date(`${dateText}T${timeText}:00`);

    if (!title || !Number.isFinite(startAt.getTime())) {
      return buildCommandResponse(
        language === "hi" || language === "hinglish"
          ? "Invalid Google event format."
          : "Invalid Google event format.",
        "show_info",
        { info: "Use: create google event <title> on YYYY-MM-DD at HH:MM" }
      );
    }

    try {
      const event = await createGoogleCalendarEvent(userId, {
        title,
        startIso: startAt.toISOString(),
        endIso: new Date(startAt.getTime() + 60 * 60 * 1000).toISOString(),
      });

      return buildCommandResponse(
        language === "hi" || language === "hinglish"
          ? `Google event create ho gaya: ${event.summary}`
          : `Google event created: ${event.summary}`,
        "open_url",
        { url: event.htmlLink, info: event.start }
      );
    } catch (error) {
      return buildCommandResponse(
        language === "hi" || language === "hinglish"
          ? "Google event create nahi ho paaya."
          : "Could not create Google Calendar event.",
        "show_info",
        { info: error?.message || "Create failed" }
      );
    }
  }

  const createEventMatch = message.match(
    /^(create event|add event|schedule event)\s+(.+?)\s+on\s+(\d{4}-\d{2}-\d{2})\s+at\s+(\d{1,2}:\d{2})$/i
  );
  if (createEventMatch) {
    const title = cleanText(createEventMatch[2], 200);
    const dateText = cleanText(createEventMatch[3], 20);
    const timeText = cleanText(createEventMatch[4], 10);

    const [hourRaw, minuteRaw] = timeText.split(":");
    const hour = Number(hourRaw);
    const minute = Number(minuteRaw);
    const dateValid = /^\d{4}-\d{2}-\d{2}$/.test(dateText);
    const timeValid =
      Number.isFinite(hour) &&
      Number.isFinite(minute) &&
      hour >= 0 &&
      hour <= 23 &&
      minute >= 0 &&
      minute <= 59;

    if (title && dateValid && timeValid) {
      return buildCommandResponse(
        language === "hi" || language === "hinglish"
          ? `Event "${title}" ready hai (${dateText} ${timeText}). Run dabao to save karo.`
          : `Event "${title}" is ready (${dateText} ${timeText}). Tap Run to save.`,
        "create_event",
        {
          info: JSON.stringify({
            title,
            date: dateText,
            time: timeText,
          }),
        }
      );
    }
  }

  if (
    text === "list events" ||
    text === "show events" ||
    text === "my agenda"
  ) {
    return buildCommandResponse(
      language === "hi" || language === "hinglish"
        ? "Events dekhne ke liye Run dabao."
        : "Tap Run to list your events.",
      "list_events",
      { info: "local" }
    );
  }

  const deleteEventMatch = message.match(/^(delete event|remove event)\s+(.+)$/i);
  if (deleteEventMatch) {
    const title = cleanText(deleteEventMatch[2], 200);
    if (title) {
      return buildCommandResponse(
        language === "hi" || language === "hinglish"
          ? `Event "${title}" delete karne ke liye Run dabao.`
          : `Tap Run to delete event "${title}".`,
        "delete_event",
        { info: title }
      );
    }
  }

  if (text === "undo" || text === "undo last action" || text === "undo action") {
    return buildCommandResponse(
      language === "hi" || language === "hinglish"
        ? "Last action undo karne ke liye Run dabao."
        : "Tap Run to undo the last action.",
      "undo_action",
      { info: "last" }
    );
  }

  if (text === "action history" || text === "show action history") {
    return buildCommandResponse(
      language === "hi" || language === "hinglish"
        ? "Action history dekhne ke liye Run dabao."
        : "Tap Run to view action history.",
      "list_actions",
      { info: "local" }
    );
  }

  return buildCommandResponse(
    language === "hi"
      ? "Command samajh nahi aaya."
      : language === "hinglish"
        ? "Command samajh nahi aaya."
        : "Command not recognized."
  );
}

function handleMemoryCommand(command, userId, language) {
  if (!userId) {
    return {
      type: "command",
      reply:
        language === "hi"
          ? "Memory feature use karne ke liye pehle cloud login karo."
          : language === "hinglish"
            ? "Memory feature ke liye pehle cloud login karo."
            : "Please sign in to cloud mode to use memory features.",
      action: "show_info",
      info: "Authentication required for personal memory",
    };
  }

  if (command.kind === "add") {
    const row = upsertUserMemory(userId, command.text);
    if (!row) {
      return {
        type: "command",
        reply:
          language === "hi"
            ? "Yaad rakhne ke liye valid text do."
            : language === "hinglish"
              ? "Memory save karne ke liye valid text do."
              : "Please provide valid text to remember.",
      };
    }

    return {
      type: "command",
      reply:
        language === "hi"
          ? `Theek hai, maine yaad rakh liya: ${row.memory_text}`
          : language === "hinglish"
            ? `Theek hai, maine yaad rakh liya: ${row.memory_text}`
            : `Saved to memory: ${row.memory_text}`,
      action: "show_info",
      info: row.memory_text,
    };
  }

  if (command.kind === "list") {
    const memories = getUserMemories(userId, 20);
    if (memories.length === 0) {
      return {
        type: "command",
        reply:
          language === "hi"
            ? "Abhi mere paas koi saved memory nahi hai."
            : language === "hinglish"
              ? "Abhi mere paas koi saved memory nahi hai."
              : "I do not have any saved memories yet.",
      };
    }

    const lines = memories.map((m, i) => `${i + 1}. ${m.text}`);
    return {
      type: "command",
      reply:
        language === "hi" || language === "hinglish"
          ? `Mujhe ye yaad hai:\n${lines.join("\n")}`
          : `Here is what I remember:\n${lines.join("\n")}`,
      action: "show_info",
      info: `Memory count: ${memories.length}`,
    };
  }

  if (command.kind === "clear") {
    const result = db
      .prepare("DELETE FROM user_memories WHERE user_id = ?")
      .run(userId);

    return {
      type: "command",
      reply:
        language === "hi"
          ? `${result.changes} memories delete kar di gayi hain.`
          : language === "hinglish"
            ? `${result.changes} memories delete kar di gayi hain.`
            : `Deleted ${result.changes} memories.`,
      action: "show_info",
      info: `Deleted: ${result.changes}`,
    };
  }

  if (command.kind === "remove") {
    const target = cleanText(command.text, 400);
    const rows = db
      .prepare(
        `SELECT id
         FROM user_memories
         WHERE user_id = ? AND lower(memory_text) LIKE ?
         ORDER BY updated_at DESC`
      )
      .all(userId, `%${target.toLowerCase()}%`);

    if (rows.length === 0) {
      return {
        type: "command",
        reply:
          language === "hi" || language === "hinglish"
            ? "Waisi memory nahi mili."
            : "No matching memory found.",
      };
    }

    db.prepare("DELETE FROM user_memories WHERE id = ?").run(rows[0].id);
    return {
      type: "command",
      reply:
        language === "hi" || language === "hinglish"
          ? "Memory remove kar di."
          : "Memory removed.",
      action: "show_info",
      info: target,
    };
  }

  return null;
}

async function handleChatIntent(
  message,
  language,
  smartReply = true,
  chatHistory = [],
  memoryContext = "",
  assistantMode = "jarvis"
) {
  const client = createOpenRouterClient();

  if (!client) {
    return {
      type: "chat",
      reply:
        language === "hi"
          ? "OPENROUTER_API_KEY missing hai."
          : language === "hinglish"
            ? "OPENROUTER_API_KEY missing hai."
            : "OPENROUTER_API_KEY is missing.",
    };
  }

  const completion = await client.chat.completions.create({
    model: process.env.OPENROUTER_MODEL || "openrouter/free",
    messages: buildConversationMessages(
      `${getChatSystemPrompt(language, smartReply, assistantMode)}${memoryContext}`,
      message,
      chatHistory
    ),
    temperature: smartReply ? 0.7 : 0.4,
  });

  const reply =
    completion.choices?.[0]?.message?.content?.trim() ||
    "Sorry, I could not generate a response.";

  return { type: "chat", reply };
}

async function handleCodeIntent(
  message,
  language,
  smartReply = true,
  chatHistory = [],
  memoryContext = "",
  assistantMode = "jarvis"
) {
  const client = createOpenRouterClient();

  if (!client) {
    return {
      type: "code",
      reply: "OPENROUTER_API_KEY is missing in backend .env",
      code: "",
      language: "text",
    };
  }

  const completion = await client.chat.completions.create({
    model: process.env.OPENROUTER_MODEL || "openrouter/free",
    messages: buildConversationMessages(
      `${getCodeSystemPrompt(language, smartReply, assistantMode)}${memoryContext}`,
      message,
      chatHistory
    ),
    temperature: smartReply ? 0.4 : 0.2,
  });

  const raw =
    completion.choices?.[0]?.message?.content ||
    '{"reply":"No reply","code":"","language":"text"}';

  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch {
    parsed = {
      reply: raw,
      code: raw,
      language: "text",
    };
  }

  return {
    type: "code",
    reply: parsed.reply || "Code generated.",
    code: parsed.code || raw,
    language: parsed.language || "text",
  };
}

async function handleImageIntent(message, language, smartReply = true) {
  let reply = "";
  let prompt = "";

  if (language === "hi") {
    reply = smartReply
      ? "Yeh image generation request lag rahi hai. Neeche better usable image prompt diya gaya hai."
      : "Yeh image request hai. Neeche prompt diya gaya hai.";
  } else if (language === "hinglish") {
    reply = smartReply
      ? "Ye image generation request lag rahi hai. Neeche better usable image prompt diya gaya hai."
      : "Ye image request hai. Neeche prompt diya gaya hai.";
  } else {
    reply = smartReply
      ? "This looks like an image generation request. Here is a better usable image prompt."
      : "This looks like an image request. Here is the prompt.";
  }

  prompt = smartReply
    ? `Create a high-quality, detailed image based on: ${message}. Professional lighting, strong composition, clean background where suitable, visually appealing, high detail, modern style.`
    : `Create an image based on: ${message}. High quality and clear details.`;

  return {
    type: "image",
    reply,
    imagePrompt: prompt,
  };
}

async function handleVideoIntent(message, language, smartReply = true) {
  let reply = "";
  let prompt = "";

  if (language === "hi") {
    reply = smartReply
      ? "Yeh video generation request lag rahi hai. Neeche better usable video prompt diya gaya hai."
      : "Yeh video request hai. Neeche prompt diya gaya hai.";
  } else if (language === "hinglish") {
    reply = smartReply
      ? "Ye video generation request lag rahi hai. Neeche better usable video prompt diya gaya hai."
      : "Ye video request hai. Neeche prompt diya gaya hai.";
  } else {
    reply = smartReply
      ? "This looks like a video generation request. Here is a more usable video prompt."
      : "This looks like a video request. Here is the prompt.";
  }

  prompt = smartReply
    ? `Create a short cinematic video based on: ${message}. Include camera movement, clear subject focus, smooth motion, detailed scene description, and high visual quality.`
    : `Create a short video based on: ${message}. Keep motion smooth and visuals clear.`;

  return {
    type: "video",
    reply,
    videoPrompt: prompt,
  };
}

function extractImageReference(firstImage) {
  if (!firstImage) return { imageUrl: "", imageDataUrl: "" };

  if (typeof firstImage === "string") {
    if (firstImage.startsWith("data:image/")) {
      return { imageUrl: "", imageDataUrl: firstImage };
    }
    return { imageUrl: firstImage, imageDataUrl: "" };
  }

  if (typeof firstImage === "object") {
    const directCandidates = [
      firstImage.image_url,
      firstImage.url,
      firstImage.src,
      firstImage.href,
      firstImage.data,
    ];

    for (const candidate of directCandidates) {
      if (typeof candidate === "string" && candidate.trim()) {
        if (candidate.startsWith("data:image/")) {
          return { imageUrl: "", imageDataUrl: candidate };
        }
        return { imageUrl: candidate, imageDataUrl: "" };
      }

      if (candidate && typeof candidate === "object") {
        const nestedCandidates = [
          candidate.url,
          candidate.image_url,
          candidate.src,
          candidate.href,
          candidate.data,
        ];

        for (const nested of nestedCandidates) {
          if (typeof nested === "string" && nested.trim()) {
            if (nested.startsWith("data:image/")) {
              return { imageUrl: "", imageDataUrl: nested };
            }
            return { imageUrl: nested, imageDataUrl: "" };
          }
        }
      }
    }
  }

  return { imageUrl: "", imageDataUrl: "" };
}

function getPreferredImageProvider() {
  const preferred = (process.env.IMAGE_PROVIDER || "").trim().toLowerCase();

  if (
    preferred === "openai" ||
    preferred === "openrouter" ||
    preferred === "huggingface" ||
    preferred === "pollinations"
  ) {
    return preferred;
  }

  if (process.env.OPENAI_API_KEY) return "openai";
  if (process.env.OPENROUTER_API_KEY) return "openrouter";
  if (process.env.HF_TOKEN) return "huggingface";
  if ((process.env.ALLOW_FREE_IMAGE_PROVIDER || "1").trim() !== "0") {
    return "pollinations";
  }
  return "";
}

function getImageProviderCandidates() {
  const preferred = getPreferredImageProvider();
  const candidates = [];
  const pushIfConfigured = (provider) => {
    if (provider === "openai" && process.env.OPENAI_API_KEY) {
      candidates.push("openai");
    } else if (provider === "openrouter" && process.env.OPENROUTER_API_KEY) {
      candidates.push("openrouter");
    } else if (provider === "huggingface" && process.env.HF_TOKEN) {
      candidates.push("huggingface");
    } else if (
      provider === "pollinations" &&
      (process.env.ALLOW_FREE_IMAGE_PROVIDER || "1").trim() !== "0"
    ) {
      candidates.push("pollinations");
    }
  };

  if (preferred) {
    pushIfConfigured(preferred);
  }

  for (const provider of ["openai", "openrouter", "huggingface", "pollinations"]) {
    pushIfConfigured(provider);
  }

  return Array.from(new Set(candidates));
}

function isHuggingFaceOomError(error) {
  const message = `${error?.error || ""} ${error?.details || ""} ${error?.message || ""}`
    .toLowerCase()
    .trim();
  return (
    message.includes("out of memory") ||
    message.includes("cuda out of memory") ||
    message.includes("oom")
  );
}

function getPreferredVideoProvider() {
  const preferred = (process.env.VIDEO_PROVIDER || "").trim().toLowerCase();

  if (preferred === "huggingface") {
    return preferred;
  }

  if (process.env.HF_TOKEN) return "huggingface";
  return "";
}

function buildImageGenerationError(message, provider, details = "") {
  return {
    error: message,
    details,
    provider,
  };
}

async function generateImageWithOpenAI(prompt) {
  const client = createOpenAIClient();

  if (!client) {
    throw buildImageGenerationError(
      "OPENAI_API_KEY is missing in backend .env",
      "openai"
    );
  }

  const result = await client.images.generate({
    model: process.env.OPENAI_IMAGE_MODEL || "gpt-image-1",
    prompt: prompt.trim().slice(0, 4000),
    size: process.env.OPENAI_IMAGE_SIZE || "1024x1024",
  });

  const firstImage = result?.data?.[0];
  const base64 = firstImage?.b64_json || "";

  if (!base64) {
    throw buildImageGenerationError(
      "Image generation failed",
      "openai",
      "No image data returned by OpenAI"
    );
  }

  return {
    provider: "openai",
    imageDataUrl: `data:image/png;base64,${base64}`,
  };
}

async function generateImageWithOpenRouter(prompt) {
  if (!process.env.OPENROUTER_API_KEY) {
    throw buildImageGenerationError(
      "OPENROUTER_API_KEY is missing in backend .env",
      "openrouter"
    );
  }

  const response = await fetch("https://openrouter.ai/api/v1/chat/completions", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${process.env.OPENROUTER_API_KEY}`,
      "Content-Type": "application/json",
      "HTTP-Referer": "http://localhost:5000",
      "X-Title": "FLOWGNIMAG",
    },
    body: JSON.stringify({
      model:
        process.env.IMAGE_MODEL || "google/gemini-3.1-flash-image-preview",
      modalities: ["text", "image"],
      max_tokens: 512,
      messages: [
        {
          role: "user",
          content: `Generate one image only. ${prompt.trim().slice(0, 500)}`,
        },
      ],
    }),
  });

  const data = await response.json();

  if (!response.ok) {
    const providerMessage =
      data?.error?.message || data?.error || JSON.stringify(data);

    if (/insufficient credits/i.test(providerMessage)) {
      throw buildImageGenerationError(
        "OpenRouter image generation is unavailable for this key",
        "openrouter",
        "This OpenRouter account has insufficient credits. Add credits, use a billed key from the correct org, or set OPENAI_API_KEY in backend/.env to use OpenAI image generation instead."
      );
    }

    throw buildImageGenerationError(
      "Failed to generate image",
      "openrouter",
      providerMessage
    );
  }

  const message = data?.choices?.[0]?.message;
  const images = message?.images || [];
  const firstImage = images[0] || null;

  let { imageUrl, imageDataUrl } = extractImageReference(firstImage);

  if (!imageDataUrl && typeof message?.content === "string") {
    const match = message.content.match(
      /data:image\/[a-zA-Z]+;base64,[A-Za-z0-9+/=]+/
    );
    if (match) {
      imageDataUrl = match[0];
    }
  }

  if (!imageDataUrl && imageUrl) {
    const imageResponse = await fetch(imageUrl);
    if (!imageResponse.ok) {
      throw buildImageGenerationError(
        "Image preview fetch failed",
        "openrouter",
        "Could not download generated image from provider URL"
      );
    }

    const contentType = imageResponse.headers.get("content-type") || "image/png";
    const arrayBuffer = await imageResponse.arrayBuffer();
    const base64 = Buffer.from(arrayBuffer).toString("base64");
    imageDataUrl = `data:${contentType};base64,${base64}`;
  }

  if (!imageDataUrl) {
    throw buildImageGenerationError(
      "Image generation failed",
      "openrouter",
      "No image data returned by provider"
    );
  }

  return {
    provider: "openrouter",
    imageDataUrl,
  };
}

async function generateBinaryWithHuggingFace(model, prompt, parameters = {}) {
  if (!process.env.HF_TOKEN) {
    throw buildImageGenerationError(
      "HF_TOKEN is missing in backend .env",
      "huggingface"
    );
  }

  if (!model || !model.trim()) {
    throw buildImageGenerationError(
      "Hugging Face model is missing",
      "huggingface"
    );
  }

  const response = await fetch(
    `https://router.huggingface.co/hf-inference/models/${encodeURIComponent(model.trim())}`,
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${process.env.HF_TOKEN}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        inputs: prompt.trim(),
        parameters,
      }),
    }
  );

  if (!response.ok) {
    const responseText = await response.text();
    throw buildImageGenerationError(
      "Hugging Face generation failed",
      "huggingface",
      responseText || `HTTP ${response.status}`
    );
  }

  const contentType = response.headers.get("content-type") || "";
  const arrayBuffer = await response.arrayBuffer();
  const base64 = Buffer.from(arrayBuffer).toString("base64");

  return { contentType, base64 };
}

async function generateImageWithHuggingFace(prompt) {
  const primaryModel =
    process.env.HF_IMAGE_MODEL || "black-forest-labs/FLUX.1-schnell";
  const fallbackModels = String(process.env.HF_IMAGE_FALLBACK_MODELS || "")
    .split(",")
    .map((item) => item.trim())
    .filter((item) => item.length > 0);
  const models = Array.from(new Set([primaryModel, ...fallbackModels]));

  const parameterProfiles = [
    { width: 1024, height: 1024, num_inference_steps: 4 },
    { width: 768, height: 768, num_inference_steps: 3 },
    { width: 512, height: 512, num_inference_steps: 2 },
  ];

  let lastError = null;
  for (const model of models) {
    for (const parameters of parameterProfiles) {
      try {
        const { contentType, base64 } = await generateBinaryWithHuggingFace(
          model,
          prompt,
          parameters
        );
        return {
          provider: "huggingface",
          imageDataUrl: `data:${contentType || "image/png"};base64,${base64}`,
        };
      } catch (error) {
        lastError = error;
        if (!isHuggingFaceOomError(error)) {
          throw error;
        }
      }
    }
  }

  throw (
    lastError ||
    buildImageGenerationError(
      "Hugging Face generation failed",
      "huggingface",
      "Unknown generation error"
    )
  );
}

async function generateImageWithPollinations(prompt) {
  const seed = Math.floor(Math.random() * 1_000_000_000);
  const width = Math.max(
    256,
    Math.min(1280, Number(process.env.FREE_IMAGE_WIDTH) || 1024)
  );
  const height = Math.max(
    256,
    Math.min(1280, Number(process.env.FREE_IMAGE_HEIGHT) || 1024)
  );
  const model = cleanText(process.env.POLLINATIONS_MODEL, 80) || "flux";
  const safePrompt = cleanText(prompt, 1000);
  const url =
    `https://image.pollinations.ai/prompt/${encodeURIComponent(safePrompt)}` +
    `?seed=${seed}&width=${width}&height=${height}&model=${encodeURIComponent(model)}&nologo=true`;

  const response = await fetch(url, {
    headers: {
      Accept: "image/*",
      "User-Agent": "FLOWGNIMAG/1.0",
    },
  });

  if (!response.ok) {
    const responseText = await response.text();
    throw buildImageGenerationError(
      "Pollinations image generation failed",
      "pollinations",
      responseText || `HTTP ${response.status}`
    );
  }

  const contentType = response.headers.get("content-type") || "image/png";
  const arrayBuffer = await response.arrayBuffer();
  const base64 = Buffer.from(arrayBuffer).toString("base64");
  if (!base64) {
    throw buildImageGenerationError(
      "Pollinations image generation failed",
      "pollinations",
      "No image bytes received"
    );
  }

  return {
    provider: "pollinations",
    imageDataUrl: `data:${contentType};base64,${base64}`,
  };
}

function generateLocalPlaceholderImage(prompt) {
  const title = cleanText(prompt, 120) || "FLOWGNIMAG";
  const safe = title
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
<defs>
<linearGradient id="g" x1="0" y1="0" x2="1" y2="1">
<stop offset="0%" stop-color="#0B1220"/>
<stop offset="100%" stop-color="#1D4ED8"/>
</linearGradient>
</defs>
<rect width="1024" height="1024" fill="url(#g)"/>
<circle cx="820" cy="180" r="140" fill="#67E8A833"/>
<circle cx="180" cy="840" r="180" fill="#F59E0B26"/>
<text x="80" y="140" fill="#E5E7EB" font-family="Arial, sans-serif" font-size="44" font-weight="700">FLOWGNIMAG</text>
<text x="80" y="220" fill="#BFDBFE" font-family="Arial, sans-serif" font-size="28">Local fallback image</text>
<foreignObject x="80" y="300" width="860" height="620">
<div xmlns="http://www.w3.org/1999/xhtml" style="color:#FFFFFF;font-family:Arial, sans-serif;font-size:32px;line-height:1.4;white-space:pre-wrap;">
${safe}
</div>
</foreignObject>
</svg>`;
  const base64 = Buffer.from(svg, "utf8").toString("base64");
  return {
    provider: "local_placeholder",
    imageDataUrl: `data:image/svg+xml;base64,${base64}`,
  };
}

async function generateVideoWithHuggingFace(prompt) {
  const model =
    process.env.HF_VIDEO_MODEL || "Wan-AI/Wan2.2-TI2V-5B";

  const { contentType, base64 } = await generateBinaryWithHuggingFace(
    model,
    prompt,
    {
      num_frames: 49,
      num_inference_steps: 30,
    }
  );

  return {
    provider: "huggingface",
    videoDataUrl: `data:${contentType || "video/mp4"};base64,${base64}`,
  };
}

app.get("/", (req, res) => {
  res.json({
    app: "FLOWGNIMAG API",
    status: "running",
    mode: "smart tool router",
  });
});

app.get("/health", (req, res) => {
  res.json({
    app: "FLOWGNIMAG API",
    status: "ok",
    uptimeSeconds: Math.round(process.uptime()),
    database: {
      connected: Boolean(db),
      path: DB_PATH,
      provider: "sqlite",
      mongodbConnected: Boolean(mongoDb),
      mongodbDatabase: mongoDb ? parseMongoDbName() : "",
    },
    providers: {
      openai: Boolean(process.env.OPENAI_API_KEY),
      openrouter: Boolean(process.env.OPENROUTER_API_KEY),
      huggingface: Boolean(process.env.HF_TOKEN),
      googleCalendarConfigured: isGoogleCalendarConfigured(),
      fcmConfigured: isFcmConfigured(),
    },
  });
});

app.get("/metrics", (req, res) => {
  res.json({
    ...metrics,
    uptimeSeconds: Math.round(process.uptime()),
    activeRateLimitBuckets: rateBuckets.size,
  });
});

app.get("/db/status", (req, res) => {
  const usingMongo = Boolean(MONGODB_URI.trim());
  const mirrorMode = MONGODB_RUNTIME_MODE === "mirror";
  const activeProvider =
    usingMongo && mirrorMode && Boolean(mongoDb) ? "mongodb_mirror" : "sqlite";
  return res.json({
    success: true,
    runtimeMode: MONGODB_RUNTIME_MODE,
    sqlite: {
      enabled: true,
      connected: Boolean(db),
      path: DB_PATH,
    },
    mongodb: {
      configured: usingMongo,
      connected: Boolean(mongoDb),
      database: usingMongo ? parseMongoDbName() : "",
      mirrorBootstrapComplete: mongoMirrorBootstrapComplete,
      mirrorSyncInProgress: mongoMirrorSyncInProgress,
      mirrorLastSyncAt: mongoMirrorLastSyncAt || null,
    },
    activeProvider,
    note:
      activeProvider === "mongodb_mirror"
        ? "Mirror mode active: reads run via SQLite compatibility layer, while data is auto-synced to MongoDB Atlas."
        : "Backend is currently SQLite-driven. Set MONGODB_RUNTIME_MODE=mirror with valid MongoDB credentials to enable Atlas mirror persistence.",
  });
});

app.get("/db/diagnostics", async (req, res) => {
  const diagnostics = {
    success: true,
    generatedAt: nowIso(),
    runtimeMode: MONGODB_RUNTIME_MODE,
    sqlite: {
      connected: Boolean(db),
      path: DB_PATH,
    },
    mongodb: {
      configured: Boolean(MONGODB_URI.trim()),
      connected: Boolean(mongoDb),
      database: MONGODB_URI.trim() ? parseMongoDbName() : "",
      uriPreview: redactMongoUri(MONGODB_URI),
      host: parseMongoHostFromUri(MONGODB_URI),
      mirrorBootstrapComplete: mongoMirrorBootstrapComplete,
      mirrorLastSyncAt: mongoMirrorLastSyncAt || null,
    },
    checks: [],
    suggestions: [],
  };

  if (!MONGODB_URI.trim()) {
    diagnostics.success = false;
    diagnostics.checks.push({
      name: "env.missing_mongodb_uri",
      ok: false,
      details: "MONGODB_URI is empty.",
    });
    diagnostics.suggestions.push(
      "Set MONGODB_URI in backend/.env and restart backend."
    );
    return res.status(400).json(diagnostics);
  }

  const host = parseMongoHostFromUri(MONGODB_URI);
  if (host) {
    try {
      const srv = await dns.resolveSrv(`_mongodb._tcp.${host}`);
      diagnostics.checks.push({
        name: "dns.srv_lookup",
        ok: Array.isArray(srv) && srv.length > 0,
        details: `Found ${srv.length} SRV records`,
      });
    } catch (error) {
      diagnostics.checks.push({
        name: "dns.srv_lookup",
        ok: false,
        details: error?.message || "SRV lookup failed",
      });
      diagnostics.suggestions.push(
        "Internet/DNS issue ho sakta hai. Network check karo and try again."
      );
    }
  }

  try {
    if (mongoDb) {
      await mongoDb.command({ ping: 1 });
      diagnostics.checks.push({
        name: "mongodb.ping_existing_client",
        ok: true,
        details: "Existing Mongo connection is healthy.",
      });
      return res.json(diagnostics);
    }

    const probeClient = new MongoClient(MONGODB_URI, {
      serverSelectionTimeoutMS: 12_000,
    });
    await probeClient.connect();
    await probeClient.db(parseMongoDbName()).command({ ping: 1 });
    await probeClient.close();
    diagnostics.checks.push({
      name: "mongodb.probe_connection",
      ok: true,
      details: "Successfully connected and pinged Atlas.",
    });
    return res.json(diagnostics);
  } catch (error) {
    diagnostics.success = false;
    diagnostics.checks.push({
      name: "mongodb.probe_connection",
      ok: false,
      details: error?.message || "Mongo connection failed",
      errorName: error?.name || "",
      errorCode: error?.code || "",
    });
    diagnostics.suggestions.push(
      "Atlas Network Access me current IP allow karo (temporary 0.0.0.0/0 for testing)."
    );
    diagnostics.suggestions.push(
      "Atlas DB user/password verify karo and URI credentials recheck karo."
    );
    diagnostics.suggestions.push(
      "Cluster paused nahi hona chahiye; Atlas cluster status check karo."
    );
    return res.status(500).json(diagnostics);
  }
});

app.get("/project/status", (req, res) => {
  return res.json({
    success: true,
    app: "FLOWGNIMAG",
    ...buildProjectStatusReport(),
  });
});

app.get("/project/synopsis-alignment", (req, res) => {
  return res.json({
    success: true,
    app: "FLOWGNIMAG",
    ...buildSynopsisAlignmentReport(),
  });
});

app.post("/auth/signup", async (req, res) => {
  try {
    const name = cleanText(req.body?.name, 80);
    const email = validEmail(req.body?.email);
    const password = String(req.body?.password || "");

    if (!name || !email || password.length < 6) {
      return res.status(400).json({
        error: "Invalid signup payload",
        details: "name, valid email, and password(min 6 chars) are required.",
      });
    }

    const exists = db
      .prepare("SELECT id FROM users WHERE email = ?")
      .get(email);
    if (exists) {
      return res.status(409).json({ error: "Email already registered" });
    }

    const hash = await bcrypt.hash(password, 10);
    const insert = db
      .prepare("INSERT INTO users (name, email, password_hash) VALUES (?, ?, ?)")
      .run(name, email, hash);

    const user = db
      .prepare("SELECT id, name, email, created_at FROM users WHERE id = ?")
      .get(insert.lastInsertRowid);
    const session = issueAuthSession(user, req);

    trackPulseIQ("user_registered", String(user.id), {
      email: user.email,
      auth_method: "email_password",
    });
    trackPulseIQ("signup_success", String(user.id), {
      email: user.email,
      auth_method: "email_password",
    });

    return res.status(201).json({
      success: true,
      token: session.token,
      refreshToken: session.refreshToken,
      accessTokenExpiresAt: session.accessTokenExpiresAt,
      refreshTokenExpiresAt: session.refreshTokenExpiresAt,
      user: {
        id: String(user.id),
        name: user.name,
        email: user.email,
        createdAt: user.created_at,
      },
    });
  } catch (error) {
    return res.status(500).json({
      error: "Signup failed",
      details: error?.message || "Unknown error",
    });
  }
});

app.post("/auth/login", async (req, res) => {
  try {
    const email = validEmail(req.body?.email);
    const password = String(req.body?.password || "");

    if (!email || !password) {
      return res.status(400).json({
        error: "Invalid login payload",
        details: "email and password are required.",
      });
    }

    const user = db
      .prepare("SELECT id, name, email, password_hash, created_at FROM users WHERE email = ?")
      .get(email);

    if (!user) {
      return res.status(401).json({ error: "Invalid credentials" });
    }

    const ok = await bcrypt.compare(password, user.password_hash);
    if (!ok) {
      return res.status(401).json({ error: "Invalid credentials" });
    }

    const session = issueAuthSession(user, req);
    trackPulseIQ("login_success", String(user.id), {
      email: user.email,
      auth_method: "email_password",
    });
    return res.json({
      success: true,
      token: session.token,
      refreshToken: session.refreshToken,
      accessTokenExpiresAt: session.accessTokenExpiresAt,
      refreshTokenExpiresAt: session.refreshTokenExpiresAt,
      user: {
        id: String(user.id),
        name: user.name,
        email: user.email,
        createdAt: user.created_at,
      },
    });
  } catch (error) {
    return res.status(500).json({
      error: "Login failed",
      details: error?.message || "Unknown error",
    });
  }
});

app.get("/auth/me", requireAuth, (req, res) => {
  const user = db
    .prepare("SELECT id, name, email, created_at FROM users WHERE id = ?")
    .get(req.auth.userId);

  if (!user) {
    return res.status(404).json({ error: "User not found" });
  }

  return res.json({
    success: true,
    user: {
      id: String(user.id),
      name: user.name,
      email: user.email,
      createdAt: user.created_at,
    },
  });
});

app.get("/assistant/briefing", requireAuth, async (req, res) => {
  try {
    const userId = req.auth.userId;

    const openTasks = db
      .prepare("SELECT id, title, priority, updated_at FROM tasks WHERE user_id = ? AND done = 0 ORDER BY updated_at DESC LIMIT 5")
      .all(userId)
      .map((row) => ({
        id: String(row.id),
        title: row.title,
        priority: row.priority,
        updatedAt: row.updated_at,
      }));
    const doneToday = db
      .prepare(
        "SELECT COUNT(*) AS count FROM tasks WHERE user_id = ? AND done = 1 AND date(updated_at) = date('now')"
      )
      .get(userId)?.count || 0;
    const notesCount = db
      .prepare("SELECT COUNT(*) AS count FROM notes WHERE user_id = ?")
      .get(userId)?.count || 0;
    const memoriesCount = db
      .prepare("SELECT COUNT(*) AS count FROM user_memories WHERE user_id = ?")
      .get(userId)?.count || 0;

    let upcomingEvents = [];
    try {
      const events = await listGoogleCalendarEvents(userId, { maxResults: 3 });
      upcomingEvents = (Array.isArray(events) ? events : [])
        .slice(0, 3)
        .map((item) => ({
          id: cleanText(item.id, 200),
          summary: cleanText(item.summary, 120) || "Upcoming event",
          start: cleanText(item.start, 80),
        }));
    } catch {
      upcomingEvents = [];
    }

    const taskSummary =
      openTasks.length === 0
        ? "No open tasks. Great momentum."
        : `${openTasks.length} open task(s), top: ${openTasks[0].title}`;
    const eventSummary =
      upcomingEvents.length === 0
        ? "No upcoming connected Google events."
        : `${upcomingEvents.length} upcoming event(s), next: ${upcomingEvents[0].summary}`;

    const summary = [
      "Daily briefing ready.",
      taskSummary,
      `Completed today: ${doneToday}.`,
      `Notes stored: ${notesCount}. Memories: ${memoriesCount}.`,
      eventSummary,
    ].join(" ");

    return res.json({
      success: true,
      generatedAt: nowIso(),
      summary,
      tasks: {
        openCount: openTasks.length,
        doneToday: Number(doneToday),
        topOpen: openTasks,
      },
      notes: {
        totalCount: Number(notesCount),
      },
      memories: {
        totalCount: Number(memoriesCount),
      },
      calendar: {
        connected: Boolean(getGoogleTokenRow(userId)),
        upcoming: upcomingEvents,
      },
    });
  } catch (error) {
    return res.status(500).json({
      error: "Failed to prepare daily briefing",
      details: error?.message || "Unknown error",
    });
  }
});

app.post("/auth/refresh", (req, res) => {
  const refreshToken = cleanText(req.body?.refreshToken, 1200);
  if (!refreshToken) {
    return res.status(400).json({ error: "refreshToken is required" });
  }

  const rotated = rotateRefreshSession(refreshToken, req);
  if (!rotated.ok) {
    return res
      .status(rotated.status || 401)
      .json({ error: rotated.error || "Refresh failed" });
  }

  return res.json({
    success: true,
    token: rotated.session.token,
    refreshToken: rotated.session.refreshToken,
    accessTokenExpiresAt: rotated.session.accessTokenExpiresAt,
    refreshTokenExpiresAt: rotated.session.refreshTokenExpiresAt,
    user: {
      id: String(rotated.user.id),
      name: rotated.user.name,
      email: rotated.user.email,
      createdAt: rotated.user.created_at,
    },
  });
});

app.post("/auth/logout", requireAuth, (req, res) => {
  const refreshToken = cleanText(req.body?.refreshToken, 1200);
  const allDevices = req.body?.allDevices === true;

  trackPulseIQ("logout", String(req.auth.userId), {
    scope: allDevices ? "all_devices" : refreshToken ? "current_device" : "unknown",
  });

  if (allDevices) {
    revokeUserRefreshTokens(req.auth.userId);
    return res.json({ success: true, revoked: "all" });
  }

  if (refreshToken) {
    revokeRefreshToken(refreshToken);
    return res.json({ success: true, revoked: "current" });
  }

  return res.json({ success: true, revoked: "none" });
});

app.get("/integrations/google/url", requireAuth, (req, res) => {
  try {
    const result = buildGoogleCalendarAuthUrl(req.auth.userId);
    if (!result.ok) {
      return res.status(500).json({
        error: "Google Calendar integration unavailable",
        details: result.error,
      });
    }
    return res.json({
      success: true,
      provider: "google_calendar",
      url: result.url,
      expiresAt: result.expiresAt,
    });
  } catch (error) {
    return res.status(500).json({
      error: "Failed to generate Google auth URL",
      details: error?.message || "Unknown error",
    });
  }
});

app.get("/integrations/google/callback", async (req, res) => {
  try {
    if (!isGoogleCalendarConfigured()) {
      return res.status(500).send("Google Calendar integration is not configured.");
    }

    const code = cleanText(req.query?.code, 4000);
    const state = cleanText(req.query?.state, 200);
    const oauthError = cleanText(req.query?.error, 300);

    if (oauthError) {
      return res.status(400).send(`Google OAuth failed: ${oauthError}`);
    }
    if (!code || !state) {
      return res.status(400).send("Missing OAuth code/state.");
    }

    cleanupExpiredGoogleOAuthStates();

    const stateRow = db
      .prepare(
        `SELECT id, user_id, used, expires_at
         FROM google_oauth_states
         WHERE state = ?`
      )
      .get(state);

    if (!stateRow || stateRow.used === 1 || Date.parse(stateRow.expires_at) < Date.now()) {
      return res.status(400).send("Invalid or expired OAuth state.");
    }

    db.prepare("UPDATE google_oauth_states SET used = 1 WHERE id = ?").run(stateRow.id);
    const tokenData = await exchangeGoogleAuthCode(code);
    saveGoogleTokens(stateRow.user_id, tokenData);

    if (GOOGLE_OAUTH_SUCCESS_REDIRECT.trim()) {
      const redirectUrl = new URL(GOOGLE_OAUTH_SUCCESS_REDIRECT);
      redirectUrl.searchParams.set("status", "success");
      return res.redirect(302, redirectUrl.toString());
    }

    return res.status(200).send("Google Calendar connected successfully. You can close this tab.");
  } catch (error) {
    return res.status(500).send(
      `Google callback failed: ${error?.message || "Unknown error"}`
    );
  }
});

app.get("/integrations/google/status", requireAuth, (req, res) => {
  const tokenRow = getGoogleTokenRow(req.auth.userId);
  return res.json({
    success: true,
    provider: "google_calendar",
    configured: isGoogleCalendarConfigured(),
    connected: Boolean(tokenRow),
    expiresAt: tokenRow?.expiry_date || "",
    scope: tokenRow?.scope || "",
    updatedAt: tokenRow?.updated_at || "",
    userinfoEndpoint: GOOGLE_OAUTH_USERINFO_URL,
  });
});

app.get("/integrations/google/profile", requireAuth, async (req, res) => {
  try {
    const profile = await getGoogleUserProfile(req.auth.userId);
    return res.json({
      success: true,
      profile,
    });
  } catch (error) {
    return res.status(500).json({
      error: "Failed to fetch Google profile",
      details: error?.message || "Unknown error",
    });
  }
});

app.get("/notifications/status", requireAuth, (req, res) => {
  try {
    const devices = db
      .prepare(
        `SELECT platform, updated_at
         FROM push_devices
         WHERE user_id = ?
         ORDER BY updated_at DESC`
      )
      .all(req.auth.userId);

    const firebaseFiles = detectFirebaseConfigFiles();
    const missingRequirements = [];
    if (!FIREBASE_PROJECT_ID.trim()) {
      missingRequirements.push("Missing FIREBASE_PROJECT_ID in backend .env");
    }
    if (!FIREBASE_CLIENT_EMAIL.trim()) {
      missingRequirements.push("Missing FIREBASE_CLIENT_EMAIL in backend .env");
    }
    if (!FIREBASE_PRIVATE_KEY.trim()) {
      missingRequirements.push("Missing FIREBASE_PRIVATE_KEY in backend .env");
    }
    if (!firebaseFiles.androidGoogleServicesPresent) {
      missingRequirements.push(
        "Missing frontend/flutter_app/android/app/google-services.json"
      );
    }
    if (!firebaseFiles.iosGoogleServiceInfoPresent) {
      missingRequirements.push(
        "Missing frontend/flutter_app/ios/Runner/GoogleService-Info.plist"
      );
    }

    return res.json({
      success: true,
      fcmConfigured: isFcmConfigured(),
      firebaseAdminReady: Boolean(firebaseMessaging),
      firebaseFiles,
      readyForLivePush:
        isFcmConfigured() &&
        firebaseFiles.androidGoogleServicesPresent &&
        firebaseFiles.iosGoogleServiceInfoPresent,
      missingRequirements,
      deviceCount: devices.length,
      devices: devices.map((item) => ({
        platform: cleanText(item.platform, 40) || "unknown",
        updatedAt: item.updated_at || "",
      })),
    });
  } catch (error) {
    return res.status(500).json({
      error: "Failed to fetch notification status",
      details: error?.message || "Unknown error",
    });
  }
});

app.get("/notifications/doctor", requireAuth, (req, res) => {
  try {
    const report = buildPushDoctorReport(req.auth.userId);
    return res.json({
      success: true,
      ...report,
    });
  } catch (error) {
    return res.status(500).json({
      error: "Failed to run push diagnostics",
      details: error?.message || "Unknown error",
    });
  }
});

app.post("/notifications/self-test", requireAuth, async (req, res) => {
  try {
    const report = buildPushDoctorReport(req.auth.userId);
    if (!report.ready) {
      return res.status(400).json({
        success: false,
        error: "Push pipeline is not ready",
        ...report,
      });
    }

    const title = cleanText(req.body?.title, 120) || "FLOWGNIMAG Self-Test";
    const body =
      cleanText(req.body?.body, 240) || "Push diagnostics passed and test sent.";
    const result = await sendFcmToUserDevices(req.auth.userId, {
      type: "self_test",
      title,
      body,
    });

    return res.json({
      success: true,
      ...report,
      sent: result.sent,
      invalid: result.invalid,
    });
  } catch (error) {
    return res.status(500).json({
      error: "Failed to run push self-test",
      details: error?.message || "Unknown error",
    });
  }
});

app.post("/notifications/register", requireAuth, (req, res) => {
  try {
    const token = cleanText(req.body?.token, 800);
    const platform = cleanText(req.body?.platform, 40) || "unknown";
    if (!token) {
      return res.status(400).json({
        error: "Invalid push token",
      });
    }

    const now = nowIso();
    const existing = db
      .prepare("SELECT id FROM push_devices WHERE user_id = ? AND token = ?")
      .get(req.auth.userId, token);

    if (existing) {
      db.prepare(
        "UPDATE push_devices SET platform = ?, updated_at = ? WHERE id = ?"
      ).run(platform, now, existing.id);
    } else {
      db.prepare(
        `INSERT INTO push_devices (user_id, token, platform, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?)`
      ).run(req.auth.userId, token, platform, now, now);
    }

    return res.json({
      success: true,
      registered: true,
    });
  } catch (error) {
    return res.status(500).json({
      error: "Failed to register push token",
      details: error?.message || "Unknown error",
    });
  }
});

app.post("/notifications/unregister", requireAuth, (req, res) => {
  try {
    const token = cleanText(req.body?.token, 800);
    if (!token) {
      return res.status(400).json({
        error: "Invalid push token",
      });
    }
    const result = db
      .prepare("DELETE FROM push_devices WHERE user_id = ? AND token = ?")
      .run(req.auth.userId, token);
    return res.json({
      success: true,
      removed: result.changes > 0,
    });
  } catch (error) {
    return res.status(500).json({
      error: "Failed to unregister push token",
      details: error?.message || "Unknown error",
    });
  }
});

app.post("/notifications/test", requireAuth, async (req, res) => {
  try {
    if (!initializeFirebaseAdmin()) {
      return res.status(500).json({
        error: "FCM is not configured on backend",
      });
    }

    const title = cleanText(req.body?.title, 120) || "FLOWGNIMAG Test";
    const body = cleanText(req.body?.body, 240) || "Test push notification";
    const result = await sendFcmToUserDevices(req.auth.userId, {
      type: "test",
      title,
      body,
    });
    return res.json({
      success: true,
      ...result,
    });
  } catch (error) {
    return res.status(500).json({
      error: "Failed to send test push",
      details: error?.message || "Unknown error",
    });
  }
});

app.post("/integrations/google/disconnect", requireAuth, (req, res) => {
  const result = db
    .prepare("DELETE FROM google_calendar_tokens WHERE user_id = ?")
    .run(req.auth.userId);
  return res.json({
    success: true,
    disconnected: result.changes > 0,
  });
});

app.get("/integrations/google/events", requireAuth, async (req, res) => {
  try {
    const events = await listGoogleCalendarEvents(req.auth.userId, {
      timeMin: cleanText(req.query?.timeMin, 80),
      timeMax: cleanText(req.query?.timeMax, 80),
      maxResults: Number(req.query?.maxResults || 10),
    });
    return res.json({
      success: true,
      events,
    });
  } catch (error) {
    return res.status(500).json({
      error: "Failed to fetch Google Calendar events",
      details: error?.message || "Unknown error",
    });
  }
});

app.post("/integrations/google/events", requireAuth, async (req, res) => {
  try {
    const title = cleanText(req.body?.title, 200);
    const startIso = cleanText(req.body?.startIso, 80);
    const endIso = cleanText(req.body?.endIso, 80);
    if (!title || !startIso || !endIso) {
      return res.status(400).json({
        error: "Invalid event payload",
        details: "title, startIso, endIso are required.",
      });
    }

    const event = await createGoogleCalendarEvent(req.auth.userId, {
      title,
      startIso,
      endIso,
    });
    return res.status(201).json({
      success: true,
      event,
    });
  } catch (error) {
    return res.status(500).json({
      error: "Failed to create Google Calendar event",
      details: error?.message || "Unknown error",
    });
  }
});

app.get("/integrations/google/gmail/messages", requireAuth, async (req, res) => {
  try {
    const messages = await listGmailMessages(req.auth.userId, {
      maxResults: Number(req.query?.maxResults || 10),
    });
    return res.json({
      success: true,
      messages,
    });
  } catch (error) {
    return res.status(500).json({
      error: "Failed to fetch Gmail messages",
      details: error?.message || "Unknown error",
    });
  }
});

app.post("/integrations/google/gmail/send", requireAuth, async (req, res) => {
  try {
    const to = cleanText(req.body?.to, 320);
    const subject = cleanText(req.body?.subject, 300);
    const bodyText = cleanText(req.body?.body, 20000);
    if (!to || !subject || !bodyText) {
      return res.status(400).json({
        error: "Invalid email payload",
        details: "to, subject, body are required.",
      });
    }

    const sent = await sendGmailMessage(req.auth.userId, {
      to,
      subject,
      bodyText,
    });

    return res.status(201).json({
      success: true,
      message: sent,
    });
  } catch (error) {
    return res.status(500).json({
      error: "Failed to send Gmail message",
      details: error?.message || "Unknown error",
    });
  }
});

app.get("/integrations/google/contacts", requireAuth, async (req, res) => {
  try {
    const contacts = await listGoogleContacts(req.auth.userId, {
      maxResults: Number(req.query?.maxResults || 20),
    });
    return res.json({
      success: true,
      contacts,
    });
  } catch (error) {
    return res.status(500).json({
      error: "Failed to fetch Google contacts",
      details: error?.message || "Unknown error",
    });
  }
});

app.patch("/integrations/google/events/:id", requireAuth, async (req, res) => {
  try {
    const eventId = cleanText(req.params?.id, 400);
    const title = cleanText(req.body?.title, 200);
    const startIso = cleanText(req.body?.startIso, 80);
    const endIso = cleanText(req.body?.endIso, 80);
    if (!eventId || !title || !startIso || !endIso) {
      return res.status(400).json({
        error: "Invalid event update payload",
        details: "id, title, startIso, endIso are required.",
      });
    }

    const event = await updateGoogleCalendarEvent(req.auth.userId, eventId, {
      title,
      startIso,
      endIso,
    });
    return res.json({
      success: true,
      event,
    });
  } catch (error) {
    return res.status(500).json({
      error: "Failed to update Google Calendar event",
      details: error?.message || "Unknown error",
    });
  }
});

app.delete("/integrations/google/events/:id", requireAuth, async (req, res) => {
  try {
    const eventId = cleanText(req.params?.id, 400);
    if (!eventId) {
      return res.status(400).json({
        error: "Invalid event id",
      });
    }

    await deleteGoogleCalendarEvent(req.auth.userId, eventId);
    return res.json({
      success: true,
      deleted: true,
    });
  } catch (error) {
    return res.status(500).json({
      error: "Failed to delete Google Calendar event",
      details: error?.message || "Unknown error",
    });
  }
});

app.get("/sync/bootstrap", requireAuth, (req, res) => {
  const userId = req.auth.userId;

  const sessions = db
    .prepare(
      `SELECT id, title, is_pinned, created_at, updated_at
       FROM chat_sessions
       WHERE user_id = ?
       ORDER BY is_pinned DESC, updated_at DESC`
    )
    .all(userId)
    .map(mapSessionRow);

  const notes = db
    .prepare(
      "SELECT id, text, created_at, updated_at FROM notes WHERE user_id = ? ORDER BY created_at DESC"
    )
    .all(userId)
    .map((row) => ({
      id: String(row.id),
      text: row.text,
      createdAt: row.created_at,
      updatedAt: row.updated_at,
    }));

  const tasks = db
    .prepare(
      "SELECT id, title, done, priority, created_at, updated_at FROM tasks WHERE user_id = ? ORDER BY created_at DESC"
    )
    .all(userId)
    .map((row) => ({
      id: String(row.id),
      title: row.title,
      done: row.done === 1,
      priority: row.priority,
      createdAt: row.created_at,
      updatedAt: row.updated_at,
    }));

  const memories = db
    .prepare(
      "SELECT id, memory_text, created_at, updated_at FROM user_memories WHERE user_id = ? ORDER BY updated_at DESC"
    )
    .all(userId)
    .map(mapMemoryRow);

  const messages = db
    .prepare(
      `SELECT m.*
       FROM chat_messages m
       JOIN chat_sessions s ON s.id = m.session_id
       WHERE s.user_id = ?
       ORDER BY m.created_at ASC`
    )
    .all(userId)
    .map((row) => ({
      ...mapMessageRow(row),
      sessionId: String(row.session_id),
    }));

  return res.json({
    success: true,
    sessions,
    messages,
    notes,
    tasks,
    memories,
  });
});

app.post("/sync/import", requireAuth, (req, res) => {
  try {
    const userId = req.auth.userId;
    const sessions = Array.isArray(req.body?.sessions) ? req.body.sessions : [];
    const messages = Array.isArray(req.body?.messages) ? req.body.messages : [];
    const notes = Array.isArray(req.body?.notes) ? req.body.notes : [];
    const tasks = Array.isArray(req.body?.tasks) ? req.body.tasks : [];
    const hasMemoriesField = Array.isArray(req.body?.memories);
    const memories = hasMemoriesField ? req.body.memories : [];

    if (
      sessions.length > 200 ||
      messages.length > 10000 ||
      notes.length > 5000 ||
      tasks.length > 5000 ||
      memories.length > 5000
    ) {
      return res.status(400).json({
        error: "Import payload is too large",
      });
    }

    const userSessionRows = db
      .prepare("SELECT id FROM chat_sessions WHERE user_id = ?")
      .all(userId)
      .map((row) => row.id);

    const deleteAll = db.transaction(() => {
      for (const sid of userSessionRows) {
        db.prepare("DELETE FROM chat_sessions WHERE id = ?").run(sid);
      }
      db.prepare("DELETE FROM notes WHERE user_id = ?").run(userId);
      db.prepare("DELETE FROM tasks WHERE user_id = ?").run(userId);
      if (hasMemoriesField) {
        db.prepare("DELETE FROM user_memories WHERE user_id = ?").run(userId);
      }
    });
    deleteAll();

    const sessionIdMap = new Map();

    const insertSession = db.prepare(
      "INSERT INTO chat_sessions (user_id, title, is_pinned, created_at, updated_at) VALUES (?, ?, ?, ?, ?)"
    );
    const insertMessage = db.prepare(
      `INSERT INTO chat_messages
       (session_id, role, text, type, code, image_prompt, video_prompt, action, url, info, suggestions_json, starred, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
    );
    const insertNote = db.prepare(
      "INSERT INTO notes (user_id, text, created_at, updated_at) VALUES (?, ?, ?, ?)"
    );
    const insertTask = db.prepare(
      "INSERT INTO tasks (user_id, title, done, priority, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)"
    );
    const insertMemory = db.prepare(
      "INSERT INTO user_memories (user_id, memory_key, memory_text, created_at, updated_at) VALUES (?, ?, ?, ?, ?)"
    );

    for (const session of sessions) {
      const title = cleanText(session?.title, 120) || "New Chat";
      const isPinned = session?.isPinned === true ? 1 : 0;
      const createdAt = cleanText(session?.createdAt, 40) || nowIso();
      const updatedAt = cleanText(session?.updatedAt, 40) || nowIso();
      const result = insertSession.run(userId, title, isPinned, createdAt, updatedAt);
      sessionIdMap.set(String(session?.id ?? result.lastInsertRowid), Number(result.lastInsertRowid));
    }

    for (const message of messages) {
      const incomingSessionId = String(message?.sessionId ?? "");
      const mappedSessionId = sessionIdMap.get(incomingSessionId);
      if (!mappedSessionId) continue;

      const role = message?.role === "user" ? "user" : "ai";
      const text = cleanText(message?.text, 12000);
      if (!text) continue;

      insertMessage.run(
        mappedSessionId,
        role,
        text,
        cleanText(message?.type, 40) || "chat",
        cleanText(message?.code, 120000),
        cleanText(message?.imagePrompt, 4000),
        cleanText(message?.videoPrompt, 4000),
        cleanText(message?.action, 80),
        cleanText(message?.url, 2000),
        cleanText(message?.info, 4000),
        serializeSuggestions(message?.suggestions),
        message?.starred === true ? 1 : 0,
        cleanText(message?.time, 40) || nowIso()
      );
    }

    for (const note of notes) {
      const text = cleanText(note?.text, 12000);
      if (!text) continue;
      const createdAt = cleanText(note?.createdAt, 40) || nowIso();
      const updatedAt = cleanText(note?.updatedAt, 40) || createdAt;
      insertNote.run(userId, text, createdAt, updatedAt);
    }

    for (const task of tasks) {
      const title = cleanText(task?.title, 600);
      if (!title) continue;
      const done = task?.done === true ? 1 : 0;
      const priority = cleanText(task?.priority, 20) || "Medium";
      const createdAt = cleanText(task?.createdAt, 40) || nowIso();
      const updatedAt = cleanText(task?.updatedAt, 40) || createdAt;
      insertTask.run(userId, title, done, priority, createdAt, updatedAt);
    }

    for (const memory of memories) {
      const text = cleanText(memory?.text, 1200);
      if (!text) continue;
      const memoryKey = normalizeMemoryKey(text);
      if (!memoryKey) continue;
      const createdAt = cleanText(memory?.createdAt, 40) || nowIso();
      const updatedAt = cleanText(memory?.updatedAt, 40) || createdAt;
      try {
        insertMemory.run(userId, memoryKey, text, createdAt, updatedAt);
      } catch {
        db.prepare(
          "UPDATE user_memories SET memory_text = ?, updated_at = ? WHERE user_id = ? AND memory_key = ?"
        ).run(text, updatedAt, userId, memoryKey);
      }
    }

    return res.json({ success: true });
  } catch (error) {
    return res.status(500).json({
      error: "Import failed",
      details: error?.message || "Unknown error",
    });
  }
});

app.get("/sessions", requireAuth, (req, res) => {
  const rows = db
    .prepare(
      `SELECT s.id, s.title, s.is_pinned, s.created_at, s.updated_at,
              COUNT(m.id) AS message_count
       FROM chat_sessions s
       LEFT JOIN chat_messages m ON m.session_id = s.id
       WHERE s.user_id = ?
       GROUP BY s.id
       ORDER BY s.is_pinned DESC, s.updated_at DESC`
    )
    .all(req.auth.userId);

  return res.json({
    success: true,
    sessions: rows.map((row) => ({
      ...mapSessionRow(row),
      messageCount: Number(row.message_count || 0),
    })),
  });
});

app.post("/sessions", requireAuth, (req, res) => {
  const title = cleanText(req.body?.title, 120) || "New Chat";
  const now = nowIso();

  const insert = db
    .prepare(
      "INSERT INTO chat_sessions (user_id, title, is_pinned, created_at, updated_at) VALUES (?, ?, 0, ?, ?)"
    )
    .run(req.auth.userId, title, now, now);

  const row = db
    .prepare("SELECT id, title, is_pinned, created_at, updated_at FROM chat_sessions WHERE id = ?")
    .get(insert.lastInsertRowid);

  return res.status(201).json({ success: true, session: mapSessionRow(row) });
});

app.patch("/sessions/:id", requireAuth, (req, res) => {
  const sessionId = Number(req.params.id);
  if (!Number.isFinite(sessionId)) {
    return res.status(400).json({ error: "Invalid session id" });
  }

  const current = db
    .prepare("SELECT id, user_id, title, is_pinned FROM chat_sessions WHERE id = ?")
    .get(sessionId);
  if (!current || current.user_id !== req.auth.userId) {
    return res.status(404).json({ error: "Session not found" });
  }

  const nextTitle = cleanText(req.body?.title, 120) || current.title;
  const nextPinned =
    typeof req.body?.isPinned === "boolean" ? (req.body.isPinned ? 1 : 0) : current.is_pinned;
  const now = nowIso();

  db.prepare(
    "UPDATE chat_sessions SET title = ?, is_pinned = ?, updated_at = ? WHERE id = ?"
  ).run(nextTitle, nextPinned, now, sessionId);

  const row = db
    .prepare("SELECT id, title, is_pinned, created_at, updated_at FROM chat_sessions WHERE id = ?")
    .get(sessionId);

  return res.json({ success: true, session: mapSessionRow(row) });
});

app.delete("/sessions/:id", requireAuth, (req, res) => {
  const sessionId = Number(req.params.id);
  if (!Number.isFinite(sessionId)) {
    return res.status(400).json({ error: "Invalid session id" });
  }

  const current = db
    .prepare("SELECT id, user_id FROM chat_sessions WHERE id = ?")
    .get(sessionId);
  if (!current || current.user_id !== req.auth.userId) {
    return res.status(404).json({ error: "Session not found" });
  }

  db.prepare("DELETE FROM chat_sessions WHERE id = ?").run(sessionId);
  return res.json({ success: true });
});

app.get("/sessions/:id/messages", requireAuth, (req, res) => {
  const sessionId = Number(req.params.id);
  if (!Number.isFinite(sessionId)) {
    return res.status(400).json({ error: "Invalid session id" });
  }

  const allowed = db
    .prepare("SELECT id FROM chat_sessions WHERE id = ? AND user_id = ?")
    .get(sessionId, req.auth.userId);
  if (!allowed) {
    return res.status(404).json({ error: "Session not found" });
  }

  const rows = db
    .prepare("SELECT * FROM chat_messages WHERE session_id = ? ORDER BY created_at ASC")
    .all(sessionId)
    .map(mapMessageRow);

  return res.json({ success: true, messages: rows });
});

app.post("/sessions/:id/messages", requireAuth, (req, res) => {
  const sessionId = Number(req.params.id);
  if (!Number.isFinite(sessionId)) {
    return res.status(400).json({ error: "Invalid session id" });
  }

  const allowed = db
    .prepare("SELECT id FROM chat_sessions WHERE id = ? AND user_id = ?")
    .get(sessionId, req.auth.userId);
  if (!allowed) {
    return res.status(404).json({ error: "Session not found" });
  }

  const role = req.body?.role === "user" ? "user" : "ai";
  const text = cleanText(req.body?.text, 12000);
  if (!text) {
    return res.status(400).json({ error: "Message text is required" });
  }

  const now = nowIso();
  const result = db
    .prepare(
      `INSERT INTO chat_messages
       (session_id, role, text, type, code, image_prompt, video_prompt, action, url, info, suggestions_json, starred, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
    )
    .run(
      sessionId,
      role,
      text,
      cleanText(req.body?.type, 40) || "chat",
      cleanText(req.body?.code, 120000),
      cleanText(req.body?.imagePrompt, 4000),
      cleanText(req.body?.videoPrompt, 4000),
      cleanText(req.body?.action, 80),
      cleanText(req.body?.url, 2000),
      cleanText(req.body?.info, 4000),
      serializeSuggestions(req.body?.suggestions),
      req.body?.starred === true ? 1 : 0,
      now
    );

  db.prepare("UPDATE chat_sessions SET updated_at = ? WHERE id = ?").run(now, sessionId);

  const row = db
    .prepare("SELECT * FROM chat_messages WHERE id = ?")
    .get(result.lastInsertRowid);
  return res.status(201).json({ success: true, message: mapMessageRow(row) });
});

app.patch("/messages/:id", requireAuth, (req, res) => {
  const messageId = Number(req.params.id);
  if (!Number.isFinite(messageId)) {
    return res.status(400).json({ error: "Invalid message id" });
  }

  const current = db
    .prepare(
      `SELECT m.id, m.session_id, m.starred
       FROM chat_messages m
       JOIN chat_sessions s ON s.id = m.session_id
       WHERE m.id = ? AND s.user_id = ?`
    )
    .get(messageId, req.auth.userId);

  if (!current) {
    return res.status(404).json({ error: "Message not found" });
  }

  const starred =
    typeof req.body?.starred === "boolean" ? (req.body.starred ? 1 : 0) : current.starred;

  db.prepare("UPDATE chat_messages SET starred = ? WHERE id = ?").run(starred, messageId);
  const row = db.prepare("SELECT * FROM chat_messages WHERE id = ?").get(messageId);
  return res.json({ success: true, message: mapMessageRow(row) });
});

app.delete("/messages/:id", requireAuth, (req, res) => {
  const messageId = Number(req.params.id);
  if (!Number.isFinite(messageId)) {
    return res.status(400).json({ error: "Invalid message id" });
  }

  const current = db
    .prepare(
      `SELECT m.id
       FROM chat_messages m
       JOIN chat_sessions s ON s.id = m.session_id
       WHERE m.id = ? AND s.user_id = ?`
    )
    .get(messageId, req.auth.userId);
  if (!current) {
    return res.status(404).json({ error: "Message not found" });
  }

  db.prepare("DELETE FROM chat_messages WHERE id = ?").run(messageId);
  return res.json({ success: true });
});

app.get("/notes", requireAuth, (req, res) => {
  const rows = db
    .prepare(
      "SELECT id, text, created_at, updated_at FROM notes WHERE user_id = ? ORDER BY created_at DESC"
    )
    .all(req.auth.userId);

  return res.json({
    success: true,
    notes: rows.map((row) => ({
      id: String(row.id),
      text: row.text,
      createdAt: row.created_at,
      updatedAt: row.updated_at,
    })),
  });
});

app.post("/notes", requireAuth, (req, res) => {
  const text = cleanText(req.body?.text, 12000);
  if (!text) {
    return res.status(400).json({ error: "Note text is required" });
  }
  const now = nowIso();
  const result = db
    .prepare(
      "INSERT INTO notes (user_id, text, created_at, updated_at) VALUES (?, ?, ?, ?)"
    )
    .run(req.auth.userId, text, now, now);

  const row = db
    .prepare("SELECT id, text, created_at, updated_at FROM notes WHERE id = ?")
    .get(result.lastInsertRowid);

  return res.status(201).json({
    success: true,
    note: {
      id: String(row.id),
      text: row.text,
      createdAt: row.created_at,
      updatedAt: row.updated_at,
    },
  });
});

app.patch("/notes/:id", requireAuth, (req, res) => {
  const noteId = Number(req.params.id);
  const text = cleanText(req.body?.text, 12000);
  if (!Number.isFinite(noteId) || !text) {
    return res.status(400).json({ error: "Invalid note update payload" });
  }
  const now = nowIso();
  const result = db
    .prepare(
      "UPDATE notes SET text = ?, updated_at = ? WHERE id = ? AND user_id = ?"
    )
    .run(text, now, noteId, req.auth.userId);

  if (result.changes === 0) {
    return res.status(404).json({ error: "Note not found" });
  }

  const row = db
    .prepare("SELECT id, text, created_at, updated_at FROM notes WHERE id = ?")
    .get(noteId);
  return res.json({
    success: true,
    note: {
      id: String(row.id),
      text: row.text,
      createdAt: row.created_at,
      updatedAt: row.updated_at,
    },
  });
});

app.delete("/notes/:id", requireAuth, (req, res) => {
  const noteId = Number(req.params.id);
  if (!Number.isFinite(noteId)) {
    return res.status(400).json({ error: "Invalid note id" });
  }
  const result = db
    .prepare("DELETE FROM notes WHERE id = ? AND user_id = ?")
    .run(noteId, req.auth.userId);
  if (result.changes === 0) {
    return res.status(404).json({ error: "Note not found" });
  }
  return res.json({ success: true });
});

app.get("/tasks", requireAuth, (req, res) => {
  const rows = db
    .prepare(
      "SELECT id, title, done, priority, created_at, updated_at FROM tasks WHERE user_id = ? ORDER BY created_at DESC"
    )
    .all(req.auth.userId);

  return res.json({
    success: true,
    tasks: rows.map((row) => ({
      id: String(row.id),
      title: row.title,
      done: row.done === 1,
      priority: row.priority,
      createdAt: row.created_at,
      updatedAt: row.updated_at,
    })),
  });
});

app.post("/tasks", requireAuth, (req, res) => {
  const title = cleanText(req.body?.title, 600);
  const priority = cleanText(req.body?.priority, 20) || "Medium";
  if (!title) {
    return res.status(400).json({ error: "Task title is required" });
  }

  const now = nowIso();
  const result = db
    .prepare(
      "INSERT INTO tasks (user_id, title, done, priority, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)"
    )
    .run(req.auth.userId, title, req.body?.done === true ? 1 : 0, priority, now, now);

  const row = db
    .prepare(
      "SELECT id, title, done, priority, created_at, updated_at FROM tasks WHERE id = ?"
    )
    .get(result.lastInsertRowid);

  return res.status(201).json({
    success: true,
    task: {
      id: String(row.id),
      title: row.title,
      done: row.done === 1,
      priority: row.priority,
      createdAt: row.created_at,
      updatedAt: row.updated_at,
    },
  });
});

app.patch("/tasks/:id", requireAuth, (req, res) => {
  const taskId = Number(req.params.id);
  if (!Number.isFinite(taskId)) {
    return res.status(400).json({ error: "Invalid task id" });
  }

  const current = db
    .prepare("SELECT id, title, done, priority FROM tasks WHERE id = ? AND user_id = ?")
    .get(taskId, req.auth.userId);
  if (!current) {
    return res.status(404).json({ error: "Task not found" });
  }

  const title = cleanText(req.body?.title, 600) || current.title;
  const done =
    typeof req.body?.done === "boolean" ? (req.body.done ? 1 : 0) : current.done;
  const priority = cleanText(req.body?.priority, 20) || current.priority;
  const now = nowIso();

  db.prepare(
    "UPDATE tasks SET title = ?, done = ?, priority = ?, updated_at = ? WHERE id = ? AND user_id = ?"
  ).run(title, done, priority, now, taskId, req.auth.userId);

  const row = db
    .prepare(
      "SELECT id, title, done, priority, created_at, updated_at FROM tasks WHERE id = ?"
    )
    .get(taskId);

  return res.json({
    success: true,
    task: {
      id: String(row.id),
      title: row.title,
      done: row.done === 1,
      priority: row.priority,
      createdAt: row.created_at,
      updatedAt: row.updated_at,
    },
  });
});

app.delete("/tasks/:id", requireAuth, (req, res) => {
  const taskId = Number(req.params.id);
  if (!Number.isFinite(taskId)) {
    return res.status(400).json({ error: "Invalid task id" });
  }
  const result = db
    .prepare("DELETE FROM tasks WHERE id = ? AND user_id = ?")
    .run(taskId, req.auth.userId);
  if (result.changes === 0) {
    return res.status(404).json({ error: "Task not found" });
  }
  return res.json({ success: true });
});

app.get("/memories", requireAuth, (req, res) => {
  const memories = getUserMemories(req.auth.userId, 200);
  return res.json({
    success: true,
    memories,
  });
});

app.post("/memories", requireAuth, (req, res) => {
  const text = cleanText(req.body?.text, 1200);
  if (!text) {
    return res.status(400).json({ error: "Memory text is required" });
  }

  const row = upsertUserMemory(req.auth.userId, text);
  if (!row) {
    return res.status(400).json({ error: "Invalid memory text" });
  }

  return res.status(201).json({
    success: true,
    memory: mapMemoryRow(row),
  });
});

app.delete("/memories", requireAuth, (req, res) => {
  const result = db
    .prepare("DELETE FROM user_memories WHERE user_id = ?")
    .run(req.auth.userId);
  return res.json({
    success: true,
    deleted: result.changes,
  });
});

app.delete("/memories/:id", requireAuth, (req, res) => {
  const memoryId = Number(req.params.id);
  if (!Number.isFinite(memoryId)) {
    return res.status(400).json({ error: "Invalid memory id" });
  }

  const result = db
    .prepare("DELETE FROM user_memories WHERE id = ? AND user_id = ?")
    .run(memoryId, req.auth.userId);
  if (result.changes === 0) {
    return res.status(404).json({ error: "Memory not found" });
  }
  return res.json({ success: true });
});

app.get("/memories/search", requireAuth, (req, res) => {
  const query = cleanText(req.query?.q, 300);
  const limit = Math.max(1, Math.min(20, Number(req.query?.limit) || 8));
  if (!query) {
    return res.status(400).json({ error: "Query parameter q is required" });
  }

  const memories = getRelevantUserMemories(req.auth.userId, query, limit);
  return res.json({
    success: true,
    query,
    count: memories.length,
    memories,
  });
});

app.post("/assistant/goal-plan", requireAuth, (req, res) => {
  const goal = cleanText(req.body?.goal, 300);
  if (!goal) {
    return res.status(400).json({ error: "goal is required" });
  }

  const language = detectLanguage(goal);
  const plan = buildGoalPlan(goal);
  if (!plan) {
    return res.status(400).json({ error: "Could not generate plan for this goal" });
  }

  const command = buildGoalPlanCommandResponse(goal, language);
  return res.json({
    success: true,
    generatedAt: nowIso(),
    plan,
    command,
  });
});

app.get("/knowledge/docs", requireAuth, (req, res) => {
  const limit = Math.max(1, Math.min(100, Number(req.query?.limit) || 30));
  const docs = listKnowledgeDocuments(req.auth.userId, limit);
  return res.json({
    success: true,
    count: docs.length,
    documents: docs,
  });
});

app.post("/knowledge/docs", requireAuth, (req, res) => {
  const title = cleanText(req.body?.title, 180);
  const content = cleanText(req.body?.content, 12000);
  const tags = normalizeKnowledgeTags(req.body?.tags);
  if (!content) {
    return res.status(400).json({ error: "content is required" });
  }

  const row = createKnowledgeDocument(req.auth.userId, { title, content, tags });
  if (!row) {
    return res.status(400).json({ error: "Could not save knowledge document" });
  }
  return res.status(201).json({
    success: true,
    document: mapKnowledgeDocRow(row),
  });
});

app.post("/knowledge/ingest", requireAuth, (req, res) => {
  const title = cleanText(req.body?.title, 180);
  const tags = normalizeKnowledgeTags(req.body?.tags);
  const base64Data = cleanText(req.body?.base64Data, 2_000_000);
  const filename = cleanText(req.body?.filename, 180);
  const mimeType = cleanText(req.body?.mimeType, 120);

  const parsed = decodeKnowledgeFileText({ filename, mimeType, base64Data });
  if (!parsed.ok) {
    return res.status(400).json({ error: parsed.error || "File ingest failed" });
  }

  const row = createKnowledgeDocument(req.auth.userId, {
    title: title || parsed.title,
    content: parsed.content,
    tags,
  });
  if (!row) {
    return res.status(400).json({ error: "Could not save ingested document" });
  }

  return res.status(201).json({
    success: true,
    document: mapKnowledgeDocRow(row),
  });
});

app.delete("/knowledge/docs/:id", requireAuth, (req, res) => {
  const docId = Number(req.params.id);
  if (!Number.isFinite(docId)) {
    return res.status(400).json({ error: "Invalid document id" });
  }

  const result = db
    .prepare("DELETE FROM knowledge_documents WHERE id = ? AND user_id = ?")
    .run(docId, req.auth.userId);
  if (result.changes === 0) {
    return res.status(404).json({ error: "Document not found" });
  }
  return res.json({ success: true });
});

app.get("/knowledge/search", requireAuth, (req, res) => {
  const query = cleanText(req.query?.q, 300);
  const limit = Math.max(1, Math.min(20, Number(req.query?.limit) || 5));
  if (!query) {
    return res.status(400).json({ error: "Query parameter q is required" });
  }

  const docs = searchKnowledgeDocuments(req.auth.userId, query, limit);
  const items = docs.map((item) => ({
    id: item.id,
    title: item.title,
    snippet: cleanText(item.content, 320),
    tags: item.tags,
    updatedAt: item.updatedAt,
  }));

  return res.json({
    success: true,
    query,
    count: items.length,
    results: items,
  });
});

app.get("/assistant/jobs", requireAuth, (req, res) => {
  const limit = Math.max(1, Math.min(100, Number(req.query?.limit) || 20));
  const jobs = listAssistantJobs(req.auth.userId, limit);
  return res.json({
    success: true,
    count: jobs.length,
    jobs,
  });
});

app.post("/assistant/jobs", requireAuth, (req, res) => {
  const goal = cleanText(req.body?.goal, 500);
  const title = cleanText(req.body?.title, 180);
  const steps = Array.isArray(req.body?.steps) ? req.body.steps : [];
  let normalizedSteps = normalizeJobSteps(steps);
  if (normalizedSteps.length === 0 && goal) {
    const plan = buildWorkflowPlan(goal);
    normalizedSteps = normalizeJobSteps(plan?.steps || []);
  }
  if (!goal || normalizedSteps.length === 0) {
    return res.status(400).json({ error: "goal and executable steps are required" });
  }
  const job = createAssistantJob(req.auth.userId, {
    title: title || `Workflow: ${goal}`,
    goal,
    steps: normalizedSteps,
  });
  if (!job) {
    return res.status(400).json({ error: "Could not create assistant job" });
  }
  return res.status(201).json({
    success: true,
    job,
  });
});

app.post("/assistant/jobs/:id/advance", requireAuth, (req, res) => {
  const jobId = Number(req.params.id);
  if (!Number.isFinite(jobId)) {
    return res.status(400).json({ error: "Invalid job id" });
  }
  const job = advanceAssistantJob(req.auth.userId, jobId);
  if (!job) {
    return res.status(404).json({ error: "Job not found" });
  }
  return res.json({
    success: true,
    job,
  });
});

app.post("/assistant/jobs/:id/cancel", requireAuth, (req, res) => {
  const jobId = Number(req.params.id);
  if (!Number.isFinite(jobId)) {
    return res.status(400).json({ error: "Invalid job id" });
  }
  const job = cancelAssistantJob(req.auth.userId, jobId);
  if (!job) {
    return res.status(404).json({ error: "Job not found" });
  }
  return res.json({
    success: true,
    job,
  });
});

app.post("/chat", async (req, res) => {
  try {
    const {
      message,
      isOnlineMode = true,
      smartReply = true,
      chatHistory = [],
      sessionId = null,
      persistToSession = false,
      assistantMode = "jarvis",
    } = req.body;

    if (!message || !message.trim()) {
      return res.status(400).json({ error: "Message is required" });
    }

    if (String(message).trim().length > 4000) {
      return res.status(400).json({
        error: "Message is too long",
        details: "Maximum message length is 4000 characters.",
      });
    }

    if (Array.isArray(chatHistory) && chatHistory.length > 40) {
      return res.status(400).json({
        error: "Chat history is too large",
        details: "Maximum history length is 40 items.",
      });
    }

    const language = detectLanguage(message);
    const userId = getOptionalAuthUserId(req);
    const memoryCommand = parseMemoryCommand(message);
    const memoryContext = buildMemoryContext(userId, message);
    const knowledgeContext = buildKnowledgeContext(userId, message);
    const combinedContext = `${memoryContext}${knowledgeContext}`;
    const normalizedAssistantMode = normalizeAssistantMode(assistantMode);

    let intent = detectIntent(message, isOnlineMode);
    let result;

    if (memoryCommand.kind !== "none") {
      intent = "memory_command";
      result = handleMemoryCommand(memoryCommand, userId, language);
    } else if (intent === "command") {
      result = await handleCommandIntent(message, language, userId);
    } else if (intent === "code") {
      result = await handleCodeIntent(
        message,
        language,
        smartReply,
        chatHistory,
        combinedContext,
        normalizedAssistantMode
      );
    } else if (intent === "image") {
      result = await handleImageIntent(message, language, smartReply);
    } else if (intent === "video") {
      result = await handleVideoIntent(message, language, smartReply);
    } else if (intent === "offline_command") {
      result = {
        type: "offline_command",
        reply: "Handled locally in offline mode.",
      };
    } else {
      result = await handleChatIntent(
        message,
        language,
        smartReply,
        chatHistory,
        combinedContext,
        normalizedAssistantMode
      );
    }

    const suggestions = buildFollowupSuggestions({
      intent,
      result,
      language,
    });
    result = {
      ...result,
      suggestions,
    };

    if (persistToSession === true && sessionId != null) {
      const parsedSessionId = Number(sessionId);

      if (userId && Number.isFinite(parsedSessionId)) {
        const allowed = db
          .prepare("SELECT id FROM chat_sessions WHERE id = ? AND user_id = ?")
          .get(parsedSessionId, userId);

        if (allowed) {
          const now = nowIso();
          const insertMessage = db.prepare(
            `INSERT INTO chat_messages
             (session_id, role, text, type, code, image_prompt, video_prompt, action, url, info, suggestions_json, starred, created_at)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?)`
          );

          const userText = cleanText(message, 12000);
          if (userText) {
            insertMessage.run(
              parsedSessionId,
              "user",
              userText,
              "chat",
              "",
              "",
              "",
              "",
              "",
              "",
              "[]",
              now
            );
          }

          const aiText = cleanText(result?.reply, 12000);
          if (aiText) {
            insertMessage.run(
              parsedSessionId,
              "ai",
              aiText,
              cleanText(result?.type, 40) || "chat",
              cleanText(result?.code, 120000),
              cleanText(result?.imagePrompt, 4000),
              cleanText(result?.videoPrompt, 4000),
              cleanText(result?.action, 80),
              cleanText(result?.url, 2000),
              cleanText(result?.info, 4000),
              serializeSuggestions(result?.suggestions),
              now
            );
          }

          db.prepare("UPDATE chat_sessions SET updated_at = ? WHERE id = ?").run(
            now,
            parsedSessionId
          );
        }
      }
    }

    return res.json({
      intent,
      language,
      smartReply,
      assistantMode: normalizedAssistantMode,
      ...result,
    });
  } catch (error) {
    console.error("FLOWGNIMAG BACKEND ERROR:");
    console.error(error);

    return res.status(500).json({
      error: "Failed to process request",
      details: error?.message || "Unknown error",
    });
  }
});

app.post("/generate-image", async (req, res) => {
  try {
    const { prompt } = req.body;

    if (!prompt || !prompt.trim()) {
      return res.status(400).json({
        error: "Prompt is required",
      });
    }

    if (String(prompt).trim().length > 4000) {
      return res.status(400).json({
        error: "Prompt is too long",
        details: "Maximum prompt length is 4000 characters.",
      });
    }

    const providers = getImageProviderCandidates();

    if (providers.length === 0) {
      return res.status(500).json({
        error: "No image provider is configured",
        details:
          "Configure OPENAI_API_KEY / OPENROUTER_API_KEY / HF_TOKEN, or enable free fallback with ALLOW_FREE_IMAGE_PROVIDER=1.",
      });
    }

    const attempts = [];
    let result = null;
    let lastError = null;

    for (const provider of providers) {
      try {
        result =
          provider === "openai"
            ? await generateImageWithOpenAI(prompt)
            : provider === "huggingface"
              ? await generateImageWithHuggingFace(prompt)
              : provider === "openrouter"
                ? await generateImageWithOpenRouter(prompt)
                : await generateImageWithPollinations(prompt);
        break;
      } catch (error) {
        lastError = error;
        attempts.push({
          provider,
          error: error?.error || "Failed to generate image",
          details: cleanText(error?.details || error?.message || "", 240),
        });
      }
    }

    if (!result) {
      const allHfOom =
        attempts.length > 0 &&
        attempts.every(
          (item) =>
            item.provider === "huggingface" &&
            isHuggingFaceOomError({
              error: item.error,
              details: item.details,
            })
        );

      return res.status(allHfOom ? 503 : 500).json({
        error:
          lastError?.error || "Failed to generate image",
        details:
          allHfOom
            ? "Hugging Face GPU is busy/out of memory. Try again in a few seconds or configure OpenAI/OpenRouter as fallback."
            : lastError?.details || lastError?.message || "Unknown error",
        provider: lastError?.provider || providers[0] || "unknown",
        attemptedProviders: attempts,
      });
    }

    return res.json({
      success: true,
      provider: result.provider,
      imageDataUrl: result.imageDataUrl,
      prompt: prompt.trim(),
      attemptedProviders: providers,
    });
  } catch (error) {
    console.error("IMAGE GENERATION ERROR:");
    console.error(error);

    return res.status(500).json({
      error: error?.error || "Failed to generate image",
      details: error?.details || error?.message || "Unknown error",
      provider: error?.provider || getPreferredImageProvider() || "unknown",
    });
  }
});

app.post("/generate-video", async (req, res) => {
  try {
    const { prompt } = req.body;

    if (!prompt || !prompt.trim()) {
      return res.status(400).json({
        error: "Prompt is required",
      });
    }

    if (String(prompt).trim().length > 4000) {
      return res.status(400).json({
        error: "Prompt is too long",
        details: "Maximum prompt length is 4000 characters.",
      });
    }

    const provider = getPreferredVideoProvider();

    if (!provider) {
      return res.status(500).json({
        error: "No video provider is configured",
        details: "Set HF_TOKEN in backend/.env to use Hugging Face text-to-video",
      });
    }

    const result = await generateVideoWithHuggingFace(prompt);

    return res.json({
      success: true,
      provider: result.provider,
      videoDataUrl: result.videoDataUrl,
      prompt: prompt.trim(),
    });
  } catch (error) {
    console.error("VIDEO GENERATION ERROR:");
    console.error(error);

    return res.status(500).json({
      error: error?.error || "Failed to generate video",
      details: error?.details || error?.message || "Unknown error",
      provider: error?.provider || getPreferredVideoProvider() || "unknown",
    });
  }
});

const PORT = process.env.PORT || 5000;

if (require.main === module) {
  app.listen(PORT, () => {
    console.log(`FLOWGNIMAG backend running on http://localhost:${PORT}`);
  });
}

module.exports = { app };
