// Copyright (c) 2026 Vladyslav Lubenskyi
// Licensed under the MIT License. See LICENSE file in the project root for full license information.

// Accessibility tree on top of the AXUIElement API.
//
// The tree has a synthetic root, the desktop. Its children are the applications that have windows,
// ordered front to back. Everything below an application comes from AX.
//
// AX calls are made on the calling thread; the API does not need the main thread. Inspecting the
// current process works only while its main run loop is running, because AX delivers requests
// there.
//
// This file uses manual reference counting: every AXUIElementRef stored in a handle is retained by
// the handle and released in lazA11yRelease().

#include <ApplicationServices/ApplicationServices.h>
#import <AppKit/AppKit.h>
#include <dispatch/dispatch.h>

#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

#include "laz_api.h"

namespace {

constexpr float kDefaultTimeoutSeconds = 5.0f;

enum StringSlot {
  STR_ROLE,
  STR_SUBROLE,
  STR_NAME,
  STR_VALUE,
  STR_DESCRIPTION,
  STR_IDENTIFIER,
  STR_COUNT
};

enum ElementKind { KIND_DESKTOP, KIND_AX };

// The indices of the attributes read in one batch by fillInfo().
enum AttributeIndex {
  ATTR_ROLE,
  ATTR_SUBROLE,
  ATTR_TITLE,
  ATTR_DESCRIPTION,
  ATTR_VALUE,
  ATTR_HELP,
  ATTR_IDENTIFIER,
  ATTR_POSITION,
  ATTR_SIZE,
  ATTR_ENABLED,
  ATTR_FOCUSED,
  ATTR_SELECTED,
  ATTR_EXPANDED,
  ATTR_DISCLOSING,
  ATTR_MODAL,
  ATTR_MAIN,
  ATTR_MINIMIZED,
  ATTR_FRONTMOST,
  ATTR_HIDDEN,
  ATTR_TITLE_ELEMENT,
  ATTR_COUNT
};

}  // namespace

struct LazA11yElement {
  ElementKind kind;
  // Retained. NULL for the desktop.
  AXUIElementRef element;
  LazA11yInfo info;
  // UTF-8 strings referenced from `info`. Owned.
  char* strings[STR_COUNT];
};

namespace {

std::atomic<float> g_timeoutSeconds{kDefaultTimeoutSeconds};

AXUIElementRef systemWide() {
  static AXUIElementRef element = nullptr;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    element = AXUIElementCreateSystemWide();
    AXUIElementSetMessagingTimeout(element, g_timeoutSeconds.load());
  });
  return element;
}

int mapAxError(AXError error) {
  switch (error) {
    case kAXErrorSuccess:
      return LAZ_A11Y_OK;
    case kAXErrorAPIDisabled:
      return LAZ_A11Y_E_ACCESS_DENIED;
    case kAXErrorInvalidUIElement:
    case kAXErrorInvalidUIElementObserver:
      return LAZ_A11Y_E_ELEMENT_GONE;
    case kAXErrorCannotComplete:
      return LAZ_A11Y_E_TIMEOUT;
    case kAXErrorNoValue:
    case kAXErrorAttributeUnsupported:
    case kAXErrorNotImplemented:
      return LAZ_A11Y_E_NOT_FOUND;
    case kAXErrorIllegalArgument:
      return LAZ_A11Y_E_INVALID_ARG;
    default:
      return LAZ_A11Y_E_INTERNAL;
  }
}

int checkTrusted() {
  return AXIsProcessTrusted() ? LAZ_A11Y_OK : LAZ_A11Y_E_ACCESS_DENIED;
}

// ============================================================================
// Conversions
// ============================================================================

char* copyUtf8(CFStringRef string) {
  if (string == nullptr) {
    return nullptr;
  }
  CFIndex length = CFStringGetLength(string);
  if (length == 0) {
    return nullptr;
  }
  CFIndex size = CFStringGetMaximumSizeForEncoding(length, kCFStringEncodingUTF8) + 1;
  char* buffer = static_cast<char*>(malloc(static_cast<size_t>(size)));
  if (buffer == nullptr) {
    return nullptr;
  }
  if (!CFStringGetCString(string, buffer, size, kCFStringEncodingUTF8)) {
    free(buffer);
    return nullptr;
  }
  return buffer;
}

char* duplicate(const char* text) {
  return text != nullptr ? strdup(text) : nullptr;
}

