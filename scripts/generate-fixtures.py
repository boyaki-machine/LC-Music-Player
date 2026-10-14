#!/usr/bin/env python3
"""Generate original sine-wave audio; no third-party music is used."""
import argparse
import ctypes
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


def write_mp3(path, samples, rate):
    library = ROOT / ".build/debug/lame.framework/Versions/A/lame"
    lame = ctypes.CDLL(str(library))
    lame.lame_init.restype = ctypes.c_void_p
    for name in ["lame_set_num_channels", "lame_set_in_samplerate", "lame_set_brate"]:
        getattr(lame, name).argtypes = [ctypes.c_void_p, ctypes.c_int]
    lame.lame_init_params.argtypes = [ctypes.c_void_p]
    lame.lame_encode_buffer.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_short),
        ctypes.POINTER(ctypes.c_short), ctypes.c_int, ctypes.POINTER(ctypes.c_ubyte), ctypes.c_int]
    lame.lame_encode_flush.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_ubyte), ctypes.c_int]
    lame.lame_close.argtypes = [ctypes.c_void_p]
    handle = lame.lame_init()
    if not handle:
        raise RuntimeError("lame_init failed")
    try:
        for name, value in [("lame_set_num_channels", 1), ("lame_set_in_samplerate", rate), ("lame_set_brate", 128)]:
            if getattr(lame, name)(handle, value) < 0:
                raise RuntimeError(name + " failed")
        if lame.lame_init_params(handle) < 0:
            raise RuntimeError("lame_init_params failed")
        pcm = (ctypes.c_short * len(samples))(*samples)
        size = int(1.25 * len(samples) + 7200)
        output = (ctypes.c_ubyte * size)()
        count = lame.lame_encode_buffer(handle, pcm, pcm, len(samples), output, size)
        if count < 0:
            raise RuntimeError("MP3 encode failed")
        encoded = bytes(output[:count])
        count = lame.lame_encode_flush(handle, output, size)
        if count < 0:
            raise RuntimeError("MP3 flush failed")
        path.write_bytes(encoded + bytes(output[:count]))
    finally:
        lame.lame_close(handle)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--duration", type=float, default=0.25)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    wav = args.output / "tone.wav"
    samples = write_wave(wav, 44100, 16, 1, args.duration)
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
    write_mp3(args.output / "tone.mp3", samples, 44100)
    (args.output / "broken.wav").write_text("This is intentionally not audio.\n")
    print(f"Generated audio fixtures in {args.output}")


if __name__ == "__main__":
    main()
