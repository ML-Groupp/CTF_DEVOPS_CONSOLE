#!/usr/bin/env bash
# A/D DevOps console — pure bash version (без Python).
#
# Меню:
#   1 состояние сервера
#   2 последний вывод (tail логов)
#   3 список бэкапов
#   4 бэкап всех сервисов
#   5 восстановление из бэкапа
#   6 полный бэкап сервера (перед игрой)
#   7 staging: тестовая копия из бэкапа / текущего проекта
#
# Ничего не хардкодит: проект, compose-файл, сервисы, volumes и порты
# берутся из конфига, docker compose и ответов на вопросы.
#
# Зависимости: bash, docker + docker compose v2, tar, awk, sed, grep.
# JSON-конфиг читается встроенным awk-парсером (jq/python не нужны).

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
DEFAULT_CONFIG="$SCRIPT_DIR/config.json"

CONFIG=""
CONFIG_DIR=""
PD=""; CF=""; BD=""; SD=""
DOCKER=()
TAIL_LINES=200
VOL_IMAGE="alpine:3.20"
EXCLUDES=()
EXTRA=()
PRE_CMDS=()
PORT_OFFSET=10000
PREFIX="adstage"

# ---------------------------------------------------------------- helpers
err() { printf '%s\n' "$*" >&2; }
die() { printf '%s\n' "$*" >&2; exit 1; }

normpath() {
    if command -v realpath >/dev/null 2>&1; then
        realpath -m -- "$1" 2>/dev/null || printf '%s\n' "$1"
    else
        printf '%s\n' "$1"
    fi
}

ask() {
    local prompt=$1 def=${2:-} ans
    if [ -n "$def" ]; then
        printf '%s [%s]: ' "$prompt" "$def" >&2
    else
        printf '%s: ' "$prompt" >&2
    fi
    if ! IFS= read -r ans; then
        ans=""
    fi
    ans=${ans#"${ans%%[![:space:]]*}"}
    ans=${ans%"${ans##*[![:space:]]}"}
    printf '%s' "${ans:-$def}"
}

confirm() {
    local prompt=$1 def=${2:-0} d ans
    if [ "$def" = 1 ]; then d="Y/n"; else d="y/N"; fi
    ans=$(ask "$prompt ($d)" "")
    if [ -z "$ans" ]; then
        [ "$def" = 1 ] && return 0 || return 1
    fi
    case "$ans" in
        y|Y|yes|Yes|д|Д|да|Да) return 0 ;;
        *) return 1 ;;
    esac
}

human_size() {
    awk -v n="${1:-0}" 'BEGIN{
        split("B KB MB GB TB", u, " ");
        i=1;
        while (n>=1024 && i<5) { n/=1024; i++ }
        if (i==1) printf "%d B\n", n; else printf "%.1f %s\n", n, u[i];
    }'
}

dir_size() {
    if [ -e "$1" ]; then
        du -sk -- "$1" 2>/dev/null | awk 'NR==1{print $1*1024; exit}'
    else
        echo 0
    fi
}

