#!/bin/bash

set -euo pipefail

STATE_FILE="/tmp/dofus_window_index"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/dofus_accounts.conf"
DEFAULT_CONFIG_FILE="${SCRIPT_DIR}/dofus_accounts.conf.dist"
WINDOW_PATTERN="Dofus Retro"
DEFAULT_INITIATIVE=100
DEBUG="${DEBUG:-0}"

ACTIVE_ACCOUNTS=()
HISTORICAL_ACCOUNTS=()

debug_log() {
    if [[ "${DEBUG}" == "1" ]]; then
        echo "[DEBUG] $*"
    fi
}

die() {
    echo "$*" >&2
    exit 1
}

usage() {
    cat <<EOF
Usage:
  $0
  $0 --scan-config
  $0 --set-ini "<pseudo>" <initiative>
  $0 --edit-active
EOF
}

ensure_runtime_config() {
    if [[ -f "${CONFIG_FILE}" ]]; then
        return
    fi

    if [[ -f "${DEFAULT_CONFIG_FILE}" ]]; then
        CONFIG_FILE="${DEFAULT_CONFIG_FILE}"
        return
    fi

    die "Fichier de configuration introuvable : ${CONFIG_FILE}"
}

ensure_writable_config() {
    if [[ -f "${CONFIG_FILE}" ]]; then
        return
    fi

    : > "${CONFIG_FILE}"
}

require_commands() {
    local cmd=""

    for cmd in "$@"; do
        command -v "${cmd}" >/dev/null 2>&1 || die "Commande requise introuvable : ${cmd}"
    done
}

trim_leading_spaces() {
    local value="$1"
    echo "${value#"${value%%[![:space:]]*}"}"
}

parse_config_file() {
    local file="$1"
    local line=""
    local section=""
    local trimmed=""

    ACTIVE_ACCOUNTS=()
    HISTORICAL_ACCOUNTS=()

    while IFS= read -r line || [[ -n "${line}" ]]; do
        trimmed="$(trim_leading_spaces "${line}")"

        if [[ -z "${trimmed}" ]] || [[ "${trimmed}" == \#* ]]; then
            continue
        fi

        case "${trimmed}" in
            "[ACTIVE]")
                section="active"
                continue
                ;;
            "[HISTORICAL]")
                section="historical"
                continue
                ;;
        esac

        [[ "${trimmed}" == *:* ]] || continue

        case "${section}" in
            active)
                ACTIVE_ACCOUNTS+=("${trimmed}")
                ;;
            historical)
                HISTORICAL_ACCOUNTS+=("${trimmed}")
                ;;
        esac
    done < "${file}"
}

write_config_file() {
    local target_file="$1"

    {
        echo "# Format : pseudo:initiative"
        echo "# Sections supportees : [ACTIVE] et [HISTORICAL]"
        echo
        echo "[ACTIVE]"
        printf '%s\n' "${ACTIVE_ACCOUNTS[@]}"
        echo
        echo "[HISTORICAL]"
        printf '%s\n' "${HISTORICAL_ACCOUNTS[@]}"
    } > "${target_file}"
}

find_initiative_for_pseudo() {
    local pseudo="$1"
    local account=""

    for account in "${ACTIVE_ACCOUNTS[@]}" "${HISTORICAL_ACCOUNTS[@]}"; do
        if [[ "${account%%:*}" == "${pseudo}" ]]; then
            echo "${account##*:}"
            return 0
        fi
    done

    return 1
}

set_account_in_section() {
    local section_name="$1"
    local pseudo="$2"
    local initiative="$3"
    local -n section_ref="${section_name}"
    local index=0

    for index in "${!section_ref[@]}"; do
        if [[ "${section_ref[$index]%%:*}" == "${pseudo}" ]]; then
            section_ref[$index]="${pseudo}:${initiative}"
            return 0
        fi
    done

    return 1
}

append_unique_account() {
    local section_name="$1"
    local account="$2"
    local pseudo="${account%%:*}"
    local -n section_ref="${section_name}"
    local current=""

    for current in "${section_ref[@]}"; do
        if [[ "${current%%:*}" == "${pseudo}" ]]; then
            return 0
        fi
    done

    section_ref+=("${account}")
}

validate_initiative() {
    [[ "$1" =~ ^[0-9]+$ ]] || die "Initiative invalide : $1"
}

extract_window_title() {
    local line="$1"
    echo "${line}" | awk '{for (i = 4; i <= NF; i++) printf "%s%s", $i, (i < NF ? OFS : ORS)}'
}

extract_pseudo_from_window() {
    local line="$1"
    local title

    title="$(extract_window_title "${line}")"
    echo "${title%% - ${WINDOW_PATTERN}*}"
}

load_dofus_windows() {
    mapfile -t WINDOWS < <(wmctrl -l | grep "${WINDOW_PATTERN}" || true)
}

