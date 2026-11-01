"""Run real COCO image crops through YOLO11n, MoonTile, and MoonDetEval.

Images, annotations and weights remain external. Raw local-box predictions and
summary metrics are written separately so downstream steps can be audited.
"""
import argparse
import contextlib
import hashlib
import importlib.metadata as metadata
import io
import json
import subprocess
import sys
import tempfile
from pathlib import Path

import cv2
import torch
from pycocotools.coco import COCO
from pycocotools.cocoeval import COCOeval
from ultralytics import YOLO

METRICS = ('ap', 'ap50', 'ap75', 'ap_small', 'ap_medium', 'ap_large',
           'ar1', 'ar10', 'ar100', 'ar_small', 'ar_medium', 'ar_large')
MODEL_SHA = '0ebbc80d4a7680d14987a577cd21342b65ecfd94632bd9a8da63ae6417644ee1'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def save(path, obj):
    path.write_bytes((json.dumps(obj, ensure_ascii=False, separators=(',', ':')) + '\n').encode('utf8'))


def call(binary, *args):
    return json.loads(subprocess.check_output([str(binary.resolve()), *map(str, args)], encoding='utf8'))


def coco_predictions(detections):
    out = []
    for item in detections:
        box = item['box']
        out.append({'image_id': item['image_id'], 'category_id': item['class_id'],
                    'bbox': [box['x1'], box['y1'], box['x2']-box['x1'], box['y2']-box['y1']],
                    'score': item['score']})
    return out


def reference(truth_path, preds):
    with contextlib.redirect_stdout(io.StringIO()):
        truth = COCO(str(truth_path))
        ev = COCOeval(truth, truth.loadRes(preds), 'bbox')
        ev.evaluate(); ev.accumulate(); ev.summarize()
    return dict(zip(METRICS, map(float, ev.stats)))


