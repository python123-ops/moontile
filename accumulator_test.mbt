///|
test "accumulator accepts tiles atomically and snapshots global merge" {
  let first : @moontile.TilePredictions = {
    tile: { id: 0, x: 0, y: 0, width: 60, height: 60, },
    detections: [
      {
        id: 1,
        image_id: 1,
        tile_id: 0,
        class_id: 0,
        score: 0.95,
        box: { x1: 45.0, y1: 10.0, x2: 60.0, y2: 30.0, },
      },
    ],
    transform: None,
  }
  let record : @moontile.Detection = {
    id: 2,
    image_id: 1,
    tile_id: 1,
    class_id: 0,
    score: 0.85,
    box: { x1: 10.0, y1: 10.0, x2: 30.0, y2: 30.0, },
  }
  let second : @moontile.TilePredictions = {
    tile: { id: 1, x: 40, y: 0, width: 60, height: 60, },
    detections: [record],
    transform: None,
  }
  let strategies : Array[@moontile.MergeStrategy] = [Nms, GreedyNmm]
  for strategy in strategies {
    let config : @moontile.MergeConfig = {
      threshold: 0.5,
      metric: IoS,
      class_agnostic: false,
      strategy,
    }
    let accumulator = @moontile.TileAccumulator::new(100, 60, config).unwrap()
    assert_eq(accumulator.tile_count(), 0)
    assert_eq(accumulator.detection_count(), 0)
    assert_true(accumulator.add_tile(first) is Ok(_))
    let early = accumulator.finish().unwrap()
    assert_eq(early.restored.length(), 1)
    let invalid = {
      ..second,
      detections: [record, { ..record, id: 3, tile_id: 0, }],
    }
    assert_true(accumulator.add_tile(invalid) is Err(_))
    let duplicate_existing = {
      ..second,
      detections: [record, { ..record, id: 1, }],
    }
    assert_true(accumulator.add_tile(duplicate_existing) is Err(_))
    let duplicate_in_tile = { ..second, detections: [record, record], }
    assert_true(accumulator.add_tile(duplicate_in_tile) is Err(_))
    assert_eq(accumulator.tile_count(), 1)
    assert_eq(accumulator.detection_count(), 1)
    assert_true(accumulator.add_tile(second) is Ok(_))
    assert_true(accumulator.add_tile(second) is Err(_))
    assert_eq(accumulator.tile_count(), 2)
    assert_eq(accumulator.detection_count(), 2)
    let result = accumulator.finish().unwrap()
    let batch = @moontile.process_tiles(100, 60, [first, second], config).unwrap()
    assert_eq(result.restored.length(), 2)
    assert_eq(result.merged.kept.length(), 1)
    assert_eq(result.merged.kept[0].box.x2, batch.merged.kept[0].box.x2)
    assert_eq(result.merged.suppressed[0].suppressed_id, 2)
    assert_eq(result.merged.suppressed[0].kept_id, 1)
    assert_eq(early.restored.length(), 1)
    result.restored.clear()
    result.merged.kept.clear()
    let unchanged = accumulator.finish().unwrap()
    assert_eq(unchanged.restored.length(), 2)
    assert_eq(unchanged.merged.kept.length(), 1)
    accumulator.reset()
    assert_eq(accumulator.tile_count(), 0)
    assert_eq(accumulator.detection_count(), 0)
    assert_true(accumulator.add_tile(first) is Ok(_))
  }
}

///|
test "accumulator validates empty tiles and preserves tie arrival order" {
  let config : @moontile.MergeConfig = {
    threshold: 0.5,
    metric: IoU,
    class_agnostic: false,
    strategy: Nms,
  }
  assert_true(@moontile.TileAccumulator::new(0, 10, config) is Err(_))
  assert_true(
    @moontile.TileAccumulator::new(10, 10, { ..config, threshold: 0.0 / 0.0, })
    is Err(_),
  )
  let accumulator = @moontile.TileAccumulator::new(10, 10, config).unwrap()
  let empty : @moontile.TilePredictions = {
    tile: { id: 3, x: 0, y: 0, width: 10, height: 10, },
    detections: [],
    transform: Some({
      scale_x: 0.0,
      scale_y: 1.0,
      pad_x: 0.0,
      pad_y: 0.0,
      clip: false,
    }),
  }
  assert_true(accumulator.add_tile(empty) is Err(_))
  assert_eq(accumulator.tile_count(), 0)
  assert_true(
    accumulator.add_tile({
      ..empty,
      tile: { ..empty.tile, width: 11, },
      transform: None,
    })
    is Err(_),
  )
  assert_eq(accumulator.tile_count(), 0)
  assert_true(accumulator.add_tile({ ..empty, transform: None, }) is Ok(_))
  let first : @moontile.TilePredictions = {
    tile: { id: 1, x: 0, y: 0, width: 10, height: 10, },
    transform: None,
    detections: [
      {
        id: 8,
        image_id: 1,
        tile_id: 1,
        class_id: 0,
        score: 0.5,
        box: { x1: 1.0, y1: 1.0, x2: 4.0, y2: 4.0, },
      },
    ],
  }
  let second : @moontile.TilePredictions = {
    tile: { ..first.tile, id: 0, },
    transform: None,
    detections: [{ ..first.detections[0], id: 9, tile_id: 0, }],
  }
  assert_true(accumulator.add_tile(first) is Ok(_))
  assert_true(accumulator.add_tile(second) is Ok(_))
  let result = accumulator.finish().unwrap()
  assert_eq(accumulator.tile_count(), 3)
  assert_eq(result.merged.kept[0].id, 8)
  assert_eq(result.merged.suppressed[0].suppressed_id, 9)
}

