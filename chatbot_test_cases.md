# Zaher CRM — Chatbot Tool-Calling Test Cases

## How to use this file

1. Make sure `GROQ_API_KEY` (and optionally `GROQ_MODEL`) is set in the Vercel project's environment
   variables — `/api/chat.js` proxies to Groq and returns a hard error in the chat panel
   (`"Couldn't reach the assistant..."`) if it's missing. Without it, none of these prompts will get
   a response at all.
2. Open the deployed app (or `zaher_crm.html` served locally), click the chat bubble bottom-right,
   and paste in **one prompt at a time**, in order within each section (later cases sometimes assume
   an earlier one already ran — e.g. delete tests delete records created by the add tests).
3. After each prompt, check three things:
   - The **chat panel** shows an action pill (e.g. "Moved Steps → Educational Collaboration") — this
     confirms the LLM picked a tool at all, and which one.
   - **`execTool`'s return string** (visible as the tool result the model then paraphrases in its
     reply) matches what's expected below.
   - The **actual UI state** changed where described in "Verify in UI" — reload the page once to
     confirm it round-tripped through Supabase (`saveRecord`/`deleteRecordRemote`), not just an
     in-memory change.
4. All record names/ids below are pulled directly from `SEED_RECORDS` in `zaher_crm.html` as it
   exists today. If Supabase already has rows seeded/edited beyond `SEED_RECORDS`, ids may differ —
   cross-check by company name in the Directory search instead of trusting ids blindly.
5. `add_record` assigns ids via `++nextId`, seeded at `Math.max(100, ...existing ids)`. If you run
   the `add_record` tests first in a fresh session, the three new records will land as **id 101,
   102, 103** in the order listed below (Foodics → Rise Up Summit → Careem → MEVP is 4 adds, so
   101–104). Re-check actual ids in the Directory before running the paired `delete_record` tests.

Tools under test (defined in `TOOLS`, executed in `execTool()`, both in `zaher_crm.html`):
`move_stage`, `update_record`, `add_record`, `delete_record`, `log_activity`, `score_agency`,
`switch_pipeline`.

---

## 1. `move_stage`

### 1.1 Partners · Portfolio 1
**Prompt:** `Move Steps to Educational Collaboration`
- Expected tool: `move_stage` — `{record: "Steps", stage: "Educational Collaboration"}`
- Record: id 4, Sara Otaibi / **Steps / Steps Grow**, currently `Awareness`
- Expected change: `stage` → `Educational Collaboration`; new `activity` entry
  `"Stage: Awareness → Educational Collaboration"` dated Today
- Verify in UI: Partners → Pipeline (Portfolio 1) — card moves from Awareness to Educational
  Collaboration column; open the record's Detail page, stage tracker shows Educational Collaboration
  as current step; Activity timeline shows the new entry at the top.

### 1.2 Partners · Portfolio 2
**Prompt:** `Move Nahdet El-Mahrousa to Workshop Delivered`
- Expected tool: `move_stage` — `{record: "Nahdet El-Mahrousa", stage: "Workshop Delivered"}`
- Record: id 21, **Nahdet El-Mahrousa**, currently `Conversation`
- Expected change: `stage` → `Workshop Delivered`
- Verify in UI: Partners → Portfolio 2 → Pipeline, card lands in Workshop Delivered column;
  Dashboard "Ecosystem funnel" count for that stage increments by 1.

### 1.3 Customers
**Prompt:** `Move Jumia Egypt to Discovery Call`
- Expected tool: `move_stage` — `{record: "Jumia Egypt", stage: "Discovery Call"}`
- Record: id 44, Sherif Aly / **Jumia Egypt**, currently `Audit Requested`
- Expected change: `stage` → `Discovery Call`
- Verify in UI: Customers → Pipeline, card moves column; Directory row's Stage pill updates.

