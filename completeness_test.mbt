///|
test "grid completion checks tile identities, geometry and retry" {
  let grid = @moontile.TileGrid::new(100, 60, 60, 60, 20, 0).unwrap()
  let config : @moontile.MergeConfig = {
    threshold: 0.5,
    metric: IoU,
    class_agnostic: false,
    strategy: Nms,
  }
  let acc = @moontile.TileAccumulator::new(100, 60, config).unwrap()
  let first : @moontile.TilePredictions = {
    tile: grid.get(0).unwrap(),
    transform: None,
    detections: [
      {
        id: 1,
        image_id: 1,
        tile_id: 0,
        class_id: 0,
        score: 0.8,
        box: { x1: 45.0, y1: 5.0, x2: 55.0, y2: 15.0, },
      },
    ],
  }
  let second : @moontile.TilePredictions = {
    tile: grid.get(1).unwrap(),
    transform: None,
    detections: [],
  }
  assert_true(acc.add_tile(first) is Ok(_))
  assert_true(acc.finish_grid(grid) is Err(_))
  assert_eq(acc.finish().unwrap().restored.length(), 1)
  assert_true(acc.add_tile(second) is Ok(_))
  let result = acc.finish_grid(grid).unwrap()
  assert_eq(result.restored.length(), 1)
  assert_eq(result.restored[0].box.x1, 45.0)
  assert_true(
    acc.finish_grid(@moontile.TileGrid::new(101, 60, 60, 60, 20, 0).unwrap())
    is Err(_),
  )
  acc.reset()
  assert_eq(acc.tile_count(), 0)
  assert_true(acc.finish_grid(grid) is Err(_))
  assert_true(acc.add_tiles([second, first]) is Ok(_))
  assert_true(acc.finish_grid(grid) is Ok(_))
  acc.reset()
  let incorrect = { ..second, tile: { ..second.tile, x: 39, }, }
  assert_true(acc.add_tiles([first, incorrect]) is Ok(_))
  assert_true(acc.finish_grid(grid) is Err(_))
  assert_eq(acc.tile_count(), 2)
  acc.reset()
  let unexpected = { ..second, tile: { ..second.tile, id: 9, }, }
  assert_true(acc.add_tiles([first, unexpected]) is Ok(_))
  assert_true(acc.finish_grid(grid) is Err(_))
  assert_true(acc.finish() is Ok(_))
  acc.reset()
  let mixed = {
    ..second,
    detections: [{ ..first.detections[0], id: 2, tile_id: 1, image_id: 2, }],
  }
  assert_true(acc.add_tiles([first, mixed]) is Ok(_))
  assert_true(acc.finish_grid(grid) is Err(_))
  assert_true(acc.finish() is Ok(_))
}

///|
test "JSON planned tiles check completeness and preserve downstream output" {
  let source =
    #|{"image_width":100,"image_height":60,"threshold":0.5,"metric":"iou","class_agnostic":false,"tile_plan":{"tile_width":60,"tile_height":60,"overlap_x":20,"overlap_y":0},"tiles":[{"tile":{"id":0,"x":0,"y":0,"width":60,"height":60},"detections":[{"id":1,"image_id":1,"tile_id":0,"class_id":0,"score":0.9,"box":{"x1":45,"y1":10,"x2":58,"y2":30}}]},{"tile":{"id":1,"x":40,"y":0,"width":60,"height":60},"detections":[]}]}
  let no_plan = source.replace(
    old="\"tile_plan\":{\"tile_width\":60,\"tile_height\":60,\"overlap_x\":20,\"overlap_y\":0},",
    new="",
  )
  assert_eq(
    @moontile.process_json(source).unwrap(),
    @moontile.process_json(no_plan).unwrap(),
  )
  assert_eq(
    @moontile.process_mbmot_json(source, 1).unwrap(),
    @moontile.process_mbmot_json(no_plan, 1).unwrap(),
  )
  let mapping =
    #|[{"class_id":0,"category_id":7}]
  assert_eq(
    @moontile.process_coco_json(source, mapping).unwrap(),
    @moontile.process_coco_json(no_plan, mapping).unwrap(),
  )
  let missing = source.replace(
    old=",{\"tile\":{\"id\":1,\"x\":40,\"y\":0,\"width\":60,\"height\":60},\"detections\":[]}",
    new="",
  )
  assert_true(@moontile.process_json(missing) is Err(_))
  assert_true(
    @moontile.process_json(
      source.replace(old="\"id\":1,\"x\":40", new="\"id\":1,\"x\":39"),
    )
    is Err(_),
  )
  assert_true(
    @moontile.process_json(
      source.replace(old="\"id\":1,\"x\":40", new="\"id\":9,\"x\":40"),
    )
    is Err(_),
  )
  assert_true(
    @moontile.process_json(
      source.replace(old="\"overlap_x\":20", new="\"overlap_x\":20.5"),
    )
    is Err(_),
  )
  assert_true(
    @moontile.process_json(
      source.replace(old="\"overlap_x\":20", new="\"overlap_x\":60"),
    )
    is Err(_),
  )
  let session = @moontile.StreamSession::new()
  assert_true(
    session.process_trace_line("{\"frame\":1,\"input\":" + missing + "}")
    is Err(_),
  )
  assert_true(session.last_frame() is None)
  assert_true(
    session.process_trace_line("{\"frame\":1,\"input\":" + source + "}")
    is Ok(_),
  )
}
