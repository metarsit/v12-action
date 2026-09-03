# scripts/jq/common.jq - shared jq definitions for v12-action.
#
# Compatible with jq 1.6, 1.7 and 1.8: no trim/ltrim/rtrim, abs, toarray,
# pick, splits/2, getpath/1 or debug/1. Every optional field is guarded so a
# null never leaks into rendered text as the string "null".

def sev_order: ["critical", "high", "medium", "low", "info", "qa"];
def sev_rank: . as $s | (sev_order | index($s)) // 99;
def validity_order: ["valid", "unreviewed", "acknowledged", "invalid"];
def validity_rank: . as $v | (validity_order | index($v)) // 99;

def str: if . == null then "" else tostring end;
def nz: if . == null then "" else . end;
def trim: if type == "string" then sub("^[[:space:]]+"; "") | sub("[[:space:]]+$"; "") else . end;

# "a, b\nc" -> ["a", "b", "c"]
def list_input:
  if type == "array" then map(str | trim) | map(select(length > 0))
  else str | split("\n") | map(split(",")) | flatten | map(trim) | map(select(length > 0))
  end;

def to_bool:
  if type == "boolean" then .
  elif type == "string" then (ascii_downcase | trim | (. == "true" or . == "yes" or . == "1" or . == "on"))
  elif type == "number" then . != 0
  else false end;

# Returns an integer, or null when the value is not a whole number.
def to_int_or_null:
  if type == "number" then (if . == floor then . else null end)
  elif type == "string" then (trim | if test("^-?[0-9]+$") then tonumber else null end)
  else null end;

def short_sha: str | .[0:7];

# True for a real YYYY-MM-DD calendar date (strptime accepts Feb 30).
def valid_date:
  ([str | capture("^(?<y>[0-9]{4})-(?<m>[0-9]{2})-(?<d>[0-9]{2})$")] | .[0]) as $p
  | if $p == null then false
    else ($p.y | tonumber) as $y | ($p.m | tonumber) as $m | ($p.d | tonumber) as $d
      | (($y % 4 == 0) and (($y % 100 != 0) or ($y % 400 == 0))) as $leap
      | [31, (if $leap then 29 else 28 end), 31, 30, 31, 30, 31, 31, 30, 31, 30, 31] as $dim
      | ($m >= 1 and $m <= 12 and $d >= 1 and $d <= $dim[$m - 1])
    end;

# ISO-8601 timestamp (with or without fractional seconds / +00:00) -> epoch
def iso_to_epoch:
  str
  | sub("\\.[0-9]+"; "")
  | sub("\\+00:00$"; "Z")
  | if test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$") then fromdateiso8601 else null end;

def duration_human:
  if . == null then "n/a"
  else (. | floor) as $s
    | if $s < 60 then "\($s)s"
      elif $s < 3600 then "\($s / 60 | floor)m \($s % 60 | tostring | if length < 2 then "0" + . else . end)s"
      else "\($s / 3600 | floor)h \(($s % 3600) / 60 | floor | tostring | if length < 2 then "0" + . else . end)m"
      end
  end;

# 12345 -> "$123.45"
def money_cents:
  if . == null then "n/a"
  else (. | round) as $c
    | (if $c < 0 then "-" else "" end) as $sign
    | ($c | if . < 0 then -. else . end) as $a
    | "\($sign)$\($a / 100 | floor).\($a % 100 | tostring | if length < 2 then "0" + . else . end)"
  end;

def usd_to_cents: if . == null then null else (. * 100 | round) end;

# ---------------------------------------------------------------------------
# Paths and globs
# ---------------------------------------------------------------------------

def norm_path: str | gsub("\\\\"; "/") | sub("^(\\./)+"; "") | sub("^/+"; "");

