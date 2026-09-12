#!/usr/bin/env python3
"""Deterministic DOCX merge and one-page PDF validation for camp applications."""

from __future__ import annotations

import argparse
import base64
import copy
import hashlib
import json
import os
import re
import shutil
import subprocess
import tempfile
import zipfile
from datetime import date
from pathlib import Path
from xml.etree import ElementTree as ET


ROOT = Path(__file__).resolve().parent
MANIFEST_PATH = ROOT / "render-settings.json"
NS = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
W = f"{{{NS}}}"
ET.register_namespace("w", NS)


class RenderError(RuntimeError):
    pass


def runtime_settings() -> dict:
    settings = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    image = os.environ.get("CAMP_PDF_CONVERTER_IMAGE")
    if image:
        if not re.fullmatch(r"ghcr\.io/[a-z0-9._/-]+@sha256:[0-9a-f]{64}", image):
            raise RenderError("invalid-converter-image")
        settings["converter_image"] = image
    return settings


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def require_text(value: object, name: str, maximum: int, *, optional: bool = False) -> str:
    if value is None and optional:
        return ""
    if not isinstance(value, str):
        raise RenderError(f"invalid-{name}")
    normalized = value.strip()
    if (not optional and not normalized) or len(normalized) > maximum or any(ord(c) < 32 and c not in "\n\t" for c in normalized):
        raise RenderError(f"invalid-{name}")
    return normalized


def parse_iso_date(value: object, name: str) -> date:
    try:
        return date.fromisoformat(str(value))
    except (TypeError, ValueError) as exc:
        raise RenderError(f"invalid-{name}") from exc


def wareki(value: date) -> str:
    if value >= date(2019, 5, 1):
        return f"令和{value.year - 2018}年{value.month}月{value.day}日"
    if value >= date(1989, 1, 8):
        return f"平成{value.year - 1988}年{value.month}月{value.day}日"
    raise RenderError("unsupported-era")


def run(command: list[str], **kwargs) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(command, check=True, text=True, capture_output=True, **kwargs)
    except (OSError, subprocess.CalledProcessError) as exc:
        stderr = getattr(exc, "stderr", "")
        raise RenderError(f"command-failed:{Path(command[0]).name}:{stderr[-400:]}") from exc


def set_run_font(run: ET.Element, font_name: str, size_half_points: int) -> None:
    rpr = run.find(f"{W}rPr")
    if rpr is None:
        rpr = ET.Element(f"{W}rPr")
        run.insert(0, rpr)
    fonts = rpr.find(f"{W}rFonts")
    if fonts is None:
        fonts = ET.SubElement(rpr, f"{W}rFonts")
    for key in ("ascii", "hAnsi", "eastAsia", "cs"):
        fonts.set(f"{W}{key}", font_name)
    for key in ("asciiTheme", "hAnsiTheme", "eastAsiaTheme", "cstheme"):
        fonts.attrib.pop(f"{W}{key}", None)
    for tag in ("sz", "szCs"):
        size = rpr.find(f"{W}{tag}")
        if size is None:
            size = ET.SubElement(rpr, f"{W}{tag}")
        size.set(f"{W}val", str(size_half_points))


def replace_paragraph(paragraph: ET.Element, text: str, font_name: str, size: int = 20) -> None:
    ppr = paragraph.find(f"{W}pPr")
    for child in list(paragraph):
        if child is not ppr:
            paragraph.remove(child)
    run_element = ET.SubElement(paragraph, f"{W}r")
    set_run_font(run_element, font_name, size)
    text_element = ET.SubElement(run_element, f"{W}t")
    if text.startswith(" ") or text.endswith(" "):
        text_element.set("{http://www.w3.org/XML/1998/namespace}space", "preserve")
    text_element.text = text


