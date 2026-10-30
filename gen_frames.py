#!/usr/bin/env python3
import math
import os
import struct
import subprocess

VIDEO = 'src/BadApple.mp4'
AUDIO = 'src/bad-apple-audio.mp3'
OUT = 'out'
FPS = 30
RING_FPS = 15
RATE = 48000
TEST_SECONDS = 10

CELL_W, CELL_H = 12, 28
DIGIT_ASPECT = 0.55
GAMMA = float(os.environ.get('GAMMA', 2.0))
FLOOR = 4
BLACK_MAX = 40

SEGMENTS = {
    'a': ((0.2, 0.06), (0.8, 0.06)),
    'b': ((0.9, 0.12), (0.9, 0.44)),
    'c': ((0.9, 0.56), (0.9, 0.88)),
    'd': ((0.2, 0.94), (0.8, 0.94)),
    'e': ((0.1, 0.56), (0.1, 0.88)),
    'f': ((0.1, 0.12), (0.1, 0.44)),
    'g': ((0.2, 0.50), (0.8, 0.50)),
}
ORDER = 'abcdefg'

RING_PIXELS = 12
RING_BANDS = [
    'lowpass=f=120',
    'bandpass=f=250:width_type=o:w=1',
    'bandpass=f=600:width_type=o:w=1',
    'bandpass=f=1500:width_type=o:w=1',
    'bandpass=f=3500:width_type=o:w=1',
    'highpass=f=6000',
]
RING_DECAY = 0.7
RING_GAMMA = 1.6
RING_BASELINE = 0.75
RING_BASELINE_SECONDS = 1.0


def ffmpeg(*args, out='-'):
    env = dict(os.environ)
    env.pop('LD_LIBRARY_PATH', None)
    return subprocess.run(['ffmpeg', '-v', 'error', '-y', *args, out],
                          stdout=subprocess.PIPE, check=True, env=env).stdout


