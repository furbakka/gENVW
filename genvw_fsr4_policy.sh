#!/usr/bin/env bash

# Canonical FSR4 version/source rows and the shared local default for wrapper
# and helper startup policy.
GENVW_FSR4_CANONICAL_TRUSTED_SOURCE_ROWS=(
  "4.0.0|https://drive.google.com/uc?export=download&id=1PvETUOHujlV16mFGC3F6ZRxnqVIKaq0V|63ea321678072bb4e1fa956fd9977d7b998f496936e59b470a31677ed2bc69af|17799000"
  "4.0.1|https://drive.google.com/uc?export=download&id=1CFlmMn3cO4MNv2tdBjbB8WuVldcRtPGO|d521ae32fd1a6ab6f0a3e3ddffc7b433145388a437df52fcb01c85df241a0b01|14509352"
  "4.0.2|https://drive.google.com/uc?export=download&id=1--CoeECVDE0xyaGriO3YbWE1LHOI4cz2|2d4b5fb8e8b5f9e330c1c376989132a1be1879af20bb7f92442c44ad02af86fb|15715440"
  "4.0.3|https://drive.google.com/uc?export=download&id=1dm0GseR7BRg8MdBHmb-St-OS2L0TB8cZ|c3bfb4381c49bb1367a30c242017e867440382d1b286eea3f7cde96189a82b4a|58399928"
  "4.1.0|https://drive.google.com/uc?export=download&id=1HPVi-4MqmyV6Vn2KXIfvwq3ZUCbOZrKx|446e27b7eab3213a1fcb584516fcf24ffbdeb23be72136f3633e508320e71813|51084008"
)

GENVW_FSR4_CANONICAL_RELEASED_VERSIONS=()
for __genvw_fsr4_row in "${GENVW_FSR4_CANONICAL_TRUSTED_SOURCE_ROWS[@]}"; do
  IFS='|' read -r __genvw_fsr4_ver _ _ _ <<<"$__genvw_fsr4_row"
  GENVW_FSR4_CANONICAL_RELEASED_VERSIONS+=("$__genvw_fsr4_ver")
done
unset __genvw_fsr4_row __genvw_fsr4_ver

GENVW_FSR4_CANONICAL_LOCAL_ONLY_VERSIONS=("${GENVW_FSR4_CANONICAL_RELEASED_VERSIONS[@]}")
GENVW_FSR4_CANONICAL_LOCAL_DEFAULT_VER="4.0.2"

genvw_fsr4_policy_error() {
  local src="${GENVW_FSR4_POLICY_DATA:-${BASH_SOURCE[0]:-$0}}"
  printf 'ERROR: Invalid FSR4 policy data in %s: %s\n' "$src" "$*" >&2
  return 1
}

genvw_fsr4_policy_version_syntax_ok() {
  local ver="${1:-}"
  [[ "$ver" =~ ^4\.[0-9]+\.[0-9]+$ ]]
}

