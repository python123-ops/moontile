///|
extern "C" fn exit_process(code : Int) = "exit"

///|
async fn main {
  let args = @env.args()
  if args.length() != 2 &&
    !(args.length() == 4 &&
    (args[2] == "--coco-map" || args[2] == "--mbmot-frame")) {
    @stdio.stderr.write(
      "usage: moontile INPUT.json [--coco-map MAPPING.json | --mbmot-frame FRAME]\n",
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
  let result = if args.length() == 4 && args[2] == "--coco-map" {
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
