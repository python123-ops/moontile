///|
extern "C" fn exit_process(code : Int) = "exit"

///|
fn parse_stream_policy(
  args : Array[String],
  start : Int,
) -> Result[@moontile.JsonPolicy, String] {
  let max_units = @string.parse_int(args[start], base=10) catch {
    _ => return Err("policy values must be nonnegative 32-bit integers")
  }
  let max_tiles = @string.parse_int(args[start + 1], base=10) catch {
    _ => return Err("policy values must be nonnegative 32-bit integers")
  }
  let max_detections = @string.parse_int(args[start + 2], base=10) catch {
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
    let mut policy : @moontile.JsonPolicy? = None
    let mut max_bytes : Int? = None
    let mut index = 2
    while index < args.length() {
      if args[index] == "--policy" &&
        policy is None &&
        index + 3 < args.length() {
        policy = match parse_stream_policy(args, index + 1) {
          Ok(value) => Some(value)
          Err(message) => {
            @stdio.stderr.write(message + "\n")
            exit_process(2)
            return
          }
        }
        index += 4
      } else if args[index] == "--max-line-bytes" &&
        max_bytes is None &&
        index + 1 < args.length() {
        let limit = @string.parse_int(args[index + 1], base=10) catch {
          _ => {
            @stdio.stderr.write(
              "max-line-bytes must be a nonnegative 32-bit integer\n",
            )
            exit_process(2)
            return
          }
        }
        if limit < 0 {
          @stdio.stderr.write(
            "max-line-bytes must be a nonnegative 32-bit integer\n",
          )
          exit_process(2)
          return
        }
        max_bytes = Some(limit)
        index += 2
      } else {
        @stdio.stderr.write(
          "usage: moontile --mbmot-stream|--trace-stream [--policy MAX_UTF16 MAX_TILES MAX_DETECTIONS] [--max-line-bytes N]\n",
        )
        exit_process(2)
        return
      }
    }
    let session = @moontile.StreamSession::new()
    match max_bytes {
      Some(limit) => run_bounded_stream(session, args[1], policy, limit)
      None => {
        let mut line_number = 0
        while @stdio.stdin.read_until("\n") is Some(line) {
          line_number += 1
          if !emit_stream_line(
              session,
              args[1],
              policy,
              line.to_string(),
              line_number,
            ) {
            return
          }
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
      "usage: moontile INPUT.json [--plan | --inspect-grid [LIMIT] | --coco-map MAPPING.json | --mbmot-frame FRAME] | moontile --mbmot-stream|--trace-stream [--policy MAX_UTF16 MAX_TILES MAX_DETECTIONS] [--max-line-bytes N]\n",
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

///|
async fn emit_stream_line(
  session : @moontile.StreamSession,
  mode : String,
  policy : @moontile.JsonPolicy?,
  line : String,
  line_number : Int,
) -> Bool {
  let result = match (mode, policy) {
    ("--trace-stream", Some(value)) =>
      session.process_trace_line_with_policy(line, value)
    ("--trace-stream", None) => session.process_trace_line(line)
    (_, Some(value)) => session.process_line_with_policy(line, value)
    (_, None) => session.process_line(line)
  }
  match result {
    Ok(output) => {
      @stdio.stdout.write(output + "\n")
      true
    }
    Err(message) => {
      @stdio.stderr.write("line \{line_number}: " + message + "\n")
      exit_process(2)
      false
    }
  }
}

///|
// Decode only complete, bounded UTF-8 lines; the fixed read buffer is separate.
async fn run_bounded_stream(
  session : @moontile.StreamSession,
  mode : String,
  policy : @moontile.JsonPolicy?,
  max_bytes : Int,
) -> Unit {
  let chunk = FixedArray::make(4096, b'\x00')
  let pending : Array[Byte] = []
  let mut line_number = 1
  while true {
    let count = @stdio.stdin.read(chunk)
    if count == 0 {
      break
    }
    for index = 0; index < count; index = index + 1 {
      let byte = chunk[index]
      if byte == b'\n' {
        let line = @utf8.decode(Bytes::from_array(pending[:])) catch {
          _ => {
            @stdio.stderr.write("line \{line_number}: invalid UTF-8\n")
            exit_process(2)
            return
          }
        }
        if !emit_stream_line(session, mode, policy, line, line_number) {
          return
        }
        pending.clear()
        line_number += 1
      } else {
        if pending.length() >= max_bytes {
          @stdio.stderr.write("line \{line_number}: line byte limit exceeded\n")
          exit_process(2)
          return
        }
        pending.push(byte)
      }
    }
  }
  if pending.length() > 0 {
    let line = @utf8.decode(Bytes::from_array(pending[:])) catch {
      _ => {
        @stdio.stderr.write("line \{line_number}: invalid UTF-8\n")
        exit_process(2)
        return
      }
    }
    let _ = emit_stream_line(session, mode, policy, line, line_number)
  }
}
