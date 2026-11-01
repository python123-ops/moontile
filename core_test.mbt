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
test "model coordinates invert resize and padding and enforce clipping" {
  let tile : @moontile.Tile = { id: 2, x: 40, y: 30, width: 60, height: 40, }
  let transform : @moontile.ModelTransform = {
    scale_x: 2.0,
    scale_y: 1.5,
    pad_x: 10.0,
    pad_y: 5.0,
    clip: false,
  }
  let model = detection(4, 2, 0, 0.8, 30.0, 12.5, 50.0, 23.0)
  let result = @moontile.restore_model(tile, model, 100, 70, transform).unwrap()
  assert_eq(result.box.x1, 50.0)
  assert_eq(result.box.y1, 35.0)
  assert_eq(result.box.x2, 60.0)
  assert_eq(result.box.y2, 42.0)
  let outside = detection(4, 2, 0, 0.8, 0.0, 5.0, 30.0, 20.0)
  assert_true(
    @moontile.restore_model(tile, outside, 100, 70, transform) is Err(_),
  )
  let clipped = @moontile.restore_model(tile, outside, 100, 70, {
    ..transform,
    clip: true,
  }).unwrap()
  assert_eq(clipped.box.x1, 40.0)
  assert_eq(clipped.box.x2, 50.0)
  let padding = detection(4, 2, 0, 0.8, 0.0, 5.0, 9.0, 20.0)
  assert_true(
    @moontile.restore_model(tile, padding, 100, 70, { ..transform, clip: true, })
    is Err(_),
  )
  assert_true(
    @moontile.restore_model(tile, model, 100, 70, { ..transform, scale_x: 0.0, })
    is Err(_),
  )
  assert_true(
    @moontile.restore_model(tile, model, 100, 70, {
      ..transform,
      scale_y: -1.0,
    })
    is Err(_),
  )
  assert_true(
    @moontile.restore_model(tile, model, 100, 70, { ..transform, pad_x: -1.0, })
    is Err(_),
  )
  assert_true(
    @moontile.restore_model(tile, model, 100, 70, {
      ..transform,
      scale_x: 0.0 / 0.0,
    })
    is Err(_),
  )
  assert_true(
    @moontile.restore_model(tile, model, 100, 70, {
      ..transform,
      pad_y: 1.0 / 0.0,
    })
    is Err(_),
  )
  assert_true(
    @moontile.restore_model(tile, model, 100, 70, {
      ..transform,
      scale_x: 1.0e-320,
    })
    is Err(_),
  )
  assert_true(
    @moontile.restore_model(tile, { ..model, tile_id: 3, }, 100, 70, transform)
    is Err(_),
  )
  let invalid =
    #|{"image_width":100,"image_height":60,"threshold":0.5,"metric":"iou","class_agnostic":false,"tiles":[{"tile":{"id":0,"x":0,"y":0,"width":60,"height":60},"transform":{"scale_x":0,"scale_y":1,"pad_x":0,"pad_y":0,"clip":false},"detections":[]}]}
  assert_true(@moontile.process_json(invalid) is Err(_))
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
  let pixel_overlap = @moontile.plan_tiles(120, 50, 50, 50, 29, 0).unwrap()
  assert_eq(pixel_overlap.length(), 5)
  assert_eq(pixel_overlap[1].x, 21)
  assert_eq(pixel_overlap[2].x, 42)
  assert_eq(pixel_overlap[4].x, 70)
}

