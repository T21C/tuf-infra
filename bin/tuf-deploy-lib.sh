#!/usr/bin/env bash
# Shared by the production deploy scripts. Sourced, not executed.

readonly TUF_STACK_RELOAD_REQUEST=/run/tuf/stack-reload-services
readonly TUF_STACK_RELOAD_ERROR=/run/tuf/stack-reload-last-error.txt

# Ask tuf-stack.service to reconcile only these services. The systemd reload
# reads the request while this process is still alive; a full-stack reload
# (infra sync, manual systemctl reload) ignores a stale file.
request_stack_reload() {
  local unit=$1
  shift
  local temporary status=0

  (( $# > 0 )) || {
    echo "request_stack_reload: no services given" >&2
    return 64
  }

  /usr/bin/install -d -m 0755 /run/tuf
  temporary=$(/usr/bin/mktemp /run/tuf/stack-reload-services.XXXXXX)
  {
    printf 'pid=%s\n' "$$"
    printf '%s\n' "$@"
  } >"$temporary"
  /usr/bin/chmod 0600 "$temporary"
  /usr/bin/mv -f "$temporary" "$TUF_STACK_RELOAD_REQUEST"

  /usr/bin/systemctl reload "$unit" || status=$?
  /usr/bin/rm -f "$TUF_STACK_RELOAD_REQUEST"
  if (( status == 0 )); then
    return 0
  fi

  echo "$unit reload failed" >&2
  if [[ -s $TUF_STACK_RELOAD_ERROR ]]; then
    /usr/bin/cat "$TUF_STACK_RELOAD_ERROR" >&2
  else
    /usr/bin/systemctl status "$unit" --no-pager -l --lines=40 >&2 || true
    /usr/bin/journalctl -u "$unit" -n 80 --no-pager >&2 || true
  fi
  return "$status"
}
