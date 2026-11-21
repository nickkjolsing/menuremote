"""Convert the bundled Bitcoin SVG paths to a resolution-independent macOS PDF.

Source: https://bitcoin.design/guide/getting-started/visual-language/
Only the M/L/C/S/Z path commands used by this asset are supported.
"""

from pathlib import Path
import re
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[1]
svg = ET.parse(ROOT / "Support/BitcoinMark.svg").getroot()
_, _, width, height = map(float, svg.attrib["viewBox"].split())
commands = [f"1 0 0 -1 0 {height:g} cm"]

for element in svg.findall("{http://www.w3.org/2000/svg}path"):
    commands.append("1 1 1 rg" if element.attrib["class"] == "st0" else "0.968627451 0.576470588 0.101960784 rg")
    tokens = re.findall(r"[A-Za-z]|[-+]?(?:\d*\.\d+|\d+\.?\d*)(?:[eE][-+]?\d+)?", element.attrib["d"])
    index = 0
    command = None
    point = (0.0, 0.0)
    start = point
    control = None
    while index < len(tokens):
        if tokens[index].isalpha():
            command = tokens[index]
            index += 1
        if command in ("Z", "z"):
            commands.append("h")
            point = start
            control = None
            command = None
            continue
        assert command in ("M", "m", "L", "l", "C", "c", "S", "s"), command
        count = {"C": 6, "S": 4}.get(command.upper(), 2)
        values = list(map(float, tokens[index:index + count]))
        assert len(values) == count
        index += count
        if command.islower():
            values = [value + point[i % 2] for i, value in enumerate(values)]
        if command.upper() == "S":
            first = tuple(2 * point[i] - control[i] for i in range(2)) if control else point
            values = list(first) + values
        operation = {"M": "m", "L": "l", "C": "c", "S": "c"}[command.upper()]
        commands.append(" ".join(f"{value:.8f}" for value in values) + " " + operation)
        point = tuple(values[-2:])
        control = tuple(values[-4:-2]) if operation == "c" else None
        if command.upper() == "M":
            start = point
            command = "l" if command.islower() else "L"
    commands.append("f")

stream = ("\n".join(commands) + "\n").encode("ascii")
objects = [
    b"<< /Type /Catalog /Pages 2 0 R >>",
    b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {width:g} {height:g}] /Resources << >> /Contents 4 0 R >>".encode(),
    f"<< /Length {len(stream)} >>\nstream\n".encode() + stream + b"endstream",
]
pdf = bytearray(b"%PDF-1.4\n% Bitcoin Design vector mark\n")
offsets = [0]
for number, obj in enumerate(objects, start=1):
    offsets.append(len(pdf))
    pdf.extend(f"{number} 0 obj\n".encode() + obj + b"\nendobj\n")
xref = len(pdf)
pdf.extend(f"xref\n0 {len(offsets)}\n0000000000 65535 f \n".encode())
for offset in offsets[1:]:
    pdf.extend(f"{offset:010d} 00000 n \n".encode())
pdf.extend(f"trailer\n<< /Size {len(offsets)} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode())
destination = ROOT / "Support/BitcoinMark.pdf"
destination.write_bytes(pdf)
print(f"Wrote {destination}")