// Returns the value at `index` of the batch, or NULL if the attribute is missing.
// Missing attributes are reported as AXValues of type kAXValueAXErrorType.
CFTypeRef batchValue(CFArrayRef values, AttributeIndex index) {
  if (values == nullptr || index >= CFArrayGetCount(values)) {
    return nullptr;
  }
  CFTypeRef value = CFArrayGetValueAtIndex(values, index);
  if (value == nullptr || CFGetTypeID(value) == CFNullGetTypeID()) {
    return nullptr;
  }
  if (CFGetTypeID(value) == AXValueGetTypeID() &&
      AXValueGetType(static_cast<AXValueRef>(value)) == kAXValueTypeAXError) {
    return nullptr;
  }
  return value;
}

// Returns the AXError reported for a missing attribute, or kAXErrorSuccess if it is present.
AXError batchError(CFArrayRef values, AttributeIndex index) {
  if (values == nullptr || index >= CFArrayGetCount(values)) {
    return kAXErrorFailure;
  }
  CFTypeRef value = CFArrayGetValueAtIndex(values, index);
  if (value != nullptr && CFGetTypeID(value) == AXValueGetTypeID() &&
      AXValueGetType(static_cast<AXValueRef>(value)) == kAXValueTypeAXError) {
    AXError error = kAXErrorSuccess;
    AXValueGetValue(static_cast<AXValueRef>(value), kAXValueTypeAXError, &error);
    return error;
  }
  return kAXErrorSuccess;
}

CFStringRef asString(CFTypeRef value) {
  if (value != nullptr && CFGetTypeID(value) == CFStringGetTypeID()) {
    return static_cast<CFStringRef>(value);
  }
  return nullptr;
}

// Returns 1 for true, 0 for false, -1 if the value is not a boolean.
int asBool(CFTypeRef value) {
  if (value == nullptr) {
    return -1;
  }
  if (CFGetTypeID(value) == CFBooleanGetTypeID()) {
    return CFBooleanGetValue(static_cast<CFBooleanRef>(value)) ? 1 : 0;
  }
  if (CFGetTypeID(value) == CFNumberGetTypeID()) {
    int number = 0;
    CFNumberGetValue(static_cast<CFNumberRef>(value), kCFNumberIntType, &number);
    return number != 0 ? 1 : 0;
  }
  return -1;
}

// Converts an AXValue attribute value to text. Numbers are formatted without trailing zeros.
char* stringifyValue(CFTypeRef value) {
  if (value == nullptr) {
    return nullptr;
  }
  CFTypeID type = CFGetTypeID(value);
  if (type == CFStringGetTypeID()) {
    return copyUtf8(static_cast<CFStringRef>(value));
  }
  if (type == CFAttributedStringGetTypeID()) {
    return copyUtf8(CFAttributedStringGetString(static_cast<CFAttributedStringRef>(value)));
  }
  if (type == CFBooleanGetTypeID()) {
    return strdup(CFBooleanGetValue(static_cast<CFBooleanRef>(value)) ? "true" : "false");
  }
  if (type == CFNumberGetTypeID()) {
    double number = 0;
    CFNumberGetValue(static_cast<CFNumberRef>(value), kCFNumberDoubleType, &number);
    char buffer[64];
    int written = snprintf(buffer, sizeof(buffer), "%g", number);
    return written > 0 ? strdup(buffer) : nullptr;
  }
  if (type == CFURLGetTypeID()) {
    return copyUtf8(CFURLGetString(static_cast<CFURLRef>(value)));
  }
  return nullptr;
}

// ============================================================================
// Handles
// ============================================================================

void clearStrings(LazA11yElement* handle) {
  for (int i = 0; i < STR_COUNT; ++i) {
    free(handle->strings[i]);
    handle->strings[i] = nullptr;
  }
}

void resetInfo(LazA11yElement* handle) {
  clearStrings(handle);
  memset(&handle->info, 0, sizeof(handle->info));
  handle->info.structSize = static_cast<int32_t>(sizeof(handle->info));
  handle->info.rawRoleId = -1;
  handle->info.childCountHint = -1;
}