### 1.4 Investors
**Prompt:** `Move 500 Global MENA to Due Diligence`
- Expected tool: `move_stage` — `{record: "500 Global MENA", stage: "Due Diligence"}`
- Record: id 64, Karim Beshara / **500 Global MENA**, currently `First Meeting`
- Expected change: `stage` → `Due Diligence`
- Verify in UI: Investors → Deal Flow, card in Due Diligence column.

### 1.5 Edge — invalid stage name for that pipeline
**Prompt:** `Move Bytes Future to Negotiation`
- Record: id 1, **Bytes Future**, pipeline partners/portfolio 1 — valid stages are Awareness →
  Educational Collaboration → Trust → Pilot Partnership → Revenue Partnership → Strategic Alliance.
  `"Negotiation"` doesn't exist in that list or as a substring of any stage name.
- Expected: `execTool` returns
  `"Negotiation" is not a valid stage. Valid: Awareness, Educational Collaboration, Trust, Pilot Partnership, Revenue Partnership, Strategic Alliance.`
- Verify in UI: Bytes Future's stage is **unchanged** (still `Trust`) — nothing should move.

### 1.6 Edge — no matching record
**Prompt:** `Move Acme Corp to Trust`
- No record in any pipeline has name or company `"Acme Corp"` (checked against all of
  `SEED_RECORDS`).
- Expected: `execTool` returns `No record matching "Acme Corp".`
- Verify in UI: nothing changes anywhere.

---

## 2. `update_record`

### 2.1 Partners · Portfolio 1 — numeric field
**Prompt:** `Update Bytes Future's ARR value to 45000`
- Expected tool: `update_record` — `{record: "Bytes Future", field: "value", value: "45000"}`
- Record: id 1, `value` currently `38000`
- Expected change: `value` → `45000` (cast to `Number` — `'value'` is in `execTool`'s numeric-cast
  list)
- Verify in UI: Directory → Partners, Value column shows `$45k`; Analytics → Partners, "Total value"
  KPI increases by $7,000.

### 2.2 Partners · Portfolio 1 — tier field (numeric cast)
**Prompt:** `Set Chain Reaction's tier to 2`
- Expected tool: `update_record` — `{record: "Chain Reaction", field: "tier", value: "2"}`
- Record: id 3, `tier` currently `1` (number)
- `execTool`'s numeric-cast list is `['value','aiScore','score','workshops','founders','tier']` —
  `tier` is included, so `r.tier` ends up as the **number** `2`, not the string `"2"`.
- Expected change: `tier` → `2` (number)
- Verify in UI: Chain Reaction Directory/Kanban card shows "Tier 2" pill. Open the record's
  **Detail page** — the Agency Score card's tier-color logic (`r.tier===1 ? green : amber`) does a
  strict `===` against the number `1`; since `tier` is now a real number, the color should be
  correct (amber for Tier 2). If you set it back to `1` via chat afterward, confirm the card turns
  green again — this was previously a bug (tier stored as a string broke the strict check) and was
  fixed in `execTool`'s `update_record` handler; this case now doubles as a regression check.

### 2.3 Partners · Portfolio 2
**Prompt:** `AUC Venture Lab just delivered a 4th workshop, update workshops to 4`
- Expected tool: `update_record` — `{record: "AUC Venture Lab", field: "workshops", value: "4"}`
- Record: id 20, `workshops` currently `3` (this field **is** in the numeric-cast list)
- Expected change: `workshops` → `4` (number)
- Verify in UI: Partners → Portfolio 2 → Pipeline, card shows "4 wshops · 24 founders"; Analytics
  → Portfolio 2, "Workshops delivered" big stat increments by 1.

### 2.4 Customers — numeric field
**Prompt:** `Update Noon.com's AI visibility score to 78`
- Expected tool: `update_record` — `{record: "Noon.com", field: "aiScore", value: "78"}`
- Record: id 40, `aiScore` currently `71`
- Expected change: `aiScore` → `78` (number)
- Verify in UI: Customers → Directory, AI Score chip shows 78; Kanban card badge "AI 78".