def patch_all_fonts(root: ET.Element, font_name: str) -> None:
    for run in root.findall(f".//{W}r"):
        current = run.find(f"{W}rPr/{W}sz")
        set_run_font(run, font_name, int(current.get(f"{W}val", "24")) if current is not None else 24)
    for fonts in root.findall(f".//{W}rFonts"):
        for key in ("ascii", "hAnsi", "eastAsia", "cs"):
            fonts.set(f"{W}{key}", font_name)
        for key in ("asciiTheme", "hAnsiTheme", "eastAsiaTheme", "cstheme"):
            fonts.attrib.pop(f"{W}{key}", None)


def apply_change_state(root: ET.Element, previously_approved: bool) -> None:
    token = "（変更）"
    matches = 0

    def set_text(run: ET.Element, value: str) -> None:
        rpr = run.find(f"{W}rPr")
        for child in list(run):
            if child is not rpr:
                run.remove(child)
        text = ET.SubElement(run, f"{W}t")
        text.text = value

    for parent in root.iter():
        for run in list(parent):
            if run.tag != f"{W}r":
                continue
            value = "".join(node.text or "" for node in run.findall(f"{W}t"))
            occurrences = value.count(token)
            if occurrences == 0:
                continue
            matches += occurrences
            parts = value.split(token)
            replacements: list[ET.Element] = []
            for index, part in enumerate(parts):
                if part:
                    plain = copy.deepcopy(run)
                    set_text(plain, part)
                    replacements.append(plain)
                if index < occurrences:
                    marked = copy.deepcopy(run)
                    set_text(marked, token)
                    rpr = marked.find(f"{W}rPr")
                    if rpr is None:
                        rpr = ET.Element(f"{W}rPr")
                        marked.insert(0, rpr)
                    strike = rpr.find(f"{W}strike")
                    if previously_approved:
                        if strike is not None:
                            rpr.remove(strike)
                    elif strike is None:
                        ET.SubElement(rpr, f"{W}strike")
                    replacements.append(marked)
            position = list(parent).index(run)
            parent.remove(run)
            for replacement in reversed(replacements):
                parent.insert(position, replacement)
    if matches != 2:
        raise RenderError("template-structure-mismatch")


def scrub_core_properties(data: bytes) -> bytes:
    root = ET.fromstring(data)
    namespaces = {
        "dc": "http://purl.org/dc/elements/1.1/",
        "cp": "http://schemas.openxmlformats.org/package/2006/metadata/core-properties",
        "dcterms": "http://purl.org/dc/terms/",
    }
    for path in ("dc:title", "dc:creator", "cp:lastModifiedBy", "dcterms:created", "dcterms:modified"):
        element = root.find(path, namespaces)
        if element is not None:
            root.remove(element)
    return ET.tostring(root, encoding="utf-8", xml_declaration=True)


