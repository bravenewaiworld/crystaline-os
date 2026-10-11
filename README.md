# Brick OS (working title)

A retro-game emulation OS for the TrimUI Brick Hammer (TG3040: Allwinner A133P, PowerVR GE8300,
1024×768 panel).

## Goal

A sleek, highly polished retro-emulation OS that gets the best possible performance, battery
life and functionality out of this hardware.

**Hardware**
- Support every hardware feature, for both performance and power efficiency.
- Bluetooth audio output (headphones).
- WiFi, mainly for moving files and debugging to start with.

**Software**
- A minimal but functional and joyful user experience.
- Isolated from the kernel and from TrimUI's libraries and quirks: standard Linux interfaces
  wherever possible, and an adapter in the frontend for TrimUI's GPU libraries, which are the
  one closed part we can't avoid.
- Emulation through libretro cores, with well-chosen defaults. Only expose settings that people
  genuinely disagree on.
- Seamless management of games, saves and cores, including moving them to and from a PC.
- Runs from an SD card, or installed to the internal storage so the card holds only games,
  saves and settings.

## Layout

| Path | Contents |
|---|---|
| `linux/` | Our kernel: Allwinner's 4.9 vendor kernel with our changes (its own git repository, branch `brick`) |
| `userspace/` | System services (e.g. `padbridge`, which turns the buttons into a standard gamepad) |
| `frontend/` | User interface and emulation (not started) |
| `tools/` | Development scripts and utilities |
| `Makefile` | Builds everything; `make help` lists the targets |
| `ROADMAP.md` | What works, what's missing, and what's next |
| `.scratch/` | Earlier work, research notes (`JOURNAL.md`), vendor firmware and third-party sources, to be sorted out later |

## Installation

Not available yet. For now, `make test-card` builds a development SD card (our kernel and
services on top of TrimUI's stock system); see `ROADMAP.md`.
