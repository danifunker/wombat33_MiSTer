/* Custom Finder icon + BNDL for the CpuFpuBench APPL.
 * Split chip outline (green left half, red right half),
 * "MACII / CPU/FPU / BENCH" inside. See make_icons.py for source. */

#include "Types.r"

resource 'BNDL' (128) {
    'CFpB', 0,
    {
        'FREF', { 0, 128 },
        'ICN#', { 0, 128 },
        'icl4', { 0, 128 }
    }
};

resource 'FREF' (128) {
    'APPL', 0, ""
};

resource 'ICN#' (128, "CpuFpuBench") {
    {
        $"06 66 66 60 06 66 66 60 1F FF FF F8 30 00 00 0C"
        $"20 00 00 04 E0 00 00 07 E2 59 9D C7 23 E6 08 84"
        $"23 FE 08 84 E2 66 08 87 E2 65 9D C7 20 00 00 04"
        $"20 00 00 04 E6 E9 1F EF E8 99 28 9F 28 E9 2E ED"
        $"28 89 48 8D E6 86 88 87 E0 00 00 07 20 00 00 04"
        $"23 BE 5A 44 E2 63 62 47 E3 BA E3 C7 22 62 62 44"
        $"23 BE 5A 44 E0 00 00 07 E0 00 00 07 20 00 00 04"
        $"30 00 00 0C 1F FF FF F8 06 66 66 60 06 66 66 60",
        $"06 66 66 60 06 66 66 60 1F FF FF F8 3F FF FF FC"
        $"3F FF FF FC FF FF FF FF FF FF FF FF 3F FF FF FC"
        $"3F FF FF FC FF FF FF FF FF FF FF FF 3F FF FF FC"
        $"3F FF FF FC FF FF FF FF FF FF FF FF 3F FF FF FC"
        $"3F FF FF FC FF FF FF FF FF FF FF FF 3F FF FF FC"
        $"3F FF FF FC FF FF FF FF FF FF FF FF 3F FF FF FC"
        $"3F FF FF FC FF FF FF FF FF FF FF FF 3F FF FF FC"
        $"3F FF FF FC 1F FF FF F8 06 66 66 60 06 66 66 60"
    }
};

data 'icl4' (128, "CpuFpuBench") {
        $"00 00 08 80 08 80 08 80 02 20 02 20 02 20 00 00"
        $"00 00 08 80 08 80 08 80 02 20 02 20 02 20 00 00"
        $"00 08 88 88 88 88 88 88 22 22 22 22 22 22 20 00"
        $"00 88 00 00 00 00 00 00 00 00 00 00 00 00 22 00"
        $"00 80 00 00 00 00 00 00 00 00 00 00 00 00 02 00"
        $"88 80 00 00 00 00 00 00 00 00 00 00 00 00 02 22"
        $"88 80 00 F0 0F 0F F0 0F F0 0F FF 0F FF 00 02 22"
        $"00 80 00 FF FF F0 0F F0 00 00 F0 00 F0 00 02 00"
        $"00 80 00 FF FF FF FF F0 00 00 F0 00 F0 00 02 00"
        $"88 80 00 F0 0F F0 0F F0 00 00 F0 00 F0 00 02 22"
        $"88 80 00 F0 0F F0 0F 0F F0 0F FF 0F FF 00 02 22"
        $"00 80 00 00 00 00 00 00 00 00 00 00 00 00 02 00"
        $"00 80 00 00 00 00 00 00 00 00 00 00 00 00 02 00"
        $"88 80 0F F0 FF F0 F0 0F 00 0F FF FF FF F0 F2 2F"
        $"88 80 F0 00 F0 0F F0 0F 00 F0 F0 00 F0 0F F2 2F"
        $"00 80 F0 00 FF F0 F0 0F 00 F0 FF F0 FF F0 F2 0F"
        $"00 80 F0 00 F0 00 F0 0F 0F 00 F0 00 F0 00 F2 0F"
        $"88 80 0F F0 F0 00 0F F0 F0 00 F0 00 F0 00 0F F2"
        $"88 80 00 00 00 00 00 00 00 00 00 00 00 00 02 22"
        $"00 80 00 00 00 00 00 00 00 00 00 00 00 00 02 00"
        $"00 80 00 FF F0 FF FF F0 0F 0F F0 F0 0F 00 02 00"
        $"88 80 00 F0 0F F0 00 FF 0F F0 00 F0 0F 00 02 22"
        $"88 80 00 FF F0 FF F0 F0 FF F0 00 FF FF 00 02 22"
        $"00 80 00 F0 0F F0 00 F0 0F F0 00 F0 0F 00 02 00"
        $"00 80 00 FF F0 FF FF F0 0F 0F F0 F0 0F 00 02 00"
        $"88 80 00 00 00 00 00 00 00 00 00 00 00 00 02 22"
        $"88 80 00 00 00 00 00 00 00 00 00 00 00 00 02 22"
        $"00 80 00 00 00 00 00 00 00 00 00 00 00 00 02 00"
        $"00 88 00 00 00 00 00 00 00 00 00 00 00 00 22 00"
        $"00 08 88 88 88 88 88 88 22 22 22 22 22 22 20 00"
        $"00 00 08 80 08 80 08 80 02 20 02 20 02 20 00 00"
        $"00 00 08 80 08 80 08 80 02 20 02 20 02 20 00 00"
};
