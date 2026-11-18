package com.hutianyi.simpledutv;

import android.content.Context;
import android.content.res.ColorStateList;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.graphics.drawable.StateListDrawable;
import android.view.Gravity;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.TextView;

final class TvViews {
    static final int BACKGROUND = 0xFF111B22;
    static final int SURFACE = 0xFF1B2A33;
    static final int OUTLINE = 0xFF39505C;
    static final int TEXT = 0xFFF2F6F4;
    static final int MUTED = 0xFFB2C4CC;
    static final int MINT = 0xFF9DE1C5;
    static final int GREEN_SURFACE = 0xFF264F47;
    static final int ERROR = 0xFFF6CBA5;

    private final Context context;

    TvViews(Context context) {
        this.context = context;
    }

    int dp(int number) {
        return Math.round(number * context.getResources().getDisplayMetrics().density);
    }

    LinearLayout row() {
        LinearLayout view = new LinearLayout(context);
        view.setOrientation(LinearLayout.HORIZONTAL);
        view.setGravity(Gravity.CENTER_VERTICAL);
        return view;
    }

    LinearLayout column() {
        LinearLayout view = new LinearLayout(context);
        view.setOrientation(LinearLayout.VERTICAL);
        return view;
    }

    TextView text(CharSequence label, int sp, int color, boolean bold) {
        TextView view = new TextView(context);
        view.setText(label);
        view.setTextSize(sp);
        view.setTextColor(color);
        view.setIncludeFontPadding(false);
        if (bold) view.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        return view;
    }

    Button button(CharSequence label, Runnable action) {
        Button view = new Button(context);
        view.setId(android.view.View.generateViewId());
        view.setAllCaps(false);
        view.setText(label);
        view.setTextSize(18);
        view.setGravity(Gravity.CENTER_VERTICAL | Gravity.START);
        view.setLetterSpacing(0);
        view.setMinHeight(dp(48));
        view.setMinimumHeight(dp(48));
        view.setMinimumWidth(0);
        view.setMinWidth(0);
        view.setPadding(dp(18), dp(10), dp(18), dp(10));
        view.setStateListAnimator(null);
        view.setFocusable(true);
        view.setOnClickListener(v -> action.run());
        styleButton(view, false);
        return view;
    }

    void styleButton(Button view, boolean selected) {
        StateListDrawable background = new StateListDrawable();
        int[] focused = {android.R.attr.state_focused};
        background.addState(focused, panel(MINT, MINT, 12));
        background.addState(new int[0], panel(selected ? GREEN_SURFACE : SURFACE, selected ? MINT : OUTLINE, 12));
        view.setBackground(background);
        view.setTextColor(new ColorStateList(new int[][]{focused, new int[0]},
                new int[]{BACKGROUND, selected ? MINT : TEXT}));
    }

    GradientDrawable panel(int fill, int stroke, int radius) {
        GradientDrawable background = new GradientDrawable();
        background.setColor(fill);
        background.setCornerRadius(dp(radius));
        if (stroke != 0) background.setStroke(dp(1), stroke);
        return background;
    }

    void add(LinearLayout column, android.view.View view, int gap) {
        LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(-1, -2);
        params.topMargin = dp(gap);
        column.addView(view, params);
    }
}
