///|
test "merged detection feeds tracking and evaluation" {
  let grid = @moontile.TileGrid::new(100, 60, 60, 60, 20, 0).unwrap()
  let tile = grid.get(0).unwrap()
  let d : @moontile.Detection = {
    id: 1,
    image_id: 1,
    tile_id: 0,
    class_id: 0,
    score: 0.95,
    box: @moontile.Box::from_xywh(45.0, 10.0, 13.0, 20.0).unwrap(),
  }
  let accumulator = @moontile.TileAccumulator::new(100, 60, {
    threshold: 0.5,
    metric: IoU,
    class_agnostic: false,
    strategy: Nms,
  }).unwrap()
  accumulator
  .add_tiles([
    { tile, detections: [d], transform: None, },
    {
      tile: { ..grid.get(1).unwrap(), x: 39, },
      detections: [],
      transform: None,
    },
  ])
  .unwrap()
  assert_true(accumulator.finish_grid(grid) is Err(_))
  let inspection = accumulator.inspect_grid(grid, max_reported=2).unwrap()
  assert_eq(inspection.mismatched_count, 1)
  assert_eq(inspection.mismatched_ids, [1])
  assert_true(!inspection.is_complete())
  accumulator
  .replace_tiles([
    { tile: grid.get(1).unwrap(), detections: [], transform: None, },
    { tile, detections: [d], transform: None, },
  ])
  .unwrap()
  assert_true(accumulator.inspect_grid(grid).unwrap().is_complete())
  let result = accumulator.finish_grid_take(grid).unwrap()
  assert_eq(accumulator.tile_count(), 0)
  assert_eq(accumulator.detection_count(), 0)
  let track_input = to_tracker(result.merged.kept[0])
  let tracker = @mbmot.Tracker::new(@mbmot.TrackerConfig::default())
  let tracks = tracker.update(1, [track_input])
  assert_eq(tracks.tracks().length(), 1)
  let prediction = to_evaluator(result.merged.kept[0], 7)
  let box = @moondeteval.Box::from_xywh(45.0, 10.0, 13.0, 20.0)
  let dataset = @moondeteval.Dataset::new(
    [@moondeteval.Image::new(1, 100, 60)],
    [@moondeteval.Category::new(7, "object")],
    [@moondeteval.GroundTruth::new(1L, 1, 7, box, area=260.0)],
  )
  let report = @moondeteval.evaluate(dataset, [prediction])
  assert_eq(report.summary().ap50(), 1.0)
}

///|
test "normalized center box reaches tracking and evaluation" {
  let bbox = @moontile.Box::from_normalized_cxcywh(0.5, 0.5, 0.5, 0.5, 100, 60).unwrap()
  let detection : @moontile.Detection = {
    id: 9,
    image_id: 1,
    tile_id: 0,
    class_id: 0,
    score: 0.95,
    box: bbox,
  }
  let tiles : Array[@moontile.TilePredictions] = [
    {
      tile: { id: 0, x: 0, y: 0, width: 100, height: 60, },
      detections: [detection],
      transform: None,
    },
  ]
  let result = @moontile.process_tiles(100, 60, tiles, {
    threshold: 0.5,
    metric: IoU,
    class_agnostic: false,
    strategy: Nms,
  }).unwrap()
  let tracker = @mbmot.Tracker::new(@mbmot.TrackerConfig::default())
  assert_eq(
    tracker.update(1, [to_tracker(result.merged.kept[0])]).tracks().length(),
    1,
  )
  let prediction = to_evaluator(result.merged.kept[0], 7)
  let truth = @moondeteval.Box::from_xywh(25.0, 15.0, 50.0, 30.0)
  let dataset = @moondeteval.Dataset::new(
    [@moondeteval.Image::new(1, 100, 60)],
    [@moondeteval.Category::new(7, "object")],
    [@moondeteval.GroundTruth::new(1L, 1, 7, truth, area=1500.0)],
  )
  assert_eq(@moondeteval.evaluate(dataset, [prediction]).summary().ap50(), 1.0)
}

///|
test "normalized JSON prediction reaches both consumers" {
  let source =
    #|{"image_width":100,"image_height":60,"threshold":0.5,"metric":"iou","class_agnostic":false,"tiles":[{"tile":{"id":0,"x":0,"y":0,"width":100,"height":60},"box_format":"normalized_cxcywh","coordinate_width":100,"coordinate_height":60,"detections":[{"id":1,"image_id":1,"tile_id":0,"class_id":0,"score":0.95,"box":{"cx":0.5,"cy":0.5,"width":0.5,"height":0.5}}]}]}
  let frame = @replay_codec.parse_frame_line(
    @moontile.process_mbmot_json(source, 1).unwrap(),
  )
  assert_eq(frame.detections().length(), 1)
  assert_eq(frame.detections()[0].bbox().x1(), 25.0)
  assert_eq(frame.detections()[0].bbox().y2(), 45.0)
  let predictions = @moondeteval.parse_coco_detections(
    @moontile.process_coco_json(source, "[{\"class_id\":0,\"category_id\":7}]").unwrap(),
  )
  let truth = @moondeteval.Box::from_xywh(25.0, 15.0, 50.0, 30.0)
  let dataset = @moondeteval.Dataset::new(
    [@moondeteval.Image::new(1, 100, 60)],
    [@moondeteval.Category::new(7, "object")],
    [@moondeteval.GroundTruth::new(1L, 1, 7, truth, area=1500.0)],
  )
  assert_eq(@moondeteval.evaluate(dataset, predictions).summary().ap50(), 1.0)
}