void publishStrings(LazA11yElement* handle) {
  LazA11yInfo* info = &handle->info;
  info->rawRole = handle->strings[STR_ROLE];
  info->rawSubrole = handle->strings[STR_SUBROLE];
  info->name = handle->strings[STR_NAME];
  info->value = handle->strings[STR_VALUE];
  info->description = handle->strings[STR_DESCRIPTION];
  info->automationId = handle->strings[STR_IDENTIFIER];
  info->className = nullptr;
}

void destroyHandle(LazA11yElement* handle) {
  if (handle == nullptr) {
    return;
  }
  if (handle->element != nullptr) {
    CFRelease(handle->element);
  }
  clearStrings(handle);
  free(handle);
}

// The union of all active displays, in global top-left-origin points.
CGRect desktopBounds() {
  uint32_t count = 0;
  if (CGGetActiveDisplayList(0, nullptr, &count) != kCGErrorSuccess || count == 0) {
    return CGRectNull;
  }
  std::vector<CGDirectDisplayID> displays(count);
  if (CGGetActiveDisplayList(count, displays.data(), &count) != kCGErrorSuccess) {
    return CGRectNull;
  }
  CGRect bounds = CGRectNull;
  for (uint32_t i = 0; i < count; ++i) {
    bounds = CGRectUnion(bounds, CGDisplayBounds(displays[i]));
  }
  return bounds;
}

void fillDesktopInfo(LazA11yElement* handle) {
  resetInfo(handle);
  handle->strings[STR_ROLE] = strdup("AXSystemWide");
  handle->strings[STR_NAME] = strdup("Desktop");
  CGRect bounds = desktopBounds();
  if (!CGRectIsNull(bounds)) {
    handle->info.x = static_cast<int32_t>(lround(bounds.origin.x));
    handle->info.y = static_cast<int32_t>(lround(bounds.origin.y));
    handle->info.width = static_cast<int32_t>(lround(bounds.size.width));
    handle->info.height = static_cast<int32_t>(lround(bounds.size.height));
    handle->info.boundsKind = LAZ_A11Y_BOUNDS_SCREEN;
  }
  handle->info.states = LAZ_A11Y_STATE_ENABLED;
  publishStrings(handle);
}

pid_t focusedApplicationPid() {
  CFTypeRef app = nullptr;
  pid_t pid = 0;
  if (AXUIElementCopyAttributeValue(systemWide(), kAXFocusedApplicationAttribute, &app) ==
          kAXErrorSuccess &&
      app != nullptr) {
    if (CFGetTypeID(app) == AXUIElementGetTypeID()) {
      AXUIElementGetPid(static_cast<AXUIElementRef>(app), &pid);
    }
    CFRelease(app);
  }
  return pid;
}

// Reads the name from the element that serves as the title, e.g. the label next to a text field.
char* titleFromTitleElement(CFTypeRef titleElement) {
  if (titleElement == nullptr || CFGetTypeID(titleElement) != AXUIElementGetTypeID()) {
    return nullptr;
  }
  auto element = static_cast<AXUIElementRef>(titleElement);
  char* result = nullptr;
  CFTypeRef value = nullptr;
  if (AXUIElementCopyAttributeValue(element, kAXValueAttribute, &value) == kAXErrorSuccess) {
    result = stringifyValue(value);
    CFRelease(value);
  }
  if (result == nullptr &&
      AXUIElementCopyAttributeValue(element, kAXTitleAttribute, &value) == kAXErrorSuccess) {
    result = copyUtf8(asString(value));
    CFRelease(value);
  }
  return result;
}

bool isAttributeSettable(AXUIElementRef element, CFStringRef attribute) {
  Boolean settable = false;
  return AXUIElementIsAttributeSettable(element, attribute, &settable) == kAXErrorSuccess &&
         settable;
}

bool roleIs(const char* role, const char* expected) {
  return role != nullptr && strcmp(role, expected) == 0;
}

