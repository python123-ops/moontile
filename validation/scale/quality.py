"""Run/replay a 200-image real sliced-inference quality study.

--infer generates real crop predictions first; replay avoids rerunning the model.
The source subset is retained beside this script with original COCO metadata.
"""
import argparse
import collections
import hashlib
import json
import math
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / 'validation'))
from real_tiled_coco import METRICS, coco_predictions, reference, save, sha, call

CASES = [('nms_iou_0', 'nms', 'iou', 0.0),
         ('nms_iou_03', 'nms', 'iou', 0.3),
         ('nms_iou_05', 'nms', 'iou', 0.5),
         ('nms_iou_07', 'nms', 'iou', 0.7),
         ('nms_iou_1', 'nms', 'iou', 1.0),
         ('nms_ios_05', 'nms', 'ios', 0.5),
         ('nmm_ios_05', 'greedy_nmm', 'ios', 0.5),
         ('nms_iou_05_agnostic', 'nms', 'iou', 0.5)]


def overlap(a, b, metric):
    intersection = max(0., min(a['x2'], b['x2']) - max(a['x1'], b['x1'])) * max(0., min(a['y2'], b['y2']) - max(a['y1'], b['y1']))
    aa = (a['x2'] - a['x1']) * (a['y2'] - a['y1'])
    bb = (b['x2'] - b['x1']) * (b['y2'] - b['y1'])
    if metric == 'ios':
        return intersection / min(aa, bb)
    scale = max(aa, bb)
    scaled_intersection = intersection / scale
    return scaled_intersection / (aa / scale + bb / scale - scaled_intersection)


def independent_merge(restored, strategy, metric, threshold, class_agnostic):
    ranked = sorted(restored, key=lambda d: -d['score'])
    kept, trace = [], []
    if strategy == 'nms':
        for candidate in ranked:
            for seed in kept:
                if seed['image_id'] != candidate['image_id'] or (not class_agnostic and seed['class_id'] != candidate['class_id']):
                    continue
                value = overlap(seed['box'], candidate['box'], metric)
                if value > threshold:
                    trace.append((candidate['id'], seed['id'], value))
                    break
            else:
                kept.append(candidate)
    else:
        consumed = set()
        for seed in ranked:
            if seed['id'] in consumed:
                continue
            consumed.add(seed['id'])
            bounds = dict(seed['box'])
            for candidate in ranked:
                if candidate['id'] in consumed or candidate['image_id'] != seed['image_id'] or (not class_agnostic and candidate['class_id'] != seed['class_id']):
                    continue
                value = overlap(seed['box'], candidate['box'], metric)
                if value > threshold:
                    for k in ('x1', 'y1'):
                        bounds[k] = min(bounds[k], candidate['box'][k])
                    for k in ('x2', 'y2'):
                        bounds[k] = max(bounds[k], candidate['box'][k])
                    consumed.add(candidate['id'])
                    trace.append((candidate['id'], seed['id'], value))
            kept.append({**seed, 'box': bounds})
    return kept, trace


