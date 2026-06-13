#!/bin/bash
# Runs every test file in the corpus dir against the built bench.
set -u
TARGET_DIR="${1:-./fpu_tests}"
PROGRAM="./obj_dir/Vfpu_tests"

if [ ! -d "$TARGET_DIR" ]; then
    echo "Corpus dir '$TARGET_DIR' not found."
    echo "Hint: no canonical 68881 corpus exists yet — see SingleStepTests/README.md"
    exit 1
fi
if [ ! -x "$PROGRAM" ]; then
    echo "Bench not built: run 'make' first."
    exit 1
fi

find "$TARGET_DIR" -type f -name '*.json' | sort | while read -r file; do
    echo "Processing: $file"
    "$PROGRAM" "$file" || exit 1
done
