#!/usr/bin/env python3
"""Summarise a CSV of sales."""
import csv
from dataclasses import dataclass


@dataclass
class Row:
    region: str
    amount: float


def load(path: str) -> list[Row]:
    with open(path, newline="") as handle:
        return [Row(r["region"], float(r["amount"])) for r in csv.DictReader(handle)]


def total(rows, region=None):
    # None means every region
    return sum(r.amount for r in rows if region in (None, r.region))


if __name__ == "__main__":
    rows = load("sales.csv")
    print(f"Total: {total(rows):,.2f}")
