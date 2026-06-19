#!/usr/bin/env python3
# Extract selected top-level (report ...) forms from tests/kerneltests.shen into
# a mini harness file, preserving order. Usage:
#   python3 extract_reports.py OUT.shen 0 1 2 17     # include report indices
import sys

out = sys.argv[1]
want = set(int(x) for x in sys.argv[2:])

src = open("tests/kerneltests.shen").read()
# split into balanced top-level parenthesized forms
forms = []
depth = 0; start = None
for i, c in enumerate(src):
    if c == '(':
        if depth == 0: start = i
        depth += 1
    elif c == ')':
        depth -= 1
        if depth == 0:
            forms.append(src[start:i+1])

reports = [f for f in forms if f.lstrip().startswith("(report")]
chosen = [reports[i] for i in sorted(want) if i < len(reports)]
with open(out, "w") as f:
    f.write("\n\n".join(chosen) + "\n")
print("wrote %d reports to %s: %s" % (len(chosen), out, sorted(want)))
