///|
test "restore_clipped intersects local boxes while preserving validation" {
  let tile : @moontile.Tile = { id: 3, x: 40, y: 20, width: 60, height: 40, }
  let d : @moontile.Detection = {
    id: 7,
    image_id: 2,
    tile_id: 3,
    class_id: 5,
    score: 0.8,
    box: { x1: -5.0, y1: -3.0, x2: 70.0, y2: 30.0, },
  }
  assert_true(@moontile.restore(tile, d, 100, 60) is Err(_))
  let clipped = @moontile.restore_clipped(tile, d, 100, 60).unwrap()
  assert_eq(clipped.box.x1, 40.0)
  assert_eq(clipped.box.y1, 20.0)
  assert_eq(clipped.box.x2, 100.0)
  assert_eq(clipped.box.y2, 50.0)
  assert_eq(clipped.id, 7)
  assert_eq(clipped.image_id, 2)
  assert_eq(clipped.tile_id, 3)
  assert_eq(clipped.class_id, 5)
  let inside = { ..d, box: { x1: 0.0, y1: 2.0, x2: 60.0, y2: 40.0, }, }
  let ordinary = @moontile.restore(tile, inside, 100, 60).unwrap()
  let unclipped = @moontile.restore_clipped(tile, inside, 100, 60).unwrap()
  assert_eq(ordinary.box.x1, unclipped.box.x1)
  assert_eq(ordinary.box.y2, unclipped.box.y2)
  let outside = { ..d, box: { x1: -3.0, y1: 1.0, x2: 0.0, y2: 3.0, }, }
  assert_true(@moontile.restore_clipped(tile, outside, 100, 60) is Err(_))
  assert_true(
    @moontile.restore_clipped(
      tile,
      { ..d, box: { x1: 1.0, y1: 1.0, x2: 1.0, y2: 2.0, }, },
      100,
      60,
    )
    is Err(_),
  )
  assert_true(
    @moontile.restore_clipped(
      tile,
      { ..d, box: { x1: 0.0 / 0.0, y1: 1.0, x2: 3.0, y2: 2.0, }, },
      100,
      60,
    )
    is Err(_),
  )
  assert_true(
    @moontile.restore_clipped(
      tile,
      { ..d, box: { x1: 0.0, y1: 1.0, x2: 1.0 / 0.0, y2: 2.0, }, },
      100,
      60,
    )
    is Err(_),
  )
  assert_true(
    @moontile.restore_clipped(tile, { ..d, tile_id: 4, }, 100, 60) is Err(_),
  )
  assert_true(@moontile.restore_clipped(tile, d, 99, 60) is Err(_))
}

///|
test "JSON clip_local supports pixel boxes and downstream exports" {
  let clipped =
    #|{"image_width":100,"image_height":60,"threshold":0.5,"metric":"iou","class_agnostic":false,"tiles":[{"tile":{"id":3,"x":40,"y":20,"width":60,"height":40},"clip_local":true,"detections":[{"id":7,"image_id":2,"tile_id":3,"class_id":5,"score":0.8,"box":{"x1":-5,"y1":-3,"x2":70,"y2":30}}]}]}
  let expected = clipped
    .replace(old="\"clip_local\":true,", new="")
    .replace(
      old="\"x1\":-5,\"y1\":-3,\"x2\":70",
      new="\"x1\":0,\"y1\":0,\"x2\":60",
    )
  assert_eq(
    @moontile.process_json(clipped).unwrap(),
    @moontile.process_json(expected).unwrap(),
  )
  assert_eq(
    @moontile.process_mbmot_json(clipped, 1).unwrap(),
    @moontile.process_mbmot_json(expected, 1).unwrap(),
  )
  let map =
    #|[{"class_id":5,"category_id":7}]
  assert_eq(
    @moontile.process_coco_json(clipped, map).unwrap(),
    @moontile.process_coco_json(expected, map).unwrap(),
  )
  let xywh = clipped
    .replace(
      old="\"clip_local\":true",
      new="\"clip_local\":true,\"box_format\":\"xywh\"",
    )
    .replace(
      old="\"x1\":-5,\"y1\":-3,\"x2\":70,\"y2\":30",
      new="\"x\":-5,\"y\":-3,\"width\":75,\"height\":33",
    )
  assert_eq(
    @moontile.process_json(xywh).unwrap(),
    @moontile.process_json(expected).unwrap(),
  )
  assert_true(
    @moontile.process_json(clipped.replace(old="\"clip_local\":true,", new=""))
    is Err(_),
  )
  assert_true(
    @moontile.process_json(
      clipped.replace(old="\"clip_local\":true", new="\"clip_local\":false"),
    )
    is Err(_),
  )
  assert_true(
    @moontile.process_json(
      clipped.replace(old="\"clip_local\":true", new="\"clip_local\":\"true\""),
    )
    is Err(_),
  )
  let outside = clipped.replace(old="\"x2\":70", new="\"x2\":0")
  assert_true(@moontile.process_json(outside) is Err(_))
  let transform =
    #|"transform":{"scale_x":1,"scale_y":1,"pad_x":0,"pad_y":0,"clip":true},
  assert_true(
    @moontile.process_json(
      clipped.replace(
        old="\"clip_local\":true,",
        new="\"clip_local\":true," + transform,
      ),
    )
    is Err(_),
  )
  let normalized = clipped.replace(
    old="\"clip_local\":true",
    new="\"clip_local\":true,\"box_format\":\"normalized_xyxy\",\"coordinate_width\":60,\"coordinate_height\":40",
  )
  assert_true(@moontile.process_json(normalized) is Err(_))
}

///|
test "empty clipped groups validate options before accepting data" {
  let empty =
    #|{"image_width":100,"image_height":60,"threshold":0.5,"metric":"iou","class_agnostic":false,"tiles":[{"tile":{"id":3,"x":40,"y":20,"width":60,"height":40},"clip_local":true,"detections":[]}]}
  assert_true(@moontile.process_json(empty) is Ok(_))
  let transform =
    #|"transform":{"scale_x":1,"scale_y":1,"pad_x":0,"pad_y":0,"clip":true},
  assert_true(
    @moontile.process_json(
      empty.replace(
        old="\"clip_local\":true,",
        new="\"clip_local\":true," + transform,
      ),
    )
    is Err(_),
  )
  let normalized = empty.replace(
    old="\"clip_local\":true",
    new="\"clip_local\":true,\"box_format\":\"normalized_xyxy\",\"coordinate_width\":60,\"coordinate_height\":40",
  )
  assert_true(@moontile.process_json(normalized) is Err(_))
  let false_with_transform = empty.replace(
    old="\"clip_local\":true,",
    new="\"clip_local\":false," + transform,
  )
  assert_true(@moontile.process_json(false_with_transform) is Ok(_))
}
