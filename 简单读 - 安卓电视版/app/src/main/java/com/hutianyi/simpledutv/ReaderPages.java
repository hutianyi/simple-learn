package com.hutianyi.simpledutv;

import android.graphics.Typeface;
import android.graphics.text.LineBreaker;
import android.text.Layout;
import android.text.Spannable;
import android.text.SpannableStringBuilder;
import android.text.StaticLayout;
import android.text.style.ForegroundColorSpan;
import android.text.style.StyleSpan;
import android.widget.TextView;

import java.util.ArrayList;
import java.util.List;

final class ReaderPages {
    record Page(int unit, int offset, CharSequence text) {}

    static List<Page> paginate(List<ReadingPack.Unit> units, TextView body, int width, int height, int accent) {
        List<Page> pages = new ArrayList<>();
        for (int unit = 0; unit < units.size(); unit++) {
            SpannableStringBuilder text = new SpannableStringBuilder();
            for (ReadingPack.Run run : units.get(unit).runs()) {
                int start = text.length();
                text.append(run.text());
                if (run.target()) {
                    text.setSpan(new StyleSpan(Typeface.BOLD), start, text.length(), Spannable.SPAN_EXCLUSIVE_EXCLUSIVE);
                    text.setSpan(new ForegroundColorSpan(accent), start, text.length(), Spannable.SPAN_EXCLUSIVE_EXCLUSIVE);
                }
            }
            StaticLayout layout = StaticLayout.Builder.obtain(text, 0, text.length(), body.getPaint(), width)
                    .setIncludePad(false)
                    .setBreakStrategy(LineBreaker.BREAK_STRATEGY_SIMPLE)
                    .setHyphenationFrequency(Layout.HYPHENATION_FREQUENCY_NONE)
                    .setLineSpacing(body.getLineSpacingExtra(), body.getLineSpacingMultiplier())
                    .build();
            int first = 0;
            while (first < layout.getLineCount()) {
                int last = first + 1;
                while (last < layout.getLineCount()
                        && layout.getLineBottom(last) - layout.getLineTop(first) <= height) {
                    last++;
                }
                int start = layout.getLineStart(first);
                int end = layout.getLineEnd(last - 1);
                if (end > start) pages.add(new Page(unit, start, text.subSequence(start, end)));
                first = last;
            }
        }
        return pages;
    }

    static int locate(List<Page> pages, int unit, int offset) {
        for (int index = pages.size() - 1; index >= 0; index--) {
            Page page = pages.get(index);
            if (page.unit() == unit && page.offset() <= offset) return index;
        }
        return 0;
    }
}
