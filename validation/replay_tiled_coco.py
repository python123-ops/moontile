"""Replay saved genuine tile predictions without images, model, or Python packages."""
import argparse
import hashlib
import json
import subprocess
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--binary', required=True, type=Path)
    p.add_argument('--raw', type=Path, default=HERE / 'real-tiled-coco-predictions.json')
    p.add_argument('--report', type=Path, default=HERE / 'real-tiled-coco-results.json')
    args = p.parse_args()
    raw_path = args.raw
    raw = json.loads(raw_path.read_text(encoding='utf8'))
    report = json.loads(args.report.read_text(encoding='utf8'))
    if hashlib.sha256(raw_path.read_bytes()).hexdigest() != report['hashes']['raw']:
        raise AssertionError('fixture hash differs from recorded inference')
    counts = [0, 0, 0]
    with tempfile.TemporaryDirectory(prefix='moontile-tiled-replay-') as tmp:
        path = Path(tmp) / 'input.json'
        for request in raw['requests']:
            path.write_text(json.dumps(request, separators=(',', ':')), encoding='utf8')
            result = json.loads(subprocess.check_output([str(args.binary.resolve()), str(path)], encoding='utf8'))
            expected = []
            for group in request['tiles']:
                tile = group['tile']
                for detection in group['detections']:
                    b = detection['box']
                    expected.append({**detection, 'box': {'x1': b['x1'] + tile['x'], 'y1': b['y1'] + tile['y'],
                                                          'x2': b['x2'] + tile['x'], 'y2': b['y2'] + tile['y']}})
            if result['restored'] != expected:
                raise AssertionError('coordinate or provenance mismatch')
            counts[0] += len(expected)
            counts[1] += len(result['kept'])
            counts[2] += len(result['suppressed'])
            if len(expected) != len(result['kept']) + len(result['suppressed']):
                raise AssertionError('merge accounting mismatch')
    if counts != [report['predictions_before'], report['predictions_after'], report['suppressed']]:
        raise AssertionError('merge counts differ from saved inference')
    print('Replayed {} images: {} restored, {} kept, {} suppressed.'.format(len(raw['requests']), *counts))


if __name__ == '__main__':
    main()
