#!/bin/sh

if [ "$(id -u)" -eq 0 ]; then
    exec bleachbit
fi

if command -v pkexec >/dev/null 2>&1; then
    pkexec env WAYLAND_DISPLAY="$WAYLAND_DISPLAY" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" GDK_BACKEND=wayland bleachbit
elif command -v sudo >/dev/null 2>&1; then
    sudo -E env GDK_BACKEND=wayland bleachbit
elif command -v doas >/dev/null 2>&1; then
    doas env WAYLAND_DISPLAY="$WAYLAND_DISPLAY" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" GDK_BACKEND=wayland bleachbit
else
    su -c "WAYLAND_DISPLAY='$WAYLAND_DISPLAY' XDG_RUNTIME_DIR='$XDG_RUNTIME_DIR' GDK_BACKEND=wayland bleachbit"
fi