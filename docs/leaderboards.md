# GlobalScore: standalone leaderboard submission

This project's PlayFab title is **`186CDB`**. Its existing **`GlobalScore`** leaderboard
is **standalone**, with one column named **`Score`**. It is not sourced from a statistic.
Keep that definition; no statistic creation, linking, aggregation or migration is required.

Completed online matches report only the local player's final score:

```gdscript
await pf.leaderboards.submit_score_async(user, LEADERBOARD_NAME, score)
```

The game passes an integer. The addon converts it to a decimal string and places it
in the first score column. `additional_scores` defaults to empty, so exactly one
column value is sent. The column name is not a request key or a separate API argument.

`Services.report_match_result()` starts the operation without awaiting it. Practice
remains local even when signed in, and existing history/achievement work is unchanged.
The Leaderboards screen retains its top-ten read and shows a live, wrapped
**Last score submission** notice. Refresh only reads the board.

## Client access is a title policy

The current `UpdateLeaderboardEntries` API permits `title_player_account` tokens as
well as title/server tokens. That does not mean every title enables game-client access.
The initialized title comes from `PlayFab.get_title_id()`, not a hard-coded number.

If the update returns **`0x89235472`**, the screen explains:

```text
PlayFab title 186CDB: API Features policy blocks client access to UpdateLeaderboardEntries. In Game Manager > Title settings > API Features, enable client access to UpdateLeaderboardEntries. If the endpoint has no exposed control, request title-level API feature enablement from PlayFab support.
```

The exact HRESULT, SDK result code and SDK message follow. The title administrator
must enable client access to **this endpoint**. The player-stat posting toggle governs
different APIs and does not enable this write path. If Game Manager exposes no control
for the endpoint, do not invent a setting or ship a secret key to work around it;
request the necessary title-level feature enablement from PlayFab.

No runtime code changes title policy, creates/deletes the leaderboard or elevates
the player's token. Direct client submission and around-user readback have been
observed on `186CDB` using the registered debug build. This does not imply that a
different title or account configuration grants the same access.

## Highest-score guard and serialization

Standalone entries are **last-write-wins**, not server-side Max aggregation.
Before the first submission in a new process, the service reads **this entity's**
current `GlobalScore` row with `get_leaderboard_around_user_async`. It matches both
entity id and type and reads the first integer score, regardless of whether the
player ranks in the top ten.

The same read is repeated before every later candidate that could exceed the
locally known best. A known equal/lower score can skip immediately. This avoids
unnecessary reads for ordinary skips while also noticing another already-published
higher score before a potential update.

- A published score is merged with the local best using the greater value. A stale
  lower read cannot erase a score this process already knows was accepted.
- The candidate is compared again after that merge. Equal/lower is a successful
  skip, with no update request.
- Only a higher candidate updates the guard optimistically and reaches the existing
  `submit_score_async(user, "GlobalScore", score)` call.
- A failed update restores the previous guard, including the best just read from
  the server. The next eligible candidate reads again.
- The **entire read, comparison and write** occupies the existing per-entity gate.
  Another local caller cannot read the same old baseline concurrently and race its
  update. Every exit releases the gate before waking waiters.

**Failed read means no upload.** Network/authentication/API failures, malformed
target scores and a non-empty around-user page lacking this entity are not treated
as zero. The notice says the score was not uploaded because the existing best could
not be established, with a separately labeled read HRESULT when available. A
successful empty page is treated as no published entry and permits the first score.
Generic errors, including a missing leaderboard, do not take that path.

This deliberately prefers missing a legitimate new high score over lowering an
existing one during a failed read. Gameplay still never awaits the service, failures
only warn, and there is no automatic/durable retry queue. Future eligible submissions
try the read again.

User removal/shutdown invalidates a pending seed or queued call before it can start
an update. An update already started settles normally. Known scores are not cleared
as a side effect of canceling queued work.

**Limits:** the read and write are not an atomic server-side compare-and-set.
Another device/writer can update between them; eventually consistent reads and
ambiguous failed writes also prevent an absolute distributed maximum guarantee.
The client neither coordinates other writers nor automatically changes reset policy.
PlayFab is already the trusted backend here; what this path lacks is a
server-authoritative conditional write, so strict cross-device all-time maximum
semantics would need that enforcement server-side rather than another service.

## One local result per match

Match completion is event-driven. The authority already guards its completion
transition; the client also needs to ignore a repeated completion payload.
`MatchDirector` marks the local result before calling the facade, so history,
achievement counters and leaderboard submission are each requested only once.
Each gameplay screen creates a fresh director for the next match.

The guard is independent of the replicated `MATCH_COMPLETE` state: that state can
arrive before the result payload. A failed asynchronous upload does not reset the
match-report flag or cause duplicate local history/achievement updates.

## Reading outcomes honestly

- **Accepted:** the addon returned success, with its actual HRESULT. Allow time for
  leaderboard propagation; acceptance is not readback.
- **Skipped:** the score was not higher than the known cached/server best. This is
  success for gameplay; no update was sent, though a read may have established the best.
- **Read failed:** no update was sent. The diagnostic labels the leaderboard-read
  HRESULT separately from any update result; this is a failure, not a successful skip.
- **Update failed:** the update's exact HRESULT/code/message are shown when a
  completion exists. Missing results are not represented as HRESULT 0.

Back/B/Esc remain available while loading; notices wrap and do not steal focus.
An older completion cannot replace a newer attempt's notice or expose it to another
signed-in session.

Client-authoritative leaderboard writes are not cheat-resistant. They publish
persistent data tied to the signed-in account. Enabling this integration does not
validate that a modified client earned its submitted score.
