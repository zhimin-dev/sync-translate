// C API exported by wasapi_capture.dll, consumed from Dart via dart:ffi.
#pragma once

#include <stdint.h>

#ifdef WASAPI_CAPTURE_EXPORTS
#define WASAPI_CAPTURE_API __declspec(dllexport)
#else
#define WASAPI_CAPTURE_API __declspec(dllimport)
#endif

#ifdef __cplusplus
extern "C" {
#endif

// Capture modes.
enum {
  WASAPI_MODE_SYSTEM = 0,  // loopback of the default render device
  WASAPI_MODE_MIC = 1,     // default capture (microphone) device
};

// Starts capture. On success returns 0 and stores an opaque handle in *out_handle.
// The captured stream is converted to mono float32 at the device mix rate.
// Uses the default endpoint (with fallback to any active device).
WASAPI_CAPTURE_API int wasapi_start(int mode, void** out_handle);

// Starts capture on the endpoint whose friendly name matches device_name
// (UTF-8, case-insensitive). Empty/NULL device_name behaves like wasapi_start.
// Returns 0 on success, negative on error (device not found => -10).
WASAPI_CAPTURE_API int wasapi_start_on_device(int mode, const char* device_name,
                                              void** out_handle);

// Lists active endpoint friendly names (UTF-8), one per line.
// Returns NULL on failure; see wasapi_last_error().
// The returned pointer is valid until the next call; copy it immediately.
WASAPI_CAPTURE_API const char* wasapi_list_devices(int mode);

// Frees the buffer returned by wasapi_list_devices (no-op, kept for symmetry).
WASAPI_CAPTURE_API void wasapi_free_string(const char* s);

// Reads up to max_frames mono float32 samples into out.
// If out is NULL this is an info probe: only *frames_read (0) and
// *sample_rate are written and 0 is returned.
// Otherwise blocks at most ~200 ms waiting for data; writes the number of
// frames read into *frames_read and the native sample rate into *sample_rate.
// Returns 0 on success, -1 on bad arguments, -2 if the capture thread died
// (e.g. default device removed). Check wasapi_last_error() for details.
WASAPI_CAPTURE_API int wasapi_read(void* handle, float* out, int max_frames,
                                   int* frames_read, int* sample_rate);

// Stops capture and releases the handle.
WASAPI_CAPTURE_API void wasapi_stop(void* handle);

// Returns a pointer to a static buffer describing the last error.
// Valid until the next error occurs; copy it immediately.
WASAPI_CAPTURE_API const char* wasapi_last_error(void);

// Spawns a hidden background process from a full command line
// (CREATE_NO_WINDOW | DETACHED_PROCESS). Returns the new process id (> 0),
// or 0 on failure (see wasapi_last_error). Used to auto-start the local
// model servers from the app.
WASAPI_CAPTURE_API int st_spawn_hidden(const char* cmdline);

#ifdef __cplusplus
}
#endif
