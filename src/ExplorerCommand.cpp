// Copyright (c) My Context Menu Tools contributors.
// Licensed under the MIT License.

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <bcrypt.h>
#include <shellapi.h>
#include <servprov.h>
#include <shlguid.h>
#include <shlobj_core.h>
#include <shlwapi.h>
#include <shobjidl_core.h>
#include <restartmanager.h>

#include <wil/Tracelogging.h>
#include <wil/resource.h>
#include <wil/result.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Data.Json.h>
#include <winrt/base.h>
#include <wil/cppwinrt.h>

#include <algorithm>
#include <chrono>
#include <cstring>
#include <cwctype>
#include <iterator>
#include <map>
#include <mutex>
#include <new>
#include <set>
#include <string>
#include <utility>
#include <vector>

#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "shell32.lib")
#pragma comment(lib, "shlwapi.lib")
#pragma comment(lib, "advapi32.lib")
#pragma comment(lib, "bcrypt.lib")
#pragma comment(lib, "rstrtmgr.lib")
#pragma comment(lib, "user32.lib")

TRACELOGGING_DEFINE_PROVIDER(
    g_traceProvider,
    "MyContextMenuTools.ExplorerCommand",
    (0xc1719ad1, 0x3a12, 0x49be, 0x96, 0x2a, 0x3f, 0xe0, 0xb7, 0x7b, 0x1e, 0xcc));

#ifndef MYTOOLS_SHOW_PERFORMANCE_VERB
#define MYTOOLS_SHOW_PERFORMANCE_VERB 1
#endif

namespace {

using JsonArray = winrt::Windows::Data::Json::JsonArray;
using JsonObject = winrt::Windows::Data::Json::JsonObject;
using JsonValue = winrt::Windows::Data::Json::IJsonValue;
using JsonValueType = winrt::Windows::Data::Json::JsonValueType;
using RuntimeJsonValue = winrt::Windows::Data::Json::JsonValue;
using unique_rm_session = wil::unique_any<DWORD,
                                          decltype(&::RmEndSession),
                                          ::RmEndSession,
                                          wil::details::pointer_access_all,
                                          DWORD,
                                          DWORD,
                                          MAXDWORD,
                                          DWORD>;

const CLSID CLSID_MyContextMenuTools = {
    0xcb098f2b,
    0x3127,
    0x44a2,
    {0xb3, 0x01, 0x58, 0x0f, 0x69, 0x84, 0xc8, 0x5d}};
const CLSID CLSID_MyContextMenuToolsFolderBackground = {
    0xcb098f2b,
    0x3127,
    0x44a2,
    {0xb3, 0x01, 0x58, 0x0f, 0x69, 0x84, 0xc8, 0x5e}};
const CLSID CLSID_MyContextMenuToolsDesktopBackground = {
    0xcb098f2b,
    0x3127,
    0x44a2,
    {0xb3, 0x01, 0x58, 0x0f, 0x69, 0x84, 0xc8, 0x5f}};

enum class CommandContext {
  Selection,
  FolderBackground,
  DesktopBackground
};

enum class ToolAction {
  ShellExecute,
  MakeBackupFile,
  TouchFile,
  CopySha256ToClipboard,
  CopyLockingProcessIds,
  DeleteAfterKillingLockingProcesses
};

long g_objectCount = 0;
long g_lockCount = 0;
HINSTANCE g_module = nullptr;

constexpr unsigned char kDynamicContextSelection = 0x5d;
constexpr unsigned char kDynamicContextFolderBackground = 0x5e;

void __stdcall LogWilFailure(const wil::FailureInfo& failure) noexcept {
  TraceLoggingWrite(g_traceProvider,
                    "WilFailure",
                    TraceLoggingLevel(WINEVENT_LEVEL_ERROR),
                    TraceLoggingHResult(failure.hr, "HResult"),
                    TraceLoggingString(failure.pszFile, "File"),
                    TraceLoggingUInt32(failure.uLineNumber, "Line"),
                    TraceLoggingString(failure.pszFunction, "Function"),
                    TraceLoggingWideString(failure.pszMessage, "Message"));
}

struct CommandProfile {
  CommandContext context = CommandContext::Selection;
  unsigned char slot = 0;
  CLSID classId = CLSID_MyContextMenuTools;
};

std::wstring ConfigPath();
std::wstring ConfigPathForProfile(const CommandProfile& profile);
std::wstring SnapshotPathForConfig(const std::wstring& configPath);
bool TryGetFileLastWriteTime(const std::wstring& path, FILETIME& lastWriteTime);
bool ReadUtf8File(const std::wstring& path, std::wstring& content, FILETIME* lastWriteTime = nullptr);
void ReplaceAll(std::wstring& text, const std::wstring& from, const std::wstring& to);

struct SourceStamp {
  std::wstring path;
  std::wstring lastWriteTime;
};

struct SelectionItem {
  std::wstring path;
  bool isDirectory = false;
  bool isFolderBackground = false;
  bool isDesktopBackground = false;
};

struct ToolItem {
  std::wstring id;
  std::wstring title;
  std::wstring tooltip;
  std::wstring icon;
  std::wstring command;
  std::wstring arguments;
  std::wstring workingDirectory;
  std::wstring verb;
  ToolAction action = ToolAction::ShellExecute;
  bool isSeparator = false;
  bool isInformational = false;
  bool appliesToFiles = true;
  bool appliesToFolders = false;
  bool appliesToFolderBackgrounds = false;
  bool appliesToDesktopBackground = false;
  std::vector<std::wstring> includeExtensions;
  std::vector<std::wstring> excludeExtensions;
  std::vector<ToolItem> children;
};

struct ToolConfig {
  std::wstring menuTitle = L"My Tools";
  std::wstring menuTooltip = L"Commands from My Context Menu Tools";
  std::wstring menuIcon;
  std::vector<ToolItem> items;
};

std::wstring ToLower(std::wstring value) {
  std::transform(value.begin(), value.end(), value.begin(), [](wchar_t ch) {
    return static_cast<wchar_t>(std::towlower(ch));
  });
  return value;
}

std::wstring ExpandEnvironmentPath(const std::wstring& value) {
  if (value.empty()) {
    return value;
  }

  const DWORD needed = ExpandEnvironmentStringsW(value.c_str(), nullptr, 0);
  if (needed == 0) {
    return value;
  }

  std::wstring expanded(needed, L'\0');
  const DWORD written = ExpandEnvironmentStringsW(value.c_str(), expanded.data(), needed);
  if (written == 0 || written > needed) {
    return value;
  }
  expanded.resize(wcslen(expanded.c_str()));
  return expanded;
}

std::wstring ModuleDirectory() {
  wchar_t path[MAX_PATH * 4]{};
  if (!g_module || !GetModuleFileNameW(g_module, path, ARRAYSIZE(path))) {
    return L"";
  }
  PathRemoveFileSpecW(path);
  return path;
}

std::wstring JoinPath(const std::wstring& directory, const std::wstring& fileName) {
  if (directory.empty()) {
    return fileName;
  }
  std::wstring result = directory;
  if (result.back() != L'\\') {
    result.push_back(L'\\');
  }
  result += fileName;
  return result;
}

bool IsDarkMode() {
  DWORD value = 1;
  DWORD size = sizeof(value);
  const auto result = RegGetValueW(HKEY_CURRENT_USER,
                                   L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
                                   L"AppsUseLightTheme",
                                   RRF_RT_REG_DWORD,
                                   nullptr,
                                   &value,
                                   &size);
  return result == ERROR_SUCCESS && value == 0;
}

int HexDigit(wchar_t ch) {
  if (ch >= L'0' && ch <= L'9') {
    return ch - L'0';
  }
  ch = static_cast<wchar_t>(std::towlower(ch));
  if (ch >= L'a' && ch <= L'f') {
    return 10 + ch - L'a';
  }
  return -1;
}

bool IsHexColorAt(const std::wstring& text, size_t index) {
  if (index + 7 > text.size() || text[index] != L'#') {
    return false;
  }
  for (size_t i = 1; i <= 6; ++i) {
    if (HexDigit(text[index + i]) < 0) {
      return false;
    }
  }
  return true;
}

std::wstring InvertHexColor(const std::wstring& color) {
  wchar_t buffer[8]{};
  buffer[0] = L'#';
  for (size_t i = 0; i < 3; ++i) {
    const int high = HexDigit(color[1 + i * 2]);
    const int low = HexDigit(color[2 + i * 2]);
    const int inverted = 255 - (high * 16 + low);
    swprintf_s(buffer + 1 + i * 2, 3, L"%02X", inverted);
  }
  return buffer;
}

bool ReadSmallUtf8File(const std::wstring& path, std::wstring& content) {
  return ReadUtf8File(path, content);
}

HRESULT WriteUtf8FileHr(const std::wstring& path, const std::wstring& content) noexcept {
  try {
    const int size = WideCharToMultiByte(CP_UTF8, 0, content.data(), static_cast<int>(content.size()), nullptr, 0, nullptr, nullptr);
    RETURN_HR_IF(HRESULT_FROM_WIN32(ERROR_NO_UNICODE_TRANSLATION), size <= 0);

    std::string bytes(size, '\0');
    RETURN_HR_IF(HRESULT_FROM_WIN32(ERROR_NO_UNICODE_TRANSLATION),
                 WideCharToMultiByte(CP_UTF8, 0, content.data(), static_cast<int>(content.size()), bytes.data(), size, nullptr, nullptr) !=
                     size);

    wil::unique_hfile file(CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr));
    RETURN_LAST_ERROR_IF(!file);

    DWORD written = 0;
    RETURN_IF_WIN32_BOOL_FALSE(WriteFile(file.get(), bytes.data(), static_cast<DWORD>(bytes.size()), &written, nullptr));
    RETURN_HR_IF(HRESULT_FROM_WIN32(ERROR_WRITE_FAULT), written != bytes.size());
    return S_OK;
  }
  CATCH_RETURN();
}

bool WriteUtf8File(const std::wstring& path, const std::wstring& content) {
  return SUCCEEDED(WriteUtf8FileHr(path, content));
}

