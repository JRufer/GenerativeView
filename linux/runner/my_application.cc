#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#include <string.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
  FlMethodChannel* media_channel;
  GtkWindow* window;
  FlView* view;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// --- Copying a file to the clipboard ---------------------------------------
//
// "Copy image" puts the file itself on the clipboard, in the three shapes
// other programs ask for: a list of URIs (file managers, upload boxes, chat
// apps), GNOME's copied-files format, and the file's own bytes under its
// image type (image editors, browsers). The bytes are read from disk when
// someone pastes and handed over untouched, so the generation data stored in
// the file goes with it.

enum {
  kTargetUriList,
  kTargetGnomeCopiedFiles,
  kTargetImage,
};

// The image type to offer a file's bytes as, or nullptr for anything that is
// not a picture (videos are offered as files only).
static const gchar* image_type_for(const gchar* path) {
  const gchar* dot = strrchr(path, '.');
  if (dot == nullptr) {
    return nullptr;
  }
  g_autofree gchar* extension = g_ascii_strdown(dot + 1, -1);
  if (g_str_equal(extension, "png")) {
    return "image/png";
  }
  if (g_str_equal(extension, "jpg") || g_str_equal(extension, "jpeg")) {
    return "image/jpeg";
  }
  if (g_str_equal(extension, "webp")) {
    return "image/webp";
  }
  if (g_str_equal(extension, "gif")) {
    return "image/gif";
  }
  if (g_str_equal(extension, "bmp")) {
    return "image/bmp";
  }
  return nullptr;
}

// The file:// URIs of |paths|, a null-terminated list, as a new list.
static gchar** uris_for(gchar** paths) {
  guint n = g_strv_length(paths);
  gchar** uris = g_new0(gchar*, n + 1);
  for (guint i = 0; i < n; i++) {
    g_autoptr(GFile) file = g_file_new_for_path(paths[i]);
    uris[i] = g_file_get_uri(file);
  }
  return uris;
}

// Called when another program pastes: |user_data| is the copied files'
// paths, a null-terminated list.
static void clipboard_get_cb(GtkClipboard* clipboard,
                             GtkSelectionData* selection_data,
                             guint info,
                             gpointer user_data) {
  gchar** paths = static_cast<gchar**>(user_data);
  const gchar* path = paths[0];
  g_auto(GStrv) uris = uris_for(paths);
  switch (info) {
    case kTargetUriList: {
      gtk_selection_data_set_uris(selection_data, uris);
      break;
    }
    case kTargetGnomeCopiedFiles: {
      g_autofree gchar* list = g_strjoinv("\n", uris);
      g_autofree gchar* text = g_strconcat("copy\n", list, nullptr);
      gtk_selection_data_set(selection_data,
                             gtk_selection_data_get_target(selection_data), 8,
                             reinterpret_cast<const guchar*>(text),
                             static_cast<gint>(strlen(text)));
      break;
    }
    case kTargetImage: {
      g_autofree gchar* bytes = nullptr;
      gsize length = 0;
      if (g_file_get_contents(path, &bytes, &length, nullptr)) {
        gtk_selection_data_set(selection_data,
                               gtk_selection_data_get_target(selection_data), 8,
                               reinterpret_cast<const guchar*>(bytes),
                               static_cast<gint>(length));
      }
      break;
    }
    default:
      break;
  }
}

// Called when something else is copied, or the app closes.
static void clipboard_clear_cb(GtkClipboard* clipboard, gpointer user_data) {
  g_strfreev(static_cast<gchar**>(user_data));
}

// Put |paths| (a null-terminated list) on the clipboard as files; a single
// picture also as its own bytes.
static gboolean copy_files_to_clipboard(gchar** paths) {
  g_autoptr(GPtrArray) found = g_ptr_array_new_with_free_func(g_free);
  for (gchar** p = paths; p != nullptr && *p != nullptr; p++) {
    if (g_file_test(*p, G_FILE_TEST_IS_REGULAR)) {
      g_ptr_array_add(found, g_strdup(*p));
    }
  }
  if (found->len == 0) {
    return FALSE;
  }
  g_ptr_array_add(found, nullptr);
  gchar** owned_paths =
      reinterpret_cast<gchar**>(g_ptr_array_steal(found, nullptr));
  const gchar* path = owned_paths[0];
  GtkTargetList* list = gtk_target_list_new(nullptr, 0);
  gtk_target_list_add(list, gdk_atom_intern_static_string("text/uri-list"), 0,
                      kTargetUriList);
  gtk_target_list_add(
      list, gdk_atom_intern_static_string("x-special/gnome-copied-files"), 0,
      kTargetGnomeCopiedFiles);
  const gchar* image_type =
      owned_paths[1] == nullptr ? image_type_for(path) : nullptr;
  if (image_type != nullptr) {
    gtk_target_list_add(list, gdk_atom_intern(image_type, FALSE), 0,
                        kTargetImage);
  }
  gint count = 0;
  GtkTargetEntry* targets = gtk_target_table_new_from_list(list, &count);
  GtkClipboard* clipboard = gtk_clipboard_get(GDK_SELECTION_CLIPBOARD);
  gboolean ok =
      gtk_clipboard_set_with_data(clipboard, targets, count, clipboard_get_cb,
                                  clipboard_clear_cb, owned_paths);
  if (ok) {
    // Let a clipboard manager keep it after this window closes.
    gtk_clipboard_set_can_store(clipboard, nullptr, 0);
  } else {
    // On failure the clear callback is never called, so the paths are ours.
    g_strfreev(owned_paths);
  }
  gtk_target_table_free(targets, count);
  gtk_target_list_unref(list);
  return ok;
}

