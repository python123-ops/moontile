///|
/// Map a MoonTile detection to MBMOT's continuous xyxy input.
pub fn to_tracker(
  d : @moontile.Detection,
) -> @mbmot.Detection raise @mbmot.TrackerError {
  let b = d.box
  @mbmot.Detection::new(
    @mbmot.BoundingBox::new(b.x1, b.y1, b.x2, b.y2),
    d.score,
    d.class_id,
  )
}

///|
/// Callers provide the COCO category ID explicitly; the two ID spaces differ.
pub fn to_evaluator(
  d : @moontile.Detection,
  category_id : Int,
) -> @moondeteval.Detection raise @moondeteval.EvalError {
  let b = d.box
  let box = @moondeteval.Box::from_xywh(b.x1, b.y1, b.x2 - b.x1, b.y2 - b.y1)
  @moondeteval.Detection::new(d.id, d.image_id, category_id, box, d.score)
}
