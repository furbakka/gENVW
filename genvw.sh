#!/usr/bin/env bash
# gENVW — Steam/Proton wrapper + wizard
# Copyright (C) 2025 furbakka
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
# See the GNU General Public License for more details.
#
# Modes:
#   • Wizard: run `genvw` → prints a Steam launch line.
#   • Wrapper: `genvw %command%` (Steam launch options wrapper).
#   • Tools: `genvw proton …` delegates to genvw_proton.sh.
#
# Local FSR4 DLL (canonical cache):
#   ~/.cache/protonfixes/upscalers/genvw/amdxcffx64_vX.Y.Z.dll
#
# SECURITY: local-only DLL use is gated via `genvw proton check --kv`
#          (meta match + allowlist match). Keep that KV output stable.
#
GENVW_VERSION="0.5.0"

# AMD_DRIVER_URL (default)
# Default AMD driver EXE URL exported by genvw for `genvw proton dll ...`.
#
# Override:
#   Use explicit flags:
#     genvw proton dll install --url "https://drivers.amd.com/drivers/driver.exe"
#     genvw proton dll install --exe "/path/to/whql-amd-software-adrenalin-*.exe"
#     genvw proton dll install --dll "/path/to/amdxcffx64_vX.Y.Z.dll"
#
# Security:
#   genvw intentionally overwrites/export AMD_DRIVER_URL; one-off
#   AMD_DRIVER_URL="https://..." env overrides are ignored here.
#   Edit this value (and optionally the helper fallback) to change the default.
#
AMD_DRIVER_URL="https://drivers.amd.com/drivers/whql-amd-software-adrenalin-edition-26.1.1-win11-b.exe"

# FSR4 local DLL cache (wrapper-side)
# Local DLL filenames are: amdxcffx64_vX.Y.Z.dll
# Example: amdxcffx64_v4.0.3.dll
#
# SECURITY: trust boundary (downloads/extract, user-controlled paths).
# genvw validates attacker-controlled env vars (e.g. GENVW_AMD_DLL_NAME) early,
# before the full UI helpers (msg/err/die with icons/colors) are defined.
# A minimal die() is defined here so early validation always aborts safely.
# The full die() later overrides this bootstrap version.

# Default cache directory for local-only FSR4 DLLs (override for testing if needed).
GENVW_FSR4_LOCAL_DIR="${GENVW_FSR4_LOCAL_DIR:-${HOME}/.cache/protonfixes/upscalers/genvw}"

# bootstrap die for early validation
# exit 2 here is intentional: this is the "early init failed" path.
die_bootstrap() { printf 'ERROR: %s\n' "$*" >&2; exit 2; }

GENVW_WRAPPER_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" >/dev/null 2>&1 && pwd -P)"
GENVW_FSR4_POLICY_DATA="${GENVW_WRAPPER_DIR}/genvw_fsr4_policy.sh"
[[ -r "$GENVW_FSR4_POLICY_DATA" ]] || die_bootstrap "Missing FSR4 policy data: $GENVW_FSR4_POLICY_DATA"
# shellcheck disable=SC1090
source "$GENVW_FSR4_POLICY_DATA"
genvw_fsr4_policy_validate || exit 2

# SECURITY: user-controlled directory env vars feed file joins / writes / cleanup roots.
# Reject empty, non-absolute, '/', whitespace-bearing, or '..'-bearing values at bootstrap
# so bad values fail loudly here instead of producing wrong-path joins later.
# No normalization, no tilde expansion, no silent rewrites.
validate_dir_env() {
  local value="${1:-}"
  local label="${2:-value}"
  [[ -n "$value" ]] || die_bootstrap "${label} is empty"
  [[ "$value" == /* ]] || die_bootstrap "${label} must be an absolute path: $value"
  [[ "$value" != "/" ]] || die_bootstrap "${label} must not be /: $value"
  case "$value" in
    *[[:space:]]*) die_bootstrap "${label} must not contain whitespace: $value" ;;
  esac
  case "$value" in
    *..*) die_bootstrap "${label} must not contain '..': $value" ;;
  esac
}

# SECURITY: GENVW_FSR4_LOCAL_DIR feeds versioned local-DLL path composition in
# genvw_fsr4_local_dll_path and is used by wizard/install/prep flows.
# Validate here so a bad value fails before any consumer runs.
validate_dir_env "${GENVW_FSR4_LOCAL_DIR:-}" "GENVW_FSR4_LOCAL_DIR"
[[ -n "${GENVW_PROFILE_DIR:-}" ]] && validate_dir_env "$GENVW_PROFILE_DIR" "GENVW_PROFILE_DIR"
[[ -n "${GENVW_ASSET_DIR:-}" ]] && validate_dir_env "$GENVW_ASSET_DIR" "GENVW_ASSET_DIR"

# SECURITY: GENVW_AMD_DLL_NAME is user-controlled. Only allow a basename (no slashes / no '..')
# so path construction cannot escape the cache dir.
genvw_amd_dll_name_safe="${GENVW_AMD_DLL_NAME:-amdxcffx64.dll}"
case "$genvw_amd_dll_name_safe" in
  *"/"* | *".."* | "." | "")
    die_bootstrap "Invalid GENVW_AMD_DLL_NAME: must be a safe basename (no slashes/traversal): $genvw_amd_dll_name_safe"
    ;;
esac

# SECURITY: keep wrapper + helper in sync — disallow weird characters/spaces, require *.dll basename.
# This prevents confusing "wrapper accepts / helper rejects" states and keeps cache naming deterministic.
case "$genvw_amd_dll_name_safe" in
  *.dll) ;;
  *) die_bootstrap "Invalid GENVW_AMD_DLL_NAME: must end with .dll: $genvw_amd_dll_name_safe" ;;
esac
[[ "$genvw_amd_dll_name_safe" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*\.dll$ ]] || die_bootstrap "Invalid GENVW_AMD_DLL_NAME: bad characters (allowed: A-Za-z0-9._- and .dll): $genvw_amd_dll_name_safe"

# Preferred override: allow the wrapper to honor the same stem knob as genvw_proton.sh.
# If set, the helper installs/verifies STEM_vVER.dll under the cache dir; genvw must point to the same.
genvw_amd_dll_stem="${GENVW_AMD_DLL_STEM:-}"
if [[ -z "$genvw_amd_dll_stem" ]]; then
  # Derive a stable stem from a versioned basename (if present).
  # Keep this in sync with genvw_proton.sh.
  genvw_amd_dll_stem="${genvw_amd_dll_name_safe##*/}"
  genvw_amd_dll_stem="${genvw_amd_dll_stem%.dll}"
  genvw_amd_dll_stem="${genvw_amd_dll_stem%%_v*}"
  [[ -n "$genvw_amd_dll_stem" ]] || genvw_amd_dll_stem="amdxcffx64"
else
      # SECURITY: stem must be a simple token (no slashes/traversal). Keep naming deterministic.
  case "$genvw_amd_dll_stem" in
    *"/"* | *".."* | "." | "")
      die_bootstrap "Invalid GENVW_AMD_DLL_STEM: must be a safe token (no slashes/traversal): $genvw_amd_dll_stem"
      ;;
  esac
  [[ "$genvw_amd_dll_stem" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die_bootstrap "Invalid GENVW_AMD_DLL_STEM: bad characters (allowed: A-Za-z0-9._-): $genvw_amd_dll_stem"
fi


# canonical versioned local DLL path for a given FSR4 version
genvw_fsr4_local_dll_path() {
  local ver="${1:-}"
  [[ -n "$ver" ]] || die "genvw_fsr4_local_dll_path: missing version"
  printf '%s\n' "${GENVW_FSR4_LOCAL_DIR}/${genvw_amd_dll_stem}_v${ver}.dll"
}

genvw_fsr4_ver_from_local_dll_path() {
  local p="${1:-}"
  local base=""
  [[ -n "$p" ]] || return 1
  base="$(basename -- "$p" 2>/dev/null || printf '%s' "$p")"
  if [[ "$base" =~ _v(4\.[0-9]+\.[0-9]+)\.dll$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

genvw_paths_equivalent() {
  local a="${1:-}" b="${2:-}"
  [[ -n "$a" && -n "$b" ]] || return 1
  if command -v realpath >/dev/null 2>&1; then
    a="$(realpath -m -- "$a" 2>/dev/null || printf '%s' "$a")"
    b="$(realpath -m -- "$b" 2>/dev/null || printf '%s' "$b")"
  fi
  [[ "$a" == "$b" ]]
}

genvw_fsr4_legacy_local_input_ver() {
  local p="${1:-${PROTON_FSR4_LOCAL:-}}"
  local ver=""
  ver="$(genvw_fsr4_ver_from_local_dll_path "$p" 2>/dev/null || true)"
  [[ -n "$ver" ]] || return 1
  genvw_fsr4_is_local_only "$ver" || return 1
  printf '%s\n' "$ver"
}

genvw_fsr4_apply_legacy_local_input() {
  local legacy_path="${PROTON_FSR4_LOCAL:-}"
  local want_ver="" canon_path="" target_var="" gen=""

  [[ -n "$legacy_path" ]] || return 0

  want_ver="$(genvw_fsr4_guess_selected_ver)"
  if [[ -z "$want_ver" ]]; then
    want_ver="$(genvw_fsr4_legacy_local_input_ver "$legacy_path" 2>/dev/null || true)"
    if [[ -z "$want_ver" ]]; then
      err "gENVW: PROTON_FSR4_LOCAL is legacy-only and must point to a versioned local-only cache DLL."
      msg "Use FSR4=<version> as the canonical interface." >&2
      msg "Expected basename: ${genvw_amd_dll_stem}_v4.x.y.dll" >&2
      return 1
    fi
    gen="$(detect_rdna_gen 2>/dev/null || printf '0')"
    case "$gen" in
      2 | 3)
        export PROTON_FSR4_RDNA3_UPGRADE="$want_ver"
        target_var="PROTON_FSR4_RDNA3_UPGRADE"
        ;;
      *)
        export PROTON_FSR4_UPGRADE="$want_ver"
        target_var="PROTON_FSR4_UPGRADE"
        ;;
    esac
    warn "gENVW: PROTON_FSR4_LOCAL is legacy-only; canonicalizing to ${target_var}=${want_ver}." >&2
  fi

  if ! genvw_fsr4_is_local_only "$want_ver"; then
    err "gENVW: PROTON_FSR4_LOCAL is legacy-only and only valid with local-only FSR4 versions."
    msg "Selected version: ${want_ver}" >&2
    msg "Use FSR4=<local-only-version> and remove PROTON_FSR4_LOCAL." >&2
    return 1
  fi

  canon_path="$(genvw_fsr4_local_dll_path "$want_ver")"
  if ! genvw_paths_equivalent "$legacy_path" "$canon_path"; then
    err "gENVW: PROTON_FSR4_LOCAL is legacy-only and must match the canonical cache path for FSR4 ${want_ver}."
    msg "Provided:  ${legacy_path}" >&2
    msg "Canonical: ${canon_path}" >&2
    msg "Use FSR4=${want_ver} and remove PROTON_FSR4_LOCAL." >&2
    return 1
  fi

  if [[ -z "$target_var" ]]; then
    warn "gENVW: PROTON_FSR4_LOCAL is legacy-only; keeping version-first FSR4 ${want_ver} and clearing the path override." >&2
  fi
  unset PROTON_FSR4_LOCAL
  return 0
}

# Wrapper-side FSR4 policy comes from the shared canonical rows/default.
GENVW_FSR4_KNOB_ALLOWED_VERSIONS=("${GENVW_FSR4_CANONICAL_RELEASED_VERSIONS[@]}")
GENVW_FSR4_LOCAL_ONLY_VERSIONS=("${GENVW_FSR4_CANONICAL_LOCAL_ONLY_VERSIONS[@]}")
GENVW_FSR4_WIZARD_LOCAL_DEFAULT="${GENVW_FSR4_CANONICAL_LOCAL_DEFAULT_VER}"
GENVW_FSR4_RESOLVED_KNOB_ALLOWED_VERSIONS=("${GENVW_FSR4_KNOB_ALLOWED_VERSIONS[@]}")
GENVW_FSR4_RESOLVED_LOCAL_ONLY_VERSIONS=("${GENVW_FSR4_LOCAL_ONLY_VERSIONS[@]}")
GENVW_FSR4_RUNTIME_LOCAL_DEFAULT_VER="${GENVW_FSR4_WIZARD_LOCAL_DEFAULT}"
GENVW_FSR4_RUNTIME_LOCAL_DEFAULT_SOURCE="preferred_default"

# Remote default can differ by GPU class.
GENVW_FSR4_DEFAULT_REMOTE_RDNA2="4.0.0"
GENVW_FSR4_DEFAULT_REMOTE_RDNA3="4.0.0"
GENVW_FSR4_DEFAULT_REMOTE_RDNA4="4.0.2"
GENVW_FSR4_DEFAULT_REMOTE_UNKNOWN="4.0.0"

genvw_fsr4_version_in_list() {
  local ver="${1:-}"
  shift || true
  [[ -n "$ver" ]] || return 1
  local v
  for v in "$@"; do
    [[ "$ver" == "$v" ]] && return 0
  done
  return 1
}

genvw_fsr4_set_runtime_local_default() {
  local ver="${1:-$GENVW_FSR4_WIZARD_LOCAL_DEFAULT}"
  local source="${2:-preferred_default}"
  if ! genvw_fsr4_is_local_only "$ver"; then
    ver="$GENVW_FSR4_WIZARD_LOCAL_DEFAULT"
    source="preferred_default"
  fi
  GENVW_FSR4_RUNTIME_LOCAL_DEFAULT_VER="$ver"
  GENVW_FSR4_RUNTIME_LOCAL_DEFAULT_SOURCE="$source"
}

genvw_fsr4_refresh_runtime_local_default_from_localdll() {
  local localdll="${1:-}"
  local ver=""
  if [[ -n "$localdll" ]] \
    && ver="$(genvw_fsr4_ver_from_local_dll_path "$localdll" 2>/dev/null)" \
    && genvw_fsr4_is_local_only "$ver"; then
    genvw_fsr4_set_runtime_local_default "$ver" "helper_localdll"
    return 0
  fi
  genvw_fsr4_set_runtime_local_default "$GENVW_FSR4_WIZARD_LOCAL_DEFAULT" "preferred_default"
  return 1
}

genvw_fsr4_effective_local_default_ver() {
  printf '%s\n' "${GENVW_FSR4_RUNTIME_LOCAL_DEFAULT_VER:-$GENVW_FSR4_WIZARD_LOCAL_DEFAULT}"
}

genvw_fsr4_effective_local_dll_path() {
  genvw_fsr4_local_dll_path "$(genvw_fsr4_effective_local_default_ver)"
}

genvw_trim_space_edges() {
  local s="${1-}"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s\n' "$s"
}

genvw_fsr4_parse_csv_strict_4x_into_array() {
  local raw="${1-}" label="${2:-CSV}"
  local -n out_ref="$3"
  local -a toks=()
  local t v
  declare -A seen=()

  out_ref=()
  [[ -n "$raw" ]] || die_bootstrap "${label} is empty"
  if [[ "$raw" == *, || "$raw" == ,* || "$raw" == *",,"* ]]; then
    die_bootstrap "${label} is malformed (empty CSV element)"
  fi

  IFS=',' read -r -a toks <<<"$raw"
  ((${#toks[@]} > 0)) || die_bootstrap "${label} did not contain any versions"

  for t in "${toks[@]}"; do
    v="$(genvw_trim_space_edges "$t")"
    [[ -n "$v" ]] || die_bootstrap "${label} has empty/whitespace-only element"
    [[ "$v" =~ ^4\.[0-9]+\.[0-9]+$ ]] || die_bootstrap "${label} has invalid version '${v}' (expected 4.x.y)"
    if [[ -n "${seen[$v]+x}" ]]; then
      die_bootstrap "${label} has duplicate version '${v}'"
    fi
    seen["$v"]=1
    out_ref+=("$v")
  done
}

genvw_fsr4_array_contains() {
  local needle="${1:-}"
  shift || true
  local x
  for x in "$@"; do
    [[ "$needle" == "$x" ]] && return 0
  done
  return 1
}

genvw_fsr4_versions_csv_from_array() {
  local -n arr_ref="$1"
  local out="" v
  for v in "${arr_ref[@]}"; do
    if [[ -n "$out" ]]; then
      out+=","
    fi
    out+="$v"
  done
  printf '%s\n' "$out"
}

genvw_fsr4_versions_pretty_from_array() {
  local -n arr_ref="$1"
  local out="" v
  for v in "${arr_ref[@]}"; do
    if [[ -n "$out" ]]; then
      out+=", "
    fi
    out+="$v"
  done
  printf '%s\n' "$out"
}

genvw_fsr4_versions_slash_from_array() {
  local -n arr_ref="$1"
  local out="" v
  for v in "${arr_ref[@]}"; do
    if [[ -n "$out" ]]; then
      out+="/"
    fi
    out+="$v"
  done
  printf '%s\n' "$out"
}

genvw_fsr4_add_tokens_to_policy() {
  local -n target_ref="$1"
  local raw="${2-}"
  local label="${3:-CSV}"
  local -a parsed=()
  local v
  [[ -n "$raw" ]] || return 0
  genvw_fsr4_parse_csv_strict_4x_into_array "$raw" "$label" parsed
  for v in "${parsed[@]}"; do
    if genvw_fsr4_array_contains "$v" "${target_ref[@]}"; then
      die_bootstrap "${label} tried to add duplicate/already-present version '${v}'"
    fi
    target_ref+=("$v")
  done
}

genvw_fsr4_replace_policy_from_csv() {
  local -n target_ref="$1"
  local raw="${2-}"
  local label="${3:-CSV}"
  local -a parsed=()
  genvw_fsr4_parse_csv_strict_4x_into_array "$raw" "$label" parsed
  ((${#parsed[@]} > 0)) || die_bootstrap "${label} did not contain any versions"
  target_ref=("${parsed[@]}")
}

genvw_fsr4_validate_final_policy() {
  local v
  for v in "${GENVW_FSR4_RESOLVED_LOCAL_ONLY_VERSIONS[@]}"; do
    if ! genvw_fsr4_array_contains "$v" "${GENVW_FSR4_RESOLVED_KNOB_ALLOWED_VERSIONS[@]}"; then
      die_bootstrap "Invalid FSR4 policy: local-only version '${v}' is not in released/allowed policy"
    fi
  done

  if ! genvw_fsr4_array_contains "$GENVW_FSR4_WIZARD_LOCAL_DEFAULT" "${GENVW_FSR4_RESOLVED_KNOB_ALLOWED_VERSIONS[@]}"; then
    die_bootstrap "Invalid FSR4 policy: GENVW_FSR4_WIZARD_LOCAL_DEFAULT (${GENVW_FSR4_WIZARD_LOCAL_DEFAULT}) is not in released/allowed policy"
  fi
  if ! genvw_fsr4_array_contains "$GENVW_FSR4_WIZARD_LOCAL_DEFAULT" "${GENVW_FSR4_RESOLVED_LOCAL_ONLY_VERSIONS[@]}"; then
    die_bootstrap "Invalid FSR4 policy: GENVW_FSR4_WIZARD_LOCAL_DEFAULT (${GENVW_FSR4_WIZARD_LOCAL_DEFAULT}) is not in local-only policy"
  fi
}

genvw_fsr4_resolve_policy() {
  local replace_ok="${GENVW_FSR4_POLICY_REPLACE_OK:-0}"
  local rel_replace="${GENVW_FSR4_RELEASED_VERSIONS_CSV-}"
  local loc_replace="${GENVW_FSR4_LOCAL_ONLY_VERSIONS_CSV-}"
  local add_both="${GENVW_FSR4_ADD_CSV-}"
  local add_both_alias="${GENVW_FSR4_ADD-}"
  local add_rel="${GENVW_FSR4_RELEASED_ADD_CSV-}"
  local add_loc="${GENVW_FSR4_LOCAL_ONLY_ADD_CSV-}"

  GENVW_FSR4_RESOLVED_KNOB_ALLOWED_VERSIONS=("${GENVW_FSR4_KNOB_ALLOWED_VERSIONS[@]}")
  GENVW_FSR4_RESOLVED_LOCAL_ONLY_VERSIONS=("${GENVW_FSR4_LOCAL_ONLY_VERSIONS[@]}")

  if [[ -n "$add_both" && -n "$add_both_alias" ]]; then
    die_bootstrap "Set only one of GENVW_FSR4_ADD_CSV or GENVW_FSR4_ADD (not both)"
  fi
  [[ -n "$add_both" ]] || add_both="$add_both_alias"

  if [[ -n "$rel_replace" || -n "$loc_replace" ]]; then
    [[ "$replace_ok" == "1" ]] || die_bootstrap "Full FSR4 policy replace requires GENVW_FSR4_POLICY_REPLACE_OK=1"
    if [[ -n "$rel_replace" ]]; then
      genvw_fsr4_replace_policy_from_csv GENVW_FSR4_RESOLVED_KNOB_ALLOWED_VERSIONS "$rel_replace" "GENVW_FSR4_RELEASED_VERSIONS_CSV"
    fi
    if [[ -n "$loc_replace" ]]; then
      genvw_fsr4_replace_policy_from_csv GENVW_FSR4_RESOLVED_LOCAL_ONLY_VERSIONS "$loc_replace" "GENVW_FSR4_LOCAL_ONLY_VERSIONS_CSV"
    fi
  fi

  genvw_fsr4_add_tokens_to_policy GENVW_FSR4_RESOLVED_KNOB_ALLOWED_VERSIONS "$add_both" "GENVW_FSR4_ADD_CSV/GENVW_FSR4_ADD"
  genvw_fsr4_add_tokens_to_policy GENVW_FSR4_RESOLVED_LOCAL_ONLY_VERSIONS "$add_both" "GENVW_FSR4_ADD_CSV/GENVW_FSR4_ADD"
  genvw_fsr4_add_tokens_to_policy GENVW_FSR4_RESOLVED_KNOB_ALLOWED_VERSIONS "$add_rel" "GENVW_FSR4_RELEASED_ADD_CSV"
  genvw_fsr4_add_tokens_to_policy GENVW_FSR4_RESOLVED_LOCAL_ONLY_VERSIONS "$add_loc" "GENVW_FSR4_LOCAL_ONLY_ADD_CSV"

  genvw_fsr4_validate_final_policy
}

genvw_fsr4_export_resolved_policy_for_helper() {
  export GENVW_FSR4_RESOLVED_RELEASED_VERSIONS_CSV
  export GENVW_FSR4_RESOLVED_LOCAL_ONLY_VERSIONS_CSV
  export GENVW_FSR4_RESOLVED_SOURCE
  GENVW_FSR4_RESOLVED_RELEASED_VERSIONS_CSV="$(genvw_fsr4_versions_csv_from_array GENVW_FSR4_RESOLVED_KNOB_ALLOWED_VERSIONS)"
  GENVW_FSR4_RESOLVED_LOCAL_ONLY_VERSIONS_CSV="$(genvw_fsr4_versions_csv_from_array GENVW_FSR4_RESOLVED_LOCAL_ONLY_VERSIONS)"
  GENVW_FSR4_RESOLVED_SOURCE="genvw"
}

genvw_fsr4_is_knob_allowed() {
  genvw_fsr4_version_in_list "${1:-}" "${GENVW_FSR4_RESOLVED_KNOB_ALLOWED_VERSIONS[@]}"
}

genvw_fsr4_is_local_only() {
  genvw_fsr4_version_in_list "${1:-}" "${GENVW_FSR4_RESOLVED_LOCAL_ONLY_VERSIONS[@]}"
}

genvw_fsr4_default_remote_for_gen() {
  local gen="${1:-0}"
  case "$gen" in
    2) printf '%s\n' "$GENVW_FSR4_DEFAULT_REMOTE_RDNA2" ;;
    3) printf '%s\n' "$GENVW_FSR4_DEFAULT_REMOTE_RDNA3" ;;
    4) printf '%s\n' "$GENVW_FSR4_DEFAULT_REMOTE_RDNA4" ;;
    *) printf '%s\n' "$GENVW_FSR4_DEFAULT_REMOTE_UNKNOWN" ;;
  esac
}

genvw_fsr4_upstream_auto_default_for_gen() {
  local gen="${1:-0}"
  if genvw_proton_policy_fsr4_global_auto_defaults_410; then
    case "$gen" in
      2 | 3) printf '%s\n' "4.0.0" ;;
      4) printf '%s\n' "4.1.0" ;;
      *) printf '%s\n' "4.1.0" ;;
    esac
    return 0
  fi
  genvw_fsr4_default_remote_for_gen "$gen"
}

genvw_fsr4_is_legacy_4x_triplet() {
  local ver="${1:-}"
  [[ "$ver" =~ ^4\.[0-9]+\.[0-9]+$ ]]
}

genvw_fsr4_malformed_override_label() {
  local v=""

  v="${PROTON_FSR4_RDNA3_UPGRADE:-}"
  if [[ -n "$v" && "$v" == 4.* ]] && ! genvw_fsr4_is_legacy_4x_triplet "$v"; then
    printf 'PROTON_FSR4_RDNA3_UPGRADE=%s\n' "$v"
    return 0
  fi

  v="${PROTON_FSR4_UPGRADE:-}"
  if [[ -n "$v" && "$v" == 4.* ]] && ! genvw_fsr4_is_legacy_4x_triplet "$v"; then
    printf 'PROTON_FSR4_UPGRADE=%s\n' "$v"
    return 0
  fi

  v="${FSR4_RDNA3:-}"
  if [[ -n "$v" && "$v" == 4.* ]] && ! genvw_fsr4_is_legacy_4x_triplet "$v"; then
    printf 'FSR4_RDNA3=%s\n' "$v"
    return 0
  fi

  v="${FSR4:-}"
  if [[ -n "$v" && "$v" == 4.* ]] && ! genvw_fsr4_is_legacy_4x_triplet "$v"; then
    printf 'FSR4=%s\n' "$v"
    return 0
  fi

  return 1
}

genvw_fsr4_allowed_versions_csv() {
  genvw_fsr4_versions_pretty_from_array GENVW_FSR4_RESOLVED_KNOB_ALLOWED_VERSIONS
}

genvw_fsr4_allowed_versions_slash() {
  genvw_fsr4_versions_slash_from_array GENVW_FSR4_RESOLVED_KNOB_ALLOWED_VERSIONS
}

# resolve policy once at startup, then export the resolved contract for helper parity.
genvw_fsr4_resolve_policy
genvw_fsr4_export_resolved_policy_for_helper

genvw_dxvk_policy_for_build_date() {
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

genvw_dxvk_probe_tree_policy() {
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

genvw_proton_source_build_date_from_root() {
  local root="${1:-}" base="" line="" token="" display=""
  base="${root##*/}"

  if [[ "$base" =~ ^proton-cachyos-([0-9]+([.][0-9]+)?)-([0-9]{8})-(.+)$ ]]; then
    printf '%s\n' "${BASH_REMATCH[3]}"
    return 0
  fi

  if [[ -r "$root/version" ]]; then
    IFS= read -r line <"$root/version" || true
    line="${line//$'\r'/}"
    token="${line#* }"
    if [[ "$token" =~ ^cachyos-([0-9]+([.][0-9]+)?)-([0-9]{8})-(native|slr)$ ]]; then
      printf '%s\n' "${BASH_REMATCH[3]}"
      return 0
    fi
  fi

  if [[ -r "$root/compatibilitytool.vdf" ]]; then
    display="$(awk -F'"' '$2=="display_name"{print $4; exit}' "$root/compatibilitytool.vdf" 2>/dev/null || true)"
    if [[ "$display" =~ proton-cachyos-([0-9]+([.][0-9]+)?)-([0-9]{8}) ]]; then
      printf '%s\n' "${BASH_REMATCH[3]}"
      return 0
    fi
  fi

  return 1
}

genvw_proton_source_major_from_root() {
  local root="${1:-}" base="" line="" token="" display=""
  base="${root##*/}"

  if [[ "$base" =~ ^proton-cachyos-([0-9]+([.][0-9]+)?)-([0-9]{8})-(.+)$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi

  if [[ -r "$root/version" ]]; then
    IFS= read -r line <"$root/version" || true
    line="${line//$'\r'/}"
    token="${line#* }"
    if [[ "$token" =~ ^cachyos-([0-9]+([.][0-9]+)?)-([0-9]{8})-(native|slr)$ ]]; then
      printf '%s\n' "${BASH_REMATCH[1]}"
      return 0
    fi
  fi

  if [[ -r "$root/compatibilitytool.vdf" ]]; then
    display="$(awk -F'"' '$2=="display_name"{print $4; exit}' "$root/compatibilitytool.vdf" 2>/dev/null || true)"
    if [[ "$display" =~ proton-cachyos-([0-9]+([.][0-9]+)?)-([0-9]{8}) ]]; then
      printf '%s\n' "${BASH_REMATCH[1]}"
      return 0
    fi
  fi

  return 1
}

genvw_proton_tree_is_cachyos() {
  local root="${1:-}" base="" version_line=""
  [[ -d "$root" ]] || return 1
  base="${root##*/}"
  case "$base" in
    proton-cachyos | proton-cachyos-*) return 0 ;;
  esac
  if [[ -r "$root/version" ]]; then
    IFS= read -r version_line <"$root/version" || true
    version_line="${version_line//$'\r'/}"
    [[ "$version_line" =~ (^|[[:space:]])cachyos-([0-9]+([.][0-9]+)?)-([0-9]{8})-(native|slr)$ ]] && return 0
  fi
  return 1
}

genvw_date_ge() {
  local got="${1:-}" want="${2:-}"
  [[ "$got" =~ ^[0-9]{8}$ && "$want" =~ ^[0-9]{8}$ ]] || return 1
  ((10#$got >= 10#$want))
}

genvw_proton_env_policy_context() {
  local out_major="${1:-}" out_date="${2:-}"
  local root="" reason="" ctx_major="" ctx_build_date=""

  if [ "${GENVW_DXVK_TARGET_READY:-0}" = "1" ]; then
    root="${GENVW_DXVK_TARGET_ROOT:-}"
    ctx_major="${GENVW_DXVK_TARGET_MAJOR:-}"
    ctx_build_date="${GENVW_DXVK_TARGET_BUILD_DATE:-}"
    if [[ -z "$ctx_major" && -n "$root" ]]; then
      ctx_major="$(genvw_proton_source_major_from_root "$root" 2>/dev/null || true)"
    fi
  fi

  if [[ -z "$ctx_major" || -z "$ctx_build_date" ]]; then
    if genvw_dxvk_runtime_tool_root root reason || genvw_dxvk_explicit_tool_root root reason; then
      [[ -n "$ctx_major" ]] || ctx_major="$(genvw_proton_source_major_from_root "$root" 2>/dev/null || true)"
      [[ -n "$ctx_build_date" ]] || ctx_build_date="$(genvw_proton_source_build_date_from_root "$root" 2>/dev/null || true)"
    fi
  fi

  if [[ -z "$ctx_build_date" ]]; then
    genvw_dxvk_explicit_build_date ctx_build_date || ctx_build_date=""
  fi

  [[ "$ctx_major" =~ ^[0-9]+([.][0-9]+)?$ ]] || ctx_major=""
  [[ "$ctx_build_date" =~ ^[0-9]{8}$ ]] || ctx_build_date=""

  [[ -n "$out_major" ]] && printf -v "$out_major" '%s' "$ctx_major"
  [[ -n "$out_date" ]] && printf -v "$out_date" '%s' "$ctx_build_date"
}

genvw_proton_major_is_11() {
  local major="${1:-}"
  [[ "$major" == "11" || "$major" == 11.* ]]
}

genvw_proton_policy_matches_11_major_date() {
  local boundary_date="${1:-}" major="" build_date=""
  genvw_proton_env_policy_context major build_date
  genvw_date_ge "$build_date" "$boundary_date" || return 1
  genvw_proton_major_is_11 "$major"
}

genvw_proton_policy_uses_proton_no_ntsync() {
  genvw_proton_policy_matches_11_major_date 20260428
}

genvw_proton_policy_omits_proton_enable_hdr() {
  genvw_proton_policy_matches_11_major_date 20260506
}

genvw_proton_policy_fsr4_global_auto_defaults_410() {
  genvw_proton_policy_matches_11_major_date 20260506
}

genvw_hdr_env_label() {
  if genvw_proton_policy_omits_proton_enable_hdr; then
    printf '%s\n' "PROTON_ENABLE_WAYLAND, DXVK_HDR, ENABLE_HDR_WSI"
  else
    printf '%s\n' "PROTON_ENABLE_WAYLAND, PROTON_ENABLE_HDR, DXVK_HDR, ENABLE_HDR_WSI"
  fi
}

genvw_dxvk_runtime_tool_root() {
  local out_root_var="${1:-}" out_reason_var="${2:-}"
  local candidates=() cand="" raw="" normalized=""

  [[ -n "${STEAM_COMPAT_TOOL_PATH:-}" ]] && candidates+=("STEAM_COMPAT_TOOL_PATH|${STEAM_COMPAT_TOOL_PATH}")
  if [[ -n "${STEAM_COMPAT_TOOL_PATHS:-}" ]]; then
    IFS=':' read -r -a raw <<<"${STEAM_COMPAT_TOOL_PATHS}"
    for cand in "${raw[@]}"; do
      [[ -n "$cand" ]] || continue
      candidates+=("STEAM_COMPAT_TOOL_PATHS|${cand}")
    done
  fi
  [[ -n "${PROTONPATH:-}" ]] && candidates+=("PROTONPATH|${PROTONPATH}")
  [[ -n "${PROTON_PATH:-}" ]] && candidates+=("PROTON_PATH|${PROTON_PATH}")

  for raw in "${candidates[@]}"; do
    cand="${raw#*|}"
    [[ -d "$cand" ]] || continue
    if command -v realpath >/dev/null 2>&1; then
      normalized="$(realpath -m -- "$cand" 2>/dev/null || printf '%s' "$cand")"
    else
      normalized="$cand"
    fi
    genvw_proton_tree_is_cachyos "$normalized" || continue
    [[ -n "$out_root_var" ]] && printf -v "$out_root_var" '%s' "$normalized"
    [[ -n "$out_reason_var" ]] && printf -v "$out_reason_var" '%s' "runtime_tool_path:${raw%%|*}"
    return 0
  done

  return 1
}

genvw_dxvk_explicit_tool_root() {
  local out_root_var="${1:-}" out_reason_var="${2:-}" tool_root="" normalized_root=""
  tool_root="${GENVW_PROTON_TOOL_ROOT:-}"
  [ -n "$tool_root" ] || return 1
  [ -d "$tool_root" ] || return 1
  if command -v realpath >/dev/null 2>&1; then
    normalized_root="$(realpath -m -- "$tool_root" 2>/dev/null || printf '%s' "$tool_root")"
  else
    normalized_root="$tool_root"
  fi
  genvw_proton_tree_is_cachyos "$normalized_root" || return 1
  [[ -n "$out_root_var" ]] && printf -v "$out_root_var" '%s' "$normalized_root"
  [[ -n "$out_reason_var" ]] && printf -v "$out_reason_var" '%s' "explicit_tool_root"
  return 0
}

genvw_dxvk_explicit_build_date() {
  local out_var="${1:-}" override_build_date="${GENVW_PROTON_BUILD_DATE:-}"
  [[ "$override_build_date" =~ ^[0-9]{8}$ ]] || return 1
  [[ -n "$out_var" ]] && printf -v "$out_var" '%s' "$override_build_date"
  return 0
}

genvw_dxvk_guard_bypass_enabled() {
  [ "${GENVW_ALLOW_UNRESOLVED_VERSIONED_DXVK:-0}" = "1" ]
}

genvw_dxvk_has_authoritative_runtime_context() {
  local _root="" _reason=""
  genvw_dxvk_runtime_tool_root _root _reason
}

genvw_dxvk_has_trusted_override() {
  local _root="" _reason="" _build_date=""
  genvw_dxvk_explicit_tool_root _root _reason && return 0
  genvw_dxvk_explicit_build_date _build_date && return 0
  return 1
}

genvw_guard_versioned_dxvk_runtime() {
  local val="${GPLASYNC:-}"
  [ -n "$val" ] && [ "$val" != "0" ] || return 0

  genvw_dxvk_guard_bypass_enabled && return 0
  genvw_dxvk_has_authoritative_runtime_context && return 0
  genvw_dxvk_has_trusted_override && return 0

  err "gENVW: blocked version-sensitive DXVK mode outside a resolved Proton-CachyOS runtime."
  msg "Reason: GPLASYNC depends on the active Proton-CachyOS generation." >&2
  msg "Allowed:" >&2
  msg "  - launch from Steam through genvw" >&2
  msg "  - set GENVW_PROTON_BUILD_DATE=YYYYMMDD" >&2
  msg "  - set GENVW_PROTON_TOOL_ROOT=/path/to/proton-cachyos-..." >&2
  msg "Override:" >&2
  msg "  - GENVW_ALLOW_UNRESOLVED_VERSIONED_DXVK=1" >&2
  return 1
}

genvw_dxvk_resolve_target() {
  local root="" build_date="" reason="" expected="" probe="" final="" warn_note="" kv=""

  if [ "${GENVW_DXVK_TARGET_READY:-0}" = "1" ]; then
    return 0
  fi

  GENVW_DXVK_TARGET_ROOT=""
  GENVW_DXVK_TARGET_MAJOR=""
  GENVW_DXVK_TARGET_BUILD_DATE=""
  GENVW_DXVK_TARGET_REASON="unresolved"
  GENVW_DXVK_TARGET_EXPECTED_POLICY="unknown_or_unsupported"
  GENVW_DXVK_TARGET_PROBE_POLICY=""
  GENVW_DXVK_TARGET_POLICY="unknown_or_unsupported"
  GENVW_DXVK_TARGET_WARN=""

  if genvw_dxvk_runtime_tool_root root reason; then
    build_date="$(genvw_proton_source_build_date_from_root "$root" 2>/dev/null || true)"
  elif genvw_dxvk_explicit_tool_root root reason; then
    build_date="$(genvw_proton_source_build_date_from_root "$root" 2>/dev/null || true)"
  elif genvw_dxvk_explicit_build_date build_date; then
    reason="explicit_build_date"
  else
    kv="$(genvw_helper_check_kv_cached)"
    root="$(genvw_kv_get_optional_unique "$kv" "PROTON_DXVK_TARGET_ROOT" 2>/dev/null || true)"
    build_date="$(genvw_kv_get_optional_unique "$kv" "PROTON_DXVK_TARGET_BUILD_DATE" 2>/dev/null || true)"
    reason="$(genvw_kv_get_optional_unique "$kv" "PROTON_DXVK_TARGET_REASON" 2>/dev/null || true)"
    expected="$(genvw_kv_get_optional_unique "$kv" "PROTON_DXVK_EXPECTED_POLICY" 2>/dev/null || true)"
    probe="$(genvw_kv_get_optional_unique "$kv" "PROTON_DXVK_PROBE_POLICY" 2>/dev/null || true)"
    final="$(genvw_kv_get_optional_unique "$kv" "PROTON_DXVK_POLICY" 2>/dev/null || true)"
    warn_note="$(genvw_kv_get_optional_unique "$kv" "PROTON_DXVK_POLICY_WARN" 2>/dev/null || true)"
    if [[ -z "$build_date" ]]; then
      build_date="$(genvw_kv_get_optional_unique "$kv" "PROTON_BUILD_DATE" 2>/dev/null || true)"
    fi
  fi

  [[ -n "$expected" ]] || expected="$(genvw_dxvk_policy_for_build_date "$build_date")"
  if [[ -z "$probe" && -n "$root" ]]; then
    probe="$(genvw_dxvk_probe_tree_policy "$root" 2>/dev/null || true)"
  fi
  if [[ -n "$probe" && "$probe" != "unknown_or_unsupported" ]]; then
    final="$probe"
    if [[ -z "$warn_note" && "$expected" != "unknown_or_unsupported" && "$probe" != "$expected" ]]; then
      warn_note="date ${build_date} expected ${expected}, probe found ${probe}"
    fi
  elif [[ -z "$final" ]]; then
    final="$expected"
  fi
  [[ -n "$reason" ]] || reason="unresolved"
  [[ -n "$expected" ]] || expected="unknown_or_unsupported"
  [[ -n "$final" ]] || final="unknown_or_unsupported"

  GENVW_DXVK_TARGET_ROOT="$root"
  GENVW_DXVK_TARGET_MAJOR="$(genvw_proton_source_major_from_root "$root" 2>/dev/null || true)"
  GENVW_DXVK_TARGET_BUILD_DATE="$build_date"
  GENVW_DXVK_TARGET_REASON="$reason"
  GENVW_DXVK_TARGET_EXPECTED_POLICY="$expected"
  GENVW_DXVK_TARGET_PROBE_POLICY="$probe"
  GENVW_DXVK_TARGET_POLICY="$final"
  GENVW_DXVK_TARGET_WARN="$warn_note"
  GENVW_DXVK_TARGET_READY=1
}

genvw_dxvk_policy_warn_once() {
  genvw_dxvk_resolve_target
  if [ -n "${GENVW_DXVK_TARGET_WARN:-}" ] && [ "${GENVW_DXVK_WARNED_MISMATCH:-0}" != "1" ]; then
    warn "gENVW: DXVK policy probe overrode the date-based expectation (${GENVW_DXVK_TARGET_WARN})."
    GENVW_DXVK_WARNED_MISMATCH=1
  fi
}

# select a concrete FSR4 version string from env (or empty)
genvw_fsr4_guess_selected_ver() {
  local v=""
  local gen=""
  gen="$(detect_rdna_gen 2>/dev/null || printf '0')"

  if genvw_fsr4_is_legacy_4x_triplet "${PROTON_FSR4_RDNA3_UPGRADE:-}"; then
    v="$PROTON_FSR4_RDNA3_UPGRADE"
  fi
  if [ -z "$v" ]; then
    if genvw_fsr4_is_legacy_4x_triplet "${PROTON_FSR4_UPGRADE:-}"; then
      v="$PROTON_FSR4_UPGRADE"
    fi
  fi

  if [ -z "$v" ]; then
    if genvw_fsr4_is_legacy_4x_triplet "${FSR4_RDNA3:-}"; then
      v="$FSR4_RDNA3"
    else
      case "${FSR4_RDNA3:-}" in
        1 ) v="$(genvw_fsr4_default_remote_for_gen 3)" ;;
        0|off|OFF ) v="" ;;
      esac
    fi
  fi
  if [ -z "$v" ]; then
    if genvw_fsr4_is_legacy_4x_triplet "${FSR4:-}"; then
      v="$FSR4"
    else
      case "${FSR4:-}" in
        1 ) v="$(genvw_fsr4_default_remote_for_gen "$gen")" ;;
        0|off|OFF ) v="" ;;
      esac
    fi
  fi

  printf '%s\n' "$v"
}

# read the effective FSR4 selection from the current wizard launch-env string.
# this avoids stale shell env values influencing wizard-only follow-up prompts.
genvw_fsr4_selected_from_launch_env() {
  local launch_env="${1:-}"
  local -a toks=()
  local tok="" selected=""

  read -r -a toks <<<"$launch_env"
  for tok in "${toks[@]}"; do
    case "$tok" in
      FSR4=*) selected="${tok#FSR4=}" ;;
      FSR4_RDNA3=*) selected="${tok#FSR4_RDNA3=}" ;;
    esac
  done

  printf '%s\n' "$selected"
}

genvw_fsr4_choice_is_active() {
  case "${1:-}" in
    "" | 0 | off | OFF) return 1 ;;
    *) return 0 ;;
  esac
}

genvw_fsr4_launch_env_is_active() {
  local selected=""
  selected="$(genvw_fsr4_selected_from_launch_env "${1:-}")"
  genvw_fsr4_choice_is_active "$selected"
}

genvw_launch_env_has_key() {
  local launch_env="${1:-}"
  local key="${2:-}"
  local -a toks=()
  local tok=""

  [[ -n "$key" ]] || return 1
  read -r -a toks <<<"$launch_env"
  for tok in "${toks[@]}"; do
    case "$tok" in
      "$key="*) return 0 ;;
    esac
  done
  return 1
}

genvw_launch_env_drop_key() {
  local launch_env="${1:-}"
  local key="${2:-}"
  local -a toks=()
  local tok="" out=""

  [[ -n "$key" ]] || {
    printf '%s\n' "$launch_env"
    return 0
  }

  read -r -a toks <<<"$launch_env"
  for tok in "${toks[@]}"; do
    case "$tok" in
      "$key="*) continue ;;
      *)
        out="${out:+$out }$tok"
        ;;
    esac
  done

  printf '%s\n' "$out"
}

genvw_launch_env_profile_lines() {
  local launch_env="${1:-}"
  local -a toks=()
  local tok="" key="" val=""
  declare -A profile_map=()

  read -r -a toks <<<"$launch_env"
  for tok in "${toks[@]}"; do
    if [[ ! "$tok" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      continue
    fi
    key="${BASH_REMATCH[1]}"
    val="${BASH_REMATCH[2]}"
    if ! genvw_profile_key_allowed "$key"; then
      continue
    fi
    profile_map["$key"]="$val"
  done

  for key in $GENVW_PROFILE_ALLOWED_KEYS; do
    [ -n "${profile_map[$key]+set}" ] && printf '%s=%s\n' "$key" "${profile_map[$key]}"
  done
}

genvw_wizard_offer_profile_save() {
  local launch_env="${1:-}"
  local script_path_print="${2:-genvw}"
  local profile_name=""
  local -a profile_args=()

  [ -n "$launch_env" ] || return 0

  if ! ask_yes_no_default "${YELLOW}Save this setup as a profile? [y/N]: ${RESET}" "n"; then
    return 0
  fi

  mapfile -t profile_args < <(genvw_launch_env_profile_lines "$launch_env")
  if [ "${#profile_args[@]}" -eq 0 ]; then
    warn "gENVW: no profile-compatible knobs were selected; skipping profile save."
    return 0
  fi

  while :; do
    printf "%s" "${YELLOW}Profile name (empty to cancel): ${RESET}"
    tty_read profile_name || profile_name=""
    profile_name="$(trim_outer_ws "$profile_name")"

    if [ -z "$profile_name" ]; then
      err "gENVW profile save: cancelled."
      return 0
    fi
    if ! genvw_profile_name_ok "$profile_name"; then
      err "gENVW: invalid profile name '$profile_name'"
      continue
    fi

    if genvw_profile_save "$profile_name" "0" "${profile_args[@]}"; then
      echo
      printf "%s\n" "${BOLD}${CYAN} === Saved profile launch options === ${RESET}"
      echo
      printf "%s\n" "${ORANGE}$script_path_print${RESET} ${WHITE}--profile${RESET} ${GREEN}$profile_name${RESET} ${WHITE}%command%${RESET}"
      echo
      info "Use the shorter line above to launch this saved profile."
      return 0
    fi

    printf "%s\n\n" "${CYAN}Try another profile name, or press Enter to skip saving.${RESET}"
  done
}

# gENVW cache root (XDG). genvw_proton.sh uses this for AMD driver download/extract.
export GENVW_CACHE_DIR="${GENVW_CACHE_DIR:-${XDG_CACHE_HOME:-${HOME}/.cache}/genvw}"
# SECURITY: wrapper-side path sanity before any consumer composes $GENVW_CACHE_DIR/...
# Helper-side validate_cache_dir in genvw_proton.sh still applies on its own call sites.
validate_dir_env "$GENVW_CACHE_DIR" "GENVW_CACHE_DIR"

# absolute directory containing this script (resolves symlinks)
genvw_script_dir() {
  local src="${BASH_SOURCE[0]:-$0}"
  if command -v readlink >/dev/null 2>&1; then
    src="$(readlink -f -- "$src" 2>/dev/null || printf '%s' "$src")"
  fi
  (cd -- "$(dirname -- "$src")" >/dev/null 2>&1 && pwd -P)
}

# genvw_abspath
# Resolve a path to an absolute path (stable compares/logs).

# genvw_abspath
# turn a path into an absolute path (handy for compares/logs).

genvw_abspath() {
  # absolute path for "$1" without hard deps on readlink/realpath.
  local p="${1:-}" dir base pv

  [ -z "$p" ] && return 1

  # readlink/realpath path if present.
  if command -v readlink >/dev/null 2>&1; then
    readlink -f -- "$p" 2>/dev/null && return 0
  fi
  if command -v realpath >/dev/null 2>&1; then
    realpath -- "$p" 2>/dev/null && return 0
  fi

  # already absolute.
  case "$p" in
    /*)
      printf '%s\n' "$p"
      return 0
      ;;
  esac

  # has a slash: resolve via cd + pwd -P.
  case "$p" in
    */*)
      dir="${p%/*}"
      base="${p##*/}"
      (cd -- "$dir" 2>/dev/null && printf '%s/%s\n' "$(pwd -P)" "$base") && return 0
      ;;
  esac

  # bare name: look it up in PATH, then absolutize that.
  pv="$(command -v -- "$p" 2>/dev/null || true)"
  if [ -n "$pv" ] && [ "$pv" != "$p" ]; then
    genvw_abspath "$pv" && return 0
  fi

  # last one: join to current dir.
  p="${p#./}"
  printf '%s/%s\n' "$(pwd -P)" "$p"
  return 0
}

# genvw_data_home
# gENVW data root (xdg_data_home fallback).

genvw_data_home() {
  printf '%s' "${XDG_DATA_HOME:-$HOME/.local/share}"
}

# genvw_asset_root_candidates
# asset roots to try (override -> installed -> portable tree).

genvw_asset_root_candidates() {
  local d

  # explicit override.
  if [[ -n "${GENVW_ASSET_DIR:-}" ]]; then
    printf '%s\n' "$GENVW_ASSET_DIR"
  fi

  # installed.
  printf '%s\n' "$(genvw_data_home)/genvw"

  # portable: bin/../share/genvw.
  d="$(genvw_script_dir)"
  printf '%s\n' "$d/../share/genvw"
}

# genvw_asset_path
# resolve a relative asset path and print the first match.

genvw_asset_path() {
  local rel="$1"
  local root

  while IFS= read -r root; do
    [[ -z "$root" ]] && continue

    # let GENVW_ASSET_DIR point to share/genvw or directly to .../assets.
    if [[ -f "$root/$rel" ]]; then
      printf '%s' "$root/$rel"
      return 0
    fi
    if [[ "$rel" == assets/* ]] && [[ -f "$root/${rel#assets/}" ]]; then
      printf '%s' "$root/${rel#assets/}"
      return 0
    fi
  done < <(genvw_asset_root_candidates)

  return 1
}

# tty_read
# read one line from /dev/tty, then fall back to stdin.

tty_read() {
  local __var="$1"
  local __tmp=""
  local ttybuf="" ttyrc=1

  # /dev/tty read is inside a stderr-silenced cmdsub, so setsid/no-ctty stays quiet.
  ttybuf="$({ IFS= read -r line </dev/tty && printf '%s' "$line"; } 2>/dev/null)"
  ttyrc=$?
  if [ "$ttyrc" -eq 0 ]; then
    printf -v "$__var" '%s' "$ttybuf"
    return 0
  fi

  if ! IFS= read -r __tmp; then
    return 1
  fi
  printf -v "$__var" '%s' "$__tmp"
  return 0
}

# tty capability check:
# - stdin must be interactive
# - prompt output must be possible via stderr tty or /dev/tty
genvw_tty_io_ready() {
  [ -t 0 ] || return 1
  [ -t 2 ] && return 0
  [ -r /dev/tty ] && [ -w /dev/tty ]
}

# trim
# normalize simple user input whitespace.

trim() {
  printf '%s' "$1" | awk '{$1=$1;print}'
}

# trim_outer_ws
# trim only leading/trailing whitespace; keep internal spacing unchanged.

trim_outer_ws() {
  local s="${1-}"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# genvw_kv_get
# return the first value for KEY from helper KV output.

genvw_kv_get() {
  local kv="${1:-}" key="${2:-}"
  printf '%s\n' "$kv" | sed -nE "s/^${key}=//p" | head -n1
}

# genvw_kv_count
# count KEY occurrences in helper KV output.

genvw_kv_count() {
  local kv="${1:-}" key="${2:-}"
  printf '%s\n' "$kv" | grep -c "^${key}=" || true
}

# genvw_kv_get_one
# return KEY value only when the key occurs exactly once.

genvw_kv_get_one() {
  local kv="${1:-}" key="${2:-}"
  local n
  n="$(genvw_kv_count "$kv" "$key")"
  [[ "$n" == "1" ]] || return 1
  genvw_kv_get "$kv" "$key"
}

# genvw_kv_get_optional_unique
# return KEY value when present exactly once; succeed with empty output when absent.
# fail when duplicated.

genvw_kv_get_optional_unique() {
  local kv="${1:-}" key="${2:-}"
  local n
  n="$(genvw_kv_count "$kv" "$key")"
  case "$n" in
    0) return 0 ;;
    1) genvw_kv_get "$kv" "$key"; return 0 ;;
    *) return 1 ;;
  esac
}

genvw_probe_runtime_local_default_from_helper() {
  local kv="" schema="" localdll=""

  kv="$(run_proton_internal_check_kv 2>/dev/null || true)"
  schema="$(genvw_kv_get_one "$kv" "KV_SCHEMA" 2>/dev/null || true)"
  if [[ "$schema" == "1" ]]; then
    localdll="$(genvw_kv_get_one "$kv" "LOCALDLL" 2>/dev/null || true)"
    if genvw_fsr4_refresh_runtime_local_default_from_localdll "$localdll"; then
      printf '%s\n' "$(genvw_fsr4_effective_local_default_ver)"
      return 0
    fi
  fi

  genvw_fsr4_set_runtime_local_default "$GENVW_FSR4_WIZARD_LOCAL_DEFAULT" "preferred_default"
  printf '%s\n' "$(genvw_fsr4_effective_local_default_ver)"
  return 1
}

genvw_helper_check_kv_cached() {
  if [ "${GENVW_HELPER_KV_CACHE_READY:-0}" != "1" ]; then
    GENVW_HELPER_KV_CACHE="$(run_proton_internal_check_kv 2>/dev/null || true)"
    GENVW_HELPER_KV_CACHE_READY=1
  fi
  printf '%s\n' "${GENVW_HELPER_KV_CACHE:-}"
}

# genvw_parse_tool_state_kv
# strict parser for helper KV fields used by tool-state checks.
# args:
#   $1 = kv text
#   $2 = output var name for CTD_EXISTS
#   $3 = output var name for TOOLS_FOUND
#   $4 = output var name for reason on failure

genvw_parse_tool_state_kv() {
  local kv="${1:-}" out_ctd_var="${2:-}" out_tools_var="${3:-}" out_reason_var="${4:-}"
  local parsed_ctd_exists="" parsed_tools_found="" fail_reason="" schema=""
  local kv_ok=1

  schema="$(genvw_kv_get_one "$kv" "KV_SCHEMA" 2>/dev/null || true)"
  if [[ "$schema" != "1" ]]; then
    kv_ok=0
    fail_reason="missing_or_duplicate KV schema"
  fi

  if [ "$kv_ok" -eq 1 ]; then
    parsed_ctd_exists="$(genvw_kv_get_one "$kv" "CTD_EXISTS" 2>/dev/null || true)"
    parsed_tools_found="$(genvw_kv_get_one "$kv" "TOOLS_FOUND" 2>/dev/null || true)"
    if [[ -z "$parsed_ctd_exists" ]]; then
      kv_ok=0
      fail_reason="missing_or_duplicate CTD_EXISTS"
    elif [[ -z "$parsed_tools_found" ]]; then
      kv_ok=0
      fail_reason="missing_or_duplicate TOOLS_FOUND"
    fi
  fi

  if [ "$kv_ok" -eq 1 ]; then
    case "$parsed_ctd_exists" in
      0 | 1) ;;
      *)
        kv_ok=0
        fail_reason="invalid CTD_EXISTS"
        ;;
    esac
    case "$parsed_tools_found" in
      '' | *[!0-9]*)
        kv_ok=0
        fail_reason="invalid TOOLS_FOUND"
        ;;
    esac
  fi

  if [ "$kv_ok" -eq 1 ]; then
    [ -n "$out_ctd_var" ] && printf -v "$out_ctd_var" '%s' "$parsed_ctd_exists"
    [ -n "$out_tools_var" ] && printf -v "$out_tools_var" '%s' "$parsed_tools_found"
    [ -n "$out_reason_var" ] && printf -v "$out_reason_var" ''
    return 0
  fi

  [ -n "$out_ctd_var" ] && printf -v "$out_ctd_var" '0'
  [ -n "$out_tools_var" ] && printf -v "$out_tools_var" '0'
  [ -n "$out_reason_var" ] && printf -v "$out_reason_var" '%s' "${fail_reason:-unknown}"
  return 1
}

# genvw_parse_preflight_kv
# strict parser for helper KV fields used by wrapper preflight.
# args:
#   $1 = kv text
#   $2 = output var name for CTD
#   $3 = output var name for SUFFIX
#   $4 = output var name for LOCALDLL
#   $5 = output var name for STEAM_ROOT
#   $6 = output var name for MAJOR
#   $7 = output var name for CTD_EXISTS
#   $8 = output var name for TOOLS_FOUND
#   $9 = output var name for DLL_PRESENT
#  $10 = output var name for DLL_SIZE
#  $11 = output var name for DLL_SHA256
#  $12 = output var name for PROTON_SOURCES_COUNT
#  $13 = output var name for PROTON build date
#  $14 = output var name for reason on failure

genvw_parse_preflight_kv() {
  local kv="${1:-}" out_ctd_var="${2:-}" out_suffix_var="${3:-}" out_localdll_var="${4:-}"
  local out_steam_root_var="${5:-}" out_major_var="${6:-}" out_ctd_exists_var="${7:-}" out_tools_found_var="${8:-}"
  local out_dll_present_var="${9:-}" out_dll_size_var="${10:-}" out_dll_sha_var="${11:-}"
  local out_sources_count_var="${12:-}" out_proton_build_date_var="${13:-}" out_reason_var="${14:-}"
  local parsed_ctd="" parsed_suffix="" parsed_localdll="" parsed_steam_root="" parsed_major=""
  local parsed_ctd_exists="" parsed_tools_found="" parsed_dll_present="" parsed_dll_size="" parsed_dll_sha=""
  local parsed_sources_count="" parsed_proton_build_date="" fail_reason="" need_k="" schema=""

  schema="$(genvw_kv_get_one "$kv" "KV_SCHEMA" 2>/dev/null || true)"
  if [[ "$schema" != "1" ]]; then
    fail_reason="missing_or_duplicate KV schema"
    [ -n "$out_reason_var" ] && printf -v "$out_reason_var" '%s' "$fail_reason"
    return 1
  fi

  for need_k in CTD SUFFIX LOCALDLL CTD_EXISTS TOOLS_FOUND; do
    if ! genvw_kv_get_one "$kv" "$need_k" >/dev/null 2>&1; then
      fail_reason="missing_or_duplicate ${need_k}"
      [ -n "$out_reason_var" ] && printf -v "$out_reason_var" '%s' "$fail_reason"
      return 1
    fi
  done

  parsed_ctd="$(genvw_kv_get_one "$kv" "CTD" 2>/dev/null || true)"
  parsed_suffix="$(genvw_kv_get_one "$kv" "SUFFIX" 2>/dev/null || true)"
  parsed_localdll="$(genvw_kv_get_one "$kv" "LOCALDLL" 2>/dev/null || true)"
  parsed_ctd_exists="$(genvw_kv_get_one "$kv" "CTD_EXISTS" 2>/dev/null || true)"
  parsed_tools_found="$(genvw_kv_get_one "$kv" "TOOLS_FOUND" 2>/dev/null || true)"

  [ -n "$out_ctd_var" ] && printf -v "$out_ctd_var" '%s' "$parsed_ctd"
  [ -n "$out_suffix_var" ] && printf -v "$out_suffix_var" '%s' "$parsed_suffix"
  [ -n "$out_localdll_var" ] && printf -v "$out_localdll_var" '%s' "$parsed_localdll"
  [ -n "$out_ctd_exists_var" ] && printf -v "$out_ctd_exists_var" '%s' "$parsed_ctd_exists"
  [ -n "$out_tools_found_var" ] && printf -v "$out_tools_found_var" '%s' "$parsed_tools_found"

  if ! parsed_steam_root="$(genvw_kv_get_optional_unique "$kv" "STEAM_ROOT")"; then
    fail_reason="duplicate STEAM_ROOT"
    [ -n "$out_reason_var" ] && printf -v "$out_reason_var" '%s' "$fail_reason"
    return 1
  fi
  [ -n "$out_steam_root_var" ] && printf -v "$out_steam_root_var" '%s' "$parsed_steam_root"

  if ! parsed_major="$(genvw_kv_get_optional_unique "$kv" "MAJOR")"; then
    fail_reason="duplicate MAJOR"
    [ -n "$out_reason_var" ] && printf -v "$out_reason_var" '%s' "$fail_reason"
    return 1
  fi
  [ -n "$out_major_var" ] && printf -v "$out_major_var" '%s' "$parsed_major"

  if ! parsed_dll_present="$(genvw_kv_get_optional_unique "$kv" "DLL_PRESENT")"; then
    fail_reason="duplicate DLL_PRESENT"
    [ -n "$out_reason_var" ] && printf -v "$out_reason_var" '%s' "$fail_reason"
    return 1
  fi
  [ -n "$out_dll_present_var" ] && printf -v "$out_dll_present_var" '%s' "$parsed_dll_present"

  if ! parsed_dll_size="$(genvw_kv_get_optional_unique "$kv" "DLL_SIZE")"; then
    fail_reason="duplicate DLL_SIZE"
    [ -n "$out_reason_var" ] && printf -v "$out_reason_var" '%s' "$fail_reason"
    return 1
  fi
  [ -n "$out_dll_size_var" ] && printf -v "$out_dll_size_var" '%s' "$parsed_dll_size"

  if ! parsed_dll_sha="$(genvw_kv_get_optional_unique "$kv" "DLL_SHA256")"; then
    fail_reason="duplicate DLL_SHA256"
    [ -n "$out_reason_var" ] && printf -v "$out_reason_var" '%s' "$fail_reason"
    return 1
  fi
  [ -n "$out_dll_sha_var" ] && printf -v "$out_dll_sha_var" '%s' "$parsed_dll_sha"

  if ! parsed_sources_count="$(genvw_kv_get_optional_unique "$kv" "PROTON_SOURCES_COUNT")"; then
    fail_reason="duplicate PROTON_SOURCES_COUNT"
    [ -n "$out_reason_var" ] && printf -v "$out_reason_var" '%s' "$fail_reason"
    return 1
  fi
  [ -n "$out_sources_count_var" ] && printf -v "$out_sources_count_var" '%s' "$parsed_sources_count"

  if ! parsed_proton_build_date="$(genvw_kv_get_optional_unique "$kv" "PROTON_DXVK_TARGET_BUILD_DATE")"; then
    fail_reason="duplicate PROTON_DXVK_TARGET_BUILD_DATE"
    [ -n "$out_reason_var" ] && printf -v "$out_reason_var" '%s' "$fail_reason"
    return 1
  elif [[ -z "$parsed_proton_build_date" ]]; then
    if ! parsed_proton_build_date="$(genvw_kv_get_optional_unique "$kv" "PROTON_BUILD_DATE")"; then
      fail_reason="duplicate PROTON_BUILD_DATE"
      [ -n "$out_reason_var" ] && printf -v "$out_reason_var" '%s' "$fail_reason"
      return 1
    fi
  fi
  [ -n "$out_proton_build_date_var" ] && printf -v "$out_proton_build_date_var" '%s' "$parsed_proton_build_date"

  case "${parsed_ctd_exists:-}" in
    0 | 1) ;;
    *)
      fail_reason="invalid CTD_EXISTS"
      [ -n "$out_reason_var" ] && printf -v "$out_reason_var" '%s' "$fail_reason"
      return 1
      ;;
  esac
  case "${parsed_dll_present:-}" in
    '' | 0 | 1) ;;
    *)
      fail_reason="invalid DLL_PRESENT"
      [ -n "$out_reason_var" ] && printf -v "$out_reason_var" '%s' "$fail_reason"
      return 1
      ;;
  esac
  case "${parsed_tools_found:-}" in
    '' | *[!0-9]*)
      fail_reason="invalid TOOLS_FOUND"
      [ -n "$out_reason_var" ] && printf -v "$out_reason_var" '%s' "$fail_reason"
      return 1
      ;;
  esac
  case "${parsed_sources_count:-}" in
    '' | *[!0-9]*)
      fail_reason="invalid PROTON_SOURCES_COUNT"
      [ -n "$out_reason_var" ] && printf -v "$out_reason_var" '%s' "$fail_reason"
      return 1
      ;;
  esac

  [ -n "$out_reason_var" ] && printf -v "$out_reason_var" '%s' ''
  return 0
}

# genvw_parse_fsr4_local_trust_kv
# strict parser for helper KV fields used by the local FSR4 trust guard.
# args:
#   $1 = kv text
#   $2 = output var name for DLL_PRESENT
#   $3 = output var name for META_PRESENT
#   $4 = output var name for META_MATCH
#   $5 = output var name for META_MATCH_REASON
#   $6 = output var name for ALLOWLIST_MATCH
#   $7 = output var name for ALLOWLIST_MATCH_REASON
#   $8 = output var name for ALLOWLIST_PATH
#   $9 = output var name for DLL_SHA256
#  $10 = output var name for DLL_SIZE

genvw_parse_fsr4_local_trust_kv() {
  local kv="${1:-}" out_dll_present_var="${2:-}" out_meta_present_var="${3:-}" out_meta_match_var="${4:-}"
  local out_reason_var="${5:-}" out_allow_match_var="${6:-}" out_allow_reason_var="${7:-}"
  local out_allow_path_var="${8:-}" out_dll_sha_var="${9:-}" out_dll_size_var="${10:-}"
  local parsed_dll_present="" parsed_meta_present="" parsed_meta_match="" parsed_reason=""
  local parsed_allow_match="" parsed_allow_reason="" parsed_allow_path="" parsed_dll_sha="" parsed_dll_size=""
  local fail_reason="" schema="" kv_ok=1 _k=""

  schema="$(genvw_kv_get_one "$kv" "KV_SCHEMA" 2>/dev/null || true)"
  if [[ "$schema" != "1" ]]; then
    kv_ok=0
    fail_reason="kv_schema_missing_or_duplicate"
  fi

  if [ "$kv_ok" -eq 1 ]; then
    for _k in DLL_PRESENT META_MATCH ALLOWLIST_MATCH; do
      if ! genvw_kv_get_one "$kv" "$_k" >/dev/null 2>&1; then
        kv_ok=0
        fail_reason="kv_missing_or_duplicate_${_k}"
        break
      fi
    done
  fi

  if [ "$kv_ok" -eq 1 ]; then
    parsed_dll_present="$(genvw_kv_get_one "$kv" "DLL_PRESENT" 2>/dev/null || true)"
    parsed_meta_match="$(genvw_kv_get_one "$kv" "META_MATCH" 2>/dev/null || true)"
    parsed_allow_match="$(genvw_kv_get_one "$kv" "ALLOWLIST_MATCH" 2>/dev/null || true)"

    if ! parsed_meta_present="$(genvw_kv_get_optional_unique "$kv" "META_PRESENT")"; then
      kv_ok=0
      fail_reason="kv_duplicate_META_PRESENT"
    fi
    if ! parsed_reason="$(genvw_kv_get_optional_unique "$kv" "META_MATCH_REASON")"; then
      kv_ok=0
      fail_reason="kv_duplicate_META_MATCH_REASON"
    fi
    if ! parsed_allow_reason="$(genvw_kv_get_optional_unique "$kv" "ALLOWLIST_MATCH_REASON")"; then
      kv_ok=0
      fail_reason="kv_duplicate_ALLOWLIST_MATCH_REASON"
    fi
    if ! parsed_allow_path="$(genvw_kv_get_optional_unique "$kv" "ALLOWLIST_PATH")"; then
      kv_ok=0
      fail_reason="kv_duplicate_ALLOWLIST_PATH"
    fi
    if ! parsed_dll_sha="$(genvw_kv_get_optional_unique "$kv" "DLL_SHA256")"; then
      kv_ok=0
      fail_reason="kv_duplicate_DLL_SHA256"
    fi
    if ! parsed_dll_size="$(genvw_kv_get_optional_unique "$kv" "DLL_SIZE")"; then
      kv_ok=0
      fail_reason="kv_duplicate_DLL_SIZE"
    fi

    [[ -n "$parsed_allow_match" ]] || parsed_allow_match=0
    [[ -n "$parsed_allow_reason" ]] || parsed_allow_reason="kv_missing_allowlist"

    case "$parsed_dll_present" in
      0 | 1) ;;
      *)
        kv_ok=0
        fail_reason="kv_invalid_DLL_PRESENT"
        ;;
    esac
    case "$parsed_meta_match" in
      0 | 1) ;;
      *)
        kv_ok=0
        fail_reason="kv_invalid_META_MATCH"
        ;;
    esac
    case "$parsed_allow_match" in
      0 | 1) ;;
      *)
        kv_ok=0
        fail_reason="kv_invalid_ALLOWLIST_MATCH"
        ;;
    esac
    case "$parsed_meta_present" in
      0 | 1) ;;
      *) parsed_meta_present=0 ;;
    esac
  fi

  if [ "$kv_ok" -eq 1 ]; then
    [ -n "$out_dll_present_var" ] && printf -v "$out_dll_present_var" '%s' "$parsed_dll_present"
    [ -n "$out_meta_present_var" ] && printf -v "$out_meta_present_var" '%s' "$parsed_meta_present"
    [ -n "$out_meta_match_var" ] && printf -v "$out_meta_match_var" '%s' "$parsed_meta_match"
    [ -n "$out_reason_var" ] && printf -v "$out_reason_var" '%s' "$parsed_reason"
    [ -n "$out_allow_match_var" ] && printf -v "$out_allow_match_var" '%s' "$parsed_allow_match"
    [ -n "$out_allow_reason_var" ] && printf -v "$out_allow_reason_var" '%s' "$parsed_allow_reason"
    [ -n "$out_allow_path_var" ] && printf -v "$out_allow_path_var" '%s' "$parsed_allow_path"
    [ -n "$out_dll_sha_var" ] && printf -v "$out_dll_sha_var" '%s' "$parsed_dll_sha"
    [ -n "$out_dll_size_var" ] && printf -v "$out_dll_size_var" '%s' "$parsed_dll_size"
    return 0
  fi

  [ -n "$out_dll_present_var" ] && printf -v "$out_dll_present_var" '0'
  [ -n "$out_meta_present_var" ] && printf -v "$out_meta_present_var" '0'
  [ -n "$out_meta_match_var" ] && printf -v "$out_meta_match_var" '0'
  [ -n "$out_reason_var" ] && printf -v "$out_reason_var" '%s' "${fail_reason:-unknown}"
  [ -n "$out_allow_match_var" ] && printf -v "$out_allow_match_var" '0'
  [ -n "$out_allow_reason_var" ] && printf -v "$out_allow_reason_var" '%s' "${fail_reason:-unknown}"
  [ -n "$out_allow_path_var" ] && printf -v "$out_allow_path_var" ''
  [ -n "$out_dll_sha_var" ] && printf -v "$out_dll_sha_var" ''
  [ -n "$out_dll_size_var" ] && printf -v "$out_dll_size_var" ''
  return 1
}

# genvw_warn_untrusted_tool_state_kv
# warn once per run when helper KV cannot be trusted for tool-state decisions.

genvw_warn_untrusted_tool_state_kv() {
  local reason="${1:-unknown}"
  if [ "${GENVW_KV_TOOL_STATE_WARNED:-0}" = "1" ]; then
    return 0
  fi
  GENVW_KV_TOOL_STATE_WARNED=1
  warn "gENVW: helper KV contract mismatch (${reason}); tool state is unknown." >&2
  warn "gENVW: skipping automatic tool-build prompts for this run. Run: genvw proton check --kv" >&2
  return 0
}

# ask_yes_no
# strict y/n prompt (returns 0 for yes, 1 for no).

ask_yes_no() {
  local ans
  while :; do
    printf "%s" "$1"

    # prefer /dev/tty so this works even when stdin is redirected
    if ! tty_read ans; then
      return 1
    fi

    ans=$(trim "$ans")
    case "$ans" in
      y | Y) return 0 ;;
      n | N) return 1 ;;
      *)
        printf "%s\n\n" "${RED}Type y or n.${RESET}"
        ;;
    esac
  done
}

# ask_yes_no_default
# y/n prompt with default fallback ("y" or "n").

ask_yes_no_default() {
  local prompt="$1"
  local default="$2" # "y" or "n"
  local ans
  while :; do
    printf "%s" "$prompt"
    # prefer /dev/tty so this works even when stdin is redirected
    tty_read ans || ans=""
    ans="$(trim "$ans")"
    [ -z "$ans" ] && ans="$default"
    case "$ans" in
      y | Y) return 0 ;;
      n | N) return 1 ;;
    esac
    printf "%s\n" "Type y or n." >&2
  done
}

genvw_gamescope_install_url() {
  printf '%s\n' "https://github.com/ValveSoftware/gamescope"
}

genvw_gamescope_print_install_hint() {
  msg "Install hint:"
  msg "  sudo pacman -S gamescope"
  msg "Official:"
  msg "  $(genvw_gamescope_install_url)"
}

genvw_dxvk_config_append() {
  local entry="$1"
  if [ -n "${DXVK_CONFIG:-}" ]; then
    export DXVK_CONFIG="${DXVK_CONFIG}; ${entry}"
  else
    export DXVK_CONFIG="${entry}"
  fi
}

genvw_vkd3d_config_append_flag() {
  local flag="$1" item="" found=0 had_noglob=0
  local IFS=',;'
  case "$-" in
    *f*) had_noglob=1 ;;
  esac
  set -f
  for item in ${VKD3D_CONFIG:-}; do
    item="$(trim_outer_ws "$item")"
    [ -n "$item" ] || continue
    if [ "$item" = "$flag" ]; then
      found=1
      break
    fi
  done
  [ "$had_noglob" = "1" ] || set +f
  [ "$found" = "1" ] && return 0
  if [ -n "${VKD3D_CONFIG:-}" ]; then
    export VKD3D_CONFIG="${VKD3D_CONFIG},${flag}"
  else
    export VKD3D_CONFIG="${flag}"
  fi
}

genvw_vkd3d_config_remove_flags() {
  local item="" keep="" skip=0 drop="" had_noglob=0
  local IFS=',;'
  case "$-" in
    *f*) had_noglob=1 ;;
  esac
  set -f
  for item in ${VKD3D_CONFIG:-}; do
    item="$(trim_outer_ws "$item")"
    [ -n "$item" ] || continue
    skip=0
    for drop in "$@"; do
      if [ "$item" = "$drop" ]; then
        skip=1
        break
      fi
    done
    [ "$skip" = "1" ] && continue
    case ",${keep}," in
      *,"${item}",*) ;;
      *) keep="${keep:+${keep},}${item}" ;;
    esac
  done
  [ "$had_noglob" = "1" ] || set +f
  if [ -n "$keep" ]; then
    export VKD3D_CONFIG="$keep"
  else
    unset VKD3D_CONFIG
  fi
}

genvw_lsfg_flow_is_valid() {
  local val="${1:-}"
  [[ "$val" =~ ^(0\.[0-9]+|1(\.0*)?)$ ]] || return 1
  LC_ALL=C awk -v val="$val" 'BEGIN { exit !(val >= 0.25 && val <= 1.0) }' >/dev/null 2>&1
}

genvw_lsfg_flow_normalize() {
  local val="${1:-}"
  case "$val" in
    1 | 1.0 | 1.00* ) printf '%s\n' "1.0" ;;
    *) printf '%s\n' "$val" ;;
  esac
}

genvw_gplasync_hz_is_valid() {
  case "${1:-}" in
    [1-9] | [1-9][0-9] | [1-9][0-9][0-9]) return 0 ;;
    *) return 1 ;;
  esac
}

genvw_gplasync_validate_vrr_hz() {
  local raw="${1##*vrr-}" out_var="${2:-}"
  if ! genvw_gplasync_hz_is_valid "$raw"; then
    warn "gENVW: invalid GPLASYNC VRR Hz '${raw}', ignoring."
    return 1
  fi
  [ -n "$out_var" ] && printf -v "$out_var" '%s' "$raw"
  return 0
}

genvw_dxvk_export_lowlatency_mode() {
  local env_name="${1:-}" pace_mode="${2:-}"
  [[ -n "$env_name" && -n "$pace_mode" ]] || return 1
  export "${env_name}=1"
  export DXVK_FRAME_PACE="$pace_mode"
  return 0
}

genvw_apply_gplasync_legacy_gplall() {
  local val="${1:-}" hz=""

  case "$val" in
    1)
      export PROTON_DXVK_GPLASYNC=1
      genvw_dxvk_config_append "dxvk.enableGraphicsPipelineLibrary=True"
      export DXVK_FRAME_PACE="low-latency"
      ;;
    vrr-*)
      genvw_gplasync_validate_vrr_hz "$val" hz || return 1
      export PROTON_DXVK_GPLASYNC=1
      genvw_dxvk_config_append "dxvk.enableGraphicsPipelineLibrary=True"
      export DXVK_FRAME_PACE="low-latency-vrr-${hz}"
      ;;
    on | llasync)
      export PROTON_DXVK_GPLASYNC=1
      export DXVK_FRAME_PACE="low-latency"
      ;;
    on-vrr-* | llasync-vrr-*)
      genvw_gplasync_validate_vrr_hz "$val" hz || return 1
      export PROTON_DXVK_GPLASYNC=1
      export DXVK_FRAME_PACE="low-latency-vrr-${hz}"
      ;;
    on-min | llasync-min)
      export PROTON_DXVK_GPLASYNC=1
      export DXVK_FRAME_PACE="min-latency"
      ;;
    lowlat)
      export PROTON_DXVK_GPLASYNC=1
      genvw_dxvk_config_append "dxvk.enableAsync=False"
      export DXVK_FRAME_PACE="low-latency"
      ;;
    lowlat-vrr-*)
      genvw_gplasync_validate_vrr_hz "$val" hz || return 1
      export PROTON_DXVK_GPLASYNC=1
      genvw_dxvk_config_append "dxvk.enableAsync=False"
      export DXVK_FRAME_PACE="low-latency-vrr-${hz}"
      ;;
    lowlat-min)
      export PROTON_DXVK_GPLASYNC=1
      genvw_dxvk_config_append "dxvk.enableAsync=False"
      export DXVK_FRAME_PACE="min-latency"
      ;;
    async | gplasync)
      export PROTON_DXVK_GPLASYNC=1
      export DXVK_FRAME_PACE="max-frame-latency"
      ;;
    *)
      warn "gENVW: unknown GPLASYNC value '${val}', ignoring."
      return 1
      ;;
  esac

  return 0
}

genvw_apply_gplasync_split_envs() {
  local val="${1:-}" hz=""

  case "$val" in
    on | llasync)
      genvw_dxvk_export_lowlatency_mode PROTON_DXVK_LLASYNC "low-latency"
      ;;
    on-vrr-* | llasync-vrr-*)
      genvw_gplasync_validate_vrr_hz "$val" hz || return 1
      genvw_dxvk_export_lowlatency_mode PROTON_DXVK_LLASYNC "low-latency-vrr-${hz}"
      ;;
    on-min | llasync-min)
      genvw_dxvk_export_lowlatency_mode PROTON_DXVK_LLASYNC "min-latency"
      ;;
    lowlat)
      genvw_dxvk_export_lowlatency_mode PROTON_DXVK_LOWLATENCY "low-latency"
      ;;
    lowlat-vrr-*)
      genvw_gplasync_validate_vrr_hz "$val" hz || return 1
      genvw_dxvk_export_lowlatency_mode PROTON_DXVK_LOWLATENCY "low-latency-vrr-${hz}"
      ;;
    lowlat-min)
      genvw_dxvk_export_lowlatency_mode PROTON_DXVK_LOWLATENCY "min-latency"
      ;;
    async | gplasync)
      export PROTON_DXVK_GPLASYNC=1
      ;;
    1 | vrr-*)
      warn "gENVW: GPLASYNC='${val}' is the 20260227 combined mode and is not valid on split DXVK builds."
      return 1
      ;;
    *)
      warn "gENVW: unknown GPLASYNC value '${val}', ignoring."
      return 1
      ;;
  esac

  return 0
}

genvw_apply_gplasync_lowlatency_only() {
  local val="${1:-}" hz=""

  case "$val" in
    lowlat)
      genvw_dxvk_export_lowlatency_mode PROTON_DXVK_LOWLATENCY "low-latency"
      ;;
    lowlat-vrr-*)
      genvw_gplasync_validate_vrr_hz "$val" hz || return 1
      genvw_dxvk_export_lowlatency_mode PROTON_DXVK_LOWLATENCY "low-latency-vrr-${hz}"
      ;;
    lowlat-min)
      genvw_dxvk_export_lowlatency_mode PROTON_DXVK_LOWLATENCY "min-latency"
      ;;
    on | llasync)
      warn "gENVW: GPLASYNC='${val}' maps to PROTON_DXVK_LOWLATENCY=1 on lowlatency-only builds."
      genvw_dxvk_export_lowlatency_mode PROTON_DXVK_LOWLATENCY "low-latency"
      ;;
    on-vrr-* | llasync-vrr-*)
      genvw_gplasync_validate_vrr_hz "$val" hz || return 1
      warn "gENVW: GPLASYNC='${val}' maps to PROTON_DXVK_LOWLATENCY=1 on lowlatency-only builds."
      genvw_dxvk_export_lowlatency_mode PROTON_DXVK_LOWLATENCY "low-latency-vrr-${hz}"
      ;;
    on-min | llasync-min)
      warn "gENVW: GPLASYNC='${val}' maps to PROTON_DXVK_LOWLATENCY=1 on lowlatency-only builds."
      genvw_dxvk_export_lowlatency_mode PROTON_DXVK_LOWLATENCY "min-latency"
      ;;
    1)
      warn "gENVW: GPLASYNC='1' no longer has a combined DXVK path here; using PROTON_DXVK_LOWLATENCY=1."
      genvw_dxvk_export_lowlatency_mode PROTON_DXVK_LOWLATENCY "low-latency"
      ;;
    vrr-*)
      genvw_gplasync_validate_vrr_hz "$val" hz || return 1
      warn "gENVW: GPLASYNC='${val}' no longer has a combined DXVK path here; using PROTON_DXVK_LOWLATENCY=1."
      genvw_dxvk_export_lowlatency_mode PROTON_DXVK_LOWLATENCY "low-latency-vrr-${hz}"
      ;;
    async | gplasync)
      warn "gENVW: GPLASYNC='${val}' has no supported DXVK path on lowlatency-only builds."
      return 1
      ;;
    *)
      warn "gENVW: unknown GPLASYNC value '${val}', ignoring."
      return 1
      ;;
  esac

  return 0
}

genvw_apply_gplasync() {
  local val="${GPLASYNC:-}" policy=""
  [ -n "$val" ] && [ "$val" != "0" ] || return 0

  genvw_guard_versioned_dxvk_runtime || return 1
  genvw_dxvk_resolve_target
  genvw_dxvk_policy_warn_once
  policy="${GENVW_DXVK_TARGET_POLICY:-unknown_or_unsupported}"

  case "$policy" in
    legacy_gplall)
      genvw_apply_gplasync_legacy_gplall "$val"
      ;;
    split_envs)
      genvw_apply_gplasync_split_envs "$val"
      ;;
    lowlatency_only)
      genvw_apply_gplasync_lowlatency_only "$val"
      ;;
    *)
      warn "gENVW: Proton-CachyOS DXVK policy is unresolved; skipping GPLASYNC='${val}'."
      return 1
      ;;
  esac
}

genvw_apply_lll() {
  local val="${LLL:-}"
  [ -n "$val" ] || return 0
  case "$val" in
    antilag)
      export LOW_LATENCY_LAYER=1
      ;;
    reflex)
      export LOW_LATENCY_LAYER=1
      export LOW_LATENCY_LAYER_REFLEX=1
      export DXVK_NVAPI_VKREFLEX=1
      ;;
    reflex-amdhide)
      export LOW_LATENCY_LAYER=1
      export LOW_LATENCY_LAYER_REFLEX=1
      export DXVK_NVAPI_VKREFLEX=1
      genvw_dxvk_config_append "dxgi.hideAmdGpu = True"
      ;;
    *)
      warn "gENVW: unknown LLL value '${val}'; skipping."
      ;;
  esac
}

genvw_apply_lsfg() {
  local mult="${LSFG:-}" perf="${LSFGPERF:-}" flow="${LSFGFLOW:-}" present="${LSFGPRESENT:-}" hdr_override="${LSFGHDR:-}"
  local hdr_override_mode="unset"

  case "$mult" in
    '' | 0) return 0 ;;
    2 | 3 | 4)
      export LSFG_LEGACY=1
      export LSFG_MULTIPLIER="$mult"
      ;;
    *)
      warn "gENVW: unknown LSFG value '${mult}', ignoring."
      return 1
      ;;
  esac

  if [ -n "$perf" ]; then
    case "$perf" in
      0) ;;
      1) export LSFG_PERFORMANCE_MODE=1 ;;
      *) warn "gENVW: invalid LSFGPERF value '${perf}', ignoring." ;;
    esac
  fi

  if [ -n "$flow" ]; then
    if genvw_lsfg_flow_is_valid "$flow"; then
      export LSFG_FLOW_SCALE="$(genvw_lsfg_flow_normalize "$flow")"
    else
      warn "gENVW: invalid LSFGFLOW value '${flow}', ignoring."
    fi
  fi

  if [ -n "$present" ]; then
    case "$present" in
      fifo | mailbox | immediate)
        export LSFG_EXPERIMENTAL_PRESENT_MODE="$present"
        ;;
      *)
        warn "gENVW: invalid LSFGPRESENT value '${present}', ignoring."
        ;;
    esac
  fi

  if [ -n "$hdr_override" ]; then
    case "$hdr_override" in
      0) hdr_override_mode="off" ;;
      1)
        hdr_override_mode="on"
        export LSFG_HDR_MODE=1
        ;;
      *)
        warn "gENVW: invalid LSFGHDR value '${hdr_override}', ignoring."
        ;;
    esac
  fi

  if [ "$hdr_override_mode" = "unset" ] && [ "${HDR:-0}" = "1" ]; then
    export LSFG_HDR_MODE=1
  fi

  if [ -n "${PROTON_FSR4_UPGRADE:-}" ] || [ -n "${PROTON_FSR4_RDNA3_UPGRADE:-}" ]; then
    warn "gENVW: LSFG + FSR4: if the game enables its own frame generation, combining it with LSFG may cause artifacts."
  fi
  if [ "${MLFG_UPGRADE:-0}" = "1" ]; then
    warn "gENVW: LSFG + MLFG: if the game enables its own frame generation, combining it with LSFG may cause artifacts."
  fi

  return 0
}

genvw_wizard_dxvk_policy() {
  local capability_policy=""
  if capability_policy="$(genvw_wizard_selected_dw_dxvk_policy 2>/dev/null)"; then
    printf '%s\n' "$capability_policy"
    return 0
  fi
  if genvw_wizard_selected_capability_provider_is_dwproton; then
    printf '%s\n' "unknown_or_unsupported"
    return 0
  fi
  if capability_policy="$(genvw_wizard_selected_cachyos_dxvk_policy 2>/dev/null)"; then
    printf '%s\n' "$capability_policy"
    return 0
  fi
  genvw_dxvk_resolve_target
  printf '%s\n' "${GENVW_DXVK_TARGET_POLICY:-unknown_or_unsupported}"
}

genvw_wizard_refresh_hz_from_value() {
  local raw="${1:-}" out_var="${2:-}" whole="" frac="" lead=""
  raw="${raw//,/.}"
  case "$raw" in
    '' | *[!0-9.]* | *.*.*) return 1 ;;
  esac

  whole="${raw%%.*}"
  [ -n "$whole" ] || return 1
  if [ "$whole" != "$raw" ]; then
    frac="${raw#*.}"
    lead="${frac%"${frac#?}"}"
    case "$lead" in
      5 | 6 | 7 | 8 | 9) whole=$((10#$whole + 1)) ;;
    esac
  fi

  genvw_gplasync_hz_is_valid "$whole" || return 1
  [ -n "$out_var" ] && printf -v "$out_var" '%s' "$whole"
  return 0
}

genvw_wizard_pick_gplasync_vrr_hz() {
  local out_var="${1:-}" picked_hz="" typed=""

  if genvw_wizard_refresh_hz_from_value "${WIZARD_MON_REFRESH:-}" picked_hz; then
    msg "Using detected monitor refresh: ${picked_hz}Hz"
    echo
    [ -n "$out_var" ] && printf -v "$out_var" '%s' "$picked_hz"
    return 0
  fi

  while :; do
    echo "Enter your display refresh rate in Hz (for example 60, 120, 144, 165, 240)."
    printf "%s" "${YELLOW}Refresh rate (Hz): ${RESET}"
    tty_read typed || typed=""
    typed="$(trim "$typed")"
    if genvw_gplasync_hz_is_valid "$typed"; then
      echo
      [ -n "$out_var" ] && printf -v "$out_var" '%s' "$typed"
      return 0
    fi
    printf "%s\n\n" "${RED}Enter a whole number from 1 to 999.${RESET}"
  done
}

genvw_wizard_gplasync_latency_prompt() {
  local mode="${1:-}" out_var="${2:-}" choice="" hz="" resolved=""
  while :; do
    echo "  1) Balanced — stable frame pacing, works on any display"
    echo "  2) VRR-aware — tuned for variable refresh rate displays"
    echo "  3) Aggressive — lowest latency, may reduce FPS"
    printf "%s" "${YELLOW}Frame pacing [1]: ${RESET}"
    tty_read choice || choice=""
    choice="$(trim "$choice")"
    [ -z "$choice" ] && choice="1"
    case "$choice" in
      1)
        resolved="$mode"
        ;;
      2)
        genvw_wizard_pick_gplasync_vrr_hz hz
        resolved="${mode}-vrr-${hz}"
        ;;
      3)
        resolved="${mode}-min"
        ;;
      *)
        printf "%s\n\n" "${RED}Enter 1, 2 or 3.${RESET}"
        continue
        ;;
    esac
    [ -n "$out_var" ] && printf -v "$out_var" '%s' "$resolved"
    return 0
  done
}

genvw_wizard_gplasync_prompt_legacy() {
  local out_var="${1:-}" choice="" selected="" hz=""

  cat <<EOF
${BOLD}DXVK Policy:${RESET} legacy combined GPLASYNC mode (proton-cachyos 10.0-20260227)

  This legacy 20260227 path bundles three DXVK behaviors together:
    1. Async shader compilation
    2. Graphics Pipeline Library (GPL)
    3. Low-latency frame pacing

  Warning: not recommended for anti-cheat or multiplayer games.

  0) Skip                                                    (default)
  1) Everything (Async + GPL + Low-Latency) Balanced    (more VRAM)
  2) Everything (Async + GPL + Low-Latency) VRR-tuned   (more VRAM)
  3) Async + Low-Latency — smoother shaders, faster response
  4) Low-Latency only — faster response, no shader smoothing
  5) Async only — smoother shaders, no latency tuning
EOF

  while :; do
    printf "%s" "${YELLOW}GPLASYNC [0-5, default=0]: ${RESET}"
    tty_read choice || choice=""
    choice="$(trim "$choice")"
    [ -z "$choice" ] && choice="0"
    case "$choice" in
      0)
        selected=""
        ;;
      1)
        selected="1"
        ;;
      2)
        genvw_wizard_pick_gplasync_vrr_hz hz
        selected="vrr-${hz}"
        ;;
      3)
        genvw_wizard_gplasync_latency_prompt "on" selected
        ;;
      4)
        genvw_wizard_gplasync_latency_prompt "lowlat" selected
        ;;
      5)
        selected="async"
        ;;
      *)
        printf "%s\n\n" "${RED}Enter 0, 1, 2, 3, 4 or 5.${RESET}"
        continue
        ;;
    esac
    echo
    [ -n "$out_var" ] && printf -v "$out_var" '%s' "$selected"
    return 0
  done
}

genvw_wizard_dxvk_prompt_split_envs() {
  local out_var="${1:-}" choice="" selected=""

  cat <<EOF
${BOLD}DXVK Policy:${RESET} split env modes (proton-cachyos 10.0-20260228 to 20260311)

  GPLASYNC, LLASYNC, and LOWLATENCY are separate paths here.

  0) Skip                                                   (default)
  1) LLASYNC — async shader compilation + low-latency pacing
  2) LOWLATENCY — low-latency pacing only
  3) GPLASYNC — GPL/async path without low-latency pacing
EOF

  while :; do
    printf "%s" "${YELLOW}DXVK mode [0-3, default=0]: ${RESET}"
    tty_read choice || choice=""
    choice="$(trim "$choice")"
    [ -z "$choice" ] && choice="0"
    case "$choice" in
      0)
        selected=""
        ;;
      1)
        genvw_wizard_gplasync_latency_prompt "llasync" selected
        ;;
      2)
        genvw_wizard_gplasync_latency_prompt "lowlat" selected
        ;;
      3)
        selected="gplasync"
        ;;
      *)
        printf "%s\n\n" "${RED}Enter 0, 1, 2 or 3.${RESET}"
        continue
        ;;
    esac
    echo
    [ -n "$out_var" ] && printf -v "$out_var" '%s' "$selected"
    return 0
  done
}

genvw_wizard_dxvk_dw_split_envs() {
  local out_var="${1:-}" choice="" selected=""
  local latency_menu

  latency_menu() {
    local mode="${1:-}" out_name="${2:-}" pace_choice="" hz="" resolved=""
    while :; do
      echo "  1) Balanced — stable frame pacing, works on any display"
      echo "  2) VRR-aware — tuned for variable refresh rate displays"
      echo "  3) Aggressive — lowest latency, may reduce FPS"
      printf "%s" "${YELLOW}Frame pacing [1]: ${RESET}"
      tty_read pace_choice || pace_choice=""
      pace_choice="$(trim "$pace_choice")"
      [ -z "$pace_choice" ] && pace_choice="1"
      case "$pace_choice" in
        1)
          resolved="$mode"
          ;;
        2)
          genvw_wizard_pick_gplasync_vrr_hz hz
          resolved="${mode}-vrr-${hz}"
          ;;
        3)
          resolved="${mode}-min"
          ;;
        *)
          printf "%s\n\n" "${RED}Enter 1, 2 or 3.${RESET}"
          continue
          ;;
      esac
      [ -n "$out_name" ] && printf -v "$out_name" '%s' "$resolved"
      return 0
    done
  }

  cat <<EOF
${BOLD}DXVK Policy:${RESET} DW-Proton GPLAsync / low-latency modes

  DW-Proton documents separate GPLASYNC, LLASYNC, and LOWLATENCY env paths for this release.
  Warning: advanced DXVK modes may affect multiplayer anti-cheat compatibility. Use Skip for anti-cheat multiplayer games unless you know the game works with these options.

  0) Skip                                                   (default)
  1) LLASYNC - async shader compilation + low-latency pacing
  2) LOWLATENCY - low-latency pacing only
  3) GPLASYNC - GPL/async path without low-latency pacing
EOF

  while :; do
    printf "%s" "${YELLOW}DXVK mode [0-3, default=0]: ${RESET}"
    tty_read choice || choice=""
    choice="$(trim "$choice")"
    [ -z "$choice" ] && choice="0"
    case "$choice" in
      0)
        selected=""
        ;;
      1)
        latency_menu "llasync" selected
        ;;
      2)
        latency_menu "lowlat" selected
        ;;
      3)
        selected="gplasync"
        ;;
      *)
        printf "%s\n\n" "${RED}Enter 0, 1, 2 or 3.${RESET}"
        continue
        ;;
    esac
    echo
    [ -n "$out_var" ] && printf -v "$out_var" '%s' "$selected"
    return 0
  done
}

genvw_wizard_dxvk_prompt_lowlatency_only() {
  local out_var="${1:-}" choice="" selected=""

  cat <<EOF
${BOLD}DXVK Policy:${RESET} lowlatency-only mode (proton-cachyos 10.0-20260312+)

  Only the low-latency pacing path remains available here.

  0) Skip                                             (default)
  1) Enable low-latency frame pacing
EOF

  while :; do
    printf "%s" "${YELLOW}DXVK low-latency [0-1, default=0]: ${RESET}"
    tty_read choice || choice=""
    choice="$(trim "$choice")"
    [ -z "$choice" ] && choice="0"
    case "$choice" in
      0)
        selected=""
        ;;
      1)
        genvw_wizard_gplasync_latency_prompt "lowlat" selected
        ;;
      *)
        printf "%s\n\n" "${RED}Enter 0 or 1.${RESET}"
        continue
        ;;
    esac
    echo
    [ -n "$out_var" ] && printf -v "$out_var" '%s' "$selected"
    return 0
  done
}

genvw_wizard_gplasync_prompt() {
  local out_var="${1:-}" policy=""
  policy="$(genvw_wizard_dxvk_policy)"
  if [[ "$policy" == "split_envs" ]] && genvw_wizard_selected_capability_provider_is_dwproton; then
    genvw_wizard_dxvk_dw_split_envs "$out_var"
    return 0
  fi

  case "$policy" in
    legacy_gplall)
      genvw_wizard_gplasync_prompt_legacy "$out_var"
      ;;
    split_envs)
      genvw_wizard_dxvk_prompt_split_envs "$out_var"
      ;;
    lowlatency_only)
      genvw_wizard_dxvk_prompt_lowlatency_only "$out_var"
      ;;
    *)
      [ -n "$out_var" ] && printf -v "$out_var" '%s' ""
      return 1
      ;;
  esac
}

genvw_wizard_lsfg_prompt() {
  local out_lsfg_var="${1:-}" out_perf_var="${2:-}" out_flow_var="${3:-}" out_present_var="${4:-}" out_hdr_var="${5:-}"
  local choice="" selected="" perf_selected="" flow_selected="" present_selected="" hdr_selected=""
  local gplasync_active=0 mlfg_active=0 hdr_launch_active=0

  GENVW_WIZARD_LSFG_PRESENT=""
  GENVW_WIZARD_LSFG_HDR=""

  if [ -n "${GPLASYNC:-}" ] && [ "${GPLASYNC}" != "0" ]; then
    gplasync_active=1
  elif genvw_launch_env_has_key "${LAUNCH_ENV:-}" "GPLASYNC"; then
    gplasync_active=1
  fi

  if [ "${HDR_ENABLED:-0}" = "1" ] || genvw_launch_env_has_key "${LAUNCH_ENV:-}" "HDR"; then
    hdr_launch_active=1
  fi

  # Mirror runtime MLFG gate: only flag MLFG active when selected FSR4 is trusted
  # local-only with local DLL present; ignore stale raw MLFG key state otherwise.
  local mlfg_sel_ver="" mlfg_launch_val="" mlfg_tok=""
  mlfg_sel_ver="$(genvw_fsr4_selected_from_launch_env "${LAUNCH_ENV:-}")"
  if [ -n "$mlfg_sel_ver" ] \
    && genvw_fsr4_is_local_only "$mlfg_sel_ver" \
    && [ -f "$(genvw_fsr4_local_dll_path "$mlfg_sel_ver")" ]; then
    for mlfg_tok in ${LAUNCH_ENV:-}; do
      case "$mlfg_tok" in
        MLFG=*) mlfg_launch_val="${mlfg_tok#MLFG=}" ;;
      esac
    done
    if [ "${MLFG_UPGRADE:-0}" = "1" ] || [ "${MLFG:-0}" = "1" ] || [ "$mlfg_launch_val" = "1" ]; then
      mlfg_active=1
    fi
  fi

  cat <<EOF
${BOLD}LSFG:${RESET} Lossless Scaling Frame Generation (lsfg-vk)

  Vulkan layer: installed
  Lossless.dll: ${WIZARD_LSFG_DLL_VER:-unknown} (${WIZARD_LSFG_DLL_PATH:-unknown})

  Multiplies rendered frames using motion interpolation.
  Works alongside Proton - the Vulkan layer injects generated
  frames between real ones.

  Warning: adds latency. Not for competitive or multiplayer games.
EOF

  if [ "$gplasync_active" -eq 1 ]; then
    echo
    echo "  GPLASYNC is active - if you hit pacing or present issues, try LSFGPRESENT=mailbox explicitly."
  fi
  if [ "${wizard_fsr4_active:-0}" = "1" ]; then
    echo
    echo "  FSR4 is active - if the game enables its own frame generation, combining it with LSFG may cause artifacts."
  fi
  if [ "$mlfg_active" -eq 1 ]; then
    echo
    echo "  MLFG is active - if the game enables its own frame generation, combining it with LSFG may cause artifacts."
  fi

  cat <<EOF

  0) Skip                                             (default)
  2) 2x - one generated frame per real frame
  3) 3x - two generated frames per real frame
  4) 4x - three generated frames per real frame
EOF

  while :; do
    printf "%s" "${YELLOW}LSFG [0-4, default=0]: ${RESET}"
    tty_read choice || choice=""
    choice="$(trim "$choice")"
    [ -z "$choice" ] && choice="0"
    case "$choice" in
      0)
        selected=""
        echo
        [ -n "$out_lsfg_var" ] && printf -v "$out_lsfg_var" '%s' "$selected"
        [ -n "$out_perf_var" ] && printf -v "$out_perf_var" '%s' ""
        [ -n "$out_flow_var" ] && printf -v "$out_flow_var" '%s' ""
        [ -n "$out_present_var" ] && printf -v "$out_present_var" '%s' ""
        [ -n "$out_hdr_var" ] && printf -v "$out_hdr_var" '%s' ""
        GENVW_WIZARD_LSFG_PRESENT=""
        GENVW_WIZARD_LSFG_HDR=""
        return 0
        ;;
      2 | 3 | 4)
        selected="$choice"
        break
        ;;
      *)
        printf "%s\n\n" "${RED}Enter 0, 2, 3 or 4.${RESET}"
        ;;
    esac
  done
  echo

  echo "${BOLD}LSFGPERF:${RESET} Use lighter model (faster, slight quality loss)."
  if ask_yes_no_default "${YELLOW}Performance mode? [y/N]: ${RESET}" "n"; then
    perf_selected="1"
  fi
  echo

  while :; do
    echo "${BOLD}LSFGFLOW:${RESET} Motion estimation resolution (lower = faster, less accurate)."
    printf "%s" "${YELLOW}Flow scale [0.25-1.0, default=1.0]: ${RESET}"
    tty_read flow_selected || flow_selected=""
    flow_selected="$(trim "$flow_selected")"
    if [ -z "$flow_selected" ]; then
      flow_selected="1.0"
      echo
      break
    fi
    if genvw_lsfg_flow_is_valid "$flow_selected"; then
      flow_selected="$(genvw_lsfg_flow_normalize "$flow_selected")"
      echo
      break
    fi
    printf "%s\n\n" "${RED}Enter a decimal from 0.25 to 1.0.${RESET}"
  done

  cat <<EOF
${BOLD}LSFGPRESENT:${RESET} Frame presentation mode for LSFG.
  Controls how LSFG queues its extra frames to the display.

  1) fifo       Stable/VSync-like. No tearing, safest default.
  2) mailbox    Lower latency. Replaces queued frames; useful if pacing feels uneven.
  3) immediate  Lowest queueing latency. Can tear or look uneven.
EOF

  while :; do
    printf "%s" "${YELLOW}Present mode [1-3, default=1]: ${RESET}"
    tty_read choice || choice=""
    choice="$(trim "$choice")"
    [ -z "$choice" ] && choice="1"
    case "$choice" in
      1) present_selected="fifo"; break ;;
      2) present_selected="mailbox"; break ;;
      3) present_selected="immediate"; break ;;
      *) printf "%s\n\n" "${RED}Enter 1, 2 or 3.${RESET}" ;;
    esac
  done
  echo

  if [ "$hdr_launch_active" -eq 1 ]; then
    hdr_selected="1"
    cat <<EOF
${BOLD}LSFG HDR handling:${RESET}
  HDR=1 and LSFG are active, so LSFG HDR handling will be saved as LSFGHDR=1.

  If this causes washed-out colors, wrong brightness, flicker,
  or other picture issues, change LSFGHDR=1 to LSFGHDR=0
  in the launch options or saved profile.
EOF
    echo
  elif [ "${WIZARD_MON_HDR:-?}" = "1" ]; then
    cat <<EOF
${BOLD}LSFG HDR handling:${RESET}
  The selected monitor currently reports HDR on.
  Enable LSFG HDR handling for LSFG's extra frames?

  This does not enable Linux HDR, Gamescope HDR, or title HDR by itself.
  If picture quality gets worse, set LSFGHDR=0 later.
EOF
    if ask_yes_no_default "${YELLOW}Enable LSFG HDR handling? [Y/n]: ${RESET}" "y"; then
      hdr_selected="1"
    else
      hdr_selected="0"
    fi
    echo
  fi

  [ -n "$out_lsfg_var" ] && printf -v "$out_lsfg_var" '%s' "$selected"
  [ -n "$out_perf_var" ] && printf -v "$out_perf_var" '%s' "$perf_selected"
  [ -n "$out_flow_var" ] && printf -v "$out_flow_var" '%s' "$flow_selected"
  [ -n "$out_present_var" ] && printf -v "$out_present_var" '%s' "$present_selected"
  [ -n "$out_hdr_var" ] && printf -v "$out_hdr_var" '%s' "$hdr_selected"
  GENVW_WIZARD_LSFG_PRESENT="$present_selected"
  GENVW_WIZARD_LSFG_HDR="$hdr_selected"
  return 0
}

genvw_wizard_korthos_amdhide_confirm() {
  local out_var="${1:-}" choice=""
  cat <<EOF
Advanced warning: Reflex path + AMD-hide fallback

  This adds:
    LOW_LATENCY_LAYER=1
    LOW_LATENCY_LAYER_REFLEX=1
    DXVK_NVAPI_VKREFLEX=1
    DXVK_CONFIG="dxgi.hideAmdGpu = True"

  This may help games expose Reflex when they do not show it on AMD GPUs.
  It changes how DXVK reports the GPU to the game.

  Do not use this first.
  Try the normal Reflex path first.

  0) Cancel AMD-hide fallback                              (default)
  1) Continue with AMD-hide fallback
EOF
  while :; do
    printf "%s" "${YELLOW}AMD-hide fallback [0-1, default=0]: ${RESET}"
    tty_read choice || choice=""
    choice="$(trim "$choice")"
    [ -z "$choice" ] && choice="0"
    case "$choice" in
      0)
        echo
        [ -n "$out_var" ] && printf -v "$out_var" '%s' "0"
        return 0
        ;;
      1)
        echo
        [ -n "$out_var" ] && printf -v "$out_var" '%s' "1"
        return 0
        ;;
      *)
        printf "%s\n\n" "${RED}Enter 0 or 1.${RESET}"
        ;;
    esac
  done
}

genvw_wizard_korthos_stacked_latency_confirm() {
  local mode="${1:-}" gplasync_val="${2:-}" out_var="${3:-}" choice=""
  local cancel_label=""
  case "$mode" in
    antilag)
      cancel_label="Cancel Korthos layer and keep DXVK low-latency"
      cat <<EOF
Compatibility warning: stacked latency paths

  You already enabled DXVK low-latency frame pacing:
    GPLASYNC=${gplasync_val}

  You also selected Korthos low_latency_layer (Anti-Lag 2):
    LOW_LATENCY_LAYER=1

  This combination is experimental in gENVW.
  It may improve latency, but behavior is game-dependent and not
  fully characterized.

  Possible issues:
    - no benefit or worse frame pacing
    - game launch failure
    - game crash
    - broken in-game latency option
    - anti-cheat / multiplayer compatibility risk

  Recommended:
    Use one latency path first.
    For protected multiplayer or anti-cheat games, do not stack
    these unless you have tested the game.
EOF
      ;;
    reflex)
      cancel_label="Cancel Reflex layer and keep DXVK low-latency"
      cat <<EOF
Compatibility warning: stacked DXVK pacing + Reflex layer

  You already enabled DXVK low-latency frame pacing:
    GPLASYNC=${gplasync_val}

  You also selected Korthos Reflex path:
    LOW_LATENCY_LAYER=1
    LOW_LATENCY_LAYER_REFLEX=1
    DXVK_NVAPI_VKREFLEX=1

  This combination is experimental in gENVW.
  It may improve latency, but behavior is game-dependent and not
  fully characterized.

  Possible issues:
    - no benefit or worse frame pacing
    - Reflex option does not appear in-game
    - game launch failure
    - game crash
    - broken in-game latency option
    - anti-cheat / multiplayer compatibility risk

  Recommended:
    Test Reflex path alone first.
    For protected multiplayer or anti-cheat games, do not stack
    these unless you have tested the game.
EOF
      ;;
    reflex-amdhide)
      cancel_label="Cancel advanced Reflex fallback and keep DXVK low-latency"
      cat <<EOF
Compatibility warning: stacked DXVK pacing + advanced Reflex fallback

  You already enabled DXVK low-latency frame pacing:
    GPLASYNC=${gplasync_val}

  You also selected advanced Korthos Reflex fallback:
    LOW_LATENCY_LAYER=1
    LOW_LATENCY_LAYER_REFLEX=1
    DXVK_NVAPI_VKREFLEX=1
    DXVK_CONFIG="dxgi.hideAmdGpu = True"

  This combination is experimental and changes multiple
  latency/GPU-reporting paths.
EOF
      ;;
  esac
  cat <<EOF

  0) ${cancel_label}        (default)
  1) Cancel DXVK low-latency and keep Korthos layer
  2) Keep both experimental latency paths
EOF
  while :; do
    printf "%s" "${YELLOW}Stacked latency paths [0-2, default=0]: ${RESET}"
    tty_read choice || choice=""
    choice="$(trim "$choice")"
    [ -z "$choice" ] && choice="0"
    case "$choice" in
      0|1|2)
        echo
        [ -n "$out_var" ] && printf -v "$out_var" '%s' "$choice"
        return 0
        ;;
      *)
        printf "%s\n\n" "${RED}Enter 0, 1, or 2.${RESET}"
        ;;
    esac
  done
}

genvw_wizard_korthos_menu() {
  local out_lll="${1:-}" out_drop_gplasync="${2:-}" wizard_gplasync_val="${3:-}"
  local choice="" candidate="" amdhide_result="" stacked_result="" drop_gplasync=0
  cat <<EOF
${BOLD}KORTHOS:${RESET} Low Latency Layer (CachyOS 11.0-20260519+).
  AMD Anti-Lag 2 or Nvidia Reflex compatibility layer.
  Anti-Lag 2 and Reflex paths are mutually exclusive.
  Reflex paths are game-dependent; test per game before using them
  in protected multiplayer or anti-cheat titles.

  0) Skip                                                       (default)
  1) Anti-Lag 2 - AMD latency reduction
  2) Reflex path - expose Nvidia Reflex compatibility
  3) Advanced Reflex + AMD-hide fallback
     (for games that ignore Reflex on AMD; changes GPU reporting)
EOF
  while :; do
    printf "%s" "${YELLOW}KORTHOS [0-3, default=0]: ${RESET}"
    tty_read choice || choice=""
    choice="$(trim "$choice")"
    [ -z "$choice" ] && choice="0"
    case "$choice" in
      0) candidate=""; break ;;
      1) candidate="antilag"; break ;;
      2) candidate="reflex"; break ;;
      3)
        amdhide_result="0"
        genvw_wizard_korthos_amdhide_confirm amdhide_result
        if [[ "$amdhide_result" == "1" ]]; then
          candidate="reflex-amdhide"
        else
          candidate=""
        fi
        break
        ;;
      *) printf "%s\n\n" "${RED}Enter 0, 1, 2, or 3.${RESET}" ;;
    esac
  done
  if [[ -n "$candidate" ]] && [[ "${wizard_gplasync_val:-}" =~ ^lowlat ]]; then
    stacked_result="0"
    genvw_wizard_korthos_stacked_latency_confirm "$candidate" "$wizard_gplasync_val" stacked_result
    case "$stacked_result" in
      0) candidate="" ;;
      1) drop_gplasync=1 ;;
      2) ;;
    esac
  fi
  [[ -n "$out_lll" ]] && printf -v "$out_lll" '%s' "$candidate"
  [[ -n "$out_drop_gplasync" ]] && printf -v "$out_drop_gplasync" '%s' "$drop_gplasync"
  echo
}

genvw_wizard_missing_gamescope_choice() {
  local intro="${1:-Gamescope is not installed.}"
  local continue_label="${2:-continue without Gamescope}"
  local out_var="${3:-}"
  local choice=""

  printf "%s\n\n" "${CYAN}${intro}${RESET}"
  msg "Choose one:"
  msg "  1 = ${continue_label}"
  msg "  2 = stop here and install Gamescope"

  while :; do
    printf "%s" "${YELLOW}Choice [1]: ${RESET}"
    tty_read choice || choice=""
    choice="$(trim "$choice")"
    [ -z "$choice" ] && choice="1"
    case "$choice" in
      1|2)
        [ -n "$out_var" ] && printf -v "$out_var" '%s' "$choice"
        echo
        return 0
        ;;
      *)
        printf "%s\n\n" "${RED}Enter 1 or 2.${RESET}"
        ;;
    esac
  done
}

# host_steam_ps_lines
# print steam-related process lines; empty output means "not running".

host_steam_ps_lines() {
  if command -v pgrep >/dev/null 2>&1; then
    {
      # native steam + helpers (match by comm)
      pgrep -a -x steam 2>/dev/null || true
      pgrep -a -x steamwebhelper 2>/dev/null || true
      pgrep -a -x steamservice 2>/dev/null || true
      # wrapper/runtime patterns
      pgrep -a -f 'steam-launch-wrapper|steam-runtime' 2>/dev/null || true
      # flatpak steam
      pgrep -a -f 'com\.valvesoftware\.Steam' 2>/dev/null || true
      pgrep -a -f 'flatpak.*com\.valvesoftware\.Steam' 2>/dev/null || true
      pgrep -a -f 'bwrap.*com\.valvesoftware\.Steam' 2>/dev/null || true
      # "steam" sometimes shows up as a wrapper script
      pgrep -a -f '(^|/)(steam|steam\.sh)([[:space:]]|$)' 2>/dev/null || true
    } | awk '!seen[$1]++'
  else
    # fallback when pgrep is missing
    ps -eo pid=,comm=,args= 2>/dev/null | awk '
    $2=="steam" || $2=="steamwebhelper" || $2=="steamservice" {print; next}
    $0 ~ /(^|\/)(steam|steam\.sh)([[:space:]]|$)/ {print; next}
    $0 ~ /(steam-launch-wrapper|steam-runtime)/ {print; next}
    $0 ~ /(flatpak.*com\.valvesoftware\.Steam|bwrap.*com\.valvesoftware\.Steam|com\.valvesoftware\.Steam)/ {print; next}
  '
  fi
}

# host_steam_is_running
# true when host_steam_ps_lines reports at least one process.

host_steam_is_running() {
  host_steam_ps_lines | grep -q .
}

# genvw_offer_build_tools
# ask to rebuild tools when wizard checks detect missing tool state.

genvw_offer_build_tools() {
  local why="$1"

  # never auto-build outside an interactive terminal
  if ! genvw_tty_io_ready; then
    echo "${YELLOW}${I_INFO} $why${RESET}" >&2
    echo "${YELLOW}${I_INFO} Non-interactive session → not auto-building tools.${RESET}" >&2
    echo "${YELLOW}   Run: genvw proton rebuild --all-targets (then restart Steam).${RESET}" >&2
    return 2
  fi

  echo "${YELLOW}${I_WARN} $why${RESET}" >&2

  if host_steam_is_running; then
    echo "${YELLOW}${I_INFO} Steam is running.${RESET}" >&2
    echo "${YELLOW}   Close Steam, rebuild, then restart Steam.${RESET}" >&2
    return 2
  fi

  if ask_yes_no_default "${BOLD}${I_TOOL} Build gENVW Proton tools now? [Y/n]: ${RESET}" "y" >&2; then
    if run_proton rebuild --all-targets >&2; then
      export GENVW_TOOLS_BUILT_THIS_RUN=1
      return 0
    fi
    return 1
  fi

  return 2
}

# show_genvw_banner
# ascii banner for interactive mode.

show_genvw_banner() {
  : "${BOLD:=$(printf '\033[1m')}"
  : "${CYAN:=$(printf '\033[36m')}"
  : "${RESET:=$(printf '\033[0m')}"

  local cols BANNER_WIDTH indent pad line color dummy

  # terminal width; default 80.
  cols=$(tput cols 2>/dev/null || echo 80)

  BANNER_WIDTH=58
  if [ "$cols" -gt "$BANNER_WIDTH" ]; then
    indent=$(((cols - BANNER_WIDTH) / 2))
  else
    indent=0
  fi

  pad=$(printf '%*s' "$indent" "")

  while IFS= read -r line; do
    [ -z "$line" ] && continue

    color="$CYAN"
    case "$line" in
      *"by furbakka"*) color="$YELLOW" ;;
    esac

    printf '%s%s%s%s\n' "$pad" "$color" "$line" "$RESET"
    sleep 0.25
  done <<'EOF'



 ▄▄▄▄ ██████ ███  ██ ██  ██ ██     ██
██ ▄▄ ██▄▄   ██ ▀▄██ ██▄▄██ ██ ▄█▄ ██
▀███▀ ██▄▄▄▄ ██   ██  ▀██▀   ▀██▀██▀

                          by furbakka
EOF
  printf '\n'
  # keep it on screen (same padding + cyan prompt)
  printf '%s%sPress Enter to start gENVW...%s' "$pad" "$BOLD$CYAN" "$RESET"
  # /dev/tty first, then stdin
  tty_read dummy || dummy=""
  echo
  echo
  genvw_logo_cleanup
}

genvw_term_cols() { tput cols 2>/dev/null || echo 80; }
genvw_term_lines() { tput lines 2>/dev/null || echo 24; }

# genvw_logo_geom
# logo geometry + placement for the current terminal.

genvw_logo_geom() {
  # outputs: w h top_pad left_pad
  local cols lines w h top left
  cols="$(genvw_term_cols)"
  lines="$(genvw_term_lines)"

  # width: ~50% of terminal, clamped
  w=$((cols * 50 / 100))
  ((w < 28)) && w=28
  ((w > 110)) && w=110
  ((w > cols - 2)) && w=$((cols - 2))
  ((w < 10)) && w=10

  # height: rough square-ish image in terminal cells
  h=$((w / 2))
  ((h < 8)) && h=8
  ((h > 28)) && h=28
  ((h > lines - 2)) && h=$((lines - 2))
  ((h < 3)) && h=3

  # left pad for centering
  left=$(((cols - w) / 2))
  ((left < 0)) && left=0

  # true vertical centering
  top=$(((lines - h) / 2))
  ((top < 0)) && top=0

  printf '%s %s %s %s\n' "$w" "$h" "$top" "$left"
}

# genvw_print_centered_block
# center stdin lines to terminal width (banner/logo fallback).

genvw_print_centered_block() {
  local cols line pad
  cols="$(genvw_term_cols)"
  while IFS= read -r line; do
    [[ -z "$line" ]] && {
      printf '\n'
      continue
    }
    pad=$(((cols - ${#line}) / 2))
    ((pad < 0)) && pad=0
    printf '%*s%s\n' "$pad" "" "$line"
  done
}

# genvw_press_enter_to_start
# pause until enter (wizard flow).

genvw_press_enter_to_start() {
  # # colors can be unset when this runs early
  : "${BOLD:=$(printf '\033[1m')}"
  : "${CYAN:=$(printf '\033[36m')}"
  : "${RESET:=$(printf '\033[0m')}"

  # same prompt text + centering as show_genvw_banner()
  local cols BANNER_WIDTH indent pad dummy
  cols=$(tput cols 2>/dev/null || echo 80)
  BANNER_WIDTH=58
  if [ "$cols" -gt "$BANNER_WIDTH" ]; then
    indent=$(((cols - BANNER_WIDTH) / 2))
  else
    indent=0
  fi
  pad=$(printf '%*s' "$indent" "")

  printf '\n'
  printf '%s%sPress Enter to start gENVW...%s' "$pad" "$BOLD$CYAN" "$RESET"
  tty_read dummy || dummy=""
  echo
  echo
}

# genvw_show_logo_png_centered
# draw a png logo in the terminal (kitty/chafa), centered.

genvw_show_logo_png_centered() {
  local png="$1"
  [[ -f "$png" ]] || return 1
  [[ -t 1 ]] || return 1

  local w h top left cols lines x
  read -r w h top left < <(genvw_logo_geom) ## Do not touch!
  cols="$(genvw_term_cols)"
  lines="$(genvw_term_lines)"

  # 1) kitten icat (real pixels + placement)
  if command -v kitten >/dev/null 2>&1; then
    x=$(((cols - w) / 2))
    ((x < 0)) && x=0
    kitten icat --silent --clear --align center --place "${w}x${h}@${x}x${top}" "$png" 2>/dev/null && return 0
  fi

  # 2) chafa kitty graphics
  if command -v chafa >/dev/null 2>&1; then
    chafa --format kitty --probe on --view-size "${cols}x${lines}" --align mid,mid --size "${w}x${h}" "$png" 2>/dev/null && return 0
  fi

  # 3) chafa braille symbols
  if command -v chafa >/dev/null 2>&1; then
    chafa --format symbols --symbols braille --fg-only --probe on --view-size "${cols}x${lines}" --align mid,mid --size "${w}x${h}" "$png" 2>/dev/null && return 0
  fi

  return 1
}
# genvw_logo_cleanup
# clear any terminal state left by logo rendering.

genvw_logo_cleanup() {
  [[ -t 1 ]] || return 0

  # kitty graphics delete (no-op on terminals that ignore it)
  printf '\033_Ga=d\033\\' 2>/dev/null || true

  # kitten icat clear if available
  if command -v kitten >/dev/null 2>&1; then
    kitten icat --silent --clear 2>/dev/null || true
  fi

  # clear screen + home cursor
  tput clear 2>/dev/null || printf '\033[2J\033[H'
}

# genvw_show_logo
# show a logo if we can (png -> ascii -> banner).

genvw_show_logo() {
  [[ -t 1 ]] || return 0
  #printf 'DEBUG(genvw_show_logo): BOLD=%q CYAN=%q RESET=%q\n' "${BOLD-UNSET}" "${CYAN-UNSET}" "${RESET-UNSET}" >&2

  # skip straight to banner if logo is disabled (and banner is allowed)
  if [[ -n "${GENVW_NO_LOGO:-}" ]]; then
    [[ -z "${GENVW_NO_BANNER:-}" ]] && show_genvw_banner
    return 0
  fi

  local logo_png ascii_txt
  logo_png="$(genvw_asset_path "assets/genvw_logo.png" 2>/dev/null || true)"
  ascii_txt="$(genvw_asset_path "ascii/genvw_logo.txt" 2>/dev/null || true)"

  # 1) png
  if [[ -n "$logo_png" && -f "$logo_png" ]]; then
    if genvw_show_logo_png_centered "$logo_png"; then
      genvw_press_enter_to_start
      genvw_logo_cleanup
      return 0
    fi
  fi

  # 2) ascii fallback
  if [[ -n "$ascii_txt" && -f "$ascii_txt" ]]; then
    genvw_print_centered_block <"$ascii_txt"
    genvw_press_enter_to_start
    genvw_logo_cleanup
    return 0
  fi

  # 3) banner fallback
  [[ -z "${GENVW_NO_BANNER:-}" ]] && show_genvw_banner
}

# colors (only if stdout is a tty)

if [ -t 1 ] && [ -z "${GENVW_NO_COLOR:-}" ]; then
  BOLD=$(printf '\033[1m')
  DIM=$(printf '\033[2m')
  RED=$(printf '\033[31m')
  GREEN=$(printf '\033[32m')
  YELLOW=$(printf '\033[33m')
  BLUE=$(printf '\033[34m')
  MAGENTA=$(printf '\033[35m')
  CYAN=$(printf '\033[36m')
  RESET=$(printf '\033[0m')
  : "${ORANGE:=$'\033[38;5;208m'}" # 256-color orange
  : "${WHITE:=$'\033[97m'}"        # bright white
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

# icons (can be replaced with ascii via GENVW_NO_EMOJI)

I_OK="✅"
I_WARN="⚠️"
I_ERR="❌"
I_INFO="ℹ️"
I_TOOL="🛠️"
I_TOOLBOX="🧰"
I_TRASH="🗑️"
I_SHIELD="🛡️"
I_GO="▶️"
I_NOTE="📝"
I_GEAR="⚙️"
I_PUZZLE="🧩"
I_BOX="📦"
I_DATE="🗓️"
I_RECEIPT="🧾"
I_GAME="🎮"
I_SEARCH="🔎"

if [[ "${GENVW_NO_EMOJI:-0}" == "1" ]]; then
  I_OK="[OK]"
  I_WARN="[WARNING]"
  I_ERR="[ERROR]"
  I_INFO="[INFO]"
  I_TOOL="[TOOL]"
  I_TOOLBOX="[KIT]"
  I_TRASH="[DELETE]"
  I_SHIELD="[SAFE]"
  I_GO=">>"
  I_NOTE="[NOTE]"
  I_GEAR="[CONFIG]"
  I_PUZZLE="[PUZZLE]"
  I_BOX="[BOX]"
  I_DATE="[DATE]"
  I_RECEIPT="[META]"
  I_GAME="[GAME]"
  I_SEARCH="[FIND]"
fi

# msg
# plain status line (no severity).

msg() { printf '%s\n' "$*"; }

# genvw_icon
# prefix an icon unless the text already starts with it (handles colored strings too).

genvw_icon() {
  local icon="$1"
  shift
  local text="$*"

  [[ -z "${icon}" ]] && {
    msg "${text}"
    return 0
  }

  # strip leading sgr escapes before checking the prefix
  local esc=$''
  local plain="$text"
  local re="^${esc}\\[[0-9;]*m(.*)$"
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

ok() { genvw_icon "${I_OK}" "${GREEN}$*${RESET}"; }
warn() { genvw_icon "${I_WARN}" "${YELLOW}$*${RESET}"; }
err() { genvw_icon "${I_ERR}" "${RED}$*${RESET}" >&2; }
info() { genvw_icon "${I_INFO}" "${CYAN}$*${RESET}"; }

hint() { info "$*"; }
note() { info "$*"; }

# step
# action line (we're about to do something).

step() { genvw_icon "${I_GO}" "$*"; }

# die
# fatal error + exit.

die() {
  # default exit 1 here is intentional: this is the normal runtime failure path.
  local code=1
  if [[ "${1-}" =~ ^[0-9]+$ ]]; then
    code="$1"
    shift
  fi
  err "$*"
  exit "$code"
}

# genvw_exit_on_signal_rc
# keep 130/143 behavior even when callers ignore ordinary failures.
# keep this out of $(...) so it can exit the parent shell.

genvw_exit_on_signal_rc() {
  local rc="${1:-0}"
  case "$rc" in
    130|143) exit "$rc" ;;
  esac
  return 0
}

# have
# command existence check.

have() { command -v "$1" >/dev/null 2>&1; }
need_cmd() { have "$1" || die "Missing required command: $1"; }

genvw_have_gamescope() {
  [ "${GENVW_NO_GAMESCOPE:-0}" = "1" ] && return 1
  have gamescope
}

genvw_have_lsfg() {
  [ "${GENVW_NO_LSFG_DETECT:-0}" = "1" ] && return 1
  local d=""
  for d in \
    /etc/vulkan/implicit_layer.d \
    /usr/share/vulkan/implicit_layer.d \
    /usr/local/share/vulkan/implicit_layer.d \
    "${HOME}/.local/share/vulkan/implicit_layer.d"; do
    [ -f "$d/VkLayer_LS_frame_generation.json" ] && return 0
  done
  return 1
}

genvw_lsfg_config_path() {
  local out_var="${1:-}" candidate=""
  for candidate in \
    "${XDG_CONFIG_HOME:-$HOME/.config}/lsfg-vk/conf.toml" \
    /etc/lsfg-vk/conf.toml; do
    if [ -f "$candidate" ]; then
      [ -n "$out_var" ] && printf -v "$out_var" '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

genvw_lsfg_dll_version() {
  local dll_path="${1:-}"
  have python3 || return 1
  [ -f "$dll_path" ] || return 1
  python3 - "$dll_path" <<'PY'
import struct, sys

with open(sys.argv[1], 'rb') as f:
    data = f.read()

marker = struct.pack('<I', 0xFEEF04BD)
pos = data.find(marker)
if pos < 0:
    sys.exit(1)

ms, ls = struct.unpack_from('<II', data, pos + 8)
print(f'{(ms >> 16) & 0xFFFF}.{ms & 0xFFFF}.{(ls >> 16) & 0xFFFF}.{ls & 0xFFFF}')
PY
}

genvw_lsfg_dll_info() {
  local out_conf_var="${1:-}" out_dll_var="${2:-}" out_ver_var="${3:-}"
  local lsfg_conf="" lsfg_dll_path="" lsfg_dll_ver="" line=""

  if ! genvw_lsfg_config_path lsfg_conf; then
    return 1
  fi

  while IFS= read -r line; do
    if [[ "$line" =~ ^[[:space:]]*dll[[:space:]]*=[[:space:]]*\"([^\"]+)\" ]]; then
      lsfg_dll_path="${BASH_REMATCH[1]}"
      break
    fi
  done <"$lsfg_conf"
  lsfg_dll_path="${lsfg_dll_path//$'\r'/}"
  lsfg_dll_path="$(trim_outer_ws "$lsfg_dll_path")"
  case "$lsfg_dll_path" in
    "~/"*) lsfg_dll_path="${HOME}/${lsfg_dll_path#~/}" ;;
  esac

  [ -n "$out_conf_var" ] && printf -v "$out_conf_var" '%s' "$lsfg_conf"

  if [ -z "$lsfg_dll_path" ]; then
    [ -n "$out_dll_var" ] && printf -v "$out_dll_var" '%s' ""
    [ -n "$out_ver_var" ] && printf -v "$out_ver_var" '%s' ""
    return 2
  fi

  [ -n "$out_dll_var" ] && printf -v "$out_dll_var" '%s' "$lsfg_dll_path"

  if [ ! -f "$lsfg_dll_path" ]; then
    [ -n "$out_ver_var" ] && printf -v "$out_ver_var" '%s' ""
    return 3
  fi

  lsfg_dll_ver="$(genvw_lsfg_dll_version "$lsfg_dll_path" 2>/dev/null || true)"
  [ -n "$lsfg_dll_ver" ] || lsfg_dll_ver="unknown"
  [ -n "$out_ver_var" ] && printf -v "$out_ver_var" '%s' "$lsfg_dll_ver"
  return 0
}

genvw_hdr_display_mode() {
  if [[ -n "${GAMESCOPE_WAYLAND_DISPLAY:-}" ]]; then
    printf '%s\n' "gamescope"
    return 0
  fi
  if [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
    printf '%s\n' "wayland"
    return 0
  fi
  case "${XDG_SESSION_TYPE:-}" in
    wayland) printf '%s\n' "wayland" ;;
    x11) printf '%s\n' "x11" ;;
    *) printf '%s\n' "unknown" ;;
  esac
}

genvw_hdr_display_label() {
  case "${1:-unknown}" in
    gamescope) printf '%s\n' "Gamescope" ;;
    wayland) printf '%s\n' "Wayland" ;;
    x11) printf '%s\n' "X11" ;;
    *) printf '%s\n' "unknown" ;;
  esac
}

genvw_hdr_session_supports_hdr_path() {
  case "${1:-unknown}" in
    gamescope|wayland) return 0 ;;
    *) return 1 ;;
  esac
}

genvw_hdr_session_can_request_hdr() {
  local mode="${1:-$(genvw_hdr_display_mode)}"
  if genvw_hdr_session_supports_hdr_path "$mode"; then
    return 0
  fi
  if [ "$mode" = "x11" ] && genvw_have_gamescope; then
    return 0
  fi
  return 1
}

genvw_hdr_print_current_sdr_state() {
  local mon="${1:-}" mode="${2:-$(genvw_hdr_display_mode)}"
  echo "Selected monitor (${mon:-unknown}) currently reports HDR off."
  if genvw_hdr_session_can_request_hdr "$mode"; then
    echo "HDR can still be requested for this launch path."
    echo "Some games expose HDR without HDR=1; others need the Proton/DXVK HDR launch path."
  else
    echo "This launch path still needs Wayland or Gamescope before HDR can be requested."
  fi
}

genvw_hdr_effective_display_mode() {
  if [ "${GS:-0}" = "1" ] && genvw_have_gamescope; then
    printf '%s\n' "gamescope"
    return 0
  fi
  genvw_hdr_display_mode
}

genvw_should_export_hdr_wsi() {
  local mode="${1:-$(genvw_hdr_effective_display_mode)}" rdna_gen=""

  case "$mode" in
    wayland|gamescope) ;;
    *) return 0 ;;
  esac

  rdna_gen="$(detect_rdna_gen 2>/dev/null || printf '0')"
  case "$rdna_gen" in
    2|3|4) ;;
    *) return 0 ;;
  esac

  return 1
}

genvw_hdr_warn_runtime_if_unsupported() {
  local mode="${1:-$(genvw_hdr_effective_display_mode)}"
  genvw_hdr_session_supports_hdr_path "$mode" && return 0
  warn "gENVW: HDR=1 requires Wayland or Gamescope. Current session: $(genvw_hdr_display_label "$mode")."
  if genvw_have_gamescope; then
    msg "    Tip: Use Gamescope for HDR on X11, or launch from a Wayland/Gamescope session."
  else
    msg "    Tip: Install Gamescope for HDR on X11, or switch to a Wayland compositor."
  fi
}

genvw_hdr_print_wizard_intro() {
  local mode="${1:-$(genvw_hdr_display_mode)}" env_label=""
  if declare -F genvw_wizard_hdr_env_label >/dev/null 2>&1; then
    env_label="$(genvw_wizard_hdr_env_label)"
  else
    env_label="$(genvw_hdr_env_label)"
  fi
  echo "${BOLD}HDR:${RESET} Enable Linux HDR path (${env_label})."
  case "$mode" in
    gamescope)
      echo "Gamescope session detected → HDR can work here."
      ;;
    wayland)
      echo "Wayland session detected → HDR can work here."
      ;;
    x11)
      echo "Current session: X11."
      echo "HDR on Linux requires Wayland or Gamescope."
      if genvw_have_gamescope; then
        echo "Gamescope is installed and can provide HDR for games on X11."
      else
        echo "Gamescope was not detected; plain X11 HDR will not work."
      fi
      ;;
    *)
      echo "Current session: unknown."
      echo "HDR on Linux usually requires Wayland or Gamescope."
      if genvw_have_gamescope; then
        echo "If you are gaming on X11, Gamescope can provide the HDR path."
      fi
      ;;
  esac
}

genvw_hdr_warn_wizard_choice_if_unsupported() {
  local mode="${1:-$(genvw_hdr_display_mode)}"
  genvw_hdr_session_supports_hdr_path "$mode" && return 0
  warn "HDR was enabled, but the current session looks like $(genvw_hdr_display_label "$mode")."
  if genvw_have_gamescope; then
    msg "    Enable GS=1 later in the wizard to provide HDR through Gamescope on X11."
  else
    msg "    This launch line will not provide HDR on plain X11. Use Wayland or install Gamescope."
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Multi-monitor detection (Layer 1 + Layer 2)
# ─────────────────────────────────────────────────────────────────────────────
# Layer 1 backends: connector + resolution + HDR + physical size via compositor tools
# Layer 2: model name enrichment via hwinfo (joined by physical size in mm)
# Output: tab-separated lines: CONNECTOR\tMODEL\tRES\tREFRESH\tHDR\tSIZE_MM\tPRIORITY

# _genvw_detect_monitors_kscreen
# KDE Wayland via kscreen-doctor --json.
# Best source: has HDR capability, VRR, priority, physical size.
# Requires: kscreen-doctor, python3
_genvw_detect_monitors_kscreen() {
  local -n _out="$1"
  local json
  json="$(kscreen-doctor --json 2>/dev/null)" || return 1
  [ -n "$json" ] || return 1

  local conn res rate hdr sw sh pri
  while IFS=$'\t' read -r conn res rate hdr sw sh pri; do
    [ -n "$conn" ] || continue
    _out+=("${conn}"$'\t'"Unknown"$'\t'"${res}"$'\t'"${rate}"$'\t'"${hdr}"$'\t'"${sw}x${sh}"$'\t'"${pri}")
  done < <(printf '%s' "$json" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except (json.JSONDecodeError, ValueError):
    sys.exit(0)
for o in data.get("outputs", []):
    if not o.get("connected"):
        continue
    name = o.get("name", "?")
    hdr_raw = o.get("hdr", False)
    if isinstance(hdr_raw, bool):
        hdr_val = "1" if hdr_raw else "0"
    elif isinstance(hdr_raw, dict):
        hdr_val = "1" if hdr_raw.get("supported", False) else "0"
    else:
        hdr_val = "?"
    pri = o.get("priority", 99)
    sz = o.get("sizeMM", {})
    sw = sz.get("width", 0)
    sh = sz.get("height", 0)
    cur_id = o.get("currentModeId", "")
    modes = o.get("modes", [])
    cur = next((m for m in modes if m.get("id") == cur_id), {})
    res_name = cur.get("name", "?")
    rate = int(cur.get("refreshRate", 0))
    print(f"{name}\t{res_name}\t{rate}\t{hdr_val}\t{sw}\t{sh}\t{pri}")
' 2>/dev/null)
}

# _genvw_detect_monitors_sway
# Sway via swaymsg -t get_outputs (JSON).
# Has resolution, refresh, physical size. No HDR info.
_genvw_detect_monitors_sway() {
  local -n _out="$1"
  local json
  json="$(swaymsg -t get_outputs 2>/dev/null)" || return 1
  [ -n "$json" ] || return 1

  local conn res rate sw sh pri focused
  while IFS=$'\t' read -r conn res rate sw sh focused; do
    [ -n "$conn" ] || continue
    pri=99
    [ "$focused" = "true" ] && pri=1
    _out+=("${conn}"$'\t'"Unknown"$'\t'"${res}"$'\t'"${rate}"$'\t'"?"$'\t'"${sw}x${sh}"$'\t'"${pri}")
  done < <(printf '%s' "$json" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except (json.JSONDecodeError, ValueError):
    sys.exit(0)
for o in data:
    if not o.get("active"):
        continue
    name = o.get("name", "?")
    cur = o.get("current_mode", {})
    w = cur.get("width", 0)
    h = cur.get("height", 0)
    rate = int(cur.get("refresh", 0) / 1000) if cur.get("refresh") else 0
    res = f"{w}x{h}" if w and h else "?"
    rect = o.get("rect", {})
    # sway reports physical size in mm at top level
    sw = o.get("physical_width", 0)
    sh = o.get("physical_height", 0)
    focused = "true" if o.get("focused") else "false"
    print(f"{name}\t{res}\t{rate}\t{sw}\t{sh}\t{focused}")
' 2>/dev/null)
}

# _genvw_detect_monitors_hyprland
# Hyprland via hyprctl monitors -j (JSON).
# Has resolution, refresh, physical size. No HDR info.
_genvw_detect_monitors_hyprland() {
  local -n _out="$1"
  local json
  json="$(hyprctl monitors -j 2>/dev/null)" || return 1
  [ -n "$json" ] || return 1

  local conn res rate sw sh focused
  while IFS=$'\t' read -r conn res rate sw sh focused; do
    [ -n "$conn" ] || continue
    local pri=99
    [ "$focused" = "true" ] && pri=1
    _out+=("${conn}"$'\t'"Unknown"$'\t'"${res}"$'\t'"${rate}"$'\t'"?"$'\t'"${sw}x${sh}"$'\t'"${pri}")
  done < <(printf '%s' "$json" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except (json.JSONDecodeError, ValueError):
    sys.exit(0)
for o in data:
    if o.get("disabled"):
        continue
    name = o.get("name", "?")
    w = o.get("width", 0)
    h = o.get("height", 0)
    rate = int(o.get("refreshRate", 0))
    res = f"{w}x{h}" if w and h else "?"
    # hyprctl does not expose physical size in mm; use 0x0 (hwinfo will fill it)
    sw = 0
    sh = 0
    focused = "true" if o.get("focused") else "false"
    print(f"{name}\t{res}\t{rate}\t{sw}\t{sh}\t{focused}")
' 2>/dev/null)
}

# _genvw_detect_monitors_gnome
# GNOME Wayland via Mutter's org.gnome.Mutter.DisplayConfig D-Bus API.
# Uses python3 + gi.repository.Gio (PyGObject) to call GetCurrentState.
# PyGObject ships with GNOME — it's how GNOME's own tools talk to Mutter.
#
# Has: connector, display-name, resolution, refresh, physical size.
# No HDR field in the D-Bus API (GNOME does not expose HDR status yet).
_genvw_detect_monitors_gnome() {
  local -n _out="$1"

  local conn model res rate sw sh pri
  while IFS=$'\t' read -r conn model res rate sw sh pri; do
    [ -n "$conn" ] || continue
    _out+=("${conn}"$'\t'"${model}"$'\t'"${res}"$'\t'"${rate}"$'\t'"?"$'\t'"${sw}x${sh}"$'\t'"${pri}")
  done < <(python3 << 'PYEOF'
import sys
try:
    from gi.repository import Gio, GLib
except ImportError:
    sys.exit(1)

try:
    bus = Gio.bus_get_sync(Gio.BusType.SESSION)
    result = bus.call_sync(
        "org.gnome.Mutter.DisplayConfig",
        "/org/gnome/Mutter/DisplayConfig",
        "org.gnome.Mutter.DisplayConfig",
        "GetCurrentState",
        None,
        GLib.VariantType.new("(ua((ssss)a(siiddada{sv})a{sv})a(iiduba(ssss)a{sv})a{sv})"),
        Gio.DBusCallFlags.NONE,
        5000,
        None
    )
except Exception:
    sys.exit(1)

# unpack GVariant into plain Python types for safe access
data = result.unpack()
# data = (serial, monitors_list, logical_monitors_list, global_props)
monitors = data[1]
logical_monitors = data[2]

# build primary set from logical monitors
# lm = (x, y, scale, transform, is_primary, [(connector, vendor, product, serial)], props)
primary_set = set()
for lm in logical_monitors:
    is_primary = lm[4]
    assoc = lm[5]
    if is_primary:
        for a in assoc:
            primary_set.add(a[0])

for mon in monitors:
    # mon = ((connector, vendor, product, serial), modes[], properties{})
    info = mon[0]
    modes = mon[1]
    props = mon[2]

    connector = info[0]

    # display-name from properties (e.g. "LG ULTRAGEAR+")
    display_name = props.get("display-name", "Unknown")
    if not display_name:
        display_name = "Unknown"

    # physical size in mm
    sw = int(props.get("width-mm", 0))
    sh = int(props.get("height-mm", 0))

    # find current mode
    # mode = (id, width, height, refresh_rate, preferred_scale, [scales], {props})
    cur_res = "?"
    cur_rate = "?"
    for mode in modes:
        mode_props = mode[6]
        if mode_props.get("is-current", False):
            cur_res = f"{mode[1]}x{mode[2]}"
            cur_rate = str(int(mode[3]))
            break

    pri = 1 if connector in primary_set else 99

    print(f"{connector}\t{display_name}\t{cur_res}\t{cur_rate}\t{sw}\t{sh}\t{pri}")
PYEOF
)
}

# _genvw_detect_monitors_xrandr
# X11/Xwayland fallback via xrandr.
# Has connector, resolution, physical size. No HDR info.
_genvw_detect_monitors_xrandr() {
  local -n _out="$1"
  local line conn res size_w size_h pri

  while IFS= read -r line; do
    # example: "DP-1 connected primary 3440x1440+0+0 (normal left ...) 800mm x 335mm"
    conn="${line%% *}"
    [ -n "$conn" ] || continue

    # physical size
    if [[ "$line" =~ ([0-9]+)mm\ x\ ([0-9]+)mm ]]; then
      size_w="${BASH_REMATCH[1]}"
      size_h="${BASH_REMATCH[2]}"
    else
      size_w=0; size_h=0
    fi

    # current resolution (the one with a + offset)
    if [[ "$line" =~ ([0-9]+x[0-9]+)\+[0-9]+\+[0-9]+ ]]; then
      res="${BASH_REMATCH[1]}"
    else
      res="?"
    fi

    pri=99
    [[ "$line" == *" primary "* ]] && pri=1

    _out+=("${conn}"$'\t'"Unknown"$'\t'"${res}"$'\t'"?"$'\t'"?"$'\t'"${size_w}x${size_h}"$'\t'"${pri}")
  done < <(LC_ALL=C xrandr 2>/dev/null | LC_ALL=C grep " connected")
}

# _genvw_detect_monitors_sysfs
# Universal kernel fallback via /sys/class/drm.
# Minimal: connector name + top mode only. No HDR, no physical size, no model.
# Only considers AMD GPUs (vendor 0x1002).
_genvw_detect_monitors_sysfs() {
  local -n _out="$1"
  local conn_path conn card top_mode

  for conn_path in /sys/class/drm/card*-*; do
    [ -e "$conn_path/status" ] || continue
    [ "$(cat "$conn_path/status" 2>/dev/null)" = "connected" ] || continue

    # card node: /sys/class/drm/card1-DP-1 → card part is /sys/class/drm/card1
    card="${conn_path%%-*}"
    # only AMD cards (vendor 0x1002)
    [ -e "$card/device/vendor" ] || continue
    [ "$(cat "$card/device/vendor" 2>/dev/null)" = "0x1002" ] || continue

    # connector name: strip "cardN-" prefix
    conn="${conn_path##*/}"
    conn="${conn#card[0-9]-}"
    conn="${conn#card[0-9][0-9]-}"

    top_mode="$(head -1 "$conn_path/modes" 2>/dev/null || true)"
    [ -n "$top_mode" ] || top_mode="?"

    _out+=("${conn}"$'\t'"Unknown"$'\t'"${top_mode}"$'\t'"?"$'\t'"?"$'\t'"0x0"$'\t'"99")
  done
}

# _genvw_enrich_monitors_hwinfo
# Reads hwinfo --monitor output, extracts Model + Vendor + physical Size,
# then joins into the Layer 1 array by matching physical size (mm).
#
# Join key: physical size in mm — both compositor tools and hwinfo report it.
# Two different monitors almost never share the exact same WxH mm.
# Two identical monitors get the same model name, which is correct.
_genvw_enrich_monitors_hwinfo() {
  local -n _out="$1"
  local -A _model_by_size=()
  local -A _vendor_by_size=()

  local _hw_model="" _hw_vendor="" _hw_sw="" _hw_sh=""

  while IFS= read -r line; do
    # strip leading whitespace
    line="${line#"${line%%[![:space:]]*}"}"
    case "$line" in
      Model:*)
        # extract quoted value: Model: "LG ULTRAGEAR+"
        if [[ "$line" =~ Model:\ *\"(.+)\" ]]; then
          _hw_model="${BASH_REMATCH[1]}"
        else
          _hw_model=""
        fi
        ;;
      Vendor:*)
        # hwinfo vendor formats:
        #   Vendor: MSI
        #   Vendor: GSM "LG ELECTRONICS"
        # prefer the quoted display name when present
        if [[ "$line" =~ Vendor:.*\"(.+)\" ]]; then
          _hw_vendor="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ Vendor:\ *([^\"[:space:]]+) ]]; then
          _hw_vendor="${BASH_REMATCH[1]}"
        else
          _hw_vendor=""
        fi
        # trim trailing whitespace
        _hw_vendor="${_hw_vendor%"${_hw_vendor##*[![:space:]]}"}"
        ;;
      Size:*)
        if [[ "$line" =~ ([0-9]+)x([0-9]+)\ *mm ]]; then
          _hw_sw="${BASH_REMATCH[1]}"
          _hw_sh="${BASH_REMATCH[2]}"
          if [ -n "$_hw_model" ] && [ "$_hw_sw" != "0" ] && [ "$_hw_sh" != "0" ]; then
            # trim redundant vendor prefix from model name
            # e.g. "LG ELECTRONICS LG ULTRAGEAR+" → "LG ULTRAGEAR+"
            if [ -n "$_hw_vendor" ]; then
              local _vup="${_hw_vendor^^}"
              local _mup="${_hw_model^^}"
              if [[ "$_mup" == "${_vup} "* ]]; then
                _hw_model="${_hw_model:$(( ${#_hw_vendor} + 1 ))}"
              fi
            fi
            _model_by_size["${_hw_sw}x${_hw_sh}"]="$_hw_model"
            _vendor_by_size["${_hw_sw}x${_hw_sh}"]="$_hw_vendor"
          fi
        fi
        # reset per-monitor state after Size (last field per monitor block)
        _hw_model=""; _hw_vendor=""; _hw_sw=""; _hw_sh=""
        ;;
    esac
  done < <(LC_ALL=C hwinfo --monitor 2>/dev/null)

  # join: replace "Unknown" model with hwinfo model where physical size matches
  local i conn cur_model cur_res rate hdr size pri
  for i in "${!_out[@]}"; do
    IFS=$'\t' read -r conn cur_model cur_res rate hdr size pri <<<"${_out[$i]}"
    if [ "$cur_model" = "Unknown" ] && [ "$size" != "0x0" ] && [ -n "${_model_by_size[$size]:-}" ]; then
      _out[$i]="${conn}"$'\t'"${_model_by_size[$size]}"$'\t'"${cur_res}"$'\t'"${rate}"$'\t'"${hdr}"$'\t'"${size}"$'\t'"${pri}"
    fi
  done
}

# genvw_detect_monitors
# Detects all connected monitors using a layered fallback strategy.
# Outputs tab-separated lines: CONNECTOR\tMODEL\tRES\tREFRESH\tHDR\tSIZE_MM\tPRIORITY
# Returns 0 on success (at least one monitor found), 1 on failure.
genvw_detect_monitors() {
  # test bypass: skip all detection when explicitly disabled
  [ "${GENVW_NO_MONITOR_DETECT:-0}" = "1" ] && return 1

  local -a _mon_lines=()

  # Layer 1: compositor tool (connector + resolution + HDR + physical size)
  if have kscreen-doctor && have python3 && [ -n "${WAYLAND_DISPLAY:-}" ]; then
    _genvw_detect_monitors_kscreen _mon_lines
  elif have swaymsg && have python3 && [ -n "${SWAYSOCK:-}" ]; then
    _genvw_detect_monitors_sway _mon_lines
  elif have hyprctl && have python3 && [ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then
    _genvw_detect_monitors_hyprland _mon_lines
  elif [ -n "${WAYLAND_DISPLAY:-}" ] && have python3 && _genvw_detect_monitors_gnome _mon_lines 2>/dev/null; then
    # GNOME Wayland: uses Mutter D-Bus via PyGObject. Placed after compositor-
    # specific checks so KDE/Sway/Hyprland users get their native backend.
    :
  elif have xrandr; then
    _genvw_detect_monitors_xrandr _mon_lines
  else
    _genvw_detect_monitors_sysfs _mon_lines
  fi

  # Layer 2: model names from hwinfo, joined by physical size in mm
  if have hwinfo; then
    _genvw_enrich_monitors_hwinfo _mon_lines
  fi

  # Output
  [ "${#_mon_lines[@]}" -gt 0 ] || return 1
  local line
  for line in "${_mon_lines[@]}"; do
    printf '%s\n' "$line"
  done
}

# genvw_monitor_count
# Returns the number of connected monitors.
genvw_monitor_count() {
  local count=0
  while IFS= read -r _; do
    (( count++ ))
  done < <(genvw_detect_monitors 2>/dev/null)
  printf '%s\n' "$count"
}

genvw_ffsr_warn_if_native_wayland_noop() {
  if [ "${PROTON_ENABLE_WAYLAND:-0}" = "1" ] && [ "${HDR:-0}" != "1" ] && [ -n "${FFSR:-}" ] && [ "${FFSR:-0}" != "0" ]; then
    warn "gENVW: FFSR has no effect with Wine's native Wayland driver."
    msg "    Tip: FFSR is the Wine fullscreen FSR path for X11/Xwayland."
  fi
}

genvw_gamescope_target_monitor_line() {
  local want_conn="${1:-}"
  local line="" first_line="" primary_line=""
  local conn="" model="" res="" rate="" hdr="" size="" pri=""

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [ -n "$first_line" ] || first_line="$line"
    IFS=$'\t' read -r conn model res rate hdr size pri <<<"$line"
    if [ "$pri" = "1" ] && [ -z "$primary_line" ]; then
      primary_line="$line"
    fi
    if [ -n "$want_conn" ] && [ "$conn" = "$want_conn" ]; then
      printf '%s\n' "$line"
      return 0
    fi
  done < <(genvw_detect_monitors 2>/dev/null)

  if [ -n "$want_conn" ]; then
    return 1
  fi
  if [ -n "$primary_line" ]; then
    printf '%s\n' "$primary_line"
    return 0
  fi
  if [ -n "$first_line" ]; then
    printf '%s\n' "$first_line"
    return 0
  fi
  return 1
}

genvw_monitor_resolution_base() {
  local res="${1:-}"
  case "$res" in
    [1-9][0-9]*x[1-9][0-9]*)
      printf '%s\n' "${res%%@*}"
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

genvw_gamescope_filter_supports_sharpness() {
  case "${1:-0}" in
    fsr|nis) return 0 ;;
    *) return 1 ;;
  esac
}

genvw_normalize_gamescope_knobs() {
  if [ "${GS:-0}" != "1" ]; then
    if [ -n "${GSFULL:-}" ] && [ "${GSFULL:-0}" != "0" ]; then
      warn "gENVW: GSFULL=${GSFULL} ignored — requires GS=1."
      GSFULL=0
    fi
    if [ -n "${GSGRAB:-}" ] && [ "${GSGRAB:-0}" != "0" ]; then
      warn "gENVW: GSGRAB=${GSGRAB} ignored — requires GS=1."
      GSGRAB=0
    fi
    if [ -n "${GSFSR:-}" ] && [ "${GSFSR:-0}" != "0" ]; then
      warn "gENVW: GSFSR=${GSFSR} ignored — requires GS=1."
      GSFSR=0
    fi
    if [ -n "${GSSHARP:-}" ]; then
      warn "gENVW: GSSHARP=${GSSHARP} ignored — requires GS=1."
      unset GSSHARP
    fi
    if [ -n "${GSRES:-}" ]; then
      warn "gENVW: GSRES=${GSRES} ignored — requires GS=1."
      unset GSRES
    fi
    return 0
  fi

  case "${GSFULL:-0}" in
    ''|0|1) ;;
    *)
      die "Invalid GSFULL value: ${GSFULL} (allowed: 0 or 1)"
      ;;
  esac

  case "${GSGRAB:-0}" in
    ''|0|1) ;;
    *)
      die "Invalid GSGRAB value: ${GSGRAB} (allowed: 0 or 1)"
      ;;
  esac

  case "${GSFSR:-0}" in
    ''|0)
      GSFSR=0
      ;;
    fsr|nis|pixel)
      ;;
    *)
      die "Invalid GSFSR value: ${GSFSR} (allowed: 0, fsr, nis, pixel)"
      ;;
  esac

  if [ -n "${GSSHARP:-}" ]; then
    case "$GSSHARP" in
      *[!0-9]*)
        die "Invalid GSSHARP value: ${GSSHARP} (expected 0-20)"
        ;;
      *)
        if [ "$GSSHARP" -lt 0 ] || [ "$GSSHARP" -gt 20 ]; then
          die "Invalid GSSHARP value: ${GSSHARP} (expected 0-20)"
        fi
        ;;
    esac

    if ! genvw_gamescope_filter_supports_sharpness "${GSFSR:-0}"; then
      warn "gENVW: GSSHARP=${GSSHARP} ignored — sharpness only applies to GSFSR=fsr|nis."
      unset GSSHARP
    fi
  fi

  if [ -n "${GSRES:-}" ]; then
    case "$GSRES" in
      [1-9][0-9]*x[1-9][0-9]*) ;;
      *)
        die "Invalid GSRES value: ${GSRES} (expected WxH, e.g. 1920x1080)"
        ;;
    esac
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# MON= knob validation & resolution
# ─────────────────────────────────────────────────────────────────────────────

# genvw_validate_mon
# Validates and resolves the MON= knob value.
# Accepts connector name (DP-1, HDMI-A-1) or numeric shorthand (1, 2).
# On success: prints the resolved connector name to stdout.
# On failure: prints error to stderr and returns 1.
# security: connector names validated against a strict pattern to block injection.
genvw_validate_mon() {
  local mon="${1:-}"
  [ -n "$mon" ] || return 0

  # numeric shorthand: resolve to connector name
  if [[ "$mon" =~ ^[0-9]+$ ]]; then
    if [ "$mon" -lt 1 ] || [ "$mon" -gt 99 ]; then
      err "gENVW: Invalid MON value: $mon (numeric shorthand must be 1-99)"
      return 1
    fi
    local resolved
    resolved="$(genvw_detect_monitors 2>/dev/null | sed -n "${mon}p" | cut -f1)"
    if [ -z "$resolved" ]; then
      err "gENVW: MON=$mon does not match any detected monitor."
      msg "    Run with GENVW_DEBUG=1 to see detected monitors."
      return 1
    fi
    printf '%s\n' "$resolved"
    return 0
  fi

  # connector name: validate format
  # valid: DP-1, DP-2, HDMI-A-1, HDMI-A-2, VGA-1, DVI-D-1, eDP-1
  # pattern: uppercase letters, hyphens, digits — no spaces, slashes, or specials
  if [[ ! "$mon" =~ ^[A-Za-z][A-Za-z0-9-]+$ ]]; then
    err "gENVW: Invalid MON value: $mon"
    msg "    Expected a connector name (DP-1, HDMI-A-1) or a number (1, 2)."
    return 1
  fi

  printf '%s\n' "$mon"
}

# genvw_normalize_mon_knob
# Validates MON= and resolves numeric shorthand. Call from the wrapper
# section, before the GS=1 block.
# On invalid input: dies.
# On valid input: sets MON to the resolved connector name (or leaves it unset).
genvw_normalize_mon_knob() {
  [ -n "${MON:-}" ] || return 0

  local resolved
  resolved="$(genvw_validate_mon "$MON")" || exit 1
  MON="$resolved"

  # MON can be recorded without GS=1 from the wizard, but hard pinning still
  # requires Gamescope. Keep the warning for non-Wayland flows where MON is
  # unlikely to have any effect; stay quiet for native Wayland where MON may be
  # carried as the selected display context.
  if [ "${GS:-0}" != "1" ]; then
    local mode
    mode="$(genvw_hdr_display_mode)"
    case "$mode" in
      gamescope)
        # already inside gamescope — MON= can still influence Gamescope sizing,
        # spec preference, and connector priority here.
        ;;
      wayland)
        ;;
      *)
        warn "gENVW: MON=$MON is set but GS=1 is not enabled."
        msg "    Tip: Gamescope can use MON for output sizing and spec preference."
        msg "    When Gamescope owns the output/DRM path, it can also select or prioritize the target connector."
        msg "    In nested desktop sessions, actual window placement still follows compositor behavior."
        ;;
    esac
  fi
}

genvw_profile_warn_map_conflicts() {
  local -n profile_map_ref="$1"
  local where="$2"
  local fsr4_choice=""

  if [ -n "${profile_map_ref[FSR4_RDNA3]+set}" ]; then
    fsr4_choice="${profile_map_ref[FSR4_RDNA3]}"
  elif [ -n "${profile_map_ref[FSR4]+set}" ]; then
    fsr4_choice="${profile_map_ref[FSR4]}"
  fi

  if genvw_fsr4_choice_is_active "$fsr4_choice"; then
    if [ -n "${profile_map_ref[FFSR]+set}" ] && [ "${profile_map_ref[FFSR]:-0}" != "0" ]; then
      warn "gENVW profile: FFSR will be disabled at launch when FSR4 is active in ${where}."
    fi
    if [ -n "${profile_map_ref[GSFSR]+set}" ] && [ "${profile_map_ref[GSFSR]:-0}" != "0" ]; then
      warn "gENVW profile: GSFSR will be disabled at launch when FSR4 is active in ${where}."
    fi
  fi

  if [ -n "${profile_map_ref[HDR]+set}" ] && [ "${profile_map_ref[HDR]:-0}" = "1" ] \
    && [ -n "${profile_map_ref[FFSR]+set}" ] && [ "${profile_map_ref[FFSR]:-0}" != "0" ]; then
    warn "gENVW profile: FFSR will be disabled at launch when HDR=1 in ${where}."
  fi

  if [ -n "${profile_map_ref[GSFSR]+set}" ] && [ "${profile_map_ref[GSFSR]:-0}" != "0" ] \
    && [ -n "${profile_map_ref[FFSR]+set}" ] && [ "${profile_map_ref[FFSR]:-0}" != "0" ]; then
    warn "gENVW profile: FFSR will be disabled at launch when GSFSR is active in ${where}."
  fi
}

# -- profiles ----------------------------------------------------------------

# where profile files live
genvw_profile_dir() {
  echo "${GENVW_PROFILE_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/genvw/profiles}"
}

# allowed keys in profiles, kept in canonical save order
GENVW_PROFILE_ALLOWED_KEYS="HDR GS MON GSFULL GSGRAB GSFSR GSSHARP GSRES FSR4 FSR4_RDNA3 MLFG FSR4SHOW FFSR LSC NVMD NTS CPU GP GM D7VK NODXR FORCEDXR GPLASYNC ASYNC LSFG LSFGPERF LSFGFLOW LSFGPRESENT LSFGHDR DEBUG"

genvw_profile_key_allowed() {
  case " $GENVW_PROFILE_ALLOWED_KEYS " in
    *" ${1:-} "*) return 0 ;;
    *) return 1 ;;
  esac
}

genvw_profile_value_error() {
  local key="$1" val="$2" where="$3" detail="$4"
  err "gENVW profile: invalid ${key}=${val} in ${where}: ${detail}"
  return 1
}

genvw_profile_validate_mon_value() {
  local val="$1" where="$2"
  if [[ "$val" =~ ^[0-9]+$ ]]; then
    if [ "$val" -lt 1 ] || [ "$val" -gt 99 ]; then
      genvw_profile_value_error "MON" "$val" "$where" "expected a monitor number 1-99 or a connector name like DP-1"
      return 1
    fi
    return 0
  fi

  if [[ ! "$val" =~ ^[A-Za-z][A-Za-z0-9-]+$ ]]; then
    genvw_profile_value_error "MON" "$val" "$where" "expected a monitor number 1-99 or a connector name like DP-1"
    return 1
  fi
  return 0
}

genvw_profile_validate_key_value() {
  local key="$1" val="$2" where="$3"

  case "$key" in
    HDR | GS | GSFULL | GSGRAB | MLFG | FSR4SHOW | LSC | NVMD | NTS | GP | GM | D7VK | NODXR | LSFGPERF | LSFGHDR | DEBUG)
      case "$val" in
        0 | 1) return 0 ;;
        *) genvw_profile_value_error "$key" "$val" "$where" "expected 0 or 1"; return 1 ;;
      esac
      ;;
    LSFG)
      case "$val" in
        0 | 2 | 3 | 4) return 0 ;;
        *) genvw_profile_value_error "$key" "$val" "$where" "expected 0, 2, 3, or 4"; return 1 ;;
      esac
      ;;
    LSFGFLOW)
      if genvw_lsfg_flow_is_valid "$val"; then
        return 0
      fi
      genvw_profile_value_error "$key" "$val" "$where" "expected a value from 0.25 to 1.0"
      return 1
      ;;
    LSFGPRESENT)
      case "$val" in
        fifo | mailbox | immediate) return 0 ;;
        *) genvw_profile_value_error "$key" "$val" "$where" "expected fifo, mailbox, or immediate"; return 1 ;;
      esac
      ;;
    FORCEDXR)
      case "$val" in
        0 | 1 | 12) return 0 ;;
        *) genvw_profile_value_error "$key" "$val" "$where" "expected 0, 1, or 12"; return 1 ;;
      esac
      ;;
    ASYNC)
      case "$val" in
        0 | 1) return 0 ;;
        *) genvw_profile_value_error "$key" "$val" "$where" "expected 0 or 1"; return 1 ;;
      esac
      ;;
    GPLASYNC)
      case "$val" in
        0 | 1 | on | on-min | llasync | llasync-min | lowlat | lowlat-min | async | gplasync) return 0 ;;
        vrr-* | on-vrr-* | llasync-vrr-* | lowlat-vrr-*)
          local hz="${val##*vrr-}"
          if genvw_gplasync_hz_is_valid "$hz"; then
            return 0
          fi
          genvw_profile_value_error "$key" "$val" "$where" "VRR Hz must be 1-999"
          return 1
          ;;
        *)
          genvw_profile_value_error "$key" "$val" "$where" "expected 0, 1, on, on-min, on-vrr-NNN, llasync, llasync-min, llasync-vrr-NNN, lowlat, lowlat-min, lowlat-vrr-NNN, vrr-NNN, async, or gplasync"
          return 1
          ;;
      esac
      ;;
    FFSR)
      case "$val" in
        0 | 1 | 2 | 3 | 4 | 5) return 0 ;;
        *) genvw_profile_value_error "$key" "$val" "$where" "expected 0 or a sharpening level from 1 to 5"; return 1 ;;
      esac
      ;;
    CPU)
      case "$val" in
        0 | [1-9] | [1-9][0-9]*) return 0 ;;
        *) genvw_profile_value_error "$key" "$val" "$where" "expected 0 or a positive integer"; return 1 ;;
      esac
      ;;
    FSR4 | FSR4_RDNA3)
      case "$val" in
        0 | 1 | off | OFF) return 0 ;;
      esac
      if genvw_fsr4_is_knob_allowed "$val"; then
        return 0
      fi
      genvw_profile_value_error "$key" "$val" "$where" "expected 0, 1, off, or $(genvw_fsr4_allowed_versions_slash)"
      return 1
      ;;
    GSFSR)
      case "$val" in
        0 | fsr | nis | pixel) return 0 ;;
        *) genvw_profile_value_error "$key" "$val" "$where" "expected 0, fsr, nis, or pixel"; return 1 ;;
      esac
      ;;
    GSSHARP)
      case "$val" in
        [0-9] | 1[0-9] | 20) return 0 ;;
        *) genvw_profile_value_error "$key" "$val" "$where" "expected an integer from 0 to 20"; return 1 ;;
      esac
      ;;
    GSRES)
      case "$val" in
        [1-9][0-9]*x[1-9][0-9]*) return 0 ;;
        *) genvw_profile_value_error "$key" "$val" "$where" "expected WxH, for example 1920x1080"; return 1 ;;
      esac
      ;;
    MON)
      genvw_profile_validate_mon_value "$val" "$where"
      return $?
      ;;
    *)
      err "gENVW profile: internal validator does not know key '$key' in ${where}"
      return 1
      ;;
  esac
}

genvw_profile_validate_map() {
  local -n profile_map_ref="$1"
  local where="$2"

  if [ -n "${profile_map_ref[GSFSR]+set}" ] && [ "${profile_map_ref[GS]:-0}" != "1" ]; then
    err "gENVW profile: GSFSR requires GS=1 in ${where}"
    return 1
  fi
  if [ -n "${profile_map_ref[GSFULL]+set}" ] && [ "${profile_map_ref[GS]:-0}" != "1" ]; then
    err "gENVW profile: GSFULL requires GS=1 in ${where}"
    return 1
  fi
  if [ -n "${profile_map_ref[GSGRAB]+set}" ] && [ "${profile_map_ref[GS]:-0}" != "1" ]; then
    err "gENVW profile: GSGRAB requires GS=1 in ${where}"
    return 1
  fi
  if [ -n "${profile_map_ref[GSRES]+set}" ] && [ "${profile_map_ref[GS]:-0}" != "1" ]; then
    err "gENVW profile: GSRES requires GS=1 in ${where}"
    return 1
  fi
  if [ -n "${profile_map_ref[GSSHARP]+set}" ]; then
    if [ "${profile_map_ref[GS]:-0}" != "1" ]; then
      err "gENVW profile: GSSHARP requires GS=1 in ${where}"
      return 1
    fi
    if ! genvw_gamescope_filter_supports_sharpness "${profile_map_ref[GSFSR]:-0}"; then
      err "gENVW profile: GSSHARP requires GSFSR=fsr|nis in ${where}"
      return 1
    fi
  fi
  return 0
}

# validate profile name — same safe-basename pattern used for DLL stems
genvw_profile_name_ok() {
  local name="$1"
  [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
}

# resolve profile path from name (caller must validate name first)
genvw_profile_path() {
  echo "$(genvw_profile_dir)/$1.env"
}

# parse a profile file into canonical KEY=VALUE lines on stdout
# strict regex, never sourced — blank lines and full-line comments only
genvw_profile_parse() {
  local file="$1" line key val line_no=0
  local where=""
  declare -A _profile_map=()

  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    line="$(trim_outer_ws "$line")"
    [ -z "$line" ] && continue
    case "$line" in
      \#*) continue ;;
    esac

    if [[ ! "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      err "gENVW profile: malformed line ${line_no} in ${file}: ${line}"
      return 1
    fi

    key="${BASH_REMATCH[1]}"
    val="${BASH_REMATCH[2]}"
    where="${file}:${line_no}"

    if ! genvw_profile_key_allowed "$key"; then
      err "gENVW profile: unknown key '${key}' on line ${line_no} in ${file}"
      return 1
    fi
    if [ -n "${_profile_map[$key]+set}" ]; then
      err "gENVW profile: duplicate key '${key}' on line ${line_no} in ${file}"
      return 1
    fi
    genvw_profile_validate_key_value "$key" "$val" "$where" || return 1
    case "$key" in
      LSFGFLOW) val="$(genvw_lsfg_flow_normalize "$val")" ;;
    esac
    _profile_map["$key"]="$val"
  done < "$file"

  genvw_profile_validate_map _profile_map "$file" || return 1

  for key in $GENVW_PROFILE_ALLOWED_KEYS; do
    [ -n "${_profile_map[$key]+set}" ] && printf '%s=%s\n' "$key" "${_profile_map[$key]}"
  done
  return 0
}

# load profile: for each key, export only if not already set in the environment
genvw_profile_load() {
  local name="$1" pfile key val parsed=""
  genvw_profile_name_ok "$name" || { err "gENVW: invalid profile name '$name'"; return 1; }
  pfile="$(genvw_profile_path "$name")"
  [ -f "$pfile" ] || { err "gENVW: profile '$name' not found ($pfile)"; return 1; }
  if ! parsed="$(genvw_profile_parse "$pfile")"; then
    return 1
  fi
  while IFS='=' read -r key val; do
    [ -n "$key" ] || continue
    if [ -z "${!key+set}" ]; then
      export "$key=$val"
    fi
  done <<< "$parsed"
  return 0
}

# save profile atomically (mktemp in same dir + mv)
genvw_profile_save() {
  local name="$1" overwrite_ok="$2"; shift 2
  local dir key val tmpf pfile prompt
  genvw_profile_name_ok "$name" || { err "gENVW: invalid profile name '$name'"; return 1; }
  dir="$(genvw_profile_dir)"
  mkdir -p "$dir" || { err "gENVW: cannot create profile dir: $dir"; return 1; }
  pfile="$(genvw_profile_path "$name")"

  declare -A _profile_map=()
  for arg in "$@"; do
    if [[ ! "$arg" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      err "gENVW profile save: bad argument '$arg' (expected KEY=VALUE)"
      return 1
    fi
    key="${BASH_REMATCH[1]}"
    val="${BASH_REMATCH[2]}"

    if ! genvw_profile_key_allowed "$key"; then
      err "gENVW profile save: unknown key '$key'"
      return 1
    fi
    if [ -n "${_profile_map[$key]+set}" ]; then
      err "gENVW profile save: duplicate key '$key'"
      return 1
    fi

    genvw_profile_validate_key_value "$key" "$val" "profile save '$name'" || return 1
    case "$key" in
      LSFGFLOW) val="$(genvw_lsfg_flow_normalize "$val")" ;;
    esac
    _profile_map["$key"]="$val"
  done
  [ ${#_profile_map[@]} -eq 0 ] && { err "gENVW profile save: no valid knobs provided"; return 1; }

  genvw_profile_validate_map _profile_map "profile save '$name'" || return 1
  genvw_profile_warn_map_conflicts _profile_map "profile save '$name'"

  if [ -f "$pfile" ] && [ "$overwrite_ok" != "1" ]; then
    prompt="${YELLOW}Overwrite profile '${name}'? [y/N]: ${RESET}"
    if ! ask_yes_no_default "$prompt" "n"; then
      err "gENVW profile save: cancelled."
      return 1
    fi
  fi

  tmpf="$(mktemp "$dir/.tmp.XXXXXX")" || { err "gENVW: mktemp failed in $dir"; return 1; }
  chmod 600 "$tmpf"
  for key in $GENVW_PROFILE_ALLOWED_KEYS; do
    [ -n "${_profile_map[$key]+set}" ] && printf '%s=%s\n' "$key" "${_profile_map[$key]}" >> "$tmpf"
  done
  mv -f "$tmpf" "$pfile" || { err "gENVW: atomic rename failed"; rm -f "$tmpf"; return 1; }
  msg "Profile '$name' saved → $pfile"
}

# delete a saved profile
genvw_profile_delete() {
  local name="$1" delete_ok="$2" pfile
  genvw_profile_name_ok "$name" || { err "gENVW: invalid profile name '$name'"; return 1; }
  pfile="$(genvw_profile_path "$name")"
  [ -f "$pfile" ] || { err "gENVW: profile '$name' not found"; return 1; }

  if [ "$delete_ok" != "1" ]; then
    if ! ask_yes_no_default "${YELLOW}Delete profile '${name}'? [y/N]: ${RESET}" "n"; then
      err "gENVW profile delete: cancelled."
      return 1
    fi
  fi

  rm -f "$pfile" && msg "Profile '$name' deleted."
}

# dispatch: genvw profile list|show|print|save|delete
genvw_profile_cmd() {
  local subcmd="${1:-}"; shift 2>/dev/null || true
  case "$subcmd" in
    list)
      local dir pfile name parsed
      dir="$(genvw_profile_dir)"
      if [ ! -d "$dir" ] || [ -z "$(ls -A "$dir" 2>/dev/null)" ]; then
        msg "No saved profiles."
        msg "Create one: genvw profile save NAME HDR=1 GS=1 ..."
        return 0
      fi
      # table header
      printf "  %-20s %-8s %-4s %-4s %-4s %s\n" "NAME" "FSR4" "HDR" "GS" "CPU" "FLAGS"
      printf "  %-20s %-8s %-4s %-4s %-4s %s\n" "----" "----" "---" "--" "---" "-----"
      for pfile in "$dir"/*.env; do
        [ -f "$pfile" ] || continue
        name="$(basename "$pfile" .env)"
        if ! parsed="$(genvw_profile_parse "$pfile")"; then
          warn "gENVW profile: skipping invalid profile '$name'" >&2
          continue
        fi
        # read key values for this profile
        declare -A _pv=()
        while IFS='=' read -r _pk _pval; do
          [ -n "$_pk" ] || continue
          _pv["$_pk"]="$_pval"
        done <<< "$parsed"
        # collect minor flags that are set and non-zero
        local flags=""
        [ -n "${_pv[FORCEDXR]+set}" ] && [ "${_pv[FORCEDXR]}" != "0" ] && flags="${flags:+$flags,}FORCEDXR=${_pv[FORCEDXR]}"
        [ -n "${_pv[GPLASYNC]+set}" ] && [ "${_pv[GPLASYNC]}" != "0" ] && flags="${flags:+$flags,}GPLASYNC=${_pv[GPLASYNC]}"
        [ -n "${_pv[LSFG]+set}" ] && [ "${_pv[LSFG]}" != "0" ] && flags="${flags:+$flags,}LSFG=${_pv[LSFG]}"
        [ -n "${_pv[LSFGFLOW]+set}" ] && flags="${flags:+$flags,}LSFGFLOW=${_pv[LSFGFLOW]}"
        [ -n "${_pv[LSFGPRESENT]+set}" ] && flags="${flags:+$flags,}LSFGPRESENT=${_pv[LSFGPRESENT]}"
        [ -n "${_pv[LSFGHDR]+set}" ] && flags="${flags:+$flags,}LSFGHDR=${_pv[LSFGHDR]}"
        for _fk in GSFULL GSGRAB MLFG FSR4SHOW FFSR LSC NVMD NTS GP GM D7VK NODXR ASYNC LSFGPERF DEBUG; do
          [ -n "${_pv[$_fk]+set}" ] && [ "${_pv[$_fk]}" != "0" ] && flags="${flags:+$flags,}$_fk"
        done
        [ -n "${_pv[GSFSR]+set}" ] && [ "${_pv[GSFSR]}" != "0" ] && flags="${flags:+$flags,}GSFSR=${_pv[GSFSR]}"
        [ -n "${_pv[MON]+set}" ] && flags="${flags:+$flags,}MON"
        printf "  %-20s %-8s %-4s %-4s %-4s %s\n" \
          "$name" "${_pv[FSR4]:-–}" "${_pv[HDR]:-–}" "${_pv[GS]:-–}" "${_pv[CPU]:-–}" "${flags:-–}"
        unset _pv
      done
      ;;
    show)
      local name="${1:-}"
      [ -z "$name" ] && { err "Usage: genvw profile show NAME"; return 1; }
      genvw_profile_name_ok "$name" || { err "gENVW: invalid profile name '$name'"; return 1; }
      local pfile="$(genvw_profile_path "$name")" parsed=""
      [ -f "$pfile" ] || { err "gENVW: profile '$name' not found"; return 1; }
      if ! parsed="$(genvw_profile_parse "$pfile")"; then
        return 1
      fi
      printf "Profile: %s\n" "$name"
      printf "  %-12s %s\n" "KEY" "VALUE"
      printf "  %-12s %s\n" "---" "-----"
      while IFS='=' read -r _sk _sv; do
        [ -n "$_sk" ] || continue
        printf "  %-12s %s\n" "$_sk" "$_sv"
      done <<< "$parsed"
      echo
      # build launch hint from stored keys
      local _hint=""
      while IFS='=' read -r _sk _sv; do
        [ -n "$_sk" ] || continue
        _hint="${_hint:+$_hint }${_sk}=${_sv}"
      done <<< "$parsed"
      msg "Launch: genvw --profile $name %command%"
      msg "Equivalent: $_hint genvw %command%"
      ;;
    print)
      local name="${1:-}"
      [ -z "$name" ] && { err "Usage: genvw profile print NAME"; return 1; }
      genvw_profile_name_ok "$name" || { err "gENVW: invalid profile name '$name'"; return 1; }
      local pfile="$(genvw_profile_path "$name")"
      [ -f "$pfile" ] || { err "gENVW: profile '$name' not found"; return 1; }
      genvw_profile_parse "$pfile"
      ;;
    save)
      local name="" overwrite_ok=0 arg
      local -a kv_args=()
      for arg in "$@"; do
        case "$arg" in
          --yes | -y) overwrite_ok=1 ;;
          *)
            if [ -z "$name" ]; then
              name="$arg"
            else
              kv_args+=("$arg")
            fi
            ;;
        esac
      done
      [ -z "$name" ] && { err "Usage: genvw profile save NAME KEY=VALUE ..."; return 1; }
      genvw_profile_save "$name" "$overwrite_ok" "${kv_args[@]}"
      ;;
    delete)
      local name="" delete_ok=0 arg
      for arg in "$@"; do
        case "$arg" in
          --yes | -y) delete_ok=1 ;;
          *)
            if [ -z "$name" ]; then
              name="$arg"
            else
              err "Usage: genvw profile delete NAME [--yes]"
              return 1
            fi
            ;;
        esac
      done
      [ -z "$name" ] && { err "Usage: genvw profile delete NAME"; return 1; }
      genvw_profile_delete "$name" "$delete_ok"
      ;;
    *)
      err "gENVW: unknown profile command '${subcmd:-}'"
      msg "Usage: genvw profile list|show|print|save|delete" >&2
      return 1
      ;;
  esac
}

# ─────────────────────────────────────────────────────────────────────────────
# Wizard: monitor detection + selection prompt
# ─────────────────────────────────────────────────────────────────────────────

# genvw_wizard_monitor_scan
# Detects connected monitors early so later display prompts can use real data.
# Populates:
#   GENVW_WIZARD_MON_LINES array
#   WIZARD_MON_COUNT
#   WIZARD_MON_REFRESH
# Prints a compact summary, but does not ask the user to choose yet.
genvw_wizard_monitor_scan() {
  WIZARD_MON=""
  WIZARD_MON_HDR="?"
  WIZARD_MON_RES=""
  WIZARD_MON_REFRESH=""
  WIZARD_MON_COUNT=0
  GENVW_WIZARD_MON_LINES=()

  local line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    GENVW_WIZARD_MON_LINES+=("$line")
  done < <(genvw_detect_monitors 2>/dev/null)

  WIZARD_MON_COUNT="${#GENVW_WIZARD_MON_LINES[@]}"

  if [ "$WIZARD_MON_COUNT" -eq 0 ]; then
    warn "gENVW: Could not detect any connected monitors."
    msg "    Gamescope monitor targeting may be limited."
    echo
    return 0
  fi

  if [ "$WIZARD_MON_COUNT" -eq 1 ]; then
    IFS=$'\t' read -r _wm_conn _wm_model _wm_res _wm_rate _wm_hdr _wm_size _wm_pri <<<"${GENVW_WIZARD_MON_LINES[0]}"
    genvw_wizard_refresh_hz_from_value "$_wm_rate" WIZARD_MON_REFRESH || WIZARD_MON_REFRESH=""
    unset _wm_conn _wm_model _wm_res _wm_rate _wm_hdr _wm_size _wm_pri
  else
    local _wm_line _wm_rate _wm_pri
    for _wm_line in "${GENVW_WIZARD_MON_LINES[@]}"; do
      IFS=$'\t' read -r _ _ _ _wm_rate _ _ _wm_pri <<<"$_wm_line"
      if [ "$_wm_pri" = "1" ] && genvw_wizard_refresh_hz_from_value "$_wm_rate" WIZARD_MON_REFRESH; then
        break
      fi
    done
    unset _wm_line _wm_rate _wm_pri
  fi

  echo "${BOLD}Detected monitors:${RESET}"
  local idx=0 conn model res rate hdr size pri hdr_tag pri_tag
  for line in "${GENVW_WIZARD_MON_LINES[@]}"; do
    (( idx++ ))
    IFS=$'\t' read -r conn model res rate hdr size pri <<<"$line"

    case "$hdr" in
      1) hdr_tag="${GREEN}HDR${RESET}" ;;
      0) hdr_tag="SDR" ;;
      *) hdr_tag="HDR?" ;;
    esac

    pri_tag=""
    [ "$pri" = "1" ] && pri_tag=" (primary)"

    local rate_str=""
    [ "$rate" != "?" ] && [ "$rate" != "0" ] && rate_str="@${rate}Hz"

    local model_str=""
    [ "$model" != "Unknown" ] && model_str="  ${CYAN}${model}${RESET}"

    printf "  [%d] %-10s%s  %s%s  %s%s\n" \
      "$idx" "$conn" "$model_str" "$res" "$rate_str" "$hdr_tag" "$pri_tag"
  done
  echo
}

# genvw_wizard_monitor_prompt
# Lets the user pick the target monitor from the cached detection results.
# When Gamescope is enabled later, the same selection is reused for MON= as
# output sizing/spec preference. Embedded/DRM Gamescope can use it to select or
# prioritize a connector. Nested desktop sessions may still place the Gamescope
# window according to compositor behavior.
# Sets:
#   WIZARD_MON       — resolved connector name (e.g. "DP-1") or "" if skipped
#   WIZARD_MON_HDR   — "1" if the current output reports HDR on, "0" if it reports HDR off/SDR, "?" if unknown
#   WIZARD_MON_RES   — detected resolution (e.g. 3840x2160) or ""
#   WIZARD_MON_REFRESH — detected refresh in whole Hz (e.g. 165) or ""
genvw_wizard_monitor_prompt() {
  WIZARD_MON=""
  WIZARD_MON_HDR="?"
  WIZARD_MON_RES=""
  WIZARD_MON_REFRESH=""

  if [ -z "${WIZARD_MON_COUNT:-}" ]; then
    genvw_wizard_monitor_scan
  fi

  if [ "${WIZARD_MON_COUNT:-0}" -eq 0 ]; then
    warn "gENVW: Monitor selection skipped because no monitor data is available."
    msg "    You can set MON=DP-1 manually."
    echo
    return 0
  fi

  echo "${BOLD}MON:${RESET} Choose the target monitor."
  echo "Used for HDR checks and GPLASYNC refresh defaults."
  echo "If Gamescope is enabled later, this same selection becomes MON= for Gamescope output sizing and spec preference."
  echo "In embedded/DRM Gamescope sessions this can select or prioritize the target connector."
  echo "In nested desktop sessions, actual window placement may still follow compositor behavior."

  if [ "${WIZARD_MON_COUNT:-0}" -eq 1 ]; then
    IFS=$'\t' read -r conn model res rate hdr size pri <<<"${GENVW_WIZARD_MON_LINES[0]}"
    WIZARD_MON="$conn"
    WIZARD_MON_HDR="$hdr"
    WIZARD_MON_RES="$(genvw_monitor_resolution_base "$res" || true)"
    genvw_wizard_refresh_hz_from_value "$rate" WIZARD_MON_REFRESH || WIZARD_MON_REFRESH=""
    msg "Single monitor detected → auto-selected ${BOLD}$conn${RESET}"
    if [ "$model" != "Unknown" ]; then
      msg "  ($model)"
    elif [ "$res" != "?" ]; then
      msg "  (${res})"
    fi
    echo
    return 0
  fi

  local choice
  while :; do
    printf "%s" "${YELLOW}Monitor [1-${WIZARD_MON_COUNT}, default=1]: ${RESET}"
    tty_read choice || choice=""
    choice=$(trim "$choice")
    [ -z "$choice" ] && choice="1"

    case "$choice" in
      *[!0-9]*)
        printf "%s\n\n" "${RED}Enter a number between 1 and ${WIZARD_MON_COUNT}.${RESET}"
        continue
        ;;
    esac
    if [ "$choice" -lt 1 ] || [ "$choice" -gt "${WIZARD_MON_COUNT}" ]; then
      printf "%s\n\n" "${RED}Enter a number between 1 and ${WIZARD_MON_COUNT}.${RESET}"
      continue
    fi

    local sel_idx=$(( choice - 1 ))
    IFS=$'\t' read -r conn model res rate hdr size pri <<<"${GENVW_WIZARD_MON_LINES[$sel_idx]}"
    WIZARD_MON="$conn"
    WIZARD_MON_HDR="$hdr"
    WIZARD_MON_RES="$(genvw_monitor_resolution_base "$res" || true)"
    genvw_wizard_refresh_hz_from_value "$rate" WIZARD_MON_REFRESH || WIZARD_MON_REFRESH=""
    printf "%s\n\n" "${GREEN}Selected: $conn${RESET}$([ "$model" != "Unknown" ] && echo " ($model)")"
    break
  done
}

# genvw_detect_max_logical_cpus
# best-effort logical CPU count for wizard + wrapper caps.
# order: getconf -> /proc/cpuinfo -> static fallback.
genvw_detect_max_logical_cpus() {
  local n=""

  if have getconf; then
    n="$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)"
  fi
  case "$n" in
    '' | *[!0-9]* | 0) n="" ;;
  esac

  if [[ -z "$n" ]]; then
    n="$(grep -c '^processor' /proc/cpuinfo 2>/dev/null || true)"
    case "$n" in
      '' | *[!0-9]* | 0) n="" ;;
    esac
  fi

  [[ -n "$n" ]] || n=128
  printf '%s\n' "$n"
}

# genvw_ctd_preflight_scan_ok
# wrapper preflight scan guard: only scan canonical compatibilitytools.d paths.
genvw_ctd_preflight_scan_ok() {
  local ctd="${1:-}"
  [[ -n "$ctd" ]] || return 1
  [[ "$ctd" == */compatibilitytools.d ]] || return 1
  [[ -d "$ctd" ]] || return 1
  return 0
}

# genvw_check_clones_present
# true if CTD has at least one clone matching proton-cachyos-<major>-* -<suffix>.
genvw_check_clones_present() {
  local ctd="${1:-}" major="${2:-}" suffix="${3:-}"
  local prefix="" suffix_tag="" p="" base=""
  local plen=0 slen=0 blen=0 start=0 midlen=0
  local had_nullglob=0

  [[ -d "$ctd" ]] || return 1
  [[ "$major" =~ ^[0-9]+(\.[0-9]+)?$ ]] || return 1
  [[ "$suffix" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 1

  prefix="proton-cachyos-${major}-"
  suffix_tag="-${suffix}"
  plen=${#prefix}
  slen=${#suffix_tag}

  shopt -q nullglob && had_nullglob=1
  shopt -s nullglob

  for p in "$ctd"/*; do
    [[ -d "$p" ]] || continue
    base="${p##*/}"
    blen=${#base}
    ((blen > plen + slen)) || continue
    [[ "${base:0:plen}" == "$prefix" ]] || continue
    start=$((blen - slen))
    [[ "${base:start:slen}" == "$suffix_tag" ]] || continue
    midlen=$((blen - plen - slen))
    ((midlen > 0)) || continue
    ((had_nullglob == 1)) || shopt -u nullglob
    return 0
  done

  ((had_nullglob == 1)) || shopt -u nullglob
  return 1
}

normalize_bdf() {
  # map common dri_prime device selector forms into a pci bdf:
  #   0000:BB:DD.F
  #
  # accepted inputs:
  # - 0000:BB:DD.F (canonical)
  # - BB:DD.F (domain assumed 0000)
  # - pci-0000:BB:DD.F
  # - pci-0000_BB_DD_F
  # - 0000_BB_DD_F
  # - BB_DD_F (domain assumed 0000)
  #
  # also strips trailing '!' (vulkan selector style):
  # - pci-0000_BB_DD_F!
  # - 0000_BB_DD_F!!
  # returns:
  #   0 and prints mapped bdf on stdout, or 1 if not recognized.
  local v="${1:-}"

  # strip mesa prefix, if present
  v="${v#pci-}"

  # strip trailing '!' (vulkan selector style)
  while [[ "$v" == *"!" ]]; do
    v="${v%?}"
  done

  # 0000_BB_DD_F -> 0000:BB:DD.F
  if echo "$v" | grep -qE '^[0-9A-Fa-f]{4}_[0-9A-Fa-f]{2}_[0-9A-Fa-f]{2}_[0-7]$'; then
    v="$(echo "$v" | sed -E 's/^([0-9A-Fa-f]{4})_([0-9A-Fa-f]{2})_([0-9A-Fa-f]{2})_([0-7])$/\1:\2:\3.\4/')"
  fi

  # BB_DD_F -> 0000:BB:DD.F
  if echo "$v" | grep -qE '^[0-9A-Fa-f]{2}_[0-9A-Fa-f]{2}_[0-7]$'; then
    v="$(echo "$v" | sed -E 's/^([0-9A-Fa-f]{2})_([0-9A-Fa-f]{2})_([0-7])$/0000:\1:\2.\3/')"
  fi

  # BB:DD.F -> 0000:BB:DD.F
  if echo "$v" | grep -qE '^[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}\.[0-7]$'; then
    v="0000:$v"
  fi

  # must now be canonical
  echo "$v" | grep -qE '^[0-9A-Fa-f]{4}:[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}\.[0-7]$' || return 1
  printf '%s\n' "$v"
}

score_gpu_line() {
  # higher = newer/better match
  local s=0 l="$1"

  # explicit arch/codename when present
  echo "$l" | grep -qiE 'Navi[[:space:]]*4[0-9]' && { echo 400; return; }
  echo "$l" | grep -qiE 'Navi[[:space:]]*3[0-9]' && { echo 300; return; }
  echo "$l" | grep -qiE 'Navi[[:space:]]*2[0-9]' && { echo 200; return; }

  # some lspci strings include gfx ip blocks
  echo "$l" | grep -qiE 'gfx12' && { echo 400; return; }
  echo "$l" | grep -qiE 'gfx11' && { echo 300; return; }
  echo "$l" | grep -qiE 'gfx10' && { echo 200; return; }

  # rdna4 pro naming
  echo "$l" | grep -qiE 'Radeon[[:space:]]+AI[[:space:]]+PRO' && { echo 400; return; }

  # dgpu marketing families
  echo "$l" | grep -qiE 'RX[[:space:]]*9[0-9]{3}' && { echo 390; return; }
  echo "$l" | grep -qiE 'RX[[:space:]]*7[0-9]{3}' && { echo 290; return; }
  echo "$l" | grep -qiE 'RX[[:space:]]*6[0-9]{3}' && { echo 190; return; }

  # igpu buckets (rdna3.5 treated as 3)
  echo "$l" | grep -qiE 'Radeon[[:space:]]*(840M|860M|880M|890M|8040S|8050S|8060S)' && { echo 301; return; }
  echo "$l" | grep -qiE 'Radeon[[:space:]]*(740M|760M|780M)|Z2[[:space:]]*Extreme' && { echo 300; return; }
  echo "$l" | grep -qiE 'Radeon[[:space:]]*(660M|680M)' && { echo 200; return; }

  echo 0
}

classify_from_line() {
  local l="$1"

  echo "$l" | grep -qiE 'Navi[[:space:]]*4[0-9]|gfx12|Radeon[[:space:]]+AI[[:space:]]+PRO|RX[[:space:]]*9[0-9]{3}' && { echo 4; return; }
  echo "$l" | grep -qiE 'Navi[[:space:]]*3[0-9]|gfx11|RX[[:space:]]*7[0-9]{3}|Radeon[[:space:]]*(740M|760M|780M|840M|860M|880M|890M|8040S|8050S|8060S)|Z2[[:space:]]*Extreme' && { echo 3; return; }
  echo "$l" | grep -qiE 'Navi[[:space:]]*2[0-9]|gfx10|RX[[:space:]]*6[0-9]{3}|Radeon[[:space:]]*(660M|680M)' && { echo 2; return; }

  echo 0
}

# detect_rdna_gen
# rdna generation detection.
# returns: 2 (rdna2), 3 (rdna3/3.5), 4 (rdna4), 0 (unknown)

detect_rdna_gen() {
  # dev override: force the classification (0..4).
  #  4 -> pretend rdna4
  #  3 -> pretend rdna3/3.5
  #  2 -> pretend rdna2 (shows the rdna2 fsr4 menu)
  #  1 -> force unsupported (genvw_require_supported_gpu refuses)
  #  0 -> pretend unknown (wizard can show both rdna3 + rdna4 menus)
  if [ -n "${GENVW_FORCE_RDNA_GEN:-}" ]; then
    case "${GENVW_FORCE_RDNA_GEN}" in
      0|1|2|3|4)
        printf '%s\n' "${GENVW_FORCE_RDNA_GEN}"
        return 0
        ;;
    esac
  fi

  command -v lspci >/dev/null 2>&1 || {
    echo 0
    return
  }

  # dri_prime notes:
  # - dri_prime is a mesa offload hint. it is not a guaranteed selector here.
  # - numeric dri_prime values (like 1) are not stable across machines.
  # - if dri_prime looks like a pci selector, we map it and target that device.
  #
  # handy:
  #   lspci -nn | grep -Ei 'VGA|3D|Display'
  #   DRI_PRIME=0000:BB:DD.F genvw proton check

  local line="" gpu="" addr="" c best_line="" best_score=-1 score=0

  # dri_prime bdf: use it when it looks like a pci selector (not 0/1).
  if [ -n "${DRI_PRIME:-}" ] && [ "${DRI_PRIME:-}" != "0" ] && [ "${DRI_PRIME:-}" != "1" ]; then
    if addr="$(normalize_bdf "$DRI_PRIME" 2>/dev/null)"; then
      line="$(lspci -nn -s "$addr" 2>/dev/null || true)"
    fi
  fi

  # test override: force the full pci scan pick (skips drm-first + dri_prime=1 heuristic)
  # use: GENVW_GPU_PICK_PCI=1 genvw ...
  if [ -z "$line" ] && [ "${GENVW_GPU_PICK_PCI:-0}" = "1" ]; then
    best_line=""
    best_score=-1

    while IFS= read -r gpu; do
      score="$(score_gpu_line "$gpu")"
      if [ "$score" -gt "$best_score" ]; then
        best_score="$score"
        best_line="$gpu"
      fi
    done < <(lspci -nn 2>/dev/null | grep -Ei 'VGA|3D|Display' | grep -Ei 'AMD|ATI' || true)

    [ -n "$best_line" ] && line="$best_line"
    [ -n "$line" ] || { echo 0; return; }

    classify_from_line "$line"
    return
  fi

  # dri_prime=1: common hybrid convention, prefer card1 if it's amd.
  if [ -z "$line" ] && [ "${DRI_PRIME:-0}" = "1" ] \
    && [ -e /sys/class/drm/card1/device/vendor ] \
    && [ "$(cat /sys/class/drm/card1/device/vendor 2>/dev/null || true)" = "0x1002" ]; then
    addr="$(basename "$(readlink -f /sys/class/drm/card1/device 2>/dev/null)")"
    [ -n "$addr" ] && line="$(lspci -nn -s "$addr" 2>/dev/null || true)"
  fi

  # drm cards: score amd card0..cardN and pick the best match.
  if [ -z "$line" ] && [ -d /sys/class/drm ]; then
    for c in /sys/class/drm/card*; do
      # accept only real card nodes (skip card0-DP-1 style connectors)
      [[ "$(basename "$c")" =~ ^card[0-9]+$ ]] || continue
      [ "$(cat "$c/device/vendor" 2>/dev/null || true)" = "0x1002" ] || continue
      addr="$(basename "$(readlink -f "$c/device" 2>/dev/null)")"
      [ -n "$addr" ] || continue
      gpu="$(lspci -nn -s "$addr" 2>/dev/null || true)"
      [ -n "$gpu" ] || continue

      score="$(score_gpu_line "$gpu")"
      if [ "$score" -gt "$best_score" ]; then
        best_score="$score"
        best_line="$gpu"
      fi
    done
    [ -n "$best_line" ] && line="$best_line"
  fi

  # last fallback: score all amd vga/3d/display lines and pick the best.
  if [ -z "$line" ]; then
    while IFS= read -r gpu; do
      score="$(score_gpu_line "$gpu")"
      if [ "$score" -gt "$best_score" ]; then
        best_score="$score"
        best_line="$gpu"
      fi
    done < <(lspci -nn 2>/dev/null | grep -Ei 'VGA|3D|Display' | grep -Ei 'AMD|ATI')

    [ -n "$best_line" ] && line="$best_line"
  fi

  [ -n "$line" ] || { echo 0; return; }
  classify_from_line "$line"
}

# genvw_gpu_debug_info
# debug dump for gpu picking (useful when rdna detection looks wrong).

genvw_gpu_debug_info() {
  echo "GPU debug:"

  # lspci shows the marketing/codename strings we classify.
  if command -v lspci >/dev/null 2>&1; then
    echo "  lspci (VGA/3D/Display):"
    lspci -nn | grep -Ei 'VGA|3D|Display' | sed 's/^/    /' || true
  else
    echo "  lspci: (missing)  — install pciutils"
  fi

  # drm cards show what the kernel thinks exists; vendor 0x1002 = amd.
  echo "  /sys/class/drm vendors (card0..card9):"
  local c v any=0
  for c in /sys/class/drm/card*; do
    # skip connector nodes like card0-DP-1.
    [[ "$(basename "$c")" =~ ^card[0-9]+$ ]] || continue
    [ -e "$c/device/vendor" ] || continue
    v="$(cat "$c/device/vendor" 2>/dev/null || true)"
    echo "    $(basename "$c"): $v"
    any=1
  done

  [ "$any" -eq 0 ] && echo "    (none found)"
}

# genvw_require_supported_gpu
# stop early when the gpu doesn't match what gENVW supports.

genvw_require_supported_gpu() {
  # needs lspci for rdna verification. if it isn't there, we fail closed.
  #
  # GENVW_FORCE_RDNA_GEN quick map:
  #   4 -> pretend rdna4
  #   3 -> pretend rdna3/3.5
  #   2 -> pretend rdna2 (shows the rdna2 fsr4 menu)
  #   1 -> force unsupported (intentional refusal)
  #   0 -> pretend unknown (wizard can show both rdna3 + rdna4 menus)
  #
  # when GENVW_FORCE_RDNA_GEN is set, we skip the strict lspci check (dev/test).

  local forced="${GENVW_FORCE_RDNA_GEN:-}"
  if [[ -n "$forced" ]]; then
    case "$forced" in
      0|2|3|4)
        if ! have lspci; then
          msg ""
          warn "Missing dependency: lspci (pciutils) — but GENVW_FORCE_RDNA_GEN=$forced is set, skipping GPU verification."
          msg ""
        fi
        return 0
        ;;
      1)
        msg ""
        err "Unsupported GPU for gENVW (forced unsupported GPU mode)."
        msg "GENVW_FORCE_RDNA_GEN=1 is set → intentionally refusing to run."
        msg ""
        return 2
        ;;
    esac
  fi

  if ! have lspci; then
    msg
    err "Missing dependency: lspci (pciutils)."
    msg "gENVW requires lspci to verify an AMD RDNA2/3/4 GPU (RDNA2 support is limited)."
    msg "Install (Arch): sudo pacman -S pciutils"
    msg
    genvw_gpu_debug_info
    msg
    return 2
  fi

  local gen="${1:-}"
  [ -n "$gen" ] || gen="$(detect_rdna_gen)"
  if [ "$gen" = "2" ] || [ "$gen" = "3" ] || [ "$gen" = "4" ]; then
    return 0
  fi

  msg
  err "Unsupported GPU for gENVW."
  msg "gENVW is intended for AMD RDNA2/3/4 class GPUs (RDNA2 support is limited)."
  case "$gen" in
    0)
      local has_amd=0 c v
      for c in /sys/class/drm/card*; do
        # real cards only (skip connector nodes like card0-DP-1)
        [[ "$(basename "$c")" =~ ^card[0-9]+$ ]] || continue

        [ -e "$c/device/vendor" ] || continue
        v="$(cat "$c/device/vendor" 2>/dev/null || true)"
        if [ "$v" = "0x1002" ]; then
          has_amd=1
          break
        fi
      done

      if [ "$has_amd" -eq 1 ]; then
        echo "Detected: AMD GPU, but gENVW could not classify it as RDNA2/3/4 (RDNA_GEN=0)."
        echo "This usually means the GPU name/codename doesn't match the patterns we know yet."
        echo "If you believe you have RDNA2/3/4, run:"
        echo "  lspci -nn | grep -Ei 'VGA|3D|Display'"
        echo "and share the output so support can be added."
      else
        echo "Detected: non-AMD GPU or unreadable sysfs (RDNA_GEN=0)."
        echo "gENVW only supports AMD RDNA2/3/4 (RDNA2 support is limited)."
      fi
      ;;
    *) echo "Detected: RDNA_GEN=$gen (unsupported)." ;;
  esac
  echo
  genvw_gpu_debug_info
  echo
  echo "Tip: If you're on a hybrid system, try running with DRI_PRIME=1."
  return 2
}

# show_help
# print cli usage/help text.

show_help() {
  cat <<EOF
gENVW - Proton / FSR4 Wrapper

Usage:
  genvw
  genvw [KEY=VALUE ...] %command% [args...]
  genvw --profile NAME [KEY=VALUE ...] %command%
  genvw profile list|show|print|save|delete [...]
  genvw proton CMD [args...]

${I_GAME} Launch Options:
  MODE                                  COMMAND
  Auto RDNA3 / RDNA4                    FSR4=1 genvw %command%
  Local Pin                             FSR4=${GENVW_FSR4_WIZARD_LOCAL_DEFAULT} genvw %command%
  Full Example                          HDR=1 FSR4=${GENVW_FSR4_WIZARD_LOCAL_DEFAULT} LSC=1 NVMD=1 NTS=1 CPU=16 GP=1 genvw %command%
  Native Wayland HDR                    HDR=1 genvw %command%
  X11 HDR + Gamescope                   HDR=1 GS=1 MON=DP-1 GSFULL=1 genvw %command%
  Gamescope Upscaling Example           GS=1 MON=DP-1 GSFULL=1 GSFSR=fsr GSRES=1920x1080 genvw %command%
  FSR4 + Gamescope Monitor Pinning      FSR4=${GENVW_FSR4_WIZARD_LOCAL_DEFAULT} GS=1 MON=DP-1 GSFULL=1 genvw %command%
  DXVK Low-Latency                      GPLASYNC=lowlat genvw %command%
  DXVK Low-Latency + VRR                GPLASYNC=lowlat-vrr-165 genvw %command%
  DXVK LLASYNC                          GPLASYNC=llasync genvw %command%
  LSFG 3x + Performance                 LSFG=3 LSFGPERF=1 genvw %command%

Common Toggles:
  KEY        VALUES     PURPOSE
  HDR        0|1        Linux HDR path (Wayland / Gamescope)
  FSR4       0|1|ver    FSR4 off, auto, or pinned version (version-first)
  FSR4_RDNA3 0|1|ver    RDNA3-only FSR4 selection
  MLFG       0|1        Machine Learning Frame Generation (trusted local-only FSR4 only)
  FSR4SHOW   0|1        On-screen FSR4/MLFG indicator (PROTON_FSR4_INDICATOR)
  LSC        0|1        Local shader cache
  NVMD       0|1        Disable window decorations
  NTS        0|1        NTSYNC (opt-in pre-20260312; default-on 20260312+)
  CPU        0|N        Visible logical CPU count
  GP         0|1        Run through game-performance

Gamescope:
  KEY        VALUES          PURPOSE
  GS         0|1             Wrap in Gamescope
  GSFULL     0|1             Start Gamescope fullscreen (-f)
  GSGRAB     0|1             Force Gamescope cursor grab (--force-grab-cursor)
  GSFSR      0|fsr|nis|pixel Gamescope upscaler filter (requires GS=1)
  GSSHARP    0-20            Gamescope sharpness for GSFSR=fsr|nis
  GSRES      WxH             Gamescope internal render resolution (requires GS=1; output follows MON/native)
  MON        DP-1|1|2        Target monitor (connector name or number; GS uses it for sizing/spec preference)
                             Nested desktop placement may still follow compositor behavior

DXVK Policy (version-aware Proton-CachyOS mapping):
  KEY        VALUES                                             PURPOSE
  GPLASYNC   0|1|on|llasync|lowlat|gplasync|...                 Version-aware DXVK policy knob; 20260227=combined, 20260228-20260311=split envs, 20260312+=lowlatency-only
  LSFG       0|2|3|4                                            Lossless Scaling frame gen multiplier (requires lsfg-vk)
  LSFGPERF   0|1                                                LSFG performance mode (lighter model)
  LSFGFLOW   0.25-1.0                                           LSFG flow scale (motion estimation resolution)
  LSFGPRESENT fifo|mailbox|immediate                            LSFG present mode (set explicitly when needed)
  LSFGHDR    0|1                                                LSFG HDR handling override for legacy lsfg-vk

Less Common:
  KEY        VALUES     PURPOSE
  FFSR       0|1-5      Wine fullscreen FSR (X11/Xwayland, SDR)
  D7VK       0|1        d7vk DDraw/D3D1-7 (20260102+; env varies by build date)
  NODXR      0|1        Disable DXR via VKD3D_CONFIG=nodxr
  FORCEDXR   0|1|12     Force DXR via VKD3D_CONFIG=dxr[,dxr12]
  ASYNC      0|1        DXVK async fallback for unresolved/unsupported DXVK policy targets
  DEBUG      0|1        Extra logging

Proton Commands:
  COMMAND                                       PURPOSE
  genvw proton status                           Show Steam, DLL, and tool state
  genvw proton diagnose [--appid APPID]         Show readiness and next steps
  genvw proton check                            Run helper sanity checks
  genvw proton prep [--yes] [--dry-run]         Prepare DLL + Proton tools
  genvw proton rebuild [--dry-run] [...]        Build or refresh gENVW tools
  genvw proton clean [--dry-run] [...]          Remove gENVW tools
  genvw proton dll verify                       Verify local DLL trust
  genvw proton dll backup [--ver X.Y.Z]         Save a sealed local backup
  genvw proton dll restore [...]                Restore a sealed local backup
  genvw proton dll --appid APPID [VER]          Show prefix DLL status or compare vs local cache

More Help:
  genvw proton --help
  genvw proton dll --help

Profiles:
  genvw --profile NAME %command%                        Use a saved profile
  genvw profile list                                    List saved profiles
  genvw profile show NAME                               Show profile details
  genvw profile save NAME [--yes] HDR=1 GS=1 FSR4=4.1.0 ...  Create or overwrite a profile
  genvw profile delete NAME [--yes]                         Delete a profile

  Examples:
    genvw --profile cyberpunk %command%
    FSR4=4.1.0 genvw --profile cyberpunk %command%   (override one knob)

  Environment variables take priority over profile values. For example,
  if your shell exports FSR4=1 globally, a profile with FSR4=4.1.0 will
  not override it. To force a specific value, set it inline:
    FSR4=4.1.0 genvw --profile cyberpunk %command%

Other Env:
  GENVW_NO_BANNER=1   Disable banner in interactive mode
  GENVW_NO_COLOR=1    Disable ANSI colors
  GENVW_DEBUG=1       Print effective env + final command before exec

Proton Wayland / SDL (set directly; genvw passes through):
  PROTON_ENABLE_WAYLAND=1  Wayland driver (canonical; newer Proton-CachyOS also accepts PROTON_USE_WAYLAND)
  PROTON_PREFER_SDL=1      Prefer SDL backend (canonical; newer Proton-CachyOS also accepts PROTON_USE_SDL)
EOF
}

# show_version
# print gENVW version info.

show_version() {
  printf 'gENVW (genvw) version %s\n' "$GENVW_VERSION"
}

# help flag: print usage and exit
if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  show_help
  exit 0
fi

# version flag: print version and exit
if [ "${1:-}" = "-V" ] || [ "${1:-}" = "--version" ] || [ "${1:-}" = "-v" ]; then
  show_version
  exit 0
fi

#####################
# proton_helper_env_add
# append KEY=VALUE to a helper env array, preserving intentionally empty values.

proton_helper_env_add() {
  local -n _helper_env_ref="$1"
  local _name="${2:?}"
  if [[ "${!_name+x}" == "x" ]]; then
    _helper_env_ref+=("${_name}=${!_name}")
  fi
}

proton_helper_env_add_literal() {
  local -n _helper_env_ref="$1"
  local _name="${2:?}"
  local _value="${3-}"
  _helper_env_ref+=("${_name}=${_value}")
}

genvw_add_proton_helper_execution_env() {
  local _env_name="$1"

  # Minimal execution baseline.
  # Keep only what the helper needs to start and to resolve HOME-based defaults.
  proton_helper_env_add_literal "$_env_name" PATH "${PATH:-/usr/bin:/bin}"
  proton_helper_env_add_literal "$_env_name" HOME "${HOME:-/tmp}"
}

genvw_add_proton_helper_stable_contract_env() {
  local _env_name="$1"

  # Stable wrapper->helper contract.
  # These are the intentional wrapper-facing knobs and resolved policy outputs
  # that wrapper-side `genvw proton ...` flows may depend on across the boundary.
  # Add new names here only when they are meant to become stable wrapper->helper
  # surface, not just because a test/debug flow wants passthrough behavior.
  proton_helper_env_add "$_env_name" STEAM_COMPAT_TOOL_PATHS
  proton_helper_env_add "$_env_name" AMD_DLL_ALLOWLIST
  proton_helper_env_add_literal "$_env_name" AMD_DRIVER_URL "${AMD_DRIVER_URL:-}"
  proton_helper_env_add "$_env_name" GENVW_FSR4_LOCAL_DIR
  proton_helper_env_add_literal "$_env_name" GENVW_FSR4_RESOLVED_RELEASED_VERSIONS_CSV "${GENVW_FSR4_RESOLVED_RELEASED_VERSIONS_CSV:-}"
  proton_helper_env_add_literal "$_env_name" GENVW_FSR4_RESOLVED_LOCAL_ONLY_VERSIONS_CSV "${GENVW_FSR4_RESOLVED_LOCAL_ONLY_VERSIONS_CSV:-}"
  proton_helper_env_add_literal "$_env_name" GENVW_FSR4_RESOLVED_SOURCE "${GENVW_FSR4_RESOLVED_SOURCE:-}"
}

genvw_add_proton_helper_internal_check_kv_env() {
  local _env_name="$1"

  # Trust-sensitive internal `check --kv` calls only.
  # Keep the helper env limited to source discovery and resolved policy parity.
  proton_helper_env_add "$_env_name" STEAM_COMPAT_TOOL_PATHS
  proton_helper_env_add_literal "$_env_name" GENVW_FSR4_RESOLVED_RELEASED_VERSIONS_CSV "${GENVW_FSR4_RESOLVED_RELEASED_VERSIONS_CSV:-}"
  proton_helper_env_add_literal "$_env_name" GENVW_FSR4_RESOLVED_LOCAL_ONLY_VERSIONS_CSV "${GENVW_FSR4_RESOLVED_LOCAL_ONLY_VERSIONS_CSV:-}"
  proton_helper_env_add_literal "$_env_name" GENVW_FSR4_RESOLVED_SOURCE "${GENVW_FSR4_RESOLVED_SOURCE:-}"
}

genvw_add_proton_helper_devtest_env() {
  local _env_name="$1"

  # Bounded dev/test passthrough exceptions.
  # These are not part of the stable wrapper->helper contract; keep them only
  # for the narrow wrapper-side debug/test flows that currently exercise them.
  # If future work needs one of these for real wrapper behavior, promote it
  # deliberately into genvw_add_proton_helper_stable_contract_env instead.
  proton_helper_env_add "$_env_name" GENVW_EXPECT_HELPER_ARGS
  proton_helper_env_add "$_env_name" GENVW_MENU_CMDLOG
}

genvw_build_proton_helper_env() {
  local _env_name="$1"
  local -n _helper_env_ref="$_env_name"
  _helper_env_ref=()

  genvw_add_proton_helper_execution_env "$_env_name"
  genvw_add_proton_helper_stable_contract_env "$_env_name"
  genvw_add_proton_helper_devtest_env "$_env_name"
}

genvw_build_proton_helper_internal_check_kv_env() {
  local _env_name="$1"
  local -n _helper_env_ref="$_env_name"
  _helper_env_ref=()

  genvw_add_proton_helper_execution_env "$_env_name"
  genvw_add_proton_helper_internal_check_kv_env "$_env_name"
}

proton_helper_invoke_with_env_mode() {
  local mode="$1"
  local env_mode="$2"
  local helper="$3"
  local -a helper_env=()
  shift 3

  case "$env_mode" in
    default) genvw_build_proton_helper_env helper_env ;;
    internal_check_kv) genvw_build_proton_helper_internal_check_kv_env helper_env ;;
    *) err "gENVW: internal helper env mode error: $env_mode"; return 2 ;;
  esac

  if [ "$mode" = "exec" ]; then
    if [ -x "$helper" ]; then
      exec env -i "${helper_env[@]}" "$helper" "$@"
    else
      exec env -i "${helper_env[@]}" bash "$helper" "$@"
    fi
  fi

  if [ -x "$helper" ]; then
    env -i "${helper_env[@]}" "$helper" "$@"
  else
    env -i "${helper_env[@]}" bash "$helper" "$@"
  fi
}

proton_helper_invoke() {
  local mode="$1"
  local helper="$2"
  shift 2

  proton_helper_invoke_with_env_mode "$mode" default "$helper" "$@"
}

# proton_helper_run
# run genvw_proton.sh in a subprocess and return its status (used for 'genvw proton ...').

proton_helper_run() {
  local helper="$1"
  shift

  proton_helper_invoke run "$helper" "$@"
}

proton_helper_run_internal_check_kv() {
  local helper="$1"
  shift

  proton_helper_invoke_with_env_mode run internal_check_kv "$helper" "$@"
}

# proton_helper_exec
# exec into genvw_proton.sh (replaces current process) for subcommands that should not return.

proton_helper_exec() {
  local helper="$1"
  shift

  proton_helper_invoke exec "$helper" "$@"
}

# proton_helper_path
# resolve helper path for wizard checks and guarded flows.

proton_helper_path() {
  # prints trusted helper path if found
  # arg1:
  #   0 = strict override handling (default)
  #   1 = ignore invalid unsafe override and continue
  local ignore_bad_override="${1:-0}"
  local dir="" cand="" canonical="" override="" override_abs=""

  dir="$(genvw_script_dir 2>/dev/null || true)"
  cand="${dir}/genvw_proton.sh"
  if [ -n "$dir" ] && [ -f "$cand" ]; then
    canonical="$(genvw_abspath "$cand" 2>/dev/null || printf '%s' "$cand")"
    if [ -f "$canonical" ]; then
      override="${GENVW_PROTON_HELPER:-}"
      if [ -n "$override" ] && [ "${GENVW_ALLOW_UNSAFE_PROTON_HELPER:-0}" != "1" ]; then
        override_abs="$(genvw_abspath "$override" 2>/dev/null || true)"
        if [ -z "$override_abs" ] || [ "$override_abs" != "$canonical" ]; then
          if [ "${GENVW_PROTON_HELPER_WARNED:-0}" != "1" ]; then
            warn "gENVW: ignoring GENVW_PROTON_HELPER outside unsafe/dev mode; using trusted sibling helper." >&2
            GENVW_PROTON_HELPER_WARNED=1
          fi
        fi
      elif [ -n "$override" ] && [ "${GENVW_ALLOW_UNSAFE_PROTON_HELPER:-0}" = "1" ]; then
        override_abs="$(genvw_abspath "$override" 2>/dev/null || true)"
        if [ -n "$override_abs" ] && [ -f "$override_abs" ]; then
          printf '%s' "$override_abs"
          return 0
        fi
        if [ "$ignore_bad_override" = "1" ]; then
          :
        else
          printf '%s' "$override"
          return 0
        fi
      fi
      printf '%s' "$canonical"
      return 0
    fi
  fi
  return 1
}

# run_proton
# call helper in subprocess mode (not exec), used by wizard/preflight flows.

run_proton() {
  local helper
  helper="$(proton_helper_path 2>/dev/null || true)"
  if [ -z "$helper" ] || [ ! -f "$helper" ]; then
    echo "${I_WARN} Proton helper not found: ${helper:-(empty)}" >&2
    return 127
  fi
  proton_helper_run "$helper" "$@"
}

run_proton_internal_check_kv() {
  local helper
  helper="$(proton_helper_path 2>/dev/null || true)"
  if [ -z "$helper" ] || [ ! -f "$helper" ]; then
    echo "${I_WARN} Proton helper not found: ${helper:-(empty)}" >&2
    return 127
  fi
  proton_helper_run_internal_check_kv "$helper" check --kv "$@"
}

run_proton_internal_check_human_summary_kv() {
  local helper
  helper="$(proton_helper_path 2>/dev/null || true)"
  if [ -z "$helper" ] || [ ! -f "$helper" ]; then
    echo "${I_WARN} Proton helper not found: ${helper:-(empty)}" >&2
    return 127
  fi
  proton_helper_run "$helper" check --human-summary-kv "$@"
}

run_proton_internal_sources_machine() {
  local helper
  helper="$(proton_helper_path 2>/dev/null || true)"
  if [ -z "$helper" ] || [ ! -f "$helper" ]; then
    echo "${I_WARN} Proton helper not found: ${helper:-(empty)}" >&2
    return 127
  fi
  proton_helper_run "$helper" sources --machine "$@"
}

run_proton_internal_dw_sources_machine() {
  local helper
  helper="$(proton_helper_path 2>/dev/null || true)"
  [ -n "$helper" ] && [ -f "$helper" ] || return 0
  proton_helper_run "$helper" dw-sources --machine "$@" 2>/dev/null || true
}

genvw_rebuild_print_no_scope_help() {
  msg "Rebuild requires explicit scope. No provider or target selected." >&2
  msg "" >&2
  msg "Examples:" >&2
  msg "  Use: genvw proton rebuild -p cachyos -t 20260520 --dry-run" >&2
  msg "  Use: genvw proton rebuild -p cachyos --all-targets --dry-run" >&2
  msg "  Use: genvw proton rebuild -p dw -t 11.0-2 --dry-run" >&2
  msg "  Use: genvw proton rebuild -p dw --all-targets --dry-run" >&2
  msg "" >&2
  msg "Scope options:" >&2
  msg "  -p cachyos -t DATE        Rebuild CachyOS target for DATE" >&2
  msg "  -p cachyos --all-targets  Rebuild all supported CachyOS targets" >&2
  msg "  -p dw -t VERSION          Rebuild DW-Proton VERSION (e.g. 11.0-2)" >&2
  msg "  -p dw --all-targets       Rebuild all supported DW-Proton targets" >&2
  msg "  --missing-only            Skip already-built targets (combine with scope)" >&2
  msg "  --dry-run                 Preview without making changes" >&2
}

genvw_rebuild_picker_arch_for_display() {
  case "${1:-}" in
    system-x86_64) printf '%s\n' "x86_64" ;;
    protonplus-unspecified | "") printf '%s\n' "unknown" ;;
    protonplus-x86_64 | protonplus-x86_64_v[1-4]) printf '%s\n' "${1#protonplus-}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

genvw_rebuild_picker_source_label() {
  local family="${1:-}" provenance="${2:-}" source_path="${3:-}" ctd="${4:-}"
  case "$family" in
    protonup-qt) printf '%s\n' "ProtonUp-Qt" ;;
    protonplus) printf '%s\n' "ProtonPlus" ;;
    system-package) printf '%s\n' "system" ;;
    *)
      if [[ -n "$ctd" && -n "$source_path" && "$source_path" == "$ctd/"* ]]; then
        printf '%s\n' "local CTD"
      elif [[ "$provenance" == "ctd" ]]; then
        printf '%s\n' "local CTD"
      elif [[ "$provenance" == "system" ]]; then
        printf '%s\n' "system"
      else
        printf '%s\n' "${family:-unknown}"
      fi
      ;;
  esac
}

genvw_rebuild_picker_cachyos_features_for_date() {
  local date="${1:-}"
  local -a out=("FSR4")
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
  local feature="" joined=""
  for feature in "${out[@]}"; do
    [[ -z "$joined" ]] && joined="$feature" || joined="${joined}, ${feature}"
  done
  printf '%s\n' "$joined"
}

compact_feature_labels_for_human() {
  local csv="${1:-}" token="" trimmed="" out=""
  local -a labels=()

  IFS=',' read -r -a labels <<<"$csv"
  for token in "${labels[@]}"; do
    trimmed="$(trim "$token")"
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

genvw_dw_align_split_env_feature_labels() {
  local version="${1:-}" base_label="${2:-}" runtime="${3:-}" status="${4:-}" csv="${5:-}"
  local build_date="" token="" trimmed="" out=""
  local major="" minor="" patch=""
  local has_lowlatency=0 has_gplasync=0 has_gplall_legacy=0 inserted=0
  local -a labels=()

  [[ -n "$csv" ]] || {
    printf '%s\n' "$csv"
    return 0
  }

  if [[ "$status" != "installed" && "$status" != "supported" ]]; then
    printf '%s\n' "$csv"
    return 0
  fi

  build_date="$base_label"
  [[ "$build_date" =~ ^[0-9]+\.[0-9]+-([0-9]{8})$ ]] && build_date="${BASH_REMATCH[1]}"
  if [[ ! "$build_date" =~ ^[0-9]{8}$ || -z "$runtime" || "$runtime" == "unresolved" ]]; then
    printf '%s\n' "$csv"
    return 0
  fi
  if [[ ! "$version" =~ ^([0-9]+)[.]([0-9]+)-([0-9]+)$ ]]; then
    printf '%s\n' "$csv"
    return 0
  fi
  major="${BASH_REMATCH[1]}"
  minor="${BASH_REMATCH[2]}"
  patch="${BASH_REMATCH[3]}"
  if ! { ((10#$major == 11)) && ((10#$minor == 0)) && ((10#$patch >= 1)); } &&
     ! { ((10#$major == 10)) && ((10#$minor == 0)) && ((10#$patch >= 20)); }; then
    printf '%s\n' "$csv"
    return 0
  fi

  IFS=',' read -r -a labels <<<"$csv"
  for token in "${labels[@]}"; do
    trimmed="$(trim "$token")"
    case "$trimmed" in
      lowlatency-DXVK) has_lowlatency=1 ;;
      GPLAsync) has_gplasync=1 ;;
      GPLAll-legacy) has_gplall_legacy=1 ;;
    esac
  done

  if ((has_lowlatency == 0 || has_gplasync == 1 || has_gplall_legacy == 1)); then
    printf '%s\n' "$csv"
    return 0
  fi

  for token in "${labels[@]}"; do
    trimmed="$(trim "$token")"
    [[ -n "$trimmed" ]] || continue
    if [[ "$trimmed" == "lowlatency-DXVK" && "$inserted" == "0" ]]; then
      [[ -z "$out" ]] && out="GPLAsync" || out="${out}, GPLAsync"
      inserted=1
    fi
    [[ -z "$out" ]] && out="$trimmed" || out="${out}, ${trimmed}"
  done

  printf '%s\n' "$out"
}

genvw_rebuild_picker_cachyos_clone_base() {
  local base="${1:-}" arch="${2:-}" prefix="" arch_part=""
  if [[ "$base" =~ ^(proton-cachyos-[0-9]+([.][0-9]+)?-[0-9]{8}-(native|slr))-protonplus-(x86_64(_v[1-4])?)$ ]]; then
    printf '%s\n' "$base"
    return 0
  fi
  if [[ "$base" =~ ^(proton-cachyos-[0-9]+([.][0-9]+)?-[0-9]{8}-(native|slr))-(x86_64(_v[1-4])?)$ ]]; then
    prefix="${BASH_REMATCH[1]}"
    arch_part="${BASH_REMATCH[4]}"
    printf '%s-protonplus-%s\n' "$prefix" "$arch_part"
    return 0
  fi
  if [[ "$arch" =~ ^protonplus-(x86_64(_v[1-4])?)$ && "$base" =~ ^(cachyos-[0-9]+([.][0-9]+)?-[0-9]{8}-(native|slr))$ ]]; then
    printf 'proton-%s-%s\n' "$base" "${arch#protonplus-}"
    return 0
  fi
  printf '%s\n' "$base"
}

genvw_rebuild_picker_major_rank() {
  local major="${1:-0}" major_int=""
  major_int="${major%%.*}"
  [[ "$major_int" =~ ^[0-9]+$ ]] || major_int=0
  printf '%s\n' "$major_int"
}

genvw_rebuild_picker_runtime_rank() {
  case "${1:-}" in
    slr) printf '%s\n' "2" ;;
    native) printf '%s\n' "1" ;;
    *) printf '%s\n' "0" ;;
  esac
}

genvw_rebuild_picker_source_rank() {
  local family="${1:-}" provenance="${2:-}"
  case "$family:$provenance" in
    system-package:* | *:system) printf '%s\n' "3" ;;
    protonplus:*) printf '%s\n' "2" ;;
    protonup-qt:*) printf '%s\n' "1" ;;
    *) printf '%s\n' "0" ;;
  esac
}

genvw_rebuild_picker_dw_major_rank() {
  local version="${1:-}" major_part=""
  major_part="${version%%.*}"
  [[ "$major_part" =~ ^[0-9]+$ ]] || major_part=0
  printf '%s\n' "$major_part"
}

genvw_rebuild_picker_dw_patch_rank() {
  local version="${1:-}" patch_part=""
  patch_part="${version##*-}"
  [[ "$patch_part" =~ ^[0-9]+$ ]] || patch_part=0
  printf '%s\n' "$patch_part"
}

genvw_rebuild_picker_cachyos_exact_id() {
  printf '%s\n' "${1:-}"
}

genvw_rebuild_picker_sort_cachyos_rows() {
  local -n rows_ref="$1"
  local line=""
  ((${#rows_ref[@]} > 0)) || return 0
  mapfile -t rows_ref < <(
    printf '%s\n' "${rows_ref[@]}" | sort -t '|' -k1,1r -k2,2nr -k3,3nr -k4,4nr -k5,5
  )
  for line in "${rows_ref[@]}"; do
    [[ -n "$line" ]] || return 1
  done
}

genvw_rebuild_picker_sort_dw_rows() {
  local -n rows_ref="$1"
  local line=""
  ((${#rows_ref[@]} > 0)) || return 0
  mapfile -t rows_ref < <(
    printf '%s\n' "${rows_ref[@]}" | sort -t '|' -k1,1nr -k2,2nr -k3,3nr -k4,4r -k5,5r
  )
  for line in "${rows_ref[@]}"; do
    [[ -n "$line" ]] || return 1
  done
}

genvw_rebuild_picker_collect_provider_summary() {
  local helper="${1:-}" kv="" schema=""
  local -n cachyos_usable_ref="$2"
  local -n cachyos_known_ref="$3"
  local -n cachyos_newest_ref="$4"
  local -n dw_usable_ref="$5"
  local -n dw_known_ref="$6"
  local -n dw_newest_ref="$7"

  cachyos_usable_ref=0
  cachyos_known_ref=0
  cachyos_newest_ref=""
  dw_usable_ref=0
  dw_known_ref=0
  dw_newest_ref=""

  kv="$(proton_helper_run "$helper" check --human-summary-kv 2>/dev/null || true)"
  schema="$(genvw_kv_get_optional_unique "$kv" "HUMAN_SUMMARY_SCHEMA" 2>/dev/null || true)"
  [[ "$schema" == "1" ]] || return 0

  cachyos_usable_ref="$(genvw_kv_get_optional_unique "$kv" "CACHYOS_USABLE" 2>/dev/null || printf '0')"
  cachyos_known_ref="$(genvw_kv_get_optional_unique "$kv" "CACHYOS_KNOWN" 2>/dev/null || printf '0')"
  cachyos_newest_ref="$(genvw_kv_get_optional_unique "$kv" "CACHYOS_NEWEST" 2>/dev/null || true)"
  dw_usable_ref="$(genvw_kv_get_optional_unique "$kv" "DWPROTON_USABLE" 2>/dev/null || printf '0')"
  dw_known_ref="$(genvw_kv_get_optional_unique "$kv" "DWPROTON_KNOWN" 2>/dev/null || printf '0')"
  dw_newest_ref="$(genvw_kv_get_optional_unique "$kv" "DWPROTON_NEWEST" 2>/dev/null || true)"
}

genvw_rebuild_picker_collect_cachyos_rows() {
  local helper="${1:-}" kv="" schema="" count="" ctd="" idx=0
  local kind="" base="" major="" date="" runtime="" arch="" family="" provenance="" policy_label=""
  local clone_base="" status="" version="" source_label="" features="" exact_id=""
  local -n rows_ref="$2"

  rows_ref=()
  kv="$(proton_helper_run "$helper" sources --machine 2>/dev/null || true)"
  schema="$(genvw_kv_get_optional_unique "$kv" "SOURCES_SCHEMA" 2>/dev/null || true)"
  [[ "$schema" == "1" ]] || return 0
  count="$(genvw_kv_get_optional_unique "$kv" "SOURCE_COUNT" 2>/dev/null || true)"
  [[ "$count" =~ ^[0-9]+$ ]] || return 0
  ctd="$(genvw_kv_get_optional_unique "$kv" "CTD" 2>/dev/null || true)"

  for ((idx = 0; idx < count; idx++)); do
    kind="$(genvw_kv_get_optional_unique "$kv" "SOURCE_${idx}_KIND" 2>/dev/null || true)"
    [[ "$kind" == "source" ]] || continue
    base="$(genvw_kv_get_optional_unique "$kv" "SOURCE_${idx}_BASE" 2>/dev/null || true)"
    major="$(genvw_kv_get_optional_unique "$kv" "SOURCE_${idx}_MAJOR" 2>/dev/null || true)"
    date="$(genvw_kv_get_optional_unique "$kv" "SOURCE_${idx}_BUILD_DATE" 2>/dev/null || true)"
    runtime="$(genvw_kv_get_optional_unique "$kv" "SOURCE_${idx}_RUNTIME" 2>/dev/null || true)"
    arch="$(genvw_kv_get_optional_unique "$kv" "SOURCE_${idx}_ARCH" 2>/dev/null || true)"
    family="$(genvw_kv_get_optional_unique "$kv" "SOURCE_${idx}_FAMILY" 2>/dev/null || true)"
    provenance="$(genvw_kv_get_optional_unique "$kv" "SOURCE_${idx}_PROVENANCE" 2>/dev/null || true)"
    policy_label="$(genvw_kv_get_optional_unique "$kv" "SOURCE_${idx}_POLICY_LABEL" 2>/dev/null || true)"
    [[ -n "$base" && -n "$major" && -n "$date" && -n "$runtime" && -n "$arch" ]] || continue
    [[ "$policy_label" == supported* ]] || continue
    if [[ "$family" == "protonplus" ]]; then
      clone_base="$(genvw_rebuild_picker_cachyos_clone_base "$base" "$arch")"
    else
      clone_base="$base"
    fi
    status="supported"
    if [[ -n "$ctd" && -d "$ctd/${clone_base}-gENVW" ]]; then
      status="installed"
    fi
    version="${major}-${date}"
    source_label="$(genvw_rebuild_picker_source_label "$family" "$provenance" "" "$ctd")"
    features="$(genvw_rebuild_picker_cachyos_features_for_date "$date")"
    exact_id="$(genvw_rebuild_picker_cachyos_exact_id "$base" "$family" "$arch")"
    rows_ref+=("${date}|$(genvw_rebuild_picker_major_rank "$major")|$(genvw_rebuild_picker_runtime_rank "$runtime")|$(genvw_rebuild_picker_source_rank "$family" "$provenance")|${exact_id}|${version}|${runtime}|$(genvw_rebuild_picker_arch_for_display "$arch")|${source_label}|${status}|${features}")
  done
  genvw_rebuild_picker_sort_cachyos_rows "$2"
}

genvw_rebuild_picker_collect_dw_rows() {
  local helper="${1:-}" kv="" schema="" count="" ctd="" idx=0
  local version="" base_label="" runtime="" arch="" source_path="" features="" status="" source_label=""
  local clone_basename="" base_date=""
  local -n rows_ref="$2"
  local -n note_ref="$3"

  rows_ref=()
  note_ref=""
  kv="$(proton_helper_run "$helper" dw-sources --machine 2>/dev/null || true)"
  schema="$(genvw_kv_get_optional_unique "$kv" "DW_SOURCES_SCHEMA" 2>/dev/null || true)"
  [[ "$schema" == "1" ]] || return 0
  count="$(genvw_kv_get_optional_unique "$kv" "DW_SOURCE_COUNT" 2>/dev/null || true)"
  [[ "$count" =~ ^[0-9]+$ ]] || return 0
  ctd="$(genvw_kv_get_optional_unique "$kv" "DW_CTD" 2>/dev/null || true)"

  for ((idx = 0; idx < count; idx++)); do
    version="$(genvw_kv_get_optional_unique "$kv" "DW_SOURCE_${idx}_VERSION" 2>/dev/null || true)"
    base_label="$(genvw_kv_get_optional_unique "$kv" "DW_SOURCE_${idx}_BASE_LABEL" 2>/dev/null || true)"
    runtime="$(genvw_kv_get_optional_unique "$kv" "DW_SOURCE_${idx}_RUNTIME" 2>/dev/null || true)"
    arch="$(genvw_kv_get_optional_unique "$kv" "DW_SOURCE_${idx}_ARCH" 2>/dev/null || true)"
    source_path="$(genvw_kv_get_optional_unique "$kv" "DW_SOURCE_${idx}_SOURCE" 2>/dev/null || true)"
    features="$(genvw_kv_get_optional_unique "$kv" "DW_SOURCE_${idx}_FEATURES" 2>/dev/null || true)"
    [[ -n "$version" && -n "$base_label" && -n "$runtime" && -n "$arch" ]] || continue
    if [[ "$base_label" == "unresolved" || "$runtime" == "unresolved" ]]; then
      if [[ "$version" == "10.0-26" ]]; then
        note_ref="$version"
      fi
      continue
    fi
    status="supported"
    clone_basename="dwproton-${version}-${arch}-gENVW"
    if [[ -n "$ctd" && -d "$ctd/$clone_basename" ]]; then
      status="installed"
    fi
    source_label="$(genvw_rebuild_picker_source_label "" "" "$source_path" "$ctd")"
    base_date="$base_label"
    [[ "$base_date" =~ ^[0-9]+\.[0-9]+-([0-9]{8})$ ]] && base_date="${BASH_REMATCH[1]}"
    [[ "$base_date" =~ ^[0-9]{8}$ ]] || base_date="00000000"
    rows_ref+=("$(genvw_rebuild_picker_dw_major_rank "$version")|$(genvw_rebuild_picker_dw_patch_rank "$version")|${base_date}|${version}|dwproton-${version}-${arch}|${version}|${base_label}|${runtime}|$(genvw_rebuild_picker_arch_for_display "$arch")|${source_label}|${status}|${features}")
  done
  genvw_rebuild_picker_sort_dw_rows "$2"
}

genvw_rebuild_picker_print_legend() {
  echo "GENVW:"
  echo "  installed  a patched gENVW compatibility tool already exists for this row."
  echo "  supported  this row is rebuildable, but no patched gENVW compatibility tool exists yet."
  echo "  available  this row is known, but not rebuildable/selectable here."
}

genvw_rebuild_picker_print_provider_menu() {
  local cachyos_usable="${1:-0}" cachyos_known="${2:-0}" cachyos_newest="${3:-}"
  local dw_usable="${4:-0}" dw_known="${5:-0}" dw_newest="${6:-}"
  local mode="${7:-standalone}"
  echo "Rebuild gENVW Proton tools"
  echo
  echo "Providers:"
  printf '  %-2s %-15s %-14s %s\n' "#" "PROVIDER" "USABLE / TOTAL" "NEWEST"
  printf '  %-2s %-15s %-14s %s\n' "1" "CachyOS Proton" "${cachyos_usable:-0} / ${cachyos_known:-0}" "${cachyos_newest:-}"
  printf '  %-2s %-15s %-14s %s\n' "2" "DW-Proton" "${dw_usable:-0} / ${dw_known:-0}" "${dw_newest:-}"
  if [[ "$mode" == "wizard" ]]; then
    echo "  0  Back"
  else
    echo "  0  Exit"
  fi
  echo
  printf '%s' "Choose provider [0-2]: "
}

genvw_rebuild_picker_print_cachyos_targets() {
  local row="" version="" runtime="" arch="" source_label="" status="" features=""
  local -n rows_ref="$1"
  echo "CachyOS Proton rebuild targets:"
  echo
  genvw_rebuild_picker_print_legend
  echo
  printf '  %-2s %-13s %-7s %-11s %-11s %-10s %s\n' "#" "VERSION" "RUNTIME" "ARCH" "SOURCE" "GENVW" "FEATURES"
  local idx=1
  for row in "${rows_ref[@]}"; do
    IFS='|' read -r _ _ _ _ _ version runtime arch source_label status features <<<"$row"
    features="$(compact_feature_labels_for_human "$features")"
    printf '  %-2s %-13s %-7s %-11s %-11s %-10s %s\n' "$idx" "$version" "$runtime" "$arch" "$source_label" "$status" "$features"
    idx=$((idx + 1))
  done
}

genvw_rebuild_picker_print_dw_targets() {
  local row="" version="" base_label="" runtime="" arch="" source_label="" status="" features=""
  local -n rows_ref="$1"
  local note="${2:-}"
  echo "DW-Proton rebuild targets:"
  echo
  genvw_rebuild_picker_print_legend
  echo
  printf '  %-2s %-8s %-13s %-11s %-7s %-9s %-10s %s\n' "#" "VERSION" "BASE" "RUNTIME" "ARCH" "SOURCE" "GENVW" "FEATURES"
  local idx=1
  for row in "${rows_ref[@]}"; do
    IFS='|' read -r _ _ _ _ _ version base_label runtime arch source_label status features <<<"$row"
    features="$(genvw_dw_align_split_env_feature_labels "$version" "$base_label" "$runtime" "$status" "$features")"
    features="$(compact_feature_labels_for_human "$features")"
    printf '  %-2s %-8s %-13s %-11s %-7s %-9s %-10s %s\n' "$idx" "$version" "$base_label" "$runtime" "$arch" "$source_label" "$status" "$features"
    idx=$((idx + 1))
  done
  if [[ -n "$note" ]]; then
    echo
    echo "Not selectable known row:"
    echo "  10.0-26  base unresolved  GENVW available"
  fi
}

genvw_rebuild_picker_print_target_options() {
  local mode="${1:-standalone}"
  echo
  echo "Options:"
  echo "  1-N  Select target"
  echo "  a    Select all rebuildable targets for this provider"
  echo "  m    Select targets without a patched gENVW tool yet"
  echo "  b    Back"
  if [[ "$mode" == "wizard" ]]; then
    echo "  0    Back to launch targets"
  else
    echo "  0    Exit"
  fi
  echo
  printf '%s' "Choose target or option: "
}

genvw_rebuild_picker_print_selected_row() {
  local provider="${1:-}" row="${2:-}"
  local exact_id="" version="" runtime="" arch="" source_label="" status="" features="" base_label=""
  echo "Selected:"
  case "$provider" in
    cachyos)
      IFS='|' read -r _ _ _ _ exact_id version runtime arch source_label status features <<<"$row"
      printf '  CachyOS Proton %s %s %s\n' "$version" "$runtime" "$arch"
      printf '  Source: %s\n' "$source_label"
      printf '  gENVW:  %s\n' "$status"
      printf '  Features: %s\n' "$features"
      ;;
    dw)
      IFS='|' read -r _ _ _ _ exact_id version base_label runtime arch source_label status features <<<"$row"
      features="$(genvw_dw_align_split_env_feature_labels "$version" "$base_label" "$runtime" "$status" "$features")"
      printf '  DW-Proton %s\n' "$version"
      printf '  Base: %s %s %s\n' "$base_label" "$runtime" "$arch"
      printf '  Source: %s\n' "$source_label"
      printf '  gENVW:  %s\n' "$status"
      printf '  Features: %s\n' "$features"
      ;;
  esac
}

genvw_rebuild_picker_print_selected_scope() {
  local provider="${1:-}" missing_only="${2:-0}"
  local provider_label=""
  case "$provider" in
    cachyos) provider_label="CachyOS Proton" ;;
    dw) provider_label="DW-Proton" ;;
    *) provider_label="Proton" ;;
  esac
  echo "Selected:"
  if ((missing_only == 1)); then
    printf '  %s targets without a patched gENVW tool yet\n' "$provider_label"
  else
    printf '  All %s rebuildable targets\n' "$provider_label"
  fi
}

genvw_rebuild_picker_build_command() {
  local provider="${1:-}" row="${2:-}" is_multi="${3:-0}" missing_only="${4:-0}"
  local exact_id="" selected_version=""
  local -n cmd_ref="$5"

  cmd_ref=("rebuild" "-p")
  if [[ "$provider" == "cachyos" ]]; then
    IFS='|' read -r _ _ _ _ exact_id _ <<<"$row"
    cmd_ref+=("cachyos")
    if ((is_multi == 1)); then
      cmd_ref+=("--all-targets")
    else
      cmd_ref+=("--target-id" "$exact_id")
    fi
  else
    IFS='|' read -r _ _ _ _ exact_id selected_version _ <<<"$row"
    cmd_ref+=("dw")
    if ((is_multi == 1)); then
      cmd_ref+=("--all-targets")
    else
      cmd_ref+=("-t" "$selected_version")
    fi
  fi
  ((missing_only == 1)) && cmd_ref+=("--missing-only")
}

genvw_rebuild_picker_choose_command() {
  local helper="${1:-}" mode="${2:-standalone}" choice="" provider="" row="" note=""
  local cachyos_usable=0 cachyos_known=0 cachyos_newest=""
  local dw_usable=0 dw_known=0 dw_newest=""
  local -a rows=() built_cmd=()
  local target_choice="" exact_id="" selected_version="" supported_count=0
  local is_multi=0 missing_only=0 row_count=0 row_index=0
  local -n cmd_ref="$3"

  cmd_ref=()

  while :; do
    genvw_rebuild_picker_collect_provider_summary "$helper" \
      cachyos_usable cachyos_known cachyos_newest \
      dw_usable dw_known dw_newest
    genvw_rebuild_picker_print_provider_menu \
      "$cachyos_usable" "$cachyos_known" "$cachyos_newest" \
      "$dw_usable" "$dw_known" "$dw_newest" "$mode"
    tty_read choice || {
      echo
      [[ "$mode" == "standalone" ]] && echo "Exited rebuild picker."
      return 1
    }
    echo
    choice="$(trim "$choice")"
    case "$choice" in
      1) provider="cachyos" ;;
      2) provider="dw" ;;
      0)
        [[ "$mode" == "standalone" ]] && echo "Exited rebuild picker."
        return 1
        ;;
      *) echo "Invalid selection. Enter one of: 0, 1, 2." ; continue ;;
    esac

    while :; do
      rows=()
      note=""
      if [[ "$provider" == "cachyos" ]]; then
        genvw_rebuild_picker_collect_cachyos_rows "$helper" rows
        genvw_rebuild_picker_print_cachyos_targets rows
      else
        genvw_rebuild_picker_collect_dw_rows "$helper" rows note
        genvw_rebuild_picker_print_dw_targets rows "$note"
      fi
      genvw_rebuild_picker_print_target_options "$mode"
      tty_read target_choice || {
        echo
        [[ "$mode" == "standalone" ]] && echo "Exited rebuild picker."
        return 1
      }
      echo
      target_choice="$(trim "$target_choice")"
      is_multi=0
      missing_only=0
      exact_id=""
      selected_version=""
      case "$target_choice" in
        0)
          [[ "$mode" == "standalone" ]] && echo "Exited rebuild picker."
          return 1
          ;;
        b | B)
          echo "Back to provider selection."
          break
          ;;
        a | A)
          is_multi=1
          ;;
        m | M)
          is_multi=1
          missing_only=1
          supported_count=0
          for row in "${rows[@]}"; do
            case "$row" in
              *"|supported|"*) supported_count=$((supported_count + 1)) ;;
            esac
          done
          if ((supported_count == 0)); then
            echo "Nothing to rebuild."
            continue
          fi
          ;;
        '' | *[!0-9]*)
          echo "Invalid selection. Enter 0, 1, ..., N, a, m, or b."
          continue
          ;;
        *)
          row_count="${#rows[@]}"
          row_index=$((10#$target_choice))
          if ((row_index < 1 || row_index > row_count)); then
            echo "Invalid selection. Enter 0, 1, ..., N, a, m, or b."
            continue
          fi
          row="${rows[row_index-1]}"
          ;;
      esac
      echo
      if ((is_multi == 1)); then
        genvw_rebuild_picker_print_selected_scope "$provider" "$missing_only"
        echo
        echo "This will rebuild all selected gENVW Proton tools."
      else
        genvw_rebuild_picker_print_selected_row "$provider" "$row"
        echo
        echo "This will rebuild the selected gENVW Proton tool."
      fi
      if ask_yes_no_default "Proceed? [y/N]: " "n"; then
        genvw_rebuild_picker_build_command "$provider" "$row" "$is_multi" "$missing_only" built_cmd
        cmd_ref=("${built_cmd[@]}")
        return 0
      fi
      return 1
    done
  done
}

genvw_rebuild_picker() {
  local helper="${1:-}"
  local -a cmd=()

  if genvw_rebuild_picker_choose_command "$helper" "standalone" cmd; then
    proton_helper_exec "$helper" "${cmd[@]}"
  fi
  return 0
}

# genvw_fsr4_integrity_guard
# when local-only fsr4 is requested, check dll trust (meta + allowlist) before launch.
# msg, ok, warn

genvw_fsr4_integrity_guard() {
  local want_ver=""

  unset GENVW_FSR4_LOCAL_TRUST_READY
  unset GENVW_FSR4_LOCAL_TRUST_VER

  want_ver="$(genvw_fsr4_guess_selected_ver)"
  genvw_fsr4_is_local_only "${want_ver:-}" || return 0

  local rdna_gen fallback_rdna3 fallback_global
  rdna_gen="$(detect_rdna_gen 2>/dev/null || printf '0')"
  fallback_rdna3="$(genvw_fsr4_default_remote_for_gen 3)"
  fallback_global="$(genvw_fsr4_default_remote_for_gen "$rdna_gen")"

  local helper
  helper="$(proton_helper_path 2>/dev/null || true)"

  local kv dll_present meta_present meta_match reason url allow_match allow_reason allow_path dll_sha dll_size
  url="${AMD_DRIVER_URL:-}"

  # defaults (safe to print)
  allow_match=0
  allow_reason="unknown"
  allow_path=""
  dll_sha=""
  dll_size=""

  if [[ -z "$helper" || ! -e "$helper" ]]; then
    dll_present=0
    meta_present=0
    meta_match=0
    reason="helper_missing"
    allow_reason="helper_missing"
  else
    kv="$(proton_helper_run_internal_check_kv "$helper" check --kv --ver "$want_ver" 2>/dev/null)"
    genvw_exit_on_signal_rc $?
    genvw_parse_fsr4_local_trust_kv \
      "$kv" \
      dll_present \
      meta_present \
      meta_match \
      reason \
      allow_match \
      allow_reason \
      allow_path \
      dll_sha \
      dll_size >/dev/null 2>&1 || true
  fi

  # trusted only when meta match + allowlist match
  if [[ "${dll_present:-0}" == "1" && "${meta_match:-0}" == "1" && "${allow_match:-0}" == "1" ]]; then
    GENVW_FSR4_LOCAL_TRUST_READY=1
    GENVW_FSR4_LOCAL_TRUST_VER="$want_ver"
    msg "${I_INFO} Provenance integrity: ${I_OK} META_MATCH=1 (ok)"
    msg "${I_INFO} Allowlist: ${I_OK} ALLOWLIST_MATCH=1 (ok)"
    msg "${I_OK} DLL trust: Trusted (META_MATCH=1, ALLOWLIST_MATCH=1)"
    return 0
  fi

  msg "${I_WARN} ${YELLOW}gENVW security: Local FSR4 DLL is not trusted.${RESET}" >&2
  msg "    DLL_PRESENT=${dll_present:-0} META_PRESENT=${meta_present:-0} META_MATCH=${meta_match:-0} REASON=${reason:-unknown} ALLOWLIST_MATCH=${allow_match:-0} ALLOWLIST_REASON=${allow_reason:-unknown}" >&2
  if [[ -n "${allow_path:-}" ]]; then
    msg "    Allowlist: ${allow_path}" >&2
  fi

  # allowlist line to add (when we have sha+size)
  if [[ "${allow_match:-0}" != "1" && -n "${dll_sha:-}" && -n "${dll_size:-}" ]]; then
    msg "    Add to allowlist (space-separated): ${dll_sha} ${dll_size}" >&2
  fi

  local tamper=0 tamper_reason=""
  if [[ "${dll_present:-0}" == "1" ]]; then
    case "${reason:-}" in
      sha256_mismatch | size_mismatch | meta_sha_invalid | meta_size_invalid)
        if [[ "${meta_match:-0}" == "0" ]]; then
          tamper=1
          tamper_reason="${reason:-unknown}"
        fi
        ;;
    esac
    if [[ "$tamper" != "1" && "${meta_match:-0}" == "1" && "${allow_match:-0}" == "0" && "${allow_reason:-}" == "not_allowlisted" ]]; then
      tamper=1
      tamper_reason="${allow_reason:-unknown}"
    fi
  fi

  if [[ "$tamper" == "1" ]]; then
    err "Local FSR4 DLL is not trusted: tamper-class trust failure (${tamper_reason}). Refusing to launch; reinstall, re-pin, or re-allowlist it with genvw proton dll install."
    return 13
  fi

  # details only under DEBUG/verbose
  if [[ "${DEBUG:-0}" == "1" || "${GENVW_VERBOSE:-0}" == "1" ]]; then
    msg "    ${I_WARN} ${YELLOW}Details:${RESET}" >&2
    msg "       This DLL failed one or more trust checks (meta and/or allowlist)." >&2

    case "${reason:-unknown}" in
      ok | "") ;;
      missing_meta) msg "       • Meta file is missing → provenance can't be confirmed for this DLL." >&2 ;;
      meta_sha_invalid)
        msg "       • Meta SHA-256 field is missing or malformed → cannot verify provenance." >&2
        ;;
      meta_size_invalid)
        msg "       • Meta DLL size field is malformed → meta is not trustworthy." >&2
        ;;
      size_mismatch | sha256_mismatch)
        msg "       • Meta/DLL mismatch → the DLL may have changed since install (or the meta is out of date)." >&2
        ;;
      no_sha256_tool)
        msg "       • Required hashing tool is missing → integrity can't be verified reliably on this system." >&2
        ;;
      insufficient_data)
        msg "       • Not enough data in meta to verify integrity (missing fields)." >&2
        ;;
      helper_missing | helper_unavailable)
        msg "       • Proton helper is missing/unavailable → trust checks could not run." >&2
        ;;
      *) msg "       • Provenance check failed (reason=${reason})." >&2 ;;
    esac

    case "${allow_reason:-unknown}" in
      ok | "") ;;
      allowlist_missing)
        msg "       • Allowlist file is missing at: ${allow_path}" >&2
        msg "         (Without it, the DLL can't be approved against your trusted fingerprint set.)" >&2
        ;;
      not_allowlisted)
        msg "       • DLL fingerprint is not allowlisted → it may be from a different driver package/version than your trusted set." >&2
        ;;
      pair_unavailable)
        msg "       • Could not compute the required fingerprint pair (sha256+size) → allowlist check can't run." >&2
        ;;
      kv_missing_allowlist)
        msg "       • Helper did not report allowlist status (out of date helper?) → cannot confirm allowlist trust." >&2
        ;;
      *) msg "       • Allowlist check failed (reason=${allow_reason})." >&2 ;;
    esac

    msg "       Most often: DLL came from a different driver package, or it was modified/tampered with." >&2
    msg "       In soft mode, gENVW will fall back to the safer path (FSR4 ${fallback_global} / generic)." >&2
    msg "       In strict mode, launch will be refused." >&2
  else
    msg "    ${I_WARN} ${YELLOW}Reason: trust checks failed or local FSR4 is not ready (set DEBUG=1 for details).${RESET}" >&2
  fi

  msg "    Fix: install a source artifact that contains FSR4 ${want_ver}." >&2
  msg "         Example: genvw proton dll install --url \"$url\"" >&2
  msg "         Or use a direct DLL: genvw proton dll install --dll \"/path/to/amdxcffx64_v${want_ver}.dll\"" >&2

  # footer summary (keeps the launch output tight)
  if [[ "${meta_match:-0}" != "1" ]]; then
    msg "${I_WARN} ${YELLOW}DLL trust: Not trusted (META_MATCH=0 REASON=${reason:-unknown})${RESET}" >&2
  elif [[ "${allow_match:-0}" != "1" ]]; then
    msg "${I_WARN} ${YELLOW}DLL trust: Not trusted (ALLOWLIST_MATCH=0 REASON=${allow_reason:-unknown})${RESET}" >&2
  else
    msg "${I_WARN} ${YELLOW}DLL trust: Not trusted (unknown)${RESET}" >&2
  fi

  if [[ "${GENVW_STRICT_META_MATCH:-0}" == "1" ]]; then
    err "Local FSR4 DLL is not trusted: strict mode enabled (GENVW_STRICT_META_MATCH=1). Refusing to launch."
    return 13
  fi

  msg "    Outcome: falling back to FSR4 ${fallback_global} / generic (soft mode)." >&2

  # soft fallback:
  # drop local dll usage
  # when a local-only version was requested, fall back to per-GPU remote defaults
  unset PROTON_FSR4_LOCAL

  if genvw_fsr4_is_local_only "${PROTON_FSR4_RDNA3_UPGRADE:-}"; then
    export PROTON_FSR4_RDNA3_UPGRADE="$fallback_rdna3"
  fi
  if genvw_fsr4_is_local_only "${PROTON_FSR4_UPGRADE:-}"; then
    export PROTON_FSR4_UPGRADE="$fallback_global"
  fi

  # keep wrapper knobs in step when the user typed a local-only version.
  if genvw_fsr4_is_local_only "${FSR4_RDNA3:-}"; then
    export FSR4_RDNA3="$fallback_rdna3"
  fi
  if genvw_fsr4_is_local_only "${FSR4:-}"; then
    export FSR4="$fallback_global"
  fi
}

genvw_apply_mlfg_runtime_policy() {
  local requested="" selected_ver=""

  if [ -n "${MLFG_UPGRADE:-}" ]; then
    requested="${MLFG_UPGRADE}"
  elif [ -n "${MLFG:-}" ]; then
    requested="${MLFG}"
  else
    unset MLFG
    unset MLFG_UPGRADE
    return 0
  fi

  case "$requested" in
    0 | 1) ;;
    *)
      err "gENVW: Invalid MLFG/MLFG_UPGRADE value: $requested" >&2
      msg "   Allowed: 0 (disable), 1 (enable)" >&2
      return 1
      ;;
  esac

  unset MLFG
  unset MLFG_UPGRADE

  if [ "$requested" = "0" ]; then
    return 0
  fi

  selected_ver="$(genvw_fsr4_guess_selected_ver)"
  if [ -n "${selected_ver:-}" ] \
    && genvw_fsr4_is_local_only "$selected_ver" \
    && [ "${GENVW_FSR4_LOCAL_TRUST_READY:-0}" = "1" ] \
    && [ "${GENVW_FSR4_LOCAL_TRUST_VER:-}" = "$selected_ver" ]; then
    export MLFG_UPGRADE=1
    return 0
  fi

  warn "gENVW: MLFG ignored: requires trusted local-only FSR4."
  if [ -z "${selected_ver:-}" ]; then
    msg "    FSR4 is not active." >&2
  elif genvw_fsr4_is_local_only "$selected_ver"; then
    msg "    Current FSR4 selection: ${selected_ver}, but no trusted local DLL is active." >&2
  else
    msg "    Current FSR4 selection: ${selected_ver} (remote/system)." >&2
  fi
  return 0
}

# profile management: genvw profile list|show|print|save|delete
if [ "${1:-}" = "profile" ]; then
  shift
  genvw_profile_cmd "$@"
  exit $?
fi

# --profile NAME: remember a named profile before wrapper mode
GENVW_ACTIVE_PROFILE=""
if [ "${1:-}" = "--profile" ]; then
  [ -z "${2:-}" ] && { err "gENVW: --profile requires a profile name"; exit 2; }
  GENVW_ACTIVE_PROFILE="$2"
  shift 2
fi

# proton subcommand
# forwards to genvw_proton.sh.
#
# helper lookup:
#   1) trusted sibling helper next to this script
#   2) optional unsafe/dev override via GENVW_ALLOW_UNSAFE_PROTON_HELPER=1
#
# usage: genvw proton SUBCMD ...
if [ "${1:-}" = "proton" ] || [ "${1:-}" = "--proton" ]; then
  if [ -n "${GENVW_ACTIVE_PROFILE:-}" ]; then
    err "gENVW: --profile is only supported for wrapper launch mode."
    msg "Use the profile with a wrapped command, for example: genvw --profile ${GENVW_ACTIVE_PROFILE} %command%" >&2
    exit 2
  fi
  shift
  # gpu gating for proton subcommands lives in genvw_proton.sh

  # script dir only used for error text ("looked for: ...")
  DIR="$(genvw_script_dir 2>/dev/null || true)"
  PROTON_HELPER="$(proton_helper_path 2>/dev/null || true)"

  # missing helper: short error always; extra steps only on a tty
  if [ -z "$PROTON_HELPER" ] || [ ! -e "$PROTON_HELPER" ] || [ ! -f "$PROTON_HELPER" ]; then
    err "genvw proton: helper script not found."
    msg "Looked for trusted helper: $DIR/genvw_proton.sh" >&2
    if [ -t 2 ]; then
      cat >&2 <<EOF

${I_TOOL} Fix:
  1) Put helper next to genvw (portable):
       install -Dm755 ./genvw_proton.sh "$DIR/genvw_proton.sh"
  2) Dev/test only: allow an explicit unsafe override:
       export GENVW_ALLOW_UNSAFE_PROTON_HELPER=1
       export GENVW_PROTON_HELPER=/full/path/to/genvw_proton.sh

Then try:
  genvw proton --help
EOF
    fi
    exit 1
  fi

  # quick helper: verify the local FSR4 dll for the selected version
  # usage: genvw proton dll verify-current
  if [ "${1:-}" = "dll" ] && { [ "${2:-}" = "verify-current" ] || [ "${2:-}" = "verify_current" ]; }; then
    _effective_local_ver=""
    _bad_override="$(genvw_fsr4_malformed_override_label 2>/dev/null || true)"
    cur_ver="$(genvw_fsr4_guess_selected_ver)"
    if [ -z "${cur_ver}" ]; then
      _legacy_local_ver="$(genvw_fsr4_legacy_local_input_ver 2>/dev/null || true)"
      if [ -n "${_legacy_local_ver:-}" ]; then
        warn "gENVW: verify-current treating legacy PROTON_FSR4_LOCAL as FSR4 ${_legacy_local_ver}."
        cur_ver="${_legacy_local_ver}"
      fi
    fi
    if [ -z "${cur_ver}" ]; then
      _effective_local_ver="$(genvw_probe_runtime_local_default_from_helper 2>/dev/null || true)"
      [ -n "${_effective_local_ver}" ] || _effective_local_ver="${GENVW_FSR4_WIZARD_LOCAL_DEFAULT}"
      if [ -n "${_bad_override:-}" ]; then
        warn "gENVW: verify-current ignoring malformed ${_bad_override}; using --ver ${_effective_local_ver}."
      fi
      cur_ver="${_effective_local_ver}"
    fi
    if genvw_fsr4_is_local_only "${cur_ver}"; then
      proton_helper_exec "$PROTON_HELPER" dll verify --ver "${cur_ver}"
      unset _legacy_local_ver
      unset _bad_override
      exit $?
    fi
    if genvw_fsr4_is_legacy_4x_triplet "${cur_ver}"; then
      msg "${I_INFO} verify-current: FSR4 ${cur_ver} is remote/system; no local cache DLL is expected." >&2
      _effective_local_ver="$(genvw_fsr4_effective_local_default_ver)"
      msg "Tip: verify a local DLL explicitly: genvw proton dll verify --ver ${_effective_local_ver}" >&2
      unset _legacy_local_ver
      unset _bad_override
      exit 0
    fi
    unset _legacy_local_ver
    unset _bad_override
    _effective_local_ver="$(genvw_fsr4_effective_local_default_ver)"
    proton_helper_exec "$PROTON_HELPER" dll verify --ver "${_effective_local_ver}"
    exit $?
  fi
  # no-scope rebuild guard: wrapper only (not applied to direct helper calls)
  if [ "${1:-}" = "rebuild" ] && [ -z "${GENVW_IN_PREP:-}" ]; then
    _rb_has_scope=0
    _rb_help=0
    for _rb_a in "$@"; do
      case "$_rb_a" in
        -h | --help | help)
          _rb_help=1
          break
          ;;
        --provider | -p | --all-targets | --target | -t | --date | --target-id)
          _rb_has_scope=1; break ;;
      esac
    done
    if [ "$_rb_help" -eq 1 ]; then
      unset _rb_has_scope _rb_help _rb_a
      proton_helper_exec "$PROTON_HELPER" "$@"
      exit $?
    fi
    if [ "$_rb_has_scope" -eq 0 ]; then
      if [ "$#" -eq 1 ] && genvw_tty_io_ready; then
        genvw_rebuild_picker "$PROTON_HELPER"
        exit $?
      fi
      genvw_rebuild_print_no_scope_help
      exit 1
    fi
    unset _rb_has_scope _rb_help _rb_a
  fi

  proton_helper_exec "$PROTON_HELPER" "$@"
fi

if [ -n "${GENVW_ACTIVE_PROFILE:-}" ]; then
  genvw_profile_load "$GENVW_ACTIVE_PROFILE" || exit $?
fi

# no args + stdin not a tty: avoid a silent no-op
if [ "$#" -eq 0 ] && [ ! -t 0 ]; then
  err "gENVW: no command provided (non-interactive)."
  msg "Tip: Run in a real terminal with no args to use the interactive wizard," >&2
  msg "or use it as a wrapper: genvw COMMAND... (Steam: genvw %command%)." >&2
  exit 2
fi


# interactive mode
if [ "$#" -eq 0 ] && [ -t 0 ]; then
  # interactive only (real terminal)
  genvw_show_logo
  #show_genvw_banner
  printf "%s\n" "${BOLD}${CYAN}=== gENVW – Interactive Steam launch options generator ===${RESET}"
  echo
  echo "Answer the questions below. At the end you'll get a line you can paste"
  echo "into Steam's Launch options for your game."
  echo

  LAUNCH_ENV=""
  HDR_ENABLED=0
  FSR4_RDNA3_USED=0
  GENVW_WIZARD_FSR4_SELECTION_KIND=""
  GENVW_WIZARD_FSR4_SELECTION_VERSION=""
  GENVW_SKIP_AUTO_TOOLS_PROMPTS=0
  WIZARD_PROTON_BUILD_DATE=""

genvw_offer_rebuild_outdated_tools() {
  # uses helper outputs already captured by genvw_setup_preflight():
  #   $1 = genvw_proton check output
  #   $2 = genvw_proton status output
  #   $3 = genvw_proton sources --machine output
  local check_out="${1:-}" status_out="${2:-}" sources_machine="${3:-}"

  # custom --suffix is off in this build.
  # this prompt is tied to the gENVW toolchain name, so keep it fixed.
  local suffix="gENVW"
  GENVW_SUFFIX="gENVW"

  # only in interactive wizard context
  if ! genvw_tty_io_ready; then
    return 0
  fi

  # if we rebuilt once already, don't ask again
  if [ -n "${GENVW_TOOLS_BUILT_THIS_RUN:-}" ]; then
    return 0
  fi

  # drop ansi so parsing stays stable
  local check_plain status_plain
  check_plain="$(printf '%s\n' "$check_out" | sed -E 's/\x1B\[[0-9;]*[A-Za-z]//g')"
  status_plain="$(printf '%s\n' "$status_out" | sed -E 's/\x1B\[[0-9;]*[A-Za-z]//g')"

  local newest_src_date="" schema="" source_count="" idx="" kind="" date="" bucket="" base=""
  local -a source_rows=()

  if [ -z "$sources_machine" ]; then
    sources_machine="$(run_proton_internal_sources_machine 2>/dev/null || true)"
  fi

  schema="$(genvw_kv_get_optional_unique "$sources_machine" "SOURCES_SCHEMA" 2>/dev/null || true)"
  source_count="$(genvw_kv_get_optional_unique "$sources_machine" "SOURCE_COUNT" 2>/dev/null || true)"
  if [[ "$schema" == "1" && "$source_count" =~ ^[0-9]+$ ]]; then
    for ((idx = 0; idx < source_count; idx++)); do
      kind="$(genvw_kv_get_optional_unique "$sources_machine" "SOURCE_${idx}_KIND" 2>/dev/null || true)"
      date="$(genvw_kv_get_optional_unique "$sources_machine" "SOURCE_${idx}_BUILD_DATE" 2>/dev/null || true)"
      bucket="$(genvw_kv_get_optional_unique "$sources_machine" "SOURCE_${idx}_POLICY_BUCKET" 2>/dev/null || true)"
      base="$(genvw_kv_get_optional_unique "$sources_machine" "SOURCE_${idx}_BASE" 2>/dev/null || true)"
      [[ "$kind" == "source" ]] || continue
      [[ "$date" =~ ^[0-9]{8}$ && -n "$base" ]] || continue
      case "$bucket" in
        stable_practical | policy_known_capability_gated) ;;
        *) continue ;;
      esac
      source_rows+=("${date}|${base}")
    done
    if ((${#source_rows[@]} > 0)); then
      newest_src_date="$(printf '%s\n' "${source_rows[@]}" | sort -t '|' -k1,1r -k2,2 | head -n1 | cut -d'|' -f1)"
    fi
  fi

  if [ -z "$newest_src_date" ]; then
    # Fallback for older helpers that do not expose sources --machine.
    newest_src_date="$(
      printf '%s\n' "$check_plain" \
        | grep -Eo 'proton-cachyos-[^[:space:]]+' \
        | grep -Eo '[0-9]{8}' \
        | sort -u \
        | tail -n 1
    )"
  fi

  # installed clone names for our suffix
  local clones
  clones="$(
    printf '%s\n' "$status_plain" \
      | grep -Eo 'proton-cachyos-[^[:space:]]+' \
      | grep -F -- "-$suffix" \
      | sort -u
  )"

  # missing data -> nothing to do
  [ -n "$newest_src_date" ] || return 0
  [ -n "$clones" ] || return 0

  # newest clone date we already have installed
  local newest_clone_date
  newest_clone_date="$(
    printf '%s\n' "$clones" \
      | grep -Eo '[0-9]{8}' \
      | sort -u \
      | tail -n 1
  )"
  [ -n "$newest_clone_date" ] || return 0

  # up to date (or newer than sources) -> stop here
  # (YYYYMMDD compares lexicographically)
  if [ "$newest_src_date" = "$newest_clone_date" ] || [ "$newest_src_date" \< "$newest_clone_date" ]; then
    return 0
  fi

  # older installed tools: anything dated before newest_src_date
  local old_tools
  old_tools="$(
    printf '%s\n' "$clones" | while IFS= read -r n; do
      if [[ "$n" =~ ([0-9]{8}) ]]; then
        if [ "${BASH_REMATCH[1]}" \< "$newest_src_date" ]; then
          printf '%s\n' "$n"
        fi
      fi
    done
  )"

  echo
  echo "${YELLOW}${I_WARN}  Outdated gENVW Proton tools detected.${RESET}" >&2
  echo "${I_DATE}  Installed (newest): $newest_clone_date" >&2
  echo "${I_DATE}  Available (newest): $newest_src_date" >&2
  echo >&2

  local old_tool_count="0"
  if [ -n "${old_tools:-}" ]; then
    old_tool_count="$(printf '%s\n' "$old_tools" | sed '/^$/d' | wc -l | tr -d '[:space:]')"
    [ -n "$old_tool_count" ] || old_tool_count="0"
  fi
  echo "${I_BOX} Older installed tools: $old_tool_count" >&2
  echo "${I_INFO} Full list: genvw proton list-clones" >&2
  echo >&2

  echo "${I_RECEIPT} Rebuild plan:" >&2
  echo "  Run: genvw proton rebuild -p cachyos -t ${newest_src_date} --dry-run" >&2
  echo "${I_INFO} Close Steam before rebuilding." >&2
  echo >&2

  # steam running handling (same flow as the other build prompt)
  if host_steam_is_running; then
    echo "${YELLOW}${I_INFO} Steam is running.${RESET}" >&2
    echo "${YELLOW}   Close Steam, rebuild, restart Steam.${RESET}" >&2
    return 0
  fi

  if ask_yes_no_default "${BOLD}${I_GO} Rebuild newest gENVW tools now? [Y/n]: ${RESET}" "y" >&2; then
    run_proton rebuild -p cachyos -t "$newest_src_date" >&2 && export GENVW_TOOLS_BUILT_THIS_RUN=1
  fi

  return 0
}

genvw_wizard_print_preflight_block() {
  local _wb_ctd="${1:-}" _wb_sfx="${2:-gENVW}" _wb_ctd_ok="${3:-0}" _wb_csrc="${4:-0}"
  local _wb_dll_dir="${GENVW_FSR4_LOCAL_DIR:-}"

  echo "Preflight: local gENVW Proton inventory check."
  printf '%s genvw proton check\n' "${I_DEBUG:-🧪}"
  echo
  echo "Paths:"
  printf '  %-22s %s\n' "Compatibilitytools.d:" "${_wb_ctd:-(none)}"
  printf '  %-22s %s\n' "DLL Cache:" "${_wb_dll_dir:-(none)}"
  printf '  %-22s %s\n' "Suffix:" "$_wb_sfx"
  echo

  local _wb_ctd_state="READY" _wb_ctd_detail="compatibilitytools.d exists"
  if [[ "${_wb_ctd_ok:-0}" != "1" ]]; then
    _wb_ctd_state="MISSING"
    _wb_ctd_detail="compatibilitytools.d not found"
  fi
  local _wb_py_state="READY" _wb_py_detail="python3 available"
  command -v python3 >/dev/null 2>&1 || { _wb_py_state="MISSING"; _wb_py_detail="python3 not found"; }
  local _wb_mk_state="READY" _wb_mk_detail="mktemp available"
  command -v mktemp >/dev/null 2>&1 || { _wb_mk_state="MISSING"; _wb_mk_detail="mktemp not found"; }

  local _wb_dll_state="MISSING" _wb_dll_detail="no DLLs in cache"
  local _wb_dll_count=0 _wb_dll_parts="" _wb_dll_f="" _wb_dll_base="" _wb_dll_ver=""
  local _wb_dll_sz=0 _wb_dll_mb_int=0 _wb_dll_mb_tenth=0 _wb_dll_item=""
  local _wb_had_null=0
  if [[ -d "${_wb_dll_dir:-}" ]]; then
    shopt -q nullglob && _wb_had_null=1
    shopt -s nullglob
    for _wb_dll_f in "$_wb_dll_dir"/*.dll; do
      _wb_dll_base="${_wb_dll_f##*/}"
      if [[ "$_wb_dll_base" =~ _v([0-9]+\.[0-9]+\.[0-9]+)\.dll$ ]]; then
        _wb_dll_ver="${BASH_REMATCH[1]}"
        _wb_dll_sz="$(wc -c < "$_wb_dll_f" 2>/dev/null || echo 0)"
        _wb_dll_mb_int=$(( _wb_dll_sz / 1048576 ))
        _wb_dll_mb_tenth=$(( (_wb_dll_sz % 1048576) * 10 / 1048576 ))
        _wb_dll_item="${_wb_dll_ver} (${_wb_dll_mb_int}.${_wb_dll_mb_tenth}M)"
        [[ -z "$_wb_dll_parts" ]] && _wb_dll_parts="$_wb_dll_item" || _wb_dll_parts="${_wb_dll_parts}, ${_wb_dll_item}"
        _wb_dll_count=$(( _wb_dll_count + 1 ))
      fi
    done
    (( _wb_had_null == 1 )) || shopt -u nullglob
    if (( _wb_dll_count > 0 )); then
      _wb_dll_state="READY"
      _wb_dll_detail="${_wb_dll_count} installed: ${_wb_dll_parts}"
    fi
  fi

  local _wb_summary_kv="" _wb_c_count=0 _wb_c_total=0 _wb_c_newest=""
  local _wb_dw_usable=0 _wb_dw_known=0 _wb_dw_newest=""
  _wb_summary_kv="$(run_proton_internal_check_human_summary_kv 2>/dev/null || true)"
  _wb_c_count="$(printf '%s\n' "$_wb_summary_kv" | grep '^CACHYOS_USABLE=' | head -1 | cut -d= -f2- 2>/dev/null || true)"
  _wb_c_total="$(printf '%s\n' "$_wb_summary_kv" | grep '^CACHYOS_KNOWN=' | head -1 | cut -d= -f2- 2>/dev/null || true)"
  _wb_c_newest="$(printf '%s\n' "$_wb_summary_kv" | grep '^CACHYOS_NEWEST=' | head -1 | cut -d= -f2- 2>/dev/null || true)"
  _wb_dw_usable="$(printf '%s\n' "$_wb_summary_kv" | grep '^DWPROTON_USABLE=' | head -1 | cut -d= -f2- 2>/dev/null || true)"
  _wb_dw_known="$(printf '%s\n' "$_wb_summary_kv" | grep '^DWPROTON_KNOWN=' | head -1 | cut -d= -f2- 2>/dev/null || true)"
  _wb_dw_newest="$(printf '%s\n' "$_wb_summary_kv" | grep '^DWPROTON_NEWEST=' | head -1 | cut -d= -f2- 2>/dev/null || true)"
  _wb_c_count="${_wb_c_count:-0}"
  _wb_c_total="${_wb_c_total:-0}"
  _wb_dw_usable="${_wb_dw_usable:-0}"
  _wb_dw_known="${_wb_dw_known:-0}"
  local _wb_prov_state="READY"
  local _wb_prov_detail="CachyOS ${_wb_c_count} usable / ${_wb_c_total} known; DW-Proton ${_wb_dw_usable} usable / ${_wb_dw_known} known"
  if [[ "${_wb_c_count:-0}" -eq 0 && "${_wb_dw_usable:-0}" -eq 0 ]]; then
    _wb_prov_state="MISSING"
  fi

  echo "Checks:"
  printf '  %-9s %-9s %s\n' "ITEM" "STATE" "DETAIL"
  printf '  %-9s %-9s %s\n' "CTD" "$_wb_ctd_state" "$_wb_ctd_detail"
  printf '  %-9s %-9s %s\n' "PYTHON" "$_wb_py_state" "$_wb_py_detail"
  printf '  %-9s %-9s %s\n' "MKTEMP" "$_wb_mk_state" "$_wb_mk_detail"
  printf '  %-9s %-9s %s\n' "DLL CACHE" "$_wb_dll_state" "$_wb_dll_detail"
  printf '  %-9s %-9s %s\n' "PROVIDERS" "$_wb_prov_state" "$_wb_prov_detail"
  echo

  echo "Targets:"
  printf '  %-11s %-15s %s\n' "PROVIDER" "USABLE / TOTAL" "NEWEST"
  printf '  %-11s %-15s %s\n' "CachyOS" "${_wb_c_count} / ${_wb_c_total}" "${_wb_c_newest:-(none)}"
  printf '  %-11s %-15s %s\n' "DW-Proton" "${_wb_dw_usable} / ${_wb_dw_known}" "${_wb_dw_newest:-(none)}"
  echo

  echo "Inventory:"
  printf '  %-14s %s\n' "Full targets:" "genvw proton sources"
  printf '  %-14s %s\n' "DLL cache:" "genvw proton dll list"
  echo
}

genvw_setup_preflight() {
  GENVW_SKIP_AUTO_TOOLS_PROMPTS=0
  GENVW_KV_TOOL_STATE_WARNED=0
  echo

  local helper out st
  helper="$(proton_helper_path || true)"
  if [ -z "$helper" ] || [ ! -f "$helper" ]; then
    echo "${I_WARN} Proton helper not found." >&2
    echo "   Looked for trusted helper: $(genvw_script_dir 2>/dev/null || printf '.')/genvw_proton.sh" >&2
    if [ -t 2 ]; then
      cat >&2 <<EOF

${I_TOOL} Fix:
  • place it next to genvw and: chmod +x ./genvw_proton.sh
  • dev/test only: export GENVW_ALLOW_UNSAFE_PROTON_HELPER=1
  • then export GENVW_PROTON_HELPER=/full/path/to/genvw_proton.sh
EOF
    fi
    echo "   Skipping Proton helper preflight." >&2
    echo
    return 0
  fi

  out="$(run_proton check 2>&1)"
  st=$?
  [ "$st" -eq 0 ] || echo "${I_WARN} genvw_proton check returned $st (continuing)." >&2

  # kv is the stable path when the helper supports it
  local _ctd _suffix _localdll _kv _steam_root _major _ctd_exists _dll_present _dll_size _dll_sha _sources_count _tools_found _proton_build_date
  local _kv_ok _kv_reason
  _kv="$(run_proton_internal_check_kv 2>/dev/null)"
  GENVW_HELPER_KV_CACHE="$_kv"
  GENVW_HELPER_KV_CACHE_READY=1
  genvw_exit_on_signal_rc $?
  _kv_ok=1
  _kv_reason=""
  if ! genvw_parse_preflight_kv \
    "$_kv" \
    _ctd \
    _suffix \
    _localdll \
    _steam_root \
    _major \
    _ctd_exists \
    _tools_found \
    _dll_present \
    _dll_size \
    _dll_sha \
    _sources_count \
    _proton_build_date \
    _kv_reason; then
    _kv_ok=0
  fi
  if [ "$_kv_ok" -ne 1 ]; then
    GENVW_SKIP_AUTO_TOOLS_PROMPTS=1
    GENVW_KV_TOOL_STATE_WARNED=1
    warn "gENVW: helper KV contract issue (${_kv_reason:-unknown}); using fallback parser for preflight." >&2
    warn "gENVW: skipping automatic tool-missing inference in preflight (helper contract mismatch)." >&2
    # fallback for older helpers with no kv output
    _ctd="$(printf '%s\n' "$out" | sed -nE 's/.*compatibilitytools\.d:[[:space:]]*//p' | head -n1)"
    _suffix="$(printf '%s\n' "$out" | sed -nE 's/.*suffix:[[:space:]]*//p' | head -n1)"
    _localdll="$(printf '%s\n' "$out" | sed -nE 's/.*local DLL:[[:space:]]*//p' | head -n1)"
    _ctd_exists=0
    _dll_present=0
    _dll_size=""
    _dll_sha=""
    _sources_count=0
    _tools_found=0
  fi

  case "${_proton_build_date:-}" in
    '' | *[!0-9]*) WIZARD_PROTON_BUILD_DATE="" ;;
    *) WIZARD_PROTON_BUILD_DATE="$_proton_build_date" ;;
  esac

  # sanitize parsed values (CR / NBSP / surrounding whitespace)
  _ctd="${_ctd//$'\r'/}"
  _ctd="${_ctd//$'\u00A0'/ }"
  _ctd="$(trim_outer_ws "$_ctd")"
  _suffix="${_suffix//$'\r'/}"
  _suffix="${_suffix//$'\u00A0'/ }"
  _suffix="$(trim "$_suffix")"
  _localdll="${_localdll//$'\r'/}"
  _localdll="${_localdll//$'\u00A0'/ }"
  _localdll="$(trim_outer_ws "$_localdll")"
  genvw_fsr4_refresh_runtime_local_default_from_localdll "$_localdll" || true

  # stash these for later checks/prompts in the wizard
  GENVW_CTD="${_ctd:-$HOME/.local/share/Steam/compatibilitytools.d}"
  GENVW_SUFFIX="${_suffix:-gENVW}"
  GENVW_MAJOR="${_major:-10.0}"
  [[ "$GENVW_MAJOR" =~ ^[0-9]+(\.[0-9]+)?$ ]] || GENVW_MAJOR="10.0"
  [[ "$GENVW_SUFFIX" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || GENVW_SUFFIX="gENVW"
  if [ "$_kv_ok" -eq 1 ] && [ "${_ctd_exists:-0}" = "1" ] && ! genvw_ctd_preflight_scan_ok "$GENVW_CTD"; then
    GENVW_SKIP_AUTO_TOOLS_PROMPTS=1
    warn "gENVW: skipping automatic tool prompts in preflight (CTD path is not scan-safe)." >&2
  fi

  # canonical path for real file checks (parsed paths are display-only)
  local _effective_local_default_ver _effective_local_dll
  _effective_local_default_ver="$(genvw_fsr4_effective_local_default_ver)"
  _effective_local_dll="$(genvw_fsr4_effective_local_dll_path)"
  LOCAL_DLL_FSR4="${_effective_local_dll}"

  genvw_wizard_print_preflight_block "$GENVW_CTD" "$GENVW_SUFFIX" "${_ctd_exists:-0}" "${_sources_count:-0}"

  # prep menu: first run, dll + tools both missing
  if [ -t 0 ] && [ -t 1 ]; then
    local _tools_missing=0
    if [ "$_kv_ok" -eq 1 ]; then
      if [ ! -d "$GENVW_CTD" ]; then
        _tools_missing=1
      elif genvw_ctd_preflight_scan_ok "$GENVW_CTD"; then
        _tools_missing=1
        if genvw_check_clones_present "$GENVW_CTD" "$GENVW_MAJOR" "$GENVW_SUFFIX"; then
          _tools_missing=0
        fi
      fi
    fi

    if [ ! -f "$LOCAL_DLL_FSR4" ] && [ "$_tools_missing" -eq 1 ]; then
      # keep the menu open if the step fails and both are still missing
      while :; do
        echo "${I_TOOLBOX} gENVW preflight: first-time setup needed" >&2
        echo "" >&2
        echo "Status:" >&2
        echo "  ${I_PUZZLE} Proton tools (gENVW):   ${I_ERR} missing" >&2
        echo "  ${I_BOX} Local FSR4 ${_effective_local_default_ver} DLL:   ${I_ERR} missing" >&2
        echo "" >&2
        echo "Details:" >&2
        echo "  • FSR4 ${_effective_local_default_ver} needs a trusted cached AMD DLL + patched Proton tools." >&2
        echo "  • Status: ${I_OK} game can still launch, but ${I_ERR} FSR4 ${_effective_local_default_ver} cannot." >&2
        echo "  • If you continue, gENVW will use a safe remote fallback." >&2
        echo "" >&2
        echo "What PREP does (one-time):" >&2
        echo "  • installs the AMD local DLL into: ~/.cache/protonfixes/upscalers/genvw/" >&2
        echo "  • builds/patches gENVW Proton tools in: ~/.local/share/Steam/compatibilitytools.d/" >&2
        echo "  • prints a reminder to restart Steam (Steam must re-scan tools)" >&2
        echo "" >&2
        echo "Safety:" >&2
        echo "  ${I_OK} does not touch game files or saves" >&2
        echo "  ${I_OK} does not touch Steam prefixes (steamapps/compatdata)" >&2
        echo "" >&2
        echo "Choose:" >&2
        echo "  1) ${I_OK} Run PREP now" >&2
        echo "  2) ${I_BOX} Install only the DLL" >&2
        echo "  3) ${I_TOOL} Rebuild only Proton tools" >&2
        echo "  4) ${I_GO} Continue launch (safe remote fallback)" >&2
        echo "  5) ${I_INFO} Show exact paths + copy/paste commands" >&2
        echo "  6) ${I_ERR} Abort" >&2
        echo "" >&2
        printf "Choose [1-6]: " >&2

        local _choice=""
        tty_read _choice || _choice=""
        _choice="$(trim "$_choice")"
        [ -z "$_choice" ] && _choice="1"

        case "$_choice" in
          1)
            echo "" >&2
            echo "${I_GO} Running: genvw proton prep" >&2
            run_proton prep --yes
            genvw_exit_on_signal_rc $?
            _tools_missing=0
            if [ "$_kv_ok" -eq 1 ]; then
              if [ ! -d "$GENVW_CTD" ]; then
                _tools_missing=1
              elif genvw_ctd_preflight_scan_ok "$GENVW_CTD"; then
                _tools_missing=1
                if genvw_check_clones_present "$GENVW_CTD" "$GENVW_MAJOR" "$GENVW_SUFFIX"; then
                  _tools_missing=0
                fi
              fi
            fi
            if [ ! -f "$LOCAL_DLL_FSR4" ] && [ "$_tools_missing" -eq 1 ]; then
              echo
              echo "${I_WARN} Still missing DLL + tools — returning to the menu." >&2
              echo "" >&2
              continue
            fi
            echo "" >&2
            echo "${I_GO} Restart Steam to re-scan compatibilitytools.d." >&2
            echo "   This launch may still fall back to a remote default until Steam restarts." >&2
            echo "" >&2
            break
            ;;
          2)
            echo "" >&2
            echo "${I_GO} Running: genvw proton dll install --ver \"$_effective_local_default_ver\"" >&2
            run_proton dll install --ver "$_effective_local_default_ver"
            genvw_exit_on_signal_rc $?
            _tools_missing=0
            if [ "$_kv_ok" -eq 1 ]; then
              if [ ! -d "$GENVW_CTD" ]; then
                _tools_missing=1
              elif genvw_ctd_preflight_scan_ok "$GENVW_CTD"; then
                _tools_missing=1
                if genvw_check_clones_present "$GENVW_CTD" "$GENVW_MAJOR" "$GENVW_SUFFIX"; then
                  _tools_missing=0
                fi
              fi
            fi
            if [ ! -f "$LOCAL_DLL_FSR4" ] && [ "$_tools_missing" -eq 1 ]; then
              echo
              echo "${I_WARN} Still missing DLL + tools — returning to the menu." >&2
              echo "" >&2
              continue
            fi
            echo "" >&2
            break
            ;;
          3)
            echo "" >&2
            echo "${I_GO} Running: genvw proton rebuild --all-targets" >&2
            run_proton rebuild --all-targets
            genvw_exit_on_signal_rc $?
            _tools_missing=0
            if [ "$_kv_ok" -eq 1 ]; then
              if [ ! -d "$GENVW_CTD" ]; then
                _tools_missing=1
              elif genvw_ctd_preflight_scan_ok "$GENVW_CTD"; then
                _tools_missing=1
                if genvw_check_clones_present "$GENVW_CTD" "$GENVW_MAJOR" "$GENVW_SUFFIX"; then
                  _tools_missing=0
                fi
              fi
            fi

            if [ ! -f "$LOCAL_DLL_FSR4" ] && [ "$_tools_missing" -eq 1 ]; then
              echo
              echo "${I_WARN} Still missing DLL + tools — returning to the menu." >&2
              echo "" >&2
              continue
            fi
            echo "" >&2
            echo "${I_GO} Restart Steam to re-scan compatibilitytools.d." >&2
            echo "" >&2
            break
            ;;
          4)
            echo "" >&2
            GENVW_PREP_SKIP_FURTHER_SETUP_PROMPTS=1
            echo "${I_GO} Continuing without first-time setup. (FSR4 ${_effective_local_default_ver} stays disabled until you run: genvw proton prep)" >&2
            break
            ;;
          5)
            echo "" >&2
            echo "${I_INFO} Details" >&2
            echo "" >&2
            echo "Expected files:" >&2
            echo "  DLL (FSR4 ${_effective_local_default_ver}):  $LOCAL_DLL_FSR4" >&2
            echo "  Tools (-$GENVW_SUFFIX):     $GENVW_CTD/*-$GENVW_SUFFIX*/" >&2
            echo "" >&2
            echo "One-time fix:" >&2
            echo "  genvw proton prep" >&2
            echo "" >&2
            echo "Manual steps:" >&2
            echo "  genvw proton dll install --ver \"$_effective_local_default_ver\"" >&2
            echo "  # Or install from a local DLL / driver source if you need a custom artifact" >&2
            echo "  genvw proton rebuild" >&2
            echo "  # Restart Steam afterwards" >&2
            echo "" >&2
            echo "Press Enter to return to the menu..." >&2
            local _ret=""
            tty_read _ret || true
            echo "" >&2
            echo "" >&2
            ;;
          6)
            echo "" >&2
            echo "${I_ERR} Aborted by user." >&2
            return 1
            ;;
          *)
            echo "" >&2
            echo "${I_WARN} Invalid choice: $_choice" >&2
            echo "" >&2
            ;;
        esac
      done
    fi
  fi

  # offer only the dll install here
  if [ -z "${GENVW_PREP_SKIP_FURTHER_SETUP_PROMPTS:-}" ] && [ ! -f "$LOCAL_DLL_FSR4" ]; then
    local _dll_prompt
    _dll_prompt="${YELLOW}${I_WARN} FSR4 ${_effective_local_default_ver} is not preinstalled in the helper cache yet.${RESET}
  Expected cache path: ${BOLD}${LOCAL_DLL_FSR4}${RESET}

${DIM}${I_INFO} If you want, install the trusted version now.
${I_INFO} Preferred: genvw proton dll install --ver ${_effective_local_default_ver}
${I_INFO} You can also skip this and let the patched backend resolve the version later.${RESET}

${YELLOW}Install the trusted cached version now? [Y/n]: ${RESET}"

    if ask_yes_no_default "$_dll_prompt" "y"; then
      if ! run_proton dll install --ver "$_effective_local_default_ver"; then
        echo "${RED}${I_ERR} Failed to install local DLL. Continuing.${RESET}" >&2
      fi
    fi
    echo
  fi

  # tools: if missing, offer rebuild (dll is independent)
  local status_out sources_out kv ctd_exists tools_found kv_reason
  status_out="$(run_proton status 2>&1)"
  genvw_exit_on_signal_rc $?
  if [ -z "${GENVW_PREP_SKIP_FURTHER_SETUP_PROMPTS:-}" ]; then
    sources_out="$(run_proton_internal_sources_machine 2>/dev/null || true)"
  fi
  kv="$(run_proton_internal_check_kv 2>/dev/null || true)"
  if ! genvw_parse_tool_state_kv "$kv" ctd_exists tools_found kv_reason; then
    GENVW_SKIP_AUTO_TOOLS_PROMPTS=1
    genvw_warn_untrusted_tool_state_kv "$kv_reason"
  fi
  if [ -z "${GENVW_PREP_SKIP_FURTHER_SETUP_PROMPTS:-}" ] && [ "${GENVW_SKIP_AUTO_TOOLS_PROMPTS:-0}" != "1" ] && { [ "${ctd_exists:-0}" != "1" ] || [ "${tools_found:-0}" -lt 1 ]; }; then
    if genvw_offer_build_tools "gENVW Proton tools are missing → local-DLL FSR4 versions (starting at ${_effective_local_default_ver}) will not work until tools are built."; then
      echo "${GREEN}${I_OK} Built/updated gENVW Proton tools. Restart Steam to re-scan compatibility tools.${RESET}"
    else
      echo "${YELLOW}${I_WARN} Tools are still missing.${RESET}"
      echo "${YELLOW}${I_GO} Fix (manual):${RESET}"
      echo "  ${I_TOOL} 1) Build/refresh tools:"
      echo "     ${I_TOOL} genvw proton rebuild"
      echo "  ${I_GO} 2) Restart Steam to re-scan compatibility tools."
    fi
  fi

  # tools exist, but can lag behind the newest sources
  if [ -z "${GENVW_PREP_SKIP_FURTHER_SETUP_PROMPTS:-}" ]; then
    genvw_offer_rebuild_outdated_tools "$out" "$status_out" "$sources_out"
  fi
  return 0
}

genvw_wizard_target_policy_label() {
  case "${1:-}" in
    stable_practical) printf '%s\n' "supported" ;;
    policy_known_capability_gated) printf '%s\n' "supported" ;;
    future_unknown) printf '%s\n' "unsupported" ;;
    *) printf '%s\n' "unsupported" ;;
  esac
}

genvw_wizard_target_policy_bucket() {
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

genvw_wizard_target_display() {
  local idx="${1:-}" major="" date="" runtime="" arch="" out=""
  major="${GENVW_WIZARD_TARGET_MAJORS[$idx]:-}"
  date="${GENVW_WIZARD_TARGET_DATES[$idx]:-}"
  runtime="${GENVW_WIZARD_TARGET_RUNTIMES[$idx]:-}"
  arch="$(genvw_wizard_target_arch_for_display "${GENVW_WIZARD_TARGET_ARCHES[$idx]:-}")"
  if [[ -n "$major" && -n "$date" ]]; then
    out="${major}-${date}"
  else
    out="${GENVW_WIZARD_TARGET_BASES[$idx]:-${GENVW_WIZARD_TARGET_PATHS[$idx]##*/}}"
  fi
  [[ -n "$runtime" ]] && out="$out $runtime"
  [[ -n "$arch" ]] && out="$out $arch"
  printf '%s\n' "$out"
}

genvw_wizard_target_arch_for_display() {
  case "${1:-}" in
    system-x86_64) printf '%s\n' "x86_64" ;;
    protonplus-unspecified | "") printf '%s\n' "unknown" ;;
    protonplus-x86_64 | protonplus-x86_64_v[1-4]) printf '%s\n' "${1#protonplus-}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

genvw_wizard_target_arch_for_group() {
  case "${1:-}" in
    system-x86_64) printf '%s\n' "x86_64" ;;
    protonplus-unspecified | "") printf '%s\n' "unknown" ;;
    protonplus-x86_64 | protonplus-x86_64_v[1-4]) printf '%s\n' "${1#protonplus-}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

genvw_wizard_target_source_label() {
  local idx="${1:-}" kind="" family="" provenance=""
  kind="${GENVW_WIZARD_TARGET_KINDS[$idx]:-source}"
  family="${GENVW_WIZARD_TARGET_FAMILIES[$idx]:-}"
  provenance="${GENVW_WIZARD_TARGET_PROVENANCES[$idx]:-}"
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

genvw_wizard_target_ctd() {
  local idx="${1:-}" path="" provenance=""
  if [[ -n "${GENVW_CTD:-}" ]]; then
    printf '%s\n' "$GENVW_CTD"
    return 0
  fi
  path="${GENVW_WIZARD_TARGET_PATHS[$idx]:-}"
  provenance="${GENVW_WIZARD_TARGET_PROVENANCES[$idx]:-}"
  case "$provenance" in
    ctd | explicit | genvw-clone)
      [[ -n "$path" ]] && dirname "$path"
      return 0
      ;;
  esac
  printf '%s\n' "$HOME/.local/share/Steam/compatibilitytools.d"
}

genvw_wizard_target_clone_base() {
  local idx="${1:-}" kind="" base="" family="" arch=""
  kind="${GENVW_WIZARD_TARGET_KINDS[$idx]:-source}"
  [[ "$kind" == "source" ]] || return 1
  base="${GENVW_WIZARD_TARGET_BASES[$idx]:-}"
  family="${GENVW_WIZARD_TARGET_FAMILIES[$idx]:-}"
  arch="${GENVW_WIZARD_TARGET_ARCHES[$idx]:-}"
  [[ -n "$base" ]] || return 1
  if [[ "$family" == "protonplus" ]]; then
    genvw_wizard_cachyos_protonplus_clone_base "$base" "$arch"
    return 0
  fi
  printf '%s\n' "$base"
}

genvw_wizard_target_clone_basename() {
  local idx="${1:-}" base="" suffix="${GENVW_SUFFIX:-gENVW}"
  base="$(genvw_wizard_target_clone_base "$idx" 2>/dev/null || true)"
  [[ -n "$base" ]] || return 1
  printf '%s-%s\n' "$base" "$suffix"
}

genvw_wizard_source_target_clone_exists() {
  local idx="${1:-}" ctd="" clone_basename=""
  [[ "${GENVW_WIZARD_TARGET_KINDS[$idx]:-source}" == "source" ]] || return 1
  clone_basename="$(genvw_wizard_target_clone_basename "$idx" 2>/dev/null || true)"
  [[ -n "$clone_basename" ]] || return 1
  ctd="$(genvw_wizard_target_ctd "$idx" 2>/dev/null || true)"
  [[ -n "$ctd" && -d "$ctd/$clone_basename" ]]
}

genvw_wizard_clone_matches_source_target() {
  local clone_idx="${1:-}" idx="" clone_basename="" source_clone=""
  [[ "${GENVW_WIZARD_TARGET_KINDS[$clone_idx]:-}" == "clone" ]] || return 1
  clone_basename="${GENVW_WIZARD_TARGET_PATHS[$clone_idx]##*/}"
  [[ -n "$clone_basename" ]] || return 1
  for idx in "${!GENVW_WIZARD_TARGET_PATHS[@]}"; do
    [[ "${GENVW_WIZARD_TARGET_KINDS[$idx]:-source}" == "source" ]] || continue
    source_clone="$(genvw_wizard_target_clone_basename "$idx" 2>/dev/null || true)"
    [[ "$source_clone" == "$clone_basename" ]] && return 0
  done
  return 1
}

genvw_wizard_target_status_label() {
  local idx="${1:-}" kind="" bucket=""
  kind="${GENVW_WIZARD_TARGET_KINDS[$idx]:-source}"
  bucket="${GENVW_WIZARD_TARGET_POLICIES[$idx]:-}"
  if [[ "$kind" == "clone" ]]; then
    printf '%s\n' "installed"
    return 0
  fi
  if genvw_wizard_source_target_clone_exists "$idx"; then
    printf '%s\n' "installed"
    return 0
  fi
  genvw_wizard_target_policy_label "$bucket"
}

genvw_wizard_apply_conservative_target() {
  local reason="${1:-wizard_target_conservative}"
  GENVW_DXVK_TARGET_ROOT=""
  GENVW_DXVK_TARGET_MAJOR=""
  GENVW_DXVK_TARGET_BUILD_DATE=""
  GENVW_DXVK_TARGET_REASON="$reason"
  GENVW_DXVK_TARGET_EXPECTED_POLICY="unknown_or_unsupported"
  GENVW_DXVK_TARGET_PROBE_POLICY=""
  GENVW_DXVK_TARGET_POLICY="unknown_or_unsupported"
  GENVW_DXVK_TARGET_WARN=""
  GENVW_DXVK_TARGET_READY=1
}

genvw_wizard_apply_known_target() {
  local idx="${1:-}" root="" date="" expected="" probe="" final="" warn_note="" bucket=""
  root="${GENVW_WIZARD_TARGET_PATHS[$idx]:-}"
  date="${GENVW_WIZARD_TARGET_DATES[$idx]:-}"
  bucket="${GENVW_WIZARD_TARGET_POLICIES[$idx]:-}"

  if [[ "$bucket" == "future_unknown" ]]; then
    GENVW_DXVK_TARGET_ROOT="$root"
    GENVW_DXVK_TARGET_MAJOR="${GENVW_WIZARD_TARGET_MAJORS[$idx]:-}"
    GENVW_DXVK_TARGET_BUILD_DATE=""
    GENVW_DXVK_TARGET_REASON="wizard_target_future_unknown"
    GENVW_DXVK_TARGET_EXPECTED_POLICY="unknown_or_unsupported"
    GENVW_DXVK_TARGET_PROBE_POLICY=""
    GENVW_DXVK_TARGET_POLICY="unknown_or_unsupported"
    GENVW_DXVK_TARGET_WARN=""
    GENVW_DXVK_TARGET_READY=1
    return 0
  fi

  expected="$(genvw_dxvk_policy_for_build_date "$date")"
  probe="$(genvw_dxvk_probe_tree_policy "$root" 2>/dev/null || true)"
  final="$expected"
  if [[ -n "$probe" && "$probe" != "unknown_or_unsupported" ]]; then
    final="$probe"
    if [[ "$expected" != "unknown_or_unsupported" && "$probe" != "$expected" ]]; then
      warn_note="date ${date} expected ${expected}, probe found ${probe}"
    fi
  fi

  GENVW_WIZARD_PROVIDER="cachyos"
  GENVW_DXVK_TARGET_ROOT="$root"
  GENVW_DXVK_TARGET_MAJOR="${GENVW_WIZARD_TARGET_MAJORS[$idx]:-}"
  GENVW_DXVK_TARGET_BUILD_DATE="$date"
  GENVW_DXVK_TARGET_REASON="wizard_target_source"
  GENVW_DXVK_TARGET_EXPECTED_POLICY="${expected:-unknown_or_unsupported}"
  GENVW_DXVK_TARGET_PROBE_POLICY="$probe"
  GENVW_DXVK_TARGET_POLICY="${final:-unknown_or_unsupported}"
  GENVW_DXVK_TARGET_WARN="$warn_note"
  GENVW_DXVK_TARGET_READY=1
}

genvw_wizard_target_policy_rank() {
  case "${1:-}" in
    policy_known_capability_gated) printf '%s\n' 3 ;;
    stable_practical) printf '%s\n' 2 ;;
    future_unknown) printf '%s\n' 1 ;;
    *) printf '%s\n' 0 ;;
  esac
}

genvw_wizard_target_source_rank() {
  local idx="${1:-}" kind="" family="" provenance=""
  kind="${GENVW_WIZARD_TARGET_KINDS[$idx]:-source}"
  family="${GENVW_WIZARD_TARGET_FAMILIES[$idx]:-}"
  provenance="${GENVW_WIZARD_TARGET_PROVENANCES[$idx]:-}"
  if [[ "$kind" == "clone" ]]; then
    printf '%s\n' 1
    return 0
  fi
  case "$family:$provenance" in
    system-package:*) printf '%s\n' 6 ;;
    protonplus:*) printf '%s\n' 5 ;;
    protonup-qt:ctd) printf '%s\n' 4 ;;
    protonup-qt:*) printf '%s\n' 4 ;;
    *) printf '%s\n' 3 ;;
  esac
}

genvw_wizard_target_runtime_rank() {
  case "${GENVW_WIZARD_TARGET_RUNTIMES[$1]:-}" in
    slr) printf '%s\n' 2 ;;
    native) printf '%s\n' 1 ;;
    *) printf '%s\n' 0 ;;
  esac
}

genvw_wizard_target_is_known_policy() {
  case "${1:-}" in
    stable_practical | policy_known_capability_gated) return 0 ;;
    *) return 1 ;;
  esac
}

genvw_wizard_add_target_from_sources_kv() {
  local kv="${1:-}" idx="${2:-}" path="" kind="" base="" major="" date="" runtime="" arch="" family="" provenance="" bucket="" label=""
  path="$(genvw_kv_get_optional_unique "$kv" "SOURCE_${idx}_PATH" 2>/dev/null || true)"
  [[ -n "$path" ]] || return 0
  kind="$(genvw_kv_get_optional_unique "$kv" "SOURCE_${idx}_KIND" 2>/dev/null || true)"
  base="$(genvw_kv_get_optional_unique "$kv" "SOURCE_${idx}_BASE" 2>/dev/null || true)"
  major="$(genvw_kv_get_optional_unique "$kv" "SOURCE_${idx}_MAJOR" 2>/dev/null || true)"
  date="$(genvw_kv_get_optional_unique "$kv" "SOURCE_${idx}_BUILD_DATE" 2>/dev/null || true)"
  runtime="$(genvw_kv_get_optional_unique "$kv" "SOURCE_${idx}_RUNTIME" 2>/dev/null || true)"
  arch="$(genvw_kv_get_optional_unique "$kv" "SOURCE_${idx}_ARCH" 2>/dev/null || true)"
  family="$(genvw_kv_get_optional_unique "$kv" "SOURCE_${idx}_FAMILY" 2>/dev/null || true)"
  provenance="$(genvw_kv_get_optional_unique "$kv" "SOURCE_${idx}_PROVENANCE" 2>/dev/null || true)"
  bucket="$(genvw_kv_get_optional_unique "$kv" "SOURCE_${idx}_POLICY_BUCKET" 2>/dev/null || true)"
  [[ -n "$bucket" ]] || bucket="$(genvw_wizard_target_policy_bucket "$major" "$date")"
  label="$(genvw_wizard_target_policy_label "$bucket")"
  case "$kind" in
    clone) ;;
    *) kind="source" ;;
  esac

  GENVW_WIZARD_TARGET_PATHS+=("$path")
  GENVW_WIZARD_TARGET_KINDS+=("$kind")
  GENVW_WIZARD_TARGET_BASES+=("$base")
  GENVW_WIZARD_TARGET_MAJORS+=("$major")
  GENVW_WIZARD_TARGET_DATES+=("$date")
  GENVW_WIZARD_TARGET_RUNTIMES+=("$runtime")
  GENVW_WIZARD_TARGET_ARCHES+=("$arch")
  GENVW_WIZARD_TARGET_FAMILIES+=("$family")
  GENVW_WIZARD_TARGET_PROVENANCES+=("$provenance")
  GENVW_WIZARD_TARGET_POLICIES+=("$bucket")
  GENVW_WIZARD_TARGET_LABELS+=("$label")
}

GENVW_WIZARD_DW_TARGET_BASES=()
GENVW_WIZARD_DW_TARGET_VERSIONS=()
GENVW_WIZARD_DW_TARGET_BASE_LABELS=()
GENVW_WIZARD_DW_TARGET_RUNTIMES=()
GENVW_WIZARD_DW_TARGET_ARCHES=()
GENVW_WIZARD_DW_TARGET_SOURCES=()
GENVW_WIZARD_DW_TARGET_FEATURES=()
GENVW_WIZARD_DW_TARGET_FSR4_DEFAULTS=()
GENVW_WIZARD_DW_TARGET_FSR4_ALLOWED=()
GENVW_WIZARD_DW_TARGET_STATUSES=()

genvw_wizard_load_dw_targets() {
  GENVW_WIZARD_DW_TARGET_BASES=()
  GENVW_WIZARD_DW_TARGET_VERSIONS=()
  GENVW_WIZARD_DW_TARGET_BASE_LABELS=()
  GENVW_WIZARD_DW_TARGET_RUNTIMES=()
  GENVW_WIZARD_DW_TARGET_ARCHES=()
  GENVW_WIZARD_DW_TARGET_SOURCES=()
  GENVW_WIZARD_DW_TARGET_FEATURES=()
  GENVW_WIZARD_DW_TARGET_FSR4_DEFAULTS=()
  GENVW_WIZARD_DW_TARGET_FSR4_ALLOWED=()
  GENVW_WIZARD_DW_TARGET_STATUSES=()

  local kv="" idx=0 total=0 ctd="" status=""
  local base="" version="" base_label="" runtime="" arch="" source="" features="" fsr4_default="" fsr4_allowed=""
  kv="$(run_proton_internal_dw_sources_machine 2>/dev/null || true)"
  [[ -n "$kv" ]] || return 0

  ctd="$(printf '%s\n' "$kv" | grep -m1 '^DW_CTD=' | cut -d= -f2- || true)"
  total="$(printf '%s\n' "$kv" | grep -m1 '^DW_SOURCE_COUNT=' | cut -d= -f2 || true)"
  [[ "$total" =~ ^[0-9]+$ ]] || return 0
  ((total > 0)) || return 0

  for ((idx = 0; idx < total; idx++)); do
    base="$(printf '%s\n' "$kv" | grep -m1 "^DW_SOURCE_${idx}_BASE=" | cut -d= -f2- || true)"
    version="$(printf '%s\n' "$kv" | grep -m1 "^DW_SOURCE_${idx}_VERSION=" | cut -d= -f2- || true)"
    base_label="$(printf '%s\n' "$kv" | grep -m1 "^DW_SOURCE_${idx}_BASE_LABEL=" | cut -d= -f2- || true)"
    runtime="$(printf '%s\n' "$kv" | grep -m1 "^DW_SOURCE_${idx}_RUNTIME=" | cut -d= -f2- || true)"
    arch="$(printf '%s\n' "$kv" | grep -m1 "^DW_SOURCE_${idx}_ARCH=" | cut -d= -f2- || true)"
    source="$(printf '%s\n' "$kv" | grep -m1 "^DW_SOURCE_${idx}_SOURCE=" | cut -d= -f2- || true)"
    features="$(printf '%s\n' "$kv" | grep -m1 "^DW_SOURCE_${idx}_FEATURES=" | cut -d= -f2- || true)"
    fsr4_default="$(printf '%s\n' "$kv" | grep -m1 "^DW_SOURCE_${idx}_FSR4_DEFAULT=" | cut -d= -f2- || true)"
    fsr4_allowed="$(printf '%s\n' "$kv" | grep -m1 "^DW_SOURCE_${idx}_FSR4_ALLOWED=" | cut -d= -f2- || true)"
    [[ -n "$base" && -n "$version" && -n "$arch" && -n "$source" ]] || continue
    if [[ -n "$ctd" && -d "$ctd/${base}-${arch}-gENVW" ]]; then
      status="installed"
    else
      status="supported"
    fi
    GENVW_WIZARD_DW_TARGET_BASES+=("$base")
    GENVW_WIZARD_DW_TARGET_VERSIONS+=("$version")
    GENVW_WIZARD_DW_TARGET_BASE_LABELS+=("$base_label")
    GENVW_WIZARD_DW_TARGET_RUNTIMES+=("$runtime")
    GENVW_WIZARD_DW_TARGET_ARCHES+=("$arch")
    GENVW_WIZARD_DW_TARGET_SOURCES+=("$source")
    GENVW_WIZARD_DW_TARGET_FEATURES+=("$features")
    GENVW_WIZARD_DW_TARGET_FSR4_DEFAULTS+=("$fsr4_default")
    GENVW_WIZARD_DW_TARGET_FSR4_ALLOWED+=("$fsr4_allowed")
    GENVW_WIZARD_DW_TARGET_STATUSES+=("$status")
  done
}

genvw_wizard_print_dw_section() {
  local start_pos="${1:-1}" limit="${2:-0}"
  local menu_pos="$start_pos" total_dw=0 dw_disp=0 dw_idx=0
  local version="" base_label="" runtime="" arch="" status="" features=""
  total_dw="${#GENVW_WIZARD_DW_TARGET_BASES[@]}"
  ((total_dw > 0)) || return 0
  echo
  echo "  DW-Proton:"
  printf '  %-2s %-8s %-15s %-10s %-10s %s\n' "#" "VERSION" "BASE" "ARCH" "GENVW" "FEATURES"
  for ((dw_disp = 0; dw_disp < total_dw; dw_disp++)); do
    ((limit > 0 && dw_disp >= limit)) && break
    dw_idx=$(( total_dw - 1 - dw_disp ))
    version="${GENVW_WIZARD_DW_TARGET_VERSIONS[$dw_idx]:-}"
    base_label="${GENVW_WIZARD_DW_TARGET_BASE_LABELS[$dw_idx]:-}"
    runtime="${GENVW_WIZARD_DW_TARGET_RUNTIMES[$dw_idx]:-}"
    arch="${GENVW_WIZARD_DW_TARGET_ARCHES[$dw_idx]:-}"
    status="${GENVW_WIZARD_DW_TARGET_STATUSES[$dw_idx]:-supported}"
    features="${GENVW_WIZARD_DW_TARGET_FEATURES[$dw_idx]:-FSR4}"
    features="$(genvw_dw_align_split_env_feature_labels "$version" "$base_label" "$runtime" "$status" "$features")"
    features="$(compact_feature_labels_for_human "$features")"
    printf '  %-2s %-8s %-15s %-10s %-10s %s\n' "$menu_pos" "$version" "$base_label" "$arch" "$status" "$features"
    menu_pos=$((menu_pos + 1))
  done
}

genvw_wizard_apply_dw_target() {
  local dw_idx="${1:-0}"
  local base="${GENVW_WIZARD_DW_TARGET_BASES[$dw_idx]:-}"
  local version="${GENVW_WIZARD_DW_TARGET_VERSIONS[$dw_idx]:-}"
  local base_label="${GENVW_WIZARD_DW_TARGET_BASE_LABELS[$dw_idx]:-}"
  local runtime="${GENVW_WIZARD_DW_TARGET_RUNTIMES[$dw_idx]:-}"
  local arch="${GENVW_WIZARD_DW_TARGET_ARCHES[$dw_idx]:-}"
  local source="${GENVW_WIZARD_DW_TARGET_SOURCES[$dw_idx]:-}"
  local features="${GENVW_WIZARD_DW_TARGET_FEATURES[$dw_idx]:-FSR4}"
  local status="${GENVW_WIZARD_DW_TARGET_STATUSES[$dw_idx]:-supported}"
  features="$(genvw_dw_align_split_env_feature_labels "$version" "$base_label" "$runtime" "$status" "$features")"

  if [[ -z "$base" || -z "$source" ]]; then
    printf "%s\n" "${RED}Selected DW-Proton target is no longer available.${RESET}" >&2
    exit 1
  fi
  if [[ ! -d "$source" ]]; then
    printf "%s\n" "${RED}Selected DW-Proton target is no longer available: ${base}${RESET}" >&2
    exit 1
  fi

  GENVW_WIZARD_PROVIDER="dwproton"
  GENVW_DW_TARGET_BASE="$base"
  GENVW_DW_TARGET_VERSION="$version"
  GENVW_DW_TARGET_SOURCE="$source"
  GENVW_DW_TARGET_ARCH="$arch"
  GENVW_DW_TARGET_BASE_LABEL="$base_label"
  GENVW_DW_TARGET_RUNTIME="$runtime"
  GENVW_DW_TARGET_FEATURES="$features"

  printf "%s\n" "${CYAN}Selected DW-Proton target: ${version} (${base_label}, ${arch})${RESET}"
  [[ -z "$features" ]] || printf "%s\n" "  ${features}"
}

genvw_provider_capability_get() {
  local record="${1:-}" key="${2:-}" line=""
  while IFS= read -r line; do
    if [[ "${line%%=*}" == "$key" ]]; then
      printf '%s\n' "${line#*=}"
      return 0
    fi
  done <<<"$record"
  return 1
}

genvw_provider_capability_bool01() {
  local record="${1:-}" key="${2:-}" value=""
  value="$(genvw_provider_capability_get "$record" "$key" 2>/dev/null || true)"
  [[ "$value" == "1" ]] && printf '%s\n' "1" || printf '%s\n' "0"
}

genvw_provider_capability_has_feature() {
  local features="${1:-}" want="${2:-}" feature=""
  local -a _genvw_capability_features=()
  IFS=',' read -r -a _genvw_capability_features <<<"$features"
  for feature in "${_genvw_capability_features[@]}"; do
    feature="$(trim "$feature")"
    [[ "$feature" == "$want" ]] && return 0
  done
  return 1
}

genvw_provider_capability_source_family() {
  case "${1:-}" in
    protonup-qt | protonplus | system-package | dwproton)
      printf '%s\n' "$1"
      ;;
    *)
      printf '%s\n' "unknown"
      ;;
  esac
}

genvw_provider_capability_source_provenance() {
  case "${1:-}" in
    ctd | system)
      printf '%s\n' "$1"
      ;;
    *)
      printf '%s\n' "unknown"
      ;;
  esac
}

genvw_provider_capability_arch_for_display() {
  case "${1:-}" in
    system-x86_64) printf '%s\n' "x86_64" ;;
    protonplus-unspecified | "") printf '%s\n' "unknown" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

genvw_provider_capability_known_policy() {
  case "${1:-}" in
    stable_practical | policy_known_capability_gated) return 0 ;;
    *) return 1 ;;
  esac
}

genvw_provider_capability_cachyos_policy_context() {
  local major="${1:-}" build_date="${2:-}" callback="${3:-}"
  local old_ready="${GENVW_DXVK_TARGET_READY-__unset__}"
  local old_root="${GENVW_DXVK_TARGET_ROOT-__unset__}"
  local old_major="${GENVW_DXVK_TARGET_MAJOR-__unset__}"
  local old_date="${GENVW_DXVK_TARGET_BUILD_DATE-__unset__}"
  local old_reason="${GENVW_DXVK_TARGET_REASON-__unset__}"
  local old_expected="${GENVW_DXVK_TARGET_EXPECTED_POLICY-__unset__}"
  local old_probe="${GENVW_DXVK_TARGET_PROBE_POLICY-__unset__}"
  local old_policy="${GENVW_DXVK_TARGET_POLICY-__unset__}"
  local old_warn="${GENVW_DXVK_TARGET_WARN-__unset__}"
  local rc=0
  shift 3 || true

  GENVW_DXVK_TARGET_READY=1
  GENVW_DXVK_TARGET_ROOT=""
  GENVW_DXVK_TARGET_MAJOR="$major"
  GENVW_DXVK_TARGET_BUILD_DATE="$build_date"
  GENVW_DXVK_TARGET_REASON="capability_context"
  GENVW_DXVK_TARGET_EXPECTED_POLICY="$(genvw_dxvk_policy_for_build_date "$build_date")"
  GENVW_DXVK_TARGET_PROBE_POLICY=""
  GENVW_DXVK_TARGET_POLICY="$GENVW_DXVK_TARGET_EXPECTED_POLICY"
  GENVW_DXVK_TARGET_WARN=""

  "$callback" "$@"
  rc=$?

  if [[ "$old_ready" == "__unset__" ]]; then unset GENVW_DXVK_TARGET_READY; else GENVW_DXVK_TARGET_READY="$old_ready"; fi
  if [[ "$old_root" == "__unset__" ]]; then unset GENVW_DXVK_TARGET_ROOT; else GENVW_DXVK_TARGET_ROOT="$old_root"; fi
  if [[ "$old_major" == "__unset__" ]]; then unset GENVW_DXVK_TARGET_MAJOR; else GENVW_DXVK_TARGET_MAJOR="$old_major"; fi
  if [[ "$old_date" == "__unset__" ]]; then unset GENVW_DXVK_TARGET_BUILD_DATE; else GENVW_DXVK_TARGET_BUILD_DATE="$old_date"; fi
  if [[ "$old_reason" == "__unset__" ]]; then unset GENVW_DXVK_TARGET_REASON; else GENVW_DXVK_TARGET_REASON="$old_reason"; fi
  if [[ "$old_expected" == "__unset__" ]]; then unset GENVW_DXVK_TARGET_EXPECTED_POLICY; else GENVW_DXVK_TARGET_EXPECTED_POLICY="$old_expected"; fi
  if [[ "$old_probe" == "__unset__" ]]; then unset GENVW_DXVK_TARGET_PROBE_POLICY; else GENVW_DXVK_TARGET_PROBE_POLICY="$old_probe"; fi
  if [[ "$old_policy" == "__unset__" ]]; then unset GENVW_DXVK_TARGET_POLICY; else GENVW_DXVK_TARGET_POLICY="$old_policy"; fi
  if [[ "$old_warn" == "__unset__" ]]; then unset GENVW_DXVK_TARGET_WARN; else GENVW_DXVK_TARGET_WARN="$old_warn"; fi
  return "$rc"
}

genvw_provider_capability_unknown_record() {
  cat <<'EOF'
CAPABILITY_SCHEMA=1
CAPABILITY_SCOPE=wizard-internal
PROVIDER=unknown
PROVIDER_FAMILY=unknown
SOURCE_KIND=unknown
SOURCE_FAMILY=unknown
SOURCE_PROVENANCE=unknown
VERSION=
MAJOR=
BUILD_DATE=
RUNTIME=unknown
ARCH=unknown
BASE_LABEL=
EVIDENCE_STATE=unknown
TARGET_VALID=0
FSR4_SUPPORTED=unknown
FSR4_OPTION_VISIBLE=0
FSR4_DEFAULT_REMOTE=unknown
FSR4_DEFAULT_LOCAL=unknown
FSR4_ALLOWED_VERSIONS=
FSR4_LOCAL_ONLY_VERSIONS=
FSR4_VERSION_SOURCE=unknown
OPTISCALER_PRESENT=unknown
OPTISCALER_ACTION=unknown
OPTISCALER_ENABLE_OPTION_VISIBLE=0
OPTISCALER_REASON=unknown_target
DXVK_POLICY=unknown_or_unsupported
DXVK_ASYNC_OPTION_VISIBLE=0
DXVK_ASYNC_ENV_NAME=
GPLASYNC_SUPPORTED=unknown
GPLALL_LEGACY=unknown
LLASYNC_SUPPORTED=unknown
LOWLATENCY_DXVK_SUPPORTED=unknown
DXVK_REASON=unknown_target
HDR_OPTION_VISIBLE=0
HDR_ENV_PROFILE=unknown
HDR_ENV_NAMES=
NTSYNC_OPTION_VISIBLE=0
NTSYNC_DEFAULT_STATE=unknown
NTSYNC_DISABLE_ENV_NAME=
NTSYNC_FORCE_ENV_NAME=
TIMEOUT_FIX_SUPPORTED=unknown
TIMEOUT_FIX_OPTION_VISIBLE=0
GAME_FIXES_SUPPORTED=unknown
GAME_FIXES_OPTION_VISIBLE=0
SHADER_CACHE_SUPPORTED=unknown
SHADER_CACHE_OPTION_VISIBLE=0
VKREFLEX_SUPPORTED=unknown
VKREFLEX_OPTION_VISIBLE=0
LOWLATENCY_LAYER_SUPPORTED=unknown
LOWLATENCY_LAYER_OPTION_VISIBLE=0
WIZARD_SAFE_OPTIONS=
WIZARD_HIDDEN_OPTIONS=fsr4,hdr,dxvk_async,gplasync,gplall_legacy,llasync,lowlatency_dxvk,optiscaler_enable,ntsync,timeout_fix,game_fixes,shader_cache,vkreflex,lowlatency_layer
CAPABILITY_REASON=unknown_target
EOF
}

genvw_provider_capability_emit_cachyos_record() {
  local kind="${1:-source}" family="${2:-unknown}" provenance="${3:-unknown}" base_label="${4:-}"
  local major="${5:-}" build_date="${6:-}" runtime="${7:-unknown}" arch="${8:-unknown}" policy="${9:-unknown_or_unsupported}"
  local target_valid="${10:-0}" evidence_state="${11:-source-grounded}" source_family="" source_provenance=""
  local fsr4_remote="" fsr4_local="" allowed_csv="" local_csv="" hdr_profile="" hdr_names=""
  local nts_visible=1 nts_default="manual" nts_disable="" nts_force="PROTON_USE_NTSYNC"
  local dxvk_async_visible=0 dxvk_async_env="" gplasync_supported=0 gplall_legacy=0 llasync_supported=0 lowlatency_supported=0
  local lowlatency_layer_supported="unknown" lowlatency_layer_visible=0 vkreflex_supported="unknown"
  local safe_options="fsr4,hdr,ntsync" hidden_options="optiscaler_enable,timeout_fix,game_fixes,shader_cache,vkreflex,lowlatency_layer"

  source_family="$(genvw_provider_capability_source_family "$family")"
  source_provenance="$(genvw_provider_capability_source_provenance "$provenance")"
  [[ -n "$runtime" ]] || runtime="unknown"
  [[ -n "$arch" ]] || arch="unknown"
  [[ -n "$policy" ]] || policy="unknown_or_unsupported"

  fsr4_remote="$(genvw_fsr4_upstream_auto_default_for_gen 4)"
  fsr4_local="$(genvw_fsr4_effective_local_default_ver 2>/dev/null || true)"
  [[ -n "$fsr4_local" ]] || fsr4_local="unknown"
  allowed_csv="$(genvw_fsr4_versions_csv_from_array GENVW_FSR4_RESOLVED_KNOB_ALLOWED_VERSIONS)"
  local_csv="$(genvw_fsr4_versions_csv_from_array GENVW_FSR4_RESOLVED_LOCAL_ONLY_VERSIONS)"

  if genvw_proton_policy_omits_proton_enable_hdr; then
    hdr_profile="wayland-hdr-no-proton-enable-hdr"
  else
    hdr_profile="legacy-wayland-hdr"
  fi
  hdr_names="$(genvw_hdr_env_label | tr -d ' ')"

  if genvw_proton_policy_uses_proton_no_ntsync; then
    nts_default="enabled"
    nts_disable="PROTON_NO_NTSYNC"
    nts_force=""
  elif [[ "$build_date" =~ ^[0-9]{8}$ ]] && ((10#$build_date >= 10#20260312)); then
    nts_default="enabled"
    nts_disable="PROTON_USE_NTSYNC"
    nts_force="PROTON_USE_NTSYNC"
  fi

  case "$policy" in
    legacy_gplall)
      dxvk_async_visible=1
      dxvk_async_env="PROTON_DXVK_GPLASYNC"
      gplasync_supported=1
      gplall_legacy=1
      lowlatency_supported=1
      safe_options+=",dxvk_async,gplasync,gplall_legacy,lowlatency_dxvk"
      hidden_options+=",llasync"
      ;;
    split_envs)
      dxvk_async_visible=1
      dxvk_async_env="PROTON_DXVK_GPLASYNC"
      gplasync_supported=1
      lowlatency_supported=1
      safe_options+=",dxvk_async,gplasync,lowlatency_dxvk"
      hidden_options+=",gplall_legacy,llasync"
      ;;
    lowlatency_only)
      lowlatency_supported=1
      safe_options+=",lowlatency_dxvk"
      hidden_options+=",dxvk_async,gplasync,gplall_legacy,llasync"
      if [[ "$build_date" =~ ^[0-9]{8}$ ]] && ((10#$build_date >= 10#20260519)); then
        lowlatency_layer_supported=1
        lowlatency_layer_visible="$target_valid"
        vkreflex_supported=1
        safe_options+=",lowlatency_layer"
        hidden_options="${hidden_options/,lowlatency_layer/}"
      fi
      ;;
    *)
      gplasync_supported="unknown"
      gplall_legacy="unknown"
      llasync_supported="unknown"
      lowlatency_supported="unknown"
      hidden_options+=",dxvk_async,gplasync,gplall_legacy,llasync"
      ;;
  esac

  cat <<EOF
CAPABILITY_SCHEMA=1
CAPABILITY_SCOPE=wizard-internal
PROVIDER=cachyos
PROVIDER_FAMILY=proton-cachyos
SOURCE_KIND=${kind}
SOURCE_FAMILY=${source_family}
SOURCE_PROVENANCE=${source_provenance}
VERSION=${major}-${build_date}
MAJOR=${major}
BUILD_DATE=${build_date}
RUNTIME=${runtime}
ARCH=${arch}
BASE_LABEL=${base_label}
EVIDENCE_STATE=${evidence_state}
TARGET_VALID=${target_valid}
FSR4_SUPPORTED=1
FSR4_OPTION_VISIBLE=${target_valid}
FSR4_DEFAULT_REMOTE=${fsr4_remote}
FSR4_DEFAULT_LOCAL=${fsr4_local}
FSR4_ALLOWED_VERSIONS=${allowed_csv}
FSR4_LOCAL_ONLY_VERSIONS=${local_csv}
FSR4_VERSION_SOURCE=policy
OPTISCALER_PRESENT=unknown
OPTISCALER_ACTION=unknown
OPTISCALER_ENABLE_OPTION_VISIBLE=0
OPTISCALER_REASON=no_enable_evidence
DXVK_POLICY=${policy}
DXVK_ASYNC_OPTION_VISIBLE=${dxvk_async_visible}
DXVK_ASYNC_ENV_NAME=${dxvk_async_env}
GPLASYNC_SUPPORTED=${gplasync_supported}
GPLALL_LEGACY=${gplall_legacy}
LLASYNC_SUPPORTED=${llasync_supported}
LOWLATENCY_DXVK_SUPPORTED=${lowlatency_supported}
DXVK_REASON=${policy}
HDR_OPTION_VISIBLE=${target_valid}
HDR_ENV_PROFILE=${hdr_profile}
HDR_ENV_NAMES=${hdr_names}
NTSYNC_OPTION_VISIBLE=${nts_visible}
NTSYNC_DEFAULT_STATE=${nts_default}
NTSYNC_DISABLE_ENV_NAME=${nts_disable}
NTSYNC_FORCE_ENV_NAME=${nts_force}
TIMEOUT_FIX_SUPPORTED=unknown
TIMEOUT_FIX_OPTION_VISIBLE=0
GAME_FIXES_SUPPORTED=unknown
GAME_FIXES_OPTION_VISIBLE=0
SHADER_CACHE_SUPPORTED=unknown
SHADER_CACHE_OPTION_VISIBLE=0
VKREFLEX_SUPPORTED=${vkreflex_supported}
VKREFLEX_OPTION_VISIBLE=0
LOWLATENCY_LAYER_SUPPORTED=${lowlatency_layer_supported}
LOWLATENCY_LAYER_OPTION_VISIBLE=${lowlatency_layer_visible}
WIZARD_SAFE_OPTIONS=${safe_options}
WIZARD_HIDDEN_OPTIONS=${hidden_options}
CAPABILITY_REASON=cachyos_policy
EOF
}

genvw_provider_capability_record_for_cachyos_target() {
  local idx="${1:-}" root="" kind="" family="" provenance="" base_label="" major="" build_date="" runtime="" arch="" bucket=""
  local expected="" probe="" policy="" target_valid=0
  root="${GENVW_WIZARD_TARGET_PATHS[$idx]:-}"
  kind="${GENVW_WIZARD_TARGET_KINDS[$idx]:-source}"
  family="${GENVW_WIZARD_TARGET_FAMILIES[$idx]:-unknown}"
  provenance="${GENVW_WIZARD_TARGET_PROVENANCES[$idx]:-unknown}"
  base_label="${GENVW_WIZARD_TARGET_BASES[$idx]:-${root##*/}}"
  major="${GENVW_WIZARD_TARGET_MAJORS[$idx]:-}"
  build_date="${GENVW_WIZARD_TARGET_DATES[$idx]:-}"
  runtime="${GENVW_WIZARD_TARGET_RUNTIMES[$idx]:-unknown}"
  arch="$(genvw_provider_capability_arch_for_display "${GENVW_WIZARD_TARGET_ARCHES[$idx]:-}")"
  bucket="${GENVW_WIZARD_TARGET_POLICIES[$idx]:-future_unknown}"

  if [[ -z "$major" || -z "$build_date" ]]; then
    genvw_provider_capability_unknown_record
    return 0
  fi
  if genvw_provider_capability_known_policy "$bucket"; then
    target_valid=1
  fi

  expected="$(genvw_dxvk_policy_for_build_date "$build_date")"
  probe="$(genvw_dxvk_probe_tree_policy "$root" 2>/dev/null || true)"
  policy="$expected"
  if [[ -n "$probe" && "$probe" != "unknown_or_unsupported" ]]; then
    policy="$probe"
  fi

  genvw_provider_capability_cachyos_policy_context "$major" "$build_date" \
    genvw_provider_capability_emit_cachyos_record "$kind" "$family" "$provenance" "$base_label" "$major" "$build_date" "$runtime" "$arch" "$policy" "$target_valid" "source-grounded"
}

genvw_dw_fsr4_default_for_version() {
  case "${1:-}" in
    10.0-10 | 10.0-11 | 10.0-12 | 10.0-16 | 10.0-17 | 10.0-20) printf '%s\n' "4.0.2" ;;
    10.0-21 | 11.0-2) printf '%s\n' "4.1.0" ;;
    10.0-23 | 10.0-25 | 10.0-26 | 11.0-1) printf '%s\n' "4.0.3" ;;
    *) printf '%s\n' "unknown" ;;
  esac
}

genvw_dw_fsr4_allowed_for_version() {
  case "${1:-}" in
    10.0-10 | 10.0-11 | 10.0-12 | 10.0-16 | 10.0-17 | 10.0-20) printf '%s\n' "4.0.0,4.0.1,4.0.2" ;;
    10.0-21 | 10.0-23 | 10.0-25 | 10.0-26 | 11.0-1 | 11.0-2) printf '%s\n' "4.0.0,4.0.1,4.0.2,4.0.3,4.1.0" ;;
    *) printf '%s\n' "" ;;
  esac
}

genvw_fsr4_csv_is_knob_allowed() {
  local raw="${1:-}" t="" v=""
  local -a toks=()
  declare -A seen=()
  [[ -n "$raw" ]] || return 1
  [[ "$raw" != *, && "$raw" != ,* && "$raw" != *",,"* ]] || return 1
  IFS=',' read -r -a toks <<<"$raw"
  ((${#toks[@]} > 0)) || return 1
  for t in "${toks[@]}"; do
    v="$(genvw_trim_space_edges "$t")"
    [[ -n "$v" ]] || return 1
    genvw_fsr4_is_knob_allowed "$v" || return 1
    [[ -z "${seen[$v]+x}" ]] || return 1
    seen["$v"]=1
  done
}

genvw_csv_without_token() {
  local raw="${1:-}" drop="${2:-}" token="" out=""
  local -a toks=()
  [[ -n "$raw" && -n "$drop" ]] || {
    printf '%s\n' "$raw"
    return 0
  }
  IFS=',' read -r -a toks <<<"$raw"
  for token in "${toks[@]}"; do
    token="$(genvw_trim_space_edges "$token")"
    [[ -n "$token" && "$token" != "$drop" ]] || continue
    [[ -n "$out" ]] && out+=","
    out+="$token"
  done
  printf '%s\n' "$out"
}

genvw_dw_version_has_split_env_dxvk() {
  local version="${1:-}" major="" minor="" patch=""
  [[ "$version" =~ ^([0-9]+)[.]([0-9]+)-([0-9]+)$ ]] || return 1
  major="${BASH_REMATCH[1]}"
  minor="${BASH_REMATCH[2]}"
  patch="${BASH_REMATCH[3]}"
  if ((10#$major == 11)) && ((10#$minor == 0)) && ((10#$patch >= 1)); then
    return 0
  fi
  if ((10#$major == 10)) && ((10#$minor == 0)) && ((10#$patch >= 20)); then
    return 0
  fi
  return 1
}

genvw_dw_target_has_split_env_dxvk() {
  local version="${1:-}" build_date="${2:-}" runtime="${3:-}" target_valid="${4:-0}"
  [[ "$target_valid" == "1" ]] || return 1
  [[ "$build_date" =~ ^[0-9]{8}$ ]] || return 1
  [[ -n "$runtime" && "$runtime" != "unresolved" ]] || return 1
  genvw_dw_version_has_split_env_dxvk "$version"
}

genvw_dw_hdr_env_profile_for_version() {
  case "${1:-}" in
    11.0-2 | 11.0-3) printf '%s\n' "wayland-only-conservative" ;;
    *)               printf '%s\n' "legacy-wayland-hdr" ;;
  esac
}

genvw_dw_hdr_env_names_for_profile() {
  case "${1:-}" in
    wayland-only-conservative) printf '%s\n' "PROTON_ENABLE_WAYLAND" ;;
    *)                         printf '%s\n' "PROTON_ENABLE_WAYLAND,PROTON_ENABLE_HDR,DXVK_HDR,ENABLE_HDR_WSI" ;;
  esac
}

genvw_dw_ntsync_mode_for_target() {
  local version="${1:-}" build_date="${2:-}" runtime="${3:-}" target_valid="${4:-0}"
  [[ "$target_valid" == "1" ]] || return 1
  [[ "$build_date" =~ ^[0-9]{8}$ ]] || return 1
  [[ -n "$runtime" && "$runtime" != "unknown" && "$runtime" != "unresolved" ]] || return 1
  case "$version" in
    10.0-20)    printf '%s\n' "proton_no_ntsync" ;;
    10.0-2[1-5]) printf '%s\n' "proton_use_ntsync_default" ;;
    *)          return 1 ;;
  esac
}

genvw_provider_capability_emit_dw_record() {
  local base="${1:-}" version="${2:-}" source="${3:-}" arch="${4:-unknown}" base_label="${5:-}" runtime="${6:-unknown}" features="${7:-}" evidence_state="${8:-descriptor-grounded}"
  local fsr4_default="${9:-}" fsr4_allowed="${10:-}" fsr4_local="" fsr4_version_source="provider-default"
  local target_valid=0 fsr4_supported=0 fsr4_visible=0 opt_present=0 opt_action="none" opt_reason="not_in_features"
  local dxvk_policy="unknown_or_unsupported" dxvk_async_visible=0 dxvk_async_env=""
  local gplasync_supported="unknown" gplall_legacy="unknown" llasync_supported="unknown" lowlatency_supported="unknown"
  local dxvk_reason="dwproton_hidden"
  local hdr_profile="legacy-wayland-hdr" hdr_names="PROTON_ENABLE_WAYLAND,PROTON_ENABLE_HDR,DXVK_HDR,ENABLE_HDR_WSI"
  local nts_visible=0 nts_default="unknown" nts_disable="" nts_force="" nts_mode=""
  local safe_options="" hidden_options="dxvk_async,gplasync,gplall_legacy,llasync,lowlatency_dxvk,optiscaler_enable,ntsync,timeout_fix,game_fixes,shader_cache,vkreflex,lowlatency_layer"
  local build_date=""

  [[ -n "$base" && -n "$version" && -n "$source" ]] && target_valid=1
  [[ -n "$runtime" ]] || runtime="unknown"
  [[ -n "$arch" ]] || arch="unknown"
  if [[ "$base" =~ ([0-9]{8}) ]]; then
    build_date="${BASH_REMATCH[1]}"
  elif [[ "$base_label" =~ ([0-9]{8}) ]]; then
    build_date="${BASH_REMATCH[1]}"
  fi
  hdr_profile="$(genvw_dw_hdr_env_profile_for_version "$version")"
  hdr_names="$(genvw_dw_hdr_env_names_for_profile "$hdr_profile")"
  nts_mode="$(genvw_dw_ntsync_mode_for_target "$version" "$build_date" "$runtime" "$target_valid" 2>/dev/null || true)"
  case "$nts_mode" in
    proton_no_ntsync)
      nts_visible=1
      nts_default="enabled"
      nts_disable="PROTON_NO_NTSYNC"
      ;;
    proton_use_ntsync_default)
      nts_visible=1
      nts_default="enabled"
      nts_disable="PROTON_USE_NTSYNC"
      nts_force="PROTON_USE_NTSYNC"
      ;;
  esac

  if genvw_provider_capability_has_feature "$features" "FSR4"; then
    fsr4_supported=1
    fsr4_visible="$target_valid"
    safe_options="fsr4,hdr"
    if [[ -z "$fsr4_default" || "$fsr4_default" == "unknown" ]]; then
      fsr4_default="$(genvw_dw_fsr4_default_for_version "$version")"
    fi
    if [[ -z "$fsr4_allowed" ]]; then
      fsr4_allowed="$(genvw_dw_fsr4_allowed_for_version "$version")"
    fi
    genvw_fsr4_is_knob_allowed "$fsr4_default" || fsr4_default="unknown"
    genvw_fsr4_csv_is_knob_allowed "$fsr4_allowed" || fsr4_allowed=""
    fsr4_local="$(genvw_fsr4_effective_local_default_ver 2>/dev/null || true)"
    genvw_fsr4_is_knob_allowed "$fsr4_local" || fsr4_local="unknown"
    [[ -n "$fsr4_allowed" ]] && fsr4_version_source="dw-descriptor"
  fi
  if [[ "$fsr4_supported" != "1" ]]; then
    fsr4_default="unknown"
    fsr4_local="unknown"
    fsr4_allowed=""
  fi
  if [[ "$version" =~ ^11[.]0-(2|3)$ ]] && genvw_provider_capability_has_feature "$features" "OptiScaler-preserved"; then
    opt_present=1
    opt_action="preserve"
    opt_reason="dwproton_preserved"
  fi
  if genvw_dw_target_has_split_env_dxvk "$version" "$build_date" "$runtime" "$target_valid"; then
    dxvk_policy="split_envs"
    dxvk_async_visible=1
    dxvk_async_env="PROTON_DXVK_GPLASYNC"
    gplasync_supported=1
    gplall_legacy=0
    llasync_supported=1
    lowlatency_supported=1
    dxvk_reason="dwproton_split_envs"
    safe_options="${safe_options:+$safe_options,}dxvk_async,gplasync,llasync,lowlatency_dxvk"
    hidden_options="$(genvw_csv_without_token "$hidden_options" "dxvk_async")"
    hidden_options="$(genvw_csv_without_token "$hidden_options" "gplasync")"
    hidden_options="$(genvw_csv_without_token "$hidden_options" "llasync")"
    hidden_options="$(genvw_csv_without_token "$hidden_options" "lowlatency_dxvk")"
  fi

  cat <<EOF
CAPABILITY_SCHEMA=1
CAPABILITY_SCOPE=wizard-internal
PROVIDER=dwproton
PROVIDER_FAMILY=dwproton
SOURCE_KIND=dw-source
SOURCE_FAMILY=dwproton
SOURCE_PROVENANCE=ctd
VERSION=${version}
MAJOR=${version%%-*}
BUILD_DATE=${build_date}
RUNTIME=${runtime}
ARCH=${arch}
BASE_LABEL=${base_label}
EVIDENCE_STATE=${evidence_state}
TARGET_VALID=${target_valid}
FSR4_SUPPORTED=${fsr4_supported}
FSR4_OPTION_VISIBLE=${fsr4_visible}
FSR4_DEFAULT_REMOTE=${fsr4_default}
FSR4_DEFAULT_LOCAL=${fsr4_local}
FSR4_ALLOWED_VERSIONS=${fsr4_allowed}
FSR4_LOCAL_ONLY_VERSIONS=${fsr4_allowed}
FSR4_VERSION_SOURCE=${fsr4_version_source}
OPTISCALER_PRESENT=${opt_present}
OPTISCALER_ACTION=${opt_action}
OPTISCALER_ENABLE_OPTION_VISIBLE=0
OPTISCALER_REASON=${opt_reason}
DXVK_POLICY=${dxvk_policy}
DXVK_ASYNC_OPTION_VISIBLE=${dxvk_async_visible}
DXVK_ASYNC_ENV_NAME=${dxvk_async_env}
GPLASYNC_SUPPORTED=${gplasync_supported}
GPLALL_LEGACY=${gplall_legacy}
LLASYNC_SUPPORTED=${llasync_supported}
LOWLATENCY_DXVK_SUPPORTED=${lowlatency_supported}
DXVK_REASON=${dxvk_reason}
HDR_OPTION_VISIBLE=${target_valid}
HDR_ENV_PROFILE=${hdr_profile}
HDR_ENV_NAMES=${hdr_names}
NTSYNC_OPTION_VISIBLE=${nts_visible}
NTSYNC_DEFAULT_STATE=${nts_default}
NTSYNC_DISABLE_ENV_NAME=${nts_disable}
NTSYNC_FORCE_ENV_NAME=${nts_force}
TIMEOUT_FIX_SUPPORTED=unknown
TIMEOUT_FIX_OPTION_VISIBLE=0
GAME_FIXES_SUPPORTED=unknown
GAME_FIXES_OPTION_VISIBLE=0
SHADER_CACHE_SUPPORTED=unknown
SHADER_CACHE_OPTION_VISIBLE=0
VKREFLEX_SUPPORTED=unknown
VKREFLEX_OPTION_VISIBLE=0
LOWLATENCY_LAYER_SUPPORTED=unknown
LOWLATENCY_LAYER_OPTION_VISIBLE=0
WIZARD_SAFE_OPTIONS=${safe_options}
WIZARD_HIDDEN_OPTIONS=${hidden_options}
CAPABILITY_REASON=dwproton_descriptor
EOF
}

genvw_provider_capability_record_for_dw_target() {
  local dw_idx="${1:-0}"
  genvw_provider_capability_emit_dw_record \
    "${GENVW_WIZARD_DW_TARGET_BASES[$dw_idx]:-}" \
    "${GENVW_WIZARD_DW_TARGET_VERSIONS[$dw_idx]:-}" \
    "${GENVW_WIZARD_DW_TARGET_SOURCES[$dw_idx]:-}" \
    "${GENVW_WIZARD_DW_TARGET_ARCHES[$dw_idx]:-unknown}" \
    "${GENVW_WIZARD_DW_TARGET_BASE_LABELS[$dw_idx]:-}" \
    "${GENVW_WIZARD_DW_TARGET_RUNTIMES[$dw_idx]:-unknown}" \
    "${GENVW_WIZARD_DW_TARGET_FEATURES[$dw_idx]:-}" \
    "descriptor-grounded" \
    "${GENVW_WIZARD_DW_TARGET_FSR4_DEFAULTS[$dw_idx]:-}" \
    "${GENVW_WIZARD_DW_TARGET_FSR4_ALLOWED[$dw_idx]:-}"
}

genvw_provider_capability_record_for_selected_target() {
  local idx=""
  case "${GENVW_WIZARD_PROVIDER:-unknown}" in
    cachyos)
      for idx in "${!GENVW_WIZARD_TARGET_PATHS[@]}"; do
        if [[ "${GENVW_WIZARD_TARGET_PATHS[$idx]:-}" == "${GENVW_DXVK_TARGET_ROOT:-}" ]]; then
          genvw_provider_capability_record_for_cachyos_target "$idx"
          return 0
        fi
      done
      genvw_provider_capability_cachyos_policy_context "${GENVW_DXVK_TARGET_MAJOR:-}" "${GENVW_DXVK_TARGET_BUILD_DATE:-}" \
        genvw_provider_capability_emit_cachyos_record "source" "unknown" "unknown" "" "${GENVW_DXVK_TARGET_MAJOR:-}" "${GENVW_DXVK_TARGET_BUILD_DATE:-}" "unknown" "unknown" "${GENVW_DXVK_TARGET_POLICY:-unknown_or_unsupported}" "0" "selected-global"
      ;;
    dwproton)
      genvw_provider_capability_emit_dw_record \
        "${GENVW_DW_TARGET_BASE:-}" \
        "${GENVW_DW_TARGET_VERSION:-}" \
        "${GENVW_DW_TARGET_SOURCE:-}" \
        "${GENVW_DW_TARGET_ARCH:-unknown}" \
        "${GENVW_DW_TARGET_BASE_LABEL:-}" \
        "${GENVW_DW_TARGET_RUNTIME:-unknown}" \
        "${GENVW_DW_TARGET_FEATURES:-}" \
        "selected-global"
      ;;
    *)
      genvw_provider_capability_unknown_record
      ;;
  esac
}

GENVW_WIZARD_SELECTED_CAPABILITY_RECORD=""
GENVW_WIZARD_DID_REBUILD=0
GENVW_WIZARD_SELECTED_CLONE_BASENAME=""

genvw_wizard_selected_capability_capture() {
  local record="" schema=""
  record="$(genvw_provider_capability_record_for_selected_target 2>/dev/null || true)"
  schema="$(genvw_provider_capability_get "$record" "CAPABILITY_SCHEMA" 2>/dev/null || true)"
  if [[ "$schema" != "1" ]]; then
    record="$(genvw_provider_capability_unknown_record)"
  fi
  GENVW_WIZARD_SELECTED_CAPABILITY_RECORD="$record"
}

genvw_wizard_selected_capability_get() {
  local key="${1:-}" record="${GENVW_WIZARD_SELECTED_CAPABILITY_RECORD:-}"
  genvw_provider_capability_get "$record" "$key"
}

genvw_wizard_selected_capability_bool01() {
  local key="${1:-}" record="${GENVW_WIZARD_SELECTED_CAPABILITY_RECORD:-}"
  genvw_provider_capability_bool01 "$record" "$key"
}

genvw_wizard_selected_capability_provider_is_cachyos() {
  [[ "$(genvw_wizard_selected_capability_get PROVIDER 2>/dev/null || true)" == "cachyos" ]]
}

genvw_wizard_selected_capability_provider_is_dwproton() {
  [[ "$(genvw_wizard_selected_capability_get PROVIDER 2>/dev/null || true)" == "dwproton" ]]
}

genvw_wizard_selected_dw_ntsync_is_deferred() {
  genvw_wizard_selected_capability_provider_is_dwproton || return 1
  [[ "$(genvw_wizard_selected_capability_bool01 NTSYNC_OPTION_VISIBLE)" == "1" ]] && return 1
  return 0
}

genvw_wizard_selected_target_id() {
  local _prov="${GENVW_WIZARD_PROVIDER:-}"
  case "$_prov" in
    cachyos)
      genvw_wizard_selected_capability_get BASE_LABEL 2>/dev/null || true
      ;;
    dwproton)
      local _v="${GENVW_DW_TARGET_VERSION:-}" _a="${GENVW_DW_TARGET_ARCH:-}"
      [[ -n "$_v" && -n "$_a" ]] || return 1
      printf '%s\n' "dwproton-${_v}-${_a}"
      ;;
    *)
      return 1
      ;;
  esac
}

genvw_wizard_cachyos_protonplus_clone_base() {
  local base="${1:-}" arch="${2:-}" prefix="" arch_part=""
  if [[ "$base" =~ ^(proton-cachyos-[0-9]+([.][0-9]+)?-[0-9]{8}-(native|slr))-protonplus-(x86_64(_v[1-4])?)$ ]]; then
    printf '%s\n' "$base"
    return 0
  fi
  if [[ "$base" =~ ^(proton-cachyos-[0-9]+([.][0-9]+)?-[0-9]{8}-(native|slr))-(x86_64(_v[1-4])?)$ ]]; then
    prefix="${BASH_REMATCH[1]}"
    arch_part="${BASH_REMATCH[4]}"
    printf '%s-protonplus-%s\n' "$prefix" "$arch_part"
    return 0
  fi
  if [[ "$arch" =~ ^protonplus-(x86_64(_v[1-4])?)$ && "$base" =~ ^(proton-cachyos-[0-9]+([.][0-9]+)?-[0-9]{8}-(native|slr))-x86_64(_v[1-4])?$ ]]; then
    prefix="${BASH_REMATCH[1]}"
    arch_part="${arch#protonplus-}"
    printf '%s-protonplus-%s\n' "$prefix" "$arch_part"
    return 0
  fi
  printf '%s\n' "$base"
}

genvw_wizard_selected_clone_basename() {
  local _target_id="${1:-}" _suffix="${2:-gENVW}" _prov="${GENVW_WIZARD_PROVIDER:-}"
  local _source_family="" _arch="" _base=""
  [[ -n "$_target_id" ]] || return 1
  _base="$_target_id"
  if [[ "$_prov" == "cachyos" ]]; then
    _source_family="$(genvw_wizard_selected_capability_get SOURCE_FAMILY 2>/dev/null || true)"
    _arch="$(genvw_wizard_selected_capability_get ARCH 2>/dev/null || true)"
    if [[ "$_source_family" == "protonplus" ]]; then
      _base="$(genvw_wizard_cachyos_protonplus_clone_base "$_target_id" "$_arch")"
    fi
  fi
  printf '%s-%s\n' "$_base" "$_suffix"
}

genvw_wizard_selected_ctd() {
  if [[ -n "${GENVW_CTD:-}" ]]; then
    printf '%s\n' "$GENVW_CTD"
    return 0
  fi
  local _prov="${GENVW_WIZARD_PROVIDER:-}" _d=""
  case "$_prov" in
    cachyos)
      [[ -n "${GENVW_DXVK_TARGET_ROOT:-}" ]] && _d="$(dirname "$GENVW_DXVK_TARGET_ROOT")"
      ;;
    dwproton)
      [[ -n "${GENVW_DW_TARGET_SOURCE:-}" ]] && _d="$(dirname "$GENVW_DW_TARGET_SOURCE")"
      ;;
  esac
  if [[ -n "$_d" ]]; then
    printf '%s\n' "$_d"
    return 0
  fi
  printf '%s\n' "$HOME/.local/share/Steam/compatibilitytools.d"
}

genvw_wizard_offer_selected_target_rebuild() {
  local _prov="${GENVW_WIZARD_PROVIDER:-unknown}"
  local _target_id="" _clone_basename="" _ctd="" _suffix="${GENVW_SUFFIX:-gENVW}"
  local _prov_label=""

  _target_id="$(genvw_wizard_selected_target_id 2>/dev/null || true)"
  [[ -n "$_target_id" ]] || return 0

  _clone_basename="$(genvw_wizard_selected_clone_basename "$_target_id" "$_suffix" 2>/dev/null || true)"
  [[ -n "$_clone_basename" ]] || return 0
  GENVW_WIZARD_SELECTED_CLONE_BASENAME="$_clone_basename"

  if [[ "$_prov" == "cachyos" && "${GENVW_DXVK_TARGET_ROOT:-}" == */"$_clone_basename" ]]; then
    return 0
  fi

  _ctd="$(genvw_wizard_selected_ctd 2>/dev/null || true)"
  [[ -n "$_ctd" ]] || return 0

  if [[ -d "$_ctd/$_clone_basename" ]]; then
    return 0
  fi

  case "$_prov" in
    cachyos)  _prov_label="CachyOS" ;;
    dwproton) _prov_label="DW-Proton" ;;
    *)        _prov_label="$_prov" ;;
  esac

  echo
  msg "This selected target is not installed as a gENVW compatibility tool yet."
  msg "Steam will not be able to use it until it is rebuilt."
  echo
  if ask_yes_no_default "${YELLOW}Rebuild this selected target now? [Y/n]: ${RESET}" "y"; then
    echo
    msg "Rebuilding selected target:"
    msg "  ${_prov_label} ${_target_id}"
    echo
    if run_proton rebuild --provider "$_prov" --target-id "$_target_id" >&2; then
      GENVW_WIZARD_DID_REBUILD=1
      echo
      msg "Rebuild complete. ${_clone_basename} is ready."
    else
      echo
      msg "Rebuild failed. The wizard will continue, but this selected target may not work in Steam."
      msg "Rebuild it later with:"
      msg "  genvw proton rebuild --provider ${_prov} --target-id ${_target_id}"
    fi
  else
    echo
    msg "Warning:"
    msg "  Launch options will still be printed, but this selected target"
    msg "  will not work in Steam until the matching gENVW compatibility tool exists."
    echo
    msg "Rebuild it later with:"
    msg "  genvw proton rebuild --provider ${_prov} --target-id ${_target_id}"
  fi
  echo
}

genvw_wizard_print_steam_compat_reminder() {
  local _clone_basename="${GENVW_WIZARD_SELECTED_CLONE_BASENAME:-}"
  local _display_name="$_clone_basename"
  local _ctd="" _vdf_name=""

  if [[ -n "$_clone_basename" ]]; then
    _ctd="$(genvw_wizard_selected_ctd 2>/dev/null || true)"
    if [[ -n "$_ctd" && -r "$_ctd/$_clone_basename/compatibilitytool.vdf" ]]; then
      _vdf_name="$(awk -F'"' '$2=="display_name"{print $4; exit}' \
        "$_ctd/$_clone_basename/compatibilitytool.vdf" 2>/dev/null || true)"
      [[ -n "$_vdf_name" ]] && _display_name="$_vdf_name"
    fi
  fi

  [[ -n "$_display_name" ]] || return 0

  echo
  printf "%s\n" "=== Steam compatibility tool ==="
  echo
  msg "Set this game in Steam to:"
  msg "  ${_display_name}"
  if [[ -n "$_clone_basename" && "$_display_name" != "$_clone_basename" ]]; then
    echo
    msg "Tool directory:"
    msg "  ${_clone_basename}"
  fi
  echo
  msg "Where:"
  msg "  Steam -> Game Properties -> Compatibility"
  msg '  Enable "Force the use of a specific Steam Play compatibility tool"'
  msg "  Select: ${_display_name}"
  echo
  msg "Reminder:"
  msg "  Launch options do not change the Steam compatibility tool."

  if [[ "${GENVW_WIZARD_DID_REBUILD:-0}" -eq 1 ]] && host_steam_is_running; then
    echo
    msg "Steam restart:"
    msg "  Steam was running during rebuild. Restart Steam so it re-scans compatibility tools."
  fi
}

genvw_wizard_hdr_env_label() {
  local visible="" profile="" names=""
  visible="$(genvw_wizard_selected_capability_bool01 HDR_OPTION_VISIBLE)"
  profile="$(genvw_wizard_selected_capability_get HDR_ENV_PROFILE 2>/dev/null || true)"
  names="$(genvw_wizard_selected_capability_get HDR_ENV_NAMES 2>/dev/null || true)"
  if [[ "$visible" == "1" && -n "$names" ]]; then
    case "$profile" in
      legacy-wayland-hdr | wayland-hdr-no-proton-enable-hdr | wayland-only-conservative)
        printf '%s\n' "${names//,/, }"
        return 0
        ;;
    esac
  fi
  genvw_hdr_env_label
}

genvw_wizard_selected_cachyos_dxvk_policy() {
  local policy="" env_name=""
  genvw_wizard_selected_capability_provider_is_cachyos || return 1
  policy="$(genvw_wizard_selected_capability_get DXVK_POLICY 2>/dev/null || true)"
  case "$policy" in
    legacy_gplall)
      [[ "$(genvw_wizard_selected_capability_bool01 DXVK_ASYNC_OPTION_VISIBLE)" == "1" ]] || return 1
      [[ "$(genvw_wizard_selected_capability_get DXVK_ASYNC_ENV_NAME 2>/dev/null || true)" == "PROTON_DXVK_GPLASYNC" ]] || return 1
      [[ "$(genvw_wizard_selected_capability_bool01 GPLASYNC_SUPPORTED)" == "1" ]] || return 1
      [[ "$(genvw_wizard_selected_capability_bool01 GPLALL_LEGACY)" == "1" ]] || return 1
      [[ "$(genvw_wizard_selected_capability_bool01 LOWLATENCY_DXVK_SUPPORTED)" == "1" ]] || return 1
      ;;
    split_envs)
      env_name="$(genvw_wizard_selected_capability_get DXVK_ASYNC_ENV_NAME 2>/dev/null || true)"
      [[ "$(genvw_wizard_selected_capability_bool01 DXVK_ASYNC_OPTION_VISIBLE)" == "1" ]] || return 1
      [[ "$env_name" == "PROTON_DXVK_GPLASYNC" ]] || return 1
      [[ "$(genvw_wizard_selected_capability_bool01 GPLASYNC_SUPPORTED)" == "1" ]] || return 1
      [[ "$(genvw_wizard_selected_capability_bool01 LOWLATENCY_DXVK_SUPPORTED)" == "1" ]] || return 1
      ;;
    lowlatency_only)
      [[ "$(genvw_wizard_selected_capability_bool01 LOWLATENCY_DXVK_SUPPORTED)" == "1" ]] || return 1
      ;;
    *)
      return 1
      ;;
  esac
  printf '%s\n' "$policy"
}

genvw_wizard_selected_dw_dxvk_policy() {
  local policy="" env_name=""
  genvw_wizard_selected_capability_provider_is_dwproton || return 1
  policy="$(genvw_wizard_selected_capability_get DXVK_POLICY 2>/dev/null || true)"
  case "$policy" in
    split_envs)
      env_name="$(genvw_wizard_selected_capability_get DXVK_ASYNC_ENV_NAME 2>/dev/null || true)"
      [[ "$(genvw_wizard_selected_capability_bool01 DXVK_ASYNC_OPTION_VISIBLE)" == "1" ]] || return 1
      [[ "$env_name" == "PROTON_DXVK_GPLASYNC" ]] || return 1
      [[ "$(genvw_wizard_selected_capability_bool01 GPLASYNC_SUPPORTED)" == "1" ]] || return 1
      [[ "$(genvw_wizard_selected_capability_bool01 LLASYNC_SUPPORTED)" == "1" ]] || return 1
      [[ "$(genvw_wizard_selected_capability_bool01 LOWLATENCY_DXVK_SUPPORTED)" == "1" ]] || return 1
      ;;
    *)
      return 1
      ;;
  esac
  printf '%s\n' "$policy"
}

genvw_wizard_selected_cachyos_ntsync_mode() {
  genvw_wizard_selected_capability_provider_is_cachyos || return 1
  genvw_wizard_selected_ntsync_mode
}

genvw_wizard_selected_ntsync_mode() {
  local default_state="" disable_env="" force_env=""
  { genvw_wizard_selected_capability_provider_is_cachyos || genvw_wizard_selected_capability_provider_is_dwproton; } || return 1
  [[ "$(genvw_wizard_selected_capability_bool01 NTSYNC_OPTION_VISIBLE)" == "1" ]] || return 1
  default_state="$(genvw_wizard_selected_capability_get NTSYNC_DEFAULT_STATE 2>/dev/null || true)"
  disable_env="$(genvw_wizard_selected_capability_get NTSYNC_DISABLE_ENV_NAME 2>/dev/null || true)"
  force_env="$(genvw_wizard_selected_capability_get NTSYNC_FORCE_ENV_NAME 2>/dev/null || true)"
  if [[ "$default_state" == "enabled" && "$disable_env" == "PROTON_NO_NTSYNC" && -z "$force_env" ]]; then
    printf '%s\n' "proton_no_ntsync"
    return 0
  fi
  if [[ "$default_state" == "enabled" && "$disable_env" == "PROTON_USE_NTSYNC" && "$force_env" == "PROTON_USE_NTSYNC" ]]; then
    printf '%s\n' "proton_use_ntsync_default"
    return 0
  fi
  printf '%s\n' "manual"
}

genvw_wizard_ntsync_default_intro_enabled() {
  if genvw_wizard_selected_capability_provider_is_dwproton; then
    echo "${BOLD}NTS:${RESET} NTSYNC is enabled by default for this selected DW-Proton runtime."
  else
    echo "${BOLD}NTS:${RESET} NTSYNC is enabled by default on this Proton-CachyOS build."
  fi
}

genvw_wizard_ntsync_default_intro_proton11() {
  if genvw_wizard_selected_capability_provider_is_dwproton; then
    echo "${BOLD}NTS:${RESET} NTSYNC is enabled by default for this selected DW-Proton runtime."
    echo "It can be disabled if needed."
  else
    echo "${BOLD}NTS:${RESET} NTSYNC is enabled by default on this Proton-CachyOS 11 build."
  fi
}

genvw_wizard_ntsync_deferred_intro() {
  echo "${BOLD}NTS:${RESET} No provider-specific NTSYNC control is exposed for this selected runtime."
}

genvw_wizard_load_source_targets() {
  local kv="" schema="" count="" idx=0
  GENVW_WIZARD_TARGET_PATHS=()
  GENVW_WIZARD_TARGET_KINDS=()
  GENVW_WIZARD_TARGET_BASES=()
  GENVW_WIZARD_TARGET_MAJORS=()
  GENVW_WIZARD_TARGET_DATES=()
  GENVW_WIZARD_TARGET_RUNTIMES=()
  GENVW_WIZARD_TARGET_ARCHES=()
  GENVW_WIZARD_TARGET_FAMILIES=()
  GENVW_WIZARD_TARGET_PROVENANCES=()
  GENVW_WIZARD_TARGET_POLICIES=()
  GENVW_WIZARD_TARGET_LABELS=()

  kv="$(run_proton_internal_sources_machine 2>/dev/null || true)"
  schema="$(genvw_kv_get_optional_unique "$kv" "SOURCES_SCHEMA" 2>/dev/null || true)"
  [[ "$schema" == "1" ]] || { genvw_wizard_load_dw_targets; return 0; }
  count="$(genvw_kv_get_optional_unique "$kv" "SOURCE_COUNT" 2>/dev/null || true)"
  [[ "$count" =~ ^[0-9]+$ ]] || { genvw_wizard_load_dw_targets; return 0; }
  for ((idx = 0; idx < count; idx++)); do
    genvw_wizard_add_target_from_sources_kv "$kv" "$idx"
  done
  genvw_wizard_load_dw_targets
}

genvw_wizard_add_explicit_target_root() {
  local root="${1:-}" base="" major="" date="" runtime="" arch="" family="" bucket="" label="" kind="source" suffix="gENVW" core=""
  [[ -d "$root" ]] || return 1
  base="${root##*/}"

  if [[ "$base" =~ ^proton-cachyos-([0-9]+([.][0-9]+)?)-([0-9]{8})-(native|slr)-(x86_64(_v[1-4])?|protonplus-unspecified|system-x86_64)-([A-Za-z0-9][A-Za-z0-9._-]*)$ ]]; then
    suffix="${BASH_REMATCH[7]}"
    if [[ "$suffix" != "gENVW" ]]; then
      return 1
    fi
    core="${base%-${suffix}}"
    major="${BASH_REMATCH[1]}"
    date="${BASH_REMATCH[3]}"
    runtime="${BASH_REMATCH[4]}"
    arch="${BASH_REMATCH[5]}"
    family="genvw-clone"
    kind="clone"
    base="$core"
  elif [[ "$base" =~ ^proton-cachyos-([0-9]+([.][0-9]+)?)-([0-9]{8})-(native|slr)-(x86_64(_v[1-4])?)$ ]]; then
    major="${BASH_REMATCH[1]}"
    date="${BASH_REMATCH[3]}"
    runtime="${BASH_REMATCH[4]}"
    arch="${BASH_REMATCH[5]}"
    family="protonup-qt"
  elif [[ "$base" =~ ^proton-cachyos-([0-9]+([.][0-9]+)?)-([0-9]{8})-(x86_64(_v[1-4])?)$ ]]; then
    major="${BASH_REMATCH[1]}"
    date="${BASH_REMATCH[3]}"
    runtime="${BASH_REMATCH[4]}"
    arch="${BASH_REMATCH[4]}"
    family="protonup-qt"
  elif [[ "$base" =~ ^cachyos-([0-9]+([.][0-9]+)?)-([0-9]{8})-(native|slr)$ ]]; then
    major="${BASH_REMATCH[1]}"
    date="${BASH_REMATCH[3]}"
    runtime="${BASH_REMATCH[4]}"
    arch="protonplus-unspecified"
    family="protonplus"
  else
    major="$(genvw_proton_source_major_from_root "$root" 2>/dev/null || true)"
    date="$(genvw_proton_source_build_date_from_root "$root" 2>/dev/null || true)"
    case "$base" in
      proton-cachyos-slr) runtime="slr" ;;
      proton-cachyos) runtime="native" ;;
      *) runtime="" ;;
    esac
    arch="system-x86_64"
    family="system-package"
  fi

  [[ "$major" =~ ^[0-9]+([.][0-9]+)?$ && "$date" =~ ^[0-9]{8}$ ]] || return 1
  bucket="$(genvw_wizard_target_policy_bucket "$major" "$date")"
  label="$(genvw_wizard_target_policy_label "$bucket")"

  GENVW_WIZARD_TARGET_PATHS+=("$root")
  GENVW_WIZARD_TARGET_KINDS+=("$kind")
  GENVW_WIZARD_TARGET_BASES+=("$base")
  GENVW_WIZARD_TARGET_MAJORS+=("$major")
  GENVW_WIZARD_TARGET_DATES+=("$date")
  GENVW_WIZARD_TARGET_RUNTIMES+=("$runtime")
  GENVW_WIZARD_TARGET_ARCHES+=("$arch")
  GENVW_WIZARD_TARGET_FAMILIES+=("$family")
  GENVW_WIZARD_TARGET_PROVENANCES+=("explicit")
  GENVW_WIZARD_TARGET_POLICIES+=("$bucket")
  GENVW_WIZARD_TARGET_LABELS+=("$label")
}

genvw_wizard_target_group_key() {
  local idx="${1:-}" major="" date="" runtime="" arch=""
  major="${GENVW_WIZARD_TARGET_MAJORS[$idx]:-}"
  date="${GENVW_WIZARD_TARGET_DATES[$idx]:-}"
  runtime="${GENVW_WIZARD_TARGET_RUNTIMES[$idx]:-}"
  arch="$(genvw_wizard_target_arch_for_group "${GENVW_WIZARD_TARGET_ARCHES[$idx]:-}")"
  printf '%s|%s|%s|%s\n' "$major" "$date" "$runtime" "$arch"
}

genvw_wizard_target_representative_score() {
  local idx="${1:-}" policy_rank="" runtime_rank="" source_rank=""
  policy_rank="$(genvw_wizard_target_policy_rank "${GENVW_WIZARD_TARGET_POLICIES[$idx]:-}")"
  runtime_rank="$(genvw_wizard_target_runtime_rank "$idx")"
  source_rank="$(genvw_wizard_target_source_rank "$idx")"
  printf '%s%02d%02d%02d\n' "${GENVW_WIZARD_TARGET_DATES[$idx]:-00000000}" "$policy_rank" "$runtime_rank" "$source_rank"
}

genvw_wizard_grouped_target_indices() {
  local idx="" key="" score="" old_score="" line="" bucket="" rank="" date="" runtime_rank="" source_rank="" base="" matching_clone=0
  local include_unsupported="${1:-0}"
  local include_matching_clones="${2:-1}"
  local -A best_idx_by_key=()
  local -A best_score_by_key=()
  local -a rows=()

  for idx in "${!GENVW_WIZARD_TARGET_PATHS[@]}"; do
    bucket="${GENVW_WIZARD_TARGET_POLICIES[$idx]:-future_unknown}"
    if ! genvw_wizard_target_is_known_policy "$bucket" && [[ "$include_unsupported" != "1" ]]; then
      continue
    fi
    matching_clone=0
    if genvw_wizard_clone_matches_source_target "$idx"; then
      matching_clone=1
    fi
    if [[ "$include_matching_clones" != "1" && "$matching_clone" == "1" ]]; then
      continue
    fi
    key="$(genvw_wizard_target_group_key "$idx")"
    if [[ "$include_matching_clones" == "1" && "$matching_clone" == "1" ]]; then
      key="${key}|clone|${idx}"
    fi
    score="$(genvw_wizard_target_representative_score "$idx")"
    old_score="${best_score_by_key[$key]:-}"
    if [[ -z "$old_score" || "$score" > "$old_score" ]]; then
      best_score_by_key[$key]="$score"
      best_idx_by_key[$key]="$idx"
    fi
  done

  for key in "${!best_idx_by_key[@]}"; do
    idx="${best_idx_by_key[$key]}"
    bucket="${GENVW_WIZARD_TARGET_POLICIES[$idx]:-future_unknown}"
    rank="$(genvw_wizard_target_policy_rank "$bucket")"
    runtime_rank="$(genvw_wizard_target_runtime_rank "$idx")"
    source_rank="$(genvw_wizard_target_source_rank "$idx")"
    date="${GENVW_WIZARD_TARGET_DATES[$idx]:-00000000}"
    base="${GENVW_WIZARD_TARGET_BASES[$idx]:-${GENVW_WIZARD_TARGET_PATHS[$idx]##*/}}"
    rows+=("${date}|${rank}|${runtime_rank}|${source_rank}|${base}|${idx}")
  done
  ((${#rows[@]} == 0)) && return 0
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    printf '%s\n' "${line##*|}"
  done < <(printf '%s\n' "${rows[@]}" | sort -t '|' -k1,1r -k2,2nr -k3,3nr -k4,4nr -k5,5)
}

genvw_wizard_default_from_indices() {
  local idx="" bucket="" date="" best_idx="" best_date=""

  for idx in "$@"; do
    bucket="${GENVW_WIZARD_TARGET_POLICIES[$idx]:-}"
    date="${GENVW_WIZARD_TARGET_DATES[$idx]:-}"
    [[ "$bucket" == "policy_known_capability_gated" ]] || continue
    if [[ -z "$best_idx" || "$date" > "$best_date" ]]; then
      best_idx="$idx"
      best_date="$date"
    fi
  done
  if [[ -n "$best_idx" ]]; then
    printf '%s\n' "$best_idx"
    return 0
  fi

  best_idx=""
  best_date=""
  for idx in "$@"; do
    bucket="${GENVW_WIZARD_TARGET_POLICIES[$idx]:-}"
    date="${GENVW_WIZARD_TARGET_DATES[$idx]:-}"
    [[ "$bucket" == "stable_practical" ]] || continue
    if [[ -z "$best_idx" || "$date" > "$best_date" ]]; then
      best_idx="$idx"
      best_date="$date"
    fi
  done
  [[ -n "$best_idx" ]] && printf '%s\n' "$best_idx"
}

genvw_wizard_print_selected_target() {
  local idx="${1:-}" label="" display="" kind="" prefix=""
  display="$(genvw_wizard_target_display "$idx")"
  kind="${GENVW_WIZARD_TARGET_KINDS[$idx]:-source}"
  if [[ "$kind" == "clone" ]]; then
    prefix="Selected gENVW Proton tool:"
    label="existing tool"
  else
    prefix="Selected Proton-CachyOS target:"
    label="$(genvw_wizard_target_status_label "$idx")"
  fi
  printf "%s\n" "${CYAN}${prefix} ${display} (${label})${RESET}"
}

genvw_wizard_press_enter_to_exit() {
  local _unused=""
  printf "%s" "${YELLOW}Press Enter to exit.${RESET}"
  tty_read _unused || true
  echo
}

genvw_wizard_exit_no_usable_target() {
  local ver=""
  ver="$(genvw_fsr4_effective_local_default_ver 2>/dev/null || true)"
  [[ -n "$ver" ]] || ver="<version>"

  cat <<EOF
No usable Proton-CachyOS source or gENVW Proton tool was found.

gENVW cannot generate reliable launch options because there is no Proton-CachyOS target to match.

To use gENVW:
  1. Install Proton-CachyOS with ProtonUp-Qt or ProtonPlus.
  2. Install or verify the trusted FSR4 DLL:
     genvw proton dll install --ver ${ver}
     genvw proton dll verify
  3. Build patched gENVW Proton tools:
     genvw proton rebuild
  4. Restart Steam and rerun genvw.

EOF
  genvw_wizard_press_enter_to_exit
  exit 0
}

genvw_wizard_exit_future_only() {
  local idx="" display=""
  cat <<'EOF'
Only future or unsupported Proton-CachyOS targets were found.

gENVW cannot generate reliable launch options for these targets until their release policy is reviewed:
EOF
  for idx in "${!GENVW_WIZARD_TARGET_PATHS[@]}"; do
    display="$(genvw_wizard_target_display "$idx")"
    printf '  - %s\n' "$display"
  done
  cat <<'EOF'

Install a supported Proton-CachyOS 10.x/11.x target or wait for a future gENVW policy update.

EOF
  genvw_wizard_press_enter_to_exit
  exit 0
}

genvw_wizard_cachyos_features_for_date() {
  local date="${1:-}"
  local -a out=("FSR4")
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
  local feat_str="" label=""
  for label in "${out[@]}"; do
    [[ -z "$feat_str" ]] && feat_str="$label" || feat_str="${feat_str}, ${label}"
  done
  printf '%s\n' "$feat_str"
}

genvw_wizard_print_target_menu() {
  local indices_name="${1:-}" default_idx="${2:-}" default_pos_name="${3:-}" idx=""
  local version="" runtime="" arch="" source_label="" status_label="" features="" default_mark="" menu_pos=1
  local -n indices_ref="$indices_name"
  local -n default_pos_ref="$default_pos_name"

  default_pos_ref=1
  printf '  %-2s %-13s %-7s %-11s %-11s %-10s %s\n' "#" "VERSION" "RUNTIME" "ARCH" "SOURCE" "GENVW" "FEATURES"
  for idx in "${indices_ref[@]}"; do
    version="${GENVW_WIZARD_TARGET_MAJORS[$idx]:-}-${GENVW_WIZARD_TARGET_DATES[$idx]:-}"
    runtime="${GENVW_WIZARD_TARGET_RUNTIMES[$idx]:-}"
    arch="$(genvw_wizard_target_arch_for_display "${GENVW_WIZARD_TARGET_ARCHES[$idx]:-}")"
    source_label="$(genvw_wizard_target_source_label "$idx")"
    status_label="$(genvw_wizard_target_status_label "$idx")"
    features="$(genvw_wizard_cachyos_features_for_date "${GENVW_WIZARD_TARGET_DATES[$idx]:-}")"
    features="$(compact_feature_labels_for_human "$features")"
    default_mark=""
    if [[ "$idx" == "$default_idx" ]]; then
      default_pos_ref="$menu_pos"
      default_mark="  [default]"
    fi
    printf '  %-2s %-13s %-7s %-11s %-11s %-10s %s%s\n' "$menu_pos" "$version" "$runtime" "$arch" "$source_label" "$status_label" "$features" "$default_mark"
    menu_pos=$((menu_pos + 1))
  done
}

genvw_wizard_target_launch_identity() {
  local idx="${1:-}" kind="" family="" provenance="" major="" date="" runtime="" arch="" base="" clone_basename=""
  kind="${GENVW_WIZARD_TARGET_KINDS[$idx]:-source}"
  family="${GENVW_WIZARD_TARGET_FAMILIES[$idx]:-}"
  provenance="${GENVW_WIZARD_TARGET_PROVENANCES[$idx]:-}"
  major="${GENVW_WIZARD_TARGET_MAJORS[$idx]:-}"
  date="${GENVW_WIZARD_TARGET_DATES[$idx]:-}"
  runtime="${GENVW_WIZARD_TARGET_RUNTIMES[$idx]:-}"
  arch="${GENVW_WIZARD_TARGET_ARCHES[$idx]:-}"
  base="${GENVW_WIZARD_TARGET_BASES[$idx]:-${GENVW_WIZARD_TARGET_PATHS[$idx]##*/}}"
  if [[ "$kind" == "clone" ]]; then
    clone_basename="${GENVW_WIZARD_TARGET_PATHS[$idx]##*/}"
  else
    clone_basename="$(genvw_wizard_target_clone_basename "$idx" 2>/dev/null || true)"
  fi
  printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
    "cachyos" "$kind" "$family" "$provenance" "$major" "$date" "$runtime" "$arch" "$base" "$clone_basename"
}

genvw_wizard_print_dw_menu_rows() {
  local start_pos="${1:-1}" indices_name="${2:-}"
  local menu_pos="$start_pos" dw_idx="" version="" base_label="" runtime="" arch="" status="" features=""
  local -n indices_ref="$indices_name"
  ((${#indices_ref[@]} > 0)) || return 0
  echo
  echo "  DW-Proton:"
  printf '  %-2s %-8s %-15s %-10s %-10s %s\n' "#" "VERSION" "BASE" "ARCH" "GENVW" "FEATURES"
  for dw_idx in "${indices_ref[@]}"; do
    version="${GENVW_WIZARD_DW_TARGET_VERSIONS[$dw_idx]:-}"
    base_label="${GENVW_WIZARD_DW_TARGET_BASE_LABELS[$dw_idx]:-}"
    runtime="${GENVW_WIZARD_DW_TARGET_RUNTIMES[$dw_idx]:-}"
    arch="${GENVW_WIZARD_DW_TARGET_ARCHES[$dw_idx]:-}"
    status="${GENVW_WIZARD_DW_TARGET_STATUSES[$dw_idx]:-supported}"
    features="${GENVW_WIZARD_DW_TARGET_FEATURES[$dw_idx]:-FSR4}"
    features="$(genvw_dw_align_split_env_feature_labels "$version" "$base_label" "$runtime" "$status" "$features")"
    features="$(compact_feature_labels_for_human "$features")"
    printf '  %-2s %-8s %-15s %-10s %-10s %s\n' "$menu_pos" "$version" "$base_label" "$arch" "$status" "$features"
    menu_pos=$((menu_pos + 1))
  done
}

genvw_wizard_collect_installed_cachyos_indices() {
  local idx="" status_label="" bucket="" launch_identity="" line="" matching_clone=0
  local -A seen_identity=()
  local -a rows=()

  for idx in "${!GENVW_WIZARD_TARGET_PATHS[@]}"; do
    bucket="${GENVW_WIZARD_TARGET_POLICIES[$idx]:-future_unknown}"
    if ! genvw_wizard_target_is_known_policy "$bucket"; then
      continue
    fi
    matching_clone=0
    if genvw_wizard_clone_matches_source_target "$idx"; then
      matching_clone=1
    fi
    if [[ "$matching_clone" == "1" ]]; then
      continue
    fi
    status_label="$(genvw_wizard_target_status_label "$idx")"
    [[ "$status_label" == "installed" ]] || continue
    launch_identity="$(genvw_wizard_target_launch_identity "$idx")"
    [[ -n "$launch_identity" ]] || continue
    [[ -n "${seen_identity[$launch_identity]:-}" ]] && continue
    seen_identity[$launch_identity]="$idx"
    rows+=("${GENVW_WIZARD_TARGET_DATES[$idx]:-00000000}|$(genvw_wizard_target_policy_rank "$bucket")|$(genvw_wizard_target_runtime_rank "$idx")|$(genvw_wizard_target_source_rank "$idx")|${GENVW_WIZARD_TARGET_BASES[$idx]:-${GENVW_WIZARD_TARGET_PATHS[$idx]##*/}}|${idx}")
  done
  ((${#rows[@]} == 0)) && return 0
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    printf '%s\n' "${line##*|}"
  done < <(printf '%s\n' "${rows[@]}" | sort -t '|' -k1,1r -k2,2nr -k3,3nr -k4,4nr -k5,5)
}

genvw_wizard_collect_installed_dw_indices() {
  local dw_idx=0 total_dw=0
  total_dw="${#GENVW_WIZARD_DW_TARGET_BASES[@]}"
  for ((dw_idx = total_dw - 1; dw_idx >= 0; dw_idx--)); do
    [[ "${GENVW_WIZARD_DW_TARGET_STATUSES[$dw_idx]:-supported}" == "installed" ]] || continue
    printf '%s\n' "$dw_idx"
  done
}

genvw_wizard_rebuildable_target_count() {
  local helper="${1:-}" note=""
  local -a cachyos_rows=() dw_rows=()

  [[ -n "$helper" && -f "$helper" ]] || {
    printf '%s\n' 0
    return 0
  }
  genvw_rebuild_picker_collect_cachyos_rows "$helper" cachyos_rows
  genvw_rebuild_picker_collect_dw_rows "$helper" dw_rows note
  printf '%s\n' "$(( ${#cachyos_rows[@]} + ${#dw_rows[@]} ))"
}

genvw_wizard_print_inventory_legend() {
  echo "GENVW:"
  echo "  installed  a launch-selectable patched gENVW compatibility tool already exists for this row."
  echo "  supported  this row is rebuildable, but no launch-selectable patched gENVW compatibility tool exists yet."
  echo "  available  this row is known, but not rebuildable/selectable here."
}

genvw_wizard_show_inventory() {
  echo
  echo "Full Proton inventory:"
  echo
  genvw_wizard_print_inventory_legend
  echo
  run_proton sources
  echo
  echo "Press Enter to return to the menu..."
  local ret=""
  tty_read ret || true
  echo
}

genvw_wizard_build_on_demand() {
  local helper="${1:-}"
  local -a cmd=()

  [[ -n "$helper" && -f "$helper" ]] || return 1
  echo
  if ! genvw_rebuild_picker_choose_command "$helper" "wizard" cmd; then
    echo
    return 1
  fi
  echo
  if host_steam_is_running; then
    msg "Steam is running. Close Steam before rebuilding Proton tools, then try again."
    echo
    return 1
  fi
  if run_proton "${cmd[@]}" >&2; then
    GENVW_WIZARD_DID_REBUILD=1
    echo
    msg "Rebuild complete. Refreshing installed launch targets."
    echo
    return 0
  fi
  echo
  msg "Rebuild failed. Returning to launch target selection."
  echo
  return 1
}

genvw_wizard_select_proton_target() {
  local explicit_root="${GENVW_PROTON_TOOL_ROOT:-}" idx="" found_idx="" default_idx="" known_count=0
  local bucket="" choice="" choice_num=0 selected_idx="" target_count=0 dw_count=0 dw_idx=0 default_pos=1
  local installed_total=0 rebuildable_total=0 max_choice=0 default_choice="1" default_is_dw=0 helper=""
  local -a installed_cachyos_indices=()
  local -a installed_dw_indices=()

  if [[ -n "$explicit_root" && ! -d "$explicit_root" ]]; then
    printf "%s\n" "${YELLOW}Proton-CachyOS target override not found; using discovered target if available.${RESET}"
  fi

  genvw_wizard_load_source_targets
  target_count="${#GENVW_WIZARD_TARGET_PATHS[@]}"
  dw_count="${#GENVW_WIZARD_DW_TARGET_BASES[@]}"

  if [[ -n "$explicit_root" && -d "$explicit_root" ]]; then
    for idx in "${!GENVW_WIZARD_TARGET_PATHS[@]}"; do
      if [[ "${GENVW_WIZARD_TARGET_PATHS[$idx]}" == "$explicit_root" ]]; then
        found_idx="$idx"
        break
      fi
    done
    if [[ -z "$found_idx" ]] && genvw_wizard_add_explicit_target_root "$explicit_root"; then
      found_idx="$((${#GENVW_WIZARD_TARGET_PATHS[@]} - 1))"
      target_count="${#GENVW_WIZARD_TARGET_PATHS[@]}"
    fi
    if [[ -n "$found_idx" ]]; then
      if [[ "${GENVW_WIZARD_TARGET_POLICIES[$found_idx]:-}" == "future_unknown" ]]; then
        genvw_wizard_exit_future_only
      fi
      genvw_wizard_apply_known_target "$found_idx"
      genvw_wizard_print_selected_target "$found_idx"
      echo
      return 0
    fi
  fi

  if ((target_count == 0 && dw_count == 0)); then
    genvw_wizard_apply_conservative_target "wizard_target_none"
    genvw_wizard_exit_no_usable_target
  fi

  for idx in "${!GENVW_WIZARD_TARGET_PATHS[@]}"; do
    bucket="${GENVW_WIZARD_TARGET_POLICIES[$idx]:-}"
    if genvw_wizard_target_is_known_policy "$bucket"; then
      known_count=$((known_count + 1))
    fi
  done

  if ((known_count == 0 && dw_count == 0)); then
    genvw_wizard_apply_conservative_target "wizard_target_future_only"
    genvw_wizard_exit_future_only
  fi

  helper="$(proton_helper_path 1 2>/dev/null || true)"
  rebuildable_total="$(genvw_wizard_rebuildable_target_count "$helper" 2>/dev/null || printf '%s' 0)"
  [[ "$rebuildable_total" =~ ^[0-9]+$ ]] || rebuildable_total=0

  mapfile -t installed_cachyos_indices < <(genvw_wizard_collect_installed_cachyos_indices)
  mapfile -t installed_dw_indices < <(genvw_wizard_collect_installed_dw_indices)
  installed_total="$(( ${#installed_cachyos_indices[@]} + ${#installed_dw_indices[@]} ))"

  if ((installed_total == 0 && rebuildable_total == 0)); then
    while :; do
      echo "Launch-selectable Proton targets:"
      echo
      echo "  No installed gENVW Proton tools are available yet."
      echo
      echo "No rebuildable provider targets are available here."
      echo "Manual inventory:"
      echo "  genvw proton sources"
      echo "  genvw proton rebuild"
      echo
      echo "Options:"
      echo "  i    Show full inventory"
      echo "  0    Exit"
      echo
      printf "%s" "${YELLOW}Choose option [0/i]: ${RESET}"
      tty_read choice || choice="0"
      choice="$(trim "$choice")"
      echo
      case "$choice" in
        i | I)
          genvw_wizard_show_inventory
          ;;
        0 | "")
          printf "%s\n" "${CYAN}Exited target selection.${RESET}"
          exit 0
          ;;
        *)
          printf "%s\n\n" "${RED}Enter 0 or i.${RESET}"
          ;;
      esac
    done
  fi

  if ((${#installed_cachyos_indices[@]} > 0)); then
    default_idx="$(genvw_wizard_default_from_indices "${installed_cachyos_indices[@]}")"
  else
    default_idx=""
  fi
  if [[ -z "$default_idx" && ${#installed_dw_indices[@]} -gt 0 ]]; then
    default_idx="${installed_dw_indices[0]}"
    default_is_dw=1
  else
    default_is_dw=0
  fi

  if ((installed_total == 1 && rebuildable_total <= installed_total)) && [[ -n "$default_idx" ]]; then
    if ((default_is_dw == 1)); then
      genvw_wizard_apply_dw_target "$default_idx"
    else
      genvw_wizard_apply_known_target "$default_idx"
      genvw_wizard_print_selected_target "$default_idx"
    fi
    echo
    return 0
  fi

  while :; do
    if ((installed_total > 0)); then
      default_pos=1
      if ((default_is_dw == 1)); then
        default_pos=$(( ${#installed_cachyos_indices[@]} + 1 ))
      fi
      echo "Launch-selectable Proton targets:"
      echo "This picker lists installed gENVW compatibility tools that Steam can use now."
      if ((${#installed_cachyos_indices[@]} > 0)); then
        if ((${#installed_dw_indices[@]} > 0)); then
          echo
          echo "  CachyOS Proton:"
        fi
        echo
        genvw_wizard_print_target_menu installed_cachyos_indices "$default_idx" default_pos
      fi
      if ((${#installed_dw_indices[@]} > 0)); then
        genvw_wizard_print_dw_menu_rows $(( ${#installed_cachyos_indices[@]} + 1 )) installed_dw_indices
      fi
      echo
      echo "Options:"
      echo "  1-N  Select installed launch target"
      echo "  b    Build another target"
      echo "  i    Show full inventory"
      echo "  0    Exit"
      echo
      max_choice="$installed_total"
      printf "%s" "${YELLOW}Choose target or option [0-${max_choice}/b/i, default=${default_pos}]: ${RESET}"
      tty_read choice || choice="0"
      choice="$(trim "$choice")"
      [[ -n "$choice" ]] || choice="$default_pos"
      echo
      case "$choice" in
        b | B)
          if genvw_wizard_build_on_demand "$helper"; then
            genvw_wizard_load_source_targets
            mapfile -t installed_cachyos_indices < <(genvw_wizard_collect_installed_cachyos_indices)
            mapfile -t installed_dw_indices < <(genvw_wizard_collect_installed_dw_indices)
            installed_total="$(( ${#installed_cachyos_indices[@]} + ${#installed_dw_indices[@]} ))"
            if ((${#installed_cachyos_indices[@]} > 0)); then
              default_idx="$(genvw_wizard_default_from_indices "${installed_cachyos_indices[@]}")"
            else
              default_idx=""
            fi
            if [[ -z "$default_idx" && ${#installed_dw_indices[@]} -gt 0 ]]; then
              default_idx="${installed_dw_indices[0]}"
              default_is_dw=1
            else
              default_is_dw=0
            fi
          fi
          continue
          ;;
        i | I)
          genvw_wizard_show_inventory
          continue
          ;;
        0)
          printf "%s\n" "${CYAN}Exited target selection.${RESET}"
          exit 0
          ;;
        '' | *[!0-9]*)
          printf "%s\n\n" "${RED}Enter a number from 0 to ${max_choice}, or b/i.${RESET}"
          continue
          ;;
        *)
          choice_num=$((10#$choice))
          if ((choice_num < 1 || choice_num > installed_total)); then
            printf "%s\n\n" "${RED}Enter a number from 0 to ${max_choice}, or b/i.${RESET}"
            continue
          fi
          if ((choice_num <= ${#installed_cachyos_indices[@]} )); then
            selected_idx="${installed_cachyos_indices[$((choice_num - 1))]}"
            genvw_wizard_apply_known_target "$selected_idx"
            genvw_wizard_print_selected_target "$selected_idx"
            echo
            return 0
          fi
          dw_idx="${installed_dw_indices[$((choice_num - ${#installed_cachyos_indices[@]} - 1))]}"
          genvw_wizard_apply_dw_target "$dw_idx"
          echo
          return 0
          ;;
      esac
    fi

    echo "Launch-selectable Proton targets:"
    echo
    echo "  No installed gENVW Proton tools are available yet."
    echo
    echo "Rebuildable targets are available."
    echo "  1) Build a gENVW Proton tool now"
    echo "  i) Show full inventory"
    echo "  0) Exit"
    echo
    printf "%s" "${YELLOW}Choose option [0-1/i, default=1]: ${RESET}"
    tty_read choice || choice="0"
    choice="$(trim "$choice")"
    [[ -n "$choice" ]] || choice="1"
    echo
    case "$choice" in
      1)
        if genvw_wizard_build_on_demand "$helper"; then
          genvw_wizard_load_source_targets
          mapfile -t installed_cachyos_indices < <(genvw_wizard_collect_installed_cachyos_indices)
          mapfile -t installed_dw_indices < <(genvw_wizard_collect_installed_dw_indices)
          installed_total="$(( ${#installed_cachyos_indices[@]} + ${#installed_dw_indices[@]} ))"
          if ((${#installed_cachyos_indices[@]} > 0)); then
            default_idx="$(genvw_wizard_default_from_indices "${installed_cachyos_indices[@]}")"
          else
            default_idx=""
          fi
          if [[ -z "$default_idx" && ${#installed_dw_indices[@]} -gt 0 ]]; then
            default_idx="${installed_dw_indices[0]}"
            default_is_dw=1
          else
            default_is_dw=0
          fi
        fi
        continue
        ;;
      i | I)
        genvw_wizard_show_inventory
        continue
        ;;
      0)
        printf "%s\n" "${CYAN}Exited target selection.${RESET}"
        exit 0
        ;;
      *)
        printf "%s\n\n" "${RED}Enter 0, 1, or i.${RESET}"
        ;;
    esac
  done
}

pick_fsr4_local_only_common() {
  # prints one token to stdout: <want_ver> | <fallback_ver> | 0 | ABORT
  # used via command substitution; keep everything except the final token on stderr
  local want_ver="${1:-}"
  local gpu_label="${2:-GPU}"
  local risk_line="${3:-Expect unpredictable behavior in some titles (freezes/crashes/weird textures).}"
  local fallback_ver="${4:-$(genvw_fsr4_default_remote_for_gen 0)}"
  local disable_label="${5:-$gpu_label}"

  [[ -n "$want_ver" ]] || {
    printf '%s' "$fallback_ver"
    return 0
  }

  LOCAL_DLL_FSR4="$(genvw_fsr4_local_dll_path "$want_ver")"

  echo "${YELLOW}${I_WARN} FSR4 ${want_ver} selected on ${gpu_label} (limited).${RESET}" >&2
  echo "  ${risk_line}" >&2
  echo "  Recommended helper cache path:" >&2
  echo "    $LOCAL_DLL_FSR4" >&2

  # missing dll: offer install, fall back, disable, or abort
  if [ ! -f "$LOCAL_DLL_FSR4" ]; then
    echo "${RED}${I_ERR} Recommended helper cache entry is missing (FSR4 ${want_ver}).${RESET}" >&2
    echo "${I_GO} Fix options:" >&2
    echo "  1) Install trusted version now (one-time)" >&2
    echo "     [genvw proton dll install --ver \"$want_ver\"]" >&2
    echo "  2) Use FSR4 ${fallback_ver} instead (safer on ${disable_label})" >&2
    echo "  3) Disable FSR4 for ${disable_label}" >&2
    echo "  4) Abort" >&2
    local choice=""
    printf "Choose [1-4]: " >&2
    tty_read choice || choice=""
    case "$choice" in
      1)
        if ! run_proton dll install --ver "$want_ver" >&2; then
          echo "${YELLOW}${I_WARN} DLL install failed → falling back to FSR4 ${fallback_ver}.${RESET}" >&2
          printf '%s' "$fallback_ver"
          return 0
        fi
        ;;
      2)
        echo "${YELLOW}${I_INFO} Using FSR4 ${fallback_ver} because local ${want_ver} DLL is not installed.${RESET}" >&2
        printf '%s' "$fallback_ver"
        return 0
        ;;
      3)
        echo "${YELLOW}${I_INFO} Disabling FSR4 (${disable_label}).${RESET}" >&2
        printf '0'
        return 0
        ;;
      4)
        echo "${YELLOW}Aborting.${RESET}" >&2
        printf 'ABORT'
        return 0
        ;;
      *)
        echo "${YELLOW}Unexpected selection; falling back to FSR4 ${fallback_ver}.${RESET}" >&2
        printf '%s' "$fallback_ver"
        return 0
        ;;
    esac
  fi

  # tools check: local-only versions need gENVW proton mapping in place
  local status_out kv ctd_exists tools_found kv_reason
  status_out="$(run_proton status 2>&1)"
  genvw_exit_on_signal_rc $?
  kv="$(run_proton_internal_check_kv 2>/dev/null || true)"
  if ! genvw_parse_tool_state_kv "$kv" ctd_exists tools_found kv_reason; then
    GENVW_SKIP_AUTO_TOOLS_PROMPTS=1
    genvw_warn_untrusted_tool_state_kv "$kv_reason"
  fi
  if [ "${ctd_exists:-0}" != "1" ] || [ "${tools_found:-0}" -lt 1 ]; then
    if [ "${GENVW_SKIP_AUTO_TOOLS_PROMPTS:-0}" = "1" ]; then
      echo "${YELLOW}${I_WARN} Skipping automatic tool-build prompt (preflight data not trusted); falling back to FSR4 ${fallback_ver}.${RESET}" >&2
      printf '%s' "$fallback_ver"
      return 0
    fi
    echo "${YELLOW}${I_WARN} gENVW Proton tools are missing.${RESET}" >&2
    echo "   FSR4 ${want_ver} requires patched Proton tools so the version maps to the canonical cached DLL." >&2
    if genvw_offer_build_tools "gENVW Proton tools are missing (required for FSR4 ${want_ver} mapping)."; then
      export GENVW_TOOLS_BUILT_THIS_RUN=1
      echo "${YELLOW}${I_INFO} Restart Steam to re-scan compatibility tools (Steam scans at startup).${RESET}" >&2
    else
      echo "${YELLOW}${I_WARN} Tools are missing → falling back to FSR4 ${fallback_ver}.${RESET}" >&2
      printf '%s' "$fallback_ver"
      return 0
    fi
  fi

  printf '%s' "$want_ver"
}

pick_rdna3_fsr4_local_only() {
  local want_ver="${1:-$(genvw_fsr4_effective_local_default_ver)}"
  pick_fsr4_local_only_common \
    "$want_ver" \
    "RDNA3/3.5" \
    "Expect unpredictable behavior in some titles (freezes/crashes/weird textures)." \
    "$(genvw_fsr4_default_remote_for_gen 3)" \
    "RDNA3/3.5"
}

pick_rdna2_fsr4_local_only() {
  local want_ver="${1:-$(genvw_fsr4_effective_local_default_ver)}"
  pick_fsr4_local_only_common \
    "$want_ver" \
    "RDNA2" \
    "Can show buggy behavior in some titles (freezes/crashes/weird textures)." \
    "$(genvw_fsr4_default_remote_for_gen 2)" \
    "RDNA2"
}

pick_rdna4_fsr4() {
  local want_ver="${1:-$(genvw_fsr4_effective_local_default_ver)}"
  pick_fsr4_local_only_common \
    "$want_ver" \
    "RDNA4" \
    "Expect unpredictable behavior in some titles (freezes/crashes/weird textures)." \
    "$(genvw_fsr4_default_remote_for_gen 4)" \
    "RDNA4"
}

genvw_wizard_fsr4_mark_active_route() {
  local route_style="${1:-}"
  case "$route_style" in
    rdna3) FSR4_RDNA3_USED=1 ;;
  esac
}

genvw_wizard_fsr4_set_value() {
  local value="${1:-}" route_style="${2:-}"
  [[ -n "$value" ]] || return 0
  LAUNCH_ENV="$LAUNCH_ENV FSR4=$value"
  GENVW_WIZARD_FSR4_SELECTION_KIND=""
  GENVW_WIZARD_FSR4_SELECTION_VERSION=""
  case "$value" in
    1)
      GENVW_WIZARD_FSR4_SELECTION_KIND="auto"
      ;;
    *)
      if genvw_fsr4_is_knob_allowed "$value"; then
        GENVW_WIZARD_FSR4_SELECTION_KIND="exact"
        GENVW_WIZARD_FSR4_SELECTION_VERSION="$value"
      fi
      ;;
  esac
  genvw_wizard_fsr4_mark_active_route "$route_style"
}

genvw_wizard_fsr4_auto_default_for_target() {
  local gen="${1:-0}" provider="" cap_ver=""
  provider="$(genvw_wizard_selected_capability_get PROVIDER 2>/dev/null || true)"
  cap_ver="$(genvw_wizard_selected_capability_get FSR4_DEFAULT_REMOTE 2>/dev/null || true)"

  if [[ "$provider" == "dwproton" ]] && genvw_fsr4_is_knob_allowed "$cap_ver"; then
    printf '%s\n' "$cap_ver"
    return 0
  fi

  if [[ "$provider" == "cachyos" ]]; then
    genvw_fsr4_upstream_auto_default_for_gen "$gen"
    return 0
  fi

  genvw_fsr4_default_remote_for_gen "$gen"
}

genvw_wizard_fsr4_target_label() {
  local provider="" label="" version="" arch=""
  provider="$(genvw_wizard_selected_capability_get PROVIDER 2>/dev/null || true)"
  case "$provider" in
    cachyos)
      label="$(genvw_wizard_selected_capability_get BASE_LABEL 2>/dev/null || true)"
      ;;
    dwproton)
      version="$(genvw_wizard_selected_capability_get VERSION 2>/dev/null || true)"
      arch="$(genvw_wizard_selected_capability_get ARCH 2>/dev/null || true)"
      if [[ -n "$version" ]]; then
        label="DW-Proton ${version}"
        [[ -n "$arch" && "$arch" != "unknown" ]] && label+=" ${arch}"
      fi
      ;;
  esac
  [[ -n "$label" ]] || label="selected Proton target"
  printf '%s\n' "$label"
}

genvw_wizard_fsr4_row_status() {
  local ver="${1:-}" path=""
  path="$(genvw_fsr4_local_dll_path "$ver")"
  if [[ -f "$path" ]]; then
    printf '%s\n' "installed"
  else
    printf '%s\n' "missing"
  fi
}

GENVW_WIZARD_FSR4_TABLE_VERSIONS=()

genvw_wizard_fsr4_parse_allowed_csv_into_array() {
  local raw="${1:-}" t="" v=""
  local -n out_ref="$2"
  local -a toks=()
  declare -A seen=()
  out_ref=()
  [[ -n "$raw" ]] || return 1
  [[ "$raw" != *, && "$raw" != ,* && "$raw" != *",,"* ]] || return 1
  IFS=',' read -r -a toks <<<"$raw"
  ((${#toks[@]} > 0)) || return 1
  for t in "${toks[@]}"; do
    v="$(genvw_trim_space_edges "$t")"
    [[ -n "$v" ]] || return 1
    genvw_fsr4_is_knob_allowed "$v" || return 1
    [[ -z "${seen[$v]+x}" ]] || return 1
    seen["$v"]=1
    out_ref+=("$v")
  done
}

genvw_wizard_fsr4_prepare_table_versions() {
  # Provider capability controls availability/default/route behavior.
  # Local table breadth stays on canonical local-only policy.
  GENVW_WIZARD_FSR4_TABLE_VERSIONS=("${GENVW_FSR4_RESOLVED_LOCAL_ONLY_VERSIONS[@]}")
}

genvw_wizard_fsr4_meta_path() {
  local ver="${1:-}"
  printf '%s\n' "${GENVW_FSR4_LOCAL_DIR}/${genvw_amd_dll_stem}_v${ver}.meta.txt"
}

genvw_wizard_fsr4_meta_value() {
  local meta="${1:-}" key="${2:-}"
  [[ -f "$meta" && -n "$key" ]] || return 1
  grep -m1 -E "^${key}=" "$meta" 2>/dev/null | cut -d= -f2- || true
}

genvw_wizard_fsr4_canonical_size() {
  local want="${1:-}" row="" ver="" url="" sha="" size=""
  for row in "${GENVW_FSR4_CANONICAL_TRUSTED_SOURCE_ROWS[@]}"; do
    IFS='|' read -r ver url sha size <<<"$row"
    if [[ "$ver" == "$want" && "$size" =~ ^[0-9]+$ ]]; then
      printf '%s\n' "$size"
      return 0
    fi
  done
  return 1
}

genvw_wizard_fsr4_size_human() {
  local bytes="${1:-}" unit="" suffix="" tenths="" whole="" frac=""
  [[ "$bytes" =~ ^[0-9]+$ ]] || { printf '%s\n' "-"; return 0; }
  if ((bytes < 1024)); then
    printf '%s\n' "$bytes"
    return 0
  elif ((bytes < 1048576)); then
    unit=1024
    suffix="K"
  elif ((bytes < 1073741824)); then
    unit=1048576
    suffix="M"
  else
    unit=1073741824
    suffix="G"
  fi
  tenths=$(((bytes * 10 + unit / 2) / unit))
  whole=$((tenths / 10))
  frac=$((tenths % 10))
  printf '%s.%s%s\n' "$whole" "$frac" "$suffix"
}

genvw_wizard_fsr4_source_label() {
  local kind="${1:-}" canonical_present="${2:-0}"
  case "$kind" in
    trusted-version | trusted | url | remote) printf '%s\n' "url" ;;
    exe) printf '%s\n' "exe" ;;
    dll) printf '%s\n' "dll" ;;
    *) [[ "$canonical_present" == "1" ]] && printf '%s\n' "url" || printf '%s\n' "-" ;;
  esac
}

genvw_wizard_fsr4_installed_date() {
  local path="${1:-}" meta="${2:-}" installed="" st=""
  installed="$(genvw_wizard_fsr4_meta_value "$meta" INSTALLED_AT_UTC 2>/dev/null || true)"
  if [[ "$installed" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2} ]]; then
    printf '%s\n' "${installed:0:10}"
    return 0
  fi
  if [[ -f "$path" ]]; then
    st="$(LC_ALL=C stat -c '%y' "$path" 2>/dev/null || true)"
    if [[ "$st" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2} ]]; then
      printf '%s\n' "${st:0:10}"
      return 0
    fi
  fi
  printf '%s\n' "-"
}

genvw_wizard_fsr4_print_table() {
  local gpu_label="${1:-GPU}" auto_ver="${2:-}" local_ver="${3:-}" target_label="" row=1 ver="" status="" mark=""
  local path="" meta="" size="" installed="" source="" canonical_size="" local_size="" source_kind="" canonical_present=0

  target_label="$(genvw_wizard_fsr4_target_label)"
  if ((${#GENVW_WIZARD_FSR4_TABLE_VERSIONS[@]} == 0)); then
    genvw_wizard_fsr4_prepare_table_versions
  fi

  echo "${BOLD}FSR4 versions${RESET}"
  echo
  printf '  Target: %s\n' "$target_label"
  printf '  GPU: %s\n' "$gpu_label"
  printf '  Auto mode currently resolves to: %s\n' "$auto_ver"
  printf '  Installed cache default: %s\n' "$local_ver"
  printf '  Cache: local upscaler cache\n'
  echo
  printf '  %-2s %-8s %-10s %-6s %-12s %s\n' "#" "VERSION" "STATUS" "SIZE" "INSTALLED" "SOURCE"
  for ver in "${GENVW_WIZARD_FSR4_TABLE_VERSIONS[@]}"; do
    path="$(genvw_fsr4_local_dll_path "$ver")"
    meta="$(genvw_wizard_fsr4_meta_path "$ver")"
    status="$(genvw_wizard_fsr4_row_status "$ver")"
    canonical_size="$(genvw_wizard_fsr4_canonical_size "$ver" 2>/dev/null || true)"
    canonical_present=0
    [[ -n "$canonical_size" ]] && canonical_present=1
    if [[ -f "$path" ]]; then
      local_size="$(wc -c <"$path" 2>/dev/null | tr -d '[:space:]' || true)"
      size="$(genvw_wizard_fsr4_size_human "$local_size")"
    elif [[ -n "$canonical_size" ]]; then
      size="$(genvw_wizard_fsr4_size_human "$canonical_size")"
    else
      size="-"
    fi
    installed="$(genvw_wizard_fsr4_installed_date "$path" "$meta")"
    source_kind="$(genvw_wizard_fsr4_meta_value "$meta" SOURCE_KIND 2>/dev/null || true)"
    if [[ -f "$path" ]]; then
      source="$(genvw_wizard_fsr4_source_label "$source_kind" "0")"
    else
      source="$(genvw_wizard_fsr4_source_label "$source_kind" "$canonical_present")"
    fi
    mark=""
    [[ "$ver" == "$local_ver" ]] && mark=" [installed default]"
    printf '  %-2s %-8s %-10s %-6s %-12s %s%s\n' "$row" "$ver" "$status" "$size" "$installed" "$source" "$mark"
    row=$((row + 1))
  done
}

genvw_wizard_fsr4_pick_table_version() {
  if ((${#GENVW_WIZARD_FSR4_TABLE_VERSIONS[@]} == 0)); then
    genvw_wizard_fsr4_prepare_table_versions
  fi
  local row_count="${#GENVW_WIZARD_FSR4_TABLE_VERSIONS[@]}" row="" idx=0
  while :; do
    printf "%s" "${YELLOW}Select FSR4 version from table [1-${row_count}]: ${RESET}" >&2
    tty_read row || row=""
    row="$(trim "$row")"
    if [[ -z "$row" ]]; then
      printf "%s\n\n" "${YELLOW}No row selected.${RESET}" >&2
      return 1
    fi
    case "$row" in
      *[!0-9]*)
        printf "%s\n\n" "${RED}Enter a number from 1 to ${row_count}.${RESET}" >&2
        ;;
      *)
        idx=$((10#$row - 1))
        if ((idx >= 0 && idx < row_count)); then
          printf '%s\n' "${GENVW_WIZARD_FSR4_TABLE_VERSIONS[$idx]}"
          return 0
        fi
        printf "%s\n\n" "${RED}Enter a number from 1 to ${row_count}.${RESET}" >&2
        ;;
    esac
  done
}

genvw_wizard_fsr4_table_contains_version() {
  local want="${1:-}" ver=""
  [[ -n "$want" ]] || return 1
  if ((${#GENVW_WIZARD_FSR4_TABLE_VERSIONS[@]} == 0)); then
    genvw_wizard_fsr4_prepare_table_versions
  fi
  for ver in "${GENVW_WIZARD_FSR4_TABLE_VERSIONS[@]}"; do
    [[ "$ver" == "$want" ]] && return 0
  done
  return 1
}

genvw_wizard_fsr4_offer_install_for_missing_exact() {
  local ver="${1:-}" path="" question=""
  genvw_fsr4_is_knob_allowed "$ver" || return 1
  genvw_wizard_fsr4_table_contains_version "$ver" || return 1

  path="$(genvw_fsr4_local_dll_path "$ver")"
  [[ -f "$path" ]] && return 0

  echo
  printf 'FSR4 %s is not installed.\n' "$ver"
  question="${YELLOW}Install this FSR4 version now? [Y/n]: ${RESET}"
  if ask_yes_no_default "$question" "y"; then
    echo
    printf 'Installing FSR4 %s:\n' "$ver"
    printf '  genvw proton dll install --ver %s\n' "$ver"
    echo
    if ! run_proton dll install --ver "$ver"; then
      echo
      printf 'FSR4 %s install failed. The wizard will continue,\n' "$ver"
      printf 'but this selected FSR4 version may not work until installed.\n'
      echo
      printf 'Install it later with:\n'
      printf '  genvw proton dll install --ver %s\n' "$ver"
    fi
    echo
    return 0
  fi

  echo
  printf 'Warning:\n'
  printf '  Launch options will still be printed, but FSR4 %s\n' "$ver"
  printf '  will not work until this version is installed.\n'
  echo
  printf 'Install it later with:\n'
  printf '  genvw proton dll install --ver %s\n' "$ver"
  echo
}

genvw_wizard_fsr4_apply_table_version() {
  local ver="${1:-}" route_style="${2:-}"
  if ! genvw_wizard_fsr4_offer_install_for_missing_exact "$ver"; then
    printf "%s\n\n" "${RED}Unexpected selection; disabling FSR4.${RESET}"
    return 0
  fi
  genvw_wizard_fsr4_set_value "$ver" "$route_style"
  printf "%s\n\n" "${CYAN}Pinned FSR4 version ${ver} selected.${RESET}"
}

genvw_wizard_fsr4_apply_version() {
  local ver="${1:-}" picker_func="${2:-}" route_style="${3:-}" sel=""

  [[ -n "$ver" ]] || return 0
  if genvw_fsr4_is_local_only "$ver"; then
    sel="$("$picker_func" "${ver:-}")"
    case "$sel" in
      0 | "")
        echo
        return 0
        ;;
      ABORT)
        printf "%s\n" "${RED}Aborted.${RESET}"
        exit 1
        ;;
      *)
        if genvw_fsr4_is_knob_allowed "$sel"; then
          ver="$sel"
        else
          printf "%s\n\n" "${RED}Unexpected selection; disabling FSR4.${RESET}"
          return 0
        fi
        ;;
    esac
  fi
  genvw_wizard_fsr4_set_value "$ver" "$route_style"
  printf "%s\n\n" "${CYAN}Pinned FSR4 version ${ver} selected.${RESET}"
}

genvw_wizard_mlfg_version_capable() {
  local ver="${1:-}" minor="" patch=""
  [[ "$ver" =~ ^4[.]([0-9]+)[.]([0-9]+)$ ]] || return 1
  minor="${BASH_REMATCH[1]}"
  patch="${BASH_REMATCH[2]}"
  if ((10#$minor > 0)); then
    return 0
  fi
  ((10#$patch >= 3))
}

genvw_wizard_mlfg_provider_has_runtime() {
  local provider="" build_date="" version=""
  provider="$(genvw_wizard_selected_capability_get PROVIDER 2>/dev/null || true)"
  case "$provider" in
    cachyos)
      build_date="$(genvw_wizard_selected_capability_get BUILD_DATE 2>/dev/null || true)"
      [[ "$build_date" =~ ^[0-9]{8}$ ]] && ((10#$build_date >= 10#20251222))
      ;;
    dwproton)
      version="$(genvw_wizard_selected_capability_get VERSION 2>/dev/null || true)"
      build_date="$(genvw_wizard_selected_capability_get BUILD_DATE 2>/dev/null || true)"
      [[ -n "$version" ]] || return 1
      [[ "$build_date" =~ ^[0-9]{8}$ ]] && ((10#$build_date >= 10#20251222))
      ;;
    *)
      return 1
      ;;
  esac
}

genvw_wizard_mlfg_selected_dll_installed() {
  local ver="${1:-}" path=""
  [[ -n "$ver" ]] || return 1
  path="$(genvw_fsr4_local_dll_path "$ver")"
  [[ -f "$path" ]]
}

genvw_wizard_mlfg_selected_context_eligible() {
  local reason_var="${1:-}" version_var="${2:-}" gate_status="" ver="${GENVW_WIZARD_FSR4_SELECTION_VERSION:-}"

  if [[ "${GENVW_WIZARD_FSR4_SELECTION_KIND:-}" != "exact" || -z "$ver" ]]; then
    gate_status="not_exact"
  elif ! genvw_wizard_mlfg_version_capable "$ver"; then
    gate_status="version"
  elif ! genvw_wizard_mlfg_selected_dll_installed "$ver"; then
    gate_status="missing"
  elif ! genvw_wizard_mlfg_provider_has_runtime; then
    gate_status="provider"
  else
    gate_status="eligible"
  fi

  if [[ -n "$reason_var" ]]; then
    printf -v "$reason_var" '%s' "$gate_status"
  fi
  if [[ -n "$version_var" ]]; then
    printf -v "$version_var" '%s' "$ver"
  fi
  [[ "$gate_status" == "eligible" ]]
}

genvw_wizard_mlfg_print_offer_intro() {
  local ver="${1:-}" target_label=""
  target_label="$(genvw_wizard_fsr4_target_label)"
  echo "${BOLD}MLFG:${RESET}"
  echo "  Machine Learning Frame Generation is available for:"
  printf '    %s\n' "$target_label"
  printf '    FSR4 %s\n' "$ver"
  echo
}

genvw_wizard_mlfg_print_not_offered() {
  local reason="${1:-}" ver="${2:-}"
  case "$reason" in
    version)
      echo "${BOLD}MLFG:${RESET}"
      printf '  Not offered because FSR4 %s does not support MLFG.\n\n' "$ver"
      ;;
    missing)
      echo "${BOLD}MLFG:${RESET}"
      printf '  Not offered because FSR4 %s is not installed.\n\n' "$ver"
      ;;
    provider)
      echo "${BOLD}MLFG:${RESET}"
      printf '  Not offered for this selected Proton target.\n\n'
      ;;
  esac
}

genvw_wizard_fsr4_unknown_path_dispatch() {
  local choice=""
  while :; do
    echo "${BOLD}FSR4 GPU path${RESET}"
    echo
    echo "  1) RDNA2/RDNA3"
    echo "  2) RDNA4"
    echo "  0) Skip FSR4"
    echo
    printf "%s" "${YELLOW}GPU path [0-2, default=0]: ${RESET}"
    tty_read choice || choice=""
    choice="$(trim "$choice")"
    [[ -n "$choice" ]] || choice="0"
    case "$choice" in
      0)
        echo
        return 0
        ;;
      1)
        echo
        genvw_wizard_run_fsr4_menu \
          "RDNA3/3.5" \
          "RDNA3 / RDNA3.5" \
          "RDNA3/3.5 selected -> using RDNA3 FSR4 table." \
          "" \
          "pick_rdna3_fsr4_local_only" \
          "rdna3" \
          3
        return 0
        ;;
      2)
        echo
        genvw_wizard_run_fsr4_menu \
          "RDNA4" \
          "RDNA4" \
          "RDNA4 selected -> using RDNA4 FSR4 table." \
          "" \
          "pick_rdna4_fsr4" \
          "global" \
          4
        return 0
        ;;
      *)
        printf "%s\n\n" "${RED}Enter 0, 1 or 2.${RESET}"
        ;;
    esac
  done
}

genvw_wizard_fsr4_validate_picker_func() {
  local picker_func="${1:-}"
  case "$picker_func" in
    pick_rdna2_fsr4_local_only|pick_rdna3_fsr4_local_only|pick_rdna4_fsr4)
      return 0
      ;;
    *)
      die "Internal: invalid FSR4 picker: $picker_func"
      ;;
  esac
}

genvw_wizard_fsr4_prompt_exact_trusted_version() {
  local heading_label="${1:-}"
  local picker_func="${2:-}"
  local route_style="${3:-}"
  local ver="" sel=""

  genvw_wizard_fsr4_validate_picker_func "$picker_func"

  while :; do
    echo "Enter exact trusted FSR4 version for ${heading_label}."
    echo "Allowed versions: $(genvw_fsr4_allowed_versions_csv)"
    printf "%s" "${YELLOW}FSR4 trusted version (${heading_label}): ${RESET}"
    tty_read ver || ver=""
    ver=$(trim "$ver")
    case "$ver" in
      "")
        printf "%s\n\n" "${YELLOW}Empty version, skipping exact trusted FSR4 selection for ${heading_label}.${RESET}"
        return 0
        ;;
      4.*)
        if ! genvw_fsr4_is_knob_allowed "$ver"; then
          printf "%s\n\n" "${RED}Invalid version. Allowed values: $(genvw_fsr4_allowed_versions_csv).${RESET}"
          continue
        fi
        if genvw_fsr4_is_local_only "$ver"; then
          sel="$("$picker_func" "${ver:-}")"
          case "$sel" in
            0 | "") return 0 ;;
            ABORT)
              printf "%s\n" "${RED}Aborted.${RESET}"
              exit 1
              ;;
            *)
              if genvw_fsr4_is_knob_allowed "$sel"; then
                ver="$sel"
              else
                printf "%s\n\n" "${RED}Unexpected selection; disabling FSR4.${RESET}"
                return 0
              fi
              ;;
          esac
        fi
        genvw_wizard_fsr4_set_value "$ver" "$route_style"
        echo
        return 0
        ;;
      *)
        printf "%s\n\n" "${RED}Invalid version. Allowed values: $(genvw_fsr4_allowed_versions_csv).${RESET}"
        ;;
    esac
  done
}

genvw_wizard_run_fsr4_menu() {
  local prompt_label="${1:-}"
  local heading_label="${2:-}"
  local intro_line="${3:-}"
  local support_line="${4:-}"
  local picker_func="${5:-}"
  local route_style="${6:-}"
  local gen="${7:-0}"
  local choice="" sel="" auto_ver="" upstream_auto_ver="" local_ver="" allowed_csv=""

  genvw_wizard_fsr4_validate_picker_func "$picker_func"

  auto_ver="$(genvw_wizard_fsr4_auto_default_for_target "$gen")"
  local_ver="$(genvw_fsr4_effective_local_default_ver)"
  genvw_wizard_fsr4_prepare_table_versions

  printf "%s\n\n" "${CYAN}${intro_line}${RESET}"
  while :; do
    genvw_wizard_fsr4_print_table "$heading_label" "$auto_ver" "$local_ver"
    echo
    echo "Recommended:"
    printf '  1) Auto mode - currently resolves to %s\n' "$auto_ver"
    printf '  2) Pin installed default version %s\n' "$local_ver"
    echo
    echo "Advanced:"
    echo "  3) Pick and pin a version from table"
    echo "  4) Pin compatibility version 4.0.0"
    echo "  0) Skip FSR4"
    echo
    printf "%s" "${YELLOW}FSR4 [0-4, default=1]: ${RESET}"
    tty_read choice || choice=""
    choice=$(trim "$choice")
    [[ -n "$choice" ]] || choice="1"
    case "$choice" in
      0)
        echo
        return 0
        ;;
      1)
        genvw_wizard_fsr4_set_value "1" "$route_style"
        printf "%s\n\n" "${CYAN}Auto FSR4 selected; current target default resolves to ${auto_ver}.${RESET}"
        return 0
        ;;
      2)
        genvw_wizard_fsr4_apply_version "$local_ver" "$picker_func" "$route_style"
        return 0
        ;;
      3)
        sel="$(genvw_wizard_fsr4_pick_table_version)" || {
          echo
          continue
        }
        genvw_wizard_fsr4_apply_table_version "$sel" "$route_style"
        return 0
        ;;
      4)
        genvw_wizard_fsr4_set_value "4.0.0" "$route_style"
        printf "%s\n\n" "${CYAN}Pinned FSR4 version 4.0.0 selected.${RESET}"
        return 0
        ;;
      *)
        printf "%s\n\n" "${RED}Enter 0, 1, 2, 3 or 4.${RESET}"
        ;;
    esac
  done

  auto_ver="$(genvw_fsr4_default_remote_for_gen "$gen")"
  upstream_auto_ver="$(genvw_fsr4_upstream_auto_default_for_gen "$gen")"
  local_ver="$(genvw_fsr4_effective_local_default_ver)"
  allowed_csv="$(genvw_fsr4_allowed_versions_csv)"

  printf "%s\n\n" "${CYAN}${intro_line}${RESET}"
  while :; do
    echo "${BOLD}FSR4 for ${heading_label}${RESET}"
    if [[ -n "$support_line" ]]; then
      echo "  Support level: ${support_line}"
    fi
    if [[ "$upstream_auto_ver" == "$auto_ver" ]]; then
      printf '  Automatic Proton-CachyOS default: %s\n' "$auto_ver"
    else
      printf '  Upstream Proton-CachyOS automatic default: %s\n' "$upstream_auto_ver"
      printf '  gENVW FSR4=1 launch mapping:             %s\n' "$auto_ver"
    fi
    printf '  gENVW trusted local default:      %s\n' "$local_ver"
    printf '  Available trusted versions:       %s\n' "$allowed_csv"
    echo
    echo "  0 = off"
    if [[ "$upstream_auto_ver" == "$auto_ver" ]]; then
      printf '  1 = automatic default (FSR4=1, currently maps to %s)\n' "$auto_ver"
    else
      printf '  1 = automatic default (FSR4=1, gENVW maps to %s)\n' "$auto_ver"
    fi
    echo "  2 = force compatibility version (FSR4=4.0.0)"
    printf '  3 = trusted local default (FSR4=%s)\n' "$local_ver"
    echo "  4 = choose exact trusted version"
    echo
    printf "%s" "${YELLOW}FSR4 choice for ${prompt_label} [0]: ${RESET}"
    tty_read choice || choice=""
    choice=$(trim "$choice")
    [ -z "$choice" ] && choice="0"
    case "$choice" in
      0)
        echo
        return 0
        ;;
      1)
        genvw_wizard_fsr4_set_value "1" "$route_style"
        if [[ "$upstream_auto_ver" == "$auto_ver" ]]; then
          printf "%s\n\n" "${CYAN}Automatic FSR4 default selected (FSR4=1, currently maps to ${auto_ver}).${RESET}"
        else
          printf "%s\n\n" "${CYAN}Automatic FSR4 default selected (FSR4=1, gENVW maps to ${auto_ver}).${RESET}"
        fi
        return 0
        ;;
      2)
        genvw_wizard_fsr4_set_value "4.0.0" "$route_style"
        echo
        return 0
        ;;
      3)
        sel="$("$picker_func" "${local_ver:-}")"
        case "$sel" in
          0 | "")
            echo
            return 0
            ;;
          ABORT)
            printf "%s\n" "${RED}Aborted.${RESET}"
            exit 1
            ;;
          *)
            if genvw_fsr4_is_knob_allowed "$sel"; then
              genvw_wizard_fsr4_set_value "$sel" "$route_style"
            else
              printf "%s\n\n" "${RED}Unexpected selection; disabling FSR4.${RESET}"
            fi
            echo
            return 0
            ;;
        esac
        ;;
      4)
        genvw_wizard_fsr4_prompt_exact_trusted_version "$heading_label" "$picker_func" "$route_style"
        return 0
        ;;
      *)
        printf "%s\n\n" "${RED}Enter 0, 1, 2, 3 or 4.${RESET}"
        ;;
    esac
  done
}

  # detect RDNA generation
  RDNA_GEN=$(detect_rdna_gen)
  case "$RDNA_GEN" in
    2) printf "%s\n\n" "${GREEN}Detected GPU architecture: RDNA2${RESET}" ;;
    3) printf "%s\n\n" "${GREEN}Detected GPU architecture: RDNA3/3.5${RESET}" ;;
    4) printf "%s\n\n" "${GREEN}Detected GPU architecture: RDNA4${RESET}" ;;
    1) printf "%s\n\n" "${RED}Forced unsupported GPU simulation (GENVW_FORCE_RDNA_GEN=1).${RESET}" ;;
    0) printf "%s\n\n" "${YELLOW}Could not detect RDNA generation automatically (RDNA_GEN=0).${RESET}" ;;
  esac
  genvw_require_supported_gpu "$RDNA_GEN" || exit $?
  # detect maximum logical CPUs (best-effort with static fallback).
  MAX_CORES="$(genvw_detect_max_logical_cpus)"
  # optional preflight (interactive only): checks genvw_proton setup and offers fixes.
  # set GENVW_NO_PREFLIGHT=1 to skip.
  if [ -z "${GENVW_NO_PREFLIGHT:-}" ] && genvw_tty_io_ready; then
    if [ -t 1 ]; then
      genvw_setup_preflight || exit $?
    else
      genvw_setup_preflight >&2 || exit $?
    fi
  fi
  genvw_wizard_select_proton_target
  genvw_wizard_selected_capability_capture
  genvw_wizard_offer_selected_target_rebuild
  ########################
  # Monitor detection
  ########################
  genvw_wizard_monitor_scan
  if [ "${WIZARD_MON_COUNT:-0}" -gt 0 ]; then
    genvw_wizard_monitor_prompt
    if [ -n "$WIZARD_MON" ]; then
      LAUNCH_ENV="$LAUNCH_ENV MON=$WIZARD_MON"
    fi
  fi
  echo
  ########################
  # HDR (strict y/n)
  ########################
  hdr_session_mode="$(genvw_hdr_display_mode)"
  hdr_question="${YELLOW}Enable HDR? [y/n]: ${RESET}"
  hdr_requested_from_current_sdr=0
  genvw_hdr_print_wizard_intro "$hdr_session_mode"
  if [ "${WIZARD_MON_HDR:-}" = "0" ]; then
    genvw_hdr_print_current_sdr_state "$WIZARD_MON" "$hdr_session_mode"
    if genvw_hdr_session_can_request_hdr "$hdr_session_mode"; then
      hdr_question="${YELLOW}Request HDR launch path (HDR=1)? [y/n]: ${RESET}"
    else
      hdr_question=""
    fi
  fi
  if [ -n "$hdr_question" ] && ask_yes_no "$hdr_question"; then
    LAUNCH_ENV="$LAUNCH_ENV HDR=1"
    HDR_ENABLED=1
    [ "${WIZARD_MON_HDR:-}" = "0" ] && hdr_requested_from_current_sdr=1
    genvw_hdr_warn_wizard_choice_if_unsupported "$hdr_session_mode"
    if [ "$hdr_session_mode" = "x11" ] && ! genvw_have_gamescope; then
      _gs_missing_choice=""
      genvw_wizard_missing_gamescope_choice \
        "HDR on X11 requires Gamescope, but gamescope is not installed." \
        "continue without HDR" \
        "_gs_missing_choice"
      if [ "$_gs_missing_choice" = "2" ]; then
        genvw_gamescope_print_install_hint
        msg "Re-run genvw after installing Gamescope."
        exit 0
      fi
      LAUNCH_ENV="$(genvw_launch_env_drop_key "$LAUNCH_ENV" "HDR")"
      LAUNCH_ENV="$(trim_outer_ws "$LAUNCH_ENV")"
      HDR_ENABLED=0
      printf "%s\n" "${CYAN}Continuing in SDR mode.${RESET}"
      msg "HDR was disabled because X11 needs Gamescope for HDR."
      genvw_gamescope_print_install_hint
    fi
  fi
  echo
  ###########################################################
  # FSR4 menus – behavior depends on RDNA generation
  ###########################################################
  if [[ "$(genvw_wizard_selected_capability_get FSR4_OPTION_VISIBLE 2>/dev/null || true)" == "1" ]]; then
  case "$RDNA_GEN" in
    2)
      genvw_wizard_run_fsr4_menu \
        "RDNA2" \
        "RDNA2" \
        "RDNA2 detected -> using limited RDNA2 FSR4 menu." \
        "limited / experimental" \
        "pick_rdna2_fsr4_local_only" \
        "rdna3" \
        2
      ;;
    3)
      genvw_wizard_run_fsr4_menu \
        "RDNA3/3.5" \
        "RDNA3 / RDNA3.5" \
        "RDNA3/3.5 detected -> using RDNA3 FSR4 menu." \
        "" \
        "pick_rdna3_fsr4_local_only" \
        "rdna3" \
        3
      ;;
    4)
      genvw_wizard_run_fsr4_menu \
        "RDNA4" \
        "RDNA4" \
        "RDNA4 detected -> using RDNA4 FSR4 menu." \
        "" \
        "pick_rdna4_fsr4" \
        "global" \
        4
      ;;
    *)
      genvw_wizard_fsr4_unknown_path_dispatch
      if false; then
      printf "%s\n\n" "${YELLOW}RDNA generation unknown -> showing both RDNA3 and RDNA4 FSR4 menus.${RESET}"
      # RDNA3 FSR4 (FSR4_RDNA3=...)
      genvw_wizard_run_fsr4_menu \
        "RDNA3/3.5" \
        "RDNA3 / RDNA3.5" \
        "RDNA3/3.5 detected -> using RDNA3 FSR4 menu." \
        "" \
        "pick_rdna3_fsr4_local_only" \
        "rdna3" \
        3
      # RDNA4/global FSR4 (FSR4=...) – only if RDNA3 FSR not selected
      if [ "$FSR4_RDNA3_USED" -eq 0 ]; then
        genvw_wizard_run_fsr4_menu \
          "RDNA4" \
          "RDNA4" \
          "RDNA4 detected -> using RDNA4 FSR4 menu." \
          "" \
          "pick_rdna4_fsr4" \
          "global" \
          4
      else
        printf "%s\n\n" "${CYAN}FSR4 for RDNA3 is enabled -> skipping RDNA4 FSR4 question.${RESET}"
      fi
      fi
      ;;
  esac
  fi

  ########################
  # MLFG (Machine Learning Frame Generation)
  ########################
  _mlfg_reason=""
  _mlfg_ver=""
  if genvw_wizard_mlfg_selected_context_eligible _mlfg_reason _mlfg_ver; then
    genvw_wizard_mlfg_print_offer_intro "$_mlfg_ver"
    while :; do
      printf "%s" "${YELLOW}Use MLFG? [Y/n]: ${RESET}"
      # Prefer /dev/tty so it works even if stdin is redirected.
      tty_read mlfg_ans || mlfg_ans=""
      mlfg_ans=$(trim "$mlfg_ans")
      if [ -z "$mlfg_ans" ]; then
        LAUNCH_ENV="$LAUNCH_ENV MLFG=1"
        printf "%s\n\n" "${CYAN}${I_INFO} MLFG will be requested.${RESET}"
        break
      fi
      case "$mlfg_ans" in
        y | Y)
          LAUNCH_ENV="$LAUNCH_ENV MLFG=1"
          printf "%s\n\n" "${CYAN}${I_INFO} MLFG will be requested.${RESET}"
          break
          ;;
        n | N)
          LAUNCH_ENV="$LAUNCH_ENV MLFG=0"
          printf "%s\n\n" "${CYAN}${I_INFO} MLFG disabled for this launch line.${RESET}"
          break
          ;;
        *)
          printf "%s\n\n" "${RED}Type y or n (Enter = default: yes).${RESET}"
          ;;
      esac
    done
  elif [[ "${GENVW_WIZARD_FSR4_SELECTION_KIND:-}" == "exact" ]]; then
    genvw_wizard_mlfg_print_not_offered "$_mlfg_reason" "$_mlfg_ver"
  fi
  unset _mlfg_reason _mlfg_ver

  gs_filter="0"
  gs_sharp=""
  gs_res=""
  gs_full="0"
  gs_grab="0"
  wizard_fsr4_active=0
  wizard_skip_upscaler_msg=0
  if genvw_fsr4_launch_env_is_active "$LAUNCH_ENV"; then
    wizard_fsr4_active=1
  fi

  ########################
  # FSR4 indicator
  ########################
  if [ "$wizard_fsr4_active" -eq 1 ]; then
    if ask_yes_no_default "${YELLOW}Testing overlay: show FSR4/MLFG indicator? [y/N]: ${RESET}" "n"; then
      LAUNCH_ENV="$LAUNCH_ENV FSR4SHOW=1"
    fi
    echo
  fi

  ########################
  # LSFG
  ########################
  WIZARD_LSFG_CONF_PATH=""
  WIZARD_LSFG_DLL_PATH=""
  WIZARD_LSFG_DLL_VER=""
  if genvw_have_lsfg; then
    if genvw_lsfg_dll_info WIZARD_LSFG_CONF_PATH WIZARD_LSFG_DLL_PATH WIZARD_LSFG_DLL_VER; then
      wizard_lsfg=""
      wizard_lsfg_perf=""
      wizard_lsfg_flow=""
      wizard_lsfg_present=""
      wizard_lsfg_hdr=""
      genvw_wizard_lsfg_prompt wizard_lsfg wizard_lsfg_perf wizard_lsfg_flow
      wizard_lsfg_present="${GENVW_WIZARD_LSFG_PRESENT:-}"
      wizard_lsfg_hdr="${GENVW_WIZARD_LSFG_HDR:-}"
      if [ -n "$wizard_lsfg" ]; then
        LAUNCH_ENV="$LAUNCH_ENV LSFG=$wizard_lsfg"
        [ "$wizard_lsfg_perf" = "1" ] && LAUNCH_ENV="$LAUNCH_ENV LSFGPERF=1"
        [ -n "$wizard_lsfg_flow" ] && LAUNCH_ENV="$LAUNCH_ENV LSFGFLOW=$wizard_lsfg_flow"
        [ -n "$wizard_lsfg_present" ] && LAUNCH_ENV="$LAUNCH_ENV LSFGPRESENT=$wizard_lsfg_present"
        [ -n "$wizard_lsfg_hdr" ] && LAUNCH_ENV="$LAUNCH_ENV LSFGHDR=$wizard_lsfg_hdr"
      fi
    else
      case "$?" in
        1) msg "lsfg-vk installed but not configured. Run lsfg-vk-ui." ;;
        2) msg "Config found but no DLL path set. Run lsfg-vk-ui." ;;
        3) msg "Lossless.dll not found. Install Lossless Scaling (Steam 993090)." ;;
      esac
      echo
    fi
  fi

  ########################
  # Gamescope / monitor / Gamescope upscaler
  ########################
  if [ "$HDR_ENABLED" -eq 1 ] && [ "$hdr_session_mode" = "wayland" ]; then
    if [ "${hdr_requested_from_current_sdr:-0}" -eq 1 ]; then
      printf "%s\n\n" "${CYAN}Wayland HDR launch path requested, so Gamescope is skipped by default to avoid extra latency.${RESET}"
    else
      printf "%s\n\n" "${CYAN}Native Wayland HDR is already available here, so Gamescope is skipped by default to avoid extra latency.${RESET}"
    fi
  else
    echo "${BOLD}GS:${RESET} Wrap command in Gamescope (if available)."
    if [ "$HDR_ENABLED" -eq 1 ] && ! genvw_hdr_session_supports_hdr_path "$hdr_session_mode" && genvw_have_gamescope; then
      echo "HDR is enabled on $(genvw_hdr_display_label "$hdr_session_mode") → Gamescope is recommended here."
    fi
    if ask_yes_no "${YELLOW}Enable Gamescope (GS=1)? [y/n]: ${RESET}"; then
      if ! genvw_have_gamescope; then
        _gs_missing_choice=""
        genvw_wizard_missing_gamescope_choice \
          "Gamescope is not installed." \
          "continue without Gamescope" \
          "_gs_missing_choice"
        if [ "$_gs_missing_choice" = "2" ]; then
          genvw_gamescope_print_install_hint
          msg "Re-run genvw after installing Gamescope."
          exit 0
        fi
        printf "%s\n" "${CYAN}Continuing without Gamescope.${RESET}"
        genvw_gamescope_print_install_hint
        echo
      else
        LAUNCH_ENV="$LAUNCH_ENV GS=1"
        echo

        echo "${BOLD}GSFULL:${RESET} Start Gamescope fullscreen (-f)."
        echo "Recommended for most Gamescope launches."
        if ask_yes_no_default "${YELLOW}Enable Gamescope fullscreen? [Y/n]: ${RESET}" "y"; then
          LAUNCH_ENV="$LAUNCH_ENV GSFULL=1"
          gs_full="1"
          echo
          echo "${BOLD}GSGRAB:${RESET} Force Gamescope to keep the mouse cursor grabbed."
          echo "Useful for games with broken mouse capture or endless camera spinning."
          if ask_yes_no_default "${YELLOW}Enable force-grab-cursor? [y/N]: ${RESET}" "n"; then
            LAUNCH_ENV="$LAUNCH_ENV GSGRAB=1"
            gs_grab="1"
          fi
        fi
        echo

        if [ "$wizard_fsr4_active" -eq 1 ]; then
          printf "%s\n" "${CYAN}FSR4 is active, so other upscalers are skipped to avoid double upscaling.${RESET}"
          msg "Skipped:"
          msg "  - GSFSR"
          msg "  - GSSHARP"
          msg "  - GSRES"
          msg "  - FFSR"
          echo
          wizard_skip_upscaler_msg=1
        else
          while :; do
            echo "${BOLD}GSFSR:${RESET} Gamescope upscaler filter (requires GS=1)."
            echo "  0     = off"
            echo "  fsr   = AMD FidelityFX Super Resolution 1.0"
            echo "  nis   = NVIDIA Image Scaling"
            echo "  pixel = pixel/nearest-style filtering"
            printf "%s" "${YELLOW}GSFSR [0]: ${RESET}"
            tty_read gs_filter || gs_filter=""
            gs_filter=$(trim "$gs_filter")
            [ -z "$gs_filter" ] && gs_filter="0"
            case "$gs_filter" in
              0)
                echo
                break
                ;;
              fsr|nis|pixel)
                LAUNCH_ENV="$LAUNCH_ENV GSFSR=$gs_filter"
                echo
                break
                ;;
              *)
                printf "%s\n\n" "${RED}Enter 0, fsr, nis, or pixel.${RESET}"
                ;;
            esac
          done

          if genvw_gamescope_filter_supports_sharpness "$gs_filter"; then
            while :; do
              echo "${BOLD}GSSHARP:${RESET} Gamescope sharpness for GSFSR=$gs_filter."
              echo "  0 = maximum sharpness"
              echo "  20 = minimum sharpness"
              echo "  empty = gamescope default"
              printf "%s" "${YELLOW}GSSHARP [default]: ${RESET}"
              tty_read gs_sharp || gs_sharp=""
              gs_sharp=$(trim "$gs_sharp")
              [ -z "$gs_sharp" ] && {
                echo
                break
              }
              case "$gs_sharp" in
                *[!0-9]*)
                  printf "%s\n\n" "${RED}Enter a number between 0 and 20, or leave it empty.${RESET}"
                  ;;
                *)
                  if [ "$gs_sharp" -ge 0 ] && [ "$gs_sharp" -le 20 ]; then
                    LAUNCH_ENV="$LAUNCH_ENV GSSHARP=$gs_sharp"
                    echo
                    break
                  else
                    printf "%s\n\n" "${RED}Enter a number between 0 and 20, or leave it empty.${RESET}"
                  fi
                  ;;
              esac
            done
          fi

          if [ "${gs_filter:-0}" != "0" ]; then
            if [ -n "${WIZARD_MON_RES:-}" ] && [[ "$WIZARD_MON_RES" =~ ^[1-9][0-9]*x[1-9][0-9]*$ ]]; then
              while :; do
                echo "${BOLD}GSRES:${RESET} Gamescope internal render resolution (requires GS=1)."
                if [ -n "${WIZARD_MON:-}" ]; then
                  echo "Output target: ${WIZARD_MON} at ${WIZARD_MON_RES}"
                fi
                echo "Gamescope will use:"
                echo "  -W ${WIZARD_MON_RES%x*} -H ${WIZARD_MON_RES#*x}"
                echo "  -w <GSRES width> -h <GSRES height>"
                echo "  empty = default"
                echo "  Example: 1920x1080"
                printf "%s" "${YELLOW}GSRES [default]: ${RESET}"
                tty_read gs_res || gs_res=""
                gs_res=$(trim "$gs_res")
                [ -z "$gs_res" ] && {
                  echo
                  break
                }
                case "$gs_res" in
                  [1-9][0-9]*x[1-9][0-9]*)
                    LAUNCH_ENV="$LAUNCH_ENV GSRES=$gs_res"
                    echo
                    break
                    ;;
                  *)
                    printf "%s\n\n" "${RED}Enter GSRES as WxH (for example 1920x1080), or leave it empty.${RESET}"
                    ;;
                esac
              done
            else
              printf "%s\n" "${CYAN}Gamescope render-resolution prompts are skipped because output resolution cannot be determined safely.${RESET}"
              msg "Tip: Use GSFSR without GSRES, or launch with MON=... when monitor detection works."
              echo
            fi
          fi
        fi
      fi
    fi
  fi
  echo
  ########################
  # FFSR – numeric only 0 or 1–5
  ########################
  if [ "$HDR_ENABLED" -eq 1 ]; then
    if [ "$wizard_skip_upscaler_msg" -eq 0 ]; then
      printf "%s\n\n" "${CYAN}HDR is enabled → skipping fullscreen FSR (FFSR).${RESET}"
    fi
  elif [ "$wizard_fsr4_active" -eq 1 ]; then
    if [ "$wizard_skip_upscaler_msg" -eq 0 ]; then
      printf "%s\n\n" "${CYAN}FSR4 is active → skipping fullscreen FSR (FFSR).${RESET}"
    fi
  elif [ "${gs_filter:-0}" != "0" ]; then
    printf "%s\n\n" "${CYAN}Wine fullscreen FSR is skipped because Gamescope upscaling is active.${RESET}"
  else
    while :; do
      echo "${BOLD}FFSR:${RESET} Wine fullscreen FSR (X11/Xwayland path, SDR only)."
      echo "  0 = off"
      echo "  1 = enable with default strength"
      echo "  2–5 = enable and set that strength"
      printf "%s" "${YELLOW}FFSR value [0]: ${RESET}"
      tty_read val || val=""
      val=$(trim "$val")
      [ -z "$val" ] && val="0"
      case "$val" in
        0)
          echo
          break
          ;;
        *[!0-9]*)
          printf "%s\n\n" "${RED}Enter 0 or a number between 1 and 5.${RESET}"
          ;;
        *)
          if [ "$val" -ge 1 ] && [ "$val" -le 5 ]; then
            LAUNCH_ENV="$LAUNCH_ENV FFSR=$val"
            echo
            break
          else
            printf "%s\n\n" "${RED}Enter 0 or a number between 1 and 5.${RESET}"
          fi
          ;;
      esac
    done
  fi
  ########################
  # debug
  ########################
  if [ "$wizard_fsr4_active" -eq 1 ]; then
    echo "${BOLD}DEBUG:${RESET} Enable Proton/DXVK/VKD3D logging + FSR4 overlay (for troubleshooting)."
  else
    echo "${BOLD}DEBUG:${RESET} Enable Proton/DXVK/VKD3D logging (for troubleshooting)."
  fi
  if ask_yes_no "${YELLOW}Enable debug mode? [y/n]: ${RESET}"; then
    LAUNCH_ENV="$LAUNCH_ENV DEBUG=1"
  fi
  echo
  ########################
  # DXVK mode selection
  ########################
  if [[ "$(genvw_wizard_dxvk_policy)" != "unknown_or_unsupported" ]]; then
    wizard_gplasync=""
    genvw_wizard_gplasync_prompt wizard_gplasync
    if [ -n "$wizard_gplasync" ]; then
      LAUNCH_ENV="$LAUNCH_ENV GPLASYNC=$wizard_gplasync"
    fi
  else
    echo "${BOLD}ASYNC:${RESET} DXVK async (DXVK_ASYNC=1). Use ONLY in singleplayer."
    if ask_yes_no "${YELLOW}Enable DXVK async? [y/n]: ${RESET}"; then
      LAUNCH_ENV="$LAUNCH_ENV ASYNC=1"
    fi
  fi
  ########################
  # Korthos low_latency_layer
  ########################
  if [[ "$(genvw_wizard_selected_capability_get LOWLATENCY_LAYER_OPTION_VISIBLE 2>/dev/null || true)" == "1" ]]; then
    wizard_lll=""
    wizard_lll_drop_gplasync=0
    genvw_wizard_korthos_menu wizard_lll wizard_lll_drop_gplasync "${wizard_gplasync:-}"
    if [[ -n "$wizard_lll" ]]; then
      LAUNCH_ENV="$LAUNCH_ENV LLL=$wizard_lll"
    fi
    if [[ "$wizard_lll_drop_gplasync" == "1" ]]; then
      LAUNCH_ENV="$(genvw_launch_env_drop_key "$LAUNCH_ENV" "GPLASYNC")"
      LAUNCH_ENV="$(trim_outer_ws "$LAUNCH_ENV")"
    fi
  fi
  echo
  ########################
  # local shader cache
  ########################
  echo "${BOLD}LSC:${RESET} Use local shader cache inside compatdata (PROTON_LOCAL_SHADER_CACHE=1)."
  if ask_yes_no "${YELLOW}Enable local shader cache? [y/n]: ${RESET}"; then
    LAUNCH_ENV="$LAUNCH_ENV LSC=1"
  fi
  echo
  ########################
  # no WM decorations
  ########################
  echo "${BOLD}NVMD:${RESET} Disable WM decorations (borderless, PROTON_NO_WM_DECORATION=1)."
  if ask_yes_no "${YELLOW}Disable WM decorations? [y/n]: ${RESET}"; then
    LAUNCH_ENV="$LAUNCH_ENV NVMD=1"
  fi
  echo
  ########################
  # ntsync
  ########################
  genvw_dxvk_resolve_target
  _nts_bdate="${GENVW_DXVK_TARGET_BUILD_DATE:-}"
  _nts_capability_mode="$(genvw_wizard_selected_ntsync_mode 2>/dev/null || true)"
  if genvw_wizard_selected_dw_ntsync_is_deferred; then
    genvw_wizard_ntsync_deferred_intro
  elif [[ "$_nts_capability_mode" == "proton_no_ntsync" ]] || { [[ -z "$_nts_capability_mode" ]] && genvw_proton_policy_uses_proton_no_ntsync; }; then
    while :; do
      genvw_wizard_ntsync_default_intro_proton11
      echo
      echo "  0) Leave default                              (recommended)"
      echo "  1) Disable NTSYNC (PROTON_NO_NTSYNC=1)"
      printf "%s" "${YELLOW}NTS [0-1, default=0]: ${RESET}"
      tty_read val || val=""
      val=$(trim "$val")
      [ -z "$val" ] && val="0"
      case "$val" in
        0)
          break
          ;;
        1)
          LAUNCH_ENV="$LAUNCH_ENV PROTON_NO_NTSYNC=1"
          break
          ;;
        *)
          printf "%s\n\n" "${RED}Enter 0 or 1.${RESET}"
          ;;
      esac
    done
  elif [[ "$_nts_capability_mode" == "proton_use_ntsync_default" ]] || { [[ -z "$_nts_capability_mode" && -n "$_nts_bdate" ]] && ((10#$_nts_bdate >= 10#20260312)); }; then
    while :; do
      genvw_wizard_ntsync_default_intro_enabled
      echo
      echo "  0) Leave default                              (recommended)"
      echo "  1) Disable NTSYNC"
      echo "  2) Force NTSYNC explicitly"
      printf "%s" "${YELLOW}NTS [0-2, default=0]: ${RESET}"
      tty_read val || val=""
      val=$(trim "$val")
      [ -z "$val" ] && val="0"
      case "$val" in
        0)
          break
          ;;
        1)
          LAUNCH_ENV="$LAUNCH_ENV PROTON_USE_NTSYNC=0"
          break
          ;;
        2)
          LAUNCH_ENV="$LAUNCH_ENV PROTON_USE_NTSYNC=1"
          break
          ;;
        *)
          printf "%s\n\n" "${RED}Enter 0, 1, or 2.${RESET}"
          ;;
      esac
    done
  else
    echo "${BOLD}NTS:${RESET} Use NTSYNC backend (PROTON_USE_NTSYNC=1, requires /dev/ntsync)."
    if ask_yes_no "${YELLOW}Enable NTSYNC? [y/n]: ${RESET}"; then
      LAUNCH_ENV="$LAUNCH_ENV NTS=1"
    fi
  fi
  unset _nts_capability_mode
  unset _nts_bdate
  echo
  ########################
  # CPU topology – capped by MAX_CORES
  ########################
  while :; do
    echo "${BOLD}CPU:${RESET} Fake CPU topology for the game via WINE_CPU_TOPOLOGY."
    echo "  0 / empty = off"
    echo "  N (e.g. 8, 16) -> game sees N logical CPUs (N:0..N-1)."
    [ "$MAX_CORES" -gt 0 ] && echo "  (Max on this system: $MAX_CORES logical CPUs)"
    printf "%s" "${YELLOW}CPU visible to game [0]: ${RESET}"
    tty_read val || val=""
    val=$(trim "$val")
    [ -z "$val" ] && val="0"
    case "$val" in
      0)
        echo
        break
        ;;
      *[!0-9]*)
        printf "%s\n\n" "${RED}Enter 0 or a positive number.${RESET}"
        ;;
      *)
        if [ "$MAX_CORES" -gt 0 ] && [ "$val" -gt "$MAX_CORES" ]; then
          printf "%s\n" "${RED}You only have $MAX_CORES logical CPUs.${RESET}"
          printf "%s\n\n" "${RED}Enter 0 or a value from 1 to $MAX_CORES.${RESET}"
        else
          LAUNCH_ENV="$LAUNCH_ENV CPU=$val"
          echo
          break
        fi
        ;;
    esac
  done
  ########################
  # game-performance
  ########################
  echo "${BOLD}GP:${RESET} Wrap command in CachyOS game-performance (if available)."
  if ask_yes_no "${YELLOW}Enable game-performance (GP=1)? [y/n]: ${RESET}"; then
    LAUNCH_ENV="$LAUNCH_ENV GP=1"
  fi
  echo
  # final output
  # map CPU to avoid leading zeros, e.g. CPU=01 -> CPU=1
  LAUNCH_ENV=$(
    printf '%s\n' "$LAUNCH_ENV" \
      | sed -E 's/(^|[[:space:]])CPU=0+([1-9][0-9]*)/\1CPU=\2/g'
  )

  # output-only: prefer unified knob in the generated line
  LAUNCH_ENV=$(
    printf '%s\n' "$LAUNCH_ENV" \
      | sed -E 's/(^|[[:space:]])FSR4_RDNA3=/\1FSR4=/g'
  )

  LAUNCH_ENV=$(trim_outer_ws "$LAUNCH_ENV")

  # detect script path for the generated launch line
  # prefer "genvw" (install name), otherwise print the real script path.

  _this="${BASH_SOURCE[0]:-$0}"
  _this_abs="$(genvw_abspath "$_this" 2>/dev/null || printf '%s' "$_this")"

  if command -v genvw >/dev/null 2>&1; then
    _pv="$(command -v genvw)"
    _pv_abs="$(genvw_abspath "$_pv" 2>/dev/null || printf '%s' "$_pv")"

    # prefer "genvw" ONLY if it points to this same script
    if [ "$_pv_abs" = "$_this_abs" ]; then
      SCRIPT_PATH="genvw"
    else
      SCRIPT_PATH="$_this_abs"
    fi
  else
    SCRIPT_PATH="$_this_abs"
  fi

  # quote SCRIPT_PATH only if needed (POSIX-safe single quotes for Steam/sh -c)
  SCRIPT_PATH_PRINT="$SCRIPT_PATH"
  case "$SCRIPT_PATH_PRINT" in
    *[!A-Za-z0-9_./:-]*)
      SCRIPT_PATH_PRINT=${SCRIPT_PATH_PRINT//\'/\'\\\'\'}
      SCRIPT_PATH_PRINT="'$SCRIPT_PATH_PRINT'"
      ;;
  esac
  printf "%s\n" "${BOLD}${CYAN} === Generated Steam launch options === ${RESET}"
  echo
  if [ -n "$LAUNCH_ENV" ]; then
    printf "%s\n" "${GREEN}$LAUNCH_ENV${RESET} ${ORANGE}$SCRIPT_PATH_PRINT${RESET} ${WHITE}%command%${RESET}"
  else
    printf "%s\n" "${ORANGE}$SCRIPT_PATH_PRINT${RESET} ${WHITE}%command%${RESET}"
  fi
  echo
  info "Copy the line above and paste it into:"
  info "${I_GEAR}  Steam → Properties → General → Launch options"
  echo
  genvw_wizard_offer_profile_save "$LAUNCH_ENV" "$SCRIPT_PATH_PRINT"
  echo
  genvw_wizard_print_steam_compat_reminder
  unset _this _this_abs _pv _pv_abs SCRIPT_PATH SCRIPT_PATH_PRINT
  exit 0
fi

# genvw_route_fsr4_knobs
# takes the user-facing fsr4 knobs and maps them to the PROTON_FSR4_* vars that protonfixes/upscalers reads
# exports env vars

genvw_route_fsr4_knobs() {
  # precedence (most explicit wins):
  # 1) PROTON_FSR4_RDNA3_UPGRADE / PROTON_FSR4_UPGRADE (user set directly)
  # 2) FSR4_RDNA3 (shared RDNA2/RDNA3 knob)
  # 3) FSR4 (routed by gpu gen: rdna3 => FSR4_RDNA3, rdna4 => keep FSR4)
  local gen rdna3_knob_allowed gpu_label

  gen="$(detect_rdna_gen)"
  rdna3_knob_allowed=0
  case "$gen" in
    2 | 3) rdna3_knob_allowed=1 ;;
  esac
  case "$gen" in
    2) gpu_label="RDNA2" ;;
    3) gpu_label="RDNA3/3.5" ;;
    4) gpu_label="RDNA4" ;;
    *) gpu_label="unknown GPU class" ;;
  esac

  # RDNA3-style knobs are shared with RDNA2 by design.
  # On other GPU classes, drop them so they cannot override global routing.
  if [[ "$rdna3_knob_allowed" -ne 1 ]]; then
    if [[ -n "${PROTON_FSR4_RDNA3_UPGRADE:-}" ]]; then
      warn "gENVW: ignoring PROTON_FSR4_RDNA3_UPGRADE on ${gpu_label}; this knob is for RDNA2/RDNA3 only." >&2
      unset PROTON_FSR4_RDNA3_UPGRADE
    fi
    if [[ -n "${FSR4_RDNA3:-}" ]]; then
      warn "gENVW: ignoring FSR4_RDNA3 on ${gpu_label}; this knob is for RDNA2/RDNA3 only." >&2
      unset FSR4_RDNA3
    fi
  fi

  # if the user set PROTON_FSR4_* directly, leave it alone
  # PROTON_FSR4_* is the direct path; don't mix it with the gENVW knobs

  if [ -n "${PROTON_FSR4_RDNA3_UPGRADE:-}" ] || [ -n "${PROTON_FSR4_UPGRADE:-}" ] || [ -n "${PROTON_FSR4_LOCAL:-}" ]; then
    if [ -n "${FSR4_RDNA3:-}" ] || [ -n "${FSR4:-}" ]; then
      err "gENVW: FSR4 conflict: choose either FSR4/FSR4_RDNA3 OR PROTON_FSR4_* (not both)."
      msg "gENVW knobs: FSR4=${FSR4-(unset)} FSR4_RDNA3=${FSR4_RDNA3-(unset)}"
      msg "PROTON overrides: PROTON_FSR4_UPGRADE=${PROTON_FSR4_UPGRADE-(unset)} PROTON_FSR4_RDNA3_UPGRADE=${PROTON_FSR4_RDNA3_UPGRADE-(unset)} PROTON_FSR4_LOCAL=${PROTON_FSR4_LOCAL-(unset)}"
      msg "Fix:"
      msg "  - Use gENVW knobs: unset PROTON_FSR4_UPGRADE PROTON_FSR4_RDNA3_UPGRADE PROTON_FSR4_LOCAL"
      msg "  - Use PROTON overrides: unset FSR4 FSR4_RDNA3"
      msg "Hint: Steam Launch Options may contain stale PROTON_FSR4_* exports."
      return 2
    fi

    # Direct PROTON overrides: bad text values are normalized by GPU class.
    # Wrapper knobs stay strict.
    # direct PROTON overrides: normalize invalid values to safe defaults by GPU class
    local _direct_norm="" _gpu_label=""
    _direct_norm="$(genvw_fsr4_default_remote_for_gen "$gen")"
    case "$gen" in
      2) _gpu_label="RDNA2" ;;
      3) _gpu_label="RDNA3/3.5" ;;
      4) _gpu_label="RDNA4" ;;
      *) _gpu_label="unknown GPU class" ;;
    esac

    if [ -n "${PROTON_FSR4_RDNA3_UPGRADE:-}" ]; then
      if ! genvw_fsr4_is_knob_allowed "${PROTON_FSR4_RDNA3_UPGRADE}"; then
        warn "gENVW: invalid PROTON_FSR4_RDNA3_UPGRADE='${PROTON_FSR4_RDNA3_UPGRADE}' for ${_gpu_label}; normalizing to ${_direct_norm}." >&2
        msg "Allowed direct values: $(genvw_fsr4_allowed_versions_csv)" >&2
        export PROTON_FSR4_RDNA3_UPGRADE="${_direct_norm}"
      fi
    fi

    if [ -n "${PROTON_FSR4_UPGRADE:-}" ]; then
      if ! genvw_fsr4_is_knob_allowed "${PROTON_FSR4_UPGRADE}"; then
        warn "gENVW: invalid PROTON_FSR4_UPGRADE='${PROTON_FSR4_UPGRADE}' for ${_gpu_label}; normalizing to ${_direct_norm}." >&2
        msg "Allowed direct values: $(genvw_fsr4_allowed_versions_csv)" >&2
        export PROTON_FSR4_UPGRADE="${_direct_norm}"
      fi
    fi

    unset FSR4_RDNA3 FSR4
    return 0
  fi

  # rdna3 knob wins; if it is set, ignore the unified knob
  if [ -n "${FSR4_RDNA3:-}" ]; then
    unset FSR4
    return 0
  fi

  # unified knob: on rdna3/3.5, map FSR4=... to FSR4_RDNA3=...
  # FSR4=0/off stays as-is (no mapping)
  if [ -n "${FSR4:-}" ] && [ "$gen" = "3" ]; then
    case "$FSR4" in
      "" | 0 | off | OFF) ;;
      *)
        # keep the original value for later error text (not exported)
        FSR4_UNIFIED_INPUT="$FSR4"
        export FSR4_RDNA3="$FSR4"
        unset FSR4
        ;;
    esac
  fi
  return 0
}

###############################################################################
# NORMAL WRAPPER MODE (used by Steam) – non-interactive
###############################################################################
# genvw: consume leading KEY=VALUE args (so "genvw FOO=1 %command%" works)
# example: genvw FSR4=1 HDR=1 %command%
while [ "$#" -gt 0 ]; do
  # allow explicit terminator
  if [ "$1" = "--" ]; then
    shift
    break
  fi
  # stop on flags/options (command starts here)
  case "$1" in
    -*) break ;;
  esac
  # only treat plain VAR=... tokens as env assignments
  if [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
    if ! export "$1"; then
      err "Invalid env assignment: $1"
      exit 2
    fi
    shift
    continue
  fi
  break
done

# only assignments given -> stop here with a hint
if [ "$#" -eq 0 ]; then
  err "gENVW: no command provided. If you meant to wrap a game, use: genvw %command%"
  msg "Tip: You can prepend env like: HDR=1 FSR4=1 genvw %command%"
  exit 2
fi

genvw_require_supported_gpu || exit $?
genvw_route_fsr4_knobs || exit $?

# fsr4 knob mapping:
#   FSR4_RDNA3=... -> rdna2/rdna3 (PROTON_FSR4_RDNA3_UPGRADE)
#   FSR4=...       -> rdna4/global (PROTON_FSR4_UPGRADE)

# hdr toggle
if [ "${HDR:-0}" = "1" ]; then
  genvw_hdr_warn_runtime_if_unsupported
  export PROTON_ENABLE_WAYLAND=1
  if ! genvw_proton_policy_omits_proton_enable_hdr; then
    export PROTON_ENABLE_HDR=1
  fi
  export DXVK_HDR=1
  if genvw_should_export_hdr_wsi; then
    export ENABLE_HDR_WSI=1
  fi
fi

# rdna3 / rdna3.5 fsr4 (FSR4_RDNA3=...)
# accepted:
#   0/off         -> disable
#   1             -> default (maps to policy default for RDNA3)
#   allowed list  -> pin an exact version
if [ -n "${FSR4_RDNA3:-}" ]; then
  case "$FSR4_RDNA3" in
    "" | 0 | off | OFF) ;;
    1)
      export PROTON_FSR4_RDNA3_UPGRADE="$(genvw_fsr4_default_remote_for_gen 3)"
      ;;
    *)
      if genvw_fsr4_is_knob_allowed "$FSR4_RDNA3"; then
        export PROTON_FSR4_RDNA3_UPGRADE="$FSR4_RDNA3"
      else
        if [ -n "${FSR4_UNIFIED_INPUT:-}" ]; then
          err "gENVW: Invalid FSR4 value: $FSR4_UNIFIED_INPUT"
        else
          err "gENVW: Invalid FSR4_RDNA3 value: $FSR4_RDNA3"
        fi
        msg "Allowed: 0/off, 1, or $(genvw_fsr4_allowed_versions_slash)" >&2
        exit 1
      fi
      ;;
  esac
fi

# rdna4/global fsr4 (FSR4=...)
# accepted:
#   0/off         -> disable
#   1             -> default (maps to policy default for detected GPU)
#   allowed list  -> pin an exact version
_fsr4_global_default="$(genvw_fsr4_default_remote_for_gen "$(detect_rdna_gen 2>/dev/null || printf '0')")"
if [ -n "${FSR4:-}" ]; then
  case "$FSR4" in
    "" | 0 | off | OFF) ;;
    1)
      export PROTON_FSR4_UPGRADE="${_fsr4_global_default}"
      ;;
    *)
      if genvw_fsr4_is_knob_allowed "$FSR4"; then
        export PROTON_FSR4_UPGRADE="$FSR4"
      else
        err "gENVW: Invalid FSR4 value: $FSR4"
        msg "Allowed: 0/off, 1, or $(genvw_fsr4_allowed_versions_slash)" >&2
        exit 1
      fi
      ;;
  esac
fi
unset _fsr4_global_default

# patched gENVW upscalers.py uses the selected PROTON_FSR4_* version directly.
# keep wrapper runtime policy version-first and only accept PROTON_FSR4_LOCAL as
# a narrow legacy input that canonicalizes into the selected version.
unset GENVW_FSR4_REMOTE_FALLBACK
genvw_fsr4_apply_legacy_local_input || exit $?

# local fsr4 trust gate:
# settle the final selected FSR4 path before applying MLFG policy.
genvw_fsr4_integrity_guard || exit $?

# mlfg toggle (ML frame gen)
# public knob: MLFG=0|1
# internal knob: MLFG_UPGRADE=0|1
# runtime only enables MLFG on trusted local-only FSR4 selections.
genvw_apply_mlfg_runtime_policy || exit $?

# wine fullscreen fsr (ffsr), sdr only
genvw_normalize_gamescope_knobs
genvw_normalize_mon_knob
if [ -n "${MON:-}" ]; then
  export WAYLANDDRV_PRIMARY_MONITOR="$MON"
fi

_runtime_fsr4_ver="$(genvw_fsr4_guess_selected_ver)"

# fsr4/mlfg indicator toggle
if [ "${FSR4SHOW:-0}" = "1" ]; then
  if [ -n "${_runtime_fsr4_ver:-}" ]; then
    export PROTON_FSR4_INDICATOR=1
  else
    warn "gENVW: FSR4SHOW ignored — FSR4 is not active."
  fi
fi

if [ -n "${GSFSR:-}" ] && [ "${GSFSR:-0}" != "0" ] && [ -n "${_runtime_fsr4_ver:-}" ]; then
  warn "gENVW: Gamescope upscaler disabled — FSR4 (${_runtime_fsr4_ver}) is already active."
  msg "    Using both would double-upscale the frame."
  GSFSR=0
  unset GSSHARP
  unset GSRES
fi

if [ "${HDR:-0}" != "1" ] && [ -n "${FFSR:-}" ] && [ "$FFSR" != "0" ]; then
  if [ -n "${_runtime_fsr4_ver:-}" ]; then
    warn "gENVW: FFSR disabled — FSR4 (${_runtime_fsr4_ver}) is already active."
    msg "    Using both would double-upscale the frame."
    FFSR=0
  fi

  if [ -n "${FFSR:-}" ] && [ "$FFSR" != "0" ] && [ -n "${GSFSR:-}" ] && [ "${GSFSR:-0}" != "0" ]; then
    warn "gENVW: FFSR disabled — Gamescope upscaler (GSFSR=${GSFSR}) is already active."
    msg "    Using both would double-upscale the frame."
    FFSR=0
  fi

  if [ -n "${FFSR:-}" ] && [ "$FFSR" != "0" ]; then
    genvw_ffsr_warn_if_native_wayland_noop
    export WINE_FULLSCREEN_FSR=1
    case "$FFSR" in
      '' | *[!0-9]*) ;;
      1) ;;
      *)
        export WINE_FULLSCREEN_FSR_STRENGTH="$FFSR"
        ;;
    esac
  fi
fi

# debug / logging knobs (noisy)
if [ "${DEBUG:-0}" = "1" ]; then
  export PROTON_LOG=1
  export WINEDEBUG=-all
  export DXVK_LOG_LEVEL=debug
  export VKD3D_DEBUG=warn
  if [ -n "${_runtime_fsr4_ver:-}" ]; then
    export PROTON_FSR4_INDICATOR=1
  fi
fi
unset _runtime_fsr4_ver

# version-aware DXVK translation
genvw_apply_gplasync || exit 1
genvw_apply_lll
if [ -z "${GPLASYNC:-}" ] || [ "${GPLASYNC}" = "0" ]; then
  if [ "${ASYNC:-0}" = "1" ]; then
    export DXVK_ASYNC=1
  fi
fi

# lossless scaling frame generation
genvw_apply_lsfg

# directdraw / d3d1-7 via d7vk (env name is build-date-dependent)
if [ -n "${D7VK:-}" ]; then
  case "$D7VK" in
    0 | 1) ;;
    *)
      err "gENVW: Invalid D7VK value: $D7VK"
      msg "Allowed: 0 or 1" >&2
      exit 1
      ;;
  esac
  if [ "$D7VK" = "1" ]; then
    genvw_dxvk_resolve_target
    _d7vk_bdate="${GENVW_DXVK_TARGET_BUILD_DATE:-}"
    if [[ -z "$_d7vk_bdate" || ! "$_d7vk_bdate" =~ ^[0-9]{8}$ ]]; then
      err "gENVW: D7VK requires a resolved Proton-CachyOS build date."
      msg "Allowed:" >&2
      msg "  - launch from Steam through genvw" >&2
      msg "  - set GENVW_PROTON_BUILD_DATE=YYYYMMDD" >&2
      msg "  - set GENVW_PROTON_TOOL_ROOT=/path/to/proton-cachyos-..." >&2
      exit 1
    elif ((10#$_d7vk_bdate < 10#20260102)); then
      err "gENVW: D7VK not available before 20260102 (detected: ${_d7vk_bdate})."
      exit 1
    elif ((10#$_d7vk_bdate <= 10#20260226)); then
      export PROTON_DXVK_DDRAW=1
    else
      export PROTON_D7VK_DDRAW=1
    fi
    unset _d7vk_bdate
  fi
fi

if [ -n "${NODXR:-}" ]; then
  case "$NODXR" in
    0 | 1) ;;
    *)
      err "gENVW: Invalid NODXR value: $NODXR"
      msg "Allowed: 0 or 1" >&2
      exit 1
      ;;
  esac
fi

if [ -n "${FORCEDXR:-}" ]; then
  case "$FORCEDXR" in
    0 | 1 | 12) ;;
    *)
      err "gENVW: Invalid FORCEDXR value: $FORCEDXR"
      msg "Allowed: 0, 1, or 12" >&2
      exit 1
      ;;
  esac
fi

if [ "${NODXR:-0}" = "1" ] && [ -n "${FORCEDXR:-}" ] && [ "${FORCEDXR:-0}" != "0" ]; then
  warn "gENVW: NODXR=1 ignored — FORCEDXR=${FORCEDXR} takes priority."
fi

# FORCEDXR intentionally wraps only the official vkd3d-proton path:
# - FORCEDXR=1  -> VKD3D_CONFIG=dxr
# - FORCEDXR=12 -> VKD3D_CONFIG=dxr,dxr12
# Upstream-documented workarounds
# examples include NVAPI force-enable for NVAPI-gated titles (DXVK-NVAPI was
# originally developed for Assetto Corsa Competizione), non-NVIDIA vendor spoofing
# via DXVK_CONFIG + DXVK_NVAPI_ALLOW_OTHER_DRIVERS, GPU-arch spoofing used for
# Ghost of Tsushima, and driver-version spoofing used for War Thunder, XDefiant,
# Cyberpunk 2077, The Last of Us Part 1, and Hellblade VR. Those are title-specific
# troubleshooting levers, not stable wrapper semantics.
# Sources:
# https://github.com/HansKristian-Work/vkd3d-proton#environment-variables
# https://github.com/HansKristian-Work/vkd3d-proton/releases/tag/v2.11
# https://github.com/jp7677/dxvk-nvapi#steam-play--proton
# https://github.com/jp7677/dxvk-nvapi#non-nvidia-gpu
# https://github.com/jp7677/dxvk-nvapi/releases/tag/v0.6.3
# https://github.com/jp7677/dxvk-nvapi/releases/tag/v0.7.1
if [ -n "${FORCEDXR:-}" ] && [ "${FORCEDXR}" != "0" ]; then
  genvw_vkd3d_config_remove_flags nodxr dxr dxr12
  genvw_vkd3d_config_append_flag dxr
  if [ "${FORCEDXR}" = "12" ]; then
    genvw_vkd3d_config_append_flag dxr12
  fi
elif [ "${NODXR:-0}" = "1" ]; then
  genvw_vkd3d_config_remove_flags nodxr dxr dxr12
  genvw_vkd3d_config_append_flag nodxr
fi

# local shader cache toggle
if [ "${LSC:-0}" = "1" ]; then
  export PROTON_LOCAL_SHADER_CACHE=1
fi

# no wm decoration toggle (borderless-ish window)
if [ "${NVMD:-0}" = "1" ]; then
  export PROTON_NO_WM_DECORATION=1
fi

# ntsync toggle
if genvw_proton_policy_uses_proton_no_ntsync; then
  if [ -n "${PROTON_USE_NTSYNC+x}" ]; then
    if [ "${PROTON_USE_NTSYNC:-}" = "0" ]; then
      export PROTON_NO_NTSYNC=1
      warn "gENVW: using PROTON_NO_NTSYNC=1 for Proton-CachyOS 11 NTSYNC disable."
    else
      warn "gENVW: clearing PROTON_USE_NTSYNC for Proton-CachyOS 11; NTSYNC is enabled by default."
    fi
    unset PROTON_USE_NTSYNC
  fi
fi

if [ "${NTS:-0}" = "1" ]; then
  if genvw_proton_policy_uses_proton_no_ntsync; then
    warn "gENVW: NTS=1 ignored; Proton-CachyOS 11 enables NTSYNC by default."
  else
    export PROTON_USE_NTSYNC=1
  fi
fi

# cpu topology (CPU= sets first N logical cpus)
if [ -n "${CPU:-}" ]; then
  case "$CPU" in
    '' | *[!0-9]*) ;;
    *)
      count="$CPU"
      if [ "$count" -gt 0 ]; then
        cpu_cap="$(genvw_detect_max_logical_cpus)"
        if [ "$cpu_cap" -gt 0 ] && [ "$count" -gt "$cpu_cap" ]; then
          count="$cpu_cap"
        fi
        i=0
        cpu_list=""
        while [ "$i" -lt "$count" ]; do
          if [ -z "$cpu_list" ]; then
            cpu_list="$i"
          else
            cpu_list="$cpu_list,$i"
          fi
          i=$((i + 1))
        done
        export WINE_CPU_TOPOLOGY="${count}:${cpu_list}"
      fi
      ;;
  esac
fi

# stop literal Steam placeholders before wrapper helpers turn them into noisy errors.
if [ "${1:-}" = "%command%" ]; then
  echo "gENVW: no real game command was provided." >&2
  echo "Use 'genvw %command%' only in Steam Launch options." >&2
  echo "From a terminal, run: genvw /path/to/game.exe" >&2
  exit 2
fi

# wrap command in gamescope when requested
if [ "${GS:-0}" = "1" ]; then
  if genvw_have_gamescope; then
    _gs_args=()
    if [ "${HDR:-0}" = "1" ]; then
      _gs_args+=(--hdr-enabled)
    fi
    if [ "${GSFULL:-0}" = "1" ]; then
      _gs_args+=(-f)
    fi
    if [ "${GSGRAB:-0}" = "1" ]; then
      _gs_args+=(--force-grab-cursor)
    fi

    _gs_target_line="$(genvw_gamescope_target_monitor_line "${MON:-}")" || _gs_target_line=""
    _gs_target_conn="${MON:-}"
    _gs_target_res=""
    if [ -n "$_gs_target_line" ]; then
      IFS=$'\t' read -r _gs_mon_conn _gs_mon_model _gs_mon_res _gs_mon_rate _gs_mon_hdr _gs_mon_size _gs_mon_pri <<<"$_gs_target_line"
      [ -n "$_gs_target_conn" ] || _gs_target_conn="$_gs_mon_conn"
      _gs_target_res="$(genvw_monitor_resolution_base "$_gs_mon_res" || true)"
      unset _gs_mon_conn _gs_mon_model _gs_mon_res _gs_mon_rate _gs_mon_hdr _gs_mon_size _gs_mon_pri
    fi

    if [ -n "$_gs_target_res" ] && [[ "$_gs_target_res" =~ ^([1-9][0-9]*)x([1-9][0-9]*)$ ]]; then
      _gs_args+=(-W "${BASH_REMATCH[1]}" -H "${BASH_REMATCH[2]}")
    else
      warn "gENVW: Gamescope output resolution could not be determined; gamescope may default to 1280x720."
      if [ -n "${MON:-}" ]; then
        msg "    Tip: verify MON=${MON} resolves to a detected monitor."
      else
        msg "    Tip: set MON=DP-1 (or similar) for a known output target."
      fi
    fi

    case "${GSFSR:-0}" in
      ''|0) ;;
      fsr|nis|pixel)
        _gs_args+=(--filter "$GSFSR")
        ;;
    esac

    if [ -n "${GSSHARP:-}" ] && genvw_gamescope_filter_supports_sharpness "${GSFSR:-0}"; then
      _gs_args+=(--sharpness "$GSSHARP")
    fi

    if [ -n "${GSRES:-}" ]; then
      _gs_w="${GSRES%%x*}"
      _gs_h="${GSRES##*x}"
      _gs_args+=(-w "$_gs_w" -h "$_gs_h")
      unset _gs_w _gs_h
    fi

    if [ -n "$_gs_target_conn" ]; then
      _gs_args+=(--prefer-output "$_gs_target_conn")
    fi

    set -- gamescope "${_gs_args[@]}" -- "$@"
    unset _gs_args _gs_target_line _gs_target_conn _gs_target_res
  else
    warn "gENVW: GS=1 requested but gamescope is not installed; continuing without Gamescope."
  fi
fi

# wrap command in game-performance when requested (cachyos helper)
if [ "${GP:-0}" = "1" ] && command -v game-performance >/dev/null 2>&1; then
  set -- game-performance "$@"
fi

# optional debug dump (prints what we ended up exporting + final command)
if [ "${GENVW_DEBUG:-0}" = "1" ]; then
  echo "gENVW debug: effective environment and command:" >&2
  [ -n "${GENVW_ACTIVE_PROFILE:-}" ] && echo "  Profile: ${GENVW_ACTIVE_PROFILE}" >&2
  for var in \
    PROTON_ENABLE_WAYLAND PROTON_USE_WAYLAND PROTON_PREFER_SDL PROTON_USE_SDL \
    PROTON_ENABLE_HDR DXVK_HDR ENABLE_HDR_WSI \
    WAYLANDDRV_PRIMARY_MONITOR \
    PROTON_FSR4_RDNA3_UPGRADE PROTON_FSR4_UPGRADE PROTON_FSR4_LOCAL PROTON_FSR4_INDICATOR \
    MLFG_UPGRADE \
    WINE_FULLSCREEN_FSR WINE_FULLSCREEN_FSR_STRENGTH \
    MANGOHUD \
    PROTON_LOG WINEDEBUG DXVK_LOG_LEVEL VKD3D_DEBUG VKD3D_CONFIG \
    PROTON_DXVK_GPLASYNC PROTON_DXVK_LLASYNC PROTON_DXVK_LOWLATENCY DXVK_FRAME_PACE DXVK_CONFIG \
    LOW_LATENCY_LAYER LOW_LATENCY_LAYER_REFLEX DXVK_NVAPI_VKREFLEX \
    PROTON_DXVK_DDRAW PROTON_D7VK_DDRAW \
    LSFG_LEGACY LSFG_MULTIPLIER LSFG_FLOW_SCALE LSFG_PERFORMANCE_MODE \
    LSFG_HDR_MODE LSFG_EXPERIMENTAL_PRESENT_MODE \
    DXVK_ASYNC PROTON_LOCAL_SHADER_CACHE PROTON_NO_WM_DECORATION \
    PROTON_USE_NTSYNC PROTON_NO_NTSYNC WINE_CPU_TOPOLOGY; do
    val="${!var-}"
    if [ -n "$val" ]; then
      echo "  $var=$val" >&2
    fi
  done
  genvw_dxvk_resolve_target
  echo "  DXVK policy=${GENVW_DXVK_TARGET_POLICY:-unknown_or_unsupported} expected=${GENVW_DXVK_TARGET_EXPECTED_POLICY:-unknown_or_unsupported} reason=${GENVW_DXVK_TARGET_REASON:-unresolved} build_date=${GENVW_DXVK_TARGET_BUILD_DATE:-}" >&2
  [ -n "${GENVW_DXVK_TARGET_WARN:-}" ] && echo "  DXVK policy note=${GENVW_DXVK_TARGET_WARN}" >&2
  echo "  GS=${GS:-0} MON=${MON:-} GSFULL=${GSFULL:-0} GSGRAB=${GSGRAB:-0} GSFSR=${GSFSR:-0} GSSHARP=${GSSHARP:-} GSRES=${GSRES:-} D7VK=${D7VK:-0} NODXR=${NODXR:-0} FORCEDXR=${FORCEDXR:-0} GPLASYNC=${GPLASYNC:-} LSFG=${LSFG:-0} LSFGPERF=${LSFGPERF:-0} LSFGFLOW=${LSFGFLOW:-} LSFGPRESENT=${LSFGPRESENT:-} LSFGHDR=${LSFGHDR:-} GP=${GP:-0} GM=${GM:-0}" >&2
  echo "  Command: $*" >&2
  printf "  Command(q):" >&2
  printf ' %q' "$@" >&2
  printf "\n" >&2
  if [ -n "${MON:-}" ] || [ "${GENVW_DEBUG:-0}" = "1" ]; then
    echo "  Detected monitors:" >&2
    genvw_detect_monitors 2>/dev/null | while IFS=$'\t' read -r _dc _dm _dr _drr _dh _ds _dp; do
      echo "    $_dc  $_dm  ${_dr}@${_drr}Hz  HDR=$_dh  ${_ds}mm  pri=$_dp" >&2
    done
  fi
fi

# gamemode wrapper
if [ "${GM:-0}" = "1" ] && command -v gamemoderun >/dev/null 2>&1; then
  exec gamemoderun "$@"
else
  exec "$@"
fi

# end of genvw