def merge_docx(job: dict, settings: dict, output_path: Path) -> dict[str, str]:
    snapshot = job.get("source_snapshot")
    context = job.get("render_context")
    if not isinstance(snapshot, dict) or not isinstance(context, dict):
        raise RenderError("invalid-job")
    if snapshot.get("render_context") != context:
        raise RenderError("context-mismatch")
    previously_approved = snapshot.get("previously_approved")
    if not isinstance(previously_approved, bool):
        raise RenderError("invalid-change-state")
    for key in ("template_hash", "settings_version", "font_version", "mayor_name", "converter_image"):
        if context.get(key) != settings.get(key):
            raise RenderError("settings-mismatch")

    limits = settings["field_limits"]
    values = {
        "user_name": require_text(snapshot.get("user_name"), "user-name", limits["user_name"]),
        "user_address": require_text(snapshot.get("user_address"), "user-address", limits["user_address"]),
        "user_phone": require_text(snapshot.get("user_phone"), "user-phone", limits["user_phone"]),
        "emergency_name": require_text(snapshot.get("emergency_name"), "emergency-name", limits["emergency_name"]),
        "emergency_address": require_text(snapshot.get("emergency_address"), "emergency-address", limits["emergency_address"]),
        "emergency_phone": require_text(snapshot.get("emergency_phone"), "emergency-phone", limits["emergency_phone"]),
        "purpose": require_text(snapshot.get("purpose"), "purpose", limits["purpose"]),
        "special_notes": require_text(snapshot.get("special_notes"), "special-notes", limits["special_notes"], optional=True),
        "room_name": require_text(context.get("room_name"), "room-name", limits["room_name"]),
    }
    application_date = parse_iso_date(snapshot.get("application_date"), "application-date")
    starts = parse_iso_date(snapshot.get("start_date"), "start-date")
    ends = parse_iso_date(snapshot.get("end_date"), "end-date")
    if starts > ends:
        raise RenderError("invalid-period")
    if snapshot.get("usage_place") != "common_and_second_floor":
        raise RenderError("invalid-usage-place")

    template = ROOT / settings["template_path"]
    if sha256_file(template) != settings["template_hash"]:
        raise RenderError("template-hash-mismatch")
    font = ROOT / settings["font_path"]
    if sha256_file(font) != settings["font_hash"]:
        raise RenderError("font-hash-mismatch")

    with zipfile.ZipFile(template, "r") as source:
        document = ET.fromstring(source.read("word/document.xml"))
        styles = ET.fromstring(source.read("word/styles.xml"))
        patch_all_fonts(document, settings["font_family"])
        patch_all_fonts(styles, settings["font_family"])
        apply_change_state(document, previously_approved)
        body = document.find(f"{W}body")
        paragraphs = [element for element in body if element.tag == f"{W}p"]
        if len(paragraphs) != 15:
            raise RenderError("template-structure-mismatch")
        replace_paragraph(paragraphs[4], wareki(application_date), settings["font_family"], 20)
        replace_paragraph(paragraphs[6], f"平泉町長　{settings['mayor_name']}　様", settings["font_family"], 20)
        replace_paragraph(paragraphs[8], f"申請者　住　所　{values['user_address']}", settings["font_family"], 16)
        replace_paragraph(paragraphs[9], "団体名", settings["font_family"], 20)
        replace_paragraph(paragraphs[10], f"氏　名（代表者名）　{values['user_name']}", settings["font_family"], 18)

        table = body.find(f"{W}tbl")
        rows = table.findall(f"{W}tr") if table is not None else []
        if len(rows) != 10:
            raise RenderError("template-structure-mismatch")
        cell_values = {
            0: (values["user_address"], 16),
            1: (values["user_name"], 18),
            2: (values["user_phone"], 20),
            3: (values["emergency_address"], 16),
            4: (values["emergency_name"], 18),
            5: (values["emergency_phone"], 20),
            6: (f"{wareki(starts)}から\n{wareki(ends)}まで", 18),
            7: (f"共用部分及び2階居室（{values['room_name']}）", 18),
            8: (values["purpose"], 16),
            9: (values["special_notes"], 16),
        }
        for row_index, (text, size) in cell_values.items():
            cells = rows[row_index].findall(f"{W}tc")
            if len(cells) < 2:
                raise RenderError("template-structure-mismatch")
            target = cells[-1]
            target_paragraphs = target.findall(f"{W}p")
            if not target_paragraphs:
                target_paragraphs = [ET.SubElement(target, f"{W}p")]
            replace_paragraph(target_paragraphs[0], text, settings["font_family"], size)
            for extra in target_paragraphs[1:]:
                target.remove(extra)

        replacements = {
            "word/document.xml": ET.tostring(document, encoding="utf-8", xml_declaration=True),
            "word/styles.xml": ET.tostring(styles, encoding="utf-8", xml_declaration=True),
            "docProps/core.xml": scrub_core_properties(source.read("docProps/core.xml")),
        }
        with zipfile.ZipFile(output_path, "w") as target_zip:
            for item in source.infolist():
                target_zip.writestr(item, replacements.get(item.filename, source.read(item.filename)))
    return values


def normalized(value: str) -> str:
    return re.sub(r"\s+", "", value)


