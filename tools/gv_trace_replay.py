#!/usr/bin/env python3
"""Build a register-level replay of MAME's Susume SCSI traffic for tb_gv_replay.vhd.

Inputs (never committed: derived from the user's own media/trace):
  --trace  <dir>  MAME trace logs (ncr.log, dma5.log) from tools/mame_trace (see docs/MAME_REFERENCE.md)
  --cue    <cue>  single-BIN CUE extracted from the CHD with chdman (temporary test derivative)
  --out    <dir>  output root; creates replay/, ee/ and cdda/ for sim_gv/run_gv_regression.sh
  --zip    <zip>  susume.zip (for susume.25c, the EEPROM default image)

Outputs:
  replay.txt   one op per line:
                 W <byteaddr> <data>         EXP1 byte write (offset from 0x1F000000)
                 R <byteaddr> <expect> <w>   EXP1 byte read; w=1: wait for IRQ10 first (ISR entry)
                 D <xfer> <dir> <words>      start DMA ch5 (dir 0 = to RAM, 1 = from RAM)
                 P <word>...                 payload words for the preceding from-RAM D op
  toc.txt      32-bit words of MiSTer Main's struct disk_t (ioctl index 251), one hex word per line
  sectors.txt  "S <hps_lba>" followed by 1176 hex 16-bit words (little-endian pairs, as sd_buff_dout)
  expect.txt   "<xfer> <bytes> <crc32> <opcode>" for every to-RAM transfer MAME made
"""
import argparse, os, re, struct, zlib

def parse_cue(path):
    tracks = []
    with open(path) as f:
        for line in f:
            l = line.strip()
            m = re.match(r'TRACK (\d+) (\S+)', l)
            if m:
                tracks.append({'num': int(m.group(1)), 'type': m.group(2)})
            m = re.match(r'INDEX 01 (\d+):(\d+):(\d+)', l)
            if m:
                mm, ss, ff = map(int, m.groups())
                tracks[-1]['start'] = (mm * 60 + ss) * 75 + ff
    binpath = os.path.join(os.path.dirname(path), re.search(r'FILE "(.*)"', open(path).read()).group(1))
    return tracks, binpath

