///|
/// Accumulate validated tile predictions before a global, score-ranked merge.
/// A failed add leaves all previously accepted tiles and detections unchanged.
pub struct TileAccumulator {
  image_width : Int
  image_height : Int
  config : MergeConfig
  tile_ids : Set[Int]
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
    tile_ids: Set([]),
    detection_ids: Set([]),
    restored: [],
  })
}

///|
/// Number of successfully added tiles, including empty tiles.
pub fn TileAccumulator::tile_count(self : TileAccumulator) -> Int {
  self.tile_ids.length()
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
  let tile = group.tile
  if self.tile_ids.contains(tile.id) {
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
  let pending : Array[Detection] = []
  let pending_ids : Set[Int] = Set([])
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
  self.tile_ids.add(tile.id)
  for record in pending {
    self.detection_ids.add(record.id)
    self.restored.push(record)
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
/// Remove all accepted data while retaining image dimensions and configuration.
pub fn TileAccumulator::reset(self : TileAccumulator) -> Unit {
  self.tile_ids.clear()
  self.detection_ids.clear()
  self.restored.clear()
}
