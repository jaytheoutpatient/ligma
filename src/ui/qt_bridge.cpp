// Small Qt bridge for values that libqt6zig does not expose directly.
//
// QVariant has no generated constructor taking a QIcon, but QAbstractItemModel
// expects one for DecorationRole. Keeping this in C++ avoids a second
// hand-written Zig representation of QVariant's internal storage.

#include <QAbstractAnimation>
#include <QAbstractItemView>
#include <QCloseEvent>
#include <QApplication>
#include <QCheckBox>
#include <QDockWidget>
#include <QEasingCurve>
#include <QEvent>
#include <QFontMetrics>
#include <QIcon>
#include <QKeyEvent>
#include <QLinearGradient>
#include <QMouseEvent>
#include <QPainter>
#include <QPainterPath>
#include <QPalette>
#include <QPropertyAnimation>
#include <QScrollBar>
#include <QString>
#include <QStyledItemDelegate>
#include <QTreeView>
#include <QVariant>
#include <QWheelEvent>
#include <QWidget>

#include <algorithm>

extern "C" void ligma_dock_slide_hide(void *dock_pointer, int horizontal, int duration_ms, int minimum);

namespace {

QColor row_gradient_start(59, 130, 246);
QColor row_gradient_end(99, 102, 241);

QRect treeRowRect(const QTreeView *tree, const QModelIndex &index, const QRect &fallback)
{
    const QRect cell = tree->visualRect(index.sibling(index.row(), 0));
    const int height = cell.height() > 0 ? cell.height() : fallback.height();
    if (height <= 0)
        return fallback;
    return QRect(0, cell.top(), tree->viewport()->width(), height);
}

using TypingCallback = int (*)(unsigned int codepoint);

class TypingFilter final : public QObject {
  public:
    TypingFilter(QObject *parent, TypingCallback callback)
        : QObject(parent)
        , callback_(callback)
    {
    }

    bool eventFilter(QObject *watched, QEvent *event) override
    {
        if (event->type() != QEvent::KeyPress)
            return QObject::eventFilter(watched, event);
        auto *key = static_cast<QKeyEvent *>(event);
        if ((key->modifiers() & (Qt::ControlModifier | Qt::AltModifier | Qt::MetaModifier)) != 0)
            return QObject::eventFilter(watched, event);
        const QString text = key->text();
        if (text.isEmpty())
            return QObject::eventFilter(watched, event);
        const uint codepoint = text.at(0).unicode();
        if (codepoint < 32)
            return QObject::eventFilter(watched, event);
        if (callback_ != nullptr && callback_(codepoint) != 0)
            return true;
        return QObject::eventFilter(watched, event);
    }

  private:
    TypingCallback callback_;
};

class RowToggleFilter final : public QObject {
  public:
    RowToggleFilter(QObject *parent, QCheckBox *box)
        : QObject(parent)
        , box_(box)
    {
    }

    bool eventFilter(QObject *watched, QEvent *event) override
    {
        if (event->type() == QEvent::MouseButtonRelease) {
            auto *mouse = static_cast<QMouseEvent *>(event);
            if (mouse->button() == Qt::LeftButton && box_ != nullptr) {
                box_->toggle();
                return true;
            }
        }
        return QObject::eventFilter(watched, event);
    }

  private:
    QCheckBox *box_;
};

QStringList wrapGridText(const QString &text, const QFontMetrics &metrics, int width)
{
    QStringList lines;
    if (text.isEmpty() || width <= 0)
        return lines;
    QString remaining = text;
    for (int line = 0; line < 3 && !remaining.isEmpty(); ++line) {
        if (metrics.horizontalAdvance(remaining) <= width) {
            lines.append(remaining);
            break;
        }
        int fit = 0;
        while (fit < remaining.size() &&
            metrics.horizontalAdvance(remaining.left(fit + 1)) <= width)
            ++fit;
        if (fit <= 0)
            fit = 1;
        if (line == 2) {
            lines.append(metrics.elidedText(remaining, Qt::ElideRight, width));
            break;
        }
        int cut = remaining.lastIndexOf(QLatin1Char(' '), fit);
        if (cut <= 0)
            cut = fit;
        const QString first = remaining.left(cut).trimmed();
        remaining = remaining.mid(cut).trimmed();
        if (!first.isEmpty())
            lines.append(first);
    }
    return lines;
}

class CenteredGridDelegate final : public QStyledItemDelegate {
  public:
    explicit CenteredGridDelegate(QObject *parent = nullptr)
        : QStyledItemDelegate(parent)
    {
    }

