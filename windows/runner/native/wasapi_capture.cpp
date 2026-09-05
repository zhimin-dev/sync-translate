// WASAPI loopback / microphone capture for the sync-translate Windows runner.
//
// Pipeline: device mix format -> downmix to mono float32 -> SPSC ring buffer
//           -> polled from Dart via wasapi_read().
//
// Loopback capture needs no special permission on Windows. Microphone capture
// respects the app's microphone privacy setting (the app is automatically
// offered to the user by Windows on first capture attempt).

#include "wasapi_capture.h"

#include <windows.h>  // 必须最先包含：avrt.h / audioclient.h 依赖其中的类型

#include <audioclient.h>
#include <avrt.h>
#include <ksmedia.h>
#include <mmdeviceapi.h>

#include <atomic>
#include <cstdio>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "ring_buffer.h"

namespace {

std::mutex g_error_mutex;
std::string g_last_error;

void set_error(const std::string& msg) {
  std::lock_guard<std::mutex> lock(g_error_mutex);
  g_last_error = msg;
}

std::string hresult_to_string(HRESULT hr) {
  char buf[32];
  std::snprintf(buf, sizeof(buf), "0x%08lX", static_cast<unsigned long>(hr));
  return std::string(buf);
}

constexpr REFERENCE_TIME kBufferDuration100ms = 100000;  // 100-ns units

class WasapiCapture {
 public:
  WasapiCapture() = default;
  ~WasapiCapture() { Stop(); }

  int Start(int mode) {
    Stop();
    mode_ = mode;

    HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    if (FAILED(hr)) {
      if (hr == RPC_E_CHANGED_MODE) {
        // Thread already lives in a different apartment; COM is usable as-is.
        com_initialized_ = false;
      } else {
        set_error("CoInitializeEx failed: " + hresult_to_string(hr));
        return -1;
      }
    } else {
      com_initialized_ = true;  // Covers S_OK and S_FALSE (both increment refcount).
    }

    hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                          __uuidof(IMMDeviceEnumerator),
                          reinterpret_cast<void**>(&enumerator_));
    if (FAILED(hr)) {
      set_error("CoCreateInstance(MMDeviceEnumerator) failed: " +
                hresult_to_string(hr));
      CleanupCom();
      return -2;
    }

    const EDataFlow flow = (mode_ == WASAPI_MODE_SYSTEM) ? eRender : eCapture;
    hr = enumerator_->GetDefaultAudioEndpoint(flow, eConsole, &device_);
    if (FAILED(hr)) {
      // 默认端点不可用（例如被拔出/禁用）时，回退到任一活动设备
      std::string msg = (mode_ == WASAPI_MODE_SYSTEM)
                            ? "GetDefaultAudioEndpoint(eRender) failed: "
                            : "GetDefaultAudioEndpoint(eCapture) failed: ";
      IMMDeviceCollection* collection = nullptr;
      hr = enumerator_->EnumAudioEndpoints(flow, DEVICE_STATE_ACTIVE,
                                           &collection);
      if (SUCCEEDED(hr)) {
        UINT count = 0;
        collection->GetCount(&count);
        if (count > 0) {
          hr = collection->Item(0, &device_);
          msg += hresult_to_string(hr) + "；已回退到活动设备（共 " +
                 std::to_string(count) + " 个）";
        } else {
          hr = HRESULT_FROM_WIN32(ERROR_NOT_FOUND);
          msg += hresult_to_string(hr) + "；且无任何活动设备";
        }
        collection->Release();
      }
      if (FAILED(hr)) {
        set_error(msg);
        CleanupCom();
        return -3;
      }
      set_error(msg);  // 回退成功，记录提示
    }

    hr = device_->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                           reinterpret_cast<void**>(&audio_client_));
    if (FAILED(hr)) {
      set_error("device->Activate(IAudioClient) failed: " +
                hresult_to_string(hr));
      CleanupCom();
      return -4;
    }