std::wstring InvertedSvgPath(const std::wstring& path) {
  if (!IsDarkMode() || ToLower(PathFindExtensionW(path.c_str())) != L".svg") {
    return path;
  }

  std::wstring svg;
  if (!ReadSmallUtf8File(path, svg)) {
    return path;
  }

  std::vector<std::wstring> colors;
  for (size_t i = 0; i < svg.size(); ++i) {
    if (!IsHexColorAt(svg, i)) {
      continue;
    }
    auto color = ToLower(svg.substr(i, 7));
    if (std::find(colors.begin(), colors.end(), color) == colors.end()) {
      colors.push_back(color);
    }
    i += 6;
  }

  if (colors.size() != 1) {
    return path;
  }

  const auto inverted = InvertHexColor(colors.front());
  ReplaceAll(svg, colors.front(), inverted);
  std::wstring upper = colors.front();
  std::transform(upper.begin(), upper.end(), upper.begin(), [](wchar_t ch) {
    return static_cast<wchar_t>(std::towupper(ch));
  });
  ReplaceAll(svg, upper, inverted);

  const auto cacheDirectory = JoinPath(ConfigPath().substr(0, ConfigPath().find_last_of(L'\\')), L"IconCache");
  CreateDirectoryW(cacheDirectory.c_str(), nullptr);
  const auto output = JoinPath(cacheDirectory, L"Extension.dark.svg");
  return WriteUtf8File(output, svg) ? output : path;
}

std::wstring SidecarIconPathForSvg(const std::wstring& svgPath) {
  if (ToLower(PathFindExtensionW(svgPath.c_str())) != L".svg") {
    return L"";
  }

  wchar_t basePath[MAX_PATH * 4]{};
  if (svgPath.size() >= ARRAYSIZE(basePath)) {
    return L"";
  }
  wcscpy_s(basePath, svgPath.c_str());
  PathRemoveExtensionW(basePath);

  const std::wstring darkIco = std::wstring(basePath) + L".dark.ico";
  if (IsDarkMode() && GetFileAttributesW(darkIco.c_str()) != INVALID_FILE_ATTRIBUTES) {
    return darkIco;
  }

  const std::wstring ico = std::wstring(basePath) + L".ico";
  if (GetFileAttributesW(ico.c_str()) != INVALID_FILE_ATTRIBUTES) {
    return ico;
  }

  const std::wstring darkPng = std::wstring(basePath) + L".dark.png";
  if (IsDarkMode() && GetFileAttributesW(darkPng.c_str()) != INVALID_FILE_ATTRIBUTES) {
    return darkPng;
  }

  const std::wstring png = std::wstring(basePath) + L".png";
  if (GetFileAttributesW(png.c_str()) != INVALID_FILE_ATTRIBUTES) {
    return png;
  }

  return L"";
}

std::wstring DefaultIconPath() {
  return JoinPath(ModuleDirectory(), L"MyContextMenuTools.exe");
}

std::wstring SmokeIconPath(const std::wstring& fileName) {
  return JoinPath(ModuleDirectory(), L"Assets\\" + fileName);
}

std::wstring ResolveIconPath(const std::wstring& icon) {
  if (icon == L"__none") {
    return L"";
  }
  if (icon == L"__default" || icon == L"__exe") {
    return DefaultIconPath();
  }
  if (icon == L"__ico") {
    return SmokeIconPath(IsDarkMode() ? L"Extension.dark.ico" : L"Extension.ico");
  }
  if (icon == L"__png") {
    return SmokeIconPath(IsDarkMode() ? L"Extension.dark.png" : L"Extension.png");
  }
  if (icon == L"__svg") {
    return SmokeIconPath(L"Extension.svg");
  }
  if (icon == L"__json") {
    return SmokeIconPath(L"MyTools.Json.png");
  }
  if (icon == L"__appicon") {
    return SmokeIconPath(L"AppIcon.ico");
  }

  const auto resolved = icon.empty() ? DefaultIconPath() : ExpandEnvironmentPath(icon);
  const auto sidecar = SidecarIconPathForSvg(resolved);
  if (!sidecar.empty()) {
    return sidecar;
  }
  return InvertedSvgPath(resolved);
}

HRESULT DuplicateString(const std::wstring& value, PWSTR* output) {
  RETURN_HR_IF_NULL(E_POINTER, output);
  RETURN_IF_FAILED(SHStrDupW(value.c_str(), output));
  return S_OK;
}

std::wstring QuoteArgument(const std::wstring& arg) {
  if (arg.find_first_of(L" \t\n\v\"") == std::wstring::npos) {
    return arg;
  }

  std::wstring result;
  result.push_back(L'"');
  size_t backslashes = 0;
  for (wchar_t ch : arg) {
    if (ch == L'\\') {
      ++backslashes;
    } else if (ch == L'"') {
      result.append(backslashes * 2 + 1, L'\\');
      result.push_back(ch);
      backslashes = 0;
    } else {
      result.append(backslashes, L'\\');
      backslashes = 0;
      result.push_back(ch);
    }
  }

  result.append(backslashes * 2, L'\\');
  result.push_back(L'"');
  return result;
}

void ReplaceAll(std::wstring& text, const std::wstring& from, const std::wstring& to) {
  if (from.empty()) {
    return;
  }

  size_t start = 0;
  while ((start = text.find(from, start)) != std::wstring::npos) {
    text.replace(start, from.length(), to);
    start += to.length();
  }
}

std::wstring ParentPath(const std::wstring& path) {
  wchar_t buffer[MAX_PATH * 4]{};
  if (path.size() >= ARRAYSIZE(buffer)) {
    return L"";
  }
  wcscpy_s(buffer, path.c_str());
  PathRemoveFileSpecW(buffer);
  return buffer;
}

std::wstring DirectoryName(const std::wstring& path) {
  wchar_t buffer[MAX_PATH * 4]{};
  if (path.size() >= ARRAYSIZE(buffer)) {
    return L"";
  }
  wcscpy_s(buffer, path.c_str());
  PathRemoveFileSpecW(buffer);
  return buffer;
}

std::wstring ResolveConfigRelativePath(const std::wstring& value, const std::wstring& baseDirectory) {
  const auto expanded = ExpandEnvironmentPath(value);
  if (expanded.empty() || !PathIsRelativeW(expanded.c_str()) || baseDirectory.empty()) {
    return expanded;
  }
  return JoinPath(baseDirectory, expanded);
}

std::wstring FileName(const std::wstring& path) {
  return PathFindFileNameW(path.c_str());
}

std::wstring FileStem(const std::wstring& path) {
  wchar_t buffer[MAX_PATH * 4]{};
  const auto name = FileName(path);
  if (name.size() >= ARRAYSIZE(buffer)) {
    return name;
  }
  wcscpy_s(buffer, name.c_str());
  PathRemoveExtensionW(buffer);
  return buffer;
}

std::wstring ExtensionOf(const std::wstring& path) {
  const wchar_t* extension = PathFindExtensionW(path.c_str());
  return extension ? ToLower(extension) : L"";
}

std::wstring JoinPaths(const std::vector<SelectionItem>& selection, bool quote) {
  std::wstring result;
  for (const auto& item : selection) {
    if (!result.empty()) {
      result.push_back(L' ');
    }
    result += quote ? QuoteArgument(item.path) : item.path;
  }
  return result;
}

std::wstring ExpandCommandText(const std::wstring& input,
                               const ToolItem& item,
                               const std::vector<SelectionItem>& selection,
                               bool quoteValues) {
  std::wstring result = input;
  const std::wstring firstPath = selection.empty() ? L"" : selection.front().path;
  const std::wstring parent = firstPath.empty() ? L"" : ParentPath(firstPath);
  const std::wstring name = firstPath.empty() ? L"" : FileName(firstPath);
  const std::wstring stem = firstPath.empty() ? L"" : FileStem(firstPath);
  const bool firstIsContainer = !selection.empty() && (selection.front().isDirectory || selection.front().isFolderBackground || selection.front().isDesktopBackground);
  const std::wstring container = firstIsContainer ? firstPath : parent;
  const std::wstring namedPath = parent.empty() || name.empty() ? L"" : JoinPath(parent, name);
  const std::wstring stemPath = parent.empty() || stem.empty() ? L"" : JoinPath(parent, stem);

  ReplaceAll(result, L"%1", quoteValues ? QuoteArgument(firstPath) : firstPath);
  ReplaceAll(result, L"%*", JoinPaths(selection, quoteValues));
  ReplaceAll(result, L"{path}", quoteValues ? QuoteArgument(firstPath) : firstPath);
  ReplaceAll(result, L"{paths}", JoinPaths(selection, quoteValues));
  ReplaceAll(result, L"{parent}\\{name}", quoteValues ? QuoteArgument(namedPath) : namedPath);
  ReplaceAll(result, L"{parent}\\{stem}", quoteValues ? QuoteArgument(stemPath) : stemPath);
  ReplaceAll(result, L"{container}", quoteValues ? QuoteArgument(container) : container);
  ReplaceAll(result, L"{parent}", quoteValues ? QuoteArgument(parent) : parent);
  ReplaceAll(result, L"{name}", quoteValues ? QuoteArgument(name) : name);
  ReplaceAll(result, L"{stem}", quoteValues ? QuoteArgument(stem) : stem);
  ReplaceAll(result, L"{id}", quoteValues ? QuoteArgument(item.id) : item.id);
  return result;
}

bool ContainsExtension(const std::vector<std::wstring>& extensions, const std::wstring& extension) {
  return std::find(extensions.begin(), extensions.end(), ToLower(extension)) != extensions.end();
}

std::vector<std::wstring> SelectedFilePaths(const std::vector<SelectionItem>& selection) {
  std::vector<std::wstring> paths;
  for (const auto& selected : selection) {
    if (!selected.path.empty() && !selected.isDirectory && !selected.isFolderBackground && !selected.isDesktopBackground) {
      paths.push_back(selected.path);
    }
  }
  return paths;
}

HRESULT LockingProcessIdsHr(const std::vector<SelectionItem>& selection, std::vector<DWORD>& processIds) noexcept {
  try {
    const auto paths = SelectedFilePaths(selection);
    if (paths.empty()) {
      return S_OK;
    }

    unique_rm_session session;
    wchar_t sessionKey[CCH_RM_SESSION_KEY + 1]{};
    RETURN_IF_WIN32_ERROR(RmStartSession(session.put(), 0, sessionKey));

    std::set<DWORD> seen;
    std::vector<LPCWSTR> resources;
    resources.reserve(paths.size());
    for (const auto& path : paths) {
      resources.push_back(path.c_str());
    }

    RETURN_IF_WIN32_ERROR(RmRegisterResources(session.get(),
                                              static_cast<UINT>(resources.size()),
                                              resources.data(),
                                              0,
                                              nullptr,
                                              0,
                                              nullptr));

    UINT needed = 0;
    UINT count = 0;
    DWORD rebootReasons = RmRebootReasonNone;
    const DWORD initialListResult = RmGetList(session.get(), &needed, &count, nullptr, &rebootReasons);
    if (initialListResult == ERROR_SUCCESS) {
      return S_OK;
    }
    if (initialListResult != ERROR_MORE_DATA) {
      RETURN_WIN32(initialListResult);
    }
    if (needed == 0) {
      return S_OK;
    }

    std::vector<RM_PROCESS_INFO> processes(needed);
    count = needed;
    RETURN_IF_WIN32_ERROR(RmGetList(session.get(), &needed, &count, processes.data(), &rebootReasons));
    for (UINT i = 0; i < count; ++i) {
      const DWORD pid = processes[i].Process.dwProcessId;
      if (pid != 0 && seen.insert(pid).second) {
        processIds.push_back(pid);
      }
    }
    return S_OK;
  }
  CATCH_RETURN();
}

