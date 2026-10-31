///|
/// A half-open pixel window. Tile IDs are row-major and start at zero.
pub(all) struct Tile {
  id : Int
  x : Int
  y : Int
  width : Int
  height : Int
} derive(FromJson, ToJson)

///|
/// Continuous xyxy coordinates, with no pixel-endpoint adjustment.
pub(all) struct Box {
  x1 : Double
  y1 : Double
  x2 : Double
  y2 : Double
} derive(FromJson, ToJson)

///|
/// Each record retains its image, tile, class, score and input identity.
pub(all) struct Detection {
  id : Int
  image_id : Int
  tile_id : Int
  class_id : Int
  score : Double
  box : Box
} derive(FromJson, ToJson)

///|
pub(all) enum Overlap {
  IoU
  IoS
}

///|
pub(all) struct Suppression {
  suppressed_id : Int
  kept_id : Int
  overlap : Double
}

///|
pub(all) struct MergeResult {
  kept : Array[Detection]
  suppressed : Array[Suppression]
}

///|
fn finite(x : Double) -> Bool {
  !x.is_nan() && !x.is_inf()
}

///|
fn valid_box(b : Box) -> Bool {
  finite(b.x1) &&
  finite(b.y1) &&
  finite(b.x2) &&
  finite(b.y2) &&
  b.x2 > b.x1 &&
  b.y2 > b.y1 &&
  finite((b.x2 - b.x1) * (b.y2 - b.y1)) &&
  (b.x2 - b.x1) * (b.y2 - b.y1) > 0.0
}

///|
pub extend Tile with @json.FromJson::{from_json}

///|
pub extend Tile with ToJson::{to_json}

///|
pub extend Box with @json.FromJson::{from_json}

///|
pub extend Box with ToJson::{to_json}

///|
pub extend Detection with @json.FromJson::{from_json}

///|
pub extend Detection with ToJson::{to_json}
