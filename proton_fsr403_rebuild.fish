# ~/.config/fish/functions/proton_fsr403_rebuild.fish
#
# 🧰 Rebuild Proton-CachyOS clones with a *local* FSR4 4.0.3 amdxcffx64.dll override.
#
# Commands:
#   proton_fsr403_rebuild --help
#   proton_fsr403_rebuild --info
#   proton_fsr403_rebuild --check
#   proton_fsr403_rebuild --clean
#   proton_fsr403_rebuild --dry-run
#   proton_fsr403_rebuild                # rebuild clones for newest detected build date
#   proton_fsr403_rebuild --date 20251222
#   proton_fsr403_rebuild --localdll ~/.cache/fsr4/amdxcffx64-4.0.3.dll
#
# Notes:
# - Excludes already-cloned *-fsr403* folders from source scan (prevents -fsr403-fsr403 duplicates)
# - Uses mktemp patcher files (prevents stdin/one-line flattening bugs)
# - Uses safe rollback: restores backups + deletes broken clone if patch/validate fails
# - fish -n prints NOTHING on success (that’s normal)

functions -e proton_fsr403_rebuild 2>/dev/null

function proton_fsr403_rebuild --description "Rebuild proton-cachyos -fsr403 clones + patch for FSR4 4.0.3 local"
    set -l ctd "$HOME/.local/share/Steam/compatibilitytools.d"
    set -l major "10.0"
    set -l tag " [FSR4 4.0.3 local]"
    set -l localdll_default "$HOME/.cache/fsr4/amdxcffx64-4.0.3.dll"

    argparse \
        'h/help' \
        'info' \
        'check' \
        'clean' \
        'n/dry-run' \
        'd/date=' \
        'localdll=' \
        'major=' \
        -- $argv
    or return 2

    if set -q _flag_major
        set major "$_flag_major"
    end

    set -l localdll "$localdll_default"
    if set -q _flag_localdll
        set localdll "$_flag_localdll"
    end

    if set -q _flag_help
        echo "🧰 proton_fsr403_rebuild"
        echo ""
        echo "Rebuilds Proton-CachyOS clones under:"
        echo "  $ctd"
        echo ""
        echo "Creates clones:"
        echo "  proton-cachyos-$major-<build>-..._v2-fsr403 / v3-fsr403 / v4-fsr403"
        echo ""
        echo "Flags:"
        echo "  --help                 Show help"
        echo "  --info                 Explain + show launch options"
        echo "  --check                Preflight (deps + folders + sources + DLL) + install advice"
        echo "  --clean                Remove existing *-fsr403 clones (and duplicates)"
        echo "  --dry-run              Show what would happen (no changes)"
        echo "  --date YYYYMMDD        Use a specific build date (e.g. 20251222)"
        echo "  --localdll PATH        Local amdxcffx64.dll (default: $localdll_default)"
        echo "  --major VER            Proton major (default: 10.0)"
        return 0
    end

    if set -q _flag_info
        echo "ℹ️  What this does"
        echo "  ✅ Finds Proton-CachyOS tools: proton-cachyos-$major-<date>-..._v*"
        echo "  ✅ Clones newest v2/v3/v4 into: ..._v2-fsr403 / ..._v3-fsr403 / ..._v4-fsr403"
        echo "  ✅ Patches protonfixes/upscalers.py to add FSR4 4.0.3 local option"
        echo "  ✅ Patches compatibilitytool.vdf so Steam lists clones separately"
        echo ""
        echo "🧩 Env vars for FSR4 4.0.3 local:"
        echo "  # RDNA4 (FSR4 standard path):"
        echo "  PROTON_FSR4_UPGRADE=4.0.3"
        echo ""
        echo "  # RDNA3 / RDNA3.5 (FSR4 RDNA3 path):"
        echo "  PROTON_FSR4_RDNA3_UPGRADE=4.0.3"
        echo ""
        echo "  # Local DLL (required for BOTH):"
        echo "  PROTON_FSR4_403_LOCAL=\"$localdll\""
        echo ""
        echo "🧪 Quick validation (optional):"
        echo "  👁️  Add: PROTON_FSR4_INDICATOR=1"
        echo ""
        echo "🎮 Launch options examples:"
        echo "  ⚠️  Set ONLY ONE: PROTON_FSR4_UPGRADE or PROTON_FSR4_RDNA3_UPGRADE (not both)."
        echo ""
        echo "  🟦 Minimal RDNA3/RDNA3.5:"
        echo "    PROTON_FSR4_RDNA3_UPGRADE=4.0.3 PROTON_FSR4_403_LOCAL=\"$localdll\" game-performance %command%"
        echo ""
        echo "  🟦 Minimal RDNA4:"
        echo "    PROTON_FSR4_UPGRADE=4.0.3 PROTON_FSR4_403_LOCAL=\"$localdll\" game-performance %command%"
        echo ""
        echo "  🐙 With gENVW (optional wrapper):"
        echo "    https://github.com/furbakka/gENVW"
        echo "    HDR=1 LSC=1 NVMD=1 NTS=1 GP=1 PROTON_FSR4_INDICATOR=1 PROTON_FSR4_RDNA3_UPGRADE=4.0.3 PROTON_FSR4_403_LOCAL=\"$localdll\" genvw %command%"
        return 0
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Preflight helper: used by --check and enforced for normal runs
    # ─────────────────────────────────────────────────────────────────────────
    function __pfr_preflight --no-scope-shadowing
        argparse 's/silent' -- $argv
        or return 2

        set -l silent 0
        if set -q _flag_silent
            set silent 1
        end

        set -l ok 1

        # Commands we rely on
        set -l req_cmds fd rg python3 mktemp stat math cp rm basename sort printf
        set -l miss_pkgs

        function __add_pkg --no-scope-shadowing
            set -l p $argv[1]
            if test -n "$p"
                contains -- $p $miss_pkgs; or set -a miss_pkgs $p
            end
        end

        if test $silent -eq 0
            echo "🧪 proton_fsr403_rebuild --check"
            echo ""
            echo "🧰 Tools:"
        end

        for c in $req_cmds
            if type -q $c
                test $silent -eq 0; and echo "  ✅ $c"
            else
                test $silent -eq 0; and echo "  ❌ $c"
                set ok 0
                switch $c
                    case fd
                        __add_pkg fd
                    case rg
                        __add_pkg ripgrep
                    case python3
                        __add_pkg python
                    case mktemp stat cp rm basename sort printf
                        __add_pkg coreutils
                end
            end
        end

        if test $silent -eq 0
            echo ""
            echo "📁 Folders:"
        end

        if test -d "$ctd"
            test $silent -eq 0; and echo "  ✅ Steam compat tools dir: $ctd"
            if test -w "$ctd"
                test $silent -eq 0; and echo "  ✅ Writable: $ctd"
            else
                test $silent -eq 0; and echo "  ❌ Not writable: $ctd"
                set ok 0
            end
        else
            test $silent -eq 0; and echo "  ❌ Missing: $ctd"
            set ok 0
        end

        if test $silent -eq 0
            echo ""
            echo "🧩 Local DLL:"
        end

        if test -f "$localdll"
            set -l sz (stat -c %s "$localdll" 2>/dev/null)
            if test -n "$sz"; and test "$sz" -ge 1024
                if test $silent -eq 0
                    echo "  ✅ $localdll  ("(math -s0 "$sz/1024/1024")" MiB)"
                end
            else
                test $silent -eq 0; and echo "  ❌ DLL exists but looks too small/broken: $localdll"
                set ok 0
            end
        else
            test $silent -eq 0; and echo "  ❌ Missing: $localdll"
            set ok 0
        end

        # Sources + required files in sources
        if test $silent -eq 0
            echo ""
            echo "📦 Proton-CachyOS sources:"
        end

        set -l sources
        set -l build_date ""
        set -l picked

        if test -d "$ctd"; and type -q fd; and type -q sort; and type -q basename
            set -l raw (fd -HI -a -t d --max-depth 1 --glob "proton-cachyos-$major-*" "$ctd" | sort)
            for d in $raw
                set -l b (basename "$d")
                if string match -q '*-fsr403*' -- "$b"
                    continue
                end
                set -a sources "$d"
            end
        end

        if test (count $sources) -eq 0
            test $silent -eq 0; and echo "  ❌ None found matching: proton-cachyos-$major-* (excluding *-fsr403*)"
            test $silent -eq 0; and echo "     Tip: install Proton-CachyOS or place it into: $ctd"
            set ok 0
        else
            test $silent -eq 0; and echo "  ✅ Found "(count $sources)" source folders"

            # Resolve build date: prefer --date, else newest detected YYYYMMDD
            if set -q _flag_date
                set build_date "$_flag_date"
                test $silent -eq 0; and echo "  ℹ️  Using requested date: $build_date"
            else
                set -l dates
                for d in $sources
                    set -l b (basename "$d")
                    set -l m (string match -r '[0-9]{8}' -- "$b")
                    if test (count $m) -gt 0
                        set -a dates $m[1]
                    end
                end
                set -l uniq (printf "%s\n" $dates | sort -u)
                if test (count $uniq) -eq 0
                    test $silent -eq 0; and echo "  ❌ Could not detect YYYYMMDD build dates in folder names."
                    set ok 0
                else
                    set build_date $uniq[-1]
                    test $silent -eq 0; and echo "  ✅ Detected newest build date: $build_date"
                end
            end

            # Check v2/v3/v4 for chosen date and record the exact picked sources
            if test -n "$build_date"
                set -l have_any 0
                for v in v2 v3 v4
                    set -l candidates
                    for d in $sources
                        set -l b (basename "$d")
                        string match -q "*$build_date*" -- "$b"; or continue
                        string match -q "*_$v" -- "$b"; or continue
                        set -a candidates "$d"
                    end
                    if test (count $candidates) -gt 0
                        set have_any 1
                        set -l sorted (printf "%s\n" $candidates | sort)
                        set -l chosen $sorted[-1]
                        set -a picked "$chosen"
                        test $silent -eq 0; and echo "  ✅ $v source: "(basename "$chosen")

                        # Required files inside that source
                        set -l need_up "$chosen/protonfixes/upscalers.py"
                        set -l need_vdf "$chosen/compatibilitytool.vdf"

                        if test -f "$need_up"
                            test $silent -eq 0; and echo "     ✅ protonfixes/upscalers.py"
                        else
                            test $silent -eq 0; and echo "     ❌ Missing: protonfixes/upscalers.py"
                            set ok 0
                        end

                        if test -f "$need_vdf"
                            test $silent -eq 0; and echo "     ✅ compatibilitytool.vdf"
                        else
                            test $silent -eq 0; and echo "     ❌ Missing: compatibilitytool.vdf"
                            set ok 0
                        end

                        if test -f "$chosen/toolmanifest.vdf"
                            test $silent -eq 0; and echo "     ✅ toolmanifest.vdf"
                        else
                            test $silent -eq 0; and echo "     ⚠ toolmanifest.vdf not present (OK)"
                        end
                    else
                        test $silent -eq 0; and echo "  ❌ $v source: (missing for date $build_date)"
                    end
                end

                if test $have_any -eq 0
                    test $silent -eq 0; and echo "  ❌ No v2/v3/v4 sources found for date: $build_date"
                    set ok 0
                end
            end
        end

        # Final summary + exact picks
        if test $silent -eq 0
            echo ""
            echo "📌 Planned build:"
            if test -n "$build_date"
                if test $ok -eq 1
                    echo "  ✅ Ready to build date: $build_date"
                else
                    echo "  ⚠ Date resolved: $build_date"
                end
            else
                echo "  ❌ No build date resolved"
            end

            if test (count $picked) -gt 0
                echo "  🧱 Will build from these sources:"
                for p in $picked
                    echo "    • "(basename "$p")
                end
            else
                echo "  ❌ No picked sources"
            end
        end

        # Install advice
        if test $silent -eq 0; and test (count $miss_pkgs) -gt 0
            set -l pkgs_sorted (printf "%s\n" $miss_pkgs | sort -u)
            echo ""
            echo "🛠️  Install missing dependencies:"
            if type -q paru
                echo "  paru -S --needed $pkgs_sorted"
            else if type -q yay
                echo "  yay -S --needed $pkgs_sorted"
            else
                echo "  sudo pacman -S --needed $pkgs_sorted"
            end
        end

        if test $silent -eq 0; and not test -f "$localdll"
            echo ""
            echo "🧩 Local DLL missing. Create it first:"
            echo "  amd_fsr4_install --check"
            echo "  amd_fsr4_install --url <AMD_driver_exe_url> --want 4.0.3"
        end

        functions -e __add_pkg 2>/dev/null

        if test $ok -eq 1
            return 0
        end
        return 1
    end

    # ─────────────────────────────────────────────────────────────────────────
    # --check : full preflight + clone list + install advice
    # ─────────────────────────────────────────────────────────────────────────
    if set -q _flag_check
        __pfr_preflight
        set -l rc $status

        echo ""
        echo "📦 Existing clones (*-fsr403*):"
        if test -d "$ctd"; and type -q fd; and type -q sort; and type -q basename
            set -l clones (fd -HI -a -t d --max-depth 1 --glob "proton-cachyos-$major-*-fsr403*" "$ctd" | sort)
            if test (count $clones) -eq 0
                echo "  (none)"
            else
                for d in $clones
                    echo "  • "(basename "$d")
                end
            end
        else
            echo "  ⚠ Skipped clone list (missing tools or folder)."
        end

        echo ""
        if test $rc -eq 0
            echo "✅ Check passed. You can run:"
            echo "  proton_fsr403_rebuild"
        else
            echo "❌ Check failed. Fix the ❌ items above, then re-run:"
            echo "  proton_fsr403_rebuild --check"
        end

        functions -e __pfr_preflight 2>/dev/null
        return $rc
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Enforce preflight for normal runs (but NOT for --clean)
    # ─────────────────────────────────────────────────────────────────────────
    if not set -q _flag_clean
    __pfr_preflight --silent
    or begin
        echo "❌ Preflight failed. Run this for details:"
        echo "  proton_fsr403_rebuild --check"
        functions -e __pfr_preflight 2>/dev/null
        return 1
    end

    # 🛑 STOP if Steam is running (real runs only; dry-run allowed)
    if not set -q _flag_dry_run
        set -l _steam_running 0
        if type -q pgrep
            pgrep -x steam >/dev/null 2>&1; and set _steam_running 1
            pgrep -x steamwebhelper >/dev/null 2>&1; and set _steam_running 1
            pgrep -x steamservice >/dev/null 2>&1; and set _steam_running 1
        else if type -q pidof
            pidof -s steam >/dev/null 2>&1; and set _steam_running 1
            pidof -s steamwebhelper >/dev/null 2>&1; and set _steam_running 1
        end
        if test $_steam_running -eq 1
            echo ""
            echo "🛑 Steam appears to be running."
            echo "   Refusing to rebuild compatibility tools while Steam is open."
            echo ""
            echo "✅ Close Steam, then re-run this command."
            echo "   Suggested shutdown:"
            echo "     steam -shutdown; sleep 2; pkill -TERM steam steamwebhelper 2>/dev/null"
            echo ""
            return 1
        end
    end


    # OPTIONAL: in --dry-run, mention if Steam is running (but don't stop)
    if set -q _flag_dry_run
        set -l _steam_running 0
        if type -q pgrep
            pgrep -x steam >/dev/null 2>&1; and set _steam_running 1
            pgrep -x steamwebhelper >/dev/null 2>&1; and set _steam_running 1
            pgrep -x steamservice >/dev/null 2>&1; and set _steam_running 1
        else if type -q pidof
            pidof -s steam >/dev/null 2>&1; and set _steam_running 1
            pidof -s steamwebhelper >/dev/null 2>&1; and set _steam_running 1
        end

        if test $_steam_running -eq 1
            echo ""
            echo "ℹ️  Steam is running — continuing because this is --dry-run."
            echo "   A real rebuild (without --dry-run) would refuse to proceed."
            echo ""
        end
    end


