# scripts/jq/process.jq - turns raw findings plus context into report.json.
#
# build_report($cfg; $refs; $run; $pinned; $changed; $meta) where the input is
# the array of findings, each already carrying .fingerprint and .titleHash
# (computed in bash, see collect-findings.sh).

include "common";

def enrich($cfg; $refs; $changedAll):
  . as $f
  | ($f | primary_location) as $loc
  | {
      uid: $f.uid,
      title: ($f.title | str),
      severity: ($f.severity | str | ascii_downcase),
      validity: ($f.validity | str | ascii_downcase),
      autoInvalidated: (($f.autoInvalidated // false) | to_bool),
      description: ($f.description | nz | str),
      impact: ($f.impact | nz | str),
      rootCause: ($f.rootCause | nz | str),
      webUrl: ($f.webUrl | str),
      sourceUrls: (($f.sourceUrls // []) | map(select(type == "string"))),
      commentCount: ($f.commentCount | to_int_or_null),
      createdAt: ($f.createdAt | nz | str),
      location: ($loc + {lang: ($loc.file | lang_for_file)}),
      locationCount: (($f.sourceLocations // []) | length),
      hasLocation: ($f | has_location),
      blobUrl: ($f | blob_url($refs.serverUrl; $refs.repository; $refs.blobSha)),
      fingerprint: ($f.fingerprint | str),
      ruleId: ("v12/" + ($f.severity | str | ascii_downcase) + "/" + ($f.title | title_slug) + "-" + ($f.titleHash | str | .[0:6])),
      detailFetched: (($f.detailFetched // false) | to_bool),
      inDiff: (if $changedAll == null then null else (($loc.file | length) > 0 and ($changedAll | index($loc.file)) != null) end)
    }
  | .sourceUrl = (if .blobUrl != null then .blobUrl elif (.sourceUrls | length) > 0 then .sourceUrls[0] else null end);

def filter_reason($cfg):
  # null when the finding is kept, otherwise why it is hidden.
  . as $f
  | if (($cfg.includeValidity | index($f.validity)) == null) then "validity"
  elif ($cfg.ignoreAutoInvalidated and .autoInvalidated and .validity == "unreviewed") then "auto-invalidated"
  elif ((.severity | sev_rank) > ($cfg.minSeverity | sev_rank)) then "below-min-severity"
  elif (($cfg.excludePaths | length) > 0 and .hasLocation and (.location.file | glob_match($cfg.excludePaths))) then "excluded-path"
  else null end;

def conclusion_for($state; $gateFailing; $hasFindings; $failOnError):
  if $state == "completed" then (if $gateFailing then "failure" elif $hasFindings then "neutral" else "success" end)
  elif $state == "failed" then "failure"
  elif $state == "cancelled" then "cancelled"
  elif $state == "timed_out" then "timed_out"
  else "neutral" end;

def build_report($cfg; $refs; $run; $pinned; $changed; $meta):
  ($changed.all // null) as $changedAll
  | map(enrich($cfg; $refs; $changedAll)) as $all
  | ($all | map(. + {hiddenReason: filter_reason($cfg)})) as $tagged
  | ($tagged | map(select(.hiddenReason == null)) | sort_findings) as $kept
  | ($cfg.failOn | if . == "none" then null else sev_rank end) as $gateRank
  | ($kept | map(.gate = ($gateRank != null and (.severity | sev_rank) <= $gateRank))) as $kept
  | ($kept | map(select(.gate))) as $gateFindings
  | ($run.actionState // $run.state // "not-created") as $state
  | ($gateFindings | length) as $gateCount
  | ($gateCount > 0) as $gateFailing
  | {
      version: 1,
      generatedAt: $meta.generatedAt,
      actionVersion: $meta.actionVersion,
      skipped: null,
      run: {
        uid: $run.uid, url: $run.webUrl, state: $state, v12State: ($run.state | nz | str), statusMessage: ($run.statusMessage | nz | str),
        name: ($run.name | nz | str), startedAt: ($run.startedAt | nz | str), endedAt: ($run.endedAt | nz | str),
        durationSeconds: ($run.durationSeconds // null), costCents: ($run.costCents // null)
      },
      estimate: {
        quoteCents: ($pinned.quoteCents // null), createQuoteCents: ($pinned.createQuoteCents // null),
        billingMode: ($pinned.billingMode // null), scopeFiles: ($meta.scopeFiles // null),
        billableChangedLines: ($meta.billableChangedLines // null)
      },
      target: {
        mode: $refs.mode, kind: $refs.kind, repository: $refs.repository, serverUrl: $refs.serverUrl,
        fromSha: $refs.fromSha, toSha: $refs.toSha, branch: $refs.branch, sha: $refs.sha, blobSha: $refs.blobSha,
        displayRange: $refs.displayRange, since: $refs.since, mergeBaseNote: $refs.mergeBaseNote,
        pr: $refs.pr, commentPrNumber: $refs.commentPrNumber, shallow: $refs.shallow,
        changedFiles: $refs.changedFiles, changedFilesTotal: $refs.changedFilesTotal
      },
      filters: {
        includeValidity: $cfg.includeValidity, ignoreAutoInvalidated: $cfg.ignoreAutoInvalidated,
        minSeverity: $cfg.minSeverity, failOn: $cfg.failOn, paths: $cfg.paths, excludePaths: $cfg.excludePaths,
        failOnError: $cfg.failOnError
      },
      counts: ($kept | severity_counts | . + {total: ($kept | length)}),
      hidden: {
        validity: ($tagged | map(select(.hiddenReason == "validity")) | length),
        autoInvalidated: ($tagged | map(select(.hiddenReason == "auto-invalidated")) | length),
        belowMinSeverity: ($tagged | map(select(.hiddenReason == "below-min-severity")) | length),
        excludedPath: ($tagged | map(select(.hiddenReason == "excluded-path")) | length),
        total: ($tagged | map(select(.hiddenReason != null)) | length)
      },
      totals: {fetched: ($all | length), totalMatching: ($meta.totalMatching // ($all | length))},
      detail: $meta.detail,
      findings: $kept,
      suppressed: [],
      expiredSuppressions: [],
      unmatchedSuppressions: [],
      gate: {failOn: $cfg.failOn, count: $gateCount, failing: $gateFailing, findingUids: ($gateFindings | map(.uid))},
      delta: null,
      conclusion: conclusion_for($state; $gateFailing; ($kept | length) > 0; $cfg.failOnError),
      jobShouldFail: ($gateFailing or ($cfg.failOnError and ($state == "failed" or $state == "cancelled" or $state == "timed_out")))
    };

# Report for the no-run cases (skipped, over budget, estimate-only, fork).
def build_skipped_report($cfg; $refs; $pinned; $meta):
  {
    version: 1,
    generatedAt: $meta.generatedAt,
    actionVersion: $meta.actionVersion,
    skipped: {reason: ($refs.skippedReason // $meta.skippedReason // "unknown"), message: ($refs.skippedMessage // $meta.skippedMessage // "")},
    run: {uid: null, url: null, state: "not-created", v12State: "", statusMessage: "", name: "", startedAt: "", endedAt: "", durationSeconds: null, costCents: null},
    estimate: {quoteCents: ($pinned.quoteCents // null), createQuoteCents: null, billingMode: ($pinned.billingMode // null), scopeFiles: ($meta.scopeFiles // null), billableChangedLines: ($meta.billableChangedLines // null)},
    target: {
      mode: ($refs.mode // null), kind: ($refs.kind // null), repository: ($refs.repository // $cfg.repository), serverUrl: $refs.serverUrl,
      fromSha: $refs.fromSha, toSha: $refs.toSha, branch: $refs.branch, sha: $refs.sha, blobSha: $refs.blobSha,
      displayRange: ($refs.displayRange // null), since: $refs.since, mergeBaseNote: null,
      pr: $refs.pr, commentPrNumber: $refs.commentPrNumber, shallow: $refs.shallow, changedFiles: $refs.changedFiles, changedFilesTotal: $refs.changedFilesTotal
    },
    filters: {includeValidity: $cfg.includeValidity, ignoreAutoInvalidated: $cfg.ignoreAutoInvalidated, minSeverity: $cfg.minSeverity, failOn: $cfg.failOn, paths: $cfg.paths, excludePaths: $cfg.excludePaths, failOnError: $cfg.failOnError},
    counts: {critical: 0, high: 0, medium: 0, low: 0, info: 0, qa: 0, total: 0},
    hidden: {validity: 0, autoInvalidated: 0, belowMinSeverity: 0, excludedPath: 0, total: 0},
    totals: {fetched: 0, totalMatching: 0},
    detail: {needed: false, fetched: 0, capped: false, cap: 0},
    findings: [], suppressed: [], expiredSuppressions: [], unmatchedSuppressions: [],
    gate: {failOn: $cfg.failOn, count: 0, failing: false, findingUids: []},
    delta: null,
    conclusion: "skipped",
    jobShouldFail: false
  };

# Apply suppressions from the config to a report. Suppressed findings move
# to .suppressed; counts and the gate are recomputed; expired suppressions
# are reported (and their findings stay visible).
def apply_suppressions($cfg):
  . as $r
  | ($cfg.suppressions // []) as $sups
  | ($sups | map(select(.expired | not))) as $active
  | ($sups | map(select(.expired))) as $expired
  | ($active | map(.fingerprint)) as $activeFps
  | ($r.findings | map(select(. as $f | ($f.fingerprint | length) > 0 and ($activeFps | index($f.fingerprint)) != null)
      | . as $f | .suppression = ($active | map(select(.fingerprint == $f.fingerprint)) | .[0] | {reason, expires, approvedBy}))) as $suppressed
  | ($r.findings | map(select(. as $f | ($activeFps | index($f.fingerprint)) == null))) as $kept
  | ($r.findings | map(.fingerprint)) as $allFps
  | ($cfg.failOn | if . == "none" then null else sev_rank end) as $gateRank
  | ($kept | map(select(.gate))) as $gateFindings
  | $r
  | .findings = $kept
  | .suppressed = $suppressed
  | .expiredSuppressions = ($expired | map(. as $s | . + {matched: (($allFps | index($s.fingerprint)) != null)}))
  | .unmatchedSuppressions = ($active | map(select(. as $s | ($allFps | index($s.fingerprint)) == null)))
  | .counts = ($kept | severity_counts | . + {total: ($kept | length)})
  | .gate = {failOn: $cfg.failOn, count: ($gateFindings | length), failing: (($gateFindings | length) > 0), findingUids: ($gateFindings | map(.uid))}
  | .conclusion = (if .skipped != null then "skipped" else conclusion_for(.run.state; .gate.failing; ($kept | length) > 0; $cfg.failOnError) end)
  | .jobShouldFail = (.gate.failing or ($cfg.failOnError and (.run.state == "failed" or .run.state == "cancelled" or .run.state == "timed_out")));

# Delta against the fingerprints stored in the previous comment (multiset).
def apply_delta($prior):
  . as $r
  | if $prior == null or ($prior | type) != "object" then .delta = null
    else
      (($prior.fps // []) | map(str)) as $before
      | ($r.findings | map(.fingerprint)) as $after
      | ($before | group_by(.) | map({key: .[0], value: length}) | from_entries) as $bc
      | ($after | group_by(.) | map({key: .[0], value: length}) | from_entries) as $ac
      | ([$bc, $ac] | map(keys) | add | unique) as $keys
      | ($keys | map(. as $k | {fp: $k, before: ($bc[$k] // 0), after: ($ac[$k] // 0)})) as $rows
      | .delta = {
          hasPrior: true,
          priorSha: ($prior.sha | nz | str),
          priorRunUid: ($prior.run // null),
          new: ($rows | map(select(.after > .before) | {fp, count: (.after - .before)})),
          resolved: ($rows | map(select(.before > .after) | {fp, count: (.before - .after)})),
          newCount: ($rows | map(select(.after > .before) | .after - .before) | add // 0),
          resolvedCount: ($rows | map(select(.before > .after) | .before - .after) | add // 0),
          unchangedCount: ($rows | map([.before, .after] | min) | add // 0)
        }
      | .findings = (.findings | map(. as $f | .isNew = (($bc[$f.fingerprint] // 0) == 0)))
    end;
