#!/usr/bin/env python3
"""Live record of the agent session, kept on branch live-log.

Claude Code calls this hook after every tool call (PostToolUse) and at the end of
every turn (Stop). It writes three files under notes/live/:
  activity.md       one line per tool call, with a UTC timestamp
  conversation.md   the session so far: prompts, the agent's messages and
                    reasoning (as far as the transcript has it), tool calls,
                    and shortened tool results
  terminal.cast     a terminal recording in asciinema format: every shell
                    command and its output, at the time it finished. Play it
                    with the asciinema player, or turn it into a GIF with agg.
and pushes them to branch live-log at most once a minute, plus at every Stop.
It commits through a separate index, so it never touches the agent's staged
work or the checked-out branch. Any error is swallowed: logging must never get
in the way of the work.
"""
import json
import os
import subprocess
import sys
import tempfile
import time

ROOT = os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()
LIVE = os.path.join(ROOT, "notes", "live")
BRANCH = "live-log"
PUSH_EVERY = 60


def now():
    return time.strftime("%Y-%m-%d %H:%M:%S UTC", time.gmtime())


def short(s, n):
    s = " ".join(str(s).split())
    return s if len(s) <= n else s[:n] + " ..."


def summarize_tool(name, inp):
    inp = inp or {}
    for key in ("command", "file_path", "path", "pattern", "description", "url", "query", "prompt"):
        if key in inp:
            return short(inp[key], 200)
    return short(json.dumps(inp), 200)


def log_activity(event):
    os.makedirs(LIVE, exist_ok=True)
    path = os.path.join(LIVE, "activity.md")
    if not os.path.exists(path):
        with open(path, "w") as f:
            f.write("# Activity\n\n| Time | Tool | Detail |\n|---|---|---|\n")
    name = event.get("tool_name", "?")
    detail = summarize_tool(name, event.get("tool_input")).replace("|", "\\|")
    with open(path, "a") as f:
        f.write("| %s | %s | `%s` |\n" % (now(), name, detail.replace("`", "'")))


CAST_MAX = 20000   # characters of output kept per command


def cast_event(text):
    """Append one output event to the terminal recording."""
    path = os.path.join(LIVE, "terminal.cast")
    if not os.path.exists(path):
        with open(path, "w") as f:
            f.write(json.dumps({"version": 2, "width": 140, "height": 40, "timestamp": int(time.time()),
                                "title": "mkMultBuff agent session"}) + "\n")
    start_file = os.path.join(LIVE, ".cast_start")
    try:
        with open(start_file) as f:
            start = float(f.read())
    except (OSError, ValueError):
        start = time.time()
        with open(start_file, "w") as f:
            f.write(str(start))
    with open(path, "a") as f:
        f.write(json.dumps([round(time.time() - start, 3), "o", text.replace("\r\n", "\n").replace("\n", "\r\n")]) + "\n")


def record_terminal(event):
    name = event.get("tool_name", "")
    inp = event.get("tool_input") or {}
    resp = event.get("tool_response")
    if name == "Bash":
        if isinstance(resp, dict):
            out = (resp.get("stdout") or "") + (resp.get("stderr") or "")
        else:
            out = str(resp or "")
        if len(out) > CAST_MAX:
            out = out[:CAST_MAX] + "\n... (output truncated)\n"
        cast_event("\x1b[1;32m$\x1b[0m %s\n%s%s" % (inp.get("command", ""), out, "" if out.endswith("\n") else "\n"))
    elif name in ("Edit", "Write", "MultiEdit", "NotebookEdit"):
        cast_event("\x1b[2m# %s %s\x1b[0m\n" % (name.lower(), inp.get("file_path", "")))