# Glob -> anchored regex. "**" spans directories, "*" and "?" do not. A
# pattern without wildcards matches the path itself or anything below it.
def glob_to_regex:
  . as $g
  | if ($g | test("[*?]") | not) then
      "^" + ($g | sub("/+$"; "") | gsub("(?<c>[.^$+(){}\\[\\]|\\\\])"; "\\\(.c)")) + "(/.*)?$"
    else
      "^" + ([$g | scan("\\*\\*/|\\*\\*|\\*|\\?|[^*?]+")]
             | map(
                 if . == "**/" then "(?:.*/)?"
                 elif . == "**" then ".*"
                 elif . == "*" then "[^/]*"
                 elif . == "?" then "[^/]"
                 else gsub("(?<c>[.^$+(){}\\[\\]|\\\\])"; "\\\(.c)")
                 end)
             | join("")) + "$"
    end;

def glob_match($patterns):
  . as $p | any($patterns[]; . as $g | $p | test($g | glob_to_regex));

# Turn an include glob into a V12 `paths` entry (a path prefix). Returns null
# when the glob cannot be expressed as a prefix and must be expanded.
def glob_to_api_path:
  str | trim
  | if test("[*?]") | not then (if test("/$") then . else . end)
    elif test("^[^*?]+/\\*\\*$") then sub("/\\*\\*$"; "/")
    elif test("^[^*?]+/\\*$") then sub("/\\*$"; "/")
    elif test("^[^*?]+/\\*\\*/\\*$") then sub("/\\*\\*/\\*$"; "/")
    else null end;

# ---------------------------------------------------------------------------
# Findings
# ---------------------------------------------------------------------------