genvw_fsr4_policy_validate() {
  local row="" ver="" url="" sha="" size="" extra=""
  local local_ver=""
  local idx=0
  local -a derived_released=()
  declare -A seen_released=()
  declare -A seen_local=()

  ((${#GENVW_FSR4_CANONICAL_TRUSTED_SOURCE_ROWS[@]} > 0)) \
    || { genvw_fsr4_policy_error "trusted source rows are empty"; return 1; }

  for row in "${GENVW_FSR4_CANONICAL_TRUSTED_SOURCE_ROWS[@]}"; do
    idx=$((idx + 1))
    IFS='|' read -r ver url sha size extra <<<"$row"

    [[ -n "$ver" ]] || { genvw_fsr4_policy_error "row ${idx}: version is empty"; return 1; }
    genvw_fsr4_policy_version_syntax_ok "$ver" \
      || { genvw_fsr4_policy_error "row ${idx} (${ver}): version must look like 4.x.y"; return 1; }
    [[ -z "$extra" ]] || { genvw_fsr4_policy_error "row ${idx} (${ver}): expected 4 fields"; return 1; }
    [[ -n "$url" ]] || { genvw_fsr4_policy_error "row ${idx} (${ver}): url is empty"; return 1; }
    [[ "$sha" =~ ^[0-9A-Fa-f]{64}$ ]] \
      || { genvw_fsr4_policy_error "row ${idx} (${ver}): sha256 must be 64 hex characters"; return 1; }
    [[ "$size" =~ ^[0-9]+$ ]] \
      || { genvw_fsr4_policy_error "row ${idx} (${ver}): size must be numeric"; return 1; }

    [[ -z "${seen_released[$ver]+x}" ]] \
      || { genvw_fsr4_policy_error "duplicate released version '${ver}'"; return 1; }
    seen_released["$ver"]=1
    derived_released+=("$ver")
  done

  if ((${#GENVW_FSR4_CANONICAL_RELEASED_VERSIONS[@]} != ${#derived_released[@]})); then
    genvw_fsr4_policy_error "released version list does not match trusted rows"
    return 1
  fi

  for ver in "${GENVW_FSR4_CANONICAL_RELEASED_VERSIONS[@]}"; do
    [[ -n "$ver" ]] || { genvw_fsr4_policy_error "released version list contains an empty entry"; return 1; }
    genvw_fsr4_policy_version_syntax_ok "$ver" \
      || { genvw_fsr4_policy_error "released version list contains invalid version '${ver}'"; return 1; }
  done

  for idx in "${!derived_released[@]}"; do
    if [[ "${GENVW_FSR4_CANONICAL_RELEASED_VERSIONS[$idx]:-}" != "${derived_released[$idx]}" ]]; then
      genvw_fsr4_policy_error "released version list does not match trusted rows"
      return 1
    fi
  done

  ((${#GENVW_FSR4_CANONICAL_LOCAL_ONLY_VERSIONS[@]} > 0)) \
    || { genvw_fsr4_policy_error "local-only version list is empty"; return 1; }

  for local_ver in "${GENVW_FSR4_CANONICAL_LOCAL_ONLY_VERSIONS[@]}"; do
    [[ -n "$local_ver" ]] || { genvw_fsr4_policy_error "local-only version list contains an empty entry"; return 1; }
    genvw_fsr4_policy_version_syntax_ok "$local_ver" \
      || { genvw_fsr4_policy_error "local-only version '${local_ver}' must look like 4.x.y"; return 1; }
    [[ -z "${seen_local[$local_ver]+x}" ]] \
      || { genvw_fsr4_policy_error "duplicate local-only version '${local_ver}'"; return 1; }
    [[ -n "${seen_released[$local_ver]+x}" ]] \
      || { genvw_fsr4_policy_error "local-only version '${local_ver}' is not in released versions"; return 1; }
    seen_local["$local_ver"]=1
  done

  [[ -n "${GENVW_FSR4_CANONICAL_LOCAL_DEFAULT_VER:-}" ]] \
    || { genvw_fsr4_policy_error "local default is empty"; return 1; }
  genvw_fsr4_policy_version_syntax_ok "${GENVW_FSR4_CANONICAL_LOCAL_DEFAULT_VER}" \
    || { genvw_fsr4_policy_error "local default '${GENVW_FSR4_CANONICAL_LOCAL_DEFAULT_VER}' must look like 4.x.y"; return 1; }
  [[ -n "${seen_local[$GENVW_FSR4_CANONICAL_LOCAL_DEFAULT_VER]+x}" ]] \
    || { genvw_fsr4_policy_error "local default '${GENVW_FSR4_CANONICAL_LOCAL_DEFAULT_VER}' is not in local-only versions"; return 1; }

  return 0
}

genvw_fsr4_policy_versions_csv() {
  local -n arr_ref="$1"
  local out="" v=""
  for v in "${arr_ref[@]}"; do
    [[ -n "$out" ]] && out+=","
    out+="$v"
  done
  printf '%s\n' "$out"
}

genvw_fsr4_policy_manifest_body() {
  local idx=0
  local row=""

  printf 'MANIFEST_FORMAT_VERSION=1\n'
  printf 'TRUSTED_SOURCE_ROW_COUNT=%s\n' "${#GENVW_FSR4_CANONICAL_TRUSTED_SOURCE_ROWS[@]}"
  for row in "${GENVW_FSR4_CANONICAL_TRUSTED_SOURCE_ROWS[@]}"; do
    idx=$((idx + 1))
    printf 'TRUSTED_SOURCE_ROW_%s=%s\n' "$idx" "$row"
  done
  printf 'RELEASED_VERSIONS_CSV=%s\n' "$(genvw_fsr4_policy_versions_csv GENVW_FSR4_CANONICAL_RELEASED_VERSIONS)"
  printf 'LOCAL_ONLY_VERSIONS_CSV=%s\n' "$(genvw_fsr4_policy_versions_csv GENVW_FSR4_CANONICAL_LOCAL_ONLY_VERSIONS)"
  printf 'LOCAL_DEFAULT_VER=%s\n' "$GENVW_FSR4_CANONICAL_LOCAL_DEFAULT_VER"
}

genvw_fsr4_policy_manifest_snapshot() {
  local body="" digest=""
  body="$(genvw_fsr4_policy_manifest_body)"
  digest="$(printf '%s\n' "$body" | sha256sum | awk '{print $1}')"
  printf '%s\n' "$body"
  printf 'MANIFEST_SHA256=%s\n' "$digest"
}
