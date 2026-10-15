#include "flutter_window.h"

#include <flutter/standard_method_codec.h>
#include <shellapi.h>
#include <shlobj.h>
#include <windows.h>

#include <fstream>
#include <optional>
#include <string>
#include <vector>

#include "flutter/generated_plugin_registrant.h"

namespace {

std::wstring Utf8ToUtf16(const std::string& str) {
  if (str.empty()) {
    return std::wstring();
  }
  int size_needed = MultiByteToWideChar(
      CP_UTF8, 0, str.data(), static_cast<int>(str.size()), nullptr, 0);
  std::wstring wstr(size_needed, 0);
  MultiByteToWideChar(CP_UTF8, 0, str.data(), static_cast<int>(str.size()),
                      &wstr[0], size_needed);
  return wstr;
}

std::string Utf16ToUtf8(const std::wstring& wstr) {
  if (wstr.empty()) {
    return std::string();
  }
  int size_needed = WideCharToMultiByte(
      CP_UTF8, 0, wstr.data(), static_cast<int>(wstr.size()), nullptr, 0,
      nullptr, nullptr);
  std::string str(size_needed, 0);
  WideCharToMultiByte(CP_UTF8, 0, wstr.data(), static_cast<int>(wstr.size()),
                      &str[0], size_needed, nullptr, nullptr);
  return str;
}

std::wstring ToWindowsPath(const std::string& path) {
  std::wstring wpath = Utf8ToUtf16(path);
  for (auto& ch : wpath) {
    if (ch == L'/') {
      ch = L'\\';
    }
  }
  return wpath;
}

std::string FromWindowsPath(const std::wstring& wpath) {
  std::string path = Utf16ToUtf8(wpath);
  for (auto& ch : path) {
    if (ch == '\\') {
      ch = '/';
    }
  }
  return path;
}

std::vector<uint8_t> ReadFileBytes(const std::wstring& wpath) {
  std::ifstream file(wpath, std::ios::binary | std::ios::ate);
  if (!file.is_open()) {
    return {};
  }
  std::streamsize size = file.tellg();
  if (size <= 0) {
    return {};
  }
  file.seekg(0, std::ios::beg);
  std::vector<uint8_t> buffer(static_cast<size_t>(size));
  if (file.read(reinterpret_cast<char*>(buffer.data()), size)) {
    return buffer;
  }
  return {};
}

bool CopyFileToClipboard(HWND hwnd, const std::string& path) {
  std::wstring wpath = ToWindowsPath(path);
  if (wpath.empty()) {
    return false;
  }

  DWORD attrs = GetFileAttributesW(wpath.c_str());
  if (attrs == INVALID_FILE_ATTRIBUTES || (attrs & FILE_ATTRIBUTE_DIRECTORY)) {
    return false;
  }

  if (!OpenClipboard(hwnd)) {
    return false;
  }
  EmptyClipboard();

  size_t path_bytes = (wpath.size() + 2) * sizeof(wchar_t);
  size_t total_bytes = sizeof(DROPFILES) + path_bytes;

  HGLOBAL hGlobal = GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT, total_bytes);
  if (!hGlobal) {
    CloseClipboard();
    return false;
  }

  DROPFILES* df = static_cast<DROPFILES*>(GlobalLock(hGlobal));
  if (!df) {
    GlobalFree(hGlobal);
    CloseClipboard();
    return false;
  }

  df->pFiles = sizeof(DROPFILES);
  df->fWide = TRUE;

  wchar_t* dest = reinterpret_cast<wchar_t*>(reinterpret_cast<char*>(df) +
                                             sizeof(DROPFILES));
  memcpy(dest, wpath.c_str(), (wpath.size() + 1) * sizeof(wchar_t));
  dest[wpath.size() + 1] = L'\0';

  GlobalUnlock(hGlobal);

  if (!SetClipboardData(CF_HDROP, hGlobal)) {
    GlobalFree(hGlobal);
    CloseClipboard();
    return false;
  }

  CloseClipboard();
  return true;
}

