# HitPad

Turn an iPad into a tablet-style pointer for your Mac.

HitPad connects to an iPad through Sidecar and maps Pencil or touch input to the Mac pointer.
Choose direct Tablet mapping or relative Trackpad movement, adjust the active area, and enable finger input when supported.
No HitPad app is required on the iPad.

## Download

[Download HitPad for Mac](https://github.com/donghaxkim/sill/releases/latest/download/HitPad.dmg) · [All releases](https://github.com/donghaxkim/sill/releases)

## Requirements

- A Mac running macOS 14 or later.
- An iPad and Mac that support Sidecar and use the same Apple Account.
- A USB connection or a compatible Wi-Fi connection.
- Pointer Control permission for HitPad to send pointer events to Mac apps.

## Use

1. Open HitPad on your Mac and choose the iPad shown in the Connection section.
2. Select Tablet mode to map positions directly, or Trackpad mode to move the pointer by relative distance.
3. Drag the highlighted area to move it or a corner handle to resize it.
4. Use the percentage fields for precise values, then choose Save to keep the area for next time.

In Tablet mode, the outlined area on the iPad maps exactly to the selected Mac display.
The pointer stays at its last position when you lift the Pencil and jumps to the new absolute position on the next contact.

## Build from source

Build and open the Mac app with:

```sh
Scripts/make-app.sh --install --open
```

Without `--install`, the app is built at `.build/HitPad.app`.

## License

HitPad is distributed under the [Apache License 2.0](LICENSE).

This fork contains portions of the Sill project, copyright 2026 Noah Saffer, used under that license.