static gboolean copy_file_to_clipboard(const gchar* path) {
  gchar* paths[] = {const_cast<gchar*>(path), nullptr};
  return copy_files_to_clipboard(paths);
}

// --- Dragging files out of the window ---------------------------------------
//
// A drag has to start from the press of the mouse button that is still held,
// so every press is noted on its way to Flutter. When the app asks for a
// drag, GTK starts one from that press, offering the files as a list of
// URIs: a file manager, a browser's upload box or a chat window takes them
// as the files themselves.

static GdkEvent* last_press = nullptr;
static gchar** drag_uris = nullptr;

static void note_presses(GdkEvent* event, gpointer data) {
  if (event->type == GDK_BUTTON_PRESS && event->button.button == 1) {
    if (last_press != nullptr) {
      gdk_event_free(last_press);
    }
    last_press = gdk_event_copy(event);
  }
  gtk_main_do_event(event);
}

static void drag_data_get_cb(GtkWidget* widget,
                             GdkDragContext* context,
                             GtkSelectionData* selection_data,
                             guint info,
                             guint time,
                             gpointer user_data) {
  if (drag_uris != nullptr) {
    gtk_selection_data_set_uris(selection_data, drag_uris);
  }
}

// GTK took the mouse for the drag, so Flutter never saw the button come up:
// tell it, or it would think the button is still held.
static void drag_end_cb(GtkWidget* widget,
                        GdkDragContext* context,
                        gpointer user_data) {
  if (last_press == nullptr || last_press->button.window == nullptr) {
    return;
  }
  GdkEvent* release = gdk_event_new(GDK_BUTTON_RELEASE);
  release->button.window =
      GDK_WINDOW(g_object_ref(last_press->button.window));
  release->button.send_event = TRUE;
  release->button.time = GDK_CURRENT_TIME;
  release->button.button = 1;
  release->button.state = GDK_BUTTON1_MASK;
  GdkDevice* device = gdk_event_get_device(last_press);
  gdk_event_set_device(release, device);
  gdk_event_set_source_device(release, gdk_event_get_source_device(last_press));
  gint x = 0, y = 0;
  if (device != nullptr) {
    gdk_window_get_device_position(last_press->button.window, device, &x, &y,
                                   nullptr);
  }
  release->button.x = x;
  release->button.y = y;
  release->button.x_root = last_press->button.x_root;
  release->button.y_root = last_press->button.y_root;
  gtk_main_do_event(release);
  gdk_event_free(release);
}

static gboolean drag_files(MyApplication* self, gchar** paths) {
  if (self->view == nullptr || last_press == nullptr || paths == nullptr ||
      paths[0] == nullptr) {
    return FALSE;
  }
  g_strfreev(drag_uris);
  drag_uris = uris_for(paths);
  GtkTargetList* list = gtk_target_list_new(nullptr, 0);
  gtk_target_list_add(list, gdk_atom_intern_static_string("text/uri-list"), 0,
                      kTargetUriList);
  GdkDragContext* context = gtk_drag_begin_with_coordinates(
      GTK_WIDGET(self->view), list, GDK_ACTION_COPY, 1, last_press, -1, -1);
  gtk_target_list_unref(list);
  if (context == nullptr) {
    return FALSE;
  }
  gtk_drag_set_icon_name(context,
                         paths[1] == nullptr ? "image-x-generic"
                                             : "emblem-documents",
                         0, 0);
  return TRUE;
}

// The "paths" argument of a call, as a new null-terminated list.
static gchar** paths_argument(FlMethodCall* method_call) {
  FlValue* args = fl_method_call_get_args(method_call);
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    return nullptr;
  }
  FlValue* list = fl_value_lookup_string(args, "paths");
  if (list == nullptr || fl_value_get_type(list) != FL_VALUE_TYPE_LIST) {
    return nullptr;
  }
  size_t n = fl_value_get_length(list);
  gchar** out = g_new0(gchar*, n + 1);
  size_t at = 0;
  for (size_t i = 0; i < n; i++) {
    FlValue* item = fl_value_get_list_value(list, i);
    if (fl_value_get_type(item) == FL_VALUE_TYPE_STRING) {
      out[at++] = g_strdup(fl_value_get_string(item));
    }
  }
  return out;
}

