///|
struct PlanInput {
  image_width : Int
  image_height : Int
  tile_width : Int
  tile_height : Int
  overlap_x : Int
  overlap_y : Int
} derive(FromJson)

///|
pub extend PlanInput with @json.FromJson::{from_json}

///|
/// Plan row-major windows from a JSON request, returning image dimensions and
/// a `tiles` array. Invalid requests return an error without partial output.
pub fn plan_json(source : String) -> Result[String, String] {
  let json = @json.parse(source) catch { _ => return Err("invalid JSON") }
  let input : PlanInput = @json.from_json(json) catch {
    _ => return Err("invalid planning fields")
  }
  let dimensions = [
    ("image_width", input.image_width),
    ("image_height", input.image_height),
    ("tile_width", input.tile_width),
    ("tile_height", input.tile_height),
    ("overlap_x", input.overlap_x),
    ("overlap_y", input.overlap_y),
  ]
  if !integer_fields_match(json, dimensions) {
    return Err("planning fields must be integers")
  }
  let tiles = match
    plan_tiles(
      input.image_width,
      input.image_height,
      input.tile_width,
      input.tile_height,
      input.overlap_x,
      input.overlap_y,
    ) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  Ok(
    Json::object({
      "image_width": input.image_width.to_json(),
      "image_height": input.image_height.to_json(),
      "tiles": tiles.to_json(),
    }).stringify(),
  )
}
