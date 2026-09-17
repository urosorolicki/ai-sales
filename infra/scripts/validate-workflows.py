#!/usr/bin/env python3
"""Structural checks on the exported n8n workflows.

n8n does not validate a workflow until it runs one, and some of the ways a
generated workflow can be wrong are silent: a connection pointing at a node that
was renamed, a Postgres node with a $1 placeholder and nothing to fill it, a node
left behind with nothing feeding it. Each of those has cost a debugging session
at least once.

This checks the JSON only. It does not connect to anything, so it is safe to run
anywhere and fast enough to run every time.

    python3 infra/scripts/validate-workflows.py [files...]

Exit code 0 if everything passes, 1 otherwise.
"""

import json
import pathlib
import re
import sys

WORKFLOW_DIR = pathlib.Path(__file__).resolve().parents[2] / "n8n" / "workflows"

TRIGGER_TYPES = {
    "n8n-nodes-base.manualTrigger",
    "n8n-nodes-base.scheduleTrigger",
    "n8n-nodes-base.errorTrigger",
    "n8n-nodes-base.webhook",
    "n8n-nodes-base.executeWorkflowTrigger",
    "n8n-nodes-base.telegramTrigger",
    "n8n-nodes-base.emailReadImap",
}

# Anything that looks like a credential sitting in the file rather than in an
# n8n credential or $env. docs/security.md: never hardcode secrets.
SECRET_PATTERNS = [
    (re.compile(r"\b\d{6,12}:[A-Za-z0-9_-]{30,}"), "what looks like a Telegram bot token"),
    (re.compile(r"\bsk-[A-Za-z0-9]{20,}"), "what looks like an API key"),
    (re.compile(r"\bxox[baprs]-[A-Za-z0-9-]{10,}"), "what looks like a Slack token"),
    (re.compile(r"[a-z][a-z0-9+.-]*://[^:\s/@]+:[^@\s/]{3,}@"), "a URL with an inline password"),
    (re.compile(r"\beyJ[A-Za-z0-9._-]{24,}"), "what looks like a JWT"),
]


class Report:
    def __init__(self):
        self.errors = []
        self.warnings = []

    def error(self, where, message):
        self.errors.append(f"{where}: {message}")

    def warn(self, where, message):
        self.warnings.append(f"{where}: {message}")