///|
test "tile grid agrees with incremental edge-anchored planning" {
  for width = 1; width <= 8; width = width + 1 {
    for height = 1; height <= 7; height = height + 1 {
      for tw = 1; tw <= 5; tw = tw + 1 {
        for th = 1; th <= 4; th = th + 1 {
          for ox = 0; ox < tw; ox = ox + 1 {
            for oy = 0; oy < th; oy = oy + 1 {
              let grid = @moontile.TileGrid::new(width, height, tw, th, ox, oy).unwrap()
              let planned = @moontile.plan_tiles(width, height, tw, th, ox, oy).unwrap()
              let actual_width = tw.min(width)
              let actual_height = th.min(height)
              let mut y = 0
              let mut id = 0
              for ;; {
                let mut x = 0
                for ;; {
                  let tile = grid.get(id).unwrap()
                  assert_eq(tile.id, id)
                  assert_eq(tile.x, x)
                  assert_eq(tile.y, y)
                  assert_eq(tile.width, actual_width)
                  assert_eq(tile.height, actual_height)
                  assert_eq(planned[id].x, x)
                  assert_eq(planned[id].y, y)
                  id = id + 1
                  if x == width - actual_width {
                    break
                  }
                  x = x + (tw - ox).min(width - actual_width - x)
                }
                if y == height - actual_height {
                  break
                }
                y = y + (th - oy).min(height - actual_height - y)
              }
              assert_eq(id, grid.length())
              assert_eq(id, planned.length())
              assert_true(grid.get(-1) is None)
              assert_true(grid.get(id) is None)
            }
          }
        }
      }
    }
  }
}

///|
test "tile grid handles count and integer boundaries without allocation" {
  let limit = @moontile.TileGrid::new(1000, 1000, 1, 1, 0, 0).unwrap()
  assert_eq(limit.length(), 1000000)
  let last = limit.get(999999).unwrap()
  assert_eq(last.x, 999)
  assert_eq(last.y, 999)
  assert_true(@moontile.TileGrid::new(1001, 1000, 1, 1, 0, 0) is Err(_))
  assert_true(@moontile.plan_tiles(1001, 1000, 1, 1, 0, 0) is Err(_))
  assert_true(
    @moontile.TileGrid::new(2147483647, 2147483647, 1, 1, 0, 0) is Err(_),
  )
  let wide = @moontile.TileGrid::new(2147483647, 1, 1073741823, 1, 0, 0).unwrap()
  assert_eq(wide.length(), 3)
  assert_eq(wide.get(1).unwrap().x, 1073741823)
  assert_eq(wide.get(2).unwrap().x, 1073741824)
  assert_true(@moontile.TileGrid::new(1, 1, 0, 1, 0, 0) is Err(_))
  assert_true(@moontile.TileGrid::new(1, 1, 1, 1, 1, 0) is Err(_))
}

///|
test "JSON planning validates fields and returns row-major windows" {
  let request =
    #|{"image_width":100,"image_height":60,"tile_width":60,"tile_height":60,"overlap_x":20,"overlap_y":0}
  let output = @moontile.plan_json(request).unwrap()
  let expected =
    #|{"image_width":100,"image_height":60,"tiles":[{"id":0,"x":0,"y":0,"width":60,"height":60},{"id":1,"x":40,"y":0,"width":60,"height":60}]}
  assert_eq(output, expected)
  assert_true(@moontile.plan_json("{") is Err(_))
  assert_true(@moontile.plan_json("{}") is Err(_))
  let invalid =
    #|{"image_width":10,"image_height":10,"tile_width":5,"tile_height":5,"overlap_x":5,"overlap_y":0}
  assert_true(@moontile.plan_json(invalid) is Err(_))
  let fractional =
    #|{"image_width":10.5,"image_height":10,"tile_width":5,"tile_height":5,"overlap_x":0,"overlap_y":0}
  assert_true(@moontile.plan_json(fractional) is Err(_))
}

