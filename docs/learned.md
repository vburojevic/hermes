# What Hermes Learned

Hermes gets better the more it's used: it writes skills for things it does often (or that you
teach it with `/learn`), remembers things about you and your setup, and a background **curator**
keeps the skills tidy: it merges overlapping skills, marks unused ones as stale, and archives them
later. This document covers the page that makes all of that visible and controllable: the calls
behind it, the story and the map, a learned skill's page, Tidying, and the notes and notification
that lead to it.

Each Bot learns on its own, so the page always shows one learner: Hermes (the gateway's own
profile) or a Bot. It needs Bot Mode for the gateway.

Code: `App/Model/LearnedModel.swift`, `App/Views/Learned/` (`LearnedPages`, `LearnedParts`,
`LearningMapView`, `LearnedSkillPage`, `LearnedTidyingPage`, `LearnedEntry`), and in HermesKit
`Packages/HermesKit/Sources/HermesKit/Learned/` (`LearnedAPI`, `LearningModels` with
`LearningGraph`, `CuratorStatus`, `CuratorReport` and `CuratorReply`, `LearningLayout`,
`LearnedSkillNote`). The mock is `Tools/mock-hermes/learned.py`, on top of the memory mock.

The protocol comes from Hermes Agent: `agent/learning_graph.py`, `agent/learning_mutations.py`,
`agent/curator.py`, `tools/skill_usage.py`, `hermes_cli/curator.py`,
`hermes_cli/web_routers/status.py` (`/api/learning/*`, `/api/curator*`), `actions.py`
(`/api/actions/*`) and `skills.py`.

Entry points:

- The top row of Skills, "What Hermes Learned", with what's new and when it last tidied ("2 new
  skills this week · tidied 2 days ago").
- The Memory page's options ("What <Hermes or the Bot> Learned"), for that learner.
- The "Learned a new skill" note in chats (§6).
- Mac: Skills → Library | Learned.
- The notification after a tidy (§6), which opens Tidying.
- The welcome tour shows a fixed demo map (`welcomeLearns`).

## 1. Calls

Every call names the learner's `profile`.

| Need | Call | Notes |
|---|---|---|
| Everything learned | `GET /api/learning/graph` | `nodes[]`: skills (`kind: "skill"`, `label`, `timestamp`, `category`, `useCount`, `state` active / stale / archived, `createdBy` agent / learn / …, `pinned`) and memories (`kind: "memory"`, `memorySource`). `edges[]`: related skills, and memories linked to the skills they mention. `clusters[]` by category (computed from the nodes when missing). Only skills with a learning signal appear (written by Hermes, taught with /learn, or used); bundled and external skills don't. A skill's `timestamp` is its latest activity, not its creation. |
| When each skill was written | `slash.exec {session_id, command: "/curator usage --json"}` | `created_at` per skill name, read once per page. "New This Week" and the weekly chart use it, falling back to the graph's `timestamp`. |
| A skill's text | `GET /api/learning/node?id=<name>` | `content` is the SKILL.md. Kept for the page's lifetime. |
| Edit a skill | `PUT /api/learning/node {id, content, profile}` | The app re-reads the text first and refuses to save if Hermes changed it since it was opened ("Hermes changed this skill since you opened it…"). |
| Where a skill's file is | `GET /api/skills/content?name=` → `path` | For editing in the Inspector's File tab (§4). |
| Archive a skill | `DELETE /api/learning/node {id, profile}` | Skills are archived (restorable); memories are deleted ([memory.md](memory.md)). |
| Curator status | `GET /api/curator` | `enabled`, `paused`, `interval_hours`, `last_run_at`, `min_idle_hours`, `stale_after_days`, `archive_after_days`. |
| Pause or resume | `PUT /api/curator/paused {paused}` | The Tidying switch. |
| Tidy Up Now | `POST /api/curator/run` | Runs in the background, often for minutes. The app follows `GET /api/actions/curator-run/status?lines=20` (`running`, `exit_code`) every 3 s for up to 20 minutes, then reloads the page and the archived list. A non-zero exit says "The tidy didn't finish (exit N)." |
| What the last tidy did | The newest run report, `logs/curator/<stamp>/run.json` | Found through the managed files: `GET /api/files?path=` lists the run folders (newest first, up to three tried), `GET /api/files/read?path=` returns the file as a base64 data URL. The folder is `<hermes_home>/logs/curator` when `GET /api/status` names the home, else under the files root (`profiles/<name>/logs/curator` for a Bot). Fields: `started_at`, `consolidated [{name, into, reason or evidence}]`, `pruned [{name, reason}]`, `archived [name]`, `state_transitions [{name, to}]`, `auto_transitions {marked_stale, archived}`. Skills auto-archived as unused before the review appear only as the `auto_transitions.archived` count, with no names. When the gateway doesn't allow reading the file, the page shows the counts it has. |
| Keep As Is, unpin, restore, list archived | `slash.exec {session_id, command: "/curator pin <name>" \| "/curator unpin <name>" \| "/curator restore <name>" \| "/curator list-archived"}` | `curator` is not a `command.dispatch` builtin (it answers 4018), so these run as slash commands in a session of the learner: its Bot Chat, created if it doesn't exist yet. For Hermes itself the learner is the gateway's own profile, or the default profile even when it's hidden. Replies are CLI text, read in one place (`CuratorReply`); anything unexpected is shown as Hermes's own words. Undo on a merge restores each original in turn. |

