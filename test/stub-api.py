#!/usr/bin/env python3
"""Offline stand-in for the V12 public REST API (https://v12.sh/api/v1).

Shapes follow docs/api-reconciliation.md: the @v12sh/cli client is the
reference for every key this stub emits. Behaviour is selected by the bearer
token and by the repoFullName in the request body, so one server instance
serves every test scenario. Every request is appended to --log as JSON lines
so tests can assert on what the action actually sent.

Tokens
  v12p_ok         normal account with runs:read + runs:write + runs:manage
  v12p_readonly   default scopes only: 403 on POST /runs, /zips, cancel
  v12p_bad        401 everywhere
  v12p_ratelimit  first request per (method, path) -> 429 Retry-After: 1
  v12p_flaky      first request per (method, path) -> 500
  v12p_retryafter first request per path -> 429 Retry-After: 999 (over the cap)

repoFullName
  acme/vault         run 42: queued -> running -> completed, 25 fixture findings
  acme/failing       run 43: fails, report 404, no findings
  acme/cancelling    run 44: runs until cancelled (cancellationPending: true)
  acme/slow          run 45: never finishes (timeout tests)
  acme/summary-list  run 46: findings list is summary-only; details per finding
  acme/nocost        run 47: completed run without a cost field
  acme/many          run 48: 300 generated findings
  acme/clean         run 49: completes with no findings

Slack (under /slack/): bot token xoxb-good works; channel C-missing ->
channel_not_found, C-notin -> not_in_channel; chat.update succeeds only
for ts 1700000000.000100; /slack/webhook/<anything> returns ok,
/slack/webhook/bad returns 404.
  acme/empty         estimate with billableChangedLines 0 (diff) / 0 files (full)
  acme/pricey        estimate priceCents 999900
  acme/badshape      estimate returns an unexpected shape
  acme/reject        estimate returns 400 with a message
"""

import argparse
import copy
import json
import os
import re
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

HERE = os.path.dirname(os.path.abspath(__file__))
FIXTURES = os.path.join(HERE, "fixtures")
UUID_RE = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
FROM_SHA = "2222222222222222222222222222222222222222"
TO_SHA = "1111111111111111111111111111111111111111"
FULL_SHA = "3333333333333333333333333333333333333333"
SEVERITIES = ["critical", "high", "medium", "low", "info", "qa"]
VALIDITIES = ["valid", "invalid", "unreviewed", "acknowledged"]

RUN_BY_REPO = {
    "acme/vault": 42,
    "acme/failing": 43,
    "acme/cancelling": 44,
    "acme/slow": 45,
    "acme/summary-list": 46,
    "acme/nocost": 47,
    "acme/many": 48,
    "acme/clean": 49,
}

SCOPES_FULL = ["runs:read", "runs:write", "runs:manage", "findings:write", "user:read", "repos:read"]
SCOPES_RO = ["runs:read", "user:read", "repos:read"]


def load_findings():
    with open(os.path.join(FIXTURES, "findings-run-42.json"), encoding="utf-8") as f:
        return json.load(f)


