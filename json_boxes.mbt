///|
struct DetectionInput {
  id : Int
  image_id : Int
  tile_id : Int
  class_id : Int
  score : Double
  box : Json
} derive(FromJson)

///|
pub extend DetectionInput with @json.FromJson::{from_json}

///|
struct InputXywh {
  x : Double
  y : Double
  width : Double
  height : Double
} derive(FromJson)

///|
pub extend InputXywh with @json.FromJson::{from_json}

///|
struct InputCenterBox {
  cx : Double
  cy : Double
  width : Double
  height : Double
} derive(FromJson)

///|
pub extend InputCenterBox with @json.FromJson::{from_json}

///|
priv enum InputBoxFormat {
  PixelXyxy
  PixelXywh
  NormalizedXyxy(Int, Int)
  NormalizedCenter(Int, Int)
}

///|
fn input_box_format(group : TileInput) -> Result[InputBoxFormat, String] {
  let width = group.coordinate_width
  let height = group.coordinate_height
  match (width, height) {
    (Some(w), Some(h)) if w > 0 && h > 0 => ()
    (None, None) => ()
    _ => return Err("coordinate dimensions must both be positive integers")
  }
  match group.box_format {
    None | Some("xyxy") => Ok(PixelXyxy)
    Some("xywh") => Ok(PixelXywh)
    Some("normalized_xyxy") | Some("normalized_cxcywh") => {
      let (w, h) = match (width, height) {
        (Some(w), Some(h)) => (w, h)
        _ => return Err("normalized boxes require coordinate dimensions")
      }
      if group.transform is None &&
        (w != group.tile.width || h != group.tile.height) {
        return Err("normalized tile dimensions must match the tile")
      }
      if group.box_format is Some("normalized_xyxy") {
        Ok(NormalizedXyxy(w, h))
      } else {
        Ok(NormalizedCenter(w, h))
      }
    }
    Some(_) => Err("unknown box format")
  }
}

///|
fn decode_input_box(
  json : Json,
  format : InputBoxFormat,
) -> Result[Box, String] {
  match format {
    PixelXyxy | NormalizedXyxy(_, _) => {
      let box : Box = @json.from_json(json) catch {
        _ => return Err("invalid xyxy box fields")
      }
      match format {
        NormalizedXyxy(w, h) =>
          Box::from_normalized_xyxy(box.x1, box.y1, box.x2, box.y2, w, h)
        _ => Ok(box)
      }
    }
    PixelXywh => {
      let box : InputXywh = @json.from_json(json) catch {
        _ => return Err("invalid xywh box fields")
      }
      Box::from_xywh(box.x, box.y, box.width, box.height)
    }
    NormalizedCenter(w, h) => {
      let box : InputCenterBox = @json.from_json(json) catch {
        _ => return Err("invalid normalized center box fields")
      }
      Box::from_normalized_cxcywh(box.cx, box.cy, box.width, box.height, w, h)
    }
  }
}

///|
fn decode_tile_predictions(
  group : TileInput,
) -> Result[TilePredictions, String] {
  let format = match input_box_format(group) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  let transform = match group.clip_local {
    Some(true) => {
      if group.transform is Some(_) {
        return Err("clip_local cannot be combined with transform")
      }
      match format {
        NormalizedXyxy(_, _) | NormalizedCenter(_, _) =>
          return Err("clip_local requires pixel box coordinates")
        _ => ()
      }
      Some({ scale_x: 1.0, scale_y: 1.0, pad_x: 0.0, pad_y: 0.0, clip: true, })
    }
    _ => group.transform
  }
  let detections : Array[Detection] = []
  for input in group.detections {
    let box = match decode_input_box(input.box, format) {
      Ok(value) => value
      Err(message) => return Err(message)
    }
    detections.push({
      id: input.id,
      image_id: input.image_id,
      tile_id: input.tile_id,
      class_id: input.class_id,
      score: input.score,
      box,
    })
  }
  Ok({ tile: group.tile, detections, transform, })
}
