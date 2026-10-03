#!/usr/bin/env python3
"""Keep configured fleet pull requests moving.

Every watcher check cycle:
  - lists open pull requests by configured authors, registered task pr= URLs, and takeovers;
  - maps each PR to its owning lane (meta branch, takeover table, or a recent status mention);
  - classifies the stall (conflict, behind, failing checks, cancelled-only rollup, open threads);
  - steers the owner once per (PR, head, problem) with the exact action and failing job links,
    re-nudges if the same problem is still there after RENUDGE_S;
  - admin-merges PRs the fleet eligibility script accepts;
  - wakes the owner of a registered green PR that has no armed merge poll;
  - prints a line only for merges, PRs with no live owner, and long stalls.
The configured budget keeps each sweep bounded so work resumes next cycle.
"""
import json, os, re, subprocess, sys, time, glob

CODE_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HOME = os.environ.get("FM_HOME", CODE_ROOT)
STATE = os.environ.get("FM_STATE_OVERRIDE", f"{HOME}/state")
CONFIG = os.environ.get("FM_FLEET_CONFIG_FILE", os.path.join(os.environ.get("FM_CONFIG_OVERRIDE", f"{HOME}/config"), "fleet-watch.json"))
GH_BIN = os.environ.get("FM_FLEET_GH_BIN", "gh")
SEEN = f"{STATE}/.pr-stall-seen.json"
REPO = ""
BUDGET_S = 24
RENUDGE_S = 45 * 60
ESCALATE_S = 120 * 60
TAKEOVERS = {}
REMOTE = set()
STEERING = {
    "conflict": "{url} conflicts with {base}. Bring {base} into the branch, resolve the conflicts, push, and keep watching the pull request until it is green.",
    "red": "{url} has failing checks on head {head}: {checks}. Read the failing job log, fix the root cause, re-run the focused local checks, push, and keep watching the pull request.",
    "behind": "{url} is behind {base}. Bring {base} into the branch, push, and keep watching the pull request.",
    "cancelled": "{url} rollup is red only from cancelled runs ({cancelled}). Re-run each cancelled run once if no sibling run of that workflow is active, then keep watching the pull request.",
    "threads": "{url} has {threads} unresolved review thread(s). Fix or answer each thread, resolve it, push, and keep watching the pull request.",
    "ready": "{url} is green on head {head} but no merge watch is armed for it. Re-run the local ready check and report the pull request ready again.",
}
STEERING_DEFAULTS = dict(STEERING)
try:
    with open(CONFIG, encoding="utf-8") as fh:
        cfg = json.load(fh)
    REPO = cfg["repo"]
    BUDGET_S = int(cfg.get("thresholds", {}).get("budget_seconds", BUDGET_S))
    RENUDGE_S = int(cfg.get("thresholds", {}).get("renudge_seconds", RENUDGE_S))
    ESCALATE_S = int(cfg.get("thresholds", {}).get("escalate_seconds", ESCALATE_S))
    TAKEOVERS = {int(k): v for k, v in cfg.get("takeovers", {}).items()}
    REMOTE = set(cfg.get("remote_lanes", []))
    steering = cfg.get("steering")
    if isinstance(steering, dict):
        STEERING.update({k: v for k, v in steering.items() if k in STEERING and isinstance(v, str)})
except (OSError, ValueError, KeyError, json.JSONDecodeError):
    REPO = os.environ.get("FM_FLEET_REPO", "")

t0 = time.time()


def left():
    return BUDGET_S - (time.time() - t0)


def sh(args, timeout=15):
    try:
        r = subprocess.run(args, capture_output=True, text=True, timeout=max(1, min(timeout, left())), cwd=CODE_ROOT,
                           env={**os.environ, "FM_HOME": HOME, "FM_ROOT_OVERRIDE": CODE_ROOT})
        return r.returncode, r.stdout
    except Exception:
        return 1, ""


Q = """query($q:String!){search(query:$q,type:ISSUE,first:100){nodes{... on PullRequest{
 number url isDraft mergeable mergeStateStatus headRefName baseRefName author{login}
 reviewThreads(first:60){nodes{isResolved}}
 commits(last:1){nodes{commit{oid statusCheckRollup{state contexts(first:100){nodes{
   ... on CheckRun{name conclusion status detailsUrl} ... on StatusContext{context state targetUrl}}}}}}}}}}}"""

