package com.hutianyi.simpledutv;

import android.app.Activity;
import android.content.SharedPreferences;
import android.graphics.Bitmap;
import android.graphics.text.LineBreaker;
import android.os.Bundle;
import android.text.Layout;
import android.text.TextUtils;
import android.util.Log;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.View;
import android.widget.Button;
import android.widget.FrameLayout;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

import java.io.IOException;
import java.util.Collections;
import java.util.List;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

import static com.hutianyi.simpledutv.TvViews.*;

public final class MainActivity extends Activity {
    private static final int[] FONT_SIZES = {23, 28, 33};
    private final ExecutorService tasks = Executors.newSingleThreadExecutor();
    private List<Library.Book> books = Collections.emptyList();
    private String selectedBook;
    private String scanStatus = "正在读取电视上的文章…";
    private boolean scanning;
    private boolean scanned;
    private boolean scanError;
    private boolean showingRead;
    private Library library;
    private Library.Book book;
    private Progress progress;
    private SharedPreferences prefs;
    private SharedPreferences readMarks;
    private TvViews ui;
    private FrameLayout root;
    private int fontIndex = 1;
    private ReaderScreen reader;
    private ScrollView questionScroll;

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        getWindow().getDecorView().setSystemUiVisibility(View.SYSTEM_UI_FLAG_FULLSCREEN
                | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION | View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY);
        prefs = getSharedPreferences("reading", MODE_PRIVATE);
        readMarks = getSharedPreferences("read_marks", MODE_PRIVATE);
        fontIndex = Math.max(0, Math.min(FONT_SIZES.length - 1, prefs.getInt("font_size", 1)));
        library = new Library(this);
        ui = new TvViews(this);
        root = new FrameLayout(this);
        root.setBackgroundColor(BACKGROUND);
        setContentView(root);
        scan(false);
    }

    @Override
    protected void onResume() {
        super.onResume();
        if (scanned && book == null && !scanning) scan(false);
    }

    @Override
    protected void onDestroy() {
        tasks.shutdownNow();
        super.onDestroy();
    }

    private void scan(boolean manual) {
        if (scanning) return;
        scanning = true;
        scanError = false;
        scanStatus = "正在检查阅读包…";
        libraryScreen(manual);
        tasks.execute(() -> {
            Library.Scan result = library.scan();
            runOnUiThread(() -> {
                if (isDestroyed()) return;
                books = result.books();
                scanned = true;
                scanning = false;
                scanError = result.error() != null;
                if (scanError) {
                    scanStatus = "导入 " + result.added() + " 个 · " + result.error();
                } else if (result.added() > 0 || result.skipped() > 0) {
                    scanStatus = "导入 " + result.added() + " 个阅读包 · 跳过 " + result.skipped() + " 个重复或旧版包";
                } else {
                    scanStatus = manual ? "收件箱没有新阅读包" : "";
                }
                if (book == null) libraryScreen(manual && result.added() == 0);
            });
        });
    }

    private void libraryScreen(boolean focusImport) {
        LinearLayout screen = screen();
        LinearLayout header = ui.row();
        LinearLayout titles = ui.column();
        titles.addView(ui.text(showingRead ? "已读文章" : "简单读", 34, TEXT, true));
        TextView summary = ui.text("", 16, MUTED, false);
        titles.addView(summary);
        header.addView(titles, new LinearLayout.LayoutParams(0, -2, 1));
        Button section = ui.button(showingRead ? "返回未读文章" : "已读文章", () -> showReadList(!showingRead));
        header.addView(section);
        Button refresh = null;
        if (!showingRead) {
            refresh = ui.button("检查新阅读包", () -> scan(true));
            LinearLayout.LayoutParams refreshLayout = new LinearLayout.LayoutParams(-2, -2);
            refreshLayout.leftMargin = ui.dp(10);
            header.addView(refresh, refreshLayout);
            section.setNextFocusRightId(refresh.getId());
            refresh.setNextFocusLeftId(section.getId());
        }
        screen.addView(header);
        if (!showingRead && !scanStatus.isEmpty()) {
            ui.add(screen, ui.text(scanStatus, 17, scanError ? ERROR : MINT, false), 8);
        }

        ScrollView scroll = scroll();
        LinearLayout list = ui.column();
        scroll.addView(list);
        screen.addView(scroll, fillWithTopMargin(14));
        Button first = null;
        Button focused = null;
        int readCount = 0;
        for (Library.Book item : books) {
            Progress saved = Progress.load(prefs, item);
            boolean read = saved.isRead(readMarks.getBoolean(item.key(), false));
            if (read) readCount++;
            if (read != showingRead) continue;

            String label = item.article().title();
            String details = item.article().day();
            String activity = showingRead ? "" : saved.activityLabel();
            if (!activity.isEmpty()) details = details.isEmpty() ? activity : details + "  ·  " + activity;
            if (!details.isEmpty()) label += "\n" + details;
            Button button = ui.button(label, () -> openBook(item));
            button.setTextSize(20);
            ui.add(list, button, first == null ? 0 : 8);
            if (first == null) first = button;
            if (item.key().equals(selectedBook)) focused = button;
        }
        summary.setText(showingRead ? getString(R.string.article_count, readCount)
                : getString(R.string.unread_count, books.size() - readCount));
        if (!showingRead) section.setText(getString(R.string.read_archive_count, readCount));
        if (first == null && !scanning) {
            String empty = showingRead ? "还没有已读文章" : "没有未读文章";
            if (!showingRead && books.isEmpty()) empty = "还没有阅读文章";
            ui.add(list, ui.text(empty, 25, TEXT, true), 24);
            if (!showingRead && books.isEmpty()) {
                ui.add(list, ui.text("从 Mac 传入 .simpledu 文件后，按「检查新阅读包」。", 19, MUTED, false), 8);
            }
        }
        if (first != null) {
            section.setNextFocusDownId(first.getId());
            first.setNextFocusUpId(section.getId());
            if (refresh != null) refresh.setNextFocusDownId(first.getId());
        }
        if (refresh != null && (focusImport || books.isEmpty())) {
            refresh.requestFocus();
        } else if (first == null) {
            section.requestFocus();
        } else {
            (focused == null ? first : focused).requestFocus();
        }
    }

    private void showReadList(boolean show) {
        showingRead = show;
        libraryScreen(false);
    }

    private void openBook(Library.Book item) {
        if (scanning) {
            Toast.makeText(this, "正在检查阅读包，请稍等", Toast.LENGTH_SHORT).show();
            return;
        }
        book = item;
        selectedBook = item.key();
        progress = Progress.load(prefs, item);
        openStage();
    }

    private void openStage() {
        switch (progress.stage) {
            case Progress.QUIZ -> quizScreen(false);
            case Progress.RESULT -> resultScreen();
            default -> reader = new ReaderScreen();
        }
    }

    private void backToLibrary() {
        book = null;
        progress = null;
        libraryScreen(false);
    }

    @SuppressWarnings("deprecation")
    @Override
    public void onBackPressed() {
        if (reader != null && progress.stage == Progress.QUIZ) quizScreen(false);
        else if (book != null) backToLibrary();
        else if (showingRead) showReadList(false);
        else super.onBackPressed();
    }

    @Override
    public boolean dispatchKeyEvent(KeyEvent event) {
        int code = event.getKeyCode();
        boolean horizontal = code == KeyEvent.KEYCODE_DPAD_LEFT || code == KeyEvent.KEYCODE_DPAD_RIGHT;
        if (horizontal && reader != null) {
            if (event.getAction() == KeyEvent.ACTION_DOWN && event.getRepeatCount() == 0) {
                if (code == KeyEvent.KEYCODE_DPAD_RIGHT) reader.forward();
                else reader.move(-1);
            }
            return true;
        }
        if (horizontal && questionScroll != null) {
            if (event.getAction() == KeyEvent.ACTION_DOWN) {
                int amount = Math.round(questionScroll.getHeight() * 0.55f);
                questionScroll.smoothScrollBy(0, code == KeyEvent.KEYCODE_DPAD_RIGHT ? amount : -amount);
            }
            return true;
        }
        return super.dispatchKeyEvent(event);
    }

    private final class ReaderScreen {
        private final Library.Book current = book;
        private final TextView content;
        private final TextView heading;
        private final TextView counter;
        private final Button next;
        private final Button size;
        private final ImageView picture;
        private final TextView pictureStatus;
        private List<ReaderPages.Page> pages = Collections.emptyList();
        private int position;
        private String imagePath;
        private int imageWidth;
        private int imageHeight;

        ReaderScreen() {
            LinearLayout screen = screen();
            LinearLayout header = ui.row();
            TextView title = ui.text(current.article().title(), 24, TEXT, true);
            title.setMaxLines(1);
            title.setEllipsize(TextUtils.TruncateAt.END);
            counter = ui.text("", 17, MINT, true);
            header.addView(title, new LinearLayout.LayoutParams(0, -2, 1));
            header.addView(counter);
            screen.addView(header);

            LinearLayout columns = ui.row();
            columns.setGravity(Gravity.CENTER_VERTICAL);
            LinearLayout copy = ui.column();
            copy.setPadding(ui.dp(18), ui.dp(14), ui.dp(18), ui.dp(10));
            copy.setBackground(ui.panel(SURFACE, 0, 14));
            heading = ui.text("", 20, MINT, true);
            heading.setLines(2);
            heading.setEllipsize(TextUtils.TruncateAt.END);
            heading.setGravity(Gravity.CENTER_VERTICAL);
            copy.addView(heading);
            content = ui.text("", FONT_SIZES[fontIndex], TEXT, false);
            content.setBreakStrategy(LineBreaker.BREAK_STRATEGY_SIMPLE);
            content.setHyphenationFrequency(Layout.HYPHENATION_FREQUENCY_NONE);
            content.setLineSpacing(ui.dp(4), 1f);
            content.setTextDirection(View.TEXT_DIRECTION_FIRST_STRONG_LTR);
            copy.addView(content, fillWithTopMargin(7));
            columns.addView(copy, new LinearLayout.LayoutParams(0, -1, 60));

            FrameLayout illustration = new FrameLayout(MainActivity.this);
            illustration.setBackground(ui.panel(SURFACE, 0, 14));
            illustration.setClipToOutline(true);
            picture = new ImageView(MainActivity.this);
            picture.setScaleType(ImageView.ScaleType.FIT_CENTER);
            illustration.addView(picture, new FrameLayout.LayoutParams(-1, -1));
            pictureStatus = ui.text("", 16, MUTED, false);
            pictureStatus.setGravity(Gravity.CENTER);
            illustration.addView(pictureStatus, new FrameLayout.LayoutParams(-1, -1));
            LinearLayout.LayoutParams pictureLayout = new LinearLayout.LayoutParams(0, -1, 40);
            pictureLayout.leftMargin = ui.dp(14);
            columns.addView(illustration, pictureLayout);
            screen.addView(columns, fillWithTopMargin(10));

            LinearLayout footer = ui.row();
            String returnHint = progress.stage == Progress.QUIZ ? "返回 继续答题" : "返回 文章列表";
            TextView hint = ui.text("←/→ 翻页 · ↑ 字号 · " + returnHint, 15, MUTED, false);
            footer.addView(hint, new LinearLayout.LayoutParams(0, -2, 1));
            size = ui.button(fontLabel(), this::changeFont);
            next = ui.button("下一页", this::forward);
            size.setNextFocusDownId(next.getId());
            size.setNextFocusUpId(next.getId());
            next.setNextFocusUpId(size.getId());
            next.setNextFocusDownId(size.getId());
            footer.addView(size);
            LinearLayout.LayoutParams nextLayout = new LinearLayout.LayoutParams(-2, -2);
            nextLayout.leftMargin = ui.dp(10);
            footer.addView(next, nextLayout);
            ui.add(screen, footer, 10);
            next.requestFocus();
            content.addOnLayoutChangeListener((v, l, t, r, b, ol, ot, or, ob) -> {
                if (r - l != or - ol || b - t != ob - ot) reflow();
            });
        }

        private void reflow() {
            int width = content.getWidth();
            int height = content.getHeight();
            if (width <= 0 || height <= 0) return;
            pages = ReaderPages.paginate(current.article().units(), content, width, height, MINT);
            position = ReaderPages.locate(pages, progress.unit, progress.offset);
            showPage();
        }

        private void showPage() {
            if (pages.isEmpty()) return;
            ReaderPages.Page page = pages.get(position);
            ReadingPack.Unit unit = current.article().units().get(page.unit());
            heading.setText(unit.heading());
            content.setText(page.text());
            counter.setText(getString(R.string.page_position, position + 1, pages.size()));
            String quizAction = progress.stage == Progress.QUIZ ? "继续答题" : "开始答题";
            next.setText(position == pages.size() - 1 ? quizAction : "下一页");
            showImage(unit.image());
        }

        private void showImage(String path) {
            int width = picture.getWidth();
            int height = picture.getHeight();
            if (width == 0 || height == 0) {
                picture.post(() -> {
                    if (reader == this && picture.getWidth() > 0 && picture.getHeight() > 0) showImage(path);
                });
                return;
            }
            if (path.equals(imagePath) && width == imageWidth && height == imageHeight) return;
            imagePath = path;
            imageWidth = width;
            imageHeight = height;
            picture.setImageDrawable(null);
            picture.setContentDescription(current.pack().imageAlt.get(path));
            pictureStatus.setVisibility(View.VISIBLE);
            pictureStatus.setText("正在载入插图…");
            tasks.execute(() -> {
                Bitmap image = null;
                try {
                    image = current.pack().image(path, width, height);
                } catch (IOException error) {
                    Log.w("SimpleDuTV", "无法显示阅读插图", error);
                }
                Bitmap loaded = image;
                runOnUiThread(() -> {
                    if (isDestroyed() || reader != this || !path.equals(imagePath)
                            || width != imageWidth || height != imageHeight) {
                        if (loaded != null) loaded.recycle();
                        return;
                    }
                    if (loaded == null) {
                        pictureStatus.setText("插图暂时无法显示");
                    } else {
                        picture.setImageBitmap(loaded);
                        pictureStatus.setVisibility(View.GONE);
                    }
                });
            });
        }

        private String fontLabel() {
            return "字号  " + new String[]{"小", "中", "大"}[fontIndex];
        }

        private void changeFont() {
            fontIndex = (fontIndex + 1) % FONT_SIZES.length;
            prefs.edit().putInt("font_size", fontIndex).apply();
            size.setText(fontLabel());
            content.setTextSize(FONT_SIZES[fontIndex]);
            reflow();
        }

        private void move(int delta) {
            if (pages.isEmpty()) return;
            int destination = position + delta;
            if (destination < 0 || destination >= pages.size()) return;
            position = destination;
            ReaderPages.Page page = pages.get(position);
            progress.unit = page.unit();
            progress.offset = page.offset();
            save();
            showPage();
        }

        private void forward() {
            if (pages.isEmpty()) return;
            if (position < pages.size() - 1) {
                move(1);
            } else {
                progress.stage = Progress.QUIZ;
                save();
                quizScreen(false);
            }
        }
    }

    private void quizScreen(boolean submittedJustNow) {
        LinearLayout screen = screen();
        ReadingPack.Question question = book.article().questions().get(progress.question);
        int savedAnswer = progress.answers[progress.question];
        boolean submitted = savedAnswer >= 0;
        int currentNumber = progress.question + 1;
        int total = progress.answers.length;

        LinearLayout header = ui.row();
        TextView title = ui.text("阅读理解", 28, TEXT, true);
        header.addView(title, new LinearLayout.LayoutParams(0, -2, 1));
        header.addView(ui.text("第 " + currentNumber + " / " + total + " 题", 19, MINT, true));
        Button reread = ui.button("回看正文", () -> reader = new ReaderScreen());
        LinearLayout.LayoutParams rereadLayout = new LinearLayout.LayoutParams(-2, -2);
        rereadLayout.leftMargin = ui.dp(16);
        header.addView(reread, rereadLayout);
        screen.addView(header);
        questionScroll = scroll();
        LinearLayout items = ui.column();
        questionScroll.addView(items);
        screen.addView(questionScroll, fillWithTopMargin(9));

        Button prompt = textCard(question.prompt());
        prompt.setNextFocusUpId(reread.getId());
        reread.setNextFocusDownId(prompt.getId());
        ui.add(items, prompt, 0);
        Button[] choices = new Button[4];
        for (int index = 0; index < choices.length; index++) {
            int option = index;
            String optionText = optionLabel(question, index, !submitted && index == progress.selection);
            if (submitted && index == savedAnswer) optionText += "   ·  你的选择";
            if (submitted && index == question.answer()) optionText += "   ·  正确答案";
            choices[index] = ui.button(optionText, () -> {
                if (submitted) return;
                progress.selection = option;
                save();
                for (int choice = 0; choice < choices.length; choice++) {
                    choices[choice].setText(optionLabel(question, choice, choice == option));
                    ui.styleButton(choices[choice], choice == option);
                }
            });
            ui.styleButton(choices[index], index == (submitted ? question.answer() : progress.selection));
            ui.add(items, choices[index], 7);
        }

        Button feedback = null;
        if (submitted) {
            String summary = savedAnswer == question.answer() ? "回答正确" : "正确答案是 " + letter(question.answer());
            String explanation = question.explanation();
            feedback = textCard(explanation.isEmpty() ? summary : summary + "\n" + explanation);
            ui.styleButton(feedback, true);
            ui.add(items, feedback, 8);
        }

        String action = submitted ? (currentNumber == total ? "查看结果" : "下一题") : "确认提交";
        Button confirm = ui.button(action, () -> {
            if (!submitted) {
                if (progress.selection < 0) {
                    Toast.makeText(this, "请先选一个答案", Toast.LENGTH_SHORT).show();
                    return;
                }
                progress.submitSelection();
                save();
                quizScreen(true);
            } else if (currentNumber < total) {
                progress.question++;
                progress.selection = -1;
                save();
                quizScreen(false);
            } else {
                progress.stage = Progress.RESULT;
                save();
                resultScreen();
            }
        });
        ui.add(items, confirm, 8);
        ui.add(screen, ui.text("↑/↓ 移动高亮 · OK 确认 · ←/→ 滚动长题目", 15, MUTED, false), 8);
        if (submittedJustNow && feedback != null) feedback.requestFocus();
        else prompt.requestFocus();
    }

    private void resultScreen() {
        LinearLayout screen = screen();
        screen.setGravity(Gravity.CENTER);
        int correct = 0;
        for (int index = 0; index < progress.answers.length; index++) {
            if (progress.answers[index] == book.article().questions().get(index).answer()) correct++;
        }
        addCentered(screen, ui.text(book.article().title(), 23, MUTED, true), 0);
        addCentered(screen, ui.text("阅读与答题完成", 34, TEXT, true), 9);
        addCentered(screen, ui.text("答对 " + correct + " / " + progress.answers.length + " 题", 36, MINT, true), 14);
        LinearLayout actions = ui.row();
        actions.setGravity(Gravity.CENTER);
        Button back = ui.button(showingRead ? "返回已读文章" : "返回未读文章", this::backToLibrary);
        actions.addView(back);
        addAction(actions, "重新答题", () -> restart(false));
        addAction(actions, "从头阅读", () -> restart(true));
        ui.add(screen, actions, 25);
        back.requestFocus();
    }

    private void addAction(LinearLayout row, String name, Runnable action) {
        LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(-2, -2);
        params.leftMargin = ui.dp(12);
        row.addView(ui.button(name, action), params);
    }

    private void restart(boolean readAgain) {
        progress.restart(readAgain);
        save();
        openStage();
    }

    private void save() {
        progress.save(prefs, book);
    }

    private LinearLayout screen() {
        reader = null;
        questionScroll = null;
        root.removeAllViews();
        LinearLayout screen = ui.column();
        screen.setPadding(ui.dp(36), ui.dp(22), ui.dp(36), ui.dp(22));
        root.addView(screen, new FrameLayout.LayoutParams(-1, -1));
        return screen;
    }

    private ScrollView scroll() {
        ScrollView view = new ScrollView(this);
        view.setFocusable(false);
        view.setDescendantFocusability(ScrollView.FOCUS_AFTER_DESCENDANTS);
        view.setVerticalScrollBarEnabled(false);
        return view;
    }

    private Button textCard(CharSequence label) {
        Button view = ui.button(label, () -> {});
        view.setClickable(false);
        view.setTextSize(21);
        return view;
    }

    private LinearLayout.LayoutParams fillWithTopMargin(int gap) {
        LinearLayout.LayoutParams layout = new LinearLayout.LayoutParams(-1, 0, 1);
        layout.topMargin = ui.dp(gap);
        return layout;
    }

    private void addCentered(LinearLayout screen, TextView text, int gap) {
        text.setGravity(Gravity.CENTER);
        ui.add(screen, text, gap);
    }

    private static String letter(int choice) {
        return String.valueOf((char) ('A' + choice));
    }

    private static String optionLabel(ReadingPack.Question question, int choice, boolean selected) {
        return letter(choice) + "   " + question.options().get(choice) + (selected ? "   ·  已选" : "");
    }
}
