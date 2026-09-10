#!/usr/bin/env python3
"""
Lit l'enregistrement d'exception d'un minidump UE4SS (crash_*.dmp).

Ces dumps n'ont pas de CrashContext.runtime-xml, donc pas de pile
portable : on extrait l'adresse fautive et le module, que triage.sh
symbolise ensuite avec UE4SS.pdb.
"""
import struct, sys

UE4SS_IMAGE_BASE = 0x180000000

d = open(sys.argv[1], 'rb').read()

sig, ver, count, rva_dir = struct.unpack_from('<4sIII', d, 0)
if sig != b'MDMP':
    sys.exit("pas un minidump")

streams = {}
for i in range(count):
    t, sz, rva = struct.unpack_from('<III', d, rva_dir + i * 12)
    streams[t] = (sz, rva)

# MINIDUMP_MODULE : base(0) size(8) checksum(12) stamp(16) NameRva(20), 108 octets
modules = []
if 4 in streams:
    _, rva = streams[4]
    n = struct.unpack_from('<I', d, rva)[0]
    for i in range(n):
        off = rva + 4 + i * 108
        base, size = struct.unpack_from('<QI', d, off)
        name_rva = struct.unpack_from('<I', d, off + 20)[0]
        ln = struct.unpack_from('<I', d, name_rva)[0]
        name = d[name_rva + 4:name_rva + 4 + ln].decode('utf-16-le', 'replace')
        modules.append((base, size, name.replace('\\', '/').split('/')[-1]))

if 6 not in streams:
    sys.exit("pas d'enregistrement d'exception")

_, rva = streams[6]
code, flags, rec, fault = struct.unpack_from('<IIQQ', d, rva + 8)
nparams = struct.unpack_from('<I', d, rva + 8 + 24)[0]
params = struct.unpack_from('<15Q', d, rva + 8 + 32)

print("  Exception   : 0x%08X" % code, file=sys.stderr)
if nparams >= 2:
    op = {0: "lecture", 1: "ecriture", 8: "execution"}.get(params[0], str(params[0]))
    print("  Acces       : %s de 0x%X" % (op, params[1]), file=sys.stderr)

for base, size, name in modules:
    if base <= fault < base + size:
        print("  Instruction : %s + %x" % (name, fault - base), file=sys.stderr)
        if 'UE4SS' in name:
            # adresse a passer a llvm-symbolizer
            print("0x%x" % (UE4SS_IMAGE_BASE + fault - base))
        break
