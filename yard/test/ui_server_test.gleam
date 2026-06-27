//// Integration test: observability UI HTTP server.
////
//// Starts the UI server and makes HTTP requests to verify it serves pages.
//// Requires: docker container running (bin/postgres.sh)

import gabsurd/client
import gleam/http/request
import gleam/http/response
import gleam/httpc
import gleam/int
import gleam/string
import gleeunit
import gleeunit/should
import testing
import yard/ui/server

pub fn main() {
  gleeunit.main()
}

fn with_server(test_fn: fn(Int) -> a) -> a {
  let port = 8390 + int.absolute_value(client.unique_integer()) % 100
  testing.with_pg_db(fn(db) {
    // Start the UI server — fail if it doesn't start
    let assert Ok(_) = server.start(db:, port:)
    // Give the server a moment to start
    timer_sleep(200)

    test_fn(port)
  })
}

@external(erlang, "timer", "sleep")
fn timer_sleep(ms: Int) -> Nil

fn http_get(url: String) -> Result(response.Response(String), Nil) {
  let assert Ok(req) = request.to(url)
  case httpc.send(req) {
    Ok(resp) -> Ok(resp)
    Error(_) -> Error(Nil)
  }
}

/// The dashboard page should be served at / with status 200.
pub fn dashboard_served_test() {
  with_server(fn(port) {
    case http_get("http://localhost:" <> int.to_string(port) <> "/") {
      Ok(resp) -> {
        should.equal(resp.status, 200)
        should.be_true(string.contains(resp.body, "Yard Dashboard"))
        should.be_true(string.contains(resp.body, "<html"))
      }
      Error(_) -> {
        // Server may not have started — try anyway, assertion will fail
        should.be_true(False)
      }
    }
  })
}

/// Unknown paths return 404 status.
pub fn not_found_test() {
  with_server(fn(port) {
    case
      http_get("http://localhost:" <> int.to_string(port) <> "/nonexistent")
    {
      Ok(resp) -> {
        should.equal(resp.status, 404)
      }
      Error(_) -> {
        should.be_true(False)
      }
    }
  })
}
