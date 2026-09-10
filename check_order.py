#!/usr/bin/env python3
"""
Detecte les appels a un local defini plus bas dans le fichier.

Lua resout ces references sur un global, donc nil : l'erreur n'apparait
qu'a l'execution, et luac -p ne la voit pas. Le correctif est une
declaration anticipee (`local nom` en tete, puis `function nom()`).
"""
import re, sys, io

def strip_strings(line):
    """Vide les litteraux : leur contenu n'est pas du code.

    Sans ca, "%s (%s)" ressemble a un appel s(), et un message de log
    contenant un mot suivi d'une parenthese aussi."""
    line = re.sub(r'"(?:[^"\\]|\\.)*"', '""', line)
    line = re.sub(r"'(?:[^'\\]|\\.)*'", "''", line)
    line = re.sub(r"\[\[.*?\]\]", "[[]]", line)
    return line


def check(path):
    lines = [strip_strings(l)
             for l in io.open(path, encoding="utf-8").read().split("\n")]

    defined = {}
    for i, l in enumerate(lines, 1):
        m = re.match(r"\s*local function ([A-Za-z_]\w*)", l)
        if m:
            defined.setdefault(m.group(1), i)
        m = re.match(r"\s*local ([A-Za-z_]\w*)\s*$", l)
        if m:
            defined.setdefault(m.group(1), i)

    bad = set()
    for i, l in enumerate(lines, 1):
        if re.match(r"\s*(local function|function|--)", l):
            continue
        for name, dl in defined.items():
            if i < dl and re.search(r"(?<![\w.:])%s\s*\(" % re.escape(name), l):
                bad.add((i, name, dl, l.strip()[:60]))

    for i, name, dl, txt in sorted(bad):
        print("  %s:%d  %s() est defini ligne %d | %s"
              % (path, i, name, dl, txt), file=sys.stderr)

    # --- appels a une fonction inexistante ---------------------------
    #
    # Nos helpers sont en snake_case, l'API UE4SS en PascalCase. Un appel
    # snake_case qui n'est defini nulle part dans le fichier est donc une
    # fonction supprimee ou mal orthographiee : Lua ne le signale qu'a
    # l'execution, et seulement si la branche concernee est atteinte.
    builtins = {
        "pcall", "xpcall", "type", "tostring", "tonumber", "ipairs",
        "pairs", "next", "select", "error", "assert", "unpack", "require",
        "print", "rawget", "rawset", "rawequal", "rawlen", "setmetatable",
        "getmetatable", "collectgarbage", "load", "loadstring", "dofile",
    }

    missing = set()
    for i, l in enumerate(lines, 1):
        if re.match(r"\s*--", l):
            continue
        for name in re.findall(r"(?<![\w.:])([a-z][a-z0-9_]*)\s*\(", l):
            if "_" not in name and name in builtins:
                continue
            if name in builtins or name in defined:
                continue
            # ignore les mots-cles suivis d'une parenthese
            if name in ("if", "while", "for", "return", "and", "or", "not", "function"):
                continue
            missing.add((i, name, l.strip()[:60]))

    for i, name, txt in sorted(missing):
        print("  %s:%d  %s() n'est defini nulle part | %s"
              % (path, i, name, txt), file=sys.stderr)

    return len(bad) + len(missing)

total = sum(check(p) for p in sys.argv[1:])

if total:
    print("\n%d probleme(s) de definition : rien n'a ete deploye." % total,
          file=sys.stderr)
    sys.exit(1)
