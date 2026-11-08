#!/usr/bin/env python3
"""Ask real agents questions about a synthetic 2-hour meeting and record how they search it.

The meeting in search-eval-meeting.json hides each answer behind wording the question does not
use: synonyms, an English passage for a German question, a misheard product name, a vague
description, a time window and a request for all decisions. Two older meetings act as decoys.
Every run uses a fresh marked fixture library, the real MCP server and its call trace.
"""

import argparse
import collections
import concurrent.futures
import datetime as dt
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time
from zoneinfo import ZoneInfo

HERE = Path(__file__).resolve().parent
BERLIN = ZoneInfo("Europe/Berlin")
TODAY = dt.date(2026, 11, 7)
NAMES = {"Speaker 1": "Sandra", "Speaker 2": "Marco", "Speaker 3": "Tom", "Speaker 4": "Lena"}
AGENTS = {
    "claude-opus": ("claude", "opus"),
    "claude-sonnet": ("claude", "sonnet"),
    "codex": ("codex", "gpt-6.1-sol"),
}
INSTRUCTIONS = (
    f"You are a helpful assistant for Jona. Today is {TODAY.isoformat()} ({TODAY.strftime('%A')}), "
    "Europe/Berlin. Answer in the user's language. Use only the connected meetings tools; work "
    "directly without delegation."
)
CODEX_DISABLED_FEATURES = [
    "apps", "plugins", "hooks", "shell_tool", "unified_exec", "view_image", "computer_use",
    "browser_use", "in_app_browser", "image_generation", "multi_agent", "multi_agent_v2",
    "memories", "sleep_tool", "goals", "skill_search", "tool_suggest", "code_mode",
]

CASES = {
    "costs": {
        "prompt": "Was wurde im Relaunch-Steering gestern alles zu den Kosten gesagt?",
        "facts": {
            "PIM licence 38,000 per year": r"38[.\s ]?000|38\s?k",
            "Agency budget 80 % used": r"80\s?(%|prozent)",
            "Hosting +4k per month": r"4[.\s ]?000|4\s?k|vier\s?k|viertausend",
            "Agency extension +60k": r"60[.\s ]?000|60\s?k",
        },
        "decoys": {"Budget planning 15,000/month": r"15[.\s ]?000", "Budget planning 9,000": r"\b9[.\s ]?000"},
    },
    "kubernetes": {
        "prompt": "Was hat Sandra im Steering gestern zum Kubernetes-Cluster gesagt?",
        "facts": {"Stable since Monday": r"stabil", "Autoscaling off": r"autoscal"},
        "decoys": {},
    },
    "golive": {
        "prompt": "Wann ist jetzt der Go-Live und warum hat er sich verschoben?",
        "facts": {
            "14 March": r"14\.?\s?(märz|maerz|march|\.\s?0?3)|march 14|3/14",
            "Payment provider certification": r"zertifizier|certif",
        },
        "decoys": {},
    },
    "marco": {
        "prompt": "Was muss Marco aus dem letzten Meeting bis wann erledigen?",
        "facts": {
            "Load test scripts by Friday": r"lasttest|load.?test",
            "Returns in regression tests": r"retour|regression",
            "Monitoring setup by month end": r"monitoring",
        },
        "decoys": {},
    },
    "complaint": {
        "prompt": "Was war nochmal im Steering mit dem Dienstleister, der sich beschwert hat?",
        "facts": {
            "Hermes": r"hermes",
            "Return labels with wrong sender": r"etikett|label|absender",
            "Agency follows up": r"agentur|tom|agency",
        },
        "decoys": {},
    },
    "accessibility": {
        "prompt": "Haben wir im Steering über Barrierefreiheit gesprochen?",
        "facts": {"Accessibility audit moved to Q3": r"q3|drittes quartal|3\. quartal"},
        "decoys": {},
    },
    "last15": {
        "prompt": "Worüber haben wir in der letzten Viertelstunde vom Steering gesprochen?",
        "facts": {
            "Code freeze 2 March": r"code.?freeze",
            "Next steering in two weeks": r"zwei wochen|2 wochen|dienstag",
            "Summary to the board": r"vorstand",
        },
        "decoys": {},
    },
    "conversion": {
        "prompt": "Wie war laut Steering die Conversion Rate im Januar?",
        "facts": {"2.1 %": r"2[,.]1"},
        "decoys": {},
    },
    "decisions": {
        "prompt": "Welche Entscheidungen haben wir im Relaunch-Steering getroffen?",
        "facts": {
            "Vouchers after launch": r"gutschein|voucher",
            "Adyen as fallback": r"adyen",
            "Agency extended to end of March": r"ende märz|ende maerz|verlänger|verlaenger",
            "Code freeze 2 March": r"code.?freeze",
        },
        "decoys": {},
    },
}


