// .github/scripts/songlink_to_slack.mjs
import fs from "node:fs";
import fetch from "node-fetch";
import { default as slackify } from "slackify-markdown";

const slackBotToken = process.env.SLACK_BOT_TOKEN;
const channelId     = process.env.SLACK_CHANNEL_ID;
const eventPath     = process.env.GITHUB_EVENT_PATH;
const scWsToken     = process.env.SC_WS_TOKEN || ""; // optional

if (!slackBotToken || !channelId || !eventPath) {
  console.error("Missing SLACK_BOT_TOKEN, SLACK_CHANNEL_ID, or GITHUB_EVENT_PATH");
  process.exit(1);
}

const event = JSON.parse(fs.readFileSync(eventPath, "utf8"));
const pr = event.pull_request || {};
const title = pr.title || "";
const body  = pr.body  || "";
const url   = pr.html_url || "";
const author = (pr.user && pr.user.login) || "unknown";
const head = (pr.head && pr.head.ref) || "?";
const base = (pr.base && pr.base.ref) || "?";

// 1) Find a SoundCloud URL (first occurrence)
const scRegex = /(https?:\/\/(?:www\.)?soundcloud\.com\/[^\s)]+)/i;
const match = scRegex.exec(`${title}\n\n${body}`);

// 2) Resolve to Songlink (Odesli)
let odesliUrl = null;
let platforms = [];
if (match) {
  const scUrl = match[1];
  const odesliApi = `https://api.song.link/v1-alpha.1/links?url=${encodeURIComponent(scUrl)}`;
  try {
    const r = await fetch(odesliApi, { headers: { "Accept": "application/json" }});
    if (r.ok) {
      const data = await r.json();
      odesliUrl = data.pageUrl || null;

      // collect a few platform links if present
      const ents = data.entitiesByUniqueId || {};
      const firstKey = data.entityUniqueId;
      const root = ents[firstKey] || {};
      const linksByPlatform = data.linksByPlatform || {};
      const pick = (key) => linksByPlatform[key]?.url;
      platforms = [
        ["Spotify", pick("spotify")],
        ["Apple Music", pick("appleMusic")],
        ["YouTube", pick("youtube")],
        ["SoundCloud", pick("soundcloud")]
      ].filter(([, v]) => !!v);
    }
  } catch (e) {
    // ignore resolution errors; we can still post a basic message
  }
}

// 3) Build the (optional) WebSocket snippet without printing the token
const snippet = scWsToken
  ? [
      "```js",
      "const signalingChannel = new WebSocket(",
      `  'wss://api.soundcloud.com/realtime?token=${"*".repeat(8)}'`,
      ");",
      "",
      "signalingChannel.onopen = () => {",
      "  console.log('WebSocket connection opened.');",
      "};",
      "",
      "signalingChannel.onmessage = (event) => {",
      "  console.log('Received:', event.data);",
      "};",
      "```",
      "",
      "_Runtime note: The real token is injected at runtime from the secret `SC_WS_TOKEN` — not shown here._"
    ].join("\n")
  : "_No SC WebSocket token provided; skipping snippet._";

// 4) Compose Slack message
let text = `*PR:* <${url}|${title}>\n*Author:* ${author}\n*Branch:* \`${head}\` → \`${base}\`\n`;
if (match) {
  text += `\n*Detected SoundCloud URL:* ${match[1]}\n`;
  if (odesliUrl) {
    text += `*Songlink:* <${odesliUrl}|Open universal link>\n`;
    if (platforms.length) {
      text += platforms.map(([n, u]) => `• *${n}:* <${u}|open>`).join("\n") + "\n";
    }
  } else {
    text += `*Songlink:* could not resolve via Odesli\n`;
  }
} else {
  text += `\n_No SoundCloud URL found in PR title/body._\n`;
}
text += `\n*SoundCloud WebSocket snippet (masked token):*\n${snippet}`;

const slackResp = await fetch("https://slack.com/api/chat.postMessage", {
  method: "POST",
  headers: {
    "Content-Type": "application/json; charset=utf-8",
    "Authorization": `Bearer ${slackBotToken}`
  },
  body: JSON.stringify({
    channel: channelId,
    text: text
  })
});
const slackJson = await slackResp.json();
if (!slackJson.ok) {
  console.error("Slack post failed:", slackJson.error);
  process.exit(1);
}
console.log("Posted Songlink to Slack.");