Q_ONE = """query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){pullRequest(number:$number){
 number url state isDraft mergeable mergeStateStatus headRefName baseRefName author{login}
 reviewThreads(first:60){nodes{isResolved}}
 commits(last:1){nodes{commit{oid statusCheckRollup{state contexts(first:100){nodes{
   ... on CheckRun{name conclusion status detailsUrl} ... on StatusContext{context state targetUrl}}}}}}}}}}"""


def registered_prs():
    """Read canonical PR URLs from task metadata for owner-independent coverage."""
    out = []
    for m in glob.glob(f"{STATE}/*.meta"):
        try:
            text = open(m, encoding="utf-8").read()
        except OSError:
            continue
        for line in text.splitlines():
            if line.startswith("pr=https://github.com/"):
                match = re.fullmatch(r"pr=(https://github\.com/([^/]+/[^/]+)/pull/([1-9][0-9]*))", line)
                if match:
                    out.append((match.group(1), match.group(2), int(match.group(3))))
                break
    return out


def prs():
    out = []
    authors = cfg.get("authors", []) if "cfg" in globals() else [os.environ.get("FM_FLEET_PR_AUTHORS", "")]
    authors = [a for a in authors if a]
    numbers = sorted({entry[2] for entry in registered_prs() if entry[1] == REPO} | set(TAKEOVERS))
    if not REPO or (not authors and not numbers):
        return out
    seen = set()
    for q in [f"repo:{REPO} is:pr is:open author:{a}" for a in authors]:
        rc, o = sh([GH_BIN, "api", "graphql", "-f", f"query={Q}", "-f", f"q={q}"], timeout=12)
        if rc:
            continue
        try:
            nodes = json.loads(o)["data"]["search"]["nodes"]
        except (KeyError, TypeError, json.JSONDecodeError):
            continue
        for n in nodes:
            if not n or n.get("number") in seen:
                continue
            if (n.get("author") or {}).get("login") not in authors:
                continue
            seen.add(n["number"])
            out.append(n)
    # Search is capped at 100 results. Fetch registered and takeover identities
    # directly so a live owner is never reported ownerless merely because the PR
    # fell past that cap or was opened by an account outside the author list.
    owner, name = REPO.split("/", 1) if "/" in REPO else (REPO, "")
    for number in numbers:
        if number in seen:
            continue
        rc, raw = sh([GH_BIN, "api", "graphql", "-f", f"query={Q_ONE}",
                      "-F", f"owner={owner}", "-F", f"name={name}", "-F", f"number={number}"], timeout=12)
        if rc:
            continue
        try:
            node = json.loads(raw)["data"]["repository"]["pullRequest"]
        except (KeyError, TypeError, json.JSONDecodeError):
            continue
        if node and node.get("state") == "OPEN" and not node.get("isDraft"):
            seen.add(number)
            out.append(node)
    return out


def owners():
    records = {}
    for m in glob.glob(f"{STATE}/*.meta"):
        tid = os.path.basename(m)[:-5]
        try:
            text = open(m, encoding="utf-8").read()
        except OSError:
            continue
        branch = ""
        pr = ""
        for line in text.splitlines():
            if line.startswith("branch="):
                branch = line[7:]
            elif line.startswith("pr="):
                pr = line[3:]
        records[tid] = {"branch": branch, "pr": pr}
    return records


def owner_of(pr, metas):
    n = pr["number"]
    url = pr.get("url", "")
    if n in TAKEOVERS and TAKEOVERS[n] in metas:
        return TAKEOVERS[n]
    # A canonical pr= is authoritative for a takeover or a stacked lane whose
    # branch moved after the PR opened.
    for tid, record in metas.items():
        if record.get("pr") == url and tid not in REMOTE:
            return tid
    # Branch ownership covers stacked lanes and PRs whose metadata was recorded
    # before the forge returned the canonical URL.
    for tid, record in metas.items():
        if record.get("branch") and record["branch"] == pr.get("headRefName") and tid not in REMOTE:
            return tid
    best = None
    for tid in metas:
        if tid in REMOTE:
            continue
        try:
            tail = open(f"{STATE}/{tid}.status", encoding="utf-8").read()[-6000:]
        except OSError:
            continue
        if f"/pull/{n}" in tail:
            best = tid
    if best:
        return best
    for tid in REMOTE:
        try:
            if f"/pull/{n}" in open(f"{STATE}/{tid}.status", encoding="utf-8").read()[-6000:]:
                return tid
        except OSError:
            pass
    return None


