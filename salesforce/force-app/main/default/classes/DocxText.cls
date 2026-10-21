/**
 * The text of a Word (.docx) file, for the order form extractor: Claude reads
 * PDFs and images but not Word, so a .docx is sent as its text instead.
 *
 * A .docx is a zip whose body is word/document.xml. Paragraphs become lines,
 * table cells are joined with " | " (one row per line), and tabs and line
 * breaks are kept. Tracked changes read as accepted: inserted text is kept,
 * deleted and moved-away text is left out. Field codes, images, formatting,
 * headers, footers and comments are left out; a text box is read once.
 */
public with sharing class DocxText {

    public static final String BODY_PART = 'word/document.xml';

    public class DocxException extends Exception {}

    /**
     * The file's text. maxBodyBytes caps the uncompressed body (the caller's
     * memory budget - reading it takes about four times its size at the peak).
     * Throws DocxException when the file is not a readable .docx or its body is
     * over the cap.
     */
    public static String read(Blob docx, Long maxBodyBytes) {
        Compression.ZipReader zip;
        Compression.ZipEntry body;
        try {
            zip = new Compression.ZipReader(docx);
            body = zip.getEntry(BODY_PART);
        } catch (Exception e) {
            throw new DocxException('not a readable Word file (' + e.getMessage() + ')');
        }
        Long size = body.getUncompressedSize();
        if (maxBodyBytes != null && size > maxBodyBytes) {
            throw new DocxException('too large to read in memory: ' + size + ' bytes of text markup, room for '
                + Math.max(maxBodyBytes, 0L));
        }
        String xml;
        try {
            xml = zip.extract(body).toString();
        } catch (Exception e) {
            throw new DocxException('could not unpack the Word file (' + e.getMessage() + ')');
        }
        zip = null;
        return fromXml(xml);
    }

    @TestVisible
    private static String fromXml(String xml) {
        List<String> out = new List<String>();
        Integer breaks = 2;      // line breaks just written - no blank lines at the start
        Integer cellDepth = 0;   // inside a table cell, paragraphs end with a space
        Integer pos = 0;
        while (true) {
            Integer lt = xml.indexOf('<', pos);
            if (lt < 0) break;
            Integer gt = xml.indexOf('>', lt);
            if (gt < 0) break;
            String tag = xml.substring(lt + 1, gt);
            pos = gt + 1;
            Boolean selfClosing = tag.endsWith('/');
            String name = tag.removeEnd('/').trim().substringBefore(' ');

            if (name == 'w:t' && !selfClosing) {
                Integer close = xml.indexOf('</w:t>', pos);
                if (close < 0) break;
                String text = xml.substring(pos, close);
                pos = close + 6;
                if (text.length() > 0) {
                    out.add(unescape(text));
                    breaks = 0;
                }
            } else if ((name == 'mc:Fallback' || name == 'w:moveFrom' || name == 'w:tabs') && !selfClosing) {
                // A text box's second copy (for old Word versions), text a tracked
                // move took away, a paragraph's tab-stop settings.
                String closing = '</' + name + '>';
                Integer close = xml.indexOf(closing, pos);
                if (close < 0) break;
                pos = close + closing.length();
            } else if (name == 'w:tc' && !selfClosing) {
                cellDepth++;
            } else if (name == '/w:tc') {
                cellDepth = Math.max(cellDepth - 1, 0);
                if (!out.isEmpty() && out[out.size() - 1] == ' ') out.remove(out.size() - 1);
                out.add(' | ');
                breaks = 0;
            } else if (name == '/w:tr' && !out.isEmpty() && out[out.size() - 1] == ' | ') {
                out[out.size() - 1] = '\n';
                breaks = 1;
            } else if ((name == '/w:p' || (name == 'w:p' && selfClosing)) && cellDepth > 0) {
                out.add(' ');
            } else if (name == '/w:p' || (name == 'w:p' && selfClosing) || name == '/w:tr'
                    || name == 'w:br' || name == 'w:cr') {
                if (breaks < 2) {
                    out.add('\n');
                    breaks++;
                }
            } else if (name == 'w:tab') {
                out.add('\t');
            }
        }
        return String.join(out, '').trim();
    }

    private static String unescape(String s) {
        if (!s.contains('&')) return s;
        return s.replace('&lt;', '<').replace('&gt;', '>').replace('&quot;', '"')
            .replace('&apos;', '\'').replace('&amp;', '&');
    }
}
