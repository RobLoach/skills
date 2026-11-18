#!/usr/bin/env python3
"""Validate every skill in skills/ before it reaches anyone's agent.

Checks, per skill:
  * SKILL.md exists and opens with a `---` frontmatter block that real YAML loaders accept
  * frontmatter carries `name` and `description`, within the limits agents enforce
  * `name` matches the directory, `metadata.homepage` is exactly this skill's GitHub URL,
    and no `github-*` metadata keys (added by `gh skills install`) are committed
  * every ```bash, ```sh and ```shell block parses under `bash -n`, once <placeholders>
    are substituted - in every SKILL.md, README.md and AGENTS.md
  * every scripts/*.sh referenced by SKILL.md exists, and none sit there unreferenced
  * scripts marked `# SHARED:` are byte-identical in every skill that carries a copy
  * a script's `Exit codes:` block lists exactly the codes it really exits with
  * SKILL.md says what to do about every exit code a script can hand back, at every
    place the script is called
  * SKILL.md sections marked `<!-- SHARED: -->` are well-formed, paired, unnested, used
    by at least two skills, and identical wherever they appear
  * README.md names every skill as `/<name>`, and its `#anchor` links resolve
  * scripts start with a shebang and pass shellcheck, when shellcheck is installed

Needs only python3. PyYAML is used as an extra frontmatter check when importable; the
built-in parser is stricter than YAML, so results do not depend on it being there.
Run from the repository root. Exits 1 if anything failed.
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

try:
    import yaml  # type: ignore[import-untyped]
except ImportError:  # Optional: the built-in parser below is the real gate.
    yaml = None

NAME_RE = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")
NAME_MAX = 64
DESCRIPTION_MAX = 1024
PLACEHOLDER_RE = re.compile(r"<[^>\n]+>")
SHELL_BLOCK_RE = re.compile(
    r"^[ \t]*```(?P<lang>bash|sh|shell)[ \t]*\n(?P<body>.*?)^[ \t]*```[ \t]*$",
    re.DOTALL | re.MULTILINE,
)
FENCE_RE = re.compile(r"^[ \t]*(```|~~~)")
HEADING_RE = re.compile(r"^(#{1,6})[ \t]+(.*?)[ \t#]*$")
SHARED_MARKER_RE = re.compile(r"^<!-- (?P<close>/?)SHARED: (?P<name>[a-z0-9]+(?:-[a-z0-9]+)*) -->$")
# Anything that looks like it was meant to be a marker, so a typo is reported rather than
# silently turning a shared section into an unchecked one.
SHARED_LOOSE_RE = re.compile(r"<!--\s*/?\s*SHARED", re.IGNORECASE)
SCRIPT_REF_RE = re.compile(r"scripts/([A-Za-z0-9._-]+\.sh)")
HOMEPAGE = "https://github.com/RobLoach/skills/blob/main/skills/{name}/SKILL.md"
# Characters that make a plain YAML scalar mean something else when they lead it.
YAML_INDICATORS = "[]{},&*!|>'\"%@`#"

failures: list[str] = []


def fail(where: object, message: str) -> None:
    failures.append(f"{where}: {message}")


def scalar(value: str) -> tuple[str | None, str | None]:
    """Decode one frontmatter value, refusing anything YAML would read differently.

    A plain (unquoted) scalar is easy to write wrongly: `description: Note: fix one` is
    a YAML error, `x #y` silently loses `#y`, and a leading `&`, `*`, `|`, `>` and so on
    change the meaning entirely. Agents load frontmatter with real YAML parsers, so any
    of these must be quoted rather than accepted here and broken there.
    """
    if value[:1] in "\"'":
        quote = value[0]
        if len(value) < 2 or value[-1] != quote:
            return None, f"unterminated {quote}-quoted value"
        inner = value[1:-1]
        if quote == "'":
            if re.search(r"(?<!')'(?!')", inner.replace("''", "")):
                return None, "single-quoted value has an undoubled `'` inside"
            return inner.replace("''", "'"), None
        if re.search(r'(?<!\\)"', inner) or "\\" in inner:
            return None, "double-quoted value has an inner `\"` or `\\` escape; avoid both"
        return inner, None
    if value[:1] in YAML_INDICATORS or value[:2] in ("- ", "? ", ": "):
        return None, f"unquoted value starts with YAML indicator {value[:1]!r}; quote it"
    if ": " in value or value.endswith(":"):
        return None, "unquoted value contains `: `, which YAML rejects; quote it"
    if " #" in value or "\t#" in value:
        return None, "unquoted value contains ` #`, which YAML reads as a comment; quote it"
    return value, None


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
        key = key.strip()
        if not re.fullmatch(r"[A-Za-z0-9_-]+", key):
            return None, f"line {lineno}: key {key!r} is not a plain identifier"
        if value and not value[:1].isspace():
            return None, f"line {lineno}: expected a space after `{key}:`"
        value, problem = scalar(value.strip()) if value.strip() else ("", None)
        if problem or value is None:
            return None, f"line {lineno}: {key}: {problem}"
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

    if yaml is not None:
        # Belt and braces: whatever the parser above accepted, a real loader must too.
        try:
            loaded = yaml.safe_load(text[4:end])
        except yaml.YAMLError as error:
            return None, f"YAML loader rejects the frontmatter: {error}".replace("\n", " ")
        if not isinstance(loaded, dict):
            return None, "frontmatter does not load as a YAML mapping"
    return data, None


def check_bash_blocks(path: Path, text: str) -> None:
    """Every documented shell snippet should at least be syntactically valid bash."""
    for index, match in enumerate(SHELL_BLOCK_RE.finditer(text), start=1):
        # <owner>, <number>, <this skill's directory> and friends are stand-ins the
        # agent substitutes; swap in a token so bash can parse the shape.
        candidate = PLACEHOLDER_RE.sub("PLACEHOLDER", match.group("body"))
        result = subprocess.run(
            ["bash", "-n"], input=candidate, capture_output=True, text=True
        )
        if result.returncode != 0:
            line = text.count("\n", 0, match.start()) + 1
            fail(
                f"{path}:{line}",
                f"{match.group('lang')} block {index} is not valid bash: "
                f"{result.stderr.strip()}",
            )


def headings(text: str) -> list[tuple[int, int, str]]:
    """(offset, level, title) for every Markdown heading outside a code fence.

    `# comment` lines inside a bash block, and `### Problem/Motivation` inside an issue
    template, are not headings - so fences have to be tracked rather than grepped past.
    """
    found = []
    offset = 0
    fence: str | None = None
    for line in text.split("\n"):
        opener = FENCE_RE.match(line)
        if opener:
            if fence is None:
                fence = opener.group(1)
            elif opener.group(1) == fence:
                fence = None
        elif fence is None:
            heading = HEADING_RE.match(line)
            if heading:
                found.append((offset, len(heading.group(1)), heading.group(2)))
        offset += len(line) + 1
    return found


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
    if not isinstance(metadata, dict):
        fail(skill_md, "frontmatter is missing a `metadata` block")
        metadata = {}
    expected = HOMEPAGE.format(name=skill_dir.name)
    homepage = metadata.get("homepage")
    if homepage != expected:
        fail(skill_md, f"`metadata.homepage` is {homepage!r}, expected {expected}")
    for key in sorted([*meta, *metadata]):
        if key.startswith("github-"):
            fail(
                skill_md,
                f"`{key}` is added by `gh skills install`, and must not be committed",
            )


def check_scripts(skill_dir: Path, text: str) -> None:
    scripts_dir = skill_dir / "scripts"
    referenced = set(SCRIPT_REF_RE.findall(text))

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
    drifts a sentence at a time unless something holds the copies together. That only
    works if every marker is seen: a malformed one, an unpaired one, or a name only one
    skill uses would each let a section drift with nothing compared, so all of those
    fail rather than pass quietly.
    """
    by_name: dict[str, dict[Path, str]] = {}
    broken = len(failures)

    for skill_dir in skill_dirs:
        skill_md = skill_dir / "SKILL.md"
        if not skill_md.is_file():
            continue
        text = skill_md.read_text()
        lines = text.split("\n")
        open_name: str | None = None
        open_line = 0
        for lineno, line in enumerate(lines, start=1):
            if not SHARED_LOOSE_RE.search(line):
                continue
            where = f"{skill_md}:{lineno}"
            marker = SHARED_MARKER_RE.match(line)
            if marker is None:
                fail(
                    where,
                    f"malformed SHARED marker {line!r}; expected exactly "
                    "`<!-- SHARED: name -->` or `<!-- /SHARED: name -->` on its own line",
                )
                continue
            name = marker.group("name")
            if not marker.group("close"):
                if open_name is not None:
                    fail(where, f"SHARED {name} opens inside {open_name} (line {open_line}); nesting is not allowed")
                    continue
                open_name, open_line = name, lineno
                continue
            if open_name is None:
                fail(where, f"`<!-- /SHARED: {name} -->` closes a section that was never opened")
                continue
            if name != open_name:
                fail(where, f"`<!-- /SHARED: {name} -->` closes {open_name}, opened on line {open_line}")
                open_name = None  # Treat it as closed, so one typo is one failure.
                continue
            copies = by_name.setdefault(name, {})
            if skill_md in copies:
                fail(where, f"SHARED section {name} appears more than once")
            else:
                copies[skill_md] = "\n".join(lines[open_line - 1 : lineno])
            open_name = None
        if open_name is not None:
            fail(f"{skill_md}:{open_line}", f"SHARED {open_name} is never closed")

    # A broken marker usually strands its partners as one-offs; report the cause alone.
    broken = len(failures) > broken
    for name, copies in sorted(by_name.items()):
        first, *rest = sorted(copies)
        if not rest and not broken:
            fail(
                first,
                f"SHARED section {name} appears in no other SKILL.md, so nothing "
                "holds it to anything; share it or drop the markers",
            )
        for other in rest:
            if copies[first] != copies[other]:
                fail(other, f"differs from {first}; SHARED copies of {name} must match")


