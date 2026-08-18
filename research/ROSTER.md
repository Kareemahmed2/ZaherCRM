# Roster-driven scanning

## The problem this solves

The weekly research prompt currently carries a hand-written baseline of every tracked competitor —
23 companies as of 18 Aug 2026. That baseline has two failure modes and both get worse over time:

1. **It goes stale.** The moment a scan writes a change to Supabase, the prompt's copy is wrong.
   Someone has to hand-edit the scheduled task every week or the delta logic drifts.
2. **It doesn't scale.** Every new competitor makes the prompt longer. Adding one to the CRM does
   nothing until a human also adds it to the prompt.

The fix is to generate the baseline from the database.

## The loop

```
Mon 06:00 UTC   competitor-scan.yml
                  -> scraper health-checks sites, queues signals
                  -> export_roster.py writes research/roster.json
                  -> job commits it back

Mon 08:00 UTC   Cowork scheduled research run
                  -> fetches roster.json
                  -> researches, diffs against it, emits a delta CSV

on push         apply-research.yml
                  -> applies the delta to Supabase

next Monday     roster.json regenerates from the updated DB
```

Nobody hand-maintains a baseline again, and adding a competitor to the CRM automatically puts it
in next week's scan. The 06:00 / 08:00 gap already in your schedule gives the export two hours to
land before the research run reads it.

## Wiring it up

### 1. Add the export step to `competitor-scan.yml`

The job already has `SUPABASE_SERVICE_ROLE_KEY`. Committing back needs no new PAT — Actions
provides `GITHUB_TOKEN` automatically; it just needs write permission on the job.

```yaml
jobs:
  scan:
    runs-on: ubuntu-latest
    timeout-minutes: 20
    permissions:
      contents: write          # <-- lets the automatic GITHUB_TOKEN commit roster.json
    steps:
      # ... existing checkout / setup-python / pip install / competitor_scan.py steps ...

      - name: Export competitor roster
        # Only on the full weekly scan — a single-competitor "Check now" run would write a
        # roster reflecting one row and clobber the real one.
        if: ${{ !inputs.competitor_id }}
        run: python scripts/export_roster.py
        env:
          SUPABASE_SERVICE_ROLE_KEY: ${{ secrets.SUPABASE_SERVICE_ROLE_KEY }}

      - name: Commit roster
        if: ${{ !inputs.competitor_id }}
        run: |
          set -euo pipefail
          git config user.name  "competitor-scan[bot]"
          git config user.email "competitor-scan@users.noreply.github.com"
          git add research/roster.json
          # generatedAt changes every run, so only commit when something real moved.
          if git diff --cached --quiet -- research/roster.json; then
            echo "roster unchanged"; exit 0
          fi
          if [ "$(git diff --cached --numstat -- research/roster.json | awk '{print $1+$2}')" -le 2 ]; then
            echo "only the timestamp moved — skipping commit"; git reset; exit 0
          fi
          git commit -m "chore: refresh competitor roster [skip ci]"
          git push
```

`[skip ci]` matters: `apply-research.yml` watches `research/**`, and a roster commit is not a delta
CSV. Without it the two workflows would ping-pong.

### 2. Decide how the research run fetches it

The Cowork run has no repo access and no credentials. Two options:

**If ZaherCRM is public** — nothing to do. The run fetches:
```
https://raw.githubusercontent.com/Kareemahmed2/ZaherCRM/master/research/roster.json
```

**If ZaherCRM is private** — `raw.githubusercontent.com` needs a token, and putting a token in a
scheduled prompt is worse than the problem it solves. Serve it from Vercel instead, which you
already run, at an unguessable path:

```js
// api/competitor-roster.js — returns the committed roster.json
// Set ROSTER_KEY in Vercel env to a long random string.
export default async function handler(req, res) {
  if (req.query.k !== process.env.ROSTER_KEY) { res.status(404).end(); return; }
  const r = await fetch('https://api.github.com/repos/Kareemahmed2/ZaherCRM/contents/research/roster.json?ref=master', {
    headers: { Authorization: `Bearer ${process.env.GITHUB_DISPATCH_TOKEN}`,
               Accept: 'application/vnd.github.raw' }
  });
  if (!r.ok) { res.status(502).json({ error: await r.text() }); return; }
  res.setHeader('Content-Type', 'application/json');
  res.send(await r.text());
}
```
The GitHub token stays server-side, exactly like `api/trigger-competitor-scan.js` already does with
`GITHUB_DISPATCH_TOKEN` (it needs `contents:read` added). The scheduled prompt then holds only a
URL whose worst-case leak is a list of competitor names.

### 3. Amend the scheduled prompt

Replace the hand-written `PART 1` baseline with the block in `roster_prompt_patch.md`. It carves one
narrow exception to the no-bash rule — curl is allowed for the roster file and nothing else — and
tells the run to treat the roster as authoritative where it disagrees with anything inline.

## Why curl and not WebFetch

`WebFetch` renders a page and answers a prompt against it with a small model. For a 35 KB JSON
baseline that is lossy: the run would get a summary, not the values, and would then "detect changes"
that are really summarisation artifacts. `curl` + `Read` gives the file verbatim.

This does not weaken the evidence bar. The no-bash rule exists so that *claims about competitors*
come from sources the run actually retrieved and can cite. Downloading your own database export is
not research — it's reading the baseline. Everything about the competitors themselves still goes
through WebSearch/WebFetch.

## Size

Roughly 1.5 KB per competitor with full prose, so ~35 KB at 23 competitors. Prose is included in
full on purpose: the delta rule ("write a cell only where the value changed") is only enforceable if
the researcher can see the current value. `--compact` drops prose if it ever gets unwieldy, at the
cost of worse deltas.
