# scripts/jq/config.jq - merge defaults, config file and inputs; validate.
#
# build($file; $loaded; $configFile; $repository; $today) returns
#   { config: {...effective config...}, errors: [ "message", ... ] }
# Inputs are read from the environment as V12_INPUT_<NAME> (set explicitly
# by action.yml; composite actions do not get INPUT_* variables).

include "common";

def input($name): ($ENV["V12_INPUT_" + $name] // "") | if type == "string" then . else tostring end;
def has_input($name): (input($name) | trim | length) > 0;

def pick($name; $cfg; $default):
  if has_input($name) then (input($name) | trim)
  elif $cfg != null then $cfg
  else $default end;

def pick_list($name; $cfg; $default):
  if has_input($name) then (input($name) | list_input)
  elif $cfg != null then ($cfg | list_input)
  else $default end;

def enum_error($where; $value; $allowed):
  if ($allowed | index($value)) == null
  then ["\($where): '\($value)' is not one of \($allowed | join(", "))"] else [] end;

def int_error($where; $value; $min; $max):
  ($value | to_int_or_null) as $n
  | if $n == null then ["\($where): '\($value)' is not a whole number"]
    elif $n < $min or ($max != null and $n > $max) then ["\($where): \($n) is outside \($min)..\($max // "unbounded")"]
    else [] end;

def bool_value($v): if type == "boolean" then . else ($v | to_bool) end;

def uuid_re: "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$";
def date_re: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$";

def allowed_defaults: [
  "fail-on", "include-validity", "ignore-auto-invalidated", "max-cost-cents", "min-severity",
  "hide-comment-when-clean", "wait", "wait-timeout-minutes", "poll-interval-seconds",
  "skip-if-unchanged", "fail-on-error", "comment", "max-comment-findings", "check-run",
  "check-run-name", "max-annotations", "upload-sarif", "sarif-category", "job-summary", "fetch-report",
  "max-findings-detail"
];
def allowed_slack: ["notify-on", "mention-on-critical", "thread", "include-snippets", "channel", "max-findings"];
def allowed_suppression: ["fingerprint", "reason", "expires", "approved-by"];

# --- file validation ---------------------------------------------------------

def unknown_keys($obj; $allowed; $where):
  if ($obj | type) != "object" then []
  else (($obj | keys) - $allowed) | map("\($where): unknown key '\(.)' (allowed: \($allowed | join(", ")))") end;

def expect_type($v; $types; $where):
  if $v == null then []
  elif ([$v | type] | inside($types)) then []
  else ["\($where): expected \($types | join(" or ")), got \($v | type)"] end;

def validate_file($f):
  if $f == null then []
  elif ($f | type) != "object" then ["config file: top level must be a mapping"]
  else
    unknown_keys($f; ["defaults", "paths", "context-documents", "suppressions", "notifications"]; "config file")
    + expect_type($f.defaults; ["object"]; "defaults")
    + unknown_keys($f.defaults; allowed_defaults; "defaults")
    + expect_type($f.paths; ["object"]; "paths")
    + unknown_keys($f.paths; ["include", "exclude"]; "paths")
    + expect_type($f.paths.include; ["array", "string"]; "paths.include")
    + expect_type($f.paths.exclude; ["array", "string"]; "paths.exclude")
    + expect_type($f["context-documents"]; ["array"]; "context-documents")
    + expect_type($f.suppressions; ["array"]; "suppressions")
    + expect_type($f.notifications; ["object"]; "notifications")
    + unknown_keys($f.notifications; ["slack"]; "notifications")
    + expect_type($f.notifications.slack; ["object"]; "notifications.slack")
    + unknown_keys($f.notifications.slack; allowed_slack; "notifications.slack")
    + ([($f.suppressions // [])[]] | to_entries | map(
        .key as $i | .value as $s | "suppressions[\($i)]" as $w
        | if ($s | type) != "object" then ["\($w): expected a mapping"]
          else
            unknown_keys($s; allowed_suppression; $w)
            + (if ($s.fingerprint | str | test("^[0-9a-f]{16}$")) then [] else ["\($w).fingerprint: must be the 16-character hex fingerprint shown in the V12 comment (got '\($s.fingerprint | str)')"] end)
            + (if ($s.reason | str | trim | length) > 0 then [] else ["\($w).reason: a reason is required"] end)
            + (if $s.expires == null then ["\($w).expires: an expiry date (YYYY-MM-DD) is required; permanent suppressions are not allowed"]
               elif ($s.expires | str | test(date_re) | not) then ["\($w).expires: '\($s.expires | str)' is not a YYYY-MM-DD date (quote it in YAML)"]
               elif ($s.expires | valid_date | not) then ["\($w).expires: '\($s.expires | str)' is not a valid calendar date"]
               else [] end)
            + expect_type($s["approved-by"]; ["string"]; "\($w).approved-by")
          end) | flatten)
  end;

# --- build -------------------------------------------------------------------

def build($file; $loaded; $configFile; $repository; $today):
  ($file // {}) as $f
  | ($f.defaults // {}) as $d
  | (($f.notifications // {}).slack // {}) as $sl
  | validate_file($f) as $fileErrors
  | {
      mode: (pick("MODE"; null; "auto") | ascii_downcase),
      since: pick("SINCE"; null; ""),
      baseRef: pick("BASE_REF"; null; ""),
      headRef: pick("HEAD_REF"; null; ""),
      branch: pick("BRANCH"; null; ""),
      sha: pick("SHA"; null; ""),
      repository: pick("REPOSITORY"; null; $repository),
      name: pick("NAME"; null; ""),
      paths: pick_list("PATHS"; $f.paths.include; []),
      excludePaths: pick_list("EXCLUDE_PATHS"; $f.paths.exclude; []),
      contextDocuments: pick_list("CONTEXT_DOCUMENTS"; $f["context-documents"]; []),
      estimateOnly: (pick("ESTIMATE_ONLY"; null; false) | to_bool),
      maxCostCents: pick("MAX_COST_CENTS"; $d["max-cost-cents"]; null),
      skipIfUnchanged: (pick("SKIP_IF_UNCHANGED"; $d["skip-if-unchanged"]; true) | to_bool),
      wait: (pick("WAIT"; $d.wait; true) | to_bool),
      waitTimeoutMinutes: pick("WAIT_TIMEOUT_MINUTES"; $d["wait-timeout-minutes"]; 60),
      pollIntervalSeconds: pick("POLL_INTERVAL_SECONDS"; $d["poll-interval-seconds"]; 15),
      failOn: (pick("FAIL_ON"; $d["fail-on"]; "none") | ascii_downcase),
      includeValidity: (pick_list("INCLUDE_VALIDITY"; $d["include-validity"]; ["valid", "unreviewed"]) | map(ascii_downcase)),
      ignoreAutoInvalidated: (pick("IGNORE_AUTO_INVALIDATED"; $d["ignore-auto-invalidated"]; false) | to_bool),
      minSeverity: (pick("MIN_SEVERITY"; $d["min-severity"]; "info") | ascii_downcase),
      failOnError: (pick("FAIL_ON_ERROR"; $d["fail-on-error"]; false) | to_bool),
      comment: (pick("COMMENT"; $d.comment; true) | to_bool),
      commentKey: pick("COMMENT_KEY"; null; ""),
      prNumber: pick("PR_NUMBER"; null; null),
      hideCommentWhenClean: (pick("HIDE_COMMENT_WHEN_CLEAN"; $d["hide-comment-when-clean"]; false) | to_bool),
      maxCommentFindings: pick("MAX_COMMENT_FINDINGS"; $d["max-comment-findings"]; 25),
      checkRun: (pick("CHECK_RUN"; $d["check-run"]; true) | to_bool),
      checkRunName: pick("CHECK_RUN_NAME"; $d["check-run-name"]; "V12 Security"),
      maxAnnotations: pick("MAX_ANNOTATIONS"; $d["max-annotations"]; 200),
      sarifPath: pick("SARIF_PATH"; null; ""),
      uploadSarif: (pick("UPLOAD_SARIF"; $d["upload-sarif"]; false) | to_bool),
      sarifCategory: pick("SARIF_CATEGORY"; $d["sarif-category"]; ""),
      jobSummary: (pick("JOB_SUMMARY"; $d["job-summary"]; true) | to_bool),
      fetchReport: (pick("FETCH_REPORT"; $d["fetch-report"]; true) | to_bool),
      maxFindingsDetail: pick("MAX_FINDINGS_DETAIL"; $d["max-findings-detail"]; 200),
      cancelOnWorkflowCancel: (pick("CANCEL_ON_WORKFLOW_CANCEL"; null; true) | to_bool),
      slack: {
        channel: pick("SLACK_CHANNEL"; $sl.channel; ""),
        notifyOn: (pick("SLACK_NOTIFY_ON"; $sl["notify-on"]; "gate-failure") | ascii_downcase),
        mentionOnCritical: pick("SLACK_MENTION_ON_CRITICAL"; $sl["mention-on-critical"]; ""),
        thread: (pick("SLACK_THREAD"; $sl.thread; true) | to_bool),
        includeSnippets: (pick("SLACK_INCLUDE_SNIPPETS"; $sl["include-snippets"]; false) | to_bool),
        maxFindings: pick("SLACK_MAX_FINDINGS"; $sl["max-findings"]; 5),
        webhookConfigured: has_input("SLACK_WEBHOOK"),
        botTokenConfigured: has_input("SLACK_BOT_TOKEN")
      },
      suppressions: (($f.suppressions // []) | map(select(type == "object") | {
        fingerprint: (.fingerprint | str),
        reason: (.reason | str | trim),
        expires: (.expires | str),
        approvedBy: (.["approved-by"] | str),
        expired: ((.expires | str) < $today)
      })),
      configFile: $configFile,
      configFileLoaded: $loaded,
      today: $today
    } as $c
  | (
      enum_error("mode"; $c.mode; ["auto", "pr", "diff", "full"])
      + enum_error("fail-on"; $c.failOn; ["none"] + sev_order)
      + enum_error("min-severity"; $c.minSeverity; sev_order)
      + (if ($c.includeValidity | length) == 0 then ["include-validity: must list at least one of \(validity_order | join(", "))"] else [] end)
      + ([$c.includeValidity[] | select(. as $v | (validity_order | index($v)) == null)] | map("include-validity: '\(.)' is not one of \(validity_order | join(", "))"))
      + enum_error("slack-notify-on"; $c.slack.notifyOn; ["always", "findings", "gate-failure", "never"])
      + (if $c.maxCostCents == null or ($c.maxCostCents | str | trim) == "" then [] else int_error("max-cost-cents"; $c.maxCostCents; 0; null) end)
      + int_error("wait-timeout-minutes"; $c.waitTimeoutMinutes; 1; 100000)
      + int_error("poll-interval-seconds"; $c.pollIntervalSeconds; 5; 3600)
      + int_error("max-annotations"; $c.maxAnnotations; 0; 5000)
      + int_error("max-comment-findings"; $c.maxCommentFindings; 0; 1000)
      + int_error("slack-max-findings"; $c.slack.maxFindings; 0; 50)
      + int_error("max-findings-detail"; $c.maxFindingsDetail; 0; 5000)
      + (if $c.prNumber == null or ($c.prNumber | str | trim) == "" then [] else int_error("pr-number"; $c.prNumber; 1; null) end)
      + (if ($c.contextDocuments | length) > 100 then ["context-documents: at most 100 documents can be attached to a run"] else [] end)
      + ([$c.contextDocuments[] | select(test(uuid_re) | not)] | map("context-documents: '\(.)' is not a context document UID (a UUID such as 0197b7e2-72cd-7bb0-b1c6-6f2ae65a2e6d)"))
      + (if ($c.paths | length) > 500 then ["paths: V12 accepts at most 500 path entries"] else [] end)
      + ([$c.paths[], $c.excludePaths[] | select(test("^/") or test("(^|/)\\.\\.(/|$)"))] | map("paths: '\(.)' must be relative to the repository root without '..' segments"))
      + (if ($c.name | length) > 200 then ["name: at most 200 characters"] else [] end)
      + (if ($c.repository | test("^[^/\\s]+/[^/\\s]+$") | not) then ["repository: '\($c.repository)' must be owner/name"] else [] end)
      + (if $c.slack.botTokenConfigured and ($c.slack.channel | length) == 0 then ["slack-channel is required when slack-bot-token is set"] else [] end)
    ) as $valueErrors
  | {
      config: ($c
        | .maxCostCents = (if .maxCostCents == null or (.maxCostCents | str | trim) == "" then null else (.maxCostCents | to_int_or_null) end)
        | .waitTimeoutMinutes = (.waitTimeoutMinutes | to_int_or_null)
        | .pollIntervalSeconds = (.pollIntervalSeconds | to_int_or_null)
        | .maxAnnotations = (.maxAnnotations | to_int_or_null)
        | .maxCommentFindings = (.maxCommentFindings | to_int_or_null)
        | .slack.maxFindings = (.slack.maxFindings | to_int_or_null)
        | .maxFindingsDetail = (.maxFindingsDetail | to_int_or_null)
        | .prNumber = (if .prNumber == null or (.prNumber | str | trim) == "" then null else (.prNumber | to_int_or_null) end)
        | .paths = (.paths | map(norm_path))
        | .excludePaths = (.excludePaths | map(norm_path))
      ),
      errors: ($fileErrors + $valueErrors)
    };