### 2.5 Customers — dropdown-backed field
**Prompt:** `Change Vezeeta's next step to Send contract`
- Expected tool: `update_record` — `{record: "Vezeeta", field: "nextStep", value: "Send contract"}`
- Record: id 41, `nextStep` currently unset (Vezeeta has no `nextStep` in `SEED_RECORDS`)
- Expected change: `nextStep` → `"Send contract"` (exact match to one of the seeded
  `next_step_options` labels, so the `<select>` will show it selected rather than falling through)
- Verify in UI: Customers → Directory, "Next step" column shows "Send contract"; Detail page's
  Next step `<select>` has it selected.

### 2.6 Investors — free-text field
**Prompt:** `Update Algebra Ventures' fund size to $100M`
- Expected tool: `update_record` — `{record: "Algebra Ventures", field: "fundSize", value: "$100M"}`
- Record: id 60, `fundSize` currently `"$80M"`
- Expected change: `fundSize` → `"$100M"`
- Verify in UI: Investors → Directory, Fund column shows $100M; Detail page "Fund size" field.

---

## 3. `add_record`

### 3.1 Partners · Portfolio 1
**Prompt:** `Add a new partner: company Foodics, category SaaS & E-commerce Platforms, stage Awareness`
- Expected tool: `add_record` —
  `{pipeline: "partners", company: "Foodics", category: "SaaS & E-commerce Platforms", stage: "Awareness", portfolio: 1}`
- Expected new record: `id` = next available (101 if this is the first add in the session),
  `name` defaults to `"Foodics"` (no contact name given), `tier: null`, `score: null`, `model: ""`,
  `region: ""`, `source: "Assistant"`, `activity: [{t:"Added via assistant", d:"Today"}]`
- Verify in UI: Partners → Portfolio 1 → Directory, new "Foodics" row in SaaS & E-commerce
  Platforms category, Awareness stage.

### 3.2 Partners · Portfolio 2
**Prompt:** `Add a new ecosystem partner called Rise Up Summit in Startup Development Orgs`
- Expected tool: `add_record` —
  `{pipeline: "partners", company: "Rise Up Summit", category: "Startup Development Orgs", portfolio: 2}`
- Expected new record: `portfolio: 2` → gets `workshops: 0, founders: 0` (per `execTool`'s
  portfolio-2 branch), stage defaults to `Awareness` (first of `STAGES.partners2` since no stage
  given)
- Verify in UI: Partners → Portfolio 2 → Pipeline, new card in Awareness column showing
  "0 wshops · 0 founders".

### 3.3 Customers
**Prompt:** `Add a new customer: company Careem, sector Mobility`
- Expected tool: `add_record` — `{pipeline: "customers", company: "Careem", sector: "Mobility"}`
- Expected new record: `stage` defaults to `Audit Requested` (first of `STAGES.customers`),
  `leadSource: "Assistant"`, `aiScore: null`, `package: "—"`, `nextStep` = first of
  `nextStepOptions`
- Verify in UI: Customers → Directory, new "Careem" row, sector "Mobility", stage Audit Requested.

### 3.4 Investors
**Prompt:** `Add a new investor called MEVP`
- Expected tool: `add_record` — `{pipeline: "investors", company: "MEVP"}`
- Expected new record: `stage` defaults to `Prospecting` (first of `STAGES.investors`, since no
  stage given), `fundSize: ""`, `thesis: ""`, `value: 0`
- Verify in UI: Investors → Deal Flow, new "MEVP" card in Prospecting column with $0 target.

### 3.5 Edge — missing required field
**Prompt:** `Add a new partner`
- No company name is given anywhere in the prompt, and `company` is a `required` param on the
  `add_record` tool schema.
- Expected (correct) behavior: the model does **not** call `add_record` at all — it should ask a
  clarifying question back in chat (e.g. "What's the partner's company name?") instead of guessing
  or calling the tool with an empty/placeholder company.