json_escape() {
    local s=$1
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\n'/\\n}
    s=${s//$'\t'/\\t}
    s=${s//$'\r'/\\r}
    printf '%s' "$s"
}

json_arr() {
    local first=1 x
    printf '['
    for x in "$@"; do
        [ -z "$x" ] && continue
        if [ $first -eq 0 ]; then printf ', '; fi
        first=0
        printf '"%s"' "$(json_escape "$x")"
    done
    printf ']'
}

# Встроенный разбор плоского JSON в shell-присваивания.
JSON_AWK=$(cat <<'AWK'
function shq(v,   r) {
    gsub(/'/, "'\\''", v)
    return "'" v "'"
}
function skipws(i) {
    while (i<=L) {
        c=substr(S,i,1)
        if (c==" " || c=="\t" || c=="\r" || c=="\n") i++; else break
    }
    return i
}
function pstr(i,   out,c,e) {
    i++; out=""
    while (i<=L) {
        c=substr(S,i,1)
        if (c=="\\") {
            e=substr(S,i+1,1)
            if (e=="n") out=out "\n"
            else if (e=="t") out=out "\t"
            else if (e=="r") out=out "\r"
            else if (e=="b") out=out "\b"
            else if (e=="f") out=out "\f"
            else out=out e
            i+=2; continue
        }
        if (c=="\"") { I=i+1; return out }
        out=out c; i++
    }
    I=i; return out
}
function skipval(i,   d,c) {
    i=skipws(i); c=substr(S,i,1)
    if (c=="{" || c=="[") {
        d=0
        while (i<=L) {
            c=substr(S,i,1)
            if (c=="\"") { pstr(i); i=I; continue }
            if (c=="{" || c=="[") d++
            else if (c=="}" || c=="]") { d--; if (d==0) return i+1 }
            i++
        }
        return i
    }
    while (i<=L && substr(S,i,1) !~ /[,}\]]/) i++
    return i
}
{ S = S $0 "\n" }
END {
    L=length(S); i=skipws(1)
    if (substr(S,i,1)!="{") exit 0
    i++
    while (1) {
        i=skipws(i); c=substr(S,i,1)
        if (c=="}") break
        if (c==",") { i++; continue }
        if (c!="\"") break
        key=pstr(i); i=skipws(I)
        if (substr(S,i,1)==":") i++
        i=skipws(i); c=substr(S,i,1)
        if (c=="[") {
            i++; items=""
            while (1) {
                i=skipws(i); c=substr(S,i,1)
                if (c=="]") { i++; break }
                if (c==",") { i++; continue }
                if (c=="\"") { v=pstr(i); i=I }
                else {
                    st=i
                    while (i<=L && substr(S,i,1) !~ /[,\]]/) i++
                    v=substr(S,st,i-st); gsub(/^[ \t\r\n]+|[ \t\r\n]+$/,"",v)
                }
                items=items " " shq(v)
            }
            print key "=(" items ")"
        } else if (c=="\"") {
            v=pstr(i); i=I
            print key "=" shq(v)
        } else if (c=="{") {
            i=skipval(i)
        } else {
            st=i
            while (i<=L && substr(S,i,1) !~ /[,}\]]/) i++
            v=substr(S,st,i-st); gsub(/^[ \t\r\n]+|[ \t\r\n]+$/,"",v)
            if (v=="true") v="1"; else if (v=="false") v="0"
            if (v=="null" || v=="") v="\"\""
            print key "=" v
        }
    }
}
AWK
)

json_to_sh() { awk "$JSON_AWK"; }

# ---------------------------------------------------------------- config
find_compose() {
    local d=$1 n
    for n in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
        [ -f "$d/$n" ] && { printf '%s\n' "$d/$n"; return 0; }
    done
    return 1
}

