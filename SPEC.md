# PadSounds — specification

**Tagline:** A grid of sound pads you trigger by click or keyboard key, for streams, podcasts, classes and jokes.

**Category:** Audio

**Inspired by (paid):** Jingle Box ($19.99 one-time)

**Frameworks:** SwiftUI, AppKit, AVFoundation, UniformTypeIdentifiers, ServiceManagement

**Donation URL (Support button):** https://ko-fi.com/leodavidai

## Spec

What the paid app does: Jingle Box is a Mac App Store soundboard sold for 19.99 dollars that plays audio clips from keyboard keys or the mouse, aimed at podcasters, DJs and presenters, with extras like MIDI and AirPlay output. Older soundboard apps such as Ambrosia Soundboard and Farrago have long been sold in the same niche, and a free soundboard also exists on the store, so there is clear continuing demand even though the store page shows modest review counts. Our clean-room PadSounds keeps only the simple core: a pad grid, hotkeys, and per-pad playback controls.

Feature set: a grid of up to 16 pads, each with a label, color, imported audio file, volume, loop toggle, play mode (play once, hold to play, toggle), and an assigned single key. Drag and drop an audio file on a pad to assign it. A Stop All button and an Escape-key shortcut. A fade out duration for stopping. A master volume slider. Choose the output device for the whole board. Save the board automatically. About 400 to 600 lines.

UI spec: a normal window app with an optional menu bar item that shows the window. The main window shows a 4 by 4 grid of rounded square pads, each showing the label, the assigned key in a corner, and a progress ring while playing. Click plays the pad. Right click or a small gear opens an inspector popover for label, color, key, volume, loop, mode and Replace File. Toolbar: Stop All, master volume, output device picker, and a Keys Active toggle. Empty state: unassigned pads show a plus sign with the text Drop audio here. Keyboard: when the window is focused, assigned keys trigger pads. An optional toggle enables global triggering using function key combinations, which asks for the Accessibility or Input Monitoring permission with an explanation first.

Technical approach: AVAudioEngine with one AVAudioPlayerNode per pad connected to a master mixer, loading AVAudioFile buffers for short clips and streaming longer ones with scheduleFile. Fade out using a timer that ramps the player node volume. Switch output device by setting the engine output audio unit device property to the chosen CoreAudio device ID. Import files using fileImporter or onDrop with UTType.audio. Because the app is sandbox friendly, copy imported files into Application Support, so pads keep working if the original moves. Persist the board as a JSON file in Application Support with pad definitions that reference the copied file names. Local key handling uses an NSEvent local monitor. Global keys optionally use an NSEvent global monitor after checking AXIsProcessTrusted and prompting. Launch at login with SMAppService is optional.

Edge cases: a missing or unreadable file shows a red warning badge on the pad and a toast. Pressing a playing pad in play once mode restarts it. Hold mode stops on key up. Two pads sharing the same key are rejected with a message. Large files should stream rather than load wholly into memory. If the chosen output device disappears, fall back to the system default and show a note. Key presses while typing in a text field such as the label editor must not trigger pads, so check first responder state. Sample rate differences between files are handled by the mixer connection format.