// Reads the attributes of handle->element into handle->info in one batch.
int fillAxInfo(LazA11yElement* handle) {
  AXUIElementRef element = handle->element;

  // The order must match AttributeIndex.
  const void* names[ATTR_COUNT] = {
      kAXRoleAttribute,       kAXSubroleAttribute,    kAXTitleAttribute,
      kAXDescriptionAttribute, kAXValueAttribute,      kAXHelpAttribute,
      kAXIdentifierAttribute, kAXPositionAttribute,   kAXSizeAttribute,
      kAXEnabledAttribute,    kAXFocusedAttribute,    kAXSelectedAttribute,
      kAXExpandedAttribute,   kAXDisclosingAttribute, kAXModalAttribute,
      kAXMainAttribute,       kAXMinimizedAttribute,  kAXFrontmostAttribute,
      kAXHiddenAttribute,     kAXTitleUIElementAttribute,
  };
  CFArrayRef attributes = CFArrayCreate(kCFAllocatorDefault, names, ATTR_COUNT,
                                        &kCFTypeArrayCallBacks);
  if (attributes == nullptr) {
    return LAZ_A11Y_E_OUT_OF_MEMORY;
  }

  CFArrayRef values = nullptr;
  AXError error = AXUIElementCopyMultipleAttributeValues(element, attributes, 0, &values);
  CFRelease(attributes);
  if (error != kAXErrorSuccess) {
    return mapAxError(error);
  }

  // Every live element has a role. Without one, the element is gone.
  CFStringRef role = asString(batchValue(values, ATTR_ROLE));
  if (role == nullptr) {
    AXError roleError = batchError(values, ATTR_ROLE);
    CFRelease(values);
    int result = mapAxError(roleError);
    return result == LAZ_A11Y_OK || result == LAZ_A11Y_E_NOT_FOUND ? LAZ_A11Y_E_ELEMENT_GONE
                                                                   : result;
  }

  resetInfo(handle);
  LazA11yInfo* info = &handle->info;
  handle->strings[STR_ROLE] = copyUtf8(role);
  handle->strings[STR_SUBROLE] = copyUtf8(asString(batchValue(values, ATTR_SUBROLE)));
  handle->strings[STR_IDENTIFIER] = copyUtf8(asString(batchValue(values, ATTR_IDENTIFIER)));
  const char* roleText = handle->strings[STR_ROLE];
  const char* subroleText = handle->strings[STR_SUBROLE];

  CFTypeRef rawValue = batchValue(values, ATTR_VALUE);
  handle->strings[STR_VALUE] = stringifyValue(rawValue);

  // Name: the title, then the title element, then the description. Static text keeps its text in
  // the value, so the value serves as the name, as on other platforms.
  char* title = copyUtf8(asString(batchValue(values, ATTR_TITLE)));
  char* description = copyUtf8(asString(batchValue(values, ATTR_DESCRIPTION)));
  char* help = copyUtf8(asString(batchValue(values, ATTR_HELP)));
  if (title == nullptr) {
    title = titleFromTitleElement(batchValue(values, ATTR_TITLE_ELEMENT));
  }
  if (title == nullptr && roleIs(roleText, "AXStaticText")) {
    title = duplicate(handle->strings[STR_VALUE]);
  }
  if (title == nullptr && description != nullptr) {
    title = description;
    description = nullptr;
  }
  handle->strings[STR_NAME] = title;
  if (description != nullptr) {
    handle->strings[STR_DESCRIPTION] = description;
    free(help);
  } else {
    handle->strings[STR_DESCRIPTION] = help;
  }

  // Bounds.
  CGPoint position = CGPointZero;
  CGSize size = CGSizeZero;
  CFTypeRef positionValue = batchValue(values, ATTR_POSITION);
  CFTypeRef sizeValue = batchValue(values, ATTR_SIZE);
  if (positionValue != nullptr && sizeValue != nullptr &&
      CFGetTypeID(positionValue) == AXValueGetTypeID() &&
      CFGetTypeID(sizeValue) == AXValueGetTypeID() &&
      AXValueGetValue(static_cast<AXValueRef>(positionValue), kAXValueTypeCGPoint, &position) &&
      AXValueGetValue(static_cast<AXValueRef>(sizeValue), kAXValueTypeCGSize, &size) &&
      size.width > 0 && size.height > 0) {
    info->x = static_cast<int32_t>(lround(position.x));
    info->y = static_cast<int32_t>(lround(position.y));
    info->width = static_cast<int32_t>(lround(size.width));
    info->height = static_cast<int32_t>(lround(size.height));
    info->boundsKind = LAZ_A11Y_BOUNDS_SCREEN;
  } else {
    info->boundsKind = LAZ_A11Y_BOUNDS_NONE;
  }

  // States.
  uint32_t states = 0;
  // Many elements, such as windows and static text, do not report AXEnabled. They are enabled.
  if (asBool(batchValue(values, ATTR_ENABLED)) != 0) {
    states |= LAZ_A11Y_STATE_ENABLED;
  }
  if (asBool(batchValue(values, ATTR_FOCUSED)) == 1) {
    states |= LAZ_A11Y_STATE_FOCUSED;
  }
  if (asBool(batchValue(values, ATTR_SELECTED)) == 1) {
    states |= LAZ_A11Y_STATE_SELECTED;
  }
  int expanded = asBool(batchValue(values, ATTR_EXPANDED));
  if (expanded < 0) {
    expanded = asBool(batchValue(values, ATTR_DISCLOSING));
  }
  if (expanded == 1) {
    states |= LAZ_A11Y_STATE_EXPANDED;
  } else if (expanded == 0) {
    states |= LAZ_A11Y_STATE_COLLAPSED;
  }
  if (asBool(batchValue(values, ATTR_MODAL)) == 1) {
    states |= LAZ_A11Y_STATE_MODAL;
  }
  if (roleIs(subroleText, "AXSecureTextField")) {
    states |= LAZ_A11Y_STATE_PASSWORD;
  }

  // Check boxes and radio buttons report 0, 1, or 2 (mixed) in AXValue.
  if ((roleIs(roleText, "AXCheckBox") || roleIs(roleText, "AXRadioButton")) &&
      rawValue != nullptr && CFGetTypeID(rawValue) == CFNumberGetTypeID()) {
    int checked = 0;
    CFNumberGetValue(static_cast<CFNumberRef>(rawValue), kCFNumberIntType, &checked);
    if (checked == 1) {
      states |= LAZ_A11Y_STATE_CHECKED;
    } else if (checked == 2) {
      states |= LAZ_A11Y_STATE_MIXED;
    }
  }

  // AX has no offscreen state. Minimized windows, hidden applications, and elements outside of
  // every display are offscreen.
  if (asBool(batchValue(values, ATTR_MINIMIZED)) == 1 ||
      asBool(batchValue(values, ATTR_HIDDEN)) == 1) {
    states |= LAZ_A11Y_STATE_OFFSCREEN;
  } else if (info->boundsKind == LAZ_A11Y_BOUNDS_SCREEN) {
    CGRect desktop = desktopBounds();
    CGRect rect = CGRectMake(info->x, info->y, info->width, info->height);
    if (!CGRectIsNull(desktop) && !CGRectIntersectsRect(desktop, rect)) {
      states |= LAZ_A11Y_STATE_OFFSCREEN;
    }
  }

  pid_t pid = 0;
  AXUIElementGetPid(element, &pid);
  info->processId = static_cast<int32_t>(pid);

  // An application is active when it is frontmost; a window when it is the main window of the
  // focused application.
  if (asBool(batchValue(values, ATTR_FRONTMOST)) == 1) {
    states |= LAZ_A11Y_STATE_ACTIVE;
  } else if (asBool(batchValue(values, ATTR_MAIN)) == 1 && pid == focusedApplicationPid()) {
    states |= LAZ_A11Y_STATE_ACTIVE;
  }

  // These need extra requests, so they are read only for the roles they apply to.
  bool isText = roleIs(roleText, "AXTextField") || roleIs(roleText, "AXTextArea") ||
                roleIs(roleText, "AXComboBox");
  if (isText && !isAttributeSettable(element, kAXValueAttribute)) {
    states |= LAZ_A11Y_STATE_READONLY;
  }
  if ((states & LAZ_A11Y_STATE_FOCUSED) != 0 ||
      isAttributeSettable(element, kAXFocusedAttribute)) {
    states |= LAZ_A11Y_STATE_FOCUSABLE;
  }

  info->states = states;
  CFRelease(values);
  publishStrings(handle);
  return LAZ_A11Y_OK;
}

