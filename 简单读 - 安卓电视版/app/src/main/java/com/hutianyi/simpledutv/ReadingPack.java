package com.hutianyi.simpledutv;

import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.net.Uri;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.zip.CRC32;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;

final class ReadingPack {
    private static final int MIB = 1024 * 1024;

    record Run(String text, boolean target) {}
    record Unit(String heading, String image, List<Run> runs) {}
    record Question(String prompt, List<String> options, int answer, String explanation) {}
    record Article(String id, String title, String day, List<Unit> units, List<Question> questions) {}
    record Manifest(String batch, int revision, String title, Map<String, String> files) {}

    final File file;
    final Manifest manifest;
    final List<Article> articles;
    final Map<String, String> imageAlt;

    private ReadingPack(File file, Manifest manifest, List<Article> articles, Map<String, String> imageAlt) {
        this.file = file;
        this.manifest = manifest;
        this.articles = articles;
        this.imageAlt = imageAlt;
    }

    ReadingPack storedAt(File file) {
        return new ReadingPack(file, manifest, articles, imageAlt);
    }

    static ReadingPack open(File file, boolean verifyPayload) throws IOException {
        require(file.isFile() && file.length() > 0 && file.length() <= 64L * MIB, "阅读包大小不受支持。");
        try (ZipFile zip = new ZipFile(file)) {
            Map<String, ZipEntry> entries = new LinkedHashMap<>();
            long totalBytes = 0;
            var iterator = zip.entries();
            while (iterator.hasMoreElements()) {
                ZipEntry entry = iterator.nextElement();
                long size = entry.getSize();
                require(safePath(entry.getName()) && !entry.isDirectory()
                        && entries.put(entry.getName(), entry) == null, "ZIP 包含不受支持的路径或重复文件。");
                require(size >= 0 && size <= 16 * MIB && (entry.getMethod() == ZipEntry.STORED
                        || entry.getMethod() == ZipEntry.DEFLATED), "ZIP 文件过大或压缩方式不受支持。");
                totalBytes += size;
                require(totalBytes <= 96L * MIB && entries.size() <= 256, "ZIP 解压后的大小或文件数量超限。");
            }

            JSONObject header = json(read(zip, entries.get("manifest.json"), 128 * 1024));
            require("SimpleDu".equals(string(header, "format"))
                    && integer(header, "schemaVersion", 1, 1) == 1, "需要简单读 v1 阅读包。");
            String batch = identifier(header, "batchID");
            int revision = integer(header, "revision", 1, 1_000_000);
            String title = text(header, "title", 180);
            JSONObject inventory = header.getJSONObject("files");
            Map<String, String> hashes = new LinkedHashMap<>();
            require(inventory.length() == entries.size() - 1, "阅读包文件清单不完整。");
            for (String path : entries.keySet()) {
                if (path.equals("manifest.json")) continue;
                String hash = string(inventory, path);
                require(hash.matches("[0-9a-f]{64}"), "阅读包校验值无效。");
                hashes.put(path, hash);
            }
            byte[] content = read(zip, entries.get("content.json"), 2 * MIB);
            require(verifyPayloadHash(content, hashes.get("content.json")), "正文和题目校验失败。");
            JSONObject body = json(content);
            Map<String, String> images = parseImages(body.getJSONArray("images"), entries.keySet());
            List<Article> articles = parseArticles(body.getJSONArray("articles"), images.keySet(), batch);

            if (verifyPayload) {
                for (var entry : hashes.entrySet()) {
                    String path = entry.getKey();
                    if (path.equals("content.json")) continue;
                    byte[] bytes = read(zip, entries.get(path), 16 * MIB);
                    require(verifyPayloadHash(bytes, entry.getValue()), "包内文件校验失败：" + path);
                    if (images.containsKey(path)) verifyImage(bytes, path);
                }
            }
            return new ReadingPack(file, new Manifest(batch, revision, title, hashes), articles, images);
        } catch (JSONException | IllegalArgumentException error) {
            throw new IOException("阅读包字段不完整或格式无效。", error);
        }
    }

