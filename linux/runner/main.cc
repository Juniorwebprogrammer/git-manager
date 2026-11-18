#include <gio/gio.h>

#include "my_application.h"

// GNOME 50 (Ubuntu 26.04) removed the "antialiasing"/"hinting"/"rgba-order"
// keys from the org.gnome.settings-daemon.plugins.xsettings schema, but GTK
// 3's Wayland backend still reads them, and GLib aborts on a missing key
// ("Settings schema ... does not contain a key named 'antialiasing'").
// Detect that broken combination and fall back to X11 (XWayland), which
// does not read the schema.
static gboolean wayland_xsettings_schema_is_broken() {
  GSettingsSchemaSource* source = g_settings_schema_source_get_default();
  if (source == nullptr) return FALSE;
  GSettingsSchema* schema = g_settings_schema_source_lookup(
      source, "org.gnome.settings-daemon.plugins.xsettings", TRUE);
  if (schema == nullptr) return FALSE;
  const gboolean broken = !g_settings_schema_has_key(schema, "antialiasing");
  g_settings_schema_unref(schema);
  return broken;
}

int main(int argc, char** argv) {
  // Respect an explicit GDK_BACKEND, and only switch when XWayland exists.
  if (g_getenv("GDK_BACKEND") == nullptr && g_getenv("DISPLAY") != nullptr &&
      wayland_xsettings_schema_is_broken()) {
    g_setenv("GDK_BACKEND", "x11", FALSE);
  }

  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}
