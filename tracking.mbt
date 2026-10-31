///|
fn single_image(detections : Array[Detection]) -> Bool {
  if detections.length() == 0 {
    return true
  }
  let image_id = detections[0].image_id
  for detection in detections {
    if detection.image_id != image_id {
      return false
    }
  }
  true
}

///|
/// Export original-image detections as one MBMOT replay input line. Frame must
/// be positive and records must belong to one image. Input order is preserved.
/// Image and tile IDs are not part of the MBMOT wire format.
pub fn export_mbmot(
  detections : Array[Detection],
  frame : Int,
) -> Result[String, String] {
  if frame <= 0 {
    return Err("frame must be positive")
  }
  if !single_image(detections) {
    return Err("one frame cannot contain multiple image IDs")
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
    let b = record.box
    output.push(
      Json::object({
        "xyxy": [b.x1, b.y1, b.x2, b.y2].to_json(),
        "score": record.score.to_json(),
        "class_id": record.class_id.to_json(),
      }),
    )
  }
  Ok(
    Json::object({ "frame": frame.to_json(), "detections": output.to_json() }).stringify(),
  )
}

///|
/// Run the tile pipeline and export the kept detections for one MBMOT frame.
/// Kept boxes follow input order, preserving detector ordering for tracking.
/// Multiple image IDs are rejected before suppression.
pub fn process_mbmot_json(
  source : String,
  frame : Int,
) -> Result[String, String] {
  if frame <= 0 {
    return Err("frame must be positive")
  }
  let processed = match process_data(source) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  if !single_image(processed.restored) {
    return Err("one frame cannot contain multiple image IDs")
  }
  let kept_by_id : Map[Int, Detection] = Map([])
  for detection in processed.merged.kept {
    kept_by_id[detection.id] = detection
  }
  let ordered : Array[Detection] = []
  for detection in processed.restored {
    match kept_by_id.get(detection.id) {
      Some(merged) => ordered.push(merged)
      None => ()
    }
  }
  export_mbmot(ordered, frame)
}
