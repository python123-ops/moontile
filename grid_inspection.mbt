///|
/// Summary of a grid inspection. ID samples are sorted and limited per kind.
/// Empty prediction groups have no image ID to inspect.
pub(all) struct GridInspection {
  expected_tiles : Int
  received_tiles : Int
  missing_count : Int
  mismatched_count : Int
  unexpected_count : Int
  missing_ids : Array[Int]
  mismatched_ids : Array[Int]
  unexpected_ids : Array[Int]
  mixed_images : Bool
}

///|
/// Whether the inspected state meets the window and image rules of finish_grid.
pub fn GridInspection::is_complete(self : GridInspection) -> Bool {
  self.missing_count == 0 &&
  self.mismatched_count == 0 &&
  self.unexpected_count == 0 &&
  !self.mixed_images
}

///|
// Retain the smallest `limit` IDs in a max heap, independent of map order.
fn retain_smallest(heap : Array[Int], value : Int, limit : Int) -> Unit {
  if limit == 0 {
    return
  }
  if heap.length() < limit {
    heap.push(value)
    let mut child = heap.length() - 1
    while child > 0 {
      let parent = (child - 1) / 2
      if heap[parent] >= heap[child] {
        break
      }
      let saved = heap[parent]
      heap[parent] = heap[child]
      heap[child] = saved
      child = parent
    }
  } else if value < heap[0] {
    heap[0] = value
    let mut parent = 0
    while true {
      let left = parent * 2 + 1
      if left >= heap.length() {
        break
      }
      let right = left + 1
      let larger = if right < heap.length() && heap[right] > heap[left] {
        right
      } else {
        left
      }
      if heap[parent] >= heap[larger] {
        break
      }
      let saved = heap[parent]
      heap[parent] = heap[larger]
      heap[larger] = saved
      parent = larger
    }
  }
}

///|
/// Inspect planned versus accepted windows without merging or changing state.
/// Each sample contains at most max_reported IDs (default 100, range 0..10000).
/// Counts remain complete; samples contain the lowest IDs in ascending order.
/// Image dimensions must match. Memory used by samples is O(max_reported).
pub fn TileAccumulator::inspect_grid(
  self : TileAccumulator,
  grid : TileGrid,
  max_reported? : Int = 100,
) -> Result[GridInspection, String] {
  if max_reported < 0 || max_reported > 10000 {
    return Err("max_reported must be in [0,10000]")
  }
  if self.image_width != grid.width || self.image_height != grid.height {
    return Err("grid and accumulator image dimensions differ")
  }
  let missing_ids : Array[Int] = []
  let mismatched_ids : Array[Int] = []
  let unexpected_ids : Array[Int] = []
  let mut missing_count = 0
  let mut mismatched_count = 0
  let mut unexpected_count = 0
  for id = 0; id < grid.length(); id = id + 1 {
    match self.tile_windows.get(id) {
      None => {
        missing_count += 1
        if missing_ids.length() < max_reported {
          missing_ids.push(id)
        }
      }
      Some(actual) => {
        let expected = match grid.get(id) {
          Some(tile) => tile
          None => return Err("invalid grid tile \\{id}")
        }
        if actual.x != expected.x ||
          actual.y != expected.y ||
          actual.width != expected.width ||
          actual.height != expected.height {
          mismatched_count += 1
          if mismatched_ids.length() < max_reported {
            mismatched_ids.push(id)
          }
        }
      }
    }
  }
  for id, _ in self.tile_windows {
    if id < 0 || id >= grid.length() {
      unexpected_count += 1
      retain_smallest(unexpected_ids, id, max_reported)
    }
  }
  unexpected_ids.sort()
  Ok({
    expected_tiles: grid.length(),
    received_tiles: self.tile_count(),
    missing_count,
    mismatched_count,
    unexpected_count,
    missing_ids,
    mismatched_ids,
    unexpected_ids,
    mixed_images: !single_image(self.restored),
  })
}
