#!/usr/bin/env python3
"""Acts as the project's GitHub App, so that the App's key never enters an
agent container. Only the coordinator's container can reach it (the `gate`
network), and only through two operations:

  POST /verdict  {repo, pr, sha, result: pass|fail, summary}
      Records the coordinator's verdict as the `api-lock` check on the pull
      request's head commit. Refused if the head has moved since `sha`.
  POST /release  {repo, issues: ["#3", "inkproof-coordination#4"], note}
      Releases the default branch if every issue is `ready-for-release` and
      CHANGELOG.md has an entry for the version computed from API.lock.

On its own, every POLL_INTERVAL seconds, it passes `api-lock` on pull requests
that leave API.lock alone, marks the others as waiting (with the
`needs-verdict` label, which wakes the coordinator), and mentions the human on
issues newly labelled `needs-human`.
"""
import base64
import calendar
import json
import os
import re
import subprocess
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

OWNER = os.environ["GH_OWNER"]
PREFIX = os.environ["REPO_PREFIX"]
APP_ID = os.environ["APP_ID"]
HUMAN = os.environ["HUMAN_USER"]
POLL = int(os.environ.get("POLL_INTERVAL", "60"))
KEY = "/run/gatekeeper/app-key.pem"
STATE = "/state/needs-human-seen.json"
API = "https://api.github.com"
CHECK = "api-lock"
WAITING = "needs-verdict"
VERSION = re.compile(r"^v(\d+)\.(\d+)\.(\d+)$")


def log(msg):
    print(f"gatekeeper: {msg}", flush=True)


class GitHubError(Exception):
    def __init__(self, status, message):
        super().__init__(f"GitHub answered {status}: {message}")
        self.status = status


class Refused(Exception):
    """A request the gatekeeper declines; the message says why."""


def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def app_jwt():
    now = int(time.time())
    header = b64url(json.dumps({"alg": "RS256", "typ": "JWT"}).encode())
    payload = b64url(json.dumps({"iat": now - 60, "exp": now + 540, "iss": APP_ID}).encode())
    signing_input = f"{header}.{payload}".encode()
    signature = subprocess.run(["openssl", "dgst", "-sha256", "-sign", KEY],
                               input=signing_input, capture_output=True, check=True).stdout
    return f"{header}.{payload}.{b64url(signature)}"


_token = {"value": None, "expires": 0.0}
_token_lock = threading.Lock()


def token():
    with _token_lock:
        if _token["value"] and time.time() < _token["expires"] - 300:
            return _token["value"]
        auth = f"Bearer {app_jwt()}"
        installation = call("GET", f"/orgs/{OWNER}/installation", auth=auth)
        issued = call("POST", f"/app/installations/{installation['id']}/access_tokens", auth=auth)
        _token["value"] = issued["token"]
        _token["expires"] = calendar.timegm(time.strptime(issued["expires_at"], "%Y-%m-%dT%H:%M:%SZ"))
        return _token["value"]


def call(method, path, body=None, auth=None, raw=False):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(API + path, data=data, method=method)
    req.add_header("Accept", "application/vnd.github.raw+json" if raw else "application/vnd.github+json")
    req.add_header("X-GitHub-Api-Version", "2022-11-28")
    req.add_header("User-Agent", "inkproof-gatekeeper")
    req.add_header("Authorization", auth or f"token {token()}")
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            content = resp.read()
    except urllib.error.HTTPError as e:
        detail = e.read().decode(errors="replace")
        try:
            detail = json.loads(detail).get("message", detail)
        except ValueError:
            pass
        raise GitHubError(e.code, detail) from None
    if raw:
        return content.decode()
    return json.loads(content) if content else None


def call_all(path, key=None):
    """Every page of a list endpoint."""
    items, page = [], 1
    sep = "&" if "?" in path else "?"
    while True:
        got = call("GET", f"{path}{sep}per_page=100&page={page}")
        batch = got[key] if key else got
        items += batch
        if len(batch) < 100:
            return items
        page += 1


def file_at(repo, path, ref):
    try:
        return call("GET", f"/repos/{repo}/contents/{path}?ref={ref}", raw=True)
    except GitHubError as e:
        if e.status == 404:
            return None
        raise


def repo_name(name):
    name = name.split("/")[-1]
    if not name.startswith(PREFIX):
        raise Refused(f"{name} is not one of this project's repositories ({PREFIX}*).")
    return f"{OWNER}/{name}"


def project_repos():
    repos = call_all("/installation/repositories", key="repositories")
    return [r["full_name"] for r in repos if r["name"].startswith(PREFIX)]


def comment(repo, number, text):
    call("POST", f"/repos/{repo}/issues/{number}/comments", {"body": text})


def remove_label(repo, number, label):
    try:
        call("DELETE", f"/repos/{repo}/issues/{number}/labels/{label}")
    except GitHubError as e:
        if e.status != 404:
            raise


# --- api-lock ---------------------------------------------------------------

