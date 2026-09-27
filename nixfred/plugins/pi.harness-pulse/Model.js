.pragma library

// Attention states the daemon emits. Anything unknown renders as idle.
var STATES = ["working", "waiting", "permission", "failed", "done", "idle", "offline"];

// Glyphs are the non-colour channel (accessibility, reducedMotion).
var GLYPHS = {
  working: "◐",     // half circle
  waiting: "?",
  permission: "!",
  failed: "✗",      // ballot x
  done: "●",        // filled circle
  idle: "○",        // ring
  offline: "·"      // middle dot
};

function normaliseState(s) {
  return STATES.indexOf(s) >= 0 ? s : "idle";
}

function glyphFor(state) {
  return GLYPHS[normaliseState(state)] || GLYPHS.idle;
}

// Parse one JSON line from pulse-feed. Returns {ok, agents, hostname, error}.
function parseFeedLine(line) {
  try {
    var d = JSON.parse(line);
    if (!d || typeof d !== "object") return { ok: false, agents: [], error: "bad payload" };
    if (d.error) return { ok: false, agents: [], error: String(d.error) };
    var agents = Array.isArray(d.agents) ? d.agents : [];
    return {
      ok: true,
      hostname: d.hostname || "",
      agents: agents.map(function (a) {
        return {
          agentId: String(a.agentId || ""),
          name: String(a.name || a.agentId || "agent"),
          engine: String(a.engine || ""),
          machine: String(a.machine || d.hostname || ""),
          state: normaliseState(a.state),
          since: Number(a.since) || 0,
          detail: String(a.detail || ""),
          label: String(a.label || a.state || ""),
          glyph: a.glyph ? String(a.glyph) : glyphFor(a.state)
        };
      })
    };
  } catch (e) {
    return { ok: false, agents: [], error: "parse: " + e };
  }
}

// Rank: what needs Fred first. Permission and waiting float left.
var RANK = { permission: 0, waiting: 1, failed: 2, done: 3, working: 4, idle: 5, offline: 6 };

function sortAgents(agents) {
  return agents.slice().sort(function (a, b) {
    var r = RANK[a.state] - RANK[b.state];
    if (r !== 0) return r;
    return a.since - b.since;
  });
}

// Six-digit hex colours from colors.toml, keyed by name (blue, yellow, red...).
function parseThemeColors(text) {
  var out = {};
  var re = /^\s*([A-Za-z0-9_]+)\s*=\s*"?#?([0-9a-fA-F]{6})"?/gm;
  var m;
  while ((m = re.exec(text)) !== null) out[m[1].toLowerCase()] = "#" + m[2];
  return out;
}

function ago(sinceMs, nowMs) {
  if (!sinceMs) return "";
  var s = Math.max(0, Math.round((nowMs - sinceMs) / 1000));
  if (s < 60) return s + "s";
  if (s < 3600) return Math.round(s / 60) + "m";
  return Math.round(s / 3600) + "h";
}
