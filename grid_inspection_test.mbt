///|
test "inspection reports independent sorted samples and supports repair" {
  let grid = @moontile.TileGrid::new(100, 100, 60, 60, 20, 20).unwrap()
  let acc = @moontile.TileAccumulator::new(100, 100, {
    threshold: 0.5,
    metric: IoU,
    class_agnostic: false,
    strategy: Nms,
  }).unwrap()
  let base : @moontile.Detection = {
    id: 1,
    image_id: 1,
    tile_id: 0,
    class_id: 0,
    score: 0.5,
    box: { x1: 1.0, y1: 1.0, x2: 3.0, y2: 3.0, },
  }
  let first : @moontile.TilePredictions = {
    tile: grid.get(0).unwrap(),
    detections: [base],
    transform: None,
  }
  let second : @moontile.TilePredictions = {
    tile: { ..grid.get(1).unwrap(), x: 39, },
    detections: [{ ..base, id: 2, image_id: 2, tile_id: 1, }],
    transform: None,
  }
  acc.add_tiles([first, second]).unwrap()
  for id in [99, 73, 95, 12, 5, 10, 8] {
    acc
    .add_tile({
      tile: { id, x: 0, y: 0, width: 60, height: 60, },
      detections: [],
      transform: None,
    })
    .unwrap()
  }
  let report = acc.inspect_grid(grid, max_reported=3).unwrap()
  assert_eq(report.expected_tiles, 4)
  assert_eq(report.received_tiles, 9)
  assert_eq(report.missing_count, 2)
  assert_eq(report.mismatched_count, 1)
  assert_eq(report.unexpected_count, 7)
  assert_eq(report.missing_ids, [2, 3])
  assert_eq(report.mismatched_ids, [1])
  assert_eq(report.unexpected_ids, [5, 8, 10])
  assert_true(report.mixed_images)
  assert_true(!report.is_complete())
  assert_true(acc.finish_grid(grid) is Err(_))
  let zero = acc.inspect_grid(grid, max_reported=0).unwrap()
  assert_eq(zero.unexpected_count, 7)
  assert_eq(zero.missing_ids.length(), 0)
  assert_eq(zero.mismatched_ids.length(), 0)
  assert_eq(zero.unexpected_ids.length(), 0)
  assert_true(acc.inspect_grid(grid, max_reported=-1) is Err(_))
  assert_true(acc.inspect_grid(grid, max_reported=10001) is Err(_))
  let wrong_grid = @moontile.TileGrid::new(101, 100, 60, 60, 20, 20).unwrap()
  assert_true(acc.inspect_grid(wrong_grid) is Err(_))
  report.unexpected_ids.clear()
  assert_eq(acc.inspect_grid(grid, max_reported=3).unwrap().unexpected_ids, [
    5, 8, 10,
  ])
  for id in [99, 73, 95, 12, 5, 10, 8] {
    acc.remove_tile(id).unwrap()
  }
  acc
  .replace_tile({
    ..second,
    tile: grid.get(1).unwrap(),
    detections: [{ ..base, id: 2, image_id: 1, tile_id: 1, }],
  })
  .unwrap()
  for id in [2, 3] {
    acc
    .add_tile({ tile: grid.get(id).unwrap(), detections: [], transform: None, })
    .unwrap()
  }
  let complete = acc.inspect_grid(grid).unwrap()
  assert_true(complete.is_complete())
  assert_eq(complete.missing_count, 0)
  assert_eq(complete.mismatched_count, 0)
  assert_eq(complete.unexpected_count, 0)
  assert_true(acc.finish_grid(grid) is Ok(_))
}

///|
test "inspection limits samples for a million planned windows" {
  let grid = @moontile.TileGrid::new(1000, 1000, 1, 1, 0, 0).unwrap()
  let acc = @moontile.TileAccumulator::new(1000, 1000, {
    threshold: 0.5,
    metric: IoU,
    class_agnostic: false,
    strategy: Nms,
  }).unwrap()
  let report = acc.inspect_grid(grid, max_reported=3).unwrap()
  assert_eq(report.expected_tiles, 1000000)
  assert_eq(report.received_tiles, 0)
  assert_eq(report.missing_count, 1000000)
  assert_eq(report.missing_ids, [0, 1, 2])
  assert_true(!report.is_complete())
}

///|
test "inspection selects smallest unexpected IDs independent of arrival order" {
  let grid = @moontile.TileGrid::new(1, 1, 1, 1, 0, 0).unwrap()
  let acc = @moontile.TileAccumulator::new(1, 1, {
    threshold: 0.5,
    metric: IoU,
    class_agnostic: false,
    strategy: Nms,
  }).unwrap()
  let groups : Array[@moontile.TilePredictions] = []
  for id = 1000; id >= 1; id = id - 1 {
    groups.push({
      tile: { id, x: 0, y: 0, width: 1, height: 1, },
      detections: [],
      transform: None,
    })
  }
  acc.add_tiles(groups).unwrap()
  let report = acc.inspect_grid(grid, max_reported=10).unwrap()
  assert_eq(report.missing_count, 1)
  assert_eq(report.unexpected_count, 1000)
  assert_eq(report.unexpected_ids, [1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
  assert_eq(
    acc.inspect_grid(grid, max_reported=10000).unwrap().unexpected_ids.length(),
    1000,
  )
}
