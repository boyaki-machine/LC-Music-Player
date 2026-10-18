#!/usr/bin/env python3
"""Generate original sine-wave audio; no third-party music is used.

The MP3 fixtures (tone.mp3 and gapless-*.mp3) are committed and not regenerated: the app
no longer bundles an MP3 encoder. They were encoded from original signals with LAME 3.100.
gapless-*.mp3 carry a LAME/Xing header with the encoder delay and padding, next to the
WAV each was encoded from; tone.mp3 has no valid header.
"""
import argparse
import math
from pathlib import Path
import subprocess
import wave

ROOT = Path(__file__).resolve().parent.parent


def write_wave(path, rate, bits, channels, duration):
    samples = [int(math.sin(2 * math.pi * 440 * n / rate) * 0.05 * (2 ** (bits - 1) - 1))
               for n in range(int(rate * duration))]
    with wave.open(str(path), "wb") as file:
        file.setnchannels(channels)
        file.setsampwidth(bits // 8)
        file.setframerate(rate)
        file.writeframes(b"".join(
            value.to_bytes(bits // 8, "little", signed=True) * channels for value in samples
        ))
    return samples


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--duration", type=float, default=0.25)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    wav = args.output / "tone.wav"
    write_wave(wav, 44100, 16, 1, args.duration)
    high = args.output / "tone-96k-24bit.wav"
    write_wave(high, 96000, 24, 2, args.duration)
    for source, name, container, codec in [
        (wav, "tone.aiff", "AIFF", "BEI16"),
        (wav, "tone-aac.m4a", "m4af", "aac"),
        (wav, "tone-alac.m4a", "m4af", "alac"),
        (wav, "tone.flac", "flac", "flac"),
        (high, "tone-96k-24bit.flac", "flac", "flac"),
    ]:
        subprocess.run(["afconvert", "-f", container, "-d", codec, str(source), str(args.output / name)], check=True)
    (args.output / "broken.wav").write_text("This is intentionally not audio.\n")
    print(f"Generated audio fixtures in {args.output}")


if __name__ == "__main__":
    main()