end

    # ─────────────────────────────────────────────────────────────────────────
    # --clean
    # ─────────────────────────────────────────────────────────────────────────
    if set -q _flag_clean
        if set -q _flag_dry_run
            echo "🧪 Dry run: would remove existing clones under: $ctd"
            set -l doomed (fd -HI -a -t d --max-depth 1 --glob "proton-cachyos-$major-*-fsr403*" "$ctd" | sort)
            if test (count $doomed) -eq 0
                echo "  (none)"
            else
                for d in $doomed
                    echo "  🗑️  "(basename "$d")
                end
            end
            functions -e __pfr_preflight 2>/dev/null
            return 0
        end
        echo "🧹 Removing existing clones under: $ctd"
        set -l doomed (fd -HI -a -t d --max-depth 1 --glob "proton-cachyos-$major-*-fsr403*" "$ctd" | sort)
        if test (count $doomed) -eq 0
            echo "  (none)"
            functions -e __pfr_preflight 2>/dev/null
            return 0
        end
        for d in $doomed
            echo "  🗑️  "(basename "$d")
            rm -rf -- "$d"
        end
        echo "✅ Cleaned."
        functions -e __pfr_preflight 2>/dev/null
        return 0
    end

    echo "🔎 Scanning: $ctd"

    # Gather candidate sources (exclude any existing -fsr403 clones)
    set -l raw (fd -HI -a -t d --max-depth 1 --glob "proton-cachyos-$major-*" "$ctd" | sort)
    set -l sources
    for d in $raw
        set -l b (basename "$d")
        if string match -q '*-fsr403*' -- "$b"
            continue
        end
        set -a sources "$d"
    end

    if test (count $sources) -eq 0
        echo "❌ No Proton-CachyOS sources found for major $major"
        functions -e __pfr_preflight 2>/dev/null
        return 1
    end

    # Determine build date (YYYYMMDD) from folder names
    set -l build_date ""
    if set -q _flag_date
        set build_date "$_flag_date"
    else
        set -l dates
        for d in $sources
            set -l b (basename "$d")
            set -l matches (string match -r '[0-9]{8}' -- "$b")
            if test (count $matches) -gt 0
                set -a dates $matches[1]
            end
        end
        set -l uniq (printf "%s\n" $dates | sort -u)
        if test (count $uniq) -eq 0
            echo "❌ Could not detect build dates in folder names."
            echo "   Tip: run: ls -1 $ctd | rg 'proton-cachyos-$major'"
            functions -e __pfr_preflight 2>/dev/null
            return 1
        end
        set build_date $uniq[-1]
    end

    if test -z "$build_date"
        echo "❌ Build date resolved to empty."
        echo "  Try: proton_fsr403_rebuild --date 20251222"
        functions -e __pfr_preflight 2>/dev/null
        return 1
    end

    echo "📌 Using build date: $build_date"
    echo "📎 Local DLL: $localdll"
    echo ""

    # Pick newest v2/v3/v4 for that build date
    set -l picked
    for v in v2 v3 v4
        set -l candidates
        for d in $sources
            set -l b (basename "$d")
            string match -q "*$build_date*" -- "$b"; or continue
            string match -q "*_$v" -- "$b"; or continue
            set -a candidates "$d"
        end
        if test (count $candidates) -gt 0
            set -l sorted (printf "%s\n" $candidates | sort)
            set -a picked $sorted[-1]
        end
    end

    if test (count $picked) -eq 0
        echo "❌ No sources matched build date $build_date"
        echo "   Try: proton_fsr403_rebuild --date 20251222"
        functions -e __pfr_preflight 2>/dev/null
        return 1
    end

    echo "✅ Sources:"
    for s in $picked
        echo "  • "(basename "$s")
    end
    echo ""

    if set -q _flag_dry_run
        echo "🧪 Dry run: no changes will be made."
        echo ""
        echo "🧾 Plan:"
        for src in $picked
            set -l base (basename "$src")
            set -l dstbase "$base-fsr403"
            set -l dst "$ctd/$dstbase"
            if test -d "$dst"
                echo "  🔁 Would rebuild: $dstbase (remove + copy)"
            else
                echo "  ➕ Would create:  $dstbase"
            end
            echo "     🧩 Would patch: protonfixes/upscalers.py"
            echo "     🧩 Would patch: compatibilitytool.vdf"
        end
        echo ""
        echo "🔁 Then restart Steam to re-scan tools:"
        echo "  steam -shutdown; sleep 2; pkill -TERM steam steamwebhelper 2>/dev/null"
        functions -e __pfr_preflight 2>/dev/null
        return 0
    end

    # ── Python patchers (written to mktemp files) ────────────────────────────
    set -l py_upscaler '
