# Vocal — App Icon & Branding

The Vocal app icon: a voice waveform that flattens into a line of text ending in a
text-insertion cursor — speech becoming text, the app's entire core loop in one mark.

- **Palette:** analogous indigo → violet → electric-blue gradient with a soft radial glow.
- **Mark:** single white glossy waveform-to-cursor symbol, no lettering, legible at 16 px.
- **Style:** soft-3D minimal, in line with current top App Store icon design.

## Files

| File | Purpose |
|---|---|
| `AppIcon-1024.png` | Full-bleed 1024×1024 master (no rounded corners — iOS/macOS apply the squircle mask). Source for all generated sizes. |
| `AppIcon-presentation.png` | Squircle presentation render for docs/marketing. |
| `exploration/` | Alternate concepts considered during design exploration. |

## Generated app assets

- `apps/iOSApp/Sources/Resources/Assets.xcassets/AppIcon.appiconset` — single universal 1024 px icon (Xcode generates all sizes).
- `apps/MacApp/Sources/Resources/Assets.xcassets/AppIcon.appiconset` — full macOS size set (16–512 pt @1x/@2x).

To regenerate sizes from the master, resize `AppIcon-1024.png` with Lanczos resampling.