///|
test "COCO pipeline output is consumable by MoonDetEval" {
  let source =
    #|{"image_width":100,"image_height":60,"threshold":0.5,"metric":"iou","class_agnostic":false,"tiles":[{"tile":{"id":0,"x":0,"y":0,"width":100,"height":60},"detections":[{"id":1,"image_id":1,"tile_id":0,"class_id":0,"score":0.95,"box":{"x1":45,"y1":10,"x2":58,"y2":30}}]}]}
  let result = @moontile.process_coco_json(
    source, "[{\"class_id\":0,\"category_id\":7}]",
  ).unwrap()
  let predictions = @moondeteval.parse_coco_detections(result)
  let box = @moondeteval.Box::from_xywh(45.0, 10.0, 13.0, 20.0)
  let dataset = @moondeteval.Dataset::new(
    [@moondeteval.Image::new(1, 100, 60)],
    [@moondeteval.Category::new(7, "object")],
    [@moondeteval.GroundTruth::new(1L, 1, 7, box, area=260.0)],
  )
  assert_eq(@moondeteval.evaluate(dataset, predictions).summary().ap50(), 1.0)
}

///|
test "MBMOT replay consumes two frames of tile results" {
  let source =
    #|{"image_width":100,"image_height":60,"threshold":0.5,"metric":"iou","class_agnostic":false,"tiles":[{"tile":{"id":0,"x":0,"y":0,"width":60,"height":60},"detections":[{"id":1,"image_id":1,"tile_id":0,"class_id":0,"score":0.95,"box":{"x1":45,"y1":10,"x2":58,"y2":30}}]},{"tile":{"id":1,"x":40,"y":0,"width":60,"height":60},"detections":[{"id":2,"image_id":1,"tile_id":1,"class_id":0,"score":0.85,"box":{"x1":5,"y1":10,"x2":18,"y2":30}}]}]}
  let first = @moontile.process_mbmot_json(source, 1).unwrap()
  let second = @moontile.process_mbmot_json(source, 2).unwrap()
  let frame1 = @replay_codec.parse_frame_line(first)
  let frame2 = @replay_codec.parse_frame_line(second)
  assert_eq(frame1.detections().length(), 1)
  assert_eq(frame2.detections().length(), 1)
  let tracker = @mbmot.Tracker::new(@mbmot.TrackerConfig::default())
  let track1 = tracker.update(frame1.frame(), frame1.detections()).tracks()[0]
  let track2 = tracker.update(frame2.frame(), frame2.detections()).tracks()[0]
  assert_eq(track1.track_id(), track2.track_id())
  assert_eq(track2.hits(), 2)
}

///|
test "stream output is accepted by MBMOT replay session" {
  let input =
    #|{"image_width":100,"image_height":60,"threshold":0.5,"metric":"iou","class_agnostic":false,"tiles":[{"tile":{"id":0,"x":0,"y":0,"width":100,"height":60},"detections":[{"id":1,"image_id":1,"tile_id":0,"class_id":0,"score":0.95,"box":{"x1":45,"y1":10,"x2":58,"y2":30}}]}]}
  let tile_stream = @moontile.StreamSession::new()
  let replay = @replay_codec.ReplaySession::new(@mbmot.TrackerConfig::default())
  let first = tile_stream
    .process_line("{\"frame\":1,\"input\":" + input + "}")
    .unwrap()
  let second = tile_stream
    .process_line("{\"frame\":2,\"input\":" + input + "}")
    .unwrap()
  let parsed = @replay_codec.parse_frame_line(first)
  assert_eq(parsed.frame(), 1)
  assert_eq(parsed.detections().length(), 1)
  let out1 = replay.process_line(first)
  let out2 = replay.process_line(second)
  assert_true(out1.contains("\"track_id\":1"))
  assert_true(out2.contains("\"track_id\":1"))
  assert_true(out2.contains("\"hits\":2"))
}

///|
test "merged tile envelope reaches both MBMOT and MoonDetEval" {
  let source =
    #|{"image_width":100,"image_height":60,"threshold":0.5,"metric":"ios","class_agnostic":false,"strategy":"greedy_nmm","tiles":[{"tile":{"id":0,"x":0,"y":0,"width":60,"height":60},"transform":{"scale_x":2,"scale_y":1.5,"pad_x":10,"pad_y":5,"clip":false},"detections":[{"id":1,"image_id":1,"tile_id":0,"class_id":0,"score":0.95,"box":{"x1":100,"y1":20,"x2":130,"y2":50}}]},{"tile":{"id":1,"x":40,"y":0,"width":60,"height":60},"detections":[{"id":2,"image_id":1,"tile_id":1,"class_id":0,"score":0.85,"box":{"x1":10,"y1":10,"x2":30,"y2":30}}]}]}
  let tracking = @replay_codec.parse_frame_line(
    @moontile.process_mbmot_json(source, 1).unwrap(),
  )
  assert_eq(tracking.detections().length(), 1)
  assert_eq(tracking.detections()[0].bbox().x2(), 70.0)
  let prediction = @moondeteval.parse_coco_detections(
    @moontile.process_coco_json(source, "[{\"class_id\":0,\"category_id\":7}]").unwrap(),
  )
  let truth = @moondeteval.Box::from_xywh(45.0, 10.0, 25.0, 20.0)
  let dataset = @moondeteval.Dataset::new(
    [@moondeteval.Image::new(1, 100, 60)],
    [@moondeteval.Category::new(7, "object")],
    [@moondeteval.GroundTruth::new(1L, 1, 7, truth, area=500.0)],
  )
  assert_eq(@moondeteval.evaluate(dataset, prediction).summary().ap50(), 1.0)
}