## 2. The page (`learnedPage`)

Until the graph arrives the page shows `SkeletonRows`.

- **Story** (`learnedHero`): one sentence ("Since August, Hermes wrote 11 skills and learned 20
  things about you and your setup"), the two counts with their colour keys, and the weekly chart:
  ink for skills, grey for memories, up to 12 weeks starting on Mondays, newest week on the right.
  "Wrote" counts skills Hermes wrote or was taught (`createdBy` `agent` or `learn`), not ones it
  only used.
- **New This Week:** skills written or taught in the last 7 days and not archived, newest first,
  tagged New, with who made it and when ("Hermes wrote it · yesterday"). Hermes doesn't record the
  chat a skill was learned in, so the date stands in for it.
- **The Map** (a preview card; the full map is `learnedMap`, §3):
  - Skills are circles sized by use, ink when used 6 or more times, grey otherwise. Memories are
    small dots. Lines are the graph's edges.
  - Laid out by category clusters with a force layout (`LearningLayout`): categories, biggest
    first, around an ellipse; memories pulled in by their edges. Every start position is seeded by
    the node's id, so the map looks the same each visit and only shifts where something new
    arrives. Layouts are computed off the main thread, one per aspect ratio, and kept until the
    graph changes.
- **Most Used:** skills by `useCount` (never-used and archived ones left out); the top three on
  iPhone.
- **Tidying** row → `learnedTidying`, with the last tidy in one sentence.
- **iPad and Mac** (`ipadLearned`, `macLearned`): the map fills the main space with its filters
  and the selected skill under it; the story, New This Week (with up to two stale skills) and the
  curator card sit beside it. On the Mac, pushed pages carry their own large title, since the main
  window hides toolbar titles.
- On iPhone and iPad the … menu has Tidying, Tidy Up Now and Refresh.
- Not available: "What <learner> learned isn't available" with the reason, and Try Again unless
  Bot Mode is missing.

## 3. The map (`learnedMap`, iPad, Mac)

- Filter chips: All, Skills, Memories, and one per skill category. Archived skills are hidden
  under every filter.
- Pinch to zoom and drag to pan. Tapping a skill selects it: a ring around it, and it and its
  connections at full strength while the other nodes and lines fade to 30%. The callout
  (`LearnedCallout`) shows the skill's category, what it does (its SKILL.md description, or its
  first line of prose), its use and how many memories mention it, with Open Skill and, on iPhone,
  Show Connections (which clears the filter), or on iPad and the Mac, Keep As Is.
- Tapping a memory opens it in Memory, on the same Bot and the entry's store.
- The full map page has a search field ("Find a skill") that selects the first skill whose name
  matches.
- **Reduce Motion:** no fade-in, no scaling, no animated selection. Only the welcome tour's demo
  map settles into place, and not with Reduce Motion on.

## 4. A learned skill (`learnedSkill`)

- **Facts:** made by (Hermes, or you with /learn) and when, use count, category, and state when
  stale or archived. Hermes doesn't record the chat a skill was learned in.
- **Keep As Is** (pin): "Tidying won't merge, change or archive it." The switch moves at once
  and stays while the gateway takes it; a refusal moves it back and says why ([chat.md](chat.md)
  §4a).
