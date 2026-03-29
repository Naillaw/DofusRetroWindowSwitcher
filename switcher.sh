#!/bin/bash

######################################
#    Fait par Vieil-Ours             #
#                                    #
#    Paquet necéssaires :            #
#    wmctrl                          #
#    xprop                           #
#    pactl                           #
######################################

# STATE_FILE type string : Fichier temporaire pour mémoriser la dernière fenêtre activée
# SCRIPT_DIR type string : Dossier contenant le script
# CONFIG_FILE type string : Fichier contenant les couples pseudo:initiative
# DEFAULT_CONFIG_FILE type string : Fichier modèle utilisé si la config locale est absente
# ACTIVE_ACCOUNTS type array de string : Couples pseudo:initiative actifs
# HISTORICAL_ACCOUNTS type array de string : Couples pseudo:initiative historiques
# WINDOWS type array de string : Liste des fenêtres Dofus Retro
# ORDERED_WINDOWS type array de string : Fenêtres configurées triées par initiative décroissante
# WINDOW_IDS type array de string : ID des fenêtres Dofus Retro triées
# ACTIVE_WINDOW_ID type string : ID de la fenêtre qui doit passer au premier plan
# AUDIO_WINDOW_ID type string : ID de la fenêtre qui garde toujours le son
# DEBUG type string : Active l'affichage de debug si vaut 1
#
STATE_FILE="/tmp/dofus_window_index"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/dofus_accounts.conf"
DEFAULT_CONFIG_FILE="${SCRIPT_DIR}/dofus_accounts.conf.dist"
WINDOW_PATTERN="Dofus Retro"
DEBUG="${DEBUG:-0}"

debug_log() {
    if [[ "${DEBUG}" == "1" ]]
    then
        echo "[DEBUG] $*"
    fi
}

print_table() {
    local title="$1"
    shift
    local rows=("$@")

    echo "${title}"
    for row in "${rows[@]}"
    do
        IFS='|' read -r col1 col2 col3 <<< "${row}"
        printf '%-24s | %-10s | %s\n' "${col1}" "${col2}" "${col3}"
    done
    echo
}

parse_config_file() {
    local file="$1"
    local line=""
    local section=""
    local trimmed=""

    ACTIVE_ACCOUNTS=()
    HISTORICAL_ACCOUNTS=()

    while IFS= read -r line || [[ -n "${line}" ]]
    do
        trimmed="${line#"${line%%[![:space:]]*}"}"

        if [[ -z "${trimmed}" ]] || [[ "${trimmed}" == \#* ]]
        then
            continue
        fi

        if [[ "${trimmed}" == "[ACTIVE]" ]]
        then
            section="active"
            continue
        fi

        if [[ "${trimmed}" == "[HISTORICAL]" ]]
        then
            section="historical"
            continue
        fi

        if [[ "${trimmed}" != *:* ]]
        then
            continue
        fi

        case "${section}" in
            active)
                ACTIVE_ACCOUNTS+=("${trimmed}")
                ;;
            historical)
                HISTORICAL_ACCOUNTS+=("${trimmed}")
                ;;
            *)
                ACTIVE_ACCOUNTS+=("${trimmed}")
                ;;
        esac
    done < "${file}"
}