int fillInfo(LazA11yElement* handle) {
  @autoreleasepool {
    if (handle->kind == KIND_DESKTOP) {
      fillDesktopInfo(handle);
      return LAZ_A11Y_OK;
    }
    return fillAxInfo(handle);
  }
}

LazA11yElement* allocateHandle(ElementKind kind, AXUIElementRef element) {
  auto handle = static_cast<LazA11yElement*>(calloc(1, sizeof(LazA11yElement)));
  if (handle != nullptr) {
    handle->kind = kind;
    handle->element = element;
  }
  return handle;
}

// Wraps an AX element. Takes ownership of `element` and releases it on failure.
int wrapElement(AXUIElementRef element, LazA11yElement** out) {
  if (element == nullptr) {
    return LAZ_A11Y_E_NOT_FOUND;
  }
  LazA11yElement* handle = allocateHandle(KIND_AX, element);
  if (handle == nullptr) {
    CFRelease(element);
    return LAZ_A11Y_E_OUT_OF_MEMORY;
  }
  int result = fillInfo(handle);
  if (result != LAZ_A11Y_OK) {
    destroyHandle(handle);
    return result;
  }
  *out = handle;
  return LAZ_A11Y_OK;
}

int createDesktop(LazA11yElement** out) {
  LazA11yElement* handle = allocateHandle(KIND_DESKTOP, nullptr);
  if (handle == nullptr) {
    return LAZ_A11Y_E_OUT_OF_MEMORY;
  }
  fillInfo(handle);
  *out = handle;
  return LAZ_A11Y_OK;
}

