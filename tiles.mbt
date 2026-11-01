///|
/// A validated, row-major tile layout that computes each window on demand.
pub struct TileGrid {
  width : Int
  height : Int
  tile_width : Int
  tile_height : Int
  step_x : Int
  step_y : Int
  columns : Int
  count : Int
}

///|
/// Validate dimensions and count windows without allocating a tile array.
/// As with plan_tiles, layouts with more than one million windows are rejected.
pub fn TileGrid::new(
  width : Int,
  height : Int,
  tile_width : Int,
  tile_height : Int,
  overlap_x : Int,
  overlap_y : Int,
) -> Result[TileGrid, String] {
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
  let dx = width - tw
  let dy = height - th
  // ceil(distance / step) + 1, without overflowing distance + step.
  let columns = if dx == 0 { 1 } else { (dx - 1) / sx + 2 }
  let rows = if dy == 0 { 1 } else { (dy - 1) / sy + 2 }
  if columns > 1000000 || rows > 1000000 / columns {
    return Err("tile count exceeds 1000000")
  }
  Ok({
    width,
    height,
    tile_width: tw,
    tile_height: th,
    step_x: sx,
    step_y: sy,
    columns,
    count: columns * rows,
  })
}

///|
/// Number of windows in the layout.
pub fn TileGrid::length(self : TileGrid) -> Int {
  self.count
}

///|
/// Get a row-major window by stable ID; invalid IDs return None.
pub fn TileGrid::get(self : TileGrid, id : Int) -> Tile? {
  if id < 0 || id >= self.count {
    return None
  }
  let col = id % self.columns
  let row = id / self.columns
  // The final step can overshoot the edge, so avoid multiplying it.
  let x = if col == self.columns - 1 {
    self.width - self.tile_width
  } else {
    col * self.step_x
  }
  let rows = self.count / self.columns
  let y = if row == rows - 1 {
    self.height - self.tile_height
  } else {
    row * self.step_y
  }
  Some({ id, x, y, width: self.tile_width, height: self.tile_height, })
}

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
  let grid = match
    TileGrid::new(width, height, tile_width, tile_height, overlap_x, overlap_y) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  let result : Array[Tile] = []
  for id = 0; id < grid.length(); id = id + 1 {
    match grid.get(id) {
      Some(tile) => result.push(tile)
      None => return Err("invalid tile index")
    }
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
  let translated = {
    x1: b.x1 + dx,
    y1: b.y1 + dy,
    x2: b.x2 + dx,
    y2: b.y2 + dy,
  }
  if !valid_box(translated) {
    return Err("translated box lost positive area or is not finite")
  }
  Ok({ ..detection, box: translated, })
}
