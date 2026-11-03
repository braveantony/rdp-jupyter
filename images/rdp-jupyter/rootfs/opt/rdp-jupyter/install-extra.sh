#!/usr/bin/env bash
# postStart hook: install admin-provided extra Python packages atomically.
#
# Must ALWAYS exit 0: a failing postStart hook kills the container. Failures are
# reported through $EXTRA_DIR/FAILED and the log instead.
# Result: $EXTRA_DIR/current -> $EXTRA_DIR/<hash>, $EXTRA_DIR/.stamp = <hash>.
set -u

REQ_FILE=${REQ_FILE:-/etc/rdp-jupyter/requirements/requirements.txt}
EXTRA_DIR=${EXTRA_DIR:-/opt/jupyter/extra}
BASE_CONSTRAINTS=${BASE_CONSTRAINTS:-/opt/jupyter/constraints.txt}
IMAGE_VERSION_FILE=${IMAGE_VERSION_FILE:-/opt/rdp-jupyter/VERSION}
PIP_CMD=${PIP_CMD:-uv pip install --python /opt/jupyter/venv/bin/python}
LOG_OUT=${LOG_OUT:-/proc/1/fd/1}
INSTALL_TIMEOUT=${INSTALL_TIMEOUT:-900}
case $INSTALL_TIMEOUT in '' | *[!0-9]* | 0) INSTALL_TIMEOUT=900 ;; esac

# Print to stdout and append to LOG_OUT (stdout only if LOG_OUT is not writable).
log() {
  printf '[install-extra] %s\n' "$*" | tee -a "$LOG_OUT" 2>/dev/null || true
}

main() {
  [ -r "$REQ_FILE" ] || { log "no requirements file, nothing to do"; return 0; }

  local clean_req hash version=''
  clean_req=$(mktemp) || { log "cannot create temp file"; return 0; }
  # shellcheck disable=SC2064  # expand now: the path is fixed
  trap "rm -f '$clean_req'" RETURN
  tr -d '\r' <"$REQ_FILE" >"$clean_req"
  if ! grep -qvE '^[[:space:]]*(#|$)' "$clean_req"; then
    log "requirements file has no packages, nothing to do"
    return 0
  fi
  [ -r "$IMAGE_VERSION_FILE" ] && version=$(tr -d '[:space:]' <"$IMAGE_VERSION_FILE")
  hash=$({ cat "$clean_req"; printf '\n%s\n%s\n' "${PIP_INDEX_URL:-}" "$version"; } \
    | sha256sum | cut -c1-16)

  mkdir -p "$EXTRA_DIR" || { log "cannot create $EXTRA_DIR"; return 0; }
  # Serialize: postStart is at-least-once, and runs may overlap.
  exec 9>"$EXTRA_DIR/.lock" || { log "cannot open lock file"; return 0; }
  flock 9 || { log "cannot take lock"; return 0; }

  if [ "$(cat "$EXTRA_DIR/.stamp" 2>/dev/null)" = "$hash" ] && [ -d "$EXTRA_DIR/current/" ]; then
    log "up to date ($hash), skipping"
    return 0
  fi

  rm -rf "$EXTRA_DIR"/*.tmp "$EXTRA_DIR/.tmpdir"
  local tmpdir=$EXTRA_DIR/.tmpdir target=$EXTRA_DIR/$hash.tmp
  mkdir -p "$tmpdir" || { log "cannot create $tmpdir"; return 0; }

  local -a cmd
  read -r -a cmd <<<"$PIP_CMD"
  cmd+=(--target "$target" -c "$BASE_CONSTRAINTS" -r "$clean_req")
  if grep -q -- '--hash=' "$clean_req"; then cmd+=(--require-hashes); fi

  log "installing extra packages ($hash)"
  local err rc
  err=$(mktemp "$tmpdir/pip-out.XXXXXX") || { log "cannot create temp file"; return 0; }
  TMPDIR=$tmpdir timeout "$INSTALL_TIMEOUT" "${cmd[@]}" >"$err" 2>&1 </dev/null
  rc=$?

  if [ "$rc" -ne 0 ]; then
    [ "$rc" -eq 124 ] && echo "install timed out after ${INSTALL_TIMEOUT}s" >>"$err"
    head -n 20 "$err" >"$EXTRA_DIR/FAILED"
    log "install FAILED (rc=$rc), keeping previous packages:"
    while IFS= read -r line; do log "  $line"; done <"$EXTRA_DIR/FAILED"
    rm -rf "$target" "$tmpdir"
    return 0
  fi

  # Switch: rename target, then atomically repoint the symlink.
  rm -rf "${EXTRA_DIR:?}/$hash"
  if ! mv -T "$target" "$EXTRA_DIR/$hash" \
    || ! ln -sfn "$hash" "$EXTRA_DIR/.current.new" \
    || ! mv -T "$EXTRA_DIR/.current.new" "$EXTRA_DIR/current"; then
    echo "failed to switch to $hash" >"$EXTRA_DIR/FAILED"
    log "install FAILED: could not switch current"
    rm -rf "$target" "$tmpdir" "$EXTRA_DIR/.current.new"
    return 0
  fi
  printf '%s\n' "$hash" >"$EXTRA_DIR/.stamp.new" && mv -f "$EXTRA_DIR/.stamp.new" "$EXTRA_DIR/.stamp"
  rm -f "$EXTRA_DIR/FAILED"
  rm -rf "$tmpdir"

  local d
  for d in "$EXTRA_DIR"/*/; do
    d=${d%/}
    [[ ${d##*/} =~ ^[0-9a-f]{16}$ ]] && [ "${d##*/}" != "$hash" ] && rm -rf "$d"
  done
  log "installed ($hash)"
  return 0
}

main "$@" || log "unexpected error (ignored)"
exit 0
