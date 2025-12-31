#!/usr/bin/env python3
"""Parse Claude session history to extract file edits."""

import json
import sys
from pathlib import Path
from typing import Optional

HISTORY_DIR = Path.home() / ".claude/projects/-Users-eriklangille-Projects-clauntty"


def find_edits(session_file: Path, file_filter: Optional[str] = None, content_filter: Optional[str] = None):
    """Find all Edit tool uses in a session file."""
    edits = []

    with open(session_file) as f:
        for line_num, line in enumerate(f, 1):
            try:
                entry = json.loads(line)
            except json.JSONDecodeError:
                continue

            # Look for tool results that show file edits
            if "toolUseResult" in entry:
                result = entry["toolUseResult"]
                if "filePath" in result and "newString" in result:
                    file_path = result.get("filePath", "")
                    new_string = result.get("newString", "")
                    old_string = result.get("oldString", "")

                    # Apply filters
                    if file_filter and file_filter not in file_path:
                        continue
                    if content_filter and content_filter not in new_string and content_filter not in old_string:
                        continue

                    edits.append({
                        "line": line_num,
                        "file": file_path,
                        "old": old_string,
                        "new": new_string,
                    })

    return edits


def find_writes(session_file: Path, file_filter: Optional[str] = None, content_filter: Optional[str] = None):
    """Find all Write tool uses in a session file."""
    writes = []

    with open(session_file) as f:
        for line_num, line in enumerate(f, 1):
            try:
                entry = json.loads(line)
            except json.JSONDecodeError:
                continue

            # Look for Write tool uses in assistant messages
            msg = entry.get("message", {})
            if msg.get("role") == "assistant":
                content = msg.get("content", [])
                for block in content:
                    if block.get("type") == "tool_use" and block.get("name") == "Write":
                        inp = block.get("input", {})
                        file_path = inp.get("file_path", "")
                        file_content = inp.get("content", "")

                        if file_filter and file_filter not in file_path:
                            continue
                        if content_filter and content_filter not in file_content:
                            continue

                        writes.append({
                            "line": line_num,
                            "file": file_path,
                            "content": file_content,
                        })

    return writes


def list_sessions():
    """List all session files."""
    sessions = list(HISTORY_DIR.glob("*.jsonl"))
    sessions.sort(key=lambda p: p.stat().st_mtime, reverse=True)

    for s in sessions[:20]:
        size = s.stat().st_size / 1024
        print(f"{s.name}: {size:.1f}KB")


def main():
    import argparse
    parser = argparse.ArgumentParser(description="Parse Claude session history")
    parser.add_argument("--list", action="store_true", help="List session files")
    parser.add_argument("--session", "-s", help="Session file name (partial match)")
    parser.add_argument("--file", "-f", help="Filter by file path")
    parser.add_argument("--content", "-c", help="Filter by content")
    parser.add_argument("--writes", action="store_true", help="Show Write operations instead of Edits")
    parser.add_argument("--full", action="store_true", help="Show full content")

    args = parser.parse_args()

    if args.list:
        list_sessions()
        return

    # Find session file
    if args.session:
        matches = list(HISTORY_DIR.glob(f"*{args.session}*.jsonl"))
        if not matches:
            print(f"No session matching '{args.session}'")
            return
        session_file = matches[0]
    else:
        # Use most recent
        sessions = list(HISTORY_DIR.glob("*.jsonl"))
        sessions.sort(key=lambda p: p.stat().st_mtime, reverse=True)
        session_file = sessions[0]

    print(f"Session: {session_file.name}")
    print()

    if args.writes:
        results = find_writes(session_file, args.file, args.content)
        for w in results:
            print(f"=== Line {w['line']}: WRITE {w['file']} ===")
            if args.full:
                print(w["content"])
            else:
                lines = w["content"].split("\n")
                print(f"  ({len(lines)} lines, {len(w['content'])} chars)")
                print("  First 5 lines:")
                for line in lines[:5]:
                    print(f"    {line[:80]}")
            print()
    else:
        results = find_edits(session_file, args.file, args.content)
        for e in results:
            print(f"=== Line {e['line']}: EDIT {e['file']} ===")
            if args.full:
                print("OLD:")
                print(e["old"])
                print("\nNEW:")
                print(e["new"])
            else:
                print(f"  old: {len(e['old'])} chars")
                print(f"  new: {len(e['new'])} chars")
                # Show first line of each
                old_first = e["old"].split("\n")[0][:60] if e["old"] else ""
                new_first = e["new"].split("\n")[0][:60] if e["new"] else ""
                print(f"  old starts: {old_first}...")
                print(f"  new starts: {new_first}...")
            print()

    print(f"Found {len(results)} {'writes' if args.writes else 'edits'}")


if __name__ == "__main__":
    main()
