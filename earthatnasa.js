import fs from "node:fs";
 import fetch from "node-fetch";
 import { default as slackify } from "slackify-markdown";

 const slackBotToken = process.env.SLACK_BOT_TOKEN;
 const channelId     = process.env.SLACK_CHANNEL_ID;
 const eventPath     = process.env.GITHUB_EVENT_PATH;
 const scWsToken     = process.env.SC_WS_TOKEN || ""; // optional

+// Simple detectors
+const scRegex   = /(https?:\/\/(?:www\.)?soundcloud\.com\/[^\s)]+)/i;
+const nasaRegex = /(https?:\/\/(?:www\.)?images\.nasa\.gov\/details\/[^\s)]+)/i;
+const ytRegex   = /(https?:\/\/(?:www\.)?(?:youtube\.com\/watch\?v=|youtu\.be\/)[^\s)]+)/i;

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

-// 1) Find a SoundCloud URL (first occurrence)
-const scRegex = /(https?:\/\/(?:www\.)?soundcloud\.com\/[^\s)]+)/i;
-const match = scRegex.exec(`${title}\n\n${body}`);
+const haystack = `${title}\n\n${body}`;
+const scMatch   = scRegex.exec(haystack);
+const nasaMatch = nasaRegex.exec(haystack);
+const ytMatch   = ytRegex.exec(haystack);

 // 2) Resolve to Songlink (Odesli)
 let odesliUrl = null;
 let platforms = [];
-if (match) {
-  const scUrl = match[1];
+if (scMatch) {
+  const scUrl = scMatch[1];
   const odesliApi = `https://api.song.link/v1-alpha.1/links?url=${encodeURIComponent(scUrl)}`;
   try {
     const r = await fetch(odesliApi, { headers: { "Accept": "application/json" }});
     if (r.ok) {
       const data = await r.json();
       odesliUrl = data.pageUrl || null;
       // ...
     }
   } catch (e) {}
 }

+// 2b) Resolve NASA images.nasa.gov (if present)
+let nasaCard = null;
+if (nasaMatch) {
+  // Extract media ID from URL like: https://images.nasa.gov/details/<MEDIA_ID>
+  const mediaId = nasaMatch[1].split("/details/")[1];
+  if (mediaId) {
+    try {
+      const searchApi = `https://images-api.nasa.gov/search?nasa_id=${encodeURIComponent(mediaId)}`;
+      const r = await fetch(searchApi, { headers: { "Accept": "application/json" }});
+      if (r.ok) {
+        const data = await r.json();
+        const item = (data.collection?.items || [])[0];
+        if (item) {
+          const meta = (item.data || [])[0] || {};
+          const links = item.links || [];
+          const thumb = links.find(x => x.rel === "preview" || x.render === "image")?.href;
+          nasaCard = {
+            title: meta.title || mediaId,
+            desc: meta.description || "",
+            date: meta.date_created || "",
+            center: meta.center || "",
+            nasaId: meta.nasa_id || mediaId,
+            thumb,
+            canonical: `https://images.nasa.gov/details/${mediaId}`
+          };
+        }
+      }
+    } catch (_) {}
+  }
+}

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

-// 4) Compose Slack message
-let text = `*PR:* <${url}|${title}>\n*Author:* ${author}\n*Branch:* \`${head}\` → \`${base}\`\n`;
-if (match) {
-  text += `\n*Detected SoundCloud URL:* ${match[1]}\n`;
-  if (odesliUrl) {
-    text += `*Songlink:* <${odesliUrl}|Open universal link>\n`;
-    if (platforms.length) {
-      text += platforms.map(([n, u]) => `• *${n}:* <${u}|open>`).join("\n") + "\n";
-    }
-  } else {
-    text += `*Songlink:* could not resolve via Odesli\n`;
-  }
-} else {
-  text += `\n_No SoundCloud URL found in PR title/body._\n`;
-}
-text += `\n*SoundCloud WebSocket snippet (masked token):*\n${snippet}`;
+// 4) Compose Slack Blocks message (richer card)
+const blocks = [
+  { type: "section", text: { type: "mrkdwn",
+    text: `*PR:* <${url}|${title}>\n*Author:* ${author}\n*Branch:* \`${head}\` → \`${base}\``
+  }}
+];
+
+if (scMatch) {
+  const scUrl = scMatch[1];
+  blocks.push({ type: "divider" });
+  blocks.push({ type: "section", text: { type: "mrkdwn",
+    text: `*Detected SoundCloud URL:*\n${scUrl}\n` +
+          (odesliUrl ? `*Songlink:* <${odesliUrl}|Open universal link>` : "_Songlink could not be resolved_")
+  }});
+  if (platforms.length) {
+    blocks.push({ type: "section", text: { type: "mrkdwn",
+      text: platforms.map(([n,u]) => `• *${n}:* <${u}|open>`).join("\n")
+    }});
+  }
+}
+
+if (nasaCard) {
+  blocks.push({ type: "divider" });
+  if (nasaCard.thumb) {
+    blocks.push({
+      type: "section",
+      text: { type: "mrkdwn",
+        text: `*NASA Media:*\n*Title:* ${nasaCard.title}\n*Date:* ${nasaCard.date}\n*Center:* ${nasaCard.center}\n<${nasaCard.canonical}|Open on images.nasa.gov>`
+      },
+      accessory: {
+        type: "image",
+        image_url: nasaCard.thumb,
+        alt_text: "NASA media thumbnail"
+      }
+    });
+  } else {
+    blocks.push({ type: "section", text: { type: "mrkdwn",
+      text: `*NASA Media:*\n*Title:* ${nasaCard.title}\n<${nasaCard.canonical}|Open on images.nasa.gov>`
+    }});
+  }
+}
+
+if (ytMatch) {
+  blocks.push({ type: "divider" });
+  blocks.push({ type: "section", text: { type: "mrkdwn",
+    text: `*YouTube:* ${ytMatch[1]}`
+  }});
+}
+
+blocks.push({ type: "divider" });
+blocks.push({ type: "section", text: { type: "mrkdwn",
+  text: `*SoundCloud WebSocket snippet (masked token):*\n${snippet}`
+}});
 
-const slackResp = await fetch("https://slack.com/api/chat.postMessage", {
+const slackResp = await fetch("https://slack.com/api/chat.postMessage", {
   method: "POST",
   headers: {
     "Content-Type": "application/json; charset=utf-8",
     "Authorization": `Bearer ${slackBotToken}`
   },
-  body: JSON.stringify({
-    channel: channelId,
-    text: text
-  })
+  body: JSON.stringify({
+    channel: channelId,
+    text: `PR: ${title}`, // fallback text
+    blocks
+  })
 });