setup_wizard() {
    local path=$1 proj comp backup staging dockerw offset extra
    printf 'Конфиг не найден, настроим один раз.\n\n'
    proj=$(ask "Папка проекта (где docker-compose.yml)" "$PWD")
    proj=$(normpath "$proj")
    comp=$(find_compose "$proj") || comp="$proj/docker-compose.yml"
    comp=$(ask "Compose-файл" "$comp")
    backup=$(ask "Папка для бэкапов" "$proj/.devops-backups")
    staging=$(ask "Папка для staging" "$(dirname -- "$proj")/$(basename -- "$proj")-staging")
    dockerw=$(ask "Docker-команда (через пробел)" "docker")
    offset=$(ask "Смещение портов staging" "10000")
    extra=$(ask "Доп. пути для полного бэкапа (через ; , можно пусто)" "")

    local -a dw=() ex=()
    read -ra dw <<< "$dockerw"
    [ ${#dw[@]} -eq 0 ] && dw=(docker)
    if [ -n "$extra" ]; then
        local IFS=',;'
        for x in $extra; do
            x=${x#"${x%%[![:space:]]*}"}; x=${x%"${x##*[![:space:]]}"}
            [ -n "$x" ] && ex+=("$x")
        done
    fi

    {
        printf '{\n'
        printf '  "project_dir": "%s",\n' "$(json_escape "$proj")"
        printf '  "compose_file": "%s",\n' "$(json_escape "$comp")"
        printf '  "backup_dir": "%s",\n' "$(json_escape "$backup")"
        printf '  "docker_cmd": %s,\n' "$(json_arr "${dw[@]}")"
        printf '  "tail_lines": 200,\n'
        printf '  "volume_backup_image": "alpine:3.20",\n'
        printf '  "backup_exclude": %s,\n' "$(json_arr .git __pycache__ node_modules .venv venv .devops-backups)"
        printf '  "extra_paths": %s,\n' "$(json_arr "${ex[@]}")"
        printf '  "pre_backup_commands": [],\n'
        printf '  "staging_dir": "%s",\n' "$(json_escape "$staging")"
        printf '  "staging_port_offset": %s,\n' "${offset:-10000}"
        printf '  "staging_project_prefix": "adstage"\n'
        printf '}\n'
    } > "$path"

    printf '\nСохранено: %s\n' "$path"
}

load_config() {
    local path=$1 decl
    path=$(normpath "$path")
    if [ ! -f "$path" ]; then
        CONFIG_DIR=$(dirname -- "$path")
        setup_wizard "$path"
    fi
    CONFIG_DIR=$(dirname -- "$path")
    decl=$(json_to_sh < "$path") || die "не удалось разобрать конфиг: $path"
    eval "$decl"

    local rel
    rel() { case "$1" in "" ) printf '%s' "" ;; /*) printf '%s' "$1" ;; *) printf '%s/%s' "$CONFIG_DIR" "$1" ;; esac; }

    PD=$(normpath "$(rel "${project_dir:-}")")
    BD=$(normpath "$(rel "${backup_dir:-}")")
    SD=$(normpath "$(rel "${staging_dir:-}")")
    CF=${compose_file:-docker-compose.yml}
    case "$CF" in /*) ;; *) CF="$PD/$CF" ;; esac
    CF=$(normpath "$CF")

    DOCKER=()
    if declare -p docker_cmd >/dev/null 2>&1; then DOCKER=("${docker_cmd[@]}"); fi
    [ ${#DOCKER[@]} -eq 0 ] && DOCKER=(docker)

    if declare -p backup_exclude >/dev/null 2>&1; then
        EXCLUDES=("${backup_exclude[@]}")
    else
        EXCLUDES=(.git __pycache__ node_modules .venv venv)
    fi
    if declare -p extra_paths >/dev/null 2>&1; then EXTRA=("${extra_paths[@]}"); fi
    if declare -p pre_backup_commands >/dev/null 2>&1; then PRE_CMDS=("${pre_backup_commands[@]}"); fi

    TAIL_LINES=${tail_lines:-200}
    VOL_IMAGE=${volume_backup_image:-alpine:3.20}
    PORT_OFFSET=${staging_port_offset:-10000}
    PREFIX=${staging_project_prefix:-adstage}
}

# ---------------------------------------------------------------- docker helpers
compose() {
    "${DOCKER[@]}" compose --project-directory "$PD" -f "$CF" "$@"
}

compose_at() {
    local pd=$1 cf=$2 name=$3
    shift 3
    if [ -n "$name" ]; then
        "${DOCKER[@]}" compose --project-directory "$pd" -f "$cf" -p "$name" "$@"
    else
        "${DOCKER[@]}" compose --project-directory "$pd" -f "$cf" "$@"
    fi
}

parse_services_yaml() {
    [ -f "$1" ] || return 0
    awk '
        /^[[:space:]]*#/ { next }
        /^services:[[:space:]]*$/ { inb=1; next }
        inb && /^[^[:space:]]/ { inb=0 }
        inb && /^  [A-Za-z0-9_.-]+:[[:space:]]*(#.*)?$/ {
            line=$0; sub(/^  /,"",line); sub(/:.*/,"",line); print line
        }
    ' "$1" 2>/dev/null
}

services() {
    local out
    out=$(compose config --services 2>/dev/null | grep -E '^[A-Za-z0-9_.-]+$')
    [ -n "$out" ] && { printf '%s\n' "$out"; return; }
    out=$(compose ps --services 2>/dev/null | grep -E '^[A-Za-z0-9_.-]+$')
    [ -n "$out" ] && { printf '%s\n' "$out"; return; }
    parse_services_yaml "$CF" | grep -E '^[A-Za-z0-9_.-]+$'
}

project_name() {
    local n
    n=$(compose config --format json 2>/dev/null \
        | sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)
    [ -n "$n" ] && { printf '%s\n' "$n"; return; }
    basename -- "$PD"
}

git_commit() {
    git -C "$PD" rev-parse --short HEAD 2>/dev/null
}

# ---------------------------------------------------------------- 1. status
show_status() {
    printf '\n=== Состояние сервера ===\n'
    printf 'Время:  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf 'Хост:   %s\n' "$(hostname 2>/dev/null || cat /etc/hostname 2>/dev/null)"
    printf 'Проект: %s\n' "$PD"
    printf 'Compose: %s\n' "$CF"

    local dv
    dv=$("${DOCKER[@]}" version --format '{{.Server.Version}}' 2>/dev/null)
    printf 'Docker: %s\n' "${dv:-недоступен}"

    local -a svcarr=()
    mapfile -t svcarr < <(services)
    local joined="-"
    if [ ${#svcarr[@]} -gt 0 ]; then
        joined=$(printf '%s, ' "${svcarr[@]}")
        joined=${joined%, }
    fi
    printf 'Сервисы (%d): %s\n' "${#svcarr[@]}" "$joined"

    local out
    if out=$(compose ps --format '{{.Name}}\t{{.Service}}\t{{.State}}\t{{.Health}}\t{{.Ports}}' 2>/dev/null) && [ -n "$out" ]; then
        printf '\n%-24s %-10s %-12s %-10s %s\n' CONTAINER SERVICE STATE HEALTH PORTS
        printf '%s\n' "$out" | awk -F'\t' '{
            for (i=1;i<=5;i++) if ($i=="") $i="-";
            printf "%-24s %-10s %-12s %-10s %s\n", $1,$2,$3,$4,$5
        }'
    else
        printf '\n'
        compose ps
    fi

    [ -r /proc/loadavg ] && printf '\nLoad:  %s\n' "$(cat /proc/loadavg)"
    if [ -r /proc/meminfo ]; then
        local mt ma
        mt=$(awk '/^MemTotal:/{print $2" "$3}' /proc/meminfo)
        ma=$(awk '/^MemAvailable:/{print $2" "$3}' /proc/meminfo)
        printf 'RAM:   %s total, %s available\n' "${mt:-?}" "${ma:-?}"
    fi
    if [ -d "$PD" ]; then
        df -Pk -- "$PD" 2>/dev/null | awk 'NR==2{printf "Disk:  %.1f GB free of %.1f GB\n", $4*1024/1e9, $2*1024/1e9}'
    fi

    if out=$("${DOCKER[@]}" system df 2>/dev/null) && [ -n "$out" ]; then
        printf '\n%s\n' "$out"
    fi
}

# ---------------------------------------------------------------- 2. logs
show_tail() {
    local -a svcs=()
    mapfile -t svcs < <(services)
    if [ ${#svcs[@]} -gt 0 ]; then
        local list="" i
        for i in "${!svcs[@]}"; do list+="$((i+1))) ${svcs[$i]}, "; done
        printf '\nСервисы: %s\n' "${list%, }"
    else
        printf '\nСервисы не найдены\n'
    fi
    local choice
    choice=$(ask "Номер сервиса (Enter = все)" "")
    local -a targets=()
    if [ -n "$choice" ]; then
        if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#svcs[@]} ]; then
            printf 'Нет такого номера\n'
            return
        fi
        targets=("${svcs[$((choice-1))]}")
    else
        targets=("${svcs[@]}")
    fi
    local svc r
    for svc in "${targets[@]}"; do
        [ -z "$svc" ] && continue
        printf '\n=== %s (last %s lines) ===\n' "$svc" "$TAIL_LINES"
        if ! compose logs --tail "$TAIL_LINES" --no-color "$svc"; then
            compose logs --tail "$TAIL_LINES" "$svc"
        fi
    done
}

# ---------------------------------------------------------------- 3. backups
list_backups() {
    [ -d "$BD" ] || return 0
    local d
    for d in "$BD"/*/; do
        [ -d "$d" ] || continue
        d=${d%/}
        [ -f "$d/meta.json" ] && printf '%s\n' "$d"
    done | sort
}

meta_field() {
    # meta_field <meta.json> <key>  -> unquoted value
    local f=$1 k=$2
    ( eval "$(json_to_sh < "$f" 2>/dev/null)"
      case "$k" in
        created) printf '%s' "${created:-?}" ;;
        size) printf '%s' "${size:-0}" ;;
        services) printf '%s\n' "${services[@]}" ;;
      esac )
}

show_backups() {
    local -a items=()
    mapfile -t items < <(list_backups)
    if [ ${#items[@]} -eq 0 ]; then
        printf '\nБэкапов нет: %s\n' "$BD"
        return
    fi
    printf '\n%-3s %-40s %-16s %-10s %-8s\n' '#' 'ИМЯ' 'КОГДА' 'РАЗМЕР' 'SERVICES'
    local i p created size nsvc sz
    for i in "${!items[@]}"; do
        p=${items[$i]}
        created=$(meta_field "$p/meta.json" created)
        size=$(meta_field "$p/meta.json" size)
        [ "$size" -gt 0 ] 2>/dev/null || size=$(dir_size "$p")
        nsvc=$(meta_field "$p/meta.json" services | sed '/^$/d' | wc -l | tr -d ' ')
        printf '%-3d %-40s %-16s %-10s %-8s\n' \
            "$((i+1))" "$(basename -- "$p")" "${created:0:16}" "$(human_size "$size")" "$nsvc"
    done
}

choose_backup() {
    local prompt=${1:-Номер бэкапа}
    local -a items=()
    mapfile -t items < <(list_backups)
    if [ ${#items[@]} -eq 0 ]; then printf 'Бэкапов нет\n'; return 1; fi
    show_backups
    local val
    val=$(ask "$prompt" "")
    if ! [[ "$val" =~ ^[0-9]+$ ]] || [ "$val" -lt 1 ] || [ "$val" -gt ${#items[@]} ]; then
        printf 'Нет такого номера\n'
        return 1
    fi
    printf '%s\n' "${items[$((val-1))]}"
}

# ---------------------------------------------------------------- 4. backup
copy_project() {
    # copy_project <src> <dst> <backup_dir>
    local src=$1 dst=$2 bdir=$3
    local -a args=()
    local x
    for x in "${EXCLUDES[@]}"; do
        [ -z "$x" ] && continue
        args+=("--exclude=$x" "--exclude=*/$x")
    done
    case "$bdir" in
        "$src"/*) args+=("--exclude=${bdir#$src/}" "--exclude=./${bdir#$src/}" "--exclude=*/${bdir#$src/}") ;;
    esac
    mkdir -p "$dst" || return 1
    tar -C "$src" -cf - "${args[@]}" . 2>/dev/null | tar -C "$dst" -xf - || {
        err "  ! копирование не удалось"; return 1
    }
}

backup_volumes() {
    local dest=$1 pname vols vol vdir saved=""
    pname=$(project_name)
    if ! vols=$("${DOCKER[@]}" volume ls -q --filter "label=com.docker.compose.project=$pname" 2>/dev/null); then
        err "  volumes: пропуск (docker volume ls недоступен)"
        return 0
    fi
    if [ -z "$vols" ]; then
        err "  volumes: не найдены для проекта $pname"
        return 0
    fi
    vdir="$dest/volumes"
    mkdir -p "$vdir"
    while IFS= read -r vol; do
        [ -z "$vol" ] && continue
        err "  volume $vol -> $vol.tgz"
        if "${DOCKER[@]}" run --rm -v "$vol:/from:ro" -v "$vdir:/to" "$VOL_IMAGE" \
                sh -c "tar czf /to/$vol.tgz -C /from ." >/dev/null 2>&1 && [ -f "$vdir/$vol.tgz" ]; then
            saved="$saved$vol"$'\n'
        else
            err "    ! не удалось: $vol"
        fi
    done <<< "$vols"
    printf '%s' "$saved"
}

run_pre_commands() {
    local dest=$1 log="$dest/pre_backup.log" cmd
    [ ${#PRE_CMDS[@]} -eq 0 ] && return 0
    for cmd in "${PRE_CMDS[@]}"; do
        [ -z "$cmd" ] && continue
        printf '  pre: %s\n' "$cmd"
        {
            printf '\n$ %s\n' "$cmd"
            ( cd "$PD" && sh -c "$cmd" ) 2>&1
        } >> "$log"
    done
}

write_system_snapshot() {
    local dest=$1 out="$dest/system-info.txt" p
    {
        printf 'time: %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')"
        printf 'host: %s\n' "$(hostname 2>/dev/null)"
        printf 'project: %s\n' "$PD"
        [ -r /proc/uptime ] && printf 'uptime: %s\n' "$(cat /proc/uptime)"
    } > "$out"

    block() {
        local title=$1; shift
        printf '\n### %s\n' "$title" >> "$out"
        "$@" >> "$out" 2>&1 || true
    }
    block "docker version" "${DOCKER[@]}" version
    block "docker ps -a" "${DOCKER[@]}" ps -a
    block "docker images" "${DOCKER[@]}" images
    block "docker volume ls" "${DOCKER[@]}" volume ls
    block "df -h" df -h
    block "free -m" free -m
    block "ss -ltnp" ss -ltnp

    local -a paths=()
    for p in "${EXTRA[@]}"; do [ -e "$p" ] && paths+=("$p"); done
    [ ${#paths[@]} -eq 0 ] && return 0
    if command -v tar >/dev/null 2>&1; then
        if ! tar -czf "$dest/system.tar.gz" "${paths[@]}" 2>/dev/null; then
            err "    ! tar не смог заархивировать extra_paths"
        fi
    else
        local target
        mkdir -p "$dest/system"
        for p in "${paths[@]}"; do
            target="$dest/system/$(printf '%s' "$p" | sed 's#^/##; s#/#_#g')"
            cp -a -- "$p" "$target" 2>/dev/null || err "    ! $p"
        done
    fi
}

write_meta() {
    local dest=$1 label=$2 full=$3 saved_vols=$4
    local created host gcommit svc_json vol_json extra_json
    created=$(date '+%Y-%m-%d %H:%M:%S')
    host=$(hostname 2>/dev/null)
    gcommit=$(git_commit)

    svc_json=$(json_arr $(services))
    local -a vols=()
    while IFS= read -r v; do [ -n "$v" ] && vols+=("$v"); done <<< "$saved_vols"
    vol_json=$(json_arr "${vols[@]}")
    extra_json="[]"
    [ "$full" = 1 ] && extra_json=$(json_arr "${EXTRA[@]}")

    {
        printf '{\n'
        printf '  "created": "%s",\n' "$(json_escape "$created")"
        printf '  "label": "%s",\n' "$(json_escape "$label")"
        printf '  "full": %s,\n' "$([ "$full" = 1 ] && echo true || echo false)"
        printf '  "host": "%s",\n' "$(json_escape "$host")"
        printf '  "project_dir": "%s",\n' "$(json_escape "$PD")"
        printf '  "compose_file": "%s",\n' "$(json_escape "$CF")"
        printf '  "git_commit": "%s",\n' "$(json_escape "$gcommit")"
        printf '  "services": %s,\n' "$svc_json"
        printf '  "volumes": %s,\n' "$vol_json"
        printf '  "extra_paths": %s,\n' "$extra_json"
        printf '  "size": %s\n' "$(dir_size "$dest")"
        printf '}\n'
    } > "$dest/meta.json"
}

create_backup() {
    local label=${1:-manual} full=${2:-0}
    local ts safe dest sz
    ts=$(date '+%Y%m%d-%H%M%S')
    safe=$(printf '%s' "${label:-backup}" | sed 's/[^A-Za-z0-9_.-]\+/-/g; s/^-//; s/-$//' | cut -c1-40)
    [ -n "$safe" ] || safe="backup"
    mkdir -p "$BD" || { err "не могу создать $BD"; return 1; }
    dest="$BD/${ts}_${safe}"
    if [ -e "$dest" ]; then
        printf 'Бэкап уже существует: %s\n' "$dest"
        return 1
    fi
    mkdir -p "$dest" || return 1
    printf '\n=== Бэкап: %s ===\n' "$(basename -- "$dest")"

    printf '  копирую проект...\n'
    copy_project "$PD" "$dest/project" "$BD" || return 1

    if ! compose config > "$dest/compose.resolved.yml" 2>/dev/null; then
        cp -f -- "$CF" "$dest/compose.resolved.yml" 2>/dev/null || true
    fi
    "${DOCKER[@]}" ps -a      > "$dest/containers.txt" 2>&1 || true
    "${DOCKER[@]}" images     > "$dest/images.txt" 2>&1 || true
    "${DOCKER[@]}" volume ls  > "$dest/volumes.txt" 2>&1 || true

    printf '  volumes...\n'
    local saved_vols
    saved_vols=$(backup_volumes "$dest")

    run_pre_commands "$dest"

    if [ "$full" = 1 ]; then
        printf '  системный срез...\n'
        write_system_snapshot "$dest"
    fi

    write_meta "$dest" "$label" "$full" "$saved_vols"
    sz=$(dir_size "$dest")
    printf 'готово: %s (%s)\n' "$dest" "$(human_size "$sz")"
    printf '%s\n' "$dest"
}

# ---------------------------------------------------------------- 5. restore
restore_volumes() {
    local bpath=$1 vdir="$1/volumes" tgz vol
    [ -d "$vdir" ] || return 0
    compgen -G "$vdir/*.tgz" >/dev/null || return 0
    if ! confirm "Восстановить volumes из бэкапа? Текущие данные будут перезаписаны" 0; then
        return 0
    fi
    for tgz in "$vdir"/*.tgz; do
        [ -f "$tgz" ] || continue
        vol=$(basename -- "$tgz" .tgz)
        printf '  volume %s\n' "$vol"
        "${DOCKER[@]}" volume rm -f "$vol" >/dev/null 2>&1 || true
        "${DOCKER[@]}" volume create "$vol" >/dev/null 2>&1 || true
        if ! "${DOCKER[@]}" run --rm -v "$vol:/to" -v "$vdir:/from:ro" "$VOL_IMAGE" \
                sh -c "tar xzf /from/$(basename -- "$tgz") -C /to"; then
            err "    ! ошибка восстановления volume $vol"
        fi
    done
}

restore_backup() {
    local src=$1 delete_extra=${2:-0}
    local created services_line srcdir entry
    created=$(meta_field "$src/meta.json" created)
    services_line=$(meta_field "$src/meta.json" services | awk 'NF{printf "%s%s", (n++?", ":""), $0}')

    printf '\n=== Восстановление: %s ===\n' "$(basename -- "$src")"
    printf '  бэкап: %s\n' "${created:-?}"
    printf '  сервисы: %s\n' "${services_line:--}"
    if ! confirm "Точно восстановить? Текущие файлы проекта будут перезаписаны" 0; then
        printf 'отменено\n'
        return 1
    fi
    if confirm "Сделать бэкап текущего состояния перед откатом?" 1; then
        create_backup "pre-restore" >/dev/null
    fi

    printf '  останавливаю стек...\n'
    compose down || err "  ! docker compose down не удался"

    printf '  возвращаю файлы...\n'
    srcdir="$src/project"
    if [ ! -d "$srcdir" ]; then
        err "  ! в бэкапе нет папки project"
        return 1
    fi
    mkdir -p "$PD"
    tar -C "$srcdir" -cf - . 2>/dev/null | tar -C "$PD" -xf - || { err "  ! ошибка копирования"; return 1; }

    if [ "$delete_extra" = 1 ]; then
        local -A keep=()
        local e n
        shopt -s dotglob nullglob
        for e in "$srcdir"/*; do keep["$(basename -- "$e")"]=1; done
        shopt -u dotglob nullglob
        for e in "${EXCLUDES[@]}"; do keep["$e"]=1; done
        keep["$(basename -- "$BD")"]=1
        shopt -s dotglob nullglob
        for e in "$PD"/*; do
            n=$(basename -- "$e")
            [ "${keep[$n]:-}" = 1 ] && continue
            printf '  удаляю лишнее: %s\n' "$n"
            rm -rf -- "$e"
        done
        shopt -u dotglob nullglob
    fi

    restore_volumes "$src"

    printf '  поднимаю стек...\n'
    compose up -d --build || err "  ! up не удался"
    printf '\n'
    compose ps
}

full_backup() {
    local label
    label=$(ask "Метка (Enter = pregame)" "pregame")
    create_backup "$label" 1
}

# ---------------------------------------------------------------- 7. staging
STAGING_AWK=$(cat <<'AWK'
/"services"[[:space:]]*:[[:space:]]*\{/ { insvc=1 }
insvc && /^    "[^"]+":[[:space:]]*\{/ {
    k=$0; sub(/^    "/,"",k); sub(/":[[:space:]]*\{$/,"",k); svc=k
}
/"container_name"[[:space:]]*:/ { next }
{
    if (match($0, /"published"[[:space:]]*:[[:space:]]*"?[0-9]+"?/)) {
        frag=substr($0,RSTART,RLENGTH)
        num=frag; gsub(/[^0-9]/,"",num)
        new=num+offset
        repl="\"published\": \"" new "\""
        $0=substr($0,1,RSTART-1) repl substr($0,RSTART+RLENGTH)
        print svc "\t" num "\t" new > mapfile
    }
    print
}
AWK
)

staging_from() {
    local backup_item=${1:-}
    local ts root src_project comp raw mapf pname
    ts=$(date '+%Y%m%d-%H%M%S')
    root="$SD/stage-$ts"
    mkdir -p "$root" || { err "! не могу создать $root"; return 1; }

    if [ -n "$backup_item" ]; then
        src_project="$backup_item/project"
        printf '\n=== staging из бэкапа %s ===\n' "$(basename -- "$backup_item")"
    else
        src_project="$PD"
        printf '\n=== staging из текущего проекта ===\n'
    fi
    if [ ! -d "$src_project" ]; then
        err "! нет папки: $src_project"
        return 1
    fi
    printf '  копирую в %s\n' "$root"
    copy_project "$src_project" "$root" "$BD" || return 1

    comp=$(find_compose "$root") || { err "! compose-файл не найден в staging"; return 1; }

    if ! raw=$(compose_at "$root" "$comp" "" config --format json 2>/tmp/.staging_err.$$); then
        err "! нужен docker compose v2 (config --format json)"
        tail -c 400 /tmp/.staging_err.$$ >&2 2>/dev/null || true
        rm -f /tmp/.staging_err.$$
        return 1
    fi
    rm -f /tmp/.staging_err.$$

    mapf="$root/.portmap"
    : > "$mapf"
    printf '%s\n' "$raw" | awk -v offset="$PORT_OFFSET" -v mapfile="$mapf" "$STAGING_AWK" \
        > "$root/docker-compose.staging.json"

    pname="${PREFIX}-${ts}"
    printf '  поднимаю проект %s (порты +%s)...\n' "$pname" "$PORT_OFFSET"
    compose_at "$root" "$root/docker-compose.staging.json" "$pname" up -d --build || \
        err "! up не удался"

    if [ -s "$mapf" ]; then
        printf '\nПорты staging:\n'
        while IFS=$'\t' read -r svc old new; do
            [ -z "$svc" ] && continue
            printf '  %-12s %s -> %s\n' "$svc" "$old" "$new"
        done < "$mapf"
    fi
    printf '\n'
    compose_at "$root" "$root/docker-compose.staging.json" "$pname" ps
    printf '\nПроект: %s\n' "$pname"
}

# ---------------------------------------------------------------- menu
menu() {
    while :; do
        printf '\n=== A/D DevOps ===\n'
        printf '1) Состояние сервера\n'
        printf '2) Последний вывод (tail логов)\n'
        printf '3) Список бэкапов\n'
        printf '4) Сделать бэкап всех сервисов\n'
        printf '5) Восстановиться из бэкапа\n'
        printf '6) Полный бэкап сервера (перед игрой)\n'
        printf '7) Поднять staging для теста фиксов\n'
        printf '0) Выход\n'
        printf 'Выбор: '
        local choice
        if ! IFS= read -r choice; then printf '\n'; return; fi
        case "$choice" in
            1) show_status ;;
            2) show_tail ;;
            3) show_backups ;;
            4) local label; label=$(ask "Метка бэкапа" "manual"); create_backup "$label" ;;
            5)
                local item; item=$(choose_backup) || continue
                local de=0; confirm "Удалять файлы, которых нет в бэкапе?" 0 && de=1
                restore_backup "$item" "$de"
                ;;
            6) full_backup ;;
            7)
                local item=""
                if confirm "Использовать бэкап? (нет = текущий проект)" 1; then
                    item=$(choose_backup) || continue
                fi
                staging_from "$item"
                ;;
            0) return ;;
            *) printf 'Нет такого пункта\n' ;;
        esac
    done
}

# ---------------------------------------------------------------- CLI
usage() {
    cat <<EOF
A/D DevOps console (bash)

Использование: $(basename -- "$0") [--config PATH] [КОМАНДА] [опции]

Команды (без команды — интерактивное меню):
  status
  tail [--service NAME]
  backups
  backup [--label LABEL] [--full]
  restore [--name BACKUP] [--delete-extra]
  staging [--backup BACKUP]
EOF
}

main() {
    local -a rest=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --config) CONFIG=$2; shift 2 ;;
            --config=*) CONFIG=${1#*=}; shift ;;
            -h|--help) usage; exit 0 ;;
            *) rest+=("$1"); shift ;;
        esac
    done
    set -- "${rest[@]}"
    [ -z "$CONFIG" ] && CONFIG="$DEFAULT_CONFIG"
    load_config "$CONFIG"

    local cmd=${1:-}
    [ $# -gt 0 ] && shift

    case "$cmd" in
        status) show_status ;;
        tail)
            local svc=""
            while [ $# -gt 0 ]; do
                case "$1" in
                    --service) svc=$2; shift 2 ;;
                    --service=*) svc=${1#*=}; shift ;;
                    *) shift ;;
                esac
            done
            if [ -n "$svc" ]; then
                compose logs --tail "$TAIL_LINES" "$svc"
            else
                show_tail
            fi
            ;;
        backups) show_backups ;;
        backup)
            local label="manual" full=0
            while [ $# -gt 0 ]; do
                case "$1" in
                    --label) label=$2; shift 2 ;;
                    --label=*) label=${1#*=}; shift ;;
                    --full) full=1; shift ;;
                    *) shift ;;
                esac
            done
            create_backup "$label" "$full" >/dev/null
            ;;
        restore)
            local name="" de=0
            while [ $# -gt 0 ]; do
                case "$1" in
                    --name) name=$2; shift 2 ;;
                    --name=*) name=${1#*=}; shift ;;
                    --delete-extra) de=1; shift ;;
                    *) shift ;;
                esac
            done
            local item=""
            if [ -n "$name" ]; then
                local p
                while IFS= read -r p; do
                    [ "$(basename -- "$p")" = "$name" ] && { item=$p; break; }
                done < <(list_backups)
                if [ -z "$item" ]; then
                    printf 'Бэкап не найден: %s\n' "$name"
                    exit 1
                fi
            else
                item=$(choose_backup) || exit 0
            fi
            restore_backup "$item" "$de"
            ;;
        staging)
            local b=""
            while [ $# -gt 0 ]; do
                case "$1" in
                    --backup) b=$2; shift 2 ;;
                    --backup=*) b=${1#*=}; shift ;;
                    *) shift ;;
                esac
            done
            local item=""
            if [ -n "$b" ]; then
                local p
                while IFS= read -r p; do
                    [ "$(basename -- "$p")" = "$b" ] && { item=$p; break; }
                done < <(list_backups)
                if [ -z "$item" ]; then
                    printf 'Бэкап не найден: %s\n' "$b"
                    exit 1
                fi
            fi
            staging_from "$item"
            ;;
        ""|menu) menu ;;
        *) usage; exit 2 ;;
    esac
}

main "$@"