import re
import sys
from pathlib import Path

p = Path(sys.argv[1])
orig = p.read_text(encoding="utf-8")
s = orig

# Add 4.0.3 local entry to __fsr4_dlls
if "4.0.3_local" not in s and "PROTON_FSR4_403_LOCAL" not in s:
    m = re.search(r"(__fsr4_dlls\s*=\s*\{\s*\n)(.*?)(\n\s*\}\s*\n\s*# use the safe option here for now)", s, flags=re.S)
    if not m:
        raise SystemExit("ERROR: Could not find __fsr4_dlls dict block")

    head, body, tail = m.group(1), m.group(2), m.group(3)
    ins = """        # Local-only: user-provided FSR4 4.0.3 DLL (no download)
        "4.0.3": {
            "version": "4.0.3_local",
            "download_url": "local://PROTON_FSR4_403_LOCAL",
            "md5_hash": None,
            "zip_md5_hash": None,
            "local_path_env": "PROTON_FSR4_403_LOCAL",
        },
"""
    new_body = body.rstrip() + "\n" + ins
    s = s[:m.start()] + head + new_body + tail + s[m.end():]

# Inject local DLL copy mode into __download_fsr4
needle = "def __download_fsr4(file: dict, cache: Path, dst: Path) -> None:"
k = s.find(needle)
if k < 0:
    raise SystemExit("ERROR: __download_fsr4 not found")

