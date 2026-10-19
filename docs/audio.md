# Audio

Status: Implemented · Updated: 2026-10-18

The TrimUI Brick's speakers, headphone jack, volume and microphone, all on the A133P's built-in sound chip (the codec). The kernel's codec driver now switches between speaker and headphones, powers the amplifiers only while sound plays, and keeps the volume across playback and sleep. TrimUI's setup did none of this and relied on start-up scripts to force the outputs on. Bluetooth audio is in [wireless.md](wireless.md).

## Decisions

- **The headphone jack switches the outputs inside the kernel** (2026-10-11). Plugging and unplugging are reported through the sound system's standard jack handling, which turns the "Headphone" and "HpSpeaker" outputs on and off. Rejected: stock's approach, which forces both outputs on at start-up and mutes the speaker through TrimUI's own code in the codec driver.
- **The headphone amplifier is a separate stage that feeds both outputs** (2026-10-11). The speaker amplifier takes its sound from the headphone outputs, so the speaker was silent unless the headphone amplifier was on for some other reason.
- **The jack's microphone detection is off (device tree `noheadphonemic`)** (2026-10-11). The jack has no microphone contact. The detection fired during playback with nothing plugged in, and its handler turned both amplifiers off, then back on 700 ms later.
- **Volume is the codec's DAC volume, with a level of its own for the speaker and for the headphones, kept in the codec driver** (2026-10-18). The controls "Speaker Playback Volume" and "Headphone Playback Volume" store a level each, and the driver puts the level of the output in use into the DAC volume register, so plugging headphones in never blasts them at the speaker's level. The register has no control of its own, so there is one way to set it. The headphone amplifier's gain stays at its start-up setting. Rejected: one level for both outputs (what we had from 2026-10-13: a level that suits the speaker is too loud in headphones); Specular switching levels on jack events (it would race the kernel's own switch and be wrong whenever Specular isn't running); keeping "DAC volume" as a control (two writers to one register); stock's ALSA software volume ("Soft Volume Master"), which refuses writes.
- **Volume controls go up for louder** (2026-10-11). In hardware, "Headphone Volume" and "digital volume" are cuts (register 0 is loudest). Their controls are inverted to match their dB scales.
- **The driver keeps the volume when playback starts and after sleep** (2026-10-13). The BSP driver wrote 0 to the volume register at every mute, and the device tree's default at every unmute, on each stream start and on resume. That threw away the level the user set. Rejected: Specular setting the level again after waking (a workaround, since removed).
- **Headphone amplifier at −18 dB from start-up (device tree `headphonegain 3`)** (2026-10-11). This is what TrimUI's start-up script set. Register 0 (0 dB) is very loud.
- **No ALSA software mixing (no `dmix`)** (2026-10-18). Specular is the only program that plays sound; mixing gets added when a second program needs to play alongside it. Rejected: stock's software volume and `dmix` chain (latency and CPU for nothing while there is one player).

## Design

```
playback ─► DAC volume ─► headphone amplifier ("Headphone Volume", −18 dB) ─┬─► headphone jack   (pin "Headphone")
                                                                               └─► speaker amplifier (enable PH6) ─► 2 speakers (pin "HpSpeaker")
jack detect (inside the codec, active high) ─► jack report ─► switches the two pins; input device "audiocodec sunxi Audio Jack"
```

- There is one ALSA card, `audiocodec`, with one playback and one capture device.
- The sound system powers the headphone amplifier and the speaker amplifier only while sound plays, and the speaker only while the jack is empty.
- The headphone gain also sets the speaker's loudness, since the speaker amplifier is fed from the headphone outputs.
- The DAC volume register gets an output's level when that output powers up (as playback starts, or when the jack switches outputs during playback; the speaker's before its amplifier is on), and when that output's control changes while the jack selects it. A jack change while nothing plays takes effect when playback next starts. Both levels start at the device tree's `dac_digital_vol` (0xA0 = +0.75 dB unless set). Bluetooth audio doesn't go through the codec, so neither level affects it.

The controls that matter (`amixer -c audiocodec`):

```
Speaker Playback Volume     0–255, 0.75 dB per step, 159 = 0 dB (the top goes to +72 dB, which only clips);
                            one value for both channels
Headphone Playback Volume   the same, for the headphones
Headphone Volume            0–7, 6 dB per step, 7 = 0 dB: the headphone amplifier's gain, which also
                            drives the speaker; the device tree's headphonegain sets it at start-up
digital volume              0–63, 1.16 dB per step, 63 = 0 dB; left at the device tree's default
```

What Specular uses: `amixer -q -c audiocodec cset name='Speaker Playback Volume' <v>` and `name='Headphone Playback Volume' <v>` (until it is updated it still writes `DAC volume`, which no longer exists). Its levels are 2 dB apart, with the top level at 0 dB, and level 0 maps to the control's lowest setting. Game sound goes to ALSA's `default` device, resampled to 48 kHz. The image has no ALSA configuration file. Specular treats the Mute switch as volume 0.

USB audio (headset dongles, USB-C DACs) uses the kernel's standard USB audio driver, which is built in. Using it needs a third sound output in Specular.

## Findings

- (2026-10-11, device) The only sound card is `audiocodec`. "Headphone" and "HpSpeaker" both come from the headphone outputs. The speaker amplifier hangs off the headphone amplifier and is switched only by PH6, which stock leaves on all the time. The line output is unused. The codec's dynamic-range compressor is on for the speaker.
- (2026-10-11, device) Headphone detection is active-high, so device-tree `hp_detect_case` must be 1. Stock's 0 is inverted, which nobody noticed because stock's `rc.local` forces both outputs on.
- (2026-10-11, device) "Headphone Volume" (register 0x310, bits 30:28) and "digital volume" are cuts, with register 0 loudest. Stock starts with the headphone gain at register 3 (−18 dB).
- (2026-10-10, stock) Stock sets its volume levels 0–20 through `digital volume`. At level 0 it also mutes the speaker amplifier (`/sys/class/speaker/mute`, a TrimUI addition). `/etc/asound.conf` mixes all programs into the card at 48 kHz through a software volume. The kernel switches outputs for headphones; userspace is not involved.
- (2026-10-10, stock) There are two 0.5 W speakers (the spec sheet says stereo). The speaker amplifier chip is unknown. The vendor tree has a node for an external amplifier (`acm8625`), but it is disabled.
- (2026-10-10, upstream) Mainline Linux has no driver for the A100/A133 built-in codec. Allwinner's 5.15 BSP tree (radxa/allwinner-bsp) has one and is the best reference for writing one.
- (2026-10-10, stock) Microphone: the spec sheet lists a built-in mono microphone. The codec has two analog microphone inputs, MIC1 and MIC2, each with a boost switch and 0–31 dB of gain. The vendor tree sets `mic1gain = mic2gain = 31` and disables the digital-microphone interface (PH8–PH12). Nothing says which input the microphone is wired to.
- (2026-10-10, stock) Stock's kernel offers a capture device on `audiocodec`. Stock's `rc.local` turns on both microphone boosts and sets both gains to 18. It also sets gains on an AC107 (an external recording chip), which this device does not have. Our research found no stock program that records.
- (2026-10-11, inferred) Our codec driver still has the capture path (MIC1/MIC2 inputs, boosts and a "MainMic Bias" supply). Nobody has tested recording on our kernel or on stock. Source: `sound/soc/sunxi/sun50iw10-codec.c`.
