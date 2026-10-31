///|
extern "C" fn exit_process(code : Int) = "exit"

///|
async fn main {
  let args = @env.args()
  if args.length() != 2 {
    @stdio.stderr.write("usage: moontile INPUT.json\n")
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
  match @moontile.process_json(content) {
    Ok(output) => @stdio.stdout.write(output + "\n")
    Err(message) => {
      @stdio.stderr.write(message + "\n")
      exit_process(2)
    }
  }
}
