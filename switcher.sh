#!/bin/bash

set -euo pipefail

STATE_FILE="/tmp/dofus_window_index"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/dofus_accounts.conf"
DEFAULT_CONFIG_FILE="${SCRIPT_DIR}/dofus_accounts.conf.dist"
WINDOW_PATTERN="Dofus Retro"
DEFAULT_INITIATIVE=100
DEBUG="${DEBUG:-0}"
NOTIFICATION_APP_PATTERN="${NOTIFICATION_APP_PATTERN:-}"
NOTIFICATION_DEDUP_SECONDS="${NOTIFICATION_DEDUP_SECONDS:-3}"

ACTIVE_ACCOUNTS=()
HISTORICAL_ACCOUNTS=()
LAST_NOTIFICATION_SIGNATURE=""
LAST_NOTIFICATION_TS=0

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
  $0 --listen-notifications
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

normalize_notification_text() {
    local value="$1"

    value="$(printf '%s\n' "${value}" | sed -E "s/<[^>]*>/ /g; s/&nbsp;/ /g; s/&quot;/\"/g; s/&apos;/'/g; s/&#39;/'/g; s/&amp;/\\&/g; s/&lt;/</g; s/&gt;/>/g")"
    value="$(printf '%s\n' "${value}" | tr '\r\n\t' '   ' | awk '{$1=$1; print}')"

    printf '%s\n' "${value}"
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

validate_notification_settings() {
    [[ "${NOTIFICATION_DEDUP_SECONDS}" =~ ^[0-9]+$ ]] || die "NOTIFICATION_DEDUP_SECONDS invalide : ${NOTIFICATION_DEDUP_SECONDS}"
}

extract_window_title() {
    local line="$1"
    echo "${line}" | awk '{for (i = 4; i <= NF; i++) printf "%s%s", $i, (i < NF ? OFS : ORS)}'
}

is_game_window_title() {
    local title="$1"

    [[ "${title}" == *" - ${WINDOW_PATTERN}"* ]]
}

extract_pseudo_from_window() {
    local line="$1"
    local title

    title="$(extract_window_title "${line}")"

    if ! is_game_window_title "${title}"; then
        echo ""
        return 0
    fi

    echo "${title%% - ${WINDOW_PATTERN}*}"
}

load_dofus_windows() {
    mapfile -t WINDOWS < <(wmctrl -l | grep "${WINDOW_PATTERN}" || true)
}

normalize_window_id() {
    local window_id="$1"

    [[ "${window_id}" =~ ^0x[0-9a-fA-F]+$ ]] || return 1
    printf '0x%x\n' "$((window_id))"
}

get_active_window_id() {
    local active_window_id=""

    active_window_id="$(xprop -root _NET_ACTIVE_WINDOW 2>/dev/null | awk '/_NET_ACTIVE_WINDOW/ {print $NF}')"
    [[ -n "${active_window_id}" ]] || return 1
    [[ "${active_window_id}" != "0x0" ]] || return 1

    normalize_window_id "${active_window_id}"
}

focus_window() {
    local target_window_id="$1"

    wmctrl -ia "${target_window_id}"
}

