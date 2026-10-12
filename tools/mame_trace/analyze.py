#!/usr/bin/env python3
"""Post-process susume_trace.lua logs.

usage: python analyze.py <logdir> [eeprom_default_from_zip]
Writes into <logdir>:
  scsi_decoded.log   one block per SCSI command (CDB decode, controller cmds, observed status regs, DMA)
  eeprom_decoded.log 93C46 transactions decoded from line levels
  analysis.txt       aggregate tables used for SUMMARY.md
The optional second arg is a path to susume.zip; the default EEPROM image (susume.25c) is
read in memory only (never written anywhere) to cross-check decoded EEPROM reads.
"""
import sys, os, re, zipfile, collections

D = sys.argv[1]
ZIP = sys.argv[2] if len(sys.argv) > 2 else None
out = open(os.path.join(D, "analysis.txt"), "w")
def P(*a):
    print(*a, file=out)

# ------------------------------------------------------------------ parse ncr.log
LINE = re.compile(r"^(\S+)\s+(\d+)\s+(\S+)\s+(\S+)\s+([RW])\s+(\S+)\s+(\S+)\s+reg=(\S)\s+(\S+)\s+val=(\S\S)\s*(.*)$")
recs = []
for ln in open(os.path.join(D, "ncr.log")):
    m = LINE.match(ln.rstrip("\n"))
    if not m:
        continue
    t, fr, pc, addr, rw, mask, data, reg, name, val, extra = m.groups()
    recs.append(dict(t=float(t), fr=int(fr), pc=pc, addr=addr, rw=rw, mask=mask, reg=int(reg, 16), name=name,
                     val=int(val, 16), extra=extra, raw=ln.rstrip("\n")))

# DMA log
dma_starts = []  # (t, addr, words, dir, raw)
crcs = []
for ln in open(os.path.join(D, "dma5.log")):
    if "XFER#" in ln:
        f = ln.split()
        t = float(f[0])
        m = re.search(r"XFER#(\d+) addr=(\w+) words=(\d+) bytes=(\d+)", ln)
        dr = "toRAM" if "dir=toRAM" in ln else "fromRAM"
        bcr = None
        dma_starts.append(dict(t=t, n=int(m.group(1)), addr=int(m.group(2), 16), words=int(m.group(3)), dir=dr, raw=ln.strip()))
    if " CRC xfer#" in ln:
        crcs.append(ln.strip())
bcrs = collections.Counter()
for ln in open(os.path.join(D, "dma5.log")):
    if "D5_BCR" in ln:
        bcrs[ln.split()[6]] += 1
chcrs = collections.Counter()
for ln in open(os.path.join(D, "dma5.log")):
    if "D5_CHCR" in ln and " W " in ln:
        chcrs[ln.split()[6]] += 1

