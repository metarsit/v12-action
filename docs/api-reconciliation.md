# V12 API reconciliation (Phase 1)

Status: **blocked on review.** No action code has been written. This document
records what could be verified about the V12 API and GitHub platform limits
from inside the build environment, where the reconciliation disagrees with the
brief, the proposed SARIF fingerprint scheme, and the decisions that need an
answer before Phase 2.

## 0. What could and could not be verified

The build sandbox's egress policy blocks `v12.sh`, `docs.github.com` and
`web.archive.org`. The OpenAPI document and the four docs pages named in the
brief were therefore unreachable. The reconciliation below uses the next best
sources, all fetched live:

| Source | Reachable | Used for |
|---|---|---|
| `https://v12.sh/api/v1/openapi.json` | no (proxy 403) | — |
| `https://v12.sh/docs/{public-api,rest,cli,using-auto-review}` | no | — |
| `@v12sh/cli` 0.3.37 from `registry.npmjs.org` (published 2026-08-31, maintained by Zellic) | yes | request bodies, response keys, client-side validation rules, vocabulary, README |
| `github/rest-api-description` (raw.githubusercontent.com) | yes | check-run and annotation caps, SARIF upload limits, comment API |
| `github/docs` source (raw.githubusercontent.com) | yes | SARIF support and fingerprint rules, job-summary limit, fork secrets, composite-action rules, Marketplace icon list |
| `github/codeql-action/src/fingerprints.ts` | yes | GitHub's own `primaryLocationLineHash` algorithm |
| Web search (GitHub community discussion #27190) | yes | 65,536-character comment cap |

The CLI is the vendor's own client and exercises every endpoint this action
uses, so where it reads or writes a key that key is real. It is still not the
spec: it proves only the keys it touches. Everything it does not touch is
listed in §3 as unverified.

## 1. Confirmed by the official CLI (matches the brief)

| Item | Evidence in `@v12sh/cli` 0.3.37 |
|---|---|
| Base URL `https://v12.sh`, paths `/api/v1/...`, `Authorization: Bearer`, JSON bodies, `Accept: application/json` | request helper; `V12_API_URL` and `V12_API_TOKEN` override |
| Estimate request `POST /api/v1/runs/estimate` body `{source, repoFullName, branch?, sha?, paths?, diffReviewConfig?}` — no `name`, no context documents | `b2()` posts the same object `P2()` builds for create |
| Estimate response `{estimate, scope[], resolved}` | `_2()` destructures exactly these |
| `estimate.priceCents` when `billingMode` is not `usage`; `estimate.estimatedPriceCents` when it is | `UF()`: `billingMode==="usage" ? estimatedPriceCents : priceCents` |
| `estimate.billableFileCount`, `billableBytes`, `billableLoc`, `billableChangedLines` | printed by `_2()` |
| `scope[]` items `{path, bytes, loc}`; `bytes` and `loc` may be null | scope table guards `== null` |
| `resolved` carries `repoFullName` or `zipUid`, `branch`, `sha`, `fromRef`, `toRef`, `patchUid`, `resolvedFromSha`, `resolvedToSha` | `p3()` and the create handler |
| Create `POST /api/v1/runs` body = estimate body + `name` (required) + `contextDocumentUids?` | create builder, `demandOption` on `--name` |
| Create response is **nested**: `{run: {...}, estimate: {...}}` | `S2($.run)` and `$.estimate.billingMode` |
| `GET /api/v1/runs/{uid}` is **nested**: `{run: {...}}` | `let {run} = await get(...)` in both `get` and `watch` |
| `GET /api/v1/runs` → `{runs[], totalMatching, offset}` with `limit`/`offset` | runs list handler |
| Run fields: `uid, name, state, statusMessage, repo, branch, sha, createdAt, startedAt, endedAt, webUrl` | `S2()` |
| Terminal states `completed`, `failed`, `cancelled`; watch exits 0 only on `completed` | `o3` set |
| Findings list `GET /api/v1/runs/{uid}/findings?severity=&validity=&limit=&offset=`; `severity` and `validity` repeatable as repeated query keys | list handler; helper appends arrays as repeated params |
| Findings list response key is **`findings`**, with `totalMatching` and echoed `offset` | `F.findings.map(...)`, `Gu(F.findings.length, F.totalMatching, F.offset)` |
| Finding fields: `uid, title, severity, validity, autoInvalidated, webUrl, description, impact, rootCause` | `K2()`, `U2()` |
| Severity `critical, high, medium, low, info, qa`; validity `valid, invalid, unreviewed, acknowledged` | `VF`, `RF` choice lists |
| Finding `webUrl` is `https://v12.sh/runs/{runUid}/{findingUid}`; findings are addressed by `findingUid` | README `findings get 42 7` |
| Cancel `POST .../cancel` → `{cancellationPending}` | cancel handler |
| Report `GET .../report` with `Accept: text/markdown` returns text, otherwise JSON | report handler |
| `/me` → `{email, githubUsername, orgName, orgKind, creditBalanceCents, tokenKind, scopes[]}` | `me` handler |
| Diff rules: GitHub target needs `fromRef` plus exactly one of `toRef`, `patchContent`, `patchUid`; zip target takes `patchContent` or `patchUid` and no refs; `branch`/`sha` cannot combine with diff options | `w2().check()` error messages |
| Estimate-then-pin: `resolved.sha` → `sha` (full audit); `resolvedFromSha` → `fromRef`; `resolvedToSha` → `toRef`; `resolved.patchUid` replaces `patchContent` | create handler |
| SHAs are accepted as `fromRef`/`toRef` | the pinned create sends SHAs in those fields |
| `paths` reaches both estimate and create | one body object is reused |
| Zip flow: `POST /api/v1/zips` → `{zipUid, uploadUrl}`; `PUT` raw bytes with `Content-Type: application/zip` | `x3()` |
| Error body is `{message: string}` or `{error: string}` | `h3()` accepts either |
| Token page: `https://v12.sh/settings`; "API tokens are scoped to your user and org; create one under the org you want to work in" | login prompt |
| Polling cadence: 15 s | `--interval` default |

## 2. Differences from the brief

1. **`contextDocumentUids` are UUID strings, not integers.** The CLI validates
   `--context-doc` against a UUID regex and caps a run at 100 documents
   ("A run can attach at most 100 context documents"; the README adds that the
   API "returns a validation error if too many context documents are
   attached"). §2's `[12]` and §5's `context-documents: [12, 47]` are wrong.
   The schema will be an array of UUID strings, `maxItems: 100`.
2. **"`sha` without `branch` returns 400" is contradicted by the CLI's own pin
   path.** When `--branch` is omitted, `runs create --repo o/r` sends
   `sha: resolved.sha` with no `branch`. Either the rule is narrower than
   stated or the CLI's default path is broken. This action will always send
   `branch` alongside `sha`, which side-steps the question, but see Q2(e).
3. **The run object has `endedAt` (not `completedAt`), `statusMessage`, and a
   string `repo`.** `statusMessage` will be logged in the progress lines.
   Duration = `endedAt − startedAt`.
4. **`POST /runs` returns an `estimate` next to `run`.** Not in §2. It is the
   quote at creation time and will be recorded as `estimate-cents`.
5. **`/me` exposes `scopes` and `orgName`.** Not in §2. This enables a scope
   preflight before any estimate call: a token without `runs:write` fails in
   one read with a message naming the scope and the bound org, instead of a
   403 after the estimate.
6. **`hasMore` is never read by the CLI.** It paginates on
   `offset + page.length < totalMatching`. This action will do the same and
   never depend on `hasMore` or on the server's default page size.
7. **`cost` on the run object is never read by the CLI.** Name and units are
   unverified (§2 says USD; the `cost-cents` output multiplies by 100, which
   is 100× wrong if the field is already cents).
8. **`sourceLocations`, `sourceUrls`, `commentCount`, `createdAt`, `runUid` are
   never read by the CLI.** `sourceLocations` is the field every inline
   surface depends on. §2 says it is always present; the code will treat a
   missing or empty array as "no location" and degrade (comment row without a
   source link, SARIF anchored at the repo root, no annotation).
9. `PATCH` findings takes `{severity, validity, userReason}` and comments take
   `{content}`. Not needed in v1, recorded for the future-work note.
10. `patchUid` is a UUID string; `zipUid` is a number.

## 3. Still unverified (taken from the brief on trust)

- Rate-limit buckets, limits, windows and `Retry-After` on 429. The CLI has no
  retry logic at all.
- 401 versus 403 semantics, the default scopes of a new token, org binding.
- Findings list: whether list items carry the full detail shape
  (`description`, `impact`, `rootCause`, `sourceLocations`) or only a summary.
  **This changes the architecture** (see Q2(a)): if the list is summary-only,
  every finding needs a detail call in the `reads:artifact` bucket (300/min).
- Findings list: maximum `limit`, default page size.
- Run: `cost` name and units; whether `GET /runs/{uid}` also carries `estimate`.
- Cancel: the `cancelled` boolean.
- Status codes: 400 for `sha` without `branch`; 404 for missing PoC/fix; 409
  on a second comment.
- Whether `branch` accepts a tag name or any ref (needed for release gates).
- Whether `fromRef..toRef` is a two-dot diff or a merge-base diff on V12's
  side (see Q2(d)).
- Public-repo-without-app and private-repo installation behaviour.
- Anything about Autopilot: `/docs/using-auto-review` was unreachable, so the
  README's Autopilot section will be written from §2 alone.

## 4. GitHub platform limits (verified)

| Surface | Limit | On overflow | Source |
|---|---|---|---|
| Issue / PR comment body | 65,536 characters | 422 "body is too long" | community discussion #27190 |
| Check run `output.summary`, `output.text` | 65,535 characters each | request rejected | rest-api-description `maxLength` |
| Check run annotations | 50 per request, more by appending through "update a check run"; `title` ≤ 255 chars; `message`, `raw_details` ≤ 64 KB; levels `notice`, `warning`, `failure` | request rejected above 50 | rest-api-description |
| `::warning` / `::error` workflow commands | 10 warnings and 10 errors per step | extra ones dropped | rest-api-description note |
| Job summary | 1 MiB per step, 20 step summaries shown per job | that step's upload fails with an error annotation; job status unaffected | github/docs `workflow-commands.md` |
| SARIF file | 10 MB gzip-compressed | rejected | github/docs `sarif-support.md` |
| SARIF objects | 20 runs/file; 25,000 results/run (top 5,000 shown, by severity); 25,000 rules/run; 1,000 locations/result (100 shown); 20 tags/rule (10 shown); 100 tool extensions/run; 1,000,000 alerts | exceeding a maximum rejects the whole file | github/docs `sarif-limits` reusable |
| SARIF rule text | `name` ≤ 255; `shortDescription.text`, `fullDescription.text` ≤ 1024 | — | `sarif-support.md` |
| SARIF dedup | only `partialFingerprints.primaryLocationLineHash` is used; `ruleId` must be stable across analyses; `upload-sarif` computes the hash from the checkout when absent | duplicates | `sarif-support.md` |
| `properties.security-severity` | over 9.0 critical; 7.0–8.9 high; 4.0–6.9 medium; 0.1–3.9 low; 0.0 or out of range → no security severity | — | `sarif-support.md` |
| Fork pull requests | only `GITHUB_TOKEN` is passed; all other secrets are absent; `GITHUB_TOKEN` is read-only | — | github/docs `forked-secrets` reusable |
| Composite actions | inputs are not exposed as `INPUT_*`; use the `inputs` context | — | github/docs `metadata-syntax.md` |
| Marketplace branding | `shield` is on the supported Feather icon list | — | `metadata-syntax.md` |

Design budgets derived from these: comment body ≤ 60,000 characters including
the hidden state block; check-run summary ≤ 60,000; annotations posted in
batches of 50 up to a configurable total (default 200); job summary ≤ 512 KiB;
SARIF capped at 5,000 results (GitHub's display limit) dropping lowest severity
first, then verified below 9 MB gzip before upload.

## 5. Proposed SARIF fingerprint scheme

GitHub dedups on `partialFingerprints.primaryLocationLineHash` only, so the
custom fingerprint must be emitted under that exact key. GitHub's own value is
a rolling hash of the 100 non-whitespace characters starting at the primary
line (codeql-action `fingerprints.ts`); it survives line drift but changes
whenever the code at the location is edited. The proposed scheme has the same
property, works without the checkout, and is human-copyable.

```
norm_path    = sourceLocations[0].file, "./" prefix stripped, "\" → "/"
norm_title   = title lowercased, split on non-alphanumerics, stop-words
               (a, an, the, in, of, on, to, is, for, with, via, by) removed,
               remaining tokens sorted and de-duplicated, joined with " "
snippet_dig  = sha256(sourceLocations[0].snippet with all whitespace removed)[0:8]
               ("" when there is no snippet)

fp           = sha256("v12-fp-v1\n" + norm_path + "\n" + norm_title + "\n" + snippet_dig)[0:16]
rule_id      = "v12/" + severity + "/" + slug(norm_title)[0:48] + "-" + sha256(norm_title)[0:6]

partialFingerprints = { "primaryLocationLineHash": fp + ":" + n,   # n = 1-based counter for repeats of fp within one run
                        "v12/fingerprint": fp }
```

- `fp` (16 hex) is the single identity used everywhere: the delta in the PR
  comment, `suppressions[].fingerprint` in the config file, the job summary,
  and the SARIF fingerprint. It is printed in each finding's details block so
  it can be copied into a suppression. §5's 8-character example becomes 16.
- Severity is deliberately outside `fp` and inside `rule_id`: a re-rated
  finding stays "unchanged" in the PR delta, while GitHub (whose
  `security-severity` is a rule property) gets a new rule and closes the old
  alert. Each rule carries `properties.security-severity`:
  critical 9.5, high 8.0, medium 5.5, low 2.5, info 1.0; `qa` gets no
  security severity and `level: note`.
- Line numbers are excluded, so pure drift keeps the identity.
- Trade-offs to accept: editing the vulnerable snippet re-opens the alert
  (same as GitHub's own hash); a finding with no location hashes on the title
  alone and relies on the `:n` suffix; and because V12 titles are generated,
  a reworded title for the same issue will produce a new identity. The token
  sort makes reorderings match but not synonyms. Dropping the title from `fp`
  would fix that at the cost of conflating distinct findings at one location.

## 6. Things in the brief that look wrong, or need a decision

1. **§3 conflicts with §7.** The suggested invocation
   `bash "${{ github.action_path }}/scripts/x.sh"` is a `${{ }}` inside a
   `run:` body, which §7 forbids and §9's lint must reject. Resolution: every
   step sets `env: V12_ACTION_PATH: ${{ github.action_path }}` and runs
   `bash "$V12_ACTION_PATH/scripts/x.sh"`. The lint rule stays absolute.
2. **Context document UIDs** are UUID strings (above).
3. **Fingerprint placement**: the scheme is only effective under
   `primaryLocationLineHash` (above).
4. **Merge-base, not base tip.** On `pull_request`, `base.sha` is the tip of
   the base branch, not the fork point. `fromRef = base.sha` would review
   base-branch changes in reverse for any stale PR. The action will compute
   `git merge-base base head` locally and send that as `fromRef`, deepening a
   shallow clone with a warning. Whether V12 itself applies merge-base
   semantics to `fromRef..toRef` is unknown (Q2(d)).
5. **`merge_group` cannot get a sticky comment** in a sane way: the event
   has no pull request object, and the audited commit is the queue's merge
   commit, not the PR head. Proposed: check run, job summary and SARIF only,
   with the diff `merge_group.base_sha..head_sha`.
6. **"Repos without the app installed" only holds for public repos** in v1,
   because `source: "github"` needs V12 to read the repo and the zip source is
   out of scope. The README will say so explicitly.
7. **Empty-diff detection** uses two checks: `git diff --quiet from..to --
   <paths>` after include/exclude globs (free), then
   `billableChangedLines == 0` on a usage-billed estimate (one estimate call,
   no run). Both skip with `skipped-reason=empty-diff`.
8. **Time windows** resolve with git's own date parser
   (`git rev-list -1 --before=<since> <branch>`), which removes the BSD/GNU
   `date` divergence entirely. No `date -d` anywhere.
9. **Bash 3.2**: the scripts will be written to the 3.2 floor and tested on
   `macos-latest`. All structured data lives in jq; hashing uses `openssl dgst
   -sha256` (`sha256sum` does not exist on macOS); no `sed -i`, `grep -P`,
   `readlink -f`, `mapfile`, `${var,,}` or associative arrays.
10. **`cost-cents`** will assume `run.cost` is USD as §2 states. If the field
    is absent the footer prints "n/a" with a warning; a missing cost never
    fails the job. Q2(b) should settle the units before this ships.
11. **`qa` findings** are not security findings. Proposed input
    `min-severity` (default `info`) applied to every surface: `qa` is hidden
    unless a team asks for it, and appears in SARIF as a plain `note`.
12. **Cancellation** gets two mechanisms, because a bash trap only fires if
    the runner delivers the signal in time: a `trap` in the wait script and a
    composite step with `if: cancelled()` that posts the cancel when a run
    UID exists. Both poll briefly while `cancellationPending` is true.
13. **Rate-limit messaging** must name both hourly buckets: a matrix of more
    than 20 repos hits `runs:write`, and more than 30 hits `runs:estimate`
    (each run costs one of each, and the estimate-only smoke test spends from
    the same per-user bucket).
14. **Action name.** The brief says `uses: <owner>/v12-audit-action@v1`; this
    repository is `metarsit/v12-action`. Examples and docs will use the real
    path, `metarsit/v12-action@v1`. The config file stays
    `.github/v12-audit.yml` and the comment marker `v12-audit-action`.
15. **Detail fan-out.** If list items are summary-only (Q2(a)), rendering
    needs one detail call per finding in the 300/min `reads:artifact`
    bucket. Proposed: fetch details for the first `max-findings-detail`
    findings (default 200) in severity order, paced under the bucket, and
    list the rest by title with their `webUrl`.

## 7. Questions (with the default I will assume if unanswered)

- **Q1. Network.** Allow `v12.sh` in this environment's network policy, or
  drop `openapi.json` into `test/fixtures/openapi.json`. Default: proceed on
  the CLI-derived shapes above and add a CI test that, whenever that fixture
  exists, asserts every key this action depends on is present in the spec.
- **Q2. From the spec, please confirm:** (a) whether findings-list items carry
  `description`, `impact`, `rootCause` and `sourceLocations`, or only the
  detail endpoint does; (b) the run object's realized-cost field name and
  units; (c) the maximum `limit` on the findings list; (d) whether
  `fromRef..toRef` is a plain two-dot diff or merge-base based; (e) whether
  `branch` accepts a tag name and whether `sha` without `branch` really
  returns 400. Defaults: (a) detail per finding with the fan-out in §6.15,
  (b) `cost` in USD, (c) request `limit=100` and follow `totalMatching`,
  (d) send the merge-base SHA as `fromRef`, (e) always send both `branch`
  and `sha`, using the tag name as `branch` on tag builds.
- **Q3. Fingerprint scheme** as in §5. Default: implement as written.
- **Q4. Bash 3.2 floor** rather than declaring macOS unsupported. Default: yes.
- **Q5. `qa` hidden by default** through `min-severity: info`. Default: yes.
- **Q6. `merge_group` without a sticky comment.** Default: yes.
- **Q7. Action path** `metarsit/v12-action@v1` in all examples. Default: yes.