def check_exit_codes(skill_dirs: list[Path]) -> None:
    """A script's documented exit codes and its real ones must agree.

    Every skill here hands control back to the agent through an exit code, and the header
    comment is the only contract for what each one means. A code that is raised but
    undocumented leaves the agent guessing; a code that is documented but never raised is
    a branch somebody is waiting for that can never arrive. Neither shows up in a syntax
    check, so compare the two lists directly.

    Three legitimate patterns would otherwise read as mismatches, so each disables the
    half of the check it defeats:
      * `exit "$STATUS"` passes another command's code straight through, so which codes
        can appear is unknowable here - that script's documented-but-unraised list is
        skipped rather than guessed at.
      * A header saying "Any other non-zero" is deliberately open-ended, so its
        raised-but-undocumented list is skipped.
      * `exit 4 ;;` inside a `case` is still a literal exit, and is matched as one.

    64 is the usage error every script shares and is not worth documenting each time.
    0 needs no `exit 0`, since falling off the end means the same thing.
    """
    for skill_dir in skill_dirs:
        for script in sorted((skill_dir / "scripts").glob("*.sh")):
            text = script.read_text()

            header = re.search(
                r"^# Exit codes:\n(?P<body>(?:#.*\n)+)", text, re.MULTILINE
            )
            # Comment lines are dropped first: the header itself talks about exit codes,
            # and `exit 4 ;;` is a real exit that sits after a `case` pattern rather than
            # at the start of its line, so neither end can be anchored.
            code_lines = [
                line for line in text.split("\n") if not line.lstrip().startswith("#")
            ]
            code = "\n".join(code_lines)
            raised = {int(m) for m in re.findall(r"\bexit\s+(\d+)\b", code)}
            raised.discard(64)
            passes_through = re.search(r"\bexit\s+\"?\$", code) is not None

            if header is None:
                if raised - {0}:
                    fail(script, "raises exit codes but documents no `# Exit codes:` block")
                continue

            body = header.group("body")
            documented = {
                int(m) for m in re.findall(r"^#\s+(\d+)\s", body, re.MULTILINE)
            }
            documented.discard(64)
            open_ended = "any other non-zero" in body.lower()

            if not open_ended:
                for code in sorted(raised - documented - {0}):
                    fail(
                        script,
                        f"exits {code}, which its `Exit codes:` block does not document",
                    )
            if not passes_through:
                for code in sorted(documented - raised - {0}):
                    fail(script, f"documents exit {code}, which it never raises")


