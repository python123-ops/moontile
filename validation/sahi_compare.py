"""Compare MoonTile CLI with the unmodified SAHI 0.11.14 NMS function.

Usage: python validation/sahi_compare.py --sahi-dir PATH --binary PATH --output PATH
The reference function is extracted from its pinned source AST because importing
the full SAHI package requires optional image-processing dependencies.
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

import torch

REVISION = "0077a143abdabad2ac81eb375377c744662f7578"
SEED = 20261101


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--sahi-dir", required=True, type=Path)
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    revision = subprocess.check_output(["git", "-C", str(args.sahi_dir), "rev-parse", "HEAD"], text=True).strip()
    if revision != REVISION:
        raise SystemExit(f"SAHI checkout must be {REVISION}, got {revision}")
    source = (args.sahi_dir / "sahi/postprocess/combine.py").read_text(encoding="utf8")
    tree = ast.parse(source)
    functions = [node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == "nms"]
    if len(functions) != 1:
        raise SystemExit("expected exactly one SAHI nms function")
    module = ast.fix_missing_locations(ast.Module(body=functions, type_ignores=[]))
    namespace = {"torch": torch}
    exec(compile(module, "sahi/postprocess/combine.py", "exec"), namespace)
    reference_nms = namespace["nms"]
    rng = random.Random(SEED)
    cases = 0
    with tempfile.TemporaryDirectory(prefix="moontile-sahi-") as temp:
        input_path = Path(temp) / "input.json"
        for case in range(40):
            records = []
            rows = []
            for index in range(25):
                x, y = rng.randrange(0, 80), rng.randrange(0, 80)
                w, h = rng.randrange(1, 21), rng.randrange(1, 21)
                # Distinct scores avoid implementation-specific tie ordering.
                score = (index + 1) / 26
                rows.append([x, y, x + w, y + h, score, 0])
                records.append({"id": index, "image_id": 1, "tile_id": 0, "class_id": 0, "score": score,
                                "box": {"x1": x, "y1": y, "x2": x + w, "y2": y + h}})
            for metric in ("iou", "ios"):
                request = {"image_width": 100, "image_height": 100, "threshold": 0.5173,
                           "metric": metric, "class_agnostic": False,
                           "tiles": [{"tile": {"id": 0, "x": 0, "y": 0, "width": 100, "height": 100}, "detections": records}]}
                input_path.write_text(json.dumps(request), encoding="utf8")
                actual = json.loads(subprocess.check_output([str(args.binary.resolve()), str(input_path)], text=True))
                expected = reference_nms(torch.tensor(rows, dtype=torch.float64), metric.upper(), 0.5173)
                ids = [record["id"] for record in actual["kept"]]
                if ids != expected:
                    raise AssertionError(f"case={case} metric={metric}: MoonTile={ids}, SAHI={expected}")
                cases += 1
        # SAHI suppresses at equality; MoonTile deliberately retains it.
        rows = [[0, 0, 10, 10, 0.9, 0], [0, 0, 10, 10, 0.8, 0]]
        equality_sahi = reference_nms(torch.tensor(rows, dtype=torch.float64), "IOU", 1.0)
        request = {"image_width": 100, "image_height": 100, "threshold": 1.0, "metric": "iou", "class_agnostic": False,
                   "tiles": [{"tile": {"id": 0, "x": 0, "y": 0, "width": 100, "height": 100},
                              "detections": [{"id": i, "image_id": 1, "tile_id": 0, "class_id": 0, "score": row[4],
                                              "box": dict(zip(("x1", "y1", "x2", "y2"), row[:4]))} for i, row in enumerate(rows)]}]}
        input_path.write_text(json.dumps(request), encoding="utf8")
        equality_moon = json.loads(subprocess.check_output([str(args.binary.resolve()), str(input_path)], text=True))["kept"]
        assert equality_sahi == [0] and [item["id"] for item in equality_moon] == [0, 1]
    report = {"status": "passed", "command": "python validation/sahi_compare.py --sahi-dir _build/sahi-reference --binary <native-cli> --output validation/sahi-results.json",
              "python": sys.version.split()[0], "torch": torch.__version__, "binary_sha256": hashlib.sha256(args.binary.read_bytes()).hexdigest(),
              "reference": "SAHI 0.11.14 nms function", "reference_commit": REVISION,
              "source_sha256": hashlib.sha256(source.encode()).hexdigest(), "seed": SEED, "cases": cases,
              "boxes_per_case": 25, "metrics": ["iou", "ios"], "threshold": 0.5173,
              "equality": {"threshold": 1.0, "sahi_kept": equality_sahi, "moontile_kept": [x["id"] for x in equality_moon]},
              "scope": "NMS only; distinct scores, single image and class; no claim for tiling or tie order"}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf8")
    print(json.dumps(report))


if __name__ == "__main__":
    main()
