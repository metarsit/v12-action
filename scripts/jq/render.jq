# scripts/jq/render.jq - Markdown rendering for the PR comment, the check-run
# summary and the job summary. Every value coming from V12 (titles,
# descriptions, snippets, paths) passes through md_cell / md_text / fenced
# blocks so it cannot break the layout or inject Markdown/HTML.

include "common";

def money_or_na: if . == null then "n/a" else money_cents end;
def cap_word: if length == 0 then . else (.[0:1] | ascii_upcase) + .[1:] end;
def plural($n; $word): "\($n) \($word)\(if $n == 1 then "" else "s" end)";

def counts_phrase($c):
  [sev_order[] | . as $s | select($c[$s] > 0) | "\($c[$s]) \($s)"] | join(", ");

def run_link($r): if $r.run.url != null then "[View run](\($r.run.url))" else "" end;

# --- header ------------------------------------------------------------------
def gate_phrase($r):
  if $r.gate.failOn == "none" then "informative (fail-on: none)"
  elif $r.gate.failing then "**failing** (fail-on: \($r.gate.failOn), \(plural($r.gate.count; "finding")) at or above)"
  else "passing (fail-on: \($r.gate.failOn), none at or above)" end;

def verdict($r):
  if $r.skipped != null then
    (if $r.skipped.reason == "over-budget" then "not run: estimate \($r.estimate.quoteCents | money_or_na) exceeds the cost ceiling"
     elif $r.skipped.reason == "empty-diff" then "skipped, nothing to review"
     elif $r.skipped.reason == "estimate-only" then "estimate only, \($r.estimate.quoteCents | money_or_na)"
     elif $r.skipped.reason == "fork-pr" then "skipped on a fork pull request"
     else "skipped (\($r.skipped.reason))" end)
  elif $r.run.state == "failed" then "failed"
  elif $r.run.state == "cancelled" then "cancelled"
  elif $r.run.state == "timed_out" then "still running on V12"
  elif $r.run.state == "queued" or $r.run.state == "running" then "\($r.run.state) on V12"
  elif $r.counts.total == 0 then "no findings"
  else "\(plural($r.counts.total; "finding")) (\(counts_phrase($r.counts)))" end;

def header_line($r):
  "**V12 security review: \(verdict($r))**"
  + (if $r.skipped == null and ($r.run.state | IN("completed")) then " · gate \(gate_phrase($r))" else "" end)
  + (if $r.run.url != null then " · \(run_link($r))" else "" end);

def status_detail($r):
  if $r.skipped != null then ($r.skipped.message | md_text)
  elif $r.run.state == "failed" then "The V12 run ended in state `failed`" + (if ($r.run.statusMessage | length) > 0 then ": \($r.run.statusMessage | md_text)" else "" end) + ". No findings were collected."
  elif $r.run.state == "cancelled" then "The V12 run was cancelled before it finished. No findings were collected."
  elif $r.run.state == "timed_out" then "CI stopped waiting; the run continues on V12 and its findings will be there when it completes. Re-run the workflow later to refresh this comment."
  elif $r.run.state == "queued" or $r.run.state == "running" then "The run was created and not waited for (wait: false)."
  else "" end;

# --- tables ------------------------------------------------------------------
def severity_table($r):
  ["| Severity | Count |", "|---|---:|"]
  + [sev_order[] | . as $s | select($s != "qa" or $r.counts.qa > 0) | "| \($s | cap_word) | \($r.counts[$s]) |"]
  | join("\n");

def delta_line($r):
  if $r.delta == null then ""
  elif $r.delta.newCount == 0 and $r.delta.resolvedCount == 0 then "No change since `\($r.delta.priorSha | short_sha)`."
  else "**\($r.delta.newCount) new, \($r.delta.resolvedCount) resolved** since `\($r.delta.priorSha | short_sha)`." end;

def location_text($f):
  if $f.hasLocation | not then "(no source location)"
  else "`\($f.location.file | md_cell)" + (if $f.location.startLine != null then ":\($f.location.startLine)" + (if $f.location.endLine != null and $f.location.endLine != $f.location.startLine then "-\($f.location.endLine)" else "" end) else "" end) + "`" end;