    void initStyleOption(QStyleOptionViewItem *option, const QModelIndex &index) const override
    {
        QStyledItemDelegate::initStyleOption(option, index);
        option->displayAlignment = Qt::AlignHCenter | Qt::AlignTop;
    }

    void setCellSize(const QSize &size) { cell_size_ = size; }

    QSize sizeHint(const QStyleOptionViewItem &option, const QModelIndex &index) const override
    {
        const QSize base = QStyledItemDelegate::sizeHint(option, index);
        if (!cell_size_.isValid() || cell_size_.isEmpty())
            return base;
        return QSize(std::max(base.width(), cell_size_.width()),
            std::max(base.height(), cell_size_.height()));
    }

    void paint(QPainter *painter, const QStyleOptionViewItem &option,
        const QModelIndex &index) const override
    {
        QStyleOptionViewItem opt = option;
        initStyleOption(&opt, index);
        const QString name = opt.text;
        const QIcon icon = qvariant_cast<QIcon>(index.data(Qt::DecorationRole));
        const bool selected = (opt.state & QStyle::State_Selected) != 0;

        // Let the style paint the item background (including the gradient
        // selection and hover rules) without its single-line label.
        QStyleOptionViewItem background = opt;
        background.text.clear();
        background.icon = QIcon();
        QStyle *style = background.widget ? background.widget->style() : QApplication::style();
        style->drawControl(QStyle::CE_ItemViewItem, &background, painter, background.widget);

        const QRect cell = opt.rect;
        QSize iconSize = opt.decorationSize;
        if (!iconSize.isValid() || iconSize.isEmpty())
            iconSize = QSize(64, 64);
        const int margin = 6;
        const QRect iconRect(cell.x() + (cell.width() - iconSize.width()) / 2,
            cell.y() + margin, iconSize.width(), iconSize.height());
        if (!icon.isNull())
            icon.paint(painter, iconRect, Qt::AlignCenter, QIcon::Normal, QIcon::Off);

        if (name.isEmpty())
            return;
        QFontMetrics metrics(opt.font);
        const int textWidth = std::max(1, cell.width() - 12);
        const QStringList lines = wrapGridText(name, metrics, textWidth);
        if (lines.isEmpty())
            return;

        painter->save();
        painter->setFont(opt.font);
        painter->setPen(selected ? QColor(Qt::white) : opt.palette.color(QPalette::Text));
        const int lineHeight = metrics.height();
        const int available = std::max(0, cell.bottom() - (iconRect.bottom() + 5));
        const int maxLines = std::min<int>(
            {3, static_cast<int>(lines.size()), std::max(available / lineHeight, 1)});
        int y = iconRect.bottom() + 5;
        for (int i = 0; i < maxLines; ++i) {
            const QRect lineRect(cell.x() + 6, y, textWidth, lineHeight);
            painter->drawText(lineRect, Qt::AlignHCenter | Qt::AlignTop,
                lines.at(i));
            y += lineHeight;
        }
        painter->restore();
    }

  private:
    QSize cell_size_;
};

class GradientRowDelegate final : public QStyledItemDelegate {
  public:
    explicit GradientRowDelegate(QAbstractItemView *view)
        : QStyledItemDelegate(view)
        , view_(view)
    {
        if (QWidget *viewport = view_->viewport()) {
            viewport->setMouseTracking(true);
            viewport->installEventFilter(this);
        }
        if (QScrollBar *bar = view_->verticalScrollBar()) {
            QObject::connect(bar, &QScrollBar::valueChanged, this,
                [this](int) { updateHoverFromCursor(); });
        }
        if (QScrollBar *bar = view_->horizontalScrollBar()) {
            QObject::connect(bar, &QScrollBar::valueChanged, this,
                [this](int) { updateHoverFromCursor(); });
        }
    }