def validate_pdf(pdf_path: Path, expected: list[str], qa_dir: Path, expected_font: str) -> dict[str, object]:
    info = run(["pdfinfo", str(pdf_path)]).stdout
    match = re.search(r"^Pages:\s+(\d+)$", info, re.MULTILINE)
    page_count = int(match.group(1)) if match else 0
    fonts = run(["pdffonts", str(pdf_path)]).stdout.splitlines()
    font_rows = [line.split() for line in fonts[2:] if line.strip()]
    fonts_embedded = (
        bool(font_rows)
        and all(len(row) >= 6 and row[4] == "yes" for row in font_rows)
        and any(expected_font.replace(" ", "") in row[0].replace(" ", "") for row in font_rows)
    )
    extracted = run(["pdftotext", "-raw", str(pdf_path), "-"]).stdout
    layout_text = run(["pdftotext", "-layout", str(pdf_path), "-"]).stdout
    qa_dir.mkdir(parents=True, exist_ok=True)
    (qa_dir / "extracted.txt").write_text(extracted, encoding="utf-8")
    (qa_dir / "layout.txt").write_text(layout_text, encoding="utf-8")
    extracted_normalized = normalized(extracted)
    text_verified = all(normalized(value) in extracted_normalized for value in expected if value)
    run(["pdftoppm", "-f", "1", "-singlefile", "-png", "-r", "144", str(pdf_path), str(qa_dir / "page-1")])
    page_png = qa_dir / "page-1.png"
    layout_verified = page_count == 1 and page_png.is_file() and page_png.stat().st_size > 10000
    return {
        "page_count": page_count,
        "fonts_embedded": fonts_embedded,
        "text_verified": text_verified,
        "layout_verified": layout_verified,
    }


def render(job: dict, output_pdf: Path, output_docx: Path | None, qa_dir: Path) -> dict[str, object]:
    settings = runtime_settings()
    work_root = Path(tempfile.mkdtemp(prefix="camp-pdf-", dir=os.environ.get("TMPDIR", "/tmp")))
    try:
        docx_path = work_root / "application.docx"
        values = merge_docx(job, settings, docx_path)
        profile = work_root / "lo-profile"
        output_dir = work_root / "converted"
        profile.mkdir()
        output_dir.mkdir()
        environment = os.environ.copy()
        environment["HOME"] = str(work_root)
        environment["LANG"] = "ja_JP.UTF-8"
        environment["LC_ALL"] = "ja_JP.UTF-8"
        run([
            "soffice", "--headless", f"-env:UserInstallation=file://{profile}",
            "--convert-to", "pdf", "--outdir", str(output_dir), str(docx_path),
        ], env=environment, timeout=90)
        converted = output_dir / "application.pdf"
        expected = [
            settings["mayor_name"], values["user_name"], values["user_address"], values["user_phone"],
            values["emergency_name"], values["emergency_address"], values["emergency_phone"], values["purpose"],
            values["special_notes"], values["room_name"], wareki(parse_iso_date(job["source_snapshot"]["application_date"], "application-date")),
        ]
        report = validate_pdf(converted, expected, qa_dir, settings["font_family"])
        if report != {"page_count": 1, "fonts_embedded": True, "text_verified": True, "layout_verified": True}:
            raise RenderError(f"validation-failed:{json.dumps(report, ensure_ascii=False, sort_keys=True)}")
        output_pdf.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(converted, output_pdf)
        if output_docx:
            output_docx.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(docx_path, output_docx)
        return report
    finally:
        shutil.rmtree(work_root, ignore_errors=True)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--job", type=Path, required=True)
    parser.add_argument("--output-pdf", type=Path, required=True)
    parser.add_argument("--output-docx", type=Path)
    parser.add_argument("--qa-dir", type=Path, required=True)
    args = parser.parse_args()
    job = json.loads(args.job.read_text(encoding="utf-8"))
    report = render(job, args.output_pdf, args.output_docx, args.qa_dir)
    print(json.dumps({"pdf_base64": base64.b64encode(args.output_pdf.read_bytes()).decode("ascii"), "validation": report}, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
