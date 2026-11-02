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
  self.process_line_impl(source, None)
}

///|
/// Process one MBMOT frame using caller limits. The UTF-16 ceiling applies
/// to the complete {frame,input} line, excluding any transport newline.
/// Errors leave the session's last accepted frame unchanged.
pub fn StreamSession::process_line_with_policy(
  self : StreamSession,
  source : String,
  policy : JsonPolicy,
) -> Result[String, String] {
  self.process_line_impl(source, Some(policy))
}

///|
fn StreamSession::process_line_impl(
  self : StreamSession,
  source : String,
  policy : JsonPolicy?,
) -> Result[String, String] {
  match check_stream_policy(source, policy) {
    Ok(_) => ()
    Err(message) => return Err(message)
  }
  let input = match parse_stream_input(source, self.last_frame) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  let nested = input.input.stringify()
  let result = match policy {
    None => process_mbmot_json(nested, input.frame)
    Some(value) =>
      process_mbmot_json_with_policy(nested, input.frame, {
        ..value,
        max_utf16_units: nested.length(),
      })
  }
  let output = match result {
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
  self.process_trace_line_impl(source, None)
}

///|
/// Process one trace frame with a caller policy. Text length covers the full
/// {frame,input} line; rejected frames do not advance the shared frame counter.
pub fn StreamSession::process_trace_line_with_policy(
  self : StreamSession,
  source : String,
  policy : JsonPolicy,
) -> Result[String, String] {
  self.process_trace_line_impl(source, Some(policy))
}

///|
fn StreamSession::process_trace_line_impl(
  self : StreamSession,
  source : String,
  policy : JsonPolicy?,
) -> Result[String, String] {
  match check_stream_policy(source, policy) {
    Ok(_) => ()
    Err(message) => return Err(message)
  }
  let input = match parse_stream_input(source, self.last_frame) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  let nested = input.input.stringify()
  let nested_policy = match policy {
    None => None
    Some(value) => Some({ ..value, max_utf16_units: nested.length(), })
  }
  let processed = match process_data_with_policy(nested, nested_policy) {
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

///|
// Enforce the original envelope length before parsing or reserializing it.
fn check_stream_policy(
  source : String,
  policy : JsonPolicy?,
) -> Result[Unit, String] {
  match policy {
    None => Ok(())
    Some(value) => {
      if value.max_utf16_units < 0 ||
        value.max_tiles < 0 ||
        value.max_detections < 0 {
        return Err("JSON policy limits must be nonnegative")
      }
      if source.length() > value.max_utf16_units {
        return Err("JSON text limit exceeded")
      }
      Ok(())
    }
  }
}
