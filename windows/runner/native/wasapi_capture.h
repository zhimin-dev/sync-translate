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
WASAPI_CAPTURE_API int wasapi_start(int mode, void** out_handle);

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

#ifdef __cplusplus
}
#endif