    bool eventFilter(QObject *watched, QEvent *event) override
    {
        if (watched == view_->viewport()) {
            if (event->type() == QEvent::MouseMove) {
                const auto *motion = static_cast<QMouseEvent *>(event);
                updateHover(view_->indexAt(motion->position().toPoint()).row());
            } else if (event->type() == QEvent::Leave) {
                updateHover(-1);
            }
        }
        return QStyledItemDelegate::eventFilter(watched, event);
    }

    void paint(QPainter *painter, const QStyleOptionViewItem &option,
        const QModelIndex &index) const override
    {
        QStyleOptionViewItem opt = option;
        initStyleOption(&opt, index);

        // initStyleOption rebuilds the state from the index and can drop the
        // view's selection bit, so read it from the untouched option first.
        const bool selected = (option.state & QStyle::State_Selected) != 0;
        const bool hovered = index.row() == hover_row_;
        if (selected || hovered) {
            const auto *tree = qobject_cast<const QTreeView *>(view_);
            const QRect row = tree != nullptr
                ? treeRowRect(tree, index, opt.rect)
                : opt.rect;
            const QRect painted = row.adjusted(2, 1, -2, -1);
            QLinearGradient gradient(painted.topLeft(),
                QPointF(painted.right() + 1, painted.top()));
            const bool light = lightBackground();
            if (selected) {
                gradient.setColorAt(0.0, withAlpha(row_gradient_start, light ? 0.34 : 0.88));
                gradient.setColorAt(0.6, withAlpha(row_gradient_end, light ? 0.16 : 0.50));
                gradient.setColorAt(1.0, withAlpha(row_gradient_end, 0.0));
            } else {
                gradient.setColorAt(0.0, withAlpha(row_gradient_start, light ? 0.20 : 0.34));
                gradient.setColorAt(1.0, withAlpha(row_gradient_end, 0.0));
            }

            QPainterPath path;
            path.addRoundedRect(painted, 6, 6);
            painter->save();
            painter->setClipRect(opt.rect);
            painter->setRenderHint(QPainter::Antialiasing, true);
            painter->fillPath(path, gradient);
            painter->restore();

            opt.state &= ~(QStyle::State_Selected | QStyle::State_MouseOver);
            if (selected) {
                const QColor selectedText = light ? QColor(QStringLiteral("#171a1f"))
                                                  : QColor(Qt::white);
                opt.palette.setColor(QPalette::Text, selectedText);
                opt.palette.setColor(QPalette::WindowText, selectedText);
                opt.palette.setColor(QPalette::HighlightedText, selectedText);
            }
        }

        QStyledItemDelegate::paint(painter, opt, index);
    }

  public:
    void refreshHover() { updateHoverFromCursor(); }

  private:
    static bool lightBackground()
    {
        return QApplication::palette().color(QPalette::Base).lightness() > 128;
    }

    static QColor withAlpha(const QColor &color, qreal alpha)
    {
        QColor result = color;
        result.setAlphaF(alpha);
        return result;
    }

    void updateHover(int row)
    {
        if (row == hover_row_)
            return;
        hover_row_ = row;
        if (QWidget *viewport = view_->viewport())
            viewport->update();
    }

    void updateHoverFromCursor()
    {
        if (view_->viewport() == nullptr)
            return;
        const QPoint local = view_->viewport()->mapFromGlobal(QCursor::pos());
        if (!view_->viewport()->rect().contains(local)) {
            updateHover(-1);
            return;
        }
        updateHover(view_->indexAt(local).row());
    }

