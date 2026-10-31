///|
test "merged detection feeds tracking and evaluation" {
  let tile : @moontile.Tile = { id: 0, x: 0, y: 0, width: 100, height: 60, }
  let d : @moontile.Detection = {
    id: 1,
    image_id: 1,
    tile_id: 0,
    class_id: 0,
    score: 0.95,
    box: { x1: 45.0, y1: 10.0, x2: 58.0, y2: 30.0, },
  }
  let restored = @moontile.restore(tile, d, 100, 60).unwrap()
  let merged = @moontile.suppress([restored], 0.5, IoU).unwrap()
  let track_input = to_tracker(merged.kept[0])
  let tracker = @mbmot.Tracker::new(@mbmot.TrackerConfig::default())
  let tracks = tracker.update(1, [track_input])
  assert_eq(tracks.tracks().length(), 1)
  let prediction = to_evaluator(merged.kept[0], 7)
  let box = @moondeteval.Box::from_xywh(45.0, 10.0, 13.0, 20.0)
  let dataset = @moondeteval.Dataset::new(
    [@moondeteval.Image::new(1, 100, 60)],
    [@moondeteval.Category::new(7, "object")],
    [@moondeteval.GroundTruth::new(1L, 1, 7, box, area=260.0)],
  )
  let report = @moondeteval.evaluate(dataset, [prediction])
  assert_eq(report.summary().ap50(), 1.0)
}
