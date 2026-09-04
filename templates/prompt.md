Pick the next unit of work, in this order:

1. Open GitHub issues on this repo labelled `agent` (`gh issue list --label agent --state open`), oldest first.
2. Open questions in `PROJECT.md` §10, in the order they're listed.
3. The first unchecked item in `backlog/TASKS.md`, if that file exists.
4. The first unfinished item on `PROJECT.md`'s status board, in order.

Read `PROJECT.md` (or `README.md` if there is no `PROJECT.md`) and `CLAUDE.md`
before starting. Follow the repo's own development rules: write the test
first, implement, run the test suite, and only proceed if it is green.

If the item is a sweep — many independent cells — do not run the cells here.
Decide the split, write sweep_manifest.json with the schema
{"workers": [{"worker_id": 0, ...}]}, create an empty file NEEDS_WORKERS at the
repo root, mark the item in progress, commit, and stop.

Otherwise do the work directly. Mark the item in progress when you start and
done or failed when you finish. Record any decision you made and anything
surprising you found, in the places the repo keeps them.

Never push directly to `main`. Commit with a real message, push to a branch,
and open a pull request (`gh pr create`) for a human to review and merge. A
reviewer-agent pass, if the repo has one configured, is advisory only — it
does not merge.
