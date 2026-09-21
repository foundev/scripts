#!/usr/bin/env python3
"""Refresh a Codex model catalog from a Codex-format /models endpoint.

OpenRouter serves its catalog in Codex's own ModelInfo schema, so the entries
can be used directly by `model_catalog_json`. This script fetches that catalog,
drops the vendors you do not want, optionally normalizes the result through the
codex CLI, and writes the catalog your profile points at.

Usage:
  ./openrouter-catalog.py --out ~/.codex/or-models.json
  ./openrouter-catalog.py --dry-run
  ./openrouter-catalog.py --exclude anthropic/ --exclude openai/ --keep-aliases
  ./openrouter-catalog.py --min-context-window 200000
  ./openrouter-catalog.py --ensure-config ~/.codex/or.config.toml \
                          --require-model z-ai/glm-5.3-flash

Why the extra normalizing pass: the entries are fed back through
`codex debug models -c model_catalog_json=...` so the file holds the exact
model definitions Codex resolves (legacy aliases canonicalized, defaults
materialized, unknown fields dropped) instead of the raw wire form. Pass
--no-normalize to keep the provider's bytes verbatim.

Environment overrides:
  OPENROUTER_API_KEY  sent as a bearer token (the catalog endpoint is public)
  CODEX_BIN           codex binary used for normalization (default: codex)
  CATALOG_URL         catalog URL, instead of the OpenRouter default
  CATALOG_OUT         output path, same as --out

Exit code: 0 on success, 1 on failure.
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.request
from collections import Counter
from pathlib import Path

DEFAULT_URL = "https://openrouter.ai/api/v1/models"
DEFAULT_OUT = "~/.codex/or-models.json"
DEFAULT_EXCLUDES = ("anthropic/", "openai/")
IMMUTABLE_FIELDS = ("slug", "display_name", "context_window")


def codex_version(codex_bin):
    """Return the codex CLI version, or None when it cannot be determined."""
    try:
        out = subprocess.run(
            [codex_bin, "--version"],
            capture_output=True,
            text=True,
            timeout=60,
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    match = re.search(r"(\d+\.\d+\.\d+[\w.\-]*)", out)
    return match.group(1) if match else None


def catalog_url(override, codex_bin):
    """Build the catalog URL, tagging the request with the local codex version."""
    url = override or os.environ.get("CATALOG_URL") or DEFAULT_URL
    if "client_version=" in url:
        return url
    version = codex_version(codex_bin)
    if not version:
        return url
    separator = "&" if "?" in url else "?"
    return f"{url}{separator}client_version={version}"


def fetch(url, timeout=180):
    """Fetch and decode the catalog. Raises RuntimeError with a short reason."""
    request = urllib.request.Request(
        url,
        headers={
            "Accept": "application/json",
            "User-Agent": "codex-catalog-refresh/1",
        },
    )
    api_key = os.environ.get("OPENROUTER_API_KEY")
    if api_key:
        request.add_header("Authorization", f"Bearer {api_key}")
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            body = response.read()
    except OSError as error:
        raise RuntimeError(f"fetch failed: {error}") from error
    try:
        payload = json.loads(body)
    except json.JSONDecodeError as error:
        raise RuntimeError(f"response was not JSON: {error}") from error
    models = payload.get("models") if isinstance(payload, dict) else None
    if not models:
        raise RuntimeError("response had no 'models' array")
    return models


def select(models, excludes, keep_aliases, min_context_window):
    """Apply the catalog filters, reporting why each dropped model was dropped."""
    kept, dropped = [], Counter()
    for model in models:
        slug = model.get("slug")
        if not isinstance(slug, str) or not slug:
            dropped["malformed"] += 1
            continue
        if "/" not in slug:
            dropped["not provider-namespaced"] += 1
            continue
        if slug.startswith("~") and not keep_aliases:
            dropped["alias entry"] += 1
            continue
        if slug.startswith(tuple(excludes)):
            dropped["excluded vendor"] += 1
            continue
        context_window = model.get("context_window") or 0
        if min_context_window and context_window < min_context_window:
            dropped["below --min-context-window"] += 1
            continue
        kept.append(model)
    return kept, dropped


def run_codex_catalog(codex_bin, catalog_path, provider):
    """Round-trip the catalog through codex, returning Codex's canonical models."""
    command = [
        codex_bin,
        "debug",
        "models",
        "-c",
        f'model_catalog_json="{catalog_path}"',
    ]
    if provider:
        command += ["-c", f"model_provider={provider}"]
    completed = subprocess.run(
        command,
        capture_output=True,
        text=True,
        timeout=600,
    )
    if completed.returncode != 0:
        detail = (completed.stderr or "").strip().splitlines()
        detail = detail[-1] if detail else "no stderr"
        raise RuntimeError(f"{codex_bin} debug models failed: {detail}")
    payload = json.loads(completed.stdout)
    models = payload.get("models")
    if not models:
        raise RuntimeError(f"{codex_bin} debug models returned no models")
    return models


def normalize(models, codex_bin, provider):
    """Canonicalize entries by feeding them back through codex."""
    with tempfile.TemporaryDirectory(prefix="catalog-") as directory:
        candidate = Path(directory) / "candidate.json"
        candidate.write_text(json.dumps({"models": models}) + "\n")
        return run_codex_catalog(codex_bin, candidate, provider)


def verify(models, codex_bin, provider):
    """Confirm the chosen entries survive a codex round-trip unchanged."""
    with tempfile.TemporaryDirectory(prefix="catalog-") as directory:
        candidate = Path(directory) / "verify.json"
        candidate.write_text(json.dumps({"models": models}) + "\n")
        reparsed = run_codex_catalog(codex_bin, candidate, provider)
    # codex re-emits the legacy base_instructions mirror on the way out, so
    # compare the slimmed form of both sides.
    if slim(reparsed) != models:
        raise RuntimeError("catalog does not round-trip through codex unchanged")
    return reparsed


