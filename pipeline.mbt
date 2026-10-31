///|
struct TileInput {
  tile : Tile
  detections : Array[Detection]
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
priv struct Processed {
  restored : Array[Detection]
  merged : MergeResult
}

///|
fn process_data(source : String) -> Result[Processed, String] {
  let json = @json.parse(source) catch { _ => return Err("invalid JSON") }
  let input : PipelineInput = @json.from_json(json) catch {
    _ => return Err("invalid pipeline fields")
  }
  let metric = match input.metric {
    "iou" => IoU
    "ios" => IoS
    _ => return Err("metric must be iou or ios")
  }
  let restored : Array[Detection] = []
  let tile_ids : Set[Int] = Set([])
  for group in input.tiles {
    if !tile_ids.add_and_check(group.tile.id) {
      return Err("duplicate tile id")
    }
    let t = group.tile
    if input.image_width <= 0 ||
      input.image_height <= 0 ||
      t.id < 0 ||
      t.x < 0 ||
      t.y < 0 ||
      t.width <= 0 ||
      t.height <= 0 ||
      t.width > input.image_width ||
      t.height > input.image_height ||
      t.x > input.image_width - t.width ||
      t.y > input.image_height - t.height {
      return Err("invalid tile or image dimensions")
    }
    for record in group.detections {
      match restore(t, record, input.image_width, input.image_height) {
        Ok(value) => restored.push(value)
        Err(message) => return Err(message)
      }
    }
  }
  if input.image_width <= 0 || input.image_height <= 0 {
    return Err("invalid image dimensions")
  }
  let merged = match input.strategy {
    None | Some("nms") =>
      suppress(
        restored,
        input.threshold,
        metric,
        class_agnostic=input.class_agnostic,
      )
    Some("greedy_nmm") =>
      merge_envelopes(
        restored,
        input.threshold,
        metric,
        class_agnostic=input.class_agnostic,
      )
    Some(_) => return Err("strategy must be nms or greedy_nmm")
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
  let trace = processed.merged.suppressed.map(fn(item) {
    Json::object({
      "suppressed_id": item.suppressed_id.to_json(),
      "kept_id": item.kept_id.to_json(),
      "overlap": item.overlap.to_json(),
    })
  })
  Ok(
    Json::object({
      "restored": processed.restored.to_json(),
      "kept": processed.merged.kept.to_json(),
      "suppressed": trace.to_json(),
    }).stringify(),
  )
}