std::vector<uint8_t> ReadCopiedFile(HWND hwnd) {
  if (!OpenClipboard(hwnd)) {
    return {};
  }

  std::vector<uint8_t> result;

  if (IsClipboardFormatAvailable(CF_HDROP)) {
    HANDLE hDrop = GetClipboardData(CF_HDROP);
    if (hDrop) {
      HDROP hDropHandle = static_cast<HDROP>(hDrop);
      UINT count = DragQueryFileW(hDropHandle, 0xFFFFFFFF, nullptr, 0);
      if (count > 0) {
        UINT len = DragQueryFileW(hDropHandle, 0, nullptr, 0);
        if (len > 0) {
          std::vector<wchar_t> buf(len + 1);
          if (DragQueryFileW(hDropHandle, 0, buf.data(), len + 1)) {
            result = ReadFileBytes(buf.data());
          }
        }
      }
    }
  }

  if (result.empty()) {
    UINT cfPng = RegisterClipboardFormatW(L"PNG");
    if (cfPng && IsClipboardFormatAvailable(cfPng)) {
      HANDLE hData = GetClipboardData(cfPng);
      if (hData) {
        void* ptr = GlobalLock(hData);
        size_t size = GlobalSize(hData);
        if (ptr && size > 0) {
          const uint8_t* bytePtr = static_cast<const uint8_t*>(ptr);
          result.assign(bytePtr, bytePtr + size);
          GlobalUnlock(hData);
        }
      }
    }
  }

  if (result.empty() && IsClipboardFormatAvailable(CF_DIB)) {
    HANDLE hDib = GetClipboardData(CF_DIB);
    if (hDib) {
      void* ptr = GlobalLock(hDib);
      size_t size = GlobalSize(hDib);
      if (ptr && size >= sizeof(BITMAPINFOHEADER)) {
        BITMAPINFOHEADER* bih = static_cast<BITMAPINFOHEADER*>(ptr);
        BITMAPFILEHEADER bfh = {};
        bfh.bfType = 0x4D42;  // "BM"
        bfh.bfSize = static_cast<DWORD>(sizeof(BITMAPFILEHEADER) + size);
        DWORD colorCount = 0;
        if (bih->biBitCount <= 8) {
          colorCount = bih->biClrUsed ? bih->biClrUsed : (1 << bih->biBitCount);
        } else if (bih->biCompression == BI_BITFIELDS) {
          colorCount = 3;
        }
        bfh.bfOffBits = sizeof(BITMAPFILEHEADER) + bih->biSize +
                        (colorCount * sizeof(RGBQUAD));

        result.resize(sizeof(BITMAPFILEHEADER) + size);
        memcpy(result.data(), &bfh, sizeof(BITMAPFILEHEADER));
        memcpy(result.data() + sizeof(BITMAPFILEHEADER), ptr, size);
      }
      if (ptr) {
        GlobalUnlock(hDib);
      }
    }
  }

  CloseClipboard();
  return result;
}

