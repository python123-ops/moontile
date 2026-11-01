///|
/// Accumulate validated tile predictions before a global, score-ranked merge.
/// A failed add leaves all previously accepted tiles and detections unchanged.
pub struct TileAccumulator {
  image_width : Int
  image_height : Int
  config : MergeConfig
  tile_windows : Map[Int, Tile]
  detection_ids : Set[Int]
  restored : Array[Detection]
}

///|
/// Create an empty accumulator. Dimensions and threshold are validated now.
pub fn TileAccumulator::new(
  image_width : Int,
  image_height : Int,
  config : MergeConfig,
) -> Result[TileAccumulator, String] {
  if image_width <= 0 || image_height <= 0 {
    return Err("invalid image dimensions")
  }
  if !finite(config.threshold) ||
    config.threshold < 0.0 ||
    config.threshold > 1.0 {
    return Err("threshold must be finite and in [0,1]")
  }
  Ok({
    image_width,
    image_height,
    config,
    tile_windows: Map([]),
    detection_ids: Set([]),
    restored: [],
  })
}

///|
/// Number of successfully added tiles, including empty tiles.
pub fn TileAccumulator::tile_count(self : TileAccumulator) -> Int {
  self.tile_windows.length()
}

///|
/// Number of accepted detections before merging.
pub fn TileAccumulator::detection_count(self : TileAccumulator) -> Int {
  self.restored.length()
}

///|
/// Validate and restore one tile atomically. Tile and detection IDs must be
/// unique within the accumulator, including IDs in the same added tile.
pub fn TileAccumulator::add_tile(
  self : TileAccumulator,
  group : TilePredictions,
) -> Result[Unit, String] {
  self.add_tiles([group])
}

///|
/// Validate and restore a batch atomically. An empty batch is a no-op.
/// Input order is preserved. Duplicate IDs within the batch or against prior
/// additions reject the whole batch without changing the accumulator.
pub fn TileAccumulator::add_tiles(
  self : TileAccumulator,
  groups : Array[TilePredictions],
) -> Result[Unit, String] {
  let pending : Array[Detection] = []
  let pending_ids : Set[Int] = Set([])
  let pending_tiles : Set[Int] = Set([])
  for group in groups {
    match self.stage_tile(group, pending, pending_ids, pending_tiles) {
      Ok(_) => ()
      Err(message) => return Err(message)
    }
  }
  for group in groups {
    self.tile_windows[group.tile.id] = group.tile
  }
  for record in pending {
    self.detection_ids.add(record.id)
    self.restored.push(record)
  }
  Ok(())
}

///|
// Stage one tile in temporary storage, without mutating the accumulator.
fn TileAccumulator::stage_tile(
  self : TileAccumulator,
  group : TilePredictions,
  pending : Array[Detection],
  pending_ids : Set[Int],
  pending_tiles : Set[Int],
) -> Result[Unit, String] {
  let tile = group.tile
  if self.tile_windows.contains(tile.id) ||
    !pending_tiles.add_and_check(tile.id) {
    return Err("duplicate tile id")
  }
  match group.transform {
    Some(transform) =>
      if !valid_transform(transform) {
        return Err("invalid model transform")
      }
    None => ()
  }
  if tile.id < 0 ||
    tile.x < 0 ||
    tile.y < 0 ||
    tile.width <= 0 ||
    tile.height <= 0 ||
    tile.width > self.image_width ||
    tile.height > self.image_height ||
    tile.x > self.image_width - tile.width ||
    tile.y > self.image_height - tile.height {
    return Err("invalid tile or image dimensions")
  }
  for record in group.detections {
    let result = match group.transform {
      Some(transform) =>
        restore_model(
          tile,
          record,
          self.image_width,
          self.image_height,
          transform,
        )
      None => restore(tile, record, self.image_width, self.image_height)
    }
    let restored = match result {
      Ok(value) => value
      Err(message) => return Err(message)
    }
    if self.detection_ids.contains(restored.id) ||
      !pending_ids.add_and_check(restored.id) {
      return Err("duplicate detection id")
    }
    pending.push(restored)
  }
  Ok(())
}

///|
/// Merge all accepted detections and return an independent snapshot. Does not
/// clear the accumulator; later additions are included in later snapshots.
pub fn TileAccumulator::finish(
  self : TileAccumulator,
) -> Result[PipelineResult, String] {
  merge_restored(self.restored.copy(), self.config)
}

///|
/// Merge only after every window in the supplied grid was added exactly once
/// with its planned geometry. All detections must share one image ID.
/// Empty prediction tiles count as received; their image cannot be verified.
/// A failure leaves the accumulator unchanged so missing tiles can be added.
pub fn TileAccumulator::finish_grid(
  self : TileAccumulator,
  grid : TileGrid,
) -> Result[PipelineResult, String] {
  if self.image_width != grid.width || self.image_height != grid.height {
    return Err("grid and accumulator image dimensions differ")
  }
  if !single_image(self.restored) {
    return Err("grid cannot contain multiple image IDs")
  }
  if self.tile_windows.length() != grid.length() {
    return Err("tile count does not match grid")
  }
  for id = 0; id < grid.length(); id = id + 1 {
    let actual = match self.tile_windows.get(id) {
      Some(value) => value
      None => return Err("missing grid tile \{id}")
    }
    let expected = match grid.get(id) {
      Some(value) => value
      None => return Err("invalid grid tile \{id}")
    }
    if actual.x != expected.x ||
      actual.y != expected.y ||
      actual.width != expected.width ||
      actual.height != expected.height {
      return Err("tile geometry differs from grid at \{id}")
    }
  }
  self.finish()
}

///|
/// Remove all accepted data while retaining image dimensions and configuration.
pub fn TileAccumulator::reset(self : TileAccumulator) -> Unit {
  self.tile_windows.clear()
  self.detection_ids.clear()
  self.restored.clear()
}
