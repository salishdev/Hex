import { expect, test } from "bun:test";
import { notesHTML } from "./sparkle";

test("release notes render headings and bullets while escaping active content and hiding provenance", () => {
  const html = notesHTML('### Improvements\n\n- Faster & better (#12)\n<script>alert("bad")</script>\n  <!-- hex-release-commit: abc -->');
  expect(html).toContain("<h3>Improvements</h3>");
  expect(html).toContain("• Faster &amp; better (#12)");
  expect(html).toContain("&lt;script&gt;");
  expect(html).not.toContain("<script>");
  expect(html).not.toContain("hex-release-commit");
});
