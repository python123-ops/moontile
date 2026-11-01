///|
struct StreamInput {
  frame : Int
  input : Json
} derive(FromJson)

///|
pub extend StreamInput with @json.FromJson::{from_json}

///|
/// Stateful validator for a single ordered stream of tile prediction frames.
pub struct StreamSession {
  mut last_frame : Int?
}

///|
/// Create a session without an accepted frame.
pub fn StreamSession::new() -> StreamSession {
  { last_frame: None, }
}

///|
/// The most recently accepted frame, or None before the first frame.
pub fn StreamSession::last_frame(self : StreamSession) -> Int? {
  self.last_frame
}

///|
/// Clear the accepted frame; the next successful input may start a new stream.
pub fn StreamSession::reset(self : StreamSession) -> Unit {
  self.last_frame = None
}

///|
// Validate the common frame envelope before processing either output format.
fn parse_stream_input(
  source : String,
  last_frame : Int?,
) -> Result[StreamInput, String] {
  let json = @json.parse(source) catch { _ => return Err("invalid JSON") }
  let input : StreamInput = @json.from_json(json) catch {
    _ => return Err("invalid stream fields")
  }
  if !integer_fields_match(json, [("frame", input.frame)]) {
    return Err("frame must be an integer")
  }
  if input.frame <= 0 {
    return Err("frame must be positive")
  }
  match last_frame {
    Some(previous) if input.frame <= previous =>
      return Err(
        "frame must increase: previous \{previous}, received \{input.frame}",
      )
    _ => ()
  }
  Ok(input)
}

///|
/// Convert one JSON object {frame, input} into an MBMOT replay JSON line.
/// Frame numbers must be positive and strictly increase. An invalid frame does
/// not change the session, so callers may correct it and retry.
pub fn StreamSession::process_line(
  self : StreamSession,
  source : String,
) -> Result[String, String] {
  let input = match parse_stream_input(source, self.last_frame) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  let output = match process_mbmot_json(input.input.stringify(), input.frame) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  self.last_frame = Some(input.frame)
  Ok(output)
}

///|
/// Process one frame and return {frame, result}, where result contains the
/// same restored, kept and suppressed arrays as process_json. Detections in
/// a frame must have one image ID. Errors leave the session unchanged.
/// This shares the frame counter with process_line.
pub fn StreamSession::process_trace_line(
  self : StreamSession,
  source : String,
) -> Result[String, String] {
  let input = match parse_stream_input(source, self.last_frame) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  let processed = match process_data(input.input.stringify()) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  if !single_image(processed.restored) {
    return Err("one frame cannot contain multiple image IDs")
  }
  let output = Json::object({
    "frame": input.frame.to_json(),
    "result": pipeline_result_json(processed),
  }).stringify()
  self.last_frame = Some(input.frame)
  Ok(output)
}
