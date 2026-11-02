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
    p.add_argument('--require-plan', action='store_true')
    p.add_argument('--plan-output', type=Path)
    p.add_argument('--boundary-output', type=Path)
    p.add_argument('--inspect-grid', action='store_true')
    p.add_argument('--inspection-output', type=Path)
    p.add_argument('--check-limits', action='store_true')
    p.add_argument('--limits-output', type=Path)
    args = p.parse_args()
    if (args.inspect_grid and not args.require_plan) or (args.inspection_output and not args.inspect_grid):
        p.error('--inspect-grid requires --require-plan; --inspection-output requires --inspect-grid')
    if args.limits_output and not args.check_limits:
        p.error('--limits-output requires --check-limits')
    raw_path = args.raw
    raw = json.loads(raw_path.read_text(encoding='utf8'))
    report = json.loads(args.report.read_text(encoding='utf8'))
    if hashlib.sha256(raw_path.read_bytes()).hexdigest() != report['hashes']['raw']:
        raise AssertionError('fixture hash differs from recorded inference')
    counts = [0, 0, 0]
    boundary_edges = {'left': 0, 'top': 0, 'right': 0, 'bottom': 0}
    boundary_images = boundary_groups = boundary_boxes = 0
    checked_plans = dropped_plans = wrong_geometry = 0
    inspected = injected = 0
    limited_complete = limited_tiles = limited_detections = 0
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
            if args.check_limits:
                bounded = copy.deepcopy(request)
                total = len(expected)
                bounded['limits'] = {'max_tiles': len(request['tiles']), 'max_detections': total}
                path.write_text(json.dumps(bounded, separators=(',', ':')), encoding='utf8')
                actual = json.loads(subprocess.check_output([str(args.binary.resolve()), str(path)], encoding='utf8'))
                if actual != result:
                    raise AssertionError('bounded result differs')
                limited_complete += 1
                for name, key, error in [('tiles', 'max_tiles', 'tile limit exceeded'), ('detections', 'max_detections', 'detection limit exceeded')]:
                    if bounded['limits'][key] == 0:
                        continue
                    bounded['limits'][key] -= 1
                    path.write_text(json.dumps(bounded, separators=(',', ':')), encoding='utf8')
                    bad = subprocess.run([str(args.binary.resolve()), str(path)], capture_output=True, encoding='utf8')
                    if bad.returncode == 0 or bad.stdout or error not in bad.stderr:
                        raise AssertionError('limit did not reject atomically: ' + name)
                    bounded['limits'][key] += 1
                    if name == 'tiles':
                        limited_tiles += 1
                    else:
                        limited_detections += 1
            if args.require_plan:
                inference = report['inference']
                planned = copy.deepcopy(request)
                planned['tile_plan'] = {key: inference[key] for key in ('tile_width', 'tile_height', 'overlap_x', 'overlap_y')}
                path.write_text(json.dumps(planned, separators=(',', ':')), encoding='utf8')
                complete = json.loads(subprocess.check_output([str(args.binary.resolve()), str(path)], encoding='utf8'))
                if complete != result:
                    raise AssertionError('planned complete input changed results')
                checked_plans += 1
                missing = copy.deepcopy(planned)
                missing['tiles'].pop()
                path.write_text(json.dumps(missing, separators=(',', ':')), encoding='utf8')
                bad = subprocess.run([str(args.binary.resolve()), str(path)], capture_output=True, encoding='utf8')
                if bad.returncode == 0 or bad.stdout or 'tile count does not match grid' not in bad.stderr:
                    raise AssertionError('missing tile was not rejected atomically')
                dropped_plans += 1
                wrong = copy.deepcopy(planned)
                group = wrong['tiles'][0]
                if group['tile']['width'] > 1:
                    group['tile']['width'] -= 1
                    group['detections'] = []
                    path.write_text(json.dumps(wrong, separators=(',', ':')), encoding='utf8')
                    bad = subprocess.run([str(args.binary.resolve()), str(path)], capture_output=True, encoding='utf8')
                    if bad.returncode == 0 or bad.stdout or 'tile geometry differs from grid' not in bad.stderr:
                        raise AssertionError('wrong tile geometry was not rejected atomically')
                    wrong_geometry += 1
                if args.inspect_grid:
                    def inspect(value):
                        path.write_text(json.dumps(value, separators=(',', ':')), encoding='utf8')
                        return json.loads(subprocess.check_output([str(args.binary.resolve()), str(path), '--inspect-grid', '1'], encoding='utf8'))
                    summary = inspect(planned)
                    if not summary['complete'] or summary['expected_tiles'] != len(planned['tiles']):
                        raise AssertionError('complete grid inspection failed')
                    inspected += 1
                    bad_grid = copy.deepcopy(wrong)
                    missing_id = bad_grid['tiles'].pop()['tile']['id']
                    unexpected_id = len(planned['tiles']) + 5
                    bad_grid['tiles'].append({'tile': {'id': unexpected_id, 'x': 0, 'y': 0, 'width': 1, 'height': 1}, 'detections': []})
                    summary = inspect(bad_grid)
                    if summary['complete'] or summary['missing_count'] != 1 or summary['missing_ids'] != [missing_id] or summary['mismatched_count'] != 1 or summary['mismatched_ids'] != [0] or summary['unexpected_count'] != 1 or summary['unexpected_ids'] != [unexpected_id]:
                        raise AssertionError('injected grid issues not identified')
                    injected += 1
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
                    if args.require_plan:
                        mutated['tile_plan'] = planned['tile_plan']
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
    if args.require_plan:
        plan_report = {'status': 'passed', 'images': len(raw['requests']), 'tiles': sum(len(r['tiles']) for r in raw['requests']),
                       'complete_inputs_verified': checked_plans, 'dropped_tile_inputs_rejected': dropped_plans,
                       'wrong_geometry_inputs_rejected': wrong_geometry, 'detections': counts[0],
                       'fixture_sha256': hashlib.sha256(raw_path.read_bytes()).hexdigest(),
                       'binary_sha256': hashlib.sha256(args.binary.read_bytes()).hexdigest(),
                       'command': 'python validation/replay_tiled_coco.py --binary <moontile-cli> --raw validation/scale/predictions.json --report validation/scale/results.json --require-plan --plan-output <results.json>',
                       'scope': 'Real crop detections; missing and altered tiles are synthetic error injections.'}
        if args.plan_output:
            args.plan_output.write_bytes((json.dumps(plan_report, indent=2) + '\n').encode('utf8'))
        print('Checked {} complete plans, {} missing tiles and {} wrong geometries.'.format(checked_plans, dropped_plans, wrong_geometry))
    elif args.plan_output:
        raise ValueError('--plan-output requires --require-plan')
    if args.check_limits:
        limits_report = {'status': 'passed', 'images': len(raw['requests']), 'exact_limit_inputs_verified': limited_complete,
                         'tile_limit_inputs_rejected': limited_tiles, 'detection_limit_inputs_rejected': limited_detections,
                         'tiles': sum(len(r['tiles']) for r in raw['requests']), 'detections': counts[0],
                         'fixture_sha256': hashlib.sha256(raw_path.read_bytes()).hexdigest(),
                         'binary_sha256': hashlib.sha256(args.binary.read_bytes()).hexdigest(),
                         'script_sha256_lf': hashlib.sha256(Path(__file__).read_bytes().replace(b'\r\n', b'\n')).hexdigest(),
                         'command': 'python validation/replay_tiled_coco.py --binary <moontile-cli> --raw validation/scale/predictions.json --report validation/scale/results.json --check-limits --limits-output validation/scale/json-limits-results.json',
                         'scope': 'Real crop predictions; limits are changed for boundary checks. No input-size or peak-memory bound is measured.'}
        if args.limits_output:
            args.limits_output.write_text(json.dumps(limits_report, indent=2) + '\n', encoding='utf8')
        print('Checked {} exact limits, {} tile-limit and {} detection-limit rejections.'.format(limited_complete, limited_tiles, limited_detections))
    if args.inspect_grid:
        inspection_report = {'status': 'passed', 'images': len(raw['requests']), 'complete_inputs_verified': inspected,
                             'inputs_with_three_injected_errors_verified': injected, 'tiles': sum(len(r['tiles']) for r in raw['requests']),
                             'detections': counts[0], 'fixture_sha256': hashlib.sha256(raw_path.read_bytes()).hexdigest(),
                             'binary_sha256': hashlib.sha256(args.binary.read_bytes()).hexdigest(),
                             'command': 'python validation/replay_tiled_coco.py --binary <moontile-cli> --raw validation/scale/predictions.json --report validation/scale/results.json --require-plan --inspect-grid --inspection-output validation/scale/json-grid-inspection-results.json',
                             'scope': 'Saved real crop predictions; missing, altered and unexpected windows are synthetic error injections.'}
        if args.inspection_output:
            args.inspection_output.write_text(json.dumps(inspection_report, indent=2) + '\n', encoding='utf8')
        print('JSON inspection checked {} complete inputs and {} inputs with three injected errors.'.format(inspected, injected))
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
