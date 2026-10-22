"""The lock the Desktop profile installs from stays hash-pinned and gateway-free.

The Desktop installer runs pip with --require-hashes against this file, and the
profile talks to llama-server directly, so the lock must never pull in an LLM
gateway such as LiteLLM.
"""

import re
from pathlib import Path

LOCK = Path(__file__).resolve().parent.parent / "requirements.lock"
_REQUIREMENT = re.compile(r"^([A-Za-z0-9][A-Za-z0-9._-]*)==\S+")


def _entries():
    entries, current = [], None
    for line in LOCK.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        match = _REQUIREMENT.match(stripped)
        if match:
            current = {"name": match.group(1).lower(), "hashes": 0}
            entries.append(current)
        assert current is not None, f"unpinned requirement line: {line!r}"
        current["hashes"] += stripped.count("--hash=sha256:")
    return entries


def test_every_locked_requirement_is_pinned_and_hashed():
    entries = _entries()
    assert entries
    assert [entry["name"] for entry in entries if entry["hashes"] == 0] == []


def test_lock_has_no_llm_gateway():
    names = {entry["name"] for entry in _entries()}
    assert not names & {"litellm", "litellm-proxy-extras", "litellm-enterprise"}
