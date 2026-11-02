///|
fn build_acc(count : Int) -> @moontile.TileAccumulator {
  let acc = @moontile.TileAccumulator::new(10, 10, {
    threshold: 0.5,
    metric: IoU,
    class_agnostic: false,
    strategy: Nms,
  }).unwrap()
  let per_tile = 1000
  let tiles = (count + per_tile - 1) / per_tile
  for tile_id = 0; tile_id < tiles; tile_id = tile_id + 1 {
    let records : Array[@moontile.Detection] = []
    let start = tile_id * per_tile
    let end = (start + per_tile).min(count)
    for id = start; id < end; id = id + 1 {
      records.push({
        id,
        image_id: 1,
        tile_id,
        class_id: id % 10,
        score: 0.5,
        box: { x1: 1.0, y1: 1.0, x2: 5.0, y2: 5.0, },
      })
    }
    acc
    .add_tile({
      tile: { id: tile_id, x: 0, y: 0, width: 10, height: 10, },
      detections: records,
      transform: None,
    })
    .unwrap()
  }
  acc
}

///|
fn verify(result : @moontile.PipelineResult, count : Int) -> Unit {
  if result.restored.length() != count ||
    result.merged.kept.length() != 10 ||
    result.merged.suppressed.length() != count - 10 {
    abort("unexpected result counts")
  }
  for id = 0; id < count; id = id + 1 {
    let d = result.restored[id]
    if d.id != id ||
      d.tile_id != id / 1000 ||
      d.class_id != id % 10 ||
      d.image_id != 1 ||
      d.score != 0.5 ||
      d.box.x1 != 1.0 ||
      d.box.y1 != 1.0 ||
      d.box.x2 != 5.0 ||
      d.box.y2 != 5.0 {
      abort("restored record mismatch")
    }
  }
  for i = 0; i < 10; i = i + 1 {
    if result.merged.kept[i].id != i {
      abort("kept order mismatch")
    }
  }
  for i = 0; i < count - 10; i = i + 1 {
    let trace = result.merged.suppressed[i]
    if trace.suppressed_id != i + 10 ||
      trace.kept_id != (i + 10) % 10 ||
      trace.overlap != 1.0 {
      abort("suppression mismatch")
    }
  }
}

///|
fn main {
  let args = @env.args()
  if args.length() != 3 {
    abort("usage: memory_scale COUNT snapshot|take")
  }
  let count = @string.parse_int(args[1], base=10) catch {
    _ => abort("invalid count")
  }
  if count < 10 || count > 1000000 {
    abort("count outside [10,1000000]")
  }
  let acc = build_acc(count)
  let start = @bench.monotonic_clock_start()
  let result = match args[2] {
    "snapshot" => acc.finish().unwrap()
    "take" => acc.finish_take().unwrap()
    _ => abort("invalid mode")
  }
  let elapsed = @bench.monotonic_clock_end(start)
  verify(result, count)
  if args[2] == "take" && (acc.tile_count() != 0 || acc.detection_count() != 0) {
    abort("take did not clear accumulator")
  }
  if args[2] == "snapshot" && acc.detection_count() != count {
    abort("snapshot changed accumulator")
  }
  println(
    Json::object({
      "count": count.to_json(),
      "mode": args[2].to_json(),
      "restored": result.restored.length().to_json(),
      "kept": result.merged.kept.length().to_json(),
      "suppressed": result.merged.suppressed.length().to_json(),
      "merge_microseconds": elapsed.to_json(),
      "verified": true.to_json(),
    }).stringify(),
  )
}
