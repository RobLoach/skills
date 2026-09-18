#!/usr/bin/env python3
"""Validate every skill in skills/ before it reaches anyone's agent.

Checks, per skill:
  * SKILL.md exists and opens with a parseable `---` frontmatter block
  * frontmatter carries `name` and `description`, within the limits agents enforce
  * `name` matches the directory it lives in, and the `homepage` URL points at itself
  * every ```bash block parses under `bash -n`, once <placeholders> are substituted
  * every scripts/*.sh referenced by SKILL.md exists, and none sit there unreferenced
  * scripts marked `# SHARED:` are byte-identical in every skill that carries a copy
  * SKILL.md sections marked `<!-- SHARED: -->` are identical wherever they appear
  * scripts start with a shebang and pass shellcheck, when shellcheck is installed

Deliberately dependency-free, so it runs the same way in CI and on a laptop.
Run from the repository root. Exits 1 if anything failed.
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

NAME_RE = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")
NAME_MAX = 64
DESCRIPTION_MAX = 1024
PLACEHOLDER_RE = re.compile(r"<[^>\n]+>")
BASH_BLOCK_RE = re.compile(r"```bash\n(.*?)```", re.DOTALL)
SHARED_OPEN_RE = re.compile(r"^<!-- SHARED: (?P<name>[^>\n]+?) -->$", re.MULTILINE)

failures: list[str] = []


def fail(where: object, message: str) -> None:
    failures.append(f"{where}: {message}")


def unquote(value: str) -> str:
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        return value[1:-1]
    return value


def parse_frontmatter(text: str) -> tuple[dict | None, str | None]:
    """Parse the `key: value` frontmatter a SKILL.md uses.

    Handles top-level scalars plus one level of indented nesting, which is all a
    SKILL.md needs. Anything else is reported rather than guessed at.
    """
    if not text.startswith("---\n"):
        return None, "missing a `---` delimited frontmatter block at the top"
    end = text.find("\n---\n", 3)
    if end == -1:
        return None, "frontmatter block is never closed with `---`"

    data: dict = {}
    parent: str | None = None
    for lineno, raw in enumerate(text[4:end].split("\n"), start=2):
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        line = raw.strip()
        if ":" not in line:
            return None, (
                f"line {lineno}: expected `key: value`, got {line!r} "
                "(multi-line values are not supported)"
            )
        key, _, value = line.partition(":")
        key, value = key.strip(), unquote(value.strip())
        if raw[:1].isspace():
            if parent is None:
                return None, f"line {lineno}: indented {key!r} sits under no parent key"
            data[parent][key] = value
        elif value:
            data[key] = value
            parent = None
        else:
            data[key] = {}
            parent = key
    return data, None


def check_bash_blocks(path: Path, text: str) -> None:
    """Every documented snippet should at least be syntactically valid bash."""
    for index, block in enumerate(BASH_BLOCK_RE.findall(text), start=1):
        # <owner>, <number>, <this skill's directory> and friends are stand-ins the
        # agent substitutes; swap in a token so bash can parse the shape.
        candidate = PLACEHOLDER_RE.sub("PLACEHOLDER", block)
        result = subprocess.run(
            ["bash", "-n"], input=candidate, capture_output=True, text=True
        )
        if result.returncode != 0:
            fail(path, f"bash block {index} is not valid bash: {result.stderr.strip()}")


def check_frontmatter(skill_dir: Path, skill_md: Path, text: str) -> None:
    meta, error = parse_frontmatter(text)
    if error or meta is None:
        fail(skill_md, error or "frontmatter could not be parsed")
        return

    name = meta.get("name")
    if not name or not isinstance(name, str):
        fail(skill_md, "frontmatter is missing `name`")
    else:
        if name != skill_dir.name:
            fail(skill_md, f"`name: {name}` does not match directory {skill_dir.name!r}")
        if not NAME_RE.match(name):
            fail(skill_md, f"`name: {name}` must be lowercase words joined by hyphens")
        if len(name) > NAME_MAX:
            fail(skill_md, f"`name` is {len(name)} chars, over the {NAME_MAX} limit")

    description = meta.get("description")
    if not description or not isinstance(description, str) or not description.strip():
        fail(skill_md, "frontmatter is missing `description`")
    elif len(description) > DESCRIPTION_MAX:
        fail(
            skill_md,
            f"`description` is {len(description)} chars, over the {DESCRIPTION_MAX} limit",
        )

    metadata = meta.get("metadata")
    homepage = metadata.get("homepage") if isinstance(metadata, dict) else None
    if homepage and skill_dir.name not in homepage:
        fail(skill_md, f"`homepage` does not point at this skill: {homepage}")


def check_scripts(skill_dir: Path, text: str) -> None:
    scripts_dir = skill_dir / "scripts"
    referenced = set(re.findall(r"scripts/([A-Za-z0-9._-]+\.sh)", text))

    for name in sorted(referenced):
        if not (scripts_dir / name).is_file():
            fail(skill_dir, f"SKILL.md references scripts/{name}, which does not exist")

    if not scripts_dir.is_dir():
        return

    for script in sorted(scripts_dir.glob("*.sh")):
        if script.name not in referenced:
            fail(script, "not referenced anywhere in SKILL.md")
        if not script.read_text().startswith("#!"):
            fail(script, "missing a shebang line")


def check_shared_scripts(skill_dirs: list[Path]) -> None:
    """A script marked `# SHARED:` must be byte-identical everywhere it appears.

    Sharing is opt-in rather than inferred from the filename: two skills can each have
    their own `setup-worktree.sh` doing legitimately different things, so only the
    marker means "these are copies of one file".
    """
    by_name: dict[str, list[Path]] = {}
    for skill_dir in skill_dirs:
        for script in (skill_dir / "scripts").glob("*.sh"):
            by_name.setdefault(script.name, []).append(script)

    for name, paths in sorted(by_name.items()):
        marked = [p for p in sorted(paths) if "# SHARED:" in p.read_text()]
        if not marked:
            continue
        if len(marked) != len(paths):
            for unmarked in sorted(set(paths) - set(marked)):
                fail(unmarked, f"{marked[0]} marks {name} as SHARED, but this copy does not")
            continue
        first, *rest = marked
        for other in rest:
            if first.read_bytes() != other.read_bytes():
                fail(other, f"differs from {first}; SHARED copies of {name} must match")


def check_shared_sections(skill_dirs: list[Path]) -> None:
    """A SKILL.md block marked `<!-- SHARED: -->` must be identical wherever it appears.

    Skills are standalone copies, not includes of one source, so shared guidance
    drifts a sentence at a time unless something holds the copies together.
    """
    by_name: dict[str, dict[Path, str]] = {}

    for skill_dir in skill_dirs:
        skill_md = skill_dir / "SKILL.md"
        if not skill_md.is_file():
            continue
        text = skill_md.read_text()
        for opening in SHARED_OPEN_RE.finditer(text):
            name = opening.group("name")
            close_re = re.compile(
                rf"^<!-- /SHARED: {re.escape(name)} -->$", re.MULTILINE
            )
            closing = close_re.search(text, opening.end())
            if closing is None:
                fail(skill_md, f"missing closing `<!-- /SHARED: {name} -->`")
                continue
            copies = by_name.setdefault(name, {})
            if skill_md in copies:
                fail(skill_md, f"SHARED section {name} appears more than once")
                continue
            copies[skill_md] = text[opening.start() : closing.end()]

    for name, copies in sorted(by_name.items()):
        first, *rest = sorted(copies)
        for other in rest:
            if copies[first] != copies[other]:
                fail(other, f"differs from {first}; SHARED copies of {name} must match")


def shellcheck_usable() -> bool:
    """Finding `shellcheck` on PATH is not enough to know it runs.

    A version-manager shim (mise, asdf) resolves fine and then fails at invocation
    with its own error, which would otherwise be reported as a bogus shellcheck
    finding against the scripts. CI installs the real thing and asserts it separately,
    so skipping here only ever affects a laptop.
    """
    try:
        probe = subprocess.run(
            ["shellcheck", "--version"], capture_output=True, text=True
        )
    except OSError:
        return False
    return probe.returncode == 0


def run_shellcheck(skill_dirs: list[Path]) -> None:
    if not shellcheck_usable():
        print("note: shellcheck not usable here, skipping that check", file=sys.stderr)
        return
    scripts = sorted(
        str(p) for skill_dir in skill_dirs for p in (skill_dir / "scripts").glob("*.sh")
    )
    if not scripts:
        return
    result = subprocess.run(["shellcheck", *scripts], capture_output=True, text=True)
    if result.returncode != 0:
        fail("shellcheck", "\n" + (result.stdout or result.stderr).strip())


def main() -> int:
    root = Path(".")
    skills_root = root / "skills"
    if not skills_root.is_dir():
        print("no skills/ directory; run this from the repository root", file=sys.stderr)
        return 1

    skill_dirs = sorted(p for p in skills_root.iterdir() if p.is_dir())
    if not skill_dirs:
        print("skills/ contains no skills", file=sys.stderr)
        return 1

    for skill_dir in skill_dirs:
        skill_md = skill_dir / "SKILL.md"
        if not skill_md.is_file():
            fail(skill_dir, "has no SKILL.md")
            continue
        text = skill_md.read_text()
        check_frontmatter(skill_dir, skill_md, text)
        check_bash_blocks(skill_md, text)
        check_scripts(skill_dir, text)

    check_shared_scripts(skill_dirs)
    check_shared_sections(skill_dirs)
    run_shellcheck(skill_dirs)

    readme = root / "README.md"
    if readme.is_file():
        check_bash_blocks(readme, readme.read_text())

    if failures:
        print(f"{len(failures)} problem(s) found:\n", file=sys.stderr)
        for failure in failures:
            print(f"  - {failure}", file=sys.stderr)
        return 1

    print(f"All good: {', '.join(p.name for p in skill_dirs)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