def generated_findings(run_uid, count):
    out = []
    for i in range(count):
        sev = SEVERITIES[i % len(SEVERITIES)]
        val = VALIDITIES[(i // 3) % len(VALIDITIES)]
        uid = 1000 + i
        out.append({
            "uid": uid, "runUid": run_uid,
            "title": "Generated finding %d (%s)" % (i, sev),
            "severity": sev, "validity": val, "autoInvalidated": (i % 7 == 0),
            "description": "Generated description %d." % i, "impact": "Generated impact.", "rootCause": "Generated root cause.",
            "commentCount": 0, "createdAt": "2026-04-26T18:20:%02d.000Z" % (i % 60),
            "sourceLocations": [{"file": "src/gen/file%d.sol" % (i % 40), "startLine": 10 + i, "endLine": 12 + i, "note": "", "snippet": "x = %d;" % i}],
            "webUrl": "https://v12.sh/runs/%d/%d" % (run_uid, uid),
        })
    return out


class State:
    lock = threading.Lock()
    runs = {}          # uid -> run object
    polls = {}         # uid -> number of GET /runs/{uid}
    cancel_at = {}     # uid -> poll count when cancel was requested
    hits = {}          # (token, method, path) -> count
    log_path = None
    findings = {}      # uid -> list

    @classmethod
    def log(cls, entry):
        if not cls.log_path:
            return
        with cls.lock:
            with open(cls.log_path, "a", encoding="utf-8") as f:
                f.write(json.dumps(entry) + "\n")


class Handler(BaseHTTPRequestHandler):
    server_version = "v12-stub/1.0"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # quiet
        if os.environ.get("STUB_VERBOSE"):
            sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    # -- helpers -----------------------------------------------------------
    def _send(self, status, body=None, headers=None, raw=None, content_type="application/json"):
        data = raw if raw is not None else (json.dumps(body).encode("utf-8") if body is not None else b"")
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if data:
            self.wfile.write(data)

    def _error(self, status, message, headers=None):
        self._send(status, {"message": message}, headers)

    def _read_body(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        if not raw:
            return None, None
        try:
            return json.loads(raw.decode("utf-8")), raw
        except ValueError:
            return "INVALID", raw

    def _auth(self):
        auth = self.headers.get("Authorization") or ""
        if not auth.startswith("Bearer "):
            return None
        return auth[len("Bearer "):].strip()

    def _first_hit(self, token, path):
        key = (token, self.command, path)
        with State.lock:
            State.hits[key] = State.hits.get(key, 0) + 1
            return State.hits[key] == 1

    def _dispatch(self):
        url = urlparse(self.path)
        path = url.path
        query = parse_qs(url.query)
        body, raw = self._read_body()
        token = self._auth()
        State.log({
            "method": self.command, "path": path, "query": query,
            "headers": {k: v for k, v in self.headers.items() if k.lower() != "authorization"},
            "token": token, "body": body,
        })
        if path.startswith("/slack/"):
            return self._slack(path, body, token)
        if token is None or token not in ("v12p_ok", "v12p_readonly", "v12p_ratelimit", "v12p_flaky", "v12p_retryafter"):
            return self._error(401, "invalid or missing token")
        if token == "v12p_ratelimit" and self._first_hit(token, path):
            return self._error(429, "rate limit exceeded for bucket", {"Retry-After": "1"})
        if token == "v12p_retryafter" and self._first_hit(token, path):
            return self._error(429, "rate limit exceeded for bucket runs:write", {"Retry-After": "999"})
        if token == "v12p_flaky" and self._first_hit(token, path):
            return self._error(500, "internal error")
        if body == "INVALID":
            return self._error(400, "request body is not valid JSON")
        if not path.startswith("/api/v1/"):
            return self._error(404, "not found")
        rest = path[len("/api/v1/"):]
        parts = [p for p in rest.split("/") if p]
        readonly = token == "v12p_readonly"

        if parts == ["me"] and self.command == "GET":
            return self._send(200, {
                "email": "ci@acme.example", "githubUsername": "acme-ci", "orgName": "Acme", "orgKind": "team",
                "creditBalanceCents": 250000, "tokenKind": "pat", "scopes": SCOPES_RO if readonly else SCOPES_FULL,
            })
        if parts == ["runs", "estimate"] and self.command == "POST":
            return self._estimate(body)
        if parts == ["runs"] and self.command == "POST":
            if readonly:
                return self._error(403, "token is missing scope runs:write")
            return self._create(body)
        if parts == ["zips"] and self.command == "POST":
            if readonly:
                return self._error(403, "token is missing scope runs:write")
            return self._send(200, {"zipUid": 87, "uploadUrl": "http://127.0.0.1:1/upload"})
        if len(parts) >= 2 and parts[0] == "runs" and parts[1].isdigit():
            uid = int(parts[1])
            run = State.runs.get(uid)
            if run is None:
                return self._error(404, "run %d not found" % uid)
            if len(parts) == 2 and self.command == "GET":
                return self._get_run(uid)
            if parts[2:] == ["cancel"] and self.command == "POST":
                if readonly:
                    return self._error(403, "token is missing scope runs:manage")
                return self._cancel(uid)
            if parts[2:] == ["report"] and self.command == "GET":
                return self._report(uid)
            if parts[2:] == ["findings"] and self.command == "GET":
                return self._findings(uid, query)
            if len(parts) == 4 and parts[2] == "findings" and parts[3].isdigit() and self.command == "GET":
                return self._finding(uid, int(parts[3]))
        return self._error(404, "not found")

    # -- validation shared by estimate and create --------------------------
    def _validate(self, body, create):
        if not isinstance(body, dict):
            return "request body must be a JSON object"
        if body.get("source") != "github":
            return "source must be 'github' (zip is not exercised by this stub)"
        if bool(body.get("repoFullName")) == bool(body.get("repoUid")):
            return "exactly one of repoFullName or repoUid is required"
        paths = body.get("paths")
        if paths is not None:
            if not isinstance(paths, list) or any(not isinstance(p, str) for p in paths):
                return "paths must be an array of strings"
            if len(paths) > 500:
                return "paths may contain at most 500 entries"
        drc = body.get("diffReviewConfig")
        if drc is not None:
            if body.get("branch") or body.get("sha"):
                return "branch and sha cannot be combined with diffReviewConfig"
            if not isinstance(drc, dict) or not drc.get("fromRef"):
                return "diffReviewConfig.fromRef is required for GitHub targets"
            n = sum(1 for k in ("toRef", "patchContent", "patchUid") if drc.get(k))
            if n != 1:
                return "diffReviewConfig needs exactly one of toRef, patchContent, patchUid"
        else:
            if body.get("sha") and not body.get("branch"):
                return "sha requires branch"
        if create:
            if not body.get("name") or not isinstance(body.get("name"), str):
                return "name is required"
            ctx = body.get("contextDocumentUids")
            if ctx is not None:
                if not isinstance(ctx, list) or any(not (isinstance(c, str) and UUID_RE.match(c)) for c in ctx):
                    return "contextDocumentUids must be an array of context document UIDs"
                if len(ctx) > 100:
                    return "a run can attach at most 100 context documents"
        return None

    def _estimate_payload(self, body):
        repo = body.get("repoFullName") or "acme/vault"
        drc = body.get("diffReviewConfig")
        paths = body.get("paths") or []
        scope = [
            {"path": "contracts/Vault.sol", "loc": 812, "bytes": 24918},
            {"path": "contracts/Permit.sol", "loc": 120, "bytes": 3900},
            {"path": "src/crypto/sign.rs", "loc": 210, "bytes": 6400},
        ]
        if paths:
            scope = [s for s in scope if any(s["path"].startswith(p.rstrip("/") + "/") or s["path"] == p for p in paths)] or scope[:1]
        if drc:
            changed = 0 if repo == "acme/empty" else 37
            est = {"billingMode": "usage", "billableFileCount": len(scope), "billableBytes": sum(s["bytes"] for s in scope),
                   "billableChangedLines": changed, "billableLoc": sum(s["loc"] for s in scope), "estimatedPriceCents": 1250}
            resolved = {"repoFullName": repo, "fromRef": drc.get("fromRef"), "toRef": drc.get("toRef"),
                        "resolvedFromSha": FROM_SHA, "resolvedToSha": TO_SHA}
        else:
            price = 999900 if repo == "acme/pricey" else 9900
            if repo == "acme/empty":
                scope = []
                price = 0
            est = {"billingMode": "fixed", "billableFileCount": len(scope), "billableBytes": sum(s["bytes"] for s in scope),
                   "billableChangedLines": 0, "billableLoc": sum(s["loc"] for s in scope), "priceCents": price}
            resolved = {"repoFullName": repo, "branch": body.get("branch"), "sha": body.get("sha") or FULL_SHA}
        return {"estimate": est, "scope": scope, "resolved": resolved}

    def _estimate(self, body):
        err = self._validate(body, create=False)
        if err:
            return self._error(400, err)
        repo = body.get("repoFullName")
        if repo == "acme/badshape":
            return self._send(200, {"quote": {"cents": 1}})
        if repo == "acme/reject":
            return self._error(400, "repository acme/reject is not accessible to this organization")
        return self._send(200, self._estimate_payload(body))

    def _create(self, body):
        err = self._validate(body, create=True)
        if err:
            return self._error(400, err)
        repo = body.get("repoFullName")
        if repo == "acme/reject":
            return self._error(400, "repository acme/reject is not accessible to this organization")
        uid = RUN_BY_REPO.get(repo, 42)
        drc = body.get("diffReviewConfig")
        now = time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime())
        run = {
            "uid": uid, "name": body.get("name"), "state": "queued", "statusMessage": "Waiting for a worker",
            "repo": repo, "branch": body.get("branch") if not drc else None, "sha": body.get("sha") if not drc else None,
            "createdAt": now, "startedAt": None, "endedAt": None, "webUrl": "https://v12.sh/runs/%d" % uid, "cost": 0,
        }
        with State.lock:
            State.runs[uid] = run
            State.polls[uid] = 0
            State.cancel_at.pop(uid, None)
            if uid in (42, 46):
                State.findings[uid] = load_findings()
                for f in State.findings[uid]:
                    f["runUid"] = uid
                    f["webUrl"] = "https://v12.sh/runs/%d/%d" % (uid, f["uid"])
            elif uid == 48:
                State.findings[uid] = generated_findings(uid, 300)
            elif uid == 47:
                State.findings[uid] = load_findings()[:3]
            else:
                State.findings[uid] = []
        return self._send(201, {"run": copy.deepcopy(run), "estimate": self._estimate_payload(body)["estimate"]})

    def _advance(self, uid):
        """Move the run state machine one poll forward. Called under lock."""
        run = State.runs[uid]
        State.polls[uid] += 1
        n = State.polls[uid]
        cancelled_at = State.cancel_at.get(uid)
        if run["state"] in ("completed", "failed", "cancelled"):
            return
        if cancelled_at is not None:
            if n >= cancelled_at + 2:
                run["state"] = "cancelled"
                run["statusMessage"] = "Cancelled by user"
                run["endedAt"] = "2026-04-26T18:30:00.000Z"
                run["cost"] = 3.5
            else:
                run["state"] = "running"
                run["statusMessage"] = "Cancelling, persisting usage"
            return
        if uid == 45:
            run["state"] = "running"
            run["statusMessage"] = "Analyzing (this run never finishes)"
            run["startedAt"] = "2026-04-26T18:15:00.000Z"
            return
        if uid == 44:
            run["state"] = "running"
            run["statusMessage"] = "Analyzing"
            run["startedAt"] = "2026-04-26T18:15:00.000Z"
            return
        if n == 1:
            run["state"] = "queued"
            run["statusMessage"] = "Waiting for a worker"
        elif n == 2:
            run["state"] = "running"
            run["statusMessage"] = "Analyzing 3 files"
            run["startedAt"] = "2026-04-26T18:15:00.000Z"
        else:
            run["startedAt"] = run["startedAt"] or "2026-04-26T18:15:00.000Z"
            run["endedAt"] = "2026-04-26T18:27:30.000Z"
            if uid == 43:
                run["state"] = "failed"
                run["statusMessage"] = "Worker crashed while cloning the repository"
                run["cost"] = 0
            else:
                run["state"] = "completed"
                run["statusMessage"] = "Completed"
                run["cost"] = 12.5 if uid != 47 else None
                if uid == 47:
                    del run["cost"]

    def _get_run(self, uid):
        with State.lock:
            self._advance(uid)
            run = copy.deepcopy(State.runs[uid])
        return self._send(200, {"run": run})

    def _cancel(self, uid):
        with State.lock:
            run = State.runs[uid]
            if run["state"] in ("completed", "failed", "cancelled"):
                return self._send(200, {"cancelled": False, "cancellationPending": False})
            if uid == 44 and run["state"] == "running":
                State.cancel_at[uid] = State.polls[uid]
                return self._send(200, {"cancelled": False, "cancellationPending": True})
            run["state"] = "cancelled"
            run["statusMessage"] = "Cancelled by user"
            run["endedAt"] = "2026-04-26T18:16:00.000Z"
            return self._send(200, {"cancelled": True, "cancellationPending": False})

    def _report(self, uid):
        if uid == 43 or State.runs[uid]["state"] != "completed":
            return self._error(404, "no report for run %d" % uid)
        accept = self.headers.get("Accept") or ""
        if "text/markdown" in accept:
            return self._send(200, raw=("# V12 report for run %d\n\nStub report.\n" % uid).encode("utf-8"), content_type="text/markdown; charset=utf-8")
        return self._send(200, {"runUid": uid, "summary": "Stub report."})

    def _findings(self, uid, query):
        with State.lock:
            items = copy.deepcopy(State.findings.get(uid, []))
        sev = query.get("severity") or []
        val = query.get("validity") or []
        if sev:
            items = [f for f in items if f["severity"] in sev]
        if val:
            items = [f for f in items if f["validity"] in val]
        try:
            limit = max(1, min(100, int((query.get("limit") or ["10"])[0])))
            offset = max(0, int((query.get("offset") or ["0"])[0]))
        except ValueError:
            return self._error(400, "limit and offset must be integers")
        page = items[offset:offset + limit]
        if uid == 46:
            page = [{k: f[k] for k in ("uid", "runUid", "title", "severity", "validity", "autoInvalidated", "webUrl")} for f in page]
        return self._send(200, {"findings": page, "totalMatching": len(items), "hasMore": offset + len(page) < len(items),
                                "limit": limit, "offset": offset})

    # -- Slack stand-in (bot token API + incoming webhook) --------------------
    def _slack(self, path, body, token):
        if path.startswith("/slack/webhook/"):
            if path.endswith("/bad"):
                return self._send(404, raw=b"no_service", content_type="text/plain")
            return self._send(200, raw=b"ok", content_type="text/plain")
        if path in ("/slack/api/chat.postMessage", "/slack/api/chat.update"):
            if token != "xoxb-good":
                return self._send(200, {"ok": False, "error": "invalid_auth"})
            if not isinstance(body, dict):
                return self._send(200, {"ok": False, "error": "invalid_json"})
            channel = body.get("channel")
            if channel == "C-missing":
                return self._send(200, {"ok": False, "error": "channel_not_found"})
            if channel == "C-notin":
                return self._send(200, {"ok": False, "error": "not_in_channel"})
            if path.endswith("chat.update"):
                if body.get("ts") == "1700000000.000100":
                    return self._send(200, {"ok": True, "channel": channel, "ts": body.get("ts")})
                return self._send(200, {"ok": False, "error": "message_not_found"})
            with State.lock:
                State.hits[("slack-ts",)] = State.hits.get(("slack-ts",), 0) + 1
                n = State.hits[("slack-ts",)]
            return self._send(200, {"ok": True, "channel": channel, "ts": "1700000001.%06d" % n})
        return self._error(404, "not found")

    def _finding(self, uid, fuid):
        with State.lock:
            for f in State.findings.get(uid, []):
                if f["uid"] == fuid:
                    return self._send(200, copy.deepcopy(f))
        return self._error(404, "finding %d not found" % fuid)

    def do_GET(self):
        self._dispatch()

    def do_POST(self):
        self._dispatch()

    def do_PUT(self):
        self._dispatch()

    def do_PATCH(self):
        self._dispatch()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", type=int, default=0)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--log", default=None, help="append every request as a JSON line to this file")
    ap.add_argument("--port-file", default=None, help="write the bound port to this file once listening")
    args = ap.parse_args()
    State.log_path = args.log
    srv = ThreadingHTTPServer((args.host, args.port), Handler)
    port = srv.server_address[1]
    if args.port_file:
        with open(args.port_file, "w", encoding="utf-8") as f:
            f.write(str(port))
    sys.stderr.write("v12 stub listening on http://%s:%d\n" % (args.host, port))
    sys.stderr.flush()
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