def disk_t(tracks, total_frames):
    """MiSTer Main support/psx/psx.cpp send_cue_and_metadata() for a single-BIN CUE without pregaps."""
    bcd = lambda v: ((v // 10) << 4) | (v % 10)
    n = len(tracks)
    # load_cue: track 0 start = 150 (implicit pregap), later tracks: start + 150
    starts = [t['start'] + 150 for t in tracks]
    ends = [starts[i + 1] - 1 for i in range(n - 1)] + [total_frames + 150 - 1]
    end = ends[-1] + 1
    words = [(bcd(n) << 8) | n, end]
    m, s = (end // 75) // 60, (end // 75) % 60
    words.append((bcd(m) << 8) | bcd(s))
    words.append(0)                                       # libcrypt 0, metadata 0 (no reset request in sim)
    for i in range(99):
        if i < n:
            start_lba = starts[i] if i else 0
            idx1 = 150 if i == 0 else 0
            mm, ss = ((start_lba + idx1) // 75) // 60, ((start_lba + idx1) // 75) % 60
            audio = 1 if tracks[i]['type'] == 'AUDIO' else 0
            words += [start_lba, ends[i], (bcd(mm) << 8) | bcd(ss) | (audio << 16), 0]
        else:
            words += [0, 0, 0, 0]
    return words

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--trace', required=True)
    ap.add_argument('--cue', required=True)
    ap.add_argument('--out', required=True)
    ap.add_argument('--zip', required=True)
    ap.add_argument('--until', type=float, default=1e9, help='stop replay at this emulated time')
    a = ap.parse_args()
    root = a.out
    a.out = os.path.join(root, 'replay')
    os.makedirs(a.out, exist_ok=True)

    tracks, binpath = parse_cue(a.cue)
    total = os.path.getsize(binpath) // 2352
    with open(os.path.join(a.out, 'toc.txt'), 'w') as f:
        for w in disk_t(tracks, total):
            f.write('%08x\n' % w)

    events = []   # (time, seq, kind, payload)
    seq = 0
    for line in open(os.path.join(a.trace, 'ncr.log')):
        p = line.split()
        if len(p) < 7 or not re.match(r'^[0-9.]+$', p[0]):
            continue
        t = float(p[0]); addr = int(p[3], 16); rw = p[4]; mask = int(p[5], 16); data = int(p[6], 16)
        lane = [0x000000ff, 0x0000ff00, 0x00ff0000, 0xff000000].index(mask)
        events.append((t, seq, rw, ((addr - 0x1F000000) + lane, (data >> (8 * lane)) & 0xFF)))
        seq += 1

    out_payload = {}
    for line in open(os.path.join(a.trace, 'dma5.log')):
        m = re.search(r'OUTDATA xfer#(\d+) .*bytes=\[([0-9a-f ]+)\]', line)
        if m:
            out_payload[int(m.group(1))] = bytes(int(x, 16) for x in m.group(2).split())
    expects = []
    for line in open(os.path.join(a.trace, 'dma5.log')):
        p = line.split()
        m = re.search(r'D5_CHCR dir=(\w+) .*XFER#(\d+) addr=\w+ words=(\d+)', line)
        if m:
            events.append((float(p[0]), seq, 'D', (int(m.group(2)), 0 if m.group(1) == 'toRAM' else 1, int(m.group(3)))))
            seq += 1
        m = re.search(r'CRC xfer#(\d+) addr=\w+ bytes=(\d+) crc32=([0-9a-f]+).*cdb=\[80 ([0-9a-f]+)', line)
        if m and float(p[0]) <= a.until:
            expects.append((int(m.group(1)), int(m.group(2)), m.group(3), m.group(4)))

    events.sort()
    reads = []
    prev_kind = None
    nops = 0
    with open(os.path.join(a.out, 'replay.txt'), 'w') as f:
        for t, _, kind, v in events:
            if t > a.until:
                break
            if kind == 'W':
                f.write('W %06x %02x\n' % v)
            elif kind == 'R':
                addr, data = v
                # ISR entry: a STATUS read with the interrupt bit set that does not directly follow
                # another status-group read -> the CPU only gets here after IRQ10
                wait = 1 if (addr == 0x08 and (data & 0x80) and prev_kind not in ('R4', 'R5', 'R6')) else 0
                f.write('R %06x %02x %d\n' % (addr, data, wait))
                kind = 'R%d' % (addr >> 1) if addr < 0x20 else 'R'
            elif kind == 'D':
                xfer, d, words = v
                f.write('D %d %d %d\n' % (xfer, d, words))
                if d == 1:
                    pl = out_payload[xfer]
                    f.write('P ' + ' '.join('%08x' % struct.unpack('<I', pl[i:i + 4])[0] for i in range(0, len(pl), 4)) + '\n')
            prev_kind = kind
            nops += 1
    with open(os.path.join(a.out, 'expect.txt'), 'w') as f:
        for e in expects:
            f.write('%d %d %s %s\n' % e)

    # sectors: every LBA read by READ(10) (from the decoded log)
    lbas = set()
    for line in open(os.path.join(a.trace, 'scsi_decoded.log')):
        m = re.search(r'READ\(10\) LBA=(\d+) .*blocks=(\d+)', line)
        if m and float(line.split()[0]) <= a.until:
            s, n = int(m.group(1)), int(m.group(2))
            lbas.update(range(s, s + n + 2))                # + read-ahead
    with open(binpath, 'rb') as b, open(os.path.join(a.out, 'sectors.txt'), 'w') as f:
        for l in sorted(lbas):
            if l >= total:
                continue
            b.seek(l * 2352)
            raw = b.read(2352)
            f.write('S %d\n' % (l + 150))
            ws = struct.unpack('<1176H', raw)
            for i in range(0, 1176, 24):
                f.write(' '.join('%04x' % w for w in ws[i:i + 24]) + '\n')
    print('ops=%d xfers=%d sectors=%d tracks=%d frames=%d' % (nops, len(expects), len(lbas), len(tracks), total))


    # EEPROM: MAME's 93C46 bit-bang + P1 DO reads, and the default image
    import zipfile
    ee = os.path.join(root, 'ee'); os.makedirs(ee, exist_ok=True)
    zf = zipfile.ZipFile(a.zip)
    img = zf.read(next(n for n in zf.namelist() if n.endswith('.25c')))
    with open(os.path.join(ee, 'ee_init.txt'), 'w') as f:
        for i in range(64):
            f.write('%02x%02x\n' % (img[2 * i], img[2 * i + 1]))
    n = 0
    with open(os.path.join(ee, 'replay.txt'), 'w') as out:
        for line in open(os.path.join(a.trace, 'eeprom.log')):
            p = line.split()
            if len(p) < 7 or not re.match(r'^[0-9.]+$', p[0]):
                continue
            addr = int(p[3], 16); v = int(p[6], 16)
            if p[4] == 'W':
                out.write('W 180000 %02x\n' % (v & 0xff)); n += 1
            elif addr == 0x1f100000:
                out.write('R 100000 %02x 0\nR 100001 %02x 0\n' % (v & 0xff, (v >> 8) & 0xff)); n += 2
    for name, txt in (('toc.txt', '00000000\n'), ('sectors.txt', ''), ('expect.txt', '')):
        open(os.path.join(ee, name), 'w').write(txt)
    print('eeprom ops=%d' % n)

    # CD-DA: first 6 frames of track 6 (the first track Susume plays); skipped for discs without it
    if len(tracks) < 6 or tracks[5]['type'] != 'AUDIO':
        print('cdda vectors skipped (no audio track 6)')
        return
    cd = os.path.join(root, 'cdda'); os.makedirs(cd, exist_ok=True)
    t6 = tracks[5]['start']
    with open(binpath, 'rb') as b:
        with open(os.path.join(cd, 'sectors.txt'), 'w') as f:
            for l in range(t6, t6 + 6):
                b.seek(l * 2352); ws = struct.unpack('<1176H', b.read(2352))
                f.write('S %d\n' % (l + 150))
                for i in range(0, 1176, 24):
                    f.write(' '.join('%04x' % w for w in ws[i:i + 24]) + '\n')
        b.seek(t6 * 2352); ws = struct.unpack('<%dH' % (1176 * 6), b.read(2352 * 6))
    with open(os.path.join(cd, 'expect_samples.txt'), 'w') as f:
        for i in range(588 * 6):
            f.write('%04x %04x\n' % (ws[2 * i], ws[2 * i + 1]))
    with open(os.path.join(cd, 'toc.txt'), 'w') as f:
        for w in disk_t(tracks, total):
            f.write('%08x\n' % w)
    print('cdda track 6 start=%d' % t6)

if __name__ == '__main__':
    main()
