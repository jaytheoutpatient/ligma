// MPRIS 2 service for the built-in player.
//
// QtDBus's QDBusVirtualObject lets us expose the root and Player interfaces
// without generated adaptor code. The Zig side owns playback state and command
// handling; this file only translates D-Bus messages, properties, and signals.

#include <QDBusConnection>
#include <QDBusError>
#include <QDBusMessage>
#include <QDBusObjectPath>
#include <QDBusVariant>
#include <QDBusVirtualObject>
#include <QStringList>
#include <QVariantMap>

#include <algorithm>
#include <cmath>
#include <cstddef>

extern "C" {

typedef struct {
    void (*play)();
    void (*pause)();
    void (*play_pause)();
    void (*stop)();
    void (*next)();
    void (*previous)();
    void (*seek_relative)(long long microseconds);
    void (*set_position)(long long microseconds);
    void (*set_volume)(double volume);
    void (*set_loop)(int mode);
    void (*set_shuffle)(int enabled);
    void (*raise)();
    void (*quit)();
    int (*state)();
    long long (*position_us)();
    long long (*duration_us)();
    double (*volume)();
    int (*loop)();
    int (*shuffle)();
    void (*metadata)(char *title, size_t title_length, char *artist,
        size_t artist_length, char *album, size_t album_length);
    void (*track_id)(char *out, size_t out_length);
} MprisCallbacks;

int ligma_mpris_start(const MprisCallbacks *callbacks);
void ligma_mpris_stop();
void ligma_mpris_notify();
void ligma_mpris_seeked();
}

