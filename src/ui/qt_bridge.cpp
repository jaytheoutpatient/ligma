// Small Qt bridge for values that libqt6zig does not expose directly.
//
// QVariant has no generated constructor taking a QIcon, but QAbstractItemModel
// expects one for DecorationRole. Keeping this in C++ avoids a second
// hand-written Zig representation of QVariant's internal storage.

#include <QIcon>
#include <QVariant>

extern "C" {

void *ligma_qvariant_from_icon(void *icon)
{
    if (icon == nullptr)
        return nullptr;
    return new QVariant(*static_cast<QIcon *>(icon));
}

} // extern "C"
