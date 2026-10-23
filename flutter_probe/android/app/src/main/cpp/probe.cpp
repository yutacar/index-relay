#include <jni.h>
#include <whisper.h>
#include <memory>
#include <string>
#include <vector>
#include <atomic>
#include <algorithm>
#include <unistd.h>
static std::atomic<jlong> cancelled{0};
extern "C" JNIEXPORT void JNICALL Java_dev_example_index_1relay_1probe_NativeWhisper_cancel(JNIEnv *, jobject, jlong token) { cancelled.store(token); }

extern "C" JNIEXPORT jstring JNICALL
Java_dev_example_index_1relay_1probe_NativeWhisper_transcribe(JNIEnv *env, jobject, jstring model, jfloatArray audio, jlong token) {
    const char *path = env->GetStringUTFChars(model, nullptr);
    if (!path) return nullptr;
    auto cp = whisper_context_default_params(); cp.use_gpu = false;
    std::unique_ptr<whisper_context, decltype(&whisper_free)> ctx(whisper_init_from_file_with_params(path, cp), whisper_free);
    env->ReleaseStringUTFChars(model, path);
    if (!ctx) { env->ThrowNew(env->FindClass("java/lang/IllegalStateException"), "MODEL_LOAD_FAILED"); return nullptr; }
    const auto n = env->GetArrayLength(audio);
    if (n <= 0 || n > 16000 * 300) { env->ThrowNew(env->FindClass("java/lang/IllegalArgumentException"), "INVALID_AUDIO_LENGTH"); return nullptr; }
    std::vector<float> samples(n); env->GetFloatArrayRegion(audio, 0, n, samples.data());
    if (env->ExceptionCheck()) return nullptr;
    auto p = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    p.language = "ja"; p.translate = false;
    // Bound inference threads by available cores to avoid oversubscribing small emulators/devices.
    const long cores = sysconf(_SC_NPROCESSORS_ONLN);
    p.n_threads = static_cast<int>(std::max(1L, std::min(4L, cores)));
    p.print_progress = false; p.print_realtime = false; p.print_timestamps = false;
    p.abort_callback = [](void *user) { return cancelled.load() == *static_cast<jlong *>(user); };
    p.abort_callback_user_data = &token;
    p.no_context = true; p.single_segment = false;
    if (whisper_full(ctx.get(), p, samples.data(), n) != 0) {
        env->ThrowNew(env->FindClass("java/lang/IllegalStateException"), "RECOGNITION_FAILED"); return nullptr;
    }
    std::string text;
    for (int i = 0; i < whisper_full_n_segments(ctx.get()); ++i) text += whisper_full_get_segment_text(ctx.get(), i);
    auto bytes = env->NewByteArray(static_cast<jsize>(text.size()));
    if (!bytes) return nullptr;
    env->SetByteArrayRegion(bytes, 0, static_cast<jsize>(text.size()), reinterpret_cast<const jbyte *>(text.data()));
    auto cls = env->FindClass("java/lang/String");
    auto init = env->GetMethodID(cls, "<init>", "([BLjava/lang/String;)V");
    return static_cast<jstring>(env->NewObject(cls, init, bytes, env->NewStringUTF("UTF-8")));
}