    WAVEFORMATEX* mix_format = nullptr;
    hr = audio_client_->GetMixFormat(&mix_format);
    if (FAILED(hr) || mix_format == nullptr) {
      set_error("GetMixFormat failed: " + hresult_to_string(hr));
      CleanupCom();
      return -5;
    }
    sample_rate_ = mix_format->nSamplesPerSec;
    channels_ = mix_format->nChannels;
    is_float_ = false;
    if (mix_format->wFormatTag == WAVE_FORMAT_IEEE_FLOAT) {
      is_float_ = true;
    } else if (mix_format->wFormatTag == WAVE_FORMAT_EXTENSIBLE) {
      const auto* ext = reinterpret_cast<const WAVEFORMATEXTENSIBLE*>(mix_format);
      is_float_ = (ext->SubFormat == KSDATAFORMAT_SUBTYPE_IEEE_FLOAT);
    }
    if (sample_rate_ <= 0 || channels_ <= 0) {
      set_error("Invalid mix format");
      CoTaskMemFree(mix_format);
      CleanupCom();
      return -6;
    }

    // Shared mode requires the engine's own mix format.
    const DWORD stream_flags =
        (mode_ == WASAPI_MODE_SYSTEM) ? AUDCLNT_STREAMFLAGS_LOOPBACK : 0;
    hr = audio_client_->Initialize(AUDCLNT_SHAREMODE_SHARED, stream_flags,
                                   kBufferDuration100ms, 0, mix_format,
                                   nullptr);
    CoTaskMemFree(mix_format);
    if (FAILED(hr)) {
      set_error("IAudioClient::Initialize failed: " + hresult_to_string(hr));
      CleanupCom();
      return -7;
    }

    hr = audio_client_->GetService(__uuidof(IAudioCaptureClient),
                                   reinterpret_cast<void**>(&capture_client_));
    if (FAILED(hr)) {
      set_error("GetService(IAudioCaptureClient) failed: " +
                hresult_to_string(hr));
      CleanupCom();
      return -8;
    }

    // Ring buffer holds 8 seconds of mono float audio.
    ring_ = std::make_unique<FloatRingBuffer>(
        static_cast<size_t>(sample_rate_) * 8);
    mono_scratch_.resize(0);

    hr = audio_client_->Start();
    if (FAILED(hr)) {
      set_error("IAudioClient::Start failed: " + hresult_to_string(hr));
      CleanupCom();
      return -9;
    }

