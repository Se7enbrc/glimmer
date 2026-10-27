#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Builds the differential input corpus (inputs only) from RFC framing rules, the repository's
independent tone fixtures and libopus. Deterministic: the same tools give the same bytes."""

import base64
import json
import random
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LAYOUTS = {
    "mono": (1, 1, 0, [0]),
    "stereo": (2, 1, 1, [0, 1]),
    "5.1": (6, 4, 2, [0, 4, 1, 5, 2, 3]),
    "7.1": (8, 5, 3, [0, 6, 1, 7, 2, 3, 4, 5]),
    "5.1-hq": (6, 6, 0, [0, 1, 2, 3, 4, 5]),
    "7.1-hq": (8, 8, 0, [0, 1, 2, 3, 4, 5, 6, 7]),
}


def tone_lanes():
    text = (ROOT / "GlimmerTests/SurroundToneData.swift").read_text()
    lanes = []
    for block in re.findall(r'"""\n(.*?)"""', text, re.S)[:12]:
        data, cursor, packets = base64.b64decode("".join(block.split())), 0, []
        while cursor + 2 <= len(data):
            count = data[cursor] | data[cursor + 1] << 8
            packets.append(data[cursor + 2:cursor + 2 + count])
            cursor += 2 + count
        lanes.append(packets)
    return lanes


def length(value):
    if value < 252:
        return bytes([value])
    first = 252 + (value & 3)
    return bytes([first, (value - first) // 4])


def pack(toc, frames, delimited, code=None, padding=0, vbr=None):
    """RFC 6716 section 3.2 packing, self-delimited per Appendix B."""
    toc &= 0xFC
    if code is None:
        code = 0 if len(frames) == 1 else 2 if len(frames) == 2 and len(frames[0]) != len(frames[1]) else 1
    if code == 0:
        return bytes([toc]) + (length(len(frames[0])) if delimited else b"") + frames[0]
    if code == 1:
        return bytes([toc | 1]) + (length(len(frames[0])) if delimited else b"") + b"".join(frames)
    if code == 2:
        return (bytes([toc | 2]) + length(len(frames[0])) + (length(len(frames[1])) if delimited else b"")
                + b"".join(frames))
    vbr = vbr if vbr is not None else len({len(f) for f in frames}) > 1
    head = bytes([toc | 3, (0x80 if vbr else 0) | (0x40 if padding else 0) | len(frames)])
    if padding:
        remaining = padding
        while remaining >= 255:
            head += b"\xff"
            remaining -= 254
        head += bytes([remaining])
    sizes = b"".join(length(len(f)) for f in frames[:-1]) if vbr else b""
    tail = length(len(frames[-1])) if delimited else b""
    return head + sizes + tail + b"".join(frames) + bytes(padding)


def stream_packets(layout, lanes, number):
    channels, streams, coupled, _ = LAYOUTS[layout]
    result = []
    for stream in range(streams):
        lane = 8 + stream if stream < coupled else stream + coupled
        result.append(lanes[lane][number])
    return result


def multistream(parts, packing=None):
    """Joins single-frame stream packets; packing(stream, toc, frame, delimited) may repack one stream."""
    out = b""
    for index, part in enumerate(parts):
        delimited = index < len(parts) - 1
        repacked = packing(index, part[0], part[1:], delimited) if packing else None
        out += repacked if repacked is not None else pack(part[0], [part[1:]], delimited)
    return out


def b64(data):
    return None if data is None else base64.b64encode(data).decode()


def audio_case(name, layout, steps, spf=240, rate=48000, mapping=None, config=None):
    channels, streams, coupled, default = LAYOUTS[layout]
    channels, streams, coupled, mapping = config or (channels, streams, coupled, mapping or default)
    return {"name": name, "input": {
        "rate": rate, "channels": channels, "streams": streams, "coupled": coupled, "mapping": mapping,
        "samplesPerFrame": spf,
        "steps": [{"packet": b64(packet), "conceal": conceal} for packet, conceal in steps]}}


def libopus(tool, layout, application, frame, fec, loss, bitrate, count):
    channels, streams, coupled, mapping = LAYOUTS[layout]
    args = [tool, str(channels), str(streams), str(coupled), ",".join(map(str, mapping)), application,
            str(frame), str(fec), str(loss), str(bitrate), str(count)]
    return [bytes.fromhex(line) for line in subprocess.run(args, check=True, capture_output=True,
                                                            text=True).stdout.split()]


def audio_cases(tool):
    lanes = tone_lanes()
    cases = []
    for layout in LAYOUTS:
        packets = [multistream(stream_packets(layout, lanes, n)) for n in range(16)]
        cases.append(audio_case(f"tones-{layout}", layout, [(p, False) for p in packets]))
        cases.append(audio_case(f"loss-{layout}", layout,
                                [(packets[0], False), (packets[1], False), (None, False), (packets[3], False),
                                 (None, False), (None, False), (packets[6], False), (packets[7], True)]))
    for layout, app, frame, fec, loss, rate in [
        ("stereo", "voip", 960, 1, 20, 32000), ("5.1", "audio", 480, 1, 10, 96000),
        ("7.1", "lowdelay", 240, 0, 0, 640000), ("5.1-hq", "audio", 960, 1, 15, 128000),
        ("mono", "voip", 960, 1, 30, 16000), ("stereo", "audio", 120, 0, 0, 128000),
        ("7.1-hq", "voip", 480, 1, 25, 96000)]:
        packets = libopus(tool, layout, app, frame, fec, loss, rate, 10)
        name = f"libopus-{layout}-{app}-{frame}{'-fec' if fec else ''}"
        cases.append(audio_case(name, layout, [(p, False) for p in packets], spf=frame))
        lossy = [(None if n in (3, 4, 7) else p, n == 9) for n, p in enumerate(packets)]
        cases.append(audio_case(name + "-lossy", layout, lossy, spf=frame))
    cases += malformed_cases(lanes)
    cases += mapping_and_config_cases(lanes)
    cases += packing_cases(lanes)
    return cases


def malformed_cases(lanes):
    good = [multistream(stream_packets("5.1", lanes, n)) for n in range(4)]
    parts = stream_packets("5.1", lanes, 1)
    variants = {
        "truncated-last-byte": good[1][:-1], "truncated-half": good[1][:len(good[1]) // 2],
        "truncated-in-length": good[1][:1], "toc-only": good[1][:2], "empty": b"",
        "extra-byte": good[1] + b"\x00", "extra-bytes": good[1] + b"\x11\x22\x33",
        "length-too-long": good[1][:1] + b"\xfb" + good[1][2:], "length-too-short": good[1][:1]
        + bytes([good[1][1] - 3]) + good[1][2:],
        "length-two-byte-truncated": good[1][:1] + b"\xfe",
        "mismatched-duration": multistream([*parts[:-1], bytes([0xF0 | (parts[-1][0] & 4)]) + parts[-1][1:]]),
        "first-stream-20ms": multistream([bytes([0xF8 | (parts[0][0] & 4)]) + parts[0][1:], *parts[1:]]),
        "code3-zero-count": multistream(parts, lambda i, toc, f, d: bytes([toc | 3, 0]) if i == 0 else None),
        "code3-padding-overflow": multistream(parts, lambda i, toc, f, d: bytes([toc | 3, 0x41, 0xff, 0xff])
                                              if i == 2 else None),
        "missing-stream": multistream(parts[:-1]),
        "extra-stream": multistream([*parts, parts[-1]]),
        "oversize": good[1] + bytes(10_300),
    }
    cases = []
    for name, packet in variants.items():
        for conceal in (False, True):
            steps = [(good[0], False), (packet, conceal), (good[2], False), (good[3], False)]
            cases.append(audio_case(f"malformed-{name}{'-conceal' if conceal else ''}", "5.1", steps))
    return cases


def mapping_and_config_cases(lanes):
    stereo = [multistream(stream_packets("stereo", lanes, n)) for n in range(4)]
    surround = [multistream(stream_packets("5.1", lanes, n)) for n in range(4)]
    steps = [(p, False) for p in stereo]
    cases = [audio_case(f"map-stereo-{'-'.join(map(str, m))}", "stereo", steps, mapping=m)
             for m in ([1, 0], [0, 0], [1, 1], [0, 255], [255, 255])]
    cases += [audio_case("map-5.1-silenced", "5.1", [(p, False) for p in surround], mapping=[0, 255, 1, 5, 255, 3]),
              audio_case("map-5.1-duplicated", "5.1", [(p, False) for p in surround], mapping=[0, 0, 0, 0, 0, 0]),
              audio_case("map-5.1-as-4ch", "5.1", [(p, False) for p in surround], config=(4, 4, 2, [0, 1, 2, 3])),
              audio_case("capacity-120", "5.1", [(p, False) for p in surround], spf=120),
              audio_case("capacity-960", "5.1", [(p, False) for p in surround], spf=960),
              audio_case("rate-24000", "stereo", steps, rate=24000),
              audio_case("rate-16000", "stereo", steps, rate=16000, spf=80)]
    invalid = {"channels-0": (0, 1, 0, []), "channels-9": (9, 9, 0, list(range(9))),
               "mapping-short": (2, 1, 1, [0]), "mapping-out-of-range": (2, 1, 1, [0, 2]),
               "coupled-over-streams": (4, 1, 2, [0, 1, 2, 3]), "streams-0": (1, 0, 0, [0]),
               "streams-9": (8, 9, 0, list(range(8)))}
    cases += [audio_case(f"invalid-{name}", "stereo", steps[:1], config=config) for name, config in invalid.items()]
    cases += [audio_case("invalid-capacity-0", "stereo", steps[:1], spf=0),
              audio_case("invalid-rate-44100", "stereo", steps[:1], rate=44100),
              audio_case("invalid-capacity-huge", "stereo", steps[:1], spf=48_000)]
    return cases


def packing_cases(lanes):
    cases = []
    pairs = [(stream_packets("stereo", lanes, 2 * n), stream_packets("stereo", lanes, 2 * n + 1)) for n in range(6)]

    def double(code, padding=0, vbr=None):
        return [(pack(a[0][0], [a[0][1:], b[0][1:]], False, code=code, padding=padding, vbr=vbr), False)
                for a, b in pairs]
    cases.append(audio_case("pack-stereo-code2", "stereo", double(2), spf=480))
    cases.append(audio_case("pack-stereo-code3-vbr", "stereo", double(3, vbr=True), spf=480))
    cases.append(audio_case("pack-stereo-code3-padded", "stereo", double(3, padding=300, vbr=True), spf=480))
    cases.append(audio_case("pack-stereo-code2-over-capacity", "stereo", double(2), spf=240))
    cases.append(audio_case("pack-stereo-code2-lossy", "stereo",
                            [double(2)[0], (None, False), double(2)[2], (None, False), (None, False)], spf=480))
    for name, packing in {
        "code3-single-padded": lambda i, toc, f, d: pack(toc, [f], d, code=3, padding=7),
        "code3-single-cbr": lambda i, toc, f, d: pack(toc, [f], d, code=3),
        "code3-padding-255": lambda i, toc, f, d: pack(toc, [f], d, code=3, padding=600) if i == 1 else None,
    }.items():
        steps = [(multistream(stream_packets("5.1", lanes, n), packing), False) for n in range(6)]
        cases.append(audio_case(f"pack-5.1-{name}", "5.1", steps))
    return cases


def nal(kind, hevc, short=False, body=b"\xa9\x00\x00\x03\x01\x80", reference=None):
    """Synthetic NAL from the H.264/H.265 header tables, not encoded pictures."""
    prefix = b"\x00\x00\x01" if short else b"\x00\x00\x00\x01"
    if hevc:
        return prefix + bytes([kind << 1, 1]) + body
    ref = reference if reference is not None else (0x60 if kind in (5, 7, 8) else 0)
    return prefix + bytes([kind | ref]) + body


def frame_header(kind, size):
    return bytes([1, 0, 0, kind, size & 0xFF, size >> 8 & 0xFF, 0, 0])


def video_cases():
    cases = []

    def stream(name, fmt, steps):
        cases.append({"name": name, "input": {"format": fmt, "steps": steps, "bytes": None}})

    def scan(name, fmt, data):
        cases.append({"name": name, "input": {"format": fmt, "steps": [], "bytes": data.hex()}})

    def packet(frame, spi, body, kind=2, flags=7, header=True):
        payload = frame_header(kind, len(body) + 8) + body if header else body
        return {"op": "packet", "frame": frame, "spi": spi, "flags": flags, "payload": payload.hex()}

    def op(kind, frame=0):
        return {"op": kind, "frame": frame, "spi": 0, "flags": 0, "payload": ""}

    for fmt, hevc in (("h264", False), ("hevc", True)):
        aud, sei = nal(35 if hevc else 9, hevc, short=True), nal(39 if hevc else 6, hevc)
        params = [nal(t, hevc, short=i == 1) for i, t in enumerate([32, 33, 34] if hevc else [7, 8])]
        idr, pframe = nal(19 if hevc else 5, hevc, short=True), nal(1, hevc)
        au = b"".join(params) + idr
        shapes = {"plain": au, "aud": aud + au, "sei": sei + au, "aud-sei-sei": aud + sei + sei + au,
                  "leading-zeros": bytes(5) + au, "trailing-zeros": au + bytes(3), "sei-after": au + sei,
                  "long-start": b"\x00" * 7 + au[3:], "pps-repeat": au + params[-1] + idr,
                  "emulation": b"".join(params) + nal(19 if hevc else 5, hevc, body=b"\x00\x00\x03" * 40 + b"\x01"),
                  "start-in-payload": b"".join(params) + nal(19 if hevc else 5, hevc, body=b"\x12\x00\x00\x01\x34"),
                  "pframe-first": pframe + au, "garbage": b"\x17\x22" + au, "no-start": b"\x65\x88\x84\x00",
                  "only-zeros": bytes(16), "start-at-end": au + b"\x00\x00\x01", "header-cut": b"\x00\x00\x01",
                  "wrong-codec": nal(7 if hevc else 32, not hevc) + idr,
                  "forbidden-bit": b"\x00\x00\x01" + bytes([0x80 | (64 if hevc else 7)]) + b"\x01\x02",
                  "hevc-tid0": b"\x00\x00\x01\x40\x00\x01\x02", "h264-nonref-sps": nal(7, False, reference=0) + idr,
                  "metadata-only": aud + sei, "metadata-then-pframe": aud + sei + pframe,
                  "large": sei + b"\x00\x00\x03\x01\xa9" * 4000 + au}
        for shape, data in shapes.items():
            scan(f"{fmt}-scan-{shape}", fmt, data)
            stream(f"{fmt}-idr-{shape}", fmt, [packet(1, 0, data), packet(2, 1, pframe, kind=1)])
        for cut in (1, 3, 4, 5, len(au) // 2, len(au) - 2):
            stream(f"{fmt}-split-at-{cut}", fmt, [packet(1, 0, au[:cut], flags=5),
                                                   packet(1, 1, au[cut:], flags=3, header=False)])
        stream(f"{fmt}-split-three", fmt, [packet(1, 0, au[:6], flags=5), packet(1, 1, au[6:12], flags=1, header=False),
                                           packet(1, 2, au[12:], flags=3, header=False)])
        stream(f"{fmt}-refresh", fmt, [packet(1, 0, au), op("refresh"), packet(2, 1, pframe, kind=1),
                                        packet(3, 2, aud + sei + au), packet(4, 3, pframe, kind=1)])
        stream(f"{fmt}-refresh-metadata-pframe", fmt, [packet(1, 0, au), op("refresh"),
                                                        packet(2, 1, aud + sei + pframe, kind=2),
                                                        packet(3, 2, sei + au)])
        stream(f"{fmt}-loss", fmt, [packet(1, 0, au), op("lost", 2), packet(3, 2, pframe, kind=1),
                                     packet(4, 3, au, kind=4), packet(5, 4, pframe, kind=1)])
        stream(f"{fmt}-spi-gap-start", fmt, [packet(1, 1, pframe, kind=1, flags=3)])
        stream(f"{fmt}-pframe-before-idr", fmt, [packet(1, 0, pframe, kind=1), packet(2, 1, au)])
        stream(f"{fmt}-short-first", fmt, [packet(1, 0, au), packet(2, 1, b"\x01\x00\x00\x01\x05", header=False)])
    for name, kind in (("av1-key", 2), ("av1-delta", 1), ("av1-recovery", 4)):
        stream(name, "av1", [packet(1, 0, b"\x12\x00\x0a\x0b"), packet(2, 1, b"\x32\x10", kind=kind)])
    rng = random.Random(20261027)
    alphabet = [b"\x00", b"\x00\x00\x01", b"\x00\x00\x00\x01", b"\x00\x00\x03", b"\x01", b"\x03", b"\x67",
                b"\x68", b"\x65", b"\x41", b"\x06", b"\x09", b"\x40\x01", b"\x42\x01", b"\x44\x01", b"\x26\x01",
                b"\x4e\x01", b"\x46\x01", b"\x02\x01", b"\x80", b"\xff"]
    for index in range(160):
        data = b"".join(rng.choice(alphabet) for _ in range(rng.randint(1, 40)))
        fmt = "hevc" if index % 2 else "h264"
        scan(f"fuzz-{index:03d}", fmt, data)
        if index % 4 < 2:
            stream(f"fuzz-stream-{index:03d}", fmt, [packet(1, 0, data), packet(2, 1, data, kind=1)])
    return cases


def observation_cases():
    def case(name, ops, cancel=None, mutate=None, observers=1):
        return {"name": name, "input": {"ops": ops, "cancelInBodyAt": cancel, "mutateInBodyAt": mutate,
                                        "observers": observers}}
    return [
        case("initial-only", ["settle"]),
        case("single-change", ["a=1", "settle"]),
        case("burst-coalesces", ["a=1", "a=2", "a=3", "a=4", "settle"]),
        case("each-change-settled", ["a=1", "settle", "a=2", "settle", "a=3", "settle"]),
        case("unrelated-ignored", ["unrelated=5", "settle", "b=3", "settle"]),
        case("same-value-write", ["a=0", "settle"]),
        case("cancel-idle", ["settle", "cancel", "settle"]),
        case("cancel-then-change", ["cancel", "a=9", "settle"]),
        case("change-then-cancel", ["a=1", "cancel", "settle"]),
        case("cancel-in-first-delivery", ["a=1", "settle"], cancel=1),
        case("cancel-in-second-delivery", ["a=1", "settle", "a=2", "settle"], cancel=2),
        case("mutate-in-delivery", ["settle", "a=1", "settle", "settle"], mutate=1),
        case("dependency-switch", ["useB", "settle", "a=4", "settle", "b=6", "settle", "useA", "settle",
                                   "b=7", "settle", "a=8", "settle"]),
        case("two-observers", ["a=1", "settle", "cancel", "a=2", "settle"], observers=2),
        case("release-after-cancel", ["a=1", "settle", "cancel", "settle", "release"]),
        case("release-while-observing", ["a=1", "settle", "release"]),
        case("long-burst", [f"a={n}" for n in range(1, 40)] + ["settle", "a=99", "settle"]),
    ]


def main():
    out = Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)
    tool = sys.argv[2]
    corpus = {
        "audio": audio_cases(tool),
        "video": video_cases(),
        "observation": observation_cases(),
        "helper": [{"name": "timeouts", "input": {"ops": [
            "status", "down:silent", "status", "count:late", "status", "status:silent", "down", "count"]}}],
        "grid": [{"name": f"apps-{count}{suffix}", "input": {"apps": names}}
                 for count in (0, 1, 2, 3, 4, 5, 6, 9, 30)
                 for suffix, names in (("", [f"Game {n}" for n in range(count)]),
                                       ("-same-names", ["Desktop"] * count)) if count or not suffix],
    }
    for area, cases in corpus.items():
        (out / f"{area}.json").write_text(json.dumps(cases, indent=1))
        print(f"{area}: {len(cases)} cases")


if __name__ == "__main__":
    main()