// Copies an element-valued attribute and wraps it.
int wrapAttribute(AXUIElementRef element, CFStringRef attribute, LazA11yElement** out) {
  CFTypeRef value = nullptr;
  AXError error = AXUIElementCopyAttributeValue(element, attribute, &value);
  if (error != kAXErrorSuccess) {
    return mapAxError(error);
  }
  if (value == nullptr || CFGetTypeID(value) != AXUIElementGetTypeID()) {
    if (value != nullptr) {
      CFRelease(value);
    }
    return LAZ_A11Y_E_NOT_FOUND;
  }
  return wrapElement(static_cast<AXUIElementRef>(value), out);
}

// ============================================================================
// Children
// ============================================================================

class HandleList {
 public:
  ~HandleList() {
    for (LazA11yElement* handle : handles_) {
      destroyHandle(handle);
    }
  }

  void add(LazA11yElement* handle) { handles_.push_back(handle); }

  // Moves the handles to a malloc'ed array owned by the caller.
  int release(LazA11yElement*** outArray, int* outCount) {
    if (handles_.empty()) {
      return LAZ_A11Y_OK;
    }
    auto array =
        static_cast<LazA11yElement**>(malloc(handles_.size() * sizeof(LazA11yElement*)));
    if (array == nullptr) {
      return LAZ_A11Y_E_OUT_OF_MEMORY;
    }
    memcpy(array, handles_.data(), handles_.size() * sizeof(LazA11yElement*));
    *outArray = array;
    *outCount = static_cast<int>(handles_.size());
    handles_.clear();
    return LAZ_A11Y_OK;
  }

 private:
  std::vector<LazA11yElement*> handles_;
};

// The PIDs of applications to list under the desktop: those with on-screen windows in
// front-to-back order, then other regular applications, e.g. those with only minimized windows.
std::vector<pid_t> applicationPids() {
  std::vector<pid_t> pids;
  auto addPid = [&pids](pid_t pid) {
    for (pid_t existing : pids) {
      if (existing == pid) {
        return;
      }
    }
    pids.push_back(pid);
  };

  CFArrayRef windows = CGWindowListCopyWindowInfo(
      kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID);
  if (windows != nullptr) {
    CFIndex count = CFArrayGetCount(windows);
    for (CFIndex i = 0; i < count; ++i) {
      auto window = static_cast<CFDictionaryRef>(CFArrayGetValueAtIndex(windows, i));
      auto layer = static_cast<CFNumberRef>(CFDictionaryGetValue(window, kCGWindowLayer));
      auto owner = static_cast<CFNumberRef>(CFDictionaryGetValue(window, kCGWindowOwnerPID));
      int layerValue = 0;
      int pid = 0;
      // Layer 0 holds application windows; higher layers hold the menu bar, Dock, and overlays.
      if (layer != nullptr && owner != nullptr &&
          CFNumberGetValue(layer, kCFNumberIntType, &layerValue) && layerValue == 0 &&
          CFNumberGetValue(owner, kCFNumberIntType, &pid)) {
        addPid(static_cast<pid_t>(pid));
      }
    }
    CFRelease(windows);
  }

  for (NSRunningApplication* app in [[NSWorkspace sharedWorkspace] runningApplications]) {
    if (app.activationPolicy == NSApplicationActivationPolicyRegular && !app.terminated) {
      addPid(app.processIdentifier);
    }
  }
  return pids;
}

