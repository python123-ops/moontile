///|
struct FixtureTile {
  tile : @moontile.Tile
  detections : Array[@moontile.Detection]
} derive(FromJson)

///|
pub extend FixtureTile with @json.FromJson::{from_json}

///|
struct FixtureRequest {
  image_width : Int
  image_height : Int
  tiles : Array[FixtureTile]
} derive(FromJson)

///|
pub extend FixtureRequest with @json.FromJson::{from_json}

///|
struct Fixture {
  requests : Array[FixtureRequest]
} derive(FromJson)

///|
pub extend Fixture with @json.FromJson::{from_json}

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
fn check_results(
  a : @moontile.PipelineResult,
  b : @moontile.PipelineResult,
) -> Unit {
  if a.restored.length() != b.restored.length() ||
    a.merged.kept.length() != b.merged.kept.length() ||
    a.merged.suppressed.length() != b.merged.suppressed.length() {
    abort("result count mismatch")
  }
  for i = 0; i < a.restored.length(); i = i + 1 {
    if !same_detection(a.restored[i], b.restored[i]) {
      abort("restored mismatch")
    }
  }
  for i = 0; i < a.merged.kept.length(); i = i + 1 {
    if !same_detection(a.merged.kept[i], b.merged.kept[i]) {
      abort("kept mismatch")
    }
  }
  for i = 0; i < a.merged.suppressed.length(); i = i + 1 {
    let x = a.merged.suppressed[i]
    let y = b.merged.suppressed[i]
    if x.kept_id != y.kept_id ||
      x.suppressed_id != y.suppressed_id ||
      x.overlap != y.overlap {
      abort("suppression mismatch")
    }
  }
}

///|
async fn main {
  let args = @env.args()
  if args.length() != 2 {
    abort("usage: grid_inspect FIXTURE.json")
  }
  let text = @fs.read_file(args[1]).text() catch {
    _ => abort("cannot read fixture")
  }
  let json = @json.parse(text) catch { _ => abort("invalid fixture JSON") }
  let fixture : Fixture = @json.from_json(json) catch {
    _ => abort("invalid fixture fields")
  }
  if fixture.requests.length() == 0 {
    abort("empty fixture")
  }
  let mut tiles = 0
  let mut detections = 0
  for request in fixture.requests {
    if request.tiles.length() < 2 {
      abort("fixture must have at least two windows per image")
    }
    let grid = @moontile.TileGrid::new(
      request.image_width,
      request.image_height,
      256,
      256,
      64,
      64,
    ).unwrap()
    let config : @moontile.MergeConfig = {
      threshold: 0.5,
      metric: IoU,
      class_agnostic: false,
      strategy: Nms,
    }
    let acc = @moontile.TileAccumulator::new(
      request.image_width,
      request.image_height,
      config,
    ).unwrap()
    let groups : Array[@moontile.TilePredictions] = []
    let mut image_detections = 0
    for item in request.tiles {
      groups.push({
        tile: item.tile,
        detections: item.detections,
        transform: None,
      })
      detections += item.detections.length()
      image_detections += item.detections.length()
    }
    let bounded = @moontile.TileAccumulator::new_limited(
      request.image_width,
      request.image_height,
      config,
      { max_tiles: groups.length(), max_detections: image_detections, },
    ).unwrap()
    bounded.add_tiles(groups).unwrap()
    let expected_bounded = @moontile.process_tiles(
      request.image_width,
      request.image_height,
      groups,
      config,
    ).unwrap()
    check_results(bounded.finish_grid_take(grid).unwrap(), expected_bounded)
    if image_detections > 0 {
      let too_small = @moontile.TileAccumulator::new_limited(
        request.image_width,
        request.image_height,
        config,
        { max_tiles: groups.length(), max_detections: image_detections - 1, },
      ).unwrap()
      if too_small.add_tiles(groups) is Ok(_) ||
        too_small.tile_count() != 0 ||
        too_small.detection_count() != 0 {
        abort("bounded batch was not rejected atomically")
      }
    }
    if groups[0].tile.id != 0 ||
      groups[1].tile.id != 1 ||
      groups[1].tile.width <= 1 {
      abort("unexpected fixture window order")
    }
    // Inject a missing window, an undersized window and an extra empty window.
    acc
    .add_tile({
      ..groups[1],
      tile: { ..groups[1].tile, width: groups[1].tile.width - 1, },
      detections: [],
    })
    .unwrap()
    for i = 2; i < groups.length(); i = i + 1 {
      acc.add_tile(groups[i]).unwrap()
    }
    let extra = grid.length() + 5
    acc
    .add_tile({
      tile: { id: extra, x: 0, y: 0, width: 1, height: 1, },
      detections: [],
      transform: None,
    })
    .unwrap()
    let report = acc.inspect_grid(grid, max_reported=1).unwrap()
    if report.missing_count != 1 ||
      report.missing_ids != [0] ||
      report.mismatched_count != 1 ||
      report.mismatched_ids != [1] ||
      report.unexpected_count != 1 ||
      report.unexpected_ids != [extra] ||
      report.mixed_images ||
      report.is_complete() {
      abort("inspection did not identify injected issues")
    }
    acc.replace_tile(groups[1]).unwrap()
    acc.add_tile(groups[0]).unwrap()
    acc.remove_tile(extra).unwrap()
    if !acc.inspect_grid(grid, max_reported=0).unwrap().is_complete() {
      abort("repaired grid is not complete")
    }
    // Replacement and re-addition move those windows to the end.
    let ordered : Array[@moontile.TilePredictions] = []
    for i = 2; i < groups.length(); i = i + 1 {
      ordered.push(groups[i])
    }
    ordered.push(groups[1])
    ordered.push(groups[0])
    let expected = @moontile.process_tiles(
      request.image_width,
      request.image_height,
      ordered,
      config,
    ).unwrap()
    let snapshot = acc.finish_grid(grid).unwrap()
    check_results(snapshot, expected)
    let taken = acc.finish_grid_take(grid).unwrap()
    check_results(taken, snapshot)
    if acc.tile_count() != 0 || acc.detection_count() != 0 {
      abort("take did not reset accumulator")
    }
    acc.add_tiles(ordered).unwrap()
    check_results(acc.finish_take().unwrap(), expected)
    check_results(taken, expected)
    if acc.tile_count() != 0 || acc.detection_count() != 0 {
      abort("reused accumulator did not reset")
    }
    tiles += groups.length()
  }
  println(
    Json::object({
      "images": fixture.requests.length().to_json(),
      "tiles": tiles.to_json(),
      "detections": detections.to_json(),
      "repairs_verified": fixture.requests.length().to_json(),
      "outputs_identical": true.to_json(),
      "take_and_reuse_verified": fixture.requests.length().to_json(),
      "bounded_inputs_verified": fixture.requests.length().to_json(),
    }).stringify(),
  )
}
