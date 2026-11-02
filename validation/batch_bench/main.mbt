///|
fn make_groups(
  tile_count : Int,
  per_tile : Int,
) -> Array[@moontile.TilePredictions] {
  let groups : Array[@moontile.TilePredictions] = []
  for tile_id = 0; tile_id < tile_count; tile_id = tile_id + 1 {
    let detections : Array[@moontile.Detection] = []
    for j = 0; j < per_tile; j = j + 1 {
      let id = tile_id * per_tile + j
      detections.push({
        id,
        image_id: 1,
        tile_id,
        class_id: id % 10,
        score: 0.5,
        box: { x1: 1.0, y1: 1.0, x2: 5.0, y2: 5.0, },
      })
    }
    groups.push({
      tile: { id: tile_id, x: 0, y: 0, width: 10, height: 10, },
      detections,
      transform: None,
    })
  }
  groups
}

///|
fn same_detection(a : @moontile.Detection, b : @moontile.Detection) -> Bool {
  a.id == b.id &&
  a.image_id == b.image_id &&
  a.tile_id == b.tile_id &&
  a.class_id == b.class_id &&
  a.score == b.score &&
  a.box.x1 == b.box.x1 &&
  a.box.y1 == b.box.y1 &&
  a.box.x2 == b.box.x2 &&
  a.box.y2 == b.box.y2
}

///|
fn verify_equal(
  a : @moontile.PipelineResult,
  b : @moontile.PipelineResult,
) -> Unit {
  if a.restored.length() != b.restored.length() ||
    a.merged.kept.length() != b.merged.kept.length() ||
    a.merged.suppressed.length() != b.merged.suppressed.length() {
    abort("result lengths differ")
  }
  for i = 0; i < a.restored.length(); i = i + 1 {
    if !same_detection(a.restored[i], b.restored[i]) {
      abort("restored differs")
    }
  }
  for i = 0; i < a.merged.kept.length(); i = i + 1 {
    if !same_detection(a.merged.kept[i], b.merged.kept[i]) {
      abort("kept differs")
    }
  }
  for i = 0; i < a.merged.suppressed.length(); i = i + 1 {
    let x = a.merged.suppressed[i]
    let y = b.merged.suppressed[i]
    if x.kept_id != y.kept_id ||
      x.suppressed_id != y.suppressed_id ||
      x.overlap != y.overlap {
      abort("suppression differs")
    }
  }
}

///|
fn new_acc(
  groups : Array[@moontile.TilePredictions],
) -> @moontile.TileAccumulator {
  let acc = @moontile.TileAccumulator::new(10, 10, {
    threshold: 0.5,
    metric: IoU,
    class_agnostic: false,
    strategy: Nms,
  }).unwrap()
  acc.add_tiles(groups).unwrap()
  acc
}

///|
fn measure_sequential(
  acc : @moontile.TileAccumulator,
  groups : Array[@moontile.TilePredictions],
) -> Double {
  let start = @bench.monotonic_clock_start()
  for group in groups {
    acc.replace_tile(group).unwrap()
  }
  @bench.monotonic_clock_end(start)
}

///|
fn measure_batch(
  acc : @moontile.TileAccumulator,
  groups : Array[@moontile.TilePredictions],
) -> Double {
  let start = @bench.monotonic_clock_start()
  acc.replace_tiles(groups).unwrap()
  @bench.monotonic_clock_end(start)
}

///|
struct RealTile {
  tile : @moontile.Tile
  detections : Array[@moontile.Detection]
} derive(FromJson)

///|
pub extend RealTile with @json.FromJson::{from_json}

///|
struct RealRequest {
  image_width : Int
  image_height : Int
  tiles : Array[RealTile]
} derive(FromJson)

///|
pub extend RealRequest with @json.FromJson::{from_json}

///|
struct RealFixture {
  requests : Array[RealRequest]
} derive(FromJson)

///|
pub extend RealFixture with @json.FromJson::{from_json}