std::vector<DWORD> LockingProcessIds(const std::vector<SelectionItem>& selection) {
  std::vector<DWORD> processIds;
  LOG_IF_FAILED(LockingProcessIdsHr(selection, processIds));
  return processIds;
}

std::wstring JoinProcessIds(const std::vector<DWORD>& processIds) {
  std::wstring text;
  for (const auto pid : processIds) {
    if (!text.empty()) {
      text += L", ";
    }
    wchar_t value[16]{};
    swprintf_s(value, L"%lu", pid);
    text += value;
  }
  return text;
}

HRESULT CopyTextToClipboard(const std::wstring& text) {
  auto clipboard = wil::open_clipboard(nullptr);
  RETURN_LAST_ERROR_IF(!clipboard);
  RETURN_IF_WIN32_BOOL_FALSE(EmptyClipboard());

  const SIZE_T bytes = (text.size() + 1) * sizeof(wchar_t);
  wil::unique_hglobal memory(GlobalAlloc(GMEM_MOVEABLE, bytes));
  RETURN_IF_NULL_ALLOC(memory);

  {
    wil::unique_hglobal_locked data(memory.get());
    RETURN_LAST_ERROR_IF_NULL(data);
    memcpy(data.get(), text.c_str(), bytes);
  }

  RETURN_LAST_ERROR_IF_NULL(SetClipboardData(CF_UNICODETEXT, memory.get()));
  memory.release();
  return S_OK;
}

std::wstring WindowsErrorMessage(DWORD error) {
  wil::unique_hlocal_string message;
  const DWORD length = FormatMessageW(FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS,
                                      nullptr,
                                      error,
                                      0,
                                      reinterpret_cast<PWSTR>(message.put()),
                                      0,
                                      nullptr);
  std::wstring result = length && message ? message.get() : L"Windows error " + std::to_wstring(error);
  while (!result.empty() && (result.back() == L'\r' || result.back() == L'\n' || result.back() == L' ')) {
    result.pop_back();
  }
  return result;
}

void AppendFileError(std::wstring& errors,
                     const std::wstring& action,
                     const std::wstring& path,
                     const std::wstring& detail) {
  errors += action + L" \"" + path + L"\": " + detail + L"\n";
}

bool MakeBackupFiles(const std::vector<SelectionItem>& selection, std::wstring& errors) {
  bool ok = true;
  for (const auto& path : SelectedFilePaths(selection)) {
    bool copied = false;
    for (unsigned int copyNumber = 1; copyNumber <= 10000; ++copyNumber) {
      std::wstring backupPath = path + L".bak";
      if (copyNumber > 1) {
        backupPath += L" (" + std::to_wstring(copyNumber) + L")";
      }

      if (CopyFileW(path.c_str(), backupPath.c_str(), TRUE)) {
        SHChangeNotify(SHCNE_CREATE, SHCNF_PATHW, backupPath.c_str(), nullptr);
        copied = true;
        break;
      }

      const DWORD error = GetLastError();
      if (error == ERROR_FILE_EXISTS || error == ERROR_ALREADY_EXISTS) {
        continue;
      }

      LOG_HR(HRESULT_FROM_WIN32(error));
      AppendFileError(errors, L"Could not create a backup of", path, WindowsErrorMessage(error));
      ok = false;
      copied = true;
      break;
    }

    if (!copied) {
      AppendFileError(errors, L"Could not create a backup of", path, L"no available numbered .bak name was found.");
      ok = false;
    }
  }
  return ok;
}

HRESULT TouchFile(const std::wstring& path, const FILETIME& now) noexcept {
  wil::unique_hfile file(CreateFileW(path.c_str(),
                                     FILE_WRITE_ATTRIBUTES,
                                     FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                                     nullptr,
                                     OPEN_EXISTING,
                                     FILE_ATTRIBUTE_NORMAL,
                                     nullptr));
  RETURN_LAST_ERROR_IF(!file);
  RETURN_IF_WIN32_BOOL_FALSE(SetFileTime(file.get(), nullptr, nullptr, &now));
  SHChangeNotify(SHCNE_UPDATEITEM, SHCNF_PATHW, path.c_str(), nullptr);
  return S_OK;
}

bool TouchFiles(const std::vector<SelectionItem>& selection, std::wstring& errors) {
  FILETIME now{};
  GetSystemTimeAsFileTime(&now);

  bool ok = true;
  for (const auto& path : SelectedFilePaths(selection)) {
    const HRESULT result = TouchFile(path, now);
    if (FAILED(result)) {
      AppendFileError(errors, L"Could not touch", path, WindowsErrorMessage(HRESULT_CODE(result)));
      ok = false;
    }
  }
  return ok;
}

std::wstring BCryptErrorMessage(const wchar_t* operation, NTSTATUS status) {
  wchar_t value[96]{};
  swprintf_s(value, L"%s failed with status 0x%08X.", operation, static_cast<unsigned int>(status));
  return value;
}

HRESULT BCryptResult(NTSTATUS status, const wchar_t* operation, std::wstring& error) noexcept {
  if (status < 0) {
    error = BCryptErrorMessage(operation, status);
    return HRESULT_FROM_NT(status);
  }
  return S_OK;
}

HRESULT Sha256File(const std::wstring& path, std::wstring& hashText, std::wstring& error) noexcept {
  try {
    wil::unique_bcrypt_algorithm algorithm;
    wil::unique_bcrypt_hash hash;
    std::vector<UCHAR> hashObject;
    std::vector<UCHAR> hashValue;

    NTSTATUS status = BCryptOpenAlgorithmProvider(algorithm.put(), BCRYPT_SHA256_ALGORITHM, nullptr, 0);
    RETURN_IF_FAILED(BCryptResult(status, L"BCryptOpenAlgorithmProvider", error));

    DWORD hashObjectLength = 0;
    DWORD bytesReturned = 0;
    status = BCryptGetProperty(algorithm.get(),
                               BCRYPT_OBJECT_LENGTH,
                               reinterpret_cast<PUCHAR>(&hashObjectLength),
                               sizeof(hashObjectLength),
                               &bytesReturned,
                               0);
    RETURN_IF_FAILED(BCryptResult(status, L"BCryptGetProperty", error));

    DWORD hashLength = 0;
    status = BCryptGetProperty(algorithm.get(),
                               BCRYPT_HASH_LENGTH,
                               reinterpret_cast<PUCHAR>(&hashLength),
                               sizeof(hashLength),
                               &bytesReturned,
                               0);
    RETURN_IF_FAILED(BCryptResult(status, L"BCryptGetProperty", error));

    hashObject.resize(hashObjectLength);
    hashValue.resize(hashLength);
    status = BCryptCreateHash(algorithm.get(),
                              hash.put(),
                              hashObject.data(),
                              static_cast<ULONG>(hashObject.size()),
                              nullptr,
                              0,
                              0);
    RETURN_IF_FAILED(BCryptResult(status, L"BCryptCreateHash", error));

    wil::unique_hfile file(CreateFileW(path.c_str(),
                                       GENERIC_READ,
                                       FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                                       nullptr,
                                       OPEN_EXISTING,
                                       FILE_ATTRIBUTE_NORMAL | FILE_FLAG_SEQUENTIAL_SCAN,
                                       nullptr));
    if (!file) {
      error = WindowsErrorMessage(GetLastError());
      RETURN_LAST_ERROR();
    }

    std::vector<UCHAR> buffer(64 * 1024);
    while (true) {
      DWORD bytesRead = 0;
      if (!ReadFile(file.get(), buffer.data(), static_cast<DWORD>(buffer.size()), &bytesRead, nullptr)) {
        error = WindowsErrorMessage(GetLastError());
        RETURN_LAST_ERROR();
      }
      if (bytesRead == 0) {
        status = BCryptFinishHash(hash.get(), hashValue.data(), static_cast<ULONG>(hashValue.size()), 0);
        RETURN_IF_FAILED(BCryptResult(status, L"BCryptFinishHash", error));

        static constexpr wchar_t kHexDigits[] = L"0123456789abcdef";
        hashText.clear();
        hashText.reserve(hashValue.size() * 2);
        for (const UCHAR byte : hashValue) {
          hashText.push_back(kHexDigits[byte >> 4]);
          hashText.push_back(kHexDigits[byte & 0x0F]);
        }
        return S_OK;
      }

      status = BCryptHashData(hash.get(), buffer.data(), bytesRead, 0);
      RETURN_IF_FAILED(BCryptResult(status, L"BCryptHashData", error));
    }
  }
  CATCH_RETURN();
}

HRESULT CopySha256ToClipboard(const std::vector<SelectionItem>& selection, std::wstring& errors) {
  const auto paths = SelectedFilePaths(selection);
  std::vector<std::wstring> hashes;
  hashes.reserve(paths.size());

  for (const auto& path : paths) {
    std::wstring hash;
    std::wstring error;
    const HRESULT result = Sha256File(path, hash, error);
    if (FAILED(result)) {
      if (error.empty()) {
        error = WindowsErrorMessage(HRESULT_CODE(result));
      }
      AppendFileError(errors, L"Could not hash", path, error);
      continue;
    }
    hashes.push_back(std::move(hash));
  }

  RETURN_HR_IF(E_FAIL, !errors.empty() || hashes.size() != paths.size());

  std::wstring text;
  for (size_t i = 0; i < hashes.size(); ++i) {
    if (!text.empty()) {
      text += L"\r\n";
    }
    text += hashes[i];
    if (hashes.size() > 1) {
      text += L"  " + paths[i];
    }
  }
  return CopyTextToClipboard(text);
}

HRESULT TerminateLockingProcess(DWORD pid) noexcept {
  wil::unique_process_handle process(OpenProcess(PROCESS_TERMINATE | SYNCHRONIZE, FALSE, pid));
  RETURN_LAST_ERROR_IF(!process);
  RETURN_IF_WIN32_BOOL_FALSE(TerminateProcess(process.get(), 1));
  RETURN_LAST_ERROR_IF(WaitForSingleObject(process.get(), 3000) == WAIT_FAILED);
  return S_OK;
}

