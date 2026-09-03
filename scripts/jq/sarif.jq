# scripts/jq/sarif.jq - SARIF 2.1.0 document from report.json.
#
# sarif($r; $version; $anchor; $category; $maxResults)
#   $anchor: repository-relative file used as the location for findings that
#   carry no sourceLocations (GitHub needs a physical location to show a
#   result). Suppressed findings are omitted so code scanning closes their
#   alerts; the suppression reason lives in the config file.

include "common";

def rule_for($f):
  {
    id: $f.ruleId,
    name: ($f.title | str | [scan("[A-Za-z0-9]+")] | map((.[0:1] | ascii_upcase) + .[1:]) | join("") | if length == 0 then "Finding" else . end | .[0:255]),
    shortDescription: {text: ($f.title | .[0:1024])},
    fullDescription: {text: ((if ($f.description | length) > 0 then $f.description else $f.title end) | .[0:1024])},
    helpUri: (if ($f.webUrl | length) > 0 then $f.webUrl else "https://v12.sh" end),
    help: {
      text: ([$f.description, (if ($f.impact | length) > 0 then "Impact: " + $f.impact else empty end), (if ($f.rootCause | length) > 0 then "Root cause: " + $f.rootCause else empty end)] | map(select(length > 0)) | join("\n\n") | .[0:20000]),
      markdown: ([(if ($f.description | length) > 0 then $f.description else empty end), (if ($f.impact | length) > 0 then "**Impact**\n\n" + $f.impact else empty end), (if ($f.rootCause | length) > 0 then "**Root cause**\n\n" + $f.rootCause else empty end), "[View on V12](\($f.webUrl))"] | join("\n\n") | .[0:20000])
    },
    defaultConfiguration: {level: ($f.severity | sarif_level)},
    properties: (
      {tags: (["security", "v12", $f.severity] | unique)}
      + (if ($f.severity | security_severity) != null then {"security-severity": ($f.severity | security_severity)} else {tags: ["v12", "quality", $f.severity]} end)
    )
  };

def result_for($f; $anchor; $ruleIndexes; $counts):
  ($ruleIndexes[$f.ruleId]) as $idx
  | ($f.fingerprint + ":" + ($counts[$f.fingerprint] | tostring)) as $lineHash
  | {
      ruleId: $f.ruleId,
      ruleIndex: $idx,
      level: ($f.severity | sarif_level),
      message: {text: (if $f.hasLocation then $f.title else $f.title + " (V12 reported no source location; anchored to \($anchor))" end)},
      locations: [{
        physicalLocation: {
          artifactLocation: {uri: (if $f.hasLocation then $f.location.file else $anchor end), uriBaseId: "%SRCROOT%"},
          region: (if $f.hasLocation and $f.location.startLine != null
                   then {startLine: $f.location.startLine, endLine: ($f.location.endLine // $f.location.startLine)}
                   else {startLine: 1} end)
        }
      }],
      partialFingerprints: {primaryLocationLineHash: $lineHash, "v12/fingerprint": $f.fingerprint},
      properties: {
        severity: $f.severity, validity: $f.validity, autoInvalidated: $f.autoInvalidated,
        findingUid: $f.uid, fingerprint: $f.fingerprint, webUrl: $f.webUrl, inDiff: $f.inDiff,
        hasSourceLocation: $f.hasLocation
      }
    }
  | (if ($f.webUrl | length) > 0 then .hostedViewerUri = $f.webUrl else . end);

def sarif($r; $version; $anchor; $category; $maxResults):
  ($r.findings | sort_findings | .[0:$maxResults]) as $findings
  | ($findings | group_by(.ruleId) | map(.[0] | rule_for(.))) as $rules
  | ($rules | to_entries | map({key: .value.id, value: .key}) | from_entries) as $ruleIndexes
  # ":n" suffix distinguishes repeats of one fingerprint within the run, in order
  | (reduce $findings[] as $f ({seen: {}, out: []};
       ((.seen[$f.fingerprint] // 0) + 1) as $n
       | .seen[$f.fingerprint] = $n
       | .out += [result_for($f; $anchor; $ruleIndexes; {($f.fingerprint): $n})])) as $acc
  | {
      "$schema": "https://json.schemastore.org/sarif-2.1.0.json",
      version: "2.1.0",
      runs: [{
        tool: {driver: {
          name: "V12",
          fullName: "V12 security audit (v12-action)",
          informationUri: "https://v12.sh",
          version: $version,
          semanticVersion: ($version | if test("^[0-9]+\\.[0-9]+\\.[0-9]+") then . else "0.0.0" end),
          rules: $rules
        }},
        automationDetails: {id: $category},
        invocations: [{
          executionSuccessful: ($r.run.state == "completed"),
          properties: {
            runUid: $r.run.uid, runUrl: $r.run.url, state: $r.run.state,
            costCents: $r.run.costCents, estimateCents: $r.estimate.quoteCents, billingMode: $r.estimate.billingMode,
            totalFindings: ($r.findings | length), resultsIncluded: ($findings | length),
            truncated: (($r.findings | length) > ($findings | length)),
            suppressedOmitted: ($r.suppressed | length),
            fingerprintScheme: "sha256(v12-fp-v1, path, normalized title, whitespace-stripped snippet)[0:16]"
          }
        } + (if ($r.run.endedAt | length) > 0 then {endTimeUtc: $r.run.endedAt} else {} end)
          + (if ($r.run.startedAt | length) > 0 then {startTimeUtc: $r.run.startedAt} else {} end)],
        versionControlProvenance: (
          if ($r.target.repository | length) > 0 and ($r.target.blobSha | str | length) > 0
          then [{repositoryUri: "\($r.target.serverUrl // "https://github.com")/\($r.target.repository)", revisionId: $r.target.blobSha}
                 + (if ($r.target.branch | str | length) > 0 then {branch: $r.target.branch} else {} end)]
          else [] end),
        results: $acc.out,
        properties: {mode: $r.target.mode, kind: $r.target.kind, gate: $r.gate, counts: $r.counts}
      }]
    };