def check_handled_exit_codes(skill_dirs: list[Path]) -> None:
    """Every exit code a script can hand back must be one SKILL.md tells the agent to act on.

    check_exit_codes above keeps a script honest with itself. This keeps the SKILL.md
    honest with the script, which is the end that actually matters: the exit code only
    exists to steer the agent, so a code with no instruction beside it is a branch the
    agent meets at runtime with nothing to go on. That gap reads as complete from either
    file alone - the script documents the code, the SKILL.md documents a workflow - and is
    only visible by comparing the two.

    Every place a SKILL.md names `scripts/<name>.sh` is a call site, and each one is
    checked on its own: the agent acts on the prose beside the call it is making, not on
    bullets two steps away. A call site's region runs to the next call site of any script,
    or to the next heading at the same or a higher level than the one it sits under -
    so a `####` subsection still belongs to its step, and a step that runs two scripts
    does not credit one with the other's bullets. Both bullet lists (`- **4** - ...`)
    and inline prose ("exit **5** means") count; the agent reads either.

    The same two escapes as above apply, per region and for the same reasons: a region
    saying "any other non-zero" has covered everything by definition, and a script that
    passes another command's code through can hand back codes no list could enumerate.
    """
    for skill_dir in skill_dirs:
        skill_md = skill_dir / "SKILL.md"
        if not skill_md.is_file():
            continue
        text = skill_md.read_text()
        heads = headings(text)
        calls = [(m.start(), m.group(1)) for m in SCRIPT_REF_RE.finditer(text)]

        regions: dict[str, list[tuple[int, str]]] = {}
        for index, (start, name) in enumerate(calls):
            enclosing = [level for offset, level, _ in heads if offset < start]
            level = enclosing[-1] if enclosing else 6
            end = calls[index + 1][0] if index + 1 < len(calls) else len(text)
            for offset, head_level, _ in heads:
                if start < offset < end and head_level <= level:
                    end = offset
                    break
            line = text.count("\n", 0, start) + 1
            regions.setdefault(name, []).append((line, text[start:end]))

        for script in sorted((skill_dir / "scripts").glob("*.sh")):
            body = script.read_text()
            code = "\n".join(
                line for line in body.split("\n") if not line.lstrip().startswith("#")
            )
            raised = {int(m) for m in re.findall(r"\bexit\s+(\d+)\b", code)} - {0, 64}

            header = re.search(r"^# Exit codes:\n(?P<body>(?:#.*\n)+)", body, re.MULTILINE)
            if header and re.search(r"\bexit\s+\"?\$", code):
                # Pass-through: the header's list is the contract, not the literals here.
                raised |= {
                    int(m) for m in re.findall(r"^#\s+(\d+)\s", header.group("body"), re.MULTILINE)
                } - {0, 64}
            if not raised:
                continue

            # A script nobody references is reported by check_scripts already.
            for line, region in regions.get(script.name, []):
                if "any other non-zero" in region.lower():
                    continue
                handled = {int(m) for m in re.findall(r"\*\*(\d+)\*\*", region)}
                for missing in sorted(raised - handled):
                    fail(
                        f"{skill_md}:{line}",
                        f"scripts/{script.name} can exit {missing}, but nothing after "
                        "this call says what the agent should do about it",
                    )


