///|
/// Greedily cluster boxes against the original highest-scored seed and replace
/// each cluster by its bounding envelope. Membership is not transitive and
/// the growing envelope is never used to match further boxes. The seed retains
/// its ID, image, tile, class and score; each other member has a trace entry.
/// Matching uses overlap > threshold, with stable input order for equal scores.
pub fn merge_envelopes(
  detections : Array[Detection],
  threshold : Double,
  metric : Overlap,
  class_agnostic? : Bool = false,
) -> Result[MergeResult, String] {
  let ranked = match rank_detections(detections, threshold) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  let consumed : Set[Int] = Set([])
  let kept : Array[Detection] = []
  let merged : Array[Suppression] = []
  let groups : Map[(Int, Int), Array[Detection]] = Map([])
  for (_, candidate) in ranked {
    groups
    .get_or_init(detection_group(candidate, class_agnostic), fn() { [] })
    .push(candidate)
  }
  for (_, seed) in ranked {
    if consumed.contains(seed.id) {
      continue
    }
    consumed.add(seed.id)
    let mut bounds = seed.box
    let group = groups[detection_group(seed, class_agnostic)]
    for candidate in group {
      if consumed.contains(candidate.id) {
        continue
      }
      let value = overlap_value(seed.box, candidate.box, metric)
      if value > threshold {
        bounds = {
          x1: bounds.x1.min(candidate.box.x1),
          y1: bounds.y1.min(candidate.box.y1),
          x2: bounds.x2.max(candidate.box.x2),
          y2: bounds.y2.max(candidate.box.y2),
        }
        if !valid_box(bounds) {
          return Err("merged box is not finite or has invalid area")
        }
        consumed.add(candidate.id)
        merged.push({
          suppressed_id: candidate.id,
          kept_id: seed.id,
          overlap: value,
        })
      }
    }
    kept.push({ ..seed, box: bounds, })
  }
  Ok({ kept, suppressed: merged, })
}
