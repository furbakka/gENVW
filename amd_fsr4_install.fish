function amd_fsr4_install --description "Download/extract AMD Windows driver and stash amdxcffx64.dll for FSR4 local mode (wget-only)"
    # Usage:
    #   amd_fsr4_install --url <drivers.amd.com/...exe> [--want 4.0.3]
    #   amd_fsr4_install --exe <path/to/driver.exe>    [--want 4.0.3]
    #   amd_fsr4_install --check
    #   amd_fsr4_install --clean [--want 4.0.3]
    #   amd_fsr4_install --uninstall
    #   amd_fsr4_install --info
    #
    # Behavior:
    #   • By default, it AUTO-CLEANS the extracted folder after success.
    #   • Use --keep-extracted to keep the extracted folder.

    argparse -n amd_fsr4_install \
        'h/help' \
        'i/info' \
        'c/check' \
        'clean' \
        'uninstall' \
        'keep-extracted' \
        'url=' \
        'exe=' \
        'want=' \
        -- $argv
    or return 2

    set -l want "4.0.3"
    if set -q _flag_want
        set want "$_flag_want"
    end

    set -l dl_dir "$HOME/AMD/driver-dl"
    set -l out_dir "$HOME/AMD/extracted-$want"
    set -l dst_dir "$HOME/.cache/fsr4"
    set -l dst "$dst_dir/amdxcffx64-$want.dll"

    # ── --uninstall (works even if deps missing) ─────────────────────────────
    if set -q _flag_uninstall
        if test -d "$dst_dir"
            echo "🗑️  Uninstall: removing:"
            echo "  $dst_dir"
            rm -rf -- "$dst_dir"
            and echo "✅ Removed $dst_dir"
            or begin
                echo "❌ Failed to remove $dst_dir"
                return 1
            end
        else
            echo "ℹ️  Nothing to uninstall (missing): $dst_dir"
        end
        return 0
    end

    # ── --clean (standalone cleanup; keeps ~/.cache/fsr4) ────────────────────
    if set -q _flag_clean; and not set -q _flag_url; and not set -q _flag_exe
        if test -d "$out_dir"
            echo "🧹 Clean: removing extracted folder:"
            echo "  $out_dir"
            rm -rf -- "$out_dir"
            and echo "✅ Removed $out_dir"
            or begin
                echo "❌ Failed to remove $out_dir"
                return 1
            end
        else
            echo "ℹ️  Nothing to clean (missing): $out_dir"
        end
        echo "✅ Kept cache folder:"
        echo "  $dst_dir"
        return 0
    end

    # ── prereq check (fail closed) ────────────────────────────────────────────
    set -l req wget 7z fd rg file md5sum
    set -l oneof exiftool strings
    set -l opt cabextract

    set -l missing_req
    for c in $req
        type -q $c; or set -a missing_req $c
    end

    set -l have_oneof
    for c in $oneof
        type -q $c; and set -a have_oneof $c
    end

    set -l missing_opt
    for c in $opt
        type -q $c; or set -a missing_opt $c
    end

    function __amd__print_prereqs --no-scope-shadowing
        echo "🧰 amd_fsr4_install prereq check"
        echo ""
        echo "✅ Required:"
        for c in $req
            type -q $c; and echo "  ✅ $c"; or echo "  ❌ $c"
        end
        echo ""
        echo "🧩 Version detection (need ONE):"
        for c in $oneof
            type -q $c; and echo "  ✅ $c"; or echo "  ❌ $c"
        end
        echo ""
        echo "🟡 Optional (only used if DLL is buried in CABs):"
        for c in $opt
            type -q $c; and echo "  ✅ $c"; or echo "  ⚠️  $c (optional)"
        end
    end

    function __amd__print_install_line --no-scope-shadowing
        set -l pkgs

        for cmd in $missing_req
            switch $cmd
                case wget
                    set -a pkgs wget
                case 7z
                    set -a pkgs p7zip
                case fd
                    set -a pkgs fd
                case rg
                    set -a pkgs ripgrep
                case file
                    set -a pkgs file
                case md5sum
                    set -a pkgs coreutils
            end
        end

        set -l needs_oneof 0
        if test (count $have_oneof) -eq 0
            set -a pkgs perl-image-exiftool
            set needs_oneof 1
        end

        set -l uniq
        for p in $pkgs
            contains -- $p $uniq; or set -a uniq $p
        end

        if test (count $uniq) -gt 0
            echo ""
            echo "➡️  Install missing prereqs:"
            echo "  paru -S --needed $uniq"
            if test $needs_oneof -eq 1
                echo "  Alternative (instead of exiftool):"
                echo "    paru -S --needed binutils"
            end
        else
            echo ""
            echo "✅ All required prereqs satisfied."
        end

        if test (count $missing_opt) -gt 0
            echo ""
            echo "🟡 Optional (only needed if DLL is buried in CABs):"
            echo "  paru -S --needed cabextract"
        end
    end

    if set -q _flag_check
        __amd__print_prereqs
        __amd__print_install_line
        functions -e __amd__print_prereqs __amd__print_install_line 2>/dev/null

        if test (count $missing_req) -gt 0; or test (count $have_oneof) -eq 0
            return 1
        end
        return 0
    end

    if set -q _flag_help; or set -q _flag_info
        echo "Usage:"
        echo "  amd_fsr4_install --url <AMD_driver_exe_url> [--want 4.0.3]"
        echo "  amd_fsr4_install --exe <AMD_driver_exe_path> [--want 4.0.3]"
        echo "  amd_fsr4_install --check"
        echo "  amd_fsr4_install --clean [--want 4.0.3]"
        echo "  amd_fsr4_install --uninstall"
        echo "  amd_fsr4_install --keep-extracted   (disable auto-clean)"
        echo ""
        echo "Default: auto-cleans extracted folder after success."
        echo ""
        __amd__print_prereqs
        __amd__print_install_line
        functions -e __amd__print_prereqs __amd__print_install_line 2>/dev/null
        return 0
    end

    if test (count $missing_req) -gt 0; or test (count $have_oneof) -eq 0
        __amd__print_prereqs
        __amd__print_install_line
        functions -e __amd__print_prereqs __amd__print_install_line 2>/dev/null
        echo ""
        echo "⛔ Missing required prereqs — aborting (no download/extract performed)."
        return 1
    end
    functions -e __amd__print_prereqs __amd__print_install_line 2>/dev/null

    # ── ensure dirs ──────────────────────────────────────────────────────────
    mkdir -p "$dl_dir" "$out_dir" "$dst_dir"

    # ── pick EXE input ───────────────────────────────────────────────────────
    set -l exe_path ""
    if set -q _flag_exe
        set exe_path "$_flag_exe"
        if not test -f "$exe_path"
            echo "❌ EXE not found: $exe_path"
            return 1
        end
    else if set -q _flag_url
        set -l url "$_flag_url"
        set -l base (basename "$url")
        set -l name (string replace -r '\?.*$' '' -- "$base")
        test -n "$name"; or set name "amd-driver.exe"
        set exe_path "$dl_dir/$name"

        echo "⬇️  Downloading (wget):"
        echo "  $url"
        echo "➡️  To:"
        echo "  $exe_path"

        set -l ua "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Safari/537.36"
        set -l referer "https://www.amd.com/"
        set -l h_accept "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
        set -l h_lang   "Accept-Language: en-US,en;q=0.9"
        set -l h_dnt    "DNT: 1"
        set -l h_conn   "Connection: keep-alive"
        set -l h_upgr   "Upgrade-Insecure-Requests: 1"

        wget -c \
            --max-redirect=25 \
            --content-disposition \
            --tries=12 --waitretry=2 --timeout=30 \
            --user-agent="$ua" \
            --referer="$referer" \
            --header="$h_accept" \
            --header="$h_lang" \
            --header="$h_dnt" \
            --header="$h_conn" \
            --header="$h_upgr" \
            -O "$exe_path" \
            "$url"
        or begin
            echo "❌ wget download failed."
            return 1
        end
    else
        echo "❌ Provide --url or --exe (or use --info)"
        return 1
    end

    # sanity: avoid HTML redirect pages
    set -l mime (file -b --mime-type "$exe_path")
    if string match -q 'text/*' -- "$mime"
        echo "❌ Downloaded file looks like text ($mime), not a Windows EXE."
        head -n 8 "$exe_path"
        return 1
    end

    # ── extract ──────────────────────────────────────────────────────────────
    echo "📦 Extracting to:"
    echo "  $out_dir"
    rm -rf -- "$out_dir"
    mkdir -p "$out_dir"
    7z x -y -o"$out_dir" "$exe_path" >/dev/null
    or begin
        echo "❌ 7z extraction failed."
        return 1
    end

    # ── find DLL ─────────────────────────────────────────────────────────────
    echo "🔎 Searching for amdxcffx64.dll…"
    set -l hits (fd -HI -a --glob 'amdxcffx64.dll' "$out_dir" | sort)

    if test (count $hits) -eq 0
        echo "⚠ Not found directly. Searching inside CAB/MSI…"

        if type -q cabextract
            for cab in (fd -HI -a -e cab "$out_dir")
                if 7z l "$cab" 2>/dev/null | rg -qi 'amdxcffx64\.dll'
                    mkdir -p "$out_dir/extracted-dll"
                    cabextract -F amdxcffx64.dll -d "$out_dir/extracted-dll" "$cab" >/dev/null 2>&1
                end
            end
        end

        for msi in (fd -HI -a -e msi "$out_dir")
            if 7z l "$msi" 2>/dev/null | rg -qi 'amdxcffx64\.dll'
                mkdir -p "$out_dir/extracted-dll"
                7z x -y -o"$out_dir/extracted-dll" "$msi" '*amdxcffx64.dll*' >/dev/null 2>&1
            end
        end

        set hits (fd -HI -a --glob 'amdxcffx64.dll' "$out_dir" | sort)
    end

    if test (count $hits) -eq 0
        echo "❌ No amdxcffx64.dll found after extraction."
        return 1
    end

    # ── filter by version ────────────────────────────────────────────────────
    set -l candidates
    for f in $hits
        set -l ok 0

        if type -q exiftool
            set -l pv (exiftool -s -s -s -ProductVersion "$f" 2>/dev/null)
            set -l fv (exiftool -s -s -s -FileVersion "$f" 2>/dev/null)
            if test -n "$pv"; and string match -qr "^$want" -- "$pv"
                set ok 1
            else if test -n "$fv"; and string match -qr "^$want" -- "$fv"
                set ok 1
            end
        end

        if test $ok -eq 0; and type -q strings
            strings -a "$f" | rg -Fq "$want"
            and set ok 1
        end

        test $ok -eq 1; and set -a candidates "$f"
    end

    if test (count $candidates) -eq 0
        echo "❌ Found amdxcffx64.dll, but none matched want='$want'."
        for f in $hits
            echo "  • $f"
        end
        return 1
    end

    # pick best candidate
    set -l picked ""
    for f in $candidates
        if string match -q '*Packages/Drivers/Display*' -- "$f"
            set picked "$f"
            break
        end
    end
    test -n "$picked"; or set picked "$candidates[1]"

    # ── copy to cache ────────────────────────────────────────────────────────
    echo "🎯 Picked:"
    echo "  $picked"
    echo "➡️  Copying to:"
    echo "  $dst"

    cp -av "$picked" "$dst" >/dev/null
    chmod 0644 "$dst" 2>/dev/null

    echo ""
    if type -q exiftool
        echo "🔎 Version (exiftool):"
        exiftool -ProductVersion -FileVersion "$dst" 2>/dev/null
    else
        echo "🔎 Version strings:"
        strings -a "$dst" | rg -n '4\.0\.[0-9]+' | head -n 10
    end

    echo ""
    echo "🧾 MD5:"
    md5sum "$dst"

    echo ""
    echo "✅ Done. Use:"
    echo "  PROTON_FSR4_403_LOCAL=\"$dst\""

    # ── AUTO-CLEAN extracted folder (default) ────────────────────────────────
    if set -q _flag_keep_extracted
        echo "🧷 Keeping extracted folder (per --keep-extracted):"
        echo "  $out_dir"
    else
        echo "🧹 Auto-clean: removing extracted folder:"
        echo "  $out_dir"
        rm -rf -- "$out_dir"
    end

    return 0
end
