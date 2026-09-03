# scripts/jq/slack.jq - Slack Block Kit payloads from report.json.
#
# slack_message($r; $cfg; $ctx) -> {text, blocks}
# slack_thread_reply($r; $ctx)  -> {text, blocks}   (short delta post)
#
# Finding descriptions and snippets are NOT included unless
# includeSnippets is true: Slack retention is not the security team's call.

include "common";

def sl: str | gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;");
def clip($n): str | if length > $n then .[0:$n - 1] + "…" else . end;

def sev_counts_fields($r):
  [sev_order[] | . as $s | select($s != "qa" or $r.counts.qa > 0) | {type: "mrkdwn", text: "*\($s | (.[0:1] | ascii_upcase) + .[1:])*\n\($r.counts[$s])"}];

def verdict_text($r):
  if $r.skipped != null then
    (if $r.skipped.reason == "over-budget" then "not run: estimate \($r.estimate.quoteCents | money_cents) exceeds the cost ceiling"
     elif $r.skipped.reason == "empty-diff" then "skipped, nothing to review"
     elif $r.skipped.reason == "estimate-only" then "estimate only, \($r.estimate.quoteCents | money_cents)"
     else "skipped (\($r.skipped.reason))" end)
  elif $r.run.state == "failed" then "failed"
  elif $r.run.state == "cancelled" then "cancelled"
  elif $r.run.state == "timed_out" then "still running on V12"
  elif $r.counts.total == 0 then "no findings"
  else "\($r.counts.total) finding\(if $r.counts.total == 1 then "" else "s" end)"
    + " (" + ([sev_order[] | . as $s | select($r.counts[$s] > 0) | "\($r.counts[$s]) \($s)"] | join(", ")) + ")" end;

def gate_text($r):
  if $r.skipped != null or $r.run.state != "completed" then ""
  elif $r.gate.failOn == "none" then "informative (fail-on: none)"
  elif $r.gate.failing then "gate *failing* (fail-on: \($r.gate.failOn), \($r.gate.count) at or above)"
  else "gate passing (fail-on: \($r.gate.failOn))" end;

def where_text($r; $ctx):
  ([
    "*\($r.target.repository | sl)*",
    (if $r.target.pr != null then "<\($r.target.pr.url)|PR #\($r.target.pr.number)> \($r.target.pr.title | clip(80) | sl)" else empty end),
    (if ($r.target.branch | str | length) > 0 then "`\($r.target.branch | sl)`" else empty end),
    (if $r.target.kind == "diff" then "`\($r.target.displayRange)`" elif $r.target.sha != null then "`\($r.target.sha | short_sha)`" else empty end)
  ] | join(" · "));

def location_text($f):
  if $f.hasLocation | not then "no source location"
  else "`\($f.location.file | sl)\(if $f.location.startLine != null then ":\($f.location.startLine)" else "" end)`" end;

def finding_block($f; $cfg):
  {
    type: "section",
    text: {type: "mrkdwn", text: (
      "*\($f.severity | ascii_upcase)* " + (if ($f.webUrl | length) > 0 then "<\($f.webUrl)|\($f.title | clip(150) | sl)>" else ($f.title | clip(150) | sl) end)
      + " — " + location_text($f)
      + (if $f.isNew == true then " · _new_" else "" end)
      + (if $cfg.includeSnippets and ($f.description | length) > 0 then "\n" + ($f.description | clip(300) | sl) else "" end)
      + (if $cfg.includeSnippets and ($f.location.snippet | length) > 0 then "\n```\n\($f.location.snippet | clip(500) | sl)\n```" else "" end)
      | .[0:2900])}
  }
  + (if ($f.webUrl | length) > 0 then {accessory: {type: "button", text: {type: "plain_text", text: "View finding"}, url: $f.webUrl}} else {} end);

def context_line($r; $ctx):
  ([
    (if $r.run.durationSeconds != null then "duration \($r.run.durationSeconds | duration_human)" else empty end),
    (if $r.run.costCents != null then "cost \($r.run.costCents | money_cents)" elif $r.estimate.quoteCents != null then "estimate \($r.estimate.quoteCents | money_cents)" else empty end),
    (if $r.estimate.scopeFiles != null then "\($r.estimate.scopeFiles) file(s) in scope" else empty end),
    (if $r.run.uid != null then "V12 run \($r.run.uid)" else empty end),
    "v12-action \($ctx.version)"
  ] | join(" · "));