int getDesktopChildren(HandleList* list) {
  @autoreleasepool {
    for (pid_t pid : applicationPids()) {
      AXUIElementRef app = AXUIElementCreateApplication(pid);
      if (app == nullptr) {
        continue;
      }
      LazA11yElement* handle = nullptr;
      int result = wrapElement(app, &handle);
      if (result == LAZ_A11Y_OK) {
        list->add(handle);
      } else if (result == LAZ_A11Y_E_ACCESS_DENIED || result == LAZ_A11Y_E_OUT_OF_MEMORY) {
        return result;
      }
      // Other errors mean the application exited or does not support accessibility: skip it.
    }
  }
  return LAZ_A11Y_OK;
}

CFArrayRef copyElementArray(AXUIElementRef element, CFStringRef attribute, AXError* error) {
  CFTypeRef value = nullptr;
  *error = AXUIElementCopyAttributeValue(element, attribute, &value);
  if (*error != kAXErrorSuccess || value == nullptr) {
    return nullptr;
  }
  if (CFGetTypeID(value) != CFArrayGetTypeID()) {
    CFRelease(value);
    return nullptr;
  }
  return static_cast<CFArrayRef>(value);
}

int getAxChildren(LazA11yElement* parent, HandleList* list) {
  AXError error = kAXErrorSuccess;
  CFArrayRef children = copyElementArray(parent->element, kAXChildrenAttribute, &error);
  // Some applications list their windows only in AXWindows.
  if ((children == nullptr || CFArrayGetCount(children) == 0) &&
      roleIs(parent->info.rawRole, "AXApplication")) {
    if (children != nullptr) {
      CFRelease(children);
    }
    children = copyElementArray(parent->element, kAXWindowsAttribute, &error);
  }

  if (children == nullptr) {
    int result = mapAxError(error);
    // An element without children reports no value or an unsupported attribute.
    return result == LAZ_A11Y_E_NOT_FOUND ? LAZ_A11Y_OK : result;
  }

  int result = LAZ_A11Y_OK;
  CFIndex count = CFArrayGetCount(children);
  for (CFIndex i = 0; i < count; ++i) {
    CFTypeRef child = CFArrayGetValueAtIndex(children, i);
    if (child == nullptr || CFGetTypeID(child) != AXUIElementGetTypeID()) {
      continue;
    }
    CFRetain(child);
    LazA11yElement* handle = nullptr;
    int childResult = wrapElement(static_cast<AXUIElementRef>(child), &handle);
    if (childResult == LAZ_A11Y_OK) {
      list->add(handle);
    } else if (childResult != LAZ_A11Y_E_ELEMENT_GONE && childResult != LAZ_A11Y_E_NOT_FOUND) {
      // A child that vanished in the meantime is skipped; other errors fail the call.
      result = childResult;
      break;
    }
  }
  CFRelease(children);
  return result;
}

}  // namespace

// ============================================================================
// Public API
// ============================================================================

int lazA11yIsAvailable(bool prompt) {
  @autoreleasepool {
    if (!prompt) {
      return checkTrusted();
    }
    const void* keys[] = {kAXTrustedCheckOptionPrompt};
    const void* values[] = {kCFBooleanTrue};
    CFDictionaryRef options =
        CFDictionaryCreate(kCFAllocatorDefault, keys, values, 1, &kCFTypeDictionaryKeyCallBacks,
                           &kCFTypeDictionaryValueCallBacks);
    bool trusted = AXIsProcessTrustedWithOptions(options);
    if (options != nullptr) {
      CFRelease(options);
    }
    return trusted ? LAZ_A11Y_OK : LAZ_A11Y_E_ACCESS_DENIED;
  }
}

int lazA11ySetTimeout(int milliseconds) {
  if (milliseconds <= 0) {
    return LAZ_A11Y_E_INVALID_ARG;
  }
  float seconds = static_cast<float>(milliseconds) / 1000.0f;
  g_timeoutSeconds.store(seconds);
  // A timeout set on the system-wide element applies to all elements.
  return mapAxError(AXUIElementSetMessagingTimeout(systemWide(), seconds));
}

int lazA11yGetRoot(LazA11yElement** out) {
  if (out == nullptr) {
    return LAZ_A11Y_E_INVALID_ARG;
  }
  *out = nullptr;
  int result = checkTrusted();
  return result == LAZ_A11Y_OK ? createDesktop(out) : result;
}

