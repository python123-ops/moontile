///|
extern "C" fn exit_process(code : Int) = "exit"

///|
fn parse_stream_policy(
  args : Array[String],
) -> Result[@moontile.JsonPolicy, String] {
  let max_units = @string.parse_int(args[3], base=10) catch {
    _ => return Err("policy values must be nonnegative 32-bit integers")
  }
  let max_tiles = @string.parse_int(args[4], base=10) catch {
    _ => return Err("policy values must be nonnegative 32-bit integers")
  }
  let max_detections = @string.parse_int(args[5], base=10) catch {
    _ => return Err("policy values must be nonnegative 32-bit integers")
  }
  if max_units < 0 || max_tiles < 0 || max_detections < 0 {
    return Err("policy values must be nonnegative 32-bit integers")
  }
  Ok({ max_utf16_units: max_units, max_tiles, max_detections, })
}

///|
async fn main {
  let args = @env.args()
  if args.length() >= 2 &&
    (args[1] == "--mbmot-stream" || args[1] == "--trace-stream") {
    if args.length() != 2 && !(args.length() == 6 && args[2] == "--policy") {
      @stdio.stderr.write(
        "usage: moontile --mbmot-stream|--trace-stream [--policy MAX_UTF16 MAX_TILES MAX_DETECTIONS]\n",
      )
      exit_process(2)
      return
    }
    let policy = if args.length() == 6 {
      match parse_stream_policy(args) {
        Ok(value) => Some(value)
        Err(message) => {
          @stdio.stderr.write(message + "\n")
          exit_process(2)
          return
        }
      }
    } else {
      None
    }
    let session = @moontile.StreamSession::new()
    let mut line_number = 0
    while @stdio.stdin.read_until("\n") is Some(line) {
      line_number += 1
      let result = match (args[1], policy) {
        ("--trace-stream", Some(value)) =>
          session.process_trace_line_with_policy(line.to_string(), value)
        ("--trace-stream", None) => session.process_trace_line(line.to_string())
        (_, Some(value)) =>
          session.process_line_with_policy(line.to_string(), value)
        (_, None) => session.process_line(line.to_string())
      }
      match result {
        Ok(output) => @stdio.stdout.write(output + "\n")
        Err(message) => {
          @stdio.stderr.write("line \{line_number}: " + message + "\n")
          exit_process(2)
          return
        }
      }
    }
    return
  }
  if args.length() != 2 &&
    !(args.length() == 3 && (args[2] == "--plan" || args[2] == "--inspect-grid")) &&
    !(args.length() == 4 &&
    (
      args[2] == "--coco-map" ||
      args[2] == "--mbmot-frame" ||
      args[2] == "--inspect-grid"
    )) {
    @stdio.stderr.write(
      "usage: moontile INPUT.json [--plan | --inspect-grid [LIMIT] | --coco-map MAPPING.json | --mbmot-frame FRAME] | moontile --mbmot-stream|--trace-stream [--policy MAX_UTF16 MAX_TILES MAX_DETECTIONS]\n",
    )
    exit_process(2)
    return
  }
  let content = @fs.read_file(args[1]).text() catch {
    _ => {
      @stdio.stderr.write("cannot read UTF-8 input\n")
      exit_process(2)
      return
    }
  }
  let result = if args.length() >= 3 && args[2] == "--inspect-grid" {
    let limit = if args.length() == 4 {
      @string.parse_int(args[3], base=10) catch {
        _ => {
          @stdio.stderr.write("max_reported must be an integer in [0,10000]\n")
          exit_process(2)
          return
        }
      }
    } else {
      100
    }
    @moontile.inspect_grid_json(content, max_reported=limit)
  } else if args.length() == 3 {
    @moontile.plan_json(content)
  } else if args.length() == 4 && args[2] == "--coco-map" {
    let mapping = @fs.read_file(args[3]).text() catch {
      _ => {
        @stdio.stderr.write("cannot read UTF-8 mapping\n")
        exit_process(2)
        return
      }
    }
    @moontile.process_coco_json(content, mapping)
  } else if args.length() == 4 {
    let frame = @string.parse_int(args[3], base=10) catch {
      _ => {
        @stdio.stderr.write("frame must be a positive integer\n")
        exit_process(2)
        return
      }
    }
    @moontile.process_mbmot_json(content, frame)
  } else {
    @moontile.process_json(content)
  }
  match result {
    Ok(output) => @stdio.stdout.write(output + "\n")
    Err(message) => {
      @stdio.stderr.write(message + "\n")
      exit_process(2)
    }
  }
}