// The bytes a program pasting the clipboard as a picture would get, or a null
// value when no picture is on offer. The integration test uses this to check
// that a copied image comes back unchanged.
static FlValue* read_copied_image() {
  GtkClipboard* clipboard = gtk_clipboard_get(GDK_SELECTION_CLIPBOARD);
  GdkAtom* targets = nullptr;
  gint count = 0;
  FlValue* result = nullptr;
  if (gtk_clipboard_wait_for_targets(clipboard, &targets, &count)) {
    for (gint i = 0; i < count && result == nullptr; i++) {
      g_autofree gchar* name = gdk_atom_name(targets[i]);
      if (!g_str_has_prefix(name, "image/")) {
        continue;
      }
      GtkSelectionData* data =
          gtk_clipboard_wait_for_contents(clipboard, targets[i]);
      if (data != nullptr) {
        gint length = gtk_selection_data_get_length(data);
        if (length >= 0) {
          result = fl_value_new_uint8_list(gtk_selection_data_get_data(data),
                                           static_cast<size_t>(length));
        }
        gtk_selection_data_free(data);
      }
    }
    g_free(targets);
  }
  return result != nullptr ? result : fl_value_new_null();
}

// --- Deleting and pasting ---------------------------------------------------

// Move a file to the desktop's trash (the freedesktop.org one GIO keeps,
// per drive). "trashed", "unsupported" when the drive has no trash, or
// "failed: <why>".
static FlValue* trash_file(const gchar* path) {
  g_autoptr(GFile) file = g_file_new_for_path(path);
  g_autoptr(GError) error = nullptr;
  if (g_file_trash(file, nullptr, &error)) {
    return fl_value_new_string("trashed");
  }
  if (g_error_matches(error, G_IO_ERROR, G_IO_ERROR_NOT_SUPPORTED)) {
    return fl_value_new_string("unsupported");
  }
  g_autofree gchar* text = g_strconcat("failed: ", error->message, nullptr);
  return fl_value_new_string(text);
}

// What a paste would bring in: {"path": ...} for a file copied in a file
// manager (or with Copy image here), so it arrives with its generation data;
// otherwise {"bytes": ..., "type": "image/..."} for a picture copied from a
// browser or an editor; null when the clipboard holds neither.
static FlValue* paste_source() {
  GtkClipboard* clipboard = gtk_clipboard_get(GDK_SELECTION_CLIPBOARD);
  gchar** uris = gtk_clipboard_wait_for_uris(clipboard);
  if (uris != nullptr) {
    // Every copied file, not just the first: the first as {"path"}, the
    // rest as a list under "more".
    FlValue* result = nullptr;
    FlValue* more = nullptr;
    for (gchar** uri = uris; *uri != nullptr; uri++) {
      g_autofree gchar* path = g_filename_from_uri(*uri, nullptr, nullptr);
      if (path == nullptr || !g_file_test(path, G_FILE_TEST_IS_REGULAR)) {
        continue;
      }
      if (result == nullptr) {
        result = fl_value_new_map();
        fl_value_set_string_take(result, "path", fl_value_new_string(path));
      } else {
        if (more == nullptr) {
          more = fl_value_new_list();
        }
        FlValue* item = fl_value_new_map();
        fl_value_set_string_take(item, "path", fl_value_new_string(path));
        fl_value_append_take(more, item);
      }
    }
    g_strfreev(uris);
    if (result != nullptr) {
      if (more != nullptr) {
        fl_value_set_string_take(result, "more", more);
      }
      return result;
    }
  }
  // Ask for the types that keep a picture's own bytes first.
  static const gchar* kTypes[] = {"image/png", "image/webp", "image/jpeg",
                                  "image/gif", "image/bmp"};
  GdkAtom* targets = nullptr;
  gint count = 0;
  if (!gtk_clipboard_wait_for_targets(clipboard, &targets, &count)) {
    return fl_value_new_null();
  }
  FlValue* result = nullptr;
  for (const gchar* type : kTypes) {
    for (gint i = 0; i < count && result == nullptr; i++) {
      g_autofree gchar* name = gdk_atom_name(targets[i]);
      if (!g_str_equal(name, type)) {
        continue;
      }
      GtkSelectionData* data =
          gtk_clipboard_wait_for_contents(clipboard, targets[i]);
      if (data != nullptr) {
        gint length = gtk_selection_data_get_length(data);
        if (length > 0) {
          result = fl_value_new_map();
          fl_value_set_string_take(
              result, "bytes",
              fl_value_new_uint8_list(gtk_selection_data_get_data(data),
                                      static_cast<size_t>(length)));
          fl_value_set_string_take(result, "type", fl_value_new_string(type));
        }
        gtk_selection_data_free(data);
      }
    }
    if (result != nullptr) {
      break;
    }
  }
  g_free(targets);
  return result != nullptr ? result : fl_value_new_null();
}

