"""Compare planning and restoration with functions from pinned SAHI source.

No image inference is performed. Python's standard library is sufficient.
"""
import argparse
import ast
import hashlib
import json
import random
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import List

REVISION = "0077a143abdabad2ac81eb375377c744662f7578"
SEED = 20261101


def load_reference(root, relative, name, kind):
    """Load the original selected definition after verifying its committed bytes."""
    path = root / relative
    committed = subprocess.check_output(["git", "-C", str(root), "show", REVISION + ":" + relative])
    local = path.read_bytes().replace(b"\r\n", b"\n")
    if local != committed.replace(b"\r\n", b"\n"):
        raise SystemExit("reference source has local modifications: " + relative)
    tree = ast.parse(local.decode("utf8"))
    nodes = [node for node in tree.body if isinstance(node, kind) and node.name == name]
    if len(nodes) != 1:
        raise SystemExit("expected exactly one reference definition: " + name)
    module = ast.fix_missing_locations(ast.Module(body=nodes, type_ignores=[]))
    namespace = {"List": List}
    exec(compile(module, relative, "exec"), namespace)
    return namespace[name], hashlib.sha256(committed).hexdigest()


def run_cli(binary, args, request, input_path, valid=True):
    input_path.write_text(json.dumps(request), encoding="utf8")
    result = subprocess.run([str(binary), str(input_path), *args], text=True, capture_output=True)
    if valid:
        if result.returncode != 0:
            raise AssertionError("CLI failed: " + result.stderr)
        return json.loads(result.stdout)
    if result.returncode == 0 or result.stdout:
        raise AssertionError("invalid input returned success or partial output")
    return result.stderr.strip()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--sahi-dir", required=True, type=Path)
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    binary = args.binary.resolve(strict=True)
    root = args.sahi_dir.resolve(strict=True)
    revision = subprocess.check_output(["git", "-C", str(root), "rev-parse", "HEAD"], text=True).strip()
    if revision != REVISION:
        raise SystemExit(f"SAHI checkout must be {REVISION}, got {revision}")
    slices, slicing_hash = load_reference(root, "sahi/slicing.py", "get_slice_bboxes", ast.FunctionDef)
    bbox, annotation_hash = load_reference(root, "sahi/annotation.py", "BoundingBox", ast.ClassDef)
    rng = random.Random(SEED)
    # Ratios are exactly representable; integer overlaps match SAHI's int conversion.
    cases = [(10, 5, 60, 40, 0.0, 0.0), (120, 40, 60, 40, 0.0, 0.0),
             (100, 70, 60, 40, 0.5, 0.25), (129, 101, 64, 48, 0.75, 0.75)]
    ratios = [0.0, 0.25, 0.5, 0.75]
    cases.extend((rng.randint(1, 300), rng.randint(1, 300), rng.randint(1, 100),
                  rng.randint(1, 100), rng.choice(ratios), rng.choice(ratios)) for _ in range(96))
    box_count = 0
    with tempfile.TemporaryDirectory(prefix="moontile-sahi-layout-") as tmp:
        input_path = Path(tmp) / "input.json"
        for case, (width, height, tw, th, rx, ry) in enumerate(cases):
            request = {"image_width": width, "image_height": height, "tile_width": tw, "tile_height": th,
                       "overlap_x": int(rx * tw), "overlap_y": int(ry * th)}
            actual = run_cli(binary, ["--plan"], request, input_path)
            reference = slices(height, width, th, tw, False, ry, rx)
            tiles = actual["tiles"]
            observed = [[t["x"], t["y"], t["x"] + t["width"], t["y"] + t["height"]] for t in tiles]
            if observed != reference or [t["id"] for t in tiles] != list(range(len(tiles))):
                raise AssertionError(f"window mismatch in case {case}: {request}")
            groups = []
            expected = []
            sampled = tiles if len(tiles) <= 16 else tiles[:15] + tiles[-1:]
            for tile in sampled:
                # Exact quarter-pixel boxes, fully inside even a 1x1 tile.
                box = [0.25, 0.25, tile["width"] - 0.25, tile["height"] - 0.25]
                shifted = bbox(box, [tile["x"], tile["y"]]).get_shifted_box().to_xyxy()
                expected.append(shifted)
                detection = {"id": tile["id"], "image_id": 1, "tile_id": tile["id"], "class_id": 0,
                             "score": 0.5, "box": dict(zip(("x1", "y1", "x2", "y2"), box))}
                groups.append({"tile": tile, "detections": [detection]})
            pipeline = {"image_width": width, "image_height": height, "threshold": 1.0,
                        "metric": "iou", "class_agnostic": False, "tiles": groups}
            output = run_cli(binary, [], pipeline, input_path)
            restored = [[d["box"][key] for key in ("x1", "y1", "x2", "y2")] for d in output["restored"]]
            if restored != expected or len(output["kept"]) != len(expected) or output["suppressed"]:
                raise AssertionError(f"restoration mismatch in case {case}: {request}")
            box_count += len(expected)
        # The APIs express overlap differently: ratios can round down before int().
        ratio = 29 / 50
        sahi_rounding = slices(50, 120, 50, 50, False, 0.0, ratio)
        moon_rounding = run_cli(binary, ["--plan"], {"image_width": 120, "image_height": 50,
                                "tile_width": 50, "tile_height": 50, "overlap_x": 29, "overlap_y": 0}, input_path)
        sahi_x = [item[0] for item in sahi_rounding]
        moon_x = [item["x"] for item in moon_rounding["tiles"]]
        if int(ratio * 50) != 28 or sahi_x == moon_x:
            raise AssertionError("expected overlap-ratio rounding difference")
        # SAHI BoundingBox translates out-of-tile boxes; MoonTile rejects them.
        outside = bbox([0, 0, 2, 2], [0, 0]).get_shifted_box().to_xyxy()
        invalid = {"image_width": 1, "image_height": 1, "threshold": 0.5, "metric": "iou",
                   "class_agnostic": False, "tiles": [{"tile": {"id": 0, "x": 0, "y": 0, "width": 1, "height": 1},
                   "detections": [{"id": 0, "image_id": 1, "tile_id": 0, "class_id": 0, "score": 0.5,
                                   "box": {"x1": 0, "y1": 0, "x2": 2, "y2": 2}}]}]}
        error = run_cli(binary, [], invalid, input_path, valid=False)
        if outside != [0, 0, 2, 2] or "inside tile" not in error:
            raise AssertionError("expected out-of-tile validation difference")
    report = {"status": "passed", "command": "python validation/sahi_layout.py --sahi-dir _build/sahi-reference --binary <native-cli> --output validation/sahi-layout-results.json",
              "python": sys.version.split()[0], "reference": "SAHI 0.11.14", "reference_commit": REVISION,
              "source_sha256": {"sahi/slicing.py": slicing_hash, "sahi/annotation.py": annotation_hash},
              "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(), "seed": SEED,
              "layout_cases": len(cases), "restored_boxes": box_count, "mismatched_layouts": 0,
              "mismatched_restored_boxes": 0, "overlap_ratios": ratios,
              "differences": {"ratio_rounding": {"requested_pixels": 29, "sahi_ratio": ratio,
                              "sahi_effective_pixels": 28, "sahi_x": sahi_x, "moontile_x": moon_x},
                              "out_of_tile": {"sahi_shifted": outside, "moontile_error": error}},
              "scope": "All windows compared; up to 16 synthetic boxes per layout, including the final window; explicit fixed slice dimensions; no model inference or accuracy claim"}
    args.output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf8")
    print(json.dumps(report, ensure_ascii=False))


if __name__ == "__main__":
    main()
