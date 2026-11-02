///|
test "replacement corrects grid atomically and preserves prior snapshots" {
  let grid = @moontile.TileGrid::new(100, 60, 60, 60, 20, 0).unwrap()
  let first : @moontile.TilePredictions = {
    tile: grid.get(0).unwrap(),
    transform: None,
    detections: [
      {
        id: 1,
        image_id: 1,
        tile_id: 0,
        class_id: 0,
        score: 0.5,
        box: { x1: 45.0, y1: 10.0, x2: 55.0, y2: 20.0, },
      },
    ],
  }
  let correct : @moontile.TilePredictions = {
    tile: grid.get(1).unwrap(),
    transform: None,
    detections: [
      {
        id: 2,
        image_id: 1,
        tile_id: 1,
        class_id: 0,
        score: 0.5,
        box: { x1: 5.0, y1: 10.0, x2: 15.0, y2: 20.0, },
      },
    ],
  }
  let wrong = {
    ..correct,
    tile: { ..correct.tile, x: 39, },
    detections: [
      {
        ..correct.detections[0],
        box: { x1: 6.0, y1: 10.0, x2: 16.0, y2: 20.0, },
      },
    ],
  }
  for strategy in [@moontile.MergeStrategy::Nms, GreedyNmm] {
    let acc = @moontile.TileAccumulator::new(100, 60, {
      threshold: 0.5,
      metric: IoU,
      class_agnostic: false,
      strategy,
    }).unwrap()
    assert_true(acc.add_tiles([first, wrong]) is Ok(_))
    let snapshot = acc.finish().unwrap()
    assert_eq(snapshot.merged.kept[0].id, 1)
    assert_true(acc.finish_grid(grid) is Err(_))
    let conflict = {
      ..correct,
      detections: [{ ..correct.detections[0], id: 1, }],
    }
    assert_true(acc.replace_tile(conflict) is Err(_))
    assert_true(
      acc.replace_tile({
        ..correct,
        detections: [correct.detections[0], correct.detections[0]],
      })
      is Err(_),
    )
    assert_true(
      acc.replace_tile({
        ..correct,
        transform: Some({
          scale_x: 0.0,
          scale_y: 1.0,
          pad_x: 0.0,
          pad_y: 0.0,
          clip: false,
        }),
      })
      is Err(_),
    )
    assert_true(
      acc.replace_tile({ ..correct, tile: { ..correct.tile, id: 9, }, })
      is Err(_),
    )
    assert_eq(acc.tile_count(), 2)
    assert_eq(acc.detection_count(), 2)
    assert_true(acc.finish_grid(grid) is Err(_))
    assert_true(acc.replace_tile(correct) is Ok(_))
    assert_eq(acc.finish_grid(grid).unwrap().merged.kept[0].id, 1)
    assert_eq(snapshot.restored[1].box.x1, 45.0)
    assert_true(acc.replace_tile(first) is Ok(_))
    let reordered = acc.finish_grid(grid).unwrap()
    assert_eq(reordered.restored[0].id, 2)
    assert_eq(reordered.merged.kept[0].id, 2)
    assert_eq(snapshot.merged.kept[0].id, 1)
    assert_true(acc.remove_tile(9) is Err(_))
    assert_eq(acc.tile_count(), 2)
    assert_true(acc.remove_tile(1) is Ok(_))
    assert_eq(acc.detection_count(), 1)
    assert_true(acc.finish_grid(grid) is Err(_))
    assert_true(acc.add_tile(correct) is Ok(_))
    assert_true(acc.finish_grid(grid) is Ok(_))
    assert_true(acc.replace_tile({ ..correct, detections: [], }) is Ok(_))
    assert_eq(acc.detection_count(), 1)
    assert_true(acc.finish_grid(grid) is Ok(_))
    assert_true(
      acc.replace_tile({
        ..first,
        detections: [{ ..first.detections[0], id: 2, }],
      })
      is Ok(_),
    )
    assert_eq(acc.finish_grid(grid).unwrap().restored[0].id, 2)
    assert_true(acc.remove_tile(1) is Ok(_))
    assert_true(acc.remove_tile(1) is Err(_))
  }
}

///|
test "replacement replays real tiled COCO predictions in arrival order" {
  // Two genuine local boxes from image 1993 in validation/scale/predictions.json.
  // Other detections are omitted; unused windows are empty for this test.
  let grid = @moontile.TileGrid::new(640, 419, 256, 256, 64, 64).unwrap()
  let first : @moontile.TilePredictions = {
    tile: grid.get(0).unwrap(),
    transform: None,
    detections: [
      {
        id: 0,
        image_id: 1993,
        tile_id: 0,
        class_id: 70,
        score: 0.09592112898826599,
        box: {
          x1: 155.5934295654297,
          y1: 247.9036407470703,
          x2: 220.0415802001953,
          y2: 255.91824340820312,
        },
      },
    ],
  }
  let second : @moontile.TilePredictions = {
    tile: grid.get(1).unwrap(),
    transform: None,
    detections: [
      {
        id: 2,
        image_id: 1993,
        tile_id: 1,
        class_id: 65,
        score: 0.12139246612787247,
        box: {
          x1: 119.9251708984375,
          y1: 220.7827606201172,
          x2: 255.62234497070312,
          y2: 255.8125457763672,
        },
      },
    ],
  }
  let acc = @moontile.TileAccumulator::new(640, 419, {
    threshold: 0.5,
    metric: IoU,
    class_agnostic: false,
    strategy: Nms,
  }).unwrap()
  assert_true(acc.add_tile(first) is Ok(_))
  assert_true(
    acc.add_tile({ ..second, tile: { ..second.tile, x: 193, }, }) is Ok(_),
  )
  for id = 2; id < grid.length(); id = id + 1 {
    assert_true(
      acc.add_tile({
        tile: grid.get(id).unwrap(),
        transform: None,
        detections: [],
      })
      is Ok(_),
    )
  }
  assert_true(acc.finish_grid(grid) is Err(_))
  assert_true(acc.replace_tile(second) is Ok(_))
  let actual = acc.finish_grid(grid).unwrap()
  let expected = @moontile.process_tiles(640, 419, [first, second], {
    threshold: 0.5,
    metric: IoU,
    class_agnostic: false,
    strategy: Nms,
  }).unwrap()
  assert_eq(actual.restored.length(), 2)
  assert_eq(actual.restored[1].box.x1, expected.restored[1].box.x1)
  assert_eq(actual.restored[1].box.x2, expected.restored[1].box.x2)
  assert_eq(actual.merged.kept.length(), expected.merged.kept.length())
  assert_eq(actual.merged.kept[0].id, expected.merged.kept[0].id)
}