namespace {

constexpr const char *service_name = "org.mpris.MediaPlayer2.ligma";
constexpr const char *object_path = "/org/mpris/MediaPlayer2";
constexpr const char *root_interface = "org.mpris.MediaPlayer2";
constexpr const char *player_interface = "org.mpris.MediaPlayer2.Player";
constexpr const char *properties_interface = "org.freedesktop.DBus.Properties";

const char *playbackStatus(const MprisCallbacks *callbacks)
{
    switch (callbacks->state()) {
    case 1:
        return "Playing";
    case 2:
        return "Paused";
    default:
        return "Stopped";
    }
}

const char *loopStatus(const MprisCallbacks *callbacks)
{
    switch (callbacks->loop()) {
    case 1:
        return "Track";
    case 2:
        return "Playlist";
    default:
        return "None";
    }
}

QVariantMap metadata(const MprisCallbacks *callbacks)
{
    QVariantMap map;
    char title[512] = {};
    char artist[512] = {};
    char album[512] = {};
    callbacks->metadata(title, sizeof(title), artist, sizeof(artist), album, sizeof(album));

    const QString title_value = QString::fromUtf8(title).trimmed();
    const QString artist_value = QString::fromUtf8(artist).trimmed();
    const QString album_value = QString::fromUtf8(album).trimmed();
    const qint64 length = callbacks->duration_us();

    if (title_value.isEmpty() && length <= 0)
        return map;

    char track_id[128] = {};
    callbacks->track_id(track_id, sizeof(track_id));
    const QString track_path = QString::fromUtf8(track_id).trimmed();
    map.insert(QStringLiteral("mpris:trackid"),
        QVariant::fromValue(QDBusObjectPath(
            track_path.isEmpty() ? QStringLiteral("/org/ligma/track/0") : track_path)));
    if (!title_value.isEmpty())
        map.insert(QStringLiteral("xesam:title"), title_value);
    if (!artist_value.isEmpty()) {
        QStringList artists;
        artists.append(artist_value);
        map.insert(QStringLiteral("xesam:artist"), artists);
    }
    if (!album_value.isEmpty())
        map.insert(QStringLiteral("xesam:album"), album_value);
    if (length > 0)
        map.insert(QStringLiteral("mpris:length"), length);
    return map;
}

QVariantMap rootProperties()
{
    QVariantMap map;
    map.insert(QStringLiteral("Identity"), QStringLiteral("Ligma"));
    map.insert(QStringLiteral("DesktopEntry"), QStringLiteral("org.ligma.FileManager"));
    map.insert(QStringLiteral("CanQuit"), true);
    map.insert(QStringLiteral("CanRaise"), true);
    map.insert(QStringLiteral("HasTrackList"), false);
    map.insert(QStringLiteral("SupportedUriSchemes"), QStringList());
    map.insert(QStringLiteral("SupportedMimeTypes"), QStringList());
    return map;
}

QVariantMap playerProperties(const MprisCallbacks *callbacks)
{
    QVariantMap map;
    map.insert(QStringLiteral("PlaybackStatus"), QString::fromLatin1(playbackStatus(callbacks)));
    map.insert(QStringLiteral("LoopStatus"), QString::fromLatin1(loopStatus(callbacks)));
    map.insert(QStringLiteral("Rate"), 1.0);
    map.insert(QStringLiteral("Shuffle"), callbacks->shuffle() != 0);
    map.insert(QStringLiteral("Metadata"), metadata(callbacks));
    map.insert(QStringLiteral("Volume"), std::clamp(callbacks->volume(), 0.0, 1.0));
    map.insert(QStringLiteral("Position"), static_cast<qlonglong>(callbacks->position_us()));
    map.insert(QStringLiteral("MinimumRate"), 1.0);
    map.insert(QStringLiteral("MaximumRate"), 1.0);
    map.insert(QStringLiteral("CanGoNext"), true);
    map.insert(QStringLiteral("CanGoPrevious"), true);
    map.insert(QStringLiteral("CanPlay"), true);
    map.insert(QStringLiteral("CanPause"), true);
    map.insert(QStringLiteral("CanSeek"), true);
    map.insert(QStringLiteral("CanControl"), true);
    return map;
}

QString introspectionXml()
{
    return QStringLiteral(R"XML(
<node>
  <interface name="org.mpris.MediaPlayer2">
    <method name="Raise"/>
    <method name="Quit"/>
    <property name="CanQuit" type="b" access="read"/>
    <property name="CanRaise" type="b" access="read"/>
    <property name="HasTrackList" type="b" access="read"/>
    <property name="Identity" type="s" access="read"/>
    <property name="DesktopEntry" type="s" access="read"/>
    <property name="SupportedUriSchemes" type="as" access="read"/>
    <property name="SupportedMimeTypes" type="as" access="read"/>
  </interface>
  <interface name="org.mpris.MediaPlayer2.Player">
    <method name="Next"/>
    <method name="Previous"/>
    <method name="Pause"/>
    <method name="PlayPause"/>
    <method name="Stop"/>
    <method name="Play"/>
    <method name="Seek">
      <arg name="Offset" type="x" direction="in"/>
    </method>
    <method name="SetPosition">
      <arg name="TrackId" type="o" direction="in"/>
      <arg name="Position" type="x" direction="in"/>
    </method>
    <method name="OpenUri">
      <arg name="Uri" type="s" direction="in"/>
    </method>
    <property name="PlaybackStatus" type="s" access="read"/>
    <property name="LoopStatus" type="s" access="readwrite"/>
    <property name="Rate" type="d" access="readwrite"/>
    <property name="Shuffle" type="b" access="readwrite"/>
    <property name="Metadata" type="a{sv}" access="read"/>
    <property name="Volume" type="d" access="readwrite"/>
    <property name="Position" type="x" access="read"/>
    <property name="MinimumRate" type="d" access="read"/>
    <property name="MaximumRate" type="d" access="read"/>
    <property name="CanGoNext" type="b" access="read"/>
    <property name="CanGoPrevious" type="b" access="read"/>
    <property name="CanPlay" type="b" access="read"/>
    <property name="CanPause" type="b" access="read"/>
    <property name="CanSeek" type="b" access="read"/>
    <property name="CanControl" type="b" access="read"/>
    <signal name="Seeked">
      <arg name="Position" type="x"/>
    </signal>
  </interface>
</node>
)XML");
}

class MprisService final : public QDBusVirtualObject {
  public:
    explicit MprisService(const MprisCallbacks *callbacks)
        : callbacks_(callbacks)
    {
    }