def location_cell($f):
  (if $f.sourceUrl != null then "[\(location_text($f))](\($f.sourceUrl))" else location_text($f) end)
  + (if $f.inDiff == false then " (outside the diff)" else "" end);

def title_cell($f):
  (if ($f.webUrl | length) > 0 then "[\($f.title | md_cell)](\($f.webUrl))" else ($f.title | md_cell) end)
  + (if $f.isNew == true then " **new**" else "" end)
  + (if $f.autoInvalidated then " *(auto-invalidated)*" else "" end);

def findings_table($r; $rows):
  if ($r.findings | length) == 0 then ""
  else
    ($r.findings[0:$rows]) as $shown
    | (["| Severity | Finding | Location |", "|---|---|---|"]
       + [$shown[] | "| \(.severity | cap_word) | \(title_cell(.)) | \(location_cell(.)) |"]
       | join("\n"))
      + (if ($r.findings | length) > $rows then "\n\n…and \(plural(($r.findings | length) - $rows; "more finding")), see the full run." else "" end)
  end;

# --- details -------------------------------------------------------------------
def section($heading; $text): if ($text | length) == 0 then "" else "**\($heading)**\n\n\($text | md_text)\n\n" end;

def snippet_block($f):
  if ($f.location.snippet | length) == 0 then ""
  else ($f.location.snippet | fence_for) as $fence
    | "\($fence)\($f.location.lang)\n\($f.location.snippet)\n\($fence)\n\n"
  end;

def finding_details($f):
  "<details>\n<summary>\(.severity | cap_word): \($f.title | md_cell)\(if $f.isNew == true then " (new)" else "" end)</summary>\n\n"
  + section("Description"; $f.description)
  + section("Impact"; $f.impact)
  + section("Root cause"; $f.rootCause)
  + (if ($f.location.note | length) > 0 then "*\($f.location.note | md_text)*\n\n" else "" end)
  + snippet_block($f)
  + (if $f.locationCount > 1 then "\($f.locationCount) source locations; the first is shown.\n\n" else "" end)
  + "Fingerprint `\($f.fingerprint)` · validity \($f.validity)"
  + (if ($f.webUrl | length) > 0 then " · [View on V12](\($f.webUrl))" else "" end)
  + (if $f.sourceUrl != null then " · [Source](\($f.sourceUrl))" else "" end)
  + "\n</details>";

def findings_details($r; $n):
  if $n == 0 or ($r.findings | length) == 0 then ""
  else ([$r.findings[0:$n][] | finding_details(.)] | join("\n"))
    + (if ($r.findings | length) > $n then "\n\nDetails are shown for the first \($n) findings." else "" end)
  end;

def suppressed_section($r):
  if ($r.suppressed | length) == 0 then ""
  else "<details>\n<summary>\(plural($r.suppressed | length; "suppressed finding"))</summary>\n\n"
    + "| Severity | Finding | Reason | Expires |\n|---|---|---|---|\n"
    + ([$r.suppressed[] | "| \(.severity | cap_word) | \(title_cell(.)) | \(.suppression.reason | md_cell) | \(.suppression.expires | md_cell)\(if (.suppression.approvedBy | length) > 0 then " (\(.suppression.approvedBy | md_cell))" else "" end) |"] | join("\n"))
    + "\n</details>"
  end;

def expired_line($r):
  if ($r.expiredSuppressions | length) == 0 then ""
  else "**Expired suppressions:** " + ([$r.expiredSuppressions[] | "`\(.fingerprint)` (expired \(.expires | md_cell))"] | join(", ")) + " — the findings are visible and gated again." end;

def hidden_line($r):
  if $r.hidden.total == 0 then ""
  else "Hidden by filters: "
    + ([
        (if $r.hidden.validity > 0 then "\($r.hidden.validity) by validity (kept: \($r.filters.includeValidity | join(", ")))" else empty end),
        (if $r.hidden.autoInvalidated > 0 then "\($r.hidden.autoInvalidated) auto-invalidated while unreviewed" else empty end),
        (if $r.hidden.belowMinSeverity > 0 then "\($r.hidden.belowMinSeverity) below min-severity (\($r.filters.minSeverity))" else empty end),
        (if $r.hidden.excludedPath > 0 then "\($r.hidden.excludedPath) in excluded paths" else empty end)
      ] | join(", ")) + "."
  end;