bool TerminateLockingProcesses(const std::vector<DWORD>& processIds, std::wstring& errors) {
  bool ok = true;
  for (const auto pid : processIds) {
    const HRESULT result = TerminateLockingProcess(pid);
    if (FAILED(result)) {
      ok = false;
      errors += L"Could not terminate process " + std::to_wstring(pid) + L": " +
                WindowsErrorMessage(HRESULT_CODE(result)) + L"\n";
    }
  }
  return ok;
}

HRESULT DeleteSelectedFile(const std::wstring& path) noexcept {
  RETURN_IF_WIN32_BOOL_FALSE(DeleteFileW(path.c_str()));
  return S_OK;
}

bool DeleteSelectedFiles(const std::vector<SelectionItem>& selection, std::wstring& errors) {
  bool ok = true;
  for (const auto& path : SelectedFilePaths(selection)) {
    const HRESULT result = DeleteSelectedFile(path);
    if (FAILED(result)) {
      ok = false;
      errors += L"Could not delete " + path + L": " + WindowsErrorMessage(HRESULT_CODE(result)) + L"\n";
    }
  }
  return ok;
}

bool MatchesLeafItem(const ToolItem& item, const std::vector<SelectionItem>& selection) {
  if (selection.empty()) {
    return false;
  }

  for (const auto& selected : selection) {
    if (selected.isDesktopBackground) {
      if (!item.appliesToDesktopBackground) {
        return false;
      }
      continue;
    }

    if (selected.isFolderBackground) {
      if (!item.appliesToFolderBackgrounds) {
        return false;
      }
      continue;
    }

    if (selected.isDirectory) {
      if (!item.appliesToFolders) {
        return false;
      }
      continue;
    }

    if (!item.appliesToFiles) {
      return false;
    }

    const auto extension = ExtensionOf(selected.path);
    if (!item.includeExtensions.empty() && !ContainsExtension(item.includeExtensions, extension)) {
      return false;
    }
    if (ContainsExtension(item.excludeExtensions, extension)) {
      return false;
    }
  }

  return true;
}

bool MatchesCommandItem(const ToolItem& item, const std::vector<SelectionItem>& selection) {
  return !item.command.empty() && MatchesLeafItem(item, selection);
}

bool MatchesActionItem(const ToolItem& item, const std::vector<SelectionItem>& selection) {
  return item.action != ToolAction::ShellExecute && MatchesLeafItem(item, selection);
}

bool MatchesInformationalItem(const ToolItem& item) {
  return item.isInformational;
}

bool MatchesSeparatorItem(const ToolItem& item, const std::vector<SelectionItem>& selection) {
  return item.isSeparator && MatchesLeafItem(item, selection);
}

HRESULT KnownFolderPath(REFKNOWNFOLDERID folderId, std::wstring& path) noexcept {
  try {
    wil::unique_cotaskmem_string value;
    RETURN_IF_FAILED(SHGetKnownFolderPath(folderId, KF_FLAG_DEFAULT, nullptr, value.put()));
    path = value.get();
    return S_OK;
  }
  CATCH_RETURN();
}

std::wstring ConfigPath() {
  std::wstring path;
  KnownFolderPath(FOLDERID_LocalAppData, path);

  if (path.empty()) {
    DWORD needed = GetEnvironmentVariableW(L"LOCALAPPDATA", nullptr, 0);
    if (needed > 1) {
      std::wstring value(needed, L'\0');
      GetEnvironmentVariableW(L"LOCALAPPDATA", value.data(), needed);
      value.resize(wcslen(value.c_str()));
      path = value;
    }
  }

  if (!path.empty() && path.back() != L'\\') {
    path.push_back(L'\\');
  }
  path += L"MyContextMenuTools\\tools.jsonc";
  return path;
}

std::wstring ConfigPathForProfile(const CommandProfile& profile) {
  if (profile.slot == 0) {
    return ConfigPath();
  }

  const auto defaultConfig = ConfigPath();
  const auto slash = defaultConfig.find_last_of(L'\\');
  if (slash == std::wstring::npos) {
    return defaultConfig;
  }

  wchar_t fileName[32]{};
  swprintf_s(fileName, L"slot-%02x.jsonc", profile.slot);
  return JoinPath(JoinPath(defaultConfig.substr(0, slash), L"Extensions"), fileName);
}

std::wstring SnapshotPathForConfig(const std::wstring& configPath) {
  const auto directory = DirectoryName(configPath);
  const auto stem = FileStem(configPath);
  if (directory.empty() || stem.empty()) {
    return L"";
  }
  return JoinPath(directory, stem + L".compiled.json");
}

HRESULT GetFileLastWriteTime(const std::wstring& path, FILETIME& lastWriteTime) noexcept {
  WIN32_FILE_ATTRIBUTE_DATA attributes{};
  RETURN_IF_WIN32_BOOL_FALSE(GetFileAttributesExW(path.c_str(), GetFileExInfoStandard, &attributes));
  lastWriteTime = attributes.ftLastWriteTime;
  return S_OK;
}

bool TryGetFileLastWriteTime(const std::wstring& path, FILETIME& lastWriteTime) {
  return SUCCEEDED(GetFileLastWriteTime(path, lastWriteTime));
}

HRESULT ReadUtf8FileHr(const std::wstring& path, std::wstring& content, FILETIME* lastWriteTime) noexcept {
  try {
    FILETIME fileLastWriteTime{};
    RETURN_IF_FAILED(GetFileLastWriteTime(path, fileLastWriteTime));
    if (lastWriteTime) {
      *lastWriteTime = fileLastWriteTime;
    }

    wil::unique_hfile file(CreateFileW(path.c_str(),
                                       GENERIC_READ,
                                       FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                                       nullptr,
                                       OPEN_EXISTING,
                                       FILE_ATTRIBUTE_NORMAL,
                                       nullptr));
    RETURN_LAST_ERROR_IF(!file);

    LARGE_INTEGER size{};
    RETURN_IF_WIN32_BOOL_FALSE(GetFileSizeEx(file.get(), &size));
    RETURN_HR_IF(HRESULT_FROM_WIN32(ERROR_FILE_TOO_LARGE), size.QuadPart <= 0 || size.QuadPart > 1024 * 1024);

    std::string bytes(static_cast<size_t>(size.QuadPart), '\0');
    DWORD read = 0;
    RETURN_IF_WIN32_BOOL_FALSE(ReadFile(file.get(), bytes.data(), static_cast<DWORD>(bytes.size()), &read, nullptr));
    RETURN_HR_IF(HRESULT_FROM_WIN32(ERROR_READ_FAULT), read != bytes.size());

    if (bytes.size() >= 3 &&
        static_cast<unsigned char>(bytes[0]) == 0xEF &&
        static_cast<unsigned char>(bytes[1]) == 0xBB &&
        static_cast<unsigned char>(bytes[2]) == 0xBF) {
      bytes.erase(0, 3);
    }

    const int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, bytes.data(), static_cast<int>(bytes.size()), nullptr, 0);
    RETURN_LAST_ERROR_IF(length <= 0);

    content.resize(length);
    RETURN_LAST_ERROR_IF(
        MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, bytes.data(), static_cast<int>(bytes.size()), content.data(), length) != length);
    return S_OK;
  }
  CATCH_RETURN();
}

bool ReadUtf8File(const std::wstring& path, std::wstring& content, FILETIME* lastWriteTime) {
  return SUCCEEDED(ReadUtf8FileHr(path, content, lastWriteTime));
}

std::wstring FileTimeSnapshotValue(const FILETIME& time) {
  ULARGE_INTEGER value{};
  value.LowPart = time.dwLowDateTime;
  value.HighPart = time.dwHighDateTime;

  wchar_t text[32]{};
  swprintf_s(text, L"%llu", value.QuadPart);
  return text;
}

bool SourceStampMatches(const SourceStamp& source) {
  FILETIME current{};
  if (!TryGetFileLastWriteTime(source.path, current)) {
    return false;
  }
  return FileTimeSnapshotValue(current) == source.lastWriteTime;
}

bool SourceStampsMatch(const std::vector<SourceStamp>& sources) {
  if (sources.empty()) {
    return false;
  }
  return std::all_of(sources.begin(), sources.end(), SourceStampMatches);
}

std::wstring StripJsonComments(const std::wstring& text) {
  std::wstring output;
  bool inString = false;
  bool escaped = false;

  for (size_t i = 0; i < text.size(); ++i) {
    const wchar_t ch = text[i];
    if (inString) {
      output.push_back(ch);
      if (escaped) {
        escaped = false;
      } else if (ch == L'\\') {
        escaped = true;
      } else if (ch == L'"') {
        inString = false;
      }
      continue;
    }

    if (ch == L'"') {
      inString = true;
      output.push_back(ch);
      continue;
    }

    if (ch == L'/' && i + 1 < text.size() && text[i + 1] == L'/') {
      while (i < text.size() && text[i] != L'\n') {
        ++i;
      }
      if (i < text.size()) {
        output.push_back(text[i]);
      }
      continue;
    }

    if (ch == L'/' && i + 1 < text.size() && text[i + 1] == L'*') {
      i += 2;
      while (i + 1 < text.size() && !(text[i] == L'*' && text[i + 1] == L'/')) {
        if (text[i] == L'\n') {
          output.push_back(L'\n');
        }
        ++i;
      }
      ++i;
      continue;
    }

    output.push_back(ch);
  }

  return output;
}

HRESULT ParseJsonValue(const std::wstring& text, JsonValue& value) noexcept {
  try {
    RuntimeJsonValue parsed{nullptr};
    RETURN_HR_IF(E_INVALIDARG, !RuntimeJsonValue::TryParse(winrt::hstring(text), parsed));
    value = parsed;
    return S_OK;
  }
  CATCH_RETURN();
}

JsonValue JsonProperty(const JsonObject& object, const std::wstring& name) {
  const winrt::hstring key(name);
  return object.HasKey(key) ? object.GetNamedValue(key) : nullptr;
}

std::wstring JsonString(const JsonValue& value) {
  const auto text = value.GetString();
  return {text.c_str(), text.size()};
}

std::wstring StringProperty(const JsonObject& object, const std::wstring& name) {
  const auto value = JsonProperty(object, name);
  return value && value.ValueType() == JsonValueType::String ? JsonString(value) : L"";
}

bool BoolProperty(const JsonObject& object, const std::wstring& name, bool fallback) {
  const auto value = JsonProperty(object, name);
  return value && value.ValueType() == JsonValueType::Boolean ? value.GetBoolean() : fallback;
}

