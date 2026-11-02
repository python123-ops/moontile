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
  let groups : Map[(Int, Int), Array[Int]] = Map([])
  for index, (_, candidate) in ranked {
    groups
    .get_or_init(detection_group(candidate, class_agnostic), fn() { [] })
    .push(index)
  }
  let accepted = Array::make(ranked.length(), false)
  let reasons : Array[Suppression?] = Array::make(ranked.length(), None)
  for _, group in groups {
    if group.length() <= 64 {
      for index in group {
        let candidate = ranked[index].1
        for previous_index in group {
          if previous_index == index {
            break
          }
          if accepted[previous_index] {
            let previous = ranked[previous_index].1
            let value = overlap_value(previous.box, candidate.box, metric)
            if value > threshold {
              reasons[index] = Some({
                suppressed_id: candidate.id,
                kept_id: previous.id,
                overlap: value,
              })
              break
            }
          }
        }
        if reasons[index] is None {
          accepted[index] = true
        }
      }
    } else {
      let spatial = group.copy()
      spatial.sort_by(fn(a, b) {
        let x = ranked[a].1.box.x1.compare(ranked[b].1.box.x1)
        if x == 0 {
          a.compare(b)
        } else {
          x
        }
      })
      let blocks : Array[NmsBlock] = []
      for start = 0; start < spatial.length(); start = start + 64 {
        let end = (start + 64).min(spatial.length())
        let first = ranked[spatial[start]].1.box
        let mut max_x = first.x2
        let mut min_y = first.y1
        let mut max_y = first.y2
        let mut min_rank = spatial[start]
        for i = start + 1; i < end; i = i + 1 {
          let box = ranked[spatial[i]].1.box
          max_x = max_x.max(box.x2)
          min_y = min_y.min(box.y1)
          max_y = max_y.max(box.y2)
          min_rank = min_rank.min(spatial[i])
        }
        blocks.push({
          start,
          end,
          min_x: first.x1,
          max_x,
          min_y,
          max_y,
          min_rank,
        })
      }
      for index in group {
        let candidate = ranked[index].1
        let box = candidate.box
        let mut best = index
        let mut best_value = 0.0
        for block in blocks {
          if block.min_x >= box.x2 {
            break
          }
          if block.max_x <= box.x1 ||
            block.min_y >= box.y2 ||
            block.max_y <= box.y1 ||
            block.min_rank >= best {
            continue
          }
          for i = block.start; i < block.end; i = i + 1 {
            let previous_index = spatial[i]
            if previous_index >= best || !accepted[previous_index] {
              continue
            }
            let previous = ranked[previous_index].1
            if previous.box.x1 >= box.x2 ||
              previous.box.x2 <= box.x1 ||
              previous.box.y1 >= box.y2 ||
              previous.box.y2 <= box.y1 {
              continue
            }
            let value = overlap_value(previous.box, box, metric)
            if value > threshold {
              best = previous_index
              best_value = value
            }
          }
          if best == group[0] {
            break
          }
        }
        if best == index {
          accepted[index] = true
        } else {
          reasons[index] = Some({
            suppressed_id: candidate.id,
            kept_id: ranked[best].1.id,
            overlap: best_value,
          })
        }
      }
    }
  }
  for index, (_, candidate) in ranked {
    match reasons[index] {
      Some(reason) => suppressed.push(reason)
      None => kept.push(candidate)
    }
  }
  Ok({ kept, suppressed, })
}

///|
// Bounds of x-sorted detections; min_rank preserves greedy tie-breaking.
priv struct NmsBlock {
  start : Int
  end : Int
  min_x : Double
  max_x : Double
  min_y : Double
  max_y : Double
  min_rank : Int
}
