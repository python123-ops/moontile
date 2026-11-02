///|
async fn main {
  let args = @env.args()
  if args.length() != 2 {
    abort("usage: stream_policy FIXTURE.json")
  }
  let text = @fs.read_file(args[1]).text() catch {
    _ => abort("cannot read fixture")
  }
  let json = @json.parse(text) catch { _ => abort("invalid fixture JSON") }
  let requests = match json {
    Object(fields) =>
      match fields.get("requests") {
        Some(Array(values)) => values
        _ => abort("invalid requests")
      }
    _ => abort("invalid fixture")
  }
  if requests.length() == 0 {
    abort("empty fixture")
  }
  let regular = @moontile.StreamSession::new()
  let guarded = @moontile.StreamSession::new()
  let trace = @moontile.StreamSession::new()
  let guarded_trace = @moontile.StreamSession::new()
  let mut total_tiles = 0
  let mut total_detections = 0
  let mut detection_rejections = 0
  for request in requests {
    let groups = match request {
      Object(fields) =>
        match fields.get("input") {
          Some(Object(input)) =>
            match input.get("tiles") {
              Some(Array(values)) => values
              _ => abort("invalid tiles")
            }
          _ => abort("invalid input")
        }
      _ => abort("invalid frame")
    }
    let mut count = 0
    for group in groups {
      match group {
        Object(fields) =>
          match fields.get("detections") {
            Some(Array(values)) => count += values.length()
            _ => abort("invalid detections")
          }
        _ => abort("invalid tile group")
      }
    }
    let line = request.stringify()
    let policy : @moontile.JsonPolicy = {
      max_utf16_units: line.length(),
      max_tiles: groups.length(),
      max_detections: count,
    }
    let prior = guarded.last_frame()
    if guarded.process_line_with_policy(line, {
        ..policy,
        max_utf16_units: line.length() - 1,
      })
      is Ok(_) ||
      guarded.last_frame() != prior {
      abort("text limit changed frame state")
    }
    if count > 0 {
      if guarded.process_line_with_policy(line, {
          ..policy,
          max_detections: count - 1,
        })
        is Ok(_) ||
        guarded.last_frame() != prior {
        abort("detection limit changed frame state")
      }
      detection_rejections += 1
    }
    if guarded.process_line_with_policy(line, policy).unwrap() !=
      regular.process_line(line).unwrap() {
      abort("MBMOT stream output differs")
    }
    if guarded_trace.process_trace_line_with_policy(line, policy).unwrap() !=
      trace.process_trace_line(line).unwrap() {
      abort("trace stream output differs")
    }
    total_tiles += groups.length()
    total_detections += count
  }
  println(
    Json::object({
      "frames": requests.length().to_json(),
      "tiles": total_tiles.to_json(),
      "detections": total_detections.to_json(),
      "text_rejections": requests.length().to_json(),
      "detection_rejections": detection_rejections.to_json(),
      "outputs_identical": true.to_json(),
    }).stringify(),
  )
}