    QAbstractItemView *view_;
    int hover_row_ = -1;
};



class SmoothScrollFilter final : public QObject {
  public:
    SmoothScrollFilter(QWidget *viewport, QScrollBar *bar, QAbstractItemView *view)
        : QObject(viewport)
        , bar_(bar)
        , view_(view)
        , animation_(new QPropertyAnimation(bar, "value", this))
    {
        animation_->setDuration(100);
        animation_->setEasingCurve(QEasingCurve::OutCubic);
        QObject::connect(bar, &QScrollBar::sliderPressed, animation_,
            &QPropertyAnimation::stop);
    }

    bool eventFilter(QObject *watched, QEvent *event) override
    {
        if (event->type() != QEvent::Wheel || bar_ == nullptr ||
            bar_->maximum() <= bar_->minimum()) {
            return QObject::eventFilter(watched, event);
        }

        auto *wheel = static_cast<QWheelEvent *>(event);
        if (wheel->modifiers() & (Qt::ControlModifier | Qt::ShiftModifier))
            return QObject::eventFilter(watched, event);
        // Qt uses the same sign for pixelDelta and angleDelta: positive means
        // scrolling up. QAbstractItemView applies `value - delta`, so negate
        // both here; using pixelDelta directly made touchpad scrolling reverse.
        const int pixel_delta = -wheel->pixelDelta().y();
        int distance = 0;
        if (pixel_delta != 0) {
            // Touchpads report fine pixel deltas. Doubling keeps a light swipe
            // responsive without making a full swipe overshoot.
            const int magnitude = pixel_delta < 0 ? -pixel_delta : pixel_delta;
            distance = (pixel_delta < 0 ? -1 : 1) * std::max(magnitude * 2, 2);
        } else {
            const int angle = wheel->angleDelta().y();
            if (angle == 0)
                return QObject::eventFilter(watched, event);
            const bool per_pixel = view_ != nullptr &&
                view_->verticalScrollMode() == QAbstractItemView::ScrollPerPixel;
            const int unit = per_pixel
                ? std::max(bar_->singleStep() * 4, 160)
                : std::max(bar_->singleStep() * 3, 48);
            distance = (angle > 0 ? -1 : 1) * unit;
        }

        animation_->stop();
        const int start = bar_->value();
        const int target = std::clamp(start + distance, bar_->minimum(), bar_->maximum());
        if (target == start)
            return true;
        animation_->setStartValue(start);
        animation_->setEndValue(target);
        animation_->start();
        return true;
    }

  private:
    QScrollBar *bar_;
    QAbstractItemView *view_;
    QPropertyAnimation *animation_;
};

class LigmaDockWidget final : public QDockWidget {
  public:
    LigmaDockWidget(const QString &title, QWidget *parent, bool horizontal,
        int duration_ms, int minimum)
        : QDockWidget(title, parent)
        , horizontal_(horizontal)
        , duration_ms_(duration_ms)
        , minimum_(minimum)
    {
    }

  protected:
    void closeEvent(QCloseEvent *event) override
    {
        event->ignore();
        ligma_dock_slide_hide(this, horizontal_ ? 1 : 0, duration_ms_, minimum_);
    }

  private:
    bool horizontal_;
    int duration_ms_;
    int minimum_;
};

void stopDockAnimation(QDockWidget *dock)
{
    auto *existing = dock->findChild<QPropertyAnimation *>("ligmaDockAnimation");
    if (existing != nullptr) {
        existing->stop();
        existing->deleteLater();
    }
}

void setDockMinimum(QDockWidget *dock, bool horizontal, int minimum)
{
    if (horizontal) {
        dock->setMinimumWidth(std::max(minimum, 0));
        dock->setMaximumWidth(QWIDGETSIZE_MAX);
    } else {
        dock->setMinimumHeight(std::max(minimum, 0));
        dock->setMaximumHeight(QWIDGETSIZE_MAX);
    }
}

void startDockAnimation(QDockWidget *dock, bool horizontal, int start, int end,
    int duration_ms, int minimum, bool hide_after)
{
    stopDockAnimation(dock);
    auto *animation = new QPropertyAnimation(
        dock, horizontal ? "maximumWidth" : "maximumHeight", dock);
    animation->setObjectName("ligmaDockAnimation");
    animation->setDuration(std::max(duration_ms, 1));
    animation->setEasingCurve(QEasingCurve::OutCubic);
    animation->setStartValue(start);
    animation->setEndValue(end);
    QObject::connect(animation, &QPropertyAnimation::finished, dock,
        [dock, horizontal, minimum, hide_after]() {
            if (hide_after)
                dock->hide();
            setDockMinimum(dock, horizontal, minimum);
        });
    animation->start(QAbstractAnimation::DeleteWhenStopped);
}

} // namespace

