///|
fn detection(
  id : Int,
  tile_id : Int,
  class_id : Int,
  score : Double,
  x1 : Double,
  y1 : Double,
  x2 : Double,
  y2 : Double,
) -> @moontile.Detection {
  { id, image_id: 1, tile_id, class_id, score, box: { x1, y1, x2, y2, }, }
}

///|
test "tile coverage and edge anchoring" {
  let tiles = @moontile.plan_tiles(100, 70, 60, 40, 20, 10).unwrap()
  assert_eq(tiles.length(), 4)
  assert_eq(tiles[3].x, 40)
  assert_eq(tiles[3].y, 30)
  assert_eq(tiles[3].id, 3)
  let small = @moontile.plan_tiles(10, 5, 60, 40, 20, 10).unwrap()
  assert_eq(small.length(), 1)
  assert_eq(small[0].width, 10)
  assert_eq(small[0].height, 5)
  assert_true(@moontile.plan_tiles(100, 70, 60, 40, 60, 0) is Err(_))
  assert_true(@moontile.plan_tiles(0, 70, 60, 40, 0, 0) is Err(_))
}

///|
test "restore and reject invalid inputs" {
  let tile : @moontile.Tile = { id: 2, x: 40, y: 30, width: 60, height: 40, }
  let sample = detection(4, 2, 0, 0.8, 10.0, 5.0, 20.0, 12.0)
  let global = @moontile.restore(tile, sample, 100, 70).unwrap()
  assert_eq(global.box.x1, 50.0)
  assert_eq(global.box.y2, 42.0)
  assert_eq(global.id, 4)
  let outside = detection(4, 2, 0, 0.8, -1.0, 5.0, 20.0, 12.0)
  assert_true(@moontile.restore(tile, outside, 100, 70) is Err(_))
  let wrong_tile = detection(4, 3, 0, 0.8, 1.0, 5.0, 20.0, 12.0)
  assert_true(@moontile.restore(tile, wrong_tile, 100, 70) is Err(_))
}

///|
test "NMS class, ties, threshold and provenance" {
  let a = detection(7, 0, 0, 0.9, 0.0, 0.0, 10.0, 10.0)
  let b = detection(8, 1, 0, 0.9, 0.0, 0.0, 10.0, 10.0)
  let c = detection(9, 1, 1, 0.8, 0.0, 0.0, 10.0, 10.0)
  let merged = @moontile.suppress([a, b, c], 0.5, IoU).unwrap()
  assert_eq(merged.kept.length(), 2)
  assert_eq(merged.kept[0].id, 7)
  assert_eq(merged.suppressed[0].suppressed_id, 8)
  assert_eq(merged.suppressed[0].kept_id, 7)
  assert_eq(@moontile.suppress([a, b], 1.0, IoU).unwrap().kept.length(), 2)
  assert_eq(
    @moontile.suppress([a, c], 0.5, IoU, class_agnostic=true).unwrap().kept.length(),
    1,
  )
  assert_true(@moontile.suppress([a, a], 0.5, IoU) is Err(_))
}

///|
test "IoS, invalid score and image separation" {
  let a = detection(1, 0, 0, 0.9, 0.0, 0.0, 10.0, 10.0)
  let b = detection(2, 1, 0, 0.8, 0.0, 0.0, 5.0, 5.0)
  assert_eq(@moontile.suppress([a, b], 0.5, IoU).unwrap().kept.length(), 2)
  assert_eq(@moontile.suppress([a, b], 0.5, IoS).unwrap().kept.length(), 1)
  let other : @moontile.Detection = { ..b, image_id: 2, }
  assert_eq(@moontile.suppress([a, other], 0.5, IoS).unwrap().kept.length(), 2)
  let bad : @moontile.Detection = { ..b, score: 0.0 / 0.0, }
  assert_true(@moontile.suppress([a, bad], 0.5, IoU) is Err(_))
  assert_true(@moontile.suppress([a], 1.1, IoU) is Err(_))
}

///|
test "empty tiles, exact coverage and JSON rejection" {
  let tiles = @moontile.plan_tiles(120, 40, 60, 40, 0, 0).unwrap()
  assert_eq(tiles.length(), 2)
  assert_eq(tiles[1].x, 60)
  assert_true(@moontile.process_json("{") is Err(_))
  let invalid =
    #|{"image_width":100,"image_height":60,"threshold":0.5,"metric":"iou","class_agnostic":false,"tiles":[{"tile":{"id":0,"x":99,"y":0,"width":2,"height":1},"detections":[]}]}
  assert_true(@moontile.process_json(invalid) is Err(_))
  let empty =
    #|{"image_width":100,"image_height":60,"threshold":0.5,"metric":"iou","class_agnostic":false,"tiles":[]}
  assert_true(@moontile.process_json(empty) is Ok(_))
}

///|
test "zero area and infinity are rejected" {
  let degenerate = detection(1, 0, 0, 0.5, 2.0, 1.0, 2.0, 3.0)
  let infinite = detection(2, 0, 0, 0.5, 1.0, 1.0, 1.0 / 0.0, 3.0)
  assert_true(@moontile.suppress([degenerate], 0.5, IoU) is Err(_))
  assert_true(@moontile.suppress([infinite], 0.5, IoU) is Err(_))
}

///|
test "restored box must remain representable after translation" {
  let tile : @moontile.Tile = {
    id: 0,
    x: 2000000000,
    y: 0,
    width: 1,
    height: 1,
  }
  let tiny = detection(1, 0, 0, 0.5, 0.0, 0.0, 0.00000001, 0.5)
  assert_true(@moontile.restore(tile, tiny, 2000000001, 1) is Err(_))
}