def changes_api_lock(repo, number):
    files = call_all(f"/repos/{repo}/pulls/{number}/files")
    return any("API.lock" in (f["filename"], f.get("previous_filename")) for f in files)


def api_lock_runs(repo, sha):
    return call("GET", f"/repos/{repo}/commits/{sha}/check-runs?check_name={CHECK}&app_id={APP_ID}")["check_runs"]


def triage_pull_request(repo, pr):
    sha = pr["head"]["sha"]
    if api_lock_runs(repo, sha):
        return
    if changes_api_lock(repo, pr["number"]):
        call("POST", f"/repos/{repo}/check-runs", {
            "name": CHECK, "head_sha": sha, "status": "in_progress",
            "output": {"title": "Waiting for the coordinator's verdict",
                       "summary": "This pull request changes API.lock, so it cannot merge until the coordinator has compared its theorem statements with their requirements."}})
        # Removing first makes a fresh "labeled" event even if an earlier
        # commit was already waiting, so the coordinator is woken again.
        remove_label(repo, pr["number"], WAITING)
        call("POST", f"/repos/{repo}/issues/{pr['number']}/labels", {"labels": [WAITING]})
        log(f"{repo}#{pr['number']} changes API.lock at {sha[:12]}; waiting for the coordinator")
    else:
        call("POST", f"/repos/{repo}/check-runs", {
            "name": CHECK, "head_sha": sha, "status": "completed", "conclusion": "success",
            "output": {"title": "API.lock unchanged", "summary": "This pull request does not change API.lock, so it needs no verdict."}})


def verdict(req):
    repo = repo_name(str(req.get("repo", "")))
    number = int(req.get("pr", 0))
    sha = str(req.get("sha", ""))
    result = req.get("result")
    summary = str(req.get("summary", "")).strip()
    if result not in ("pass", "fail"):
        raise Refused("result must be pass or fail.")
    if not summary:
        raise Refused("Give a summary: what you compared, and for a fail, each finding.")
    pr = call("GET", f"/repos/{repo}/pulls/{number}")
    if pr["state"] != "open":
        raise Refused(f"{repo}#{number} is not open.")
    head = pr["head"]["sha"]
    if not sha or not head.startswith(sha) or len(sha) < 7:
        raise Refused(f"{repo}#{number}'s head is {head}. Review that commit and give its verdict with its full sha.")
    passed = result == "pass"
    body = {"name": CHECK, "head_sha": head, "status": "completed",
            "conclusion": "success" if passed else "failure",
            "output": {"title": "The coordinator passed API.lock" if passed else "The coordinator failed API.lock",
                       "summary": summary}}
    runs = api_lock_runs(repo, head)
    if runs:
        del body["name"], body["head_sha"]
        call("PATCH", f"/repos/{repo}/check-runs/{runs[0]['id']}", body)
    else:
        call("POST", f"/repos/{repo}/check-runs", body)
    remove_label(repo, number, WAITING)
    log(f"verdict {result} on {repo}#{number} at {head[:12]}")
    return f"Recorded {result} for {repo}#{number} at {head[:12]}."


# --- releases ---------------------------------------------------------------

def latest_release_tag(repo):
    best = None
    for tag in call_all(f"/repos/{repo}/tags"):
        m = VERSION.match(tag["name"])
        if m:
            version = tuple(int(x) for x in m.groups())
            if best is None or version > best[0]:
                best = (version, tag["name"], tag["commit"]["sha"])
    return best


def lines(text):
    return {line.strip() for line in (text or "").splitlines() if line.strip()}


def next_version(previous, old_lock, new_lock):
    """Semantic versioning from the API.lock diff. Before 1.0, a change to
    API.lock bumps the minor version; from 1.0, removing or changing a line
    is major and only adding lines is minor. Anything else is a patch."""
    if previous is None:
        return "v0.1.0", "this is the first release"
    major, minor, patch = previous
    removed = lines(old_lock) - lines(new_lock)
    added = lines(new_lock) - lines(old_lock)
    if removed:
        why = "API.lock removes or changes declarations"
    elif added:
        why = "API.lock only adds declarations"
    else:
        why = "API.lock is unchanged"
    if major == 0:
        version = (0, minor + 1, 0) if (removed or added) else (0, minor, patch + 1)
    elif removed:
        version = (major + 1, 0, 0)
    elif added:
        version = (major, minor + 1, 0)
    else:
        version = (major, minor, patch + 1)
    return "v{}.{}.{}".format(*version), why


def changelog_entry(changelog, version):
    heading = re.compile(rf"^##\s+\[?{re.escape(version)}\]?(\s|$)")
    found, body = False, []
    for line in (changelog or "").splitlines():
        if found:
            if line.startswith("## "):
                break
            body.append(line)
        elif heading.match(line):
            found = True
    return "\n".join(body).strip() if found else None