sync_audio_if_possible() {
    local ordered_window_ids=""
    local audio_window_id=""
    local win_id=""
    local cmd=""
    local -a window_ids=()

    [[ ${#ACTIVE_ACCOUNTS[@]} -gt 0 ]] || return 0

    for cmd in wmctrl xprop pactl pgrep; do
        if ! command -v "${cmd}" >/dev/null 2>&1; then
            debug_log "Synchro audio ignorée : commande introuvable (${cmd})."
            return 0
        fi
    done

    if ! ordered_window_ids="$(build_ordered_window_ids)"; then
        debug_log "Synchro audio ignorée : aucune fenêtre ${WINDOW_PATTERN} ouverte."
        return 0
    fi

    mapfile -t window_ids <<< "${ordered_window_ids}"
    [[ ${#window_ids[@]} -gt 0 ]] || return 0

    audio_window_id="${window_ids[0]}"
    debug_log "Fenetre audio ID: ${audio_window_id}"

    for win_id in "${window_ids[@]}"; do
        if [[ "${win_id}" == "${audio_window_id}" ]]; then
            set_window_mute "${win_id}" 0
        else
            set_window_mute "${win_id}" 1
        fi
    done
}

set_ini() {
    local pseudo="${1:-}"
    local initiative="${2:-}"

    [[ -n "${pseudo}" && -n "${initiative}" ]] || die "Usage: $0 --set-ini <pseudo> <initiative>"
    validate_initiative "${initiative}"

    ensure_writable_config
    parse_config_file "${CONFIG_FILE}"

    if ! set_account_in_section ACTIVE_ACCOUNTS "${pseudo}" "${initiative}"; then
        if ! set_account_in_section HISTORICAL_ACCOUNTS "${pseudo}" "${initiative}"; then
            ACTIVE_ACCOUNTS+=("${pseudo}:${initiative}")
        fi
    fi

    write_config_file "${CONFIG_FILE}"
    sync_audio_if_possible
    echo "Initiative mise a jour : ${pseudo}:${initiative}"
}

edit_active() {
    local account=""
    local pseudo=""
    local initiative=""
    local new_initiative=""
    local -a updated_active=()

    ensure_writable_config
    parse_config_file "${CONFIG_FILE}"

    [[ ${#ACTIVE_ACCOUNTS[@]} -gt 0 ]] || die "Aucun compte actif configure dans ${CONFIG_FILE}."

    echo "Comptes actifs :"
    for account in "${ACTIVE_ACCOUNTS[@]}"; do
        echo "  - ${account%%:*} : ${account##*:}"
    done
    echo

    for account in "${ACTIVE_ACCOUNTS[@]}"; do
        pseudo="${account%%:*}"
        initiative="${account##*:}"
        printf 'Nouvelle initiative pour %s [%s] : ' "${pseudo}" "${initiative}"
        read -r new_initiative

        if [[ -z "${new_initiative}" ]]; then
            new_initiative="${initiative}"
        fi

        validate_initiative "${new_initiative}"
        updated_active+=("${pseudo}:${new_initiative}")
    done

    ACTIVE_ACCOUNTS=("${updated_active[@]}")
    write_config_file "${CONFIG_FILE}"
    sync_audio_if_possible
    echo "Comptes actifs mis a jour : ${CONFIG_FILE}"
}

scan_config() {
    local line=""
    local pseudo=""
    local initiative=""
    local account=""
    local -a new_active=()
    local -a new_historical=()

    require_commands wmctrl
    ensure_writable_config
    parse_config_file "${CONFIG_FILE}"
    load_dofus_windows
    [[ ${#WINDOWS[@]} -gt 0 ]] || die "Aucune fenêtre ${WINDOW_PATTERN} trouvée."

    for line in "${WINDOWS[@]}"; do
        pseudo="$(extract_pseudo_from_window "${line}")"
        [[ -n "${pseudo}" ]] || continue

        initiative="$(find_initiative_for_pseudo "${pseudo}" || true)"
        if [[ -z "${initiative}" ]]; then
            initiative="${DEFAULT_INITIATIVE}"
        fi

        append_unique_account new_active "${pseudo}:${initiative}"
    done

    for account in "${ACTIVE_ACCOUNTS[@]}" "${HISTORICAL_ACCOUNTS[@]}"; do
        pseudo="${account%%:*}"
        if printf '%s\n' "${new_active[@]}" | awk -F ':' -v target="${pseudo}" '$1 == target { found = 1 } END { exit(found ? 0 : 1) }'
        then
            continue
        fi
        append_unique_account new_historical "${account}"
    done

    ACTIVE_ACCOUNTS=("${new_active[@]}")
    HISTORICAL_ACCOUNTS=("${new_historical[@]}")
    write_config_file "${CONFIG_FILE}"
    sync_audio_if_possible

    echo "${#ACTIVE_ACCOUNTS[@]} fenêtre(s) trouvée(s). Configuration mise a jour : ${CONFIG_FILE}"
}

collect_process_tree() {
    local root_pid="$1"
    local current_pid=""
    local child_pid=""
    local -a queue=("${root_pid}")
    local -a descendants=()

    while [[ ${#queue[@]} -gt 0 ]]; do
        current_pid="${queue[0]}"
        queue=("${queue[@]:1}")
        descendants+=("${current_pid}")

        while read -r child_pid; do
            [[ -n "${child_pid}" ]] && queue+=("${child_pid}")
        done < <(pgrep -P "${current_pid}" || true)
    done

    printf '%s\n' "${descendants[@]}"
}

get_sink_inputs_for_window() {
    local win_id="$1"
    local pid=""
    local -a process_tree=()

    pid="$(xprop -id "${win_id}" | awk '/_NET_WM_PID/ {print $3}')"
    [[ -n "${pid}" ]] || return 0

    mapfile -t process_tree < <(collect_process_tree "${pid}")
    debug_log "Fenetre ${win_id} -> PIDs ${process_tree[*]}"

    LANG=C pactl list sink-inputs | awk -v pids="${process_tree[*]}" '
    BEGIN {
        split(pids, pid_array, " ")
        for (i in pid_array) {
            allowed[pid_array[i]] = 1
        }
    }
    /^Sink Input #/ {
        input_id = $3
        sub(/^#/, "", input_id)
        match_pid = 0
    }
    /application.process.id = "/ {
        split($0, parts, "\"")
        if (parts[2] in allowed) {
            match_pid = 1
        }
    }
    /^$/ {
        if (input_id != "" && match_pid) {
            print input_id
        }
        input_id = ""
        match_pid = 0
    }
    END {
        if (input_id != "" && match_pid) {
            print input_id
        }
    }'
}

set_window_mute() {
    local win_id="$1"
    local mute_value="$2"
    local input_id=""

    while read -r input_id; do
        [[ -n "${input_id}" ]] || continue
        pactl set-sink-input-mute "${input_id}" "${mute_value}"
        debug_log "Fenetre ${win_id} -> sink ${input_id} mute=${mute_value}"
    done < <(get_sink_inputs_for_window "${win_id}")
}

build_ordered_window_ids() {
    local account=""
    local pseudo=""
    local line=""
    local -a sorted_accounts=()
    local -a ordered_window_ids=()
    local -A window_id_by_pseudo=()

    mapfile -t sorted_accounts < <(printf '%s\n' "${ACTIVE_ACCOUNTS[@]}" | sort -t ':' -k2,2nr)
    load_dofus_windows
    [[ ${#WINDOWS[@]} -gt 0 ]] || return 1

    for line in "${WINDOWS[@]}"; do
        pseudo="$(extract_pseudo_from_window "${line}")"
        [[ -n "${pseudo}" ]] || continue
        [[ -n "${window_id_by_pseudo["${pseudo}"]:-}" ]] && continue
        window_id_by_pseudo["${pseudo}"]="${line%% *}"
    done

    for account in "${sorted_accounts[@]}"; do
        pseudo="${account%%:*}"
        [[ -n "${window_id_by_pseudo["${pseudo}"]:-}" ]] || continue
        ordered_window_ids+=("${window_id_by_pseudo["${pseudo}"]}")
        debug_log "Pseudo ${pseudo} -> ${window_id_by_pseudo["${pseudo}"]}"
    done

    [[ ${#ordered_window_ids[@]} -gt 0 ]] || return 1
    printf '%s\n' "${ordered_window_ids[@]}"
}

run_switch() {
    local index=0
    local ordered_window_ids=""
    local active_window_id=""
    local previous_index=""

    require_commands wmctrl
    ensure_runtime_config
    parse_config_file "${CONFIG_FILE}"
    [[ ${#ACTIVE_ACCOUNTS[@]} -gt 0 ]] || die "Aucun compte actif configure dans ${CONFIG_FILE}."

    ordered_window_ids="$(build_ordered_window_ids)" || die "Aucune fenêtre configurée trouvée pour ${WINDOW_PATTERN}."
    mapfile -t WINDOW_IDS <<< "${ordered_window_ids}"

    if [[ -f "${STATE_FILE}" ]] && read -r previous_index < "${STATE_FILE}" && [[ "${previous_index}" =~ ^[0-9]+$ ]]; then
        index=$(( (previous_index + 1) % ${#WINDOW_IDS[@]} ))
    fi

    active_window_id="${WINDOW_IDS[$index]}"
    debug_log "Fenetre active ID: ${active_window_id}"

    wmctrl -ia "${active_window_id}"
    echo "${index}" > "${STATE_FILE}"
}

main() {
    case "${1:-}" in
        "")
            run_switch
            ;;
        --scan-config)
            scan_config
            ;;
        --set-ini)
            set_ini "${2:-}" "${3:-}"
            ;;
        --edit-active)
            edit_active
            ;;
        -h|--help)
            usage
            ;;
        *)
            usage
            exit 1
            ;;
    esac
}

main "$@"