def render_transcript(src):
    """Turn the transcript JSONL into readable markdown."""
    out = ["# Session record", "", "Rendered %s from the Claude Code transcript." % now(), ""]
    with open(src) as f:
        for line in f:
            try:
                rec = json.loads(line)
            except ValueError:
                continue
            msg = rec.get("message") or {}
            role = msg.get("role") or rec.get("type")
            stamp = rec.get("timestamp", "")[:19].replace("T", " ")
            content = msg.get("content")
            if isinstance(content, str):
                content = [{"type": "text", "text": content}]
            for block in content or []:
                kind = block.get("type")
                if kind == "text" and block.get("text", "").strip():
                    who = "Prompt" if role == "user" else "Agent"
                    out += ["### %s, %s" % (who, stamp), "", block["text"].strip(), ""]
                elif kind == "thinking" and block.get("thinking", "").strip():
                    out += ["#### Reasoning, %s" % stamp, ""]
                    out += ["> " + l for l in block["thinking"].strip().splitlines()] + [""]
                elif kind == "tool_use":
                    out += ["- `%s` %s" % (block.get("name"), short(summarize_tool(block.get("name"), block.get("input")), 300).replace("`", "'"))]
                elif kind == "tool_result":
                    res = block.get("content")
                    if isinstance(res, list):
                        res = " ".join(c.get("text", "") for c in res if isinstance(c, dict))
                    out += ["  - result: %s" % short(res or "", 400).replace("`", "'"), ""]
    return "\n".join(out) + "\n"


def git(*args, **kw):
    env = dict(os.environ)
    env.update(kw.pop("env", {}))
    return subprocess.run(["git"] + list(args), cwd=ROOT, env=env, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, universal_newlines=True, timeout=30)


def push():
    stamp = os.path.join(LIVE, ".last_push")
    with tempfile.TemporaryDirectory() as tmp:
        env = {"GIT_INDEX_FILE": os.path.join(tmp, "index")}
        git("read-tree", "--empty", env=env)
        files = [os.path.join("notes", "live", n) for n in ("activity.md", "conversation.md", "terminal.cast")
                 if os.path.exists(os.path.join(LIVE, n))]
        if not files:
            return
        git("add", "-f", *files, env=env)
        tree = git("write-tree", env=env).stdout.strip()
        # Build on the remote tip, so a second session or a fresh clone never
        # leaves this branch unable to fast-forward.
        fetched = git("fetch", "-q", "--no-write-fetch-head", "origin",
                      "+refs/heads/%s:refs/remotes/origin/%s" % (BRANCH, BRANCH))
        ref = "refs/remotes/origin/" + BRANCH if fetched.returncode == 0 else "refs/heads/" + BRANCH
        parent = git("rev-parse", "-q", "--verify", ref).stdout.strip()
        args = ["commit-tree", tree, "-m", "Live log " + now()] + (["-p", parent] if parent else [])
        commit = git(*args, env={"GIT_AUTHOR_NAME": "live-log", "GIT_AUTHOR_EMAIL": "live-log@users.noreply.github.com",
                                 "GIT_COMMITTER_NAME": "live-log", "GIT_COMMITTER_EMAIL": "live-log@users.noreply.github.com"}).stdout.strip()
        if commit:
            git("update-ref", "refs/heads/" + BRANCH, commit)
            git("push", "-q", "origin", BRANCH)
    with open(stamp, "w") as f:
        f.write(str(time.time()))


def due():
    try:
        with open(os.path.join(LIVE, ".last_push")) as f:
            return time.time() - float(f.read()) >= PUSH_EVERY
    except (OSError, ValueError):
        return True


def main():
    try:
        event = json.load(sys.stdin)
    except ValueError:
        event = {}
    kind = event.get("hook_event_name", "")
    try:
        if kind == "PostToolUse":
            log_activity(event)
            record_terminal(event)
        elif kind == "Stop":
            os.makedirs(LIVE, exist_ok=True)
            cast_event("\x1b[2m# --- end of turn ---\x1b[0m\n")
        sync = kind == "Stop" or due()
        if sync:
            src = event.get("transcript_path")
            if src and os.path.exists(src):
                os.makedirs(LIVE, exist_ok=True)
                with open(os.path.join(LIVE, "conversation.md"), "w") as f:
                    f.write(render_transcript(src))
            push()
    except Exception:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
