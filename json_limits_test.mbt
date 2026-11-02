///|
test "JSON capacity limits cover merges, exports, inspection and streams" {
  let base =
    #|{"image_width":100,"image_height":60,"threshold":0.5,"metric":"iou","class_agnostic":false,"tile_plan":{"tile_width":60,"tile_height":60,"overlap_x":20,"overlap_y":0},"tiles":[{"tile":{"id":0,"x":0,"y":0,"width":60,"height":60},"detections":[{"id":1,"image_id":1,"tile_id":0,"class_id":0,"score":0.9,"box":{"x1":45,"y1":10,"x2":58,"y2":30}}]},{"tile":{"id":1,"x":40,"y":0,"width":60,"height":60},"detections":[{"id":2,"image_id":1,"tile_id":1,"class_id":0,"score":0.8,"box":{"x1":5,"y1":10,"x2":18,"y2":30}}]}]}
  let bounded = base.replace(
    old="\"tiles\":[",
    new="\"limits\":{\"max_tiles\":2,\"max_detections\":2},\"tiles\":[",
  )
  let limited_tiles = bounded.replace(
    old="\"max_tiles\":2",
    new="\"max_tiles\":1",
  )
  let limited_boxes = bounded.replace(
    old="\"max_detections\":2",
    new="\"max_detections\":1",
  )
  assert_eq(
    @moontile.process_json(bounded).unwrap(),
    @moontile.process_json(base).unwrap(),
  )
  assert_eq(
    @moontile.inspect_grid_json(bounded).unwrap(),
    @moontile.inspect_grid_json(base).unwrap(),
  )
  let mapping =
    #|[{"class_id":0,"category_id":7}]
  assert_eq(
    @moontile.process_coco_json(bounded, mapping).unwrap(),
    @moontile.process_coco_json(base, mapping).unwrap(),
  )
  assert_eq(
    @moontile.process_mbmot_json(bounded, 1).unwrap(),
    @moontile.process_mbmot_json(base, 1).unwrap(),
  )
  assert_true(
    @moontile.process_json(limited_tiles) is Err("tile limit exceeded"),
  )
  assert_true(
    @moontile.process_json(limited_boxes) is Err("detection limit exceeded"),
  )
  assert_true(
    @moontile.inspect_grid_json(limited_boxes)
    is Err("detection limit exceeded"),
  )
  assert_true(
    @moontile.process_coco_json(limited_boxes, mapping)
    is Err("detection limit exceeded"),
  )
  assert_true(
    @moontile.process_mbmot_json(limited_boxes, 1)
    is Err("detection limit exceeded"),
  )
  for
    value in [
      "null", "{}", "{\"max_tiles\":2}", "{\"max_tiles\":2.5,\"max_detections\":2}",
      "{\"max_tiles\":2,\"max_detections\":2.5}", "{\"max_tiles\":2147483648,\"max_detections\":2}",
      "{\"max_tiles\":-1,\"max_detections\":2}", "{\"max_tiles\":2,\"max_detections\":-1}",
    ] {
    let invalid = base.replace(
      old="\"tiles\":[",
      new="\"limits\":" + value + ",\"tiles\":[",
    )
    assert_true(@moontile.process_json(invalid) is Err(_))
  }
  let session = @moontile.StreamSession::new()
  assert_true(
    session.process_line("{\"frame\":1,\"input\":" + limited_boxes + "}")
    is Err(_),
  )
  assert_true(session.last_frame() is None)
  assert_true(
    session.process_line("{\"frame\":1,\"input\":" + bounded + "}") is Ok(_),
  )
}

///|
test "JSON capacity limits accept empty input and integral numeric spelling" {
  let empty =
    #|{"image_width":10,"image_height":10,"threshold":0.5,"metric":"iou","class_agnostic":false,"limits":{"max_tiles":0.0,"max_detections":0e0},"tiles":[]}
  assert_true(@moontile.process_json(empty) is Ok(_))
  let one_empty = empty.replace(
    old="\"tiles\":[]",
    new="\"tiles\":[{\"tile\":{\"id\":0,\"x\":0,\"y\":0,\"width\":10,\"height\":10},\"detections\":[]}]",
  )
  assert_true(@moontile.process_json(one_empty) is Err("tile limit exceeded"))
}
