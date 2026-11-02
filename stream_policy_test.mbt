///|
test "stream caller policy checks whole frame and preserves retry state" {
  let input =
    #|{"image_width":10,"image_height":10,"threshold":0.5,"metric":"iou","class_agnostic":false,"note":"🌙","limits":{"max_tiles":100,"max_detections":100},"tiles":[{"tile":{"id":0,"x":0,"y":0,"width":10,"height":10},"detections":[{"id":1,"image_id":1,"tile_id":0,"class_id":0,"score":0.9,"box":{"x1":1,"y1":1,"x2":5,"y2":5}}]}]}
  let first = "{\"frame\":1,\"input\":" + input + "}"
  let second = "{\"frame\":2,\"input\":" + input + "}"
  let policy : @moontile.JsonPolicy = {
    max_utf16_units: first.length(),
    max_tiles: 1,
    max_detections: 1,
  }
  let session = @moontile.StreamSession::new()
  let reference = @moontile.StreamSession::new()
  assert_true(
    session.process_line_with_policy(first, {
      ..policy,
      max_utf16_units: first.length() - 1,
    })
    is Err("JSON text limit exceeded"),
  )
  assert_true(
    session.process_line_with_policy(first, { ..policy, max_tiles: 0, })
    is Err("tile limit exceeded"),
  )
  assert_true(
    session.process_line_with_policy(first, { ..policy, max_detections: 0, })
    is Err("detection limit exceeded"),
  )
  assert_true(
    session.process_line_with_policy(first, { ..policy, max_tiles: -1, })
    is Err("JSON policy limits must be nonnegative"),
  )
  assert_true(session.last_frame() is None)
  assert_eq(
    session.process_line_with_policy(first, policy).unwrap(),
    reference.process_line(first).unwrap(),
  )
  assert_true(
    session.process_trace_line_with_policy(second, {
      ..policy,
      max_detections: 0,
    })
    is Err("detection limit exceeded"),
  )
  assert_true(session.last_frame() is Some(1))
  assert_eq(
    session.process_trace_line_with_policy(second, policy).unwrap(),
    reference.process_trace_line(second).unwrap(),
  )
  assert_true(session.process_line_with_policy(second, policy) is Err(_))
  assert_true(session.last_frame() is Some(2))
  session.reset()
  assert_true(session.process_trace_line_with_policy(first, policy) is Ok(_))
  assert_true(session.last_frame() is Some(1))
}

///|
test "stream policy accepts exact source length despite JSON reserialization" {
  let line =
    #|{"frame":1,"input":{"image_width":10,"image_height":10,"threshold":5e-1,"metric":"iou","class_agnostic":false,"tiles":[]}}
  let session = @moontile.StreamSession::new()
  assert_true(
    session.process_trace_line_with_policy(line, {
      max_utf16_units: line.length(),
      max_tiles: 0,
      max_detections: 0,
    })
    is Ok(_),
  )
}