def check_workflow(path, wf, known_ids, report):
    where = path.name
    nodes = wf.get("nodes", [])
    names = [n.get("name") for n in nodes]
    by_name = {n.get("name"): n for n in nodes}

    if len(set(names)) != len(names):
        dupes = sorted({n for n in names if names.count(n) > 1})
        report.error(where, f"duplicate node names: {', '.join(dupes)}")

    ids = [n.get("id") for n in nodes]
    if len(set(ids)) != len(ids):
        report.error(where, "duplicate node ids")

    connections = wf.get("connections", {})

    # Every endpoint of every connection must exist. A rename that misses the
    # connections map fails at runtime, not at import.
    for src, outputs in connections.items():
        if src not in by_name:
            report.error(where, f"connections reference unknown source node '{src}'")
        for branch in outputs.get("main", []):
            for target in branch:
                if target.get("node") not in by_name:
                    report.error(where, f"'{src}' connects to unknown node '{target.get('node')}'")

    # A node removed without its connections entry crashes the workflow with
    # "Cannot read properties of undefined (reading 'disabled')".
    for name in connections:
        if name not in by_name:
            report.error(where, f"orphan connections entry for removed node '{name}'")

    # Everything must be reachable from a trigger.
    triggers = [n["name"] for n in nodes if n.get("type") in TRIGGER_TYPES]
    if not triggers:
        report.error(where, "no trigger node")
    reachable = set()
    frontier = list(triggers)
    while frontier:
        current = frontier.pop()
        if current in reachable:
            continue
        reachable.add(current)
        for branch in connections.get(current, {}).get("main", []):
            for target in branch:
                frontier.append(target.get("node"))

    # LangChain sub-nodes (a chat model, a memory, a tool) are attached the other
    # way round: the connection is stored on the sub-node and points at the node
    # that uses it, on a connection type other than "main". They are reachable,
    # just not by walking forwards.
    for name, outputs in connections.items():
        for kind, branches in outputs.items():
            if kind == "main":
                continue
            for branch in branches:
                for target in branch:
                    if target.get("node") in reachable:
                        reachable.add(name)

    for name in names:
        if name not in reachable:
            report.error(where, f"node '{name}' is not reachable from any trigger")

    for node in nodes:
        name = node.get("name")
        ntype = node.get("type", "")
        params = node.get("parameters", {})

        if ntype == "n8n-nodes-base.postgres":
            if "postgres" not in node.get("credentials", {}):
                report.error(where, f"'{name}' has no Postgres credential")
            query = params.get("query", "")
            replacement = params.get("options", {}).get("queryReplacement")
            uses_placeholder = "$1" in query
            if uses_placeholder and not replacement:
                report.error(where, f"'{name}' uses $1 but sets no queryReplacement")
            if replacement and not uses_placeholder:
                report.warn(where, f"'{name}' sets queryReplacement but the query has no $1")
            # $2 and up are never supplied: every query here takes one JSON blob.
            for extra in re.findall(r"\$(\d+)", query):
                if extra != "1":
                    report.error(where, f"'{name}' references ${extra}; only $1 is supplied")
            # A status='error' WRITE must not be able to violate
            # agent_runs_error_requires_message. Reading status = 'error', which
            # several queries do to count prior failures, is not a write.
            if re.search(r"SET\s+status\s*=\s*'error'", query):
                if "COALESCE" not in query.upper() and "NULLIF" not in query.upper():
                    report.warn(where, f"'{name}' writes status='error' with no COALESCE guard on the message")

        if ntype == "n8n-nodes-base.if":
            conditions = params.get("conditions", {}).get("conditions", [])
            if not conditions:
                report.error(where, f"'{name}' is an IF with no conditions")

        if ntype == "n8n-nodes-base.code" and not params.get("jsCode", "").strip():
            report.error(where, f"'{name}' is an empty Code node")

    settings = wf.get("settings", {})
    error_workflow = settings.get("errorWorkflow")
    if error_workflow and error_workflow not in known_ids:
        report.error(where, f"errorWorkflow '{error_workflow}' is not a workflow in this directory")
    if not error_workflow and wf.get("id") != "wf99ErrorHandler":
        report.warn(where, "no errorWorkflow set; failures here will be silent")

    raw = json.dumps(wf)
    for pattern, label in SECRET_PATTERNS:
        match = pattern.search(raw)
        if match:
            report.error(where, f"contains {label}")

    return len(nodes)


def main(argv):
    paths = [pathlib.Path(a) for a in argv[1:]] or sorted(WORKFLOW_DIR.glob("*.json"))
    if not paths:
        print("no workflow files found", file=sys.stderr)
        return 1

    loaded = {}
    for path in paths:
        try:
            loaded[path] = json.loads(path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as exc:
            print(f"{path.name}: not valid JSON: {exc}", file=sys.stderr)
            return 1

    # Workflow ids are resolved against the whole directory, not just the files
    # named on the command line: checking one file must not make every other
    # workflow look missing.
    known_ids = set()
    for path in WORKFLOW_DIR.glob("*.json"):
        try:
            known_ids.add(json.loads(path.read_text(encoding="utf-8")).get("id"))
        except json.JSONDecodeError:
            pass
    known_ids |= {wf.get("id") for wf in loaded.values()}
    report = Report()

    for path, wf in loaded.items():
        count = check_workflow(path, wf, known_ids, report)
        print(f"  checked {path.name} ({count} nodes)")

    for warning in report.warnings:
        print(f"  WARN  {warning}")
    for error in report.errors:
        print(f"  FAIL  {error}", file=sys.stderr)

    if report.errors:
        print(f"\n{len(report.errors)} problem(s) found", file=sys.stderr)
        return 1
    print(f"\n{len(loaded)} workflow(s) OK"
          + (f", {len(report.warnings)} warning(s)" if report.warnings else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