std::vector<std::wstring> StringArrayProperty(const JsonObject& object, const std::wstring& name) {
  std::vector<std::wstring> values;
  const auto value = JsonProperty(object, name);
  if (!value || value.ValueType() != JsonValueType::Array) {
    return values;
  }

  for (const auto& item : value.GetArray()) {
    if (item.ValueType() == JsonValueType::String) {
      auto normalized = ToLower(JsonString(item));
      if (!normalized.empty() && normalized[0] != L'.') {
        normalized.insert(normalized.begin(), L'.');
      }
      values.push_back(normalized);
    }
  }
  return values;
}

std::vector<std::wstring> AppliesToProperty(const JsonObject& object) {
  std::vector<std::wstring> values;
  const auto value = JsonProperty(object, L"appliesTo");
  if (!value) {
    return values;
  }
  if (value.ValueType() == JsonValueType::String) {
    values.push_back(ToLower(JsonString(value)));
  } else if (value.ValueType() == JsonValueType::Array) {
    for (const auto& item : value.GetArray()) {
      if (item.ValueType() == JsonValueType::String) {
        values.push_back(ToLower(JsonString(item)));
      }
    }
  }
  return values;
}

ToolAction ActionProperty(const JsonObject& object) {
  const auto action = ToLower(StringProperty(object, L"action"));
  if (action == L"makebackupfile" || action == L"makebakfile") {
    return ToolAction::MakeBackupFile;
  }
  if (action == L"touchfile" || action == L"touchfiles") {
    return ToolAction::TouchFile;
  }
  if (action == L"copysha256toclipboard" || action == L"copysha256") {
    return ToolAction::CopySha256ToClipboard;
  }
  if (action == L"copylockingprocessids" || action == L"copylockingpids") {
    return ToolAction::CopyLockingProcessIds;
  }
  if (action == L"deleteafterkillinglockingprocesses" || action == L"killlockingprocessesanddelete") {
    return ToolAction::DeleteAfterKillingLockingProcesses;
  }
  return ToolAction::ShellExecute;
}

std::vector<ToolItem> ParseItems(const JsonArray& value, const std::wstring& baseDirectory, int includeDepth);
bool ParseToolItem(const JsonObject& value, const std::wstring& baseDirectory, int includeDepth, ToolItem& item);

std::vector<ToolItem> ParseChildren(const JsonObject& object, const std::wstring& baseDirectory, int includeDepth) {
  const auto children = JsonProperty(object, L"children");
  if (!children || children.ValueType() != JsonValueType::Array) {
    return {};
  }
  return ParseItems(children.GetArray(), baseDirectory, includeDepth);
}

std::vector<std::wstring> IncludePaths(const JsonObject& object) {
  std::vector<std::wstring> paths;
  auto include = JsonProperty(object, L"include");
  if (!include) {
    include = JsonProperty(object, L"$include");
  }
  if (!include) {
    return paths;
  }

  if (include.ValueType() == JsonValueType::String) {
    paths.push_back(JsonString(include));
  } else if (include.ValueType() == JsonValueType::Array) {
    for (const auto& value : include.GetArray()) {
      if (value.ValueType() == JsonValueType::String) {
        paths.push_back(JsonString(value));
      }
    }
  }
  return paths;
}

std::vector<ToolItem> ParseIncludedItems(const std::wstring& includePath, const std::wstring& baseDirectory, int includeDepth) {
  if (includeDepth <= 0) {
    return {};
  }

  const auto path = ResolveConfigRelativePath(includePath, baseDirectory);
  std::wstring json;
  if (!ReadUtf8File(path, json)) {
    return {};
  }

  JsonValue root{nullptr};
  if (FAILED(ParseJsonValue(StripJsonComments(json), root))) {
    return {};
  }

  const auto includeBaseDirectory = DirectoryName(path);
  if (root.ValueType() == JsonValueType::Array) {
    return ParseItems(root.GetArray(), includeBaseDirectory, includeDepth - 1);
  }
  if (root.ValueType() != JsonValueType::Object) {
    return {};
  }

  const auto object = root.GetObject();
  const auto items = JsonProperty(object, L"items");
  if (items && items.ValueType() == JsonValueType::Array) {
    return ParseItems(items.GetArray(), includeBaseDirectory, includeDepth - 1);
  }

  ToolItem item;
  if (ParseToolItem(object, includeBaseDirectory, includeDepth - 1, item)) {
    return {std::move(item)};
  }
  return {};
}

std::vector<ToolItem> ParseItems(const JsonArray& value, const std::wstring& baseDirectory, int includeDepth) {
  std::vector<ToolItem> items;
  for (const auto& child : value) {
    if (child.ValueType() == JsonValueType::Object) {
      const auto object = child.GetObject();
      const auto includePaths = IncludePaths(object);
      if (!includePaths.empty()) {
        for (const auto& includePath : includePaths) {
          auto included = ParseIncludedItems(includePath, baseDirectory, includeDepth);
          items.insert(items.end(), std::make_move_iterator(included.begin()), std::make_move_iterator(included.end()));
        }
        continue;
      }
    }

    ToolItem parsed;
    if (child.ValueType() == JsonValueType::Object &&
        ParseToolItem(child.GetObject(), baseDirectory, includeDepth, parsed)) {
      items.push_back(std::move(parsed));
    }
  }
  return items;
}

bool ParseToolItem(const JsonObject& value, const std::wstring& baseDirectory, int includeDepth, ToolItem& item) {
  ToolItem parsed;
  parsed.id = StringProperty(value, L"id");
  const auto type = ToLower(StringProperty(value, L"type"));
  const bool isConfiguredSeparator = BoolProperty(value, L"separator", false) || type == L"separator" || type == L"divider";
  if (isConfiguredSeparator) {
    return false;
  }
  parsed.title = StringProperty(value, L"title");
  parsed.tooltip = StringProperty(value, L"tooltip");
  parsed.icon = StringProperty(value, L"icon");
  parsed.command = StringProperty(value, L"command");
  parsed.arguments = StringProperty(value, L"arguments");
  parsed.workingDirectory = StringProperty(value, L"workingDirectory");
  parsed.verb = StringProperty(value, L"verb");
  parsed.action = ActionProperty(value);
  parsed.children = ParseChildren(value, baseDirectory, includeDepth);
  parsed.includeExtensions = StringArrayProperty(value, L"includeExtensions");
  parsed.excludeExtensions = StringArrayProperty(value, L"excludeExtensions");

  parsed.appliesToFiles = true;
  parsed.appliesToFolders = parsed.isSeparator;
  parsed.appliesToFolderBackgrounds = false;
  parsed.appliesToDesktopBackground = false;
  const auto appliesTo = AppliesToProperty(value);
  if (!appliesTo.empty()) {
    parsed.appliesToFiles = false;
    parsed.appliesToFolders = false;
    parsed.appliesToFolderBackgrounds = false;
    parsed.appliesToDesktopBackground = false;
    for (const auto& target : appliesTo) {
      if (target == L"files" || target == L"file" || target == L"all") {
        parsed.appliesToFiles = true;
      }
      if (target == L"folders" || target == L"folder" || target == L"directories" || target == L"directory" || target == L"all") {
        parsed.appliesToFolders = true;
      }
      if (target == L"folderbackgrounds" || target == L"folderbackground" || target == L"directorybackgrounds" || target == L"directorybackground" || target == L"backgrounds" || target == L"background" || target == L"all") {
        parsed.appliesToFolderBackgrounds = true;
      }
      if (target == L"desktopbackground" || target == L"desktopbackgrounds" || target == L"desktop" || target == L"backgrounds" || target == L"background" || target == L"all") {
        parsed.appliesToDesktopBackground = true;
      }
    }
  }

  parsed.appliesToFiles = BoolProperty(value, L"files", parsed.appliesToFiles);
  parsed.appliesToFolders = BoolProperty(value, L"folders", parsed.appliesToFolders);
  parsed.appliesToFolderBackgrounds = BoolProperty(value, L"folderBackgrounds", parsed.appliesToFolderBackgrounds);
  parsed.appliesToDesktopBackground = BoolProperty(value, L"desktopBackground", parsed.appliesToDesktopBackground);
  const auto backgrounds = JsonProperty(value, L"backgrounds");
  if (backgrounds && backgrounds.ValueType() == JsonValueType::Boolean && backgrounds.GetBoolean()) {
    parsed.appliesToFolderBackgrounds = true;
    parsed.appliesToDesktopBackground = true;
  }

  if (!parsed.isSeparator && (parsed.title.empty() || (parsed.command.empty() && parsed.children.empty() && parsed.action == ToolAction::ShellExecute))) {
    return false;
  }

  item = std::move(parsed);
  return true;
}

bool ParseConfigRoot(const JsonObject& root, const std::wstring& configPath, int includeDepth, ToolConfig& config) {
  ToolConfig parsed;
  const auto title = StringProperty(root, L"menuTitle");
  if (!title.empty()) {
    parsed.menuTitle = title;
  }
  parsed.menuTooltip = StringProperty(root, L"menuTooltip");
  parsed.menuIcon = StringProperty(root, L"menuIcon");

  const auto items = JsonProperty(root, L"items");
  if (!items || items.ValueType() != JsonValueType::Array) {
    return false;
  }

  parsed.items = ParseItems(items.GetArray(), DirectoryName(configPath), includeDepth);

  config = std::move(parsed);
  return true;
}

bool ParseConfig(const std::wstring& json, const std::wstring& configPath, ToolConfig& config) {
  JsonValue root{nullptr};
  if (FAILED(ParseJsonValue(StripJsonComments(json), root)) || root.ValueType() != JsonValueType::Object) {
    return false;
  }

  return ParseConfigRoot(root.GetObject(), configPath, 8, config);
}

bool ParseCompiledSnapshot(const std::wstring& json,
                           const std::wstring& configPath,
                           ToolConfig& config,
                           std::vector<SourceStamp>& sources) {
  JsonValue root{nullptr};
  if (FAILED(ParseJsonValue(json, root)) || root.ValueType() != JsonValueType::Object) {
    return false;
  }

  const auto object = root.GetObject();
  if (StringProperty(object, L"format") != L"MyContextMenuTools.CompiledConfig.v1") {
    return false;
  }

  const auto sourceValues = JsonProperty(object, L"sources");
  if (!sourceValues || sourceValues.ValueType() != JsonValueType::Array || sourceValues.GetArray().Size() == 0) {
    return false;
  }

  std::vector<SourceStamp> parsedSources;
  for (const auto& value : sourceValues.GetArray()) {
    if (value.ValueType() != JsonValueType::Object) {
      return false;
    }
    const auto sourceObject = value.GetObject();
    SourceStamp source{StringProperty(sourceObject, L"path"), StringProperty(sourceObject, L"lastWriteTime")};
    if (source.path.empty() || source.lastWriteTime.empty() || !SourceStampMatches(source)) {
      return false;
    }
    parsedSources.push_back(std::move(source));
  }

  const auto compiledConfig = JsonProperty(object, L"config");
  if (!compiledConfig || compiledConfig.ValueType() != JsonValueType::Object) {
    return false;
  }

  ToolConfig parsedConfig;
  if (!ParseConfigRoot(compiledConfig.GetObject(), configPath, 0, parsedConfig)) {
    return false;
  }

  config = std::move(parsedConfig);
  sources = std::move(parsedSources);
  return true;
}

