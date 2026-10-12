#!/usr/bin/env python3
"""Builds WikiReader/Resources/ecdict.sqlite from ECDICT (https://github.com/skywind3000/ECDICT, MIT).

    python3 -I -X utf8 tools/make_dictionary.py path/to/ecdict.csv

The CSV is not kept in the repo (66 MB): download it with
    curl -L -o ecdict.csv https://raw.githubusercontent.com/skywind3000/ECDICT/master/ecdict.csv

Every entry that has a Chinese or English definition is kept (all ~770k, phrases included).
`pos`, `detail` and `audio` are dropped: the app doesn't use them.
The table is WITHOUT ROWID keyed on (lower, word), so the lookup index is the table itself.
"""
import csv, os, sqlite3, sys

csv.field_size_limit(10**9)
source = sys.argv[1]
out = os.path.join(os.path.dirname(__file__), "..", "WikiReader", "Resources", "ecdict.sqlite")
if os.path.exists(out):
    os.remove(out)

db = sqlite3.connect(out)
db.executescript("""
PRAGMA page_size = 4096;
PRAGMA journal_mode = OFF;
CREATE TABLE entries (
    lower TEXT NOT NULL,        -- word.lower(), what lookups use first
    word TEXT NOT NULL,         -- as written (case matters: "March" / "march")
    phonetic TEXT NOT NULL,
    definition TEXT NOT NULL,   -- English, one meaning per line (written as the two characters \\ n)
    translation TEXT NOT NULL,  -- Chinese, same layout
    collins INTEGER NOT NULL,   -- 0...5 stars
    oxford INTEGER NOT NULL,    -- 1 = Oxford 3000
    tag TEXT NOT NULL,          -- "zk gk cet4 cet6 ky toefl ielts gre"
    bnc INTEGER NOT NULL,       -- frequency ranks, 0 = unknown
    frq INTEGER NOT NULL,
    exchange TEXT NOT NULL,     -- "p:went/d:gone/i:going/3:goes" or "0:go/1:p" (lemma)
    PRIMARY KEY (lower, word)
) WITHOUT ROWID;
""")

def number(text):
    return int(text) if text and text.strip().isdigit() else 0

rows, seen = [], set()
with open(source, encoding="utf-8", newline="") as f:
    for r in csv.DictReader(f):
        word = (r["word"] or "").strip()
        definition, translation = (r["definition"] or "").strip(), (r["translation"] or "").strip()
        if not word or not (definition or translation):
            continue
        key = (word.lower(), word)
        if key in seen:
            continue
        seen.add(key)
        rows.append((key[0], word, (r["phonetic"] or "").strip(), definition, translation,
                     number(r["collins"]), number(r["oxford"]), (r["tag"] or "").strip(),
                     number(r["bnc"]), number(r["frq"]), (r["exchange"] or "").strip()))

db.executemany("INSERT INTO entries VALUES (?,?,?,?,?,?,?,?,?,?,?)", rows)
db.commit()
db.execute("VACUUM")
db.close()
print(f"{len(rows)} entries, {os.path.getsize(out) / 1e6:.1f} MB -> {os.path.normpath(out)}")
