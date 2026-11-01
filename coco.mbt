///|
/// Explicit mapping between a detector class and a COCO category ID.
pub(all) struct CategoryMapping {
  class_id : Int
  category_id : Int
} derive(FromJson)

///|
pub extend CategoryMapping with @json.FromJson::{from_json}

///|
/// Export detections to a COCO bbox result array. Category IDs are explicitly
/// mapped; duplicate class mappings, missing mappings and invalid records fail.
/// Coordinates are continuous xywh. Input order is preserved and no clipping
/// or additional NMS is applied.
pub fn export_coco(
  detections : Array[Detection],
  mappings : Array[CategoryMapping],
) -> Result[String, String] {
  let mapping : Map[Int, Int] = Map([])
  for entry in mappings {
    if entry.class_id < 0 || entry.category_id < 0 {
      return Err("class and category IDs must be nonnegative")
    }
    if mapping.contains(entry.class_id) {
      return Err("duplicate class mapping: \{entry.class_id}")
    }
    mapping[entry.class_id] = entry.category_id
  }
  let ids : Set[Int] = Set([])
  let output : Array[Json] = []
  for record in detections {
    if record.id < 0 ||
      record.image_id < 0 ||
      record.tile_id < 0 ||
      record.class_id < 0 ||
      !finite(record.score) ||
      record.score < 0.0 ||
      record.score > 1.0 ||
      !valid_box(record.box) {
      return Err("invalid detection: \{record.id}")
    }
    if !ids.add_and_check(record.id) {
      return Err("duplicate detection id: \{record.id}")
    }
    let category = match mapping.get(record.class_id) {
      Some(value) => value
      None => return Err("missing mapping for class: \{record.class_id}")
    }
    let b = record.box
    output.push(
      Json::object({
        "image_id": record.image_id.to_json(),
        "category_id": category.to_json(),
        "bbox": [b.x1, b.y1, b.x2 - b.x1, b.y2 - b.y1].to_json(),
        "score": record.score.to_json(),
      }),
    )
  }
  Ok(output.to_json().stringify())
}

///|
/// Run the standard JSON pipeline, then export kept boxes using a JSON array
/// of {class_id, category_id} mapping objects. Errors produce no partial JSON.
pub fn process_coco_json(
  source : String,
  mapping_source : String,
) -> Result[String, String] {
  let json = @json.parse(mapping_source) catch {
    _ => return Err("invalid mapping JSON")
  }
  let mappings : Array[CategoryMapping] = @json.from_json(json) catch {
    _ => return Err("invalid mapping fields")
  }
  let entries = match json {
    Array(values) => values
    _ => return Err("invalid mapping fields")
  }
  if entries.length() != mappings.length() {
    return Err("invalid mapping fields")
  }
  for i = 0; i < mappings.length(); i = i + 1 {
    let entry = mappings[i]
    if !integer_fields_match(entries[i], [
        ("class_id", entry.class_id),
        ("category_id", entry.category_id),
      ]) {
      return Err("mapping IDs must be integers")
    }
  }
  let processed = match process_data(source) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  export_coco(processed.merged.kept, mappings)
}
