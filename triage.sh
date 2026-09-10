#!/usr/bin/env bash
#
# Symbolise le dernier crash de Shutter avec UE4SS.pdb.
#
# Usage :
#   ./triage.sh          le crash le plus recent
#   ./triage.sh -n 3     les 3 plus recents
#   ./triage.sh <dossier UE4CC-...>
#
set -euo pipefail

WIN64="$HOME/.steam/steam/steamapps/common/Shutter/Shutter/Binaries/Win64"
DLL="$WIN64/UE4SS.dll"
LOG="$WIN64/UE4SS.log"
CRASHES="$HOME/.local/share/Steam/steamapps/compatdata/2314110/pfx/drive_c/users/steamuser/AppData/Local/Shutter/Saved/Crashes"
BASE=$((0x180000000))   # ImageBase de UE4SS.dll

count=1
target=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n) count="$2"; shift 2 ;;
        *)  target="$1"; shift ;;
    esac
done

command -v llvm-symbolizer >/dev/null || {
    echo "llvm-symbolizer absent : sudo pacman -S llvm" >&2; exit 1; }
[[ -f "$DLL" ]] || { echo "UE4SS.dll introuvable : $DLL" >&2; exit 1; }

#-------------------------------------------------------
# Contexte : quelle version tournait
#-------------------------------------------------------

if [[ -f "$LOG" ]]; then
    build=$(grep -o 'BUILD = [0-9a-z-]*' "$LOG" | tail -1 || true)
    echo "Dernier build charge  : ${build:-inconnu}"
    echo "Derniere ligne du log : $(stat -c '%y' "$LOG" | cut -d. -f1)"
    echo
fi

#-------------------------------------------------------
# Dumps UE4SS (crash_*.dmp) : pas de pile portable, on lit
# l'enregistrement d'exception du minidump.
#-------------------------------------------------------

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
dmp=$(ls -1t "$WIN64"/crash_*.dmp 2>/dev/null | head -1)

if [[ -n "$dmp" && -f "$here/mdmp.py" ]]; then
    echo "=========================================================="
    echo "Dernier dump UE4SS : $(basename "$dmp")"
    echo "  $(stat -c '%y' "$dmp" | cut -d. -f1)"
    addr=$(python3 "$here/mdmp.py" "$dmp")
    if [[ -n "$addr" ]]; then
        out=$(llvm-symbolizer --obj="$DLL" "$addr" 2>/dev/null)
        printf '  -> %s\n     %s\n' \
            "$(echo "$out" | sed -n 1p)" \
            "$(echo "$out" | sed -n 2p | sed 's|.*[\\/]||')"
    fi
    echo
fi

#-------------------------------------------------------
# Selection des dumps
#-------------------------------------------------------

if [[ -n "$target" ]]; then
    dumps="$target"
else
    dumps=$(ls -1dt "$CRASHES"/*/ 2>/dev/null | head -n "$count")
fi

[[ -n "$dumps" ]] || { echo "Aucun crash dans $CRASHES"; exit 0; }

while read -r dir; do

    [[ -z "$dir" ]] && continue
    xml="$dir/CrashContext.runtime-xml"
    [[ -f "$xml" ]] || continue

    echo "=========================================================="
    echo "$(basename "$dir")"
    echo "  $(stat -c '%y' "$xml" | cut -d. -f1)"

    python3 - "$xml" <<'PY'
import re,sys,html
t=open(sys.argv[1],encoding='utf-8',errors='replace').read()
def tag(n):
    m=re.search(r"<%s>(.*?)</%s>"%(n,n),t,re.S)
    return html.unescape(m.group(1)).strip() if m else ""
print("  %s" % tag("ErrorMessage"))
print("  a %s s apres le lancement" % tag("SecondsSinceStart"))
PY

    echo "  ----------------------------------------------------------"

    python3 - "$xml" <<'PY' | while read -r off; do
import re,sys,html
t=open(sys.argv[1],encoding='utf-8',errors='replace').read()
m=re.search(r"<PCallStack>(.*?)</PCallStack>",t,re.S)
for o in re.findall(r"UE4SS\s+0x[0-9a-f]+\s+\+\s+([0-9a-f]+)", html.unescape(m.group(1)) if m else ""):
    print(o)
PY
        addr=$(printf '0x%x' $((BASE + 0x$off)))
        out=$(llvm-symbolizer --obj="$DLL" "$addr" 2>/dev/null)
        fn=$(echo "$out" | sed -n 1p)
        loc=$(echo "$out" | sed -n 2p | sed 's|.*[\\/]||')
        printf '  %-9s %-52s %s\n' "+$off" "${fn:0:52}" "$loc"
    done

    echo
done <<< "$dumps"
