// C ABI shim for QTermWidget.
//
// QTermWidget is a C++ class, so it cannot be called through Zig's C import.
// This small translation unit owns the widget and exposes only plain C
// functions. It is compiled with the system g++ (see build.zig) so the shim
// and Qt share the same C++ runtime.
//
// QTermWidget itself is LGPL-2.0-or-later / BSD-3-Clause; see the qtermwidget
// package for details.

#include <qtermwidget.h>

#include <QFont>
#include <QFontDatabase>
#include <QKeyEvent>
#include <QString>
#include <QWidget>

namespace {

/// F12 normally reaches the application shortcut before the terminal, but a
/// terminal emulator accepts most keys itself. Intercept F12 when the widget
/// has focus so the panel can still be toggled from inside the shell.
class LigmaTermWidget final : public QTermWidget {
public:
    using ToggleCallback = void (*)(void *);

    LigmaTermWidget(QWidget *parent, void *user, ToggleCallback toggle)
        : QTermWidget(0, parent), m_user(user), m_toggle(toggle)
    {
    }

protected:
    void keyPressEvent(QKeyEvent *event) override
    {
        if (event->key() == Qt::Key_F12 && event->modifiers() == Qt::NoModifier) {
            if (m_toggle)
                m_toggle(m_user);
            event->accept();
            return;
        }
        QTermWidget::keyPressEvent(event);
    }

private:
    void *m_user;
    ToggleCallback m_toggle;
};

QString fromUtf8(const char *text)
{
    return text ? QString::fromUtf8(text) : QString();
}

} // namespace

extern "C" {

void *ligma_terminal_new(void *parent, void *user, void (*toggle)(void *))
{
    auto *term = new LigmaTermWidget(static_cast<QWidget *>(parent), user, toggle);
    term->setScrollBarPosition(QTermWidgetInterface::ScrollBarRight);
    term->setTerminalSizeHint(false);
    term->setHistorySize(10000);
    term->setColorScheme(QStringLiteral("WhiteOnBlack"));
    term->setTerminalOpacity(1.0);

    QFont font = QFontDatabase::systemFont(QFontDatabase::FixedFont);
    font.setStyleHint(QFont::Monospace);
    font.setFixedPitch(true);
    if (font.pointSize() <= 0)
        font.setPointSize(10);
    term->setTerminalFont(font);

    return term;
}

/// Configure the shell and start it. The widget must already be visible so
/// the terminal has a real size when the shell reads its window size.
void ligma_terminal_start(void *handle, const char *shell, const char *working_directory)
{
    auto *term = static_cast<QTermWidget *>(handle);
    if (!term)
        return;
    if (shell && *shell)
        term->setShellProgram(fromUtf8(shell));
    if (working_directory && *working_directory)
        term->setWorkingDirectory(fromUtf8(working_directory));
    term->startShellProgram();
}

void ligma_terminal_set_focus(void *handle)
{
    if (auto *term = static_cast<QTermWidget *>(handle))
        term->setFocus(Qt::OtherFocusReason);
}

/// Ask the running shell to change directory. QTermWidget only forwards the
/// `cd` when the shell is in the foreground, so a job like an editor keeps
/// running undisturbed.
void ligma_terminal_change_dir(void *handle, const char *working_directory)
{
    auto *term = static_cast<QTermWidget *>(handle);
    if (!term || !working_directory || !*working_directory)
        return;
    term->changeDir(fromUtf8(working_directory));
}

/// Release the widget (and with it the PTY/shell) during application
/// shutdown, before Qt tears the rest of the window down.
void ligma_terminal_shutdown(void *handle)
{
    if (auto *term = static_cast<QWidget *>(handle))
        delete term;
}

} // extern "C"
