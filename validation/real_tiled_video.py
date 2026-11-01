"""Infer real video crops with OpenCV HOG and replay them through MoonTile/MBMOT.

The replay mode uses only Python's standard library, the stored prediction
fixture, and a MoonTile executable. The video and OpenCV are needed for infer.
"""
import argparse
import hashlib
import json
import math
import subprocess
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path, value):
    path.write_bytes((json.dumps(value, ensure_ascii=False, separators=(',', ':')) + '\n').encode('utf8'))


def run(binary, args, input_text=None):
    return subprocess.check_output([str(binary.resolve()), *map(str, args)], input=input_text, encoding='utf8')


def stream_text(values):
    return ''.join(json.dumps(v, separators=(',', ':')) + '\n' for v in values)


def read_lines(text):
    return [json.loads(line) for line in text.splitlines()]


def compare(actual, expected, where='root'):
    if isinstance(expected, dict):
        if not isinstance(actual, dict) or set(actual) != set(expected):
            raise AssertionError('object keys differ: ' + where)
        for key in expected:
            compare(actual[key], expected[key], where + '.' + key)
    elif isinstance(expected, list):
        if not isinstance(actual, list) or len(actual) != len(expected):
            raise AssertionError('array length differs: ' + where)
        for i, (a, b) in enumerate(zip(actual, expected)):
            compare(a, b, where + '[' + str(i) + ']')
    elif isinstance(expected, float):
        if not isinstance(actual, (int, float)) or not math.isclose(actual, expected, rel_tol=1e-10, abs_tol=1e-9):
            raise AssertionError('number differs: ' + where)
    elif actual != expected:
        raise AssertionError('value differs: ' + where)


def process(requests, moontile, mbmot=None):
    source = stream_text(requests)
    trace = read_lines(run(moontile, ['--trace-stream'], source))
    output = read_lines(run(moontile, ['--mbmot-stream'], source))
    if len(trace) != len(requests) or len(output) != len(requests):
        raise AssertionError('stream frame count changed')
    restored_total = kept_total = suppressed_total = 0
    for request, detail, converted in zip(requests, trace, output):
        frame = request['frame']
        if detail['frame'] != frame or converted['frame'] != frame:
            raise AssertionError('frame number changed')
        expected = []
        for group in request['input']['tiles']:
            tile = group['tile']
            for detection in group['detections']:
                box = detection['box']
                expected.append({**detection, 'box': {'x1': box['x1'] + tile['x'], 'y1': box['y1'] + tile['y'],
                                                       'x2': box['x2'] + tile['x'], 'y2': box['y2'] + tile['y']}})
        result = detail['result']
        compare(result['restored'], expected)
        kept = {d['id']: d for d in result['kept']}
        if len(kept) + len(result['suppressed']) != len(expected):
            raise AssertionError('merge accounting mismatch')
        reference = []
        for detection in expected:
            if detection['id'] in kept:
                box = kept[detection['id']]['box']
                reference.append({'xyxy': [box['x1'], box['y1'], box['x2'], box['y2']],
                                  'score': detection['score'], 'class_id': detection['class_id']})
        compare(converted['detections'], reference)
        restored_total += len(expected); kept_total += len(kept); suppressed_total += len(result['suppressed'])
    tracks = None
    if mbmot is not None:
        tracks = read_lines(run(mbmot, [], stream_text(output)))
        if len(tracks) != len(requests) or any(t['frame'] != r['frame'] for t, r in zip(tracks, requests)):
            raise AssertionError('tracker frame count or ordering changed')
    return output, tracks, {'restored': restored_total, 'kept': kept_total, 'suppressed': suppressed_total}


