//// Observability UI HTTP server — served alongside yard on startup.
////
//// Built on mist. Routes:
////   GET /                     — Dashboard (recent runs + conversations)
////   GET /runs                 — Full runs list
////   GET /runs/:run_id         — Run detail with events
////   GET /conversations        — Conversations list
////   GET /conversations/:id    — Conversation messages

import gabsurd/client.{type Db}
import gleam/bytes_tree
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/otp/actor
import gleam/otp/static_supervisor
import mist.{type Connection, type ResponseData}
import yard/ui/queries
import yard/ui/template

/// Start the observability UI HTTP server.
///
/// Call this from yard's startup to serve the dashboard.
/// Returns the supervisor PID; the server runs for the lifetime of the VM.
pub fn start(
  db db: Db,
  port port: Int,
) -> Result(actor.Started(static_supervisor.Supervisor), actor.StartError) {
  let handler = fn(req: Request(Connection)) -> Response(ResponseData) {
    handle_request(db, req)
  }

  mist.new(handler)
  |> mist.bind("127.0.0.1")
  |> mist.port(port)
  |> mist.start()
}

fn handle_request(db: Db, req: Request(Connection)) -> Response(ResponseData) {
  case request.path_segments(req) {
    [] ->
      respond(
        200,
        template.dashboard(
          queries.list_runs(db),
          queries.list_conversations(db),
        ),
      )
    ["runs"] -> respond(200, template.dashboard(queries.list_runs(db), []))
    ["runs", run_id] ->
      respond(
        200,
        template.run_detail(run_id, queries.list_events(db, run_id:)),
      )
    ["conversations"] ->
      respond(200, template.dashboard([], queries.list_conversations(db)))
    ["conversations", id] ->
      respond(
        200,
        template.conversation_detail(id, queries.get_conversation(db, id:)),
      )
    _ -> respond(404, "<h1>404</h1><p>Not found</p>")
  }
}

fn respond(status: Int, body: String) -> Response(ResponseData) {
  response.new(status)
  |> response.prepend_header("content-type", "text/html; charset=utf-8")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(body)))
}