///|
test "JSON identities and dimensions reject fractional values" {
  let source =
    #|{"image_width":100,"image_height":60,"threshold":0.5,"metric":"iou","class_agnostic":false,"tiles":[{"tile":{"id":0,"x":0,"y":0,"width":60,"height":60},"detections":[{"id":1,"image_id":1,"tile_id":0,"class_id":0,"score":0.9,"box":{"x1":1.5,"y1":2,"x2":5,"y2":6}}]}]}
  assert_true(@moontile.process_json(source) is Ok(_))
  let fields = [
    ("\"image_width\":100", "\"image_width\":100.5"),
    ("\"image_height\":60", "\"image_height\":60.5"),
    ("\"id\":0", "\"id\":0.5"),
    ("\"x\":0", "\"x\":0.5"),
    ("\"y\":0", "\"y\":0.5"),
    ("\"width\":60", "\"width\":60.5"),
    ("\"height\":60", "\"height\":60.5"),
    ("\"id\":1", "\"id\":1.5"),
    ("\"image_id\":1", "\"image_id\":1.5"),
    ("\"tile_id\":0", "\"tile_id\":0.5"),
    ("\"class_id\":0", "\"class_id\":0.5"),
  ]
  for (old, new) in fields {
    let invalid = source.replace(old~, new~)
    assert_true(@moontile.process_json(invalid) is Err(_))
    assert_true(@moontile.process_mbmot_json(invalid, 1) is Err(_))
    assert_true(
      @moontile.process_coco_json(
        invalid, "[{\"class_id\":0,\"category_id\":7}]",
      )
      is Err(_),
    )
  }
  let integer_form = source.replace(
    old="\"image_width\":100",
    new="\"image_width\":1e2",
  )
  assert_true(@moontile.process_json(integer_form) is Ok(_))
  assert_true(
    @moontile.process_coco_json(
      source, "[{\"class_id\":0.5,\"category_id\":7}]",
    )
    is Err(_),
  )
  assert_true(
    @moontile.process_coco_json(
      source, "[{\"class_id\":0,\"category_id\":7.5}]",
    )
    is Err(_),
  )
  assert_true(
    @moontile.process_coco_json(
      source, "[{\"class_id\":0.0,\"category_id\":7.0}]",
    )
    is Ok(_),
  )
  let session = @moontile.StreamSession::new()
  assert_true(
    session.process_line("{\"frame\":1.5,\"input\":" + source + "}") is Err(_),
  )
  assert_true(session.last_frame() is None)
  assert_true(
    session.process_line("{\"frame\":1,\"input\":" + source + "}") is Ok(_),
  )
  assert_true(
    session.process_line(
      "{\"frame\":2,\"input\":" +
      source.replace(old="\"tile_id\":0", new="\"tile_id\":0.5") +
      "}",
    )
    is Err(_),
  )
  assert_true(session.last_frame() is Some(1))
  assert_true(
    session.process_line("{\"frame\":2.0,\"input\":" + source + "}") is Ok(_),
  )
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
test "typed pipeline restores, merges and validates the complete batch" {
  let first : @moontile.TilePredictions = {
    tile: { id: 0, x: 0, y: 0, width: 60, height: 60, },
    detections: [detection(1, 0, 0, 0.95, 100.0, 20.0, 130.0, 50.0)],
    transform: Some({
      scale_x: 2.0,
      scale_y: 1.5,
      pad_x: 10.0,
      pad_y: 5.0,
      clip: false,
    }),
  }
  let second : @moontile.TilePredictions = {
    tile: { id: 1, x: 40, y: 0, width: 60, height: 60, },
    detections: [detection(2, 1, 0, 0.85, 10.0, 10.0, 30.0, 30.0)],
    transform: None,
  }
  let config : @moontile.MergeConfig = {
    threshold: 0.5,
    metric: IoS,
    class_agnostic: false,
    strategy: GreedyNmm,
  }
  let result = @moontile.process_tiles(100, 60, [first, second], config).unwrap()
  assert_eq(result.restored.length(), 2)
  assert_eq(result.restored[0].box.x1, 45.0)
  assert_eq(result.restored[1].box.x2, 70.0)
  assert_eq(result.merged.kept.length(), 1)
  assert_eq(result.merged.kept[0].box.x2, 70.0)
  assert_eq(result.merged.suppressed[0].suppressed_id, 2)
  let json =
    #|{"image_width":100,"image_height":60,"threshold":0.5,"metric":"ios","class_agnostic":false,"strategy":"greedy_nmm","tiles":[{"tile":{"id":0,"x":0,"y":0,"width":60,"height":60},"transform":{"scale_x":2,"scale_y":1.5,"pad_x":10,"pad_y":5,"clip":false},"detections":[{"id":1,"image_id":1,"tile_id":0,"class_id":0,"score":0.95,"box":{"x1":100,"y1":20,"x2":130,"y2":50}}]},{"tile":{"id":1,"x":40,"y":0,"width":60,"height":60},"detections":[{"id":2,"image_id":1,"tile_id":1,"class_id":0,"score":0.85,"box":{"x1":10,"y1":10,"x2":30,"y2":30}}]}]}
  let mapped = @moontile.export_coco(result.merged.kept, [
    { class_id: 0, category_id: 7, },
  ]).unwrap()
  assert_eq(
    mapped,
    @moontile.process_coco_json(json, "[{\"class_id\":0,\"category_id\":7}]").unwrap(),
  )
  let nms = @moontile.process_tiles(100, 60, [first, second], {
    ..config,
    strategy: Nms,
  }).unwrap()
  assert_eq(nms.merged.kept[0].box.x2, 60.0)
  assert_true(
    @moontile.process_tiles(100, 60, [first, first], config) is Err(_),
  )
  assert_true(@moontile.process_tiles(0, 60, [], config) is Err(_))
  assert_true(
    @moontile.process_tiles(100, 60, [], { ..config, threshold: 1.5, })
    is Err(_),
  )
  let invalid = {
    ..second,
    detections: [detection(1, 1, 0, 0.8, 1.0, 1.0, 4.0, 4.0)],
  }
  assert_true(
    @moontile.process_tiles(100, 60, [first, invalid], config) is Err(_),
  )
  let empty_invalid = {
    ..first,
    detections: [],
    transform: Some({
      scale_x: 0.0,
      scale_y: 1.0,
      pad_x: 0.0,
      pad_y: 0.0,
      clip: false,
    }),
  }
  assert_true(
    @moontile.process_tiles(100, 60, [empty_invalid], config) is Err(_),
  )
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

///|
test "envelope merging uses the original seed rather than transitive overlap" {
  let a = detection(1, 0, 0, 0.9, 0.0, 0.0, 10.0, 10.0)
  let b = detection(2, 1, 0, 0.8, 8.0, 0.0, 18.0, 10.0)
  let c = detection(3, 2, 0, 0.7, 16.0, 0.0, 26.0, 10.0)
  let result = @moontile.merge_envelopes([a, b, c], 0.15, IoS).unwrap()
  assert_eq(result.kept.length(), 2)
  assert_eq(result.kept[0].id, 1)
  assert_eq(result.kept[0].box.x1, 0.0)
  assert_eq(result.kept[0].box.x2, 18.0)
  assert_eq(result.kept[0].score, 0.9)
  assert_eq(result.kept[1].id, 3)
  assert_eq(result.suppressed[0].kept_id, 1)
  assert_eq(result.suppressed[0].suppressed_id, 2)
  assert_eq(
    @moontile.merge_envelopes([a, b], 0.2, IoS).unwrap().kept.length(),
    2,
  )
}

///|
test "envelope merging isolates images and classes and rejects bad values" {
  let a = detection(1, 0, 0, 0.9, 0.0, 0.0, 10.0, 10.0)
  let b = detection(2, 1, 1, 0.9, 0.0, 0.0, 10.0, 10.0)
  let other : @moontile.Detection = { ..b, id: 3, image_id: 2, }
  assert_eq(
    @moontile.merge_envelopes([a, b], 0.5, IoU).unwrap().kept.length(),
    2,
  )
  let agnostic = @moontile.merge_envelopes(
    [a, b, other],
    0.5,
    IoU,
    class_agnostic=true,
  ).unwrap()
  assert_eq(agnostic.kept.length(), 2)
  assert_eq(agnostic.kept[0].id, 1)
  assert_eq(agnostic.kept[0].class_id, 0)
  assert_true(@moontile.merge_envelopes([a, a], 0.5, IoU) is Err(_))
  assert_true(@moontile.merge_envelopes([a], 1.1, IoU) is Err(_))
  let wide = detection(4, 0, 0, 0.9, 0.0, 0.0, 1.0e308, 1.0)
  let tall = detection(5, 0, 0, 0.8, 0.0, 0.0, 1.0, 1.0e308)
  assert_true(@moontile.merge_envelopes([wide, tall], 0.0, IoS) is Err(_))
}