def msf(l):
    l += 150
    return "%02d:%02d:%02d" % (l // 4500, (l // 75) % 60, l % 75)

def decode_cdb(c):
    op = c[0]
    def be(b):
        v = 0
        for x in b:
            v = (v << 8) | x
        return v
    if op == 0x00: return "TEST UNIT READY", "TUR"
    if op == 0x03: return "REQUEST SENSE alloc=%d" % c[4], "REQUEST_SENSE"
    if op == 0x12: return "INQUIRY evpd=%d page=%02x alloc=%d" % (c[1] & 1, c[2], c[4]), "INQUIRY"
    if op == 0x15: return "MODE SELECT(6) pf=%d sp=%d paramlen=%d" % ((c[1] >> 4) & 1, c[1] & 1, c[4]), "MODE_SELECT6"
    if op == 0x1a: return "MODE SENSE(6) dbd=%d pc=%d page=%02x alloc=%d" % ((c[1] >> 3) & 1, c[2] >> 6, c[2] & 0x3f, c[4]), "MODE_SENSE6"
    if op == 0x1b: return "START/STOP UNIT start=%d loej=%d" % (c[4] & 1, (c[4] >> 1) & 1), "START_STOP"
    if op == 0x25: return "READ CAPACITY", "READ_CAPACITY"
    if op == 0x28:
        lba = be(c[2:6]); n = be(c[7:9])
        return "READ(10) LBA=%d (0x%x, MSF %s) blocks=%d" % (lba, lba, msf(lba), n), "READ10"
    if op == 0x2b: return "SEEK(10) LBA=%d" % be(c[2:6]), "SEEK10"
    if op == 0x42:
        return "READ SUB-CHANNEL msf=%d subq=%d format=%02x track=%d alloc=%d" % ((c[1] >> 1) & 1, (c[2] >> 6) & 1, c[3], c[6], be(c[7:9])), "READ_SUBCHANNEL"
    if op == 0x43:
        return "READ TOC msf=%d format=%d start_track=%d alloc=%d" % ((c[1] >> 1) & 1, (c[9] >> 6) if len(c) > 9 else 0, c[6], be(c[7:9])), "READ_TOC"
    if op == 0x45: return "PLAY AUDIO(10) LBA=%d len=%d" % (be(c[2:6]), be(c[7:9])), "PLAY_AUDIO10"
    if op == 0x47: return "PLAY AUDIO MSF start=%02d:%02d:%02d end=%02d:%02d:%02d" % tuple(c[3:9]), "PLAY_AUDIO_MSF"
    if op == 0x48: return "PLAY AUDIO TRACK/INDEX start=T%d.%d end=T%d.%d" % (c[4], c[5], c[7], c[8]), "PLAY_TRACK_INDEX"
    if op == 0x4b: return "PAUSE/RESUME resume=%d" % (c[8] & 1), "PAUSE_RESUME"
    if op == 0x4e: return "STOP PLAY/SCAN", "STOP"
    if op == 0xa5: return "PLAY AUDIO(12)", "PLAY_AUDIO12"
    return "opcode %02x" % op, "OP_%02x" % op

# group into transactions at each SELECT command write
txs = []
cur = None
pre = []
for r in recs:
    if r["rw"] == "W" and r["reg"] == 3 and (r["val"] & 0x7f) in (0x41, 0x42, 0x43, 0x46):
        m = re.search(r"fifo=\[([0-9a-f ]*)\]", r["extra"])
        fifo = [int(x, 16) for x in m.group(1).split()] if m and m.group(1) else []
        atn = (r["val"] & 0x7f) in (0x42, 0x43, 0x46)
        msg = fifo[0] if atn and fifo else None
        cdb = fifo[1:] if atn else fifo
        cur = dict(t=r["t"], fr=r["fr"], cdb=cdb, msg=msg, selcmd=r["val"], recs=[], pre=pre)
        txs.append(cur)
        pre = []
        continue
    if cur is None:
        pre.append(r)
    else:
        cur["recs"].append(r)
# attach the setup writes (ENABLE_SEL/BUSID/FIFO) that precede each select to that select's block
for i in range(1, len(txs)):
    prev = txs[i - 1]["recs"]
    k = len(prev)
    while k > 0 and prev[k - 1]["rw"] == "W" and prev[k - 1]["reg"] in (2, 3, 4) and not (prev[k - 1]["reg"] == 3 and prev[k - 1]["val"] not in (0x44,)):
        k -= 1
    txs[i]["pre"] = prev[k:]
    txs[i - 1]["recs"] = prev[:k]

di = 0
for tx in txs:
    tx["desc"], tx["kind"] = decode_cdb(tx["cdb"]) if tx["cdb"] else ("(empty)", "EMPTY")
    tx["ctl"] = [("%02x" % r["val"]) for r in tx["recs"] if r["rw"] == "W" and r["reg"] == 3]
    # status/message bytes = FIFO reads after INIT_CMD_COMPLETE
    st = []
    seen_iccs = False
    for r in tx["recs"]:
        if r["rw"] == "W" and r["reg"] == 3 and (r["val"] & 0x7f) == 0x11:
            seen_iccs = True; st = []
        elif seen_iccs and r["rw"] == "R" and r["reg"] == 2:
            st.append(r["val"])
    tx["status_msg"] = st
    tx["tc"] = None
    tc = {}
    for r in tx["recs"]:
        if r["rw"] == "W" and r["reg"] in (0, 1, 0xE):
            tc[r["reg"]] = r["val"]
    if tc:
        tx["tc"] = tc.get(0, 0) | (tc.get(1, 0) << 8) | (tc.get(0xE, 0) << 16)
    tx["pio_reads"] = sum(1 for r in tx["recs"] if r["rw"] == "R" and r["reg"] == 2)
    tx["dma"] = []
    tend = tx["recs"][-1]["t"] if tx["recs"] else tx["t"]
    while di < len(dma_starts) and dma_starts[di]["t"] < tx["t"]:
        di += 1
    j = di
    while j < len(dma_starts) and dma_starts[j]["t"] <= tend + 1e-6:
        tx["dma"].append(dma_starts[j]); j += 1
    # observed (STATUS, SEQSTEP, ISTATUS) triples
    obs = []
    for r in tx["recs"]:
        if r["rw"] == "R" and r["reg"] in (4, 5, 6):
            obs.append("%s=%02x" % ({4: "ST", 5: "IS", 6: "SS"}[r["reg"]], r["val"]))
    tx["obs"] = obs

# write decoded log
with open(os.path.join(D, "scsi_decoded.log"), "w") as o:
    o.write("# time_s frame  CDB-decode | controller cmds after select | TC | DMA | status,msg bytes | observed ST/SS/IS reads\n")
    for i, tx in enumerate(txs):
        dm = ";".join("ch5 %s addr=%06x words=%d" % (d["dir"], d["addr"], d["words"]) for d in tx["dma"])
        o.write("%10.6f %6d #%d sel=%02x msg=%s CDB=[%s] %s | cmds=%s | TC=%s | DMA=%s | st/msg=%s | %s\n" % (
            tx["t"], tx["fr"], i, tx["selcmd"], ("%02x" % tx["msg"]) if tx["msg"] is not None else "-",
            " ".join("%02x" % b for b in tx["cdb"]), tx["desc"], ",".join(tx["ctl"]),
            tx["tc"], dm or "-", ",".join("%02x" % b for b in tx["status_msg"]), " ".join(tx["obs"])))

# ---- aggregate tables
P("== SCSI: %d selections" % len(txs))
P("controller command codes used (all NCR COMMAND writes):")
cc = collections.Counter(("%02x" % r["val"]) for r in recs if r["rw"] == "W" and r["reg"] == 3)
for k, v in sorted(cc.items()):
    P("  %s x%d" % (k, v))
P("register write counts by reg:", dict(collections.Counter("%X" % r["reg"] for r in recs if r["rw"] == "W")))
P("register read counts by reg:", dict(collections.Counter("%X" % r["reg"] for r in recs if r["rw"] == "R")))
P("access masks used:", dict(collections.Counter((r["rw"], r["mask"]) for r in recs)))

P("\n== distinct CDBs in first-occurrence order (count, first time, last time, TC, DMA words, status/msg)")
dist = collections.OrderedDict()
for tx in txs:
    k = " ".join("%02x" % b for b in tx["cdb"])
    if k not in dist:
        dist[k] = dict(n=0, first=tx["t"], last=tx["t"], desc=tx["desc"], tc=set(), dw=set(), st=set(), ctl=set())
    e = dist[k]
    e["n"] += 1; e["last"] = tx["t"]
    e["tc"].add(tx["tc"]); e["dw"].add(tuple(d["words"] for d in tx["dma"]))
    e["st"].add(",".join("%02x" % b for b in tx["status_msg"])); e["ctl"].add(",".join(tx["ctl"]))
for k, e in dist.items():
    P("  [%s] n=%d first=%.3f last=%.3f %s | TC=%s DMAwords=%s st/msg=%s cmds=%s" % (
        k, e["n"], e["first"], e["last"], e["desc"], sorted(x for x in e["tc"] if x is not None) or "-",
        sorted(e["dw"]), sorted(e["st"]), sorted(e["ctl"])))

P("\n== by opcode kind")
kinds = collections.OrderedDict()
for tx in txs:
    kinds.setdefault(tx["kind"], []).append(tx)
for k, l in kinds.items():
    P("  %-18s n=%4d first=%.3f last=%.3f" % (k, len(l), l[0]["t"], l[-1]["t"]))

P("\n== READ(10) list (time, LBA, blocks, DMA addr/words)")
for tx in txs:
    if tx["kind"] == "READ10":
        P("  %.6f %s | %s" % (tx["t"], tx["desc"], ";".join("addr=%06x words=%d" % (d["addr"], d["words"]) for d in tx["dma"])))
P("\n== PLAY / PAUSE / MODE SELECT / TOC list")
for tx in txs:
    if tx["kind"] in ("PLAY_TRACK_INDEX", "PAUSE_RESUME", "PLAY_AUDIO_MSF", "PLAY_AUDIO10", "READ_TOC", "MODE_SENSE6", "STOP", "INQUIRY", "REQUEST_SENSE", "TUR"):
        P("  %.6f %s st/msg=%s" % (tx["t"], tx["desc"], ",".join("%02x" % b for b in tx["status_msg"])))
ms = [tx for tx in txs if tx["kind"] == "MODE_SELECT6"]
P("  MODE SELECT(6): %d times, first %.3f last %.3f; DMA dirs %s" % (len(ms), ms[0]["t"] if ms else -1, ms[-1]["t"] if ms else -1,
    collections.Counter(d["dir"] + "/%d" % d["words"] for tx in ms for d in tx["dma"])))
rs = [tx for tx in txs if tx["kind"] == "READ_SUBCHANNEL"]
if rs:
    gaps = [b["t"] - a["t"] for a, b in zip(rs, rs[1:])]
    P("  READ SUB-CHANNEL: %d times, first %.3f last %.3f, median gap %.3f s" % (len(rs), rs[0]["t"], rs[-1]["t"], sorted(gaps)[len(gaps) // 2] if gaps else 0))

P("\n== DMA ch5 BCR values:", dict(bcrs))
P("== DMA ch5 CHCR values written:", dict(chcrs))
P("== DMA ch5 starts: %d (toRAM %d, fromRAM %d)" % (len(dma_starts), sum(d["dir"] == "toRAM" for d in dma_starts), sum(d["dir"] == "fromRAM" for d in dma_starts)))
P("== CRC lines (first 25):")
for c in crcs[:25]:
    P("  " + c)

# small DMA payloads (data-in <=64 bytes, and all data-out) grouped by CDB opcode
P("\n== small DMA payloads by CDB (distinct payloads, count, first time)")
pay = collections.OrderedDict()
for ln in open(os.path.join(D, "dma5.log")):
    m = re.search(r"^(\S+).*?(CRC|OUTDATA) xfer#\d+ addr=(\w+) bytes=(\d+) crc32=(\w+) (?:first64|bytes)=\[([0-9a-f ]*)\] cdb=\[([0-9a-f ]*)\]", ln)
    if not m:
        continue
    t, kind, addr, nb, crc, data, cdb = m.groups()
    if int(nb) > 64:
        continue
    op = cdb.split()[1] if len(cdb.split()) > 1 else "?"
    key = (kind, op, data)
    if key not in pay:
        pay[key] = [0, float(t), float(t)]
    pay[key][0] += 1; pay[key][2] = float(t)
shown = collections.Counter()
for (kind, op, data), (n, t0, t1) in pay.items():
    shown[(kind, op)] += 1
    if shown[(kind, op)] > 12:
        continue
    P("  %-7s op=%s n=%3d first=%.3f last=%.3f [%s]" % ("IN" if kind == "CRC" else "OUT", op, n, t0, t1, data))

for k, v in shown.items():
    if v > 12:
        P("  (%s op=%s: %d more distinct payloads not shown)" % (k[0], k[1], v - 12))

# observed status sequences per kind (first instance)
P("\n== observed ST/SS/IS sequence per command kind (first instance)")
for k, l in kinds.items():
    P("  %-18s %s" % (k, " ".join(l[0]["obs"])))

# example raw sequences
def dump(title, tx, maxl=80):
    P("\n---- %s (t=%.6f)" % (title, tx["t"]))
    for r in tx["pre"][-14:]:
        P("   " + r["raw"])
    P("   >>> SELECT: CDB [%s] %s" % (" ".join("%02x" % b for b in tx["cdb"]), tx["desc"]))
    for r in tx["recs"][:maxl]:
        P("   " + r["raw"])
    for d in tx["dma"]:
        P("   DMA: " + d["raw"])
P("\n== EXAMPLE SEQUENCES")
first_sel_t = txs[0]["t"] if txs else 1e9
P("\n---- (a) controller init before first selection")
for r in [r for r in recs if r["t"] < first_sel_t and not (r["reg"] == 8 and 0 < r["val"] < 0xff)][:80]:
    P("   " + r["raw"])
conf1 = [r for r in recs if r["t"] < first_sel_t and r["reg"] == 8]
P("   (CONF1 write/readback walking test: %d CONF1 accesses before first select, values %02x..%02x)" % (
    len(conf1), min(r["val"] for r in conf1) if conf1 else 0, max(r["val"] for r in conf1) if conf1 else 0))
for k in ("TUR", "INQUIRY", "READ10", "PLAY_TRACK_INDEX", "READ_SUBCHANNEL", "MODE_SELECT6", "PAUSE_RESUME", "REQUEST_SENSE", "READ_TOC", "MODE_SENSE6"):
    if k in kinds:
        dump(k, kinds[k][0])

# ------------------------------------------------------------------ EEPROM decode
ee_lines = open(os.path.join(D, "eeprom.log")).read().splitlines()
default = None
if ZIP:
    try:
        with zipfile.ZipFile(ZIP) as z:
            raw = z.read("susume.25c")
        default = [(raw[2 * i] << 8) | raw[2 * i + 1] for i in range(64)]  # MAME stores big-endian words
    except Exception as e:
        P("could not read default eeprom:", e)
trans = []
cs = 0; clk = 0; bits = []; do_after = []; cur_do = None; tstart = 0
ev = []
for ln in ee_lines:
    if ln.startswith("   ("):
        continue
    f = ln.split()
    t = float(f[0])
    if "DI=" in ln:
        v = int(f[6], 16) & 0xff
        di_, cs_, clk_ = v & 1, (v >> 1) & 1, (v >> 2) & 1
        if cs_ and not cs:
            bits = []; do_after = []; tstart = t
        if cs_ and clk_ and not clk:
            bits.append(di_); do_after.append(None)
        if cs and not cs_ and bits:
            trans.append((tstart, bits, do_after))
            bits = []; do_after = []
        cs, clk = cs_, clk_
        ev.append(("w", t, v))
    elif "DO=" in ln:
        d = int(ln.split("DO=")[1])
        if do_after and do_after[-1] is None:
            do_after[-1] = d
        cur_do = d
if cs and bits:
    trans.append((tstart, bits, do_after))

def b2i(b):
    v = 0
    for x in b:
        v = (v << 1) | x
    return v
dec = []
for (t, bits, dos) in trans:
    # skip leading zeros before start bit
    i = 0
    while i < len(bits) and bits[i] == 0:
        i += 1
    if i + 9 > len(bits):
        dec.append((t, "INCOMPLETE bits=%s" % "".join(map(str, bits)), None)); continue
    op = b2i(bits[i + 1:i + 3]); addr = b2i(bits[i + 3:i + 9]); rest = bits[i + 9:]; restdo = dos[i + 9:]
    if op == 2:
        # DO reads after each subsequent clock; fill gaps with previous value
        vals = []
        last = 0
        for d in restdo:
            if d is None: d = last
            vals.append(d); last = d
        word = b2i(vals[:16]) if len(vals) >= 16 else None
        alt = b2i(vals[1:17]) if len(vals) >= 17 else None
        note = ""
        if default is not None:
            note = " default=%04x %s" % (default[addr], "MATCH" if word == default[addr] else ("MATCH(shift1)" if alt == default[addr] else "differs"))
        dec.append((t, "READ  addr=%02x data=%s (clocks after addr=%d)%s" % (addr, ("%04x" % word) if word is not None else "?", len(rest), note), ("R", addr, word)))
    elif op == 1:
        dec.append((t, "WRITE addr=%02x data=%04x" % (addr, b2i(rest[:16])), ("W", addr, b2i(rest[:16]))))
    elif op == 3:
        dec.append((t, "ERASE addr=%02x" % addr, ("E", addr, None)))
    else:
        sub = addr >> 4
        nm = {0: "EWDS", 1: "WRAL", 2: "ERAL", 3: "EWEN"}[sub]
        if sub == 1:
            nm += " data=%04x" % b2i(rest[:16])
        dec.append((t, nm, (nm[:4], addr, None)))
with open(os.path.join(D, "eeprom_decoded.log"), "w") as o:
    o.write("# time_s  transaction (93C46, 16-bit org; decoded from DI/CS/CLK writes and DO reads)\n")
    for t, s, _ in dec:
        o.write("%.6f %s\n" % (t, s))
P("\n== EEPROM: %d transactions" % len(dec))
c = collections.Counter(s.split()[0] for _, s, _ in dec)
P("  by type:", dict(c))
rd = sorted(set(x[2][1] for x in dec if x[2] and x[2][0] == "R"))
wr = [(t, x[2][1], x[2][2]) for t, s, x in [(a, b, (a, b, cc)) for a, b, cc in dec] if False]
P("  addresses read:", " ".join("%02x" % a for a in rd))
P("  writes:", " ".join("%.3f:%02x=%04x" % (t, x[1], x[2]) for t, s, x in dec if x and x[0] == "W"))
P("  other:", " ".join("%.3f:%s" % (t, s) for t, s, x in dec if x and x[0] not in ("R", "W")))
P("  read windows (time ranges):", " ".join("%.2f" % t for t, s, x in dec if x and x[0] == "R")[:400])

out.close()
print(open(os.path.join(D, "analysis.txt")).read()[:3000])