///|
async fn verify_real(path : String) -> Unit {
  let text = @fs.read_file(path).text() catch {
    _ => abort("cannot read real fixture")
  }
  let json = @json.parse(text) catch { _ => abort("invalid real fixture JSON") }
  let fixture : RealFixture = @json.from_json(json) catch {
    _ => abort("invalid real fixture fields")
  }
  if fixture.requests.length() == 0 {
    abort("empty real fixture")
  }
  let mut tiles_checked = 0
  let mut detections_checked = 0
  let mut replacements_checked = 0
  for request in fixture.requests {
    let config : @moontile.MergeConfig = {
      threshold: 0.5,
      metric: IoU,
      class_agnostic: false,
      strategy: Nms,
    }
    let single = @moontile.TileAccumulator::new(
      request.image_width,
      request.image_height,
      config,
    ).unwrap()
    let batch = @moontile.TileAccumulator::new(
      request.image_width,
      request.image_height,
      config,
    ).unwrap()
    let groups : Array[@moontile.TilePredictions] = []
    for group in request.tiles {
      groups.push({
        tile: group.tile,
        detections: group.detections,
        transform: None,
      })
      detections_checked += group.detections.length()
    }
    single.add_tiles(groups).unwrap()
    batch.add_tiles(groups).unwrap()
    let replacements : Array[@moontile.TilePredictions] = []
    for i = groups.length() - 1; i >= 0; i = i - 1 {
      if groups[i].tile.id % 2 == 0 {
        replacements.push(groups[i])
      }
    }
    for group in replacements {
      single.replace_tile(group).unwrap()
    }
    batch.replace_tiles(replacements).unwrap()
    let grid = @moontile.TileGrid::new(
      request.image_width,
      request.image_height,
      256,
      256,
      64,
      64,
    ).unwrap()
    verify_equal(
      single.finish_grid(grid).unwrap(),
      batch.finish_grid(grid).unwrap(),
    )
    tiles_checked += groups.length()
    replacements_checked += replacements.length()
  }
  println(
    Json::object({
      "images": fixture.requests.length().to_json(),
      "tiles": tiles_checked.to_json(),
      "detections": detections_checked.to_json(),
      "replaced_tiles": replacements_checked.to_json(),
      "results_identical": true.to_json(),
    }).stringify(),
  )
}

///|
async fn main {
  let args = @env.args()
  if args.length() == 3 && args[1] == "--real" {
    verify_real(args[2])
    return
  }
  if args.length() != 1 {
    abort("usage: batch_bench [--real FIXTURE.json]")
  }
  let tile_count = 2000
  let per_tile = 20
  let replaced = 500
  let repeats = 5
  let groups = make_groups(tile_count, per_tile)
  let changes : Array[@moontile.TilePredictions] = []
  for i = 0; i < replaced; i = i + 1 {
    changes.push(groups[replaced - 1 - i])
  }
  let before_times : Array[Double] = []
  let batch_times : Array[Double] = []
  // First pair warms both paths; later pairs alternate measurement order.
  for i = 0; i < repeats + 1; i = i + 1 {
    let single = new_acc(groups)
    let batch = new_acc(groups)
    let (single_us, batch_us) = if i % 2 == 0 {
      (measure_sequential(single, changes), measure_batch(batch, changes))
    } else {
      let batch_us = measure_batch(batch, changes)
      let single_us = measure_sequential(single, changes)
      (single_us, batch_us)
    }
    if single.tile_count() != tile_count ||
      batch.tile_count() != tile_count ||
      single.detection_count() != tile_count * per_tile ||
      batch.detection_count() != tile_count * per_tile {
      abort("accumulator counts differ")
    }
    verify_equal(single.finish().unwrap(), batch.finish().unwrap())
    if i > 0 {
      before_times.push(single_us)
      batch_times.push(batch_us)
    }
  }
  println(
    Json::object({
      "tile_count": tile_count.to_json(),
      "detections_per_tile": per_tile.to_json(),
      "replaced_tiles": replaced.to_json(),
      "repeats": repeats.to_json(),
      "warmups": (1).to_json(),
      "sequential_microseconds": before_times.to_json(),
      "batch_microseconds": batch_times.to_json(),
      "results_identical": true.to_json(),
    }).stringify(),
  )
}
