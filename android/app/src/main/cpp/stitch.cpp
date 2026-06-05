// Phase 6 — JNI shim. StitchChannel.java calls this; it forwards the
// tile file paths to OpenPano (vendored), which stitches them and writes
// the result. OpenCV's auto-stitcher was non-deterministic on our
// regular grid; OpenPano reliably stitches the same tiles.
//
// Tiles in / result out are file paths (PNG). [nCols] is the grid width
// (row-major order), used to restrict feature matching to neighbouring
// tiles.
//
// Returns 0 on success; non-zero on failure (read by StitchChannel.java).

#include <jni.h>

#include <string>
#include <vector>

#include "openpano_stitch.h"

extern "C" JNIEXPORT jint JNICALL
Java_at_sciens_gimbal_1controller_StitchChannel_nativeStitch(
    JNIEnv* env, jclass /*clazz*/, jobjectArray paths, jstring outPath,
    jint nCols) {
  try {
    const jsize n = env->GetArrayLength(paths);
    std::vector<std::string> tilePaths;
    tilePaths.reserve(n);
    for (jsize i = 0; i < n; ++i) {
      auto js = reinterpret_cast<jstring>(env->GetObjectArrayElement(paths, i));
      const char* c = env->GetStringUTFChars(js, nullptr);
      tilePaths.emplace_back(c);
      env->ReleaseStringUTFChars(js, c);
      env->DeleteLocalRef(js);
    }

    const char* outc = env->GetStringUTFChars(outPath, nullptr);
    const std::string out(outc);
    env->ReleaseStringUTFChars(outPath, outc);

    const std::string workDir = out.substr(0, out.find_last_of('/'));
    return openpano_stitch(tilePaths, out, workDir, nCols);
  } catch (...) {
    return -102;
  }
}
