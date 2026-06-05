#pragma once
#include <string>
#include <vector>

// Stitch the tile images (absolute file paths, PNG) into a panorama,
// written to outPath. workDir is a writable dir for the OpenPano config.
// nCols is the grid width (tiles are passed row-major); >0 restricts
// feature matching to grid neighbours (faster). Returns 0 on success,
// negative on error.
int openpano_stitch(const std::vector<std::string>& paths,
                    const std::string& outPath,
                    const std::string& workDir,
                    int nCols);