///|
test "COCO export preserves order and rejects ambiguous mappings" {
  let a = detection(1, 0, 0, 0.9, 2.0, 3.0, 7.0, 9.0)
  let b = detection(2, 0, 1, 0.8, 4.0, 5.0, 8.0, 10.0)
  let mappings : Array[@moontile.CategoryMapping] = [
    { class_id: 0, category_id: 7, },
    { class_id: 1, category_id: 42, },
  ]
  let encoded = @moontile.export_coco([a, b], mappings).unwrap()
  assert_eq(
    encoded, "[{\"image_id\":1,\"category_id\":7,\"bbox\":[2,3,5,6],\"score\":0.9},{\"image_id\":1,\"category_id\":42,\"bbox\":[4,5,4,5],\"score\":0.8}]",
  )
  assert_true(@moontile.export_coco([a, b], [mappings[0]]) is Err(_))
  assert_true(@moontile.export_coco([a], [mappings[0], mappings[0]]) is Err(_))
  assert_true(@moontile.export_coco([a, a], mappings) is Err(_))
  assert_true(
    @moontile.export_coco([a], [{ class_id: 0, category_id: -1, }]) is Err(_),
  )
  assert_eq(@moontile.export_coco([], []).unwrap(), "[]")
}

///|
test "COCO pipeline rejects malformed mappings" {
  let input =
    #|{"image_width":10,"image_height":10,"threshold":0.5,"metric":"iou","class_agnostic":false,"tiles":[]}
  assert_true(@moontile.process_coco_json(input, "{") is Err(_))
  assert_true(@moontile.process_coco_json(input, "{}") is Err(_))
  assert_eq(@moontile.process_coco_json(input, "[]").unwrap(), "[]")
}

///|
test "MBMOT export validates frame, identities and detection fields" {
  let a = detection(1, 0, 0, 0.9, 2.0, 3.0, 7.0, 9.0)
  let b = detection(2, 0, 1, 0.8, 4.0, 5.0, 8.0, 10.0)
  let encoded = @moontile.export_mbmot([a, b], 42).unwrap()
  assert_eq(
    encoded, "{\"frame\":42,\"detections\":[{\"xyxy\":[2,3,7,9],\"score\":0.9,\"class_id\":0},{\"xyxy\":[4,5,8,10],\"score\":0.8,\"class_id\":1}]}",
  )
  assert_eq(
    @moontile.export_mbmot([], 1).unwrap(),
    "{\"frame\":1,\"detections\":[]}",
  )
  assert_true(@moontile.export_mbmot([a], 0) is Err(_))
  assert_true(@moontile.export_mbmot([a, a], 1) is Err(_))
  let other : @moontile.Detection = { ..b, image_id: 2, }
  assert_true(@moontile.export_mbmot([a, other], 1) is Err(_))
  let bad : @moontile.Detection = { ..b, score: 1.1, }
  assert_true(@moontile.export_mbmot([bad], 1) is Err(_))
}

///|
test "MBMOT pipeline rejects mixed image IDs" {
  let input =
    #|{"image_width":10,"image_height":10,"threshold":0.5,"metric":"iou","class_agnostic":false,"tiles":[{"tile":{"id":0,"x":0,"y":0,"width":10,"height":10},"detections":[{"id":1,"image_id":1,"tile_id":0,"class_id":0,"score":0.9,"box":{"x1":0,"y1":0,"x2":5,"y2":5}},{"id":2,"image_id":2,"tile_id":0,"class_id":0,"score":0.8,"box":{"x1":0,"y1":0,"x2":5,"y2":5}}]}]}
  assert_true(@moontile.process_mbmot_json(input, 1) is Err(_))
  assert_true(@moontile.process_mbmot_json(input, -1) is Err(_))
}

///|
test "MBMOT pipeline retains original order after score-ranked suppression" {
  let input =
    #|{"image_width":10,"image_height":10,"threshold":0.5,"metric":"iou","class_agnostic":false,"tiles":[{"tile":{"id":0,"x":0,"y":0,"width":10,"height":10},"detections":[{"id":1,"image_id":1,"tile_id":0,"class_id":0,"score":0.5,"box":{"x1":0,"y1":0,"x2":2,"y2":2}},{"id":2,"image_id":1,"tile_id":0,"class_id":0,"score":0.9,"box":{"x1":5,"y1":5,"x2":7,"y2":7}}]}]}
  let output = @moontile.process_mbmot_json(input, 1).unwrap()
  assert_eq(
    output, "{\"frame\":1,\"detections\":[{\"xyxy\":[0,0,2,2],\"score\":0.5,\"class_id\":0},{\"xyxy\":[5,5,7,7],\"score\":0.9,\"class_id\":0}]}",
  )
}

///|
test "stream rejects errors without advancing and allows reset" {
  let data =
    #|{"image_width":10,"image_height":10,"threshold":0.5,"metric":"iou","class_agnostic":false,"tiles":[]}
  let session = @moontile.StreamSession::new()
  assert_true(session.last_frame() is None)
  assert_true(session.process_line("not json") is Err(_))
  let first = "{\"frame\":1,\"input\":" + data + "}"
  let first_output = session.process_line(first).unwrap()
  assert_eq(first_output, "{\"frame\":1,\"detections\":[]}")
  assert_true(session.last_frame() is Some(1))
  assert_true(session.process_line(first) is Err(_))
  assert_true(session.process_line("{\"frame\":2,\"input\":{}}") is Err(_))
  assert_true(session.last_frame() is Some(1))
  let third = "{\"frame\":3,\"input\":" + data + "}"
  assert_eq(
    session.process_line(third).unwrap(),
    "{\"frame\":3,\"detections\":[]}",
  )
  session.reset()
  assert_true(session.last_frame() is None)
  assert_true(session.process_line(first) is Ok(_))
}