def main():
    p = argparse.ArgumentParser()
    for arg in ('ground-truth', 'provenance', 'images', 'weights', 'moontile', 'moondeteval', 'raw', 'output'):
        p.add_argument('--' + arg, required=True, type=Path)
    p.add_argument('--count', type=int, default=10)
    p.add_argument('--moondeteval-revision', required=True)
    p.add_argument('--moontile-revision', required=True)
    args = p.parse_args()
    provenance = json.loads(args.provenance.read_text(encoding='utf8'))
    if sha(args.ground_truth) != provenance['inputs']['ground_truth_sha256']:
        raise SystemExit('ground truth does not match provenance')
    if sha(args.weights) != MODEL_SHA:
        raise SystemExit('unexpected YOLO11n weights')
    data = json.loads(args.ground_truth.read_text(encoding='utf8'))
    if not 1 <= args.count <= len(data['images']):
        raise SystemExit('invalid image count')
    images = sorted(data['images'], key=lambda x: x['id'])[:args.count]
    ids = {im['id'] for im in images}
    subset = {**data, 'images': images, 'annotations': [a for a in data['annotations'] if a['image_id'] in ids]}
    categories = sorted(data['categories'], key=lambda c: c['id'])
    torch.set_num_threads(min(8, torch.get_num_threads()))
    torch.manual_seed(20261002)
    model = YOLO(str(args.weights))
    for i, category in enumerate(categories):
        if model.names[i].lower() != category['name'].lower():
            raise ValueError('model class order does not match COCO categories')
    requests, all_before, all_after, image_hashes = [], [], [], []
    dropped = 0
    with tempfile.TemporaryDirectory(prefix='moontile-sliced-') as tmp:
        tmp = Path(tmp)
        inp, truth_path, pre_path, post_path = (tmp / name for name in ('input.json', 'truth.json', 'before.json', 'after.json'))
        mapping_path = tmp / 'mapping.json'
        save(truth_path, subset)
        save(mapping_path, [{'class_id': c['id'], 'category_id': c['id']} for c in categories])
        for im in images:
            path = args.images / im['file_name']
            image_hashes.append({'id': im['id'], 'file_name': im['file_name'], 'sha256': sha(path)})
            image = cv2.imread(str(path), cv2.IMREAD_COLOR)
            if image is None or image.shape[:2] != (im['height'], im['width']):
                raise ValueError('invalid or mismatched image ' + str(path))
            save(inp, {'image_width': im['width'], 'image_height': im['height'],
                       'tile_width': 256, 'tile_height': 256, 'overlap_x': 64, 'overlap_y': 64})
            tiles = call(args.moontile, inp, '--plan')['tiles']
            crops = [image[t['y']:t['y']+t['height'], t['x']:t['x']+t['width']] for t in tiles]
            results = model.predict(source=crops, device='cpu', imgsz=640, conf=0.05,
                                    iou=0.7, max_det=300, batch=8, verbose=False)
            if len(results) != len(tiles):
                raise AssertionError('model result count mismatch')
            groups, next_id = [], 0
            for tile, result in zip(tiles, results):
                if result.orig_shape != (tile['height'], tile['width']):
                    raise AssertionError('model result shape mismatch')
                detections = []
                for xyxy, confidence, cls in zip(result.boxes.xyxy.tolist(), result.boxes.conf.tolist(), result.boxes.cls.tolist()):
                    x1, y1, x2, y2 = map(float, xyxy)
                    if not (0 <= x1 < x2 <= tile['width'] and 0 <= y1 < y2 <= tile['height']):
                        dropped += 1
                        continue
                    detections.append({'id': next_id, 'image_id': im['id'], 'tile_id': tile['id'],
                                       'class_id': categories[int(cls)]['id'], 'score': float(confidence),
                                       'box': dict(zip(('x1', 'y1', 'x2', 'y2'), (x1, y1, x2, y2)))})
                    next_id += 1
                groups.append({'tile': tile, 'detections': detections})
            request = {'image_width': im['width'], 'image_height': im['height'], 'threshold': 0.5,
                       'metric': 'iou', 'class_agnostic': False, 'strategy': 'nms', 'tiles': groups}
            requests.append(request)
            save(inp, request)
            processed = call(args.moontile, inp)
            if len(processed['restored']) != next_id or len(processed['kept']) + len(processed['suppressed']) != next_id:
                raise AssertionError('detection accounting mismatch')
            expected = []
            for group in groups:
                tile = group['tile']
                for item in group['detections']:
                    box = item['box']
                    expected.append({**item, 'box': {'x1': box['x1'] + tile['x'], 'y1': box['y1'] + tile['y'],
                                                     'x2': box['x2'] + tile['x'], 'y2': box['y2'] + tile['y']}})
            if processed['restored'] != expected:
                raise AssertionError('local-to-image coordinates or detection provenance mismatch')
            exported = call(args.moontile, inp, '--coco-map', mapping_path)
            if exported != coco_predictions(processed['kept']):
                raise AssertionError('COCO export differs from kept detections')
            all_before.extend(coco_predictions(processed['restored']))
            all_after.extend(exported)
        if not all_before or not all_after:
            raise ValueError('no valid predictions')
        save(pre_path, all_before); save(post_path, all_after)
        before_moon = call(args.moondeteval, truth_path, pre_path)['summary']
        after_moon = call(args.moondeteval, truth_path, post_path)['summary']
        before_ref, after_ref = reference(truth_path, all_before), reference(truth_path, all_after)
        differences = [abs(moon[k] - ref[k]) for moon, ref in ((before_moon, before_ref), (after_moon, after_ref)) for k in METRICS]
        if max(differences) > 1e-9:
            raise AssertionError('MoonDetEval and pycocotools metrics differ: ' + str(max(differences)))
    save(args.raw, {'images': image_hashes, 'requests': requests})
    report = {'status': 'passed', 'command': f'python validation/real_tiled_coco.py --ground-truth <ground_truth.json> --provenance <results.json> --images <image-cache> --weights <yolo11n.pt> --moontile <moontile-cli> --moontile-revision <git-sha> --moondeteval <moondeteval-cli> --moondeteval-revision <git-sha> --count {args.count} --raw validation/real-tiled-coco-predictions.json --output validation/real-tiled-coco-results.json', 'seed': 20261002, 'selection': 'first count sorted image ids in saved subset',
              'image_ids': sorted(ids), 'images': len(images), 'tiles': sum(len(r['tiles']) for r in requests),
              'predictions_before': len(all_before), 'predictions_after': len(all_after),
              'suppressed': len(all_before) - len(all_after), 'invalid_boxes_filtered': dropped,
              'before': before_moon, 'after': after_moon, 'max_metric_reference_difference': max(differences),
              'inference': {'tile_width': 256, 'tile_height': 256, 'overlap_x': 64, 'overlap_y': 64,
                            'imgsz': 640, 'conf': 0.05, 'iou': 0.7, 'max_det': 300, 'device': 'cpu', 'batch': 8},
              'merge': {'strategy': 'nms', 'metric': 'iou', 'threshold': 0.5, 'class_agnostic': False},
              'hashes': {'ground_truth': sha(args.ground_truth), 'provenance': sha(args.provenance), 'model': sha(args.weights),
                         'moontile_binary': sha(args.moontile), 'moondeteval_binary': sha(args.moondeteval), 'raw': sha(args.raw)},
              'moontile_revision': args.moontile_revision, 'moondeteval_revision': args.moondeteval_revision,
              'versions': {'python': sys.version.split()[0], **{k: metadata.version(k) for k in ('ultralytics', 'torch', 'torchvision', 'opencv-python', 'pycocotools', 'numpy')}},
              'dataset': 'COCO val2017', 'image_url_template': provenance['image_url_template'],
              'annotation_url': provenance['annotation_url'], 'model_url': provenance['model_url'],
              'scope': 'Actual crop inference; suppression counts are not verified duplicate counts; 10-image subset is not a general accuracy benchmark.'}
    args.output.write_bytes((json.dumps(report, indent=2) + '\n').encode('utf8'))
    print(json.dumps(report, ensure_ascii=False))


if __name__ == '__main__':
    main()
