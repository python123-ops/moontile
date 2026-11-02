///|
test "bounded accumulator rejects whole batches and retains limits on reuse" {
  let config : @moontile.MergeConfig = {
    threshold: 0.5,
    metric: IoU,
    class_agnostic: false,
    strategy: Nms,
  }
  assert_true(
    @moontile.TileAccumulator::new_limited(10, 10, config, {
      max_tiles: -1,
      max_detections: 2,
    })
    is Err(_),
  )
  assert_true(
    @moontile.TileAccumulator::new_limited(10, 10, config, {
      max_tiles: 2,
      max_detections: -1,
    })
    is Err(_),
  )
  let empty = @moontile.TileAccumulator::new_limited(10, 10, config, {
    max_tiles: 0,
    max_detections: 0,
  }).unwrap()
  assert_true(empty.add_tiles([]) is Ok(_))
  let first : @moontile.TilePredictions = {
    tile: { id: 0, x: 0, y: 0, width: 10, height: 10, },
    transform: None,
    detections: [
      {
        id: 1,
        image_id: 1,
        tile_id: 0,
        class_id: 0,
        score: 0.8,
        box: { x1: 1.0, y1: 1.0, x2: 5.0, y2: 5.0, },
      },
    ],
  }
  let second : @moontile.TilePredictions = {
    tile: { ..first.tile, id: 1, },
    transform: None,
    detections: [{ ..first.detections[0], id: 2, tile_id: 1, }],
  }
  assert_true(
    empty.add_tile({ ..first, detections: [], }) is Err("tile limit exceeded"),
  )
  let no_boxes = @moontile.TileAccumulator::new_limited(10, 10, config, {
    max_tiles: 1,
    max_detections: 0,
  }).unwrap()
  assert_true(no_boxes.add_tile(first) is Err("detection limit exceeded"))
  assert_true(no_boxes.add_tile({ ..first, detections: [], }) is Ok(_))
  assert_true(no_boxes.replace_tile(first) is Err("detection limit exceeded"))
  assert_eq(no_boxes.detection_count(), 0)
  let acc = @moontile.TileAccumulator::new_limited(10, 10, config, {
    max_tiles: 2,
    max_detections: 2,
  }).unwrap()
  let oversized = {
    ..second,
    detections: [second.detections[0], { ..second.detections[0], id: 3, }],
  }
  assert_true(
    acc.add_tiles([first, oversized]) is Err("detection limit exceeded"),
  )
  assert_eq(acc.tile_count(), 0)
  assert_eq(acc.detection_count(), 0)
  assert_true(acc.add_tiles([first, second]) is Ok(_))
  assert_true(
    acc.add_tile({ ..second, tile: { ..second.tile, id: 3, }, detections: [], })
    is Err("tile limit exceeded"),
  )
  assert_true(acc.replace_tile(oversized) is Err("detection limit exceeded"))
  assert_eq(acc.finish().unwrap().restored[1].id, 2)
  assert_true(
    acc.replace_tiles([{ ..first, detections: [], }, oversized]) is Ok(_),
  )
  assert_eq(acc.detection_count(), 2)
  let result = acc.finish_take().unwrap()
  assert_eq(result.restored.length(), 2)
  assert_eq(acc.tile_count(), 0)
  assert_true(
    acc.add_tiles([first, oversized]) is Err("detection limit exceeded"),
  )
  assert_true(acc.add_tiles([first, second]) is Ok(_))
  assert_true(acc.remove_tile(0) is Ok(_))
  assert_true(acc.replace_tile(oversized) is Ok(_))
  acc.reset()
  assert_true(
    acc.add_tiles([first, oversized]) is Err("detection limit exceeded"),
  )
  assert_eq(acc.tile_count(), 0)
}