bool HasVisibleItems(const ToolItem& item, const std::vector<SelectionItem>& selection) {
  if (MatchesInformationalItem(item)) {
    return true;
  }
  if (MatchesSeparatorItem(item, selection)) {
    return true;
  }
  if (MatchesActionItem(item, selection)) {
    return true;
  }
  if (!item.children.empty()) {
    return std::any_of(item.children.begin(), item.children.end(), [&](const ToolItem& child) {
      return HasVisibleItems(child, selection);
    });
  }
  return MatchesCommandItem(item, selection);
}

void RemoveRedundantSeparators(std::vector<ToolItem>& items) {
  std::vector<ToolItem> compacted;
  compacted.reserve(items.size());
  for (auto& item : items) {
    if (item.isSeparator && (compacted.empty() || compacted.back().isSeparator)) {
      continue;
    }
    compacted.push_back(std::move(item));
  }
  while (!compacted.empty() && compacted.back().isSeparator) {
    compacted.pop_back();
  }
  items = std::move(compacted);
}

std::vector<ToolItem> VisibleItems(const std::vector<ToolItem>& items, const std::vector<SelectionItem>& selection) {
  std::vector<ToolItem> visible;
  for (const auto& item : items) {
    if (HasVisibleItems(item, selection)) {
      visible.push_back(item);
    }
  }
  RemoveRedundantSeparators(visible);
  return visible;
}

void FlattenVisibleLeafItems(const std::vector<ToolItem>& items,
                             const std::vector<SelectionItem>& selection,
                             std::vector<ToolItem>& visible) {
  for (const auto& item : items) {
    if (MatchesInformationalItem(item)) {
      visible.push_back(item);
      continue;
    }

    if (MatchesSeparatorItem(item, selection)) {
      visible.push_back(item);
      continue;
    }

    if (MatchesActionItem(item, selection)) {
      visible.push_back(item);
      continue;
    }

    if (!item.children.empty()) {
      FlattenVisibleLeafItems(item.children, selection, visible);
      continue;
    }

    if (MatchesCommandItem(item, selection)) {
      visible.push_back(item);
    }
  }
}

std::vector<ToolItem> VisibleRootItems(const ToolConfig& config, const std::vector<SelectionItem>& selection) {
  std::vector<ToolItem> visible;
  FlattenVisibleLeafItems(config.items, selection, visible);
  RemoveRedundantSeparators(visible);
  return visible;
}

std::wstring FormatElapsedMilliseconds(std::chrono::steady_clock::duration elapsed) {
  const auto microseconds = std::chrono::duration_cast<std::chrono::microseconds>(elapsed).count();
  const auto wholeMilliseconds = microseconds / 1000;
  const auto tenths = (microseconds % 1000) / 100;

  wchar_t text[64]{};
  swprintf_s(text, L"%lld.%lld ms", wholeMilliseconds, tenths);
  return text;
}

ToolItem LoadTimeItem(const std::wstring& menuTitle, std::chrono::steady_clock::duration elapsed) {
  ToolItem item;
  const auto displayTitle = menuTitle.empty() ? L"Context menu" : menuTitle;
  item.id = L"context-menu-load-time";
  item.title = displayTitle + L" loaded in " + FormatElapsedMilliseconds(elapsed);
  item.tooltip = L"Time from context menu command creation until subcommands were ready.";
  item.isInformational = true;
  item.appliesToFiles = true;
  item.appliesToFolders = true;
  item.appliesToFolderBackgrounds = true;
  item.appliesToDesktopBackground = true;
  return item;
}

ToolItem SmokeCommand(const std::wstring& id, const std::wstring& title) {
  ToolItem item;
  item.id = id;
  item.title = title;
  item.tooltip = L"Hardcoded cascade smoke test command";
  item.command = L"notepad.exe";
  item.arguments = L"%1";
  item.appliesToFiles = true;
  item.appliesToFolders = false;
  return item;
}

std::vector<ToolItem> HardcodedCascadeSmokeItems() {
  ToolItem twoTier = SmokeCommand(L"smoke-2-tier", L"Smoke test: 2-tier command");
  twoTier.icon = L"__default";

  ToolItem threeTier;
  threeTier.id = L"smoke-3-tier";
  threeTier.title = L"Smoke test: 3-tier cascade";
  threeTier.icon = L"__default";
  threeTier.children.push_back(SmokeCommand(L"smoke-3-tier-command", L"Tier 3 command"));

  ToolItem fourTierChild;
  fourTierChild.id = L"smoke-4-tier-level-3";
  fourTierChild.title = L"Tier 3 submenu";
  fourTierChild.icon = L"__default";
  fourTierChild.children.push_back(SmokeCommand(L"smoke-4-tier-command", L"Tier 4 command"));

  ToolItem fourTier;
  fourTier.id = L"smoke-4-tier";
  fourTier.title = L"Smoke test: 4-tier cascade";
  fourTier.icon = L"__default";
  fourTier.children.push_back(std::move(fourTierChild));

  ToolItem iconExe = SmokeCommand(L"smoke-icon-exe", L"Icon smoke: EXE resource");
  iconExe.icon = L"__exe";

  ToolItem iconIco = SmokeCommand(L"smoke-icon-ico", L"Icon smoke: ICO file");
  iconIco.icon = L"__ico";

  ToolItem iconPng = SmokeCommand(L"smoke-icon-png", L"Icon smoke: PNG file");
  iconPng.icon = L"__png";

  ToolItem iconSvg = SmokeCommand(L"smoke-icon-svg", L"Icon smoke: SVG file");
  iconSvg.icon = L"__svg";

  return {std::move(twoTier), std::move(threeTier), std::move(fourTier), std::move(iconExe), std::move(iconIco), std::move(iconPng), std::move(iconSvg)};
}

std::vector<ToolItem> RootMenuItemsForSelection(const ToolConfig& config, const std::vector<SelectionItem>& selection) {
  std::vector<ToolItem> visible;

  // Uncomment while diagnosing Windows 11 cascade and icon rendering behavior.
  // visible = VisibleItems(HardcodedCascadeSmokeItems(), selection);

  auto jsonItems = VisibleRootItems(config, selection);
  visible.insert(visible.end(), std::make_move_iterator(jsonItems.begin()), std::make_move_iterator(jsonItems.end()));
  return visible;
}

class ConfigCache {
 public:
  ToolConfig Get(const std::wstring& path = ConfigPath()) {
    std::lock_guard<std::mutex> guard(mutex_);
    auto& entry = entries_[path];

    if (entry.loaded && SourceStampsMatch(entry.sources)) {
      return entry.config;
    }

    const auto snapshotPath = SnapshotPathForConfig(path);
    if (!snapshotPath.empty()) {
      std::wstring snapshotJson;
      ToolConfig snapshotConfig;
      std::vector<SourceStamp> snapshotSources;
      if (ReadUtf8File(snapshotPath, snapshotJson) && ParseCompiledSnapshot(snapshotJson, path, snapshotConfig, snapshotSources)) {
        entry.config = std::move(snapshotConfig);
        entry.sources = std::move(snapshotSources);
        entry.loaded = true;
        return entry.config;
      }
    }

    FILETIME lastWriteTime{};
    if (!TryGetFileLastWriteTime(path, lastWriteTime)) {
      entry.loaded = true;
      entry.sources.clear();
      entry.config = {};
      return entry.config;
    }

    std::wstring json;
    if (!ReadUtf8File(path, json)) {
      entry.loaded = true;
      entry.sources.clear();
      entry.config = {};
      return entry.config;
    }

    ToolConfig parsed;
    if (ParseConfig(json, path, parsed)) {
      entry.config = std::move(parsed);
    } else {
      entry.config = {};
    }
    entry.sources = {{path, FileTimeSnapshotValue(lastWriteTime)}};
    entry.loaded = true;
    return entry.config;
  }

 private:
  struct Entry {
    bool loaded = false;
    std::vector<SourceStamp> sources;
    ToolConfig config;
  };

  std::mutex mutex_;
  std::map<std::wstring, Entry> entries_;
};

ConfigCache& Cache() {
  static ConfigCache cache;
  return cache;
}

HRESULT GetSelectionItem(IShellItemArray* items, DWORD index, SelectionItem& selection) noexcept {
  try {
    winrt::com_ptr<IShellItem> item;
    RETURN_IF_FAILED(items->GetItemAt(index, item.put()));

    wil::unique_cotaskmem_string path;
    RETURN_IF_FAILED(item->GetDisplayName(SIGDN_FILESYSPATH, path.put()));

    const DWORD attributes = GetFileAttributesW(path.get());
    selection = {path.get(), attributes != INVALID_FILE_ATTRIBUTES && (attributes & FILE_ATTRIBUTE_DIRECTORY)};
    return S_OK;
  }
  CATCH_RETURN();
}

HRESULT GetSelectionHr(IShellItemArray* items, std::vector<SelectionItem>& selection) noexcept {
  try {
    if (!items) {
      return S_OK;
    }

    DWORD count = 0;
    RETURN_IF_FAILED(items->GetCount(&count));
    for (DWORD i = 0; i < count; ++i) {
      SelectionItem item;
      if (SUCCEEDED(GetSelectionItem(items, i, item))) {
        selection.push_back(std::move(item));
      }
    }
    return S_OK;
  }
  CATCH_RETURN();
}

std::vector<SelectionItem> GetSelection(IShellItemArray* items) {
  std::vector<SelectionItem> selection;
  LOG_IF_FAILED(GetSelectionHr(items, selection));
  return selection;
}

