#!/bin/bash
# Launched from the "Uninstall Git Manager" menu entry. Runs as the
# normal user first (to confirm), then escalates via pkexec only for
# the actual package removal, so the user never needs a terminal.
set -e

PKG_NAME="git-manager"

if command -v zenity >/dev/null 2>&1; then
  zenity --question \
    --title="Uninstall Git Manager" \
    --text="Remove Git Manager from this computer?\n\nYour saved GitHub accounts/tokens and git configuration (user.name, user.email, credentials) will not be touched." \
    --width=400 || exit 0
fi

if pkexec apt-get remove -y "$PKG_NAME"; then
  if command -v notify-send >/dev/null 2>&1; then
    notify-send "Git Manager" "Uninstalled successfully."
  elif command -v zenity >/dev/null 2>&1; then
    zenity --info --title="Git Manager" --text="Uninstalled successfully." --width=300
  fi
else
  if command -v zenity >/dev/null 2>&1; then
    zenity --error --title="Git Manager" \
      --text="Could not uninstall Git Manager.\n\nYou can try again, or run this in a terminal:\nsudo apt-get remove $PKG_NAME" \
      --width=400
  fi
  exit 1
fi
