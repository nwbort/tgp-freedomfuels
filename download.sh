#!/usr/bin/env bash
#
# download - Downloads TGP page and extracts the price table to CSV files
# Usage: ./download.sh URL

set -e

# Check if URL provided
if [ $# -ne 1 ]; then
  echo "Usage: $0 URL"
  exit 1
fi

URL="$1"

# Validate URL format (must start with http:// or https://)
if [[ ! "$URL" =~ ^https?:// ]]; then
  echo "Error: URL must start with http:// or https://"
  exit 1
fi

# Create temporary file
TEMP_FILE=$(mktemp)

# Download the file
echo "Downloading $URL"
curl -s -L "$URL" \
  -H "User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36" \
  -o "$TEMP_FILE" || {
  echo "Error: Failed to download $URL"
  rm -f "$TEMP_FILE"
  exit 1
}

CURRENT_DIR="$(pwd)"
CURRENT_CSV="${CURRENT_DIR}/tgp-freedomfuels-current.csv"
HISTORY_CSV="${CURRENT_DIR}/tgp-freedomfuels-history.csv"

# Extract table to CSV using Python
python3 - "$TEMP_FILE" "$CURRENT_CSV" "$HISTORY_CSV" <<'PYEOF'
import sys
import csv
import os
from html.parser import HTMLParser

html_file = sys.argv[1]
current_csv = sys.argv[2]
history_csv = sys.argv[3]

class TableParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.tables = []
        self._in_table = False
        self._in_row = False
        self._in_cell = False
        self._current_table = []
        self._current_row = []
        self._current_cell = []
        self._depth = 0  # track nested tables

    def handle_starttag(self, tag, attrs):
        if tag == 'table':
            if self._in_table:
                self._depth += 1
            else:
                self._in_table = True
                self._current_table = []
                self._depth = 0
        elif tag in ('tr',) and self._in_table and self._depth == 0:
            self._in_row = True
            self._current_row = []
        elif tag in ('td', 'th') and self._in_row and self._depth == 0:
            self._in_cell = True
            self._current_cell = []

    def handle_endtag(self, tag):
        if tag == 'table':
            if self._depth > 0:
                self._depth -= 1
            else:
                if self._current_table:
                    self.tables.append(self._current_table)
                self._in_table = False
                self._current_table = []
        elif tag == 'tr' and self._in_table and self._depth == 0:
            if self._current_row:
                self._current_table.append(self._current_row)
            self._in_row = False
            self._current_row = []
        elif tag in ('td', 'th') and self._in_row and self._depth == 0:
            cell_text = ' '.join(''.join(self._current_cell).split())
            self._current_row.append(cell_text)
            self._in_cell = False
            self._current_cell = []

    def handle_data(self, data):
        if self._in_cell:
            self._current_cell.append(data)

    def handle_entityref(self, name):
        if self._in_cell:
            entities = {'amp': '&', 'lt': '<', 'gt': '>', 'nbsp': ' ', 'quot': '"'}
            self._current_cell.append(entities.get(name, ''))

    def handle_charref(self, name):
        if self._in_cell:
            try:
                if name.startswith('x'):
                    self._current_cell.append(chr(int(name[1:], 16)))
                else:
                    self._current_cell.append(chr(int(name)))
            except (ValueError, OverflowError):
                pass


with open(html_file, 'r', encoding='utf-8', errors='replace') as f:
    html = f.read()

parser = TableParser()
parser.feed(html)

if not parser.tables:
    print("Error: No tables found in the HTML", file=sys.stderr)
    sys.exit(1)

# Pick the largest table (most rows) as the TGP table
tgp_table = max(parser.tables, key=lambda t: len(t))

if len(tgp_table) < 2:
    print("Error: Table has fewer than 2 rows", file=sys.stderr)
    sys.exit(1)

print(f"Found table with {len(tgp_table)} rows and {len(tgp_table[0])} columns")

# Write current CSV (overwrite)
with open(current_csv, 'w', newline='', encoding='utf-8') as f:
    writer = csv.writer(f)
    for row in tgp_table:
        writer.writerow(row)
print(f"Written: {current_csv}")

# Append new unique rows to history CSV
# Load existing history rows as a set of tuples for dedup
existing_rows = set()
history_has_header = False
if os.path.exists(history_csv) and os.path.getsize(history_csv) > 0:
    with open(history_csv, 'r', newline='', encoding='utf-8') as f:
        reader = csv.reader(f)
        rows = list(reader)
        if rows:
            history_has_header = True
            # Skip header row from dedup check (index 0)
            for row in rows[1:]:
                existing_rows.add(tuple(row))

header = tgp_table[0]
data_rows = tgp_table[1:]

new_rows = [row for row in data_rows if tuple(row) not in existing_rows]

with open(history_csv, 'a', newline='', encoding='utf-8') as f:
    writer = csv.writer(f)
    if not history_has_header:
        writer.writerow(header)
    for row in new_rows:
        writer.writerow(row)

print(f"Appended {len(new_rows)} new row(s) to: {history_csv}")

PYEOF

rm -f "$TEMP_FILE"