def slim(models):
    """Drop the legacy top-level instruction mirror that duplicates model_messages."""
    trimmed = []
    for model in models:
        entry = dict(model)
        template = (entry.get("model_messages") or {}).get("instructions_template")
        if template is not None:
            entry.pop("base_instructions", None)
        trimmed.append(entry)
    return trimmed


def write_catalog(path, models):
    """Write the catalog atomically, keeping the previous version as .bak."""
    path.parent.mkdir(parents=True, exist_ok=True)
    mode = None
    if path.exists():
        shutil.copy2(path, path.with_name(path.name + ".bak"))
        mode = path.stat().st_mode & 0o777
    handle, temporary = tempfile.mkstemp(dir=path.parent, prefix=path.name, suffix=".tmp")
    try:
        with os.fdopen(handle, "w") as stream:
            json.dump({"models": models}, stream, indent=2)
            stream.write("\n")
        if mode is not None:
            os.chmod(temporary, mode)
        os.replace(temporary, path)
    except BaseException:
        os.unlink(temporary)
        raise


def ensure_config(config_path, out_value):
    """Make sure the profile config references the catalog path we just wrote."""
    path = config_path.expanduser()
    text = path.read_text()
    line = f'model_catalog_json = "{out_value}"'
    lines = [
        existing
        for existing in text.splitlines()
        if not existing.lstrip().startswith("model_catalog_json")
    ]
    # Top-level keys must stay above the first [table] header.
    insert_at = 0
    for index, existing in enumerate(lines):
        if existing.lstrip().startswith("["):
            break
        if existing.strip():
            insert_at = index + 1
    lines.insert(insert_at, line)
    shutil.copy2(path, path.with_name(path.name + ".bak"))
    path.write_text("\n".join(lines) + "\n")
    return line


def parse_args(argv):
    parser = argparse.ArgumentParser(
        description="Refresh a Codex model catalog from a Codex-format /models endpoint.",
    )
    parser.add_argument("--out", default=os.environ.get("CATALOG_OUT", DEFAULT_OUT),
                        help=f"catalog to write (default: {DEFAULT_OUT})")
    parser.add_argument("--url", default=None, help="catalog URL override")
    parser.add_argument("--exclude", action="append", default=None, metavar="PREFIX",
                        help="vendor prefix to drop, repeatable "
                             f"(default: {' '.join(DEFAULT_EXCLUDES)})")
    parser.add_argument("--keep-aliases", action="store_true",
                        help="keep ~-prefixed latest aliases")
    parser.add_argument("--min-context-window", type=int, default=0, metavar="TOKENS",
                        help="drop models with a smaller context window")
    parser.add_argument("--require-model", action="append", default=[], metavar="SLUG",
                        help="fail unless this slug is present, repeatable")
    parser.add_argument("--provider", default=None, metavar="NAME",
                        help="model_provider for the normalizing codex run")
    parser.add_argument("--codex-bin", default=os.environ.get("CODEX_BIN", "codex"),
                        help="codex binary (default: codex)")
    parser.add_argument("--no-normalize", action="store_true",
                        help="write the provider's entries verbatim")
    parser.add_argument("--no-verify", action="store_true",
                        help="skip the round-trip check")
    parser.add_argument("--ensure-config", default=None, metavar="PATH",
                        help="also point this profile config at the catalog")
    parser.add_argument("--print-models", action="store_true",
                        help="list the kept slugs on stdout")
    parser.add_argument("--dry-run", action="store_true",
                        help="report what would happen without writing")
    return parser.parse_args(argv)


def main(argv):
    args = parse_args(argv)
    excludes = tuple(args.exclude) if args.exclude else DEFAULT_EXCLUDES
    out = Path(args.out).expanduser()

    url = catalog_url(args.url, args.codex_bin)
    print(f"catalog: {url}")
    try:
        source = fetch(url)
    except RuntimeError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    models, dropped = select(source, excludes, args.keep_aliases, args.min_context_window)
    print(f"fetched {len(source)} models, kept {len(models)}")
    for reason, count in dropped.most_common():
        print(f"  dropped {count}: {reason}")
    if not models:
        print("error: every model was filtered out", file=sys.stderr)
        return 1

    missing = [slug for slug in args.require_model
               if slug not in {model.get("slug") for model in models}]
    if missing:
        print(f"error: required model(s) missing: {', '.join(missing)}", file=sys.stderr)
        return 1

    if args.no_normalize:
        final = models
    else:
        try:
            final = slim(normalize(models, args.codex_bin, args.provider))
            if not args.no_verify:
                verify(final, args.codex_bin, args.provider)
        except (OSError, subprocess.SubprocessError, RuntimeError, json.JSONDecodeError) as error:
            print(f"error: normalization failed: {error}", file=sys.stderr)
            return 1
        print(f"normalized {len(final)} models through {args.codex_bin}")

    for field in IMMUTABLE_FIELDS:
        if any(not model.get(field) for model in final):
            print(f"error: an entry is missing {field}", file=sys.stderr)
            return 1

    if args.print_models:
        for model in final:
            print(model["slug"])

    if args.dry_run:
        print(f"dry run: would write {len(final)} models to {out}")
        return 0

    write_catalog(out, final)
    size_mb = out.stat().st_size / 1e6
    print(f"wrote {len(final)} models to {out} ({size_mb:.1f} MB)")

    if args.ensure_config:
        line = ensure_config(Path(args.ensure_config), args.out)
        print(f"updated {args.ensure_config}: {line}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
