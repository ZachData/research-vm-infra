Read PROJECT.md (or README.md if there is no PROJECT.md) and CLAUDE.md. Take
the first unfinished item on the status board, in order. Follow the repo's own
development rules: write the test first, implement, run the test suite, and
only proceed if it is green.

If the item is a sweep — many independent cells — do not run the cells here.
Decide the split, write sweep_manifest.json with the schema
{"workers": [{"worker_id": 0, ...}]}, create an empty file NEEDS_WORKERS at the
repo root, mark the item in progress, commit, and stop.

Otherwise do the work directly. Mark the item in progress when you start and
done or failed when you finish. Record any decision you made and anything
surprising you found, in the places the repo keeps them. Commit with a real
message and push.