find_initiative_for_pseudo() {
    local pseudo="$1"
    local account=""

    for account in "${ACTIVE_ACCOUNTS[@]}" "${HISTORICAL_ACCOUNTS[@]}"
    do
        if [[ "${account%%:*}" == "${pseudo}" ]]
        then
            echo "${account##*:}"
            return 0
        fi
    done

    return 1
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

set_ini() {
    local pseudo="$1"
    local initiative="$2"
    local updated=0
    local index=0
    local account=""

    if [[ -z "${pseudo}" ]] || [[ -z "${initiative}" ]]
    then
        echo "Usage: $0 --set-ini <pseudo> <initiative>"
        exit 1
    fi

    if [[ ! "${initiative}" =~ ^[0-9]+$ ]]
    then
        echo "Initiative invalide : ${initiative}"
        exit 1
    fi

    parse_config_file "${CONFIG_FILE}"

    for index in "${!ACTIVE_ACCOUNTS[@]}"
    do
        account="${ACTIVE_ACCOUNTS[$index]}"
        if [[ "${account%%:*}" == "${pseudo}" ]]
        then
            ACTIVE_ACCOUNTS[$index]="${pseudo}:${initiative}"
            updated=1
            break
        fi
    done

    if [[ "${updated}" == "0" ]]
    then
        for index in "${!HISTORICAL_ACCOUNTS[@]}"
        do
            account="${HISTORICAL_ACCOUNTS[$index]}"
            if [[ "${account%%:*}" == "${pseudo}" ]]
            then
                HISTORICAL_ACCOUNTS[$index]="${pseudo}:${initiative}"
                updated=1
                break
            fi
        done
    fi

    if [[ "${updated}" == "0" ]]
    then
        ACTIVE_ACCOUNTS+=("${pseudo}:${initiative}")
    fi

    write_config_file "${CONFIG_FILE}"
    echo "Initiative mise a jour : ${pseudo}:${initiative}"
}

edit_active() {
    local account=""
    local pseudo=""
    local initiative=""
    local new_initiative=""
    local -a updated_active_accounts=()
    local -a active_rows=()

    parse_config_file "${CONFIG_FILE}"

    if [[ ${#ACTIVE_ACCOUNTS[@]} -eq 0 ]]
    then
        echo "Aucun compte actif configure dans ${CONFIG_FILE}."
        exit 1
    fi

    for account in "${ACTIVE_ACCOUNTS[@]}"
    do
        active_rows+=("${account%%:*}|${account##*:}|courant")
    done

    print_table "Comptes actifs" \
        "Pseudo|Initiative|Edition" \
        "${active_rows[@]}"

    for account in "${ACTIVE_ACCOUNTS[@]}"
    do
        pseudo="${account%%:*}"
        initiative="${account##*:}"
        printf 'Nouvelle initiative pour %s [%s] : ' "${pseudo}" "${initiative}"
        read -r new_initiative

        if [[ -z "${new_initiative}" ]]
        then
            new_initiative="${initiative}"
        fi

        if [[ ! "${new_initiative}" =~ ^[0-9]+$ ]]
        then
            echo "Initiative invalide pour ${pseudo} : ${new_initiative}"
            exit 1
        fi

        updated_active_accounts+=("${pseudo}:${new_initiative}")
    done

    ACTIVE_ACCOUNTS=("${updated_active_accounts[@]}")
    write_config_file "${CONFIG_FILE}"
    echo "Comptes actifs mis a jour : ${CONFIG_FILE}"
}

extract_window_title() {
    local line="$1"

    echo "${line}" | awk '{for (i = 4; i <= NF; i++) printf "%s%s", $i, (i < NF ? OFS : ORS)}'
}

extract_pseudo_from_window() {
    local line="$1"
    local title=""

    title=$(extract_window_title "${line}")
    echo "${title%% - ${WINDOW_PATTERN}*}"
}

scan_config() {
    local target_file="$1"
    local line=""
    local pseudo=""
    local initiative=""
    local next_initiative=100
    local -a scan_windows=()
    local -a active_rows=()
    local -a scanned_rows=()
    local -a new_active_accounts=()
    local -a new_historical_accounts=()
    local account=""

    if [[ -f "${target_file}" ]]
    then
        parse_config_file "${target_file}"
        for account in "${ACTIVE_ACCOUNTS[@]}"
        do
            active_rows+=("${account%%:*}|${account##*:}|actif")
        done
        for account in "${HISTORICAL_ACCOUNTS[@]}"
        do
            active_rows+=("${account%%:*}|${account##*:}|historique")
        done
    fi

    mapfile -t scan_windows < <(wmctrl -l | grep "${WINDOW_PATTERN}")

    if [[ ${#scan_windows[@]} -eq 0 ]]
    then
        echo "Aucune fenêtre ${WINDOW_PATTERN} trouvée."
        exit 1
    fi

    for line in "${scan_windows[@]}"
    do
        pseudo=$(extract_pseudo_from_window "${line}")

        if [[ -z "${pseudo}" ]]
        then
            continue
        fi

        initiative="$(find_initiative_for_pseudo "${pseudo}" || true)"

        if [[ -z "${initiative}" ]]
        then
            initiative="${next_initiative}"
            next_initiative=$((next_initiative - 10))
        fi

        new_active_accounts+=("${pseudo}:${initiative}")
        scanned_rows+=("${pseudo}|${initiative}|$(extract_window_title "${line}")")
    done

    for account in "${ACTIVE_ACCOUNTS[@]}" "${HISTORICAL_ACCOUNTS[@]}"
    do
        pseudo="${account%%:*}"

        if printf '%s\n' "${new_active_accounts[@]}" | grep -Fqx "${account}"
        then
            continue
        fi

        if printf '%s\n' "${new_active_accounts[@]}" | awk -F ':' -v target="${pseudo}" '$1 == target { found = 1 } END { exit(found ? 0 : 1) }'
        then
            continue
        fi

        new_historical_accounts+=("${account}")
    done

    {
        echo "# Format : pseudo:initiative"
        echo "# Sections supportees : [ACTIVE] et [HISTORICAL]"
        echo
        echo "[ACTIVE]"
        printf '%s\n' "${new_active_accounts[@]}"
        echo
        echo "[HISTORICAL]"
        printf '%s\n' "${new_historical_accounts[@]}"
    } > "${target_file}"

    if [[ ${#active_rows[@]} -gt 0 ]]
    then
        print_table "Comptes actifs" \
            "Pseudo|Initiative|Source" \
            "${active_rows[@]}"
    fi

    print_table "Fenetres scannees" \
        "Pseudo|Initiative|Fenetre" \
        "${scanned_rows[@]}"

    echo "Configuration mise a jour : ${target_file}"
}

collect_process_tree() {
    local root_pid="$1"
    local current_pid=""
    local child_pid=""
    local -a queue=()
    local -a descendants=()

    queue=("${root_pid}")

    while [[ ${#queue[@]} -gt 0 ]]
    do
        current_pid="${queue[0]}"
        queue=("${queue[@]:1}")
        descendants+=("${current_pid}")

        while read -r child_pid
        do
            if [[ -n "${child_pid}" ]]
            then
                queue+=("${child_pid}")
            fi
        done < <(pgrep -P "${current_pid}")
    done

    printf '%s\n' "${descendants[@]}"
}

get_sink_inputs_for_window() {
    local win_id="$1"
    local pid=""
    local -a window_pids=()

    pid=$(xprop -id "${win_id}" | grep "_NET_WM_PID" | awk '{print $3}')
    debug_log "Fenetre ${win_id} -> PID ${pid}"

    if [[ -z "${pid}" ]]
    then
        return
    fi

    mapfile -t window_pids < <(collect_process_tree "${pid}")
    debug_log "Fenetre ${win_id} -> arbre PID: ${window_pids[*]}"

    LANG=C pactl list sink-inputs | \
    awk -v pids="${window_pids[*]}" '
    BEGIN {
        split(pids, pid_array, " ")
        for (i in pid_array) {
            allowed_pids[pid_array[i]] = 1
        }
    }
    /^Sink Input #/ {
        input_id = $3
        sub(/^#/, "", input_id)
        matches_pid = 0
    }
    /application.process.id = "/ {
        split($0, parts, "\"")
        process_id = parts[2]
        if (process_id in allowed_pids) {
            matches_pid = 1
        }
    }
    /^$/ {
        if (input_id != "" && matches_pid) {
            print input_id
        }
        input_id = ""
        matches_pid = 0
    }
    END {
        if (input_id != "" && matches_pid) {
            print input_id
        }
    }'
}

set_window_mute() {
    local win_id="$1"
    local mute_value="$2"
    local -a input_ids=()

    mapfile -t input_ids < <(get_sink_inputs_for_window "${win_id}")
    debug_log "Fenetre ${win_id} -> sink inputs: ${input_ids[*]}"

    for input_id in "${input_ids[@]}"
    do
        pactl set-sink-input-mute "${input_id}" "${mute_value}"
        debug_log "Mute ${mute_value} applique a sink input ${input_id}"
    done
}

if [[ "${1:-}" == "--scan-config" ]]
then
    scan_config "${CONFIG_FILE}"
    exit 0
fi

if [[ ! -f "${CONFIG_FILE}" ]]
then
    if [[ -f "${DEFAULT_CONFIG_FILE}" ]]
    then
        CONFIG_FILE="${DEFAULT_CONFIG_FILE}"
    else
        echo "Fichier de configuration introuvable : ${CONFIG_FILE}"
        exit 1
    fi
fi

if [[ "${1:-}" == "--set-ini" ]]
then
    set_ini "${2:-}" "${3:-}"
    exit 0
fi

if [[ "${1:-}" == "--edit-active" ]]
then
    edit_active
    exit 0
fi

parse_config_file "${CONFIG_FILE}"

if [[ ${#ACTIVE_ACCOUNTS[@]} -eq 0 ]]
then
    echo "Aucun compte actif configure dans ${CONFIG_FILE}."
    exit 1
fi

mapfile -t WINDOWS < <(wmctrl -l | grep "${WINDOW_PATTERN}")
debug_log "Fenetres detectees: ${#WINDOWS[@]}"

if [[ ${#WINDOWS[@]} -eq 0 ]]
then
    echo "Aucune fenêtre ${WINDOW_PATTERN} trouvée."
    exit 1
fi

mapfile -t SORTED_CONFIG < <(printf '%s\n' "${ACTIVE_ACCOUNTS[@]}" | sort -t ':' -k2,2nr)

ORDERED_WINDOWS=()
for ACCOUNT in "${SORTED_CONFIG[@]}"
do
    PSEUDO=${ACCOUNT%%:*}
    MATCHING_WINDOW=""

    for LINE in "${WINDOWS[@]}"
    do
        if [[ "${LINE}" == *"${PSEUDO} - ${WINDOW_PATTERN}"* ]]
        then
            MATCHING_WINDOW="${LINE}"
            break
        fi
    done

    if [[ -n "${MATCHING_WINDOW}" ]]
    then
        ORDERED_WINDOWS+=("${MATCHING_WINDOW}")
        debug_log "Pseudo ${PSEUDO} -> ${MATCHING_WINDOW}"
    else
        debug_log "Pseudo ${PSEUDO} -> aucune fenetre"
    fi
done

if [[ ${#ORDERED_WINDOWS[@]} -eq 0 ]]
then
    echo "Aucune fenêtre configurée trouvée pour ${WINDOW_PATTERN}."
    exit 1
fi

WINDOW_IDS=()
for LINE in "${ORDERED_WINDOWS[@]}"
do
    WINDOW_IDS+=("$(echo "${LINE}" | awk '{print $1}')")
done

# Lire l’index précédent ou démarrer à 0
if [[ -f "${STATE_FILE}" ]]
then
    INDEX=$(cat "${STATE_FILE}")
    INDEX=$(( (INDEX + 1) % ${#WINDOW_IDS[@]} ))
else
    INDEX=0
fi

ACTIVE_WINDOW_ID="${WINDOW_IDS[$INDEX]}"
AUDIO_WINDOW_ID="${WINDOW_IDS[0]}"
debug_log "Index actif: ${INDEX}"
debug_log "Fenetre active ID: ${ACTIVE_WINDOW_ID}"
debug_log "Fenetre audio ID: ${AUDIO_WINDOW_ID}"

for WIN_ID in "${WINDOW_IDS[@]}"
do
    if [[ "${WIN_ID}" == "${AUDIO_WINDOW_ID}" ]]
    then
        set_window_mute "${WIN_ID}" 0
    else
        set_window_mute "${WIN_ID}" 1
    fi
done

# Activer la fenêtre suivante
wmctrl -ia "${ACTIVE_WINDOW_ID}"

# Sauvegarder l’index sur /tmp
echo "${INDEX}" > "${STATE_FILE}"