HRESULT GetFolderViewPath(IUnknown* site, std::wstring& path) noexcept {
  try {
  path.clear();
  if (!site) {
      return E_NOINTERFACE;
  }

    winrt::com_ptr<IServiceProvider> serviceProvider;
    RETURN_IF_FAILED(site->QueryInterface(__uuidof(IServiceProvider), serviceProvider.put_void()));

    winrt::com_ptr<IFolderView> folderView;
    RETURN_IF_FAILED(serviceProvider->QueryService(SID_SFolderView, __uuidof(IFolderView), folderView.put_void()));

    winrt::com_ptr<IPersistFolder2> folder;
    RETURN_IF_FAILED(folderView->GetFolder(__uuidof(IPersistFolder2), folder.put_void()));

    wil::unique_cotaskmem folderIdList;
    RETURN_IF_FAILED(folder->GetCurFolder(reinterpret_cast<PIDLIST_ABSOLUTE*>(folderIdList.put())));

    winrt::com_ptr<IShellItem> folderItem;
    RETURN_IF_FAILED(SHCreateItemFromIDList(
        static_cast<PCIDLIST_ABSOLUTE>(folderIdList.get()), __uuidof(IShellItem), folderItem.put_void()));

    wil::unique_cotaskmem_string folderPath;
    RETURN_IF_FAILED(folderItem->GetDisplayName(SIGDN_FILESYSPATH, folderPath.put()));
    path = folderPath.get();
    RETURN_HR_IF(E_FAIL, path.empty());
    return S_OK;
  }
  CATCH_RETURN();
}

bool TryGetFolderViewPath(IUnknown* site, std::wstring& path) {
  return SUCCEEDED(GetFolderViewPath(site, path));
}

std::wstring DesktopPath() {
  std::wstring path;
  KnownFolderPath(FOLDERID_Desktop, path);
  return path;
}

std::vector<SelectionItem> GetSelectionForContext(IShellItemArray* items,
                                                  CommandContext context,
                                                  const std::wstring& backgroundPath = L"") {
  auto selection = GetSelection(items);
  if (context == CommandContext::Selection) {
    return selection;
  }

  const auto desktop = DesktopPath();
  if (selection.empty() && !backgroundPath.empty()) {
    selection.push_back({backgroundPath, true});
  } else if (selection.empty() && context == CommandContext::DesktopBackground) {
    if (!desktop.empty()) {
      selection.push_back({desktop, true});
    }
  }

  for (auto& item : selection) {
    const bool isDesktop = !desktop.empty() && ToLower(item.path) == ToLower(desktop);
    item.isDirectory = true;
    item.isFolderBackground = context == CommandContext::FolderBackground && !isDesktop;
    item.isDesktopBackground = context == CommandContext::DesktopBackground || isDesktop;
  }
  return selection;
}

class ToolExplorerCommand
    : public winrt::implements<ToolExplorerCommand,
                              IExplorerCommand,
                              winrt::non_agile,
                              winrt::no_weak_ref,
                              winrt::no_module_lock> {
 public:
  ToolExplorerCommand(ToolItem item, std::vector<SelectionItem> selection, CommandContext context)
      : item_(std::move(item)), selection_(std::move(selection)), context_(context) {
    InterlockedIncrement(&g_objectCount);
  }

  ~ToolExplorerCommand() {
    InterlockedDecrement(&g_objectCount);
  }

  IFACEMETHODIMP GetTitle(IShellItemArray*, PWSTR* name) override {
    try {
      if (item_.action == ToolAction::CopyLockingProcessIds) {
        const auto processIds = LockingProcessIds(selection_);
        const auto suffix = processIds.empty() ? L"none detected" : JoinProcessIds(processIds);
        return DuplicateString(ExpandCommandText(item_.title, item_, selection_, false) + L": " + suffix, name);
      }
      return DuplicateString(ExpandCommandText(item_.title, item_, selection_, false), name);
    }
    CATCH_RETURN();
  }

  IFACEMETHODIMP GetIcon(IShellItemArray*, PWSTR* icon) override {
    RETURN_HR_IF_NULL(E_POINTER, icon);
    try {
      if (item_.isSeparator || item_.isInformational) {
        *icon = nullptr;
        return E_NOTIMPL;
      }
      const auto resolved = ResolveIconPath(item_.icon);
      if (resolved.empty()) {
        *icon = nullptr;
        return E_NOTIMPL;
      }
      return DuplicateString(resolved, icon);
    }
    CATCH_RETURN();
  }

  IFACEMETHODIMP GetToolTip(IShellItemArray*, PWSTR* infoTip) override {
    RETURN_HR_IF_NULL(E_POINTER, infoTip);
    try {
      if (item_.isSeparator || item_.tooltip.empty()) {
        *infoTip = nullptr;
        return E_NOTIMPL;
      }
      return DuplicateString(ExpandCommandText(item_.tooltip, item_, selection_, false), infoTip);
    }
    CATCH_RETURN();
  }

  IFACEMETHODIMP GetCanonicalName(GUID* guidCommandName) override {
    RETURN_HR_IF_NULL(E_POINTER, guidCommandName);
    *guidCommandName = GUID_NULL;
    return S_OK;
  }

  IFACEMETHODIMP GetState(IShellItemArray* items, BOOL, EXPCMDSTATE* cmdState) override {
    RETURN_HR_IF_NULL(E_POINTER, cmdState);
    try {
      auto selection = GetSelectionForContext(items, context_);
      if (selection.empty()) {
        selection = selection_;
      }
      if (item_.isInformational) {
        *cmdState = ECS_DISABLED;
      } else {
        *cmdState = HasVisibleItems(item_, selection) ? ECS_ENABLED : ECS_HIDDEN;
      }
      return S_OK;
    }
    CATCH_RETURN();
  }

  IFACEMETHODIMP GetFlags(EXPCMDFLAGS* flags) override {
    RETURN_HR_IF_NULL(E_POINTER, flags);
    if (item_.isSeparator) {
      *flags = ECF_ISSEPARATOR;
    } else {
      *flags = item_.children.empty() ? ECF_DEFAULT : ECF_HASSUBCOMMANDS;
    }
    return S_OK;
  }

  IFACEMETHODIMP EnumSubCommands(IEnumExplorerCommand** enumCommands) override;

  IFACEMETHODIMP Invoke(IShellItemArray* items, IBindCtx*) override {
    try {
      if (item_.isSeparator || item_.isInformational || !item_.children.empty()) {
        return S_OK;
      }

      auto selection = GetSelectionForContext(items, context_);
      if (selection.empty()) {
        selection = selection_;
      }
      if (!MatchesCommandItem(item_, selection) && !MatchesActionItem(item_, selection)) {
        RETURN_HR(E_FAIL);
      }

      if (item_.action == ToolAction::CopyLockingProcessIds) {
        const auto processIds = LockingProcessIds(selection);
        const auto text = processIds.empty() ? L"No locking process detected." : JoinProcessIds(processIds);
        return CopyTextToClipboard(text);
      }

      if (item_.action == ToolAction::MakeBackupFile) {
        std::wstring errors;
        if (!MakeBackupFiles(selection, errors)) {
          MessageBoxW(nullptr, errors.c_str(), L"Make .bak file", MB_ICONERROR | MB_OK);
          RETURN_HR(E_FAIL);
        }
        return S_OK;
      }

      if (item_.action == ToolAction::TouchFile) {
        std::wstring errors;
        if (!TouchFiles(selection, errors)) {
          MessageBoxW(nullptr, errors.c_str(), L"Touch file", MB_ICONERROR | MB_OK);
          RETURN_HR(E_FAIL);
        }
        return S_OK;
      }

      if (item_.action == ToolAction::CopySha256ToClipboard) {
        std::wstring errors;
        const HRESULT result = CopySha256ToClipboard(selection, errors);
        if (FAILED(result)) {
          if (errors.empty()) {
            errors = L"Could not copy the SHA-256 hash to the clipboard: " + WindowsErrorMessage(HRESULT_CODE(result));
          }
          MessageBoxW(nullptr, errors.c_str(), L"Copy SHA-256 to clipboard", MB_ICONERROR | MB_OK);
        }
        return result;
      }

      if (item_.action == ToolAction::DeleteAfterKillingLockingProcesses) {
        const auto paths = SelectedFilePaths(selection);
        if (paths.empty()) {
          RETURN_HR(E_FAIL);
        }

        const auto processIds = LockingProcessIds(selection);
        std::wstring prompt;
        if (processIds.empty()) {
          prompt = L"No locking process was detected. Delete the selected file(s)?";
        } else {
          prompt = L"Kill locking process ID(s) " + JoinProcessIds(processIds) + L" and delete the selected file(s)?";
        }
        if (MessageBoxW(nullptr, prompt.c_str(), L"Super Delete", MB_ICONWARNING | MB_YESNO | MB_DEFBUTTON2) != IDYES) {
          return HRESULT_FROM_WIN32(ERROR_CANCELLED);
        }

        std::wstring errors;
        if (!processIds.empty()) {
          TerminateLockingProcesses(processIds, errors);
        }
        Sleep(300);
        DeleteSelectedFiles(selection, errors);
        if (!errors.empty()) {
          MessageBoxW(nullptr, errors.c_str(), L"Super Delete", MB_ICONERROR | MB_OK);
          RETURN_HR(E_FAIL);
        }
        return S_OK;
      }

      const auto parameters = ExpandCommandText(item_.arguments, item_, selection, true);
      const auto workingDirectory = ExpandCommandText(item_.workingDirectory, item_, selection, false);

      SHELLEXECUTEINFOW executeInfo{};
      executeInfo.cbSize = sizeof(executeInfo);
      executeInfo.fMask = SEE_MASK_NOCLOSEPROCESS;
      const auto command = ExpandEnvironmentPath(item_.command);
      executeInfo.lpVerb = item_.verb.empty() ? nullptr : item_.verb.c_str();
      executeInfo.lpFile = command.c_str();
      executeInfo.lpParameters = parameters.empty() ? nullptr : parameters.c_str();
      executeInfo.lpDirectory = workingDirectory.empty() ? nullptr : workingDirectory.c_str();
      executeInfo.nShow = SW_SHOWNORMAL;

      RETURN_IF_WIN32_BOOL_FALSE(ShellExecuteExW(&executeInfo));
      wil::unique_process_handle process(executeInfo.hProcess);
      return S_OK;
    }
    CATCH_RETURN();
  }

 private:
  ToolItem item_;
  std::vector<SelectionItem> selection_;
  CommandContext context_;
};