def slug(title: str) -> str:
    """GitHub's heading anchor: lowercase, punctuation dropped, spaces to hyphens."""
    title = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", title)  # [text](url) -> text
    title = re.sub(r"<[^>]+>", "", title)
    return re.sub(r"[^\w\- ]", "", title.strip().lower()).replace(" ", "-")


def check_readme(readme: Path, skill_dirs: list[Path]) -> None:
    """README.md is the install page: every skill on it, and no link that goes nowhere."""
    text = readme.read_text()
    for skill_dir in skill_dirs:
        if not re.search(rf"/{re.escape(skill_dir.name)}(?![a-z0-9-])", text):
            fail(readme, f"never mentions `/{skill_dir.name}`; list it with the slash commands")

    anchors: set[str] = set()
    seen: dict[str, int] = {}
    for _, _, title in headings(text):
        base = slug(title)
        count = seen.get(base, 0)
        seen[base] = count + 1
        anchors.add(base if count == 0 else f"{base}-{count}")
    for match in re.finditer(r"\]\(#([^)\s]+)\)", text):
        if match.group(1) not in anchors:
            line = text.count("\n", 0, match.start()) + 1
            fail(f"{readme}:{line}", f"link to #{match.group(1)} matches no heading")


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
    check_exit_codes(skill_dirs)
    check_handled_exit_codes(skill_dirs)
    check_shared_sections(skill_dirs)
    run_shellcheck(skill_dirs)

    readme = root / "README.md"
    if readme.is_file():
        check_bash_blocks(readme, readme.read_text())
        check_readme(readme, skill_dirs)
    else:
        fail(readme, "missing")
    agents = root / "AGENTS.md"
    if agents.is_file():
        check_bash_blocks(agents, agents.read_text())

    if failures:
        print(f"{len(failures)} problem(s) found:\n", file=sys.stderr)
        for failure in failures:
            print(f"  - {failure}", file=sys.stderr)
        return 1

    print(f"All good: {', '.join(p.name for p in skill_dirs)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