def slack_message($r; $cfg; $ctx):
  ("V12 security review: \(verdict_text($r))" | .[0:150]) as $header
  | (if $r.counts.critical > 0 and ($cfg.mentionOnCritical | length) > 0 then $cfg.mentionOnCritical + " " else "" end) as $mention
  | {
      text: ($mention + $header + (if ($r.run.url | str | length) > 0 then " — \($r.run.url)" else "" end)),
      blocks: (
        [{type: "header", text: {type: "plain_text", text: $header, emoji: false}}]
        + [{type: "section", text: {type: "mrkdwn", text: ($mention + where_text($r; $ctx) + (gate_text($r) | if length > 0 then "\n" + . else "" end) | .[0:2900])}}]
        + (if $r.skipped != null or ($r.run.state | IN("failed", "cancelled", "timed_out")) then
             [{type: "section", text: {type: "mrkdwn", text: (
               if $r.skipped != null then ($r.skipped.message | sl | clip(1500))
               elif $r.run.state == "failed" then "The V12 run failed" + (if ($r.run.statusMessage | length) > 0 then ": \($r.run.statusMessage | sl | clip(500))" else "" end)
               elif $r.run.state == "cancelled" then "The V12 run was cancelled."
               else "CI stopped waiting; the run continues on V12." end)}}]
           else [] end)
        + (if $r.skipped == null and $r.run.state == "completed" and $r.counts.total > 0 then [{type: "section", fields: sev_counts_fields($r)}] else [] end)
        + (if $r.delta != null then [{type: "context", elements: [{type: "mrkdwn", text: (if $r.delta.newCount == 0 and $r.delta.resolvedCount == 0 then "No change since `\($r.delta.priorSha | short_sha)`" else "*\($r.delta.newCount) new, \($r.delta.resolvedCount) resolved* since `\($r.delta.priorSha | short_sha)`" end)}]}] else [] end)
        + ([$r.findings[0:$cfg.maxFindings][] | finding_block(.; $cfg)])
        + (if ($r.findings | length) > $cfg.maxFindings then [{type: "context", elements: [{type: "mrkdwn", text: "…and \(($r.findings | length) - $cfg.maxFindings) more, see the full run"}]}] else [] end)
        + (if ($r.suppressed | length) > 0 then [{type: "context", elements: [{type: "mrkdwn", text: "\($r.suppressed | length) suppressed finding(s) not shown"}]}] else [] end)
        + [{type: "context", elements: [{type: "mrkdwn", text: (context_line($r; $ctx) | .[0:2900])}]}]
        + [{type: "actions", elements: (
            (if ($r.run.url | str | length) > 0 then [{type: "button", text: {type: "plain_text", text: "View run on V12"}, url: $r.run.url}] else [] end)
            + (if ($ctx.workflowUrl | str | length) > 0 then [{type: "button", text: {type: "plain_text", text: "Workflow run"}, url: $ctx.workflowUrl}] else [] end)
            + (if $r.target.pr != null and ($r.target.pr.url | length) > 0 then [{type: "button", text: {type: "plain_text", text: "Pull request"}, url: $r.target.pr.url}] else [] end))}]
      )
    }
  | .blocks = (.blocks | map(select((.type != "actions") or ((.elements | length) > 0))) | .[0:50]);

def slack_thread_reply($r; $ctx):
  ("Re-run for `\($r.target.blobSha | short_sha)`: " + verdict_text($r)
   + (if $r.delta != null then " · \($r.delta.newCount) new, \($r.delta.resolvedCount) resolved" else "" end)
   + (gate_text($r) | if length > 0 then " · " + . else "" end)
   + (if ($r.run.url | str | length) > 0 then " · <\($r.run.url)|run>" else "" end)) as $line
  | {text: ($line | gsub("<[^|>]+\\|"; "") | gsub(">"; "")), blocks: [{type: "section", text: {type: "mrkdwn", text: ($line | .[0:2900])}}]};
