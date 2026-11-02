///|
test "caller policy bounds JSON text and cannot be relaxed by the request" {
  assert_eq("🌙".length(), 2)
  let source =
    #|{"image_width":10,"image_height":10,"threshold":0.5,"metric":"iou","class_agnostic":false,"note":"🌙","tiles":[{"tile":{"id":0,"x":0,"y":0,"width":10,"height":10},"detections":[{"id":1,"image_id":1,"tile_id":0,"class_id":0,"score":0.9,"box":{"x1":1,"y1":1,"x2":5,"y2":5}}]}]}
  let policy : @moontile.JsonPolicy = {
    max_utf16_units: source.length(),
    max_tiles: 1,
    max_detections: 1,
  }
  assert_eq(
    @moontile.process_json_with_policy(source, policy).unwrap(),
    @moontile.process_json(source).unwrap(),
  )
  assert_true(
    @moontile.process_json_with_policy(source, {
      ..policy,
      max_utf16_units: source.length() - 1,
    })
    is Err("JSON text limit exceeded"),
  )
  assert_true(
    @moontile.process_json_with_policy(source, { ..policy, max_tiles: 0, })
    is Err("tile limit exceeded"),
  )
  assert_true(
    @moontile.process_json_with_policy(source, { ..policy, max_detections: 0, })
    is Err("detection limit exceeded"),
  )
  for
    invalid in [
      { ..policy, max_utf16_units: -1, },
      { ..policy, max_tiles: -1, },
      { ..policy, max_detections: -1, },
    ] {
    assert_true(
      @moontile.process_json_with_policy(source, invalid)
      is Err("JSON policy limits must be nonnegative"),
    )
  }
  let loose_request = source.replace(
    old="\"tiles\":[",
    new="\"limits\":{\"max_tiles\":100,\"max_detections\":100},\"tiles\":[",
  )
  let longer_policy = { ..policy, max_utf16_units: loose_request.length(), }
  assert_true(
    @moontile.process_json_with_policy(loose_request, {
      ..longer_policy,
      max_tiles: 0,
    })
    is Err("tile limit exceeded"),
  )
  let strict_request = loose_request.replace(
    old="\"max_detections\":100",
    new="\"max_detections\":0",
  )
  assert_true(
    @moontile.process_json_with_policy(strict_request, longer_policy)
    is Err("detection limit exceeded"),
  )
  assert_true(
    @moontile.process_json_with_policy("{", { ..policy, max_utf16_units: 0, })
    is Err("JSON text limit exceeded"),
  )
}
