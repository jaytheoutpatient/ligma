// C ABI shim for the GStreamer music engine.
//
// QtMultimedia does not expose direct ALSA output, equalizer filters, or a way
// to disable software volume. This shim owns a GStreamer playbin, applies the
// output/filter configuration, and exposes a small polling API to the Zig
// player. Keeping the GStreamer objects in C++ avoids teaching libqt6zig about
// another large C API.

#include <gst/gst.h>
#include <gst/gsttaglist.h>

#include <algorithm>
#include <atomic>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <string>

namespace {

// GstPlayFlags is not exposed by the installed development headers. These
// values are the stable public flags from gst-plugins-base.
constexpr guint PLAY_FLAG_AUDIO = 1u << 1;
constexpr guint PLAY_FLAG_SOFT_VOLUME = 1u << 4;
constexpr guint PLAY_FLAG_NATIVE_AUDIO = 1u << 5;
constexpr guint PLAY_FLAG_FORCE_FILTERS = 1u << 11;

struct MusicEngine {
    GstElement *playbin = nullptr;
    GstBus *bus = nullptr;
    GstElement *filter_bin = nullptr;
    GstElement *equalizer = nullptr;
    GstElement *rgvolume = nullptr;

    std::mutex mutex;
    std::string title;
    std::string artist;
    std::string album;
    std::string error;
    guint tag_serial = 0;
    bool eos_pending = false;
    bool error_pending = false;

    std::atomic<int> state{0}; // 0 = stopped, 1 = playing, 2 = paused

    int output_mode = 0; // 0 = PipeWire/auto, 1 = direct ALSA
    std::string alsa_device = "default";
    bool bitperfect = false;
    bool eq_enabled = false;
    bool rg_enabled = false;
    double eq_gains[10] = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0};
    double volume = 1.0;
};

std::string tag_string(const GstTagList *tags, const char *tag)
{
    gchar *value = nullptr;
    if (!gst_tag_list_get_string(tags, tag, &value) || value == nullptr)
        return {};
    std::string result(value);
    g_free(value);
    return result;
}

void apply_flags(MusicEngine *engine)
{
    guint flags = PLAY_FLAG_AUDIO;
    if (engine->bitperfect) {
        flags |= PLAY_FLAG_NATIVE_AUDIO;
    } else {
        flags |= PLAY_FLAG_SOFT_VOLUME;
        if (engine->filter_bin)
            flags |= PLAY_FLAG_FORCE_FILTERS;
    }
    g_object_set(engine->playbin, "flags", flags, nullptr);
    g_object_set(engine->playbin, "volume", engine->bitperfect ? 1.0 : engine->volume, nullptr);
}

void clear_filter(MusicEngine *engine)
{
    // playbin takes ownership of the floating reference returned by
    // gst_bin_new when it accepts the audio-filter. Clearing the property
    // releases that reference; do not unref the cached pointer again.
    g_object_set(engine->playbin, "audio-filter", nullptr, nullptr);
    engine->filter_bin = nullptr;
    engine->equalizer = nullptr;
    engine->rgvolume = nullptr;
}

void set_equalizer_bands(MusicEngine *engine)
{
    if (engine->equalizer == nullptr)
        return;
    for (int i = 0; i < 10; ++i) {
        gchar name[16];
        g_snprintf(name, sizeof(name), "band%d", i);
        g_object_set(engine->equalizer, name, engine->eq_gains[i], nullptr);
    }
}

