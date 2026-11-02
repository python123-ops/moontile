///|
/// Return the same JSON payload as the native CLI; failures are JSON objects.
pub fn moontile_process(source : String) -> String {
  match @moontile.process_json(source) {
    Ok(output) => output
    Err(message) => Json::object({ "error": message.to_json() }).stringify()
  }
}

///|
/// Plan windows using the same JSON contract as the native CLI.
pub fn moontile_plan(source : String) -> String {
  match @moontile.plan_json(source) {
    Ok(output) => output
    Err(message) => Json::object({ "error": message.to_json() }).stringify()
  }
}

///|
/// Inspect planned windows; failures are JSON objects.
pub fn moontile_inspect(source : String) -> String {
  match @moontile.inspect_grid_json(source) {
    Ok(output) => output
    Err(message) => Json::object({ "error": message.to_json() }).stringify()
  }
}