window = s[k:k+4000]
if "Local DLL mode (FSR4 4.0.3 override)" not in window:
    insert_at = k + len(needle) + 1
    ins = """    # Local DLL mode (FSR4 4.0.3 override)
    local_env = file.get("local_path_env", None)
    if local_env is not None:
        src_str = os.environ.get(local_env, "")
        if not src_str:
            raise RuntimeError(f\'Local DLL env "{local_env}" is not set\')
        src_path = Path(os.path.expandvars(os.path.expanduser(src_str)))
        if (not src_path.is_file()) or src_path.stat().st_size < 1024:
            raise RuntimeError(f\'Local DLL "{src_path}" missing/too small\')
        file["md5_hash"] = hashlib.md5(src_path.read_bytes()).hexdigest().lower()
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(src_path, dst)
        return

"""
    s = s[:insert_at] + ins + s[insert_at:]

if s != orig:
    p.write_text(s, encoding="utf-8")
    print("patched")
else:
    print("no-op")
'

    # Smart VDF patcher:
    # - Supports: "compat_tools" { "BASE" { ... } }  (your format)
    # - Also keeps a fallback for: "compatibilitytool" "BASE"
    set -l py_vdf '
import re
import sys
from pathlib import Path

p = Path(sys.argv[1])
base = sys.argv[2]
dstbase = sys.argv[3]
tag = sys.argv[4]

