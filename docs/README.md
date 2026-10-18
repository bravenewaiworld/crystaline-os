# Design docs

Why Crystaline OS works the way it does: decisions, designs and research, one doc per topic. What is done and what is left is in [ROADMAP.md](../ROADMAP.md); how to work on it is in [DEVELOPMENT.md](../DEVELOPMENT.md).

| Doc | Covers |
|---|---|
| [platform.md](platform.md) | The chip and the board, the vendor kernel versus mainline, TrimUI's stock firmware, related projects |
| [boot.md](boot.md) | Boot chain, bootloaders and their settings, boot images, start-up, watchdog |
| [system-image.md](system-image.md) | The Buildroot image, services, user data on the SD card, file transfer, development access |
| [install-and-update.md](install-and-update.md) | System versions, updates, installing to internal storage, backup and restore |
| [storage.md](storage.md) | SD card and internal storage hardware, the data partition's filesystem |
| [usb.md](usb.md) | USB ports, role switching, the network link |
| [display.md](display.md) | Panel and its controller variants, display engine, vsync |
| [gpu.md](gpu.md) | PowerVR GPU driver and libraries |
| [power.md](power.md) | Power chip, battery and charging, CPU speed, thermal limits, sleep, power measurements |
| [input.md](input.md) | Buttons, FN switch, power key, the virtual gamepad |
| [leds-and-rumble.md](leds-and-rumble.md) | LEDs and the rumble motor |
| [audio.md](audio.md) | Speaker, headphones, volume |
| [wireless.md](wireless.md) | WiFi and Bluetooth (XR829), Bluetooth audio |

## Format

Every doc follows this template. Leave out a section that would be empty, and keep the order.

````markdown
# <Topic>

Status: Planned | In progress | Implemented · Updated: <YYYY-MM-DD>

<One paragraph: what this covers and why it matters.>

## Decisions

- **<What we do, as a statement>** (<YYYY-MM-DD>). <Why.> Rejected: <alternative> (<why not>).

## Design

<How it works, or will work: structure, data flow, file and partition layouts. New or changed
interfaces, types and formats go in as code snippets (a code outline).>

## Findings

- (<YYYY-MM-DD>, <kind>) <Fact.> Source: <file in this repo or a public link, if any>.

## Open questions

- <Question, and what would answer it.>
````

- **One doc per topic, kept current.** Update it in place as things change; it describes how things are, not how they got there. When a decision is reversed, rewrite it and put the old choice under "Rejected" with the reason.
- **Decisions** carry the date they were made and what was rejected, so they aren't relitigated.
- **Findings** are facts we relied on, each tagged with where it came from:
  - `device`: measured on our device.
  - `stock`: read from TrimUI's stock firmware.
  - `bsp`: from Allwinner's vendor sources.
  - `upstream`: from mainline Linux, other projects or datasheets.
  - `inferred`: reasoned but not verified.
- **No duplication.** Status of work belongs in the roadmap; how-to belongs in DEVELOPMENT.md; what the code makes obvious belongs nowhere.
- A new topic gets a new doc and a line in the table above.
