#include "flutter_window.h"

#include <optional>

#include <string>

#include "flutter/generated_plugin_registrant.h"
#include "utils.h"

namespace {

// Puts a DWORD value on the (already opened) clipboard under a named format.
void SetClipboardDword(const wchar_t* format_name, DWORD value) {
  UINT format = RegisterClipboardFormatW(format_name);
  if (format == 0) {
    return;
  }
  HGLOBAL handle = GlobalAlloc(GMEM_MOVEABLE, sizeof(DWORD));
  if (!handle) {
    return;
  }
  DWORD* data = static_cast<DWORD*>(GlobalLock(handle));
  if (!data) {
    GlobalFree(handle);
    return;
  }
  *data = value;
  GlobalUnlock(handle);
  if (!SetClipboardData(format, handle)) {
    GlobalFree(handle);
  }
}

std::wstring Utf8ToWide(const std::string& text) {
  if (text.empty()) {
    return std::wstring();
  }
  int size = MultiByteToWideChar(CP_UTF8, 0, text.data(),
                                 static_cast<int>(text.size()), nullptr, 0);
  std::wstring wide(size, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, text.data(), static_cast<int>(text.size()),
                      wide.data(), size);
  return wide;
}

// Copies text to the clipboard and marks it so that Windows does not keep it
// in the clipboard history and does not upload it to the cloud clipboard.
bool CopySensitiveText(HWND owner, const std::string& utf8) {
  std::wstring text = Utf8ToWide(utf8);
  if (!OpenClipboard(owner)) {
    return false;
  }
  EmptyClipboard();
  bool ok = false;
  size_t bytes = (text.size() + 1) * sizeof(wchar_t);
  HGLOBAL handle = GlobalAlloc(GMEM_MOVEABLE, bytes);
  if (handle) {
    void* data = GlobalLock(handle);
    if (data) {
      memcpy(data, text.c_str(), bytes);
      GlobalUnlock(handle);
      if (SetClipboardData(CF_UNICODETEXT, handle)) {
        ok = true;
      } else {
        GlobalFree(handle);
      }
    } else {
      GlobalFree(handle);
    }
  }
  SetClipboardDword(L"ExcludeClipboardContentFromMonitorProcessing", 1);
  SetClipboardDword(L"CanIncludeInClipboardHistory", 0);
  SetClipboardDword(L"CanUploadToCloudClipboard", 0);
  CloseClipboard();
  return ok;
}

bool ClearClipboard(HWND owner) {
  if (!OpenClipboard(owner)) {
    return false;
  }
  EmptyClipboard();
  CloseClipboard();
  return true;
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

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());

  platform_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "secretvault/platform",
          &flutter::StandardMethodCodec::GetInstance());
  platform_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() == "copySensitive") {
          std::string text;
          const auto* args =
              std::get_if<flutter::EncodableMap>(call.arguments());
          if (args) {
            auto it = args->find(flutter::EncodableValue("text"));
            if (it != args->end()) {
              if (const auto* value = std::get_if<std::string>(&it->second)) {
                text = *value;
              }
            }
          }
          if (CopySensitiveText(GetHandle(), text)) {
            result->Success();
          } else {
            result->Error("clipboard", "Unable to open the clipboard");
          }
        } else if (call.method_name() == "clearClipboard") {
          if (ClearClipboard(GetHandle())) {
            result->Success();
          } else {
            result->Error("clipboard", "Unable to open the clipboard");
          }
        } else {
          result->NotImplemented();
        }
      });

  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  platform_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
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