def record(began, title, turns, total_seconds=None):
    words = sum(len(text.split()) for _, text in turns)
    gap = 0.6
    per_word = (total_seconds - gap * len(turns)) / words if total_seconds else 0.38
    identifier = began.astimezone(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    segments, clock = [], 0.0
    for speaker, text in turns:
        length = max(1.2, len(text.split()) * per_word)
        segments.append({"start": round(clock, 2), "end": round(clock + length, 2), "speaker": speaker, "text": text})
        clock += length + gap
    speakers = []
    for label in dict.fromkeys(speaker for speaker, _ in turns):
        mine = [s for s in segments if s["speaker"] == label]
        speaker = {
            "label": label, "is_local_user": label == "Jona",
            "identity": "local-user" if label == "Jona" else "unidentified",
            "source": "microphone" if label == "Jona" else "teams",
            "turns": len(mine), "seconds": round(sum(s["end"] - s["start"] for s in mine), 2),
        }
        if label in NAMES:
            speaker["name"] = NAMES[label]
        speakers.append(speaker)
    return {
        "schema_version": 1, "id": identifier, "title": title, "title_source": "teams",
        "started_at": began.isoformat(), "ended_at": (began + dt.timedelta(seconds=clock)).isoformat(),
        "duration_seconds": round(clock), "status": "complete", "source": "teams", "trigger": "manual",
        "speakers": speakers, "segments": segments,
        "audio_file": identifier + ".m4a", "transcript_file": identifier + ".txt",
    }


def library():
    steering = json.loads((HERE / "search-eval-meeting.json").read_text())
    return [
        record(dt.datetime(2026, 11, 6, 9, 0, tzinfo=BERLIN), "Webshop-Relaunch Steering", steering, 7200),
        record(dt.datetime(2026, 11, 3, 10, 0, tzinfo=BERLIN), "Team-Weekly Plattform", [
            ("Jona", "Okay, dann fangen wir an. Sandra, magst du kurz zur Plattform?"),
            ("Speaker 1", "Ja, das Kubernetes-Upgrade auf 1.31 machen wir nächste Woche Mittwoch im Wartungsfenster, die Staging-Umgebung ist schon migriert."),
            ("Speaker 2", "Ich brauche danach einen Tag für die Smoke-Tests, also bitte rechtzeitig Bescheid geben."),
            ("Jona", "Die Kosten für die Testlizenzen von BrowserStack laufen übrigens Ende November aus, das müssen wir verlängern."),
            ("Speaker 4", "Und ich bin nächste Woche Montag und Dienstag im Urlaub."),
        ]),
        record(dt.datetime(2026, 10, 29, 14, 0, tzinfo=BERLIN), "Budgetplanung 2027", [
            ("Jona", "Wir müssen bis Mitte November die Kosten für 2027 einreichen."),
            ("Speaker 4", "Für Marketing planen wir mit 120.000 Euro, inklusive der SEO-Agentur."),
            ("Jona", "Beim Relaunch rechne ich nach dem Go-Live mit laufenden Kosten von etwa 15.000 Euro im Monat."),
            ("Speaker 1", "Für die Infrastruktur kalkuliere ich mit 9.000 Euro pro Monat."),
        ]),
    ]


def prepare(case_dir):
    root = case_dir / "meetings"
    (root / "transcripts").mkdir(parents=True)
    (root / "audios").mkdir()
    (root / ".agent-fixture").write_text("meeting-notes-agent-fixture\n")
    (root / "config.json").write_text(json.dumps({
        "localSpeakerName": "Jona", "agentsMayNameMeetings": False, "agentsMaySummarizeMeetings": False,
    }))
    for item in library():
        (root / "transcripts" / (item["id"] + ".json")).write_text(json.dumps(item, ensure_ascii=False, indent=1))
        (root / "transcripts" / item["transcript_file"]).write_text(
            "\n\n".join(f'[{s["start"]}] {s["speaker"]}: {s["text"]}' for s in item["segments"]) + "\n")
        (root / "audios" / item["audio_file"]).write_bytes(b"Synthetic fixture; no captured audio.\n")
    return root


def command(agent, binary, root, client, answer, prompt):
    cli, model = AGENTS[agent]
    if cli == "claude":
        config = {"mcpServers": {"meetings": {"command": str(binary), "args": ["--mcp-fixture", str(root)]}}}
        return ["claude", "-p", "--model", model, "--tools", "", "--strict-mcp-config",
                "--mcp-config", json.dumps(config), "--allowedTools", "mcp__meetings",
                "--no-session-persistence", "--output-format", "stream-json", "--verbose",
                "--append-system-prompt", INSTRUCTIONS, prompt]
    argv = ["codex", "exec", "--ignore-user-config", "--ephemeral", "--json", "--skip-git-repo-check",
            "--color", "never", "-C", str(client), "-m", model, "-s", "read-only",
            "--output-last-message", str(answer)]
    overrides = {
        "approval_policy": "never", "web_search": "disabled", "project_doc_max_bytes": 0,
        "model_reasoning_effort": "high", "developer_instructions": INSTRUCTIONS,
        "mcp_servers.meetings.command": str(binary), "mcp_servers.meetings.args": ["--mcp-fixture", str(root)],
        "mcp_servers.meetings.startup_timeout_sec": 15, "mcp_servers.meetings.tool_timeout_sec": 45,
    }
    overrides.update({"features." + feature: False for feature in CODEX_DISABLED_FEATURES})
    for key, value in overrides.items():
        argv += ["-c", key + "=" + json.dumps(value, ensure_ascii=False)]
    return argv + [prompt]


def json_lines(path):
    result = []
    if path.exists():
        for line in path.read_text(errors="replace").splitlines():
            try:
                result.append(json.loads(line))
            except ValueError:
                pass
    return result


def describe(event):
    params = event["request"]["params"]
    name, args = params["name"], params.get("arguments", {})
    result = (event.get("response") or {}).get("result", {})
    text = "".join(item.get("text", "") for item in result.get("content", []))
    call = {"tool": name, "args": args, "bytes": len(text.encode()), "error": bool(result.get("isError"))}
    if name == "search_meetings":
        call["hits"] = len(re.findall(r"^s\d+ \S+ .*\(excerpt\):", text, re.M))
    return call


def run(agent, case_id, rep, output, binary, timeout):
    case = CASES[case_id]
    case_dir = output / agent / f"{case_id}-{rep}"
    case_dir.mkdir(parents=True)
    root = prepare(case_dir)
    client = case_dir / "client"
    client.mkdir()
    answer_file = case_dir / "answer.txt"
    began = time.monotonic()
    with (case_dir / "events.jsonl").open("w") as stdout, (case_dir / "stderr.txt").open("w") as stderr:
        try:
            code = subprocess.run(
                command(agent, binary, root, client, answer_file, case["prompt"]),
                stdin=subprocess.DEVNULL, stdout=stdout, stderr=stderr, cwd=client,
                env=dict(os.environ, TZ="Europe/Berlin"), timeout=timeout,
            ).returncode
        except subprocess.TimeoutExpired:
            code = 124
    events = json_lines(case_dir / "events.jsonl")
    cost = None
    if AGENTS[agent][0] == "claude":
        final = next((e for e in reversed(events) if e.get("type") == "result"), {})
        answer_file.write_text(final.get("result", ""))
        cost = final.get("total_cost_usd")
    answer = answer_file.read_text() if answer_file.exists() else ""
    calls = [describe(e) for e in json_lines(root / "mcp-trace.jsonl")
             if e.get("request", {}).get("method") == "tools/call"]
    lower = answer.casefold()
    missing = [fact for fact, pattern in case["facts"].items() if not re.search(pattern, lower)]
    result = {
        "agent": agent, "case": case_id, "rep": rep, "exit": code,
        "seconds": round(time.monotonic() - began, 1), "cost_usd": cost,
        "facts_found": len(case["facts"]) - len(missing), "facts_total": len(case["facts"]),
        "missing": missing,
        "decoys": [name for name, pattern in case["decoys"].items() if re.search(pattern, lower)],
        "calls": calls, "result_bytes": sum(c["bytes"] for c in calls), "artifacts": str(case_dir),
    }
    (case_dir / "result.json").write_text(json.dumps(result, ensure_ascii=False, indent=1) + "\n")
    return result


def report(results):
    by_agent = collections.defaultdict(list)
    for result in results:
        by_agent[result["agent"]].append(result)
    print(f'\n{"agent":14} {"runs":>4} {"facts":>7} {"calls":>6} {"searches":>8} {"empty":>6} {"read KB":>7} {"sec":>5} {"$":>6}')
    for agent, items in sorted(by_agent.items()):
        searches = [c for r in items for c in r["calls"] if c["tool"] == "search_meetings" and not c["error"]]
        empty = sum(1 for c in searches if c["hits"] == 0)
        costs = [r["cost_usd"] for r in items if r["cost_usd"] is not None]
        found = sum(r["facts_found"] for r in items)
        total = sum(r["facts_total"] for r in items)
        print(f'{agent:14} {len(items):4} {found:3}/{total:<3} '
              f'{sum(len(r["calls"]) for r in items) / len(items):6.1f} {len(searches) / len(items):8.1f} '
              f'{100 * empty / max(1, len(searches)):5.0f}% '
              f'{sum(r["result_bytes"] for r in items) / len(items) / 1000:7.1f} '
              f'{sum(r["seconds"] for r in items) / len(items):5.1f} '
              f'{sum(costs) / len(costs) if costs else float("nan"):6.3f}')


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--binary", type=Path, default=Path("build/MeetingNotesSmoke"))
    parser.add_argument("--agents", default=",".join(AGENTS), help="Comma-separated: " + ", ".join(AGENTS))
    parser.add_argument("--cases", default=",".join(CASES), help="Comma-separated: " + ", ".join(CASES))
    parser.add_argument("--repeat", type=int, default=1)
    parser.add_argument("--jobs", type=int, default=6)
    parser.add_argument("--timeout", type=int, default=600)
    args = parser.parse_args()
    agents, cases = args.agents.split(","), args.cases.split(",")
    unknown = (set(agents) - set(AGENTS)) | (set(cases) - set(CASES))
    if unknown:
        parser.error("Unknown agents or cases: " + ", ".join(sorted(unknown)))
    binary = args.binary.resolve(strict=True)
    output = Path(tempfile.mkdtemp(prefix="meeting-notes-search-eval-"))
    print("Artifacts: " + str(output), flush=True)
    jobs = [(a, c, r) for r in range(1, args.repeat + 1) for c in cases for a in agents]
    results = []
    with concurrent.futures.ThreadPoolExecutor(args.jobs) as pool:
        futures = [pool.submit(run, a, c, r, output, binary, args.timeout) for a, c, r in jobs]
        for future in concurrent.futures.as_completed(futures):
            result = future.result()
            results.append(result)
            searches = [c["args"].get("queries") for c in result["calls"] if c["tool"] == "search_meetings"]
            print(f'{result["agent"]:14} {result["case"]:13} #{result["rep"]} exit={result["exit"]} '
                  f'facts={result["facts_found"]}/{result["facts_total"]} calls={len(result["calls"])} '
                  f'{result["seconds"]}s missing={result["missing"]} decoys={result["decoys"]} '
                  f'searches={searches}', flush=True)
            (output / "results.json").write_text(json.dumps(results, ensure_ascii=False, indent=1) + "\n")
    report(results)
    print("Keyword grading is only a signal; read answer.txt for wrong or unsupported claims.")
    raise SystemExit(any(r["exit"] or r["missing"] for r in results))


if __name__ == "__main__":
    main()
