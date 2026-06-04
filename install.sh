#!/bin/sh
set -eu

prog=${0##*/}

usage() {
  cat <<USAGE
Usage: ./$prog [options]

Install the gENVW launcher bundle. Run from the directory containing:
  genvw
  genvw.sh
  genvw_proton.sh
  genvw_fsr4_policy.sh

Options:
  --prefix DIR      Install under DIR/bin (default: HOME/.local, or /usr/local as root)
  --bindir DIR      Install all four runtime files directly into DIR
  --user            Use HOME/.local/bin
  --system          Use /usr/local/bin
  --destdir DIR     Stage under DIR while preserving the absolute target layout
  --dry-run         Print actions without changing files
  --uninstall       Remove the four installed runtime files from the target directory
  --help            Show this help

Environment:
  PREFIX            Same as --prefix when --bindir is not set
  BINDIR            Same as --bindir
  DESTDIR           Same as --destdir
USAGE
}

fail() {
  printf '%s: %s\n' "$prog" "$*" >&2
  exit 1
}

info() {
  printf '%s\n' "$*"
}

is_root() {
  uid=$(id -u 2>/dev/null || printf '1')
  [ "$uid" = "0" ]
}

src_dir=${0%/*}
if [ "$src_dir" = "$0" ]; then
  src_dir=.
fi
src_dir=$(CDPATH= cd "$src_dir" 2>/dev/null && pwd -P) || fail "cannot resolve script directory"

prefix=${PREFIX:-}
bindir=${BINDIR:-}
destdir=${DESTDIR:-}
dry_run=0
uninstall=0

if [ -z "$prefix" ]; then
  if is_root; then
    prefix=/usr/local
  else
    : "${HOME:?HOME is not set}"
    prefix=$HOME/.local
  fi
fi

while [ "$#" -gt 0 ]; do
  case "$1" in
    --prefix)
      [ "$#" -ge 2 ] || fail "--prefix requires a directory"
      prefix=$2
      bindir=
      shift 2
      ;;
    --prefix=*)
      prefix=${1#--prefix=}
      bindir=
      shift
      ;;
    --bindir)
      [ "$#" -ge 2 ] || fail "--bindir requires a directory"
      bindir=$2
      shift 2
      ;;
    --bindir=*)
      bindir=${1#--bindir=}
      shift
      ;;
    --destdir)
      [ "$#" -ge 2 ] || fail "--destdir requires a directory"
      destdir=$2
      shift 2
      ;;
    --destdir=*)
      destdir=${1#--destdir=}
      shift
      ;;
    --user)
      : "${HOME:?HOME is not set}"
      prefix=$HOME/.local
      bindir=
      shift
      ;;
    --system)
      prefix=/usr/local
      bindir=
      shift
      ;;
    --dry-run|-n)
      dry_run=1
      shift
      ;;
    --uninstall)
      uninstall=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      fail "unknown option: $1"
      ;;
  esac
done

[ -n "$bindir" ] || bindir=$prefix/bin

case "$bindir" in
  /*) ;;
  *) fail "target bin directory must be absolute: $bindir" ;;
esac

if [ -n "$destdir" ]; then
  case "$destdir" in
    /*) ;;
    *) fail "DESTDIR must be absolute when set: $destdir" ;;
  esac
fi

target_dir=$destdir$bindir

runtime_files='genvw genvw.sh genvw_proton.sh genvw_fsr4_policy.sh'
for f in $runtime_files; do
  [ -f "$src_dir/$f" ] || fail "missing required source file: $src_dir/$f"
  [ -r "$src_dir/$f" ] || fail "source file is not readable: $src_dir/$f"
done

command -v bash >/dev/null 2>&1 || fail "bash is required by the installed scripts"

for f in $runtime_files; do
  bash -n "$src_dir/$f" || fail "syntax check failed: $f"
done

cleanup_tmp() {
  if [ -n "${tmp_paths:-}" ]; then
    for p in $tmp_paths; do
      rm -f "$p" 2>/dev/null || true
    done
  fi
}
tmp_paths=
trap cleanup_tmp EXIT HUP INT TERM

copy_runtime_file() {
  name=$1
  mode=$2
  src=$src_dir/$name
  dst=$target_dir/$name
  tmp=$target_dir/.$name.tmp.$$
  tmp_paths="$tmp_paths $tmp"

  if [ "$dry_run" -eq 1 ]; then
    info "would install $src -> $dst mode $mode"
    return 0
  fi

  cp "$src" "$tmp" || fail "copy failed: $name"
  chmod "$mode" "$tmp" || fail "chmod failed: $name"
  mv -f "$tmp" "$dst" || fail "rename failed: $name"
}

if [ "$uninstall" -eq 1 ]; then
  if [ "$dry_run" -eq 1 ]; then
    for f in $runtime_files; do
      info "would remove $target_dir/$f"
    done
    exit 0
  fi
  for f in $runtime_files; do
    rm -f "$target_dir/$f" || fail "remove failed: $target_dir/$f"
  done
  info "Removed gENVW runtime files from $target_dir"
  exit 0
fi

if [ "$dry_run" -eq 1 ]; then
  info "would create directory $target_dir"
else
  mkdir -p "$target_dir" || fail "cannot create target directory: $target_dir"
fi

copy_runtime_file genvw 0755
copy_runtime_file genvw.sh 0755
copy_runtime_file genvw_proton.sh 0755
copy_runtime_file genvw_fsr4_policy.sh 0644

if [ "$dry_run" -eq 1 ]; then
  info "dry run complete"
  exit 0
fi

[ -x "$target_dir/genvw" ] || fail "installed launcher is not executable"
[ -x "$target_dir/genvw.sh" ] || fail "installed wrapper is not executable"
[ -x "$target_dir/genvw_proton.sh" ] || fail "installed helper is not executable"
[ -r "$target_dir/genvw_fsr4_policy.sh" ] || fail "installed policy is not readable"

"$target_dir/genvw" --version >/dev/null || fail "installed launcher self-check failed"

info "Installed gENVW runtime files to $target_dir"
info "Run: genvw --version"
info "Run: genvw proton --help"

if [ -z "$destdir" ]; then
  case ":${PATH:-}:" in
    *":$bindir:"*) ;;
    *) info "Note: $bindir is not currently in PATH." ;;
  esac
fi
