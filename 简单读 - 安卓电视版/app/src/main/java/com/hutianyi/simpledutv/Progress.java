package com.hutianyi.simpledutv;

import android.content.SharedPreferences;

import java.util.Arrays;

final class Progress {
    static final int READING = 0;
    static final int QUIZ = 1;
    static final int RESULT = 2;

    int stage;
    int unit;
    int offset;
    int question;
    int selection = -1;
    final int[] answers;
    private boolean completed;

    private Progress(int questions) {
        answers = new int[questions];
        Arrays.fill(answers, -1);
    }

    static Progress load(SharedPreferences prefs, Library.Book book) {
        int count = book.article().questions().size();
        Progress result = new Progress(count);
        String value = prefs.getString(book.key(), "");
        String[] fields = value.split(",", -1);
        int completedField = count + 5;
        if (fields.length != completedField && fields.length != completedField + 1) return result;
        try {
            int stage = bounded(fields[0], READING, RESULT);
            int unit = bounded(fields[1], 0, book.article().units().size() - 1);
            int offset = bounded(fields[2], 0, Integer.MAX_VALUE);
            int question = bounded(fields[3], 0, count - 1);
            int selection = bounded(fields[4], -1, 3);
            boolean completed = fields.length > completedField && bounded(fields[completedField], 0, 1) == 1;
            int[] answers = new int[count];
            for (int index = 0; index < count; index++) {
                int answer = bounded(fields[index + 5], -1, 3);
                if ((index < question || stage == RESULT) && answer < 0) return result;
                if (index > question && answer >= 0) return result;
                if (stage == READING && answer >= 0) return result;
                answers[index] = answer;
            }
            result.stage = stage;
            result.unit = unit;
            result.offset = offset;
            result.question = question;
            result.selection = selection;
            System.arraycopy(answers, 0, result.answers, 0, count);
            // Older records reached the quiz only after reading the last page.
            result.completed = completed || result.allAnswersSubmitted();
        } catch (NumberFormatException invalid) {
            android.util.Log.w("SimpleDuTV", "已保存的进度无效，恢复初始状态。", invalid);
        }
        return result;
    }

    void save(SharedPreferences prefs, Library.Book book) {
        StringBuilder value = new StringBuilder().append(stage).append(',').append(unit).append(',')
                .append(offset).append(',').append(question).append(',').append(selection);
        for (int answer : answers) value.append(',').append(answer);
        value.append(',').append(completed ? 1 : 0);
        prefs.edit().putString(book.key(), value.toString()).apply();
    }

    void submitSelection() {
        answers[question] = selection;
        if (allAnswersSubmitted()) completed = true;
    }

    void restart(boolean readAgain) {
        stage = readAgain ? READING : QUIZ;
        question = 0;
        selection = -1;
        Arrays.fill(answers, -1);
        if (readAgain) {
            unit = 0;
            offset = 0;
        }
    }

    boolean isRead(boolean markedRead) {
        return markedRead || completed;
    }

    String activityLabel() {
        if (stage == QUIZ) return "答题中";
        return stage == READING && (unit != 0 || offset != 0) ? "阅读中" : "";
    }

    private boolean allAnswersSubmitted() {
        for (int answer : answers) {
            if (answer < 0) return false;
        }
        return true;
    }

    private static int bounded(String field, int min, int max) {
        int value = Integer.parseInt(field);
        if (value < min || value > max) throw new NumberFormatException("进度超出范围");
        return value;
    }
}