def pcm(*args, channels=1):
    raw = ffmpeg('-i', AUDIO, *args, '-ar', str(RATE), '-f', 's16le')
    samples = struct.unpack('<%dh' % (len(raw) // 2), raw)
    return [samples[c::channels] for c in range(channels)]


def rms_per_frame(samples, fps, n):
    step = RATE / fps
    out = []
    for i in range(n):
        seg = samples[int(i * step):int((i + 1) * step)]
        out.append(math.sqrt(sum(s * s for s in seg) / len(seg)) if seg else 0.0)
    return out


def envelope(levels, decay, percentile=0.98):
    ref = sorted(levels)[int(len(levels) * percentile)] or 1.0
    out, env = [], 0.0
    for r in levels:
        env = max(min(r / ref, 1.0), env * decay)
        out.append(env)
    return out


def onsets(levels):
    alpha = 1 / (RING_FPS * RING_BASELINE_SECONDS)
    slow, out = levels[0], []
    for r in levels:
        out.append(max(0.0, r - RING_BASELINE * slow))
        slow += alpha * (r - slow)
    return out


def seg_dist(px, py, seg):
    (x1, y1), (x2, y2) = seg
    px, x1, x2 = px * DIGIT_ASPECT, x1 * DIGIT_ASPECT, x2 * DIGIT_ASPECT
    dx, dy = x2 - x1, y2 - y1
    t = max(0.0, min(1.0, ((px - x1) * dx + (py - y1) * dy) / (dx * dx + dy * dy)))
    return math.hypot(px - (x1 + t * dx), py - (y1 + t * dy))


def cell_map():
    cell = []
    for r in range(CELL_H):
        for c in range(CELL_W):
            x, y = (c + 0.5) / CELL_W, (r + 0.5) / CELL_H
            cell.append(min(range(7), key=lambda s: seg_dist(x, y, SEGMENTS[ORDER[s]])))
    return cell


def panel_frames():
    w, h = CELL_W * 4, CELL_H
    raw = ffmpeg('-i', VIDEO, '-vf', f'scale={w}:{h}:flags=area,format=gray', '-f', 'rawvideo')
    size = w * h
    frames = [raw[i:i + size] for i in range(0, len(raw) - size + 1, size)]
    n = len(frames)

    cell = cell_map()
    counts = [cell.count(s) for s in range(7)]
    lut = [int(255 * (v / 255) ** GAMMA + 0.5) for v in range(256)]
    lut = [v if v >= FLOOR else 0 for v in lut]

    black = [max(f) < BLACK_MAX for f in frames]
    first = next(i for i in range(n) if not black[i])
    last = next(i for i in reversed(range(n)) if not black[i])

    colon = [int(255 * e ** 1.8) for e in envelope(rms_per_frame(pcm('-ac', '1')[0], FPS, n), 0.8)]
    colon = [v if v >= FLOOR else 0 for v in colon]

    inverted, original = [], []
    for i, f in enumerate(frames):
        avg = []
        for d in range(4):
            acc = [0] * 7
            for r in range(CELL_H):
                row, base = r * w + d * CELL_W, r * CELL_W
                for c in range(CELL_W):
                    acc[cell[base + c]] += f[row + c]
            avg += [acc[s] // counts[s] for s in range(7)]
        tail = [colon[i], colon[i]]
        neg = [0] * 28 if i < first or i > last else [lut[255 - v] for v in avg]
        inverted.append(' '.join(map(str, neg + tail)))
        original.append(' '.join(map(str, [lut[v] for v in avg] + tail)))
    return inverted, original


def ring_frames(n):
    graph = '[0:a]pan=mono|c0=0.5*c0+0.5*c1,asplit=%d' % len(RING_BANDS)
    graph += ''.join(f'[s{i}]' for i in range(len(RING_BANDS))) + ';'
    graph += ''.join(f'[s{i}]{f}[b{i}];' for i, f in enumerate(RING_BANDS))
    graph += ''.join(f'[b{i}]' for i in range(len(RING_BANDS)))
    graph += f'amerge=inputs={len(RING_BANDS)}[out]'
    bands = pcm('-filter_complex', graph, '-map', '[out]', channels=len(RING_BANDS))
    levels = [envelope(onsets(rms_per_frame(b, RING_FPS, n)), RING_DECAY, 0.97) for b in bands]

    lines = []
    for i in range(n):
        px = []
        for p in range(RING_PIXELS):
            v = int(255 * levels[min(p, RING_PIXELS - 1 - p)][i] ** RING_GAMMA)
            v = v if v >= FLOOR else 0
            px.append('%02x%02x%02x' % (v, v, v))
        lines.append(' '.join(px))
    return lines


def write(name, lines, fps):
    with open(f'{OUT}/{name}.txt', 'w') as fh:
        fh.write('\n'.join(lines) + '\n')
    with open(f'{OUT}/{name}_test.txt', 'w') as fh:
        fh.write('\n'.join(lines[:TEST_SECONDS * fps]) + '\n')


def main():
    os.makedirs(OUT, exist_ok=True)
    inverted, original = panel_frames()
    n = len(inverted)
    write('badapple_frames', inverted, FPS)
    write('badapple_frames_orig', original, FPS)
    write('badapple_ring', ring_frames(math.ceil(n * RING_FPS / FPS)), RING_FPS)

    encode = ['-af', 'aresample=resampler=soxr:precision=28', '-ar', str(RATE), '-ac', '2',
              '-c:a', 'libmp3lame', '-q:a', '2']
    ffmpeg('-i', AUDIO, *encode, out=f'{OUT}/badapple.mp3')
    ffmpeg('-i', AUDIO, '-t', str(TEST_SECONDS), *encode, out=f'{OUT}/badapple_test.mp3')
    print(f'{n} frames, {n / FPS:.2f} s')


if __name__ == '__main__':
    main()
