"""Replay previously generated full-image COCO predictions through MoonTile.

This checks real-data plumbing, not sliced inference or model improvement.
Requires pycocotools and local COCO ground truths/predictions from the same run.
"""
import argparse
import contextlib
import hashlib
import io
import json
import math
import subprocess
import sys
import tempfile
from collections import defaultdict
from pathlib import Path

from pycocotools.coco import COCO
from pycocotools.cocoeval import COCOeval
import importlib.metadata


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def evaluate(ground_truth, predictions, image_ids):
    with contextlib.redirect_stdout(io.StringIO()):
        coco = COCO(str(ground_truth))
        result = coco.loadRes(predictions)
        evaluation = COCOeval(coco, result, "bbox")
        evaluation.params.imgIds = image_ids
        evaluation.evaluate()
        evaluation.accumulate()
        evaluation.summarize()
    return [float(value) for value in evaluation.stats]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--ground-truth", required=True, type=Path)
    parser.add_argument("--predictions", required=True, type=Path)
    parser.add_argument("--provenance", required=True, type=Path)
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--count", type=int, default=10)
    parser.add_argument("--input-format", choices=("xyxy", "xywh", "normalized_xyxy", "normalized_cxcywh"), default="xyxy")
    args = parser.parse_args()
    truth = json.loads(args.ground_truth.read_text(encoding="utf8"))
    predictions = json.loads(args.predictions.read_text(encoding="utf8"))
    provenance = json.loads(args.provenance.read_text(encoding="utf8"))
    hashes = provenance["inputs"]
    if digest(args.ground_truth) != hashes["ground_truth_sha256"] or digest(args.predictions) != hashes["predictions_sha256"]:
        raise SystemExit("inputs do not match the supplied provenance hashes")
    images = {image["id"]: image for image in truth["images"]}
    if args.count < 1 or args.count > len(images):
        raise SystemExit("count outside available image range")
    image_ids = sorted(images)[:args.count]
    grouped = defaultdict(list)
    rejected = 0
    for item in predictions:
        if item["image_id"] not in image_ids:
            continue
        image = images[item["image_id"]]
        x, y, w, h = item["bbox"]
        score = item["score"]
        if not all(math.isfinite(v) for v in (x, y, w, h, score)) or w <= 0 or h <= 0 or x < 0 or y < 0 or x + w > image["width"] or y + h > image["height"] or not 0 <= score <= 1:
            rejected += 1
            continue
        grouped[item["image_id"]].append(item)
    baseline, actual, exported = [], [], []
    with tempfile.TemporaryDirectory(prefix="moontile-coco-") as tmp:
        input_path = Path(tmp) / "input.json"
        mapping_path = Path(tmp) / "mapping.json"
        mapping_path.write_text(json.dumps([{"class_id": category["id"], "category_id": category["id"]}
                                            for category in truth["categories"]]), encoding="utf8")
        for image_id in image_ids:
            image = images[image_id]
            records = grouped[image_id]
            detections = []
            for index, item in enumerate(records):
                x, y, w, h = item["bbox"]
                if args.input_format == "xywh":
                    box = {"x": x, "y": y, "width": w, "height": h}
                elif args.input_format == "normalized_xyxy":
                    box = {"x1": x / image["width"], "y1": y / image["height"],
                           "x2": (x + w) / image["width"], "y2": (y + h) / image["height"]}
                elif args.input_format == "normalized_cxcywh":
                    box = {"cx": (x + w / 2) / image["width"], "cy": (y + h / 2) / image["height"],
                           "width": w / image["width"], "height": h / image["height"]}
                else:
                    box = {"x1": x, "y1": y, "x2": x + w, "y2": y + h}
                detections.append({"id": index, "image_id": image_id, "tile_id": 0,
                                   "class_id": item["category_id"], "score": item["score"], "box": box})
            request = {"image_width": image["width"], "image_height": image["height"], "threshold": 1.0,
                       "metric": "iou", "class_agnostic": False, "tiles": [{"tile": {"id": 0, "x": 0, "y": 0,
                       "width": image["width"], "height": image["height"]}, "detections": detections}]}
            if args.input_format != "xyxy":
                request["tiles"][0]["box_format"] = args.input_format
            if args.input_format.startswith("normalized_"):
                request["tiles"][0]["coordinate_width"] = image["width"]
                request["tiles"][0]["coordinate_height"] = image["height"]
            input_path.write_text(json.dumps(request), encoding="utf8")
            result = json.loads(subprocess.check_output([str(args.binary.resolve()), str(input_path)], text=True))
            coco_output = json.loads(subprocess.check_output([str(args.binary.resolve()), str(input_path),
                                                               "--coco-map", str(mapping_path)], text=True))
            if len(result["kept"]) != len(records) or result["suppressed"]:
                raise AssertionError(f"unexpected suppression on image {image_id}")
            if len(coco_output) != len(records):
                raise AssertionError(f"COCO export count mismatch on image {image_id}")
            exported.extend(coco_output)
            baseline.extend(records)
            # Preserve input ordering, which matters for tied confidence scores.
            by_id = {item["id"]: item for item in result["kept"]}
            for index in range(len(records)):
                item = by_id[index]
                box = item["box"]
                actual.append({"image_id": image_id, "category_id": item["class_id"], "score": item["score"],
                               "bbox": [box["x1"], box["y1"], box["x2"] - box["x1"], box["y2"] - box["y1"]]})
    if not baseline:
        raise SystemExit("no valid predictions in selected images")
    for source, result in zip(baseline, actual):
        if any(source[key] != result[key] for key in ("image_id", "category_id", "score")):
            raise AssertionError("image, category, score or order changed during replay")
    coordinate_error = max(abs(left - right) for source, result in zip(baseline, actual)
                           for left, right in zip(source["bbox"], result["bbox"]))
    if coordinate_error > 1e-8:
        raise AssertionError(f"COCO box coordinate drift {coordinate_error}")
    before = evaluate(args.ground_truth, baseline, image_ids)
    after = evaluate(args.ground_truth, actual, image_ids)
    coco_stats = evaluate(args.ground_truth, exported, image_ids)
    error = max(abs(a - b) for a, b in zip(before, after))
    export_error = max(abs(a - b) for a, b in zip(before, coco_stats))
    if error > 1e-9:
        raise AssertionError(f"COCO metric drift {error}")
    if export_error > 1e-9:
        raise AssertionError(f"COCO export metric drift {export_error}")
    report = {"status": "passed", "command": f"python validation/real_coco.py --ground-truth <ground_truth.json> --predictions <predictions.json> --provenance <results.json> --binary <native-cli> --count {args.count} --input-format {args.input_format} --output <output.json>",
              "python": sys.version.split()[0], "pycocotools": importlib.metadata.version("pycocotools"), "binary_sha256": digest(args.binary),
              "dataset": provenance["dataset"], "annotation_url": provenance["annotation_url"],
              "original_annotation_sha256": provenance["annotation_sha256"],
              "original_run_seed": provenance["seed"], "model": provenance["model"], "model_url": provenance["model_url"],
              "model_sha256": provenance["model_sha256"], "inference": provenance["inference"],
              "input_sha256": {"ground_truth": digest(args.ground_truth), "predictions": digest(args.predictions)},
              "image_ids": image_ids, "image_selection": "first count sorted image IDs from saved inputs",
              "images": len(image_ids), "input_predictions": len(baseline),
              "rejected_outside_or_invalid": rejected, "threshold": 1.0, "input_format": args.input_format,
              "baseline_ap": before[0], "baseline_ap50": before[1], "replayed_ap": after[0], "replayed_ap50": after[1],
              "exported_ap": coco_stats[0], "exported_ap50": coco_stats[1],
              "max_coco_metric_abs_error": error, "max_export_metric_abs_error": export_error,
              "max_bbox_coordinate_abs_error_pixels": coordinate_error,
              "scope": "Existing full-image predictions converted mathematically into selected format; one full-image window; not real tiled inference or accuracy improvement"}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf8")
    print(json.dumps(report))


if __name__ == "__main__":
    main()
