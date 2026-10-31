///|
/// Return the same JSON payload as the native CLI; failures are JSON objects.
pub fn moontile_process(source : String) -> String {
  match @moontile.process_json(source) {
    Ok(output) => output
    Err(message) => Json::object({ "error": message.to_json() }).stringify()
  }
}
