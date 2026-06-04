#!/usr/bin/env bash
# genvw_proton.sh — backend for `genvw proton …`
#
# this keeps genvw small. stuff handled here:
# - find steam + compatibilitytools.d (native + flatpak)
# - manage the local fsr4 dll (install/verify + meta/report + allowlist)
# - rebuild/clean/list proton-cachyos clones + patch upscalers/vdf
#
# genvw parses `check --kv`. keep that output strictly KEY=VALUE and don’t rename keys.
#
# tags you’ll see in comments:
# - warning: output/order matters
# - security: trust boundary
# - footgun: deletes (always bounded; use rm_rf_within_root)

set -euo pipefail

GENVW_PROTON_VERSION="0.5.0"

# defaults live here so you can see what happens with zero flags/env.
# most of this can be overridden by flags or env.

# proton-cachyos sources
MAJOR_DEFAULT="10.0"                # proton-cachyos major to look for (e.g. 10.0)
MIN_SUPPORTED_DATE_GENVW="20251222" # older builds don’t match the patch set

# clone identity / steam display
SUFFIX_DEFAULT="gENVW" # suffix for cloned tool dirs (e.g. *-gENVW)
TAG_DEFAULT=""         # optional extra tag shown in steam (e.g. -gENVW[Tag])

GENVW_PROTON_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" >/dev/null 2>&1 && pwd -P)"
GENVW_FSR4_POLICY_DATA="${GENVW_PROTON_DIR}/genvw_fsr4_policy.sh"
if [[ ! -r "$GENVW_FSR4_POLICY_DATA" ]]; then
  printf 'ERROR: Missing FSR4 policy data: %s\n' "$GENVW_FSR4_POLICY_DATA" >&2
  exit 2
fi
# shellcheck disable=SC1090
source "$GENVW_FSR4_POLICY_DATA"
genvw_fsr4_policy_validate || exit 2

# canonical trusted FSR4 source map for helper-side install/verify flows and
# for generated upscalers.py backend emission.
FSR4_TRUSTED_SOURCE_ROWS=("${GENVW_FSR4_CANONICAL_TRUSTED_SOURCE_ROWS[@]}")

# fsr4 policy for helper-side install/verify/write flows. Keep this limited to
# real versions only; future 4.1.x-4.4.x family seams live in the patched
# Python backend and are not enabled here by placeholder entries.
FSR4_RELEASED_VERSIONS=("${GENVW_FSR4_CANONICAL_RELEASED_VERSIONS[@]}")

# Historical name kept for compatibility with existing helper/wrapper env
# contracts. In practice this is the helper write-policy allowlist.
FSR4_LOCAL_ONLY_VERSIONS=("${GENVW_FSR4_CANONICAL_LOCAL_ONLY_VERSIONS[@]}")
FSR4_RELEASED_VERSIONS_RESOLVED=("${FSR4_RELEASED_VERSIONS[@]}")
FSR4_LOCAL_ONLY_VERSIONS_RESOLVED=("${FSR4_LOCAL_ONLY_VERSIONS[@]}")

# canonical cache dir for dll + meta/report
# honors GENVW_FSR4_LOCAL_DIR so wrapper + helper use the same local DLL root
DLL_DST_DIR_DEFAULT="${GENVW_FSR4_LOCAL_DIR:-${HOME}/.cache/protonfixes/upscalers/genvw}"
DLL_DST_DIR_CANONICAL="${HOME}/.cache/protonfixes/upscalers/genvw"

# filenames on disk are part of the contract with genvw:
# - dll:  stem_vver.dll (amdxcffx64_v4.0.3.dll)
# - meta/report use the same stem_vver prefix
# - a legacy stem.dll may exist, but shouldn’t be relied on

FSR4_LOCAL_DEFAULT_VER="${GENVW_FSR4_CANONICAL_LOCAL_DEFAULT_VER}" # default local dll version to install/verify
AMD_DLL_STEM_DEFAULT="amdxcffx64" # default dll stem when nothing overrides it

GENVW_FSR4_DOWNLOAD_USER_AGENT="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36"

if [[ -z "${FSR4_LOCAL_DEFAULT_VER}" ]]; then
  echo "ERROR: FSR4_LOCAL_DEFAULT_VER is empty" >&2
  exit 2
fi

# env overrides:
# - prefer GENVW_AMD_DLL_STEM (stem only)
# - back-compat: GENVW_AMD_DLL_NAME can be a basename like amdxcffx64.dll
# stem only here; the full basename is built later (stem + version + .dll)
AMD_DLL_STEM="${GENVW_AMD_DLL_STEM:-}"
if [[ -z "${AMD_DLL_STEM}" ]]; then
  # derive a stem from GENVW_AMD_DLL_NAME, but strip paths/.dll/_v* noise
  AMD_DLL_STEM="${GENVW_AMD_DLL_NAME:-${AMD_DLL_STEM_DEFAULT}.dll}"
  AMD_DLL_STEM="${AMD_DLL_STEM##*/}"
  AMD_DLL_STEM="${AMD_DLL_STEM%.dll}"
  AMD_DLL_STEM="${AMD_DLL_STEM%%_v*}"
  [[ -n "${AMD_DLL_STEM}" ]] || AMD_DLL_STEM="${AMD_DLL_STEM_DEFAULT}"
fi

# upstream/source dll basename inside extracted amd driver trees.
# the cache/install name is versioned (AMD_DLL_NAME), but the extracted file is not.
# override if amd ever renames it:
#   export GENVW_AMD_DLL_SRC_NAME="amdxcffx64.dll"
AMD_DLL_SRC_NAME="${GENVW_AMD_DLL_SRC_NAME:-${AMD_DLL_STEM_DEFAULT}.dll}"

# lock file to keep two installs from stepping on each other
AMD_LOCK_NAME_DEFAULT=".genvw_dll_install.lock"
AMD_LOCK_NAME="${GENVW_AMD_LOCK_NAME:-$AMD_LOCK_NAME_DEFAULT}"

# allowlist path override behavior:
# - unset/empty AMD_DLL_ALLOWLIST => track selected --ver automatically
# - non-empty AMD_DLL_ALLOWLIST  => keep user path pinned across --ver changes
AMD_DLL_ALLOWLIST_LOCKED=0
if [[ -n "${AMD_DLL_ALLOWLIST:-}" ]]; then
  AMD_DLL_ALLOWLIST_LOCKED=1
fi

amd_set_cache_names_for_ver() {
  # set versioned cache filenames for a specific fsr4 version
  #   $1 = version string (e.g. 4.1.0)
  local ver="${1:-}"
  [[ -n "${ver}" ]] || die "Internal: missing --ver for cache name selection"
  AMD_DLL_NAME="${AMD_DLL_STEM}_v${ver}.dll"
  AMD_META_NAME="${AMD_DLL_STEM}_v${ver}.meta.txt"
  AMD_REPORT_NAME="${AMD_DLL_STEM}_v${ver}.report.txt"
  AMD_ALLOWLIST_NAME="${AMD_DLL_STEM}_v${ver}.allowlist"
  AMD_DLL_ALLOWLIST_DEFAULT="${HOME}/.local/share/genvw/allowlists/${AMD_ALLOWLIST_NAME}"
  if [[ "${AMD_DLL_ALLOWLIST_LOCKED:-0}" != "1" ]]; then
    AMD_DLL_ALLOWLIST="${AMD_DLL_ALLOWLIST_DEFAULT}"
  fi
}

genvw_reset_validation_trust_anchor_defaults() {
  DLL_DST_DIR_DEFAULT="${DLL_DST_DIR_CANONICAL}"
  AMD_DLL_ALLOWLIST_LOCKED=0
  AMD_DLL_ALLOWLIST=""
}

genvw_reset_install_allowlist_defaults() {
  AMD_DLL_ALLOWLIST_LOCKED=0
  AMD_DLL_ALLOWLIST=""
  amd_set_cache_names_for_ver "${1:-$FSR4_LOCAL_DEFAULT_VER}"
}

fsr4_ver_syntax_ok() {
  local ver="${1:-}"
  [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

fsr4_ver_is_4x_triplet() {
  local ver="${1:-}"
  [[ "$ver" =~ ^4\.[0-9]+\.[0-9]+$ ]]
}

fsr4_ver_is_released_supported() {
  local ver="${1:-}"
  [[ -n "$ver" ]] || return 1
  local v
  for v in "${FSR4_RELEASED_VERSIONS_RESOLVED[@]}"; do
    [[ "$ver" == "$v" ]] && return 0
  done
  return 1
}

fsr4_ver_is_local_only_supported() {
  local ver="${1:-}"
  [[ -n "$ver" ]] || return 1
  local v
  for v in "${FSR4_LOCAL_ONLY_VERSIONS_RESOLVED[@]}"; do
    [[ "$ver" == "$v" ]] && return 0
  done
  return 1
}

fsr4_trusted_source_lookup() {
  local want_ver="${1:-}" want_field="${2:-}"
  local row="" ver="" url="" sha="" size=""
  [[ -n "$want_ver" && -n "$want_field" ]] || return 1
  for row in "${FSR4_TRUSTED_SOURCE_ROWS[@]}"; do
    IFS='|' read -r ver url sha size <<<"$row"
    [[ "$ver" == "$want_ver" ]] || continue
    case "$want_field" in
      version) printf '%s\n' "$ver" ;;
      url) printf '%s\n' "$url" ;;
      sha256) printf '%s\n' "$sha" ;;
      size) printf '%s\n' "$size" ;;
      row) printf '%s\n' "$row" ;;
      *) return 1 ;;
    esac
    return 0
  done
  return 1
}

fsr4_trusted_source_exists() {
  fsr4_trusted_source_lookup "${1:-}" version >/dev/null 2>&1
}

fsr4_trusted_sources_python_entries() {
  local row="" ver="" url="" sha="" size=""
  for row in "${FSR4_TRUSTED_SOURCE_ROWS[@]}"; do
    IFS='|' read -r ver url sha size <<<"$row"
    printf "%s\n" "    '${ver}': {{"
    printf "%s\n" "        'version': '${ver}',"
    printf "%s\n" "        'download_url': '${url}',"
    printf "%s\n" "        'sha256': '${sha}',"
    printf "%s\n" "        'size': ${size},"
    printf "%s\n" "    }},"
  done
}

dwproton_fsr4_amd_source_allowlist_python_entries() {
  cat <<'EOF'
    '4.0.0': {
        'version': '4.0.0',
        'download_url': 'https://download.amd.com/dir/bin/amdxcffx64.dll/67A4D2BC10ad000/amdxcffx64.dll',
        'source_token': '67A4D2BC10ad000',
    },
    '4.0.1': {
        'version': '4.0.1',
        'download_url': 'https://download.amd.com/dir/bin/amdxcffx64.dll/67D435F7d97000/amdxcffx64.dll',
        'source_token': '67D435F7d97000',
    },
    '4.0.2': {
        'version': '4.0.2',
        'download_url': 'https://download.amd.com/dir/bin/amdxcffx64.dll/68840348eb8000/amdxcffx64.dll',
        'source_token': '68840348eb8000',
    },
    '4.0.3': {
        'version': '4.0.3',
        'download_url': 'https://download.amd.com/dir/bin/amdxcffx64.dll/6930960536b9000/amdxcffx64.dll',
        'source_token': '6930960536b9000',
    },
    '4.1.0': {
        'version': '4.1.0',
        'download_url': 'https://download.amd.com/dir/bin/amdxcffx64.dll/69A0952A304a000/amdxcffx64.dll',
        'source_token': '69A0952A304a000',
    },
EOF
}

fsr4_trusted_file_has_mz() {
  local file="${1:-}" sig=""
  [[ -f "$file" ]] || return 1
  sig="$(od -An -tx1 -N2 "$file" 2>/dev/null | tr -d '[:space:]' || true)"
  [[ "$sig" == "4d5a" ]]
}

fsr4_trusted_validate_file() {
  local file="${1:-}" ver="${2:-}"
  local want_sha="" want_size="" got_sha="" got_size=""
  [[ -f "$file" ]] || return 1
  fsr4_trusted_source_exists "$ver" || return 1
  want_sha="$(fsr4_trusted_source_lookup "$ver" sha256)"
  want_size="$(fsr4_trusted_source_lookup "$ver" size)"
  [[ -n "$want_sha" && -n "$want_size" ]] || return 1
  got_size="$(stat -c %s "$file" 2>/dev/null || true)"
  [[ "$got_size" == "$want_size" ]] || return 1
  fsr4_trusted_file_has_mz "$file" || return 1
  got_sha="$(sha256sum "$file" 2>/dev/null | awk '{print $1}' || true)"
  [[ -n "$got_sha" && "${got_sha,,}" == "${want_sha,,}" ]]
}

fsr4_trusted_allowlist_ensure_entry() {
  local ver="${1:-}" sha="${2:-}" size="${3:-}" note="${4:-}" out_appended_name="${5:-}"
  local allow="${AMD_DLL_ALLOWLIST:-}"
  local entry_appended=0
  note="$(fsr4_allowlist_note_sanitize "$note")"
  [[ -n "$allow" && -n "$sha" && -n "$size" ]] || return 1
  mkdir -p -- "$(dirname -- "$allow")" || die "Could not create allowlist directory: $(dirname -- "$allow")"
  touch "$allow" || die "Could not create allowlist: $allow"
  if ! awk -v sha="$sha" -v size="$size" '
        { sub(/\r$/, "", $0) }
        /^[[:space:]]*#/ {next}
        /^[[:space:]]*$/ {next}
        { if ($1 == sha && $2 == size) found=1 }
        END { exit(found ? 0 : 1) }
      ' "$allow"; then
    if [[ -n "$note" ]]; then
      printf '%s %s # %s\n' "$sha" "$size" "$note" >>"$allow" || die "Could not update allowlist: $allow"
    else
      printf '%s %s\n' "$sha" "$size" >>"$allow" || die "Could not update allowlist: $allow"
    fi
    entry_appended=1
  fi
  if [[ -n "$out_appended_name" ]]; then
    printf -v "$out_appended_name" '%s' "$entry_appended"
  fi
}

fsr4_allowlist_note_sanitize() {
  local note="${1:-}"
  note="${note//$'\r'/ }"
  note="${note//$'\n'/ }"
  note="${note//$'\t'/ }"
  note="$(printf '%s' "$note" | tr -cd 'A-Za-z0-9._:= -')"
  while [[ "$note" == *"  "* ]]; do
    note="${note//  / }"
  done
  note="${note#"${note%%[! ]*}"}"
  note="${note%"${note##*[! ]}"}"
  printf '%s\n' "${note:0:160}"
}

fsr4_allowlist_note_atom_sanitize() {
  local value="${1:-}"
  value="${value//$'\r'/}"
  value="${value//$'\n'/}"
  value="${value//$'\t'/}"
  value="$(printf '%s' "$value" | tr -cd 'A-Za-z0-9._:-')"
  printf '%s\n' "${value:0:64}"
}

fsr4_local_trust_allowlist_note_from_meta() {
  local selected_ver="${1:-}" dst_dir="${2:-$DLL_DST_DIR_DEFAULT}"
  local meta="$dst_dir/${AMD_META_NAME}"
  local driver="" source_kind="" note=""
  : "${selected_ver}"
  if [[ -f "$meta" ]]; then
    driver="$(fsr4_allowlist_note_atom_sanitize "$(amd_meta_get_value "$meta" "DRIVER_LABEL")")"
    source_kind="$(fsr4_allowlist_note_atom_sanitize "$(amd_meta_get_value "$meta" "SOURCE_KIND")")"
  fi
  if [[ -n "$driver" ]]; then
    note="driver=$driver"
  fi
  if [[ -n "$source_kind" ]]; then
    note="${note:+$note }source=$source_kind"
  fi
  printf '%s\n' "$note"
}

fsr4_trusted_download_to_file() {
  local url="${1:-}" dst="${2:-}"
  local ua="${GENVW_FSR4_DOWNLOAD_USER_AGENT}"
  [[ -n "$url" && -n "$dst" ]] || die "Internal: trusted download requires url and dst"
  if have curl; then
    curl -L --fail \
      --connect-timeout 15 --max-time 120 \
      --retry 3 --retry-delay 2 --retry-connrefused \
      --max-redirs 25 \
      -A "$ua" -o "$dst" "$url" >/dev/null 2>&1 \
      || die "Trusted version download failed (curl): $url"
    return 0
  fi
  if have wget; then
    wget --https-only --max-redirect=25 \
      --tries=3 --waitretry=2 --timeout=30 \
      -O "$dst" --user-agent="$ua" "$url" >/dev/null 2>&1 \
      || die "Trusted version download failed (wget): $url"
    return 0
  fi
  die "Missing downloader (need curl or wget) for trusted version install"
}

fsr4_local_only_versions_csv() {
  local out="" v
  for v in "${FSR4_LOCAL_ONLY_VERSIONS_RESOLVED[@]}"; do
    if [[ -n "$out" ]]; then
      out+=", "
    fi
    out+="$v"
  done
  printf '%s\n' "$out"
}

fsr4_local_only_versions_slash() {
  local out="" v
  for v in "${FSR4_LOCAL_ONLY_VERSIONS_RESOLVED[@]}"; do
    if [[ -n "$out" ]]; then
      out+="/"
    fi
    out+="$v"
  done
  printf '%s\n' "$out"
}

fsr4_released_versions_slash() {
  local out="" v
  for v in "${FSR4_RELEASED_VERSIONS_RESOLVED[@]}"; do
    if [[ -n "$out" ]]; then
      out+="/"
    fi
    out+="$v"
  done
  printf '%s\n' "$out"
}

fsr4_require_local_write_supported_ver() {
  local ver="${1:-}"
  local ctx="${2:-this command}"
  if fsr4_ver_is_released_supported "$ver" && fsr4_ver_is_local_only_supported "$ver"; then
    return 0
  fi
  die "${ctx}: --ver ${ver} is not supported for local write paths. Supported versions: $(fsr4_local_only_versions_slash)"
}

fsr4_warn_unreleased_read_only_ver() {
  local ver="${1:-}"
  local ctx="${2:-read-only flow}"
  if fsr4_ver_is_4x_triplet "$ver" && ! fsr4_ver_is_released_supported "$ver"; then
    warn "${ctx}: --ver ${ver} is not in released FSR4 policy ($(fsr4_released_versions_slash)); continuing read-only verification."
  fi
}

fsr4_versions_slash_from_args() {
  # helper for compact "a/b/c" version lists in error messages.
  local out="" v
  for v in "$@"; do
    [[ -n "$v" ]] || continue
    if [[ -n "$out" ]]; then
      out+="/"
    fi
    out+="$v"
  done
  printf '%s\n' "$out"
}

fsr4_versions_comma_from_args() {
  local out="" v
  for v in "$@"; do
    [[ -n "$v" ]] || continue
    if [[ -n "$out" ]]; then
      out+=", "
    fi
    out+="$v"
  done
  [[ -n "$out" ]] && printf '%s\n' "$out" || printf '%s\n' "none"
}

fsr4_array_contains() {
  local needle="${1:-}" v
  shift || true
  [[ -n "$needle" ]] || return 1
  for v in "$@"; do
    [[ "$v" == "$needle" ]] && return 0
  done
  return 1
}

fsr4_collect_dll_filename_version_candidates() {
  # collect unique 4.x.y candidates from the DLL filename only.
  local dll_path="${1:-}"
  local -n out_ref="$2"
  local base="" v=""
  declare -A seen=()

  out_ref=()
  [[ -n "$dll_path" ]] || return 0
  [[ -f "$dll_path" ]] || return 0

  base="$(basename -- "$dll_path" 2>/dev/null || printf '%s' "$dll_path")"

  while IFS= read -r v; do
    [[ -n "$v" ]] || continue
    fsr4_ver_is_4x_triplet "$v" || continue
    if [[ -z "${seen[$v]+x}" ]]; then
      seen["$v"]=1
      out_ref+=("$v")
    fi
  done < <(printf '%s\n' "$base" | grep -Eo '4\.[0-9]+\.[0-9]+' || true)
}

fsr4_collect_dll_content_version_candidates() {
  # installed-cache verification cannot trust the cache filename because we
  # choose that name ourselves. only scan the DLL bytes here.
  local dll_path="${1:-}"
  local -n out_ref="$2"
  local v=""
  declare -A seen=()

  out_ref=()
  [[ -n "$dll_path" ]] || return 0
  [[ -f "$dll_path" ]] || return 0

  while IFS= read -r v; do
    [[ -n "$v" ]] || continue
    fsr4_ver_is_4x_triplet "$v" || continue
    if [[ -z "${seen[$v]+x}" ]]; then
      seen["$v"]=1
      out_ref+=("$v")
    fi
  done < <(LC_ALL=C grep -aEo '4\.[0-9]+\.[0-9]+' "$dll_path" 2>/dev/null | awk '!seen[$0]++' || true)
}

fsr4_collect_dll_version_candidates() {
  # collect unique 4.x.y candidates from filename and binary content.
  # filename covers the common amdxcffx64_vX.Y.Z.dll case.
  # content scan catches embedded markers when the filename is generic.
  local dll_path="${1:-}"
  local -n out_ref="$2"
  local -a filename=()
  local -a content=()
  local v=""
  declare -A seen=()

  out_ref=()
  [[ -n "$dll_path" ]] || return 0
  [[ -f "$dll_path" ]] || return 0

  fsr4_collect_dll_filename_version_candidates "$dll_path" filename
  fsr4_collect_dll_content_version_candidates "$dll_path" content

  for v in "${filename[@]}" "${content[@]}"; do
    [[ -n "$v" ]] || continue
    fsr4_ver_is_4x_triplet "$v" || continue
    if [[ -z "${seen[$v]+x}" ]]; then
      seen["$v"]=1
      out_ref+=("$v")
    fi
  done
}

fsr4_filter_local_write_supported_versions() {
  local -n in_ref="$1"
  local -n out_ref="$2"
  local v=""

  out_ref=()
  for v in "${in_ref[@]}"; do
    if fsr4_ver_is_released_supported "$v" && fsr4_ver_is_local_only_supported "$v"; then
      out_ref+=("$v")
    fi
  done
}

fsr4_highest_supported_version_from_args() {
  local highest="" relation="" v=""
  for v in "$@"; do
    [[ -n "$v" ]] || continue
    if [[ -z "$highest" ]]; then
      highest="$v"
      continue
    fi
    amd_triplet_version_compare "$v" "$highest" relation || relation="lt"
    [[ "$relation" == "gt" ]] && highest="$v"
  done
  [[ -n "$highest" ]] && printf '%s\n' "$highest"
}

fsr4_dll_marker_result_label() {
  local all_count="${1:-0}" supported_count="${2:-0}"
  if ((supported_count == 1)); then
    printf '%s\n' "single"
  elif ((supported_count > 1)); then
    printf '%s\n' "ambiguous"
  elif ((all_count > 0)); then
    printf '%s\n' "unsupported"
  else
    printf '%s\n' "missing"
  fi
}

fsr4_detect_single_local_write_ver_from_dll() {
  # detect one local-write-supported 4.x.y version from a DLL file.
  # fails fast when detection is missing, unsupported, or ambiguous.
  local dll_path="${1:-}"
  local ctx="${2:-dll install}"
  local -a all=()
  local -a supported=()
  local v=""

  require_file "$dll_path" "--dll"
  fsr4_collect_dll_version_candidates "$dll_path" all

  # local-write paths only accept versions inside both policy lists.
  for v in "${all[@]}"; do
    if fsr4_ver_is_released_supported "$v" && fsr4_ver_is_local_only_supported "$v"; then
      supported+=("$v")
    fi
  done

  if ((${#supported[@]} == 1)); then
    printf '%s\n' "${supported[0]}"
    return 0
  fi

  if ((${#supported[@]} == 0)); then
    if ((${#all[@]} == 0)); then
      die "${ctx}: could not infer DLL FSR4 version from filename/content."
    fi
    die "${ctx}: detected unsupported/unreleased DLL version candidate(s): $(fsr4_versions_slash_from_args "${all[@]}"). Supported local-write versions: $(fsr4_local_only_versions_slash)."
  fi

  die "${ctx}: selected DLL contains multiple FSR4 version markers: $(fsr4_versions_slash_from_args "${supported[@]}")"
}

fsr4_detect_single_local_write_ver_from_dll_content() {
  # confirm the installed cache DLL from its bytes only.
  local dll_path="${1:-}"
  local ctx="${2:-dll install}"
  local -a all=()
  local -a supported=()
  local v=""

  require_file "$dll_path" "installed DLL"
  fsr4_collect_dll_content_version_candidates "$dll_path" all

  for v in "${all[@]}"; do
    if fsr4_ver_is_released_supported "$v" && fsr4_ver_is_local_only_supported "$v"; then
      supported+=("$v")
    fi
  done

  if ((${#supported[@]} == 1)); then
    printf '%s\n' "${supported[0]}"
    return 0
  fi

  if ((${#supported[@]} == 0)); then
    if ((${#all[@]} == 0)); then
      die "${ctx}: installed DLL does not expose a supported 4.x.y version marker in its content."
    fi
    die "${ctx}: installed DLL content exposed unsupported/unreleased version candidate(s): $(fsr4_versions_slash_from_args "${all[@]}"). Supported local-write versions: $(fsr4_local_only_versions_slash)."
  fi

  die "${ctx}: installed DLL content exposes multiple FSR4 version markers: $(fsr4_versions_slash_from_args "${supported[@]}")"
}

fsr4_version_from_versioned_cache_name() {
  local p="${1:-}"
  local base=""
  [[ -n "$p" ]] || return 1
  base="$(basename -- "$p" 2>/dev/null || printf '%s' "$p")"
  if [[ "$base" =~ _v(4\.[0-9]+\.[0-9]+)\.(dll|meta\.txt|report\.txt)$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

amd_validate_local_dll_source_for_install() {
  local src_dll="${1:-}"
  require_file "$src_dll" "--dll"
  [[ -r "$src_dll" ]] || die "--dll: file not readable: $src_dll"
  case "$src_dll" in
    *.dll | *.DLL) ;;
    *) die "--dll expects a .dll file path: $src_dll" ;;
  esac

  local src_size=0
  src_size="$(stat -c %s "$src_dll" 2>/dev/null || echo 0)"
  [[ "$src_size" =~ ^[0-9]+$ && "$src_size" -ge 1024 ]] || die "--dll: file is too small (<1 KiB): $src_dll"

  local sig=""
  IFS= read -r -n2 sig <"$src_dll" || true
  [[ "$sig" == "MZ" ]] || die "--dll: file does not look like a PE DLL (missing 'MZ' header): $src_dll"
}

fsr4_hidden_install_expect_ver() {
  # internal contract for wrapper/prep flows:
  # install must resolve to this version or fail.
  local expect="${GENVW_INSTALL_EXPECT_VER:-}"
  [[ -n "$expect" ]] || return 1
  fsr4_ver_syntax_ok "$expect" || die "Invalid GENVW_INSTALL_EXPECT_VER: must look like 4.x.y: $expect"
  fsr4_require_local_write_supported_ver "$expect" "install expectation"
  printf '%s\n' "$expect"
}

fsr4_hidden_install_dev_override_ver() {
  # internal-only escape hatch for tests and recovery:
  # force the install version even when the artifact cannot prove it.
  local override="${GENVW_DEV_DLL_INSTALL_VER:-}"
  [[ -n "$override" ]] || return 1
  fsr4_ver_syntax_ok "$override" || die "Invalid GENVW_DEV_DLL_INSTALL_VER: must look like 4.x.y: $override"
  fsr4_require_local_write_supported_ver "$override" "dev install override"
  printf '%s\n' "$override"
}

amd_dll_is_trusted_for_ver() {
  local ver="${1:-}"
  local dst_dir="${2:-$DLL_DST_DIR_DEFAULT}"
  local __save_dll="${AMD_DLL_NAME:-}"
  local __save_meta="${AMD_META_NAME:-}"
  local __save_report="${AMD_REPORT_NAME:-}"
  local __save_allow_name="${AMD_ALLOWLIST_NAME:-}"
  local __save_allow_default="${AMD_DLL_ALLOWLIST_DEFAULT:-}"
  local __save_allow="${AMD_DLL_ALLOWLIST:-}"
  local cache_dll=""
  local rc=1

  [[ -n "$ver" ]] || return 1
  fsr4_ver_is_local_only_supported "$ver" || return 1

  amd_set_cache_names_for_ver "$ver"
  cache_dll="${dst_dir}/${AMD_DLL_NAME}"
  if [[ -f "$cache_dll" ]]; then
    if amd_dll_provenance_integrity verify "$dst_dir" >/dev/null 2>&1; then
      rc=0
    fi
  fi

  AMD_DLL_NAME="$__save_dll"
  AMD_META_NAME="$__save_meta"
  AMD_REPORT_NAME="$__save_report"
  AMD_ALLOWLIST_NAME="$__save_allow_name"
  AMD_DLL_ALLOWLIST_DEFAULT="$__save_allow_default"
  AMD_DLL_ALLOWLIST="$__save_allow"
  return "$rc"
}

fsr4_resolve_effective_local_default() {
  local dst_dir="${1:-$DLL_DST_DIR_DEFAULT}"
  local -n out_ver_ref="$2"
  local -n out_source_ref="$3"
  local preferred="${FSR4_LOCAL_DEFAULT_VER}"
  local candidate=""
  local i=0

  out_ver_ref="$preferred"
  out_source_ref="preferred_default"

  if amd_dll_is_trusted_for_ver "$preferred" "$dst_dir"; then
    out_ver_ref="$preferred"
    out_source_ref="preferred_trusted"
    return 0
  fi

  for ((i = ${#FSR4_LOCAL_ONLY_VERSIONS_RESOLVED[@]} - 1; i >= 0; i--)); do
    candidate="${FSR4_LOCAL_ONLY_VERSIONS_RESOLVED[i]}"
    [[ "$candidate" == "$preferred" ]] && continue
    if amd_dll_is_trusted_for_ver "$candidate" "$dst_dir"; then
      out_ver_ref="$candidate"
      out_source_ref="highest_trusted_installed"
      return 0
    fi
  done

  return 0
}

fsr4_apply_effective_local_default_if_implicit() {
  local dst_dir="${1:-$DLL_DST_DIR_DEFAULT}"
  validate_inherited_local_dll_cache_root_if_used "$dst_dir"

  declare -g FSR4_EFFECTIVE_LOCAL_DEFAULT_VER="${FSR4_LOCAL_DEFAULT_VER}"
  declare -g FSR4_EFFECTIVE_LOCAL_DEFAULT_SOURCE="preferred_default"

  if [[ "${FSR4_VER_EXPLICIT:-0}" == "1" || "${LOCALDLL_EXPLICIT:-0}" == "1" ]]; then
    FSR4_EFFECTIVE_LOCAL_DEFAULT_VER="${FSR4_VER:-$FSR4_LOCAL_DEFAULT_VER}"
    if [[ "${FSR4_VER_EXPLICIT:-0}" == "1" ]]; then
      FSR4_EFFECTIVE_LOCAL_DEFAULT_SOURCE="explicit_ver"
    else
      FSR4_EFFECTIVE_LOCAL_DEFAULT_SOURCE="explicit_localdll"
    fi
    return 0
  fi

  fsr4_resolve_effective_local_default "$dst_dir" FSR4_EFFECTIVE_LOCAL_DEFAULT_VER FSR4_EFFECTIVE_LOCAL_DEFAULT_SOURCE
  FSR4_VER="${FSR4_EFFECTIVE_LOCAL_DEFAULT_VER}"
  amd_set_cache_names_for_ver "${FSR4_VER}"
  LOCALDLL="${dst_dir}/${AMD_DLL_NAME}"
}

fsr4_enforce_expected_install_ver() {
  local actual="${1:-}" expected="${2:-}" ctx="${3:-dll install}"
  [[ -n "$expected" ]] || return 0
  if [[ "$actual" != "$expected" ]]; then
    err "${ctx}: source artifact resolved to FSR4 ${actual}, but FSR4 ${expected} was requested."
    return 1
  fi
}

amd_record_last_installed_ver() {
  declare -g GENVW_LAST_INSTALLED_FSR4_VER="${1:-}"
  declare -g GENVW_LAST_INSTALLED_FSR4_VER_SOURCE="${2:-}"
}

fsr4_trim_space_edges() {
  local s="${1-}"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s\n' "$s"
}

fsr4_parse_csv_strict_4x_into_array() {
  local raw="${1-}" label="${2:-CSV}"
  local -n out_ref="$3"
  local -a toks=()
  local t v
  declare -A seen=()

  out_ref=()
  [[ -n "$raw" ]] || die "${label} is empty"
  if [[ "$raw" == *, || "$raw" == ,* || "$raw" == *",,"* ]]; then
    die "${label} is malformed (empty CSV element)"
  fi

  IFS=',' read -r -a toks <<<"$raw"
  ((${#toks[@]} > 0)) || die "${label} did not contain any versions"

  for t in "${toks[@]}"; do
    v="$(fsr4_trim_space_edges "$t")"
    [[ -n "$v" ]] || die "${label} has empty/whitespace-only element"
    [[ "$v" =~ ^4\.[0-9]+\.[0-9]+$ ]] || die "${label} has invalid version '${v}' (expected 4.x.y)"
    if [[ -n "${seen[$v]+x}" ]]; then
      die "${label} has duplicate version '${v}'"
    fi
    seen["$v"]=1
    out_ref+=("$v")
  done
}

fsr4_array_contains() {
  local needle="${1:-}"
  shift || true
  local x
  for x in "$@"; do
    [[ "$needle" == "$x" ]] && return 0
  done
  return 1
}

fsr4_add_tokens_to_policy() {
  local -n target_ref="$1"
  local raw="${2-}"
  local label="${3:-CSV}"
  local -a parsed=()
  local v
  [[ -n "$raw" ]] || return 0
  fsr4_parse_csv_strict_4x_into_array "$raw" "$label" parsed
  for v in "${parsed[@]}"; do
    if fsr4_array_contains "$v" "${target_ref[@]}"; then
      die "${label} tried to add duplicate/already-present version '${v}'"
    fi
    target_ref+=("$v")
  done
}

fsr4_replace_policy_from_csv() {
  local -n target_ref="$1"
  local raw="${2-}"
  local label="${3:-CSV}"
  local -a parsed=()
  fsr4_parse_csv_strict_4x_into_array "$raw" "$label" parsed
  ((${#parsed[@]} > 0)) || die "${label} did not contain any versions"
  target_ref=("${parsed[@]}")
}

fsr4_validate_final_policy() {
  local v
  for v in "${FSR4_LOCAL_ONLY_VERSIONS_RESOLVED[@]}"; do
    if ! fsr4_array_contains "$v" "${FSR4_RELEASED_VERSIONS_RESOLVED[@]}"; then
      die "Invalid FSR4 policy: local-only version '${v}' is not in released policy"
    fi
  done

  if ! fsr4_array_contains "$FSR4_LOCAL_DEFAULT_VER" "${FSR4_RELEASED_VERSIONS_RESOLVED[@]}"; then
    die "Invalid FSR4 policy: FSR4_LOCAL_DEFAULT_VER (${FSR4_LOCAL_DEFAULT_VER}) is not in released policy"
  fi
  if ! fsr4_array_contains "$FSR4_LOCAL_DEFAULT_VER" "${FSR4_LOCAL_ONLY_VERSIONS_RESOLVED[@]}"; then
    die "Invalid FSR4 policy: FSR4_LOCAL_DEFAULT_VER (${FSR4_LOCAL_DEFAULT_VER}) is not in local-only policy"
  fi
}

fsr4_resolve_policy() {
  local resolved_rel="${GENVW_FSR4_RESOLVED_RELEASED_VERSIONS_CSV-}"
  local resolved_loc="${GENVW_FSR4_RESOLVED_LOCAL_ONLY_VERSIONS_CSV-}"
  local replace_ok="${GENVW_FSR4_POLICY_REPLACE_OK:-0}"
  local rel_replace="${GENVW_FSR4_RELEASED_VERSIONS_CSV-}"
  local loc_replace="${GENVW_FSR4_LOCAL_ONLY_VERSIONS_CSV-}"
  local add_both="${GENVW_FSR4_ADD_CSV-}"
  local add_both_alias="${GENVW_FSR4_ADD-}"
  local add_rel="${GENVW_FSR4_RELEASED_ADD_CSV-}"
  local add_loc="${GENVW_FSR4_LOCAL_ONLY_ADD_CSV-}"

  FSR4_RELEASED_VERSIONS_RESOLVED=("${FSR4_RELEASED_VERSIONS[@]}")
  FSR4_LOCAL_ONLY_VERSIONS_RESOLVED=("${FSR4_LOCAL_ONLY_VERSIONS[@]}")

  # when wrapper provided resolved policy, use it exactly so wrapper/helper stay in parity.
  if [[ -n "$resolved_rel" || -n "$resolved_loc" ]]; then
    [[ -n "$resolved_rel" && -n "$resolved_loc" ]] || die "Resolved FSR4 policy contract is incomplete (need both released and local-only CSV)"
    fsr4_replace_policy_from_csv FSR4_RELEASED_VERSIONS_RESOLVED "$resolved_rel" "GENVW_FSR4_RESOLVED_RELEASED_VERSIONS_CSV"
    fsr4_replace_policy_from_csv FSR4_LOCAL_ONLY_VERSIONS_RESOLVED "$resolved_loc" "GENVW_FSR4_RESOLVED_LOCAL_ONLY_VERSIONS_CSV"
    fsr4_validate_final_policy
    return 0
  fi

  if [[ -n "$add_both" && -n "$add_both_alias" ]]; then
    die "Set only one of GENVW_FSR4_ADD_CSV or GENVW_FSR4_ADD (not both)"
  fi
  [[ -n "$add_both" ]] || add_both="$add_both_alias"

  if [[ -n "$rel_replace" || -n "$loc_replace" ]]; then
    [[ "$replace_ok" == "1" ]] || die "Full FSR4 policy replace requires GENVW_FSR4_POLICY_REPLACE_OK=1"
    if [[ -n "$rel_replace" ]]; then
      fsr4_replace_policy_from_csv FSR4_RELEASED_VERSIONS_RESOLVED "$rel_replace" "GENVW_FSR4_RELEASED_VERSIONS_CSV"
    fi
    if [[ -n "$loc_replace" ]]; then
      fsr4_replace_policy_from_csv FSR4_LOCAL_ONLY_VERSIONS_RESOLVED "$loc_replace" "GENVW_FSR4_LOCAL_ONLY_VERSIONS_CSV"
    fi
  fi

  fsr4_add_tokens_to_policy FSR4_RELEASED_VERSIONS_RESOLVED "$add_both" "GENVW_FSR4_ADD_CSV/GENVW_FSR4_ADD"
  fsr4_add_tokens_to_policy FSR4_LOCAL_ONLY_VERSIONS_RESOLVED "$add_both" "GENVW_FSR4_ADD_CSV/GENVW_FSR4_ADD"
  fsr4_add_tokens_to_policy FSR4_RELEASED_VERSIONS_RESOLVED "$add_rel" "GENVW_FSR4_RELEASED_ADD_CSV"
  fsr4_add_tokens_to_policy FSR4_LOCAL_ONLY_VERSIONS_RESOLVED "$add_loc" "GENVW_FSR4_LOCAL_ONLY_ADD_CSV"

  fsr4_validate_final_policy
}

# prime names to the default local version so globals exist before flag parsing
amd_set_cache_names_for_ver "${FSR4_LOCAL_DEFAULT_VER}"

# cache root (xdg-ish):
# used for amd driver exe downloads + extraction dirs (keeps junk out of $HOME)
GENVW_CACHE_DIR="${GENVW_CACHE_DIR:-${XDG_CACHE_HOME:-${HOME}/.cache}/genvw}"
AMD_DRIVER_DL_DIR="${GENVW_CACHE_DIR}/amd/driver-dl" # downloaded driver exes
AMD_EXTRACT_ROOT="${GENVW_CACHE_DIR}/amd/extracted"  # extracted trees for dll harvesting

# validate_cache_dir
#
# footgun/security: this is the root for downloads, extraction dirs, and cleanup.
# if it’s relative or '/', you can end up writing/removing in the wrong place.
# fail fast so we don’t do something stupid.

# depends on: die()
validate_dir_env() {
  local p="${1:-}"
  local label="${2:-path}"
  [[ -n "$p" ]] || die "${label} is empty"
  [[ "$p" == /* ]] || die "${label} must be an absolute path: $p"
  [[ "$p" != "/" ]] || die "${label} must not be /: $p"
  [[ "$p" != *..* ]] || die "${label} must not contain '..': $p"
  if [[ "$p" =~ [[:space:]] ]]; then
    die "${label} must not contain whitespace: $p"
  fi
}

validate_cache_dir() {
  local p="${1:-${GENVW_CACHE_DIR:-}}"
  validate_dir_env "$p" "GENVW_CACHE_DIR"
}

validate_inherited_local_dll_cache_root_if_used() {
  local dst_dir="${1:-}"
  [[ -n "$dst_dir" ]] || dst_dir="$DLL_DST_DIR_DEFAULT"
  [[ "$dst_dir" == "$DLL_DST_DIR_DEFAULT" ]] || return 0
  validate_dir_env "$DLL_DST_DIR_DEFAULT" "GENVW_FSR4_LOCAL_DIR"
}

# validate_basename
#
# security: these can be overridden via env (GENVW_AMD_DLL_NAME / GENVW_AMD_META_NAME / ...).
# keep them as plain basenames since they get joined with cache dirs later.
# also blocks weird option-y names like "-rf".

# rules:
# - non-empty
# - no '/'
# - no '..'
# - no whitespace
# - must not start with '-' (avoid option injection)
#
# depends on: die()
validate_basename() {
  local value="${1:-}"
  local label="${2:-value}"
  [[ -n "$value" ]] || die "${label} is empty"
  [[ "$value" != */* ]] || die "${label} must be a basename (no '/'): $value"
  [[ "$value" != *..* ]] || die "${label} must not contain '..': $value"
  [[ "$value" != -* ]] || die "${label} must not start with '-': $value"
  if [[ "$value" =~ [[:space:]] ]]; then
    die "${label} must not contain whitespace: $value"
  fi
}

# selftest-only install version when helper selftest falls back to AMD_DRIVER_URL.
GENVW_SELFTEST_DEFAULT_AMD_URL_INSTALL_VER="4.0.3"

# amd_driver_url fallback default (only if unset)
: "${AMD_DRIVER_URL:=https://drivers.amd.com/drivers/whql-amd-software-adrenalin-edition-26.1.1-win11-b.exe}"

# Diagnose/install source policy for helper-side local install flows.
# Keep this table in sync with the real AMD artifacts you want to point users at.
# Fields:
#   version | source_kind | min_driver_label | max_driver_label | source_ref
# source_kind:
#   trusted_map       -> canonical trusted version install via --ver
#   amd_driver_range  -> known driver EXE range via --url/--exe
#   local_dll_only    -> standalone DLL install via --dll
FSR4_DIAG_SOURCE_POLICY=(
  "4.0.0|trusted_map|||"
  "4.0.1|trusted_map|||"
  "4.0.2|trusted_map|||"
  "4.0.3|trusted_map|||"
  "4.1.0|trusted_map|||"
)

# external allowlist (user-maintained):
# security: this is the trust anchor for approving a local dll fingerprint.
# format: "SHA256 SIZE [extra fields...]" (comments/blank lines allowed).
# match rules: sha256+size required; anything after the second field is ignored.
# managed by amd_set_cache_names_for_ver() so it follows --ver unless user-pinned.

# amd_dll_allowlist_match_triple
# legacy helper kept for compatibility with older callers.
# status: intentional reserve helper; no live callers right now.
# the live check is inline in amd_dll_provenance_integrity().
#
# warning: parsed output — keep stable.
amd_dll_allowlist_match_triple() {
  # deprecated: this used to imply "md5 required" and drifted from the real allowlist rules.
  # keep it around so we don’t accidentally bring strict-md5 back during refactors.
  #
  # real rules:
  # - sha + size must match
  # - ignore anything after the second field
  # - strip trailing \r so windows/crlf allowlists work
  local sha="${1:-}" size="${2:-}" md5="${3:-}"
  local allow="${AMD_DLL_ALLOWLIST:-}"

  [[ -n "$sha" && -n "$size" ]] || return 2
  [[ -f "$allow" ]] || return 3

  : "${md5}"
  awk -v sha="$sha" -v size="$size" '
    { sub(/\r$/, "", $0) }
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    {
      if ($1 == sha && $2 == size) { found=1; exit }
    }
    END { exit(found ? 0 : 1) }
  ' "$allow"
}

copy_allowlists_into_dir() {
  local src_dir="${1:-}" dst_dir="${2:-}"
  [[ -n "$src_dir" && -n "$dst_dir" ]] || return 0
  [[ -d "$src_dir" ]] || return 0
  mkdir -p -- "$dst_dir" 2>/dev/null || return 0

  # copy allowlist contents into the sandbox, not the symlink itself.
  # this keeps versioned filenames valid even when they point at one canonical file.
  find "$src_dir" -maxdepth 1 \( -type f -o -type l \) -name '*.allowlist' \
    -exec cp -fL -- {} "$dst_dir/" \; 2>/dev/null || true
}

# ui
is_tty() { [[ -t 0 ]] && [[ -t 1 ]]; }

if is_tty && [[ -z "${GENVW_NO_COLOR:-}" ]]; then
  BOLD=$'\033[1m'
  DIM=$'\033[2m'
  RED=$'\033[31m'
  GREEN=$'\033[32m'
  YELLOW=$'\033[33m'
  BLUE=$'\033[34m'
  MAGENTA=$'\033[35m'
  CYAN=$'\033[36m'
  RESET=$'\033[0m'
else
  BOLD=''
  DIM=''
  RED=''
  GREEN=''
  YELLOW=''
  BLUE=''
  MAGENTA=''
  CYAN=''
  RESET=''
fi

# icons: prefer vs16 where needed (⚠️ 🛡️ 🗓️ ▶️ etc) to avoid text-glyph rendering

# colored emoji icons
# core
I_OK="✅"
I_WARN="⚠️"
I_ERR="❌"
I_INFO="ℹ️"

# actions / tools
I_TOOL="🛠️"
I_GEAR="⚙️"
I_WRENCH="🔧"
I_HAMMER="🔨"
I_BUILD="🏗️"
I_BOX="📦"
I_PACKAGE="$I_BOX"
I_TRASH="🗑️"
I_BROOM="🧹"
I_KEY="🔑"
I_LOCK="🔒"
I_UNLOCK="🔓"
I_LOCK_SEC="🔐"
I_SHIELD="🛡️"
I_TUNE="🎛️"

# flow / navigation
I_ARROW="➡️"
I_GO="▶️"
I_BACK="↩️"
I_NEXT="⏭️"
I_STOP="⏹️"
I_PAUSE="⏸️"
I_RETRY="🔁"
I_PLUS="➕"

# search / inspect / debug
I_SEARCH="🔎"
I_EYE="👀"
I_DOC="📄"
I_NOTE="📝"
I_CLIP="📎"
I_HASH="🔢"
I_BUG="🐛"
I_DEBUG="🧪"
I_PUZZLE="🧩"
I_TOOLBOX="🧰"
I_RECEIPT="🧾"
I_PIN="📌"
I_TARGET="🎯"
I_CHART="📊"

# downloads / network / files
I_DL="⬇️"
I_UL="⬆️"
I_LINK="🔗"
I_NET="🌐"
I_FILE="📁"
I_FOLDER="$I_FILE"
I_PATH="🧭"
I_SAVE="💾"

# steam / gaming context
I_GAME="🎮"
I_STEAM="$I_GAME"
I_ROCKET="🚀"
I_SPARK="✨"
I_FIRE="🔥"
I_ICE="🧊"
I_DESKTOP="🖥️"
I_NEW="🆕"
I_IDEA="💡"
I_DATE="🗓️"

# trust / validation
I_CHECK="✔️"
I_CHECKMARK="$I_CHECK"
I_X="✖️"
I_CROSS="✘️"
I_ALERT="🚨"
I_SIGN="✍️"
I_FINGERPRINT="🧬"
I_CERT="📜"

# emoji escape hatch
# clean logs / minimal terminals: disable emoji icons.
# message strings stay the same; only prefixes change.
if [[ "${GENVW_NO_EMOJI:-0}" == "1" ]]; then
  # core
  I_OK="[OK]"
  I_WARN="[WARNING]"
  I_ERR="[ERROR]"
  I_INFO="[INFO]"

  # actions / tools
  I_TOOL="[TOOL]"
  I_GEAR="[CONFIG]"
  I_WRENCH="[FIX]"
  I_HAMMER="[HIT]"
  I_BUILD="[BUILD]"
  I_BOX="[BOX]"
  I_PACKAGE="[PACKAGE]"
  I_TRASH="[DELETE]"
  I_BROOM="[CLEAN]"
  I_KEY="[KEY]"
  I_LOCK="[LOCK]"
  I_UNLOCK="[OPEN]"
  I_LOCK_SEC="[SECURE]"
  I_SHIELD="[SAFE]"
  I_TUNE="[TUNE]"

  # flow / navigation
  I_ARROW="->"
  I_GO=">>"
  I_BACK="<-"
  I_NEXT=">>|"
  I_STOP="[STOP]"
  I_PAUSE="[PAUSE]"
  I_RETRY="[RETRY]"
  I_PLUS="+"

  # search / inspect / debug
  I_SEARCH="[SEARCH]"
  I_EYE="[SEE]"
  I_DOC="[DOCUMENT]"
  I_NOTE="[NOTE]"
  I_CLIP="[CLIP]"
  I_HASH="[HASH]"
  I_BUG="[BUG]"
  I_DEBUG="[DEBUG]"
  I_PUZZLE="[PUZZLE]"
  I_TOOLBOX="[KIT]"
  I_RECEIPT="[META]"
  I_PIN="[PIN]"
  I_TARGET="[TARGET]"
  I_CHART="[CHART]"

  # downloads / network / files
  I_DL="[DL]"
  I_UL="[UL]"
  I_LINK="[LINK]"
  I_NET="[NET]"
  I_FILE="[FILE]"
  I_FOLDER="[DIR]"
  I_PATH="[PATH]"
  I_SAVE="[SAVE]"

  # steam / gaming context
  I_STEAM="[STEAM]"
  I_GAME="[GAME]"
  I_ROCKET="[RUN]"
  I_SPARK="[*]"
  I_FIRE="[HOT]"
  I_ICE="[COOL]"
  I_DESKTOP="[PC]"
  I_NEW="[NEW]"
  I_IDEA="[TIP]"
  I_DATE="[DATE]"

  # trust / validation
  I_CHECK="[YES]"
  I_CHECKMARK="[YES]"
  I_X="[NO]"
  I_CROSS="[NO]"
  I_ALERT="[!!]"
  I_SIGN="[SIGN]"
  I_FINGERPRINT="[FINGERPRINT]"
  I_CERT="[CERTIFICATE]"
fi

# message helpers
# plain printer (no prefix / color). good for multi-line blocks.
msg() { printf '%s\n' "$*"; }

# add the icon unless the line already starts with it.
# strip leading ansi sgr so colored callers still match the prefix check.
genvw_icon() {
  local icon="$1"
  shift
  local text="$*"

  # if icons are disabled/empty, just print the text.
  [[ -z "${icon}" ]] && {
    msg "${text}"
    return 0
  }

  # drop leading ansi sgr (e.g. \e[33m) before checking for an existing icon.
  local esc=$'\033'
  local plain="$text"
  local re
  re="^${esc}\\[[0-9;]*m(.*)$"
  while [[ "$plain" == "${esc}["* ]]; do
    if [[ "$plain" =~ $re ]]; then
      plain="${BASH_REMATCH[1]}"
      continue
    fi
    break
  done

  [[ "$plain" == "${icon}"* ]] && {
    msg "$text"
    return 0
  }
  msg "${icon} ${text}"
}

# ok (green) — completed steps and confirmations.
ok() { genvw_icon "${I_OK}" "${GREEN}$*${RESET}"; }
# warn (yellow) — non-fatal issues, attention needed.
warn() { genvw_icon "${I_WARN}" "${YELLOW}$*${RESET}"; }
# err (red, stderr) — failures, abort reasons, fatal checks.
err() { genvw_icon "${I_ERR}" "${RED}$*${RESET}" >&2; }
# info (cyan) — neutral messages (no decision implied).
info() { genvw_icon "${I_INFO}" "${CYAN}$*${RESET}"; }
# defaulted (cyan) — auto-picked setting.
defaulted() { genvw_icon "${I_PATH}" "${CYAN}$*${RESET}"; }
# fallback (yellow) — degraded path / plan b.
fallback() { genvw_icon "${I_BACK}" "${YELLOW}$*${RESET}"; }
# fix (wrench) — small adjustment (non-fatal).
fix() { genvw_icon "${I_WRENCH}" "${CYAN}$*${RESET}"; }
# choice (sliders) — user-selected setting.
choice() { genvw_icon "${I_TUNE}" "${CYAN}$*${RESET}"; }

# step prefix for "about to do something" lines.
# adds I_GO (▶️) unless icons are off.
# avoids double-prefix if the message already starts with it.
# keeps action output easy to scan
step() {
  local ico="${I_GO:-}"
  local s="$*"

  # icon off: print the line as-is.
  [[ -z "${ico}" ]] && {
    msg "$s"
    return 0
  }

  # already prefixed: don't add it twice.
  [[ "$s" == "${ico}"* ]] && {
    msg "$s"
    return 0
  }

  msg "${ico} ${s}"
}

# hint prefix for guidance / fyi lines.
# adds I_INFO (ℹ️) unless icons are off.
# avoids double-prefix if the message already starts with it.
hint() {
  local ico="${I_INFO}"
  local s="$*"
  [[ -z "${ico}" ]] && {
    msg "$s"
    return 0
  }
  [[ "$s" == "${ico}"* ]] && {
    msg "$s"
    return 0
  }
  msg "${ico} ${s}"
}

ask_yes_no_default() {
  # yes/no prompt. returns 0 for yes, 1 for no.
  # usage:
  #   if ask_yes_no_default "Prompt [Y/n]: " "y"; then ...; fi
  local prompt="${1:-}" default="${2:-y}" ans=""

  # normalize default to y/n (anything else becomes y)
  default="$(printf '%s' "$default" | tr '[:upper:]' '[:lower:]')"
  [[ "$default" == "n" ]] || default="y"

  # non-interactive: no prompt. obey default.
  if ! is_tty; then
    [[ "$default" == "y" ]] && return 0 || return 1
  fi

  # prompt + read via /dev/tty so pipes don't break it.
  # under setsid/no-ctty, /dev/tty can throw ENXIO; suppress that noise.
  if { printf '%s' "$prompt" >/dev/tty; } 2>/dev/null; then
    ans="$({ IFS= read -r line </dev/tty && printf '%s' "$line"; } 2>/dev/null)" || ans=""
  else
    printf '%s' "$prompt"
    IFS= read -r ans || ans=""
  fi

  ans="$(printf '%s' "$ans" | tr -d '[:space:]')"
  [[ -z "$ans" ]] && ans="$default"

  case "${ans,,}" in
    y | yes) return 0 ;;
    n | no) return 1 ;;
    *)
      warn "Invalid input: $ans"
      return 1
      ;;
  esac
}

# die: print error and exit 1.
die() {
  err "$*"
  exit 1
}

have() { command -v "$1" >/dev/null 2>&1; }

# verbose_on: returns 0 when verbose/debug output is on.
# keeps the default output short; dumps extra detail only when asked for.
verbose_on() {
  [[ "${GENVW_VERBOSE:-0}" == "1" || "${DEBUG:-0}" == "1" ]]
}

need_cmd() { have "$1" || die "Missing required command: $1"; }

# gpu guard (scope: amd rdna2/3/4)
_GENVW_DETECT_LINE=""

_genvw_score_line() {
  # prints: "SCORE GEN"
  # gen: 4 (rdna4), 3 (rdna3/3.5), 2 (rdna2), 0 (unknown)
  local s=0 g=0 line="$1"

  echo "$line" | grep -qiE 'gfx12' && {
    echo "400 4"
    return
  }

  echo "$line" | grep -qiE 'Navi[[:space:]]*4[0-9]' && {
    echo "400 4"
    return
  }
  echo "$line" | grep -qiE 'Radeon[[:space:]]+AI[[:space:]]+PRO' && {
    echo "400 4"
    return
  }
  echo "$line" | grep -qiE 'RX[[:space:]]*9[0-9]{3}' && {
    echo "390 4"
    return
  }

  echo "$line" | grep -qiE 'gfx11' && {
    echo "300 3"
    return
  }

  echo "$line" | grep -qiE 'Navi[[:space:]]*3[0-9]' && {
    echo "300 3"
    return
  }
  echo "$line" | grep -qiE 'RX[[:space:]]*7[0-9]{3}' && {
    echo "290 3"
    return
  }
  echo "$line" | grep -qiE 'Radeon[[:space:]]*(840M|860M|880M|890M|8040S|8050S|8060S)' && {
    echo "301 3"
    return
  }
  echo "$line" | grep -qiE 'Radeon[[:space:]]*(740M|760M|780M)' && {
    echo "300 3"
    return
  }
  echo "$line" | grep -qiE 'Z2[[:space:]]*Extreme' && {
    echo "300 3"
    return
  }

  echo "$line" | grep -qiE 'gfx10' && {
    echo "200 2"
    return
  }

  echo "$line" | grep -qiE 'Navi[[:space:]]*2[0-9]' && {
    echo "200 2"
    return
  }
  echo "$line" | grep -qiE 'RX[[:space:]]*6[0-9]{3}' && {
    echo "190 2"
    return
  }
  echo "$line" | grep -qiE 'Radeon[[:space:]]*(660M|680M)' && {
    echo "200 2"
    return
  }

  echo "0 0"
}

_genvw_pick_best_amd_line() {
  # Prefer AMD DRM cards (cardN) if present; otherwise scan lspci output.
  local best_score=-1 best_line="" c addr line score gen

  if have lspci && [ -d /sys/class/drm ]; then
    for c in /sys/class/drm/card*; do
      # Only accept real card nodes: card0, card1, ... card10, ...
      # Skip connector nodes like: card0-DP-1, card1-HDMI-A-1, etc.
      [[ "$(basename "$c")" =~ ^card[0-9]+$ ]] || continue

      [ -e "$c/device/vendor" ] || continue

      # 0x1002 is amd pci vendor id.
      [ "$(cat "$c/device/vendor" 2>/dev/null || true)" = "0x1002" ] || continue

      # follow the device link so we get a bdf for `lspci -s`.
      addr="$(basename "$(readlink -f "$c/device" 2>/dev/null || true)")"

      [ -n "$addr" ] || continue
      line="$(lspci -nn -s "$addr" 2>/dev/null || true)"
      [ -n "$line" ] || continue

      read -r score gen < <(_genvw_score_line "$line")
      if [ "$score" -gt "$best_score" ]; then
        best_score="$score"
        best_line="$line"
      fi
    done
  fi

  if [ -z "$best_line" ] && have lspci; then
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      read -r score gen < <(_genvw_score_line "$line")
      if [ "$score" -gt "$best_score" ]; then
        best_score="$score"
        best_line="$line"
      fi
    done < <(lspci -nn | grep -Ei 'VGA|3D|Display' | grep -Ei 'AMD|ATI' || true)
  fi

  printf '%s' "$best_line"
}

# shim for old patch drafts: _genvw_best_lspci_line() used to exist.
_genvw_best_lspci_line() {
  _genvw_pick_best_amd_line
}

genvw_detect_rdna_gen() {
  # prints gen and sets _GENVW_DETECT_LINE.
  if ! have lspci; then
    _GENVW_DETECT_LINE=""
    echo 0
    return
  fi

  _GENVW_DETECT_LINE="$(_genvw_pick_best_amd_line)"
  if [ -z "$_GENVW_DETECT_LINE" ]; then
    echo 0
    return
  fi

  local score gen
  read -r score gen < <(_genvw_score_line "$_GENVW_DETECT_LINE")
  echo "$gen"
}

# normalize_bdf
#
# dri_prime notes:
# - dri_prime=1 is a common offload hint, not a reliable selector here.
# - drm card numbering can change between boots.
#
# selection policy:
# - only treat dri_prime as deterministic when it can be normalized to a pci bdf.
# - numeric values (like "1") are hints at most.
#
# handy:
#   lspci -nn | grep -Ei 'VGA|3D|Display'
#   DRI_PRIME=0000:BB:DD.F genvw proton gpu
normalize_bdf() {
  # turns common dri_prime forms into a pci bdf (0000:BB:DD.F).
  local v="${1:-}"

  # vulkan sometimes appends '!' to selectors; strip it.
  while [[ "$v" == *"!" ]]; do
    v="${v%?}"
  done

  # mesa prefix, when present.
  v="${v#pci-}"

  # 0000_BB_DD_F -> 0000:BB:DD.F
  if [[ "$v" =~ ^([0-9A-Fa-f]{4})_([0-9A-Fa-f]{2})_([0-9A-Fa-f]{2})_([0-7])$ ]]; then
    printf '%s:%s:%s.%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}"
    return 0
  fi

  # BB_DD_F -> 0000:BB:DD.F
  if [[ "$v" =~ ^([0-9A-Fa-f]{2})_([0-9A-Fa-f]{2})_([0-7])$ ]]; then
    printf '0000:%s:%s.%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
    return 0
  fi

  # 0000:BB:DD.F -> 0000:BB:DD.F
  if [[ "$v" =~ ^[0-9A-Fa-f]{4}:[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}\.[0-7]$ ]]; then
    printf '%s' "$v"
    return 0
  fi

  # BB:DD.F -> 0000:BB:DD.F
  if [[ "$v" =~ ^[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}\.[0-7]$ ]]; then
    printf '0000:%s' "$v"
    return 0
  fi

  return 1
}

genvw_detect_rdna_gen_into_vars() {
  # sets:
  #   GENVW_RDNA_GEN (0/2/3/4)
  #   GENVW_GPU_LINE (best-match lspci line; honors DRI_PRIME bdf when given)
  GENVW_RDNA_GEN=0
  GENVW_GPU_LINE=""

  if ! have lspci; then
    return 0
  fi

  # honor user intent when DRI_PRIME is set.
  # bdf forms:
  #   - 0000:03:00.0 / 03:00.0
  #   - pci-0000:03:00.0
  #   - pci-0000_03_00_0
  # also supports the local heuristic: DRI_PRIME=1 prefers /sys/class/drm/card1 if it's amd.
  if [ -n "${DRI_PRIME-}" ]; then
    local _dp="${DRI_PRIME}"

    # don't strip '!' here. normalize_bdf owns that.
    :

    # match genvw: DRI_PRIME=1 -> prefer amd card1 when present.
    if [ "${_dp}" = "1" ]; then
      if [ -e /sys/class/drm/card1/device/vendor ] && [ "$(cat /sys/class/drm/card1/device/vendor 2>/dev/null || true)" = "0x1002" ]; then
        local _addr="" _line=""
        _addr="$(basename "$(readlink -f /sys/class/drm/card1/device 2>/dev/null || true)")"
        if [ -n "${_addr}" ]; then
          _line="$(lspci -nn -s "${_addr}" 2>/dev/null | head -n 1 || true)"
          if [ -n "${_line}" ]; then
            GENVW_GPU_LINE="${_line}"
            local score gen
            read -r score gen < <(_genvw_score_line "${_line}")
            GENVW_RDNA_GEN="${gen:-0}"
            return 0
          fi
        fi
      fi
    fi

    # DRI_PRIME=0 means "no steering".
    if [ "${_dp}" != "0" ]; then
      local _bdf="" _line=""
      _bdf="$(normalize_bdf "${_dp}" 2>/dev/null)" || _bdf=""
      if [ -n "${_bdf}" ]; then
        _line="$(lspci -nn -s "${_bdf}" 2>/dev/null | head -n 1 || true)"
        if [ -n "${_line}" ]; then
          GENVW_GPU_LINE="${_line}"
          local score gen
          read -r score gen < <(_genvw_score_line "${_line}")
          GENVW_RDNA_GEN="${gen:-0}"
          return 0
        fi
      fi
    fi
  fi

  # fallback: best scoring amd vga/3d/display line.
  local best_line=""
  best_line="$(_genvw_best_lspci_line)"
  if [ -n "$best_line" ]; then
    GENVW_GPU_LINE="$best_line"
    local score gen
    read -r score gen < <(_genvw_score_line "$best_line")
    GENVW_RDNA_GEN="${gen:-0}"
  fi
  return 0
}

genvw_gpu_debug_info() {
  echo "GPU debug:"
  if have lspci; then
    echo "  lspci (VGA/3D/Display):"
    lspci -nn | grep -Ei 'VGA|3D|Display' | sed 's/^/    /' || true
  else
    echo "  lspci: (missing)  — install pciutils"
  fi

  echo "  /sys/class/drm vendors (card0..card9):"
  local c v any=0
  for c in /sys/class/drm/card*; do
    # only real card nodes here (card0, card1, ...).
    # skip connector entries like card0-DP-1, card1-HDMI-A-1.
    [[ "$(basename "$c")" =~ ^card[0-9]+$ ]] || continue
    [ -e "$c/device/vendor" ] || continue
    v="$(cat "$c/device/vendor" 2>/dev/null || true)"
    echo "    $(basename "$c"): $v"
    any=1
  done
  [ "$any" -eq 0 ] && echo "    (none found)"
}

genvw_require_supported_gpu() {
  # hard stop unless we see amd rdna2/3/4.
  if [ "${GENVW_SKIP_GPU_CHECK:-0}" = "1" ]; then
    return 0
  fi

  genvw_detect_rdna_gen_into_vars
  local gen="$GENVW_RDNA_GEN"
  if [ "$gen" = "2" ] || [ "$gen" = "3" ] || [ "$gen" = "4" ]; then
    return 0
  fi

  echo
  err "Unsupported GPU for gENVW Proton helper."
  msg "gENVW is intended for AMD RDNA2/3/4 class GPUs (RDNA2 support is limited)."
  case "$gen" in
    2) msg "Detected: AMD RDNA2 (limited support)." ;;
    0) msg "Detected: unknown / not AMD / could not classify (RDNA_GEN=0)." ;;
    *) msg "Detected: RDNA_GEN=$gen (unsupported)." ;;
  esac
  if [ -n "$GENVW_GPU_LINE" ]; then
    msg
    msg "Best-match device line:"
    msg "  $GENVW_GPU_LINE"
  fi
  msg
  genvw_gpu_debug_info
  msg
  msg "Tip: On hybrid systems try: DRI_PRIME=1 genvw proton check"
  msg "     Or explicitly: DRI_PRIME=0000:03:00.0 genvw proton check"
  return 2
}

# genvw_warn_if_unsupported_gpu
genvw_warn_if_unsupported_gpu() {
  # warn-only if we don't see amd rdna2/3/4.
  if [ "${GENVW_SKIP_GPU_CHECK:-0}" = "1" ]; then
    return 0
  fi
  genvw_detect_rdna_gen_into_vars
  local gen="$GENVW_RDNA_GEN"
  if [ "$gen" = "2" ] || [ "$gen" = "3" ] || [ "$gen" = "4" ]; then
    return 0
  fi
  warn "No supported RDNA2/3/4 GPU detected (RDNA_GEN=$gen)."
  warn "You can still run this command, but FSR4-related features won't work on this system."
  if [ -n "$GENVW_GPU_LINE" ]; then
    warn "Best-match device line:"
    warn "  $GENVW_GPU_LINE"
  fi
  return 0
}

# steam integration (native + flatpak)
STEAM_KIND=""
STEAM_ROOT=""
STEAM_CTD_CHOSEN=""
STEAM_CTD_SOURCES=0

# steam_ps_summary
steam_ps_summary() {
  # reads `ps`-style lines on stdin and prints a one-line steam process summary.
  awk '
    BEGIN{total=0; steam=0; web=0; svc=0; def=0}
    {
      total++
      if ($0 ~ /(^|[[:space:]])steam([[:space:]]|$)/ || $0 ~ /\/steam([[:space:]]|$)/ || $0 ~ /\/steam\.sh([[:space:]]|$)/) steam=1
      if ($0 ~ /steamwebhelper/) web++
      if ($0 ~ /steamservice/) svc++
      if ($0 ~ /<defunct>/) def++
    }
    END {
      printf "summary: total=%d steam=%d steamwebhelper=%d steamservice=%d defunct=%d\n", total, steam, web, svc, def
    }
  '
}

# steam_ps_brief
# small ps summary: one steam line, one steamwebhelper, one wrapper/runtime marker.
# keeps the debug output short unless GENVW_STEAM_VERBOSE=1.
# intentional reserve helper for future debug output paths.
steam_ps_brief() {
  # hides common steam sandbox noise (pressure-vessel, srt-bwrap, srt-logger).
  awk '
    function trunc(s, n) { return (length(s) > n) ? substr(s,1,n) "…" : s }

    /pressure-vessel|pv-adverb|srt-bwrap|srt-logger/ { next }

    {
      raw=$0
      line=trunc(raw, 170)

      if (!steam && raw ~ /(^|[[:space:]])steam([[:space:]]|$)|\/steam([[:space:]]|$)|\/steam\.sh([[:space:]]|$)/) {
        steam=line; picked++
      }
      else if (!web && raw ~ /steamwebhelper/) {
        web=line; picked++
      }
      else if (!wrap && raw ~ /(steam-launch-wrapper|steam-runtime|com\.valvesoftware\.Steam|flatpak|bwrap)/) {
        wrap=line; picked++
      }
      else {
        hidden++
      }
    }

    END {
      if (steam) print steam
      if (web) print web
      if (wrap) print wrap
      if (hidden > 0) printf "(… %d more hidden; set GENVW_STEAM_VERBOSE=1 for full list)\n", hidden
    }
  '
}

# steam detection (native + flatpak)

steam_ps_lines() {
  # prints matching steam-ish processes; empty output means "not running".
  if have pgrep; then
    {
      # native steam + helpers (match by comm)
      pgrep -a -x steam 2>/dev/null || true
      pgrep -a -x steamwebhelper 2>/dev/null || true
      pgrep -a -x steamservice 2>/dev/null || true

      # if steam is a wrapper script or launched differently, match args too
      pgrep -a -f '(^|/)(steam|steam\.sh)([[:space:]]|$)' 2>/dev/null || true
      pgrep -a -f 'steamwebhelper' 2>/dev/null || true

      # wrapper/runtime patterns
      pgrep -a -f 'steam-launch-wrapper|steam-runtime' 2>/dev/null || true

      # flatpak / sandbox wrappers
      pgrep -a -f 'flatpak.*com\.valvesoftware\.Steam' 2>/dev/null || true
      pgrep -a -f 'bwrap.*com\.valvesoftware\.Steam' 2>/dev/null || true
      pgrep -a -f 'com\.valvesoftware\.Steam' 2>/dev/null || true
    } | awk '!seen[$1]++' # de-dupe by pid
  else
    # fallback when pgrep is missing (minimal env)
    ps -eo pid=,comm=,args= 2>/dev/null | awk '
      $2=="steam" || $2=="steamwebhelper" || $2=="steamservice" {print; next}
      $0 ~ /(^|\/)(steam|steam\.sh)([[:space:]]|$)/ {print; next}
      $0 ~ /(steam-launch-wrapper|steam-runtime)/ {print; next}
      $0 ~ /(flatpak.*com\.valvesoftware\.Steam|bwrap.*com\.valvesoftware\.Steam|com\.valvesoftware\.Steam)/ {print; next}
    '
  fi
}

# steam_is_running: boolean wrapper around steam_ps_lines.
steam_is_running() {
  local _out
  _out="$(steam_ps_lines 2>/dev/null || true)"
  [[ -n "${_out//[[:space:]]/}" ]]
}

steam_running() { steam_is_running; }

# rm_rf_within_root
# bounded delete helper for rm -rf
# deletes only paths proven to live under a chosen root
rm_rf_within_root() {
  local root="${1:-}" target="${2:-}"
  [[ -n "$root" && -n "$target" ]] || return 1

  # strip trailing slashes to avoid "symlink/" corner-cases.
  root="${root%/}"
  target="${target%/}"

  [[ "$root" == /* && "$root" != "/" ]] || return 1
  [[ "$target" != "/" && "$target" != "$HOME" ]] || return 1
  [[ -e "$target" || -L "$target" ]] || return 1

  # if target is a symlink, delete the link itself (don't follow it).
  # avoids deleting outside-root paths through a link.
  if [[ -L "$target" ]]; then
    if command -v realpath >/dev/null 2>&1; then
      local root_ns target_ns
      root_ns="$(realpath -ms -- "$root" 2>/dev/null || true)"
      target_ns="$(realpath -ms -- "$target" 2>/dev/null || true)"
      [[ -n "$root_ns" && -n "$target_ns" && "$target_ns" == "$root_ns/"* ]] || return 1
    else
      [[ "$target" == "$root/"* ]] || return 1
    fi
    rm -f -- "$target"
    return $?
  fi

  [[ -d "$target" ]] || return 1

  if command -v realpath >/dev/null 2>&1; then
    local root_r target_r
    root_r="$(realpath -m -- "$root" 2>/dev/null || true)"
    target_r="$(realpath -m -- "$target" 2>/dev/null || true)"
    [[ -n "$root_r" && -n "$target_r" && "$target_r" == "$root_r/"* ]] || return 1
  else
    [[ "$target" == "$root/"* ]] || return 1
  fi

  rm -rf -- "$target"
}

rm_f_within_root() {
  local root="${1:-}" target="${2:-}"
  [[ -n "$root" && -n "$target" ]] || return 1

  root="${root%/}"
  target="${target%/}"

  [[ "$root" == /* && "$root" != "/" ]] || return 1
  [[ "$target" != "/" && "$target" != "$HOME" ]] || return 1
  [[ -f "$target" || -L "$target" ]] || return 1

  if command -v realpath >/dev/null 2>&1; then
    local root_r target_r
    if [[ -L "$target" ]]; then
      root_r="$(realpath -ms -- "$root" 2>/dev/null || true)"
      target_r="$(realpath -ms -- "$target" 2>/dev/null || true)"
    else
      root_r="$(realpath -m -- "$root" 2>/dev/null || true)"
      target_r="$(realpath -m -- "$target" 2>/dev/null || true)"
    fi
    [[ -n "$root_r" && -n "$target_r" && "$target_r" == "$root_r/"* ]] || return 1
  else
    [[ "$target" == "$root/"* ]] || return 1
  fi

  rm -f -- "$target"
}

amd_shared_upscalers_root() {
  printf '%s\n' "${HOME}/.cache/protonfixes/upscalers"
}

amd_is_protected_shared_upscalers_path() {
  local path="${1:-}"
  [[ -n "$path" ]] || return 1

  local shared_root local_root
  shared_root="$(amd_shared_upscalers_root)"
  local_root="${shared_root}/genvw"

  local path_r shared_r local_r
  if command -v realpath >/dev/null 2>&1; then
    path_r="$(realpath -m -- "$path" 2>/dev/null || true)"
    shared_r="$(realpath -m -- "$shared_root" 2>/dev/null || true)"
    local_r="$(realpath -m -- "$local_root" 2>/dev/null || true)"
  else
    path_r="${path%/}"
    shared_r="${shared_root%/}"
    local_r="${local_root%/}"
  fi

  [[ -n "$path_r" && -n "$shared_r" && -n "$local_r" ]] || return 1
  [[ "$path_r" == "$shared_r" || "$path_r" == "$shared_r/"* ]] || return 1
  [[ "$path_r" == "$local_r" || "$path_r" == "$local_r/"* ]] && return 1
  return 0
}

amd_require_local_cache_delete_root() {
  local dst_dir="${1:-}"
  [[ -n "$dst_dir" ]] || die "internal: missing DLL cache directory"
  if amd_is_protected_shared_upscalers_path "$dst_dir"; then
    die "Refusing to delete shared Proton upscaler cache entries outside genvw: $dst_dir"
  fi
}

amd_remote_cache_dir_from_local_dir() {
  local dst_dir="${1:-}"
  [[ -n "$dst_dir" ]] || return 1

  dst_dir="${dst_dir%/}"
  [[ "${dst_dir##*/}" == "genvw" ]] || return 1

  local parent="${dst_dir%/*}"
  [[ -n "$parent" && "$parent" != "$dst_dir" ]] || return 1
  [[ "${parent##*/}" == "upscalers" ]] || return 1

  printf '%s\n' "$parent"
}

# pretty command strings (prefer genvw wrapper when installed)

# cmd_proton: prints the command prefix used in help text.
cmd_proton() {
  # genvw installed: use `genvw proton ...`
  # fallback: call this script directly.
  if have genvw; then
    printf '%s\n' "genvw proton"
  else
    printf '%s\n' "genvw_proton.sh"
  fi
}

# cmd_dll: prints the dll subcommand prefix used in help text.
cmd_dll() {
  if have genvw; then
    printf '%s\n' "genvw proton dll"
  else
    printf '%s\n' "genvw_proton.sh dll"
  fi
}

major_selection_is_all_supported() {
  [[ "${GENVW_MAJOR_SELECTION_MODE:-explicit}" == "all_supported" ]]
}

major_selection_label() {
  if major_selection_is_all_supported; then
    printf '%s\n' "all supported local majors"
  else
    printf '%s\n' "${MAJOR:-$MAJOR_DEFAULT}"
  fi
}

major_selection_error_label() {
  if major_selection_is_all_supported; then
    printf '%s\n' "all supported majors"
  else
    printf 'major=%s\n' "${MAJOR:-$MAJOR_DEFAULT}"
  fi
}

source_major_mode_is_all_supported() {
  [[ "${1:-explicit}" == "all_supported" ]]
}

source_major_matches_selection() {
  local src_major="${1:-}"
  if major_selection_is_all_supported; then
    [[ "$src_major" =~ ^[0-9]+(\.[0-9]+)?$ ]]
  else
    [[ "$src_major" == "${MAJOR:-$MAJOR_DEFAULT}" ]]
  fi
}

# steam_detect_ctd: pick a compatibilitytools.d path (native or flatpak).
steam_detect_ctd() {
  # prefers a ctd that has proton-cachyos sources.
  # override with --ctd /path/to/compatibilitytools.d.
  local major="${1:-$MAJOR_DEFAULT}"
  local major_mode="${2:-${GENVW_MAJOR_SELECTION_MODE:-explicit}}"
  if [[ ! "$major" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    major="$MAJOR_DEFAULT"
  fi
  local -a cands=()
  local min_date="${MIN_SUPPORTED_DATE_GENVW:-20251222}"
  [[ "$min_date" =~ ^[0-9]{8}$ ]] || min_date=20251222
  local suffix_default="${SUFFIX_DEFAULT:-gENVW}"
  local had_nullglob=0

  # extra candidates for testing / odd layouts
  if [[ -n "${GENVW_CTD_CANDIDATES:-}" ]]; then
    local IFS=':'
    read -r -a cands <<<"${GENVW_CTD_CANDIDATES}"
  fi
  local xdg_data="${XDG_DATA_HOME:-$HOME/.local/share}"
  cands+=(
    "${xdg_data}/Steam/compatibilitytools.d"
    "${HOME}/.local/share/Steam/compatibilitytools.d"
    "${HOME}/.steam/root/compatibilitytools.d"
    "${HOME}/.steam/steam/compatibilitytools.d"
    "${HOME}/.steam/compatibilitytools.d"
    "${HOME}/.var/app/com.valvesoftware.Steam/data/Steam/compatibilitytools.d"
  )

  local best="" best_count=-1
  local p count
  shopt -q nullglob && had_nullglob=1
  shopt -s nullglob
  # By design, source scans ignore symlinked clone dirs.
  # Why: keep auto-detect/source counts anchored to real directories under CTD.
  # Impact: symlink-only clone layouts are treated as having no eligible sources.
  for p in "${cands[@]}"; do
    [[ -d "$p" ]] || continue
    count="$(source_ctd_supported_source_count "$p" "$major" "$min_date" "$suffix_default" "$major_mode")"
    if ((count > best_count)); then
      best="$p"
      best_count=$count
    fi
  done

  # if we found a ctd but it has zero sources, scan under $HOME for another one.
  # bounded depth + prunes keep it from going wild.
  if ((best_count == 0)) && have find; then
    local scan_best="" scan_best_count=0
    local p2 count2
    while IFS= read -r p2; do
      [[ -d "$p2" ]] || continue
      # Same policy as the primary scan above: ignore symlinked clone dirs.
      count2="$(source_ctd_supported_source_count "$p2" "$major" "$min_date" "$suffix_default" "$major_mode")"
      if ((count2 > scan_best_count)); then
        scan_best="$p2"
        scan_best_count=$count2
      fi
    done < <(find "$HOME" -maxdepth 7 \
      \( -path "$HOME/.cache" -o -path "$HOME/.cache/*" \
      -o -path "$HOME/Downloads" -o -path "$HOME/Downloads/*" \
      -o -path "$HOME/.local/share/Trash" -o -path "$HOME/.local/share/Trash/*" \
      -o -path "$HOME/.var/app/*/cache" -o -path "$HOME/.var/app/*/cache/*" \
      \) -prune -o -type d -name compatibilitytools.d -print 2>/dev/null)

    if ((scan_best_count > best_count)); then
      best="$scan_best"
      best_count=$scan_best_count
    fi
  fi

  if [[ -z "$best" ]]; then
    best="${HOME}/.local/share/Steam/compatibilitytools.d"
    best_count=0
  fi
  ((had_nullglob == 1)) || shopt -u nullglob

  STEAM_CTD_CHOSEN="$best"
  STEAM_CTD_SOURCES="$best_count"
  STEAM_ROOT="$(dirname "$best")"

  if [[ "$best" == *"/.var/app/com.valvesoftware.Steam/"* ]]; then
    STEAM_KIND="flatpak"
  else
    STEAM_KIND="native"
  fi
}

# steam_print_detected
steam_print_detected() {
  local major="${1:-$MAJOR_DEFAULT}"
  local major_label="$major"
  if major_selection_is_all_supported; then
    major_label="all supported local majors"
  fi
  msg "${I_PUZZLE} Steam integration:"
  if ((STEAM_CTD_SOURCES == 0)); then
    msg "  • Steam kind: $STEAM_KIND (guessed)"
  else
    msg "  • Steam kind: $STEAM_KIND"
  fi
  msg "  • Steam root: $STEAM_ROOT"
  msg "  • compatibilitytools.d: $CTD"
  msg "  • Eligible Proton-CachyOS sources here ($major_label, >= ${MIN_SUPPORTED_DATE_GENVW:-20251222}): $STEAM_CTD_SOURCES"
  if ((STEAM_CTD_SOURCES == 0)); then
    msg "  ${I_INFO} Auto-detect tried common paths and a bounded scan under $HOME."
    msg "    If this still shows 0 sources, pass --ctd /path/to/Steam/compatibilitytools.d or set GENVW_CTD_CANDIDATES=/path/one:/path/two"
  fi
  if steam_is_running; then
    warn "Steam is running. This is OK for 'check/status'."
    warn "Rebuild is blocked while Steam is running (unless you pass --allow-steam)."
  fi

}

# source_metadata_record:
# normalize a Proton-CachyOS source path into a canonical base + fields.
# Supports both:
# - user-style versioned source dirs in compatibilitytools.d
# - packaged system dirs like /usr/share/steam/compatibilitytools.d/proton-cachyos[-slr]
source_metadata_record() {
  local src="${1:-}"
  local base="${src##*/}"
  local rec="" major="" date="" runtime="" arch=""
  local line="" token="" display=""

  rec="$(source_user_metadata_record_from_base "$base" 2>/dev/null || true)"
  if [[ -n "$rec" ]]; then
    printf '%s\n' "$rec"
    return 0
  fi

  case "$base" in
    proton-cachyos | proton-cachyos-slr)
      if [[ -r "$src/version" ]]; then
        IFS= read -r line <"$src/version" || true
        line="${line//$'\r'/}"
        token="${line#* }"
        if [[ "$token" =~ ^cachyos-([0-9]+([.][0-9]+)?)-([0-9]{8})-(native|slr)$ ]]; then
          major="${BASH_REMATCH[1]}"
          date="${BASH_REMATCH[3]}"
          runtime="${BASH_REMATCH[4]}"
        fi
      fi

      if [[ -r "$src/compatibilitytool.vdf" ]]; then
        display="$(awk -F'"' '$2=="display_name"{print $4; exit}' "$src/compatibilitytool.vdf" 2>/dev/null || true)"
        if [[ -z "$major" || -z "$date" ]]; then
          if [[ "$display" =~ proton-cachyos-([0-9]+([.][0-9]+)?)-([0-9]{8}) ]]; then
            major="${BASH_REMATCH[1]}"
            date="${BASH_REMATCH[3]}"
          fi
        fi
        if [[ -z "$runtime" ]]; then
          case "$display" in
            *"(native)"*) runtime="native" ;;
            *"(steam linux runtime)"*) runtime="slr" ;;
          esac
        fi
      fi

      if [[ -z "$runtime" ]]; then
        case "$base" in
          proton-cachyos-slr) runtime="slr" ;;
          proton-cachyos) runtime="native" ;;
        esac
      fi

      [[ -n "$major" && -n "$date" && -n "$runtime" ]] || return 1
      arch="system-x86_64"
      printf 'proton-cachyos-%s-%s-%s-%s|%s|%s|%s|%s\n' \
        "$major" "$date" "$runtime" "$arch" "$major" "$date" "$runtime" "$arch"
      return 0
      ;;
  esac

  return 1
}

source_user_metadata_record_from_base() {
  local base="${1:-}"
  local major="" date="" runtime="" arch=""

  if [[ "$base" =~ ^proton-cachyos-([0-9]+([.][0-9]+)?)-([0-9]{8})-(native|slr)-(x86_64(_v[1-4])?)$ ]]; then
    major="${BASH_REMATCH[1]}"
    date="${BASH_REMATCH[3]}"
    runtime="${BASH_REMATCH[4]}"
    arch="${BASH_REMATCH[5]}"
    printf '%s|%s|%s|%s|%s\n' "$base" "$major" "$date" "$runtime" "$arch"
    return 0
  fi

  if [[ "$base" =~ ^proton-cachyos-([0-9]+([.][0-9]+)?)-([0-9]{8})-(x86_64(_v[1-4])?)$ ]]; then
    major="${BASH_REMATCH[1]}"
    date="${BASH_REMATCH[3]}"
    runtime="${BASH_REMATCH[4]}"
    arch="${BASH_REMATCH[4]}"
    printf '%s|%s|%s|%s|%s\n' "$base" "$major" "$date" "$runtime" "$arch"
    return 0
  fi

  if [[ "$base" =~ ^cachyos-([0-9]+([.][0-9]+)?)-([0-9]{8})-(native|slr)$ ]]; then
    major="${BASH_REMATCH[1]}"
    date="${BASH_REMATCH[3]}"
    runtime="${BASH_REMATCH[4]}"
    arch="protonplus-unspecified"
    printf 'proton-cachyos-%s-%s-%s-%s|%s|%s|%s|%s\n' \
      "$major" "$date" "$runtime" "$arch" "$major" "$date" "$runtime" "$arch"
    return 0
  fi

  return 1
}

source_ctd_supported_source_count() {
  local root="${1:-}" major="${2:-}" min_date="${3:-}" suffix_effective="${4:-}" major_mode="${5:-explicit}"
  local suffix_default="${SUFFIX_DEFAULT:-gENVW}"
  local count=0 p="" base="" rec="" parsed="" src_major="" src_date=""
  local had_nullglob=0
  local -a source_globs=()

  [[ -d "$root" ]] || {
    printf '%s\n' 0
    return 0
  }
  [[ "$min_date" =~ ^[0-9]{8}$ ]] || min_date=20251222

  shopt -q nullglob && had_nullglob=1
  shopt -s nullglob
  if source_major_mode_is_all_supported "$major_mode"; then
    source_globs=("$root"/proton-cachyos-* "$root"/cachyos-*)
  else
    source_globs=("$root"/proton-cachyos-"$major"-* "$root"/cachyos-"$major"-*)
  fi
  for p in "${source_globs[@]}"; do
    [[ -d "$p" && ! -L "$p" ]] || continue
    base="${p##*/}"
    [[ "$base" == *"-${suffix_default}" ]] && continue
    [[ -n "$suffix_effective" && "$base" == *"-${suffix_effective}" ]] && continue
    rec="$(source_metadata_record "$p" 2>/dev/null || true)"
    [[ -n "$rec" ]] || continue
    parsed="${rec#*|}"
    src_major="${parsed%%|*}"
    parsed="${parsed#*|}"
    src_date="${parsed%%|*}"
    if ! source_major_mode_is_all_supported "$major_mode"; then
      [[ "$src_major" == "$major" ]] || continue
    fi
    [[ "$src_date" =~ ^[0-9]{8}$ ]] || continue
    ((10#$src_date >= 10#$min_date)) || continue
    ((count += 1))
  done
  ((had_nullglob == 1)) || shopt -u nullglob

  printf '%s\n' "$count"
}

source_effective_base() {
  local src="${1:-}" rec=""
  rec="$(source_metadata_record "$src" 2>/dev/null || true)"
  if [[ -n "$rec" ]]; then
    printf '%s\n' "${rec%%|*}"
    return 0
  fi
  printf '%s\n' "${src##*/}"
}

source_clone_identity_metadata_record() {
  local src="${1:-}" rec="" parsed="" base="" major="" date="" runtime="" arch=""
  local vdf_rec="" vdf_parsed="" vdf_major="" vdf_date="" vdf_runtime="" vdf_arch=""

  rec="$(source_metadata_record "$src" 2>/dev/null || true)"
  [[ -n "$rec" ]] || return 1

  parsed="${rec#*|}"
  base="${rec%%|*}"
  major="${parsed%%|*}"
  parsed="${parsed#*|}"
  date="${parsed%%|*}"
  parsed="${parsed#*|}"
  runtime="${parsed%%|*}"
  arch="${parsed#*|}"

  if [[ "$arch" != "protonplus-unspecified" ]]; then
    printf '%s\n' "$rec"
    return 0
  fi

  vdf_rec="$(source_vdf_metadata_record "$src" 2>/dev/null || true)"
  [[ -n "$vdf_rec" ]] || {
    printf '%s\n' "$rec"
    return 0
  }

  vdf_parsed="${vdf_rec#*|}"
  vdf_major="${vdf_parsed%%|*}"
  vdf_parsed="${vdf_parsed#*|}"
  vdf_date="${vdf_parsed%%|*}"
  vdf_parsed="${vdf_parsed#*|}"
  vdf_runtime="${vdf_parsed%%|*}"
  vdf_arch="${vdf_parsed#*|}"

  if [[ "$major" == "$vdf_major" && "$date" == "$vdf_date" && "$runtime" == "$vdf_runtime" ]]; then
    arch="protonplus-${vdf_arch}"
    base="proton-cachyos-${major}-${date}-${runtime}-${arch}"
    printf '%s|%s|%s|%s|%s\n' "$base" "$major" "$date" "$runtime" "$arch"
    return 0
  fi

  printf '%s\n' "$rec"
}

source_clone_vdf_source_base() {
  local src="${1:-}" rec="" parsed="" major="" date="" runtime="" arch=""
  local vdf_rec="" vdf_parsed="" vdf_base="" vdf_major="" vdf_date="" vdf_runtime=""

  rec="$(source_metadata_record "$src" 2>/dev/null || true)"
  [[ -n "$rec" ]] || {
    printf '%s\n' "${src##*/}"
    return 0
  }

  parsed="${rec#*|}"
  major="${parsed%%|*}"
  parsed="${parsed#*|}"
  date="${parsed%%|*}"
  parsed="${parsed#*|}"
  runtime="${parsed%%|*}"
  arch="${parsed#*|}"
  [[ "$arch" == "protonplus-unspecified" ]] || {
    printf '%s\n' "${src##*/}"
    return 0
  }

  vdf_rec="$(source_vdf_metadata_record "$src" 2>/dev/null || true)"
  [[ -n "$vdf_rec" ]] || {
    printf '%s\n' "${src##*/}"
    return 0
  }

  vdf_base="${vdf_rec%%|*}"
  vdf_parsed="${vdf_rec#*|}"
  vdf_major="${vdf_parsed%%|*}"
  vdf_parsed="${vdf_parsed#*|}"
  vdf_date="${vdf_parsed%%|*}"
  vdf_parsed="${vdf_parsed#*|}"
  vdf_runtime="${vdf_parsed%%|*}"

  if [[ "$major" == "$vdf_major" && "$date" == "$vdf_date" && "$runtime" == "$vdf_runtime" ]]; then
    printf '%s\n' "$vdf_base"
    return 0
  fi

  printf '%s\n' "${src##*/}"
}

source_build_date() {
  local src="${1:-}" rec="" parsed=""
  rec="$(source_metadata_record "$src" 2>/dev/null || true)"
  if [[ -n "$rec" ]]; then
    parsed="${rec#*|}"
    parsed="${parsed#*|}"
    printf '%s\n' "${parsed%%|*}"
    return 0
  fi
  extract_build_date_from_name "${src##*/}"
}

dxvk_policy_for_build_date() {
  local build_date="${1:-}"
  [[ "$build_date" =~ ^[0-9]{8}$ ]] || {
    printf '%s\n' "unknown_or_unsupported"
    return 0
  }

  if [[ "$build_date" == "20260227" ]]; then
    printf '%s\n' "legacy_gplall"
  elif ((10#$build_date >= 20260228 && 10#$build_date <= 20260311)); then
    printf '%s\n' "split_envs"
  elif ((10#$build_date >= 20260312)); then
    printf '%s\n' "lowlatency_only"
  else
    printf '%s\n' "unknown_or_unsupported"
  fi
}

dxvk_probe_tree_policy() {
  local root="${1:-}" proton_py=""
  local has_gplasync=0 has_lowlatency=0 has_llasync=0

  [[ -d "$root" ]] || return 1

  proton_py="$root/proton"
  [[ -f "$proton_py" ]] || return 1

  LC_ALL=C grep -Fq 'PROTON_DXVK_GPLASYNC' "$proton_py" 2>/dev/null && has_gplasync=1
  LC_ALL=C grep -Fq 'PROTON_DXVK_LOWLATENCY' "$proton_py" 2>/dev/null && has_lowlatency=1
  LC_ALL=C grep -Fq 'PROTON_DXVK_LLASYNC' "$proton_py" 2>/dev/null && has_llasync=1

  if ((has_lowlatency == 1 && has_gplasync == 1)); then
    printf '%s\n' "split_envs"
    return 0
  fi
  if ((has_lowlatency == 1 && has_gplasync == 0)); then
    printf '%s\n' "lowlatency_only"
    return 0
  fi
  if ((has_lowlatency == 0 && has_gplasync == 1)); then
    printf '%s\n' "legacy_gplall"
    return 0
  fi
  if ((has_llasync == 1)); then
    printf '%s\n' "unknown_or_unsupported"
    return 0
  fi

  return 1
}

dxvk_pick_target_root_for_date() {
  local want_date="${1:-}" out_var="${2:-}"
  local target_root=""
  local src=""

  for src in "${SUPPORTED_SOURCES[@]}"; do
    if [[ "$(source_build_date "$src" 2>/dev/null || true)" == "$want_date" ]]; then
      target_root="$src"
      break
    fi
  done
  if [[ -z "$target_root" ]]; then
    for src in "${SOURCES[@]}"; do
      if [[ "$(source_build_date "$src" 2>/dev/null || true)" == "$want_date" ]]; then
        target_root="$src"
        break
      fi
    done
  fi

  [[ -n "$target_root" ]] || return 1
  [[ -n "$out_var" ]] && printf -v "$out_var" '%s' "$target_root"
  return 0
}

dxvk_resolve_target_state() {
  local out_root_var="${1:-}" out_date_var="${2:-}" out_reason_var="${3:-}"
  local out_expected_var="${4:-}" out_probe_var="${5:-}" out_final_var="${6:-}" out_warn_var="${7:-}"
  local target_root="" target_date="" target_reason="" expected_policy="" probe_policy="" final_policy="" warn_note=""
  local newest_src_date="" newest_supported_date=""

  SOURCES=()
  SUPPORTED_SOURCES=()
  if [[ -d "${CTD:-}" ]]; then
    gather_sources >/dev/null 2>&1 || true
    gather_supported_sources_from_sources >/dev/null 2>&1 || true
  fi

  newest_src_date="$(detect_build_date_for_sources "${SOURCES[@]}" 2>/dev/null || true)"
  newest_supported_date="$(detect_build_date_for_sources "${SUPPORTED_SOURCES[@]}" 2>/dev/null || true)"

  if [[ -n "${BUILD_DATE:-}" ]]; then
    target_date="${BUILD_DATE}"
    target_reason="explicit_date"
  elif [[ -n "$newest_supported_date" ]]; then
    target_date="$newest_supported_date"
    target_reason="helper_default_supported_source"
  elif [[ -n "$newest_src_date" ]]; then
    target_date="$newest_src_date"
    target_reason="helper_default_newest_source"
  else
    target_reason="unresolved"
  fi

  if [[ -n "$target_date" ]]; then
    dxvk_pick_target_root_for_date "$target_date" target_root || true
  fi

  expected_policy="$(dxvk_policy_for_build_date "$target_date")"
  if [[ -n "$target_root" ]]; then
    probe_policy="$(dxvk_probe_tree_policy "$target_root" 2>/dev/null || true)"
  fi

  final_policy="$expected_policy"
  if [[ -n "$probe_policy" && "$probe_policy" != "unknown_or_unsupported" ]]; then
    final_policy="$probe_policy"
    if [[ "$expected_policy" != "unknown_or_unsupported" && "$probe_policy" != "$expected_policy" ]]; then
      warn_note="date ${target_date} expected ${expected_policy}, probe found ${probe_policy}"
    fi
  elif [[ -z "$final_policy" ]]; then
    final_policy="unknown_or_unsupported"
  fi

  [[ -n "$out_root_var" ]] && printf -v "$out_root_var" '%s' "$target_root"
  [[ -n "$out_date_var" ]] && printf -v "$out_date_var" '%s' "$target_date"
  [[ -n "$out_reason_var" ]] && printf -v "$out_reason_var" '%s' "$target_reason"
  [[ -n "$out_expected_var" ]] && printf -v "$out_expected_var" '%s' "$expected_policy"
  [[ -n "$out_probe_var" ]] && printf -v "$out_probe_var" '%s' "$probe_policy"
  [[ -n "$out_final_var" ]] && printf -v "$out_final_var" '%s' "$final_policy"
  [[ -n "$out_warn_var" ]] && printf -v "$out_warn_var" '%s' "$warn_note"
}

source_clone_basename() {
  local src="${1:-}" suffix="${2:-}"
  local rec="" base=""
  rec="$(source_clone_identity_metadata_record "$src" 2>/dev/null || true)"
  if [[ -n "$rec" ]]; then
    base="${rec%%|*}"
  else
    base="$(source_effective_base "$src")" || return 1
  fi
  [[ -n "$base" ]] || return 1
  printf '%s-%s\n' "$base" "$suffix"
}

steam_display_runtime_label() {
  case "${1:-}" in
    slr) printf '%s\n' "SLR" ;;
    native) printf '%s\n' "native" ;;
    *) printf '%s\n' "${1:-unknown}" ;;
  esac
}

steam_display_arch_label() {
  local raw_arch="${1:-}" arch="${1:-}"
  case "$arch" in
    system-*) arch="${arch#system-}" ;;
    protonplus-*) arch="${arch#protonplus-}" ;;
  esac
  case "$arch" in
    x86_64) printf '%s\n' "x64" ;;
    x86_64_v[0-9]*) printf '%s\n' "x64-v${arch#x86_64_v}" ;;
    protonplus-unspecified | "" | unknown) printf '%s\n' "unknown" ;;
    *) printf '%s\n' "${raw_arch:-unknown}" ;;
  esac
}

steam_display_source_label_for_cachyos() {
  local source_base="${1:-}" clone_base="${2:-}" combined=""
  combined="${source_base} ${clone_base}"
  case "$combined" in
    *-system-x86_64*) printf '%s\n' "system" ;;
    *-protonplus-* | cachyos-*) printf '%s\n' "ProtonPlus" ;;
    *proton-cachyos-*) printf '%s\n' "ProtonUp-Qt" ;;
    *) printf '%s\n' "unknown" ;;
  esac
}

steam_display_cachyos_metadata_record() {
  local source_base="${1:-}" clone_base="${2:-}"
  local major="" date="" runtime="" arch=""

  if [[ "$source_base" =~ ^proton-cachyos-([0-9]+([.][0-9]+)?)-([0-9]{8})-(native|slr)-((x86_64(_v[0-9]+)?)|(protonplus-(x86_64(_v[0-9]+)?|unspecified))|(system-x86_64))$ ]]; then
    major="${BASH_REMATCH[1]}"
    date="${BASH_REMATCH[3]}"
    runtime="${BASH_REMATCH[4]}"
    arch="${BASH_REMATCH[5]}"
  elif [[ "$source_base" =~ ^cachyos-([0-9]+([.][0-9]+)?)-([0-9]{8})-(native|slr)$ ]]; then
    major="${BASH_REMATCH[1]}"
    date="${BASH_REMATCH[3]}"
    runtime="${BASH_REMATCH[4]}"
    arch="protonplus-unspecified"
    if [[ "$clone_base" =~ ^proton-cachyos-([0-9]+([.][0-9]+)?)-([0-9]{8})-(native|slr)-((x86_64(_v[0-9]+)?)|(protonplus-(x86_64(_v[0-9]+)?|unspecified))|(system-x86_64))-([A-Za-z0-9][A-Za-z0-9._-]*)$ ]] &&
       [[ "${BASH_REMATCH[1]}" == "$major" && "${BASH_REMATCH[3]}" == "$date" && "${BASH_REMATCH[4]}" == "$runtime" ]]; then
      arch="${BASH_REMATCH[5]}"
    fi
  elif [[ "$clone_base" =~ ^proton-cachyos-([0-9]+([.][0-9]+)?)-([0-9]{8})-(native|slr)-((x86_64(_v[0-9]+)?)|(protonplus-(x86_64(_v[0-9]+)?|unspecified))|(system-x86_64))-([A-Za-z0-9][A-Za-z0-9._-]*)$ ]]; then
    major="${BASH_REMATCH[1]}"
    date="${BASH_REMATCH[3]}"
    runtime="${BASH_REMATCH[4]}"
    arch="${BASH_REMATCH[5]}"
  else
    return 1
  fi

  printf '%s|%s|%s|%s\n' "$major" "$date" "$runtime" "$arch"
}

steam_display_name_for_cachyos() {
  local source_base="${1:-}" clone_base="${2:-}" rec="" parsed=""
  local major="" date="" runtime="" arch="" runtime_label="" arch_label="" source_label=""

  rec="$(steam_display_cachyos_metadata_record "$source_base" "$clone_base" 2>/dev/null || true)"
  [[ -n "$rec" ]] || return 1
  major="${rec%%|*}"
  parsed="${rec#*|}"
  date="${parsed%%|*}"
  parsed="${parsed#*|}"
  runtime="${parsed%%|*}"
  arch="${parsed#*|}"

  runtime_label="$(steam_display_runtime_label "$runtime" 2>/dev/null || true)"
  arch_label="$(steam_display_arch_label "$arch" 2>/dev/null || true)"
  source_label="$(steam_display_source_label_for_cachyos "$source_base" "$clone_base" 2>/dev/null || true)"
  [[ -n "$runtime_label" && -n "$arch_label" && -n "$source_label" ]] || return 1
  printf 'gENVW CachyOS %s-%s %s %s [%s]\n' "$major" "$date" "$runtime_label" "$arch_label" "$source_label"
}

steam_display_name_for_dwproton() {
  local version="${1:-}"
  [[ "$version" =~ ^[0-9]+[.][0-9]+-[0-9]+$ ]] || return 1
  printf 'gENVW DW-Proton %s\n' "$version"
}

dwproton_display_name_for_version() {
  steam_display_name_for_dwproton "${1:-}"
}

dwproton_display_name_for_clone_basename() {
  local clone_basename="${1:-}" version=""
  if [[ "$clone_basename" =~ ^dwproton-([0-9]+[.][0-9]+-[0-9]+)-x86_64(_v[1-4])?-[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    version="${BASH_REMATCH[1]}"
    dwproton_display_name_for_version "$version"
    return 0
  fi
  return 1
}

append_unique_path() {
  local path="${1:-}"
  local -n arr_ref="$2"
  local existing=""
  for existing in "${arr_ref[@]}"; do
    [[ "$existing" == "$path" ]] && return 0
  done
  arr_ref+=("$path")
}

system_source_roots() {
  local raw=""
  local IFS=':'
  local -a roots=()
  local root=""
  if [[ "${GENVW_SYSTEM_SOURCE_ROOTS+x}" == "x" ]]; then
    raw="${GENVW_SYSTEM_SOURCE_ROOTS}"
  else
    raw="/usr/share/steam/compatibilitytools.d"
  fi
  read -r -a roots <<<"$raw"
  for root in "${roots[@]}"; do
    [[ -n "$root" ]] || continue
    printf '%s\n' "$root"
  done
}

source_provenance_mode_kv() {
  case "${1:-}" in
    ctd) printf '%s\n' "user-ctd" ;;
    system) printf '%s\n' "packaged-system" ;;
    mixed) printf '%s\n' "mixed" ;;
    none) printf '%s\n' "none" ;;
    *) printf '%s\n' "${1:-unknown}" ;;
  esac
}

source_provenance_mode_label() {
  case "${1:-}" in
    ctd) printf '%s\n' "user CTD" ;;
    system) printf '%s\n' "packaged system" ;;
    mixed) printf '%s\n' "mixed" ;;
    none) printf '%s\n' "none" ;;
    *) printf '%s\n' "${1:-unknown}" ;;
  esac
}

source_provenance_record_for_path() {
  local src="${1:-}" root=""
  [[ -n "$src" ]] || return 1

  if [[ -n "${CTD:-}" && "$src" == "$CTD/"* ]]; then
    printf 'ctd|%s\n' "$CTD"
    return 0
  fi

  while IFS= read -r root; do
    [[ -n "$root" ]] || continue
    if [[ "$src" == "$root/"* ]]; then
      printf 'system|%s\n' "$root"
      return 0
    fi
  done < <(system_source_roots)

  printf 'other|%s\n' "${src%/*}"
}

source_default_priority_for_path() {
  local src="${1:-}" prov_rec="" prov="" base=""
  prov_rec="$(source_provenance_record_for_path "$src" 2>/dev/null || true)"
  prov="${prov_rec%%|*}"
  if [[ "$prov" == "system" ]]; then
    printf '%s\n' "30"
    return 0
  fi

  base="$(source_effective_base "$src" 2>/dev/null || printf '%s\n' "${src##*/}")"
  case "$base" in
    *-protonplus-* | *-protonplus-unspecified | cachyos-*) printf '%s\n' "20" ;;
    proton-cachyos-*) printf '%s\n' "10" ;;
    *) printf '%s\n' "0" ;;
  esac
}

source_provenance_summary() {
  local -n srcs_ref="$1" mode_ref="$2" provenance_ref="$3" root_ref="$4"
  local src="" rec="" mode="" root="" seen_mode="" seen_root=""
  local count=0

  mode_ref="none"
  provenance_ref="none"
  root_ref=""

  for src in "${srcs_ref[@]}"; do
    rec="$(source_provenance_record_for_path "$src" 2>/dev/null || true)"
    [[ -n "$rec" ]] || continue
    mode="${rec%%|*}"
    root="${rec#*|}"
    ((count += 1))

    if [[ -z "$seen_mode" ]]; then
      seen_mode="$mode"
      seen_root="$root"
      continue
    fi

    if [[ "$mode" != "$seen_mode" || "$root" != "$seen_root" ]]; then
      mode_ref="mixed"
      provenance_ref="mixed"
      root_ref=""
      return 0
    fi
  done

  ((count > 0)) || return 0
  mode_ref="$seen_mode"
  provenance_ref="$(source_provenance_mode_kv "$seen_mode")"
  root_ref="$seen_root"
}

rebuild_source_selection_tail() {
  case "${GENVW_SOURCE_SELECTION:-default}" in
    prefer_system) printf '%s' " --prefer-system-sources" ;;
    system_only) printf '%s' " --system-sources-only" ;;
    *) printf '%s' "" ;;
  esac
}

# keep this around for later
#steam_running() { steam_is_running; }

# first_line: read and print only the first stdin line.
# used to avoid a hard dependency on `head`.
first_line() {
  local line=""
  IFS= read -r line || true
  printf "%s" "$line"
}

# amd_wget_download: fetch an amd driver into the cache dir.
# trust boundary: downloads + local extract.
amd_wget_download() {
  # amd expects a referer and a browser-ish ua.
  # without it you can get a "download-incomplete" redirect.
  local url="$1"
  local out="$2"
  local ua="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Safari/537.36"
  local ref="https://www.amd.com/"
  # no resume. cache is trusted unless `7z t` fails, then re-download.
  mkdir -p -- "$(dirname -- "$out")" >/dev/null 2>&1 || true
  wget \
    --https-only \
    --show-progress \
    --max-redirect=25 \
    --tries=12 --waitretry=2 --timeout=30 \
    --user-agent="$ua" \
    --referer="$ref" \
    -O "$out" \
    "$url"
}

# amd_wget_content_length
# gets the remote size for an amd driver url.
# intentional reserve helper for future download diagnostics.
amd_wget_content_length() {
  local url="$1"

  # same ua/referer as downloads (avoids amd edge blocking).
  local ua="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Safari/537.36"
  local ref="https://www.amd.com/"

  # curl path: use Content-Range total when available.
  if have curl; then
    local hdr="" total=""
    hdr="$(curl -sSLD- -o /dev/null -A "$ua" -e "$ref" -H 'Range: bytes=0-0' --max-time 20 "$url" 2>/dev/null || true)"
    total="$(printf '%s\n' "$hdr" | tr -d '\r' | awk 'BEGIN{IGNORECASE=1} /^Content-Range:/ {split($0,a,"/"); if (a[2] ~ /^[0-9]+$/) {print a[2]; exit}}')"
    if [[ "$total" =~ ^[0-9]+$ ]]; then
      printf '%s\n' "$total"
      return 0
    fi
  fi

  local out=""
  out="$(wget --spider --server-response --max-redirect=25 --tries=3 --timeout=20 \
    --user-agent="$ua" --referer="$ref" "$url" 2>&1 || true)"

  # last Content-Length wins (redirect chains can include several).
  printf '%s\n' "$out" | awk -F': ' 'BEGIN{IGNORECASE=1} $1 ~ /Content-Length/ {print $2}' | tail -n1 | tr -d '\r'
}

# amd_pick_best_dll_candidate
# picks the best amdxcffx64.dll from an extracted driver tree.
amd_pick_best_dll_candidate() {
  # scoring rules:
  # - prefer display driver paths
  # - prefer real-sized dlls over tiny stubs
  # - stable tie-break by path (C locale)
  local LC_ALL=C
  local min_bytes=10485760 # 10 MiB: skips tiny stub dlls when a real payload exists.

  local best="" best_score=-1 best_size=-1
  local f score sz
  local any_big=0

  # if any candidate is big enough, ignore smaller ones.
  for f in "$@"; do
    sz="$(stat -c '%s' "$f" 2>/dev/null || echo 0)"
    ((sz >= min_bytes)) && any_big=1
  done

  for f in "$@"; do
    score=0
    [[ "$f" == *"/Packages/Drivers/Display/"* ]] && score=$((score + 200))
    [[ "$f" == *"/Packages/Drivers/"* ]] && score=$((score + 40))
    [[ "$f" == *"/WT6A_INF/"* ]] && score=$((score + 25))
    [[ "$f" == *"/Display/"* ]] && score=$((score + 10))

    sz="$(stat -c '%s' "$f" 2>/dev/null || echo 0)"

    # if there's a real-sized dll, don't consider small candidates.
    if ((any_big == 1 && sz < min_bytes)); then
      continue
    fi

    # size adds a small tie-break without dominating the path score.
    score=$((score + (sz / 1048576))) # +1 per MiB

    if [[ -z "$best" ]] || ((score > best_score)) || { ((score == best_score)) && ((sz > best_size)); } || { ((score == best_score)) && ((sz == best_size)) && [[ "$f" < "$best" ]]; }; then
      best="$f"
      best_score="$score"
      best_size="$sz"
    fi
  done

  printf '%s
' "$best"
}

# usage: help text
usage() {
  local _pcmd _dcmd
  _pcmd="$(cmd_proton)"
  _dcmd="$(cmd_dll)"

  cat <<EOF
${I_TOOLBOX} genvw_proton

Quickstart:
  $_pcmd prep
    One-shot setup
  $_pcmd prep --yes
    Non-interactive setup
  $_pcmd prep --dry-run
    Preview setup changes

Launch:
  FSR4=1 genvw %command%
    Auto RDNA3 / RDNA4
  FSR4=$FSR4_LOCAL_DEFAULT_VER genvw %command%
    Local pin

Read Only:
  $_pcmd status
    Show Steam, DLL, and tool state
  $_pcmd diagnose [--appid APPID|--pfx-dll PATH]
    Show readiness and next steps
  $_pcmd check
    Run helper sanity checks
  $_pcmd check --kv
    Emit KV contract output
  $_pcmd sources --machine
    Emit discovered Proton-CachyOS source targets
  $_pcmd gpu
    Show GPU detection details
  $_pcmd list-clones [--date YYYYMMDD] [...]
    List current gENVW clone tools

Build / Maintenance:
  $_pcmd rebuild [--dry-run] [...]
    Build or refresh gENVW tools
  $_pcmd rebuild --dry-run --dwproton-preview [...]
    Preview disabled DW-Proton rebuild plans
  $_pcmd clean [--dry-run] [...]
    Remove gENVW tools
  $_pcmd clean --old
    Remove older clone dates
  $_pcmd selftest [all|paths|steam|dll]
    Run helper self-tests

DLL Commands:
  $_dcmd install [--exe PATH | --url URL] [...]
    Install local AMD FSR4 DLL
  $_dcmd inspect --dll PATH|--exe PATH|--url URL [...]
    Inspect an FSR4 DLL source without installing
  $_dcmd verify
    Verify local DLL trust
  $_dcmd backup [--ver X.Y.Z]
    Save a sealed local backup
  $_dcmd restore [--ver X.Y.Z] [...]
    Restore a sealed local backup
  $_dcmd tidy [--driver-label LABEL]
    Clean extracted driver folders
  $_dcmd uninstall
    Remove local DLL + metadata
  $_dcmd appid APPID [VER]
    Compare prefix DLL vs local cache
  $_dcmd prefix-sync --appid APPID [VER]
    Copy cache DLL into a prefix

Notes:
  • Aliases: uninstall | remove | rm
  • --appid searches across Steam libraries.
  • Defaults: --date picks newest found; --ctd auto-detects common Steam paths.
  • Source selection:
      --prefer-system-sources  Prefer packaged /usr/share sources when present.
      --system-sources-only    Only use packaged /usr/share sources.
  • Rebuild selectors:
      --target requires an explicit --provider (cachyos or dw).
      -p cachyos -t YYYYMMDD  All eligible CachyOS variants for that date;
                              not a single source-family or architecture selector.
      -p dw -t RELEASE        DW-Proton release selector (e.g. 11.0-2).
      --all-targets           Broad safe supported scope.
      --missing-only          Applies after the selected target scope.
  • Restart Steam after rebuild or clean.

EOF
}

proton_help_requested() {
  local a=""
  for a in "$@"; do
    case "$a" in
      -h | --help | help) return 0 ;;
    esac
  done
  return 1
}

prep_usage() {
  local _pcmd
  _pcmd="$(cmd_proton)"
  cat <<EOF
${I_TOOLBOX} genvw_proton prep

Prepare the local AMD DLL and supported gENVW Proton tool state.

Usage:
  $_pcmd prep [--yes] [--dry-run] [--ver X.Y.Z] [...]

Examples:
  $_pcmd prep --dry-run
  $_pcmd prep --yes

Notes:
  • --dry-run previews DLL install + rebuild steps without changes.
  • Normal prep may install/update local prep artifacts and gENVW tools.
  • Use $_pcmd status or $_pcmd sources for current state.
EOF
}

rebuild_usage() {
  local _pcmd
  _pcmd="$(cmd_proton)"
  cat <<EOF
${I_RETRY} genvw_proton rebuild

Rebuild selected supported gENVW compatibility tools.

Usage:
  $_pcmd rebuild --dry-run -p cachyos -t 20260521
  $_pcmd rebuild --dry-run -p dw -t 11.0-3
  $_pcmd rebuild --dry-run --all-targets
  $_pcmd rebuild --dry-run --all-targets --missing-only

Notes:
  • Explicit scope is required for rebuild and rebuild --dry-run.
  • --all-targets selects the broad supported rebuild scope.
  • --missing-only applies after the selected target scope.
  • Normal rebuild is blocked while Steam is running.
EOF
}

clean_usage() {
  local _pcmd
  _pcmd="$(cmd_proton)"
  cat <<EOF
${I_BROOM} genvw_proton clean

Remove gENVW compatibility tools.

Usage:
  $_pcmd clean [--dry-run] [--ctd PATH] [--major X.Y] [--suffix gENVW]
  $_pcmd clean --old [--dry-run] [--ctd PATH] [--major X.Y] [--suffix gENVW]

Examples:
  $_pcmd clean --dry-run
  $_pcmd clean --old --dry-run
  $_pcmd clean
  $_pcmd clean --old

Notes:
  • clean removes current gENVW tools in scope.
  • clean --old removes older/stale clone dates.
  • --dry-run previews removal only.
  • Normal clean is blocked while Steam is running.
  • clean --old is the supported old-clean surface.
EOF
}

list_clones_usage() {
  local _pcmd
  _pcmd="$(cmd_proton)"
  cat <<EOF
${I_BOX} genvw_proton list-clones

Read-only inventory of current gENVW clones/tools.

Usage:
  $_pcmd list-clones [--date YYYYMMDD] [--ctd PATH] [--major X.Y] [--suffix gENVW]

Examples:
  $_pcmd list-clones

Notes:
  • Read-only inventory; no deletion or rebuild.
  • Use $_pcmd clean --dry-run for a removal preview.
EOF
}

# flags that require a value (prevents shift errors and empty values)
# used by amd_dll_run, do_prep, parse_kv_flags

# require_flag_value
# flag parser guard. stops missing values from turning into weird shifts.
# trust boundary: used on paths/urls that feed download/extract paths.
require_flag_value() {
  local flag="${1:-}"
  local val="${2-}"
  [[ -n "$flag" ]] || die "internal: missing flag name"

  # missing/empty
  [[ -n "$val" ]] || die "$flag requires a value"

  # next token is another flag
  if [[ "$val" == --* ]]; then
    die "$flag requires a value (got '$val')"
  fi
}

kv_norm() {
  # normalize a single-line kv/meta value for parsing and comparisons.
  # strips CR (crlf files) and trims leading/trailing whitespace.
  local s="${1-}"
  s="${s//$'\r'/}"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

kv_get_one_strict() {
  local kv="${1:-}" key="${2:-}"
  local n="" value=""
  [[ -n "$key" ]] || die "internal: kv_get_one_strict missing key"
  n="$(printf '%s\n' "$kv" | grep -c "^${key}=" || true)"
  [[ "$n" == "1" ]] || die "diagnose: internal KV contract error for ${key} (expected exactly one entry, found ${n})"
  value="$(printf '%s\n' "$kv" | sed -nE "s/^${key}=//p")"
  printf '%s\n' "$value"
}

# file helpers

_amd_extract_exe() {
  local dl="${1:-}"
  local exdir="${2:-}"
  require_file "$dl" "--exe"
  [[ -n "$exdir" ]] || die "internal: missing extract dir"
  mkdir -p -- "$exdir" >/dev/null 2>&1 || true

  # record input/method for report/meta writers
  declare -g GENVW_AMD_LAST_DL="$dl"
  declare -g GENVW_AMD_LAST_EXTRACT_METHOD="7z"

  # pre-scan archive paths before extracting (blocks traversal/absolute paths)
  if declare -F validate_7z_archive_paths >/dev/null 2>&1; then
    validate_7z_archive_paths "$dl"
  fi

  7z x -y -o"$exdir" "$dl" >/dev/null || die "7z extraction failed: $dl"

  # optional bounded-tree validation if present
  if declare -F validate_extraction_tree >/dev/null 2>&1; then
    validate_extraction_tree "$exdir"
  fi
}

# url extractor: download into cache dir, then extract.
# trust boundary: downloads/extract + user-controlled paths.
_amd_extract_url() {
  local url="${1:-}"
  local exdir="${2:-}"
  [[ -n "$url" ]] || die "internal: missing url"

  local dl_dir="${AMD_DRIVER_DL_DIR:-${GENVW_CACHE_DIR:-$HOME/.cache/genvw}/amd/driver-dl}"
  mkdir -p -- "$dl_dir" >/dev/null 2>&1 || true

  local name
  name="$(basename -- "$url" 2>/dev/null || true)"
  name="${name%%\?*}"
  name="$(printf '%s' "$name" | tr -cd '[:alnum:]._-')"
  [[ -n "$name" ]] || name="amd_driver.exe"

  local dl="${dl_dir}/${name}"

  # record download path for report/meta writers
  declare -g GENVW_AMD_LAST_DL="$dl"

  if declare -F amd_wget_download >/dev/null 2>&1; then
    amd_wget_download "$url" "$dl" || die "Download failed: $url"
  elif have wget; then
    wget -c -O "$dl" --user-agent="Mozilla/5.0" --referer="https://www.amd.com/" "$url" >/dev/null 2>&1 \
      || die "Download failed (wget): $url"
  elif have curl; then
    curl -L --fail -A "Mozilla/5.0" -e "https://www.amd.com/" -o "$dl" "$url" >/dev/null 2>&1 \
      || die "Download failed (curl): $url"
  else
    die "Missing downloader (need wget or curl)"
  fi

  _amd_extract_exe "$dl" "$exdir"
}

amd_driver_cached_exe_path_for_url() {
  local url="${1:-}"
  local dl_dir="${2:-${AMD_DRIVER_DL_DIR:-${GENVW_CACHE_DIR:-$HOME/.cache/genvw}/amd/driver-dl}}"
  [[ -n "$url" ]] || return 1

  local exe_name_raw="" exe_name_safe=""
  exe_name_raw="$(basename "$url" 2>/dev/null || true)"
  exe_name_raw="${exe_name_raw%%\?*}"
  exe_name_raw="${exe_name_raw%%\#*}"
  exe_name_safe="$(LC_ALL=C printf '%s' "$exe_name_raw" | tr -cd 'A-Za-z0-9._-')"
  exe_name_safe="${exe_name_safe:0:120}"

  if [[ -z "$exe_name_safe" || "$exe_name_safe" == "." || "$exe_name_safe" == ".." || "$exe_name_safe" == -* || "$exe_name_safe" != *.exe ]]; then
    exe_name_safe="amd-driver.exe"
  fi

  printf '%s\n' "${dl_dir}/${exe_name_safe}"
}

amd_dll_validate_url_for_install() {
  local url="${1:-}" force_url="${2:-0}"
  [[ -n "$url" ]] || die "dll install: --url requires a value"
  case "$url" in
    https://*) : ;;
    *) die "Refusing non-HTTPS URL (download manually and use --exe): $url" ;;
  esac

  if amd_url_allowed "$url"; then
    if ((force_url != 0)); then
      warn "Using --force-url even though URL is allowlisted: $url"
    fi
    return 0
  fi

  if ((force_url == 0)); then
    die "Refusing URL not in AMD allowlist (use --force-url to override): $url"
  fi

  warn "URL is NOT in the AMD allowlist. --force-url bypasses URL safety checks."
  msg "URL: $url"
  msg "Allowlist: https://drivers.amd.com/*, https://download.amd.com/*, https://www.amd.com/*"
  msg "Risk: You are trusting the downloaded EXE; proceed only if you fully trust the source."

  if [[ "${GENVW_ASSUME_YES:-0}" == "1" ]]; then
    info "Assuming consent (GENVW_ASSUME_YES=1). Continuing."
  else
    if ! ask_yes_no_default "Proceed with untrusted URL? [y/N]: " "n"; then
      die "Aborted by user."
    fi
  fi
}

amd_dll_validate_url_for_inspect() {
  local url="${1:-}"
  [[ -n "$url" ]] || die "dll inspect: --url requires a value"
  case "$url" in
    https://*) : ;;
    *) die "dll inspect: refusing non-HTTPS URL: $url" ;;
  esac
}

amd_dll_resolve_url_driver_exe() {
  local url="${1:-}"
  local -n out_dl_ref="$2"
  local -n out_downloaded_ref="$3"
  local resolved_dl="" __sig="" dlrc=0

  [[ -n "$url" ]] || die "internal: missing driver URL"
  mkdir -p -- "$AMD_DRIVER_DL_DIR" >/dev/null 2>&1 || true
  resolved_dl="$(amd_driver_cached_exe_path_for_url "$url" "$AMD_DRIVER_DL_DIR")" || die "Could not derive driver cache path from URL: $url"

  if [[ -f "$resolved_dl" ]]; then
    __sig="$(head -c 2 "$resolved_dl" 2>/dev/null || true)"
    if [[ "$__sig" != "MZ" ]]; then
      warn "Cached driver does not look like a Windows EXE (missing 'MZ'); re-downloading from scratch:"
      msg "  $resolved_dl"
      rm -f -- "$resolved_dl" 2>/dev/null || true
    else
      if ! 7z t "$resolved_dl" >/dev/null 2>&1; then
        warn "Cached driver is corrupt (7z test failed); re-downloading from scratch:"
        msg "  $resolved_dl"
        rm -f -- "$resolved_dl" 2>/dev/null || true
      fi
    fi
  fi

  if [[ -f "$resolved_dl" ]]; then
    msg "${I_OK} Cached driver already present; skipping download:"
    msg "  $resolved_dl"
    out_downloaded_ref=0
  else
    msg "${I_DL} Downloading (wget):"
    msg "  $url"
    msg "${I_ARROW}  To:"
    msg "  $resolved_dl"
    out_downloaded_ref=1
    if amd_wget_download "$url" "$resolved_dl"; then
      :
    else
      dlrc=$?
      if ((dlrc == 130 || dlrc == 143)); then
        warn "Download interrupted (rc=$dlrc); keeping partial: $resolved_dl"
        return "$dlrc"
      fi
      rm -f -- "$resolved_dl" 2>/dev/null || true
      die "Download failed (HTTP error / blocked / network): $url"
    fi
  fi

  out_dl_ref="$resolved_dl"
}

amd_dll_validate_driver_exe_after_resolve() {
  local dl="${1:-}" url="${2:-}" downloaded="${3:-0}"
  local sig=""
  if [[ -r "$dl" ]]; then
    IFS= read -r -n2 sig <"$dl" || true
  fi
  if [[ "$sig" != "MZ" ]]; then
    warn "Downloaded file does not look like a Windows EXE (missing 'MZ' header)."
    ((downloaded == 1)) && rm -f -- "$dl" 2>/dev/null || true
    if [[ -n "$url" ]] && [[ "$url" =~ ^https?://drivers\.amd\.com/|^https?://([^/]+\.)?amd\.com/ ]]; then
      die "AMD URL returned HTML/redirect, not a driver EXE. Download via browser and re-run with: $(cmd_dll) install --exe /path/to/driver.exe"
    else
      die "URL did not return a Windows driver EXE. Use a real .exe URL, or download via browser and re-run with: $(cmd_dll) install --exe /path/to/driver.exe"
    fi
  fi
}

fsr4_dll_fingerprint() {
  local dll_path="${1:-}"
  local -n out_mz_ref="$2"
  local -n out_sha_ref="$3"
  local -n out_size_ref="$4"

  out_mz_ref="no"
  out_sha_ref=""
  out_size_ref=""
  [[ -f "$dll_path" ]] || return 1
  fsr4_trusted_file_has_mz "$dll_path" && out_mz_ref="yes"
  out_size_ref="$(stat -c %s "$dll_path" 2>/dev/null || true)"
  out_sha_ref="$(sha256sum "$dll_path" 2>/dev/null | awk '{print $1}' || true)"
  [[ -n "$out_sha_ref" && "$out_size_ref" =~ ^[0-9]+$ ]]
}

fsr4_trusted_fingerprint_lookup() {
  local want_sha="${1:-}" want_size="${2:-}"
  local -n __fsr4_trusted_out_ver_ref="$3"
  local row="" ver="" url="" sha="" size=""

  __fsr4_trusted_out_ver_ref=""
  [[ -n "$want_sha" && -n "$want_size" ]] || return 1
  for row in "${FSR4_TRUSTED_SOURCE_ROWS[@]}"; do
    IFS='|' read -r ver url sha size <<<"$row"
    if [[ "${sha,,}" == "${want_sha,,}" && "$size" == "$want_size" ]]; then
      __fsr4_trusted_out_ver_ref="$ver"
      return 0
    fi
  done
  return 1
}

fsr4_dll_collect_marker_report() {
  local dll_path="${1:-}"
  local -n out_filename_ref="$2"
  local -n out_content_ref="$3"
  local -n out_all_ref="$4"
  local -n out_supported_ref="$5"
  local -n out_result_ref="$6"

  fsr4_collect_dll_filename_version_candidates "$dll_path" out_filename_ref
  fsr4_collect_dll_content_version_candidates "$dll_path" out_content_ref
  fsr4_collect_dll_version_candidates "$dll_path" out_all_ref
  fsr4_filter_local_write_supported_versions out_all_ref out_supported_ref
  out_result_ref="$(fsr4_dll_marker_result_label "${#out_all_ref[@]}" "${#out_supported_ref[@]}")"
}

fsr4_dll_inspect_suggest_version() {
  local requested_ver="${1:-}"
  local -n supported_ref="$2"
  local -n out_suggest_ref="$3"
  local -n out_reason_ref="$4"
  local -n out_requested_ref="$5"

  out_suggest_ref=""
  out_reason_ref=""
  out_requested_ref=""

  if [[ -n "$requested_ver" ]]; then
    if fsr4_array_contains "$requested_ver" "${supported_ref[@]}"; then
      out_suggest_ref="$requested_ver"
      out_reason_ref="requested version is present in supported markers"
      out_requested_ref="present"
    else
      out_requested_ref="not present"
    fi
    return 0
  fi

  if ((${#supported_ref[@]} > 0)); then
    out_suggest_ref="$(fsr4_highest_supported_version_from_args "${supported_ref[@]}")"
    [[ -n "$out_suggest_ref" ]] && out_reason_ref="highest supported detected marker"
  fi
}

fsr4_dll_inspect_print_report() {
  local source_kind="${1:-unknown}" source_ref="${2:-}" picked_dll="${3:-}" requested_ver="${4:-}"
  local mz="" sha="" size="" policy_ver="" result=""
  local -a filename_markers=()
  local -a content_markers=()
  local -a all_markers=()
  local -a supported_markers=()
  local suggested_ver="" suggested_reason="" requested_eval=""

  require_file "$picked_dll" "picked DLL"
  [[ -r "$picked_dll" ]] || die "dll inspect: picked DLL is not readable: $picked_dll"

  fsr4_dll_fingerprint "$picked_dll" mz sha size || die "dll inspect: could not compute DLL fingerprint: $picked_dll"
  fsr4_dll_collect_marker_report "$picked_dll" filename_markers content_markers all_markers supported_markers result
  fsr4_dll_inspect_suggest_version "$requested_ver" supported_markers suggested_ver suggested_reason requested_eval
  fsr4_trusted_fingerprint_lookup "$sha" "$size" policy_ver || true

  msg "DLL Inspect"
  msg ""
  msg "Source:"
  printf '  %-13s %s\n' "Kind:" "$source_kind"
  printf '  %-13s %s\n' "Source:" "${source_ref:-$picked_dll}"
  printf '  %-13s %s\n' "Picked DLL:" "$picked_dll"
  msg ""
  msg "File:"
  printf '  %-13s %s\n' "MZ header:" "$mz"
  printf '  %-13s %s\n' "Size:" "$size"
  printf '  %-13s %s\n' "SHA256:" "$sha"
  msg ""
  msg "Version markers:"
  printf '  %-13s %s\n' "Filename:" "$(fsr4_versions_comma_from_args "${filename_markers[@]}")"
  printf '  %-13s %s\n' "Content:" "$(fsr4_versions_comma_from_args "${content_markers[@]}")"
  printf '  %-13s %s\n' "Supported:" "$(fsr4_versions_comma_from_args "${supported_markers[@]}")"
  printf '  %-13s %s\n' "Result:" "$result"
  if [[ -n "$requested_ver" ]]; then
    printf '  %-13s %s (%s)\n' "Requested:" "$requested_ver" "$requested_eval"
  fi
  msg ""
  msg "Suggested local version:"
  if [[ -n "$suggested_ver" ]]; then
    msg "  $suggested_ver"
    msg "  Reason: $suggested_reason"
  elif [[ -n "$requested_ver" ]]; then
    msg "  none"
    msg "  Reason: requested version is not present in supported markers"
  else
    msg "  none"
    msg "  Reason: no supported markers detected"
  fi
  msg ""
  msg "Policy:"
  if [[ -n "$policy_ver" ]]; then
    printf '  %-19s %s\n' "Trusted row match:" "yes (FSR4 ${policy_ver})"
  else
    printf '  %-19s %s\n' "Trusted row match:" "no"
  fi
  msg ""
  msg "Result:"
  msg "  Inspect only. Nothing installed. No allowlist changed."
}

fsr4_print_local_trust_plan() {
  local source_kind="${1:-unknown}" source_ref="${2:-}" picked_dll="${3:-}" selected_ver="${4:-}"
  local mz="" sha="" size=""

  fsr4_dll_fingerprint "$picked_dll" mz sha size || die "dll install: could not compute DLL fingerprint: $picked_dll"
  genvw_reset_install_allowlist_defaults "$selected_ver"

  msg "Local trust approval:"
  printf '  %-16s %s\n' "Source kind:" "$source_kind"
  printf '  %-16s %s\n' "Source:" "$source_ref"
  printf '  %-16s %s\n' "Picked DLL:" "$picked_dll"
  printf '  %-16s %s\n' "FSR4 version:" "$selected_ver"
  printf '  %-16s %s\n' "SHA256:" "$sha"
  printf '  %-16s %s\n' "SIZE:" "$size"
  printf '  %-16s %s\n' "Allowlist:" "$AMD_DLL_ALLOWLIST"
  msg "  Scope: local machine trust only; project policy is unchanged."
}

fsr4_print_ambiguous_install_guidance() {
  local source_kind="${1:-unknown}" source_ref="${2:-}" selected_ver="${3:-}"
  local source_flag="" keep_suffix=" --keep"
  case "$source_kind" in
    dll)
      source_flag="--dll"
      keep_suffix=""
      ;;
    exe) source_flag="--exe" ;;
    url) source_flag="--url" ;;
    *)
      source_flag="--dll"
      keep_suffix=""
      ;;
  esac

  msg ""
  msg "Next steps:"
  msg "  This source requires local fingerprint approval."
  if [[ -n "$selected_ver" ]]; then
    msg "  Rerun with an explicit version and local trust approval:"
    msg ""
    msg "    $(cmd_dll) install ${source_flag} ${source_ref} --ver ${selected_ver} --trust-local"
  else
    msg "  Run inspect to choose an explicit supported marker:"
    msg ""
    msg "    $(cmd_dll) inspect ${source_flag} ${source_ref}${keep_suffix}"
  fi
  msg ""
  msg "  Or inspect without installing:"
  msg "    $(cmd_dll) inspect ${source_flag} ${source_ref}${keep_suffix}"
}

fsr4_plan_local_trust_for_ambiguous_markers() {
  local picked_dll="${1:-}" source_kind="${2:-}" source_ref="${3:-}" requested_ver="${4:-}"
  local ver_explicit="${5:-0}" trust_local="${6:-0}" dry_run="${7:-0}"
  local -n __fsr4_plan_out_ver_ref="$8"
  local selected_ver="" markers_slash="" prompt=""
  local -a filename_markers=()
  local -a content_markers=()
  local -a all_markers=()
  local -a supported_markers=()
  local marker_result=""

  fsr4_dll_collect_marker_report "$picked_dll" filename_markers content_markers all_markers supported_markers marker_result
  if ((${#supported_markers[@]} <= 1)); then
    return 1
  fi

  markers_slash="$(fsr4_versions_slash_from_args "${supported_markers[@]}")"

  if ((ver_explicit == 1)); then
    if ! fsr4_array_contains "$requested_ver" "${supported_markers[@]}"; then
      err "dll install: requested FSR4 ${requested_ver} is not present in selected DLL markers: ${markers_slash}"
      msg "Nothing was installed."
      fsr4_dll_inspect_print_report "$source_kind" "$source_ref" "$picked_dll" "$requested_ver"
      return 1
    fi
    selected_ver="$requested_ver"
  else
    selected_ver="$(fsr4_highest_supported_version_from_args "${supported_markers[@]}")"
  fi

  if ((dry_run == 1)); then
    if ((trust_local == 1 && ver_explicit == 1)); then
      warn "dll install: selected DLL contains multiple FSR4 version markers: ${markers_slash}"
      msg "Dry run: would approve and install this DLL as FSR4 ${selected_ver}."
      fsr4_print_local_trust_plan "$source_kind" "$source_ref" "$picked_dll" "$selected_ver"
      __fsr4_plan_out_ver_ref="$selected_ver"
      declare -g GENVW_INSTALL_APPROVED_AMBIGUOUS_MARKERS=1
      declare -g GENVW_INSTALL_LOCAL_TRUST_APPROVED=1
      return 0
    fi
    err "dll install: selected DLL contains multiple FSR4 version markers: ${markers_slash}"
    msg ""
    msg "gENVW cannot safely auto-detect one FSR4 version from this DLL."
    msg "Nothing was installed."
    fsr4_dll_inspect_print_report "$source_kind" "$source_ref" "$picked_dll" "$requested_ver"
    fsr4_print_ambiguous_install_guidance "$source_kind" "$source_ref" "$selected_ver"
    return 1
  fi

  if ((trust_local == 1 && ver_explicit == 1)); then
    __fsr4_plan_out_ver_ref="$selected_ver"
    declare -g GENVW_INSTALL_APPROVED_AMBIGUOUS_MARKERS=1
    declare -g GENVW_INSTALL_LOCAL_TRUST_APPROVED=1
    return 0
  fi

  if ! is_tty; then
    err "dll install: selected DLL contains multiple FSR4 version markers: ${markers_slash}"
    msg ""
    msg "gENVW cannot safely auto-detect one FSR4 version from this DLL."
    msg "Nothing was installed."
    fsr4_dll_inspect_print_report "$source_kind" "$source_ref" "$picked_dll" "$requested_ver"
    if ((trust_local == 1 && ver_explicit == 0)); then
      msg ""
      msg "Non-interactive local trust approval requires an explicit --ver."
    fi
    fsr4_print_ambiguous_install_guidance "$source_kind" "$source_ref" "$selected_ver"
    return 1
  fi

  warn "dll install: selected DLL contains multiple FSR4 version markers: ${markers_slash}"
  msg ""
  msg "gENVW cannot safely auto-detect one FSR4 version from this DLL."
  fsr4_print_local_trust_plan "$source_kind" "$source_ref" "$picked_dll" "$selected_ver"
  msg ""
  prompt="Approve and install this DLL as FSR4 ${selected_ver} on this machine? [y/N]: "
  if ! ask_yes_no_default "$prompt" "n"; then
    msg "Nothing was installed."
    return 1
  fi

  __fsr4_plan_out_ver_ref="$selected_ver"
  declare -g GENVW_INSTALL_APPROVED_AMBIGUOUS_MARKERS=1
  declare -g GENVW_INSTALL_LOCAL_TRUST_APPROVED=1
  return 0
}

fsr4_resolve_install_ver_from_dll_markers() {
  local picked_dll="${1:-}" source_kind="${2:-}" source_ref="${3:-}" requested_ver="${4:-}"
  local ver_explicit="${5:-0}" trust_local="${6:-0}" dry_run="${7:-0}"
  local out_ver_name="${8:-}"
  local -n __fsr4_resolve_out_ver_ref="$out_ver_name"
  local -a all_markers=()
  local -a supported_markers=()

  fsr4_collect_dll_version_candidates "$picked_dll" all_markers
  fsr4_filter_local_write_supported_versions all_markers supported_markers

  if ((${#supported_markers[@]} == 1)); then
    __fsr4_resolve_out_ver_ref="${supported_markers[0]}"
    return 0
  fi

  if ((${#supported_markers[@]} == 0)); then
    if ((${#all_markers[@]} == 0)); then
      err "dll install: could not infer DLL FSR4 version from filename/content."
    else
      err "dll install: detected unsupported/unreleased DLL version candidate(s): $(fsr4_versions_slash_from_args "${all_markers[@]}"). Supported local-write versions: $(fsr4_local_only_versions_slash)."
    fi
    return 1
  fi

  fsr4_plan_local_trust_for_ambiguous_markers \
    "$picked_dll" \
    "$source_kind" \
    "$source_ref" \
    "$requested_ver" \
    "$ver_explicit" \
    "$trust_local" \
    "$dry_run" \
    "$out_ver_name"
}

fsr4_confirm_installed_content_for_ver() {
  local source_dll="${1:-}" installed_dll="${2:-}" selected_ver="${3:-}" approved_ambiguous="${4:-0}" ctx="${5:-dll install}"
  local -n out_confirmed_ref="$6"
  local detected_ver="" src_sha="" src_size="" dst_sha="" dst_size=""
  local -a content_markers=()
  local -a supported_markers=()

  out_confirmed_ref=""

  if ((approved_ambiguous == 1)); then
    fsr4_collect_dll_content_version_candidates "$installed_dll" content_markers
    fsr4_filter_local_write_supported_versions content_markers supported_markers
    if ! fsr4_array_contains "$selected_ver" "${supported_markers[@]}"; then
      err "${ctx}: installed DLL content does not contain selected supported FSR4 ${selected_ver} marker."
      return 1
    fi
    src_sha="$(sha256sum "$source_dll" 2>/dev/null | awk '{print $1}' || true)"
    dst_sha="$(sha256sum "$installed_dll" 2>/dev/null | awk '{print $1}' || true)"
    src_size="$(stat -c %s "$source_dll" 2>/dev/null || true)"
    dst_size="$(stat -c %s "$installed_dll" 2>/dev/null || true)"
    if [[ -z "$src_sha" || -z "$dst_sha" || "$src_sha" != "$dst_sha" || "$src_size" != "$dst_size" ]]; then
      err "${ctx}: installed DLL fingerprint does not match the approved source DLL."
      return 1
    fi
    out_confirmed_ref="$selected_ver"
    return 0
  fi

  if ! detected_ver="$(fsr4_detect_single_local_write_ver_from_dll_content "$installed_dll" "$ctx")"; then
    return 1
  fi
  out_confirmed_ref="$detected_ver"
}

fsr4_approve_installed_dll_local_allowlist() {
  local selected_ver="${1:-}" dst_dir="${2:-$DLL_DST_DIR_DEFAULT}"
  local expected="" dll_sha="" dll_size="" mz="" note="" appended=0
  [[ -n "$selected_ver" ]] || die "dll install: missing selected version for local trust approval"
  fsr4_require_local_write_supported_ver "$selected_ver" "dll install"
  genvw_reset_install_allowlist_defaults "$selected_ver"
  expected="$dst_dir/${AMD_DLL_NAME}"
  require_file "$expected" "installed DLL"
  fsr4_dll_fingerprint "$expected" mz dll_sha dll_size || die "dll install: could not compute installed DLL fingerprint: $expected"
  [[ "$mz" == "yes" ]] || die "dll install: installed DLL is missing an MZ header: $expected"
  note="$(fsr4_local_trust_allowlist_note_from_meta "$selected_ver" "$dst_dir")"
  fsr4_trusted_allowlist_ensure_entry "$selected_ver" "$dll_sha" "$dll_size" "$note" appended
  ok "Added local allowlist fingerprint:"
  msg "  SHA256: $dll_sha"
  msg "  SIZE:   $dll_size"
  if [[ "$appended" == "1" && -n "$note" ]]; then
    msg "  Note:   $note"
  fi
  msg "  Allowlist:"
  msg "    $AMD_DLL_ALLOWLIST"
}

amd_dll_extract_pick_prepare() {
  local dl="${1:-}" url="${2:-}" keep="${3:-0}" requested_ver="${4:-$FSR4_LOCAL_DEFAULT_VER}" ver_explicit="${5:-1}"
  local -n out_picked_ref="$6"
  local -n out_exdir_ref="$7"
  local -n out_drv_label_ref="$8"
  local -n out_reuse_ref="$9"
  local -n out_cands_ref="${10}"

  local prep_drv_label="" prep_exdir="" probePath="" f=""
  : "${requested_ver}" "${ver_explicit}" "${keep}"

  out_picked_ref=""
  out_exdir_ref=""
  out_drv_label_ref=""
  out_reuse_ref="0"
  out_cands_ref=()

  if [[ -n "$dl" ]]; then
    step "Using driver EXE: $dl"
  elif [[ -n "$url" ]]; then
    step "Using driver URL: $url"
  else
    die "Internal error: missing driver source (no dl/url)"
  fi

  prep_drv_label="$(amd_driver_label_from_source "$dl" "$url")"
  prep_drv_label="${prep_drv_label%.[eE][xX][eE]}"
  prep_exdir="$AMD_EXTRACT_ROOT/$prep_drv_label"
  declare -g __GENVW_EXDIR="$prep_exdir"
  mkdir -p -- "$prep_exdir" >/dev/null 2>&1 || true

  probePath="$(find "$prep_exdir" -type f -name "${AMD_DLL_SRC_NAME}" -print -quit 2>/dev/null || true)"
  if [[ -n "$probePath" ]]; then
    out_reuse_ref="1"
    info "Reuse extracted driver cache (skip extraction): $prep_exdir"
  fi

  if [[ "$out_reuse_ref" != "1" ]]; then
    step "${I_DL} Extracting driver..."
    msg "${I_BOX} Extracting to:"
    msg "  $prep_exdir"
    require_file "$dl" "--exe"
    _amd_extract_exe "$dl" "$prep_exdir"
  fi

  if [[ "$ver_explicit" == "1" ]]; then
    step "${I_SEARCH} Searching for ${AMD_DLL_SRC_NAME} (install as ${AMD_DLL_NAME})..."
  else
    step "${I_SEARCH} Searching for ${AMD_DLL_SRC_NAME} (version auto-detect pending)..."
  fi
  while IFS= read -r -d '' f; do
    out_cands_ref+=("$f")
  done < <(find "$prep_exdir" -type f -name "${AMD_DLL_SRC_NAME}" -print0 2>/dev/null || true)

  if [[ "${#out_cands_ref[@]}" -eq 0 ]]; then
    die "Could not find ${AMD_DLL_SRC_NAME} in extracted driver: $prep_drv_label"
  fi

  out_picked_ref="$(amd_pick_best_dll_candidate "${out_cands_ref[@]}")"
  [[ -n "$out_picked_ref" ]] || die "Could not pick a DLL candidate from extracted files"

  ok "Picked: $out_picked_ref"
  out_exdir_ref="$prep_exdir"
  out_drv_label_ref="$prep_drv_label"
}

# require_file: file must exist (used for --exe / --pfx-dll).
require_file() {
  local p="${1:-}"
  local flag="${2:-path}"
  [[ -n "$p" ]] || die "${flag} requires a value"
  [[ -f "$p" ]] || die "${flag}: file not found: $p"
}

# option parsing

parse_kv_flags() {
  declare -g GENVW_KV_HELP=0
  declare -g GENVW_VERBOSE="${GENVW_VERBOSE:-0}"
  declare -g GENVW_SOURCE_SELECTION="default"
  declare -g GENVW_MAJOR_SELECTION_MODE="${GENVW_MAJOR_SELECTION_DEFAULT_MODE:-all_supported}"
  declare -g FSR4_VER_EXPLICIT=0
  declare -g LOCALDLL_EXPLICIT=0
  declare -g BUILD_DATE_EXPLICIT=0
  FSR4_VER="${FSR4_LOCAL_DEFAULT_VER}"
  amd_set_cache_names_for_ver "${FSR4_VER}"
  validate_amd_cache_names
  CTD=""
  CTD_SET=0
  CTD_REQUIRED=1 # default is "ctd required"
  MAJOR="$MAJOR_DEFAULT"
  SUFFIX="$SUFFIX_DEFAULT"
  TAG="$TAG_DEFAULT"
  LOCALDLL="${DLL_DST_DIR_DEFAULT}/${AMD_DLL_NAME}"
  BUILD_DATE=""
  CLEAN_OLD=0
  DRY_RUN=0
  DWPROTON_PREVIEW=0
  local localdll_set=0
  local localdll_value=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ctd-optional | --no-ctd-required)
        # ctd optional for non-destructive subcommands (status/check).
        CTD_REQUIRED=0
        shift
        ;;

      --allow-steam)
        ALLOW_STEAM=1
        shift
        ;;
      --prefer-system-sources)
        [[ "${GENVW_SOURCE_SELECTION}" == "system_only" ]] && die "--prefer-system-sources conflicts with --system-sources-only"
        GENVW_SOURCE_SELECTION="prefer_system"
        shift
        ;;
      --system-sources-only)
        [[ "${GENVW_SOURCE_SELECTION}" == "prefer_system" ]] && die "--system-sources-only conflicts with --prefer-system-sources"
        GENVW_SOURCE_SELECTION="system_only"
        shift
        ;;
      --ctd)
        require_flag_value --ctd "${2-}"
        CTD="$2"
        CTD_SET=1
        shift 2
        ;;
      --major)
        require_flag_value --major "${2-}"
        MAJOR="$2"
        GENVW_MAJOR_SELECTION_MODE="explicit"
        shift 2
        ;;
      --suffix)
        # allow: --suffix "" (empty means "use default")
        # reject: missing argument entirely
        (($# >= 2)) || die "--suffix requires a value (use --suffix \"\" to default to ${SUFFIX_DEFAULT})"

        SUFFIX="${2-}"       # may be empty on purpose
        SUFFIX="${SUFFIX#-}" # allow "-gENVW" too

        # validate when non-empty
        validate_suffix "${SUFFIX-}"

        # suffix locked to "gENVW" by design (avoids broad matching surprises).
        if [[ -n "${SUFFIX}" && "${SUFFIX}" != "${SUFFIX_DEFAULT}" ]]; then
          die "--suffix only supports: ${SUFFIX_DEFAULT} (use --suffix \"\" to default)"
        fi

        shift 2
        ;;
      --ver)
        require_flag_value --ver "${2-}"
        FSR4_VER="$2"
        # only dotted version strings like 4.0.3 (no spaces, no slashes).
        if ! fsr4_ver_syntax_ok "${FSR4_VER}"; then
          die "--ver must look like X.Y.Z (example: ${FSR4_LOCAL_DEFAULT_VER}): ${FSR4_VER}"
        fi
        FSR4_VER_EXPLICIT=1
        amd_set_cache_names_for_ver "${FSR4_VER}"
        LOCALDLL="${DLL_DST_DIR_DEFAULT}/${AMD_DLL_NAME}"
        shift 2
        ;;

      --tag)
        require_flag_value --tag "${2-}"
        TAG="$2"
        shift 2
        ;;
      --localdll)
        require_flag_value --localdll "${2-}"
        localdll_value="$2"
        localdll_set=1
        shift 2
        ;;
      --date)
        require_flag_value --date "${2-}"
        BUILD_DATE="$2"
        BUILD_DATE_EXPLICIT=1
        shift 2
        ;;
      --old)
        CLEAN_OLD=1
        shift
        ;;
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      --dwproton-preview)
        DWPROTON_PREVIEW=1
        shift
        ;;
      --verbose | --debug)
        declare -g GENVW_VERBOSE=1
        shift
        ;;
      -h | --help)
        usage
        declare -g GENVW_KV_HELP=1
        return 0
        ;;
      *) die "Unknown flag: $1" ;;
    esac
  done

  if ((localdll_set == 1)); then
    local __expected_localdll="${DLL_DST_DIR_DEFAULT}/${AMD_DLL_NAME}"
    if [[ "$localdll_value" != "$__expected_localdll" ]]; then
      die "--localdll is restricted to the canonical path only: $__expected_localdll"
    fi
    LOCALDLL="$localdll_value"
    LOCALDLL_EXPLICIT=1
  fi

  # fail fast on malformed inputs before any CTD/source scanning.
  validate_major "$MAJOR"
  if ((CTD_SET == 1)); then
    if ((CTD_REQUIRED == 1)); then
      validate_ctd "$CTD"
    elif [[ -n "$CTD" && -d "$CTD" ]]; then
      # optional mode keeps legacy behavior: only validate when the provided dir exists.
      validate_ctd "$CTD"
    fi
  fi
  if [[ -n "$BUILD_DATE" ]]; then
    validate_date_yyyymmdd "$BUILD_DATE"
  fi

  if ((CTD_SET == 0)); then
    steam_detect_ctd "$MAJOR" "$GENVW_MAJOR_SELECTION_MODE"
    CTD="$STEAM_CTD_CHOSEN"
  else
    # --ctd provided: derive steam fields from it so kv/status never go blank.
    STEAM_CTD_CHOSEN="$CTD"
    STEAM_ROOT="$(dirname -- "$CTD")"
    if [[ "$CTD" == *"/.var/app/com.valvesoftware.Steam/"* ]]; then
      STEAM_KIND="flatpak"
    else
      STEAM_KIND="native"
    fi

    # count eligible sources in this ctd (same filter as auto-detect).
    local min_date="${MIN_SUPPORTED_DATE_GENVW:-20251222}"
    [[ "$min_date" =~ ^[0-9]{8}$ ]] || min_date=20251222
    local suffix_default="${SUFFIX_DEFAULT:-gENVW}"
    local suffix_effective="${SUFFIX#-}"
    local ctd_sources=0
    # By design, source counts only include real directories, not symlinked clones.
    # Impact: users who symlink clone dirs into CTD may see lower source counts.
    ctd_sources="$(source_ctd_supported_source_count "$CTD" "$MAJOR" "$min_date" "$suffix_effective" "$GENVW_MAJOR_SELECTION_MODE")"
    STEAM_CTD_SOURCES="$ctd_sources"
  fi

  # normalize/default suffix early so safety checks behave the same everywhere
  SUFFIX="${SUFFIX#-}"
  if [[ -z "${SUFFIX}" ]]; then
    SUFFIX="${SUFFIX_DEFAULT}"
  fi

  # safety validation
  validate_major "$MAJOR"
  validate_suffix "$SUFFIX"

  # ctd validation can be mode-aware (status/check can run without steam).
  if ((CTD_REQUIRED == 1)); then
    validate_ctd "$CTD"
  else
    # optional ctd: validate only when the directory exists.
    if [[ -n "$CTD" && -d "$CTD" ]]; then
      validate_ctd "$CTD"
    fi
  fi

  if [[ -n "$BUILD_DATE" ]]; then
    validate_date_yyyymmdd "$BUILD_DATE"
  fi
}

rebuild_normalize_provider_filter() {
  case "${1:-all}" in
    all) printf '%s\n' "all" ;;
    cachyos | proton-cachyos) printf '%s\n' "cachyos" ;;
    dw | dwproton | dw-proton) printf '%s\n' "dwproton" ;;
    *) die "Unknown rebuild provider: ${1:-}. Allowed values: all, cachyos, proton-cachyos, dw, dwproton, dw-proton" ;;
  esac
}

parse_rebuild_flags() {
  declare -g REBUILD_PROVIDER_FILTER="all"
  declare -g REBUILD_MISSING_ONLY=0
  declare -g REBUILD_TARGET_KIND="default"
  declare -g REBUILD_TARGET_ID=""
  declare -g REBUILD_TARGET_EXPLICIT=0
  declare -g REBUILD_ALL_TARGETS=0
  local -a passthrough=()
  local _target_raw=""
  local _exact_target_id=""
  local _provider_explicit=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --provider | -p)
        local _pflag="$1"
        require_flag_value "$_pflag" "${2-}"
        REBUILD_PROVIDER_FILTER="$(rebuild_normalize_provider_filter "$2")"
        _provider_explicit=1
        shift 2
        ;;
      --missing-only)
        REBUILD_MISSING_ONLY=1
        shift
        ;;
      --target | -t)
        local _tflag="$1"
        require_flag_value "$_tflag" "${2-}"
        _target_raw="$2"
        shift 2
        ;;
      --all-targets)
        REBUILD_ALL_TARGETS=1
        shift
        ;;
      --target-id)
        require_flag_value --target-id "${2-}"
        _exact_target_id="$2"
        shift 2
        ;;
      *)
        passthrough+=("$1")
        shift
        ;;
    esac
  done
  declare -g REBUILD_TARGET_RAW="${_target_raw}"
  declare -g REBUILD_EXACT_TARGET_ID="${_exact_target_id}"
  declare -g REBUILD_PROVIDER_EXPLICIT="${_provider_explicit}"

  parse_kv_flags "${passthrough[@]}"
  rebuild_validate_provider_date_scope
  if [[ "${REBUILD_ALL_TARGETS:-0}" -eq 1 ]]; then
    [[ -z "${_exact_target_id:-}" ]] || die "--target-id cannot be combined with --all-targets."
    rebuild_validate_all_targets_scope
  elif [[ -n "${REBUILD_TARGET_RAW:-}" ]]; then
    [[ -z "${_exact_target_id:-}" ]] || die "--target-id cannot be combined with --target."
    rebuild_validate_target_scope
  elif [[ -n "${_exact_target_id:-}" ]]; then
    rebuild_validate_exact_id_scope
  else
    rebuild_target_model_normalize_from_flags
  fi
}

rebuild_date_filter_active() {
  [[ -n "${BUILD_DATE:-}" ]]
}

rebuild_validate_provider_date_scope() {
  rebuild_date_filter_active || return 0
  case "${REBUILD_PROVIDER_FILTER:-all}" in
    all)
      REBUILD_PROVIDER_FILTER="cachyos"
      ;;
    cachyos)
      ;;
    dwproton)
      die "rebuild --date applies only to CachyOS Proton targets; use --provider cachyos or omit --date for DW-Proton rebuilds."
      ;;
  esac
}

rebuild_includes_cachyos() {
  [[ "${REBUILD_PROVIDER_FILTER:-all}" == "all" || "${REBUILD_PROVIDER_FILTER:-all}" == "cachyos" ]]
}

rebuild_includes_dwproton() {
  [[ "${REBUILD_PROVIDER_FILTER:-all}" == "all" || "${REBUILD_PROVIDER_FILTER:-all}" == "dwproton" ]]
}

rebuild_target_model_reset() {
  declare -g REBUILD_TARGET_KIND="default"
  declare -g REBUILD_TARGET_ID=""
  declare -g REBUILD_TARGET_EXPLICIT=0
}

rebuild_target_model_set_cachyos_date() {
  REBUILD_TARGET_KIND="cachyos_date"
  REBUILD_TARGET_ID="${BUILD_DATE:-}"
  REBUILD_TARGET_EXPLICIT=1
}

rebuild_target_model_normalize_from_flags() {
  if rebuild_date_filter_active; then
    rebuild_target_model_set_cachyos_date
  else
    rebuild_target_model_reset
  fi
}

rebuild_target_kind_is_cachyos_date() {
  [[ "${REBUILD_TARGET_KIND:-default}" == "cachyos_date" ]]
}

rebuild_target_kind_is_default() {
  [[ "${REBUILD_TARGET_KIND:-default}" == "default" ]]
}

rebuild_target_model_record() {
  printf 'TARGET_SCHEMA=1\n'
  printf 'TARGET_SCOPE=rebuild-internal\n'
  printf 'PROVIDER=%s\n' "${REBUILD_PROVIDER_FILTER:-all}"
  printf 'TARGET_KIND=%s\n' "${REBUILD_TARGET_KIND:-default}"
  printf 'TARGET_ID=%s\n' "${REBUILD_TARGET_ID:-}"
  printf 'TARGET_EXPLICIT=%s\n' "${REBUILD_TARGET_EXPLICIT:-0}"
}

rebuild_target_model_set_dw_release() {
  REBUILD_TARGET_KIND="dw_release"
  REBUILD_TARGET_ID="${REBUILD_TARGET_RAW:-}"
  REBUILD_TARGET_EXPLICIT=1
}

rebuild_target_kind_is_dw_release() {
  [[ "${REBUILD_TARGET_KIND:-default}" == "dw_release" ]]
}

rebuild_validate_target_shape_cachyos() {
  [[ "${1:-}" =~ ^[0-9]{8}$ ]] || die "Invalid CachyOS target '${1:-}': expected 8-digit build date (e.g. 20260424)."
}

rebuild_validate_target_shape_dw() {
  [[ "${1:-}" =~ ^[0-9]+\.[0-9]+-[0-9]+$ ]] || die "Invalid DW-Proton target '${1:-}': expected release like 11.0-2."
}

rebuild_validate_target_scope() {
  local target="${REBUILD_TARGET_RAW:-}"
  local provider="${REBUILD_PROVIDER_FILTER:-all}"

  [[ -z "$target" ]] && return 0

  [[ "${REBUILD_PROVIDER_EXPLICIT:-0}" -eq 1 ]] || die "--target requires an explicit --provider (cachyos, dw, dwproton, dw-proton, proton-cachyos)."

  rebuild_date_filter_active && die "--target and --date cannot be combined. Use one selector."

  [[ "$provider" == "all" ]] && die "--target requires a specific provider, not 'all'."

  case "$provider" in
    cachyos)
      rebuild_validate_target_shape_cachyos "$target"
      BUILD_DATE="$target"
      BUILD_DATE_EXPLICIT=1
      rebuild_target_model_set_cachyos_date
      ;;
    dwproton)
      rebuild_validate_target_shape_dw "$target"
      rebuild_target_model_set_dw_release
      ;;
  esac
}

rebuild_target_model_set_all_targets() {
  REBUILD_TARGET_KIND="all_targets"
  REBUILD_TARGET_ID=""
  REBUILD_TARGET_EXPLICIT=1
}

rebuild_target_kind_is_all_targets() {
  [[ "${REBUILD_TARGET_KIND:-default}" == "all_targets" ]]
}

rebuild_validate_all_targets_scope() {
  [[ -z "${REBUILD_TARGET_RAW:-}" ]] || die "rebuild --all-targets cannot be combined with --target."
  rebuild_date_filter_active && die "rebuild --all-targets cannot be combined with --date."
  rebuild_target_model_set_all_targets
}

rebuild_target_model_set_exact_id() {
  REBUILD_TARGET_KIND="exact_id"
  REBUILD_TARGET_ID="${REBUILD_EXACT_TARGET_ID:-}"
  REBUILD_TARGET_EXPLICIT=1
}

rebuild_target_kind_is_exact_id() {
  [[ "${REBUILD_TARGET_KIND:-default}" == "exact_id" ]]
}

rebuild_validate_exact_id_scope() {
  local _id="${REBUILD_EXACT_TARGET_ID:-}"
  [[ -n "$_id" ]] || return 0
  [[ "${REBUILD_PROVIDER_EXPLICIT:-0}" -eq 1 ]] \
    || die "--target-id requires an explicit --provider (cachyos or dwproton)."
  local _prov="${REBUILD_PROVIDER_FILTER:-all}"
  [[ "$_prov" == "all" ]] \
    && die "--target-id requires a specific provider, not 'all'."
  [[ "$_prov" == "cachyos" || "$_prov" == "dwproton" ]] \
    || die "--target-id requires --provider cachyos or --provider dwproton."
  rebuild_date_filter_active && die "--target-id cannot be combined with --date."
  rebuild_target_model_set_exact_id
}

pick_sources_for_exact_id() {
  local want_id="${REBUILD_TARGET_ID:-}"
  local src="" base="" rec=""
  local -a matched=()
  PICKED=()
  for src in "${SOURCES[@]}"; do
    rec="$(source_list_metadata_record "$src" 2>/dev/null || true)"
    if [[ -n "$rec" ]]; then
      base="${rec%%|*}"
    else
      base="${src##*/}"
    fi
    [[ "$base" == "$want_id" ]] || continue
    matched+=("$src")
  done
  if ((${#matched[@]} == 0)); then
    die "target id '${want_id}' not found in: $CTD"
  fi
  if ((${#matched[@]} > 1)); then
    die "target id '${want_id}' matched ${#matched[@]} sources; expected exactly one."
  fi
  PICKED=("${matched[@]}")
}

filter_dwproton_targets_by_exact_id() {
  local -n _fdte_in="$1"
  local -n _fdte_out="$2"
  local _want_id="$3"
  local _d="" _base="" _version="" _arch="" _core=""

  _fdte_out=()
  for _d in "${_fdte_in[@]}"; do
    _base="${_d##*/}"
    _version="$(dwproton_folder_version "$_base" 2>/dev/null || true)"
    [[ -n "$_version" ]] || continue
    _arch="$(dwproton_display_arch_for_path "$_d" "$_version" 2>/dev/null || true)"
    [[ -n "$_arch" ]] || continue
    _core="dwproton-${_version}-${_arch}"
    [[ "$_core" == "$_want_id" ]] || continue
    _fdte_out+=("$_d")
  done
}

pick_all_supported_sources_for_rebuild() {
  PICKED=("${SUPPORTED_SOURCES[@]}")
}

filter_dwproton_targets_by_release() {
  local -n _fdt_in="$1"
  local -n _fdt_out="$2"
  local _release="$3"
  local _row="" _version="" _base=""

  _fdt_out=()
  for _row in "${_fdt_in[@]}"; do
    _base="${_row##*/}"
    _version="$(dwproton_folder_version "$_base" 2>/dev/null || true)"
    if [[ "$_version" == "$_release" ]]; then
      _fdt_out+=("$_row")
    fi
  done
}

# amd dll installer

validate_major() {
  local major="${1:-}"
  [[ -n "$major" ]] || die "--major cannot be empty"
  [[ "$major" =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "Invalid --major '$major' (expected like 10 or 10.0)"
}

validate_suffix() {
  local s="${1:-}"
  s="${s#-}"

  # empty is ok here; caller defaults it later.
  [[ -n "$s" ]] || return 0

  [[ "$s" != *"/"* ]] || die "Invalid --suffix '$s' (must not contain '/')"
  [[ "$s" != *"\\"* ]] || die "Invalid --suffix '$s' (must not contain '\\')"
  [[ "$s" != *$'\n'* && "$s" != *$'\r'* && "$s" != *$'\t'* && "$s" != *" "* ]] \
    || die "Invalid --suffix '$s' (must not contain whitespace)"
  [[ "$s" != *"*"* && "$s" != *"?"* && "$s" != *"["* && "$s" != *"]"* ]] \
    || die "Invalid --suffix '$s' (must not contain glob characters: * ? [ ])"
  [[ "$s" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
    || die "Invalid --suffix '$s' (allowed: A-Z a-z 0-9 . _ - ; must start with alnum)"
  [[ "$s" != "." && "$s" != ".." ]] || die "Invalid --suffix '$s'"
  ((${#s} <= 48)) || die "Invalid --suffix '$s' (too long; max 48 chars)"
}

# validate_ctd

validate_ctd() {
  local ctd="${1:-}"
  [[ -n "$ctd" ]] || die "--ctd cannot be empty"
  # hard stop: must be a compatibilitytools.d folder
  [[ "$ctd" == *"/compatibilitytools.d" ]] || die "Refusing --ctd '$ctd' (must end with /compatibilitytools.d)"
  # hard stop: refuse obviously dangerous targets
  [[ "$ctd" != "/" && "$ctd" != "$HOME" && "$ctd" != "$HOME/" ]] || die "Refusing dangerous --ctd '$ctd'"
  [[ -d "$ctd" ]] || die "compatibilitytools.d not found: $ctd"
}

# amd_url_allowed
# allowlist for --url downloads.

amd_url_allowed() {
  local url="${1:-}"
  case "$url" in
    https://drivers.amd.com/* | https://download.amd.com/* | https://www.amd.com/*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# validate_amd_cache_names

amd_cleanup_extract_dir() {
  # cleanup handler for extracted driver dirs (safe under `set -u`).
  local flag="${__GENVW_EXDIR_CLEANUP:-1}"
  local dir="${__GENVW_EXDIR:-}"

  # tolerate '"1"' and other odd values.
  flag="${flag//\"/}"
  case "$flag" in
    1 | true | yes | y | on) ;;
    *) return 0 ;;
  esac

  [[ -n "$dir" ]] || return 0
  local root="${AMD_EXTRACT_ROOT:-}"
  [[ -n "$root" ]] || return 0
  case "$dir" in
    "$root"/*) ;;
    *) return 0 ;;
  esac
  rm_rf_within_root "$AMD_EXTRACT_ROOT" "$dir" >/dev/null 2>&1 || true
}

_validate_one_amd_cache_name() {
  local env_name="${1:-ENV}" n="${2:-}"
  [[ -n "$n" ]] || die "Invalid ${env_name}: empty"
  [[ "$n" != *"/"* ]] || die "Invalid ${env_name} (must not contain '/'): $n"
  [[ "$n" != *".."* ]] || die "Invalid ${env_name} (must not contain '..'): $n"
  [[ "$n" != "." ]] || die "Invalid ${env_name}: $n"
  [[ "$n" =~ ^[A-Za-z0-9.][A-Za-z0-9._-]*$ ]] || die "Invalid ${env_name}: $n"
}

validate_amd_cache_names() {
  # restrict cache names to safe basenames (no slashes, no traversal).

  _validate_one_amd_cache_name "GENVW_AMD_DLL_NAME" "${AMD_DLL_NAME}"
  _validate_one_amd_cache_name "GENVW_AMD_META_NAME" "${AMD_META_NAME}"
  _validate_one_amd_cache_name "GENVW_AMD_REPORT_NAME" "${AMD_REPORT_NAME}"
  _validate_one_amd_cache_name "GENVW_AMD_ALLOWLIST_NAME" "${AMD_ALLOWLIST_NAME}"
  _validate_one_amd_cache_name "GENVW_AMD_LOCK_NAME" "${AMD_LOCK_NAME}"
  _validate_one_amd_cache_name "GENVW_AMD_DLL_SRC_NAME" "${AMD_DLL_SRC_NAME}"
  [[ "${AMD_DLL_SRC_NAME}" == *.dll ]] \
    || die "Invalid GENVW_AMD_DLL_SRC_NAME (must end with .dll): ${AMD_DLL_SRC_NAME}"
}

validate_7z_archive_paths() {
  # back-compat wrapper: older patch series may still call this name.
  validate_7z_archive_listing "$@"
}

validate_extraction_tree() {
  # extraction guardrails:
  # - refuse symlinks under the extracted dir
  # - refuse any path that resolves outside the extracted root
  local exdir="${1:-}"
  [[ -n "$exdir" ]] || die "validate_extraction_tree: missing exdir"
  [[ -d "$exdir" ]] || die "validate_extraction_tree: not a directory: $exdir"
  need_cmd readlink

  local exroot
  exroot="$(readlink -f -- "$exdir" 2>/dev/null)" || die "Failed to resolve exdir: $exdir"

  # refuse any symlinks (even broken ones)
  local -a syms=()
  mapfile -t syms < <(find "$exdir" -type l -o -xtype l 2>/dev/null || true)
  if ((${#syms[@]} > 0)); then
    err "Refusing extracted tree containing symlinks (possible escape/trick):"
    printf '  %s\n' "${syms[@]:0:30}" >&2
    ((${#syms[@]} > 30)) && err "  ... and more"
    die "Extraction validation failed (symlinks present)."
  fi

  # every path must resolve under exroot
  local p rp
  while IFS= read -r -d '' p; do
    rp="$(readlink -f -- "$p" 2>/dev/null || true)"
    [[ -n "$rp" ]] || continue
    [[ "$rp" == "$exroot"* ]] || die "Extraction produced path outside exdir: $p -> $rp"
  done < <(find "$exdir" -mindepth 1 -print0 2>/dev/null || true)
}

validate_7z_archive_listing() {
  # archive member path checks (absolute paths, traversal, weird 7z sfx entries).
  local archive="${1:-}"
  [[ -n "$archive" ]] || die "Archive listing validation: missing archive path"
  [[ -f "$archive" ]] || die "Archive listing validation: not found: $archive"

  need_cmd 7z
  need_cmd readlink
  need_cmd basename

  local arch_abs arch_base
  arch_abs="$(readlink -f -- "$archive" 2>/dev/null || printf '%s' "$archive")"
  arch_base="$(basename -- "$archive" 2>/dev/null || true)"

  local line path norm
  while IFS= read -r line; do
    [[ "$line" == "Path = "* ]] || continue
    path="${line#Path = }"

    # ignore 7z pseudo entries like [0], [1], etc (common in sfx exes)
    if [[ "$path" =~ ^\[[0-9]+\]$ ]]; then
      continue
    fi

    # normalize for comparisons
    norm="${path//\\//}"
    norm="${norm#./}"

    # ignore "self entry" where 7z lists the archive itself as a member
    if [[ "$norm" == "$archive" || "$norm" == "$arch_abs" || "$norm" == "$arch_base" ]]; then
      continue
    fi

    # tolerate an absolute self entry that matches the archive
    if [[ "$norm" == /* ]]; then
      local bn=""
      bn="$(basename -- "$norm" 2>/dev/null || true)"
      if [[ -n "$bn" && "$bn" == "$arch_base" && "$norm" == "$arch_abs" ]]; then
        continue
      fi
    fi
    # refuse absolute paths (unix or windows drive roots)
    if [[ "$norm" == /* || "$norm" =~ ^[A-Za-z]:/ ]]; then
      err "Refusing archive member with absolute path: $path"
      return 1
    fi

    # refuse traversal
    if [[ "$norm" == ".." || "$norm" == ../* || "$norm" == */../* || "$norm" == */.. ]]; then
      err "Refusing archive member with path traversal: $path"
      return 1
    fi
  done < <(7z l -slt -- "$archive" 2>/dev/null || true)

  return 0
}

amd_dll_prereq_check() {
  local missing_required=()
  local missing_optional=()
  msg "${I_SEARCH} genvw_proton DLL install prereq check"

  # required tools for download+extract+search+install
  if [[ "${GENVW_DLL_NEEDS_WGET:-0}" == "1" ]] && ! have wget; then
    missing_required+=("wget")
  fi
  have 7z || missing_required+=("7z (p7zip)")
  have find || missing_required+=("find (findutils)")
  have mkdir || missing_required+=("mkdir (coreutils)")
  have rm || missing_required+=("rm (coreutils)")
  have cp || missing_required+=("cp (coreutils)")
  have ln || missing_required+=("ln (coreutils)")
  have basename || missing_required+=("basename (coreutils)")
  have date || missing_required+=("date (coreutils)")
  have readlink || missing_required+=("readlink (coreutils)")
  have stat || missing_required+=("stat (coreutils)")
  have mktemp || missing_required+=("mktemp (coreutils)")
  have mv || missing_required+=("mv (coreutils)")
  # provenance meta needs sha256sum; keep it required.
  have sha256sum || missing_required+=("sha256sum (coreutils)")

  # optional helpers (nice-to-have)
  have exiftool || have strings || missing_optional+=("exiftool or strings (version info)")
  have sort || missing_optional+=("sort (nicer candidate ordering)")
  have cabextract || missing_optional+=("cabextract (only if DLL is buried in CABs)")
  have file || missing_optional+=("file (extra info)")

  if ((${#missing_required[@]} > 0)); then
    die "Missing required: ${missing_required[*]}"
  fi
  if ((${#missing_optional[@]} > 0)); then
    warn "Missing optional: ${missing_optional[*]}"
  fi
  ok "All required prerequisites satisfied."
  return 0
}

amd_dll_uninstall() {
  # remove the cached dll + its sidecar files (meta/report) if present.
  local dst_dir="${1:-$DLL_DST_DIR_DEFAULT}"
  validate_amd_cache_names
  mkdir -p -- "$dst_dir" >/dev/null 2>&1 || true
  amd_require_local_cache_delete_root "$dst_dir"

  local dll="$dst_dir/${AMD_DLL_NAME}"
  local meta="$dst_dir/${AMD_META_NAME}"
  local report="$dst_dir/${AMD_REPORT_NAME}"

  local removed=0
  if [[ -f "$dll" ]]; then
    rm_f_within_root "$dst_dir" "$dll" && removed=$((removed + 1))
  fi
  if [[ -f "$meta" ]]; then
    rm_f_within_root "$dst_dir" "$meta" && removed=$((removed + 1))
  fi
  if [[ -f "$report" ]]; then
    rm_f_within_root "$dst_dir" "$report" && removed=$((removed + 1))
  fi

  if ((removed == 0)); then
    msg "${I_INFO}  Nothing to remove (no ${AMD_DLL_NAME}/${AMD_META_NAME}/${AMD_REPORT_NAME} in this folder)."
  else
    ok "Removed $removed file(s) from: $dst_dir"
  fi
}

amd_dll_uninstall_all() {
  # remove all versioned cached dll/meta/report triplets for this stem.
  local dst_dir="${1:-$DLL_DST_DIR_DEFAULT}"
  local removed=0
  local had_nullglob=0
  local f

  validate_amd_cache_names
  mkdir -p -- "$dst_dir" >/dev/null 2>&1 || true
  amd_require_local_cache_delete_root "$dst_dir"

  shopt -q nullglob && had_nullglob=1
  shopt -s nullglob
  for f in \
    "$dst_dir/${AMD_DLL_STEM}_v"*.dll \
    "$dst_dir/${AMD_DLL_STEM}_v"*.meta.txt \
    "$dst_dir/${AMD_DLL_STEM}_v"*.report.txt; do
    [[ -f "$f" ]] || continue
    rm_f_within_root "$dst_dir" "$f" && removed=$((removed + 1))
  done
  ((had_nullglob == 1)) || shopt -u nullglob

  if ((removed == 0)); then
    msg "${I_INFO}  Nothing to remove (no ${AMD_DLL_STEM}_v*.dll/.meta.txt/.report.txt in this folder)."
  else
    ok "Removed $removed file(s) from: $dst_dir"
  fi
}

amd_dll_check() {
  # show dll fingerprints + sidecar presence.
  local dst_dir="${1:-$DLL_DST_DIR_DEFAULT}"
  validate_amd_cache_names
  mkdir -p -- "$dst_dir" >/dev/null 2>&1 || true

  local expected="$dst_dir/${AMD_DLL_NAME}"
  local meta="$dst_dir/${AMD_META_NAME}"
  local report_file="$dst_dir/${AMD_REPORT_NAME}"

  if [[ ! -f "$expected" ]]; then
    warn "Not installed (missing): $expected"
    msg "${I_INFO} Cache folder: $dst_dir"
    return 1
  fi

  local sha sz
  sha="$(sha256sum "$expected" 2>/dev/null | awk '{print $1}' || true)"
  sz="$(stat -c %s "$expected" 2>/dev/null || echo 0)"

  ok "Installed: $expected"
  msg "  size: ${sz} bytes"
  [[ -n "$sha" ]] && msg "  sha256: $sha"

  if [[ -f "$meta" ]]; then
    ok "Meta: $meta"
  else
    warn "Meta missing: $meta"
  fi

  if [[ -f "$report_file" ]]; then
    ok "Report: $report_file"
  else
    msg "${I_INFO} Report not present: $report_file"
  fi

  return 0
}

amd_dll_verify_report() {
  local dst_dir="${1:-$DLL_DST_DIR_DEFAULT}"
  local want_ver="${2:-$FSR4_LOCAL_DEFAULT_VER}"
  validate_amd_cache_names
  mkdir -p -- "$dst_dir" >/dev/null 2>&1 || true

  local expected="$dst_dir/${AMD_DLL_NAME}"
  local meta="$dst_dir/${AMD_META_NAME}"
  local report_file="$dst_dir/${AMD_REPORT_NAME}"
  local dll_present=0 meta_present=0 report_present=0
  local dll_size="" dll_sha="" meta_sha="" meta_size=""
  local meta_match=0 meta_reason="missing_meta"
  local allow_match=0 allow_reason="dll_missing"
  local allow_path="${AMD_DLL_ALLOWLIST}"
  local dll_state="MISSING" dll_detail="${AMD_DLL_NAME}"
  local meta_state="MISSING" meta_detail="${AMD_META_NAME}"
  local report_state="MISSING" report_detail="${AMD_REPORT_NAME}"
  local trust_match=0 _trust_label="untrusted" _trust_summary="META_MATCH=0, ALLOWLIST_MATCH=0" _trust_reason="missing_meta"
  local prov_state="BLOCKED" prov_detail="meta missing"
  local trust_state="BLOCKED" trust_detail="DLL missing"
  local result_text="Not Installed"
  local rc=0
  local _unused_src_url=""

  [[ -f "$expected" ]] && dll_present=1
  [[ -f "$meta" ]] && meta_present=1
  [[ -f "$report_file" ]] && report_present=1

  if ((dll_present == 1)); then
    dll_state="READY"
    amd_dll_provenance_integrity_decide_with_opts \
      "$expected" \
      "$meta" \
      0 \
      1 \
      meta_match \
      meta_reason \
      allow_match \
      allow_reason \
      trust_match \
      _trust_summary \
      _trust_reason \
      dll_sha \
      dll_size \
      meta_sha \
      meta_size \
      _unused_src_url
  fi

  if ((meta_present == 1)); then
    meta_state="READY"
  fi

  if ((report_present == 1)); then
    report_state="READY"
  fi

  if ((dll_present == 1)); then
    prov_detail="META_MATCH=${meta_match}"
    trust_detail="ALLOWLIST_MATCH=${allow_match}"
    if ((meta_match == 1)); then
      prov_state="READY"
    fi
    if ((allow_match == 1)); then
      trust_state="READY"
    fi
  fi

  if ((dll_present == 0)); then
    prov_detail="meta missing"
    trust_detail="DLL missing"
    rc=2
    if fsr4_ver_is_4x_triplet "$want_ver" && ! fsr4_ver_is_released_supported "$want_ver"; then
      rc=1
    fi
  else
    if ((meta_present == 0)); then
      prov_detail="meta missing"
      rc=2
    fi
    if ((meta_match != 1)); then
      prov_detail="META_MATCH=0 (${meta_reason})"
      ((rc < 2)) && rc=1
    fi
    if ((allow_match != 1)); then
      case "$allow_reason" in
        allowlist_missing) trust_detail="allowlist missing" ;;
        dll_missing) trust_detail="DLL missing" ;;
        pair_unavailable) trust_detail="fingerprint unavailable" ;;
        *) trust_detail="ALLOWLIST_MATCH=0 (${allow_reason})" ;;
      esac
      ((rc == 0)) && rc=1
    fi
    case "$rc" in
      0) result_text="Trusted" ;;
      1) result_text="Untrusted" ;;
      *) result_text="Incomplete" ;;
    esac
  fi

  msg "DLL Verify"
  msg ""
  printf '  %-7s %-9s %s\n' "ITEM" "STATE" "DETAIL"
  prep_print_status_row "DLL" "$dll_state" "$dll_detail"
  prep_print_status_row "META" "$meta_state" "$meta_detail"
  prep_print_status_row "REPORT" "$report_state" "$report_detail"
  prep_print_status_row "PROV" "$prov_state" "$prov_detail"
  prep_print_status_row "TRUST" "$trust_state" "$trust_detail"
  msg ""
  msg "Paths:"
  print_label_value_row "DLL:" "$expected"
  if ((dll_present == 1)); then
    print_label_value_row "Size:" "${dll_size} bytes"
    [[ -n "$dll_sha" ]] && print_label_value_row "SHA256:" "$dll_sha"
  fi
  print_label_value_row "Meta:" "$meta"
  print_label_value_row "Report:" "$report_file"
  msg ""
  msg "Result:"
  msg "  $result_text"

  return "$rc"
}

# amd_dll_provenance_integrity
# compares cached dll fingerprints vs meta + allowlist and prints kv summary.

amd_dll_provenance_integrity_decide_with_opts() {
  local expected="${1:-}" meta="${2:-}" fingerprint_strict="${3:-1}" allow_zero_size_unavailable="${4:-0}"
  local -n out_meta_match_ref="$5" out_meta_reason_ref="$6" out_allow_match_ref="$7" out_allow_reason_ref="$8"
  local -n out_trust_match_ref="$9" out_trust_summary_ref="${10}" out_trust_reason_ref="${11}"
  local -n out_dll_sha_ref="${12}" out_dll_size_ref="${13}" out_meta_sha_ref="${14}" out_meta_size_ref="${15}" out_src_url_ref="${16}"

  local calc_meta_sha="" calc_meta_size="" calc_src_url="" consistency_reason=""
  local calc_dll_sha="" calc_dll_size=""
  local fingerprint_match=0 fingerprint_reason="" reason=""
  local _trust_label="untrusted"

  out_meta_match_ref=1
  out_meta_reason_ref="ok"
  out_allow_match_ref=0
  out_allow_reason_ref="allowlist_missing"
  out_trust_match_ref=0
  out_trust_summary_ref="META_MATCH=1, ALLOWLIST_MATCH=0"
  out_trust_reason_ref="allowlist_missing"
  out_dll_sha_ref=""
  out_dll_size_ref=""
  out_meta_sha_ref=""
  out_meta_size_ref=""
  out_src_url_ref=""

  if have sha256sum; then
    calc_dll_sha="$(sha256sum "$expected" 2>/dev/null | awk '{print $1}' || true)"
  fi
  if have stat; then
    calc_dll_size="$(stat -c '%s' "$expected" 2>/dev/null || true)"
  fi

  if [[ -f "$meta" ]]; then
    if [[ "$fingerprint_strict" == "1" ]]; then
      calc_meta_sha="$(grep -E '^CACHE_DLL_SHA256=' "$meta" | head -n1 | cut -d= -f2- || true)"
      calc_meta_size="$(grep -E '^CACHE_DLL_SIZE=' "$meta" | head -n1 | cut -d= -f2- || true)"
      calc_meta_sha="${calc_meta_sha//$'\r'/}"
      calc_meta_size="${calc_meta_size//$'\r'/}"
      calc_meta_sha="${calc_meta_sha//[[:space:]]/}"
      calc_meta_size="${calc_meta_size//[[:space:]]/}"
    else
      calc_meta_sha="$(amd_meta_get_value "$meta" "CACHE_DLL_SHA256")"
      calc_meta_size="$(amd_meta_get_value "$meta" "CACHE_DLL_SIZE")"
    fi
    calc_src_url="$(grep -E '^SOURCE_URL=' "$meta" | head -n1 | cut -d= -f2- || true)"

    amd_meta_fingerprint_match_status "$calc_meta_sha" "$calc_meta_size" "$calc_dll_sha" "$calc_dll_size" "$fingerprint_strict" fingerprint_match fingerprint_reason
    reason="$fingerprint_reason"
    if ((fingerprint_match == 1)); then
      consistency_reason="$(amd_meta_provenance_consistency_reason "$meta" "$expected")"
      if [[ -n "$consistency_reason" ]]; then
        reason="$consistency_reason"
      fi
    fi

    if [[ "$reason" != "ok" ]]; then
      out_meta_match_ref=0
      out_meta_reason_ref="$reason"
    fi
  else
    out_meta_match_ref=0
    out_meta_reason_ref="missing_meta"
  fi

  out_dll_sha_ref="$calc_dll_sha"
  out_dll_size_ref="$calc_dll_size"
  out_meta_sha_ref="$calc_meta_sha"
  out_meta_size_ref="$calc_meta_size"
  out_src_url_ref="$calc_src_url"

  amd_allowlist_match_status "${AMD_DLL_ALLOWLIST}" "$calc_dll_sha" "$calc_dll_size" "$allow_zero_size_unavailable" out_allow_match_ref out_allow_reason_ref
  amd_dll_trust_result_status \
    "$out_meta_match_ref" \
    "$out_meta_reason_ref" \
    "$out_allow_match_ref" \
    "$out_allow_reason_ref" \
    out_trust_match_ref \
    _trust_label \
    out_trust_summary_ref \
    out_trust_reason_ref
}

amd_dll_provenance_integrity_decide() {
  local expected="${1:-}" meta="${2:-}"
  shift 2
  amd_dll_provenance_integrity_decide_with_opts "$expected" "$meta" 1 0 "$@"
}

amd_dll_provenance_integrity() {
  # mode: check | verify | status
  local mode="$1" dst_dir="$2"

  local meta_match=1 meta_reason="ok"
  local allow_match=0 allow_reason="allowlist_missing"
  local trust_match=1 trust_summary="META_MATCH=1, ALLOWLIST_MATCH=1" _trust_reason="ok"

  local expected="$dst_dir/${AMD_DLL_NAME}"
  local meta="$dst_dir/${AMD_META_NAME}"

  # missing dll
  if [[ ! -f "$expected" ]]; then
    if [[ "$mode" != "status" ]]; then
      warn "Provenance integrity: DLL missing"
    fi
    [[ "$mode" == "verify" ]] && return 2 || return 0
  fi

  # missing meta
  if [[ ! -f "$meta" ]]; then
    warn "Provenance integrity: meta missing"
    [[ "$mode" == "verify" ]] && return 2 || return 0
  fi

  # sha256sum is required for this check to mean anything
  if ! have sha256sum; then
    warn "${I_SHIELD} Provenance integrity: sha256sum not found — cannot verify meta integrity."
    [[ "$mode" == "verify" ]] && return 3 || return 0
  fi

  local meta_sha="" meta_size="" src_url="" dll_sha="" dll_size=""
  amd_dll_provenance_integrity_decide \
    "$expected" \
    "$meta" \
    meta_match \
    meta_reason \
    allow_match \
    allow_reason \
    trust_match \
    trust_summary \
    _trust_reason \
    dll_sha \
    dll_size \
    meta_sha \
    meta_size \
    src_url

  if [[ "$meta_reason" != "ok" ]]; then
    warn "${I_SHIELD} Provenance integrity: META_MATCH=0 REASON=$meta_reason"
    if verbose_on; then
      msg "    DLL_SHA256=$dll_sha"
      msg "    META_DLL_SHA256=$meta_sha"
      if [[ -n "$dll_size" || -n "$meta_size" ]]; then
        msg "    DLL_SIZE=${dll_size}"
        msg "    META_DLL_SIZE=${meta_size}"
      fi
    else
      msg "    ${I_INFO} Run with --verbose/--debug for fingerprints + details."
    fi

    local _dcmd default_url
    _dcmd="$(cmd_dll)"
    default_url="${AMD_DRIVER_URL:-}"
    if [[ -n "$src_url" ]]; then
      msg "${I_WRENCH}${I_NET} Easiest Fix: $_dcmd install"
      msg ""
      msg "${I_WRENCH}   Manual Fix: $_dcmd install --url \"$src_url\""
    else
      msg "${I_WRENCH}   Manual Fix: $_dcmd install --url \"$default_url\""
    fi

    if verbose_on; then
      msg "    ${I_WARN}  Details:"
      msg "         This DLL failed the provenance integrity check (META_MATCH=0)."
      msg "         Causes:"
      case "${meta_reason:-unknown}" in
        insufficient_data)
          msg "         • Meta file has no comparable fingerprint fields (sha/size) → cannot verify provenance."
          msg "           Fix: reinstall the local DLL to regenerate meta (or repair meta keys)."
          ;;
        installed_ver_missing)
          msg "         • Meta installed-version field is empty for a versioned cache DLL → provenance meta is incomplete."
          msg "           Fix: reinstall the local DLL to regenerate helper-managed meta."
          ;;
        installed_ver_mismatch)
          msg "         • Meta installed-version field contradicts the versioned cache filename → provenance meta is inconsistent."
          msg "           Fix: reinstall the local DLL to regenerate helper-managed meta."
          ;;
        installed_ver_source_missing)
          msg "         • Trusted-version metadata is missing FSR4_INSTALLED_VER_SOURCE → provenance installed-version source is incomplete."
          msg "           Fix: reinstall the trusted version to regenerate helper-managed meta."
          ;;
        installed_ver_source_mismatch)
          msg "         • FSR4_INSTALLED_VER_SOURCE contradicts trusted-version metadata → provenance installed-version source is inconsistent."
          msg "           Fix: reinstall the trusted version to regenerate helper-managed meta."
          ;;
        amd_driver_flavor_missing)
          msg "         • Helper-managed AMD-source metadata is missing DRIVER_FLAVOR → provenance driver classification is incomplete."
          msg "           Fix: reinstall from the AMD driver package to regenerate helper-managed meta."
          ;;
        amd_driver_flavor_mismatch)
          msg "         • DRIVER_FLAVOR contradicts helper-managed AMD-source metadata → provenance driver classification is inconsistent."
          msg "           Fix: reinstall from the AMD driver package to regenerate helper-managed meta."
          ;;
        amd_source_kind_missing)
          msg "         • Helper-managed AMD-source metadata is missing SOURCE_KIND → provenance source classification is incomplete."
          msg "           Fix: reinstall from the AMD driver package to regenerate helper-managed meta."
          ;;
        amd_source_kind_mismatch)
          msg "         • SOURCE_KIND contradicts helper-managed AMD-source metadata → provenance source classification is inconsistent."
          msg "           Fix: reinstall from the AMD driver package to regenerate helper-managed meta."
          ;;
        amd_source_path_missing)
          msg "         • EXE-classified AMD-source metadata is missing SOURCE_PATH → provenance source reference is incomplete."
          msg "           Fix: reinstall from the AMD driver package to regenerate helper-managed meta."
          ;;
        amd_source_path_shape_mismatch)
          msg "         • EXE-classified AMD-source metadata has a non-EXE SOURCE_PATH → provenance source reference is inconsistent."
          msg "           Fix: reinstall from the AMD driver package to regenerate helper-managed meta."
          ;;
        amd_source_url_missing)
          msg "         • URL-classified AMD-source metadata is missing SOURCE_URL → provenance source reference is incomplete."
          msg "           Fix: reinstall from the AMD driver package to regenerate helper-managed meta."
          ;;
        amd_source_url_shape_mismatch)
          msg "         • URL-classified AMD-source metadata has a non-URL SOURCE_URL → provenance source reference is inconsistent."
          msg "           Fix: reinstall from the AMD driver package to regenerate helper-managed meta."
          ;;
        local_installed_ver_source_missing)
          msg "         • Local-DLL metadata is missing FSR4_INSTALLED_VER_SOURCE → provenance installed-version source is incomplete."
          msg "           Fix: reinstall the local DLL to regenerate helper-managed meta."
          ;;
        local_installed_ver_source_mismatch)
          msg "         • FSR4_INSTALLED_VER_SOURCE contradicts helper-managed local-DLL metadata → provenance installed-version source is inconsistent."
          msg "           Fix: reinstall the local DLL to regenerate helper-managed meta."
          ;;
        local_source_kind_missing)
          msg "         • Local-DLL metadata resolved from installed DLL scan is missing SOURCE_KIND → provenance source classification is incomplete."
          msg "           Fix: reinstall the local DLL to regenerate helper-managed meta."
          ;;
        local_source_kind_mismatch)
          msg "         • SOURCE_KIND contradicts local-DLL metadata resolved from installed DLL scan → provenance source classification is inconsistent."
          msg "           Fix: reinstall the local DLL to regenerate helper-managed meta."
          ;;
        source_kind_missing)
          msg "         • Trusted-version metadata is missing SOURCE_KIND → provenance source classification is incomplete."
          msg "           Fix: reinstall the trusted version to regenerate helper-managed meta."
          ;;
        source_kind_mismatch)
          msg "         • SOURCE_KIND contradicts trusted-version metadata → provenance source classification is inconsistent."
          msg "           Fix: reinstall the trusted version to regenerate helper-managed meta."
          ;;
        meta_sha_invalid)
          msg "         • Meta SHA-256 field is missing or malformed → cannot verify provenance."
          msg "           Fix: reinstall the local DLL to regenerate meta."
          ;;
        meta_size_invalid)
          msg "         • Meta DLL size field is malformed → meta is not trustworthy."
          msg "           Fix: reinstall the local DLL to regenerate meta."
          ;;
        size_mismatch | sha256_mismatch)
          msg "         • Meta/DLL mismatch → the DLL may have changed since install (or meta is out of date)."
          ;;
        *) msg "        • Provenance check failed (reason=${meta_reason})." ;;
      esac
      msg "    ${I_INFO}  Most often: DLL came from a different driver package, or it was modified/tampered with."
    fi

    [[ "$mode" == "verify" ]] || return 0
  fi

  # allowlist integrity (extra requirement)
  local allow_path="${AMD_DLL_ALLOWLIST}"

  if ((allow_match == 0)); then
    if [[ "$mode" != "status" ]]; then
      warn "${I_SHIELD} Allowlist: ALLOWLIST_MATCH=0 REASON=$allow_reason"
      msg "    ALLOWLIST_PATH=$allow_path"
      if verbose_on; then
        msg "    DLL_SHA256=$dll_sha"
        msg "    DLL_SIZE=$dll_size"
      fi
      msg "    ${I_WRENCH} Fix: append fingerprint to allowlist: $allow_path"

      if verbose_on; then
        msg "    $dll_sha $dll_size"
      else
        msg "    cmd: printf '%s\n' '$dll_sha $dll_size' >> '$allow_path'"
      fi

      if verbose_on; then
        msg "    ${I_WARN}  Details:"
        msg "       This DLL failed the allowlist trust check (ALLOWLIST_MATCH=0)."
        msg "       Causes:"
        case "${allow_reason:-unknown}" in
          allowlist_missing)
            msg "       • Allowlist file is missing at: ${allow_path}"
            msg "         (Without it, the DLL can't be approved against your trusted fingerprint set.)"
            ;;
          not_allowlisted)
            msg "       • DLL fingerprint is not allowlisted → it may be from a different driver package/version than your trusted set."
            ;;
          pair_unavailable)
          msg "       • Could not compute the fingerprint (sha/size) → allowlist check can't run."
          ;;
          *) msg "       • Allowlist check failed (reason=${allow_reason})." ;;
        esac
        msg "      Most often: DLL came from a different driver package, or it was modified/tampered with."
      else
        msg "    ${I_INFO}  Run with --verbose/--debug for details."
      fi
    fi
    # verify mode is strict; check/status only report and keep going
    [[ "$mode" == "verify" ]] || return 0
  fi

  # quiet on success for check/status; verbose only on verify
  if [[ "$mode" == "verify" ]]; then
    ((meta_match == 1)) && msg "${I_SHIELD} Provenance integrity: ${I_OK} META_MATCH=1 (ok)"
    ((allow_match == 1)) && msg "${I_SHIELD} Allowlist: ${I_OK} ALLOWLIST_MATCH=1 (ok)"

    if ((trust_match == 0)); then
      warn "${I_SHIELD} DLL trust: Not trusted (${trust_summary})"
      return 1
    fi
  fi
  return 0
}

# amd_dll_clean_extracted_all
# remove every extracted driver folder under AMD_EXTRACT_ROOT, keep the dll cache dir.

amd_dll_clean_extracted_all() {
  local dst_dir="${1:-$DLL_DST_DIR_DEFAULT}"
  local base="$AMD_EXTRACT_ROOT"
  local found=0 d
  while IFS= read -r -d '' d; do
    found=1
    msg "${I_BROOM} Clean: removing extracted folder:"
    msg "  $d"
    if rm_rf_within_root "$base" "$d"; then
      ok "Removed $d"
    else
      die "Failed to remove $d"
    fi
  done < <(find "$base" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null || true)
  if [[ "$found" == "0" ]]; then
    msg "${I_INFO} Nothing to clean (missing): $base/*"
  fi
  msg "${I_OK} Kept cache folder:"
  msg "  $dst_dir"
}

# amd_dll_clean_extracted
# remove one extracted driver folder, keep the dll cache dir.

amd_dll_clean_extracted() {
  local out_dir="$1"
  local dst_dir="$2"
  if [[ -d "$out_dir" ]]; then
    msg "${I_BROOM} Clean: removing extracted folder:"
    msg "  $out_dir"
    if rm_rf_within_root "$AMD_EXTRACT_ROOT" "$out_dir"; then
      ok "Removed $out_dir"
    else
      die "Failed to remove $out_dir"
    fi
  else
    msg "${I_INFO} Nothing to clean (missing): $out_dir"
  fi
  msg "${I_OK} Kept cache folder:"
  msg "  $dst_dir"
}

# amd_steam_collect_library_paths
# list steam library roots (native + flatpak) by reading libraryfolders.vdf.

amd_steam_collect_library_paths() {
  # keep STEAM_ROOT present (uses the existing detector)
  if [[ -z "${STEAM_ROOT:-}" || ! -d "${STEAM_ROOT:-}" ]]; then
    local detect_major="${MAJOR:-$MAJOR_DEFAULT}"
    if [[ ! "$detect_major" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
      detect_major="$MAJOR_DEFAULT"
    fi
    steam_detect_ctd "$detect_major" || true
  fi

  local -a roots=()
  local xdg_data="${XDG_DATA_HOME:-$HOME/.local/share}"

  # prefer detected root (covers flatpak too)
  if [[ -n "${STEAM_ROOT:-}" && -d "${STEAM_ROOT:-}" ]]; then
    roots+=("${STEAM_ROOT}")
  fi

  # safe fallbacks (native layouts / older installs)
  roots+=(
    "${xdg_data}/Steam"
    "${HOME}/.local/share/Steam"
    "${HOME}/.steam/steam"
    "${HOME}/.steam/root"
  )

  local -A seen=()
  local r vdf line p

  for r in "${roots[@]}"; do
    [[ -d "$r" ]] || continue
    seen["$r"]=1

    for vdf in "$r/config/libraryfolders.vdf" "$r/steamapps/libraryfolders.vdf"; do
      [[ -f "$vdf" ]] || continue
      while IFS= read -r line; do
        # match: "path" "/some/path"
        if [[ "$line" =~ \"path\"[[:space:]]+\"([^\"]+)\" ]]; then
          p="${BASH_REMATCH[1]}"
          # vdf uses backslash escaping
          p="${p//\\\\/\\}"
          [[ -n "$p" ]] && seen["$p"]=1
        fi
      done <"$vdf"
    done
  done

  for p in "${!seen[@]}"; do
    printf '%s\n' "$p"
  done | sort
}

# amd_steam_find_prefix_dll_for_appid
# find the prefix dll for an appid by walking steam library roots.

amd_steam_find_prefix_dll_for_appid() {
  local appid="${1:-}"
  [[ -n "$appid" ]] || die "--appid requires a value"

  local pfx_name="${AMD_DLL_SRC_NAME:-amdxcffx64.dll}"
  local lib="" pfx_root="" cand="" fallback=""
  while IFS= read -r lib; do
    [[ -n "$lib" ]] || continue
    pfx_root="$lib/steamapps/compatdata/$appid/pfx"
    cand="$pfx_root/drive_c/windows/system32/$pfx_name"
    if [[ -f "$cand" ]]; then
      printf '%s\n' "$cand"
      return 0
    fi
    if [[ -z "$fallback" && -d "$pfx_root/drive_c/windows/system32" ]]; then
      fallback="$cand"
    fi
  done < <(amd_steam_collect_library_paths)

  if [[ -n "$fallback" ]]; then
    printf '%s\n' "$fallback"
    return 0
  fi

  return 1
}

# amd_dll_prefix_verify
# compare the cache dll vs a prefix dll (by appid or explicit path).

amd_dll_prefix_target_detail() {
  local target_ver="${1:-${want:-unknown}}"
  if ((${ver_explicit:-0} == 1)); then
    printf 'FSR4 %s (--ver)' "$target_ver"
  else
    printf 'FSR4 %s (default local target)' "$target_ver"
  fi
}

amd_dll_prefix_sync_intent_label() {
  if ((${ver_explicit:-0} == 1)); then
    printf 'selected version'
  else
    printf 'default local target'
  fi
}

amd_dll_prefix_print_status_row() {
  local item="${1:-}" state="${2:-}" detail="${3:-}"
  printf '  %-14s %-11s %s\n' "$item" "$state" "$detail"
}

amd_dll_prefix_detection_detail() {
  local ver="${1:-}"
  local -n filename_ref="$2"
  local -n content_ref="$3"
  local has_filename=0 has_content=0

  [[ -n "$ver" ]] || return 1
  fsr4_array_contains "$ver" "${filename_ref[@]}" && has_filename=1
  fsr4_array_contains "$ver" "${content_ref[@]}" && has_content=1

  if ((has_filename == 1 && has_content == 1)); then
    printf '%s\n' "detected from DLL filename/content"
  elif ((has_content == 1)); then
    printf '%s\n' "detected from DLL content"
  elif ((has_filename == 1)); then
    printf '%s\n' "detected from DLL filename"
  else
    printf '%s\n' "detected from DLL content"
  fi
}

amd_dll_prefix_cache_path_for_ver() {
  local ver="${1:-}" dst_dir="${2:-$DLL_DST_DIR_DEFAULT}"
  local -n out_path_ref="$3"
  local __save_dll="${AMD_DLL_NAME:-}"
  local __save_meta="${AMD_META_NAME:-}"
  local __save_report="${AMD_REPORT_NAME:-}"
  local __save_allow_name="${AMD_ALLOWLIST_NAME:-}"
  local __save_allow_default="${AMD_DLL_ALLOWLIST_DEFAULT:-}"
  local __save_allow="${AMD_DLL_ALLOWLIST:-}"

  out_path_ref=""
  [[ -n "$ver" ]] || return 1
  amd_set_cache_names_for_ver "$ver"
  out_path_ref="${dst_dir}/${AMD_DLL_NAME}"

  AMD_DLL_NAME="$__save_dll"
  AMD_META_NAME="$__save_meta"
  AMD_REPORT_NAME="$__save_report"
  AMD_ALLOWLIST_NAME="$__save_allow_name"
  AMD_DLL_ALLOWLIST_DEFAULT="$__save_allow_default"
  AMD_DLL_ALLOWLIST="$__save_allow"
}

amd_dll_prefix_files_match() {
  local left="${1:-}" right="${2:-}"
  local -n out_left_sha_ref="$3"
  local -n out_right_sha_ref="$4"
  local -n out_left_size_ref="$5"
  local -n out_right_size_ref="$6"

  out_left_sha_ref=""
  out_right_sha_ref=""
  out_left_size_ref=""
  out_right_size_ref=""

  [[ -f "$left" && -f "$right" ]] || return 1

  out_left_size_ref="$(stat -c %s "$left" 2>/dev/null || true)"
  out_right_size_ref="$(stat -c %s "$right" 2>/dev/null || true)"
  [[ -n "$out_left_size_ref" && "$out_left_size_ref" == "$out_right_size_ref" ]] || return 1

  out_left_sha_ref="$(sha256sum "$left" 2>/dev/null | awk '{print $1}' || true)"
  out_right_sha_ref="$(sha256sum "$right" 2>/dev/null | awk '{print $1}' || true)"
  [[ -n "$out_left_sha_ref" && "$out_left_sha_ref" == "$out_right_sha_ref" ]] || return 1

  if have cmp; then
    cmp -s "$left" "$right" || return 1
  fi

  return 0
}

amd_dll_prefix_collect_exact_local_cache_matches() {
  local pfx_dll="${1:-}" dst_dir="${2:-$DLL_DST_DIR_DEFAULT}"
  local -n out_versions_ref="$3"
  local -n out_paths_ref="$4"
  local -n out_prefix_sha_ref="$5"
  local -n out_prefix_size_ref="$6"
  local prefix_mz="" dll="" ver=""
  local had_nullglob=0
  local cache_sha="" cache_size=""
  declare -A seen_ver=()

  out_versions_ref=()
  out_paths_ref=()
  out_prefix_sha_ref=""
  out_prefix_size_ref=""

  require_file "$pfx_dll" "prefix DLL"
  fsr4_dll_fingerprint "$pfx_dll" prefix_mz out_prefix_sha_ref out_prefix_size_ref || return 1

  shopt -q nullglob && had_nullglob=1
  shopt -s nullglob
  local -a dll_candidates=( "$dst_dir"/"${AMD_DLL_STEM}"_v*.dll )
  ((had_nullglob)) || shopt -u nullglob

  for dll in "${dll_candidates[@]}"; do
    [[ -f "$dll" ]] || continue
    ver="$(fsr4_version_from_versioned_cache_name "$dll" 2>/dev/null || true)"
    [[ -n "$ver" ]] || continue
    cache_size="$(stat -c %s "$dll" 2>/dev/null || true)"
    [[ -n "$cache_size" && "$cache_size" == "$out_prefix_size_ref" ]] || continue
    cache_sha="$(sha256sum "$dll" 2>/dev/null | awk '{print $1}' || true)"
    [[ -n "$cache_sha" && "$cache_sha" == "$out_prefix_sha_ref" ]] || continue
    if have cmp && ! cmp -s "$pfx_dll" "$dll"; then
      continue
    fi
    if [[ -z "${seen_ver[$ver]+x}" ]]; then
      seen_ver["$ver"]=1
      out_versions_ref+=("$ver")
      out_paths_ref+=("$dll")
    fi
  done
}

amd_dll_prefix_describe_cache_match() {
  local -n match_versions_ref="$1"
  local -n match_paths_ref="$2"
  local -n out_state_ref="$3"
  local -n out_detail_ref="$4"

  out_state_ref="MISSING"
  out_detail_ref="does not match installed local cache versions"

  if ((${#match_versions_ref[@]} == 1 && ${#match_paths_ref[@]} == 1)); then
    out_state_ref="READY"
    out_detail_ref="matches installed local cache ${match_paths_ref[0]##*/}"
    return 0
  fi

  if ((${#match_versions_ref[@]} > 1)); then
    out_state_ref="READY"
    out_detail_ref="matches installed local cache versions: $(fsr4_versions_comma_from_args "${match_versions_ref[@]}")"
  fi
}

amd_dll_prefix_describe_identity() {
  local -n filename_markers_ref="$1"
  local -n content_markers_ref="$2"
  local -n all_markers_ref="$3"
  local -n supported_markers_ref="$4"
  local -n match_versions_ref="$5"
  local -n out_state_ref="$6"
  local -n out_detail_ref="$7"
  local -n out_clear_ver_ref="$8"
  local marker_ver="" match_ver="" detail=""

  out_state_ref="UNKNOWN"
  out_detail_ref="no supported FSR4 marker detected"
  out_clear_ver_ref=""

  if ((${#match_versions_ref[@]} > 1)); then
    if ((${#supported_markers_ref[@]} == 1)); then
      out_state_ref="AMBIGUOUS"
      out_detail_ref="detected marker FSR4 ${supported_markers_ref[0]} disagrees with exact local cache match versions: $(fsr4_versions_comma_from_args "${match_versions_ref[@]}")"
      return 0
    fi
    out_state_ref="AMBIGUOUS"
    out_detail_ref="exact local cache match spans multiple installed versions: $(fsr4_versions_comma_from_args "${match_versions_ref[@]}")"
    return 0
  fi

  if ((${#match_versions_ref[@]} == 1)); then
    match_ver="${match_versions_ref[0]}"
  fi

  if ((${#supported_markers_ref[@]} == 1)); then
    marker_ver="${supported_markers_ref[0]}"
    if [[ -n "$match_ver" && "$match_ver" != "$marker_ver" ]]; then
      out_state_ref="AMBIGUOUS"
      out_detail_ref="detected marker FSR4 ${marker_ver} disagrees with exact local cache match FSR4 ${match_ver}"
      return 0
    fi
    detail="$(amd_dll_prefix_detection_detail "$marker_ver" filename_markers_ref content_markers_ref)"
    out_state_ref="READY"
    out_detail_ref="FSR4 ${marker_ver} (${detail})"
    out_clear_ver_ref="$marker_ver"
    return 0
  fi

  if ((${#supported_markers_ref[@]} > 1)); then
    out_state_ref="AMBIGUOUS"
    out_detail_ref="detected multiple supported FSR4 markers: $(fsr4_versions_comma_from_args "${supported_markers_ref[@]}")"
    return 0
  fi

  if ((${#all_markers_ref[@]} > 0)); then
    if [[ -n "$match_ver" ]]; then
      out_state_ref="AMBIGUOUS"
      out_detail_ref="detected unsupported FSR4 marker(s): $(fsr4_versions_comma_from_args "${all_markers_ref[@]}"); exact local cache match is FSR4 ${match_ver}"
      return 0
    fi
    out_state_ref="UNSUPPORTED"
    out_detail_ref="detected unsupported FSR4 marker(s): $(fsr4_versions_comma_from_args "${all_markers_ref[@]}")"
    return 0
  fi

  if [[ -n "$match_ver" ]]; then
    out_state_ref="READY"
    out_detail_ref="FSR4 ${match_ver} (inferred from exact local cache match)"
    out_clear_ver_ref="$match_ver"
  fi
}

amd_dll_prefix_status_report() {
  local appid="${1:-}"
  local pfx_dll="${2:-}"
  local dst_dir="${3:-$DLL_DST_DIR_DEFAULT}"
  local default_ver="${FSR4_LOCAL_DEFAULT_VER}"
  local default_cache_dll="" default_state="MISSING" default_detail=""
  local version_state="" version_detail="" cache_state="" cache_detail="" clear_ver=""
  local prefix_sha="" prefix_size="" dst_flag=""
  local -a filename_markers=() content_markers=() all_markers=() supported_markers=()
  local -a match_versions=() match_paths=()
  local marker_result=""

  amd_dll_prefix_cache_path_for_ver "$default_ver" "$dst_dir" default_cache_dll
  if [[ -f "$default_cache_dll" ]]; then
    default_state="INFO"
    default_detail="FSR4 ${default_ver}"
  else
    default_state="MISSING"
    default_detail="FSR4 ${default_ver} not installed locally"
  fi

  fsr4_dll_collect_marker_report "$pfx_dll" filename_markers content_markers all_markers supported_markers marker_result
  amd_dll_prefix_collect_exact_local_cache_matches "$pfx_dll" "$dst_dir" match_versions match_paths prefix_sha prefix_size \
    || die "prefix-verify: could not compute prefix DLL fingerprint: $pfx_dll"
  amd_dll_prefix_describe_identity filename_markers content_markers all_markers supported_markers match_versions \
    version_state version_detail clear_ver
  amd_dll_prefix_describe_cache_match match_versions match_paths cache_state cache_detail

  msg "${I_SEARCH} Prefix Status"
  msg ""
  printf '  %-14s %-11s %s\n' "ITEM" "STATE" "DETAIL"
  amd_dll_prefix_print_status_row "PREFIX DLL" "READY" "${pfx_dll##*/}"
  amd_dll_prefix_print_status_row "PREFIX VERSION" "$version_state" "$version_detail"
  amd_dll_prefix_print_status_row "CACHE MATCH" "$cache_state" "$cache_detail"
  amd_dll_prefix_print_status_row "DEFAULT TARGET" "$default_state" "$default_detail"

  msg ""
  msg "Paths:"
  print_label_value_row "Prefix DLL:" "$pfx_dll"
  if ((${#match_paths[@]} == 1)); then
    print_label_value_row "Matched cache:" "${match_paths[0]}"
  fi
  if verbose_on; then
    msg ""
    msg "Fingerprints:"
    print_label_value_row "Prefix SHA256:" "${prefix_sha:-unknown}"
    print_label_value_row "Prefix Size:" "${prefix_size:-unknown}"
  fi

  if [[ -n "${dst_dir:-}" && "$dst_dir" != "$DLL_DST_DIR_DEFAULT" ]]; then
    dst_flag=" --dst-dir \"$dst_dir\""
  fi

  msg ""
  msg "Next:"
  local step_no=1
  if [[ "$cache_state" == "READY" && -n "$clear_ver" ]]; then
    msg "  ${step_no}. Prefix already matches installed local cache FSR4 ${clear_ver}."
    step_no=$((step_no + 1))
  fi
  if [[ -n "$appid" ]]; then
    msg "  ${step_no}. To sync back to the default local target:"
    msg "     $(cmd_dll) prefix-sync --appid ${appid}${dst_flag} --ver ${default_ver}"
  else
    msg "  ${step_no}. To sync back to the default local target:"
    msg "     $(cmd_dll) prefix-sync --pfx-dll ${pfx_dll}${dst_flag} --ver ${default_ver}"
  fi
  return 0
}

amd_dll_prefix_verify_selected_report() {
  local appid="${1:-}"
  local pfx_dll="${2:-}"
  local dst_dir="${3:-$DLL_DST_DIR_DEFAULT}"
  local cache_dll="$dst_dir/${AMD_DLL_NAME}"
  local version_state="" version_detail="" clear_ver="" prefix_state="MISMATCH"
  local pfx_sha="" cache_sha="" pfx_size="" cache_size="" prefix_sha="" prefix_size="" dst_flag=""
  local -a filename_markers=() content_markers=() all_markers=() supported_markers=()
  local -a match_versions=() match_paths=()
  local marker_result=""

  validate_amd_cache_names
  if [[ ! -f "$cache_dll" ]]; then
    err "prefix-verify: cache DLL missing: $cache_dll"
    hint "Install it first: $(cmd_dll) install"
    hint "The source artifact must contain FSR4 ${want:-$FSR4_LOCAL_DEFAULT_VER}."
    return 1
  fi

  fsr4_dll_collect_marker_report "$pfx_dll" filename_markers content_markers all_markers supported_markers marker_result
  amd_dll_prefix_collect_exact_local_cache_matches "$pfx_dll" "$dst_dir" match_versions match_paths prefix_sha prefix_size \
    || die "prefix-verify: could not compute prefix DLL fingerprint: $pfx_dll"
  amd_dll_prefix_describe_identity filename_markers content_markers all_markers supported_markers match_versions \
    version_state version_detail clear_ver

  if amd_dll_prefix_files_match "$pfx_dll" "$cache_dll" pfx_sha cache_sha pfx_size cache_size; then
    prefix_state="READY"
  else
    prefix_state="MISMATCH"
    [[ -z "$pfx_sha" ]] && pfx_sha="$prefix_sha"
    [[ -z "$pfx_size" ]] && pfx_size="$prefix_size"
    cache_sha="$(sha256sum "$cache_dll" 2>/dev/null | awk '{print $1}' || true)"
    cache_size="$(stat -c %s "$cache_dll" 2>/dev/null || true)"
  fi

  msg "${I_SEARCH} Prefix Verify"
  msg ""
  printf '  %-14s %-11s %s\n' "ITEM" "STATE" "DETAIL"
  amd_dll_prefix_print_status_row "CHECK TARGET" "READY" "$(amd_dll_prefix_target_detail)"
  amd_dll_prefix_print_status_row "CACHE" "READY" "${cache_dll##*/}"
  if [[ -n "$clear_ver" ]]; then
    amd_dll_prefix_print_status_row "PREFIX VERSION" "$version_state" "$version_detail"
  fi
  if [[ "$prefix_state" == "READY" ]]; then
    amd_dll_prefix_print_status_row "PREFIX" "READY" "matches selected cache DLL"
  else
    amd_dll_prefix_print_status_row "PREFIX" "MISMATCH" "differs from selected cache DLL"
  fi

  msg ""
  msg "Paths:"
  print_label_value_row "Prefix DLL:" "$pfx_dll"
  print_label_value_row "Cache DLL:" "$cache_dll"
  if verbose_on; then
    msg ""
    msg "Fingerprints:"
    print_label_value_row "Prefix SHA256:" "${pfx_sha:-unknown}"
    print_label_value_row "Cache SHA256:" "${cache_sha:-unknown}"
  fi

  [[ "$prefix_state" == "READY" ]] && return 0

  if [[ -n "${dst_dir:-}" && "$dst_dir" != "$DLL_DST_DIR_DEFAULT" ]]; then
    dst_flag=" --dst-dir \"$dst_dir\""
  fi

  msg ""
  msg "Next:"
  local step_no=1
  if [[ -n "$clear_ver" && "$clear_ver" != "${want:-$FSR4_LOCAL_DEFAULT_VER}" ]]; then
    msg "  ${step_no}. Verify against the detected prefix version:"
    if [[ -n "$appid" ]]; then
      msg "     $(cmd_dll) prefix-verify --appid ${appid}${dst_flag} --ver ${clear_ver}"
    else
      msg "     $(cmd_dll) prefix-verify --pfx-dll ${pfx_dll}${dst_flag} --ver ${clear_ver}"
    fi
    step_no=$((step_no + 1))
  fi
  if [[ -n "$appid" ]]; then
    msg "  ${step_no}. Or sync the prefix DLL to the selected target:"
    msg "     $(cmd_dll) prefix-sync --appid ${appid}${dst_flag} --ver ${want:-$FSR4_LOCAL_DEFAULT_VER}"
  else
    msg "  ${step_no}. Or sync the prefix DLL to the selected target:"
    msg "     $(cmd_dll) prefix-sync --pfx-dll ${pfx_dll}${dst_flag} --ver ${want:-$FSR4_LOCAL_DEFAULT_VER}"
  fi
  return 1
}

amd_dll_prefix_target_usage() {
  local verb="${1:-prefix-verify}"
  local _pfx_name="${AMD_DLL_SRC_NAME:-amdxcffx64.dll}"
  cat >&2 <<EOF
${verb} requires a prefix target.

Common:
  $(cmd_dll) ${verb} --appid APPID [--ver X.Y.Z]

Advanced:
  $(cmd_dll) ${verb} --pfx-dll DLL_PATH [--ver X.Y.Z]

Notes:
  --appid APPID finds the Steam prefix DLL automatically.
  --pfx-dll DLL_PATH points directly to ${_pfx_name} inside a prefix.
  DLL_PATH is the full path to drive_c/windows/system32/${_pfx_name}.
  Without --ver, the prefix DLL is identified/statused first.
EOF
}

amd_dll_prefix_version_without_target_usage() {
  local verb="${1:-prefix-verify}"
  local ver="${2:-${FSR4_LOCAL_DEFAULT_VER}}"
  cat >&2 <<EOF
${verb} needs a prefix target before the version.

Common:
  $(cmd_dll) ${verb} --appid APPID --ver ${ver}

Advanced:
  $(cmd_dll) ${verb} --pfx-dll DLL_PATH --ver ${ver}
EOF
}

amd_dll_prefix_direct_path_usage() {
  local verb="${1:-prefix-verify}"
  cat >&2 <<EOF
${verb} got a direct DLL path without --pfx-dll.

Common:
  $(cmd_dll) ${verb} --appid APPID [--ver X.Y.Z]

Advanced:
  $(cmd_dll) ${verb} --pfx-dll DLL_PATH [--ver X.Y.Z]
EOF
}

amd_dll_prefix_arg_looks_like_path() {
  local value="${1:-}"
  [[ -n "$value" ]] || return 1
  [[ "$value" == */* || "$value" == ./* || "$value" == ../* || "$value" == ~/* || "$value" == *.dll || "$value" == *.DLL ]]
}

amd_dll_prefix_verify() {
  local appid="${1:-}"
  local pfx_dll="${2:-}"
  local dst_dir="${3:-$DLL_DST_DIR_DEFAULT}"

  have sha256sum || die "sha256sum not found — cannot verify prefix DLL integrity"

  if [[ -z "$pfx_dll" ]]; then
    if [[ -z "$appid" ]]; then
      amd_dll_prefix_target_usage "prefix-verify"
      return 1
    fi
    pfx_dll="$(amd_steam_find_prefix_dll_for_appid "$appid" || true)"
  fi

  if [[ -z "$pfx_dll" ]]; then
    err "prefix-verify: prefix DLL path could not be resolved"
    if [[ -n "$appid" ]]; then
      local _pfx_name="${AMD_DLL_SRC_NAME:-amdxcffx64.dll}"
      msg "${I_INFO} appid: $appid"
      msg "${I_INFO} looked for: steamapps/compatdata/$appid/pfx/.../system32/${_pfx_name}"
    else
      msg "${I_INFO} pfx-dll: ${pfx_dll:-(empty)}"
    fi
    return 1
  fi

  if [[ ! -e "$pfx_dll" ]]; then
    local pfx_dir=""
    pfx_dir="$(dirname "$pfx_dll")"
    if [[ -d "$pfx_dir" ]]; then
      err "prefix-verify: prefix DLL missing: $pfx_dll"
      [[ -n "$appid" ]] && msg "${I_INFO} appid: $appid"
      hint "Run prefix-sync to install the DLL into this existing prefix, then retry prefix-verify."
    else
      err "prefix-verify: prefix directory missing: $pfx_dir"
      [[ -n "$appid" ]] && hint "Launch the game once to create its prefix, then retry prefix-verify."
    fi
    return 1
  fi

  if [[ ! -f "$pfx_dll" ]]; then
    err "prefix-verify: prefix DLL is not a regular file: $pfx_dll"
    return 1
  fi

  if ((${ver_explicit:-0} == 0)); then
    amd_dll_prefix_status_report "$appid" "$pfx_dll" "$dst_dir"
    return $?
  fi
  amd_dll_prefix_verify_selected_report "$appid" "$pfx_dll" "$dst_dir"
  return $?
}

# amd_dll_prefix_sync
# copy the current cache dll into a prefix dll (appid or explicit path).
amd_dll_prefix_sync() {
  local appid="${1:-}"
  local pfx_dll="${2:-}"
  local dst_dir="${3:-$DLL_DST_DIR_DEFAULT}"

  if ! have cp; then
    die "cp not found — cannot sync prefix DLL"
  fi

  validate_amd_cache_names
  local cache_dll="$dst_dir/${AMD_DLL_NAME}"
  if [[ ! -f "$cache_dll" ]]; then
    err "prefix-sync: cache DLL missing: $cache_dll"
    hint "Install it first: $(cmd_dll) install"
    hint "The source artifact must contain FSR4 ${want:-$FSR4_LOCAL_DEFAULT_VER}."
    return 1
  fi

  if [[ -z "$pfx_dll" ]]; then
    if [[ -z "$appid" ]]; then
      amd_dll_prefix_target_usage "prefix-sync"
      return 1
    fi
    pfx_dll="$(amd_steam_find_prefix_dll_for_appid "$appid" || true)"
  fi

  if [[ -z "$pfx_dll" ]]; then
    err "prefix-sync: prefix DLL path could not be resolved"
    [[ -n "$appid" ]] && msg "${I_INFO} appid: $appid"
    [[ -n "$appid" ]] && hint "Launch the game once to create its prefix, then retry prefix-sync."
    return 1
  fi

  # refuse unexpected destinations (keeps --pfx-dll from being a footgun)
  local suffix="/drive_c/windows/system32/${AMD_DLL_SRC_NAME:-amdxcffx64.dll}"
  if [[ "$pfx_dll" != *"$suffix" ]]; then
    err "prefix-sync: refusing to write outside Wine system32 path"
    msg "${I_INFO} got:   $pfx_dll"
    msg "${I_INFO} want:  *$suffix"
    return 1
  fi

  local pfx_dir
  pfx_dir="$(dirname "$pfx_dll")"
  if [[ ! -d "$pfx_dir" ]]; then
    err "prefix-sync: prefix directory missing: $pfx_dir"
    hint "Launch the game once to create the prefix, then retry."
    return 1
  fi

  # warning-only: lsof/fuser isn't reliable everywhere, still useful when present
  if have lsof; then
    if lsof -t -- "$pfx_dll" >/dev/null 2>&1; then
      warn "prefix-sync: prefix DLL looks in use; close the game/Steam before syncing"
      hint "Tip: run this while the game is not running"
    fi
  elif have fuser; then
    if fuser -- "$pfx_dll" >/dev/null 2>&1; then
      warn "prefix-sync: prefix DLL looks in use; close the game/Steam before syncing"
      hint "Tip: run this while the game is not running"
    fi
  fi

  # precompute the backup path so we can print exactly what got created (.~N~)
  local backup_path=""
  if [[ -f "$pfx_dll" ]]; then
    local i=1
    while [[ -e "${pfx_dll}.~${i}~" ]]; do
      i=$((i + 1))
      if ((i > 9999)); then
        err "prefix-sync: too many backups for: $pfx_dll"
        return 1
      fi
    done
    backup_path="${pfx_dll}.~${i}~"
  fi

  local _pfx_name="${AMD_DLL_SRC_NAME:-amdxcffx64.dll}"
  msg "${I_WRENCH} Prefix Sync"
  msg ""
  printf '  %-7s %-9s %s\n' "ITEM" "STATE" "DETAIL"
  prep_print_status_row "TARGET" "READY" "$(amd_dll_prefix_target_detail)"
  prep_print_status_row "CACHE" "READY" "${cache_dll##*/}"
  prep_print_status_row "PREFIX" "WRITE" "${pfx_dll##*/}"
  msg ""
  msg "Paths:"
  print_label_value_row "Prefix DLL:" "$pfx_dll"
  print_label_value_row "Cache DLL:" "$cache_dll"

  if ! cp -a --backup=numbered -- "$cache_dll" "$pfx_dll"; then
    err "prefix-sync: copy failed"
    return 1
  fi

  msg ""
  ok "Prefix DLL updated"
  if [[ -n "$backup_path" && -e "$backup_path" ]]; then
    print_label_value_row "Backup:" "$backup_path"
  fi
  return 0
}

amd_dll_help() {
  local _dcmd
  _dcmd="$(cmd_dll)"
  cat <<EOF
${I_PUZZLE} genvw_proton dll

Installs the local AMD FSR4 DLL into:
  ~/.cache/protonfixes/upscalers/genvw/

Install:
  $_dcmd install --ver X.Y.Z [--dst-dir PATH] [--verbose|--debug]
    Install a trusted canonical FSR4 version from the built-in source map
  $_dcmd install X.Y.Z [--dst-dir PATH] [--verbose|--debug]
    Positional shorthand for trusted version install
  $_dcmd install [--dll /path/to/amdxcffx64_vX.Y.Z.dll|--url "https://drivers.amd.com/...exe"|--exe /path/to/driver.exe] [--ver X.Y.Z] [--keep] [--force-url] [--trust-local|--trust-dll] [--dst-dir PATH] [--verbose|--debug]
    Install from a local DLL, a local driver EXE, or a downloaded driver EXE

Inspect:
  $_dcmd inspect --dll PATH [--ver X.Y.Z] [--verbose|--debug]
    Inspect a local DLL source without installing or changing allowlists
  $_dcmd inspect --exe PATH [--ver X.Y.Z] [--keep] [--verbose|--debug]
    Extract and inspect the selected ${AMD_DLL_SRC_NAME:-amdxcffx64.dll} from a driver EXE
  $_dcmd inspect --url URL [--ver X.Y.Z] [--keep] [--verbose|--debug]
    Download or reuse, extract, and inspect the selected ${AMD_DLL_SRC_NAME:-amdxcffx64.dll}
  $_dcmd verify|check [--dst-dir PATH] [--ver X.Y.Z]
    Verify one installed local DLL and its trust state
  $_dcmd list [--dst-dir PATH] [--ver X.Y.Z] [--trusted-only] [--verbose|--debug]
    List installed local DLLs and shared Proton cache entries
  $_dcmd backup [VER] [--ver X.Y.Z] [--dst-dir PATH] [--verbose|--debug]
    Save a sealed local backup snapshot
  $_dcmd restore [VER] [--ver X.Y.Z] [--sha256 SHA256] [--dst-dir PATH] [--yes] [--verbose|--debug]
    Restore a DLL from a sealed local backup

Prefix:
  $_dcmd --appid APPID [VER]
    Shorthand for prefix-verify by Steam appid.
    Without VER: show prefix status. With VER: compare against the selected local cache DLL.
  $_dcmd appid APPID [VER]
    Same shorthand
  $_dcmd prefix-verify [APPID] [VER] [--appid APPID] [--pfx-dll DLL_PATH] [--dst-dir PATH] [--ver X.Y.Z]
    Without --ver: identify/status the prefix DLL. With --ver: compare against the selected local cache DLL.
  $_dcmd prefix-sync [APPID] [VER] [--appid APPID] [--pfx-dll DLL_PATH] [--dst-dir PATH] [--ver X.Y.Z]
    Copy the selected local cache DLL into a prefix and keep a numbered backup
    --appid APPID finds the Steam prefix DLL automatically.
    --pfx-dll DLL_PATH is the direct path to amdxcffx64.dll inside a prefix.
    DLL_PATH is the full path to drive_c/windows/system32/amdxcffx64.dll.
    Without VER / --ver, prefix-verify shows prefix status before any explicit version compare.
    A prefix contains one amdxcffx64.dll at a time, so it can only match one selected version at a time.

Cleanup:
  $_dcmd tidy [--driver-label LABEL|--driver LABEL] [--dst-dir PATH]
    Remove extracted AMD driver folders
  $_dcmd uninstall [VER] [--ver X.Y.Z] [--all] [--dst-dir PATH]
    Remove one or all installed local DLLs, plus metadata

Notes:
  • Aliases: uninstall = remove = rm
  • --appid searches across Steam libraries (so prefixes may live outside ~/.local/share/Steam).
  • MISMATCH means the prefix has a different ${AMD_DLL_SRC_NAME:-amdxcffx64.dll} than your cache; refresh it by re-running the game once or overwriting the prefix DLL.
  • Preferred install path: $_dcmd install --ver ${FSR4_LOCAL_DEFAULT_VER}
  • Version installs are cache-first and validate sha256 + size + MZ before reuse.
  • install with --url/--exe will download the driver EXE if needed, then extract + install the best ${AMD_DLL_SRC_NAME:-amdxcffx64.dll} candidate.
  • backup seals one trusted installed DLL into: <dst-dir>/backups/vX.Y.Z/sha256_<sha>__size_<bytes>/
  • restore only accepts backups whose DLL hash/size matches both the snapshot manifest and the copied meta file.
  • install with --dll reads the local FSR4 version from the DLL artifact itself unless --ver is used as an explicit expectation.
  • inspect is read-only: it never installs DLLs, writes meta/report files, or changes allowlists.
  • --trust-local adds the selected DLL SHA256 + size to the local per-version allowlist after validation.
  • --trust-dll is an alias for --trust-local.
  • Local trust approval is user-machine trust only; it does not update project policy.
  • After install, it runs the trust checks and prints META_MATCH / ALLOWLIST_MATCH results.
  • --keep keeps the extracted folder (otherwise it is auto-removed).
EOF
}

amd_meta_get_value() {
  local meta="${1:-}" key="${2:-}" val=""
  [[ -f "$meta" && -n "$key" ]] || return 0
  val="$(sed -nE "s/^${key}=//p" "$meta" 2>/dev/null | head -n1 || true)"
  if declare -F kv_norm >/dev/null 2>&1; then
    val="$(kv_norm "$val")"
  else
    val="${val//$'\r'/}"
  fi
  printf '%s\n' "$val"
}

amd_meta_installed_ver_consistency_reason() {
  local meta="${1:-}" expected_path="${2:-}"
  local installed_ver="" expected_ver=""
  [[ -f "$meta" && -n "$expected_path" ]] || return 0
  grep -qE '^FSR4_INSTALLED_VER=' "$meta" 2>/dev/null || return 0

  expected_ver="$(fsr4_version_from_versioned_cache_name "$expected_path" 2>/dev/null || true)"
  [[ -n "$expected_ver" ]] || return 0

  installed_ver="$(amd_meta_get_value "$meta" "FSR4_INSTALLED_VER")"
  if [[ -z "$installed_ver" ]]; then
    printf '%s\n' "installed_ver_missing"
    return 0
  fi
  if [[ "$installed_ver" != "$expected_ver" ]]; then
    printf '%s\n' "installed_ver_mismatch"
  fi
}

amd_meta_fingerprint_match_status() {
  local meta_sha="${1:-}" meta_size="${2:-}" dll_sha="${3:-}" dll_size="${4:-}" strict="${5:-0}"
  local -n out_match_ref="$6" out_reason_ref="$7"
  local reason="" cmp_any=0 cmp_ok=1

  out_match_ref=0
  out_reason_ref="insufficient_data"

  if [[ "$strict" == "1" ]]; then
    reason="ok"
    if [[ -z "$meta_sha" ]]; then
      reason="insufficient_data"
    fi
    if [[ "$reason" == "ok" && ! "$meta_sha" =~ ^[0-9a-fA-F]{64}$ ]]; then
      reason="meta_sha_invalid"
    fi
    if [[ "$reason" == "ok" && -n "$meta_size" && ! "$meta_size" =~ ^[0-9]+$ ]]; then
      reason="meta_size_invalid"
    fi
    if [[ -n "$meta_size" && -n "$dll_size" && "$meta_size" != "$dll_size" ]]; then
      reason="size_mismatch"
    fi
    if [[ "$reason" == "ok" && -n "$meta_sha" && -n "$dll_sha" && "$meta_sha" != "$dll_sha" ]]; then
      reason="sha256_mismatch"
    fi
    if [[ "$reason" == "ok" ]]; then
      out_match_ref=1
    fi
    out_reason_ref="$reason"
    return 0
  fi

  if [[ -n "$meta_size" ]]; then
    cmp_any=1
    if [[ -z "$dll_size" || "$meta_size" != "$dll_size" ]]; then
      cmp_ok=0
      reason="size_mismatch"
    fi
  fi
  if [[ -n "$meta_sha" ]]; then
    cmp_any=1
    if [[ -z "$dll_sha" ]]; then
      cmp_ok=0
      reason="${reason:-no_sha256_tool}"
    elif [[ "$meta_sha" != "$dll_sha" ]]; then
      cmp_ok=0
      reason="${reason:-sha256_mismatch}"
    fi
  fi

  if ((cmp_any == 1 && cmp_ok == 1)); then
    out_match_ref=1
    out_reason_ref="ok"
  else
    out_reason_ref="${reason:-insufficient_data}"
  fi
}

amd_allowlist_match_status() {
  local allow_path="${1:-}" dll_sha="${2:-}" dll_size="${3:-}" zero_size_unavailable="${4:-0}"
  local -n out_match_ref="$5" out_reason_ref="$6"

  out_match_ref=0
  out_reason_ref="allowlist_missing"

  if [[ ! -f "$allow_path" ]]; then
    out_reason_ref="allowlist_missing"
    return 0
  fi

  if [[ -z "$dll_sha" || -z "$dll_size" || ( "$zero_size_unavailable" == "1" && "$dll_size" == "0" ) ]]; then
    out_reason_ref="pair_unavailable"
    return 0
  fi

  if awk -v sha="$dll_sha" -v size="$dll_size" '
      { sub(/\r$/, "", $0) }
      /^[[:space:]]*#/ { next }
      /^[[:space:]]*$/ { next }
      {
        if ($1 == sha && $2 == size) { found=1; exit }
      }
      END { exit(found ? 0 : 1) }
    ' "$allow_path"; then
    out_match_ref=1
    out_reason_ref="ok"
  else
    out_reason_ref="not_allowlisted"
  fi
}

amd_dll_trust_result_status() {
  local meta_match="${1:-0}" meta_reason="${2:-unknown}" allow_match="${3:-0}" allow_reason="${4:-unknown}"
  local -n out_trusted_ref="$5" out_label_ref="$6" out_summary_ref="$7" out_reason_ref="$8"

  out_trusted_ref=0
  out_label_ref="untrusted"
  out_summary_ref="META_MATCH=${meta_match}, ALLOWLIST_MATCH=${allow_match}"
  out_reason_ref="${meta_reason:-unknown}"

  if [[ "$meta_match" == "1" && "$allow_match" == "1" ]]; then
    out_trusted_ref=1
    out_label_ref="trusted"
    out_reason_ref="ok"
    return 0
  fi

  if [[ "$meta_match" == "1" ]]; then
    out_reason_ref="${allow_reason:-unknown}"
  fi
  return 0
}

amd_meta_source_kind_consistency_reason() {
  local meta="${1:-}"
  local installed_ver_source="" source_kind=""
  [[ -f "$meta" ]] || return 0
  grep -qE '^FSR4_INSTALLED_VER_SOURCE=' "$meta" 2>/dev/null || return 0

  installed_ver_source="$(amd_meta_get_value "$meta" "FSR4_INSTALLED_VER_SOURCE")"
  [[ "$installed_ver_source" == "trusted_version_map" ]] || return 0

  source_kind="$(amd_meta_get_value "$meta" "SOURCE_KIND")"
  if [[ -z "$source_kind" ]]; then
    printf '%s\n' "source_kind_missing"
    return 0
  fi
  if [[ "$source_kind" != "trusted-version" ]]; then
    printf '%s\n' "source_kind_mismatch"
  fi
}

amd_meta_amd_source_driver_flavor_consistency_reason() {
  local meta="${1:-}"
  local installed_ver_source="" source_kind="" driver_flavor="" source_path="" source_url=""
  [[ -f "$meta" ]] || return 0
  grep -qE '^FSR4_INSTALLED_VER_SOURCE=' "$meta" 2>/dev/null || return 0
  grep -qE '^SOURCE_KIND=' "$meta" 2>/dev/null || return 0

  installed_ver_source="$(amd_meta_get_value "$meta" "FSR4_INSTALLED_VER_SOURCE")"
  case "$installed_ver_source" in
    installed_dll_scan | dev_override) ;;
    *) return 0 ;;
  esac

  source_kind="$(amd_meta_get_value "$meta" "SOURCE_KIND")"
  case "$source_kind" in
    exe)
      source_path="$(amd_meta_get_value "$meta" "SOURCE_PATH")"
      [[ -n "$source_path" && "$source_path" == *.[eE][xX][eE] ]] || return 0
      ;;
    url)
      source_url="$(amd_meta_get_value "$meta" "SOURCE_URL")"
      [[ -n "$source_url" ]] || return 0
      ;;
    *) return 0 ;;
  esac

  if ! grep -qE '^DRIVER_FLAVOR=' "$meta" 2>/dev/null; then
    printf '%s\n' "amd_driver_flavor_missing"
    return 0
  fi

  driver_flavor="$(amd_meta_get_value "$meta" "DRIVER_FLAVOR")"
  if [[ -z "$driver_flavor" ]]; then
    printf '%s\n' "amd_driver_flavor_missing"
    return 0
  fi

  case "$driver_flavor" in
    local-dll | trusted-version) printf '%s\n' "amd_driver_flavor_mismatch" ;;
  esac
}

amd_meta_amd_source_kind_consistency_reason() {
  local meta="${1:-}"
  local driver_flavor="" installed_ver_source="" source_kind=""
  [[ -f "$meta" ]] || return 0
  grep -qE '^DRIVER_FLAVOR=' "$meta" 2>/dev/null || return 0
  grep -qE '^FSR4_INSTALLED_VER_SOURCE=' "$meta" 2>/dev/null || return 0

  driver_flavor="$(amd_meta_get_value "$meta" "DRIVER_FLAVOR")"
  case "$driver_flavor" in
    "" | local-dll | trusted-version) return 0 ;;
  esac

  installed_ver_source="$(amd_meta_get_value "$meta" "FSR4_INSTALLED_VER_SOURCE")"
  case "$installed_ver_source" in
    installed_dll_scan | dev_override) ;;
    *) return 0 ;;
  esac

  if ! grep -qE '^SOURCE_KIND=' "$meta" 2>/dev/null; then
    printf '%s\n' "amd_source_kind_missing"
    return 0
  fi

  source_kind="$(amd_meta_get_value "$meta" "SOURCE_KIND")"
  if [[ -z "$source_kind" ]]; then
    printf '%s\n' "amd_source_kind_missing"
    return 0
  fi

  case "$source_kind" in
    exe | url) ;;
    *) printf '%s\n' "amd_source_kind_mismatch" ;;
  esac
}

amd_meta_amd_source_path_consistency_reason() {
  local meta="${1:-}"
  local driver_flavor="" installed_ver_source="" source_kind="" source_path=""
  [[ -f "$meta" ]] || return 0
  grep -qE '^DRIVER_FLAVOR=' "$meta" 2>/dev/null || return 0
  grep -qE '^FSR4_INSTALLED_VER_SOURCE=' "$meta" 2>/dev/null || return 0
  grep -qE '^SOURCE_KIND=' "$meta" 2>/dev/null || return 0

  driver_flavor="$(amd_meta_get_value "$meta" "DRIVER_FLAVOR")"
  case "$driver_flavor" in
    "" | local-dll | trusted-version) return 0 ;;
  esac

  installed_ver_source="$(amd_meta_get_value "$meta" "FSR4_INSTALLED_VER_SOURCE")"
  case "$installed_ver_source" in
    installed_dll_scan | dev_override) ;;
    *) return 0 ;;
  esac

  source_kind="$(amd_meta_get_value "$meta" "SOURCE_KIND")"
  [[ "$source_kind" == "exe" ]] || return 0

  if ! grep -qE '^SOURCE_PATH=' "$meta" 2>/dev/null; then
    printf '%s\n' "amd_source_path_missing"
    return 0
  fi

  source_path="$(amd_meta_get_value "$meta" "SOURCE_PATH")"
  if [[ -z "$source_path" ]]; then
    printf '%s\n' "amd_source_path_missing"
    return 0
  fi

  if [[ "$source_path" != *.[eE][xX][eE] ]]; then
    printf '%s\n' "amd_source_path_shape_mismatch"
  fi
}

amd_meta_amd_source_url_consistency_reason() {
  local meta="${1:-}"
  local driver_flavor="" installed_ver_source="" source_kind="" source_url=""
  [[ -f "$meta" ]] || return 0
  grep -qE '^DRIVER_FLAVOR=' "$meta" 2>/dev/null || return 0
  grep -qE '^FSR4_INSTALLED_VER_SOURCE=' "$meta" 2>/dev/null || return 0
  grep -qE '^SOURCE_KIND=' "$meta" 2>/dev/null || return 0

  driver_flavor="$(amd_meta_get_value "$meta" "DRIVER_FLAVOR")"
  case "$driver_flavor" in
    "" | local-dll | trusted-version) return 0 ;;
  esac

  installed_ver_source="$(amd_meta_get_value "$meta" "FSR4_INSTALLED_VER_SOURCE")"
  case "$installed_ver_source" in
    installed_dll_scan | dev_override) ;;
    *) return 0 ;;
  esac

  source_kind="$(amd_meta_get_value "$meta" "SOURCE_KIND")"
  [[ "$source_kind" == "url" ]] || return 0

  if ! grep -qE '^SOURCE_URL=' "$meta" 2>/dev/null; then
    printf '%s\n' "amd_source_url_missing"
    return 0
  fi

  source_url="$(amd_meta_get_value "$meta" "SOURCE_URL")"
  if [[ -z "$source_url" ]]; then
    printf '%s\n' "amd_source_url_missing"
    return 0
  fi

  if [[ "$source_url" != *://* ]]; then
    printf '%s\n' "amd_source_url_shape_mismatch"
  fi
}

amd_meta_installed_ver_source_consistency_reason() {
  local meta="${1:-}"
  local source_kind="" installed_ver_source=""
  [[ -f "$meta" ]] || return 0
  grep -qE '^SOURCE_KIND=' "$meta" 2>/dev/null || return 0

  source_kind="$(amd_meta_get_value "$meta" "SOURCE_KIND")"
  [[ "$source_kind" == "trusted-version" ]] || return 0

  if ! grep -qE '^FSR4_INSTALLED_VER_SOURCE=' "$meta" 2>/dev/null; then
    printf '%s\n' "installed_ver_source_missing"
    return 0
  fi

  installed_ver_source="$(amd_meta_get_value "$meta" "FSR4_INSTALLED_VER_SOURCE")"
  if [[ -z "$installed_ver_source" ]]; then
    printf '%s\n' "installed_ver_source_missing"
    return 0
  fi
  if [[ "$installed_ver_source" != "trusted_version_map" ]]; then
    printf '%s\n' "installed_ver_source_mismatch"
  fi
}

amd_meta_local_dll_installed_ver_source_consistency_reason() {
  local meta="${1:-}"
  local driver_flavor="" source_kind="" installed_ver_source=""
  [[ -f "$meta" ]] || return 0
  grep -qE '^DRIVER_FLAVOR=' "$meta" 2>/dev/null || return 0
  grep -qE '^SOURCE_KIND=' "$meta" 2>/dev/null || return 0

  driver_flavor="$(amd_meta_get_value "$meta" "DRIVER_FLAVOR")"
  source_kind="$(amd_meta_get_value "$meta" "SOURCE_KIND")"
  [[ "$driver_flavor" == "local-dll" && "$source_kind" == "dll" ]] || return 0

  if ! grep -qE '^FSR4_INSTALLED_VER_SOURCE=' "$meta" 2>/dev/null; then
    printf '%s\n' "local_installed_ver_source_missing"
    return 0
  fi

  installed_ver_source="$(amd_meta_get_value "$meta" "FSR4_INSTALLED_VER_SOURCE")"
  if [[ -z "$installed_ver_source" ]]; then
    printf '%s\n' "local_installed_ver_source_missing"
    return 0
  fi
  case "$installed_ver_source" in
    installed_dll_scan | dev_override) ;;
    *) printf '%s\n' "local_installed_ver_source_mismatch" ;;
  esac
}

amd_meta_local_dll_source_kind_consistency_reason() {
  local meta="${1:-}"
  local driver_flavor="" installed_ver_source="" source_kind=""
  [[ -f "$meta" ]] || return 0
  grep -qE '^DRIVER_FLAVOR=' "$meta" 2>/dev/null || return 0
  grep -qE '^FSR4_INSTALLED_VER_SOURCE=' "$meta" 2>/dev/null || return 0

  driver_flavor="$(amd_meta_get_value "$meta" "DRIVER_FLAVOR")"
  installed_ver_source="$(amd_meta_get_value "$meta" "FSR4_INSTALLED_VER_SOURCE")"
  [[ "$driver_flavor" == "local-dll" && "$installed_ver_source" == "installed_dll_scan" ]] || return 0

  source_kind="$(amd_meta_get_value "$meta" "SOURCE_KIND")"
  if [[ -z "$source_kind" ]]; then
    printf '%s\n' "local_source_kind_missing"
    return 0
  fi
  if [[ "$source_kind" != "dll" ]]; then
    printf '%s\n' "local_source_kind_mismatch"
  fi
}

amd_meta_provenance_consistency_reason() {
  local meta="${1:-}" expected_path="${2:-}" reason=""
  [[ -f "$meta" ]] || return 0

  reason="$(amd_meta_installed_ver_consistency_reason "$meta" "$expected_path")"
  [[ -n "$reason" ]] && printf '%s\n' "$reason" && return 0

  reason="$(amd_meta_amd_source_driver_flavor_consistency_reason "$meta")"
  [[ -n "$reason" ]] && printf '%s\n' "$reason" && return 0

  reason="$(amd_meta_source_kind_consistency_reason "$meta")"
  [[ -n "$reason" ]] && printf '%s\n' "$reason" && return 0

  reason="$(amd_meta_amd_source_kind_consistency_reason "$meta")"
  [[ -n "$reason" ]] && printf '%s\n' "$reason" && return 0

  reason="$(amd_meta_amd_source_path_consistency_reason "$meta")"
  [[ -n "$reason" ]] && printf '%s\n' "$reason" && return 0

  reason="$(amd_meta_amd_source_url_consistency_reason "$meta")"
  [[ -n "$reason" ]] && printf '%s\n' "$reason" && return 0

  reason="$(amd_meta_installed_ver_source_consistency_reason "$meta")"
  [[ -n "$reason" ]] && printf '%s\n' "$reason" && return 0

  reason="$(amd_meta_local_dll_installed_ver_source_consistency_reason "$meta")"
  [[ -n "$reason" ]] && printf '%s\n' "$reason" && return 0

  reason="$(amd_meta_local_dll_source_kind_consistency_reason "$meta")"
  [[ -n "$reason" ]] && printf '%s\n' "$reason" && return 0

  return 0
}

amd_meta_driver_label_from_file() {
  local meta="${1:-}" label=""
  [[ -f "$meta" ]] || return 0
  label="$(amd_meta_get_value "$meta" "DRIVER_LABEL")"
  [[ -n "$label" ]] || label="$(amd_meta_get_value "$meta" "AMD_DRIVER_LABEL")"
  printf '%s\n' "$label"
}

amd_driver_label_numeric_ver() {
  local label="${1:-}"
  if [[ "$label" =~ (^|[^0-9])([0-9]{2}\.[0-9]{1,2}\.[0-9]{1,2})(-|$) ]]; then
    printf '%s\n' "${BASH_REMATCH[2]}"
  fi
}

amd_size_human_short() {
  local bytes="${1:-0}"
  [[ "$bytes" =~ ^[0-9]+$ ]] || bytes=0
  LC_ALL=C awk -v n="$bytes" '
    BEGIN {
      split("B K M G T P", u, " ")
      i=1
      while (n >= 1024 && i < 6) {
        n /= 1024
        i++
      }
      if (i == 1) {
        printf "%d%s\n", n, u[i]
      } else {
        printf "%.1f%s\n", n, u[i]
      }
    }
  '
}

amd_driver_display_value() {
  local driver_label="${1:-}" source_kind="${2:-}"
  local numeric=""
  numeric="$(amd_driver_label_numeric_ver "$driver_label")"
  if [[ -n "$numeric" ]]; then
    printf '%s\n' "$numeric"
    return 0
  fi
  if [[ "$source_kind" == "dll" ]]; then
    printf '%s\n' "local"
    return 0
  fi
  printf '%s\n' "-"
}

amd_source_display_value() {
  local source_kind="${1:-}"
  [[ -n "$source_kind" ]] || source_kind="?"
  printf '%s\n' "$source_kind"
}

amd_triplet_version_compare() {
  local left="${1:-}" right="${2:-}"
  local -n out_ref="$3"
  out_ref="unknown"

  if [[ ! "$left" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || ! "$right" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    return 1
  fi

  local l1=0 l2=0 l3=0 r1=0 r2=0 r3=0
  IFS=. read -r l1 l2 l3 <<<"$left"
  IFS=. read -r r1 r2 r3 <<<"$right"

  if ((10#$l1 < 10#$r1)); then
    out_ref="lt"
    return 0
  fi
  if ((10#$l1 > 10#$r1)); then
    out_ref="gt"
    return 0
  fi
  if ((10#$l2 < 10#$r2)); then
    out_ref="lt"
    return 0
  fi
  if ((10#$l2 > 10#$r2)); then
    out_ref="gt"
    return 0
  fi
  if ((10#$l3 < 10#$r3)); then
    out_ref="lt"
    return 0
  fi
  if ((10#$l3 > 10#$r3)); then
    out_ref="gt"
    return 0
  fi

  out_ref="eq"
  return 0
}

amd_dll_source_brief() {
  local kind="${1:-}" path="${2:-}" url="${3:-}"
  if [[ -n "$url" ]]; then
    if [[ -n "$kind" ]]; then
      printf '%s\n' "$kind $url"
    else
      printf '%s\n' "$url"
    fi
    return 0
  fi
  if [[ -n "$path" ]]; then
    if [[ -n "$kind" ]]; then
      printf '%s\n' "$kind $path"
    else
      printf '%s\n' "$path"
    fi
    return 0
  fi
  [[ -n "$kind" ]] && printf '%s\n' "$kind" || printf '%s\n' "unknown"
}

amd_dll_source_name() {
  local path="${1:-}" url="${2:-}"
  local src=""
  if [[ -n "$path" ]]; then
    src="${path##*/}"
    [[ -n "$src" ]] && printf '%s\n' "$src" && return 0
  fi
  if [[ -n "$url" ]]; then
    src="${url##*/}"
    src="${src%%\?*}"
    [[ -n "$src" ]] && printf '%s\n' "$src" && return 0
  fi
  printf '%s\n' "-"
}

amd_dll_same_ver_overwrite_guard() {
  local dst_dir="${1:-$DLL_DST_DIR_DEFAULT}"
  local incoming_dll="${2:-}"
  local incoming_meta="${3:-}"
  local incoming_ver="${4:-$FSR4_LOCAL_DEFAULT_VER}"
  local incoming_driver_label="${5:-}"
  local incoming_source_kind="${6:-}"
  local incoming_source_path="${7:-}"
  local incoming_source_url="${8:-}"
  local incoming_hint_path="${9:-}"
  local assume_yes="${10:-0}"
  local ctx="${11:-dll install}"
  local -n out_prompted_ref="${12:-}"

  out_prompted_ref=0
  validate_amd_cache_names

  local live_dll="$dst_dir/${AMD_DLL_NAME}"
  local live_meta="$dst_dir/${AMD_META_NAME}"
  [[ -f "$live_dll" ]] || return 0

  local live_sha="" incoming_sha=""
  if have sha256sum; then
    live_sha="$(sha256sum "$live_dll" 2>/dev/null | awk '{print $1}' || true)"
    incoming_sha="$(sha256sum "$incoming_dll" 2>/dev/null | awk '{print $1}' || true)"
  fi

  local live_driver_label="" live_source_kind="" live_source_path="" live_source_url=""
  if [[ -f "$live_meta" ]]; then
    live_driver_label="$(amd_meta_driver_label_from_file "$live_meta")"
    live_source_kind="$(amd_meta_get_value "$live_meta" "SOURCE_KIND")"
    live_source_path="$(amd_meta_get_value "$live_meta" "SOURCE_PATH")"
    live_source_url="$(amd_meta_get_value "$live_meta" "SOURCE_URL")"
  fi

  if [[ -f "$incoming_meta" ]]; then
    [[ -n "$incoming_driver_label" ]] || incoming_driver_label="$(amd_meta_driver_label_from_file "$incoming_meta")"
    [[ -n "$incoming_source_kind" ]] || incoming_source_kind="$(amd_meta_get_value "$incoming_meta" "SOURCE_KIND")"
    [[ -n "$incoming_source_path" ]] || incoming_source_path="$(amd_meta_get_value "$incoming_meta" "SOURCE_PATH")"
    [[ -n "$incoming_source_url" ]] || incoming_source_url="$(amd_meta_get_value "$incoming_meta" "SOURCE_URL")"
  fi

  [[ -n "$incoming_source_path" ]] || incoming_source_path="$incoming_dll"

  if [[ -n "$incoming_sha" && -n "$live_sha" && "$incoming_sha" == "$live_sha" ]]; then
    local identical_action_label="reinstall"
    local identical_action_detail="reinstalling and overwriting the same DLL"
    if [[ "$ctx" == "restore" ]]; then
      identical_action_label="restore"
      identical_action_detail="restoring and overwriting with the same DLL"
    fi
    info "Same-version ${identical_action_label}: installed FSR4 ${incoming_ver} is identical to the incoming DLL."
    print_label_value_row "Driver Label:" "${incoming_driver_label:-${live_driver_label:-unknown}}"
    print_label_value_row "DLL SHA256:" "$incoming_sha"
    print_label_value_row "Action:" "$identical_action_detail"
    return 0
  fi

  local live_driver_ver="" incoming_driver_ver="" relation="unknown"
  live_driver_ver="$(amd_driver_label_numeric_ver "$live_driver_label")"
  incoming_driver_ver="$(amd_driver_label_numeric_ver "$incoming_driver_label")"
  if [[ -n "$live_driver_ver" && -n "$incoming_driver_ver" ]]; then
    amd_triplet_version_compare "$incoming_driver_ver" "$live_driver_ver" relation || relation="unknown"
  fi

  local prompt=""
  case "$relation" in
    lt)
      warn "Same-version overwrite: installed FSR4 ${incoming_ver} comes from newer driver ${live_driver_label:-unknown}."
      warn "Incoming source uses older driver ${incoming_driver_label:-unknown}."
      prompt="Overwrite installed FSR4 ${incoming_ver} with the older-driver DLL? [y/N]: "
      ;;
    gt)
      info "Same-version overwrite: installed FSR4 ${incoming_ver} will be replaced with a DLL from newer driver ${incoming_driver_label:-unknown}."
      prompt="Overwrite installed FSR4 ${incoming_ver} with the newer-driver DLL? [y/N]: "
      ;;
    eq)
      warn "Same-version overwrite: installed and incoming FSR4 ${incoming_ver} DLLs differ, but both report driver ${incoming_driver_label:-${live_driver_label:-unknown}}."
      prompt="Overwrite installed FSR4 ${incoming_ver} with this different DLL? [y/N]: "
      ;;
    *)
      warn "Same-version overwrite: installed and incoming FSR4 ${incoming_ver} DLLs differ."
      prompt="Overwrite installed FSR4 ${incoming_ver} with this different DLL? [y/N]: "
      ;;
  esac

  msg ""
  msg "Installed:"
  print_label_value_row "Driver Label:" "${live_driver_label:-unknown}"
  [[ -n "$live_sha" ]] && print_label_value_row "DLL SHA256:" "$live_sha"
  print_label_value_row "Source:" "$(amd_dll_source_brief "$live_source_kind" "$live_source_path" "$live_source_url")"
  msg ""
  msg "Incoming:"
  print_label_value_row "Driver Label:" "${incoming_driver_label:-unknown}"
  [[ -n "$incoming_sha" ]] && print_label_value_row "DLL SHA256:" "$incoming_sha"
  print_label_value_row "Source:" "$(amd_dll_source_brief "$incoming_source_kind" "$incoming_source_path" "$incoming_source_url")"
  [[ -n "$incoming_hint_path" ]] && print_label_value_row "Backup:" "$incoming_hint_path"
  msg ""

  if [[ "$assume_yes" == "1" ]]; then
    info "Assuming overwrite consent. Continuing."
    out_prompted_ref=1
    return 0
  fi

  if ! is_tty; then
    if [[ "$ctx" == "restore" ]]; then
      die "restore: overwrite confirmation required; re-run interactively or use --yes."
    fi
    die "${ctx}: overwrite confirmation required; re-run interactively or set GENVW_ASSUME_YES=1."
  fi

  if ! ask_yes_no_default "$prompt" "n"; then
    die "${ctx}: cancelled."
  fi
  out_prompted_ref=1
}

amd_dll_backup_root() {
  local dst_dir="${1:-$DLL_DST_DIR_DEFAULT}"
  printf '%s\n' "${dst_dir%/}/backups"
}

amd_remove_exact_tmp_dir() {
  local dir="${1:-}"
  [[ -n "$dir" ]] || return 0
  [[ -d "$dir" ]] || return 0
  rm -rf -- "$dir"
}

amd_dll_snapshot_validate_dir() {
  local snapshot_dir="${1:-}" expected_ver="${2:-}"
  local -n out_dll_ref="$3"
  local -n out_meta_ref="$4"
  local -n out_report_ref="$5"
  local -n out_sha_ref="$6"
  local -n out_size_ref="$7"
  local -n out_created_ref="$8"
  local -n out_reason_ref="$9"

  out_dll_ref=""
  out_meta_ref=""
  out_report_ref=""
  out_sha_ref=""
  out_size_ref=""
  out_created_ref=""
  out_reason_ref="unknown"

  [[ -d "$snapshot_dir" ]] || {
    out_reason_ref="missing_snapshot_dir"
    return 1
  }

  local had_nullglob=0
  shopt -q nullglob && had_nullglob=1
  shopt -s nullglob
  local -a dlls=( "$snapshot_dir"/"${AMD_DLL_STEM}"_v*.dll )
  local -a metas=( "$snapshot_dir"/"${AMD_DLL_STEM}"_v*.meta.txt )
  local -a reports=( "$snapshot_dir"/"${AMD_DLL_STEM}"_v*.report.txt )
  ((had_nullglob == 1)) || shopt -u nullglob

  ((${#dlls[@]} == 1)) || {
    out_reason_ref="snapshot_dll_count_${#dlls[@]}"
    return 1
  }
  ((${#metas[@]} == 1)) || {
    out_reason_ref="snapshot_meta_count_${#metas[@]}"
    return 1
  }
  ((${#reports[@]} == 1)) || {
    out_reason_ref="snapshot_report_count_${#reports[@]}"
    return 1
  }

  local dll="${dlls[0]}"
  local meta="${metas[0]}"
  local report="${reports[0]}"
  local snapshot_txt="$snapshot_dir/snapshot.txt"

  [[ -f "$snapshot_txt" ]] || {
    out_reason_ref="missing_snapshot_manifest"
    return 1
  }
  [[ -r "$dll" && -r "$meta" && -r "$report" && -r "$snapshot_txt" ]] || {
    out_reason_ref="snapshot_unreadable"
    return 1
  }

  local dll_ver="" meta_ver="" report_ver=""
  dll_ver="$(fsr4_version_from_versioned_cache_name "$dll" 2>/dev/null || true)"
  meta_ver="$(fsr4_version_from_versioned_cache_name "$meta" 2>/dev/null || true)"
  report_ver="$(fsr4_version_from_versioned_cache_name "$report" 2>/dev/null || true)"
  [[ -n "$dll_ver" && "$meta_ver" == "$dll_ver" && "$report_ver" == "$dll_ver" ]] || {
    out_reason_ref="snapshot_name_version_mismatch"
    return 1
  }
  if [[ -n "$expected_ver" && "$dll_ver" != "$expected_ver" ]]; then
    out_reason_ref="snapshot_version_mismatch"
    return 1
  fi

  local dll_sha="" dll_size=""
  dll_sha="$(sha256sum "$dll" 2>/dev/null | awk '{print $1}' || true)"
  dll_size="$(stat -c %s "$dll" 2>/dev/null || true)"
  [[ "$dll_sha" =~ ^[0-9a-f]{64}$ ]] || {
    out_reason_ref="snapshot_dll_sha_invalid"
    return 1
  }
  [[ "$dll_size" =~ ^[0-9]+$ && "$dll_size" -gt 0 ]] || {
    out_reason_ref="snapshot_dll_size_invalid"
    return 1
  }

  local meta_sha="" meta_size="" meta_installed_ver=""
  meta_sha="$(amd_meta_get_value "$meta" "CACHE_DLL_SHA256")"
  meta_size="$(amd_meta_get_value "$meta" "CACHE_DLL_SIZE")"
  meta_installed_ver="$(amd_meta_get_value "$meta" "FSR4_INSTALLED_VER")"
  [[ "$meta_sha" == "$dll_sha" ]] || {
    out_reason_ref="snapshot_meta_sha_mismatch"
    return 1
  }
  [[ "$meta_size" == "$dll_size" ]] || {
    out_reason_ref="snapshot_meta_size_mismatch"
    return 1
  }
  [[ "$meta_installed_ver" == "$dll_ver" ]] || {
    out_reason_ref="snapshot_meta_ver_mismatch"
    return 1
  }

  local snap_format="" snap_ver="" snap_sha="" snap_size="" snap_created=""
  snap_format="$(amd_meta_get_value "$snapshot_txt" "SNAPSHOT_FORMAT_VERSION")"
  snap_ver="$(amd_meta_get_value "$snapshot_txt" "FSR4_VER")"
  snap_sha="$(amd_meta_get_value "$snapshot_txt" "CACHE_DLL_SHA256")"
  snap_size="$(amd_meta_get_value "$snapshot_txt" "CACHE_DLL_SIZE")"
  snap_created="$(amd_meta_get_value "$snapshot_txt" "CREATED_AT_UTC")"
  [[ "$snap_format" == "1" ]] || {
    out_reason_ref="snapshot_manifest_format"
    return 1
  }
  [[ "$snap_ver" == "$dll_ver" ]] || {
    out_reason_ref="snapshot_manifest_ver_mismatch"
    return 1
  }
  [[ "$snap_sha" == "$dll_sha" ]] || {
    out_reason_ref="snapshot_manifest_sha_mismatch"
    return 1
  }
  [[ "$snap_size" == "$dll_size" ]] || {
    out_reason_ref="snapshot_manifest_size_mismatch"
    return 1
  }

  out_dll_ref="$dll"
  out_meta_ref="$meta"
  out_report_ref="$report"
  out_sha_ref="$dll_sha"
  out_size_ref="$dll_size"
  out_created_ref="$snap_created"
  out_reason_ref="ok"
  return 0
}

amd_dll_snapshot_create() {
  local dst_dir="${1:-$DLL_DST_DIR_DEFAULT}"
  local want_ver="${2:-$FSR4_LOCAL_DEFAULT_VER}"
  local dry_run="${3:-0}"

  validate_amd_cache_names
  fsr4_require_local_write_supported_ver "$want_ver" "dll backup"

  local expected="$dst_dir/${AMD_DLL_NAME}"
  local meta="$dst_dir/${AMD_META_NAME}"
  local report="$dst_dir/${AMD_REPORT_NAME}"

  [[ -f "$expected" ]] || die "backup: installed DLL is missing: $expected"
  [[ -f "$meta" ]] || die "backup: provenance meta is missing: $meta"
  [[ -f "$report" ]] || die "backup: report is missing: $report"

  if ! amd_dll_provenance_integrity verify "$dst_dir"; then
    die "backup: the installed DLL is not trusted; fix trust first, then back it up."
  fi

  local dll_sha="" dll_size=""
  dll_sha="$(sha256sum "$expected" 2>/dev/null | awk '{print $1}' || true)"
  dll_size="$(stat -c %s "$expected" 2>/dev/null || true)"
  [[ "$dll_sha" =~ ^[0-9a-f]{64}$ ]] || die "backup: could not compute DLL sha256: $expected"
  [[ "$dll_size" =~ ^[0-9]+$ && "$dll_size" -gt 0 ]] || die "backup: could not compute DLL size: $expected"

  local backup_root="" version_dir="" final_dir=""
  backup_root="$(amd_dll_backup_root "$dst_dir")"
  version_dir="${backup_root}/v${want_ver}"
  final_dir="${version_dir}/sha256_${dll_sha}__size_${dll_size}"

  mkdir -p -- "$backup_root" "$version_dir" || die "backup: could not create backup folders under: $backup_root"
  chmod 700 -- "$backup_root" "$version_dir" 2>/dev/null || die "backup: could not protect backup folders: $backup_root"

  local existing_dll="" existing_meta="" existing_report="" existing_sha="" existing_size="" existing_created="" existing_reason=""
  if [[ -d "$final_dir" ]]; then
    if amd_dll_snapshot_validate_dir "$final_dir" "$want_ver" existing_dll existing_meta existing_report existing_sha existing_size existing_created existing_reason; then
      ok "Backup already present: $final_dir"
      return 0
    fi
    die "backup: existing backup is inconsistent (${existing_reason}): $final_dir"
  fi

  if ((dry_run == 1)); then
    msg "${I_INFO} dry-run: would create backup"
    msg "  ver: $want_ver"
    msg "  dll: $expected"
    msg "  meta: $meta"
    msg "  report: $report"
    msg "  backup: $final_dir"
    return 0
  fi

  local tmp_dir=""
  local __old_trap_exit="" __old_trap_int="" __old_trap_term=""
  tmp_dir="$(mktemp -d "${backup_root}/tmp.snapshot.XXXXXX")" || die "backup: could not create temp backup dir under: $backup_root"
  __old_trap_exit="$(trap -p EXIT 2>/dev/null || true)"
  __old_trap_int="$(trap -p INT 2>/dev/null || true)"
  __old_trap_term="$(trap -p TERM 2>/dev/null || true)"
  declare -g __GENVW_DLL_SNAPSHOT_TMP_DIR="$tmp_dir"
  trap 'amd_remove_exact_tmp_dir "${__GENVW_DLL_SNAPSHOT_TMP_DIR:-}"' EXIT
  trap 'amd_remove_exact_tmp_dir "${__GENVW_DLL_SNAPSHOT_TMP_DIR:-}"; exit 130' INT
  trap 'amd_remove_exact_tmp_dir "${__GENVW_DLL_SNAPSHOT_TMP_DIR:-}"; exit 143' TERM

  local snap_dll="$tmp_dir/${AMD_DLL_NAME}"
  local snap_meta="$tmp_dir/${AMD_META_NAME}"
  local snap_report="$tmp_dir/${AMD_REPORT_NAME}"
  local snap_manifest="$tmp_dir/snapshot.txt"
  local meta_source_kind="" meta_source_sha="" meta_driver_label="" meta_driver_flavor=""
  meta_source_kind="$(amd_meta_get_value "$meta" "SOURCE_KIND")"
  meta_source_sha="$(amd_meta_get_value "$meta" "SOURCE_SHA256")"
  meta_driver_label="$(amd_meta_get_value "$meta" "DRIVER_LABEL")"
  meta_driver_flavor="$(amd_meta_get_value "$meta" "DRIVER_FLAVOR")"

  cp -f -- "$expected" "$snap_dll" || die "backup: could not copy DLL into temp backup dir: $snap_dll"
  cp -f -- "$meta" "$snap_meta" || die "backup: could not copy meta into temp backup dir: $snap_meta"
  cp -f -- "$report" "$snap_report" || die "backup: could not copy report into temp backup dir: $snap_report"
  {
    echo "SNAPSHOT_FORMAT_VERSION=1"
    echo "CREATED_AT_UTC=$(date -u +'%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || true)"
    echo "FSR4_VER=$want_ver"
    echo "CACHE_DLL_SHA256=$dll_sha"
    echo "CACHE_DLL_SIZE=$dll_size"
    echo "SOURCE_KIND=$meta_source_kind"
    echo "SOURCE_SHA256=$meta_source_sha"
    echo "DRIVER_LABEL=$meta_driver_label"
    echo "DRIVER_FLAVOR=$meta_driver_flavor"
  } >"$snap_manifest" || die "backup: could not write manifest: $snap_manifest"

  local tmp_dll="" tmp_meta="" tmp_report="" tmp_sha="" tmp_size="" tmp_created="" tmp_reason=""
  if ! amd_dll_snapshot_validate_dir "$tmp_dir" "$want_ver" tmp_dll tmp_meta tmp_report tmp_sha tmp_size tmp_created tmp_reason; then
    die "backup: temp backup validation failed (${tmp_reason})"
  fi

  chmod 0400 -- "$snap_dll" "$snap_meta" "$snap_report" "$snap_manifest" 2>/dev/null || die "backup: could not protect backup files in: $tmp_dir"
  mv -- "$tmp_dir" "$final_dir" || die "backup: could not seal backup into place: $final_dir"
  chmod 0500 -- "$final_dir" 2>/dev/null || die "backup: could not protect sealed backup dir: $final_dir"

  __GENVW_DLL_SNAPSHOT_TMP_DIR=""
  restore_one_trap "$__old_trap_exit" EXIT
  restore_one_trap "$__old_trap_int" INT
  restore_one_trap "$__old_trap_term" TERM

  ok "Created backup: $final_dir"
  msg "  sha256: $dll_sha"
  msg "  restore: $(cmd_dll) restore --ver $want_ver --sha256 $dll_sha"
}

amd_dll_restore_snapshot() {
  local dst_dir="${1:-$DLL_DST_DIR_DEFAULT}"
  local want_ver="${2:-$FSR4_LOCAL_DEFAULT_VER}"
  local want_sha="${3:-}"
  local assume_yes="${4:-0}"
  local dry_run="${5:-0}"

  validate_amd_cache_names
  fsr4_require_local_write_supported_ver "$want_ver" "dll restore"

  want_sha="${want_sha,,}"
  if [[ -n "$want_sha" && ! "$want_sha" =~ ^[0-9a-f]{64}$ ]]; then
    die "restore: --sha256 must be a full 64-character SHA-256 value"
  fi

  local backup_root="" version_dir=""
  backup_root="$(amd_dll_backup_root "$dst_dir")"
  version_dir="${backup_root}/v${want_ver}"
  [[ -d "$version_dir" ]] || die "restore: no snapshots found for FSR4 ${want_ver} in: $version_dir"

  local had_nullglob=0
  shopt -q nullglob && had_nullglob=1
  shopt -s nullglob
  local -a candidate_dirs=( "$version_dir"/sha256_*__size_* )
  ((had_nullglob == 1)) || shopt -u nullglob
  ((${#candidate_dirs[@]} > 0)) || die "restore: no snapshots found for FSR4 ${want_ver} in: $version_dir"

  local -a valid_dirs=() valid_shas=() valid_sizes=() valid_created=() valid_driver=() valid_source=() invalid_entries=()
  local cand="" cand_dll="" cand_meta="" cand_report="" cand_sha="" cand_size="" cand_created="" cand_reason=""
  for cand in "${candidate_dirs[@]}"; do
    [[ -d "$cand" ]] || continue
    if amd_dll_snapshot_validate_dir "$cand" "$want_ver" cand_dll cand_meta cand_report cand_sha cand_size cand_created cand_reason; then
      if [[ -n "$want_sha" && "$cand_sha" != "$want_sha" ]]; then
        continue
      fi
      local cand_driver_label="" cand_source_kind=""
      cand_driver_label="$(amd_meta_driver_label_from_file "$cand_meta")"
      cand_source_kind="$(amd_meta_get_value "$cand_meta" "SOURCE_KIND")"
      valid_dirs+=("$cand")
      valid_shas+=("$cand_sha")
      valid_sizes+=("$cand_size")
      valid_created+=("$cand_created")
      valid_driver+=("$(amd_driver_display_value "$cand_driver_label" "$cand_source_kind")")
      valid_source+=("$(amd_source_display_value "$cand_source_kind")")
    else
      invalid_entries+=("${cand}:${cand_reason}")
    fi
  done

  if ((${#valid_dirs[@]} == 0)); then
    if ((${#invalid_entries[@]} > 0)); then
      warn "restore: found backup folders, but none passed validation."
      for cand_reason in "${invalid_entries[@]}"; do
        msg "  $cand_reason"
      done
    fi
    if [[ -n "$want_sha" ]]; then
      die "restore: no valid snapshot matched SHA-256 ${want_sha} for FSR4 ${want_ver}"
    fi
    die "restore: no valid snapshots found for FSR4 ${want_ver}"
  fi

  if ((${#valid_dirs[@]} > 1)); then
    warn "restore: multiple valid snapshots match FSR4 ${want_ver}; choose one with --sha256:"
    local idx=0
    printf '  %-6s %-64s %-6s %-8s %-6s %-20s\n' "VER" "SHA256" "SIZE" "DRIVER" "SOURCE" "CREATED"
    for ((idx = 0; idx < ${#valid_dirs[@]}; idx++)); do
      printf '  %-6s %-64s %-6s %-8s %-6s %-20s\n' \
        "$want_ver" \
        "${valid_shas[idx]}" \
        "$(amd_size_human_short "${valid_sizes[idx]}")" \
        "${valid_driver[idx]}" \
        "${valid_source[idx]}" \
        "${valid_created[idx]:-unknown}"
    done
    msg ""
    msg "Use the full SHA256 with:"
    msg "  $(cmd_dll) restore --ver ${want_ver} --sha256 FULL_SHA256"
    die "restore: ambiguous snapshot selection"
  fi

  local selected_dir="${valid_dirs[0]}"
  local selected_sha="${valid_shas[0]}"
  local selected_size="${valid_sizes[0]}"
  local selected_created="${valid_created[0]}"
  local selected_dll="" selected_meta="" selected_report="" selected_reason=""
  if ! amd_dll_snapshot_validate_dir "$selected_dir" "$want_ver" selected_dll selected_meta selected_report selected_sha selected_size selected_created selected_reason; then
    die "restore: selected backup failed validation (${selected_reason}): $selected_dir"
  fi

  if ((dry_run == 1)); then
    msg "${I_INFO} dry-run: would restore backup"
    msg "  ver: $want_ver"
    msg "  backup: $selected_dir"
    msg "  sha256: $selected_sha"
    msg "  dst-dir: $dst_dir"
    return 0
  fi

  local overwrite_prompted=0
  amd_dll_same_ver_overwrite_guard \
    "$dst_dir" \
    "$selected_dll" \
    "$selected_meta" \
    "$want_ver" \
    "" \
    "" \
    "" \
    "" \
    "$selected_dir" \
    "$assume_yes" \
    "restore" \
    overwrite_prompted

  if ((assume_yes != 1 && overwrite_prompted != 1)); then
    if ! is_tty; then
      die "restore: non-interactive mode requires --yes."
    fi
    if ! ask_yes_no_default "Restore backup for FSR4 ${want_ver}? [y/N]: " "n"; then
      die "restore: cancelled."
    fi
  fi

  mkdir -p -- "$dst_dir" || die "restore: could not create dst-dir: $dst_dir"

  local tmp_dir=""
  local __old_trap_exit="" __old_trap_int="" __old_trap_term=""
  tmp_dir="$(mktemp -d "${backup_root}/tmp.restore.XXXXXX")" || die "restore: could not create temp restore dir under: $backup_root"
  __old_trap_exit="$(trap -p EXIT 2>/dev/null || true)"
  __old_trap_int="$(trap -p INT 2>/dev/null || true)"
  __old_trap_term="$(trap -p TERM 2>/dev/null || true)"
  declare -g __GENVW_DLL_RESTORE_TMP_DIR="$tmp_dir"
  trap 'amd_remove_exact_tmp_dir "${__GENVW_DLL_RESTORE_TMP_DIR:-}"' EXIT
  trap 'amd_remove_exact_tmp_dir "${__GENVW_DLL_RESTORE_TMP_DIR:-}"; exit 130' INT
  trap 'amd_remove_exact_tmp_dir "${__GENVW_DLL_RESTORE_TMP_DIR:-}"; exit 143' TERM

  local stage_dir="$tmp_dir/stage"
  local orig_dir="$tmp_dir/original"
  mkdir -p -- "$stage_dir" "$orig_dir" || die "restore: could not prepare temp restore staging in: $tmp_dir"

  local stage_dll="$stage_dir/${AMD_DLL_NAME}"
  local stage_meta="$stage_dir/${AMD_META_NAME}"
  local stage_report="$stage_dir/${AMD_REPORT_NAME}"
  cp -f -- "$selected_dll" "$stage_dll" || die "restore: could not stage snapshot DLL"
  cp -f -- "$selected_meta" "$stage_meta" || die "restore: could not stage snapshot meta"
  cp -f -- "$selected_report" "$stage_report" || die "restore: could not stage snapshot report"
  cp -f -- "$selected_dir/snapshot.txt" "$stage_dir/snapshot.txt" || die "restore: could not stage snapshot manifest"

  local stage_sha="" stage_size="" stage_created="" stage_reason=""
  if ! amd_dll_snapshot_validate_dir "$stage_dir" "$want_ver" cand_dll cand_meta cand_report stage_sha stage_size stage_created stage_reason; then
    die "restore: staged snapshot validation failed (${stage_reason})"
  fi

  local live_dll="$dst_dir/${AMD_DLL_NAME}"
  local live_meta="$dst_dir/${AMD_META_NAME}"
  local live_report="$dst_dir/${AMD_REPORT_NAME}"
  local -a names=( "${AMD_DLL_NAME}" "${AMD_META_NAME}" "${AMD_REPORT_NAME}" )
  local -a staged_files=( "$stage_dll" "$stage_meta" "$stage_report" )
  local -a live_files=( "$live_dll" "$live_meta" "$live_report" )
  declare -A had_original=()
  local idx=0
  for ((idx = 0; idx < ${#names[@]}; idx++)); do
    had_original["${names[idx]}"]=0
    if [[ -f "${live_files[idx]}" ]]; then
      cp -f -- "${live_files[idx]}" "$orig_dir/${names[idx]}" || die "restore: could not save current live file: ${live_files[idx]}"
      had_original["${names[idx]}"]=1
    fi
  done

  local restore_copy_failed=0
  for ((idx = 0; idx < ${#names[@]}; idx++)); do
    if ! cp -f -- "${staged_files[idx]}" "${live_files[idx]}"; then
      restore_copy_failed=1
      break
    fi
    chmod 0644 -- "${live_files[idx]}" 2>/dev/null || true
  done
  if ((restore_copy_failed == 1)); then
    for ((idx = 0; idx < ${#names[@]}; idx++)); do
      if [[ "${had_original[${names[idx]}]}" == "1" ]]; then
        cp -f -- "$orig_dir/${names[idx]}" "${live_files[idx]}" || true
        chmod 0644 -- "${live_files[idx]}" 2>/dev/null || true
      else
        rm -f -- "${live_files[idx]}" 2>/dev/null || true
      fi
    done
    die "restore: failed while writing live cache files; restored the previous state."
  fi

  local verify_out="" verify_rc=0 had_errexit=0
  case "$-" in
    *e*) had_errexit=1 ;;
  esac
  set +e
  verify_out="$(amd_dll_provenance_integrity verify "$dst_dir" 2>&1)"
  verify_rc=$?
  if ((had_errexit == 1)); then
    set -e
  else
    set +e
  fi
  if ((verify_rc != 0)); then
    for ((idx = 0; idx < ${#names[@]}; idx++)); do
      if [[ "${had_original[${names[idx]}]}" == "1" ]]; then
        cp -f -- "$orig_dir/${names[idx]}" "${live_files[idx]}" || true
        chmod 0644 -- "${live_files[idx]}" 2>/dev/null || true
      else
        rm -f -- "${live_files[idx]}" 2>/dev/null || true
      fi
    done
    printf '%s\n' "$verify_out"
    die "restore: restored files failed trust verification; reverted the live cache."
  fi

  printf '%s\n' "$verify_out"
  ok "${I_SHIELD} DLL trust: Trusted (META_MATCH=1, ALLOWLIST_MATCH=1)"

  amd_remove_exact_tmp_dir "$tmp_dir"
  __GENVW_DLL_RESTORE_TMP_DIR=""
  restore_one_trap "$__old_trap_exit" EXIT
  restore_one_trap "$__old_trap_int" INT
  restore_one_trap "$__old_trap_term" TERM

  ok "Restored backup: $selected_dir"
  msg "  installed: $live_dll"
  msg "  sha256: $selected_sha"
}

# enumerate the versioned cache DLLs on disk and summarize trust for each one.
# this is read-only on purpose: it mirrors verify/check logic without mutating cache state.
amd_dll_list() {
  local dst_dir="${1:-$DLL_DST_DIR_DEFAULT}" want_ver="${2:-}" trusted_only="${3:-0}" verbose="${4:-0}"
  local __saved_dll_name="${AMD_DLL_NAME:-}" __saved_meta_name="${AMD_META_NAME:-}" __saved_report_name="${AMD_REPORT_NAME:-}"
  local __saved_allow_name="${AMD_ALLOWLIST_NAME:-}" __saved_allow_default="${AMD_DLL_ALLOWLIST_DEFAULT:-}" __saved_allow="${AMD_DLL_ALLOWLIST:-}"
  local had_nullglob=0
  shopt -q nullglob && had_nullglob=1
  shopt -s nullglob
  local -a dll_candidates=( "$dst_dir"/"${AMD_DLL_STEM}"_v*.dll )
  ((had_nullglob)) || shopt -u nullglob

  local -a versions=()
  local -a remote_entries=()
  local dll bn ver
  for dll in "${dll_candidates[@]}"; do
    [[ -f "$dll" ]] || continue
    bn="$(basename -- "$dll")"
    [[ "$bn" =~ ^${AMD_DLL_STEM}_v([0-9]+\.[0-9]+\.[0-9]+)\.dll$ ]] || continue
    ver="${BASH_REMATCH[1]}"
    if [[ -n "$want_ver" && "$ver" != "$want_ver" ]]; then
      continue
    fi
    versions+=("$ver")
  done

  local remote_dir=""
  if ((trusted_only == 0)); then
    remote_dir="$(amd_remote_cache_dir_from_local_dir "$dst_dir" 2>/dev/null || true)"
    if [[ -n "$remote_dir" && -d "$remote_dir" ]]; then
      shopt -q nullglob && had_nullglob=1
      shopt -s nullglob
      local -a remote_candidates=( "$remote_dir"/"${AMD_DLL_STEM}"_v*.dll )
      ((had_nullglob)) || shopt -u nullglob
      local remote_id=""
      for dll in "${remote_candidates[@]}"; do
        [[ -f "$dll" ]] || continue
        bn="$(basename -- "$dll")"
        [[ "$bn" =~ ^${AMD_DLL_STEM}_v([0-9]+\.[0-9]+\.[0-9]+)_(.+)\.dll$ ]] || continue
        ver="${BASH_REMATCH[1]}"
        remote_id="${BASH_REMATCH[2]}"
        if [[ -n "$want_ver" && "$ver" != "$want_ver" ]]; then
          continue
        fi
        remote_entries+=("${ver}|${dll}|${remote_id}")
      done
    fi
  fi

  if ((${#versions[@]} == 0 && ${#remote_entries[@]} == 0)); then
    if [[ -n "$want_ver" ]]; then
      msg "${I_INFO} No installed versioned DLLs found for FSR4 ${want_ver} in: $dst_dir"
    else
      msg "${I_INFO} No installed versioned DLLs found in: $dst_dir"
    fi
    AMD_DLL_NAME="$__saved_dll_name"
    AMD_META_NAME="$__saved_meta_name"
    AMD_REPORT_NAME="$__saved_report_name"
    AMD_ALLOWLIST_NAME="$__saved_allow_name"
    AMD_DLL_ALLOWLIST_DEFAULT="$__saved_allow_default"
    AMD_DLL_ALLOWLIST="$__saved_allow"
    return 0
  fi

  local listed=0
  local sha_tool=0
  command -v sha256sum >/dev/null 2>&1 && sha_tool=1

  if ((${#versions[@]} > 0)); then
    mapfile -t versions < <(printf '%s\n' "${versions[@]}" | sort -u -V)
    msg "${I_BOX} Installed DLL cache: $dst_dir"
    printf "%-6s %-9s %-6s %-8s %-6s %-64s\n" "VER" "TRUST" "SIZE" "DRIVER" "SOURCE" "SHA256"
  fi

  for ver in "${versions[@]}"; do
    amd_set_cache_names_for_ver "$ver"
    local dll_path="$dst_dir/$AMD_DLL_NAME"
    local meta_path="$dst_dir/$AMD_META_NAME"
    local report_path="$dst_dir/$AMD_REPORT_NAME"
    [[ -f "$dll_path" ]] || continue

    local dll_size=0 dll_sha=""
    dll_size="$(wc -c <"$dll_path" 2>/dev/null || echo 0)"
    if ((sha_tool == 1)); then
      dll_sha="$(sha256sum "$dll_path" 2>/dev/null | awk '{print $1}' || true)"
    fi

    local meta_present=0 meta_match=0 meta_reason="missing_meta"
    local meta_dll_size="" meta_dll_sha="" meta_source_kind="" meta_source_path="" meta_source_url="" meta_installed_at="" meta_driver_label=""
    if [[ -f "$meta_path" ]]; then
      meta_present=1
      meta_reason=""
      meta_dll_size="$(amd_meta_get_value "$meta_path" "CACHE_DLL_SIZE")"
      meta_dll_sha="$(amd_meta_get_value "$meta_path" "CACHE_DLL_SHA256")"
      meta_source_kind="$(amd_meta_get_value "$meta_path" "SOURCE_KIND")"
      meta_source_path="$(amd_meta_get_value "$meta_path" "SOURCE_PATH")"
      meta_source_url="$(amd_meta_get_value "$meta_path" "SOURCE_URL")"
      meta_installed_at="$(amd_meta_get_value "$meta_path" "INSTALLED_AT_UTC")"
      meta_driver_label="$(amd_meta_driver_label_from_file "$meta_path")"

      local fingerprint_match=0 fingerprint_reason=""
      amd_meta_fingerprint_match_status "$meta_dll_sha" "$meta_dll_size" "$dll_sha" "$dll_size" 0 fingerprint_match fingerprint_reason
      local consistency_reason=""
      if ((fingerprint_match == 1)); then
        consistency_reason="$(amd_meta_provenance_consistency_reason "$meta_path" "$dll_path")"
      fi
      if ((fingerprint_match == 1)) && [[ -z "$consistency_reason" ]]; then
        meta_match=1
        meta_reason="ok"
      else
        meta_match=0
        meta_reason="${consistency_reason:-$fingerprint_reason}"
      fi
    fi

    local allow_path="${AMD_DLL_ALLOWLIST}" allow_present=0 allow_match=0 allow_reason=""
    [[ -f "$allow_path" ]] && allow_present=1
    amd_allowlist_match_status "$allow_path" "$dll_sha" "$dll_size" 1 allow_match allow_reason

    local trust_match=0 trust="untrusted" trust_summary="" trust_reason=""
    amd_dll_trust_result_status "$meta_match" "$meta_reason" "$allow_match" "$allow_reason" trust_match trust trust_summary trust_reason
    if ((trusted_only == 1)) && [[ "$trust" != "trusted" ]]; then
      continue
    fi

    listed=1
    local shown_sha="$dll_sha"
    [[ -n "$shown_sha" ]] || shown_sha="(no-sha256)"
    printf "%-6s %-9s %-6s %-8s %-6s %-64s\n" \
      "$ver" \
      "$trust" \
      "$(amd_size_human_short "$dll_size")" \
      "$(amd_driver_display_value "$meta_driver_label" "$meta_source_kind")" \
      "$(amd_source_display_value "$meta_source_kind")" \
      "$shown_sha"
    if ((verbose == 1)); then
      msg "  dll: $dll_path"
      msg "  meta: $meta_path"
      msg "  report: $report_path"
      msg "  source: $(amd_source_display_value "$meta_source_kind")"
      msg "  source_name: $(amd_dll_source_name "$meta_source_path" "$meta_source_url")"
      [[ -n "$meta_source_path" ]] && msg "  source_path: $meta_source_path"
      [[ -n "$meta_source_url" ]] && msg "  source_url: $meta_source_url"
      msg "  allowlist: $allow_path"
      msg "  meta_match: $meta_match ($meta_reason)"
      msg "  allowlist_match: $allow_match ($allow_reason)"
      [[ -n "$meta_installed_at" ]] && msg "  installed_at: $meta_installed_at"
      [[ -n "$dll_sha" ]] && msg "  sha256: $dll_sha"
    fi
  done

  if ((${#remote_entries[@]} > 0)); then
    local remote_seen=0
    local remote_entry="" remote_ver="" remote_path="" remote_id=""
    mapfile -t remote_entries < <(printf '%s\n' "${remote_entries[@]}" | sort -t'|' -k1,1V -k2,2)
    msg "${I_BOX} Shared Proton DLL cache: $remote_dir"
    printf "%-6s %-9s %-6s %-8s %-6s %-64s\n" "VER" "TRUST" "SIZE" "DRIVER" "SOURCE" "SHA256"
    for remote_entry in "${remote_entries[@]}"; do
      remote_ver="${remote_entry%%|*}"
      remote_path="${remote_entry#*|}"
      remote_id="${remote_path##*|}"
      remote_path="${remote_path%|*}"
      [[ -f "$remote_path" ]] || continue

      local remote_size=0 remote_sha="" remote_short_sha=""
      remote_size="$(wc -c <"$remote_path" 2>/dev/null || echo 0)"
      if ((sha_tool == 1)); then
        remote_sha="$(sha256sum "$remote_path" 2>/dev/null | awk '{print $1}' || true)"
      fi
      [[ -n "$remote_sha" ]] || remote_sha="(no-sha256)"

      listed=1
      remote_seen=1
      printf "%-6s %-9s %-6s %-8s %-6s %-64s\n" \
        "$remote_ver" \
        "remote" \
        "$(amd_size_human_short "$remote_size")" \
        "-" \
        "url" \
        "$remote_sha"
      if ((verbose == 1)); then
        msg "  dll: $remote_path"
        msg "  remote_id: $remote_id"
        msg "  managed_by: Proton upscalers.py"
        msg "  delete_policy: protected"
        [[ -n "$remote_sha" ]] && msg "  sha256: $remote_sha"
      fi
    done
    if ((remote_seen == 0)); then
      msg "${I_INFO} No shared Proton cache DLL entries matched the current filters in: $remote_dir"
    fi
  fi

  if ((listed == 0)); then
    if [[ -n "$want_ver" ]]; then
      msg "${I_INFO} No installed DLL entries matched FSR4 ${want_ver} in: $dst_dir"
    else
      msg "${I_INFO} No installed DLL entries matched the current filters in: $dst_dir"
    fi
  fi

  AMD_DLL_NAME="$__saved_dll_name"
  AMD_META_NAME="$__saved_meta_name"
  AMD_REPORT_NAME="$__saved_report_name"
  AMD_ALLOWLIST_NAME="$__saved_allow_name"
  AMD_DLL_ALLOWLIST_DEFAULT="$__saved_allow_default"
  AMD_DLL_ALLOWLIST="$__saved_allow"
}

amd_driver_label_from_source() {
  # derive a label like "26.1.1-win11-b" from the driver filename/url
  # fallback: sanitized basename (truncated)
  local dl="${1:-}" url="${2:-}" name="" ver="" flavor="" label=""

  if [[ -n "$url" ]]; then
    name="$(basename -- "$url" 2>/dev/null || true)"
  else
    name="$(basename -- "$dl" 2>/dev/null || true)"
  fi

  name="${name%.exe}"

  # common amd pattern: "...-26.1.1-win11-b" or "...-25.12.1-win11-a"
  if [[ "$name" =~ ([0-9]{2}\.[0-9]{1,2}\.[0-9]{1,2})(-([A-Za-z0-9._-]+))? ]]; then
    ver="${BASH_REMATCH[1]}"
    flavor="${BASH_REMATCH[3]:-}"
    if [[ -n "$flavor" ]]; then
      label="${ver}-${flavor}"
    else
      label="${ver}"
    fi
    printf '%s\n' "$label"
    return 0
  fi

  # fallback: safe path component
  name="$(printf '%s' "$name" | tr -cd '[:alnum:]._-')"
  name="${name%.[eE][xX][eE]}"
  [[ -n "$name" ]] || name="unknown"
  printf '%s\n' "${name:0:48}"
}

# meta file check: old v1 meta that lacks the extra provenance keys
amd_meta_needs_upgrade_v1() {
  local meta_file="${1:-}"
  [[ -f "$meta_file" ]] || return 1

  local ver=""
  ver="$(grep -E '^META_FORMAT_VERSION=' "$meta_file" 2>/dev/null | head -n1 | cut -d= -f2- || true)"
  ver="${ver//$'\r'/}"
  ver="${ver//[[:space:]]/}"
  if [[ -n "$ver" && "$ver" != "1" ]]; then
    # newer/unknown format
    return 1
  fi

  # old v1 meta had only DRIVER_* / SOURCE_URL / CACHE_DLL* keys
  # these are the extra keys we want present
  local k=""
  for k in SOURCE_KIND SOURCE_PATH SOURCE_SHA256 EXTRACT_METHOD EXTRACTED_FROM EXTRACTED_FILE INTENDED_CACHE_PATH KERNEL OS FSR4_INSTALLED_VER FSR4_INSTALLED_VER_SOURCE; do
    if ! grep -qE "^${k}=" "$meta_file" 2>/dev/null; then
      return 0
    fi
  done

  # deprecated advisory-only fields are stripped on upgrade so meta stays grounded
  # in installed-version truth only.
  if grep -qE '^FSR4_DRIVER_HINT_MAX_VER=' "$meta_file" 2>/dev/null; then
    return 0
  fi
  if grep -qE '^FSR4_DRIVER_HINT_SOURCE=' "$meta_file" 2>/dev/null; then
    return 0
  fi
  local retired_k1="FSR4_MAX""_KNOWN"
  local retired_k2="FSR4_MAX""_KNOWN_SOURCE"
  if grep -qE "^${retired_k1}=" "$meta_file" 2>/dev/null; then
    return 0
  fi
  if grep -qE "^${retired_k2}=" "$meta_file" 2>/dev/null; then
    return 0
  fi
  if grep -qE '^CACHE_DLL_MD5=' "$meta_file" 2>/dev/null; then
    return 0
  fi

  return 1
}

# meta file upgrade: add missing provenance keys to an existing v1 meta file
# args: meta path, installed dll path, driver label, exe path (may be empty), url (may be empty), exdir (may be empty)
amd_meta_upgrade_v1() {
  local meta="${1:-}" expected="${2:-}" drv_label="${3:-}" dl="${4:-}" url="${5:-}" exdir="${6:-}"
  [[ -f "$meta" && -f "$expected" && -n "$drv_label" ]] || return 0

  validate_amd_cache_names

  if ! amd_meta_needs_upgrade_v1 "$meta"; then
    return 0
  fi

  # fingerprints from the installed dll
  have sha256sum || return 0

  local dll_sha="" dll_size=""
  dll_sha="$(sha256sum "$expected" 2>/dev/null | awk '{print $1}' || true)"
  [[ -n "$dll_sha" ]] || return 0

  dll_size="$(stat -c %s "$expected" 2>/dev/null || true)"
  [[ "$dll_size" =~ ^[0-9]+$ && "$dll_size" -gt 0 ]] || return 0

  # split label into version + flavor (same rule as install path)
  local drv_version="${drv_label%%-*}"
  local drv_flavor="${drv_label#"${drv_version}"}"
  drv_flavor="${drv_flavor#-}"

  # provenance keys
  local source_kind="exe" source_path="$dl" source_sha=""

  # if dl/exdir are missing, pull them from the adjacent report file when present
  local report_file=""
  report_file="${meta%.meta.txt}.report.txt"
  if [[ "$report_file" == "$meta" ]]; then
    report_file="${meta}.report.txt"
  fi

  local rep_kind="" rep_path="" rep_exdir="" rep_picked=""
  if [[ -f "$report_file" ]]; then
    rep_kind="$(sed -nE 's/^source_kind:[[:space:]]*//p' "$report_file" 2>/dev/null | head -n1 || true)"
    rep_path="$(sed -nE 's/^source_path:[[:space:]]*//p' "$report_file" 2>/dev/null | head -n1 || true)"
    rep_exdir="$(sed -nE 's/^extracted_dir:[[:space:]]*//p' "$report_file" 2>/dev/null | head -n1 || true)"
    rep_picked="$(sed -nE 's/^picked:[[:space:]]*//p' "$report_file" 2>/dev/null | head -n1 || true)"
    if declare -F kv_norm >/dev/null 2>&1; then
      rep_kind="$(kv_norm "$rep_kind")"
      rep_path="$(kv_norm "$rep_path")"
      rep_exdir="$(kv_norm "$rep_exdir")"
      rep_picked="$(kv_norm "$rep_picked")"
    fi
    [[ -n "$rep_kind" ]] && source_kind="$rep_kind"
    if [[ -z "${dl:-}" && -n "$rep_path" ]]; then
      dl="$rep_path"
      source_path="$rep_path"
    fi
    if [[ -z "${exdir:-}" && -n "$rep_exdir" ]]; then
      exdir="$rep_exdir"
    fi
  fi

  if [[ -n "$url" && -z "${dl:-}" ]]; then
    source_kind="url"
  fi

  if have sha256sum && [[ -n "${dl:-}" && -r "$dl" ]]; then
    source_sha="$(sha256sum "$dl" 2>/dev/null | awk '{print $1}' || true)"
  fi

  local extracted_file=""
  if [[ -n "${exdir:-}" && -d "$exdir" ]]; then
    extracted_file="$(find "$exdir" -type f -name "${AMD_DLL_SRC_NAME}" -print -quit 2>/dev/null || true)"
  fi
  if [[ -z "$extracted_file" && -n "$rep_picked" ]]; then
    extracted_file="$rep_picked"
  fi

  local extract_method="7z"
  local extracted_from="$dl"

  # keep source_url from meta unless url arg is set
  local src_url=""
  src_url="$(grep -E '^SOURCE_URL=' "$meta" 2>/dev/null | head -n1 | cut -d= -f2- || true)"
  if [[ -n "$url" ]]; then
    src_url="$url"
  fi

  if [[ -z "$extracted_from" && -n "$src_url" ]]; then
    extracted_from="$src_url"
  fi

  local intended_cache="$expected"
  local kernel_info="" os_info=""
  kernel_info="$(uname -r 2>/dev/null || true)"
  os_info="$(uname -srmo 2>/dev/null || uname -a 2>/dev/null || true)"

  # keep installed timestamp if present
  local installed_at=""
  installed_at="$(grep -E '^INSTALLED_AT_UTC=' "$meta" 2>/dev/null | head -n1 | cut -d= -f2- || true)"
  if [[ -z "$installed_at" ]]; then
    installed_at="$(date -u +'%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || true)"
  fi

  local installed_ver="" installed_ver_source=""
  installed_ver="$(fsr4_version_from_versioned_cache_name "$expected" 2>/dev/null || true)"
  if [[ -n "$installed_ver" ]]; then
    installed_ver_source="cache_filename"
  fi

  # write new meta to a temp file, then rename into place
  local meta_tmp=""
  meta_tmp="$(mktemp "${meta}.tmp.XXXXXX" 2>/dev/null || true)"
  [[ -n "$meta_tmp" ]] || return 0

  if ! {
    echo "META_FORMAT_VERSION=1"
    echo "DRIVER_LABEL=$drv_label"
    echo "DRIVER_VERSION=$drv_version"
    echo "DRIVER_FLAVOR=$drv_flavor"
    [[ -n "$installed_ver" ]] && echo "FSR4_INSTALLED_VER=$installed_ver" || echo "FSR4_INSTALLED_VER="
    echo "FSR4_INSTALLED_VER_SOURCE=$installed_ver_source"
    [[ -n "$src_url" ]] && echo "SOURCE_URL=$src_url" || echo "SOURCE_URL="
    echo "SOURCE_KIND=$source_kind"
    echo "SOURCE_PATH=$source_path"
    echo "SOURCE_SHA256=$source_sha"
    echo "EXTRACT_METHOD=$extract_method"
    echo "EXTRACTED_FROM=$extracted_from"
    echo "EXTRACTED_FILE=$extracted_file"
    echo "INTENDED_CACHE_PATH=$intended_cache"
    echo "KERNEL=$kernel_info"
    echo "OS=$os_info"
    echo "CACHE_DLL=$expected"
    echo "CACHE_DLL_SHA256=$dll_sha"
    echo "CACHE_DLL_SIZE=$dll_size"
    echo "INSTALLED_AT_UTC=$installed_at"
  } >"$meta_tmp" 2>/dev/null; then
    rm -f -- "$meta_tmp" 2>/dev/null || true
    return 0
  fi

  if ! mv -f -- "$meta_tmp" "$meta" 2>/dev/null; then
    rm -f -- "$meta_tmp" 2>/dev/null || true
    return 0
  fi

  msg "${I_INFO} Upgraded provenance meta (v1 additive keys): $meta"
  return 0
}

_amd_dll_extract_pick_copy() {
  local dl="$1" url="$2" dst_dir="$3" keep="$4"
  local requested_ver="${5:-$FSR4_LOCAL_DEFAULT_VER}"
  local ver_explicit="${6:-1}"
  local trust_local="${7:-0}"
  local resolved_ver="" resolved_ver_source=""
  local confirmed_ver="" confirmed_ver_source=""
  local expected_install_ver="" dev_override_ver=""
  local marker_requested_ver=""
  : "${requested_ver}" "${ver_explicit}"

  validate_amd_cache_names
  mkdir -p -- "$dst_dir" "$AMD_EXTRACT_ROOT" >/dev/null 2>&1 || true
  if [[ -n "${GENVW_INSTALL_EXPECT_VER:-}" ]]; then
    expected_install_ver="$(fsr4_hidden_install_expect_ver)"
  fi
  if [[ -n "${GENVW_DEV_DLL_INSTALL_VER:-}" ]]; then
    dev_override_ver="$(fsr4_hidden_install_dev_override_ver)"
  fi
  if [[ -n "$expected_install_ver" ]]; then
    marker_requested_ver="$expected_install_ver"
  elif [[ "$ver_explicit" == "1" && -n "$requested_ver" ]]; then
    marker_requested_ver="$requested_ver"
  fi

  local drv_label=""
  local exdir=""

  local _cleanup_exdir=1
  if [[ "${keep:-0}" == "1" ]]; then
    _cleanup_exdir=0
  fi

  # traps can run after locals are gone; under `set -u` that can trip unbound vars.
  # stash what the trap needs in globals.
  declare -g __GENVW_EXDIR="${exdir}"
  declare -g __GENVW_EXDIR_CLEANUP="${_cleanup_exdir}"
  local __old_trap_exit="" __old_trap_int="" __old_trap_term=""
  __old_trap_exit="$(trap -p EXIT 2>/dev/null || true)"
  __old_trap_int="$(trap -p INT 2>/dev/null || true)"
  __old_trap_term="$(trap -p TERM 2>/dev/null || true)"

  # exit on ctrl-c / sigterm after cleanup (130/143).
  trap 'amd_cleanup_extract_dir' EXIT
  trap 'amd_cleanup_extract_dir; exit 130' INT
  trap 'amd_cleanup_extract_dir; exit 143' TERM

  local cands=()
  local picked="" reuseExtracted="0"
  amd_dll_extract_pick_prepare "$dl" "$url" "$keep" "$requested_ver" "$ver_explicit" picked exdir drv_label reuseExtracted cands
  local plan_source_kind="exe"
  local plan_source_ref="$dl"
  if [[ -n "$url" ]]; then
    plan_source_kind="url"
    plan_source_ref="$url"
  fi

  if [[ -n "$dev_override_ver" ]]; then
    resolved_ver="$dev_override_ver"
    resolved_ver_source="dev_override"
    info "dll install: using hidden dev version override ${resolved_ver}."
  else
    # resolve the install target before naming cache/meta/allowlist files.
    if ! fsr4_resolve_install_ver_from_dll_markers "$picked" "$plan_source_kind" "$plan_source_ref" "$marker_requested_ver" "$ver_explicit" "$trust_local" 0 resolved_ver; then
      restore_one_trap "$__old_trap_exit" EXIT
      restore_one_trap "$__old_trap_int" INT
      restore_one_trap "$__old_trap_term" TERM
      amd_cleanup_extract_dir
      return 1
    fi
    resolved_ver_source="source_dll_scan"
    if [[ "${GENVW_INSTALL_APPROVED_AMBIGUOUS_MARKERS:-0}" == "1" ]]; then
      info "dll install: approved FSR4 ${resolved_ver} from selected DLL markers."
    else
      info "dll install: auto-detected FSR4 ${resolved_ver} from extracted DLL."
    fi
  fi
  if ! fsr4_enforce_expected_install_ver "$resolved_ver" "$expected_install_ver" "dll install"; then
    restore_one_trap "$__old_trap_exit" EXIT
    restore_one_trap "$__old_trap_int" INT
    restore_one_trap "$__old_trap_term" TERM
    amd_cleanup_extract_dir
    return 1
  fi
  amd_set_cache_names_for_ver "$resolved_ver"
  validate_amd_cache_names

  local expected="$dst_dir/${AMD_DLL_NAME}"
  local meta="$dst_dir/${AMD_META_NAME}"
  local report="$dst_dir/${AMD_REPORT_NAME}"

  # candidate scoring diagnostics (mirrors amd_pick_best_dll_candidate heuristics).
  # if any candidate is "real-sized" (>= 10 MiB), smaller ones get ignored.
  local minBytes=10485760 # 10 MiB
  local anyBig=0
  for f in "${cands[@]}"; do
    local sz=0
    sz="$(stat -c %s "$f" 2>/dev/null || echo 0)"
    ((sz >= minBytes)) && anyBig=1
  done

  # report provenance: what source we used
  local sourceExePath="${dl:-}"
  if [[ -z "$sourceExePath" && -n "${GENVW_AMD_LAST_DL:-}" && -f "$GENVW_AMD_LAST_DL" ]]; then
    sourceExePath="$GENVW_AMD_LAST_DL"
  fi

  local sourceKind="exe"
  local sourcePath="$sourceExePath"
  if [[ -z "$sourcePath" ]]; then
    # no local exe path; record the url instead
    sourceKind="url"
    sourcePath="${url:-}"
  fi

  local overwrite_prompted=0
  amd_dll_same_ver_overwrite_guard \
    "$dst_dir" \
    "$picked" \
    "" \
    "$resolved_ver" \
    "$drv_label" \
    "$sourceKind" \
    "$sourcePath" \
    "$url" \
    "" \
    "${GENVW_ASSUME_YES:-0}" \
    "dll install" \
    overwrite_prompted

  {
    echo "driver_label: $drv_label"
    echo "extracted_dir: $exdir"
    echo "reuse_extracted: ${reuseExtracted:-0}"
    echo "source_kind: $sourceKind"
    echo "source_path: $sourcePath"
    echo "candidates: ${#cands[@]}"
    echo "pick_policy: option3"
    echo "size_floor_bytes: $minBytes"
    echo "size_floor_enabled: $anyBig"
    for f in "${cands[@]}"; do
      # version string hint (strings output)
      local pv=""
      local sz=0 score=0 eligible=1 flags=""
      pv="$(strings "$f" 2>/dev/null | grep -m1 -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true)"
      sz="$(stat -c %s "$f" 2>/dev/null || echo 0)"

      [[ "$f" == *"/Packages/Drivers/Display/"* ]] && score=$((score + 200)) && flags="${flags}packages_drivers_display "
      [[ "$f" == *"/Packages/Drivers/"* ]] && score=$((score + 40)) && flags="${flags}packages_drivers "
      [[ "$f" == *"/WT6A_INF/"* ]] && score=$((score + 25)) && flags="${flags}wt6a_inf "
      [[ "$f" == *"/Display/"* ]] && score=$((score + 10)) && flags="${flags}display "

      if ((anyBig == 1 && sz < minBytes)); then
        eligible=0
        flags="${flags}ignored_by_size_floor "
      fi

      # size adds a tiny tie-break
      score=$((score + (sz / 1048576))) # +1 per MiB

      echo "  - file: $f"
      [[ -n "$pv" ]] && echo "    product_version: $pv"
      echo "    size: $sz"
      echo "    sha256: $(sha256sum "$f" 2>/dev/null | awk '{print $1}' || true)"
      echo "    eligible: $eligible"
      echo "    score: $score"
      [[ -n "$flags" ]] && echo "    score_flags: ${flags% }"
    done
  } >"$report" 2>/dev/null || true

  ok "Wrote report: $report"

  # append pick summary to the report (shows why it won)

  {
    local pickedSize=0 pickedScore=0 pickedEligible=1 pickedFlags=""
    pickedSize="$(stat -c %s "$picked" 2>/dev/null || echo 0)"

    [[ "$picked" == *"/Packages/Drivers/Display/"* ]] && pickedScore=$((pickedScore + 200)) && pickedFlags="${pickedFlags}packages_drivers_display "
    [[ "$picked" == *"/Packages/Drivers/"* ]] && pickedScore=$((pickedScore + 40)) && pickedFlags="${pickedFlags}packages_drivers "
    [[ "$picked" == *"/WT6A_INF/"* ]] && pickedScore=$((pickedScore + 25)) && pickedFlags="${pickedFlags}wt6a_inf "
    [[ "$picked" == *"/Display/"* ]] && pickedScore=$((pickedScore + 10)) && pickedFlags="${pickedFlags}display "

    if ((anyBig == 1 && pickedSize < minBytes)); then
      pickedEligible=0
      pickedFlags="${pickedFlags}ignored_by_size_floor "
    fi

    pickedScore=$((pickedScore + (pickedSize / 1048576))) # +1 per MiB

    echo "picked: $picked"
    echo "picked_size: $pickedSize"
    echo "picked_eligible: $pickedEligible"
    echo "picked_score: $pickedScore"
    [[ -n "$pickedFlags" ]] && echo "picked_score_flags: ${pickedFlags% }"
  } >>"$report" 2>/dev/null || true

  # copy into stable cache location
  msg "${I_ARROW} Copying to:"
  msg "  $expected"
  cp -f -- "$picked" "$expected" || die "Could not copy extracted DLL into cache path: $expected"

  if [[ -n "$dev_override_ver" ]]; then
    confirmed_ver="$resolved_ver"
    confirmed_ver_source="dev_override"
  else
    if ! fsr4_confirm_installed_content_for_ver "$picked" "$expected" "$resolved_ver" "${GENVW_INSTALL_APPROVED_AMBIGUOUS_MARKERS:-0}" "dll install" confirmed_ver; then
      rm -f -- "$expected" "$report" 2>/dev/null || true
      restore_one_trap "$__old_trap_exit" EXIT
      restore_one_trap "$__old_trap_int" INT
      restore_one_trap "$__old_trap_term" TERM
      amd_cleanup_extract_dir
      return 1
    fi
    confirmed_ver_source="installed_dll_scan"
    if [[ "$confirmed_ver" != "$resolved_ver" ]]; then
      rm -f -- "$expected" "$report" 2>/dev/null || true
      err "dll install: installed DLL content resolved to FSR4 ${confirmed_ver}, but pre-copy detection resolved to ${resolved_ver}."
      restore_one_trap "$__old_trap_exit" EXIT
      restore_one_trap "$__old_trap_int" INT
      restore_one_trap "$__old_trap_term" TERM
      amd_cleanup_extract_dir
      return 1
    fi
  fi

  # meta/provenance
  local drv_version="${drv_label%%-*}"
  local drv_flavor="${drv_label#"${drv_version}"}"
  drv_flavor="${drv_flavor#-}"
  # compute fingerprints first (keeps the meta write simple)
  local dll_sha="" dll_size=""
  dll_sha="$(sha256sum "$expected" 2>/dev/null || true)"
  dll_sha="${dll_sha%% *}"
  [[ -n "$dll_sha" ]] || die "Could not compute sha256 for installed DLL: $expected"

  dll_size="$(stat -c %s "$expected" 2>/dev/null || true)"
  [[ "$dll_size" =~ ^[0-9]+$ && "$dll_size" -gt 0 ]] || die "Could not compute size for installed DLL: $expected"

  # write meta via temp file + rename (avoids partial writes on interrupt)
  # extra provenance keys used by `check --kv`
  local meta_source_kind="$sourceKind"
  local meta_source_path="$sourcePath"
  local meta_source_sha=""
  if have sha256sum && [[ -n "$meta_source_path" && -f "$meta_source_path" ]]; then
    meta_source_sha="$(sha256sum "$meta_source_path" 2>/dev/null | awk '{print $1}' || true)"
  fi

  local meta_extract_method="${GENVW_AMD_LAST_EXTRACT_METHOD:-7z}"
  local meta_extracted_from="$meta_source_path"
  local meta_extracted_file="$picked"
  local meta_kernel="" meta_os=""
  meta_kernel="$(uname -r 2>/dev/null || true)"
  meta_os="$(uname -srmo 2>/dev/null || uname -a 2>/dev/null || true)"

  local meta_tmp=""
  meta_tmp="$(mktemp "${meta}.tmp.XXXXXX")" || die "Could not create temp provenance file for: $meta"
  {
    echo "META_FORMAT_VERSION=1"
    echo "DRIVER_LABEL=$drv_label"
    echo "DRIVER_VERSION=$drv_version"
    echo "DRIVER_FLAVOR=$drv_flavor"
    echo "FSR4_INSTALLED_VER=$confirmed_ver"
    echo "FSR4_INSTALLED_VER_SOURCE=$confirmed_ver_source"
    [[ -n "$url" ]] && echo "SOURCE_URL=$url" || echo "SOURCE_URL="
    echo "SOURCE_KIND=$meta_source_kind"
    echo "SOURCE_PATH=$meta_source_path"
    echo "SOURCE_SHA256=$meta_source_sha"
    echo "EXTRACT_METHOD=$meta_extract_method"
    echo "EXTRACTED_FROM=$meta_extracted_from"
    echo "EXTRACTED_FILE=$meta_extracted_file"
    echo "INTENDED_CACHE_PATH=$expected"
    echo "KERNEL=$meta_kernel"
    echo "OS=$meta_os"
    echo "CACHE_DLL=$expected"
    echo "CACHE_DLL_SHA256=$dll_sha"
    echo "CACHE_DLL_SIZE=$dll_size"
    echo "INSTALLED_AT_UTC=$(date -u +'%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || true)"
  } >"$meta_tmp"
  if ! mv -f -- "$meta_tmp" "$meta"; then
    rm -f -- "$meta_tmp" 2>/dev/null || true
    die "Could not write provenance meta: $meta"
  fi

  {
    echo "resolved_ver: $resolved_ver"
    echo "resolved_ver_source: $resolved_ver_source"
    echo "installed_ver: $confirmed_ver"
    echo "installed_ver_source: $confirmed_ver_source"
  } >>"$report" 2>/dev/null || true

  ok "Wrote provenance: $meta"
  ok "Installed: $expected"
  amd_record_last_installed_ver "$confirmed_ver" "$confirmed_ver_source"

  msg "${I_BROOM} Clean it later with:"
  msg "  $(cmd_dll) tidy"
  msg "  $(cmd_dll) tidy --driver-label \"${drv_label}\""

  # restore caller trap handlers (important for sourced/direct-function use).
  restore_one_trap "$__old_trap_exit" EXIT
  restore_one_trap "$__old_trap_int" INT
  restore_one_trap "$__old_trap_term" TERM
  amd_cleanup_extract_dir
  return 0
}

amd_dll_install_from_local_dll() {
  # direct local DLL install path:
  # - no driver EXE download/extract
  # - copy a user-provided DLL into the versioned cache path
  # - write provenance/report sidecars so check/verify/prep keep a stable contract
  local src_dll="${1:-}"
  local dst_dir="${2:-$DLL_DST_DIR_DEFAULT}"
  local fsr4_ver="${3:-$FSR4_LOCAL_DEFAULT_VER}"
  local fsr4_ver_source="${4:-source_dll_scan}"
  local approved_ambiguous="${5:-0}"
  local confirmed_ver="" confirmed_ver_source=""
  local src_size=0

  validate_amd_cache_names
  amd_validate_local_dll_source_for_install "$src_dll"
  src_size="$(stat -c %s "$src_dll" 2>/dev/null || echo 0)"

  mkdir -p -- "$dst_dir" >/dev/null 2>&1 || true

  local expected="$dst_dir/${AMD_DLL_NAME}"
  local drv_label="local-dll-${fsr4_ver}"
  local overwrite_prompted=0
  amd_dll_same_ver_overwrite_guard \
    "$dst_dir" \
    "$src_dll" \
    "" \
    "$fsr4_ver" \
    "$drv_label" \
    "dll" \
    "$src_dll" \
    "" \
    "" \
    "${GENVW_ASSUME_YES:-0}" \
    "dll install" \
    overwrite_prompted

  cp -f -- "$src_dll" "$expected" || die "Could not copy --dll into cache path: $expected"

  if [[ "$fsr4_ver_source" == "dev_override" ]]; then
    confirmed_ver="$fsr4_ver"
    confirmed_ver_source="dev_override"
  else
    if ! fsr4_confirm_installed_content_for_ver "$src_dll" "$expected" "$fsr4_ver" "$approved_ambiguous" "dll install" confirmed_ver; then
      rm -f -- "$expected" 2>/dev/null || true
      return 1
    fi
    confirmed_ver_source="installed_dll_scan"
    if [[ "$confirmed_ver" != "$fsr4_ver" ]]; then
      rm -f -- "$expected" 2>/dev/null || true
      err "dll install: installed DLL content resolved to FSR4 ${confirmed_ver}, but pre-copy detection resolved to ${fsr4_ver}."
      return 1
    fi
  fi

  local dll_sha="" dll_size=0 source_sha=""
  dll_sha="$(sha256sum "$expected" 2>/dev/null | awk '{print $1}' || true)"
  [[ -n "$dll_sha" ]] || die "Could not compute sha256 for installed DLL: $expected"

  dll_size="$(stat -c %s "$expected" 2>/dev/null || echo 0)"
  [[ "$dll_size" =~ ^[0-9]+$ && "$dll_size" -gt 0 ]] || die "Could not compute size for installed DLL: $expected"

  source_sha="$(sha256sum "$src_dll" 2>/dev/null | awk '{print $1}' || true)"
  [[ -n "$source_sha" ]] || die "Could not compute sha256 for --dll source: $src_dll"

  local meta="$dst_dir/${AMD_META_NAME}"
  local report="$dst_dir/${AMD_REPORT_NAME}"
  local meta_kernel="" meta_os=""
  meta_kernel="$(uname -r 2>/dev/null || true)"
  meta_os="$(uname -srmo 2>/dev/null || uname -a 2>/dev/null || true)"

  local meta_tmp=""
  meta_tmp="$(mktemp "${meta}.tmp.XXXXXX")" || die "Could not create temp provenance file for: $meta"
  {
    echo "META_FORMAT_VERSION=1"
    echo "DRIVER_LABEL=$drv_label"
    echo "DRIVER_VERSION=$confirmed_ver"
    echo "DRIVER_FLAVOR=local-dll"
    echo "FSR4_INSTALLED_VER=$confirmed_ver"
    echo "FSR4_INSTALLED_VER_SOURCE=$confirmed_ver_source"
    echo "SOURCE_URL="
    echo "SOURCE_KIND=dll"
    echo "SOURCE_PATH=$src_dll"
    echo "SOURCE_SHA256=$source_sha"
    echo "EXTRACT_METHOD=direct-copy"
    echo "EXTRACTED_FROM=$src_dll"
    echo "EXTRACTED_FILE=$src_dll"
    echo "INTENDED_CACHE_PATH=$expected"
    echo "KERNEL=$meta_kernel"
    echo "OS=$meta_os"
    echo "CACHE_DLL=$expected"
    echo "CACHE_DLL_SHA256=$dll_sha"
    echo "CACHE_DLL_SIZE=$dll_size"
    echo "INSTALLED_AT_UTC=$(date -u +'%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || true)"
  } >"$meta_tmp"
  if ! mv -f -- "$meta_tmp" "$meta"; then
    rm -f -- "$meta_tmp" 2>/dev/null || true
    die "Could not write provenance meta: $meta"
  fi

  {
    echo "driver_label: $drv_label"
    echo "source_kind: dll"
    echo "source_path: $src_dll"
    echo "source_sha256: $source_sha"
    echo "candidates: 1"
    echo "pick_policy: direct_copy"
    echo "  - file: $src_dll"
    echo "    size: $src_size"
    echo "    sha256: $source_sha"
    echo "    eligible: 1"
    echo "    score: 0"
    echo "    score_flags: direct_copy"
    echo "picked: $src_dll"
    echo "picked_size: $dll_size"
    echo "picked_eligible: 1"
    echo "picked_score: 0"
    echo "picked_score_flags: direct_copy"
    echo "resolved_ver: $fsr4_ver"
    echo "resolved_ver_source: $fsr4_ver_source"
    echo "installed_ver: $confirmed_ver"
    echo "installed_ver_source: $confirmed_ver_source"
  } >"$report" 2>/dev/null || true

  ok "Installed from local DLL: $src_dll"
  ok "Installed: $expected"
  ok "Wrote provenance: $meta"
  ok "Wrote report: $report"
  amd_record_last_installed_ver "$confirmed_ver" "$confirmed_ver_source"
}

amd_dll_install_trusted_version() {
  local fsr4_ver="${1:-$FSR4_LOCAL_DEFAULT_VER}"
  local dst_dir="${2:-$DLL_DST_DIR_DEFAULT}"
  local url="" want_sha="" want_size="" expected="" meta="" report="" allow=""
  local downloaded=0 dll_sha="" dll_size="" kernel="" os_name="" source_state="cached_valid"

  fsr4_require_local_write_supported_ver "$fsr4_ver" "dll install"
  fsr4_trusted_source_exists "$fsr4_ver" || die "dll install: no trusted source metadata for FSR4 ${fsr4_ver}"
  amd_set_cache_names_for_ver "$fsr4_ver"
  validate_amd_cache_names
  mkdir -p -- "$dst_dir" >/dev/null 2>&1 || true

  url="$(fsr4_trusted_source_lookup "$fsr4_ver" url)"
  want_sha="$(fsr4_trusted_source_lookup "$fsr4_ver" sha256)"
  want_size="$(fsr4_trusted_source_lookup "$fsr4_ver" size)"
  expected="$dst_dir/${AMD_DLL_NAME}"
  meta="$dst_dir/${AMD_META_NAME}"
  report="$dst_dir/${AMD_REPORT_NAME}"
  allow="${AMD_DLL_ALLOWLIST}"

  if ! fsr4_trusted_validate_file "$expected" "$fsr4_ver"; then
    local tmp_dll=""
    tmp_dll="$(mktemp "${expected}.tmp.XXXXXX")" || die "Could not create temp download path for: $expected"
    fsr4_trusted_download_to_file "$url" "$tmp_dll"
    fsr4_trusted_validate_file "$tmp_dll" "$fsr4_ver" || {
      rm -f -- "$tmp_dll" 2>/dev/null || true
      die "Trusted version download failed validation for FSR4 ${fsr4_ver}"
    }
    mv -f -- "$tmp_dll" "$expected" || {
      rm -f -- "$tmp_dll" 2>/dev/null || true
      die "Could not install trusted version into cache path: $expected"
    }
    downloaded=1
    source_state="downloaded"
  fi

  fsr4_trusted_validate_file "$expected" "$fsr4_ver" || die "Trusted cache validation failed for: $expected"
  dll_sha="$(sha256sum "$expected" 2>/dev/null | awk '{print $1}' || true)"
  [[ -n "$dll_sha" ]] || die "Could not compute sha256 for installed DLL: $expected"
  dll_size="$(stat -c %s "$expected" 2>/dev/null || true)"
  [[ "$dll_size" =~ ^[0-9]+$ && "$dll_size" -gt 0 ]] || die "Could not compute size for installed DLL: $expected"
  [[ "${dll_sha,,}" == "${want_sha,,}" && "$dll_size" == "$want_size" ]] || die "Trusted install drifted from canonical metadata for FSR4 ${fsr4_ver}"
  fsr4_trusted_allowlist_ensure_entry "$fsr4_ver" "$dll_sha" "$dll_size"

  kernel="$(uname -r 2>/dev/null || true)"
  os_name="$(uname -srmo 2>/dev/null || uname -a 2>/dev/null || true)"

  local meta_tmp=""
  meta_tmp="$(mktemp "${meta}.tmp.XXXXXX")" || die "Could not create temp provenance file for: $meta"
  {
    echo "META_FORMAT_VERSION=1"
    echo "DRIVER_LABEL=trusted-fsr4-${fsr4_ver}"
    echo "DRIVER_VERSION=$fsr4_ver"
    echo "DRIVER_FLAVOR=trusted-version"
    echo "FSR4_INSTALLED_VER=$fsr4_ver"
    echo "FSR4_INSTALLED_VER_SOURCE=trusted_version_map"
    echo "SOURCE_URL=$url"
    echo "SOURCE_KIND=trusted-version"
    echo "SOURCE_PATH="
    echo "SOURCE_SHA256=$want_sha"
    echo "EXTRACT_METHOD=direct-download"
    echo "EXTRACTED_FROM=$url"
    echo "EXTRACTED_FILE=$expected"
    echo "INTENDED_CACHE_PATH=$expected"
    echo "KERNEL=$kernel"
    echo "OS=$os_name"
    echo "CACHE_DLL=$expected"
    echo "CACHE_DLL_SHA256=$dll_sha"
    echo "CACHE_DLL_SIZE=$dll_size"
    echo "TRUSTED_SOURCE_URL=$url"
    echo "TRUSTED_SOURCE_SHA256=$want_sha"
    echo "TRUSTED_SOURCE_SIZE=$want_size"
    echo "GENVW_FSR4_SOURCE_STATE=$source_state"
    echo "INSTALLED_AT_UTC=$(date -u +'%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || true)"
  } >"$meta_tmp"
  if ! mv -f -- "$meta_tmp" "$meta"; then
    rm -f -- "$meta_tmp" 2>/dev/null || true
    die "Could not write provenance meta: $meta"
  fi

  {
    echo "source_kind: trusted-version"
    echo "source_url: $url"
    echo "resolved_ver: $fsr4_ver"
    echo "resolved_ver_source: explicit_ver"
    echo "installed_ver: $fsr4_ver"
    echo "installed_ver_source: trusted_version_map"
    echo "trusted_sha256: $want_sha"
    echo "trusted_size: $want_size"
    echo "cache_state: $source_state"
    echo "allowlist: $allow"
  } >"$report" 2>/dev/null || true

  if ((downloaded == 1)); then
    ok "Downloaded trusted FSR4 ${fsr4_ver}"
  else
    ok "Reused trusted FSR4 ${fsr4_ver} from cache: $expected"
  fi
  ok "Installed: $expected"
  ok "Wrote provenance: $meta"
  ok "Wrote report: $report"
  ok "Allowlisted: $allow"
  amd_record_last_installed_ver "$fsr4_ver" "trusted_version_map"
}

# amd_dll_install_from_source
# download/extract path for driver exe (trust boundary)

amd_dll_install_from_source() {
  # args: url exe dst_dir keep force_url fsr4_ver ver_explicit trust_local
  local url="${1:-}" exe="${2:-}" dst_dir="${3:-$DLL_DST_DIR_DEFAULT}" keep="${4:-0}" force_url="${5:-0}"
  local fsr4_ver="${6:-$FSR4_LOCAL_DEFAULT_VER}" ver_explicit="${7:-1}"
  local trust_local="${8:-0}"

  # tracks whether we downloaded the file (so we don't delete user-provided --exe)
  local downloaded=0

  # url allowlist behavior:
  # - allowlisted url: normal path
  # - not allowlisted: require --force-url, then ask for confirmation (unless GENVW_ASSUME_YES=1)
  if [[ -n "$url" ]]; then
    amd_dll_validate_url_for_install "$url" "$force_url"
    GENVW_DLL_NEEDS_WGET=1
  else
    GENVW_DLL_NEEDS_WGET=0
  fi

  amd_dll_prereq_check || return 1
  mkdir -p -- "$AMD_DRIVER_DL_DIR" "$dst_dir" >/dev/null 2>&1 || true

  local dl=""
  if [[ -n "$exe" ]]; then
    [[ -f "$exe" ]] || die "Missing driver exe: $exe"
    dl="$exe"
  else
    [[ -n "$url" ]] || die "dll install needs either --url or --exe"
    amd_dll_resolve_url_driver_exe "$url" dl downloaded
  fi

  # validate download looks like a windows pe exe (starts with "mz")
  amd_dll_validate_driver_exe_after_resolve "$dl" "$url" "$downloaded"

  validate_7z_archive_listing "$dl"
  _amd_dll_extract_pick_copy "$dl" "$url" "$dst_dir" "$keep" "$fsr4_ver" "$ver_explicit" "$trust_local"
}

validate_driver_label() {
  local drv="${1:-}"
  [[ -n "$drv" ]] || die "--drv requires a value"

  # keep this a plain label: no separators, no traversal
  [[ "$drv" != *"/"* ]] || die "Invalid --drv label (must not contain '/'): $drv"
  [[ "$drv" != *".."* ]] || die "Invalid --drv label (must not contain '..'): $drv"

  # simple charset so it maps cleanly to a folder name
  [[ "$drv" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "Invalid --drv label: $drv"
}

amd_dll_clean_extracted_driver_label() {
  local drv="${1:-}" dst_dir="${2:-$DLL_DST_DIR_DEFAULT}"
  [[ -n "$drv" ]] || die "--driver-label requires a value"
  validate_driver_label "$drv"
  local out_dir="$AMD_EXTRACT_ROOT/$drv"
  amd_dll_clean_extracted "$out_dir" "$dst_dir"
}

amd_dll_inspect_local_dll() {
  local src_dll="${1:-}" requested_ver="${2:-}"
  require_file "$src_dll" "--dll"
  [[ -r "$src_dll" ]] || die "dll inspect: --dll file is not readable: $src_dll"
  case "$src_dll" in
    *.dll | *.DLL) ;;
    *) die "dll inspect: --dll expects a .dll file path: $src_dll" ;;
  esac
  fsr4_dll_inspect_print_report "dll" "$src_dll" "$src_dll" "$requested_ver"
}

amd_dll_inspect_driver_source() {
  local source_kind="${1:-}" source_ref="${2:-}" requested_ver="${3:-}" keep="${4:-0}"
  local dl="" downloaded=0 picked="" exdir="" drv_label="" reuseExtracted="0"
  local -a cands=()

  validate_amd_cache_names
  mkdir -p -- "$AMD_EXTRACT_ROOT" >/dev/null 2>&1 || true

  case "$source_kind" in
    exe)
      require_file "$source_ref" "--exe"
      dl="$source_ref"
      amd_dll_validate_driver_exe_after_resolve "$dl" "" 0
      validate_7z_archive_listing "$dl"
      ;;
    url)
      amd_dll_validate_url_for_inspect "$source_ref"
      need_cmd 7z
      amd_dll_resolve_url_driver_exe "$source_ref" dl downloaded
      amd_dll_validate_driver_exe_after_resolve "$dl" "$source_ref" "$downloaded"
      validate_7z_archive_listing "$dl"
      ;;
    *)
      die "dll inspect: internal source kind error: $source_kind"
      ;;
  esac

  local _cleanup_exdir=1
  if [[ "${keep:-0}" == "1" ]]; then
    _cleanup_exdir=0
  fi
  declare -g __GENVW_EXDIR=""
  declare -g __GENVW_EXDIR_CLEANUP="${_cleanup_exdir}"
  local __old_trap_exit="" __old_trap_int="" __old_trap_term=""
  __old_trap_exit="$(trap -p EXIT 2>/dev/null || true)"
  __old_trap_int="$(trap -p INT 2>/dev/null || true)"
  __old_trap_term="$(trap -p TERM 2>/dev/null || true)"
  trap 'amd_cleanup_extract_dir' EXIT
  trap 'amd_cleanup_extract_dir; exit 130' INT
  trap 'amd_cleanup_extract_dir; exit 143' TERM

  local inspect_url=""
  [[ "$source_kind" == "url" ]] && inspect_url="$source_ref"
  amd_dll_extract_pick_prepare "$dl" "$inspect_url" "$keep" "${requested_ver:-$FSR4_LOCAL_DEFAULT_VER}" 0 picked exdir drv_label reuseExtracted cands
  fsr4_dll_inspect_print_report "$source_kind" "$source_ref" "$picked" "$requested_ver"

  restore_one_trap "$__old_trap_exit" EXIT
  restore_one_trap "$__old_trap_int" INT
  restore_one_trap "$__old_trap_term" TERM
  amd_cleanup_extract_dir
}

# dll subcommand router (install/list/verify/check/uninstall/tidy/prefix-*)
amd_dll_run() {
  local __saved_amd_dll_name="${AMD_DLL_NAME:-}"
  local __saved_amd_meta_name="${AMD_META_NAME:-}"
  local __saved_amd_report_name="${AMD_REPORT_NAME:-}"
  local __saved_amd_allowlist_name="${AMD_ALLOWLIST_NAME:-}"
  local __saved_amd_allowlist_default="${AMD_DLL_ALLOWLIST_DEFAULT:-}"
  local __saved_amd_allowlist="${AMD_DLL_ALLOWLIST:-}"
  local fsr4_ver="${FSR4_LOCAL_DEFAULT_VER}"
  local want="$fsr4_ver"
  amd_set_cache_names_for_ver "${fsr4_ver}"
  local dst_dir="$DLL_DST_DIR_DEFAULT"
  local url="" exe="" src_dll=""
  local keep=0 force_url=0
  local dry_run=0
  local trust_local=0
  local trusted_only=0
  local ver_explicit=0
  local fsr4_ver_source=""
  local install_auto_detect_pending=0
  local install_expected_ver="" install_dev_override_ver=""

  # allow --dry-run before the verb
  while [[ "${1:-}" == "--dry-run" ]]; do
    dry_run=1
    shift
  done

  # help anywhere
  for a in "$@"; do
    case "$a" in
      -h | --help | help)
        amd_dll_help
        return 0
        ;;
    esac
  done

  if (($# == 0)); then
    amd_dll_help
    return 0
  fi

  # numeric-first is not supported
  if [[ "${1:-}" =~ ^[0-9]+$ ]]; then
    die "Numeric-first shorthand is not supported. Use: $(cmd_dll) --appid APPID [VER]  (or: $(cmd_dll) appid APPID [VER])"
  fi

  # shorthands:
  #   --appid APPID [VER] -> prefix-verify --appid APPID [VER]
  #   --pfx-dll PATH [VER] -> prefix-verify --pfx-dll PATH [VER]
  case "${1:-}" in
    --appid | appid)
      shift
      set -- prefix-verify --appid "$@"
      ;;
    --pfx-dll | pfx-dll)
      shift
      set -- prefix-verify --pfx-dll "$@"
      ;;
  esac

  case "${1:-}" in
    -h | --help | help)
      amd_dll_help
      return 0
      ;;
    backup | snapshot)
      shift
      local snapshot_ver_seen=0
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --dry-run)
            die "dll prefix-verify does not support --dry-run"
            ;;
          --verbose | --debug)
            declare -g GENVW_VERBOSE=1
            shift
            ;;
          --dst-dir)
            require_flag_value --dst-dir "${2-}"
            dst_dir="$2"
            shift 2
            ;;
          --ver)
            require_flag_value --ver "${2-}"
            fsr4_ver="$2"
            if [[ ! "${fsr4_ver}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
              die "--ver must look like X.Y.Z (example: ${FSR4_LOCAL_DEFAULT_VER}): ${fsr4_ver}"
            fi
            want="$fsr4_ver"
            ver_explicit=1
            snapshot_ver_seen=1
            amd_set_cache_names_for_ver "${fsr4_ver}"
            shift 2
            ;;
          *)
            if [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
              if ((snapshot_ver_seen == 1)); then
                die "backup: version specified more than once"
              fi
              fsr4_ver="$1"
              want="$fsr4_ver"
              ver_explicit=1
              snapshot_ver_seen=1
              amd_set_cache_names_for_ver "${fsr4_ver}"
              shift
            else
              die "Unknown flag for dll backup: $1 (try: $(cmd_dll) --help)"
            fi
            ;;
        esac
      done
      validate_inherited_local_dll_cache_root_if_used "$dst_dir"
      if ((ver_explicit == 0)); then
        local __effective_ver="" __effective_source=""
        fsr4_resolve_effective_local_default "$dst_dir" __effective_ver __effective_source
        fsr4_ver="$__effective_ver"
        want="$__effective_ver"
        amd_set_cache_names_for_ver "${fsr4_ver}"
      fi
      amd_dll_snapshot_create "$dst_dir" "${want:-$fsr4_ver}" "$dry_run"
      return 0
      ;;
    restore)
      shift
      local restore_ver_seen=0
      local restore_yes=0
      local restore_sha=""
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --dry-run)
            die "dll prefix-verify does not support --dry-run"
            ;;
          --yes | -y)
            restore_yes=1
            shift
            ;;
          --verbose | --debug)
            declare -g GENVW_VERBOSE=1
            shift
            ;;
          --dst-dir)
            require_flag_value --dst-dir "${2-}"
            dst_dir="$2"
            shift 2
            ;;
          --sha256)
            require_flag_value --sha256 "${2-}"
            restore_sha="$2"
            shift 2
            ;;
          --ver)
            require_flag_value --ver "${2-}"
            fsr4_ver="$2"
            if [[ ! "${fsr4_ver}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
              die "--ver must look like X.Y.Z (example: ${FSR4_LOCAL_DEFAULT_VER}): ${fsr4_ver}"
            fi
            want="$fsr4_ver"
            ver_explicit=1
            restore_ver_seen=1
            amd_set_cache_names_for_ver "${fsr4_ver}"
            shift 2
            ;;
          *)
            if [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
              if ((restore_ver_seen == 1)); then
                die "restore: version specified more than once"
              fi
              fsr4_ver="$1"
              want="$fsr4_ver"
              ver_explicit=1
              restore_ver_seen=1
              amd_set_cache_names_for_ver "${fsr4_ver}"
              shift
            else
              die "Unknown flag for dll restore: $1 (try: $(cmd_dll) --help)"
            fi
            ;;
        esac
      done
      validate_inherited_local_dll_cache_root_if_used "$dst_dir"
      if ((ver_explicit == 0)); then
        local __effective_ver="" __effective_source=""
        fsr4_resolve_effective_local_default "$dst_dir" __effective_ver __effective_source
        fsr4_ver="$__effective_ver"
        want="$__effective_ver"
        amd_set_cache_names_for_ver "${fsr4_ver}"
      fi
      amd_dll_restore_snapshot "$dst_dir" "${want:-$fsr4_ver}" "$restore_sha" "$restore_yes" "$dry_run"
      return 0
      ;;
    install)
      shift
      ;;
    inspect)
      shift
      local inspect_ver=""
      local inspect_ver_seen=0
      local inspect_keep=0
      local inspect_source_count=0
      local inspect_kind="" inspect_ref=""
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --dry-run)
            die "dll inspect is already read-only and does not support --dry-run"
            ;;
          --verbose | --debug)
            declare -g GENVW_VERBOSE=1
            shift
            ;;
          --ver)
            require_flag_value --ver "${2-}"
            inspect_ver="$2"
            if [[ ! "${inspect_ver}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
              die "--ver must look like X.Y.Z (example: ${FSR4_LOCAL_DEFAULT_VER}): ${inspect_ver}"
            fi
            inspect_ver_seen=1
            shift 2
            ;;
          --dll)
            require_flag_value --dll "${2-}"
            src_dll="$2"
            inspect_source_count=$((inspect_source_count + 1))
            inspect_kind="dll"
            inspect_ref="$src_dll"
            shift 2
            ;;
          --exe)
            require_flag_value --exe "${2-}"
            exe="$2"
            inspect_source_count=$((inspect_source_count + 1))
            inspect_kind="exe"
            inspect_ref="$exe"
            shift 2
            ;;
          --url)
            require_flag_value --url "${2-}"
            url="$2"
            inspect_source_count=$((inspect_source_count + 1))
            inspect_kind="url"
            inspect_ref="$url"
            shift 2
            ;;
          --keep)
            inspect_keep=1
            shift
            ;;
          --trust-local | --trust-dll)
            die "dll inspect: $1 is only valid for dll install"
            ;;
          -h | --help | help)
            amd_dll_help
            return 0
            ;;
          *)
            die "Unknown flag for dll inspect: $1 (try: $(cmd_dll) --help)"
            ;;
        esac
      done
      : "${inspect_ver_seen}"
      if ((dry_run == 1)); then
        die "dll inspect is already read-only and does not support --dry-run"
      fi
      if ((inspect_source_count != 1)); then
        die "dll inspect requires exactly one source: --dll, --exe, or --url"
      fi
      if [[ "$inspect_kind" == "dll" && "$inspect_keep" == "1" ]]; then
        die "dll inspect: --keep is only meaningful with --exe or --url"
      fi
      case "$inspect_kind" in
        dll) amd_dll_inspect_local_dll "$inspect_ref" "$inspect_ver" ;;
        exe | url) amd_dll_inspect_driver_source "$inspect_kind" "$inspect_ref" "$inspect_ver" "$inspect_keep" ;;
      esac
      return 0
      ;;
    verify | check)
      local __verb="${1:-}"
      shift
      local verify_ver_seen=0
      genvw_reset_validation_trust_anchor_defaults
      amd_set_cache_names_for_ver "${fsr4_ver}"
      dst_dir="$DLL_DST_DIR_DEFAULT"
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --dry-run)
            die "dll ${__verb} does not support --dry-run"
            ;;
          --verbose | --debug)
            declare -g GENVW_VERBOSE=1
            shift
            ;;
          --dst-dir)
            require_flag_value --dst-dir "${2-}"
            dst_dir="$2"
            shift 2
            ;;
          --ver)
            require_flag_value --ver "${2-}"
            fsr4_ver="$2"
            if [[ ! "${fsr4_ver}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
              die "--ver must look like X.Y.Z (example: ${FSR4_LOCAL_DEFAULT_VER}): ${fsr4_ver}"
            fi
            want="$fsr4_ver"
            ver_explicit=1
            verify_ver_seen=1
            amd_set_cache_names_for_ver "${fsr4_ver}"
            shift 2
            ;;
          *)
            if [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
              if ((verify_ver_seen == 1)); then
                die "dll ${__verb}: version specified more than once"
              fi
              fsr4_ver="$1"
              want="$fsr4_ver"
              ver_explicit=1
              verify_ver_seen=1
              amd_set_cache_names_for_ver "${fsr4_ver}"
              shift
            else
              die "Unknown flag for verify: $1"
            fi
            ;;
        esac
      done
      validate_inherited_local_dll_cache_root_if_used "$dst_dir"
      if ((ver_explicit == 0)); then
        local __effective_ver="" __effective_source=""
        fsr4_resolve_effective_local_default "$dst_dir" __effective_ver __effective_source
        fsr4_ver="$__effective_ver"
        want="$__effective_ver"
        amd_set_cache_names_for_ver "${fsr4_ver}"
      fi
      fsr4_warn_unreleased_read_only_ver "${want:-$fsr4_ver}" "dll ${__verb}"
      if [[ "$__verb" == "verify" ]]; then
        amd_dll_verify_report "$dst_dir" "${want:-$fsr4_ver}" || return $?
        return 0
      fi
      amd_dll_check "$dst_dir"
      amd_dll_provenance_integrity "$__verb" "$dst_dir" || return $?
      return 0
      ;;
    list)
      shift
      local list_ver=""
      genvw_reset_validation_trust_anchor_defaults
      dst_dir="$DLL_DST_DIR_DEFAULT"
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --verbose | --debug)
            declare -g GENVW_VERBOSE=1
            shift
            ;;
          --trusted-only)
            trusted_only=1
            shift
            ;;
          --dst-dir)
            require_flag_value --dst-dir "${2-}"
            dst_dir="$2"
            shift 2
            ;;
          --ver)
            require_flag_value --ver "${2-}"
            fsr4_ver="$2"
            if [[ ! "${fsr4_ver}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
              die "--ver must look like X.Y.Z (example: ${FSR4_LOCAL_DEFAULT_VER}): ${fsr4_ver}"
            fi
            list_ver="$fsr4_ver"
            shift 2
            ;;
          *) die "Unknown flag for dll list: $1 (try: $(cmd_dll) --help)" ;;
        esac
      done
      validate_inherited_local_dll_cache_root_if_used "$dst_dir"
      amd_dll_list "$dst_dir" "$list_ver" "$trusted_only" "${GENVW_VERBOSE:-0}"
      return 0
      ;;
    prefix-verify | verify-prefix | prefix_verify | verify_prefix)
      shift
      local appid="" pfx_dll=""

      # ver overrides any positional VER
      local ver_from_flag=0

      genvw_reset_validation_trust_anchor_defaults
      amd_set_cache_names_for_ver "${fsr4_ver}"
      dst_dir="$DLL_DST_DIR_DEFAULT"

      # positional form:
      #   prefix-verify APPID [VER]
      # flags still work: --appid, --ver, --pfx-dll, --dst-dir
      if [[ $# -gt 0 && "$1" != --* ]]; then
        if [[ "$1" =~ ^[0-9]+$ ]]; then
          appid="$1"
          shift
          if [[ $# -gt 0 && "$1" != --* ]]; then
            if [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
              want="$1"
              fsr4_ver="$want"
              ver_explicit=1
              amd_set_cache_names_for_ver "$want"
              shift
            else
              die "prefix-verify: positional VER must look like X.Y.Z (example: ${FSR4_LOCAL_DEFAULT_VER}): $1"
            fi
          fi
        elif [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
          amd_dll_prefix_version_without_target_usage "prefix-verify" "$1"
          return 1
        elif amd_dll_prefix_arg_looks_like_path "$1"; then
          amd_dll_prefix_direct_path_usage "prefix-verify"
          return 1
        else
          die "prefix-verify: positional APPID must be numeric: $1"
        fi
      fi

      while [[ $# -gt 0 ]]; do
        case "$1" in
          --dry-run)
            die "dll prefix-verify does not support --dry-run"
            ;;
          --verbose | --debug)
            declare -g GENVW_VERBOSE=1
            shift
            ;;
          --dst-dir)
            require_flag_value --dst-dir "${2-}"
            dst_dir="$2"
            shift 2
            ;;
          --ver)
            require_flag_value --ver "${2-}"
            fsr4_ver="$2"
            if [[ ! "${fsr4_ver}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
              die "--ver must look like X.Y.Z (example: ${FSR4_LOCAL_DEFAULT_VER}): ${fsr4_ver}"
            fi
            want="$fsr4_ver"
            ver_from_flag=1
            ver_explicit=1
            amd_set_cache_names_for_ver "${fsr4_ver}"
            shift 2
            ;;
          --appid)
            require_flag_value --appid "${2-}"
            appid="$2"
            shift 2
            ;;
          --pfx-dll | --dll)
            require_flag_value --pfx-dll "${2-}"
            pfx_dll="$2"
            shift 2
            ;;
          *)
            # allow a positional VER after flags, but don't override --ver
            if [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
              if ((ver_from_flag == 1)); then
                hint "prefix-verify: ignoring positional VER '$1' because --ver was provided"
                shift
                continue
              fi
              want="$1"
              ver_explicit=1
              amd_set_cache_names_for_ver "$want"
              shift
              continue
            fi
            die "Unknown flag for dll prefix-verify: $1 (try: $(cmd_dll) --help)"
            ;;
        esac
      done
      if [[ -z "$appid" && -z "$pfx_dll" ]]; then
        amd_dll_prefix_target_usage "prefix-verify"
        return 1
      fi
      validate_inherited_local_dll_cache_root_if_used "$dst_dir"
      if ((ver_explicit == 0)); then
        fsr4_ver="$FSR4_LOCAL_DEFAULT_VER"
        want="$FSR4_LOCAL_DEFAULT_VER"
        amd_set_cache_names_for_ver "${fsr4_ver}"
      fi

      if ((ver_explicit == 1)); then
        local __prefix_verify_ver="${want:-$fsr4_ver}"
        fsr4_warn_unreleased_read_only_ver "${__prefix_verify_ver}" "prefix-verify"
        if verbose_on; then
          amd_dll_check "$dst_dir" || return $?
        fi
        amd_dll_provenance_integrity "verify" "$dst_dir" || return $?
      fi
      amd_dll_prefix_verify "$appid" "$pfx_dll" "$dst_dir"
      return $?
      ;;

    prefix-sync | sync-prefix | prefix_sync | sync_prefix)
      shift
      local appid="" pfx_dll=""

      # same parse rules as prefix-verify
      local ver_from_flag=0
      if [[ $# -gt 0 && "$1" != --* ]]; then
        if [[ "$1" =~ ^[0-9]+$ ]]; then
          appid="$1"
          shift
          if [[ $# -gt 0 && "$1" != --* ]]; then
            if [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
              want="$1"
              fsr4_ver="$want"
              ver_explicit=1
              amd_set_cache_names_for_ver "$want"
              shift
            else
              die "prefix-sync: positional VER must look like X.Y.Z (example: ${FSR4_LOCAL_DEFAULT_VER}): $1"
            fi
          fi
        elif [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
          amd_dll_prefix_version_without_target_usage "prefix-sync" "$1"
          return 1
        elif amd_dll_prefix_arg_looks_like_path "$1"; then
          amd_dll_prefix_direct_path_usage "prefix-sync"
          return 1
        else
          die "prefix-sync: positional APPID must be numeric: $1"
        fi
      fi

      while [[ $# -gt 0 ]]; do
        case "$1" in
          --dry-run)
            dry_run=1
            shift
            ;;
          --verbose | --debug)
            declare -g GENVW_VERBOSE=1
            shift
            ;;
          --dst-dir)
            require_flag_value --dst-dir "${2-}"
            dst_dir="$2"
            shift 2
            ;;
          --ver)
            require_flag_value --ver "${2-}"
            fsr4_ver="$2"
            if [[ ! "${fsr4_ver}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
              die "--ver must look like X.Y.Z (example: ${FSR4_LOCAL_DEFAULT_VER}): ${fsr4_ver}"
            fi
            want="$fsr4_ver"
            ver_from_flag=1
            ver_explicit=1
            amd_set_cache_names_for_ver "${fsr4_ver}"
            shift 2
            ;;
          --appid)
            require_flag_value --appid "${2-}"
            appid="$2"
            shift 2
            ;;
          --pfx-dll | --dll)
            require_flag_value --pfx-dll "${2-}"
            pfx_dll="$2"
            shift 2
            ;;
          *)
            # allow a positional VER after flags, but don't override --ver
            if [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
              if ((ver_from_flag == 1)); then
                hint "prefix-sync: ignoring positional VER '$1' because --ver was provided"
                shift
                continue
              fi
              want="$1"
              ver_explicit=1
              amd_set_cache_names_for_ver "$want"
              shift
              continue
            fi
            die "Unknown flag for dll prefix-sync: $1 (try: $(cmd_dll) --help)"
            ;;
        esac
      done
      if [[ -z "$appid" && -z "$pfx_dll" ]]; then
        amd_dll_prefix_target_usage "prefix-sync"
        return 1
      fi
      validate_inherited_local_dll_cache_root_if_used "$dst_dir"
      if ((ver_explicit == 0)); then
        local __effective_ver="" __effective_source=""
        fsr4_resolve_effective_local_default "$dst_dir" __effective_ver __effective_source
        fsr4_ver="$__effective_ver"
        want="$__effective_ver"
        amd_set_cache_names_for_ver "${fsr4_ver}"
      fi

      fsr4_require_local_write_supported_ver "${want:-$fsr4_ver}" "dll prefix-sync"

      if ((dry_run == 1)); then
        msg "${I_INFO} dry-run: would prefix-sync"
        msg "  ver: ${want:-$fsr4_ver}"
        msg "  appid: ${appid:-none}"
        msg "  pfx-dll: ${pfx_dll:-(auto)}"
        msg "  dst-dir: $dst_dir"
        return 0
      fi

      if verbose_on; then
        amd_dll_check "$dst_dir" || return $?
      fi
      amd_dll_provenance_integrity "verify" "$dst_dir" || return $?
      amd_dll_prefix_sync "$appid" "$pfx_dll" "$dst_dir" || return $?
      # only verify if the sync worked
      amd_dll_prefix_verify "$appid" "$pfx_dll" "$dst_dir"
      return $?
      ;;

    tidy | clean | tidy-extracted)
      shift
      local driver_label=""

      while [[ $# -gt 0 ]]; do
        case "$1" in
          --dry-run)
            dry_run=1
            shift
            ;;
          --dst-dir)
            require_flag_value --dst-dir "${2-}"
            dst_dir="$2"
            shift 2
            ;;
          --driver-label | --driver)
            require_flag_value --driver-label "${2-}"
            driver_label="$2"
            shift 2
            ;;
          --help | -h)
            usage
            return 0
            ;;
          *)
            die "Unknown flag for dll tidy: $1 (try: $(cmd_dll) --help)"
            ;;
        esac
      done

      validate_inherited_local_dll_cache_root_if_used "$dst_dir"
      validate_amd_cache_names

      driver_label=${driver_label//$'\r'/}
      if declare -F kv_norm >/dev/null 2>&1; then
        driver_label="$(kv_norm "${driver_label}")"
      fi
      driver_label=${driver_label%.[eE][xX][eE]}

      if ((dry_run == 1)); then
        msg "${I_INFO} dry-run: would remove extracted folder(s) under:"
        msg "  $AMD_EXTRACT_ROOT"
        if [[ -n "$driver_label" ]]; then
          msg "  (driver-label: $driver_label)"
        else
          msg "  (auto: meta->driver-label, else all)"
        fi
        return 0
      fi
      if [[ -z "$driver_label" ]]; then
        local meta="$dst_dir/${AMD_META_NAME}"
        if [[ -f "$meta" ]]; then
          driver_label="$({
            grep -E '^DRIVER_LABEL=' "$meta" 2>/dev/null || true
            grep -E '^AMD_DRIVER_LABEL=' "$meta" 2>/dev/null || true
          } | head -n1 | cut -d= -f2-)"
          driver_label=${driver_label//$'\r'/}
          if declare -F kv_norm >/dev/null 2>&1; then
            driver_label="$(kv_norm "${driver_label}")"
          fi
          driver_label=${driver_label%.[eE][xX][eE]}

          if [[ -z "$driver_label" ]]; then
            local src_url src_path extracted_from dl_for
            src_url="$(grep -E '^SOURCE_URL=' "$meta" | head -n 1 | cut -d= -f2- || true)"
            src_path="$(grep -E '^SOURCE_PATH=' "$meta" | head -n 1 | cut -d= -f2- || true)"
            extracted_from="$(grep -E '^EXTRACTED_FROM=' "$meta" | head -n 1 | cut -d= -f2- || true)"
            dl_for=""
            if [[ -n "$src_path" ]]; then
              dl_for="$src_path"
            elif [[ -n "$extracted_from" ]]; then
              dl_for="$extracted_from"
            fi
            driver_label="$(amd_driver_label_from_source "$dl_for" "$src_url")"
          fi
        fi
      fi

      if [[ -n "$driver_label" ]]; then
        amd_dll_clean_extracted_driver_label "$driver_label"
      else
        amd_dll_clean_extracted_all
      fi

      return 0
      ;;
    remove | uninstall | rm)
      shift
      # remove accepts:
      #   uninstall --ver X.Y.Z
      #   uninstall X.Y.Z
      #   uninstall --all
      local remove_all=0
      local remove_ver_seen=0
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --dry-run)
            dry_run=1
            shift
            ;;
          --verbose | --debug)
            declare -g GENVW_VERBOSE=1
            shift
            ;;
          --dst-dir)
            require_flag_value --dst-dir "${2-}"
            dst_dir="$2"
            shift 2
            ;;
          --ver)
            require_flag_value --ver "${2-}"
            fsr4_ver="$2"
            if [[ ! "${fsr4_ver}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
              die "--ver must look like X.Y.Z (example: ${FSR4_LOCAL_DEFAULT_VER}): ${fsr4_ver}"
            fi
            want="$fsr4_ver"
            ver_explicit=1
            remove_ver_seen=1
            amd_set_cache_names_for_ver "${fsr4_ver}"
            shift 2
            ;;
          --all)
            remove_all=1
            shift
            ;;
          *)
            if [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
              if ((remove_ver_seen == 1)); then
                die "remove/uninstall: version specified more than once"
              fi
              fsr4_ver="$1"
              want="$fsr4_ver"
              ver_explicit=1
              remove_ver_seen=1
              amd_set_cache_names_for_ver "${fsr4_ver}"
              shift
            else
              die "Unknown flag for remove: $1"
            fi
            ;;
        esac
      done

      validate_inherited_local_dll_cache_root_if_used "$dst_dir"
      if ((remove_all == 1 && remove_ver_seen == 1)); then
        die "remove/uninstall: choose one of --all or --ver/VER (not both)"
      fi

      if [[ "$dry_run" == "1" ]]; then
        msg "${I_DEBUG} Dry run: no changes will be made."
        if ((remove_all == 1)); then
          msg "Would remove all versioned DLL cache files from: $dst_dir"
        else
          msg "Would uninstall DLL version ${want:-$FSR4_LOCAL_DEFAULT_VER} from: $dst_dir"
        fi
        return 0
      fi
      if ((remove_all == 1)); then
        amd_dll_uninstall_all "$dst_dir"
      else
        amd_dll_uninstall "$dst_dir"
      fi
      return 0
      ;;
  esac

  # install
  local install_positional_ver_seen=0
  local install_trusted_ver=0
  genvw_reset_install_allowlist_defaults "${fsr4_ver}"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        dry_run=1
        shift
        ;;
      --ver)
        require_flag_value --ver "${2-}"
        fsr4_ver="$2"
        if [[ ! "${fsr4_ver}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
          die "--ver must look like X.Y.Z (example: ${FSR4_LOCAL_DEFAULT_VER}): ${fsr4_ver}"
        fi
        want="$fsr4_ver"
        ver_explicit=1
        amd_set_cache_names_for_ver "${fsr4_ver}"
        shift 2
        ;;
      --verbose | --debug)
        declare -g GENVW_VERBOSE=1
        shift
        ;;
      --url)
        require_flag_value --url "${2-}"
        url="$2"
        shift 2
        ;;
      --dll)
        require_flag_value --dll "${2-}"
        src_dll="$2"
        shift 2
        ;;
      --exe)
        require_flag_value --exe "${2-}"
        exe="$2"
        shift 2
        ;;
      --dst-dir)
        require_flag_value --dst-dir "${2-}"
        dst_dir="$2"
        shift 2
        ;;
      --keep)
        keep=1
        shift
        ;;
      --force-url)
        force_url=1
        shift
        ;;
      --trust-local | --trust-dll)
        trust_local=1
        shift
        ;;
      -h | --help | help)
        amd_dll_help
        return 0
        ;;
      *)
        if [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
          if ((install_positional_ver_seen == 1)); then
            die "dll install: version specified more than once"
          fi
          fsr4_ver="$1"
          want="$fsr4_ver"
          ver_explicit=1
          install_positional_ver_seen=1
          amd_set_cache_names_for_ver "${fsr4_ver}"
          shift
        else
          die "Unknown dll flag: $1"
        fi
        ;;
    esac
  done

  if [[ -n "${GENVW_INSTALL_EXPECT_VER:-}" ]]; then
    install_expected_ver="$(fsr4_hidden_install_expect_ver)"
  fi
  if [[ -n "${GENVW_DEV_DLL_INSTALL_VER:-}" ]]; then
    install_dev_override_ver="$(fsr4_hidden_install_dev_override_ver)"
  fi
  if ((ver_explicit == 1 && install_trusted_ver == 0)); then
    install_expected_ver="${want:-$fsr4_ver}"
  fi

  if [[ -n "$src_dll" ]]; then
    install_auto_detect_pending=0
  elif [[ -n "$install_dev_override_ver" ]]; then
    want="$install_dev_override_ver"
    install_auto_detect_pending=0
  else
    install_auto_detect_pending=1
  fi

  # catch the common typo: url pasted into --exe
  if [[ -n "$exe" && "$exe" =~ ^https?:// ]]; then
    die "--exe expects a local file path, not a URL. Use: $(cmd_dll) install --url \"$exe\""
  fi

  # catch the common typo: url pasted into --dll
  if [[ -n "$src_dll" && "$src_dll" =~ ^https?:// ]]; then
    die "--dll expects a local file path, not a URL. Use: $(cmd_dll) install --url \"$src_dll\""
  fi

  local install_source_count=0
  [[ -n "$url" ]] && install_source_count=$((install_source_count + 1))
  [[ -n "$exe" ]] && install_source_count=$((install_source_count + 1))
  [[ -n "$src_dll" ]] && install_source_count=$((install_source_count + 1))
  if ((install_source_count > 1)); then
    die "dll install: choose one source: --dll, --url, or --exe"
  fi

  if ((install_source_count == 0 && ver_explicit == 1)); then
    install_trusted_ver=1
    install_auto_detect_pending=0
    fsr4_require_local_write_supported_ver "${want:-$fsr4_ver}" "dll install"
  fi

  # if neither flag was given, fall back to AMD_DRIVER_URL
  if [[ -z "$src_dll" && -z "$url" && -z "$exe" && "$install_trusted_ver" != "1" ]]; then
    url="$AMD_DRIVER_URL"
  fi

  [[ -n "$src_dll" || -n "$url" || -n "$exe" || "$install_trusted_ver" == "1" ]] || die "dll install needs one source: --ver X.Y.Z, --dll /path/to/amdxcffx64_vX.Y.Z.dll, --url URL, or --exe /path/to/driver.exe (or use: $(cmd_dll) verify)"
  validate_inherited_local_dll_cache_root_if_used "$dst_dir"
  declare -g GENVW_INSTALL_APPROVED_AMBIGUOUS_MARKERS=0
  declare -g GENVW_INSTALL_LOCAL_TRUST_APPROVED=0
  if ((trust_local == 1)); then
    declare -g GENVW_INSTALL_LOCAL_TRUST_APPROVED=1
  fi

  if [[ -n "$src_dll" ]]; then
    [[ "$keep" -eq 1 ]] && info "Ignoring --keep with --dll (no extract directory to keep)."
    [[ "$force_url" -eq 1 ]] && info "Ignoring --force-url with --dll (URL checks are not used)."
    amd_validate_local_dll_source_for_install "$src_dll"
    if [[ -n "$install_dev_override_ver" ]]; then
      fsr4_ver="$install_dev_override_ver"
      fsr4_ver_source="dev_override"
      info "dll install: using hidden dev version override ${fsr4_ver}."
    else
      if ! fsr4_resolve_install_ver_from_dll_markers "$src_dll" "dll" "$src_dll" "$install_expected_ver" "$ver_explicit" "$trust_local" "$dry_run" fsr4_ver; then
        AMD_DLL_NAME="$__saved_amd_dll_name"
        AMD_META_NAME="$__saved_amd_meta_name"
        AMD_REPORT_NAME="$__saved_amd_report_name"
        AMD_ALLOWLIST_NAME="$__saved_amd_allowlist_name"
        AMD_DLL_ALLOWLIST_DEFAULT="$__saved_amd_allowlist_default"
        AMD_DLL_ALLOWLIST="$__saved_amd_allowlist"
        return 1
      fi
      fsr4_ver_source="source_dll_scan"
      if [[ "${GENVW_INSTALL_APPROVED_AMBIGUOUS_MARKERS:-0}" == "1" ]]; then
        info "dll install: approved FSR4 ${fsr4_ver} from --dll markers."
      else
        info "dll install: auto-detected FSR4 ${fsr4_ver} from --dll input."
      fi
    fi
    if ! fsr4_enforce_expected_install_ver "$fsr4_ver" "$install_expected_ver" "dll install"; then
      AMD_DLL_NAME="$__saved_amd_dll_name"
      AMD_META_NAME="$__saved_amd_meta_name"
      AMD_REPORT_NAME="$__saved_amd_report_name"
      AMD_ALLOWLIST_NAME="$__saved_amd_allowlist_name"
      AMD_DLL_ALLOWLIST_DEFAULT="$__saved_amd_allowlist_default"
      AMD_DLL_ALLOWLIST="$__saved_amd_allowlist"
      return 1
    fi
    want="$fsr4_ver"
    amd_set_cache_names_for_ver "${fsr4_ver}"
    fsr4_require_local_write_supported_ver "${want:-$fsr4_ver}" "dll install"
  fi

  # dry-run prints what would happen, then exits
  if [[ "$dry_run" == "1" ]]; then
    msg "${I_DEBUG} Dry run: no changes will be made."
    if [[ "$install_trusted_ver" == "1" ]]; then
      msg "Would install trusted FSR4 version: $want"
      msg "Source: canonical trusted source map"
    elif [[ -n "$src_dll" ]]; then
      msg "Would install from local DLL: $src_dll"
      [[ "$keep" -eq 1 ]] && msg "Note: --keep is ignored with --dll"
      [[ "$force_url" -eq 1 ]] && msg "Note: --force-url is ignored with --dll"
    elif [[ -n "$exe" ]]; then
      msg "Would install from EXE: $exe"
    else
      msg "Would install from URL: $url"
    fi
    if ((install_auto_detect_pending == 1)); then
      msg "Want: auto-detect (from extracted DLL at install time)"
    elif [[ -n "$install_dev_override_ver" && -z "$src_dll" ]]; then
      msg "Want: $want (hidden dev override)"
    else
      msg "Want: $want"
    fi
    [[ -n "$install_expected_ver" ]] && msg "Expect: $install_expected_ver"
    msg "Dst:  $dst_dir"
    [[ "$keep" -eq 1 ]] && msg "Keep extracted: yes"
    [[ "$force_url" -eq 1 ]] && msg "Force URL allowlist: yes"
    if ((trust_local == 1)) && [[ -n "$src_dll" && -n "${want:-$fsr4_ver}" ]]; then
      fsr4_print_local_trust_plan "dll" "$src_dll" "$src_dll" "${want:-$fsr4_ver}"
    elif ((trust_local == 1)); then
      msg "Local trust approval: requested"
      if ((install_auto_detect_pending == 1)); then
        msg "Local trust approval plan requires extracting the selected DLL during a real install."
      fi
    fi
    AMD_DLL_NAME="$__saved_amd_dll_name"
    AMD_META_NAME="$__saved_amd_meta_name"
    AMD_REPORT_NAME="$__saved_amd_report_name"
    AMD_ALLOWLIST_NAME="$__saved_amd_allowlist_name"
    AMD_DLL_ALLOWLIST_DEFAULT="$__saved_amd_allowlist_default"
    AMD_DLL_ALLOWLIST="$__saved_amd_allowlist"
    return 0
  fi

  # install lock: stop two installs stomping each other
  local lock_base="$dst_dir"
  local lockfile="${lock_base}/${AMD_LOCK_NAME}"
  local lockfd
  local lockdir=""

  mkdir -p "$lock_base" || die "Cannot create lock directory: $lock_base"
  exec {lockfd}>"$lockfile" || die "Cannot open lock file: $lockfile"

  if have flock; then
    if ! flock -n "$lockfd"; then
      die "${I_LOCK} DLL install already running (lock busy): $lockfile"
    fi
  else
    # mkdir lock when flock is missing
    lockdir="${lockfile}.d"
    if mkdir "$lockdir" 2>/dev/null; then
      printf '%s\n' "$$" >"$lockdir/pid" 2>/dev/null || true
      info "${I_LOCK} flock not found — using mkdir lock: $lockdir"
    else
      local lockpid=""
      lockpid="$(cat "$lockdir/pid" 2>/dev/null || true)"
      if [[ "$lockpid" =~ ^[0-9]+$ ]] && kill -0 "$lockpid" 2>/dev/null; then
        die "${I_LOCK} DLL install already running (mkdir lock busy): $lockdir (pid $lockpid)"
      fi
      warn "${I_LOCK} Stale mkdir lock detected; clearing: $lockdir (pid ${lockpid:-unknown})"
      rm -f "$lockdir/pid" 2>/dev/null || true
      rmdir "$lockdir" 2>/dev/null || true
      mkdir "$lockdir" 2>/dev/null || die "${I_LOCK} DLL install already running (mkdir lock busy): $lockdir"
      printf '%s\n' "$$" >"$lockdir/pid" 2>/dev/null || true
      info "${I_LOCK} flock not found — using mkdir lock: $lockdir"
    fi
  fi

  # set +e so a failure path still reaches lock cleanup
  local install_rc=0
  local had_errexit=0
  case "$-" in
    *e*) had_errexit=1 ;;
  esac
  set +e
  if [[ "$install_trusted_ver" == "1" ]]; then
    amd_dll_install_trusted_version "${want:-$fsr4_ver}" "$dst_dir"
  elif [[ -n "$src_dll" ]]; then
    amd_dll_install_from_local_dll "$src_dll" "$dst_dir" "$fsr4_ver" "${fsr4_ver_source:-source_dll_scan}" "${GENVW_INSTALL_APPROVED_AMBIGUOUS_MARKERS:-0}"
  else
    amd_dll_install_from_source "$url" "$exe" "$dst_dir" "$keep" "$force_url" "$fsr4_ver" "$ver_explicit" "$trust_local"
  fi
  install_rc=$?
  if ((had_errexit == 1)); then
    set -e
  else
    set +e
  fi

  if ((install_rc != 0)); then
    if [[ -n "$lockdir" ]]; then
      rm -f "$lockdir/pid" 2>/dev/null || true
      rmdir "$lockdir" 2>/dev/null || true
    fi
    exec {lockfd}>&- 2>/dev/null || true

    if ((install_rc == 130 || install_rc == 143)); then
      warn "DLL install interrupted (rc=$install_rc); keeping partial downloads."
    fi
    AMD_DLL_NAME="$__saved_amd_dll_name"
    AMD_META_NAME="$__saved_amd_meta_name"
    AMD_REPORT_NAME="$__saved_amd_report_name"
    AMD_ALLOWLIST_NAME="$__saved_amd_allowlist_name"
    AMD_DLL_ALLOWLIST_DEFAULT="$__saved_amd_allowlist_default"
    AMD_DLL_ALLOWLIST="$__saved_amd_allowlist"
    return "$install_rc"
  fi

  if [[ "${GENVW_INSTALL_LOCAL_TRUST_APPROVED:-0}" == "1" ]]; then
    local __approved_ver="${GENVW_LAST_INSTALLED_FSR4_VER:-${want:-$fsr4_ver}}"
    if [[ -n "$__approved_ver" ]]; then
      fsr4_approve_installed_dll_local_allowlist "$__approved_ver" "$dst_dir"
    fi
  fi

  # trust check after install; doesn't block the success path
  local __trust_rc=0
  amd_dll_provenance_integrity verify "$dst_dir" || __trust_rc=$?
  if ((__trust_rc != 0)); then
    warn "Install finished, but the DLL is not fully trusted yet (META_MATCH and/or ALLOWLIST_MATCH failed)."
    warn "   gENVW will fall back to RDNA architecture defaults in soft mode (or refuse in strict mode) until you fix it."
  elif [[ "${GENVW_INSTALL_LOCAL_TRUST_APPROVED:-0}" == "1" ]]; then
    ok "${I_SHIELD} DLL trust: Trusted (META_MATCH=1, ALLOWLIST_MATCH=1)"
  fi

  if [[ -n "$lockdir" ]]; then
    rm -f "$lockdir/pid" 2>/dev/null || true
    rmdir "$lockdir" 2>/dev/null || true
  fi
  exec {lockfd}>&- 2>/dev/null || true
  AMD_DLL_NAME="$__saved_amd_dll_name"
  AMD_META_NAME="$__saved_amd_meta_name"
  AMD_REPORT_NAME="$__saved_amd_report_name"
  AMD_ALLOWLIST_NAME="$__saved_amd_allowlist_name"
  AMD_DLL_ALLOWLIST_DEFAULT="$__saved_amd_allowlist_default"
  AMD_DLL_ALLOWLIST="$__saved_amd_allowlist"
  return 0
}

# date flag: yyyymmdd, or empty
validate_date_yyyymmdd() {
  local d="${1:-}"
  [[ -z "$d" ]] && return 0
  [[ "$d" =~ ^[0-9]{8}$ ]] || die "Invalid --date '$d' (expected YYYYMMDD)"
}

# emit matching clone dirs (nul-separated)
_matching_clones() {
  local ctd="$1" major="$2" suffix="$3" date="${4:-}"
  local had_nullglob=0
  validate_major "$major"
  validate_suffix "$suffix"
  validate_ctd "$ctd"
  validate_date_yyyymmdd "$date"

  shopt -q nullglob && had_nullglob=1
  shopt -s nullglob
  local d
  if [[ -n "$date" ]]; then
    for d in "$ctd"/proton-cachyos-"$major"-"$date"-*-"$suffix"; do
      [[ -d "$d" ]] || continue
      clone_base_matches_major_selection "${d##*/}" "$suffix" "$date" "$major" && printf '%s\0' "$d"
    done
  else
    for d in "$ctd"/proton-cachyos-"$major"-*-"$suffix"; do
      [[ -d "$d" ]] || continue
      clone_base_matches_major_selection "${d##*/}" "$suffix" "" "$major" && printf '%s\0' "$d"
    done
  fi
  ((had_nullglob == 1)) || shopt -u nullglob
}

clone_base_matches_major_selection() {
  local base="${1:-}" suffix="${2:-}" date_filter="${3:-}" major_filter="${4:-${MAJOR:-$MAJOR_DEFAULT}}"
  local core="$base" clone_major="" clone_date="" arch=""

  [[ -n "$suffix" && "$base" == *-"$suffix" ]] || return 1
  core="${base%-${suffix}}"
  if [[ "$core" =~ ^proton-cachyos-([0-9]+([.][0-9]+)?)-([0-9]{8})-(native|slr)-(.+)$ ]]; then
    clone_major="${BASH_REMATCH[1]}"
    clone_date="${BASH_REMATCH[3]}"
    arch="${BASH_REMATCH[5]}"
  elif [[ "$core" =~ ^proton-cachyos-([0-9]+([.][0-9]+)?)-([0-9]{8})-(x86_64(_v[1-4])?)$ ]]; then
    clone_major="${BASH_REMATCH[1]}"
    clone_date="${BASH_REMATCH[3]}"
    arch="${BASH_REMATCH[4]}"
  else
    return 1
  fi

  case "$arch" in
    x86_64 | x86_64_v[1-4] | protonplus-unspecified | protonplus-x86_64 | protonplus-x86_64_v[1-4] | system-x86_64) ;;
    *) return 1 ;;
  esac
  [[ -z "$date_filter" || "$clone_date" == "$date_filter" ]] || return 1
  if major_selection_is_all_supported; then
    [[ "$clone_major" =~ ^[0-9]+(\.[0-9]+)?$ ]]
  else
    [[ "$clone_major" == "$major_filter" ]]
  fi
}

_matching_clones_for_current_selection() {
  local ctd="$1" suffix="$2" date="${3:-}"
  local had_nullglob=0
  validate_suffix "$suffix"
  validate_ctd "$ctd"
  validate_date_yyyymmdd "$date"

  if ! major_selection_is_all_supported; then
    _matching_clones "$ctd" "$MAJOR" "$suffix" "$date"
    return 0
  fi

  shopt -q nullglob && had_nullglob=1
  shopt -s nullglob
  local d base
  if [[ -n "$date" ]]; then
    for d in "$ctd"/proton-cachyos-*-"$date"-*-"$suffix"; do
      [[ -d "$d" ]] || continue
      base="${d##*/}"
      clone_base_matches_major_selection "$base" "$suffix" "$date" && printf '%s\0' "$d"
    done
  else
    for d in "$ctd"/proton-cachyos-*-"$suffix"; do
      [[ -d "$d" ]] || continue
      base="${d##*/}"
      clone_base_matches_major_selection "$base" "$suffix" "" && printf '%s\0' "$d"
    done
  fi
  ((had_nullglob == 1)) || shopt -u nullglob
}

dwproton_clone_inventory_record_for_base() {
  local base="${1:-}" suffix="${2:-}" core="" version="" arch="" major="" minor="" build=""

  validate_suffix "$suffix"
  [[ -n "$suffix" && "$base" == *-"$suffix" ]] || return 1
  core="${base%-${suffix}}"
  if [[ "$core" =~ ^dwproton-([0-9]+)[.]([0-9]+)-([0-9]+)-(x86_64(_v[1-4])?)$ ]]; then
    major="${BASH_REMATCH[1]}"
    minor="${BASH_REMATCH[2]}"
    build="${BASH_REMATCH[3]}"
    arch="${BASH_REMATCH[4]}"
    version="${major}.${minor}-${build}"
  else
    return 1
  fi

  printf '%08d\t%08d\t%08d\t%s\t%s\t%s\n' "$major" "$minor" "$build" "$base" "$version" "$arch"
}

_matching_dwproton_clones_for_human_inventory() {
  local ctd="$1" suffix="$2" date="${3:-}"
  local had_nullglob=0 d="" base="" rec=""
  validate_suffix "$suffix"
  validate_ctd "$ctd"
  validate_date_yyyymmdd "$date"

  [[ -z "$date" ]] || return 0
  major_selection_is_all_supported || return 0

  shopt -q nullglob && had_nullglob=1
  shopt -s nullglob
  for d in "$ctd"/dwproton-*-"$suffix"; do
    [[ -d "$d" && ! -L "$d" ]] || continue
    base="${d##*/}"
    rec="$(dwproton_clone_inventory_record_for_base "$base" "$suffix" 2>/dev/null || true)"
    [[ -n "$rec" ]] && printf '%s\0' "$d"
  done
  ((had_nullglob == 1)) || shopt -u nullglob
}

# pull yyyymmdd out of a clone basename
_clone_date_from_basename() {
  local b="${1:-}"
  if [[ "$b" =~ -([0-9]{8})- ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

# list clone dates (sorted, unique)
_list_clone_dates_sorted_unique() {
  local -a dates=()
  local p b d
  while IFS= read -r -d '' p; do
    b="$(basename "$p")"
    d="$(_clone_date_from_basename "$b" 2>/dev/null || true)"
    [[ -n "$d" ]] && dates+=("$d")
  done < <(_matching_clones "$CTD" "$MAJOR" "$SUFFIX" "")

  ((${#dates[@]})) || return 0
  printf '%s\n' "${dates[@]}" | sort -u
}

# collect clone paths for a list of dates (nul-separated)
_collect_clones_for_dates() {
  local d
  for d in "$@"; do
    _matching_clones "$CTD" "$MAJOR" "$SUFFIX" "$d"
  done
}

# pick keep vs drop dates, then collect clone paths to remove
dwproton_clean_old_rotation_plan() {
  local ctd="${1:-}" suffix="${2:-}" keep_n="${3:-2}"

  DW_CLEAN_OLD_KEEP=()
  DW_CLEAN_OLD_REMOVE=()

  local -a records=()
  local _dw_plan_p _dw_plan_rec
  while IFS= read -r -d '' _dw_plan_p; do
    [[ -n "$_dw_plan_p" ]] || continue
    dwproton_clone_owned_for_clean "$_dw_plan_p" "$suffix" 2>/dev/null || continue
    _dw_plan_rec="$(dwproton_clone_inventory_record_for_base "${_dw_plan_p##*/}" "$suffix" 2>/dev/null)" || continue
    [[ -n "$_dw_plan_rec" ]] || continue
    records+=("${_dw_plan_rec}"$'\t'"${_dw_plan_p}")
  done < <(_matching_dwproton_clones_for_human_inventory "$ctd" "$suffix" "")

  ((${#records[@]} > 0)) || return 0

  local -a sorted=()
  mapfile -t sorted < <(printf '%s\n' "${records[@]}" | sort -t$'\t' -k1,1 -k2,2 -k6,6 -k3,3)

  local prev_key="" cur_key="" _dw_plan_item _dw_plan_path
  local -a group_paths=()
  local _gn _gj

  for _dw_plan_item in "${sorted[@]}" ""; do
    if [[ -n "$_dw_plan_item" ]]; then
      cur_key="$(printf '%s\n' "$_dw_plan_item" | awk -F'\t' '{print $1 "_" $2 "_" $6}')"
      _dw_plan_path="$(printf '%s\n' "$_dw_plan_item" | awk -F'\t' '{print $7}')"
    else
      cur_key=""
    fi

    if [[ "$cur_key" != "$prev_key" && -n "$prev_key" ]]; then
      _gn="${#group_paths[@]}"
      for ((_gj = 0; _gj < _gn; _gj++)); do
        if ((_gj < _gn - keep_n)); then
          DW_CLEAN_OLD_REMOVE+=("${group_paths[$_gj]}")
        else
          DW_CLEAN_OLD_KEEP+=("${group_paths[$_gj]}")
        fi
      done
      group_paths=()
    fi

    if [[ -n "$_dw_plan_item" ]]; then
      group_paths+=("$_dw_plan_path")
      prev_key="$cur_key"
    fi
  done

  return 0
}

dwproton_clean_old_print_plan() {
  local mode="${1:-dry-run}" _dw_old_p

  ((${#DW_CLEAN_OLD_KEEP[@]} > 0 || ${#DW_CLEAN_OLD_REMOVE[@]} > 0)) || return 0

  msg ""
  if [[ "$mode" == "dry-run" ]]; then
    msg "DW-Proton clean --old preview (dry-run only):"
  else
    msg "DW-Proton clean --old candidates:"
  fi
  for _dw_old_p in "${DW_CLEAN_OLD_KEEP[@]##*/}"; do
    printf '  %-8s %s\n' "KEEP" "$_dw_old_p"
  done
  for _dw_old_p in "${DW_CLEAN_OLD_REMOVE[@]##*/}"; do
    printf '  %-8s %s\n' "REMOVE" "$_dw_old_p"
  done
  if [[ "$mode" == "dry-run" ]]; then
    msg "${I_INFO} DW-Proton clean --old dry-run preview only. Actual clean --old removes strictly validated older DW-Proton gENVW clones after confirmation."
  else
    msg "${I_INFO} DW-Proton clean --old removes only strictly validated REMOVE candidates."
  fi
}

dwproton_clean_old_remove_candidates() {
  local _dw_old_del count=0

  for _dw_old_del in "${DW_CLEAN_OLD_REMOVE[@]}"; do
    dwproton_clone_owned_for_clean "$_dw_old_del" "$SUFFIX" || die "DW-Proton clean --old candidate failed validation: ${_dw_old_del##*/}"
    rm_rf_within_root "$CTD" "$_dw_old_del" || die "Failed to remove DW clone ${_dw_old_del##*/}"
    count=$((count + 1))
  done

  ((count == 0)) || ok "Removed ${count} older DW-Proton clone(s)."
}

_clean_old_candidates() {
  local keep_n="${1:-2}"

  CLEAN_KEEP_DATES=()
  CLEAN_DROP_DATES=()
  CLEAN_DOOMED=()

  local -a dates=()
  mapfile -t dates < <(_list_clone_dates_sorted_unique)

  local nd="${#dates[@]}"
  ((nd > 0)) || return 0

  if ((nd <= keep_n)); then
    CLEAN_KEEP_DATES=("${dates[@]}")
    return 0
  fi

  CLEAN_KEEP_DATES=("${dates[@]:nd-keep_n:keep_n}")
  CLEAN_DROP_DATES=("${dates[@]:0:nd-keep_n}")

  local -a doomed=()
  local p
  while IFS= read -r -d '' p; do
    [[ -n "$p" ]] && doomed+=("$p")
  done < <(_collect_clones_for_dates "${CLEAN_DROP_DATES[@]}")

  CLEAN_DOOMED=("${doomed[@]}")
}

# clean-old: keep newest dates for this suffix, drop older clones
do_clean_old() {
  # suffix must be set by parse_kv_flags; empty suffix matches wide
  local keep_n=2

  if steam_running; then
    if [[ "${DRY_RUN:-0}" == "1" || "${DRYRUN:-0}" == "1" ]]; then
      msg "${I_DEBUG} Allowing --dry-run while Steam is running."
    else
      die "Steam is running. Close Steam before clean."
    fi
  fi

  _clean_old_candidates "$keep_n"
  dwproton_clean_old_rotation_plan "$CTD" "$SUFFIX" "$keep_n"
  if ((${#CLEAN_DOOMED[@]} == 0)); then
    msg "${I_INFO} Nothing to remove for suffix '-$SUFFIX' (major=$MAJOR) — already within newest $keep_n date(s)."
    if [[ "${DRY_RUN:-0}" == "1" || "${DRYRUN:-0}" == "1" ]]; then
      dwproton_clean_old_print_plan "dry-run"
      return 0
    fi
    if ((${#DW_CLEAN_OLD_REMOVE[@]} > 0)); then
      dwproton_clean_old_print_plan "actual"
      msg ""
      if ask_yes_no_default "${I_WARN}${I_WARN} Delete older DW-Proton clones now (keep newest ${keep_n})? [y/N]: " "n"; then
        dwproton_clean_old_remove_candidates
      else
        msg "${I_INFO} DW-Proton cleanup skipped by user."
      fi
    fi
    return 0
  fi

  msg ""
  msg "${I_INFO} Cleanup scope:"
  msg "  • deletes ONLY *-${SUFFIX} tools under: $CTD"
  warn "  • never touches Proton-CachyOS sources"
  warn "  • never touches non-${SUFFIX} tools"
  warn "  • never deletes anything outside compatibilitytools.d"
  msg ""
  msg "${I_DATE}  Keeping newest ${keep_n} date(s): ${CLEAN_KEEP_DATES[*]}"
  msg "${I_BOX} Removing older date(s): ${CLEAN_DROP_DATES[*]}"
  msg ""
  msg "${I_TRASH} Clones that would be removed:"
  printf '  • %s\n' "${CLEAN_DOOMED[@]##*/}"
  msg ""
  msg "${I_INFO} You can rebuild any removed date later (as long as sources exist) with:"
  msg "  $(cmd_proton) rebuild --date YYYYMMDD"
  msg ""

  if [[ "${DRY_RUN:-0}" == "1" || "${DRYRUN:-0}" == "1" ]]; then
    dwproton_clean_old_print_plan "dry-run"
  else
    dwproton_clean_old_print_plan "actual"
  fi

  if ask_yes_no_default "${I_WARN}${I_WARN} Delete the older gENVW tools now (keep newest ${keep_n})? [y/N]: " "n"; then
    if [[ "${DRY_RUN:-0}" == "1" || "${DRYRUN:-0}" == "1" ]]; then
      msg "${I_DEBUG} Dry run: no files removed."
      return 0
    fi
    local p
    for p in "${CLEAN_DOOMED[@]}"; do
      rm_rf_within_root "$CTD" "$p" || die "Failed to remove $p"
    done
    ok "Removed ${#CLEAN_DOOMED[@]} older clone(s)."
    dwproton_clean_old_remove_candidates
  else
    msg "${I_INFO} Cleanup skipped by user."
  fi
}

# ask to run clean --old after a fully successful rebuild
prompt_clean_old_after_rebuild() {
  local built="${1:-0}"
  local total="${2:-0}"

  # only after a clean rebuild (all clones built)
  ((total > 0)) || return 0
  ((built == total)) || return 0
  is_tty || return 0

  # only prompt when there's something to drop
  _clean_old_candidates 2
  ((${#CLEAN_DOOMED[@]} > 0)) || return 0

  msg ""
  warn "Older gENVW Proton tools are still installed (you now have multiple dates)."
  msg "${I_INFO} Optional cleanup: keep newest 2 dates (newest + one fallback)."
  msg "   This does NOT affect sources; tools can be rebuilt again with:"
  msg "     $(cmd_proton) rebuild --date YYYYMMDD"
  msg ""

  if ask_yes_no_default "${I_WARN}${I_WARN} Run cleanup now? (genvw proton clean --old) [y/N]: " "n"; then
    do_clean_old
  else
    msg "${I_INFO} Cleanup skipped by user."
  fi
}

# list clones matching the same pattern used by clean
do_list_clones() {
  parse_kv_flags --ctd-optional "$@"
  if [[ "${GENVW_KV_HELP:-0}" == "1" ]]; then
    return 0
  fi
  local list_date="${BUILD_DATE:-}"

  local -a hits=()
  while IFS= read -r -d '' p; do
    [[ -n "$p" ]] && hits+=("$p")
  done < <(_matching_clones_for_current_selection "$CTD" "$SUFFIX" "$list_date")

  local -a dw_hits=()
  while IFS= read -r -d '' p; do
    [[ -n "$p" ]] && dw_hits+=("$p")
  done < <(_matching_dwproton_clones_for_human_inventory "$CTD" "$SUFFIX" "$list_date")

  if ((${#hits[@]} == 0 && ${#dw_hits[@]} == 0)); then
    if [[ -n "$list_date" ]]; then
      msg "${I_INFO} Nothing found for suffix '-$SUFFIX' (major=$(major_selection_label) date=$list_date)"
    else
      msg "${I_INFO} Nothing found for suffix '-$SUFFIX' (major=$(major_selection_label))"
    fi
    return 0
  fi

  msg "gENVW Proton clones"
  msg ""
  print_label_value_row "Compatibilitytools.d:" "$CTD"
  print_label_value_row "Major:" "$(major_selection_label)"
  print_label_value_row "Suffix:" "$SUFFIX"
  [[ -n "$list_date" ]] && print_label_value_row "Date:" "$list_date"
  msg ""
  if ((${#hits[@]} > 0)); then
    print_clone_summary_table "$MAJOR" "$SUFFIX" "${hits[@]}"
  fi
  if ((${#dw_hits[@]} > 0)); then
    ((${#hits[@]} > 0)) && msg ""
    print_dwproton_clone_inventory_table "$SUFFIX" "${dw_hits[@]}"
  fi
  print_list_clones_summary hits dw_hits "$SUFFIX"
}

# clone + patch preflight
preflight_proton() {
  need_cmd python3
  need_cmd mktemp
  need_cmd cp
  need_cmd rm
  need_cmd find
  need_cmd sort
  need_cmd grep

  # fill steam root/ctd for status output
  steam_detect_ctd "$MAJOR"
  [[ -d "$CTD" ]] || die "compatibilitytools.d not found: $CTD"

  if [[ -f "$LOCALDLL" ]]; then
    local sz
    sz="$(stat -c '%s' "$LOCALDLL" 2>/dev/null || echo 0)"
    if [[ "$sz" -lt 1024 ]]; then
      warn "Local DLL too small (<1 KiB): $LOCALDLL"
    fi
  fi
}

# collect proton-cachyos sources (skip suffix clones)
gather_sources() {
  SOURCES=()
  local had_nullglob=0
  local d b rec="" parsed="" src_major=""
  local -a ctd_sources=()
  local -a system_sources=()
  local -a ctd_globs=()
  shopt -q nullglob && had_nullglob=1
  shopt -s nullglob
  # By design, rebuild/prep source selection ignores symlinked clone dirs.
  # Why: keep patch source selection tied to real directories in CTD.
  # Impact: symlink-only source trees are intentionally skipped.
  if major_selection_is_all_supported; then
    ctd_globs=("$CTD"/proton-cachyos-* "$CTD"/cachyos-*)
  else
    ctd_globs=("$CTD"/proton-cachyos-"$MAJOR"-* "$CTD"/cachyos-"$MAJOR"-*)
  fi
  for d in "${ctd_globs[@]}"; do
    [[ -d "$d" && ! -L "$d" ]] || continue
    b="${d##*/}"
    case "$b" in
      *-"$SUFFIX") continue ;;
    esac
    rec="$(source_metadata_record "$d" 2>/dev/null || true)"
    [[ -n "$rec" ]] || continue
    parsed="${rec#*|}"
    src_major="${parsed%%|*}"
    source_major_matches_selection "$src_major" || continue
    append_unique_path "$d" ctd_sources
  done

  local root="" sys=""
  while IFS= read -r root; do
    [[ -d "$root" ]] || continue
    for sys in "$root"/proton-cachyos "$root"/proton-cachyos-slr; do
      [[ -d "$sys" && ! -L "$sys" ]] || continue
      rec="$(source_metadata_record "$sys" 2>/dev/null || true)"
      [[ -n "$rec" ]] || continue
      parsed="${rec#*|}"
      src_major="${parsed%%|*}"
      source_major_matches_selection "$src_major" || continue
      append_unique_path "$sys" system_sources
    done
  done < <(system_source_roots)

  case "${GENVW_SOURCE_SELECTION:-default}" in
    prefer_system)
      if ((${#system_sources[@]} > 0)); then
        SOURCES=("${system_sources[@]}")
      else
        SOURCES=("${ctd_sources[@]}")
      fi
      ;;
    ctd_preferred)
      if ((${#ctd_sources[@]} > 0)); then
        SOURCES=("${ctd_sources[@]}")
      else
        SOURCES=("${system_sources[@]}")
      fi
      ;;
    system_only)
      SOURCES=("${system_sources[@]}")
      ;;
    *)
      SOURCES=("${system_sources[@]}" "${ctd_sources[@]}")
      ;;
  esac
  ((had_nullglob == 1)) || shopt -u nullglob
}

detect_build_date() {
  # pull YYYYMMDD tokens out of SOURCES[], return the newest one
  detect_build_date_for_sources "${SOURCES[@]}"
}

detect_build_date_for_sources() {
  # pull YYYYMMDD tokens out of the provided source list, return newest
  local -a dates=()
  local d
  for d in "$@"; do
    local src_date=""
    src_date="$(source_build_date "$d" 2>/dev/null || true)"
    [[ "$src_date" =~ ^[0-9]{8}$ ]] || continue
    dates+=("$src_date")
  done
  ((${#dates[@]} > 0)) || return 1
  printf '%s\n' "${dates[@]}" | sort -u | tail -n 1
}

extract_build_date_from_name() {
  # extract YYYYMMDD from a proton folder name, print it if found
  local b="${1:-}"
  if [[ "$b" =~ ([0-9]{8}) ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  fi
}

min_supported_date_genvw() {
  local min="${MIN_SUPPORTED_DATE_GENVW:-20251222}"
  [[ "$min" =~ ^[0-9]{8}$ ]] || min=20251222
  printf '%s\n' "$min"
}

is_supported_source_date() {
  local d="${1:-}"
  local min
  [[ "$d" =~ ^[0-9]{8}$ ]] || return 1
  min="$(min_supported_date_genvw)"
  ((10#$d >= 10#$min))
}

gather_supported_sources_from_sources() {
  # build SUPPORTED_SOURCES[] from SOURCES[] using MIN_SUPPORTED_DATE_GENVW
  # and the shared patch-capability gate used by rebuild/check provider targets.
  SUPPORTED_SOURCES=()
  local src d reason=""
  for src in "${SOURCES[@]}"; do
    d="$(source_build_date "$src" || true)"
    is_supported_source_date "$d" || continue
    source_is_patch_capable_target "$src" reason || continue
    SUPPORTED_SOURCES+=("$src")
  done
}

source_policy_bucket_for_wizard() {
  local major="${1:-}" date="${2:-}" major_int=""
  major_int="${major%%.*}"

  case "$major_int" in
    10)
      printf '%s\n' "stable_practical"
      ;;
    11)
      if [[ "$date" =~ ^[0-9]{8}$ ]] && ((10#$date >= 10#20260428)); then
        printf '%s\n' "policy_known_capability_gated"
      else
        printf '%s\n' "future_unknown"
      fi
      ;;
    *)
      printf '%s\n' "future_unknown"
      ;;
  esac
}

source_policy_label_for_wizard() {
  case "${1:-}" in
    stable_practical) printf '%s\n' "supported" ;;
    policy_known_capability_gated) printf '%s\n' "supported, guarded" ;;
    future_unknown) printf '%s\n' "unsupported" ;;
    *) printf '%s\n' "unsupported" ;;
  esac
}

source_policy_label_for_human() {
  case "${1:-}" in
    stable_practical | policy_known_capability_gated) printf '%s\n' "supported" ;;
    future_unknown) printf '%s\n' "unsupported" ;;
    *) printf '%s\n' "unsupported" ;;
  esac
}

source_folder_family_for_path() {
  local src="${1:-}" base="${src##*/}"
  case "$base" in
    proton-cachyos-*-*-*-*) printf '%s\n' "protonup-qt" ;;
    cachyos-*-*-*) printf '%s\n' "protonplus" ;;
    proton-cachyos | proton-cachyos-slr) printf '%s\n' "system-package" ;;
    *) printf '%s\n' "unknown" ;;
  esac
}

source_target_status_label_for_kind() {
  local kind="${1:-source}" bucket="${2:-}"
  if [[ "$kind" == "clone" ]]; then
    printf '%s\n' "installed"
    return 0
  fi
  source_policy_label_for_human "$bucket"
}

source_target_family_label_for_human() {
  local kind="${1:-source}" family="${2:-}" provenance="${3:-}"
  if [[ "$kind" == "clone" ]]; then
    printf '%s\n' "local CTD"
    return 0
  fi
  case "$family" in
    protonup-qt) printf '%s\n' "ProtonUp-Qt" ;;
    protonplus) printf '%s\n' "ProtonPlus" ;;
    system-package) printf '%s\n' "system" ;;
    *)
      case "$provenance" in
        ctd) printf '%s\n' "local CTD" ;;
        system) printf '%s\n' "system" ;;
        *) printf '%s\n' "${family:-unknown}" ;;
      esac
      ;;
  esac
}

source_clone_family_label_for_human() {
  case "$(clone_family_label_from_base "${1:-}")" in
    System) printf '%s\n' "system" ;;
    ProtonPlus) printf '%s\n' "ProtonPlus" ;;
    ProtonUp-Qt) printf '%s\n' "ProtonUp-Qt" ;;
    *) printf '%s\n' "local CTD" ;;
  esac
}

source_human_state_for_source() {
  local src="${1:-}" bucket="${2:-}" label="" reason=""
  label="$(source_policy_label_for_human "$bucket")"
  [[ "$label" == "supported" ]] || {
    printf '%s\n' "$label"
    return 0
  }

  if source_requires_patch_capability_check "$src"; then
    if source_patch_capability_check "$src" reason; then
      printf '%s\n' "supported"
      return 0
    fi
    case "$reason" in
      missing_* | unrecognized_source | source_not_directory) printf '%s\n' "incomplete" ;;
      *) printf '%s\n' "broken" ;;
    esac
    return 0
  fi

  printf '%s\n' "supported"
}

source_target_arch_for_human() {
  case "${1:-}" in
    system-x86_64) printf '%s\n' "x86_64" ;;
    protonplus-unspecified | "") printf '%s\n' "unknown" ;;
    protonplus-x86_64 | protonplus-x86_64_v[1-4]) printf '%s\n' "${1#protonplus-}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

source_vdf_metadata_record() {
  local src="${1:-}" vdf="" token="" major="" date="" runtime="" arch=""
  vdf="$src/compatibilitytool.vdf"
  [[ -r "$vdf" ]] || return 1

  while IFS= read -r token; do
    if [[ "$token" =~ ^proton-cachyos-([0-9]+([.][0-9]+)?)-([0-9]{8})-(native|slr)-(x86_64(_v[1-4])?)$ ]]; then
      major="${BASH_REMATCH[1]}"
      date="${BASH_REMATCH[3]}"
      runtime="${BASH_REMATCH[4]}"
      arch="${BASH_REMATCH[5]}"
      printf '%s|%s|%s|%s|%s\n' "$token" "$major" "$date" "$runtime" "$arch"
      return 0
    fi
  done < <(awk -F'"' '{ for (i = 2; i <= NF; i += 2) print $i }' "$vdf" 2>/dev/null)

  return 1
}

source_list_metadata_record() {
  local src="${1:-}" rec="" vdf_rec="" parsed="" base="" major="" date="" runtime="" arch=""
  local vdf_base="" vdf_major="" vdf_date="" vdf_runtime="" vdf_arch=""

  rec="$(source_metadata_record "$src" 2>/dev/null || true)"
  [[ -n "$rec" ]] || return 1

  parsed="${rec#*|}"
  base="${rec%%|*}"
  major="${parsed%%|*}"
  parsed="${parsed#*|}"
  date="${parsed%%|*}"
  parsed="${parsed#*|}"
  runtime="${parsed%%|*}"
  arch="${parsed#*|}"

  if [[ "$arch" != "protonplus-unspecified" ]]; then
    printf '%s\n' "$rec"
    return 0
  fi

  vdf_rec="$(source_vdf_metadata_record "$src" 2>/dev/null || true)"
  [[ -n "$vdf_rec" ]] || {
    printf '%s\n' "$rec"
    return 0
  }

  parsed="${vdf_rec#*|}"
  vdf_base="${vdf_rec%%|*}"
  vdf_major="${parsed%%|*}"
  parsed="${parsed#*|}"
  vdf_date="${parsed%%|*}"
  parsed="${parsed#*|}"
  vdf_runtime="${parsed%%|*}"
  vdf_arch="${parsed#*|}"

  if [[ "$major" == "$vdf_major" && "$date" == "$vdf_date" && "$runtime" == "$vdf_runtime" ]]; then
    printf '%s|%s|%s|%s|%s\n' "$vdf_base" "$major" "$date" "$runtime" "$vdf_arch"
    return 0
  fi

  printf '%s\n' "$rec"
}

source_target_record_for_list() {
  local src="${1:-}" suffix="${2:-${SUFFIX:-$SUFFIX_DEFAULT}}" rec="" kind="source"
  rec="$(source_list_metadata_record "$src" 2>/dev/null || true)"
  if [[ -z "$rec" ]]; then
    rec="$(clone_metadata_record "$src" "$suffix" 2>/dev/null || true)"
    kind="clone"
  fi
  [[ -n "$rec" ]] || return 1
  printf '%s|%s\n' "$kind" "$rec"
}

source_human_row_record() {
  local src="${1:-}" suffix="${2:-${SUFFIX:-$SUFFIX_DEFAULT}}" record="" kind="" rec="" parsed="" base="" src_major="" date="" runtime="" arch=""
  local provenance_rec="" provenance="" family="" bucket="" version="" arch_label="" source_label="" status_label=""
  local major_rank="" runtime_rank="" source_rank=""

  record="$(source_target_record_for_list "$src" "$suffix" 2>/dev/null || true)"
  [[ -n "$record" ]] || return 1
  kind="${record%%|*}"
  rec="${record#*|}"
  base="${rec%%|*}"
  parsed="${rec#*|}"
  src_major="${parsed%%|*}"
  parsed="${parsed#*|}"
  date="${parsed%%|*}"
  parsed="${parsed#*|}"
  runtime="${parsed%%|*}"
  arch="${parsed#*|}"

  if [[ "$kind" == "clone" ]]; then
    provenance="genvw-clone"
    family="genvw-clone"
  else
    provenance_rec="$(source_provenance_record_for_path "$src" 2>/dev/null || true)"
    provenance="${provenance_rec%%|*}"
    family="$(source_folder_family_for_path "$src")"
  fi

  bucket="$(source_policy_bucket_for_wizard "$src_major" "$date")"
  version="${src_major}-${date}"
  arch_label="$(source_target_arch_for_human "$arch")"
  if [[ "$kind" == "clone" ]]; then
    source_label="$(source_clone_family_label_for_human "$base")"
    status_label="$(source_target_status_label_for_kind "$kind" "$bucket")"
  else
    source_label="$(source_target_family_label_for_human "$kind" "$family" "$provenance")"
    status_label="$(source_human_state_for_source "$src" "$bucket")"
    local _srh_clone_base
    _srh_clone_base="$(source_clone_basename "$src" "$suffix" 2>/dev/null || true)"
    if [[ "$status_label" == "supported" && -n "$_srh_clone_base" && -n "${CTD:-}" && -d "${CTD}/${_srh_clone_base}" ]]; then
      status_label="installed"
    fi
  fi
  major_rank="$(source_sort_major_rank "$src_major")"
  runtime_rank="$(source_sort_runtime_rank "$runtime")"
  source_rank="$(source_sort_family_rank "$kind" "$family" "$provenance")"

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$kind" "$date" "$major_rank" "$runtime_rank" "$source_rank" "$base" \
    "$version" "$runtime" "$arch_label" "$source_label" "$status_label"
}

dwproton_display_mapping_record() {
  case "${1:-}" in
    dwproton-10.0-10) printf '%s\n' "10.0|20251222|slr" ;;
    dwproton-10.0-11) printf '%s\n' "10.0|20251222|slr" ;;
    dwproton-10.0-12) printf '%s\n' "10.0|20260101|slr" ;;
    dwproton-10.0-16) printf '%s\n' "10.0|20260127|slr" ;;
    dwproton-10.0-17) printf '%s\n' "10.0|20260207|slr" ;;
    dwproton-10.0-20) printf '%s\n' "10.0|20260228|slr" ;;
    dwproton-10.0-21) printf '%s\n' "10.0|20260312|slr" ;;
    dwproton-10.0-23) printf '%s\n' "10.0|20260330|slr" ;;
    dwproton-10.0-25) printf '%s\n' "10.0|20260424|slr" ;;
    dwproton-10.0-26) printf '%s\n' "unresolved|unresolved|unresolved" ;;
    dwproton-11.0-1) printf '%s\n' "11.0|20260429|proton-slr" ;;
    dwproton-11.0-2) printf '%s\n' "11.0|20260506|slr" ;;
    dwproton-11.0-3) printf '%s\n' "11.0|20260521|slr" ;;
    *) printf '%s\n' "unresolved|unresolved|unresolved" ;;
  esac
}

dwproton_known_folder() {
  case "${1:-}" in
    dwproton-10.0-10 | dwproton-10.0-11 | dwproton-10.0-12 | \
    dwproton-10.0-16 | dwproton-10.0-17 | dwproton-10.0-20 | \
    dwproton-10.0-21 | dwproton-10.0-23 | dwproton-10.0-25 | \
    dwproton-10.0-26 | dwproton-11.0-1 | dwproton-11.0-2 | dwproton-11.0-3)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

dwproton_folder_version() {
  local base="${1:-}"
  if [[ "$base" =~ ^dwproton-([0-9]+[.][0-9]+-[0-9]+)$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

dwproton_patch_shape_record_from_base() {
  case "${1:-}" in
    dwproton-10.0-10 | dwproton-10.0-11 | dwproton-10.0-12 | \
    dwproton-10.0-16 | dwproton-10.0-17 | dwproton-10.0-20 | \
    dwproton-10.0-21 | dwproton-10.0-23)
      printf '%s\n' "private_bool_loaddll|WINE_LOADDLL_REPLACE|1|0|0"
      return 0
      ;;
    dwproton-10.0-25 | dwproton-10.0-26 | dwproton-11.0-1)
      printf '%s\n' "private_tuple_upscaler_replace|WINE_UPSCALER_REPLACE|1|0|0"
      return 0
      ;;
    dwproton-11.0-2 | dwproton-11.0-3)
      printf '%s\n' "public_optiscaler_aware|WINE_UPSCALER_REPLACE|0|1|1"
      return 0
      ;;
  esac
  return 1
}

dwproton_upscaler_file_has_optiscaler_marker() {
  local up="${1:-}"
  [[ -f "$up" && ! -L "$up" ]] || return 1
  grep -Eq 'PROTON_USE_OPTISCALER|PROTON_OPTISCALER_NAME|WINE_OPTISCALER_NAME|setup_optiscaler' "$up"
}

dwproton_patch_shape_record_from_file() {
  local up="${1:-}" opt_markers=0
  [[ -f "$up" && ! -L "$up" ]] || return 1

  if dwproton_upscaler_file_has_optiscaler_marker "$up"; then
    opt_markers=1
  fi

  if ((opt_markers == 1)) && grep -Fq 'def setup_upscaler(' "$up" && grep -Fq 'WINE_UPSCALER_REPLACE' "$up"; then
    printf '%s\n' "public_optiscaler_aware|WINE_UPSCALER_REPLACE|0|1|1"
    return 0
  fi
  if grep -Fq 'def __setup_upscaler' "$up"; then
    if grep -Fq 'WINE_LOADDLL_REPLACE' "$up"; then
      printf '%s\n' "private_bool_loaddll|WINE_LOADDLL_REPLACE|1|0|${opt_markers}"
      return 0
    fi
    if grep -Fq 'WINE_UPSCALER_REPLACE' "$up"; then
      printf '%s\n' "private_tuple_upscaler_replace|WINE_UPSCALER_REPLACE|1|0|${opt_markers}"
      return 0
    fi
  fi

  return 1
}

dwproton_patch_capability_print_record() {
  local provider="${1:-not_dwproton}" source_base="${2:-unresolved}" dw_version="${3:-unresolved}"
  local known_version="${4:-0}" mapped_major="${5:-unresolved}" mapped_date="${6:-unresolved}"
  local mapped_runtime="${7:-unresolved}" shape="${8:-unknown}" replacement_env="${9:-unknown}"
  local private_setup="${10:-0}" public_setup="${11:-0}" opt_markers="${12:-0}"
  local reason="${13:-not_dwproton}"

  printf 'PROVIDER_FAMILY=%s\n' "$provider"
  printf 'SOURCE_BASE=%s\n' "$source_base"
  printf 'DW_VERSION=%s\n' "$dw_version"
  printf 'KNOWN_DW_VERSION=%s\n' "$known_version"
  printf 'MAPPED_BASE_MAJOR=%s\n' "$mapped_major"
  printf 'MAPPED_BASE_DATE=%s\n' "$mapped_date"
  printf 'MAPPED_BASE_RUNTIME=%s\n' "$mapped_runtime"
  printf 'UPSCALER_SHAPE=%s\n' "$shape"
  printf 'REPLACEMENT_ENV=%s\n' "$replacement_env"
  printf 'PRIVATE_SETUP_UPSCALER=%s\n' "$private_setup"
  printf 'PUBLIC_SETUP_UPSCALER=%s\n' "$public_setup"
  printf 'OPTISCALER_MARKERS_PRESENT=%s\n' "$opt_markers"
  printf 'OPTISCALER_ACTIVE_FOR_GENVW_FSR4=no\n'
  printf 'CAPABILITY_STATUS=unsupported\n'
  printf 'CAPABILITY_REASON=%s\n' "$reason"
}

dwproton_patch_capability_classification() {
  local src="${1:-}" base="" version="" known_version=0 map="" parsed=""
  local mapped_major="unresolved" mapped_date="unresolved" mapped_runtime="unresolved"
  local shape="unknown" replacement_env="unknown" private_setup=0 public_setup=0 opt_markers=0
  local shape_rec="" reason="dwproton_unknown_version" up=""

  base="${src##*/}"
  version="$(dwproton_folder_version "$base" 2>/dev/null || true)"
  if [[ -z "$version" || ! -d "$src" || -L "$src" ]]; then
    dwproton_patch_capability_print_record \
      "not_dwproton" "$base" "unresolved" 0 \
      "unresolved" "unresolved" "unresolved" \
      "unknown" "unknown" 0 0 0 "not_dwproton"
    return 1
  fi

  if dwproton_known_folder "$base"; then
    known_version=1
    map="$(dwproton_display_mapping_record "$base")"
    mapped_major="${map%%|*}"
    parsed="${map#*|}"
    mapped_date="${parsed%%|*}"
    mapped_runtime="${parsed#*|}"
  fi

  up="$src/protonfixes/upscalers.py"
  if dwproton_upscaler_file_has_optiscaler_marker "$up"; then
    opt_markers=1
  fi
  shape_rec="$(dwproton_patch_shape_record_from_base "$base" 2>/dev/null || true)"
  if [[ -z "$shape_rec" ]]; then
    shape_rec="$(dwproton_patch_shape_record_from_file "$up" 2>/dev/null || true)"
  fi
  if [[ -n "$shape_rec" ]]; then
    shape="${shape_rec%%|*}"
    parsed="${shape_rec#*|}"
    replacement_env="${parsed%%|*}"
    parsed="${parsed#*|}"
    private_setup="${parsed%%|*}"
    parsed="${parsed#*|}"
    public_setup="${parsed%%|*}"
    opt_markers="${parsed#*|}"
  fi

  if ((known_version == 1)); then
    if [[ "$shape" == "unknown" ]]; then
      reason="dwproton_unrecognized_shape"
    elif ((opt_markers == 1)); then
      reason="dwproton_optiscaler_boundary"
    else
      reason="dwproton_support_not_enabled"
    fi
  fi

  dwproton_patch_capability_print_record \
    "dwproton" "$base" "$version" "$known_version" \
    "$mapped_major" "$mapped_date" "$mapped_runtime" \
    "$shape" "$replacement_env" "$private_setup" "$public_setup" "$opt_markers" "$reason"
}

dwproton_record_value() {
  local record="${1:-}" key="${2:-}"
  [[ -n "$key" ]] || return 1
  printf '%s\n' "$record" | sed -nE "/^${key}=/{s/^${key}=//;p;q;}"
}

dwproton_fsr4_plan_component_is_safe() {
  local value="${1:-}"
  [[ -n "$value" ]] || return 1
  [[ "$value" != "." && "$value" != ".." ]] || return 1
  [[ "$value" != .* ]] || return 1
  [[ "$value" != */* && "$value" != *\\* ]] || return 1
  [[ "$value" != *..* ]] || return 1
  [[ ! "$value" =~ [[:space:]] ]] || return 1
  [[ "$value" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
}

dwproton_fsr4_plan_clone_basename_from_fields() {
  local provider="${1:-}" folder="${2:-}" version="${3:-}" arch="${4:-}" suffix="${5:-}"
  suffix="${suffix#-}"

  [[ "$provider" == "dwproton" ]] || return 1
  dwproton_fsr4_plan_component_is_safe "$folder" || return 1
  dwproton_fsr4_plan_component_is_safe "$version" || return 1
  dwproton_fsr4_plan_component_is_safe "$arch" || return 1
  dwproton_fsr4_plan_component_is_safe "$suffix" || return 1
  [[ "$version" =~ ^[0-9]+[.][0-9]+-[0-9]+$ ]] || return 1
  [[ ! "$folder" =~ ^dwproton-[0-9]+[.][0-9]+-[0-9]+-.+ ]] || return 1
  [[ "$folder" == "dwproton-$version" ]] || return 1
  [[ "$suffix" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 1

  local candidate="dwproton-${version}-${arch}-${suffix}"
  dwproton_fsr4_plan_component_is_safe "$candidate" || return 1
  printf '%s\n' "$candidate"
}

dwproton_vdf_internal_name_for_path() {
  local src="${1:-}" version="${2:-}" vdf="" token=""
  vdf="$src/compatibilitytool.vdf"
  [[ -n "$version" && -r "$vdf" ]] || return 1

  while IFS= read -r token; do
    if [[ "$token" =~ ^dwproton-([0-9]+[.][0-9]+-[0-9]+)-(x86_64(_v[1-4])?)$ ]]; then
      [[ "${BASH_REMATCH[1]}" == "$version" ]] || continue
      printf '%s\n' "$token"
      return 0
    fi
  done < <(awk -F'"' '{ for (i = 2; i <= NF; i += 2) print $i }' "$vdf" 2>/dev/null)

  return 1
}

dwproton_vdf_display_name_for_path() {
  local src="${1:-}" vdf="" display=""
  vdf="$src/compatibilitytool.vdf"
  [[ -r "$vdf" ]] || return 1
  display="$(awk -F'"' '$2=="display_name"{print $4; exit}' "$vdf" 2>/dev/null || true)"
  [[ -n "$display" ]] || return 1
  printf '%s\n' "$display"
}

dwproton_clone_owned_for_clean() {
  local path="${1:-}" suffix="${2:-}" base="" rec="" vdf=""
  local internal_found="" display_found="" install_path="" expected_display="" expected_version=""

  [[ -n "$path" && -n "$suffix" ]] || return 1
  [[ -d "$path" && ! -L "$path" ]] || return 1

  base="${path##*/}"
  rec="$(dwproton_clone_inventory_record_for_base "$base" "$suffix" 2>/dev/null)" || return 1
  [[ -n "$rec" ]] || return 1

  vdf="$path/compatibilitytool.vdf"
  [[ -r "$vdf" ]] || return 1

  internal_found="$(awk -F'"' '
    $2 == "compat_tools" { in_tools = 1; next }
    in_tools && $2 != "" && $2 != "install_path" && $2 != "display_name" {
      print $2
      exit
    }
  ' "$vdf" 2>/dev/null || true)"
  [[ "$internal_found" == "$base" ]] || return 1

  display_found="$(awk -F'"' '$2=="display_name"{print $4; exit}' "$vdf" 2>/dev/null || true)"
  expected_version="$(printf '%s\n' "$rec" | awk -F'\t' '{print $5}')"
  expected_display="$(steam_display_name_for_dwproton "$expected_version" 2>/dev/null || true)"
  if [[ "$display_found" != "$base" && ( -z "$expected_display" || "$display_found" != "$expected_display" ) ]]; then
    return 1
  fi

  install_path="$(awk -F'"' '$2=="install_path"{print $4; exit}' "$vdf" 2>/dev/null || true)"
  [[ "$install_path" == "." ]] || return 1

  [[ -f "$path/protonfixes/upscalers.py" ]] || return 1

  return 0
}

dwproton_fsr4_required_probe_class_for_shape() {
  case "${1:-}" in
    private_bool_loaddll) printf '%s\n' "private_bool_loaddll_runtime" ;;
    private_tuple_upscaler_replace) printf '%s\n' "private_tuple_upscaler_replace_runtime" ;;
    public_optiscaler_aware) printf '%s\n' "public_optiscaler_present_inactive_runtime" ;;
    *) printf '%s\n' "unknown" ;;
  esac
}

dwproton_fsr4_patch_plan_print_record() {
  local provider="${1:-not_dwproton}" source_base="${2:-unresolved}" dw_version="${3:-unresolved}"
  local known_version="${4:-0}" mapped_major="${5:-unresolved}" mapped_date="${6:-unresolved}"
  local mapped_runtime="${7:-unresolved}" shape="${8:-unknown}" replacement_env="${9:-unknown}"
  local opt_markers="${10:-0}" source_internal="${11:-unresolved}" source_display="${12:-unresolved}"
  local clone_basename="${13:-unresolved}" clone_internal="${14:-unresolved}" clone_display="${15:-unresolved}"
  local required_probe="${16:-unknown}" reason="${17:-not_dwproton}"

  printf 'PROVIDER_FAMILY=%s\n' "$provider"
  printf 'SOURCE_BASE=%s\n' "$source_base"
  printf 'DW_VERSION=%s\n' "$dw_version"
  printf 'KNOWN_DW_VERSION=%s\n' "$known_version"
  printf 'MAPPED_BASE_MAJOR=%s\n' "$mapped_major"
  printf 'MAPPED_BASE_DATE=%s\n' "$mapped_date"
  printf 'MAPPED_BASE_RUNTIME=%s\n' "$mapped_runtime"
  printf 'UPSCALER_SHAPE=%s\n' "$shape"
  printf 'REPLACEMENT_ENV=%s\n' "$replacement_env"
  printf 'OPTISCALER_MARKERS_PRESENT=%s\n' "$opt_markers"
  printf 'OPTISCALER_ACTIVE_FOR_GENVW_FSR4=no\n'
  printf 'SOURCE_INTERNAL_NAME=%s\n' "$source_internal"
  printf 'SOURCE_DISPLAY_NAME=%s\n' "$source_display"
  printf 'CLONE_BASENAME=%s\n' "$clone_basename"
  printf 'CLONE_INTERNAL_NAME=%s\n' "$clone_internal"
  printf 'CLONE_DISPLAY_NAME=%s\n' "$clone_display"
  printf 'INSTALL_PATH=.\n'
  printf 'REQUIRED_PROBE_CLASS=%s\n' "$required_probe"
  printf 'FSR4_OVERRIDE_STATUS=not_implemented\n'
  printf 'PATCH_PLAN_STATUS=blocked\n'
  printf 'PATCH_PLAN_REASON=%s\n' "$reason"
  printf 'SUPPORT_STATUS=unsupported\n'
}

dwproton_fsr4_patch_plan_record() {
  local src="${1:-}" suffix="${2:-${SUFFIX:-$SUFFIX_DEFAULT}}"
  local classification="" class_rc=0 provider="" source_base="" dw_version="" known_version=""
  local mapped_major="" mapped_date="" mapped_runtime="" shape="" replacement_env="" opt_markers=""
  local source_internal="unresolved" source_display="unresolved" arch="" clone_basename="unresolved"
  local clone_internal="unresolved" clone_display="unresolved" required_probe="unknown" reason=""
  local plan_rc=0

  classification="$(dwproton_patch_capability_classification "$src" 2>/dev/null)" || class_rc=$?
  provider="$(dwproton_record_value "$classification" PROVIDER_FAMILY)"
  source_base="$(dwproton_record_value "$classification" SOURCE_BASE)"
  dw_version="$(dwproton_record_value "$classification" DW_VERSION)"
  known_version="$(dwproton_record_value "$classification" KNOWN_DW_VERSION)"
  mapped_major="$(dwproton_record_value "$classification" MAPPED_BASE_MAJOR)"
  mapped_date="$(dwproton_record_value "$classification" MAPPED_BASE_DATE)"
  mapped_runtime="$(dwproton_record_value "$classification" MAPPED_BASE_RUNTIME)"
  shape="$(dwproton_record_value "$classification" UPSCALER_SHAPE)"
  replacement_env="$(dwproton_record_value "$classification" REPLACEMENT_ENV)"
  opt_markers="$(dwproton_record_value "$classification" OPTISCALER_MARKERS_PRESENT)"
  reason="$(dwproton_record_value "$classification" CAPABILITY_REASON)"

  if ((class_rc != 0)) || [[ "$provider" != "dwproton" ]]; then
    dwproton_fsr4_patch_plan_print_record \
      "${provider:-not_dwproton}" "${source_base:-${src##*/}}" "unresolved" 0 \
      "unresolved" "unresolved" "unresolved" \
      "unknown" "unknown" 0 \
      "unresolved" "unresolved" "unresolved" "unresolved" "unresolved" \
      "unknown" "not_dwproton"
    return 1
  fi

  source_internal="$(dwproton_vdf_internal_name_for_path "$src" "$dw_version" 2>/dev/null || true)"
  [[ -n "$source_internal" ]] || source_internal="unresolved"
  source_display="$(dwproton_vdf_display_name_for_path "$src" 2>/dev/null || true)"
  [[ -n "$source_display" ]] || source_display="unresolved"
  arch="$(dwproton_display_arch_for_path "$src" "$dw_version" 2>/dev/null || true)"

  if [[ -n "$arch" ]]; then
    if clone_basename="$(dwproton_fsr4_plan_clone_basename_from_fields "$provider" "$source_base" "$dw_version" "$arch" "$suffix" 2>/dev/null)"; then
      clone_internal="$clone_basename"
      clone_display="$(steam_display_name_for_dwproton "$dw_version" 2>/dev/null || true)"
      [[ -n "$clone_display" ]] || clone_display="$clone_basename"
    elif [[ "$known_version" == "1" ]]; then
      reason="unsafe_clone_candidate"
      plan_rc=1
    fi
  fi

  required_probe="$(dwproton_fsr4_required_probe_class_for_shape "$shape")"

  dwproton_fsr4_patch_plan_print_record \
    "$provider" "$source_base" "$dw_version" "$known_version" \
    "$mapped_major" "$mapped_date" "$mapped_runtime" \
    "$shape" "$replacement_env" "$opt_markers" \
    "$source_internal" "$source_display" "$clone_basename" "$clone_internal" "$clone_display" \
    "$required_probe" "$reason"
  return "$plan_rc"
}

dwproton_fsr4_writer_print_record() {
  local status="${1:-blocked}" class="${2:-unknown}" source_up="${3:-unresolved}" output_up="${4:-unresolved}"
  local dw_version="${5:-unresolved}" replacement_env="${6:-unknown}" opt_markers="${7:-0}"
  local override_status="${8:-not_implemented}" reason="${9:-dwproton_support_not_enabled}"

  printf 'WRITER_STATUS=%s\n' "$status"
  printf 'WRITER_CLASS=%s\n' "$class"
  printf 'SOURCE_UPSCALERS=%s\n' "$source_up"
  printf 'OUTPUT_UPSCALERS=%s\n' "$output_up"
  printf 'DW_VERSION=%s\n' "$dw_version"
  printf 'REPLACEMENT_ENV=%s\n' "$replacement_env"
  printf 'REPLACEMENT_VALUE=fsr4\n'
  printf 'OPTISCALER_MARKERS_PRESENT=%s\n' "$opt_markers"
  printf 'OPTISCALER_ACTIVE_FOR_GENVW_FSR4=no\n'
  printf 'FSR4_OVERRIDE_STATUS=%s\n' "$override_status"
  printf 'PATCH_PLAN_STATUS=blocked\n'
  printf 'SUPPORT_STATUS=unsupported\n'
  printf 'WRITER_REASON=%s\n' "$reason"
}

dwproton_fsr4_source_paths_for_writer() {
  local source="${1:-}" out_root_var="${2:-}" out_upscalers_var="${3:-}"
  local resolved_root="" resolved_upscalers=""

  if [[ -d "$source" && ! -L "$source" ]]; then
    resolved_root="$source"
    resolved_upscalers="$source/protonfixes/upscalers.py"
  elif [[ "$source" == */protonfixes/upscalers.py ]]; then
    resolved_upscalers="$source"
    resolved_root="${source%/protonfixes/upscalers.py}"
  else
    resolved_upscalers="$source"
    if [[ "$source" == */* ]]; then
      resolved_root="${source%/*}"
    else
      resolved_root=""
    fi
  fi

  printf -v "$out_root_var" '%s' "$resolved_root"
  printf -v "$out_upscalers_var" '%s' "$resolved_upscalers"
}

dwproton_fsr4_writer_output_path_is_safe() {
  local output_path="${1:-}" output_root="${2:-}"
  local root_real="" output_real="" parent="" probe="" probe_real=""

  [[ -n "$output_path" && "$output_path" == /* && "$output_path" != "/" ]] || return 1
  [[ -n "$output_root" && "$output_root" == /* && "$output_root" != "/" ]] || return 1
  case "$output_path" in
    */../*|*/..) return 1 ;;
  esac
  [[ -d "$output_root" && ! -L "$output_root" ]] || return 1
  [[ ! -L "$output_path" ]] || return 1
  [[ ! -e "$output_path" || -f "$output_path" ]] || return 1

  root_real="$(readlink -f -- "$output_root" 2>/dev/null)" || return 1
  [[ -n "$root_real" && "$root_real" != "/" ]] || return 1
  output_real="$(readlink -m -- "$output_path" 2>/dev/null)" || return 1
  case "$output_real" in
    "$root_real"/*) ;;
    *) return 1 ;;
  esac

  parent="${output_path%/*}"
  [[ -n "$parent" && "$parent" != "/" ]] || return 1
  probe="$parent"
  while [[ ! -e "$probe" && "$probe" != "/" ]]; do
    probe="${probe%/*}"
  done
  [[ -n "$probe" && "$probe" != "/" && -d "$probe" && ! -L "$probe" ]] || return 1
  probe_real="$(readlink -f -- "$probe" 2>/dev/null)" || return 1
  case "$probe_real" in
    "$root_real"|"$root_real"/*) return 0 ;;
    *) return 1 ;;
  esac
}

dwproton_fsr4_inject_source_backend_disabled() {
  local upscalers_path="${1:-}" shape="${2:-unknown}" selected_version="${3:-4.1.0}"
  local amd_sources="" google_sources=""

  [[ -f "$upscalers_path" && ! -L "$upscalers_path" ]] || return 1
  amd_sources="$(dwproton_fsr4_amd_source_allowlist_python_entries)"
  google_sources="$(fsr4_trusted_sources_python_entries)"

  python3 - "$upscalers_path" "$shape" "$selected_version" "$amd_sources" "$google_sources" <<'PY'
import ast
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
shape = sys.argv[2]
selected_version = sys.argv[3]
amd_sources = sys.argv[4]
google_sources = sys.argv[5]
amd_sources = amd_sources.replace("{{", "{").replace("}}", "}")
google_sources = google_sources.replace("{{", "{").replace("}}", "}")

HELPER_START = "# gENVW DW-Proton FSR4 source backend start"
HELPER_END = "# gENVW DW-Proton FSR4 source backend end"

def module_tree(src: str) -> ast.Module:
    return ast.parse(src)

def find_function_node(src: str, name: str) -> ast.FunctionDef:
    tree = module_tree(src)
    for node in tree.body:
        if isinstance(node, ast.FunctionDef) and node.name == name:
            return node
    raise SystemExit(f"ERROR: Could not find def {name}(...)")

def replace_block_by_lines(src: str, start_lineno: int, end_lineno: int, new_block: str) -> str:
    lines = src.splitlines(True)
    replacement = new_block.rstrip("\n") + "\n"
    lines[start_lineno - 1:end_lineno] = [replacement]
    return "".join(lines)

def replace_function(src: str, name: str, new_block: str) -> str:
    node = find_function_node(src, name)
    return replace_block_by_lines(src, node.lineno, node.end_lineno, new_block)

def replace_or_append_function(src: str, name: str, new_block: str) -> str:
    try:
        return replace_function(src, name, new_block)
    except SystemExit:
        return src.rstrip("\n") + "\n\n" + new_block.rstrip("\n") + "\n"

def helper_block() -> str:
    template = """__HELPER_START__
import hashlib as _GENVW_hashlib
import json as _GENVW_json
import os as _GENVW_os
import shutil as _GENVW_shutil
import urllib.request as _GENVW_urllib_request
from pathlib import Path as _GENVW_Path
from urllib.parse import urlparse as _GENVW_urlparse

GENVW_DWPROTON_AMD_SOURCE_IDENTITY_TRUST_IS_TEMPORARY = True
GENVW_DWPROTON_FSR4_DEFAULT_VERSION = __SELECTED_VERSION__
GENVW_DWPROTON_AMD_SOURCE_ALLOWLIST = {
__AMD_SOURCES__
}
GENVW_DWPROTON_GOOGLE_SHA256_SOURCES = {
__GOOGLE_SOURCES__
}

def _genvw_dwproton_log(level: str, message: str) -> None:
    logger = globals().get('log')
    fn = getattr(logger, level, None)
    if callable(fn):
        fn(message)

def _genvw_dwproton_cache_dir() -> _GENVW_Path:
    cfg = globals().get('config')
    cache_root = getattr(getattr(cfg, 'path', None), 'cache_dir', None)
    if cache_root is None:
        cache_root = _GENVW_Path(_GENVW_os.environ.get('GENVW_TEST_CACHE_DIR', '.'))
    return _GENVW_Path(cache_root).joinpath('upscalers')

def _genvw_dwproton_resolve_fsr4_version(version: str) -> str:
    requested = str(version or '').strip() or 'default'
    if requested == 'default':
        requested = GENVW_DWPROTON_FSR4_DEFAULT_VERSION
    if requested in GENVW_DWPROTON_AMD_SOURCE_ALLOWLIST and requested in GENVW_DWPROTON_GOOGLE_SHA256_SOURCES:
        return requested
    raise ValueError(f'Unsupported gENVW DW-Proton FSR4 version: {{requested}}')

def _genvw_dwproton_amd_identity_ok(version: str, metadata: dict) -> bool:
    expected = GENVW_DWPROTON_AMD_SOURCE_ALLOWLIST.get(version)
    if not expected:
        return False
    url = str(metadata.get('download_url', ''))
    parsed = _GENVW_urlparse(url)
    token = str(expected.get('source_token', ''))
    expected_path = f'/dir/bin/amdxcffx64.dll/{{token}}/amdxcffx64.dll'
    return (
        parsed.scheme == 'https'
        and parsed.netloc == 'download.amd.com'
        and parsed.path == expected_path
        and _GENVW_Path(parsed.path).name == 'amdxcffx64.dll'
        and metadata.get('version') == version
        and metadata.get('source_token') == token
    )

def _genvw_dwproton_amd_source(version: str) -> dict:
    version = _genvw_dwproton_resolve_fsr4_version(version)
    item = dict(GENVW_DWPROTON_AMD_SOURCE_ALLOWLIST[version])
    item.update({
        'genvw_version': version,
        'source_kind': 'amd_source_allowlisted',
        'source_trust': 'temporary_source_identity',
        'md5_hash': None,
        'zip_md5_hash': None,
        'sha256_hash': None,
        'size': None,
        'genvw_default_version': GENVW_DWPROTON_FSR4_DEFAULT_VERSION,
        'cache_name': f'amdxcffx64_v{{version}}_amd_source_allowlisted.dll',
    })
    if not _genvw_dwproton_amd_identity_ok(version, item):
        raise ValueError(f'AMD FSR4 source identity mismatch for {{version}}')
    return item

def _genvw_dwproton_google_source(version: str) -> dict:
    version = _genvw_dwproton_resolve_fsr4_version(version)
    item = dict(GENVW_DWPROTON_GOOGLE_SHA256_SOURCES[version])
    item.update({
        'genvw_version': version,
        'source_kind': 'google_sha256_verified',
        'source_trust': 'sha256_size_mz',
        'md5_hash': None,
        'zip_md5_hash': None,
        'sha256_hash': item['sha256'],
        'genvw_default_version': GENVW_DWPROTON_FSR4_DEFAULT_VERSION,
        'cache_name': f'amdxcffx64_v{{version}}_google_sha256_verified.dll',
    })
    return item

def _genvw_dwproton_cache_path(cache_dir: _GENVW_Path, metadata: dict) -> _GENVW_Path:
    return _GENVW_Path(cache_dir).joinpath(metadata['cache_name'])

def _genvw_dwproton_cache_meta_path(cached_file: _GENVW_Path) -> _GENVW_Path:
    return cached_file.with_name(cached_file.name + '.genvw.json')

def _genvw_dwproton_file_fingerprint(path: _GENVW_Path) -> tuple[str, int]:
    digest = _GENVW_hashlib.sha256()
    with path.open('rb') as file_fd:
        while True:
            chunk = file_fd.read(1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest().lower(), path.stat().st_size

def _genvw_dwproton_basic_dll_ok(path: _GENVW_Path) -> bool:
    try:
        if not path.is_file() or path.stat().st_size < 1024:
            return False
        with path.open('rb') as file_fd:
            return file_fd.read(2) == b'MZ'
    except OSError:
        return False

def _genvw_dwproton_google_dll_ok(path: _GENVW_Path, metadata: dict) -> bool:
    try:
        if not _genvw_dwproton_basic_dll_ok(path):
            return False
        if path.stat().st_size != int(metadata['size']):
            return False
        got_sha, _ = _genvw_dwproton_file_fingerprint(path)
        return got_sha == str(metadata['sha256_hash']).lower()
    except (OSError, TypeError, ValueError, KeyError):
        return False

def _genvw_dwproton_write_cache_meta(cached_file: _GENVW_Path, metadata: dict) -> None:
    observed_sha, observed_size = _genvw_dwproton_file_fingerprint(cached_file)
    record = {
        'version': metadata['genvw_version'],
        'genvw_version': metadata['genvw_version'],
        'source_kind': metadata['source_kind'],
        'source_trust': metadata['source_trust'],
        'source_url': metadata['download_url'],
        'source_token': metadata.get('source_token', ''),
        'temporary_amd_source_identity_trust': metadata['source_kind'] == 'amd_source_allowlisted',
        'genvw_default_version': GENVW_DWPROTON_FSR4_DEFAULT_VERSION,
        'observed_sha256': observed_sha,
        'observed_size': observed_size,
    }
    if metadata['source_kind'] == 'google_sha256_verified':
        record['sha256_hash'] = metadata['sha256_hash']
        record['size'] = metadata['size']
    _genvw_dwproton_cache_meta_path(cached_file).write_text(_GENVW_json.dumps(record, sort_keys=True), encoding='utf-8')

def _genvw_dwproton_read_cache_meta(cached_file: _GENVW_Path) -> dict:
    try:
        return _GENVW_json.loads(_genvw_dwproton_cache_meta_path(cached_file).read_text(encoding='utf-8'))
    except Exception:
        return {}

def _genvw_dwproton_cached_file_ok(cached_file: _GENVW_Path, metadata: dict) -> bool:
    record = _genvw_dwproton_read_cache_meta(cached_file)
    if record.get('genvw_version') != metadata['genvw_version']:
        return False
    if record.get('source_kind') != metadata['source_kind']:
        return False
    if record.get('source_url') != metadata['download_url']:
        return False
    if metadata['source_kind'] == 'amd_source_allowlisted':
        if record.get('source_token') != metadata.get('source_token'):
            return False
        if not _genvw_dwproton_amd_identity_ok(metadata['genvw_version'], metadata):
            return False
        return _genvw_dwproton_basic_dll_ok(cached_file)
    if metadata['source_kind'] == 'google_sha256_verified':
        return _genvw_dwproton_google_dll_ok(cached_file, metadata)
    return False

def _genvw_dwproton_download_to_cache(metadata: dict, cached_file: _GENVW_Path) -> None:
    cached_file.parent.mkdir(parents=True, exist_ok=True)
    tmp_file = cached_file.with_name(cached_file.name + f'.tmp.{{_GENVW_os.getpid()}}')
    request = _GENVW_urllib_request.Request(metadata['download_url'])
    try:
        tmp_file.unlink(missing_ok=True)
        with _GENVW_urllib_request.urlopen(request, timeout=60) as response:
            with tmp_file.open('wb') as dst_fd:
                _GENVW_shutil.copyfileobj(response, dst_fd)
        if metadata['source_kind'] == 'amd_source_allowlisted':
            if not _genvw_dwproton_amd_identity_ok(metadata['genvw_version'], metadata):
                raise RuntimeError('AMD FSR4 source identity mismatch')
            if not _genvw_dwproton_basic_dll_ok(tmp_file):
                raise RuntimeError('AMD FSR4 source-accepted bytes failed basic DLL sanity')
        elif metadata['source_kind'] == 'google_sha256_verified':
            if not _genvw_dwproton_google_dll_ok(tmp_file, metadata):
                raise RuntimeError('Google FSR4 fallback failed SHA-256/size/MZ validation')
        else:
            raise RuntimeError(f'Unknown FSR4 source kind: {{metadata.get("source_kind")}}')
        tmp_file.replace(cached_file)
        _genvw_dwproton_write_cache_meta(cached_file, metadata)
    except Exception:
        tmp_file.unlink(missing_ok=True)
        raise

def _genvw_dwproton_select_cached_or_downloaded(cache_dir: _GENVW_Path, version: str) -> tuple[_GENVW_Path, dict]:
    version = _genvw_dwproton_resolve_fsr4_version(version)
    google_meta = _genvw_dwproton_google_source(version)
    try:
        amd_meta = _genvw_dwproton_amd_source(version)
    except Exception as exc:
        amd_meta = None
        _genvw_dwproton_log('warn', f'AMD FSR4 source-allowlisted primary unavailable for {{version}}: {{exc!r}}')
    for metadata in tuple(m for m in (amd_meta, google_meta) if m is not None):
        cached_file = _genvw_dwproton_cache_path(cache_dir, metadata)
        if _genvw_dwproton_cached_file_ok(cached_file, metadata):
            return cached_file, metadata
    if amd_meta is not None:
        amd_cached = _genvw_dwproton_cache_path(cache_dir, amd_meta)
        try:
            _genvw_dwproton_download_to_cache(amd_meta, amd_cached)
            if _genvw_dwproton_cached_file_ok(amd_cached, amd_meta):
                return amd_cached, amd_meta
        except Exception as exc:
            _genvw_dwproton_log('warn', f'AMD FSR4 source-allowlisted primary failed for {{version}}: {{exc!r}}')
    google_cached = _genvw_dwproton_cache_path(cache_dir, google_meta)
    _genvw_dwproton_download_to_cache(google_meta, google_cached)
    if _genvw_dwproton_cached_file_ok(google_cached, google_meta):
        return google_cached, google_meta
    raise RuntimeError(f'No valid exact-version FSR4 source for {{version}}')

def _genvw_dwproton_mark_file_metadata(file: dict, metadata: dict) -> None:
    file['version'] = metadata['genvw_version']
    file['genvw_version'] = metadata['genvw_version']
    file['source_kind'] = metadata['source_kind']
    file['source_trust'] = metadata['source_trust']
    file['source_url'] = metadata['download_url']
    file['source_token'] = metadata.get('source_token', '')
    file['temporary_amd_source_identity_trust'] = metadata['source_kind'] == 'amd_source_allowlisted'
    file['genvw_default_version'] = GENVW_DWPROTON_FSR4_DEFAULT_VERSION
    if metadata['source_kind'] == 'google_sha256_verified':
        file['sha256_hash'] = metadata['sha256_hash']
        file['size'] = metadata['size']
    else:
        file['sha256_hash'] = None
        file['size'] = None

def _genvw_dwproton_build_entry(version: str) -> dict:
    resolved = _genvw_dwproton_resolve_fsr4_version(version)
    item = dict(GENVW_DWPROTON_AMD_SOURCE_ALLOWLIST.get(resolved, {}))
    return {
        'version': resolved,
        'download_url': item.get('download_url', ''),
        'md5_hash': None,
        'zip_md5_hash': None,
        'genvw_version': resolved,
        'source_kind': 'amd_source_allowlisted',
        'source_trust': 'temporary_source_identity',
        'source_token': item.get('source_token', ''),
        'temporary_amd_source_identity_trust': True,
        'genvw_default_version': GENVW_DWPROTON_FSR4_DEFAULT_VERSION,
    }
__HELPER_END__"""
    template = template.replace("{{", "{").replace("}}", "}")
    return (
        template
        .replace("__HELPER_START__", HELPER_START)
        .replace("__HELPER_END__", HELPER_END)
        .replace("__SELECTED_VERSION__", repr(selected_version))
        .replace("__AMD_SOURCES__", amd_sources)
        .replace("__GOOGLE_SOURCES__", google_sources)
    )

def inject_helper(src: str) -> str:
    block = helper_block().rstrip("\n") + "\n\n"
    if HELPER_START in src and HELPER_END in src:
        pattern = re.compile(re.escape(HELPER_START) + r'.*?' + re.escape(HELPER_END) + r'\n*', re.S)
        return pattern.sub(block, src, count=1)
    try:
        node = find_function_node(src, "__get_fsr4_dlls")
        lines = src.splitlines(True)
        lines.insert(node.lineno - 1, block)
        return "".join(lines)
    except SystemExit:
        return src.rstrip("\n") + "\n\n" + block

def get_fsr4_block() -> str:
    return """def __get_fsr4_dlls(version: str = 'default') -> dict:
    resolved = _genvw_dwproton_resolve_fsr4_version(version)
    return {
        'drive_c/windows/system32/amdxcffx64.dll': _genvw_dwproton_build_entry(resolved),
    }"""

def download_fsr4_block() -> str:
    return """def __download_fsr4(file: dict, cache: Path, dst: Path) -> None:
    version = _genvw_dwproton_resolve_fsr4_version(file.get('genvw_version') or file.get('version') or 'default')
    cached_file, metadata = _genvw_dwproton_select_cached_or_downloaded(_GENVW_Path(cache), version)
    _genvw_dwproton_mark_file_metadata(file, metadata)
    dst.parent.mkdir(parents=True, exist_ok=True)
    _GENVW_shutil.copy(cached_file, dst)"""

def check_file_block() -> str:
    return """def __check_upscaler_file(
    prefix_dir: str, dst: str, file: dict, version: dict, ignore_version: bool
) -> bool:
    target = _GENVW_Path(prefix_dir, dst)
    if target.is_symlink():
        _genvw_dwproton_log('debug', f'Removing stale symlink "{dst}"')
        target.unlink()
    if target.exists() and target.stat().st_size < 1024:
        _genvw_dwproton_log('debug', f'Removing stale file "{dst}"')
        target.unlink()
    if not target.exists():
        _genvw_dwproton_log('warn', f'Missing file from prefix "{dst}"')
        return False

    file_version = _genvw_dwproton_resolve_fsr4_version(file.get('genvw_version') or file.get('version') or 'default')
    entry_version = version.get('genvw_version') or version.get('version')
    if entry_version != file_version:
        _genvw_dwproton_log('warn', f'Version mismatch between gENVW metadata and prefix "{dst}"')
        return False
    source_kind = version.get('source_kind', '')
    if source_kind == 'amd_source_allowlisted':
        metadata = _genvw_dwproton_amd_source(file_version)
        if version.get('source_url') != metadata['download_url'] or version.get('source_token') != metadata['source_token']:
            return False
        return _genvw_dwproton_basic_dll_ok(target)
    if source_kind == 'google_sha256_verified':
        metadata = _genvw_dwproton_google_source(file_version)
        return _genvw_dwproton_google_dll_ok(target, metadata)

    version_md5 = version.get('md5_hash')
    if version_md5 is not None:
        with target.open('rb') as dst_fd:
            dst_md5 = _GENVW_hashlib.md5(dst_fd.read()).hexdigest().lower()
        if dst_md5 != str(version_md5).lower():
            _genvw_dwproton_log('warn', f'MD5 checksum mismatch between version and prefix "{dst}"')
            return False
    if not ignore_version and version.get('version') != file.get('version'):
        _genvw_dwproton_log('warn', f'Version mismatch between configuration and prefix "{dst}"')
        return False
    return True"""

def check_files_block() -> str:
    if shape == "private_tuple_upscaler_replace":
        return_value = """    dll_names = set([_GENVW_Path(f).name for f in files.keys()])
    paths = tuple(path for path in files.keys())
    parts = list(_GENVW_Path(paths[0]).parts)
    parts.remove(_GENVW_Path(paths[0]).name)
    parts.remove('drive_c')
    parts.insert(0, 'c:')
    windows_path = '\\\\'.join(parts)
    return all(valid_files), dll_names, windows_path"""
    else:
        return_value = "    return all(valid_files)"
    return f"""def __check_upscaler_files(
    prefix_dir: str, files: dict, version_file: str, ignore_version: bool
):
    try:
        with open(version_file, encoding='utf-8') as version_fd:
            version = _GENVW_json.loads(version_fd.read())
        for dst in files.keys():
            entry = version[dst]
            _ = entry.get('version')
            _ = entry.get('genvw_version')
            _ = entry.get('source_kind')
    except Exception as e:
        _genvw_dwproton_log('warn', f'Error while reading version file "{{version_file}}"')
        _genvw_dwproton_log('warn', repr(e))
        {'return False, set(), ' + repr('') if shape == 'private_tuple_upscaler_replace' else 'return False'}

    valid_files = tuple(
        __check_upscaler_file(prefix_dir, dst, files[dst], version[dst], ignore_version)
        for dst in files.keys()
    )
{return_value}"""

def download_files_block() -> str:
    return """def __download_upscaler_files(
    prefix_dir: str,
    files: dict,
    dlfunc,
    version_file: str,
) -> bool:
    cache_dir = _genvw_dwproton_cache_dir()
    version = {}
    for dst in files.keys():
        _genvw_dwproton_log('info', f'Downloading upscaler file "{_GENVW_os.path.basename(dst)}"')
        file = _GENVW_Path(prefix_dir, dst)
        temp = _GENVW_Path(prefix_dir, dst + '.old')
        try:
            if file.exists() or file.is_symlink():
                file.rename(temp)
            dlfunc(files[dst], cache_dir, file)
            temp.unlink(missing_ok=True)
        except Exception as e:
            _genvw_dwproton_log('crit', f'Error while downloading file "{file.name}"')
            _genvw_dwproton_log('crit', repr(e))
            file.unlink(missing_ok=True)
            if temp.exists() or temp.is_symlink():
                temp.rename(file)
            return False
        observed_sha, observed_size = _genvw_dwproton_file_fingerprint(file)
        record = {
            'version': files[dst]['genvw_version'],
            'genvw_version': files[dst]['genvw_version'],
            'source_kind': files[dst]['source_kind'],
            'source_trust': files[dst]['source_trust'],
            'source_url': files[dst]['source_url'],
            'source_token': files[dst].get('source_token', ''),
            'temporary_amd_source_identity_trust': files[dst]['source_kind'] == 'amd_source_allowlisted',
            'genvw_default_version': GENVW_DWPROTON_FSR4_DEFAULT_VERSION,
            'observed_sha256': observed_sha,
            'observed_size': observed_size,
        }
        if files[dst]['source_kind'] == 'google_sha256_verified':
            record['sha256_hash'] = files[dst]['sha256_hash']
            record['size'] = files[dst]['size']
        version[dst] = record
    with open(version_file, 'w', encoding='utf-8') as version_fd:
        version_fd.write(_GENVW_json.dumps(version, sort_keys=True))
    return True"""

src = path.read_text(encoding="utf-8", errors="replace")
src2 = inject_helper(src)
src2 = replace_or_append_function(src2, "__get_fsr4_dlls", get_fsr4_block())
src2 = replace_or_append_function(src2, "__download_fsr4", download_fsr4_block())
src2 = replace_or_append_function(src2, "__check_upscaler_file", check_file_block())
src2 = replace_or_append_function(src2, "__check_upscaler_files", check_files_block())
src2 = replace_or_append_function(src2, "__download_upscaler_files", download_files_block())
path.write_text(src2, encoding="utf-8")
PY
}

dwproton_fsr4_write_patched_upscalers_disabled() {
  local source_arg="${1:-}" output_path="${2:-}" output_root="${3:-}"
  local suffix="${4:-${SUFFIX:-$SUFFIX_DEFAULT}}" selected_version="${5:-4.1.0}"
  local source_root="" source_upscalers="" plan="" plan_rc=0 provider="" known_version=""
  local dw_version="unresolved" shape="unknown" replacement_env="unknown" opt_markers=0 reason=""
  local writer_status="blocked" override_status="not_implemented" tmp_path="" output_dir=""

  dwproton_fsr4_source_paths_for_writer "$source_arg" source_root source_upscalers

  plan="$(dwproton_fsr4_patch_plan_record "$source_root" "$suffix" 2>/dev/null)" || plan_rc=$?
  provider="$(dwproton_record_value "$plan" PROVIDER_FAMILY)"
  known_version="$(dwproton_record_value "$plan" KNOWN_DW_VERSION)"
  dw_version="$(dwproton_record_value "$plan" DW_VERSION)"
  shape="$(dwproton_record_value "$plan" UPSCALER_SHAPE)"
  replacement_env="$(dwproton_record_value "$plan" REPLACEMENT_ENV)"
  opt_markers="$(dwproton_record_value "$plan" OPTISCALER_MARKERS_PRESENT)"
  reason="$(dwproton_record_value "$plan" PATCH_PLAN_REASON)"

  [[ -n "$dw_version" ]] || dw_version="unresolved"
  [[ -n "$shape" ]] || shape="unknown"
  [[ -n "$replacement_env" ]] || replacement_env="unknown"
  [[ -n "$opt_markers" ]] || opt_markers=0
  [[ -n "$reason" ]] || reason="dwproton_support_not_enabled"

  if ((plan_rc != 0)) || [[ "$provider" != "dwproton" ]]; then
    dwproton_fsr4_writer_print_record \
      "skipped" "unknown" "${source_upscalers:-unresolved}" "${output_path:-unresolved}" \
      "unresolved" "unknown" 0 "not_implemented" "not_dwproton"
    return 1
  fi

  if [[ "$known_version" != "1" ]]; then
    dwproton_fsr4_writer_print_record \
      "blocked" "$shape" "${source_upscalers:-unresolved}" "${output_path:-unresolved}" \
      "$dw_version" "$replacement_env" "$opt_markers" "not_implemented" "dwproton_unknown_version"
    return 1
  fi

  if [[ "$shape" == "unknown" ]]; then
    dwproton_fsr4_writer_print_record \
      "blocked" "unknown" "${source_upscalers:-unresolved}" "${output_path:-unresolved}" \
      "$dw_version" "unknown" "$opt_markers" "not_implemented" "dwproton_unrecognized_shape"
    return 1
  fi

  [[ -f "$source_upscalers" && ! -L "$source_upscalers" ]] || {
    dwproton_fsr4_writer_print_record \
      "blocked" "$shape" "${source_upscalers:-unresolved}" "${output_path:-unresolved}" \
      "$dw_version" "$replacement_env" "$opt_markers" "not_implemented" "dwproton_unrecognized_shape"
    return 1
  }

  [[ "$selected_version" =~ ^[0-9]+[.][0-9]+[.][0-9]+$ ]] || {
    dwproton_fsr4_writer_print_record \
      "blocked" "$shape" "$source_upscalers" "${output_path:-unresolved}" \
      "$dw_version" "$replacement_env" "$opt_markers" "not_implemented" "dwproton_support_not_enabled"
    return 1
  }

  if ! dwproton_fsr4_writer_output_path_is_safe "$output_path" "$output_root"; then
    dwproton_fsr4_writer_print_record \
      "blocked" "$shape" "$source_upscalers" "${output_path:-unresolved}" \
      "$dw_version" "$replacement_env" "$opt_markers" "not_implemented" "unsafe_output_path"
    return 1
  fi

  output_dir="${output_path%/*}"
  mkdir -p -- "$output_dir" || {
    dwproton_fsr4_writer_print_record \
      "blocked" "$shape" "$source_upscalers" "$output_path" \
      "$dw_version" "$replacement_env" "$opt_markers" "not_implemented" "unsafe_output_path"
    return 1
  }
  if ! dwproton_fsr4_writer_output_path_is_safe "$output_path" "$output_root"; then
    dwproton_fsr4_writer_print_record \
      "blocked" "$shape" "$source_upscalers" "$output_path" \
      "$dw_version" "$replacement_env" "$opt_markers" "not_implemented" "unsafe_output_path"
    return 1
  fi

  tmp_path="${output_path}.tmp.$$"
  [[ ! -e "$tmp_path" && ! -L "$tmp_path" ]] || {
    dwproton_fsr4_writer_print_record \
      "blocked" "$shape" "$source_upscalers" "$output_path" \
      "$dw_version" "$replacement_env" "$opt_markers" "not_implemented" "unsafe_output_path"
    return 1
  }

  cp -- "$source_upscalers" "$tmp_path" || {
    rm -f -- "$tmp_path"
    dwproton_fsr4_writer_print_record \
      "blocked" "$shape" "$source_upscalers" "$output_path" \
      "$dw_version" "$replacement_env" "$opt_markers" "not_implemented" "dwproton_unrecognized_shape"
    return 1
  }
  dwproton_fsr4_inject_source_backend_disabled "$tmp_path" "$shape" "$selected_version" || {
    rm -f -- "$tmp_path"
    dwproton_fsr4_writer_print_record \
      "blocked" "$shape" "$source_upscalers" "$output_path" \
      "$dw_version" "$replacement_env" "$opt_markers" "not_implemented" "dwproton_unrecognized_shape"
    return 1
  }
  {
    printf '\nGENVW_DWPROTON_TRANSFORM_CLASS = "%s"\n' "$shape"
    printf 'GENVW_DWPROTON_WRITER_SELECTED_FSR4_VERSION = "%s"\n' "$selected_version"
  } >>"$tmp_path" || {
    rm -f -- "$tmp_path"
    dwproton_fsr4_writer_print_record \
      "blocked" "$shape" "$source_upscalers" "$output_path" \
      "$dw_version" "$replacement_env" "$opt_markers" "not_implemented" "dwproton_unrecognized_shape"
    return 1
  }
  python3 -m py_compile "$tmp_path" >/dev/null 2>&1 || {
    rm -f -- "$tmp_path"
    dwproton_fsr4_writer_print_record \
      "blocked" "$shape" "$source_upscalers" "$output_path" \
      "$dw_version" "$replacement_env" "$opt_markers" "not_implemented" "dwproton_unrecognized_shape"
    return 1
  }
  mv -f -- "$tmp_path" "$output_path" || {
    rm -f -- "$tmp_path"
    dwproton_fsr4_writer_print_record \
      "blocked" "$shape" "$source_upscalers" "$output_path" \
      "$dw_version" "$replacement_env" "$opt_markers" "not_implemented" "unsafe_output_path"
    return 1
  }

  writer_status="ready"
  override_status="prototype_only"
  reason="dwproton_writer_test_only"

  dwproton_fsr4_writer_print_record \
    "$writer_status" "$shape" "$source_upscalers" "$output_path" \
    "$dw_version" "$replacement_env" "$opt_markers" "$override_status" "$reason"
}

dwproton_fsr4_clone_assembly_print_record() {
  local status="${1:-blocked}" assembly_class="${2:-unknown}" source_root="${3:-unresolved}" clone_root="${4:-unresolved}"
  local clone_basename="${5:-unresolved}" clone_internal="${6:-unresolved}" clone_display="${7:-unresolved}"
  local vdf_path="${8:-unresolved}" patched_upscalers="${9:-unresolved}" writer_status="${10:-blocked}"
  local replacement_env="${11:-unknown}" opt_markers="${12:-0}" override_status="${13:-not_implemented}"
  local reason="${14:-dwproton_support_not_enabled}"

  printf 'ASSEMBLY_STATUS=%s\n' "$status"
  printf 'ASSEMBLY_CLASS=%s\n' "$assembly_class"
  printf 'SOURCE_ROOT=%s\n' "$source_root"
  printf 'CLONE_ROOT=%s\n' "$clone_root"
  printf 'CLONE_BASENAME=%s\n' "$clone_basename"
  printf 'CLONE_INTERNAL_NAME=%s\n' "$clone_internal"
  printf 'CLONE_DISPLAY_NAME=%s\n' "$clone_display"
  printf 'VDF_PATH=%s\n' "$vdf_path"
  printf 'PATCHED_UPSCALERS=%s\n' "$patched_upscalers"
  printf 'WRITER_STATUS=%s\n' "$writer_status"
  printf 'REPLACEMENT_ENV=%s\n' "$replacement_env"
  printf 'REPLACEMENT_VALUE=fsr4\n'
  printf 'OPTISCALER_MARKERS_PRESENT=%s\n' "$opt_markers"
  printf 'OPTISCALER_ACTIVE_FOR_GENVW_FSR4=no\n'
  printf 'FSR4_OVERRIDE_STATUS=%s\n' "$override_status"
  printf 'PATCH_PLAN_STATUS=blocked\n'
  printf 'SUPPORT_STATUS=unsupported\n'
  printf 'ASSEMBLY_REASON=%s\n' "$reason"
}

dwproton_fsr4_clone_root_is_safe() {
  local output_root="${1:-}" clone_root="${2:-}"
  local root_real="" clone_real="" parent="" probe="" probe_real=""

  [[ -n "$output_root" && "$output_root" == /* && "$output_root" != "/" ]] || return 1
  [[ -n "$clone_root" && "$clone_root" == /* && "$clone_root" != "/" ]] || return 1
  case "$clone_root" in
    */../*|*/..) return 1 ;;
  esac
  [[ -d "$output_root" && ! -L "$output_root" ]] || return 1
  [[ ! -L "$clone_root" ]] || return 1
  [[ ! -e "$clone_root" || -d "$clone_root" ]] || return 1

  root_real="$(readlink -f -- "$output_root" 2>/dev/null)" || return 1
  [[ -n "$root_real" && "$root_real" != "/" ]] || return 1
  clone_real="$(readlink -m -- "$clone_root" 2>/dev/null)" || return 1
  case "$clone_real" in
    "$root_real"/*) ;;
    *) return 1 ;;
  esac

  parent="${clone_root%/*}"
  [[ -n "$parent" && "$parent" != "/" ]] || return 1
  probe="$parent"
  while [[ ! -e "$probe" && "$probe" != "/" ]]; do
    probe="${probe%/*}"
  done
  [[ -n "$probe" && "$probe" != "/" && -d "$probe" && ! -L "$probe" ]] || return 1
  probe_real="$(readlink -f -- "$probe" 2>/dev/null)" || return 1
  case "$probe_real" in
    "$root_real"|"$root_real"/*) return 0 ;;
    *) return 1 ;;
  esac
}

dwproton_fsr4_assemble_clone_disabled() {
  local source_root="${1:-}" clone_root="${2:-}" output_root="${3:-}"
  local suffix="${4:-${SUFFIX:-$SUFFIX_DEFAULT}}" selected_version="${5:-4.1.0}"
  local plan="" plan_rc=0 provider="" known_version="" shape="unknown" replacement_env="unknown" opt_markers=0
  local source_base="unresolved" dw_version="unresolved" clone_basename="unresolved" clone_internal="unresolved"
  local clone_display="unresolved" expected_clone="unresolved" expected_display="unresolved" source_upscalers="" vdf_path="unresolved"
  local patched_upscalers="unresolved" reason="dwproton_support_not_enabled" writer="" writer_rc=0
  local writer_status="blocked" override_status="not_implemented" vdf_tmp=""

  source_upscalers="${source_root%/}/protonfixes/upscalers.py"
  plan="$(dwproton_fsr4_patch_plan_record "$source_root" "$suffix" 2>/dev/null)" || plan_rc=$?
  provider="$(dwproton_record_value "$plan" PROVIDER_FAMILY)"
  known_version="$(dwproton_record_value "$plan" KNOWN_DW_VERSION)"
  source_base="$(dwproton_record_value "$plan" SOURCE_BASE)"
  dw_version="$(dwproton_record_value "$plan" DW_VERSION)"
  shape="$(dwproton_record_value "$plan" UPSCALER_SHAPE)"
  replacement_env="$(dwproton_record_value "$plan" REPLACEMENT_ENV)"
  opt_markers="$(dwproton_record_value "$plan" OPTISCALER_MARKERS_PRESENT)"
  expected_clone="$(dwproton_record_value "$plan" CLONE_BASENAME)"
  reason="$(dwproton_record_value "$plan" PATCH_PLAN_REASON)"

  [[ -n "$source_base" ]] || source_base="${source_root##*/}"
  [[ -n "$dw_version" ]] || dw_version="unresolved"
  [[ -n "$shape" ]] || shape="unknown"
  [[ -n "$replacement_env" ]] || replacement_env="unknown"
  [[ -n "$opt_markers" ]] || opt_markers=0
  [[ -n "$expected_clone" ]] || expected_clone="unresolved"
  [[ -n "$reason" ]] || reason="dwproton_support_not_enabled"
  expected_display="$(steam_display_name_for_dwproton "$dw_version" 2>/dev/null || true)"
  [[ -n "$expected_display" ]] || expected_display="unresolved"

  if ((plan_rc != 0)) || [[ "$provider" != "dwproton" ]]; then
    dwproton_fsr4_clone_assembly_print_record \
      "skipped" "unknown" "${source_root:-unresolved}" "${clone_root:-unresolved}" \
      "unresolved" "unresolved" "unresolved" "unresolved" "unresolved" \
      "skipped" "unknown" 0 "not_implemented" "not_dwproton"
    return 1
  fi

  clone_basename="${clone_root##*/}"
  clone_internal="$clone_basename"
  clone_display="$expected_display"
  [[ "$clone_display" != "unresolved" ]] || clone_display="$clone_basename"
  vdf_path="$clone_root/compatibilitytool.vdf"
  patched_upscalers="$clone_root/protonfixes/upscalers.py"

  if [[ "$known_version" != "1" ]]; then
    dwproton_fsr4_clone_assembly_print_record \
      "blocked" "$shape" "$source_root" "${clone_root:-unresolved}" \
      "$expected_clone" "$expected_clone" "$expected_display" "$vdf_path" "$patched_upscalers" \
      "blocked" "$replacement_env" "$opt_markers" "not_implemented" "dwproton_unknown_version"
    return 1
  fi

  if [[ ! -d "$source_root" || -L "$source_root" || ! -r "$source_upscalers" || -L "$source_upscalers" ]]; then
    dwproton_fsr4_clone_assembly_print_record \
      "blocked" "$shape" "$source_root" "$clone_root" \
      "$expected_clone" "$expected_clone" "$expected_display" "$vdf_path" "$patched_upscalers" \
      "blocked" "$replacement_env" "$opt_markers" "not_implemented" "dwproton_unrecognized_shape"
    return 1
  fi

  if [[ "$shape" == "unknown" ]]; then
    dwproton_fsr4_clone_assembly_print_record \
      "blocked" "unknown" "$source_root" "$clone_root" \
      "$expected_clone" "$expected_clone" "$expected_display" "$vdf_path" "$patched_upscalers" \
      "blocked" "unknown" "$opt_markers" "not_implemented" "dwproton_unrecognized_shape"
    return 1
  fi

  if [[ "$expected_clone" == "unresolved" || "$clone_basename" != "$expected_clone" ||
        "$clone_internal" != "$expected_clone" || "$clone_display" != "$expected_display" ]]; then
    dwproton_fsr4_clone_assembly_print_record \
      "blocked" "$shape" "$source_root" "$clone_root" \
      "${expected_clone:-unresolved}" "${expected_clone:-unresolved}" "${expected_display:-unresolved}" "$vdf_path" "$patched_upscalers" \
      "blocked" "$replacement_env" "$opt_markers" "not_implemented" "unsafe_clone_candidate"
    return 1
  fi

  if ! dwproton_fsr4_clone_root_is_safe "$output_root" "$clone_root" ||
     ! dwproton_fsr4_writer_output_path_is_safe "$vdf_path" "$output_root" ||
     ! dwproton_fsr4_writer_output_path_is_safe "$patched_upscalers" "$output_root"; then
    dwproton_fsr4_clone_assembly_print_record \
      "blocked" "$shape" "$source_root" "$clone_root" \
      "$clone_basename" "$clone_internal" "$clone_display" "$vdf_path" "$patched_upscalers" \
      "blocked" "$replacement_env" "$opt_markers" "not_implemented" "unsafe_output_path"
    return 1
  fi

  mkdir -p -- "$clone_root" || {
    dwproton_fsr4_clone_assembly_print_record \
      "blocked" "$shape" "$source_root" "$clone_root" \
      "$clone_basename" "$clone_internal" "$clone_display" "$vdf_path" "$patched_upscalers" \
      "blocked" "$replacement_env" "$opt_markers" "not_implemented" "unsafe_output_path"
    return 1
  }
  if ! dwproton_fsr4_clone_root_is_safe "$output_root" "$clone_root"; then
    dwproton_fsr4_clone_assembly_print_record \
      "blocked" "$shape" "$source_root" "$clone_root" \
      "$clone_basename" "$clone_internal" "$clone_display" "$vdf_path" "$patched_upscalers" \
      "blocked" "$replacement_env" "$opt_markers" "not_implemented" "unsafe_output_path"
    return 1
  fi

  vdf_tmp="${vdf_path}.tmp.$$"
  if ! dwproton_fsr4_writer_output_path_is_safe "$vdf_tmp" "$output_root"; then
    dwproton_fsr4_clone_assembly_print_record \
      "blocked" "$shape" "$source_root" "$clone_root" \
      "$clone_basename" "$clone_internal" "$clone_display" "$vdf_path" "$patched_upscalers" \
      "blocked" "$replacement_env" "$opt_markers" "not_implemented" "unsafe_output_path"
    return 1
  fi
  if ! cat >"$vdf_tmp" <<EOF
"compatibilitytools"
{
  "compat_tools"
  {
    "$clone_internal"
    {
      "install_path" "."
      "display_name" "$clone_display"
    }
  }
}
EOF
  then
    rm -f -- "$vdf_tmp"
    dwproton_fsr4_clone_assembly_print_record \
      "blocked" "$shape" "$source_root" "$clone_root" \
      "$clone_basename" "$clone_internal" "$clone_display" "$vdf_path" "$patched_upscalers" \
      "blocked" "$replacement_env" "$opt_markers" "not_implemented" "unsafe_output_path"
    return 1
  fi
  mv -f -- "$vdf_tmp" "$vdf_path" || {
    rm -f -- "$vdf_tmp"
    dwproton_fsr4_clone_assembly_print_record \
      "blocked" "$shape" "$source_root" "$clone_root" \
      "$clone_basename" "$clone_internal" "$clone_display" "$vdf_path" "$patched_upscalers" \
      "blocked" "$replacement_env" "$opt_markers" "not_implemented" "unsafe_output_path"
    return 1
  }

  writer="$(dwproton_fsr4_write_patched_upscalers_disabled "$source_root" "$patched_upscalers" "$output_root" "$suffix" "$selected_version")" || writer_rc=$?
  writer_status="$(dwproton_record_value "$writer" WRITER_STATUS)"
  replacement_env="$(dwproton_record_value "$writer" REPLACEMENT_ENV)"
  opt_markers="$(dwproton_record_value "$writer" OPTISCALER_MARKERS_PRESENT)"
  override_status="$(dwproton_record_value "$writer" FSR4_OVERRIDE_STATUS)"
  [[ -n "$writer_status" ]] || writer_status="blocked"
  [[ -n "$replacement_env" ]] || replacement_env="unknown"
  [[ -n "$opt_markers" ]] || opt_markers=0
  [[ -n "$override_status" ]] || override_status="not_implemented"

  if ((writer_rc != 0)) || [[ "$writer_status" != "ready" ]]; then
    reason="$(dwproton_record_value "$writer" WRITER_REASON)"
    [[ -n "$reason" ]] || reason="dwproton_writer_not_ready"
    dwproton_fsr4_clone_assembly_print_record \
      "blocked" "$shape" "$source_root" "$clone_root" \
      "$clone_basename" "$clone_internal" "$clone_display" "$vdf_path" "$patched_upscalers" \
      "$writer_status" "$replacement_env" "$opt_markers" "$override_status" "$reason"
    return 1
  fi

  dwproton_fsr4_clone_assembly_print_record \
    "ready" "$shape" "$source_root" "$clone_root" \
    "$clone_basename" "$clone_internal" "$clone_display" "$vdf_path" "$patched_upscalers" \
    "$writer_status" "$replacement_env" "$opt_markers" "$override_status" "dwproton_assembly_test_only"
}

dwproton_fsr4_rebuild_plan_print_record() {
  local status="${1:-blocked}" action="${2:-BLOCK}" source_root="${3:-unresolved}" clone_parent="${4:-unresolved}"
  local clone_root="${5:-unresolved}" clone_basename="${6:-unresolved}" dw_version="${7:-unresolved}"
  local arch="${8:-unresolved}" assembly_class="${9:-unknown}" writer_status="${10:-not_run}"
  local assembly_status="${11:-not_run}" replacement_env="${12:-unknown}" opt_markers="${13:-0}"
  local override_status="${14:-not_implemented}" reason="${15:-dwproton_support_not_enabled}"

  printf 'DW_REBUILD_PLAN_STATUS=%s\n' "$status"
  printf 'DW_REBUILD_ACTION=%s\n' "$action"
  printf 'SOURCE_ROOT=%s\n' "$source_root"
  printf 'CLONE_PARENT=%s\n' "$clone_parent"
  printf 'CLONE_ROOT=%s\n' "$clone_root"
  printf 'CLONE_BASENAME=%s\n' "$clone_basename"
  printf 'DW_VERSION=%s\n' "$dw_version"
  printf 'DW_ARCH=%s\n' "$arch"
  printf 'ASSEMBLY_CLASS=%s\n' "$assembly_class"
  printf 'WRITER_STATUS=%s\n' "$writer_status"
  printf 'ASSEMBLY_STATUS=%s\n' "$assembly_status"
  printf 'REPLACEMENT_ENV=%s\n' "$replacement_env"
  printf 'REPLACEMENT_VALUE=fsr4\n'
  printf 'OPTISCALER_MARKERS_PRESENT=%s\n' "$opt_markers"
  printf 'OPTISCALER_ACTIVE_FOR_GENVW_FSR4=no\n'
  printf 'FSR4_OVERRIDE_STATUS=%s\n' "$override_status"
  printf 'PATCH_PLAN_STATUS=blocked\n'
  printf 'SUPPORT_STATUS=unsupported\n'
  printf 'PUBLIC_REBUILD_STATUS=disabled\n'
  printf 'PLAN_REASON=%s\n' "$reason"
}

dwproton_fsr4_clone_parent_is_safe() {
  local clone_parent="${1:-}" parent_real=""

  [[ -n "$clone_parent" && "$clone_parent" == /* && "$clone_parent" != "/" ]] || return 1
  case "$clone_parent" in
    */../*|*/..) return 1 ;;
  esac
  [[ -d "$clone_parent" && ! -L "$clone_parent" ]] || return 1
  parent_real="$(readlink -f -- "$clone_parent" 2>/dev/null)" || return 1
  [[ -n "$parent_real" && "$parent_real" != "/" ]] || return 1
}

dwproton_fsr4_rebuild_plan_disabled() {
  local source_root="${1:-}" clone_parent="${2:-}" suffix="${3:-${SUFFIX:-$SUFFIX_DEFAULT}}" selected_version="${4:-4.1.0}"
  local plan="" plan_rc=0 provider="" known_version="" source_base="" dw_version="unresolved"
  local shape="unknown" replacement_env="unknown" opt_markers=0 reason="dwproton_support_not_enabled"
  local clone_basename="unresolved" expected_clone="unresolved" clone_root="unresolved" arch="unresolved"

  : "$selected_version"
  [[ -n "$clone_parent" && "$clone_parent" != "/" ]] && clone_parent="${clone_parent%/}"

  plan="$(dwproton_fsr4_patch_plan_record "$source_root" "$suffix" 2>/dev/null)" || plan_rc=$?
  provider="$(dwproton_record_value "$plan" PROVIDER_FAMILY)"
  known_version="$(dwproton_record_value "$plan" KNOWN_DW_VERSION)"
  source_base="$(dwproton_record_value "$plan" SOURCE_BASE)"
  dw_version="$(dwproton_record_value "$plan" DW_VERSION)"
  shape="$(dwproton_record_value "$plan" UPSCALER_SHAPE)"
  replacement_env="$(dwproton_record_value "$plan" REPLACEMENT_ENV)"
  opt_markers="$(dwproton_record_value "$plan" OPTISCALER_MARKERS_PRESENT)"
  clone_basename="$(dwproton_record_value "$plan" CLONE_BASENAME)"
  reason="$(dwproton_record_value "$plan" PATCH_PLAN_REASON)"

  [[ -n "$source_base" ]] || source_base="${source_root##*/}"
  [[ -n "$dw_version" ]] || dw_version="unresolved"
  [[ -n "$shape" ]] || shape="unknown"
  [[ -n "$replacement_env" ]] || replacement_env="unknown"
  [[ -n "$opt_markers" ]] || opt_markers=0
  [[ -n "$clone_basename" ]] || clone_basename="unresolved"
  [[ -n "$reason" ]] || reason="dwproton_support_not_enabled"

  if [[ "$provider" != "dwproton" ]]; then
    dwproton_fsr4_rebuild_plan_print_record \
      "skipped" "SKIP" "${source_root:-unresolved}" "${clone_parent:-unresolved}" \
      "unresolved" "unresolved" "unresolved" "unresolved" \
      "unknown" "not_run" "not_run" "unknown" 0 "not_implemented" "not_dwproton"
    return 1
  fi

  arch="$(dwproton_display_arch_for_path "$source_root" "$dw_version" 2>/dev/null || true)"
  [[ -n "$arch" ]] || arch="unresolved"

  if [[ "$known_version" != "1" ]]; then
    dwproton_fsr4_rebuild_plan_print_record \
      "blocked" "BLOCK" "$source_root" "${clone_parent:-unresolved}" \
      "unresolved" "$clone_basename" "$dw_version" "$arch" \
      "$shape" "not_run" "not_run" "$replacement_env" "$opt_markers" "not_implemented" "dwproton_unknown_version"
    return 1
  fi

  if [[ "$shape" == "unknown" || "$arch" == "unresolved" ]]; then
    dwproton_fsr4_rebuild_plan_print_record \
      "blocked" "BLOCK" "$source_root" "${clone_parent:-unresolved}" \
      "unresolved" "$clone_basename" "$dw_version" "$arch" \
      "$shape" "not_run" "not_run" "$replacement_env" "$opt_markers" "not_implemented" "dwproton_unrecognized_shape"
    return 1
  fi

  expected_clone="$(dwproton_fsr4_plan_clone_basename_from_fields "$provider" "$source_base" "$dw_version" "$arch" "$suffix" 2>/dev/null || true)"
  if [[ -z "$expected_clone" || "$clone_basename" == "unresolved" || "$clone_basename" != "$expected_clone" ]]; then
    dwproton_fsr4_rebuild_plan_print_record \
      "blocked" "BLOCK" "$source_root" "${clone_parent:-unresolved}" \
      "unresolved" "${clone_basename:-unresolved}" "$dw_version" "$arch" \
      "$shape" "not_run" "not_run" "$replacement_env" "$opt_markers" "not_implemented" "unsafe_clone_candidate"
    return 1
  fi

  if ! dwproton_fsr4_clone_parent_is_safe "$clone_parent"; then
    dwproton_fsr4_rebuild_plan_print_record \
      "blocked" "BLOCK" "$source_root" "${clone_parent:-unresolved}" \
      "unresolved" "$clone_basename" "$dw_version" "$arch" \
      "$shape" "not_run" "not_run" "$replacement_env" "$opt_markers" "not_implemented" "unsafe_output_path"
    return 1
  fi

  clone_root="$clone_parent/$clone_basename"
  if ! dwproton_fsr4_clone_root_is_safe "$clone_parent" "$clone_root"; then
    dwproton_fsr4_rebuild_plan_print_record \
      "blocked" "BLOCK" "$source_root" "$clone_parent" \
      "$clone_root" "$clone_basename" "$dw_version" "$arch" \
      "$shape" "not_run" "not_run" "$replacement_env" "$opt_markers" "not_implemented" "unsafe_clone_candidate"
    return 1
  fi

  if [[ -d "$clone_root" ]]; then
    dwproton_fsr4_rebuild_plan_print_record \
      "ready" "REBUILD" "$source_root" "$clone_parent" \
      "$clone_root" "$clone_basename" "$dw_version" "$arch" \
      "$shape" "not_run" "not_run" "$replacement_env" "$opt_markers" "not_implemented" "existing_clone_directory"
    return 0
  fi

  dwproton_fsr4_rebuild_plan_print_record \
    "ready" "CREATE" "$source_root" "$clone_parent" \
    "$clone_root" "$clone_basename" "$dw_version" "$arch" \
    "$shape" "not_run" "not_run" "$replacement_env" "$opt_markers" "not_implemented" "missing_clone_directory"
}

dwproton_fsr4_copy_clone_print_record() {
  local status="${1:-blocked}" copy_class="${2:-unknown}" source_root="${3:-unresolved}" clone_parent="${4:-unresolved}"
  local clone_root="${5:-unresolved}" clone_basename="${6:-unresolved}" clone_internal="${7:-unresolved}"
  local clone_display="${8:-unresolved}" vdf_path="${9:-unresolved}" patched_upscalers="${10:-unresolved}"
  local writer_status="${11:-not_run}" replacement_env="${12:-unknown}" opt_markers="${13:-0}"
  local override_status="${14:-not_implemented}" reason="${15:-dwproton_support_not_enabled}"

  printf 'COPY_STATUS=%s\n' "$status"
  printf 'COPY_CLASS=%s\n' "$copy_class"
  printf 'SOURCE_ROOT=%s\n' "$source_root"
  printf 'CLONE_PARENT=%s\n' "$clone_parent"
  printf 'CLONE_ROOT=%s\n' "$clone_root"
  printf 'CLONE_BASENAME=%s\n' "$clone_basename"
  printf 'CLONE_INTERNAL_NAME=%s\n' "$clone_internal"
  printf 'CLONE_DISPLAY_NAME=%s\n' "$clone_display"
  printf 'VDF_PATH=%s\n' "$vdf_path"
  printf 'PATCHED_UPSCALERS=%s\n' "$patched_upscalers"
  printf 'WRITER_STATUS=%s\n' "$writer_status"
  printf 'REPLACEMENT_ENV=%s\n' "$replacement_env"
  printf 'REPLACEMENT_VALUE=fsr4\n'
  printf 'OPTISCALER_MARKERS_PRESENT=%s\n' "$opt_markers"
  printf 'OPTISCALER_ACTIVE_FOR_GENVW_FSR4=no\n'
  printf 'FSR4_OVERRIDE_STATUS=%s\n' "$override_status"
  printf 'PATCH_PLAN_STATUS=blocked\n'
  printf 'SUPPORT_STATUS=unsupported\n'
  printf 'PUBLIC_REBUILD_STATUS=disabled\n'
  printf 'COPY_REASON=%s\n' "$reason"
}

dwproton_fsr4_source_root_is_safe() {
  local source_root="${1:-}" source_real=""

  [[ -n "$source_root" && "$source_root" == /* && "$source_root" != "/" ]] || return 1
  case "$source_root" in
    */../*|*/..) return 1 ;;
  esac
  [[ -d "$source_root" && ! -L "$source_root" ]] || return 1
  source_real="$(readlink -f -- "$source_root" 2>/dev/null)" || return 1
  [[ -n "$source_real" && "$source_real" != "/" ]] || return 1
}

dwproton_fsr4_clone_parent_is_temp_output_root() {
  local clone_parent="${1:-}" parent_real="" tmp_root="${TMPDIR:-/tmp}" tmp_real=""

  parent_real="$(readlink -f -- "$clone_parent" 2>/dev/null)" || return 1
  tmp_real="$(readlink -f -- "$tmp_root" 2>/dev/null || true)"
  [[ -n "$tmp_real" && "$tmp_real" != "/" ]] || tmp_real="/tmp"
  case "$parent_real" in
    "$tmp_real"/*|/tmp/*|/var/tmp/*) return 0 ;;
    *) return 1 ;;
  esac
}

dwproton_fsr4_copy_clone_disabled() {
  local source_root="${1:-}" clone_root="${2:-}" clone_parent="${3:-}"
  local suffix="${4:-${SUFFIX:-$SUFFIX_DEFAULT}}" selected_version="${5:-4.1.0}"
  local plan="" plan_rc=0 plan_status="" plan_action="" clone_basename="unresolved" expected_clone="unresolved" expected_display="unresolved" dw_version_for_display=""
  local shape="unknown" replacement_env="unknown" opt_markers=0 reason="dwproton_support_not_enabled"
  local vdf_path="unresolved" patched_upscalers="unresolved" source_vdf="" source_upscalers=""
  local writer="" writer_rc=0 writer_status="not_run" override_status="not_implemented" vdf_tmp=""

  [[ -n "$source_root" && "$source_root" != "/" ]] && source_root="${source_root%/}"
  [[ -n "$clone_root" && "$clone_root" != "/" ]] && clone_root="${clone_root%/}"
  [[ -n "$clone_parent" && "$clone_parent" != "/" ]] && clone_parent="${clone_parent%/}"

  if ! dwproton_fsr4_source_root_is_safe "$source_root"; then
    dwproton_fsr4_copy_clone_print_record \
      "blocked" "unknown" "${source_root:-unresolved}" "${clone_parent:-unresolved}" "${clone_root:-unresolved}" \
      "unresolved" "unresolved" "unresolved" "unresolved" "unresolved" \
      "not_run" "unknown" 0 "not_implemented" "unsafe_output_path"
    return 1
  fi

  plan="$(dwproton_fsr4_rebuild_plan_disabled "$source_root" "$clone_parent" "$suffix" "$selected_version" 2>/dev/null)" || plan_rc=$?
  plan_status="$(dwproton_record_value "$plan" DW_REBUILD_PLAN_STATUS)"
  plan_action="$(dwproton_record_value "$plan" DW_REBUILD_ACTION)"
  expected_clone="$(dwproton_record_value "$plan" CLONE_BASENAME)"
  shape="$(dwproton_record_value "$plan" ASSEMBLY_CLASS)"
  replacement_env="$(dwproton_record_value "$plan" REPLACEMENT_ENV)"
  opt_markers="$(dwproton_record_value "$plan" OPTISCALER_MARKERS_PRESENT)"
  reason="$(dwproton_record_value "$plan" PLAN_REASON)"
  [[ -n "$expected_clone" ]] || expected_clone="unresolved"
  [[ -n "$shape" ]] || shape="unknown"
  [[ -n "$replacement_env" ]] || replacement_env="unknown"
  [[ -n "$opt_markers" ]] || opt_markers=0
  [[ -n "$reason" ]] || reason="dwproton_support_not_enabled"
  dw_version_for_display="$(dwproton_record_value "$plan" DW_VERSION)"
  expected_display="$(steam_display_name_for_dwproton "$dw_version_for_display" 2>/dev/null || true)"
  [[ -n "$expected_display" ]] || expected_display="unresolved"

  if [[ "$plan_status" == "skipped" || "$plan_action" == "SKIP" ]]; then
    dwproton_fsr4_copy_clone_print_record \
      "skipped" "unknown" "$source_root" "${clone_parent:-unresolved}" "${clone_root:-unresolved}" \
      "unresolved" "unresolved" "unresolved" "unresolved" "unresolved" \
      "skipped" "unknown" 0 "not_implemented" "not_dwproton"
    return 1
  fi

  if ((plan_rc != 0)) || [[ "$plan_status" != "ready" ]]; then
    dwproton_fsr4_copy_clone_print_record \
      "blocked" "$shape" "$source_root" "${clone_parent:-unresolved}" "${clone_root:-unresolved}" \
      "$expected_clone" "$expected_clone" "$expected_display" "unresolved" "unresolved" \
      "not_run" "$replacement_env" "$opt_markers" "not_implemented" "$reason"
    return 1
  fi

  if ! dwproton_fsr4_clone_parent_is_temp_output_root "$clone_parent"; then
    dwproton_fsr4_copy_clone_print_record \
      "blocked" "$shape" "$source_root" "$clone_parent" "${clone_root:-unresolved}" \
      "$expected_clone" "$expected_clone" "$expected_display" "unresolved" "unresolved" \
      "not_run" "$replacement_env" "$opt_markers" "not_implemented" "unsafe_output_path"
    return 1
  fi

  source_vdf="$source_root/compatibilitytool.vdf"
  source_upscalers="$source_root/protonfixes/upscalers.py"
  if [[ ! -r "$source_vdf" || -L "$source_vdf" || ! -r "$source_upscalers" || -L "$source_upscalers" ]]; then
    dwproton_fsr4_copy_clone_print_record \
      "blocked" "$shape" "$source_root" "$clone_parent" "${clone_root:-unresolved}" \
      "$expected_clone" "$expected_clone" "$expected_display" "unresolved" "unresolved" \
      "not_run" "$replacement_env" "$opt_markers" "not_implemented" "dwproton_unrecognized_shape"
    return 1
  fi

  clone_basename="${clone_root##*/}"
  if [[ -z "$clone_basename" || "$expected_clone" == "unresolved" || "$clone_basename" != "$expected_clone" ]]; then
    dwproton_fsr4_copy_clone_print_record \
      "blocked" "$shape" "$source_root" "$clone_parent" "${clone_root:-unresolved}" \
      "$expected_clone" "$expected_clone" "$expected_display" "unresolved" "unresolved" \
      "not_run" "$replacement_env" "$opt_markers" "not_implemented" "unsafe_clone_candidate"
    return 1
  fi

  if ! dwproton_fsr4_clone_root_is_safe "$clone_parent" "$clone_root"; then
    dwproton_fsr4_copy_clone_print_record \
      "blocked" "$shape" "$source_root" "$clone_parent" "${clone_root:-unresolved}" \
      "$expected_clone" "$expected_clone" "$expected_display" "unresolved" "unresolved" \
      "not_run" "$replacement_env" "$opt_markers" "not_implemented" "unsafe_clone_candidate"
    return 1
  fi

  vdf_path="$clone_root/compatibilitytool.vdf"
  patched_upscalers="$clone_root/protonfixes/upscalers.py"
  if ! dwproton_fsr4_writer_output_path_is_safe "$vdf_path" "$clone_parent" ||
     ! dwproton_fsr4_writer_output_path_is_safe "$patched_upscalers" "$clone_parent"; then
    dwproton_fsr4_copy_clone_print_record \
      "blocked" "$shape" "$source_root" "$clone_parent" "$clone_root" \
      "$clone_basename" "$clone_basename" "$expected_display" "$vdf_path" "$patched_upscalers" \
      "not_run" "$replacement_env" "$opt_markers" "not_implemented" "unsafe_output_path"
    return 1
  fi

  if [[ -e "$clone_root" || -L "$clone_root" ]]; then
    rm_rf_within_root "$clone_parent" "$clone_root" || {
      dwproton_fsr4_copy_clone_print_record \
        "blocked" "$shape" "$source_root" "$clone_parent" "$clone_root" \
        "$clone_basename" "$clone_basename" "$expected_display" "$vdf_path" "$patched_upscalers" \
        "not_run" "$replacement_env" "$opt_markers" "not_implemented" "unsafe_clone_candidate"
      return 1
    }
  fi

  cp -a -- "$source_root" "$clone_root" || {
    rm_rf_within_root "$clone_parent" "$clone_root" >/dev/null 2>&1 || true
    dwproton_fsr4_copy_clone_print_record \
      "blocked" "$shape" "$source_root" "$clone_parent" "$clone_root" \
      "$clone_basename" "$clone_basename" "$expected_display" "$vdf_path" "$patched_upscalers" \
      "not_run" "$replacement_env" "$opt_markers" "not_implemented" "unsafe_output_path"
    return 1
  }
  chmod -R u+w -- "$clone_root" 2>/dev/null || true

  if ! dwproton_fsr4_clone_root_is_safe "$clone_parent" "$clone_root" ||
     ! dwproton_fsr4_writer_output_path_is_safe "$vdf_path" "$clone_parent" ||
     ! dwproton_fsr4_writer_output_path_is_safe "$patched_upscalers" "$clone_parent"; then
    rm_rf_within_root "$clone_parent" "$clone_root" >/dev/null 2>&1 || true
    dwproton_fsr4_copy_clone_print_record \
      "blocked" "$shape" "$source_root" "$clone_parent" "$clone_root" \
      "$clone_basename" "$clone_basename" "$expected_display" "$vdf_path" "$patched_upscalers" \
      "not_run" "$replacement_env" "$opt_markers" "not_implemented" "unsafe_output_path"
    return 1
  fi

  vdf_tmp="${vdf_path}.tmp.$$"
  if ! dwproton_fsr4_writer_output_path_is_safe "$vdf_tmp" "$clone_parent"; then
    rm_rf_within_root "$clone_parent" "$clone_root" >/dev/null 2>&1 || true
    dwproton_fsr4_copy_clone_print_record \
      "blocked" "$shape" "$source_root" "$clone_parent" "$clone_root" \
      "$clone_basename" "$clone_basename" "$expected_display" "$vdf_path" "$patched_upscalers" \
      "not_run" "$replacement_env" "$opt_markers" "not_implemented" "unsafe_output_path"
    return 1
  fi
  if ! cat >"$vdf_tmp" <<EOF
"compatibilitytools"
{
  "compat_tools"
  {
    "$clone_basename"
    {
      "install_path" "."
      "display_name" "$expected_display"
    }
  }
}
EOF
  then
    rm -f -- "$vdf_tmp"
    rm_rf_within_root "$clone_parent" "$clone_root" >/dev/null 2>&1 || true
    dwproton_fsr4_copy_clone_print_record \
      "blocked" "$shape" "$source_root" "$clone_parent" "$clone_root" \
      "$clone_basename" "$clone_basename" "$expected_display" "$vdf_path" "$patched_upscalers" \
      "not_run" "$replacement_env" "$opt_markers" "not_implemented" "unsafe_output_path"
    return 1
  fi
  mv -f -- "$vdf_tmp" "$vdf_path" || {
    rm -f -- "$vdf_tmp"
    rm_rf_within_root "$clone_parent" "$clone_root" >/dev/null 2>&1 || true
    dwproton_fsr4_copy_clone_print_record \
      "blocked" "$shape" "$source_root" "$clone_parent" "$clone_root" \
      "$clone_basename" "$clone_basename" "$expected_display" "$vdf_path" "$patched_upscalers" \
      "not_run" "$replacement_env" "$opt_markers" "not_implemented" "unsafe_output_path"
    return 1
  }

  writer="$(dwproton_fsr4_write_patched_upscalers_disabled "$source_root" "$patched_upscalers" "$clone_parent" "$suffix" "$selected_version")" || writer_rc=$?
  writer_status="$(dwproton_record_value "$writer" WRITER_STATUS)"
  replacement_env="$(dwproton_record_value "$writer" REPLACEMENT_ENV)"
  opt_markers="$(dwproton_record_value "$writer" OPTISCALER_MARKERS_PRESENT)"
  override_status="$(dwproton_record_value "$writer" FSR4_OVERRIDE_STATUS)"
  [[ -n "$writer_status" ]] || writer_status="blocked"
  [[ -n "$replacement_env" ]] || replacement_env="unknown"
  [[ -n "$opt_markers" ]] || opt_markers=0
  [[ -n "$override_status" ]] || override_status="not_implemented"

  if ((writer_rc != 0)) || [[ "$writer_status" != "ready" ]]; then
    reason="$(dwproton_record_value "$writer" WRITER_REASON)"
    [[ -n "$reason" ]] || reason="dwproton_writer_not_ready"
    rm_rf_within_root "$clone_parent" "$clone_root" >/dev/null 2>&1 || true
    dwproton_fsr4_copy_clone_print_record \
      "blocked" "$shape" "$source_root" "$clone_parent" "$clone_root" \
      "$clone_basename" "$clone_basename" "$expected_display" "$vdf_path" "$patched_upscalers" \
      "$writer_status" "$replacement_env" "$opt_markers" "$override_status" "$reason"
    return 1
  fi

  dwproton_fsr4_copy_clone_print_record \
    "ready" "$shape" "$source_root" "$clone_parent" "$clone_root" \
    "$clone_basename" "$clone_basename" "$expected_display" "$vdf_path" "$patched_upscalers" \
    "$writer_status" "$replacement_env" "$opt_markers" "$override_status" "dwproton_copy_test_only"
}

dwproton_fsr4_stage_clone_print_record() {
  local status="${1:-blocked}" stage_class="${2:-unknown}" action="${3:-BLOCK}" source_root="${4:-unresolved}"
  local clone_parent="${5:-unresolved}" final_clone_root="${6:-unresolved}" clone_basename="${7:-unresolved}"
  local staging_root="${8:-unresolved}" backup_root="${9:-none}" vdf_path="${10:-unresolved}"
  local patched_upscalers="${11:-unresolved}" writer_status="${12:-not_run}" validation_status="${13:-not_run}"
  local publish_status="${14:-not_run}" cleanup_status="${15:-not_run}" replacement_env="${16:-unknown}"
  local opt_markers="${17:-0}" override_status="${18:-not_implemented}" reason="${19:-dwproton_support_not_enabled}"

  printf 'STAGE_STATUS=%s\n' "$status"
  printf 'STAGE_CLASS=%s\n' "$stage_class"
  printf 'STAGE_ACTION=%s\n' "$action"
  printf 'SOURCE_ROOT=%s\n' "$source_root"
  printf 'CLONE_PARENT=%s\n' "$clone_parent"
  printf 'FINAL_CLONE_ROOT=%s\n' "$final_clone_root"
  printf 'CLONE_BASENAME=%s\n' "$clone_basename"
  printf 'STAGING_ROOT=%s\n' "$staging_root"
  printf 'BACKUP_ROOT=%s\n' "$backup_root"
  printf 'VDF_PATH=%s\n' "$vdf_path"
  printf 'PATCHED_UPSCALERS=%s\n' "$patched_upscalers"
  printf 'WRITER_STATUS=%s\n' "$writer_status"
  printf 'VALIDATION_STATUS=%s\n' "$validation_status"
  printf 'PUBLISH_STATUS=%s\n' "$publish_status"
  printf 'CLEANUP_STATUS=%s\n' "$cleanup_status"
  printf 'REPLACEMENT_ENV=%s\n' "$replacement_env"
  printf 'REPLACEMENT_VALUE=fsr4\n'
  printf 'OPTISCALER_MARKERS_PRESENT=%s\n' "$opt_markers"
  printf 'OPTISCALER_ACTIVE_FOR_GENVW_FSR4=no\n'
  printf 'FSR4_OVERRIDE_STATUS=%s\n' "$override_status"
  printf 'PATCH_PLAN_STATUS=blocked\n'
  printf 'SUPPORT_STATUS=unsupported\n'
  printf 'PUBLIC_REBUILD_STATUS=disabled\n'
  printf 'STAGE_REASON=%s\n' "$reason"
}

dwproton_fsr4_stage_cleanup_path_disabled() {
  local root="${1:-}" path="${2:-}"
  [[ -n "$path" && "$path" != "/" && "$path" != "none" && "$path" != "unresolved" ]] || return 0
  [[ -e "$path" || -L "$path" ]] || return 0
  rm_rf_within_root "$root" "$path"
}

dwproton_fsr4_stage_clone_validate_disabled() {
  local source_root="${1:-}" staging_root="${2:-}" clone_basename="${3:-}"
  local stage_class="${4:-unknown}" replacement_env="${5:-unknown}" opt_markers="${6:-0}"
  local selected_version="${7:-4.1.0}" vdf="" up="" src_file="" rel="" staged_file="" expected_display=""

  vdf="$staging_root/compatibilitytool.vdf"
  up="$staging_root/protonfixes/upscalers.py"
  expected_display="$(dwproton_display_name_for_clone_basename "$clone_basename" 2>/dev/null || true)"

  [[ -f "$vdf" && ! -L "$vdf" && -f "$up" && ! -L "$up" ]] || return 1
  grep -Fq "\"$clone_basename\"" "$vdf" || return 1
  grep -Fq '"install_path" "."' "$vdf" || return 1
  if [[ -n "$expected_display" ]]; then
    grep -Fq "\"display_name\" \"$expected_display\"" "$vdf" || return 1
  else
    grep -Fq "\"display_name\" \"$clone_basename\"" "$vdf" || return 1
  fi
  python3 -m py_compile "$up" >/dev/null 2>&1 || return 1

  while IFS= read -r -d '' src_file; do
    rel="${src_file#"$source_root"/}"
    case "$rel" in
      compatibilitytool.vdf|protonfixes/upscalers.py) continue ;;
    esac
    staged_file="$staging_root/$rel"
    [[ -e "$staged_file" || -L "$staged_file" ]] || return 1
  done < <(find "$source_root" -type f -print0)

  if [[ "$opt_markers" == "1" ]]; then
    grep -Fq "setup_optiscaler" "$up" || return 1
    grep -Fq "PROTON_USE_OPTISCALER" "$up" || return 1
    grep -Fq "PROTON_OPTISCALER_NAME" "$up" || return 1
    grep -Fq "WINE_OPTISCALER_NAME" "$up" || return 1
  elif grep -Eq "setup_optiscaler|PROTON_USE_OPTISCALER|PROTON_OPTISCALER_NAME|WINE_OPTISCALER_NAME" "$up"; then
    return 1
  fi

  python3 - "$up" "$stage_class" "$replacement_env" "$opt_markers" "$selected_version" >/dev/null 2>&1 <<'PY'
import importlib
import importlib.util
import sys
import tempfile
from pathlib import Path

path = Path(sys.argv[1])
stage_class = sys.argv[2]
expected_env = sys.argv[3]
expected_markers = sys.argv[4] == "1"
selected_version = sys.argv[5]
text = path.read_text(encoding="utf-8")

def import_upscalers(path: Path):
    package_root = path.parent.parent
    package_init = path.parent / "__init__.py"
    if package_init.is_file():
        for name in tuple(sys.modules):
            if name == "protonfixes" or name.startswith("protonfixes."):
                del sys.modules[name]
        sys.path.insert(0, str(package_root))
        try:
            return importlib.import_module("protonfixes.upscalers")
        finally:
            try:
                sys.path.remove(str(package_root))
            except ValueError:
                pass

    spec = importlib.util.spec_from_file_location("dwproton_stage_validate", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

def call_private_setup(private_setup, env, compat_dir, prefix_dir):
    calls = (
        ("fsr4", compat_dir, prefix_dir, selected_version),
        (env, "PROTON_FSR4_UPGRADE", "fsr4", compat_dir, prefix_dir, selected_version),
    )
    last_type_error = None
    for args in calls:
        try:
            return private_setup(*args)
        except TypeError as exc:
            last_type_error = exc
    if last_type_error is not None:
        raise last_type_error
    raise RuntimeError("private setup call failed")

module = import_upscalers(path)

with tempfile.TemporaryDirectory(prefix="genvw-dwproton-stage-") as runtime:
    runtime_path = Path(runtime)
    compat_dir = runtime_path / "compat"
    prefix_dir = runtime_path / "prefix"
    compat_dir.mkdir(parents=True, exist_ok=True)
    prefix_dir.mkdir(parents=True, exist_ok=True)

    class _GENVWStageResponse:
        def __init__(self, payload: bytes):
            self.payload = payload
            self.offset = 0

        def __enter__(self):
            return self

        def __exit__(self, _exc_type, _exc, _tb):
            return False

        def read(self, size: int = -1) -> bytes:
            if size is None or size < 0:
                size = len(self.payload) - self.offset
            chunk = self.payload[self.offset:self.offset + size]
            self.offset += len(chunk)
            return chunk

    def _genvw_stage_urlopen(request, *args, **kwargs):
        url = getattr(request, "full_url", str(request))
        if "download.amd.com/dir/bin/amdxcffx64.dll/" in url:
            return _GENVWStageResponse(b"MZ" + (b"0" * 2048))
        raise RuntimeError(f"unexpected DW-Proton stage validation URL: {url}")

    if hasattr(module, "urllib") and hasattr(module.urllib, "request"):
        module.urllib.request.urlopen = _genvw_stage_urlopen
    if hasattr(module, "_GENVW_urllib_request"):
        module._GENVW_urllib_request.urlopen = _genvw_stage_urlopen

    env = {"PROTON_FSR4_UPGRADE": selected_version}
    module.setup_upscalers({"fsr4"}, env, str(compat_dir), str(prefix_dir))

    private_setup = module.__dict__.get("__setup_upscaler")
    public_setup = module.__dict__.get("setup_upscaler")
    opt_keys = ("PROTON_USE_OPTISCALER", "PROTON_OPTISCALER_NAME", "WINE_OPTISCALER_NAME")
    opt_markers = all(key in text for key in opt_keys) and "setup_optiscaler" in text
    opt_active = any(key in env for key in opt_keys)

    if env.get(expected_env) != "fsr4":
        raise SystemExit(f"expected {expected_env}=fsr4")
    if opt_active:
        raise SystemExit("OptiScaler env became active")
    if opt_markers != expected_markers:
        raise SystemExit("OptiScaler marker state mismatch")

    if stage_class == "private_bool_loaddll":
        if private_setup is None or not isinstance(call_private_setup(private_setup, env, str(compat_dir), str(prefix_dir)), bool):
            raise SystemExit("private bool contract mismatch")
        if "WINE_UPSCALER_REPLACE" in env:
            raise SystemExit("private bool set WINE_UPSCALER_REPLACE")
    elif stage_class == "private_tuple_upscaler_replace":
        if private_setup is None or not isinstance(call_private_setup(private_setup, env, str(compat_dir), str(prefix_dir)), tuple):
            raise SystemExit("private tuple contract mismatch")
        if "WINE_LOADDLL_REPLACE" in env:
            raise SystemExit("private tuple set WINE_LOADDLL_REPLACE")
    elif stage_class == "public_optiscaler_aware":
        if public_setup is None or not isinstance(public_setup("fsr4", str(compat_dir), str(prefix_dir), selected_version), bool):
            raise SystemExit("public OptiScaler-aware contract mismatch")
        if not opt_markers:
            raise SystemExit("public OptiScaler markers missing")
    else:
        raise SystemExit(f"unknown stage class: {stage_class}")
PY
}

dwproton_fsr4_stage_clone_publish_disabled() {
  local source_root="${1:-}" final_clone_root="${2:-}" clone_parent="${3:-}"
  local suffix="${4:-${SUFFIX:-$SUFFIX_DEFAULT}}" selected_version="${5:-4.1.0}"
  local plan="" plan_rc=0 plan_status="" plan_action="" expected_clone="unresolved" plan_clone_root="unresolved"
  local stage_class="unknown" replacement_env="unknown" opt_markers=0 reason="dwproton_support_not_enabled"
  local clone_basename="unresolved" expected_display="unresolved" dw_version_for_display="" action="BLOCK" source_vdf="" source_upscalers=""
  local vdf_path="unresolved" patched_upscalers="unresolved" staging_root="unresolved" backup_root="none"
  local staging_vdf="" staging_upscalers="" writer="" writer_rc=0 writer_status="not_run"
  local override_status="not_implemented" validation_status="not_run" publish_status="not_run"
  local cleanup_status="not_run" vdf_tmp="" cleanup_ok=1

  [[ -n "$source_root" && "$source_root" != "/" ]] && source_root="${source_root%/}"
  [[ -n "$final_clone_root" && "$final_clone_root" != "/" ]] && final_clone_root="${final_clone_root%/}"
  [[ -n "$clone_parent" && "$clone_parent" != "/" ]] && clone_parent="${clone_parent%/}"
  [[ -n "$final_clone_root" && "$final_clone_root" != "/" ]] && clone_basename="${final_clone_root##*/}"
  [[ -n "$final_clone_root" && "$final_clone_root" != "/" ]] && vdf_path="$final_clone_root/compatibilitytool.vdf"
  [[ -n "$final_clone_root" && "$final_clone_root" != "/" ]] && patched_upscalers="$final_clone_root/protonfixes/upscalers.py"

  if ! dwproton_fsr4_source_root_is_safe "$source_root"; then
    dwproton_fsr4_stage_clone_print_record \
      "blocked" "unknown" "BLOCK" "${source_root:-unresolved}" "${clone_parent:-unresolved}" "${final_clone_root:-unresolved}" \
      "${clone_basename:-unresolved}" "unresolved" "none" "$vdf_path" "$patched_upscalers" \
      "not_run" "not_run" "not_run" "not_run" "unknown" 0 "not_implemented" "unsafe_output_path"
    return 1
  fi

  plan="$(dwproton_fsr4_rebuild_plan_disabled "$source_root" "$clone_parent" "$suffix" "$selected_version" 2>/dev/null)" || plan_rc=$?
  plan_status="$(dwproton_record_value "$plan" DW_REBUILD_PLAN_STATUS)"
  plan_action="$(dwproton_record_value "$plan" DW_REBUILD_ACTION)"
  expected_clone="$(dwproton_record_value "$plan" CLONE_BASENAME)"
  plan_clone_root="$(dwproton_record_value "$plan" CLONE_ROOT)"
  stage_class="$(dwproton_record_value "$plan" ASSEMBLY_CLASS)"
  replacement_env="$(dwproton_record_value "$plan" REPLACEMENT_ENV)"
  opt_markers="$(dwproton_record_value "$plan" OPTISCALER_MARKERS_PRESENT)"
  reason="$(dwproton_record_value "$plan" PLAN_REASON)"
  [[ -n "$expected_clone" ]] || expected_clone="unresolved"
  [[ -n "$plan_clone_root" ]] || plan_clone_root="unresolved"
  [[ -n "$stage_class" ]] || stage_class="unknown"
  [[ -n "$replacement_env" ]] || replacement_env="unknown"
  [[ -n "$opt_markers" ]] || opt_markers=0
  [[ -n "$reason" ]] || reason="dwproton_support_not_enabled"
  dw_version_for_display="$(dwproton_record_value "$plan" DW_VERSION)"
  expected_display="$(steam_display_name_for_dwproton "$dw_version_for_display" 2>/dev/null || true)"
  [[ -n "$expected_display" ]] || expected_display="unresolved"

  if [[ "$plan_status" == "skipped" || "$plan_action" == "SKIP" ]]; then
    dwproton_fsr4_stage_clone_print_record \
      "skipped" "unknown" "SKIP" "$source_root" "${clone_parent:-unresolved}" "${final_clone_root:-unresolved}" \
      "${clone_basename:-unresolved}" "unresolved" "none" "$vdf_path" "$patched_upscalers" \
      "skipped" "not_run" "not_run" "not_run" "unknown" 0 "not_implemented" "not_dwproton"
    return 1
  fi

  if ((plan_rc != 0)) || [[ "$plan_status" != "ready" ]]; then
    dwproton_fsr4_stage_clone_print_record \
      "blocked" "$stage_class" "BLOCK" "$source_root" "${clone_parent:-unresolved}" "${final_clone_root:-unresolved}" \
      "$expected_clone" "unresolved" "none" "$vdf_path" "$patched_upscalers" \
      "not_run" "not_run" "not_run" "not_run" "$replacement_env" "$opt_markers" "not_implemented" "$reason"
    return 1
  fi

  source_vdf="$source_root/compatibilitytool.vdf"
  source_upscalers="$source_root/protonfixes/upscalers.py"
  if [[ ! -r "$source_vdf" || -L "$source_vdf" || ! -r "$source_upscalers" || -L "$source_upscalers" ]]; then
    dwproton_fsr4_stage_clone_print_record \
      "blocked" "$stage_class" "BLOCK" "$source_root" "$clone_parent" "${final_clone_root:-unresolved}" \
      "$expected_clone" "unresolved" "none" "$vdf_path" "$patched_upscalers" \
      "not_run" "not_run" "not_run" "not_run" "$replacement_env" "$opt_markers" "not_implemented" "dwproton_unrecognized_shape"
    return 1
  fi

  if [[ -z "$clone_basename" || "$clone_basename" != "$expected_clone" ||
        "$final_clone_root" != "$plan_clone_root" ||
        ! "$clone_basename" =~ ^dwproton-[0-9]+[.][0-9]+-[0-9]+-x86_64(_v[1-4])?-[A-Za-z0-9][A-Za-z0-9._-]*$ ]] ||
     ! dwproton_fsr4_clone_root_is_safe "$clone_parent" "$final_clone_root"; then
    dwproton_fsr4_stage_clone_print_record \
      "blocked" "$stage_class" "BLOCK" "$source_root" "$clone_parent" "${final_clone_root:-unresolved}" \
      "$expected_clone" "unresolved" "none" "$vdf_path" "$patched_upscalers" \
      "not_run" "not_run" "not_run" "not_run" "$replacement_env" "$opt_markers" "not_implemented" "unsafe_clone_candidate"
    return 1
  fi

  if [[ -d "$final_clone_root" ]]; then
    action="REPLACE"
  else
    action="CREATE"
  fi

  staging_root="$(mktemp -d "$clone_parent/.${clone_basename}.stage.XXXXXX")" || {
    dwproton_fsr4_stage_clone_print_record \
      "blocked" "$stage_class" "BLOCK" "$source_root" "$clone_parent" "$final_clone_root" \
      "$clone_basename" "unresolved" "none" "$vdf_path" "$patched_upscalers" \
      "not_run" "not_run" "not_run" "blocked" "$replacement_env" "$opt_markers" "not_implemented" "unsafe_output_path"
    return 1
  }
  if [[ "$staging_root" == "$final_clone_root" ]] || ! dwproton_fsr4_clone_root_is_safe "$clone_parent" "$staging_root"; then
    dwproton_fsr4_stage_cleanup_path_disabled "$clone_parent" "$staging_root" >/dev/null 2>&1 || cleanup_ok=0
    [[ "$cleanup_ok" == "1" ]] && cleanup_status="clean" || cleanup_status="blocked"
    dwproton_fsr4_stage_clone_print_record \
      "blocked" "$stage_class" "BLOCK" "$source_root" "$clone_parent" "$final_clone_root" \
      "$clone_basename" "$staging_root" "none" "$vdf_path" "$patched_upscalers" \
      "not_run" "not_run" "not_run" "$cleanup_status" "$replacement_env" "$opt_markers" "not_implemented" "unsafe_output_path"
    return 1
  fi

  if ! cp -a -- "$source_root"/. "$staging_root"/; then
    dwproton_fsr4_stage_cleanup_path_disabled "$clone_parent" "$staging_root" >/dev/null 2>&1 || cleanup_ok=0
    [[ "$cleanup_ok" == "1" ]] && cleanup_status="clean" || cleanup_status="blocked"
    dwproton_fsr4_stage_clone_print_record \
      "blocked" "$stage_class" "BLOCK" "$source_root" "$clone_parent" "$final_clone_root" \
      "$clone_basename" "$staging_root" "none" "$vdf_path" "$patched_upscalers" \
      "not_run" "not_run" "not_run" "$cleanup_status" "$replacement_env" "$opt_markers" "not_implemented" "unsafe_output_path"
    return 1
  fi
  chmod -R u+w -- "$staging_root" 2>/dev/null || true

  staging_vdf="$staging_root/compatibilitytool.vdf"
  staging_upscalers="$staging_root/protonfixes/upscalers.py"
  if ! dwproton_fsr4_writer_output_path_is_safe "$staging_vdf" "$clone_parent" ||
     ! dwproton_fsr4_writer_output_path_is_safe "$staging_upscalers" "$clone_parent"; then
    dwproton_fsr4_stage_cleanup_path_disabled "$clone_parent" "$staging_root" >/dev/null 2>&1 || cleanup_ok=0
    [[ "$cleanup_ok" == "1" ]] && cleanup_status="clean" || cleanup_status="blocked"
    dwproton_fsr4_stage_clone_print_record \
      "blocked" "$stage_class" "BLOCK" "$source_root" "$clone_parent" "$final_clone_root" \
      "$clone_basename" "$staging_root" "none" "$vdf_path" "$patched_upscalers" \
      "not_run" "not_run" "not_run" "$cleanup_status" "$replacement_env" "$opt_markers" "not_implemented" "unsafe_output_path"
    return 1
  fi

  vdf_tmp="${staging_vdf}.tmp.$$"
  if ! dwproton_fsr4_writer_output_path_is_safe "$vdf_tmp" "$clone_parent"; then
    dwproton_fsr4_stage_cleanup_path_disabled "$clone_parent" "$staging_root" >/dev/null 2>&1 || cleanup_ok=0
    [[ "$cleanup_ok" == "1" ]] && cleanup_status="clean" || cleanup_status="blocked"
    dwproton_fsr4_stage_clone_print_record \
      "blocked" "$stage_class" "BLOCK" "$source_root" "$clone_parent" "$final_clone_root" \
      "$clone_basename" "$staging_root" "none" "$vdf_path" "$patched_upscalers" \
      "not_run" "not_run" "not_run" "$cleanup_status" "$replacement_env" "$opt_markers" "not_implemented" "unsafe_output_path"
    return 1
  fi
  if ! cat >"$vdf_tmp" <<EOF
"compatibilitytools"
{
  "compat_tools"
  {
    "$clone_basename"
    {
      "install_path" "."
      "display_name" "$expected_display"
    }
  }
}
EOF
  then
    rm -f -- "$vdf_tmp"
    dwproton_fsr4_stage_cleanup_path_disabled "$clone_parent" "$staging_root" >/dev/null 2>&1 || cleanup_ok=0
    [[ "$cleanup_ok" == "1" ]] && cleanup_status="clean" || cleanup_status="blocked"
    dwproton_fsr4_stage_clone_print_record \
      "blocked" "$stage_class" "BLOCK" "$source_root" "$clone_parent" "$final_clone_root" \
      "$clone_basename" "$staging_root" "none" "$vdf_path" "$patched_upscalers" \
      "not_run" "not_run" "not_run" "$cleanup_status" "$replacement_env" "$opt_markers" "not_implemented" "unsafe_output_path"
    return 1
  fi
  if ! mv -f -- "$vdf_tmp" "$staging_vdf"; then
    rm -f -- "$vdf_tmp"
    dwproton_fsr4_stage_cleanup_path_disabled "$clone_parent" "$staging_root" >/dev/null 2>&1 || cleanup_ok=0
    [[ "$cleanup_ok" == "1" ]] && cleanup_status="clean" || cleanup_status="blocked"
    dwproton_fsr4_stage_clone_print_record \
      "blocked" "$stage_class" "BLOCK" "$source_root" "$clone_parent" "$final_clone_root" \
      "$clone_basename" "$staging_root" "none" "$vdf_path" "$patched_upscalers" \
      "not_run" "not_run" "not_run" "$cleanup_status" "$replacement_env" "$opt_markers" "not_implemented" "unsafe_output_path"
    return 1
  fi

  writer="$(dwproton_fsr4_write_patched_upscalers_disabled "$source_root" "$staging_upscalers" "$clone_parent" "$suffix" "$selected_version")" || writer_rc=$?
  writer_status="$(dwproton_record_value "$writer" WRITER_STATUS)"
  replacement_env="$(dwproton_record_value "$writer" REPLACEMENT_ENV)"
  opt_markers="$(dwproton_record_value "$writer" OPTISCALER_MARKERS_PRESENT)"
  override_status="$(dwproton_record_value "$writer" FSR4_OVERRIDE_STATUS)"
  [[ -n "$writer_status" ]] || writer_status="blocked"
  [[ -n "$replacement_env" ]] || replacement_env="unknown"
  [[ -n "$opt_markers" ]] || opt_markers=0
  [[ -n "$override_status" ]] || override_status="not_implemented"
  if ((writer_rc != 0)) || [[ "$writer_status" != "ready" ]]; then
    reason="$(dwproton_record_value "$writer" WRITER_REASON)"
    [[ -n "$reason" ]] || reason="dwproton_writer_not_ready"
    dwproton_fsr4_stage_cleanup_path_disabled "$clone_parent" "$staging_root" >/dev/null 2>&1 || cleanup_ok=0
    [[ "$cleanup_ok" == "1" ]] && cleanup_status="clean" || cleanup_status="blocked"
    dwproton_fsr4_stage_clone_print_record \
      "blocked" "$stage_class" "BLOCK" "$source_root" "$clone_parent" "$final_clone_root" \
      "$clone_basename" "$staging_root" "none" "$vdf_path" "$patched_upscalers" \
      "$writer_status" "not_run" "not_run" "$cleanup_status" "$replacement_env" "$opt_markers" "$override_status" "$reason"
    return 1
  fi

  if dwproton_fsr4_stage_clone_validate_disabled "$source_root" "$staging_root" "$clone_basename" "$stage_class" "$replacement_env" "$opt_markers" "$selected_version"; then
    validation_status="pass"
  else
    validation_status="fail"
    dwproton_fsr4_stage_cleanup_path_disabled "$clone_parent" "$staging_root" >/dev/null 2>&1 || cleanup_ok=0
    [[ "$cleanup_ok" == "1" ]] && cleanup_status="clean" || cleanup_status="blocked"
    dwproton_fsr4_stage_clone_print_record \
      "blocked" "$stage_class" "BLOCK" "$source_root" "$clone_parent" "$final_clone_root" \
      "$clone_basename" "$staging_root" "none" "$vdf_path" "$patched_upscalers" \
      "$writer_status" "$validation_status" "not_run" "$cleanup_status" "$replacement_env" "$opt_markers" "$override_status" "dwproton_validation_failed"
    return 1
  fi

  if [[ "$action" == "CREATE" ]]; then
    if ! mv -- "$staging_root" "$final_clone_root"; then
      dwproton_fsr4_stage_cleanup_path_disabled "$clone_parent" "$staging_root" >/dev/null 2>&1 || cleanup_ok=0
      dwproton_fsr4_stage_cleanup_path_disabled "$clone_parent" "$final_clone_root" >/dev/null 2>&1 || true
      [[ "$cleanup_ok" == "1" ]] && cleanup_status="clean" || cleanup_status="blocked"
      dwproton_fsr4_stage_clone_print_record \
        "blocked" "$stage_class" "BLOCK" "$source_root" "$clone_parent" "$final_clone_root" \
        "$clone_basename" "$staging_root" "none" "$vdf_path" "$patched_upscalers" \
        "$writer_status" "$validation_status" "blocked" "$cleanup_status" "$replacement_env" "$opt_markers" "$override_status" "dwproton_publish_failed"
      return 1
    fi
  else
    backup_root="$(mktemp -d "$clone_parent/.${clone_basename}.backup.XXXXXX")" || {
      dwproton_fsr4_stage_cleanup_path_disabled "$clone_parent" "$staging_root" >/dev/null 2>&1 || cleanup_ok=0
      [[ "$cleanup_ok" == "1" ]] && cleanup_status="clean" || cleanup_status="blocked"
      dwproton_fsr4_stage_clone_print_record \
        "blocked" "$stage_class" "BLOCK" "$source_root" "$clone_parent" "$final_clone_root" \
        "$clone_basename" "$staging_root" "unresolved" "$vdf_path" "$patched_upscalers" \
        "$writer_status" "$validation_status" "blocked" "$cleanup_status" "$replacement_env" "$opt_markers" "$override_status" "dwproton_publish_failed"
      return 1
    }
    if ! dwproton_fsr4_clone_root_is_safe "$clone_parent" "$backup_root" || [[ "$backup_root" == "$final_clone_root" || "$backup_root" == "$staging_root" ]]; then
      dwproton_fsr4_stage_cleanup_path_disabled "$clone_parent" "$staging_root" >/dev/null 2>&1 || cleanup_ok=0
      dwproton_fsr4_stage_cleanup_path_disabled "$clone_parent" "$backup_root" >/dev/null 2>&1 || cleanup_ok=0
      [[ "$cleanup_ok" == "1" ]] && cleanup_status="clean" || cleanup_status="blocked"
      dwproton_fsr4_stage_clone_print_record \
        "blocked" "$stage_class" "BLOCK" "$source_root" "$clone_parent" "$final_clone_root" \
        "$clone_basename" "$staging_root" "$backup_root" "$vdf_path" "$patched_upscalers" \
        "$writer_status" "$validation_status" "blocked" "$cleanup_status" "$replacement_env" "$opt_markers" "$override_status" "dwproton_publish_failed"
      return 1
    fi
    dwproton_fsr4_stage_cleanup_path_disabled "$clone_parent" "$backup_root" >/dev/null 2>&1 || cleanup_ok=0
    if ! mv -- "$final_clone_root" "$backup_root"; then
      dwproton_fsr4_stage_cleanup_path_disabled "$clone_parent" "$staging_root" >/dev/null 2>&1 || cleanup_ok=0
      [[ "$cleanup_ok" == "1" ]] && cleanup_status="clean" || cleanup_status="blocked"
      dwproton_fsr4_stage_clone_print_record \
        "blocked" "$stage_class" "BLOCK" "$source_root" "$clone_parent" "$final_clone_root" \
        "$clone_basename" "$staging_root" "$backup_root" "$vdf_path" "$patched_upscalers" \
        "$writer_status" "$validation_status" "blocked" "$cleanup_status" "$replacement_env" "$opt_markers" "$override_status" "dwproton_publish_failed"
      return 1
    fi
    if ! mv -- "$staging_root" "$final_clone_root"; then
      dwproton_fsr4_stage_cleanup_path_disabled "$clone_parent" "$staging_root" >/dev/null 2>&1 || cleanup_ok=0
      dwproton_fsr4_stage_cleanup_path_disabled "$clone_parent" "$final_clone_root" >/dev/null 2>&1 || true
      if mv -- "$backup_root" "$final_clone_root"; then
        backup_root="none"
        [[ "$cleanup_ok" == "1" ]] && cleanup_status="clean" || cleanup_status="blocked"
        dwproton_fsr4_stage_clone_print_record \
          "blocked" "$stage_class" "BLOCK" "$source_root" "$clone_parent" "$final_clone_root" \
          "$clone_basename" "$staging_root" "$backup_root" "$vdf_path" "$patched_upscalers" \
          "$writer_status" "$validation_status" "blocked" "$cleanup_status" "$replacement_env" "$opt_markers" "$override_status" "dwproton_publish_failed"
        return 1
      fi
      cleanup_status="blocked"
      dwproton_fsr4_stage_clone_print_record \
        "blocked" "$stage_class" "BLOCK" "$source_root" "$clone_parent" "$final_clone_root" \
        "$clone_basename" "$staging_root" "$backup_root" "$vdf_path" "$patched_upscalers" \
        "$writer_status" "$validation_status" "blocked" "$cleanup_status" "$replacement_env" "$opt_markers" "$override_status" "dwproton_restore_failed"
      return 1
    fi
    dwproton_fsr4_stage_cleanup_path_disabled "$clone_parent" "$backup_root" >/dev/null 2>&1 || cleanup_ok=0
  fi

  publish_status="published"
  if [[ "$cleanup_ok" == "1" ]]; then
    cleanup_status="clean"
  else
    cleanup_status="blocked"
  fi
  dwproton_fsr4_stage_clone_print_record \
    "ready" "$stage_class" "$action" "$source_root" "$clone_parent" "$final_clone_root" \
    "$clone_basename" "$staging_root" "$backup_root" "$vdf_path" "$patched_upscalers" \
    "$writer_status" "$validation_status" "$publish_status" "$cleanup_status" "$replacement_env" "$opt_markers" "$override_status" "dwproton_staging_test_only"
}

dwproton_vdf_arch_for_path() {
  local src="${1:-}" version="${2:-}" vdf="" token=""
  vdf="$src/compatibilitytool.vdf"
  [[ -n "$version" && -r "$vdf" ]] || return 1

  while IFS= read -r token; do
    if [[ "$token" =~ ^dwproton-([0-9]+[.][0-9]+-[0-9]+)-(x86_64(_v[1-4])?)$ ]]; then
      [[ "${BASH_REMATCH[1]}" == "$version" ]] || continue
      printf '%s\n' "${BASH_REMATCH[2]}"
      return 0
    fi
  done < <(awk -F'"' '{ for (i = 2; i <= NF; i += 2) print $i }' "$vdf" 2>/dev/null)

  return 1
}

dwproton_display_arch_for_path() {
  local src="${1:-}" version="${2:-}" base="" arch=""
  base="${src##*/}"
  arch="$(dwproton_vdf_arch_for_path "$src" "$version" 2>/dev/null || true)"
  if [[ -n "$arch" ]]; then
    printf '%s\n' "$arch"
    return 0
  fi
  if dwproton_known_folder "$base"; then
    printf '%s\n' "x86_64"
    return 0
  fi
  return 1
}

dwproton_display_source_label_for_path() {
  local src="${1:-}" rec="" provenance=""
  rec="$(source_provenance_record_for_path "$src" 2>/dev/null || true)"
  provenance="${rec%%|*}"
  case "$provenance" in
    ctd) printf '%s\n' "local CTD" ;;
    system) printf '%s\n' "system" ;;
    *) printf '%s\n' "local CTD" ;;
  esac
}

dwproton_display_row_record() {
  local src="${1:-}" base="" version="" arch="" map="" parsed=""
  local base_major="" base_date="" runtime="" base_label="" source_label="" status_label=""
  local dw_major="" dw_minor="" dw_build="" sort_date=""
  local suffix="${SUFFIX:-$SUFFIX_DEFAULT}" clone_basename=""

  [[ -d "$src" && ! -L "$src" ]] || return 1
  base="${src##*/}"
  version="$(dwproton_folder_version "$base" 2>/dev/null || true)"
  [[ -n "$version" ]] || return 1
  arch="$(dwproton_display_arch_for_path "$src" "$version" 2>/dev/null || true)"
  [[ -n "$arch" ]] || return 1

  map="$(dwproton_display_mapping_record "$base")"
  base_major="${map%%|*}"
  parsed="${map#*|}"
  base_date="${parsed%%|*}"
  runtime="${parsed#*|}"

  if [[ "$base_major" == "unresolved" || "$base_date" == "unresolved" ]]; then
    base_label="unresolved"
    runtime="unresolved"
    sort_date="00000000"
    status_label="available"
  else
    base_label="${base_major}-${base_date}"
    sort_date="$base_date"
    status_label="supported"
    clone_basename="$(dwproton_fsr4_plan_clone_basename_from_fields "dwproton" "$base" "$version" "$arch" "$suffix" 2>/dev/null || true)"
    if [[ -n "$clone_basename" && -n "${CTD:-}" && -d "${CTD}/${clone_basename}" ]]; then
      status_label="installed"
    fi
  fi

  if [[ "$version" =~ ^([0-9]+)[.]([0-9]+)-([0-9]+)$ ]]; then
    dw_major="${BASH_REMATCH[1]}"
    dw_minor="${BASH_REMATCH[2]}"
    dw_build="${BASH_REMATCH[3]}"
  else
    dw_major=0
    dw_minor=0
    dw_build=0
  fi
  source_label="$(dwproton_display_source_label_for_path "$src")"

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$dw_major" "$dw_minor" "$dw_build" "$sort_date" "$base" \
    "$version" "$base_label" "$runtime" "$arch" "$source_label" "$status_label"
}

gather_dwproton_display_targets() {
  local out_name="${1:-}"
  local -n out_ref="$out_name"
  local d="" row=""
  local had_nullglob=0

  out_ref=()
  [[ -d "${CTD:-}" ]] || return 0

  shopt -q nullglob && had_nullglob=1
  shopt -s nullglob
  for d in "$CTD"/dwproton-*; do
    [[ -d "$d" && ! -L "$d" ]] || continue
    row="$(dwproton_display_row_record "$d" 2>/dev/null || true)"
    [[ -n "$row" ]] || continue
    append_unique_path "$d" out_ref
  done
  ((had_nullglob == 1)) || shopt -u nullglob
}

clone_metadata_record() {
  local src="${1:-}" suffix="${2:-${SUFFIX:-$SUFFIX_DEFAULT}}"
  local base="${src##*/}" core="" major="" date="" runtime="" arch=""

  [[ -n "$suffix" && "$base" == *-"$suffix" ]] || return 1
  core="${base%-${suffix}}"
  if [[ "$core" =~ ^proton-cachyos-([0-9]+([.][0-9]+)?)-([0-9]{8})-(native|slr)-(.+)$ ]]; then
    major="${BASH_REMATCH[1]}"
    date="${BASH_REMATCH[3]}"
    runtime="${BASH_REMATCH[4]}"
    arch="${BASH_REMATCH[5]}"
  else
    return 1
  fi

  case "$arch" in
    x86_64 | x86_64_v[1-4] | protonplus-unspecified | protonplus-x86_64 | protonplus-x86_64_v[1-4] | system-x86_64) ;;
    *) return 1 ;;
  esac

  printf '%s|%s|%s|%s|%s\n' "$core" "$major" "$date" "$runtime" "$arch"
}

gather_source_targets_for_machine() {
  local out_name="${1:-}"
  local -n out_ref="$out_name"
  local d="" b="" rec="" list_rec="" parsed="" src_major="" root="" sys="" source_base="" list_base=""
  local had_nullglob=0
  local -a ctd_globs=()
  local -a seen_bases=()

  out_ref=()

  shopt -q nullglob && had_nullglob=1
  shopt -s nullglob

  if [[ -d "${CTD:-}" ]]; then
    if major_selection_is_all_supported; then
      ctd_globs=("$CTD"/proton-cachyos-* "$CTD"/cachyos-*)
    else
      ctd_globs=("$CTD"/proton-cachyos-"$MAJOR"-* "$CTD"/cachyos-"$MAJOR"-*)
    fi
    for d in "${ctd_globs[@]}"; do
      [[ -d "$d" && ! -L "$d" ]] || continue
      b="${d##*/}"
      case "$b" in
        *-"$SUFFIX") continue ;;
      esac
      rec="$(source_metadata_record "$d" 2>/dev/null || true)"
      [[ -n "$rec" ]] || continue
      parsed="${rec#*|}"
      src_major="${parsed%%|*}"
      source_major_matches_selection "$src_major" || continue
      source_base="${rec%%|*}"
      append_unique_path "$source_base" seen_bases
      list_rec="$(source_list_metadata_record "$d" 2>/dev/null || true)"
      list_base="${list_rec%%|*}"
      [[ -n "$list_rec" ]] && append_unique_path "$list_base" seen_bases
      append_unique_path "$d" out_ref
    done
  fi

  while IFS= read -r root; do
    [[ -d "$root" ]] || continue
    for sys in "$root"/proton-cachyos "$root"/proton-cachyos-slr; do
      [[ -d "$sys" && ! -L "$sys" ]] || continue
      rec="$(source_metadata_record "$sys" 2>/dev/null || true)"
      [[ -n "$rec" ]] || continue
      parsed="${rec#*|}"
      src_major="${parsed%%|*}"
      source_major_matches_selection "$src_major" || continue
      source_base="${rec%%|*}"
      append_unique_path "$source_base" seen_bases
      list_rec="$(source_list_metadata_record "$sys" 2>/dev/null || true)"
      list_base="${list_rec%%|*}"
      [[ -n "$list_rec" ]] && append_unique_path "$list_base" seen_bases
      append_unique_path "$sys" out_ref
    done
  done < <(system_source_roots)

  if [[ -d "${CTD:-}" ]]; then
    while IFS= read -r -d '' d; do
      [[ -d "$d" && ! -L "$d" ]] || continue
      rec="$(clone_metadata_record "$d" "$SUFFIX" 2>/dev/null || true)"
      [[ -n "$rec" ]] || continue
      parsed="${rec#*|}"
      src_major="${parsed%%|*}"
      source_major_matches_selection "$src_major" || continue
      source_base="${rec%%|*}"
      if [[ " ${seen_bases[*]} " == *" ${source_base} "* ]]; then
        continue
      fi
      append_unique_path "$source_base" seen_bases
      append_unique_path "$d" out_ref
    done < <(_matching_clones_for_current_selection "$CTD" "$SUFFIX" "" 2>/dev/null || true)
  fi

  ((had_nullglob == 1)) || shopt -u nullglob
}

do_dw_sources_machine() {
  local _a="" src="" row="" idx=0
  local dw_major="" dw_minor="" dw_build="" sort_date=""
  local base="" version="" base_label="" runtime="" arch="" source_label="" status_label=""
  local features="" fsr4_default="" fsr4_allowed="" resolved_count=0
  local -a dw_targets=() resolved_rows=() args=()

  for _a in "$@"; do
    case "$_a" in
      --machine) ;;
      *) args+=("$_a") ;;
    esac
  done
  parse_kv_flags --ctd-optional "${args[@]}"
  [[ "${GENVW_KV_HELP:-0}" == "1" ]] && return 0

  gather_dwproton_display_targets dw_targets

  for src in "${dw_targets[@]}"; do
    row="$(dwproton_display_row_record "$src" 2>/dev/null || true)"
    [[ -n "$row" ]] || continue
    IFS=$'\t' read -r dw_major dw_minor dw_build sort_date base version base_label runtime arch source_label status_label <<<"$row" || continue
    [[ "$base_label" != "unresolved" && "$runtime" != "unresolved" && "$sort_date" != "00000000" ]] || continue
    resolved_rows+=("$row")
    resolved_count=$((resolved_count + 1))
  done

  printf 'DW_SOURCES_SCHEMA=1\n'
  printf 'DW_CTD=%s\n' "${CTD:-}"
  printf 'DW_SOURCE_COUNT=%s\n' "$resolved_count"

  idx=0
  for row in "${resolved_rows[@]}"; do
    IFS=$'\t' read -r dw_major dw_minor dw_build sort_date base version base_label runtime arch source_label status_label <<<"$row" || continue
    features="$(list_clone_features_for_human "${base}-${arch}-gENVW" 2>/dev/null || printf 'FSR4')"
    printf 'DW_SOURCE_%s_BASE=%s\n' "$idx" "$base"
    printf 'DW_SOURCE_%s_VERSION=%s\n' "$idx" "$version"
    printf 'DW_SOURCE_%s_BASE_LABEL=%s\n' "$idx" "$base_label"
    printf 'DW_SOURCE_%s_RUNTIME=%s\n' "$idx" "$runtime"
    printf 'DW_SOURCE_%s_ARCH=%s\n' "$idx" "$arch"
    printf 'DW_SOURCE_%s_SOURCE=%s\n' "$idx" "${CTD:-}/$base"
    printf 'DW_SOURCE_%s_FEATURES=%s\n' "$idx" "$features"
    fsr4_default="$(dwproton_fsr4_default_for_version "$version")"
    fsr4_allowed="$(dwproton_fsr4_allowed_for_version "$version")"
    printf 'DW_SOURCE_%s_FSR4_DEFAULT=%s\n' "$idx" "$fsr4_default"
    printf 'DW_SOURCE_%s_FSR4_ALLOWED=%s\n' "$idx" "$fsr4_allowed"
    idx=$((idx + 1))
  done
}

do_sources() {
  local machine=0 a="" idx=0 src="" rec="" base="" parsed="" src_major="" date="" runtime="" arch=""
  local provenance_rec="" provenance="" provenance_root="" family="" bucket="" label="" kind="" record=""
  local row_num=0 version="" source_label="" arch_label="" status_label="" features="" row="" major_rank="" runtime_rank="" source_rank=""
  local -a args=()
  local -a source_targets=()
  local -a machine_source_targets=()
  local -a dw_targets=()
  local -a source_rows=()
  local -a dw_rows=()
  local -a clone_rows=()

  for a in "$@"; do
    case "$a" in
      --machine | --kv)
        machine=1
        ;;
      *)
        args+=("$a")
        ;;
    esac
  done

  parse_kv_flags --ctd-optional "${args[@]}"
  if [[ "${GENVW_KV_HELP:-0}" == "1" ]]; then
    return 0
  fi

  gather_source_targets_for_machine source_targets
  gather_dwproton_display_targets dw_targets

  if ((machine == 1)); then
    for src in "${source_targets[@]}"; do
      record="$(source_target_record_for_list "$src" "$SUFFIX" 2>/dev/null || true)"
      [[ -n "$record" ]] || continue
      kind="${record%%|*}"
      if [[ "$kind" == "source" ]] && ! source_is_patch_capable_target "$src"; then
        continue
      fi
      machine_source_targets+=("$src")
    done

    printf 'SOURCES_SCHEMA=1\n'
    printf 'CTD=%s\n' "$CTD"
    printf 'SOURCE_COUNT=%s\n' "${#machine_source_targets[@]}"
    for idx in "${!machine_source_targets[@]}"; do
      src="${machine_source_targets[$idx]}"
      record="$(source_target_record_for_list "$src" "$SUFFIX" 2>/dev/null || true)"
      [[ -n "$record" ]] || continue
      kind="${record%%|*}"
      rec="${record#*|}"
      base="${rec%%|*}"
      parsed="${rec#*|}"
      src_major="${parsed%%|*}"
      parsed="${parsed#*|}"
      date="${parsed%%|*}"
      parsed="${parsed#*|}"
      runtime="${parsed%%|*}"
      arch="${parsed#*|}"
      if [[ "$kind" == "clone" ]]; then
        provenance="genvw-clone"
        provenance_root="$CTD"
        family="genvw-clone"
      else
        provenance_rec="$(source_provenance_record_for_path "$src" 2>/dev/null || true)"
        provenance="${provenance_rec%%|*}"
        provenance_root="${provenance_rec#*|}"
        [[ "$provenance_root" != "$provenance_rec" ]] || provenance_root=""
        family="$(source_folder_family_for_path "$src")"
      fi
      bucket="$(source_policy_bucket_for_wizard "$src_major" "$date")"
      label="$(source_policy_label_for_wizard "$bucket")"
      printf 'SOURCE_%s_PATH=%s\n' "$idx" "$src"
      printf 'SOURCE_%s_KIND=%s\n' "$idx" "$kind"
      printf 'SOURCE_%s_BASE=%s\n' "$idx" "$base"
      printf 'SOURCE_%s_MAJOR=%s\n' "$idx" "$src_major"
      printf 'SOURCE_%s_BUILD_DATE=%s\n' "$idx" "$date"
      printf 'SOURCE_%s_RUNTIME=%s\n' "$idx" "$runtime"
      printf 'SOURCE_%s_ARCH=%s\n' "$idx" "$(source_target_arch_for_human "$arch")"
      printf 'SOURCE_%s_FAMILY=%s\n' "$idx" "$family"
      printf 'SOURCE_%s_PROVENANCE=%s\n' "$idx" "${provenance:-unknown}"
      printf 'SOURCE_%s_PROVENANCE_ROOT=%s\n' "$idx" "$provenance_root"
      printf 'SOURCE_%s_POLICY_BUCKET=%s\n' "$idx" "$bucket"
      printf 'SOURCE_%s_POLICY_LABEL=%s\n' "$idx" "$label"
    done
    return 0
  fi

  if ((${#source_targets[@]} == 0 && ${#dw_targets[@]} == 0)); then
    msg "${I_INFO} No Proton-CachyOS targets found."
    return 0
  fi

  if ((${#source_targets[@]} == 0)); then
    msg "${I_INFO} No Proton-CachyOS targets found."
  fi

  for idx in "${!source_targets[@]}"; do
    src="${source_targets[$idx]}"
    row="$(source_human_row_record "$src" 2>/dev/null || true)"
    [[ -n "$row" ]] || continue
    kind="${row%%$'\t'*}"
    if [[ "$kind" == "clone" ]]; then
      clone_rows+=("$row")
    else
      source_rows+=("$row")
    fi
  done

  for idx in "${!dw_targets[@]}"; do
    src="${dw_targets[$idx]}"
    row="$(dwproton_display_row_record "$src" 2>/dev/null || true)"
    [[ -n "$row" ]] || continue
    dw_rows+=("$row")
  done

  if ((${#source_rows[@]} > 0)); then
    msg "Proton-CachyOS targets"
    printf '\n'
    printf '  %-2s %-13s %-7s %-11s %-11s %-10s %s\n' "#" "VERSION" "RUNTIME" "ARCH" "SOURCE" "GENVW" "FEATURES"
    row_num=0
    while IFS=$'\t' read -r kind date major_rank runtime_rank source_rank base version runtime arch_label source_label status_label; do
      [[ -n "$kind" ]] || continue
      row_num=$((row_num + 1))
      features="$(list_clone_features_for_human "$base" 2>/dev/null || printf 'FSR4')"
      features="$(compact_feature_labels_for_human "$features")"
      printf '  %-2s %-13s %-7s %-11s %-11s %-10s %s\n' "$row_num" "$version" "$runtime" "$arch_label" "$source_label" "$status_label" "$features"
    done < <(printf '%s\n' "${source_rows[@]}" | sort -t $'\t' -k2,2r -k3,3nr -k4,4nr -k5,5nr -k6,6)
  fi

  if ((${#dw_rows[@]} > 0)); then
    printf '\n'
    msg "DW-Proton targets"
    printf '\n'
    printf '  %-2s %-9s %-13s %-11s %-7s %-9s %-10s %s\n' "#" "VERSION" "BASE" "RUNTIME" "ARCH" "SOURCE" "GENVW" "FEATURES"
    row_num=0
    while IFS=$'\t' read -r major_rank _minor_rank _dw_build _sort_date _base version base_label runtime arch_label source_label status_label; do
      [[ -n "$major_rank" ]] || continue
      row_num=$((row_num + 1))
      features="$(list_clone_features_for_human "$_base" 2>/dev/null || printf 'FSR4')"
      features="$(compact_feature_labels_for_human "$features")"
      printf '  %-2s %-9s %-13s %-11s %-7s %-9s %-10s %s\n' "$row_num" "$version" "$base_label" "$runtime" "$arch_label" "$source_label" "$status_label" "$features"
    done < <(printf '%s\n' "${dw_rows[@]}" | sort -t $'\t' -k1,1nr -k2,2nr -k3,3nr -k4,4r -k5,5r)
  fi

  printf '\n'
}

offer_rebuild_if_newer_available() {
  # if installed clones are older than the newest source date, offer to rebuild that date (tty only)

  # genvw wizard already asked; don't ask again here
  if [[ -n "${GENVW_SKIP_OUTDATED_PROMPT:-}" ]]; then
    return 0
  fi

  local newest_src_date="${1:-}"
  [[ -n "$newest_src_date" ]] || return 0

  local -a clones=()
  while IFS= read -r -d '' p; do
    [[ -n "$p" ]] && clones+=("$p")
  done < <(_matching_clones "$CTD" "$MAJOR" "$SUFFIX" "")

  ((${#clones[@]} > 0)) || return 0

  # find newest installed clone date
  local newest_clone_date="" b d
  for p in "${clones[@]}"; do
    b="${p##*/}"
    d="$(extract_build_date_from_name "$b" || true)"
    [[ -n "$d" ]] || continue
    if [[ -z "$newest_clone_date" || "$d" > "$newest_clone_date" ]]; then
      newest_clone_date="$d"
    fi
  done

  [[ -n "$newest_clone_date" ]] || return 0

  # up to date (YYYYMMDD string compare is fine)
  if [[ "$newest_src_date" == "$newest_clone_date" || "$newest_src_date" < "$newest_clone_date" ]]; then
    return 0
  fi

  warn "Outdated gENVW Proton tools detected."
  msg "${I_DATE}  Installed gENVW tool date (newest): $newest_clone_date"
  msg "${I_NEW} Newest Proton-CachyOS source date:   $newest_src_date"
  msg ""

  local -a old_names=()
  for p in "${clones[@]}"; do
    b="${p##*/}"
    d="$(extract_build_date_from_name "$b" || true)"
    [[ -n "$d" ]] || continue
    if [[ "$d" < "$newest_src_date" ]]; then
      old_names+=("$b")
    fi
  done
  msg "${I_BOX} Older installed tools: ${#old_names[@]}"
  msg "${I_INFO} Full list: $(cmd_proton) list-clones"
  msg ""

  local saved_date="$BUILD_DATE"
  msg "${I_RECEIPT} Rebuild plan:"
  msg "  Run: $(cmd_proton) rebuild --dry-run"
  msg "${I_INFO} Close Steam before rebuilding."
  msg ""

  # only prompt when user didn't force --date
  if [[ -z "$saved_date" ]]; then
    if ask_yes_no_default "${YELLOW}${I_RETRY} Rebuild newest date $newest_src_date now? [Y/n]: ${RESET}" "y"; then
      BUILD_DATE="$newest_src_date"
      return 0
    fi

    msg "${I_INFO} Rebuild skipped by user."
    return 1
  else
    warn "(You set --date $saved_date; continuing with your chosen date.)"
    return 0
  fi
}

pick_sources_for_major_date() {
  local want_major="${1:-}" want_date="${2:-}" out_name="${3:-PICKED}"
  local -n out_ref="$out_name"
  local d rec="" base="" parsed="" src_major="" date="" runtime="" arch="" variant=""
  local key="" existing_idx=-1 idx=0 existing_base="" existing_priority="" priority=""
  local -a choice_keys=()
  local -a choice_vals=()

  for d in "${SOURCES[@]}"; do
    rec="$(source_metadata_record "$d" 2>/dev/null || true)"
    [[ -n "$rec" ]] || continue
    base="${rec%%|*}"
    parsed="${rec#*|}"
    src_major="${parsed%%|*}"
    parsed="${parsed#*|}"
    date="${parsed%%|*}"
    parsed="${parsed#*|}"
    runtime="${parsed%%|*}"
    arch="${parsed#*|}"
    [[ -z "$want_major" || "$src_major" == "$want_major" ]] || continue
    [[ "$date" == "$want_date" ]] || continue

    variant="1"
    if [[ "$arch" =~ _v([0-9]+)$ ]]; then
      variant="${BASH_REMATCH[1]}"
    fi
    [[ "$variant" =~ ^[0-9]+$ ]] || variant="1"
    key="${src_major}|${runtime}|${variant}"

    existing_idx=-1
    for idx in "${!choice_keys[@]}"; do
      if [[ "${choice_keys[$idx]}" == "$key" ]]; then
        existing_idx="$idx"
        break
      fi
    done

    if ((existing_idx < 0)); then
      choice_keys+=("$key")
      choice_vals+=("$d")
      continue
    fi

    existing_base="$(source_effective_base "${choice_vals[$existing_idx]}")"
    existing_priority="$(source_default_priority_for_path "${choice_vals[$existing_idx]}")"
    priority="$(source_default_priority_for_path "$d")"
    if ((priority > existing_priority)); then
      choice_vals[$existing_idx]="$d"
    elif ((priority == existing_priority)) && [[ "$base" > "$existing_base" ]]; then
      choice_vals[$existing_idx]="$d"
    fi
  done

  ((${#choice_keys[@]} > 0)) || return 0
  while IFS= read -r key; do
    [[ -n "$key" ]] || continue
    for idx in "${!choice_keys[@]}"; do
      if [[ "${choice_keys[$idx]}" == "$key" ]]; then
        out_ref+=("${choice_vals[$idx]}")
        break
      fi
    done
  done < <(printf '%s\n' "${choice_keys[@]}" | sort -t '|' -k1,1V -k2,2 -k3,3n)
}

pick_sources_for_date() {
  # fill PICKED[] with sources matching BUILD_DATE.
  PICKED=()
  pick_sources_for_major_date "" "$BUILD_DATE" PICKED
}

pick_latest_sources_by_major() {
  PICKED=()
  local src="" rec="" parsed="" src_major="" date=""
  local -A latest_by_major=()

  for src in "${SOURCES[@]}"; do
    rec="$(source_metadata_record "$src" 2>/dev/null || true)"
    [[ -n "$rec" ]] || continue
    parsed="${rec#*|}"
    src_major="${parsed%%|*}"
    parsed="${parsed#*|}"
    date="${parsed%%|*}"
    [[ "$src_major" =~ ^[0-9]+(\.[0-9]+)?$ ]] || continue
    [[ "$date" =~ ^[0-9]{8}$ ]] || continue
    if [[ -z "${latest_by_major[$src_major]:-}" || "$date" > "${latest_by_major[$src_major]}" ]]; then
      latest_by_major[$src_major]="$date"
    fi
  done

  ((${#latest_by_major[@]} > 0)) || return 0
  local major=""
  while IFS= read -r major; do
    [[ -n "$major" ]] || continue
    pick_sources_for_major_date "$major" "${latest_by_major[$major]}" PICKED
  done < <(printf '%s\n' "${!latest_by_major[@]}" | sort -V)
}

pick_sources_for_rebuild_selection() {
  local newest_src_date="${1:-}" newest_supported_date="${2:-}"

  if [[ -n "$BUILD_DATE" ]]; then
    pick_sources_for_date
    return 0
  fi

  if major_selection_is_all_supported; then
    pick_latest_sources_by_major
    return 0
  fi

  if [[ -n "$newest_supported_date" ]]; then
    BUILD_DATE="$newest_supported_date"
  else
    BUILD_DATE="$newest_src_date"
  fi
  pick_sources_for_date
}

rebuild_plan_scope_label() {
  if [[ -n "${BUILD_DATE:-}" ]]; then
    printf 'date %s\n' "$BUILD_DATE"
  elif major_selection_is_all_supported; then
    printf '%s\n' "all supported majors"
  else
    printf '%s\n' "selected sources"
  fi
}

make_temp_patchers() {
  # let callers pre-set T_UP/T_VDF (handy inside a temp dir)
  : "${T_UP:=$(mktemp -t genvw_proton_upscaler.XXXXXX.py)}"
  : "${T_VDF:=$(mktemp -t genvw_proton_vdf.XXXXXX.py)}"
  cat >"$T_UP" <<'PY'
#!/usr/bin/env python3
import ast
import os
import re
import sys
from pathlib import Path

HELPER_START = "# >>> gENVW FSR4 universal backend >>>"
HELPER_END = "# <<< gENVW FSR4 universal backend <<<"
PATCH_MARKER = "gENVW FSR4 universal backend"
DEFAULT_VERSION = "4.0.2"
PATCH_USER_AGENT = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/135.0.0.0 Safari/537.36"
)

def add_imports(src: str) -> str:
    required = [
        ("import hashlib", "import hashlib\n"),
        ("import os", "import os\n"),
        ("import shutil", "import shutil\n"),
        ("import urllib.request", "import urllib.request\n"),
    ]
    has_path = ("from pathlib import Path" in src) or ("import pathlib" in src)

    missing_lines = []
    for key, line in required:
        if key not in src:
            missing_lines.append(line)
    if not has_path:
        missing_lines.append("from pathlib import Path\n")

    if not missing_lines:
        return src

    lines = src.splitlines(True)

    insert_at = 0
    saw_import = False
    for i, ln in enumerate(lines):
        if ln.startswith("import ") or ln.startswith("from "):
            saw_import = True
            insert_at = i + 1
            continue
        if saw_import:
            break
        insert_at = i
        break

    ins = "".join(missing_lines) + "\n"
    lines.insert(insert_at, ins)
    return "".join(lines)

def _module_tree(src: str) -> ast.Module:
    try:
        return ast.parse(src)
    except SyntaxError as exc:
        raise SystemExit(f"ERROR: Could not parse source: {exc}") from exc

def _find_function_node(src: str, name: str) -> ast.FunctionDef:
    tree = _module_tree(src)
    for node in tree.body:
        if isinstance(node, ast.FunctionDef) and node.name == name:
            return node
    raise SystemExit(f"ERROR: Could not find def {name}(...)")

def _replace_block_by_lines(src: str, start_lineno: int, end_lineno: int, new_block: str) -> str:
    lines = src.splitlines(True)
    replacement = new_block.rstrip("\n") + "\n"
    lines[start_lineno - 1:end_lineno] = [replacement]
    return "".join(lines)

def replace_function(src: str, name: str, new_block: str) -> str:
    node = _find_function_node(src, name)
    return _replace_block_by_lines(src, node.lineno, node.end_lineno, new_block)

def helper_block() -> str:
    return f"""{HELPER_START}
_GENVW_FSR4_USER_AGENT = {PATCH_USER_AGENT!r}
_GENVW_FSR4_DEFAULT_VERSION = {DEFAULT_VERSION!r}
_GENVW_FSR4_VERSION_FAMILY_PREFIXES = (
    '4.0.',
    '4.1.',
    '4.2.',
    '4.3.',
    '4.4.',
)
_GENVW_FSR4_SOURCES = {{
__GENVW_FSR4_PY_SOURCES__
}}

def _genvw_fsr4_version_in_known_family(version: str) -> bool:
    version = str(version).strip()
    return any(version.startswith(prefix) for prefix in _GENVW_FSR4_VERSION_FAMILY_PREFIXES)

def _genvw_fsr4_resolve_requested_version(version: str) -> str:
    requested = str(version).strip() or 'default'
    if requested == 'default':
        return _GENVW_FSR4_DEFAULT_VERSION
    if requested in _GENVW_FSR4_SOURCES:
        return requested
    if _genvw_fsr4_version_in_known_family(requested):
        return _GENVW_FSR4_DEFAULT_VERSION
    return _GENVW_FSR4_DEFAULT_VERSION

def _genvw_fsr4_get_source(version: str) -> dict:
    resolved = _genvw_fsr4_resolve_requested_version(version)
    return _GENVW_FSR4_SOURCES[resolved]

def _genvw_fsr4_runtime_requested_version(env: dict) -> tuple[str, str]:
    for key in ('PROTON_FSR4_RDNA3_UPGRADE', 'PROTON_FSR4_UPGRADE'):
        requested = str(env.get(key, '')).strip()
        if requested in _GENVW_FSR4_SOURCES:
            return key, requested
    return '', ''

def genvw_setup_result(result) -> tuple[bool, set, str]:
    if isinstance(result, tuple):
        enabled = bool(result[0]) if len(result) > 0 else False
        dll_names = result[1] if len(result) > 1 and isinstance(result[1], set) else set()
        windows_path = result[2] if len(result) > 2 else ''
        return enabled, dll_names, windows_path
    return bool(result), set(), ''

def genvw_public_upscaler_entry(name: str):
    entries = {{
        'dlss': ('__get_dlss_dlls', '__download_extract_zip', '__dlss_version_file'),
        'xess': ('__get_xess_dlls', '__download_extract_zip', '__xess_version_file'),
        'fsr3': ('__get_fsr3_dlls', '__download_extract_zip', '__fsr3_version_file'),
        'fsr4': ('__get_fsr4_dlls', '__download_fsr4', '__fsr4_version_file'),
    }}
    entry = entries.get(name)
    if entry is None:
        return None
    getter_name, downloader_name, version_file_name = entry
    getter = globals().get(getter_name)
    downloader = globals().get(downloader_name)
    version_file = globals().get(version_file_name)
    if not callable(getter) or not callable(downloader) or not version_file:
        return None
    return getter, downloader, version_file

def genvw_setup_upscaler(
    env: dict,
    key: str,
    name: str,
    compat_dir: str,
    prefix_dir: str,
    version: str = 'default',
) -> tuple[bool, set, str]:
    private_setup = globals().get('__setup_upscaler')
    if callable(private_setup):
        return genvw_setup_result(
            private_setup(env, key, name, compat_dir, prefix_dir, version)
        )

    public_setup = globals().get('setup_upscaler')
    public_entry = genvw_public_upscaler_entry(name)
    check_files = globals().get('__check_upscaler_files')
    download_files = globals().get('__download_upscaler_files')
    if (
        callable(public_setup)
        and public_entry is not None
        and callable(check_files)
        and callable(download_files)
    ):
        requested = env[key] if env.get(key, '0') not in {{'0', '1'}} else version
        get_files, download_func, version_file = public_entry
        files = get_files(requested)
        version_path = os.path.join(compat_dir, version_file)
        enabled, _, _ = genvw_setup_result(
            check_files(prefix_dir, files, version_path, False)
        )
        if not enabled:
            if not download_files(prefix_dir, files, download_func, version_path):
                return False, set(), ''
        return genvw_setup_result(check_files(prefix_dir, files, version_path, True))

    if callable(public_setup):
        requested = env[key] if env.get(key, '0') not in {{'0', '1'}} else version
        return genvw_setup_result(public_setup(name, compat_dir, prefix_dir, requested))

    raise NameError('missing upscaler setup function')

def _genvw_fsr4_cache_path(cache_dir: Path, version: str) -> Path:
    resolved = _genvw_fsr4_resolve_requested_version(version)
    return cache_dir.joinpath(f'amdxcffx64_v{{resolved}}.dll')

def _genvw_fsr4_validate_file(path: Path, metadata: dict) -> bool:
    try:
        if not path.is_file():
            return False
        if path.stat().st_size != metadata['size']:
            return False
        digest = hashlib.sha256()
        with path.open('rb') as file_fd:
            header = file_fd.read(2)
            if header != b'MZ':
                return False
            digest.update(header)
            while True:
                chunk = file_fd.read(1024 * 1024)
                if not chunk:
                    break
                digest.update(chunk)
        return digest.hexdigest().lower() == metadata['sha256'].lower()
    except OSError:
        return False

def _genvw_fsr4_download_to_cache(metadata: dict, cached_file: Path) -> None:
    cached_file.parent.mkdir(parents=True, exist_ok=True)
    tmp_file = cached_file.with_name(cached_file.name + f'.tmp.{{os.getpid()}}')
    request = urllib.request.Request(
        metadata['download_url'],
        headers={{'User-Agent': _GENVW_FSR4_USER_AGENT}},
    )
    try:
        tmp_file.unlink(missing_ok=True)
        with urllib.request.urlopen(request, timeout=60) as response:
            with tmp_file.open('wb') as dst_fd:
                shutil.copyfileobj(response, dst_fd)
        if not _genvw_fsr4_validate_file(tmp_file, metadata):
            raise RuntimeError(f'Invalid FSR4 download for version {{metadata[\"version\"]}}')
        tmp_file.replace(cached_file)
    except Exception as exc:
        tmp_file.unlink(missing_ok=True)
        raise exc

def _genvw_fsr4_build_entry(version: str) -> dict:
    resolved = _genvw_fsr4_resolve_requested_version(version)
    metadata = _GENVW_FSR4_SOURCES[resolved]
    return {{
        'version': f'{{resolved}}_genvw',
        'download_url': metadata['download_url'],
        'md5_hash': None,
        'zip_md5_hash': None,
        'sha256_hash': metadata['sha256'],
        'size': metadata['size'],
        'genvw_version': resolved,
        'cache_name': f'amdxcffx64_v{{resolved}}.dll',
    }}

def _genvw_metadata_has_strong_fields(metadata: dict) -> bool:
    return bool(metadata.get('sha256_hash')) and ('size' in metadata) and (metadata.get('size') is not None)

def _genvw_validate_target_against_metadata(path: Path, metadata: dict) -> bool:
    if not _genvw_metadata_has_strong_fields(metadata):
        return False
    try:
        size = int(metadata['size'])
    except (TypeError, ValueError):
        return False
    sha = str(metadata.get('sha256_hash', '')).strip().lower()
    if not sha:
        return False
    try:
        if not path.is_file():
            return False
        if path.stat().st_size != size:
            return False
        digest = hashlib.sha256()
        with path.open('rb') as file_fd:
            header = file_fd.read(2)
            if header != b'MZ':
                return False
            digest.update(header)
            while True:
                chunk = file_fd.read(1024 * 1024)
                if not chunk:
                    break
                digest.update(chunk)
        return digest.hexdigest().lower() == sha
    except OSError:
        return False
{HELPER_END}"""

def inject_helper_block(src: str) -> str:
    block = helper_block().rstrip("\n") + "\n\n"
    if HELPER_START in src and HELPER_END in src:
        pattern = re.compile(
            re.escape(HELPER_START) + r'.*?' + re.escape(HELPER_END) + r'\n*',
            re.S,
        )
        return pattern.sub(block, src, count=1)

    node = _find_function_node(src, "__get_fsr4_dlls")
    lines = src.splitlines(True)
    lines.insert(node.lineno - 1, block)
    return "".join(lines)

def get_fsr4_function_block() -> str:
    return """def __get_fsr4_dlls(version: str = 'default') -> dict:
    version = _genvw_fsr4_resolve_requested_version(version)
    return {
        'drive_c/windows/system32/amdxcffx64.dll': _genvw_fsr4_build_entry(version),
    }"""

def download_fsr4_function_block() -> str:
    return """def __download_fsr4(file: dict, cache: Path, dst: Path) -> None:
    version = str(file.get('genvw_version', '')).strip()
    if not version:
        version = str(file.get('version', '')).strip().split('_', 1)[0]
    version = _genvw_fsr4_resolve_requested_version(version)
    metadata = _genvw_fsr4_get_source(version)
    cached_file = _genvw_fsr4_cache_path(cache, version)

    if not _genvw_fsr4_validate_file(cached_file, metadata):
        _genvw_fsr4_download_to_cache(metadata, cached_file)
    if not _genvw_fsr4_validate_file(cached_file, metadata):
        raise RuntimeError(f'Invalid cached FSR4 DLL for version {version}')

    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy(cached_file, dst)"""

def check_upscaler_file_function_block() -> str:
    return """def __check_upscaler_file(
    prefix_dir: str, dst: str, file: dict, version: dict, ignore_version: bool
) -> bool:
    target = Path(prefix_dir, dst)

    if target.is_symlink():
        log.debug(f'Removing stale symlink "{dst}"')
        target.unlink()
    if target.exists() and target.stat().st_size < 1024:
        log.debug(f'Removing stale file "{dst}"')
        target.unlink()

    if not target.exists():
        log.warn(f'Missing file from prefix "{dst}"')
        return False

    if _genvw_metadata_has_strong_fields(version):
        if not _genvw_validate_target_against_metadata(target, version):
            log.warn(f'SHA-256/size mismatch between version and prefix "{dst}"')
            return False
    else:
        with target.open('rb') as dst_fd:
            dst_md5 = hashlib.md5(dst_fd.read()).hexdigest().lower()
        version_md5 = version.get('md5_hash')
        if version_md5 is not None and dst_md5 != str(version_md5).lower():
            log.warn(f'MD5 checksum mismatch between version and prefix "{dst}"')
            return False

    if not ignore_version:
        if version.get('version') != file.get('version'):
            log.warn(f'Version mismatch between configuration and prefix "{dst}"')
            return False
        if _genvw_metadata_has_strong_fields(file):
            if not _genvw_validate_target_against_metadata(target, file):
                log.warn(f'SHA-256/size mismatch between manifest and prefix "{dst}"')
                return False
        else:
            with target.open('rb') as dst_fd:
                dst_md5 = hashlib.md5(dst_fd.read()).hexdigest().lower()
            file_md5 = file.get('md5_hash')
            if file_md5 is not None and dst_md5 != str(file_md5).lower():
                log.warn(f'MD5 checksum mismatch between manifest and prefix "{dst}"')
                return False
        log.debug(f'Found matching file in prefix "{dst}"')

    return True"""

def check_upscaler_files_function_block() -> str:
    return """def __check_upscaler_files(
    prefix_dir: str, files: dict, version_file: str, ignore_version: bool
) -> tuple[bool, set, str]:
    if not os.path.isfile(version_file):
        log.warn(f'Missing version file "{version_file}"')
        return False, set(), ''

    try:
        with open(version_file, encoding='utf-8') as version_fd:
            version = json.loads(version_fd.read())
        for dst, file in files.items():
            entry = version[dst]
            _ = entry.get('md5_hash')
            if _genvw_metadata_has_strong_fields(file):
                if not _genvw_metadata_has_strong_fields(entry):
                    raise KeyError(f'missing strong metadata for {dst}')
                _ = entry['sha256_hash']
                _ = entry['size']
    except Exception as e:
        log.warn(f'Error while reading version file "{version_file}"')
        log.warn(repr(e))
        return False, set(), ''

    valid_files = tuple(
        __check_upscaler_file(prefix_dir, dst, files[dst], version[dst], ignore_version)
        for dst in files.keys()
    )

    dll_names = set([Path(f).name for f in files.keys()])
    paths = tuple(path for path in files.keys())
    parts = list(Path(paths[0]).parts)
    parts.remove(Path(paths[0]).name)
    parts.remove('drive_c')
    parts.insert(0, 'c:')
    windows_path = '\\\\'.join(parts)

    return all(valid_files), dll_names, windows_path"""

def download_upscaler_files_function_block() -> str:
    return """def __download_upscaler_files(
    prefix_dir: str,
    files: dict,
    dlfunc: Callable[[dict, Path, Path], None],
    version_file: str,
) -> bool:
    \"\"\"Download and install the required dlls.\"\"\"
    cache_dir = config.path.cache_dir.joinpath('upscalers')
    version = {}
    for dst in files.keys():
        log.info(f'Downloading upscaler file "{os.path.basename(dst)}"')
        file = Path(prefix_dir, dst)
        temp = Path(prefix_dir, dst + '.old')
        try:
            if file.exists() or file.is_symlink():
                file.rename(temp)
            dlfunc(files[dst], cache_dir, file)
            temp.unlink(missing_ok=True)
        except Exception as e:
            log.crit(f'Error while downloading file "{file.name}"')
            log.crit(repr(e))
            file.unlink(missing_ok=True)
            if temp.exists() or temp.is_symlink():
                temp.rename(file)
            return False
        version[dst] = {
            'version': files[dst]['version'],
            'md5_hash': files[dst].get('md5_hash'),
        }
        if _genvw_metadata_has_strong_fields(files[dst]):
            version[dst]['sha256_hash'] = files[dst]['sha256_hash']
            version[dst]['size'] = files[dst]['size']
        if files[dst].get('genvw_version'):
            version[dst]['genvw_version'] = files[dst]['genvw_version']
    with open(version_file, 'w', encoding='utf-8') as version_fd:
        version_fd.write(json.dumps(version))
    return True"""

def setup_upscalers_function_block() -> str:
    return """def setup_upscalers(
    compat_config: set, env: dict, compat_dir: str, prefix_dir: str
) -> None:
    \"\"\"Setup configured upscalers

    usage: setup_upscalers(g_session.compat_config, g_session.env, g_compatdata.base_dir, g_compatdata.prefix_dir)
    \"\"\"
    loaddll_replace = set()
    fsr4_key, fsr4_version = _genvw_fsr4_runtime_requested_version(env)
    if 'dlss' in compat_config:
        enabled, _, _ = genvw_setup_upscaler(
            env, 'PROTON_DLSS_UPGRADE', 'dlss', compat_dir, prefix_dir
        )
        if enabled:
            loaddll_replace.add('dlss')
    if 'xess' in compat_config:
        enabled, _, _ = genvw_setup_upscaler(
            env, 'PROTON_XESS_UPGRADE', 'xess', compat_dir, prefix_dir
        )
        if enabled:
            loaddll_replace.add('xess')
    if 'fsr3' in compat_config:
        enabled, _, _ = genvw_setup_upscaler(
            env, 'PROTON_FSR3_UPGRADE', 'fsr3', compat_dir, prefix_dir
        )
        if enabled:
            loaddll_replace.add('fsr3')
    if fsr4_version:
        enabled, _, _ = genvw_setup_upscaler(
            env, fsr4_key, 'fsr4', compat_dir, prefix_dir, fsr4_version
        )
        if enabled:
            loaddll_replace.add('fsr4')
    elif 'fsr4rdna3' in compat_config:
        enabled, _, _ = genvw_setup_upscaler(
            env, 'PROTON_FSR4_RDNA3_UPGRADE', 'fsr4', compat_dir, prefix_dir, '4.0.0'
        )
        if enabled:
            loaddll_replace.add('fsr4')
    elif 'fsr4' in compat_config:
        enabled, _, _ = genvw_setup_upscaler(
            env, 'PROTON_FSR4_UPGRADE', 'fsr4', compat_dir, prefix_dir
        )
        if enabled:
            loaddll_replace.add('fsr4')

    if 'fsr4' in loaddll_replace:
        env['FSR4_UPGRADE'] = '1'
        if 'mlfg' in compat_config:
            env['MLFG_UPGRADE'] = '1'
        if fsr4_key == 'PROTON_FSR4_RDNA3_UPGRADE' or 'fsr4rdna3' in compat_config:
            env['DXIL_SPIRV_CONFIG'] = 'wmma_rdna3_workaround'

    if 'dlss' in loaddll_replace:
        env.setdefault(
            'DXVK_NVAPI_DRS_SETTINGS',
            str(
                'ngx_dlss_sr_override=on,'
                'ngx_dlss_rr_override=on,'
                'ngx_dlss_fg_override=on,'
                'ngx_dlss_sr_override_render_preset_selection=default,'
                'ngx_dlss_rr_override_render_preset_selection=default,'
            ),
        )

    if 'xess' in loaddll_replace:
        pass

    if 'fsr3' in loaddll_replace:
        pass

    if loaddll_replace:
        env['WINE_LOADDLL_REPLACE'] = ','.join(loaddll_replace)"""

def main() -> int:
    if len(sys.argv) != 2:
        print("Usage: patch_upscalers.py /path/to/upscalers.py", file=sys.stderr)
        return 2
    path = Path(sys.argv[1])
    if not path.exists():
        print(f"ERROR: not found: {path}", file=sys.stderr)
        return 2

    src = path.read_text(encoding="utf-8", errors="replace")

    src2 = add_imports(src)
    src2 = inject_helper_block(src2)
    src2 = replace_function(src2, "__get_fsr4_dlls", get_fsr4_function_block())
    src2 = replace_function(src2, "__download_fsr4", download_fsr4_function_block())
    src2 = replace_function(src2, "__check_upscaler_file", check_upscaler_file_function_block())
    src2 = replace_function(src2, "__check_upscaler_files", check_upscaler_files_function_block())
    src2 = replace_function(src2, "__download_upscaler_files", download_upscaler_files_function_block())
    src2 = replace_function(src2, "setup_upscalers", setup_upscalers_function_block())

    if src2 == src:
        print("OK: upscalers.py already patched")
        return 0

    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(src2, encoding="utf-8")
    tmp.replace(path)
    print("APPLIED: upscalers.py gENVW FSR4 universal backend")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())

PY

  local __py_sources=""
  __py_sources="$(fsr4_trusted_sources_python_entries)"
  python3 - "$T_UP" "$__py_sources" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
sources = sys.argv[2]
text = path.read_text(encoding="utf-8")
text = text.replace("__GENVW_FSR4_PY_SOURCES__", sources)
path.write_text(text, encoding="utf-8")
PY
  unset __py_sources

  cat >"$T_VDF" <<'PY'
import re
import sys
from pathlib import Path

p = Path(sys.argv[1])
base = sys.argv[2]
dstbase = sys.argv[3]
display = sys.argv[4] if len(sys.argv) >= 5 else ""
tag = sys.argv[5] if len(sys.argv) >= 6 else ""

orig = p.read_text(encoding="utf-8")
text = orig

# Format A: compat_tools key rename (first match only)
pat_key = re.compile(r"(^\s*\")" + re.escape(base) + r"(\")(\s*(?://[^\n]*)?\s*\n\s*\{)", re.M)
text, _ = pat_key.subn(r"\1" + dstbase + r"\2\3", text, count=1)

# Format B: compatibilitytool mapping (fallback; safe no-op if absent)
text = text.replace(f"\"compatibilitytool\" \"{base}\"", f"\"compatibilitytool\" \"{dstbase}\"")

if not display:
    display = dstbase
if tag:
    display = display + tag

# display_name: replace first value
pat_dn = re.compile(r"(^\s*\"display_name\"\s*\")([^\"]*)(\")", re.M)
def dn_repl(m):
    return m.group(1) + display + m.group(3)
text, _ = pat_dn.subn(dn_repl, text, count=1)

if text != orig:
    p.write_text(text, encoding="utf-8")
    print("patched")
else:
    print("no-op")
PY
}

patch_guard_target() {
  # block symlinks and anything outside the clone root
  # patch_guard_target CLONE_ROOT PATH [LABEL]
  local root="$1" path="$2" label="${3:-file}"

  [[ -e "$path" || -L "$path" ]] || return 0

  if [[ -L "$path" ]]; then
    err "Refusing to patch symlink ($label): $path"
    return 1
  fi
  if [[ ! -f "$path" ]]; then
    err "Refusing to patch non-regular file ($label): $path"
    return 1
  fi

  local root_real file_real
  root_real="$(readlink -f -- "$root" 2>/dev/null)" || {
    err "Refusing to patch ($label): cannot resolve clone root: $root"
    return 1
  }
  file_real="$(readlink -f -- "$path" 2>/dev/null)" || {
    err "Refusing to patch ($label): cannot resolve path: $path"
    return 1
  }

  case "$file_real" in
    "$root_real"/*) return 0 ;;
    *)
      err "Refusing to patch outside clone root ($label): $file_real"
      return 1
      ;;
  esac
}

# patch_clone_with_temp_patchers
# run patching in a subshell; temp patchers live in a temp dir

patch_clone_with_temp_patchers() {
  (
    set -euo pipefail
    local dst="$1" base="$2" dstbase="$3"
    local tdir
    tdir="$(mktemp -d -t genvw_proton_patchers.XXXXXX)"
    trap "rm -rf -- $(printf '%q' "$tdir")" EXIT

    # keep patchers in the temp dir, one rm -rf cleans it
    T_UP="$tdir/patch_upscalers.py"
    T_VDF="$tdir/patch_vdf.py"

    make_temp_patchers
    patch_clone "$dst" "$base" "$dstbase"
  )
}

# patch_clone
# patch a cloned tool so steam sees it and local dll routing works

patch_clone() {
  local dst="$1"
  local base="$2"
  local dstbase="$3"

  local display_name=""
  local up="$dst/protonfixes/upscalers.py"
  local vdf="$dst/compatibilitytool.vdf"

  display_name="$(steam_display_name_for_cachyos "$base" "$dstbase" 2>/dev/null || true)"
  [[ -n "$display_name" ]] || display_name="$dstbase"

  if [[ -f "$up" ]]; then
    patch_guard_target "$dst" "$up" "upscalers.py" || return 1
    patch_guard_target "$dst" "$up.bak" "upscalers.py backup" || return 1
    cp -a -- "$up" "$up.bak"
    local out
    out="$(python3 "$T_UP" "$up" 2>&1)" || {
      err "$out"
      return 1
    }
    msg "${I_PUZZLE} upscalers.py: $out"
    python3 -m py_compile "$up" >/dev/null 2>&1 || {
      err "py_compile failed for $up"
      return 1
    }
  else
    warn "Missing: $up"
  fi

  if [[ -f "$vdf" ]]; then
    patch_guard_target "$dst" "$vdf" "compatibilitytool.vdf" || return 1
    patch_guard_target "$dst" "$vdf.bak" "compatibilitytool.vdf backup" || return 1
    cp -a -- "$vdf" "$vdf.bak"
    local out2
    out2="$(python3 "$T_VDF" "$vdf" "$base" "$dstbase" "$display_name" "$TAG" 2>&1)" || {
      err "$out2"
      return 1
    }
    msg "${I_RECEIPT} compatibilitytool.vdf: $out2"

    local tm="$dst/toolmanifest.vdf"
    if [[ -f "$tm" ]]; then
      patch_guard_target "$dst" "$tm" "toolmanifest.vdf" || return 1
      patch_guard_target "$dst" "$tm.bak" "toolmanifest.vdf backup" || return 1
      cp -a -- "$tm" "$tm.bak"
      local out3
      out3="$(python3 "$T_VDF" "$tm" "$base" "$dstbase" "$display_name" "$TAG" 2>&1)" || {
        err "$out3"
        return 1
      }
      msg "${I_RECEIPT} toolmanifest.vdf: $out3"
    else
      warn "Missing: $tm"
    fi
  else
    warn "Missing: $vdf"
  fi
}

# cleanup_partial_clone
# cleanup after an interrupted rebuild (temp patchers + partial destination)

cleanup_partial_clone() {
  # patchers live in patch_clone_with_temp_patchers() temp dir
  # that subshell EXIT trap removes them
  # don’t touch $T_UP/$T_VDF here
  local had_errexit=0
  case "$-" in
    *e*) had_errexit=1 ;;
  esac
  set +e

  if [[ -n "${CURRENT_DST:-}" && -d "${CURRENT_DST:-}" ]]; then
    # never allow ctd to be "/" (hard stop)
    if [[ "${CTD:-}" == "/" ]]; then
      warn "Refusing cleanup: CTD is '/'."
    elif command -v realpath >/dev/null 2>&1; then
      # use realpath when present (handles symlinks/..)
      local ctd_r dst_r
      ctd_r="$(realpath -m -- "${CTD:-}" 2>/dev/null || true)"
      dst_r="$(realpath -m -- "$CURRENT_DST" 2>/dev/null || true)"
      if [[ -n "$ctd_r" && -n "$dst_r" && "$dst_r" == "$ctd_r/"* ]]; then
        warn "Interrupted/failed; removing partial clone: $(basename "$CURRENT_DST")"
        rm_rf_within_root "$CTD" "$CURRENT_DST" >/dev/null 2>&1 || true
      else
        warn "Refusing to remove CURRENT_DST outside CTD safety bounds: $CURRENT_DST"
      fi
    else
      # fallback: string prefix check
      if [[ -n "${CTD:-}" && "$CURRENT_DST" == "$CTD/"* ]]; then
        warn "Interrupted/failed; removing partial clone: $(basename "$CURRENT_DST")"
        rm_rf_within_root "$CTD" "$CURRENT_DST" >/dev/null 2>&1 || true
      else
        warn "Refusing to remove CURRENT_DST outside CTD safety bounds: $CURRENT_DST"
      fi
    fi
  fi

  CURRENT_DST=""
  if ((had_errexit == 1)); then
    set -e
  else
    set +e
  fi
  return 0
}

# patch capability gates:

source_major_is_default_10() {
  case "${1:-}" in
    10 | 10.0) return 0 ;;
    *) return 1 ;;
  esac
}

source_requires_patch_capability_check() {
  local src="${1:-}" rec="" parsed="" src_major="" date="" runtime="" arch=""

  rec="$(source_metadata_record "$src" 2>/dev/null || true)"
  [[ -n "$rec" ]] || return 0
  parsed="${rec#*|}"
  src_major="${parsed%%|*}"
  parsed="${parsed#*|}"
  date="${parsed%%|*}"
  parsed="${parsed#*|}"
  runtime="${parsed%%|*}"
  arch="${parsed#*|}"

  [[ "$arch" == "protonplus-unspecified" ]] && return 0
  source_major_is_default_10 "$src_major" && return 1
  return 0
}

source_patch_capability_set_reason() {
  local out_var="${1:-}" value="${2:-unknown}"
  [[ -n "$out_var" ]] && printf -v "$out_var" '%s' "$value"
}

source_is_patch_capable_target() {
  local src="${1:-}" out_reason_var="${2:-}"

  if ! source_requires_patch_capability_check "$src"; then
    source_patch_capability_set_reason "$out_reason_var" "ok"
    return 0
  fi

  source_patch_capability_check "$src" "$out_reason_var"
}

source_patch_capability_check() {
  local src="${1:-}" out_reason_var="${2:-}"
  local rec="" base="" dstbase="" up="" vdf="" tm=""
  local tmp="" clone="" rc=0

  source_patch_capability_set_reason "$out_reason_var" "unknown"
  [[ -d "$src" && ! -L "$src" ]] || {
    source_patch_capability_set_reason "$out_reason_var" "source_not_directory"
    return 1
  }

  rec="$(source_metadata_record "$src" 2>/dev/null || true)"
  [[ -n "$rec" ]] || {
    source_patch_capability_set_reason "$out_reason_var" "unrecognized_source"
    return 1
  }
  base="$(source_clone_vdf_source_base "$src")"
  dstbase="$(source_clone_basename "$src" "${SUFFIX:-$SUFFIX_DEFAULT}")"

  up="$src/protonfixes/upscalers.py"
  [[ -f "$up" ]] || {
    source_patch_capability_set_reason "$out_reason_var" "missing_upscalers_py"
    return 1
  }
  patch_guard_target "$src" "$up" "upscalers.py" >/dev/null 2>&1 || {
    source_patch_capability_set_reason "$out_reason_var" "unsafe_upscalers_py"
    return 1
  }

  vdf="$src/compatibilitytool.vdf"
  [[ -f "$vdf" ]] || {
    source_patch_capability_set_reason "$out_reason_var" "missing_compatibilitytool_vdf"
    return 1
  }
  patch_guard_target "$src" "$vdf" "compatibilitytool.vdf" >/dev/null 2>&1 || {
    source_patch_capability_set_reason "$out_reason_var" "unsafe_compatibilitytool_vdf"
    return 1
  }

  tm="$src/toolmanifest.vdf"
  if [[ -e "$tm" || -L "$tm" ]]; then
    [[ -f "$tm" ]] || {
      source_patch_capability_set_reason "$out_reason_var" "unsafe_toolmanifest_vdf"
      return 1
    }
    patch_guard_target "$src" "$tm" "toolmanifest.vdf" >/dev/null 2>&1 || {
      source_patch_capability_set_reason "$out_reason_var" "unsafe_toolmanifest_vdf"
      return 1
    }
  fi

  tmp="$(mktemp -d -t genvw_source_capability.XXXXXX)" || {
    source_patch_capability_set_reason "$out_reason_var" "mktemp_failed"
    return 1
  }
  clone="$tmp/source-probe"
  mkdir -p "$clone/protonfixes" || {
    rm -rf -- "$tmp"
    source_patch_capability_set_reason "$out_reason_var" "probe_setup_failed"
    return 1
  }
  cp -a -- "$up" "$clone/protonfixes/upscalers.py" || {
    rm -rf -- "$tmp"
    source_patch_capability_set_reason "$out_reason_var" "probe_copy_failed"
    return 1
  }
  cp -a -- "$vdf" "$clone/compatibilitytool.vdf" || {
    rm -rf -- "$tmp"
    source_patch_capability_set_reason "$out_reason_var" "probe_copy_failed"
    return 1
  }
  if [[ -f "$tm" ]]; then
    cp -a -- "$tm" "$clone/toolmanifest.vdf" || {
      rm -rf -- "$tmp"
      source_patch_capability_set_reason "$out_reason_var" "probe_copy_failed"
      return 1
    }
  fi

  (
    set -euo pipefail
    T_UP="$tmp/patch_upscalers.py"
    T_VDF="$tmp/patch_vdf.py"
    make_temp_patchers
    patch_clone "$clone" "$base" "$dstbase" >/dev/null
  ) >/dev/null 2>&1
  rc=$?
  rm -rf -- "$tmp"
  if ((rc != 0)); then
    source_patch_capability_set_reason "$out_reason_var" "patcher_probe_failed"
    return 1
  fi

  source_patch_capability_set_reason "$out_reason_var" "ok"
  return 0
}

filter_picked_by_patch_capability() {
  local -a kept=()
  local src="" base="" reason=""
  local printed_help=0

  for src in "${PICKED[@]}"; do
    if ! source_requires_patch_capability_check "$src"; then
      kept+=("$src")
      continue
    fi

    base="$(source_effective_base "$src")"
    if source_patch_capability_check "$src" reason; then
      kept+=("$src")
      continue
    fi

    warn "Unsupported source for patch/rebuild (capability check failed: ${reason}): $base"
    if ((printed_help == 0)); then
      warn "Source was discovered but will not be patched because this layout did not pass the local patcher probe."
      printed_help=1
    fi
  done

  PICKED=("${kept[@]}")
}

# filter_picked_by_min_date:

filter_picked_by_min_date() {
  # drop sources older than min_supported_date_genvw
  local min
  min="$(min_supported_date_genvw)"
  local -a kept=()
  local src base d
  local printed_help=0

  for src in "${PICKED[@]}"; do
    base="$(source_effective_base "$src")"
    d="$(source_build_date "$src" || true)"
    if [[ -z "$d" ]]; then
      kept+=("$src")
      continue
    fi

    if ! is_supported_source_date "$d"; then
      warn "Unsupported source (too old for gENVW patch set): $base"

      if ((printed_help == 0)); then
        warn "${I_TOOLBOX} Minimum supported build date for gENVW patching: $min"
        warn "${I_ARROW} You can rebuild a supported tool date anytime (if sources exist):"
        warn "   $(cmd_proton) rebuild --date YYYYMMDD"
        warn "${I_BOX} Sources = Proton-CachyOS folders installed in compatibilitytools.d (NOT your -${SUFFIX} clones)."
        warn "${I_TOOLBOX} Get sources via ProtonUp-Qt: Add Version → Compatibility tool → Proton-CachyOS → Install"
        warn "   https://davidotek.github.io/protonup-qt/"
        warn "${I_RETRY} Restart Steam (Steam scans compatibilitytools.d at startup)"
        warn "${I_ARROW} Then run: $(cmd_proton) rebuild"
        printed_help=1
      fi

      continue
    fi

    kept+=("$src")
  done

  PICKED=("${kept[@]}")
}

cachyos_arch_rank() {
  # Returns numeric rank for arch field. Higher = preferred.
  local arch="${1:-}"
  case "$arch" in
    x86_64_v4 | protonplus-x86_64_v4) printf '%s\n' "4" ;;
    x86_64_v3 | protonplus-x86_64_v3) printf '%s\n' "3" ;;
    x86_64_v2 | protonplus-x86_64_v2) printf '%s\n' "2" ;;
    x86_64 | protonplus-x86_64 | system-x86_64) printf '%s\n' "1" ;;
    *) printf '%s\n' "0" ;;
  esac
}

cachyos_source_family_rank() {
  # protonup-qt preferred (1) over protonplus (0)
  local base="${1:-}"
  case "$base" in
    proton-cachyos-*) printf '%s\n' "1" ;;
    *) printf '%s\n' "0" ;;
  esac
}

cachyos_source_priority_for_path() {
  source_default_priority_for_path "${1:-}"
}

narrow_picked_to_preferred_cachyos_variant() {
  # Reduce PICKED[] to one preferred safe variant per major/date/runtime.
  # Preference: highest arch rank, then source priority, then existing basename order.
  local -A _best_arch=()   # key -> best arch rank seen
  local -A _best_priority=() # key -> best source priority seen
  local -A _best_src=()    # key -> best src path
  local _src _rec _base _parsed _major _date _runtime _arch _key _arch_rank _src_priority
  local _cur_arch _cur_priority

  for _src in "${PICKED[@]}"; do
    _rec="$(source_metadata_record "$_src" 2>/dev/null || true)"
    [[ -n "$_rec" ]] || continue
    _base="${_rec%%|*}"
    _parsed="${_rec#*|}"
    _major="${_parsed%%|*}"; _parsed="${_parsed#*|}"
    _date="${_parsed%%|*}"; _parsed="${_parsed#*|}"
    _runtime="${_parsed%%|*}"
    _arch="${_parsed#*|}"
    _key="${_major}|${_date}|${_runtime}"
    _arch_rank="$(cachyos_arch_rank "$_arch")"
    _src_priority="$(cachyos_source_priority_for_path "$_src")"

    if [[ -z "${_best_src[$_key]+x}" ]]; then
      _best_arch[$_key]="$_arch_rank"
      _best_priority[$_key]="$_src_priority"
      _best_src[$_key]="$_src"
      continue
    fi

    _cur_arch="${_best_arch[$_key]}"
    _cur_priority="${_best_priority[$_key]}"

    if (( _arch_rank > _cur_arch )); then
      _best_arch[$_key]="$_arch_rank"
      _best_priority[$_key]="$_src_priority"
      _best_src[$_key]="$_src"
    elif (( _arch_rank == _cur_arch && _src_priority > _cur_priority )); then
      _best_priority[$_key]="$_src_priority"
      _best_src[$_key]="$_src"
    fi
  done

  local -a _kept=()
  for _src in "${PICKED[@]}"; do
    _rec="$(source_metadata_record "$_src" 2>/dev/null || true)"
    [[ -n "$_rec" ]] || { _kept+=("$_src"); continue; }
    _base="${_rec%%|*}"
    _parsed="${_rec#*|}"
    _major="${_parsed%%|*}"; _parsed="${_parsed#*|}"
    _date="${_parsed%%|*}"; _parsed="${_parsed#*|}"
    _runtime="${_parsed%%|*}"
    _key="${_major}|${_date}|${_runtime}"
    [[ "${_best_src[$_key]:-}" == "$_src" ]] || continue
    _kept+=("$_src")
  done
  PICKED=("${_kept[@]}")
}

dwproton_release_major_key() {
  # From release like "11.0-2" extract major key "11.0"
  local rel="${1:-}"
  printf '%s\n' "${rel%-*}"
}

dwproton_release_patch_num() {
  # From release like "11.0-2" extract patch number "2" (numeric)
  local rel="${1:-}"
  printf '%s\n' "${rel##*-}"
}

dwproton_pick_default_targets_by_major() {
  # Filter dw_targets array (by-ref in) to newest safe release per major.
  # Uses numeric comparison for release patch numbers (10.0-10 > 10.0-9).
  local -n _dpdm_in="$1"
  local -n _dpdm_out="$2"
  _dpdm_out=()

  local -A _best_patch=()  # major_key -> best patch num seen
  local -A _best_entry=()  # major_key -> best entry path
  local _entry _base _ver _major_key _patch _row _base_label _status_label

  for _entry in "${_dpdm_in[@]}"; do
    _row="$(dwproton_display_row_record "$_entry" 2>/dev/null || true)"
    [[ -n "$_row" ]] || continue
    IFS=$'\t' read -r _ _ _ _ _ _ _base_label _ _ _ _status_label <<<"$_row" || continue
    [[ "$_base_label" != "unresolved" ]] || continue
    [[ "$_status_label" == "supported" || "$_status_label" == "installed" ]] || continue
    _base="$(basename "$_entry")"
    _ver="$(dwproton_folder_version "$_base" 2>/dev/null || true)"
    [[ -n "$_ver" ]] || continue
    _major_key="$(dwproton_release_major_key "$_ver")"
    _patch="$(dwproton_release_patch_num "$_ver")"
    [[ "$_patch" =~ ^[0-9]+$ ]] || continue

    if [[ -z "${_best_entry[$_major_key]+x}" ]] || (( _patch > _best_patch[$_major_key] )); then
      _best_patch[$_major_key]="$_patch"
      _best_entry[$_major_key]="$_entry"
    fi
  done

  local _key
  for _key in "${!_best_entry[@]}"; do
    _dpdm_out+=("${_best_entry[$_key]}")
  done
}

rebuild_dll_trust_advisory() {
  # after rebuild, print one-line trust status for the local dll (if present)
  # runs do_check in a subshell so it doesn't touch caller state
  local dst_dir="${DLL_DST_DIR_DEFAULT}"
  local expected="$dst_dir/${AMD_DLL_NAME}"

  [[ -f "$expected" ]] || return 0

  local kv="" k="" v=""
  local meta_match="0" meta_reason="unknown"
  local allow_match="0" allow_reason="unknown"

  local -a args=(--kv)
  [[ -n "${CTD:-}" ]] && args+=(--ctd "$CTD")
  [[ -n "${MAJOR:-}" ]] && args+=(--major "$MAJOR")
  [[ -n "${SUFFIX:-}" ]] && args+=(--suffix "$SUFFIX")
  [[ -n "${TAG:-}" ]] && args+=(--tag "$TAG")
  [[ -n "${FSR4_VER:-}" ]] && args+=(--ver "$FSR4_VER")

  kv="$( (do_check "${args[@]}") 2>/dev/null || true)"
  [[ -n "$kv" ]] || return 0

  amd_dll_trust_snapshot_from_kv "$kv" meta_match meta_reason allow_match allow_reason

  if [[ "$meta_match" == "1" && "$allow_match" == "1" ]]; then
    ok "${I_SHIELD} DLL trust: Trusted (META_MATCH=1, ALLOWLIST_MATCH=1)"
  else
    local trust_warning_summary=""
    amd_dll_trust_raw_warning_summary "$meta_match" "$meta_reason" "$allow_match" "$allow_reason" trust_warning_summary
    warn "${I_SHIELD} DLL present but untrusted (${trust_warning_summary})"
  fi
  return 0
}

rebuild_collect_dll_trust_status() {
  local -n out_state_ref="$1"
  local -n out_detail_ref="$2"
  local dst_dir="${DLL_DST_DIR_DEFAULT}"
  local expected="$dst_dir/${AMD_DLL_NAME}"

  out_state_ref="MISSING"
  out_detail_ref="local cache missing"
  [[ -f "$expected" ]] || return 0

  local kv="" k="" v=""
  local meta_match="0" meta_reason="unknown"
  local allow_match="0" allow_reason="unknown"
  local -a args=(--kv)
  [[ -n "${CTD:-}" ]] && args+=(--ctd "$CTD")
  [[ -n "${MAJOR:-}" ]] && args+=(--major "$MAJOR")
  [[ -n "${SUFFIX:-}" ]] && args+=(--suffix "$SUFFIX")
  [[ -n "${TAG:-}" ]] && args+=(--tag "$TAG")
  [[ -n "${FSR4_VER:-}" ]] && args+=(--ver "$FSR4_VER")

  kv="$( (do_check "${args[@]}") 2>/dev/null || true)"
  [[ -n "$kv" ]] || {
    out_state_ref="WARN"
    out_detail_ref="could not collect trust state"
    return 0
  }

  amd_dll_trust_snapshot_from_kv "$kv" meta_match meta_reason allow_match allow_reason

  if [[ "$meta_match" == "1" && "$allow_match" == "1" ]]; then
    out_state_ref="READY"
    out_detail_ref="trusted"
  else
    out_state_ref="BLOCKED"
    out_detail_ref="META_MATCH=${meta_match} (${meta_reason}), ALLOWLIST_MATCH=${allow_match} (${allow_reason})"
  fi
  return 0
}

rebuild_patch_status_from_output() {
  local patch_out="${1:-}"
  local -n out_up_ref="$2"
  local -n out_vdf_ref="$3"
  local -n out_tm_ref="$4"

  local up_line="" vdf_line="" tm_line=""
  out_up_ref="UNKNOWN"
  out_vdf_ref="UNKNOWN"
  out_tm_ref="UNKNOWN"

  up_line="$(printf '%s\n' "$patch_out" | sed -nE 's/^.*upscalers\.py: //p' | head -n1)"
  vdf_line="$(printf '%s\n' "$patch_out" | sed -nE 's/^.*compatibilitytool\.vdf: //p' | head -n1)"
  tm_line="$(printf '%s\n' "$patch_out" | sed -nE 's/^.*toolmanifest\.vdf: //p' | head -n1)"

  case "$up_line" in
    APPLIED:*) out_up_ref="APPLIED" ;;
    OK:*) out_up_ref="ALREADY" ;;
  esac
  case "$vdf_line" in
    patched) out_vdf_ref="PATCHED" ;;
    no-op) out_vdf_ref="NO-OP" ;;
  esac
  case "$tm_line" in
    patched) out_tm_ref="PATCHED" ;;
    no-op) out_tm_ref="NO-OP" ;;
  esac

  if printf '%s\n' "$patch_out" | grep -Eq 'Missing: .*/upscalers\.py$'; then
    out_up_ref="MISSING"
  fi
  if printf '%s\n' "$patch_out" | grep -Eq 'Missing: .*/compatibilitytool\.vdf$'; then
    out_vdf_ref="MISSING"
  fi
  if printf '%s\n' "$patch_out" | grep -Eq 'Missing: .*/toolmanifest\.vdf$'; then
    out_tm_ref="MISSING"
  fi
}

dwproton_rebuild_shape_enabled() {
  case "${1:-}" in
    private_bool_loaddll|private_tuple_upscaler_replace|public_optiscaler_aware) return 0 ;;
    *) return 1 ;;
  esac
}

dwproton_collect_rebuild_plans() {
  local targets_name="${1:-}" names_name="${2:-}" actions_name="${3:-}" statuses_name="${4:-}"
  local reasons_name="${5:-}" sources_name="${6:-}" roots_name="${7:-}" classes_name="${8:-}"
  local -n targets_ref="$targets_name"
  local -n names_ref="$names_name"
  local -n actions_ref="$actions_name"
  local -n statuses_ref="$statuses_name"
  local -n reasons_ref="$reasons_name"
  local -n sources_ref="$sources_name"
  local -n roots_ref="$roots_name"
  local -n classes_ref="$classes_name"
  local src="" record="" record_rc=0 status="" action="" name="" reason="" clone_root="" stage_class=""

  names_ref=()
  actions_ref=()
  statuses_ref=()
  reasons_ref=()
  sources_ref=()
  roots_ref=()
  classes_ref=()

  for src in "${targets_ref[@]}"; do
    record_rc=0
    record="$(dwproton_fsr4_rebuild_plan_disabled "$src" "$CTD" "$SUFFIX" "${FSR4_VER:-$FSR4_LOCAL_DEFAULT_VER}" 2>/dev/null)" || record_rc=$?
    status="$(dwproton_record_value "$record" DW_REBUILD_PLAN_STATUS)"
    action="$(dwproton_record_value "$record" DW_REBUILD_ACTION)"
    name="$(dwproton_record_value "$record" CLONE_BASENAME)"
    reason="$(dwproton_record_value "$record" PLAN_REASON)"
    clone_root="$(dwproton_record_value "$record" CLONE_ROOT)"
    stage_class="$(dwproton_record_value "$record" ASSEMBLY_CLASS)"

    [[ -n "$status" ]] || status="blocked"
    [[ -n "$action" ]] || action="BLOCK"
    [[ -n "$name" && "$name" != "unresolved" ]] || name="${src##*/}"
    [[ -n "$reason" ]] || reason="dwproton_support_not_enabled"
    [[ -n "$stage_class" ]] || stage_class="unknown"
    [[ "$action" != "SKIP" ]] || continue

    if ((record_rc != 0)) || [[ "$status" != "ready" || "$clone_root" == "unresolved" || -z "$clone_root" ]]; then
      status="blocked"
      action="BLOCK"
    elif ! dwproton_rebuild_shape_enabled "$stage_class"; then
      status="blocked"
      action="BLOCK"
      reason="dwproton_shape_not_enabled"
    fi

    names_ref+=("$name")
    actions_ref+=("$action")
    statuses_ref+=("$status")
    reasons_ref+=("$reason")
    sources_ref+=("$src")
    roots_ref+=("$clone_root")
    classes_ref+=("$stage_class")
  done
}

dwproton_print_rebuild_plan() {
  local names_name="${1:-}" actions_name="${2:-}" reasons_name="${3:-}"
  local -n names_ref="$names_name"
  local -n actions_ref="$actions_name"
  local idx=0

  : "$reasons_name"
  ((${#names_ref[@]} > 0)) || return 0
  msg ""
  msg "DW-Proton Plan:"
  printf '  %-8s %s\n' "ACTION" "NAME"
  for ((idx = 0; idx < ${#names_ref[@]}; idx++)); do
    printf '  %-8s %s\n' "$(rebuild_human_action "${actions_ref[idx]}")" "${names_ref[idx]}"
  done
}

rebuild_human_action() {
  case "${1:-}" in
    REPLACE | REBUILD) printf '%s\n' "REBUILD" ;;
    CREATE) printf '%s\n' "CREATE" ;;
    SKIP) printf '%s\n' "SKIP" ;;
    *) printf '%s\n' "${1:-SKIP}" ;;
  esac
}

dwproton_human_rebuild_detail() {
  case "${1:-}" in
    dwproton_validation_failed) printf '%s\n' "validation failed" ;;
    dwproton_publish_failed) printf '%s\n' "publish failed" ;;
    dwproton_restore_failed) printf '%s\n' "restore failed after publish error" ;;
    dwproton_unrecognized_shape) printf '%s\n' "unsupported upscalers.py shape" ;;
    dwproton_unknown_version) printf '%s\n' "unknown DW-Proton version" ;;
    unsafe_clone_candidate) printf '%s\n' "unsafe clone candidate" ;;
    unsafe_output_path) printf '%s\n' "unsafe output path" ;;
    dwproton_writer_not_ready) printf '%s\n' "upscalers.py writer not ready" ;;
    "") printf '%s\n' "blocked" ;;
    *) printf '%s\n' "${1//_/ }" ;;
  esac
}

rebuild_print_result_table() {
  local title="${1:-Result:}" names_name="${2:-}" up_name="${3:-}" vdf_name="${4:-}" tm_name="${5:-}"
  local actions_name="${6:-}" results_name="${7:-}"
  local -n names_ref="$names_name"
  local -n up_ref="$up_name"
  local -n vdf_ref="$vdf_name"
  local -n tm_ref="$tm_name"
  local -n actions_ref="$actions_name"
  local -n results_ref="$results_name"
  local idx=0 name_width=4

  ((${#names_ref[@]} > 0)) || return 0
  for ((idx = 0; idx < ${#names_ref[@]}; idx++)); do
    ((${#names_ref[idx]} > name_width)) && name_width=${#names_ref[idx]}
  done

  msg "$title"
  printf '  %-*s %-10s %-10s %-12s %-8s %s\n' "$name_width" "NAME" "UPSCALERS" "COMPAT_VDF" "TOOLMANIFEST" "ACTION" "RESULT"
  for ((idx = 0; idx < ${#names_ref[@]}; idx++)); do
    printf '  %-*s %-10s %-10s %-12s %-8s %s\n' \
      "$name_width" "${names_ref[idx]}" "${up_ref[idx]}" "${vdf_ref[idx]}" "${tm_ref[idx]}" \
      "$(rebuild_human_action "${actions_ref[idx]}")" "${results_ref[idx]}"
  done
  msg ""
}

print_dwproton_rebuild_sources_table() {
  local sources_name="${1:-}" src="" row="" major_rank="" minor_rank="" build_rank="" sort_date="" base=""
  local version="" _base_label="" _runtime="" arch="" _source_label="" _status_label=""
  local -n sources_ref="$sources_name"
  local -a rows=()

  msg "DW-Proton Sources:"
  if ((${#sources_ref[@]} == 0)); then
    msg "  No DW-Proton sources found."
    return 0
  fi

  printf '  %-8s %-9s %s\n' "PROVIDER" "VERSION" "ARCH"
  for src in "${sources_ref[@]}"; do
    row="$(dwproton_display_row_record "$src" 2>/dev/null || true)"
    [[ -n "$row" ]] || continue
    rows+=("$row")
  done

  while IFS=$'\t' read -r major_rank minor_rank build_rank sort_date base version _base_label _runtime arch _source_label _status_label; do
    [[ -n "$major_rank" ]] || continue
    printf '  %-8s %-9s %s\n' "dwproton" "$version" "$arch"
  done < <(printf '%s\n' "${rows[@]}" | sort -t $'\t' -k1,1nr -k2,2nr -k3,3nr -k4,4r -k5,5r)
}

# do_rebuild
# rebuild gENVW proton tools for the chosen date

restore_one_trap() {
  local spec="${1-}" sig="${2-}"
  [[ -n "${sig}" ]] || return 0
  if [[ -z "${spec}" ]]; then
    trap - "${sig}" 2>/dev/null || true
    return 0
  fi
  # bash trap -p form: trap -- 'cmd' SIGINT (or EXIT/RETURN)
  if [[ "${spec}" =~ ^trap[[:space:]]+--[[:space:]]+\'([[:print:][:space:]]*)\'[[:space:]]+[A-Z0-9]+$ ]]; then # trap-parse-multiline-v3
    trap -- "${BASH_REMATCH[1]}" "${sig}"
    return 0
  fi
  # also handle $'...' quoting
  if [[ "${spec}" =~ ^trap[[:space:]]+--[[:space:]]+\$\'([[:print:][:space:]]*)\'[[:space:]]+[A-Z0-9]+$ ]]; then
    local cmd
    cmd="$(printf '%b' "${BASH_REMATCH[1]}")"
    trap -- "${cmd}" "${sig}"
    return 0
  fi
  # unknown trap spec format: clear this signal trap safely.
  trap - "${sig}" 2>/dev/null || true
}

restore_traps_clone() {
  # guard against re-entry
  trap - RETURN 2>/dev/null || true

  restore_one_trap "${__GENVW_REBUILD_OLD_TRAP_EXIT:-}" EXIT
  restore_one_trap "${__GENVW_REBUILD_OLD_TRAP_INT:-}" INT
  restore_one_trap "${__GENVW_REBUILD_OLD_TRAP_TERM:-}" TERM
  restore_one_trap "${__GENVW_REBUILD_OLD_TRAP_RETURN:-}" RETURN
}

do_rebuild() {
  ALLOW_STEAM=0
  parse_rebuild_flags "$@"
  if [[ "${GENVW_KV_HELP:-0}" == "1" ]]; then
    return 0
  fi
  if [[ "${DWPROTON_PREVIEW:-0}" -eq 1 && "${DRY_RUN:-0}" -ne 1 ]]; then
    die "--dwproton-preview is only valid with rebuild --dry-run"
  fi
  fsr4_apply_effective_local_default_if_implicit "${DLL_DST_DIR_DEFAULT}"

  # rebuild --dry-run routes to the planner (no changes)
  if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
    do_dry_run "$@"
    return $?
  fi

  preflight_proton

  # local dll trust: show state, and offer reinstall when meta mismatches
  # when called from prep, skip the prompt here
  local __kv="" __k="" __v=""
  local __dll_present=0 __meta_match=0 __meta_reason="unknown" __allow_match=0 __allow_reason="unknown"
  local __reinstall_ver="${FSR4_VER:-$FSR4_LOCAL_DEFAULT_VER}"
  local __reinstall_supported=0
  if fsr4_ver_is_local_only_supported "${__reinstall_ver}"; then
    __reinstall_supported=1
  fi
  # keep precheck aligned with the current rebuild context (--ver/--ctd/etc).
  # run in a subshell so parse_kv_flags in do_check can't mutate this function state.
  local -a __check_args=(--kv)
  [[ -n "${CTD:-}" ]] && __check_args+=(--ctd "$CTD")
  [[ -n "${MAJOR:-}" ]] && __check_args+=(--major "$MAJOR")
  [[ -n "${SUFFIX:-}" ]] && __check_args+=(--suffix "$SUFFIX")
  [[ -n "${TAG:-}" ]] && __check_args+=(--tag "$TAG")
  [[ -n "${FSR4_VER:-}" ]] && __check_args+=(--ver "$FSR4_VER")
  __kv="$( (do_check "${__check_args[@]}") 2>/dev/null || true)"
  while IFS='=' read -r __k __v; do
    case "${__k}" in
      DLL_PRESENT) __dll_present="${__v}" ;;
    esac
  done <<<"${__kv}"
  amd_dll_trust_snapshot_from_kv "${__kv}" __meta_match __meta_reason __allow_match __allow_reason

  if [[ "${__dll_present}" -ne 1 ]]; then
    warn "Local DLL missing: ${LOCALDLL}"
    msg "${I_ARROW} Install:"
    msg "  $(cmd_dll) install --url \"${AMD_DRIVER_URL}\" --dst-dir \"${DLL_DST_DIR_DEFAULT}\""
    msg "  ${I_INFO} Source artifact must contain FSR4 ${__reinstall_ver}."
    if [[ "${__reinstall_supported}" -ne 1 ]]; then
      warn "Selected --ver ${__reinstall_ver} is outside local-write supported versions ($(fsr4_local_only_versions_slash)); install/prefix write paths are disabled for this version."
    fi
  elif [[ "${__meta_match}" -ne 1 || "${__allow_match}" -ne 1 ]]; then
    local __trust_warning_summary=""
    amd_dll_trust_raw_warning_summary "${__meta_match}" "${__meta_reason}" "${__allow_match}" "${__allow_reason}" __trust_warning_summary
    warn "${I_SHIELD} DLL present but untrusted (${__trust_warning_summary})"
    msg "${I_ARROW} Details:"
    msg "  $(cmd_dll) verify"

    if [[ "${GENVW_IN_PREP:-0}" -eq 1 ]]; then
      # prep already printed guidance
      :
    elif [[ "${__meta_match}" -ne 1 ]]; then
      if [[ "${__reinstall_supported}" -ne 1 ]]; then
        warn "${I_SHIELD} Skipping reinstall prompt: --ver ${__reinstall_ver} is outside local-write supported versions ($(fsr4_local_only_versions_slash))."
      elif is_tty && ask_yes_no_default "Reinstall local DLL now? [y/N]: " "n"; then
        step "Reinstalling local DLL (FSR4 ${__reinstall_ver})"
        GENVW_IN_PREP=1 GENVW_INSTALL_EXPECT_VER="${__reinstall_ver}" amd_dll_run install --url "${AMD_DRIVER_URL}" --dst-dir "${DLL_DST_DIR_DEFAULT}"
      fi
    else
      # allowlist mismatch: reinstall from the same url won't change that
      prep_dll_trust_summary "${LOCALDLL}"
    fi
  fi

  # trap state is kept in globals; return traps can run after locals are gone
  declare -g __GENVW_REBUILD_OLD_TRAP_EXIT __GENVW_REBUILD_OLD_TRAP_INT __GENVW_REBUILD_OLD_TRAP_TERM __GENVW_REBUILD_OLD_TRAP_RETURN
  __GENVW_REBUILD_OLD_TRAP_EXIT="$(trap -p EXIT 2>/dev/null || true)"
  __GENVW_REBUILD_OLD_TRAP_INT="$(trap -p INT 2>/dev/null || true)"
  __GENVW_REBUILD_OLD_TRAP_TERM="$(trap -p TERM 2>/dev/null || true)"
  __GENVW_REBUILD_OLD_TRAP_RETURN="$(trap -p RETURN 2>/dev/null || true)"
  # old code
  #trap 'cleanup_partial_clone' EXIT
  #trap 'cleanup_partial_clone; exit 130' INT
  #trap 'cleanup_partial_clone; exit 143' TERM
  #trap restore_traps_clone RETURN

  # new code
  # clear EXIT first so cleanup doesn't run twice on int/term
  trap 'cleanup_partial_clone' EXIT
  trap 'trap - EXIT 2>/dev/null || true; cleanup_partial_clone; exit 130' INT
  trap 'trap - EXIT 2>/dev/null || true; cleanup_partial_clone; exit 143' TERM
  trap restore_traps_clone RETURN

  if rebuild_includes_cachyos; then
    gather_sources
  else
    SOURCES=()
    PICKED=()
  fi
  local -a dw_targets=() dw_plan_names=() dw_plan_actions=() dw_plan_statuses=()
  local -a dw_plan_reasons=() dw_plan_sources=() dw_plan_roots=() dw_plan_classes=()
  if rebuild_includes_dwproton; then
    gather_dwproton_display_targets dw_targets
    if rebuild_target_kind_is_dw_release; then
      local -a dw_targets_filtered=()
      filter_dwproton_targets_by_release dw_targets dw_targets_filtered "${REBUILD_TARGET_ID:-}"
      if ((${#dw_targets_filtered[@]} == 0)); then
        die "DW-Proton target '${REBUILD_TARGET_ID:-}' not found in: $CTD"
      fi
      dw_targets=("${dw_targets_filtered[@]}")
    elif rebuild_target_kind_is_exact_id; then
      local -a dw_exact_filtered=()
      filter_dwproton_targets_by_exact_id dw_targets dw_exact_filtered "${REBUILD_TARGET_ID:-}"
      if ((${#dw_exact_filtered[@]} == 0)); then
        die "DW-Proton target id '${REBUILD_TARGET_ID:-}' not found in: $CTD"
      elif ((${#dw_exact_filtered[@]} > 1)); then
        die "DW-Proton target id '${REBUILD_TARGET_ID:-}' matched ${#dw_exact_filtered[@]} targets; expected exactly one."
      fi
      dw_targets=("${dw_exact_filtered[@]}")
    elif rebuild_target_kind_is_all_targets; then
      local -a dw_resolved_filtered=()
      local _dw_rt="" _dw_row=""
      for _dw_rt in "${dw_targets[@]}"; do
        _dw_row="$(dwproton_display_row_record "$_dw_rt" 2>/dev/null || true)"
        [[ -n "$_dw_row" ]] || continue
        IFS=$'\t' read -r _ _ _ _ _ _ _dw_bl _ _ _ _ <<<"$_dw_row" || continue
        [[ "$_dw_bl" == "unresolved" ]] && continue
        dw_resolved_filtered+=("$_dw_rt")
      done
      dw_targets=("${dw_resolved_filtered[@]}")
    elif rebuild_target_kind_is_default; then
      local -a dw_default_filtered=()
      dwproton_pick_default_targets_by_major dw_targets dw_default_filtered
      dw_targets=("${dw_default_filtered[@]}")
    fi
    dwproton_collect_rebuild_plans dw_targets dw_plan_names dw_plan_actions dw_plan_statuses dw_plan_reasons dw_plan_sources dw_plan_roots dw_plan_classes
  fi

  if ((${#SOURCES[@]} == 0 && ${#dw_plan_names[@]} == 0)); then
    die "No Proton-CachyOS sources found and no DW-Proton rebuild targets found in: $CTD ($(major_selection_error_label))"
  fi

  if ((${#SOURCES[@]} > 0)); then
    local newest_src_date="" newest_supported_date=""
    newest_src_date="$(detect_build_date)" || die "Could not detect build dates in Proton folder names."
    gather_supported_sources_from_sources
    newest_supported_date="$(detect_build_date_for_sources "${SUPPORTED_SOURCES[@]}" 2>/dev/null || true)"

    if [[ -n "$newest_supported_date" ]] && ! major_selection_is_all_supported; then
      if ! offer_rebuild_if_newer_available "$newest_supported_date"; then
        return 0
      fi
    fi

    if rebuild_target_kind_is_all_targets; then
      pick_all_supported_sources_for_rebuild
    elif rebuild_target_kind_is_exact_id; then
      pick_sources_for_exact_id
    else
      pick_sources_for_rebuild_selection "$newest_src_date" "$newest_supported_date"
    fi
    filter_picked_by_min_date
    ((${#PICKED[@]} > 0)) || die "No supported sources for gENVW patching. Minimum supported date: ${MIN_SUPPORTED_DATE_GENVW}"
    filter_picked_by_patch_capability
    ((${#PICKED[@]} > 0)) || die "No patch-capable sources for gENVW patching. Minimum supported date: ${MIN_SUPPORTED_DATE_GENVW}"
    if rebuild_target_kind_is_default; then
      narrow_picked_to_preferred_cachyos_variant
    fi
  else
    PICKED=()
  fi

  if [[ "${REBUILD_MISSING_ONLY:-0}" -eq 1 && ${#dw_plan_names[@]} -gt 0 ]]; then
    local -a dw_keep_names=() dw_keep_actions=() dw_keep_statuses=() dw_keep_reasons=() dw_keep_sources=() dw_keep_roots=() dw_keep_classes=()
    local dw_filter_idx=0
    for ((dw_filter_idx = 0; dw_filter_idx < ${#dw_plan_names[@]}; dw_filter_idx++)); do
      [[ "${dw_plan_actions[dw_filter_idx]}" == "CREATE" ]] || continue
      dw_keep_names+=("${dw_plan_names[dw_filter_idx]}")
      dw_keep_actions+=("${dw_plan_actions[dw_filter_idx]}")
      dw_keep_statuses+=("${dw_plan_statuses[dw_filter_idx]}")
      dw_keep_reasons+=("${dw_plan_reasons[dw_filter_idx]}")
      dw_keep_sources+=("${dw_plan_sources[dw_filter_idx]}")
      dw_keep_roots+=("${dw_plan_roots[dw_filter_idx]}")
      dw_keep_classes+=("${dw_plan_classes[dw_filter_idx]}")
    done
    dw_plan_names=("${dw_keep_names[@]}")
    dw_plan_actions=("${dw_keep_actions[@]}")
    dw_plan_statuses=("${dw_keep_statuses[@]}")
    dw_plan_reasons=("${dw_keep_reasons[@]}")
    dw_plan_sources=("${dw_keep_sources[@]}")
    dw_plan_roots=("${dw_keep_roots[@]}")
    dw_plan_classes=("${dw_keep_classes[@]}")
  fi

  local -a plan_actions=() plan_names=() rebuild_picked=()
  local src="" base="" dstbase="" dst=""
  for src in "${PICKED[@]}"; do
    dstbase="$(source_clone_basename "$src" "$SUFFIX")"
    dst="${CTD}/${dstbase}"
    if [[ -d "$dst" ]]; then
      [[ "${REBUILD_MISSING_ONLY:-0}" -eq 1 ]] && continue
      plan_actions+=("REBUILD")
    else
      plan_actions+=("CREATE")
    fi
    plan_names+=("$dstbase")
    rebuild_picked+=("$src")
  done

  local dw_ready_count=0 dw_idx=0
  for ((dw_idx = 0; dw_idx < ${#dw_plan_statuses[@]}; dw_idx++)); do
    [[ "${dw_plan_statuses[dw_idx]}" == "ready" ]] && dw_ready_count=$((dw_ready_count + 1))
  done
  if ((${#rebuild_picked[@]} == 0 && dw_ready_count == 0)); then
    msg "${I_RETRY} Rebuild"
    if [[ "${REBUILD_MISSING_ONLY:-0}" -eq 1 ]]; then
      rebuild_includes_cachyos && msg "  No missing CachyOS Proton gENVW clones."
      rebuild_includes_dwproton && msg "  No missing DW-Proton gENVW clones."
      return 0
    fi
    dwproton_print_rebuild_plan dw_plan_names dw_plan_actions dw_plan_reasons
    msg ""
    die "No rebuildable Proton-CachyOS or DW-Proton targets found in: $CTD ($(major_selection_error_label))"
  fi

  msg "${I_RETRY} Rebuild"
  msg ""
  if ((${#rebuild_picked[@]} > 0)); then
    msg "CachyOS Proton Sources:"
    print_source_summary_table "$MAJOR" "${rebuild_picked[@]}"
    msg ""
    msg "CachyOS Proton Plan:"
    printf '  %-8s %s\n' "ACTION" "NAME"
    local plan_idx=0
    for ((plan_idx = 0; plan_idx < ${#plan_names[@]}; plan_idx++)); do
      printf '  %-8s %s\n' "${plan_actions[plan_idx]}" "${plan_names[plan_idx]}"
    done
    msg ""
  fi
  if ((${#dw_plan_sources[@]} > 0)); then
    print_dwproton_rebuild_sources_table dw_plan_sources
  fi
  dwproton_print_rebuild_plan dw_plan_names dw_plan_actions dw_plan_reasons
  msg ""

  if steam_is_running; then
    local _steam_lines
    _steam_lines="$(steam_ps_lines 2>/dev/null || true)"

    local _summary
    _summary="$(printf '%s\n' "$_steam_lines" | steam_ps_summary)"

    err "Steam is running. Close Steam before rebuild (Steam caches tools at startup)."
    err "$_summary"
    if [[ "${ALLOW_STEAM:-0}" == "1" ]]; then
      err "--allow-steam does not permit write rebuild while Steam is running."
    fi

    # verbose steam ps output is noisy unless you ask for it
    if [[ -n "${GENVW_STEAM_VERBOSE:-}" ]]; then
      err "Detected Steam processes (verbose):"
      printf '%s\n' "$_steam_lines" \
        | awk '{ line=$0; if (length(line)>220) line=substr(line,1,220)"…"; print line }' \
        | sed 's/^/  /' >&2
    else
      if [[ "${ALLOW_STEAM:-0}" != "1" ]]; then
        err "(Tip: set GENVW_STEAM_VERBOSE=1 to print the full Steam process list.)"
      fi
    fi

    die "Close Steam and re-run."
  fi

  # patchers are built per-clone in a temp dir, so they don't leak into the main traps

  local built=0 total=0 rebuild_rc=0
  local created=0 rebuilt=0
  local -a names=() patch_up=() patch_vdf=() patch_tm=() patch_actions=() patch_results=()
  local patch_out="" patch_rc=0 up_status="" vdf_status="" tm_status=""
  local -a dw_result_names=() dw_result_up=() dw_result_vdf=() dw_result_tm=() dw_result_actions=() dw_result_results=() dw_result_details=()
  local dw_stage_out="" dw_stage_rc=0 dw_stage_status="" dw_stage_action="" dw_stage_reason=""

  for src in "${rebuild_picked[@]}"; do
    total=$((total + 1))
    base="$(source_clone_vdf_source_base "$src")"
    dstbase="$(source_clone_basename "$src" "$SUFFIX")"
    dst="${CTD}/${dstbase}"
    CURRENT_DST="$dst"

    if [[ -d "$dst" ]]; then
      local patch_action="REBUILD"
      rebuilt=$((rebuilt + 1))
      rm_rf_within_root "$CTD" "$dst" || die "Failed to remove $dst"
    else
      local patch_action="CREATE"
      created=$((created + 1))
    fi

    cp -a -- "$src" "$dst"
    chmod -R u+w -- "$dst"

    set +e
    patch_out="$(patch_clone_with_temp_patchers "$dst" "$base" "$dstbase" 2>&1)"
    patch_rc=$?
    set -e
    if ((patch_rc == 0)); then
      rebuild_patch_status_from_output "$patch_out" up_status vdf_status tm_status
      built=$((built + 1))
      names+=("$dstbase")
      patch_up+=("$up_status")
      patch_vdf+=("$vdf_status")
      patch_tm+=("$tm_status")
      patch_actions+=("$patch_action")
      patch_results+=("SUCCESS")
      CURRENT_DST=""
    else
      err "Patch failed; removing broken clone: $dstbase"
      [[ -n "$patch_out" ]] && printf '%s\n' "$patch_out" >&2
      rm_rf_within_root "$CTD" "$dst" || die "Failed to remove $dst"
      names+=("$dstbase")
      patch_up+=("${up_status:-UNKNOWN}")
      patch_vdf+=("${vdf_status:-UNKNOWN}")
      patch_tm+=("${tm_status:-UNKNOWN}")
      patch_actions+=("$patch_action")
      patch_results+=("FAILED")
      CURRENT_DST=""
    fi
  done

  for ((dw_idx = 0; dw_idx < ${#dw_plan_names[@]}; dw_idx++)); do
    [[ "${dw_plan_statuses[dw_idx]}" == "ready" ]] || continue
    total=$((total + 1))
    dw_stage_out=""
    dw_stage_rc=0
    set +e
    dw_stage_out="$(dwproton_fsr4_stage_clone_publish_disabled "${dw_plan_sources[dw_idx]}" "${dw_plan_roots[dw_idx]}" "$CTD" "$SUFFIX" "${FSR4_VER:-$FSR4_LOCAL_DEFAULT_VER}" 2>&1)"
    dw_stage_rc=$?
    set -e
    dw_stage_status="$(dwproton_record_value "$dw_stage_out" STAGE_STATUS)"
    dw_stage_action="$(dwproton_record_value "$dw_stage_out" STAGE_ACTION)"
    dw_stage_reason="$(dwproton_record_value "$dw_stage_out" STAGE_REASON)"
    [[ -n "$dw_stage_status" ]] || dw_stage_status="blocked"
    [[ -n "$dw_stage_action" ]] || dw_stage_action="BLOCK"
    [[ -n "$dw_stage_reason" ]] || dw_stage_reason="dwproton_rebuild_failed"

    if ((dw_stage_rc == 0)) && [[ "$dw_stage_status" == "ready" ]]; then
      built=$((built + 1))
      case "$dw_stage_action" in
        CREATE)
          created=$((created + 1))
          dw_result_actions+=("CREATE")
          ;;
        REPLACE)
          rebuilt=$((rebuilt + 1))
          dw_result_actions+=("REBUILD")
          ;;
        *)
          dw_result_actions+=("SKIP")
          ;;
      esac
      dw_result_names+=("${dw_plan_names[dw_idx]}")
      dw_result_up+=("APPLIED")
      dw_result_vdf+=("PATCHED")
      dw_result_tm+=("NO-OP")
      dw_result_results+=("SUCCESS")
    else
      err "DW-Proton rebuild failed: ${dw_plan_names[dw_idx]} ($(dwproton_human_rebuild_detail "$dw_stage_reason"))"
      dw_result_names+=("${dw_plan_names[dw_idx]}")
      dw_result_up+=("UNKNOWN")
      dw_result_vdf+=("UNKNOWN")
      dw_result_tm+=("NO-OP")
      dw_result_actions+=("$(rebuild_human_action "${dw_plan_actions[dw_idx]}")")
      dw_result_results+=("BLOCKED")
      dw_result_details+=("$(dwproton_human_rebuild_detail "$dw_stage_reason")")
      rebuild_rc=1
    fi
  done

  if ((${#names[@]} > 0)); then
    rebuild_print_result_table "CachyOS Proton Result:" names patch_up patch_vdf patch_tm patch_actions patch_results
  fi
  if ((${#dw_result_names[@]} > 0)); then
    rebuild_print_result_table "DW-Proton Result:" dw_result_names dw_result_up dw_result_vdf dw_result_tm dw_result_actions dw_result_results
    msg "Safety: DW-Proton clones are staged, validated, and published only after validation passes."
    if printf '%s\n' "${dw_result_results[@]}" | grep -Fqx "BLOCKED"; then
      msg "Blocked DW-Proton clones are not published."
      if ((${#dw_result_details[@]} > 0)); then
        msg "Blocked DW-Proton diagnostics:"
        local dw_result_idx=0
        for ((dw_result_idx = 0; dw_result_idx < ${#dw_result_names[@]}; dw_result_idx++)); do
          [[ "${dw_result_results[dw_result_idx]}" == "BLOCKED" ]] || continue
          printf '  %-42s %s\n' "${dw_result_names[dw_result_idx]}" "${dw_result_details[dw_result_idx]}"
        done
      fi
    fi
    msg ""
  fi

  # prep already prints the restart hint; don't repeat it here
  if [[ -z "${GENVW_IN_PREP:-}" ]]; then
    msg "Next:"
    if steam_is_running; then
      msg "  Restart Steam now to re-scan compatibility tools."
    else
      msg "  Restart Steam to re-scan compatibility tools."
    fi
    msg ""
  fi

  local dll_trust_state="" dll_trust_detail=""
  rebuild_collect_dll_trust_status dll_trust_state dll_trust_detail
  msg "Summary:"
  printf '  %-8s %-9s %s\n' "ITEM" "STATE" "DETAIL"
  if ((built == total)); then
    prep_print_status_row "BUILT" "READY" "$built/$total clones"
  else
    prep_print_status_row "BUILT" "PARTIAL" "$built/$total clones"
  fi
  prep_print_status_row "CREATED" "READY" "$created"
  prep_print_status_row "REBUILT" "READY" "$rebuilt"
  prep_print_status_row "TRUST" "$dll_trust_state" "$dll_trust_detail"
  if ! major_selection_is_all_supported; then
    ((${#names[@]} > 0)) && prompt_clean_old_after_rebuild "$built" "$total"
  fi
  return "$rebuild_rc"
}

print_dwproton_rebuild_preview_disabled() {
  local -a dw_targets=() dw_targets_filtered=()
  local src="" record="" action="" name="" reason="" status=""
  local -a rows=()

  gather_dwproton_display_targets dw_targets

  if rebuild_target_kind_is_dw_release; then
    filter_dwproton_targets_by_release dw_targets dw_targets_filtered "${REBUILD_TARGET_ID:-}"
    if ((${#dw_targets_filtered[@]} == 0)); then
      die "DW-Proton target '${REBUILD_TARGET_ID:-}' not found in: $CTD"
    fi
    dw_targets=("${dw_targets_filtered[@]}")
  elif rebuild_target_kind_is_exact_id; then
    local -a dw_exact_filtered_preview=()
    filter_dwproton_targets_by_exact_id dw_targets dw_exact_filtered_preview "${REBUILD_TARGET_ID:-}"
    if ((${#dw_exact_filtered_preview[@]} == 0)); then
      die "DW-Proton target id '${REBUILD_TARGET_ID:-}' not found in: $CTD"
    fi
    dw_targets=("${dw_exact_filtered_preview[@]}")
  elif rebuild_target_kind_is_default; then
    dwproton_pick_default_targets_by_major dw_targets dw_targets_filtered
    dw_targets=("${dw_targets_filtered[@]}")
  elif rebuild_target_kind_is_all_targets; then
    local -a dw_preview_resolved=()
    local _pdw_rt="" _pdw_row="" _pdw_bl=""
    for _pdw_rt in "${dw_targets[@]}"; do
      _pdw_row="$(dwproton_display_row_record "$_pdw_rt" 2>/dev/null || true)"
      [[ -n "$_pdw_row" ]] || continue
      IFS=$'\t' read -r _ _ _ _ _ _ _pdw_bl _ _ _ _ <<<"$_pdw_row" || continue
      [[ "$_pdw_bl" == "unresolved" ]] && continue
      dw_preview_resolved+=("$_pdw_rt")
    done
    dw_targets=("${dw_preview_resolved[@]}")
  fi

  local -a _pdw_sorted_pairs=() _pdw_sorted_targets=()
  local _pdw_ord_row="" _pdw_ord_m="" _pdw_ord_mi="" _pdw_ord_b="" _pdw_ord_src=""
  for _pdw_ord_src in "${dw_targets[@]}"; do
    _pdw_ord_row="$(dwproton_display_row_record "$_pdw_ord_src" 2>/dev/null || true)"
    [[ -n "$_pdw_ord_row" ]] || continue
    IFS=$'\t' read -r _pdw_ord_m _pdw_ord_mi _pdw_ord_b _ <<<"$_pdw_ord_row" || continue
    [[ "$_pdw_ord_m" =~ ^[0-9]+$ ]] || _pdw_ord_m=0
    [[ "$_pdw_ord_mi" =~ ^[0-9]+$ ]] || _pdw_ord_mi=0
    [[ "$_pdw_ord_b" =~ ^[0-9]+$ ]] || _pdw_ord_b=0
    _pdw_sorted_pairs+=("$(printf '%020d %020d %020d %s' "$_pdw_ord_m" "$_pdw_ord_mi" "$_pdw_ord_b" "$_pdw_ord_src")")
  done
  while IFS= read -r _pdw_ord_src; do
    [[ -n "$_pdw_ord_src" ]] && _pdw_sorted_targets+=("${_pdw_ord_src##* }")
  done < <(printf '%s\n' "${_pdw_sorted_pairs[@]}" | sort -k1,1rn -k2,2rn -k3,3rn)
  dw_targets=("${_pdw_sorted_targets[@]}")

  for src in "${dw_targets[@]}"; do
    record="$(dwproton_fsr4_rebuild_plan_disabled "$src" "$CTD" "$SUFFIX" "${FSR4_VER:-$FSR4_LOCAL_DEFAULT_VER}" 2>/dev/null)" || true
    action="$(dwproton_record_value "$record" DW_REBUILD_ACTION)"
    name="$(dwproton_record_value "$record" CLONE_BASENAME)"
    reason="$(dwproton_record_value "$record" PLAN_REASON)"
    [[ -n "$action" ]] || action="BLOCK"
    [[ -n "$name" && "$name" != "unresolved" ]] || name="${src##*/}"
    [[ -n "$reason" ]] || reason="dwproton_support_not_enabled"
    [[ "$action" != "SKIP" ]] || continue
    [[ "$action" == "CREATE" || "$action" == "REBUILD" || "$action" == "REPLACE" ]] || continue
    [[ "${REBUILD_MISSING_ONLY:-0}" -eq 1 && "$action" != "CREATE" ]] && continue
    status="planned"
    rows+=("${name}|${action}|${status}|${reason}")
  done

  msg ""
  msg "DW-Proton Plan:"
  if ((${#rows[@]} == 0)); then
    msg "  No missing DW-Proton gENVW clones."
    return 0
  fi

  printf '  %-8s %s\n' "ACTION" "NAME"
  while IFS='|' read -r name action status reason; do
    [[ -n "$name" ]] || continue
    : "$status" "$reason"
    printf '  %-8s %s\n' "$(rebuild_human_action "$action")" "$name"
  done < <(printf '%s\n' "${rows[@]}")
}

# rebuild_context_collect_safe_cachyos_dates
# collect unique build date strings from SUPPORTED_SOURCES[]

rebuild_context_collect_safe_cachyos_dates() {
  local -n _csd_out="$1"
  _csd_out=()
  local -A _seen=()
  local _src _d
  for _src in "${SUPPORTED_SOURCES[@]}"; do
    _d="$(source_build_date "$_src" 2>/dev/null || true)"
    [[ -n "$_d" ]] || continue
    [[ -v "_seen[$_d]" ]] && continue
    _seen["$_d"]=1
    _csd_out+=("$_d")
  done
}

# rebuild_context_collect_planned_cachyos_dates
# collect unique build date strings from PICKED[]

rebuild_context_collect_planned_cachyos_dates() {
  local -n _cpd_out="$1"
  _cpd_out=()
  local -A _seen=()
  local _src _d
  for _src in "${PICKED[@]}"; do
    _d="$(source_build_date "$_src" 2>/dev/null || true)"
    [[ -n "$_d" ]] || continue
    [[ -v "_seen[$_d]" ]] && continue
    _seen["$_d"]=1
    _cpd_out+=("$_d")
  done
}

# rebuild_context_subtract_dates
# output: extras = all_safe minus planned (by date string)

rebuild_context_subtract_dates() {
  local -n _rcs_all="$1"
  local -n _rcs_planned="$2"
  local -n _rcs_out="$3"
  _rcs_out=()
  local -A _planned_set=()
  local _d
  for _d in "${_rcs_planned[@]}"; do _planned_set["$_d"]=1; done
  for _d in "${_rcs_all[@]}"; do
    [[ -v "_planned_set[$_d]" ]] && continue
    _rcs_out+=("$_d")
  done
}

# rebuild_context_collect_safe_dw_releases
# collect unique DW release ids from a dw_targets array

rebuild_context_collect_safe_dw_releases() {
  local -n _cdr_src="$1"
  local -n _cdr_out="$2"
  _cdr_out=()
  local -A _seen=()
  local _entry _base _ver
  for _entry in "${_cdr_src[@]}"; do
    _base="$(basename "$_entry")"
    _ver="$(dwproton_folder_version "$_base" 2>/dev/null || true)"
    [[ -n "$_ver" ]] || continue
    [[ -v "_seen[$_ver]" ]] && continue
    _seen["$_ver"]=1
    _cdr_out+=("$_ver")
  done
}

# rebuild_context_sort_dw_releases_newest_first
# sort a DW release-id array newest-first: major numeric desc, patch numeric desc

rebuild_context_sort_dw_releases_newest_first() {
  local -n _rcsdr_in="$1"
  local -n _rcsdr_out="$2"
  _rcsdr_out=()
  ((${#_rcsdr_in[@]} > 0)) || return 0
  local _ver _major _patch _line
  local -a _pairs=()
  for _ver in "${_rcsdr_in[@]}"; do
    _major="$(dwproton_release_major_key "$_ver")"
    _patch="$(dwproton_release_patch_num "$_ver")"
    # major_key like "10.0" — extract integer part for numeric comparison
    local _major_int="${_major%%.*}"
    [[ "$_major_int" =~ ^[0-9]+$ ]] || _major_int=0
    [[ "$_patch"     =~ ^[0-9]+$ ]] || _patch=0
    _pairs+=("$(printf '%020d %020d %s' "$_major_int" "$_patch" "$_ver")")
  done
  local -a _sorted=()
  while IFS= read -r _line; do
    [[ -n "$_line" ]] && _sorted+=("$_line")
  done < <(printf '%s\n' "${_pairs[@]}" | sort -k1,1rn -k2,2rn)
  for _line in "${_sorted[@]}"; do
    _rcsdr_out+=("${_line##* }")
  done
}

# print_rebuild_dry_run_context
# prints "Available targets not selected by default:" section when extras exist
# argument: name of dw_targets local array

print_rebuild_dry_run_context() {
  local -n _prdc_dw="$1"

  local -a _safe_cachy=() _planned_cachy=() _extra_cachy=()
  local -a _safe_dw=() _planned_dw=() _extra_dw=()

  if rebuild_includes_cachyos && [[ -v SUPPORTED_SOURCES ]] && ((${#SUPPORTED_SOURCES[@]} > 0)); then
    rebuild_context_collect_safe_cachyos_dates _safe_cachy
    rebuild_context_collect_planned_cachyos_dates _planned_cachy
    rebuild_context_subtract_dates _safe_cachy _planned_cachy _extra_cachy
    # sort descending: YYYYMMDD fixed-width strings, numeric desc = newest first
    if ((${#_extra_cachy[@]} > 0)); then
      local -a _sorted_cachy=()
      while IFS= read -r _ctx_d; do
        [[ -n "$_ctx_d" ]] && _sorted_cachy+=("$_ctx_d")
      done < <(printf '%s\n' "${_extra_cachy[@]}" | sort -rn)
      _extra_cachy=("${_sorted_cachy[@]}")
    fi
  fi

  if rebuild_includes_dwproton && ((${#_prdc_dw[@]} > 0)); then
    local -a _prdc_dw_copy=("${_prdc_dw[@]}")
    local -a _prdc_dw_narrow=()
    rebuild_context_collect_safe_dw_releases _prdc_dw_copy _safe_dw
    dwproton_pick_default_targets_by_major _prdc_dw_copy _prdc_dw_narrow
    local -a _planned_dw=()
    rebuild_context_collect_safe_dw_releases _prdc_dw_narrow _planned_dw
    rebuild_context_subtract_dates _safe_dw _planned_dw _extra_dw
    local -a _sorted_dw=()
    rebuild_context_sort_dw_releases_newest_first _extra_dw _sorted_dw
    _extra_dw=("${_sorted_dw[@]}")
  fi

  local _has_context=0
  ((${#_extra_cachy[@]} > 0)) && _has_context=1
  ((${#_extra_dw[@]} > 0)) && _has_context=1
  ((_has_context)) || return 0

  msg ""
  msg "Available targets not selected by default:"

  local _top5_cachy=("${_extra_cachy[@]:0:5}")
  if ((${#_top5_cachy[@]} > 0)); then
    msg ""
    msg "  CachyOS Proton:"
    local _d
    for _d in "${_top5_cachy[@]}"; do
      printf '    %s\n' "$_d"
    done
    local _first_date="${_top5_cachy[0]}"
    printf '  %s\n' "Use: genvw proton rebuild -p cachyos -t ${_first_date} --dry-run"
    printf '  %s\n' "Use: genvw proton rebuild -p cachyos --all-targets --dry-run"
  fi

  local _top5_dw=("${_extra_dw[@]:0:5}")
  if ((${#_top5_dw[@]} > 0)); then
    msg ""
    msg "  DW-Proton:"
    local _v
    for _v in "${_top5_dw[@]}"; do
      printf '    %s\n' "$_v"
    done
    local _first_ver="${_top5_dw[0]}"
    printf '  %s\n' "Use: genvw proton rebuild -p dw -t ${_first_ver} --dry-run"
    printf '  %s\n' "Use: genvw proton rebuild -p dw --all-targets --dry-run"
  fi
}

# do_dry_run
# show what rebuild would do, without touching the filesystem

do_dry_run() {
  parse_rebuild_flags "$@"
  if [[ "${GENVW_KV_HELP:-0}" == "1" ]]; then
    return 0
  fi
  fsr4_apply_effective_local_default_if_implicit "${DLL_DST_DIR_DEFAULT}"
  preflight_proton

  local -a dw_targets=()
  if rebuild_includes_cachyos; then
    gather_sources
  else
    SOURCES=()
    PICKED=()
  fi
  if rebuild_includes_dwproton; then
    gather_dwproton_display_targets dw_targets
  fi

  if ((${#SOURCES[@]} == 0 && ${#dw_targets[@]} == 0)); then
    die "No Proton-CachyOS sources found and no DW-Proton dry-run targets found in: $CTD ($(major_selection_error_label))"
  fi

  msg "${I_DEBUG} Dry run: no changes will be made."

  if ((${#SOURCES[@]} > 0)); then
    local newest_src_date="" newest_supported_date=""
    newest_src_date="$(detect_build_date)" || die "Could not detect build dates in Proton folder names."
    gather_supported_sources_from_sources
    newest_supported_date="$(detect_build_date_for_sources "${SUPPORTED_SOURCES[@]}" 2>/dev/null || true)"

    if rebuild_target_kind_is_all_targets; then
      pick_all_supported_sources_for_rebuild
    elif rebuild_target_kind_is_exact_id; then
      pick_sources_for_exact_id
    else
      pick_sources_for_rebuild_selection "$newest_src_date" "$newest_supported_date"
      if ! major_selection_is_all_supported; then
        [[ -n "$BUILD_DATE" ]] || die "Could not detect build dates in Proton folder names."
      fi
    fi
    filter_picked_by_min_date
    ((${#PICKED[@]} > 0)) || die "No supported sources for gENVW patching. Minimum supported date: ${MIN_SUPPORTED_DATE_GENVW}"
    filter_picked_by_patch_capability
    ((${#PICKED[@]} > 0)) || die "No patch-capable sources for gENVW patching. Minimum supported date: ${MIN_SUPPORTED_DATE_GENVW}"
    if rebuild_target_kind_is_default; then
      narrow_picked_to_preferred_cachyos_variant
    fi

    local -a dry_plan_names=() dry_plan_actions=()
    for src in "${PICKED[@]}"; do
      local base dstbase dst
      base="$(basename "$src")"
      dstbase="$(source_clone_basename "$src" "$SUFFIX")"
      dst="${CTD}/${dstbase}"
      if [[ -d "$dst" ]]; then
        [[ "${REBUILD_MISSING_ONLY:-0}" -eq 1 ]] && continue
        dry_plan_actions+=("REBUILD")
      else
        dry_plan_actions+=("CREATE")
      fi
      dry_plan_names+=("$dstbase")
    done

    msg ""
    msg "CachyOS Proton Plan:"
    if ((${#dry_plan_names[@]} > 0)); then
      printf '  %-8s %s\n' "ACTION" "NAME"
      local dry_idx=0
      for ((dry_idx = 0; dry_idx < ${#dry_plan_names[@]}; dry_idx++)); do
        printf '  %-8s %s\n' "${dry_plan_actions[dry_idx]}" "${dry_plan_names[dry_idx]}"
      done
    else
      msg "  No missing CachyOS Proton gENVW clones."
    fi
  elif rebuild_includes_cachyos; then
    msg ""
    msg "CachyOS Proton Plan:"
    msg "  No missing CachyOS Proton gENVW clones."
  fi

  if rebuild_includes_dwproton; then
    print_dwproton_rebuild_preview_disabled
  fi

  if rebuild_target_kind_is_default && [[ "${REBUILD_MISSING_ONLY:-0}" -ne 1 ]]; then
    print_rebuild_dry_run_context dw_targets
  fi
}

# validate_clean_old_argv
# keep clean --old narrow so it can't be combined into a footgun

validate_clean_old_argv() {
  local a
  while (($#)); do
    a="$1"
    case "$a" in
      --old | --dry-run)
        shift
        ;;
      --suffix)
        # allow scoping clean --old; empty is ok (defaults later)
        [[ "${2+x}" == "x" ]] || die "Missing value for $a"
        shift 2
        ;;
      --ctd | --major)
        # allow scoping clean --old
        [[ -n "${2:-}" ]] || die "Missing value for $a"
        shift 2
        ;;
      -h | --help)
        return 0
        ;;
      *)
        die "For safety, 'clean --old' must not be combined with '$a'. Use: $(cmd_proton) clean --old"
        ;;
    esac
  done
}

# do_clean
# remove gENVW clones (scoped by suffix/major/date, or --old mode)

do_clean() {
  # detect --old before parse_kv_flags so we can reject mixed flags early
  local _saw_old=0 a
  for a in "$@"; do
    [[ "$a" == "--old" ]] && _saw_old=1
  done
  if ((_saw_old)); then
    validate_clean_old_argv "$@"
  fi

  local dry_run=0
  for a in "$@"; do
    [[ "$a" == "--dry-run" ]] && dry_run=1
  done
  [[ "${DRY_RUN:-0}" == "1" ]] && dry_run=1
  [[ "${DRYRUN:-0}" == "1" ]] && dry_run=1

  parse_kv_flags "$@"
  if [[ "${GENVW_KV_HELP:-0}" == "1" ]]; then
    return 0
  fi
  if [[ "${CLEAN_OLD:-0}" == "1" ]]; then
    do_clean_old
    return 0
  fi

  # if user didn't pass --suffix (or passed it empty), show what default will do
  local _saw_suffix=0 _saw_suffix_empty=0 i j
  for ((i = 1; i <= $#; i++)); do
    if [[ "${!i}" == "--suffix" ]]; then
      _saw_suffix=1
      j=$((i + 1))
      if ((j > $#)); then
        _saw_suffix_empty=1
      else
        [[ -n "${!j-}" ]] || _saw_suffix_empty=1
      fi
    fi
  done
  if ((_saw_suffix == 0 || _saw_suffix_empty == 1)); then
    msg "${I_INFO} Using default suffix '-${SUFFIX_DEFAULT}' (will remove *-${SUFFIX_DEFAULT} clones)."
  fi

  local clean_date="${BUILD_DATE:-}"

  # don't delete while steam is running; dry-run is ok
  if steam_running; then
    if ((dry_run)); then
      msg "${I_DEBUG} Allowing --dry-run while Steam is running."
    else
      die "Steam is running. Close Steam before clean."
    fi
  fi

  local -a doomed=()
  while IFS= read -r -d '' p; do
    [[ -n "$p" ]] && doomed+=("$p")
  done < <(_matching_clones "$CTD" "$MAJOR" "$SUFFIX" "$clean_date")

  local -a dw_dry_candidates=()
  if ((dry_run)); then
    local _dw_p
    while IFS= read -r -d '' _dw_p; do
      [[ -n "$_dw_p" ]] && dw_dry_candidates+=("$_dw_p")
    done < <(_matching_dwproton_clones_for_human_inventory "$CTD" "$SUFFIX" "$clean_date")
  fi

  local -a dw_owned=()
  if ((!dry_run)); then
    local _dw_q
    while IFS= read -r -d '' _dw_q; do
      if [[ -n "$_dw_q" ]] && dwproton_clone_owned_for_clean "$_dw_q" "$SUFFIX"; then
        dw_owned+=("$_dw_q")
      fi
    done < <(_matching_dwproton_clones_for_human_inventory "$CTD" "$SUFFIX" "$clean_date")
  fi

  if ((${#doomed[@]} == 0 && (dry_run || ${#dw_owned[@]} == 0))); then
    if [[ -n "$clean_date" ]]; then
      msg "${I_INFO} Nothing to remove for suffix '-$SUFFIX' (major=$MAJOR date=$clean_date)"
    else
      msg "${I_INFO} Nothing to remove for suffix '-$SUFFIX' (major=$MAJOR)"
    fi
    if ((dry_run && ${#dw_dry_candidates[@]} > 0)); then
      msg ""
      msg "DW-Proton clean candidates (dry-run only):"
      local _dwp
      for _dwp in "${dw_dry_candidates[@]##*/}"; do
        printf '  %-8s %s\n' "REMOVE" "$_dwp"
      done
      msg "${I_INFO} DW-Proton clones shown for dry-run preview. Actual clean removes strictly validated DW-Proton gENVW clones."
    fi
    return 0
  fi

  if ((${#doomed[@]} > 0)); then
    msg "${I_BROOM} Removing clones under: $CTD"
    printf '  %-8s %s\n' "ACTION" "NAME"
    local doomed_name=""
    for doomed_name in "${doomed[@]##*/}"; do
      printf '  %-8s %s\n' "REMOVE" "$doomed_name"
    done
  fi
  if ((dry_run)); then
    msg "${I_DEBUG} Dry run: no files removed."
    if ((${#dw_dry_candidates[@]} > 0)); then
      msg ""
      msg "DW-Proton clean candidates (dry-run only):"
      local _dwp
      for _dwp in "${dw_dry_candidates[@]##*/}"; do
        printf '  %-8s %s\n' "REMOVE" "$_dwp"
      done
      msg "${I_INFO} DW-Proton clones shown for dry-run preview. Actual clean removes strictly validated DW-Proton gENVW clones."
    fi
    return 0
  fi

  local p
  for p in "${doomed[@]}"; do
    rm_rf_within_root "$CTD" "$p" || die "Failed to remove $p"
  done
  if ((${#doomed[@]} > 0)); then
    ok "Removed ${#doomed[@]} clone(s)."
  fi

  if ((${#dw_owned[@]} > 0)); then
    msg "${I_BROOM} Removing DW-Proton clones under: $CTD"
    local _dw_del
    for _dw_del in "${dw_owned[@]}"; do
      rm_rf_within_root "$CTD" "$_dw_del" || die "Failed to remove DW clone ${_dw_del##*/}"
    done
    ok "Removed ${#dw_owned[@]} DW-Proton clone(s)."
  fi
}

prep_dll_trust_summary() {
  # quick trust summary right after install (prep). never blocks.
  # runs check --kv in a subshell so it can't mess with caller state.
  local localdll="${1:-}"
  [[ -n "$localdll" ]] || return 0

  local kv="" k="" v=""
  local meta_match="0" meta_reason="unknown"
  local allow_match="0" allow_reason="unknown"
  local dll_sha="" dll_size=""
  local allow_path="${AMD_DLL_ALLOWLIST}"

  # build args carefully: only pass flags that have values
  local -a args=(--kv)
  [[ -n "${CTD:-}" ]] && args+=(--ctd "$CTD")
  [[ -n "${MAJOR:-}" ]] && args+=(--major "$MAJOR")
  [[ -n "${SUFFIX:-}" ]] && args+=(--suffix "$SUFFIX")
  [[ -n "${TAG:-}" ]] && args+=(--tag "$TAG")

  kv="$( (do_check "${args[@]}") 2>/dev/null || true)"

  if [[ -z "$kv" ]]; then
    warn "${I_SHIELD} DLL trust: Unable to run trust check (no KV output)."
    return 0
  fi

  amd_dll_trust_snapshot_from_kv "$kv" meta_match meta_reason allow_match allow_reason dll_sha dll_size allow_path

  if [[ "$meta_match" == "1" && "$allow_match" == "1" ]]; then
    ok "${I_SHIELD} DLL trust:  Trusted (META_MATCH=1, ALLOWLIST_MATCH=1)"
    return 0
  fi

  local meta_warning_line="" allow_warning_line=""
  amd_dll_trust_raw_warning_line "META_MATCH" "$meta_match" "$meta_reason" meta_warning_line
  amd_dll_trust_raw_warning_line "ALLOWLIST_MATCH" "$allow_match" "$allow_reason" allow_warning_line
  warn "${I_SHIELD} DLL trust: Not fully trusted yet"
  warn "   ${meta_warning_line}"
  warn "   ${allow_warning_line}"

  msg "${I_LOCK_SEC} Fingerprint pair (copy into allowlist if you trust this DLL):"
  msg "  DLL_SHA256=${dll_sha}"
  msg "  DLL_SIZE=${dll_size}"
  msg "${I_PIN} Next steps:"
  msg "  1) If this DLL is expected (new AMD driver), append the pair to:"
  msg "     ${allow_path}"
  msg "     (create the folder/file if missing; comments/blank lines are allowed)"
  msg "  2) Re-run:"
  msg "     $(cmd_proton) check --kv"
  msg "  3) Or re-install from official AMD driver package:"
  msg "     $(cmd_dll) install"
  return 0
}

prep_reason_label() {
  local reason="${1:-unknown}"
  case "$reason" in
    ok) printf '%s\n' "ok" ;;
    missing_meta) printf '%s\n' "missing meta" ;;
    insufficient_data) printf '%s\n' "incomplete meta" ;;
    installed_ver_missing) printf '%s\n' "missing installed version" ;;
    installed_ver_mismatch) printf '%s\n' "installed version mismatch" ;;
    installed_ver_source_missing) printf '%s\n' "missing installed-version source" ;;
    installed_ver_source_mismatch) printf '%s\n' "installed-version source mismatch" ;;
    amd_driver_flavor_missing) printf '%s\n' "missing AMD-source driver flavor" ;;
    amd_driver_flavor_mismatch) printf '%s\n' "AMD-source driver flavor mismatch" ;;
    amd_source_kind_missing) printf '%s\n' "missing AMD-source kind" ;;
    amd_source_kind_mismatch) printf '%s\n' "AMD-source kind mismatch" ;;
    amd_source_url_missing) printf '%s\n' "missing AMD-source URL" ;;
    local_installed_ver_source_missing) printf '%s\n' "missing local-dll installed-version source" ;;
    local_installed_ver_source_mismatch) printf '%s\n' "local-dll installed-version source mismatch" ;;
    local_source_kind_missing) printf '%s\n' "missing local-dll source kind" ;;
    local_source_kind_mismatch) printf '%s\n' "local-dll source kind mismatch" ;;
    source_kind_missing) printf '%s\n' "missing source kind" ;;
    source_kind_mismatch) printf '%s\n' "source kind mismatch" ;;
    meta_sha_invalid) printf '%s\n' "invalid meta sha256" ;;
    meta_size_invalid) printf '%s\n' "invalid meta size" ;;
    size_mismatch) printf '%s\n' "size mismatch" ;;
    sha256_mismatch) printf '%s\n' "sha256 mismatch" ;;
    no_sha256_tool) printf '%s\n' "sha256 tool missing" ;;
    allowlist_missing) printf '%s\n' "allowlist missing" ;;
    not_allowlisted) printf '%s\n' "allowlist mismatch" ;;
    pair_unavailable) printf '%s\n' "sha256/size unavailable" ;;
    dll_missing) printf '%s\n' "DLL missing" ;;
    *) printf '%s\n' "${reason//_/ }" ;;
  esac
}

amd_dll_trust_reason_summary() {
  local meta_match="${1:-0}" meta_reason="${2:-unknown}" allow_match="${3:-0}" allow_reason="${4:-unknown}"
  local both_mode="${5:-joined}" joiner="${6:-, }"
  local -n out_detail_ref="$7"

  out_detail_ref="trusted"
  if [[ "$meta_match" != "1" && "$allow_match" != "1" ]]; then
    case "$both_mode" in
      primary)
        out_detail_ref="$(prep_reason_label "$meta_reason")"
        ;;
      joined)
        out_detail_ref="$(prep_reason_label "$meta_reason")${joiner}$(prep_reason_label "$allow_reason")"
        ;;
      *)
        out_detail_ref="$(prep_reason_label "$meta_reason")${joiner}$(prep_reason_label "$allow_reason")"
        ;;
    esac
    return 0
  fi
  if [[ "$meta_match" != "1" ]]; then
    out_detail_ref="$(prep_reason_label "$meta_reason")"
    return 0
  fi
  if [[ "$allow_match" != "1" ]]; then
    out_detail_ref="$(prep_reason_label "$allow_reason")"
  fi
}

amd_dll_trust_raw_warning_line() {
  local key="${1:-META_MATCH}" match="${2:-0}" reason="${3:-unknown}"
  local -n out_line_ref="$4"
  out_line_ref="${key}=${match} REASON=${reason}"
}

amd_dll_trust_raw_warning_summary() {
  local meta_match="${1:-0}" meta_reason="${2:-unknown}" allow_match="${3:-0}" allow_reason="${4:-unknown}"
  local -n out_summary_ref="$5"
  local meta_line="" allow_line=""

  amd_dll_trust_raw_warning_line "META_MATCH" "$meta_match" "$meta_reason" meta_line
  amd_dll_trust_raw_warning_line "ALLOWLIST_MATCH" "$allow_match" "$allow_reason" allow_line
  out_summary_ref="${meta_line}; ${allow_line}"
}

amd_dll_trust_snapshot_from_kv() {
  local kv="${1:-}"
  local -n out_meta_match_ref="$2" out_meta_reason_ref="$3" out_allow_match_ref="$4" out_allow_reason_ref="$5"
  local out_dll_sha_name="${6:-}" out_dll_size_name="${7:-}" out_allow_path_name="${8:-}"
  local k="" v=""

  out_meta_match_ref="0"
  out_meta_reason_ref="unknown"
  out_allow_match_ref="0"
  out_allow_reason_ref="unknown"

  local -n out_dll_sha_ref="${out_dll_sha_name:-REPLY}"
  local -n out_dll_size_ref="${out_dll_size_name:-REPLY}"
  local -n out_allow_path_ref="${out_allow_path_name:-REPLY}"

  [[ -n "$out_dll_sha_name" ]] && out_dll_sha_ref=""
  [[ -n "$out_dll_size_name" ]] && out_dll_size_ref=""

  while IFS='=' read -r k v; do
    case "$k" in
      META_MATCH) out_meta_match_ref="${v:-0}" ;;
      META_MATCH_REASON) out_meta_reason_ref="${v:-unknown}" ;;
      ALLOWLIST_MATCH) out_allow_match_ref="${v:-0}" ;;
      ALLOWLIST_MATCH_REASON) out_allow_reason_ref="${v:-unknown}" ;;
      DLL_SHA256) [[ -n "$out_dll_sha_name" ]] && out_dll_sha_ref="${v:-}" ;;
      DLL_SIZE) [[ -n "$out_dll_size_name" ]] && out_dll_size_ref="${v:-}" ;;
      ALLOWLIST_PATH) [[ -n "$out_allow_path_name" ]] && out_allow_path_ref="${v:-$out_allow_path_ref}" ;;
    esac
  done <<<"$kv"
}

prep_print_status_row() {
  local item="${1:-}" state="${2:-}" detail="${3:-}"
  printf '  %-7s %-9s %s\n' "$item" "$state" "$detail"
}

print_label_value_row() {
  local label="${1:-}" value="${2:-}"
  printf '  %-14s %s\n' "$label" "$value"
}

print_detail_table_row() {
  local item="${1:-}" value="${2:-}"
  printf '  %-11s %s\n' "$item" "$value"
}

source_table_fields_from_base() {
  local major="${1:-}" base="${2:-}"
  local name="proton-cachyos" rec="" parsed="" parsed_major="" date="" tail="" runtime="" arch=""

  rec="$(source_metadata_record "$base" 2>/dev/null || true)"
  if [[ -n "$rec" ]]; then
    parsed="${rec#*|}"
    parsed_major="${parsed%%|*}"
    parsed="${parsed#*|}"
    date="${parsed%%|*}"
    parsed="${parsed#*|}"
    runtime="${parsed%%|*}"
    arch="${parsed#*|}"
    major="${parsed_major:-$major}"
  elif [[ "$base" =~ ^proton-cachyos-${major}-([0-9]{8})-(.+)$ ]]; then
    date="${BASH_REMATCH[1]}"
    tail="${BASH_REMATCH[2]}"
    runtime="${tail%%-*}"
    arch="${tail#*-}"
  else
    date="unknown"
    runtime="unknown"
    arch="$base"
  fi

  printf '%s|%s|%s|%s|%s\n' "$name" "$major" "$date" "$runtime" "$arch"
}

source_table_fields_from_path() {
  local major="${1:-}" src="${2:-}"
  local rec="" parsed="" parsed_major="" date="" runtime="" arch=""

  rec="$(source_metadata_record "$src" 2>/dev/null || true)"
  if [[ -n "$rec" ]]; then
    parsed="${rec#*|}"
    parsed_major="${parsed%%|*}"
    parsed="${parsed#*|}"
    date="${parsed%%|*}"
    parsed="${parsed#*|}"
    runtime="${parsed%%|*}"
    arch="${parsed#*|}"
    printf '%s|%s|%s|%s|%s\n' "proton-cachyos" "${parsed_major:-$major}" "$date" "$runtime" "$arch"
    return 0
  fi

  source_table_fields_from_base "$major" "${src##*/}"
}

source_rebuild_table_fields_from_path() {
  local src="${1:-}" rec="" parsed="" src_major="" date="" runtime="" arch=""
  local family="" provenance_rec="" provenance="" source_label=""

  rec="$(source_list_metadata_record "$src" 2>/dev/null || true)"
  [[ -n "$rec" ]] || return 1
  parsed="${rec#*|}"
  src_major="${parsed%%|*}"
  parsed="${parsed#*|}"
  date="${parsed%%|*}"
  parsed="${parsed#*|}"
  runtime="${parsed%%|*}"
  arch="${parsed#*|}"

  family="$(source_folder_family_for_path "$src")"
  provenance_rec="$(source_provenance_record_for_path "$src" 2>/dev/null || true)"
  provenance="${provenance_rec%%|*}"
  case "$family" in
    protonup-qt) source_label="ProtonUp-Qt" ;;
    protonplus) source_label="ProtonPlus" ;;
    system-package) source_label="System" ;;
    *)
      case "$provenance" in
        ctd) source_label="Local CTD" ;;
        system) source_label="System" ;;
        *) source_label="${family:-unknown}" ;;
      esac
      ;;
  esac

  printf '%s|%s|%s|%s|%s\n' "proton-cachyos" "${src_major}-${date}" "$runtime" "$source_label" "$(source_target_arch_for_human "$arch")"
}

dwproton_fsr4_default_for_version() {
  case "${1:-}" in
    10.0-10 | 10.0-11 | 10.0-12 | 10.0-16 | 10.0-17 | 10.0-20) printf '%s\n' "4.0.2" ;;
    10.0-21 | 11.0-2) printf '%s\n' "4.1.0" ;;
    10.0-23 | 10.0-25 | 10.0-26 | 11.0-1) printf '%s\n' "4.0.3" ;;
    *) printf '%s\n' "unknown" ;;
  esac
}

dwproton_fsr4_allowed_for_version() {
  case "${1:-}" in
    10.0-10 | 10.0-11 | 10.0-12 | 10.0-16 | 10.0-17 | 10.0-20) printf '%s\n' "4.0.0,4.0.1,4.0.2" ;;
    10.0-21 | 10.0-23 | 10.0-25 | 10.0-26 | 11.0-1 | 11.0-2) printf '%s\n' "4.0.0,4.0.1,4.0.2,4.0.3,4.1.0" ;;
    *) printf '%s\n' "" ;;
  esac
}

print_source_summary_table() {
  local _major="${1:-}"
  shift || true

  local src="" parsed="" provider="" version="" runtime="" source_label="" arch=""

  : "$_major"
  printf '  %-14s %-13s %-7s %-11s %s\n' "PROVIDER" "VERSION" "RUNTIME" "SOURCE" "ARCH"
  for src in "$@"; do
    parsed="$(source_rebuild_table_fields_from_path "$src" 2>/dev/null || true)"
    [[ -n "$parsed" ]] || continue
    provider="${parsed%%|*}"
    parsed="${parsed#*|}"
    version="${parsed%%|*}"
    parsed="${parsed#*|}"
    runtime="${parsed%%|*}"
    parsed="${parsed#*|}"
    source_label="${parsed%%|*}"
    arch="${parsed#*|}"
    printf '  %-14s %-13s %-7s %-11s %s\n' "$provider" "$version" "$runtime" "$source_label" "$arch"
  done
}

source_sort_major_rank() {
  local major="${1:-0}" major_int=""
  major_int="${major%%.*}"
  [[ "$major_int" =~ ^[0-9]+$ ]] || major_int=0
  printf '%s\n' "$major_int"
}

source_sort_runtime_rank() {
  case "${1:-}" in
    slr) printf '%s\n' 2 ;;
    native) printf '%s\n' 1 ;;
    *) printf '%s\n' 0 ;;
  esac
}

source_sort_family_rank() {
  local kind="${1:-source}" family="${2:-}" provenance="${3:-}"
  if [[ "$kind" == "clone" ]]; then
    printf '%s\n' 0
    return 0
  fi
  case "$family:$provenance" in
    system-package:* | *:system) printf '%s\n' 3 ;;
    protonplus:*) printf '%s\n' 2 ;;
    protonup-qt:ctd | protonup-qt:*) printf '%s\n' 1 ;;
    *) printf '%s\n' 0 ;;
  esac
}

source_newest_display_from_paths() {
  local src="" parsed="" name="" major="" date="" runtime="" arch="" row=""
  local kind="" major_rank="" runtime_rank="" source_rank="" base="" version="" arch_label="" source_label="" status_label=""
  local -a rows=()

  for src in "$@"; do
    row="$(source_human_row_record "$src" 2>/dev/null || true)"
    if [[ -n "$row" ]]; then
      IFS=$'\t' read -r kind date major_rank runtime_rank source_rank base version runtime arch_label source_label status_label <<<"$row"
      [[ -n "$date" && -n "$version" && -n "$runtime" ]] || continue
      rows+=("${date}"$'\t'"${major_rank:-0}"$'\t'"${runtime_rank:-0}"$'\t'"${source_rank:-0}"$'\t'"${base:-$src}"$'\t'"${version} ${runtime} ${arch_label:-unknown}")
      continue
    fi

    parsed="$(source_table_fields_from_path "$MAJOR" "$src" 2>/dev/null || true)"
    [[ -n "$parsed" ]] || continue
    name="${parsed%%|*}"
    parsed="${parsed#*|}"
    major="${parsed%%|*}"
    parsed="${parsed#*|}"
    date="${parsed%%|*}"
    parsed="${parsed#*|}"
    runtime="${parsed%%|*}"
    arch="${parsed#*|}"
    rows+=("${date}"$'\t'"$(source_sort_major_rank "$major")"$'\t'"$(source_sort_runtime_rank "$runtime")"$'\t'"0"$'\t'"${src##*/}"$'\t'"${major}-${date} ${runtime} $(source_target_arch_for_human "$arch")")
  done

  ((${#rows[@]} > 0)) || return 1
  row="$(printf '%s\n' "${rows[@]}" | sort -t $'\t' -k1,1r -k2,2nr -k3,3nr -k4,4nr -k5,5 | head -n1)"
  printf '%s\n' "${row##*$'\t'}"
}

clone_table_fields_from_base() {
  local major="${1:-}" suffix="${2:-}" base="${3:-}"
  local core="$base" clone_suffix="(none)" parsed="" name="" parsed_major="" date="" runtime="" arch=""

  if [[ -n "$suffix" && "$base" == *-"$suffix" ]]; then
    core="${base%-${suffix}}"
    clone_suffix="$suffix"
  fi

  parsed="$(source_table_fields_from_base "$major" "$core")"
  name="${parsed%%|*}"
  parsed="${parsed#*|}"
  parsed_major="${parsed%%|*}"
  parsed="${parsed#*|}"
  date="${parsed%%|*}"
  parsed="${parsed#*|}"
  runtime="${parsed%%|*}"
  arch="${parsed#*|}"
  printf '%s|%s|%s|%s|%s|%s\n' "$name" "$parsed_major" "$date" "$runtime" "$arch" "$clone_suffix"
}

print_clone_summary_table() {
  local major="${1:-}" suffix="${2:-}"
  shift 2 || true

  local path="" row="" row_num=0 kind="" date="" major_rank="" runtime_rank="" source_rank=""
  local base="" version="" runtime="" arch_label="" source_label="" status_label=""
  local family_label="" features=""
  local -a rows=()

  for path in "$@"; do
    row="$(source_human_row_record "$path" "$suffix" 2>/dev/null || true)"
    [[ -n "$row" ]] && rows+=("$row")
  done

  msg "CachyOS Proton:"
  printf '  %-3s %-13s %-8s %-11s %-10s %s\n' "#" "VERSION" "RUNTIME" "FAMILY" "ARCH" "FEATURES"
  ((${#rows[@]} > 0)) || return 0
  while IFS=$'\t' read -r kind date major_rank runtime_rank source_rank base version runtime arch_label source_label status_label; do
    [[ -n "$kind" ]] || continue
    row_num=$((row_num + 1))
    family_label="$(clone_family_label_from_base "$base")"
    features="$(list_clone_features_for_human "$base")"
    features="$(compact_feature_labels_for_human "$features")"
    printf '  %-3s %-13s %-8s %-11s %-10s %s\n' "$row_num" "$version" "$runtime" "$family_label" "$arch_label" "$features"
  done < <(printf '%s\n' "${rows[@]}" | sort -t $'\t' -k2,2r -k3,3nr -k4,4nr -k5,5nr -k6,6)
}

clone_family_label_from_base() {
  local base="${1:-}"
  case "$base" in
    *-protonplus-* | *-protonplus-unspecified) printf '%s\n' "ProtonPlus" ;;
    *-system-x86_64) printf '%s\n' "System" ;;
    proton-cachyos-*) printf '%s\n' "ProtonUp-Qt" ;;
    *) printf '%s\n' "Unknown" ;;
  esac
}

cachyos_features_for_build_date() {
  local date="${1:-}"
  local -a out=()
  if [[ "$date" == "20260227" ]]; then
    out+=("GPLAll-legacy")
  elif [[ "$date" > "20260227" && "$date" < "20260312" ]]; then
    out+=("GPLAsync" "lowlatency-DXVK")
  elif [[ "$date" > "20260311" && "$date" < "20260519" ]]; then
    out+=("lowlatency-DXVK" "NTSync")
  elif [[ "$date" > "20260518" ]]; then
    out+=("lowlatency-DXVK" "NTSync" "lowlatency-layer" "vkreflex")
  fi
  [[ "$date" > "20250806" ]] && out+=("shader-cache")
  [[ "$date" > "20260505" ]] && out+=("OptiScaler-preserved")
  ((${#out[@]} > 0)) && printf '%s\n' "${out[@]}"
}

compact_feature_labels_for_human() {
  local csv="${1:-}" token="" trimmed="" out=""
  local -a labels=()

  IFS=',' read -r -a labels <<<"$csv"
  for token in "${labels[@]}"; do
    trimmed="${token#"${token%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    [[ -n "$trimmed" ]] || continue
    case "$trimmed" in
      FSR4 | shader-cache | timeout-fix | game-fixes)
        continue
        ;;
    esac
    [[ -z "$out" ]] && out="$trimmed" || out="${out}, ${trimmed}"
  done

  [[ -n "$out" ]] || out="-"
  printf '%s\n' "$out"
}

list_clone_features_for_human() {
  local base="${1:-}" folder_base="" shape_rec="" shape_name="" date="" map_rec="" dw_date="" label=""
  local -a feat=("FSR4")

  if [[ "$base" =~ ^(dwproton-[0-9]+[.][0-9]+-[0-9]+)(-|$) ]]; then
    folder_base="${BASH_REMATCH[1]}"
    map_rec="$(dwproton_display_mapping_record "$folder_base" 2>/dev/null || true)"
    dw_date="${map_rec#*|}"; dw_date="${dw_date%%|*}"
    if [[ -n "$dw_date" && "$dw_date" != "unresolved" ]]; then
      while IFS= read -r label; do
        [[ -n "$label" ]] && feat+=("$label")
      done < <(cachyos_features_for_build_date "$dw_date")
      shape_rec="$(dwproton_patch_shape_record_from_base "$folder_base" 2>/dev/null || true)"
      shape_name="${shape_rec%%|*}"
      if [[ "$shape_name" == "public_optiscaler_aware" && " ${feat[*]} " != *" OptiScaler-preserved "* ]]; then
        feat+=("OptiScaler-preserved")
      fi
      case "$folder_base" in
        dwproton-11.0-2 | dwproton-11.0-3) feat+=("game-fixes") ;;
      esac
      [[ -n "$shape_name" ]] && feat+=("timeout-fix")
    fi
  elif [[ "$base" =~ ^(proton-)?cachyos-[0-9]+[.][0-9]+-([0-9]{8})- ]]; then
    date="${BASH_REMATCH[2]}"
    while IFS= read -r label; do
      [[ -n "$label" ]] && feat+=("$label")
    done < <(cachyos_features_for_build_date "$date")
  fi

  local out=""
  for label in "${feat[@]}"; do
    [[ -z "$out" ]] && out="$label" || out="${out}, ${label}"
  done
  printf '%s\n' "$out"
}

print_dwproton_clone_inventory_table() {
  local suffix="${1:-}"
  shift || true

  local path="" base="" row="" row_num=0 major="" minor="" build="" version="" arch="" features=""
  local -a rows=()

  for path in "$@"; do
    base="${path##*/}"
    row="$(dwproton_clone_inventory_record_for_base "$base" "$suffix" 2>/dev/null || true)"
    [[ -n "$row" ]] && rows+=("$row")
  done

  msg "DW-Proton:"
  printf '  %-3s %-10s %-10s %s\n' "#" "VERSION" "ARCH" "FEATURES"
  ((${#rows[@]} > 0)) || return 0
  while IFS=$'\t' read -r major minor build base version arch; do
    [[ -n "$version" ]] || continue
    row_num=$((row_num + 1))
    features="$(list_clone_features_for_human "$base")"
    features="$(compact_feature_labels_for_human "$features")"
    printf '  %-3s %-10s %-10s %s\n' "$row_num" "$version" "$arch" "$features"
  done < <(printf '%s\n' "${rows[@]}" | sort -t $'\t' -k1,1nr -k2,2nr -k3,3nr -k4,4)
}

print_list_clones_summary() {
  local cachyos_name="${1:-}" dw_name="${2:-}" suffix="${3:-}"
  local -n cachyos_ref="$cachyos_name"
  local -n dw_ref="$dw_name"
  local path="" row="" kind="" date="" major_rank="" runtime_rank="" source_rank=""
  local base="" version="" runtime="" arch_label="" source_label="" status_label="" family_label=""
  local total=0 cachyos_count=0 dw_count=0 upqt_count=0 protonplus_count=0 system_count=0 unknown_count=0

  for path in "${cachyos_ref[@]}"; do
    row="$(source_human_row_record "$path" "$suffix" 2>/dev/null || true)"
    [[ -n "$row" ]] || continue
    IFS=$'\t' read -r kind date major_rank runtime_rank source_rank base version runtime arch_label source_label status_label <<<"$row"
    [[ -n "$kind" ]] || continue
    family_label="$(clone_family_label_from_base "$base")"
    cachyos_count=$((cachyos_count + 1))
    case "$family_label" in
      ProtonUp-Qt) upqt_count=$((upqt_count + 1)) ;;
      ProtonPlus) protonplus_count=$((protonplus_count + 1)) ;;
      System) system_count=$((system_count + 1)) ;;
      *) unknown_count=$((unknown_count + 1)) ;;
    esac
  done

  dw_count="${#dw_ref[@]}"
  total=$((cachyos_count + dw_count))

  msg ""
  msg "Summary:"
  printf '  %-5s %-14s %-11s %s\n' "TOTAL" "PROVIDER" "FAMILY" "COUNT"
  printf '  %-5s %-14s %-11s %s\n' "$total" "all" "all" "$total"
  if ((cachyos_count > 0)); then
    printf '  %-5s %-14s %-11s %s\n' "$cachyos_count" "CachyOS Proton" "all" "$cachyos_count"
    ((protonplus_count > 0)) && printf '  %-5s %-14s %-11s %s\n' "$protonplus_count" "CachyOS Proton" "ProtonPlus" "$protonplus_count"
    ((upqt_count > 0)) && printf '  %-5s %-14s %-11s %s\n' "$upqt_count" "CachyOS Proton" "ProtonUp-Qt" "$upqt_count"
    ((system_count > 0)) && printf '  %-5s %-14s %-11s %s\n' "$system_count" "CachyOS Proton" "System" "$system_count"
    ((unknown_count > 0)) && printf '  %-5s %-14s %-11s %s\n' "$unknown_count" "CachyOS Proton" "Unknown" "$unknown_count"
  fi
  ((dw_count > 0)) && printf '  %-5s %-14s %-11s %s\n' "$dw_count" "DW-Proton" "DW-Proton" "$dw_count"
  return 0
}

prep_target_source_label() {
  local source="${1:-preferred_default}"
  case "$source" in
    explicit_ver) printf '%s\n' "explicit --ver" ;;
    env_fsr4) printf '%s\n' "explicit FSR4 env" ;;
    explicit_localdll) printf '%s\n' "explicit --localdll" ;;
    preferred_trusted) printf '%s\n' "preferred local default (trusted)" ;;
    highest_trusted_installed) printf '%s\n' "highest trusted installed local DLL" ;;
    preferred_default) printf '%s\n' "implicit local default" ;;
    *) printf '%s\n' "${source//_/ }" ;;
  esac
}

fsr4_diag_source_policy_for_ver() {
  local ver="${1:-}"
  local -n out_kind_ref="$2"
  local -n out_min_ref="$3"
  local -n out_max_ref="$4"
  local -n out_ref_ref="$5"
  local row="" row_ver="" row_kind="" row_min="" row_max="" row_ref=""

  out_kind_ref="no_default_source"
  out_min_ref=""
  out_max_ref=""
  out_ref_ref=""

  for row in "${FSR4_DIAG_SOURCE_POLICY[@]}"; do
    IFS='|' read -r row_ver row_kind row_min row_max row_ref <<<"$row"
    [[ "$row_ver" == "$ver" ]] || continue
    out_kind_ref="$row_kind"
    out_min_ref="$row_min"
    out_max_ref="$row_max"
    out_ref_ref="$row_ref"
    return 0
  done
  return 1
}

diagnose_print_missing_dll_next_steps() {
  local want="${1:-}"
  local -n step_no_ref="$2"
  local policy_kind="" policy_min="" policy_max="" policy_ref=""
  local dll_example="/path/to/${AMD_DLL_SRC_NAME:-amdxcffx64.dll}"

  fsr4_diag_source_policy_for_ver "$want" policy_kind policy_min policy_max policy_ref || true

  case "$policy_kind" in
    trusted_map)
      msg "  ${step_no_ref}. Install the trusted canonical version:"
      msg "     $(cmd_dll) install --ver ${want} --dst-dir \"${DLL_DST_DIR_DEFAULT}\""
      step_no_ref=$((step_no_ref + 1))
      msg "  ${step_no_ref}. Or install from a local DLL:"
      msg "     $(cmd_dll) install --dll ${dll_example} --dst-dir \"${DLL_DST_DIR_DEFAULT}\""
      step_no_ref=$((step_no_ref + 1))
      msg "  ${step_no_ref}. Or restore a backup:"
      msg "     $(cmd_dll) restore --ver ${want}"
      step_no_ref=$((step_no_ref + 1))
      ;;
    amd_driver_range)
      msg "  ${step_no_ref}. Install from an AMD driver that contains FSR4 ${want}:"
      if [[ -n "$policy_min" && -n "$policy_max" ]]; then
        msg "     known driver labels: ${policy_min} through ${policy_max}"
      elif [[ -n "$policy_min" ]]; then
        msg "     known driver labels: ${policy_min} and newer"
      fi
      msg "     $(cmd_dll) install --url \"${policy_ref:-$AMD_DRIVER_URL}\" --dst-dir \"${DLL_DST_DIR_DEFAULT}\""
      step_no_ref=$((step_no_ref + 1))
      msg "  ${step_no_ref}. Or restore a backup:"
      msg "     $(cmd_dll) restore --ver ${want}"
      step_no_ref=$((step_no_ref + 1))
      ;;
    local_dll_only)
      msg "  ${step_no_ref}. Install from a local DLL:"
      msg "     $(cmd_dll) install --dll ${dll_example} --dst-dir \"${DLL_DST_DIR_DEFAULT}\""
      step_no_ref=$((step_no_ref + 1))
      msg "  ${step_no_ref}. Or install the trusted canonical version:"
      msg "     $(cmd_dll) install --ver ${want} --dst-dir \"${DLL_DST_DIR_DEFAULT}\""
      step_no_ref=$((step_no_ref + 1))
      msg "  ${step_no_ref}. Or restore a backup:"
      msg "     $(cmd_dll) restore --ver ${want}"
      step_no_ref=$((step_no_ref + 1))
      ;;
    *)
      msg "  ${step_no_ref}. No default install source is configured for FSR4 ${want}"
      step_no_ref=$((step_no_ref + 1))
      msg "  ${step_no_ref}. Install the trusted canonical version:"
      msg "     $(cmd_dll) install --ver ${want} --dst-dir \"${DLL_DST_DIR_DEFAULT}\""
      step_no_ref=$((step_no_ref + 1))
      msg "  ${step_no_ref}. If you already have a local DLL:"
      msg "     $(cmd_dll) install --dll ${dll_example} --dst-dir \"${DLL_DST_DIR_DEFAULT}\""
      step_no_ref=$((step_no_ref + 1))
      msg "  ${step_no_ref}. Or restore a backup:"
      msg "     $(cmd_dll) restore --ver ${want}"
      step_no_ref=$((step_no_ref + 1))
      ;;
  esac
}

prep_print_final_summary() {
  local dll_state="${1:-}" dll_detail="${2:-}"
  local tools_state="${3:-}" tools_detail="${4:-}"
  local steam_state="${5:-}" steam_detail="${6:-}"
  local want="${7:-$FSR4_LOCAL_DEFAULT_VER}" trust_ok="${8:-0}"
  local step_no=1

  msg "Result:"
  prep_print_status_row "DLL" "$dll_state" "$dll_detail"
  prep_print_status_row "TOOLS" "$tools_state" "$tools_detail"
  prep_print_status_row "STEAM" "$steam_state" "$steam_detail"
  msg ""
  msg "Next:"
  if [[ "$steam_state" == "ACTION" ]]; then
    msg "  ${step_no}. Restart Steam"
    step_no=$((step_no + 1))
  fi
  if [[ "$trust_ok" == "1" ]]; then
    msg "  ${step_no}. Launch with:"
    msg "     FSR4=${want} genvw %command%"
    step_no=$((step_no + 1))
  else
    msg "  ${step_no}. Verify DLL trust:"
    msg "     $(cmd_dll) verify --ver ${want}"
    step_no=$((step_no + 1))
  fi
  msg "  ${step_no}. Optional check:"
  msg "     $(cmd_proton) check"
}

# do_prep
# one-shot setup: keep local dll + tools present.
# asks before doing anything unless --yes.

do_prep() {
  # one-shot setup:
  # - install local amd dll for selected --ver (write-path gated) if missing
  # - build/refresh genvw proton tools if missing
  #
  # interactive: asks before changes (unless --yes)
  # non-interactive: refuses to modify unless --yes
  local YES=0
  local url="$AMD_DRIVER_URL"
  local exe=""
  local keep=""
  local force_url=""
  # stuff we don't handle here gets forwarded to rebuild parsing
  local -a rest=()

  # help anywhere
  if proton_help_requested "$@"; then
    prep_usage
    return 0
  fi

  while (($# > 0)); do
    case "$1" in
      --yes | -y)
        YES=1
        shift
        ;;
      --url)
        require_flag_value --url "${2-}"
        url="$2"
        shift 2
        ;;
      --exe)
        require_flag_value --exe "${2-}"
        exe="$2"
        shift 2
        ;;
      --keep)
        keep=1
        shift
        ;;
      --force-url)
        force_url=1
        shift
        ;;
      *)
        rest+=("$1")
        shift
        ;;
    esac
  done

  # parse standard flags (ctd/major/suffix/tag/date/localdll/dry-run/allow-steam/etc.)

  ALLOW_STEAM=0
  parse_kv_flags "${rest[@]}"
  if [[ "${GENVW_KV_HELP:-0}" == "1" ]]; then
    return 0
  fi
  fsr4_apply_effective_local_default_if_implicit "${DLL_DST_DIR_DEFAULT}"

  local want="${FSR4_VER:-$FSR4_LOCAL_DEFAULT_VER}"
  local dst_dir="$DLL_DST_DIR_DEFAULT"
  local expected="${dst_dir}/${AMD_DLL_NAME}"
  local target_source_label=""
  fsr4_require_local_write_supported_ver "${want}" "prep"
  target_source_label="$(prep_target_source_label "${FSR4_EFFECTIVE_LOCAL_DEFAULT_SOURCE:-preferred_default}")"

  msg "${I_TOOLBOX} genvw_proton prep"
  msg ""
  msg "Goal:"
  msg "  ${I_OK} Install local AMD DLL (FSR4 ${want})"
  msg "  ${I_OK} Build/refresh gENVW Proton tools (-${SUFFIX})"
  msg ""
  msg "Targets:"
  msg "  ${I_BOX} DLL:   ${expected}"
  msg "  ${I_PUZZLE} Tools: ${CTD}/*-${SUFFIX}*/"
  msg "  ${I_PIN} Target: FSR4 ${want} (${target_source_label})"
  msg ""

  # Determine current state
  local dll_present=0 dll_trusted=0 dll_ok=0 tools_ok=0
  local dll_meta_match=0 dll_allow_match=0
  if [[ -f "${expected}" ]]; then
    local sz
    sz="$(stat -c '%s' "${expected}" 2>/dev/null || echo 0)"
    if [[ "${sz}" -ge 1024 ]]; then
      dll_present=1

      # trust check (provenance + allowlist). run check --kv in a subshell.
      local kv="" k="" v=""
      kv="$( ("$0" check --kv --ver "${want}") 2>/dev/null || true)"
      while IFS='=' read -r k v; do
        case "${k}" in
          META_MATCH) dll_meta_match="${v}" ;;
          ALLOWLIST_MATCH) dll_allow_match="${v}" ;;
        esac
      done <<<"${kv}"
      if [[ "${dll_meta_match}" -eq 1 && "${dll_allow_match}" -eq 1 ]]; then
        dll_trusted=1
        dll_ok=1
      fi
    fi
  fi

  local -a clones=()
  while IFS= read -r -d '' p; do
    clones+=("$p")
  done < <(_matching_clones_for_current_selection "${CTD}" "${SUFFIX}" "${BUILD_DATE:-}" || true)

  local -a supported_clones=()
  local c="" cb="" cd=""
  for c in "${clones[@]}"; do
    cb="$(basename "$c")"
    cd="$(extract_build_date_from_name "$cb" || true)"
    is_supported_source_date "$cd" || continue
    supported_clones+=("$c")
  done

  # tools "ok" means "the full set for the target date exists", not just "anything exists".
  # this catches half-built states after ctrl-c (e.g. v1/v2 created, v3/v4 missing).

  local -a expected_clones=()
  local newest_src_date="" newest_supported_date=""

  gather_sources || true
  newest_src_date="$(detect_build_date 2>/dev/null || true)"
  gather_supported_sources_from_sources || true
  newest_supported_date="$(detect_build_date_for_sources "${SUPPORTED_SOURCES[@]}" 2>/dev/null || true)"

  pick_sources_for_rebuild_selection "$newest_src_date" "$newest_supported_date" || true
  local tools_scope=""
  tools_scope="$(rebuild_plan_scope_label)"

  if ((${#PICKED[@]} > 0)); then
    filter_picked_by_min_date || true

    local src
    for src in "${PICKED[@]}"; do
      expected_clones+=("${CTD}/$(source_clone_basename "$src" "$SUFFIX")")
    done
  fi

  if ((${#expected_clones[@]} > 0)); then
    local missing=0 e
    for e in "${expected_clones[@]}"; do
      [[ -d "$e" ]] || {
        missing=1
        break
      }
    done
    [[ "$missing" -eq 0 ]] && tools_ok=1
  else
    # fallback: if we can't compute expectations, treat any supported-date clone as ok.
    ((${#supported_clones[@]} > 0)) && tools_ok=1
  fi

  local dll_meta_reason="unknown" dll_allow_reason="unknown"
  if [[ "${dll_present}" -eq 1 ]]; then
    dll_meta_reason="$(printf "%s\n" "${kv}" | awk -F= '$1=="META_MATCH_REASON"{print $2; exit}')"
    dll_allow_reason="$(printf "%s\n" "${kv}" | awk -F= '$1=="ALLOWLIST_MATCH_REASON"{print $2; exit}')"
    [[ -n "${dll_meta_reason}" ]] || dll_meta_reason="unknown"
    [[ -n "${dll_allow_reason}" ]] || dll_allow_reason="unknown"
  fi

  local -a missing_clones=()
  if [[ "${tools_ok}" -ne 1 ]] && declare -p expected_clones >/dev/null 2>&1 && ((${#expected_clones[@]} > 0)); then
    local __e
    for __e in "${expected_clones[@]}"; do
      [[ -d "$__e" ]] || missing_clones+=("$__e")
    done
  fi

  local dll_state="" dll_detail=""
  if [[ "${dll_ok}" -eq 1 ]]; then
    dll_state="READY"
    dll_detail="trusted FSR4 ${want}"
  elif [[ "${dll_present}" -eq 1 ]]; then
    dll_state="BLOCKED"
    amd_dll_trust_reason_summary "${dll_meta_match}" "${dll_meta_reason}" "${dll_allow_match}" "${dll_allow_reason}" joined " + " dll_detail
  else
    dll_state="MISSING"
    dll_detail="local FSR4 ${want} DLL not installed"
  fi

  local tools_state="" tools_detail="" tools_reason_kind=""
  if [[ "${tools_ok}" -eq 1 ]]; then
    tools_state="READY"
    if ((${#expected_clones[@]} > 0)); then
      tools_detail="${tools_scope}, ${#clones[@]} clone(s)"
    else
      tools_detail="${#clones[@]} clone(s) present"
    fi
    tools_reason_kind="ready"
  elif ((${#missing_clones[@]} > 0)); then
    if ((${#missing_clones[@]} < ${#expected_clones[@]})); then
      tools_state="PARTIAL"
      tools_detail="${#missing_clones[@]} missing clone(s) for ${tools_scope}"
      tools_reason_kind="partial"
    else
      tools_state="MISSING"
      tools_detail="clone set missing for ${tools_scope}"
      tools_reason_kind="missing_clones"
    fi
  elif [[ -n "${newest_src_date}" && -z "${newest_supported_date}" ]]; then
    tools_state="BLOCKED"
    tools_detail="only older sources found"
    tools_reason_kind="outdated_sources"
  else
    tools_state="BLOCKED"
    tools_detail="no supported source folders found"
    tools_reason_kind="no_sources"
  fi

  msg "Status:"
  prep_print_status_row "DLL" "$dll_state" "$dll_detail"
  prep_print_status_row "TOOLS" "$tools_state" "$tools_detail"
  msg ""

  if [[ "${dll_ok}" -ne 1 || "${tools_ok}" -ne 1 ]]; then
    msg "Why:"
    if [[ "${dll_ok}" -ne 1 ]]; then
      if [[ "${dll_present}" -eq 1 ]]; then
        msg "  DLL:"
        msg "    META_MATCH=${dll_meta_match} REASON=${dll_meta_reason}"
        msg "    ALLOWLIST_MATCH=${dll_allow_match} REASON=${dll_allow_reason}"
      else
        msg "  DLL:"
        msg "    missing from:"
        msg "    ${expected}"
      fi
    fi

    if [[ "${tools_ok}" -ne 1 ]]; then
      case "$tools_reason_kind" in
        partial | missing_clones)
          msg "  TOOLS:"
          msg "    expected clones for ${tools_scope}:"
          local __m
          for __m in "${expected_clones[@]}"; do
            msg "      $(basename "$__m")"
          done
          if ((${#missing_clones[@]} > 0)); then
            msg "    missing:"
            for __m in "${missing_clones[@]}"; do
              msg "      $(basename "$__m")"
            done
          fi
          ;;
        outdated_sources)
          msg "  TOOLS:"
          msg "    sources found, but only older builds are installed."
          msg "    newest found: ${newest_src_date}"
          msg "    minimum supported: $(min_supported_date_genvw)"
          ;;
        no_sources)
          msg "  TOOLS:"
          msg "    no supported Proton-CachyOS source folders found in:"
          msg "    ${CTD}"
          ;;
      esac
    fi
    msg ""
  fi

  # trust-gate before early return
  # if the dll looks "ok" from the earlier fast checks, re-check the trust bits
  # so we don't short-circuit prep when meta/allowlist is failing.

  if [[ "${dll_ok}" -eq 1 ]]; then
    local __kv="" __k="" __v=""
    local __meta_match=0 __allow_match=0

    __kv="$( ("$0" check --kv --ver "${want}") 2>/dev/null || true)"
    while IFS='=' read -r __k __v; do
      case "${__k}" in
        META_MATCH) __meta_match="${__v}" ;;
        ALLOWLIST_MATCH) __allow_match="${__v}" ;;
      esac
    done <<<"${__kv}"

    if [[ "${__meta_match}" -ne 1 || "${__allow_match}" -ne 1 ]]; then
      dll_ok=0
    fi
  fi

  # early out: nothing to do
  if [[ "${dll_ok}" -eq 1 && "${tools_ok}" -eq 1 ]]; then
    ok "Nothing to do — prep already complete"
    msg ""
    prep_print_final_summary "READY" "trusted FSR4 ${want}" "READY" "${tools_detail}" "OK" "no Steam restart needed" "${want}" 1
    return 0
  fi

  # dry-run: print the plan and stop
  if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
    warn "DRY-RUN: no changes will be made."
    msg ""
    msg "Plan:"
    local rebuild_plan_tail=""
    local rebuild_arg=""
    for rebuild_arg in "${rest[@]}"; do
      [[ "$rebuild_arg" == "--dry-run" ]] && continue
      rebuild_plan_tail+=" $(printf '%q' "$rebuild_arg")"
    done

    if [[ "${dll_ok}" -eq 1 ]]; then
      msg "  Step 1: skip DLL install"
      msg "    reason: trusted local DLL already present for FSR4 ${want}"
    else
      msg "  Step 1: install local DLL"
      if [[ "${dll_present}" -eq 1 ]]; then
        msg "    reason: local DLL exists but is not trusted"
      else
        msg "    reason: target DLL is missing"
      fi
      msg "    command:"
      if [[ -n "${exe}" ]]; then
        msg "      $(cmd_dll) install --exe \"${exe}\" --dst-dir \"${dst_dir}\"${keep:+ --keep}"
      else
        msg "      $(cmd_dll) install --url \"${url}\" --dst-dir \"${dst_dir}\"${keep:+ --keep}${force_url:+ --force-url}"
      fi
      msg "    Source artifact must contain FSR4 ${want}."
    fi

    if [[ "${tools_ok}" -eq 1 ]]; then
      msg "  Step 2: skip rebuild"
      msg "    reason: tool clone set is already complete"
    else
      case "$tools_reason_kind" in
        partial | missing_clones)
          msg "  Step 2: rebuild tools"
          msg "    reason: clone set is incomplete for ${tools_scope}"
          msg "    command:"
          msg "      $(cmd_proton) rebuild${rebuild_plan_tail}"
          ;;
        outdated_sources)
          msg "  Step 2: cannot rebuild tools yet"
          msg "    reason: only older Proton-CachyOS sources are installed"
          msg "    need: source date >= $(min_supported_date_genvw)"
          ;;
        no_sources)
          msg "  Step 2: cannot rebuild tools yet"
          msg "    reason: no supported Proton-CachyOS source folders are installed"
          ;;
      esac
    fi

    if [[ "${tools_ok}" -ne 1 && ( "$tools_reason_kind" == "partial" || "$tools_reason_kind" == "missing_clones" ) ]]; then
      msg "  Restart Steam after rebuild."
    fi
    return 0
  fi

  # consent gate
  if [[ "${YES}" -ne 1 ]]; then
    if ! is_tty; then
      err "Non-interactive mode: refusing to modify without --yes."
      msg "${I_ARROW} Run:"
      msg "  $(cmd_proton) prep --yes ${rest[*]:-}"
      return 2
    fi

    msg "This will modify files under:"
    msg "  • ${dst_dir}"
    msg "  • ${CTD}"
    msg ""

    if ! ask_yes_no_default "Proceed with PREP now? [Y/n]: " "y"; then
      warn "Aborted by user."
      return 1
    fi
    msg ""
  fi

  local ran_dll_step=0 ran_tools_step=0

  # step 1: dll install (only when missing/untrusted)
  if [[ "${dll_ok}" -ne 1 ]]; then
    msg "${I_BOX} Step 1/2: Install local DLL (FSR4 ${want})"
    ran_dll_step=1

    if [[ -n "${exe}" ]]; then
      GENVW_IN_PREP=1 GENVW_ASSUME_YES="${YES}" GENVW_INSTALL_EXPECT_VER="${want}" amd_dll_run install --exe "${exe}" --dst-dir "${dst_dir}" ${keep:+ --keep}
    else
      GENVW_IN_PREP=1 GENVW_ASSUME_YES="${YES}" GENVW_INSTALL_EXPECT_VER="${want}" amd_dll_run install --url "${url}" --dst-dir "${dst_dir}" ${keep:+ --keep} ${force_url:+ --force-url}
    fi

    # show trust summary right after install so you can see why it can still be blocked
    prep_dll_trust_summary "$expected"
    msg ""
  fi

  # step 2: proton tools (build whatever is missing)
  if [[ "${tools_ok}" -ne 1 ]]; then
    msg "${I_PUZZLE} Step 2/2: Build/refresh gENVW Proton tools (-${SUFFIX})"
    ran_tools_step=1
    GENVW_IN_PREP=1 do_rebuild "${rest[@]}"
    msg ""
  fi

  local post_kv="" post_k="" post_v=""
  local post_dll_present=0 post_meta_match=0 post_allow_match=0
  local post_meta_reason="unknown" post_allow_reason="unknown"
  post_kv="$( (do_check --kv --ver "${want}") 2>/dev/null || true)"
  while IFS='=' read -r post_k post_v; do
    case "$post_k" in
      DLL_PRESENT) post_dll_present="${post_v:-0}" ;;
    esac
  done <<<"$post_kv"
  amd_dll_trust_snapshot_from_kv "$post_kv" post_meta_match post_meta_reason post_allow_match post_allow_reason

  local final_dll_state="" final_dll_detail="" final_tools_detail="" final_tools_state="READY"
  if [[ "${post_dll_present}" -eq 1 && "${post_meta_match}" -eq 1 && "${post_allow_match}" -eq 1 ]]; then
    final_dll_state="READY"
    final_dll_detail="trusted FSR4 ${want}"
  elif [[ "${post_dll_present}" -eq 1 ]]; then
    final_dll_state="BLOCKED"
    amd_dll_trust_reason_summary "${post_meta_match}" "${post_meta_reason}" "${post_allow_match}" "${post_allow_reason}" joined " + " final_dll_detail
  else
    final_dll_state="MISSING"
    final_dll_detail="local FSR4 ${want} DLL missing"
  fi

  if [[ "${ran_tools_step}" -eq 1 ]]; then
    final_tools_detail="refreshed (-${SUFFIX})"
  else
    final_tools_detail="${tools_detail}"
  fi

  ok "PREP complete"
  msg ""
  if [[ "${ran_tools_step}" -eq 1 ]]; then
    prep_print_final_summary "${final_dll_state}" "${final_dll_detail}" "${final_tools_state}" "${final_tools_detail}" "ACTION" "restart required after tool refresh" "${want}" "$((post_dll_present == 1 && post_meta_match == 1 && post_allow_match == 1 ? 1 : 0))"
  else
    prep_print_final_summary "${final_dll_state}" "${final_dll_detail}" "${final_tools_state}" "${final_tools_detail}" "OK" "no Steam restart needed" "${want}" "$((post_dll_present == 1 && post_meta_match == 1 && post_allow_match == 1 ? 1 : 0))"
  fi
}

# check_human_provider_inventory_collect
# shared human-summary provider accounting for direct check and wrapper preflight.

check_human_provider_inventory_collect() {
  local -n _chpi_c_usable_ref="$1"
  local -n _chpi_c_known_ref="$2"
  local -n _chpi_c_newest_ref="$3"
  local -n _chpi_dw_usable_ref="$4"
  local -n _chpi_dw_known_ref="$5"
  local -n _chpi_dw_newest_ref="$6"
  local _chpi_dw_row="" _chpi_dw_rec="" _chpi_dw_m=0 _chpi_dw_mi=0 _chpi_dw_b=0
  local _chpi_best_m=0 _chpi_best_mi=0 _chpi_best_b=0
  local _chpi_dw_v="" _chpi_dw_bbl="" _chpi_dw_a="" _chpi_dw_a_short=""
  local -a _chpi_dw_targets=()

  _chpi_c_usable_ref=0
  _chpi_c_known_ref=0
  _chpi_c_newest_ref=""
  _chpi_dw_usable_ref=0
  _chpi_dw_known_ref=0
  _chpi_dw_newest_ref=""

  SOURCES=()
  SUPPORTED_SOURCES=()
  if [[ -d "$CTD" ]]; then
    gather_sources >/dev/null 2>&1 || true
    gather_supported_sources_from_sources >/dev/null 2>&1 || true
    _chpi_c_known_ref="${#SOURCES[@]}"
    _chpi_c_usable_ref="${#SUPPORTED_SOURCES[@]}"
    if ((${_chpi_c_usable_ref:-0} > 0)); then
      _chpi_c_newest_ref="$(source_newest_display_from_paths "${SUPPORTED_SOURCES[@]}" 2>/dev/null || true)"
    fi
  fi

  gather_dwproton_display_targets _chpi_dw_targets
  for _chpi_dw_row in "${_chpi_dw_targets[@]}"; do
    _chpi_dw_rec="$(dwproton_display_row_record "$_chpi_dw_row" 2>/dev/null || true)"
    [[ -n "$_chpi_dw_rec" ]] || continue
    _chpi_dw_known_ref=$(( _chpi_dw_known_ref + 1 ))
    IFS=$'\t' read -r _chpi_dw_m _chpi_dw_mi _chpi_dw_b _ _ _chpi_dw_v _chpi_dw_bbl _ _chpi_dw_a _ _ <<<"$_chpi_dw_rec" || continue
    [[ "$_chpi_dw_bbl" == "unresolved" ]] && continue
    _chpi_dw_usable_ref=$(( _chpi_dw_usable_ref + 1 ))
    [[ "$_chpi_dw_m" =~ ^[0-9]+$ ]] || _chpi_dw_m=0
    [[ "$_chpi_dw_mi" =~ ^[0-9]+$ ]] || _chpi_dw_mi=0
    [[ "$_chpi_dw_b" =~ ^[0-9]+$ ]] || _chpi_dw_b=0
    if (( _chpi_dw_m > _chpi_best_m || (_chpi_dw_m == _chpi_best_m && _chpi_dw_mi > _chpi_best_mi) || (_chpi_dw_m == _chpi_best_m && _chpi_dw_mi == _chpi_best_mi && _chpi_dw_b > _chpi_best_b) )); then
      _chpi_best_m="$_chpi_dw_m"
      _chpi_best_mi="$_chpi_dw_mi"
      _chpi_best_b="$_chpi_dw_b"
      _chpi_dw_a_short="${_chpi_dw_a##*-}"
      _chpi_dw_newest_ref="${_chpi_dw_v} base ${_chpi_dw_bbl:-?} ${_chpi_dw_a_short:-x86_64}"
    fi
  done
}

check_human_provider_inventory_emit_kv() {
  local _chpi_c_usable=0 _chpi_c_known=0 _chpi_c_newest=""
  local _chpi_dw_usable=0 _chpi_dw_known=0 _chpi_dw_newest=""
  check_human_provider_inventory_collect \
    _chpi_c_usable _chpi_c_known _chpi_c_newest \
    _chpi_dw_usable _chpi_dw_known _chpi_dw_newest
  printf 'HUMAN_SUMMARY_SCHEMA=1\n'
  printf 'CACHYOS_USABLE=%s\n' "${_chpi_c_usable:-0}"
  printf 'CACHYOS_KNOWN=%s\n' "${_chpi_c_known:-0}"
  printf 'CACHYOS_NEWEST=%s\n' "${_chpi_c_newest:-}"
  printf 'DWPROTON_USABLE=%s\n' "${_chpi_dw_usable:-0}"
  printf 'DWPROTON_KNOWN=%s\n' "${_chpi_dw_known:-0}"
  printf 'DWPROTON_NEWEST=%s\n' "${_chpi_dw_newest:-}"
}

# do_check
# quick health check for: ctd, sources/clones, and the local dll.
# --kv prints key=value only (meant for scripts).

do_check() {
  # pull --kv/--machine out first so parse_kv_flags sees the usual args
  local __kv=0
  local __human_summary_kv=0
  local __args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --kv | --machine)
        __kv=1
        shift
        ;;
      --human-summary-kv)
        __human_summary_kv=1
        shift
        ;;
      *)
        __args+=("$1")
        shift
        ;;
    esac
  done

  genvw_reset_validation_trust_anchor_defaults

  # allow running on hosts without steam/ctd (kv consumers still want output)
  local GENVW_MAJOR_SELECTION_DEFAULT_MODE="all_supported"
  ((__kv == 1)) && GENVW_MAJOR_SELECTION_DEFAULT_MODE="explicit"
  parse_kv_flags --ctd-optional "${__args[@]}"
  if [[ "${GENVW_KV_HELP:-0}" == "1" ]]; then
    return 0
  fi
  fsr4_apply_effective_local_default_if_implicit "${DLL_DST_DIR_DEFAULT}"

  if ((__human_summary_kv == 1)); then
    check_human_provider_inventory_emit_kv
    return 0
  fi

  # kv path: keep output strict key=value (no msg/warn/etc)
  if ((__kv == 1)); then
    local GENVW_MAJOR_SELECTION_MODE="explicit"
    # dll fingerprint (only if the file exists)
    local __dll_present=0 __dll_sha="" __dll_size=0
    if [[ -f "$LOCALDLL" ]]; then
      __dll_present=1
      __dll_size="$(wc -c <"$LOCALDLL" 2>/dev/null || echo 0)"
      if command -v sha256sum >/dev/null 2>&1; then
        __dll_sha="$(sha256sum "$LOCALDLL" 2>/dev/null | awk '{print $1}' || true)"
      fi
    fi

    # ctd may be missing in "status-only" cases
    local __ctd_exists=0
    [[ -d "$CTD" ]] && __ctd_exists=1

    local __sha_tool="none"
    command -v sha256sum >/dev/null 2>&1 && __sha_tool="sha256sum"

    local __sources_count=0 __tools_found=0
    local __source_mode="none" __source_provenance="none" __source_root=""
    local -a __kv_sources=()
    local __kv_source_selection="${GENVW_SOURCE_SELECTION:-default}"
    SOURCES=()
    SUPPORTED_SOURCES=()
    if [[ -d "$CTD" ]]; then
      if [[ "$__kv_source_selection" == "default" ]]; then
        GENVW_SOURCE_SELECTION="ctd_preferred"
      fi
      gather_sources >/dev/null 2>&1 || true
      GENVW_SOURCE_SELECTION="$__kv_source_selection"
      gather_supported_sources_from_sources >/dev/null 2>&1 || true
      source_provenance_summary SOURCES __source_mode __source_provenance __source_root
      __sources_count="${#SUPPORTED_SOURCES[@]}"
      __kv_sources=("${SUPPORTED_SOURCES[@]}")

      # count clones with the shared matcher so kv/status/rebuild stay aligned.
      if [[ -n "$SUFFIX" ]]; then
        __tools_found=0
        while IFS= read -r -d '' __p; do
          ((__tools_found += 1))
        done < <(_matching_clones "$CTD" "$MAJOR" "$SUFFIX" "")
      fi
    fi

    # KV contract version for wrapper consumers (genvw).
    # Bump only when key meanings or required keys change.
    printf "KV_SCHEMA=1\n"
    printf "STEAM_KIND=%s\n" "${STEAM_KIND-}"
    printf "STEAM_ROOT=%s\n" "${STEAM_ROOT-}"
    printf "CTD=%s\n" "$CTD"
    printf "CTD_EXISTS=%s\n" "$__ctd_exists"
    printf "MAJOR=%s\n" "$MAJOR"
    printf "SUFFIX=%s\n" "$SUFFIX"
    printf "LOCALDLL=%s\n" "$LOCALDLL"
    printf "DLL_PRESENT=%s\n" "$__dll_present"
    printf "DLL_SIZE=%s\n" "$__dll_size"
    printf "SHA256_TOOL=%s\n" "$__sha_tool"
    [[ -n "$__dll_sha" ]] && printf "DLL_SHA256=%s\n" "$__dll_sha"
    printf "PROTON_SOURCE_MODE=%s\n" "$__source_mode"
    printf "PROTON_SOURCE_PROVENANCE=%s\n" "$__source_provenance"
    printf "PROTON_SOURCE_ROOT=%s\n" "$__source_root"
    printf "PROTON_SOURCES_COUNT=%s\n" "$__sources_count"
    printf "PROTON_CLONES_COUNT=%s\n" "$__tools_found"

    local __build_date="${BUILD_DATE:-}"
    [[ -z "$__build_date" ]] && __build_date="$(detect_build_date_for_sources "${__kv_sources[@]}" 2>/dev/null || true)"
    local __dxvk_target_root="" __dxvk_target_date="" __dxvk_target_reason=""
    local __dxvk_expected_policy="" __dxvk_probe_policy="" __dxvk_final_policy="" __dxvk_warn=""
    local __expected_for_date=0 __missing_for_date=0 __complete_for_date=0

    if [[ -n "$__build_date" ]]; then
      local __src __bn __clone_dir
      for __src in "${__kv_sources[@]}"; do
        __bn="$(source_effective_base "$__src")"
        if [[ "$(source_build_date "$__src" 2>/dev/null || true)" == "$__build_date" ]]; then
          ((__expected_for_date++))
          __clone_dir="${CTD}/$(source_clone_basename "$__src" "$SUFFIX")"
          [[ -d "$__clone_dir" ]] || ((__missing_for_date++))
        fi
      done
      if [[ "$__expected_for_date" -gt 0 && "$__missing_for_date" -eq 0 ]]; then
        __complete_for_date=1
      fi
    fi

    printf "PROTON_BUILD_DATE=%s\n" "$__build_date"
    printf "PROTON_EXPECTED_CLONES_FOR_DATE=%s\n" "$__expected_for_date"
    printf "PROTON_MISSING_CLONES_FOR_DATE=%s\n" "$__missing_for_date"
    printf "PROTON_CLONES_COMPLETE_FOR_DATE=%s\n" "$__complete_for_date"

    dxvk_resolve_target_state \
      __dxvk_target_root __dxvk_target_date __dxvk_target_reason \
      __dxvk_expected_policy __dxvk_probe_policy __dxvk_final_policy __dxvk_warn
    if [[ -z "$__dxvk_target_root" ]]; then
      for __src in "${__kv_sources[@]}"; do
        if [[ "$(source_build_date "$__src" 2>/dev/null || true)" == "${__dxvk_target_date:-$__build_date}" ]]; then
          __dxvk_target_root="$__src"
          break
        fi
      done
    fi
    if [[ -z "$__dxvk_probe_policy" && -n "$__dxvk_target_root" ]]; then
      __dxvk_probe_policy="$(dxvk_probe_tree_policy "$__dxvk_target_root" 2>/dev/null || true)"
      if [[ -n "$__dxvk_probe_policy" && "$__dxvk_probe_policy" != "unknown_or_unsupported" ]]; then
        __dxvk_final_policy="$__dxvk_probe_policy"
      fi
    fi
    printf "PROTON_DXVK_TARGET_ROOT=%s\n" "$__dxvk_target_root"
    printf "PROTON_DXVK_TARGET_BUILD_DATE=%s\n" "$__dxvk_target_date"
    printf "PROTON_DXVK_TARGET_REASON=%s\n" "$__dxvk_target_reason"
    printf "PROTON_DXVK_EXPECTED_POLICY=%s\n" "$__dxvk_expected_policy"
    printf "PROTON_DXVK_PROBE_POLICY=%s\n" "$__dxvk_probe_policy"
    printf "PROTON_DXVK_POLICY=%s\n" "$__dxvk_final_policy"
    printf "PROTON_DXVK_POLICY_WARN=%s\n" "$__dxvk_warn"

    printf "TOOLS_FOUND=%s\n" "$__tools_found"

    # meta fields (if present). we can upgrade v1 meta silently so kv consumers get filled keys.
    local __meta="${LOCALDLL%.dll}.meta.txt"
    if [[ -f "$__meta" ]]; then
      local __drv_label=""
      # prefer new label key, fall back to old one
      __drv_label="$(
        {
          grep -E '^DRIVER_LABEL=' "$__meta" 2>/dev/null || true
          grep -E '^AMD_DRIVER_LABEL=' "$__meta" 2>/dev/null || true
        } | head -n1 | cut -d= -f2-
      )"
      __drv_label="${__drv_label//$'\r'/}"
      if declare -F kv_norm >/dev/null 2>&1; then
        __drv_label="$(kv_norm "$__drv_label")"
      fi
      if [[ -n "$__drv_label" ]]; then
        amd_meta_upgrade_v1 "$__meta" "$LOCALDLL" "$__drv_label" "" "" "" >/dev/null 2>&1 || true
      fi
    fi
    local __meta_present=0
    local __extract_method="" __extracted_from="" __extracted_file="" __intended="" __kernel="" __os=""
    if [[ -f "$__meta" ]]; then
      __meta_present=1

      # pull a few meta lines that help when debugging "where did this dll come from?"
      __extract_method="$(sed -nE 's/^EXTRACT_METHOD=//p' "$__meta" 2>/dev/null | head -n1 || true)"
      __extracted_from="$(sed -nE 's/^EXTRACTED_FROM=//p' "$__meta" 2>/dev/null | head -n1 || true)"
      __extracted_file="$(sed -nE 's/^EXTRACTED_FILE=//p' "$__meta" 2>/dev/null | head -n1 || true)"
      __intended="$(sed -nE 's/^INTENDED_CACHE_PATH=//p' "$__meta" 2>/dev/null | head -n1 || true)"
      __kernel="$(sed -nE 's/^KERNEL=//p' "$__meta" 2>/dev/null | head -n1 || true)"
      __os="$(sed -nE 's/^OS=//p' "$__meta" 2>/dev/null | head -n1 || true)"

      __extract_method="$(kv_norm "$__extract_method")"
      __extracted_from="$(kv_norm "$__extracted_from")"
      __extracted_file="$(kv_norm "$__extracted_file")"
      __intended="$(kv_norm "$__intended")"
      __kernel="$(kv_norm "$__kernel")"
      __os="$(kv_norm "$__os")"
    fi

    # optional version fields (left empty unless you fill them during install)
    local __dll_fv="" __dll_pv=""
    if [[ -f "$__meta" ]]; then
      __dll_fv="$(sed -nE 's/^DLL_FILE_VERSION=//p' "$__meta" 2>/dev/null | head -n1 || true)"
      __dll_pv="$(sed -nE 's/^DLL_PRODUCT_VERSION=//p' "$__meta" 2>/dev/null | head -n1 || true)"
      __dll_fv="$(kv_norm "$__dll_fv")"
      __dll_pv="$(kv_norm "$__dll_pv")"
    fi

    printf "META_PATH=%s\n" "$__meta"
    printf "META_PRESENT=%s\n" "$__meta_present"

    # Meta integrity for `check --kv` must stay aligned with `dll verify`.
    # Reuse the shared provenance decision, then keep the KV allowlist block
    # below as-is so the contract and reason labels stay stable.
    local __meta_match=0 __meta_reason=""
    local __meta_dll_sha="" __meta_dll_size=""
    local __kv_allow_match_unused=0 __kv_allow_reason_unused=""
    local __kv_trust_match_unused=0 __kv_trust_summary_unused="" __kv_trust_reason_unused=""
    local __kv_dll_sha_unused="" __kv_dll_size_unused="" __kv_src_url_unused=""
    amd_dll_provenance_integrity_decide_with_opts \
      "$LOCALDLL" \
      "$__meta" \
      0 \
      1 \
      __meta_match \
      __meta_reason \
      __kv_allow_match_unused \
      __kv_allow_reason_unused \
      __kv_trust_match_unused \
      __kv_trust_summary_unused \
      __kv_trust_reason_unused \
      __kv_dll_sha_unused \
      __kv_dll_size_unused \
      __meta_dll_sha \
      __meta_dll_size \
      __kv_src_url_unused

    printf "META_MATCH=%s\n" "$__meta_match"
    printf "META_MATCH_REASON=%s\n" "$__meta_reason"
    printf "META_DLL_SIZE=%s\n" "$__meta_dll_size"
    printf "META_DLL_SHA256=%s\n" "$__meta_dll_sha"
    printf "DLL_FILE_VERSION=%s\n" "$__dll_fv"
    printf "DLL_PRODUCT_VERSION=%s\n" "$__dll_pv"
    printf "EXTRACT_METHOD=%s\n" "$__extract_method"
    printf "EXTRACTED_FROM=%s\n" "$__extracted_from"
    printf "EXTRACTED_FILE=%s\n" "$__extracted_file"
    printf "INTENDED_CACHE_PATH=%s\n" "$__intended"
    printf "KERNEL=%s\n" "$__kernel"
    printf "OS=%s\n" "$__os"

    # extra source/provenance fields (handy when you’re comparing installs)
    local __meta_installed_at="" __meta_source_sha="" __meta_source_url="" __meta_source_path="" __meta_source_kind=""
    if ((__meta_present == 1)); then
      __meta_installed_at="$(sed -nE 's/^INSTALLED_AT_UTC=//p' "$__meta" 2>/dev/null | head -n1 || true)"
      __meta_source_sha="$(sed -nE 's/^SOURCE_SHA256=//p' "$__meta" 2>/dev/null | head -n1 || true)"
      __meta_source_url="$(sed -nE 's/^SOURCE_URL=//p' "$__meta" 2>/dev/null | head -n1 || true)"
      __meta_source_path="$(sed -nE 's/^SOURCE_PATH=//p' "$__meta" 2>/dev/null | head -n1 || true)"
      __meta_source_kind="$(sed -nE 's/^SOURCE_KIND=//p' "$__meta" 2>/dev/null | head -n1 || true)"
      __meta_installed_at="$(kv_norm "$__meta_installed_at")"
      __meta_source_sha="$(kv_norm "$__meta_source_sha")"
      __meta_source_url="$(kv_norm "$__meta_source_url")"
      __meta_source_path="$(kv_norm "$__meta_source_path")"
      __meta_source_kind="$(kv_norm "$__meta_source_kind")"
    fi

    printf "META_INSTALLED_AT=%s\n" "$__meta_installed_at"
    printf "META_SOURCE_SHA256=%s\n" "$__meta_source_sha"
    printf "META_SOURCE_URL=%s\n" "$__meta_source_url"
    printf "META_SOURCE_PATH=%s\n" "$__meta_source_path"
    printf "META_SOURCE_KIND=%s\n" "$__meta_source_kind"

    # allowlist gate (kv-only): require sha256+size only.
    local __allow_path="${AMD_DLL_ALLOWLIST}"
    local __allow_present=0 __allow_match=0 __allow_reason=""
    [[ -f "$__allow_path" ]] && __allow_present=1

    if ((__dll_present == 0)); then
      __allow_match=0
      __allow_reason="dll_missing"
    elif ((__allow_present == 0)); then
      __allow_match=0
      __allow_reason="allowlist_missing"
    elif [[ -z "$__dll_sha" || -z "$__dll_size" || "$__dll_size" == "0" ]]; then
      __allow_match=0
      __allow_reason="pair_unavailable"
    else
      if awk -v sha="$__dll_sha" -v size="$__dll_size" '
          { sub(/\r$/, "", $0) }
          /^[[:space:]]*#/ {next}
          /^[[:space:]]*$/ {next}
          {
            if ($1==sha && $2==size) { found=1; exit }
          }
          END { exit (found?0:1) }
          ' "$__allow_path"; then
        __allow_match=1
        __allow_reason="ok"
      else
        __allow_match=0
        __allow_reason="not_allowlisted"
      fi
    fi

    printf "ALLOWLIST_PATH=%s\n" "$__allow_path"
    printf "ALLOWLIST_PRESENT=%s\n" "$__allow_present"
    printf "ALLOWLIST_MATCH=%s\n" "$__allow_match"
    printf "ALLOWLIST_MATCH_REASON=%s\n" "$__allow_reason"

    return 0
  fi

  local _ch_ctd_state="MISSING" _ch_ctd_detail="compatibilitytools.d missing"
  local _ch_py_state="READY" _ch_py_detail="python3 available"
  local _ch_mk_state="READY" _ch_mk_detail="mktemp available"
  local _ch_dll_state="MISSING" _ch_dll_detail="no DLLs in cache"
  local _ch_prov_state="MISSING"

  if [[ -d "$CTD" ]]; then
    _ch_ctd_state="READY"
    _ch_ctd_detail="compatibilitytools.d exists"
  fi
  have python3 || { _ch_py_state="MISSING"; _ch_py_detail="python3 not found"; }
  have mktemp  || { _ch_mk_state="MISSING"; _ch_mk_detail="mktemp not found"; }

  local _ch_dll_dir="$DLL_DST_DIR_DEFAULT"
  local _ch_dll_count=0 _ch_dll_parts="" _ch_dll_f="" _ch_dll_base="" _ch_dll_ver=""
  local _ch_dll_sz=0 _ch_dll_sz_fmt="" _ch_dll_item="" _ch_had_null=0
  if [[ -d "$_ch_dll_dir" ]]; then
    shopt -q nullglob && _ch_had_null=1
    shopt -s nullglob
    for _ch_dll_f in "$_ch_dll_dir"/*.dll; do
      _ch_dll_base="${_ch_dll_f##*/}"
      if [[ "$_ch_dll_base" =~ _v([0-9]+\.[0-9]+\.[0-9]+)\.dll$ ]]; then
        _ch_dll_ver="${BASH_REMATCH[1]}"
        _ch_dll_sz="$(wc -c < "$_ch_dll_f" 2>/dev/null || echo 0)"
        _ch_dll_sz_fmt="$(amd_size_human_short "$_ch_dll_sz")"
        _ch_dll_item="${_ch_dll_ver} (${_ch_dll_sz_fmt})"
        [[ -z "$_ch_dll_parts" ]] && _ch_dll_parts="$_ch_dll_item" || _ch_dll_parts="${_ch_dll_parts}, ${_ch_dll_item}"
        _ch_dll_count=$(( _ch_dll_count + 1 ))
      fi
    done
    (( _ch_had_null == 1 )) || shopt -u nullglob
    if (( _ch_dll_count > 0 )); then
      _ch_dll_state="READY"
      _ch_dll_detail="${_ch_dll_count} installed: ${_ch_dll_parts}"
    fi
  fi

  local _ch_eligible=0 _ch_total=0 _ch_c_newest=""
  local _ch_dw_usable=0 _ch_dw_known=0 _ch_dw_newest=""
  check_human_provider_inventory_collect \
    _ch_eligible _ch_total _ch_c_newest \
    _ch_dw_usable _ch_dw_known _ch_dw_newest

  local _ch_prov_detail="CachyOS ${_ch_eligible} usable / ${_ch_total} known; DW-Proton ${_ch_dw_usable} usable / ${_ch_dw_known} known"
  if [[ "${_ch_eligible:-0}" -gt 0 || "${_ch_dw_usable:-0}" -gt 0 ]]; then
    _ch_prov_state="READY"
  fi

  msg "${I_DEBUG} genvw proton check"
  msg ""
  msg "Paths:"
  printf '  %-22s %s\n' "Compatibilitytools.d:" "${CTD:-(none)}"
  printf '  %-22s %s\n' "DLL Cache:" "${_ch_dll_dir:-(none)}"
  printf '  %-22s %s\n' "Suffix:" "$SUFFIX"
  msg ""
  msg "Checks:"
  printf '  %-9s %-9s %s\n' "ITEM" "STATE" "DETAIL"
  printf '  %-9s %-9s %s\n' "CTD" "$_ch_ctd_state" "$_ch_ctd_detail"
  printf '  %-9s %-9s %s\n' "PYTHON" "$_ch_py_state" "$_ch_py_detail"
  printf '  %-9s %-9s %s\n' "MKTEMP" "$_ch_mk_state" "$_ch_mk_detail"
  printf '  %-9s %-9s %s\n' "DLL CACHE" "$_ch_dll_state" "$_ch_dll_detail"
  printf '  %-9s %-9s %s\n' "PROVIDERS" "$_ch_prov_state" "$_ch_prov_detail"
  msg ""
  msg "Targets:"
  printf '  %-11s %-15s %s\n' "PROVIDER" "USABLE / TOTAL" "NEWEST"
  printf '  %-11s %-15s %s\n' "CachyOS" "${_ch_eligible} / ${_ch_total}" "${_ch_c_newest:-(none)}"
  printf '  %-11s %-15s %s\n' "DW-Proton" "${_ch_dw_usable} / ${_ch_dw_known}" "${_ch_dw_newest:-(none)}"
  msg ""
  msg "Inventory:"
  printf '  %-14s %s\n' "Full targets:" "genvw proton sources"
  printf '  %-14s %s\n' "DLL cache:" "genvw proton dll list"
  msg ""

}

# do_gpu
# gpu diagnostics (calls into genvw to show detection details if needed).
# genvw_detect_rdna_gen_into_vars, msg, warn
# main

do_gpu() {
  # helper-side gpu classification info (not authoritative).
  if [ "${GENVW_SKIP_GPU_CHECK:-0}" = "1" ]; then
    warn "GENVW_SKIP_GPU_CHECK=1 (GPU checks bypassed)"
  fi

  genvw_detect_rdna_gen_into_vars

  local _bdf=""
  _bdf="$(normalize_bdf "${DRI_PRIME-}" 2>/dev/null || true)"
  msg "${I_DESKTOP} GPU detection"
  msg ""
  printf '  %-11s %s\n' "ITEM" "VALUE"
  print_detail_table_row "DRI_PRIME" "${DRI_PRIME:-"(empty)"}"
  print_detail_table_row "BDF" "${_bdf:-"(none)"}"
  print_detail_table_row "RDNA_GEN" "$GENVW_RDNA_GEN"

  if ! have lspci; then
    print_detail_table_row "LSPCI" "missing"
    warn "Install (Arch): sudo pacman -S pciutils"
    return 0
  fi

  if [ -n "$GENVW_GPU_LINE" ]; then
    print_detail_table_row "DEVICE" "$GENVW_GPU_LINE"
  fi
}

# status_color_enabled
# true when stdout is a TTY and NO_COLOR is not set.
# used only by human status output helpers below.
status_color_enabled() { [[ -t 1 && -z "${NO_COLOR:-}" ]]; }

status_bold()   { status_color_enabled && printf '\033[1m%s\033[0m' "$*" || printf '%s' "$*"; }
status_green()  { status_color_enabled && printf '\033[32m%s\033[0m' "$*" || printf '%s' "$*"; }
status_yellow() { status_color_enabled && printf '\033[33m%s\033[0m' "$*" || printf '%s' "$*"; }
status_red()    { status_color_enabled && printf '\033[31m%s\033[0m' "$*" || printf '%s' "$*"; }
status_dim()    { status_color_enabled && printf '\033[2m%s\033[0m' "$*" || printf '%s' "$*"; }

# human_mib_from_bytes VAL
# prints "X.X MiB" for a byte count. Never used in machine outputs.
human_mib_from_bytes() {
  local _bytes=${1:-}
  if [[ -z "$_bytes" || ! "$_bytes" =~ ^[0-9]+$ ]]; then printf 'unknown'; return; fi
  awk -v b="$_bytes" 'BEGIN { printf "%.1f MiB", b/1048576 }'
}

# status_state_colored STATE
# applies color to a state string for human status output only.
status_state_colored() {
  local _s="${1:-}"
  case "$_s" in
    OK|READY|PRESENT) status_green "$_s" ;;
    WARN|MISSING|OLD|PARTIAL|LIMITED) status_yellow "$_s" ;;
    ERROR|FAIL|UNTRUSTED|BLOCKED) status_red "$_s" ;;
    *) printf '%s' "$_s" ;;
  esac
}

# status_print_summary_row ITEM STATE DETAIL
# used only by human status (do_status), never by machine/kv paths.
status_print_summary_row() {
  local _item="${1:-}" _state="${2:-}" _detail="${3:-}"
  printf '  %-10s ' "$_item"
  status_state_colored "$_state"
  printf '    %s\n' "$_detail"
}

# status_print_targets_row PROVIDER TARGET CLONE STATE
# used only by human status default rebuild targets table.
status_print_targets_row() {
  local _prov="${1:-}" _target="${2:-}" _clone="${3:-}" _state="${4:-}"
  printf '  %-14s  %-12s  %-52s  ' "$_prov" "$_target" "$_clone"
  status_state_colored "$_state"
  printf '\n'
}

# status_print_dll_row VERSION DEFAULT TRUSTED SIZE
# used only by human status local FSR4 DLLs table.
status_print_dll_row() {
  local _ver="${1:-}" _def="${2:-}" _trust="${3:-}" _size="${4:-}"
  local _def_str _trust_str
  if [[ "$_def" == "yes" ]]; then
    _def_str="$(status_green yes)"
  else
    _def_str="no"
  fi
  if [[ "$_trust" == "yes" ]]; then
    _trust_str="$(status_green yes)"
  else
    _trust_str="$(status_red no)"
  fi
  printf '  %-7s  %-7s  %-9s  %s\n' "$_ver" "$_def_str" "$_trust_str" "$_size"
}

# status_print_provider_row PROVIDER DEFAULT_TARGETS AVAILABLE_TARGETS FEATURES
# used only by human status providers table.
status_print_provider_row() {
  local _prov="${1:-}" _def="${2:-}" _avail="${3:-}" _feat="${4:-}"
  printf '  %-14s  %-15s  %-17s  %s\n' "$_prov" "$_def" "$_avail" "$_feat"
}

# do_status
# prints human-readable status dashboard: summary, default targets, local FSR4 DLLs, providers.
# uses: parse_kv_flags, steam_detect_ctd, amd_dll_provenance_integrity
# output: msg/warn to stdout; color only when stdout is TTY and NO_COLOR unset.
# called by: main

do_status() {
  parse_kv_flags --ctd-optional "$@"
  if [[ "${GENVW_KV_HELP:-0}" == "1" ]]; then
    return 0
  fi
  fsr4_apply_effective_local_default_if_implicit "${DLL_DST_DIR_DEFAULT}"

  # keep status working even without steam installed
  # parse_kv_flags fills ctd + steam fields when it can (and honors --ctd)
  # only probe for ctd if it's still empty
  if [[ -z "${CTD:-}" ]]; then
    steam_detect_ctd "$MAJOR"
    CTD="$STEAM_CTD_CHOSEN"
  fi
  local min_date="${MIN_SUPPORTED_DATE_GENVW:-20251222}"
  local ctd_state="MISSING" ctd_detail="compatibilitytools.d not found"
  local sources_state="MISSING" sources_detail="no supported source folders found"
  local dll_sum_state="MISSING" dll_sum_detail="default ${FSR4_EFFECTIVE_LOCAL_DEFAULT_VER} not installed"
  local clones_state="MISSING" clones_detail="no default clone(s) found"
  local steam_state="OK" steam_detail="not running"
  local total_sources_count=0
  local eligible_sources_count=0
  local source_mode="none" source_provenance="none" source_root=""
  local meta_match="0" meta_reason="unknown"
  local allow_match="0" allow_reason="unknown"
  local kv="" k="" v=""

  [[ "$min_date" =~ ^[0-9]{8}$ ]] || min_date=20251222

  if steam_is_running; then
    steam_state="RUNNING"
    steam_detail="rebuild blocked while Steam is running"
  fi
  if [[ -d "$CTD" ]]; then
    ctd_state="READY"
    ctd_detail="compatibilitytools.d exists"
  fi

  SOURCES=()
  SUPPORTED_SOURCES=()
  if [[ -d "$CTD" ]]; then
    gather_sources >/dev/null 2>&1 || true
    gather_supported_sources_from_sources >/dev/null 2>&1 || true
    source_provenance_summary SOURCES source_mode source_provenance source_root
    total_sources_count="${#SOURCES[@]}"
    eligible_sources_count="${#SUPPORTED_SOURCES[@]}"
    if ((eligible_sources_count > 0)); then
      sources_state="READY"
      sources_detail="${eligible_sources_count} CachyOS source(s)"
    elif ((total_sources_count > 0)); then
      sources_state="OLD"
      sources_detail="0 eligible CachyOS source(s)"
    fi
  else
    sources_state="BLOCKED"
    sources_detail="cannot scan sources until compatibilitytools.d exists"
  fi

  # DW-Proton targets for default rebuild targets section
  local -a _st_dw_targets=()
  if [[ -d "$CTD" ]]; then
    gather_dwproton_display_targets _st_dw_targets
  fi

  # clones summary — count default targets (CachyOS + DW) present vs total
  local _st_def_present=0 _st_def_total=0
  if [[ -d "$CTD" ]]; then
    # CachyOS defaults — mirrors default rebuild date-selection path
    if ((${#SUPPORTED_SOURCES[@]} > 0)); then
      local -a __st_picked_copy=("${PICKED[@]}")
      local -a __st_supported_copy=("${SUPPORTED_SOURCES[@]}")
      local -a __st_sources_copy=("${SOURCES[@]}")
      local __st_build_date_copy="${BUILD_DATE:-}"
      SOURCES=("${SUPPORTED_SOURCES[@]}")
      PICKED=("${SUPPORTED_SOURCES[@]}")
      if major_selection_is_all_supported; then
        pick_latest_sources_by_major 2>/dev/null || true
      else
        local __st_newest_date=""
        __st_newest_date="$(detect_build_date_for_sources "${SUPPORTED_SOURCES[@]}" 2>/dev/null || true)"
        if [[ -n "$__st_newest_date" ]]; then
          BUILD_DATE="$__st_newest_date"
          pick_sources_for_date 2>/dev/null || true
        fi
      fi
      filter_picked_by_min_date >/dev/null 2>&1 || true
      filter_picked_by_patch_capability >/dev/null 2>&1 || true
      narrow_picked_to_preferred_cachyos_variant 2>/dev/null || true
      local _st_src=""
      for _st_src in "${PICKED[@]}"; do
        local _st_dstbase=""
        _st_dstbase="$(source_clone_basename "$_st_src" "$SUFFIX" 2>/dev/null || true)"
        [[ -n "$_st_dstbase" ]] || continue
        _st_def_total=$((_st_def_total + 1))
        [[ -d "${CTD}/${_st_dstbase}" ]] && _st_def_present=$((_st_def_present + 1))
      done
      PICKED=("${__st_picked_copy[@]}")
      SUPPORTED_SOURCES=("${__st_supported_copy[@]}")
      SOURCES=("${__st_sources_copy[@]}")
      BUILD_DATE="$__st_build_date_copy"
    fi
    # DW-Proton defaults
    if ((${#_st_dw_targets[@]} > 0)); then
      local -a _st_dw_def=()
      dwproton_pick_default_targets_by_major _st_dw_targets _st_dw_def
      local -a _st_dw_plan_names=() _st_dw_plan_actions=() _st_dw_plan_statuses=()
      local -a _st_dw_plan_reasons=() _st_dw_plan_sources=() _st_dw_plan_roots=() _st_dw_plan_classes=()
      dwproton_collect_rebuild_plans _st_dw_def _st_dw_plan_names _st_dw_plan_actions _st_dw_plan_statuses _st_dw_plan_reasons _st_dw_plan_sources _st_dw_plan_roots _st_dw_plan_classes
      local _st_dw_pi=0
      for _st_dw_pi in "${!_st_dw_plan_names[@]}"; do
        _st_def_total=$((_st_def_total + 1))
        local _st_dw_clone="${CTD}/${_st_dw_plan_names[$_st_dw_pi]}"
        [[ -d "$_st_dw_clone" ]] && _st_def_present=$((_st_def_present + 1))
      done
    fi
  fi
  if ((_st_def_total > 0)); then
    if ((_st_def_present == _st_def_total)); then
      clones_state="PRESENT"
      clones_detail="${_st_def_present}/${_st_def_total} default clone(s) present"
    elif ((_st_def_present > 0)); then
      clones_state="WARN"
      clones_detail="${_st_def_present}/${_st_def_total} default clone(s) present"
    else
      clones_state="MISSING"
      clones_detail="0/${_st_def_total} default clone(s) present"
    fi
  fi

  # DLL trust check via check --kv
  kv="$( (do_check --kv --ver "$FSR4_EFFECTIVE_LOCAL_DEFAULT_VER" --ctd "$CTD" --major "$MAJOR" --suffix "$SUFFIX") 2>/dev/null || true)"
  amd_dll_trust_snapshot_from_kv "$kv" meta_match meta_reason allow_match allow_reason

  # count local DLLs
  local _st_dll_count=0
  local _st_dll_def_ver="${FSR4_EFFECTIVE_LOCAL_DEFAULT_VER}"
  local _st_dll_cache_dir="${DLL_DST_DIR_DEFAULT}"
  local _st_ver=""
  for _st_ver in "${FSR4_LOCAL_ONLY_VERSIONS_RESOLVED[@]}"; do
    local _st_dll_path="${_st_dll_cache_dir}/${AMD_DLL_STEM}_v${_st_ver}.dll"
    [[ -f "$_st_dll_path" ]] && _st_dll_count=$((_st_dll_count + 1))
  done

  if [[ -f "$LOCALDLL" ]]; then
    if [[ "$meta_match" == "1" && "$allow_match" == "1" ]]; then
      dll_sum_state="READY"
      dll_sum_detail="default ${_st_dll_def_ver} trusted, ${_st_dll_count} local version(s)"
    else
      dll_sum_state="UNTRUSTED"
      local _dll_trust_detail=""
      amd_dll_trust_reason_summary "$meta_match" "$meta_reason" "$allow_match" "$allow_reason" primary ", " _dll_trust_detail
      dll_sum_detail="default ${_st_dll_def_ver} ${_dll_trust_detail}, ${_st_dll_count} local version(s)"
    fi
  elif ((_st_dll_count > 0)); then
    dll_sum_state="WARN"
    dll_sum_detail="${_st_dll_count} local version(s) present, default ${_st_dll_def_ver} missing"
  fi

  # ── Header ──────────────────────────────────────────────────────────────────
  printf '%s\n' "$(status_bold "gENVW Proton status")"
  msg ""

  # ── Summary ─────────────────────────────────────────────────────────────────
  printf '%s\n' "$(status_bold "Summary:")"
  printf '  %-10s %-9s %s\n' "ITEM" "STATE" "DETAIL"
  status_print_summary_row "Steam" "$steam_state" "$steam_detail"
  status_print_summary_row "CTD" "$ctd_state" "$ctd_detail"
  status_print_summary_row "Sources" "$sources_state" "$sources_detail"
  status_print_summary_row "DLLs" "$dll_sum_state" "$dll_sum_detail"
  status_print_summary_row "Clones" "$clones_state" "$clones_detail"
  msg ""

  # preserve Source Mode / Source Root so existing tests keep passing
  print_label_value_row "Source Mode:" "$(source_provenance_mode_label "$source_mode")"
  print_label_value_row "Source Root:" "${source_root:-"(none)"}"
  print_label_value_row "Major:" "$(major_selection_label)"
  msg ""

  # ── Default rebuild targets ──────────────────────────────────────────────────
  printf '%s\n' "$(status_bold "Default rebuild targets:")"
  printf '  %-14s  %-12s  %-52s  %s\n' "PROVIDER" "TARGET" "CLONE" "STATE"

  # CachyOS Proton defaults — mirrors the default rebuild date-selection path
  if [[ -d "$CTD" ]] && ((${#SUPPORTED_SOURCES[@]} > 0)); then
    local -a __stdr_picked_bak=("${PICKED[@]}")
    local -a __stdr_supported_bak=("${SUPPORTED_SOURCES[@]}")
    local __stdr_build_date_bak="${BUILD_DATE:-}"
    local __stdr_sources_bak=("${SOURCES[@]}")
    SOURCES=("${SUPPORTED_SOURCES[@]}")
    PICKED=("${SUPPORTED_SOURCES[@]}")
    # apply the same date selection used by default rebuild:
    # pick newest supported date, then filter/narrow
    if major_selection_is_all_supported; then
      pick_latest_sources_by_major 2>/dev/null || true
    else
      local __stdr_newest_date=""
      __stdr_newest_date="$(detect_build_date_for_sources "${SUPPORTED_SOURCES[@]}" 2>/dev/null || true)"
      if [[ -n "$__stdr_newest_date" ]]; then
        BUILD_DATE="$__stdr_newest_date"
        pick_sources_for_date 2>/dev/null || true
      fi
    fi
    filter_picked_by_min_date >/dev/null 2>&1 || true
    filter_picked_by_patch_capability >/dev/null 2>&1 || true
    narrow_picked_to_preferred_cachyos_variant 2>/dev/null || true
    local _stdr_src="" _stdr_dstbase="" _stdr_target_label="" _stdr_state=""
    for _stdr_src in "${PICKED[@]}"; do
      _stdr_dstbase="$(source_clone_basename "$_stdr_src" "$SUFFIX" 2>/dev/null || true)"
      [[ -n "$_stdr_dstbase" ]] || continue
      local _stdr_rec=""
      _stdr_rec="$(source_metadata_record "$_stdr_src" 2>/dev/null || true)"
      local _stdr_parsed="${_stdr_rec#*|}"
      local _stdr_major="${_stdr_parsed%%|*}"; _stdr_parsed="${_stdr_parsed#*|}"
      local _stdr_date="${_stdr_parsed%%|*}"; _stdr_parsed="${_stdr_parsed#*|}"
      local _stdr_runtime="${_stdr_parsed%%|*}"
      _stdr_target_label="${_stdr_major}-${_stdr_date} ${_stdr_runtime}"
      if [[ -d "${CTD}/${_stdr_dstbase}" ]]; then
        _stdr_state="PRESENT"
      else
        _stdr_state="MISSING"
      fi
      status_print_targets_row "CachyOS Proton" "$_stdr_target_label" "$_stdr_dstbase" "$_stdr_state"
    done
    PICKED=("${__stdr_picked_bak[@]}")
    SUPPORTED_SOURCES=("${__stdr_supported_bak[@]}")
    SOURCES=("${__stdr_sources_bak[@]}")
    BUILD_DATE="$__stdr_build_date_bak"
  elif [[ -d "$CTD" ]]; then
    status_print_targets_row "CachyOS Proton" "(none)" "no supported sources" "MISSING"
  else
    status_print_targets_row "CachyOS Proton" "(none)" "no CTD" "MISSING"
  fi

  # DW-Proton defaults
  if ((${#_st_dw_targets[@]} > 0)); then
    local -a _stdr_dw_def=()
    dwproton_pick_default_targets_by_major _st_dw_targets _stdr_dw_def
    local -a _stdr_dw_pnames=() _stdr_dw_pactions=() _stdr_dw_pstatuses=()
    local -a _stdr_dw_preasons=() _stdr_dw_psources=() _stdr_dw_proots=() _stdr_dw_pclasses=()
    dwproton_collect_rebuild_plans _stdr_dw_def _stdr_dw_pnames _stdr_dw_pactions _stdr_dw_pstatuses _stdr_dw_preasons _stdr_dw_psources _stdr_dw_proots _stdr_dw_pclasses
    local _stdr_dw_pi=0 _stdr_dw_ver="" _stdr_dw_clone="" _stdr_dw_state="" _stdr_dw_src_base=""
    for _stdr_dw_pi in "${!_stdr_dw_pnames[@]}"; do
      _stdr_dw_clone="${_stdr_dw_pnames[$_stdr_dw_pi]}"
      _stdr_dw_src_base="$(basename "${_stdr_dw_psources[$_stdr_dw_pi]}" 2>/dev/null || true)"
      _stdr_dw_ver="$(dwproton_folder_version "$_stdr_dw_src_base" 2>/dev/null || true)"
      [[ -n "$_stdr_dw_ver" ]] || _stdr_dw_ver="$_stdr_dw_clone"
      if [[ -d "${CTD}/${_stdr_dw_clone}" ]]; then
        _stdr_dw_state="PRESENT"
      else
        _stdr_dw_state="MISSING"
      fi
      status_print_targets_row "DW-Proton" "$_stdr_dw_ver" "$_stdr_dw_clone" "$_stdr_dw_state"
    done
  else
    if [[ -d "$CTD" ]]; then
      status_print_targets_row "DW-Proton" "(none)" "no DW-Proton sources" "MISSING"
    else
      status_print_targets_row "DW-Proton" "(none)" "no CTD" "MISSING"
    fi
  fi
  msg ""

  # ── Local FSR4 DLLs ─────────────────────────────────────────────────────────
  printf '%s\n' "$(status_bold "Local FSR4 DLLs:")"
  print_label_value_row "Cache:" "$(status_dim "$_st_dll_cache_dir")"
  print_label_value_row "Default:" "$_st_dll_def_ver"
  msg ""

  local _stf_found=0
  printf '  %-7s  %-7s  %-9s  %s\n' "VERSION" "DEFAULT" "TRUSTED" "SIZE"
  for _st_ver in "${FSR4_LOCAL_ONLY_VERSIONS_RESOLVED[@]}"; do
    local _stf_dll="${_st_dll_cache_dir}/${AMD_DLL_STEM}_v${_st_ver}.dll"
    [[ -f "$_stf_dll" ]] || continue
    _stf_found=1
    local _stf_sz=0
    _stf_sz="$(stat -c '%s' "$_stf_dll" 2>/dev/null || echo 0)"
    local _stf_mib=""
    _stf_mib="$(human_mib_from_bytes "$_stf_sz")"
    local _stf_is_def="no"
    [[ "$_st_ver" == "$_st_dll_def_ver" ]] && _stf_is_def="yes"
    local _stf_trusted="no"
    if amd_dll_is_trusted_for_ver "$_st_ver" "$_st_dll_cache_dir" 2>/dev/null; then
      _stf_trusted="yes"
    fi
    status_print_dll_row "$_st_ver" "$_stf_is_def" "$_stf_trusted" "$_stf_mib"
  done
  if ((_stf_found == 0)); then
    msg "  No local FSR4 DLLs found."
  fi
  # emit provenance integrity note (e.g. "Provenance integrity: meta missing") for
  # existing tests that check this string; output goes to stdout via msg path
  amd_dll_provenance_integrity status "$(dirname -- "$LOCALDLL")" || true
  msg ""

  # ── Providers ───────────────────────────────────────────────────────────────
  printf '%s\n' "$(status_bold "Providers:")"
  printf '  %-14s  %-15s  %-17s  %s\n' "PROVIDER" "DEFAULT TARGETS" "AVAILABLE TARGETS" "FEATURES"

  # CachyOS Proton provider row
  local _stp_cachy_def=0 _stp_cachy_avail=0 _stp_cachy_feat="FSR4"
  if [[ -d "$CTD" ]] && ((${#SUPPORTED_SOURCES[@]} > 0)); then
    local -a __stp_picked_bak=("${PICKED[@]}")
    local -a __stp_supported_bak=("${SUPPORTED_SOURCES[@]}")
    local -a __stp_sources_bak=("${SOURCES[@]}")
    local __stp_build_date_bak="${BUILD_DATE:-}"
    SOURCES=("${SUPPORTED_SOURCES[@]}")
    PICKED=("${SUPPORTED_SOURCES[@]}")
    if major_selection_is_all_supported; then
      pick_latest_sources_by_major 2>/dev/null || true
    else
      local __stp_newest_date=""
      __stp_newest_date="$(detect_build_date_for_sources "${SUPPORTED_SOURCES[@]}" 2>/dev/null || true)"
      if [[ -n "$__stp_newest_date" ]]; then
        BUILD_DATE="$__stp_newest_date"
        pick_sources_for_date 2>/dev/null || true
      fi
    fi
    filter_picked_by_min_date >/dev/null 2>&1 || true
    filter_picked_by_patch_capability >/dev/null 2>&1 || true
    _stp_cachy_avail="${#PICKED[@]}"
    narrow_picked_to_preferred_cachyos_variant 2>/dev/null || true
    _stp_cachy_def="${#PICKED[@]}"
    if ((${#PICKED[@]} > 0)); then
      _stp_cachy_feat="$(list_clone_features_for_human "$(basename "${PICKED[0]}")")"
      _stp_cachy_feat="$(compact_feature_labels_for_human "$_stp_cachy_feat")"
    fi
    PICKED=("${__stp_picked_bak[@]}")
    SUPPORTED_SOURCES=("${__stp_supported_bak[@]}")
    SOURCES=("${__stp_sources_bak[@]}")
    BUILD_DATE="$__stp_build_date_bak"
  fi
  _stp_cachy_feat="$(compact_feature_labels_for_human "$_stp_cachy_feat")"
  status_print_provider_row "CachyOS Proton" "$_stp_cachy_def" "$_stp_cachy_avail" "$_stp_cachy_feat"

  # DW-Proton provider row
  local _stp_dw_def=0 _stp_dw_avail=0 _stp_dw_feat="FSR4"
  if ((${#_st_dw_targets[@]} > 0)); then
    local -a _stp_dw_def_arr=()
    _stp_dw_avail="${#_st_dw_targets[@]}"
    dwproton_pick_default_targets_by_major _st_dw_targets _stp_dw_def_arr
    _stp_dw_def="${#_stp_dw_def_arr[@]}"
    if ((${#_stp_dw_def_arr[@]} > 0)); then
      _stp_dw_feat="$(list_clone_features_for_human "$(basename "${_stp_dw_def_arr[0]}")")"
      _stp_dw_feat="$(compact_feature_labels_for_human "$_stp_dw_feat")"
    fi
  fi
  _stp_dw_feat="$(compact_feature_labels_for_human "$_stp_dw_feat")"
  status_print_provider_row "DW-Proton" "$_stp_dw_def" "$_stp_dw_avail" "$_stp_dw_feat"

  msg ""
  msg "  full inventory: $(cmd_proton) list-clones"

  # ── Action (only when something needs attention) ─────────────────────────────
  local _sta_needed=0
  [[ "$ctd_state" == "MISSING" ]] && _sta_needed=1
  [[ "$dll_sum_state" == "MISSING" || "$dll_sum_state" == "UNTRUSTED" ]] && _sta_needed=1
  [[ "$clones_state" == "MISSING" ]] && _sta_needed=1
  if ((_sta_needed == 1)); then
    msg ""
    printf '%s\n' "$(status_bold "Action:")"
    if [[ "$ctd_state" == "MISSING" ]]; then
      if [[ -d "$CTD" ]]; then
        warn "No gENVW Proton tools found in: $CTD"
        msg "Build via: $(cmd_proton) rebuild"
      else
        warn "compatibilitytools.d not found: $CTD"
        msg "  Pass it explicitly with --ctd /path/to/Steam/compatibilitytools.d."
      fi
    fi
    if [[ "$dll_sum_state" == "MISSING" ]]; then
      local _sta_dcmd
      _sta_dcmd="$(cmd_dll)"
      msg "  Install FSR4 ${_st_dll_def_ver}:"
      msg "    $_sta_dcmd install --url \"${AMD_DRIVER_URL}\" --dst-dir \"${DLL_DST_DIR_DEFAULT}\""
    fi
    if [[ "$clones_state" == "MISSING" && "$ctd_state" != "MISSING" ]]; then
      msg "  Build tools:"
      msg "    $(cmd_proton) rebuild"
    fi
  fi
}

# do_diagnose
# compact read-only summary for the current local DLL/tool state.
# built from check --kv so it stays aligned with status/prep/rebuild logic.
do_diagnose() {
  local diag_appid="" diag_pfx_dll=""
  local diag_env_ver="" diag_env_ver_used=0
  local -a __diag_args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --appid)
        require_flag_value --appid "${2-}"
        diag_appid="$2"
        shift 2
        ;;
      --pfx-dll)
        require_flag_value --pfx-dll "${2-}"
        diag_pfx_dll="$2"
        shift 2
        ;;
      *)
        __diag_args+=("$1")
        shift
        ;;
    esac
  done
  if [[ -n "$diag_appid" && -n "$diag_pfx_dll" ]]; then
    die "diagnose: choose one of --appid or --pfx-dll (not both)"
  fi
  if [[ -n "$diag_appid" && ! "$diag_appid" =~ ^[0-9]+$ ]]; then
    die "diagnose: --appid must be numeric: $diag_appid"
  fi
  parse_kv_flags --ctd-optional "${__diag_args[@]}"
  if [[ "${GENVW_KV_HELP:-0}" == "1" ]]; then
    return 0
  fi
  if ((FSR4_VER_EXPLICIT == 0 && LOCALDLL_EXPLICIT == 0)); then
    if [[ -n "${FSR4:-}" ]] && fsr4_ver_syntax_ok "${FSR4}"; then
      diag_env_ver="${FSR4}"
      diag_env_ver_used=1
      FSR4_VER="${diag_env_ver}"
      FSR4_VER_EXPLICIT=1
      amd_set_cache_names_for_ver "${FSR4_VER}"
      LOCALDLL="${DLL_DST_DIR_DEFAULT}/${AMD_DLL_NAME}"
    fi
  fi
  fsr4_apply_effective_local_default_if_implicit "${DLL_DST_DIR_DEFAULT}"

  local want="" target_source="preferred_default"
  if ((diag_env_ver_used == 1)); then
    want="${diag_env_ver}"
    target_source="env_fsr4"
  elif ((FSR4_VER_EXPLICIT == 1)); then
    want="${FSR4_VER}"
    target_source="explicit_ver"
  else
    want="${FSR4_EFFECTIVE_LOCAL_DEFAULT_VER:-$FSR4_LOCAL_DEFAULT_VER}"
    target_source="${FSR4_EFFECTIVE_LOCAL_DEFAULT_SOURCE:-preferred_default}"
  fi

  local kv=""
  if ((diag_env_ver_used == 1)); then
    kv="$(do_check --kv --ver "${diag_env_ver}" "${__diag_args[@]}")" || return $?
  else
    kv="$(do_check --kv "${__diag_args[@]}")" || return $?
  fi

  local kv_ctd="" kv_major="" kv_suffix="" kv_localdll=""
  local dll_present="" meta_match="" meta_reason="" allow_match="" allow_reason=""
  local src_count="" tools_found="" build_date="" expected_for_date="" missing_for_date="" complete_for_date=""
  local source_mode="" source_root=""
  kv_ctd="$(kv_get_one_strict "$kv" "CTD")"
  kv_major="$(kv_get_one_strict "$kv" "MAJOR")"
  kv_suffix="$(kv_get_one_strict "$kv" "SUFFIX")"
  kv_localdll="$(kv_get_one_strict "$kv" "LOCALDLL")"
  dll_present="$(kv_get_one_strict "$kv" "DLL_PRESENT")"
  meta_match="$(kv_get_one_strict "$kv" "META_MATCH")"
  meta_reason="$(kv_get_one_strict "$kv" "META_MATCH_REASON")"
  allow_match="$(kv_get_one_strict "$kv" "ALLOWLIST_MATCH")"
  allow_reason="$(kv_get_one_strict "$kv" "ALLOWLIST_MATCH_REASON")"
  src_count="$(kv_get_one_strict "$kv" "PROTON_SOURCES_COUNT")"
  tools_found="$(kv_get_one_strict "$kv" "TOOLS_FOUND")"
  source_mode="$(kv_get_one_strict "$kv" "PROTON_SOURCE_MODE")"
  source_root="$(kv_get_one_strict "$kv" "PROTON_SOURCE_ROOT")"
  build_date="$(kv_get_one_strict "$kv" "PROTON_BUILD_DATE")"
  expected_for_date="$(kv_get_one_strict "$kv" "PROTON_EXPECTED_CLONES_FOR_DATE")"
  missing_for_date="$(kv_get_one_strict "$kv" "PROTON_MISSING_CLONES_FOR_DATE")"
  complete_for_date="$(kv_get_one_strict "$kv" "PROTON_CLONES_COMPLETE_FOR_DATE")"

  local target_local=0
  fsr4_ver_is_local_only_supported "$want" && target_local=1

  local dll_state="READY" dll_detail="trusted"
  local tools_state="READY" tools_detail=""
  local prefix_state="" prefix_detail="" prefix_path=""
  local steam_state="OK" steam_detail="not running"
  local target_detail="FSR4 ${want} ($(prep_target_source_label "$target_source"))"
  local needs_dll_install=0 needs_dll_verify=0 needs_rebuild=0 needs_supported_source=0
  local needs_prefix_sync=0 needs_prefix_launch_once=0
  local steam_running_now=0
  local show_prefix=0
  local show_why=0
  local -a missing_clones=()

  if ((target_local == 0)); then
    dll_state="N/A"
    dll_detail="remote/system version"
  elif [[ "$dll_present" != "1" ]]; then
    dll_state="MISSING"
    dll_detail="local FSR4 ${want} DLL not installed"
    needs_dll_install=1
  elif [[ "$meta_match" == "1" && "$allow_match" == "1" ]]; then
    dll_state="READY"
    dll_detail="trusted"
  else
    dll_state="BLOCKED"
    amd_dll_trust_reason_summary "$meta_match" "$meta_reason" "$allow_match" "$allow_reason" joined ", " dll_detail
    needs_dll_verify=1
  fi

  if [[ "$src_count" == "0" ]]; then
    tools_state="BLOCKED"
    if [[ "$tools_found" == "0" ]]; then
      tools_detail="no supported sources found"
    else
      tools_detail="${tools_found} clone(s) installed, no supported sources found"
    fi
    needs_supported_source=1
  elif [[ "$complete_for_date" == "1" ]]; then
    tools_state="READY"
    if [[ -n "$build_date" && "$expected_for_date" != "0" ]]; then
      tools_detail="date ${build_date}, ${expected_for_date}/${expected_for_date} clones"
    else
      tools_detail="${tools_found} clone(s)"
    fi
  elif [[ -n "$build_date" && "$expected_for_date" != "0" ]]; then
    needs_rebuild=1
    if [[ "$tools_found" == "0" ]]; then
      tools_state="MISSING"
      tools_detail="clone set missing for date ${build_date}"
    else
      tools_state="PARTIAL"
      tools_detail="${missing_for_date}/${expected_for_date} clones missing for date ${build_date}"
    fi
  elif [[ "$tools_found" == "0" ]]; then
    tools_state="MISSING"
    tools_detail="no gENVW clones found"
    needs_rebuild=1
  else
    tools_state="READY"
    tools_detail="${tools_found} clone(s)"
  fi

  if steam_is_running; then
    steam_running_now=1
    if ((needs_rebuild == 1)); then
      steam_state="BLOCKED"
      steam_detail="close Steam before rebuild"
    else
      steam_state="RUNNING"
      steam_detail="rebuild blocked while Steam is running"
    fi
  fi

  if [[ -n "$diag_appid" || -n "$diag_pfx_dll" ]]; then
    show_prefix=1
    if ((target_local == 0)); then
      prefix_state="N/A"
      prefix_detail="remote/system version"
    elif [[ "$dll_present" != "1" ]]; then
      prefix_state="BLOCKED"
      prefix_detail="cache DLL missing"
    elif ! have sha256sum; then
      prefix_state="UNKNOWN"
      prefix_detail="sha256sum not available"
    else
      prefix_path="$diag_pfx_dll"
      if [[ -z "$prefix_path" ]]; then
        prefix_path="$(amd_steam_find_prefix_dll_for_appid "$diag_appid" || true)"
      fi
      if [[ -z "$prefix_path" || ! -f "$prefix_path" ]]; then
        prefix_state="MISSING"
        if [[ -n "$diag_appid" ]]; then
          prefix_detail="prefix DLL not found for appid ${diag_appid}"
          needs_prefix_launch_once=1
        else
          prefix_detail="prefix DLL not found"
        fi
      else
        local pfx_sha="" cache_sha=""
        pfx_sha="$(sha256sum "$prefix_path" 2>/dev/null | awk '{print $1}' || true)"
        cache_sha="$(sha256sum "$kv_localdll" 2>/dev/null | awk '{print $1}' || true)"
        if [[ -n "$pfx_sha" && -n "$cache_sha" && "$pfx_sha" == "$cache_sha" ]]; then
          prefix_state="READY"
          prefix_detail="matches local cache"
        else
          prefix_state="MISMATCH"
          prefix_detail="differs from local cache"
          needs_prefix_sync=1
        fi
      fi
    fi
  fi

  if [[ -n "$kv_ctd" && -d "$kv_ctd" && -n "$build_date" && "$build_date" =~ ^[0-9]{8}$ && "$expected_for_date" != "0" ]]; then
    local __saved_ctd="${CTD:-}" __saved_major="${MAJOR:-}" __saved_suffix="${SUFFIX:-}"
    local src="" base="" clone_dir=""
    CTD="$kv_ctd"
    MAJOR="$kv_major"
    SUFFIX="$kv_suffix"
    SOURCES=()
    SUPPORTED_SOURCES=()
    gather_sources >/dev/null 2>&1 || true
    gather_supported_sources_from_sources >/dev/null 2>&1 || true
    for src in "${SUPPORTED_SOURCES[@]}"; do
      base="$(source_effective_base "$src")"
      [[ "$(source_build_date "$src" 2>/dev/null || true)" == "$build_date" ]] || continue
      clone_dir="${CTD}/$(source_clone_basename "$src" "$SUFFIX")"
      [[ -d "$clone_dir" ]] || missing_clones+=("$(source_clone_basename "$src" "$SUFFIX")")
    done
    CTD="$__saved_ctd"
    MAJOR="$__saved_major"
    SUFFIX="$__saved_suffix"
  fi

  if [[ "$dll_state" == "BLOCKED" ]]; then
    show_why=1
  fi
  if [[ "$tools_state" == "PARTIAL" || "$tools_state" == "MISSING" ]] && ((${#missing_clones[@]} > 0)); then
    show_why=1
  fi
  if [[ "$tools_state" == "BLOCKED" && "$src_count" == "0" ]]; then
    show_why=1
  fi
  if [[ "$prefix_state" == "MISSING" || "$prefix_state" == "MISMATCH" || "$prefix_state" == "UNKNOWN" ]]; then
    show_why=1
  fi
  if [[ "$prefix_state" == "BLOCKED" && -n "${prefix_path:-${diag_pfx_dll:-}}" ]]; then
    show_why=1
  fi

  msg "gENVW Proton diagnose"
  msg ""
  msg "Paths:"
  print_label_value_row "Source Mode:" "$(source_provenance_mode_label "$source_mode")"
  print_label_value_row "Source Root:" "${source_root:-"(none)"}"
  msg ""
  printf '  %-7s %-9s %s\n' "ITEM" "STATE" "DETAIL"
  printf '  %-7s %-9s %s\n' "TARGET" "SELECTED" "$target_detail"
  prep_print_status_row "DLL" "$dll_state" "$dll_detail"
  prep_print_status_row "TOOLS" "$tools_state" "$tools_detail"
  if ((show_prefix == 1)); then
    prep_print_status_row "PREFIX" "$prefix_state" "$prefix_detail"
  fi
  prep_print_status_row "STEAM" "$steam_state" "$steam_detail"

  if ((show_why == 1)); then
    msg ""
    msg "Why:"
    if [[ "$dll_state" == "BLOCKED" ]]; then
      msg "  DLL:"
      msg "    META_MATCH=${meta_match} (${meta_reason})"
      msg "    ALLOWLIST_MATCH=${allow_match} (${allow_reason})"
    fi
    if [[ "$tools_state" == "PARTIAL" || "$tools_state" == "MISSING" ]] && ((${#missing_clones[@]} > 0)); then
      msg "  TOOLS:"
      msg "    missing clone(s):"
      printf '      %s\n' "${missing_clones[@]}"
    elif [[ "$tools_state" == "BLOCKED" && "$src_count" == "0" ]]; then
      msg "  TOOLS:"
      msg "    no supported Proton-CachyOS sources found under:"
      msg "    ${kv_ctd}"
      msg "    minimum supported date: $(min_supported_date_genvw)"
    fi
    if [[ "$prefix_state" == "MISSING" ]]; then
      msg "  PREFIX:"
      if [[ -n "$diag_appid" ]]; then
        msg "    appid: ${diag_appid}"
        msg "    looked for: steamapps/compatdata/${diag_appid}/pfx/.../system32/${AMD_DLL_SRC_NAME:-amdxcffx64.dll}"
      else
        msg "    path: ${diag_pfx_dll}"
      fi
    elif [[ "$prefix_state" == "MISMATCH" || "$prefix_state" == "UNKNOWN" ]]; then
      msg "  PREFIX:"
      msg "    path: ${prefix_path:-${diag_pfx_dll:-"(not resolved)"}}"
    elif [[ "$prefix_state" == "BLOCKED" && -n "${prefix_path:-${diag_pfx_dll:-}}" ]]; then
      msg "  PREFIX:"
      msg "    path: ${prefix_path:-${diag_pfx_dll}}"
    fi
  fi

  msg ""
  msg "Next:"
  local step_no=1
  local rebuild_tail=""
  rebuild_tail="$(rebuild_source_selection_tail)"
  if ((steam_running_now == 1 && needs_rebuild == 1)); then
    msg "  ${step_no}. Close Steam"
    step_no=$((step_no + 1))
  fi
  if ((needs_supported_source == 1)); then
    msg "  ${step_no}. Install or update a supported Proton-CachyOS source"
    step_no=$((step_no + 1))
  fi
  if ((needs_dll_install == 1)); then
    diagnose_print_missing_dll_next_steps "${want}" step_no
  elif ((needs_dll_verify == 1)); then
    msg "  ${step_no}. Inspect:"
    msg "     $(cmd_dll) verify --ver ${want}"
    step_no=$((step_no + 1))
  fi
  if ((needs_rebuild == 1)); then
    msg "  ${step_no}. Run:"
    if [[ -n "$build_date" ]]; then
      msg "     $(cmd_proton) rebuild${rebuild_tail} --date ${build_date}"
    else
      msg "     $(cmd_proton) rebuild${rebuild_tail}"
    fi
    step_no=$((step_no + 1))
  fi
  if ((needs_prefix_launch_once == 1)); then
    msg "  ${step_no}. Launch the game once to create its prefix"
    step_no=$((step_no + 1))
  elif ((needs_prefix_sync == 1)); then
    msg "  ${step_no}. Sync the prefix DLL:"
    if [[ -n "$diag_appid" ]]; then
      msg "     $(cmd_dll) prefix-sync --appid ${diag_appid} --ver ${want}"
    else
      msg "     $(cmd_dll) prefix-sync --pfx-dll ${diag_pfx_dll} --ver ${want}"
    fi
    step_no=$((step_no + 1))
  fi
  if ((needs_supported_source == 0 && needs_dll_install == 0 && needs_dll_verify == 0 && needs_rebuild == 0)); then
    msg "  ${step_no}. Launch with:"
    msg "     FSR4=${want} genvw %command%"
  fi
}

selftest_print_live_summary() {
  local kv=""
  kv="$(do_check --kv "$@" 2>/dev/null)" || die "selftest: could not collect live status"

  local ctd_exists="" tools_found="" dll_present="" meta_match="" allow_match="" sources_count=""
  ctd_exists="$(kv_get_one_strict "$kv" "CTD_EXISTS")"
  tools_found="$(kv_get_one_strict "$kv" "TOOLS_FOUND")"
  dll_present="$(kv_get_one_strict "$kv" "DLL_PRESENT")"
  meta_match="$(kv_get_one_strict "$kv" "META_MATCH")"
  allow_match="$(kv_get_one_strict "$kv" "ALLOWLIST_MATCH")"
  sources_count="$(kv_get_one_strict "$kv" "PROTON_SOURCES_COUNT")"

  local paths_state="BLOCKED" paths_detail="compatibilitytools.d missing"
  local dll_state="MISSING" dll_detail="local cache missing"
  local tools_state="MISSING" tools_detail="no gENVW tools found"
  local steam_state="OK" steam_detail="not running"

  if [[ "$ctd_exists" == "1" ]]; then
    paths_state="READY"
    paths_detail="compatibilitytools.d detected"
  fi
  if [[ "$sources_count" =~ ^[0-9]+$ && "$sources_count" -gt 0 ]]; then
    paths_detail="${paths_detail}; ${sources_count} source folder(s)"
  fi

  if [[ "$dll_present" == "1" ]]; then
    if [[ "$meta_match" == "1" && "$allow_match" == "1" ]]; then
      dll_state="READY"
      dll_detail="trusted local cache present"
    else
      dll_state="BLOCKED"
      dll_detail="local cache present but not fully trusted"
    fi
  fi

  if [[ "$tools_found" =~ ^[0-9]+$ && "$tools_found" -gt 0 ]]; then
    tools_state="READY"
    tools_detail="${tools_found} tool(s) found"
  fi

  if steam_is_running; then
    steam_state="WARN"
    steam_detail="running; rebuild would be blocked"
  fi

  prep_print_status_row "PATHS" "$paths_state" "$paths_detail"
  prep_print_status_row "DLL" "$dll_state" "$dll_detail"
  prep_print_status_row "TOOLS" "$tools_state" "$tools_detail"
  prep_print_status_row "STEAM" "$steam_state" "$steam_detail"
}

selftest_run_dll_sandbox() {
  local exe="${1:-}"
  local -n out_state_ref="$2"
  local -n out_detail_ref="$3"
  local -n out_input_ref="$4"
  local -n out_dll_ref="$5"
  local -n out_inner_ref="$6"

  local explicit_exe=0
  local -a inner_args=()
  local -a inner_env=()
  local selftest_install_ver=""
  out_state_ref="FAIL"
  out_detail_ref="temp-home DLL install failed"
  out_input_ref=""
  out_dll_ref=""
  out_inner_ref=""

  if [[ -n "$exe" ]]; then
    explicit_exe=1
    if [[ ! -f "$exe" ]]; then
      err "selftest dll: missing driver exe: $exe"
      return 1
    fi
  else
    inner_args=(dll --url "$AMD_DRIVER_URL")
    selftest_install_ver="${GENVW_DEV_DLL_INSTALL_VER:-$GENVW_SELFTEST_DEFAULT_AMD_URL_INSTALL_VER}"
  fi

  local -a req=(
    bash 7z find mkdir rm cp ln basename dirname date readlink stat mktemp mv
    sort head cut ls
  )
  if ((explicit_exe == 0)); then
    req+=(wget)
  fi

  local -a opt=(
    awk grep sed tr stat sha256sum
    flock strings file cabextract exiftool
  )

  local c
  for c in "${req[@]}"; do
    if ! have "$c"; then
      err "selftest missing required tool on this system: $c"
      return 1
    fi
  done
  if ((explicit_exe == 1)); then
    local sig=""
    IFS= read -r -n2 sig <"$exe" || true
    if [[ "$sig" != "MZ" ]]; then
      err "selftest dll: file does not look like a Windows EXE (missing 'MZ' header): $exe"
      return 1
    fi
    if ! 7z t "$exe" >/dev/null 2>&1; then
      err "selftest dll: archive test failed: $exe"
      return 1
    fi
    inner_args=(dll --exe "$exe")
  fi

  local REAL_HOME="$HOME"
  T="$(mktemp -d)"
  B="$(mktemp -d)"
  local __old_selftest_trap_exit="" __old_selftest_trap_int="" __old_selftest_trap_term=""
  __old_selftest_trap_exit="$(trap -p EXIT 2>/dev/null || true)"
  __old_selftest_trap_int="$(trap -p INT 2>/dev/null || true)"
  __old_selftest_trap_term="$(trap -p TERM 2>/dev/null || true)"
  trap 'rm -rf -- "${T:-}" "${B:-}" 2>/dev/null || true' EXIT
  trap 'trap - EXIT 2>/dev/null || true; rm -rf -- "${T:-}" "${B:-}" 2>/dev/null || true; exit 130' INT
  trap 'trap - EXIT 2>/dev/null || true; rm -rf -- "${T:-}" "${B:-}" 2>/dev/null || true; exit 143' TERM

  local allow_dir_src="$REAL_HOME/.local/share/genvw/allowlists"
  local allow_dir_dst="$T/.local/share/genvw/allowlists"
  copy_allowlists_into_dir "$allow_dir_src" "$allow_dir_dst"

  for c in "${req[@]}"; do
    ln -sf -- "$(command -v "$c")" "$B/$c"
  done
  for c in "${opt[@]}"; do
    have "$c" || continue
    ln -sf -- "$(command -v "$c")" "$B/$c"
  done

  if ((explicit_exe == 0)); then
    local cached_real_exe="" cached_temp_exe="" cached_sig=""
    cached_real_exe="$(amd_driver_cached_exe_path_for_url "$AMD_DRIVER_URL" || true)"
    if [[ -n "$cached_real_exe" && -f "$cached_real_exe" ]]; then
      IFS= read -r -n2 cached_sig <"$cached_real_exe" || true
      if [[ "$cached_sig" == "MZ" ]] && 7z t "$cached_real_exe" >/dev/null 2>&1; then
        cached_temp_exe="$(amd_driver_cached_exe_path_for_url "$AMD_DRIVER_URL" "$T/.cache/genvw/amd/driver-dl" || true)"
        if [[ -n "$cached_temp_exe" ]]; then
          mkdir -p -- "$(dirname "$cached_temp_exe")"
          ln -sf -- "$cached_real_exe" "$cached_temp_exe"
        fi
      fi
    fi
  fi

  local rc=0
  inner_env=(
    HOME="$T"
    PATH="$B"
    XDG_CACHE_HOME="$T/.cache"
    GENVW_CACHE_DIR="$T/.cache/genvw"
    GENVW_IN_PREP=1
  )
  if [[ -n "$selftest_install_ver" ]]; then
    inner_env+=(GENVW_DEV_DLL_INSTALL_VER="$selftest_install_ver")
  fi
  if [[ "${GENVW_SELFTEST_TRACE:-0}" == "1" ]]; then
    env "${inner_env[@]}" "$B/bash" --noprofile --norc -x "$0" "${inner_args[@]}"
    rc=$?
  else
    out_inner_ref="$(env "${inner_env[@]}" "$B/bash" --noprofile --norc "$0" "${inner_args[@]}" 2>&1)"
    rc=$?
  fi

  if ((rc != 0)); then
    err "selftest dll failed: inner dll command exited $rc"
    [[ -n "$out_inner_ref" ]] && printf '%s\n' "$out_inner_ref"
    if ((explicit_exe == 1)); then
      err "Tip: re-run with tracing: GENVW_SELFTEST_TRACE=1 genvw proton selftest dll \"$exe\""
    else
      err "Tip: re-run with tracing: GENVW_SELFTEST_TRACE=1 genvw proton selftest dll"
    fi
    rm -rf -- "${T:-}" "${B:-}" 2>/dev/null || true
    restore_one_trap "$__old_selftest_trap_exit" EXIT
    restore_one_trap "$__old_selftest_trap_int" INT
    restore_one_trap "$__old_selftest_trap_term" TERM
    return "$rc"
  fi

  local created_root="$T/.cache/protonfixes/upscalers/genvw"
  local -a created_dlls=()
  local created_path=""
  while IFS= read -r created_path; do
    [[ -n "$created_path" ]] && created_dlls+=("$created_path")
  done < <(find "$created_root" -maxdepth 1 -type f -name 'amdxcffx64_v*.dll' | sort)

  if ((${#created_dlls[@]} != 1)); then
    die "selftest failed: expected exactly one installed DLL under $created_root (found ${#created_dlls[@]})"
  fi

  local dst="${created_dlls[0]}"
  out_state_ref="READY"
  out_detail_ref="temp-home DLL install passed"
  if ((explicit_exe == 1)); then
    out_input_ref="$exe"
  else
    out_input_ref="$AMD_DRIVER_URL"
  fi
  out_dll_ref="${dst##*/}"

  rm -rf -- "${T:-}" "${B:-}" 2>/dev/null || true
  restore_one_trap "$__old_selftest_trap_exit" EXIT
  restore_one_trap "$__old_selftest_trap_int" INT
  restore_one_trap "$__old_selftest_trap_term" TERM
  return 0
}

# do_selftest
# quick smoke checks so dumb breakage shows up early
# die, err, have, hint, msg, ok, parse_kv_flags, preflight_proton
# steam_print_detected, warn
# main

do_selftest() {
  # first arg that looks like a mode wins (all|paths|steam|dll).
  # everything else gets passed through:
  # - paths/steam -> parse_kv_flags
  # - dll -> args after "dll"

  local mode="all"
  local -a selftest_kv_args=()
  local -a selftest_dll_args=()
  local -a selftest_args=("$@")
  local i=0 a=""

  while [[ $i -lt ${#selftest_args[@]} ]]; do
    a="${selftest_args[i]}"

    case "$a" in
      all | paths | steam | dll)
        mode="$a"
        i=$((i + 1))
        if [[ "$mode" == "dll" ]]; then
          while [[ $i -lt ${#selftest_args[@]} ]]; do
            selftest_dll_args+=("${selftest_args[i]}")
            i=$((i + 1))
          done
        elif [[ "$mode" == "all" ]]; then
          # for "selftest all", route known kv flags to paths, and positional args to dll.
          # this allows: selftest all /path/to/driver.exe
          local expect_kv_value=0 t=""
          while [[ $i -lt ${#selftest_args[@]} ]]; do
            t="${selftest_args[i]}"
            if ((expect_kv_value == 1)); then
              selftest_kv_args+=("$t")
              expect_kv_value=0
              i=$((i + 1))
              continue
            fi
            case "$t" in
              --dry-run)
                die "selftest does not support --dry-run"
                ;;
              --ctd | --major | --suffix | --tag | --localdll | --date | --ver)
                selftest_kv_args+=("$t")
                expect_kv_value=1
                ;;
              --allow-steam | --old | --prefer-system-sources | --system-sources-only | -h | --help | --ctd-optional | --no-ctd-required | -*)
                selftest_kv_args+=("$t")
                ;;
              *)
                selftest_dll_args+=("$t")
                ;;
            esac
            i=$((i + 1))
          done
        else
          while [[ $i -lt ${#selftest_args[@]} ]]; do
            if [[ "${selftest_args[i]}" == "--dry-run" ]]; then
              die "selftest does not support --dry-run"
            fi
            selftest_kv_args+=("${selftest_args[i]}")
            i=$((i + 1))
          done
        fi
        break
        ;;

      # known kv flags (kept grouped so "flags before mode" stays predictable)
      --allow-steam | --old | --prefer-system-sources | --system-sources-only | -h | --help | --ctd-optional | --no-ctd-required)
        selftest_kv_args+=("$a")
        ;;

      --dry-run)
        die "selftest does not support --dry-run"
        ;;

      --ctd | --major | --suffix | --tag | --localdll | --date | --ver)
        selftest_kv_args+=("$a")
        if [[ $((i + 1)) -lt ${#selftest_args[@]} ]]; then
          i=$((i + 1))
          selftest_kv_args+=("${selftest_args[i]}")
        fi
        ;;

      -*)
        # unknown flag: keep it so parse_kv_flags can reject it normally.
        selftest_kv_args+=("$a")
        ;;

      *)
        # first non-flag token becomes the mode (even if invalid).
        # everything after that is forwarded as mode args (kv-style).
        mode="$a"
        i=$((i + 1))
        while [[ $i -lt ${#selftest_args[@]} ]]; do
          selftest_kv_args+=("${selftest_args[i]}")
          i=$((i + 1))
        done
        break
        ;;
    esac

    i=$((i + 1))
  done

  msg "${I_DEBUG} genvw_proton selftest"
  local _pcmd
  _pcmd="$(cmd_proton)"

  case "$mode" in
    all)
      local sandbox_state="" sandbox_detail="" sandbox_input="" sandbox_dll="" sandbox_inner=""
      selftest_run_dll_sandbox "${selftest_dll_args[0]:-}" sandbox_state sandbox_detail sandbox_input sandbox_dll sandbox_inner || return $?
      msg ""
      msg "Summary:"
      printf '  %-7s %-9s %s\n' "ITEM" "STATE" "DETAIL"
      selftest_print_live_summary "${selftest_kv_args[@]}"
      prep_print_status_row "SANDBOX" "$sandbox_state" "$sandbox_detail"
      msg ""
      msg "Next:"
      msg "  $(cmd_proton) status"
      msg "  $(cmd_dll) verify"
      ;;
    paths | steam)
      msg ""
      msg "Summary:"
      printf '  %-7s %-9s %s\n' "ITEM" "STATE" "DETAIL"
      selftest_print_live_summary "${selftest_kv_args[@]}"
      msg ""
      msg "Next:"
      msg "  $(cmd_proton) status"
      msg "  $(cmd_dll) verify"
      ;;
    dll)
      local sandbox_state="" sandbox_detail="" sandbox_input="" sandbox_dll="" sandbox_inner=""
      selftest_run_dll_sandbox "${selftest_dll_args[0]:-}" sandbox_state sandbox_detail sandbox_input sandbox_dll sandbox_inner || return $?
      msg ""
      msg "Sandbox:"
      printf '  %-7s %-9s %s\n' "ITEM" "STATE" "DETAIL"
      prep_print_status_row "MODE" "READY" "dll"
      prep_print_status_row "INPUT" "READY" "$sandbox_input"
      prep_print_status_row "DLL" "READY" "$sandbox_dll"
      prep_print_status_row "TRUST" "READY" "$sandbox_detail"
      if verbose_on && [[ -n "$sandbox_inner" ]]; then
        msg ""
        msg "Inner Output:"
        printf '%s\n' "$sandbox_inner"
      fi
      ok "selftest OK: DLL installed into temp HOME"
      msg ""
      msg "Next:"
      msg "  $(cmd_proton) status"
      msg "  $(cmd_dll) verify"
      ;;

    *)
      die "Unknown selftest mode: $mode (use: all | paths | steam | dll)"
      ;;
  esac

}

# main: cli dispatcher (rebuild/clean/list-clones/check/prep/gpu/status/selftest/dll)

main() {
  fsr4_resolve_policy

  if (($# == 0)); then
    # default to status (no gpu needed).
    do_status
    return 0
  fi

  local cmd="${1:-rebuild}"
  case "$cmd" in
    -h | --help | help)
      usage
      exit 0
      ;;
  esac
  if [[ "$cmd" != "rebuild" ]]; then
    local _arg=""
    for _arg in "${@:2}"; do
      [[ "$_arg" == "--dwproton-preview" ]] || continue
      die "--dwproton-preview is only valid with rebuild --dry-run"
    done
  fi

  # sanity-check cache root before we touch downloads/extract dirs.
  validate_cache_dir "$GENVW_CACHE_DIR"
  # keep legacy GENVW_AMD_DLL_NAME override aligned with wrapper validation.
  if [[ -n "${GENVW_AMD_DLL_NAME:-}" ]]; then
    local _raw_dll_name="${GENVW_AMD_DLL_NAME}"
    case "$_raw_dll_name" in
      */* | *\\* | *..*)
        die "Invalid GENVW_AMD_DLL_NAME: must be a safe basename (no slashes/traversal): $_raw_dll_name"
        ;;
    esac
    case "$_raw_dll_name" in
      *.dll) ;;
      *) die "Invalid GENVW_AMD_DLL_NAME: must end with .dll: $_raw_dll_name" ;;
    esac
    [[ "$_raw_dll_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*\.dll$ ]] \
      || die "Invalid GENVW_AMD_DLL_NAME: bad characters (allowed: A-Za-z0-9._- and .dll): $_raw_dll_name"
  fi
  # filename knobs are user-overridable; keep them as plain basenames.
  validate_basename "$AMD_DLL_NAME" "GENVW_AMD_DLL_NAME/AMD_DLL_NAME"
  validate_basename "$AMD_META_NAME" "GENVW_AMD_META_NAME/AMD_META_NAME"
  validate_basename "$AMD_REPORT_NAME" "GENVW_AMD_REPORT_NAME/AMD_REPORT_NAME"
  validate_basename "$AMD_LOCK_NAME" "GENVW_AMD_LOCK_NAME/AMD_LOCK_NAME"

  # gpu gating:
  # - most commands are just filesystem/steam/tooling
  # - rebuild/prep are the ones where "unsupported gpu" is worth warning about
  if [ "${GENVW_SKIP_GPU_CHECK:-0}" != "1" ]; then
    case "$cmd" in
      rebuild | prep)
        if [ "${GENVW_STRICT_GPU_CHECK:-0}" = "1" ]; then
          genvw_require_supported_gpu || return $?
        else
          genvw_warn_if_unsupported_gpu
        fi
        ;;
      *)
        # no gating for other commands.
        ;;
    esac
  fi

  case "$cmd" in
    rebuild)
      shift
      if proton_help_requested "$@"; then
        rebuild_usage
        return 0
      fi
      do_rebuild "$@"
      ;;
    clean)
      shift
      if proton_help_requested "$@"; then
        clean_usage
        return 0
      fi
      do_clean "$@"
      ;;
    list-clones)
      shift
      if proton_help_requested "$@"; then
        list_clones_usage
        return 0
      fi
      do_list_clones "$@"
      ;;
    sources)
      shift
      do_sources "$@"
      ;;
    dw-sources)
      shift
      do_dw_sources_machine "$@"
      ;;
    check)
      shift
      # kv mode: keep stdout intact (avoid callers eating output by accident).
      local _kv=0 _a
      for _a in "$@"; do
        case "$_a" in
          --kv | --machine) _kv=1 ;;
        esac
      done
      if ((_kv == 1)); then
        local _out
        _out="$(do_check "$@")"
        printf "%s\n" "$_out"
      else
        do_check "$@"
      fi
      ;;

    prep)
      shift
      if proton_help_requested "$@"; then
        prep_usage
        return 0
      fi
      do_prep "$@"
      ;;
    diagnose | diag)
      shift
      do_diagnose "$@"
      ;;
    gpu)
      shift
      do_gpu "$@"
      ;;
    status)
      shift
      do_status "$@"
      ;;
    selftest)
      shift
      do_selftest "$@"
      ;;
    dll)
      shift
      amd_dll_run "$@"
      ;;
    *) die "Unknown command: $cmd (try: --help)" ;;
  esac
}

# only run when executed, not when sourced.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi

# end of genvw_proton.sh