def detail_note($r):
  if $r.detail.capped then "Details were fetched for the \($r.detail.cap) most severe findings (max-findings-detail); the rest are listed by title." else "" end;

# --- footer --------------------------------------------------------------------
def cost_phrase($r):
  (if $r.run.costCents != null then "cost \($r.run.costCents | money_cents)" else "cost n/a" end)
  + (if $r.estimate.quoteCents != null then " (estimate \($r.estimate.quoteCents | money_cents)\(if $r.estimate.billingMode == "usage" then ", usage billing" else "" end))" else "" end);

def range_phrase($r):
  if $r.target.kind == "diff" then "range `\($r.target.displayRange)`" + (if $r.target.since != null then " (since \($r.target.since.since | md_cell))" else "" end)
  elif $r.target.sha != null then "commit `\($r.target.sha | short_sha)` on `\($r.target.branch | md_cell)`"
  else "" end;

def footer($r; $version):
  ([
    (if $r.run.durationSeconds != null then "duration \($r.run.durationSeconds | duration_human)" else empty end),
    cost_phrase($r),
    (if $r.estimate.scopeFiles != null then "\(plural($r.estimate.scopeFiles; "file")) in scope" else empty end),
    (if $r.target.changedFiles != null then "\(plural($r.target.changedFiles; "changed file"))" else empty end),
    (range_phrase($r) | select(length > 0)),
    (if $r.run.url != null then "[full run](\($r.run.url))" else empty end)
  ] | join(" · "))
  + "\n<sub>v12-action \($version)"
  + (if $r.target.mergeBaseNote != null then " · \($r.target.mergeBaseNote)" else "" end)
  + "</sub>";

def joined: map(select(length > 0)) | join("\n\n");

