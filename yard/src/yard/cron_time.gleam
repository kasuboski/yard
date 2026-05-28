//// Cron time conversion helpers.
////
//// Converts between birl Time and automata DateTime types.
//// Shared between cron_engine (production) and cron_engine_test (tests).

import automata/schedule/ast as schedule_ast
import birl
import gleam/int

/// Convert a birl Time to automata ValidDateTime.
pub fn birl_to_valid_datetime(t: birl.Time) -> schedule_ast.ValidDateTime {
  let birl.Day(year: y, month: m, date: d) = birl.get_day(t)
  let birl.TimeOfDay(hour: h, minute: min, second: s, ..) =
    birl.get_time_of_day(t)
  let assert Ok(vdt) =
    schedule_ast.try_valid_datetime(
      year: y,
      month: m,
      day: d,
      hour: h,
      minute: min,
      second: s,
    )
  vdt
}

/// Convert an automata DateTime to a unix timestamp.
pub fn datetime_to_unix(dt: schedule_ast.DateTime) -> Int {
  let schedule_ast.DateTime(
    date: schedule_ast.Date(year: y, month: m, day: d),
    time: schedule_ast.Time(hour: h, minute: min, second: s),
  ) = dt
  // birl.from_naive expects "YYYY-MM-DDTHH:MM:SS" (no Z suffix)
  let birl_str =
    int.to_string(y)
    <> "-"
    <> pad2(m)
    <> "-"
    <> pad2(d)
    <> "T"
    <> pad2(h)
    <> ":"
    <> pad2(min)
    <> ":"
    <> pad2(s)
  case birl.from_naive(birl_str) {
    Ok(t) -> birl.to_unix(t)
    Error(_) ->
      // Far future to avoid immediate firing on parse error
      birl.to_unix(birl.utc_now()) + 86_400 * 365
  }
}

fn pad2(n: Int) -> String {
  case n < 10 {
    True -> "0" <> int.to_string(n)
    False -> int.to_string(n)
  }
}
