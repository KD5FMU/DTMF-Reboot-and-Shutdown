#!/bin/bash
#
# install-reboot-shutdown-dtmf.sh
#
# Creates:
#   /etc/asterisk/local/reboot-node.sh
#   /etc/asterisk/local/shutdown-node.sh
#
# Downloads:
#   /var/lib/asterisk/sounds/custom/rebooting.ul
#   /var/lib/asterisk/sounds/custom/shutdown.ul
#
# Adds DTMF functions to /etc/asterisk/rpt.conf:
#   992=cmd,/etc/asterisk/local/reboot-node.sh
#   993=cmd,/etc/asterisk/local/shutdown-node.sh
#
# Then makes the scripts executable.

set -euo pipefail

LOCAL_DIR="/etc/asterisk/local"
SOUND_DIR="/var/lib/asterisk/sounds/custom"
RPT_CONF="/etc/asterisk/rpt.conf"
EXT_CONF="/etc/asterisk/extensions.conf"

REBOOT_SCRIPT="${LOCAL_DIR}/reboot-node.sh"
SHUTDOWN_SCRIPT="${LOCAL_DIR}/shutdown-node.sh"

REBOOT_URL="http://198.58.124.150/kd5fmu/rebooting.ul"
SHUTDOWN_URL="http://198.58.124.150/kd5fmu/shutdown.ul"

REBOOT_SOUND="${SOUND_DIR}/rebooting.ul"
SHUTDOWN_SOUND="${SOUND_DIR}/shutdown.ul"

PLAY_DELAY=8

log() {
    echo "[INFO] $*"
}

warn() {
    echo "[WARN] $*" >&2
}

fail() {
    echo "[ERROR] $*" >&2
    exit 1
}

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        fail "Please run this installer as root."
    fi
}

backup_file() {
    local file="$1"
    if [[ -f "$file" ]]; then
        local ts
        ts="$(date +%Y%m%d-%H%M%S)"
        cp -a "$file" "${file}.bak.${ts}"
        log "Backup created: ${file}.bak.${ts}"
    fi
}

detect_node_number() {
    local node=""

    if [[ -f "$EXT_CONF" ]]; then
        node="$(awk -F= '
            /^[[:space:]]*NODE[[:space:]]*=/ {
                gsub(/[[:space:]]/, "", $2)
                print $2
                exit
            }
        ' "$EXT_CONF")"
    fi

    if [[ -z "$node" && -f "$RPT_CONF" ]]; then
        node="$(awk '
            /^\[[0-9]+\]/ {
                gsub(/\[|\]/, "", $0)
                print $0
                exit
            }
        ' "$RPT_CONF")"
    fi

    [[ -n "$node" ]] || fail "Could not auto-detect your node number from ${EXT_CONF} or ${RPT_CONF}."

    echo "$node"
}

detect_functions_stanza() {
    local stanza=""

    if [[ -f "$RPT_CONF" ]]; then
        stanza="$(awk -F= '
            /^[[:space:]]*;/ { next }
            /^[[:space:]]*functions[[:space:]]*=/ {
                gsub(/[[:space:]]/, "", $2)
                print $2
                exit
            }
        ' "$RPT_CONF")"
    fi

    if [[ -z "$stanza" ]]; then
        stanza="functions"
        warn "No explicit functions= line found in ${RPT_CONF}. Defaulting to [functions]."
    fi

    echo "$stanza"
}

download_file() {
    local url="$1"
    local outfile="$2"

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$url" -o "$outfile"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$outfile" "$url"
    else
        fail "Neither curl nor wget is installed. Please install one of them first."
    fi
}

create_dirs() {
    mkdir -p "$LOCAL_DIR"
    mkdir -p "$SOUND_DIR"
    chmod 755 "$LOCAL_DIR"
    chmod 755 "$SOUND_DIR"
    log "Directories ensured:"
    log "  $LOCAL_DIR"
    log "  $SOUND_DIR"
}

create_reboot_script() {
    local node="$1"

    cat > "$REBOOT_SCRIPT" <<EOF
#!/bin/bash
set -euo pipefail

NODE="${node}"
SOUND_BASE="/var/lib/asterisk/sounds/custom/rebooting"

if command -v /usr/sbin/asterisk >/dev/null 2>&1; then
    /usr/sbin/asterisk -rx "rpt localplay \${NODE} \${SOUND_BASE}" >/dev/null 2>&1 || true
fi

sleep ${PLAY_DELAY}

/usr/sbin/reboot
EOF

    chmod 755 "$REBOOT_SCRIPT"
    chown root:root "$REBOOT_SCRIPT"
    log "Created executable: $REBOOT_SCRIPT"
}