class ToolCommandEnumerator
    : public winrt::implements<ToolCommandEnumerator,
                              IEnumExplorerCommand,
                              winrt::non_agile,
                              winrt::no_weak_ref,
                              winrt::no_module_lock> {
 public:
  ToolCommandEnumerator(std::vector<ToolItem> items, std::vector<SelectionItem> selection, CommandContext context)
      : items_(std::move(items)), selection_(std::move(selection)), context_(context) {
    InterlockedIncrement(&g_objectCount);
  }

  ~ToolCommandEnumerator() {
    InterlockedDecrement(&g_objectCount);
  }

  IFACEMETHODIMP Next(ULONG count, IExplorerCommand** commands, ULONG* fetched) override {
    RETURN_HR_IF(E_POINTER, !commands || (count > 1 && !fetched));
    for (ULONG i = 0; i < count; ++i) {
      commands[i] = nullptr;
    }

    try {
      ULONG created = 0;
      while (created < count && index_ < items_.size()) {
        auto command = winrt::make_self<ToolExplorerCommand>(items_[index_], selection_, context_);
        commands[created] = command.as<IExplorerCommand>().detach();
        ++created;
        ++index_;
      }

      if (fetched) {
        *fetched = created;
      }
      return created == count ? S_OK : S_FALSE;
    }
    CATCH_RETURN();
  }

  IFACEMETHODIMP Skip(ULONG count) override {
    index_ = std::min(index_ + count, items_.size());
    return index_ < items_.size() ? S_OK : S_FALSE;
  }

  IFACEMETHODIMP Reset() override {
    index_ = 0;
    return S_OK;
  }

  IFACEMETHODIMP Clone(IEnumExplorerCommand** enumCommands) override {
    RETURN_HR_IF_NULL(E_POINTER, enumCommands);
    *enumCommands = nullptr;
    try {
      auto clone = winrt::make_self<ToolCommandEnumerator>(items_, selection_, context_);
      clone->index_ = index_;
      *enumCommands = clone.as<IEnumExplorerCommand>().detach();
      return S_OK;
    }
    CATCH_RETURN();
  }

 private:
  std::vector<ToolItem> items_;
  std::vector<SelectionItem> selection_;
  CommandContext context_;
  size_t index_ = 0;
};

IFACEMETHODIMP ToolExplorerCommand::EnumSubCommands(IEnumExplorerCommand** enumCommands) {
  RETURN_HR_IF_NULL(E_POINTER, enumCommands);
  *enumCommands = nullptr;
  try {
    const auto visible = VisibleItems(item_.children, selection_);
    if (visible.empty()) {
      return S_FALSE;
    }
    auto enumerator = winrt::make_self<ToolCommandEnumerator>(visible, selection_, context_);
    *enumCommands = enumerator.as<IEnumExplorerCommand>().detach();
    return S_OK;
  }
  CATCH_RETURN();
}

class RootExplorerCommand
    : public winrt::implements<RootExplorerCommand,
                              IExplorerCommand,
                              IObjectWithSite,
                              winrt::non_agile,
                              winrt::no_weak_ref,
                              winrt::no_module_lock> {
 public:
  explicit RootExplorerCommand(CommandProfile profile)
      : profile_(profile),
        configPath_(ConfigPathForProfile(profile)),
        loadStarted_(std::chrono::steady_clock::now()) {
    InterlockedIncrement(&g_objectCount);
  }

  ~RootExplorerCommand() {
    InterlockedDecrement(&g_objectCount);
  }

  IFACEMETHODIMP GetTitle(IShellItemArray*, PWSTR* name) override {
    try {
      return DuplicateString(Cache().Get(configPath_).menuTitle, name);
    }
    CATCH_RETURN();
  }

  IFACEMETHODIMP GetIcon(IShellItemArray*, PWSTR* icon) override {
    RETURN_HR_IF_NULL(E_POINTER, icon);
    try {
      const auto config = Cache().Get(configPath_);
      const auto resolved = ResolveIconPath(config.menuIcon);
      if (resolved.empty()) {
        *icon = nullptr;
        return E_NOTIMPL;
      }
      return DuplicateString(resolved, icon);
    }
    CATCH_RETURN();
  }

  IFACEMETHODIMP GetToolTip(IShellItemArray*, PWSTR* infoTip) override {
    RETURN_HR_IF_NULL(E_POINTER, infoTip);
    try {
      const auto tooltip = Cache().Get(configPath_).menuTooltip;
      if (tooltip.empty()) {
        *infoTip = nullptr;
        return E_NOTIMPL;
      }
      return DuplicateString(tooltip, infoTip);
    }
    CATCH_RETURN();
  }

  IFACEMETHODIMP GetCanonicalName(GUID* guidCommandName) override {
    RETURN_HR_IF_NULL(E_POINTER, guidCommandName);
    *guidCommandName = profile_.classId;
    return S_OK;
  }

  IFACEMETHODIMP GetState(IShellItemArray* items, BOOL, EXPCMDSTATE* cmdState) override {
    RETURN_HR_IF_NULL(E_POINTER, cmdState);
    try {
      std::wstring backgroundPath;
      if (profile_.context != CommandContext::Selection) {
        TryGetFolderViewPath(site_.get(), backgroundPath);
      }
      lastSelection_ = GetSelectionForContext(items, profile_.context, backgroundPath);
      Cache().Get(configPath_);
      *cmdState = ECS_ENABLED;
      return S_OK;
    }
    CATCH_RETURN();
  }

  IFACEMETHODIMP GetFlags(EXPCMDFLAGS* flags) override {
    RETURN_HR_IF_NULL(E_POINTER, flags);
    *flags = ECF_HASSUBCOMMANDS;
    return S_OK;
  }

  IFACEMETHODIMP EnumSubCommands(IEnumExplorerCommand** enumCommands) override {
    RETURN_HR_IF_NULL(E_POINTER, enumCommands);
    *enumCommands = nullptr;
    try {
      if (lastSelection_.empty() && profile_.context != CommandContext::Selection) {
        std::wstring backgroundPath;
        if (TryGetFolderViewPath(site_.get(), backgroundPath)) {
          lastSelection_ = GetSelectionForContext(nullptr, profile_.context, backgroundPath);
        }
      }
      const auto config = Cache().Get(configPath_);
      auto visible = RootMenuItemsForSelection(config, lastSelection_);
#if MYTOOLS_SHOW_PERFORMANCE_VERB
      visible.push_back(LoadTimeItem(config.menuTitle, std::chrono::steady_clock::now() - loadStarted_));
#endif
      auto enumerator = winrt::make_self<ToolCommandEnumerator>(visible, lastSelection_, profile_.context);
      *enumCommands = enumerator.as<IEnumExplorerCommand>().detach();
      return S_OK;
    }
    CATCH_RETURN();
  }

  IFACEMETHODIMP Invoke(IShellItemArray*, IBindCtx*) override {
    return S_OK;
  }

  IFACEMETHODIMP SetSite(IUnknown* site) override {
    site_.copy_from(site);
    return S_OK;
  }

  IFACEMETHODIMP GetSite(REFIID riid, void** site) override {
    RETURN_HR_IF_NULL(E_POINTER, site);
    *site = nullptr;
    if (!site_) {
      return E_NOINTERFACE;
    }
    return static_cast<HRESULT>(site_.as(riid, site));
  }

 private:
  CommandProfile profile_;
  std::wstring configPath_;
  std::vector<SelectionItem> lastSelection_;
  std::chrono::steady_clock::time_point loadStarted_;
  winrt::com_ptr<IUnknown> site_;
};

class ClassFactory
    : public winrt::implements<ClassFactory,
                              IClassFactory,
                              winrt::non_agile,
                              winrt::no_weak_ref,
                              winrt::no_module_lock> {
 public:
  explicit ClassFactory(CommandProfile profile) : profile_(profile) {}

  IFACEMETHODIMP CreateInstance(IUnknown* outer, REFIID riid, void** object) override {
    RETURN_HR_IF(CLASS_E_NOAGGREGATION, outer != nullptr);
    RETURN_HR_IF_NULL(E_POINTER, object);
    *object = nullptr;
    try {
      auto command = winrt::make_self<RootExplorerCommand>(profile_);
      return static_cast<HRESULT>(command.as(riid, object));
    }
    CATCH_RETURN();
  }

  IFACEMETHODIMP LockServer(BOOL lock) override {
    if (lock) {
      InterlockedIncrement(&g_lockCount);
    } else {
      InterlockedDecrement(&g_lockCount);
    }
    return S_OK;
  }

 private:
  CommandProfile profile_;
};

}  // namespace

BOOL APIENTRY DllMain(HINSTANCE instance, DWORD reason, LPVOID reserved) {
  wil::DLLMain(instance, reason, reserved);
  if (reason == DLL_PROCESS_ATTACH) {
    g_module = instance;
    DisableThreadLibraryCalls(instance);
    wil::g_fResultOutputDebugString = true;
    TraceLoggingRegister(g_traceProvider);
    wil::SetResultLoggingCallback(LogWilFailure);
  } else if (reason == DLL_PROCESS_DETACH) {
    wil::SetResultLoggingCallback(nullptr);
    TraceLoggingUnregister(g_traceProvider);
  }
  return TRUE;
}

STDAPI DllGetClassObject(REFCLSID classId, REFIID interfaceId, void** object) {
  RETURN_HR_IF_NULL(E_POINTER, object);
  *object = nullptr;
  CommandProfile profile;
  profile.classId = classId;
  if (IsEqualCLSID(classId, CLSID_MyContextMenuToolsFolderBackground)) {
    profile.context = CommandContext::FolderBackground;
  } else if (IsEqualCLSID(classId, CLSID_MyContextMenuToolsDesktopBackground)) {
    profile.context = CommandContext::DesktopBackground;
  } else if (!IsEqualCLSID(classId, CLSID_MyContextMenuTools)) {
    const bool isDynamicProfile =
        classId.Data1 == CLSID_MyContextMenuTools.Data1 &&
        classId.Data2 == CLSID_MyContextMenuTools.Data2 &&
        classId.Data3 == CLSID_MyContextMenuTools.Data3 &&
        classId.Data4[0] == CLSID_MyContextMenuTools.Data4[0] &&
        classId.Data4[1] == CLSID_MyContextMenuTools.Data4[1] &&
        classId.Data4[2] == CLSID_MyContextMenuTools.Data4[2] &&
        classId.Data4[3] == CLSID_MyContextMenuTools.Data4[3] &&
        classId.Data4[4] == CLSID_MyContextMenuTools.Data4[4] &&
        classId.Data4[5] == CLSID_MyContextMenuTools.Data4[5] &&
        classId.Data4[6] != CLSID_MyContextMenuTools.Data4[6] &&
        (classId.Data4[7] == kDynamicContextSelection || classId.Data4[7] == kDynamicContextFolderBackground);
    if (!isDynamicProfile) {
      return CLASS_E_CLASSNOTAVAILABLE;
    }
    profile.slot = classId.Data4[6];
    profile.context = classId.Data4[7] == kDynamicContextFolderBackground ? CommandContext::FolderBackground : CommandContext::Selection;
  }

  try {
    auto factory = winrt::make_self<ClassFactory>(profile);
    return static_cast<HRESULT>(factory.as(interfaceId, object));
  }
  CATCH_RETURN();
}

STDAPI DllCanUnloadNow() {
  return g_objectCount == 0 && g_lockCount == 0 ? S_OK : S_FALSE;
}
