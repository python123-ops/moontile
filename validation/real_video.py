"""Replay the MBMOT sample's real HOG detections through MoonTile.

One full-image tile is used per frame. This checks conversion and tracking
continuity; it does not measure tiled inference or tracking accuracy.
"""
import argparse
import hashlib
import json
import subprocess
from pathlib import Path


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--detections", required=True, type=Path)
    parser.add_argument("--moontile", required=True, type=Path)
    parser.add_argument("--mbmot", required=True, type=Path)
    parser.add_argument("--mbmot-revision", required=True)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    source = args.detections.read_text(encoding="utf8")
    frames = [json.loads(line) for line in source.splitlines() if line.strip()]
    if not frames:
        raise SystemExit("empty detection stream")
    requests = []
    previous = 0
    total = 0
    reordered_inputs = 0
    for item in frames:
        frame = item["frame"]
        if not isinstance(frame, int) or frame <= previous:
            raise SystemExit("frame IDs must strictly increase from a positive number")
        previous = frame
        values = item["detections"]
        total += len(values)
        if any(values[i]["score"] < values[i + 1]["score"] for i in range(len(values) - 1)):
            reordered_inputs += 1
        detections = []
        for index, detection in enumerate(values):
            x1, y1, x2, y2 = detection["xyxy"]
            detections.append({"id": index, "image_id": frame, "tile_id": 0,
                               "class_id": detection["class_id"], "score": detection["score"],
                               "box": {"x1": x1, "y1": y1, "x2": x2, "y2": y2}})
        request = {"image_width": 768, "image_height": 576, "threshold": 1.0, "metric": "iou",
                   "class_agnostic": False, "tiles": [{"tile": {"id": 0, "x": 0, "y": 0,
                   "width": 768, "height": 576}, "detections": detections}]}
        requests.append({"frame": frame, "input": request})
    requests_ndjson = "".join(json.dumps(item, separators=(",", ":")) + "\n" for item in requests)
    output = subprocess.check_output([str(args.moontile.resolve()), "--mbmot-stream"], input=requests_ndjson, text=True)
    converted = [json.loads(line) for line in output.splitlines()]
    if converted != frames:
        raise AssertionError("detection data, frame count, or order changed during stream conversion")
    stream = "".join(json.dumps(frame, separators=(",", ":")) + "\n" for frame in frames)
    replay = "".join(json.dumps(frame, separators=(",", ":")) + "\n" for frame in converted)
    original_tracks = subprocess.check_output([str(args.mbmot.resolve())], input=stream, text=True)
    converted_tracks = subprocess.check_output([str(args.mbmot.resolve())], input=replay, text=True)
    expected = [json.loads(line) for line in original_tracks.splitlines()]
    actual = [json.loads(line) for line in converted_tracks.splitlines()]
    if expected != actual or len(actual) != len(frames):
        raise AssertionError("MBMOT tracking results changed")
    report = {"status": "passed", "command": "python validation/real_video.py --detections <detections.ndjson> --moontile <native-cli> --mbmot <mbmot-replay> --mbmot-revision <commit> --output validation/real-video-results.json",
              "dataset": "MBMOT 90-frame HOG detection stream from OpenCV vtest.avi",
              "source": "https://github.com/python123-ops/mbmot/tree/main/examples/video",
              "detection_sha256": digest(args.detections), "moontile_binary_sha256": digest(args.moontile),
              "mbmot_binary_sha256": digest(args.mbmot), "mbmot_source_revision": args.mbmot_revision, "dimensions": [768, 576],
              "frames": len(frames), "detections": total, "frames_not_score_sorted": reordered_inputs,
              "moontile_invocations": 1, "protocol": "--mbmot-stream",
              "threshold": 1.0, "matched_tracking_frames": len(actual),
              "scope": "Existing whole-frame predictions; one tile per frame. Not an accuracy or real tiled-inference benchmark."}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf8")
    print(json.dumps(report))


if __name__ == "__main__":
    main()
