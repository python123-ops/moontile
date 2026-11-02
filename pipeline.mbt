///|
struct TileInput {
  tile : Tile
  detections : Array[DetectionInput]
  transform : ModelTransform?
  box_format : String?
  coordinate_width : Int?
  coordinate_height : Int?
  clip_local : Bool?
} derive(FromJson)

///|
pub extend TileInput with @json.FromJson::{from_json}

///|
struct TilePlanInput {
  tile_width : Int
  tile_height : Int
  overlap_x : Int
  overlap_y : Int
} derive(FromJson)

///|
pub extend TilePlanInput with @json.FromJson::{from_json}

///|
struct LimitsInput {
  max_tiles : Int
  max_detections : Int
} derive(FromJson)

///|
pub extend LimitsInput with @json.FromJson::{from_json}

///|
struct PipelineInput {
  image_width : Int
  image_height : Int
  threshold : Double
  metric : String
  class_agnostic : Bool
  strategy : String?
  tile_plan : TilePlanInput?
  limits : LimitsInput?
  tiles : Array[TileInput]
} derive(FromJson)

///|
pub extend PipelineInput with @json.FromJson::{from_json}

///|
/// One tile and its detections, with an optional model-input transform.
pub(all) struct TilePredictions {
  tile : Tile
  detections : Array[Detection]
  transform : ModelTransform?
}

///|
/// Choose suppression or non-transitive greedy envelope merging.
pub(all) enum MergeStrategy {
  Nms
  GreedyNmm
}

///|
/// Parameters applied after all tile coordinates have been restored.
pub(all) struct MergeConfig {
  threshold : Double
  metric : Overlap
  class_agnostic : Bool
  strategy : MergeStrategy
}

///|
/// The input-ordered restored detections and the ranked merge result.
pub(all) struct PipelineResult {
  restored : Array[Detection]
  merged : MergeResult
}

///|
fn prepare_data(
  source : String,
) -> Result[(TileAccumulator, TileGrid?), String] {
  let json = @json.parse(source) catch { _ => return Err("invalid JSON") }
  let input : PipelineInput = @json.from_json(json) catch {
    _ => return Err("invalid pipeline fields")
  }
  if !pipeline_integers_match(json, input) {
    return Err("pipeline dimensions and IDs must be integers")
  }
  let metric = match input.metric {
    "iou" => IoU
    "ios" => IoS
    _ => return Err("metric must be iou or ios")
  }
  let strategy = match input.strategy {
    None | Some("nms") => Nms
    Some("greedy_nmm") => GreedyNmm
    Some(_) => return Err("strategy must be nms or greedy_nmm")
  }
  let limits : AccumulatorLimits? = match input.limits {
    None => None
    Some(value) => {
      if value.max_tiles < 0 || value.max_detections < 0 {
        return Err("accumulator limits must be nonnegative")
      }
      if input.tiles.length() > value.max_tiles {
        return Err("tile limit exceeded")
      }
      let mut available = value.max_detections
      for group in input.tiles {
        if group.detections.length() > available {
          return Err("detection limit exceeded")
        }
        available -= group.detections.length()
      }
      Some({ max_tiles: value.max_tiles, max_detections: value.max_detections, })
    }
  }
  let tiles : Array[TilePredictions] = []
  for group in input.tiles {
    match decode_tile_predictions(group) {
      Ok(value) => tiles.push(value)
      Err(message) => return Err(message)
    }
  }
  let grid = match input.tile_plan {
    None => None
    Some(plan) => {
      let grid = match
        TileGrid::new(
          input.image_width,
          input.image_height,
          plan.tile_width,
          plan.tile_height,
          plan.overlap_x,
          plan.overlap_y,
        ) {
        Ok(value) => value
        Err(message) => return Err(message)
      }
      Some(grid)
    }
  }
  let accumulator = match
    prepare_accumulator(
      input.image_width,
      input.image_height,
      tiles,
      {
        threshold: input.threshold,
        metric,
        class_agnostic: input.class_agnostic,
        strategy,
      },
      limits,
    ) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  Ok((accumulator, grid))
}