- **Connected:** related skills and memories from the edges, skills first, most used first.
- **SKILL.md** preview. Edit opens it in the Inspector's File tab on iPad and the Mac (in its own
  window on the Mac, [inspector.md](inspector.md)); on iPhone, or when the gateway won't say where
  the file is, a code editor sheet saves it with `PUT /api/learning/node`. Save closes the sheet
  at once and the preview shows the new text; a refusal (Hermes changed it meanwhile) opens the
  sheet again with the text typed and why. Copy is in the … menu.
- **Bottom bar:** Archive (confirmed: "Hermes stops using it. You can restore it from Tidying.";
  the page closes at once, and a refusal says so)
  and **Use in a Chat**, which puts the skill in the composer's tray (`Slash.skillChip`): the Bot's
  chat for a Bot, else the chat that was open last, or a new chat.
- A skill that's gone (merged or archived meanwhile) says so and points to Tidying.

## 5. Tidying (`learnedTidying`)

- `curatorCard`:
  - On or paused (the Tidying switch).
  - The schedule ("Every 7 days, when <gateway> has been idle 2 h").
  - The last tidy in one sentence ("Last tidy 2 days ago: merged 2 overlapping skills, archived 3
    unused ones and marked 4 as stale."), with counts for merged, archived and stale.
  - **Tidy Up Now** ("Tidying…" while it runs).
- **Last Tidy · <date>:**
  - Each merge (`curatorMergeRow`), grouped by the skill it went into, with **Undo** (restore the
    originals).
  - Each archive (`curatorArchiveRow`) with **Restore**. Restored rows say so at once, and offer
    Restore again with why if the gateway refuses.
- **Stale:** the skills stale now, with how long they've been unused and when they'll be archived.
- **Rules:** "Stale after 30 days unused" and "Archived after 90 days unused" (from the curator's
  settings), read-only. Skills a scheduled task uses are never archived.
- **Archived:** the full list from `/curator list-archived`, with Restore.

## 6. Notifications and chat

- After a tidy that changed something, one quiet (passive) notification: "<Hermes or the Bot>
  tidied its skills", "Merged 2 overlapping skills and archived 3 unused ones." It opens Tidying
  for that learner. The curator fires no hook, so the gateway plugin (`Tools/hermes-app-push`)
  looks for new run reports in each profile's `logs/curator/` every 30 s, sends one notice for the
  newest tidy that changed something (never for reports older than the plugin's first look), and
  collapses it with the previous one per profile. It follows the tasks preference: sent only when
  that is set to all ([notifications.md](notifications.md); installing the plugin:
  [plugins.md](plugins.md)).
- When Hermes writes a new skill in a chat (a successful `skill_manage` step with `action: create`
  that wasn't staged for approval), the turn's note reads "Learned a new skill: app-store-listing",
  and tapping it opens the skill in a sheet. It uses the same component as `memoryNote`, with the
  sparkles glyph, and sits before the memory notes ([chat.md](chat.md)).

## 7. Accessibility

- The chart is a Swift Charts chart, so VoiceOver has its audio graph, plus a summary ("Most active
  week: Oct 6, 5 skills and 3 memories").
- The map has a list alternative: VoiceOver reads the skills by cluster ("<skill>, <category>,
  used 12 times, 3 connections"), with their connections as custom actions ("Go to <skill>",
  "Memory: <text>"), and each cluster's memory count.
- Map colours are ink and grey with a size difference, never colour alone.

## 8. Acceptance checks

- The page reflects `GET /api/learning/graph` for the chosen learner; bundled skills never appear.
- New This Week uses when a skill was written, not when it was last used.
- Keep As Is pins the skill, and the next tidy leaves it alone.
- Tidy Up Now runs the curator and refreshes the page when it finishes.
- Undo on a merge and Restore on an archive bring the skills back.
- Archive from a skill page is restorable from Tidying.
- Editing a SKILL.md that Hermes changed meanwhile is refused, and the person's text stays.
- Light, dark and Increase Contrast read well.

## 9. Setup

What Hermes Learned needs Bot Mode: without it, or while it doesn't answer, the page shows Bot
Mode's setup instead of a spinner. Tidying turned off in config (`curator.enabled: false`) reads
Tidying is off, the switch turns it on (`PUT /api/config`, then out of pause), and Tidy Up Now
waits for it ([setup.md](setup.md) §4.10).