build_open_window_title_map() {
    local title_map_name="$1"
    local line=""
    local title=""
    local window_id=""
    local -n title_map_ref="${title_map_name}"

    title_map_ref=()
    load_dofus_windows

    for line in "${WINDOWS[@]}"; do
        title="$(extract_window_title "${line}")"
        window_id="${line%% *}"

        if ! is_game_window_title "${title}"; then
            continue
        fi

        if [[ -n "${title}" && -z "${title_map_ref["${title}"]:-}" ]]; then
            title_map_ref["${title}"]="${window_id}"
        fi
    done

    [[ ${#title_map_ref[@]} -gt 0 ]]
}

extract_dbus_string() {
    local line="$1"

    if [[ "${line}" =~ ^[[:space:]]*string\ \"(.*)\"$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
        return 0
    fi

    return 1
}

is_notify_call_header() {
    local line="$1"

    if [[ "${line}" == method\ call*member=Notify*interface=org.freedesktop.Notifications* ]] \
        || [[ "${line}" == method\ call*interface=org.freedesktop.Notifications*member=Notify* ]]; then
        return 0
    fi

    return 1
}

is_dbus_message_header() {
    local line="$1"

    [[ "${line}" == method\ call* ]] \
        || [[ "${line}" == method\ return* ]] \
        || [[ "${line}" == signal* ]] \
        || [[ "${line}" == error* ]]
}

process_dbus_notification_stream() {
    local callback_name="$1"
    local line=""
    local trimmed=""
    local in_block=0
    local parse_state=0
    local app_name=""
    local app_icon=""
    local summary=""
    local body=""
    local string_value=""
    local is_message_header=0
    local pending_field=""
    local pending_string_value=""

    finalize_current_block() {
        [[ "${in_block}" == "1" ]] || return 0

        if [[ -n "${app_name}${summary}${body}" ]]; then
            "${callback_name}" "${app_name}" "${summary}" "${body}"
        fi

        in_block=0
        parse_state=0
        app_name=""
        app_icon=""
        summary=""
        body=""
        pending_field=""
        pending_string_value=""
    }

    while IFS= read -r line || [[ -n "${line}" ]]; do
        is_message_header=0
        if is_dbus_message_header "${line}"; then
            is_message_header=1
        fi

        if [[ "${in_block}" == "1" && "${is_message_header}" == "1" ]]; then
            finalize_current_block
        fi

        if is_notify_call_header "${line}"; then
            in_block=1
            parse_state=0
            app_name=""
            app_icon=""
            summary=""
            body=""
            pending_field=""
            pending_string_value=""
            continue
        fi

        if [[ "${is_message_header}" == "1" ]]; then
            continue
        fi

        [[ "${in_block}" == "1" ]] || continue

        if [[ -n "${pending_field}" ]]; then
            if [[ "${line}" == *\" ]]; then
                pending_string_value+=$'\n'"${line%\"}"

                case "${pending_field}" in
                    app_name)
                        app_name="${pending_string_value}"
                        parse_state=1
                        ;;
                    app_icon)
                        app_icon="${pending_string_value}"
                        parse_state=3
                        ;;
                    summary)
                        summary="${pending_string_value}"
                        ;;
                    body)
                        body="${pending_string_value}"
                        ;;
                esac

                if [[ "${pending_field}" == "summary" ]]; then
                    parse_state=4
                elif [[ "${pending_field}" == "body" ]]; then
                    parse_state=5
                fi

                pending_field=""
                pending_string_value=""
            else
                pending_string_value+=$'\n'"${line}"
            fi
            continue
        fi

        if [[ -z "${line}" ]]; then
            finalize_current_block
            continue
        fi

        trimmed="$(trim_leading_spaces "${line}")"

        case "${parse_state}" in
            0)
                if string_value="$(extract_dbus_string "${line}")"; then
                    app_name="${string_value}"
                    parse_state=1
                elif [[ "${line}" =~ ^[[:space:]]*string\ \"(.*)$ ]]; then
                    pending_field="app_name"
                    pending_string_value="${BASH_REMATCH[1]}"
                fi
                ;;
            1)
                if [[ "${trimmed}" == uint32\ * ]]; then
                    parse_state=2
                fi
                ;;
            2)
                if string_value="$(extract_dbus_string "${line}")"; then
                    app_icon="${string_value}"
                    parse_state=3
                elif [[ "${line}" =~ ^[[:space:]]*string\ \"(.*)$ ]]; then
                    pending_field="app_icon"
                    pending_string_value="${BASH_REMATCH[1]}"
                fi
                ;;
            3)
                if string_value="$(extract_dbus_string "${line}")"; then
                    summary="${string_value}"
                    parse_state=4
                elif [[ "${line}" =~ ^[[:space:]]*string\ \"(.*)$ ]]; then
                    pending_field="summary"
                    pending_string_value="${BASH_REMATCH[1]}"
                fi
                ;;
            4)
                if string_value="$(extract_dbus_string "${line}")"; then
                    body="${string_value}"
                    parse_state=5
                elif [[ "${line}" =~ ^[[:space:]]*string\ \"(.*)$ ]]; then
                    pending_field="body"
                    pending_string_value="${BASH_REMATCH[1]}"
                fi
                ;;
        esac

        if (( parse_state >= 5 )) && [[ "${trimmed}" == int32\ * ]]; then
            finalize_current_block
        fi
    done

    if [[ "${in_block}" == "1" ]]; then
        finalize_current_block
    fi
}

notification_matches_filter() {
    local app_name="$1"
    local summary="$2"
    local body="$3"
    local pattern_lower="${NOTIFICATION_APP_PATTERN,,}"
    local haystack_lower=""

    [[ -z "${pattern_lower}" ]] && return 0

    haystack_lower="${app_name,,} ${summary,,} ${body,,}"
    [[ "${haystack_lower}" == *"${pattern_lower}"* ]]
}

find_matching_window_title_from_summary() {
    local summary="$1"
    local map_name="$2"
    local summary_normalized=""
    local summary_lower=""
    local title=""
    local title_normalized=""
    local title_lower=""
    local -n map_ref="${map_name}"

    summary_normalized="$(normalize_notification_text "${summary}")"
    summary_lower="${summary_normalized,,}"

    [[ -n "${summary_lower}" ]] || return 1

    for title in "${!map_ref[@]}"; do
        title_normalized="$(normalize_notification_text "${title}")"
        title_lower="${title_normalized,,}"

        if [[ "${summary_lower}" == "${title_lower}" ]]; then
            printf '%s\n' "${title}"
            return 0
        fi
    done

    return 1
}

select_notification_summary_for_matching() {
    local summary="$1"
    local body="$2"
    local normalized_summary=""
    local normalized_body=""

    normalized_summary="$(normalize_notification_text "${summary}")"
    normalized_body="$(normalize_notification_text "${body}")"

    if [[ "${normalized_summary}" == "${WINDOW_PATTERN}" ]] && is_game_window_title "${normalized_body}"; then
        printf '%s\n' "${normalized_body}"
        return 0
    fi

    printf '%s\n' "${normalized_summary}"
}

remember_notification_signature() {
    local signature="$1"
    local now_ts="$2"

    LAST_NOTIFICATION_SIGNATURE="${signature}"
    LAST_NOTIFICATION_TS="${now_ts}"
}

handle_dbus_notification() {
    local app_name="$1"
    local summary="$2"
    local body="$3"
    local matched_title=""
    local matching_summary=""
    local active_window_id=""
    local target_window_id=""
    local normalized_target_window_id=""
    local notification_signature=""
    local now_ts=0
    local -A window_id_by_title=()

    debug_log "Notification recue : app='${app_name}' summary='${summary}' body='${body}'"
    matching_summary="$(select_notification_summary_for_matching "${summary}" "${body}")"

    if ! notification_matches_filter "${app_name}" "${summary}" "${body}"; then
        debug_log "Notification ignorée : filtre source non correspondant."
        return 0
    fi

    if ! build_open_window_title_map window_id_by_title; then
        debug_log "Notification ignorée : aucune fenêtre ${WINDOW_PATTERN} ouverte."
        return 0
    fi

    matched_title="$(find_matching_window_title_from_summary "${matching_summary}" window_id_by_title || true)"
    if [[ -z "${matched_title}" ]]; then
        debug_log "Notification ignorée : aucun titre exact reconnu depuis le summary."
        return 0
    fi

    target_window_id="${window_id_by_title["${matched_title}"]}"
    notification_signature="${matched_title}|${matching_summary}"
    debug_log "Notification corrélée par summary/titre : ${matched_title}"

    normalized_target_window_id="$(normalize_window_id "${target_window_id}")" || normalized_target_window_id="${target_window_id}"
    now_ts="$(date +%s)"

    if [[ "${notification_signature}" == "${LAST_NOTIFICATION_SIGNATURE}" ]] \
        && (( now_ts - LAST_NOTIFICATION_TS < NOTIFICATION_DEDUP_SECONDS )); then
        debug_log "Notification ignorée : doublon recent."
        return 0
    fi

    active_window_id="$(get_active_window_id || true)"
    if [[ -n "${active_window_id}" && "${active_window_id}" == "${normalized_target_window_id}" ]]; then
        remember_notification_signature "${notification_signature}" "${now_ts}"
        debug_log "Notification ignorée : fenêtre déjà active."
        return 0
    fi

    if ! focus_window "${target_window_id}"; then
        debug_log "Impossible de focus la fenêtre ${target_window_id}."
        return 0
    fi

    remember_notification_signature "${notification_signature}" "${now_ts}"
    debug_log "Fenêtre focusée via notification -> ${target_window_id}"
}

listen_notifications() {
    require_commands dbus-monitor wmctrl xprop stdbuf
    validate_notification_settings

    debug_log "Ecoute des notifications Dofus sur DBus..."

    process_dbus_notification_stream handle_dbus_notification < <(
        stdbuf -oL -eL dbus-monitor --session --monitor \
            "type='method_call',interface='org.freedesktop.Notifications',member='Notify'"
    )
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
        --listen-notifications)
            listen_notifications
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

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