orig = p.read_text(encoding="utf-8")
text = orig

# Format A: compat_tools key rename (first match only)
pat_key = re.compile(r"(^\s*\")" + re.escape(base) + r"(\")(\s*(?://[^\n]*)?\s*\n\s*\{)", re.M)
text, _ = pat_key.subn(r"\1" + dstbase + r"\2\3", text, count=1)

# Format B: compatibilitytool mapping (fallback; safe no-op if absent)
text = text.replace(f"\"compatibilitytool\" \"{base}\"", f"\"compatibilitytool\" \"{dstbase}\"")

# display_name: replace first value
pat_dn = re.compile(r"(^\s*\"display_name\"\s*\")([^\"]*)(\")", re.M)
def dn_repl(m):
    return m.group(1) + dstbase + tag + m.group(3)
text, _ = pat_dn.subn(dn_repl, text, count=1)

if text != orig:
    p.write_text(text, encoding="utf-8")
    print("patched")
else:
    print("no-op")
'

    set -l t_up (mktemp -t proton_fsr403_upscaler.XXXXXX.py)
    set -l t_vdf (mktemp -t proton_fsr403_vdf.XXXXXX.py)
    printf "%s\n" "$py_upscaler" > "$t_up"; or begin echo "❌ Failed to write $t_up"; rm -f -- "$t_up" "$t_vdf"; functions -e __pfr_preflight 2>/dev/null; return 1; end
    printf "%s\n" "$py_vdf" > "$t_vdf"; or begin echo "❌ Failed to write $t_vdf"; rm -f -- "$t_up" "$t_vdf"; functions -e __pfr_preflight 2>/dev/null; return 1; end

    # Rollback: restore .bak (best effort) + delete clone + abort
    function __rollback --no-scope-shadowing
        set -l reason "$argv[1]"
        set -l dst "$argv[2]"
        set -l dstbase "$argv[3]"
        set -l t_up "$argv[4]"
        set -l t_vdf "$argv[5]"

        echo "🧯 Rollback: $reason"
        echo "  ↩️  Restoring backups (best effort)…"

        set -l up "$dst/protonfixes/upscalers.py"
        if test -f "$up.bak"
            cp -af -- "$up.bak" "$up" 2>/dev/null
        end

        if test -f "$dst/compatibilitytool.vdf.bak"
            cp -af -- "$dst/compatibilitytool.vdf.bak" "$dst/compatibilitytool.vdf" 2>/dev/null
        end

        echo "  🗑️  Removing broken clone: $dstbase"
        rm -rf -- "$dst"

        rm -f -- "$t_up" "$t_vdf" 2>/dev/null
        return 1
    end

    # Remove accidental duplicates first
    set -l dupes (fd -HI -a -t d --max-depth 1 --glob "proton-cachyos-$major-*-fsr403-fsr403" "$ctd" | sort)
    for d in $dupes
        echo "🗑️  Removing duplicate clone: "(basename "$d")
        rm -rf -- "$d"
    end

        # ── Summary counters ────────────────────────────────────────────────
    set -l sum_total (count $picked)
    set -l sum_built 0
    set -l sum_patched_up 0
    set -l sum_patched_vdf 0
    set -l sum_names