int lazA11yGetFocused(LazA11yElement** out) {
  if (out == nullptr) {
    return LAZ_A11Y_E_INVALID_ARG;
  }
  *out = nullptr;
  int result = checkTrusted();
  if (result != LAZ_A11Y_OK) {
    return result;
  }
  return wrapAttribute(systemWide(), kAXFocusedUIElementAttribute, out);
}

int lazA11yElementFromPoint(int x, int y, LazA11yElement** out) {
  if (out == nullptr) {
    return LAZ_A11Y_E_INVALID_ARG;
  }
  *out = nullptr;
  int result = checkTrusted();
  if (result != LAZ_A11Y_OK) {
    return result;
  }
  AXUIElementRef element = nullptr;
  AXError error = AXUIElementCopyElementAtPosition(systemWide(), static_cast<float>(x),
                                                   static_cast<float>(y), &element);
  if (error != kAXErrorSuccess) {
    return mapAxError(error);
  }
  return wrapElement(element, out);
}

int lazA11yGetParent(LazA11yElement* element, LazA11yElement** out) {
  if (element == nullptr || out == nullptr) {
    return LAZ_A11Y_E_INVALID_ARG;
  }
  *out = nullptr;
  if (element->kind == KIND_DESKTOP) {
    return LAZ_A11Y_E_NOT_FOUND;
  }
  // Applications are the children of the synthetic desktop.
  if (roleIs(element->info.rawRole, "AXApplication")) {
    return createDesktop(out);
  }
  int result = wrapAttribute(element->element, kAXParentAttribute, out);
  // An element without a parent other than an application should not exist; attach it to the
  // desktop rather than leave it orphaned.
  return result == LAZ_A11Y_E_NOT_FOUND ? createDesktop(out) : result;
}

int lazA11yGetChildren(LazA11yElement* element, LazA11yElement*** outArray, int* outCount) {
  if (element == nullptr || outArray == nullptr || outCount == nullptr) {
    return LAZ_A11Y_E_INVALID_ARG;
  }
  *outArray = nullptr;
  *outCount = 0;

  HandleList list;
  int result = element->kind == KIND_DESKTOP ? getDesktopChildren(&list)
                                             : getAxChildren(element, &list);
  if (result != LAZ_A11Y_OK) {
    return result;
  }
  return list.release(outArray, outCount);
}

void lazA11yFreeElementArray(LazA11yElement** array) {
  free(array);
}

int lazA11yGetInfo(LazA11yElement* element, LazA11yInfo* info) {
  if (element == nullptr || info == nullptr ||
      info->structSize < static_cast<int32_t>(sizeof(LazA11yInfo))) {
    return LAZ_A11Y_E_INVALID_ARG;
  }
  *info = element->info;
  return LAZ_A11Y_OK;
}

int lazA11yRefresh(LazA11yElement* element) {
  if (element == nullptr) {
    return LAZ_A11Y_E_INVALID_ARG;
  }
  return fillInfo(element);
}

int lazA11yIsSameElement(LazA11yElement* a, LazA11yElement* b, bool* out) {
  if (a == nullptr || b == nullptr || out == nullptr) {
    return LAZ_A11Y_E_INVALID_ARG;
  }
  if (a->kind == KIND_DESKTOP || b->kind == KIND_DESKTOP) {
    *out = a->kind == b->kind;
  } else {
    *out = CFEqual(a->element, b->element);
  }
  return LAZ_A11Y_OK;
}

int lazA11yCloneHandle(LazA11yElement* element, LazA11yElement** out) {
  if (element == nullptr || out == nullptr) {
    return LAZ_A11Y_E_INVALID_ARG;
  }
  *out = nullptr;
  LazA11yElement* clone = allocateHandle(element->kind, element->element);
  if (clone == nullptr) {
    return LAZ_A11Y_E_OUT_OF_MEMORY;
  }
  if (clone->element != nullptr) {
    CFRetain(clone->element);
  }
  // Copy the snapshot instead of reading it again, so cloning needs no request to the application.
  clone->info = element->info;
  for (int i = 0; i < STR_COUNT; ++i) {
    clone->strings[i] = duplicate(element->strings[i]);
  }
  publishStrings(clone);
  *out = clone;
  return LAZ_A11Y_OK;
}

void lazA11yRelease(LazA11yElement* element) {
  destroyHandle(element);
}