# --- comment -------------------------------------------------------------------
# state carried in the comment for the next run (delta + Slack thread)
def comment_state($r; $slack):
  {v: 1, sha: ($r.target.blobSha // ""), run: $r.run.uid, fps: ($r.findings | map(.fingerprint) | .[0:1000])}
  + (if $slack != null and ($slack.ts | str | length) > 0 then {slackTs: $slack.ts, slackChannel: $slack.channel} else {} end);

def comment_body($r; $key; $version; $details; $rows; $slack):
  [
    state_marker($key),
    header_line($r),
    status_detail($r),
    (if $r.skipped == null and $r.run.state == "completed" then severity_table($r) else "" end),
    delta_line($r),
    findings_table($r; $rows),
    findings_details($r; $details),
    suppressed_section($r),
    expired_line($r),
    hidden_line($r),
    detail_note($r),
    "---\n" + footer($r; $version),
    (comment_state($r; $slack) | state_block)
  ] | joined;

# Render at decreasing sizes until the body fits the cap (characters, as
# GitHub counts them).
def comment_fitting($r; $key; $version; $maxDetails; $slack; $cap):
  [[$maxDetails, 200], [25, 100], [10, 50], [5, 25], [0, 25], [0, 10], [0, 0]] as $sizes
  | first(($sizes[] | select(.[0] <= $maxDetails)) as $s | comment_body($r; $key; $version; $s[0]; $s[1]; $slack) | select(length <= $cap))
    // (comment_body($r; $key; $version; 0; 0; $slack) | .[0:$cap]);

# --- check run -------------------------------------------------------------------
def check_title($r): "V12 security review: \(verdict($r))";

def check_summary($r; $version):
  [
    header_line($r),
    status_detail($r),
    (if $r.skipped == null and $r.run.state == "completed" then severity_table($r) else "" end),
    delta_line($r),
    findings_table($r; 50),
    hidden_line($r),
    "---\n" + footer($r; $version)
  ] | joined;

def check_conclusion($r):
  if $r.skipped != null then "skipped"
  elif $r.run.state == "completed" then (if $r.gate.failing then "failure" elif $r.counts.total > 0 then "neutral" else "success" end)
  elif $r.run.state == "failed" then (if $r.filters.failOnError then "failure" else "neutral" end)
  elif $r.run.state == "cancelled" then "cancelled"
  elif $r.run.state == "timed_out" then (if $r.filters.failOnError then "failure" else "neutral" end)
  else "neutral" end;

def annotation_level($f): if $f.gate then "failure" elif ($f.severity | IN("critical", "high", "medium")) then "warning" else "notice" end;

def annotations($r; $max):
  [$r.findings[] | select(.hasLocation and .location.startLine != null)][0:$max]
  | map({
      path: .location.file,
      start_line: .location.startLine,
      end_line: (.location.endLine // .location.startLine),
      annotation_level: annotation_level(.),
      title: ("V12 \(.severity): \(.title)" | .[0:255]),
      message: ((.description | if length > 0 then . else .title end) + "\n\nFingerprint \(.fingerprint) · \(.webUrl)" | .[0:60000]),
      raw_details: ((if (.impact | length) > 0 then "Impact: \(.impact)\n\n" else "" end) + (if (.rootCause | length) > 0 then "Root cause: \(.rootCause)" else "" end) | .[0:60000])
    });

# --- job summary ---------------------------------------------------------------
def filters_table($r):
  ["| Setting | Value |", "|---|---|",
   "| fail-on | \($r.filters.failOn) |",
   "| include-validity | \($r.filters.includeValidity | join(", ")) |",
   "| ignore-auto-invalidated | \($r.filters.ignoreAutoInvalidated) |",
   "| min-severity | \($r.filters.minSeverity) |",
   "| paths | \(if ($r.filters.paths | length) > 0 then ($r.filters.paths | map(md_cell) | join(", ")) else "(whole tree)" end) |",
   "| exclude-paths | \(if ($r.filters.excludePaths | length) > 0 then ($r.filters.excludePaths | map(md_cell) | join(", ")) else "(none)" end) |"]
  | join("\n");

def cost_table($r):
  ["| Cost | Value |", "|---|---|",
   "| Estimate | \($r.estimate.quoteCents | money_or_na)\(if $r.estimate.billingMode != null then " (\($r.estimate.billingMode) billing)" else "" end) |",
   "| Realized | \($r.run.costCents | money_or_na) |",
   "| Files in scope | \($r.estimate.scopeFiles // "n/a") |"]
  + (if $r.estimate.billableChangedLines != null then ["| Billable changed lines | \($r.estimate.billableChangedLines) |"] else [] end)
  | join("\n");

def target_table($r):
  ["| Target | Value |", "|---|---|",
   "| Repository | \($r.target.repository | md_cell) |",
   "| Mode | \($r.target.mode // "n/a") (\($r.target.kind // "n/a")) |"]
  + (if $r.target.kind == "diff" then ["| Range | `\($r.target.displayRange)` |"] else [] end)
  + (if $r.target.sha != null then ["| Commit | `\($r.target.sha | short_sha)` on `\($r.target.branch | md_cell)` |"] else [] end)
  + (if $r.target.since != null then ["| Window | since \($r.target.since.since | md_cell)\(if $r.target.since.fallbackToRoot then " (fell back to the root commit)" else "" end) |"] else [] end)
  + (if $r.target.pr != null then ["| Pull request | #\($r.target.pr.number) |"] else [] end)
  + (if $r.run.uid != null then ["| V12 run | [\($r.run.uid)](\($r.run.url)) (\($r.run.v12State // $r.run.state)) |"] else [] end)
  | join("\n");

def surfaces_table($surfaces):
  if $surfaces == null then ""
  else ["| Surface | Result |", "|---|---|"] + [$surfaces | to_entries[] | "| \(.key) | \(.value | md_cell) |"] | join("\n") end;

def summary_body($r; $version; $surfaces):
  [
    "## V12 security review",
    header_line($r),
    status_detail($r),
    (if $r.skipped == null and $r.run.state == "completed" then severity_table($r) else "" end),
    delta_line($r),
    findings_table($r; 100),
    suppressed_section($r),
    expired_line($r),
    hidden_line($r),
    detail_note($r),
    "### Target\n\n" + target_table($r),
    "### Cost\n\n" + cost_table($r),
    "### Gate settings\n\n" + filters_table($r),
    (if $surfaces != null then "### Surfaces\n\n" + surfaces_table($surfaces) else "" end),
    "---\n" + footer($r; $version)
  ] | joined;
