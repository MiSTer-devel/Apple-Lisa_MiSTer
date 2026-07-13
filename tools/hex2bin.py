import sys

def hex2bin(hexfile, binfile):
    data = []

    # Read hex bytes from file
    with open(hexfile, "r") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue  # skip blank lines
            try:
                value = int(line, 16)
            except ValueError:
                raise ValueError(f"Invalid hex byte: '{line}'")
            if value < 0 or value > 255:
                raise ValueError(f"Out-of-range byte: {value}")
            data.append(value)

    # Write binary file
    with open(binfile, "wb") as f:
        f.write(bytes(data))

    print(f"Wrote {len(data)} bytes to {binfile}")

if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Usage: hex2bin.py ROM.hex ROM.bin")
        sys.exit(1)

    hex2bin(sys.argv[1], sys.argv[2])

