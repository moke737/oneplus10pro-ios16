# make-zero-area.py - build a tiny Android sparse image that writes zeros over
# one firmware area of userdata and touches nothing else.
#
# Sparse format (AOSP):
#   header: magic, major, minor, file_hdr_sz, chunk_hdr_sz, blk_sz,
#           total_blks, total_chunks, checksum
#   chunk:  type, reserved, chunk_sz, total_sz [, payload]
#   types:  0xCAC1 raw, 0xCAC2 fill, 0xCAC3 don't care
#
# Usage:
#   python3 make-zero-area.py OUT.simg --blocks 58672399 --start 58669326 --count 2048
import argparse
import struct
import sys

MAGIC = 0xED26FF3A
BLK = 4096
T_RAW, T_FILL, T_DONT = 0xCAC1, 0xCAC2, 0xCAC3


def hdr(total_blks: int, chunks: int) -> bytes:
    return struct.pack('<IHHHHIIII', MAGIC, 1, 0, 28, 12, BLK, total_blks, chunks, 0)


def dont_care(n: int) -> bytes:
    return struct.pack('<HHII', T_DONT, 0, n, 12)


def fill(n: int, value: int = 0) -> bytes:
    return struct.pack('<HHII', T_FILL, 0, n, 16) + struct.pack('<I', value)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('out')
    ap.add_argument('--blocks', type=int, required=True, help='userdata size in 4096-byte blocks')
    ap.add_argument('--start', type=int, required=True, help='first block to zero')
    ap.add_argument('--count', type=int, required=True, help='number of blocks to zero')
    a = ap.parse_args()

    if a.start < 0 or a.count <= 0 or a.start + a.count > a.blocks:
        print('range outside the partition', file=sys.stderr)
        return 2

    chunks = []
    # The three ranges must cover the whole partition: before, the zeros, after.
    if a.start > 0:
        chunks.append(dont_care(a.start))
    chunks.append(fill(a.count, 0))
    tail = a.blocks - a.start - a.count
    if tail > 0:
        chunks.append(dont_care(tail))

    with open(a.out, 'wb') as f:
        f.write(hdr(a.blocks, len(chunks)))
        for c in chunks:
            f.write(c)

    print(f'{a.out}: {len(chunks)} chunks, zeros at block {a.start}..{a.start + a.count - 1} '
          f'({a.count} blocks = {a.count * BLK // 1024} KiB), {a.blocks} blocks total')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
