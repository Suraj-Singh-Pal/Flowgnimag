const PULSEIQ_API_KEY = (process.env.PULSEIQ_API_KEY || "").trim();
const PULSEIQ_PROJECT_ID = (
  process.env.PULSEIQ_PROJECT_ID || "69df59433719108df765d5ba"
).trim();
const PULSEIQ_ENDPOINT = "https://pulseiq-ffio.onrender.com/api/ingest/event";

async function track(eventName, userId = null, properties = {}) {
  if (!PULSEIQ_API_KEY) {
    return;
  }

  try {
    const response = await fetch(PULSEIQ_ENDPOINT, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-api-key": PULSEIQ_API_KEY,
      },
      body: JSON.stringify({
        projectId: PULSEIQ_PROJECT_ID,
        eventName,
        userId: userId || undefined,
        anonymousId: "server_event",
        properties,
      }),
    });

    if (!response.ok) {
      const details = await response.text().catch(() => "");
      console.warn(
        `[PulseIQ] ${eventName} failed with status ${response.status}: ${details}`
      );
    }
  } catch (error) {
    console.warn(
      `[PulseIQ] ${eventName} failed: ${error?.message || "Unknown error"}`
    );
  }
}

module.exports = { track };
