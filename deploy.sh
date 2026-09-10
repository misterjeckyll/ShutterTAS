#!/usr/bin/env bash
#
# Deploie les scripts Lua de ShutterTAS vers le dossier Mods de UE4SS.
#
# Le jeu tourne sous Proton : le chemin Windows vu par UE4SS
#   S:\steamapps\common\Shutter\...\Mods\ShutterTASDiscovery\Scripts\
# correspond cote Linux a DEST ci-dessous.
#
# Usage :
#   ./deploy.sh              deploie et verifie
#   ./deploy.sh --bump       incremente TAS_BUILD puis deploie
#   ./deploy.sh --check      compare seulement, ne copie rien
#   SHUTTERTAS_DEST=/autre/chemin ./deploy.sh
#
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/Scripts"

DEST="${SHUTTERTAS_DEST:-$HOME/.steam/steam/steamapps/common/Shutter/Shutter/Binaries/Win64/Mods/ShutterTASDiscovery/Scripts}"

BUMP=0
CHECK_ONLY=0

for arg in "$@"; do
    case "$arg" in
        --bump)  BUMP=1 ;;
        --check) CHECK_ONLY=1 ;;
        -h|--help)
            sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'
            exit 0 ;;
        *)
            echo "Option inconnue : $arg" >&2
            exit 2 ;;
    esac
done

[[ -d "$SRC" ]]  || { echo "Source introuvable : $SRC" >&2; exit 1; }
[[ -d "$DEST" ]] || {
    echo "Destination introuvable : $DEST" >&2
    echo "Le jeu est-il installe ? Sinon, precisez SHUTTERTAS_DEST." >&2
    exit 1
}

main_lua="$SRC/main.lua"

#-------------------------------------------------------
# Incrementation du marqueur de version
#-------------------------------------------------------

if [[ $BUMP -eq 1 ]]; then

    current="$(grep -oP 'TAS_BUILD = "\K[^"]+' "$main_lua" || true)"

    if [[ -z "$current" ]]; then
        echo "TAS_BUILD introuvable dans main.lua, --bump ignore" >&2
    else
        today="$(date +%Y-%m-%d)"
        base="${current%-*}"
        suffix="${current##*-}"

        # Suffixe numerique : les lettres debordaient sur '{' apres 'z'.
        if [[ "$base" == "$today" && "$suffix" =~ ^[0-9]+$ ]]; then
            next=$(( suffix + 1 ))
        else
            next=1
        fi

        new="$today-$next"
        sed -i "s/TAS_BUILD = \"$current\"/TAS_BUILD = \"$new\"/" "$main_lua"
        echo "BUILD  $current -> $new"
    fi
fi

#-------------------------------------------------------
# Verification syntaxique avant tout deploiement
#-------------------------------------------------------

if command -v luac >/dev/null 2>&1; then
    for f in "$SRC"/*.lua; do
        luac -p "$f" || { echo "Erreur de syntaxe dans $(basename "$f"), rien n'a ete deploye" >&2; exit 1; }
    done
    echo "SYNTAXE  ok"

    # Lua ne signale un appel a un local defini plus bas qu'a l'execution.
    if [[ -f "$(dirname "$SRC")/check_order.py" ]]; then
        if python3 "$(dirname "$SRC")/check_order.py" "$SRC"/*.lua; then
            echo "ORDRE    ok"
        else
            exit 1
        fi
    fi
else
    echo "SYNTAXE  luac absent, verification ignoree" >&2
fi

#-------------------------------------------------------
# Comparaison / copie
#-------------------------------------------------------

changed=0

for f in "$SRC"/*.lua; do

    name="$(basename "$f")"
    target="$DEST/$name"

    if [[ -f "$target" ]] && cmp -s "$f" "$target"; then
        printf '  =  %s\n' "$name"
        continue
    fi

    changed=1

    if [[ $CHECK_ONLY -eq 1 ]]; then
        printf '  !  %s (differe)\n' "$name"
        continue
    fi

    if [[ -f "$target" ]]; then
        cp -p "$target" "$target.bak-$(date +%Y%m%d-%H%M%S)"
    fi

    cp "$f" "$target"
    printf '  ->  %s\n' "$name"
done

if [[ $CHECK_ONLY -eq 1 ]]; then
    [[ $changed -eq 0 ]] && echo "A jour." || echo "Des fichiers different."
    exit $changed
fi

#-------------------------------------------------------
# Verification post-copie
#-------------------------------------------------------

for f in "$SRC"/*.lua; do
    name="$(basename "$f")"
    cmp -s "$f" "$DEST/$name" || { echo "ECHEC de verification pour $name" >&2; exit 1; }
done

# On ne garde que les 5 sauvegardes les plus recentes
find "$DEST" -maxdepth 1 -name '*.bak-*' -printf '%T@ %p\0' 2>/dev/null \
    | sort -zrn | tail -zn +6 | cut -z -d' ' -f2- | xargs -0 -r rm --

build="$(grep -oP 'TAS_BUILD = "\K[^"]+' "$DEST/main.lua" 2>/dev/null || echo '?')"

echo "OK  deploye dans $DEST"
echo "BUILD = $build  (doit apparaitre dans la console UE4SS au chargement)"
