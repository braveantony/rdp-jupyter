#!/usr/bin/env bash
# Create or update the RDP login accounts and print their names.
# Accounts come from a users file ("user:password" per line; blank lines and
# # comments ignored), or from RDP_USER (default bigred) / RDP_PASSWORD.
# Each account gets a fixed UID by position (1000, 1001, ...) and a private home.
set -eu
users_file=${1:-/etc/rdp-jupyter/users}

accounts=$(mktemp)
trap 'rm -f "$accounts"' EXIT
if [ -s "$users_file" ]; then
  # Strip CR so a file edited on Windows does not add \r to every password
  tr -d '\r' < "$users_file" | grep -vE '^[[:space:]]*(#|$)' > "$accounts" || true
else
  if [ -z "${RDP_PASSWORD:-}" ]; then
    echo "[entrypoint] set RDP_PASSWORD or mount a users file at $users_file" >&2
    exit 1
  fi
  printf '%s:%s\n' "${RDP_USER:-bigred}" "$RDP_PASSWORD" > "$accounts"
fi

# Validate everything before touching /etc/passwd
users=""
while IFS=: read -r user pass; do
  case $user in
    root | xrdp) echo "[entrypoint] account name not allowed: $user" >&2; exit 1 ;;
  esac
  if ! printf '%s' "$user" | grep -Eq '^[a-z_][a-z0-9_-]{0,31}$'; then
    echo "[entrypoint] invalid account name: $user" >&2
    exit 1
  fi
  if [ -z "$pass" ]; then
    echo "[entrypoint] empty password for account: $user" >&2
    exit 1
  fi
  case " $users " in
    *" $user "*) echo "[entrypoint] duplicate account: $user" >&2; exit 1 ;;
  esac
  existing=$(id -u "$user" 2>/dev/null || true)
  if [ -n "$existing" ] && [ "$existing" -lt 1000 ]; then
    echo "[entrypoint] account name not allowed (system account): $user" >&2
    exit 1
  fi
  users="$users $user"
done < "$accounts"
if [ -z "$users" ]; then
  echo "[entrypoint] no accounts defined in $users_file" >&2
  exit 1
fi

uid=1000
while IFS=: read -r user pass; do
  if id "$user" >/dev/null 2>&1; then
    [ "$(id -u "$user")" = "$uid" ] || usermod -o -u "$uid" "$user"
  else
    useradd -M -U -u "$uid" -s /bin/bash "$user"
  fi
  printf '%s:%s\n' "$user" "$pass" | chpasswd -c SHA512

  home=/home/$user
  if [ ! -d "$home" ]; then
    cp -a /etc/skel "$home"
    chown -R "$user:$user" "$home"
  elif [ "$(stat -c %u "$home")" != "$uid" ]; then
    # users file reordered on a kept /home: hand the home to the new UID
    chown -R "$user:$user" "$home"
  fi
  chmod 700 "$home"
  uid=$((uid + 1))
done < "$accounts"

# Homes of accounts no longer in the file (kept on a PVC) would otherwise
# belong to whichever account now has their old UID: lock them to root
for home in /home/*; do
  [ -d "$home" ] && [ ! -L "$home" ] || continue
  case " $users " in
    *" ${home#/home/} "*) ;;
    *) chown root:root "$home" && chmod 700 "$home" ;;
  esac
done

echo "${users# }"