    QString introspect(const QString &path) const override
    {
        Q_UNUSED(path);
        return introspectionXml();
    }

    bool handleMessage(const QDBusMessage &message, const QDBusConnection &connection) override
    {
        const QString interface = message.interface();
        const QString member = message.member();
        const QVariantList arguments = message.arguments();

        if (interface == properties_interface)
            return handleProperties(message, connection, member, arguments);

        if (interface == root_interface) {
            if (member == QStringLiteral("Raise")) {
                callbacks_->raise();
                connection.send(message.createReply());
                return true;
            }
            if (member == QStringLiteral("Quit")) {
                callbacks_->quit();
                connection.send(message.createReply());
                return true;
            }
            return error(message, connection, QDBusError::UnknownMethod);
        }

        if (interface == player_interface) {
            if (member == QStringLiteral("Play")) {
                callbacks_->play();
            } else if (member == QStringLiteral("Pause")) {
                callbacks_->pause();
            } else if (member == QStringLiteral("PlayPause")) {
                callbacks_->play_pause();
            } else if (member == QStringLiteral("Stop")) {
                callbacks_->stop();
            } else if (member == QStringLiteral("Next")) {
                callbacks_->next();
            } else if (member == QStringLiteral("Previous")) {
                callbacks_->previous();
            } else if (member == QStringLiteral("Seek") && arguments.size() == 1) {
                callbacks_->seek_relative(arguments.at(0).toLongLong());
            } else if (member == QStringLiteral("SetPosition") && arguments.size() == 2) {
                char track_id[128] = {};
                callbacks_->track_id(track_id, sizeof(track_id));
                const QString requested = arguments.at(0).value<QDBusObjectPath>().path();
                if (requested == QString::fromUtf8(track_id))
                    callbacks_->set_position(arguments.at(1).toLongLong());
            } else if (member == QStringLiteral("OpenUri")) {
                return error(message, connection, QDBusError::NotSupported,
                    QStringLiteral("Ligma does not accept remote URIs over MPRIS"));
            } else {
                return error(message, connection, QDBusError::UnknownMethod);
            }
            connection.send(message.createReply());
            return true;
        }

        if (interface == QStringLiteral("org.freedesktop.DBus.Introspectable") &&
            member == QStringLiteral("Introspect")) {
            connection.send(message.createReply(introspectionXml()));
            return true;
        }

        return false;
    }

  private:
    bool handleProperties(const QDBusMessage &message, const QDBusConnection &connection,
        const QString &member, const QVariantList &arguments)
    {
        if (member == QStringLiteral("Get") && arguments.size() == 2) {
            const QString interface = arguments.at(0).toString();
            const QString property = arguments.at(1).toString();
            const QVariant value = propertyValue(interface, property);
            if (!value.isValid())
                return error(message, connection, QDBusError::UnknownProperty,
                    QStringLiteral("Unknown MPRIS property: %1").arg(property));
            connection.send(message.createReply(value));
            return true;
        }

        if (member == QStringLiteral("GetAll") && arguments.size() == 1) {
            const QString interface = arguments.at(0).toString();
            QVariantMap values;
            if (interface == root_interface)
                values = rootProperties();
            else if (interface == player_interface)
                values = playerProperties(callbacks_);
            else
                return error(message, connection, QDBusError::UnknownInterface);
            connection.send(message.createReply(values));
            return true;
        }

        if (member == QStringLiteral("Set") && arguments.size() == 3) {
            const QString interface = arguments.at(0).toString();
            const QString property = arguments.at(1).toString();
            const QVariant value = arguments.at(2).value<QDBusVariant>().variant();
            if (interface != player_interface)
                return error(message, connection, QDBusError::PropertyReadOnly);
            if (!setPlayerProperty(property, value))
                return error(message, connection, QDBusError::PropertyReadOnly,
                    QStringLiteral("Property is not writable: %1").arg(property));
            connection.send(message.createReply());
            return true;
        }

        return error(message, connection, QDBusError::UnknownMethod);
    }