///|
test "batch addition rolls back all tiles and permits retry" {
  let first : @moontile.TilePredictions = {
    tile: { id: 0, x: 0, y: 0, width: 10, height: 10, },
    detections: [
      {
        id: 1,
        image_id: 1,
        tile_id: 0,
        class_id: 0,
        score: 0.5,
        box: { x1: 1.0, y1: 1.0, x2: 5.0, y2: 5.0, },
      },
    ],
    transform: None,
  }
  let second : @moontile.TilePredictions = {
    tile: { ..first.tile, id: 1, },
    detections: [{ ..first.detections[0], id: 2, tile_id: 1, }],
    transform: Some({
      scale_x: 2.0,
      scale_y: 2.0,
      pad_x: 0.0,
      pad_y: 0.0,
      clip: false,
    }),
  }
  let third : @moontile.TilePredictions = {
    tile: { ..first.tile, id: 2, },
    detections: [{ ..first.detections[0], id: 3, tile_id: 2, }],
    transform: None,
  }
  for strategy in [@moontile.MergeStrategy::Nms, GreedyNmm] {
    let config : @moontile.MergeConfig = {
      threshold: 0.1,
      metric: IoU,
      class_agnostic: false,
      strategy,
    }
    let acc = @moontile.TileAccumulator::new(10, 10, config).unwrap()
    assert_true(acc.add_tile(first) is Ok(_))
    assert_true(acc.add_tiles([]) is Ok(_))
    assert_true(acc.add_tiles([second, first]) is Err(_))
    assert_true(acc.add_tiles([second, second]) is Err(_))
    assert_true(
      acc.add_tiles([
        second,
        { ..third, detections: [{ ..third.detections[0], id: 2, }], },
      ])
      is Err(_),
    )
    assert_true(
      acc.add_tiles([
        second,
        { ..third, detections: [{ ..third.detections[0], id: 1, }], },
      ])
      is Err(_),
    )
    assert_true(
      acc.add_tiles([
        second,
        { ..third, detections: [], tile: { ..third.tile, width: 11, }, },
      ])
      is Err(_),
    )
    assert_true(
      acc.add_tiles([
        second,
        {
          ..third,
          detections: [],
          transform: Some({
            scale_x: 0.0,
            scale_y: 1.0,
            pad_x: 0.0,
            pad_y: 0.0,
            clip: false,
          }),
        },
      ])
      is Err(_),
    )
    assert_eq(acc.tile_count(), 1)
    assert_eq(acc.detection_count(), 1)
    assert_eq(acc.finish().unwrap().restored[0].id, 1)
    assert_true(acc.add_tiles([second, third]) is Ok(_))
    assert_eq(acc.tile_count(), 3)
    assert_eq(acc.detection_count(), 3)
    let actual = acc.finish().unwrap()
    let expected = @moontile.process_tiles(
      10,
      10,
      [first, second, third],
      config,
    ).unwrap()
    assert_eq(actual.restored.length(), 3)
    assert_eq(actual.restored[1].box.x2, 2.5)
    assert_eq(actual.restored[2].id, 3)
    assert_eq(actual.merged.kept.length(), expected.merged.kept.length())
    assert_eq(actual.merged.kept[0].id, 1)
    assert_eq(
      actual.merged.suppressed.length(),
      expected.merged.suppressed.length(),
    )
    assert_eq(
      actual.merged.suppressed[0].suppressed_id,
      expected.merged.suppressed[0].suppressed_id,
    )
  }
}
