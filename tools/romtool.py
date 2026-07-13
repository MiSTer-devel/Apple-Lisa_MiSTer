#!/usr/bin/env python3
import argparse
import sys
from pathlib import Path

def fuse(upper_path: Path, lower_path: Path, out_path: Path):
    upper = upper_path.read_bytes()
    lower = lower_path.read_bytes()

    if len(upper) != len(lower):
        sys.exit("Error: Upper and lower ROM files must be the same size")

    fused = bytearray()
    for u, l in zip(upper, lower):
        fused.append(u)
        fused.append(l)

    out_path.write_bytes(fused)
    print(f"Fused {len(upper)}+{len(lower)} bytes into {len(fused)} bytes: {out_path}")

def split(fused_path: Path, upper_path: Path, lower_path: Path):
    fused = fused_path.read_bytes()

    if len(fused) % 2 != 0:
        sys.exit("Error: Fused ROM size must be even")

    upper = fused[0::2]
    lower = fused[1::2]

    upper_path.write_bytes(upper)
    lower_path.write_bytes(lower)
    print(f"Split {len(fused)} bytes into {len(upper)} and {len(lower)}")

def main():
    parser = argparse.ArgumentParser(description="Fuse or split 16-bit ROM binary files")
    subparsers = parser.add_subparsers(dest="command", required=True)

    # Fuse command
    fuse_parser = subparsers.add_parser("fuse", help="Fuse upper and lower ROMs into one file")
    fuse_parser.add_argument("upper", type=Path, help="Upper byte ROM file")
    fuse_parser.add_argument("lower", type=Path, help="Lower byte ROM file")
    fuse_parser.add_argument("output", type=Path, help="Output fused file")

    # Split command
    split_parser = subparsers.add_parser("split", help="Split fused ROM into upper and lower files")
    split_parser.add_argument("fused", type=Path, help="Fused ROM file")
    split_parser.add_argument("upper", type=Path, help="Output upper ROM file")
    split_parser.add_argument("lower", type=Path, help="Output lower ROM file")

    args = parser.parse_args()

    if args.command == "fuse":
        fuse(args.upper, args.lower, args.output)
    elif args.command == "split":
        split(args.fused, args.upper, args.lower)

if __name__ == "__main__":
    main()