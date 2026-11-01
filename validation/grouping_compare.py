"""Compare two native CLIs on deterministic grouped detection workloads.

Both binaries must implement the same MoonTile JSON contract. Measurements
include process startup, JSON parsing and serialization. No model is run.
"""
import argparse
import hashlib
import json
import platform
import statistics
import subprocess
import sys
import tempfile
import time
from pathlib import Path


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def request(count, classes, strategy):
    detections = []
    for i in range(count):
        x, y = (i % 1000) * 2, (i // 1000) * 2
        detections.append({"id": i, "image_id": 1, "tile_id": 0, "class_id": i % classes,
                           "score": 0.5, "box": {"x1": x, "y1": y, "x2": x + 1, "y2": y + 1}})
    return {"image_width": 2000, "image_height": max(2, ((count + 999) // 1000) * 2),
            "threshold": 0.5, "metric": "iou", "class_agnostic": False, "strategy": strategy,
            "tiles": [{"tile": {"id": 0, "x": 0, "y": 0, "width": 2000,
                                "height": max(2, ((count + 999) // 1000) * 2)},
                       "detections": detections}]}


def run(binary, input_path):
    start = time.perf_counter()
    completed = subprocess.run([str(binary), str(input_path)], capture_output=True, check=True)
    return time.perf_counter() - start, completed.stdout


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--before", type=Path, required=True)
    parser.add_argument("--after", type=Path, required=True)
    parser.add_argument("--before-revision", required=True)
    parser.add_argument("--repeat", type=int, default=3)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.repeat < 1:
        raise SystemExit("repeat must be positive")
    before, after = args.before.resolve(strict=True), args.after.resolve(strict=True)
    scenarios = [("many_classes", 8000, 100), ("single_class", 1200, 1)]
    results = []
    with tempfile.TemporaryDirectory(prefix="moontile-groups-") as temp:
        input_path = Path(temp) / "input.json"
        for name, count, classes in scenarios:
            for strategy in ("nms", "greedy_nmm"):
                payload = json.dumps(request(count, classes, strategy), separators=(",", ":"))
                input_path.write_text(payload, encoding="utf8")
                _, baseline = run(before, input_path)
                _, candidate = run(after, input_path)
                if baseline != candidate:
                    raise AssertionError(f"output differs: {name}, {strategy}")
                parsed = json.loads(candidate)
                if len(parsed["kept"]) != count or parsed["suppressed"]:
                    raise AssertionError("unexpected suppression in disjoint-box workload")
                samples = {"before": [], "after": []}
                for turn in range(args.repeat):
                    order = [("before", before), ("after", after)]
                    if turn % 2:
                        order.reverse()
                    for label, binary in order:
                        elapsed, output = run(binary, input_path)
                        if output != baseline:
                            raise AssertionError(f"unstable output: {name}, {strategy}, {label}")
                        samples[label].append(elapsed)
                old = statistics.median(samples["before"])
                new = statistics.median(samples["after"])
                results.append({"scenario": name, "strategy": strategy, "detections": count,
                                "classes": classes, "input_sha256": hashlib.sha256(payload.encode()).hexdigest(),
                                "outputs_identical": True, "before_seconds": samples["before"],
                                "after_seconds": samples["after"], "before_median_seconds": old,
                                "after_median_seconds": new, "median_speedup": old / new})
    report = {"command": "python validation/grouping_compare.py --before <before-cli> --after <after-cli> --before-revision <commit> --repeat 3 --output <output.json>",
              "before_revision": args.before_revision, "before_binary_sha256": digest(before),
              "after_binary_sha256": digest(after), "after_source_sha256": {name: digest(Path(name)) for name in ("nms.mbt", "merge.mbt")},
              "python": sys.version.split()[0], "platform": platform.platform(), "processor": platform.processor(),
              "toolchain": subprocess.check_output(["moon", "version", "--all"], text=True).strip(),
              "build_mode": "native release for both binaries",
              "repeat": args.repeat, "warmups_per_binary": 1, "seed": None,
              "scope": "Synthetic disjoint boxes; equal scores; one image; timings include CLI startup and JSON; not an inference benchmark",
              "results": results}
    args.output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf8")
    print(json.dumps(report))


if __name__ == "__main__":
    main()
