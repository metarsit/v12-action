#!/usr/bin/env python3
"""Independent implementation of the gate rule, used as the test oracle.

Usage: oracle.py FIXTURE FAIL_ON INCLUDE_VALIDITY(comma) IGNORE_AUTO(true/false) MIN_SEVERITY
Prints: total gate critical high medium low info qa
"""
import json
import sys

SEV = ["critical", "high", "medium", "low", "info", "qa"]

fixture, fail_on, include_validity, ignore_auto, min_sev = sys.argv[1:6]
include = set(include_validity.split(","))
ignore = ignore_auto == "true"
findings = json.load(open(fixture, encoding="utf-8"))

kept = []
for f in findings:
    if f["validity"] not in include:
        continue
    if ignore and f.get("autoInvalidated") and f["validity"] == "unreviewed":
        continue
    if SEV.index(f["severity"]) > SEV.index(min_sev):
        continue
    kept.append(f)

gate = 0 if fail_on == "none" else sum(1 for f in kept if SEV.index(f["severity"]) <= SEV.index(fail_on))
counts = {s: sum(1 for f in kept if f["severity"] == s) for s in SEV}
print(len(kept), gate, *[counts[s] for s in SEV])
