//// HTML dashboard — renders the observability UI.
////
//// All HTML is generated server-side. No JavaScript framework needed.

import gleam/int
import gleam/list
import gleam/string
import yard/ui/queries.{type ConversationRow, type EventRow, type RunSummary}

/// Generate the main dashboard page.
pub fn dashboard(
  runs: List(RunSummary),
  conversations: List(ConversationRow),
) -> String {
  page("Yard Dashboard", dashboard_body(runs, conversations))
}

/// Generate the run detail page.
pub fn run_detail(run_id: String, events: List(EventRow)) -> String {
  let safe_id = escape(run_id)
  page("Run " <> safe_id, run_detail_body(run_id, events))
}

/// Generate the conversation detail page.
pub fn conversation_detail(id: String, messages_json: String) -> String {
  let safe_id = escape(id)
  page(
    "Conversation " <> truncate(safe_id, 12),
    conversation_body(id, messages_json),
  )
}

// ── Page wrapper ─────────────────────────────────────────────────────

fn page(title: String, body: String) -> String {
  "<!DOCTYPE html>
<html lang=\"en\">
<head>
<meta charset=\"UTF-8\">
<meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">
<title>" <> escape(title) <> "</title>
<style>" <> css() <> "</style>
</head>
<body>
<nav class=\"topnav\">
  <a href=\"/\" class=\"brand\">⚓ Yard</a>
  <a href=\"/\">Dashboard</a>
  <a href=\"/runs\">Runs</a>
  <a href=\"/conversations\">Conversations</a>
</nav>
<main>" <> body <> "</main>
</body>
</html>"
}

// ── Dashboard body ───────────────────────────────────────────────────

fn dashboard_body(
  runs: List(RunSummary),
  conversations: List(ConversationRow),
) -> String {
  let run_count = list.length(runs)
  let conv_count = list.length(conversations)
  "<h1>Dashboard</h1>
<div class=\"stats\">
  <div class=\"stat\"><span class=\"v\">" <> int.to_string(run_count) <> "</span><span class=\"l\">Recent Runs</span></div>
  <div class=\"stat\"><span class=\"v\">" <> int.to_string(conv_count) <> "</span><span class=\"l\">Conversations</span></div>
</div>
<h2>Recent Runs</h2>" <> runs_table(runs) <> "<h2>Conversations</h2>" <> conversations_table(
    conversations,
  )
}

// ── Run detail body ──────────────────────────────────────────────────

fn run_detail_body(run_id: String, events: List(EventRow)) -> String {
  let safe_id = escape(run_id)
  "<h1>Run Detail</h1>
<p class=\"muted\">Run ID: <code>" <> safe_id <> "</code></p>" <> events_table(
    events,
  )
}

// ── Conversation body ────────────────────────────────────────────────

fn conversation_body(id: String, messages_json: String) -> String {
  let safe_id = escape(id)
  "<h1>Conversation</h1>
<p class=\"muted\">ID: <code>" <> safe_id <> "</code></p>
<div class=\"messages\">" <> render_messages(messages_json) <> "</div>"
}

// ── Tables ───────────────────────────────────────────────────────────

fn runs_table(runs: List(RunSummary)) -> String {
  case runs {
    [] -> "<p class=\"empty\">No runs yet.</p>"
    _ -> "
<table>
  <thead><tr><th>Run ID</th><th>Agent</th><th>Source</th><th>Status</th><th>Started</th></tr></thead>
  <tbody>
" <> string.join(
        list.map(runs, fn(r) {
          "<tr>"
          <> "<td><a href=\"/runs/"
          <> escape(r.run_id)
          <> "\"><code>"
          <> truncate(escape(r.run_id), 12)
          <> "</code></a></td>"
          <> "<td>"
          <> escape(r.agent_id)
          <> "</td>"
          <> "<td>"
          <> escape(r.trigger_source)
          <> "</td>"
          <> "<td><span class=\"badge badge-"
          <> status_class(r.status)
          <> "\">"
          <> escape(r.status)
          <> "</span></td>"
          <> "<td class=\"muted\">"
          <> escape(r.started_at)
          <> "</td>"
          <> "</tr>"
        }),
        "\n",
      ) <> "
  </tbody>
</table>"
  }
}

fn events_table(events: List(EventRow)) -> String {
  case events {
    [] -> "<p class=\"empty\">No events recorded.</p>"
    _ -> "
<table>
  <thead><tr><th>Type</th><th>Source</th><th>Duration</th><th>Time</th><th>Payload</th></tr></thead>
  <tbody>
" <> string.join(
        list.map(events, fn(e) {
          let dur = case e.duration_ms {
            option.Some(ms) -> int.to_string(ms) <> "ms"
            option.None -> "—"
          }
          "<tr>"
          <> "<td><span class=\"badge badge-event-"
          <> event_class(e.event_type)
          <> "\">"
          <> escape(e.event_type)
          <> "</span></td>"
          <> "<td><span class=\"badge badge-src-"
          <> e.src
          <> "\">"
          <> escape(e.src)
          <> "</span></td>"
          <> "<td>"
          <> dur
          <> "</td>"
          <> "<td class=\"muted\">"
          <> escape(e.created_at)
          <> "</td>"
          <> "<td><code class=\"payload\">"
          <> escape(truncate(e.payload, 200))
          <> "</code></td>"
          <> "</tr>"
        }),
        "\n",
      ) <> "
  </tbody>
</table>"
  }
}

