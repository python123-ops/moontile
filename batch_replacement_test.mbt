///|
test "batch replacement is atomic and permits ID swaps" {
  let tile : @moontile.Tile = { id: 0, x: 0, y: 0, width: 10, height: 10, }
  let detection : @moontile.Detection = {
    id: 1,
    image_id: 1,
    tile_id: 0,
    class_id: 0,
    score: 0.5,
    box: { x1: 1.0, y1: 1.0, x2: 5.0, y2: 5.0, },
  }
  let first : @moontile.TilePredictions = {
    tile,
    detections: [detection],
    transform: None,
  }
  let second : @moontile.TilePredictions = {
    tile: { ..tile, id: 1, },
    detections: [{ ..detection, id: 2, tile_id: 1, }],
    transform: None,
  }
  let third : @moontile.TilePredictions = {
    tile: { ..tile, id: 2, },
    detections: [{ ..detection, id: 3, tile_id: 2, }],
    transform: None,
  }
  for strategy in [@moontile.MergeStrategy::Nms, GreedyNmm] {
    let acc = @moontile.TileAccumulator::new(10, 10, {
      threshold: 0.5,
      metric: IoU,
      class_agnostic: false,
      strategy,
    }).unwrap()
    assert_true(acc.add_tiles([first, second, third]) is Ok(_))
    let before = acc.finish().unwrap()
    assert_true(acc.replace_tiles([]) is Ok(_))
    let swap_second = {
      ..second,
      detections: [{ ..second.detections[0], id: 3, }],
    }
    let swap_third = {
      ..third,
      detections: [{ ..third.detections[0], id: 2, }],
    }
    assert_true(acc.replace_tile(swap_second) is Err(_))
    assert_true(acc.replace_tiles([swap_third, swap_second]) is Ok(_))
    let after = acc.finish().unwrap()
    assert_eq(acc.tile_count(), 3)
    assert_eq(acc.detection_count(), 3)
    assert_eq(after.restored[0].id, 1)
    assert_eq(after.restored[1].id, 2)
    assert_eq(after.restored[1].tile_id, 2)
    assert_eq(after.restored[2].id, 3)
    assert_eq(after.restored[2].tile_id, 1)
    assert_eq(before.restored[1].id, 2)
    assert_eq(before.restored[1].tile_id, 1)
    let duplicate_tiles = [second, second]
    assert_true(acc.replace_tiles(duplicate_tiles) is Err(_))
    assert_true(
      acc.replace_tiles([second, { ..third, tile: { ..third.tile, id: 99, }, }])
      is Err(_),
    )
    assert_true(
      acc.replace_tiles([
        second,
        { ..third, detections: [{ ..third.detections[0], id: 1, }], },
      ])
      is Err(_),
    )
    assert_true(
      acc.replace_tiles([
        second,
        {
          ..third,
          detections: [
            { ..third.detections[0], id: 2, },
            { ..third.detections[0], id: 2, },
          ],
        },
      ])
      is Err(_),
    )
    assert_true(
      acc.replace_tiles([
        second,
        {
          ..third,
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
    let unchanged = acc.finish().unwrap()
    assert_eq(unchanged.restored[1].tile_id, 2)
    assert_eq(unchanged.restored[2].tile_id, 1)
    assert_eq(acc.detection_count(), 3)
    assert_true(acc.remove_tile(1) is Ok(_))
    assert_true(acc.replace_tiles([{ ..third, detections: [], }]) is Ok(_))
    assert_eq(acc.detection_count(), 1)
  }
}

///|
test "batch and ordered single replacements agree when IDs do not move" {
  let acc1 = @moontile.TileAccumulator::new(10, 10, {
    threshold: 0.5,
    metric: IoU,
    class_agnostic: false,
    strategy: Nms,
  }).unwrap()
  let acc2 = @moontile.TileAccumulator::new(10, 10, {
    threshold: 0.5,
    metric: IoU,
    class_agnostic: false,
    strategy: Nms,
  }).unwrap()
  let groups : Array[@moontile.TilePredictions] = []
  for id = 0; id < 12; id = id + 1 {
    groups.push({
      tile: { id, x: 0, y: 0, width: 10, height: 10, },
      transform: None,
      detections: [
        {
          id,
          image_id: 1,
          tile_id: id,
          class_id: 0,
          score: 0.5,
          box: { x1: 1.0, y1: 1.0, x2: 5.0, y2: 5.0, },
        },
      ],
    })
  }
  acc1.add_tiles(groups).unwrap()
  acc2.add_tiles(groups).unwrap()
  let replacements = [groups[7], groups[3], groups[9]]
  acc1.replace_tiles(replacements).unwrap()
  for group in replacements {
    acc2.replace_tile(group).unwrap()
  }
  let batch = acc1.finish().unwrap()
  let sequential = acc2.finish().unwrap()
  for i = 0; i < batch.restored.length(); i = i + 1 {
    assert_eq(batch.restored[i].id, sequential.restored[i].id)
  }
  assert_eq(batch.merged.kept[0].id, sequential.merged.kept[0].id)
  for i = 0; i < batch.merged.suppressed.length(); i = i + 1 {
    assert_eq(
      batch.merged.suppressed[i].suppressed_id,
      sequential.merged.suppressed[i].suppressed_id,
    )
    assert_eq(
      batch.merged.suppressed[i].kept_id,
      sequential.merged.suppressed[i].kept_id,
    )
  }
}