    running_.store(true);
    thread_ = std::thread([this] { CaptureLoop(); });
    return 0;
  }

  int Read(float* out, int max_frames, int* frames_read, int* sample_rate) {
    if (frames_read != nullptr) *frames_read = 0;
    if (sample_rate != nullptr) *sample_rate = sample_rate_;
    if (out == nullptr) return 0;  // info probe (sample rate only)
    if (max_frames <= 0 || frames_read == nullptr) return -1;
    if (!running_.load()) {
      return -2;  // capture thread died (device unplugged, etc.)
    }
    // Wait briefly for fresh data so the Dart side can use a relaxed poll.
    int waited_ms = 0;
    while (ring_ != nullptr && ring_->available() == 0 && running_.load() &&
           waited_ms < 200) {
      Sleep(2);
      waited_ms += 2;
    }
    if (ring_ == nullptr) return -2;
    *frames_read = static_cast<int>(ring_->read(out, max_frames));
    return 0;
  }

  void Stop() {
    if (!running_.load() && thread_.get_id() == std::thread::id()) return;
    running_.store(false);
    if (thread_.joinable()) thread_.join();
    if (audio_client_ != nullptr && capture_client_ != nullptr) {
      audio_client_->Stop();
    }
    CleanupCom();
  }

 private:
  void CaptureLoop() {
    const HRESULT coinit_hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    if (FAILED(coinit_hr) && coinit_hr != RPC_E_CHANGED_MODE) {
      set_error("Capture thread CoInitializeEx failed: " +
                hresult_to_string(coinit_hr));
      running_.store(false);
      return;
    }

    DWORD mmcss_task_index = 0;
    HANDLE mmcss_handle = AvSetMmThreadCharacteristicsW(L"Pro Audio",
                                                        &mmcss_task_index);

    while (running_.load()) {
      UINT32 packet_frames = 0;
      HRESULT hr = capture_client_->GetNextPacketSize(&packet_frames);
      if (FAILED(hr)) {
        set_error("GetNextPacketSize failed: " + hresult_to_string(hr));
        break;
      }
      if (packet_frames == 0) {
        Sleep(5);
        continue;
      }
      BYTE* data = nullptr;
      UINT32 frames = 0;
      DWORD flags = 0;
      hr = capture_client_->GetBuffer(&data, &frames, &flags, nullptr, nullptr);
      if (FAILED(hr)) {
        set_error("GetBuffer failed: " + hresult_to_string(hr));
        break;
      }
      if (flags & AUDCLNT_BUFFERFLAGS_SILENT) {
        ring_->write_zeros(frames);
      } else {
        if (mono_scratch_.size() < frames) mono_scratch_.resize(frames);
        DownmixToMonoFloat(data, frames, mono_scratch_.data());
        ring_->write(mono_scratch_.data(), frames);
      }
      capture_client_->ReleaseBuffer(frames);
    }

    if (mmcss_handle != nullptr) AvRevertMmThreadCharacteristics(mmcss_handle);
    if (SUCCEEDED(coinit_hr)) CoUninitialize();  // covers S_OK and S_FALSE
    running_.store(false);
  }

  void DownmixToMonoFloat(const BYTE* data, UINT32 frames, float* out) const {
    if (is_float_) {
      const float* p = reinterpret_cast<const float*>(data);
      for (UINT32 i = 0; i < frames; ++i) {
        double sum = 0.0;
        for (int c = 0; c < channels_; ++c) sum += p[i * channels_ + c];
        out[i] = static_cast<float>(sum / channels_);
      }
    } else {
      const int16_t* p = reinterpret_cast<const int16_t*>(data);
      for (UINT32 i = 0; i < frames; ++i) {
        double sum = 0.0;
        for (int c = 0; c < channels_; ++c) sum += p[i * channels_ + c];
        out[i] = static_cast<float>(sum / channels_ / 32768.0);
      }
    }
  }

  void CleanupCom() {
    if (capture_client_ != nullptr) {
      capture_client_->Release();
      capture_client_ = nullptr;
    }
    if (audio_client_ != nullptr) {
      audio_client_->Release();
      audio_client_ = nullptr;
    }
    if (device_ != nullptr) {
      device_->Release();
      device_ = nullptr;
    }
    if (enumerator_ != nullptr) {
      enumerator_->Release();
      enumerator_ = nullptr;
    }
    ring_.reset();
    if (com_initialized_) {
      CoUninitialize();
      com_initialized_ = false;
    }
  }

  int mode_ = WASAPI_MODE_SYSTEM;
  bool com_initialized_ = false;
  bool is_float_ = false;
  int sample_rate_ = 0;
  int channels_ = 0;

  std::atomic<bool> running_{false};
  std::thread thread_;

  IMMDeviceEnumerator* enumerator_ = nullptr;
  IMMDevice* device_ = nullptr;
  IAudioClient* audio_client_ = nullptr;
  IAudioCaptureClient* capture_client_ = nullptr;

  std::unique_ptr<FloatRingBuffer> ring_;
  std::vector<float> mono_scratch_;
};

}  // namespace

extern "C" {

int wasapi_start(int mode, void** out_handle) {
  if (out_handle == nullptr) return -1;
  auto* capture = new WasapiCapture();
  int rc = capture->Start(mode);
  if (rc != 0) {
    delete capture;
    return rc;
  }
  *out_handle = capture;
  return 0;
}

int wasapi_read(void* handle, float* out, int max_frames, int* frames_read,
                int* sample_rate) {
  if (handle == nullptr) return -1;
  auto* capture = static_cast<WasapiCapture*>(handle);
  return capture->Read(out, max_frames, frames_read, sample_rate);
}

void wasapi_stop(void* handle) {
  if (handle == nullptr) return;
  delete static_cast<WasapiCapture*>(handle);  // destructor stops the thread
}

const char* wasapi_last_error() {
  std::lock_guard<std::mutex> lock(g_error_mutex);
  return g_last_error.c_str();
}

}  // extern "C"
