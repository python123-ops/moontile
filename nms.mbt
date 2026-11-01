///|
fn overlap_value(a : Box, b : Box, metric : Overlap) -> Double {
  let w = (a.x2.min(b.x2) - a.x1.max(b.x1)).max(0.0)
  let h = (a.y2.min(b.y2) - a.y1.max(b.y1)).max(0.0)
  let intersection = w * h
  let aa = (a.x2 - a.x1) * (a.y2 - a.y1)
  let bb = (b.x2 - b.x1) * (b.y2 - b.y1)
  match metric {
    IoU => {
      let scale = aa.max(bb)
      let numerator = intersection / scale
      numerator / (aa / scale + bb / scale - numerator)
    }
    IoS => intersection / aa.min(bb)
  }
}

///|
fn rank_detections(
  detections : Array[Detection],
  threshold : Double,
) -> Result[Array[(Int, Detection)], String] {
  if !finite(threshold) || threshold < 0.0 || threshold > 1.0 {
    return Err("threshold must be finite and in [0,1]")
  }
  let ids : Set[Int] = Set([])
  let ranked : Array[(Int, Detection)] = []
  for index, detection in detections {
    if detection.id < 0 ||
      detection.image_id < 0 ||
      detection.tile_id < 0 ||
      detection.class_id < 0 ||
      !finite(detection.score) ||
      detection.score < 0.0 ||
      detection.score > 1.0 ||
      !valid_box(detection.box) {
      return Err("invalid detection")
    }
    if !ids.add_and_check(detection.id) {
      return Err("duplicate detection id")
    }
    ranked.push((index, detection))
  }
  ranked.sort_by(fn(a, b) {
    if a.1.score > b.1.score {
      -1
    } else if a.1.score < b.1.score {
      1
    } else {
      a.0.compare(b.0)
    }
  })
  Ok(ranked)
}

///|
// Global rank stays authoritative; this key only narrows possible matches.
fn detection_group(detection : Detection, class_agnostic : Bool) -> (Int, Int) {
  (detection.image_id, if class_agnostic { 0 } else { detection.class_id })
}

///|
/// Greedy NMS per image and class. Suppresses when overlap > threshold.
/// Equal scores retain input order. IDs must be unique in the whole batch.
pub fn suppress(
  detections : Array[Detection],
  threshold : Double,
  metric : Overlap,
  class_agnostic? : Bool = false,
) -> Result[MergeResult, String] {
  let ranked = match rank_detections(detections, threshold) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  let kept : Array[Detection] = []
  let suppressed : Array[Suppression] = []
  let groups : Map[(Int, Int), Array[Detection]] = Map([])
  for (_, candidate) in ranked {
    let group = groups.get_or_init(detection_group(candidate, class_agnostic), fn() {
      []
    })
    let mut matched = false
    for previous in group {
      let value = overlap_value(previous.box, candidate.box, metric)
      if value > threshold {
        suppressed.push({
          suppressed_id: candidate.id,
          kept_id: previous.id,
          overlap: value,
        })
        matched = true
        break
      }
    }
    if !matched {
      kept.push(candidate)
      group.push(candidate)
    }
  }
  Ok({ kept, suppressed, })
}