def classify(pr):
    c = pr["commits"]["nodes"][0]["commit"]
    roll = c.get("statusCheckRollup") or {}
    ctx = [x for x in (roll.get("contexts") or {}).get("nodes", []) if x]
    fails = [(x.get("name") or x.get("context"), x.get("detailsUrl") or x.get("targetUrl") or "")
             for x in ctx if (x.get("conclusion") or x.get("state")) in ("FAILURE", "ERROR", "TIMED_OUT", "STARTUP_FAILURE")]
    canc = [x.get("name") for x in ctx if x.get("conclusion") == "CANCELLED"]
    pending = [x for x in ctx if x.get("status") in ("IN_PROGRESS", "QUEUED", "PENDING", "WAITING") or x.get("state") == "PENDING"]
    threads = sum(1 for t in pr["reviewThreads"]["nodes"] if not t["isResolved"])
    head = c["oid"][:10]
    fields = {"url": pr["url"], "base": pr["baseRefName"], "head": head, "threads": threads,
              "checks": "; ".join(f"{n} {u}" for n, u in fails[:4]),
              "cancelled": ", ".join(sorted(set(canc)))[:120]}

    def steer(kind):
        try:
            return STEERING[kind].format(**fields)
        except Exception:
            return STEERING_DEFAULTS[kind].format(**fields)

    if pr["mergeable"] == "CONFLICTING" or pr["mergeStateStatus"] == "DIRTY":
        return head, "conflict", steer("conflict")
    if fails:
        return head, "red:" + ",".join(sorted(n for n, _ in fails)), steer("red")
    if pr["mergeStateStatus"] == "BEHIND":
        return head, "behind", steer("behind")
    if canc and not pending and roll.get("state") != "SUCCESS":
        return head, "cancelled", steer("cancelled")
    if threads:
        return head, "threads", steer("threads")
    if pending:
        return head, "running", None
    if pr["isDraft"]:
        return head, "draft-green", None
    return head, "green", steer("ready")


def main():
    try:
        seen = json.load(open(SEEN))
    except Exception:
        seen = {}
    now = int(time.time())
    metas = owners()
    lines = []
    live_keys = set()
    for pr in prs():
        if left() < 3:
            break
        n = pr["number"]
        head, cls, action = classify(pr)
        key = f"{n}:{head}:{cls}"
        live_keys.add(key)
        rec = seen.get(key, {"first": now, "steered": 0, "escalated": 0})
        if cls == "green":
            rc, o = sh(["bash", os.path.join(CODE_ROOT, "bin", "fm-pr-fleet-merge-eligible.sh"), pr["url"]], timeout=10)
            if o.strip().startswith("true") and left() > 6:
                rc, o = sh(["bash", os.path.join(CODE_ROOT, "bin", "fm-pr-fleet-admin-merge.sh"), pr["url"]], timeout=15)
                if "merged:" in o:
                    lines.append(f"pr-stall: merged {pr['url']}")
                    seen[key] = rec
                    continue
            own = owner_of(pr, metas)
            # A registration whose ready check failed while CI was pending has
            # no merge watch; once green, wake its owner to report ready again.
            if not own or metas[own].get("pr") != pr["url"] or os.path.exists(f"{STATE}/{own}.check.sh"):
                action = None
        if action is None:
            seen[key] = rec
            continue
        own = owner_of(pr, metas)
        if own is None:
            if not rec["escalated"]:
                lines.append(f"pr-stall: no live owner for {pr['url']} ({cls}); assign a babysit lane")
                rec["escalated"] = now
            seen[key] = rec
            continue
        if own in REMOTE:
            seen[key] = rec
            continue
        if not rec["steered"] or now - rec["steered"] > RENUDGE_S:
            msg = ("[pr-stall sweep] " if not rec["steered"] else "[pr-stall sweep, still stalled] ") + action
            rc, _ = sh([os.path.join(CODE_ROOT, "bin/fm-send.sh"), own, msg], timeout=8)
            if rc == 0:
                rec["steered"] = now
        if now - rec["first"] > ESCALATE_S and not rec["escalated"]:
            lines.append(f"pr-stall: {pr['url']} stuck {cls} for {(now - rec['first']) // 60}m despite steering {own}")
            rec["escalated"] = now
        seen[key] = rec
    seen = {k: v for k, v in seen.items() if k in live_keys or now - v.get("first", now) < 86400}
    json.dump(seen, open(SEEN + ".tmp", "w"))
    os.replace(SEEN + ".tmp", SEEN)
    if lines:
        print(" | ".join(lines)[:900])


if __name__ == "__main__":
    main()