# Build clones
    for src in $picked
        set -l base (basename "$src")
        set -l dstbase "$base-fsr403"
        set -l dst "$ctd/$dstbase"

        echo "🧹 Rebuilding: $dstbase"
        rm -rf -- "$dst" 2>/dev/null

        echo "📦 Copying: $base → $dstbase"
        cp -a -- "$src" "$dst"
        or begin
            echo "❌ Copy failed: $src"
            rm -rf -- "$dst"
            rm -f -- "$t_up" "$t_vdf" 2>/dev/null
            functions -e __rollback 2>/dev/null
            functions -e __pfr_preflight 2>/dev/null
            return 1
        end
        echo "✅ Copied OK"

        # Patch upscalers.py
        set -l up "$dst/protonfixes/upscalers.py"
        if test -f "$up"
            cp -a -- "$up" "$up.bak" 2>/dev/null
            echo "🧷 Backup: upscalers.py.bak"
            echo "🧩 Patching: upscalers.py"
            python3 "$t_up" "$up"
            or begin
                __rollback "upscalers.py patch failed" "$dst" "$dstbase" "$t_up" "$t_vdf"
                echo "❌ Aborting (non-zero)."
                functions -e __rollback 2>/dev/null
                functions -e __pfr_preflight 2>/dev/null
                return 1
            end
            # 🧪 Validate patched upscalers.py compiles (catches SyntaxError before Steam sees it)
            python3 -m py_compile "$up"
            or begin
                __rollback "upscalers.py invalid python (py_compile failed)" "$dst" "$dstbase" "$t_up" "$t_vdf"
                echo "❌ Aborting (py_compile failed)."
                functions -e __rollback 2>/dev/null
                functions -e __pfr_preflight 2>/dev/null
                return 1
            end
            echo "✅ Patched: $up"
            set sum_patched_up (math $sum_patched_up + 1)
        else
            echo "⚠ Missing: $up"
        end

        # Patch compatibilitytool.vdf (Steam listing)
        set -l vdf "$dst/compatibilitytool.vdf"
        if test -f "$vdf"
            cp -a -- "$vdf" "$vdf.bak" 2>/dev/null
            echo "🧷 Backup: compatibilitytool.vdf.bak"
            echo "🧩 Patching: compatibilitytool.vdf"
            python3 "$t_vdf" "$vdf" "$base" "$dstbase" "$tag"
            or begin
                __rollback "compatibilitytool.vdf patch failed" "$dst" "$dstbase" "$t_up" "$t_vdf"
                echo "❌ Aborting (non-zero)."
                functions -e __rollback 2>/dev/null
                functions -e __pfr_preflight 2>/dev/null
                return 1
            end

            # Validate ONLY compatibilitytool.vdf (toolmanifest.vdf may not contain the name)
            rg -Fq "\"$dstbase\"" "$vdf"
            or begin
                __rollback "compatibilitytool.vdf validation failed (dstbase not found)" "$dst" "$dstbase" "$t_up" "$t_vdf"
                echo "❌ Aborting (non-zero)."
                functions -e __rollback 2>/dev/null
                functions -e __pfr_preflight 2>/dev/null
                return 1
            end

            echo "✅ Patched: $vdf"
            set sum_patched_vdf (math $sum_patched_vdf + 1)
        else
            echo "⚠ Missing: $vdf"
        end

        echo "✅ Done: $dstbase"
        set sum_built (math $sum_built + 1)
        set -a sum_names "$dstbase"
        echo ""
    end

    rm -f -- "$t_up" "$t_vdf" 2>/dev/null
    functions -e __rollback 2>/dev/null
    functions -e __pfr_preflight 2>/dev/null

        echo "📊 Summary"
    echo "  ✅ Built clones: $sum_built/$sum_total"
    echo "  🧩 Patched upscalers.py: $sum_patched_up"
    echo "  🧾 Patched VDF files: $sum_patched_vdf"
    if test (count $sum_names) -gt 0
        echo "  📦 Clones:"
        for n in $sum_names
            echo "    • $n"
        end
    end
    echo ""

echo "🔁 Restart Steam to re-scan tools:"
    echo "  steam -shutdown; sleep 2; pkill -TERM steam steamwebhelper 2>/dev/null"
    echo ""
    echo "🧩 Use these env vars for FSR4 4.0.3 local:"
    echo "  # RDNA4:"
    echo "  PROTON_FSR4_UPGRADE=4.0.3"
    echo ""
    echo "  # RDNA3 / RDNA3.5:"
    echo "  PROTON_FSR4_RDNA3_UPGRADE=4.0.3"
    echo ""
    echo "  # Local DLL (required for BOTH):"
    echo "  PROTON_FSR4_403_LOCAL=\"$localdll\""
end