bool build_filter(MusicEngine *engine)
{
    clear_filter(engine);
    if (engine->bitperfect || (!engine->eq_enabled && !engine->rg_enabled))
        return true;

    GstElement *bin = gst_bin_new("ligma-audio-filter");
    GstElement *in = gst_element_factory_make("audioconvert", nullptr);
    GstElement *out = gst_element_factory_make("audioconvert", nullptr);
    GstElement *rg = engine->rg_enabled ? gst_element_factory_make("rgvolume", nullptr) : nullptr;
    GstElement *eq = engine->eq_enabled ? gst_element_factory_make("equalizer-10bands", nullptr) : nullptr;

    if (bin == nullptr || in == nullptr || out == nullptr
        || (engine->rg_enabled && rg == nullptr)
        || (engine->eq_enabled && eq == nullptr)) {
        if (bin) gst_object_unref(bin);
        if (in) gst_object_unref(in);
        if (out) gst_object_unref(out);
        if (rg) gst_object_unref(rg);
        if (eq) gst_object_unref(eq);
        return false;
    }

    gst_bin_add_many(GST_BIN(bin), in, out, nullptr);
    if (rg) gst_bin_add(GST_BIN(bin), rg);
    if (eq) gst_bin_add(GST_BIN(bin), eq);

    GstElement *previous = in;
    if (rg) {
        if (!gst_element_link(previous, rg)) {
            gst_object_unref(bin);
            return false;
        }
        previous = rg;
    }
    if (eq) {
        if (!gst_element_link(previous, eq)) {
            gst_object_unref(bin);
            return false;
        }
        previous = eq;
    }
    if (!gst_element_link(previous, out)) {
        gst_object_unref(bin);
        return false;
    }

    GstPad *sink_pad = gst_element_get_static_pad(in, "sink");
    GstPad *src_pad = gst_element_get_static_pad(out, "src");
    if (sink_pad == nullptr || src_pad == nullptr) {
        if (sink_pad) gst_object_unref(sink_pad);
        if (src_pad) gst_object_unref(src_pad);
        gst_object_unref(bin);
        return false;
    }
    gst_element_add_pad(bin, gst_ghost_pad_new("sink", sink_pad));
    gst_element_add_pad(bin, gst_ghost_pad_new("src", src_pad));
    gst_object_unref(sink_pad);
    gst_object_unref(src_pad);

    engine->filter_bin = bin;
    engine->equalizer = eq;
    engine->rgvolume = rg;
    set_equalizer_bands(engine);
    g_object_set(engine->playbin, "audio-filter", bin, nullptr);
    return true;
}

void apply_output(MusicEngine *engine)
{
    GstElement *sink = nullptr;
    if (engine->output_mode == 1) {
        sink = gst_element_factory_make("alsasink", nullptr);
        if (sink != nullptr)
            g_object_set(sink, "device", engine->alsa_device.c_str(), nullptr);
    }
    if (sink == nullptr)
        sink = gst_element_factory_make("pipewiresink", nullptr);
    if (sink == nullptr)
        sink = gst_element_factory_make("autoaudiosink", nullptr);

    if (sink != nullptr) {
        // playbin takes ownership of the floating reference returned by the
        // factory. Do not unref it here, or the pipeline keeps a dangling
        // pointer and fails when it is disposed.
        g_object_set(engine->playbin, "audio-sink", sink, nullptr);
    } else {
        g_object_set(engine->playbin, "audio-sink", nullptr, nullptr);
    }
}

GstBusSyncReply bus_sync(GstBus *, GstMessage *message, gpointer user_data)
{
    auto *engine = static_cast<MusicEngine *>(user_data);

    switch (GST_MESSAGE_TYPE(message)) {
    case GST_MESSAGE_TAG: {
        GstTagList *tags = nullptr;
        gst_message_parse_tag(message, &tags);
        if (tags != nullptr) {
            std::lock_guard<std::mutex> lock(engine->mutex);
            bool changed = false;

            std::string next_title = tag_string(tags, GST_TAG_TITLE);
            if (!next_title.empty() && next_title != engine->title) {
                engine->title = next_title;
                changed = true;
            }

            std::string next_artist = tag_string(tags, GST_TAG_ARTIST);
            if (next_artist.empty())
                next_artist = tag_string(tags, GST_TAG_ALBUM_ARTIST);
            if (!next_artist.empty() && next_artist != engine->artist) {
                engine->artist = next_artist;
                changed = true;
            }

            std::string next_album = tag_string(tags, GST_TAG_ALBUM);
            if (!next_album.empty() && next_album != engine->album) {
                engine->album = next_album;
                changed = true;
            }

            if (changed)
                engine->tag_serial++;
            gst_tag_list_unref(tags);
        }
        break;
    }
    case GST_MESSAGE_EOS: {
        std::lock_guard<std::mutex> lock(engine->mutex);
        engine->eos_pending = true;
        engine->state.store(0);
        break;
    }
    case GST_MESSAGE_ERROR: {
        GError *error = nullptr;
        gchar *debug = nullptr;
        gst_message_parse_error(message, &error, &debug);
        {
            std::lock_guard<std::mutex> lock(engine->mutex);
            engine->error = error ? error->message : "GStreamer playback error";
            engine->error_pending = true;
            engine->state.store(0);
        }
        if (debug)
            g_free(debug);
        if (error)
            g_error_free(error);
        break;
    }
    default:
        break;
    }

    gst_message_unref(message);
    return GST_BUS_DROP;
}

