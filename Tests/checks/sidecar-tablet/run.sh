#!/bin/bash
# Real AppKit input view and CGEvent router with an in-memory event sink.
# No pointer movement, permissions, Sidecar connection, or physical iPad required.
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/../common.sh"
swiftc -O "$root/Sources/SillMenuBar/TabletSurfaceGeometry.swift" \
    "$root/Sources/SillMenuBar/SidecarPencilInput.swift" \
    "$root/Sources/SillMenuBar/SidecarTablet.swift" "$here/main.swift" -o "$out/check"
"$out/check"
