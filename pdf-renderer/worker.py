#!/usr/bin/env python3
"""Claim and complete one A7 job from the authenticated A8 container."""

from __future__ import annotations

import json
import os
import re
import tempfile
import urllib.error
import urllib.request
from pathlib import Path

from renderer import RenderError, render


def post(endpoint: str, secret: str, payload: dict) -> dict | None:
    request = urllib.request.Request(
        endpoint,
        data=json.dumps(payload, separators=(",", ":")).encode("utf-8"),
        headers={"content-type": "application/json", "x-camp-pdf-worker-secret": secret},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def main() -> int:
    endpoint = os.environ.get("CAMP_PDF_WORKER_URL", "")
    secret = os.environ.get("CAMP_PDF_WORKER_SECRET", "")
    converter_image = os.environ.get("CAMP_PDF_CONVERTER_IMAGE", "")
    if (not endpoint.startswith("https://") or len(secret) < 32
        or not re.fullmatch(r"ghcr\.io/[a-z0-9._/-]+@sha256:[0-9a-f]{64}", converter_image)):
        raise SystemExit("authenticated worker configuration required")
    job = post(endpoint, secret, {"operation": "claim"})
    if not job:
        return 0
    with tempfile.TemporaryDirectory(prefix="camp-pdf-worker-") as directory:
        root = Path(directory)
        output = root / "application.pdf"
        try:
            validation = render(job, output, None, root / "qa")
        except Exception:
            try:
                post(endpoint, secret, {"operation": "fail", "jobId": job["job_id"], "attemptId": job["attempt_id"]})
            except (OSError, urllib.error.URLError):
                pass
            raise
        payload = {
            "operation": "complete",
            "jobId": job["job_id"],
            "attemptId": job["attempt_id"],
            "sourceHash": job["source_hash"],
            "pdfBase64": __import__("base64").b64encode(output.read_bytes()).decode("ascii"),
            "validation": validation,
        }
        # A lost completion response may mean A7 already committed immutable
        # bytes. Never follow an uncertain completion with `fail`.
        result = post(endpoint, secret, payload)
        if result != {"recorded": True}:
            raise RenderError("completion-not-recorded")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
