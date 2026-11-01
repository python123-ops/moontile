"""Replay saved genuine tile predictions without images, model, or Python packages."""
import argparse
import copy
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
    p.add_argument('--clip-boundary', action='store_true')
    p.add_argument('--boundary-output', type=Path)
    args = p.parse_args()
    raw_path = args.raw
    raw = json.loads(raw_path.read_text(encoding='utf8'))
    report = json.loads(args.report.read_text(encoding='utf8'))
    if hashlib.sha256(raw_path.read_bytes()).hexdigest() != report['hashes']['raw']:
        raise AssertionError('fixture hash differs from recorded inference')
    counts = [0, 0, 0]
    boundary_edges = {'left': 0, 'top': 0, 'right': 0, 'bottom': 0}
    boundary_images = boundary_groups = boundary_boxes = 0
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
            if args.clip_boundary:
                mutated = copy.deepcopy(request)
                image_has_changes = False
                for group in mutated['tiles']:
                    if group.get('transform') is not None or group.get('box_format', 'xyxy') != 'xyxy':
                        raise ValueError('boundary replay requires local pixel xyxy inputs')
                    tile = group['tile']
                    group_changed = False
                    for detection in group['detections']:
                        b = detection['box']; changed = False
                        for key, edge, value, delta in (('x1', 'left', 0, -1), ('y1', 'top', 0, -1),
                                                        ('x2', 'right', tile['width'], 1), ('y2', 'bottom', tile['height'], 1)):
                            if b[key] == value:
                                b[key] += delta
                                boundary_edges[edge] += 1
                                changed = group_changed = image_has_changes = True
                        boundary_boxes += int(changed)
                    if group_changed:
                        group['clip_local'] = True
                        boundary_groups += 1
                if image_has_changes:
                    boundary_images += 1
                    path.write_text(json.dumps(mutated, separators=(',', ':')), encoding='utf8')
                    clipped = json.loads(subprocess.check_output([str(args.binary.resolve()), str(path)], encoding='utf8'))
                    if clipped != result:
                        raise AssertionError('boundary clipping changed original restored or merged results')
            counts[0] += len(expected)
            counts[1] += len(result['kept'])
            counts[2] += len(result['suppressed'])
            if len(expected) != len(result['kept']) + len(result['suppressed']):
                raise AssertionError('merge accounting mismatch')
    if counts != [report['predictions_before'], report['predictions_after'], report['suppressed']]:
        raise AssertionError('merge counts differ from saved inference')
    if args.clip_boundary:
        if not boundary_boxes:
            raise AssertionError('no edge-touching predictions in fixture')
        boundary_report = {'status': 'passed', 'images': len(raw['requests']), 'affected_images': boundary_images,
                           'affected_tiles': boundary_groups, 'affected_boxes': boundary_boxes, 'edges': boundary_edges,
                           'input_predictions': counts[0], 'kept': counts[1], 'suppressed': counts[2],
                           'fixture_sha256': hashlib.sha256(raw_path.read_bytes()).hexdigest(),
                           'binary_sha256': hashlib.sha256(args.binary.read_bytes()).hexdigest(),
                           'command': 'python validation/replay_tiled_coco.py --binary <moontile-cli> --raw validation/scale/predictions.json --report validation/scale/results.json --clip-boundary --boundary-output validation/scale/clipping-boundary-results.json',
                           'scope': 'Real predictions touching tile edges were artificially expanded one pixel for a boundary test; these are not raw detector out-of-bounds predictions.'}
        if args.boundary_output:
            args.boundary_output.write_bytes((json.dumps(boundary_report, indent=2) + '\n').encode('utf8'))
        print('Clipping perturbation matched on {} boxes across {} images.'.format(boundary_boxes, boundary_images))
    elif args.boundary_output:
        raise ValueError('--boundary-output requires --clip-boundary')
    print('Replayed {} images: {} restored, {} kept, {} suppressed.'.format(len(raw['requests']), *counts))


if __name__ == '__main__':
    main()
