#!/usr/bin/env python3
"""Generate deterministic stereo WAV/FLAC pairs with a fixed one-second PCM buffer."""
import argparse
import math
from pathlib import Path
import random
import subprocess
import wave


def generate(root, name, rate, bits, seconds):
    wav, flac = root / f"{name}.wav", root / f"{name}.flac"
    rng = random.Random(21022)
    chunk = bytearray()
    for frame in range(rate):
        left = int((math.sin(2 * math.pi * 440 * frame / rate) * 0.03
                    + rng.uniform(-0.02, 0.02)) * ((1 << (bits - 1)) - 1))
        right = int((math.sin(2 * math.pi * 1100 * frame / rate) * 0.02
                     + rng.uniform(-0.02, 0.02)) * ((1 << (bits - 1)) - 1))
        chunk.extend(left.to_bytes(bits // 8, "little", signed=True))
        chunk.extend(right.to_bytes(bits // 8, "little", signed=True))
    with wave.open(str(wav), "wb") as file:
        file.setnchannels(2)
        file.setsampwidth(bits // 8)
        file.setframerate(rate)
        for _ in range(seconds):
            file.writeframesraw(chunk)
    subprocess.run(["afconvert", "-f", "flac", "-d", "flac", str(wav), str(flac)], check=True)
    print(f"{name}: {seconds}s {rate}Hz {bits}bit stereo; WAV {wav.stat().st_size} bytes; FLAC {flac.stat().st_size} bytes")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--short-seconds", type=int, default=60)
    parser.add_argument("--large-seconds", type=int, default=600)
    args = parser.parse_args()
    if not (0 < args.short_seconds <= 3600 and 0 < args.large_seconds <= 3600):
        parser.error("durations must be between 1 and 3600 seconds")
    args.output.mkdir(parents=True, exist_ok=True)
    for name in ["short.wav", "short.flac", "large.wav", "large.flac"]:
        if (args.output / name).exists():
            parser.error(f"use a fresh output directory; {name} already exists")
    generate(args.output, "short", 44100, 16, args.short_seconds)
    generate(args.output, "large", 96000, 24, args.large_seconds)


if __name__ == "__main__":
    main()
