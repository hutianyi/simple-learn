package com.hutianyi.simpledutv;

import android.content.Context;
import android.util.Log;

import java.io.File;
import java.io.IOException;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Comparator;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

final class Library {
    record Book(ReadingPack pack, ReadingPack.Article article) {
        String key() {
            return pack.manifest.batch() + "/" + pack.manifest.revision() + "/" + article.id();
        }
    }

    record Scan(List<Book> books, int added, int skipped, int rejected, String error) {}

    private final File inbox;
    private final File library;

    Library(Context context) {
        inbox = new File(context.getFilesDir(), "inbox");
        library = new File(context.getFilesDir(), "library");
    }

    Scan scan() {
        List<Book> books = new ArrayList<>();
        Map<String, ReadingPack> active = new HashMap<>();
        int added = 0;
        int skipped = 0;
        int rejected = 0;
        String errorMessage = null;

        try {
            for (File file : packs(library)) {
                try {
                    ReadingPack pack = ReadingPack.open(file, false);
                    if (!(pack.manifest.batch() + ".simpledu").equals(file.getName())) {
                        throw new IOException("包名与批次不一致。");
                    }
                    active.put(pack.manifest.batch(), pack);
                } catch (IOException error) {
                    Log.w("SimpleDuTV", "无法读取已导入的阅读包", error);
                    errorMessage = "部分已导入阅读包无法读取。可以从 Mac 重传原包。";
                }
            }

            for (File incoming : packs(inbox)) {
                ReadingPack pack;
                try {
                    pack = ReadingPack.open(incoming, true);
                    ReadingPack previous = active.get(pack.manifest.batch());
                    if (previous != null && pack.manifest.revision() <= previous.manifest.revision()) {
                        if (pack.manifest.revision() == previous.manifest.revision()
                                && !pack.manifest.equals(previous.manifest)) {
                            throw new IOException("同一批次和版本的内容不同。");
                        }
                        if (!incoming.delete()) throw new IOException("无法清理已处理的收件箱文件。");
                        skipped++;
                        continue;
                    }
                } catch (IOException error) {
                    Log.w("SimpleDuTV", "拒绝导入阅读包", error);
                    File quarantine = new File(inbox, incoming.getName() + ".rejected");
                    boolean moved = incoming.renameTo(quarantine);
                    errorMessage = error.getMessage() + (moved ? "" : " 收件箱文件保留，稍后可重试。");
                    rejected++;
                    continue;
                }

                // Both directories are private and on the same filesystem. Rename publishes the full archive.
                File destination = new File(library, pack.manifest.batch() + ".simpledu");
                if (incoming.renameTo(destination)) {
                    active.put(pack.manifest.batch(), pack.storedAt(destination));
                    added++;
                } else {
                    errorMessage = "无法保存阅读包，文件仍在收件箱。请检查电视的可用空间后重试。";
                }
            }
        } catch (IOException error) {
            Log.w("SimpleDuTV", "无法扫描阅读包目录", error);
            errorMessage = error.getMessage();
        }

        List<ReadingPack> ordered = new ArrayList<>(active.values());
        ordered.sort(Comparator.comparingLong((ReadingPack pack) -> pack.file.lastModified()).reversed()
                .thenComparing(pack -> pack.manifest.batch()));
        for (ReadingPack pack : ordered) {
            for (ReadingPack.Article article : pack.articles) books.add(new Book(pack, article));
        }
        return new Scan(books, added, skipped, rejected, errorMessage);
    }

    private static File[] packs(File directory) throws IOException {
        if (!directory.isDirectory() && !directory.mkdirs() && !directory.isDirectory()) {
            throw new IOException("无法打开简单读的存储目录。");
        }
        File[] files = directory.listFiles((path, name) -> !name.startsWith(".") && name.endsWith(".simpledu"));
        if (files == null) throw new IOException("无法读取简单读的存储目录。");
        Arrays.sort(files, Comparator.comparingLong(File::lastModified).thenComparing(File::getName));
        return files;
    }
}