    Bitmap image(String path, int width, int height) throws IOException {
        try (ZipFile zip = new ZipFile(file)) {
            byte[] bytes = read(zip, zip.getEntry(path), 16 * MIB);
            BitmapFactory.Options options = imageBounds(bytes);
            options.inSampleSize = sample(options, width, height);
            options.inJustDecodeBounds = false;
            Bitmap bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.length, options);
            require(bitmap != null, "插图无法显示。");
            return bitmap;
        }
    }

    private static Map<String, String> parseImages(JSONArray array, Set<String> entries)
            throws JSONException, IOException {
        count(array, 1, 200);
        Map<String, String> images = new LinkedHashMap<>();
        for (int index = 0; index < array.length(); index++) {
            JSONObject image = array.getJSONObject(index);
            String path = string(image, "path");
            String lowerPath = path.toLowerCase(Locale.ROOT);
            require(path.startsWith("images/") && entries.contains(path) && (lowerPath.endsWith(".jpg")
                    || lowerPath.endsWith(".jpeg") || lowerPath.endsWith(".png")), "缺少插图或图片格式不受支持。");
            require(images.put(path, text(image, "alt", 1000)) == null, "插图重复。");
            text(image, "credit", 2000);
        }
        return images;
    }

    private static List<Article> parseArticles(JSONArray array, Set<String> images, String batch)
            throws JSONException, IOException {
        count(array, 1, 30);
        Set<String> articleIds = new HashSet<>();
        List<Article> articles = new ArrayList<>();
        for (int index = 0; index < array.length(); index++) {
            JSONObject article = array.getJSONObject(index);
            String id = uniqueId(article, articleIds);
            String title = text(article, "title", 180);
            require(images.contains(string(article, "cover")), "文章缺少封面。");

            Set<String> paragraphIds = new HashSet<>();
            List<Unit> units = parseUnits(article.getJSONArray("units"), images, paragraphIds);
            List<Question> questions = parseQuestions(article.getJSONArray("questions"), paragraphIds);
            JSONArray sources = article.getJSONArray("sources");
            for (int sourceIndex = 0; sourceIndex < sources.length(); sourceIndex++) {
                JSONObject source = sources.getJSONObject(sourceIndex);
                text(source, "title", 500);
                // Legacy iPad packs can contain escaped query punctuation. This metadata is never opened.
                Uri link = Uri.parse(string(source, "url"));
                require(("http".equalsIgnoreCase(link.getScheme()) || "https".equalsIgnoreCase(link.getScheme()))
                        && link.getHost() != null && !link.getHost().isEmpty(), "文章资料链接无效。");
            }
            int day = article.isNull("dayNumber") ? 0 : integer(article, "dayNumber", 1, 1_000_000);
            int number = article.isNull("articleNumber") ? 0 : integer(article, "articleNumber", 1, 1_000_000);
            var legacy = java.util.regex.Pattern.compile("day([0-9]{1,6})-article([0-9]{1,6})").matcher(id);
            if (legacy.matches()) {
                if (day == 0) day = Integer.parseInt(legacy.group(1));
                if (number == 0) number = Integer.parseInt(legacy.group(2));
            } else if (day == 0 && batch.equals("ket-day14")) {
                day = 14;
            }
            String label = day > 0 ? "Day " + day + (number > 0 ? " / Article " + number : "") : "";
            articles.add(new Article(id, title, label, units, questions));
        }
        return articles;
    }

    private static List<Unit> parseUnits(JSONArray array, Set<String> images, Set<String> paragraphs)
            throws JSONException, IOException {
        count(array, 1, 80);
        Set<String> unitIds = new HashSet<>();
        List<Unit> units = new ArrayList<>();
        int characters = 0;
        for (int index = 0; index < array.length(); index++) {
            JSONObject unit = array.getJSONObject(index);
            uniqueId(unit, unitIds);
            String heading = string(unit, "heading");
            String image = string(unit, "image");
            require(heading.length() <= 180 && images.contains(image), "阅读单元缺少插图或标题过长。");
            JSONArray body = unit.getJSONArray("paragraphs");
            count(body, 1, 400);
            List<Run> runs = new ArrayList<>();
            for (int paragraphIndex = 0; paragraphIndex < body.length(); paragraphIndex++) {
                JSONObject paragraph = body.getJSONObject(paragraphIndex);
                uniqueId(paragraph, paragraphs);
                require(paragraphs.size() <= 400, "文章段落过多。");
                if (paragraphIndex > 0) runs.add(new Run("\n\n", false));
                JSONArray parts = paragraph.getJSONArray("runs");
                count(parts, 1, 200);
                StringBuilder combined = new StringBuilder();
                for (int partIndex = 0; partIndex < parts.length(); partIndex++) {
                    JSONObject part = parts.getJSONObject(partIndex);
                    String partText = string(part, "text");
                    Object target = part.get("target");
                    require(!partText.isEmpty() && target instanceof Boolean, "正文词组或重点词标记无效。");
                    require(combined.length() + partText.length() <= 10_000, "正文段落过长。");
                    combined.append(partText);
                    runs.add(new Run(partText, (Boolean) target));
                }
                require(validText(combined.toString(), 10_000), "正文段落为空或包含不支持的字符。");
                characters += combined.length();
                require(characters <= 60_000, "文章正文过长。");
            }
            units.add(new Unit(heading, image, runs));
        }
        return units;
    }

    private static List<Question> parseQuestions(JSONArray array, Set<String> paragraphs)
            throws JSONException, IOException {
        count(array, 1, 60);
        Set<String> questionIds = new HashSet<>();
        List<Question> questions = new ArrayList<>();
        for (int index = 0; index < array.length(); index++) {
            JSONObject question = array.getJSONObject(index);
            uniqueId(question, questionIds);
            String prompt = text(question, "prompt", 1000);
            JSONArray choices = question.getJSONArray("options");
            count(choices, 4, 4);
            List<String> options = new ArrayList<>(4);
            for (int choice = 0; choice < 4; choice++) {
                Object value = choices.get(choice);
                require(value instanceof String && validText((String) value, 1000)
                        && !options.contains(value), "选项为空、过长或重复。");
                options.add((String) value);
            }
            int answer = integer(question, "answer", 0, 3);
            String explanation = string(question, "explanation");
            require(explanation.length() <= 2000, "题目解析过长。");
            JSONArray evidence = question.getJSONArray("evidence");
            for (int reference = 0; reference < evidence.length(); reference++) {
                require(paragraphs.contains(evidence.get(reference)), "答题依据引用了不存在的段落。");
            }
            questions.add(new Question(prompt, options, answer, explanation));
        }
        return questions;
    }

    private static JSONObject json(byte[] bytes) throws JSONException, IOException {
        return new JSONObject(StandardCharsets.UTF_8.newDecoder().decode(ByteBuffer.wrap(bytes)).toString());
    }

    private static byte[] read(ZipFile zip, ZipEntry entry, int maxBytes) throws IOException {
        require(entry != null && entry.getSize() >= 0 && entry.getSize() <= maxBytes, "缺少必要文件或文件过大。");
        int expected = (int) entry.getSize();
        CRC32 crc = new CRC32();
        ByteArrayOutputStream output = new ByteArrayOutputStream(Math.min(expected, 64 * 1024));
        byte[] buffer = new byte[16 * 1024];
        try (InputStream stream = zip.getInputStream(entry)) {
            int count;
            while ((count = stream.read(buffer)) != -1) {
                require(output.size() + count <= expected, "解压后的文件大小不符。");
                output.write(buffer, 0, count);
                crc.update(buffer, 0, count);
            }
        }
        require(output.size() == expected && crc.getValue() == entry.getCrc(), "ZIP 文件校验失败。");
        return output.toByteArray();
    }

    private static boolean verifyPayloadHash(byte[] bytes, String expected) {
        try {
            byte[] hash = MessageDigest.getInstance("SHA-256").digest(bytes);
            StringBuilder result = new StringBuilder(64);
            for (byte value : hash) {
                result.append(Character.forDigit((value & 0xff) >>> 4, 16));
                result.append(Character.forDigit(value & 0xf, 16));
            }
            return Objects.equals(result.toString(), expected);
        } catch (NoSuchAlgorithmException error) {
            throw new IllegalStateException(error);
        }
    }

    private static void verifyImage(byte[] bytes, String path) throws IOException {
        BitmapFactory.Options options = imageBounds(bytes);
        require(options.outWidth > 0 && options.outHeight > 0 && options.outWidth <= 8192
                && options.outHeight <= 8192 && (long) options.outWidth * options.outHeight <= 24_000_000
                && ("image/jpeg".equals(options.outMimeType) || "image/png".equals(options.outMimeType)),
                "插图格式或尺寸不受支持：" + path);
        options.inSampleSize = sample(options, 64, 64);
        options.inJustDecodeBounds = false;
        Bitmap bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.length, options);
        require(bitmap != null, "插图文件损坏：" + path);
        bitmap.recycle();
    }

    private static BitmapFactory.Options imageBounds(byte[] bytes) {
        BitmapFactory.Options options = new BitmapFactory.Options();
        options.inJustDecodeBounds = true;
        BitmapFactory.decodeByteArray(bytes, 0, bytes.length, options);
        return options;
    }

    private static int sample(BitmapFactory.Options bounds, int width, int height) {
        double scale = Math.max((double) bounds.outWidth / Math.max(1, width),
                (double) bounds.outHeight / Math.max(1, height));
        return Integer.highestOneBit(Math.max(1, (int) scale));
    }

    private static boolean safePath(String name) {
        if (name.isEmpty() || name.indexOf('\\') >= 0 || name.indexOf(':') >= 0
                || name.indexOf('\0') >= 0) return false;
        for (String part : name.split("/", -1)) {
            if (part.isEmpty() || part.equals(".") || part.equals("..")) return false;
        }
        return true;
    }

    private static String uniqueId(JSONObject object, Set<String> ids) throws JSONException, IOException {
        String id = identifier(object, "id");
        require(ids.add(id), "文章、题目、阅读单元或段落编号重复。");
        return id;
    }

    private static String identifier(JSONObject object, String key) throws JSONException, IOException {
        String id = string(object, key);
        require(id.matches("[0-9A-Za-z_-]{1,100}"), "编号无效。");
        return id;
    }

    private static int integer(JSONObject object, String key, int min, int max) throws JSONException, IOException {
        Object value = object.get(key);
        require(value instanceof Integer || value instanceof Long, "数字字段无效：" + key);
        long number = ((Number) value).longValue();
        require(number >= min && number <= max, "数字字段超出支持范围：" + key);
        return (int) number;
    }

    private static String string(JSONObject object, String key) throws JSONException, IOException {
        Object value = object.get(key);
        require(value instanceof String, "字段格式无效：" + key);
        return (String) value;
    }

    private static String text(JSONObject object, String key, int max) throws JSONException, IOException {
        String result = string(object, key);
        require(validText(result, max), "文字字段为空或过长：" + key);
        return result;
    }

    private static boolean validText(String value, int max) {
        if (value.trim().isEmpty() || value.length() > max) return false;
        for (int index = 0; index < value.length(); index++) {
            char c = value.charAt(index);
            if (Character.isISOControl(c) && c != '\n' && c != '\t') return false;
        }
        return true;
    }

    private static void count(JSONArray items, int min, int max) throws IOException {
        require(items.length() >= min && items.length() <= max, "条目数量不受支持。");
    }

    private static void require(boolean condition, String error) throws IOException {
        if (!condition) throw new IOException(error);
    }
}