def infer(args):
    import cv2
    cv2.setNumThreads(1)
    capture = cv2.VideoCapture(str(args.video))
    if not capture.isOpened():
        raise ValueError('cannot open video')
    width = int(capture.get(cv2.CAP_PROP_FRAME_WIDTH)); height = int(capture.get(cv2.CAP_PROP_FRAME_HEIGHT))
    fps = capture.get(cv2.CAP_PROP_FPS)
    if width <= 0 or height <= 0 or not math.isfinite(fps) or fps <= 0:
        raise ValueError('invalid source dimensions or frame rate')
    with tempfile.TemporaryDirectory(prefix='moontile-video-plan-') as temp:
        plan = Path(temp) / 'plan.json'
        write_json(plan, {'image_width': width, 'image_height': height, 'tile_width': 384,
                          'tile_height': 384, 'overlap_x': 128, 'overlap_y': 128})
        tiles = json.loads(run(args.moontile, [plan, '--plan']))['tiles']
    hog = cv2.HOGDescriptor(); hog.setSVMDetector(cv2.HOGDescriptor_getDefaultPeopleDetector())
    requests = []; frame_hashes = []
    try:
        for frame_id in range(1, args.frames + 1):
            ok, frame = capture.read()
            if not ok:
                raise ValueError('video ended before the requested number of frames')
            if frame.shape[:2] != (height, width):
                raise ValueError('decoded frame dimensions changed')
            frame_hashes.append(hashlib.sha256(frame.tobytes()).hexdigest())
            groups = []; detection_id = 0
            for tile in tiles:
                crop = frame[tile['y']:tile['y'] + tile['height'], tile['x']:tile['x'] + tile['width']]
                rectangles, margins = hog.detectMultiScale(crop, winStride=(8, 8), padding=(8, 8), scale=1.05)
                detections = []
                for rect, margin in zip(rectangles, margins):
                    x, y, w, h = map(int, rect)
                    margin = float(margin)
                    if margin >= 0:
                        score = 1.0 / (1.0 + math.exp(-margin))
                    else:
                        exp_margin = math.exp(margin)
                        score = exp_margin / (1.0 + exp_margin)
                    if score < 0.55:
                        continue
                    if x < 0 or y < 0 or w <= 0 or h <= 0 or x + w > tile['width'] or y + h > tile['height']:
                        raise ValueError('HOG produced an invalid box')
                    detections.append({'id': detection_id, 'image_id': frame_id, 'tile_id': tile['id'], 'class_id': 0,
                                       'score': score, 'box': {'x1': x, 'y1': y, 'x2': x+w, 'y2': y+h}})
                    detection_id += 1
                groups.append({'tile': tile, 'detections': detections})
            requests.append({'frame': frame_id, 'input': {'image_width': width, 'image_height': height,
                            'threshold': 0.4, 'metric': 'iou', 'class_agnostic': False,
                            'strategy': 'nms', 'tiles': groups}})
    finally:
        capture.release()
    output, tracks, counts = process(requests, args.moontile, args.mbmot)
    track_ids = {t['track_id'] for row in tracks for t in row['tracks']}
    appearances = {}
    for row in tracks:
        for track in row['tracks']:
            appearances.setdefault(track['track_id'], set()).add(row['frame'])
    repeated_ids = sum(len(frames) > 1 for frames in appearances.values())
    if not counts['restored'] or not track_ids or not repeated_ids:
        raise AssertionError('sample contains no detections or repeated track IDs')
    write_json(args.raw, {'frames_bgr_sha256': frame_hashes, 'requests': requests})
    write_json(args.output_frames, output); write_json(args.tracks, tracks)
    report = {'status': 'passed', 'command': f'python validation/real_tiled_video.py infer --video <vtest.avi> --moontile <moontile-cli> --mbmot <mbmot-replay-cli> --moontile-revision <commit> --mbmot-revision <commit> --frames {args.frames}',
              'source_url': 'https://github.com/opencv/opencv/blob/4.x/samples/data/vtest.avi',
              'opencv_license': 'https://github.com/opencv/opencv/blob/4.x/LICENSE',
              'video_sha256': digest(args.video), 'opencv_version': cv2.__version__,
              'dimensions': [width, height], 'fps': fps, 'frames': len(requests), 'tiles_per_frame': len(tiles),
              'detector': {'name': 'OpenCV HOG default people detector', 'score': 'sigmoid of raw SVM margin, not calibrated',
                           'confidence': 0.55, 'win_stride': [8, 8], 'padding': [8, 8], 'scale': 1.05},
              'tile': {'width': 384, 'height': 384, 'overlap_x': 128, 'overlap_y': 128},
              'merge': {'strategy': 'nms', 'metric': 'iou', 'threshold': 0.4, 'class_agnostic': False},
              'counts': counts, 'unique_track_ids': len(track_ids), 'track_ids_in_multiple_frames': repeated_ids,
              'moontile_revision': args.moontile_revision, 'mbmot_revision': args.mbmot_revision,
              'hashes': {'moontile': digest(args.moontile), 'mbmot': digest(args.mbmot), 'raw': digest(args.raw),
                         'detections': digest(args.output_frames), 'tracks': digest(args.tracks)},
              'scope': 'Real sliced video frames; no tracking ground truth or accuracy assessment; repeated IDs do not prove correct identity.'}
    args.report.write_bytes((json.dumps(report, indent=2) + '\n').encode('utf8'))
    print(json.dumps(report))


def replay(args):
    report = json.loads(args.report.read_text(encoding='utf8'))
    for path, key in ((args.raw, 'raw'), (args.output_frames, 'detections'), (args.tracks, 'tracks')):
        if digest(path) != report['hashes'][key]:
            raise AssertionError('fixture hash mismatch: ' + key)
    raw = json.loads(args.raw.read_text(encoding='utf8'))
    expected = json.loads(args.output_frames.read_text(encoding='utf8'))
    output, tracks, counts = process(raw['requests'], args.moontile, args.mbmot)
    compare(output, expected)
    if counts != report['counts']:
        raise AssertionError('saved merge counts differ')
    if args.mbmot:
        compare(tracks, json.loads(args.tracks.read_text(encoding='utf8')))
    print('Replayed {} real frames: {} restored, {} kept, {} suppressed.'.format(len(output), counts['restored'], counts['kept'], counts['suppressed']))


def main():
    p = argparse.ArgumentParser(); p.add_argument('mode', choices=('infer', 'replay'))
    p.add_argument('--moontile', type=Path, required=True); p.add_argument('--mbmot', type=Path)
    p.add_argument('--video', type=Path); p.add_argument('--frames', type=int, default=20)
    p.add_argument('--moontile-revision'); p.add_argument('--mbmot-revision')
    p.add_argument('--raw', type=Path, default=HERE / 'real-tiled-video-predictions.json')
    p.add_argument('--output-frames', type=Path, default=HERE / 'real-tiled-video-detections.json')
    p.add_argument('--tracks', type=Path, default=HERE / 'real-tiled-video-tracks.json')
    p.add_argument('--report', type=Path, default=HERE / 'real-tiled-video-results.json')
    args = p.parse_args()
    if args.mode == 'infer':
        if args.video is None or args.mbmot is None or not args.moontile_revision or not args.mbmot_revision or args.frames < 1:
            p.error('infer requires --video, --mbmot, both revisions and positive --frames')
        infer(args)
    else:
        replay(args)


if __name__ == '__main__':
    main()
