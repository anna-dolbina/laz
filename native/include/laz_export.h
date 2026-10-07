// Copyright (c) 2026 Vladyslav Lubenskyi
// Licensed under the MIT License. See LICENSE file in the project root for full license information.

#ifndef LAZ_EXPORT_H
#define LAZ_EXPORT_H

// Export and calling-convention decorations for the public C ABI.
// On Windows, functions are exported explicitly and use __stdcall.
// On macOS and Linux, all non-static symbols are exported and the default convention is used.
#if defined(_WIN32)
    #define LAZ_EXPORT __declspec(dllexport)
    #define LAZ_CALL __stdcall
#else
    #define LAZ_EXPORT
    #define LAZ_CALL
#endif

#endif // LAZ_EXPORT_H
