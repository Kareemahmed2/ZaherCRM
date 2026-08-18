# Scheduled-prompt patch — roster-driven baseline

Paste this in place of the hand-written `PART 1 — RE-CHECK THE TRACKED DIRECTORY` baseline list,
once `roster.json` is reachable. Set `<ROSTER_URL>` first.

Keep the `CROSS-CUTTING BASELINE` block that follows the list — those are standing rules, not
per-competitor state, and the roster does not carry them.

---

═══════════════════════════════════════════════════════════════
PART 1 — RE-CHECK THE TRACKED DIRECTORY
═══════════════════════════════════════════════════════════════
FIRST, FETCH THE ROSTER. The directory is generated from the CRM database, not written into this
prompt, so it is never stale and never needs editing when a competitor is added.

    curl -sS --max-time 30 -o roster.json "<ROSTER_URL>"

Then Read roster.json. This is the ONLY permitted use of bash/curl in this run — it is reading our
own database export, not researching a competitor. Every claim about a competitor must still come
from WebSearch/WebFetch against a source you actually retrieved.

If the fetch fails or returns something that isn't JSON, say so plainly at the top of your message
and continue using whatever baseline context you can find in /areas/zaherai-positioning.md and
/areas/zaher-crm.md. Do not invent a roster, and do not silently skip competitors.

The roster gives you, for every competitor in the CRM: identity and classification, the current
stored value of every field you might overwrite, the v2 radar scores (null = NOT MEASURED, never
zero), `staleDays` since it was last checked, and its three most recent signals.

HOW TO USE IT:
- It IS the baseline. Write a cell only where today's verified fact DIFFERS from the stored value
  you can see in the roster. Where the roster disagrees with anything written elsewhere in this
  prompt, THE ROSTER WINS — it comes from the live database.
- Cover every competitor in the roster. Prioritise by `staleDays` (highest first) and `threatLevel`
  if you cannot get to all of them, and say in your message which ones you did not reach.
- Check `recentSignals` before reporting an event — if it is already there, don't re-report it.
- A competitor in the roster that you cannot reach at all gets a row with `company`, `status` and
  `lastCheckedAt`, so "Last checked" stays honest.

Volatile fields to re-check: funding/ARR, pricing and entry price, engines tracked, sovereign-model
coverage, MENA/Arabic localisation moves, M&A, leadership changes, site going down, major product
launches, and anything that moves market authority (a raise, an acquisition, a third-party ranking
placement, a new directory profile).