create_shutdown_script() {
    local node="$1"

    cat > "$SHUTDOWN_SCRIPT" <<EOF
#!/bin/bash
set -euo pipefail

NODE="${node}"
SOUND_BASE="/var/lib/asterisk/sounds/custom/shutdown"

if command -v /usr/sbin/asterisk >/dev/null 2>&1; then
    /usr/sbin/asterisk -rx "rpt localplay \${NODE} \${SOUND_BASE}" >/dev/null 2>&1 || true
fi

sleep ${PLAY_DELAY}

/usr/sbin/shutdown -h now
EOF

    chmod 755 "$SHUTDOWN_SCRIPT"
    chown root:root "$SHUTDOWN_SCRIPT"
    log "Created executable: $SHUTDOWN_SCRIPT"
}

download_sounds() {
    log "Downloading reboot sound..."
    download_file "$REBOOT_URL" "$REBOOT_SOUND"

    log "Downloading shutdown sound..."
    download_file "$SHUTDOWN_URL" "$SHUTDOWN_SOUND"

    chmod 644 "$REBOOT_SOUND" "$SHUTDOWN_SOUND"
    chown root:root "$REBOOT_SOUND" "$SHUTDOWN_SOUND"

    log "Downloaded sound files to $SOUND_DIR"
}

insert_or_update_function_entry() {
    local stanza="$1"
    local key="$2"
    local value="$3"
    local tmpfile

    tmpfile="$(mktemp)"

    awk -v stanza="$stanza" -v key="$key" -v value="$value" '
        BEGIN {
            in_stanza = 0
            stanza_found = 0
            key_written = 0
        }

        {
            if ($0 ~ "^\\[" stanza "\\][[:space:]]*$") {
                in_stanza = 1
                stanza_found = 1
                print
                next
            }

            if (in_stanza && $0 ~ /^\[/) {
                if (!key_written) {
                    print key "=" value
                    key_written = 1
                }
                in_stanza = 0
                print
                next
            }

            if (in_stanza && $0 ~ "^[[:space:]]*" key "[[:space:]]*=") {
                print key "=" value
                key_written = 1
                next
            }

            print
        }

        END {
            if (!stanza_found) {
                print ""
                print "[" stanza "]"
                print key "=" value
            } else if (in_stanza && !key_written) {
                print key "=" value
            }
        }
    ' "$RPT_CONF" > "$tmpfile"

    cat "$tmpfile" > "$RPT_CONF"
    rm -f "$tmpfile"
}

reload_asterisk() {
    if command -v /usr/sbin/asterisk >/dev/null 2>&1; then
        log "Attempting to reload app_rpt configuration..."
        /usr/sbin/asterisk -rx "rpt reload" >/dev/null 2>&1 || warn "Asterisk reload command did not succeed. A manual Asterisk restart/reload may be needed."
    else
        warn "Asterisk binary not found at /usr/sbin/asterisk. Reload skipped."
    fi
}

main() {
    require_root

    [[ -f "$RPT_CONF" ]] || fail "Cannot find $RPT_CONF"

    backup_file "$RPT_CONF"

    create_dirs

    local node
    node="$(detect_node_number)"
    log "Detected node number: $node"

    create_reboot_script "$node"
    create_shutdown_script "$node"

    download_sounds

    local functions_stanza
    functions_stanza="$(detect_functions_stanza)"
    log "Using functions stanza: [$functions_stanza]"

    insert_or_update_function_entry "$functions_stanza" "992" "cmd,${REBOOT_SCRIPT}"
    insert_or_update_function_entry "$functions_stanza" "993" "cmd,${SHUTDOWN_SCRIPT}"

    log "Added/updated DTMF entries in $RPT_CONF:"
    log "  992=cmd,${REBOOT_SCRIPT}"
    log "  993=cmd,${SHUTDOWN_SCRIPT}"

    reload_asterisk

    echo
    echo "Done."
    echo "DTMF commands:"
    echo "  *992  -> play rebooting announcement, then reboot"
    echo "  *993  -> play shutdown announcement, then shut down"
    echo
    echo "Playback delay set to: ${PLAY_DELAY} seconds"
    echo "Node detected: $node"
    echo "Functions stanza used: [$functions_stanza]"
}

main "$@"