- Expected (failure) behavior to watch for: model calls `add_record` with `company: ""` or a
  fabricated name like `"New Partner"` — if this happens, you'll get a junk row in Partners
  Directory with a blank/fake company name. Worth flagging as a prompt-engineering gap in
  `buildSystem()` if it happens consistently (the system prompt doesn't explicitly tell the model to
  ask before calling tools with missing info).
- Verify in UI: Partners Directory — no new blank/fake row should appear.

---

## 4. `delete_record`

Run these **after** the matching `add_record` test above, so you're deleting a record you just
created rather than real seed data.

### 4.1 Delete an add-test record (Partners)
**Prompt:** `Delete the Foodics record`
- Expected tool: `delete_record` — `{record: "Foodics"}`
- Verify in UI: Foodics row disappears from Partners Directory immediately, and after a page
  reload (confirms `deleteRecordRemote` actually hit Supabase, not just local state).
- Note: unlike the UI's own Delete button (which shows a confirm dialog via `confirmDelete()`), the
  chatbot's `delete_record` has **no confirmation step** — it deletes immediately. Good to be aware
  of before testing this against anything you care about.

### 4.2 Delete an add-test record (Investors)
**Prompt:** `Delete MEVP`
- Expected tool: `delete_record` — `{record: "MEVP"}`
- Verify in UI: MEVP card disappears from Investors Deal Flow.

### 4.3 Edge — no matching record
**Prompt:** `Delete Acme Corp`
- Expected: `execTool` returns `No record matching "Acme Corp".` — nothing is deleted (there's no
  "closest match" fallback risk here since `findRecord` returning `null` short-circuits before any
  `records.filter` runs).
- Verify in UI: record counts unchanged everywhere.

---

## 5. `log_activity`

### 5.1 Partners
**Prompt:** `Log an activity on Room 11: "Sent updated webinar deck"`
- Expected tool: `log_activity` — `{record: "Room 11", text: "Sent updated webinar deck"}`
- Record: id 2, **Room 11**
- Expected change: new entry appended to `activity`: `{t: "Sent updated webinar deck", d: "Today"}`
  (note: `log_activity` does **not** prefix or reformat the text like `move_stage`/`update_record`
  do — whatever the model passes as `text` lands verbatim)
- Verify in UI: Room 11 Detail page → Activity timeline, new entry at top dated Today.

### 5.2 Customers
**Prompt:** `Log an activity on Talabat: "CMO requested pricing for enterprise tier"`
- Expected tool: `log_activity` — `{record: "Talabat", text: "CMO requested pricing for enterprise tier"}`
- Record: id 42, **Talabat**
- Verify in UI: Talabat Detail page → Activity timeline; if Customers → Dashboard is the active
  page, "Recent activity" feed also shows it (feed is built from all records' activity arrays,
  sorted).

---

## 6. `score_agency`

This tool is read-only — it never touches `records`, so there's nothing to verify in the UI beyond
the chat reply itself.

### 6.1 Points-based scoring
**Prompt:** `Score an agency: mixed clients, SEO + content, 25 clients, named SEO team`
- Expected tool: `score_agency` —
  `{clientType: "mixed", services: ["seo","content"], rosterSize: 25, namedSeoTeam: true}`
- Expected math: mixed +10, SEO +20, Content +15, roster 20+ +20, named SEO team +15 = **80** →
  **Tier 1** (≥50 threshold)
- Expected reply text: `Score 80 → Tier 1. Breakdown: Mixed B2B/B2C clients +10; SEO service +20; Content service +15; Client roster 20+ +20; Named SEO team +15.`

### 6.2 Hard-skip
**Prompt:** `Score an agency that lists GEO/AEO as one of their services`
- Expected tool: `score_agency` — `{clientType: "...", listsGeo: true, ...}` (clientType is
  `required` on the schema even though it's irrelevant once `listsGeo` triggers the skip — watch
  whether the model supplies a placeholder value here)
- Expected reply text: `Skip — Lists GEO/AEO as a service — competitor.`

---

## 7. `switch_pipeline`