# First source location, normalised. Always returns an object; `.file` is ""
# when V12 reported no location.
def primary_location:
  ((.sourceLocations // []) | map(select(type == "object")) | .[0] // {}) as $l
  | {
      file: ($l.file | norm_path),
      startLine: ($l.startLine | to_int_or_null),
      endLine: ($l.endLine | to_int_or_null),
      snippet: ($l.snippet | nz | str),
      note: ($l.note | nz | str)
    }
  | .endLine = (if .endLine == null or (.startLine != null and .endLine < .startLine) then .startLine else .endLine end);

def has_location: (primary_location.file | length) > 0;

def stop_words: ["a", "an", "the", "in", "of", "on", "to", "is", "for", "with", "via", "by", "and", "or", "at", "from", "as"];

def norm_title:
  str | ascii_downcase
  | [scan("[a-z0-9]+")]
  | . - stop_words
  | unique
  | join(" ");

def title_slug: norm_title | gsub("[^a-z0-9]+"; "-") | .[0:48] | sub("-+$"; "") | if length == 0 then "finding" else . end;

# Material hashed (in bash, with sha256) into the 16-hex fingerprint.
def fingerprint_material:
  primary_location as $l
  | "v12-fp-v1\n" + $l.file + "\n" + (.title | norm_title) + "\n" + ($l.snippet | gsub("[[:space:]]+"; ""));

def severity_counts:
  reduce .[] as $f ({critical: 0, high: 0, medium: 0, low: 0, info: 0, qa: 0};
    if ($f.severity | sev_rank) < 99 then .[$f.severity] += 1 else . end);

# Works on raw API findings (sourceLocations) and enriched ones (location).
def loc_file: if has("location") then (.location.file | str) else primary_location.file end;
def loc_line: if has("location") then (.location.startLine // 0) else (primary_location.startLine // 0) end;

def sort_findings:
  sort_by([(.severity | sev_rank), (.validity | validity_rank), loc_file, loc_line, (.title | str)]);

# ---------------------------------------------------------------------------
# Markdown helpers
# ---------------------------------------------------------------------------

# Literal text for a Markdown table cell: HTML-escaped, no pipes, no
# newlines, no accidental emphasis or code spans.
def md_cell:
  str | @html
  | gsub("\\|"; "&#124;") | gsub("`"; "&#96;") | gsub("\\*"; "&#42;") | gsub("_"; "&#95;")
  | gsub("\\["; "&#91;") | gsub("\\]"; "&#93;") | gsub("~"; "&#126;") | gsub("\r?\n"; " ");

# Literal text for Markdown prose (newlines kept).
def md_text:
  str | @html | gsub("`"; "&#96;") | gsub("\\*"; "&#42;") | gsub("_"; "&#95;")
  | gsub("\\["; "&#91;") | gsub("\\]"; "&#93;") | gsub("~"; "&#126;") | gsub("(?<h>^|\n)#"; "\(.h)&#35;");

# A backtick fence longer than any run of backticks in the content.
def fence_for: ([scan("`+")] | map(length) | max // 0) as $m | ("`" * ([$m + 1, 3] | max));

def lang_for_file:
  str | ascii_downcase as $p
  | (($p | split("/") | last) // "") as $base
  | ($base | if test("\\.") then (split(".") | last // "") else "" end) as $ext
  | ({
      sol: "solidity", vy: "vyper", cairo: "cairo", move: "move", rs: "rust", go: "go", py: "python",
      js: "javascript", mjs: "javascript", cjs: "javascript", jsx: "jsx", ts: "typescript", tsx: "tsx",
      java: "java", kt: "kotlin", kts: "kotlin", swift: "swift", c: "c", h: "c", cpp: "cpp", cc: "cpp",
      cxx: "cpp", hpp: "cpp", cs: "csharp", rb: "ruby", php: "php", sh: "bash", bash: "bash", zsh: "zsh",
      yml: "yaml", yaml: "yaml", json: "json", toml: "toml", sql: "sql", scala: "scala", ex: "elixir",
      exs: "elixir", erl: "erlang", hs: "haskell", ml: "ocaml", lua: "lua", dart: "dart", zig: "zig",
      nim: "nim", r: "r", m: "objectivec", pl: "perl", tf: "hcl", proto: "protobuf", graphql: "graphql",
      html: "html", css: "css", scss: "scss", md: "markdown", xml: "xml", vue: "vue", svelte: "svelte",
      wasm: "wasm", wat: "wast", asm: "asm", s: "asm", ps1: "powershell", groovy: "groovy", clj: "clojure"
    }[$ext]) as $lang
  | if $lang != null then $lang
    elif $base == "dockerfile" then "dockerfile"
    elif $base == "makefile" then "makefile"
    else "" end;

def truncate_chars($n): str | if length > $n then .[0:$n] + "…" else . end;

def blob_url($server; $repo; $sha):
  primary_location as $l
  | if ($l.file | length) == 0 or ($sha | length) == 0 then null
    else "\($server)/\($repo)/blob/\($sha)/\($l.file | split("/") | map(@uri) | join("/"))"
      + (if $l.startLine != null then "#L\($l.startLine)" + (if $l.endLine != null and $l.endLine != $l.startLine then "-L\($l.endLine)" else "" end) else "" end)
    end;

# ---------------------------------------------------------------------------
# SARIF helpers
# ---------------------------------------------------------------------------

def sarif_level: if . == "critical" or . == "high" then "error" elif . == "medium" then "warning" else "note" end;
def security_severity: {critical: "9.5", high: "8.0", medium: "5.5", low: "2.5", info: "1.0"}[.];

# ---------------------------------------------------------------------------
# Comment state block (base64 JSON inside an HTML comment)
# ---------------------------------------------------------------------------

def state_marker($key): "<!-- v12-audit-action:\($key) -->";
def state_encode: tojson | @base64;
def state_block: "<!-- v12-audit-action:state:" + state_encode + " -->";
def state_decode:
  # Input: full comment body. Output: decoded state object or null.
  (capture("<!-- v12-audit-action:state:(?<b>[A-Za-z0-9+/=]+) -->") | .b) as $b
  | if $b == null then null else (try ($b | @base64d | fromjson) catch null) end;
