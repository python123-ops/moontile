"""Compare spatial NMS against a baseline CLI on synthetic and saved real inputs."""
import argparse
import hashlib
import json
import platform
import random
import statistics
import subprocess
import tempfile
import time
from pathlib import Path


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def execute(binary, path):
    start = time.perf_counter()
    result = subprocess.run([str(binary), str(path)], capture_output=True, check=True)
    return time.perf_counter() - start, result.stdout


def request(kind, count):
    rng = random.Random(20261102)
    positions = list(range(count))
    rng.shuffle(positions)
    boxes = []
    for i, pos in enumerate(positions):
        x = (pos % 200) * 4 if kind == 'scattered' else 10
        y = (pos // 200) * 4 if kind == 'scattered' else 10
        boxes.append({'id': i, 'image_id': 1, 'tile_id': 0, 'class_id': 0,
                      'score': 0.5, 'box': {'x1': x, 'y1': y, 'x2': x + 2, 'y2': y + 2}})
    return {'image_width': 800, 'image_height': max(800, (count // 200 + 1) * 4), 'threshold': 0.5,
            'metric': 'iou', 'class_agnostic': False, 'tiles': [{'tile': {'id': 0, 'x': 0, 'y': 0,
            'width': 800, 'height': max(800, (count // 200 + 1) * 4)}, 'detections': boxes}]}


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--before', type=Path, required=True)
    p.add_argument('--after', type=Path, required=True)
    p.add_argument('--raw', type=Path, default=Path('validation/scale/predictions.json'))
    p.add_argument('--repeat', type=int, default=3)
    p.add_argument('--output', type=Path, required=True)
    args = p.parse_args()
    if args.repeat < 1:
        p.error('repeat must be positive')
    before, after = args.before.resolve(strict=True), args.after.resolve(strict=True)
    raw = json.loads(args.raw.read_text(encoding='utf8'))
    results = []
    with tempfile.TemporaryDirectory(prefix='moontile-nms-scale-') as tmp:
        path = Path(tmp) / 'input.json'
        for kind, count in [('scattered', 10000), ('identical', 10000)]:
            path.write_text(json.dumps(request(kind, count), separators=(',', ':')), encoding='utf8')
            _, expected = execute(before, path)
            _, got = execute(after, path)
            if got != expected:
                raise AssertionError('synthetic output differs: ' + kind)
            samples = {'before': [], 'after': []}
            for turn in range(args.repeat):
                order = [('before', before), ('after', after)]
                if turn % 2:
                    order.reverse()
                for label, binary in order:
                    elapsed, output = execute(binary, path)
                    if output != expected:
                        raise AssertionError('unstable output')
                    samples[label].append(elapsed)
            old, new = statistics.median(samples['before']), statistics.median(samples['after'])
            results.append({'scenario': kind, 'detections': count, 'input_sha256': sha(path),
                            'output_sha256': hashlib.sha256(expected).hexdigest(), 'before_seconds': samples['before'],
                            'after_seconds': samples['after'], 'before_median': old, 'after_median': new, 'speedup': old / new})
        real_detections = 0
        for record in raw['requests']:
            path.write_text(json.dumps(record, separators=(',', ':')), encoding='utf8')
            _, expected = execute(before, path)
            _, got = execute(after, path)
            if got != expected:
                raise AssertionError('real output differs')
            real_detections += sum(len(group['detections']) for group in record['tiles'])
    report = {'command': 'python validation/nms_scale.py --before <baseline-release-cli> --after <new-release-cli> --output validation/nms-scale-results.json',
              'baseline_revision': '76dfafc', 'before_binary_sha256': sha(before), 'after_binary_sha256': sha(after),
              'source_sha256': sha(Path('nms.mbt')), 'fixture_sha256': sha(args.raw), 'seed': 20261102,
              'platform': platform.platform(), 'toolchain': subprocess.check_output(['moon', 'version', '--all'], text=True).strip(),
              'build_mode': 'native release', 'repeat': args.repeat, 'warmups': 1,
              'scope': 'Synthetic one-class workloads. Timings include process startup and JSON. Real crop predictions are checked for output equivalence only.',
              'real_images': len(raw['requests']), 'real_predictions': real_detections, 'real_outputs_identical': True, 'results': results}
    args.output.write_text(json.dumps(report, indent=2) + '\n', encoding='utf8')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