extern "C" {

void *ligma_qvariant_from_icon(void *icon)
{
    if (icon == nullptr)
        return nullptr;
    return new QVariant(*static_cast<QIcon *>(icon));
}

/// Applies the window's background tint without fading its contents. The
/// tint comes from the active palette's Window color, so Light, Dark, and
/// Matugen all keep their own character. Below full opacity the top-level
/// window becomes translucent and the large file-view surfaces stop painting
/// their own opaque background; labels, icons, and input fields stay opaque.
void ligma_apply_window_chrome(void *window_pointer, double opacity, int compact_menus)
{
    auto *window = static_cast<QWidget *>(window_pointer);
    if (window == nullptr)
        return;

    const double clamped = std::clamp(opacity, 0.0, 1.0);
    const bool translucent = clamped < 0.999;
    window->setAttribute(Qt::WA_StyledBackground, true);
    window->setAttribute(Qt::WA_TranslucentBackground, translucent);
    if (!translucent)
        window->setAttribute(Qt::WA_NoSystemBackground, false);

    QString style;
    if (translucent) {
        const QColor tint = QApplication::palette().color(QPalette::Window);
        const int alpha = qRound(clamped * 255.0);
        const QString background = QString("rgba(%1, %2, %3, %4)")
                                       .arg(tint.red())
                                       .arg(tint.green())
                                       .arg(tint.blue())
                                       .arg(alpha);
        style += "QMainWindow { background: transparent; }";
        style += "QSplitter { background-color: " + background + "; }";
        style += "QTabWidget, QTabWidget::pane, QTabBar, QStackedWidget "
                 "{ background: transparent; }";
        style += "QTreeView, QListView { background: transparent; }";
        style += "QHeaderView { background-color: " + background + "; }";
        style += "QHeaderView::section { background-color: " + background + "; "
                 "border: none; padding: 2px 4px; }";
        style += "QMenuBar, QMenuBar::item, QStatusBar "
                 "{ background-color: " + background + "; }";
    }

    if (compact_menus != 0) {
        style += "QMenu { padding: 3px; }";
        style += "QMenu::item { padding: 4px 28px 4px 24px; }";
        style += "QMenu::separator { height: 1px; margin: 3px 8px; "
                 "background: rgba(127, 127, 127, 0.25); }";
    }

    window->setStyleSheet(style);
    window->update();
}

void ligma_checkbox_row_click(void *text_pointer, void *checkbox_pointer)
{
    auto *text = static_cast<QWidget *>(text_pointer);
    auto *box = static_cast<QCheckBox *>(checkbox_pointer);
    if (text != nullptr && box != nullptr)
        text->installEventFilter(new RowToggleFilter(text, box));
}

void ligma_attach_typing_filter(void *view_pointer, TypingCallback callback)
{
    auto *view = static_cast<QAbstractItemView *>(view_pointer);
    if (view == nullptr || view->viewport() == nullptr)
        return;
    view->viewport()->installEventFilter(new TypingFilter(view->viewport(), callback));
}

void ligma_set_list_text_alignment(void *view_pointer, int center)
{
    auto *view = static_cast<QAbstractItemView *>(view_pointer);
    if (view == nullptr)
        return;
    auto *current = view->itemDelegate();
    if (center != 0) {
        if (dynamic_cast<CenteredGridDelegate *>(current) == nullptr)
            view->setItemDelegate(new CenteredGridDelegate(view));
    } else if (dynamic_cast<CenteredGridDelegate *>(current) != nullptr) {
        view->setItemDelegate(new QStyledItemDelegate(view));
    }
}

void ligma_set_grid_item_size(void *view_pointer, int width, int height)
{
    auto *view = static_cast<QAbstractItemView *>(view_pointer);
    if (view == nullptr)
        return;
    auto *delegate = dynamic_cast<CenteredGridDelegate *>(view->itemDelegate());
    if (delegate == nullptr)
        return;
    delegate->setCellSize(QSize(std::max(width, 1), std::max(height, 1)));
    view->doItemsLayout();
    view->viewport()->update();
}

void ligma_set_row_gradient_colors(int start_r, int start_g, int start_b, int end_r,
    int end_g, int end_b)
{
    row_gradient_start = QColor(start_r, start_g, start_b);
    row_gradient_end = QColor(end_r, end_g, end_b);
}

void ligma_attach_row_gradient(void *view_pointer)
{
    auto *view = static_cast<QAbstractItemView *>(view_pointer);
    if (view == nullptr)
        return;

    auto *delegate = dynamic_cast<GradientRowDelegate *>(view->itemDelegate());
    if (delegate == nullptr) {
        delegate = new GradientRowDelegate(view);
        view->setItemDelegate(delegate);
    }

    // The delegate paints the full-row gradient itself. Keep the style from
    // drawing an opaque selection panel on top of it.
    QPalette palette = QApplication::palette();
    palette.setColor(QPalette::Highlight, Qt::transparent);
    palette.setColor(QPalette::HighlightedText, QColor(Qt::white));
    view->setPalette(palette);
    if (QWidget *viewport = view->viewport()) {
        viewport->setPalette(palette);
        viewport->update();
    }
    delegate->refreshHover();
}

void ligma_smooth_scroll_attach(void *view)
{
    auto *item_view = static_cast<QAbstractItemView *>(view);
    if (item_view == nullptr)
        return;
    QWidget *viewport = item_view->viewport();
    if (viewport == nullptr)
        return;
    viewport->installEventFilter(
        new SmoothScrollFilter(viewport, item_view->verticalScrollBar(), item_view));
}

void *ligma_dock_new(const char *title, void *parent_pointer, int horizontal,
    int duration_ms, int minimum)
{
    auto *parent = static_cast<QWidget *>(parent_pointer);
    return new LigmaDockWidget(QString::fromUtf8(title), parent, horizontal != 0,
        duration_ms, minimum);
}

void ligma_dock_slide_show(void *dock_pointer, int horizontal, int duration_ms, int minimum)
{
    auto *dock = static_cast<QDockWidget *>(dock_pointer);
    if (dock == nullptr || dock->isVisible())
        return;

    stopDockAnimation(dock);
    int target = 0;
    if (horizontal) {
        target = std::max(dock->sizeHint().width(), std::max(minimum, 0));
        if (target <= 0)
            target = minimum > 0 ? minimum : 360;
        dock->setMinimumWidth(0);
        dock->setMaximumWidth(0);
    } else {
        target = std::max(dock->sizeHint().height(), std::max(minimum, 0));
        if (target <= 0)
            target = minimum > 0 ? minimum : 220;
        dock->setMinimumHeight(0);
        dock->setMaximumHeight(0);
    }

    dock->show();
    startDockAnimation(dock, horizontal != 0, 0, target, duration_ms, minimum, false);
}

void ligma_dock_slide_hide(void *dock_pointer, int horizontal, int duration_ms, int minimum)
{
    auto *dock = static_cast<QDockWidget *>(dock_pointer);
    if (dock == nullptr || !dock->isVisible())
        return;

    stopDockAnimation(dock);
    const int start = horizontal ? dock->width() : dock->height();
    if (horizontal) {
        dock->setMinimumWidth(0);
        dock->setMaximumWidth(std::max(start, 0));
    } else {
        dock->setMinimumHeight(0);
        dock->setMaximumHeight(std::max(start, 0));
    }
    startDockAnimation(dock, horizontal != 0, start, 0, duration_ms, minimum, true);
}

} // extern "C"
