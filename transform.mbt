///|
/// Forward model preprocessing: model = local * scale + padding, per axis.
/// Set clip to intersect the inverted box with the tile before restoration.
pub(all) struct ModelTransform {
  scale_x : Double
  scale_y : Double
  pad_x : Double
  pad_y : Double
  clip : Bool
} derive(FromJson)

///|
pub extend ModelTransform with @json.FromJson::{from_json}

///|
fn valid_transform(t : ModelTransform) -> Bool {
  finite(t.scale_x) &&
  finite(t.scale_y) &&
  t.scale_x > 0.0 &&
  t.scale_y > 0.0 &&
  finite(t.pad_x) &&
  finite(t.pad_y) &&
  t.pad_x >= 0.0 &&
  t.pad_y >= 0.0
}

///|
/// Invert explicit resizing and padding, then translate to image coordinates.
/// Model boxes use absolute continuous xyxy pixels, not normalized coordinates.
pub fn restore_model(
  tile : Tile,
  detection : Detection,
  image_width : Int,
  image_height : Int,
  transform : ModelTransform,
) -> Result[Detection, String] {
  if !valid_transform(transform) {
    return Err("invalid model transform")
  }
  let b = detection.box
  if !valid_box(b) {
    return Err("invalid model box")
  }
  let x1 = (b.x1 - transform.pad_x) / transform.scale_x
  let y1 = (b.y1 - transform.pad_y) / transform.scale_y
  let x2 = (b.x2 - transform.pad_x) / transform.scale_x
  let y2 = (b.y2 - transform.pad_y) / transform.scale_y
  if !finite(x1) || !finite(y1) || !finite(x2) || !finite(y2) {
    return Err("model transform produced non-finite coordinates")
  }
  let local_box = if transform.clip {
    {
      x1: x1.max(0.0).min(tile.width.to_double()),
      y1: y1.max(0.0).min(tile.height.to_double()),
      x2: x2.max(0.0).min(tile.width.to_double()),
      y2: y2.max(0.0).min(tile.height.to_double()),
    }
  } else {
    { x1, y1, x2, y2, }
  }
  restore(tile, { ..detection, box: local_box, }, image_width, image_height)
}

///|
/// Intersect a local pixel box with the tile before translating to the image.
/// Fully outside, degenerate, non-finite or otherwise invalid inputs return Err.
pub fn restore_clipped(
  tile : Tile,
  detection : Detection,
  image_width : Int,
  image_height : Int,
) -> Result[Detection, String] {
  restore_model(tile, detection, image_width, image_height, {
    scale_x: 1.0,
    scale_y: 1.0,
    pad_x: 0.0,
    pad_y: 0.0,
    clip: true,
  })
}
