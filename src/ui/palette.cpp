// Palette loading for Matugen/qt6ct and built-in light/dark appearance.
//
// Reading qt6ct's active/inactive/disabled color groups directly lets Ligma
// match a Matugen scheme without requiring the qt6ct platform theme plugin.

#include <QApplication>
#include <QColor>
#include <QFile>
#include <QPalette>
#include <QStyle>
#include <QString>
#include <QStringList>

namespace {

QColor parseColor(const QString &value)
{
    QString text = value.trimmed();
    if (!text.startsWith('#'))
        text.prepend('#');
    return QColor(text);
}

bool applyGroup(QPalette &palette, QPalette::ColorGroup group, const QStringList &values)
{
    if (values.size() < 21)
        return false;

    const QPalette::ColorRole roles[] = {
        QPalette::WindowText,
        QPalette::Button,
        QPalette::Light,
        QPalette::Midlight,
        QPalette::Dark,
        QPalette::Mid,
        QPalette::Text,
        QPalette::BrightText,
        QPalette::ButtonText,
        QPalette::Base,
        QPalette::Window,
        QPalette::Shadow,
        QPalette::Highlight,
        QPalette::HighlightedText,
        QPalette::Link,
        QPalette::LinkVisited,
        QPalette::AlternateBase,
        QPalette::NoRole,
        QPalette::ToolTipBase,
        QPalette::ToolTipText,
        QPalette::PlaceholderText,
    };

    for (int index = 0; index < 21; ++index) {
        if (roles[index] == QPalette::NoRole)
            continue;
        const QColor color = parseColor(values.at(index));
        if (color.isValid())
            palette.setColor(group, roles[index], color);
    }
    return true;
}

QStringList colorValues(const QString &line)
{
    QStringList values;
    const int equals = line.indexOf('=');
    if (equals < 0)
        return values;
    const QString raw = line.mid(equals + 1);
    for (const QString &part : raw.split(','))
        values.append(part.trimmed());
    return values;
}

void setRole(QPalette &palette, QPalette::ColorRole role, const QColor &active,
    const QColor &inactive, const QColor &disabled)
{
    palette.setColor(QPalette::Active, role, active);
    palette.setColor(QPalette::Inactive, role, inactive);
    palette.setColor(QPalette::Disabled, role, disabled);
}

void setCommon(QPalette &palette, const QColor &window, const QColor &base,
    const QColor &alternate, const QColor &text, const QColor &button,
    const QColor &buttonText, const QColor &highlight,
    const QColor &highlightedText, const QColor &tooltipBase,
    const QColor &tooltipText, const QColor &placeholder, const QColor &link)
{
    const QColor light = window.lighter(135);
    const QColor midlight = window.lighter(112);
    const QColor dark = window.darker(125);
    const QColor mid = window.darker(108);
    const QColor disabledHighlight = highlight.darker(140);
    const QColor brightText(QStringLiteral("#ffffff"));

    // Set every group explicitly. QPalette's default inactive/disabled colors
    // are black, which makes alternating rows unreadable after a runtime
    // light/dark switch.
    setRole(palette, QPalette::Window, window, window, window);
    setRole(palette, QPalette::WindowText, text, text, placeholder);
    setRole(palette, QPalette::Base, base, base, base);
    setRole(palette, QPalette::AlternateBase, alternate, alternate, alternate);
    setRole(palette, QPalette::Text, text, text, placeholder);
    setRole(palette, QPalette::Button, button, button, button);
    setRole(palette, QPalette::ButtonText, buttonText, buttonText, placeholder);
    setRole(palette, QPalette::BrightText, brightText, brightText, placeholder);
    setRole(palette, QPalette::Highlight, highlight, highlight, disabledHighlight);
    setRole(palette, QPalette::HighlightedText, highlightedText, highlightedText,
        placeholder);
    setRole(palette, QPalette::ToolTipBase, tooltipBase, tooltipBase, tooltipBase);
    setRole(palette, QPalette::ToolTipText, tooltipText, tooltipText, placeholder);
    setRole(palette, QPalette::PlaceholderText, placeholder, placeholder, placeholder);
    setRole(palette, QPalette::Link, link, link, placeholder);
    setRole(palette, QPalette::LinkVisited, link.darker(115), link.darker(115),
        placeholder);
    setRole(palette, QPalette::Light, light, light, light);
    setRole(palette, QPalette::Midlight, midlight, midlight, midlight);
    setRole(palette, QPalette::Dark, dark, dark, dark);
    setRole(palette, QPalette::Mid, mid, mid, mid);
    setRole(palette, QPalette::Shadow, QColor(Qt::black), QColor(Qt::black),
        QColor(Qt::black));
}

} // namespace

extern "C" {

int ligma_apply_qt6ct_palette(const char *path)
{
    if (path == nullptr || qApp == nullptr)
        return 0;

    QFile file(QString::fromUtf8(path));
    if (!file.open(QIODevice::ReadOnly | QIODevice::Text))
        return 0;

    QStringList active;
    QStringList inactive;
    QStringList disabled;
    while (!file.atEnd()) {
        const QString line = QString::fromUtf8(file.readLine()).trimmed();
        if (line.startsWith("active_colors="))
            active = colorValues(line);
        else if (line.startsWith("inactive_colors="))
            inactive = colorValues(line);
        else if (line.startsWith("disabled_colors="))
            disabled = colorValues(line);
    }
    if (active.size() < 21)
        return 0;

    QPalette palette;
    if (!applyGroup(palette, QPalette::Active, active))
        return 0;
    applyGroup(palette, QPalette::Inactive, inactive.isEmpty() ? active : inactive);
    applyGroup(palette, QPalette::Disabled, disabled.isEmpty() ? active : disabled);
    qApp->setPalette(palette);
    return 1;
}

void ligma_apply_builtin_palette(int dark)
{
    if (qApp == nullptr)
        return;

    QPalette palette;
    if (dark) {
        setCommon(palette,
            QColor("#111418"), QColor("#171b21"), QColor("#1d232b"),
            QColor("#e6edf3"), QColor("#20262e"), QColor("#e6edf3"),
            QColor("#6366f1"), QColor("#ffffff"), QColor("#1b2027"),
            QColor("#e6edf3"), QColor("#8b95a5"), QColor("#7aa2ff"));
    } else {
        setCommon(palette,
            QColor("#f5f6f8"), QColor("#ffffff"), QColor("#eef1f5"),
            QColor("#171a1f"), QColor("#eef1f5"), QColor("#171a1f"),
            QColor("#3b82f6"), QColor("#ffffff"), QColor("#ffffff"),
            QColor("#171a1f"), QColor("#7a8493"), QColor("#2563eb"));
    }
    qApp->setPalette(palette);
}

void ligma_apply_system_palette()
{
    if (qApp == nullptr)
        return;
    qApp->setPalette(qApp->style()->standardPalette());
}

} // extern "C"