    QVariant propertyValue(const QString &interface, const QString &property) const
    {
        const QVariantMap values = interface == root_interface ? rootProperties()
            : interface == player_interface ? playerProperties(callbacks_)
            : QVariantMap();
        return values.value(property);
    }

    bool setPlayerProperty(const QString &property, const QVariant &value)
    {
        if (property == QStringLiteral("LoopStatus")) {
            const QString mode = value.toString();
            if (mode == QStringLiteral("None"))
                callbacks_->set_loop(0);
            else if (mode == QStringLiteral("Track"))
                callbacks_->set_loop(1);
            else if (mode == QStringLiteral("Playlist"))
                callbacks_->set_loop(2);
            else
                return false;
            notifyChanged();
            return true;
        }
        if (property == QStringLiteral("Shuffle")) {
            callbacks_->set_shuffle(value.toBool() ? 1 : 0);
            notifyChanged();
            return true;
        }
        if (property == QStringLiteral("Volume")) {
            callbacks_->set_volume(value.toDouble());
            notifyChanged();
            return true;
        }
        if (property == QStringLiteral("Rate")) {
            return std::abs(value.toDouble() - 1.0) < 0.0001;
        }
        return false;
    }

    static bool error(const QDBusMessage &message, const QDBusConnection &connection,
        QDBusError::ErrorType type, const QString &text = QString())
    {
        const QString detail = text.isEmpty() ? QDBusError::errorString(type) : text;
        connection.send(message.createErrorReply(type, detail));
        return true;
    }

  public:
    void notifyChanged() const
    {
        QDBusMessage signal = QDBusMessage::createSignal(QString::fromLatin1(object_path),
            QString::fromLatin1(properties_interface),
            QStringLiteral("PropertiesChanged"));
        QVariantMap changed = playerProperties(callbacks_);
        changed.remove(QStringLiteral("Position"));
        signal << QString::fromLatin1(player_interface) << changed << QStringList();
        QDBusConnection::sessionBus().send(signal);
    }

    void notifySeeked() const
    {
        QDBusMessage signal = QDBusMessage::createSignal(QString::fromLatin1(object_path),
            QString::fromLatin1(player_interface),
            QStringLiteral("Seeked"));
        signal << static_cast<qlonglong>(callbacks_->position_us());
        QDBusConnection::sessionBus().send(signal);
    }

  private:
    const MprisCallbacks *callbacks_;
};

MprisService *service = nullptr;

} // namespace

extern "C" {

int ligma_mpris_start(const MprisCallbacks *callbacks)
{
    if (service != nullptr)
        return 1;
    if (callbacks == nullptr)
        return 0;

    QDBusConnection bus = QDBusConnection::sessionBus();
    if (!bus.isConnected())
        return 0;

    service = new MprisService(callbacks);
    if (!bus.registerService(QString::fromLatin1(service_name))) {
        delete service;
        service = nullptr;
        return 0;
    }
    if (!bus.registerVirtualObject(QString::fromLatin1(object_path), service)) {
        bus.unregisterService(QString::fromLatin1(service_name));
        delete service;
        service = nullptr;
        return 0;
    }
    return 1;
}

void ligma_mpris_stop()
{
    if (service == nullptr)
        return;
    QDBusConnection bus = QDBusConnection::sessionBus();
    bus.unregisterObject(QString::fromLatin1(object_path));
    bus.unregisterService(QString::fromLatin1(service_name));
    delete service;
    service = nullptr;
}

void ligma_mpris_notify()
{
    if (service != nullptr)
        service->notifyChanged();
}

void ligma_mpris_seeked()
{
    if (service != nullptr)
        service->notifySeeked();
}

} // extern "C"
