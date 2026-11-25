#!/usr/bin/env python3
"""Generate the bundled notification sounds into app/Sounds (16-bit mono WAV, standard library only).

The sounds are synthesized here from sine and square waves, in the style of anime and game
interface chimes. Nothing is sampled from an existing recording.

    python3 scripts/make-sounds.py
"""
import math
import os
import random
import struct
import wave

RATE = 44100
OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "app", "Sounds")
NOTES = {"C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11}


def hz(name):
    """'A5' or 'F#6' -> frequency."""
    semitone = NOTES[name[0]] + (1 if "#" in name else 0)
    return 440.0 * 2 ** ((semitone - 9) / 12 + int(name[-1]) - 4)


def bell(t, f):
    return math.sin(2 * math.pi * f * t) + 0.35 * math.sin(2 * math.pi * 2.01 * f * t) + 0.15 * math.sin(2 * math.pi * 3.02 * f * t)


def chip(t, f):   # a soft square wave, the 8-bit game sound
    return sum(math.sin(2 * math.pi * f * k * t) / k for k in (1, 3, 5, 7)) * 0.8


def brass(t, f):  # a few saw harmonics
    return sum(math.sin(2 * math.pi * f * k * t) / k for k in (1, 2, 3, 4, 5)) * 0.6


def add(buf, start, length, freq, decay, voice=bell, gain=1.0, bend=0.0):
    """Mix one note into buf. `bend` slides the pitch by that many semitones over the note."""
    first = int(start * RATE)
    count = int(length * RATE)
    if len(buf) < first + count:
        buf.extend([0.0] * (first + count - len(buf)))
    phase_t = 0.0
    for i in range(count):
        t = i / RATE
        f = freq * 2 ** (bend * (t / length) / 12)
        phase_t += f / freq / RATE   # time warped so the bend stays continuous
        attack = min(1.0, t / 0.004)
        release = min(1.0, (length - t) / 0.01)
        buf[first + i] += gain * attack * release * math.exp(-t / decay) * voice(phase_t, freq)


def sparkle():
    buf = []
    for i, n in enumerate(["C7", "E7", "G7", "C8", "E8"]):
        add(buf, i * 0.05, 0.45, hz(n), 0.12, gain=0.7)
    return buf


def kira_kira():
    buf = []
    rng = random.Random(7)
    scale = ["C7", "D7", "E7", "G7", "A7", "C8", "D8", "E8"]
    for i in range(10):
        add(buf, i * 0.045 + rng.uniform(0, 0.012), 0.3, hz(rng.choice(scale)), 0.07, gain=0.55)
    add(buf, 0.5, 0.6, hz("E8"), 0.18, gain=0.5)
    return buf


def level_up():
    buf = []
    for i, n in enumerate(["C5", "E5", "G5", "C6"]):
        add(buf, i * 0.085, 0.085, hz(n), 0.3, voice=chip, gain=0.5)
    for n in ["C6", "E6", "G6"]:
        add(buf, 0.34, 0.5, hz(n), 0.2, voice=chip, gain=0.3)
    return buf


def ta_da():
    buf = []
    for n in ["G4", "B4", "D5"]:
        add(buf, 0.0, 0.13, hz(n), 0.3, voice=brass, gain=0.35)
    for n in ["C5", "E5", "G5", "C6"]:
        add(buf, 0.16, 0.75, hz(n), 0.3, voice=brass, gain=0.3)
    return buf


def pop():
    buf = []
    add(buf, 0.0, 0.09, 380.0, 0.03, voice=lambda t, f: math.sin(2 * math.pi * f * t), gain=1.0, bend=22)
    return buf


def pikon():   # the bright two-note "notice" chime
    buf = []
    add(buf, 0.0, 0.12, hz("E6"), 0.08, gain=0.7)
    add(buf, 0.075, 0.55, hz("B6"), 0.16, gain=0.8)
    return buf


def magic_wand():
    buf = []
    steps = 16
    for i in range(steps):
        add(buf, i * 0.03, 0.35, hz("C6") * 2 ** (i * 2 / steps), 0.08, gain=0.45)
    add(buf, steps * 0.03, 0.7, hz("C8"), 0.2, gain=0.6)
    return buf


def uh_oh():
    buf = []
    add(buf, 0.0, 0.2, hz("G5"), 0.1, gain=0.8)
    add(buf, 0.17, 0.45, hz("D5"), 0.14, gain=0.8)
    return buf


def question():   # two rising notes, the second sliding up like a spoken "hm?"
    buf = []
    add(buf, 0.0, 0.14, hz("A5"), 0.09, gain=0.7)
    add(buf, 0.13, 0.5, hz("D6"), 0.16, gain=0.8, bend=2)
    return buf


def doorbell():
    buf = []
    add(buf, 0.0, 0.5, hz("E6"), 0.22, gain=0.7)
    add(buf, 0.28, 0.8, hz("C6"), 0.28, gain=0.7)
    return buf


SOUNDS = {"Sparkle": sparkle, "Kira Kira": kira_kira, "Level Up": level_up, "Ta-da": ta_da, "Pop": pop,
          "Pikon": pikon, "Magic Wand": magic_wand, "Uh-oh": uh_oh, "Question": question, "Doorbell": doorbell}

os.makedirs(OUT, exist_ok=True)
for name, make in SOUNDS.items():
    samples = make()
    peak = max(abs(s) for s in samples) or 1.0
    data = b"".join(struct.pack("<h", int(s / peak * 0.8 * 32767)) for s in samples)
    with wave.open(os.path.join(OUT, name + ".wav"), "wb") as f:
        f.setnchannels(1)
        f.setsampwidth(2)
        f.setframerate(RATE)
        f.writeframes(data)
    print(f"{name}.wav  {len(samples) / RATE:.2f}s")
