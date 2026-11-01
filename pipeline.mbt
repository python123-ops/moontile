///|
struct TileInput {
  tile : Tile
  detections : Array[Detection]
  transform : ModelTransform?
} derive(FromJson)

///|
pub extend TileInput with @json.FromJson::{from_json}

///|
struct PipelineInput {
  image_width : Int
  image_height : Int
  threshold : Double
  metric : String
  class_agnostic : Bool
  strategy : String?
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
fn process_data(source : String) -> Result[PipelineResult, String] {
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
  let tiles : Array[TilePredictions] = input.tiles.map(fn(group) {
    {
      tile: group.tile,
      detections: group.detections,
      transform: group.transform,
    }
  })
  process_tiles(input.image_width, input.image_height, tiles, {
    threshold: input.threshold,
    metric,
    class_agnostic: input.class_agnostic,
    strategy,
  })
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
  let restored : Array[Detection] = []
  let tile_ids : Set[Int] = Set([])
  for group in tiles {
    if !tile_ids.add_and_check(group.tile.id) {
      return Err("duplicate tile id")
    }
    let t = group.tile
    match group.transform {
      Some(transform) =>
        if !valid_transform(transform) {
          return Err("invalid model transform")
        }
      None => ()
    }
    if image_width <= 0 ||
      image_height <= 0 ||
      t.id < 0 ||
      t.x < 0 ||
      t.y < 0 ||
      t.width <= 0 ||
      t.height <= 0 ||
      t.width > image_width ||
      t.height > image_height ||
      t.x > image_width - t.width ||
      t.y > image_height - t.height {
      return Err("invalid tile or image dimensions")
    }
    for record in group.detections {
      let result = match group.transform {
        Some(transform) =>
          restore_model(t, record, image_width, image_height, transform)
        None => restore(t, record, image_width, image_height)
      }
      match result {
        Ok(value) => restored.push(value)
        Err(message) => return Err(message)
      }
    }
  }
  if image_width <= 0 || image_height <= 0 {
    return Err("invalid image dimensions")
  }
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
/// Process one JSON document with local xyxy boxes and return the NMS trace.
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