flutter::EncodableValue PasteSource(HWND hwnd) {
  if (!OpenClipboard(hwnd)) {
    return flutter::EncodableValue();
  }

  if (IsClipboardFormatAvailable(CF_HDROP)) {
    HANDLE hDrop = GetClipboardData(CF_HDROP);
    if (hDrop) {
      HDROP hDropHandle = static_cast<HDROP>(hDrop);
      UINT count = DragQueryFileW(hDropHandle, 0xFFFFFFFF, nullptr, 0);
      if (count > 0) {
        UINT len = DragQueryFileW(hDropHandle, 0, nullptr, 0);
        if (len > 0) {
          std::vector<wchar_t> buf(len + 1);
          if (DragQueryFileW(hDropHandle, 0, buf.data(), len + 1)) {
            std::string normPath = FromWindowsPath(buf.data());
            CloseClipboard();
            flutter::EncodableMap map;
            map[flutter::EncodableValue("path")] =
                flutter::EncodableValue(normPath);
            return flutter::EncodableValue(map);
          }
        }
      }
    }
  }

  UINT cfPng = RegisterClipboardFormatW(L"PNG");
  if (cfPng && IsClipboardFormatAvailable(cfPng)) {
    HANDLE hData = GetClipboardData(cfPng);
    if (hData) {
      void* ptr = GlobalLock(hData);
      size_t size = GlobalSize(hData);
      if (ptr && size > 0) {
        const uint8_t* bytePtr = static_cast<const uint8_t*>(ptr);
        std::vector<uint8_t> pngBytes(bytePtr, bytePtr + size);
        GlobalUnlock(hData);
        CloseClipboard();
        flutter::EncodableMap map;
        map[flutter::EncodableValue("bytes")] =
            flutter::EncodableValue(pngBytes);
        map[flutter::EncodableValue("type")] =
            flutter::EncodableValue("image/png");
        return flutter::EncodableValue(map);
      }
      if (ptr) {
        GlobalUnlock(hData);
      }
    }
  }

  if (IsClipboardFormatAvailable(CF_DIB)) {
    HANDLE hDib = GetClipboardData(CF_DIB);
    if (hDib) {
      void* ptr = GlobalLock(hDib);
      size_t size = GlobalSize(hDib);
      if (ptr && size >= sizeof(BITMAPINFOHEADER)) {
        BITMAPINFOHEADER* bih = static_cast<BITMAPINFOHEADER*>(ptr);
        BITMAPFILEHEADER bfh = {};
        bfh.bfType = 0x4D42;  // "BM"
        bfh.bfSize = static_cast<DWORD>(sizeof(BITMAPFILEHEADER) + size);
        DWORD colorCount = 0;
        if (bih->biBitCount <= 8) {
          colorCount = bih->biClrUsed ? bih->biClrUsed : (1 << bih->biBitCount);
        } else if (bih->biCompression == BI_BITFIELDS) {
          colorCount = 3;
        }
        bfh.bfOffBits = sizeof(BITMAPFILEHEADER) + bih->biSize +
                        (colorCount * sizeof(RGBQUAD));

        std::vector<uint8_t> bmpBytes(sizeof(BITMAPFILEHEADER) + size);
        memcpy(bmpBytes.data(), &bfh, sizeof(BITMAPFILEHEADER));
        memcpy(bmpBytes.data() + sizeof(BITMAPFILEHEADER), ptr, size);
        GlobalUnlock(hDib);
        CloseClipboard();
        flutter::EncodableMap map;
        map[flutter::EncodableValue("bytes")] =
            flutter::EncodableValue(bmpBytes);
        map[flutter::EncodableValue("type")] =
            flutter::EncodableValue("image/bmp");
        return flutter::EncodableValue(map);
      }
      if (ptr) {
        GlobalUnlock(hDib);
      }
    }
  }

  CloseClipboard();
  return flutter::EncodableValue();
}

std::string TrashFile(const std::string& path) {
  if (path.empty()) {
    return "failed: empty path";
  }
  std::wstring wpath = ToWindowsPath(path);
  wpath.push_back(L'\0');

  SHFILEOPSTRUCTW op = {};
  op.wFunc = FO_DELETE;
  op.pFrom = wpath.c_str();
  op.fFlags = FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_NOERRORUI | FOF_SILENT;

  int rc = SHFileOperationW(&op);
  if (rc == 0) {
    if (op.fAnyOperationsAborted) {
      return "cancelled";
    }
    return "trashed";
  }
  return "failed: " + std::to_string(rc);
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());

  media_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "generativeview/media",
          &flutter::StandardMethodCodec::GetInstance());

  media_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        const std::string& method = call.method_name();
        if (method == "copyFile") {
          const auto* args =
              std::get_if<flutter::EncodableMap>(call.arguments());
          if (args) {
            auto it = args->find(flutter::EncodableValue("path"));
            if (it != args->end()) {
              if (const auto* path = std::get_if<std::string>(&it->second)) {
                bool ok = CopyFileToClipboard(GetHandle(), *path);
                result->Success(flutter::EncodableValue(ok));
                return;
              }
            }
          }
          result->Success(flutter::EncodableValue(false));
        } else if (method == "readCopiedFile") {
          std::vector<uint8_t> bytes = ReadCopiedFile(GetHandle());
          if (!bytes.empty()) {
            result->Success(flutter::EncodableValue(bytes));
          } else {
            result->Success(flutter::EncodableValue());
          }
        } else if (method == "pasteSource") {
          result->Success(PasteSource(GetHandle()));
        } else if (method == "trashFile") {
          const auto* args =
              std::get_if<flutter::EncodableMap>(call.arguments());
          if (args) {
            auto it = args->find(flutter::EncodableValue("path"));
            if (it != args->end()) {
              if (const auto* path = std::get_if<std::string>(&it->second)) {
                std::string status = TrashFile(*path);
                result->Success(flutter::EncodableValue(status));
                return;
              }
            }
          }
          result->Success(flutter::EncodableValue("failed: no path"));
        } else {
          result->NotImplemented();
        }
      });

  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() { this->Show(); });
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (media_channel_) {
    media_channel_ = nullptr;
  }
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