def parse_issue(ref, default_repo):
    m = re.fullmatch(r"(?:([\w.-]+/)?([\w.-]+))?#(\d+)", ref.strip())
    if not m:
        raise Refused(f"{ref!r} is not an issue reference; use #n or repo#n.")
    repo = repo_name(m.group(2)) if m.group(2) else default_repo
    return repo, int(m.group(3))


_release_lock = threading.Lock()


def release(req):
    repo = repo_name(str(req.get("repo", "")))
    note = str(req.get("note", "")).strip()
    refs = req.get("issues") or []
    if not note:
        raise Refused("Give a note: what you verified against the acceptance criteria.")
    if not refs:
        raise Refused("Name the ready-for-release issues this release delivers.")
    issues = [parse_issue(str(r), repo) for r in refs]
    not_ready = []
    for issue_repo, number in issues:
        issue = call("GET", f"/repos/{issue_repo}/issues/{number}")
        if "ready-for-release" not in {label["name"] for label in issue["labels"]}:
            not_ready.append(f"{issue_repo}#{number}")
    if not_ready:
        raise Refused(f"Not labelled ready-for-release: {', '.join(not_ready)}.")

    with _release_lock:
        branch = call("GET", f"/repos/{repo}")["default_branch"]
        head = call("GET", f"/repos/{repo}/commits/{branch}")["sha"]
        previous = latest_release_tag(repo)
        if previous and previous[2] == head:
            raise Refused(f"Nothing has been merged into {branch} since {previous[1]}.")
        old_lock = file_at(repo, "API.lock", previous[1]) if previous else ""
        new_lock = file_at(repo, "API.lock", head)
        version, why = next_version(previous[0] if previous else None, old_lock, new_lock)
        entry = changelog_entry(file_at(repo, "CHANGELOG.md", head), version)
        if not entry:
            raise Refused(f"CHANGELOG.md on {branch} needs a '## {version}' entry with its sentence: {why}, so the next version is {version}.")
        created = call("POST", f"/repos/{repo}/releases", {
            "tag_name": version, "target_commitish": head, "name": version,
            "body": f"{entry}\n\nVerified by the coordinator: {note}"})
    for issue_repo, number in issues:
        comment(issue_repo, number,
                f"From: gatekeeper (no reply needed)\n\nReleased in [{version}]({created['html_url']}).\n\nThe coordinator verified: {note}")
        remove_label(issue_repo, number, "ready-for-release")
    log(f"released {repo} {version} at {head[:12]}")
    return f"Released {repo} {version} ({created['html_url']})."


# --- needs-human ------------------------------------------------------------

def mention_needs_human(repo, seen):
    events = call("GET", f"/repos/{repo}/issues/events?per_page=100")
    first_look = repo not in seen
    known = set(seen.get(repo, []))
    for event in reversed(events):
        if event["event"] != "labeled" or event.get("label", {}).get("name") != "needs-human":
            continue
        if event["id"] in known:
            continue
        known.add(event["id"])
        issue = event["issue"]
        # On the first look, only learn what is already there.
        if first_look or issue["state"] != "open" or f"@{HUMAN}" in (issue.get("body") or ""):
            continue
        comment(repo, issue["number"], f"From: gatekeeper (no reply needed)\n\n@{HUMAN} this needs your decision.")
        log(f"mentioned the human on {repo}#{issue['number']}")
    seen[repo] = sorted(known)[-500:]


def load_seen():
    try:
        with open(STATE) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def poll_forever():
    seen = load_seen()
    while True:
        try:
            for repo in project_repos():
                try:
                    for pr in call_all(f"/repos/{repo}/pulls?state=open"):
                        triage_pull_request(repo, pr)
                    mention_needs_human(repo, seen)
                except GitHubError as e:
                    log(f"{repo}: {e}")
            with open(STATE + ".tmp", "w") as f:
                json.dump(seen, f)
            os.replace(STATE + ".tmp", STATE)
        except Exception as e:  # keep polling whatever goes wrong
            log(f"poll failed: {e}")
        time.sleep(POLL)


# --- HTTP -------------------------------------------------------------------

class Handler(BaseHTTPRequestHandler):
    routes = {"/verdict": verdict, "/release": release}

    def do_POST(self):
        route = self.routes.get(self.path)
        if route is None:
            return self.reply(404, {"error": f"No such operation: {self.path}"})
        try:
            req = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
            self.reply(200, {"message": route(req)})
        except Refused as e:
            self.reply(409, {"error": str(e)})
        except GitHubError as e:
            self.reply(502, {"error": str(e)})
        except (ValueError, TypeError) as e:
            self.reply(400, {"error": f"Bad request: {e}"})
        except Exception as e:
            log(f"{self.path} failed: {e!r}")
            self.reply(500, {"error": f"The gatekeeper failed: {e!r}. Nothing more was done; tell the human."})

    def reply(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, fmt, *args):
        log(f"{self.address_string()} {fmt % args}")


if __name__ == "__main__":
    threading.Thread(target=poll_forever, daemon=True).start()
    log(f"serving the coordinator for {OWNER}/{PREFIX}* as App {APP_ID}")
    ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