### 7.1 Simple pipeline switch
**Prompt:** `Switch to the customers pipeline`
- Expected tool: `switch_pipeline` — `{pipeline: "customers"}`
- Verify in UI: sidebar "Customers" pill becomes active (green), topbar mode chip reads
  "Customers", Dashboard reloads with customer stats.

### 7.2 Pipeline + portfolio switch
**Prompt:** `Show me partners portfolio 2`
- Expected tool: `switch_pipeline` — `{pipeline: "partners", portfolio: 2}`
- Verify in UI: sidebar "Partners" active, top-right portfolio toggle shows "Portfolio 2 ·
  Ecosystem" selected, Dashboard stat cards switch to the workshops/founders variant (`isP2()`
  branch).

---

## 8. Multi-step / ambiguous prompts

### 8.1 Genuinely ambiguous — multiple matches in real data
**Prompt:** `Move whichever Tier 1 partner is still stuck at Awareness to Trust`
- There is **no query tool** — the model can only resolve "whichever partner..." by reading the
  `CURRENT DATA` JSON dump embedded in the system prompt (`buildSystem()` → `snapshot()`) and
  picking a `company` value itself before calling `move_stage`.
- This is not a contrived edge case — checking `SEED_RECORDS`, **three** Partners/Portfolio 1
  records are simultaneously `tier: 1` and `stage: "Awareness"`: id 4 **Steps / Steps Grow**
  (unless you already ran test 1.1 and moved it), id 6 **Digital Wasfa**, and id 8 **Entshar
  Technology**.
- Expected (good) behavior: the model either asks which one you mean, or explicitly says it found
  multiple matches and asks you to pick, rather than silently moving one.
- Expected (bad) behavior to watch for: model picks one arbitrarily (usually the first in the JSON
  array) and calls `move_stage` on it without flagging the ambiguity — worth noting which company it
  picked, since that reveals how the model is breaking the tie.
- Verify in UI: check all three companies' stages before and after — confirm only the one the model
  claimed to move (if any) actually changed, and that it told you which one.

### 8.2 Chained tool calls in one turn
**Prompt:** `We just closed the Wamda Capital deal a second time — bump their target raise by another $200k and log a note about the follow-on`
- Record: id 65, **Wamda Capital**, `value` currently `300000`, `stage` already `Closed`
- Expected tool sequence (order may vary): `update_record` —
  `{record: "Wamda Capital", field: "value", value: "500000"}` **and** `log_activity` —
  `{record: "Wamda Capital", text: "<something about the follow-on>"}`
- Note: the model has to compute `300000 + 200000 = 500000` itself and pass the *new total*, since
  `update_record` overwrites `value`, it doesn't add a delta (`r[f]=v` in `execTool`, no `+=`). If
  the model instead passes `"200000"`, that's a bug in the model's reasoning, not the tool — worth
  distinguishing when you see the result.
- Verify in UI: Wamda Capital Detail page — `value`/"Target raise" field shows $500k (not $200k),
  and Activity timeline has a new entry about the follow-on, dated Today.

---

## Coverage summary

| Tool | Partners P1 | Partners P2 | Customers | Investors | Edge cases |
|---|---|---|---|---|---|
| `move_stage` | 1.1 | 1.2 | 1.3 | 1.4 | 1.5 (bad stage), 1.6 (no match) |
| `update_record` | 2.1, 2.2 (tier cast) | 2.3 | 2.4, 2.5 | 2.6 | — |
| `add_record` | 3.1 | 3.2 | 3.3 | 3.4 | 3.5 (missing required field) |
| `delete_record` | 4.1 | — | — | 4.2 | 4.3 (no match) |
| `log_activity` | 5.1 | — | 5.2 | — | — |
| `score_agency` | — (pipeline-agnostic) | | | | 6.1 (scored), 6.2 (hard-skip) |
| `switch_pipeline` | 7.1, 7.2 | | | | — |
| multi-step | 8.1 (ambiguous), 8.2 (chained) | | | | |

**28 total test cases** across all 7 tools and all 4 pipeline/portfolio views.
