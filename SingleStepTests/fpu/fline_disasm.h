// Compact pretty-printer for 68881 F-line instructions.
//
// Covers the families the FPU bench is most likely to exercise:
//   - cpGEN  (FADD/FSUB/FMUL/FDIV/FSQRT/FCMP/... and FMOVE variants)
//   - cpBcc.w / cpBcc.l
//   - cpScc / cpDBcc / cpTRAPcc
//   - cpSAVE / cpRESTORE
//
// Output is a single short line of the form "FADD.X FP0,FP1" — designed for
// printing alongside a failing test, not for round-trip assembly.

#pragma once

#include <cstdint>
#include <cstdio>
#include <cstring>

namespace fline {

inline const char* gen_mnem(unsigned op7) {
    // Lookup keyed by extension-word bits[6:0]. Returns nullptr if unknown,
    // which the caller falls back to printing as "FxOP_$xx".
    switch (op7) {
        case 0x00: return "FMOVE";
        case 0x01: return "FINT";
        case 0x02: return "FSINH";
        case 0x03: return "FINTRZ";
        case 0x04: return "FSQRT";
        case 0x06: return "FLOGNP1";
        case 0x08: return "FETOXM1";
        case 0x09: return "FTANH";
        case 0x0A: return "FATAN";
        case 0x0C: return "FASIN";
        case 0x0D: return "FATANH";
        case 0x0E: return "FSIN";
        case 0x0F: return "FTAN";
        case 0x10: return "FETOX";
        case 0x11: return "FTWOTOX";
        case 0x12: return "FTENTOX";
        case 0x14: return "FLOGN";
        case 0x15: return "FLOG10";
        case 0x16: return "FLOG2";
        case 0x18: return "FABS";
        case 0x19: return "FCOSH";
        case 0x1A: return "FNEG";
        case 0x1C: return "FACOS";
        case 0x1D: return "FCOS";
        case 0x1E: return "FGETEXP";
        case 0x1F: return "FGETMAN";
        case 0x20: return "FDIV";
        case 0x21: return "FMOD";
        case 0x22: return "FADD";
        case 0x23: return "FMUL";
        case 0x24: return "FSGLDIV";
        case 0x25: return "FREM";
        case 0x26: return "FSCALE";
        case 0x27: return "FSGLMUL";
        case 0x28: return "FSUB";
        case 0x38: return "FCMP";
        case 0x3A: return "FTST";
        default:
            if ((op7 & 0x78) == 0x30) return "FSINCOS"; // 30..37
            return nullptr;
    }
}

// Data-format letter for R/M=1 cpGEN (extension bits[12:10]).
inline char fmt_letter(unsigned spec) {
    static const char* k = "LSXPWDB?";
    return k[spec & 7];
}

inline const char* cc_mnem(unsigned cc) {
    static const char* tab[32] = {
        "F",  "EQ", "OGT","OGE","OLT","OLE","OGL","OR",
        "UN", "UEQ","UGT","UGE","ULT","ULE","NE", "T",
        "SF", "SEQ","GT", "GE", "LT", "LE", "GL", "GLE",
        "NGLE","NGL","NLE","NLT","NGE","NGT","SNE","ST"
    };
    return tab[cc & 31];
}

inline void ea_str(unsigned mode, unsigned reg, char* out, size_t n) {
    switch (mode) {
        case 0: snprintf(out, n, "D%u", reg); break;
        case 1: snprintf(out, n, "A%u", reg); break;
        case 2: snprintf(out, n, "(A%u)", reg); break;
        case 3: snprintf(out, n, "(A%u)+", reg); break;
        case 4: snprintf(out, n, "-(A%u)", reg); break;
        case 5: snprintf(out, n, "d16(A%u)", reg); break;
        case 6: snprintf(out, n, "d8(A%u,Xn)", reg); break;
        case 7:
            switch (reg) {
                case 0: snprintf(out, n, "(xxx).W"); break;
                case 1: snprintf(out, n, "(xxx).L"); break;
                case 2: snprintf(out, n, "d16(PC)"); break;
                case 3: snprintf(out, n, "d8(PC,Xn)"); break;
                case 4: snprintf(out, n, "#imm"); break;
                default: snprintf(out, n, "(7,%u?)", reg); break;
            }
            break;
        default: snprintf(out, n, "(?,%u)", mode); break;
    }
}

// Disassemble two-word F-line (opword + ext). Returns a static buffer.
inline const char* disasm(uint16_t opword, uint16_t ext) {
    static char buf[64];
    const unsigned cop  = (opword >> 9) & 7;
    const unsigned type = (opword >> 6) & 7;
    const unsigned mode = (opword >> 3) & 7;
    const unsigned reg  = opword & 7;

    if (cop != 1) {  // not the FPU coprocessor ID
        snprintf(buf, sizeof(buf), "cp%u.??? $%04X $%04X", cop, opword, ext);
        return buf;
    }

    char ea[16];

    switch (type) {
        case 0: { // cpGEN — ext-word family selected by bits[15:13]
            const unsigned family = (ext >> 13) & 7;
            const unsigned src    = (ext >> 10) & 7;
            const unsigned dst    = (ext >> 7)  & 7;   // FPn
            const unsigned op7    = ext & 0x7F;
            const char*    mn     = gen_mnem(op7);

            switch (family) {
                case 0: // R/M=0 general op (reg-reg)
                    snprintf(buf, sizeof(buf), "%s.X FP%u,FP%u",
                             mn ? mn : "FxOP", src, dst);
                    break;
                case 2: // FMOVE.fmt FPn,<ea>
                    ea_str(mode, reg, ea, sizeof(ea));
                    snprintf(buf, sizeof(buf), "FMOVE.%c FP%u,%s",
                             fmt_letter(src), dst, ea);
                    break;
                case 4: // R/M=1 general op (<ea> -> FPn)
                    ea_str(mode, reg, ea, sizeof(ea));
                    snprintf(buf, sizeof(buf), "%s.%c %s,FP%u",
                             mn ? mn : "FxOP", fmt_letter(src), ea, dst);
                    break;
                case 5: // FMOVECR #ROMoffset,FPn
                    snprintf(buf, sizeof(buf), "FMOVECR #$%02X,FP%u",
                             ext & 0x7F, dst);
                    break;
                case 6: case 7: // FMOVEM (data regs / control regs)
                    ea_str(mode, reg, ea, sizeof(ea));
                    snprintf(buf, sizeof(buf), "FMOVEM ext=$%04X,%s",
                             ext, ea);
                    break;
                default:
                    snprintf(buf, sizeof(buf), "cpGEN $%04X $%04X",
                             opword, ext);
                    break;
            }
            break;
        }
        case 1: { // cpScc / cpDBcc / cpTRAPcc
            const unsigned cc = ext & 0x3F;
            if (mode == 1) {
                snprintf(buf, sizeof(buf), "FDB%s D%u,disp",
                         cc_mnem(cc), reg);
            } else if (mode == 7 && (reg == 2 || reg == 3 || reg == 4)) {
                snprintf(buf, sizeof(buf), "FTRAP%s", cc_mnem(cc));
            } else {
                ea_str(mode, reg, ea, sizeof(ea));
                snprintf(buf, sizeof(buf), "FS%s.B %s", cc_mnem(cc), ea);
            }
            break;
        }
        case 2: { // cpBcc.W
            const unsigned cc = opword & 0x3F;
            snprintf(buf, sizeof(buf), "FB%s.W disp=$%04X",
                     cc_mnem(cc), ext);
            break;
        }
        case 3: { // cpBcc.L
            const unsigned cc = opword & 0x3F;
            snprintf(buf, sizeof(buf), "FB%s.L disp_hi=$%04X",
                     cc_mnem(cc), ext);
            break;
        }
        case 4: { // cpSAVE
            ea_str(mode, reg, ea, sizeof(ea));
            snprintf(buf, sizeof(buf), "FSAVE %s", ea);
            break;
        }
        case 5: { // cpRESTORE
            ea_str(mode, reg, ea, sizeof(ea));
            snprintf(buf, sizeof(buf), "FRESTORE %s", ea);
            break;
        }
        default:
            snprintf(buf, sizeof(buf), "F? $%04X $%04X", opword, ext);
            break;
    }
    return buf;
}

} // namespace fline
