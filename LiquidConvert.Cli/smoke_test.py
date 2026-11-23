"""Integration checks for the packaged Windows CLI."""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import subprocess
import sys
from tempfile import TemporaryDirectory
from threading import Thread
from zipfile import ZipFile

from openpyxl import Workbook
from pptx import Presentation


def write_docx(path):
    with ZipFile(path, "w") as docx:
        docx.writestr("[Content_Types].xml", """
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
</Types>""")
        docx.writestr("_rels/.rels", """
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
</Relationships>""")
        docx.writestr("word/document.xml", """
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
<w:body><w:p><w:r><w:t>中文发布稿与参数</w:t></w:r></w:p></w:body>
</w:document>""")


def write_pdf(path):
    stream = b"BT /F1 14 Tf 40 700 Td (PDF text extraction) Tj ET"
    objects = (
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Count 1 /Kids [3 0 R] >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources "
        b"<< /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        f"<< /Length {len(stream)} >>".encode() + b"\nstream\n" + stream + b"\nendstream",
    )
    data = bytearray(b"%PDF-1.4\n")
    offsets = []
    for i, obj in enumerate(objects, 1):
        offsets.append(len(data))
        data.extend(f"{i} 0 obj\n".encode() + obj + b"\nendobj\n")
    start = len(data)
    data.extend(f"xref\n0 {len(offsets) + 1}\n0000000000 65535 f \n".encode())
    for offset in offsets:
        data.extend(f"{offset:010} 00000 n \n".encode())
    data.extend(f"trailer\n<< /Size {len(offsets) + 1} /Root 1 0 R >>\nstartxref\n{start}\n%%EOF\n".encode())
    path.write_bytes(data)


class Article(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers()
        self.wfile.write("""
<html><head><title>新闻测试</title></head><body><nav>菜单</nav><main>
<p>新消息</p><script>script noise</script><a href="/source">信源</a>
<img alt="原图" data-src="/photo.png"></main><footer>页脚</footer></body></html>
""".encode())


def main():
    executable = Path(sys.argv[1]).resolve()

    def run(*args, code=0):
        process = subprocess.run([str(executable), *map(str, args)], capture_output=True, encoding="utf-8", timeout=60)
        assert process.returncode == code, (args, process.returncode, process.stdout, process.stderr)
        return process.stdout

    with TemporaryDirectory(prefix="liquidconvert-cli-") as directory:
        root = Path(directory)
        docx = root / "新闻稿.docx"
        write_docx(docx)
        explicit = root / "导出结果" / "新闻稿.md"
        run("--extract-markdown", docx, "--output", explicit, "--no-ocr")
        assert "中文发布稿与参数" in explicit.read_text(encoding="utf-8")

        pdf = root / "paper.pdf"
        write_pdf(pdf)
        assert "PDF text extraction" in run(pdf)

        slides = root / "slides.pptx"
        presentation = Presentation()
        presentation.slides.add_slide(presentation.slide_layouts[0]).shapes.title.text = "中文演示页"
        presentation.save(slides)
        assert "中文演示页" in run(slides)

        sheet = root / "sheet.xlsx"
        workbook = Workbook()
        workbook.active.append(["金额", 128])
        workbook.save(sheet)
        assert "金额" in run(sheet)

        text_file = root / "新闻稿.txt"
        text_file.write_text("另一份中文说明", encoding="utf-16")
        assert run(text_file).strip() == "另一份中文说明"
        run(text_file, "--output", text_file, code=1)
        assert "另一份中文说明" in text_file.read_text(encoding="utf-16")

        with ThreadingHTTPServer(("127.0.0.1", 0), Article) as server:
            thread = Thread(target=server.serve_forever, daemon=True)
            thread.start()
            origin = f"http://127.0.0.1:{server.server_port}"
            try:
                markdown = run(f"{origin}/article", "--no-ocr")
                assert "# 新闻测试" in markdown and "新消息" in markdown
                assert f"[信源]({origin}/source)" in markdown and f"![原图]({origin}/photo.png)" in markdown
                assert all(noise not in markdown for noise in ("菜单", "页脚", "script noise"))
            finally:
                server.shutdown()

        output = root / "batch"
        output.mkdir()
        existing = output / "新闻稿.md"
        existing.write_text("existing", encoding="utf-8")
        result = json.loads(run("--batch", docx, root / "legacy.doc", text_file, "--output-dir", output, "--json", code=1))
        assert not result["ok"] and not result["ocr_enabled"] and len(result["failures"]) == 1
        assert [Path(item["output"]).name for item in result["exported"]] == ["新闻稿-2.md", "新闻稿-3.md"]
        assert existing.read_text(encoding="utf-8") == "existing"
        run(code=2)
    print("Windows CLI smoke tests passed")


if __name__ == "__main__":
    main()
