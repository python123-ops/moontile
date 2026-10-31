///|
/// Generate row-major tiles, anchoring the last window to each image edge.
/// Overlap is in pixels and must be smaller than the requested tile size.
pub fn plan_tiles(
  width : Int,
  height : Int,
  tile_width : Int,
  tile_height : Int,
  overlap_x : Int,
  overlap_y : Int,
) -> Result[Array[Tile], String] {
  if width <= 0 || height <= 0 || tile_width <= 0 || tile_height <= 0 {
    return Err("image and tile dimensions must be positive")
  }
  if overlap_x < 0 ||
    overlap_y < 0 ||
    overlap_x >= tile_width ||
    overlap_y >= tile_height {
    return Err("overlap must be nonnegative and smaller than tile size")
  }
  let tw = tile_width.min(width)
  let th = tile_height.min(height)
  let sx = tile_width - overlap_x
  let sy = tile_height - overlap_y
  let result : Array[Tile] = []
  let mut y = 0
  for ;; {
    let mut x = 0
    for ;; {
      if result.length() >= 1000000 {
        return Err("tile count exceeds 1000000")
      }
      result.push({ id: result.length(), x, y, width: tw, height: th, })
      if x == width - tw {
        break
      }
      x = x + sx.min(width - tw - x)
    }
    if y == height - th {
      break
    }
    y = y + sy.min(height - th - y)
  }
  Ok(result)
}

///|
/// Translate a local box, rejecting invalid tiles and boxes outside the tile.
/// No clipping is performed.
pub fn restore(
  tile : Tile,
  detection : Detection,
  image_width : Int,
  image_height : Int,
) -> Result[Detection, String] {
  if image_width <= 0 ||
    image_height <= 0 ||
    tile.id < 0 ||
    tile.x < 0 ||
    tile.y < 0 ||
    tile.width <= 0 ||
    tile.height <= 0 ||
    tile.width > image_width ||
    tile.height > image_height ||
    tile.x > image_width - tile.width ||
    tile.y > image_height - tile.height {
    return Err("invalid tile or image dimensions")
  }
  let b = detection.box
  if detection.id < 0 ||
    detection.image_id < 0 ||
    detection.class_id < 0 ||
    detection.tile_id != tile.id ||
    !finite(detection.score) ||
    detection.score < 0.0 ||
    detection.score > 1.0 {
    return Err("invalid detection identity, tile, class or score")
  }
  if !valid_box(b) ||
    b.x1 < 0.0 ||
    b.y1 < 0.0 ||
    b.x2 > tile.width.to_double() ||
    b.y2 > tile.height.to_double() {
    return Err("box must be finite, positive and inside tile")
  }
  let dx = tile.x.to_double()
  let dy = tile.y.to_double()
  Ok({
    ..detection,
    box: { x1: b.x1 + dx, y1: b.y1 + dy, x2: b.x2 + dx, y2: b.y2 + dy, },
  })
}
