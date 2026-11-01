///|
// FromJson for Int can truncate fractions; compare decoded values to the JSON
// numbers before accepting identity and dimension fields at the wire boundary.
fn integer_fields_match(json : Json, expected : Array[(String, Int)]) -> Bool {
  let object = match json {
    Object(value) => value
    _ => return false
  }
  for (name, value) in expected {
    match object.get(name) {
      Some(Number(number, ..)) if number == value.to_double() => ()
      _ => return false
    }
  }
  true
}

///|
fn json_field(json : Json, name : String) -> Json? {
  match json {
    Object(fields) => fields.get(name)
    _ => None
  }
}

///|
fn pipeline_integers_match(json : Json, input : PipelineInput) -> Bool {
  if !integer_fields_match(json, [
      ("image_width", input.image_width),
      ("image_height", input.image_height),
    ]) {
    return false
  }
  match input.tile_plan {
    Some(plan) => {
      let plan_json = match json_field(json, "tile_plan") {
        Some(value) => value
        None => return false
      }
      if !integer_fields_match(plan_json, [
          ("tile_width", plan.tile_width),
          ("tile_height", plan.tile_height),
          ("overlap_x", plan.overlap_x),
          ("overlap_y", plan.overlap_y),
        ]) {
        return false
      }
    }
    None => ()
  }
  let groups = match json_field(json, "tiles") {
    Some(Array(values)) => values
    _ => return false
  }
  if groups.length() != input.tiles.length() {
    return false
  }
  for i = 0; i < groups.length(); i = i + 1 {
    let group = input.tiles[i]
    for
      (name, value) in [
        ("coordinate_width", group.coordinate_width),
        ("coordinate_height", group.coordinate_height),
      ] {
      match (json_field(groups[i], name), value) {
        (None | Some(Null), None) => ()
        (Some(Number(number, ..)), Some(integer)) if number ==
          integer.to_double() => ()
        _ => return false
      }
    }
    let tile = group.tile
    let tile_json = match json_field(groups[i], "tile") {
      Some(value) => value
      None => return false
    }
    if !integer_fields_match(tile_json, [
        ("id", tile.id),
        ("x", tile.x),
        ("y", tile.y),
        ("width", tile.width),
        ("height", tile.height),
      ]) {
      return false
    }
    let detections = match json_field(groups[i], "detections") {
      Some(Array(values)) => values
      _ => return false
    }
    if detections.length() != group.detections.length() {
      return false
    }
    for j = 0; j < detections.length(); j = j + 1 {
      let record = group.detections[j]
      if !integer_fields_match(detections[j], [
          ("id", record.id),
          ("image_id", record.image_id),
          ("tile_id", record.tile_id),
          ("class_id", record.class_id),
        ]) {
        return false
      }
    }
  }
  true
}