void copy_string(char *destination, size_t length, const std::string &source)
{
    if (destination == nullptr || length == 0)
        return;
    const size_t count = std::min(length - 1, source.size());
    std::memcpy(destination, source.data(), count);
    destination[count] = '\0';
}

} // namespace

extern "C" {

void *ligma_music_new(int output_mode, const char *alsa_device, int eq_enabled, int rg_enabled)
{
    gst_init(nullptr, nullptr);

    auto *engine = new MusicEngine();
    engine->output_mode = output_mode;
    engine->bitperfect = output_mode == 1;
    if (alsa_device != nullptr && alsa_device[0] != '\0')
        engine->alsa_device = alsa_device;
    engine->eq_enabled = eq_enabled != 0;
    engine->rg_enabled = rg_enabled != 0;

    engine->playbin = gst_element_factory_make("playbin", "ligma-playbin");
    if (engine->playbin == nullptr) {
        delete engine;
        return nullptr;
    }

    engine->bus = gst_element_get_bus(engine->playbin);
    if (engine->bus == nullptr) {
        gst_object_unref(engine->playbin);
        delete engine;
        return nullptr;
    }
    gst_bus_set_sync_handler(engine->bus, bus_sync, engine, nullptr);

    apply_output(engine);
    build_filter(engine);
    apply_flags(engine);
    return engine;
}

void ligma_music_free(void *handle)
{
    auto *engine = static_cast<MusicEngine *>(handle);
    if (engine == nullptr)
        return;

    gst_bus_set_sync_handler(engine->bus, nullptr, nullptr, nullptr);
    gst_element_set_state(engine->playbin, GST_STATE_NULL);
    clear_filter(engine);
    gst_object_unref(engine->bus);
    gst_object_unref(engine->playbin);
    delete engine;
}

int ligma_music_load(void *handle, const char *path)
{
    auto *engine = static_cast<MusicEngine *>(handle);
    if (engine == nullptr || path == nullptr)
        return 0;

    GError *error = nullptr;
    gchar *uri = gst_filename_to_uri(path, &error);
    if (uri == nullptr) {
        std::lock_guard<std::mutex> lock(engine->mutex);
        engine->error = error ? error->message : "Could not convert path to URI";
        engine->error_pending = true;
        if (error)
            g_error_free(error);
        return 0;
    }

    gst_element_set_state(engine->playbin, GST_STATE_READY);
    {
        std::lock_guard<std::mutex> lock(engine->mutex);
        engine->title.clear();
        engine->artist.clear();
        engine->album.clear();
        engine->error.clear();
        engine->eos_pending = false;
        engine->error_pending = false;
        engine->tag_serial++;
        engine->state.store(0);
    }

    g_object_set(engine->playbin, "uri", uri, nullptr);
    g_free(uri);
    gst_element_set_state(engine->playbin, GST_STATE_PAUSED);
    return 1;
}

void ligma_music_play(void *handle)
{
    auto *engine = static_cast<MusicEngine *>(handle);
    if (engine == nullptr)
        return;
    gst_element_set_state(engine->playbin, GST_STATE_PLAYING);
    engine->state.store(1);
}

void ligma_music_pause(void *handle)
{
    auto *engine = static_cast<MusicEngine *>(handle);
    if (engine == nullptr)
        return;
    gst_element_set_state(engine->playbin, GST_STATE_PAUSED);
    engine->state.store(2);
}

void ligma_music_stop(void *handle)
{
    auto *engine = static_cast<MusicEngine *>(handle);
    if (engine == nullptr)
        return;
    gst_element_set_state(engine->playbin, GST_STATE_READY);
    engine->state.store(0);
}

void ligma_music_set_volume(void *handle, double volume)
{
    auto *engine = static_cast<MusicEngine *>(handle);
    if (engine == nullptr)
        return;
    engine->volume = std::clamp(volume, 0.0, 1.0);
    if (!engine->bitperfect)
        g_object_set(engine->playbin, "volume", engine->volume, nullptr);
}

void ligma_music_set_position(void *handle, int64_t milliseconds)
{
    auto *engine = static_cast<MusicEngine *>(handle);
    if (engine == nullptr || milliseconds < 0)
        return;
    gst_element_seek_simple(
        engine->playbin,
        GST_FORMAT_TIME,
        static_cast<GstSeekFlags>(GST_SEEK_FLAG_FLUSH | GST_SEEK_FLAG_ACCURATE),
        milliseconds * GST_MSECOND);
}

int64_t ligma_music_position(void *handle)
{
    auto *engine = static_cast<MusicEngine *>(handle);
    if (engine == nullptr)
        return 0;
    gint64 position = 0;
    if (!gst_element_query_position(engine->playbin, GST_FORMAT_TIME, &position))
        return 0;
    return position / GST_MSECOND;
}

int64_t ligma_music_duration(void *handle)
{
    auto *engine = static_cast<MusicEngine *>(handle);
    if (engine == nullptr)
        return 0;
    gint64 duration = 0;
    if (!gst_element_query_duration(engine->playbin, GST_FORMAT_TIME, &duration))
        return 0;
    return duration / GST_MSECOND;
}

int ligma_music_state(void *handle)
{
    auto *engine = static_cast<MusicEngine *>(handle);
    return engine == nullptr ? 0 : engine->state.load();
}

int ligma_music_is_bitperfect(void *handle)
{
    auto *engine = static_cast<MusicEngine *>(handle);
    return engine != nullptr && engine->bitperfect;
}

int ligma_music_poll(void *handle)
{
    auto *engine = static_cast<MusicEngine *>(handle);
    if (engine == nullptr)
        return 0;

    std::lock_guard<std::mutex> lock(engine->mutex);
    int events = 0;
    if (engine->eos_pending) {
        engine->eos_pending = false;
        events |= 1;
    }
    if (engine->error_pending) {
        engine->error_pending = false;
        events |= 2;
    }
    return events;
}

unsigned int ligma_music_tag_serial(void *handle)
{
    auto *engine = static_cast<MusicEngine *>(handle);
    if (engine == nullptr)
        return 0;
    std::lock_guard<std::mutex> lock(engine->mutex);
    return engine->tag_serial;
}

int ligma_music_tags(
    void *handle,
    char *title,
    size_t title_length,
    char *artist,
    size_t artist_length,
    char *album,
    size_t album_length)
{
    auto *engine = static_cast<MusicEngine *>(handle);
    if (engine == nullptr)
        return 0;
    std::lock_guard<std::mutex> lock(engine->mutex);
    copy_string(title, title_length, engine->title);
    copy_string(artist, artist_length, engine->artist);
    copy_string(album, album_length, engine->album);
    return engine->title.empty() && engine->artist.empty() && engine->album.empty() ? 0 : 1;
}

int ligma_music_error(void *handle, char *buffer, size_t length)
{
    auto *engine = static_cast<MusicEngine *>(handle);
    if (engine == nullptr)
        return 0;
    std::lock_guard<std::mutex> lock(engine->mutex);
    copy_string(buffer, length, engine->error);
    return engine->error.empty() ? 0 : 1;
}

int ligma_music_set_eq(void *handle, int enabled, const double *gains, int count)
{
    auto *engine = static_cast<MusicEngine *>(handle);
    if (engine == nullptr)
        return 0;
    engine->eq_enabled = enabled != 0;
    for (int i = 0; i < 10; ++i) {
        if (gains != nullptr && i < count)
            engine->eq_gains[i] = gains[i];
        else
            engine->eq_gains[i] = 0;
    }
    if (!build_filter(engine))
        return 0;
    apply_flags(engine);
    return 1;
}

int ligma_music_set_replaygain(void *handle, int enabled)
{
    auto *engine = static_cast<MusicEngine *>(handle);
    if (engine == nullptr)
        return 0;
    engine->rg_enabled = enabled != 0;
    if (!build_filter(engine))
        return 0;
    apply_flags(engine);
    return 1;
}

int ligma_music_set_output(void *handle, int output_mode, const char *alsa_device)
{
    auto *engine = static_cast<MusicEngine *>(handle);
    if (engine == nullptr)
        return 0;
    engine->output_mode = output_mode;
    engine->bitperfect = output_mode == 1;
    if (alsa_device != nullptr && alsa_device[0] != '\0')
        engine->alsa_device = alsa_device;
    apply_output(engine);
    build_filter(engine);
    apply_flags(engine);
    return 1;
}

} // extern "C"
