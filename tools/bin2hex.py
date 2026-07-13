import sys

def bin2hex(binfile, hexfile):
    with open(binfile, "rb") as f:
        data = f.read()

    with open(hexfile, "w") as f:
        for b in data:
            f.write(f"{b:02x}\n")

    print(f"Wrote {len(data)} bytes to {hexfile}")

if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Usage: bin2hex.py ROM.bin ROM.hex")
        sys.exit(1)

    bin2hex(sys.argv[1], sys.argv[2])
