///|
// Straightforward full-scan references preserve the original global ordering.
fn reference_suppress(
  detections : Array[Detection],
  threshold : Double,
  metric : Overlap,
  class_agnostic : Bool,
) -> MergeResult {
  let ranked = rank_detections(detections, threshold).unwrap()
  let kept : Array[Detection] = []
  let suppressed : Array[Suppression] = []
  for (_, candidate) in ranked {
    let mut matched = false
    for previous in kept {
      if previous.image_id == candidate.image_id &&
        (class_agnostic || previous.class_id == candidate.class_id) {
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
    }
    if !matched {
      kept.push(candidate)
    }
  }
  { kept, suppressed, }
}

///|
fn reference_envelopes(
  detections : Array[Detection],
  threshold : Double,
  metric : Overlap,
  class_agnostic : Bool,
) -> MergeResult {
  let ranked = rank_detections(detections, threshold).unwrap()
  let consumed : Set[Int] = Set([])
  let kept : Array[Detection] = []
  let suppressed : Array[Suppression] = []
  for (_, seed) in ranked {
    if consumed.contains(seed.id) {
      continue
    }
    consumed.add(seed.id)
    let mut bounds = seed.box
    for (_, candidate) in ranked {
      if consumed.contains(candidate.id) ||
        seed.image_id != candidate.image_id ||
        (!class_agnostic && seed.class_id != candidate.class_id) {
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
        consumed.add(candidate.id)
        suppressed.push({
          suppressed_id: candidate.id,
          kept_id: seed.id,
          overlap: value,
        })
      }
    }
    kept.push({ ..seed, box: bounds, })
  }
  { kept, suppressed, }
}

///|
fn assert_merge_equal(
  actual : MergeResult,
  expected : MergeResult,
) -> Unit raise {
  assert_eq(actual.kept.length(), expected.kept.length())
  assert_eq(actual.suppressed.length(), expected.suppressed.length())
  for i = 0; i < actual.kept.length(); i = i + 1 {
    let a = actual.kept[i]
    let b = expected.kept[i]
    assert_eq(a.id, b.id)
    assert_eq(a.image_id, b.image_id)
    assert_eq(a.tile_id, b.tile_id)
    assert_eq(a.class_id, b.class_id)
    assert_eq(a.score, b.score)
    assert_eq(a.box.x1, b.box.x1)
    assert_eq(a.box.y1, b.box.y1)
    assert_eq(a.box.x2, b.box.x2)
    assert_eq(a.box.y2, b.box.y2)
  }
  for i = 0; i < actual.suppressed.length(); i = i + 1 {
    assert_eq(actual.suppressed[i].kept_id, expected.suppressed[i].kept_id)
    assert_eq(
      actual.suppressed[i].suppressed_id,
      expected.suppressed[i].suppressed_id,
    )
    assert_eq(actual.suppressed[i].overlap, expected.suppressed[i].overlap)
  }
}

///|
test "grouped algorithms match full-scan references with interleaved groups" {
  let mut cases_with_suppression = 0
  for case = 0; case < 40; case = case + 1 {
    let detections : Array[Detection] = []
    for i = 0; i < 30; i = i + 1 {
      let x = ((i * 7 + case * 3) % 4).to_double()
      let y = ((i * 11 + case * 5) % 4).to_double()
      let w = (6 + (i + case) % 4).to_double()
      let h = (6 + (i * 2 + case) % 4).to_double()
      detections.push({
        id: i,
        image_id: (i * 7 + case) % 3,
        tile_id: i % 4,
        class_id: (i * 5 + case) % 4,
        score: ((i * 7 + case) % 5).to_double() / 5.0,
        box: { x1: x, y1: y, x2: x + w, y2: y + h, },
      })
    }
    for metric in [IoU, IoS] {
      for agnostic in [false, true] {
        for threshold in [0.0, 0.5, 1.0] {
          let result = suppress(
            detections,
            threshold,
            metric,
            class_agnostic=agnostic,
          ).unwrap()
          if result.suppressed.length() > 0 {
            cases_with_suppression = cases_with_suppression + 1
          }
          assert_merge_equal(
            result,
            reference_suppress(detections, threshold, metric, agnostic),
          )
          assert_merge_equal(
            merge_envelopes(
              detections,
              threshold,
              metric,
              class_agnostic=agnostic,
            ).unwrap(),
            reference_envelopes(detections, threshold, metric, agnostic),
          )
        }
      }
    }
  }
  assert_true(cases_with_suppression > 0)
}

///|
test "spatial NMS matches full scan across blocks and orderings" {
  for scenario = 0; scenario < 5; scenario = scenario + 1 {
    let detections : Array[Detection] = []
    for i = 0; i < 260; i = i + 1 {
      let x = if scenario == 0 {
        (i * 3).to_double()
      } else if scenario == 1 {
        10.0
      } else {
        ((i * 47 + scenario * 13) % 83).to_double()
      }
      let y = if scenario == 2 { (i * 19 % 73).to_double() } else { 0.0 }
      let width = if scenario == 3 && i % 37 == 0 { 100.0 } else { 6.0 }
      detections.push({
        id: i,
        image_id: if scenario == 4 {
          i % 2
        } else {
          0
        },
        tile_id: i % 3,
        class_id: if scenario == 4 {
          i % 3
        } else {
          0
        },
        score: (i * 23 % 7).to_double() / 7.0,
        box: { x1: x, y1: y, x2: x + width, y2: y + 6.0, },
      })
    }
    for metric in [IoU, IoS] {
      for agnostic in [false, true] {
        for threshold in [0.0, 0.5, 1.0] {
          assert_merge_equal(
            suppress(detections, threshold, metric, class_agnostic=agnostic).unwrap(),
            reference_suppress(detections, threshold, metric, agnostic),
          )
        }
      }
    }
  }
}