///|
fn process_data(source : String) -> Result[PipelineResult, String] {
  let (accumulator, grid) = match prepare_data(source) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  match grid {
    Some(value) => accumulator.finish_grid_take(value)
    None => accumulator.finish_take()
  }
}

///|
/// Restore and merge all tile detections atomically; invalid or duplicate tile
/// or detection IDs, invalid transforms, and invalid dimensions return Err.
/// All slices in one call share image dimensions; NMS isolates image IDs.
pub fn process_tiles(
  image_width : Int,
  image_height : Int,
  tiles : Array[TilePredictions],
  config : MergeConfig,
) -> Result[PipelineResult, String] {
  process_with_grid(image_width, image_height, tiles, config, None)
}

///|
fn process_with_grid(
  image_width : Int,
  image_height : Int,
  tiles : Array[TilePredictions],
  config : MergeConfig,
  grid : TileGrid?,
) -> Result[PipelineResult, String] {
  let accumulator = match
    prepare_accumulator(image_width, image_height, tiles, config, None) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  match grid {
    Some(value) => accumulator.finish_grid_take(value)
    None => accumulator.finish_take()
  }
}

///|
fn prepare_accumulator(
  image_width : Int,
  image_height : Int,
  tiles : Array[TilePredictions],
  config : MergeConfig,
  limits : AccumulatorLimits?,
) -> Result[TileAccumulator, String] {
  let created = match limits {
    None => TileAccumulator::new(image_width, image_height, config)
    Some(value) =>
      TileAccumulator::new_limited(image_width, image_height, config, value)
  }
  let accumulator = match created {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  for group in tiles {
    match accumulator.add_tile(group) {
      Ok(_) => ()
      Err(message) => return Err(message)
    }
  }
  Ok(accumulator)
}

///|
fn merge_restored(
  restored : Array[Detection],
  config : MergeConfig,
) -> Result[PipelineResult, String] {
  let merged = match config.strategy {
    Nms =>
      suppress(
        restored,
        config.threshold,
        config.metric,
        class_agnostic=config.class_agnostic,
      )
    GreedyNmm =>
      merge_envelopes(
        restored,
        config.threshold,
        config.metric,
        class_agnostic=config.class_agnostic,
      )
  }
  let result = match merged {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  Ok({ restored, merged: result, })
}

///|
/// Process one JSON document with per-tile box formats and return the trace.
pub fn process_json(source : String) -> Result[String, String] {
  let processed = match process_data(source) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  Ok(pipeline_result_json(processed).stringify())
}

///|
fn pipeline_result_json(processed : PipelineResult) -> Json {
  let trace = processed.merged.suppressed.map(fn(item) {
    Json::object({
      "suppressed_id": item.suppressed_id.to_json(),
      "kept_id": item.kept_id.to_json(),
      "overlap": item.overlap.to_json(),
    })
  })
  Json::object({
    "restored": processed.restored.to_json(),
    "kept": processed.merged.kept.to_json(),
    "suppressed": trace.to_json(),
  })
}

///|
/// Inspect a pipeline JSON document with a required tile_plan, without merging.
/// Invalid input returns an error; ID samples are bounded independently.
pub fn inspect_grid_json(
  source : String,
  max_reported? : Int = 100,
) -> Result[String, String] {
  let (accumulator, grid) = match prepare_data(source) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  let grid = match grid {
    Some(value) => value
    None => return Err("tile_plan is required for inspection")
  }
  let report = match accumulator.inspect_grid(grid, max_reported~) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  Ok(
    Json::object({
      "expected_tiles": report.expected_tiles.to_json(),
      "received_tiles": report.received_tiles.to_json(),
      "missing_count": report.missing_count.to_json(),
      "mismatched_count": report.mismatched_count.to_json(),
      "unexpected_count": report.unexpected_count.to_json(),
      "missing_ids": report.missing_ids.to_json(),
      "mismatched_ids": report.mismatched_ids.to_json(),
      "unexpected_ids": report.unexpected_ids.to_json(),
      "mixed_images": report.mixed_images.to_json(),
      "complete": report.is_complete().to_json(),
    }).stringify(),
  )
}
