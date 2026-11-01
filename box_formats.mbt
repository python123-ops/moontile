///|
/// Convert a continuous pixel xywh box to xyxy. Width and height must be
/// finite and positive. Negative origins are allowed for later clipping.
pub fn Box::from_xywh(
  x : Double,
  y : Double,
  width : Double,
  height : Double,
) -> Result[Box, String] {
  if !finite(width) || !finite(height) || width <= 0.0 || height <= 0.0 {
    return Err("box width and height must be finite and positive")
  }
  let result : Box = { x1: x, y1: y, x2: x + width, y2: y + height, }
  if !valid_box(result) {
    return Err("box coordinates or area are not representable")
  }
  Ok(result)
}

///|
/// Convert a normalized xyxy box to continuous pixels in the stated coordinate
/// space. All normalized edges must be in [0,1], with positive area.
pub fn Box::from_normalized_xyxy(
  x1 : Double,
  y1 : Double,
  x2 : Double,
  y2 : Double,
  image_width : Int,
  image_height : Int,
) -> Result[Box, String] {
  if image_width <= 0 || image_height <= 0 {
    return Err("coordinate-space dimensions must be positive")
  }
  let normalized : Box = { x1, y1, x2, y2, }
  if !valid_box(normalized) || x1 < 0.0 || y1 < 0.0 || x2 > 1.0 || y2 > 1.0 {
    return Err("normalized box must have positive area inside [0,1]")
  }
  let width = image_width.to_double()
  let height = image_height.to_double()
  let pixels : Box = {
    x1: x1 * width,
    y1: y1 * height,
    x2: x2 * width,
    y2: y2 * height,
  }
  if !valid_box(pixels) {
    return Err("pixel box coordinates or area are not representable")
  }
  Ok(pixels)
}

///|
/// Convert normalized center-x, center-y, width, height (YOLO-style) to
/// continuous pixel xyxy. The whole box must lie within normalized [0,1].
pub fn Box::from_normalized_cxcywh(
  center_x : Double,
  center_y : Double,
  width : Double,
  height : Double,
  image_width : Int,
  image_height : Int,
) -> Result[Box, String] {
  if !finite(center_x) ||
    !finite(center_y) ||
    !finite(width) ||
    !finite(height) ||
    width <= 0.0 ||
    height <= 0.0 {
    return Err("center must be finite and box dimensions finite and positive")
  }
  Box::from_normalized_xyxy(
    center_x - width / 2.0,
    center_y - height / 2.0,
    center_x + width / 2.0,
    center_y + height / 2.0,
    image_width,
    image_height,
  )
}