// The "path" argument of a call, or nullptr.
static const gchar* path_argument(FlMethodCall* method_call) {
  FlValue* args = fl_method_call_get_args(method_call);
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    return nullptr;
  }
  FlValue* path = fl_value_lookup_string(args, "path");
  if (path == nullptr || fl_value_get_type(path) != FL_VALUE_TYPE_STRING) {
    return nullptr;
  }
  return fl_value_get_string(path);
}

// Handles calls on the "generativeview/media" channel.
static void media_method_call_cb(FlMethodChannel* channel,
                                 FlMethodCall* method_call,
                                 gpointer user_data) {
  g_autoptr(FlMethodResponse) response = nullptr;
  const gchar* method = fl_method_call_get_name(method_call);
  if (g_str_equal(method, "readCopiedFile")) {
    g_autoptr(FlValue) result = read_copied_image();
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));
  } else if (g_str_equal(method, "copyFile")) {
    FlValue* args = fl_method_call_get_args(method_call);
    FlValue* path = nullptr;
    if (args != nullptr && fl_value_get_type(args) == FL_VALUE_TYPE_MAP) {
      path = fl_value_lookup_string(args, "path");
    }
    gboolean copied = FALSE;
    if (path != nullptr && fl_value_get_type(path) == FL_VALUE_TYPE_STRING) {
      copied = copy_file_to_clipboard(fl_value_get_string(path));
    }
    g_autoptr(FlValue) result = fl_value_new_bool(copied);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));
  } else if (g_str_equal(method, "copyFiles")) {
    g_auto(GStrv) paths = paths_argument(method_call);
    gboolean copied = paths != nullptr && copy_files_to_clipboard(paths);
    g_autoptr(FlValue) result = fl_value_new_bool(copied);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));
  } else if (g_str_equal(method, "dragFiles")) {
    g_auto(GStrv) paths = paths_argument(method_call);
    gboolean started = drag_files(MY_APPLICATION(user_data), paths);
    g_autoptr(FlValue) result = fl_value_new_bool(started);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));
  } else if (g_str_equal(method, "trashFile")) {
    const gchar* path = path_argument(method_call);
    g_autoptr(FlValue) result = path != nullptr
                                    ? trash_file(path)
                                    : fl_value_new_string("failed: no path");
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));
  } else if (g_str_equal(method, "setFullScreen")) {
    // The focus view's full-screen mode: the window drops its frame and
    // fills the monitor it is on, or goes back to how it was.
    MyApplication* self = MY_APPLICATION(user_data);
    FlValue* args = fl_method_call_get_args(method_call);
    FlValue* on = nullptr;
    if (args != nullptr && fl_value_get_type(args) == FL_VALUE_TYPE_MAP) {
      on = fl_value_lookup_string(args, "on");
    }
    if (self->window != nullptr && on != nullptr &&
        fl_value_get_type(on) == FL_VALUE_TYPE_BOOL) {
      if (fl_value_get_bool(on)) {
        gtk_window_fullscreen(self->window);
      } else {
        gtk_window_unfullscreen(self->window);
      }
    }
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (g_str_equal(method, "pasteSource")) {
    g_autoptr(FlValue) result = paste_source();
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }
  fl_method_call_respond(method_call, response, nullptr);
}

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));
  self->window = window;

  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup most users will be using (e.g. Ubuntu
  // desktop).
  // If running on X and not using GNOME then just use a traditional title bar
  // in case the window manager does more exotic layout, e.g. tiling.
  // If running on Wayland assume the header bar will work (may need changing
  // if future cases occur).
  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "GenerativeView");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "GenerativeView");
  }

  gtk_window_set_default_size(window, 1440, 900);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  self->view = view;
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  // For dragging files out: note each press, and serve the drag's files.
  gdk_event_handler_set(note_presses, nullptr, nullptr);
  g_signal_connect(view, "drag-data-get", G_CALLBACK(drag_data_get_cb),
                   nullptr);
  g_signal_connect(view, "drag-end", G_CALLBACK(drag_end_cb), nullptr);

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  self->media_channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)),
      "generativeview/media", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(
      self->media_channel, media_method_call_cb, self, nullptr);

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  g_clear_object(&self->media_channel);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     G_APPLICATION_NON_UNIQUE, nullptr));
}
