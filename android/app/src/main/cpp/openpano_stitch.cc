#include "openpano_stitch.h"

#include <fstream>

#include "lib/config.hh"
#include "lib/imgproc.hh"
#include "stitch/stitcher.hh"

using namespace config;
using namespace pano;

// The OpenPano config that reliably stitched our gimbal tiles (validated
// on Linux): camera-estimation mode, all-pairs matching, multiband off,
// lazy read (memory-friendly on a phone).
static const char* kConfig = R"CFG(
CYLINDER 0
ESTIMATE_CAMERA 1
TRANS 0
ORDERED_INPUT 0
CROP 0
MAX_OUTPUT_SIZE 8000
LAZY_READ 1
FOCAL_LENGTH 37
SIFT_WORKING_SIZE 800
NUM_OCTAVE 4
NUM_SCALE 7
SCALE_FACTOR 1.4142135623
GAUSS_SIGMA 1.4142135623
GAUSS_WINDOW_FACTOR 6
CONTRAST_THRES 4e-2
JUDGE_EXTREMA_DIFF_THRES 2e-3
EDGE_RATIO 6
PRE_COLOR_THRES 5e-2
CALC_OFFSET_DEPTH 4
OFFSET_THRES 0.5
ORI_RADIUS 4.5
ORI_HIST_SMOOTH_COUNT 2
DESC_HIST_SCALE_FACTOR 3
DESC_INT_FACTOR 512
MATCH_REJECT_NEXT_RATIO 0.8
RANSAC_ITERATIONS 1500
RANSAC_INLIER_THRES 3.5
INLIER_IN_MATCH_RATIO 0.1
INLIER_IN_POINTS_RATIO 0.04
STRAIGHTEN 1
SLOPE_PLAIN 8e-3
LM_LAMBDA 5
MULTIPASS_BA 1
MULTIBAND 0
)CFG";

// Load the global config from a file (replicates OpenPano main.cc's
// init_config, but takes an explicit path instead of cwd/config.cfg).
static void load_config(const char* path) {
#define CFG(x) x = Config.get(#x)
  ConfigParser Config(path);
  CFG(CYLINDER);
  CFG(TRANS);
  CFG(ESTIMATE_CAMERA);
  CFG(ORDERED_INPUT);
  CFG(CROP);
  CFG(STRAIGHTEN);
  CFG(FOCAL_LENGTH);
  CFG(MAX_OUTPUT_SIZE);
  CFG(LAZY_READ);
  CFG(SIFT_WORKING_SIZE);
  CFG(NUM_OCTAVE);
  CFG(NUM_SCALE);
  CFG(SCALE_FACTOR);
  CFG(GAUSS_SIGMA);
  CFG(GAUSS_WINDOW_FACTOR);
  CFG(JUDGE_EXTREMA_DIFF_THRES);
  CFG(CONTRAST_THRES);
  CFG(PRE_COLOR_THRES);
  CFG(EDGE_RATIO);
  CFG(CALC_OFFSET_DEPTH);
  CFG(OFFSET_THRES);
  CFG(ORI_RADIUS);
  CFG(ORI_HIST_SMOOTH_COUNT);
  CFG(DESC_HIST_SCALE_FACTOR);
  CFG(DESC_INT_FACTOR);
  CFG(MATCH_REJECT_NEXT_RATIO);
  CFG(RANSAC_ITERATIONS);
  CFG(RANSAC_INLIER_THRES);
  CFG(INLIER_IN_MATCH_RATIO);
  CFG(INLIER_IN_POINTS_RATIO);
  CFG(SLOPE_PLAIN);
  CFG(LM_LAMBDA);
  CFG(MULTIPASS_BA);
  CFG(MULTIBAND);
#undef CFG
}

int openpano_stitch(const std::vector<std::string>& paths,
                    const std::string& outPath,
                    const std::string& workDir,
                    int nCols) {
  try {
    if (paths.size() < 2) return -1;
    const std::string cfgPath = workDir + "/openpano.cfg";
    {
      std::ofstream f(cfgPath);
      if (!f) return -2;
      f << kConfig;
    }
    load_config(cfgPath.c_str());

    // Restrict matching to grid neighbours (tiles are row-major).
    pano::g_grid_cols = nCols;
    // Progress file the Dart UI polls during the stitch.
    pano::g_progress_path = workDir + "/progress.txt";

    std::vector<std::string> imgs(paths.begin(), paths.end());
    Stitcher p(std::move(imgs));
    Mat32f res = p.build();
    if (CROP) res = crop(res);
    write_rgb(outPath.c_str(), res);
    pano::g_progress_path.clear();
    return 0;
  } catch (...) {
    pano::g_progress_path.clear();
    return -100;
  }
}