fn conversations_table(conversations: List(ConversationRow)) -> String {
  case conversations {
    [] -> "<p class=\"empty\">No conversations yet.</p>"
    _ -> "
<table>
  <thead><tr><th>ID</th><th>Agent</th><th>User Key</th><th>Updated</th></tr></thead>
  <tbody>
" <> string.join(
        list.map(conversations, fn(c) {
          "<tr>"
          <> "<td><a href=\"/conversations/"
          <> escape(c.id)
          <> "\"><code>"
          <> truncate(escape(c.id), 12)
          <> "</code></a></td>"
          <> "<td>"
          <> escape(c.agent_id)
          <> "</td>"
          <> "<td>"
          <> escape(c.user_key)
          <> "</td>"
          <> "<td class=\"muted\">"
          <> escape(c.updated_at)
          <> "</td>"
          <> "</tr>"
        }),
        "\n",
      ) <> "
  </tbody>
</table>"
  }
}

// ── Message rendering ────────────────────────────────────────────────

fn render_messages(messages_json: String) -> String {
  // Simple rendering — just show the raw JSON in a pre block.
  // A more polished version would parse and render each message.
  "<pre class=\"json\">" <> escape(messages_json) <> "</pre>"
}

// ── Helpers ──────────────────────────────────────────────────────────

fn status_class(status: String) -> String {
  case status {
    "completed" -> "ok"
    "running" -> "info"
    "failed" -> "err"
    "cancelled" -> "warn"
    _ -> "neutral"
  }
}

fn event_class(event_type: String) -> String {
  case event_type {
    // Host (yard_events) lifecycle
    "actor_started" -> "info"
    "actor_completed" -> "ok"
    "effect_yielded" -> "neutral"
    "effect_handled" -> "info"
    "effect_replayed" -> "warn"
    // Pig (pig_events) agent-internal events
    "pig.inference_completed" -> "ok"
    "pig.tool_executed" -> "info"
    "pig.session_ended" -> "ok"
    "pig.inference_failed" -> "err"
    "pig." <> _ -> "info"
    _ -> "neutral"
  }
}

fn escape(s: String) -> String {
  s
  |> string.replace("&", "&amp;")
  |> string.replace("<", "&lt;")
  |> string.replace(">", "&gt;")
  |> string.replace("\"", "&quot;")
}

fn truncate(s: String, max: Int) -> String {
  case string.length(s) > max {
    True -> string.slice(s, 0, max) <> "…"
    False -> s
  }
}

import gleam/option

// ── CSS ──────────────────────────────────────────────────────────────

fn css() -> String {
  "
  :root {
    --bg: #0f172a; --surface: #1e293b; --text: #e2e8f0;
    --muted: #64748b; --border: #334155; --link: #38bdf8;
    --ok: #22c55e; --err: #ef4444; --warn: #f59e0b; --info: #3b82f6;
  }
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { background: var(--bg); color: var(--text); font-family: -apple-system, sans-serif; font-size: 14px; line-height: 1.5; padding: 0; }
  nav.topnav { background: var(--surface); padding: 12px 24px; display: flex; gap: 16px; align-items: center; border-bottom: 1px solid var(--border); position: sticky; top: 0; z-index: 100; }
  nav.topnav a { color: var(--muted); text-decoration: none; font-weight: 500; }
  nav.topnav a:hover { color: var(--link); }
  nav.topnav a.brand { font-weight: 700; font-size: 16px; color: var(--text); }
  main { max-width: 1100px; margin: 0 auto; padding: 24px; }
  h1 { margin-bottom: 16px; font-size: 22px; }
  h2 { margin: 24px 0 12px; font-size: 18px; }
  table { width: 100%; border-collapse: collapse; background: var(--surface); border-radius: 8px; overflow: hidden; }
  th, td { text-align: left; padding: 10px 14px; border-bottom: 1px solid var(--border); }
  th { color: var(--muted); font-size: 12px; text-transform: uppercase; letter-spacing: 0.04em; }
  tr:last-child td { border-bottom: none; }
  td code, pre.json { font-family: 'SF Mono', monospace; font-size: 12px; }
  .stats { display: flex; gap: 16px; margin-bottom: 24px; }
  .stat { background: var(--surface); border-radius: 8px; padding: 16px 20px; min-width: 120px; }
  .stat .v { font-size: 24px; font-weight: 700; display: block; }
  .stat .l { font-size: 12px; color: var(--muted); }
  .badge { display: inline-block; padding: 2px 8px; border-radius: 999px; font-size: 11px; font-weight: 700; text-transform: uppercase; }
  .badge-ok { background: rgba(34,197,94,0.15); color: var(--ok); }
  .badge-err { background: rgba(239,68,68,0.15); color: var(--err); }
  .badge-warn { background: rgba(245,158,11,0.15); color: var(--warn); }
  .badge-info { background: rgba(59,130,246,0.15); color: var(--info); }
  .badge-neutral { background: rgba(100,116,139,0.15); color: var(--muted); }
  .badge-src-host { background: rgba(56,189,248,0.15); color: var(--link); }
  .badge-src-pig { background: rgba(168,85,247,0.15); color: #a855f7; }
  .muted { color: var(--muted); }
  .empty { color: var(--muted); font-style: italic; padding: 12px 0; }
  pre.json { background: var(--surface); padding: 16px; border-radius: 8px; overflow-x: auto; white-space: pre-wrap; word-break: break-all; }
  .payload { color: var(--muted); }
  "
}