def check_result(request, actual, strategy, metric, threshold, class_agnostic):
    expected_restored = []
    for group in request['tiles']:
        tile = group['tile']
        for det in group['detections']:
            b = det['box']
            expected_restored.append({**det, 'box': {'x1': b['x1'] + tile['x'], 'y1': b['y1'] + tile['y'],
                                                       'x2': b['x2'] + tile['x'], 'y2': b['y2'] + tile['y']}})
    if actual['restored'] != expected_restored:
        raise AssertionError('restored coordinate or input identity mismatch')
    kept, trace = independent_merge(expected_restored, strategy, metric, threshold, class_agnostic)
    if actual['kept'] != kept or len(actual['suppressed']) != len(trace):
        raise AssertionError('independent kept boxes or suppression count mismatch')
    for actual_item, (suppressed_id, kept_id, value) in zip(actual['suppressed'], trace):
        if actual_item['suppressed_id'] != suppressed_id or actual_item['kept_id'] != kept_id or not math.isclose(actual_item['overlap'], value, rel_tol=1e-12, abs_tol=1e-12):
            raise AssertionError('independent suppression trace mismatch')
    return expected_restored, kept


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--moontile', required=True, type=Path)
    p.add_argument('--moondeteval', required=True, type=Path)
    p.add_argument('--moontile-revision', required=True)
    p.add_argument('--moondeteval-revision', required=True)
    p.add_argument('--infer', action='store_true', help='run actual crop inference before replay')
    p.add_argument('--images', type=Path); p.add_argument('--weights', type=Path)
    args = p.parse_args()
    raw_path = HERE / 'predictions.json'; truth_path = HERE / 'ground_truth.json'
    provenance_path = HERE / 'provenance.json'; initial_report = HERE / 'results.json'
    if args.infer:
        if args.images is None or args.weights is None:
            p.error('--infer requires --images and --weights')
        cmd = [sys.executable, str(ROOT / 'validation/real_tiled_coco.py'), '--ground-truth', str(truth_path),
               '--provenance', str(provenance_path), '--images', str(args.images), '--weights', str(args.weights),
               '--moontile', str(args.moontile), '--moontile-revision', args.moontile_revision,
               '--moondeteval', str(args.moondeteval), '--moondeteval-revision', args.moondeteval_revision,
               '--count', '200', '--raw', str(raw_path), '--output', str(initial_report)]
        subprocess.run(cmd, check=True)
    provenance = json.loads(provenance_path.read_text(encoding='utf8'))
    initial = json.loads(initial_report.read_text(encoding='utf8'))
    if sha(truth_path) != provenance['inputs']['ground_truth_sha256'] or sha(raw_path) != initial['hashes']['raw']:
        raise AssertionError('input fixture hash mismatch')
    raw = json.loads(raw_path.read_text(encoding='utf8'))
    truth = json.loads(truth_path.read_text(encoding='utf8'))
    requests = raw['requests']
    if len(requests) != len(truth['images']) or len(requests) != initial['images']:
        raise AssertionError('source image count mismatch')
    input_categories = {d['class_id'] for req in requests for t in req['tiles'] for d in t['detections']}
    gt_classes = {a['category_id'] for a in truth['annotations']}
    sizes = collections.Counter('small' if a['area'] < 1024 else 'medium' if a['area'] < 9216 else 'large' for a in truth['annotations'])
    cases = []
    with tempfile.TemporaryDirectory(prefix='moontile-quality-') as tmp:
        tmp = Path(tmp); inp = tmp / 'input.json'; predictions_path = tmp / 'predictions.json'
        for name, strategy, metric, threshold in CASES:
            predictions = []; restored_count = suppressed_count = 0; empty_images = 0; max_group = 0
            for req in requests:
                class_agnostic = name.endswith('_agnostic')
                request = {**req, 'strategy': strategy, 'metric': metric, 'threshold': threshold, 'class_agnostic': class_agnostic}
                save(inp, request)
                result = call(args.moontile, inp)
                restored, kept = check_result(request, result, strategy, metric, threshold, class_agnostic)
                restored_count += len(restored); suppressed_count += len(result['suppressed'])
                empty_images += int(not restored); max_group = max(max_group, len(restored))
                predictions.extend(coco_predictions(kept))
            save(predictions_path, predictions)
            moon = call(args.moondeteval, truth_path, predictions_path)['summary']
            ref = reference(truth_path, predictions)
            delta = max(abs(moon[k] - ref[k]) for k in METRICS)
            if delta > 1e-9:
                raise AssertionError('MoonDetEval and pycocotools differ: ' + str(delta))
            if threshold == 1.0 and suppressed_count != 0:
                raise AssertionError('threshold 1 must not suppress')
            cases.append({'name': name, 'strategy': strategy, 'metric': metric, 'threshold': threshold, 'class_agnostic': class_agnostic,
                          'restored': restored_count, 'kept': len(predictions), 'suppressed': suppressed_count,
                          'empty_prediction_images': empty_images, 'max_predictions_per_image': max_group,
                          'metrics': moon, 'max_metric_reference_difference': delta})
            print('checked ' + name + ': ' + str(len(predictions)) + ' kept', file=sys.stderr, flush=True)
    reference_case = next(case for case in cases if case['name'] == 'nms_iou_05')
    if reference_case['kept'] != initial['predictions_after'] or reference_case['restored'] != initial['predictions_before']:
        raise AssertionError('inference and quality run detection counts differ')
    if any(abs(reference_case['metrics'][key] - initial['after'][key]) > 1e-9 for key in METRICS):
        raise AssertionError('inference and quality run metrics differ')
    report = {'status': 'passed', 'seed': provenance['seed'], 'selection': provenance['selection'],
              'images': len(requests), 'tiles': sum(len(req['tiles']) for req in requests),
              'ground_truths': len(truth['annotations']), 'ground_truth_classes': len(gt_classes),
              'predicted_classes': len(input_categories), 'ground_truth_size_counts': dict(sizes),
              'ground_truth_size_partition': 'exclusive: small area < 1024, medium 1024 <= area < 9216, large >= 9216 pixels squared',
              'crowd_annotations': sum(bool(a['iscrowd']) for a in truth['annotations']),
              'cases': cases, 'independent_reference': 'Python greedy per-image implementation with configurable class isolation, stable ties and original-seed envelope matching',
              'metric_reference': 'pycocotools', 'versions': initial['versions'], 'inference': initial['inference'],
              'hashes': {'raw': sha(raw_path), 'ground_truth': sha(truth_path), 'provenance': sha(provenance_path),
                         'moontile': sha(args.moontile), 'moondeteval': sha(args.moondeteval)},
              'moontile_revision': args.moontile_revision, 'moondeteval_revision': args.moondeteval_revision,
              'command': 'python validation/scale/quality.py --moontile <cli> --moondeteval <cli> --moontile-revision <sha> --moondeteval-revision <sha> [--infer --images <cache> --weights <weights>]',
              'scope': 'Actual 200-image crop inference, stratified subset; no confidence interval, broader dataset claim or manually verified duplicate count.'}
    (HERE / 'quality-results.json').write_bytes((json.dumps(report, indent=2) + '\n').encode('utf8'))
    print(json.dumps({'status': report['status'], 'images': report['images'], 'tiles': report['tiles'], 'cases': len(cases)}))


if __name__ == '__main__':
    main()
