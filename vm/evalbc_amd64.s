// Copyright (C) 2022 Sneller, Inc.
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.

// The following bytecode instructions:
//
//   - bccbrtf  (CBRT)
//   - bcexpf   (EXP)
//   - bcexp2f  (EXP2)
//   - bcexp10f (EXP10)
//   - bcexpm1f (EXPM1)
//   - bclnf    (LN)
//   - bcln1pf  (LN1P)
//   - bclog2f  (LOG2)
//   - bclog10f (LOG10)
//   - bcsinf   (SIN)
//   - bccosf   (COS)
//   - bctanf   (TAN)
//   - bcasinf  (ASIN)
//   - bcacosf  (ACOS)
//   - bcatanf  (ATAN)
//   - bcatan2f (ATAN2)
//   - bchypotf (HYPOT)
//   - bcpowf   (POW)
//
// were ported from SLEEF library <https://github.com/shibatch/sleef>,
// which is distributed under the following conditions:
//
//   Copyright Naoki Shibata and contributors 2010 - 2021.
//   Distributed under the Boost Software License, Version 1.0.
//   (See accompanying file LICENSE.txt or copy at
//   http://www.boost.org/LICENSE_1_0.txt)

// the opaddrs global is produced
// by parsing this file and emitting
// a table entry for every function
// declared as /^TEXT bc.*/
#include "textflag.h"
#include "funcdata.h"
#include "go_asm.h"
#include "avx512.h"
#include "bc_amd64.h"
#include "bc_imm_amd64.h"
#include "bc_constant.h"
#include "bc_constant_rempi.h"
#include "bc_macros_amd64.h"
#include "ops_mask.h" // provides OPMASK

// decodes the next instruction from the virtual pc
// register, advances virtual pc register, and jumps
// into the next bytecode instruction.
#define _NEXT(vm_pc, advance) \
  ADDQ $(advance + 8), vm_pc  \
  JMP  -8(vm_pc)

// every bytecode instruction
// other than 'ret' should end in
// NEXT(), which will branch into
// the next pseudo-instruction
#define NEXT() _NEXT(VIRT_PCREG, 0)

#define NEXT_ADVANCE(advance) _NEXT(VIRT_PCREG, advance)

// RET_ABORT returns early
// with the carry flag set to
// indicate an aborted bytecode program
#define RET_ABORT() \
  STC \
  RET

// use FAIL() when you encounter
// an unrecoverable error
#define FAIL()                                       \
  SUBQ bytecode_compiled+0(VIRT_BCPTR), VIRT_PCREG   \
  MOVL VIRT_PCREG, bytecode_errpc(VIRT_BCPTR)        \
  MOVL $const_bcerrCorrupt, bytecode_err(VIRT_BCPTR) \
  RET_ABORT()

#define _POP(pc, dst) \
  MOVQ 0(pc), dst     \
  ADDQ $8, pc

// POP(dst) pops the next item
// of the scalar operand stack
#define POP(dst) _POP(VIRT_PCREG, dst)

// POP + broadcast quadword
#define POP_BCSTQ(zreg)            \
  VPBROADCASTQ 0(VIRT_PCREG), zreg \
  ADDQ $8, VIRT_PCREG

// POP + broadcast double
#define POP_BCSTPD(zreg)           \
  VBROADCASTSD 0(VIRT_PCREG), zreg \
  ADDQ $8, VIRT_PCREG

// POP + broadcast dword
#define POP_BCSTD(zreg)            \
  VPBROADCASTD 0(VIRT_PCREG), zreg \
  ADDQ $8, VIRT_PCREG

// decode an offset immediate
// and load that respective mask word
// into 'dst'
#define LOADMSK(dst)            \
  MOVWQZX 0(VIRT_PCREG), R8     \
  ADDQ $2, VIRT_PCREG           \
  LEAQ 0(VIRT_VALUES)(R8*1), R8 \
  KMOVW 0(R8), dst

#define LOADARG1Z(dst0, dst1)           \
  MOVWQZX 0(VIRT_PCREG), R8             \
  ADDQ $2, VIRT_PCREG                   \
  VMOVDQU64 0(VIRT_VALUES)(R8*1), dst0  \
  VMOVDQU64 64(VIRT_VALUES)(R8*1), dst1

#define SAVEARG1Z(src0, src1)           \
  MOVWQZX 0(VIRT_PCREG), R8             \
  ADDQ $2, VIRT_PCREG                   \
  VMOVDQU64 src0, 0(VIRT_VALUES)(R8*1)  \
  VMOVDQU64 src1, 64(VIRT_VALUES)(R8*1)

#define IMM_FROM_DICT(REG)      \
    MOVWQZX 0(VIRT_PCREG), DX   \
    ADDQ $2, VIRT_PCREG         \
    SHLQ $4, DX                 \ // imm *= sizeof(string)
    MOVQ bytecode_dict(DI), REG \ // REG = dict
    LEAQ 0(REG)(DX*1), REG        // REG = &dict[imm]

// Control Flow Instructions
// -------------------------

// the 'return' instruction
TEXT bcret(SB), NOSPLIT|NOFRAME, $0
  // bytecode.auxpos += popcnt(lanes)
  KMOVW   K7, R8
  POPCNTL R8, R8
  ADDQ    R8, bytecode_auxpos(VIRT_BCPTR)
  CLC
  RET

// jump forward 'n' bytes if the current mask is zero
TEXT bcjz(SB), NOSPLIT|NOFRAME, $0
  POP(DX)
  KTESTW K1, K1
  JNZ    next
  LEAQ   0(VIRT_PCREG)(DX*1), VIRT_PCREG   // virtual pc += uint32(DX)
next:
  NEXT()

// Load & Save Instructions
// ------------------------

// k1 = vstack[imm]
TEXT bcloadk(SB), NOSPLIT|NOFRAME, $0
  MOVWQZX 0(VIRT_PCREG), R8
  KMOVW 0(VIRT_VALUES)(R8*1), K1
  NEXT_ADVANCE(2)

// vstack[imm] = k1
TEXT bcsavek(SB), NOSPLIT|NOFRAME, $0
  MOVWQZX 0(VIRT_PCREG), R8
  KMOVW K1, 0(VIRT_VALUES)(R8*1)
  NEXT_ADVANCE(2)

// swap(k1, vstack[imm])
TEXT bcxchgk(SB), NOSPLIT|NOFRAME, $0
  MOVWQZX 0(VIRT_PCREG), R8
  KMOVW 0(VIRT_VALUES)(R8*1), K2
  KMOVW K1, 0(VIRT_VALUES)(R8*1)
  KMOVW K2, K1
  NEXT_ADVANCE(2)

// load row pointer
TEXT bcloadb(SB), NOSPLIT|NOFRAME, $0
  MOVWQZX 0(VIRT_PCREG), R8
  VMOVDQU64 0(VIRT_VALUES)(R8*1), Z0
  VMOVDQU64 64(VIRT_VALUES)(R8*1), Z1
  NEXT_ADVANCE(2)

// save row pointer
TEXT bcsaveb(SB), NOSPLIT|NOFRAME, $0
  MOVWQZX 0(VIRT_PCREG), R8
  VMOVDQU64 Z0, 0(VIRT_VALUES)(R8*1)
  VMOVDQU64 Z1, 64(VIRT_VALUES)(R8*1)
  NEXT_ADVANCE(2)

// load value pointer
TEXT bcloadv(SB), NOSPLIT|NOFRAME, $0
  MOVWQZX 0(VIRT_PCREG), R8
  VMOVDQU64 0(VIRT_VALUES)(R8*1), Z30
  VMOVDQU64 64(VIRT_VALUES)(R8*1), Z31
  NEXT_ADVANCE(2)

// save value pointer
TEXT bcsavev(SB), NOSPLIT|NOFRAME, $0
  MOVWQZX 0(VIRT_PCREG), R8
  VMOVDQU64 Z30, 0(VIRT_VALUES)(R8*1)
  VMOVDQU64 Z31, 64(VIRT_VALUES)(R8*1)
  NEXT_ADVANCE(2)

// load a sub-structure pointer,
// but only set K1 for non-zero-length
// sub-structure components
TEXT bcloadzerov(SB), NOSPLIT|NOFRAME, $0
  MOVWQZX 0(VIRT_PCREG), R8
  VMOVDQU64 0(VIRT_VALUES)(R8*1), Z30
  VMOVDQU64 64(VIRT_VALUES)(R8*1), Z31
  VPTESTMD Z31, Z31, K1
  NEXT_ADVANCE(2)

// save a sub-structure pointer,
// but zero results when K1 is unset
TEXT bcsavezerov(SB), NOSPLIT|NOFRAME, $0
  MOVWQZX     0(VIRT_PCREG), R8
  VMOVDQA32.Z Z30, K1, Z28
  VMOVDQA32.Z Z31, K1, Z29
  VMOVDQU32   Z28, 0(VIRT_VALUES)(R8*1)
  VMOVDQU32   Z29, 64(VIRT_VALUES)(R8*1)
  NEXT_ADVANCE(2)

// load a value pointer from bytecode.outer
// using the permutation specified in
// bytecode.perm
TEXT bcloadpermzerov(SB), NOSPLIT|NOFRAME, $0
  MOVWQZX     0(VIRT_PCREG), R8
  MOVQ        bytecode_outer(VIRT_BCPTR), R15
  VMOVDQU32   bytecode_perm(VIRT_BCPTR), Z28
  MOVQ        bytecode_vstack(R15), R15
  VPERMD      0(R15)(R8*1), Z28, Z30
  VPERMD      64(R15)(R8*1), Z28, Z31
  VPTESTMD    Z31, Z31, K1
  NEXT_ADVANCE(2)

// load scalar
TEXT bcloads(SB), NOSPLIT|NOFRAME, $0
  MOVWQZX 0(VIRT_PCREG), R8
  VMOVDQU64 0(VIRT_VALUES)(R8*1), Z2
  VMOVDQU64 64(VIRT_VALUES)(R8*1), Z3
  NEXT_ADVANCE(2)

// save scalar
TEXT bcsaves(SB), NOSPLIT|NOFRAME, $0
  MOVWQZX 0(VIRT_PCREG), R8
  VMOVDQU64 Z2, 0(VIRT_VALUES)(R8*1)
  VMOVDQU64 Z3, 64(VIRT_VALUES)(R8*1)
  NEXT_ADVANCE(2)

TEXT bcloadzeros(SB), NOSPLIT|NOFRAME, $0
  MOVWQZX 0(VIRT_PCREG), R8
  VMOVDQU32 0(VIRT_VALUES)(R8*1), Z2
  VMOVDQU32 64(VIRT_VALUES)(R8*1), Z3
  VPTESTMD Z3, Z3, K1
  NEXT_ADVANCE(2)

TEXT bcsavezeros(SB), NOSPLIT|NOFRAME, $0
  MOVWQZX 0(VIRT_PCREG), R8
  KSHIFTRW $8, K1, K2
  VMOVDQA32.Z Z2, K1, Z4
  VMOVDQA32.Z Z3, K2, Z5
  VMOVDQU32 Z4, 0(VIRT_VALUES)(R8*1)
  VMOVDQU32 Z5, 64(VIRT_VALUES)(R8*1)
  NEXT_ADVANCE(2)

// Mask Instructions
// -----------------

TEXT bcbroadcastimmk(SB), NOSPLIT|NOFRAME, $0
  KMOVW 0(VIRT_PCREG), K1
  NEXT_ADVANCE(2)

TEXT bcfalse(SB), NOSPLIT|NOFRAME, $0
  VPXORD  Z30, Z30, Z30
  VPXORD  Z31, Z31, Z31
  KXORW   K0, K0, K1
  NEXT()

// K1 &= vstack[imm]
TEXT bcandk(SB), NOSPLIT|NOFRAME, $0
  MOVWQZX 0(VIRT_PCREG), R8
  KMOVW 0(VIRT_VALUES)(R8*1), K2
  KANDW K1, K2, K1
  NEXT_ADVANCE(2)

// K1 |= vstack[imm]
TEXT bcork(SB), NOSPLIT|NOFRAME, $0
  MOVWQZX 0(VIRT_PCREG), R8
  KMOVW 0(VIRT_VALUES)(R8*1), K2
  KORW  K1, K2, K1
  NEXT_ADVANCE(2)

// K1 = vstack[imm] &^ K1
TEXT bcandnotk(SB), NOSPLIT|NOFRAME, $0
  MOVWQZX 0(VIRT_PCREG), R8
  KMOVW 0(VIRT_VALUES)(R8*1), K2
  KANDNW K2, K1, K1
  NEXT_ADVANCE(2)

// K1 = K1 &^ vstack[imm]
TEXT bcnandk(SB), NOSPLIT|NOFRAME, $0
  MOVWQZX 0(VIRT_PCREG), R8
  KMOVW 0(VIRT_VALUES)(R8*1), K2
  KANDNW K1, K2, K1
  NEXT_ADVANCE(2)

// K1 = (K1 ^ vstack[imm]) & (valid lanes)
TEXT bcxork(SB), NOSPLIT|NOFRAME, $0
  MOVWQZX 0(VIRT_PCREG), R8
  KMOVW 0(VIRT_VALUES)(R8*1), K2
  KXORW K1, K2, K1
  NEXT_ADVANCE(2)

// K1 = K1 ^ true
// (this is roughly NOT, but keeps invalid lanes unset)
TEXT bcnotk(SB), NOSPLIT|NOFRAME, $0
  KXORW K1, K7, K1
  NEXT()

// K1 = (K1 xnor vstack[imm]) & (valid lanes)
TEXT bcxnork(SB), NOSPLIT|NOFRAME, $0
  MOVWQZX 0(VIRT_PCREG), R8
  KMOVW 0(VIRT_VALUES)(R8*1), K2
  KXNORW K1, K2, K1
  KANDW  K1, K7, K1
  NEXT_ADVANCE(2)

// Arithmetic & Logical Instructions
// ---------------------------------

// Arithmetic operation macros
#define BC_ARITH_OP_VAR(instruction)                \
  MOVWQZX       0(VIRT_PCREG), R8                   \
  KSHIFTRW      $8, K1, K2                          \
  instruction   0(VIRT_VALUES)(R8*1), Z2, K1, Z2    \
  instruction   64(VIRT_VALUES)(R8*1), Z3, K2, Z3

#define BC_ARITH_OP_IMM(instruction, broadcast)     \
  broadcast     0(VIRT_PCREG), Z4                   \
  KSHIFTRW      $8, K1, K2                          \
  instruction   Z4, Z2, K1, Z2                      \
  instruction   Z4, Z3, K2, Z3

#define BC_ARITH_REV_OP_VAR(instruction)            \
  MOVWQZX       0(VIRT_PCREG), R8                   \
  KSHIFTRW      $8, K1, K2                          \
  VMOVDQU64     0(VIRT_VALUES)(R8*1), Z4            \
  VMOVDQU64     64(VIRT_VALUES)(R8*1), Z5           \
  instruction   Z2, Z4, K1, Z2                      \
  instruction   Z3, Z5, K2, Z3

#define BC_ARITH_REV_OP_IMM(instruction, broadcast) \
  broadcast     0(VIRT_PCREG), Z4                   \
  KSHIFTRW      $8, K1, K2                          \
  instruction   Z2, Z4, K1, Z2                      \
  instruction   Z3, Z4, K2, Z3

// Left = Left - Trunc(Left / Right) * Right
#define BC_MODF64_OP(LEFT1, LEFT2, RIGHT1, RIGHT2, TMP1, TMP2) \
  VDIVPD.RZ_SAE.Z RIGHT1, LEFT1, K1, TMP1                      \
  VDIVPD.RZ_SAE.Z RIGHT2, LEFT2, K2, TMP2                      \
  VRNDSCALEPD.Z   $VROUND_IMM_TRUNC_SAE, TMP1, K1, TMP1        \
  VRNDSCALEPD.Z   $VROUND_IMM_TRUNC_SAE, TMP2, K2, TMP2        \
  VFNMADD231PD    RIGHT1, TMP1, K1, LEFT1                      \
  VFNMADD231PD    RIGHT2, TMP2, K2, LEFT2

// This macro implements INT64 division that can be used in bytecode instructions.
//
// An unsigned scalar version could look like this (in C++):
//
// static uint64_t divu64(uint64_t a, uint64_t b) {
//   double fa = double(a);
//   double fb = double(b);
//
//   // First division step.
//   uint64_t w1 = uint64_t(fa / fb);
//   uint64_t x = w1 * b;
//
//   // Remainder of the first division step.
//   double fc = double(int64_t(a) - int64_t(x));
//
//   // Second division step.
//   int64_t w2 = int64_t(fc / fb);
//   uint64_t w = uint64_t(w1 + w2);
//
//   // Correction of a possible "off by 1" result.
//   return w - uint64_t(w * b > a);
// }
#define BC_DIVU64_IMPL(DST_A, DST_B, SRC_A1, SRC_B1, SRC_A2, SRC_B2, MASK_A, MASK_B, TMP_A1, TMP_B1, TMP_A2, TMP_B2, TMP_A3, TMP_B3, TMP_MASK_A, TMP_MASK_B) \
  /* Convert to double precision */                           \
  VCVTUQQ2PD.Z SRC_A1, MASK_A, TMP_A1                         \
  VCVTUQQ2PD.Z SRC_B1, MASK_B, TMP_B1                         \
  VCVTUQQ2PD.Z SRC_A2, MASK_A, TMP_A2                         \
  VCVTUQQ2PD.Z SRC_B2, MASK_B, TMP_B2                         \
                                                              \
  /* First division step */                                   \
  VDIVPD.Z TMP_A2, TMP_A1, MASK_A, TMP_A3                     \
  VDIVPD.Z TMP_B2, TMP_B1, MASK_B, TMP_B3                     \
                                                              \
  VCVTPD2UQQ.Z TMP_A3, MASK_A, TMP_A3                         \
  VCVTPD2UQQ.Z TMP_B3, MASK_B, TMP_B3                         \
                                                              \
  /* Decrease the dividend by the first result */             \
  VPMULLQ.Z SRC_A2, TMP_A3, MASK_A, TMP_A1                    \
  VPMULLQ.Z SRC_B2, TMP_B3, MASK_B, TMP_B1                    \
                                                              \
  VPSUBQ.Z TMP_A1, SRC_A1, MASK_A, TMP_A1                     \
  VPSUBQ.Z TMP_B1, SRC_B1, MASK_B, TMP_B1                     \
                                                              \
  /* Prepare for the second division */                       \
  VCVTQQ2PD.Z TMP_A1, MASK_A, TMP_A1                          \
  VCVTQQ2PD.Z TMP_B1, MASK_B, TMP_B1                          \
                                                              \
  /* Second division step, corrects results from the first */ \
  VDIVPD.Z TMP_A2, TMP_A1, MASK_A, TMP_A1                     \
  VDIVPD.Z TMP_B2, TMP_B1, MASK_B, TMP_B1                     \
                                                              \
  VCVTPD2QQ.Z TMP_A1, MASK_A, TMP_A1                          \
  VCVTPD2QQ.Z TMP_B1, MASK_B, TMP_B1                          \
                                                              \
  VPADDQ TMP_A1, TMP_A3, MASK_A, TMP_A3                       \
  VPADDQ TMP_B1, TMP_B3, MASK_B, TMP_B3                       \
                                                              \
  /* Calculate the result by using the second remainder */    \
  VPMULLQ SRC_A2, TMP_A3, MASK_A, TMP_A1                      \
  VPMULLQ SRC_B2, TMP_B3, MASK_B, TMP_B1                      \
                                                              \
  /* Check whether we need to subtract 1 from the result */   \
  VPCMPUQ $VPCMP_IMM_GT, SRC_A1, TMP_A1, MASK_A, TMP_MASK_A   \
  VPCMPUQ $VPCMP_IMM_GT, SRC_B1, TMP_B1, MASK_B, TMP_MASK_B   \
                                                              \
  /* Subtract 1 from the result, if necessary */              \
  VPSUBQ.BCST CONSTQ_1(), TMP_A3, TMP_MASK_A, TMP_A3          \
  VPSUBQ.BCST CONSTQ_1(), TMP_B3, TMP_MASK_B, TMP_B3          \
                                                              \
  VMOVDQA64 TMP_A3, MASK_A, DST_A                             \
  VMOVDQA64 TMP_B3, MASK_B, DST_B


#define BC_MODU64_IMPL(DST_A, DST_B, SRC_A1, SRC_B1, SRC_A2, SRC_B2, MASK_A, MASK_B, TMP_A1, TMP_B1, TMP_A2, TMP_B2, TMP_A3, TMP_B3, TMP_MASK_A, TMP_MASK_B) \
  /* Convert to double precision */                           \
  VCVTUQQ2PD.Z SRC_A1, MASK_A, TMP_A1                         \
  VCVTUQQ2PD.Z SRC_B1, MASK_B, TMP_B1                         \
  VCVTUQQ2PD.Z SRC_A2, MASK_A, TMP_A2                         \
  VCVTUQQ2PD.Z SRC_B2, MASK_B, TMP_B2                         \
                                                              \
  /* First division step */                                   \
  VDIVPD.Z TMP_A2, TMP_A1, MASK_A, TMP_A3                     \
  VDIVPD.Z TMP_B2, TMP_B1, MASK_B, TMP_B3                     \
                                                              \
  VCVTPD2UQQ.Z TMP_A3, MASK_A, TMP_A3                         \
  VCVTPD2UQQ.Z TMP_B3, MASK_B, TMP_B3                         \
                                                              \
  /* Decrease the dividend by the first result */             \
  VPMULLQ.Z SRC_A2, TMP_A3, MASK_A, TMP_A1                    \
  VPMULLQ.Z SRC_B2, TMP_B3, MASK_B, TMP_B1                    \
                                                              \
  VPSUBQ.Z TMP_A1, SRC_A1, MASK_A, TMP_A1                     \
  VPSUBQ.Z TMP_B1, SRC_B1, MASK_B, TMP_B1                     \
                                                              \
  /* Prepare for the second division */                       \
  VCVTQQ2PD.Z TMP_A1, MASK_A, TMP_A1                          \
  VCVTQQ2PD.Z TMP_B1, MASK_B, TMP_B1                          \
                                                              \
  /* Second division step, corrects results from the first */ \
  VDIVPD.Z TMP_A2, TMP_A1, MASK_A, TMP_A1                     \
  VDIVPD.Z TMP_B2, TMP_B1, MASK_B, TMP_B1                     \
                                                              \
  VCVTPD2QQ.Z TMP_A1, MASK_A, TMP_A1                          \
  VCVTPD2QQ.Z TMP_B1, MASK_B, TMP_B1                          \
                                                              \
  VPADDQ.Z TMP_A1, TMP_A3, MASK_A, TMP_A3                     \
  VPADDQ.Z TMP_B1, TMP_B3, MASK_B, TMP_B3                     \
                                                              \
  /* Calculate the result by using the second remainder */    \
  VPMULLQ.Z SRC_A2, TMP_A3, MASK_A, TMP_A1                    \
  VPMULLQ.Z SRC_B2, TMP_B3, MASK_B, TMP_B1                    \
                                                              \
  /* Check whether we need to subtract 1 from the result */   \
  VPCMPUQ $VPCMP_IMM_GT, SRC_A1, TMP_A1, MASK_A, TMP_MASK_A   \
  VPCMPUQ $VPCMP_IMM_GT, SRC_B1, TMP_B1, MASK_B, TMP_MASK_B   \
                                                              \
  /* Subtract 1 from the result, if necessary */              \
  VPSUBQ.BCST CONSTQ_1(), TMP_A3, TMP_MASK_A, TMP_A3          \
  VPSUBQ.BCST CONSTQ_1(), TMP_B3, TMP_MASK_B, TMP_B3          \
                                                              \
  /* Calculate the final remainder  */                        \
  VPMULLQ SRC_A2, TMP_A3, TMP_A3                              \
  VPMULLQ SRC_B2, TMP_B3, TMP_B3                              \
                                                              \
  VPSUBQ TMP_A3, SRC_A1, MASK_A, DST_A                        \
  VPSUBQ TMP_B3, SRC_B1, MASK_B, DST_B

#define BC_DIVI64_IMPL(DST_A, DST_B, SRC_A1, SRC_B1, SRC_A2, SRC_B2, MASK_A, MASK_B, TMP_A1, TMP_B1, TMP_A2, TMP_B2, TMP_A3, TMP_B3, TMP_A4, TMP_B4, TMP_A5, TMP_B5, TMP_MASK_A, TMP_MASK_B) \
  /* We divide positive/unsigned numbers first */             \
  VPABSQ.Z SRC_A1, MASK_A, TMP_A1                             \
  VPABSQ.Z SRC_B1, MASK_B, TMP_B1                             \
  VPABSQ.Z SRC_A2, MASK_A, TMP_A2                             \
  VPABSQ.Z SRC_B2, MASK_B, TMP_B2                             \
                                                              \
  VCVTUQQ2PD.Z TMP_A1, MASK_A, TMP_A3                         \
  VCVTUQQ2PD.Z TMP_B1, MASK_B, TMP_B3                         \
  VCVTUQQ2PD.Z TMP_A2, MASK_A, TMP_A4                         \
  VCVTUQQ2PD.Z TMP_B2, MASK_B, TMP_B4                         \
                                                              \
  /* First division step */                                   \
  VDIVPD.Z TMP_A4, TMP_A3, MASK_A, TMP_A5                     \
  VDIVPD.Z TMP_B4, TMP_B3, MASK_B, TMP_B5                     \
                                                              \
  VCVTPD2UQQ.Z TMP_A5, MASK_A, TMP_A5                         \
  VCVTPD2UQQ.Z TMP_B5, MASK_B, TMP_B5                         \
                                                              \
  /* Decrease the dividend by the first result */             \
  VPMULLQ.Z TMP_A2, TMP_A5, MASK_A, TMP_A3                    \
  VPMULLQ.Z TMP_B2, TMP_B5, MASK_B, TMP_B3                    \
                                                              \
  VPSUBQ.Z TMP_A3, TMP_A1, MASK_A, TMP_A3                     \
  VPSUBQ.Z TMP_B3, TMP_B1, MASK_B, TMP_B3                     \
                                                              \
  /* Prepare for the second division */                       \
  VCVTQQ2PD.Z TMP_A3, MASK_A, TMP_A3                          \
  VCVTQQ2PD.Z TMP_B3, MASK_B, TMP_B3                          \
                                                              \
  /* Second division step, corrects results from the first */ \
  VDIVPD.Z TMP_A4, TMP_A3, MASK_A, TMP_A3                     \
  VDIVPD.Z TMP_B4, TMP_B3, MASK_B, TMP_B3                     \
                                                              \
  VCVTPD2QQ.Z TMP_A3, MASK_A, TMP_A3                          \
  VCVTPD2QQ.Z TMP_B3, MASK_B, TMP_B3                          \
                                                              \
  /* XOR signs so we can negate the result, if necessary */   \
  VPXORQ.Z SRC_A2, SRC_A1, MASK_A, TMP_A4                     \
  VPXORQ.Z SRC_B2, SRC_B1, MASK_B, TMP_B4                     \
                                                              \
  VPADDQ TMP_A3, TMP_A5, MASK_A, DST_A                        \
  VPADDQ TMP_B3, TMP_B5, MASK_B, DST_B                        \
                                                              \
  /* Calculate the result by using the second remainder */    \
  VPMULLQ TMP_A2, DST_A, MASK_A, TMP_A2                       \
  VPMULLQ TMP_B2, DST_B, MASK_B, TMP_B2                       \
                                                              \
  /* Check whether we need to subtract 1 from the result */   \
  VPCMPUQ $VPCMP_IMM_GT, TMP_A1, TMP_A2, MASK_A, TMP_MASK_A   \
  VPCMPUQ $VPCMP_IMM_GT, TMP_B1, TMP_B2, MASK_B, TMP_MASK_B   \
                                                              \
  /* Subtract 1 from the result, if necessary */              \
  VPSUBQ.BCST CONSTQ_1(), DST_A, TMP_MASK_A, DST_A            \
  VPSUBQ.BCST CONSTQ_1(), DST_B, TMP_MASK_B, DST_B            \
                                                              \
  /* Negate the result, if the result must be negative */     \
  VPMOVQ2M TMP_A4, TMP_MASK_A                                 \
  VPMOVQ2M TMP_B4, TMP_MASK_B                                 \
                                                              \
  VPXORQ TMP_A4, TMP_A4, TMP_A4                               \
  VPSUBQ DST_A, TMP_A4, TMP_MASK_A, DST_A                     \
  VPSUBQ DST_B, TMP_A4, TMP_MASK_B, DST_B

#define BC_MODI64_IMPL(DST_A, DST_B, SRC_A1, SRC_B1, SRC_A2, SRC_B2, MASK_A, MASK_B, TMP_A1, TMP_B1, TMP_A2, TMP_B2, TMP_A3, TMP_B3, TMP_A4, TMP_B4, TMP_A5, TMP_B5, TMP_MASK_A, TMP_MASK_B) \
  /* We divide positive/unsigned numbers first */             \
  VPABSQ.Z SRC_A1, MASK_A, TMP_A1                             \
  VPABSQ.Z SRC_B1, MASK_B, TMP_B1                             \
  VPABSQ.Z SRC_A2, MASK_A, TMP_A2                             \
  VPABSQ.Z SRC_B2, MASK_B, TMP_B2                             \
                                                              \
  VCVTUQQ2PD.Z TMP_A1, MASK_A, TMP_A3                         \
  VCVTUQQ2PD.Z TMP_B1, MASK_B, TMP_B3                         \
  VCVTUQQ2PD.Z TMP_A2, MASK_A, TMP_A4                         \
  VCVTUQQ2PD.Z TMP_B2, MASK_B, TMP_B4                         \
                                                              \
  /* First division step */                                   \
  VDIVPD.Z TMP_A4, TMP_A3, MASK_A, TMP_A5                     \
  VDIVPD.Z TMP_B4, TMP_B3, MASK_B, TMP_B5                     \
                                                              \
  VCVTPD2UQQ.Z TMP_A5, MASK_A, TMP_A5                         \
  VCVTPD2UQQ.Z TMP_B5, MASK_B, TMP_B5                         \
                                                              \
  /* Decrease the dividend by the first result */             \
  VPMULLQ.Z TMP_A2, TMP_A5, MASK_A, TMP_A3                    \
  VPMULLQ.Z TMP_B2, TMP_B5, MASK_B, TMP_B3                    \
                                                              \
  VPSUBQ.Z TMP_A3, TMP_A1, MASK_A, TMP_A3                     \
  VPSUBQ.Z TMP_B3, TMP_B1, MASK_B, TMP_B3                     \
                                                              \
  /* Prepare for the second division */                       \
  VCVTQQ2PD.Z TMP_A3, MASK_A, TMP_A3                          \
  VCVTQQ2PD.Z TMP_B3, MASK_B, TMP_B3                          \
                                                              \
  /* Second division step, corrects results from the first */ \
  VDIVPD.Z TMP_A4, TMP_A3, MASK_A, TMP_A3                     \
  VDIVPD.Z TMP_B4, TMP_B3, MASK_B, TMP_B3                     \
                                                              \
  VCVTPD2QQ.Z TMP_A3, MASK_A, TMP_A3                          \
  VCVTPD2QQ.Z TMP_B3, MASK_B, TMP_B3                          \
                                                              \
  VPADDQ.Z TMP_A3, TMP_A5, MASK_A, TMP_A5                     \
  VPADDQ.Z TMP_B3, TMP_B5, MASK_B, TMP_B5                     \
                                                              \
  /* Calculate the result by using the second remainder */    \
  VPMULLQ.Z TMP_A2, TMP_A5, MASK_A, TMP_A3                    \
  VPMULLQ.Z TMP_B2, TMP_B5, MASK_B, TMP_B3                    \
                                                              \
  /* Check whether we need to subtract 1 from the result */   \
  VPCMPUQ $VPCMP_IMM_GT, TMP_A1, TMP_A3, MASK_A, TMP_MASK_A   \
  VPCMPUQ $VPCMP_IMM_GT, TMP_B1, TMP_B3, MASK_B, TMP_MASK_B   \
                                                              \
  /* Subtract 1 from the result, if necessary */              \
  VPSUBQ.BCST CONSTQ_1(), TMP_A5, TMP_MASK_A, TMP_A5          \
  VPSUBQ.BCST CONSTQ_1(), TMP_B5, TMP_MASK_B, TMP_B5          \
                                                              \
  /* Calculate the mask of resulting negative results */      \
  VPMOVQ2M SRC_A1, TMP_MASK_A                                 \
  VPMOVQ2M SRC_B1, TMP_MASK_B                                 \
                                                              \
  /* Calculate the final remainder  */                        \
  VPMULLQ TMP_A2, TMP_A5, MASK_A, DST_A                       \
  VPMULLQ TMP_B2, TMP_B5, MASK_B, DST_B                       \
                                                              \
  VPSUBQ DST_A, TMP_A1, MASK_A, DST_A                         \
  VPSUBQ DST_B, TMP_B1, MASK_B, DST_B                         \
                                                              \
  /* Negate the result, if the result must be negative */     \
  VPXORQ TMP_A4, TMP_A4, TMP_A4                               \
  VPSUBQ DST_A, TMP_A4, TMP_MASK_A, DST_A                     \
  VPSUBQ DST_B, TMP_A4, TMP_MASK_B, DST_B

// Broadcast a constant (float)
TEXT bcbroadcastimmf(SB), NOSPLIT|NOFRAME, $0
  VBROADCASTSD 0(VIRT_PCREG), Z2
  VMOVDQA64 Z2, Z3
  NEXT_ADVANCE(8)

// Broadcast a constant (int)
TEXT bcbroadcastimmi(SB), NOSPLIT|NOFRAME, $0
  VPBROADCASTQ 0(VIRT_PCREG), Z2
  VMOVDQA64 Z2, Z3
  NEXT_ADVANCE(8)

// Unary operation - abs (float)
TEXT bcabsf(SB), NOSPLIT|NOFRAME, $0
  VBROADCASTSD  CONSTF64_SIGN_BIT(), Z4
  KSHIFTRW      $8, K1, K2
  VANDNPD       Z2, Z4, K1, Z2
  VANDNPD       Z3, Z4, K2, Z3
  NEXT()

// Unary operation - abs (int)
TEXT bcabsi(SB), NOSPLIT|NOFRAME, $0
  KSHIFTRW $8, K1, K2
  VPABSQ Z2, K1, Z2
  VPABSQ Z3, K2, Z3
  NEXT()

// Unary operation - neg (float)
TEXT bcnegf(SB), NOSPLIT|NOFRAME, $0
  KSHIFTRW      $8, K1, K2
  VXORPD        X4, X4, X4
  VSUBPD        Z2, Z4, K1, Z2
  VSUBPD        Z3, Z4, K2, Z3
  NEXT()

// Unary operation - neg (int)
TEXT bcnegi(SB), NOSPLIT|NOFRAME, $0
  KSHIFTRW      $8, K1, K2
  VPXORQ        X4, X4, X4
  VPSUBQ        Z2, Z4, K1, Z2
  VPSUBQ        Z3, Z4, K2, Z3
  NEXT()

// Unary operation - sign (float)
TEXT bcsignf(SB), NOSPLIT|NOFRAME, $0
  VBROADCASTSD  CONSTF64_SIGN_BIT(), Z4
  VBROADCASTSD  CONSTF64_1(), Z5
  VXORPD        X6, X6, X6
  KSHIFTRW      $8, K1, K2

  VCMPPD        $VCMP_IMM_NEQ_OQ, Z6, Z2, K1, K3
  VCMPPD        $VCMP_IMM_NEQ_OQ, Z6, Z3, K2, K4

  // Clear everything but signs, and combine with ones. This uses a {K3, K4}
  // write mask and would only update numbers that are not zeros nor NaNs.
  VPTERNLOGQ    $0xEA, Z5, Z4, K3, Z2 // Z2{K3} = (Z2 & Z4) | Z5
  VPTERNLOGQ    $0xEA, Z5, Z4, K4, Z3 // Z3{K4} = (Z3 & Z4) | Z5

  NEXT()

// Unary operation - sign (int)
TEXT bcsigni(SB), NOSPLIT|NOFRAME, $0
  KSHIFTRW $8, K1, K2
  VPMINSQ.BCST CONSTQ_1(), Z2, K1, Z2
  VPMINSQ.BCST CONSTQ_1(), Z3, K2, Z3
  VPMAXSQ.BCST CONSTQ_NEG_1(), Z2, K1, Z2
  VPMAXSQ.BCST CONSTQ_NEG_1(), Z3, K2, Z3
  NEXT()

// Unary operation - square (float)
TEXT bcsquaref(SB), NOSPLIT|NOFRAME, $0
  KSHIFTRW      $8, K1, K2
  VMULPD        Z2, Z2, K1, Z2
  VMULPD        Z3, Z3, K2, Z3
  NEXT()

// Unary operation - square (int)
TEXT bcsquarei(SB), NOSPLIT|NOFRAME, $0
  KSHIFTRW      $8, K1, K2
  VPMULLQ       Z2, Z2, K1, Z2
  VPMULLQ       Z3, Z3, K2, Z3
  NEXT()

// Unary operation - bit_not (int)
TEXT bcbitnoti(SB), NOSPLIT|NOFRAME, $0
  KSHIFTRW $8, K1, K2
  VPTERNLOGQ $0x01, Z2, Z2, K1, Z2
  VPTERNLOGQ $0x01, Z3, Z3, K2, Z3
  NEXT()

// Unary operation - bit_count (int)
TEXT bcbitcounti(SB), NOSPLIT|NOFRAME, $0
  KSHIFTRW $8, K1, K2

  VPBROADCASTB CONSTD_15(), Z10
  VPSRLQ $4, Z2, Z4
  VPSRLQ $4, Z3, Z5

  VBROADCASTI32X4 CONST_GET_PTR(popcnt_nibble_vpsadbw_pos, 0), Z11
  VPANDQ Z10, Z4, Z4
  VPANDQ Z10, Z5, Z5

  VBROADCASTI32X4 CONST_GET_PTR(popcnt_nibble_vpsadbw_neg, 0), Z12
  VPANDQ Z10, Z2, Z6
  VPANDQ Z10, Z3, Z7

  VPSHUFB Z4, Z11, Z4
  VPSHUFB Z6, Z12, Z6
  VPSHUFB Z5, Z11, Z5
  VPSHUFB Z7, Z12, Z7

  VPSADBW Z6, Z4, Z4
  VPSADBW Z7, Z5, Z5

  VMOVDQA64 Z4, K1, Z2
  VMOVDQA64 Z5, K2, Z3

  NEXT()

// Unary operation - rounding (float)
TEXT bcroundf(SB), NOSPLIT|NOFRAME, $0
  VBROADCASTSD CONSTF64_HALF(), Z4
  KSHIFTRW $8, K1, K2
  VMOVAPD Z4, Z5

  // 0xD8 <- (a & (~c)) | (b & c)
  VPTERNLOGQ.BCST $0xD8, CONSTF64_SIGN_BIT(), Z2, Z4
  VPTERNLOGQ.BCST $0xD8, CONSTF64_SIGN_BIT(), Z3, Z5

  // Equivalent to trunc(x + 0.5 * sign(x)) having the intermediate calculation truncated.
  VADDPD.RZ_SAE Z4, Z2, K1, Z2
  VADDPD.RZ_SAE Z5, Z3, K2, Z3

  VRNDSCALEPD $VROUND_IMM_TRUNC_SAE, Z2, K1, Z2
  VRNDSCALEPD $VROUND_IMM_TRUNC_SAE, Z3, K2, Z3

  NEXT()

TEXT bcroundevenf(SB), NOSPLIT|NOFRAME, $0
  KSHIFTRW      $8, K1, K2
  VRNDSCALEPD   $VROUND_IMM_NEAREST_SAE, Z2, K1, Z2
  VRNDSCALEPD   $VROUND_IMM_NEAREST_SAE, Z3, K2, Z3
  NEXT()

TEXT bctruncf(SB), NOSPLIT|NOFRAME, $0
  KSHIFTRW      $8, K1, K2
  VRNDSCALEPD   $VROUND_IMM_TRUNC_SAE, Z2, K1, Z2
  VRNDSCALEPD   $VROUND_IMM_TRUNC_SAE, Z3, K2, Z3
  NEXT()

TEXT bcfloorf(SB), NOSPLIT|NOFRAME, $0
  KSHIFTRW      $8, K1, K2
  VRNDSCALEPD   $VROUND_IMM_DOWN_SAE, Z2, K1, Z2
  VRNDSCALEPD   $VROUND_IMM_DOWN_SAE, Z3, K2, Z3
  NEXT()

TEXT bcceilf(SB), NOSPLIT|NOFRAME, $0
  KSHIFTRW      $8, K1, K2
  VRNDSCALEPD   $VROUND_IMM_UP_SAE, Z2, K1, Z2
  VRNDSCALEPD   $VROUND_IMM_UP_SAE, Z3, K2, Z3
  NEXT()

// Binary operation - add (float)
TEXT bcaddf(SB), NOSPLIT|NOFRAME, $0
  BC_ARITH_OP_VAR(VADDPD)
  NEXT_ADVANCE(2)

TEXT bcaddimmf(SB), NOSPLIT|NOFRAME, $0
  BC_ARITH_OP_IMM(VADDPD, VBROADCASTSD)
  NEXT_ADVANCE(8)

// Binary operation - add (int)
TEXT bcaddi(SB), NOSPLIT|NOFRAME, $0
  BC_ARITH_OP_VAR(VPADDQ)
  NEXT_ADVANCE(2)

TEXT bcaddimmi(SB), NOSPLIT|NOFRAME, $0
  BC_ARITH_OP_IMM(VPADDQ, VPBROADCASTQ)
  NEXT_ADVANCE(8)

// Binary operation - sub (float)
TEXT bcsubf(SB), NOSPLIT|NOFRAME, $0
  BC_ARITH_OP_VAR(VSUBPD)
  NEXT_ADVANCE(2)

TEXT bcsubimmf(SB), NOSPLIT|NOFRAME, $0
  BC_ARITH_OP_IMM(VSUBPD, VBROADCASTSD)
  NEXT_ADVANCE(8)

// Binary operation - sub (int)
TEXT bcsubi(SB), NOSPLIT|NOFRAME, $0
  BC_ARITH_OP_VAR(VPSUBQ)
  NEXT_ADVANCE(2)

TEXT bcsubimmi(SB), NOSPLIT|NOFRAME, $0
  BC_ARITH_OP_IMM(VPSUBQ, VPBROADCASTQ)
  NEXT_ADVANCE(8)

// Binary operation - rsub (float)
TEXT bcrsubf(SB), NOSPLIT|NOFRAME, $0
  BC_ARITH_REV_OP_VAR(VSUBPD)
  NEXT_ADVANCE(2)

TEXT bcrsubimmf(SB), NOSPLIT|NOFRAME, $0
  BC_ARITH_REV_OP_IMM(VSUBPD, VBROADCASTSD)
  NEXT_ADVANCE(8)

// Binary operation - rsub (int)
TEXT bcrsubi(SB), NOSPLIT|NOFRAME, $0
  BC_ARITH_REV_OP_VAR(VPSUBQ)
  NEXT_ADVANCE(2)

TEXT bcrsubimmi(SB), NOSPLIT|NOFRAME, $0
  BC_ARITH_REV_OP_IMM(VPSUBQ, VPBROADCASTQ)
  NEXT_ADVANCE(8)

// Binary operation - mul (float)
TEXT bcmulf(SB), NOSPLIT|NOFRAME, $0
  BC_ARITH_OP_VAR(VMULPD)
  NEXT_ADVANCE(2)

TEXT bcmulimmf(SB), NOSPLIT|NOFRAME, $0
  BC_ARITH_OP_IMM(VMULPD, VBROADCASTSD)
  NEXT_ADVANCE(8)

// Binary operation - mul (int)
TEXT bcmuli(SB), NOSPLIT|NOFRAME, $0
  BC_ARITH_OP_VAR(VPMULLQ)
  NEXT_ADVANCE(2)

TEXT bcmulimmi(SB), NOSPLIT|NOFRAME, $0
  BC_ARITH_OP_IMM(VPMULLQ, VPBROADCASTQ)
  NEXT_ADVANCE(8)

// Binary operation - div (float)
TEXT bcdivf(SB), NOSPLIT|NOFRAME, $0
  BC_ARITH_OP_VAR(VDIVPD)
  NEXT_ADVANCE(2)

TEXT bcdivimmf(SB), NOSPLIT|NOFRAME, $0
  BC_ARITH_OP_IMM(VDIVPD, VBROADCASTSD)
  NEXT_ADVANCE(8)

// Binary operation - rdiv (float)
TEXT bcrdivf(SB), NOSPLIT|NOFRAME, $0
  BC_ARITH_REV_OP_VAR(VDIVPD)
  NEXT_ADVANCE(2)

TEXT bcrdivimmf(SB), NOSPLIT|NOFRAME, $0
  BC_ARITH_REV_OP_IMM(VDIVPD, VBROADCASTSD)
  NEXT_ADVANCE(8)

// Binary operation - div (int)
TEXT bcdivi(SB), NOSPLIT|NOFRAME, $0
  MOVWQZX 0(VIRT_PCREG), R8
  ADDQ $2, VIRT_PCREG
  KSHIFTRW $8, K1, K2
  VMOVDQU64 0(VIRT_VALUES)(R8*1), Z4
  VMOVDQU64 64(VIRT_VALUES)(R8*1), Z5
  JMP divi_tail(SB)

TEXT bcdivimmi(SB), NOSPLIT|NOFRAME, $0
  VPBROADCASTQ 0(VIRT_PCREG), Z4
  KSHIFTRW $8, K1, K2
  ADDQ $8, VIRT_PCREG
  VMOVDQA64 Z4, Z5
  JMP divi_tail(SB)

TEXT divi_tail(SB), NOSPLIT|NOFRAME, $0
  BC_DIVI64_IMPL(Z2, Z3, Z2, Z3, Z4, Z5, K1, K2, Z6, Z7, Z8, Z9, Z10, Z11, Z12, Z13, Z14, Z15, K3, K4)
  NEXT()

// Binary operation - rdiv (int)
TEXT bcrdivi(SB), NOSPLIT|NOFRAME, $0
  MOVWQZX 0(VIRT_PCREG), R8
  ADDQ $2, VIRT_PCREG
  KSHIFTRW $8, K1, K2
  VMOVDQU64 0(VIRT_VALUES)(R8*1), Z4
  VMOVDQU64 64(VIRT_VALUES)(R8*1), Z5
  JMP rdivi_tail(SB)

TEXT bcrdivimmi(SB), NOSPLIT|NOFRAME, $0
  VPBROADCASTQ 0(VIRT_PCREG), Z4
  KSHIFTRW $8, K1, K2
  ADDQ $8, VIRT_PCREG
  VMOVDQA64 Z4, Z5
  JMP rdivi_tail(SB)

TEXT rdivi_tail(SB), NOSPLIT|NOFRAME, $0
  BC_DIVI64_IMPL(Z2, Z3, Z4, Z5, Z2, Z3, K1, K2, Z6, Z7, Z8, Z9, Z10, Z11, Z12, Z13, Z14, Z15, K3, K4)
  NEXT()

// Binary operation - mod (float):
TEXT bcmodf(SB), NOSPLIT|NOFRAME, $0
  MOVWQZX       0(VIRT_PCREG), R8
  KSHIFTRW      $8, K1, K2
  VMOVUPD       0(VIRT_VALUES)(R8*1), Z4
  VMOVUPD       64(VIRT_VALUES)(R8*1), Z5
  BC_MODF64_OP(Z2, Z3, Z4, Z5, Z6, Z7)
  NEXT_ADVANCE(2)

TEXT bcmodimmf(SB), NOSPLIT|NOFRAME, $0
  VBROADCASTSD  0(VIRT_PCREG), Z4
  KSHIFTRW      $8, K1, K2
  BC_MODF64_OP(Z2, Z3, Z4, Z4, Z6, Z7)
  NEXT_ADVANCE(8)

// Binary operation - rmod (float):
TEXT bcrmodf(SB), NOSPLIT|NOFRAME, $0
  MOVWQZX       0(VIRT_PCREG), R8
  KSHIFTRW      $8, K1, K2
  VMOVAPD       Z2, Z4
  VMOVAPD       Z3, Z5
  VMOVUPD       0(VIRT_VALUES)(R8*1), Z2
  VMOVUPD       64(VIRT_VALUES)(R8*1), Z3
  BC_MODF64_OP(Z2, Z3, Z4, Z5, Z6, Z7)
  NEXT_ADVANCE(2)

TEXT bcrmodimmf(SB), NOSPLIT|NOFRAME, $0
  VMOVAPD       Z2, Z4
  VMOVAPD       Z3, Z5
  VBROADCASTSD  0(VIRT_PCREG), Z2
  VBROADCASTSD  0(VIRT_PCREG), Z3
  KSHIFTRW      $8, K1, K2
  BC_MODF64_OP(Z2, Z3, Z4, Z5, Z6, Z7)
  NEXT_ADVANCE(8)

// Binary operation - mod (int):
TEXT bcmodi(SB), NOSPLIT|NOFRAME, $0
  MOVWQZX 0(VIRT_PCREG), R8
  ADDQ $2, VIRT_PCREG
  KSHIFTRW $8, K1, K2
  VMOVDQU64 0(VIRT_VALUES)(R8*1), Z4
  VMOVDQU64 64(VIRT_VALUES)(R8*1), Z5
  JMP modi_tail(SB)

TEXT bcmodimmi(SB), NOSPLIT|NOFRAME, $0
  VPBROADCASTQ 0(VIRT_PCREG), Z4
  KSHIFTRW $8, K1, K2
  ADDQ $8, VIRT_PCREG
  VMOVDQA64 Z4, Z5
  JMP modi_tail(SB)

TEXT modi_tail(SB), NOSPLIT|NOFRAME, $0
  BC_MODI64_IMPL(Z2, Z3, Z2, Z3, Z4, Z5, K1, K2, Z6, Z7, Z8, Z9, Z10, Z11, Z12, Z13, Z14, Z15, K3, K4)
  NEXT()

// Binary operation - rmod (int):
TEXT bcrmodi(SB), NOSPLIT|NOFRAME, $0
  MOVWQZX 0(VIRT_PCREG), R8
  ADDQ $2, VIRT_PCREG
  KSHIFTRW $8, K1, K2
  VMOVDQU64 0(VIRT_VALUES)(R8*1), Z4
  VMOVDQU64 64(VIRT_VALUES)(R8*1), Z5
  JMP rmodi_tail(SB)

TEXT bcrmodimmi(SB), NOSPLIT|NOFRAME, $0
  VPBROADCASTQ 0(VIRT_PCREG), Z4
  KSHIFTRW $8, K1, K2
  ADDQ $8, VIRT_PCREG
  VMOVDQA64 Z4, Z5
  JMP rmodi_tail(SB)

TEXT rmodi_tail(SB), NOSPLIT|NOFRAME, $0
  BC_MODI64_IMPL(Z2, Z3, Z4, Z5, Z2, Z3, K1, K2, Z6, Z7, Z8, Z9, Z10, Z11, Z12, Z13, Z14, Z15, K3, K4)
  NEXT()

// Arithmetic muladd (int)
TEXT bcaddmulimmi(SB), NOSPLIT|NOFRAME, $0
  MOVWQZX 0(VIRT_PCREG), R8
  VPBROADCASTQ 2(VIRT_PCREG), Z5
  KSHIFTRW $8, K1, K2
  VPMULLQ 0(VIRT_VALUES)(R8*1), Z5, Z4
  VPMULLQ 64(VIRT_VALUES)(R8*1), Z5, Z5
  VPADDQ Z4, Z2, K1, Z2
  VPADDQ Z5, Z3, K2, Z3
  NEXT_ADVANCE(10)

// Binary operation - min/max (float)
TEXT bcminvaluef(SB), NOSPLIT|NOFRAME, $0
  BC_ARITH_OP_VAR(VMINPD)
  NEXT_ADVANCE(2)

TEXT bcminvalueimmf(SB), NOSPLIT|NOFRAME, $0
  BC_ARITH_OP_IMM(VMINPD, VBROADCASTSD)
  NEXT_ADVANCE(8)

TEXT bcmaxvaluef(SB), NOSPLIT|NOFRAME, $0
  BC_ARITH_OP_VAR(VMAXPD)
  NEXT_ADVANCE(2)

TEXT bcmaxvalueimmf(SB), NOSPLIT|NOFRAME, $0
  BC_ARITH_OP_IMM(VMAXPD, VBROADCASTSD)
  NEXT_ADVANCE(8)

// Binary operation - min/max (int)
TEXT bcminvaluei(SB), NOSPLIT|NOFRAME, $0
  BC_ARITH_OP_VAR(VPMINSQ)
  NEXT_ADVANCE(2)

TEXT bcminvalueimmi(SB), NOSPLIT|NOFRAME, $0
  BC_ARITH_OP_IMM(VPMINSQ, VPBROADCASTQ)
  NEXT_ADVANCE(8)

TEXT bcmaxvaluei(SB), NOSPLIT|NOFRAME, $0
  BC_ARITH_OP_VAR(VPMAXSQ)
  NEXT_ADVANCE(2)

TEXT bcmaxvalueimmi(SB), NOSPLIT|NOFRAME, $0
  BC_ARITH_OP_IMM(VPMAXSQ, VPBROADCASTQ)
  NEXT_ADVANCE(8)

// Binary operation - bitwise AND (int)
TEXT bcandi(SB), NOSPLIT|NOFRAME, $0
  BC_ARITH_OP_VAR(VPANDQ)
  NEXT_ADVANCE(2)

TEXT bcandimmi(SB), NOSPLIT|NOFRAME, $0
  BC_ARITH_OP_IMM(VPANDQ, VPBROADCASTQ)
  NEXT_ADVANCE(8)

// Binary operation - bitwise OR (int)
TEXT bcori(SB), NOSPLIT|NOFRAME, $0
  BC_ARITH_OP_VAR(VPORQ)
  NEXT_ADVANCE(2)

TEXT bcorimmi(SB), NOSPLIT|NOFRAME, $0
  BC_ARITH_OP_IMM(VPORQ, VPBROADCASTQ)
  NEXT_ADVANCE(8)

// Binary operation - bitwise XOR (int)
TEXT bcxori(SB), NOSPLIT|NOFRAME, $0
  BC_ARITH_OP_VAR(VPXORQ)
  NEXT_ADVANCE(2)

TEXT bcxorimmi(SB), NOSPLIT|NOFRAME, $0
  BC_ARITH_OP_IMM(VPXORQ, VPBROADCASTQ)
  NEXT_ADVANCE(8)

// Binary operation - shift left logical (int)
TEXT bcslli(SB), NOSPLIT|NOFRAME, $0
  BC_ARITH_OP_VAR(VPSLLVQ)
  NEXT_ADVANCE(2)

TEXT bcsllimmi(SB), NOSPLIT|NOFRAME, $0
  BC_ARITH_OP_IMM(VPSLLVQ, VPBROADCASTQ)
  NEXT_ADVANCE(8)

// Binary operation - shift right arithmetic (int)
TEXT bcsrai(SB), NOSPLIT|NOFRAME, $0
  BC_ARITH_OP_VAR(VPSRAVQ)
  NEXT_ADVANCE(2)

TEXT bcsraimmi(SB), NOSPLIT|NOFRAME, $0
  BC_ARITH_OP_IMM(VPSRAVQ, VPBROADCASTQ)
  NEXT_ADVANCE(8)

// Binary operation - shift right logical (int)
TEXT bcsrli(SB), NOSPLIT|NOFRAME, $0
  BC_ARITH_OP_VAR(VPSRLVQ)
  NEXT_ADVANCE(2)

TEXT bcsrlimmi(SB), NOSPLIT|NOFRAME, $0
  BC_ARITH_OP_IMM(VPSRLVQ, VPBROADCASTQ)
  NEXT_ADVANCE(8)

// Math Functions
// --------------

// Square root: sqrt(x)
TEXT bcsqrtf(SB), NOSPLIT|NOFRAME, $0
  KSHIFTRW      $8, K1, K2
  VSQRTPD       Z2, K1, Z2
  VSQRTPD       Z3, K2, Z3
  NEXT()

// Cube root: cbrt(x)
CONST_DATA_U64(const_cbrt,   0, $0x40b8000000000000) // f64(6144)
CONST_DATA_U64(const_cbrt,   8, $0x3fd5555555555555) // f64(0.33333333333333331)
CONST_DATA_U64(const_cbrt,  16, $0xc008000000000000) // f64(-3)
CONST_DATA_U64(const_cbrt,  24, $0x3ff428a2f98d728b) // i64(4608352999143469707)
CONST_DATA_U64(const_cbrt,  32, $0x3ff965fea53d6e3d) // i64(4609827837958778429)
CONST_DATA_U64(const_cbrt,  40, $0xbc7ddc22548ea41e) // i64(-4864489982484634594)
CONST_DATA_U64(const_cbrt,  48, $0xbc9f53e999952f09) // i64(-4855069610512929015)
CONST_DATA_U64(const_cbrt,  56, $0xbfe47ce4f76bed42) // f64(-0.64024589848069291)
CONST_DATA_U64(const_cbrt,  64, $0x4007b141aaa12a9c) // f64(2.9615510302003951)
CONST_DATA_U64(const_cbrt,  72, $0xc016ef22a5e505b3) // f64(-5.7335306092294784)
CONST_DATA_U64(const_cbrt,  80, $0x401828dc834c5911) // f64(6.0399036898945875)
CONST_DATA_U64(const_cbrt,  88, $0xc00ede0af7836a8b) // f64(-3.8584193551044499)
CONST_DATA_U64(const_cbrt,  96, $0x4001d887ace5ac54) // f64(2.230727530249661)
CONST_DATA_U64(const_cbrt, 104, $0xbfe5555555555555) // f64(-0.66666666666666663)
CONST_DATA_U32(const_cbrt, 112, $0x3ff00000) // i32(1072693248)
CONST_DATA_U32(const_cbrt, 116, $0x1) // i32(1)
CONST_DATA_U32(const_cbrt, 120, $0x2) // i32(2)
CONST_DATA_U32(const_cbrt, 124, $0xfffff800) // i32(4294965248)
CONST_GLOBAL(const_cbrt, $128)

TEXT bccbrtf(SB), NOSPLIT|NOFRAME, $0
  KTESTW K1, K1
  JZ next

  MOVL $0xAAAA, R8

  // Process Z2 (initial 8 lanes).
  VBROADCASTSD CONSTF64_ABS_BITS(), Z10
  VPANDQ Z10, Z2, Z6
  VGETEXPPD Z6, Z4
  VXORPD X5, X5, X5
  VCVTPD2DQ.RN_SAE Z4, Y7
  VPCMPEQD Y4, Y4, Y4
  VPSUBD Y4, Y7, Y8
  VPTERNLOGQ $15, Z7, Z7, Z7
  VPSRAD $1, Y7, Y9
  VPBROADCASTD CONST_GET_PTR(const_cbrt, 112), Y4
  VPSLLD $20, Y9, Y11
  VPADDD Y4, Y11, Y11
  KMOVW R8, K2
  VPEXPANDD.Z Z11, K2, Z11
  VMULPD Z2, Z11, Z11
  VPSUBD Y9, Y7, Y7
  VPSLLD $20, Y7, Y7
  VPADDD Y4, Y7, Y7
  VCVTDQ2PD Y8, Z8
  VADDPD.BCST CONST_GET_PTR(const_cbrt, 0), Z8, Z8
  VPEXPANDD.Z Z7, K2, Z9
  VBROADCASTSD CONST_GET_PTR(const_cbrt, 8), Z12
  VMULPD Z12, Z8, Z7
  VCVTPD2DQ.RZ_SAE Z7, Y7
  VCVTDQ2PD Y7, Z13
  VMULPD Z9, Z11, Z11
  VMULPD.BCST CONST_GET_PTR(const_cbrt, 16), Z13, Z9
  VADDPD Z9, Z8, Z8
  VCVTPD2DQ.RZ_SAE Z8, Y8
  VPCMPEQD.BCST CONST_GET_PTR(const_cbrt, 116), Y8, K3
  VPCMPEQD.BCST CONST_GET_PTR(const_cbrt, 120), Y8, K4
  VBROADCASTSD CONSTF64_1(), Z9
  VBROADCASTSD CONST_GET_PTR(const_cbrt, 24), K3, Z9
  VBROADCASTSD CONST_GET_PTR(const_cbrt, 32), K4, Z9
  VBROADCASTSD CONSTF64_SIGN_BIT(), Z8
  VPANDQ Z8, Z11, Z13
  VPORQ Z9, Z13, Z9
  VBROADCASTSD.Z CONST_GET_PTR(const_cbrt, 40), K3, Z14
  VBROADCASTSD CONST_GET_PTR(const_cbrt, 48), K4, Z14
  VPXORQ Z14, Z13, Z13
  VPANDQ Z10, Z11, Z10
  VBROADCASTSD CONST_GET_PTR(const_cbrt, 56), Z11
  VFMADD213PD.BCST CONST_GET_PTR(const_cbrt, 64), Z10, Z11 // Z11 = (Z10 * Z11) + mem
  VFMADD213PD.BCST CONST_GET_PTR(const_cbrt, 72), Z10, Z11 // Z11 = (Z10 * Z11) + mem
  VFMADD213PD.BCST CONST_GET_PTR(const_cbrt, 80), Z10, Z11 // Z11 = (Z10 * Z11) + mem
  VFMADD213PD.BCST CONST_GET_PTR(const_cbrt, 88), Z10, Z11 // Z11 = (Z10 * Z11) + mem
  VFMADD213PD.BCST CONST_GET_PTR(const_cbrt, 96), Z10, Z11 // Z11 = (Z10 * Z11) + mem
  VMULPD Z11, Z11, Z14
  VMULPD Z14, Z14, Z14
  VFMSUB213PD Z11, Z10, Z14 // Z14 = (Z10 * Z14) - Z11
  VMULPD Z12, Z14, Z12
  VSUBPD Z12, Z11, Z11
  VMULPD Z11, Z11, Z12
  VMOVAPD Z11, Z14
  VFMSUB213PD Z12, Z11, Z14 // Z14 = (Z11 * Z14) - Z12
  VMULPD Z12, Z12, Z15
  VMOVAPD Z12, Z16
  VFMSUB213PD Z15, Z12, Z16 // Z16 = (Z12 * Z16) - Z15
  VFMADD231PD Z12, Z14, Z16 // Z16 = (Z14 * Z12) + Z16
  VFMADD231PD Z14, Z12, Z16 // Z16 = (Z12 * Z14) + Z16
  VMULPD Z10, Z15, Z17
  VFMSUB213PD Z17, Z10, Z15 // Z15 = (Z10 * Z15) - Z17
  VFMADD231PD Z16, Z10, Z15 // Z15 = (Z10 * Z16) + Z15
  VPXORQ.BCST CONSTF64_SIGN_BIT(), Z11, Z16
  VSUBPD Z11, Z17, Z18
  VSUBPD Z17, Z18, Z19
  VSUBPD Z19, Z18, Z20
  VSUBPD Z20, Z17, Z17
  VSUBPD Z19, Z16, Z16
  VADDPD Z17, Z16, Z16
  VADDPD Z16, Z15, Z15
  VADDPD Z15, Z18, Z15
  VMULPD.BCST CONST_GET_PTR(const_cbrt, 104), Z15, Z15
  VMULPD Z15, Z11, Z11
  VADDPD Z11, Z12, Z15
  VSUBPD Z12, Z15, Z16
  VSUBPD Z16, Z15, Z17
  VSUBPD Z17, Z12, Z12
  VSUBPD Z16, Z11, Z11
  VADDPD Z12, Z11, Z11
  VADDPD Z11, Z14, Z11
  VMULPD Z10, Z15, Z12
  VFMSUB213PD Z12, Z10, Z15 // Z15 = (Z10 * Z15) - Z12
  VFMADD231PD Z11, Z10, Z15 // Z15 = (Z10 * Z11) + Z15
  VMULPD Z9, Z12, Z10
  VMOVAPD Z9, Z11
  VFMSUB213PD Z10, Z12, Z11 // Z11 = (Z12 * Z11) - Z10
  VFMADD231PD Z15, Z9, Z11  // Z11 = (Z9 * Z15) + Z11
  VFMADD231PD Z13, Z12, Z11 // Z11 = (Z12 * Z13) + Z11
  VADDPD Z11, Z10, Z9
  VPBROADCASTD CONST_GET_PTR(const_cbrt, 124), Y10
  VPADDD Y10, Y7, Y7
  VPSRAD $1, Y7, Y10
  VPSLLD $20, Y10, Y11
  VPADDD Y4, Y11, Y11
  VPEXPANDD.Z Z11, K2, Z11
  VMULPD Z11, Z9, Z9
  VPSUBD Y10, Y7, Y7
  VPSLLD $20, Y7, Y7
  VPADDD Y4, Y7, Y4
  VPEXPANDD.Z Z4, K2, Z4
  VMULPD Z4, Z9, Z4
  VCMPPD.BCST $VCMP_IMM_EQ_OQ, CONSTF64_POSITIVE_INF(), Z6, K2
  VPANDQ Z8, Z2, Z6
  VPORQ.BCST CONSTF64_POSITIVE_INF(), Z6, K2, Z4
  VCMPPD $VCMP_IMM_EQ_OQ, Z5, Z2, K2
  VPANDQ Z8, Z2, K2, Z4
  VMOVDQA64 Z4, Z2

  // Process Z3 (remaining 8 lanes).
  VBROADCASTSD CONSTF64_ABS_BITS(), Z10
  VPANDQ Z10, Z3, Z6
  VGETEXPPD Z6, Z4
  VXORPD X5, X5, X5
  VCVTPD2DQ.RN_SAE Z4, Y7
  VPCMPEQD Y4, Y4, Y4
  VPSUBD Y4, Y7, Y8
  VPTERNLOGQ $15, Z7, Z7, Z7
  VPSRAD $1, Y7, Y9
  VPBROADCASTD CONST_GET_PTR(const_cbrt, 112), Y4
  VPSLLD $20, Y9, Y11
  VPADDD Y4, Y11, Y11
  KMOVW R8, K2
  VPEXPANDD.Z Z11, K2, Z11
  VMULPD Z3, Z11, Z11
  VPSUBD Y9, Y7, Y7
  VPSLLD $20, Y7, Y7
  VPADDD Y4, Y7, Y7
  VCVTDQ2PD Y8, Z8
  VADDPD.BCST CONST_GET_PTR(const_cbrt, 0), Z8, Z8
  VPEXPANDD.Z Z7, K2, Z9
  VBROADCASTSD CONST_GET_PTR(const_cbrt, 8), Z12
  VMULPD Z12, Z8, Z7
  VCVTPD2DQ.RZ_SAE Z7, Y7
  VCVTDQ2PD Y7, Z13
  VMULPD Z9, Z11, Z11
  VMULPD.BCST CONST_GET_PTR(const_cbrt, 16), Z13, Z9
  VADDPD Z9, Z8, Z8
  VCVTPD2DQ.RZ_SAE Z8, Y8
  VPCMPEQD.BCST CONST_GET_PTR(const_cbrt, 116), Y8, K3
  VPCMPEQD.BCST CONST_GET_PTR(const_cbrt, 120), Y8, K4
  VBROADCASTSD CONSTF64_1(), Z9
  VBROADCASTSD CONST_GET_PTR(const_cbrt, 24), K3, Z9
  VBROADCASTSD CONST_GET_PTR(const_cbrt, 32), K4, Z9
  VBROADCASTSD CONSTF64_SIGN_BIT(), Z8
  VPANDQ Z8, Z11, Z13
  VPORQ Z9, Z13, Z9
  VBROADCASTSD.Z CONST_GET_PTR(const_cbrt, 40), K3, Z14
  VBROADCASTSD CONST_GET_PTR(const_cbrt, 48), K4, Z14
  VPXORQ Z14, Z13, Z13
  VPANDQ Z10, Z11, Z10
  VBROADCASTSD CONST_GET_PTR(const_cbrt, 56), Z11
  VFMADD213PD.BCST CONST_GET_PTR(const_cbrt, 64), Z10, Z11 // Z11 = (Z10 * Z11) + mem
  VFMADD213PD.BCST CONST_GET_PTR(const_cbrt, 72), Z10, Z11 // Z11 = (Z10 * Z11) + mem
  VFMADD213PD.BCST CONST_GET_PTR(const_cbrt, 80), Z10, Z11 // Z11 = (Z10 * Z11) + mem
  VFMADD213PD.BCST CONST_GET_PTR(const_cbrt, 88), Z10, Z11 // Z11 = (Z10 * Z11) + mem
  VFMADD213PD.BCST CONST_GET_PTR(const_cbrt, 96), Z10, Z11 // Z11 = (Z10 * Z11) + mem
  VMULPD Z11, Z11, Z14
  VMULPD Z14, Z14, Z14
  VFMSUB213PD Z11, Z10, Z14 // Z14 = (Z10 * Z14) - Z11
  VMULPD Z12, Z14, Z12
  VSUBPD Z12, Z11, Z11
  VMULPD Z11, Z11, Z12
  VMOVAPD Z11, Z14
  VFMSUB213PD Z12, Z11, Z14 // Z14 = (Z11 * Z14) - Z12
  VMULPD Z12, Z12, Z15
  VMOVAPD Z12, Z16
  VFMSUB213PD Z15, Z12, Z16 // Z16 = (Z12 * Z16) - Z15
  VFMADD231PD Z12, Z14, Z16 // Z16 = (Z14 * Z12) + Z16
  VFMADD231PD Z14, Z12, Z16 // Z16 = (Z12 * Z14) + Z16
  VMULPD Z10, Z15, Z17
  VFMSUB213PD Z17, Z10, Z15 // Z15 = (Z10 * Z15) - Z17
  VFMADD231PD Z16, Z10, Z15 // Z15 = (Z10 * Z16) + Z15
  VPXORQ.BCST CONSTF64_SIGN_BIT(), Z11, Z16
  VSUBPD Z11, Z17, Z18
  VSUBPD Z17, Z18, Z19
  VSUBPD Z19, Z18, Z20
  VSUBPD Z20, Z17, Z17
  VSUBPD Z19, Z16, Z16
  VADDPD Z17, Z16, Z16
  VADDPD Z16, Z15, Z15
  VADDPD Z15, Z18, Z15
  VMULPD.BCST CONST_GET_PTR(const_cbrt, 104), Z15, Z15
  VMULPD Z15, Z11, Z11
  VADDPD Z11, Z12, Z15
  VSUBPD Z12, Z15, Z16
  VSUBPD Z16, Z15, Z17
  VSUBPD Z17, Z12, Z12
  VSUBPD Z16, Z11, Z11
  VADDPD Z12, Z11, Z11
  VADDPD Z11, Z14, Z11
  VMULPD Z10, Z15, Z12
  VFMSUB213PD Z12, Z10, Z15 // Z15 = (Z10 * Z15) - Z12
  VFMADD231PD Z11, Z10, Z15 // Z15 = (Z10 * Z11) + Z15
  VMULPD Z9, Z12, Z10
  VMOVAPD Z9, Z11
  VFMSUB213PD Z10, Z12, Z11 // Z11 = (Z12 * Z11) - Z10
  VFMADD231PD Z15, Z9, Z11  // Z11 = (Z9 * Z15) + Z11
  VFMADD231PD Z13, Z12, Z11 // Z11 = (Z12 * Z13) + Z11
  VADDPD Z11, Z10, Z9
  VPBROADCASTD CONST_GET_PTR(const_cbrt, 124), Y10
  VPADDD Y10, Y7, Y7
  VPSRAD $1, Y7, Y10
  VPSLLD $20, Y10, Y11
  VPADDD Y4, Y11, Y11
  VPEXPANDD.Z Z11, K2, Z11
  VMULPD Z11, Z9, Z9
  VPSUBD Y10, Y7, Y7
  VPSLLD $20, Y7, Y7
  VPADDD Y4, Y7, Y4
  VPEXPANDD.Z Z4, K2, Z4
  VMULPD Z4, Z9, Z4
  VCMPPD.BCST $VCMP_IMM_EQ_OQ, CONSTF64_POSITIVE_INF(), Z6, K2
  VPANDQ Z8, Z3, Z6
  VPORQ.BCST CONSTF64_POSITIVE_INF(), Z6, K2, Z4
  VCMPPD $VCMP_IMM_EQ_OQ, Z5, Z3, K2
  VPANDQ Z8, Z3, K2, Z4
  VMOVDQA64 Z4, Z3

next:
  NEXT()

// Exponential: exp(x)
CONST_DATA_U64(const_exp,   0, $0x3ff71547652b82fe) // f64(1.4426950408889634)
CONST_DATA_U64(const_exp,   8, $0xbfe62e42fefa3000) // f64(-0.69314718055966296)
CONST_DATA_U64(const_exp,  16, $0xbd53de6af278ece6) // f64(-2.8235290563031577E-13)
CONST_DATA_U64(const_exp,  24, $0x3e21e0c670afff06) // f64(2.0812763782371645E-9)
CONST_DATA_U64(const_exp,  32, $0x3e5af6c36f75740c) // f64(2.511210703042288E-8)
CONST_DATA_U64(const_exp,  40, $0x3e927e5d38a23654) // f64(2.7557626281694912E-7)
CONST_DATA_U64(const_exp,  48, $0x3ec71ddef633fb47) // f64(2.7557234020253882E-6)
CONST_DATA_U64(const_exp,  56, $0x3efa01a0127f883a) // f64(2.4801586874796863E-5)
CONST_DATA_U64(const_exp,  64, $0x3f2a01a01b4421fd) // f64(1.9841269898558658E-4)
CONST_DATA_U64(const_exp,  72, $0x3f56c16c16c3396b) // f64(0.0013888888889144978)
CONST_DATA_U64(const_exp,  80, $0x3f8111111110e7a5) // f64(0.0083333333333149382)
CONST_DATA_U64(const_exp,  88, $0x3fa55555555554f9) // f64(0.041666666666666026)
CONST_DATA_U64(const_exp,  96, $0x3fc555555555555e) // f64(0.16666666666666691)
CONST_DATA_U64(const_exp, 104, $0x40862e42fe102c83) // f64(709.78271114955749)
CONST_DATA_U64(const_exp, 112, $0xc08f400000000000) // f64(-1000)
CONST_DATA_U32(const_exp, 120, $0x3ff00000) // i32(1072693248)
CONST_GLOBAL(const_exp, $124)

TEXT bcexpf(SB), NOSPLIT|NOFRAME, $0
  KTESTW K1, K1
  JZ next

  MOVL $0xAAAA, R8
  KSHIFTRW $8, K1, K2
  KMOVW R8, K3

  VBROADCASTSD CONST_GET_PTR(const_exp, 0), Z9
  VBROADCASTSD CONST_GET_PTR(const_exp, 8), Z8
  VBROADCASTSD CONST_GET_PTR(const_exp, 24), Z10
  VBROADCASTSD CONST_GET_PTR(const_exp, 16), Z11

  VMULPD Z9, Z2, Z4
  VMULPD Z9, Z3, Z5
  VRNDSCALEPD $8, Z4, Z6
  VRNDSCALEPD $8, Z5, Z7
  VCVTPD2DQ.RN_SAE Z6, Y4
  VCVTPD2DQ.RN_SAE Z7, Y5
  VINSERTI32X8 $1, Y5, Z4, Z4

  VMOVAPD Z8, Z9
  VFMADD213PD Z2, Z6, Z8 // Z8 = (Z6 * Z8) + Z2
  VFMADD213PD Z3, Z7, Z9 // Z9 = (Z7 * Z9) + Z3
  VFMADD231PD Z11, Z6, Z8 // Z8 = (Z6 * Z11) + Z8
  VFMADD231PD Z11, Z7, Z9 // Z9 = (Z7 * Z11) + Z9
  VMULPD Z8, Z8, Z6
  VMULPD Z9, Z9, Z7
  VBROADCASTSD CONST_GET_PTR(const_exp, 32), Z5
  VMOVAPD Z10, Z11
  VFMADD213PD Z5, Z8, Z10 // Z10 = (Z8 * Z10) + Z5
  VFMADD213PD Z5, Z9, Z11 // Z11 = (Z9 * Z11) + Z5
  VBROADCASTSD CONST_GET_PTR(const_exp, 48), Z5
  VBROADCASTSD CONST_GET_PTR(const_exp, 40), Z12
  VBROADCASTSD CONST_GET_PTR(const_exp, 56), Z14
  VMOVAPD Z12, Z13
  VMOVAPD Z14, Z15
  VFMADD213PD Z5, Z8, Z12 // Z12 = (Z8 * Z12) + Z5
  VFMADD213PD Z5, Z9, Z13 // Z13 = (Z9 * Z13) + Z5
  VBROADCASTSD CONST_GET_PTR(const_exp, 64), Z5
  VMULPD Z6, Z6, Z16
  VMULPD Z7, Z7, Z17
  VFMADD213PD Z5, Z8, Z14 // Z14 = (Z8 * Z14) + Z5
  VFMADD213PD Z5, Z9, Z15 // Z15 = (Z9 * Z15) + Z5
  VFMADD231PD Z12, Z6, Z14 // Z14 = (Z6 * Z12) + Z14
  VFMADD231PD Z13, Z7, Z15 // Z15 = (Z7 * Z13) + Z15

  VBROADCASTSD CONST_GET_PTR(const_exp, 80), Z5
  VBROADCASTSD CONST_GET_PTR(const_exp, 72), Z12
  VMOVAPD Z12, Z13
  VFMADD213PD Z5, Z8, Z12 // Z12 = (Z8 * Z12) + Z5
  VFMADD213PD Z5, Z9, Z13 // Z13 = (Z9 * Z13) + Z5
  VBROADCASTSD CONST_GET_PTR(const_exp, 96), Z5
  VBROADCASTSD CONST_GET_PTR(const_exp, 88), Z18
  VMOVAPD Z18, Z19
  VFMADD213PD Z5, Z8, Z18 // Z18 = (Z8 * Z18) + Z5
  VFMADD213PD Z5, Z9, Z19 // Z19 = (Z9 * Z19) + Z5
  VMULPD Z16, Z16, Z20
  VMULPD Z17, Z17, Z21
  VBROADCASTSD CONSTF64_HALF(), Z5
  VFMADD231PD Z12, Z6, Z18  // Z18 = (Z6 * Z12) + Z18
  VFMADD231PD Z13, Z7, Z19  // Z19 = (Z7 * Z13) + Z19
  VFMADD231PD Z14, Z16, Z18 // Z18 = (Z16 * Z14) + Z18
  VFMADD231PD Z15, Z17, Z19 // Z19 = (Z17 * Z15) + Z19
  VFMADD231PD Z10, Z20, Z18 // Z18 = (Z20 * Z10) + Z18
  VFMADD231PD Z11, Z21, Z19 // Z19 = (Z21 * Z11) + Z19
  VBROADCASTSD CONSTF64_1(), Z6
  VFMADD213PD Z5, Z8, Z18 // Z18 = (Z8 * Z18) + Z5{0.5}
  VFMADD213PD Z5, Z9, Z19 // Z19 = (Z9 * Z19) + Z5{0.5}
  VFMADD213PD Z6, Z8, Z18 // Z18 = (Z8 * Z18) + Z6{1.0}
  VFMADD213PD Z6, Z9, Z19 // Z19 = (Z9 * Z19) + Z6{1.0}
  VFMADD213PD Z6, Z8, Z18 // Z18 = (Z8 * Z18) + Z6{1.0}
  VFMADD213PD Z6, Z9, Z19 // Z19 = (Z9 * Z19) + Z6{1.0}

  VPSRAD $1, Z4, Z6
  VPSLLD $20, Z6, Z8
  VPBROADCASTD CONST_GET_PTR(const_exp, 120), Z10
  VPADDD Z10, Z8, Z8
  VEXTRACTI32X8 $1, Z8, Y9
  VPEXPANDD.Z Z8, K3, Z8
  VPEXPANDD.Z Z9, K3, Z9

  VMULPD Z8, Z18, Z8
  VMULPD Z9, Z19, Z9
  VPSUBD Z6, Z4, Z4
  VPSLLD $20, Z4, Z4
  VPADDD Z10, Z4, Z4
  VEXTRACTI32X8 $1, Z4, Y5
  VPEXPANDD.Z Z4, K3, Z4
  VPEXPANDD.Z Z5, K3, Z5

  VMULPD Z4, Z8, Z4
  VMULPD Z5, Z9, Z5

  VBROADCASTSD CONST_GET_PTR(const_exp, 104), Z10
  VBROADCASTSD CONST_GET_PTR(const_exp, 112), Z11
  VBROADCASTSD CONSTF64_POSITIVE_INF(), Z12
  VCMPPD $VCMP_IMM_GT_OS, Z10, Z2, K1, K3
  VCMPPD $VCMP_IMM_GT_OS, Z10, Z3, K2, K4
  VCMPPD $VCMP_IMM_NLT_US, Z11, Z2, K1, K5
  VCMPPD $VCMP_IMM_NLT_US, Z11, Z3, K2, K6

  VMOVAPD Z12, K3, Z4
  VMOVAPD Z12, K4, Z5
  VMOVAPD.Z Z4, K5, Z4
  VMOVAPD.Z Z5, K6, Z5

  VMOVAPD Z4, K1, Z2
  VMOVAPD Z5, K1, Z3

next:
  NEXT()

// Base-2 exponential: exp2(x)
CONST_DATA_U64(const_exp2,   0, $0x3dfe7901ca95e150) // f64(4.4343590829265295E-10)
CONST_DATA_U64(const_exp2,   8, $0x3e3e6106d72c1c17) // f64(7.0731645980857074E-9)
CONST_DATA_U64(const_exp2,  16, $0x3e7b5266946bf979) // f64(1.0178192609217605E-7)
CONST_DATA_U64(const_exp2,  24, $0x3eb62bfcdabcbb81) // f64(1.3215438725113276E-6)
CONST_DATA_U64(const_exp2,  32, $0x3eeffcbfbc12cc80) // f64(1.5252733535175847E-5)
CONST_DATA_U64(const_exp2,  40, $0x3f24309130cb34ec) // f64(1.5403530451011478E-4)
CONST_DATA_U64(const_exp2,  48, $0x3f55d87fe78c5960) // f64(0.0013333558146704991)
CONST_DATA_U64(const_exp2,  56, $0x3f83b2ab6fba08f0) // f64(0.0096181291075976005)
CONST_DATA_U64(const_exp2,  64, $0x3fac6b08d704a01f) // f64(0.055504108664820466)
CONST_DATA_U64(const_exp2,  72, $0x3fcebfbdff82c5a1) // f64(0.24022650695910122)
CONST_DATA_U64(const_exp2,  80, $0x3fe62e42fefa39ef) // f64(0.69314718055994529)
CONST_DATA_U64(const_exp2,  88, $0x4090000000000000) // f64(1024)
CONST_DATA_U64(const_exp2,  96, $0xc09f400000000000) // f64(-2000)
CONST_DATA_U32(const_exp2, 104, $0x3ff00000) // i32(1072693248)
CONST_GLOBAL(const_exp2, $108)

TEXT bcexp2f(SB), NOSPLIT|NOFRAME, $0
  KTESTW K1, K1
  JZ next

  MOVL $0xAAAA, R8
  KSHIFTRW $8, K1, K2
  KMOVW R8, K3

  VRNDSCALEPD $8, Z2, Z6
  VRNDSCALEPD $8, Z3, Z7
  VCVTPD2DQ.RN_SAE Z6, Y4
  VCVTPD2DQ.RN_SAE Z7, Y5
  VINSERTI32X8 $1, Y5, Z4, Z4

  VBROADCASTSD CONST_GET_PTR(const_exp2, 0), Z10
  VBROADCASTSD CONST_GET_PTR(const_exp2, 16), Z12
  VBROADCASTSD CONST_GET_PTR(const_exp2, 32), Z14
  VSUBPD Z6, Z2, Z6
  VSUBPD Z7, Z3, Z7
  VMULPD Z6, Z6, Z8
  VMULPD Z7, Z7, Z9
  VMOVAPD Z10, Z11
  VMOVAPD Z12, Z13
  VMOVAPD Z14, Z15
  VBROADCASTSD CONST_GET_PTR(const_exp2, 8), Z16
  VBROADCASTSD CONST_GET_PTR(const_exp2, 24), Z17
  VBROADCASTSD CONST_GET_PTR(const_exp2, 40), Z18
  VFMADD213PD Z16, Z6, Z10 // Z10 = (Z6 * Z10) + Z16
  VFMADD213PD Z16, Z7, Z11 // Z11 = (Z7 * Z11) + Z16
  VFMADD213PD Z17, Z6, Z12 // Z12 = (Z6 * Z12) + Z17
  VFMADD213PD Z17, Z7, Z13 // Z13 = (Z7 * Z13) + Z17
  VFMADD213PD Z18, Z6, Z14 // Z14 = (Z6 * Z14) + Z18
  VFMADD213PD Z18, Z7, Z15 // Z15 = (Z7 * Z15) + Z18
  VMULPD Z8, Z8, Z16
  VMULPD Z9, Z9, Z17
  VFMADD231PD Z12, Z8, Z14 // Z14 = (Z8 * Z12) + Z14
  VFMADD231PD Z13, Z9, Z15 // Z15 = (Z9 * Z13) + Z15

  VBROADCASTSD CONST_GET_PTR(const_exp2, 56), Z5
  VBROADCASTSD CONST_GET_PTR(const_exp2, 48), Z12
  VBROADCASTSD CONST_GET_PTR(const_exp2, 64), Z18
  VMOVAPD Z12, Z13
  VMOVAPD Z18, Z19
  VFMADD213PD Z5, Z6, Z12 // Z12 = (Z6 * Z12) + Z5
  VFMADD213PD Z5, Z7, Z13 // Z13 = (Z7 * Z13) + Z5
  VBROADCASTSD CONST_GET_PTR(const_exp2, 72), Z5
  VMULPD Z16, Z16, Z20
  VMULPD Z17, Z17, Z21
  VFMADD213PD Z5, Z6, Z18 // Z18 = (Z6 * Z18) + Z5
  VFMADD213PD Z5, Z7, Z19 // Z19 = (Z7 * Z19) + Z5
  VFMADD231PD Z12, Z8, Z18  // Z18 = (Z8 * Z12) + Z18
  VFMADD231PD Z13, Z9, Z19  // Z19 = (Z9 * Z13) + Z19
  VBROADCASTSD CONST_GET_PTR(const_exp2, 80), Z5
  VFMADD231PD Z14, Z16, Z18 // Z18 = (Z16 * Z14) + Z18
  VFMADD231PD Z15, Z17, Z19 // Z19 = (Z17 * Z15) + Z19
  VFMADD231PD Z10, Z20, Z18 // Z18 = (Z20 * Z10) + Z18
  VFMADD231PD Z11, Z21, Z19 // Z19 = (Z21 * Z11) + Z19
  VBROADCASTSD CONSTF64_1(), Z20
  VFMADD213PD Z5, Z6, Z18 // Z18 = (Z6 * Z18) + Z5
  VFMADD213PD Z5, Z7, Z19 // Z19 = (Z7 * Z19) + Z5
  VFMADD213PD Z20, Z6, Z18 // Z18 = (Z6 * Z18) + Z20{1.0}
  VFMADD213PD Z20, Z7, Z19 // Z19 = (Z7 * Z19) + Z20{1.0}

  VPSRAD $1, Z4, Z6
  VPSLLD $20, Z6, Z8
  VPBROADCASTD CONST_GET_PTR(const_exp2, 104), Z10
  VPADDD Z10, Z8, Z8
  VEXTRACTI32X8 $1, Z8, Y9
  VPEXPANDD.Z Z8, K3, Z8
  VPEXPANDD.Z Z9, K3, Z9

  VMULPD Z8, Z18, Z8
  VMULPD Z9, Z19, Z9
  VPSUBD Z6, Z4, Z4
  VPSLLD $20, Z4, Z4
  VPADDD Z10, Z4, Z4
  VEXTRACTI32X8 $1, Z4, Y5
  VPEXPANDD.Z Z4, K3, Z4
  VPEXPANDD.Z Z5, K3, Z5
  VMULPD Z4, Z8, Z4
  VMULPD Z5, Z9, Z5

  VBROADCASTSD CONST_GET_PTR(const_exp2, 88), Z10
  VBROADCASTSD CONST_GET_PTR(const_exp2, 96), Z11
  VBROADCASTSD CONSTF64_POSITIVE_INF(), Z12
  VCMPPD $VCMP_IMM_GE_OS, Z10, Z2, K1, K3
  VCMPPD $VCMP_IMM_GE_OS, Z10, Z3, K2, K4
  VCMPPD $VCMP_IMM_NLT_US, Z11, Z2, K1, K5
  VCMPPD $VCMP_IMM_NLT_US, Z11, Z3, K2, K6

  VMOVAPD Z12, K3, Z4
  VMOVAPD Z12, K4, Z5
  VMOVAPD.Z Z4, K5, Z4
  VMOVAPD.Z Z5, K6, Z5

  VMOVAPD Z4, K1, Z2
  VMOVAPD Z5, K2, Z3

next:
  NEXT()

// Base-10 exponential: exp10(x)
CONST_DATA_U64(const_exp10,   0, $0x400a934f0979a371) // f64(3.3219280948873622)
CONST_DATA_U64(const_exp10,   8, $0xbfd34413509f7000) // f64(-0.30102999566383914)
CONST_DATA_U64(const_exp10,  16, $0xbd43fde623e2566b) // f64(-1.4205023227266099E-13)
CONST_DATA_U64(const_exp10,  24, $0x3f2f9b875f46726f) // f64(2.4114634983342677E-4)
CONST_DATA_U64(const_exp10,  32, $0x3f52f6dbb8e3072a) // f64(0.0011574884152171874)
CONST_DATA_U64(const_exp10,  40, $0x3f748988cff14706) // f64(0.0050139755467897337)
CONST_DATA_U64(const_exp10,  48, $0x3f9411663b046154) // f64(0.019597623207205331)
CONST_DATA_U64(const_exp10,  56, $0x3fb16e4df78fca37) // f64(0.068089363994467841)
CONST_DATA_U64(const_exp10,  64, $0x3fca7ed709f2107e) // f64(0.20699584947226762)
CONST_DATA_U64(const_exp10,  72, $0x3fe1429ffd1eb6e2) // f64(0.53938292920585362)
CONST_DATA_U64(const_exp10,  80, $0x3ff2bd7609fd573b) // f64(1.1712551489085417)
CONST_DATA_U64(const_exp10,  88, $0x4000470591de2c43) // f64(2.034678592293433)
CONST_DATA_U64(const_exp10,  96, $0x40053524c73cea78) // f64(2.6509490552392059)
CONST_DATA_U64(const_exp10, 104, $0x40026bb1bbb55516) // f64(2.3025850929940459)
CONST_DATA_U64(const_exp10, 112, $0x40734413509f79fe) // f64(308.25471555991669)
CONST_DATA_U64(const_exp10, 120, $0xc075e00000000000) // f64(-350)
CONST_DATA_U32(const_exp10, 128, $0x3ff00000) // i32(1072693248)
CONST_GLOBAL(const_exp10, $132)

TEXT bcexp10f(SB), NOSPLIT|NOFRAME, $0
  KTESTW K1, K1
  JZ next

  MOVL $0xAAAA, R8
  KSHIFTRW $8, K1, K2
  KMOVW R8, K3

  VBROADCASTSD CONST_GET_PTR(const_exp10, 0), Z5
  VBROADCASTSD CONST_GET_PTR(const_exp10, 8), Z8
  VBROADCASTSD CONST_GET_PTR(const_exp10, 16), Z10

  VMULPD Z5, Z2, Z4
  VMULPD Z5, Z3, Z5
  VRNDSCALEPD $8, Z4, Z6
  VRNDSCALEPD $8, Z5, Z7
  VCVTPD2DQ.RN_SAE Z6, Y4
  VCVTPD2DQ.RN_SAE Z7, Y5
  VINSERTI32X8 $1, Y5, Z4, Z4

  VMOVAPD Z8, Z9
  VFMADD213PD Z2, Z6, Z8 // Z8 = (Z6 * Z8) + Z2
  VFMADD213PD Z3, Z7, Z9 // Z9 = (Z7 * Z9) + Z3
  VFMADD231PD Z10, Z6, Z8 // Z8 = (Z6 * Z10) + Z8
  VFMADD231PD Z10, Z7, Z9 // Z9 = (Z7 * Z10) + Z9
  VBROADCASTSD CONST_GET_PTR(const_exp10, 24), Z6
  VBROADCASTSD CONST_GET_PTR(const_exp10, 32), Z10
  VBROADCASTSD CONST_GET_PTR(const_exp10, 40), Z11
  VMOVAPD Z6, Z7
  VFMADD213PD Z10, Z8, Z6 // Z6 = (Z8 * Z6) + Z10
  VFMADD213PD Z10, Z9, Z7 // Z7 = (Z9 * Z7) + Z10
  VFMADD213PD Z11, Z8, Z6 // Z6 = (Z8 * Z6) + Z11
  VFMADD213PD Z11, Z9, Z7 // Z7 = (Z9 * Z7) + Z11
  VBROADCASTSD CONST_GET_PTR(const_exp10, 48), Z10
  VBROADCASTSD CONST_GET_PTR(const_exp10, 56), Z11
  VFMADD213PD Z10, Z8, Z6 // Z6 = (Z8 * Z6) + Z10
  VFMADD213PD Z10, Z9, Z7 // Z7 = (Z9 * Z7) + Z10
  VFMADD213PD Z11, Z8, Z6 // Z6 = (Z8 * Z6) + Z11
  VFMADD213PD Z11, Z9, Z7 // Z7 = (Z9 * Z7) + Z11
  VBROADCASTSD CONST_GET_PTR(const_exp10, 64), Z10
  VBROADCASTSD CONST_GET_PTR(const_exp10, 72), Z11
  VFMADD213PD Z10, Z8, Z6 // Z6 = (Z8 * Z6) + Z10
  VFMADD213PD Z10, Z9, Z7 // Z7 = (Z9 * Z7) + Z10
  VFMADD213PD Z11, Z8, Z6 // Z6 = (Z8 * Z6) + Z11
  VFMADD213PD Z11, Z9, Z7 // Z7 = (Z9 * Z7) + Z11
  VBROADCASTSD CONST_GET_PTR(const_exp10, 80), Z10
  VBROADCASTSD CONST_GET_PTR(const_exp10, 88), Z11
  VFMADD213PD Z10, Z8, Z6 // Z6 = (Z8 * Z6) + Z10
  VFMADD213PD Z10, Z9, Z7 // Z7 = (Z9 * Z7) + Z10
  VFMADD213PD Z11, Z8, Z6 // Z6 = (Z8 * Z6) + Z11
  VFMADD213PD Z11, Z9, Z7 // Z7 = (Z9 * Z7) + Z11
  VBROADCASTSD CONST_GET_PTR(const_exp10, 96), Z10
  VBROADCASTSD CONST_GET_PTR(const_exp10, 104), Z11
  VFMADD213PD Z10, Z8, Z6 // Z6 = (Z8 * Z6) + Z10
  VFMADD213PD Z10, Z9, Z7 // Z7 = (Z9 * Z7) + Z10
  VFMADD213PD Z11, Z8, Z6 // Z6 = (Z8 * Z6) + Z11
  VFMADD213PD Z11, Z9, Z7 // Z7 = (Z9 * Z7) + Z11

  VBROADCASTSD CONSTF64_1(), Z10
  VPBROADCASTD CONST_GET_PTR(const_exp10, 128), Z12
  VFMADD213PD Z10, Z8, Z6 // Z6 = (Z8 * Z6) + mem
  VFMADD213PD Z10, Z9, Z7 // Z7 = (Z9 * Z7) + mem
  VPSRAD $1, Z4, Z8
  VPSLLD $20, Z8, Z10
  VPADDD Z12, Z10, Z10
  VEXTRACTI32X8 $1, Z10, Y11
  VPEXPANDD.Z Z10, K3, Z10
  VPEXPANDD.Z Z11, K3, Z11
  VMULPD Z10, Z6, Z6
  VMULPD Z11, Z7, Z7
  VPSUBD Z8, Z4, Z4
  VPSLLD $20, Z4, Z4
  VPADDD Z12, Z4, Z4
  VEXTRACTI32X8 $1, Z4, Y5
  VPEXPANDD.Z Z4, K3, Z4
  VPEXPANDD.Z Z5, K3, Z5
  VMULPD Z4, Z6, Z4
  VMULPD Z5, Z7, Z5

  VBROADCASTSD CONST_GET_PTR(const_exp10, 112), Z10
  VBROADCASTSD CONST_GET_PTR(const_exp10, 120), Z11
  VBROADCASTSD CONSTF64_POSITIVE_INF(), Z12
  VCMPPD $VCMP_IMM_GT_OS, Z10, Z2, K3
  VCMPPD $VCMP_IMM_GT_OS, Z10, Z3, K4
  VCMPPD $VCMP_IMM_NLT_US, Z11, Z2, K5
  VCMPPD $VCMP_IMM_NLT_US, Z11, Z3, K6

  VMOVAPD Z12, K3, Z4
  VMOVAPD Z12, K4, Z5
  VMOVAPD.Z Z4, K5, Z4
  VMOVAPD.Z Z5, K6, Z5

  VMOVAPD Z4, K1, Z2
  VMOVAPD Z5, K2, Z3

next:
  NEXT()

// Exponential minus one: expm1(x) == exp(x) - 1
CONST_DATA_U64(const_expm1,   0, $0x3ff71547652b82fe) // f64(1.4426950408889634)
CONST_DATA_U64(const_expm1,   8, $0xbfe62e42fefa3000) // f64(-0.69314718055966296)
CONST_DATA_U64(const_expm1,  16, $0xbd53de6af278ece6) // f64(-2.8235290563031577E-13)
CONST_DATA_U64(const_expm1,  24, $0x3de60632a887194c) // f64(1.6024722197099321E-10)
CONST_DATA_U64(const_expm1,  32, $0x3e21f8eaf54829dc) // f64(2.092255183563157E-9)
CONST_DATA_U64(const_expm1,  40, $0x3e5ae652e8103ab6) // f64(2.5052300237826445E-8)
CONST_DATA_U64(const_expm1,  48, $0x3e927e4c95a9765c) // f64(2.7557248009021353E-7)
CONST_DATA_U64(const_expm1,  56, $0x3ec71de3a11d7656) // f64(2.7557318923860444E-6)
CONST_DATA_U64(const_expm1,  64, $0x3efa01a01af6f0b7) // f64(2.4801587356058151E-5)
CONST_DATA_U64(const_expm1,  72, $0x3f2a01a01a02d002) // f64(1.9841269841480719E-4)
CONST_DATA_U64(const_expm1,  80, $0x3f56c16c16c145cc) // f64(0.0013888888888867633)
CONST_DATA_U64(const_expm1,  88, $0x3f81111111111119) // f64(0.008333333333333347)
CONST_DATA_U64(const_expm1,  96, $0x3fa555555555555a) // f64(0.041666666666666699)
CONST_DATA_U64(const_expm1, 104, $0x3fc5555555555555) // f64(0.16666666666666666)
CONST_DATA_U64(const_expm1, 112, $0xc08f400000000000) // f64(-1000)
CONST_DATA_U64(const_expm1, 120, $0xbff0000000000000) // f64(-1)
CONST_DATA_U64(const_expm1, 128, $0x40862e42fefa39ef) // f64(709.78271289338397)
CONST_DATA_U64(const_expm1, 136, $0xc0425e4f7b2737fa) // f64(-36.736800569677101)
CONST_DATA_U32(const_expm1, 144, $0x3ff00000) // i32(1072693248)
CONST_GLOBAL(const_expm1, $148)

TEXT bcexpm1f(SB), NOSPLIT|NOFRAME, $0
  KTESTW K1, K1
  JZ next

  MOVL $0xAAAA, R15
  KSHIFTRW $8, K1, K2
  KMOVW R15, K5

  VBROADCASTSD CONST_GET_PTR(const_expm1, 0), Z8
  VBROADCASTSD CONST_GET_PTR(const_expm1, 8), Z9
  VXORPD X5, X5, X5
  VXORPD X5, X5, X5
  VADDPD Z5, Z2, Z6
  VADDPD Z5, Z3, Z7
  VMULPD Z8, Z6, Z6
  VMULPD Z8, Z7, Z7
  VRNDSCALEPD $8, Z6, Z6
  VRNDSCALEPD $8, Z7, Z7
  VMULPD Z9, Z6, Z8
  VMULPD Z9, Z7, Z9

  VADDPD Z2, Z8, Z12
  VADDPD Z3, Z9, Z13
  VSUBPD Z2, Z12, Z10
  VSUBPD Z3, Z13, Z11
  VSUBPD Z10, Z12, Z14
  VSUBPD Z11, Z13, Z15
  VSUBPD Z14, Z2, Z14
  VSUBPD Z15, Z3, Z15
  VSUBPD Z10, Z8, Z8
  VSUBPD Z11, Z9, Z9
  VADDPD Z14, Z8, Z8
  VADDPD Z15, Z9, Z9
  VBROADCASTSD CONST_GET_PTR(const_expm1, 16), Z15
  VADDPD Z5, Z8, Z8
  VADDPD Z5, Z9, Z9
  VMULPD Z15, Z6, Z14
  VMULPD Z15, Z7, Z15
  VADDPD Z12, Z14, Z10
  VADDPD Z13, Z15, Z11
  VSUBPD Z12, Z10, Z16
  VSUBPD Z13, Z11, Z17
  VSUBPD Z16, Z10, Z18
  VSUBPD Z17, Z11, Z19
  VSUBPD Z18, Z12, Z12
  VSUBPD Z19, Z13, Z13
  VSUBPD Z16, Z14, Z14
  VSUBPD Z17, Z15, Z15
  VADDPD Z12, Z14, Z12
  VADDPD Z13, Z15, Z13
  VADDPD Z8, Z12, Z8
  VADDPD Z9, Z13, Z9
  VMULPD Z10, Z10, Z12
  VMULPD Z11, Z11, Z13

  VCVTPD2DQ.RN_SAE Z6, Y6
  VCVTPD2DQ.RN_SAE Z7, Y7
  VINSERTI32X8 $1, Y7, Z6, Z6
  VMOVDQU32 Z6, bytecode_spillArea(VIRT_BCPTR) // Save Z6

  VBROADCASTSD CONST_GET_PTR(const_expm1, 24), Z14
  VBROADCASTSD CONST_GET_PTR(const_expm1, 40), Z16
  VMOVAPD Z14, Z15
  VMOVAPD Z16, Z17
  VBROADCASTSD CONST_GET_PTR(const_expm1, 32), Z18
  VBROADCASTSD CONST_GET_PTR(const_expm1, 48), Z19
  VFMADD213PD Z18, Z10, Z14 // Z14 = (Z10 * Z14) + Z18
  VFMADD213PD Z18, Z11, Z15 // Z15 = (Z11 * Z15) + Z18
  VFMADD213PD Z19, Z10, Z16 // Z16 = (Z10 * Z16) + Z19
  VFMADD213PD Z19, Z11, Z17 // Z17 = (Z11 * Z17) + Z19
  VBROADCASTSD CONST_GET_PTR(const_expm1, 56), Z18
  VBROADCASTSD CONST_GET_PTR(const_expm1, 72), Z20
  VMOVAPD Z18, Z19
  VMOVAPD Z20, Z21
  VBROADCASTSD CONST_GET_PTR(const_expm1, 64), Z22
  VBROADCASTSD CONST_GET_PTR(const_expm1, 80), Z23
  VFMADD213PD Z22, Z10, Z18 // Z18 = (Z10 * Z18) + Z22
  VFMADD213PD Z22, Z11, Z19 // Z19 = (Z11 * Z19) + Z22
  VFMADD213PD Z23, Z10, Z20 // Z20 = (Z10 * Z20) + Z23
  VFMADD213PD Z23, Z11, Z21 // Z21 = (Z11 * Z21) + Z23
  VBROADCASTSD CONST_GET_PTR(const_expm1, 88), Z22
  VBROADCASTSD CONST_GET_PTR(const_expm1, 104), Z24
  VBROADCASTSD CONST_GET_PTR(const_expm1, 96), Z26
  VMOVAPD Z22, Z23
  VMOVAPD Z24, Z25
  VFMADD213PD Z26, Z10, Z22 // Z22 = (Z10 * Z22) + Z26
  VFMADD213PD Z26, Z11, Z23 // Z23 = (Z11 * Z23) + Z26
  VMULPD Z24, Z10, Z26
  VMULPD Z25, Z11, Z27
  VMOVAPD Z24, Z4
  VMOVAPD Z25, Z5
  VFMSUB213PD Z26, Z10, Z4 // Z4 = (Z10 * Z4) - Z26
  VFMSUB213PD Z27, Z11, Z5 // Z5 = (Z11 * Z5) - Z27
  VFMADD231PD Z24, Z8, Z4  // Z4 = (Z8 * Z24) + Z4
  VFMADD231PD Z25, Z9, Z5  // Z5 = (Z9 * Z25) + Z5
  VBROADCASTSD CONSTF64_HALF(), Z25
  VADDPD Z25, Z26, Z6
  VADDPD Z25, Z27, Z7
  VSUBPD Z6, Z25, Z24
  VSUBPD Z7, Z25, Z25
  VADDPD Z24, Z26, Z24
  VADDPD Z25, Z27, Z25
  VADDPD Z4, Z24, Z24
  VADDPD Z5, Z25, Z25
  VMULPD Z6, Z10, Z26
  VMULPD Z7, Z11, Z27
  VMOVAPD Z10, Z4
  VMOVAPD Z11, Z5
  VFMSUB213PD Z26, Z6, Z4  // Z4 = (Z6 * Z4) - Z26
  VFMSUB213PD Z27, Z7, Z5  // Z5 = (Z7 * Z5) - Z27
  VFMADD231PD Z24, Z10, Z4 // Z4 = (Z10 * Z24) + Z4
  VFMADD231PD Z25, Z11, Z5 // Z5 = (Z11 * Z25) + Z5
  VFMADD231PD Z6, Z8, Z4   // Z4 = (Z8 * Z6) + Z4
  VFMADD231PD Z7, Z9, Z5   // Z5 = (Z9 * Z7) + Z5
  VBROADCASTSD CONSTF64_1(), Z25
  VADDPD Z25, Z26, Z6
  VADDPD Z25, Z27, Z7
  VSUBPD Z6, Z25, Z24
  VSUBPD Z7, Z25, Z25
  VADDPD Z24, Z26, Z26
  VADDPD Z25, Z27, Z27
  VADDPD Z4, Z26, Z26
  VADDPD Z5, Z27, Z27
  VMULPD Z6, Z10, Z4
  VMULPD Z7, Z11, Z5
  VMOVAPD Z10, Z24
  VMOVAPD Z11, Z25
  VFMSUB213PD Z4, Z6, Z24   // Z24 = (Z6 * Z24) - Z4
  VFMSUB213PD Z5, Z7, Z25   // Z25 = (Z7 * Z25) - Z5
  VFMADD231PD Z26, Z10, Z24 // Z24 = (Z10 * Z26) + Z24
  VFMADD231PD Z27, Z11, Z25 // Z25 = (Z11 * Z27) + Z25
  VADDPD Z10, Z10, Z26
  VADDPD Z11, Z11, Z27
  VFMSUB213PD Z12, Z10, Z10 // Z10 = (Z10 * Z10) - Z12
  VFMSUB213PD Z13, Z11, Z11 // Z11 = (Z11 * Z11) - Z13
  VFMADD231PD Z26, Z8, Z10  // Z10 = (Z8 * Z26) + Z10
  VFMADD231PD Z27, Z9, Z11  // Z11 = (Z9 * Z27) + Z11
  VFMADD231PD Z16, Z12, Z18 // Z18 = (Z12 * Z16) + Z18
  VFMADD231PD Z17, Z13, Z19 // Z19 = (Z13 * Z17) + Z19
  VMULPD Z12, Z12, Z16
  VMULPD Z13, Z13, Z17
  VFMADD231PD Z20, Z12, Z22 // Z22 = (Z12 * Z20) + Z22
  VFMADD231PD Z21, Z13, Z23 // Z23 = (Z13 * Z21) + Z23
  VADDPD Z12, Z12, Z20
  VADDPD Z13, Z13, Z21
  VFMSUB213PD Z16, Z12, Z12 // Z12 = (Z12 * Z12) - Z16
  VFMSUB213PD Z17, Z13, Z13 // Z13 = (Z13 * Z13) - Z17
  VFMADD231PD Z20, Z10, Z12 // Z12 = (Z10 * Z20) + Z12
  VFMADD231PD Z21, Z11, Z13 // Z13 = (Z11 * Z21) + Z13
  VFMADD231PD Z18, Z16, Z22 // Z22 = (Z16 * Z18) + Z22
  VFMADD231PD Z19, Z17, Z23 // Z23 = (Z17 * Z19) + Z23
  VMULPD Z16, Z16, Z10
  VMULPD Z17, Z17, Z11
  VFMADD231PD Z14, Z10, Z22 // Z22 = (Z10 * Z14) + Z22
  VFMADD231PD Z15, Z11, Z23 // Z23 = (Z11 * Z15) + Z23
  VFMADD231PD Z8, Z6, Z24   // Z24 = (Z6 * Z8) + Z24
  VFMADD231PD Z9, Z7, Z25   // Z25 = (Z7 * Z9) + Z25
  VBROADCASTSD CONSTF64_1(), Z15
  VADDPD Z15, Z4, Z8
  VADDPD Z15, Z5, Z9
  VSUBPD Z8, Z15, Z10
  VSUBPD Z9, Z15, Z11
  VADDPD Z10, Z4, Z10
  VADDPD Z11, Z5, Z11
  VADDPD Z24, Z10, Z10
  VADDPD Z25, Z11, Z11
  VMULPD Z22, Z16, Z14
  VMULPD Z23, Z17, Z15
  VFMSUB213PD Z14, Z22, Z16 // Z16 = (Z22 * Z16) - Z14
  VFMSUB213PD Z15, Z23, Z17 // Z17 = (Z23 * Z17) - Z15
  VFMADD231PD Z22, Z12, Z16 // Z16 = (Z12 * Z22) + Z16
  VFMADD231PD Z23, Z13, Z17 // Z17 = (Z13 * Z23) + Z17
  VADDPD Z8, Z14, Z12
  VADDPD Z9, Z15, Z13
  VSUBPD Z12, Z8, Z8
  VSUBPD Z13, Z9, Z9
  VADDPD Z8, Z14, Z8
  VADDPD Z9, Z15, Z9
  VADDPD Z10, Z8, Z8
  VADDPD Z11, Z9, Z9
  VADDPD Z8, Z16, Z8
  VADDPD Z9, Z17, Z9
  VMOVDQU32 bytecode_spillArea(VIRT_BCPTR), Z6 // Load Z6
  VPSRAD $1, Z6, Z10
  VPSLLD $20, Z10, Z14
  VPBROADCASTD CONST_GET_PTR(const_expm1, 144), Z16
  VPADDD Z16, Z14, Z14
  VEXTRACTI32X8 $1, Z14, Y15
  VPEXPANDD.Z Z14, K5, Z14
  VPEXPANDD.Z Z15, K5, Z15
  VMULPD Z14, Z12, Z12
  VMULPD Z15, Z13, Z13
  VPSUBD Z10, Z6, Z6
  VPSLLD $20, Z6, Z6
  VPADDD Z16, Z6, Z6
  VEXTRACTI32X8 $1, Z6, Y7
  VPEXPANDD.Z Z6, K5, Z6
  VPEXPANDD.Z Z7, K5, Z7
  VMULPD Z6, Z12, Z10
  VMULPD Z7, Z13, Z11
  VMULPD Z14, Z8, Z8
  VMULPD Z15, Z9, Z9
  VBROADCASTSD CONST_GET_PTR(const_expm1, 112), Z20
  VBROADCASTSD CONST_GET_PTR(const_expm1, 120), Z21
  VMULPD Z6, Z8, Z6
  VMULPD Z7, Z9, Z7
  VCMPPD $VCMP_IMM_LT_OS, Z20, Z2, K3
  VCMPPD $VCMP_IMM_LT_OS, Z20, Z3, K4
  VXORPD X5, X5, X5
  VMOVAPD Z5, K3, Z10
  VMOVAPD Z5, K4, Z11
  VMOVAPD Z5, K3, Z6
  VMOVAPD Z5, K4, Z7
  VADDPD Z21, Z10, Z4
  VADDPD Z21, Z11, Z5
  VSUBPD Z10, Z4, Z12
  VSUBPD Z11, Z5, Z13
  VSUBPD Z12, Z4, Z14
  VSUBPD Z13, Z5, Z15
  VSUBPD Z14, Z10, Z10
  VSUBPD Z15, Z11, Z11
  VSUBPD Z12, Z21, Z12
  VSUBPD Z13, Z21, Z13
  VADDPD Z10, Z12, Z10
  VADDPD Z11, Z13, Z11
  VADDPD Z6, Z10, Z6
  VADDPD Z7, Z11, Z7
  VADDPD Z6, Z4, Z4
  VADDPD Z7, Z5, Z5
  VBROADCASTSD CONST_GET_PTR(const_expm1, 128), Z20
  VBROADCASTSD CONST_GET_PTR(const_expm1, 136), Z19
  VCMPPD $VCMP_IMM_GT_OS, Z20, Z2, K3
  VCMPPD $VCMP_IMM_GT_OS, Z20, Z3, K4
  VBROADCASTSD CONSTF64_SIGN_BIT(), Z20
  VBROADCASTSD CONSTF64_POSITIVE_INF(), K3, Z4
  VBROADCASTSD CONSTF64_POSITIVE_INF(), K4, Z5
  VCMPPD $VCMP_IMM_LT_OS, Z19, Z2, K3
  VCMPPD $VCMP_IMM_LT_OS, Z19, Z3, K4
  VMOVAPD Z21, K3, Z4
  VMOVAPD Z21, K4, Z5
  VPCMPEQQ Z20, Z2, K3
  VPCMPEQQ Z20, Z3, K4
  VBROADCASTSD CONSTF64_SIGN_BIT(), K3, Z4
  VBROADCASTSD CONSTF64_SIGN_BIT(), K4, Z5

  VMOVAPD Z4, K1, Z2
  VMOVAPD Z5, K2, Z3

next:
  NEXT()

// Natural logarithm: ln(x)
CONST_DATA_U64(const_ln,  0, $0x3ff5555555555555) // f64(1.3333333333333333)
CONST_DATA_U64(const_ln,  8, $0x4090000000000000) // f64(1024)
CONST_DATA_U64(const_ln, 16, $0xbff0000000000000) // f64(-1)
CONST_DATA_U64(const_ln, 24, $0x3fc3872e67fe8e84) // f64(0.15256290510034287)
CONST_DATA_U64(const_ln, 32, $0x3fc747353a506035) // f64(0.1818605932937786)
CONST_DATA_U64(const_ln, 40, $0x3fc39c4f5407567e) // f64(0.15320769885027014)
CONST_DATA_U64(const_ln, 48, $0x3fcc71c0a65ecd8e) // f64(0.222221451983938)
CONST_DATA_U64(const_ln, 56, $0x3fd249249a68a245) // f64(0.28571429327942993)
CONST_DATA_U64(const_ln, 64, $0x3fd99999998f92ea) // f64(0.3999999999635252)
CONST_DATA_U64(const_ln, 72, $0x3fe55555555557ae) // f64(0.66666666666673335)
CONST_DATA_U64(const_ln, 80, $0x3fe62e42fefa39ef) // f64(0.69314718055994529)
CONST_DATA_U64(const_ln, 88, $0x3c7abc9e3b39803f) // f64(2.3190468138462996E-17)
CONST_DATA_U64(const_ln, 96, $0x0253040002530400) // i64(167482009228346368)
CONST_GLOBAL(const_ln, $104)

TEXT bclnf(SB), NOSPLIT|NOFRAME, $0
  KTESTW K1, K1
  JZ next

  KSHIFTRW $8, K1, K2
  VBROADCASTSD CONST_GET_PTR(const_ln, 0), Z5
  VBROADCASTSD CONST_GET_PTR(const_ln, 8), Z6
  VBROADCASTSD CONSTF64_POSITIVE_INF(), Z7

  VMULPD Z5, Z2, Z4
  VMULPD Z5, Z3, Z5
  VGETEXPPD Z4, Z4
  VGETEXPPD Z5, Z5
  VCMPPD $VCMP_IMM_EQ_OQ, Z7, Z4, K3
  VCMPPD $VCMP_IMM_EQ_OQ, Z7, Z5, K4
  VMOVAPD Z6, K3, Z4
  VMOVAPD Z6, K4, Z5
  VGETMANTPD $11, Z2, Z6
  VGETMANTPD $11, Z3, Z7

  VBROADCASTSD CONST_GET_PTR(const_ln, 16), Z9
  VBROADCASTSD CONSTF64_1(), Z12
  VADDPD Z9, Z6, Z10
  VADDPD Z9, Z7, Z11
  VADDPD Z12, Z10, Z14
  VADDPD Z12, Z11, Z15
  VSUBPD Z14, Z10, Z16
  VSUBPD Z15, Z11, Z17
  VSUBPD Z16, Z9, Z16
  VSUBPD Z17, Z9, Z17
  VSUBPD Z14, Z6, Z14
  VSUBPD Z15, Z7, Z15
  VADDPD Z16, Z14, Z14
  VADDPD Z17, Z15, Z15
  VADDPD Z12, Z6, Z16
  VADDPD Z12, Z7, Z17
  VADDPD Z9, Z16, Z8
  VADDPD Z9, Z17, Z9
  VSUBPD Z8, Z16, Z18
  VSUBPD Z9, Z17, Z19
  VSUBPD Z18, Z12, Z18
  VSUBPD Z19, Z12, Z19
  VSUBPD Z8, Z6, Z6
  VSUBPD Z9, Z7, Z7
  VDIVPD Z16, Z12, Z8
  VDIVPD Z17, Z12, Z9
  VADDPD Z18, Z6, Z6
  VADDPD Z19, Z7, Z7
  VMULPD Z8, Z10, Z18
  VMULPD Z9, Z11, Z19
  VFMSUB213PD Z18, Z8, Z10  // Z10 = (Z8 * Z10) - Z18
  VFMSUB213PD Z19, Z9, Z11  // Z11 = (Z9 * Z11) - Z19
  VFNMADD213PD Z12, Z8, Z16 // Z16 = -(Z8 * Z16) + Z12
  VFNMADD213PD Z12, Z9, Z17 // Z17 = -(Z9 * Z17) + Z12
  VFNMADD231PD Z6, Z8, Z16  // Z16 = -(Z8 * Z6) + Z16
  VFNMADD231PD Z7, Z9, Z17  // Z17 = -(Z9 * Z7) + Z17
  VFMADD231PD Z14, Z8, Z10  // Z10 = (Z8 * Z14) + Z10
  VFMADD231PD Z15, Z9, Z11  // Z11 = (Z9 * Z15) + Z11
  VFMADD231PD Z16, Z18, Z10 // Z10 = (Z18 * Z16) + Z10
  VFMADD231PD Z17, Z19, Z11 // Z11 = (Z19 * Z17) + Z11
  VMULPD Z18, Z18, Z6
  VMULPD Z19, Z19, Z7
  VMULPD Z6, Z6, Z8
  VMULPD Z7, Z7, Z9
  VMULPD Z8, Z8, Z12
  VMULPD Z9, Z9, Z13

  VBROADCASTSD CONST_GET_PTR(const_ln, 24), Z14
  VBROADCASTSD CONST_GET_PTR(const_ln, 32), Z20
  VBROADCASTSD CONST_GET_PTR(const_ln, 40), Z21
  VMOVAPD Z14, Z15
  VFMADD213PD Z20, Z6, Z14 // Z14 = (Z6 * Z14) + mem
  VFMADD213PD Z20, Z7, Z15 // Z15 = (Z7 * Z15) + mem
  VFMADD231PD Z21, Z8, Z14 // Z14 = (Z8 * mem) + Z14
  VFMADD231PD Z21, Z9, Z15 // Z15 = (Z9 * mem) + Z15

  VBROADCASTSD CONST_GET_PTR(const_ln, 48), Z16
  VBROADCASTSD CONST_GET_PTR(const_ln, 64), Z20
  VMOVAPD Z16, Z17
  VMOVAPD Z20, Z21
  VBROADCASTSD CONST_GET_PTR(const_ln, 56), Z22
  VBROADCASTSD CONST_GET_PTR(const_ln, 72), Z23
  VFMADD213PD Z22, Z6, Z16 // Z16 = (Z6 * Z16) + mem
  VFMADD213PD Z22, Z7, Z17 // Z17 = (Z7 * Z17) + mem
  VFMADD213PD Z23, Z6, Z20 // Z20 = (Z6 * Z20) + mem
  VFMADD213PD Z23, Z7, Z21 // Z21 = (Z7 * Z21) + mem
  VFMADD231PD Z16, Z8, Z20  // Z20 = (Z8 * Z16) + Z20
  VFMADD231PD Z17, Z9, Z21  // Z21 = (Z9 * Z17) + Z21
  VFMADD231PD Z14, Z12, Z20 // Z20 = (Z12 * Z14) + Z20
  VFMADD231PD Z15, Z13, Z21 // Z21 = (Z13 * Z15) + Z21

  VBROADCASTSD CONST_GET_PTR(const_ln, 80), Z8
  VBROADCASTSD CONST_GET_PTR(const_ln, 88), Z14
  VMOVAPD Z8, Z9
  VMULPD Z8, Z4, Z12
  VMULPD Z8, Z5, Z13
  VFMSUB213PD Z12, Z4, Z8 // Z8 = (Z4 * Z8) - Z12
  VFMSUB213PD Z13, Z5, Z9 // Z9 = (Z5 * Z9) - Z13
  VFMADD231PD Z14, Z4, Z8 // Z8 = (Z4 * Z14) + Z8
  VFMADD231PD Z14, Z5, Z9 // Z9 = (Z5 * Z14) + Z9
  VADDPD Z18, Z18, Z4
  VADDPD Z19, Z19, Z5
  VADDPD Z10, Z10, Z10
  VADDPD Z11, Z11, Z11
  VADDPD Z4, Z12, Z14
  VADDPD Z5, Z13, Z15
  VSUBPD Z14, Z12, Z12
  VSUBPD Z15, Z13, Z13
  VADDPD Z12, Z4, Z4
  VADDPD Z13, Z5, Z5
  VADDPD Z4, Z8, Z4
  VADDPD Z5, Z9, Z5
  VADDPD Z10, Z4, Z4
  VADDPD Z11, Z5, Z5
  VMULPD Z6, Z18, Z6
  VMULPD Z7, Z19, Z7
  VMULPD Z20, Z6, Z6
  VMULPD Z21, Z7, Z7
  VADDPD Z6, Z14, Z8
  VADDPD Z7, Z15, Z9
  VSUBPD Z8, Z14, Z10
  VSUBPD Z9, Z15, Z11
  VADDPD Z10, Z6, Z6
  VADDPD Z11, Z7, Z7
  VADDPD Z6, Z4, Z4
  VADDPD Z7, Z5, Z5
  VPBROADCASTQ CONST_GET_PTR(const_ln, 96), Z6
  VADDPD Z4, Z8, Z4
  VADDPD Z5, Z9, Z5

  VFIXUPIMMPD $0, Z6, Z2, Z4
  VFIXUPIMMPD $0, Z6, Z3, Z5

  VMOVAPD Z4, K1, Z2
  VMOVAPD Z5, K2, Z3

next:
  NEXT()

// Logarithm of x + 1: ln1p(x) == ln(x + 1)
CONST_DATA_U64(const_log1p,   0, $0x3ff5555555555555) // f64(1.3333333333333333)
CONST_DATA_U64(const_log1p,   8, $0x4090000000000000) // f64(1024)
CONST_DATA_U64(const_log1p,  16, $0xbff0000000000000) // f64(-1)
CONST_DATA_U64(const_log1p,  24, $0x3fe62e42fefa39ef) // f64(0.69314718055994529)
CONST_DATA_U64(const_log1p,  32, $0x3c7abc9e3b39803f) // f64(2.3190468138462996E-17)
CONST_DATA_U64(const_log1p,  40, $0x4000000000000000) // f64(2)
CONST_DATA_U64(const_log1p,  48, $0x3fc3872e67fe8e84) // f64(0.15256290510034287)
CONST_DATA_U64(const_log1p,  56, $0x3fc747353a506035) // f64(0.1818605932937786)
CONST_DATA_U64(const_log1p,  64, $0x3fc39c4f5407567e) // f64(0.15320769885027014)
CONST_DATA_U64(const_log1p,  72, $0x3fcc71c0a65ecd8e) // f64(0.222221451983938)
CONST_DATA_U64(const_log1p,  80, $0x3fd249249a68a245) // f64(0.28571429327942993)
CONST_DATA_U64(const_log1p,  88, $0x3fd99999998f92ea) // f64(0.3999999999635252)
CONST_DATA_U64(const_log1p,  96, $0x3fe55555555557ae) // f64(0.66666666666673335)
CONST_DATA_U64(const_log1p, 104, $0x7fac7b1f3cac7433) // f64(9.9999999999999999E+306)
CONST_GLOBAL(const_log1p, $112)

TEXT bcln1pf(SB), NOSPLIT|NOFRAME, $0
  KTESTW K1, K1
  JZ next

  MOVL $0xAAAA, R15
  KSHIFTRW $8, K1, K2
  KMOVW R15, K5

  VBROADCASTSD CONSTF64_1(), Z4
  VBROADCASTSD CONST_GET_PTR(const_log1p, 0), Z9
  VBROADCASTSD CONST_GET_PTR(const_log1p, 0), Z12
  VADDPD Z4, Z2, Z6
  VADDPD Z4, Z3, Z7
  VMULPD Z9, Z6, Z8
  VMULPD Z9, Z7, Z9

  VBROADCASTSD CONSTF64_POSITIVE_INF(), Z6
  VGETEXPPD Z8, Z10
  VGETEXPPD Z9, Z11
  VCMPPD $VCMP_IMM_EQ_OQ, Z6, Z10, K3
  VCMPPD $VCMP_IMM_EQ_OQ, Z6, Z11, K4
  VMOVAPD Z12, K3, Z10
  VMOVAPD Z12, K4, Z11
  VCVTPD2DQ.RN_SAE Z10, Y8
  VCVTPD2DQ.RN_SAE Z11, Y9
  VPXOR X12, X12, X12
  VPSLLD $20, Y8, Y8
  VPSLLD $20, Y9, Y9
  VPSUBD Y8, Y12, Y8
  VPSUBD Y9, Y12, Y9
  VPEXPANDD.Z Z8, K5, Z8
  VPEXPANDD.Z Z9, K5, Z9
  VPADDQ Z4, Z8, Z12
  VPADDQ Z4, Z9, Z13
  VBROADCASTSD CONST_GET_PTR(const_log1p, 16), Z8
  VBROADCASTSD CONST_GET_PTR(const_log1p, 24), Z18
  VXORPD X14, X14, X14
  VXORPD X15, X15, X15
  VADDPD Z8, Z12, Z16
  VADDPD Z8, Z13, Z17
  VMULPD Z18, Z10, Z20
  VMULPD Z18, Z11, Z21
  VMOVAPD Z18, Z19
  VBROADCASTSD CONST_GET_PTR(const_log1p, 32), Z9
  VFMSUB213PD Z20, Z10, Z18 // Z18 = (Z10 * Z18) - Z20
  VFMSUB213PD Z21, Z11, Z19 // Z19 = (Z11 * Z19) - Z21
  VFMADD231PD Z9, Z10, Z18 // Z18 = (Z10 * Z9) + Z18
  VFMADD231PD Z9, Z11, Z19 // Z19 = (Z11 * Z9) + Z19
  VFMADD231PD Z12, Z2, Z16 // Z16 = (Z2 * Z12) + Z16
  VFMADD231PD Z13, Z3, Z17 // Z17 = (Z3 * Z13) + Z17
  VBROADCASTSD CONST_GET_PTR(const_log1p, 40), Z11
  VADDPD Z11, Z16, Z12
  VADDPD Z11, Z17, Z13
  VSUBPD Z12, Z11, Z10
  VSUBPD Z13, Z11, Z11
  VDIVPD Z12, Z4, Z22
  VDIVPD Z13, Z4, Z23
  VADDPD Z10, Z16, Z10
  VADDPD Z11, Z17, Z11
  VMULPD Z22, Z16, Z24
  VMULPD Z23, Z17, Z25
  VFMSUB213PD Z24, Z22, Z16  // Z16 = (Z22 * Z16) - Z24
  VFMSUB213PD Z25, Z23, Z17  // Z17 = (Z23 * Z17) - Z25
  VFNMADD213PD Z4, Z22, Z12  // Z12 = -(Z22 * Z12) + Z4
  VFNMADD213PD Z4, Z23, Z13  // Z13 = -(Z23 * Z13) + Z4
  VFNMADD231PD Z10, Z22, Z12 // Z12 = -(Z22 * Z10) + Z12
  VFNMADD231PD Z11, Z23, Z13 // Z13 = -(Z23 * Z11) + Z13
  VFMADD231PD Z22, Z14, Z16  // Z16 = (Z14 * Z22) + Z16
  VFMADD231PD Z23, Z15, Z17  // Z17 = (Z15 * Z23) + Z17
  VFMADD231PD Z12, Z24, Z16  // Z16 = (Z24 * Z12) + Z16
  VFMADD231PD Z13, Z25, Z17  // Z17 = (Z25 * Z13) + Z17
  VMULPD Z24, Z24, Z4
  VMULPD Z25, Z25, Z5
  VMULPD Z4, Z4, Z10
  VMULPD Z5, Z5, Z11
  VMULPD Z10, Z10, Z12
  VMULPD Z11, Z11, Z13
  VBROADCASTSD CONST_GET_PTR(const_log1p, 48), Z22
  VBROADCASTSD CONST_GET_PTR(const_log1p, 56), Z9
  VBROADCASTSD CONST_GET_PTR(const_log1p, 64), Z26
  VMOVAPD Z22, Z23
  VFMADD213PD Z9, Z4, Z22 // Z22 = (Z4 * Z22) + Z9
  VFMADD213PD Z9, Z5, Z23 // Z23 = (Z5 * Z23) + Z9
  VFMADD231PD Z26, Z10, Z22 // Z22 = (Z10 * Z26) + Z22
  VFMADD231PD Z26, Z11, Z23 // Z23 = (Z11 * Z26) + Z23
  VBROADCASTSD CONST_GET_PTR(const_log1p, 72), Z26
  VBROADCASTSD CONST_GET_PTR(const_log1p, 88), Z6
  VMOVAPD Z26, Z27
  VMOVAPD Z6, Z7
  VFMADD213PD.BCST CONST_GET_PTR(const_log1p, 80), Z4, Z26 // Z26 = (Z4 * Z26) + mem
  VFMADD213PD.BCST CONST_GET_PTR(const_log1p, 80), Z5, Z27 // Z27 = (Z5 * Z27) + mem
  VFMADD213PD.BCST CONST_GET_PTR(const_log1p, 96), Z4, Z6 // Z6 = (Z4 * Z6) + mem
  VFMADD213PD.BCST CONST_GET_PTR(const_log1p, 96), Z5, Z7 // Z7 = (Z5 * Z7) + mem
  VFMADD231PD Z26, Z10, Z6 // Z6 = (Z10 * Z26) + Z6
  VFMADD231PD Z27, Z11, Z7 // Z7 = (Z11 * Z27) + Z7
  VFMADD231PD Z22, Z12, Z6 // Z6 = (Z12 * Z22) + Z6
  VFMADD231PD Z23, Z13, Z7 // Z7 = (Z13 * Z23) + Z7
  VADDPD Z24, Z24, Z10
  VADDPD Z25, Z25, Z11
  VADDPD Z16, Z16, Z12
  VADDPD Z17, Z17, Z13
  VADDPD Z10, Z20, Z16
  VADDPD Z11, Z21, Z17
  VSUBPD Z16, Z20, Z20
  VSUBPD Z17, Z21, Z21
  VADDPD Z20, Z10, Z10
  VADDPD Z21, Z11, Z11
  VADDPD Z10, Z18, Z10
  VADDPD Z11, Z19, Z11
  VADDPD Z10, Z12, Z10
  VADDPD Z11, Z13, Z11
  VMULPD Z4, Z24, Z4
  VMULPD Z5, Z25, Z5
  VMULPD Z6, Z4, Z4
  VMULPD Z7, Z5, Z5
  VADDPD Z4, Z16, Z12
  VADDPD Z5, Z17, Z13
  VSUBPD Z12, Z16, Z16
  VSUBPD Z13, Z17, Z17
  VADDPD Z16, Z4, Z4
  VADDPD Z17, Z5, Z5
  VADDPD Z4, Z10, Z4
  VADDPD Z5, Z11, Z5
  VADDPD Z4, Z12, Z4
  VADDPD Z5, Z13, Z5

  VBROADCASTSD CONSTF64_POSITIVE_INF(), Z6
  VCMPPD.BCST $VCMP_IMM_GT_OS, CONST_GET_PTR(const_log1p, 104), Z2, K3
  VCMPPD.BCST $VCMP_IMM_GT_OS, CONST_GET_PTR(const_log1p, 104), Z3, K4
  VMOVAPD Z6, K3, Z4
  VMOVAPD Z6, K4, Z5
  VCMPPD $VCMP_IMM_LT_OS, Z8, Z2, K5
  VCMPPD $VCMP_IMM_LT_OS, Z8, Z3, K6
  VCMPPD $VCMP_IMM_UNORD_Q, Z14, Z2, K3
  VCMPPD $VCMP_IMM_UNORD_Q, Z15, Z3, K4
  KORW K5, K3, K3
  KORW K6, K4, K4
  VBROADCASTSD CONSTF64_NAN(), K3, Z4
  VBROADCASTSD CONSTF64_NAN(), K4, Z5
  VCMPPD $VCMP_IMM_EQ_OQ, Z8, Z2, K3
  VCMPPD $VCMP_IMM_EQ_OQ, Z8, Z3, K4
  VBROADCASTSD CONSTF64_NEGATIVE_INF(), K3, Z4
  VBROADCASTSD CONSTF64_NEGATIVE_INF(), K4, Z5
  VPCMPEQQ.BCST CONSTF64_SIGN_BIT(), Z2, K3
  VPCMPEQQ.BCST CONSTF64_SIGN_BIT(), Z3, K4
  VBROADCASTSD CONSTF64_SIGN_BIT(), K3, Z4
  VBROADCASTSD CONSTF64_SIGN_BIT(), K4, Z5

  VMOVAPD Z4, K1, Z2
  VMOVAPD Z5, K2, Z3

next:
  NEXT()

// Base-2 logarithm: log2(x)
CONST_DATA_U64(const_ln2,  0, $0x3ff5555555555555) // f64(1.3333333333333333)
CONST_DATA_U64(const_ln2,  8, $0x4090000000000000) // f64(1024)
CONST_DATA_U64(const_ln2, 16, $0xbff0000000000000) // f64(-1)
CONST_DATA_U64(const_ln2, 24, $0x3fcc2b7a962850e9) // f64(0.22007686931522777)
CONST_DATA_U64(const_ln2, 32, $0x3fd0caaeeb877481) // f64(0.26237080574885147)
CONST_DATA_U64(const_ln2, 40, $0x3fcc501739f17ba9) // f64(0.22119417504560815)
CONST_DATA_U64(const_ln2, 48, $0x3fd484ac6a7cb2dd) // f64(0.32059774779444955)
CONST_DATA_U64(const_ln2, 56, $0x3fda617636c2c254) // f64(0.41219859454853247)
CONST_DATA_U64(const_ln2, 64, $0x3fe2776c50e7ede9) // f64(0.5770780162997059)
CONST_DATA_U64(const_ln2, 72, $0x3feec709dc3a07b2) // f64(0.96179669392608091)
CONST_DATA_U64(const_ln2, 80, $0x40071547652b82fe) // f64(2.8853900817779268)
CONST_DATA_U64(const_ln2, 88, $0x3c5bedda32ebbcb1) // f64(6.0561604995516738E-18)
CONST_DATA_U64(const_ln2, 96, $0x0253040002530400) // i64(167482009228346368)
CONST_GLOBAL(const_ln2, $104)

TEXT bclog2f(SB), NOSPLIT|NOFRAME, $0
  KTESTW K1, K1
  JZ next

  KSHIFTRW $8, K1, K2

  VBROADCASTSD CONSTF64_POSITIVE_INF(), Z6
  VBROADCASTSD CONST_GET_PTR(const_ln2, 0), Z5
  VBROADCASTSD CONST_GET_PTR(const_ln2, 8), Z7

  VMULPD Z5, Z2, Z4
  VMULPD Z5, Z3, Z5
  VGETEXPPD Z4, Z4
  VGETEXPPD Z5, Z5
  VCMPPD $VCMP_IMM_EQ_OQ, Z6, Z4, K3
  VCMPPD $VCMP_IMM_EQ_OQ, Z6, Z5, K4
  VMOVAPD Z7, K3, Z4
  VMOVAPD Z7, K4, Z5
  VGETMANTPD $11, Z2, Z6
  VGETMANTPD $11, Z3, Z7

  VBROADCASTSD CONST_GET_PTR(const_ln2, 16), Z9
  VBROADCASTSD CONSTF64_1(), Z12
  VADDPD Z9, Z6, Z10
  VADDPD Z9, Z7, Z11
  VADDPD Z12, Z10, Z14
  VADDPD Z12, Z11, Z15
  VSUBPD Z14, Z10, Z16
  VSUBPD Z15, Z11, Z17
  VSUBPD Z16, Z9, Z16
  VSUBPD Z17, Z9, Z17
  VSUBPD Z14, Z6, Z14
  VSUBPD Z15, Z7, Z15
  VADDPD Z16, Z14, Z14
  VADDPD Z17, Z15, Z15
  VADDPD Z12, Z6, Z16
  VADDPD Z12, Z7, Z17
  VADDPD Z9, Z16, Z8
  VADDPD Z9, Z17, Z9
  VSUBPD Z8, Z16, Z18
  VSUBPD Z9, Z17, Z19
  VSUBPD Z18, Z12, Z18
  VSUBPD Z19, Z12, Z19
  VSUBPD Z8, Z6, Z6
  VSUBPD Z9, Z7, Z7
  VDIVPD Z16, Z12, Z8
  VDIVPD Z17, Z12, Z9
  VADDPD Z18, Z6, Z6
  VADDPD Z19, Z7, Z7
  VMULPD Z8, Z10, Z18
  VMULPD Z9, Z11, Z19
  VFMSUB213PD Z18, Z8, Z10  // Z10 = (Z8 * Z10) - Z18
  VFMSUB213PD Z19, Z9, Z11  // Z11 = (Z9 * Z11) - Z19
  VFNMADD213PD Z12, Z8, Z16 // Z16 = -(Z8 * Z16) + Z12
  VFNMADD213PD Z12, Z9, Z17 // Z17 = -(Z9 * Z17) + Z12
  VFNMADD231PD Z6, Z8, Z16  // Z16 = -(Z8 * Z6) + Z16
  VFNMADD231PD Z7, Z9, Z17  // Z17 = -(Z9 * Z7) + Z17
  VFMADD231PD Z14, Z8, Z10  // Z10 = (Z8 * Z14) + Z10
  VFMADD231PD Z15, Z9, Z11  // Z11 = (Z9 * Z15) + Z11
  VFMADD231PD Z16, Z18, Z10 // Z10 = (Z18 * Z16) + Z10
  VFMADD231PD Z17, Z19, Z11 // Z11 = (Z19 * Z17) + Z11
  VMULPD Z18, Z18, Z6
  VMULPD Z19, Z19, Z7
  VBROADCASTSD CONST_GET_PTR(const_ln2, 48), Z8
  VBROADCASTSD CONST_GET_PTR(const_ln2, 56), Z20
  VMOVAPD Z8, Z9
  VFMADD213PD Z20, Z6, Z8 // Z8 = (Z6 * Z8) + Z20
  VFMADD213PD Z20, Z7, Z9 // Z9 = (Z7 * Z9) + Z20
  VBROADCASTSD CONST_GET_PTR(const_ln2, 80), Z14
  VMULPD Z6, Z6, Z12
  VMULPD Z7, Z7, Z13
  VMULPD Z14, Z18, Z16
  VMULPD Z14, Z19, Z17
  VMOVAPD Z14, Z20
  VMOVAPD Z14, Z21
  VFMSUB213PD Z16, Z18, Z20 // Z20 = (Z18 * Z20) - Z16
  VFMSUB213PD Z17, Z19, Z21 // Z21 = (Z19 * Z21) - Z17
  VFMADD231PD Z10, Z14, Z20 // Z20 = (Z14 * Z10) + Z20
  VFMADD231PD Z11, Z14, Z21 // Z21 = (Z14 * Z11) + Z21
  VBROADCASTSD CONST_GET_PTR(const_ln2, 64), Z10
  VBROADCASTSD CONST_GET_PTR(const_ln2, 72), Z22
  VMOVAPD Z10, Z11
  VMULPD Z12, Z12, Z14
  VMULPD Z13, Z13, Z15
  VFMADD213PD Z22, Z6, Z10 // Z10 = (Z6 * Z10) + Z22
  VFMADD213PD Z22, Z7, Z11 // Z11 = (Z7 * Z11) + Z22
  VFMADD231PD Z8, Z12, Z10 // Z10 = (Z12 * Z8) + Z10
  VFMADD231PD Z9, Z13, Z11 // Z11 = (Z13 * Z9) + Z11
  VBROADCASTSD CONST_GET_PTR(const_ln2, 24), Z8
  VBROADCASTSD CONST_GET_PTR(const_ln2, 32), Z22
  VBROADCASTSD CONST_GET_PTR(const_ln2, 40), Z23
  VMOVAPD Z8, Z9
  VFMADD213PD Z22, Z6, Z8   // Z8 = (Z6 * Z8) + Z22
  VFMADD213PD Z22, Z7, Z9   // Z9 = (Z7 * Z9) + Z22
  VBROADCASTSD CONST_GET_PTR(const_ln2, 88), Z22
  VFMADD231PD Z23, Z12, Z8  // Z8 = (Z12 * 23) + Z8
  VFMADD231PD Z23, Z13, Z9  // Z9 = (Z13 * 23) + Z9
  VFMADD231PD Z22, Z18, Z20 // Z20 = (Z18 * 22) + Z20
  VFMADD231PD Z22, Z19, Z21 // Z21 = (Z19 * 22) + Z21
  VFMADD231PD Z8, Z14, Z10  // Z10 = (Z14 * Z8) + Z10
  VFMADD231PD Z9, Z15, Z11  // Z11 = (Z15 * Z9) + Z11
  VADDPD Z16, Z4, Z8
  VADDPD Z17, Z5, Z9
  VSUBPD Z4, Z8, Z12
  VSUBPD Z5, Z9, Z13
  VSUBPD Z12, Z8, Z14
  VSUBPD Z13, Z9, Z15
  VSUBPD Z14, Z4, Z4
  VSUBPD Z15, Z5, Z5
  VSUBPD Z12, Z16, Z12
  VSUBPD Z13, Z17, Z13
  VADDPD Z4, Z12, Z4
  VADDPD Z5, Z13, Z5
  VADDPD Z20, Z4, Z4
  VADDPD Z21, Z5, Z5
  VMULPD Z6, Z18, Z6
  VMULPD Z7, Z19, Z7
  VMULPD Z10, Z6, Z6
  VMULPD Z11, Z7, Z7
  VADDPD Z6, Z8, Z10
  VADDPD Z7, Z9, Z11
  VSUBPD Z8, Z10, Z12
  VSUBPD Z9, Z11, Z13
  VSUBPD Z12, Z10, Z14
  VSUBPD Z13, Z11, Z15
  VSUBPD Z14, Z8, Z8
  VSUBPD Z15, Z9, Z9
  VSUBPD Z12, Z6, Z6
  VSUBPD Z13, Z7, Z7
  VADDPD Z8, Z6, Z6
  VADDPD Z9, Z7, Z7
  VADDPD Z6, Z4, Z4
  VADDPD Z7, Z5, Z5
  VPBROADCASTQ CONST_GET_PTR(const_ln2, 96), Z6
  VADDPD Z4, Z10, Z4
  VADDPD Z5, Z11, Z5

  VFIXUPIMMPD $0, Z6, Z2, Z4
  VFIXUPIMMPD $0, Z6, Z3, Z5

  VMOVAPD Z4, K1, Z2
  VMOVAPD Z5, K2, Z3

next:
  NEXT()

// Base-10 logarithm: log10(x)
CONST_DATA_U64(const_ln10,   0, $0x3ff5555555555555) // f64(1.3333333333333333)
CONST_DATA_U64(const_ln10,   8, $0x4090000000000000) // f64(1024)
CONST_DATA_U64(const_ln10,  16, $0xbff0000000000000) // f64(-1)
CONST_DATA_U64(const_ln10,  24, $0x3fb0f63bd2a55192) // f64(0.066257227828208337)
CONST_DATA_U64(const_ln10,  32, $0x3fb4381a2bf55d48) // f64(0.078981052143139441)
CONST_DATA_U64(const_ln10,  40, $0x3fb10895f3ea9496) // f64(0.066537258195767585)
CONST_DATA_U64(const_ln10,  48, $0x3fb8b4d992891f74) // f64(0.096509550357152751)
CONST_DATA_U64(const_ln10,  56, $0x3fbfc3fa6f6d7821) // f64(0.1240841409721445)
CONST_DATA_U64(const_ln10,  64, $0x3fc63c6277499b88) // f64(0.17371779274546051)
CONST_DATA_U64(const_ln10,  72, $0x3fd287a7636f4570) // f64(0.28952965460219726)
CONST_DATA_U64(const_ln10,  80, $0x3fd34413509f79ff) // f64(0.3010299956639812)
CONST_DATA_U64(const_ln10,  88, $0xbc49dc1da994fd21) // f64(-2.8037281277851704E-18)
CONST_DATA_U64(const_ln10,  96, $0x3febcb7b1526e50e) // f64(0.86858896380650363)
CONST_DATA_U64(const_ln10, 104, $0x3c6a5b1dc915f38f) // f64(1.1430059694096389E-17)
CONST_DATA_U64(const_ln10, 112, $0x0253040002530400) // i64(167482009228346368)
CONST_GLOBAL(const_ln10, $120)

TEXT bclog10f(SB), NOSPLIT|NOFRAME, $0
  KTESTW K1, K1
  JZ next

  KSHIFTRW $8, K1, K2

  VBROADCASTSD CONSTF64_POSITIVE_INF(), Z6
  VBROADCASTSD CONST_GET_PTR(const_ln10, 0), Z5
  VBROADCASTSD CONST_GET_PTR(const_ln10, 8), Z7

  VMULPD Z5, Z2, Z4
  VMULPD Z5, Z3, Z5
  VGETEXPPD Z4, Z4
  VGETEXPPD Z5, Z5
  VCMPPD $VCMP_IMM_EQ_OQ, Z6, Z4, K3
  VCMPPD $VCMP_IMM_EQ_OQ, Z6, Z5, K4
  VMOVAPD Z7, K3, Z4
  VMOVAPD Z7, K4, Z5
  VGETMANTPD $11, Z2, Z6
  VGETMANTPD $11, Z3, Z7
  VBROADCASTSD CONST_GET_PTR(const_ln10, 16), Z9
  VBROADCASTSD CONSTF64_1(), Z12
  VADDPD Z9, Z6, Z10
  VADDPD Z9, Z7, Z11
  VADDPD Z12, Z10, Z14
  VADDPD Z12, Z11, Z15
  VSUBPD Z14, Z10, Z16
  VSUBPD Z15, Z11, Z17
  VSUBPD Z16, Z9, Z16
  VSUBPD Z17, Z9, Z17
  VSUBPD Z14, Z6, Z14
  VSUBPD Z15, Z7, Z15
  VADDPD Z16, Z14, Z14
  VADDPD Z17, Z15, Z15
  VADDPD Z12, Z6, Z16
  VADDPD Z12, Z7, Z17
  VADDPD Z9, Z16, Z8
  VADDPD Z9, Z17, Z9
  VSUBPD Z8, Z16, Z18
  VSUBPD Z9, Z17, Z19
  VSUBPD Z18, Z12, Z18
  VSUBPD Z19, Z12, Z19
  VSUBPD Z8, Z6, Z6
  VSUBPD Z9, Z7, Z7
  VADDPD Z18, Z6, Z6
  VADDPD Z19, Z7, Z7
  VDIVPD Z16, Z12, Z8
  VDIVPD Z17, Z12, Z9
  VMULPD Z8, Z10, Z18
  VMULPD Z9, Z11, Z19
  VFMSUB213PD Z18, Z8, Z10  // Z10 = (Z8 * Z10) - Z18
  VFMSUB213PD Z19, Z9, Z11  // Z11 = (Z9 * Z11) - Z19
  VFNMADD213PD Z12, Z8, Z16 // Z16 = -(Z8 * Z16) + Z12
  VFNMADD213PD Z12, Z9, Z17 // Z17 = -(Z9 * Z17) + Z12
  VFNMADD231PD Z6, Z8, Z16  // Z16 = -(Z8 * Z6) + Z16
  VFNMADD231PD Z7, Z9, Z17  // Z17 = -(Z9 * Z7) + Z17
  VFMADD231PD Z14, Z8, Z10  // Z10 = (Z8 * Z14) + Z10
  VFMADD231PD Z15, Z9, Z11  // Z11 = (Z9 * Z15) + Z11
  VFMADD231PD Z16, Z18, Z10 // Z10 = (Z18 * Z16) + Z10
  VFMADD231PD Z17, Z19, Z11 // Z11 = (Z19 * Z17) + Z11
  VMULPD Z18, Z18, Z6
  VMULPD Z19, Z19, Z7
  VMULPD Z6, Z6, Z8
  VMULPD Z7, Z7, Z9
  VBROADCASTSD CONST_GET_PTR(const_ln10, 24), Z12
  VBROADCASTSD CONST_GET_PTR(const_ln10, 32), Z14
  VBROADCASTSD CONST_GET_PTR(const_ln10, 40), Z15
  VMOVAPD Z12, Z13
  VFMADD213PD Z14, Z6, Z12 // Z12 = (Z6 * Z12) + Z14
  VFMADD213PD Z14, Z7, Z13 // Z13 = (Z7 * Z13) + Z14
  VFMADD231PD Z15, Z8, Z12 // Z12 = (Z8 * Z15) + Z12
  VFMADD231PD Z15, Z9, Z13 // Z13 = (Z9 * Z15) + Z13
  VBROADCASTSD CONST_GET_PTR(const_ln10, 48), Z14
  VBROADCASTSD CONST_GET_PTR(const_ln10, 64), Z16
  VBROADCASTSD CONST_GET_PTR(const_ln10, 56), Z20
  VMOVAPD Z14, Z15
  VMOVAPD Z16, Z17
  VFMADD213PD Z20, Z6, Z14 // Z14 = (Z6 * Z14) + Z20
  VFMADD213PD Z20, Z7, Z15 // Z15 = (Z7 * Z15) + Z20
  VBROADCASTSD CONST_GET_PTR(const_ln10, 72), Z22
  VMULPD Z8, Z8, Z20
  VMULPD Z9, Z9, Z21
  VFMADD213PD Z22, Z6, Z16 // Z16 = (Z6 * Z16) + Z22
  VFMADD213PD Z22, Z7, Z17 // Z17 = (Z7 * Z17) + Z22
  VFMADD231PD Z14, Z8, Z16 // Z16 = (Z8 * Z14) + Z16
  VFMADD231PD Z15, Z9, Z17 // Z17 = (Z9 * Z15) + Z17
  VBROADCASTSD CONST_GET_PTR(const_ln10, 80), Z8
  VBROADCASTSD CONST_GET_PTR(const_ln10, 88), Z22
  VMOVAPD Z8, Z9
  VMULPD Z8, Z4, Z14
  VMULPD Z9, Z5, Z15
  VFMSUB213PD Z14, Z4, Z8 // Z8 = (Z4 * Z8) - Z14
  VFMSUB213PD Z15, Z5, Z9 // Z9 = (Z5 * Z9) - Z15
  VFMADD231PD Z22, Z4, Z8 // Z8 = (Z4 * Z22) + Z8
  VFMADD231PD Z22, Z5, Z9 // Z9 = (Z5 * Z22) + Z9
  VBROADCASTSD CONST_GET_PTR(const_ln10, 96), Z4
  VBROADCASTSD CONST_GET_PTR(const_ln10, 104), Z5
  VFMADD231PD Z12, Z20, Z16 // Z16 = (Z20 * Z12) + Z16
  VFMADD231PD Z13, Z21, Z17 // Z17 = (Z21 * Z13) + Z17
  VMULPD Z4, Z18, Z12
  VMULPD Z4, Z19, Z13
  VMOVAPD Z4, Z20
  VMOVAPD Z4, Z21
  VFMSUB213PD Z12, Z18, Z20 // Z20 = (Z18 * Z20) - Z12
  VFMSUB213PD Z13, Z19, Z21 // Z21 = (Z19 * Z21) - Z13
  VFMADD231PD Z10, Z4, Z20  // Z20 = (Z4 * Z10) + Z20
  VFMADD231PD Z11, Z4, Z21  // Z21 = (Z4 * Z11) + Z21
  VFMADD231PD Z5, Z18, Z20 // Z20 = (Z18 * Z5) + Z20
  VFMADD231PD Z5, Z19, Z21 // Z21 = (Z19 * Z5) + Z21
  VADDPD Z12, Z14, Z4
  VADDPD Z13, Z15, Z5
  VSUBPD Z4, Z14, Z10
  VSUBPD Z5, Z15, Z11
  VADDPD Z10, Z12, Z10
  VADDPD Z11, Z13, Z11
  VADDPD Z10, Z8, Z8
  VADDPD Z11, Z9, Z9
  VADDPD Z20, Z8, Z8
  VADDPD Z21, Z9, Z9
  VMULPD Z6, Z18, Z6
  VMULPD Z7, Z19, Z7
  VMULPD Z16, Z6, Z6
  VMULPD Z17, Z7, Z7
  VADDPD Z6, Z4, Z10
  VADDPD Z7, Z5, Z11
  VSUBPD Z10, Z4, Z4
  VSUBPD Z11, Z5, Z5
  VADDPD Z4, Z6, Z4
  VADDPD Z5, Z7, Z5
  VADDPD Z4, Z8, Z4
  VADDPD Z5, Z9, Z5
  VBROADCASTSD CONST_GET_PTR(const_ln10, 112), Z6
  VADDPD Z4, Z10, Z4
  VADDPD Z5, Z11, Z5
  VFIXUPIMMPD $0, Z6, Z2, Z4
  VFIXUPIMMPD $0, Z6, Z3, Z5

  VMOVAPD Z4, K1, Z2
  VMOVAPD Z5, K2, Z3

next:
  NEXT()

// Sin/Cos/Tan calculation has 3 code paths:
//
//   - case 'a': values lesser than 15
//   - case 'b': values lesser than 1e14
//   - case 'c': other values that require input domain reduction
//
// Execution:
//
//   - if inputs in all lanes are lesser than 15, only case 'a' is executed
//   - if there are values equal or greater than 15, case 'b' is executed
//   - if there are values equal or greater than 1e14, case 'c' is executed
//   - each case is properly blended to the output so lanes don't influence each other
//
// NOTE: Case 'c' requires a very expensive input range reduction to PI. It
//       uses a lookup table, which is provided by `bc_constant_rempi.h`.

// Sine: sin(x)
CONST_DATA_U64(const_sin,   0, $0x402e000000000000) // f64(15)
CONST_DATA_U64(const_sin,   8, $0x3fd45f306dc9c883) // f64(0.31830988618379069)
CONST_DATA_U64(const_sin,  16, $0xc00921fb54442d18) // f64(-3.1415926535897931)
CONST_DATA_U64(const_sin,  24, $0xbca1a62633145c07) // f64(-1.2246467991473532E-16)
CONST_DATA_U64(const_sin,  32, $0x3e545f306dc9c883) // f64(1.8972747694479864E-8)
CONST_DATA_U64(const_sin,  40, $0x4170000000000000) // f64(16777216)
CONST_DATA_U64(const_sin,  48, $0xc00921fb50000000) // f64(-3.1415926218032837)
CONST_DATA_U64(const_sin,  56, $0xbe6110b460000000) // f64(-3.1786509424591713E-8)
CONST_DATA_U64(const_sin,  64, $0xbca1a62630000000) // f64(-1.2246467864107189E-16)
CONST_DATA_U64(const_sin,  72, $0xbaf8a2e03707344a) // f64(-1.27366343270219E-24)
CONST_DATA_U64(const_sin,  80, $0x42d6bcc41e900000) // f64(1.0E+14)
CONST_DATA_U64(const_sin,  88, $0x4010000000000000) // f64(4)
CONST_DATA_U64(const_sin,  96, $0x3fd0000000000000) // f64(0.25)
CONST_DATA_U64(const_sin, 104, $0x401921fb54442d18) // f64(6.2831853071795862)
CONST_DATA_U64(const_sin, 112, $0x3cb1a62633145c07) // f64(2.4492935982947064E-16)
CONST_DATA_U64(const_sin, 120, $0x3fe6666666666666) // f64(0.69999999999999996)
CONST_DATA_U64(const_sin, 128, $0x0000000100000001) // i64(4294967297)
CONST_DATA_U64(const_sin, 136, $0xbff921fb54442d18) // i64(-4613618979930100456)
CONST_DATA_U64(const_sin, 144, $0xbc91a62633145c07) // i64(-4858919839960114169)
CONST_DATA_U64(const_sin, 152, $0x3ce8811a03b2b11d) // f64(2.7205241613852957E-15)
CONST_DATA_U64(const_sin, 160, $0xbd6ae422bc319350) // f64(-7.6429259411395447E-13)
CONST_DATA_U64(const_sin, 168, $0x3de6123c74705f67) // f64(1.605893701172779E-10)
CONST_DATA_U64(const_sin, 176, $0xbe5ae6454baa2959) // f64(-2.5052106814843123E-8)
CONST_DATA_U64(const_sin, 184, $0x3ec71de3a525fbed) // f64(2.7557319210442822E-6)
CONST_DATA_U64(const_sin, 192, $0xbf2a01a01a014225) // f64(-1.9841269841204645E-4)
CONST_DATA_U64(const_sin, 200, $0x3f811111111110b9) // f64(0.0083333333333331805)
CONST_DATA_U64(const_sin, 208, $0xbfc5555555555555) // f64(-0.16666666666666666)
CONST_DATA_U32(const_sin, 216, $0x000003ff) // i32(1023)
CONST_DATA_U32(const_sin, 220, $0xffffffc9) // i32(4294967241)
CONST_DATA_U32(const_sin, 224, $0x00000285) // i32(645)
CONST_DATA_U32(const_sin, 228, $0xffffffc0) // i32(4294967232)
CONST_DATA_U32(const_sin, 232, $0x00000006) // i32(6)
CONST_DATA_U32(const_sin, 236, $0x00000002) // i32(2)
CONST_DATA_U32(const_sin, 240, $0x00000001) // i32(1)
CONST_GLOBAL(const_sin, $244)

TEXT bcsinf(SB), NOSPLIT|NOFRAME, $0
  KTESTW K1, K1
  JZ next

  // case 'a': this case is implicit and is always executed
  KSHIFTRW $8, K1, K2
  VBROADCASTSD CONSTF64_ABS_BITS(), Z7
  VBROADCASTSD CONST_GET_PTR(const_sin, 0), Z4
  VBROADCASTSD CONST_GET_PTR(const_sin, 8), Z5

  VANDPD Z7, Z2, Z6
  VANDPD Z7, Z3, Z7

  // K3/K4 contain lanes where x >= 15, which require more work
  VCMPPD $VCMP_IMM_GE_OQ, Z4, Z6, K1, K3
  VCMPPD $VCMP_IMM_GE_OQ, Z4, Z7, K2, K4
  KUNPCKBW K3, K4, K3

  VMULPD Z5, Z2, Z4
  VMULPD Z5, Z3, Z5

  VRNDSCALEPD $8, Z4, Z8
  VRNDSCALEPD $8, Z5, Z9
  VCVTPD2DQ.RN_SAE Z8, Y4
  VCVTPD2DQ.RN_SAE Z9, Y5
  VINSERTI32X8 $1, Y5, Z4, Z4

  VBROADCASTSD CONST_GET_PTR(const_sin, 16), Z10
  VBROADCASTSD CONST_GET_PTR(const_sin, 24), Z12
  VMOVAPD Z10, Z11
  VFMADD213PD Z2, Z8, Z10 // Z10 = (Z8 * Z10) + Z2
  VFMADD213PD Z3, Z9, Z11 // Z11 = (Z9 * Z11) + Z3
  VMULPD Z12, Z8, Z8
  VMULPD Z12, Z9, Z9
  VADDPD Z8, Z10, Z14
  VADDPD Z9, Z11, Z15
  VSUBPD Z14, Z10, Z10
  VSUBPD Z15, Z11, Z11
  VADDPD Z10, Z8, Z16
  VADDPD Z11, Z9, Z17

  // Jump to 'sin_case_b' if one or more lane has x >= 15
  KTESTW K3, K3
  JNE sin_case_b

sin_eval_poly:
  // Polynomial evaluation; code shared by all cases
  VMULPD Z14, Z14, Z6
  VMULPD Z15, Z15, Z7
  VADDPD Z14, Z14, Z8
  VADDPD Z15, Z15, Z9

  VMOVAPD Z14, Z10
  VMOVAPD Z15, Z11
  VFMSUB213PD Z6, Z14, Z10 // Z10 = (Z14 * Z10) - Z6
  VFMSUB213PD Z7, Z15, Z11 // Z11 = (Z15 * Z11) - Z7
  VFMADD231PD Z8, Z16, Z10 // Z10 = (Z16 * Z8) + Z10
  VFMADD231PD Z9, Z17, Z11 // Z11 = (Z17 * Z9) + Z11

  VMULPD Z6, Z6, Z8
  VMULPD Z7, Z7, Z9
  VMULPD Z8, Z8, Z12
  VMULPD Z9, Z9, Z13

  VBROADCASTSD CONST_GET_PTR(const_sin, 152), Z18
  VBROADCASTSD CONST_GET_PTR(const_sin, 168), Z20
  VBROADCASTSD CONST_GET_PTR(const_sin, 184), Z22
  VMOVAPD Z18, Z19
  VMOVAPD Z20, Z21
  VMOVAPD Z22, Z23

  VBROADCASTSD CONST_GET_PTR(const_sin, 160), Z24
  VBROADCASTSD CONST_GET_PTR(const_sin, 176), Z25
  VFMADD213PD Z24, Z6, Z18 // Z18 = (Z6 * Z18) + Z24
  VFMADD213PD Z24, Z7, Z19 // Z19 = (Z7 * Z19) + Z24
  VFMADD213PD Z25, Z6, Z20 // Z20 = (Z6 * Z20) + Z25
  VFMADD213PD Z25, Z7, Z21 // Z21 = (Z7 * Z21) + Z25

  VBROADCASTSD CONST_GET_PTR(const_sin, 192), Z24
  VBROADCASTSD CONST_GET_PTR(const_sin, 200), Z25
  VFMADD213PD Z24, Z6, Z22  // Z22 = (Z6 * Z22) + Z24
  VFMADD213PD Z24, Z7, Z23  // Z23 = (Z7 * Z23) + Z24
  VFMADD231PD Z20, Z8, Z22  // Z22 = (Z8 * Z20) + Z22
  VFMADD231PD Z21, Z9, Z23  // Z23 = (Z9 * Z21) + Z23
  VFMADD231PD Z18, Z12, Z22 // Z22 = (Z12 * Z18) + Z22
  VFMADD231PD Z19, Z13, Z23 // Z23 = (Z13 * Z19) + Z23
  VFMADD213PD Z25, Z6, Z22  // Z22 = (Z6 * Z22) + Z25
  VFMADD213PD Z25, Z7, Z23  // Z23 = (Z7 * Z23) + Z25

  VBROADCASTSD CONST_GET_PTR(const_sin, 208), Z13
  VMULPD Z22, Z6, Z8
  VMULPD Z23, Z7, Z9
  VADDPD Z13, Z8, Z18
  VADDPD Z13, Z9, Z19
  VSUBPD Z18, Z13, Z12
  VSUBPD Z19, Z13, Z13
  VADDPD Z12, Z8, Z8
  VADDPD Z13, Z9, Z9
  VMULPD Z18, Z6, Z12
  VMULPD Z19, Z7, Z13
  VMOVAPD Z6, Z20
  VMOVAPD Z7, Z21
  VFMSUB213PD Z12, Z18, Z20 // Z20 = (Z18 * Z20) - Z12
  VFMSUB213PD Z13, Z19, Z21 // Z21 = (Z19 * Z21) - Z13
  VFMADD231PD Z8, Z6, Z20   // Z20 = (Z6 * Z8) + Z20
  VFMADD231PD Z9, Z7, Z21   // Z21 = (Z7 * Z9) + Z21
  VFMADD231PD Z10, Z18, Z20 // Z20 = (Z18 * Z10) + Z20
  VFMADD231PD Z11, Z19, Z21 // Z21 = (Z19 * Z11) + Z21

  VBROADCASTSD CONSTF64_1(), Z7
  VADDPD Z7, Z12, Z8
  VADDPD Z7, Z13, Z9
  VSUBPD Z8, Z7, Z6
  VSUBPD Z9, Z7, Z7
  VADDPD Z6, Z12, Z6
  VADDPD Z7, Z13, Z7
  VADDPD Z20, Z6, Z6
  VADDPD Z21, Z7, Z7
  VMULPD Z6, Z14, Z6
  VMULPD Z7, Z15, Z7
  VFMADD231PD Z16, Z8, Z6 // Z6 = (Z8 * Z16) + Z6
  VFMADD231PD Z17, Z9, Z7 // Z7 = (Z9 * Z17) + Z7
  VFMADD231PD Z8, Z14, Z6 // Z6 = (Z14 * Z8) + Z6
  VFMADD231PD Z9, Z15, Z7 // Z7 = (Z15 * Z9) + Z7

  VPANDD.BCST CONST_GET_PTR(const_sin, 128), Z4, Z4
  VPCMPEQD.BCST CONST_GET_PTR(const_sin, 240), Z4, K3
  KSHIFTRW $8, K3, K4
  VPBROADCASTQ.Z CONSTF64_SIGN_BIT(), K3, Z4
  VPBROADCASTQ.Z CONSTF64_SIGN_BIT(), K4, Z5
  VXORPD Z6, Z4, Z4
  VXORPD Z7, Z5, Z5
  VXORPD X6, X6, X6
  VCMPPD $VCMP_IMM_EQ_OQ, Z6, Z2, K3
  VCMPPD $VCMP_IMM_EQ_OQ, Z6, Z3, K4
  VMOVAPD Z2, K3, Z4
  VMOVAPD Z3, K4, Z5
  VMOVAPD Z4, K1, Z2
  VMOVAPD Z5, K2, Z3

next:
  NEXT()

sin_case_b:
  // case 'b': one or more lane has x >= 1e14
  VBROADCASTSD CONST_GET_PTR(const_sin, 32), Z9
  VMULPD Z9, Z2, Z8
  VMULPD Z9, Z3, Z9
  VRNDSCALEPD $11, Z8, Z8
  VRNDSCALEPD $11, Z9, Z9
  VBROADCASTSD CONST_GET_PTR(const_sin, 8), Z10
  VBROADCASTSD CONST_GET_PTR(const_sin, 40), Z11
  VMULPD Z11, Z8, Z8
  VMULPD Z11, Z9, Z9
  VMOVAPD Z10, Z11
  VFMSUB213PD Z8, Z2, Z10 // Z10 = (Z2 * Z10) - Z8
  VFMSUB213PD Z9, Z3, Z11 // Z11 = (Z3 * Z11) - Z9
  VRNDSCALEPD $8, Z10, Z12
  VRNDSCALEPD $8, Z11, Z13
  VBROADCASTSD CONST_GET_PTR(const_sin, 48), Z10
  VBROADCASTSD CONST_GET_PTR(const_sin, 48), Z11
  VMULPD Z10, Z12, Z18
  VMULPD Z11, Z13, Z19
  VFMADD213PD Z2, Z8, Z10 // Z10 = (Z8 * Z10) + Z2
  VFMADD213PD Z3, Z9, Z11 // Z11 = (Z9 * Z11) + Z3
  VADDPD Z18, Z10, Z20
  VADDPD Z19, Z11, Z21
  VSUBPD Z20, Z10, Z10
  VSUBPD Z21, Z11, Z11
  VADDPD Z10, Z18, Z10
  VADDPD Z11, Z19, Z11

  VBROADCASTSD CONST_GET_PTR(const_sin, 56), Z19
  VMULPD Z19, Z8, Z22
  VMULPD Z19, Z9, Z23
  VADDPD Z20, Z22, Z24
  VADDPD Z21, Z23, Z25
  VSUBPD Z20, Z24, Z26
  VSUBPD Z21, Z25, Z27
  VSUBPD Z26, Z24, Z5
  VSUBPD Z27, Z25, Z18
  VSUBPD Z5, Z20, Z20
  VSUBPD Z18, Z21, Z21
  VSUBPD Z26, Z22, Z22
  VSUBPD Z27, Z23, Z23
  VADDPD Z20, Z22, Z20
  VADDPD Z21, Z23, Z21
  VADDPD Z20, Z10, Z10
  VADDPD Z21, Z11, Z11
  VMULPD Z19, Z12, Z18
  VMULPD Z19, Z13, Z19
  VADDPD Z24, Z18, Z20
  VADDPD Z25, Z19, Z21
  VSUBPD Z24, Z20, Z22
  VSUBPD Z25, Z21, Z23
  VSUBPD Z22, Z20, Z26
  VSUBPD Z23, Z21, Z27
  VSUBPD Z26, Z24, Z24
  VSUBPD Z27, Z25, Z25
  VSUBPD Z22, Z18, Z18
  VSUBPD Z23, Z19, Z19
  VADDPD Z24, Z18, Z18
  VADDPD Z25, Z19, Z19

  VBROADCASTSD CONST_GET_PTR(const_sin, 64), Z23
  VADDPD Z10, Z18, Z10
  VADDPD Z11, Z19, Z11
  VMULPD Z23, Z8, Z18
  VMULPD Z23, Z9, Z19
  VADDPD Z20, Z18, Z24
  VADDPD Z21, Z19, Z25
  VSUBPD Z20, Z24, Z26
  VSUBPD Z21, Z25, Z27
  VSUBPD Z26, Z24, Z5
  VSUBPD Z27, Z25, Z22
  VSUBPD Z5, Z20, Z20
  VSUBPD Z22, Z21, Z21
  VSUBPD Z26, Z18, Z18
  VSUBPD Z27, Z19, Z19
  VADDPD Z20, Z18, Z18
  VADDPD Z21, Z19, Z19
  VADDPD Z10, Z18, Z10
  VADDPD Z11, Z19, Z11
  VMULPD Z23, Z12, Z18
  VMULPD Z23, Z13, Z19
  VADDPD Z24, Z18, Z20
  VADDPD Z25, Z19, Z21
  VSUBPD Z24, Z20, Z22
  VSUBPD Z25, Z21, Z23
  VSUBPD Z22, Z20, Z26
  VSUBPD Z23, Z21, Z27
  VSUBPD Z26, Z24, Z24
  VSUBPD Z27, Z25, Z25
  VSUBPD Z22, Z18, Z18
  VSUBPD Z23, Z19, Z19
  VADDPD Z24, Z18, Z18
  VADDPD Z25, Z19, Z19
  VADDPD Z10, Z18, Z10
  VADDPD Z11, Z19, Z11
  VBROADCASTSD CONST_GET_PTR(const_sin, 72), Z19
  VADDPD Z12, Z8, Z8
  VADDPD Z13, Z9, Z9
  VMULPD Z19, Z8, Z18
  VMULPD Z19, Z9, Z19
  VADDPD Z20, Z18, Z8
  VADDPD Z21, Z19, Z9
  VSUBPD Z8, Z20, Z20
  VSUBPD Z9, Z21, Z21
  VADDPD Z20, Z18, Z18
  VADDPD Z21, Z19, Z19
  VADDPD Z10, Z18, Z10
  VADDPD Z11, Z19, Z11

  VCVTPD2DQ.RN_SAE Z12, Y18
  VCVTPD2DQ.RN_SAE Z13, Y19
  VINSERTI32X8 $1, Y19, Z18, K3, Z4

  VBROADCASTSD CONST_GET_PTR(const_sin, 80), Z20
  VMOVAPD Z8, K3, Z14
  VMOVAPD Z9, K4, Z15
  VMOVAPD Z10, K3, Z16
  VMOVAPD Z11, K4, Z17

  VCMPPD $VCMP_IMM_GE_OS, Z20, Z6, K3, K3
  VCMPPD $VCMP_IMM_GE_OS, Z20, Z7, K4, K4
  KUNPCKBW K3, K4, K3
  KTESTW K3, K3
  JZ sin_eval_poly

  // case 'c': one or more lane has x >= 1e14
  VBROADCASTSD CONSTF64_POSITIVE_INF(), Z12
  MOVL $0xAAAA, R8
  LEAQ CONST_GET_PTR(const_rempi, 0), R15

  // K0 contains mask of all inputs that are either +INF or -INF
  VCMPPD $VCMP_IMM_EQ_OQ, Z12, Z6, K3, K0
  VCMPPD $VCMP_IMM_EQ_OQ, Z12, Z7, K4, K5
  KUNPCKBW K0, K5, K0

  VGETEXPPD Z2, Z12
  VGETEXPPD Z3, Z13
  VCVTPD2DQ.RN_SAE Z12, Y8
  VCVTPD2DQ.RN_SAE Z13, Y9
  VINSERTI32X8 $1, Y9, Z8, Z8

  VPCMPGTD.BCST CONSTD_NEG_1(), Z8, K5
  VPANDD.BCST CONST_GET_PTR(const_sin, 216), Z8, Z8
  VMOVDQA32.Z Z8, K5, Z8
  VPADDD.BCST CONST_GET_PTR(const_sin, 220), Z8, Z10
  VPCMPGTD.BCST CONST_GET_PTR(const_sin, 224), Z10, K5
  VPBROADCASTD.Z CONST_GET_PTR(const_sin, 228), K5, Z8
  VPSLLD $20, Z8, Z8
  VEXTRACTI32X8 $1, Z8, Y9
  KMOVW R8, K5
  VPEXPANDD.Z Z8, K5, Z8
  VPEXPANDD.Z Z9, K5, Z9
  VPADDQ Z2, Z8, Z8
  VPADDQ Z3, Z9, Z9
  VPSRAD $31, Z10, Z18
  VPANDND Z10, Z18, Z10
  VPSLLD $2, Z10, Z10
  VEXTRACTI32X8 $1, Z10, Y11

  KMOVB K3, K5
  KMOVB K4, K6
  VXORPD X18, X18, X18
  VXORPD X19, X19, X19
  VGATHERDPD 0(R15)(Y10*8), K5, Z18
  VGATHERDPD 0(R15)(Y11*8), K6, Z19
  ADDQ $8, R15

  VMULPD Z8, Z18, Z20
  VMULPD Z9, Z19, Z21
  VFMSUB213PD Z20, Z8, Z18 // Z18 = (Z8 * Z18) - Z20
  VFMSUB213PD Z21, Z9, Z19 // Z19 = (Z9 * Z19) - Z21
  VBROADCASTSD CONST_GET_PTR(const_sin, 88), Z23
  VMULPD Z23, Z20, Z24
  VMULPD Z23, Z21, Z25
  VRNDSCALEPD $8, Z24, Z24
  VRNDSCALEPD $8, Z25, Z25
  VRNDSCALEPD $8, Z20, Z26
  VRNDSCALEPD $8, Z21, Z27
  VMULPD Z23, Z26, Z26
  VMULPD Z23, Z27, Z27
  VSUBPD Z26, Z24, Z26
  VSUBPD Z27, Z25, Z27
  VCVTPD2DQ.RZ_SAE Z26, Y26
  VCVTPD2DQ.RZ_SAE Z27, Y27
  VINSERTI32X8 $1, Y27, Z26, Z26

  VBROADCASTSD CONST_GET_PTR(const_sin, 96), Z27
  VMULPD Z27, Z24, Z24
  VMULPD Z27, Z25, Z25
  VSUBPD Z24, Z20, Z20
  VSUBPD Z25, Z21, Z21
  VADDPD Z18, Z20, Z24
  VADDPD Z19, Z21, Z25
  VSUBPD Z24, Z20, Z20
  VSUBPD Z25, Z21, Z21
  VADDPD Z20, Z18, Z18
  VADDPD Z21, Z19, Z19

  KMOVB K3, K5
  KMOVB K4, K6
  VXORPD X20, X20, X20
  VXORPD X21, X21, X21
  VGATHERDPD 0(R15)(Y10*8), K5, Z20
  VGATHERDPD 0(R15)(Y11*8), K6, Z21
  ADDQ $8, R15

  VMULPD Z8, Z20, Z12
  VMULPD Z9, Z21, Z13
  VFMSUB213PD Z12, Z8, Z20 // Z20 = (Z8 * Z20) - Z12
  VFMSUB213PD Z13, Z9, Z21 // Z21 = (Z9 * Z21) - Z13
  VADDPD Z18, Z20, Z18
  VADDPD Z19, Z21, Z19
  VADDPD Z24, Z12, Z20
  VADDPD Z25, Z13, Z21
  VSUBPD Z24, Z20, Z6
  VSUBPD Z25, Z21, Z7
  VSUBPD Z6, Z20, Z5
  VSUBPD Z5, Z24, Z24
  VSUBPD Z7, Z21, Z5
  VSUBPD Z5, Z25, Z25
  VSUBPD Z6, Z12, Z12
  VSUBPD Z7, Z13, Z13
  VADDPD Z24, Z12, Z24
  VADDPD Z25, Z13, Z25
  VADDPD Z24, Z18, Z24
  VADDPD Z25, Z19, Z25
  VMULPD Z23, Z20, Z18
  VMULPD Z23, Z21, Z19
  VRNDSCALEPD $8, Z18, Z12
  VRNDSCALEPD $8, Z19, Z13
  VRNDSCALEPD $8, Z20, Z18
  VRNDSCALEPD $8, Z21, Z19
  VMULPD Z23, Z18, Z18
  VMULPD Z23, Z19, Z19
  VSUBPD Z18, Z12, Z18
  VSUBPD Z19, Z13, Z19
  VCVTPD2DQ.RZ_SAE Z18, Y18
  VCVTPD2DQ.RZ_SAE Z19, Y19
  VBROADCASTSD CONST_GET_PTR(const_sin, 96), Z23
  VINSERTI32X8 $1, Y19, Z18, Z18
  VPADDD Z26, Z18, Z18
  VMULPD Z23, Z12, Z22
  VMULPD Z23, Z13, Z23
  VSUBPD Z22, Z20, Z20
  VSUBPD Z23, Z21, Z21
  VADDPD Z24, Z20, Z22
  VADDPD Z25, Z21, Z23
  VSUBPD Z22, Z20, Z20
  VSUBPD Z23, Z21, Z21
  VADDPD Z20, Z24, Z20
  VADDPD Z21, Z25, Z21

  KMOVB K3, K5
  KMOVB K4, K6
  VXORPD X24, X24, X24
  VXORPD X25, X25, X25
  VGATHERDPD 0(R15)(Y10*8), K5, Z24
  VGATHERDPD 0(R15)(Y11*8), K6, Z25
  ADDQ $8, R15

  KMOVB K3, K5
  KMOVB K4, K6
  VXORPD X26, X26, X26
  VXORPD X27, X27, X27
  VGATHERDPD 0(R15)(Y10*8), K5, Z26
  VGATHERDPD 0(R15)(Y11*8), K6, Z27

  VMULPD Z8, Z24, Z10
  VMULPD Z9, Z25, Z11
  VFMSUB213PD Z10, Z8, Z24 // Z24 = (Z8 * Z24) - Z10
  VFMSUB213PD Z11, Z9, Z25 // Z25 = (Z9 * Z25) - Z11
  VFMADD231PD Z26, Z8, Z24 // Z24 = (Z8 * Z26) + Z24
  VFMADD231PD Z27, Z9, Z25 // Z25 = (Z9 * Z27) + Z25
  VADDPD Z20, Z24, Z20
  VADDPD Z21, Z25, Z21
  VADDPD Z22, Z10, Z24
  VADDPD Z23, Z11, Z25
  VSUBPD Z22, Z24, Z26
  VSUBPD Z23, Z25, Z27
  VSUBPD Z26, Z24, Z12
  VSUBPD Z27, Z25, Z13
  VSUBPD Z12, Z22, Z22
  VSUBPD Z13, Z23, Z23
  VSUBPD Z26, Z10, Z10
  VSUBPD Z27, Z11, Z11
  VADDPD Z22, Z10, Z10
  VADDPD Z23, Z11, Z11
  VADDPD Z10, Z20, Z10
  VADDPD Z11, Z21, Z11
  VADDPD Z10, Z24, Z20
  VADDPD Z11, Z25, Z21
  VSUBPD Z20, Z24, Z22
  VSUBPD Z21, Z25, Z23
  VADDPD Z22, Z10, Z10
  VADDPD Z23, Z11, Z11

  VBROADCASTSD CONST_GET_PTR(const_sin, 104), Z23
  VMULPD Z23, Z20, Z24
  VMULPD Z23, Z21, Z25
  VMOVAPD Z23, Z26
  VMOVAPD Z23, Z27
  VFMSUB213PD Z24, Z20, Z26 // Z26 = (Z20 * Z26) - Z24
  VFMSUB213PD Z25, Z21, Z27 // Z27 = (Z21 * Z27) - Z25
  VFMADD231PD Z10, Z23, Z26 // Z26 = (Z23 * Z10) + Z26
  VBROADCASTSD CONST_GET_PTR(const_sin, 112), Z10
  VFMADD231PD Z11, Z23, Z27 // Z27 = (Z23 * Z11) + Z27
  VBROADCASTSD CONSTF64_ABS_BITS(), Z11
  VFMADD231PD Z10, Z20, Z26 // Z26 = (Z20 * Z10) + Z26
  VFMADD231PD Z10, Z21, Z27 // Z27 = (Z21 * Z10) + Z27

  VBROADCASTSD CONST_GET_PTR(const_sin, 120), Z5
  VANDPD Z11, Z8, Z10
  VANDPD Z11, Z9, Z11
  VCMPPD $VCMP_IMM_LT_OS, Z5, Z10, K5
  VCMPPD $VCMP_IMM_LT_OS, Z5, Z11, K6
  VMOVAPD Z8, K5, Z24
  VMOVAPD Z9, K6, Z25
  VPADDD Z18, Z18, Z8
  VPANDD.BCST CONST_GET_PTR(const_sin, 232), Z8, Z8
  VXORPD Z26, Z26, K5, Z26
  VXORPD Z27, Z27, K6, Z27

  VXORPD X12, X12, X12
  VCMPPD $VCMP_IMM_LT_OS, Z24, Z12, K5
  VCMPPD $VCMP_IMM_LT_OS, Z25, Z12, K6
  KUNPCKBW K5, K6, K5
  VPBROADCASTD CONST_GET_PTR(const_sin, 236), Z10
  VPBROADCASTD CONST_GET_PTR(const_sin, 240), Z22
  VPBLENDMD Z10, Z22, K5, Z10
  VPADDD Z10, Z8, Z8
  VPBROADCASTQ CONST_GET_PTR(const_sin, 128), Z10
  VPSRLD $2, Z8, Z20
  VPANDD Z10, Z18, Z8
  VPCMPEQD Z22, Z8, K5
  KSHIFTRW $8, K5, K6
  VBROADCASTSD CONSTF64_SIGN_BIT(), Z9
  VBROADCASTSD CONST_GET_PTR(const_sin, 136), Z11
  VANDPD Z9, Z24, Z8
  VANDPD Z9, Z25, Z9
  VBROADCASTSD CONST_GET_PTR(const_sin, 144), Z5
  VXORPD Z11, Z8, Z10
  VXORPD Z11, Z9, Z11
  VXORPD Z5, Z8, Z8
  VXORPD Z5, Z9, Z9
  VADDPD Z10, Z24, Z18
  VADDPD Z11, Z25, Z19
  VSUBPD Z24, Z18, Z22
  VSUBPD Z25, Z19, Z23
  VSUBPD Z22, Z18, Z12
  VSUBPD Z23, Z19, Z13
  VSUBPD Z12, Z24, Z12
  VSUBPD Z13, Z25, Z13
  VSUBPD Z22, Z10, Z10
  VSUBPD Z23, Z11, Z11
  VADDPD Z12, Z10, Z10
  VADDPD Z13, Z11, Z11
  VADDPD Z8, Z26, Z8
  VADDPD Z9, Z27, Z9
  VMOVAPD Z18, K5, Z24
  VMOVAPD Z19, K6, Z25
  VADDPD Z10, Z8, K5, Z26
  VADDPD Z11, Z9, K6, Z27
  VADDPD Z26, Z24, Z8
  VADDPD Z27, Z25, Z9
  VSUBPD Z8, Z24, Z10
  VSUBPD Z9, Z25, Z11
  VADDPD Z10, Z26, Z10
  VADDPD Z11, Z27, Z11

  VMOVDQA32 Z20, K3, Z4
  VMOVAPD Z8, K3, Z14
  VMOVAPD Z9, K4, Z15
  VMOVAPD Z10, K3, Z16
  VMOVAPD Z11, K4, Z17

  VXORPD X12, X12, X12
  VCMPPD $VCMP_IMM_UNORD_Q, Z12, Z2, K3, K3
  VCMPPD $VCMP_IMM_UNORD_Q, Z12, Z3, K4, K4
  KSHIFTRW $8, K0, K5
  KORW K0, K3, K3
  KORW K5, K4, K4
  VPTERNLOGQ $0xFF, Z14, Z14, K3, Z14
  VPTERNLOGQ $0xFF, Z15, Z15, K4, Z15
  JMP sin_eval_poly

// Cosine: cos(x)
CONST_DATA_U64(const_cos,   0, $0x402e000000000000) // f64(15)
CONST_DATA_U64(const_cos,   8, $0x3fd45f306dc9c883) // f64(0.31830988618379069)
CONST_DATA_U64(const_cos,  16, $0xbfe0000000000000) // f64(-0.5)
CONST_DATA_U64(const_cos,  24, $0x4000000000000000) // f64(2)
CONST_DATA_U64(const_cos,  32, $0xbff921fb54442d18) // f64(-1.5707963267948966)
CONST_DATA_U64(const_cos,  40, $0xbc91a62633145c07) // f64(-6.123233995736766E-17)
CONST_DATA_U64(const_cos,  48, $0x3e645f306dc9c883) // f64(3.7945495388959729E-8)
CONST_DATA_U64(const_cos,  56, $0xbe545f306dc9c883) // f64(-1.8972747694479864E-8)
CONST_DATA_U64(const_cos,  64, $0xc160000000000000) // f64(-8388608)
CONST_DATA_U64(const_cos,  72, $0x4170000000000000) // f64(16777216)
CONST_DATA_U64(const_cos,  80, $0xbff921fb50000000) // f64(-1.5707963109016418)
CONST_DATA_U64(const_cos,  88, $0xbe5110b460000000) // f64(-1.5893254712295857E-8)
CONST_DATA_U64(const_cos,  96, $0xbc91a62630000000) // f64(-6.1232339320535943E-17)
CONST_DATA_U64(const_cos, 104, $0xbae8a2e03707344a) // f64(-6.3683171635109499E-25)
CONST_DATA_U64(const_cos, 112, $0x42d6bcc41e900000) // f64(1.0E+14)
CONST_DATA_U64(const_cos, 120, $0x4010000000000000) // f64(4)
CONST_DATA_U64(const_cos, 128, $0x3fd0000000000000) // f64(0.25)
CONST_DATA_U64(const_cos, 136, $0x401921fb54442d18) // f64(6.2831853071795862)
CONST_DATA_U64(const_cos, 144, $0x3cb1a62633145c07) // f64(2.4492935982947064E-16)
CONST_DATA_U64(const_cos, 152, $0x3fe6666666666666) // f64(0.69999999999999996)
CONST_DATA_U64(const_cos, 160, $0x0000000100000001) // i64(4294967297)
CONST_DATA_U64(const_cos, 168, $0xbff0000000000000) // f64(-1)
CONST_DATA_U64(const_cos, 176, $0x3ce8811a03b2b11d) // f64(2.7205241613852957E-15)
CONST_DATA_U64(const_cos, 184, $0xbd6ae422bc319350) // f64(-7.6429259411395447E-13)
CONST_DATA_U64(const_cos, 192, $0x3de6123c74705f67) // f64(1.605893701172779E-10)
CONST_DATA_U64(const_cos, 200, $0xbe5ae6454baa2959) // f64(-2.5052106814843123E-8)
CONST_DATA_U64(const_cos, 208, $0x3ec71de3a525fbed) // f64(2.7557319210442822E-6)
CONST_DATA_U64(const_cos, 216, $0xbf2a01a01a014225) // f64(-1.9841269841204645E-4)
CONST_DATA_U64(const_cos, 224, $0x3f811111111110b9) // f64(0.0083333333333331805)
CONST_DATA_U64(const_cos, 232, $0xbfc5555555555555) // f64(-0.16666666666666666)
CONST_DATA_U64(const_cos, 240, $0x0000000200000002) // i64(8589934594)
CONST_DATA_U32(const_cos, 248, $0x00000001) // i32(1)
CONST_DATA_U32(const_cos, 252, $0x000003ff) // i32(1023)
CONST_DATA_U32(const_cos, 256, $0xffffffc9) // i32(4294967241)
CONST_DATA_U32(const_cos, 260, $0x00000285) // i32(645)
CONST_DATA_U32(const_cos, 264, $0xffffffc0) // i32(4294967232)
CONST_DATA_U32(const_cos, 268, $0x00000006) // i32(6)
CONST_DATA_U32(const_cos, 272, $0x00000008) // i32(8)
CONST_DATA_U32(const_cos, 276, $0x00000007) // i32(7)
CONST_GLOBAL(const_cos, $280)

TEXT bccosf(SB), NOSPLIT|NOFRAME, $0
  KTESTW K1, K1
  JZ next

  KSHIFTRW $8, K1, K2

  // case 'a': this case is implicit and is always executed
  VBROADCASTSD CONST_GET_PTR(const_cos, 0), Z5
  VBROADCASTSD CONST_GET_PTR(const_cos, 8), Z4

  VPANDQ.BCST CONSTF64_ABS_BITS(), Z2, Z6
  VPANDQ.BCST CONSTF64_ABS_BITS(), Z3, Z7

  VCMPPD $VCMP_IMM_GE_OQ, Z5, Z6, K1, K3
  VCMPPD $VCMP_IMM_GE_OQ, Z5, Z7, K2, K4
  KUNPCKBW K3, K4, K3

  VBROADCASTSD CONST_GET_PTR(const_cos, 24), Z8
  VBROADCASTSD CONST_GET_PTR(const_cos, 16), Z9
  VMOVAPD Z4, Z5
  VFMADD213PD Z9, Z2, Z4 // Z4 = (Z2 * Z4) + Z9
  VFMADD213PD Z9, Z3, Z5 // Z5 = (Z3 * Z5) + Z9
  VRNDSCALEPD $8, Z4, Z4
  VRNDSCALEPD $8, Z5, Z5
  VBROADCASTSD CONSTF64_1(), Z10
  VMOVAPD Z8, Z9
  VFMADD213PD Z10, Z4, Z8 // Z8 = (Z4 * Z8) + Z10
  VFMADD213PD Z10, Z5, Z9 // Z9 = (Z5 * Z9) + Z10
  VCVTPD2DQ.RN_SAE Z8, Y4
  VCVTPD2DQ.RN_SAE Z9, Y5
  VBROADCASTSD CONST_GET_PTR(const_cos, 32), Z11
  VINSERTI32X8 $1, Y5, Z4, Z4

  VMULPD Z11, Z8, Z10
  VMULPD Z11, Z9, Z11
  VADDPD Z2, Z10, Z12
  VADDPD Z3, Z11, Z13
  VSUBPD Z2, Z12, Z14
  VSUBPD Z3, Z13, Z15
  VSUBPD Z14, Z12, Z16
  VSUBPD Z15, Z13, Z17
  VSUBPD Z16, Z2, Z16
  VSUBPD Z17, Z3, Z17
  VSUBPD Z14, Z10, Z10
  VSUBPD Z15, Z11, Z11
  VBROADCASTSD CONST_GET_PTR(const_cos, 40), Z15
  VADDPD Z16, Z10, Z10
  VADDPD Z17, Z11, Z11
  VMULPD Z15, Z8, Z14
  VMULPD Z15, Z9, Z15
  VADDPD Z12, Z14, Z8
  VADDPD Z13, Z15, Z9
  VSUBPD Z8, Z12, Z12
  VSUBPD Z9, Z13, Z13
  VADDPD Z12, Z14, Z12
  VADDPD Z13, Z15, Z13
  VADDPD Z10, Z12, Z10
  VADDPD Z11, Z13, Z11

  // Jump to 'cos_case_b' if one or more lane has x >= 15
  KTESTW K3, K3
  JNE cos_case_b

cos_eval_poly:
  // Polynomial evaluation; code shared by all cases
  VMULPD Z8, Z8, Z2
  VMULPD Z9, Z9, Z3
  VADDPD Z8, Z8, Z6
  VADDPD Z9, Z9, Z7

  VMOVAPD Z8, Z12
  VMOVAPD Z9, Z13
  VFMSUB213PD Z2, Z8, Z12  // Z12 = (Z8 * Z12) - Z2
  VFMSUB213PD Z3, Z9, Z13  // Z13 = (Z9 * Z13) - Z3
  VFMADD231PD Z6, Z10, Z12 // Z12 = (Z10 * Z6) + Z12
  VFMADD231PD Z7, Z11, Z13 // Z13 = (Z11 * Z7) + Z13

  VMULPD Z2, Z2, Z6
  VMULPD Z3, Z3, Z7
  VMULPD Z6, Z6, Z14
  VMULPD Z7, Z7, Z15

  VBROADCASTSD CONST_GET_PTR(const_cos, 176), Z16
  VBROADCASTSD CONST_GET_PTR(const_cos, 192), Z18
  VBROADCASTSD CONST_GET_PTR(const_cos, 208), Z20
  VMOVAPD Z16, Z17
  VMOVAPD Z18, Z19
  VBROADCASTSD CONST_GET_PTR(const_cos, 184), Z22
  VBROADCASTSD CONST_GET_PTR(const_cos, 200), Z23

  VFMADD213PD Z22, Z2, Z16 // Z16 = (Z2 * Z16) + Z22
  VFMADD213PD Z22, Z3, Z17 // Z17 = (Z3 * Z17) + Z22
  VBROADCASTSD CONST_GET_PTR(const_cos, 216), Z22
  VFMADD213PD Z23, Z2, Z18 // Z18 = (Z2 * Z18) + Z23
  VFMADD213PD Z23, Z3, Z19 // Z19 = (Z3 * Z19) + Z23
  VBROADCASTSD CONST_GET_PTR(const_cos, 224), Z23
  VMOVAPD Z20, Z21
  VFMADD213PD Z22, Z2, Z20 // Z20 = (Z2 * Z20) + Z22
  VFMADD213PD Z22, Z3, Z21 // Z21 = (Z3 * Z21) + Z22
  VFMADD231PD Z18, Z6, Z20  // Z20 = (Z6 * Z18) + Z20
  VFMADD231PD Z19, Z7, Z21  // Z21 = (Z7 * Z19) + Z21
  VFMADD231PD Z16, Z14, Z20 // Z20 = (Z14 * Z16) + Z20
  VFMADD231PD Z17, Z15, Z21 // Z21 = (Z15 * Z17) + Z21
  VFMADD213PD Z23, Z2, Z20 // Z20 = (Z2 * Z20) + Z23
  VFMADD213PD Z23, Z3, Z21 // Z21 = (Z3 * Z21) + Z23

  VBROADCASTSD CONST_GET_PTR(const_cos, 232), Z15
  VMULPD Z20, Z2, Z6
  VMULPD Z21, Z3, Z7
  VADDPD Z15, Z6, Z16
  VADDPD Z15, Z7, Z17
  VSUBPD Z16, Z15, Z14
  VSUBPD Z17, Z15, Z15
  VADDPD Z14, Z6, Z6
  VADDPD Z15, Z7, Z7
  VMULPD Z16, Z2, Z14
  VMULPD Z17, Z3, Z15
  VMOVAPD Z2, Z18
  VMOVAPD Z3, Z19
  VFMSUB213PD Z14, Z16, Z18 // Z18 = (Z16 * Z18) - Z14
  VFMSUB213PD Z15, Z17, Z19 // Z19 = (Z17 * Z19) - Z15
  VFMADD231PD Z6, Z2, Z18   // Z18 = (Z2 * Z6) + Z18
  VFMADD231PD Z7, Z3, Z19   // Z19 = (Z3 * Z7) + Z19
  VFMADD231PD Z12, Z16, Z18 // Z18 = (Z16 * Z12) + Z18
  VFMADD231PD Z13, Z17, Z19 // Z19 = (Z17 * Z13) + Z19

  VBROADCASTSD CONSTF64_1(), Z13
  VADDPD Z13, Z14, Z6
  VADDPD Z13, Z15, Z7
  VSUBPD Z6, Z13, K1, Z2
  VSUBPD Z7, Z13, K2, Z3
  VADDPD Z2, Z14, K1, Z2
  VADDPD Z3, Z15, K2, Z3
  VADDPD Z18, Z2, K1, Z2
  VADDPD Z19, Z3, K2, Z3
  VMULPD Z2, Z8, K1, Z2
  VMULPD Z3, Z9, K2, Z3
  VFMADD231PD Z10, Z6, K1, Z2 // Z2 = (Z6 * Z10) + Z2
  VFMADD231PD Z11, Z7, K2, Z3 // Z3 = (Z7 * Z11) + Z3
  VFMADD231PD Z6, Z8, K1, Z2  // Z2 = (Z8 * Z6) + Z2
  VFMADD231PD Z7, Z9, K2, Z3  // Z3 = (Z9 * Z7) + Z3

  VBROADCASTSD CONSTF64_SIGN_BIT(), Z6
  VPANDD.BCST CONST_GET_PTR(const_cos, 240), Z4, Z4
  VPTESTNMD Z4, Z4, K3
  KSHIFTRW $8, K3, K4
  VMOVAPD.Z Z6, K3, Z4
  VMOVAPD.Z Z6, K4, Z5
  VXORPD Z4, Z2, K1, Z2
  VXORPD Z5, Z3, K2, Z3

next:
  NEXT()

cos_case_b:
  // case 'b': one or more lane has x >= 1e14
  VBROADCASTSD CONST_GET_PTR(const_cos, 48), Z12
  VBROADCASTSD CONST_GET_PTR(const_cos, 64), Z16
  VBROADCASTSD CONST_GET_PTR(const_cos, 56), Z20
  VMOVAPD Z12, Z13
  VMOVAPD Z16, Z17
  VFMADD213PD Z20, Z2, Z12 // Z12 = (Z2 * Z12) + Z20
  VFMADD213PD Z20, Z3, Z13 // Z13 = (Z3 * Z13) + Z20
  VRNDSCALEPD $11, Z12, Z12
  VRNDSCALEPD $11, Z13, Z13
  VBROADCASTSD CONST_GET_PTR(const_cos, 8), Z20
  VBROADCASTSD CONST_GET_PTR(const_cos, 16), Z21
  VMULPD Z20, Z2, Z14
  VMULPD Z20, Z3, Z15
  VFMADD213PD Z21, Z12, Z16 // Z16 = (Z12 * Z16) + Z21
  VFMADD213PD Z21, Z13, Z17 // Z17 = (Z13 * Z17) + Z21
  VADDPD Z16, Z14, Z14
  VADDPD Z17, Z15, Z15
  VCVTPD2DQ.RN_SAE Z14, Y14
  VCVTPD2DQ.RN_SAE Z15, Y15
  VINSERTI32X8 $1, Y15, Z14, Z14
  VBROADCASTSD CONST_GET_PTR(const_cos, 72), Z15
  VPADDD Z14, Z14, Z14
  VMULPD Z15, Z12, Z12
  VMULPD Z15, Z13, Z13
  VPORD.BCST CONST_GET_PTR(const_cos, 248), Z14, Z16
  VMOVDQA32 Z16, K3, Z4
  VEXTRACTI32X8 $1, Z16, Y17
  VCVTDQ2PD Y16, Z14
  VCVTDQ2PD Y17, Z15
  VBROADCASTSD CONST_GET_PTR(const_cos, 80), Z18
  VMULPD Z18, Z14, Z20
  VMULPD Z18, Z15, Z21
  VMOVAPD Z18, Z19
  VFMADD213PD Z2, Z12, Z18 // Z18 = (Z12 * Z18) + Z2
  VFMADD213PD Z3, Z13, Z19 // Z19 = (Z13 * Z19) + Z3
  VBROADCASTSD CONST_GET_PTR(const_cos, 88), Z16
  VADDPD Z20, Z18, Z22
  VADDPD Z21, Z19, Z23
  VSUBPD Z18, Z22, Z24
  VSUBPD Z19, Z23, Z25
  VSUBPD Z24, Z22, Z26
  VSUBPD Z25, Z23, Z27
  VSUBPD Z26, Z18, Z18
  VSUBPD Z27, Z19, Z19
  VSUBPD Z24, Z20, Z20
  VSUBPD Z25, Z21, Z21
  VADDPD Z18, Z20, Z18
  VADDPD Z19, Z21, Z19
  VMULPD Z16, Z12, Z20
  VMULPD Z16, Z13, Z21
  VADDPD Z22, Z20, Z26
  VADDPD Z23, Z21, Z27
  VSUBPD Z22, Z26, Z24
  VSUBPD Z23, Z27, Z25
  VSUBPD Z24, Z26, Z5
  VSUBPD Z5, Z22, Z22
  VSUBPD Z25, Z27, Z5
  VSUBPD Z5, Z23, Z23
  VSUBPD Z24, Z20, Z20
  VSUBPD Z25, Z21, Z21
  VADDPD Z22, Z20, Z20
  VADDPD Z23, Z21, Z21
  VADDPD Z20, Z18, Z18
  VADDPD Z21, Z19, Z19
  VMULPD Z16, Z14, Z20
  VMULPD Z16, Z15, Z21
  VBROADCASTSD CONST_GET_PTR(const_cos, 96), Z16
  VADDPD Z26, Z20, Z22
  VADDPD Z27, Z21, Z23
  VSUBPD Z26, Z22, Z24
  VSUBPD Z27, Z23, Z25
  VSUBPD Z24, Z22, Z5
  VSUBPD Z5, Z26, Z26
  VSUBPD Z25, Z23, Z5
  VSUBPD Z5, Z27, Z27
  VSUBPD Z24, Z20, Z20
  VSUBPD Z25, Z21, Z21
  VADDPD Z26, Z20, Z20
  VADDPD Z27, Z21, Z21
  VADDPD Z18, Z20, Z18
  VADDPD Z19, Z21, Z19
  VMULPD Z16, Z12, Z24
  VMULPD Z16, Z13, Z25
  VADDPD Z22, Z24, Z26
  VADDPD Z23, Z25, Z27
  VSUBPD Z22, Z26, Z20
  VSUBPD Z23, Z27, Z21
  VSUBPD Z20, Z26, Z5
  VSUBPD Z5, Z22, Z22
  VSUBPD Z21, Z27, Z5
  VSUBPD Z5, Z23, Z23
  VSUBPD Z20, Z24, Z24
  VSUBPD Z21, Z25, Z25
  VADDPD Z22, Z24, Z22
  VADDPD Z23, Z25, Z23
  VADDPD Z18, Z22, Z18
  VADDPD Z19, Z23, Z19
  VMULPD Z16, Z14, Z20
  VMULPD Z16, Z15, Z21
  VBROADCASTSD CONST_GET_PTR(const_cos, 104), Z16
  VADDPD Z26, Z20, Z22
  VADDPD Z27, Z21, Z23
  VSUBPD Z26, Z22, Z24
  VSUBPD Z27, Z23, Z25
  VSUBPD Z24, Z22, Z5
  VSUBPD Z5, Z26, Z26
  VSUBPD Z25, Z23, Z5
  VSUBPD Z5, Z27, Z27
  VSUBPD Z24, Z20, Z20
  VSUBPD Z25, Z21, Z21
  VADDPD Z26, Z20, Z20
  VADDPD Z27, Z21, Z21
  VADDPD Z18, Z20, Z18
  VADDPD Z19, Z21, Z19
  VADDPD Z14, Z12, Z12
  VADDPD Z15, Z13, Z13
  VMULPD Z16, Z12, Z12
  VMULPD Z16, Z13, Z13
  VADDPD Z22, Z12, Z14
  VADDPD Z23, Z13, Z15
  VSUBPD Z14, Z22, Z20
  VSUBPD Z15, Z23, Z21
  VADDPD Z20, Z12, Z12
  VADDPD Z21, Z13, Z13
  VADDPD Z18, Z12, Z12
  VADDPD Z19, Z13, Z13

  VBROADCASTSD CONST_GET_PTR(const_cos, 112), Z16
  VMOVAPD Z14, K3, Z8
  VMOVAPD Z15, K4, Z9
  VMOVAPD Z12, K3, Z10
  VMOVAPD Z13, K4, Z11

  VCMPPD $VCMP_IMM_GE_OS, Z16, Z6, K3, K3
  VCMPPD $VCMP_IMM_GE_OS, Z16, Z7, K4, K4
  KUNPCKBW K3, K4, K3
  KTESTW K3, K3
  JZ cos_eval_poly

  // case 'c': one or more lane has x >= 1e14
  VBROADCASTSD CONSTF64_POSITIVE_INF(), Z14
  MOVL $0xAAAA, R8
  LEAQ CONST_GET_PTR(const_rempi, 0), R15

  // K0 contains mask of all inputs that are either +INF or -INF
  VCMPPD $VCMP_IMM_EQ_OQ, Z14, Z6, K3, K0
  VCMPPD $VCMP_IMM_EQ_OQ, Z14, Z7, K4, K5
  KUNPCKBW K0, K5, K0

  VGETEXPPD Z2, Z14
  VGETEXPPD Z3, Z15
  VCVTPD2DQ.RN_SAE Z14, Y14
  VCVTPD2DQ.RN_SAE Z15, Y15
  VINSERTI32X8 $1, Y15, Z14, Z14
  VPCMPGTD.BCST CONSTD_NEG_1(), Z14, K5
  VPANDD.BCST.Z CONST_GET_PTR(const_cos, 252), Z14, K5, Z14
  VPADDD.BCST CONST_GET_PTR(const_cos, 256), Z14, Z12
  VPCMPGTD.BCST CONST_GET_PTR(const_cos, 260), Z12, K5
  VPBROADCASTD.Z CONST_GET_PTR(const_cos, 264), K5, Z14
  VPSLLD $20, Z14, Z14
  VEXTRACTI32X8 $1, Z14, Y15
  KMOVW R8, K5
  VPEXPANDD.Z Z14, K5, Z14
  VPEXPANDD.Z Z15, K5, Z15
  VPADDQ Z2, Z14, Z14
  VPADDQ Z3, Z15, Z15
  VPSRAD $31, Z12, Z18
  VPANDND Z12, Z18, Z12
  VPSLLD $2, Z12, Z18
  VEXTRACTI32X8 $1, Z18, Y19

  KMOVB K3, K5
  KMOVB K4, K6
  VXORPD X12, X12, X12
  VXORPD X13, X13, X13
  VGATHERDPD 0(R15)(Y18*8), K5, Z12
  VGATHERDPD 0(R15)(Y19*8), K6, Z13
  ADDQ $8, R15

  VBROADCASTSD CONST_GET_PTR(const_cos, 120), Z5
  VMULPD Z14, Z12, Z20
  VMULPD Z15, Z13, Z21
  VFMSUB213PD Z20, Z14, Z12 // Z12 = (Z14 * Z12) - Z20
  VFMSUB213PD Z21, Z15, Z13 // Z13 = (Z15 * Z13) - Z21
  VMULPD Z5, Z20, Z24
  VMULPD Z5, Z21, Z25
  VRNDSCALEPD $8, Z24, Z24
  VRNDSCALEPD $8, Z25, Z25
  VRNDSCALEPD $8, Z20, Z26
  VRNDSCALEPD $8, Z21, Z27
  VMULPD Z5, Z26, Z26
  VMULPD Z5, Z27, Z27
  VBROADCASTSD CONST_GET_PTR(const_cos, 128), Z5
  VSUBPD Z26, Z24, Z26
  VSUBPD Z27, Z25, Z27
  VCVTPD2DQ.RZ_SAE Z26, Y26
  VCVTPD2DQ.RZ_SAE Z27, Y27
  VINSERTI32X8 $1, Y27, Z26, Z26
  VMULPD Z5, Z24, Z24
  VMULPD Z5, Z25, Z25
  VSUBPD Z24, Z20, Z20
  VSUBPD Z25, Z21, Z21
  VADDPD Z12, Z20, Z24
  VADDPD Z13, Z21, Z25
  VSUBPD Z24, Z20, Z20
  VSUBPD Z25, Z21, Z21
  VADDPD Z20, Z12, Z12
  VADDPD Z21, Z13, Z13

  KMOVB K3, K5
  KMOVB K4, K6
  VXORPD X20, X20, X20
  VXORPD X21, X21, X21
  VGATHERDPD 0(R15)(Y18*8), K5, Z20
  VGATHERDPD 0(R15)(Y19*8), K6, Z21
  ADDQ $8, R15

  VMULPD Z14, Z20, Z22
  VMULPD Z15, Z21, Z23
  VFMSUB213PD Z22, Z14, Z20 // Z20 = (Z14 * Z20) - Z22
  VFMSUB213PD Z23, Z15, Z21 // Z21 = (Z15 * Z21) - Z23
  VADDPD Z12, Z20, Z12
  VADDPD Z13, Z21, Z13
  VADDPD Z24, Z22, Z20
  VADDPD Z25, Z23, Z21
  VSUBPD Z24, Z20, Z16
  VSUBPD Z25, Z21, Z17
  VSUBPD Z16, Z20, Z5
  VSUBPD Z5, Z24, Z24
  VSUBPD Z17, Z21, Z5
  VSUBPD Z5, Z25, Z25
  VBROADCASTSD CONST_GET_PTR(const_cos, 120), Z5
  VSUBPD Z16, Z22, Z22
  VSUBPD Z17, Z23, Z23
  VADDPD Z24, Z22, Z24
  VADDPD Z25, Z23, Z25
  VADDPD Z24, Z12, Z24
  VADDPD Z25, Z13, Z25
  VMULPD Z5, Z20, Z12
  VMULPD Z5, Z21, Z13
  VRNDSCALEPD $8, Z12, Z22
  VRNDSCALEPD $8, Z13, Z23
  VRNDSCALEPD $8, Z20, Z12
  VRNDSCALEPD $8, Z21, Z13
  VMULPD Z5, Z12, Z12
  VMULPD Z5, Z13, Z13
  VBROADCASTSD CONST_GET_PTR(const_cos, 128), Z5
  VSUBPD Z12, Z22, Z12
  VSUBPD Z13, Z23, Z13
  VCVTPD2DQ.RZ_SAE Z12, Y12
  VCVTPD2DQ.RZ_SAE Z13, Y13
  VINSERTI32X8 $1, Y13, Z12, Z12
  VPADDD Z12, Z26, Z12
  VMULPD Z5, Z22, Z22
  VMULPD Z5, Z23, Z23
  VSUBPD Z22, Z20, Z20
  VSUBPD Z23, Z21, Z21
  VADDPD Z24, Z20, Z22
  VADDPD Z25, Z21, Z23
  VSUBPD Z22, Z20, Z20
  VSUBPD Z23, Z21, Z21
  VADDPD Z20, Z24, Z20
  VADDPD Z21, Z25, Z21

  KMOVB K3, K5
  KMOVB K4, K6
  VXORPD X24, X24, X24
  VXORPD X25, X25, X25
  VGATHERDPD 0(R15)(Y18*8), K5, Z24
  VGATHERDPD 0(R15)(Y19*8), K6, Z25
  ADDQ $8, R15

  KMOVB K3, K5
  KMOVB K4, K6
  VXORPD X26, X26, X26
  VXORPD X27, X27, X27
  VGATHERDPD 0(R15)(Y18*8), K5, Z26
  VGATHERDPD 0(R15)(Y19*8), K6, Z27

  VMULPD Z14, Z24, Z18
  VMULPD Z15, Z25, Z19
  VFMSUB213PD Z18, Z14, Z24 // Z24 = (Z14 * Z24) - Z18
  VFMSUB213PD Z19, Z15, Z25 // Z25 = (Z15 * Z25) - Z19
  VFMADD231PD Z26, Z14, Z24 // Z24 = (Z14 * Z26) + Z24
  VFMADD231PD Z27, Z15, Z25 // Z25 = (Z15 * Z27) + Z25
  VADDPD Z20, Z24, Z20
  VADDPD Z21, Z25, Z21
  VADDPD Z22, Z18, Z24
  VADDPD Z23, Z19, Z25
  VSUBPD Z22, Z24, Z26
  VSUBPD Z23, Z25, Z27
  VSUBPD Z26, Z24, Z16
  VSUBPD Z27, Z25, Z17
  VSUBPD Z16, Z22, Z22
  VSUBPD Z17, Z23, Z23
  VSUBPD Z26, Z18, Z18
  VSUBPD Z27, Z19, Z19
  VADDPD Z22, Z18, Z18
  VADDPD Z23, Z19, Z19
  VADDPD Z18, Z20, Z18
  VADDPD Z19, Z21, Z19
  VADDPD Z18, Z24, Z20
  VADDPD Z19, Z25, Z21
  VSUBPD Z20, Z24, Z22
  VSUBPD Z21, Z25, Z23
  VADDPD Z22, Z18, Z18
  VADDPD Z23, Z19, Z19

  VBROADCASTSD CONST_GET_PTR(const_cos, 144), Z5
  VBROADCASTSD CONST_GET_PTR(const_cos, 136), Z25
  VMULPD Z25, Z20, Z22
  VMULPD Z25, Z21, Z23
  VMOVAPD Z25, Z26
  VMOVAPD Z25, Z27
  VFMSUB213PD Z22, Z20, Z26 // Z26 = (Z20 * Z26) - Z22
  VFMSUB213PD Z23, Z21, Z27 // Z27 = (Z21 * Z27) - Z23
  VFMADD231PD Z18, Z25, Z26 // Z26 = (Z25 * Z18) + Z26
  VFMADD231PD Z19, Z25, Z27 // Z27 = (Z25 * Z19) + Z27
  VFMADD231PD Z5, Z20, Z26 // Z26 = (Z20 * Z5) + Z26
  VFMADD231PD Z5, Z21, Z27 // Z27 = (Z21 * Z5) + Z27

  VBROADCASTSD CONST_GET_PTR(const_cos, 152), Z5
  VPANDQ.BCST CONSTF64_ABS_BITS(), Z14, Z18
  VPANDQ.BCST CONSTF64_ABS_BITS(), Z15, Z19
  VCMPPD $VCMP_IMM_LT_OS, Z5, Z18, K5
  VCMPPD $VCMP_IMM_LT_OS, Z5, Z19, K6
  VMOVAPD Z14, K5, Z22
  VMOVAPD Z15, K6, Z23
  VXORPD Z26, Z26, K5, Z26
  VXORPD Z27, Z27, K6, Z27
  VPADDD Z12, Z12, Z14
  VPANDD.BCST CONST_GET_PTR(const_cos, 268), Z14, Z14
  VPBROADCASTD CONST_GET_PTR(const_cos, 276), Z20
  VPXORD X16, X16, X16
  VCMPPD $VCMP_IMM_LT_OS, Z22, Z16, K5
  VCMPPD $VCMP_IMM_LT_OS, Z23, Z16, K6
  KUNPCKBW K5, K6, K5
  VPBROADCASTD CONST_GET_PTR(const_cos, 272), K5, Z20
  VPADDD Z14, Z20, Z14
  VPSRLD $1, Z14, Z18
  VBROADCASTSD CONST_GET_PTR(const_cos, 168), Z14
  VPANDD.BCST CONST_GET_PTR(const_cos, 160), Z12, Z12
  VMOVAPD Z14, Z15
  VXORPD Z14, Z14, K5, Z14
  VXORPD Z15, Z15, K6, Z15
  VPTESTNMD Z12, Z12, K5
  KSHIFTRW $8, K5, K6

  VBROADCASTSD CONSTF64_SIGN_BIT(), Z5
  VBROADCASTSD CONST_GET_PTR(const_cos, 32), Z13
  VANDPD Z5, Z14, Z14
  VANDPD Z5, Z15, Z15
  VBROADCASTSD CONST_GET_PTR(const_cos, 40), Z5
  VXORPD Z13, Z14, Z12
  VXORPD Z13, Z15, Z13
  VXORPD Z5, Z14, Z14
  VXORPD Z5, Z15, Z15
  VADDPD Z12, Z22, Z20
  VADDPD Z13, Z23, Z21
  VSUBPD Z22, Z20, Z24
  VSUBPD Z23, Z21, Z25
  VSUBPD Z24, Z20, Z5
  VSUBPD Z25, Z21, Z17
  VSUBPD Z5, Z22, Z5
  VSUBPD Z17, Z23, Z17
  VSUBPD Z24, Z12, Z12
  VSUBPD Z25, Z13, Z13
  VADDPD Z5, Z12, Z12
  VADDPD Z17, Z13, Z13
  VADDPD Z14, Z26, Z14
  VADDPD Z15, Z27, Z15
  VMOVAPD Z20, K5, Z22
  VMOVAPD Z21, K6, Z23
  VADDPD Z12, Z14, K5, Z26
  VADDPD Z13, Z15, K6, Z27
  VADDPD Z26, Z22, Z14
  VADDPD Z27, Z23, Z15
  VSUBPD Z14, Z22, Z12
  VSUBPD Z15, Z23, Z13
  VADDPD Z12, Z26, Z12
  VADDPD Z13, Z27, Z13

  VMOVDQA32 Z18, K3, Z4
  VMOVAPD Z14, K3, Z8
  VMOVAPD Z15, K4, Z9
  VMOVAPD Z12, K3, Z10
  VMOVAPD Z13, K4, Z11

  VCMPPD $VCMP_IMM_UNORD_Q, Z16, Z2, K3, K3
  VCMPPD $VCMP_IMM_UNORD_Q, Z16, Z3, K4, K4
  KSHIFTRW $8, K0, K5
  KORW K0, K3, K3
  KORW K5, K4, K4
  VPTERNLOGQ $0xFF, Z8, Z8, K3, Z8
  VPTERNLOGQ $0xFF, Z9, Z9, K4, Z9
  JMP cos_eval_poly

// Tangent: tan(x) == sin(x) / cos(x)
CONST_DATA_U64(const_tan,   0, $0x3fe45f306dc9c883) // f64(0.63661977236758138)
CONST_DATA_U64(const_tan,   8, $0xbff921fb54442d18) // f64(-1.5707963267948966)
CONST_DATA_U64(const_tan,  16, $0xbc91a62633145c07) // f64(-6.123233995736766E-17)
CONST_DATA_U64(const_tan,  24, $0x402e000000000000) // f64(15)
CONST_DATA_U64(const_tan,  32, $0x3e645f306dc9c883) // f64(3.7945495388959729E-8)
CONST_DATA_U64(const_tan,  40, $0x4170000000000000) // f64(16777216)
CONST_DATA_U64(const_tan,  48, $0xbc86b01ec5417056) // f64(-3.9357353350364972E-17)
CONST_DATA_U64(const_tan,  56, $0xbfe0000000000000) // f64(-0.5)
CONST_DATA_U64(const_tan,  64, $0xbff921fb50000000) // f64(-1.5707963109016418)
CONST_DATA_U64(const_tan,  72, $0xbe5110b460000000) // f64(-1.5893254712295857E-8)
CONST_DATA_U64(const_tan,  80, $0xbc91a62630000000) // f64(-6.1232339320535943E-17)
CONST_DATA_U64(const_tan,  88, $0xbae8a2e03707344a) // f64(-6.3683171635109499E-25)
CONST_DATA_U64(const_tan,  96, $0x42d6bcc41e900000) // f64(1.0E+14)
CONST_DATA_U64(const_tan, 104, $0x4010000000000000) // f64(4)
CONST_DATA_U64(const_tan, 112, $0x3fd0000000000000) // f64(0.25)
CONST_DATA_U64(const_tan, 120, $0x401921fb54442d18) // f64(6.2831853071795862)
CONST_DATA_U64(const_tan, 128, $0x3cb1a62633145c07) // f64(2.4492935982947064E-16)
CONST_DATA_U64(const_tan, 136, $0x3fe6666666666666) // f64(0.69999999999999996)
CONST_DATA_U64(const_tan, 144, $0x3f35445f555134ed) // f64(3.2450988266392763E-4)
CONST_DATA_U64(const_tan, 152, $0x3f4269be400de3af) // f64(5.6192197381143237E-4)
CONST_DATA_U64(const_tan, 160, $0x3f57eef631e20b93) // f64(0.0014607815024027845)
CONST_DATA_U64(const_tan, 168, $0x3f6d6c27c371c959) // f64(0.0035916115407924995)
CONST_DATA_U64(const_tan, 176, $0x3f8226e7bfa35090) // f64(0.0088632684095631131)
CONST_DATA_U64(const_tan, 184, $0x3f9664f4729f98e5) // f64(0.021869487281855355)
CONST_DATA_U64(const_tan, 192, $0x3faba1ba1bdcec06) // f64(0.05396825399517273)
CONST_DATA_U64(const_tan, 200, $0x3fc111111110e933) // f64(0.13333333333305006)
CONST_DATA_U64(const_tan, 208, $0x3fd5555555555568) // f64(0.33333333333333437)
CONST_DATA_U64(const_tan, 216, $0xbff0000000000000) // f64(-1)
CONST_DATA_U64(const_tan, 224, $0xc000000000000000) // f64(-2)
CONST_DATA_U64(const_tan, 232, $0x0000000100000001) // i64(4294967297)
CONST_DATA_U32(const_tan, 240, $0x000003ff) // i32(1023)
CONST_DATA_U32(const_tan, 244, $0xffffffc9) // i32(4294967241)
CONST_DATA_U32(const_tan, 248, $0x00000285) // i32(645)
CONST_DATA_U32(const_tan, 252, $0xffffffc0) // i32(4294967232)
CONST_DATA_U32(const_tan, 256, $0x00000001) // i32(1)
CONST_GLOBAL(const_tan, $260)

TEXT bctanf(SB), NOSPLIT|NOFRAME, $0
  KTESTW K1, K1
  JZ next

  KSHIFTRW $8, K1, K2

  // case 'a': this case is implicit and is always executed
  VBROADCASTSD CONST_GET_PTR(const_tan, 0), Z11
  VBROADCASTSD CONST_GET_PTR(const_tan, 8), Z8
  VMULPD Z11, Z2, Z10
  VMULPD Z11, Z3, Z11
  VRNDSCALEPD $8, Z10, Z6
  VRNDSCALEPD $8, Z11, Z7
  VCVTPD2DQ.RN_SAE Z6, Y4
  VCVTPD2DQ.RN_SAE Z7, Y5
  VINSERTI32X8 $1, Y5, Z4, Z4
  VMOVAPD Z8, Z9
  VBROADCASTSD CONST_GET_PTR(const_tan, 16), Z13
  VFMADD213PD Z2, Z6, Z8 // Z8 = (Z6 * Z8) + Z2
  VFMADD213PD Z3, Z7, Z9 // Z9 = (Z7 * Z9) + Z3
  VMULPD Z13, Z6, Z12
  VMULPD Z13, Z7, Z13
  VADDPD Z12, Z8, Z14
  VADDPD Z13, Z9, Z15
  VBROADCASTSD CONSTF64_ABS_BITS(), Z7
  VBROADCASTSD CONST_GET_PTR(const_tan, 24), Z20
  VSUBPD Z14, Z8, Z8
  VSUBPD Z15, Z9, Z9
  VANDPD Z7, Z2, Z6
  VANDPD Z7, Z3, Z7
  VADDPD Z8, Z12, Z16
  VADDPD Z9, Z13, Z17
  VCMPPD $VCMP_IMM_GE_OQ, Z20, Z6, K1, K3
  VCMPPD $VCMP_IMM_GE_OQ, Z20, Z7, K2, K4
  KUNPCKBW K3, K4, K3

  KTESTW K3, K3
  JNE tan_case_b

tan_eval_poly:
  // Polynomial evaluation; code shared by all cases
  VPANDD.BCST CONST_GET_PTR(const_tan, 232), Z4, Z4
  VPCMPEQD.BCST CONST_GET_PTR(const_tan, 256), Z4, K5
  KSHIFTRW $8, K5, K6

  VBROADCASTSD CONSTF64_HALF(), Z7
  VMULPD Z7, Z14, Z8
  VMULPD Z7, Z15, Z9
  VMULPD Z7, Z16, Z6
  VMULPD Z7, Z17, Z7
  VMULPD Z8, Z8, Z10
  VMULPD Z9, Z9, Z11
  VADDPD Z8, Z8, Z12
  VADDPD Z9, Z9, Z13
  VMOVAPD Z8, Z14
  VMOVAPD Z9, Z15
  VFMSUB213PD Z10, Z8, Z14 // Z14 = (Z8 * Z14) - Z10
  VFMSUB213PD Z11, Z9, Z15 // Z15 = (Z9 * Z15) - Z11
  VFMADD231PD Z12, Z6, Z14 // Z14 = (Z6 * Z12) + Z14
  VFMADD231PD Z13, Z7, Z15 // Z15 = (Z7 * Z13) + Z15
  VMULPD Z10, Z10, Z12
  VMULPD Z11, Z11, Z13
  VBROADCASTSD CONST_GET_PTR(const_tan, 144), Z16
  VBROADCASTSD CONST_GET_PTR(const_tan, 160), Z18
  VBROADCASTSD CONST_GET_PTR(const_tan, 152), Z20
  VBROADCASTSD CONST_GET_PTR(const_tan, 168), Z21
  VMOVAPD Z16, Z17
  VFMADD213PD Z20, Z10, Z16 // Z16 = (Z10 * Z16) + Z20
  VFMADD213PD Z20, Z11, Z17 // Z17 = (Z11 * Z17) + Z20
  VMOVAPD Z18, Z19
  VFMADD213PD Z21, Z10, Z18 // Z18 = (Z10 * Z18) + Z21
  VFMADD213PD Z21, Z11, Z19 // Z19 = (Z11 * Z19) + Z21
  VMULPD Z12, Z12, Z20
  VMULPD Z13, Z13, Z21
  VFMADD231PD Z16, Z12, Z18 // Z18 = (Z12 * Z16) + Z18
  VFMADD231PD Z17, Z13, Z19 // Z19 = (Z13 * Z17) + Z19
  VBROADCASTSD CONST_GET_PTR(const_tan, 176), Z16
  VBROADCASTSD CONST_GET_PTR(const_tan, 192), Z22
  VBROADCASTSD CONST_GET_PTR(const_tan, 184), Z4
  VBROADCASTSD CONST_GET_PTR(const_tan, 200), Z5
  VMOVAPD Z16, Z17
  VMOVAPD Z22, Z23
  VFMADD213PD Z4, Z10, Z16  // Z16 = (Z10 * Z16) + Z4
  VFMADD213PD Z4, Z11, Z17  // Z17 = (Z11 * Z17) + Z4
  VFMADD213PD Z5, Z10, Z22  // Z22 = (Z10 * Z22) + Z5
  VFMADD213PD Z5, Z11, Z23  // Z23 = (Z11 * Z23) + Z5
  VBROADCASTSD CONST_GET_PTR(const_tan, 208), Z4
  VFMADD231PD Z16, Z12, Z22 // Z22 = (Z12 * Z16) + Z22
  VFMADD231PD Z17, Z13, Z23 // Z23 = (Z13 * Z17) + Z23
  VFMADD231PD Z18, Z20, Z22 // Z22 = (Z20 * Z18) + Z22
  VFMADD231PD Z19, Z21, Z23 // Z23 = (Z21 * Z19) + Z23
  VFMADD213PD Z4, Z10, Z22  // Z22 = (Z10 * Z22) + Z4
  VFMADD213PD Z4, Z11, Z23  // Z23 = (Z11 * Z23) + Z4
  VMULPD Z10, Z8, Z12
  VMULPD Z11, Z9, Z13
  VMOVAPD Z8, Z16
  VMOVAPD Z9, Z17
  VFMSUB213PD Z12, Z10, Z16 // Z16 = (Z10 * Z16) - Z12
  VFMSUB213PD Z13, Z11, Z17 // Z17 = (Z11 * Z17) - Z13
  VFMADD231PD Z14, Z8, Z16  // Z16 = (Z8 * Z14) + Z16
  VFMADD231PD Z15, Z9, Z17  // Z17 = (Z9 * Z15) + Z17
  VFMADD231PD Z10, Z6, Z16  // Z16 = (Z6 * Z10) + Z16
  VFMADD231PD Z11, Z7, Z17  // Z17 = (Z7 * Z11) + Z17
  VMULPD Z22, Z12, Z10
  VMULPD Z23, Z13, Z11
  VFMSUB213PD Z10, Z22, Z12 // Z12 = (Z22 * Z12) - Z10
  VFMSUB213PD Z11, Z23, Z13 // Z13 = (Z23 * Z13) - Z11
  VFMADD231PD Z16, Z22, Z12 // Z12 = (Z22 * Z16) + Z12
  VFMADD231PD Z17, Z23, Z13 // Z13 = (Z23 * Z17) + Z13
  VADDPD Z10, Z8, Z14
  VADDPD Z11, Z9, Z15
  VSUBPD Z14, Z8, Z8
  VSUBPD Z15, Z9, Z9
  VADDPD Z8, Z10, Z8
  VADDPD Z9, Z11, Z9
  VADDPD Z8, Z6, Z6
  VADDPD Z9, Z7, Z7
  VADDPD Z6, Z12, Z6
  VADDPD Z7, Z13, Z7
  VMULPD Z14, Z14, Z8
  VMULPD Z15, Z15, Z9
  VADDPD Z14, Z14, Z10
  VADDPD Z15, Z15, Z11
  VBROADCASTSD CONST_GET_PTR(const_tan, 224), Z13
  VMULPD Z13, Z14, Z16
  VMULPD Z13, Z15, Z17
  VFMSUB213PD Z8, Z14, Z14 // Z14 = (Z14 * Z14) - Z8
  VFMSUB213PD Z9, Z15, Z15 // Z15 = (Z15 * Z15) - Z9
  VFMADD231PD Z10, Z6, Z14 // Z14 = (Z6 * Z10) + Z14
  VFMADD231PD Z11, Z7, Z15 // Z15 = (Z7 * Z11) + Z15
  VBROADCASTSD CONST_GET_PTR(const_tan, 216), Z11
  VADDPD Z11, Z8, Z18
  VADDPD Z11, Z9, Z19
  VSUBPD Z18, Z11, Z10
  VSUBPD Z19, Z11, Z11
  VADDPD Z10, Z8, Z8
  VADDPD Z11, Z9, Z9
  VADDPD Z14, Z8, Z8
  VADDPD Z15, Z9, Z9
  VMULPD Z13, Z6, Z4
  VMULPD Z13, Z7, Z5
  VPBROADCASTQ CONSTF64_SIGN_BIT(), Z6
  VBROADCASTSD CONSTF64_1(), Z7
  VMOVAPD Z16, Z10
  VMOVAPD Z17, Z11
  VXORPD Z6, Z18, K5, Z10
  VXORPD Z6, Z19, K6, Z11
  VMOVAPD Z4, Z12
  VMOVAPD Z5, Z13
  VMOVAPD Z16, K5, Z18
  VMOVAPD Z17, K6, Z19
  VDIVPD Z18, Z7, Z16
  VDIVPD Z19, Z7, Z17
  VXORPD Z6, Z8, K5, Z12
  VXORPD Z6, Z9, K6, Z13
  VMOVAPD Z4, K5, Z8
  VMOVAPD Z5, K6, Z9
  VMULPD Z10, Z16, Z4
  VMULPD Z11, Z17, Z5
  VFMSUB213PD Z4, Z16, Z10   // Z10 = (Z16 * Z10) - Z4
  VFMSUB213PD Z5, Z17, Z11   // Z11 = (Z17 * Z11) - Z5
  VFNMADD213PD Z7, Z16, Z18 // Z18 = -(Z16 * Z18) + Z7
  VFNMADD213PD Z7, Z17, Z19 // Z19 = -(Z17 * Z19) + Z7
  VFNMADD231PD Z8, Z16, Z18  // Z18 = -(Z16 * Z8) + Z18
  VFNMADD231PD Z9, Z17, Z19  // Z19 = -(Z17 * Z9) + Z19
  VFMADD231PD Z12, Z16, Z10  // Z10 = (Z16 * Z12) + Z10
  VFMADD231PD Z13, Z17, Z11  // Z11 = (Z17 * Z13) + Z11
  VFMADD231PD Z18, Z4, Z10   // Z10 = (Z4 * Z18) + Z10
  VFMADD231PD Z19, Z5, Z11   // Z11 = (Z5 * Z19) + Z11
  VADDPD Z10, Z4, Z4
  VADDPD Z11, Z5, Z5
  VPXOR X6, X6, X6
  VCMPPD $VCMP_IMM_EQ_OQ, Z6, Z2, K5
  VCMPPD $VCMP_IMM_EQ_OQ, Z6, Z3, K6
  VMOVAPD Z2, K5, Z4
  VMOVAPD Z3, K6, Z5
  VMOVAPD Z4, Z2
  VMOVAPD Z5, Z3

next:
  NEXT()

tan_case_b:
  // case 'b': one or more lane has x >= 1e14
  VMULPD.BCST CONST_GET_PTR(const_tan, 32), Z2, Z8
  VMULPD.BCST CONST_GET_PTR(const_tan, 32), Z3, Z9
  VRNDSCALEPD $11, Z8, Z12
  VRNDSCALEPD $11, Z9, Z13
  VXORPD X8, X8, X8
  VMULPD.BCST CONST_GET_PTR(const_tan, 40), Z12, Z12
  VMULPD.BCST CONST_GET_PTR(const_tan, 40), Z13, Z13
  VBROADCASTSD CONST_GET_PTR(const_tan, 0), Z18
  VBROADCASTSD CONST_GET_PTR(const_tan, 0), Z19
  VFMSUB213PD Z10, Z2, Z18 // Z18 = (Z2 * Z18) - Z10
  VFMSUB213PD Z11, Z3, Z19 // Z19 = (Z3 * Z19) - Z11
  VFMADD231PD.BCST CONST_GET_PTR(const_tan, 48), Z2, Z18 // Z18 = (Z2 * mem) + Z18
  VFMADD231PD.BCST CONST_GET_PTR(const_tan, 48), Z3, Z19 // Z19 = (Z3 * mem) + Z19
  VCMPPD $VCMP_IMM_LT_OS, Z8, Z2, K5
  VCMPPD $VCMP_IMM_LT_OS, Z8, Z3, K6
  VBROADCASTSD CONSTF64_HALF(), Z20
  VBROADCASTSD CONSTF64_HALF(), Z21
  VBROADCASTSD CONST_GET_PTR(const_tan, 56), K5, Z20
  VBROADCASTSD CONST_GET_PTR(const_tan, 56), K6, Z21
  VSUBPD Z12, Z20, Z20
  VSUBPD Z13, Z21, Z21
  VADDPD Z20, Z10, Z22
  VADDPD Z21, Z11, Z23
  VSUBPD Z10, Z22, Z24
  VSUBPD Z11, Z23, Z25
  VSUBPD Z24, Z22, Z26
  VSUBPD Z25, Z23, Z27
  VSUBPD Z26, Z10, Z10
  VSUBPD Z27, Z11, Z11
  VSUBPD Z24, Z20, Z20
  VSUBPD Z25, Z21, Z21
  VADDPD Z10, Z20, Z10
  VADDPD Z11, Z21, Z11
  VADDPD Z10, Z18, Z10
  VADDPD Z11, Z19, Z11
  VADDPD Z10, Z22, Z10
  VADDPD Z11, Z23, Z11
  VRNDSCALEPD $11, Z10, Z18
  VRNDSCALEPD $11, Z11, Z19
  VBROADCASTSD CONST_GET_PTR(const_tan, 64), Z10
  VBROADCASTSD CONST_GET_PTR(const_tan, 64), Z11
  VMULPD Z10, Z18, Z20
  VMULPD Z11, Z19, Z21
  VFMADD213PD Z2, Z12, Z10 // Z10 = (Z12 * Z10) + Z2
  VFMADD213PD Z3, Z13, Z11 // Z11 = (Z13 * Z11) + Z3
  VADDPD Z20, Z10, Z22
  VADDPD Z21, Z11, Z23
  VSUBPD Z22, Z10, Z10
  VSUBPD Z23, Z11, Z11
  VADDPD Z10, Z20, Z10
  VADDPD Z11, Z21, Z11

  VBROADCASTSD CONST_GET_PTR(const_tan, 72), Z21
  VMULPD Z21, Z12, Z24
  VMULPD Z21, Z13, Z25
  VADDPD Z22, Z24, Z26
  VADDPD Z23, Z25, Z27
  VSUBPD Z22, Z26, Z8
  VSUBPD Z23, Z27, Z9
  VSUBPD Z8, Z24, Z24
  VSUBPD Z9, Z25, Z25
  VSUBPD Z8, Z26, Z8
  VSUBPD Z9, Z27, Z9
  VSUBPD Z8, Z22, Z22
  VSUBPD Z9, Z23, Z23
  VADDPD Z22, Z24, Z22
  VADDPD Z23, Z25, Z23
  VADDPD Z22, Z10, Z10
  VADDPD Z23, Z11, Z11
  VMULPD Z21, Z18, Z20
  VMULPD Z21, Z19, Z21
  VADDPD Z26, Z20, Z22
  VADDPD Z27, Z21, Z23
  VSUBPD Z26, Z22, Z24
  VSUBPD Z27, Z23, Z25
  VSUBPD Z24, Z22, Z8
  VSUBPD Z25, Z23, Z9
  VSUBPD Z8, Z26, Z26
  VSUBPD Z9, Z27, Z27
  VSUBPD Z24, Z20, Z20
  VSUBPD Z25, Z21, Z21
  VADDPD Z26, Z20, Z20
  VADDPD Z27, Z21, Z21

  VBROADCASTSD CONST_GET_PTR(const_tan, 80), Z25
  VADDPD Z10, Z20, Z10
  VADDPD Z11, Z21, Z11
  VMULPD Z25, Z12, Z20
  VMULPD Z25, Z13, Z21
  VADDPD Z22, Z20, Z26
  VADDPD Z23, Z21, Z27
  VSUBPD Z22, Z26, Z8
  VSUBPD Z23, Z27, Z9
  VSUBPD Z8, Z20, Z20
  VSUBPD Z9, Z21, Z21
  VSUBPD Z8, Z26, Z8
  VSUBPD Z9, Z27, Z9
  VSUBPD Z8, Z22, Z22
  VSUBPD Z9, Z23, Z23
  VADDPD Z22, Z20, Z20
  VADDPD Z23, Z21, Z21
  VADDPD Z10, Z20, Z10
  VADDPD Z11, Z21, Z11
  VMULPD Z25, Z18, Z20
  VMULPD Z25, Z19, Z21
  VADDPD Z26, Z20, Z22
  VADDPD Z27, Z21, Z23
  VSUBPD Z26, Z22, Z24
  VSUBPD Z27, Z23, Z25
  VSUBPD Z24, Z22, Z8
  VSUBPD Z25, Z23, Z9
  VSUBPD Z8, Z26, Z26
  VSUBPD Z9, Z27, Z27
  VSUBPD Z24, Z20, Z20
  VSUBPD Z25, Z21, Z21
  VBROADCASTSD CONST_GET_PTR(const_tan, 88), Z25
  VADDPD Z26, Z20, Z20
  VADDPD Z27, Z21, Z21
  VADDPD Z10, Z20, Z20
  VADDPD Z11, Z21, Z21
  VADDPD Z18, Z12, Z10
  VADDPD Z19, Z13, Z11
  VMULPD Z25, Z10, Z12
  VMULPD Z25, Z11, Z13
  VADDPD Z22, Z12, Z10
  VADDPD Z23, Z13, Z11
  VSUBPD Z10, Z22, Z22
  VSUBPD Z11, Z23, Z23
  VADDPD Z22, Z12, Z12
  VADDPD Z23, Z13, Z13
  VADDPD Z20, Z12, Z12
  VADDPD Z21, Z13, Z13

  VCVTPD2DQ.RN_SAE Z18, Y20
  VCVTPD2DQ.RN_SAE Z19, Y21
  VBROADCASTSD CONST_GET_PTR(const_tan, 96), Z25
  VINSERTI32X8 $1, Y21, Z20, Z20

  VMOVDQA32 Z20, K3, Z4
  VMOVAPD Z10, K3, Z14
  VMOVAPD Z11, K4, Z15
  VMOVAPD Z12, K3, Z16
  VMOVAPD Z13, K4, Z17

  VCMPPD $VCMP_IMM_GE_OQ, Z25, Z6, K3, K3
  VCMPPD $VCMP_IMM_GE_OQ, Z25, Z7, K4, K4
  KUNPCKBW K3, K4, K3
  KTESTW K3, K3
  JZ tan_eval_poly

  // case 'c': one or more lane has x >= 1e14
  VBROADCASTSD CONSTF64_POSITIVE_INF(), Z10
  MOVL $0xAAAA, R8
  LEAQ CONST_GET_PTR(const_rempi, 0), R15

  VCMPPD $VCMP_IMM_EQ_OQ, Z10, Z6, K3, K0
  VCMPPD $VCMP_IMM_EQ_OQ, Z10, Z7, K4, K5
  KUNPCKBW K0, K5, K0

  VGETEXPPD Z2, Z10
  VGETEXPPD Z3, Z11
  VCVTPD2DQ.RN_SAE Z10, Y10
  VCVTPD2DQ.RN_SAE Z11, Y11
  VINSERTI32X8 $1, Y11, Z10, Z10

  VPCMPGTD.BCST CONSTD_NEG_1(), Z10, K5
  VPANDD.BCST.Z CONST_GET_PTR(const_tan, 240), Z10, K5, Z10
  VPADDD.BCST CONST_GET_PTR(const_tan, 244), Z10, Z10
  VPCMPGTD.BCST CONST_GET_PTR(const_tan, 248), Z10, K5
  VPBROADCASTD.Z CONST_GET_PTR(const_tan, 252), K5, Z12
  VPSLLD $20, Z12, Z12
  VEXTRACTI32X8 $1, Z12, Y13
  KMOVW R8, K5
  VPEXPANDD.Z Z12, K5, Z12
  VPEXPANDD.Z Z13, K5, Z13
  VPADDQ Z2, Z12, Z18
  VPADDQ Z3, Z13, Z19
  VPSRAD $31, Z10, Z12
  VPANDND Z10, Z12, Z10
  VPSLLD $2, Z10, Z10
  VEXTRACTI32X8 $1, Z10, Y11

  KMOVB K3, K5
  KMOVB K4, K6
  VXORPD X12, X12, X12
  VXORPD X13, X13, X13
  VGATHERDPD 0(R15)(Y10*8), K5, Z12
  VGATHERDPD 0(R15)(Y11*8), K6, Z13
  ADDQ $8, R15

  VMULPD Z18, Z12, Z20
  VMULPD Z19, Z13, Z21
  VFMSUB213PD Z20, Z18, Z12 // Z12 = (Z18 * Z12) - Z20
  VFMSUB213PD Z21, Z19, Z13 // Z13 = (Z19 * Z13) - Z21
  VBROADCASTSD CONST_GET_PTR(const_tan, 104), Z22
  VBROADCASTSD CONST_GET_PTR(const_tan, 112), Z23
  VMULPD Z22, Z20, Z24
  VMULPD Z22, Z21, Z25
  VRNDSCALEPD $8, Z24, Z24
  VRNDSCALEPD $8, Z25, Z25
  VRNDSCALEPD $8, Z20, Z26
  VRNDSCALEPD $8, Z21, Z27
  VMULPD Z22, Z26, Z26
  VMULPD Z22, Z27, Z27
  VSUBPD Z26, Z24, Z26
  VSUBPD Z27, Z25, Z27
  VCVTPD2DQ.RZ_SAE Z26, Y26
  VCVTPD2DQ.RZ_SAE Z27, Y27
  VINSERTI32X8 $1, Y27, Z26, Z26
  VMULPD Z23, Z24, Z24
  VMULPD Z23, Z25, Z25
  VSUBPD Z24, Z20, Z20
  VSUBPD Z25, Z21, Z21
  VADDPD Z12, Z20, Z24
  VADDPD Z13, Z21, Z25
  VSUBPD Z24, Z20, Z20
  VSUBPD Z25, Z21, Z21
  VADDPD Z20, Z12, Z12
  VADDPD Z21, Z13, Z13

  KMOVB K3, K5
  KMOVB K4, K6
  VXORPD X20, X20, X20
  VXORPD X21, X21, X21
  VGATHERDPD 0(R15)(Y10*8), K5, Z20
  VGATHERDPD 0(R15)(Y11*8), K6, Z21
  ADDQ $8, R15

  VMULPD Z18, Z20, Z6
  VMULPD Z19, Z21, Z7
  VFMSUB213PD Z6, Z18, Z20 // Z20 = (Z18 * Z20) - Z6
  VFMSUB213PD Z7, Z19, Z21 // Z21 = (Z19 * Z21) - Z7
  VADDPD Z12, Z20, Z12
  VADDPD Z13, Z21, Z13
  VADDPD Z24, Z6, Z8
  VADDPD Z25, Z7, Z9
  VSUBPD Z24, Z8, Z20
  VSUBPD Z25, Z9, Z21
  VSUBPD Z20, Z8, Z5
  VSUBPD Z5, Z24, Z24
  VSUBPD Z21, Z9, Z5
  VSUBPD Z5, Z25, Z25
  VSUBPD Z20, Z6, Z20
  VSUBPD Z21, Z7, Z21
  VADDPD Z24, Z20, Z20
  VADDPD Z25, Z21, Z21
  VADDPD Z20, Z12, Z12
  VADDPD Z21, Z13, Z13
  VMULPD Z22, Z8, Z20
  VMULPD Z22, Z9, Z21
  VRNDSCALEPD $8, Z20, Z24
  VRNDSCALEPD $8, Z21, Z25
  VRNDSCALEPD $8, Z8, Z20
  VRNDSCALEPD $8, Z9, Z21
  VMULPD Z22, Z20, Z20
  VMULPD Z22, Z21, Z21
  VSUBPD Z20, Z24, Z20
  VSUBPD Z21, Z25, Z21
  VCVTPD2DQ.RZ_SAE Z20, Y20
  VCVTPD2DQ.RZ_SAE Z21, Y21
  VINSERTI32X8 $1, Y21, Z20, Z20
  VPADDD Z26, Z20, Z20
  VMULPD Z23, Z24, Z22
  VMULPD Z23, Z25, Z23
  VSUBPD Z22, Z8, Z22
  VSUBPD Z23, Z9, Z23
  VADDPD Z12, Z22, Z24
  VADDPD Z13, Z23, Z25
  VSUBPD Z24, Z22, Z22
  VSUBPD Z25, Z23, Z23
  VADDPD Z22, Z12, Z12
  VADDPD Z23, Z13, Z13

  KMOVB K3, K5
  KMOVB K4, K6
  VXORPD X22, X22, X22
  VXORPD X23, X23, X23
  VGATHERDPD 0(R15)(Y10*8), K5, Z22
  VGATHERDPD 0(R15)(Y11*8), K6, Z23
  ADDQ $8, R15

  KMOVB K3, K5
  KMOVB K4, K6
  VXORPD X26, X26, X26
  VXORPD X27, X27, X27
  VGATHERDPD 0(R15)(Y10*8), K5, Z26
  VGATHERDPD 0(R15)(Y11*8), K6, Z27

  VMULPD Z18, Z22, Z10
  VMULPD Z19, Z23, Z11
  VFMSUB213PD Z10, Z18, Z22 // Z22 = (Z18 * Z22) - Z10
  VFMSUB213PD Z11, Z19, Z23 // Z23 = (Z19 * Z23) - Z11
  VFMADD231PD Z26, Z18, Z22 // Z22 = (Z18 * Z26) + Z22
  VFMADD231PD Z27, Z19, Z23 // Z23 = (Z19 * Z27) + Z23
  VADDPD Z12, Z22, Z12
  VADDPD Z13, Z23, Z13
  VADDPD Z24, Z10, Z22
  VADDPD Z25, Z11, Z23
  VSUBPD Z24, Z22, Z26
  VSUBPD Z25, Z23, Z27
  VSUBPD Z26, Z22, Z6
  VSUBPD Z27, Z23, Z7
  VSUBPD Z6, Z24, Z24
  VSUBPD Z7, Z25, Z25
  VSUBPD Z26, Z10, Z10
  VSUBPD Z27, Z11, Z11
  VADDPD Z24, Z10, Z10
  VADDPD Z25, Z11, Z11
  VADDPD Z10, Z12, Z10
  VADDPD Z11, Z13, Z11
  VADDPD Z10, Z22, Z24
  VADDPD Z11, Z23, Z25
  VSUBPD Z24, Z22, Z12
  VSUBPD Z25, Z23, Z13
  VADDPD Z12, Z10, Z22
  VADDPD Z13, Z11, Z23
  VBROADCASTSD CONST_GET_PTR(const_tan, 120), Z26
  VBROADCASTSD CONST_GET_PTR(const_tan, 128), Z27
  VMULPD Z26, Z24, Z10
  VMULPD Z26, Z25, Z11
  VMOVAPD Z26, Z12
  VMOVAPD Z26, Z13
  VFMSUB213PD Z10, Z24, Z12 // Z12 = (Z24 * Z12) - Z10
  VFMSUB213PD Z11, Z25, Z13 // Z13 = (Z25 * Z13) - Z11
  VFMADD231PD Z22, Z26, Z12 // Z12 = (Z26 * Z22) + Z12
  VFMADD231PD Z23, Z26, Z13 // Z13 = (Z26 * Z23) + Z13
  VFMADD231PD Z27, Z24, Z12 // Z12 = (Z24 * Z27) + Z12
  VFMADD231PD Z27, Z25, Z13 // Z13 = (Z25 * Z27) + Z13
  VBROADCASTSD CONSTF64_ABS_BITS(), Z26
  VBROADCASTSD CONST_GET_PTR(const_tan, 136), Z27
  VANDPD Z26, Z18, Z22
  VANDPD Z26, Z19, Z23
  VCMPPD $VCMP_IMM_LT_OS, Z27, Z22, K3, K5
  VCMPPD $VCMP_IMM_LT_OS, Z27, Z23, K4, K6
  VMOVAPD Z18, K5, Z10
  VMOVAPD Z19, K6, Z11
  VXORPD X8, X8, X8
  VMOVAPD Z8, K5, Z12
  VMOVAPD Z8, K6, Z13
  VCMPPD $VCMP_IMM_UNORD_Q, Z8, Z2, K3, K5
  KORB K0, K5, K5
  VCMPPD $VCMP_IMM_UNORD_Q, Z8, Z3, K4, K6
  KSHIFTRW $8, K0, K0
  KORB K0, K6, K6

  VPTERNLOGD $255, Z6, Z6, Z6
  VPTERNLOGD $255, Z7, Z7, Z7

  VMOVAPD Z6, K5, Z14
  VMOVAPD Z7, K6, Z15
  VMOVAPD Z6, K5, Z16
  VMOVAPD Z7, K6, Z17

  VMOVDQA32 Z20, K3, Z4
  VMOVAPD Z10, K3, Z14
  VMOVAPD Z11, K4, Z15
  VMOVAPD Z12, K3, Z16
  VMOVAPD Z13, K4, Z17
  JMP tan_eval_poly

// Inverse sine: asin(x)
CONST_DATA_U64(const_asin,   0, $0x3fa02ff4c7428a47) // f64(0.031615876506539346)
CONST_DATA_U64(const_asin,   8, $0xbf9032e75ccd4ae8) // f64(-0.015819182433299966)
CONST_DATA_U64(const_asin,  16, $0x3f93c0e0817e9742) // f64(0.019290454772679107)
CONST_DATA_U64(const_asin,  24, $0x3f7b0ef96b727e7e) // f64(0.0066060774762771706)
CONST_DATA_U64(const_asin,  32, $0x3f88e3fd48d0fb6f) // f64(0.012153605255773773)
CONST_DATA_U64(const_asin,  40, $0x3f8c70ddf81249fc) // f64(0.013887151845016092)
CONST_DATA_U64(const_asin,  48, $0x3f91c6b5042ec6b2) // f64(0.017359569912236146)
CONST_DATA_U64(const_asin,  56, $0x3f96e89f8578b64e) // f64(0.022371761819320483)
CONST_DATA_U64(const_asin,  64, $0x3f9f1c72c5fd95ba) // f64(0.030381959280381322)
CONST_DATA_U64(const_asin,  72, $0x3fa6db6db407c2b3) // f64(0.044642856813771024)
CONST_DATA_U64(const_asin,  80, $0x3fb3333333375cd0) // f64(0.075000000003785816)
CONST_DATA_U64(const_asin,  88, $0x3fc55555555552f4) // f64(0.16666666666664975)
CONST_DATA_U64(const_asin,  96, $0x3fe921fb54442d18) // f64(0.78539816339744828)
CONST_DATA_U64(const_asin, 104, $0x3c81a62633145c07) // f64(3.061616997868383E-17)
CONST_GLOBAL(const_asin, $112)

TEXT bcasinf(SB), NOSPLIT|NOFRAME, $0
  KTESTW K1, K1
  JZ next

  KSHIFTRW $8, K1, K2

  VBROADCASTSD CONSTF64_ABS_BITS(), Z7
  VBROADCASTSD CONSTF64_HALF(), Z8
  VBROADCASTSD CONSTF64_1(), Z9

  VANDPD.Z Z7, Z2, K1, Z6
  VANDPD.Z Z7, Z3, K2, Z7
  VCMPPD $VCMP_IMM_LT_OQ, Z8, Z6, K1, K3
  VCMPPD $VCMP_IMM_LT_OQ, Z8, Z7, K2, K4
  VSUBPD Z6, Z9, Z4
  VSUBPD Z7, Z9, Z5
  VMULPD Z8, Z4, Z4
  VMULPD Z8, Z5, Z5
  VMULPD Z2, Z2, K3, Z4
  VMULPD Z3, Z3, K4, Z5
  VSQRTPD Z4, Z12
  VSQRTPD Z5, Z13
  VMULPD Z12, Z12, Z14
  VMULPD Z13, Z13, Z15
  VMOVAPD Z12, Z16
  VMOVAPD Z13, Z17
  VFMSUB213PD Z14, Z12, Z16 // Z16 = (Z12 * Z16) - Z14
  VFMSUB213PD Z15, Z13, Z17 // Z17 = (Z13 * Z17) - Z15
  VADDPD Z14, Z4, Z18
  VADDPD Z15, Z5, Z19
  VSUBPD Z4, Z18, Z20
  VSUBPD Z5, Z19, Z21
  VSUBPD Z20, Z18, Z22
  VSUBPD Z21, Z19, Z23
  VSUBPD Z22, Z4, Z22
  VSUBPD Z23, Z5, Z23
  VSUBPD Z20, Z14, Z14
  VSUBPD Z21, Z15, Z15
  VADDPD Z22, Z14, Z14
  VADDPD Z23, Z15, Z15
  VADDPD Z14, Z16, Z14
  VADDPD Z15, Z17, Z15
  VDIVPD Z12, Z9, Z16
  VDIVPD Z13, Z9, Z17
  VFNMADD213PD Z9, Z16, Z12 // Z12 = -(Z16 * Z12) + Z9
  VFNMADD213PD Z9, Z17, Z13 // Z13 = -(Z17 * Z13) + Z9
  VMULPD Z12, Z16, Z12
  VMULPD Z13, Z17, Z13
  VMULPD Z18, Z16, Z20
  VMULPD Z19, Z17, Z21
  VMOVAPD Z16, Z22
  VMOVAPD Z17, Z23
  VFMSUB213PD Z20, Z18, Z22 // Z22 = (Z18 * Z22) - Z20
  VFMSUB213PD Z21, Z19, Z23 // Z23 = (Z19 * Z23) - Z21
  VFMADD231PD Z14, Z16, Z22 // Z22 = (Z16 * Z14) + Z22
  VFMADD231PD Z15, Z17, Z23 // Z23 = (Z17 * Z15) + Z23
  VFMADD231PD Z12, Z18, Z22 // Z22 = (Z18 * Z12) + Z22
  VFMADD231PD Z13, Z19, Z23 // Z23 = (Z19 * Z13) + Z23
  VMULPD Z8, Z20, Z12
  VMULPD Z8, Z21, Z13
  VMOVAPD Z6, K3, Z12
  VMOVAPD Z7, K4, Z13
  VCMPPD $VCMP_IMM_EQ_OQ, Z9, Z6, K5
  VCMPPD $VCMP_IMM_EQ_OQ, Z9, Z7, K6
  VXORPD Z12, Z12, K5, Z12
  VXORPD Z13, Z13, K6, Z13
  KORW K3, K5, K5
  KORW K4, K6, K6
  KNOTW K5, K5
  KNOTW K6, K6
  VMULPD.Z Z8, Z22, K5, Z6
  VMULPD.Z Z8, Z23, K6, Z7
  VMULPD Z4, Z4, Z8
  VMULPD Z5, Z5, Z9
  VMULPD Z8, Z8, Z10
  VMULPD Z9, Z9, Z11
  VMULPD Z10, Z10, Z14
  VMULPD Z11, Z11, Z15
  VBROADCASTSD CONST_GET_PTR(const_asin, 0), Z16
  VBROADCASTSD CONST_GET_PTR(const_asin, 16), Z18
  VBROADCASTSD CONST_GET_PTR(const_asin, 8), Z20
  VBROADCASTSD CONST_GET_PTR(const_asin, 24), Z21
  VMOVAPD Z16, Z17
  VFMADD213PD Z20, Z4, Z16 // Z16 = (Z4 * Z16) + Z20
  VFMADD213PD Z20, Z5, Z17 // Z17 = (Z5 * Z17) + Z20
  VMOVAPD Z18, Z19
  VFMADD213PD Z21, Z4, Z18 // Z18 = (Z4 * Z18) + Z21
  VFMADD213PD Z21, Z5, Z19 // Z19 = (Z5 * Z19) + Z21
  VBROADCASTSD CONST_GET_PTR(const_asin, 32), Z20
  VBROADCASTSD CONST_GET_PTR(const_asin, 48), Z22
  VMOVAPD Z20, Z21
  VMOVAPD Z22, Z23
  VBROADCASTSD CONST_GET_PTR(const_asin, 40), Z24
  VBROADCASTSD CONST_GET_PTR(const_asin, 56), Z25
  VFMADD213PD Z24, Z4, Z20 // Z20 = (Z4 * Z20) + Z24
  VFMADD213PD Z24, Z5, Z21 // Z21 = (Z5 * Z21) + Z24
  VFMADD213PD Z25, Z4, Z22 // Z22 = (Z4 * Z22) + Z25
  VFMADD213PD Z25, Z5, Z23 // Z23 = (Z5 * Z23) + Z25
  VFMADD231PD Z16, Z8, Z18 // Z18 = (Z8 * Z16) + Z18
  VFMADD231PD Z17, Z9, Z19 // Z19 = (Z9 * Z17) + Z19
  VFMADD231PD Z20, Z8, Z22 // Z22 = (Z8 * Z20) + Z22
  VFMADD231PD Z21, Z9, Z23 // Z23 = (Z9 * Z21) + Z23
  VBROADCASTSD CONST_GET_PTR(const_asin, 64), Z16
  VBROADCASTSD CONST_GET_PTR(const_asin, 80), Z20
  VMOVAPD Z16, Z17
  VMOVAPD Z20, Z21
  VBROADCASTSD CONST_GET_PTR(const_asin, 72), Z24
  VBROADCASTSD CONST_GET_PTR(const_asin, 88), Z25
  VFMADD213PD Z24, Z4, Z16 // Z16 = (Z4 * Z16) + Z24
  VFMADD213PD Z24, Z5, Z17 // Z17 = (Z5 * Z17) + Z24
  VFMADD213PD Z25, Z4, Z20 // Z20 = (Z4 * Z20) + Z25
  VFMADD213PD Z25, Z5, Z21 // Z21 = (Z5 * Z21) + Z25
  VFMADD231PD Z16, Z8, Z20  // Z20 = (Z8 * Z16) + Z20
  VFMADD231PD Z17, Z9, Z21  // Z21 = (Z9 * Z17) + Z21
  VFMADD231PD Z22, Z10, Z20 // Z20 = (Z10 * Z22) + Z20
  VFMADD231PD Z23, Z11, Z21 // Z21 = (Z11 * Z23) + Z21
  VFMADD231PD Z18, Z14, Z20 // Z20 = (Z14 * Z18) + Z20
  VFMADD231PD Z19, Z15, Z21 // Z21 = (Z15 * Z19) + Z21
  VMULPD Z12, Z4, Z4
  VMULPD Z13, Z5, Z5
  VBROADCASTSD CONST_GET_PTR(const_asin, 96), Z9
  VBROADCASTSD CONST_GET_PTR(const_asin, 104), Z14
  VMULPD Z4, Z20, Z4
  VMULPD Z5, Z21, Z5
  VSUBPD Z12, Z9, Z10
  VSUBPD Z13, Z9, Z11
  VSUBPD Z10, Z9, Z8
  VSUBPD Z11, Z9, Z9
  VSUBPD Z12, Z8, Z8
  VSUBPD Z13, Z9, Z9
  VADDPD Z14, Z8, Z8
  VADDPD Z14, Z9, Z9
  VSUBPD Z6, Z8, Z6
  VSUBPD Z7, Z9, Z7
  VSUBPD Z4, Z10, Z8
  VSUBPD Z5, Z11, Z9
  VSUBPD Z8, Z10, Z10
  VSUBPD Z9, Z11, Z11
  VSUBPD Z4, Z10, Z10
  VSUBPD Z5, Z11, Z11
  VADDPD Z6, Z10, Z6
  VADDPD Z7, Z11, Z7
  VADDPD Z6, Z8, Z6
  VADDPD Z7, Z9, Z7
  VADDPD Z6, Z6, Z6
  VADDPD Z7, Z7, Z7
  VBROADCASTSD CONSTF64_SIGN_BIT(), Z10
  VADDPD Z4, Z12, K3, Z6
  VADDPD Z5, Z13, K4, Z7
  VPTERNLOGQ $108, Z10, Z6, K1, Z2
  VPTERNLOGQ $108, Z10, Z7, K2, Z3

next:
  NEXT()

// Inverse cosine: acos(x)
CONST_DATA_U64(const_acos,   0, $0x3fa02ff4c7428a47) // f64(0.031615876506539346)
CONST_DATA_U64(const_acos,   8, $0xbf9032e75ccd4ae8) // f64(-0.015819182433299966)
CONST_DATA_U64(const_acos,  16, $0x3f93c0e0817e9742) // f64(0.019290454772679107)
CONST_DATA_U64(const_acos,  24, $0x3f7b0ef96b727e7e) // f64(0.0066060774762771706)
CONST_DATA_U64(const_acos,  32, $0x3f88e3fd48d0fb6f) // f64(0.012153605255773773)
CONST_DATA_U64(const_acos,  40, $0x3f8c70ddf81249fc) // f64(0.013887151845016092)
CONST_DATA_U64(const_acos,  48, $0x3f91c6b5042ec6b2) // f64(0.017359569912236146)
CONST_DATA_U64(const_acos,  56, $0x3f96e89f8578b64e) // f64(0.022371761819320483)
CONST_DATA_U64(const_acos,  64, $0x3f9f1c72c5fd95ba) // f64(0.030381959280381322)
CONST_DATA_U64(const_acos,  72, $0x3fa6db6db407c2b3) // f64(0.044642856813771024)
CONST_DATA_U64(const_acos,  80, $0x3fb3333333375cd0) // f64(0.075000000003785816)
CONST_DATA_U64(const_acos,  88, $0x3fc55555555552f4) // f64(0.16666666666664975)
CONST_DATA_U64(const_acos,  96, $0x3ff921fb54442d18) // f64(1.5707963267948966)
CONST_DATA_U64(const_acos, 104, $0x3c91a62633145c07) // f64(6.123233995736766E-17)
CONST_DATA_U64(const_acos, 112, $0x400921fb54442d18) // f64(3.1415926535897931)
CONST_DATA_U64(const_acos, 120, $0x3ca1a62633145c07) // f64(1.2246467991473532E-16)
CONST_GLOBAL(const_acos, $128)

TEXT bcacosf(SB), NOSPLIT|NOFRAME, $0
  KTESTW K1, K1
  JZ next

  KSHIFTRW $8, K1, K2

  VBROADCASTSD CONSTF64_ABS_BITS(), Z5
  VBROADCASTSD CONSTF64_HALF(), Z6
  VBROADCASTSD CONSTF64_1(), Z7
  VXORPD X10, X10, X10

  VANDPD.Z Z5, Z2, K1, Z4
  VANDPD.Z Z5, Z3, K2, Z5
  VCMPPD $VCMP_IMM_LT_OS, Z6, Z4, K1, K3
  VCMPPD $VCMP_IMM_LT_OS, Z6, Z5, K2, K4
  VSUBPD Z4, Z7, Z8
  VSUBPD Z5, Z7, Z9
  VMULPD Z6, Z8, Z8
  VMULPD Z6, Z9, Z9
  VMULPD Z2, Z2, K3, Z8
  VMULPD Z3, Z3, K4, Z9
  VSQRTPD Z8, Z12
  VSQRTPD Z9, Z13
  VMULPD Z12, Z12, Z14
  VMULPD Z13, Z13, Z15
  VMOVAPD Z12, Z16
  VMOVAPD Z13, Z17
  VFMSUB213PD Z14, Z12, Z16 // Z16 = (Z12 * Z16) - Z14
  VFMSUB213PD Z15, Z13, Z17 // Z17 = (Z13 * Z17) - Z15
  VADDPD Z14, Z8, Z18
  VADDPD Z15, Z9, Z19
  VSUBPD Z8, Z18, Z20
  VSUBPD Z9, Z19, Z21
  VSUBPD Z20, Z18, Z22
  VSUBPD Z21, Z19, Z23
  VSUBPD Z22, Z8, Z22
  VSUBPD Z23, Z9, Z23
  VSUBPD Z20, Z14, Z14
  VSUBPD Z21, Z15, Z15
  VADDPD Z22, Z14, Z14
  VADDPD Z23, Z15, Z15
  VADDPD Z14, Z16, Z14
  VADDPD Z15, Z17, Z15
  VDIVPD Z12, Z7, Z16
  VDIVPD Z13, Z7, Z17
  VFNMADD213PD Z7, Z16, Z12 // Z12 = -(Z16 * Z12) + Z7
  VFNMADD213PD Z7, Z17, Z13 // Z13 = -(Z17 * Z13) + Z7
  VMULPD Z12, Z16, Z12
  VMULPD Z13, Z17, Z13
  VMULPD Z18, Z16, Z20
  VMULPD Z19, Z17, Z21
  VMOVAPD Z16, Z22
  VMOVAPD Z17, Z23
  VFMSUB213PD Z20, Z18, Z22 // Z22 = (Z18 * Z22) - Z20
  VFMSUB213PD Z21, Z19, Z23 // Z23 = (Z19 * Z23) - Z21
  VFMADD231PD Z14, Z16, Z22 // Z22 = (Z16 * Z14) + Z22
  VFMADD231PD Z15, Z17, Z23 // Z23 = (Z17 * Z15) + Z23
  VFMADD231PD Z12, Z18, Z22 // Z22 = (Z18 * Z12) + Z22
  VFMADD231PD Z13, Z19, Z23 // Z23 = (Z19 * Z13) + Z23
  VMULPD Z6, Z20, Z12
  VMULPD Z6, Z21, Z13
  VMOVAPD Z4, K3, Z12
  VMOVAPD Z5, K4, Z13
  VCMPPD $VCMP_IMM_EQ_OQ, Z7, Z4, K5
  VCMPPD $VCMP_IMM_EQ_OQ, Z7, Z5, K6
  VXORPD Z12, Z12, K5, Z12
  VXORPD Z13, Z13, K6, Z13
  KORW K3, K5, K5
  KORW K4, K6, K6
  KNOTW K5, K5
  KNOTW K6, K6
  VMULPD.Z Z6, Z22, K5, Z14
  VMULPD.Z Z6, Z23, K6, Z15
  VMULPD Z8, Z8, Z16
  VMULPD Z9, Z9, Z17
  VMULPD Z16, Z16, Z18
  VMULPD Z17, Z17, Z19
  VBROADCASTSD CONST_GET_PTR(const_acos, 0), Z20
  VBROADCASTSD CONST_GET_PTR(const_acos, 16), Z22
  VMOVAPD Z20, Z21
  VMOVAPD Z22, Z23
  VBROADCASTSD CONST_GET_PTR(const_acos, 8), Z24
  VBROADCASTSD CONST_GET_PTR(const_acos, 24), Z25
  VFMADD213PD Z24, Z8, Z20 // Z20 = (Z8 * Z20) + Z24
  VFMADD213PD Z24, Z9, Z21 // Z21 = (Z9 * Z21) + Z24
  VFMADD213PD Z25, Z8, Z22 // Z22 = (Z8 * Z22) + Z25
  VFMADD213PD Z25, Z9, Z23 // Z23 = (Z9 * Z23) + Z25
  VBROADCASTSD CONST_GET_PTR(const_acos, 32), Z24
  VBROADCASTSD CONST_GET_PTR(const_acos, 48), Z26
  VMOVAPD Z24, Z25
  VMOVAPD Z26, Z27
  VFMADD213PD.BCST CONST_GET_PTR(const_acos, 40), Z8, Z24 // Z24 = (Z8 * Z24) + mem
  VFMADD213PD.BCST CONST_GET_PTR(const_acos, 40), Z9, Z25 // Z25 = (Z9 * Z25) + mem
  VFMADD213PD.BCST CONST_GET_PTR(const_acos, 56), Z8, Z26 // Z26 = (Z8 * Z26) + mem
  VFMADD213PD.BCST CONST_GET_PTR(const_acos, 56), Z9, Z27 // Z27 = (Z9 * Z27) + mem
  VFMADD231PD Z20, Z16, Z22 // Z22 = (Z16 * Z20) + Z22
  VFMADD231PD Z21, Z17, Z23 // Z23 = (Z17 * Z21) + Z23
  VFMADD231PD Z24, Z16, Z26 // Z26 = (Z16 * Z24) + Z26
  VFMADD231PD Z25, Z17, Z27 // Z27 = (Z17 * Z25) + Z27
  VBROADCASTSD CONST_GET_PTR(const_acos, 64), Z20
  VBROADCASTSD CONST_GET_PTR(const_acos, 80), Z24
  VMOVAPD Z20, Z21
  VMOVAPD Z24, Z25
  VFMADD213PD.BCST CONST_GET_PTR(const_acos, 72), Z8, Z20 // Z20 = (Z8 * Z20) + mem
  VFMADD213PD.BCST CONST_GET_PTR(const_acos, 72), Z9, Z21 // Z21 = (Z9 * Z21) + mem
  VFMADD213PD.BCST CONST_GET_PTR(const_acos, 88), Z8, Z24 // Z24 = (Z8 * Z24) + mem
  VFMADD213PD.BCST CONST_GET_PTR(const_acos, 88), Z9, Z25 // Z25 = (Z9 * Z25) + mem
  VFMADD231PD Z20, Z16, Z24 // Z24 = (Z16 * Z20) + Z24
  VFMADD231PD Z21, Z17, Z25 // Z25 = (Z17 * Z21) + Z25
  VFMADD231PD Z26, Z18, Z24 // Z24 = (Z18 * Z26) + Z24
  VMULPD Z18, Z18, Z18
  VFMADD231PD Z27, Z19, Z25 // Z25 = (Z19 * Z27) + Z25
  VMULPD Z19, Z19, Z19
  VFMADD231PD Z22, Z18, Z24 // Z24 = (Z18 * Z22) + Z24
  VFMADD231PD Z23, Z19, Z25 // Z25 = (Z19 * Z23) + Z25
  VBROADCASTSD CONSTF64_SIGN_BIT(), Z17
  VMULPD Z12, Z8, Z8
  VMULPD Z13, Z9, Z9
  VMULPD Z8, Z24, Z8
  VMULPD Z9, Z25, Z9
  VANDPD Z17, Z2, Z16
  VANDPD Z17, Z3, Z17
  VXORPD Z12, Z16, Z18
  VXORPD Z13, Z17, Z19
  VXORPD Z8, Z16, Z16
  VXORPD Z9, Z17, Z17
  VADDPD Z16, Z18, Z20
  VADDPD Z17, Z19, Z21
  VSUBPD Z20, Z18, Z18
  VSUBPD Z21, Z19, Z19
  VBROADCASTSD CONST_GET_PTR(const_acos, 96), Z23
  VBROADCASTSD CONST_GET_PTR(const_acos, 104), Z24
  VADDPD Z16, Z18, Z16
  VADDPD Z17, Z19, Z17
  VSUBPD Z20, Z23, Z18
  VSUBPD Z21, Z23, Z19
  VSUBPD Z18, Z23, Z22
  VSUBPD Z19, Z23, Z23
  VSUBPD Z20, Z22, Z20
  VSUBPD Z21, Z23, Z21
  VADDPD Z24, Z20, Z20
  VADDPD Z24, Z21, Z21
  VADDPD Z8, Z12, Z22
  VADDPD Z9, Z13, Z23
  VSUBPD Z22, Z12, Z12
  VSUBPD Z23, Z13, Z13
  VADDPD Z12, Z8, Z8
  VADDPD Z13, Z9, Z9
  VADDPD Z14, Z8, Z8
  VADDPD Z15, Z9, Z9
  VADDPD Z22, Z22, Z12
  VADDPD Z23, Z23, Z13
  VADDPD Z8, Z8, Z8
  VADDPD Z9, Z9, Z9
  VMOVAPD Z18, K3, Z12
  VMOVAPD Z19, K4, Z13
  VSUBPD Z16, Z20, K3, Z8
  VSUBPD Z17, Z21, K4, Z9
  VCMPPD $VCMP_IMM_LT_OS, Z10, Z2, K1, K3
  VCMPPD $VCMP_IMM_LT_OS, Z10, Z3, K2, K4
  VCMPPD $VCMP_IMM_NLT_US, Z6, Z4, K3, K3
  VCMPPD $VCMP_IMM_NLT_US, Z6, Z5, K4, K4
  VBROADCASTSD CONST_GET_PTR(const_acos, 112), Z11
  VBROADCASTSD CONST_GET_PTR(const_acos, 120), Z14
  VSUBPD Z12, Z11, Z4
  VSUBPD Z13, Z11, Z5
  VSUBPD Z4, Z11, Z10
  VSUBPD Z5, Z11, Z11
  VSUBPD Z12, Z10, Z10
  VSUBPD Z13, Z11, Z11
  VADDPD Z14, Z10, Z10
  VADDPD Z14, Z11, Z11
  VMOVAPD Z4, K3, Z12
  VMOVAPD Z5, K4, Z13
  VSUBPD Z8, Z10, K3, Z8
  VSUBPD Z9, Z11, K4, Z9
  VADDPD Z8, Z12, K1, Z2
  VADDPD Z9, Z13, K2, Z3

next:
  NEXT()

// Inverse tangent: atan(x)
CONST_DATA_U64(const_atan,   0, $0xbff0000000000000) // f64(-1)
CONST_DATA_U64(const_atan,   8, $0x3ee64adb3e06ee72) // f64(1.0629848419144875E-5)
CONST_DATA_U64(const_atan,  16, $0xbf2077212aa7d6ce) // f64(-1.2562064996728687E-4)
CONST_DATA_U64(const_atan,  24, $0x3f471ece4d9ced98) // f64(7.0557664296393412E-4)
CONST_DATA_U64(const_atan,  32, $0xbf64a20138b90cee) // f64(-0.0025186561449871336)
CONST_DATA_U64(const_atan,  40, $0x3f7a788ec28e9fb3) // f64(0.0064626289903699117)
CONST_DATA_U64(const_atan,  48, $0xbf8a45a2ea379db5) // f64(-0.012828133366339903)
CONST_DATA_U64(const_atan,  56, $0x3f954d3eccf8f320) // f64(0.02080247999241458)
CONST_DATA_U64(const_atan,  64, $0xbf9d9805e7ba23e7) // f64(-0.028900234478474032)
CONST_DATA_U64(const_atan,  72, $0x3fa26bc6260b1bdd) // f64(0.035978500503510459)
CONST_DATA_U64(const_atan,  80, $0xbfa56d2d526c0577) // f64(-0.041848579703592508)
CONST_DATA_U64(const_atan,  88, $0x3fa81b6efb51f8a6) // f64(0.047084301165328399)
CONST_DATA_U64(const_atan,  96, $0xbfaae027d1895f2e) // f64(-0.052491421058844842)
CONST_DATA_U64(const_atan, 104, $0x3fae1a556400767b) // f64(0.0587946590969581)
CONST_DATA_U64(const_atan, 112, $0xbfb110c441e542d6) // f64(-0.06666208847787955)
CONST_DATA_U64(const_atan, 120, $0x3fb3b131f3b00d10) // f64(0.076922533029620376)
CONST_DATA_U64(const_atan, 128, $0xbfb745d0ac14efec) // f64(-0.090909044277338757)
CONST_DATA_U64(const_atan, 136, $0x3fbc71c710b37a0b) // f64(0.11111110837689624)
CONST_DATA_U64(const_atan, 144, $0xbfc249249211afc7) // f64(-0.14285714275626857)
CONST_DATA_U64(const_atan, 152, $0x3fc9999999987cf0) // f64(0.19999999999797735)
CONST_DATA_U64(const_atan, 160, $0xbfd555555555543a) // f64(-0.33333333333331761)
CONST_DATA_U64(const_atan, 168, $0x3ff921fb54442d18) // f64(1.5707963267948966)
CONST_DATA_U64(const_atan, 176, $0x3c91a62633145c07) // f64(6.123233995736766E-17)
CONST_GLOBAL(const_atan, $184)

TEXT bcatanf(SB), NOSPLIT|NOFRAME, $0
  KTESTW K1, K1
  JZ next

  KSHIFTRW $8, K1, K2
  VBROADCASTSD CONSTF64_ABS_BITS(), Z5
  VBROADCASTSD CONST_GET_PTR(const_atan, 0), Z7
  VBROADCASTSD CONSTF64_1(), Z12

  VANDPD Z5, Z2, Z4
  VANDPD Z5, Z3, Z5
  VCMPPD $VCMP_IMM_LT_OS, Z4, Z12, K1, K3
  VCMPPD $VCMP_IMM_LT_OS, Z5, Z12, K2, K4
  VBLENDMPD Z7, Z4, K3, Z6
  VBLENDMPD Z7, Z5, K4, Z7
  VBROADCASTSD.Z CONSTF64_SIGN_BIT(), K3, Z14
  VBROADCASTSD.Z CONSTF64_SIGN_BIT(), K4, Z15
  VMAXPD Z12, Z4, Z16
  VMAXPD Z12, Z5, Z17
  VDIVPD Z16, Z12, Z18
  VDIVPD Z17, Z12, Z19
  VXORPD X20, X20, X20
  VXORPD X21, X21, X21
  VMULPD Z18, Z6, Z10
  VMULPD Z19, Z7, Z11
  VFMSUB213PD Z10, Z18, Z6   // Z6 = (Z18 * Z6) - Z10
  VFMSUB213PD Z11, Z19, Z7   // Z7 = (Z19 * Z7) - Z11
  VFNMADD213PD Z12, Z18, Z16 // Z16 = -(Z18 * Z16) + Z12
  VFNMADD213PD Z12, Z19, Z17 // Z17 = -(Z19 * Z17) + Z13
  VFNMADD231PD Z20, Z18, Z16 // Z16 = -(Z18 * Z20) + Z16
  VFNMADD231PD Z21, Z19, Z17 // Z17 = -(Z19 * Z21) + Z17
  VFMADD231PD Z14, Z18, Z6   // Z6 = (Z18 * Z14) + Z6
  VFMADD231PD Z15, Z19, Z7   // Z7 = (Z19 * Z15) + Z7
  VFMADD231PD Z16, Z10, Z6   // Z6 = (Z10 * Z16) + Z6
  VFMADD231PD Z17, Z11, Z7   // Z7 = (Z11 * Z17) + Z7
  VMULPD Z10, Z10, Z12
  VMULPD Z11, Z11, Z13
  VADDPD Z10, Z10, Z14
  VADDPD Z11, Z11, Z15
  VMOVAPD Z10, Z16
  VMOVAPD Z11, Z17
  VFMSUB213PD Z12, Z10, Z16 // Z16 = (Z10 * Z16) - Z12
  VFMSUB213PD Z13, Z11, Z17 // Z17 = (Z11 * Z17) - Z13
  VFMADD231PD Z14, Z6, Z16  // Z16 = (Z6 * Z14) + Z16
  VFMADD231PD Z15, Z7, Z17  // Z17 = (Z7 * Z15) + Z17
  VADDPD Z16, Z12, Z14
  VADDPD Z17, Z13, Z15
  VSUBPD Z14, Z12, Z12
  VSUBPD Z15, Z13, Z13
  VBROADCASTSD CONST_GET_PTR(const_atan, 8), Z18
  VBROADCASTSD CONST_GET_PTR(const_atan, 16), Z20
  VMOVAPD Z18, Z19
  VFMADD213PD Z20, Z14, Z18 // Z18 = (Z14 * Z18) + Z20
  VFMADD213PD Z20, Z15, Z19 // Z19 = (Z15 * Z19) + Z20
  VBROADCASTSD CONST_GET_PTR(const_atan, 24), Z20
  VBROADCASTSD CONST_GET_PTR(const_atan, 32), Z24
  VMOVAPD Z20, Z21
  VMULPD Z14, Z14, Z22
  VMULPD Z15, Z15, Z23
  VFMADD213PD Z24, Z14, Z20 // Z20 = (Z14 * Z20) + Z24
  VFMADD213PD Z24, Z15, Z21 // Z21 = (Z15 * Z21) + Z24
  VFMADD231PD Z18, Z22, Z20 // Z20 = (Z22 * Z18) + Z20
  VFMADD231PD Z19, Z23, Z21 // Z21 = (Z23 * Z19) + Z21
  VBROADCASTSD CONST_GET_PTR(const_atan, 40), Z18
  VBROADCASTSD CONST_GET_PTR(const_atan, 56), Z24
  VMOVAPD Z18, Z19
  VMOVAPD Z24, Z25
  VBROADCASTSD CONST_GET_PTR(const_atan, 48), Z26
  VBROADCASTSD CONST_GET_PTR(const_atan, 64), Z27
  VFMADD213PD Z26, Z14, Z18 // Z18 = (Z14 * Z18) + Z26
  VFMADD213PD Z26, Z15, Z19 // Z19 = (Z15 * Z19) + Z26
  VFMADD213PD Z27, Z14, Z24 // Z24 = (Z14 * Z24) + Z27
  VFMADD213PD Z27, Z15, Z25 // Z25 = (Z15 * Z25) + Z27
  VBROADCASTSD CONST_GET_PTR(const_atan, 72), Z26
  VBROADCASTSD CONST_GET_PTR(const_atan, 88), Z8
  VBROADCASTSD CONST_GET_PTR(const_atan, 80), Z9
  VMOVAPD Z26, Z27
  VFMADD213PD Z9, Z14, Z26 // Z26 = (Z14 * Z26) + Z9
  VFMADD213PD Z9, Z15, Z27 // Z27 = (Z15 * Z27) + Z9
  VMOVAPD Z8, Z9
  VFMADD213PD.BCST CONST_GET_PTR(const_atan, 96), Z14, Z8 // Z8 = (Z14 * Z8) + mem
  VFMADD213PD.BCST CONST_GET_PTR(const_atan, 96), Z15, Z9 // Z9 = (Z15 * Z9) + mem
  VFMADD231PD Z18, Z22, Z24 // Z24 = (Z22 * Z18) + Z24
  VFMADD231PD Z19, Z23, Z25 // Z25 = (Z23 * Z19) + Z25
  VFMADD231PD Z26, Z22, Z8  // Z8 = (Z22 * Z26) + Z8
  VFMADD231PD Z27, Z23, Z9  // Z9 = (Z23 * Z27) + Z9
  VBROADCASTSD CONST_GET_PTR(const_atan, 104), Z18
  VBROADCASTSD CONST_GET_PTR(const_atan, 120), Z26
  VBROADCASTSD CONST_GET_PTR(const_atan, 112), Z27
  VMOVAPD Z18, Z19
  VFMADD213PD Z27, Z14, Z18 // Z18 = (Z14 * Z18) + Z27
  VFMADD213PD Z27, Z15, Z19 // Z19 = (Z15 * Z19) + Z27
  VMOVAPD Z26, Z27
  VFMADD213PD.BCST CONST_GET_PTR(const_atan, 128), Z14, Z26 // Z26 = (Z14 * Z26) + mem
  VFMADD213PD.BCST CONST_GET_PTR(const_atan, 128), Z15, Z27 // Z27 = (Z15 * Z27) + mem
  VFMADD231PD Z18, Z22, Z26 // Z26 = (Z22 * Z18) + Z26
  VFMADD231PD Z19, Z23, Z27 // Z27 = (Z23 * Z19) + Z27
  VMULPD Z22, Z22, Z18
  VMULPD Z23, Z23, Z19
  VMULPD Z18, Z18, Z22
  VMULPD Z19, Z19, Z23
  VFMADD231PD Z20, Z18, Z24 // Z24 = (Z18 * Z20) + Z24
  VFMADD231PD Z21, Z19, Z25 // Z25 = (Z19 * Z21) + Z25
  VFMADD231PD Z8, Z18, Z26  // Z26 = (Z18 * Z8) + Z26
  VFMADD231PD Z9, Z19, Z27  // Z27 = (Z19 * Z9) + Z27
  VBROADCASTSD CONST_GET_PTR(const_atan, 136), Z8
  VBROADCASTSD CONST_GET_PTR(const_atan, 144), Z9
  VFMADD231PD Z24, Z22, Z26 // Z26 = (Z22 * Z24) + Z26
  VFMADD231PD Z25, Z23, Z27 // Z27 = (Z23 * Z25) + Z27
  VFMADD213PD Z8, Z14, Z26 // Z26 = (Z14 * Z26) + Z8
  VFMADD213PD Z8, Z15, Z27 // Z27 = (Z15 * Z27) + Z8
  VFMADD213PD Z9, Z14, Z26 // Z26 = (Z14 * Z26) + Z9
  VFMADD213PD Z9, Z15, Z27 // Z27 = (Z15 * Z27) + Z9
  VBROADCASTSD CONST_GET_PTR(const_atan, 152), Z8
  VBROADCASTSD CONST_GET_PTR(const_atan, 160), Z9
  VFMADD213PD Z8, Z14, Z26 // Z26 = (Z14 * Z26) + Z8
  VFMADD213PD Z8, Z15, Z27 // Z27 = (Z15 * Z27) + Z8
  VFMADD213PD Z9, Z14, Z26 // Z26 = (Z14 * Z26) + Z9
  VFMADD213PD Z9, Z15, Z27 // Z27 = (Z15 * Z27) + Z9
  VADDPD Z12, Z16, Z12
  VADDPD Z13, Z17, Z13
  VMULPD Z14, Z10, Z16
  VMULPD Z15, Z11, Z17
  VMOVAPD Z14, Z18
  VMOVAPD Z15, Z19
  VFMSUB213PD Z16, Z10, Z18 // Z18 = (Z10 * Z18) - Z16
  VFMSUB213PD Z17, Z11, Z19 // Z19 = (Z11 * Z19) - Z17
  VFMADD231PD Z14, Z6, Z18  // Z18 = (Z6 * Z14) + Z18
  VFMADD231PD Z15, Z7, Z19  // Z19 = (Z7 * Z15) + Z19
  VFMADD231PD Z12, Z10, Z18 // Z18 = (Z10 * Z12) + Z18
  VFMADD231PD Z13, Z11, Z19 // Z19 = (Z11 * Z13) + Z19
  VMULPD Z26, Z16, Z12
  VMULPD Z27, Z17, Z13
  VFMSUB213PD Z12, Z26, Z16 // Z16 = (Z26 * Z16) - Z12
  VFMSUB213PD Z13, Z27, Z17 // Z17 = (Z27 * Z17) - Z13
  VFMADD231PD Z18, Z26, Z16 // Z16 = (Z26 * Z18) + Z16
  VFMADD231PD Z19, Z27, Z17 // Z17 = (Z27 * Z19) + Z17

  VPTERNLOGD.Z $255, Z8, Z8, K3, Z8
  VPTERNLOGD.Z $255, Z9, Z9, K4, Z9
  VPSRLD $31, Y8, Y8
  VPSRLD $31, Y9, Y9

  VADDPD Z12, Z10, Z14
  VADDPD Z13, Z11, Z15
  VSUBPD Z14, Z10, Z10
  VSUBPD Z15, Z11, Z11
  VADDPD Z10, Z12, Z10
  VADDPD Z11, Z13, Z11

  VCVTDQ2PD Y8, Z8
  VCVTDQ2PD Y9, Z9
  VADDPD Z10, Z6, Z6
  VADDPD Z11, Z7, Z7

  VBROADCASTSD CONST_GET_PTR(const_atan, 168), Z10
  VBROADCASTSD CONST_GET_PTR(const_atan, 176), Z11
  VMULPD Z10, Z8, Z12
  VMULPD Z10, Z9, Z13
  VMOVAPD Z10, Z18
  VMOVAPD Z10, Z19
  VFMSUB213PD Z12, Z8, Z18 // Z18 = (Z8 * Z18) - Z12
  VFMSUB213PD Z13, Z9, Z19 // Z19 = (Z9 * Z19) - Z13
  VFMADD231PD Z11, Z8, Z18 // Z18 = (Z8 * Z11) + Z18
  VFMADD231PD Z11, Z9, Z19 // Z19 = (Z9 * Z11) + Z19
  VADDPD Z6, Z16, Z6
  VADDPD Z7, Z17, Z7
  VADDPD Z14, Z12, Z8
  VADDPD Z15, Z13, Z9
  VSUBPD Z8, Z12, Z12
  VSUBPD Z9, Z13, Z13
  VADDPD Z12, Z14, Z12
  VADDPD Z13, Z15, Z13
  VADDPD Z12, Z18, Z12
  VADDPD Z13, Z19, Z13
  VADDPD Z12, Z6, Z6
  VADDPD Z13, Z7, Z7
  VCMPPD.BCST $VCMP_IMM_EQ_OQ, CONSTF64_POSITIVE_INF(), Z4, K3
  VCMPPD.BCST $VCMP_IMM_EQ_OQ, CONSTF64_POSITIVE_INF(), Z5, K4
  VADDPD Z6, Z8, Z4
  VADDPD Z7, Z9, Z5
  VMOVAPD Z10, K3, Z4
  VMOVAPD Z10, K4, Z5
  VPTERNLOGQ.BCST $108, CONSTF64_SIGN_BIT(), Z4, K1, Z2
  VPTERNLOGQ.BCST $108, CONSTF64_SIGN_BIT(), Z5, K2, Z3

next:
  NEXT()

// Inverse tangent (two arguments): atan2(y, x)
CONST_DATA_U64(const_atan2,   0, $0x0004000000000001) // f64(5.5626846462680084E-309)
CONST_DATA_U64(const_atan2,   8, $0x4340000000000000) // f64(9007199254740992)
CONST_DATA_U64(const_atan2,  16, $0x0000000100000001) // i64(4294967297)
CONST_DATA_U64(const_atan2,  24, $0x3ee64adb3e06ee72) // f64(1.0629848419144875E-5)
CONST_DATA_U64(const_atan2,  32, $0xbf2077212aa7d6ce) // f64(-1.2562064996728687E-4)
CONST_DATA_U64(const_atan2,  40, $0x3f471ece4d9ced98) // f64(7.0557664296393412E-4)
CONST_DATA_U64(const_atan2,  48, $0xbf64a20138b90cee) // f64(-0.0025186561449871336)
CONST_DATA_U64(const_atan2,  56, $0x3f7a788ec28e9fb3) // f64(0.0064626289903699117)
CONST_DATA_U64(const_atan2,  64, $0xbf8a45a2ea379db5) // f64(-0.012828133366339903)
CONST_DATA_U64(const_atan2,  72, $0x3f954d3eccf8f320) // f64(0.02080247999241458)
CONST_DATA_U64(const_atan2,  80, $0xbf9d9805e7ba23e7) // f64(-0.028900234478474032)
CONST_DATA_U64(const_atan2,  88, $0x3fa26bc6260b1bdd) // f64(0.035978500503510459)
CONST_DATA_U64(const_atan2,  96, $0xbfa56d2d526c0577) // f64(-0.041848579703592508)
CONST_DATA_U64(const_atan2, 104, $0x3fa81b6efb51f8a6) // f64(0.047084301165328399)
CONST_DATA_U64(const_atan2, 112, $0xbfaae027d1895f2e) // f64(-0.052491421058844842)
CONST_DATA_U64(const_atan2, 120, $0x3fae1a556400767b) // f64(0.0587946590969581)
CONST_DATA_U64(const_atan2, 128, $0xbfb110c441e542d6) // f64(-0.06666208847787955)
CONST_DATA_U64(const_atan2, 136, $0x3fb3b131f3b00d10) // f64(0.076922533029620376)
CONST_DATA_U64(const_atan2, 144, $0xbfb745d0ac14efec) // f64(-0.090909044277338757)
CONST_DATA_U64(const_atan2, 152, $0x3fbc71c710b37a0b) // f64(0.11111110837689624)
CONST_DATA_U64(const_atan2, 160, $0xbfc249249211afc7) // f64(-0.14285714275626857)
CONST_DATA_U64(const_atan2, 168, $0x3fc9999999987cf0) // f64(0.19999999999797735)
CONST_DATA_U64(const_atan2, 176, $0xbfd555555555543a) // f64(-0.33333333333331761)
CONST_DATA_U64(const_atan2, 184, $0x3ff921fb54442d18) // f64(1.5707963267948966)
CONST_DATA_U64(const_atan2, 192, $0x3c91a62633145c07) // f64(6.123233995736766E-17)
CONST_DATA_U64(const_atan2, 200, $0x3fe921fb54442d18) // i64(4605249457297304856)
CONST_DATA_U64(const_atan2, 208, $0x400921fb54442d18) // i64(4614256656552045848)
CONST_DATA_U32(const_atan2, 216, $0xfffffffe) // i32(4294967294)
CONST_GLOBAL(const_atan2, $220)

TEXT bcatan2f(SB), NOSPLIT|NOFRAME, $0
  KTESTW K1, K1
  JZ next

  KSHIFTRW $8, K1, K2
  MOVWQZX 0(VIRT_PCREG), R8
  VMOVUPD 0(VIRT_VALUES)(R8*1), Z4
  VMOVUPD 64(VIRT_VALUES)(R8*1), Z5

  VXORPD X8, X8, X8
  VBROADCASTSD CONST_GET_PTR(const_atan2, 0), Z11
  VPBROADCASTQ CONSTF64_ABS_BITS(), Z12
  VBROADCASTSD CONSTF64_1(), Z24

  VANDPD Z12, Z4, Z6
  VANDPD Z12, Z5, Z7
  VCMPPD $VCMP_IMM_LT_OS, Z11, Z6, K1, K3
  VCMPPD $VCMP_IMM_LT_OS, Z11, Z7, K2, K4

  VBROADCASTSD CONST_GET_PTR(const_atan2, 8), Z7
  VMULPD Z7, Z4, K3, Z4
  VMULPD Z7, Z5, K4, Z5
  VMULPD Z7, Z2, K3, Z2
  VMULPD Z7, Z3, K4, Z3
  VANDPD Z12, Z2, Z18
  VANDPD Z12, Z3, Z19
  VANDPD Z12, Z2, Z10
  VANDPD Z12, Z3, Z11

  // K2 also used to save these two, as we need this mask at the end
  VPCMPGTQ Z4, Z8, K3
  VPCMPGTQ Z5, Z8, K4
  KUNPCKBW K3, K4, K2
  VPBROADCASTD.Z CONST_GET_PTR(const_atan2, 216), K2, Z14

  VCMPPD $VCMP_IMM_LT_OS, Z8, Z4, K3
  VCMPPD $VCMP_IMM_LT_OS, Z8, Z5, K4
  KUNPCKBW K3, K4, K3
  VBROADCASTSD CONSTF64_SIGN_BIT(), Z6
  VMOVAPD.Z Z6, K3, Z20
  VMOVAPD.Z Z6, K4, Z21
  VXORPD Z4, Z20, Z22
  VXORPD Z5, Z21, Z23
  VPBROADCASTD CONST_GET_PTR(const_atan2, 16), Z16
  VPORD Z16, Z14, Z16
  VCMPPD $VCMP_IMM_LT_OS, Z10, Z22, K3
  VCMPPD $VCMP_IMM_LT_OS, Z11, Z23, K4
  KUNPCKBW K3, K4, K3
  VMOVDQA32 Z16, K3, Z14

  VBROADCASTSD CONSTF64_POSITIVE_INF(), Z16
  VCMPPD $VCMP_IMM_EQ_OQ, Z16, Z10, K5
  VCMPPD $VCMP_IMM_EQ_OQ, Z16, Z11, K6
  KUNPCKBW K5, K6, K0

  VMOVAPD Z18, Z16
  VMOVAPD Z19, Z17
  VXORPD Z6, Z22, K3, Z16
  VXORPD Z6, Z23, K4, Z17
  VMOVAPD Z18, K3, Z22
  VMOVAPD Z19, K4, Z23
  VDIVPD Z22, Z24, Z26
  VDIVPD Z23, Z24, Z27
  VXORPD.Z Z6, Z20, K3, Z8
  VXORPD.Z Z6, Z21, K4, Z9
  VXORPD Z20, Z20, K3, Z20
  VXORPD Z21, Z21, K4, Z21
  VMULPD Z16, Z26, Z18
  VMULPD Z17, Z27, Z19
  VFMSUB213PD Z18, Z26, Z16  // Z16 = (Z26 * Z16) - Z18
  VFMSUB213PD Z19, Z27, Z17  // Z17 = (Z27 * Z17) - Z19
  VFNMADD213PD Z24, Z26, Z22 // Z22 = -(Z26 * Z22) + Z24
  VFNMADD213PD Z24, Z27, Z23 // Z23 = -(Z27 * Z23) + Z24
  VFNMADD231PD Z20, Z26, Z22 // Z22 = -(Z26 * Z20) + Z22
  VFNMADD231PD Z21, Z27, Z23 // Z23 = -(Z27 * Z21) + Z23
  VFMADD231PD Z8, Z26, Z16   // Z16 = (Z26 * Z8) + Z16
  VFMADD231PD Z9, Z27, Z17   // Z17 = (Z27 * Z9) + Z17
  VFMADD231PD Z22, Z18, Z16  // Z16 = (Z18 * Z22) + Z16
  VFMADD231PD Z23, Z19, Z17  // Z17 = (Z19 * Z23) + Z17
  VMULPD Z18, Z18, Z20
  VMULPD Z19, Z19, Z21
  VADDPD Z18, Z18, Z22
  VADDPD Z19, Z19, Z23
  VMOVAPD Z18, Z24
  VMOVAPD Z19, Z25
  VFMSUB213PD Z20, Z18, Z24 // Z24 = (Z18 * Z24) - Z20
  VFMSUB213PD Z21, Z19, Z25 // Z25 = (Z19 * Z25) - Z21
  VFMADD231PD Z22, Z16, Z24 // Z24 = (Z16 * Z22) + Z24
  VFMADD231PD Z23, Z17, Z25 // Z25 = (Z17 * Z23) + Z25
  VADDPD Z24, Z20, Z22
  VADDPD Z25, Z21, Z23
  VSUBPD Z22, Z20, Z20
  VSUBPD Z23, Z21, Z21
  VBROADCASTSD CONST_GET_PTR(const_atan2, 24), Z26
  VBROADCASTSD CONST_GET_PTR(const_atan2, 40), Z8
  VMOVAPD Z26, Z27
  VMOVAPD Z8, Z9
  VFMADD213PD.BCST CONST_GET_PTR(const_atan2, 32), Z22, Z26 // Z26 = (Z22 * Z26) + mem
  VFMADD213PD.BCST CONST_GET_PTR(const_atan2, 32), Z23, Z27 // Z27 = (Z23 * Z27) + mem
  VMULPD Z22, Z22, Z10
  VMULPD Z23, Z23, Z11
  VFMADD213PD.BCST CONST_GET_PTR(const_atan2, 48), Z22, Z8 // Z8 = (Z22 * Z8) + mem
  VFMADD213PD.BCST CONST_GET_PTR(const_atan2, 48), Z23, Z9 // Z9 = (Z23 * Z9) + mem
  VFMADD231PD Z26, Z10, Z8 // Z8 = (Z10 * Z26) + Z8
  VFMADD231PD Z27, Z11, Z9 // Z9 = (Z11 * Z27) + Z9
  VBROADCASTSD CONST_GET_PTR(const_atan2, 56), Z26
  VBROADCASTSD CONST_GET_PTR(const_atan2, 72), Z6
  VMOVAPD Z26, Z27
  VMOVAPD Z6, Z7
  VFMADD213PD.BCST CONST_GET_PTR(const_atan2, 64), Z22, Z26 // Z26 = (Z22 * Z26) + mem
  VFMADD213PD.BCST CONST_GET_PTR(const_atan2, 64), Z23, Z27 // Z27 = (Z23 * Z27) + mem
  VFMADD213PD.BCST CONST_GET_PTR(const_atan2, 80), Z22, Z6 // Z6 = (Z22 * Z6) + mem
  VFMADD213PD.BCST CONST_GET_PTR(const_atan2, 80), Z23, Z7 // Z7 = (Z23 * Z7) + mem
  VBROADCASTSD CONST_GET_PTR(const_atan2, 88), Z12
  VBROADCASTSD CONST_GET_PTR(const_atan2, 104), Z4
  VMOVAPD Z12, Z13
  VMOVAPD Z4, Z5
  VFMADD213PD.BCST CONST_GET_PTR(const_atan2, 96), Z22, Z12 // Z12 = (Z22 * Z12) + mem
  VFMADD213PD.BCST CONST_GET_PTR(const_atan2, 96), Z23, Z13 // Z13 = (Z23 * Z13) + mem
  VFMADD213PD.BCST CONST_GET_PTR(const_atan2, 112), Z22, Z4 // Z4 = (Z22 * Z4) + mem
  VFMADD213PD.BCST CONST_GET_PTR(const_atan2, 112), Z23, Z5 // Z5 = (Z23 * Z5) + mem
  VFMADD231PD Z26, Z10, Z6 // Z6 = (Z10 * Z26) + Z6
  VFMADD231PD Z27, Z11, Z7 // Z7 = (Z11 * Z27) + Z7
  VFMADD231PD Z12, Z10, Z4 // Z4 = (Z10 * Z12) + Z4
  VFMADD231PD Z13, Z11, Z5 // Z5 = (Z11 * Z13) + Z5
  VBROADCASTSD CONST_GET_PTR(const_atan2, 120), Z26
  VBROADCASTSD CONST_GET_PTR(const_atan2, 136), Z12
  VMOVAPD Z26, Z27
  VMOVAPD Z12, Z13
  VFMADD213PD.BCST CONST_GET_PTR(const_atan2, 128), Z22, Z26 // Z26 = (Z22 * Z26) + mem
  VFMADD213PD.BCST CONST_GET_PTR(const_atan2, 128), Z23, Z27 // Z27 = (Z23 * Z27) + mem
  VFMADD213PD.BCST CONST_GET_PTR(const_atan2, 144), Z22, Z12 // Z12 = (Z22 * Z12) + mem
  VFMADD213PD.BCST CONST_GET_PTR(const_atan2, 144), Z23, Z13 // Z13 = (Z23 * Z13) + mem
  VFMADD231PD Z26, Z10, Z12 // Z12 = (Z10 * Z26) + Z12
  VFMADD231PD Z27, Z11, Z13 // Z13 = (Z11 * Z27) + Z13
  VMULPD Z10, Z10, Z26
  VMULPD Z11, Z11, Z27
  VFMADD231PD Z8, Z26, Z6 // Z6 = (Z26 * Z8) + Z6
  VFMADD231PD Z9, Z27, Z7 // Z7 = (Z27 * Z9) + Z7
  VMULPD Z26, Z26, Z8
  VMULPD Z27, Z27, Z9
  VFMADD231PD Z4, Z26, Z12 // Z12 = (Z26 * Z4) + Z12
  VFMADD231PD Z5, Z27, Z13 // Z13 = (Z27 * Z5) + Z13
  VFMADD231PD Z6, Z8, Z12  // Z12 = (Z8 * Z6) + Z12
  VFMADD231PD Z7, Z9, Z13  // Z13 = (Z9 * Z7) + Z13
  VBROADCASTSD CONST_GET_PTR(const_atan2, 152), Z26
  VBROADCASTSD CONST_GET_PTR(const_atan2, 160), Z27
  VFMADD213PD Z26, Z22, Z12 // Z12 = (Z22 * Z12) + Z26
  VFMADD213PD Z26, Z23, Z13 // Z13 = (Z23 * Z13) + Z26
  VFMADD213PD Z27, Z22, Z12 // Z12 = (Z22 * Z12) + Z27
  VFMADD213PD Z27, Z23, Z13 // Z13 = (Z23 * Z13) + Z27
  VBROADCASTSD CONST_GET_PTR(const_atan2, 168), Z26
  VBROADCASTSD CONST_GET_PTR(const_atan2, 176), Z27
  VFMADD213PD Z26, Z22, Z12 // Z12 = (Z22 * Z12) + Z26
  VFMADD213PD Z26, Z23, Z13 // Z13 = (Z23 * Z13) + Z26
  VFMADD213PD Z27, Z22, Z12 // Z12 = (Z22 * Z12) + Z27
  VFMADD213PD Z27, Z23, Z13 // Z13 = (Z23 * Z13) + Z27
  VADDPD Z20, Z24, Z20
  VADDPD Z21, Z25, Z21
  VMULPD Z22, Z18, Z24
  VMULPD Z23, Z19, Z25
  VMOVAPD Z22, Z26
  VMOVAPD Z23, Z27
  VFMSUB213PD Z24, Z18, Z26 // Z26 = (Z18 * Z26) - Z24
  VFMSUB213PD Z25, Z19, Z27 // Z27 = (Z19 * Z27) - Z25
  VFMADD231PD Z22, Z16, Z26 // Z26 = (Z16 * Z22) + Z26
  VFMADD231PD Z23, Z17, Z27 // Z27 = (Z17 * Z23) + Z27
  VFMADD231PD Z20, Z18, Z26 // Z26 = (Z18 * Z20) + Z26
  VFMADD231PD Z21, Z19, Z27 // Z27 = (Z19 * Z21) + Z27
  VMULPD Z12, Z24, Z20
  VMULPD Z13, Z25, Z21
  VFMSUB213PD Z20, Z12, Z24 // Z24 = (Z12 * Z24) - Z20
  VFMSUB213PD Z21, Z13, Z25 // Z25 = (Z13 * Z25) - Z21
  VFMADD231PD Z26, Z12, Z24 // Z24 = (Z12 * Z26) + Z24
  VFMADD231PD Z27, Z13, Z25 // Z25 = (Z13 * Z27) + Z25
  VADDPD Z20, Z18, Z22
  VADDPD Z21, Z19, Z23
  VSUBPD Z22, Z18, Z18
  VSUBPD Z23, Z19, Z19
  VADDPD Z18, Z20, Z18
  VADDPD Z19, Z21, Z19
  VEXTRACTI32X8 $1, Z14, Y15
  VCVTDQ2PD Y14, Z14
  VCVTDQ2PD Y15, Z15
  VADDPD Z18, Z16, Z16
  VADDPD Z19, Z17, Z17
  VBROADCASTSD CONST_GET_PTR(const_atan2, 184), Z18
  VBROADCASTSD CONST_GET_PTR(const_atan2, 184), Z19
  VMULPD Z18, Z14, Z20
  VMULPD Z19, Z15, Z21
  VMOVAPD Z18, Z26
  VMOVAPD Z19, Z27
  VBROADCASTSD CONST_GET_PTR(const_atan2, 192), Z4
  VFMSUB213PD Z20, Z14, Z26 // Z26 = (Z14 * Z26) - Z20
  VFMSUB213PD Z21, Z15, Z27 // Z27 = (Z15 * Z27) - Z21
  VFMADD231PD Z4, Z14, Z26  // Z26 = (Z14 * Z4) + Z26
  VFMADD231PD Z4, Z15, Z27  // Z27 = (Z15 * Z4) + Z27
  VADDPD Z16, Z24, Z14
  VADDPD Z17, Z25, Z15
  VADDPD Z22, Z20, Z16
  VADDPD Z23, Z21, Z17
  VSUBPD Z16, Z20, Z20
  VSUBPD Z17, Z21, Z21
  VADDPD Z20, Z22, Z20
  VADDPD Z21, Z23, Z21
  VADDPD Z20, Z26, Z20
  VADDPD Z21, Z27, Z21
  VADDPD Z20, Z14, Z14
  VADDPD Z21, Z15, Z15
  VADDPD Z14, Z16, Z14
  VADDPD Z15, Z17, Z15

  // NOTE: Z4/Z5 have to be reloaded as they were clobbered
  VMOVUPD 0(VIRT_VALUES)(R8*1), Z4
  VMOVUPD 64(VIRT_VALUES)(R8*1), Z5
  VBROADCASTSD CONSTF64_SIGN_BIT(), Z6
  VXORPD X8, X8, X8

  VANDPD Z6, Z4, Z16
  VANDPD Z6, Z5, Z17
  VXORPD Z14, Z16, Z14
  VXORPD Z15, Z17, Z15

  VBROADCASTSD CONSTF64_ABS_BITS(), Z13
  VBROADCASTSD CONSTF64_POSITIVE_INF(), Z20
  VANDPD Z13, Z4, Z12
  VANDPD Z13, Z5, Z13
  VCMPPD $VCMP_IMM_EQ_OQ, Z20, Z12, K3
  VCMPPD $VCMP_IMM_EQ_OQ, Z20, Z13, K4
  VCMPPD $VCMP_IMM_EQ_OQ, Z8, Z4, K5
  VCMPPD $VCMP_IMM_EQ_OQ, Z8, Z5, K6
  VORPD.BCST CONST_GET_PTR(const_atan2, 184), Z16, Z12
  VORPD.BCST CONST_GET_PTR(const_atan2, 184), Z17, Z13
  KORW K3, K5, K5
  KORW K4, K6, K6
  VMOVAPD Z18, Z22
  VMOVAPD Z19, Z23
  VSUBPD Z12, Z18, K3, Z22
  VSUBPD Z13, Z19, K4, Z23
  VMOVAPD Z22, K5, Z14
  VMOVAPD Z23, K6, Z15

  VORPD.BCST CONST_GET_PTR(const_atan2, 200), Z16, Z10
  VORPD.BCST CONST_GET_PTR(const_atan2, 200), Z17, Z11
  VSUBPD Z10, Z18, K3, Z18
  VSUBPD Z11, Z19, K4, Z19

  KMOVB K0, K3
  KSHIFTRW $8, K0, K4
  VMOVAPD Z18, K3, Z14
  VMOVAPD Z19, K4, Z15
  VCMPPD $VCMP_IMM_EQ_OQ, Z8, Z2, K3
  VCMPPD $VCMP_IMM_EQ_OQ, Z8, Z3, K4
  KSHIFTRW $8, K2, K6
  VPBROADCASTQ.Z CONST_GET_PTR(const_atan2, 208), K2, Z8
  VPBROADCASTQ.Z CONST_GET_PTR(const_atan2, 208), K6, Z9
  VCMPPD $VCMP_IMM_UNORD_Q, Z4, Z2, K2
  VCMPPD $VCMP_IMM_UNORD_Q, Z5, Z3, K6
  VMOVAPD Z8, K3, Z14
  VMOVAPD Z9, K4, Z15
  KSHIFTRW $8, K1, K3
  VPTERNLOGQ $108, Z6, Z14, K1, Z2
  VPTERNLOGQ $108, Z6, Z15, K3, Z3
  VPTERNLOGD $255, Z4, Z4, Z4
  VMOVAPD Z4, K2, Z2
  VMOVAPD Z4, K6, Z3

next:
  NEXT_ADVANCE(2)

// Hypot: hypot(x, y)
CONST_DATA_U64(const_hypot, 0, $0x0010000000000000) // f64(2.2250738585072014E-308)
CONST_DATA_U64(const_hypot, 8, $0x4350000000000000) // f64(18014398509481984)
CONST_GLOBAL(const_hypot, $16)

TEXT bchypotf(SB), NOSPLIT|NOFRAME, $0
  KTESTW K1, K1
  JZ next

  KSHIFTRW $8, K1, K2
  MOVWQZX 0(VIRT_PCREG), R8
  VMOVUPD 0(VIRT_VALUES)(R8*1), Z4
  VMOVUPD 64(VIRT_VALUES)(R8*1), Z5

  VBROADCASTSD CONSTF64_ABS_BITS(), Z8
  VBROADCASTSD CONST_GET_PTR(const_hypot, 0), Z10
  VBROADCASTSD CONST_GET_PTR(const_hypot, 8), Z11
  VANDPD Z8, Z2, Z6
  VANDPD Z8, Z3, Z7
  VANDPD Z8, Z4, Z4
  VANDPD Z8, Z5, Z5
  VMAXPD Z4, Z6, Z8
  VMAXPD Z5, Z7, Z9
  VCMPPD $VCMP_IMM_LT_OS, Z10, Z8, K1, K3
  VCMPPD $VCMP_IMM_LT_OS, Z10, Z9, K2, K4
  VBROADCASTSD CONSTF64_1(), Z14
  VMOVAPD Z8, Z12
  VMOVAPD Z9, Z13
  VMOVAPD Z14, K1, Z2
  VMOVAPD Z14, K2, Z3
  VMULPD Z11, Z8, K3, Z12
  VMULPD Z11, Z9, K4, Z13
  VDIVPD Z12, Z2, Z14
  VDIVPD Z13, Z3, Z15
  VMINPD Z4, Z6, Z16
  VMINPD Z5, Z7, Z17
  VMOVAPD Z16, Z18
  VMOVAPD Z17, Z19
  VMULPD Z11, Z16, K3, Z18
  VMULPD Z11, Z17, K4, Z19
  VMULPD Z14, Z18, Z20
  VMULPD Z15, Z19, Z21
  VFMSUB213PD Z20, Z14, Z18 // Z18 = (Z14 * Z18) - Z20
  VFMSUB213PD Z21, Z15, Z19 // Z19 = (Z15 * Z19) - Z21
  VFNMADD213PD Z2, Z14, Z12 // Z12 = -(Z14 * Z12) + Z2
  VFNMADD213PD Z3, Z15, Z13 // Z13 = -(Z15 * Z13) + Z3
  VXORPD X10, X10, X10
  VXORPD X11, X11, X11
  VFNMADD231PD Z11, Z14, Z12 // Z12 = -(Z14 * Z11) + Z12
  VFNMADD231PD Z11, Z15, Z13 // Z13 = -(Z15 * Z11) + Z13
  VFMADD231PD Z14, Z11, Z18  // Z18 = (Z11 * Z14) + Z18
  VFMADD231PD Z15, Z11, Z19  // Z19 = (Z11 * Z15) + Z19
  VFMADD231PD Z12, Z20, Z18  // Z18 = (Z20 * Z12) + Z18
  VFMADD231PD Z13, Z21, Z19  // Z19 = (Z21 * Z13) + Z19
  VMULPD Z20, Z20, Z12
  VMULPD Z21, Z21, Z13
  VADDPD Z20, Z20, Z14
  VADDPD Z21, Z21, Z15
  VFMSUB213PD Z12, Z20, Z20 // Z20 = (Z20 * Z20) - Z12
  VFMSUB213PD Z13, Z21, Z21 // Z21 = (Z21 * Z21) - Z13
  VFMADD231PD Z14, Z18, Z20 // Z20 = (Z18 * Z14) + Z20
  VFMADD231PD Z15, Z19, Z21 // Z21 = (Z19 * Z15) + Z21
  VADDPD Z2, Z12, Z14
  VADDPD Z3, Z13, Z15
  VSUBPD Z12, Z14, Z18
  VSUBPD Z13, Z15, Z19
  VSUBPD Z18, Z14, Z22
  VSUBPD Z19, Z15, Z23
  VSUBPD Z22, Z12, Z12
  VSUBPD Z23, Z13, Z13
  VSUBPD Z18, Z2, Z18
  VSUBPD Z19, Z3, Z19
  VADDPD Z12, Z18, Z12
  VADDPD Z13, Z19, Z13
  VADDPD Z12, Z20, Z12
  VADDPD Z13, Z21, Z13
  VADDPD Z12, Z14, Z18
  VADDPD Z13, Z15, Z19
  VSQRTPD Z18, Z18
  VSQRTPD Z19, Z19
  VCMPPD $VCMP_IMM_EQ_OQ, Z11, Z16, K1, K3
  VCMPPD $VCMP_IMM_EQ_OQ, Z11, Z17, K2, K4
  VMULPD Z18, Z18, Z16
  VMULPD Z19, Z19, Z17
  VMOVAPD Z18, Z20
  VMOVAPD Z19, Z21
  VFMSUB213PD Z16, Z18, Z20 // Z20 = (Z18 * Z20) - Z16
  VFMSUB213PD Z17, Z19, Z21 // Z21 = (Z19 * Z21) - Z17
  VADDPD Z16, Z14, Z22
  VADDPD Z17, Z15, Z23
  VSUBPD Z14, Z22, Z24
  VSUBPD Z15, Z23, Z25
  VSUBPD Z24, Z22, Z26
  VSUBPD Z25, Z23, Z27
  VSUBPD Z26, Z14, Z14
  VSUBPD Z27, Z15, Z15
  VSUBPD Z24, Z16, Z16
  VSUBPD Z25, Z17, Z17
  VADDPD Z14, Z16, Z14
  VADDPD Z15, Z17, Z15
  VDIVPD Z18, Z2, Z16
  VDIVPD Z19, Z3, Z17
  VADDPD Z20, Z12, Z12
  VADDPD Z21, Z13, Z13
  VADDPD Z14, Z12, Z12
  VADDPD Z15, Z13, Z13
  VFNMADD213PD Z2, Z16, Z18 // Z18 = -(Z16 * Z18) + Z2
  VFNMADD213PD Z3, Z17, Z19 // Z19 = -(Z17 * Z19) + Z3
  VMULPD Z18, Z16, Z2
  VMULPD Z19, Z17, Z3
  VMULPD Z22, Z16, Z14
  VMULPD Z23, Z17, Z15
  VMOVAPD Z16, Z18
  VMOVAPD Z17, Z19
  VBROADCASTSD CONSTF64_HALF(), Z20
  VFMSUB213PD Z14, Z22, Z18 // Z18 = (Z22 * Z18) - Z14
  VFMSUB213PD Z15, Z23, Z19 // Z19 = (Z23 * Z19) - Z15
  VFMADD231PD Z12, Z16, Z18 // Z18 = (Z16 * Z12) + Z18
  VFMADD231PD Z13, Z17, Z19 // Z19 = (Z17 * Z13) + Z19
  VFMADD231PD Z2, Z22, Z18  // Z18 = (Z22 * Z2) + Z18
  VFMADD231PD Z3, Z23, Z19  // Z19 = (Z23 * Z3) + Z19

  VMOVAPD Z20, K1, Z2
  VMOVAPD Z20, K2, Z3
  VMULPD Z2, Z14, Z12
  VMULPD Z3, Z15, Z13
  VMULPD Z2, Z18, K1, Z2
  VMULPD Z3, Z19, K2, Z3
  VMULPD Z12, Z8, Z14
  VMULPD Z13, Z9, Z15
  VFMSUB213PD Z14, Z8, Z12 // Z12 = (Z8 * Z12) - Z14
  VFMSUB213PD Z15, Z9, Z13 // Z13 = (Z9 * Z13) - Z15
  VFMADD231PD Z2, Z8, Z12  // Z12 = (Z8 * Z2) + Z12
  VFMADD231PD Z3, Z9, Z13  // Z13 = (Z9 * Z3) + Z13
  VADDPD Z12, Z14, K1, Z2
  VADDPD Z13, Z15, K2, Z3
  VCMPPD $VCMP_IMM_UNORD_Q, Z11, Z2, K1, K5
  VCMPPD $VCMP_IMM_UNORD_Q, Z11, Z3, K2, K6
  VBROADCASTSD CONSTF64_POSITIVE_INF(), Z10
  VBROADCASTSD CONSTF64_POSITIVE_INF(), Z11
  VMOVAPD Z10, K5, Z2
  VMOVAPD Z11, K6, Z3
  VMOVAPD Z8, K3, Z2
  VMOVAPD Z9, K4, Z3
  VCMPPD $VCMP_IMM_UNORD_Q, Z6, Z4, K1, K3
  VCMPPD $VCMP_IMM_UNORD_Q, Z7, Z5, K2, K4
  VBROADCASTSD CONSTF64_NAN(), K3, Z2
  VBROADCASTSD CONSTF64_NAN(), K4, Z3
  VCMPPD $VCMP_IMM_EQ_OQ, Z10, Z6, K1, K3
  VCMPPD $VCMP_IMM_EQ_OQ, Z11, Z7, K2, K4
  VCMPPD $VCMP_IMM_EQ_OQ, Z10, Z4, K1, K5
  VCMPPD $VCMP_IMM_EQ_OQ, Z11, Z5, K2, K6
  KORW K5, K3, K3
  KORW K6, K4, K4
  VMOVAPD Z10, K3, Z2
  VMOVAPD Z11, K4, Z3

next:
  NEXT_ADVANCE(2)

// Power: pow(x, y)
CONST_DATA_U64(const_pow,   0, $0x3ff5555555555555) // f64(1.3333333333333333)
CONST_DATA_U64(const_pow,   8, $0x4090000000000000) // f64(1024)
CONST_DATA_U64(const_pow,  16, $0xbff0000000000000) // f64(-1)
CONST_DATA_U64(const_pow,  24, $0x3fba6dea6d1e9d11) // f64(0.10323968090107295)
CONST_DATA_U64(const_pow,  32, $0x3fbe252ddf5f8d0a) // f64(0.117754809412464)
CONST_DATA_U64(const_pow,  40, $0x3fc110f384a1865c) // f64(0.13332981086846274)
CONST_DATA_U64(const_pow,  48, $0x3fc3b13bb108efd1) // f64(0.15384622711451226)
CONST_DATA_U64(const_pow,  56, $0x3fc745d17248daf1) // f64(0.18181818085005078)
CONST_DATA_U64(const_pow,  64, $0x3fcc71c71c76197f) // f64(0.22222222223008356)
CONST_DATA_U64(const_pow,  72, $0x3fd2492492492200) // f64(0.28571428571424917)
CONST_DATA_U64(const_pow,  80, $0x3fd999999999999b) // f64(0.40000000000000008)
CONST_DATA_U64(const_pow,  88, $0x3fbdc2ec09e714d3) // f64(0.11625552407993504)
CONST_DATA_U64(const_pow,  96, $0x3fe62e42fefa39ef) // f64(0.69314718055994529)
CONST_DATA_U64(const_pow, 104, $0x3c7abc9e3b39803f) // f64(2.3190468138462996E-17)
CONST_DATA_U64(const_pow, 112, $0x3fe5555555555555) // f64(0.66666666666666663)
CONST_DATA_U64(const_pow, 120, $0x3c85f00000000000) // f64(3.8055496254241206E-17)
CONST_DATA_U64(const_pow, 128, $0x3ff71547652b82fe) // f64(1.4426950408889634)
CONST_DATA_U64(const_pow, 136, $0xbfe62e42fefa3000) // f64(-0.69314718055966296)
CONST_DATA_U64(const_pow, 144, $0xbd53de6af278ece6) // f64(-2.8235290563031577E-13)
CONST_DATA_U64(const_pow, 152, $0x3e5af559d51456b9) // f64(2.5106968342095042E-8)
CONST_DATA_U64(const_pow, 160, $0x3e928a8f696db5ad) // f64(2.7628616677027065E-7)
CONST_DATA_U64(const_pow, 168, $0x3ec71ddfd27d265e) // f64(2.7557249672502357E-6)
CONST_DATA_U64(const_pow, 176, $0x3efa0199ec6c491b) // f64(2.4801497398981979E-5)
CONST_DATA_U64(const_pow, 184, $0x3f2a01a01ae0c33d) // f64(1.984126988090698E-4)
CONST_DATA_U64(const_pow, 192, $0x3f56c16c1828ec7b) // f64(0.0013888888939977129)
CONST_DATA_U64(const_pow, 200, $0x3f8111111110fb68) // f64(0.0083333333333237141)
CONST_DATA_U64(const_pow, 208, $0x3fa5555555550e90) // f64(0.041666666666540952)
CONST_DATA_U64(const_pow, 216, $0x3fc5555555555558) // f64(0.16666666666666674)
CONST_DATA_U64(const_pow, 224, $0x3fe0000000000009) // f64(0.500000000000001)
CONST_DATA_U64(const_pow, 232, $0xc08f400000000000) // f64(-1000)
CONST_DATA_U64(const_pow, 240, $0x40862e42fe102c83) // f64(709.78271114955749)
CONST_DATA_U32(const_pow, 248, $0x3ff00000) // i32(1072693248)
CONST_GLOBAL(const_pow, $252)

TEXT bcpowf(SB), NOSPLIT|NOFRAME, $0
  KTESTW K1, K1
  JZ next

  MOVL $0xAAAA, R8
  KMOVW R8, K6
  MOVWQZX 0(VIRT_PCREG), R8

  // Process Z2 (first 8 lanes).
  VXORPD X6, X6, X6
  VMOVUPD 0(VIRT_VALUES)(R8*1), Z4
  VRNDSCALEPD $8, Z4, Z5
  VCMPPD $VCMP_IMM_EQ_OQ, Z4, Z5, K3
  VMULPD.BCST CONSTF64_HALF(), Z4, Z5
  VPBROADCASTQ CONSTF64_ABS_BITS(), Z10
  VRNDSCALEPD $8, Z5, Z7
  VPANDQ Z10, Z2, Z8
  VMULPD.BCST CONST_GET_PTR(const_pow, 0), Z8, Z9
  VCMPPD $VCMP_IMM_NEQ_UQ, Z5, Z7, K3, K2
  VGETEXPPD Z9, Z13
  VBROADCASTSD CONSTF64_POSITIVE_INF(), Z9
  VCMPPD $VCMP_IMM_EQ_OQ, Z9, Z13, K4
  VBROADCASTSD CONST_GET_PTR(const_pow, 8), K4, Z13
  VGETMANTPD $11, Z8, Z12
  VBROADCASTSD CONST_GET_PTR(const_pow, 16), Z11
  VBROADCASTSD CONSTF64_1(), Z7
  VADDPD Z11, Z12, Z5
  VADDPD Z7, Z5, Z14
  VSUBPD Z14, Z5, Z15
  VSUBPD Z15, Z11, Z15
  VSUBPD Z14, Z12, Z14
  VADDPD Z15, Z14, Z14
  VADDPD Z7, Z12, Z15
  VADDPD Z11, Z15, Z16
  VSUBPD Z16, Z15, Z17
  VSUBPD Z17, Z7, Z17
  VSUBPD Z16, Z12, Z12
  VADDPD Z17, Z12, Z12
  VDIVPD Z15, Z7, Z16
  VMULPD Z16, Z5, Z17
  VFMSUB213PD Z17, Z16, Z5   // Z5 = (Z16 * Z5) - Z17
  VFNMADD213PD Z7, Z16, Z15  // Z15 = -(Z16 * Z15) + Z7
  VFNMADD231PD Z12, Z16, Z15 // Z15 = -(Z16 * Z12) + Z15
  VFMADD231PD Z14, Z16, Z5   // Z5 = (Z16 * Z14) + Z5
  VFMADD231PD Z15, Z17, Z5   // Z5 = (Z17 * Z15) + Z5
  VMULPD Z17, Z17, Z12
  VADDPD Z17, Z17, Z14
  VMOVAPD Z17, Z15
  VFMSUB213PD Z12, Z17, Z15  // Z15 = (Z17 * Z15) - Z12
  VMULPD Z12, Z12, Z16
  VMULPD Z16, Z16, Z18
  VBROADCASTSD CONST_GET_PTR(const_pow, 24), Z19
  VFMADD213PD.BCST CONST_GET_PTR(const_pow, 32), Z12, Z19 // Z19 = (Z12 * Z19) + mem
  VBROADCASTSD CONST_GET_PTR(const_pow, 40), Z20
  VMULPD Z18, Z18, Z21
  VFMADD213PD.BCST CONST_GET_PTR(const_pow, 48), Z12, Z20 // Z20 = (Z12 * Z20) + mem
  VFMADD231PD Z19, Z16, Z20  // Z20 = (Z16 * Z19) + Z20
  VBROADCASTSD CONST_GET_PTR(const_pow, 56), Z19
  VFMADD213PD.BCST CONST_GET_PTR(const_pow, 64), Z12, Z19 // Z19 = (Z12 * Z19) + mem
  VBROADCASTSD CONST_GET_PTR(const_pow, 72), Z22
  VFMADD213PD.BCST CONST_GET_PTR(const_pow, 80), Z12, Z22 // Z22 = (Z12 * Z22) + mem
  VFMADD231PD Z19, Z16, Z22  // Z22 = (Z16 * Z19) + Z22
  VFMADD231PD Z20, Z18, Z22  // Z22 = (Z18 * Z20) + Z22
  VFMADD231PD.BCST CONST_GET_PTR(const_pow, 88), Z21, Z22 // Z22 = (Z21 * mem) + Z22
  VFMADD231PD Z5, Z14, Z15   // Z15 = (Z14 * Z5) + Z15
  VBROADCASTSD CONST_GET_PTR(const_pow, 96), Z16
  VMULPD Z16, Z13, Z18
  VFMSUB213PD Z18, Z13, Z16  // Z16 = (Z13 * Z16) - Z18
  VFMADD231PD.BCST CONST_GET_PTR(const_pow, 104), Z13, Z16 // Z16 = (Z13 * mem) + Z16
  VADDPD Z5, Z5, Z13
  VADDPD Z14, Z18, Z19
  VSUBPD Z19, Z18, Z18
  VADDPD Z18, Z14, Z14
  VADDPD Z14, Z16, Z14
  VADDPD Z13, Z14, Z13
  VMULPD Z12, Z17, Z14
  VMOVAPD Z17, Z16
  VFMSUB213PD Z14, Z12, Z16  // Z16 = (Z12 * Z16) - Z14
  VFMADD231PD Z17, Z15, Z16  // Z16 = (Z15 * Z17) + Z16
  VFMADD231PD Z5, Z12, Z16   // Z16 = (Z12 * Z5) + Z16
  VBROADCASTSD CONST_GET_PTR(const_pow, 112), Z5
  VMULPD Z5, Z14, Z17
  VMOVAPD Z5, Z18
  VFMSUB213PD Z17, Z14, Z18  // Z18 = (Z14 * Z18) - Z17
  VFMADD231PD Z5, Z16, Z18   // Z18 = (Z16 * Z5) + Z18
  VFMADD231PD.BCST CONST_GET_PTR(const_pow, 120), Z14, Z18 // Z18 = (Z14 * mem) + Z18
  VADDPD Z17, Z19, Z5
  VSUBPD Z5, Z19, Z19
  VADDPD Z19, Z17, Z17
  VADDPD Z17, Z13, Z13
  VADDPD Z18, Z13, Z13
  VMULPD Z14, Z12, Z17
  VMOVAPD Z14, Z18
  VFMSUB213PD Z17, Z12, Z18  // Z18 = (Z12 * Z18) - Z17
  VFMADD231PD Z15, Z14, Z18  // Z18 = (Z14 * Z15) + Z18
  VFMADD231PD Z16, Z12, Z18  // Z18 = (Z12 * Z16) + Z18
  VMULPD Z22, Z17, Z12
  VFMSUB213PD Z12, Z22, Z17  // Z17 = (Z22 * Z17) - Z12
  VFMADD231PD Z18, Z22, Z17  // Z17 = (Z22 * Z18) + Z17
  VADDPD Z12, Z5, Z14
  VSUBPD Z14, Z5, Z5
  VADDPD Z5, Z12, Z5
  VADDPD Z13, Z5, Z5
  VADDPD Z5, Z17, Z12
  VMULPD Z4, Z14, Z5
  VFMSUB213PD Z5, Z4, Z14    // Z14 = (Z4 * Z14) - Z5
  VFMADD231PD Z12, Z4, Z14   // Z14 = (Z4 * Z12) + Z14
  VADDPD Z14, Z5, Z12
  VMULPD.BCST CONST_GET_PTR(const_pow, 128), Z12, Z12
  VRNDSCALEPD $8, Z12, Z13
  VCVTPD2DQ.RN_SAE Z13, Y12
  VMULPD.BCST CONST_GET_PTR(const_pow, 136), Z13, Z15
  VADDPD Z5, Z15, Z16
  VSUBPD Z5, Z16, Z17
  VSUBPD Z17, Z16, Z18
  VSUBPD Z18, Z5, Z18
  VSUBPD Z17, Z15, Z15
  VADDPD Z18, Z15, Z15
  VMULPD.BCST CONST_GET_PTR(const_pow, 144), Z13, Z13
  VADDPD Z14, Z15, Z14
  VADDPD Z16, Z13, Z15
  VSUBPD Z16, Z15, Z17
  VSUBPD Z17, Z15, Z18
  VSUBPD Z18, Z16, Z16
  VSUBPD Z17, Z13, Z13
  VADDPD Z16, Z13, Z13
  VADDPD Z14, Z13, Z13
  VADDPD Z13, Z15, Z14
  VSUBPD Z14, Z15, Z15
  VADDPD Z15, Z13, Z13
  VMULPD Z14, Z14, Z15
  VMULPD Z15, Z15, Z16
  VMULPD Z16, Z16, Z17
  VBROADCASTSD CONST_GET_PTR(const_pow, 152), Z18
  VBROADCASTSD CONST_GET_PTR(const_pow, 168), Z19
  VFMADD213PD.BCST CONST_GET_PTR(const_pow, 160), Z14, Z18 // Z18 = (Z14 * Z18) + mem
  VFMADD213PD.BCST CONST_GET_PTR(const_pow, 176), Z14, Z19 // Z19 = (Z14 * Z19) + mem
  VBROADCASTSD CONST_GET_PTR(const_pow, 184), Z20
  VBROADCASTSD CONST_GET_PTR(const_pow, 200), Z21
  VFMADD213PD.BCST CONST_GET_PTR(const_pow, 192), Z14, Z20 // Z20 = (Z14 * Z20) + mem
  VFMADD213PD.BCST CONST_GET_PTR(const_pow, 208), Z14, Z21 // Z21 = (Z14 * Z21) + mem
  VBROADCASTSD CONST_GET_PTR(const_pow, 216), Z22
  VFMADD231PD Z19, Z15, Z20  // Z20 = (Z15 * Z19) + Z20
  VFMADD213PD.BCST CONST_GET_PTR(const_pow, 224), Z14, Z22 // Z22 = (Z14 * Z22) + mem
  VFMADD231PD Z21, Z15, Z22  // Z22 = (Z15 * Z21) + Z22
  VFMADD231PD Z20, Z16, Z22  // Z22 = (Z16 * Z20) + Z22
  VFMADD231PD Z18, Z17, Z22  // Z22 = (Z17 * Z18) + Z22
  VADDPD Z7, Z14, Z16
  VSUBPD Z16, Z7, Z17
  VADDPD Z17, Z14, Z17
  VADDPD Z17, Z13, Z17
  VADDPD Z14, Z14, Z18
  VFMSUB213PD Z15, Z14, Z14  // Z14 = (Z14 * Z14) - Z15
  VFMADD231PD Z18, Z13, Z14  // Z14 = (Z13 * Z18) + Z14
  VMULPD Z22, Z15, Z13
  VFMSUB213PD Z13, Z22, Z15  // Z15 = (Z22 * Z15) - Z13
  VFMADD231PD Z14, Z22, Z15  // Z15 = (Z22 * Z14) + Z15
  VADDPD Z13, Z16, Z14
  VSUBPD Z14, Z16, Z16
  VADDPD Z16, Z13, Z13
  VADDPD Z13, Z17, Z13
  VADDPD Z13, Z15, Z13
  VADDPD Z13, Z14, Z13
  VPSRAD $1, Y12, Y14
  VPSLLD $20, Y14, Y15
  VPBROADCASTD CONST_GET_PTR(const_pow, 248), Y16
  VPADDD Y16, Y15, Y15
  VPEXPANDD.Z Z15, K6, Z15
  VMULPD Z15, Z13, Z13
  VPSUBD Y14, Y12, Y12
  VPSLLD $20, Y12, Y12
  VPADDD Y16, Y12, Y12
  VPEXPANDD.Z Z12, K6, Z12
  VCMPPD.BCST $VCMP_IMM_NLT_US, CONST_GET_PTR(const_pow, 232), Z5, K4
  VMULPD.Z Z12, Z13, K4, Z12
  VCMPPD.BCST $VCMP_IMM_GT_OS, CONST_GET_PTR(const_pow, 240), Z5, K4
  VMOVAPD Z9, K4, Z12
  VBLENDMPD Z11, Z7, K2, Z5
  VBROADCASTSD CONSTF64_NAN(), Z13
  VCMPPD $VCMP_IMM_LT_OS, Z2, Z6, K4
  VMOVAPD Z5, K3, Z13
  VMOVAPD Z7, K4, Z13
  VMULPD Z12, Z13, Z5
  VADDPD Z11, Z8, Z11
  VPBROADCASTQ CONSTF64_SIGN_BIT(), Z12
  VPTERNLOGQ $120, Z12, Z4, Z11
  VPANDQ Z10, Z4, Z10
  VCMPPD $VCMP_IMM_EQ_OQ, Z9, Z10, K3
  VCMPPD $VCMP_IMM_NLT_US, Z6, Z11, K4
  VCMPPD $VCMP_IMM_EQ_OQ, Z6, Z11, K5
  VBLENDMPD Z7, Z9, K5, Z10
  VMOVAPD.Z Z10, K4, Z10
  VMOVAPD Z10, K3, Z5
  VCMPPD $VCMP_IMM_EQ_OQ, Z9, Z8, K0
  VCMPPD $VCMP_IMM_EQ_OQ, Z6, Z2, K3
  KORW K3, K0, K4
  VPCMPGTQ Z4, Z6, K0
  KXNORW K3, K0, K3
  VPBROADCASTQ.Z CONSTF64_POSITIVE_INF(), K3, Z8
  VPANDQ.Z Z12, Z2, K2, Z9
  VCMPPD $VCMP_IMM_UNORD_Q, Z2, Z4, K2
  VPORQ Z8, Z9, K4, Z5
  VPTERNLOGD $255, Z8, Z8, Z8
  VMOVAPD Z8, K2, Z5
  VCMPPD $VCMP_IMM_EQ_OQ, Z6, Z4, K0
  VCMPPD $VCMP_IMM_EQ_OQ, Z7, Z2, K2
  KORW K2, K0, K2
  VMOVAPD Z7, K2, Z5
  VMOVAPD Z5, Z2

  // Process Z3 (remaining 8 lanes).
  VXORPD X6, X6, X6
  VMOVUPD 64(VIRT_VALUES)(R8*1), Z4
  VRNDSCALEPD $8, Z4, Z5
  VCMPPD $VCMP_IMM_EQ_OQ, Z4, Z5, K3
  VMULPD.BCST CONSTF64_HALF(), Z4, Z5
  VPBROADCASTQ CONSTF64_ABS_BITS(), Z10
  VRNDSCALEPD $8, Z5, Z7
  VPANDQ Z10, Z3, Z8
  VMULPD.BCST CONST_GET_PTR(const_pow, 0), Z8, Z9
  VCMPPD $VCMP_IMM_NEQ_UQ, Z5, Z7, K3, K2
  VGETEXPPD Z9, Z13
  VBROADCASTSD CONSTF64_POSITIVE_INF(), Z9
  VCMPPD $VCMP_IMM_EQ_OQ, Z9, Z13, K4
  VBROADCASTSD CONST_GET_PTR(const_pow, 8), K4, Z13
  VGETMANTPD $11, Z8, Z12
  VBROADCASTSD CONST_GET_PTR(const_pow, 16), Z11
  VBROADCASTSD CONSTF64_1(), Z7
  VADDPD Z11, Z12, Z5
  VADDPD Z7, Z5, Z14
  VSUBPD Z14, Z5, Z15
  VSUBPD Z15, Z11, Z15
  VSUBPD Z14, Z12, Z14
  VADDPD Z15, Z14, Z14
  VADDPD Z7, Z12, Z15
  VADDPD Z11, Z15, Z16
  VSUBPD Z16, Z15, Z17
  VSUBPD Z17, Z7, Z17
  VSUBPD Z16, Z12, Z12
  VADDPD Z17, Z12, Z12
  VDIVPD Z15, Z7, Z16
  VMULPD Z16, Z5, Z17
  VFMSUB213PD Z17, Z16, Z5   // Z5 = (Z16 * Z5) - Z17
  VFNMADD213PD Z7, Z16, Z15  // Z15 = -(Z16 * Z15) + Z7
  VFNMADD231PD Z12, Z16, Z15 // Z15 = -(Z16 * Z12) + Z15
  VFMADD231PD Z14, Z16, Z5   // Z5 = (Z16 * Z14) + Z5
  VFMADD231PD Z15, Z17, Z5   // Z5 = (Z17 * Z15) + Z5
  VMULPD Z17, Z17, Z12
  VADDPD Z17, Z17, Z14
  VMOVAPD Z17, Z15
  VFMSUB213PD Z12, Z17, Z15  // Z15 = (Z17 * Z15) - Z12
  VMULPD Z12, Z12, Z16
  VMULPD Z16, Z16, Z18
  VBROADCASTSD CONST_GET_PTR(const_pow, 24), Z19
  VFMADD213PD.BCST CONST_GET_PTR(const_pow, 32), Z12, Z19 // Z19 = (Z12 * Z19) + mem
  VBROADCASTSD CONST_GET_PTR(const_pow, 40), Z20
  VMULPD Z18, Z18, Z21
  VFMADD213PD.BCST CONST_GET_PTR(const_pow, 48), Z12, Z20 // Z20 = (Z12 * Z20) + mem
  VFMADD231PD Z19, Z16, Z20  // Z20 = (Z16 * Z19) + Z20
  VBROADCASTSD CONST_GET_PTR(const_pow, 56), Z19
  VFMADD213PD.BCST CONST_GET_PTR(const_pow, 64), Z12, Z19 // Z19 = (Z12 * Z19) + mem
  VBROADCASTSD CONST_GET_PTR(const_pow, 72), Z22
  VFMADD213PD.BCST CONST_GET_PTR(const_pow, 80), Z12, Z22 // Z22 = (Z12 * Z22) + mem
  VFMADD231PD Z19, Z16, Z22  // Z22 = (Z16 * Z19) + Z22
  VFMADD231PD Z20, Z18, Z22  // Z22 = (Z18 * Z20) + Z22
  VFMADD231PD.BCST CONST_GET_PTR(const_pow, 88), Z21, Z22 // Z22 = (Z21 * mem) + Z22
  VFMADD231PD Z5, Z14, Z15   // Z15 = (Z14 * Z5) + Z15
  VBROADCASTSD CONST_GET_PTR(const_pow, 96), Z16
  VMULPD Z16, Z13, Z18
  VFMSUB213PD Z18, Z13, Z16  // Z16 = (Z13 * Z16) - Z18
  VFMADD231PD.BCST CONST_GET_PTR(const_pow, 104), Z13, Z16 // Z16 = (Z13 * mem) + Z16
  VADDPD Z5, Z5, Z13
  VADDPD Z14, Z18, Z19
  VSUBPD Z19, Z18, Z18
  VADDPD Z18, Z14, Z14
  VADDPD Z14, Z16, Z14
  VADDPD Z13, Z14, Z13
  VMULPD Z12, Z17, Z14
  VMOVAPD Z17, Z16
  VFMSUB213PD Z14, Z12, Z16  // Z16 = (Z12 * Z16) - Z14
  VFMADD231PD Z17, Z15, Z16  // Z16 = (Z15 * Z17) + Z16
  VFMADD231PD Z5, Z12, Z16   // Z16 = (Z12 * Z5) + Z16
  VBROADCASTSD CONST_GET_PTR(const_pow, 112), Z5
  VMULPD Z5, Z14, Z17
  VMOVAPD Z5, Z18
  VFMSUB213PD Z17, Z14, Z18  // Z18 = (Z14 * Z18) - Z17
  VFMADD231PD Z5, Z16, Z18   // Z18 = (Z16 * Z5) + Z18
  VFMADD231PD.BCST CONST_GET_PTR(const_pow, 120), Z14, Z18 // Z18 = (Z14 * mem) + Z18
  VADDPD Z17, Z19, Z5
  VSUBPD Z5, Z19, Z19
  VADDPD Z19, Z17, Z17
  VADDPD Z17, Z13, Z13
  VADDPD Z18, Z13, Z13
  VMULPD Z14, Z12, Z17
  VMOVAPD Z14, Z18
  VFMSUB213PD Z17, Z12, Z18  // Z18 = (Z12 * Z18) - Z17
  VFMADD231PD Z15, Z14, Z18  // Z18 = (Z14 * Z15) + Z18
  VFMADD231PD Z16, Z12, Z18  // Z18 = (Z12 * Z16) + Z18
  VMULPD Z22, Z17, Z12
  VFMSUB213PD Z12, Z22, Z17  // Z17 = (Z22 * Z17) - Z12
  VFMADD231PD Z18, Z22, Z17  // Z17 = (Z22 * Z18) + Z17
  VADDPD Z12, Z5, Z14
  VSUBPD Z14, Z5, Z5
  VADDPD Z5, Z12, Z5
  VADDPD Z13, Z5, Z5
  VADDPD Z5, Z17, Z12
  VMULPD Z4, Z14, Z5
  VFMSUB213PD Z5, Z4, Z14    // Z14 = (Z4 * Z14) - Z5
  VFMADD231PD Z12, Z4, Z14   // Z14 = (Z4 * Z12) + Z14
  VADDPD Z14, Z5, Z12
  VMULPD.BCST CONST_GET_PTR(const_pow, 128), Z12, Z12
  VRNDSCALEPD $8, Z12, Z13
  VCVTPD2DQ.RN_SAE Z13, Y12
  VMULPD.BCST CONST_GET_PTR(const_pow, 136), Z13, Z15
  VADDPD Z5, Z15, Z16
  VSUBPD Z5, Z16, Z17
  VSUBPD Z17, Z16, Z18
  VSUBPD Z18, Z5, Z18
  VSUBPD Z17, Z15, Z15
  VADDPD Z18, Z15, Z15
  VMULPD.BCST CONST_GET_PTR(const_pow, 144), Z13, Z13
  VADDPD Z14, Z15, Z14
  VADDPD Z16, Z13, Z15
  VSUBPD Z16, Z15, Z17
  VSUBPD Z17, Z15, Z18
  VSUBPD Z18, Z16, Z16
  VSUBPD Z17, Z13, Z13
  VADDPD Z16, Z13, Z13
  VADDPD Z14, Z13, Z13
  VADDPD Z13, Z15, Z14
  VSUBPD Z14, Z15, Z15
  VADDPD Z15, Z13, Z13
  VMULPD Z14, Z14, Z15
  VMULPD Z15, Z15, Z16
  VMULPD Z16, Z16, Z17
  VBROADCASTSD CONST_GET_PTR(const_pow, 152), Z18
  VBROADCASTSD CONST_GET_PTR(const_pow, 168), Z19
  VFMADD213PD.BCST CONST_GET_PTR(const_pow, 160), Z14, Z18 // Z18 = (Z14 * Z18) + mem
  VFMADD213PD.BCST CONST_GET_PTR(const_pow, 176), Z14, Z19 // Z19 = (Z14 * Z19) + mem
  VBROADCASTSD CONST_GET_PTR(const_pow, 184), Z20
  VBROADCASTSD CONST_GET_PTR(const_pow, 200), Z21
  VFMADD213PD.BCST CONST_GET_PTR(const_pow, 192), Z14, Z20 // Z20 = (Z14 * Z20) + mem
  VFMADD213PD.BCST CONST_GET_PTR(const_pow, 208), Z14, Z21 // Z21 = (Z14 * Z21) + mem
  VBROADCASTSD CONST_GET_PTR(const_pow, 216), Z22
  VFMADD231PD Z19, Z15, Z20  // Z20 = (Z15 * Z19) + Z20
  VFMADD213PD.BCST CONST_GET_PTR(const_pow, 224), Z14, Z22 // Z22 = (Z14 * Z22) + mem
  VFMADD231PD Z21, Z15, Z22  // Z22 = (Z15 * Z21) + Z22
  VFMADD231PD Z20, Z16, Z22  // Z22 = (Z16 * Z20) + Z22
  VFMADD231PD Z18, Z17, Z22  // Z22 = (Z17 * Z18) + Z22
  VADDPD Z7, Z14, Z16
  VSUBPD Z16, Z7, Z17
  VADDPD Z17, Z14, Z17
  VADDPD Z17, Z13, Z17
  VADDPD Z14, Z14, Z18
  VFMSUB213PD Z15, Z14, Z14  // Z14 = (Z14 * Z14) - Z15
  VFMADD231PD Z18, Z13, Z14  // Z14 = (Z13 * Z18) + Z14
  VMULPD Z22, Z15, Z13
  VFMSUB213PD Z13, Z22, Z15  // Z15 = (Z22 * Z15) - Z13
  VFMADD231PD Z14, Z22, Z15  // Z15 = (Z22 * Z14) + Z15
  VADDPD Z13, Z16, Z14
  VSUBPD Z14, Z16, Z16
  VADDPD Z16, Z13, Z13
  VADDPD Z13, Z17, Z13
  VADDPD Z13, Z15, Z13
  VADDPD Z13, Z14, Z13
  VPSRAD $1, Y12, Y14
  VPSLLD $20, Y14, Y15
  VPBROADCASTD CONST_GET_PTR(const_pow, 248), Y16
  VPADDD Y16, Y15, Y15
  VPEXPANDD.Z Z15, K6, Z15
  VMULPD Z15, Z13, Z13
  VPSUBD Y14, Y12, Y12
  VPSLLD $20, Y12, Y12
  VPADDD Y16, Y12, Y12
  VPEXPANDD.Z Z12, K6, Z12
  VCMPPD.BCST $VCMP_IMM_NLT_US, CONST_GET_PTR(const_pow, 232), Z5, K4
  VMULPD.Z Z12, Z13, K4, Z12
  VCMPPD.BCST $VCMP_IMM_GT_OS, CONST_GET_PTR(const_pow, 240), Z5, K4
  VMOVAPD Z9, K4, Z12
  VBLENDMPD Z11, Z7, K2, Z5
  VBROADCASTSD CONSTF64_NAN(), Z13
  VCMPPD $VCMP_IMM_LT_OS, Z3, Z6, K4
  VMOVAPD Z5, K3, Z13
  VMOVAPD Z7, K4, Z13
  VMULPD Z12, Z13, Z5
  VADDPD Z11, Z8, Z11
  VPBROADCASTQ CONSTF64_SIGN_BIT(), Z12
  VPTERNLOGQ $120, Z12, Z4, Z11
  VPANDQ Z10, Z4, Z10
  VCMPPD $VCMP_IMM_EQ_OQ, Z9, Z10, K3
  VCMPPD $VCMP_IMM_NLT_US, Z6, Z11, K4
  VCMPPD $VCMP_IMM_EQ_OQ, Z6, Z11, K5
  VBLENDMPD Z7, Z9, K5, Z10
  VMOVAPD.Z Z10, K4, Z10
  VMOVAPD Z10, K3, Z5
  VCMPPD $VCMP_IMM_EQ_OQ, Z9, Z8, K0
  VCMPPD $VCMP_IMM_EQ_OQ, Z6, Z3, K3
  KORW K3, K0, K4
  VPCMPGTQ Z4, Z6, K0
  KXNORW K3, K0, K3
  VPBROADCASTQ.Z CONSTF64_POSITIVE_INF(), K3, Z8
  VPANDQ.Z Z12, Z3, K2, Z9
  VCMPPD $VCMP_IMM_UNORD_Q, Z3, Z4, K2
  VPORQ Z8, Z9, K4, Z5
  VPTERNLOGD $255, Z8, Z8, Z8
  VMOVAPD Z8, K2, Z5
  VCMPPD $VCMP_IMM_EQ_OQ, Z6, Z4, K0
  VCMPPD $VCMP_IMM_EQ_OQ, Z7, Z3, K2
  KORW K2, K0, K2
  VMOVAPD Z7, K2, Z5
  VMOVAPD Z5, Z3

next:
  NEXT_ADVANCE(2)

// Conversion Instructions
// -----------------------

// convert the input mask to 0.0 or 1.0 based on whether or not it is set
TEXT bccvtktof64(SB), NOSPLIT|NOFRAME, $0
  VBROADCASTSD  CONSTF64_1(), Z2
  KSHIFTRW      $8, K1, K2
  VMOVDQA64.Z   Z2, K2, Z3
  VMOVDQA64.Z   Z2, K1, Z2
  NEXT()

// convert float64 to mask
TEXT bccvtf64tok(SB), NOSPLIT|NOFRAME, $0
  KSHIFTRW $8, K1, K2

  VPXORQ    Z11, Z11, Z11

  // shift out the sign bit, so we correctly handle the "-0.0" case
  VPSLLQ    $1, Z2, Z4
  VPSLLQ    $1, Z3, Z5

  // binary image of +0.0 is full of zeros, so it's safe to use int arithmetic
  VPCMPQ    $VPCMP_IMM_NE, Z11, Z4, K1, K1
  VPCMPQ    $VPCMP_IMM_NE, Z11, Z5, K2, K2
  KUNPCKBW  K1, K2, K1
  NEXT()

// convert the input mask to 0 or 1 based on whether or not it is set
TEXT bccvtktoi64(SB), NOSPLIT|NOFRAME, $0
  VPBROADCASTQ CONSTQ_1(), Z2
  KSHIFTRW     $8, K1, K2
  VMOVDQA64.Z  Z2, K2, Z3
  VMOVDQA64.Z  Z2, K1, Z2
  NEXT()

TEXT bccvti64tok(SB), NOSPLIT|NOFRAME, $0
  KSHIFTRW $8, K1, K2
  VPXORQ X4, X4, X4
  VPCMPQ $VPCMP_IMM_NE, Z4, Z2, K1, K1
  VPCMPQ $VPCMP_IMM_NE, Z4, Z3, K2, K2
  KUNPCKBW K1, K2, K1
  NEXT()

// integer to fp conversion
TEXT bccvti64tof64(SB), NOSPLIT|NOFRAME, $0
  KSHIFTRW         $8, K1, K2
  VCVTQQ2PD.RN_SAE Z2, K1, Z2
  VCVTQQ2PD.RN_SAE Z3, K2, Z3
  NEXT()

// convert fp to int
//
// TODO: validate FPCLASS, etc.;
// we should convert +inf/-inf correctly
// in those circumstances...

#define BC_CVT_F64_TO_I64(mode) \
  KSHIFTRW       $8, K1, K2     \
  VCVTPD2QQ.mode Z2, K1, Z2     \
  VCVTPD2QQ.mode Z3, K2, Z3

// TODO: We should truncate by default, and then extend our offered rounding conversions.
TEXT bccvtf64toi64(SB), NOSPLIT|NOFRAME, $0
  BC_CVT_F64_TO_I64(RN_SAE)
  NEXT()

TEXT bcfproundu(SB), NOSPLIT|NOFRAME, $0
  BC_CVT_F64_TO_I64(RU_SAE)
  NEXT()

TEXT bcfproundd(SB), NOSPLIT|NOFRAME, $0
  BC_CVT_F64_TO_I64(RD_SAE)
  NEXT()

// Converts a signed 64-bit integer to a string slice.
//
// Implementation notes:
//   - maximum length of the output is 20 bytes, including '-' sign.
//   - we split the string into 3 parts (two 8-char parts, and one 4-char part) forming [4-8-8] string.
//   - the integer is converted to string by subdividing it, by 10000000000000000, 100000000, 10000, 100, and 10.
//   - then after we have 0-9 numbers in each byte representing a character, we just add '48' to make it ASCII.
//   - the length of each string in each lane is found at the end, by counting leading zeros.
//   - we always insert a '-' sign, the string length is incremented if the integer is negative, so it will only
//     appear when the input is negative. This simplifies the code a bit.
TEXT bccvti64tostr(SB), NOSPLIT|NOFRAME, $0
  // Get the signs so we can prepend '-' sign at the end.
  VPMOVQ2M Z2, K2
  VPMOVQ2M Z3, K3
  KUNPCKBW K2, K3, K2

  // Make the inputs unsigned - since we know which lanes are negative, it's destructive.
  VPABSQ Z2, Z2
  VPABSQ Z3, Z3

  // Step A:
  //
  // Split the input into 3 parts:
  //   Z2:Z3   <- 8-char low part lanes
  //   Z12:Z13 <- 8-char high part lanes
  //   Z20     <- 4-char high part lanes

  // NOTE: We don't rely on high-precision integer division here. We can just shift
  // right by 16 bits, which is the maximum we can to divide by `10000000000000000`
  // to get the 4-char high part lanes.
  VPSRLQ $16, Z2, Z12
  VPSRLQ $16, Z3, Z13

  // 152587890625 == 10000000000000000 >> 16
  VBROADCASTSD CONSTF64_152587890625(), Z19

  VCVTUQQ2PD Z12, Z12
  VCVTUQQ2PD Z13, Z13

  VDIVPD.RD_SAE Z19, Z12, Z8
  VDIVPD.RD_SAE Z19, Z13, Z9

  VPBROADCASTQ CONSTQ_0xFFFF(), Z20
  VBROADCASTSD CONSTF64_65536(), Z18

  VPANDQ Z20, Z3, Z21
  VPANDQ Z20, Z2, Z20

  VCVTUQQ2PD Z21, Z21
  VCVTUQQ2PD Z20, Z20

  VRNDSCALEPD $VROUND_IMM_DOWN_SAE, Z8, Z8
  VRNDSCALEPD $VROUND_IMM_DOWN_SAE, Z9, Z9

  VFNMADD231PD Z19, Z8, Z12
  VFNMADD231PD Z19, Z9, Z13

  VFMADD132PD Z18, Z20, Z12
  VFMADD132PD Z18, Z21, Z13

  // Required for splitting to 8-char parts, where each part is between 0 to 99999999.
  VBROADCASTSD CONSTF64_100000000(), Z18

  VDIVPD.RD_SAE Z18, Z12, Z2
  VDIVPD.RD_SAE Z18, Z13, Z3

  VRNDSCALEPD $VROUND_IMM_DOWN_SAE, Z2, Z2
  VRNDSCALEPD $VROUND_IMM_DOWN_SAE, Z3, Z3

  VFNMADD231PD Z18, Z2, Z12
  VFNMADD231PD Z18, Z3, Z13

  // Z20 <- 4-char high part lanes
  VCVTPD2UDQ Z8, Y20
  VCVTPD2UDQ Z9, Y21
  VINSERTI32X8 $1, Y21, Z20, Z20

  // Z2:Z3 <- 8-char high part lanes
  VCVTPD2UQQ Z2, Z2
  VCVTPD2UQQ Z3, Z3

  // Z12:Z13 <- 8-char low part lanes
  VCVTPD2UQQ Z12, Z12
  VCVTPD2UQQ Z13, Z13

  // Step B:
  //
  // Stringify the input parts:
  //   - the output would be 20 characters.
  //   - the stringification happens in 3 steps:
  //     - Step X - tens of thousands [X / 10000, X % 10000]
  //     - Step Y - hundreds          [Y / 100  , Y % 100  ]
  //     - Step Z - tens              [Z / 10   , Z % 10   ]
  //   - the output is bytes having numbers from 0-9 (decimals).

  // Constants for X step.
  VPBROADCASTQ CONSTQ_3518437209(), Z18
  VPBROADCASTQ CONSTQ_10000(), Z19

  // Z4:Z5, Z14:Z15 <- X / 10000
  VPMULUDQ Z18, Z2, Z4
  VPMULUDQ Z18, Z3, Z5
  VPMULUDQ Z18, Z12, Z14
  VPMULUDQ Z18, Z13, Z15

  VPSRLQ $45, Z4, Z4
  VPSRLQ $45, Z5, Z5
  VPSRLQ $45, Z14, Z14
  VPSRLQ $45, Z15, Z15

  // Z6:Z7, Z16:Z17 <- X % 10000
  VPMULUDQ Z19, Z4, Z6
  VPMULUDQ Z19, Z5, Z7
  VPMULUDQ Z19, Z14, Z16
  VPMULUDQ Z19, Z15, Z17

  VPSUBD Z6, Z2, Z6
  VPSUBD Z7, Z3, Z7
  VPSUBD Z16, Z12, Z16
  VPSUBD Z17, Z13, Z17

  // Constants for Y step.
  VPBROADCASTD CONSTD_5243(), Z18
  VPBROADCASTD CONSTD_100(), Z19

  // Z4:Z5, Z14:Z15 <- Y == [X / 10000, X % 10000]
  VPSLLQ $32, Z6, Z6
  VPSLLQ $32, Z7, Z7
  VPSLLQ $32, Z16, Z16
  VPSLLQ $32, Z17, Z17

  VPORD Z6, Z4, Z4
  VPORD Z7, Z5, Z5
  VPORD Z16, Z14, Z14
  VPORD Z17, Z15, Z15

  // Z6:Z7, Z16:Z17, Z21 <- Y / 100
  VPMULHUW Z18, Z20, Z21
  VPMULHUW Z18, Z4, Z6
  VPMULHUW Z18, Z5, Z7
  VPMULHUW Z18, Z14, Z16
  VPMULHUW Z18, Z15, Z17

  VPSRLW $3, Z21, Z21
  VPSRLW $3, Z6, Z6
  VPSRLW $3, Z7, Z7
  VPSRLW $3, Z16, Z16
  VPSRLW $3, Z17, Z17

  // Z4:Z5, Z14:Z15, Z20 <- Y % 100
  VPMULLW Z19, Z21, Z22
  VPMULLW Z19, Z6, Z8
  VPMULLW Z19, Z7, Z9
  VPMULLW Z19, Z16, Z18
  VPMULLW Z19, Z17, Z19

  VPSUBW Z22, Z20, Z20
  VPSUBW Z8, Z4, Z4
  VPSUBW Z9, Z5, Z5
  VPSUBW Z18, Z14, Z14
  VPSUBW Z19, Z15, Z15

  // Z4:Z5, Z14:Z15, Z20 <- Z == [Y / 100, Y % 100]
  VPSLLD $16, Z20, Z20
  VPSLLD $16, Z4, Z4
  VPSLLD $16, Z5, Z5
  VPSLLD $16, Z14, Z14
  VPSLLD $16, Z15, Z15

  VPORD Z21, Z20, Z20
  VPORD Z6, Z4, Z4
  VPORD Z7, Z5, Z5
  VPORD Z16, Z14, Z14
  VPORD Z17, Z15, Z15

  // Constants for Z step.
  VPBROADCASTW CONSTD_6554(), Z18
  VPBROADCASTW CONSTD_10(), Z19

  // Z4:Z5, Z14:Z15, Z21 <- Z / 10
  VPMULHUW Z18, Z20, Z21
  VPMULHUW Z18, Z4, Z6
  VPMULHUW Z18, Z5, Z7
  VPMULHUW Z18, Z14, Z16
  VPMULHUW Z18, Z15, Z17

  // Z4:Z5, Z14:Z15, Z20 <- Z % 10
  VPMULLW Z19, Z21, Z22
  VPMULLW Z19, Z6, Z8
  VPMULLW Z19, Z7, Z9
  VPMULLW Z19, Z16, Z18
  VPMULLW Z19, Z17, Z19

  VPSUBW Z22, Z20, Z20
  VPSUBW Z8, Z4, Z4
  VPSUBW Z9, Z5, Z5
  VPSUBW Z18, Z14, Z14
  VPSUBW Z19, Z15, Z15

  // Z4:Z5, Z14:Z15, Z20 <- [Z / 10, Z % 10]
  VPSLLW $8, Z20, Z20
  VPSLLW $8, Z4, Z4
  VPSLLW $8, Z5, Z5
  VPSLLW $8, Z14, Z14
  VPSLLW $8, Z15, Z15

  VPORD Z21, Z20, Z20
  VPORD Z6, Z4, Z4
  VPORD Z7, Z5, Z5
  VPORD Z16, Z14, Z14
  VPORD Z17, Z15, Z15

  // Step C:
  //
  // Find the length of the output string of each lane and insert a '-' sign
  // before the first non-zero character. This is not really trivial as the
  // string is split across three registers. So, we start at the highest
  // character and use VPLZCNT[D|Q] to advance.

  // This temporarily reverses the strings as we would not be able to
  // use VPLZCNT[D|Q] otherwise. There are in general two options, generate
  // reversed string, or reverse the string before the counting. It doesn't
  // matter, as either way we would have to reverse it (either for storing
  // or for zero counting).
  VBROADCASTI32X4 CONST_GET_PTR(bswap32, 0), Z10
  VBROADCASTI32X4 CONST_GET_PTR(bswap64, 0), Z9

  VPSHUFB Z10, Z20, Z10
  VPSHUFB Z9, Z4, Z6
  VPSHUFB Z9, Z5, Z7
  VPSHUFB Z9, Z14, Z8
  VPSHUFB Z9, Z15, Z9

  // Stringified number must have at least 1 character, so make it nonzero in tmp Z8/Z9.
  VPORQ.BCST CONSTD_0x7F(), Z8, Z8
  VPORQ.BCST CONSTD_0x7F(), Z9, Z9

  VPLZCNTD Z10, Z10
  VPLZCNTQ Z6, Z6
  VPLZCNTQ Z7, Z7
  VPLZCNTQ Z8, Z8
  VPLZCNTQ Z9, Z9

  // VPLZCNT[D|Q] gives us bits, but we need shifts of 8-bit quantities.
  //
  // NOTE: We keep the quantities in bits - so 2 characters are 16, etc... The reason
  // is that this makes the code simpler as shift operation needs bits, and we have to
  // insert a sign, which is shifted by bits and not bytes.
  VPBROADCASTD CONSTD_7(), Z11
  VPANDND Z10, Z11, Z10
  VPANDNQ Z6, Z11, Z6
  VPANDNQ Z7, Z11, Z7
  VPANDNQ Z8, Z11, Z8
  VPANDNQ Z9, Z11, Z9

  // Number of characters * 8 of the output string (will be advanced).
  VPSLLD.BCST $3, CONSTD_20(), Z3

  // Advance high 4 chars.
  VPSUBD Z10, Z3, K1, Z3
  VPSUBD.BCST CONSTD_8(), Z10, Z10
  VPBROADCASTD CONSTD_3(), Z11
  VPSLLVD Z10, Z11, Z11
  VPSUBB Z11, Z20, Z20

  // Advance high 8-chars.
  VPCMPEQD.BCST CONSTD_128(), Z3, K3
  KSHIFTRW $8, K3, K4

  VPMOVQD Z6, Y10
  VPMOVQD Z7, Y11
  VPSUBQ.BCST CONSTQ_8(), Z6, Z6
  VPSUBQ.BCST CONSTQ_8(), Z7, Z7

  VINSERTI32X8 $1, Y11, Z10, Z10
  VPSUBD Z10, Z3, K3, Z3

  VPBROADCASTQ.Z CONSTQ_3(), K3, Z12
  VPBROADCASTQ.Z CONSTQ_3(), K4, Z13
  VPSLLVQ Z6, Z12, Z12
  VPSLLVQ Z7, Z13, Z13

  VPSUBB Z12, Z4, Z4
  VPSUBB Z13, Z5, Z5

  // Advance low 8-chars.
  VPCMPEQD.BCST CONSTD_64(), Z3, K3
  KSHIFTRW $8, K3, K4

  VPMOVQD Z8, Y10
  VPMOVQD Z9, Y11
  VPSUBQ.BCST CONSTQ_8(), Z8, Z8
  VPSUBQ.BCST CONSTQ_8(), Z9, Z9

  VINSERTI32X8 $1, Y11, Z10, Z10
  VPSUBD Z10, Z3, K3, Z3

  VPBROADCASTQ.Z CONSTQ_3(), K3, Z12
  VPBROADCASTQ.Z CONSTQ_3(), K4, Z13
  VPSLLVQ Z8, Z12, Z12
  VPSLLVQ Z9, Z13, Z13

  VPSUBB Z12, Z14, Z14
  VPSUBB Z13, Z15, Z15

  // Z3 contains the number of characters * 8 (in bit units) - convert it back to bytes.
  VPSRLD $3, Z3, Z3

  // Step D:
  //
  // Shuffle in a way so we get low 16 character part for each lane. The rest 4
  // characters are kept in Z20 (4 character high lanes). Then store the characters
  // to consecutive memory.

  VPUNPCKLQDQ Z14, Z4, Z6 // Lane [06] [04] [02] [00]
  VPUNPCKHQDQ Z14, Z4, Z7 // Lane [07] [05] [03] [01]
  VPUNPCKLQDQ Z15, Z5, Z8 // Lane [14] [12] [10] [08]
  VPUNPCKHQDQ Z15, Z5, Z9 // Lane [15] [13] [11] [09]

  // Constants for converting the number to ASCII.
  VPBROADCASTB CONSTD_48(), Z18

  VPADDB Z18, Z20, Z20
  VPADDB Z18, Z6, Z6
  VPADDB Z18, Z7, Z7
  VPADDB Z18, Z8, Z8
  VPADDB Z18, Z9, Z9

  // Z3 now contains the length of the output string of each lane including '-' sign when negative.
  VPADDD.BCST CONSTD_1(), Z3, K2, Z3

  // Make sure we have at least 20 bytes for each lane, we always overallocate to make the conversion easier.
  VM_CHECK_SCRATCH_CAPACITY($(20 * 16), R8, abort)

  VM_GET_SCRATCH_BASE_GP(R8)

  // Update the length of the output buffer.
  ADDQ $(20 * 16), bytecode_scratch+8(VIRT_BCPTR)

  // Broadcast scratch base to all lanes in Z2, which becomes string slice offset.
  VPBROADCASTD.Z R8, K1, Z2

  // Make R8 the first address where the output will be stored.
  ADDQ SI, R8

  VPADDD CONST_GET_PTR(consts_offsets_d_20, 4), Z2, Z2
  VPSUBD.Z Z3, Z2, K1, Z2

  VEXTRACTI32X4 $1, Z20, X21
  VEXTRACTI32X4 $2, Z20, X22
  VEXTRACTI32X4 $3, Z20, X23

  // Store output strings (low lanes).
  VPEXTRD $0, X20, 0(R8)
  VEXTRACTI32X4 $0, Z6, 4(R8)
  VPEXTRD $1, X20, 20(R8)
  VEXTRACTI32X4 $0, Z7, 24(R8)
  VPEXTRD $2, X20, 40(R8)
  VEXTRACTI32X4 $1, Z6, 44(R8)
  VPEXTRD $3, X20, 60(R8)
  VEXTRACTI32X4 $1, Z7, 64(R8)

  VPEXTRD $0, X21, 80(R8)
  VEXTRACTI32X4 $2, Z6, 84(R8)
  VPEXTRD $1, X21, 100(R8)
  VEXTRACTI32X4 $2, Z7, 104(R8)
  VPEXTRD $2, X21, 120(R8)
  VEXTRACTI32X4 $3, Z6, 124(R8)
  VPEXTRD $3, X21, 140(R8)
  VEXTRACTI32X4 $3, Z7, 144(R8)

  // Store output strings (high lanes).
  VPEXTRD $0, X22, 160(R8)
  VEXTRACTI32X4 $0, Z8, 164(R8)
  VPEXTRD $1, X22, 180(R8)
  VEXTRACTI32X4 $0, Z9, 184(R8)
  VPEXTRD $2, X22, 200(R8)
  VEXTRACTI32X4 $1, Z8, 204(R8)
  VPEXTRD $3, X22, 220(R8)
  VEXTRACTI32X4 $1, Z9, 224(R8)

  VPEXTRD $0, X23, 240(R8)
  VEXTRACTI32X4 $2, Z8, 244(R8)
  VPEXTRD $1, X23, 260(R8)
  VEXTRACTI32X4 $2, Z9, 264(R8)
  VPEXTRD $2, X23, 280(R8)
  VEXTRACTI32X4 $3, Z8, 284(R8)
  VPEXTRD $3, X23, 300(R8)
  VEXTRACTI32X4 $3, Z9, 304(R8)

  NEXT()

abort:
  MOVL $const_bcerrMoreScratch, bytecode_err(VIRT_BCPTR)
  RET_ABORT()


// Comparison Instructions - [Sort]Cmp(Value, Value)
// -------------------------------------------------

CONST_DATA_U64(ion_value_cmp_predicate_nulls_first, 0, $0x0403000202020100)
CONST_DATA_U64(ion_value_cmp_predicate_nulls_first, 8, $0xFFFFFFFFFFFFFF04)
CONST_GLOBAL(ion_value_cmp_predicate_nulls_first, $16)

CONST_DATA_U64(ion_value_cmp_predicate_nulls_last, 0, $0x040300020202010F)
CONST_DATA_U64(ion_value_cmp_predicate_nulls_last, 8, $0xFFFFFFFFFFFFFF04)
CONST_GLOBAL(ion_value_cmp_predicate_nulls_last, $16)

TEXT bcsortcmpvnf(SB), NOSPLIT|NOFRAME, $0
  VBROADCASTI32X4 CONST_GET_PTR(ion_value_cmp_predicate_nulls_first, 0), Z11
  JMP sortcmpv_tail(SB)

TEXT bcsortcmpvnl(SB), NOSPLIT|NOFRAME, $0
  VBROADCASTI32X4 CONST_GET_PTR(ion_value_cmp_predicate_nulls_last, 0), Z11
  JMP sortcmpv_tail(SB)

#define BC_CMP_NAME sortcmpv_tail
#define BC_CMP_IS_SORT
#include "evalbc_cmpv_impl.h"
#undef BC_CMP_IS_SORT
#undef BC_CMP_NAME

/*
(for our script to pick up the opcode)
TEXT bccmpv(SB), NOSPLIT|NOFRAME, $0
*/

#define BC_CMP_NAME bccmpv
#include "evalbc_cmpv_impl.h"
#undef BC_CMP_NAME


// Comparison Instructions - Cmp(Value, Bool)
// ------------------------------------------

// Compares the content of left (unboxed) value and right (bool) scalar
TEXT bccmpvk(SB), NOSPLIT|NOFRAME, $0
  MOVWLZX 0(VIRT_PCREG), R8
  ADDQ $2, VIRT_PCREG
  KMOVW 0(VIRT_VALUES)(R8*1), K2
  VPBROADCASTD.Z CONSTD_1(), K2, Z2
  JMP cmpvk_tail(SB)

// Compares the content of left (unboxed) value and right (bool) immediate
TEXT bccmpvimmk(SB), NOSPLIT|NOFRAME, $0
  VPBROADCASTB 0(VIRT_PCREG), Z2
  ADDQ $1, VIRT_PCREG
  VPSRLD $24, Z2, Z2
  JMP cmpvk_tail(SB)

TEXT cmpvk_tail(SB), NOSPLIT|NOFRAME, $0
  KMOVW K1, K2
  VPXORQ X4, X4, X4
  VPGATHERDD 0(SI)(Z30*1), K2, Z4                      // Z4 <- first 4 bytes of the left value

  VPBROADCASTD CONSTD_0x0F(), Z6
  VPSRLD $4, Z4, Z5
  VPANDD Z6, Z5, Z5                                    // Z5 <- left ION type
  VPANDD Z6, Z4, Z4                                    // Z4 <- left boolean value (0 or 1)
  VPCMPEQD.BCST CONSTD_1(), Z5, K1, K1                 // K1 <- bool comparison predicate (the output predicate)

  VPSUBD.Z Z2, Z4, K1, Z2                              // Z2 <- comparison results {-1, 0, 1} (all)
  VEXTRACTI32X8 $1, Z2, Y3
  VPMOVSXDQ Y2, Z2                                     // Z2 <- comparison results (low)
  VPMOVSXDQ Y3, Z3                                     // Z3 <- comparison results (high)

  NEXT()


// Comparison Instructions - Cmp(Value, Int64)
// -------------------------------------------

// Compares the content of left (unboxed) value and right (int64) scalar
TEXT bccmpvi64(SB), NOSPLIT|NOFRAME, $0
  KMOVW K1, K2
  VPXORQ X9, X9, X9
  VPGATHERDD 0(SI)(Z30*1), K2, Z9                     // Z9 <- first 4 bytes of the left value

  VMOVDQA64 Z2, Z6                                    // Z6 <- right int64 value (low)
  VPXORD X2, X2, X2                                   // Z2 <- Comparison results, initially all zeros (low)
  VMOVDQA64 Z3, Z7                                    // Z7 <- right int64 value (high)
  VPXORD X3, X3, X3                                   // Z3 <- Comparison results, initially all zeros (high)

  VPBROADCASTD CONSTD_0x0F(), Z10
  VBROADCASTI32X4 CONST_GET_PTR(ion_value_cmp_predicate_nulls_first, 0), Z11

  VPSRLD $4, Z9, Z8
  VPANDD Z10, Z8, Z8                                  // Z8 <- left ION type
  VPSHUFB Z8, Z11, Z11                                // Z11 <- left ION type converted to an internal type
  VPANDD Z10, Z9, Z10                                 // Z10 <- left L field
  VPCMPEQD.BCST CONSTD_2(), Z11, K1, K1               // K1 <- number comparison predicate (the output predicate)

  KTESTW K1, K1
  JZ next                                             // Skip number comparison if there are no numbers (K1 == 0)

  // Gather 8 bytes of each left value
  VEXTRACTI32X8 $1, Z30, Y11
  KMOVB K1, K2
  VPXORQ X4, X4, X4
  VPGATHERDQ 1(SI)(Y30*1), K2, Z4
  KSHIFTRW $8, K1, K3
  VPXORQ X5, X5, X5
  VPGATHERDQ 1(SI)(Y11*1), K3, Z5

  // Byteswap each gathered value and shift right in case of signed/unsigned int
  VPBROADCASTD CONSTD_8(), Z11
  VPSUBD Z10, Z11, Z10
  VPSLLD $3, Z10, Z10

  VEXTRACTI32X8 $1, Z10, Y11
  VBROADCASTI32X4 CONST_GET_PTR(bswap64, 0), Z12
  VPMOVZXDQ Y10, Z10
  VPMOVZXDQ Y11, Z11

  VPSHUFB Z12, Z4, Z4
  VPSHUFB Z12, Z5, Z5

  VPBROADCASTD CONSTD_1(), Z12
  VPBROADCASTD CONSTD_3(), Z13
  VPBROADCASTD CONSTD_0xFFFFFFFF(), Z14

  VPSRLVQ Z10, Z4, Z4
  VPSRLVQ Z11, Z5, Z5

  // Convert negative uint64 to int64 (ION stores negative integers as positive ones, but having a different tag)
  VPCMPEQD Z13, Z8, K1, K2
  KSHIFTRW $8, K2, K3

  VPSUBQ Z4, Z3, K2, Z4
  VPSUBQ Z5, Z3, K3, Z5

  VPCMPGTD Z13, Z8, K1, K2                             // K2 <- mask of floating point values (low / all)
  KSHIFTRW $8, K2, K3                                  // K3 <- mask of floating point values (high)

  VCVTQQ2PD Z6, K2, Z6                                 // Z6 <- mixed i64|f64 values depending on left value type (low)
  VCVTQQ2PD Z7, K3, Z7                                 // Z7 <- mixed i64|f64 values depending on left value type (high)

  VPANDQ.Z Z6, Z4, K2, Z10                             // Z10 <- MSB bits of left & right negative floats (low)
  VPANDQ.Z Z7, Z5, K3, Z11                             // Z11 <- MSB bits of left & right negative floats (high)
  VPMOVQ2M Z10, K5                                     // K4 <- floating point negative values (low)
  VPMOVQ2M Z11, K6                                     // K5 <- floating point negative values (high)

  VPXORQ X10, X10, X10
  KUNPCKBW K5, K6, K5                                  // K5 <- floating point negative values (all)

  KSHIFTRW $8, K1, K2
  VPCMPQ $VPCMP_IMM_LT, Z6, Z4, K1, K3                 // K3 <- less than (low)
  VPCMPQ $VPCMP_IMM_LT, Z7, Z5, K2, K4                 // K4 <- less than (high)
  KUNPCKBW K3, K4, K3                                  // K3 <- less than (all)
  VMOVDQA32 Z14, K3, Z2                                // Z2 <- merge less than results (-1)

  VPCMPQ $VPCMP_IMM_GT, Z6, Z4, K1, K3                 // K3 <- greater than (low)
  VPCMPQ $VPCMP_IMM_GT, Z7, Z5, K2, K4                 // K4 <- greater than (high)
  KUNPCKBW K3, K4, K3                                  // K3 <- greater than (all)
  VMOVDQA32 Z12, K3, Z2                                // Z2 <- merge greater than results (1)
  VPSUBD Z2, Z10, K5, Z2                               // Z2 <- results with corrected floating point comparison

  VEXTRACTI32X8 $1, Z2, Y3
  VPMOVSXDQ Y2, Z2                                     // Z2 <- comparison results (low)
  VPMOVSXDQ Y3, Z3                                     // Z3 <- comparison results (high)

next:
  NEXT()

// Compares the content of left (unboxed) value and right (int64) immediate
TEXT bccmpvimmi64(SB), NOSPLIT|NOFRAME, $0
  VPBROADCASTQ 0(VIRT_PCREG), Z2
  ADDQ $8, VIRT_PCREG
  VMOVDQA64 Z2, Z3
  JMP bccmpvi64(SB)


// Comparison Instructions - Cmp(Value, Float64)
// ---------------------------------------------

// Compares the content of left (unboxed) value and right (float64) scalar
TEXT bccmpvf64(SB), NOSPLIT|NOFRAME, $0
  KMOVW K1, K2
  VPXORQ X9, X9, X9
  VPGATHERDD 0(SI)(Z30*1), K2, Z9                     // Z9 <- first 4 bytes of the left value

  VMOVAPD Z2, Z6                                      // Z6 <- right int64 value (low)
  VPXORD X2, X2, X2                                   // Z2 <- Comparison results, initially all zeros (low)
  VMOVAPD Z3, Z7                                      // Z7 <- right int64 value (high)
  VPXORD X3, X3, X3                                   // Z3 <- Comparison results, initially all zeros (high)

  VPBROADCASTD CONSTD_0x0F(), Z10
  VBROADCASTI32X4 CONST_GET_PTR(ion_value_cmp_predicate_nulls_first, 0), Z11

  VPSRLD $4, Z9, Z8
  VPANDD Z10, Z8, Z8                                  // Z8 <- left ION type
  VPSHUFB Z8, Z11, Z11                                // Z11 <- left ION type converted to an internal type
  VPANDD Z10, Z9, Z10                                 // Z10 <- left L field
  VPCMPEQD.BCST CONSTD_2(), Z11, K1, K1               // K1 <- number comparison predicate (the output predicate)

  KTESTW K1, K1
  JZ next                                             // Skip number comparison if there are no numbers (K1 == 0)

  // Gather 8 bytes of each left value
  VEXTRACTI32X8 $1, Z30, Y11
  KMOVB K1, K2
  VPXORQ X4, X4, X4
  VPGATHERDQ 1(SI)(Y30*1), K2, Z4
  KSHIFTRW $8, K1, K3
  VPXORQ X5, X5, X5
  VPGATHERDQ 1(SI)(Y11*1), K3, Z5

  // Byteswap each gathered value and shift right in case of signed/unsigned int
  VPBROADCASTD CONSTD_8(), Z11
  VPSUBD Z10, Z11, Z10
  VPSLLD $3, Z10, Z10

  VEXTRACTI32X8 $1, Z10, Y11
  VBROADCASTI32X4 CONST_GET_PTR(bswap64, 0), Z12
  VPMOVZXDQ Y10, Z10
  VPMOVZXDQ Y11, Z11

  VPSHUFB Z12, Z4, Z4
  VPSHUFB Z12, Z5, Z5

  VPBROADCASTD CONSTD_1(), Z12
  VPBROADCASTD CONSTD_3(), Z13
  VPBROADCASTD CONSTD_0xFFFFFFFF(), Z14

  VPSRLVQ Z10, Z4, Z4
  VPSRLVQ Z11, Z5, Z5

  // Convert negative uint64 to int64 (ION stores negative integers as positive ones, but having a different tag)
  VPCMPEQD Z13, Z8, K1, K2
  KSHIFTRW $8, K2, K3

  VPSUBQ Z4, Z3, K2, Z4
  VPSUBQ Z5, Z3, K3, Z5

  VPCMPD $VPCMP_IMM_LE, Z13, Z8, K1, K2                // K2 <- mask of integer values (all)
  KSHIFTRW $8, K2, K3                                  // K3 <- mask of integer values (high)

  VCVTQQ2PD Z4, K2, Z4                                 // Z4 <- left numbers converted to float64 (low)
  KSHIFTRW $8, K1, K2                                  // K1 <- active lanes (high)
  VCVTQQ2PD Z5, K3, Z5                                 // Z5 <- left numbers converted to float64 (high)

  VPANDQ.Z Z6, Z4, K1, Z10                             // Z10 <- MSB bits of left & right negative floats (low)
  VPANDQ.Z Z7, Z5, K2, Z11                             // Z11 <- MSB bits of left & right negative floats (high)
  VPMOVQ2M Z10, K5                                     // K4 <- floating point negative values (low)
  VPMOVQ2M Z11, K6                                     // K5 <- floating point negative values (high)

  VPXORQ X10, X10, X10
  KUNPCKBW K5, K6, K5                                  // K5 <- floating point negative values (all)

  VPCMPQ $VPCMP_IMM_LT, Z6, Z4, K1, K3                 // K3 <- less than (low)
  VPCMPQ $VPCMP_IMM_LT, Z7, Z5, K2, K4                 // K4 <- less than (high)
  KUNPCKBW K3, K4, K3                                  // K3 <- less than (all)
  VMOVDQA32 Z14, K3, Z2                                // Z2 <- merge less than results (-1)

  VPCMPQ $VPCMP_IMM_GT, Z6, Z4, K1, K3                 // K3 <- greater than (low)
  VPCMPQ $VPCMP_IMM_GT, Z7, Z5, K2, K4                 // K4 <- greater than (high)
  KUNPCKBW K3, K4, K3                                  // K3 <- greater than (all)
  VMOVDQA32 Z12, K3, Z2                                // Z2 <- merge greater than results (1)
  VPSUBD Z2, Z10, K5, Z2                               // Z2 <- results with corrected floating point comparison

  VEXTRACTI32X8 $1, Z2, Y3
  VPMOVSXDQ Y2, Z2                                     // Z2 <- comparison results (low)
  VPMOVSXDQ Y3, Z3                                     // Z3 <- comparison results (high)

next:
  NEXT()

// Compares the content of left (unboxed) value and right (float64) immediate
TEXT bccmpvimmf64(SB), NOSPLIT|NOFRAME, $0
  VBROADCASTSD 0(VIRT_PCREG), Z2
  ADDQ $8, VIRT_PCREG
  VMOVDQA64 Z2, Z3
  JMP bccmpvf64(SB)


// Comparison Instructions - String
// --------------------------------

/*
(for our script to pick up the opcodes)
TEXT bccmpltstr(SB), NOSPLIT|NOFRAME, $0
TEXT bccmplestr(SB), NOSPLIT|NOFRAME, $0
TEXT bccmpgtstr(SB), NOSPLIT|NOFRAME, $0
TEXT bccmpgestr(SB), NOSPLIT|NOFRAME, $0
*/

#define BC_CMP_NAME bccmpltstr
#define BC_CMP_I_IMM VPCMP_IMM_LT
#include "evalbc_cmpxxstr_impl.h"
#undef BC_CMP_I_IMM
#undef BC_CMP_NAME

#define BC_CMP_NAME bccmplestr
#define BC_CMP_I_IMM VPCMP_IMM_LE
#include "evalbc_cmpxxstr_impl.h"
#undef BC_CMP_I_IMM
#undef BC_CMP_NAME

#define BC_CMP_NAME bccmpgtstr
#define BC_CMP_I_IMM VPCMP_IMM_GT
#include "evalbc_cmpxxstr_impl.h"
#undef BC_CMP_I_IMM
#undef BC_CMP_NAME

#define BC_CMP_NAME bccmpgestr
#define BC_CMP_I_IMM VPCMP_IMM_GE
#include "evalbc_cmpxxstr_impl.h"
#undef BC_CMP_I_IMM
#undef BC_CMP_NAME


// Comparison Instructions - Bool
// ------------------------------

#define BC_CMPXX_OP_K(predicate)     \
  MOVWLZX 0(VIRT_PCREG), BX          \
  MOVWLZX 0(VIRT_PCREG), DX          \
  VPBROADCASTB CONSTD_1(), X5        \
  KMOVW 0(VIRT_VALUES)(BX*1), K2     \
  KMOVW 0(VIRT_VALUES)(DX*1), K3     \
  VMOVDQU8.Z X5, K2, X4              \
  VMOVDQU8.Z X5, K3, X5              \
  VPCMPUB predicate, X5, X4, K1, K1

#define BC_CMPXX_OP_K_IMM(predicate) \
  MOVWLZX 0(VIRT_PCREG), BX          \
  VPBROADCASTB CONSTD_1(), X4        \
  VPBROADCASTB 0(VIRT_PCREG), X5     \
  KMOVW 0(VIRT_VALUES)(BX*1), K2     \
  VMOVDQU8.Z X4, K2, X4              \
  VPCMPUB predicate, X5, X4, K1, K1

TEXT bccmpltk(SB), NOSPLIT|NOFRAME, $0
  BC_CMPXX_OP_K($VPCMP_IMM_LT)
  NEXT_ADVANCE(4)

TEXT bccmpltimmk(SB), NOSPLIT|NOFRAME, $0
  BC_CMPXX_OP_K_IMM($VPCMP_IMM_LT)
  NEXT_ADVANCE(3)

TEXT bccmplek(SB), NOSPLIT|NOFRAME, $0
  BC_CMPXX_OP_K($VPCMP_IMM_LE)
  NEXT_ADVANCE(4)

TEXT bccmpleimmk(SB), NOSPLIT|NOFRAME, $0
  BC_CMPXX_OP_K_IMM($VPCMP_IMM_LE)
  NEXT_ADVANCE(3)

TEXT bccmpgtk(SB), NOSPLIT|NOFRAME, $0
  BC_CMPXX_OP_K($VPCMP_IMM_GT)
  NEXT_ADVANCE(4)

TEXT bccmpgtimmk(SB), NOSPLIT|NOFRAME, $0
  BC_CMPXX_OP_K_IMM($VPCMP_IMM_GT)
  NEXT_ADVANCE(3)

TEXT bccmpgek(SB), NOSPLIT|NOFRAME, $0
  BC_CMPXX_OP_K($VPCMP_IMM_GE)
  NEXT_ADVANCE(4)

TEXT bccmpgeimmk(SB), NOSPLIT|NOFRAME, $0
  BC_CMPXX_OP_K_IMM($VPCMP_IMM_GE)
  NEXT_ADVANCE(3)

#undef BC_CMPXX_OP_K_IMM
#undef BC_CMPXX_OP_K


// Comparison Instructions - Number
// --------------------------------

// computes cmp(Z2|Z3, f64imm)
#define BC_CMP_OP_F64_IMM(fPred)                  \
  VPBROADCASTQ 0(VIRT_PCREG), Z4                  \
  KSHIFTRW $8, K1, K2                             \
  VCMPPD fPred, Z4, Z2, K1, K1                    \
  VCMPPD fPred, Z4, Z3, K2, K2                    \
  KUNPCKBW K1, K2, K1                             \
                                                  \
  NEXT_ADVANCE(8)

// computes cmp(Z2|Z3, stack[slot])
#define BC_CMP_OP_I64(iPred)                      \
  MOVWQZX 0(VIRT_PCREG), R8                       \
  KSHIFTRW $8, K1, K2                             \
  VPCMPQ iPred, 0(VIRT_VALUES)(R8*1), Z2, K1, K1  \
  VPCMPQ iPred, 64(VIRT_VALUES)(R8*1), Z3, K2, K2 \
  KUNPCKBW K1, K2, K1                             \
                                                  \
  NEXT_ADVANCE(2)

// computes cmp(Z2|Z3, i64imm)
#define BC_CMP_OP_I64_IMM(iPred)                  \
  VPBROADCASTQ 0(VIRT_PCREG), Z4                  \
  KSHIFTRW $8, K1, K2                             \
  VPCMPQ iPred, Z4, Z2, K1, K1                    \
  VPCMPQ iPred, Z4, Z3, K2, K2                    \
  KUNPCKBW K1, K2, K1                             \
                                                  \
  NEXT_ADVANCE(8)

// Floating point equality in the sense that
// `-0 == 0`, `NaN == NaN`, and `-NaN != NaN`
TEXT bccmpeqf(SB), NOSPLIT|NOFRAME, $0
  MOVWQZX 0(VIRT_PCREG), R8
  KSHIFTRW $8, K1, K2

  VMOVUPD 0(VIRT_VALUES)(R8*1), Z4
  VMOVUPD 64(VIRT_VALUES)(R8*1), Z5

  // Floating point comparison handles `-0 == 0` properly
  VCMPPD $VCMP_IMM_EQ_OQ, Z4, Z2, K1, K3
  VCMPPD $VCMP_IMM_EQ_OQ, Z5, Z3, K2, K4

  // Integer comparison handles `NaN == NaN` properly
  VPCMPEQQ Z4, Z2, K1, K1
  VPCMPEQQ Z5, Z3, K2, K2

  KORW K3, K1, K1
  KORW K4, K2, K2
  KUNPCKBW K1, K2, K1

  NEXT_ADVANCE(2)

// current scalar float == f64(imm)
TEXT bccmpeqimmf(SB), NOSPLIT|NOFRAME, $0
  // We expect that the immediate is not NaN or -0 here. If the immediate
  // value is NaN 'bcisnanf' should be used instead. This gives us the
  // opportunity to make this function smaller as we know what the second
  // value isn't.
  BC_CMP_OP_F64_IMM($VCMP_IMM_EQ_OQ)

TEXT bccmpltf(SB), NOSPLIT|NOFRAME, $0
  // Implements `cmp_unordered_lt(a, b) ^ isnan(a)`:
  //   - `val < val` -> result
  //   - `NaN < val` -> false
  //   - `val < NaN` -> true
  //   - `NaN < NaN` -> false
  MOVWQZX 0(VIRT_PCREG), R8
  KSHIFTRW $8, K1, K2

  VCMPPD $VCMP_IMM_UNORD_Q, Z2, Z2, K1, K3
  VCMPPD $VCMP_IMM_UNORD_Q, Z3, Z3, K2, K4
  VCMPPD $VCMP_IMM_NGE_UQ, 0(VIRT_VALUES)(R8*1), Z2, K1, K1
  VCMPPD $VCMP_IMM_NGE_UQ, 64(VIRT_VALUES)(R8*1), Z3, K2, K2

  KUNPCKBW K3, K4, K3
  KUNPCKBW K1, K2, K1
  KXORW K3, K1, K1
  NEXT_ADVANCE(2)

TEXT bccmpltimmf(SB), NOSPLIT|NOFRAME, $0
  // `val < imm` -> result
  // `NaN < imm` -> false
  BC_CMP_OP_F64_IMM($VCMP_IMM_LT_OQ)

TEXT bccmplef(SB), NOSPLIT|NOFRAME, $0
  // Implements `cmp_ordered_le(a, b) | isnan(b)`:
  //   - `val <= val` -> result
  //   - `NaN <= val` -> false
  //   - `val <= NaN` -> true
  //   - `NaN <= NaN` -> true
  MOVWQZX 0(VIRT_PCREG), R8
  KSHIFTRW $8, K1, K2

  VMOVUPD 0(VIRT_VALUES)(R8*1), Z4
  VMOVUPD 64(VIRT_VALUES)(R8*1), Z5

  VCMPPD $VCMP_IMM_UNORD_Q, Z4, Z4, K1, K3
  VCMPPD $VCMP_IMM_UNORD_Q, Z5, Z5, K2, K4
  VCMPPD $VCMP_IMM_LE_OQ, Z4, Z2, K1, K1
  VCMPPD $VCMP_IMM_LE_OQ, Z5, Z3, K2, K2

  KUNPCKBW K3, K4, K3
  KUNPCKBW K1, K2, K1
  KORW K3, K1, K1
  NEXT_ADVANCE(2)

TEXT bccmpleimmf(SB), NOSPLIT|NOFRAME, $0
  // `val <= imm` -> result
  // `NaN <= imm` -> false
  BC_CMP_OP_F64_IMM($VCMP_IMM_LE_OQ)

TEXT bccmpgtf(SB), NOSPLIT|NOFRAME, $0
  // Implements `cmp_unordered_gt(a, b) ^ isnan(b)`
  //   - `val > val` -> result
  //   - `NaN > val` -> true
  //   - `val > NaN` -> false
  //   - `NaN > NaN` -> false
  MOVWQZX 0(VIRT_PCREG), R8
  KSHIFTRW $8, K1, K2

  VMOVUPD 0(VIRT_VALUES)(R8*1), Z4
  VMOVUPD 64(VIRT_VALUES)(R8*1), Z5

  VCMPPD $VCMP_IMM_UNORD_Q, Z4, Z4, K1, K3
  VCMPPD $VCMP_IMM_UNORD_Q, Z5, Z5, K2, K4
  VCMPPD $VCMP_IMM_NLE_UQ, Z4, Z2, K1, K1
  VCMPPD $VCMP_IMM_NLE_UQ, Z5, Z3, K2, K2

  KUNPCKBW K3, K4, K3
  KUNPCKBW K1, K2, K1
  KXORW K3, K1, K1
  NEXT_ADVANCE(2)

TEXT bccmpgtimmf(SB), NOSPLIT|NOFRAME, $0
  // `val > imm` -> result
  // `NaN > imm` -> true
  BC_CMP_OP_F64_IMM($VCMP_IMM_NLE_UQ)

TEXT bccmpgef(SB), NOSPLIT|NOFRAME, $0
  // Implements `cmp_ordered_ge(a, b) | isnan(a)`
  //   - `val >= val` -> result
  //   - `NaN >= val` -> true
  //   - `val >= NaN` -> false
  //   - `NaN >= NaN` -> true
  MOVWQZX 0(VIRT_PCREG), R8
  KSHIFTRW $8, K1, K2

  VCMPPD $VCMP_IMM_UNORD_Q, Z2, Z2, K1, K3
  VCMPPD $VCMP_IMM_UNORD_Q, Z3, Z3, K2, K4
  VCMPPD $VCMP_IMM_GE_OQ, 0(VIRT_VALUES)(R8*1), Z2, K1, K1
  VCMPPD $VCMP_IMM_GE_OQ, 64(VIRT_VALUES)(R8*1), Z3, K2, K2

  KUNPCKBW K3, K4, K3
  KUNPCKBW K1, K2, K1
  KXORW K3, K1, K1
  NEXT_ADVANCE(2)

TEXT bccmpgeimmf(SB), NOSPLIT|NOFRAME, $0
  // `val >= imm` -> result
  // `NaN >= imm` -> true
  BC_CMP_OP_F64_IMM($VCMP_IMM_NLT_UQ)

TEXT bccmpeqi(SB), NOSPLIT|NOFRAME, $0
  BC_CMP_OP_I64($VPCMP_IMM_EQ)

TEXT bccmpeqimmi(SB), NOSPLIT|NOFRAME, $0
  BC_CMP_OP_I64_IMM($VPCMP_IMM_EQ)

TEXT bccmplti(SB), NOSPLIT|NOFRAME, $0
  BC_CMP_OP_I64($VPCMP_IMM_LT)

TEXT bccmpltimmi(SB), NOSPLIT|NOFRAME, $0
  BC_CMP_OP_I64_IMM($VPCMP_IMM_LT)

TEXT bccmplei(SB), NOSPLIT|NOFRAME, $0
  BC_CMP_OP_I64($VPCMP_IMM_LE)

TEXT bccmpleimmi(SB), NOSPLIT|NOFRAME, $0
  BC_CMP_OP_I64_IMM($VPCMP_IMM_LE)

TEXT bccmpgti(SB), NOSPLIT|NOFRAME, $0
  BC_CMP_OP_I64($VPCMP_IMM_GT)

TEXT bccmpgtimmi(SB), NOSPLIT|NOFRAME, $0
  BC_CMP_OP_I64_IMM($VPCMP_IMM_GT)

TEXT bccmpgei(SB), NOSPLIT|NOFRAME, $0
  BC_CMP_OP_I64($VPCMP_IMM_GE)

TEXT bccmpgeimmi(SB), NOSPLIT|NOFRAME, $0
  BC_CMP_OP_I64_IMM($VPCMP_IMM_GE)

#undef BC_CMP_OP_F64_IMM
#undef BC_CMP_OP_I64_IMM
#undef BC_CMP_OP_I64


// Test Instructions
// -----------------

// isnanf(x) is the same as x != x
TEXT bcisnanf(SB), NOSPLIT|NOFRAME, $0
  KSHIFTRW $8, K1, K2
  VCMPPD $VCMP_IMM_NEQ_UQ, Z2, Z2, K1, K1
  VCMPPD $VCMP_IMM_NEQ_UQ, Z3, Z3, K2, K2
  KUNPCKBW K1, K2, K1
  NEXT()

// take the tag pointed to in Z30:Z31
// and determine if it contains _any_ of
// the immediate bits provided in the instruction
TEXT bcchecktag(SB), NOSPLIT|NOFRAME, $0
  MOVWLZX      0(VIRT_PCREG), R14
  VPBROADCASTD R14, Z14                // Z14 = tag bits
  KMOVW        K1, K3
  VPGATHERDD   0(SI)(Z30*1), K3, Z15   // Z15 = initial object bytes
  VPBROADCASTD CONSTD_1(), Z21
  VPSRLD       $4, Z15, Z15            // Z15 >>= 4
  VPANDD.BCST  CONSTD_0x0F(), Z15, Z15 // Z15 = (bytes >> 4) & 0xf
  VPSLLVD      Z15, Z21, Z15           // Z15 = 1 << ((bytes >> 4) & 0xf)
  VPTESTMD     Z14, Z15, K1, K1        // test tag&z15 != 0
  NEXT_ADVANCE(2)

// LUT for ion type bits -> json "type" bits
CONST_DATA_U8(consts_typebits_shuf, 0, $(1 << 0))  // null -> null
CONST_DATA_U8(consts_typebits_shuf, 1, $(1 << 1))  // bool -> bool
CONST_DATA_U8(consts_typebits_shuf, 2, $(1 << 2))  // uint -> number
CONST_DATA_U8(consts_typebits_shuf, 3, $(1 << 2))  // int -> number
CONST_DATA_U8(consts_typebits_shuf, 4, $(1 << 2))  // float -> number
CONST_DATA_U8(consts_typebits_shuf, 5, $(1 << 2))  // decimal -> number
CONST_DATA_U8(consts_typebits_shuf, 6, $(1 << 3))  // timestamp -> timestamp
CONST_DATA_U8(consts_typebits_shuf, 7, $(1 << 4))  // symbol -> string
CONST_DATA_U8(consts_typebits_shuf, 8, $(1 << 4))  // string -> string
CONST_DATA_U8(consts_typebits_shuf, 9, $0)         // clob is unused
CONST_DATA_U8(consts_typebits_shuf, 10, $0)        // blob is unused
CONST_DATA_U8(consts_typebits_shuf, 11, $(1 << 5)) // list -> list
CONST_DATA_U8(consts_typebits_shuf, 12, $0)        // sexp is unused
CONST_DATA_U8(consts_typebits_shuf, 13, $(1 << 6)) // struct -> struct
CONST_DATA_U8(consts_typebits_shuf, 14, $0)        // annotation is unused
CONST_DATA_U8(consts_typebits_shuf, 15, $0)        // reserved is unused
CONST_GLOBAL(consts_typebits_shuf, $16)

// turn the tag bits in z30:z31 into an integer
TEXT bctypebits(SB), NOSPLIT|NOFRAME, $0
  KMOVW         K1, K3
  VPXORD        Z15, Z15, Z15
  VPMOVZXBD     CONST_GET_PTR(consts_typebits_shuf, 0), Z14
  VPGATHERDD    0(SI)(Z30*1), K3, Z15   // Z15 = initial object bytes
  VPSRLD        $4, Z15, Z15            // Z15 >>= 4
  VPANDD.BCST   CONSTD_0x0F(), Z15, Z15 // Z15 = (bytes >> 4) & 0xf
  VPERMD.Z      Z14, Z15, K1, Z15       // Z15 = json type bits
  VPMOVZXDQ     Y15, Z2
  VEXTRACTI32X8 $1, Z15, Y15
  VPMOVZXDQ     Y15, Z3
  NEXT_ADVANCE(0)

// current value == NULL
TEXT bcisnull(SB), NOSPLIT|NOFRAME, $0
  // compute data[0]&0xf == 0xf
  KMOVW          K1, K2
  VPGATHERDD     0(SI)(Z30*1), K2, Z29
  VPBROADCASTD   CONSTD_0x0F(), Z28
  VPANDD         Z29, Z28, Z29
  VPCMPEQD       Z29, Z28, K1, K1
  NEXT()

// current value != NULL
TEXT bcisnotnull(SB), NOSPLIT|NOFRAME, $0
  // compute data[0]&0xf != 0xf
  KMOVW          K1, K2
  VPGATHERDD     0(SI)(Z30*1), K2, Z29
  VPBROADCASTD   CONSTD_0x0F(), Z28
  VPANDD         Z29, Z28, Z29
  VPCMPUD        $4, Z29, Z28, K1, K1
  NEXT()

TEXT bcistrue(SB), NOSPLIT|NOFRAME, $0
  KMOVW         K1, K2
  VPGATHERDD    0(SI)(Z30*1), K2, Z29
  VPANDD.BCST   CONSTD_0xFF(), Z29, Z29
  VPCMPEQD.BCST CONSTD_TRUE_BYTE(), Z29, K1, K1
  NEXT()

TEXT bcisfalse(SB), NOSPLIT|NOFRAME, $0
  KMOVW         K1, K2
  VPGATHERDD    0(SI)(Z30*1), K2, Z29
  VPANDD.BCST   CONSTD_0xFF(), Z29, Z29
  VPCMPEQD.BCST CONSTD_FALSE_BYTE(), Z29, K1, K1
  NEXT()

// compare slices in z2:z3 to saved slices
// (works identically for strings and timestamps)
TEXT bceqslice(SB), NOSPLIT|NOFRAME, $0
  LOADARG1Z(Z4, Z5)
  VMOVDQA32    Z2, Z6
  VMOVDQA32    Z3, Z7
  JMP          eqmem_tail(SB)

// compare slices z4:z5.k1 and z6:z7.k1 and return K1 equal mask
TEXT eqmem_tail(SB), NOSPLIT|NOFRAME, $0
  VPCMPEQD     Z7, Z5, K1, K1   // only bother comparing equal-length slices
  KTESTW       K1, K1
  JZ           next
  VPBROADCASTD CONSTD_4(), Z24
  VPXORD       Z10, Z10, Z10    // default behavior is 0 = 0 (matching)
  VPXORD       Z11, Z11, Z11
  JMP          loop4tail
loop4:
  KMOVW        K2, K3
  KMOVW        K2, K4
  VPGATHERDD   0(SI)(Z6*1), K2, Z10
  VPGATHERDD   0(SI)(Z4*1), K3, Z11
  VPCMPEQD     Z10, Z11, K1, K1 // matching &= words are equal
  KANDW        K1, K4, K4
  VPADDD       Z24, Z4, K4, Z4  // offsets += 4
  VPADDD       Z24, Z6, K4, Z6
  VPSUBD       Z24, Z7, K4, Z7  // lengths -= 4
  VPSUBD       Z24, Z5, K4, Z5
loop4tail:
  VPCMPD          $VPCMP_IMM_GE, Z24, Z7, K1, K2 // K2 = matching lanes w/ length >= 4
  KTESTW          K2, K2
  JNZ             loop4
  // test final 4 bytes w/ mask
  VPTESTMD        Z7, Z7, K1, K2          // only load lanes w/ length > 0
  VBROADCASTI64X2 tail_mask_map<>(SB), Z9
  VPERMD          Z9, Z7, Z9
  KMOVW           K2, K3
  VPGATHERDD      0(SI)(Z6*1), K2, Z10
  VPGATHERDD      0(SI)(Z4*1), K3, Z11
  VPANDD          Z9, Z10, Z10
  VPANDD          Z9, Z11, Z11
  VPCMPEQD        Z10, Z11, K1, K1
next:
  NEXT()

// equal(Z30:Z31, stack[imm])
TEXT bcequalv(SB), NOSPLIT|NOFRAME, $0
  LOADARG1Z(Z4, Z5)
  VMOVDQA32.Z  Z30, K1, Z6
  VMOVDQA32.Z  Z31, K1, Z7
  JMP          eqmem_tail(SB)

// given 4-byte immediate and mask,
// compute K1 = (*value)&mask == imm
TEXT bceqv4mask(SB), NOSPLIT|NOFRAME, $0
  KMOVW         K1, K2
  VPGATHERDD    0(SI)(Z30*1), K2, Z26
  VPANDD.BCST   4(VIRT_PCREG), Z26, Z26
  VPCMPEQD.BCST 0(VIRT_PCREG), Z26, K1, K1
  LEAQ          4(SI), R8
  NEXT_ADVANCE(8)

// same as above, but use 'R8'
// as an additional pre-increment
// displacement for longer literal
// comparisons
TEXT bceqv4maskplus(SB), NOSPLIT|NOFRAME, $0
  KMOVW         K1, K2
  VPGATHERDD    0(R8)(Z30*1), K2, Z26
  VPANDD.BCST   4(VIRT_PCREG), Z26, Z26
  VPCMPEQD.BCST 0(VIRT_PCREG), Z26, K1, K1
  LEAQ          4(R8), R8
  NEXT_ADVANCE(8)

// begin a comparison with 8 literal bytes,
// resetting the displacement reg
TEXT bceqv8(SB), NOSPLIT|NOFRAME, $0
  KMOVW         K1, K2
  VPGATHERDD    0(SI)(Z30*1), K2, Z26
  VPCMPEQD.BCST 0(VIRT_PCREG), Z26, K1, K1
  KMOVW         K1, K2
  VPGATHERDD    4(SI)(Z30*1), K2, Z26
  VPCMPEQD.BCST 4(VIRT_PCREG), Z26, K1, K1
  LEAQ          8(SI), R8
  NEXT_ADVANCE(8)

// continue a comparison op with 8 more literal bytes
TEXT bceqv8plus(SB), NOSPLIT|NOFRAME, $0
  KMOVW         K1, K2
  VPGATHERDD    0(R8)(Z30*1), K2, Z26
  VPCMPEQD.BCST 0(VIRT_PCREG), Z26, K1, K1
  KMOVW         K1, K2
  VPGATHERDD    4(R8)(Z30*1), K2, Z26
  VPCMPEQD.BCST 4(VIRT_PCREG), Z26, K1, K1
  LEAQ          8(R8), R8
  NEXT_ADVANCE(8)

// select only values where length==imm
TEXT bcleneq(SB), NOSPLIT|NOFRAME, $0
  VPCMPEQD.BCST 0(VIRT_PCREG), Z31, K1, K1
  NEXT_ADVANCE(4)

// Timestamp Boxing, Unboxing, and Manipulation
// ============================================
//
// First some constants:
//
//   - [0x0000000000000E10] 3600            <- 60 * 60                    (number of seconds per 1 hour)
//   - [0x00000000D693A400] 3600000000      <- 60 * 60 * 1e6              (number of microseconds per 1 hour)
//
//   - [0x0000000000015180] 86400           <- 60 * 60 * 24               (number of seconds per 1 day)
//   - [0x000000141DD76000] 86400000000     <- 60 * 60 * 24 * 1e6         (number of microseconds per 1 day)
//
//   - [0x00000000000005B5] 1461            <- 356 * 4   + 1              (number of days per 4 years cycle)
//   - [0x0000000000008EAC] 36524           <- 356 * 100 + 24             (number of days per 100 years cycle)
//   - [0x0000000000023AB1] 146097          <- 356 * 400 + 97             (number of days per 400 years cycle)
//
//   - [0x0000000000002B09] 11017           <- 10957 + 31 + 29            (number of days between 1970-01-01 and 2000-03-01)
//   - [0x0000000038BC5D80] 951868800       <- 11017 * 60 * 60 * 24       (number of seconds between 1970-01-01 and 2000-03-01)
//   - [0x0D35B7A160C70000] 951868800000000 <- 11017 * 60 * 60 * 24 * 1e6 (number of microseconds between 1970-01-01 and 2000-03-01)
//
// Divide/Modulo with a number that has N zero least significant bits can rewritten in the following way:
//
//   - Division:
//       C = A / B
//       C = (A >> N) / (B >> N)
//
//   - Modulo:
//       C = A % B
//       C = (((A >> N) % (B >> N)) << N) + (A & (N - 1))
//
// Which means that we don't need a 64-bit division with full precision (like the one that we implemented
// for integer pipeline) to decompose a timestamp value, because we can always cut the bits we are not
// interested in and use them later. In addition, unix time with microseconds precision has an interesting
// property - after we truncate the timestamp into day, it's guaranteed that the rest (Year/Month/Day
// combined) fits into a 32-bit integer, because the number of microseconds per day exceeds a 32-bit integer
// range, so there is less bits for representing the rest of the timestamp, which we later decompose to year,
// month, and day of month.
//
// Resources
// ---------
//
//  - https://howardhinnant.github.io/date_algorithms.html - The best resource for composing / decomposing.

#define BC_DIV_U32_RCP_2X(OUT1, OUT2, IN1, IN2, RCP, N_SHR)                      \
  VPMULUDQ RCP, IN1, OUT1                                                        \
  VPMULUDQ RCP, IN2, OUT2                                                        \
  VPSRLQ $(N_SHR), OUT1, OUT1                                                    \
  VPSRLQ $(N_SHR), OUT2, OUT2

#define BC_DIV_U32_RCP_2X_MASKED(OUT1, OUT2, IN1, IN2, RCP, N_SHR, MASK1, MASK2) \
  VPMULUDQ RCP, IN1, MASK1, OUT1                                                 \
  VPMULUDQ RCP, IN2, MASK2, OUT2                                                 \
  VPSRLQ $(N_SHR), OUT1, MASK1, OUT1                                             \
  VPSRLQ $(N_SHR), OUT2, MASK2, OUT2

// calculates `OUT = IN % DIVISOR` as `OUT = IN - ((IN * RCP) / N_SHR) * DIVISOR`
#define BC_MOD_U32_RCP_2X(OUT1, OUT2, IN1, IN2, DIVISOR, RCP, N_SHR, TMP1, TMP2) \
  VPMULUDQ RCP, IN1, TMP1                                                        \
  VPMULUDQ RCP, IN2, TMP2                                                        \
  VPSRLQ $(N_SHR), TMP1, TMP1                                                    \
  VPSRLQ $(N_SHR), TMP2, TMP2                                                    \
  VPMULUDQ DIVISOR, TMP1, TMP1                                                   \
  VPMULUDQ DIVISOR, TMP2, TMP2                                                   \
  VPSUBQ TMP1, IN1, OUT1                                                         \
  VPSUBQ TMP2, IN2, OUT2

#define BC_MOD_U32_RCP_2X_MASKED(OUT1, OUT2, IN1, IN2, DIVISOR, RCP, N_SHR, MASK1, MASK2, TMP1, TMP2) \
  VPMULUDQ RCP, IN1, TMP1                                                                             \
  VPMULUDQ RCP, IN2, TMP2                                                                             \
  VPSRLQ $(N_SHR), TMP1, TMP1                                                                         \
  VPSRLQ $(N_SHR), TMP2, TMP2                                                                         \
  VPMULUDQ DIVISOR, TMP1, TMP1                                                                        \
  VPMULUDQ DIVISOR, TMP2, TMP2                                                                        \
  VPSUBQ TMP1, IN1, MASK1, OUT1                                                                       \
  VPSUBQ TMP2, IN2, MASK2, OUT2

#define BC_DIV_U64_WITH_CONST_RECIPROCAL_BCST(DST_A, DST_B, SRC_A, SRC_B, RECIP, N_SHR) \
  VPMULLQ.BCST RECIP, SRC_A, DST_A \
  VPMULLQ.BCST RECIP, SRC_B, DST_B \
                                   \
  VPSRLQ $(N_SHR), DST_A, DST_A    \
  VPSRLQ $(N_SHR), DST_B, DST_B

#define BC_DIV_U64_WITH_CONST_RECIPROCAL_BCST_MASKED(DST_A, DST_B, SRC_A, SRC_B, MASK_A, MASK_B, RECIP, N_SHR) \
  VPMULLQ.BCST RECIP, SRC_A, MASK_A, DST_A \
  VPMULLQ.BCST RECIP, SRC_B, MASK_B, DST_B \
                                           \
  VPSRLQ $(N_SHR), DST_A, MASK_A, DST_A    \
  VPSRLQ $(N_SHR), DST_B, MASK_B, DST_B

// Inputs
//   Z2/Z3   - Input timestamp.
//   K1/K2   - Input mask.
//
// Outputs:
//   Z4/Z5   - Microseconds of the day (combines hours, minutes, seconds, microseconds).
//   Z8/Z9   - Year index.
//   Z10/Z11 - Month index - starting from zero, where zero represents March.
//   Z14/Z15 - Day of month - starting from zero.
//
// Clobbers:
//   Z4...Z19
//   K Regs (TODO: Specify)
#define BC_DECOMPOSE_TIMESTAMP_PARTS(INPUT1, INPUT2)                                        \
  /* First cut off some bits that we don't need to calculate Year/Month/Day. */             \
  VPSRAQ.Z $13, INPUT1, K1, Z4                                                              \
  VPSRAQ.Z $13, INPUT2, K2, Z5                                                              \
                                                                                            \
  VPBROADCASTQ CONSTQ_1970_01_01_TO_0000_03_01_US_OFFSET_SHR_13(), Z14                      \
  VBROADCASTSD CONSTF64_MICROSECONDS_IN_1_DAY_SHR_13(), Z15                                 \
                                                                                            \
  /* Adjust the value so we always end up with unsigned days count, we want to have */      \
  /* positive 400 years cycles. */                                                          \
  VPADDQ Z14, Z4, Z4                                                                        \
  VPADDQ Z14, Z5, Z5                                                                        \
                                                                                            \
  /* Convert to double precision so we can divide. */                                       \
  VCVTUQQ2PD Z4, Z6                                                                         \
  VCVTUQQ2PD Z5, Z7                                                                         \
                                                                                            \
  /* Z8/Z9 <- Get the number of days: */                                                    \
  /*       <- floor(float64(input >> 13) / float64((60 * 60 * 24 * 1000000) >> 13)). */     \
  VDIVPD.RD_SAE Z15, Z6, Z8                                                                 \
  VDIVPD.RD_SAE Z15, Z7, Z9                                                                 \
                                                                                            \
  VRNDSCALEPD $VROUND_IMM_DOWN_SAE, Z8, Z8                                                  \
  VRNDSCALEPD $VROUND_IMM_DOWN_SAE, Z9, Z9                                                  \
                                                                                            \
  /* Z12/Z13 - Number of days as integers (adjusted to be unsigned). */                     \
  /*           In this case, always less than 2^32. */                                      \
  VCVTPD2UQQ Z8, Z12                                                                        \
  VCVTPD2UQQ Z9, Z13                                                                        \
                                                                                            \
  /* Z6/Z7 <- Number of (hours, minutes, seconds, and microseconds) >> 13. */               \
  VMULPD Z15, Z8, Z16                                                                       \
  VMULPD Z15, Z9, Z17                                                                       \
  VSUBPD Z16, Z6, Z6                                                                        \
  VSUBPD Z17, Z7, Z7                                                                        \
  VCVTPD2UQQ Z6, Z6                                                                         \
  VCVTPD2UQQ Z7, Z7                                                                         \
                                                                                            \
  /* Z4/Z5 <- Number of hours, minutes, seconds, and microseconds. */                       \
  /*          VPTERNLOG(0xD8) = (A & ~C) | (B & C) */                                       \
  VPSLLQ $13, Z6, Z4                                                                        \
  VPSLLQ $13, Z7, Z5                                                                        \
  VPTERNLOGQ.BCST $0xD8, CONSTQ_0x1FFF(), INPUT1, Z4                                        \
  VPTERNLOGQ.BCST $0xD8, CONSTQ_0x1FFF(), INPUT2, Z5                                        \
                                                                                            \
  /* Z8/Z9 <- Number of 400Y cycles. */                                                     \
  BC_DIV_U64_WITH_CONST_RECIPROCAL_BCST(Z8, Z9, Z12, Z13, CONSTQ_963315389(), 47)           \
                                                                                            \
  /* Z14/Z15 <- Remaining days [0, 146096]. */                                              \
  VPMULLQ.BCST CONSTQ_146097(), Z8, Z14                                                     \
  VPMULLQ.BCST CONSTQ_146097(), Z9, Z15                                                     \
  VPSUBQ Z14, Z12, Z14                                                                      \
  VPSUBQ Z15, Z13, Z15                                                                      \
                                                                                            \
  /* Z10/Z11 <- Number of 100Y cycles [0, 3]. */                                            \
  VPSRLQ $2, Z14, Z10                                                                       \
  VPSRLQ $2, Z15, Z11                                                                       \
  BC_DIV_U64_WITH_CONST_RECIPROCAL_BCST(Z10, Z11, Z10, Z11, CONSTQ_963321983(), 43)         \
  VPMINUQ.BCST CONSTQ_3(), Z10, Z10                                                         \
  VPMINUQ.BCST CONSTQ_3(), Z11, Z11                                                         \
                                                                                            \
  /* Z14/Z15 <- Remaining days. */                                                          \
  VPMULLQ.BCST CONSTQ_36524(), Z10, Z16                                                     \
  VPMULLQ.BCST CONSTQ_36524(), Z11, Z17                                                     \
  VPSUBQ Z16, Z14, Z14                                                                      \
  VPSUBQ Z17, Z15, Z15                                                                      \
                                                                                            \
  /* K3/K4 <- 100YCycles != 0. */                                                           \
  VPTESTMQ Z10, Z10, K1, K3                                                                 \
  VPTESTMQ Z11, Z11, K2, K4                                                                 \
                                                                                            \
  /* Z8/Z9 <- 400Y_Cycles * 400. */                                                         \
  VPMULLQ.BCST CONSTQ_400(), Z8, Z8                                                         \
  VPMULLQ.BCST CONSTQ_400(), Z9, Z9                                                         \
                                                                                            \
  /* Z12/Z13 <- Number of 4Y cycles [0, 24]. */                                             \
  BC_DIV_U64_WITH_CONST_RECIPROCAL_BCST(Z12, Z13, Z14, Z15, CONSTQ_376287347(), 39)         \
  VPMINUQ.BCST CONSTQ_24(), Z12, Z12                                                        \
  VPMINUQ.BCST CONSTQ_24(), Z13, Z13                                                        \
                                                                                            \
  /* Z10/Z11 <- 100Y_Cycles * 100. */                                                       \
  VPMULLQ.BCST CONSTQ_100(), Z10, Z10                                                       \
  VPMULLQ.BCST CONSTQ_100(), Z11, Z11                                                       \
                                                                                            \
  /* Z14/Z15 <- Remaining days. */                                                          \
  VPMULLQ.BCST CONSTQ_1461(), Z12, Z16                                                      \
  VPMULLQ.BCST CONSTQ_1461(), Z13, Z17                                                      \
  VPSUBQ Z16, Z14, Z14                                                                      \
  VPSUBQ Z17, Z15, Z15                                                                      \
                                                                                            \
  /* Z8/Z9 <- 400Y_Cycles * 400 + 100Y_Cycles * 100. */                                     \
  VPADDQ Z10, Z8, Z8                                                                        \
  VPADDQ Z11, Z9, Z9                                                                        \
                                                                                            \
  /* K3/K4 <- 100YCycles != 0 && 4YCycles == 0. */                                          \
  VPTESTNMQ Z12, Z12, K3, K3                                                                \
  VPTESTNMQ Z13, Z13, K4, K4                                                                \
                                                                                            \
  /* Z12/Z13 <- 4YCycles * 4. */                                                            \
  VPSLLQ $2, Z12, Z12                                                                       \
  VPSLLQ $2, Z13, Z13                                                                       \
                                                                                            \
  /* Z8/Z9 <- 400Y_Cycles * 400 + 100Y_Cycles * 100 + 4YCycles * 4. */                      \
  VPADDQ Z12, Z8, Z8                                                                        \
  VPADDQ Z13, Z9, Z9                                                                        \
                                                                                            \
  /* Z16/Z17 <- Remaining years of the 4Y cycle [0, 3]. */                                  \
  BC_DIV_U64_WITH_CONST_RECIPROCAL_BCST(Z16, Z17, Z14, Z15, CONSTQ_45965(), 24)             \
  VPMINUQ.BCST CONSTQ_3(), Z16, Z16                                                         \
  VPMINUQ.BCST CONSTQ_3(), Z17, Z17                                                         \
                                                                                            \
  /* K3/K4 <- !(100YCycles != 0 && 4YCycles == 0). */                                       \
  KNOTW K3, K3                                                                              \
  KNOTW K4, K4                                                                              \
                                                                                            \
  /* Z8/Z9 <- 400Y_Cycles * 400 + 100Y_Cycles * 100 + 4YCycles * 4 + Remaining_Years. */    \
  VPADDQ Z16, Z8, Z8                                                                        \
  VPADDQ Z17, Z9, Z9                                                                        \
                                                                                            \
  /* K3/K4 - !(100YCycles != 0 && 4YCycles == 0) && RemainingYearsInLast4YCycle == 0. */    \
  VPTESTNMQ Z16, Z16, K3, K3                                                                \
  VPTESTNMQ Z17, Z17, K4, K4                                                                \
                                                                                            \
  /* Z14/Z15 <- Remaining days [0, 366]. */                                                 \
  VPMULLQ.BCST CONSTQ_365(), Z16, Z18                                                       \
  VPMULLQ.BCST CONSTQ_365(), Z17, Z19                                                       \
  VPSUBQ Z18, Z14, Z14                                                                      \
  VPSUBQ Z19, Z15, Z15                                                                      \
                                                                                            \
  /* Z10/Z11 <- Months (starting from 0, where 0 represents March at this point). */        \
  /* The following equation is used to calculate months: `5 * RemainingDays + 2) / 153` */  \
  VPSLLQ $2, Z14, Z10                                                                       \
  VPADDQ.BCST CONSTQ_2(), Z14, Z12                                                          \
  VPSLLQ $2, Z15, Z11                                                                       \
  VPADDQ.BCST CONSTQ_2(), Z15, Z13                                                          \
  VPADDQ Z10, Z12, Z12                                                                      \
  VPADDQ Z11, Z13, Z13                                                                      \
  BC_DIV_U64_WITH_CONST_RECIPROCAL_BCST(Z10, Z11, Z12, Z13, CONSTQ_3593175255(), 39)        \
                                                                                            \
  /* Z14/Z15 <- Remaining days respecting the month in Z10/Z11. */                          \
  VMOVDQU64 CONST_GET_PTR(consts_days_until_month_from_march, 0), Z13                       \
  VPERMD Z13, Z10, Z12                                                                      \
  VPERMD Z13, Z11, Z13                                                                      \
  VPSUBQ Z12, Z14, Z14                                                                      \
  VPSUBQ Z13, Z15, Z15

// Years are ADDED to DST_DAYS_A and DST_DAYS_B.
//
// The input year is a year that uses March as its first month (as used in other functions).
#define BC_COMPOSE_YEAR_TO_DAYS(DST_DAYS_A, DST_DAYS_B, YEAR_A, YEAR_B, TMP_A1, TMP_B1, TMP_A2, TMP_B2, TMP_A3, TMP_B3) \
  /* TMP_A1/B1 <- Number of 400Y cycles (era). */                                           \
  VPMULLQ.BCST CONSTQ_1374389535(), YEAR_A, TMP_A1                                          \
  VPMULLQ.BCST CONSTQ_1374389535(), YEAR_B, TMP_B1                                          \
  VPSRAQ $39, TMP_A1, TMP_A1                                                                \
  VPSRAQ $39, TMP_B1, TMP_B1                                                                \
                                                                                            \
  /* TMP_A2/B2 <- Number of years in the last 400Y era [0, 399]. */                         \
  VPMULLQ.BCST CONSTQ_400(), TMP_A1, TMP_A2                                                 \
  VPMULLQ.BCST CONSTQ_400(), TMP_B1, TMP_B2                                                 \
  VPSUBQ TMP_A2, YEAR_A, TMP_A2                                                             \
  VPSUBQ TMP_B2, YEAR_B, TMP_B2                                                             \
                                                                                            \
  /* DST_DAYS_A/B - Increment full 400Y cycles converted to days. */                        \
  VPMULLQ.BCST CONSTQ_146097(), TMP_A1, TMP_A3                                              \
  VPMULLQ.BCST CONSTQ_146097(), TMP_B1, TMP_B3                                              \
  VPADDQ TMP_A3, DST_DAYS_A, DST_DAYS_A                                                     \
  VPADDQ TMP_B3, DST_DAYS_B, DST_DAYS_B                                                     \
                                                                                            \
  /* DST_DAYS_A/B - Increment days of the last era: YOE * 365 + YOE / 4 - YOE / 100. */     \
  VPMULLQ.BCST CONSTQ_365(), TMP_A2, TMP_A1                                                 \
  VPMULLQ.BCST CONSTQ_365(), TMP_B2, TMP_B1                                                 \
  VPMULLQ.BCST CONSTQ_1374389535(), TMP_A2, TMP_A3                                          \
  VPMULLQ.BCST CONSTQ_1374389535(), TMP_B2, TMP_B3                                          \
                                                                                            \
  VPSRLQ $2, TMP_A2, TMP_A2                                                                 \
  VPSRLQ $2, TMP_B2, TMP_B2                                                                 \
  VPSRLQ $37, TMP_A3, TMP_A3                                                                \
  VPSRLQ $37, TMP_B3, TMP_B3                                                                \
                                                                                            \
  VPADDQ TMP_A1, DST_DAYS_A, DST_DAYS_A                                                     \
  VPADDQ TMP_B1, DST_DAYS_B, DST_DAYS_B                                                     \
  VPADDQ TMP_A2, DST_DAYS_A, DST_DAYS_A                                                     \
  VPADDQ TMP_B2, DST_DAYS_B, DST_DAYS_B                                                     \
                                                                                            \
  VPSUBQ TMP_A3, DST_DAYS_A, DST_DAYS_A                                                     \
  VPSUBQ TMP_B3, DST_DAYS_B, DST_DAYS_B

// DATE_ADD(MONTH|YEAR, interval, timestamp)
//
// If the datepart is less than month we don't have to decompose. In that case we just
// reuse the existing `bcaddi` and `bcaddimmi` instructions, which are timestamp agnostic.
//
// We don't really need a specific code for adding years, as `year == month * 12`. This
// means that we can just convert years to months and add `year * 12` months and be done.
TEXT bcdateaddmonth(SB), NOSPLIT|NOFRAME, $0
  MOVWQZX 0(VIRT_PCREG), R8
  ADDQ $2, VIRT_PCREG
  VMOVDQU64 0(VIRT_VALUES)(R8*1), Z20
  VMOVDQU64 64(VIRT_VALUES)(R8*1), Z21
  JMP dateaddmonth_tail(SB)

TEXT bcdateaddmonthimm(SB), NOSPLIT|NOFRAME, $0
  VPBROADCASTQ 0(VIRT_PCREG), Z20
  ADDQ $8, VIRT_PCREG
  VMOVDQA64 Z20, Z21
  JMP dateaddmonth_tail(SB)

TEXT bcdateaddyear(SB), NOSPLIT|NOFRAME, $0
  MOVWQZX 0(VIRT_PCREG), R8
  ADDQ $2, VIRT_PCREG

  // multiply years by 12
  VPSLLQ $3, 0(VIRT_VALUES)(R8*1), Z20
  VPSLLQ $3, 64(VIRT_VALUES)(R8*1), Z21
  VPSRLQ $1, Z20, Z4
  VPSRLQ $1, Z21, Z5
  VPADDQ Z4, Z20, Z20
  VPADDQ Z5, Z21, Z21

  JMP dateaddmonth_tail(SB)

TEXT bcdateaddquarter(SB), NOSPLIT|NOFRAME, $0
  MOVWQZX 0(VIRT_PCREG), R8
  ADDQ $2, VIRT_PCREG

  // multiply quarters by 3
  VMOVDQU64 0(VIRT_VALUES)(R8*1), Z20
  VMOVDQU64 64(VIRT_VALUES)(R8*1), Z21
  VPSLLQ $1, Z20, Z4
  VPSLLQ $1, Z21, Z5
  VPADDQ Z4, Z20, Z20
  VPADDQ Z5, Z21, Z21

  JMP dateaddmonth_tail(SB)

// Tail instruction implementing DATE_ADD(MONTH, interval, timestamp).
//
// Inputs:
//   K1      - 16-bit mask
//   Z2/Z3   - Timestamp values
//   Z20/Z21 - Months to add
TEXT dateaddmonth_tail(SB), NOSPLIT|NOFRAME, $0
  KSHIFTRW $8, K1, K2

  // --- Decompose the timestamp ---

  // Z4/Z5   - Microseconds of the day (combines hours, minutes, seconds, microseconds).
  // Z8/Z9   - Year index.
  // Z10/Z11 - Month index - starting from zero, where zero represents March.
  // Z14/Z15 - Day of month - starting from zero.
  BC_DECOMPOSE_TIMESTAMP_PARTS(Z2, Z3)

  // -- Perform the addition ---

  // Z10/Z11 <- months combined (could be within a range, negative, or greater than 11).
  VPADDQ Z20, Z10, Z10
  VPADDQ Z21, Z11, Z11

  // Load some constants.
  VBROADCASTSD CONSTF64_12(), Z20
  VPXORQ X21, X21, X21

  // Z12/Z13 <- Years difference (int).
  VCVTQQ2PD Z10, Z12
  VCVTQQ2PD Z11, Z13

  VCMPPD $VCMP_IMM_LT_OQ, Z21, Z10, K3
  VCMPPD $VCMP_IMM_LT_OQ, Z21, Z11, K4

  VSUBPD.BCST CONSTF64_11(), Z12, K3, Z12
  VSUBPD.BCST CONSTF64_11(), Z13, K4, Z13

  VDIVPD.RD_SAE Z20, Z12, Z12
  VDIVPD.RD_SAE Z20, Z13, Z13

  VCVTPD2QQ.RD_SAE Z12, Z12
  VCVTPD2QQ.RD_SAE Z13, Z13

  // Z8/Z9 <- Final years (int).
  VPADDQ Z12, Z8, Z8
  VPADDQ Z13, Z9, Z9

  // Z10/Z11 <- Corrected month index [0, 11] (where 0 represents March).
  VPMULLQ.BCST CONSTQ_12(), Z12, Z12
  VPMULLQ.BCST CONSTQ_12(), Z13, Z13

  VPSUBQ Z12, Z10, Z10
  VPSUBQ Z13, Z11, Z11

  // --- Compose the timestamp ---

  // Z6/Z7 <- Number of days of the last year (months + day of month).
  VMOVDQU64 CONST_GET_PTR(consts_days_until_month_from_march, 0), Z13
  VPERMD Z13, Z10, Z12
  VPERMD Z13, Z11, Z13
  VPADDQ Z12, Z14, Z6
  VPADDQ Z13, Z15, Z7

  // Z6/Z7 <- Final number of days.
  BC_COMPOSE_YEAR_TO_DAYS(Z6, Z7, Z8, Z9, Z10, Z11, Z12, Z13, Z14, Z15)

  // Z6/Z7 <- Final number of days converted to microseconds.
  VPMULLQ.BCST CONSTQ_86400000000(), Z6, Z6
  VPMULLQ.BCST CONSTQ_86400000000(), Z7, Z7

  // Z6/Z7 <- Combined microseconds of all days and microseconds of the remaining day.
  VPADDQ Z4, Z6, Z6
  VPADDQ Z5, Z7, Z7

  // Z2/Z3 <- Make it a unix timestamp starting from 1970-01-01.
  VPSUBQ.BCST CONSTQ_1970_01_01_TO_0000_03_01_US_OFFSET(), Z6, K1, Z2
  VPSUBQ.BCST CONSTQ_1970_01_01_TO_0000_03_01_US_OFFSET(), Z7, K2, Z3

  NEXT()

// DATE_DIFF(DAY|HOUR|MINUTE|SECOND|MILLISECOND, t1, t2)
TEXT bcdatediffparam(SB), NOSPLIT|NOFRAME, $0
  MOVWQZX 0(VIRT_PCREG), R8
  VPBROADCASTQ 2(VIRT_PCREG), Z6

  KSHIFTRW $8, K1, K2

  VMOVDQU64 0(VIRT_VALUES)(R8*1), Z4
  VMOVDQU64 64(VIRT_VALUES)(R8*1), Z5

  VPSUBQ Z2, Z4, Z4
  VPSUBQ Z3, Z5, Z5

  // We never need the last 3 bits of the value, so cut it off to increase precision.
  VPSRAQ $3, Z6, Z6
  VPSRAQ $3, Z4, Z4
  VPSRAQ $3, Z5, Z5

  VCVTQQ2PD.RD_SAE Z6, Z6
  VCVTQQ2PD.RD_SAE Z4, Z4
  VCVTQQ2PD.RD_SAE Z5, Z5

  VDIVPD.RZ_SAE Z6, Z4, Z4
  VDIVPD.RZ_SAE Z6, Z5, Z5

  VCVTPD2QQ.RZ_SAE Z4, K1, Z2
  VCVTPD2QQ.RZ_SAE Z5, K2, Z3

  NEXT_ADVANCE(10)

// DATE_DIFF(MONTH|QUARTER|YEAR, interval, timestamp)
TEXT bcdatediffmonthyear(SB), NOSPLIT|NOFRAME, $0
  MOVWQZX 0(VIRT_PCREG), R8
  KSHIFTRW $8, K1, K2

  VMOVDQU64 0(VIRT_VALUES)(R8*1), Z4
  VMOVDQU64 64(VIRT_VALUES)(R8*1), Z5

  MOVWQZX 2(VIRT_PCREG), R8
  LEAQ CONST_GET_PTR(consts_datediff_month_year_div_rcp, 0), R15

  // First make the first timestamp lesser and the second greater. This would give us always
  // a positive difference, which we would negate at the end, where required. This makes it
  // a bit easier to implement months difference as specified in PartiQL SQL reference.
  VPCMPQ $VPCMP_IMM_GT, Z4, Z2, K1, K5
  VPCMPQ $VPCMP_IMM_GT, Z5, Z3, K2, K6

  // Z20/Z21 <- Greater timestamp.
  VPMAXSQ Z2, Z4, Z20
  VPMAXSQ Z3, Z5, Z21

  // Z2/Z3 <- Lesser timestamp.
  VPMINSQ Z2, Z4, K1, Z2
  VPMINSQ Z3, Z5, K2, Z3

  // Decomposed lesser timestamp:
  //   Z4/Z5   - Microseconds of the day (combines hours, minutes, seconds, microseconds).
  //   Z8/Z9   - Year index.
  //   Z10/Z11 - Month index - starting from zero, where zero represents March.
  //   Z14/Z15 - Day of month - starting from zero.
  BC_DECOMPOSE_TIMESTAMP_PARTS(Z2, Z3)

  // Z22/Z23 <- Lesser timestamp's 'Year * 12 + MonthIndex'.
  VPMULLQ.BCST CONSTQ_12(), Z8, Z8
  VPMULLQ.BCST CONSTQ_12(), Z9, Z9
  VPADDQ Z8, Z10, Z22
  VPADDQ Z9, Z11, Z23

  // Z4/Z5 <- Greater timestamp's value decremented by hours/minutes/... from the lesser timestamp.
  VPSUBQ Z4, Z20, Z4
  VPSUBQ Z5, Z21, Z5

  // Z20/Z21 <- Saved lesser timestamp's day of month, so we can use it later.
  VMOVDQA64 Z14, Z20
  VMOVDQA64 Z15, Z21

  // Decomposed greater timestamp:
  //   Z4/Z5   - Microseconds of the day (combines hours, minutes, seconds, microseconds).
  //   Z8/Z9   - Year index.
  //   Z10/Z11 - Month index - starting from zero, where zero represents March.
  //   Z14/Z15 - Day of month - starting from zero.
  BC_DECOMPOSE_TIMESTAMP_PARTS(Z4, Z5)

  // Z10/Z11 <- Greater timestamp's 'Year * 12 + MonthIndex'.
  VPMULLQ.BCST CONSTQ_12(), Z8, Z8
  VPMULLQ.BCST CONSTQ_12(), Z9, Z9
  VPADDQ Z8, Z10, Z10
  VPADDQ Z9, Z11, Z11

  // Z4/Z5 <- Rough months difference (greater timestamp - lesser timestamp).
  VPSUBQ Z22, Z10, Z4
  VPSUBQ Z23, Z11, Z5

  // Z4/Z5 <- Rough months difference - 1.
  VPSUBQ.BCST CONSTQ_1(), Z4, Z4
  VPSUBQ.BCST CONSTQ_1(), Z5, Z5

  // Z10 <- Zeros
  // Z11 <- Multiplier used to implement the same bytecode for MONTH and YEAR difference.
  VPXORQ X10, X10, X10
  VPBROADCASTQ 0(R15)(R8 * 8), Z11

  // Increment one month if the lesser timestamp's day of month <= greater timestamp's day of month.
  VPCMPQ $VPCMP_IMM_GE, Z20, Z14, K3
  VPCMPQ $VPCMP_IMM_GE, Z21, Z15, K4

  VPADDQ.BCST CONSTQ_1(), Z4, K3, Z4
  VPADDQ.BCST CONSTQ_1(), Z5, K4, Z5

  // Z4/Z5 <- Final months difference - always positive at this point.
  VPMAXSQ Z10, Z4, Z4
  VPMAXSQ Z10, Z5, Z5

  // Z2/Z3 <- Final months/years difference - depending on the bytecode instruction's predicate.
  VPMULLQ Z11, Z4, Z4
  VPMULLQ Z11, Z5, Z5
  VPSRLQ $35, Z4, K1, Z2
  VPSRLQ $35, Z5, K2, Z3

  // Z2/Z3 <- Final months/years difference - positive or negative depending on which timestamp was greater.
  VPSUBQ Z2, Z10, K5, Z2
  VPSUBQ Z3, Z10, K6, Z3

  NEXT_ADVANCE(4)

#define BC_EXTRACT_HMS_FROM_TIMESTAMP(OUT1, OUT2, IN1, IN2, TMP1, TMP2, TMP3, TMP4, TMP5) \
  /* First cut off some bits and convert to float64 without losing the precision. */      \
  VBROADCASTSD CONSTF64_MICROSECONDS_IN_1_DAY_SHR_13(), TMP5                              \
  VPSRAQ $13, IN1, TMP1                                                                   \
  VPSRAQ $13, IN2, TMP2                                                                   \
  VCVTQQ2PD TMP1, TMP1                                                                    \
  VCVTQQ2PD TMP2, TMP2                                                                    \
                                                                                          \
  /* Z8/Z9 <- floor(float64(input >> 13) / float64((60 * 60 * 24 * 1000000) >> 13)). */   \
  VDIVPD.RD_SAE TMP5, TMP1, TMP3                                                          \
  VDIVPD.RD_SAE TMP5, TMP2, TMP4                                                          \
  VRNDSCALEPD $VROUND_IMM_DOWN_SAE, TMP3, TMP3                                            \
  VRNDSCALEPD $VROUND_IMM_DOWN_SAE, TMP4, TMP4                                            \
                                                                                          \
  /* TMP1/TMP2 <- Number of (hours, minutes, seconds, and microseconds) >> 13. */         \
  VMULPD TMP5, TMP3, TMP3                                                                 \
  VMULPD TMP5, TMP4, TMP4                                                                 \
  VSUBPD TMP3, TMP1, TMP1                                                                 \
  VSUBPD TMP4, TMP2, TMP2                                                                 \
  VCVTPD2UQQ TMP1, TMP1                                                                   \
  VCVTPD2UQQ TMP2, TMP2                                                                   \
                                                                                          \
  /* OUT1/OUT2 <- Number of hours, minutes, seconds, and microseconds combined. */        \
  VPBROADCASTQ CONSTQ_0x1FFF(), TMP3                                                      \
  VPSLLQ $13, TMP1, OUT1                                                                  \
  VPSLLQ $13, TMP2, OUT2                                                                  \
  VPTERNLOGQ $0xD8, TMP3, IN1, OUT1 /* (A & ~C) | (B & C) */                              \
  VPTERNLOGQ $0xD8, TMP3, IN2, OUT2 /* (A & ~C) | (B & C) */

// EXTRACT(MICROSECOND FROM timestamp) - the result includes seconds
TEXT bcdateextractmicrosecond(SB), NOSPLIT|NOFRAME, $0
  KSHIFTRW $8, K1, K2

  // Z4:Z5 <- hours, minutes, seconds, and microseconds combined
  BC_EXTRACT_HMS_FROM_TIMESTAMP(OUT(Z4), OUT(Z5), IN(Z2), IN(Z3), Z6, Z7, Z8, Z9, Z10)

  // discard hours and minutes, keep microseconds that include also seconds
  VPBROADCASTQ CONSTQ_600479951(), Z8
  VPBROADCASTQ CONSTQ_60000000(), Z9
  VPSRLQ $8, Z4, Z6
  VPSRLQ $8, Z5, Z7
  BC_DIV_U32_RCP_2X(OUT(Z6), OUT(Z7), IN(Z6), IN(Z7), IN(Z8), 47)
  VPMULUDQ Z9, Z6, Z6
  VPMULUDQ Z9, Z7, Z7
  VPSUBQ Z6, Z4, K1, Z2
  VPSUBQ Z7, Z5, K2, Z3

  NEXT()

// EXTRACT(MILLISECOND FROM timestamp) - the result includes seconds
TEXT bcdateextractmillisecond(SB), NOSPLIT|NOFRAME, $0
  KSHIFTRW $8, K1, K2

  // Z4:Z5 <- hours, minutes, seconds, and microseconds combined
  BC_EXTRACT_HMS_FROM_TIMESTAMP(OUT(Z4), OUT(Z5), IN(Z2), IN(Z3), Z6, Z7, Z8, Z9, Z10)

  // discard hours and minutes, keep milliseconds that include also seconds
  VPBROADCASTQ CONSTQ_600479951(), Z8
  VPBROADCASTQ CONSTQ_60000000(), Z9
  VPSRLQ $8, Z4, Z6
  VPSRLQ $8, Z5, Z7
  BC_DIV_U32_RCP_2X(OUT(Z6), OUT(Z7), IN(Z6), IN(Z7), IN(Z8), 47)
  VPMULUDQ Z9, Z6, Z6
  VPMULUDQ Z9, Z7, Z7
  VPBROADCASTQ CONSTQ_274877907(), Z8
  VPSUBQ Z6, Z4, Z4
  VPSUBQ Z7, Z5, Z5
  BC_DIV_U32_RCP_2X_MASKED(OUT(Z2), OUT(Z3), IN(Z4), IN(Z5), IN(Z8), 38, IN(K1), IN(K2))

  NEXT()

// EXTRACT(SECOND FROM timestamp)
TEXT bcdateextractsecond(SB), NOSPLIT|NOFRAME, $0
  KSHIFTRW $8, K1, K2

  // Z4:Z5 <- hours, minutes, seconds, and microseconds combined
  BC_EXTRACT_HMS_FROM_TIMESTAMP(OUT(Z4), OUT(Z5), IN(Z2), IN(Z3), Z6, Z7, Z8, Z9, Z10)

  // discard hours and minutes, keep seconds
  VPBROADCASTQ CONSTQ_600479951(), Z8
  VPBROADCASTQ CONSTQ_60000000(), Z9
  VPSRLQ $8, Z4, Z6
  VPSRLQ $8, Z5, Z7
  BC_DIV_U32_RCP_2X(OUT(Z6), OUT(Z7), IN(Z6), IN(Z7), IN(Z8), 47)
  VPMULUDQ Z9, Z6, Z6
  VPMULUDQ Z9, Z7, Z7
  VPBROADCASTQ CONSTQ_1125899907(), Z8
  VPSUBQ Z6, Z4, Z4
  VPSUBQ Z7, Z5, Z5
  BC_DIV_U32_RCP_2X_MASKED(OUT(Z2), OUT(Z3), IN(Z4), IN(Z5), IN(Z8), 50, IN(K1), IN(K2))

  NEXT()

// EXTRACT(MINUTE FROM timestamp)
TEXT bcdateextractminute(SB), NOSPLIT|NOFRAME, $0
  KSHIFTRW $8, K1, K2

  // Z4:Z5 <- hours, minutes, seconds, and microseconds combined
  BC_EXTRACT_HMS_FROM_TIMESTAMP(OUT(Z4), OUT(Z5), IN(Z2), IN(Z3), Z6, Z7, Z8, Z9, Z10)

  // discard seconds
  VPBROADCASTQ CONSTQ_600479951(), Z8
  VPBROADCASTQ CONSTQ_60000000(), Z9
  VPSRLQ $8, Z4, Z6
  VPSRLQ $8, Z5, Z7
  BC_DIV_U32_RCP_2X(OUT(Z4), OUT(Z5), IN(Z6), IN(Z7), IN(Z8), 47)

  // now keep only minutes (% 60)
  VPBROADCASTQ CONSTQ_2290649225(), Z6
  VPBROADCASTQ CONSTQ_60(), Z7
  BC_MOD_U32_RCP_2X_MASKED(OUT(Z2), OUT(Z3), IN(Z4), IN(Z5), IN(Z7), IN(Z6), 37, IN(K1), IN(K2), Z8, Z9)

  NEXT()

// EXTRACT(HOUR FROM timestamp)
TEXT bcdateextracthour(SB), NOSPLIT|NOFRAME, $0
  KSHIFTRW $8, K1, K2

  // Z4:Z5 <- hours, minutes, seconds, and microseconds combined
  BC_EXTRACT_HMS_FROM_TIMESTAMP(OUT(Z4), OUT(Z5), IN(Z2), IN(Z3), Z6, Z7, Z8, Z9, Z10)

  // discard minutes and seconds
  VPBROADCASTQ CONSTQ_1281023895(), Z8
  VPSRLQ $10, Z4, Z4
  VPSRLQ $10, Z5, Z5
  BC_DIV_U32_RCP_2X_MASKED(OUT(Z2), OUT(Z3), IN(Z4), IN(Z5), IN(Z8), 52, IN(K1), IN(K2))

  NEXT()

// EXTRACT(DAY FROM timestamp)
TEXT bcdateextractday(SB), NOSPLIT|NOFRAME, $0
  KSHIFTRW $8, K1, K2
  BC_DECOMPOSE_TIMESTAMP_PARTS(Z2, Z3)
  VPBROADCASTQ CONSTQ_1(), Z4
  VPADDQ Z4, Z14, K1, Z2
  VPADDQ Z4, Z15, K2, Z3
  NEXT()

// EXTRACT(DOW FROM timestamp)
TEXT bcdateextractdow(SB), NOSPLIT|NOFRAME, $0
  KSHIFTRW $8, K1, K2

  // divide Z2:Z3 by (60 * 60 * 24 * 1000000) (microseconds per day)
  // to get days from the start of unix time
  VBROADCASTSD CONSTF64_MICROSECONDS_IN_1_DAY_SHR_13(), Z6
  VPSRAQ $13, Z2, Z4
  VPSRAQ $13, Z3, Z5
  VCVTQQ2PD.Z Z4, K1, Z4
  VCVTQQ2PD.Z Z5, K2, Z5

  VDIVPD.RD_SAE Z6, Z4, Z4
  VDIVPD.RD_SAE Z6, Z5, Z5

  // The internal [unboxed] representation is a unix microtime, which
  // starts at 1970-01-01, which is Thursday - so add 4 and then modulo
  // it by 7 to get a value in [0, 6] range, where 0 is Sunday.
  VBROADCASTSD CONSTF64_4(), Z6
  VRNDSCALEPD $VROUND_IMM_DOWN_SAE, Z4, Z4
  VRNDSCALEPD $VROUND_IMM_DOWN_SAE, Z5, Z5

  VBROADCASTSD CONSTF64_7(), Z8
  VADDPD Z6, Z4, Z4
  VADDPD Z6, Z5, Z5

  VDIVPD.RD_SAE Z8, Z4, Z6
  VDIVPD.RD_SAE Z8, Z5, Z7

  VRNDSCALEPD $VROUND_IMM_DOWN_SAE, Z6, Z6
  VRNDSCALEPD $VROUND_IMM_DOWN_SAE, Z7, Z7

  VMULPD Z8, Z6, Z6
  VMULPD Z8, Z7, Z7

  VSUBPD Z6, Z4, Z4
  VSUBPD Z7, Z5, Z5

  VCVTPD2QQ Z4, K1, Z2
  VCVTPD2QQ Z5, K2, Z3

  NEXT()

// A DWORD table designed for VPERMD that can be used to map month of the year into the number
// of days preceeding the month + 1, excluding leap day.
CONST_DATA_U32(extract_doy_predicate,  0, $0)         // Zero index is unused
CONST_DATA_U32(extract_doy_predicate,  4, $(59 + 1))  // March
CONST_DATA_U32(extract_doy_predicate,  8, $(90 + 1))  // April
CONST_DATA_U32(extract_doy_predicate, 12, $(120 + 1)) // May
CONST_DATA_U32(extract_doy_predicate, 16, $(151 + 1)) // June
CONST_DATA_U32(extract_doy_predicate, 20, $(181 + 1)) // July
CONST_DATA_U32(extract_doy_predicate, 24, $(212 + 1)) // August
CONST_DATA_U32(extract_doy_predicate, 28, $(243 + 1)) // September
CONST_DATA_U32(extract_doy_predicate, 32, $(273 + 1)) // October
CONST_DATA_U32(extract_doy_predicate, 36, $(304 + 1)) // November
CONST_DATA_U32(extract_doy_predicate, 40, $(334 + 1)) // December
CONST_DATA_U32(extract_doy_predicate, 44, $(0 + 1))   // January
CONST_DATA_U32(extract_doy_predicate, 48, $(31 + 1))  // February
CONST_DATA_U32(extract_doy_predicate, 52, $0)
CONST_DATA_U32(extract_doy_predicate, 56, $0)
CONST_DATA_U32(extract_doy_predicate, 60, $0)
CONST_GLOBAL(extract_doy_predicate, $64)

// EXTRACT(DOY FROM timestamp)
//
// Extacting DOY is implemented as (x - DATE_TRUNC(x)) / MICROSECONDS_PER_DAY + 1
TEXT bcdateextractdoy(SB), NOSPLIT|NOFRAME, $0
  KSHIFTRW $8, K1, K2

  // Z8/Z9 <- Year index
  // Z10/Z11 <- Month index - starting from zero, where zero represents March
  // Z14/Z15 <- Day of month
  BC_DECOMPOSE_TIMESTAMP_PARTS(Z2, Z3)

  VPBROADCASTQ CONSTQ_10(), Z12
  VPBROADCASTQ CONSTQ_1(), Z13

  VPCMPUQ $VPCMP_IMM_LT, Z12, Z10, K3, K3
  VPCMPUQ $VPCMP_IMM_LT, Z12, Z11, K4, K4

  VMOVDQU64 CONST_GET_PTR(extract_doy_predicate, 0), Z12
  VPADDQ Z13, Z10, Z10
  VPADDQ Z13, Z11, Z11

  VPERMD Z12, Z10, Z4
  VPERMD Z12, Z11, Z5

  VPADDQ Z13, Z4, K3, Z4
  VPADDQ Z13, Z5, K4, Z5

  VPADDQ Z14, Z4, K1, Z2
  VPADDQ Z15, Z5, K2, Z3

  NEXT()

// EXTRACT(MONTH FROM timestamp)
TEXT bcdateextractmonth(SB), NOSPLIT|NOFRAME, $0
  KSHIFTRW $8, K1, K2
  BC_DECOMPOSE_TIMESTAMP_PARTS(Z2, Z3)

  // Convert our MonthIndex into a month in a range from [1, 12], where 1 is January.
  VPADDQ.BCST CONSTQ_3(), Z10, Z10
  VPADDQ.BCST CONSTQ_3(), Z11, Z11
  VPCMPUQ.BCST $VPCMP_IMM_GT, CONSTQ_12(), Z10, K5
  VPCMPUQ.BCST $VPCMP_IMM_GT, CONSTQ_12(), Z11, K6

  // Wrap the month if it was greater than 12 after adding the final offset.
  VPSUBQ.BCST CONSTQ_12(), Z10, K5, Z10
  VPSUBQ.BCST CONSTQ_12(), Z11, K6, Z11

  VMOVDQA64 Z10, K1, Z2
  VMOVDQA64 Z11, K2, Z3
  NEXT()

// EXTRACT(QUARTER FROM timestamp)
TEXT bcdateextractquarter(SB), NOSPLIT|NOFRAME, $0
  KSHIFTRW $8, K1, K2
  BC_DECOMPOSE_TIMESTAMP_PARTS(Z2, Z3)

  VPBROADCASTQ CONSTQ_1(), Z4
  VBROADCASTI32X4 CONST_GET_PTR(consts_quarter_from_month_1_is_march, 0), Z5

  // convert a resulting month index into [1, 12] range, where 1 represents March
  VPADDQ Z4, Z10, Z10
  VPADDQ Z4, Z11, Z11

  // use VPSHUFB to convert the month index into a quarter
  VPSHUFB Z10, Z5, Z10
  VPSHUFB Z11, Z5, Z11

  VMOVDQA64 Z10, K1, Z2
  VMOVDQA64 Z11, K2, Z3
  NEXT()

// EXTRACT(YEAR FROM timestamp)
TEXT bcdateextractyear(SB), NOSPLIT|NOFRAME, $0
  BC_DECOMPOSE_TIMESTAMP_PARTS(Z2, Z3)
  KSHIFTRW $8, K1, K2

  // Convert our MonthIndex into a month in a range from [1, 12], where 1 is January.
  VPADDQ.BCST CONSTQ_3(), Z10, Z10
  VPADDQ.BCST CONSTQ_3(), Z11, Z11
  VPCMPUQ.BCST $VPCMP_IMM_GT, CONSTQ_12(), Z10, K5
  VPCMPUQ.BCST $VPCMP_IMM_GT, CONSTQ_12(), Z11, K6

  // Wrap the month if it was greater than 12 after adding the final offset.
  VPSUBQ.BCST CONSTQ_12(), Z10, K5, Z10
  VPSUBQ.BCST CONSTQ_12(), Z11, K6, Z11

  // Increment one year if required to adjust for the month greater than 12 after adding the final offset.
  VPADDQ.BCST CONSTQ_1(), Z8, K5, Z8
  VPADDQ.BCST CONSTQ_1(), Z9, K6, Z9

  VMOVDQA64 Z8, K1, Z2
  VMOVDQA64 Z9, K2, Z3
  NEXT()

TEXT bcdatetounixepoch(SB), NOSPLIT|NOFRAME, $0
  KSHIFTRW $8, K1, K2

  // Discard some bits so we can prepare the timestamp value for division.
  VPSRAQ $6, Z2, K1, Z2
  VPSRAQ $6, Z3, K2, Z3

  // 15625 == 1000000 >> 6
  VPXORQ X5, X5, X5
  VPBROADCASTQ CONSTQ_15625(), Z4

  VPCMPQ $VPCMP_IMM_LT, Z5, Z2, K1, K3
  VPCMPQ $VPCMP_IMM_LT, Z5, Z3, K2, K4

  VPSUBQ.BCST CONSTQ_1(), Z4, Z5

  VPSUBQ Z5, Z2, K3, Z2
  VPSUBQ Z5, Z3, K4, Z3

  BC_DIVI64_IMPL(Z2, Z3, Z2, Z3, Z4, Z4, K1, K2, Z6, Z7, Z8, Z9, Z10, Z11, Z12, Z13, Z14, Z15, K3, K4)
  NEXT()

// DATE_TRUNC(MILLISECOND, timestamp)
TEXT bcdatetruncmillisecond(SB), NOSPLIT|NOFRAME, $0
  KSHIFTRW $8, K1, K2
  VPBROADCASTQ CONSTQ_1000(), Z4
  BC_DIVU64_IMPL(Z2, Z3, Z2, Z3, Z4, Z4, K1, K2, Z6, Z7, Z8, Z9, Z10, Z11, K3, K4)
  VPMULLQ Z4, Z2, K1, Z2
  VPMULLQ Z4, Z3, K2, Z3
  NEXT()

// DATE_TRUNC(SECOND, timestamp)
TEXT bcdatetruncsecond(SB), NOSPLIT|NOFRAME, $0
  KSHIFTRW $8, K1, K2
  VPBROADCASTQ CONSTQ_1000000(), Z4
  BC_DIVU64_IMPL(Z2, Z3, Z2, Z3, Z4, Z4, K1, K2, Z6, Z7, Z8, Z9, Z10, Z11, K3, K4)
  VPMULLQ Z4, Z2, K1, Z2
  VPMULLQ Z4, Z3, K2, Z3
  NEXT()

// DATE_TRUNC(MINUTE, timestamp)
TEXT bcdatetruncminute(SB), NOSPLIT|NOFRAME, $0
  KSHIFTRW $8, K1, K2
  VPBROADCASTQ CONSTQ_60000000(), Z4
  BC_DIVU64_IMPL(Z2, Z3, Z2, Z3, Z4, Z4, K1, K2, Z6, Z7, Z8, Z9, Z10, Z11, K3, K4)
  VPMULLQ Z4, Z2, K1, Z2
  VPMULLQ Z4, Z3, K2, Z3
  NEXT()

// DATE_TRUNC(HOUR, timestamp)
TEXT bcdatetrunchour(SB), NOSPLIT|NOFRAME, $0
  KSHIFTRW $8, K1, K2
  VPBROADCASTQ CONSTQ_3600000000(), Z4
  BC_DIVU64_IMPL(Z2, Z3, Z2, Z3, Z4, Z4, K1, K2, Z6, Z7, Z8, Z9, Z10, Z11, K3, K4)
  VPMULLQ Z4, Z2, K1, Z2
  VPMULLQ Z4, Z3, K2, Z3
  NEXT()

// DATE_TRUNC(DAY, timestamp)
TEXT bcdatetruncday(SB), NOSPLIT|NOFRAME, $0
  KSHIFTRW $8, K1, K2
  VPBROADCASTQ CONSTQ_86400000000(), Z4
  BC_DIVU64_IMPL(Z2, Z3, Z2, Z3, Z4, Z4, K1, K2, Z6, Z7, Z8, Z9, Z10, Z11, K3, K4)
  VPMULLQ Z4, Z2, K1, Z2
  VPMULLQ Z4, Z3, K2, Z3
  NEXT()

// DATE_TRUNC(WEEK(dow), timestamp)
//
// Truncating a timestamp to a DOW can be implemented the following way:
//   days = unix_time_in_days(ts)
//   off = days + 4 - dow
//   adj = floor(off / 7) * 7
//   truncated_ts = days_to_microseconds(adj - 4 + dow)
TEXT bcdatetruncdow(SB), NOSPLIT|NOFRAME, $0
  KSHIFTRW $8, K1, K2
  VPBROADCASTW 0(VIRT_PCREG), Z7

  // divide Z2:Z3 by (60 * 60 * 24 * 1000000) (microseconds per day)
  // to get days from the start of unix time. Calculate also Z7 to
  // be `4 - DOW`.
  VBROADCASTSD CONSTF64_MICROSECONDS_IN_1_DAY_SHR_13(), Z6
  VPBROADCASTQ CONSTQ_4(), Z8
  VPSRAQ $13, Z2, Z4
  VPSRAQ $13, Z3, Z5
  VCVTQQ2PD.Z Z4, K1, Z4
  VCVTQQ2PD.Z Z5, K2, Z5
  VPSRLQ $48, Z7, Z7
  VDIVPD.RD_SAE Z6, Z4, Z4
  VDIVPD.RD_SAE Z6, Z5, Z5
  VPSUBQ Z7, Z8, Z7

  // The internal [unboxed] representation is a unix microtime, which
  // starts at 1970-01-01, which is Thursday - so add 4 - the requested
  // DayOfWeek so we can calculate the adjustment.
  VBROADCASTSD CONSTF64_7(), Z10
  VCVTQQ2PD Z7, Z7

  VRNDSCALEPD $VROUND_IMM_DOWN_SAE, Z4, Z4 // Z4 <- Days since 1970-01-01 (low)
  VRNDSCALEPD $VROUND_IMM_DOWN_SAE, Z5, Z5 // Z5 <- Days since 1970-01-01 (high)

  VADDPD Z7, Z4, Z4                        // Z4 <- days + 4 - dow (low)
  VADDPD Z7, Z5, Z5                        // Z5 <- days + 4 - dow (high)
  VDIVPD.RD_SAE Z10, Z4, Z4                // Z4 <- (days + 4 - dow) / 7 (low)
  VDIVPD.RD_SAE Z10, Z5, Z5                // Z5 <- (days + 4 - dow) / 7 (high)
  VRNDSCALEPD $VROUND_IMM_DOWN_SAE, Z4, Z4 // Z4 <- floor((days + 4 - dow) / 7) (low)
  VRNDSCALEPD $VROUND_IMM_DOWN_SAE, Z5, Z5 // Z5 <- floor((days + 4 - dow) / 7) (high)
  VMULPD Z10, Z4, Z4                       // Z4 <- floor((days + 4 - dow) / 7) * 7 (low)
  VMULPD Z10, Z5, Z5                       // Z5 <- floor((days + 4 - dow) / 7) * 7 (high)

  VSUBPD Z7, Z4, Z4                        // Z8 <- days since 1970-01-01 truncated to DOW (low) (low)
  VSUBPD Z7, Z5, Z5                        // Z9 <- days since 1970-01-01 truncated to DOW (low) (high)

  VPBROADCASTQ CONSTQ_86400000000(), Z6
  VCVTPD2QQ Z4, Z4
  VCVTPD2QQ Z5, Z5
  VPMULLQ Z6, Z4, K1, Z2                   // Z2 <- Truncated timestamp in unix microseconds (low)
  VPMULLQ Z6, Z5, K2, Z3                   // Z3 <- Truncated timestamp in unix microseconds (high)

  NEXT_ADVANCE(2)

// DATE_TRUNC(MONTH, timestamp)
TEXT bcdatetruncmonth(SB), NOSPLIT|NOFRAME, $0
  KSHIFTRW $8, K1, K2

  // Z8/Z9 <- Year index.
  // Z10/Z11 <- Month index - starting from zero, where zero represents March.
  BC_DECOMPOSE_TIMESTAMP_PARTS(Z2, Z3)

  // Z4/Z5 <- Number of days in a year [0, 365] got from MonthIndex.
  VMOVDQU64 CONST_GET_PTR(consts_days_until_month_from_march, 0), Z13
  VPERMD Z13, Z10, Z4
  VPERMD Z13, Z11, Z5

  // Z4/Z5 <- Number of days of all years, including days in the last month.
  BC_COMPOSE_YEAR_TO_DAYS(Z4, Z5, Z8, Z9, Z10, Z11, Z12, Z13, Z14, Z15)

  // Z4/Z5 <- Final number of days converted to microseconds.
  VPMULLQ.BCST CONSTQ_86400000000(), Z4, Z4
  VPMULLQ.BCST CONSTQ_86400000000(), Z5, Z5

  // Z2/Z3 <- Make it a unix timestamp starting from 1970-01-01.
  VPSUBQ.BCST CONSTQ_1970_01_01_TO_0000_03_01_US_OFFSET(), Z4, K1, Z2
  VPSUBQ.BCST CONSTQ_1970_01_01_TO_0000_03_01_US_OFFSET(), Z5, K2, Z3

  NEXT()

// VPSHUFB predicate that aligns a month in [1, 12] range (where 1 is March) to a quarter
// month in [0, 11] range (our processing range that can be then easily composed). This
// is a special predicate designed only for 'bcdatetruncquarter' operation.
CONST_DATA_U64(consts_align_month_to_quarter_1_is_march, 0, $0x0404040101010A00)
CONST_DATA_U64(consts_align_month_to_quarter_1_is_march, 8, $0x0000000A0A070707)
CONST_GLOBAL(consts_align_month_to_quarter_1_is_march, $16)

// DATE_TRUNC(QUARTER, timestamp)
TEXT bcdatetruncquarter(SB), NOSPLIT|NOFRAME, $0
  KSHIFTRW $8, K1, K2

  // Z8/Z9 <- Year index.
  // Z10/Z11 <- Month index - starting from zero, where zero represents March.
  BC_DECOMPOSE_TIMESTAMP_PARTS(Z2, Z3)

  // make month index from [1, 12] so we can safely use VPSHUFB (so zero can stay zero)
  VPBROADCASTQ CONSTQ_1(), Z4
  VBROADCASTI32X4 CONST_GET_PTR(consts_align_month_to_quarter_1_is_march, 0), Z5

  VPADDQ Z4, Z10, Z10
  VPADDQ Z4, Z11, Z11

  // since month index starts in March, we have to decrease one year if the month is March
  VPCMPEQQ Z4, Z10, K1, K3
  VPCMPEQQ Z4, Z11, K2, K4
  VPSUBQ Z4, Z8, K3, Z8
  VPSUBQ Z4, Z9, K4, Z9

  VMOVDQU64 CONST_GET_PTR(consts_days_until_month_from_march, 0), Z13
  VPSHUFB Z10, Z5, Z10
  VPSHUFB Z11, Z5, Z11

  // Z4/Z5 <- Number of days in a year [0, 365] got from MonthIndex.
  VPERMD Z13, Z10, Z4
  VPERMD Z13, Z11, Z5

  // Z4/Z5 <- Number of days of all years, including days in the last month.
  BC_COMPOSE_YEAR_TO_DAYS(Z4, Z5, Z8, Z9, Z10, Z11, Z12, Z13, Z14, Z15)

  // Z4/Z5 <- Final number of days converted to microseconds.
  VPMULLQ.BCST CONSTQ_86400000000(), Z4, Z4
  VPMULLQ.BCST CONSTQ_86400000000(), Z5, Z5

  // Z2/Z3 <- Make it a unix timestamp starting from 1970-01-01.
  VPSUBQ.BCST CONSTQ_1970_01_01_TO_0000_03_01_US_OFFSET(), Z4, K1, Z2
  VPSUBQ.BCST CONSTQ_1970_01_01_TO_0000_03_01_US_OFFSET(), Z5, K2, Z3

  NEXT()

// DATE_TRUNC(YEAR, timestamp)
TEXT bcdatetruncyear(SB), NOSPLIT|NOFRAME, $0
  KSHIFTRW $8, K1, K2

  // Z8/Z9 <- Year index.
  // Z10/Z11 <- Month index - starting from zero, where zero represents March.
  BC_DECOMPOSE_TIMESTAMP_PARTS(Z2, Z3)

  // Since the month starts from March, we have to check whether the truncation doesn't
  // need to decrement one year (January/February have 10/11 indexes, respectively)
  VPCMPUQ.BCST $VPCMP_IMM_LT, CONSTQ_10(), Z10, K3
  VPCMPUQ.BCST $VPCMP_IMM_LT, CONSTQ_10(), Z11, K4

  // Decrement one year if required.
  VPSUBQ.BCST CONSTQ_1(), Z8, K3, Z8
  VPSUBQ.BCST CONSTQ_1(), Z9, K4, Z9

  VPBROADCASTQ CONSTQ_306(), Z4
  VMOVDQA64 Z4, Z5

  BC_COMPOSE_YEAR_TO_DAYS(Z4, Z5, Z8, Z9, Z10, Z11, Z12, Z13, Z14, Z15)

  // Z4/Z5 <- Final number of days converted to microseconds.
  VPMULLQ.BCST CONSTQ_86400000000(), Z4, Z4
  VPMULLQ.BCST CONSTQ_86400000000(), Z5, Z5

  // Z2/Z3 <- Make it a unix timestamp starting from 1970-01-01.
  VPSUBQ.BCST CONSTQ_1970_01_01_TO_0000_03_01_US_OFFSET(), Z4, K1, Z2
  VPSUBQ.BCST CONSTQ_1970_01_01_TO_0000_03_01_US_OFFSET(), Z5, K2, Z3

  NEXT()

TEXT bcunboxts(SB), NOSPLIT|NOFRAME, $0
  // TernLog:
  //   VPTERNLOG(0xD8) == (A & ~C) | (B & C) == Blend(A, B, ~C)
  KSHIFTRW $8, K1, K2

  // Z4/Z5 <- First 8 bytes of the timestamp to process, ignoring
  //          timezone offset, which is assumed to be zero.
  VEXTRACTI32X8 $1, Z2, Y21
  KMOVB K1, K3
  KSHIFTRW $8, K1, K4
  VPXORQ X4, X4, X4
  VPXORQ X5, X5, X5
  VPGATHERDQ 1(SI)(Y2*1), K3, Z4
  VPGATHERDQ 1(SI)(Y21*1), K4, Z5

  // Z20/Z21 <- Frequently used constants to avoid broadcasts.
  VPBROADCASTQ CONSTQ_0x7F(), Z20
  VPBROADCASTQ CONSTQ_0x80(), Z21
  VPBROADCASTQ CONSTQ_1(), Z22
  VPBROADCASTQ CONSTD_8(), Z23

  // Z4/Z5 <- First 8 bytes of the timestamp cleared so only bytes that
  //          are within the length are non-zero, other bytes cleared.
  VPMINUD.Z Z23, Z3, K1, Z16
  VPSUBD.Z Z16, Z23, K1, Z16
  VPSLLD $3, Z16, Z16
  VEXTRACTI32X8 $1, Z16, Y17
  VPMOVZXDQ Y16, Z16
  VPMOVZXDQ Y17, Z17
  VPSLLVQ Z16, Z4, Z4
  VPSLLVQ Z17, Z5, Z5
  VPSRLVQ Z16, Z4, Z4
  VPSRLVQ Z17, Z5, Z5

  // Z6/Z7 <- Year (1 to 3 bytes).
  //
  // We assume year to be one to three bytes, month and day must be one bytes each.
  VPTESTNMQ Z21, Z4, K3
  VPTESTNMQ Z21, Z5, K4
  VPANDQ Z20, Z4, Z6
  VPANDQ Z20, Z5, Z7
  VPSRLQ $8, Z4, Z4
  VPSRLQ $8, Z5, Z5

  // KUNPCKBW K3, K4, K5
  VPSLLQ $7, Z6, K3, Z6
  VPSLLQ $7, Z7, K4, Z7
  VPTERNLOGQ $0xD8, Z20, Z4, K3, Z6
  VPTERNLOGQ $0xD8, Z20, Z5, K4, Z7
  VPSRLQ $8, Z4, K3, Z4
  VPSRLQ $8, Z5, K4, Z5

  VPTESTNMQ Z21, Z4, K3, K3
  VPTESTNMQ Z21, Z5, K4, K4
  VPSLLQ $7, Z6, K3, Z6
  VPSLLQ $7, Z7, K4, Z7
  VPTERNLOGQ $0xD8, Z20, Z4, K3, Z6
  VPTERNLOGQ $0xD8, Z20, Z5, K4, Z7
  VPSRLQ $8, Z4, K3, Z4
  VPSRLQ $8, Z5, K4, Z5

  // Z4/Z5 <- [?|?|?|Second|Minute|Hour|Day|Month] with 0x80 bit cleared in each value.
  VPANDQ.BCST CONSTQ_0x0000007F7F7F7F7F(), Z4, Z4
  VPANDQ.BCST CONSTQ_0x0000007F7F7F7F7F(), Z5, Z5

  // Z8/Z9 <- Month (always 1 byte), indexed from 1.
  VPANDQ Z20, Z4, Z8
  VPANDQ Z20, Z5, Z9
  VPSRLQ $8, Z4, Z4
  VPSRLQ $8, Z5, Z5
  VPMAXUQ Z22, Z8, Z8
  VPMAXUQ Z22, Z9, Z9

  // Z10/Z11 <- Day of month (always 1 byte), indexed from 1.
  VPANDQ Z20, Z4, Z10
  VPANDQ Z20, Z5, Z11
  VPSRLQ $8, Z4, Z4
  VPSRLQ $8, Z5, Z5
  VPMAXUQ Z22, Z10, Z10
  VPMAXUQ Z22, Z11, Z11

  // Z4/Z5 <- Hour/Minute/Second converted to Seconds.
  VPBROADCASTQ CONSTQ_0x0001013C(), Z18
  VPBROADCASTQ CONSTQ_0x0001003C(), Z19
  // [0 + Second | Minute + Hour*60] <- [0 | Second | Minute | Hour].
  VPMADDUBSW Z18, Z4, Z4
  VPMADDUBSW Z18, Z5, Z5
  // [Second + Minute*60 + Hour*60*60] <- [0 + Second | Minute + Hour*60].
  VPMADDWD Z19, Z4, Z4
  VPMADDWD Z19, Z5, Z5

  // Z18 <- Load last 4 bytes of the timestamp if it contains microseconds.
  VPCMPD.BCST $VPCMP_IMM_GT, CONSTD_10(), Z3, K1, K3
  VPADDD Z2, Z3, Z19
  VPXORD X18, X18, X18
  VPGATHERDD -4(SI)(Z19*1), K3, Z18

  // Z8/Z9 <- Month - 3.
  VPSUBQ.BCST CONSTQ_3(), Z8, Z8
  VPSUBQ.BCST CONSTQ_3(), Z9, Z9

  // NOTE: Z21 is 0x80 - this is enough to check for a negative month in this case.
  VPTESTMQ Z21, Z8, K3
  VPTESTMQ Z21, Z9, K4

  // Z6/Z7 <- Corrected year in case that the month is January/February.
  VPSUBQ Z22, Z6, K3, Z6
  VPSUBQ Z22, Z7, K4, Z7

  // Z8/Z9 <- Corrected month index in range [0, 11] where 0 is March.
  VPADDQ.BCST CONSTQ_12(), Z8, K3, Z8
  VPADDQ.BCST CONSTQ_12(), Z9, K4, Z9

  // --- Compose the timestamp ---

  // Z8/Z9 <- Number of days in a year [0, 365].
  VMOVDQU64 CONST_GET_PTR(consts_days_until_month_from_march, 0), Z13
  VPERMD Z13, Z8, Z12
  VPERMD Z13, Z9, Z13
  VPADDQ Z12, Z10, Z8
  VPADDQ Z13, Z11, Z9
  VPSUBQ.BCST CONSTQ_1(), Z8, Z8
  VPSUBQ.BCST CONSTQ_1(), Z9, Z9

  // Z8/Z9 <- Number of days of all years, including days in the last month.
  BC_COMPOSE_YEAR_TO_DAYS(Z8, Z9, Z6, Z7, Z10, Z11, Z12, Z13, Z14, Z15)

  // Z18 <- Convert last 4 bytes of the timestamp to microseconds (it's either a value or zero).
  VPSHUFB CONST_GET_PTR(bswap24_zero_last_byte, 0), Z18, Z18

  // Z8/Z9 <- Final number of days converted to microseconds.
  VPMULLQ.BCST CONSTQ_86400000000(), Z8, Z8
  VPMULLQ.BCST CONSTQ_86400000000(), Z9, Z9

  // Z8/Z9 <- Combined microseconds of all days and microseconds of the remaining day.
  VEXTRACTI32X8 $1, Z18, Y19
  VPMULLQ.BCST CONSTQ_1000000(), Z4, Z4
  VPMULLQ.BCST CONSTQ_1000000(), Z5, Z5
  VPMOVZXDQ Y18, Z18
  VPMOVZXDQ Y19, Z19
  VPADDQ Z4, Z8, Z8
  VPADDQ Z5, Z9, Z9
  VPADDQ Z18, Z8, Z8
  VPADDQ Z19, Z9, Z9

  // Z2/Z3 <- Make it a unix timestamp starting from 1970-01-01.
  VPSUBQ.BCST CONSTQ_1970_01_01_TO_0000_03_01_US_OFFSET(), Z8, K1, Z2
  VPSUBQ.BCST CONSTQ_1970_01_01_TO_0000_03_01_US_OFFSET(), Z9, K2, Z3

  NEXT()

TEXT bcboxts(SB), NOSPLIT|NOFRAME, $0
  // Make sure we have at least 16 bytes for each lane, we always overallocate to make the boxing simpler.
  VM_CHECK_SCRATCH_CAPACITY($(16 * 16), R8, abort)

  // set zmm30.k1 to the current scratch base
  VM_GET_SCRATCH_BASE_ZMM(Z30, K1)

  // Update the length of the output buffer.
  ADDQ $(16 * 16), bytecode_scratch+8(VIRT_BCPTR)

  KSHIFTRW $8, K1, K2
  // Decompose the timestamp value into Year/Month/DayOfMonth and microseconds of the day.
  //
  // Z4/Z5   - Microseconds of the day (combines hours, minutes, seconds, microseconds).
  // Z8/Z9   - Year index.
  // Z10/Z11 - Month index - starting from zero, where zero represents March.
  // Z14/Z15 - Day of month - starting from zero.
  BC_DECOMPOSE_TIMESTAMP_PARTS(Z2, Z3)

  // Convert our MonthIndex into a month in a range from [1, 12], where 1 is January.
  VPADDQ.BCST CONSTQ_3(), Z10, Z10
  VPADDQ.BCST CONSTQ_3(), Z11, Z11
  VPCMPUQ.BCST $VPCMP_IMM_GT, CONSTQ_12(), Z10, K5
  VPCMPUQ.BCST $VPCMP_IMM_GT, CONSTQ_12(), Z11, K6

  // Increment one year if required to adjust for the month greater than 12 after adding the final offset.
  VPADDQ.BCST CONSTQ_1(), Z8, K5, Z8
  VPADDQ.BCST CONSTQ_1(), Z9, K6, Z9

  // Wrap the month if it was greater than 12 after adding the final offset.
  VPSUBQ.BCST CONSTQ_12(), Z10, K5, Z10
  VPSUBQ.BCST CONSTQ_12(), Z11, K6, Z11

  // Increment one day to make the day of the month start from 1.
  VPADDQ.BCST CONSTQ_1(), Z14, Z14
  VPADDQ.BCST CONSTQ_1(), Z15, Z15

  // Construct Type|L, Offset, Year, Month, and DayOfMonth data, where:
  //   - Type|L is  (one byte).
  //   - Offset [0] (one byte).
  //   - Year (1 to 3 bytes).
  //   - Month [1, 12] (one byte)
  //   - DayOfMonth [1, 31] (one byte)
  //
  // Notes:
  //   - VPTERNLOG(0xD8) == (A & ~C) | (B & C) == Blend(A, B, ~C)

  // Z10/Z11 <- [DayOfMonth, Month, 0].
  VPSLLQ $16, Z14, Z14
  VPSLLQ $16, Z15, Z15
  VPSLLQ $8, Z10, Z10
  VPSLLQ $8, Z11, Z11
  VPBROADCASTQ CONSTQ_0x7F(), Z16
  VPBROADCASTQ CONSTQ_1(), Z17
  VPORQ Z14, Z10, Z10
  VPORQ Z15, Z11, Z11

  // Z14/Z15 <- Initial L field (length) is 7 bytes - Offset, Year (1 byte), Month, DayOfMonth, Hour, Minute, Second).
  //   - Modified by the algorithm depending on the year's length.
  //   - Used later to calculate the offset to the higher value (representing Hour/Minute/Second/Microsecond).
  VPBROADCASTQ CONSTQ_7(), Z14
  VPBROADCASTQ CONSTQ_7(), Z15

  // Z10/Z11 <- [DayOfMonth, Month, Year (1 byte)].
  VPTERNLOGQ $0xD8, Z16, Z8, Z10
  VPTERNLOGQ $0xD8, Z16, Z9, Z11
  VPORQ.BCST CONSTQ_0x0000000000808080(), Z10, Z10
  VPORQ.BCST CONSTQ_0x0000000000808080(), Z11, Z11

  // Z10/Z11 <- [DayOfMonth, Month, Year (1-2 bytes)].
  VPCMPQ $VPCMP_IMM_GT, Z16, Z8, K5
  VPCMPQ $VPCMP_IMM_GT, Z16, Z9, K6
  VPSRLQ $7, Z8, Z8
  VPSRLQ $7, Z9, Z9
  VPADDQ Z17, Z14, K5, Z14
  VPADDQ Z17, Z15, K6, Z15
  VPSLLQ $8, Z10, K5, Z10
  VPSLLQ $8, Z11, K6, Z11
  VPTERNLOGQ $0xD8, Z16, Z8, K5, Z10
  VPTERNLOGQ $0xD8, Z16, Z9, K6, Z11

  // Z10/Z11 <- [DayOfMonth, Month, Year (1-3 bytes)].
  VPCMPQ $VPCMP_IMM_GT, Z16, Z8, K5
  VPCMPQ $VPCMP_IMM_GT, Z16, Z9, K6
  VPSRLQ $7, Z8, Z8
  VPSRLQ $7, Z9, Z9
  VPADDQ Z17, Z14, K5, Z14
  VPADDQ Z17, Z15, K6, Z15
  VPSLLQ $8, Z10, K5, Z10
  VPSLLQ $8, Z11, K6, Z11
  VPTERNLOGQ $0xD8, Z16, Z8, K5, Z10
  VPTERNLOGQ $0xD8, Z16, Z9, K6, Z11

  // Z10/Z11 <- [DayOfMonth, Month, Year (1-3 bytes), Offset (always zero), Type|L (without a possible microsecond encoding length)].
  VPSLLQ $16, Z10, Z10
  VPSLLQ $16, Z11, Z11
  VPTERNLOGQ.BCST $0xFE, CONSTQ_0x0000000000008060(), Z14, Z10
  VPTERNLOGQ.BCST $0xFE, CONSTQ_0x0000000000008060(), Z15, Z11

  // Z14/Z15 - The size of the lower value of the encoded timestamp, in bytes, including Type|L field.
  VPSUBQ.BCST CONSTQ_2(), Z14, Z14
  VPSUBQ.BCST CONSTQ_2(), Z15, Z15

  // Construct Hour, Minute, Second, and an optional Microsecond
  //   - Hour [0, 23] (one byte)
  //   - Minute [0, 59] (one byte)
  //   - Second [0, 59] (one byte)
  //   - Microsecond [0, 999999] (1 byte for fraction_exponent 0xC6, 3 bytes for coefficient - UInt)

  // Z8/Z9 - Hour [0, 23].
  VPSRLQ $12, Z4, Z8
  VPSRLQ $12, Z5, Z9
  BC_DIV_U64_WITH_CONST_RECIPROCAL_BCST(Z8, Z9, Z8, Z9, CONSTQ_2562048517(), 51)

  // Z4/Z5 - (Minutes * 60000000) + (Second * 1000000) + Microseconds.
  VPMULLQ.BCST CONSTQ_3600000000(), Z8, Z12
  VPMULLQ.BCST CONSTQ_3600000000(), Z9, Z13
  VPSUBQ Z12, Z4, Z4
  VPSUBQ Z13, Z5, Z5

  // Z6/Z7 - Minute [0, 59].
  VPSRLQ $8, Z4, Z6
  VPSRLQ $8, Z5, Z7
  BC_DIV_U64_WITH_CONST_RECIPROCAL_BCST(Z6, Z7, Z6, Z7, CONSTQ_18764999(), 42)

  // Z4/Z5 - (Seconds * 1000000) + Microseconds.
  VPMULLQ.BCST CONSTQ_60000000(), Z6, Z12
  VPMULLQ.BCST CONSTQ_60000000(), Z7, Z13
  VPSUBQ Z12, Z4, Z4
  VPSUBQ Z13, Z5, Z5

  // Z12/Z13 - Second [0, 59].
  BC_DIV_U64_WITH_CONST_RECIPROCAL_BCST(Z12, Z13, Z4, Z5, CONSTQ_1125899907(), 50)

  // Z4/Z5 - Microsecond [0, 999999].
  VPMULLQ.BCST CONSTQ_1000000(), Z12, Z16
  VPMULLQ.BCST CONSTQ_1000000(), Z13, Z17
  VPSUBQ Z16, Z4, Z4
  VPSUBQ Z17, Z5, Z5

  // K3/K4 - Non-zero if the lane has a non-zero microsecond.
  VPTESTMQ Z4, Z4, K3
  VPTESTMQ Z5, Z5, K4

  // Z8/Z9 - [Second, Minute, Hour] (3 bytes).
  VPSLLQ $8, Z6, Z6
  VPSLLQ $8, Z7, Z7
  VPSLLQ $16, Z12, Z12
  VPSLLQ $16, Z13, Z13
  VPTERNLOGQ $0xFE, Z12, Z6, Z8
  VPTERNLOGQ $0xFE, Z13, Z7, Z9

  // Z4/Z5 - [Microsecond (3 bytes), 0xC6, Second, Minute, Hour].
  VBROADCASTI64X2 CONST_GET_PTR(consts_boxts_microsecond_swap, 0), Z16
  VPBROADCASTQ CONSTQ_0x00000000C6808080(), Z17
  VPSHUFB Z16, Z4, Z4
  VPSHUFB Z16, Z5, Z5
  VPTERNLOGQ $0xFE, Z17, Z8, Z4
  VPTERNLOGQ $0xFE, Z17, Z9, Z5

  // Z10/Z11 -  [DayOfMonth, Month, Year (1-3 bytes), Offset (always zero), Type|L (final length)].
  VPADDQ.BCST CONSTQ_4(), Z10, K3, Z10
  VPADDQ.BCST CONSTQ_4(), Z11, K4, Z11

  // Z30 - offsets relative to vmm (where each timestamp value starts, overallocated).
  VMOVDQA32 byteidx<>+0(SB), X28 // X28 = [0, 1, 2, 3 ...]
  VPMOVZXBD X28, Z28
  VPSLLD    $4, Z28, Z28
  VPADDD    Z28, Z30, K1, Z30    // Z30 += [0, 16, 32, 48, ...]

  // turn (zmm14 || zmm15) -> zmm14 by truncating
  VPMOVQD      Z14, Y14
  VPMOVQD      Z15, Y15
  VINSERTI32X8 $1, Y15, Z14, Z14

  KMOVB         K1, K3
  KSHIFTRW      $8, K1, K4
  VPADDD        Z14, Z30, Z29         // Z29 = high positions
  VEXTRACTI32X8 $1, Z30, Y21          // Y21 = hi 8 base positions
  VPSCATTERDQ   Z10, K3, 0(SI)(Y30*1) // write leading bits, lo 8 lanes
  VPSCATTERDQ   Z11, K4, 0(SI)(Y21*1) // write leading bits, hi 8 lanes
  KMOVB         K1, K3
  KSHIFTRW      $8, K1, K4
  VEXTRACTI32X8 $1, Z29, Y21          // Y21 = hi 8 upper positions
  VPSCATTERDQ   Z4, K3, 0(SI)(Y29*1)  // write trailing bits, lo 8 lanes
  VPSCATTERDQ   Z5, K4, 0(SI)(Y21*1)  // write trailing bits, hi 8 lanes

  VPMOVQD Z10, Y10
  VPMOVQD Z11, Y11
  VINSERTI64X4 $1, Y11, Z10, Z31
  VPADDD.BCST CONSTD_1(), Z31, Z31
  VPANDD.BCST.Z CONSTD_0x0F(), Z31, K1, Z31

  NEXT()

abort:
  MOVL $const_bcerrMoreScratch, bytecode_err(VIRT_BCPTR)
  RET_ABORT()

// compare
//   (Z9/Z10/Z11) timestamp and
//   (Z6/Z7/Z8) timestamp
// as
//   (Z6 < Z9) || (Z6 == Z9 && Z11 < Z8)
//
// note that comparisons are *unsigned*
#define TIME_COMPARE_TAIL(imm)    \
  KSHIFTRW $8, K1, K2             \
  VPCMPUQ  imm, Z9, Z6, K1, K3    \
  VPCMPUQ  imm, Z10, Z7, K2, K4   \
  VPCMPEQQ Z9, Z6, K1, K1         \
  VPCMPEQQ Z10, Z7, K2, K2        \
  KUNPCKBW K1, K2, K2             \
  KUNPCKBW K3, K4, K1             \
  VPCMPUD  imm, Z11, Z8, K2, K2   \
  KORW     K1, K2, K1

// compare two timestamps using '<'
// with the following register layout:
//   Z6: lhs first 8 timestamps, first 8 sig. bytes
//   Z7: lhs second 8 timestamps, first 8 sig. bytes
//   Z8: lhs all 16 timestamps, last 4 bytes
//   Z9-Z11: same as above, rhs
//
// the bcconsttm() instruction prepares
// registers according to this ABI
TEXT bctimelt(SB), NOSPLIT|NOFRAME, $0
  TIME_COMPARE_TAIL($VPCMP_IMM_LT)
  NEXT()

// same as above, with direction reversed
TEXT bctimegt(SB), NOSPLIT|NOFRAME, $0
  TIME_COMPARE_TAIL($VPCMP_IMM_GT)
  NEXT()

// load constant timestamp plus
// variable timestamp in Z2:Z3;
// this instruction should always be
// followed by bctimegt() or bctimelt()
// (see above)
TEXT bcconsttm(SB), NOSPLIT|NOFRAME, $0
  IMM_FROM_DICT(R8)
  VPXORD       Z6, Z6, Z6
  VPXORD       Z7, Z7, Z7
  VPXORD       Z8, Z8, Z8
  VPXORD       Z11, Z11, Z11  // microseconds = 0
  MOVQ         0(R8), R15     // R15 = &constant[0]
  CMPQ         8(R8), $13     // if len(constant)==13, then microsecond component exists
  JNE          no_tail
  MOVL         9(R15), R8
  BSWAPL       R8
  ANDL         $0xFFFFFF, R8
  VPBROADCASTD R8, Z11        // microseconds = bswap32(encoded[8:]) & 0xFFFFFF
no_tail:
  MOVQ         1(R15), R15
  BSWAPQ       R15
  VPBROADCASTQ R15, Z9        // Z9 = bswap64(first 8 bytes of timestamp)
  VMOVDQA64    Z9, Z10        // Z10 = same as Z9
  // now load variable portion:
  VBROADCASTI64X2  CONST_GET_PTR(bswap64, 0), Z20
  VBROADCASTI32X4  CONST_GET_PTR(bswap24_zero_last_byte, 0), Z24
  KMOVB            K1, K2
  KSHIFTRW         $8, K1, K3
  VEXTRACTI32X8    $1, Z2, Y4
  VPGATHERDQ       0(SI)(Y2*1), K2, Z6 // first 8 lanes, 8 sig. bytes
  VPGATHERDQ       0(SI)(Y4*1), K3, Z7 // second 8 lanes, 8 sig. bytes
  VPCMPEQD.BCST    CONSTD_12(), Z3, K1, K2
  VPGATHERDD       8(SI)(Z2*1), K2, Z8 // all 16 lanes, last 4 bytes when length=12
  VPSHUFB          Z20, Z6, Z6         // bswap first 8 bytes in all 16 lanes
  VPSHUFB          Z20, Z7, Z7
  VPSHUFB          Z24, Z8, Z8         // bswap microseconds in all 16 lanes
  NEXT()

// TODO: This is a remainder from an older timestamp code still in use.
#define TIME_LO  Z5
#define TIME_HI  Z6
#define MASK_LO  Z7
#define MASK_HI  Z8
#define MERGE_LO Z9
#define MERGE_HI Z10
#define TMPZ     Z11
#define TMPY     Y11 /* needs to point to same register as TMPZ */
#define TMP_LO   Z12
#define TMP_HI   Z13

// Load a timestamp from Z2:Z3 into Z5:Z6
// while taking the proper length in Z3 into
// account to 'normalize' unspecified components
#define TIMESTAMP_LOAD_LE                              \
    KMOVB         K1, K2                               \
    KSHIFTRW      $8, K1, K3                           \
    VEXTRACTI32X8 $1, Z2, Y4                           \
    VPGATHERDQ    0(SI)(Y2*1), K2, TIME_LO             \
    VPGATHERDQ    0(SI)(Y4*1), K3, TIME_HI             \
                                                       \
    VPCMPUD.BCST $5, CONSTD_8(), Z3, K1, K2            \
    KTESTW       K1, K2                                \
    /* skip truncation in case all lengths >= 8 */     \
    JC           skip_truncation                       \
                                                       \
    /* compute shift for mask to */                    \
    /* blend out the fields      */                    \
    VPBROADCASTD CONSTD_8(), TMPZ                      \
    VPSUBD       Z3, TMPZ, TMPZ                        \
    VPSLLD       $3, TMPZ, TMPZ                        \
                                                       \
    /* expand shifts into two Z registers */           \
    VPMOVZXDQ     TMPY, TMP_LO                         \
    VEXTRACTI32X8 $1, TMPZ, TMPY                       \
    VPMOVZXDQ     TMPY, TMP_HI                         \
                                                       \
    /* create masks for bytes to keep */               \
    /* by shifting in 0s from the MSB */               \
    VPBROADCASTQ CONSTQ_NEG_1(), MASK_LO               \
    VMOVDQU32    MASK_LO, MASK_HI                      \
    VPSRLVQ      TMP_LO, MASK_LO, MASK_LO              \
    VPSRLVQ      TMP_HI, MASK_HI, MASK_HI              \
                                                       \
    /* mask to merge in '1' for */                     \
    /* both day & month in case */                     \
    /* they are cleared out     */                     \
    VPBROADCASTQ CONSTQ_0x0000000101000000(), TMP_LO   \
    VPANDNQ      TMP_LO, MASK_LO, MERGE_LO             \
    VPANDNQ      TMP_LO, MASK_HI, MERGE_HI             \
                                                       \
    /* make sure termination bits are always set */    \
    VPBROADCASTQ CONSTQ_0x8080808080800080(), TMP_LO   \
    VPORQ        TMP_LO, MERGE_LO, MERGE_LO            \
    VPORQ        TMP_LO, MERGE_HI, MERGE_HI            \
                                                       \
    /* only modify lanes with lengths < 8 */           \
    KNOTW        K2, K3                                \
    /* do TIME_LO = TIME_LO & MASK_LO | MERGE_LO */    \
    VPTERNLOGQ   $0xEA, MERGE_LO, MASK_LO, K3, TIME_LO \
    KSHIFTRW     $8, K3, K3                            \
    VPTERNLOGQ   $0xEA, MERGE_HI, MASK_HI, K3, TIME_HI \
                                                       \
skip_truncation:

// bctmextract
//  input:
//   K1: lanes
//   Z2: timestamp offset
//   Z3: timestamp length
//   R8: year/month/day/hour/minute/second
//  output:
//   Z2: extracted value (lower 8)
//   Z3: extracted value (upper 8)
//  clobbers:
//   Z4-Z11, K2-K3
TEXT bctmextract(SB), NOSPLIT|NOFRAME, $0
    TIMESTAMP_LOAD_LE
    MOVBQZX      0(VIRT_PCREG), R8
    ADDQ         $1, VIRT_PCREG
    CMPQ         R8, $0
    JZ           years

    // extract single byte
    SHLQ         $3, R8
    ADDQ         $16, R8
    VPBROADCASTQ R8, Z4
    // extract months/days/hours/minutes/seconds
    VPSRLVQ      Z4, TIME_LO, Z10
    VPSRLVQ      Z4, TIME_HI, Z11
    VPBROADCASTQ CONSTQ_0x7F(), Z9
    VPANDQ       Z9, Z10, Z2  // months (lower)
    VPANDQ       Z9, Z11, Z3  // months (upper)
    JMP          done

years:
    // extract years
    VPSRLQ       $16, TIME_LO, Z7
    VPSRLQ       $16, TIME_HI, Z8
    VPBROADCASTQ CONSTQ_0x7F(), Z9
    VPANDQ       Z9, Z7, Z7
    VPANDQ       Z9, Z8, Z8
    VPSRLQ       $1, TIME_LO, Z10
    VPSRLQ       $1, TIME_HI, Z11
    VPBROADCASTQ CONSTQ_0x3F80(), Z4
    VPANDQ       Z4, Z10, Z10
    VPANDQ       Z4, Z11, Z11
    VPORQ        Z7, Z10, Z2
    VPORQ        Z8, Z11, Z3

done:
    NEXT()

#undef TIME_LO
#undef TIME_HI
#undef MASK_LO
#undef MASK_HI
#undef MERGE_LO
#undef MERGE_HI
#undef TMPZ
#undef TMPY
#undef TMP_LO
#undef TMP_HI
#undef TIMESTAMP_LOAD_LE

// Bucket Instructions
// -------------------

// Widthbucket (float)
//
// WIDTH_BUCKET semantics is as follows:
//   - When the input is less than MIN, the output is 0
//   - When the input is greater than or equal to MAX, the output is BucketCount+1
//
// Some references that I have found that explicitly state that MAX is outside:
//   - https://www.oreilly.com/library/view/sql-in-a/9780596155322/re91.html
//   - https://docs.oracle.com/cd/B19306_01/server.102/b14200/functions214.htm
//   - https://docs.snowflake.com/en/sql-reference/functions/width_bucket.html
TEXT bcwidthbucketf(SB), NOSPLIT|NOFRAME, $0
  KSHIFTRW      $8, K1, K2

  // MinValue
  MOVWQZX       0(VIRT_PCREG), R8
  VMOVUPD.Z     0(VIRT_VALUES)(R8*1), K1, Z4
  VMOVUPD.Z     64(VIRT_VALUES)(R8*1), K2, Z5

  // MaxValue
  MOVWQZX       2(VIRT_PCREG), R8
  VMOVUPD.Z     0(VIRT_VALUES)(R8*1), K1, Z6
  VMOVUPD.Z     64(VIRT_VALUES)(R8*1), K2, Z7

  // Value = Input - MinValue
  VSUBPD.RD_SAE Z4, Z2, K1, Z2
  VSUBPD.RD_SAE Z5, Z3, K2, Z3

  // ValueRange = MaxValue - MinValue
  VSUBPD.RD_SAE Z4, Z6, Z6
  VSUBPD.RD_SAE Z5, Z7, Z7

  // Value = (Input - MinValue) / (MaxValue - MinValue)
  VDIVPD.RD_SAE Z6, Z2, K1, Z2
  VDIVPD.RD_SAE Z7, Z3, K2, Z3

  // BucketCount
  MOVWQZX       4(VIRT_PCREG), R8
  VMOVUPD.Z     0(VIRT_VALUES)(R8*1), K1, Z4
  VMOVUPD.Z     64(VIRT_VALUES)(R8*1), K2, Z5

  // Value = ((Input - MinValue) / (MaxValue - MinValue)) * BucketCount
  VMULPD.RD_SAE Z4, Z2, K1, Z2
  VMULPD.RD_SAE Z5, Z3, K2, Z3

  // Round to integer - this operation would preserve special numbers (Inf/NaN).
  VRNDSCALEPD   $VROUND_IMM_DOWN_SAE, Z2, K1, Z2
  VRNDSCALEPD   $VROUND_IMM_DOWN_SAE, Z3, K2, Z3

  // Restrict output values to [0, BucketCount + 1] range
  VBROADCASTSD  CONSTF64_1(), Z6
  VMINPD        Z4, Z2, K1, Z2
  VMINPD        Z5, Z3, K2, Z3
  VADDPD        Z6, Z2, K1, Z2
  VADDPD        Z6, Z3, K2, Z3
  VXORPD        X6, X6, X6
  VMAXPD        Z6, Z2, K1, Z2
  VMAXPD        Z6, Z3, K2, Z3

  NEXT_ADVANCE(6)

// widthbucket (int)
//
// NOTE: This function has some precision loss when the arithmetic exceeds 2^53.
TEXT bcwidthbucketi(SB), NOSPLIT|NOFRAME, $0
  KSHIFTRW $8, K1, K2

  // MinValue.I64
  MOVWQZX 0(VIRT_PCREG), R8
  VMOVDQU64.Z 0(VIRT_VALUES)(R8*1), K1, Z4
  VMOVDQU64.Z 64(VIRT_VALUES)(R8*1), K2, Z5

  // MaxValue.I64
  MOVWQZX 2(VIRT_PCREG), R8
  VMOVDQU64.Z 0(VIRT_VALUES)(R8*1), K1, Z6
  VMOVDQU64.Z 64(VIRT_VALUES)(R8*1), K2, Z7

  // K3/K4 = Value < MinValue
  VPCMPQ $VPCMP_IMM_LT, Z4, Z2, K1, K3
  VPCMPQ $VPCMP_IMM_LT, Z5, Z3, K2, K4

  // Value.U64 = Input - MinValue
  VPSUBQ Z4, Z2, K1, Z2
  VPSUBQ Z5, Z3, K2, Z3

  // ValueRange.U64 = MaxValue - MinValue
  VPSUBQ Z4, Z6, Z6
  VPSUBQ Z5, Z7, Z7

  // Value.F64 = (F64)Value.U64
  VCVTUQQ2PD Z2, K1, Z2
  VCVTUQQ2PD Z3, K2, Z3

  // ValueRange.F64 = (F64)ValueRange.U64
  VCVTUQQ2PD Z6, Z6
  VCVTUQQ2PD Z7, Z7

  // Value.F64 = (Input - MinValue) / (MaxValue - MinValue)
  VDIVPD.RD_SAE Z6, Z2, K1, Z2
  VDIVPD.RD_SAE Z7, Z3, K2, Z3

  // BucketCount.U64
  MOVWQZX 4(VIRT_PCREG), R8
  VMOVDQU64.Z 0(VIRT_VALUES)(R8*1), K1, Z4
  VMOVDQU64.Z 64(VIRT_VALUES)(R8*1), K2, Z5

  // BucketCount.F64 = (F64)BucketCount.U64
  VCVTQQ2PD Z4, Z6
  VCVTQQ2PD Z5, Z7

  // Value.F64 = ((Input - MinValue) / (MaxValue - MinValue)) * BucketCount
  VMULPD.RD_SAE Z6, Z2, K1, Z2
  VMULPD.RD_SAE Z7, Z3, K2, Z3

  // Value.I64 = (I64)Value.F64
  VCVTTPD2QQ Z2, K1, Z2
  VCVTTPD2QQ Z3, K2, Z3

  // Restrict output values to [0, BucketCount + 1] range
  VPBROADCASTQ CONSTQ_1(), Z10
  VPMINSQ Z4, Z2, K1, Z2
  VPMINSQ Z5, Z3, K2, Z3
  VPADDQ Z10, Z2, K1, Z2
  VPADDQ Z10, Z3, K2, Z3
  VPXORQ Z2, Z2, K3, Z2
  VPXORQ Z3, Z3, K4, Z3

  NEXT_ADVANCE(6)

// timebucket (timestamp)
TEXT bctimebucketts(SB), NOSPLIT|NOFRAME, $0
  KSHIFTRW     $8, K1, K2

  // Load interval from stack
  MOVWQZX       0(VIRT_PCREG), R8
  VMOVDQU64.Z   0(VIRT_VALUES)(R8*1), K1, Z4
  VMOVDQU64.Z   64(VIRT_VALUES)(R8*1), K2, Z5

  BC_MODI64_IMPL(Z16, Z17, Z2, Z3, Z4, Z5, K1, K2, Z6, Z7, Z8, Z9, Z10, Z11, Z12, Z13, Z14, Z15, K3, K4)

  // subtract modulo value from source in order
  // to get the start value of the bucket
  VPSUBQ Z16, Z2, K1, Z2
  VPSUBQ Z17, Z3, K2, Z3

  NEXT_ADVANCE(2)

// GEO Functions
// -------------

#define CONST_GEO_TILE_MAX_PRECISION() CONSTQ_32()

// Calculates GEO HASH bits with full precision.
//
// The output can contain many bits, so it's necessary to BIT-AND the results to get the designated precision.
#define BC_SCALE_GEO_COORDINATES(DST_LAT_A, DST_LAT_B, DST_LON_A, DST_LON_B, SRC_LAT_A, SRC_LAT_B, SRC_LON_A, SRC_LON_B, TMP_0) \
  /* Scale latitude values. */                                 \
  VBROADCASTSD CONSTQ_0x3D86800000000000(), TMP_0              \
  VDIVPD.RD_SAE TMP_0, SRC_LAT_A, DST_LAT_A                    \
  VDIVPD.RD_SAE TMP_0, SRC_LAT_B, DST_LAT_B                    \
                                                               \
  /* Scale longitude values. */                                \
  VBROADCASTSD CONSTQ_0x3D96800000000000(), TMP_0              \
  VDIVPD.RD_SAE TMP_0, SRC_LON_A, DST_LON_A                    \
  VDIVPD.RD_SAE TMP_0, SRC_LON_B, DST_LON_B                    \
                                                               \
  /* Convert to integers. */                                   \
  VPBROADCASTQ CONSTQ_35184372088832(), TMP_0                  \
  VCVTPD2QQ.RD_SAE DST_LAT_A, DST_LAT_A                        \
  VCVTPD2QQ.RD_SAE DST_LAT_B, DST_LAT_B                        \
                                                               \
  VCVTPD2QQ.RD_SAE DST_LON_A, DST_LON_A                        \
  VCVTPD2QQ.RD_SAE DST_LON_B, DST_LON_B                        \
                                                               \
  /* Scaled latitude values to integers of full precision. */  \
  VPADDQ TMP_0, DST_LAT_A, DST_LAT_A                           \
  VPADDQ TMP_0, DST_LAT_B, DST_LAT_B                           \
                                                               \
  /* Scaled longitute values to integers of full precision. */ \
  VPADDQ TMP_0, DST_LON_A, DST_LON_A                           \
  VPADDQ TMP_0, DST_LON_B, DST_LON_B

// GEO_HASH is a string representing longitude, latitude, and precision as "HASH" where each
// 5 bits of interleaved latitude and longitude data are encoded by a single ASCII character.
TEXT bcgeohash(SB), NOSPLIT|NOFRAME, $0
  KSHIFTRW $8, K1, K2
  MOVWQZX 0(VIRT_PCREG), R8
  MOVWQZX 2(VIRT_PCREG), R15

  // Z8/Z9 <- Precision in bits.
  VMOVDQU64.Z 0(VIRT_VALUES)(R15*1), K1, Z8
  VMOVDQU64.Z 64(VIRT_VALUES)(R15*1), K2, Z9

  JMP geohash_tail(SB)

TEXT bcgeohashimm(SB), NOSPLIT|NOFRAME, $0
  KSHIFTRW $8, K1, K2
  MOVWQZX 0(VIRT_PCREG), R8
  MOVWQZX 2(VIRT_PCREG), R15

  // Z8/Z9 <- Precision in bits.
  VPBROADCASTQ R15, Z8
  VPBROADCASTQ R15, Z9

  JMP geohash_tail(SB)

TEXT geohash_tail(SB), NOSPLIT|NOFRAME, $0
  // Z4/Z5 <- Latitude.
  VMOVAPD.Z Z2, K1, Z4
  VMOVAPD.Z Z3, K2, Z5

  // Z6/Z7 <- Longitude.
  VMOVUPD.Z 0(VIRT_VALUES)(R8*1), K1, Z6
  VMOVUPD.Z 64(VIRT_VALUES)(R8*1), K2, Z7

  VPMOVSQD Z8, Y8
  VPMOVSQD Z9, Y9
  VINSERTI32X8 $1, Y9, Z8, Z3

  // Z4/Z5/Z6/Z7 <- Scaled latitude and longitude bits with full precision.
  BC_SCALE_GEO_COORDINATES(Z4, Z5, Z6, Z7, Z4, Z5, Z6, Z7, Z10)

  // Restrict precision to [1, 12] characters (12 characters is 60 bits, which is the maximum).
  VPMAXSD.BCST CONSTD_1(), Z3, Z3
  VPMINSD.BCST.Z CONSTD_12(), Z3, K1, Z3

  // At the moment the output bits contain 46 bits representing latitude and longitude.
  // The maximum precision of geohash we support is 12 (30 bits for each coordinate),
  // so cut off the extra bits from both latitude and longitude.
  VPSRLQ $16, Z4, Z4
  VPSRLQ $16, Z5, Z5
  VPSRLQ $16, Z6, Z6
  VPSRLQ $16, Z7, Z7

  // Usually, GEO_HASH implementations first interleave all the bits of latitude
  // and logitude and then a lookup is used for each 5 bits chunk to get the
  // character representing it. However, this is unnecessary as we just need 5
  // bits of each chunk in any order to apply our own VPSHUFB lookups.
  //
  // We have this (latitude / longitude) (5 bits are used to compose a single character):
  //
  //   [__AABBBC|CDDDEEFF|FGGHHHII|JJJKKLLL] (Z4/Z5) (uppercased are latitudes)
  //   [__aaabbc|ccddeeef|fggghhii|ijjkkkll] (Z6/Z7) (lowercased are longitudes)
  //
  // But we want this so we would be able to encode the bits as GEO_HASH:
  //
  //   [________][________][___AAaaa][___CCccc][___EEeee][___GGggg][___IIiii][___KKkkk] {longitude has 3 bits}
  //   [________][________][___bbBBB][___ddDDD][___ffFFF][___hhHHH][___jjJJJ][___llLLL] {latitude has 3 bits}
  //
  // After this it's easy to use VPUNPCKLBW to interleave the bytes to get the final string.

  // VPTERNLOG(0xD8) == (A & ~C) | (B &  C) == Blend(A, B, ~C)
  // VPTERNLOG(0xE4) == (A &  C) | (B & ~C) == Blend(A, B,  C)

  // NOTE: This is basically a dumb approach to shuffle bits via shifting and masking.
  VPBROADCASTD CONSTD_0b11001110_01110011_10011100_11100111(), Z14

  VPSRLQ $2, Z6, Z10                            // [________|________|________|________|____aaab|bcccddee|effggghh|iiijjkkk] {lo}
  VPSRLQ $2, Z7, Z11                            // [________|________|________|________|____aaab|bcccddee|effggghh|iiijjkkk] {hi}
  VPSLLQ $3, Z6, Z6                             // [________|________|________|________|__bbcccd|deeeffgg|ghhiiijj|kkkll___] {lo}
  VPSLLQ $3, Z7, Z7                             // [________|________|________|________|__bbcccd|deeeffgg|ghhiiijj|kkkll___] {hi}

  VPTERNLOGD $0xD8, Z14, Z4, Z6                 // [________|________|________|________|__bbBBBd|dDDDffFF|FhhHHHjj|JJJllLLL] {lo}
  VPTERNLOGD $0xD8, Z14, Z5, Z7                 // [________|________|________|________|__bbBBBd|dDDDffFF|FhhHHHjj|JJJllLLL] {hi}
  VPTERNLOGD $0xD8, Z14, Z10, Z4                // [________|________|________|________|__AAaaaC|CcccEEee|eGGgggII|iiiKKkkk] {lo}
  VPTERNLOGD $0xD8, Z14, Z11, Z5                // [________|________|________|________|__AAaaaC|CcccEEee|eGGgggII|iiiKKkkk] {hi}

  VPBROADCASTQ CONSTQ_0xFFFFFF(), Z14
  VPSLLQ $9, Z4, Z10                            // [________|________|________|_AAaaaCC|cccEEeee|________|________|________] {lo}
  VPSLLQ $9, Z5, Z11                            // [________|________|________|_AAaaaCC|cccEEeee|________|________|________] {hi}
  VPSLLQ $9, Z6, Z12                            // [________|________|________|_bbBBBdd|DDDffFFF|________|________|________] {lo}
  VPSLLQ $9, Z7, Z13                            // [________|________|________|_bbBBBdd|DDDffFFF|________|________|________] {hi}

  VPTERNLOGQ $0xE4, Z14, Z10, Z4                // [________|________|________|_AAaaaCC|cccEEeee|________|eGGgggII|iiiKKkkk] {lo}
  VPTERNLOGQ $0xE4, Z14, Z11, Z5                // [________|________|________|_AAaaaCC|cccEEeee|________|eGGgggII|iiiKKkkk] {hi}
  VPTERNLOGQ $0xE4, Z14, Z12, Z6                // [________|________|________|_bbBBBdd|DDDffFFF|________|FhhHHHjj|JJJllLLL] {lo}
  VPTERNLOGQ $0xE4, Z14, Z13, Z7                // [________|________|________|_bbBBBdd|DDDffFFF|________|FhhHHHjj|JJJllLLL] {hi}

  VPSLLQ $3, Z4, Z10                            // [________|________|________|___CCccc|________|________|___IIiii|________] {lo}
  VPSLLQ $3, Z5, Z11                            // [________|________|________|___CCccc|________|________|___IIiii|________] {hi}
  VPSLLQ $3, Z6, Z12                            // [________|________|________|___ddDDD|________|________|___jjJJJ|________] {lo}
  VPSLLQ $3, Z7, Z13                            // [________|________|________|___ddDDD|________|________|___jjJJJ|________] {hi}

  VPSLLQ $6, Z4, Z14                            // [________|________|___AAaaa|________|________|___GGggg|________|________] {lo}
  VPSLLQ $6, Z5, Z15                            // [________|________|___AAaaa|________|________|___GGggg|________|________] {hi}
  VPSLLQ $6, Z6, Z16                            // [________|________|___bbBBB|________|________|___hhHHH|________|________] {lo}
  VPSLLQ $6, Z7, Z17                            // [________|________|___bbBBB|________|________|___hhHHH|________|________] {hi}

  VPBROADCASTQ CONSTQ_0b00000000_00000000_00000000_00000000_00011111_00000000_00000000_00011111(), Z18
  VPANDD Z18, Z4, Z4                            // [00000000|00000000|00000000|00000000|000EEeee|00000000|00000000|000KKkkk] {lo}
  VPANDD Z18, Z5, Z5                            // [00000000|00000000|00000000|00000000|000EEeee|00000000|00000000|000KKkkk] {hi}
  VPSLLQ $8, Z18, Z19
  VPANDD Z18, Z6, Z6                            // [00000000|00000000|00000000|00000000|000ffFFF|00000000|00000000|000llLLL] {lo}
  VPANDD Z18, Z7, Z7                            // [00000000|00000000|00000000|00000000|000ffFFF|00000000|00000000|000llLLL] {hi}

  VPSLLQ $16, Z18, Z18
  VPTERNLOGD $0xD8, Z19, Z10, Z4                // [00000000|00000000|00000000|000CCccc|000EEeee|00000000|000IIiii|000KKkkk] {lo}
  VPTERNLOGD $0xD8, Z19, Z11, Z5                // [00000000|00000000|00000000|000CCccc|000EEeee|00000000|000IIiii|000KKkkk] {hi}
  VPTERNLOGD $0xD8, Z19, Z12, Z6                // [00000000|00000000|00000000|000ddDDD|000ffFFF|00000000|000jjJJJ|000llLLL] {lo}
  VPTERNLOGD $0xD8, Z19, Z13, Z7                // [00000000|00000000|00000000|000ddDDD|000ffFFF|00000000|000jjJJJ|000llLLL] {hi}

  VPTERNLOGD $0xD8, Z18, Z14, Z4                // [00000000|00000000|000AAaaa|000CCccc|000EEeee|000GGggg|000IIiii|000KKkkk] {lo}
  VPTERNLOGD $0xD8, Z18, Z15, Z5                // [00000000|00000000|000AAaaa|000CCccc|000EEeee|000GGggg|000IIiii|000KKkkk] {hi}
  VPTERNLOGD $0xD8, Z18, Z16, Z6                // [00000000|00000000|000bbBBB|000ddDDD|000ffFFF|000hhHHH|000jjJJJ|000llLLL] {lo}
  VPTERNLOGD $0xD8, Z18, Z17, Z7                // [00000000|00000000|000bbBBB|000ddDDD|000ffFFF|000hhHHH|000jjJJJ|000llLLL] {hi}

  // Encode the bits into characters.
  //
  // NOTE: Since we need 32 entry LUT, we apply VPSHUFB twice, the second time with a mask that's only valid when `index > 15`.
  VPBROADCASTB CONSTD_15(), Z12
  VBROADCASTI32X4 CONST_GET_PTR(geohash_chars_lut,  0), Z10
  VBROADCASTI32X4 CONST_GET_PTR(geohash_chars_lut, 16), Z11

  VPCMPGTB Z12, Z4, K3
  VPCMPGTB Z12, Z5, K4
  VPSHUFB Z4, Z10, Z14
  VPSHUFB Z5, Z10, Z15
  VPSHUFB Z4, Z11, K3, Z14
  VPSHUFB Z5, Z11, K4, Z15

  VPCMPGTB Z12, Z6, K3
  VPCMPGTB Z12, Z7, K4
  VPSHUFB Z6, Z10, Z16
  VPSHUFB Z7, Z10, Z17
  VPSHUFB Z6, Z11, K3, Z16
  VPSHUFB Z7, Z11, K4, Z17

  // Make sure we have at least 16 bytes for each lane, we always overallocate to make the encoding easier.
  // The encoded hash per lane is 12 bytes, however, we store 16 byte quantities, so we need 16 bytes.
  VM_CHECK_SCRATCH_CAPACITY($(16 * 16), R8, abort)

  VM_GET_SCRATCH_BASE_GP(R8)

  // Update the length of the output buffer.
  ADDQ $(16 * 16), bytecode_scratch+8(VIRT_BCPTR)

  // Broadcast scratch base to all lanes in Z2, which becomes string slice offset.
  VPBROADCASTD.Z R8, K1, Z2

  VPADDD CONST_GET_PTR(consts_offsets_interleaved_d_16, 0), Z2, Z2

  // Make R8 the first address where the output will be stored.
  ADDQ SI, R8

  // Unpack so we will get 16 characters in each 128-bit part of the register.
  VPUNPCKLBW Z14, Z16, Z4  // Lane: [06][04][02][00]
  VPUNPCKHBW Z14, Z16, Z5  // Lane: [07][05][03][01]
  VPUNPCKLBW Z15, Z17, Z6  // Lane: [13][12][10][08]
  VPUNPCKHBW Z15, Z17, Z7  // Lane: [15][13][11][09]

  // Byteswap the characters, as we have the most significant last, at the moment.
  VBROADCASTI32X4 CONST_GET_PTR(geohash_chars_swap, 0), Z10
  VPSHUFB Z10, Z4, Z4
  VPSHUFB Z10, Z5, Z5
  VPSHUFB Z10, Z6, Z6
  VPSHUFB Z10, Z7, Z7

  // Store directly (avoiding scatter).
  VMOVDQU32 Z4, 0(R8)
  VMOVDQU32 Z5, 64(R8)
  VMOVDQU32 Z6, 128(R8)
  VMOVDQU32 Z7, 192(R8)

  NEXT_ADVANCE(4)

abort:
  MOVL $const_bcerrMoreScratch, bytecode_err(VIRT_BCPTR)
  RET_ABORT()

// GEO_TILE_X and GEO_TILE_Y functions project latitude and logitude by using Mercator.

// X = FLOOR( (longitude + 180.0) / 360.0 * (1 << zoom) )
//   = FLOOR( [(1 << 48) / 2] + FMA(longitude * [(1 << 48) / 360]) >> (48 - precision)
TEXT bcgeotilex(SB), NOSPLIT|NOFRAME, $0
  KSHIFTRW $8, K1, K2
  MOVWQZX 0(VIRT_PCREG), R8

  VBROADCASTSD CONSTF64_281474976710656_DIV_360(), Z6
  VBROADCASTSD CONSTF64_140737488355328(), Z7

  VFMADD132PD.RZ_SAE Z6, Z7, K1, Z2
  VFMADD132PD.RZ_SAE Z6, Z7, K2, Z3

  VCVTPD2UQQ.RZ_SAE Z2, Z4
  VCVTPD2UQQ.RZ_SAE Z3, Z5

  VPXORQ X8, X8, X8
  VPBROADCASTQ CONST_GEO_TILE_MAX_PRECISION(), Z9
  VPMAXSQ 0(VIRT_VALUES)(R8*1), Z8, Z6
  VPMAXSQ 64(VIRT_VALUES)(R8*1), Z8, Z7

  VPBROADCASTQ CONSTQ_0x0000FFFFFFFFFFFF(), Z11
  VPMINSQ Z9, Z6, Z6
  VPMINSQ Z9, Z7, Z7

  VPBROADCASTQ CONSTQ_48(), Z9
  VPMINSQ Z11, Z4, Z4
  VPMINSQ Z11, Z5, Z5

  VPSUBQ Z6, Z9, Z6
  VPSUBQ Z7, Z9, Z7

  VPSRLVQ Z6, Z4, K1, Z2
  VPSRLVQ Z7, Z5, K2, Z3

  NEXT_ADVANCE(2)

// Y = FLOOR( {0.5 - [LN((1 + SIN(lat)) / (1 - SIN(lat))] / (4*PI)} * (1 << precision) );
//   = FLOOR( [1 << 48) / 2] - [LN((1 + SIN(lat)) / (1 - SIN(lat)) * (1 << 48) / (4*PI)] ) >> (48 - precision));
TEXT bcgeotiley(SB), NOSPLIT|NOFRAME, $0
  KSHIFTRW $8, K1, K2
  MOVWQZX 0(VIRT_PCREG), R8

  VBROADCASTSD CONSTF64_PI_DIV_180(), Z11
  VBROADCASTSD CONSTF64_1(), Z10

  VMULPD Z11, Z2, K1, Z2
  VMULPD Z11, Z3, K2, Z3
  BC_FAST_SIN_4ULP(Z4, Z5, Z2, Z3)

  // Truncate to [-0.9999, 0.9999] to avoid infinity in border cases.
  VBROADCASTSD CONSTF64_0p9999(), Z11
  VBROADCASTSD CONSTF64_MINUS_0p9999(), Z12
  VMINPD Z11, Z4, Z4
  VMINPD Z11, Z5, Z5
  VMAXPD Z12, Z4, Z4
  VMAXPD Z12, Z5, Z5

  // Z6/Z7 <- 1 - SIN(lat)
  VSUBPD Z4, Z10, Z6
  VSUBPD Z5, Z10, Z7

  // Z4/Z5 <- 1 + SIN(lat)
  VADDPD Z4, Z10, Z4
  VADDPD Z5, Z10, Z5

  // Z4/Z5 <- LN((1 + SIN(lat)) / (1 - SIN(lat)))
  VDIVPD Z6, Z4, Z6
  VDIVPD Z7, Z5, Z7
  BC_FAST_LN_4ULP(Z4, Z5, Z6, Z7)

  VBROADCASTSD CONSTF64_281474976710656_DIV_4PI(), Z10
  VBROADCASTSD CONSTF64_140737488355328(), Z11

  // Z6/Z7 <- [(1 << 48) / 2] - (LN((1 + SIN(lat)) / (1 - SIN(lat))) * [(1 << 48) / 4*PI]
  VFNMADD213PD Z11, Z10, Z4 // Z4 = Z11 - (Z10 * Z4)
  VFNMADD213PD Z11, Z10, Z5 // Z5 = Z11 - (Z10 * Z5)

  VPXORQ X8, X8, X8
  VPBROADCASTQ CONST_GEO_TILE_MAX_PRECISION(), Z9
  VPMAXSQ 0(VIRT_VALUES)(R8*1), Z8, Z6
  VPMAXSQ 64(VIRT_VALUES)(R8*1), Z8, Z7

  VCVTPD2UQQ.RZ_SAE Z4, Z4
  VCVTPD2UQQ.RZ_SAE Z5, Z5

  VPBROADCASTQ CONSTQ_0x0000FFFFFFFFFFFF(), Z11
  VPMINSQ Z9, Z6, Z6
  VPMINSQ Z9, Z7, Z7

  VPBROADCASTQ CONSTQ_48(), Z9
  VPMINSQ Z11, Z4, Z4
  VPMINSQ Z11, Z5, Z5

  VPSUBQ Z6, Z9, Z6
  VPSUBQ Z7, Z9, Z7

  VPSRLVQ Z6, Z4, K1, Z2
  VPSRLVQ Z7, Z5, K2, Z3

  NEXT_ADVANCE(2)

// GEO_TILE_ES() projects latitude and longitude coordinates by using Mercator function
// and encodes them as "Precision/X/Y" string, which is compatible with Elastic Search.

// Extracts uint16[0|1] of each 64-bit lane and byteswaps it - ((input >> (Index * 16)) & 0xFFFF) << 48
CONST_DATA_U64(const_geotilees_extract_u16, 0, $0x0100FFFFFFFFFFFF)
CONST_DATA_U64(const_geotilees_extract_u16, 8, $0x0908FFFFFFFFFFFF)
CONST_DATA_U64(const_geotilees_extract_u16, 16, $0x0302FFFFFFFFFFFF)
CONST_DATA_U64(const_geotilees_extract_u16, 24, $0x0B0AFFFFFFFFFFFF)
CONST_GLOBAL(const_geotilees_extract_u16, $32)

// Extracts uint16[0|1|2] of each 64-bit lane and byteswaps it - bswap16((input >> (Index * 16)) & 0xFFFF)
CONST_DATA_U64(const_geotilees_extract_u16_bswap, 0, $0xFFFFFFFFFFFF0001)
CONST_DATA_U64(const_geotilees_extract_u16_bswap, 8, $0xFFFFFFFFFFFF0809)
CONST_DATA_U64(const_geotilees_extract_u16_bswap, 16, $0xFFFFFFFFFFFF0203)
CONST_DATA_U64(const_geotilees_extract_u16_bswap, 24, $0xFFFFFFFFFFFF0A0B)
CONST_DATA_U64(const_geotilees_extract_u16_bswap, 32, $0xFFFFFFFFFFFF0405)
CONST_DATA_U64(const_geotilees_extract_u16_bswap, 40, $0xFFFFFFFFFFFF0C0D)
CONST_GLOBAL(const_geotilees_extract_u16_bswap, $48)

TEXT bcgeotilees(SB), NOSPLIT|NOFRAME, $0
  KSHIFTRW $8, K1, K2
  MOVWQZX 0(VIRT_PCREG), R8
  MOVWQZX 2(VIRT_PCREG), R15

  // Z8/Z9 <- Precision in bits.
  VMOVDQU64.Z 0(VIRT_VALUES)(R15*1), K1, Z8
  VMOVDQU64.Z 64(VIRT_VALUES)(R15*1), K2, Z9

  JMP geotilees_tail(SB)

TEXT bcgeotileesimm(SB), NOSPLIT|NOFRAME, $0
  KSHIFTRW $8, K1, K2
  MOVWQZX 0(VIRT_PCREG), R8
  MOVWQZX 2(VIRT_PCREG), R15

  // Z8/Z9 <- Precision in bits.
  VPBROADCASTQ R15, Z8
  VPBROADCASTQ R15, Z9

  JMP geotilees_tail(SB)

TEXT geotilees_tail(SB), NOSPLIT|NOFRAME, $0
  // Make sure we have at least 32 bytes for each lane, we always overallocate to make the conversion easier.
  VM_CHECK_SCRATCH_CAPACITY($(32 * 16), R15, abort)

  VM_GET_SCRATCH_BASE_GP(R15)

  // Update the length of the output buffer.
  ADDQ $(32 * 16), bytecode_scratch+8(VIRT_BCPTR)

  // Z4/Z5 <- Projected latitude to Y.
  VBROADCASTSD CONSTF64_PI_DIV_180(), Z11
  VBROADCASTSD CONSTF64_1(), Z10
  VMULPD Z11, Z2, K1, Z2
  VMULPD Z11, Z3, K2, Z3

  BC_FAST_SIN_4ULP(Z4, Z5, Z2, Z3)

  // Truncate to [-0.9999, 0.9999] to avoid infinity in border cases.
  VBROADCASTSD CONSTF64_0p9999(), Z11
  VBROADCASTSD CONSTF64_MINUS_0p9999(), Z12
  VMINPD Z11, Z4, Z4
  VMINPD Z11, Z5, Z5
  VMAXPD Z12, Z4, Z4
  VMAXPD Z12, Z5, Z5

  // Z6/Z7 <- 1 - SIN(lat)
  VSUBPD Z4, Z10, Z6
  VSUBPD Z5, Z10, Z7

  // Z4/Z5 <- 1 + SIN(lat)
  VADDPD Z4, Z10, Z4
  VADDPD Z5, Z10, Z5

  // Z4/Z5 <- LN((1 + SIN(lat)) / (1 - SIN(lat)))
  VDIVPD Z6, Z4, Z6
  VDIVPD Z7, Z5, Z7
  BC_FAST_LN_4ULP(Z4, Z5, Z6, Z7)

  VBROADCASTSD CONSTF64_281474976710656_DIV_4PI(), Z10
  VBROADCASTSD CONSTF64_140737488355328(), Z11
  VFNMADD213PD Z11, Z10, Z4 // Z4 = Z11 - (Z10 * Z4)
  VFNMADD213PD Z11, Z10, Z5 // Z5 = Z11 - (Z10 * Z5)

  VBROADCASTSD CONSTF64_281474976710656_DIV_360(), Z10
  VCVTPD2UQQ.RZ_SAE Z4, Z4
  VCVTPD2UQQ.RZ_SAE Z5, Z5

  // Z6/Z7 <- Projected longitude to X.
  VMOVUPD 0(VIRT_VALUES)(R8*1), Z6
  VMOVUPD 64(VIRT_VALUES)(R8*1), Z7
  VFMADD132PD.RZ_SAE Z10, Z11, K1, Z6
  VFMADD132PD.RZ_SAE Z10, Z11, K2, Z7

  VCVTPD2UQQ.RZ_SAE Z6, Z6
  VCVTPD2UQQ.RZ_SAE Z7, Z7

  // Z8/Z9 <- Clamped precision.
  VPXORQ X10, X10, X10
  VPBROADCASTQ CONST_GEO_TILE_MAX_PRECISION(), Z11
  VPMAXSQ Z10, Z8, Z8
  VPMAXSQ Z10, Z9, Z9
  VPMINSQ Z11, Z8, Z8
  VPMINSQ Z11, Z9, Z9

  VPBROADCASTQ CONSTQ_0x0000FFFFFFFFFFFF(), Z10
  VPBROADCASTQ CONSTQ_48(), Z11
  VPMINSQ Z10, Z4, Z4
  VPMINSQ Z10, Z5, Z5

  // Z8/Z9 <- How many bits to shift X and Y to get the desired precision.
  VPSUBQ Z8, Z11, Z10
  VPSUBQ Z9, Z11, Z11

  // Z4/Z5 <- Y bits.
  // Z6/Z7 <- X bits.
  VPSRLVQ Z10, Z4, Z4
  VPSRLVQ Z11, Z5, Z5
  VPSRLVQ Z10, Z6, Z6
  VPSRLVQ Z11, Z7, Z7

  // We have two 32-bit numbers in Z4/Z5 and Z6/Z7 representing Y/X tiles. We can
  // use the same approach as we use in 'i64tostr' instruction, however, it's
  // slightly different as we need to stringify only 32-bit unsigned numbers (so
  // no sign handling, for example) and one value representing the precision,
  // which only requires 1-2 digits.
  //
  // Stringifying a 32-bit number can be split into the following
  //
  //   - stringify low 8 characters
  //   - stringify high 2 characters.
  //
  // This means that we need four registers to strinfigy low 8-char X/Y tiles,
  // and two registers to strinfigy the rest, which represents 2 high characters
  // of latitude and longitude, and 2 characters of precision. We do a bit of
  // shuffling to actually only need one register pair to stringify the remaining
  // 2 high characters of latitude and longitude, and also the whole precision as
  // it's guaranteed to be less than 100.

  VPBROADCASTQ CONSTQ_1441151881(), Z17
  VPBROADCASTQ CONSTQ_100000000(), Z13

  VPMULUDQ Z17, Z4, Z14
  VPMULUDQ Z17, Z5, Z15
  VPMULUDQ Z17, Z6, Z16
  VPMULUDQ Z17, Z7, Z17

  // Z14/Z15 - Y / 100000000 (high 2 chars)
  // Z16/Z17 - X / 100000000 (high 2 chars)
  VPSRLQ $57, Z14, Z14
  VPSRLQ $57, Z15, Z15
  VPSRLQ $57, Z16, Z16
  VPSRLQ $57, Z17, Z17

  VPMULUDQ Z13, Z14, Z10
  VPMULUDQ Z13, Z15, Z11
  VPMULUDQ Z13, Z16, Z12
  VPMULUDQ Z13, Z17, Z13

  // Z4/Z5 - Y % 100000000 (low 8 chars)
  // Z6/Z7 - X % 100000000 (low 8 chars)
  VPSUBQ Z10, Z4, Z4
  VPSUBQ Z11, Z5, Z5
  VPSUBQ Z12, Z6, Z6
  VPSUBQ Z13, Z7, Z7

  // Z14/Z15 <- [0][Z][X][Y]
  VPSLLQ $16, Z16, Z16
  VPSLLQ $16, Z17, Z17
  VPSLLQ $32, Z8, Z8
  VPSLLQ $32, Z9, Z9

  VPTERNLOGQ $0xFE, Z16, Z14, Z8 // Z14 = Z14 | Z16 | Z8
  VPTERNLOGQ $0xFE, Z17, Z15, Z9 // Z15 = Z15 | Z17 | Z9

  // Stringify
  // ---------

  BC_UINT_TO_STR_STEP_10000_PREPARE(OUT(Z26), OUT(Z27))
  BC_UINT_TO_STR_STEP_10000_4X(IN_OUT(Z4), IN_OUT(Z5), IN_OUT(Z6), IN_OUT(Z7), IN(Z26), IN(Z27), CLOBBER(Z22), CLOBBER(Z23), CLOBBER(Z24), CLOBBER(Z25))

  BC_UINT_TO_STR_STEP_100_PREPARE(OUT(Z26), OUT(Z27))
  BC_UINT_TO_STR_STEP_100_4X(IN_OUT(Z4), IN_OUT(Z5), IN_OUT(Z6), IN_OUT(Z7), IN(Z26), IN(Z27), CLOBBER(Z22), CLOBBER(Z23), CLOBBER(Z24), CLOBBER(Z25))

  BC_UINT_TO_STR_STEP_10_PREPARE(OUT(Z26), OUT(Z27))
  BC_UINT_TO_STR_STEP_10_6X(IN_OUT(Z4), IN_OUT(Z5), IN_OUT(Z6), IN_OUT(Z7), IN_OUT(Z8), IN_OUT(Z9), IN(Z26), IN(Z27), CLOBBER(Z22), CLOBBER(Z23), CLOBBER(Z24), CLOBBER(Z25))

  // Prepare Outputs
  // ---------------

  VPBROADCASTQ R15, Z21
  VPBROADCASTQ CONSTQ_64(), Z24
  VPBROADCASTD CONSTD_7(), Z25
  VPSLLQ.BCST $56, CONSTQ_1(), Z26

  VPADDQ.Z CONST_GET_PTR(consts_offsets_q_32, 8), Z21, K1, Z20
  VPADDQ.Z CONST_GET_PTR(consts_offsets_q_32, 8+64), Z21, K2, Z21

  // Prepend "/Y"
  // ------------

  VBROADCASTI32X4 CONST_GET_PTR(bswap64, 0), Z27
  VPSHUFB Z27, Z4, Z10
  VPSHUFB Z27, Z5, Z11
  VPORQ Z24, Z10, Z10
  VPORQ Z24, Z11, Z11

  VBROADCASTI32X4 CONST_GET_PTR(const_geotilees_extract_u16_bswap, 0), Z13
  VPSHUFB Z13, Z8, Z12
  VPSHUFB Z13, Z9, Z13

  VPLZCNTQ Z12, Z12
  VPLZCNTQ Z13, Z13

  VPCMPEQQ Z24, Z12, K3
  VPCMPEQQ Z24, Z13, K4

  VPLZCNTQ.Z Z10, K3, Z10
  VPLZCNTQ.Z Z11, K4, Z11

  VPANDNQ Z10, Z25, Z10
  VPANDNQ Z11, Z25, Z11
  VPANDNQ Z12, Z25, Z12
  VPANDNQ Z13, Z25, Z13

  VPSUBQ Z10, Z24, Z14
  VPSUBQ Z11, Z24, Z15
  VPSUBQ Z12, Z24, Z16
  VPSUBQ Z13, Z24, Z17

  VPSRLVQ Z14, Z26, Z10
  VPSRLVQ Z15, Z26, Z11
  VPSRLVQ Z16, Z26, Z12
  VPSRLVQ Z17, Z26, Z13

  VPADDQ Z14, Z16, Z14
  VPADDQ Z15, Z17, Z15
  VPSRLQ $3, Z14, Z14
  VPSRLQ $3, Z15, Z15
  VPADDQ.BCST CONSTQ_1(), Z14, Z22
  VPADDQ.BCST CONSTQ_1(), Z15, Z23

  VBROADCASTI32X4 CONST_GET_PTR(const_geotilees_extract_u16, 0), Z15
  VPSHUFB Z15, Z8, Z14
  VPSHUFB Z15, Z9, Z15

  VPSUBB Z10, Z4, Z4
  VPSUBB Z11, Z5, Z5
  VPSUBB Z12, Z14, Z12
  VPSUBB Z13, Z15, Z13

  VPBROADCASTB CONSTD_48(), Z27
  VPADDB Z27, Z4, Z4
  VPADDB Z27, Z5, Z5
  KMOVB K1, K3
  KMOVB K2, K4
  VPSCATTERQQ Z4, K3, -8(SI)(Z20*1)
  VPSCATTERQQ Z5, K4, -8(SI)(Z21*1)

  VPADDB Z27, Z12, Z12
  VPADDB Z27, Z13, Z13
  KMOVB K1, K3
  KMOVB K2, K4
  VPSCATTERQQ Z12, K3, -16(SI)(Z20*1)
  VPSCATTERQQ Z13, K4, -16(SI)(Z21*1)

  VPSUBQ Z22, Z20, Z20
  VPSUBQ Z23, Z21, Z21

  // Prepend "/X"
  // ------------

  VBROADCASTI32X4 CONST_GET_PTR(bswap64, 0), Z27
  VPSHUFB Z27, Z6, Z10
  VPSHUFB Z27, Z7, Z11
  VPORQ Z24, Z10, Z10
  VPORQ Z24, Z11, Z11

  VBROADCASTI32X4 CONST_GET_PTR(const_geotilees_extract_u16_bswap, 16), Z13
  VPSHUFB Z13, Z8, Z12
  VPSHUFB Z13, Z9, Z13

  VPLZCNTQ Z12, Z12
  VPLZCNTQ Z13, Z13

  VPCMPEQQ Z24, Z12, K3
  VPCMPEQQ Z24, Z13, K4

  VPLZCNTQ.Z Z10, K3, Z10
  VPLZCNTQ.Z Z11, K4, Z11

  VPANDNQ Z10, Z25, Z10
  VPANDNQ Z11, Z25, Z11
  VPANDNQ Z12, Z25, Z12
  VPANDNQ Z13, Z25, Z13

  VPSUBQ Z10, Z24, Z14
  VPSUBQ Z11, Z24, Z15
  VPSUBQ Z12, Z24, Z16
  VPSUBQ Z13, Z24, Z17

  VPSRLVQ Z14, Z26, Z10
  VPSRLVQ Z15, Z26, Z11
  VPSRLVQ Z16, Z26, Z12
  VPSRLVQ Z17, Z26, Z13

  VPADDQ Z14, Z16, Z14
  VPADDQ Z15, Z17, Z15
  VPSRLQ $3, Z14, Z14
  VPSRLQ $3, Z15, Z15
  VPADDQ.BCST CONSTQ_1(), Z14, Z22
  VPADDQ.BCST CONSTQ_1(), Z15, Z23

  VBROADCASTI32X4 CONST_GET_PTR(const_geotilees_extract_u16, 16), Z15
  VPSHUFB Z15, Z8, Z14
  VPSHUFB Z15, Z9, Z15

  VPSUBB Z10, Z6, Z6
  VPSUBB Z11, Z7, Z7
  VPSUBB Z12, Z14, Z12
  VPSUBB Z13, Z15, Z13

  VPBROADCASTB CONSTD_48(), Z27
  VPADDB Z27, Z6, Z6
  VPADDB Z27, Z7, Z7
  KMOVB K1, K3
  KMOVB K2, K4
  VPSCATTERQQ Z6, K3, -8(SI)(Z20*1)
  VPSCATTERQQ Z7, K4, -8(SI)(Z21*1)

  VPADDB Z27, Z12, Z12
  VPADDB Z27, Z13, Z13
  KMOVB K1, K3
  KMOVB K2, K4
  VPSCATTERQQ Z12, K3, -16(SI)(Z20*1)
  VPSCATTERQQ Z13, K4, -16(SI)(Z21*1)

  VPSUBQ Z22, Z20, Z20
  VPSUBQ Z23, Z21, Z21

  // Prepend "/Z"
  // ------------

  VBROADCASTI32X4 CONST_GET_PTR(const_geotilees_extract_u16_bswap, 32), Z13
  VPSHUFB Z13, Z8, Z12
  VPSHUFB Z13, Z9, Z13
  VPORQ Z24, Z12, Z12
  VPORQ Z24, Z13, Z13

  VPLZCNTQ Z12, Z12
  VPLZCNTQ Z13, Z13

  VPANDNQ Z12, Z25, Z12
  VPANDNQ Z13, Z25, Z13

  VPSUBQ Z12, Z24, Z16
  VPSUBQ Z13, Z24, Z17

  VPSRLVQ Z16, Z26, Z12
  VPSRLVQ Z17, Z26, Z13

  VPSRLQ $3, Z16, Z22
  VPSRLQ $3, Z17, Z23

  VPSLLQ $16, Z8, Z12
  VPSLLQ $16, Z9, Z13

  VPBROADCASTB CONSTD_48(), Z27
  VPADDB Z27, Z12, Z12
  VPADDB Z27, Z13, Z13
  KMOVB K1, K3
  KMOVB K2, K4
  VPSCATTERQQ Z12, K3, -8(SI)(Z20*1)
  VPSCATTERQQ Z13, K4, -8(SI)(Z21*1)

  VPSUBQ Z22, Z20, Z20
  VPSUBQ Z23, Z21, Z21

  // Finalize
  // --------

  // This calculates the length of each output string based on the current indexes
  // in Z20/Z21 by subtracting them from the initial state (the end of each string).
  VPMOVQD Z20, Y20
  VPMOVQD Z21, Y21
  VINSERTI32X8 $1, Y21, Z20, Z20
  VPBROADCASTD R15, K1, Z3

  VMOVDQA32.Z Z20, K1, Z2
  VPADDD CONST_GET_PTR(consts_offsets_d_32, 4), Z3, K1, Z3
  VPSUBD Z2, Z3, K1, Z3

  NEXT_ADVANCE(4)

abort:
  MOVL $const_bcerrMoreScratch, bytecode_err(VIRT_BCPTR)
  RET_ABORT()


TEXT bcgeodistance(SB), NOSPLIT|NOFRAME, $0
  KSHIFTRW $8, K1, K2

  // Z4/Z5 <- Lon2 - Lon1
  MOVWQZX 4(VIRT_PCREG), R8
  MOVWQZX 0(VIRT_PCREG), R15

  VMOVUPD 0(VIRT_VALUES)(R8*1), Z4
  VMOVUPD 64(VIRT_VALUES)(R8*1), Z5
  VSUBPD 0(VIRT_VALUES)(R15*1), Z4, Z4
  VSUBPD 64(VIRT_VALUES)(R15*1), Z5, Z5

  // Z6/Z7 <- Lat2
  MOVWQZX 2(VIRT_PCREG), R8
  VBROADCASTSD CONSTF64_PI_DIV_180(), Z10
  VBROADCASTSD CONSTF64_HALF(), Z11

  VMOVUPD 0(VIRT_VALUES)(R8*1), Z6
  VMOVUPD 64(VIRT_VALUES)(R8*1), Z7

  // Z4/Z5 <- RADIANS(Lon2 - Lon1)
  VMULPD Z10, Z4, Z4
  VMULPD Z10, Z5, Z5

  // Z2/Z3 <- RADIANS(Lat1)
  VMULPD Z10, Z2, K1, Z2
  VMULPD Z10, Z3, K2, Z3

  // Z6/Z7 <- RADIANS(Lat2)
  VMULPD Z10, Z6, Z6
  VMULPD Z10, Z7, Z7

  // Z8/Z9 <- RADIANS(Lat2 - Lat1)
  VSUBPD Z2, Z6, Z8
  VSUBPD Z3, Z7, Z9

  // Z4/Z5 <- SIN(RADIANS(Lon2 - Lon1) / 2)
  // Z10/Z11 <- SIN(RADIANS(Lat2 - Lat1) / 2)
  VMULPD Z11, Z4, Z4
  VMULPD Z11, Z5, Z5
  VMULPD Z11, Z8, Z8
  VMULPD Z11, Z9, Z9
  BC_FAST_SIN_4ULP(OUT(Z4), OUT(Z5), IN(Z4), IN(Z5))
  BC_FAST_SIN_4ULP(OUT(Z10), OUT(Z11), IN(Z8), IN(Z9))

  // Z8/Z9 <- COS(RADIANS(Lat1))
  // Z6/Z7 <- COS(RADIANS(Lat2))
  BC_FAST_COS_4ULP(OUT(Z8), OUT(Z9), IN(Z2), IN(Z3))
  BC_FAST_COS_4ULP(OUT(Z6), OUT(Z7), IN(Z6), IN(Z7))

  // Z6/Z7 <- COS(RADIANS(Lat1)) * COS(RADIANS(Lat2))
  VMULPD Z8, Z6, Z6
  VMULPD Z9, Z7, Z7

  // Z4/Z5 <- SIN^2(RADIANS(Lon2 - Lon1) / 2)
  VMULPD Z4, Z4, Z4
  VMULPD Z5, Z5, Z5

  // Z4/Z5 <- COS(RADIANS(Lat1)) * COS(RADIANS(Lat2)) * SIN^2(RADIANS(Lon2 - Lon1) / 2)
  VMULPD Z6, Z4, Z4
  VMULPD Z7, Z5, Z5

  // Z4/Z5 <- Q == SIN^2(RADIANS(Lat2 - Lat1) / 2) + COS(RADIANS(Lat1)) * COS(RADIANS(Lat2)) * SIN^2(RADIANS(Lon2 - Lon1) / 2)
  VBROADCASTSD CONSTF64_1(), Z7
  VFMADD231PD Z10, Z10, Z4 // Z4 = (Z10 * Z10) + Z4
  VFMADD231PD Z11, Z11, Z5 // Z5 = (Z11 * Z11) + Z5

  // Z4/Z5 <- ASIN(SQRT(Q))
  VSQRTPD Z4, Z8
  VSQRTPD Z5, Z9
  BC_FAST_ASIN_4ULP(OUT(Z4), OUT(Z5), IN(Z8), IN(Z9))

  VBROADCASTSD CONSTF64_12742000(), Z10
  VMULPD Z10, Z4, K1, Z2
  VMULPD Z10, Z5, K2, Z3

  NEXT_ADVANCE(6)


// String Concatenation
// --------------------

#define BC_CONCAT_ACC_INIT()          \
  VEXTRACTI32X8 $1, Z3, Y4            \
  VPMOVZXDQ Y3, K1, Z2                \
  VPMOVZXDQ Y4, K2, Z3

#define BC_CONCAT_ACC_STEP(StackRef)  \
  MOVWQZX (StackRef)(VIRT_PCREG), R8  \
  VPMOVZXDQ 64(VIRT_VALUES)(R8*1), Z4 \
  VPMOVZXDQ 96(VIRT_VALUES)(R8*1), Z5 \
  VPADDQ Z4, Z2, K1, Z2               \
  VPADDQ Z5, Z3, K2, Z3

// Initializes string length for concatenation in Z2/Z3
TEXT bcconcatlenget1(SB), NOSPLIT|NOFRAME, $0
  KSHIFTRW $8, K1, K2
  BC_CONCAT_ACC_INIT()
  NEXT_ADVANCE(0)

TEXT bcconcatlenget2(SB), NOSPLIT|NOFRAME, $0
  KSHIFTRW $8, K1, K2
  BC_CONCAT_ACC_INIT()
  BC_CONCAT_ACC_STEP(0)
  NEXT_ADVANCE(2)

TEXT bcconcatlenget3(SB), NOSPLIT|NOFRAME, $0
  KSHIFTRW $8, K1, K2
  BC_CONCAT_ACC_INIT()
  BC_CONCAT_ACC_STEP(0)
  BC_CONCAT_ACC_STEP(2)
  NEXT_ADVANCE(4)

TEXT bcconcatlenget4(SB), NOSPLIT|NOFRAME, $0
  KSHIFTRW $8, K1, K2
  BC_CONCAT_ACC_INIT()
  BC_CONCAT_ACC_STEP(0)
  BC_CONCAT_ACC_STEP(2)
  BC_CONCAT_ACC_STEP(4)
  NEXT_ADVANCE(6)

// Accumulates string length as INT64 in Z2/Z3
TEXT bcconcatlenacc1(SB), NOSPLIT|NOFRAME, $0
  KSHIFTRW $8, K1, K2
  BC_CONCAT_ACC_STEP(0)
  NEXT_ADVANCE(2)

TEXT bcconcatlenacc2(SB), NOSPLIT|NOFRAME, $0
  KSHIFTRW $8, K1, K2
  BC_CONCAT_ACC_STEP(0)
  BC_CONCAT_ACC_STEP(2)
  NEXT_ADVANCE(4)

TEXT bcconcatlenacc3(SB), NOSPLIT|NOFRAME, $0
  KSHIFTRW $8, K1, K2
  BC_CONCAT_ACC_STEP(0)
  BC_CONCAT_ACC_STEP(2)
  BC_CONCAT_ACC_STEP(4)
  NEXT_ADVANCE(6)

TEXT bcconcatlenacc4(SB), NOSPLIT|NOFRAME, $0
  KSHIFTRW $8, K1, K2
  BC_CONCAT_ACC_STEP(0)
  BC_CONCAT_ACC_STEP(2)
  BC_CONCAT_ACC_STEP(4)
  BC_CONCAT_ACC_STEP(6)
  NEXT_ADVANCE(8)

#undef BC_CONCAT_ACC_STEP
#undef BC_CONCAT_ACC_INIT

// Allocate string, which length is described by UINT64 elements in Z2/Z3
TEXT bcallocstr(SB), NOSPLIT|NOFRAME, $0
  // NOTE: We want unsigned saturation here as too large objects would end up with 0xFFFFFFFF length, which is UINT32_MAX.

  VPMOVUSQD Z2, Y4
  VPMOVUSQD Z3, Y5
  VINSERTI32X8 $1, Y5, Z4, Z4

  VPBROADCASTD CONSTD_134217727(), Z10                 // 134217727 == 2^31 / 16 - 1 <- horizonal addition threshold
  VPCMPD $VPCMP_IMM_LE, Z10, Z4, K1, K3                // Clear all lanes that would cause overflow during horizontal addition
  VMOVDQA32.Z Z4, K3, Z7                               // Z7 = [15    14    13    12   |11    10    09    08   |07    06    05    04   |03    02    01    00   ]

  // Horizontal addition:
  MOVL $0xFF00F0F0, R15
  KMOVD R15, K4
  VPSLLDQ $4, Z7, Z4                                   // Z4 = [14    13    12    __   |10    09    08    __   |06    05    04    __   |02    01    00    __   ]
  VPADDD Z7, Z4, Z4                                    // Z4 = [15+14 14+13 13+12 12   |11+10 10+09 09+08 08   |07+06 06+05 05+04 04   |03+02 02+01 01+00 00   ]
  VPSLLDQ $8, Z4, Z5                                   // Z5 = [13+12 12    __    __   |09+08 08    __    __   |05+04 04    __    __   |01+00 00    __    __   ]
  VPADDD Z5, Z4, Z4                                    // Z4 = [15:12 14:12 13:12 12   |11:08 10:08 09:08 08   |07:04 06:04 05:04 04   |03:00 02:00 01:00 00   ]

  VPSHUFD $SHUFFLE_IMM_4x2b(3, 3, 3, 3), Z4, Z5        // Z5 = [15:12 15:12 15:12 15:12|11:08 11:08 11:08 11:08|07:04 07:04 07:04 07:04|03:00 03:00 03:00 03:00]
  VPERMQ $SHUFFLE_IMM_4x2b(1, 1, 1, 1), Z5, Z5         // Z5 = [11:08 11:08 11:08 11:08|<ign> <ign> <ign> <ign>|03:00 03:00 03:00 03:00|<ign> <ign> <ign> <ign>]
  VPADDD Z5, Z4, K4, Z4                                // Z4 = [15:08 14:08 13:08 12:08|11:08 10:08 09:08 08   |07:00 06:00 05:00 04:00|03:00 02:00 01:00 00   ]
  KSHIFTRD $16, K4, K4
  VPSHUFD $SHUFFLE_IMM_4x2b(3, 3, 3, 3), Z4, Z5        // Z5 = [15:08 15:08 15:08 15:08|11:08 11:08 11:08 11:08|07:00 07:00 07:00 07:00|03:00 03:00 03:00 03:00]
  VSHUFI64X2 $SHUFFLE_IMM_4x2b(1, 1, 1, 1), Z5, Z5, Z5 // Z5 = [07:00 07:00 07:00 07:00|07:00 07:00 07:00 07:00|<ign> <ign> <ign> <ign>|<ign> <ign> <ign> <ign>]
  VPADDD Z5, Z4, K4, Z4                                // Z4 = [15:00 14:00 13:00 12:00|11:00 10:00 09:00 08:00|07:00 06:00 05:00 04:00|03:00 02:00 01:00 00   ]

  VEXTRACTI32X4 $3, Z4, X10
  VPSUBD Z7, Z4, Z5                                    // Z5 = [14:00 13:00 12:00 11:00|10:00 09:00 08:00 07:00|06:00 05:00 04:00 03:00|02:00 01:00 00    zero ]
  VPEXTRD $3, X10, R15                                 // R15 = Aggregated length of all objects to be allocated

  // What we have:
  //   Z4 <- Horizontally added lengths - it essentially contains the end of each object
  //   Z5 <- Start of each object in the output buffer relative to its current end (has to be further adjusted to get an absolute index)
  //   Z7 <- Length of each object to be allocated (describes input lengths with large objects already masked out)
  //   R15 <- Sum of all lengths, so we can allocate

  // Allocate the string
  MOVQ bytecode_scratch+8(VIRT_BCPTR), CX              // CX = Output buffer length
  MOVQ bytecode_scratch+16(VIRT_BCPTR), R8             // R8 = Output buffer capacity
  SUBQ CX, R8                                          // R8 = Remaining space in the output buffer
  CMPQ R8, R15
  JLT abort                                            // Abort if the output buffer is too small

  VPBROADCASTD CX, Z2
  VPADDD.BCST bytecode_scratchoff(VIRT_BCPTR), Z2, Z2
  VPADDD.Z Z5, Z2, K3, Z2                              // Beginning of each allocated object, zero index of non-allocated

  ADDQ CX, R15
  MOVQ R15, bytecode_scratch+8(VIRT_BCPTR)             // Update the length of our scratch buffer
  VPXORD X3, X3, X3                                    // Length of each allocated object, initially zero

  KMOVW K3, K1                                         // Update K1 predicate, masking out objects that were too large and thus couldn't be allocated
  NEXT()

abort:
  MOVL $const_bcerrMoreScratch, bytecode_err(VIRT_BCPTR)
  RET_ABORT()


TEXT bcappendstr(SB), NOSPLIT|NOFRAME, $0
  KMOVW K1, BX
  MOVWQZX (0)(VIRT_PCREG), R8

  TESTL BX, BX                                         // Bail if there are no strings to append
  JZ next

  LEAQ 0(VIRT_VALUES)(R8*1), R8                        // Make R8 absolute so we can use it with index later
  VMOVDQU32.Z 64(R8), K1, Z5                           // Length of each string to be appended

  VPADDD Z2, Z3, Z6                                    // End index of each output string
  VMOVDQU32 Z6, bytecode_spillArea(VIRT_BCPTR)         // Save the end index of each output string
  VPADDD Z5, Z3, K1, Z3                                // Update the length of each output string

iter:                                                  // Iterate over the mask and append each string where it's 1
  TZCNTL BX, DX                                        // DX - Index of the lane to process
  BLSRL BX, BX                                         // Clear the index of the iterator

  MOVL 0(R8)(DX * 4), R14                              // Input index
  MOVL 64(R8)(DX * 4), CX                              // Input length
  MOVL bytecode_spillArea(VIRT_BCPTR)(DX * 4), R15     // Output index

  ADDQ SI, R14                                         // Make input address from input index
  ADDQ SI, R15                                         // Make output address from output index

  SUBL $64, CX
  JCS copy_tail

  // Main copy loop that processes 64 bytes at once
copy_iter:
  VMOVDQU8 0(R14), Z7
  ADDQ $64, R14
  VMOVDQU8 Z7, 0(R15)
  ADDQ $64, R15

  SUBL $64, CX
  JCC copy_iter

copy_tail:
  // NOTE: The following line makes sense, but it's not needed. In C it would
  // be undefined behavior to shift with anything outside of [0, 63], but we
  // know that X86 only uses 6 bits in our case (64-bit shift), which would
  // not be changed by adding 64 as it has those 6 bits zero.
  // ADDL $64, CX

  MOVQ $-1, DX
  SHLQ CL, DX
  NOTQ DX
  KMOVQ DX, K2

  VMOVDQU8.Z 0(R14), K2, Z7
  VMOVDQU8 Z7, K2, 0(R15)

  TESTL BX, BX
  JNE iter

next:
  NEXT_ADVANCE(2)


// Find Symbol Instructions
// ------------------------

// findsym within Z0:Z1 starting at Z0
TEXT bcfindsym(SB), NOSPLIT|NOFRAME, $0
  VPBROADCASTD 0(VIRT_PCREG), Z22
  ADDQ         $4, VIRT_PCREG
  VMOVDQA32    Z0, Z30             // Z30 = offset
  VPADDD       Z1, Z0, Z26         // Z26 = end of struct
  JMP          findsym_tail(SB)

// findsym within Z0:Z1 starting at Z30
// or Z30+Z31 depending on the saved mask
// argument
TEXT bcfindsym2(SB), NOSPLIT|NOFRAME, $0
  MOVWQZX      0(VIRT_PCREG), R8
  MOVL         2(VIRT_PCREG), DX
  ADDQ         $6, VIRT_PCREG
  LEAQ         0(VIRT_VALUES)(R8*1), R8
  KMOVW        0(R8), K2
  VPBROADCASTD DX, Z22
  VPADDD       Z30, Z31, K2, Z30
  VPADDD       Z0, Z1, Z26
  JMP          findsym_tail(SB)

// identical to above with reversed
// mask argument ordering
// (addend predicate in K1, active mask in stack slot)
TEXT bcfindsym2rev(SB), NOSPLIT|NOFRAME, $0
  MOVWQZX      0(VIRT_PCREG), R8
  MOVL         2(VIRT_PCREG), DX
  ADDQ         $6, VIRT_PCREG
  LEAQ         0(VIRT_VALUES)(R8*1), R8
  VPBROADCASTD DX, Z22
  VPADDD       Z30, Z31, K1, Z30
  VPADDD       Z0, Z1, Z26
  KMOVW        0(R8), K1
  JMP          findsym_tail(SB)

// same as above, but the K1 argument
// is used for both the lane mask and
// the addend argument
TEXT bcfindsym3(SB), NOSPLIT|NOFRAME, $0
  VPBROADCASTD 0(VIRT_PCREG), Z22
  ADDQ         $4, VIRT_PCREG
  VPADDD       Z30, Z31, K1, Z30
  VPADDD       Z0, Z1, Z26
  JMP          findsym_tail(SB)

// inputs:
//   K1 = active lanes
//   Z30 = starting offset (dword)
//   Z26 = end of row (dword)
//   Z22 = symbol ID to match (dword)
//
// outputs:
//   K1 = lanes matched
//   Z30 = offset (location of symbol >= search)
//   Z31 = length (when K1 is set; undef otherwise)
//
TEXT findsym_tail(SB), NOSPLIT|NOFRAME, $0
  VPXORD       Z31, Z31, Z31         // Z31 = length
  KMOVW        K1, K5                // K5 = active
  KXORW        K0, K0, K1            // K1 = found
  VPBROADCASTD CONSTD_1(), Z21       // Z21 = 1
  VPBROADCASTD CONSTD_0x7F(), Z24    // Z24 = 0x7f
  VPBROADCASTD CONSTD_0x80(), Z25    // Z25 = 0x80
  JMP          looptail
loop:
  // load 4 bytes and process the leading uvarint
  XORL         DX, DX                // indicates jump to uvarintdone
  KMOVW        K5, K2
  VPGATHERDD   (SI)(Z30*1), K2, Z29  // Z29 = first 4 bytes
  VMOVDQA32.Z  Z21, K5, Z23          // Z23 = uvarint size = 1 (for now)
  VPANDD       Z24, Z29, Z28         // Z28 = accumulator = byte & 0x7f
  VPTESTNMD    Z25, Z29, K5, K4      // K4 = varint bit set
  KANDNW       K5, K4, K2
  VPSRLD       $8, Z29, K2, Z29      // shift to get descriptor byte as lsb
  KTESTW       K4, K4
  KMOVW        K4, K3
  JNZ          uvarint_parse2        // slow path for symbol > 0x7f
uvarintdone:
  VPCMPD        $VPCMP_IMM_GE, Z28, Z22, K5, K5  // only keep lanes active where search >= symbol
  VPCMPEQD      Z28, Z22, K5, K2           // K2 = active & symbol matches
  KORW          K2, K1, K1                 // set result in K1
  VPADDD        Z23, Z30, K5, Z30          // update offset *when search >= symbol!*
  VPANDD.BCST   CONSTD_0xFF(), Z29, Z29    // make sure Z29 is just the lsb
  VPANDD.BCST   CONSTD_0x0F(), Z29, Z28    // Z28 = data&0xf
  VPCMPEQD.BCST CONSTD_0x0E(), Z28, K5, K6 // K6 = Z28==0xe (varint-encoded item)
  KANDNW        K5, K6, K4                 // K4 = active non-varint items
  VPCMPEQD.BCST CONSTD_0x0F(), Z28, K4, K3 // K3 = Z28==0xf (null item)
  VMOVDQA32     Z21, K3, Z31               // length = 1 if null
  KANDNW        K4, K3, K4                 // K4 = immediate but not null
  VPCMPEQD.BCST CONSTD_TRUE_BYTE(), Z29, K4, K3 // K3 = value is 'true'
  VPXORD        Z28, Z28, K3, Z28          // length = 0 for 0x11 ('true')
  VPADDD        Z21, Z28, K4, Z31          // ... in which case length = 1 + immediate
  KTESTW        K6, K6
  JZ            fieldlendone               // fast-path when everything is short

  // parse object size when uvarint-encoded
  INCL         DX                    // DX != 0 indicates jump to fieldlendone
  KMOVW        K6, K4
  VPGATHERDD   1(SI)(Z30*1), K4, Z29 // load next 4 bytes into Z29
  VPADDD       Z21, Z21, Z23         // Z23 = varint size + descriptor = 2 (currently)
  VPANDD.Z     Z24, Z29, K6, Z28     // Z28 = bytes&0x7f or 0 when not varint
  VPTESTNMD    Z25, Z29, K6, K4      // test bytes&0x80
  KTESTW       K4, K4
  JNZ          uvarint_parse3        // common case is 1-byte field length
fieldlendone:
  VPADDD       Z23, Z28, K6, Z31     // for varints: length = varint size + encoding size
  KANDNW       K5, K2, K5            // unset active lanes when symbol matched
  VPADDD       Z30, Z31, K5, Z30     // offset += length when not matched
looptail:
  VPCMPUD      $5, Z26, Z30, K5, K4
  KANDNW       K5, K4, K5            // unset active lanes when at end
  KTESTW       K5, K5                // early exit if we've consumed everything
  JNZ          loop
done:
  NEXT()
// un-rolled uvarint parsing
#define CHOMP()                  \
  VPADDD       Z21, Z23, K4, Z23 \
  VPSLLD       $7, Z28, K4, Z28  \
  VPSRLD       $8, Z29, K4, Z29  \
  VPANDD       Z24, Z29, Z27     \
  VPORD        Z27, Z28, K4, Z28 \
  VPTESTNMD    Z25, Z29, K4, K4
uvarint_parse3:
  CHOMP()
uvarint_parse2:
  CHOMP()
  CHOMP()
  KTESTW       K4, K4
  JNZ          trap                 // assert symbol < max symbol ID
  // since the Go assembler won't let you
  // compute the address of a label (AAAAAHHHH WHY)
  // we use DX to indicate the return branch target
  TESTL        DX, DX
  JNZ          fieldlendone
  // uvarintdone expects that we have
  // shifted zmm29 so that the first byte
  // is the beginning of the next object
  VPSRLD       $8, Z29, K3, Z29
  JMP          uvarintdone
trap:
  FAIL()

#undef CHOMP

// Blend Instructions
// ------------------

// blend in saved values using K1
// on 32x 32-bit lanes across two registers
#define BLEND32(r0, r1)                    \
  MOVWQZX     0(VIRT_PCREG), R8            \
  ADDQ        $2, VIRT_PCREG               \
  VMOVDQU32   0(VIRT_VALUES)(R8*1), K1, r0 \
  VMOVDQU32   64(VIRT_VALUES)(R8*1), K1, r1

// like BLEND32(), but with the
// register/stack ordering reversed
#define BLEND32REV(r0, r1)                 \
  MOVWQZX     0(VIRT_PCREG), R8            \
  ADDQ        $2, VIRT_PCREG               \
  KXORW       K1, K7, K2                   \
  VMOVDQU32   0(VIRT_VALUES)(R8*1), K2, r0 \
  VMOVDQU32   64(VIRT_VALUES)(R8*1), K2, r1

// blend in saved values using K1
// on 16x 64-bit lanes across two registers
#define BLEND64(r0, r1)                    \
  MOVWQZX     0(VIRT_PCREG), R8            \
  ADDQ        $2, VIRT_PCREG               \
  KSHIFTRW    $8, K1, K2                   \
  VMOVDQU64   0(VIRT_VALUES)(R8*1), K1, r0 \
  VMOVDQU64   64(VIRT_VALUES)(R8*1), K2, r1

// blend in saved values using K1
// on 16x 64-bit lanes across two registers
#define BLEND64REV(r0, r1)                 \
  MOVWQZX     0(VIRT_PCREG), R8            \
  ADDQ        $2, VIRT_PCREG               \
  KXORW       K1, K7, K2                   \
  KSHIFTRW    $8, K2, K3                   \
  VMOVDQU64   0(VIRT_VALUES)(R8*1), K2, r0 \
  VMOVDQU64   64(VIRT_VALUES)(R8*1), K3, r1

// NOTE: PLEASE DO NOT RE-ORDER THE BLEND INSTRUCTIONS;
// the SSA code relies on the reversed-argument version
// of each blend instruction being the regular version
// opcode plus one

// blend stack slot into Z30+Z31 (value pointers)
TEXT bcblendv(SB), NOSPLIT|NOFRAME, $0
  BLEND32(Z30, Z31)
  NEXT()

// blend Z30+Z31 into stack slot value;
// return union of values
TEXT bcblendrevv(SB), NOSPLIT|NOFRAME, $0
  BLEND32REV(Z30, Z31)
  NEXT()

// blend Z2+Z3, assuming packed 64-bit integers or doubles
TEXT bcblendnum(SB), NOSPLIT|NOFRAME, $0
  BLEND64(Z2, Z3)
  NEXT()

// blend Z2+Z3, 64-bit layout, reversed
TEXT bcblendnumrev(SB), NOSPLIT|NOFRAME, $0
  BLEND64REV(Z2, Z3)
  NEXT()

// blend Z2+Z3, assuming slices (strings or timestamps)
TEXT bcblendslice(SB), NOSPLIT|NOFRAME, $0
  BLEND32(Z2, Z3)
  NEXT()

// blend Z2+Z3, assuming slices, reversed
TEXT bcblendslicerev(SB), NOSPLIT|NOFRAME, $0
  BLEND32REV(Z2, Z3)
  NEXT()

// Unboxing Instructions
// ---------------------

// unpack string/array/timestamp to scalar slice
TEXT bcunpack(SB), NOSPLIT|NOFRAME, $0
  MOVBLZX       0(VIRT_PCREG), R8
  KTESTW        K1, K1
  JZ            next
  VPBROADCASTD  R8, Z23                    // Z23 = descriptor tag
  KMOVW         K1, K2
  VPBROADCASTD  CONSTD_0x0F(), Z27         // Z27 = 0x0F
  VPGATHERDD    0(SI)(Z30*1), K2, Z26      // Z26 = first 4 bytes
  VPANDD        Z26, Z27, Z25              // Z25 = first 4 & 0x0f = int size
  VPCMPEQD      Z25, Z27, K1, K2           // K2 = field is null
  KANDNW        K1, K2, K1                 // unset str.null lanes
  VPSRLD        $4, Z26, Z26               // first 4 words >>= 4
  VPANDD        Z27, Z26, Z24              // Z24 = (word >> 4) & 0xf = descriptor tag
  VPCMPEQD      Z23, Z24, K1, K1           // match only descriptor tag
  KTESTW        K1, K1
  JZ            next
  VPCMPEQD.BCST CONSTD_0x0E(), Z25, K1, K2 // K2 = descriptor=e (varint-sized)
  KANDNW        K1, K2, K3                 // K3 = non-varint-sized strings
  VPADDD.BCST.Z CONSTD_1(), Z30, K1, Z2    // Z2 = base = offset+1 (will update later for varints)
  VMOVDQA32     Z25, K3, Z3                // Z3 = length = first4&0xf for non-varint-size
  KTESTW        K2, K2
  JZ            next                       // short-circuit if no varint-length objects
  // decode up to 3 varint bytes; we expect
  // not to see 4 bytes because our current chunk
  // alignment would not allow for objects over
  // 2^21 bytes long anyway...
  // TODO: if we need to support longer objects,
  // the end of this unrolled loop can do another
  // gatherdd and jump back up to the top here...
  VPBROADCASTD  CONSTD_1(), Z24         // Z24 = 0x01
  VPBROADCASTD  CONSTD_0x7F(), Z27      // Z27 = 0x7F
  VPBROADCASTD  CONSTD_0x80(), Z29      // Z29 = 0x80
  VPSRLD        $4, Z26, Z26            // now Z26 = 3 bytes following descriptor
  KMOVW         K2, K3
  VPANDD.Z      Z27, Z26, K3, Z28       // Z28 = byte1&0x7f = accumulator
  VPADDD        Z24, Z2, K3, Z2         // base+1
  VPTESTNMD     Z29, Z26, K3, K3        // test byte1&0x80
  KTESTW        K3, K3
  JZ            done
  // decode 2nd varint byte
  VPSRLD        $8, Z26, K3, Z26        // word >>= 8
  VPSLLD        $7, Z28, K3, Z28        // accum <<= 7
  VPANDD        Z27, Z26, K3, Z25
  VPORD         Z25, Z28, K3, Z28       // accum |= (word & 0x7f)
  VPADDD        Z24, Z2, K3, Z2         // base+1
  VPTESTNMD     Z29, Z26, K3, K3        // test word&0x80
  // decode 3rd varint byte
  VPSRLD        $8, Z26, K3, Z26        // word >>= 8
  VPSLLD        $7, Z28, K3, Z28        // accum <<= 7
  VPANDD        Z27, Z26, K3, Z25
  VPORD         Z25, Z28, K3, Z28       // accum |= (word & 0x7f)
  VPADDD        Z24, Z2, K3, Z2         // base+1
  VPTESTNMD     Z29, Z26, K3, K3        // test word&0x80
  KTESTW        K3, K3
  JNZ           trap                    // trap if length(object) > 2^21
done:
  VMOVDQA32     Z28, K2, Z3             // set Z3 = length
next:
  NEXT_ADVANCE(1)
trap:
  FAIL()

// for Z30:Z31 that are symbols, replace with
// symtab[symbol] instead
TEXT bcunsymbolize(SB), NOSPLIT|NOFRAME, $0
  KTESTW K1, K1
  JZ     next
  VPBROADCASTD  CONSTD_0x0F(), Z10
  KMOVW         K1, K2
  VPGATHERDD    0(SI)(Z30*1), K2, Z28      // Z28 = first 4 bytes
  VPSRLD        $4, Z28, Z29
  VPANDD        Z10, Z29, Z29              // z29 = (bytes >> 4) & 0x0f = tag
  VPCMPEQD.BCST CONSTD_7(), Z29, K1, K2    // K2 = lanes that are symbols (tag == 7)
  KTESTW        K2, K2
  JZ            next                       // fast path: no symbols

  VPBROADCASTD  CONSTD_4(), Z24
  VPANDD        Z10, Z28, Z29                   // Z29 = bytes & 0x0f = size
  VPCMPD        $VPCMP_IMM_LT, Z24, Z29, K2, K2 // only choose lanes where size < 4
  VPSUBD.Z      Z29, Z24, K2, Z29               // Z29 = (4 - size)
  VPSLLD        $3, Z29, Z29                    // Z29 = (4 - size)<<3 = shift count
  VPSRLD        $8, Z28, Z28                    // Z28 = uint value plus garbage
  VBROADCASTI32X4 bswap32<>+0(SB), Z24
  VPSHUFB         Z24, Z28, Z28         // Z28 = bswap32(repr)
  VPSRLVD         Z29, Z28, Z28         // Z28 = bswap32(repr)>>(4-size) = symbol ID
  // only keep lanes where id < len(symtab)
  VPCMPD.BCST     $VPCMP_IMM_LT, bytecode_symtab+8(VIRT_BCPTR), Z28, K2, K2
  KMOVB           K2, K3
  MOVQ            bytecode_symtab+0(VIRT_BCPTR), R8
  TESTQ           R8, R8
  JZ              uhoh
  VPGATHERDQ      0(R8)(Y28*8), K3, Z22  // gather lo 8 vmrefs
  KSHIFTRW        $8, K2, K4
  VEXTRACTI32X8   $1, Z28, Y29
  VPGATHERDQ      0(R8)(Y29*8), K4, Z23  // gather hi 8 vmrefs
  VPMOVQD         Z22, Y20
  VPMOVQD         Z23, Y21
  VINSERTI32X8    $1, Y21, Z20, Z20      // Z20 = lo 32 bits of 16 vmrefs = offsets
  VMOVDQA32       Z20, K2, Z30           // set offsets where successful
  VPROLQ          $32, Z22, Z22          // flip lo/hi 32 bits of each element
  VPROLQ          $32, Z23, Z23
  VPMOVQD         Z22, Y20
  VPMOVQD         Z23, Y21
  VINSERTI32X8    $1, Y21, Z20, Z20      // Z20 = hi 32 bits of 16 vmrefs = lengths
  VMOVDQA32       Z20, K2, Z31           // set lengths where successful
next:
  NEXT()
uhoh:
  BYTE $0xCC
  JMP  next

// unbox BOOL values in (Z30:Z31).K1 into Z2/Z3 and K1
//
// NOTE: This opcode was designed in a way to be followed by cvti64tok,
// because we don't have a way to describe multiple returns in our SSA.
TEXT bcunboxktoi64(SB), NOSPLIT|NOFRAME, $0
  VPXORQ X4, X4, X4
  KMOVW K1, K2
  VPGATHERDD 0(SI)(Z30*1), K2, Z4                     // Z4 <- first 4 bytes of each encoded value
  VPANDD.BCST CONSTD_0xFF(), Z4, Z4                   // Z4 <- first byte of each encoded value

  VPCMPEQD.BCST CONSTD_TRUE_BYTE(), Z4, K1, K2        // K2 <- set to ONEs for TRUE values
  VPCMPEQD.BCST CONSTD_FALSE_BYTE(), Z4, K1, K1       // K1 <- set to ONEs for FALSE values
  VPBROADCASTQ CONSTQ_1(), Z4

  KSHIFTRW $8, K2, K3
  KORW K2, K1, K1                                     // K1 <- active lanes written

  VMOVDQA64.Z Z4, K2, Z2                              // Z2 <- bools converted to i64 (low)
  VMOVDQA64.Z Z4, K3, Z3                              // Z3 <- bools converted to i64 (high)

  NEXT()

// unboxcoerce instructions unbox a numeric value and coerce it to either f64 or i64
TEXT bcunboxcoercef64(SB), NOSPLIT|NOFRAME, $0
  MOVWQZX 0(VIRT_PCREG), R8
  KMOVW K1, K2
  VPXORQ X4, X4, X4
  VPGATHERDD 0(SI)(Z30*1), K2, Z4                     // Z4 <- read first 4 bytes (Type|L)

  VPBROADCASTD CONSTD_1(), Z10                        // Z10 <- constant(1)
  VPBROADCASTD CONSTD_0x0F(), Z6                      // Z6 <- constant(0xF)
  VPSLLD $1, Z10, Z11                                 // Z11 <- constant(2)

  VPSRLD $4, Z4, Z5                                   // Z5 <- Z4 >> 4
  VPSLLD $3, Z10, Z12                                 // Z12 <- constant(8)

  VPANDD Z6, Z5, Z5                                   // Z5 <- ION type
  VPANDD Z6, Z4, Z6                                   // Z6 <- L field
  VPSUBD Z11, Z5, Z4                                  // Z4 <- ION type - 2 (this saves us some instructions / constants)

  VPCMPUD $VPCMP_IMM_LE, Z11, Z4, K1, K1              // K1 <- mask of all lanes that contain either 0x2, 0x3, or 0x4 ION type
  VPXORQ X2, X2, X2                                   // Z2 <- zero all lanes in case there are no numbers (low)
  VPXORQ X3, X3, X3                                   // Z3 <- zero all lanes in case there are no numbers (high)

  KTESTW K1, K1
  JZ next                                             // Skip unboxing if there are no numbers

  VEXTRACTI32X8 $1, Z30, Y13
  KMOVB K1, K3
  VPGATHERDQ 1(SI)(Y30*1), K3, Z2                     // Z2 <- number data (low)
  VPSUBD Z6, Z12, Z12                                 // Z12 <- (8 - L)
  KSHIFTRW $8, K1, K4
  VPGATHERDQ 1(SI)(Y13*1), K4, Z3                     // Z3 <- number data (high)
  VPSLLD $3, Z12, Z12                                 // Z12 <- (8 - L) << 3

  VEXTRACTI32X8 $1, Z12, Y13
  VBROADCASTI32X4 CONST_GET_PTR(bswap64, 0), Z5
  VPMOVZXDQ Y12, Z12                                  // Z12 <- (8 - L) << 3 (low)
  VPMOVZXDQ Y13, Z13                                  // Z13 <- (8 - L) << 3 (high)

  VPSHUFB Z5, Z2, Z2                                  // Z2 <- byteswapped lanes (low)
  VPSHUFB Z5, Z3, Z3                                  // Z3 <- byteswapped lanes (high)

  VPCMPEQD Z10, Z4, K1, K3                            // K3 <- negative integers (low/all)
  VPSRLVQ Z12, Z2, Z2                                 // Z2 <- byteswapped lanes, shifted right by `(8 - L) << 3` (low)
  KSHIFTRW $8, K3, K4                                 // K4 <- negative integers (high)
  VPSRLVQ Z13, Z3, Z3                                 // Z3 <- byteswapped lanes, shifted right by `(8 - L) << 3` (high)

  VPXORQ X10, X10, X10
  VPSUBQ Z2, Z10, K3, Z2                              // Z2 <- negate integer if negative (low)
  VPCMPD $VPCMP_IMM_NE, Z11, Z4, K1, K3               // K3 <- integer values (low/all)
  VPSUBQ Z3, Z10, K4, Z3                              // Z3 <- negate integer if negative (high)
  KSHIFTRW $8, K3, K4                                 // K4 <- integer values (high)

  VCVTQQ2PD Z2, K3, Z2                                // Z2 <- final 64-bit floats (low)
  VCVTQQ2PD Z3, K4, Z3                                // Z3 <- final 64-bit floats (high)

next:
  NEXT()

TEXT bcunboxcoercei64(SB), NOSPLIT|NOFRAME, $0
  MOVWQZX 0(VIRT_PCREG), R8
  KMOVW K1, K2
  VPXORQ X4, X4, X4
  VPGATHERDD 0(SI)(Z30*1), K2, Z4                     // Z4 <- read first 4 bytes (Type|L)

  VPBROADCASTD CONSTD_1(), Z10                        // Z10 <- constant(1)
  VPBROADCASTD CONSTD_0x0F(), Z6                      // Z6 <- constant(0xF)
  VPSLLD $1, Z10, Z11                                 // Z11 <- constant(2)

  VPSRLD $4, Z4, Z5                                   // Z5 <- Z4 >> 4
  VPSLLD $3, Z10, Z12                                 // Z12 <- constant(8)

  VPANDD Z6, Z5, Z5                                   // Z5 <- ION type
  VPANDD Z6, Z4, Z6                                   // Z6 <- L field
  VPSUBD Z11, Z5, Z4                                  // Z4 <- ION type - 2 (this saves us some instructions / constants)

  VPCMPUD $VPCMP_IMM_LE, Z11, Z4, K1, K1              // K1 <- mask of all lanes that contain either 0x2, 0x3, or 0x4 ION type
  VPXORQ X2, X2, X2                                   // Z2 <- zero all lanes in case there are no numbers (low)
  VPXORQ X3, X3, X3                                   // Z3 <- zero all lanes in case there are no numbers (high)

  KTESTW K1, K1
  JZ next                                             // Skip unboxing if there are no numbers

  VEXTRACTI32X8 $1, Z30, Y13
  KMOVB K1, K3
  VPGATHERDQ 1(SI)(Y30*1), K3, Z2                     // Z2 <- number data (low)
  VPSUBD Z6, Z12, Z12                                 // Z12 <- (8 - L)
  KSHIFTRW $8, K1, K4
  VPGATHERDQ 1(SI)(Y13*1), K4, Z3                     // Z3 <- number data (high)
  VPSLLD $3, Z12, Z12                                 // Z12 <- (8 - L) << 3

  VEXTRACTI32X8 $1, Z12, Y13
  VBROADCASTI32X4 CONST_GET_PTR(bswap64, 0), Z5
  VPMOVZXDQ Y12, Z12                                  // Z12 <- (8 - L) << 3 (low)
  VPMOVZXDQ Y13, Z13                                  // Z13 <- (8 - L) << 3 (high)

  VPSHUFB Z5, Z2, Z2                                  // Z2 <- byteswapped lanes (low)
  VPSHUFB Z5, Z3, Z3                                  // Z3 <- byteswapped lanes (high)

  VPCMPEQD Z10, Z4, K1, K3                            // K3 <- negative integers (low/all)
  VPSRLVQ Z12, Z2, Z2                                 // Z2 <- byteswapped lanes, shifted right by `(8 - L) << 3` (low)
  KSHIFTRW $8, K3, K4                                 // K4 <- negative integers (high)
  VPSRLVQ Z13, Z3, Z3                                 // Z3 <- byteswapped lanes, shifted right by `(8 - L) << 3` (high)

  VPXORQ X10, X10, X10
  VPSUBQ Z2, Z10, K3, Z2                              // Z2 <- negate integer if negative (low)
  VPCMPEQD Z11, Z4, K1, K3                            // K3 <- floating points (low/all)
  VPSUBQ Z3, Z10, K4, Z3                              // Z3 <- negate integer if negative (high)
  KSHIFTRW $8, K3, K4                                 // K4 <- floating points (high)

  VCVTTPD2QQ Z2, K3, Z2                               // Z2 <- final 64-bit integers (low)
  VCVTTPD2QQ Z3, K4, Z3                               // Z3 <- final 64-bit integers (high)

next:
  NEXT()

// unboxcoerce instructions unbox a value that is castable to either f64 and i64
//
// A little trick is used to cast bool to i64/f64 - if a value type is bool, we assign
// 0x01 to its binary representation - then if the value is false all bytes are cleared
// (shifted out) as L field is zero; however, if L field is 1 (representing a true value)
// then 0x01 byte would remain, which would be then kept to coerce to i64 or converted to
// a floating point 1.0 representation.
TEXT bcunboxcvtf64(SB), NOSPLIT|NOFRAME, $0
  MOVWQZX 0(VIRT_PCREG), R8
  KMOVW K1, K2
  VPXORQ X4, X4, X4
  VPGATHERDD 0(SI)(Z30*1), K2, Z4                     // Z4 <- read first 4 bytes (Type|L)

  VPBROADCASTD CONSTD_1(), Z10                        // Z10 <- constant(1)
  VPBROADCASTD CONSTD_0x0F(), Z6                      // Z6 <- constant(0xF)
  VPSLLD $1, Z10, Z11                                 // Z11 <- constant(2)
  VPADDD Z10, Z11, Z14                                // Z14 <- constant(3)

  VPSRLD $4, Z4, Z5                                   // Z5 <- Z4 >> 4
  VPSLLD $3, Z10, Z12                                 // Z12 <- constant(8)

  VPANDD Z6, Z5, Z5                                   // Z5 <- ION type
  VPANDD Z6, Z4, Z6                                   // Z6 <- L field
  VPSUBD Z10, Z5, Z4                                  // Z4 <- ION type - 1 (this saves us some instructions / constants)

  VPCMPUD $VPCMP_IMM_LE, Z14, Z4, K1, K1              // K1 <- mask of all lanes that contain either 0x1, 0x2, 0x3, or 0x4 ION type
  VPXORQ X2, X2, X2                                   // Z2 <- zero all lanes in case there are no numbers (low)
  VPXORQ X3, X3, X3                                   // Z3 <- zero all lanes in case there are no numbers (high)

  KTESTW K1, K1
  JZ next                                             // Skip unboxing if there are no numbers

  VEXTRACTI32X8 $1, Z30, Y13
  KMOVB K1, K3
  VPGATHERDQ 1(SI)(Y30*1), K3, Z2                     // Z2 <- number data (low)
  VPSUBD Z6, Z12, Z12                                 // Z12 <- (8 - L)
  KSHIFTRW $8, K1, K4
  VPGATHERDQ 1(SI)(Y13*1), K4, Z3                     // Z3 <- number data (high)
  VPSLLD $3, Z12, Z12                                 // Z12 <- (8 - L) << 3

  VEXTRACTI32X8 $1, Z12, Y13
  VBROADCASTI32X4 CONST_GET_PTR(bswap64, 0), Z5
  VPXORQ X15, X15, X15                                // Z15 <- constant(0)
  VPMOVZXDQ Y12, Z12                                  // Z12 <- (8 - L) << 3 (low)
  VPMOVZXDQ Y13, Z13                                  // Z13 <- (8 - L) << 3 (high)

  VPCMPEQD Z15, Z4, K1, K3                            // K3 <- mask of bool values (low/all)
  KSHIFTRW $8, K3, K4                                 // K4 <- mask of bool values (high)

  VMOVDQA64 Z10, K3, Z2                               // Z2 <- value data fixed to have ones for bool values (low)
  VMOVDQA64 Z10, K4, Z3                               // Z3 <- value data fixed to have ones for bool values (high)

  VPSHUFB Z5, Z2, Z2                                  // Z2 <- byteswapped lanes (low)
  VPSHUFB Z5, Z3, Z3                                  // Z3 <- byteswapped lanes (high)

  VPCMPEQD Z11, Z4, K1, K3                            // K3 <- negative integers (low/all)
  VPSRLVQ Z12, Z2, Z2                                 // Z2 <- byteswapped lanes, shifted right by `(8 - L) << 3` (low)
  KSHIFTRW $8, K3, K4                                 // K4 <- negative integers (high)
  VPSRLVQ Z13, Z3, Z3                                 // Z3 <- byteswapped lanes, shifted right by `(8 - L) << 3` (high)

  VPSUBQ Z2, Z15, K3, Z2                              // Z2 <- negate integer if negative (low)
  VPCMPD $VPCMP_IMM_NE, Z14, Z4, K1, K3               // K3 <- integer values (low/all)
  VPSUBQ Z3, Z15, K4, Z3                              // Z3 <- negate integer if negative (high)
  KSHIFTRW $8, K3, K4                                 // K4 <- integer values (high)

  VCVTQQ2PD Z2, K3, Z2                                // Z2 <- final 64-bit floats (low)
  VCVTQQ2PD Z3, K4, Z3                                // Z3 <- final 64-bit floats (high)

next:
  NEXT()

TEXT bcunboxcvti64(SB), NOSPLIT|NOFRAME, $0
  MOVWQZX 0(VIRT_PCREG), R8
  KMOVW K1, K2
  VPXORQ X4, X4, X4
  VPGATHERDD 0(SI)(Z30*1), K2, Z4                     // Z4 <- read first 4 bytes (Type|L)

  VPBROADCASTD CONSTD_1(), Z10                        // Z10 <- constant(1)
  VPBROADCASTD CONSTD_0x0F(), Z6                      // Z6 <- constant(0xF)
  VPSLLD $1, Z10, Z11                                 // Z11 <- constant(2)
  VPADDD Z10, Z11, Z14                                // Z14 <- constant(3)

  VPSRLD $4, Z4, Z5                                   // Z5 <- Z4 >> 4
  VPSLLD $3, Z10, Z12                                 // Z12 <- constant(8)

  VPANDD Z6, Z5, Z5                                   // Z5 <- ION type
  VPANDD Z6, Z4, Z6                                   // Z6 <- L field
  VPSUBD Z10, Z5, Z4                                  // Z4 <- ION type - 1 (this saves us some instructions / constants)

  VPCMPUD $VPCMP_IMM_LE, Z14, Z4, K1, K1              // K1 <- mask of all lanes that contain either 0x2, 0x3, or 0x4 ION type
  VPXORQ X2, X2, X2                                   // Z2 <- zero all lanes in case there are no numbers (low)
  VPXORQ X3, X3, X3                                   // Z3 <- zero all lanes in case there are no numbers (high)

  KTESTW K1, K1
  JZ next                                             // Skip unboxing if there are no numbers

  VEXTRACTI32X8 $1, Z30, Y13
  KMOVB K1, K3
  VPGATHERDQ 1(SI)(Y30*1), K3, Z2                     // Z2 <- number data (low)
  VPSUBD Z6, Z12, Z12                                 // Z12 <- (8 - L)
  KSHIFTRW $8, K1, K4
  VPGATHERDQ 1(SI)(Y13*1), K4, Z3                     // Z3 <- number data (high)
  VPSLLD $3, Z12, Z12                                 // Z12 <- (8 - L) << 3

  VEXTRACTI32X8 $1, Z12, Y13
  VBROADCASTI32X4 CONST_GET_PTR(bswap64, 0), Z5
  VPXORQ X15, X15, X15                                // Z15 <- constant(0)
  VPMOVZXDQ Y12, Z12                                  // Z12 <- (8 - L) << 3 (low)
  VPMOVZXDQ Y13, Z13                                  // Z13 <- (8 - L) << 3 (high)

  VPCMPEQD Z15, Z4, K1, K3                            // K3 <- mask of bool values (low/all)
  KSHIFTRW $8, K3, K4                                 // K4 <- mask of bool values (high)

  VMOVDQA64 Z10, K3, Z2                               // Z2 <- value data fixed to have ones for bool values (low)
  VMOVDQA64 Z10, K4, Z3                               // Z3 <- value data fixed to have ones for bool values (high)

  VPSHUFB Z5, Z2, Z2                                  // Z2 <- byteswapped lanes (low)
  VPSHUFB Z5, Z3, Z3                                  // Z3 <- byteswapped lanes (high)

  VPCMPEQD Z11, Z4, K1, K3                            // K3 <- negative integers (low/all)
  VPSRLVQ Z12, Z2, Z2                                 // Z2 <- byteswapped lanes, shifted right by `(8 - L) << 3` (low)
  KSHIFTRW $8, K3, K4                                 // K4 <- negative integers (high)
  VPSRLVQ Z13, Z3, Z3                                 // Z3 <- byteswapped lanes, shifted right by `(8 - L) << 3` (high)

  VPXORQ X10, X10, X10
  VPSUBQ Z2, Z10, K3, Z2                              // Z2 <- negate integer if negative (low)
  VPCMPEQD Z14, Z4, K1, K3                            // K3 <- floating points (low/all)
  VPSUBQ Z3, Z10, K4, Z3                              // Z3 <- negate integer if negative (high)
  KSHIFTRW $8, K3, K4                                 // K4 <- floating points (high)

  VCVTTPD2QQ Z2, K3, Z2                               // Z2 <- final 64-bit integers (low)
  VCVTTPD2QQ Z3, K4, Z3                               // Z3 <- final 64-bit integers (high)

next:
  NEXT()

// unpack (Z30:Z31).K1 into Z2|Z3 when integers
TEXT bctoint(SB), NOSPLIT|NOFRAME, $0
  KTESTW        K1, K1
  JZ            next
  KMOVW         K1, K2
  VPBROADCASTD  CONSTD_0x0F(), Z27      // Z27 = 0x0F
  VPGATHERDD    0(SI)(Z30*1), K2, Z28   // Z28 = first 4 bytes
  VPANDD        Z27, Z28, Z25           // Z25 = first 4 & 0x0f = int size
  VPCMPEQD      Z25, Z27, K1, K2        // K2 = field is null
  KANDNW        K1, K2, K1              // unset int.null lanes
  VPSRLD        $4, Z28, Z28
  VPANDD        Z27, Z28, Z24           // Z24 = (word >> 4) & 0xf = descriptor tag
  VPCMPEQD.BCST CONSTD_2(), Z24, K1, K2 // K2 = is uint
  VPCMPEQD.BCST CONSTD_3(), Z24, K1, K3 // K3 = is (signed) int
  KORW          K2, K3, K1              // K1 = is (any) integer

  // assert(!(size > 8))
  VPCMPD.BCST $6, CONSTD_8(), Z25, K1, K4
  KTESTW      K4, K4
  JNZ         trap

  // compute shift from size as (8-size)*8,
  // then zero-extend it to (Z25|Z26) as 16 quadwords
  VPBROADCASTD  CONSTD_8(), Z24
  VPSUBD        Z25, Z24, K1, Z25
  VPSLLD        $3, Z25, Z25
  VEXTRACTI32X8 $1, Z25, Y26
  VPMOVZXDQ     Y25, Z25
  VPMOVZXDQ     Y26, Z26

  // load 8-byte values and mask them appropriately
  KSHIFTRW      $8, K1, K4                // K4 = upper 8 mask
  VEXTRACTI32X8 $1, Z30, Y29              // Y29 = upper 8 offsets

  // gather (Y30|Y29) into (Z27|Z28) as 16 quadwords,
  // taking care to mask away sign bits
  KMOVB         K1, K5
  VPGATHERDQ    1(SI)(Y30*1), K5, Z27     // first 8
  KMOVB         K4, K5
  VPGATHERDQ    1(SI)(Y29*1), K5, Z28

  // convert big-endian to little-endian 8-byte values
  VBROADCASTI64X2  bswap64<>(SB), Z21   // swap lookup
  VPSHUFB          Z21, Z27, Z27        // Z27 - little-endian
  VPSHUFB          Z21, Z28, Z28        // Z28 - little-endian

  // shift out bytes outside length of integer (value >> (8-size)*8)
  VPSRLVQ          Z25, Z27, K1, Z2
  VPSRLVQ          Z26, Z28, K4, Z3

  // there's no negate operation (or even a complement),
  // use 0 - x operation
  KSHIFTRW     $8, K3, K5
  VPXORQ       Z21, Z21, Z21
  VPSUBQ       Z2, Z21, K3, Z2
  VPSUBQ       Z3, Z21, K5, Z3
next:
  NEXT()
trap:
  FAIL()

// current scalar = coerce(current value, f64)
TEXT bctof64(SB), NOSPLIT|NOFRAME, $0
  KTESTW        K1, K1
  JZ            next
  KMOVW         K1, K2
  VPBROADCASTD  CONSTD_0x0F(), Z27      // Z27 = 0x0F
  VPGATHERDD    0(SI)(Z30*1), K2, Z28   // Z28 = first 4 bytes
  VPANDD        Z27, Z28, Z25           // Z25 = first 4 & 0x0f = fp size
  VPCMPEQD      Z25, Z27, K1, K2        // K2 = field is null
  KANDNW        K1, K2, K1              // unset int.null lanes
  VPSRLD        $4, Z28, Z28
  VPANDD        Z27, Z28, Z24           // Z24 = (word >> 4) & 0xf = descriptor tag
  VPCMPEQD.BCST CONSTD_4(), Z24, K1, K1 // K1 = is float
  KTESTW        K1, K1
  JZ            next

  // load fp64
  VPCMPEQD.BCST CONSTD_8(), Z25, K1, K2 // K3 = size == 8 (float64)
  KTESTW        K2, K2
  JZ            tryfp32
  VEXTRACTI32X8 $1, Z30, Y29                // Y29 = upper 8 offsets
  KSHIFTRW      $8, K2, K3
  KMOVB         K2, K4
  KMOVB         K3, K5
  // perform 8-byte loads and bwap64 the results
  VBROADCASTI32X4 bswap64<>+0(SB), Z24
  VPGATHERDQ    1(SI)(Y30*1), K4, Z20
  VPGATHERDQ    1(SI)(Y29*1), K5, Z21
  VPSHUFB       Z24, Z20, Z20
  VPSHUFB       Z24, Z21, Z21
  VMOVAPD       Z20, K2, Z2
  VMOVAPD       Z21, K3, Z3

  // load + expand fp32
tryfp32:
  KANDNW        K1, K2, K2
  VPCMPEQD.BCST CONSTD_4(), Z25, K2, K2 // K2 = size == 4 (float32)
  KTESTW        K2, K2
  JZ            next
  KORW          K1, K2, K1
  KMOVW         K2, K3
  // perform 4-byte loads, bswap32 the results,
  // and then extend them to fp64 in Z2:Z3
  VBROADCASTI32X4 bswap32<>+0(SB), Z24
  VPGATHERDD    1(SI)(Z30*1), K3, Z28
  VPSHUFB       Z24, Z28, Z28
  VCVTPS2PD.SAE Y28, Z27      // lo 8 fp32 -> Z27 x 8 fp64
  VEXTRACTF32X8 $1, Z28, Y28
  VCVTPS2PD.SAE Y28, Z28      // hi 8 fp32 -> Z28 x 8 fp64
  KSHIFTRW      $8, K2, K3
  VMOVAPD       Z27, K2, Z2
  VMOVAPD       Z28, K3, Z3
next:
  NEXT()

// Boxing Instructions
// -------------------

// boxing procedures take an operand
// with a known register layout and type
// and serialize it as ion, returning the
// data in bytecode.scratch and the offsets
// in each lane as ~offset in Z30 and length in Z31 (as usual)
//
// it is *required* that Z30:Z31 are zeroed
// in boxing procedures when the predicate (K1) register is unset!

// box 64-bit floats in Z2:Z3
// (possibly tail-calling into boxint)
TEXT bcboxfloat(SB), NOSPLIT|NOFRAME, $0
  VM_CHECK_SCRATCH_CAPACITY($(9 * 16), R15, abort)

  VPXORD     Z30, Z30, Z30
  VPXORD     Z31, Z31, Z31
  VCVTTPD2QQ Z2, Z4
  VCVTTPD2QQ Z3, Z5
  VCVTQQ2PD  Z4, Z6
  VCVTQQ2PD  Z5, Z7
  VCMPPD     $VCMP_IMM_EQ_OQ, Z2, Z6, K2 // is float64(int64(input)) == input?
  VCMPPD     $VCMP_IMM_EQ_OQ, Z3, Z7, K3
  KUNPCKBW   K2, K3, K2
  KANDW      K1, K2, K2 // K2 = floats that fit into 64-bit signed integers
  KANDNW     K1, K2, K3 // K3 = floats that are actually floats
  KTESTW     K3, K3
  JZ         check_ints

  VPBROADCASTD.Z   CONSTD_9(), K3, Z31           // set len(encoded) = 9
  VM_GET_SCRATCH_BASE_ZMM(Z30, K3)
  VMOVDQA32        byteidx<>+0(SB), X28
  VPMOVZXBD        X28, Z28
  VPSLLD           $3, Z28, Z29
  VPADDD           Z28, Z29, Z29
  VPADDD           Z29, Z30, K3, Z30             // pos += lane index * 9
  MOVL             $0x48, R8
  VPBROADCASTD     R8, Z28
  VBROADCASTI64X2  bswap64<>(SB), Z27
  VPSHUFB          Z27, Z2, Z6                   // bswap64(input)
  VPSHUFB          Z27, Z3, Z7
  KMOVW            K3, K4
  VPSCATTERDD      Z28, K4, 0(SI)(Z30*1)        // write descriptor byte
  VEXTRACTI32X8    $1, Z30, Y29
  KMOVB            K3, K4
  VSCATTERDPD      Z6, K4, 1(SI)(Y30*1)         // write lo 8 floats
  KSHIFTRW         $8, K3, K4
  VSCATTERDPD      Z7, K4, 1(SI)(Y29*1)         // write hi 8 floats
  ADDQ             $(9*16), bytecode_scratch+8(VIRT_BCPTR)       // update scratch base
check_ints:
  KTESTW     K2, K2
  JZ         next
  JMP        boxint_tail(SB)
next:
  NEXT()
abort:
  MOVL $const_bcerrMoreScratch, bytecode_err(VIRT_BCPTR)
  RET_ABORT()

// box 64-bit signed integers in Z2:Z3
//
// requires 9*16 bytes of space
TEXT bcboxint(SB), NOSPLIT|NOFRAME, $0
  KMOVW     K1, K2
  VPXORD    Z30, Z30, Z30
  VPXORD    Z31, Z31, Z31 // default value for output is len=0
  VMOVDQA64 Z2, Z4
  VMOVDQA64 Z3, Z5
  JMP       boxint_tail(SB)

// core integer boxing procedure:
//   Z4 + Z5 = 16 x 64-bit signed qwords
//   K2 = lanes to write out
// updates Z30.K2 and Z31.K2, but leaves the other lanes un-touched
TEXT boxint_tail(SB), NOSPLIT|NOFRAME, $0
  VM_CHECK_SCRATCH_CAPACITY($(9 * 16), R15, abort)

  // compute abs(word) and compute
  // the predicate mask for negative signed words
  VPMOVQ2M     Z4, K3
  VPABSQ       Z4, Z4
  VPMOVQ2M     Z5, K4
  VPABSQ       Z5, Z5

  VPLZCNTQ      Z4, Z10
  VPLZCNTQ      Z5, Z11
  VPMOVQD       Z10, Y12
  VPMOVQD       Z11, Y13
  VPBROADCASTD  CONSTD_64(), Z6
  VINSERTI32X8  $1, Y13, Z12, Z12     // Z12 = 16 x 32-bit lzcount
  VPSUBD        Z12, Z6, Z12          // Z12 = 64 - lzcnt(int)
  VPBROADCASTD  CONSTD_8(), Z8        // Z8 = 8
  VPSUBD.BCST   CONSTD_1(), Z8, Z7    // Z7 = 7
  VPADDD        Z7, Z12, Z12          // Z12 = (64-lzcnt(int))+7
  VPSRLD        $3, Z12, Z12          // Z12 = (64-lzcnt(int)+7)/8 = size of encoded big-endian int
  VPCMPEQD      Z8, Z12, K2, K6       // K6 = mask of lanes with eight significant bytes

  VPADDD.BCST      CONSTD_1(), Z12, K2, Z31 // value length = 1 + intwidth
  VPSUBD           Z12, Z8, Z14             // Z14 = (8 - size) = leading zero bytes
  VPSLLD           $3, Z14, Z14             // Z14 = 8 * leading zero bytes = leading zero bits
  VPMOVZXDQ        Y14, Z26
  VEXTRACTI32X8    $1, Z14, Y13
  VPMOVZXDQ        Y13, Z27
  VPSLLVQ          Z26, Z4, Z4              // shift ints left by leading zero bytes
  VPSLLVQ          Z27, Z5, Z5              // so the msb is now in the highest byte position
  VPBROADCASTD     CONSTD_2(), Z13
  KUNPCKBW         K3, K4, K5               // unpack to 16 lanes of sign bits
  KANDW            K2, K5, K5               // K5 = valid & sign bit set
  VPADDD.BCST      CONSTD_1(), Z13, K5, Z13 // Z13 = 2 or 3 (if signed)
  VBROADCASTI64X2  bswap64<>(SB), Z27
  VPSLLD           $4, Z13, Z13             // Z13 = 0x20 or 0x30 (if signed)
  VPADDD           Z12, Z13, Z13            // Z13 = (0x20 or 0x30) + size in bytes
  VEXTRACTI32X8    $1, Z13, Y14
  VPMOVZXDQ        Y14, Z14                 // Z14 = hi 8 descriptors, extended to qwords
  VPMOVZXDQ        Y13, Z13                 // Z13 = lo 8 descriptors, extended to qwords
  VPSHUFB          Z27, Z4, Z4              // Z4 = bswap64(lo 8 words)
  VPSHUFB          Z27, Z5, Z5              // Z5 = bswap64(hi 8 words)
  VPSLLQ           $8, Z4, Z6               // Z6, Z7 = make room for 1-byte descriptor
  VPSLLQ           $8, Z5, Z7
  VPORQ            Z13, Z6, Z6              // OR in descriptor byte
  VPORQ            Z14, Z7, Z7

  VMOVDQU64        byteidx<>(SB), X29
  VPMOVZXBD        X29, Z29           // Z29 = lane index
  VPSLLD           $3, Z29, Z28       // Z28 = lane index * 8
  VM_GET_SCRATCH_BASE_ZMM(Z30, K2)
  KTESTW           K6, K6
  JNZ              slow_encode

  // fast-path for all integers 8 bytes or less when encoded
  MOVQ             bytecode_scratch(VIRT_BCPTR), R15
  ADDQ             bytecode_scratch+8(VIRT_BCPTR), R15
  KSHIFTRW         $8, K2, K3
  VMOVDQU64        Z6, K2, 0(R15)                       // store the sixteen encoded ion objects
  VMOVDQU64        Z7, K3, 64(R15)
  ADDQ             $128, bytecode_scratch+8(VIRT_BCPTR)
  VPADDD           Z28, Z30, K2, Z30                   // add (lane*8) to offset, or set to zero
  JMP              next
slow_encode:
  // some of the lanes have 8 significant bytes,
  // so we need to perform two overlapped scatters
  ADDQ             $(9*16), bytecode_scratch+8(VIRT_BCPTR)
  VPADDD           Z28, Z30, K2, Z30   // base += (lane index * 8)
  VPADDD           Z29, Z30, K2, Z30   // base += lane index
  VEXTRACTI32X8    $1, Z30, Y28
  KMOVB            K2, K3
  VPSCATTERDQ      Z6, K3, 0(SI)(Y30*1)         // write lo 8, first 8 bytes
  KSHIFTRW         $8, K2, K3
  VPSCATTERDQ      Z7, K3, 0(SI)(Y28*1)         // write hi 8, first 8 bytes
  KMOVB            K2, K3
  VPSCATTERDQ      Z4, K3, 1(SI)(Y30*1)         // write overlapping for final byte of lo 8
  KSHIFTRW         $8, K2, K3
  VPSCATTERDQ      Z5, K3, 1(SI)(Y28*1)         // write overlapping for final byte of hi 8
next:
  NEXT()
abort:
  MOVL $const_bcerrMoreScratch, bytecode_err(VIRT_BCPTR)
  RET_ABORT()

// take the current set of non-missing lanes (K1)
// and a boolean mask (from stack[imm] -> K2)
// and write out the boolean as encoded ion
// to the scratch buffer for each non-missing lane
TEXT bcboxmask(SB), NOSPLIT|NOFRAME, $0
  MOVWQZX      0(VIRT_PCREG), R8
  ADDQ         $2, VIRT_PCREG
  KMOVW        0(VIRT_VALUES)(R8*1), K2             // K2 = true/false
  KMOVW        K1, K3                               // K3 = non-missing
  JMP          boxmask_tail(SB)

// same as boxmask, but with the arguments reversed
TEXT bcboxmask2(SB), NOSPLIT|NOFRAME, $0
  MOVWQZX      0(VIRT_PCREG), R8
  ADDQ         $2, VIRT_PCREG
  KMOVW        K1, K2                               // K2 = true/false
  KMOVW        0(VIRT_VALUES)(R8*1), K3             // K3 = non-missing
  JMP          boxmask_tail(SB)

// same as boxmask, but with K1 = K2
TEXT bcboxmask3(SB), NOSPLIT|NOFRAME, $0
  KMOVW K1, K2
  KMOVW K1, K3
  JMP   boxmask_tail(SB)

// store (up to) 16 booleans
//
// currently stores the values unconditionally,
// but only updates Z30:Z31 using K3
//
// see boxmask_tail_vbmi2 for a version that
// only writes out the lanes that are valid
TEXT boxmask_tail(SB), NOSPLIT|NOFRAME, $0
  VM_CHECK_SCRATCH_CAPACITY($16, R15, abort)
  MOVL         $0x10, R14
  VPBROADCASTB R14, X10                             // X10 = false byte x 16
  MOVL         $1, R14
  VPBROADCASTB R14, X11
  VPADDB       X10, X11, K2, X10                    // X10 = true or false bytes (0x10 + 1/0)
  MOVQ         bytecode_scratch(VIRT_BCPTR), R14
  ADDQ         bytecode_scratch+8(VIRT_BCPTR), R14
  VMOVDQU      X10, 0(R14)                          // store 16 bytes unconditionally
  // offsets are [0, 1, 2, 3...] plus base offset;
  // then complemented for Z30
  VPXORD         Z30, Z30, Z30
  VM_GET_SCRATCH_BASE_ZMM(Z30, K3)
  VMOVDQU        byteidx<>+0(SB), X10
  VPMOVZXBD      X10, Z10
  VPADDD         Z10, Z30, K3, Z30
  VPBROADCASTD.Z CONSTD_1(), K3, Z31
  // update used scratch space
  ADDQ           $16, bytecode_scratch+8(VIRT_BCPTR)
  NEXT()
abort:
  MOVL $const_bcerrMoreScratch, bytecode_err(VIRT_BCPTR)
  RET_ABORT()

// FIXME: on machines with VBMI-2 (Ice Lake and after),
// try using this version instead, which writes out fewer
// bytes when some of the lanes are missing
// (this may not be worthwhile; it depends on how much
// scratch space we expect to use)
TEXT boxmask_tail_vbmi2(SB), NOSPLIT|NOFRAME, $0
  KMOVW        K1, R15
  POPCNTL      R15, R15
  ADDQ         bytecode_scratch+8(VIRT_BCPTR), R15  // R15 = len(scratch)+popcnt(K1)
  CMPQ         bytecode_scratch+16(VIRT_BCPTR), R15 // compare w/ cap(scratch)
  JLT          abort
  MOVL         $0x10, R14
  VPBROADCASTB R14, X10                             // X10 = false byte x 16
  MOVL         $1, R14
  VPBROADCASTB R14, X11
  VPADDB       X10, X11, K2, X10                    // X10 = true or false bytes (0x10 + 1/0)
  MOVQ         bytecode_scratch(VIRT_BCPTR), R13
  MOVQ         bytecode_scratch+8(VIRT_BCPTR), R14  // current offset
  VPCOMPRESSB  X10, K1, 0(R13)(R14*1)               // write out true/false bytes
  VMOVDQU      byteidx<>+0(SB), X11                 // X11 = [0, 1, 2, 3...]
  VPEXPANDB    X11, K1, X11                         // X11 = output offset displ in each lane
  VPMOVZXBD    X11, Z11                             // expand offset to 32 bits
  VPBROADCASTD R14, Z14                             // broadcast original offset
  VPADDD       Z11, Z14, Z14                        // offset = original + displacement
  VNOTINPLACE(Z14)                                  // Z14 = ^offset

  // set Z30 to ^offset in scratch
  // set Z31 to width (one or zero, depending on K2)
  VMOVDQA32.Z    Z14, K1, Z30
  VPBROADCASTD.Z CONSTD_1(), K1, Z31

  // update len(scratch)
  MOVQ     R15, bytecode_scratch+8(VIRT_BCPTR)
  NEXT()
abort:
  MOVL $const_bcerrMoreScratch, bytecode_err(VIRT_BCPTR)
  RET_ABORT()

// Boxes string slice held in RSI(Z2:Z3)
TEXT bcboxstring(SB), NOSPLIT|NOFRAME, $0
  VPSLLD.BCST $4, CONSTD_8(), Z20 // ION type of a boxed string is 0x8
  JMP boxslice_tail(SB)

// Boxes list data held in RSI(Z2:Z3)
TEXT bcboxlist(SB), NOSPLIT|NOFRAME, $0
  VPSLLD.BCST $4, CONSTD_0x0B(), Z20 // ION type of a boxed list is 0xB
  JMP boxslice_tail(SB)

// Boxes [string, list, object] slice held in RSI(Z2:Z3)
//
// Inputs:
//   - K1 - 16-bit lane mask
//   - Z2 - 32-bit offsets relative to RSI
//   - Z3 - 32-bit lengths of each data slice
//
// Implementation notes:
//   - Two paths - small slices (up to 13 bytes), large slices (more than 13 bytes).
//   - Do gathers of the leading 16 bytes of each slice as early as possible.
//     These bytes are gathered to Z11, Z12, Z13, and Z14 and used by both code
//     paths - this optimizes a bit storing smaller slices in both cases.
//   - Encoding of the Type|L + Length happens regardless of slice lengths, we
//     do gathers meanwhile so the CPU should be busy enough to hide the latency.
TEXT boxslice_tail(SB), NOSPLIT|NOFRAME, $0
  // Quickly skip this instruction if there is nothing to box.
  VPXORD Z30, Z30, Z30
  VPXORD Z31, Z31, Z31

  KTESTW K1, K1
  JZ next

  // Gather LO-8 bytes of LO-8 lanes to Z11.
  KMOVW K1, K4
  VPXORD X11, X11, X11
  VPGATHERDQ 0(SI)(Y2*1), K4, Z11

  // Z15 will contain HI-8 indexes in the LO 256-bit part of Z15 (for gathers).
  VSHUFI64X2 $SHUFFLE_IMM_4x2b(1, 0, 3, 2), Z2, Z2, Z15

  // Load some constants here.
  VPBROADCASTD CONSTD_1(), Z10

  // K2 will contain each lane that contains string longer than 8 bytes.
  VPCMPD.BCST $VPCMP_IMM_GT, CONSTD_8(), Z3, K1, K2
  // Check whether we can use a fast-path, which requires all strings to be less
  // than 14 characters long. If K3 != K1 it would mean that we have to go slow.
  VPCMPD.BCST $VPCMP_IMM_LT, CONSTD_0x0E(), Z3, K1, K3

  // Calculate an encoded ION length.
  //
  // First encode all lengths to ION RunLength encoding, it's easier to
  // determine the length of the encoded value actually after it's encoded
  // as we can just use LZCNT with shift to get the number of bytes it requires.
  VMOVDQA32.Z Z3, K1, Z4                               // Z4 = [xxxxxxxx|xxxxxxxx|xxxxxxxx|xAAAAAAA]
  VPSLLD.Z $1, Z3, K1, Z5                              // Z5 = [xxxxxxxx|xxxxxxxx|xBBBBBBB|xxxxxxxx]
  VPSLLD.Z $2, Z3, K1, Z6                              // Z6 = [xxxxxxxx|xCCCCCCC|xxxxxxxx|xxxxxxxx]
  VPSLLD.Z $3, Z3, K1, Z7                              // Z7 = [xDDDDDDD|xxxxxxxx|xxxxxxxx|xxxxxxxx]

  // Use VPTERNLOGD to combine the extracted bits:
  //   VPTERNLOG(0xD8) == (A & ~C) | (B & C) == Blend(A, B, ~C)
  VPTERNLOGD.BCST $0xD8, CONSTD_0x007F007F(), Z4, Z5   // Z5 = [xxxxxxxx|xxxxxxxx|xBBBBBBB|xAAAAAAA]
  VPTERNLOGD.BCST $0xD8, CONSTD_0x007F007F(), Z6, Z7   // Z7 = [xDDDDDDD|xCCCCCCC|xxxxxxxx|xxxxxxxx]
  VPTERNLOGD.BCST $0xD8, CONSTD_0xFFFF0000(), Z7, Z5   // Z5 = [xDDDDDDD|xCCCCCCC|xBBBBBBB|xAAAAAAA]
  VPANDD.BCST CONSTD_0x7F7F7F7F(), Z5, Z5              // Z5 = [0DDDDDDD|0CCCCCCC|0BBBBBBB|0AAAAAAA]

  // Find the last leading bit set, which will be used to determine the number
  // of bytes required for storing each length.
  VPLZCNTD Z5, Z6
  VPBROADCASTD CONSTD_4(), Z7

  // Z5 = [0DDDDDDD|0CCCCCCC|0BBBBBBB|1AAAAAAA] where '1' is a run-length termination bit.
  VPORD.BCST CONSTD_128(), Z5, K1, Z5
  VPBROADCASTD CONSTD_32(), Z8

  // Z6 would contain the number of bytes required to store each length.
  VPSRLD $3, Z6, Z6
  VPSUBD.Z Z6, Z7, K1, Z6
  // Z7 would contain the number of bits (aligned to 8) required to store each length.
  VPSLLD $3, Z6, Z7

  // Gather HI-8 bytes of LO-8 lanes to Z12.
  KMOVW K1, K5
  VPXORD X12, X12, X12
  VPGATHERDQ 8(SI)(Y2*1), K5, Z12

  // Z7 would contain the number of bits to discard in Z5.
  VPSUBD Z7, Z8, Z7

  // Z5 <- [1AAAAAAA|0BBBBBBB|0CCCCCCC|0DDDDDDD] (ByteSwapped).
  VPSHUFB CONST_GET_PTR(bswap32, 0), Z5, Z5
  // Discards bytes in Z5 that are not used to encode the length.
  VPSRLVD Z7, Z5, Z5

  // Clear lanes in Z6 that represent strings having length less than 14 bytes.
  VPXORD Z6, Z6, K3, Z6
  // Z16 would contain the number of bytes that is required to store Type|L + Length.
  VPADDD.Z Z10, Z6, K1, Z16

  // Z7 would contain the number of bytes required to store each string in ION data.
  // What we want is to have offsets for each ION encoded string in the output buffer,
  // which can then be used to calculate the number of bytes required to store all
  // strings in all lanes. We cannot touch the output buffer without having the total.
  VPADDD.Z Z16, Z4, K1, Z7                             // Z7 = [15    14    13    12   |11    10    09    08   |07    06    05    04   |03    02    01    00   ]
  VPSLLDQ $4, Z7, Z8                                   // Z8 = [14    13    12    __   |10    09    08    __   |06    05    04    __   |02    01    00    __   ]
  VPADDD Z8, Z7, Z8                                    // Z8 = [15+14 14+13 13+12 12   |11+10 10+09 09+08 08   |07+06 06+05 05+04 04   |03+02 02+01 01+00 00   ]
  VPSLLDQ $8, Z8, Z9                                   // Z9 = [13+12 12    __    __   |09+08 08    __    __   |05+04 04    __    __   |01+00 00    __    __   ]
  VPADDD Z8, Z9, Z8                                    // Z8 = [15:12 14:12 13:12 12   |11:08 10:08 09:08 08   |07:04 06:04 05:04 04   |03:00 02:00 01:00 00   ]

  // Gather LO-8 bytes of HI-8 lanes to Z13.
  KSHIFTRW $8, K1, K4
  VPXORD X13, X13, X13
  VPGATHERDQ 0(SI)(Y15*1), K4, Z13

  MOVL $0xF0F0, R15
  KMOVW R15, K4
  VPSHUFD $SHUFFLE_IMM_4x2b(3, 3, 3, 3), Z8, Z9        // Z9 = [15:12 15:12 15:12 15:12|11:08 11:08 11:08 11:08|07:04 07:04 07:04 07:04|03:00 03:00 03:00 03:00]
  VPERMQ $SHUFFLE_IMM_4x2b(1, 1, 1, 1), Z9, Z9         // Z9 = [11:08 11:08 11:08 11:08|<ign> <ign> <ign> <ign>|03:00 03:00 03:00 03:00|<ign> <ign> <ign> <ign>]
  VPADDD Z9, Z8, K4, Z8                                // Z8 = [15:08 14:08 13:08 12:08|11:08 10:08 09:08 08   |07:00 06:00 05:00 04:00|03:00 02:00 01:00 00   ]

  MOVL $0xFF00, R15
  KMOVW R15, K4
  VPSHUFD $SHUFFLE_IMM_4x2b(3, 3, 3, 3), Z8, Z9        // Z9 = [15:08 15:08 15:08 15:08|11:08 11:08 11:08 11:08|07:00 07:00 07:00 07:00|03:00 03:00 03:00 03:00]
  VSHUFI64X2 $SHUFFLE_IMM_4x2b(1, 1, 1, 1), Z9, Z9, Z9 // Z9 = [07:00 07:00 07:00 07:00|07:00 07:00 07:00 07:00|<ign> <ign> <ign> <ign>|<ign> <ign> <ign> <ign>]
  VPADDD Z9, Z8, K4, Z8                                // Z8 = [15:00 14:00 13:00 12:00|11:00 10:00 09:00 08:00|07:00 06:00 05:00 04:00|03:00 02:00 01:00 00   ]

  // We need to calculate the the number of bytes we are going to write to the
  // destination - we have to shuffle the content of Z8 in order to do that.
  VEXTRACTI32X4 $3, Z8, X9
  VPEXTRD $3, X9, R15

  // Gather HI-8 bytes of HI-8 lanes to Z14.
  KSHIFTRW $8, K2, K5
  VPXORD X14, X14, X14
  VPGATHERDQ 8(SI)(Y15*1), K5, Z14

  // Z8 now contains the end index of each lane. What we need is, however, the
  // start index, which can be calculated by subtracting start indexes from it.
  VPSUBD Z7, Z8, Z9                                    // Z9 = [14:00 13:00 12:00 11:00|10:00 09:00 08:00 07:00|06:00 05:00 04:00 03:00|02:00 01:00 00    zero ]

  MOVQ bytecode_scratch+8(VIRT_BCPTR), CX              // CX = Output buffer length.
  MOVQ bytecode_scratch+16(VIRT_BCPTR), R8             // R8 = Output buffer capacity.
  LEAQ 16(R15), BX                                     // BX = Capacity required to store the output (let's assume 16 bytes more for 16-byte stores).
  SUBQ CX, R8                                          // R8 = Remaining space in the output buffer.

  // Abort if the output buffer is too small.
  CMPQ R8, BX
  JLT abort

  // Update the output buffer length and Z30/Z31 (boxed value outputs).
  VPBROADCASTD.Z CX, K1, Z30
  VPADDD.BCST bytecode_scratchoff(VIRT_BCPTR), Z30, K1, Z30
  ADDQ CX, R15
  VPADDD Z9, Z30, K1, Z30
  VMOVDQA32.Z Z7, K1, Z31                              // Z31 = ION data length: Type|L + optional VarUInt + string data.
  MOVQ R15, bytecode_scratch+8(VIRT_BCPTR)             // Store output buffer length back to the bytecode_scratch slice.

  MOVL bytecode_scratchoff(VIRT_BCPTR), R8             // R8 = location of scratch base
  ADDQ SI, R8                                          // R8 += base output address.
  ADDQ CX, R8                                          // R8 += adjusted output address by its current length.

  // Unpack string data into 16-byte units, so we can use 16-byte stores.
  VPUNPCKLQDQ Z12, Z11, Z10                            // Z10 = [S06 S06 S06 S06|S04 S04 S04 S04|S02 S02 S02 S02|S00 S00 S00 S00]
  VPUNPCKHQDQ Z12, Z11, Z11                            // Z11 = [S07 S07 S07 S07|S05 S05 S05 S05|S03 S03 S03 S03|S01 S01 S01 S01]
  VPUNPCKLQDQ Z14, Z13, Z12                            // Z12 = [S14 S14 S14 S14|S12 S12 S12 S12|S10 S10 S10 S10|S08 S08 S08 S08]
  VPUNPCKHQDQ Z14, Z13, Z13                            // Z13 = [S15 S15 S15 S15|S13 S13 S13 S13|S11 S11 S11 S11|S09 S09 S09 S09]

  // K3 contains a mask of strings having length lesser than 14. If all strings
  // of all lanes have length lesser than 14 then we can take a fast path.
  KTESTW K1, K3
  JNC large_string

  // --- Fast path for small strings (small string in each lane or MISSING) ---

  // Make Z7 contain Type|L where Type is the requested ION type
  VPORD.Z Z20, Z3, K1, Z7                              // Z7  = [L15 L14 L13 L12|L11 L10 L09 L08|L07 L06 L05 L04|L03 L02 L01 L00]
  VPMOVZXDQ Y7, Z5                                     // Z5  = [___ L07 ___ L06|___ L05 ___ L04|___ L03 ___ L02|___ L01 ___ L00]
  VSHUFI64X2 $SHUFFLE_IMM_4x2b(1, 0, 3, 2), Z7, Z7, Z7

  VPSLLDQ $7, Z5, Z6                                   // Z6  = [L07 ___ L06 ___|L05 ___ L04 ___|L03 ___ L02 ___|L01 ___ L00 ___]
  VPSLLDQ $15, Z5, Z5                                  // Z5  = [L06 ___ ___ ___|L04 ___ ___ ___|L02 ___ ___ ___|L00 ___ ___ ___]
  VPMOVZXDQ Y7, Z7                                     // Z7  = [___ L15 ___ L14|___ L13 ___ L12|___ L11 ___ L10|___ L09 ___ L08]

  VPALIGNR $15, Z6, Z11, Z11                           // Z11 = [V07 V07 V07 V07|V05 V05 V05 V05|V03 V03 V03 V03|V01 V01 V01 V01]
  VPALIGNR $15, Z5, Z10, Z10                           // Z10 = [V06 V06 V06 V06|V04 V04 V04 V04|V02 V02 V02 V02|V00 V00 V00 V00]

  VPSLLDQ $7, Z7, Z6                                   // Z6  = [L15 ___ L14 ___|L13 ___ L12 ___|L11 ___ L10 ___|L09 ___ L08 ___]
  VPSLLDQ $15, Z7, Z7                                  // Z7  = [L14 ___ ___ ___|L12 ___ ___ ___|L10 ___ ___ ___|L08 ___ ___ ___]

  VPALIGNR $15, Z6, Z13, Z13                           // Z13 = [V15 V15 V15 V15|V13 V13 V13 V13|V11 V11 V11 V11|V09 V09 V09 V09]
  VPALIGNR $15, Z7, Z12, Z12                           // Z12 = [V14 V14 V14 V14|V12 V12 V12 V12|V10 V10 V10 V10|V08 V08 V08 V08]

  VPEXTRD $0, X8, DX
  VEXTRACTI32X4 $1, Z8, X5
  VMOVDQU32 X10, 0(R8)                                 // {00} Write [V00 V00 V00 V00]
  VPEXTRD $1, X8, CX
  VMOVDQU32 X11, 0(R8)(DX*1)                           // {01} Write [V01 V01 V01 V01]
  VPEXTRD $2, X8, DX
  VEXTRACTI32X4 $1, Z10, 0(R8)(CX*1)                   // {02} Write [V02 V02 V02 V02]
  VPEXTRD $3, X8, CX
  VEXTRACTI32X4 $1, Z11, 0(R8)(DX*1)                   // {03} Write [V03 V03 V03 V03]

  VPEXTRD $0, X5, DX
  VEXTRACTI32X4 $2, Z8, X6
  VEXTRACTI32X4 $2, Z10, 0(R8)(CX*1)                   // {04} Write [V04 V04 V04 V04]
  VPEXTRD $1, X5, CX
  VEXTRACTI32X4 $2, Z11, 0(R8)(DX*1)                   // {05} Write [V05 V05 V05 V05]
  VPEXTRD $2, X5, DX
  VEXTRACTI32X4 $3, Z10, 0(R8)(CX*1)                   // {06} Write [V06 V06 V06 V06]
  VPEXTRD $3, X5, CX
  VEXTRACTI32X4 $3, Z11, 0(R8)(DX*1)                   // {07} Write [V07 V07 V07 V07]

  VPEXTRD $0, X6, DX
  VEXTRACTI32X4 $3, Z8, X5
  VMOVDQU32 X12, 0(R8)(CX*1)                           // {08} Write [V08 V08 V08 V08]
  VPEXTRD $1, X6, CX
  VMOVDQU32 X13, 0(R8)(DX*1)                           // {09} Write [V09 V09 V09 V09]
  VPEXTRD $2, X6, DX
  VEXTRACTI32X4 $1, Z12, 0(R8)(CX*1)                   // {10} Write [V10 V10 V10 V10]
  VPEXTRD $3, X6, CX
  VEXTRACTI32X4 $1, Z13, 0(R8)(DX*1)                   // {11} Write [V11 V11 V11 V11]

  VPEXTRD $0, X5, DX
  VEXTRACTI32X4 $2, Z12, 0(R8)(CX*1)                   // {12} Write [V12 V12 V12 V12]
  VPEXTRD $1, X5, CX
  VEXTRACTI32X4 $2, Z13, 0(R8)(DX*1)                   // {13} Write [V13 V13 V13 V13]
  VPEXTRD $2, X5, DX
  VEXTRACTI32X4 $3, Z12, 0(R8)(CX*1)                   // {14} Write [V14 V14 V14 V14]
  VEXTRACTI32X4 $3, Z13, 0(R8)(DX*1)                   // {15} Write [V15 V15 V15 V15]

  JMP next

large_string:
  // --- Slow path for large strings (one/more lane has a string greater than 13 bytes) ---

  // We already have encoded ION length, including the information regarding how "long" the length is.
  VPBROADCASTD.Z CONSTD_0x0E(), K1, Z15
  VMOVDQA32 Z3, K3, Z15                                // Z15 = [L15 L14 L13 L12|L11 L10 L09 L08|L07 L06 L05 L04|L03 L02 L01 L00]
  VPORD.Z Z20, Z15, K1, Z15                            // Z15 = [T15 T14 T13 T12|T11 T10 T09 T08|T07 T06 T05 T04|T03 T02 T01 T00]
  VPSLLD $24, Z15, Z15

  VPUNPCKLDQ Z5, Z15, Z14                              // Z14 = [L13 T13 L12 T12|L09 T09 L08 T08|L05 T05 L04 T04|L01 T01 L00 T00]
  VPUNPCKHDQ Z5, Z15, Z15                              // Z15 = [L15 T15 L14 T14|L11 T11 L10 T10|L07 T07 L06 T06|L03 T03 L02 T02]

  // This will make each QWORD look like [__ __ __ VU VU VU VU TL] where
  // TL is Type|L and VU is VarUInt representing string length in bytes.
  VPSRLQ $24, Z14, Z14
  VPSRLQ $24, Z15, Z15

  // Z5 now contains 32-bit indexes to RSI (input buffer).
  VMOVDQA32.Z Z2, K1, Z5

  // The following code processes 4 strings each loop iteration.
  MOVL $4, BX

  // Requred by MOVSB, we have to move them temporarily.
  MOVQ DI, R14
  MOVQ SI, R15

large_repeat:
  VPEXTRD $0, X9, DX                                   // {0} Offset in the output buffer.
  VPEXTRD $0, X4, CX                                   // {0} String length in bytes (without ION overhead).
  VPEXTRD $0, X16, DI                                  // {0} Byte length of Type|L followed by VarUInt representing string length.
  VPEXTRD $0, X5, SI                                   // {0} Index into the input buffer.
  VPEXTRQ $0, X14, 0(R8)(DX*1)                         // {0} Write Type|L byte + optional Length if the string is longer than 13.
  ADDQ DX, DI                                          // {0} Adjust output offset to point to the first string data index.
  VMOVDQU32 X10, 0(R8)(DI*1)                           // {0} Write the initial [15:0] slice of the string.

  SUBQ $16, CX                                         // {0} We have written 16 bytes already.
  JBE large_skip_0                                     // {0} Skip MOVSB if this string was not greater than 16 bytes.
  LEAQ 16(R15)(SI*1), SI                               // {0} RSI - source pointer.
  LEAQ 16(R8)(DI*1), DI                                // {0} RDI - destination pointer.
  REP; MOVSB                                           // {0} Move RCX bytes from RSI to RDI.

large_skip_0:
  VPEXTRD $1, X9, DX                                   // {1} Offset in the output buffer.
  VPEXTRD $1, X4, CX                                   // {1} String length in bytes (without ION overhead).
  VPEXTRD $1, X16, DI                                  // {1} Byte length of Type|L followed by VarUInt representing string length.
  VPEXTRD $1, X5, SI                                   // {1} Index into the input buffer.
  VPEXTRQ $1, X14, 0(R8)(DX*1)                         // {1} Write Type|L byte + optional Length if the string is longer than 13.
  ADDQ DX, DI                                          // {1} Adjust output offset to point to the first string data index.
  VMOVDQU32 X11, 0(R8)(DI*1)                           // {1} Write the initial [15:0] slice of the string.

  SUBQ $16, CX                                         // {1} We have written 16 bytes already.
  JBE large_skip_1                                     // {1} Skip MOVSB if this string was not greater than 16 bytes.
  LEAQ 16(R15)(SI*1), SI                               // {1} RSI - source pointer.
  LEAQ 16(R8)(DI*1), DI                                // {1} RDI - destination pointer.
  REP; MOVSB                                           // {1} Move RCX bytes from RSI to RDI.

large_skip_1:
  VPEXTRD $2, X9, DX                                   // {2} Offset in the output buffer.
  VPEXTRD $2, X4, CX                                   // {2} String length in bytes (without ION overhead).
  VPEXTRD $2, X16, DI                                  // {2} Byte length of Type|L followed by VarUInt representing string length.
  VPEXTRD $2, X5, SI                                   // {2} Index into the input buffer.
  VPEXTRQ $0, X15, 0(R8)(DX*1)                         // {2} Write Type|L byte + optional Length if the string is longer than 13.
  ADDQ DX, DI                                          // {2} Adjust output offset to point to the first string data index.
  VEXTRACTI32X4 $1, Z10, 0(R8)(DI*1)                   // {2} Write the initial [15:0] slice of the string.

  SUBQ $16, CX                                         // {2} We have written 16 bytes already.
  JBE large_skip_2                                     // {2} Skip MOVSB if this string was not greater than 16 bytes.
  LEAQ 16(R15)(SI*1), SI                               // {2} RSI - source pointer.
  LEAQ 16(R8)(DI*1), DI                                // {2} RDI - destination pointer.
  REP; MOVSB                                           // {2} Move RCX bytes from RSI to RDI.

large_skip_2:
  VPEXTRD $3, X9, DX                                   // {3} Offset in the output buffer.
  VPEXTRD $3, X4, CX                                   // {3} String length in bytes (without ION overhead).
  VPEXTRD $3, X16, DI                                  // {3} Byte length of Type|L followed by VarUInt representing string length.
  VPEXTRD $3, X5, SI                                   // {3} Index into the input buffer.
  VPEXTRQ $1, X15, 0(R8)(DX*1)                         // {3} Write Type|L byte + optional Length if the string is longer than 13.
  ADDQ DX, DI                                          // {3} Adjust output offset to point to the first string data index.
  VEXTRACTI32X4 $1, Z11, 0(R8)(DI*1)                   // {3} Write the initial [15:0] slice of the string.

  SUBQ $16, CX                                         // {3} We have written 16 bytes already.
  JBE large_skip_3                                     // {3} Skip MOVSB if this string was not greater than 16 bytes.
  LEAQ 16(R15)(SI*1), SI                               // {3} RSI - source pointer.
  LEAQ 16(R8)(DI*1), DI                                // {3} RDI - destination pointer.
  REP; MOVSB                                           // {3} Move RCX bytes from RSI to RDI.

large_skip_3:
  // Shuffle all vectors so we will end up with values in low parts.
  VSHUFI64X2 $SHUFFLE_IMM_4x2b(0, 3, 2, 1), Z4, Z4, Z4    // Z4/Z5/Z9/Z16 are indexes and lengths (DWORDS).
  VSHUFI64X2 $SHUFFLE_IMM_4x2b(0, 3, 2, 1), Z5, Z5, Z5
  VSHUFI64X2 $SHUFFLE_IMM_4x2b(0, 3, 2, 1), Z9, Z9, Z9
  VSHUFI64X2 $SHUFFLE_IMM_4x2b(0, 3, 2, 1), Z16, Z16, Z16

  VSHUFI64X2 $SHUFFLE_IMM_4x2b(1, 0, 3, 2), Z12, Z10, Z10 // Z10:Z13 are first 16 bytes of each string (QWORDS).
  VSHUFI64X2 $SHUFFLE_IMM_4x2b(1, 0, 3, 2), Z13, Z11, Z11
  VSHUFI64X2 $SHUFFLE_IMM_4x2b(1, 0, 3, 2), Z12, Z12, Z12
  VSHUFI64X2 $SHUFFLE_IMM_4x2b(1, 0, 3, 2), Z13, Z13, Z13

  VSHUFI64X2 $SHUFFLE_IMM_4x2b(0, 3, 2, 1), Z14, Z14, Z14 // Z14:Z15 are Type|L + encoded string lengths (QWORDS).
  VSHUFI64X2 $SHUFFLE_IMM_4x2b(0, 3, 2, 1), Z15, Z15, Z15

  SUBL $1, BX
  JNZ large_repeat

  MOVQ R14, DI
  MOVQ R15, SI

next:
  NEXT()

abort:
  MOVL $const_bcerrMoreScratch, bytecode_err(VIRT_BCPTR)
  RET_ABORT()


// Make List / Struct
// ------------------

/*
(for our script to pick up the opcodes)
TEXT bcmakelist(SB), NOSPLIT|NOFRAME, $0
TEXT bcmakestruct(SB), NOSPLIT|NOFRAME, $0
*/

#define BC_GENERATE_MAKE_LIST
#include "evalbc_make_object_impl.h"
#undef BC_GENERATE_MAKE_LIST

#define BC_GENERATE_MAKE_STRUCT
#include "evalbc_make_object_impl.h"
#undef BC_GENERATE_MAKE_STRUCT


// Hash Instructions
// -----------------

TEXT bchashvalue(SB), NOSPLIT|NOFRAME, $0
  MOVWQZX          0(VIRT_PCREG), R8
  ADDQ             $2, VIRT_PCREG
  ADDQ             bytecode_hashmem(VIRT_BCPTR), R8
  MOVQ             R8, R14
  MOVQ             VIRT_BASE, R15
  VPXORD           X10, X10, X10
  VMOVDQU32        Z10, (R8)
  VMOVDQU32        Z10, 64(R8)
  VMOVDQU32        Z10, 128(R8)
  VMOVDQU32        Z10, 192(R8)
  VMOVDQA32.Z      Z30, K1, Z28
  VMOVDQA32.Z      Z31, K1, Z29
  JMP              hashimpl_tail(SB)

TEXT bchashvalueplus(SB), NOSPLIT|NOFRAME, $0
  MOVWQZX          0(VIRT_PCREG), R14
  MOVWQZX          2(VIRT_PCREG), R8
  ADDQ             $4, VIRT_PCREG
  ADDQ             bytecode_hashmem(VIRT_BCPTR), R8
  ADDQ             bytecode_hashmem(VIRT_BCPTR), R14
  MOVQ             VIRT_BASE, R15
  VMOVDQA32.Z      Z30, K1, Z28
  VMOVDQA32.Z      Z31, K1, Z29
  JMP              hashimpl_tail(SB)

// expected input register arguments:
//   R8 = destination hash slot
//   R14 = source hash slot (may alias R8)
//   R15 = base memory pointer
//   Z28 = offsets relative to base
//   Z29 = lengths relative to offsets
TEXT hashimpl_tail(SB), NOSPLIT|NOFRAME, $0
  VBROADCASTI32X4  chachaiv<>+0(SB), Z27
  VMOVDQA32        X28, X10
  VMOVDQA32        X29, X11
  VPXORD           0(R14), Z27, Z9
  CALL             hashx4(SB)
  VMOVDQU32        Z9, 0(R8)
  VEXTRACTI32X4    $1, Z28, X10
  VEXTRACTI32X4    $1, Z29, X11
  VPXORD           64(R14), Z27, Z9
  CALL             hashx4(SB)
  VMOVDQU32        Z9, 64(R8)
  VEXTRACTI32X4    $2, Z28, X10
  VEXTRACTI32X4    $2, Z29, X11
  VPXORD           128(R14), Z27, Z9
  CALL             hashx4(SB)
  VMOVDQU32        Z9, 128(R8)
  VEXTRACTI32X4    $3, Z28, X10
  VEXTRACTI32X4    $3, Z29, X11
  VPXORD           192(R14), Z27, Z9
  CALL             hashx4(SB)
  VMOVDQU32        Z9, 192(R8)
  NEXT()

#define QROUNDx4(rowa, rowb, rowc, rowd, ztmp) \
  VPADDD rowa, rowb, rowa                      \
  VPXORD rowa, rowd, ztmp                      \
  VPROLD $16, ztmp, rowd                       \
  VPADDD rowc, rowd, rowc                      \
  VPXORD rowb, rowc, ztmp                      \
  VPROLD $12, ztmp, rowb                       \
  VPADDD rowa, rowb, rowa                      \
  VPXORD rowd, rowa, ztmp                      \
  VPROLD $8, ztmp, rowd                        \
  VPADDD rowc, rowd, rowc                      \
  VPXORD rowb, rowc, ztmp                      \
  VPROLD $7, ztmp, rowb

// within each 4-dword lane,
// rotate words left by 1
#define ROTLD_1(row) VPSHUFD $57, row, row
// ... left by 2
#define ROTLD_2(row) VPSHUFD $78, row, row
// ... left by 3
#define ROTLD_3(row) VPSHUFD $147, row, row

#define ROUNDx2(rowa, rowb, rowc, rowd, ztmp) \
  QROUNDx4(rowa, rowb, rowc, rowd, ztmp)      \
  ROTLD_1(rowb)                               \
  ROTLD_2(rowc)                               \
  ROTLD_3(rowd)                               \
  QROUNDx4(rowa, rowb, rowc, rowd, ztmp)      \
  ROTLD_3(rowb)                               \
  ROTLD_2(rowc)                               \
  ROTLD_1(rowd)

// inputs:
//   R15 = base, X10:X11 = offset:ptr, Z9 = iv
// outputs:
//   Z9 = 4x128 hash outputs
// clobbers:
//   Z6-Z24, CX, R13
TEXT hashx4(SB), NOFRAME|NOSPLIT, $0
  // populate initial rows (seed should be populated)
  VBROADCASTI32X4 chachaiv<>+16(SB), Z12
  VBROADCASTI32X4 chachaiv<>+32(SB), Z13
  VBROADCASTI32X4 chachaiv<>+48(SB), Z14

  // unpack 4 lanes to 8 lanes for offsets and lengths
  VPMOVZXDQ    X10, Y10         // Y10 = 4*64bit offsets (zero extend)
  VPMOVZXDQ    X11, Y11         // Y11 = 4*64bit lengths (zero extend)
  VPMOVZXDQ    Y10, Z10         // Z10 = 4*128bit offsets (zero extend)
  VPMOVZXDQ    Y11, Z11         // Z11 = 4*128bit lengths (zero extend)
  VPXORD       Z9, Z11, Z9      // fold length into IV

  VPUNPCKLQDQ  Z10, Z10, Z10    // Z10 = 8*64bit offsets, duplicated pair-wise
  VPUNPCKLQDQ  Z11, Z11, Z11    // Z11 = 8*64bit lengths, duplicated pair-wise
  VPBROADCASTQ CONSTQ_8(), Z8   // Z8 = $8
  MOVL         $0xaa, CX
  KMOVB        CX, K4
  VPADDQ       Z8, Z10, K4, Z10 // offset in odd lanes += 8
  VPSUBQ       Z8, Z11, K4, Z11 // length in odd lanes -= 8

  // create masks for each lane
  VPXORQ        Z16, Z16, Z16           // Z16 = zeros
  VPBROADCASTQ  CONSTQ_NEG_1(), Z20     // Z20 = all 1s
  VPCMPQ        $6, Z16, Z11, K2        // K2 = lanes > 0 (signed!)
  VPANDQ.BCST.Z CONSTQ_7(), Z11, K2, Z7 // Z7 = bytes&7 or 0 if <=0
  VPSLLQ        $3, Z7, Z7              // Z7 = valid bytes *= 8 = valid bits
  VPSLLVQ       Z7, Z20, Z7             // Z7 = ones << valid bits
  VPSLLQ        $1, Z8, Z6              // Z6 = $16 as quadwords

  KTESTB       K2, K2
  JZ           done
  KSHIFTRB     $1, K4, K4     // K4 = $0x55
loop:
  // extract the 8-bit K2 mask into a 16-bit dword mask
  KANDB        K2, K4, K3     // K3 = even bits
  KSHIFTLB     $1, K3, K3     // K3 = K2<<1 = odd bits
  KORB         K3, K2, K5     // K5: even bits imply odd bits
  VPMOVM2B     K5, X15        // byte=[0 or 0xff] for each of 8 bits
  VPUNPCKLBW   X15, X15, X15  // interleave bits
  VPMOVB2M     X15, K5        // K5 = dword register mask

  VPXORQ       Z17, Z17, Z17
  VPXORQ       Z18, Z18, Z18
  VPXORQ       Z19, Z19, Z19

  KMOVB        K2, K3
  VPGATHERQQ   0(R15)(Z10*1), K3, Z17  // Z17 = row 0
  VPCMPUQ      $6, Z11, Z8, K2, K3     // K3 = len < 8 (unsigned!)
  VPANDNQ      Z17, Z7, K3, Z17        // &^=mask when len<8
  VPSUBQ       Z6, Z11, K2, Z11        // len -= 16

  VPCMPQ       $6, Z16, Z11, K2, K2    // still > 0?
  KMOVB        K2, K3
  VPGATHERQQ   16(R15)(Z10*1), K3, Z18 // Z18 = row 1
  VPCMPUQ      $6, Z11, Z8, K2, K3     // len<8
  VPANDNQ      Z18, Z7, K3, Z18        // &^=mask when len<8
  VPSUBQ       Z6, Z11, K2, Z11        // len -= 16

  VPCMPQ       $6, Z16, Z11, K2, K2    // k1 = still > 0?
  KMOVB        K2, K3
  VPGATHERQQ   32(R15)(Z10*1), K3, Z19 // Z19 = row 2
  VPCMPUQ      $6, Z11, Z8, K2, K3     // K3 = len<8
  VPANDNQ      Z19, Z7, K3, Z19
  VPSUBQ       Z6, Z11, K2, Z11

  VMOVDQA32 Z9, Z20
  VPXORD    Z12, Z17, Z21
  VPXORD    Z13, Z18, Z22
  VPXORD    Z14, Z19, Z23
  MOVL      $4, R13
rounds:
  ROUNDx2(Z20, Z21, Z22, Z23, Z24)
  DECL      R13
  JNZ       rounds
  VPADDD    Z9,  Z20, K5, Z9
  VPADDD    Z12, Z21, K5, Z12
  VPADDD    Z13, Z22, K5, Z13
  VPADDD    Z14, Z23, K5, Z14

  // loop tail: continue while any(len(lane))>0
  VPCMPQ      $6, Z16, Z11, K2, K2          // len(lane) > 0?
  VPADDQ.BCST CONSTQ_48(), Z10, K2, Z10     // offset += 48
  KTESTB      K2, K2
  JNZ         loop
done:
  RET

// given input hash[imm0], determine
// if there are members in tree[imm1]
TEXT bchashmember(SB), NOSPLIT|NOFRAME, $0
  MOVWQZX 0(VIRT_PCREG), R8
  MOVWQZX 2(VIRT_PCREG), R13
  ADDQ    $4, VIRT_PCREG
  KTESTW  K1, K1
  JZ      next
  ADDQ    bytecode_hashmem(VIRT_BCPTR), R8       // R8 = pointer to input hash slot
  MOVQ    bytecode_trees(VIRT_BCPTR), R14
  MOVQ    0(R14)(R13*8), R13                     // R13 = tree pointer
  KMOVW   K1, K2
  KMOVW   K1, K3

  // load the low 64 bits of the sixteen hashes;
  // we should have Z15 = first 8 lo 64, Z16 = second 8 lo 64
  VMOVDQU64   0(R8), Z15
  VMOVDQU64   64(R8), Z16
  VPUNPCKLQDQ Z16, Z15, Z15
  VMOVDQU64   128(R8), Z16
  VMOVDQU64   192(R8), Z17
  VPUNPCKLQDQ Z17, Z16, Z16
  VMOVDQU64   permute64+0(SB), Z18
  VPERMQ      Z15, Z18, Z15                      // Z15 = low 8 hashes (64-bit)
  VPERMQ      Z16, Z18, Z16                      // Z16 = hi 8 ''
  VMOVDQA64   Z15, Z17                           // Z17, Z18 = temporaries for rotated hashes
  VMOVDQA64   Z16, Z18

  // load some immediates
  VONES(Z10)                       // Z10 = all ones
  VPSRLD        $28, Z10, Z6       // Z6 = 0xf
  VPXORQ        Z14, Z14, Z14      // Z14 = constant 0
  VPXORQ        Z7, Z7, Z7         // Z7 = shift count

  // load table[0] into Z8 and copy to Z9
  MOVQ          radixTree64_index(R13), R15
  VMOVDQU32     0(R15), Z8         // Z8 = initial indices for (hash&mask)
  VMOVDQA32     Z8, Z9             // Z9 = same

  // extract low 32-bit words from hashes
  VPMOVQD       Z15, Y24
  VPMOVQD       Z16, Y25
  VINSERTI32X8  $1, Y25, Z24, Z11  // Z11 = lo32 x 16 words
  VPRORQ        $32, Z15, Z26      // rotate 32 bits to get hi 32
  VPRORQ        $32, Z16, Z27
  VPMOVQD       Z26, Y26
  VPMOVQD       Z27, Y27
  VINSERTI32X8  $1, Y27, Z26, Z12  // Z12 = hi32 x 16 words

  // compute the first table offset
  // as a permutation into the correct
  // initial slot (since we have a sixteen-wide splay)
  VPANDD        Z11, Z6, Z11
  VPANDD        Z12, Z6, Z12
  VPERMD        Z8, Z11, Z8
  VPERMD        Z9, Z12, Z9
  JMP           loop_tail

  // inner loop: i = table[i][(hash>>shift)&mask]; shift += 4;
  // Z8 or Z9 = i, Z17 and Z18 are 64-bit hashes
  //
  // loop while i > 0; perform two searches simultaneously
  // with active lanes marked as K2 and K3 respectively
loop:
  // lo 32 bits x 16 -> Z24
  VPMOVQD       Z17, Y24
  VPMOVQD       Z18, Y25
  VINSERTI32X8  $1, Y25, Z24, Z24

  // hi 32 bits x 16 -> Z25
  VPSRLQ        $32, Z17, Z25
  VPSRLQ        $32, Z18, Z26
  VPMOVQD       Z25, Y25
  VPMOVQD       Z26, Y26
  VINSERTI32X8  $1, Y26, Z25, Z25

  VPANDD        Z24, Z6, Z24  // lo 8 &= mask
  VPANDD        Z25, Z6, Z25  // hi 8 &= mask
  VPSLLD        $4, Z8, Z11   // Z11 = index * 16 = ptr0
  VPSLLD        $4, Z9, Z12   // Z12 = index * 16 = ptr1
  VPADDD        Z11, Z24, Z11 // Z11 = (index * 16) + (hash & mask)
  VPADDD        Z12, Z25, Z12 // Z12 = (index * 16) + (hash & mask)
  KMOVW         K2, K4
  VPGATHERDD    0(R15)(Z11*4), K4, Z8 // Z8 = table[Z8][(hash&mask)]
  KMOVW         K3, K5
  VPGATHERDD    0(R15)(Z12*4), K5, Z9 // Z9 = table[Z9][(hash&mask)]
loop_tail:
  VPRORQ        $4, Z17, Z17        // chomp 4 bits of hash
  VPRORQ        $4, Z18, Z18
  VPCMPD        $1, Z8, Z14, K2, K2 // select lanes with index > 0
  VPCMPD        $1, Z9, Z14, K3, K3
  KORTESTW      K2, K3
  JNZ           loop                // loop while any indices are non-negative

  // determine if values[i] == hash in each lane
  VPTESTMD      Z8, Z8, K1, K2  // select index != 0
  VPTESTMD      Z9, Z9, K1, K3  //
  VPXORD        Z8, Z10, K2, Z8 // ^idx = value index
  VPXORD        Z9, Z10, K3, Z9

  MOVQ          radixTree64_values(R13), R15

  // load and test against hash0
  VEXTRACTI32X8 $1, Z8, Y24            // upper 8 indices
  KMOVB         K2, K5
  VPGATHERDQ    0(R15)(Y8*1), K5, Z26  // Z26 = first 8 hashes
  KSHIFTRW      $8, K2, K5
  VPGATHERDQ    0(R15)(Y24*1), K5, Z27 // Z27 = second 8 hashes
  VPCMPEQQ      Z15, Z26, K2, K5       // K5 = lo 8 match
  KSHIFTRW      $8, K2, K6
  VPCMPEQQ      Z16, Z27, K6, K6       // K6 = hi 8 match
  KUNPCKBW      K5, K6, K2             // (K5||K6) -> K2 = found lanes

  // load and test against hash1 (same as above)
  KANDNQ        K3, K2, K3             // unset already found from K3
  VEXTRACTI32X8 $1, Z9, Y25            // lower 8 indices
  VPROLQ        $32, Z15, Z15          // first 8 rol 32
  VPROLQ        $32, Z16, Z16          // second 8 rol 32
  KMOVB         K3, K5
  VPGATHERDQ    0(R15)(Y9*1), K5, Z26
  KSHIFTRW      $8, K3, K5
  VPGATHERDQ    0(R15)(Y25*1), K5, Z27
  VPCMPEQQ      Z15, Z26, K3, K4
  KSHIFTRW      $8, K3, K6
  VPCMPEQQ      Z16, Z27, K6, K6
  KUNPCKBW      K4, K6, K3
  KORW          K2, K3, K1             // K1 = (matched hash0)|(matched hash1)
next:
  NEXT()

// given input hash[imm0], determine
// if there are members in tree[imm1]
// and put them in the V register
TEXT bchashlookup(SB), NOSPLIT|NOFRAME, $0
  MOVWQZX 0(VIRT_PCREG), R8
  MOVWQZX 2(VIRT_PCREG), R13
  ADDQ    $4, VIRT_PCREG
  VPXORD  Z30, Z30, Z30
  VPXORD  Z31, Z31, Z31
  KTESTW  K1, K1
  JZ      next
  ADDQ    bytecode_hashmem(VIRT_BCPTR), R8       // R8 = pointer to input hash slot
  MOVQ    bytecode_trees(VIRT_BCPTR), R14
  MOVQ    0(R14)(R13*8), R13                     // R13 = tree pointer
  KMOVW   K1, K2
  KMOVW   K1, K3

  // load the low 64 bits of the sixteen hashes;
  // we should have Z15 = first 8 lo 64, Z16 = second 8 lo 64
  VMOVDQU64   0(R8), Z15
  VMOVDQU64   64(R8), Z16
  VPUNPCKLQDQ Z16, Z15, Z15
  VMOVDQU64   128(R8), Z16
  VMOVDQU64   192(R8), Z17
  VPUNPCKLQDQ Z17, Z16, Z16
  VMOVDQU64   permute64+0(SB), Z18
  VPERMQ      Z15, Z18, Z15                      // Z15 = low 8 hashes (64-bit)
  VPERMQ      Z16, Z18, Z16                      // Z16 = hi 8 ''
  VMOVDQA64   Z15, Z17                           // Z17, Z18 = temporaries for rotated hashes
  VMOVDQA64   Z16, Z18

  // load some immediates
  VONES(Z10)                       // Z10 = all ones
  VPSRLD        $28, Z10, Z6       // Z6 = 0xf
  VPXORQ        Z14, Z14, Z14      // Z14 = constant 0
  VPXORQ        Z7, Z7, Z7         // Z7 = shift count

  // load table[0] into Z8 and copy to Z9
  MOVQ          radixTree64_index(R13), R15
  VMOVDQU32     0(R15), Z8         // Z8 = initial indices for (hash&mask)
  VMOVDQA32     Z8, Z9             // Z9 = same

  // extract low 32-bit words from hashes
  VPMOVQD       Z15, Y24
  VPMOVQD       Z16, Y25
  VINSERTI32X8  $1, Y25, Z24, Z11  // Z11 = lo32 x 16 words
  VPRORQ        $32, Z15, Z26      // rotate 32 bits to get hi 32
  VPRORQ        $32, Z16, Z27
  VPMOVQD       Z26, Y26
  VPMOVQD       Z27, Y27
  VINSERTI32X8  $1, Y27, Z26, Z12  // Z12 = hi32 x 16 words

  // compute the first table offset
  // as a permutation into the correct
  // initial slot (since we have a sixteen-wide splay)
  VPANDD        Z11, Z6, Z11
  VPANDD        Z12, Z6, Z12
  VPERMD        Z8, Z11, Z8
  VPERMD        Z9, Z12, Z9
  JMP           loop_tail

  // inner loop: i = table[i][(hash>>shift)&mask]; shift += 4;
  // Z8 or Z9 = i, Z17 and Z18 are 64-bit hashes
  //
  // loop while i > 0; perform two searches simultaneously
  // with active lanes marked as K2 and K3 respectively
loop:
  // lo 32 bits x 16 -> Z24
  VPMOVQD       Z17, Y24
  VPMOVQD       Z18, Y25
  VINSERTI32X8  $1, Y25, Z24, Z24

  // hi 32 bits x 16 -> Z25
  VPSRLQ        $32, Z17, Z25
  VPSRLQ        $32, Z18, Z26
  VPMOVQD       Z25, Y25
  VPMOVQD       Z26, Y26
  VINSERTI32X8  $1, Y26, Z25, Z25

  VPANDD        Z24, Z6, Z24  // lo 8 &= mask
  VPANDD        Z25, Z6, Z25  // hi 8 &= mask
  VPSLLD        $4, Z8, Z11   // Z11 = index * 16 = ptr0
  VPSLLD        $4, Z9, Z12   // Z12 = index * 16 = ptr1
  VPADDD        Z11, Z24, Z11 // Z11 = (index * 16) + (hash & mask)
  VPADDD        Z12, Z25, Z12 // Z12 = (index * 16) + (hash & mask)
  KMOVW         K2, K4
  VPGATHERDD    0(R15)(Z11*4), K4, Z8 // Z8 = table[Z8][(hash&mask)]
  KMOVW         K3, K5
  VPGATHERDD    0(R15)(Z12*4), K5, Z9 // Z9 = table[Z9][(hash&mask)]
loop_tail:
  VPRORQ        $4, Z17, Z17        // chomp 4 bits of hash
  VPRORQ        $4, Z18, Z18
  VPCMPD        $1, Z8, Z14, K2, K2 // select lanes with index > 0
  VPCMPD        $1, Z9, Z14, K3, K3
  KORTESTW      K2, K3
  JNZ           loop                // loop while any indices are non-negative

  // determine if values[i] == hash in each lane
  VPTESTMD      Z8, Z8, K1, K2  // select index != 0
  VPTESTMD      Z9, Z9, K1, K3  //
  VPXORD        Z8, Z10, K2, Z8 // ^idx = value index
  VPXORD        Z9, Z10, K3, Z9

  MOVQ          radixTree64_values(R13), R15

  // load and test against hash0
  VEXTRACTI32X8 $1, Z8, Y24            // upper 8 indices
  KMOVB         K2, K5
  VPGATHERDQ    0(R15)(Y8*1), K5, Z26  // Z26 = first 8 hashes
  KSHIFTRW      $8, K2, K5
  VPGATHERDQ    0(R15)(Y24*1), K5, Z27 // Z27 = second 8 hashes
  VPCMPEQQ      Z15, Z26, K2, K5       // K5 = lo 8 match
  KMOVB         K5, K6
  KSHIFTRW      $8, K2, K6
  VPCMPEQQ      Z16, Z27, K6, K6       // K6 = hi 8 match
  KUNPCKBW      K5, K6, K2             // (K5||K6) -> K2 = found lanes

  // load and test against hash1 (same as above)
  KANDNQ        K3, K2, K3             // unset already found from K3
  VEXTRACTI32X8 $1, Z9, Y25            // lower 8 indices
  VPROLQ        $32, Z15, Z15          // first 8 rol 32
  VPROLQ        $32, Z16, Z16          // second 8 rol 32
  KMOVB         K3, K5
  VPGATHERDQ    0(R15)(Y9*1), K5, Z26
  KSHIFTRW      $8, K3, K5
  VPGATHERDQ    0(R15)(Y25*1), K5, Z27
  VPCMPEQQ      Z15, Z26, K3, K4
  KSHIFTRW      $8, K3, K6
  VPCMPEQQ      Z16, Z27, K6, K6
  KUNPCKBW      K4, K6, K3
  VMOVDQA32     Z9, K3, Z8             // Z8 = good offsets
  KORW          K2, K3, K1             // K1 = (matched hash0)|(matched hash1)
  KMOVW         K1, K2
  VPGATHERDD    8(R15)(Z8*1), K2, Z30   // load boxed offsets
  KMOVW         K1, K3
  VPGATHERDD    12(R15)(Z8*1), K3, Z31  // load boxed lengths
  VPADDD.BCST   bytecode_scratchoff(VIRT_BCPTR), Z30, K1, Z30
next:
  NEXT()

// Simple Aggregation Instructions
// -------------------------------

TEXT bcaggandk(SB), NOSPLIT|NOFRAME, $0
  MOVWQZX 0(VIRT_PCREG), DX
  MOVL    2(VIRT_PCREG), R8

  KMOVW K1, BX                         // BX <- Non-null lanes
  MOVWLZX 0(VIRT_VALUES)(DX*1), DX     // DX <- Boolean values
  ORB BX, 8(R10)(R8*1)                 // Mark this aggregation slot if we have non-null lanes
  ANDL BX, DX                          // DX <- Boolean values in non-null lanes

  // If BX != DX it means that at least one lane is active and that not all BOOLs
  // in active lanes are TRUE - this would result in FALSE if not already FALSE.
  XORL R15, R15
  CMPL BX, DX

  SETEQ R15
  ANDB R15, 0(R10)(R8*1)

  NEXT_ADVANCE(6)

TEXT bcaggork(SB), NOSPLIT|NOFRAME, $0
  MOVWQZX 0(VIRT_PCREG), DX
  MOVL    2(VIRT_PCREG), R8

  KMOVW K1, BX                         // BX <- Non-null lanes
  MOVWLZX 0(VIRT_VALUES)(DX*1), DX     // DX <- Boolean values
  ORB BX, 8(R10)(R8*1)                 // Mark this aggregation slot if we have non-null lanes

  // If BX & DX != 0 it means that at least one lane is active and that not all BOOLs
  // in active lanes are FALSE - this would result in TRUE if not already TRUE.
  XORL R15, R15
  ANDL BX, DX

  SETNE R15
  ORB R15, 0(R10)(R8*1)

  NEXT_ADVANCE(6)

TEXT bcaggsumf(SB), NOSPLIT|NOFRAME, $0
  MOVL          0(VIRT_PCREG), R8
  KSHIFTRW      $8, K1, K2
  VMOVDQA64.Z   Z2, K1, Z4
  VMOVDQA64.Z   Z3, K2, Z5

  VADDPD        Z4, Z5, Z5
  VEXTRACTF64X4 $VEXTRACT_IMM_HI, Z5, Y4
  VADDPD        Y4, Y5, Y5
  VEXTRACTF64X2 $VEXTRACT_IMM_HI, Y5, X4
  VADDPD        X4, X5, X5
  VSHUFPD       $1, X5, X5, X4
  VADDSD        X4, X5, X5

  VADDSD        0(R10)(R8*1), X5, X5
  VMOVSD        X5, 0(R10)(R8*1)

  KMOVW         K1, R15
  POPCNTL       R15, R15
  ADDQ          R15, 8(R10)(R8*1)
  NEXT_ADVANCE(4)

TEXT bcaggsumi(SB), NOSPLIT|NOFRAME, $0
  MOVL          0(VIRT_PCREG), R8
  KSHIFTRW      $8, K1, K2
  KMOVW         K1, R15
  VMOVQ         0(R10)(R8*1), X6

  VMOVDQA64.Z   Z2, K1, Z5
  VPADDQ        Z3, Z5, K2, Z5
  VEXTRACTI64X4 $VEXTRACT_IMM_HI, Z5, Y4
  VPADDQ        Y4, Y5, Y5
  VEXTRACTI64X2 $VEXTRACT_IMM_HI, Y5, X4

  POPCNTL       R15, R15

  VPADDQ        X4, X5, X5
  VPSHUFD       $SHUFFLE_IMM_4x2b(1, 0, 3, 2), X5, X4
  VPADDQ        X4, X5, X5
  VPADDQ        X6, X5, X5

  VMOVQ         X5, 0(R10)(R8*1)
  ADDQ          R15, 8(R10)(R8*1)
  NEXT_ADVANCE(4)

TEXT bcaggminf(SB), NOSPLIT|NOFRAME, $0
  MOVL          0(VIRT_PCREG), R8
  VBROADCASTSD  CONSTF64_POSITIVE_INF(), Z5
  KSHIFTRW      $8, K1, K2
  KMOVW         K1, R15

  VMINPD        Z5, Z2, K1, Z5
  VMINPD        Z5, Z3, K2, Z5
  VEXTRACTF64X4 $VEXTRACT_IMM_HI, Z5, Y4
  VMINPD        Y4, Y5, Y5
  VEXTRACTF64X2 $VEXTRACT_IMM_HI, Y5, X4

  POPCNTL       R15, R15

  VMINPD        X4, X5, X5
  VSHUFPD       $1, X5, X5, X4
  VMINSD        X4, X5, X5

  VMINSD        0(R10)(R8*1), X5, X5
  VMOVSD        X5, 0(R10)(R8*1)
  ADDQ          R15, 8(R10)(R8*1)
  NEXT_ADVANCE(4)

TEXT bcaggmini(SB), NOSPLIT|NOFRAME, $0
  MOVL          0(VIRT_PCREG), R8
  VPBROADCASTQ  CONSTQ_0x7FFFFFFFFFFFFFFF(), Z5
  KSHIFTRW      $8, K1, K2
  KMOVW         K1, R15
  VMOVQ         0(R10)(R8*1), X6

  VPMINSQ       Z5, Z2, K1, Z5
  VPMINSQ       Z5, Z3, K2, Z5
  VEXTRACTI64X4 $VEXTRACT_IMM_HI, Z5, Y4
  VPMINSQ       Y4, Y5, Y5
  VEXTRACTI64X2 $VEXTRACT_IMM_HI, Y5, X4

  POPCNTL       R15, R15

  VPMINSQ       X4, X5, X5
  VPSHUFD       $SHUFFLE_IMM_4x2b(1, 0, 3, 2), X5, X4
  VPMINSQ       X4, X5, X5
  VPMINSQ       X6, X5, X5

  VMOVQ         X5, 0(R10)(R8*1)
  ADDQ          R15, 8(R10)(R8*1)
  NEXT_ADVANCE(4)

TEXT bcaggmaxf(SB), NOSPLIT|NOFRAME, $0
  MOVL          0(VIRT_PCREG), R8
  VBROADCASTSD  CONSTF64_NEGATIVE_INF(), Z5
  KSHIFTRW      $8, K1, K2
  KMOVW         K1, R15

  VMAXPD        Z5, Z2, K1, Z5
  VMAXPD        Z5, Z3, K2, Z5
  VEXTRACTF64X4 $VEXTRACT_IMM_HI, Z5, Y4
  VMAXPD        Y4, Y5, Y5
  VEXTRACTF64X2 $VEXTRACT_IMM_HI, Y5, X4

  POPCNTL       R15, R15

  VMAXPD        X4, X5, X5
  VSHUFPD       $1, X5, X5, X4
  VMAXSD        X4, X5, X5

  VMAXSD        0(R10)(R8*1), X5, X5
  VMOVSD        X5, 0(R10)(R8*1)
  ADDQ          R15, 8(R10)(R8*1)
  NEXT_ADVANCE(4)

TEXT bcaggmaxi(SB), NOSPLIT|NOFRAME, $0
  MOVL          0(VIRT_PCREG), R8
  VPBROADCASTQ  CONSTQ_0x8000000000000000(), Z5
  KSHIFTRW      $8, K1, K2
  KMOVW         K1, R15

  VMOVQ         0(R10)(R8*1), X6
  VPMAXSQ       Z5, Z2, K1, Z5
  VPMAXSQ       Z5, Z3, K2, Z5
  VEXTRACTI64X4 $VEXTRACT_IMM_HI, Z5, Y4
  VPMAXSQ       Y4, Y5, Y5
  VEXTRACTI64X2 $VEXTRACT_IMM_HI, Y5, X4

  POPCNTL       R15, R15

  VPMAXSQ       X4, X5, X5
  VPSHUFD       $SHUFFLE_IMM_4x2b(1, 0, 3, 2), X5, X4
  VPMAXSQ       X4, X5, X5
  VPMAXSQ       X6, X5, X5

  VMOVQ         X5, 0(R10)(R8*1)
  ADDQ          R15, 8(R10)(R8*1)
  NEXT_ADVANCE(4)

TEXT bcaggandi(SB), NOSPLIT|NOFRAME, $0
  MOVL          0(VIRT_PCREG), R8
  VPBROADCASTQ  CONSTQ_0xFFFFFFFFFFFFFFFF(), Z5
  KSHIFTRW      $8, K1, K2
  KMOVW         K1, R15

  VMOVQ         0(R10)(R8*1), X6
  VPANDQ        Z5, Z2, K1, Z5
  VPANDQ        Z5, Z3, K2, Z5
  VEXTRACTI64X4 $VEXTRACT_IMM_HI, Z5, Y4
  VPANDQ        Y4, Y5, Y5
  VEXTRACTI64X2 $VEXTRACT_IMM_HI, Y5, X4

  POPCNTL       R15, R15

  VPANDQ        X4, X5, X5
  VPSHUFD       $SHUFFLE_IMM_4x2b(1, 0, 3, 2), X5, X4
  VPANDQ        X4, X5, X5
  VPANDQ        X6, X5, X5

  VMOVQ         X5, 0(R10)(R8*1)
  ADDQ          R15, 8(R10)(R8*1)
  NEXT_ADVANCE(4)

TEXT bcaggori(SB), NOSPLIT|NOFRAME, $0
  MOVL          0(VIRT_PCREG), R8
  KSHIFTRW      $8, K1, K2
  KMOVW         K1, R15

  VMOVQ         0(R10)(R8*1), X6
  VMOVDQA64.Z   Z2, K1, Z5
  VPORQ         Z5, Z3, K2, Z5
  VEXTRACTI64X4 $VEXTRACT_IMM_HI, Z5, Y4
  VPORQ         Y4, Y5, Y5
  VEXTRACTI64X2 $VEXTRACT_IMM_HI, Y5, X4

  POPCNTL       R15, R15

  VPORQ         X4, X5, X5
  VPSHUFD       $SHUFFLE_IMM_4x2b(1, 0, 3, 2), X5, X4
  VPORQ         X4, X5, X5
  VPORQ         X6, X5, X5

  VMOVQ         X5, 0(R10)(R8*1)
  ADDQ          R15, 8(R10)(R8*1)
  NEXT_ADVANCE(4)

TEXT bcaggxori(SB), NOSPLIT|NOFRAME, $0
  MOVL          0(VIRT_PCREG), R8
  KSHIFTRW      $8, K1, K2
  KMOVW         K1, R15

  VMOVQ         0(R10)(R8*1), X6
  VMOVDQA64.Z   Z2, K1, Z5
  VPXORQ        Z5, Z3, K2, Z5
  VEXTRACTI64X4 $VEXTRACT_IMM_HI, Z5, Y4
  VPXORQ        Y4, Y5, Y5
  VEXTRACTI64X2 $VEXTRACT_IMM_HI, Y5, X4

  POPCNTL       R15, R15

  VPXORQ        X4, X5, X5
  VPSHUFD       $SHUFFLE_IMM_4x2b(1, 0, 3, 2), X5, X4
  VPXORQ        X4, X5, X5
  VPXORQ        X6, X5, X5

  VMOVQ         X5, 0(R10)(R8*1)
  ADDQ          R15, 8(R10)(R8*1)
  NEXT_ADVANCE(4)

TEXT bcaggcount(SB), NOSPLIT|NOFRAME, $0
  KMOVW         K1, R15
  MOVL          0(VIRT_PCREG), R8
  POPCNTQ       R15, R15
  ADDQ          R15, 0(R10)(R8*1)
  NEXT_ADVANCE(4)

// Slot Aggregation Instructions
// -----------------------------

// In each bytecode_bucket(), aggregate the value Z2:Z3 (float or int)

// take the value of the H register
// and locate the entries associated with
// each hash (for each lane where K1!=0);
//
// returns early if it cannot locate all of K1
TEXT bcaggbucket(SB), NOSPLIT|NOFRAME, $0
  MOVWQZX 0(VIRT_PCREG), R8
  ADDQ    $2, VIRT_PCREG
  KTESTW  K1, K1
  JZ      next
  ADDQ    bytecode_hashmem(VIRT_BCPTR), R8 // R8 = pointer to input hash slot
  KMOVW   K1, K2
  KMOVW   K1, K3

  // load the low 64 bits of the sixteen hashes;
  // we should have Z15 = first 8 lo 64, Z16 = second 8 lo 64
  VMOVDQU64   0(R8), Z15
  VMOVDQU64   64(R8), Z16
  VPUNPCKLQDQ Z16, Z15, Z15
  VMOVDQU64   128(R8), Z16
  VMOVDQU64   192(R8), Z17
  VPUNPCKLQDQ Z17, Z16, Z16
  VMOVDQU64   permute64+0(SB), Z18
  VPERMQ      Z15, Z18, Z15                      // Z15 = low 8 hashes (64-bit)
  VPERMQ      Z16, Z18, Z16                      // Z16 = hi 8 ''
  VMOVDQA64   Z15, Z17                           // Z17, Z18 = temporaries for rotated hashes
  VMOVDQA64   Z16, Z18

  // load some immediates
  VONES(Z10)                       // Z10 = all ones
  VPSRLD        $28, Z10, Z6       // Z6 = 0xf
  VPXORQ        Z14, Z14, Z14      // Z14 = constant 0
  VPXORQ        Z7, Z7, Z7         // Z7 = shift count

  // load table[0] into Z8 and copy to Z9
  MOVQ          radixTree64_index(R10), R15
  VMOVDQU32     0(R15), Z8         // Z8 = initial indices for (hash&mask)
  VMOVDQA32     Z8, Z9             // Z9 = same

  // extract low 32-bit words from hashes
  VPMOVQD       Z15, Y24
  VPMOVQD       Z16, Y25
  VINSERTI32X8  $1, Y25, Z24, Z11  // Z11 = lo32 x 16 words
  VPRORQ        $32, Z15, Z26      // rotate 32 bits to get hi 32
  VPRORQ        $32, Z16, Z27
  VPMOVQD       Z26, Y26
  VPMOVQD       Z27, Y27
  VINSERTI32X8  $1, Y27, Z26, Z12  // Z12 = hi32 x 16 words

  // compute the first table offset
  // as a permutation into the correct
  // initial slot (since we have a sixteen-wide splay)
  VPANDD        Z11, Z6, Z11
  VPANDD        Z12, Z6, Z12
  VPERMD        Z8, Z11, Z8
  VPERMD        Z9, Z12, Z9
  JMP           loop_tail

  // inner loop: i = table[i][(hash>>shift)&mask]; shift += 4;
  // Z8 or Z9 = i, Z17 and Z18 are 64-bit hashes
  //
  // loop while i > 0; perform two searches simultaneously
  // with active lanes marked as K2 and K3 respectively
loop:
  // lo 32 bits x 16 -> Z24
  VPMOVQD       Z17, Y24
  VPMOVQD       Z18, Y25
  VINSERTI32X8  $1, Y25, Z24, Z24

  // hi 32 bits x 16 -> Z25
  VPSRLQ        $32, Z17, Z25
  VPSRLQ        $32, Z18, Z26
  VPMOVQD       Z25, Y25
  VPMOVQD       Z26, Y26
  VINSERTI32X8  $1, Y26, Z25, Z25

  VPANDD        Z24, Z6, Z24  // lo 8 &= mask
  VPANDD        Z25, Z6, Z25  // hi 8 &= mask
  VPSLLD        $4, Z8, Z11   // Z11 = index * 16 = ptr0
  VPSLLD        $4, Z9, Z12   // Z12 = index * 16 = ptr1
  VPADDD        Z11, Z24, Z11 // Z11 = (index * 16) + (hash & mask)
  VPADDD        Z12, Z25, Z12 // Z12 = (index * 16) + (hash & mask)
  KMOVW         K2, K4
  VPGATHERDD    0(R15)(Z11*4), K4, Z8 // Z8 = table[Z8][(hash&mask)]
  KMOVW         K3, K5
  VPGATHERDD    0(R15)(Z12*4), K5, Z9 // Z9 = table[Z9][(hash&mask)]
loop_tail:
  VPRORQ        $4, Z17, Z17        // chomp 4 bits of hash
  VPRORQ        $4, Z18, Z18
  VPCMPD        $1, Z8, Z14, K2, K2 // select lanes with index > 0
  VPCMPD        $1, Z9, Z14, K3, K3
  KORTESTW      K2, K3
  JNZ           loop                // loop while any indices are non-negative

  // determine if values[i] == hash in each lane
  VPTESTMD      Z8, Z8, K1, K2  // select index != 0
  VPTESTMD      Z9, Z9, K1, K3  //
  VPXORD        Z8, Z10, K2, Z8 // ^idx = value index
  VPXORD        Z9, Z10, K3, Z9

  MOVQ          radixTree64_values(R10), R15

  // load and test against hash0
  VEXTRACTI32X8 $1, Z8, Y24            // upper 8 indices
  KMOVB         K2, K5
  VPGATHERDQ    0(R15)(Y8*1), K5, Z26  // Z26 = first 8 hashes
  KSHIFTRW      $8, K2, K5
  VPGATHERDQ    0(R15)(Y24*1), K5, Z27 // Z27 = second 8 hashes
  VPCMPEQQ      Z15, Z26, K2, K5       // K5 = lo 8 match
  KSHIFTRW      $8, K2, K6
  VPCMPEQQ      Z16, Z27, K6, K6       // K6 = hi 8 match
  KUNPCKBW      K5, K6, K2             // (K5||K6) -> K2 = found lanes
  VMOVDQA32.Z   Z8, K2, Z13            // Z13 = ret

  // load and test against hash1 (same as above)
  VEXTRACTI32X8 $1, Z9, Y25            // lower 8 indices
  VPROLQ        $32, Z15, Z15          // first 8 rol 32
  VPROLQ        $32, Z16, Z16          // second 8 rol 32
  KANDNQ        K3, K2, K3             // unset already found from K3
  KMOVB         K3, K5
  VPGATHERDQ    0(R15)(Y9*1), K5, Z26
  KSHIFTRW      $8, K3, K5
  VPGATHERDQ    0(R15)(Y25*1), K5, Z27
  VPCMPEQQ      Z15, Z26, K3, K4
  KSHIFTRW      $8, K3, K6
  VPCMPEQQ      Z16, Z27, K6, K6
  KUNPCKBW      K4, K6, K3
  VMOVDQA32     Z9, K3, Z13            // add matched offsets to ret
  KORW          K2, K3, K2             // K2 = found

  // now test that we found everything we wanted
  KXORW         K2, K1, K2         // K1^K2 = found xor wanted
  KTESTW        K2, K2             // (K1^K2)!=0 -> found != wanted
  JNZ           early_ret          // we didn't locate entries!
next:
  // perform a sanity bounds-check on the returned offsets;
  // each offset should be <= len(tree.values)
  VPCMPD.BCST   $VPCMP_IMM_GT, radixTree64_values+8(R10), Z13, K1, K4
  KTESTW        K4, K4
  JNZ           bad_radix_bucket
  VMOVDQU32     Z13, bytecode_bucket(VIRT_BCPTR)
  NEXT()
early_ret:
  // set bytecode.err to NeedRadix
  // and bytecode.errinfo to the hash slot
  MOVL    $const_bcerrNeedRadix, bytecode_err(VIRT_BCPTR)
  MOVWQZX -2(VIRT_PCREG), R8
  MOVQ    R8, bytecode_errinfo(VIRT_BCPTR)
  RET_ABORT()
bad_radix_bucket:
  // set bytecode.err to TreeCorrupt
  // and set bytecode.errpc to this pc
  MOVL    $const_bcerrTreeCorrupt, bytecode_err(VIRT_BCPTR)
  LEAQ    -2(VIRT_PCREG), VIRT_PCREG
  SUBQ    bytecode_compiled(VIRT_BCPTR), VIRT_PCREG // get relative position
  MOVL    VIRT_PCREG, bytecode_errpc(VIRT_BCPTR)
  RET_ABORT()

// All aggregate operations except AVG aggregate the value and then mark
// slot+1, so we can decide whether the result of the aggregation should
// be the aggregated value or NULL - in other words it basically describes
// whether there was at least one aggregation.
//
// Expects 64-bit sources in Z4 and Z5.
#define BC_AGGREGATE_SLOT_MARK_OP(SlotOffset, Instruction)                    \
  /* Load buckets as early as possible so we can resolve conflicts early,  */ \
  /* because VPCONFLICTD has a very high latency (higher than VPCONFLICTQ).*/ \
  VPBROADCASTD CONSTD_0xFFFFFFFF(), Z6                                        \
  VMOVDQU32 bytecode_bucket(VIRT_BCPTR), K1, Z6                               \
  VPCONFLICTD.Z Z6, K1, Z11                                                   \
  VEXTRACTI32X8 $1, Z6, Y7                                                    \
                                                                              \
  /* Load the aggregation data pointer. */                                    \
  MOVL SlotOffset(VIRT_PCREG), R15                                            \
  ADDQ $8, R15                                                                \
  ADDQ radixTree64_values(R10), R15                                           \
                                                                              \
  /* Mark all values that we are gonna update. */                             \
  VPBROADCASTD CONSTD_1(), Z10                                                \
  KMOVW K1, K2                                                                \
  VPSCATTERDD Z10, K2, 8(R15)(Z6*1)                                           \
                                                                              \
  /* Gather the first low 8 values, which are safe to gather at this point. */\
  KMOVB K1, K2                                                                \
  VPXORQ X14, X14, X14                                                        \
  VGATHERDPD 0(R15)(Y6*1), K2, Z14                                            \
                                                                              \
  /* Skip the loop if there are no conflicts. */                              \
  VPANDD CONST_GET_PTR(aggregate_conflictdq_mask, 0), Z11, Z11                \
  VPTESTMD Z11, Z11, K1, K2                                                   \
  KTESTW K2, K2                                                               \
  JZ resolved                                                                 \
                                                                              \
  /* Calculate a predicate for VPERMQ so we can swizzle sources. */           \
  VMOVDQU32 CONST_GET_PTR(aggregate_conflictdq_norm, 0), Z10                  \
  VPLZCNTD Z11, Z12                                                           \
  VPSUBD Z12, Z10, Z12                                                        \
  VEXTRACTI32X8 $1, Z12, Y13                                                  \
  VPMOVZXDQ Y12, Z12                                                          \
  VPMOVZXDQ Y13, Z13                                                          \
                                                                              \
loop:                                                                         \
  /* Z10 - broadcasted conflicting lanes. */                                  \
  VPBROADCASTMW2D K2, Z10                                                     \
                                                                              \
  /* Swizzle sources so we can aggregate conflicting lanes. */                \
  VPERMQ Z4, Z12, Z8                                                          \
  VPERMQ Z5, Z13, Z9                                                          \
                                                                              \
  /* K4/K5 - resolved conflicts in this iteration. */                         \
  VPTESTNMD Z11, Z10, K2, K4                                                  \
  KSHIFTRW $8, K4, K5                                                         \
                                                                              \
  /* K2 - remaining conflicts (to be resolved in the next iteration.) */      \
  KANDNW K2, K4, K2                                                           \
                                                                              \
  /* Aggregate conflicting lanes and mask out lanes we have resolved. */      \
  Instruction Z8, Z4, K4, Z4                                                  \
  Instruction Z9, Z5, K5, Z5                                                  \
                                                                              \
  /* Continue looping if there are still conflicts. */                        \
  KTESTW K2, K2                                                               \
  JNZ loop                                                                    \
                                                                              \
resolved:                                                                     \
  /* Finally, aggregate non-conflicting sources into buckets. */              \
  Instruction Z4, Z14, K1, Z14                                                \
  KMOVB K1, K2                                                                \
  VSCATTERDPD Z14, K2, 0(R15)(Y6*1)                                           \
                                                                              \
  KSHIFTRW $8, K1, K2                                                         \
  VPXORQ X14, X14, X14                                                        \
  VGATHERDPD 0(R15)(Y7*1), K2, Z14                                            \
  KSHIFTRW $8, K1, K2                                                         \
  Instruction Z5, Z14, K2, Z14                                                \
  VSCATTERDPD Z14, K2, 0(R15)(Y7*1)                                           \
                                                                              \
next:

// This macro is used to implement AVG, which requires more than just a mark.
//
// In order to calculate the average we aggregate the value and also a count
// of values aggregated, this count will then be used to calculate the final
// average and also to decide whether the result is NULL or non-NULL. If the
// COUNT is zero, the result of the aggregation is NULL.
//
// Expects 64-bit sources in Z4 and Z5.
#define BC_AGGREGATE_SLOT_COUNT_OP(SlotOffset, Instruction)                   \
  /* Load buckets as early as possible so we can resolve conflicts early,  */ \
  /* because VPCONFLICTD has a very high latency (higher than VPCONFLICTQ).*/ \
  VPBROADCASTD CONSTD_0xFFFFFFFF(), Z6                                        \
  VMOVDQU32 bytecode_bucket(VIRT_BCPTR), K1, Z6                               \
  VPCONFLICTD.Z Z6, K1, Z11                                                   \
  VEXTRACTI32X8 $1, Z6, Y7                                                    \
                                                                              \
  /* Load the aggregation data pointer. */                                    \
  MOVL  SlotOffset(VIRT_PCREG), R15                                           \
  ADDQ $8, R15                                                                \
  ADDQ radixTree64_values(R10), R15                                           \
                                                                              \
  /* Gather the first low 8 values, which are safe to gather at this point. */\
  KMOVB K1, K2                                                                \
  VPXORQ X14, X14, X14                                                        \
  VGATHERDPD 0(R15)(Y6*1), K2, Z14                                            \
                                                                              \
  /* Initial COUNT values - conflicts will be resolved later, if any... */    \
  VPBROADCASTD CONSTD_1(), Z15                                                \
                                                                              \
  /* Skip the conflict resolution if there are no conflicts. */               \
  VPANDD CONST_GET_PTR(aggregate_conflictdq_mask, 0), Z11, Z11                \
  VPTESTMD Z11, Z11, K1, K2                                                   \
  KTESTW K2, K2                                                               \
  JZ resolved                                                                 \
                                                                              \
  /* Calculate a predicate for VPERMQ so we can swizzle sources. */           \
  VMOVDQU32 CONST_GET_PTR(aggregate_conflictdq_norm, 0), Z10                  \
  VPLZCNTD Z11, Z12                                                           \
  VPSUBD Z12, Z10, Z12                                                        \
  VEXTRACTI32X8 $1, Z12, Y13                                                  \
  VPMOVZXDQ Y12, Z12                                                          \
  VPMOVZXDQ Y13, Z13                                                          \
                                                                              \
  /* Z16 - ones, for incrementing COUNTs of conflicting lanes. */             \
  VMOVDQA32 Z15, Z16                                                          \
                                                                              \
loop:                                                                         \
  /* Z10 - broadcasted conflicting lanes. */                                  \
  VPBROADCASTMW2D K2, Z10                                                     \
                                                                              \
  /* Swizzle sources so we can aggregate conflicting lanes. */                \
  VPERMQ Z4, Z12, Z8                                                          \
  VPERMQ Z5, Z13, Z9                                                          \
                                                                              \
  /* K4/K5 - resolved conflicts in this iteration. */                         \
  VPTESTNMD Z11, Z10, K2, K4                                                  \
  KSHIFTRW $8, K4, K5                                                         \
                                                                              \
  /* Adds COUNTs of conflicting lanes iteratively. */                         \
  VPADDD Z16, Z15, K2, Z15                                                    \
                                                                              \
  /* K2 - remaining conflicts (to be resolved in the next iteration.) */      \
  KANDNW K2, K4, K2                                                           \
                                                                              \
  /* Aggregate conflicting lanes and mask out lanes we have resolved. */      \
  Instruction Z8, Z4, K4, Z4                                                  \
  Instruction Z9, Z5, K5, Z5                                                  \
                                                                              \
  /* Continue looping if there are still conflicts. */                        \
  KTESTW K2, K2                                                               \
  JNZ loop                                                                    \
                                                                              \
resolved:                                                                     \
  /* Gather first 8 COUNTs. */                                                \
  VPXORQ X13, X13, X13                                                        \
  KMOVB K1, K2                                                                \
  VPGATHERDQ 8(R15)(Y6*1), K2, Z13                                            \
                                                                              \
  /* Convert COUNT aggregates from DWORD to QWORD, so we can add them. */     \
  VEXTRACTI32X8 $1, Z15, Y16                                                  \
  VPMOVZXDQ Y15, Z15                                                          \
  VPMOVZXDQ Y16, Z16                                                          \
                                                                              \
  /* Aggregate non-conflicting values and COUNTs into buckets (low). */       \
  Instruction Z4, Z14, K1, Z14                                                \
  VPADDQ Z15, Z13, K1, Z13                                                    \
  KMOVB K1, K2                                                                \
  VSCATTERDPD Z14, K2, 0(R15)(Y6*1)                                           \
  KMOVB K1, K2                                                                \
  VPSCATTERDQ Z13, K2, 8(R15)(Y6*1)                                           \
                                                                              \
  /* Aggregate non-conflicting values and COUNTs into buckets (high). */      \
  VPXORQ X14, X14, X14                                                        \
  VPXORQ X13, X13, X13                                                        \
  KSHIFTRW $8, K1, K2                                                         \
  VGATHERDPD 0(R15)(Y7*1), K2, Z14                                            \
  KSHIFTRW $8, K1, K2                                                         \
  VPGATHERDQ 8(R15)(Y7*1), K2, Z13                                            \
  KSHIFTRW $8, K1, K2                                                         \
  Instruction Z5, Z14, K2, Z14                                                \
  VPADDQ Z16, Z13, K2, Z13                                                    \
  VSCATTERDPD Z14, K2, 0(R15)(Y7*1)                                           \
  KSHIFTRW $8, K1, K2                                                         \
  VPSCATTERDQ Z13, K2, 8(R15)(Y7*1)                                           \
                                                                              \
next:

TEXT bcaggslotandk(SB), NOSPLIT|NOFRAME, $0
  MOVWQZX 4(VIRT_PCREG), R8
  KMOVW 0(VIRT_VALUES)(R8*1), K4
  KSHIFTRW $8, K4, K5

  VPMOVM2Q K4, Z4
  VPMOVM2Q K5, Z5

  BC_AGGREGATE_SLOT_MARK_OP(0, VPANDQ)
  NEXT_ADVANCE(6)

TEXT bcaggslotork(SB), NOSPLIT|NOFRAME, $0
  MOVWQZX 4(VIRT_PCREG), R8
  KMOVW 0(VIRT_VALUES)(R8*1), K4
  KSHIFTRW $8, K4, K5

  VPMOVM2Q K4, Z4
  VPMOVM2Q K5, Z5

  BC_AGGREGATE_SLOT_MARK_OP(0, VPORQ)
  NEXT_ADVANCE(6)

TEXT bcaggslotaddf(SB), NOSPLIT|NOFRAME, $0
  VMOVDQA64 Z2, Z4
  VMOVDQA64 Z3, Z5
  BC_AGGREGATE_SLOT_MARK_OP(0, VADDPD)
  NEXT_ADVANCE(4)

TEXT bcaggslotaddi(SB), NOSPLIT|NOFRAME, $0
  VMOVDQA64 Z2, Z4
  VMOVDQA64 Z3, Z5
  BC_AGGREGATE_SLOT_MARK_OP(0, VPADDQ)
  NEXT_ADVANCE(4)

TEXT bcaggslotavgf(SB), NOSPLIT|NOFRAME, $0
  VMOVDQA64 Z2, Z4
  VMOVDQA64 Z3, Z5
  BC_AGGREGATE_SLOT_COUNT_OP(0, VADDPD)
  NEXT_ADVANCE(4)

TEXT bcaggslotavgi(SB), NOSPLIT|NOFRAME, $0
  VMOVDQA64 Z2, Z4
  VMOVDQA64 Z3, Z5
  BC_AGGREGATE_SLOT_COUNT_OP(0, VPADDQ)
  NEXT_ADVANCE(4)

TEXT bcaggslotminf(SB), NOSPLIT|NOFRAME, $0
  VMOVDQA64 Z2, Z4
  VMOVDQA64 Z3, Z5
  BC_AGGREGATE_SLOT_MARK_OP(0, VMINPD)
  NEXT_ADVANCE(4)

TEXT bcaggslotmini(SB), NOSPLIT|NOFRAME, $0
  VMOVDQA64 Z2, Z4
  VMOVDQA64 Z3, Z5
  BC_AGGREGATE_SLOT_MARK_OP(0, VPMINSQ)
  NEXT_ADVANCE(4)

TEXT bcaggslotmaxf(SB), NOSPLIT|NOFRAME, $0
  VMOVDQA64 Z2, Z4
  VMOVDQA64 Z3, Z5
  BC_AGGREGATE_SLOT_MARK_OP(0, VMAXPD)
  NEXT_ADVANCE(4)

TEXT bcaggslotmaxi(SB), NOSPLIT|NOFRAME, $0
  VMOVDQA64 Z2, Z4
  VMOVDQA64 Z3, Z5
  BC_AGGREGATE_SLOT_MARK_OP(0, VPMAXSQ)
  NEXT_ADVANCE(4)

TEXT bcaggslotandi(SB), NOSPLIT|NOFRAME, $0
  VMOVDQA64 Z2, Z4
  VMOVDQA64 Z3, Z5
  BC_AGGREGATE_SLOT_MARK_OP(0, VPANDQ)
  NEXT_ADVANCE(4)

TEXT bcaggslotori(SB), NOSPLIT|NOFRAME, $0
  VMOVDQA64 Z2, Z4
  VMOVDQA64 Z3, Z5
  BC_AGGREGATE_SLOT_MARK_OP(0, VPORQ)
  NEXT_ADVANCE(4)

TEXT bcaggslotxori(SB), NOSPLIT|NOFRAME, $0
  VMOVDQA64 Z2, Z4
  VMOVDQA64 Z3, Z5
  BC_AGGREGATE_SLOT_MARK_OP(0, VPXORQ)
  NEXT_ADVANCE(4)

// COUNT is a special aggregation function that just counts active lanes stored
// in K1. This is the simplest aggregation, which only requres a basic conflict
// resolution that doesn't require to loop over conflicting lanes.
TEXT bcaggslotcount(SB), NOSPLIT|NOFRAME, $0
  // Load buckets as early as possible so we can resolve conflicts early,
  // because VPCONFLICTD has a very high latency (higher than VPCONFLICTQ).
  VPBROADCASTD CONSTD_0xFFFFFFFF(), Z6
  VMOVDQU32 bytecode_bucket(VIRT_BCPTR), K1, Z6
  VPCONFLICTD.Z Z6, K1, Z8

  // Load the aggregation data pointer and prepare high 8 element offsets.
  MOVL 0(VIRT_PCREG), R15
  ADDQ radixTree64_values(R10), R15
  VEXTRACTI32X8 $1, Z6, Y7

  // Z4/Z5 <- gather all 16 lanes representing the current COUNT.
  KMOVB K1, K2
  KSHIFTRW $8, K1, K3
  VPGATHERDQ 8(R15)(Y6*1), K2, Z4
  VPGATHERDQ 8(R15)(Y7*1), K3, Z5

  // Now resolve COUNT conflicts. We know that the most significant element
  // is stored last by scatters, and we know, that conflict detection goes
  // from the most significant to least significant, so the conflicts are
  // resolved in the correct order respecting scatter.
  //
  // NOTE: It would be easier to use VPOPCNTD, but unfortunately it's not
  // available on all machines, so we do the popcount with VPSHUFB, which
  // is like 10 instructions longer, but we can still do it.
  //
  // VPMADDUBSW is used to horizontally add two bytes, Z10 is a vector of
  // 0x0101 values, thus multiplying all bytes with 1, and summing them.
  //
  // NOTE: This chain can be replaced by `VPOPCNTD Z8, Z8`
  VBROADCASTI32X4 CONST_GET_PTR(popcnt_nibble, 0), Z10
  VPSRLD $4, Z8, Z9
  VPANDD.BCST CONSTD_0x0F0F0F0F(), Z8, Z8
  VPANDD.BCST CONSTD_0x0F0F0F0F(), Z9, Z9
  VPSHUFB Z8, Z10, Z8
  VPSHUFB Z9, Z10, Z9
  VPBROADCASTD CONSTD_0x01010101(), Z10
  VPADDD Z9, Z8, Z8
  VPMADDUBSW Z10, Z8, Z8

  // Aggregate and store the new COUNT of elements.
  VPADDD.BCST CONSTD_1(), Z8, Z8
  KMOVB K1, K2
  KSHIFTRW $8, K1, K3
  VEXTRACTI32X8 $1, Z8, Y9
  VPMOVZXDQ Y8, Z8
  VPMOVZXDQ Y9, Z9
  VPADDQ Z8, Z4, Z4
  VPADDQ Z9, Z5, Z5
  VPSCATTERDQ Z4, K2, 8(R15)(Y6*1)
  VPSCATTERDQ Z5, K3, 8(R15)(Y7*1)

  NEXT_ADVANCE(4)

// Uncategorized Instructions
// --------------------------

// take two immediate offsets into the scratch buffer and broadcast them into registers
TEXT bclitref(SB), NOSPLIT|NOFRAME, $0
  VPBROADCASTD  0(VIRT_PCREG), Z30 // offset in scratch
  VPBROADCASTD  4(VIRT_PCREG), Z31 // length
  VPADDD.BCST   bytecode_scratchoff(VIRT_BCPTR), Z30, Z30 // offset += displ
  ADDQ          $8, VIRT_PCREG
  NEXT()

TEXT bcauxval(SB), NOSPLIT|NOFRAME, $0
  MOVWQZX    0(VIRT_PCREG), R8
  IMULQ      $24, R8
  MOVQ       bytecode_auxvals+0(VIRT_BCPTR), R15
  MOVQ       0(R15)(R8*1), R15
  MOVQ       bytecode_auxpos(VIRT_BCPTR), R8
  LEAQ       0(R15)(R8*8), R15 // skip entries in group
  VMOVDQU32  0(R15), Z8   // Z8 = first 8, packed
  VPMOVQD    Z8, Y10      // Y10 = first 8 offsets
  VPSRLQ     $32, Z8, Z8  // Z8 = first 8 >>= 32
  VPMOVQD    Z8, Y11      // Y11 = first 8 lengths
  VMOVDQU32  64(R15), Z9  // Z9 = second 8, packed
  VPMOVQD    Z9, Y12      // Y12 = second 8 offsets
  VPSRLQ     $32, Z9, Z9  // Z9 = second 8 >>= 32
  VPMOVQD    Z9, Y13      // Y13 = second 8 lengths

  VINSERTI32X8 $1, Y12, Z10, Z30 // concatenate offsets
  VINSERTI32X8 $1, Y13, Z11, Z31 // concatenate lengths
  VPTESTMD     Z31, Z31, K1      // zero-length values -> MISSING
  NEXT_ADVANCE(2)

// take the list slice in Z2:Z3
// and put the first object slice in Z30:Z31,
// then update Z2:Z3 to point to the rest of
// the list
TEXT bcsplit(SB), NOSPLIT|NOFRAME, $0
  VPTESTMD      Z3, Z3, K1, K1           // only keep lanes with len != 0
  KTESTW        K1, K1
  JZ            next
  KMOVW         K1, K2
  VPBROADCASTD  CONSTD_0x0F(), Z27         // Z27 = 0x0F
  VPBROADCASTD  CONSTD_1(), Z21            // Z21 = 1
  VPGATHERDD    0(SI)(Z2*1), K2, Z26       // Z26 = first 4 bytes
  VPANDD        Z26, Z27, Z25              // Z25 = first 4 & 0x0f = int size
  VPSRLD        $4, Z26, Z26               // first 4 words >>= 4
  VPANDD        Z27, Z26, Z24              // Z24 = (word >> 4) & 0xf = descriptor tag
  VPCMPEQD      Z21, Z24, K1, K4           // K4 = descriptor=1 (boolean)
  VPCMPEQD      Z25, Z27, K1, K2           // K2 = field is null
  KORW          K2, K4, K2                 // K2 = field is null or boolean (must be 1 byte)
  KANDNW        K1, K2, K3                 // K3 = field is active and not 1-byte-sized
  VPCMPEQD.BCST CONSTD_0x0E(), Z25, K1, K2 // K2 = descriptor=e (varint-sized)
  KANDNW        K3, K2, K3                 // K3 = non-varint-sized objects
  VMOVDQA32.Z   Z25, K3, Z22               // Z22 = length = first4&0xf for non-varint-size
  VPADDD        Z21, Z22, K1, Z22          // Z22++ for all lanes (for descriptor byte)
  VPCMPEQD      Z24, Z21, K1, K4           // K4 = descriptor tag == 1
  VMOVDQA32     Z21, K4, Z22               // Z22 = 1 for booleans independent of size bits
  // decode up to 3 varint bytes; we expect
  // not to see 4 bytes because our current chunk
  // alignment would not allow for objects over
  // 2^21 bytes long anyway...
  VPBROADCASTD  CONSTD_0x7F(), Z27      // Z27 = 0x7F
  VPBROADCASTD  CONSTD_0x80(), Z29      // Z29 = 0x80
  VPSRLD        $4, Z26, Z26            // now Z26 = 3 bytes following descriptor
  KMOVW         K2, K3
  VPANDD.Z      Z27, Z26, K3, Z28       // Z28 = byte1&0x7f = accumulator
  VPADDD        Z21, Z22, K3, Z22       // total++
  VPTESTNMD     Z29, Z26, K3, K3        // test byte1&0x80
  KTESTW        K3, K3
  JZ            done
  VPSRLD        $8, Z26, K3, Z26        // word >>= 8
  VPSLLD        $7, Z28, K3, Z28        // accum <<= 7
  VPANDD        Z27, Z26, K3, Z25
  VPORD         Z25, Z28, K3, Z28       // accum |= (word & 0x7f)
  VPADDD        Z21, Z22, K3, Z22       // total++
  VPTESTNMD     Z29, Z26, K3, K3        // test word&0x80
  VPSRLD        $8, Z26, K3, Z26        // word >>= 8
  VPSLLD        $7, Z28, K3, Z28        // accum <<= 7
  VPANDD        Z27, Z26, K3, Z25
  VPORD         Z25, Z28, K3, Z28       // accum |= (word & 0x7f)
  VPADDD        Z21, Z22, K3, Z22       // total++
  VPTESTNMD     Z29, Z26, K3, K3        // test word&0x80
  KTESTW        K3, K3
  JNZ           trap                    // trap if length(object) > 2^21
done:
  VPADDD        Z28, Z22, K2, Z22       // size += varint size
  VPCMPUD       $VPCMP_IMM_GT, Z3, Z22, K1, K3   // bounds check: we are still inside the array
  KTESTW        K3, K3
  JNZ           trap
  VMOVDQA32.Z   Z2, K1, Z30             // Z30 = object base = Z2
  VMOVDQA32.Z   Z22, K1, Z31            // Z31 = object size = Z22
  VPADDD        Z22, Z2, K1, Z2         // offset += object size
  VPSUBD.Z      Z22, Z3, K1, Z3         // length -= object size
next:
  NEXT()
trap:
  FAIL()

// take value regs Z30:Z31 and parse
// them as structure offset + length
// into Z0:Z1
TEXT bctuple(SB), NOSPLIT|NOFRAME, $0
  KTESTW        K1, K1
  JZ            next
  KMOVW         K1, K2
  VPBROADCASTD  CONSTD_0x0F(), Z27         // Z27 = 0x0F
  VPBROADCASTD  CONSTD_1(), Z21            // Z21 = 1
  VMOVDQA32     Z21, Z23                   // Z23 = 1 = offset addend
  VPGATHERDD    0(SI)(Z30*1), K2, Z28      // Z28 = first 4 bytes
  VPANDD        Z27, Z28, Z25              // Z25 = first 4 & 0x0f = immediate size
  VPCMPEQD      Z27, Z25, K1, K2           // K2 = lane is null
  KANDNW        K1, K2, K1                 // unset lanes that are null values
  VPSRLD        $4, Z28, Z28               // Z28 >>= 4
  VPANDD        Z27, Z28, Z26              // Z26 = field tag
  VPCMPEQD.BCST CONSTD_0x0D(), Z26, K1, K1 // K1 = keep lanes that are actually structures
  VPCMPEQD.BCST CONSTD_0x0E(), Z25, K1, K2 // K2 = lane has non-immediate length
  VPSRLD        $4, Z28, Z28               // shift away first byte completely
  VPBROADCASTD  CONSTD_0x7F(), Z24         // Z24 = 0x7f
  VPBROADCASTD  CONSTD_0x80(), Z26         // Z26 = 0x80
  VPADDD        Z21, Z23, K2, Z23          // offset++ (now 2)
  VPANDD        Z24, Z28, K2, Z25          // outsize = byte&0x7f
  VPTESTNMD     Z26, Z28, K2, K2           // test if we've hit the stop bit
  KTESTW        K2, K2
  JNZ           two_more                   // keep the fast path (length < 127) short
done:
  VPADDD        Z23, Z30, K1, Z0           // Z0 = base = offset + encoding size
  VMOVDQA32     Z25, K1, Z1                // Z1 = length
next:
  NEXT()
trap:
  FAIL()
two_more:
  VPADDD        Z21, Z23, K2, Z23
  VPSLLD        $7, Z25, K2, Z25
  VPSRLD        $8, Z28, Z28
  VPANDD        Z24, Z28, K2, Z27
  VPORD         Z27, Z25, K2, Z25
  VPTESTNMD     Z26, Z28, K2, K2
  VPADDD        Z21, Z23, K2, Z23
  VPSLLD        $7, Z25, K2, Z25
  VPSRLD        $8, Z28, Z28
  VPANDD        Z24, Z28, K2, Z27
  VPORD         Z27, Z25, K2, Z25
  VPTESTNMD     Z26, Z28, K2, K2
  KTESTW        K2, K2
  JNZ           trap
  JMP           done

// duplicate a value stack slot
// (used when a value is returned multiple times)
TEXT bcdupv(SB), NOSPLIT|NOFRAME, $0
  MOVWQZX    0(VIRT_PCREG), R8
  MOVWQZX    2(VIRT_PCREG), R15
  ADDQ       $4, VIRT_PCREG
  VMOVDQU32.Z 0(VIRT_VALUES)(R8*1), K1, Z28
  VMOVDQU32.Z 64(VIRT_VALUES)(R8*1), K1, Z29
  VMOVDQU32 Z28, 0(VIRT_VALUES)(R15*1)
  VMOVDQU32 Z29, 64(VIRT_VALUES)(R15*1)
  NEXT()

// zero a slot (this is effectively the constprop'd version of saving MISSING everywhere)
TEXT bczerov(SB), NOSPLIT|NOFRAME, $0
  MOVWQZX     0(VIRT_PCREG), R8
  ADDQ        $2, VIRT_PCREG
  VPXORD      Z28, Z28, Z28
  VMOVDQU32   Z28, 0(VIRT_VALUES)(R8*1)
  VMOVDQU32   Z28, 64(VIRT_VALUES)(R8*1)
  NEXT()

// Defines for function SIZE()

#define     HEAD_BYTES      Z29
#define     T_FIELD         Z28
#define     L_FIELD         Z27
#define     OBJECT_SIZE     Z26
#define     HEADER_LENGTH   Z25
#define     VALID           K1
#define     LIST_SEXP       K5
#define     STRUCT          K6

#define     TMP                 Z5
#define     TMP2                Z6
#define     TMP3                Z7
#define     CONST_0x80          Z8
#define     CONST_0x7f          Z9
#define     CONST_0x01          Z10
#define     CONST_0x0e          Z11
#define     CONST_0x0f          Z12
#define     CONST_0x00          Z13
#define     CONST_BSWAPD        Z14
#define     CONST_0x80808080    Z15
#define     CONST_0x03          Z16


// Calculate the number bytes occupied by uvint value.
// Assumes that uvint has at most 3 bytes, for longer
// values jumps to `trap`.
//
// Inputs:
// - BYTES  - 4 initial bytes
// - VALID  - valid lanes
//
// Outputs:
// - COUNT  - the number of bytes ([0..3] each)
//
// Modifies:
// - BYTES
#define CALCULATE_UVINT_LENGTH(VALID, BYTES, COUNT)     \
    VPSHUFB     CONST_BSWAPD, BYTES, BYTES              \
    VPANDD      CONST_0x80808080, BYTES, BYTES          \
    VPLZCNTD    BYTES, COUNT                            \
    VPSRLD      $3, COUNT, VALID, COUNT                 \
    VPADDD.Z    CONST_0x01, COUNT, VALID, COUNT         \
    /* check if length > 3 */                           \
    VPCMPUD     $VPCMP_IMM_GT, CONST_0x03, COUNT, K2    \
    KTESTW      K2, K2                                  \
    JNZ trap


#define DWORD_CONST(value, target)    \
    MOVD $value, CX                   \
    VPBROADCASTD CX, target


// Function exposes macro CALCULATE_UVINT_LENGTH for unit test purposes.
//
// input:
// - Z30 - offsets
// - K1  - active lanes
// output:
// - K7  - masks too long uvints
// - Z31 - 32-bit lengths
TEXT objectsize_test_uvint_length(SB), NOSPLIT|NOFRAME, $0
    // init
    DWORD_CONST(0x80, CONST_0x80)
    DWORD_CONST(0x01, CONST_0x01)
    DWORD_CONST(0x03, CONST_0x03)
    DWORD_CONST(0x80808080, CONST_0x80808080)
    VBROADCASTI32X4 bswap32<>+0(SB), CONST_BSWAPD
    DWORD_CONST(0xcacacaca, Z1)

    KMOVW   K1, K2
    VPGATHERDD (SI)(Z30*1), K2, Z1

    VPXORD Z31, Z31, Z31
    CALCULATE_UVINT_LENGTH(K1, Z1, Z31)
    KMOVW K2, K7
    RET

trap:
    MOVD $0xffffffff, AX
    VPBROADCASTD AX, Z31
    KMOVW K2, K7
    RET


#include "evalbc_ionheader.h"

// Function exposes macro CALCULATE_OBJECT_SIZE for unit test purposes.
//
// input:
// - Z30 - offsets
// - K1  - active lanes
// output:
// - K7  - masks invalid entries
// - Z30 - header length (TV byte + optional uvint length)
// - Z31 - object size
TEXT objectsize_test_object_header_size(SB), NOSPLIT|NOFRAME, $0

    DWORD_CONST(0x01, CONST_0x01)
    DWORD_CONST(0x0e, CONST_0x0e)
    DWORD_CONST(0x0f, CONST_0x0f)
    DWORD_CONST(0x7f, CONST_0x7f)
    DWORD_CONST(0x80, CONST_0x80)

    // test
    LOAD_OBJECT_HEADER(K1)
    CALCULATE_OBJECT_SIZE(K1, no_uvint, uvint_done)

    // store result
    VMOVDQA32 HEADER_LENGTH, Z1
    VMOVDQA32 OBJECT_SIZE, Z2
    KMOVW K2, K7
    RET

trap:
    DWORD_CONST(0xffffffff, Z1)
    DWORD_CONST(0xffffffff, Z2)
    RET


// SIZE(x) function --- returns the number of items
// in a struct or list, missing otherwise.
TEXT bcobjectsize(SB), NOSPLIT|NOFRAME, $0
    VPBROADCASTD CONSTD_1(), CONST_0x01
    VPBROADCASTD CONSTD_0x0F(), CONST_0x0f

    /* 1. Determine object types */
    LOAD_OBJECT_HEADER(K1)

    VPXORD      Z2, Z2, Z2 /* set the count to zero */
    VPXORD      Z3, Z3, Z3

    VPCMPD.BCST $VPCMP_IMM_EQ, CONSTD_0x0B(), T_FIELD, K1, K2 /* list */
    VPCMPD.BCST $VPCMP_IMM_EQ, CONSTD_0x0C(), T_FIELD, K1, LIST_SEXP /* sexp */
    VPCMPD.BCST $VPCMP_IMM_EQ, CONSTD_0x0D(), T_FIELD, K1, STRUCT /* struct */

    KORW    K2, LIST_SEXP, LIST_SEXP
    KORW    LIST_SEXP, STRUCT, K1 /* non-containers -> missing */
    KTESTW  K1, K1
    JZ      no_compbound_values_found

    /* 2. unset all null values */
    VPCMPD  $VPCMP_IMM_EQ, CONST_0x0f, L_FIELD, K1, K2 /* K2 - null values */
    KANDNW  K1, K2, K1
    KTESTW  K1, K1
    JZ      all_nulls

    VPBROADCASTD CONSTD_0x0E(), CONST_0x0e
    VPBROADCASTD CONSTD_0x7F(), CONST_0x7f
    VPBROADCASTD CONSTD_0x80(), CONST_0x80
    VPBROADCASTD CONSTD_3(), CONST_0x03
    DWORD_CONST(0x80808080, CONST_0x80808080)
    VBROADCASTI32X4 bswap32<>+0(SB), CONST_BSWAPD
    VPXORD CONST_0x00, CONST_0x00, CONST_0x00

    /* 3. find the containers' size */
    KORW    LIST_SEXP, STRUCT, K2
    CALCULATE_OBJECT_SIZE(K2, no_uvint1, uvint_done1)

    VPADDD  Z30, HEADER_LENGTH, Z30 /* Z30 - points the inner structure */
    VPADDD  Z30, OBJECT_SIZE, Z31   /* Z31 = points the end of the inner structure */

    /* 4. iterate over lists/sexprs */
count_list_sexp_values:
    VPCMPD $VPCMP_IMM_LT, Z31, Z30, LIST_SEXP, LIST_SEXP
    KTESTW  LIST_SEXP, LIST_SEXP
    JZ count_list_sexp_values_end

    LOAD_OBJECT_HEADER(LIST_SEXP)
    CALCULATE_OBJECT_SIZE(LIST_SEXP, no_uvint2, uvint_done2)

    VPADDD  CONST_0x01, Z2, LIST_SEXP, Z2       /* count += 1 */
    VPADDD  HEADER_LENGTH, Z30, LIST_SEXP, Z30  /* offset += header_size */
    VPADDD  OBJECT_SIZE, Z30, LIST_SEXP, Z30    /* offset += object_size */

    JMP count_list_sexp_values
count_list_sexp_values_end:

    /* 5. iterate over structs */
count_fields:
    VPCMPD $VPCMP_IMM_LT, Z31, Z30, STRUCT, STRUCT
    KTESTW STRUCT, STRUCT
    JZ count_fields_end

    /* skip field id */
    KMOVW STRUCT, K2
    VPGATHERDD  (SI)(Z30*1), K2, HEAD_BYTES
    CALCULATE_UVINT_LENGTH(STRUCT, HEAD_BYTES, TMP)
    VPADDD  TMP, Z30, Z30

    /* skip field value */
    LOAD_OBJECT_HEADER(STRUCT)
    CALCULATE_OBJECT_SIZE(STRUCT, no_uvint3, uvint_done3)

    VPADDD  CONST_0x01, Z2, STRUCT, Z2       /* count += 1 */
    VPADDD  HEADER_LENGTH, Z30, STRUCT, Z30  /* offset += header_size */
    VPADDD  OBJECT_SIZE, Z30, STRUCT, Z30    /* offset += object_size */

    JMP count_fields
count_fields_end:
    VEXTRACTI32X8   $1, Z2, Y3
    VPMOVZXDQ       Y2, Z2
    VPMOVZXDQ       Y3, Z3
    NEXT()

no_compbound_values_found:
all_nulls:
    KXORW           K1, K1, K1
    NEXT()
trap:
    FAIL()


#undef DWORD_CONST
#undef CALCULATE_UVINT_LENGTH
#undef LOAD_OBJECT_HEADER
#undef CALCULATE_OBJECT_SIZE

#undef HEAD_BYTES
#undef T_FIELD
#undef L_FIELD
#undef OBJECT_SIZE
#undef HEADER_LENGTH
#undef VALID
#undef LIST_SEXP
#undef STRUCT

#undef TMP
#undef TMP2
#undef TMP3
#undef CONST_0x80
#undef CONST_0x7f
#undef CONST_0x01
#undef CONST_0x0e
#undef CONST_0x0f
#undef CONST_0x00
#undef CONST_0x80808080
#undef CONST_0x03

// String Instructions
// -------------------

//; #region string methods

//; #region bcCmpStrEqCs
//; equal ascii string in slice in Z2:Z3, with stack[imm]
TEXT bcCmpStrEqCs(SB), NOSPLIT|NOFRAME, $0
  IMM_FROM_DICT(R14)                      //;05667C35 load *[]byte with the provided str into R14
  VPBROADCASTD  8(R14),Z6                 //;713DF24F bcst needle_length              ;Z6=counter_needle; R14=needle_slice;
  VPTESTMD      Z6,  Z6,  K1,  K1         //;EF7C0710 K1 &= (counter_needle != 0)     ;K1=lane_active; Z6=counter_needle;
  VPCMPD        $0,  Z6,  Z3,  K1,  K1    //;502E314F K1 &= (str_len==counter_needle) ;K1=lane_active; Z3=str_len; Z6=counter_needle; 0=Eq;
  MOVQ          (R14),R14                 //;D2647DF0 load needle_ptr                 ;R14=needle_ptr; R14=needle_slice;
  VPXORD        Z11, Z11, Z11             //;81C90120 load constant 0                 ;Z11=0;
  VPBROADCASTD  CONSTD_4(),Z20            //;C8AFBE50 load constant 4                 ;Z20=4;

  JMP           tests                     //;F2A3982D                                 ;
loop:
//; load data
  KMOVW         K1,  K3                   //;723D04C9 copy eligible lanes             ;K3=tmp_mask; K1=lane_active;
  VPGATHERDD    (SI)(Z2*1),K3,  Z8        //;E4967C89 gather data                     ;Z8=data_msg; K3=tmp_mask; SI=msg_ptr; Z2=str_start;
  VPSUBD        Z20, Z3,  K1,  Z3         //;AEDCD850 str_len -= 4                    ;Z3=str_len; K1=lane_active; Z20=4;
  VPADDD        Z20, Z2,  K1,  Z2         //;D7CC90DD str_start += 4                  ;Z2=str_start; K1=lane_active; Z20=4;
//; compare data with needle
  VPCMPD.BCST   $0,  (R14),Z8,  K1,  K1   //;F0E5B3BD K1 &= (data_msg==[needle_ptr])  ;K1=lane_active; Z8=data_msg; R14=needle_ptr; 0=Eq;
  ADDQ          $4,  R14                  //;B2EF9837 needle_ptr += 4                 ;R14=needle_ptr;
tests:
  VPCMPD        $2,  Z3,  Z11, K1,  K1    //;8A1022B4 K1 &= (0<=str_len)              ;K1=lane_active; Z11=0; Z3=str_len; 2=LessEq;
  VPCMPD        $6,  Z20, Z3,  K3         //;99392208 K3 := (str_len>4)               ;K3=tmp_mask; Z3=str_len; Z20=4; 6=Greater;
  KTESTW        K1,  K1                   //;FE455439 any lanes still alive           ;K1=lane_active;
  JZ            next                      //;CD5F484F no, exit; jump if zero (ZF = 1) ;
  KTESTW        K1,  K3                   //;C28D3832 ZF := ((K3&K1)==0); CF := ((~K3&K1)==0);K3=tmp_mask; K1=lane_active;
  JNZ           loop                      //;B678BE90 no, loop again; jump if not zero (ZF = 0);
//; load data
  KMOVW         K1,  K3                   //;723D04C9 copy eligible lanes             ;K3=tmp_mask; K1=lane_active;
  VPGATHERDD    (SI)(Z2*1),K3,  Z8        //;36FEA5FE gather data                     ;Z8=data_msg; K3=tmp_mask; SI=msg_ptr; Z2=str_start;
  VPERMD        CONST_TAIL_MASK(),Z3,  Z19 //;E5886CFE get tail_mask                  ;Z19=tail_mask; Z3=str_len;
  VPANDD        Z8,  Z19, Z8              //;FC6636EA mask data from msg              ;Z8=data_msg; Z19=tail_mask;
//; compare data with needle
  VPCMPD.BCST   $0,  (R14),Z8,  K1,  K1   //;474761AE K1 &= (data_msg==[needle_ptr])  ;K1=lane_active; Z8=data_msg; R14=needle_ptr; 0=Eq;
next:
  NEXT()
//; #endregion bcCmpStrEqCs

//; #region bcCmpStrEqCi
//; equal ascii string in slice in Z2:Z3, with stack[imm]
TEXT bcCmpStrEqCi(SB), NOSPLIT|NOFRAME, $0
  IMM_FROM_DICT(R14)                      //;05667C35 load *[]byte with the provided str into R14
  VPBROADCASTD  8(R14),Z6                 //;713DF24F bcst needle_length              ;Z6=counter_needle; R14=needle_slice;
  VPTESTMD      Z6,  Z6,  K1,  K1         //;EF7C0710 K1 &= (counter_needle != 0)     ;K1=lane_active; Z6=counter_needle;
  VPCMPD        $0,  Z6,  Z3,  K1,  K1    //;502E314F K1 &= (str_len==counter_needle) ;K1=lane_active; Z3=str_len; Z6=counter_needle; 0=Eq;
  MOVQ          (R14),R14                 //;D2647DF0 load needle_ptr                 ;R14=needle_ptr; R14=needle_slice;
  VPBROADCASTB  CONSTB_32(),Z15           //;5B8F2908 load constant 0b00100000        ;Z15=c_0b00100000;
  VPBROADCASTB  CONSTB_97(),Z16           //;5D5B0014 load constant ASCII a           ;Z16=char_a;
  VPBROADCASTB  CONSTB_122(),Z17          //;8E2ED824 load constant ASCII z           ;Z17=char_z;
  VPXORD        Z11, Z11, Z11             //;81C90120 load constant 0                 ;Z11=0;
  VPBROADCASTD  CONSTD_4(),Z20            //;C8AFBE50 load constant 4                 ;Z20=4;

  JMP           tests                     //;F2A3982D                                 ;
loop:
//; load data
  KMOVW         K1,  K3                   //;723D04C9 copy eligible lanes             ;K3=tmp_mask; K1=lane_active;
  VPGATHERDD    (SI)(Z2*1),K3,  Z8        //;E4967C89 gather data                     ;Z8=data_msg; K3=tmp_mask; SI=msg_ptr; Z2=str_start;
  VPSUBD        Z20, Z3,  K1,  Z3         //;AEDCD850 str_len -= 4                    ;Z3=str_len; K1=lane_active; Z20=4;
  VPADDD        Z20, Z2,  K1,  Z2         //;D7CC90DD str_start += 4                  ;Z2=str_start; K1=lane_active; Z20=4;
//; str_to_upper: IN zmm8; OUT zmm13
  VPCMPB        $5,  Z16, Z8,  K3         //;30E9B9FD K3 := (data_msg>=char_a)        ;K3=tmp_mask; Z8=data_msg; Z16=char_a; 5=GreaterEq;
  VPCMPB        $2,  Z17, Z8,  K3,  K3    //;8CE85BA0 K3 &= (data_msg<=char_z)        ;K3=tmp_mask; Z8=data_msg; Z17=char_z; 2=LessEq;
  VPMOVM2B      K3,  Z13                  //;ADC21F45 mask with selected chars        ;Z13=data_msg_upper; K3=tmp_mask;
  VPTERNLOGQ    $76, Z15, Z8,  Z13        //;1BB96D97 see stringext.md                ;Z13=data_msg_upper; Z8=data_msg; Z15=c_0b00100000;
//; compare data with needle
  VPCMPD.BCST   $0,  (R14),Z13, K1,  K1   //;F0E5B3BD K1 &= (data_msg_upper==[needle_ptr]);K1=lane_active; Z13=data_msg_upper; R14=needle_ptr; 0=Eq;
  ADDQ          $4,  R14                  //;B2EF9837 needle_ptr += 4                 ;R14=needle_ptr;
tests:
  VPCMPD        $2,  Z3,  Z11, K1,  K1    //;8A1022B4 K1 &= (0<=str_len)              ;K1=lane_active; Z11=0; Z3=str_len; 2=LessEq;
  VPCMPD        $6,  Z20, Z3,  K3         //;99392208 K3 := (str_len>4)               ;K3=tmp_mask; Z3=str_len; Z20=4; 6=Greater;
  KTESTW        K1,  K1                   //;FE455439 any lanes still alive           ;K1=lane_active;
  JZ            next                      //;CD5F484F no, exit; jump if zero (ZF = 1) ;
  KTESTW        K1,  K3                   //;C28D3832 ZF := ((K3&K1)==0); CF := ((~K3&K1)==0);K3=tmp_mask; K1=lane_active;
  JNZ           loop                      //;B678BE90 no, loop again; jump if not zero (ZF = 0);
//; load data
  KMOVW         K1,  K3                   //;723D04C9 copy eligible lanes             ;K3=tmp_mask; K1=lane_active;
  VPGATHERDD    (SI)(Z2*1),K3,  Z8        //;36FEA5FE gather data                     ;Z8=data_msg; K3=tmp_mask; SI=msg_ptr; Z2=str_start;
  VPERMD        CONST_TAIL_MASK(),Z3,  Z19 //;E5886CFE get tail_mask                  ;Z19=tail_mask; Z3=str_len;
  VPANDD        Z8,  Z19, Z8              //;FC6636EA mask data from msg              ;Z8=data_msg; Z19=tail_mask;
//; str_to_upper: IN zmm8; OUT zmm13
  VPCMPB        $5,  Z16, Z8,  K3         //;30E9B9FD K3 := (data_msg>=char_a)        ;K3=tmp_mask; Z8=data_msg; Z16=char_a; 5=GreaterEq;
  VPCMPB        $2,  Z17, Z8,  K3,  K3    //;8CE85BA0 K3 &= (data_msg<=char_z)        ;K3=tmp_mask; Z8=data_msg; Z17=char_z; 2=LessEq;
  VPMOVM2B      K3,  Z13                  //;ADC21F45 mask with selected chars        ;Z13=data_msg_upper; K3=tmp_mask;
  VPTERNLOGQ    $76, Z15, Z8,  Z13        //;1BB96D97 see stringext.md                ;Z13=data_msg_upper; Z8=data_msg; Z15=c_0b00100000;
//; compare data with needle
  VPCMPD.BCST   $0,  (R14),Z13, K1,  K1   //;474761AE K1 &= (data_msg_upper==[needle_ptr]);K1=lane_active; Z13=data_msg_upper; R14=needle_ptr; 0=Eq;
next:
  NEXT()
//; #endregion bcCmpStrEqCi

//; #region bcCmpStrEqUTF8Ci
//; empty needles or empty data always result in a dead lane
TEXT bcCmpStrEqUTF8Ci(SB), NOSPLIT|NOFRAME, $0
  IMM_FROM_DICT(R14)                      //;05667C35 load *[]byte with the provided str into R14
  MOVQ          (R14),R14                 //;D2647DF0 load needle_ptr                 ;R14=needle_ptr; R14=needle_slice;
  MOVL          (R14),CX                  //;5B83F09F load number of code-points      ;CX=n_runes; R14=needle_ptr;
  ADDQ          $4,  R14                  //;7B0665F3 needle_ptr += 4                 ;R14=needle_ptr;
  VPBROADCASTD  CX,  Z26                  //;485C8362 bcst number of code-points      ;Z26=scratch_Z26; CX=n_runes;
  VPTESTMD      Z26, Z26, K1,  K1         //;CD49D8A5 K1 &= (scratch_Z26 != 0); empty needles are dead lanes;K1=lane_active; Z26=scratch_Z26;

  VMOVDQU32     CONST_TAIL_MASK(),Z18     //;7DB21CB0 load tail_mask_data             ;Z18=tail_mask_data;
  VMOVDQU32     CONST_N_BYTES_UTF8(),Z21  //;B323211A load table_n_bytes_utf8         ;Z21=table_n_bytes_utf8;
  VPBROADCASTD  CONSTD_4(),Z20            //;C8AFBE50 load constant 4                 ;Z20=4;
  VPBROADCASTB  CONSTB_32(),Z15           //;5B8F2908 load constant 0b00100000        ;Z15=c_0b00100000;
  VPBROADCASTB  CONSTB_97(),Z16           //;5D5B0014 load constant ASCII a           ;Z16=c_char_a;
  VPBROADCASTB  CONSTB_122(),Z17          //;8E2ED824 load constant ASCII z           ;Z17=c_char_z;

loop:
  VPTESTMD      Z3,  Z3,  K1,  K1         //;790C4E82 K1 &= (str_len != 0); empty data are dead lanes;K1=lane_active; Z3=str_len;
  KMOVW         K1,  K3                   //;723D04C9 copy eligible lanes             ;K3=tmp_mask; K1=lane_active;
  VPGATHERDD    (SI)(Z2*1),K3,  Z8        //;E4967C89 gather data                     ;Z8=data_msg; K3=tmp_mask; SI=msg_ptr; Z2=str_start;

//; NOTE: debugging. If you jump from here to mixed_ascii you bypass the 4 ASCII optimization
//;  JMP           mixed_ascii               //;6FE3345D                                 ;

  CMPL          CX,  $4                   //;E273EEEA are we in the needle tail?      ;CX=n_runes;
  JL            mixed_ascii               //;A8685FD7 yes, then jump; jump if less (SF neq OF);
  VPBROADCASTD.Z 16(R14),K1,  Z9          //;2694A02F load needle data                ;Z9=data_needle; K1=lane_active; R14=needle_ptr;

//; clear tail from data: IN zmm8; OUT zmm8
  VPMINSD       Z3,  Z20, Z26             //;DEC17BF3 scratch_Z26 := min(4, str_len)  ;Z26=scratch_Z26; Z20=4; Z3=str_len;
  VPERMD        Z18, Z26, Z19             //;E5886CFE get tail_mask                   ;Z19=tail_mask; Z26=scratch_Z26; Z18=tail_mask_data;
  VPANDD        Z8,  Z19, Z8              //;64208067 mask data from msg              ;Z8=data_msg; Z19=tail_mask;

//; determine if either data or needle has non-ASCII content
  VPORD.Z       Z8,  Z9,  K1,  Z26        //;3692D686 scratch_Z26 := data_needle | data_msg;Z26=scratch_Z26; K1=lane_active; Z9=data_needle; Z8=data_msg;
  VPMOVB2M      Z26, K3                   //;5303B427 get 64 sign-bits                ;K3=tmp_mask; Z26=scratch_Z26;
  KTESTQ        K3,  K3                   //;A2B0951C all sign-bits zero?             ;K3=tmp_mask;
  JNZ           mixed_ascii               //;303EFD4D no, found a non-ascii char; jump if not zero (ZF = 0);

//; str_to_upper: IN zmm8; OUT zmm13
  VPCMPB        $5,  Z16, Z8,  K3         //;30E9B9FD K3 := (data_msg>=c_char_a)      ;K3=tmp_mask; Z8=data_msg; Z16=c_char_a; 5=GreaterEq;
  VPCMPB        $2,  Z17, Z8,  K3,  K3    //;8CE85BA0 K3 &= (data_msg<=c_char_z)      ;K3=tmp_mask; Z8=data_msg; Z17=c_char_z; 2=LessEq;
  VPMOVM2B      K3,  Z13                  //;ADC21F45 mask with selected chars        ;Z13=data_msg_upper; K3=tmp_mask;
  VPTERNLOGQ    $76, Z15, Z8,  Z13        //;1BB96D97 see stringext.md                ;Z13=data_msg_upper; Z8=data_msg; Z15=c_0b00100000;

//; compare data with needle for 4 ASCIIs
  VPCMPD        $0,  Z13, Z9,  K1,  K1    //;BBBDF880 K1 &= (data_needle==data_msg_upper);K1=lane_active; Z9=data_needle; Z13=data_msg_upper; 0=Eq;
  KTESTW        K1,  K1                   //;5746030A any lanes still alive?          ;K1=lane_active;
  JZ            next                      //;B763A908 no, exit; jump if zero (ZF = 1) ;

//; advance to the next 4 ASCIIs
  VPADDD        Z20, Z2,  K1,  Z2         //;D7CC90DD str_start += 4                  ;Z2=str_start; K1=lane_active; Z20=4;
  VPSUBD        Z20, Z3,  K1,  Z3         //;AEDCD850 str_len -= 4                    ;Z3=str_len; K1=lane_active; Z20=4;
  ADDQ          $80, R14                  //;F0BC3163 needle_ptr += 80                ;R14=needle_ptr;
  SUBL          $4,  CX                   //;646B86C9 n_runes -= 4                    ;CX=n_runes;
  JG            loop                      //;1EBC2C20 jump if greater ((ZF = 0) and (SF = OF));
  JMP           next                      //;2230EE05                                 ;

mixed_ascii:
//; select next UTF8 byte sequence
  VPSRLD        $4,  Z8,  Z26             //;FE5F1413 scratch_Z26 := data_msg>>4      ;Z26=scratch_Z26; Z8=data_msg;
  VPERMD        Z21, Z26, Z7              //;68FECBA0 get n_bytes_data                ;Z7=n_bytes_data; Z26=scratch_Z26; Z21=table_n_bytes_utf8;
  VPERMD        Z18, Z7,  Z19             //;E5886CFE get tail_mask                   ;Z19=tail_mask; Z7=n_bytes_data; Z18=tail_mask_data;
  VPANDD        Z8,  Z19, Z8              //;FC6636EA mask data from msg              ;Z8=data_msg; Z19=tail_mask;

//; compare data with needle for 1 UTF8 byte sequence
  VPCMPD.BCST   $0,  (R14),Z8,  K1,  K3   //;345D0BF3 K3 := K1 & (data_msg==[needle_ptr]);K3=tmp_mask; K1=lane_active; Z8=data_msg; R14=needle_ptr; 0=Eq;
  VPCMPD.BCST   $0,  4(R14),Z8,  K1,  K4  //;EFD0A9A3 K4 := K1 & (data_msg==[needle_ptr+4]);K4=alt2_match; K1=lane_active; Z8=data_msg; R14=needle_ptr; 0=Eq;
  VPCMPD.BCST   $0,  8(R14),Z8,  K1,  K5  //;CAC0FAC6 K5 := K1 & (data_msg==[needle_ptr+8]);K5=alt3_match; K1=lane_active; Z8=data_msg; R14=needle_ptr; 0=Eq;
  VPCMPD.BCST   $0,  12(R14),Z8,  K1,  K6  //;50C70740 K6 := K1 & (data_msg==[needle_ptr+12]);K6=alt4_match; K1=lane_active; Z8=data_msg; R14=needle_ptr; 0=Eq;
  KORW          K3,  K4,  K3              //;58E49245 tmp_mask |= alt2_match          ;K3=tmp_mask; K4=alt2_match;
  KORW          K3,  K5,  K3              //;BDCB8940 tmp_mask |= alt3_match          ;K3=tmp_mask; K5=alt3_match;
  KORW          K6,  K3,  K1              //;AAF6ED91 lane_active := tmp_mask | alt4_match;K1=lane_active; K3=tmp_mask; K6=alt4_match;
  KTESTW        K1,  K1                   //;5746030A any lanes still alive?          ;K1=lane_active;
  JZ            next                      //;B763A908 no, exit; jump if zero (ZF = 1) ;

//; advance to the next rune
  VPADDD        Z7,  Z2,  K1,  Z2         //;DFE8D20B str_start += n_bytes_data       ;Z2=str_start; K1=lane_active; Z7=n_bytes_data;
  VPSUBD        Z7,  Z3,  K1,  Z3         //;24E04BE7 str_len -= n_bytes_data         ;Z3=str_len; K1=lane_active; Z7=n_bytes_data;
  ADDQ          $20, R14                  //;1F8D79B1 needle_ptr += 20                ;R14=needle_ptr;
  DECL          CX                        //;A99E9290 n_runes--                       ;CX=n_runes;
  JG            loop                      //;80013DFA jump if greater ((ZF = 0) and (SF = OF));

next:
  VPTESTNMD     Z3,  Z3,  K1,  K1         //;E555E77C K1 &= (str_len==0)              ;K1=lane_active; Z3=str_len;
  NEXT()

//; #endregion bcCmpStrEqUTF8Ci

//; #region bcCmpStrFuzzyA3
TEXT bcCmpStrFuzzyA3(SB), NOSPLIT|NOFRAME, $0
  IMM_FROM_DICT(R15)                      //;05667C35 load *[]byte with the provided str into R15
//; load parameters
  MOVQ          (R15),R15                 //;D2647DF0 load needle_ptr                 ;R15=update_data_ptr;
  MOVQ          R15, R14                  //;EC3C3E7D needle_ptr := update_data_ptr   ;R14=needle_ptr; R15=update_data_ptr;
  ADDQ          $512,R14                  //;46443C9E needle_ptr += 512               ;R14=needle_ptr;
  VPBROADCASTD  (R14),Z13                 //;713DF24F bcst needle_len                 ;Z13=needle_len; R14=needle_ptr;
  ADDQ          $4,  R14                  //;B63DFEAF needle_ptr += 4                 ;R14=needle_ptr;
//; load from stack-slot: load 16x uint32 into Z14
  LOADARG1Z(Z27, Z26)
  VPMOVQD       Z27, Y27                  //;17FCB103 truncate uint64 to uint32       ;Z27=scratch2;
  VPMOVQD       Z26, Y26                  //;8F762E8E truncate uint64 to uint32       ;Z26=scratch1;
  VINSERTI64X4  $1,  Y26, Z27, Z14        //;3944001B merge into 16x uint32           ;Z14=threshold; Z27=scratch2; Z26=scratch1;
//; restrict lanes to allow fast bail-out
  VPSUBD        Z14, Z13, Z26             //;10B77777 scratch1 := needle_len - threshold;Z26=scratch1; Z13=needle_len; Z14=threshold;
  VPCMPD        $2,  Z3,  Z26, K1,  K1    //;F08352A0 K1 &= (scratch1<=data_len)      ;K1=lane_active; Z26=scratch1; Z3=data_len; 2=LessEq;
  KTESTW        K1,  K1                   //;8BEF97CD ZF := (K1==0); CF := 1          ;K1=lane_active;
  JZ            next                      //;5FEF8EC0 jump if zero (ZF = 1)           ;
//; load constants
  VPBROADCASTB  CONSTB_32(),Z15           //;5B8F2908 load constant 0b00100000        ;Z15=c_0b00100000;
  VPBROADCASTB  CONSTB_97(),Z16           //;5D5B0014 load constant ASCII a           ;Z16=char_a;
  VPBROADCASTB  CONSTB_122(),Z17          //;8E2ED824 load constant ASCII z           ;Z17=char_z;
  VPBROADCASTD  CONSTD_3(),Z24            //;6F57EE92 load constant 3                 ;Z24=3;
  VPBROADCASTD  CONSTD_0x10101(),Z19      //;2AB82DC0 load constant 0x10101           ;Z19=0x10101;
  VPBROADCASTD  CONSTD_0x10801(),Z22      //;A76098A3 load constant 0x10801           ;Z22=0x10801;
  VPBROADCASTD  CONSTD_0x400001(),Z23     //;3267BFF0 load constant 0x400001          ;Z23=0x400001;
  VPSLLD        $1,  Z19, Z20             //;68F49F35 0x20202 := 0x10101<<1           ;Z20=0x20202; Z19=0x10101;
  VPSLLD        $2,  Z19, Z21             //;2789BA9D 0x40404 := 0x10101<<2           ;Z21=0x40404; Z19=0x10101;
  VMOVDQU32     FUZZY_ROR_APPROX3(),Z25   //;2CEF25D2 load ror approx3                ;Z25=ror_a3;
  VMOVDQU32     CONST_TAIL_INV_MASK(),Z18 //;9653E713 load tail_inv_mask_data         ;Z18=tail_mask_data;
  VPXORD        Z11, Z11, Z11             //;81C90120 load constant 0                 ;Z11=0;
//; init variables loop2
  VPXORD        Z4,  Z4,  Z4              //;6D778B5D edit_dist := 0                  ;Z4=edit_dist;
  VPXORD        Z5,  Z5,  Z5              //;B150336A needle_off := 0                 ;Z5=needle_off;
  KMOVW         K1,  K2                   //;FBC36D43 lane_todo := lane_active        ;K2=lane_todo; K1=lane_active;
  KXORW         K1,  K1,  K1              //;1607AB46 lane_active := 0                ;K1=lane_active;
loop2:
//; load data ascii approx3
//; clear data
  VPTERNLOGD    $0b11111111,Z8,  Z8,  Z8  //;F81949DF set 0xFFFFFFFF                  ;Z8=data;
  VPTERNLOGD    $0b11111111,Z9,  Z9,  Z9  //;9E9BD820 set 0xFFFFFFFF                  ;Z9=needle;
//; load data and needle
  VPCMPD        $6,  Z11, Z3,  K2,  K4    //;FCFCB494 K4 := K2 & (data_len>0)         ;K4=scratch1; K2=lane_todo; Z3=data_len; Z11=0; 6=Greater;
  VPCMPD        $6,  Z11, Z13, K2,  K5    //;7C687BDA K5 := K2 & (needle_len>0)       ;K5=scratch2; K2=lane_todo; Z13=needle_len; Z11=0; 6=Greater;
  KMOVW         K4,  K3                   //;723D04C9 copy eligible lanes             ;K3=tmp_mask; K4=scratch1;
  VPGATHERDD    (SI)(Z2*1),K3,  Z8        //;E4967C89 gather data                     ;Z8=data; K3=tmp_mask; SI=data_ptr; Z2=data_off;
  VPGATHERDD    (R14)(Z5*1),K5,  Z9       //;4EAE4300 gather needle                   ;Z9=needle; K5=scratch2; R14=needle_ptr; Z5=needle_off;
//; remove tail from data
  VPMINSD       Z3,  Z24, Z26             //;D337D11D scratch1 := min(3, data_len)    ;Z26=scratch1; Z24=3; Z3=data_len;
  VPERMD        Z18, Z26, Z26             //;E882D550                                 ;Z26=scratch1; Z18=tail_mask_data;
  VPORD         Z8,  Z26, K4,  Z8         //;985B667B data |= scratch1                ;Z8=data; K4=scratch1; Z26=scratch1;
//; str_to_upper: IN zmm8; OUT zmm26
  VPCMPB        $5,  Z16, Z8,  K3         //;30E9B9FD K3 := (data>=char_a)            ;K3=tmp_mask; Z8=data; Z16=char_a; 5=GreaterEq;
  VPCMPB        $2,  Z17, Z8,  K3,  K3    //;8CE85BA0 K3 &= (data<=char_z)            ;K3=tmp_mask; Z8=data; Z17=char_z; 2=LessEq;
//; Z15 is 64 bytes with 0b00100000
//;    Z15|Z8 |Z26 => Z26
//;     0 | 0 | 0      0
//;     0 | 0 | 1      0
//;     0 | 1 | 0      1
//;     0 | 1 | 1      1
//;     1 | 0 | 0      0
//;     1 | 0 | 1      0
//;     1 | 1 | 0      1
//;     1 | 1 | 1      0     <= change from lower to upper
  VPMOVM2B      K3,  Z26                  //;ADC21F45 mask with selected chars        ;Z26=scratch1; K3=tmp_mask;
  VPTERNLOGD    $0b01001100,Z15, Z8,  Z26 //;1BB96D97                                 ;Z26=scratch1; Z8=data; Z15=c_0b00100000;
//; prepare data
  VPSHUFB       Z25, Z9,  Z27             //;9E2DA720                                 ;Z27=scratch2; Z9=needle; Z25=ror_a3;
  VPSHUFB       Z25, Z27, Z28             //;EF2A718F                                 ;Z28=scratch3; Z27=scratch2; Z25=ror_a3;
//; compare data
  VPCMPB        $0,  Z26, Z9,  K3         //;B72E9264 K3 := (needle==scratch1)        ;K3=tmp_mask; Z9=needle; Z26=scratch1; 0=Eq;
  VPCMPB        $0,  Z26, Z27, K4         //;4D744078 K4 := (scratch2==scratch1)      ;K4=scratch1; Z27=scratch2; Z26=scratch1; 0=Eq;
  VPCMPB        $0,  Z26, Z28, K5         //;7D453022 K5 := (scratch3==scratch1)      ;K5=scratch2; Z28=scratch3; Z26=scratch1; 0=Eq;
//; fuzzy kernel approx3: create lookup key in Z26
  VMOVDQU8.Z    Z19, K3,  Z26             //;AE601720 0000_0000 0000_000a 0000_000b 0000_000c;Z26=scratch1; K3=tmp_mask; Z19=0x10101;
  VMOVDQU8.Z    Z20, K4,  Z27             //;C8E83855 0000_0000 0000_00d0 0000_00e0 0000_00f0;Z27=scratch2; K4=scratch1; Z20=0x20202;
  VMOVDQU8.Z    Z21, K5,  Z29             //;1AA38791 0000_0000 0000_0g00 0000_0h00 0000_0i00;Z29=scratch4; K5=scratch2; Z21=0x40404;
  VPTERNLOGD    $0b11111110,Z29, Z27, Z26 //;FF99B822 0000_0000 0000_0gda 0000_0heb 0000_0ifc;Z26=scratch1; Z27=scratch2; Z29=scratch4;
  VPMADDUBSW    Z26, Z22, Z26             //;6483F13D 0000_0000 0000_0gda 0000_0000 00he_bifc;Z26=scratch1; Z22=0x10801;
  VPMADDWD      Z26, Z23, Z26             //;3FA33058 0000_0000 0000_0000 0000_000g dahe_bifc;Z26=scratch1; Z23=0x400001;
//; do the lookup of the advance values
  KMOVW         K2,  K3                   //;45A99B90 tmp_mask := lane_todo           ;K3=tmp_mask; K2=lane_todo;
  VPGATHERDD    (R15)(Z26*1),K3,  Z27     //;C3AEFFBF                                 ;Z27=scratch2; K3=tmp_mask; R15=update_data_ptr; Z26=scratch1;
//; unpack results
  VPSRLD        $4,  Z27, Z28             //;87E05D1F ed_delta := scratch2>>4         ;Z28=ed_delta; Z27=scratch2;
  VPSRLD        $2,  Z27, Z9              //;13C921F9 adv_needle := scratch2>>2       ;Z9=adv_needle; Z27=scratch2;
  VPANDD        Z24, Z28, Z28             //;A7E1848A ed_delta &= 3                   ;Z28=ed_delta; Z24=3;
  VPANDD        Z24, Z27, Z8              //;42B9DA14 adv_data := scratch2 & 3        ;Z8=adv_data; Z27=scratch2; Z24=3;
  VPANDD        Z24, Z9,  Z9              //;E2CB942A adv_needle &= 3                 ;Z9=adv_needle; Z24=3;
//; update ascii
//; update edit distance
  VPADDD        Z28, Z4,  K2,  Z4         //;F07EA991 edit_dist += ed_delta           ;Z4=edit_dist; K2=lane_todo; Z28=ed_delta;
//; advance data
  VPSUBD        Z8,  Z3,  K2,  Z3         //;DF7FB44E data_len -= adv_data            ;Z3=data_len; K2=lane_todo; Z8=adv_data;
  VPADDD        Z8,  Z2,  K2,  Z2         //;F81C97B0 data_off += adv_data            ;Z2=data_off; K2=lane_todo; Z8=adv_data;
//; advance needle
  VPSUBD        Z9,  Z13, K2,  Z13        //;41970AC0 needle_len -= adv_needle        ;Z13=needle_len; K2=lane_todo; Z9=adv_needle;
  VPADDD        Z9,  Z5,  K2,  Z5         //;254FD5C6 needle_off += adv_needle        ;Z5=needle_off; K2=lane_todo; Z9=adv_needle;
//; cmp-tail
//; restrict lanes based on edit distance and threshold
  VPCMPD        $2,  Z14, Z4,  K2,  K2    //;86F95312 K2 &= (edit_dist<=threshold)    ;K2=lane_todo; Z4=edit_dist; Z14=threshold; 2=LessEq;
//; test if we have a match
  VPCMPD        $5,  Z13, Z11, K2,  K3    //;EEF4BAA0 K3 := K2 & (0>=needle_len)      ;K3=tmp_mask; K2=lane_todo; Z11=0; Z13=needle_len; 5=GreaterEq;
  VPCMPD        $5,  Z3,  Z11, K3,  K3    //;4CCAC6C8 K3 &= (0>=data_len)             ;K3=tmp_mask; Z11=0; Z3=data_len; 5=GreaterEq;
  KORW          K1,  K3,  K1              //;8FAB61CD lane_active |= tmp_mask         ;K1=lane_active; K3=tmp_mask;
  KANDNW        K2,  K3,  K2              //;482703BD lane_todo &= ~tmp_mask          ;K2=lane_todo; K3=tmp_mask;
  KTESTW        K2,  K2                   //;4661A15A any lanes still todo?           ;K2=lane_todo;
  JNZ           loop2                     //;28307DE7 yes, then loop; jump if not zero (ZF = 0);
next:
  NEXT()
//; #endregion bcCmpStrFuzzyA3

//; #region bcCmpStrFuzzyUnicodeA3
TEXT bcCmpStrFuzzyUnicodeA3(SB), NOSPLIT|NOFRAME, $0
  IMM_FROM_DICT(R15)                      //;05667C35 load *[]byte with the provided str into R15
//; load parameters
  MOVQ          (R15),R15                 //;D2647DF0 load needle_ptr                 ;R15=update_data_ptr;
  MOVQ          R15, R14                  //;EC3C3E7D needle_ptr := update_data_ptr   ;R14=needle_ptr; R15=update_data_ptr;
  ADDQ          $512,R14                  //;46443C9E needle_ptr += 512               ;R14=needle_ptr;
  VPBROADCASTD  (R14),Z13                 //;713DF24F bcst needle_len                 ;Z13=needle_len; R14=needle_ptr;
  ADDQ          $4,  R14                  //;B63DFEAF needle_ptr += 4                 ;R14=needle_ptr;
//; load from stack-slot: load 16x uint32 into Z14
  LOADARG1Z(Z27, Z26)
  VPMOVQD       Z27, Y27                  //;17FCB103 truncate uint64 to uint32       ;Z27=scratch2;
  VPMOVQD       Z26, Y26                  //;8F762E8E truncate uint64 to uint32       ;Z26=scratch1;
  VINSERTI64X4  $1,  Y26, Z27, Z14        //;3944001B merge into 16x uint32           ;Z14=threshold; Z27=scratch2; Z26=scratch1;
//; load constants
  VPBROADCASTB  CONSTB_32(),Z15           //;5B8F2908 load constant 0b00100000        ;Z15=c_0b00100000;
  VPBROADCASTB  CONSTB_97(),Z16           //;5D5B0014 load constant ASCII a           ;Z16=char_a;
  VPBROADCASTB  CONSTB_122(),Z17          //;8E2ED824 load constant ASCII z           ;Z17=char_z;
  VMOVDQU32     CONST_TAIL_MASK(),Z18     //;7DB21CB0 load tail_mask_data             ;Z18=tail_mask_data;
  VMOVDQU32     CONST_N_BYTES_UTF8(),Z24  //;B323211A load table_n_bytes_utf8         ;Z24=table_n_bytes_utf8;
  VPBROADCASTD  CONSTD_1(),Z10            //;6F57EE92 load constant 1                 ;Z10=1;
  VPADDD        Z10, Z10, Z6              //;00000000 constd_2 := 1 + 1               ;Z6=2; Z10=1;
  VPADDD        Z10, Z6,  Z7              //;00000000 constd_3 := 2 + 1               ;Z7=3; Z6=2; Z10=1;
  VPADDD        Z6,  Z6,  Z23             //;00000000 constd_4 := 2 + 2               ;Z23=4; Z6=2;
  VPXORD        Z11, Z11, Z11             //;81C90120 load constant 0                 ;Z11=0;
//; init variables loop2
  VPXORD        Z4,  Z4,  Z4              //;6D778B5D edit_dist := 0                  ;Z4=edit_dist;
  VPXORD        Z5,  Z5,  Z5              //;B150336A needle_off := 0                 ;Z5=needle_off;
  KMOVW         K1,  K2                   //;FBC36D43 lane_todo := lane_active        ;K2=lane_todo; K1=lane_active;
  KXORW         K1,  K1,  K1              //;1607AB46 lane_active := 0                ;K1=lane_active;
loop2:
//; load data unicode approx3
//; clear data0 and needle0
  VPTERNLOGD    $0b11111111,Z8,  Z8,  Z8  //;B8E7EDD5 set 0xFFFFFFFF                  ;Z8=d0;
  VPTERNLOGD    $0b11111111,Z9,  Z9,  Z9  //;A8E35E7F set 0xFFFFFFFF                  ;Z9=d1;
  VPTERNLOGD    $0b11111111,Z28, Z28, Z28 //;3CB765D7 set 0xFFFFFFFF                  ;Z28=d2;
//; load data0
  VPCMPD        $5,  Z10, Z3,  K2,  K3    //;FCFCB494 K3 := K2 & (data_len>=1)        ;K3=tmp_mask; K2=lane_todo; Z3=data_len; Z10=1; 5=GreaterEq;
  VPGATHERDD    (SI)(Z2*1),K3,  Z8        //;E4967C89 gather data0                    ;Z8=d0; K3=tmp_mask; SI=data_ptr; Z2=data_off;
//; get number of bytes in code-point
  VPSRLD        $4,  Z8,  Z26             //;FE5F1413 scratch1 := d0>>4               ;Z26=scratch1; Z8=d0;
  VPERMD        Z24, Z26, Z12             //;68FECBA0 get n_bytes_d0                  ;Z12=n_bytes_d0; Z26=scratch1; Z24=table_n_bytes_utf8;
//; load data1
  VPSUBD        Z12, Z3,  Z20             //;8BA4E60E data_len_alt := data_len - n_bytes_d0;Z20=data_len_alt; Z3=data_len; Z12=n_bytes_d0;
  VPCMPD        $5,  Z10, Z20, K2,  K3    //;FCFCB494 K3 := K2 & (data_len_alt>=1)    ;K3=tmp_mask; K2=lane_todo; Z20=data_len_alt; Z10=1; 5=GreaterEq;
  VPADDD        Z12, Z2,  K2,  Z19        //;88A5638D data_off_alt := data_off + n_bytes_d0;Z19=data_off_alt; K2=lane_todo; Z2=data_off; Z12=n_bytes_d0;
  VPGATHERDD    (SI)(Z19*1),K3,  Z9       //;81256F6A gather data1                    ;Z9=d1; K3=tmp_mask; SI=data_ptr; Z19=data_off_alt;
//; get number of bytes in code-point
  VPSRLD        $4,  Z9,  Z26             //;FE5F1413 scratch1 := d1>>4               ;Z26=scratch1; Z9=d1;
  VPERMD        Z24, Z26, Z22             //;68FECBA0 get n_bytes_d1                  ;Z22=n_bytes_d1; Z26=scratch1; Z24=table_n_bytes_utf8;
//; load data2
  VPSUBD        Z22, Z20, Z20             //;743C9E50 data_len_alt -= n_bytes_d1      ;Z20=data_len_alt; Z22=n_bytes_d1;
  VPCMPD        $5,  Z10, Z20, K2,  K3    //;C500A274 K3 := K2 & (data_len_alt>=1)    ;K3=tmp_mask; K2=lane_todo; Z20=data_len_alt; Z10=1; 5=GreaterEq;
  VPADDD        Z22, Z19, K2,  Z19        //;3656366C data_off_alt += n_bytes_d1      ;Z19=data_off_alt; K2=lane_todo; Z22=n_bytes_d1;
  VPGATHERDD    (SI)(Z19*1),K3,  Z28      //;3640A661 gather data2                    ;Z28=d2; K3=tmp_mask; SI=data_ptr; Z19=data_off_alt;
//; get number of bytes in code-point
  VPSRLD        $4,  Z28, Z26             //;FE5F1413 scratch1 := d2>>4               ;Z26=scratch1; Z28=d2;
  VPERMD        Z24, Z26, Z25             //;68FECBA0 get n_bytes_d2                  ;Z25=n_bytes_d2; Z26=scratch1; Z24=table_n_bytes_utf8;
//; load needles
  VPTERNLOGD    $0b11111111,Z19, Z19, Z19 //;9E9BD820 set 0xFFFFFFFF                  ;Z19=n0;
  VPTERNLOGD    $0b11111111,Z20, Z20, Z20 //;4408EAE3 set 0xFFFFFFFF                  ;Z20=n1;
  VPTERNLOGD    $0b11111111,Z21, Z21, Z21 //;61F40C30 set 0xFFFFFFFF                  ;Z21=n2;
  VPCMPD        $5,  Z10, Z13, K2,  K3    //;7C687BDA K3 := K2 & (needle_len>=1)      ;K3=tmp_mask; K2=lane_todo; Z13=needle_len; Z10=1; 5=GreaterEq;
  VPCMPD        $6,  Z10, Z13, K2,  K4    //;E2B17160 K4 := K2 & (needle_len>1)       ;K4=scratch1; K2=lane_todo; Z13=needle_len; Z10=1; 6=Greater;
  VPCMPD.BCST   $6,  CONSTD_2(),Z13, K2,  K5  //;62D5A597 K5 := K2 & (needle_len>2)   ;K5=scratch2; K2=lane_todo; Z13=needle_len; 6=Greater;
  VPGATHERDD    (R14)(Z5*1),K3,  Z19      //;4EAE4300 gather needle0                  ;Z19=n0; K3=tmp_mask; R14=needle_ptr; Z5=needle_off;
  VPGATHERDD    4(R14)(Z5*1),K4,  Z20     //;7F0BC8AC gather needle1                  ;Z20=n1; K4=scratch1; R14=needle_ptr; Z5=needle_off;
  VPGATHERDD    8(R14)(Z5*1),K5,  Z21     //;2FC91E09 gather needle2                  ;Z21=n2; K5=scratch2; R14=needle_ptr; Z5=needle_off;
//; remove tail from data
  VPERMD        Z18, Z12, Z26             //;83C76A20 get tail_mask (data)            ;Z26=scratch1; Z12=n_bytes_d0; Z18=tail_mask_data;
  VPERMD        Z18, Z22, Z27             //;46B49FFC get tail_mask (data)            ;Z27=scratch2; Z22=n_bytes_d1; Z18=tail_mask_data;
  VPERMD        Z18, Z25, Z29             //;38DC4AAA get tail_mask (data)            ;Z29=scratch3; Z25=n_bytes_d2; Z18=tail_mask_data;
  VPANDD        Z8,  Z26, Z8              //;D1E2261E mask data                       ;Z8=d0; Z26=scratch1;
  VPANDD        Z9,  Z27, Z9              //;A5CA4DE9 mask data                       ;Z9=d1; Z27=scratch2;
  VPANDD        Z28, Z29, Z28             //;C05E8C87 mask data                       ;Z28=d2; Z29=scratch3;
//; str_to_upper: IN zmm8; OUT zmm26
  VPCMPB        $5,  Z16, Z8,  K3         //;30E9B9FD K3 := (d0>=char_a)              ;K3=tmp_mask; Z8=d0; Z16=char_a; 5=GreaterEq;
  VPCMPB        $2,  Z17, Z8,  K3,  K3    //;8CE85BA0 K3 &= (d0<=char_z)              ;K3=tmp_mask; Z8=d0; Z17=char_z; 2=LessEq;
//; Z15 is 64 bytes with 0b00100000
//;    Z15|Z8 |Z26 => Z26
//;     0 | 0 | 0      0
//;     0 | 0 | 1      0
//;     0 | 1 | 0      1
//;     0 | 1 | 1      1
//;     1 | 0 | 0      0
//;     1 | 0 | 1      0
//;     1 | 1 | 0      1
//;     1 | 1 | 1      0     <= change from lower to upper
  VPMOVM2B      K3,  Z26                  //;ADC21F45 mask with selected chars        ;Z26=scratch1; K3=tmp_mask;
  VPTERNLOGD    $0b01001100,Z15, Z8,  Z26 //;1BB96D97                                 ;Z26=scratch1; Z8=d0; Z15=c_0b00100000;
  VMOVDQA32     Z26, Z8                   //;41954CFC d0 := scratch1                  ;Z8=d0; Z26=scratch1;
//; str_to_upper: IN zmm9; OUT zmm27
  VPCMPB        $5,  Z16, Z9,  K3         //;30E9B9FD K3 := (d1>=char_a)              ;K3=tmp_mask; Z9=d1; Z16=char_a; 5=GreaterEq;
  VPCMPB        $2,  Z17, Z9,  K3,  K3    //;8CE85BA0 K3 &= (d1<=char_z)              ;K3=tmp_mask; Z9=d1; Z17=char_z; 2=LessEq;
//; Z15 is 64 bytes with 0b00100000
//;    Z15|Z8 |Z26 => Z26
//;     0 | 0 | 0      0
//;     0 | 0 | 1      0
//;     0 | 1 | 0      1
//;     0 | 1 | 1      1
//;     1 | 0 | 0      0
//;     1 | 0 | 1      0
//;     1 | 1 | 0      1
//;     1 | 1 | 1      0     <= change from lower to upper
  VPMOVM2B      K3,  Z27                  //;ADC21F45 mask with selected chars        ;Z27=scratch2; K3=tmp_mask;
  VPTERNLOGD    $0b01001100,Z15, Z9,  Z27 //;1BB96D97                                 ;Z27=scratch2; Z9=d1; Z15=c_0b00100000;
  VMOVDQA32     Z27, Z9                   //;60AA018C d1 := scratch2                  ;Z9=d1; Z27=scratch2;
//; str_to_upper: IN zmm28; OUT zmm29
  VPCMPB        $5,  Z16, Z28, K3         //;30E9B9FD K3 := (d2>=char_a)              ;K3=tmp_mask; Z28=d2; Z16=char_a; 5=GreaterEq;
  VPCMPB        $2,  Z17, Z28, K3,  K3    //;8CE85BA0 K3 &= (d2<=char_z)              ;K3=tmp_mask; Z28=d2; Z17=char_z; 2=LessEq;
//; Z15 is 64 bytes with 0b00100000
//;    Z15|Z8 |Z26 => Z26
//;     0 | 0 | 0      0
//;     0 | 0 | 1      0
//;     0 | 1 | 0      1
//;     0 | 1 | 1      1
//;     1 | 0 | 0      0
//;     1 | 0 | 1      0
//;     1 | 1 | 0      1
//;     1 | 1 | 1      0     <= change from lower to upper
  VPMOVM2B      K3,  Z29                  //;ADC21F45 mask with selected chars        ;Z29=scratch3; K3=tmp_mask;
  VPTERNLOGD    $0b01001100,Z15, Z28, Z29 //;1BB96D97                                 ;Z29=scratch3; Z28=d2; Z15=c_0b00100000;
  VMOVDQA32     Z29, Z28                  //;250F442B d2 := scratch3                  ;Z28=d2; Z29=scratch3;
//; create key with bits for NeedleData:02-12-22-21-01-11-10-20-00
  VPCMPD        $0,  Z28, Z21, K3         //;00000000 K3 := (n2==d2)                  ;K3=tmp_mask; Z21=n2; Z28=d2; 0=Eq;
  VPCMPD        $0,  Z9,  Z21, K4         //;00000000 K4 := (n2==d1)                  ;K4=scratch1; Z21=n2; Z9=d1; 0=Eq;
  VPCMPD        $0,  Z8,  Z21, K5         //;00000000 K5 := (n2==d0)                  ;K5=scratch2; Z21=n2; Z8=d0; 0=Eq;
  VPSLLD.Z      $6,  Z10, K3,  Z21        //;00000000 key := 1<<6                     ;Z21=key; K3=tmp_mask; Z10=1;
  VPSLLD.Z      $5,  Z10, K4,  Z27        //;00000000 scratch2 := 1<<5                ;Z27=scratch2; K4=scratch1; Z10=1;
  VPSLLD.Z      $1,  Z10, K5,  Z29        //;00000000 scratch3 := 1<<1                ;Z29=scratch3; K5=scratch2; Z10=1;
  VPTERNLOGD    $0b11111110,Z29, Z27, Z21 //;00000000                                 ;Z21=key; Z27=scratch2; Z29=scratch3;

  VPCMPD        $0,  Z28, Z20, K3         //;00000000 K3 := (n1==d2)                  ;K3=tmp_mask; Z20=n1; Z28=d2; 0=Eq;
  VPCMPD        $0,  Z9,  Z20, K4         //;00000000 K4 := (n1==d1)                  ;K4=scratch1; Z20=n1; Z9=d1; 0=Eq;
  VPCMPD        $0,  Z8,  Z20, K5         //;00000000 K5 := (n1==d0)                  ;K5=scratch2; Z20=n1; Z8=d0; 0=Eq;
  VPSLLD.Z      $7,  Z10, K3,  Z27        //;00000000 scratch2 := 1<<7                ;Z27=scratch2; K3=tmp_mask; Z10=1;
  VPSLLD.Z      $3,  Z10, K4,  Z26        //;00000000 scratch1 := 1<<3                ;Z26=scratch1; K4=scratch1; Z10=1;
  VPSLLD.Z      $2,  Z10, K5,  Z29        //;00000000 scratch3 := 1<<2                ;Z29=scratch3; K5=scratch2; Z10=1;
  VPORD         Z26, Z27, Z27             //;00000000 scratch2 |= scratch1            ;Z27=scratch2; Z26=scratch1;
  VPTERNLOGD    $0b11111110,Z29, Z27, Z21 //;00000000                                 ;Z21=key; Z27=scratch2; Z29=scratch3;

  VPCMPD        $0,  Z28, Z19, K3         //;00000000 K3 := (n0==d2)                  ;K3=tmp_mask; Z19=n0; Z28=d2; 0=Eq;
  VPCMPD        $0,  Z9,  Z19, K4         //;00000000 K4 := (n0==d1)                  ;K4=scratch1; Z19=n0; Z9=d1; 0=Eq;
  VPCMPD        $0,  Z8,  Z19, K5         //;00000000 K5 := (n0==d0)                  ;K5=scratch2; Z19=n0; Z8=d0; 0=Eq;
  VPSLLD.Z      $8,  Z10, K3,  Z29        //;00000000 scratch3 := 1<<8                ;Z29=scratch3; K3=tmp_mask; Z10=1;
  VPSLLD.Z      $4,  Z10, K4,  Z27        //;00000000 scratch2 := 1<<4                ;Z27=scratch2; K4=scratch1; Z10=1;
  VPSLLD.Z      $0,  Z10, K5,  Z26        //;00000000 scratch1 := 1<<0                ;Z26=scratch1; K5=scratch2; Z10=1;
  VPORD         Z26, Z27, Z27             //;00000000 scratch2 |= scratch1            ;Z27=scratch2; Z26=scratch1;
  VPTERNLOGD    $0b11111110,Z29, Z27, Z21 //;00000000                                 ;Z21=key; Z27=scratch2; Z29=scratch3;

//; do the lookup of the advance values
  KMOVW         K2,  K3                   //;45A99B90 tmp_mask := lane_todo           ;K3=tmp_mask; K2=lane_todo;
  VPGATHERDD    (R15)(Z21*1),K3,  Z26     //;C3AEFFBF                                 ;Z26=scratch1; K3=tmp_mask; R15=update_data_ptr; Z21=key;
//; unpack results
  VPSRLD        $4,  Z26, Z19             //;87E05D1F ed_delta := scratch1>>4         ;Z19=ed_delta; Z26=scratch1;
  VPSRLD        $2,  Z26, Z21             //;13C921F9 adv_needle := scratch1>>2       ;Z21=adv_needle; Z26=scratch1;
  VPANDD        Z7,  Z19, Z19             //;A7E1848A ed_delta &= 3                   ;Z19=ed_delta; Z7=3;
  VPANDD        Z7,  Z26, Z20             //;42B9DA14 adv_data := scratch1 & 3        ;Z20=adv_data; Z26=scratch1; Z7=3;
  VPANDD        Z7,  Z21, Z21             //;E2CB942A adv_needle &= 3                 ;Z21=adv_needle; Z7=3;
//; update unicode approx3
//; update edit distance
  VPADDD        Z4,  Z19, Z4              //;15747D59 edit_dist += ed_delta           ;Z4=edit_dist; Z19=ed_delta;
//; advance data
  VPCMPD        $5,  Z10, Z20, K2,  K3    //;7FC1A433 K3 := K2 & (adv_data>=1)        ;K3=tmp_mask; K2=lane_todo; Z20=adv_data; Z10=1; 5=GreaterEq;
  VMOVDQA32.Z   Z12, K3,  Z26             //;6428B608 scratch1 := n_bytes_d0          ;Z26=scratch1; K3=tmp_mask; Z12=n_bytes_d0;
  VPCMPD        $5,  Z6,  Z20, K2,  K3    //;4FC83ED2 K3 := K2 & (adv_data>=2)        ;K3=tmp_mask; K2=lane_todo; Z20=adv_data; Z6=2; 5=GreaterEq;
  VPADDD        Z22, Z26, K3,  Z26        //;BAE14871 scratch1 += n_bytes_d1          ;Z26=scratch1; K3=tmp_mask; Z22=n_bytes_d1;
  VPCMPD        $5,  Z7,  Z20, K2,  K3    //;120E0569 K3 := K2 & (adv_data>=3)        ;K3=tmp_mask; K2=lane_todo; Z20=adv_data; Z7=3; 5=GreaterEq;
  VPADDD        Z25, Z26, K3,  Z26        //;9BAA69A9 scratch1 += n_bytes_d2          ;Z26=scratch1; K3=tmp_mask; Z25=n_bytes_d2;
  VPSUBD        Z26, Z3,  K2,  Z3         //;DF7FB44E data_len -= scratch1            ;Z3=data_len; K2=lane_todo; Z26=scratch1;
  VPADDD        Z26, Z2,  K2,  Z2         //;F81C97B0 data_off += scratch1            ;Z2=data_off; K2=lane_todo; Z26=scratch1;
//; advance needle
  VPCMPD        $5,  Z10, Z21, K2,  K3    //;5578190E K3 := K2 & (adv_needle>=1)      ;K3=tmp_mask; K2=lane_todo; Z21=adv_needle; Z10=1; 5=GreaterEq;
  VMOVDQA32.Z   Z23, K3,  Z26             //;00000000 scratch1 := 4                   ;Z26=scratch1; K3=tmp_mask; Z23=4;
  VPCMPD        $5,  Z6,  Z21, K2,  K3    //;A814294A K3 := K2 & (adv_needle>=2)      ;K3=tmp_mask; K2=lane_todo; Z21=adv_needle; Z6=2; 5=GreaterEq;
  VPADDD        Z23, Z26, K3,  Z26        //;B2BE82E2 scratch1 += 4                   ;Z26=scratch1; K3=tmp_mask; Z23=4;
  VPSUBD        Z21, Z13, K2,  Z13        //;41970AC0 needle_len -= adv_needle        ;Z13=needle_len; K2=lane_todo; Z21=adv_needle;
  VPADDD        Z26, Z5,  K2,  Z5         //;89331149 needle_off += scratch1          ;Z5=needle_off; K2=lane_todo; Z26=scratch1;
//; cmp-tail
//; restrict lanes based on edit distance and threshold
  VPCMPD        $2,  Z14, Z4,  K2,  K2    //;86F95312 K2 &= (edit_dist<=threshold)    ;K2=lane_todo; Z4=edit_dist; Z14=threshold; 2=LessEq;
//; test if we have a match
  VPCMPD        $5,  Z13, Z11, K2,  K3    //;EEF4BAA0 K3 := K2 & (0>=needle_len)      ;K3=tmp_mask; K2=lane_todo; Z11=0; Z13=needle_len; 5=GreaterEq;
  VPCMPD        $5,  Z3,  Z11, K3,  K3    //;4CCAC6C8 K3 &= (0>=data_len)             ;K3=tmp_mask; Z11=0; Z3=data_len; 5=GreaterEq;
  KORW          K1,  K3,  K1              //;8FAB61CD lane_active |= tmp_mask         ;K1=lane_active; K3=tmp_mask;
  KANDNW        K2,  K3,  K2              //;482703BD lane_todo &= ~tmp_mask          ;K2=lane_todo; K3=tmp_mask;
  KTESTW        K2,  K2                   //;4661A15A any lanes still todo?           ;K2=lane_todo;
  JNZ           loop2                     //;28307DE7 yes, then loop; jump if not zero (ZF = 0);
next:
  NEXT()
//; #endregion bcCmpStrFuzzyUnicodeA3

//; #region bcHasSubstrFuzzyA3
TEXT bcHasSubstrFuzzyA3(SB), NOSPLIT|NOFRAME, $0
  IMM_FROM_DICT(R15)                      //;05667C35 load *[]byte with the provided str into R15
//; load parameters
  MOVQ          (R15),R15                 //;D2647DF0 load needle_ptr                 ;R15=update_data_ptr;
  MOVQ          R15, R14                  //;EC3C3E7D needle_ptr := update_data_ptr   ;R14=needle_ptr; R15=update_data_ptr;
  ADDQ          $512,R14                  //;46443C9E needle_ptr += 512               ;R14=needle_ptr;
  VPBROADCASTD  (R14),Z13                 //;713DF24F bcst needle_len                 ;Z13=needle_len; R14=needle_ptr;
  ADDQ          $4,  R14                  //;B63DFEAF needle_ptr += 4                 ;R14=needle_ptr;
//; load from stack-slot: load 16x uint32 into Z14
  LOADARG1Z(Z27, Z26)
  VPMOVQD       Z27, Y27                  //;17FCB103 truncate uint64 to uint32       ;Z27=scratch2;
  VPMOVQD       Z26, Y26                  //;8F762E8E truncate uint64 to uint32       ;Z26=scratch1;
  VINSERTI64X4  $1,  Y26, Z27, Z14        //;3944001B merge into 16x uint32           ;Z14=threshold; Z27=scratch2; Z26=scratch1;
//; restrict lanes to allow fast bail-out
  VPSUBD        Z14, Z13, Z26             //;10B77777 scratch1 := needle_len - threshold;Z26=scratch1; Z13=needle_len; Z14=threshold;
  VPCMPD        $2,  Z3,  Z26, K1,  K1    //;F08352A0 K1 &= (scratch1<=data_len)      ;K1=lane_active; Z26=scratch1; Z3=data_len; 2=LessEq;
  KTESTW        K1,  K1                   //;8BEF97CD ZF := (K1==0); CF := 1          ;K1=lane_active;
  JZ            next                      //;5FEF8EC0 jump if zero (ZF = 1)           ;
//; load constants
  VPBROADCASTB  CONSTB_32(),Z15           //;5B8F2908 load constant 0b00100000        ;Z15=c_0b00100000;
  VPBROADCASTB  CONSTB_97(),Z16           //;5D5B0014 load constant ASCII a           ;Z16=char_a;
  VPBROADCASTB  CONSTB_122(),Z17          //;8E2ED824 load constant ASCII z           ;Z17=char_z;
  VPBROADCASTD  CONSTD_3(),Z24            //;6F57EE92 load constant 3                 ;Z24=3;
  VPBROADCASTD  CONSTD_0x10101(),Z19      //;2AB82DC0 load constant 0x10101           ;Z19=0x10101;
  VPBROADCASTD  CONSTD_0x10801(),Z22      //;A76098A3 load constant 0x10801           ;Z22=0x10801;
  VPBROADCASTD  CONSTD_0x400001(),Z23     //;3267BFF0 load constant 0x400001          ;Z23=0x400001;
  VPSLLD        $1,  Z19, Z20             //;68F49F35 0x20202 := 0x10101<<1           ;Z20=0x20202; Z19=0x10101;
  VPSLLD        $2,  Z19, Z21             //;2789BA9D 0x40404 := 0x10101<<2           ;Z21=0x40404; Z19=0x10101;
  VMOVDQU32     CONST_TAIL_INV_MASK(),Z18 //;9653E713 load tail_inv_mask_data         ;Z18=tail_mask_data;
  VMOVDQU32     FUZZY_ROR_APPROX3(),Z25   //;2CEF25D2 load ror approx3                ;Z25=ror_a3;
  VPBROADCASTD  CONSTD_1(),Z10            //;6F57EE92 load constant 1                 ;Z10=1;
  VPXORD        Z11, Z11, Z11             //;81C90120 load constant 0                 ;Z11=0;
//; init variables loop2
  KMOVW         K1,  K2                   //;FBC36D43 lane_todo := lane_active        ;K2=lane_todo; K1=lane_active;
  KXORW         K1,  K1,  K1              //;1607AB46 lane_active := 0                ;K1=lane_active;
  VMOVDQA32     Z2,  Z12                  //;467EBBBC data_off2 := data_off           ;Z12=data_off2; Z2=data_off;
  VMOVDQA32     Z3,  Z6                   //;DD42E20B data_len2 := data_len           ;Z6=data_len2; Z3=data_len;
  VMOVDQA32     Z13, Z7                   //;29B33C21 needle_len2 := needle_len       ;Z7=needle_len2; Z13=needle_len;
loop2:
//; init variables loop1
  VPXORD        Z4,  Z4,  Z4              //;6D778B5D edit_dist := 0                  ;Z4=edit_dist;
  VPXORD        Z5,  Z5,  Z5              //;B150336A needle_off := 0                 ;Z5=needle_off;
  KMOVW         K2,  K6                   //;FDBD9EFA lane_todo2 := lane_todo         ;K6=lane_todo2; K2=lane_todo;
loop1:
//; load data ascii approx3
//; clear data
  VPTERNLOGD    $0b11111111,Z8,  Z8,  Z8  //;F81949DF set 0xFFFFFFFF                  ;Z8=data;
  VPTERNLOGD    $0b11111111,Z9,  Z9,  Z9  //;9E9BD820 set 0xFFFFFFFF                  ;Z9=needle;
//; load data and needle
  VPCMPD        $6,  Z11, Z6,  K6,  K4    //;FCFCB494 K4 := K6 & (data_len2>0)        ;K4=scratch1; K6=lane_todo2; Z6=data_len2; Z11=0; 6=Greater;
  VPCMPD        $6,  Z11, Z13, K6,  K5    //;7C687BDA K5 := K6 & (needle_len>0)       ;K5=scratch2; K6=lane_todo2; Z13=needle_len; Z11=0; 6=Greater;
  KMOVW         K4,  K3                   //;723D04C9 copy eligible lanes             ;K3=tmp_mask; K4=scratch1;
  VPGATHERDD    (SI)(Z12*1),K3,  Z8       //;E4967C89 gather data                     ;Z8=data; K3=tmp_mask; SI=data_ptr; Z12=data_off2;
  VPGATHERDD    (R14)(Z5*1),K5,  Z9       //;4EAE4300 gather needle                   ;Z9=needle; K5=scratch2; R14=needle_ptr; Z5=needle_off;
//; remove tail from data
  VPMINSD       Z6,  Z24, Z26             //;D337D11D scratch1 := min(3, data_len2)   ;Z26=scratch1; Z24=3; Z6=data_len2;
  VPERMD        Z18, Z26, Z26             //;E882D550                                 ;Z26=scratch1; Z18=tail_mask_data;
  VPORD         Z8,  Z26, K4,  Z8         //;985B667B data |= scratch1                ;Z8=data; K4=scratch1; Z26=scratch1;
//; str_to_upper: IN zmm8; OUT zmm26
  VPCMPB        $5,  Z16, Z8,  K3         //;30E9B9FD K3 := (data>=char_a)            ;K3=tmp_mask; Z8=data; Z16=char_a; 5=GreaterEq;
  VPCMPB        $2,  Z17, Z8,  K3,  K3    //;8CE85BA0 K3 &= (data<=char_z)            ;K3=tmp_mask; Z8=data; Z17=char_z; 2=LessEq;
//; Z15 is 64 bytes with 0b00100000
//;    Z15|Z8 |Z26 => Z26
//;     0 | 0 | 0      0
//;     0 | 0 | 1      0
//;     0 | 1 | 0      1
//;     0 | 1 | 1      1
//;     1 | 0 | 0      0
//;     1 | 0 | 1      0
//;     1 | 1 | 0      1
//;     1 | 1 | 1      0     <= change from lower to upper
  VPMOVM2B      K3,  Z26                  //;ADC21F45 mask with selected chars        ;Z26=scratch1; K3=tmp_mask;
  VPTERNLOGD    $0b01001100,Z15, Z8,  Z26 //;1BB96D97                                 ;Z26=scratch1; Z8=data; Z15=c_0b00100000;
//; prepare data
  VPSHUFB       Z25, Z9,  Z27             //;9E2DA720                                 ;Z27=scratch2; Z9=needle; Z25=ror_a3;
  VPSHUFB       Z25, Z27, Z28             //;EF2A718F                                 ;Z28=scratch3; Z27=scratch2; Z25=ror_a3;
//; compare data
  VPCMPB        $0,  Z26, Z9,  K3         //;B72E9264 K3 := (needle==scratch1)        ;K3=tmp_mask; Z9=needle; Z26=scratch1; 0=Eq;
  VPCMPB        $0,  Z26, Z27, K4         //;4D744078 K4 := (scratch2==scratch1)      ;K4=scratch1; Z27=scratch2; Z26=scratch1; 0=Eq;
  VPCMPB        $0,  Z26, Z28, K5         //;7D453022 K5 := (scratch3==scratch1)      ;K5=scratch2; Z28=scratch3; Z26=scratch1; 0=Eq;
  VPBROADCASTD  CONSTD_0xFF(),Z27         //;8826339E load constant 0xFF              ;Z27=const_0xFF;
//; fuzzy kernel approx3: create lookup key in Z26
  VMOVDQU8.Z    Z19, K3,  Z26             //;AE601720 0000_0000 0000_000a 0000_000b 0000_000c;Z26=scratch1; K3=tmp_mask; Z19=0x10101;
  VMOVDQU8.Z    Z20, K4,  Z27             //;C8E83855 0000_0000 0000_00d0 0000_00e0 0000_00f0;Z27=scratch2; K4=scratch1; Z20=0x20202;
  VMOVDQU8.Z    Z21, K5,  Z29             //;1AA38791 0000_0000 0000_0g00 0000_0h00 0000_0i00;Z29=scratch4; K5=scratch2; Z21=0x40404;
  VPTERNLOGD    $0b11111110,Z29, Z27, Z26 //;FF99B822 0000_0000 0000_0gda 0000_0heb 0000_0ifc;Z26=scratch1; Z27=scratch2; Z29=scratch4;
  VPMADDUBSW    Z26, Z22, Z26             //;6483F13D 0000_0000 0000_0gda 0000_0000 00he_bifc;Z26=scratch1; Z22=0x10801;
  VPMADDWD      Z26, Z23, Z26             //;3FA33058 0000_0000 0000_0000 0000_000g dahe_bifc;Z26=scratch1; Z23=0x400001;
//; do the lookup of the advance values
  KMOVW         K6,  K3                   //;45A99B90 tmp_mask := lane_todo2          ;K3=tmp_mask; K6=lane_todo2;
  VPGATHERDD    (R15)(Z26*1),K3,  Z27     //;C3AEFFBF                                 ;Z27=scratch2; K3=tmp_mask; R15=update_data_ptr; Z26=scratch1;
//; unpack results
  VPSRLD        $4,  Z27, Z28             //;87E05D1F ed_delta := scratch2>>4         ;Z28=ed_delta; Z27=scratch2;
  VPSRLD        $2,  Z27, Z9              //;13C921F9 adv_needle := scratch2>>2       ;Z9=adv_needle; Z27=scratch2;
  VPANDD        Z24, Z28, Z28             //;A7E1848A ed_delta &= 3                   ;Z28=ed_delta; Z24=3;
  VPANDD        Z24, Z27, Z8              //;42B9DA14 adv_data := scratch2 & 3        ;Z8=adv_data; Z27=scratch2; Z24=3;
  VPANDD        Z24, Z9,  Z9              //;E2CB942A adv_needle &= 3                 ;Z9=adv_needle; Z24=3;
//; update ascii
//; update edit distance
  VPADDD        Z28, Z4,  K6,  Z4         //;F07EA991 edit_dist += ed_delta           ;Z4=edit_dist; K6=lane_todo2; Z28=ed_delta;
//; advance data
  VPSUBD        Z8,  Z6,  K6,  Z6         //;DF7FB44E data_len2 -= adv_data           ;Z6=data_len2; K6=lane_todo2; Z8=adv_data;
  VPADDD        Z8,  Z12, K6,  Z12        //;F81C97B0 data_off2 += adv_data           ;Z12=data_off2; K6=lane_todo2; Z8=adv_data;
//; advance needle
  VPSUBD        Z9,  Z7,  K6,  Z7         //;41970AC0 needle_len2 -= adv_needle       ;Z7=needle_len2; K6=lane_todo2; Z9=adv_needle;
  VPADDD        Z9,  Z5,  K6,  Z5         //;254FD5C6 needle_off += adv_needle        ;Z5=needle_off; K6=lane_todo2; Z9=adv_needle;
//; has-tail
//; restrict lanes based on edit distance and threshold
  VPCMPD        $2,  Z14, Z4,  K6,  K6    //;86F95312 K6 &= (edit_dist<=threshold)    ;K6=lane_todo2; Z4=edit_dist; Z14=threshold; 2=LessEq;
//; test if we have a match
  VPCMPD        $5,  Z7,  Z11, K6,  K3    //;EEF4BAA0 K3 := K6 & (0>=needle_len2)     ;K3=tmp_mask; K6=lane_todo2; Z11=0; Z7=needle_len2; 5=GreaterEq;
  KANDNW        K6,  K3,  K6              //;482703BD lane_todo2 &= ~tmp_mask         ;K6=lane_todo2; K3=tmp_mask;
  KORW          K1,  K3,  K1              //;8FAB61CD lane_active |= tmp_mask         ;K1=lane_active; K3=tmp_mask;
  KTESTW        K6,  K6                   //;9D3A860D any lanes still todo?           ;K6=lane_todo2;
  JNZ           loop1                     //;EA12C247 yes, then loop; jump if not zero (ZF = 0);

  KANDNW        K2,  K6,  K2              //;E3BAA7D5 lane_todo &= ~lane_todo2        ;K2=lane_todo; K6=lane_todo2;
  VPSUBD        Z10, Z3,  K2,  Z3         //;7C100DFB data_len--                      ;Z3=data_len; K2=lane_todo; Z10=1;
  VPADDD        Z10, Z2,  K2,  Z2         //;397684ED data_off++                      ;Z2=data_off; K2=lane_todo; Z10=1;
  VPCMPD        $6,  Z11, Z3,  K2,  K2    //;591E80A4 K2 &= (data_len>0)              ;K2=lane_todo; Z3=data_len; Z11=0; 6=Greater;
//; reset variables for loop2
  VMOVDQA32     Z3,  Z6                   //;1C31BFD8 data_len2 := data_len           ;Z6=data_len2; Z3=data_len;
  VMOVDQA32     Z2,  Z12                  //;3B8A334A data_off2 := data_off           ;Z12=data_off2; Z2=data_off;
  VMOVDQA32     Z13, Z7                   //;8EFD9390 needle_len2 := needle_len       ;Z7=needle_len2; Z13=needle_len;
  KTESTW        K2,  K2                   //;4661A15A any lanes still todo?           ;K2=lane_todo;
  JNZ           loop2                     //;28307DE7 yes, then loop; jump if not zero (ZF = 0);
next:
  NEXT()
//; #endregion bcHasSubstrFuzzyA3

//; #region bcHasSubstrFuzzyUnicodeA3
TEXT bcHasSubstrFuzzyUnicodeA3(SB), NOSPLIT|NOFRAME, $0
  IMM_FROM_DICT(R15)                      //;05667C35 load *[]byte with the provided str into R15
//; load parameters
  MOVQ          (R15),R15                 //;D2647DF0 load needle_ptr                 ;R15=update_data_ptr;
  MOVQ          R15, R14                  //;EC3C3E7D needle_ptr := update_data_ptr   ;R14=needle_ptr; R15=update_data_ptr;
  ADDQ          $512,R14                  //;46443C9E needle_ptr += 512               ;R14=needle_ptr;
  VPBROADCASTD  (R14),Z13                 //;713DF24F bcst needle_len                 ;Z13=needle_len; R14=needle_ptr;
  ADDQ          $4,  R14                  //;B63DFEAF needle_ptr += 4                 ;R14=needle_ptr;
//; load from stack-slot: load 16x uint32 into Z14
  LOADARG1Z(Z27, Z26)
  VPMOVQD       Z27, Y27                  //;17FCB103 truncate uint64 to uint32       ;Z27=scratch2;
  VPMOVQD       Z26, Y26                  //;8F762E8E truncate uint64 to uint32       ;Z26=scratch1;
  VINSERTI64X4  $1,  Y26, Z27, Z14        //;3944001B merge into 16x uint32           ;Z14=threshold; Z27=scratch2; Z26=scratch1;
//; load constants
  VPBROADCASTB  CONSTB_32(),Z15           //;5B8F2908 load constant 0b00100000        ;Z15=c_0b00100000;
  VPBROADCASTB  CONSTB_97(),Z16           //;5D5B0014 load constant ASCII a           ;Z16=char_a;
  VPBROADCASTB  CONSTB_122(),Z17          //;8E2ED824 load constant ASCII z           ;Z17=char_z;
  VMOVDQU32     CONST_TAIL_MASK(),Z18     //;7DB21CB0 load tail_mask_data             ;Z18=tail_mask_data;
  VMOVDQU32     CONST_N_BYTES_UTF8(),Z24  //;B323211A load table_n_bytes_utf8         ;Z24=table_n_bytes_utf8;
  VPBROADCASTD  CONSTD_1(),Z10            //;6F57EE92 load constant 1                 ;Z10=1;
  VPXORD        Z11, Z11, Z11             //;81C90120 load constant 0                 ;Z11=0;
//; init variables loop2
  KMOVW         K1,  K2                   //;FBC36D43 lane_todo := lane_active        ;K2=lane_todo; K1=lane_active;
  KXORW         K1,  K1,  K1              //;1607AB46 lane_active := 0                ;K1=lane_active;
  VMOVDQA32     Z2,  Z6                   //;467EBBBC data_off2 := data_off           ;Z6=data_off2; Z2=data_off;
  VMOVDQA32     Z3,  Z23                  //;DD42E20B data_len2 := data_len           ;Z23=data_len2; Z3=data_len;
  VMOVDQA32     Z13, Z7                   //;29B33C21 needle_len2 := needle_len       ;Z7=needle_len2; Z13=needle_len;
loop2:
//; init variables loop1
  VPXORD        Z4,  Z4,  Z4              //;6D778B5D edit_dist := 0                  ;Z4=edit_dist;
  VPXORD        Z5,  Z5,  Z5              //;B150336A needle_off := 0                 ;Z5=needle_off;
  KMOVW         K2,  K6                   //;FDBD9EFA lane_todo2 := lane_todo         ;K6=lane_todo2; K2=lane_todo;
loop1:
//; load data unicode approx3
//; clear data0 and needle0
  VPTERNLOGD    $0b11111111,Z8,  Z8,  Z8  //;B8E7EDD5 set 0xFFFFFFFF                  ;Z8=d0;
  VPTERNLOGD    $0b11111111,Z9,  Z9,  Z9  //;A8E35E7F set 0xFFFFFFFF                  ;Z9=d1;
  VPTERNLOGD    $0b11111111,Z28, Z28, Z28 //;3CB765D7 set 0xFFFFFFFF                  ;Z28=d2;
//; load data0
  VPCMPD        $5,  Z10, Z23, K6,  K3    //;FCFCB494 K3 := K6 & (data_len2>=1)       ;K3=tmp_mask; K6=lane_todo2; Z23=data_len2; Z10=1; 5=GreaterEq;
  VPGATHERDD    (SI)(Z6*1),K3,  Z8        //;E4967C89 gather data0                    ;Z8=d0; K3=tmp_mask; SI=data_ptr; Z6=data_off2;
//; get number of bytes in code-point
  VPSRLD        $4,  Z8,  Z26             //;FE5F1413 scratch1 := d0>>4               ;Z26=scratch1; Z8=d0;
  VPERMD        Z24, Z26, Z12             //;68FECBA0 get n_bytes_d0                  ;Z12=n_bytes_d0; Z26=scratch1; Z24=table_n_bytes_utf8;
//; load data1
  VPSUBD        Z12, Z23, Z20             //;8BA4E60E data_len_alt := data_len2 - n_bytes_d0;Z20=data_len_alt; Z23=data_len2; Z12=n_bytes_d0;
  VPCMPD        $5,  Z10, Z20, K6,  K3    //;FCFCB494 K3 := K6 & (data_len_alt>=1)    ;K3=tmp_mask; K6=lane_todo2; Z20=data_len_alt; Z10=1; 5=GreaterEq;
  VPADDD        Z12, Z6,  K6,  Z19        //;88A5638D data_off_alt := data_off2 + n_bytes_d0;Z19=data_off_alt; K6=lane_todo2; Z6=data_off2; Z12=n_bytes_d0;
  VPGATHERDD    (SI)(Z19*1),K3,  Z9       //;81256F6A gather data1                    ;Z9=d1; K3=tmp_mask; SI=data_ptr; Z19=data_off_alt;
//; get number of bytes in code-point
  VPSRLD        $4,  Z9,  Z26             //;FE5F1413 scratch1 := d1>>4               ;Z26=scratch1; Z9=d1;
  VPERMD        Z24, Z26, Z22             //;68FECBA0 get n_bytes_d1                  ;Z22=n_bytes_d1; Z26=scratch1; Z24=table_n_bytes_utf8;
//; load data2
  VPSUBD        Z22, Z20, Z20             //;743C9E50 data_len_alt -= n_bytes_d1      ;Z20=data_len_alt; Z22=n_bytes_d1;
  VPCMPD        $5,  Z10, Z20, K6,  K3    //;C500A274 K3 := K6 & (data_len_alt>=1)    ;K3=tmp_mask; K6=lane_todo2; Z20=data_len_alt; Z10=1; 5=GreaterEq;
  VPADDD        Z22, Z19, K6,  Z19        //;3656366C data_off_alt += n_bytes_d1      ;Z19=data_off_alt; K6=lane_todo2; Z22=n_bytes_d1;
  VPGATHERDD    (SI)(Z19*1),K3,  Z28      //;3640A661 gather data2                    ;Z28=d2; K3=tmp_mask; SI=data_ptr; Z19=data_off_alt;
//; get number of bytes in code-point
  VPSRLD        $4,  Z28, Z26             //;FE5F1413 scratch1 := d2>>4               ;Z26=scratch1; Z28=d2;
  VPERMD        Z24, Z26, Z25             //;68FECBA0 get n_bytes_d2                  ;Z25=n_bytes_d2; Z26=scratch1; Z24=table_n_bytes_utf8;
//; load needles
  VPTERNLOGD    $0b11111111,Z19, Z19, Z19 //;9E9BD820 set 0xFFFFFFFF                  ;Z19=n0;
  VPTERNLOGD    $0b11111111,Z20, Z20, Z20 //;4408EAE3 set 0xFFFFFFFF                  ;Z20=n1;
  VPTERNLOGD    $0b11111111,Z21, Z21, Z21 //;61F40C30 set 0xFFFFFFFF                  ;Z21=n2;
  VPCMPD        $5,  Z10, Z7,  K6,  K3    //;7C687BDA K3 := K6 & (needle_len2>=1)     ;K3=tmp_mask; K6=lane_todo2; Z7=needle_len2; Z10=1; 5=GreaterEq;
  VPCMPD        $6,  Z10, Z7,  K6,  K4    //;E2B17160 K4 := K6 & (needle_len2>1)      ;K4=scratch1; K6=lane_todo2; Z7=needle_len2; Z10=1; 6=Greater;
  VPCMPD.BCST   $6,  CONSTD_2(),Z7,  K6,  K5  //;62D5A597 K5 := K6 & (needle_len2>2)  ;K5=scratch2; K6=lane_todo2; Z7=needle_len2; 6=Greater;
  VPGATHERDD    (R14)(Z5*1),K3,  Z19      //;4EAE4300 gather needle0                  ;Z19=n0; K3=tmp_mask; R14=needle_ptr; Z5=needle_off;
  VPGATHERDD    4(R14)(Z5*1),K4,  Z20     //;7F0BC8AC gather needle1                  ;Z20=n1; K4=scratch1; R14=needle_ptr; Z5=needle_off;
  VPGATHERDD    8(R14)(Z5*1),K5,  Z21     //;2FC91E09 gather needle2                  ;Z21=n2; K5=scratch2; R14=needle_ptr; Z5=needle_off;
//; remove tail from data
  VPERMD        Z18, Z12, Z26             //;83C76A20 get tail_mask (data)            ;Z26=scratch1; Z12=n_bytes_d0; Z18=tail_mask_data;
  VPERMD        Z18, Z22, Z27             //;46B49FFC get tail_mask (data)            ;Z27=scratch2; Z22=n_bytes_d1; Z18=tail_mask_data;
  VPERMD        Z18, Z25, Z29             //;38DC4AAA get tail_mask (data)            ;Z29=scratch3; Z25=n_bytes_d2; Z18=tail_mask_data;
  VPANDD        Z8,  Z26, Z8              //;D1E2261E mask data                       ;Z8=d0; Z26=scratch1;
  VPANDD        Z9,  Z27, Z9              //;A5CA4DE9 mask data                       ;Z9=d1; Z27=scratch2;
  VPANDD        Z28, Z29, Z28             //;C05E8C87 mask data                       ;Z28=d2; Z29=scratch3;
//; str_to_upper: IN zmm8; OUT zmm26
  VPCMPB        $5,  Z16, Z8,  K3         //;30E9B9FD K3 := (d0>=char_a)              ;K3=tmp_mask; Z8=d0; Z16=char_a; 5=GreaterEq;
  VPCMPB        $2,  Z17, Z8,  K3,  K3    //;8CE85BA0 K3 &= (d0<=char_z)              ;K3=tmp_mask; Z8=d0; Z17=char_z; 2=LessEq;
//; Z15 is 64 bytes with 0b00100000
//;    Z15|Z8 |Z26 => Z26
//;     0 | 0 | 0      0
//;     0 | 0 | 1      0
//;     0 | 1 | 0      1
//;     0 | 1 | 1      1
//;     1 | 0 | 0      0
//;     1 | 0 | 1      0
//;     1 | 1 | 0      1
//;     1 | 1 | 1      0     <= change from lower to upper
  VPMOVM2B      K3,  Z26                  //;ADC21F45 mask with selected chars        ;Z26=scratch1; K3=tmp_mask;
  VPTERNLOGD    $0b01001100,Z15, Z8,  Z26 //;1BB96D97                                 ;Z26=scratch1; Z8=d0; Z15=c_0b00100000;
  VMOVDQA32     Z26, Z8                   //;41954CFC d0 := scratch1                  ;Z8=d0; Z26=scratch1;
//; str_to_upper: IN zmm9; OUT zmm27
  VPCMPB        $5,  Z16, Z9,  K3         //;30E9B9FD K3 := (d1>=char_a)              ;K3=tmp_mask; Z9=d1; Z16=char_a; 5=GreaterEq;
  VPCMPB        $2,  Z17, Z9,  K3,  K3    //;8CE85BA0 K3 &= (d1<=char_z)              ;K3=tmp_mask; Z9=d1; Z17=char_z; 2=LessEq;
//; Z15 is 64 bytes with 0b00100000
//;    Z15|Z8 |Z26 => Z26
//;     0 | 0 | 0      0
//;     0 | 0 | 1      0
//;     0 | 1 | 0      1
//;     0 | 1 | 1      1
//;     1 | 0 | 0      0
//;     1 | 0 | 1      0
//;     1 | 1 | 0      1
//;     1 | 1 | 1      0     <= change from lower to upper
  VPMOVM2B      K3,  Z27                  //;ADC21F45 mask with selected chars        ;Z27=scratch2; K3=tmp_mask;
  VPTERNLOGD    $0b01001100,Z15, Z9,  Z27 //;1BB96D97                                 ;Z27=scratch2; Z9=d1; Z15=c_0b00100000;
  VMOVDQA32     Z27, Z9                   //;60AA018C d1 := scratch2                  ;Z9=d1; Z27=scratch2;
//; str_to_upper: IN zmm28; OUT zmm29
  VPCMPB        $5,  Z16, Z28, K3         //;30E9B9FD K3 := (d2>=char_a)              ;K3=tmp_mask; Z28=d2; Z16=char_a; 5=GreaterEq;
  VPCMPB        $2,  Z17, Z28, K3,  K3    //;8CE85BA0 K3 &= (d2<=char_z)              ;K3=tmp_mask; Z28=d2; Z17=char_z; 2=LessEq;
//; Z15 is 64 bytes with 0b00100000
//;    Z15|Z8 |Z26 => Z26
//;     0 | 0 | 0      0
//;     0 | 0 | 1      0
//;     0 | 1 | 0      1
//;     0 | 1 | 1      1
//;     1 | 0 | 0      0
//;     1 | 0 | 1      0
//;     1 | 1 | 0      1
//;     1 | 1 | 1      0     <= change from lower to upper
  VPMOVM2B      K3,  Z29                  //;ADC21F45 mask with selected chars        ;Z29=scratch3; K3=tmp_mask;
  VPTERNLOGD    $0b01001100,Z15, Z28, Z29 //;1BB96D97                                 ;Z29=scratch3; Z28=d2; Z15=c_0b00100000;
  VMOVDQA32     Z29, Z28                  //;250F442B d2 := scratch3                  ;Z28=d2; Z29=scratch3;
//; create key with bits for NeedleData:02-12-22-21-01-11-10-20-00
  VPCMPD        $0,  Z28, Z21, K3         //;00000000 K3 := (n2==d2)                  ;K3=tmp_mask; Z21=n2; Z28=d2; 0=Eq;
  VPCMPD        $0,  Z9,  Z21, K4         //;00000000 K4 := (n2==d1)                  ;K4=scratch1; Z21=n2; Z9=d1; 0=Eq;
  VPCMPD        $0,  Z8,  Z21, K5         //;00000000 K5 := (n2==d0)                  ;K5=scratch2; Z21=n2; Z8=d0; 0=Eq;
  VPSLLD.Z      $6,  Z10, K3,  Z21        //;00000000 key := 1<<6                     ;Z21=key; K3=tmp_mask; Z10=1;
  VPSLLD.Z      $5,  Z10, K4,  Z27        //;00000000 scratch2 := 1<<5                ;Z27=scratch2; K4=scratch1; Z10=1;
  VPSLLD.Z      $1,  Z10, K5,  Z29        //;00000000 scratch3 := 1<<1                ;Z29=scratch3; K5=scratch2; Z10=1;
  VPTERNLOGD    $0b11111110,Z29, Z27, Z21 //;00000000                                 ;Z21=key; Z27=scratch2; Z29=scratch3;

  VPCMPD        $0,  Z28, Z20, K3         //;00000000 K3 := (n1==d2)                  ;K3=tmp_mask; Z20=n1; Z28=d2; 0=Eq;
  VPCMPD        $0,  Z9,  Z20, K4         //;00000000 K4 := (n1==d1)                  ;K4=scratch1; Z20=n1; Z9=d1; 0=Eq;
  VPCMPD        $0,  Z8,  Z20, K5         //;00000000 K5 := (n1==d0)                  ;K5=scratch2; Z20=n1; Z8=d0; 0=Eq;
  VPSLLD.Z      $7,  Z10, K3,  Z27        //;00000000 scratch2 := 1<<7                ;Z27=scratch2; K3=tmp_mask; Z10=1;
  VPSLLD.Z      $3,  Z10, K4,  Z26        //;00000000 scratch1 := 1<<3                ;Z26=scratch1; K4=scratch1; Z10=1;
  VPSLLD.Z      $2,  Z10, K5,  Z29        //;00000000 scratch3 := 1<<2                ;Z29=scratch3; K5=scratch2; Z10=1;
  VPORD         Z26, Z27, Z27             //;00000000 scratch2 |= scratch1            ;Z27=scratch2; Z26=scratch1;
  VPTERNLOGD    $0b11111110,Z29, Z27, Z21 //;00000000                                 ;Z21=key; Z27=scratch2; Z29=scratch3;

  VPCMPD        $0,  Z28, Z19, K3         //;00000000 K3 := (n0==d2)                  ;K3=tmp_mask; Z19=n0; Z28=d2; 0=Eq;
  VPCMPD        $0,  Z9,  Z19, K4         //;00000000 K4 := (n0==d1)                  ;K4=scratch1; Z19=n0; Z9=d1; 0=Eq;
  VPCMPD        $0,  Z8,  Z19, K5         //;00000000 K5 := (n0==d0)                  ;K5=scratch2; Z19=n0; Z8=d0; 0=Eq;
  VPSLLD.Z      $8,  Z10, K3,  Z29        //;00000000 scratch3 := 1<<8                ;Z29=scratch3; K3=tmp_mask; Z10=1;
  VPSLLD.Z      $4,  Z10, K4,  Z27        //;00000000 scratch2 := 1<<4                ;Z27=scratch2; K4=scratch1; Z10=1;
  VPSLLD.Z      $0,  Z10, K5,  Z26        //;00000000 scratch1 := 1<<0                ;Z26=scratch1; K5=scratch2; Z10=1;
  VPORD         Z26, Z27, Z27             //;00000000 scratch2 |= scratch1            ;Z27=scratch2; Z26=scratch1;
  VPTERNLOGD    $0b11111110,Z29, Z27, Z21 //;00000000                                 ;Z21=key; Z27=scratch2; Z29=scratch3;

  VPADDD        Z10, Z10, Z8              //;00000000 constd_2 := 1 + 1               ;Z8=2; Z10=1;
  VPADDD        Z10, Z8,  Z9              //;00000000 constd_3 := 2 + 1               ;Z9=3; Z8=2; Z10=1;
  VPADDD        Z8,  Z8,  Z28             //;00000000 constd_4 := 2 + 2               ;Z28=4; Z8=2;
//; do the lookup of the advance values
  KMOVW         K6,  K3                   //;45A99B90 tmp_mask := lane_todo2          ;K3=tmp_mask; K6=lane_todo2;
  VPGATHERDD    (R15)(Z21*1),K3,  Z26     //;C3AEFFBF                                 ;Z26=scratch1; K3=tmp_mask; R15=update_data_ptr; Z21=key;
//; unpack results
  VPSRLD        $4,  Z26, Z19             //;87E05D1F ed_delta := scratch1>>4         ;Z19=ed_delta; Z26=scratch1;
  VPSRLD        $2,  Z26, Z21             //;13C921F9 adv_needle := scratch1>>2       ;Z21=adv_needle; Z26=scratch1;
  VPANDD        Z9,  Z19, Z19             //;A7E1848A ed_delta &= 3                   ;Z19=ed_delta; Z9=3;
  VPANDD        Z9,  Z26, Z20             //;42B9DA14 adv_data := scratch1 & 3        ;Z20=adv_data; Z26=scratch1; Z9=3;
  VPANDD        Z9,  Z21, Z21             //;E2CB942A adv_needle &= 3                 ;Z21=adv_needle; Z9=3;
//; update unicode approx3
//; update edit distance
  VPADDD        Z4,  Z19, Z4              //;15747D59 edit_dist += ed_delta           ;Z4=edit_dist; Z19=ed_delta;
//; advance data
  VPCMPD        $5,  Z10, Z20, K6,  K3    //;7FC1A433 K3 := K6 & (adv_data>=1)        ;K3=tmp_mask; K6=lane_todo2; Z20=adv_data; Z10=1; 5=GreaterEq;
  VMOVDQA32.Z   Z12, K3,  Z26             //;6428B608 scratch1 := n_bytes_d0          ;Z26=scratch1; K3=tmp_mask; Z12=n_bytes_d0;
  VPCMPD        $5,  Z8,  Z20, K6,  K3    //;4FC83ED2 K3 := K6 & (adv_data>=2)        ;K3=tmp_mask; K6=lane_todo2; Z20=adv_data; Z8=2; 5=GreaterEq;
  VPADDD        Z22, Z26, K3,  Z26        //;BAE14871 scratch1 += n_bytes_d1          ;Z26=scratch1; K3=tmp_mask; Z22=n_bytes_d1;
  VPCMPD        $5,  Z9,  Z20, K6,  K3    //;120E0569 K3 := K6 & (adv_data>=3)        ;K3=tmp_mask; K6=lane_todo2; Z20=adv_data; Z9=3; 5=GreaterEq;
  VPADDD        Z25, Z26, K3,  Z26        //;9BAA69A9 scratch1 += n_bytes_d2          ;Z26=scratch1; K3=tmp_mask; Z25=n_bytes_d2;
  VPSUBD        Z26, Z23, K6,  Z23        //;DF7FB44E data_len2 -= scratch1           ;Z23=data_len2; K6=lane_todo2; Z26=scratch1;
  VPADDD        Z26, Z6,  K6,  Z6         //;F81C97B0 data_off2 += scratch1           ;Z6=data_off2; K6=lane_todo2; Z26=scratch1;
//; advance needle
  VPCMPD        $5,  Z10, Z21, K6,  K3    //;5578190E K3 := K6 & (adv_needle>=1)      ;K3=tmp_mask; K6=lane_todo2; Z21=adv_needle; Z10=1; 5=GreaterEq;
  VMOVDQA32.Z   Z28, K3,  Z26             //;00000000 scratch1 := 4                   ;Z26=scratch1; K3=tmp_mask; Z28=4;
  VPCMPD        $5,  Z8,  Z21, K6,  K3    //;A814294A K3 := K6 & (adv_needle>=2)      ;K3=tmp_mask; K6=lane_todo2; Z21=adv_needle; Z8=2; 5=GreaterEq;
  VPADDD        Z28, Z26, K3,  Z26        //;B2BE82E2 scratch1 += 4                   ;Z26=scratch1; K3=tmp_mask; Z28=4;
  VPSUBD        Z21, Z7,  K6,  Z7         //;41970AC0 needle_len2 -= adv_needle       ;Z7=needle_len2; K6=lane_todo2; Z21=adv_needle;
  VPADDD        Z26, Z5,  K6,  Z5         //;89331149 needle_off += scratch1          ;Z5=needle_off; K6=lane_todo2; Z26=scratch1;
//; has-tail
//; restrict lanes based on edit distance and threshold
  VPCMPD        $2,  Z14, Z4,  K6,  K6    //;86F95312 K6 &= (edit_dist<=threshold)    ;K6=lane_todo2; Z4=edit_dist; Z14=threshold; 2=LessEq;
//; test if we have a match
  VPCMPD        $5,  Z7,  Z11, K6,  K3    //;EEF4BAA0 K3 := K6 & (0>=needle_len2)     ;K3=tmp_mask; K6=lane_todo2; Z11=0; Z7=needle_len2; 5=GreaterEq;
  KANDNW        K6,  K3,  K6              //;482703BD lane_todo2 &= ~tmp_mask         ;K6=lane_todo2; K3=tmp_mask;
  KORW          K1,  K3,  K1              //;8FAB61CD lane_active |= tmp_mask         ;K1=lane_active; K3=tmp_mask;
  KTESTW        K6,  K6                   //;9D3A860D any lanes still todo?           ;K6=lane_todo2;
  JNZ           loop1                     //;EA12C247 yes, then loop; jump if not zero (ZF = 0);

  KANDNW        K2,  K6,  K2              //;E3BAA7D5 lane_todo &= ~lane_todo2        ;K2=lane_todo; K6=lane_todo2;
  VPSUBD        Z10, Z3,  K2,  Z3         //;7C100DFB data_len--                      ;Z3=data_len; K2=lane_todo; Z10=1;
  VPADDD        Z10, Z2,  K2,  Z2         //;397684ED data_off++                      ;Z2=data_off; K2=lane_todo; Z10=1;
  VPCMPD        $6,  Z11, Z3,  K2,  K2    //;591E80A4 K2 &= (data_len>0)              ;K2=lane_todo; Z3=data_len; Z11=0; 6=Greater;
//; reset variables for loop2
  VMOVDQA32     Z3,  Z23                  //;1C31BFD8 data_len2 := data_len           ;Z23=data_len2; Z3=data_len;
  VMOVDQA32     Z2,  Z6                   //;3B8A334A data_off2 := data_off           ;Z6=data_off2; Z2=data_off;
  VMOVDQA32     Z13, Z7                   //;8EFD9390 needle_len2 := needle_len       ;Z7=needle_len2; Z13=needle_len;
  KTESTW        K2,  K2                   //;4661A15A any lanes still todo?           ;K2=lane_todo;
  JNZ           loop2                     //;28307DE7 yes, then loop; jump if not zero (ZF = 0);
next:
  NEXT()
//; #endregion bcHasSubstrFuzzyUnicodeA3

//; #region bcSkip1charLeft
//; skip the first UTF-8 codepoint in Z2:Z3
TEXT bcSkip1charLeft(SB), NOSPLIT|NOFRAME, $0
  VPTESTMD      Z3,  Z3,  K1,  K1         //;B1146BCF update lane mask with non-empty lanes;K1=lane_active; Z3=str_length;
  KTESTW        K1,  K1                   //;69D1CDA2 all lanes empty?                ;K1=lane_active;
  JZ            next                      //;A5924904 yes, then exit; jump if zero (ZF = 1);

  KMOVW         K1,  K3                   //;723D04C9 copy eligible lanes             ;K3=tmp_mask; K1=lane_active;
  VPGATHERDD    (SI)(Z2*1),K3,  Z8        //;E4967C89 gather data                     ;Z8=data_msg; K3=tmp_mask; SI=msg_ptr; Z2=str_start;

  VPSRLD        $4,  Z8,  Z26             //;FE5F1413 scratch_Z26 := data_msg>>4      ;Z26=scratch_Z26; Z8=data_msg;
  VPERMD        CONST_N_BYTES_UTF8(),Z26, Z7  //;CFC7AA76 get n_bytes_data            ;Z7=n_bytes_data; Z26=scratch_Z26;
  VPSUBD        Z7,  Z3,  K1,  Z3         //;B69EBA11 str_len -= n_bytes_data         ;Z3=str_len; K1=lane_active; Z7=n_bytes_data;
  VPADDD        Z7,  Z2,  K1,  Z2         //;45909060 str_start += n_bytes_data       ;Z2=str_start; K1=lane_active; Z7=n_bytes_data;
next:
  NEXT()
//; #endregion bcSkip1charLeft

//; #region bcSkip1charRight
//; skip the last UTF-8 codepoint in Z2:Z3
TEXT bcSkip1charRight(SB), NOSPLIT|NOFRAME, $0
  VPTESTMD      Z3,  Z3,  K1,  K1         //;B1146BCF update lane mask with non-empty lanes;K1=lane_active; Z3=str_length;
  KTESTW        K1,  K1                   //;69D1CDA2 all lanes empty?                ;K1=lane_active;
  JZ            next                      //;A5924904 yes, then exit; jump if zero (ZF = 1);

  VPBROADCASTD  CONSTD_UTF8_2B_MASK(),Z27 //;F6E81301 load constant UTF8 2byte mask   ;Z27=UTF8_2byte_mask;
  VPBROADCASTD  CONSTD_UTF8_3B_MASK(),Z28 //;B1E12620 load constant UTF8 3byte mask   ;Z28=UTF8_3byte_mask;
  VPBROADCASTD  CONSTD_UTF8_4B_MASK(),Z29 //;D896A9E1 load constant UTF8 4byte mask   ;Z29=UTF8_4byte_mask;
  VPBROADCASTD  CONSTD_1(),Z10            //;6F57EE92 load constant 1                 ;Z10=constd_1;
  VPADDD        Z10, Z10, Z24             //;EDD57CAF load constant 2                 ;Z24=constd_2; Z10=constd_1;
  VPADDD        Z10, Z24, Z25             //;7E7A1CB0 load constant 3                 ;Z25=constd_3; Z24=constd_2; Z10=constd_1;
  KMOVW         K1,  K3                   //;723D04C9 copy eligible lanes             ;K3=tmp_mask; K1=lane_active;
  VPADDD        Z2,  Z3,  Z4              //;5684E300 compute end-of-string ptr       ;Z4=end_of_str; Z3=str_length; Z2=str_start;
  VPGATHERDD    -4(SI)(Z4*1),K3,  Z8      //;573D089A gather data from end            ;Z8=data_msg; K3=tmp_mask; SI=msg_ptr; Z4=end_of_str;

//; #region count_bytes_code_point_right; data in Z8; result out Z7
  VPANDD        Z27, Z8,  Z26             //;B7541DA7 remove irrelevant bits for 2byte test;Z26=scratch_Z26; Z8=data_msg; Z27=UTF8_2byte_mask;
  VPCMPD        $0,  Z27, Z26, K1,  K3    //;C6890BF4 K3 := K1 & (scratch_Z26==UTF8_2byte_mask); create 2byte mask;K3=tmp_mask; K1=lane_active; Z26=scratch_Z26; Z27=UTF8_2byte_mask; 0=Eq;
  VPANDD        Z28, Z8,  Z26             //;D14D6426 remove irrelevant bits for 3byte test;Z26=scratch_Z26; Z8=data_msg; Z28=UTF8_3byte_mask;
  VPCMPD        $0,  Z28, Z26, K1,  K4    //;14C32DC0 K4 := K1 & (scratch_Z26==UTF8_3byte_mask); create 3byte mask;K4=tmp_mask2; K1=lane_active; Z26=scratch_Z26; Z28=UTF8_3byte_mask; 0=Eq;
  VPANDD        Z29, Z8,  Z26             //;C19D386F remove irrelevant bits for 4byte test;Z26=scratch_Z26; Z8=data_msg; Z29=UTF8_4byte_mask;
  VPCMPD        $0,  Z29, Z26, K1,  K5    //;1AE0A51C K5 := K1 & (scratch_Z26==UTF8_4byte_mask); create 4byte mask;K5=tmp_mask3; K1=lane_active; Z26=scratch_Z26; Z29=UTF8_4byte_mask; 0=Eq;
  VMOVDQA32     Z10, Z7                   //;A7640B64 n_bytes_data := 1               ;Z7=n_bytes_data; Z10=constd_1;
  VPADDD        Z10, Z7,  K3,  Z7         //;684FACB1 2byte UTF-8: add extra 1byte    ;Z7=n_bytes_data; K3=tmp_mask; Z10=constd_1;
  VPADDD        Z24, Z7,  K4,  Z7         //;A542E2E5 3byte UTF-8: add extra 2bytes   ;Z7=n_bytes_data; K4=tmp_mask2; Z24=constd_2;
  VPADDD        Z25, Z7,  K5,  Z7         //;26F561C2 4byte UTF-8: add extra 3bytes   ;Z7=n_bytes_data; K5=tmp_mask3; Z25=constd_3;
//; #endregion count_bytes_code_point_right; data in Z8; result out Z7

  VPSUBD        Z7,  Z3,  K1,  Z3         //;B69EBA11 str_length -= n_bytes_data      ;Z3=str_length; K1=lane_active; Z7=n_bytes_data;
next:
  NEXT()
//; #endregion bcSkip1charRight

//; #region bcSkipNcharLeft
//; skip the first n UTF-8 code-points in Z2:Z3
TEXT bcSkipNcharLeft(SB), NOSPLIT|NOFRAME, $0
//; load from stack-slot: load 16x uint32 into Z6
  LOADARG1Z(Z27, Z26)
  VPMOVQD       Z27, Y27                  //;17FCB103 truncate uint64 to uint32       ;Z27=scratch_Z27;
  VPMOVQD       Z26, Y26                  //;8F762E8E truncate uint64 to uint32       ;Z26=scratch_Z26;
  VINSERTI64X4  $1,  Y26, Z27, Z6         //;3944001B merge into 16x uint32           ;Z6=counter; Z27=scratch_Z27; Z26=scratch_Z26;

  VPXORD        Z11, Z11, Z11             //;81C90120 load constant 0                 ;Z11=0;
  VPCMPD        $5,  Z6,  Z3,  K1,  K1    //;502E314F K1 &= (str_len>=counter)        ;K1=lane_active; Z3=str_len; Z6=counter; 5=GreaterEq;
  VPCMPD        $1,  Z6,  Z11, K1,  K2    //;7E49CD56 K2 := K1 & (0<counter)          ;K2=lane_todo; K1=lane_active; Z11=0; Z6=counter; 1=LessThen;
  KTESTW        K2,  K2                   //;69D1CDA2 ZF := (K2==0); CF := 1          ;K2=lane_todo;
  JZ            next                      //;A5924904 jump if zero (ZF = 1)           ;

  VMOVDQU32     CONST_N_BYTES_UTF8(),Z21  //;B323211A load table_n_bytes_utf8         ;Z21=table_n_bytes_utf8;
  VPBROADCASTD  CONSTD_1(),Z10            //;6F57EE92 load constant 1                 ;Z10=1;
loop:
  KMOVW         K2,  K3                   //;723D04C9 copy eligible lanes             ;K3=tmp_mask; K2=lane_todo;
  VPGATHERDD    (SI)(Z2*1),K3,  Z8        //;E4967C89 gather data                     ;Z8=data_msg; K3=tmp_mask; SI=msg_ptr; Z2=str_start;

  VPSRLD        $4,  Z8,  Z26             //;FE5F1413 scratch_Z26 := data_msg>>4      ;Z26=scratch_Z26; Z8=data_msg;
  VPERMD        Z21, Z26, Z7              //;68FECBA0 get n_bytes_data                ;Z7=n_bytes_data; Z26=scratch_Z26; Z21=table_n_bytes_utf8;
  VPSUBD        Z7,  Z3,  K2,  Z3         //;B69EBA11 str_len -= n_bytes_data         ;Z3=str_len; K2=lane_todo; Z7=n_bytes_data;
  VPADDD        Z7,  Z2,  K2,  Z2         //;45909060 str_start += n_bytes_data       ;Z2=str_start; K2=lane_todo; Z7=n_bytes_data;

  VPSUBD        Z10, Z6,  Z6              //;97723E12 counter--                       ;Z6=counter; Z10=1;
//; tests
  VPCMPD        $1,  Z6,  Z11, K2,  K2    //;DF88A710 K2 &= (0<counter)               ;K2=lane_todo; Z11=0; Z6=counter; 1=LessThen;
  VPCMPD        $5,  Z3,  Z11, K2,  K3    //;2E4360D2 K3 := K2 & (0>=str_len)         ;K3=tmp_mask; K2=lane_todo; Z11=0; Z3=str_len; 5=GreaterEq;
  KANDNW        K1,  K3,  K1              //;21163EF3 lane_active &= ~tmp_mask        ;K1=lane_active; K3=tmp_mask;
  KTESTW        K2,  K1                   //;799F076E ZF := ((K1&K2)==0); CF := ((~K1&K2)==0);K1=lane_active; K2=lane_todo;
  JNZ           loop                      //;203DDAE1 any chars left? NO, loop next; jump if not zero (ZF = 0);

next:
  NEXT()
//; #endregion bcSkipNcharLeft

//; #region bcSkipNcharRight
//; skip the last n UTF-8 code-points in Z2:Z3
TEXT bcSkipNcharRight(SB), NOSPLIT|NOFRAME, $0
//; load from stack-slot: load 16x uint32 into Z6
  LOADARG1Z(Z27, Z26)
  VPMOVQD       Z27, Y27                  //;17FCB103 truncate uint64 to uint32       ;Z27=scratch_Z27;
  VPMOVQD       Z26, Y26                  //;8F762E8E truncate uint64 to uint32       ;Z26=scratch_Z26;
  VINSERTI64X4  $1,  Y26, Z27, Z6         //;3944001B merge into 16x uint32           ;Z6=counter; Z27=scratch_Z27; Z26=scratch_Z26;

  VPXORD        Z11, Z11, Z11             //;81C90120 load constant 0                 ;Z11=0;
  VPCMPD        $5,  Z6,  Z3,  K1,  K1    //;502E314F K1 &= (str_len>=counter)        ;K1=lane_active; Z3=str_len; Z6=counter; 5=GreaterEq;
  VPCMPD        $1,  Z6,  Z11, K1,  K2    //;7E49CD56 K2 := K1 & (0<counter)          ;K2=lane_todo; K1=lane_active; Z11=0; Z6=counter; 1=LessThen;
  KTESTW        K2,  K2                   //;69D1CDA2 ZF := (K2==0); CF := 1          ;K2=lane_todo;
  JZ            next                      //;A5924904 jump if zero (ZF = 1)           ;

  VPBROADCASTD  CONSTD_UTF8_2B_MASK(),Z27 //;F6E81301 load constant UTF8 2byte mask   ;Z27=UTF8_2byte_mask;
  VPBROADCASTD  CONSTD_UTF8_3B_MASK(),Z28 //;B1E12620 load constant UTF8 3byte mask   ;Z28=UTF8_3byte_mask;
  VPBROADCASTD  CONSTD_UTF8_4B_MASK(),Z29 //;D896A9E1 load constant UTF8 4byte mask   ;Z29=UTF8_4byte_mask;
  VPBROADCASTD  CONSTD_1(),Z10            //;6F57EE92 load constant 1                 ;Z10=1;
  VPADDD        Z10, Z10, Z22             //;EDD57CAF load constant 2                 ;Z22=2; Z10=1;
  VPADDD        Z10, Z22, Z23             //;7E7A1CB0 load constant 3                 ;Z23=3; Z22=2; Z10=1;
loop:
  KMOVW         K2,  K3                   //;723D04C9 copy eligible lanes             ;K3=tmp_mask; K2=lane_todo;
  VPADDD        Z2,  Z3,  Z4              //;5684E300 str_end := str_len + str_start  ;Z4=str_end; Z3=str_len; Z2=str_start;
  VPGATHERDD    -4(SI)(Z4*1),K3,  Z8      //;573D089A gather data from end            ;Z8=data_msg; K3=tmp_mask; SI=msg_ptr; Z4=str_end;

//; count_bytes_code_point_right; data in Z8; result out Z7
  VPANDD        Z27, Z8,  Z26             //;B7541DA7 remove irrelevant bits for 2byte test;Z26=scratch_Z26; Z8=data_msg; Z27=UTF8_2byte_mask;
  VPCMPD        $0,  Z27, Z26, K2,  K3    //;C6890BF4 K3 := K2 & (scratch_Z26==UTF8_2byte_mask); create 2byte mask;K3=tmp_mask; K2=lane_todo; Z26=scratch_Z26; Z27=UTF8_2byte_mask; 0=Eq;
  VPANDD        Z28, Z8,  Z26             //;D14D6426 remove irrelevant bits for 3byte test;Z26=scratch_Z26; Z8=data_msg; Z28=UTF8_3byte_mask;
  VPCMPD        $0,  Z28, Z26, K2,  K4    //;14C32DC0 K4 := K2 & (scratch_Z26==UTF8_3byte_mask); create 3byte mask;K4=tmp_mask2; K2=lane_todo; Z26=scratch_Z26; Z28=UTF8_3byte_mask; 0=Eq;
  VPANDD        Z29, Z8,  Z26             //;C19D386F remove irrelevant bits for 4byte test;Z26=scratch_Z26; Z8=data_msg; Z29=UTF8_4byte_mask;
  VPCMPD        $0,  Z29, Z26, K2,  K5    //;1AE0A51C K5 := K2 & (scratch_Z26==UTF8_4byte_mask); create 4byte mask;K5=tmp_mask3; K2=lane_todo; Z26=scratch_Z26; Z29=UTF8_4byte_mask; 0=Eq;
  VMOVDQA32     Z10, Z7                   //;A7640B64 n_bytes_data := 1               ;Z7=n_bytes_data; Z10=1;
  VPADDD        Z10, Z7,  K3,  Z7         //;684FACB1 2byte UTF-8: add extra 1byte    ;Z7=n_bytes_data; K3=tmp_mask; Z10=1;
  VPADDD        Z22, Z7,  K4,  Z7         //;A542E2E5 3byte UTF-8: add extra 2bytes   ;Z7=n_bytes_data; K4=tmp_mask2; Z22=2;
  VPADDD        Z23, Z7,  K5,  Z7         //;26F561C2 4byte UTF-8: add extra 3bytes   ;Z7=n_bytes_data; K5=tmp_mask3; Z23=3;
//; advance
  VPSUBD        Z7,  Z3,  K2,  Z3         //;B69EBA11 str_len -= n_bytes_data         ;Z3=str_len; K2=lane_todo; Z7=n_bytes_data;
  VPSUBD        Z10, Z6,  Z6              //;97723E12 counter--                       ;Z6=counter; Z10=1;
//; tests
  VPCMPD        $1,  Z6,  Z11, K2,  K2    //;DF88A710 K2 &= (0<counter)               ;K2=lane_todo; Z11=0; Z6=counter; 1=LessThen;
  VPCMPD        $2,  Z3,  Z11, K2,  K2    //;B623ED13 K2 &= (0<=str_len)              ;K2=lane_todo; Z11=0; Z3=str_len; 2=LessEq;
  VPCMPD        $5,  Z3,  Z11, K2,  K3    //;2E4360D2 K3 := K2 & (0>=str_len)         ;K3=tmp_mask; K2=lane_todo; Z11=0; Z3=str_len; 5=GreaterEq;
  KANDNW        K1,  K3,  K1              //;21163EF3 lane_active &= ~tmp_mask        ;K1=lane_active; K3=tmp_mask;
  KTESTW        K2,  K1                   //;799F076E ZF := ((K1&K2)==0); CF := ((~K1&K2)==0);K1=lane_active; K2=lane_todo;
  JNZ           loop                      //;203DDAE1 any chars left? NO, loop next; jump if not zero (ZF = 0);

next:
  NEXT()
//; #endregion bcSkipNcharRight

//; #region bcTrimWsLeft
//; Z2 = string offsets. Contains the start position of the strings, which may be updated (increased)
//; Z3 = string lengths. Contains the length of the strings, which may be updated (decreased)
TEXT bcTrimWsLeft(SB), NOSPLIT|NOFRAME, $0
  VMOVDQU32     bswap32<>(SB),Z22         //;2510A88F load constant_bswap32           ;Z22=constant_bswap32;
  VPBROADCASTD  CONSTD_4(),Z20            //;C8AFBE50 load constant 4                 ;Z20=constd_4;
  VPXORD        Z11, Z11, Z11             //;F4B92302 constd_0 := 0                   ;Z11=constd_0;
//; #region load white space chars
  MOVL          $0xD0920,R8               //;00000000                                 ;R8=tmp_constant;
  VPBROADCASTB  R8,  Z15                  //;7D467BFE load whitespace                 ;Z15=c_char_space; R8=tmp_constant;
  SHRL          $8,  R8                   //;69731820                                 ;R8=tmp_constant;
  VPBROADCASTB  R8,  Z16                  //;1FD6A756 load tab                        ;Z16=c_char_tab; R8=tmp_constant;
  SHRL          $8,  R8                   //;FA1E61C9                                 ;R8=tmp_constant;
  VPBROADCASTB  R8,  Z17                  //;14E0AB16 load cr                         ;Z17=c_char_cr; R8=tmp_constant;
//; #endregion load white space chars
loop:
  KMOVW         K1,  K3                   //;723D04C9 copy eligible lanes             ;K3=tmp_mask; K1=lane_active;
  VPGATHERDD    (SI)(Z2*1),K3,  Z8        //;68B7D88C gather data                     ;Z8=data_msg; K3=tmp_mask; SI=msg_ptr; Z2=str_start;
//; #region trim left/right whitespace comparison
  VPCMPB        $0,  Z15, Z8,  K3         //;529F46B9 K3 := (data_msg==c_char_space); test if equal to SPACE char;K3=tmp_mask; Z8=data_msg; Z15=c_char_space; 0=Eq;
  VPCMPB        $2,  Z8,  Z16, K2         //;AD553F19 K2 := (c_char_tab<=data_msg); is TAB (0x09) <= char;K2=scratch2_mask; Z16=c_char_tab; Z8=data_msg; 2=LessEq;
  VPCMPB        $2,  Z17, Z8,  K2,  K2    //;6BC60637 K2 &= (data_msg<=c_char_cr); and is char <= CR (0x0D);K2=scratch2_mask; Z8=data_msg; Z17=c_char_cr; 2=LessEq;
  KORQ          K3,  K2,  K3              //;00000000                                 ;K3=tmp_mask; K2=scratch2_mask;
  KTESTQ        K3,  K3                   //;A522D4C2 1 for every whitespace          ;K3=tmp_mask;
  JZ            next                      //;DC07C307 no matching chars found : no need to update string_start_position; jump if zero (ZF = 1);
//; #endregion

//; #region convert mask to selected byte count
  VPMOVM2B      K3,  Z8                   //;B0C4D1C5 promote 64x bit to 64x byte     ;Z8=data_msg; K3=tmp_mask;
  VPTERNLOGQ    $15, Z8,  Z8,  Z8         //;249B4036 negate                          ;Z8=data_msg;
  VPSHUFB       Z22, Z8,  Z8              //;8CF1488E reverse byte order              ;Z8=data_msg; Z22=constant_bswap32;
  VPLZCNTD      Z8,  K1,  Z8              //;90920F43 count leading zeros             ;Z8=data_msg; K1=lane_active;
  VPSRLD        $3,  Z8,  K1,  Z8         //;68276EFE divide by 8 yields byte_count   ;Z8=data_msg; K1=lane_active;
  VPMINSD       Z3,  Z8,  K1,  Z8         //;6616691F take minimun of length          ;Z8=data_msg; K1=lane_active; Z3=str_length;
//; #endregion zmm8 = #bytes

  VPADDD        Z8,  Z2,  K1,  Z2         //;40C40F7D str_start += data_msg           ;Z2=str_start; K1=lane_active; Z8=data_msg;
  VPSUBD        Z8,  Z3,  K1,  Z3         //;63A2C77B str_length -= data_msg          ;Z3=str_length; K1=lane_active; Z8=data_msg;
//; select lanes that have([essential] remaining string length > 0)
  VPCMPD        $2,  Z3,  Z11, K1,  K2    //;94B55922 K2 := K1 & (0<=str_length)      ;K2=scratch_mask1; K1=lane_active; Z11=constd_0; Z3=str_length; 2=LessEq;
//; select lanes that have([optimization] number of trimmed chars = 4)
  VPCMPD        $0,  Z20, Z8,  K2,  K2    //;D3BA3C05 K2 &= (data_msg==4)             ;K2=scratch_mask1; Z8=data_msg; Z20=constd_4; 0=Eq;
  KTESTW        K2,  K2                   //;7CB2A200                                 ;K2=scratch_mask1;
  JNZ           loop                      //;00000000 jump if not zero (ZF = 0)       ;

next:
  NEXT()
//; #endregion bcTrimWsLeft

//; #region bcTrimWsRight
//; Z2 = string offsets. Contains the start position of the strings, which may be updated (increased)
//; Z3 = string lengths. Contains the length of the strings, which may be updated (decreased)
TEXT bcTrimWsRight(SB), NOSPLIT|NOFRAME, $0
  VMOVDQU32     bswap32<>(SB),Z22         //;2510A88F load constant_bswap32           ;Z22=constant_bswap32;
  VPBROADCASTD  CONSTD_4(),Z20            //;C8AFBE50 load constant 4                 ;Z20=constd_4;
  VPXORD        Z11, Z11, Z11             //;F4B92302 constd_0 := 0                   ;Z11=constd_0;
//; #region load white space chars
  MOVL          $0xD0920,R8               //;00000000                                 ;R8=tmp_constant;
  VPBROADCASTB  R8,  Z15                  //;7D467BFE load whitespace                 ;Z15=c_char_space; R8=tmp_constant;
  SHRL          $8,  R8                   //;69731820                                 ;R8=tmp_constant;
  VPBROADCASTB  R8,  Z16                  //;1FD6A756 load tab                        ;Z16=c_char_tab; R8=tmp_constant;
  SHRL          $8,  R8                   //;FA1E61C9                                 ;R8=tmp_constant;
  VPBROADCASTB  R8,  Z17                  //;14E0AB16 load cr                         ;Z17=c_char_cr; R8=tmp_constant;
//; #endregion load white space chars
  VPADDD        Z3,  Z2,  Z14             //;00000000 str_pos_end := str_start + str_length;Z14=str_pos_end; Z2=str_start; Z3=str_length;
  VPSUBD        Z20, Z14, Z14             //;00000000 str_pos_end -= 4                ;Z14=str_pos_end; Z20=constd_4;
loop:
  KMOVW         K1,  K3                   //;723D04C9 copy eligible lanes             ;K3=tmp_mask; K1=lane_active;
  VPGATHERDD    (SI)(Z14*1),K3,  Z8       //;68B7D88C gather data                     ;Z8=data_msg; K3=tmp_mask; SI=msg_ptr; Z14=str_pos_end;
//; #region trim left/right whitespace comparison
  VPCMPB        $0,  Z15, Z8,  K3         //;529F46B9 K3 := (data_msg==c_char_space); test if equal to SPACE char;K3=tmp_mask; Z8=data_msg; Z15=c_char_space; 0=Eq;
  VPCMPB        $2,  Z8,  Z16, K2         //;AD553F19 K2 := (c_char_tab<=data_msg); is TAB (0x09) <= char;K2=scratch2_mask; Z16=c_char_tab; Z8=data_msg; 2=LessEq;
  VPCMPB        $2,  Z17, Z8,  K2,  K2    //;6BC60637 K2 &= (data_msg<=c_char_cr); and is char <= CR (0x0D);K2=scratch2_mask; Z8=data_msg; Z17=c_char_cr; 2=LessEq;
  KORQ          K3,  K2,  K3              //;00000000                                 ;K3=tmp_mask; K2=scratch2_mask;
  KTESTQ        K3,  K3                   //;A522D4C2 1 for every whitespace          ;K3=tmp_mask;
  JZ            next                      //;DC07C307 no matching chars found : no need to update string_start_position; jump if zero (ZF = 1);
//; #endregion

//; #region convert mask to selected byte count
  VPMOVM2B      K3,  Z8                   //;B0C4D1C5 promote 64x bit to 64x byte     ;Z8=data_msg; K3=tmp_mask;
  VPTERNLOGQ    $15, Z8,  Z8,  Z8         //;249B4036 negate                          ;Z8=data_msg;
  VPLZCNTD      Z8,  K1,  Z8              //;90920F43 count leading zeros             ;Z8=data_msg; K1=lane_active;
  VPSRLD        $3,  Z8,  K1,  Z8         //;68276EFE divide by 8 yields byte_count   ;Z8=data_msg; K1=lane_active;
  VPMINSD       Z3,  Z8,  K1,  Z8         //;6616691F take minimun of length          ;Z8=data_msg; K1=lane_active; Z3=str_length;
//; #endregion zmm8 = #bytes

  VPSUBD        Z8,  Z14, K1,  Z14        //;40C40F7D str_pos_end -= data_msg         ;Z14=str_pos_end; K1=lane_active; Z8=data_msg;
  VPSUBD        Z8,  Z3,  K1,  Z3         //;63A2C77B str_length -= data_msg          ;Z3=str_length; K1=lane_active; Z8=data_msg;
//; select lanes that have([essential] remaining string length > 0)
  VPCMPD        $2,  Z3,  Z11, K1,  K2    //;94B55922 K2 := K1 & (0<=str_length)      ;K2=scratch_mask1; K1=lane_active; Z11=constd_0; Z3=str_length; 2=LessEq;
//; select lanes that have([optimization] number of trimmed chars = 4)
  VPCMPD        $0,  Z20, Z8,  K2,  K2    //;D3BA3C05 K2 &= (data_msg==4)             ;K2=scratch_mask1; Z8=data_msg; Z20=constd_4; 0=Eq;
  KTESTW        K2,  K2                   //;7CB2A200                                 ;K2=scratch_mask1;
  JNZ           loop                      //;00000000 jump if not zero (ZF = 0)       ;

next:
  NEXT()
//; #endregion bcTrimWsRight

//; #region bcTrim4charLeft
//; Z2 = string offsets. Contains the start position of the strings, which may be updated (increased)
//; Z3 = string lengths. Contains the length of the strings, which may be updated (decreased)
TEXT bcTrim4charLeft(SB), NOSPLIT|NOFRAME, $0
  VMOVDQU32     bswap32<>(SB),Z22         //;2510A88F load constant_bswap32           ;Z22=constant_bswap32;
  VPBROADCASTD  CONSTD_4(),Z20            //;C8AFBE50 load constant 4                 ;Z20=4;
  VPXORD        Z11, Z11, Z11             //;81C90120 load constant 0                 ;Z11=0;
  IMM_FROM_DICT(R14)                      //;05667C35 load *[]byte with the provided str into R14
  MOVQ          (R14),R14                 //;26BB22F5 Load ptr of string              ;R14=chars_ptr; R14=chars_slice;
  MOVL          (R14),R14                 //;B7C25D43 Load first 4 chars              ;R14=chars_ptr;
  VPBROADCASTB  R14, Z9                   //;96085025                                 ;Z9=c_char0; R14=chars_ptr;
  SHRL          $8,  R14                  //;63D19F3B chars_ptr >>= 8                 ;R14=chars_ptr;
  VPBROADCASTB  R14, Z10                  //;FCEBCAA6                                 ;Z10=c_char1; R14=chars_ptr;
  SHRL          $8,  R14                  //;E5627E10 chars_ptr >>= 8                 ;R14=chars_ptr;
  VPBROADCASTB  R14, Z12                  //;66A9E2D3                                 ;Z12=c_char2; R14=chars_ptr;
  SHRL          $8,  R14                  //;C5E83B19 chars_ptr >>= 8                 ;R14=chars_ptr;
  VPBROADCASTB  R14, Z13                  //;C18E3641                                 ;Z13=c_char3; R14=chars_ptr;
loop:
  KMOVW         K1,  K3                   //;723D04C9 copy eligible lanes             ;K3=tmp_mask; K1=lane_active;
  VPGATHERDD    (SI)(Z2*1),K3,  Z8        //;68B7D88C gather data                     ;Z8=data_msg; K3=tmp_mask; SI=msg_ptr; Z2=str_start;
//; #region trim left/right 4char comparison
  VPCMPB        $0,  Z9,  Z8,  K3         //;D8545E6D K3 := (data_msg==c_char0); is char == char0;K3=tmp_mask; Z8=data_msg; Z9=c_char0; 0=Eq;
  VPCMPB        $0,  Z10, Z8,  K2         //;933CFC19 K2 := (data_msg==c_char1); is char == char1;K2=scratch2_mask; Z8=data_msg; Z10=c_char1; 0=Eq;
  KORQ          K2,  K3,  K3              //;7B471502 tmp_mask |= scratch2_mask       ;K3=tmp_mask; K2=scratch2_mask;
  VPCMPB        $0,  Z12, Z8,  K2         //;D206A939 K2 := (data_msg==c_char2); is char == char2;K2=scratch2_mask; Z8=data_msg; Z12=c_char2; 0=Eq;
  KORQ          K2,  K3,  K3              //;FD738F32 tmp_mask |= scratch2_mask       ;K3=tmp_mask; K2=scratch2_mask;
  VPCMPB        $0,  Z13, Z8,  K2         //;AB8B7AAA K2 := (data_msg==c_char3); is char == char3;K2=scratch2_mask; Z8=data_msg; Z13=c_char3; 0=Eq;
  KORQ          K2,  K3,  K3              //;CDC8B5A9 tmp_mask |= scratch2_mask       ;K3=tmp_mask; K2=scratch2_mask;
  KORTESTQ      K3,  K3                   //;A522D4C2 1 for every whitespace          ;K3=tmp_mask;
  JZ            next                      //;DC07C307 no matching chars found : no need to update string_start_position; jump if zero (ZF = 1);
//; #endregion

//; #region convert mask k3 to selected byte count zmm7
  VPMOVM2B      K3,  Z7                   //;B0C4D1C5 promote 64x bit to 64x byte     ;Z7=n_bytes_data; K3=tmp_mask;
  VPTERNLOGQ    $15, Z7,  Z7,  Z7         //;249B4036 negate                          ;Z7=n_bytes_data;
  VPSHUFB       Z22, Z7,  Z7              //;8CF1488E reverse byte order              ;Z7=n_bytes_data; Z22=constant_bswap32;
  VPLZCNTD      Z7,  K1,  Z7              //;90920F43 count leading zeros             ;Z7=n_bytes_data; K1=lane_active;
  VPSRLD        $3,  Z7,  K1,  Z7         //;68276EFE divide by 8 yields byte_count   ;Z7=n_bytes_data; K1=lane_active;
  VPMINSD       Z3,  Z7,  K1,  Z7         //;6616691F take minimun of length          ;Z7=n_bytes_data; K1=lane_active; Z3=str_len;
//; #endregion zmm7 = #bytes

  VPADDD        Z7,  Z2,  K1,  Z2         //;40C40F7D str_start += n_bytes_data       ;Z2=str_start; K1=lane_active; Z7=n_bytes_data;
  VPSUBD        Z7,  Z3,  K1,  Z3         //;63A2C77B str_len -= n_bytes_data         ;Z3=str_len; K1=lane_active; Z7=n_bytes_data;
  VPCMPD        $2,  Z3,  Z11, K1,  K2    //;94B55922 K2 := K1 & (0<=str_len)         ;K2=scratch_mask1; K1=lane_active; Z11=0; Z3=str_len; 2=LessEq;
  VPCMPD        $0,  Z20, Z7,  K2,  K2    //;D3BA3C05 K2 &= (n_bytes_data==4)         ;K2=scratch_mask1; Z7=n_bytes_data; Z20=4; 0=Eq;
  KTESTW        K2,  K2                   //;7CB2A200 ZF := (K2==0); CF := 1          ;K2=scratch_mask1;
  JNZ           loop                      //;7E49CD56 jump if not zero (ZF = 0)       ;

next:
  NEXT()
//; #endregion bcTrim4charLeft

//; #region bcTrim4charRight
//; Z2 = string offsets. Contains the start position of the strings, which may be updated (increased)
//; Z3 = string lengths. Contains the length of the strings, which may be updated (decreased)
TEXT bcTrim4charRight(SB), NOSPLIT|NOFRAME, $0
  VMOVDQU32     bswap32<>(SB),Z22         //;2510A88F load constant_bswap32           ;Z22=constant_bswap32;
  VPBROADCASTD  CONSTD_4(),Z20            //;C8AFBE50 load constant 4                 ;Z20=4;
  VPXORD        Z11, Z11, Z11             //;81C90120 load constant 0                 ;Z11=0;
  IMM_FROM_DICT(R14)                      //;05667C35 load *[]byte with the provided str into R14
  MOVQ          (R14),R14                 //;26BB22F5 Load ptr of string              ;R14=chars_ptr; R14=chars_slice;
  MOVL          (R14),R14                 //;B7C25D43 Load first 4 chars              ;R14=chars_ptr;
  VPBROADCASTB  R14, Z9                   //;96085025                                 ;Z9=c_char0; R14=chars_ptr;
  SHRL          $8,  R14                  //;63D19F3B chars_ptr >>= 8                 ;R14=chars_ptr;
  VPBROADCASTB  R14, Z10                  //;FCEBCAA6                                 ;Z10=c_char1; R14=chars_ptr;
  SHRL          $8,  R14                  //;E5627E10 chars_ptr >>= 8                 ;R14=chars_ptr;
  VPBROADCASTB  R14, Z12                  //;66A9E2D3                                 ;Z12=c_char2; R14=chars_ptr;
  SHRL          $8,  R14                  //;C5E83B19 chars_ptr >>= 8                 ;R14=chars_ptr;
  VPBROADCASTB  R14, Z13                  //;C18E3641                                 ;Z13=c_char3; R14=chars_ptr;
  VPADDD        Z3,  Z2,  Z14             //;813A5F04 str_end := str_start + str_len  ;Z14=str_end; Z2=str_start; Z3=str_len;
  VPSUBD        Z20, Z14, Z14             //;EAF06C41 str_end -= 4                    ;Z14=str_end; Z20=4;
loop:
  KMOVW         K1,  K3                   //;723D04C9 copy eligible lanes             ;K3=tmp_mask; K1=lane_active;
  VPGATHERDD    (SI)(Z14*1),K3,  Z8       //;68B7D88C gather data                     ;Z8=data_msg; K3=tmp_mask; SI=msg_ptr; Z14=str_end;
//; #region trim left/right 4char comparison
  VPCMPB        $0,  Z9,  Z8,  K3         //;D8545E6D K3 := (data_msg==c_char0); is char == char0;K3=tmp_mask; Z8=data_msg; Z9=c_char0; 0=Eq;
  VPCMPB        $0,  Z10, Z8,  K2         //;933CFC19 K2 := (data_msg==c_char1); is char == char1;K2=scratch2_mask; Z8=data_msg; Z10=c_char1; 0=Eq;
  KORQ          K2,  K3,  K3              //;7B471502 tmp_mask |= scratch2_mask       ;K3=tmp_mask; K2=scratch2_mask;
  VPCMPB        $0,  Z12, Z8,  K2         //;D206A939 K2 := (data_msg==c_char2); is char == char2;K2=scratch2_mask; Z8=data_msg; Z12=c_char2; 0=Eq;
  KORQ          K2,  K3,  K3              //;FD738F32 tmp_mask |= scratch2_mask       ;K3=tmp_mask; K2=scratch2_mask;
  VPCMPB        $0,  Z13, Z8,  K2         //;AB8B7AAA K2 := (data_msg==c_char3); is char == char3;K2=scratch2_mask; Z8=data_msg; Z13=c_char3; 0=Eq;
  KORQ          K2,  K3,  K3              //;CDC8B5A9 tmp_mask |= scratch2_mask       ;K3=tmp_mask; K2=scratch2_mask;
  KORTESTQ      K3,  K3                   //;A522D4C2 1 for every whitespace          ;K3=tmp_mask;
  JZ            next                      //;DC07C307 no matching chars found : no need to update string_start_position; jump if zero (ZF = 1);
//; #endregion

//; #region convert mask k3 to selected byte count zmm7
  VPMOVM2B      K3,  Z7                   //;B0C4D1C5 promote 64x bit to 64x byte     ;Z7=n_bytes_data; K3=tmp_mask;
  VPTERNLOGQ    $15, Z7,  Z7,  Z7         //;249B4036 negate                          ;Z7=n_bytes_data;
  VPLZCNTD      Z7,  K1,  Z7              //;90920F43 count leading zeros             ;Z7=n_bytes_data; K1=lane_active;
  VPSRLD        $3,  Z7,  K1,  Z7         //;68276EFE divide by 8 yields byte_count   ;Z7=n_bytes_data; K1=lane_active;
  VPMINSD       Z3,  Z7,  K1,  Z7         //;6616691F take minimun of length          ;Z7=n_bytes_data; K1=lane_active; Z3=str_len;
//; #endregion zmm7 = #bytes

  VPSUBD        Z7,  Z14, K1,  Z14        //;40C40F7D str_end -= n_bytes_data         ;Z14=str_end; K1=lane_active; Z7=n_bytes_data;
  VPSUBD        Z7,  Z3,  K1,  Z3         //;63A2C77B str_len -= n_bytes_data         ;Z3=str_len; K1=lane_active; Z7=n_bytes_data;
  VPCMPD        $2,  Z3,  Z11, K1,  K2    //;94B55922 K2 := K1 & (0<=str_len)         ;K2=scratch_mask1; K1=lane_active; Z11=0; Z3=str_len; 2=LessEq;
  VPCMPD        $0,  Z20, Z7,  K2,  K2    //;D3BA3C05 K2 &= (n_bytes_data==4)         ;K2=scratch_mask1; Z7=n_bytes_data; Z20=4; 0=Eq;
  KTESTW        K2,  K2                   //;7CB2A200 ZF := (K2==0); CF := 1          ;K2=scratch_mask1;
  JNZ           loop                      //;7E49CD56 jump if not zero (ZF = 0)       ;

next:
  NEXT()
//; #endregion bcTrim4charRight

//; #region bcContainsSuffixCs
TEXT bcContainsSuffixCs(SB), NOSPLIT|NOFRAME, $0
  IMM_FROM_DICT(R14)                      //;05667C35 load *[]byte with the provided str into R14
//; restrict lanes based on the length of needle
  VPBROADCASTD  8(R14),Z25                //;713DF24F bcst needle_len                 ;Z25=needle_len; R14=needle_slice;
  VPCMPD        $5,  Z25, Z3,  K1,  K1    //;502E314F K1 &= (str_len>=needle_len)     ;K1=lane_active; Z3=str_len; Z25=needle_len; 5=GreaterEq;
  VPTESTMD      Z25, Z25, K1,  K1         //;6C36C5E7 K1 &= (needle_len != 0)         ;K1=lane_active; Z25=needle_len;
  KTESTW        K1,  K1                   //;6E50BE85 any lanes still alive??         ;K1=lane_active;
  JZ            next                      //;BD98C1A8 no, exit; jump if zero (ZF = 1) ;
//; load constants
  VPBROADCASTD  CONSTD_4(),Z20            //;C8AFBE50 load constant 4                 ;Z20=4;
//; init variables
  MOVQ          (R14),R14                 //;D2647DF0 load needle_ptr                 ;R14=needle_ptr; R14=needle_slice;
  VMOVDQA32     Z25, Z6                   //;6F6F1342 counter := needle_len           ;Z6=counter; Z25=needle_len;
  VPSUBD        Z25, Z3,  K1,  Z24        //;4ADB5015 search_base := str_len - needle_len;Z24=search_base; K1=lane_active; Z3=str_len; Z25=needle_len;
  VPADDD        Z2,  Z24, Z24             //;3E1762B7 search_base += str_start        ;Z24=search_base; Z2=str_start;
  JMP           tail                      //;F2A3982D                                 ;
loop:
  KMOVW         K1,  K3                   //;723D04C9 copy eligible lanes             ;K3=tmp_mask; K1=lane_active;
  VPGATHERDD    (SI)(Z24*1),K3,  Z8       //;E4967C89 gather data                     ;Z8=data_msg; K3=tmp_mask; SI=msg_ptr; Z24=search_base;
//; compare data with needle
  VPCMPD.BCST   $0,  (R14),Z8,  K1,  K1   //;F0E5B3BD K1 &= (data_msg==[needle_ptr])  ;K1=lane_active; Z8=data_msg; R14=needle_ptr; 0=Eq;
  KTESTW        K1,  K1                   //;5746030A any lanes still alive?          ;K1=lane_active;
  JZ            next                      //;B763A908 no, exit; jump if zero (ZF = 1) ;
//; advance 4 ASCIIs
  VPSUBD        Z20, Z6,  Z6              //;AEDCD850 counter -= 4                    ;Z6=counter; Z20=4;
  ADDQ          $4,  R14                  //;B2EF9837 needle_ptr += 4                 ;R14=needle_ptr;
  VPADDD        Z20, Z24, Z24             //;D7CC90DD search_base += 4                ;Z24=search_base; Z20=4;
tail:
  VPCMPD        $5,  Z20, Z6,  K3         //;C28D3832 K3 := (counter>=4); 4 or more chars in needle?;K3=tmp_mask; Z6=counter; Z20=4; 5=GreaterEq;
  KTESTW        K1,  K3                   //;77067C8D ZF := ((K3&K1)==0); CF := ((~K3&K1)==0);K3=tmp_mask; K1=lane_active;
  JNZ           loop                      //;B678BE90 no, loop again; jump if not zero (ZF = 0);
//; still any needle left to compare
  VPTESTMD      Z6,  Z6,  K3              //;E0E548E4 K3 := (counter!=0); any chars left in needle?;K3=tmp_mask; Z6=counter;
  KTESTW        K1,  K3                   //;C28D3832 ZF := ((K3&K1)==0); CF := ((~K3&K1)==0);K3=tmp_mask; K1=lane_active;
  JZ            update                    //;4DA2206F no, update results; jump if zero (ZF = 1);
//; load the last 1-4 ASCIIs
  KMOVW         K1,  K3                   //;723D04C9 copy eligible lanes             ;K3=tmp_mask; K1=lane_active;
  VPGATHERDD    (SI)(Z24*1),K3,  Z8       //;36FEA5FE gather data                     ;Z8=data_msg; K3=tmp_mask; SI=msg_ptr; Z24=search_base;
  VPERMD        CONST_TAIL_MASK(),Z6,  Z19 //;E5886CFE get tail_mask                  ;Z19=tail_mask; Z6=counter;
  VPANDD        Z8,  Z19, Z8              //;FC6636EA mask data from msg              ;Z8=data_msg; Z19=tail_mask;
  VPANDD.BCST   (R14),Z19, Z9             //;EE8B32D9 load needle with mask           ;Z9=data_needle; Z19=tail_mask; R14=needle_ptr;
//; compare data with needle
  VPCMPD        $0,  Z9,  Z8,  K1,  K1    //;474761AE K1 &= (data_msg==data_needle)   ;K1=lane_active; Z8=data_msg; Z9=data_needle; 0=Eq;
update:
  VPSUBD        Z25, Z3,  K1,  Z3         //;B5FDDA17 str_len -= needle_len           ;Z3=str_len; K1=lane_active; Z25=needle_len;
next:
  NEXT()
//; #endregion bcContainsSuffixCs

//; #region bcContainsSuffixCi
TEXT bcContainsSuffixCi(SB), NOSPLIT|NOFRAME, $0
  IMM_FROM_DICT(R14)                      //;05667C35 load *[]byte with the provided str into R14
//; restrict lanes based on the length of needle
  VPBROADCASTD  8(R14),Z25                //;713DF24F bcst needle_len                 ;Z25=needle_len; R14=needle_slice;
  VPCMPD        $5,  Z25, Z3,  K1,  K1    //;502E314F K1 &= (str_len>=needle_len)     ;K1=lane_active; Z3=str_len; Z25=needle_len; 5=GreaterEq;
  VPTESTMD      Z25, Z25, K1,  K1         //;6C36C5E7 K1 &= (needle_len != 0)         ;K1=lane_active; Z25=needle_len;
  KTESTW        K1,  K1                   //;6E50BE85 any lanes still alive??         ;K1=lane_active;
  JZ            next                      //;BD98C1A8 no, exit; jump if zero (ZF = 1) ;
//; load constants
  VPBROADCASTD  CONSTD_4(),Z20            //;C8AFBE50 load constant 4                 ;Z20=4;
  VPBROADCASTB  CONSTB_32(),Z15           //;5B8F2908 load constant 0b00100000        ;Z15=c_0b00100000;
  VPBROADCASTB  CONSTB_97(),Z16           //;5D5B0014 load constant ASCII a           ;Z16=char_a;
  VPBROADCASTB  CONSTB_122(),Z17          //;8E2ED824 load constant ASCII z           ;Z17=char_z;
//; init variables
  MOVQ          (R14),R14                 //;D2647DF0 load needle_ptr                 ;R14=needle_ptr; R14=needle_slice;
  VMOVDQA32     Z25, Z6                   //;6F6F1342 counter := needle_len           ;Z6=counter; Z25=needle_len;
  VPSUBD        Z25, Z3,  K1,  Z24        //;4ADB5015 search_base := str_len - needle_len;Z24=search_base; K1=lane_active; Z3=str_len; Z25=needle_len;
  VPADDD        Z2,  Z24, Z24             //;3E1762B7 search_base += str_start        ;Z24=search_base; Z2=str_start;
  JMP           tail                      //;F2A3982D                                 ;
loop:
  KMOVW         K1,  K3                   //;723D04C9 copy eligible lanes             ;K3=tmp_mask; K1=lane_active;
  VPGATHERDD    (SI)(Z24*1),K3,  Z8       //;E4967C89 gather data                     ;Z8=data_msg; K3=tmp_mask; SI=msg_ptr; Z24=search_base;
//; str_to_upper: IN zmm8; OUT zmm13
  VPCMPB        $5,  Z16, Z8,  K3         //;30E9B9FD K3 := (data_msg>=char_a)        ;K3=tmp_mask; Z8=data_msg; Z16=char_a; 5=GreaterEq;
  VPCMPB        $2,  Z17, Z8,  K3,  K3    //;8CE85BA0 K3 &= (data_msg<=char_z)        ;K3=tmp_mask; Z8=data_msg; Z17=char_z; 2=LessEq;
  VPMOVM2B      K3,  Z13                  //;ADC21F45 mask with selected chars        ;Z13=data_msg_upper; K3=tmp_mask;
  VPTERNLOGQ    $76, Z15, Z8,  Z13        //;1BB96D97 see stringext.md                ;Z13=data_msg_upper; Z8=data_msg; Z15=c_0b00100000;
//; compare data with needle
  VPCMPD.BCST   $0,  (R14),Z13, K1,  K1   //;F0E5B3BD K1 &= (data_msg_upper==[needle_ptr]);K1=lane_active; Z13=data_msg_upper; R14=needle_ptr; 0=Eq;
  KTESTW        K1,  K1                   //;5746030A any lanes still alive?          ;K1=lane_active;
  JZ            next                      //;B763A908 no, exit; jump if zero (ZF = 1) ;
//; advance 4 ASCIIs
  VPSUBD        Z20, Z6,  Z6              //;AEDCD850 counter -= 4                    ;Z6=counter; Z20=4;
  ADDQ          $4,  R14                  //;B2EF9837 needle_ptr += 4                 ;R14=needle_ptr;
  VPADDD        Z20, Z24, Z24             //;D7CC90DD search_base += 4                ;Z24=search_base; Z20=4;
tail:
  VPCMPD        $5,  Z20, Z6,  K3         //;C28D3832 K3 := (counter>=4); 4 or more chars in needle?;K3=tmp_mask; Z6=counter; Z20=4; 5=GreaterEq;
  KTESTW        K1,  K3                   //;77067C8D ZF := ((K3&K1)==0); CF := ((~K3&K1)==0);K3=tmp_mask; K1=lane_active;
  JNZ           loop                      //;B678BE90 no, loop again; jump if not zero (ZF = 0);
//; still any needle left to compare
  VPTESTMD      Z6,  Z6,  K3              //;E0E548E4 K3 := (counter!=0); any chars left in needle?;K3=tmp_mask; Z6=counter;
  KTESTW        K1,  K3                   //;C28D3832 ZF := ((K3&K1)==0); CF := ((~K3&K1)==0);K3=tmp_mask; K1=lane_active;
  JZ            update                    //;4DA2206F no, update results; jump if zero (ZF = 1);
//; load the last 1-4 ASCIIs
  KMOVW         K1,  K3                   //;723D04C9 copy eligible lanes             ;K3=tmp_mask; K1=lane_active;
  VPGATHERDD    (SI)(Z24*1),K3,  Z8       //;36FEA5FE gather data                     ;Z8=data_msg; K3=tmp_mask; SI=msg_ptr; Z24=search_base;
  VPERMD        CONST_TAIL_MASK(),Z6,  Z19 //;E5886CFE get tail_mask                  ;Z19=tail_mask; Z6=counter;
  VPANDD        Z8,  Z19, Z8              //;FC6636EA mask data from msg              ;Z8=data_msg; Z19=tail_mask;
  VPANDD.BCST   (R14),Z19, Z9             //;EE8B32D9 load needle with mask           ;Z9=data_needle; Z19=tail_mask; R14=needle_ptr;
//; compare data with needle
//; str_to_upper: IN zmm8; OUT zmm13
  VPCMPB        $5,  Z16, Z8,  K3         //;30E9B9FD K3 := (data_msg>=char_a)        ;K3=tmp_mask; Z8=data_msg; Z16=char_a; 5=GreaterEq;
  VPCMPB        $2,  Z17, Z8,  K3,  K3    //;8CE85BA0 K3 &= (data_msg<=char_z)        ;K3=tmp_mask; Z8=data_msg; Z17=char_z; 2=LessEq;
  VPMOVM2B      K3,  Z13                  //;ADC21F45 mask with selected chars        ;Z13=data_msg_upper; K3=tmp_mask;
  VPTERNLOGQ    $76, Z15, Z8,  Z13        //;1BB96D97 see stringext.md                ;Z13=data_msg_upper; Z8=data_msg; Z15=c_0b00100000;

  VPCMPD        $0,  Z9,  Z13, K1,  K1    //;474761AE K1 &= (data_msg_upper==data_needle);K1=lane_active; Z13=data_msg_upper; Z9=data_needle; 0=Eq;
update:
  VPSUBD        Z25, Z3,  K1,  Z3         //;B5FDDA17 str_len -= needle_len           ;Z3=str_len; K1=lane_active; Z25=needle_len;
next:
  NEXT()
//; #endregion bcContainsSuffixCi

//; #region bcContainsSuffixUTF8Ci
TEXT bcContainsSuffixUTF8Ci(SB), NOSPLIT|NOFRAME, $0
  IMM_FROM_DICT(R14)                      //;05667C35 load *[]byte with the provided str into R14
  MOVQ          (R14),R14                 //;D2647DF0 load needle_ptr                 ;R14=needle_ptr; R14=needle_slice;
  MOVL          (R14),CX                  //;5B83F09F load number of code-points      ;CX=n_runes; R14=needle_ptr;
  VPBROADCASTD  CX,  Z26                  //;485C8362 bcst number of code-points      ;Z26=scratch_Z26; CX=n_runes;
  VPTESTMD      Z26, Z26, K1,  K1         //;CD49D8A5 K1 &= (scratch_Z26 != 0); empty needles are dead lanes;K1=lane_active; Z26=scratch_Z26;
  VPCMPD        $2,  Z3,  Z26, K1,  K1    //;B73A4F83 K1 &= (scratch_Z26<=str_len)    ;K1=lane_active; Z26=scratch_Z26; Z3=str_len; 2=LessEq;
  KTESTW        K1,  K1                   //;5746030A any lanes still alive?          ;K1=lane_active;
  JZ            next                      //;B763A908 no, exit; jump if zero (ZF = 1) ;

  ADDQ          $4,  R14                  //;7B0665F3 calc alt_ptr offset             ;R14=needle_ptr;
  VPBROADCASTD  CONSTD_UTF8_2B_MASK(),Z5  //;F6E81301 load constant UTF8 2byte mask   ;Z5=UTF8_2byte_mask;
  VPBROADCASTD  CONSTD_UTF8_3B_MASK(),Z23 //;B1E12620 load constant UTF8 3byte mask   ;Z23=UTF8_3byte_mask;
  VPBROADCASTD  CONSTD_UTF8_4B_MASK(),Z21 //;D896A9E1 load constant UTF8 4byte mask   ;Z21=UTF8_4byte_mask;
  VMOVDQU32     CONST_TAIL_MASK(),Z18     //;7DB21CB0 load tail_mask_data             ;Z18=tail_mask_data;
  VPBROADCASTB  CONSTB_32(),Z15           //;5B8F2908 load constant 0b00100000        ;Z15=c_0b00100000;
  VPBROADCASTB  CONSTB_97(),Z16           //;5D5B0014 load constant ASCII a           ;Z16=char_a;
  VPBROADCASTB  CONSTB_122(),Z17          //;8E2ED824 load constant ASCII z           ;Z17=char_z;
  VPBROADCASTD  CONSTD_1(),Z10            //;6F57EE92 load constant 1                 ;Z10=1;
  VPADDD        Z10, Z10, Z14             //;EDD57CAF load constant 2                 ;Z14=2; Z10=1;
  VPADDD        Z10, Z14, Z12             //;7E7A1CB0 load constant 3                 ;Z12=3; Z14=2; Z10=1;
  VPADDD        Z10, Z12, Z20             //;9CFA6ADD load constant 4                 ;Z20=4; Z12=3; Z10=1;
  VPADDD        Z2,  Z3,  Z24             //;ADF771FC search_base := str_len + str_start;Z24=search_base; Z3=str_len; Z2=str_start;

loop:
  VPCMPD        $5,  Z10, Z3,  K1,  K1    //;790C4E82 K1 &= (str_len>=1); empty data are dead lanes;K1=lane_active; Z3=str_len; Z10=1; 5=GreaterEq;
  KMOVW         K1,  K3                   //;723D04C9 copy eligible lanes             ;K3=tmp_mask; K1=lane_active;
  VPGATHERDD    -4(SI)(Z24*1),K3,  Z8     //;573D089A gather data from end            ;Z8=data_msg; K3=tmp_mask; SI=msg_ptr; Z24=search_base;
//; NOTE: debugging. If you jump from here to mixed_ascii you bypass the 4 ASCII optimization
  CMPL          CX,  $4                   //;E273EEEA are we in the needle tail?      ;CX=n_runes;
  JL            mixed_ascii               //;A8685FD7 yes, then jump; jump if less (SF neq OF);
  VPBROADCASTD.Z 16(R14),K1,  Z9          //;2694A02F load needle data                ;Z9=data_needle; K1=lane_active; R14=needle_ptr;
//; clear tail from data: IN zmm8; OUT zmm8
  VPMINSD       Z3,  Z20, Z26             //;DEC17BF3 scratch_Z26 := min(4, str_len)  ;Z26=scratch_Z26; Z20=4; Z3=str_len;
  VPERMD        Z18, Z26, Z19             //;E5886CFE get tail_mask                   ;Z19=tail_mask; Z26=scratch_Z26; Z18=tail_mask_data;
  VPANDD        Z8,  Z19, Z8              //;64208067 mask data from msg              ;Z8=data_msg; Z19=tail_mask;
//; determine if either data or needle has non-ASCII content
  VPORD.Z       Z8,  Z9,  K1,  Z26        //;3692D686 scratch_Z26 := data_needle | data_msg;Z26=scratch_Z26; K1=lane_active; Z9=data_needle; Z8=data_msg;
  VPMOVB2M      Z26, K3                   //;5303B427 get 64 sign-bits                ;K3=tmp_mask; Z26=scratch_Z26;
  KTESTQ        K3,  K3                   //;A2B0951C all sign-bits zero?             ;K3=tmp_mask;
  JNZ           mixed_ascii               //;303EFD4D no, found a non-ascii char; jump if not zero (ZF = 0);

//; str_to_upper: IN zmm8; OUT zmm13
  VPCMPB        $5,  Z16, Z8,  K3         //;30E9B9FD K3 := (data_msg>=char_a)        ;K3=tmp_mask; Z8=data_msg; Z16=char_a; 5=GreaterEq;
  VPCMPB        $2,  Z17, Z8,  K3,  K3    //;8CE85BA0 K3 &= (data_msg<=char_z)        ;K3=tmp_mask; Z8=data_msg; Z17=char_z; 2=LessEq;
  VPMOVM2B      K3,  Z13                  //;ADC21F45 mask with selected chars        ;Z13=data_msg_upper; K3=tmp_mask;
  VPTERNLOGQ    $76, Z15, Z8,  Z13        //;1BB96D97 see stringext.md                ;Z13=data_msg_upper; Z8=data_msg; Z15=c_0b00100000;
//; compare data with needle for 4 ASCIIs
  VPCMPD        $0,  Z13, Z9,  K1,  K1    //;BBBDF880 K1 &= (data_needle==data_msg_upper);K1=lane_active; Z9=data_needle; Z13=data_msg_upper; 0=Eq;
  KTESTW        K1,  K1                   //;5746030A any lanes still alive?          ;K1=lane_active;
  JZ            next                      //;B763A908 no, exit; jump if zero (ZF = 1) ;
//; advance to the next 4 ASCIIs
  VPSUBD        Z20, Z24, K1,  Z24        //;D7CC90DD search_base -= 4                ;Z24=search_base; K1=lane_active; Z20=4;
  VPSUBD        Z20, Z3,  K1,  Z3         //;83ADFEDA str_len -= 4                    ;Z3=str_len; K1=lane_active; Z20=4;
  ADDQ          $80, R14                  //;F0BC3163 needle_ptr += 80                ;R14=needle_ptr;
  SUBL          $4,  CX                   //;646B86C9 n_runes -= 4                    ;CX=n_runes;
  JG            loop                      //;1EBC2C20 jump if greater ((ZF = 0) and (SF = OF));
  JMP           next                      //;2230EE05                                 ;

mixed_ascii:
//; count_bytes_code_point_right; data in Z8; result out Z7
  VPANDD        Z5,  Z8,  Z26             //;B7541DA7 remove irrelevant bits for 2byte test;Z26=scratch_Z26; Z8=data_msg; Z5=UTF8_2byte_mask;
  VPCMPD        $0,  Z5,  Z26, K1,  K3    //;C6890BF4 K3 := K1 & (scratch_Z26==UTF8_2byte_mask); create 2byte mask;K3=tmp_mask; K1=lane_active; Z26=scratch_Z26; Z5=UTF8_2byte_mask; 0=Eq;
  VPANDD        Z23, Z8,  Z26             //;D14D6426 remove irrelevant bits for 3byte test;Z26=scratch_Z26; Z8=data_msg; Z23=UTF8_3byte_mask;
  VPCMPD        $0,  Z23, Z26, K1,  K4    //;14C32DC0 K4 := K1 & (scratch_Z26==UTF8_3byte_mask); create 3byte mask;K4=alt2_match; K1=lane_active; Z26=scratch_Z26; Z23=UTF8_3byte_mask; 0=Eq;
  VPANDD        Z21, Z8,  Z26             //;C19D386F remove irrelevant bits for 4byte test;Z26=scratch_Z26; Z8=data_msg; Z21=UTF8_4byte_mask;
  VPCMPD        $0,  Z21, Z26, K1,  K5    //;1AE0A51C K5 := K1 & (scratch_Z26==UTF8_4byte_mask); create 4byte mask;K5=alt3_match; K1=lane_active; Z26=scratch_Z26; Z21=UTF8_4byte_mask; 0=Eq;
  VMOVDQA32     Z10, Z7                   //;A7640B64 n_bytes_data := 1               ;Z7=n_bytes_data; Z10=1;
  VPADDD        Z10, Z7,  K3,  Z7         //;684FACB1 2byte UTF-8: add extra 1byte    ;Z7=n_bytes_data; K3=tmp_mask; Z10=1;
  VPADDD        Z14, Z7,  K4,  Z7         //;A542E2E5 3byte UTF-8: add extra 2bytes   ;Z7=n_bytes_data; K4=alt2_match; Z14=2;
  VPADDD        Z12, Z7,  K5,  Z7         //;26F561C2 4byte UTF-8: add extra 3bytes   ;Z7=n_bytes_data; K5=alt3_match; Z12=3;
//; shift code-point to least significant position
  VPSUBD        Z7,  Z20, Z26             //;C8ECAA75 scratch_Z26 := 4 - n_bytes_data ;Z26=scratch_Z26; Z20=4; Z7=n_bytes_data;
  VPSLLD        $3,  Z26, Z26             //;5734792E scratch_Z26 <<= 3               ;Z26=scratch_Z26;
  VPSRLVD       Z26, Z8,  Z8              //;529FFC90 data_msg >>= scratch_Z26        ;Z8=data_msg; Z26=scratch_Z26;
//; compare data with needle for 1 UTF8 byte sequence
  VPCMPD.BCST   $0,  (R14),Z8,  K1,  K3   //;345D0BF3 K3 := K1 & (data_msg==[needle_ptr]);K3=tmp_mask; K1=lane_active; Z8=data_msg; R14=needle_ptr; 0=Eq;
  VPCMPD.BCST   $0,  4(R14),Z8,  K1,  K4  //;EFD0A9A3 K4 := K1 & (data_msg==[needle_ptr+4]);K4=alt2_match; K1=lane_active; Z8=data_msg; R14=needle_ptr; 0=Eq;
  VPCMPD.BCST   $0,  8(R14),Z8,  K1,  K5  //;CAC0FAC6 K5 := K1 & (data_msg==[needle_ptr+8]);K5=alt3_match; K1=lane_active; Z8=data_msg; R14=needle_ptr; 0=Eq;
  VPCMPD.BCST   $0,  12(R14),Z8,  K1,  K6  //;50C70740 K6 := K1 & (data_msg==[needle_ptr+12]);K6=alt4_match; K1=lane_active; Z8=data_msg; R14=needle_ptr; 0=Eq;
  KORW          K3,  K4,  K3              //;58E49245 tmp_mask |= alt2_match          ;K3=tmp_mask; K4=alt2_match;
  KORW          K3,  K5,  K3              //;BDCB8940 tmp_mask |= alt3_match          ;K3=tmp_mask; K5=alt3_match;
  KORW          K6,  K3,  K1              //;AAF6ED91 lane_active := tmp_mask | alt4_match;K1=lane_active; K3=tmp_mask; K6=alt4_match;
  KTESTW        K1,  K1                   //;5746030A any lanes still alive?          ;K1=lane_active;
  JZ            next                      //;B763A908 no, exit; jump if zero (ZF = 1) ;
//; advance to the next rune
  VPSUBD        Z7,  Z24, K1,  Z24        //;D35D27FB search_base -= n_bytes_data     ;Z24=search_base; K1=lane_active; Z7=n_bytes_data;
  VPSUBD        Z7,  Z3,  K1,  Z3         //;24E04BE7 str_len -= n_bytes_data         ;Z3=str_len; K1=lane_active; Z7=n_bytes_data;
  ADDQ          $20, R14                  //;1F8D79B1 needle_ptr += 20                ;R14=needle_ptr;
  DECL          CX                        //;A99E9290 n_runes--                       ;CX=n_runes;
  JG            loop                      //;80013DFA jump if greater ((ZF = 0) and (SF = OF));
next:
  NEXT()

//; #endregion bcContainsSuffixUTF8Ci

//; #region bcContainsPrefixCs
//; equal ascii string in slice in Z2:Z3, with stack[imm]
TEXT bcContainsPrefixCs(SB), NOSPLIT|NOFRAME, $0
  IMM_FROM_DICT(R14)                      //;05667C35 load *[]byte with the provided str into R14
  VPBROADCASTD  8(R14),Z6                 //;713DF24F bcst needle_length              ;Z6=counter; R14=needle_slice;
  VPTESTMD      Z6,  Z6,  K1,  K1         //;EF7C0710 K1 &= (counter != 0)            ;K1=lane_active; Z6=counter;
  VPCMPD        $5,  Z6,  Z3,  K1,  K1    //;502E314F K1 &= (str_len>=counter)        ;K1=lane_active; Z3=str_len; Z6=counter; 5=GreaterEq;
  KTESTW        K1,  K1                   //;C28D3832 any lane still alive            ;K1=lane_active;
  JZ            next                      //;4DA2206F no, exit; jump if zero (ZF = 1) ;
  MOVQ          (R14),R14                 //;D2647DF0 load needle_ptr                 ;R14=needle_ptr; R14=needle_slice;
  VPXORD        Z11, Z11, Z11             //;81C90120 load constant 0                 ;Z11=0;
  VPBROADCASTD  CONSTD_4(),Z20            //;C8AFBE50 load constant 4                 ;Z20=4;

  VMOVDQA32     Z2,  Z24                  //;6F6F1342 search_base := str_start        ;Z24=search_base; Z2=str_start;
  VMOVDQA32     Z6,  Z25                  //;6F6F1343 needle_len := counter           ;Z25=needle_len; Z6=counter;
  JMP           tests                     //;F2A3982D                                 ;
loop:
//; load data
  KMOVW         K1,  K3                   //;723D04C9 copy eligible lanes             ;K3=tmp_mask; K1=lane_active;
  VPGATHERDD    (SI)(Z24*1),K3,  Z8       //;E4967C89 gather data                     ;Z8=data_msg; K3=tmp_mask; SI=msg_ptr; Z24=search_base;
  VPSUBD        Z20, Z6,  K1,  Z6         //;AEDCD850 counter -= 4                    ;Z6=counter; K1=lane_active; Z20=4;
  VPADDD        Z20, Z24, K1,  Z24        //;D7CC90DD search_base += 4                ;Z24=search_base; K1=lane_active; Z20=4;
//; compare data with needle
  VPCMPD.BCST   $0,  (R14),Z8,  K1,  K1   //;F0E5B3BD K1 &= (data_msg==[needle_ptr])  ;K1=lane_active; Z8=data_msg; R14=needle_ptr; 0=Eq;
  ADDQ          $4,  R14                  //;B2EF9837 needle_ptr += 4                 ;R14=needle_ptr;
tests:
  VPCMPD        $2,  Z6,  Z11, K1,  K1    //;8A1022B4 K1 &= (0<=counter)              ;K1=lane_active; Z11=0; Z6=counter; 2=LessEq;
  VPCMPD        $6,  Z20, Z6,  K3         //;99392208 K3 := (counter>4)               ;K3=tmp_mask; Z6=counter; Z20=4; 6=Greater;
  KTESTW        K1,  K1                   //;FE455439 any lanes still alive           ;K1=lane_active;
  JZ            next                      //;CD5F484F no, exit; jump if zero (ZF = 1) ;
  KTESTW        K1,  K3                   //;C28D3832 ZF := ((K3&K1)==0); CF := ((~K3&K1)==0);K3=tmp_mask; K1=lane_active;
  JNZ           loop                      //;B678BE90 no, loop again; jump if not zero (ZF = 0);
//; load data
  KMOVW         K1,  K3                   //;723D04C9 copy eligible lanes             ;K3=tmp_mask; K1=lane_active;
  VPGATHERDD    (SI)(Z24*1),K3,  Z8       //;36FEA5FE gather data                     ;Z8=data_msg; K3=tmp_mask; SI=msg_ptr; Z24=search_base;
  VPERMD        CONST_TAIL_MASK(),Z6,  Z19 //;E5886CFE get tail_mask                  ;Z19=tail_mask; Z6=counter;
  VPANDD        Z8,  Z19, Z8              //;FC6636EA mask data from msg              ;Z8=data_msg; Z19=tail_mask;
  VPANDD.BCST   (R14),Z19, Z9             //;EE8B32D9 data_needle := tail_mask & [needle_ptr];Z9=data_needle; Z19=tail_mask; R14=needle_ptr;
//; compare data with needle
  VPCMPD        $0,  Z9,  Z8,  K1,  K1    //;474761AE K1 &= (data_msg==data_needle)   ;K1=lane_active; Z8=data_msg; Z9=data_needle; 0=Eq;
  VPADDD        Z25, Z2,  K1,  Z2         //;8A3B8A20 str_start += needle_length      ;Z2=str_start; K1=lane_active; Z25=needle_length;
  VPSUBD        Z25, Z3,  K1,  Z3         //;B5FDDA17 str_len -= needle_length        ;Z3=str_len; K1=lane_active; Z25=needle_length;
next:
  NEXT()
//; #endregion bcContainsPrefixCs

//; #region bcContainsPrefixCi
//; equal ascii string in slice in Z2:Z3, with stack[imm]
TEXT bcContainsPrefixCi(SB), NOSPLIT|NOFRAME, $0
  IMM_FROM_DICT(R14)                      //;05667C35 load *[]byte with the provided str into R14
  VPBROADCASTD  8(R14),Z6                 //;713DF24F bcst needle_length              ;Z6=counter; R14=needle_slice;
  VPTESTMD      Z6,  Z6,  K1,  K1         //;EF7C0710 K1 &= (counter != 0)            ;K1=lane_active; Z6=counter;
  VPCMPD        $5,  Z6,  Z3,  K1,  K1    //;502E314F K1 &= (str_len>=counter)        ;K1=lane_active; Z3=str_len; Z6=counter; 5=GreaterEq;
  KTESTW        K1,  K1                   //;C28D3832 any lane still alive            ;K1=lane_active;
  JZ            next                      //;4DA2206F no, exit; jump if zero (ZF = 1) ;
  MOVQ          (R14),R14                 //;D2647DF0 load needle_ptr                 ;R14=needle_ptr; R14=needle_slice;
  VPBROADCASTB  CONSTB_32(),Z15           //;5B8F2908 load constant 0b00100000        ;Z15=c_0b00100000;
  VPBROADCASTB  CONSTB_97(),Z16           //;5D5B0014 load constant ASCII a           ;Z16=char_a;
  VPBROADCASTB  CONSTB_122(),Z17          //;8E2ED824 load constant ASCII z           ;Z17=char_z;
  VPXORD        Z11, Z11, Z11             //;81C90120 load constant 0                 ;Z11=0;
  VPBROADCASTD  CONSTD_4(),Z20            //;C8AFBE50 load constant 4                 ;Z20=4;

  VMOVDQA32     Z2,  Z24                  //;6F6F1342 search_base := str_start        ;Z24=search_base; Z2=str_start;
  VMOVDQA32     Z6,  Z25                  //;6F6F1343 needle_len := counter           ;Z25=needle_len; Z6=counter;
  JMP           tests                     //;F2A3982D                                 ;
loop:
//; load data
  KMOVW         K1,  K3                   //;723D04C9 copy eligible lanes             ;K3=tmp_mask; K1=lane_active;
  VPGATHERDD    (SI)(Z24*1),K3,  Z8       //;E4967C89 gather data                     ;Z8=data_msg; K3=tmp_mask; SI=msg_ptr; Z24=search_base;
  VPSUBD        Z20, Z6,  K1,  Z6         //;AEDCD850 counter -= 4                    ;Z6=counter; K1=lane_active; Z20=4;
  VPADDD        Z20, Z24, K1,  Z24        //;D7CC90DD search_base += 4                ;Z24=search_base; K1=lane_active; Z20=4;
//; str_to_upper: IN zmm8; OUT zmm13
  VPCMPB        $5,  Z16, Z8,  K3         //;30E9B9FD K3 := (data_msg>=char_a)        ;K3=tmp_mask; Z8=data_msg; Z16=char_a; 5=GreaterEq;
  VPCMPB        $2,  Z17, Z8,  K3,  K3    //;8CE85BA0 K3 &= (data_msg<=char_z)        ;K3=tmp_mask; Z8=data_msg; Z17=char_z; 2=LessEq;
  VPMOVM2B      K3,  Z13                  //;ADC21F45 mask with selected chars        ;Z13=data_msg_upper; K3=tmp_mask;
  VPTERNLOGQ    $76, Z15, Z8,  Z13        //;1BB96D97 see stringext.md                ;Z13=data_msg_upper; Z8=data_msg; Z15=c_0b00100000;
//; compare data with needle
  VPCMPD.BCST   $0,  (R14),Z13, K1,  K1   //;F0E5B3BD K1 &= (data_msg_upper==[needle_ptr]);K1=lane_active; Z13=data_msg_upper; R14=needle_ptr; 0=Eq;
  ADDQ          $4,  R14                  //;B2EF9837 needle_ptr += 4                 ;R14=needle_ptr;
tests:
  VPCMPD        $2,  Z6,  Z11, K1,  K1    //;8A1022B4 K1 &= (0<=counter)              ;K1=lane_active; Z11=0; Z6=counter; 2=LessEq;
  VPCMPD        $6,  Z20, Z6,  K3         //;99392208 K3 := (counter>4)               ;K3=tmp_mask; Z6=counter; Z20=4; 6=Greater;
  KTESTW        K1,  K1                   //;FE455439 any lanes still alive           ;K1=lane_active;
  JZ            next                      //;CD5F484F no, exit; jump if zero (ZF = 1) ;
  KTESTW        K1,  K3                   //;C28D3832 ZF := ((K3&K1)==0); CF := ((~K3&K1)==0);K3=tmp_mask; K1=lane_active;
  JNZ           loop                      //;B678BE90 no, loop again; jump if not zero (ZF = 0);
//; load data
  KMOVW         K1,  K3                   //;723D04C9 copy eligible lanes             ;K3=tmp_mask; K1=lane_active;
  VPGATHERDD    (SI)(Z24*1),K3,  Z8       //;36FEA5FE gather data                     ;Z8=data_msg; K3=tmp_mask; SI=msg_ptr; Z24=search_base;
  VPERMD        CONST_TAIL_MASK(),Z6,  Z19 //;E5886CFE get tail_mask                  ;Z19=tail_mask; Z6=counter;
  VPANDD        Z8,  Z19, Z8              //;FC6636EA mask data from msg              ;Z8=data_msg; Z19=tail_mask;
  VPANDD.BCST   (R14),Z19, Z9             //;EE8B32D9 data_needle := tail_mask & [needle_ptr];Z9=data_needle; Z19=tail_mask; R14=needle_ptr;
//; str_to_upper: IN zmm8; OUT zmm13
  VPCMPB        $5,  Z16, Z8,  K3         //;30E9B9FD K3 := (data_msg>=char_a)        ;K3=tmp_mask; Z8=data_msg; Z16=char_a; 5=GreaterEq;
  VPCMPB        $2,  Z17, Z8,  K3,  K3    //;8CE85BA0 K3 &= (data_msg<=char_z)        ;K3=tmp_mask; Z8=data_msg; Z17=char_z; 2=LessEq;
  VPMOVM2B      K3,  Z13                  //;ADC21F45 mask with selected chars        ;Z13=data_msg_upper; K3=tmp_mask;
  VPTERNLOGQ    $76, Z15, Z8,  Z13        //;1BB96D97 see stringext.md                ;Z13=data_msg_upper; Z8=data_msg; Z15=c_0b00100000;
//; compare data with needle
  VPCMPD        $0,  Z9,  Z13, K1,  K1    //;474761AE K1 &= (data_msg_upper==data_needle);K1=lane_active; Z13=data_msg_upper; Z9=data_needle; 0=Eq;
  VPADDD        Z25, Z2,  K1,  Z2         //;8A3B8A20 str_start += needle_length      ;Z2=str_start; K1=lane_active; Z25=needle_length;
  VPSUBD        Z25, Z3,  K1,  Z3         //;B5FDDA17 str_len -= needle_length        ;Z3=str_len; K1=lane_active; Z25=needle_length;
next:
  NEXT()
//; #endregion bcContainsPrefixCi

//; #region bcContainsPrefixUTF8Ci
//; empty needles or empty data always result in a dead lane
TEXT bcContainsPrefixUTF8Ci(SB), NOSPLIT|NOFRAME, $0
  IMM_FROM_DICT(R14)                      //;05667C35 load *[]byte with the provided str into R14
  MOVQ          (R14),R14                 //;D2647DF0 load needle_ptr                 ;R14=needle_ptr; R14=needle_slice;
  MOVL          (R14),CX                  //;5B83F09F load number of code-points      ;CX=n_runes; R14=needle_ptr;
  VPBROADCASTD  CX,  Z26                  //;485C8362 bcst number of code-points      ;Z26=scratch_Z26; CX=n_runes;
  VPTESTMD      Z26, Z26, K1,  K1         //;CD49D8A5 K1 &= (scratch_Z26 != 0); empty needles are dead lanes;K1=lane_active; Z26=scratch_Z26;
  VPCMPD        $2,  Z3,  Z26, K1,  K1    //;B73A4F83 K1 &= (scratch_Z26<=str_len)    ;K1=lane_active; Z26=scratch_Z26; Z3=str_len; 2=LessEq;
  KTESTW        K1,  K1                   //;5746030A any lanes still alive?          ;K1=lane_active;
  JZ            next                      //;B763A908 no, exit; jump if zero (ZF = 1) ;

  ADDQ          $4,  R14                  //;7B0665F3 needle_ptr += 4                 ;R14=needle_ptr;
  VMOVDQU32     CONST_TAIL_MASK(),Z18     //;7DB21CB0 load tail_mask_data             ;Z18=tail_mask_data;
  VMOVDQU32     CONST_N_BYTES_UTF8(),Z21  //;B323211A load table_n_bytes_utf8         ;Z21=table_n_bytes_utf8;
  VPBROADCASTD  CONSTD_4(),Z20            //;C8AFBE50 load constant 4                 ;Z20=4;
  VPBROADCASTB  CONSTB_32(),Z15           //;5B8F2908 load constant 0b00100000        ;Z15=c_0b00100000;
  VPBROADCASTB  CONSTB_97(),Z16           //;5D5B0014 load constant ASCII a           ;Z16=char_a;
  VPBROADCASTB  CONSTB_122(),Z17          //;8E2ED824 load constant ASCII z           ;Z17=char_z;

loop:
  VPTESTMD      Z3,  Z3,  K1,  K1         //;790C4E82 K1 &= (str_len != 0); empty data are dead lanes;K1=lane_active; Z3=str_len;
  KMOVW         K1,  K3                   //;723D04C9 copy eligible lanes             ;K3=tmp_mask; K1=lane_active;
  VPGATHERDD    (SI)(Z2*1),K3,  Z8        //;E4967C89 gather data                     ;Z8=data_msg; K3=tmp_mask; SI=msg_ptr; Z2=str_start;

//; NOTE: debugging. If you jump from here to mixed_ascii you bypass the 4 ASCII optimization
//;  JMP           mixed_ascii               //;6FE3345D                                 ;

  CMPL          CX,  $4                   //;E273EEEA are we in the needle tail?      ;CX=n_runes;
  JL            mixed_ascii               //;A8685FD7 yes, then jump; jump if less (SF neq OF);
  VPBROADCASTD.Z 16(R14),K1,  Z9          //;2694A02F load needle data                ;Z9=data_needle; K1=lane_active; R14=needle_ptr;

//; clear tail from data: IN zmm8; OUT zmm8
  VPMINSD       Z3,  Z20, Z26             //;DEC17BF3 scratch_Z26 := min(4, str_len)  ;Z26=scratch_Z26; Z20=4; Z3=str_len;
  VPERMD        Z18, Z26, Z19             //;E5886CFE get tail_mask                   ;Z19=tail_mask; Z26=scratch_Z26; Z18=tail_mask_data;
  VPANDD        Z8,  Z19, Z8              //;64208067 mask data from msg              ;Z8=data_msg; Z19=tail_mask;

//; determine if either data or needle has non-ASCII content
  VPORD.Z       Z8,  Z9,  K1,  Z26        //;3692D686 scratch_Z26 := data_needle | data_msg;Z26=scratch_Z26; K1=lane_active; Z9=data_needle; Z8=data_msg;
  VPMOVB2M      Z26, K3                   //;5303B427 get 64 sign-bits                ;K3=tmp_mask; Z26=scratch_Z26;
  KTESTQ        K3,  K3                   //;A2B0951C all sign-bits zero?             ;K3=tmp_mask;
  JNZ           mixed_ascii               //;303EFD4D no, found a non-ascii char; jump if not zero (ZF = 0);

//; str_to_upper: IN zmm8; OUT zmm13
  VPCMPB        $5,  Z16, Z8,  K3         //;30E9B9FD K3 := (data_msg>=char_a)        ;K3=tmp_mask; Z8=data_msg; Z16=char_a; 5=GreaterEq;
  VPCMPB        $2,  Z17, Z8,  K3,  K3    //;8CE85BA0 K3 &= (data_msg<=char_z)        ;K3=tmp_mask; Z8=data_msg; Z17=char_z; 2=LessEq;
  VPMOVM2B      K3,  Z13                  //;ADC21F45 mask with selected chars        ;Z13=data_msg_upper; K3=tmp_mask;
  VPTERNLOGQ    $76, Z15, Z8,  Z13        //;1BB96D97 see stringext.md                ;Z13=data_msg_upper; Z8=data_msg; Z15=c_0b00100000;
//; compare data with needle for 4 ASCIIs
  VPCMPD        $0,  Z13, Z9,  K1,  K1    //;BBBDF880 K1 &= (data_needle==data_msg_upper);K1=lane_active; Z9=data_needle; Z13=data_msg_upper; 0=Eq;
  KTESTW        K1,  K1                   //;5746030A any lanes still alive?          ;K1=lane_active;
  JZ            next                      //;B763A908 no, exit; jump if zero (ZF = 1) ;

//; advance to the next 4 ASCIIs
  VPADDD        Z20, Z2,  K1,  Z2         //;D7CC90DD str_start += 4                  ;Z2=str_start; K1=lane_active; Z20=4;
  VPSUBD        Z20, Z3,  K1,  Z3         //;AEDCD850 str_len -= 4                    ;Z3=str_len; K1=lane_active; Z20=4;
  ADDQ          $80, R14                  //;F0BC3163 needle_ptr += 80                ;R14=needle_ptr;
  SUBL          $4,  CX                   //;646B86C9 n_runes -= 4                    ;CX=n_runes;
  JG            loop                      //;1EBC2C20 jump if greater ((ZF = 0) and (SF = OF));
  JMP           next                      //;2230EE05                                 ;

mixed_ascii:
//; select next UTF8 byte sequence
  VPSRLD        $4,  Z8,  Z26             //;FE5F1413 scratch_Z26 := data_msg>>4      ;Z26=scratch_Z26; Z8=data_msg;
  VPERMD        Z21, Z26, Z7              //;68FECBA0 get n_bytes_data                ;Z7=n_bytes_data; Z26=scratch_Z26; Z21=table_n_bytes_utf8;
  VPERMD        Z18, Z7,  Z19             //;E5886CFE get tail_mask                   ;Z19=tail_mask; Z7=n_bytes_data; Z18=tail_mask_data;
  VPANDD        Z8,  Z19, Z8              //;FC6636EA mask data from msg              ;Z8=data_msg; Z19=tail_mask;

//; compare data with needle for 1 UTF8 byte sequence
  VPCMPD.BCST   $0,  (R14),Z8,  K1,  K3   //;345D0BF3 K3 := K1 & (data_msg==[needle_ptr]);K3=tmp_mask; K1=lane_active; Z8=data_msg; R14=needle_ptr; 0=Eq;
  VPCMPD.BCST   $0,  4(R14),Z8,  K1,  K4  //;EFD0A9A3 K4 := K1 & (data_msg==[needle_ptr+4]);K4=alt2_match; K1=lane_active; Z8=data_msg; R14=needle_ptr; 0=Eq;
  VPCMPD.BCST   $0,  8(R14),Z8,  K1,  K5  //;CAC0FAC6 K5 := K1 & (data_msg==[needle_ptr+8]);K5=alt3_match; K1=lane_active; Z8=data_msg; R14=needle_ptr; 0=Eq;
  VPCMPD.BCST   $0,  12(R14),Z8,  K1,  K6  //;50C70740 K6 := K1 & (data_msg==[needle_ptr+12]);K6=alt4_match; K1=lane_active; Z8=data_msg; R14=needle_ptr; 0=Eq;
  KORW          K3,  K4,  K3              //;58E49245 tmp_mask |= alt2_match          ;K3=tmp_mask; K4=alt2_match;
  KORW          K3,  K5,  K3              //;BDCB8940 tmp_mask |= alt3_match          ;K3=tmp_mask; K5=alt3_match;
  KORW          K6,  K3,  K1              //;AAF6ED91 lane_active := tmp_mask | alt4_match;K1=lane_active; K3=tmp_mask; K6=alt4_match;
  KTESTW        K1,  K1                   //;5746030A any lanes still alive?          ;K1=lane_active;
  JZ            next                      //;B763A908 no, exit; jump if zero (ZF = 1) ;

//; advance to the next rune
  VPADDD        Z7,  Z2,  K1,  Z2         //;DFE8D20B str_start += n_bytes_data       ;Z2=str_start; K1=lane_active; Z7=n_bytes_data;
  VPSUBD        Z7,  Z3,  K1,  Z3         //;24E04BE7 str_len -= n_bytes_data         ;Z3=str_len; K1=lane_active; Z7=n_bytes_data;
  ADDQ          $20, R14                  //;1F8D79B1 needle_ptr += 20                ;R14=needle_ptr;
  DECL          CX                        //;A99E9290 n_runes--                       ;CX=n_runes;
  JG            loop                      //;80013DFA jump if greater ((ZF = 0) and (SF = OF));

next:
  NEXT()

//; #endregion bcContainsPrefixUTF8Ci

//; #region bcLengthStr
//; count number of UTF-8 code-points in Z2:Z3 (str interpretation); store the result in Z2:Z3 (int64 interpretation)
TEXT bcLengthStr(SB), NOSPLIT|NOFRAME, $0
  VPBROADCASTD  CONSTD_1(),Z10            //;6F57EE92 load constant 1                 ;Z10=constd_1;
  VPBROADCASTD  CONSTD_4(),Z20            //;C8AFBE50 load constant 4                 ;Z20=constd_4;
  VPBROADCASTB  CONSTD_0x80(),Z27         //;96E41B4F load constant 80808080          ;Z27=constd_80808080;
  VMOVDQU32     CONST_TAIL_MASK(),Z18     //;7DB21CB0 load tail_mask_data             ;Z18=tail_mask_data;
  VMOVDQU32     CONST_N_BYTES_UTF8(),Z21  //;B323211A load table_n_bytes_utf8         ;Z21=table_n_bytes_utf8;
  VPXORD        Z11, Z11, Z11             //;81C90120 load constant 0                 ;Z11=constd_0;
  VPXORD        Z6,  Z6,  Z6              //;F292B105 counter := 0                    ;Z6=counter;
  JMP           test                      //;4CAF1B53                                 ;
loop:
  KMOVW         K2,  K3                   //;723D04C9 copy eligible lanes             ;K3=tmp_mask; K2=lane2_mask;
  VPXORD        Z8,  Z8,  Z8              //;CED5BB69 data_msg := 0                   ;Z8=data_msg;
  VPGATHERDD    (SI)(Z2*1),K3,  Z8        //;E4967C89 gather data                     ;Z8=data_msg; K3=tmp_mask; SI=msg_ptr; Z2=str_start;

  VPMINSD       Z20, Z3,  Z7              //;DDF0DB53 n_bytes_data := min(str_length, 4);Z7=n_bytes_data; Z3=str_length; Z20=constd_4;
  VPERMD        Z18, Z7,  Z19             //;8F3EBC09 get tail_mask                   ;Z19=tail_mask; Z7=n_bytes_data; Z18=tail_mask_data;
  VPANDD        Z8,  Z19, Z8              //;EF91B1F3 remove tail from data           ;Z8=data_msg; Z19=tail_mask;
  VPMOVB2M      Z8,  K3                   //;F22D958D get 64 sign-bits                ;K3=tmp_mask; Z8=data_msg;
  KTESTQ        K3,  K3                   //;F2C8F6C8 all sign-bits zero?             ;K3=tmp_mask;
  JNZ           non_ascii                 //;71B77ACE no: non-ascii present; jump if not zero (ZF = 0);
  VPADDD        Z7,  Z6,  K2,  Z6         //;978F956A counter += n_bytes_data         ;Z6=counter; K2=lane2_mask; Z7=n_bytes_data;

update:
  VPSUBD        Z7,  Z3,  K2,  Z3         //;B69EBA11 str_length -= n_bytes_data      ;Z3=str_length; K2=lane2_mask; Z7=n_bytes_data;
  VPADDD        Z7,  Z2,  K2,  Z2         //;45909060 str_start += n_bytes_data       ;Z2=str_start; K2=lane2_mask; Z7=n_bytes_data;

test:
//; We could compare Z2 > end_of_str, and remove the above sub Z3, but the min(4, Z3) prevents that
  VPCMPD        $6,  Z11, Z3,  K1,  K2    //;DA211F9B K2 := K1 & (str_length>0)       ;K2=lane2_mask; K1=lane_active; Z3=str_length; Z11=constd_0; 6=Greater;
  KTESTW        K2,  K2                   //;799F076E all lanes done? 0 means lane is done;K2=lane2_mask;
  JNZ           loop                      //;203DDAE1 if some lanes alive then loop; jump if not zero (ZF = 0);

  VPMOVZXDQ     Y6,  Z2                   //;9CA47A78 cast 8 x int32 to 8 x int64     ;Z2=str_start; Z6=counter;
  VEXTRACTI32X8 $1,  Z6,  Y6              //;DC597720 256-bits to lower lane          ;Z6=counter;
  VPMOVZXDQ     Y6,  Z3                   //;C24D656F cast 8 x int32 to 8 x int64     ;Z3=str_length; Z6=counter;
  NEXT()

non_ascii:  //; NOTE: this is the assumed to be a somewhat unlikely branch
  VPTESTNMD     Z27, Z8,  K2,  K3         //;85E34261 K3 is all-ascii lanes           ;K3=tmp_mask; K2=lane2_mask; Z8=data_msg; Z27=constd_80808080;
  VPADDD        Z7,  Z6,  K3,  Z6         //;D765BB59 for all ascii lanes             ;Z6=counter; K3=tmp_mask; Z7=n_bytes_data;
  KANDNW        K2,  K3,  K3              //;5A982E07 K3 is mixed-ascii lanes         ;K3=tmp_mask; K2=lane2_mask;
  VPADDD        Z10, Z6,  K3,  Z6         //;8E335D11 for mixed-ascii lanes           ;Z6=counter; K3=tmp_mask; Z10=constd_1;
  VPSRLD        $4,  Z8,  Z26             //;FE5F1413 shift 4 bits to right           ;Z26=scratch_Z26; Z8=data_msg;
  VPERMD        Z21, Z26, K3,  Z7         //;68FECBA0 get n_bytes_data                ;Z7=n_bytes_data; K3=tmp_mask; Z26=scratch_Z26; Z21=table_n_bytes_utf8;
  JMP           update                    //;A596F5F6                                 ;
//; #endregion bcLengthStr

//; #region bcSubstr
//; Get a substring of UTF-8 code-points in Z2:Z3 (str interpretation). The substring starts
//; from the specified start-index and ends at the specified length or at the last character
//; of the string (which ever is first). The start-index is 1-based! The first index of the
//; string starts at 1. The substring is stored in Z2:Z3 (str interpretation)
TEXT bcSubstr(SB), NOSPLIT|NOFRAME, $0
//; load from stack-slot: load 16x uint32 into Z6
  LOADARG1Z(Z27, Z28)
  VPMOVQD       Z27, Y27                  //;17FCB103 truncate uint64 to uint32       ;Z27=scratch_Z27;
  VPMOVQD       Z28, Y28                  //;8F762E8E truncate uint64 to uint32       ;Z28=scratch_Z28;
  VINSERTI64X4  $1,  Y28, Z27, Z6         //;3944001B merge into 16x uint32           ;Z6=counter; Z27=scratch_Z27; Z28=scratch_Z28;
//; load from stack-slot: load 16x uint32 into Z12
  LOADARG1Z(Z27, Z28)
  VPMOVQD       Z27, Y27                  //;17FCB103 truncate uint64 to uint32       ;Z27=scratch_Z27;
  VPMOVQD       Z28, Y28                  //;8F762E8E truncate uint64 to uint32       ;Z28=scratch_Z28;
  VINSERTI64X4  $1,  Y28, Z27, Z12        //;3944001B merge into 16x uint32           ;Z12=substr_length; Z27=scratch_Z27; Z28=scratch_Z28;
//; load constants
  VMOVDQU32     CONST_N_BYTES_UTF8(),Z21  //;B323211A load table_n_bytes_utf8         ;Z21=table_n_bytes_utf8;
  VPXORD        Z11, Z11, Z11             //;81C90120 load constant 0                 ;Z11=0;
  VPBROADCASTD  CONSTD_1(),Z10            //;6F57EE92 load constant 1                 ;Z10=1;
  VMOVDQA32     Z2,  Z4                   //;CFB0D832 curr_offset := str_start        ;Z4=curr_offset; Z2=str_start;
//; fixup parameters
  VPSUBD        Z10, Z6,  Z6              //;34951830 1-based to 0-based indices      ;Z6=counter; Z10=1;
  VPMAXSD       Z6,  Z11, Z6              //;18F03020 counter := max(0, counter)      ;Z6=counter; Z11=0;

//; find start of substring
  JMP           test1                     //;4CAF1B53                                 ;
loop1:
//; load next code-point
  KMOVW         K2,  K3                   //;723D04C9 copy eligible lanes             ;K3=tmp_mask; K2=lane2_mask;
  VPGATHERDD    (SI)(Z4*1),K3,  Z8        //;FC80CF41 gather data                     ;Z8=data_msg; K3=tmp_mask; SI=msg_ptr; Z4=curr_offset;
  VPSUBD        Z10, Z6,  Z6              //;19C9DC47 counter--                       ;Z6=counter; Z10=1;
//; get number of bytes in next code-point
  VPSRLD        $4,  Z8,  Z26             //;FE5F1413 scratch_Z26 := data_msg>>4      ;Z26=scratch_Z26; Z8=data_msg;
  VPERMD        Z21, Z26, Z7              //;68FECBA0 get n_bytes_data                ;Z7=n_bytes_data; Z26=scratch_Z26; Z21=table_n_bytes_utf8;
//; advance
  VPADDD        Z7,  Z4,  K2,  Z4         //;45909060 curr_offset += n_bytes_data     ;Z4=curr_offset; K2=lane2_mask; Z7=n_bytes_data;
  VPSUBD        Z7,  Z3,  K2,  Z3         //;B69EBA11 str_len -= n_bytes_data         ;Z3=str_len; K2=lane2_mask; Z7=n_bytes_data;
test1:
  VPCMPD        $6,  Z11, Z6,  K1,  K2    //;2E4360D2 K2 := K1 & (counter>0); any chars left to skip?;K2=lane2_mask; K1=lane_active; Z6=counter; Z11=0; 6=Greater;
  VPCMPD        $6,  Z11, Z3,  K2,  K2    //;DA211F9B K2 &= (str_len>0)               ;K2=lane2_mask; Z3=str_len; Z11=0; 6=Greater;
  KTESTW        K2,  K2                   //;799F076E all lanes done? 0 means lane is done;K2=lane2_mask;
  JNZ           loop1                     //;203DDAE1 any lanes todo? yes, then loop; jump if not zero (ZF = 0);

//; At this moment Z4 has the start position of the substring. Next we will calculate the length of the substring in Z3.
  VMOVDQA32     Z4,  Z2                   //;60EBBEED str_start := curr_offset        ;Z2=str_start; Z4=curr_offset;

//; find end of substring
  JMP           test2                     //;4CAF1B53                                 ;
loop2:
//; load next code-point
  KMOVW         K2,  K3                   //;723D04C9 copy eligible lanes             ;K3=tmp_mask; K2=lane2_mask;
  VPGATHERDD    (SI)(Z4*1),K3,  Z8        //;5A704AF6 gather data                     ;Z8=data_msg; K3=tmp_mask; SI=msg_ptr; Z4=curr_offset;
  VPSUBD        Z10, Z12, Z12             //;61D287CD substr_length--                 ;Z12=substr_length; Z10=1;
//; get number of bytes in next code-point
  VPSRLD        $4,  Z8,  Z26             //;FE5F1413 scratch_Z26 := data_msg>>4      ;Z26=scratch_Z26; Z8=data_msg;
  VPERMD        Z21, Z26, Z7              //;68FECBA0 get n_bytes_data                ;Z7=n_bytes_data; Z26=scratch_Z26; Z21=table_n_bytes_utf8;
//; advance
  VPADDD        Z7,  Z4,  K2,  Z4         //;45909060 curr_offset += n_bytes_data     ;Z4=curr_offset; K2=lane2_mask; Z7=n_bytes_data;
  VPSUBD        Z7,  Z3,  K2,  Z3         //;B69EBA11 str_len -= n_bytes_data         ;Z3=str_len; K2=lane2_mask; Z7=n_bytes_data;
test2:
  VPCMPD        $6,  Z11, Z12, K1,  K2    //;2E4360D2 K2 := K1 & (substr_length>0); any chars left to trim;K2=lane2_mask; K1=lane_active; Z12=substr_length; Z11=0; 6=Greater;
  VPCMPD        $6,  Z11, Z3,  K2,  K2    //;DA211F9B K2 &= (str_len>0); all lanes done?;K2=lane2_mask; Z3=str_len; Z11=0; 6=Greater;
  KTESTW        K2,  K2                   //;799F076E 0 means lane is done            ;K2=lane2_mask;
  JNZ           loop2                     //;203DDAE1 any lanes todo? yes, then loop; jump if not zero (ZF = 0);
//; overwrite str_length with correct values
  VPSUBD        Z2,  Z4,  Z3              //;E24AE85F str_len := curr_offset - str_start;Z3=str_len; Z4=curr_offset; Z2=str_start;
  NEXT()
//; #endregion bcSubstr

//; #region bcSplitPart
//; NOTE: the delimiter cannot be byte 0
TEXT bcSplitPart(SB), NOSPLIT|NOFRAME, $0
  IMM_FROM_DICT(R14)                      //;05667C35 load *[]byte with the provided str into R14
  MOVQ          (R14),R14                 //;FEE415A0                                 ;R14=split_info;
  VPBROADCASTB  (R14),Z21                 //;B4B43F80 bcst delimiter                  ;Z21=delim; R14=split_info;
//; #region load from stack-slot: load 16x uint32 into Z7
  LOADARG1Z(Z27, Z26)
  VPMOVQD       Z27, Y27                  //;17FCB103 truncate uint64 to uint32       ;Z27=scratch_Z27;
  VPMOVQD       Z26, Y26                  //;8F762E8E truncate uint64 to uint32       ;Z26=scratch_Z26;
  VINSERTI64X4  $1,  Y26, Z27, Z7         //;3944001B merge into 16x uint32           ;Z7=counter_delim; Z27=scratch_Z27; Z26=scratch_Z26;
//; #endregion load from stack-slot
  VPBROADCASTD  CONSTD_1(),Z10            //;6F57EE92 load constant 1                 ;Z10=1;
  VPBROADCASTD  CONSTD_4(),Z20            //;C8AFBE50 load constant 4                 ;Z20=4;
  VMOVDQU32     bswap32<>(SB),Z22         //;2510A88F load constant_bswap32           ;Z22=constant_bswap32;
  VMOVDQU32     CONST_TAIL_MASK(),Z18     //;7DB21CB0 load tail_mask_data             ;Z18=tail_mask_data;
  VPXORD        Z11, Z11, Z11             //;81C90120 load constant 0                 ;Z11=0;

  KMOVW         K1,  K2                   //;FE3838B3 lane2_mask := lane_active       ;K2=lane2_mask; K1=lane_active;
  VMOVDQA32     Z2,  Z4                   //;CFB0D832 search_base := str_start        ;Z4=search_base; Z2=str_start;
  VPADDD        Z2,  Z3,  Z5              //;E5429114 o_data_end := str_len + str_start;Z5=o_data_end; Z3=str_len; Z2=str_start;
  VPSUBD        Z10, Z7,  Z7              //;68858B39 counter_delim--; (1-based indexing);Z7=counter_delim; Z10=1;

//; #region find n-th delimiter
  JMP           tail1                     //;9DD42F87                                 ;
loop1:
  KMOVW         K2,  K3                   //;723D04C9 copy eligible lanes             ;K3=tmp_mask; K2=lane2_mask;
  VPGATHERDD    (SI)(Z4*1),K3,  Z8        //;FC80CF41 gather data                     ;Z8=data_msg; K3=tmp_mask; SI=msg_ptr; Z4=search_base;
//; clear tail from data
  VPMINSD       Z3,  Z20, Z26             //;DEC17BF3 scratch_Z26 := min(4, str_len)  ;Z26=scratch_Z26; Z20=4; Z3=str_len;
  VPERMD        Z18, Z26, Z19             //;E5886CFE get tail_mask                   ;Z19=tail_mask; Z26=scratch_Z26; Z18=tail_mask_data;
  VPANDD        Z8,  Z19, Z8              //;64208067 mask data from msg              ;Z8=data_msg; Z19=tail_mask;
//; calculate skip_count in zmm14
  VPCMPB        $0,  Z21, Z8,  K3         //;8E3317B0 K3 := (data_msg==delim)         ;K3=tmp_mask; Z8=data_msg; Z21=delim; 0=Eq;
  VPMOVM2B      K3,  Z14                  //;E74FDEBD promote 64x bit to 64x byte     ;Z14=skip_count; K3=tmp_mask;
  VPSHUFB       Z22, Z14, Z14             //;4F265F03 reverse byte order              ;Z14=skip_count; Z22=constant_bswap32;
  VPLZCNTD      Z14, Z14                  //;72202F9A count leading zeros             ;Z14=skip_count;
  VPSRLD        $3,  Z14, Z14             //;6DC91432 divide by 8 yields skip_count   ;Z14=skip_count;
//; advance
  VPADDD        Z14, Z4,  K2,  Z4         //;5034DEA0 search_base += skip_count       ;Z4=search_base; K2=lane2_mask; Z14=skip_count;
  VPSUBD        Z14, Z3,  K2,  Z3         //;95AAE700 str_len -= skip_count           ;Z3=str_len; K2=lane2_mask; Z14=skip_count;
//; did we encounter a delimiter?
  VPCMPD        $4,  Z20, Z14, K2,  K3    //;80B9AEA2 K3 := K2 & (skip_count!=4); active lanes where skip != 4;K3=tmp_mask; K2=lane2_mask; Z14=skip_count; Z20=4; 4=NotEqual;
  VPSUBD        Z10, Z7,  K3,  Z7         //;35E75E57 counter_delim--                 ;Z7=counter_delim; K3=tmp_mask; Z10=1;
  VPSUBD        Z10, Z3,  K3,  Z3         //;AF759B00 str_len--                       ;Z3=str_len; K3=tmp_mask; Z10=1;
  VPADDD        Z10, Z4,  K3,  Z4         //;D5281D43 search_base++                   ;Z4=search_base; K3=tmp_mask; Z10=1;

tail1:
//; still a lane todo?
  VPCMPD        $1,  Z7,  Z11, K2,  K2    //;50E6D99D K2 &= (0<counter_delim)         ;K2=lane2_mask; Z11=0; Z7=counter_delim; 1=LessThen;
  VPCMPD        $1,  Z5,  Z4,  K2,  K2    //;A052FCB6 K2 &= (search_base<o_data_end)  ;K2=lane2_mask; Z4=search_base; Z5=o_data_end; 1=LessThen;
  KTESTW        K2,  K2                   //;799F076E all lanes done? 0 means lane is done;K2=lane2_mask;
  JNZ           loop1                     //;203DDAE1 any lanes todo? yes, then loop; jump if not zero (ZF = 0);
  VPCMPD        $0,  Z7,  Z11, K1,  K1    //;A0ABF51F K1 &= (0==counter_delim)        ;K1=lane_active; Z11=0; Z7=counter_delim; 0=Eq;
//; #endregion find n-th delimiter

  VMOVDQA32     Z4,  K1,  Z2              //;B69A81FE str_start := search_base        ;Z2=str_start; K1=lane_active; Z4=search_base;

//; #region find next delimiter
  KMOVW         K1,  K2                   //;A543DE2E lane2_mask := lane_active       ;K2=lane2_mask; K1=lane_active;
loop2:
  KMOVW         K2,  K3                   //;723D04C9 copy eligible lanes             ;K3=tmp_mask; K2=lane2_mask;
  VPGATHERDD    (SI)(Z4*1),K3,  Z8        //;5A704AF6 gather data                     ;Z8=data_msg; K3=tmp_mask; SI=msg_ptr; Z4=search_base;
//; calculate skip_count in zmm14
  VPCMPB        $0,  Z21, Z8,  K3         //;E8DC9CCA K3 := (data_msg==delim)         ;K3=tmp_mask; Z8=data_msg; Z21=delim; 0=Eq;
  VPMOVM2B      K3,  Z14                  //;E74FDEBD promote 64x bit to 64x byte     ;Z14=skip_count; K3=tmp_mask;
  VPSHUFB       Z22, Z14, Z14             //;4F265F03 reverse byte order              ;Z14=skip_count; Z22=constant_bswap32;
  VPLZCNTD      Z14, Z14                  //;72202F9A count leading zeros             ;Z14=skip_count;
  VPSRLD        $3,  Z14, Z14             //;6DC91432 divide by 8 yields skip_count   ;Z14=skip_count;
//; advance
  VPADDD        Z14, Z4,  K2,  Z4         //;5034DEA0 search_base += skip_count       ;Z4=search_base; K2=lane2_mask; Z14=skip_count;
//; did we encounter a delimiter?
  VPCMPD        $0,  Z20, Z14, K2,  K2    //;80B9AEA2 K2 &= (skip_count==4); active lanes where skip != 4;K2=lane2_mask; Z14=skip_count; Z20=4; 0=Eq;
  VPCMPD        $1,  Z5,  Z4,  K3         //;E2BEF075 K3 := (search_base<o_data_end)  ;K3=tmp_mask; Z4=search_base; Z5=o_data_end; 1=LessThen;
  KTESTW        K3,  K2                   //;799F076E all lanes still todo?           ;K2=lane2_mask; K3=tmp_mask;
  JNZ           loop2                     //;203DDAE1 any lanes todo? yes, then loop; jump if not zero (ZF = 0);
//; #endregion find next delimiter

  VPMINSD       Z5,  Z4,  Z4              //;C62A5921 search_base := min(search_base, o_data_end);Z4=search_base; Z5=o_data_end;
  VPSUBD        Z2,  Z4,  K1,  Z3         //;E24AE85F str_len := search_base - str_start;Z3=str_len; K1=lane_active; Z4=search_base; Z2=str_start;
next:
  NEXT()
//; #endregion bcSplitPart

//; #region bcContainsSubstrCs
TEXT bcContainsSubstrCs(SB), NOSPLIT|NOFRAME, $0
  IMM_FROM_DICT(R14)                      //;05667C35 load *[]byte with the provided str into R14
//; load parameter
  VPBROADCASTD  8(R14),Z6                 //;F6AC18B2 bcst needle_len                 ;Z6=needle_len1; R14=needle_ptr1;
//; restrict lanes to allow fast bail-out
  VPCMPD        $5,  Z6,  Z3,  K1,  K1    //;EE56D9C0 K1 &= (data_len1>=needle_len1)  ;K1=lane_active; Z3=data_len1; Z6=needle_len1; 5=GreaterEq;
  KTESTW        K1,  K1                   //;5746030A any lanes still alive?          ;K1=lane_active;
  JZ            next                      //;B763A908 no, exit; jump if zero (ZF = 1) ;
//; init needle pointer
  MOVQ          (R14),R14                 //;D2647DF0 load needle_ptr                 ;R14=needle_ptr1; R14=needle_slice;
//; load constants
  VMOVDQU32     bswap32<>(SB),Z22         //;A0BC360A load constant bswap32           ;Z22=bswap32;
  VMOVDQU32     CONST_TAIL_MASK(),Z18     //;7DB21CB0 load tail_mask_data             ;Z18=tail_mask_data;
  VPBROADCASTD  CONSTD_1(),Z10            //;6F57EE92 load constant 1                 ;Z10=1;
  VPBROADCASTD  CONSTD_4(),Z20            //;C8AFBE50 load constant 4                 ;Z20=4;
  VPXORD        Z11, Z11, Z11             //;81C90120 load constant 0                 ;Z11=0;
//; init variables for scan_loop
  KMOVW         K1,  K2                   //;ECF269E6 lane_todo := lane_active        ;K2=lane_todo; K1=lane_active;
  KXORW         K1,  K1,  K1              //;6F6437B4 lane_active := 0                ;K1=lane_active;
  VPBROADCASTB  (R14),Z9                  //;54CB0C41 bcst first char from needle     ;Z9=char1_needle; R14=needle_ptr1;

//; scan for the char1_needle in all lane_todo (K2) and accumulate in lane_selected (K4)
scan_start:
  KXORW         K4,  K4,  K4              //;8403FAC0 lane_selected := 0              ;K4=lane_selected;
scan_loop:
  KMOVW         K2,  K3                   //;723D04C9 copy eligible lanes             ;K3=tmp_mask; K2=lane_todo;
  VPXORD        Z8,  Z8,  Z8              //;CED5BB69 if not cleared 170C9C8F will give unncessary matches;Z8=data;
  VPGATHERDD    (SI)(Z2*1),K3,  Z8        //;573D089A gather data from end            ;Z8=data; K3=tmp_mask; SI=data_ptr; Z2=data_off1;
  VPCMPB        $0,  Z9,  Z8,  K3         //;170C9C8F K3 := (data==char1_needle)      ;K3=tmp_mask; Z8=data; Z9=char1_needle; 0=Eq;
  KTESTQ        K3,  K3                   //;AD0284F2 found any char1_needle?         ;K3=tmp_mask;
  JNZ           scan_found_something      //;4645455C yes, found something!; jump if not zero (ZF = 0);
  VPSUBD        Z20, Z3,  K2,  Z3         //;BF319EDC data_len1 -= 4                  ;Z3=data_len1; K2=lane_todo; Z20=4;
  VPADDD        Z20, Z2,  K2,  Z2         //;B5CB47F3 data_off1 += 4                  ;Z2=data_off1; K2=lane_todo; Z20=4;
scan_found_something_ret:                 //;2CADDCF3 reentry code path with found char1_needle
  VPCMPD        $1,  Z3,  Z11, K2,  K2    //;358E0E6F K2 &= (0<data_len1)             ;K2=lane_todo; Z11=0; Z3=data_len1; 1=LessThen;
  KTESTW        K2,  K2                   //;854AE89B any lanes still todo?           ;K2=lane_todo;
  JNZ           scan_loop                 //;5BB6DC39 yes, then continue scanning; jump if not zero (ZF = 0);
  JMP           scan_done                 //;58F52ADF                                 ;

scan_found_something:
//; calculate skip_count in Z14
  VPMOVM2B      K3,  Z27                  //;E74FDEBD promote 64x bit to 64x byte     ;Z27=skip_count; K3=tmp_mask;
  VPSHUFB       Z22, Z27, Z27             //;4F265F03 reverse byte order              ;Z27=skip_count; Z22=bswap32;
  VPLZCNTD      Z27, Z27                  //;72202F9A count leading zeros             ;Z27=skip_count;
  VPSRLD.Z      $3,  Z27, K2,  Z27        //;6DC91432 divide by 8 yields skip_count   ;Z27=skip_count; K2=lane_todo;
//; advance
  VPCMPD        $4,  Z20, Z27, K2,  K3    //;2846C84C K3 := K2 & (skip_count!=4)      ;K3=tmp_mask; K2=lane_todo; Z27=skip_count; Z20=4; 4=NotEqual;
  VPADDD        Z27, Z2,  K2,  Z2         //;63F1BACC data_off1 += skip_count         ;Z2=data_off1; K2=lane_todo; Z27=skip_count;
  VPSUBD        Z27, Z3,  K2,  Z3         //;8F7F978F data_len1 -= skip_count         ;Z3=data_len1; K2=lane_todo; Z27=skip_count;
//; update masks with the found stuff
  KANDNW        K2,  K3,  K2              //;1EA864B0 lane_todo &= ~tmp_mask          ;K2=lane_todo; K3=tmp_mask;
  KORW          K4,  K3,  K4              //;A69E7F6D lane_selected |= tmp_mask       ;K4=lane_selected; K3=tmp_mask;
  JMP           scan_found_something_ret  //;169A16C1 jump back to where we came from ;

scan_done:                                //;50D019A9 check if the ran out of data
  VPCMPD        $5,  Z6,  Z3,  K4,  K4    //;FA18B497 K4 &= (data_len1>=needle_len1)  ;K4=lane_selected; Z3=data_len1; Z6=needle_len1; 5=GreaterEq;
  KTESTW        K4,  K4                   //;9AA8B932 any lanes selected?             ;K4=lane_selected;
  JZ            next                      //;31580AD4 no, then exit; jump if zero (ZF = 1);
//; init variables for needle_loop
  VMOVDQA32     Z2,  Z24                  //;835001A1 data_off2 := data_off1          ;Z24=data_off2; Z2=data_off1;
  VMOVDQA32     Z3,  Z5                   //;31B4F894 data_len2 := data_len1          ;Z5=data_len2; Z3=data_len1;
  VMOVDQA32     Z6,  Z25                  //;E323C56F needle_len2 := needle_len1      ;Z25=needle_len2; Z6=needle_len1;
  MOVQ          R14, R13                  //;92B163CC needle_ptr2 := needle_ptr1      ;R13=needle_ptr2; R14=needle_ptr1;
  KMOVW         K4,  K2                   //;226BBC9E lane_todo := lane_selected      ;K2=lane_todo; K4=lane_selected;
needle_loop:
  KMOVW         K4,  K3                   //;F271B5DF copy eligible lanes             ;K3=tmp_mask; K4=lane_selected;
  VPXORD        Z8,  Z8,  Z8              //;CED5BB69 data := 0                       ;Z8=data;
  VPGATHERDD    (SI)(Z24*1),K3,  Z8       //;2CF4C294 gather data                     ;Z8=data; K3=tmp_mask; SI=data_ptr; Z24=data_off2;
//; load needle and apply tail masks
  VPMINSD       Z20, Z25, Z13             //;7D091557 adv_needle := min(needle_len2, 4);Z13=adv_needle; Z25=needle_len2; Z20=4;
  VPERMD        Z18, Z13, Z27             //;B7D1A978 get tail_mask (needle)          ;Z27=scratch_Z27; Z13=adv_needle; Z18=tail_mask_data;
  VPANDD        Z8,  Z27, Z8              //;5669D792 remove tail from data           ;Z8=data; Z27=scratch_Z27;
  VPANDD.BCST   (R13),Z27, Z28            //;C9F5F9B2 load needle and remove tail     ;Z28=needle; Z27=scratch_Z27; R13=needle_ptr2;
//; compare data with needle
  VPCMPD        $0,  Z28, Z8,  K4,  K4    //;18C82D78 K4 &= (data==needle)            ;K4=lane_selected; Z8=data; Z28=needle; 0=Eq;
//; advance
  VPADDD        Z13, Z24, K4,  Z24        //;3371623C data_off2 += adv_needle         ;Z24=data_off2; K4=lane_selected; Z13=adv_needle;
  VPSUBD        Z13, Z5,  K4,  Z5         //;9905C7C3 data_len2 -= adv_needle         ;Z5=data_len2; K4=lane_selected; Z13=adv_needle;
  VPSUBD        Z13, Z25, K4,  Z25        //;5A8AB52E needle_len2 -= adv_needle       ;Z25=needle_len2; K4=lane_selected; Z13=adv_needle;
  ADDQ          $4,  R13                  //;5D0D7365 needle_ptr2 += 4                ;R13=needle_ptr2;
//; check needle_loop conditions
  VPCMPD        $1,  Z25, Z11, K3         //;D0432359 K3 := (0<needle_len2)           ;K3=tmp_mask; Z11=0; Z25=needle_len2; 1=LessThen;
  KTESTW        K4,  K3                   //;88EB401D any lanes selected & elegible?  ;K3=tmp_mask; K4=lane_selected;
  JNZ           needle_loop               //;F1339C58 yes, then retry scanning; jump if not zero (ZF = 0);
//; update lanes
  KORW          K1,  K4,  K1              //;123EE41E lane_active |= lane_selected    ;K1=lane_active; K4=lane_selected;
  KANDNW        K2,  K4,  K2              //;32D9FB5F lane_todo &= ~lane_selected     ;K2=lane_todo; K4=lane_selected;
  VMOVDQA32     Z24, K4,  Z2              //;5FA56037 data_off1 := data_off2          ;Z2=data_off1; K4=lane_selected; Z24=data_off2;
  VMOVDQA32     Z5,  K4,  Z3              //;8536472E data_len1 := data_len2          ;Z3=data_len1; K4=lane_selected; Z5=data_len2;
//; advance the scan-offsets with 1 and if there are any lanes still todo, scan those
  VPADDD        Z10, Z2,  K2,  Z2         //;65A7A575 data_off1++                     ;Z2=data_off1; K2=lane_todo; Z10=1;
  VPSUBD        Z10, Z3,  K2,  Z3         //;F7731EA7 data_len1--                     ;Z3=data_len1; K2=lane_todo; Z10=1;
  KTESTW        K2,  K2                   //;D8353CAF any lanes todo?                 ;K2=lane_todo;
  JNZ           scan_start                //;68ACA94C yes, then restart scanning; jump if not zero (ZF = 0);
next:
  NEXT()
//; #endregion bcContainsSubstrCs

//; #region bcContainsSubstrCi
TEXT bcContainsSubstrCi(SB), NOSPLIT|NOFRAME, $0
  IMM_FROM_DICT(R14)                      //;05667C35 load *[]byte with the provided str into R14
//; load parameter
  VPBROADCASTD  8(R14),Z6                 //;F6AC18B2 bcst needle_len                 ;Z6=needle_len1; R14=needle_ptr1;
//; restrict lanes to allow fast bail-out
  VPCMPD        $5,  Z6,  Z3,  K1,  K1    //;EE56D9C0 K1 &= (data_len1>=needle_len1)  ;K1=lane_active; Z3=data_len1; Z6=needle_len1; 5=GreaterEq;
  KTESTW        K1,  K1                   //;5746030A any lanes still alive?          ;K1=lane_active;
  JZ            next                      //;B763A908 no, exit; jump if zero (ZF = 1) ;
//; init needle pointer
  MOVQ          (R14),R14                 //;D2647DF0 load needle_ptr                 ;R14=needle_ptr1; R14=needle_slice;
//; load constants
  VPBROADCASTB  CONSTB_32(),Z15           //;5B8F2908 load constant 0b00100000        ;Z15=c_0b00100000;
  VPBROADCASTB  CONSTB_97(),Z16           //;5D5B0014 load constant ASCII a           ;Z16=char_a;
  VPBROADCASTB  CONSTB_122(),Z17          //;8E2ED824 load constant ASCII z           ;Z17=char_z;
  VMOVDQU32     bswap32<>(SB),Z22         //;A0BC360A load constant bswap32           ;Z22=bswap32;
  VMOVDQU32     CONST_TAIL_MASK(),Z18     //;7DB21CB0 load tail_mask_data             ;Z18=tail_mask_data;
  VPBROADCASTD  CONSTD_1(),Z10            //;6F57EE92 load constant 1                 ;Z10=1;
  VPBROADCASTD  CONSTD_4(),Z20            //;C8AFBE50 load constant 4                 ;Z20=4;
  VPXORD        Z11, Z11, Z11             //;81C90120 load constant 0                 ;Z11=0;
//; init variables for scan_loop
  KMOVW         K1,  K2                   //;ECF269E6 lane_todo := lane_active        ;K2=lane_todo; K1=lane_active;
  KXORW         K1,  K1,  K1              //;6F6437B4 lane_active := 0                ;K1=lane_active;
  VPBROADCASTB  (R14),Z9                  //;54CB0C41 bcst first char from needle     ;Z9=char1_needle; R14=needle_ptr1;

//; scan for the char1_needle in all lane_todo (K2) and accumulate in lane_selected (K4)
scan_start:
  KXORW         K4,  K4,  K4              //;8403FAC0 lane_selected := 0              ;K4=lane_selected;
scan_loop:
  KMOVW         K2,  K3                   //;723D04C9 copy eligible lanes             ;K3=tmp_mask; K2=lane_todo;
  VPXORD        Z8,  Z8,  Z8              //;CED5BB69 if not cleared 170C9C8F will give unncessary matches;Z8=data;
  VPGATHERDD    (SI)(Z2*1),K3,  Z8        //;573D089A gather data from end            ;Z8=data; K3=tmp_mask; SI=data_ptr; Z2=data_off1;
//; str_to_upper: IN zmm8; OUT zmm26
  VPCMPB        $5,  Z16, Z8,  K3         //;30E9B9FD K3 := (data>=char_a)            ;K3=tmp_mask; Z8=data; Z16=char_a; 5=GreaterEq;
  VPCMPB        $2,  Z17, Z8,  K3,  K3    //;8CE85BA0 K3 &= (data<=char_z)            ;K3=tmp_mask; Z8=data; Z17=char_z; 2=LessEq;
//; Z15 is 64 bytes with 0b00100000
//;    Z15|Z8 |Z26 => Z26
//;     0 | 0 | 0      0
//;     0 | 0 | 1      0
//;     0 | 1 | 0      1
//;     0 | 1 | 1      1
//;     1 | 0 | 0      0
//;     1 | 0 | 1      0
//;     1 | 1 | 0      1
//;     1 | 1 | 1      0     <= change from lower to upper
  VPMOVM2B      K3,  Z26                  //;ADC21F45 mask with selected chars        ;Z26=scratch_Z26; K3=tmp_mask;
  VPTERNLOGD    $0b01001100,Z15, Z8,  Z26 //;1BB96D97                                 ;Z26=scratch_Z26; Z8=data; Z15=c_0b00100000;
  VPCMPB        $0,  Z9,  Z26, K3         //;170C9C8F K3 := (scratch_Z26==char1_needle);K3=tmp_mask; Z26=scratch_Z26; Z9=char1_needle; 0=Eq;
  KTESTQ        K3,  K3                   //;AD0284F2 found any char1_needle?         ;K3=tmp_mask;
  JNZ           scan_found_something      //;4645455C yes, found something!; jump if not zero (ZF = 0);
  VPSUBD        Z20, Z3,  K2,  Z3         //;BF319EDC data_len1 -= 4                  ;Z3=data_len1; K2=lane_todo; Z20=4;
  VPADDD        Z20, Z2,  K2,  Z2         //;B5CB47F3 data_off1 += 4                  ;Z2=data_off1; K2=lane_todo; Z20=4;
scan_found_something_ret:                 //;2CADDCF3 reentry code path with found char1_needle
  VPCMPD        $1,  Z3,  Z11, K2,  K2    //;358E0E6F K2 &= (0<data_len1)             ;K2=lane_todo; Z11=0; Z3=data_len1; 1=LessThen;
  KTESTW        K2,  K2                   //;854AE89B any lanes still todo?           ;K2=lane_todo;
  JNZ           scan_loop                 //;5BB6DC39 yes, then continue scanning; jump if not zero (ZF = 0);
  JMP           scan_done                 //;58F52ADF                                 ;

scan_found_something:
//; calculate skip_count in Z14
  VPMOVM2B      K3,  Z27                  //;E74FDEBD promote 64x bit to 64x byte     ;Z27=skip_count; K3=tmp_mask;
  VPSHUFB       Z22, Z27, Z27             //;4F265F03 reverse byte order              ;Z27=skip_count; Z22=bswap32;
  VPLZCNTD      Z27, Z27                  //;72202F9A count leading zeros             ;Z27=skip_count;
  VPSRLD.Z      $3,  Z27, K2,  Z27        //;6DC91432 divide by 8 yields skip_count   ;Z27=skip_count; K2=lane_todo;
//; advance
  VPCMPD        $4,  Z20, Z27, K2,  K3    //;2846C84C K3 := K2 & (skip_count!=4)      ;K3=tmp_mask; K2=lane_todo; Z27=skip_count; Z20=4; 4=NotEqual;
  VPADDD        Z27, Z2,  K2,  Z2         //;63F1BACC data_off1 += skip_count         ;Z2=data_off1; K2=lane_todo; Z27=skip_count;
  VPSUBD        Z27, Z3,  K2,  Z3         //;8F7F978F data_len1 -= skip_count         ;Z3=data_len1; K2=lane_todo; Z27=skip_count;
//; update masks with the found stuff
  KANDNW        K2,  K3,  K2              //;1EA864B0 lane_todo &= ~tmp_mask          ;K2=lane_todo; K3=tmp_mask;
  KORW          K4,  K3,  K4              //;A69E7F6D lane_selected |= tmp_mask       ;K4=lane_selected; K3=tmp_mask;
  JMP           scan_found_something_ret  //;169A16C1 jump back to where we came from ;

scan_done:                                //;50D019A9 check if the ran out of data
  VPCMPD        $5,  Z6,  Z3,  K4,  K4    //;FA18B497 K4 &= (data_len1>=needle_len1)  ;K4=lane_selected; Z3=data_len1; Z6=needle_len1; 5=GreaterEq;
  KTESTW        K4,  K4                   //;9AA8B932 any lanes selected?             ;K4=lane_selected;
  JZ            next                      //;31580AD4 no, then exit; jump if zero (ZF = 1);
//; init variables for needle_loop
  VMOVDQA32     Z2,  Z24                  //;835001A1 data_off2 := data_off1          ;Z24=data_off2; Z2=data_off1;
  VMOVDQA32     Z3,  Z5                   //;31B4F894 data_len2 := data_len1          ;Z5=data_len2; Z3=data_len1;
  VMOVDQA32     Z6,  Z25                  //;E323C56F needle_len2 := needle_len1      ;Z25=needle_len2; Z6=needle_len1;
  MOVQ          R14, R13                  //;92B163CC needle_ptr2 := needle_ptr1      ;R13=needle_ptr2; R14=needle_ptr1;
  KMOVW         K4,  K2                   //;226BBC9E lane_todo := lane_selected      ;K2=lane_todo; K4=lane_selected;
needle_loop:
  KMOVW         K4,  K3                   //;F271B5DF copy eligible lanes             ;K3=tmp_mask; K4=lane_selected;
  VPXORD        Z8,  Z8,  Z8              //;CED5BB69 data := 0                       ;Z8=data;
  VPGATHERDD    (SI)(Z24*1),K3,  Z8       //;2CF4C294 gather data                     ;Z8=data; K3=tmp_mask; SI=data_ptr; Z24=data_off2;
//; str_to_upper: IN zmm8; OUT zmm26
  VPCMPB        $5,  Z16, Z8,  K3         //;30E9B9FD K3 := (data>=char_a)            ;K3=tmp_mask; Z8=data; Z16=char_a; 5=GreaterEq;
  VPCMPB        $2,  Z17, Z8,  K3,  K3    //;8CE85BA0 K3 &= (data<=char_z)            ;K3=tmp_mask; Z8=data; Z17=char_z; 2=LessEq;
//; Z15 is 64 bytes with 0b00100000
//;    Z15|Z8 |Z26 => Z26
//;     0 | 0 | 0      0
//;     0 | 0 | 1      0
//;     0 | 1 | 0      1
//;     0 | 1 | 1      1
//;     1 | 0 | 0      0
//;     1 | 0 | 1      0
//;     1 | 1 | 0      1
//;     1 | 1 | 1      0     <= change from lower to upper
  VPMOVM2B      K3,  Z26                  //;ADC21F45 mask with selected chars        ;Z26=scratch_Z26; K3=tmp_mask;
  VPTERNLOGD    $0b01001100,Z15, Z8,  Z26 //;1BB96D97                                 ;Z26=scratch_Z26; Z8=data; Z15=c_0b00100000;
//; load needle and apply tail masks
  VPMINSD       Z20, Z25, Z13             //;7D091557 adv_needle := min(needle_len2, 4);Z13=adv_needle; Z25=needle_len2; Z20=4;
  VPERMD        Z18, Z13, Z27             //;B7D1A978 get tail_mask (needle)          ;Z27=scratch_Z27; Z13=adv_needle; Z18=tail_mask_data;
  VPANDD        Z26, Z27, Z8              //;5669D792 remove tail from data           ;Z8=data; Z27=scratch_Z27; Z26=scratch_Z26;
  VPANDD.BCST   (R13),Z27, Z28            //;C9F5F9B2 load needle and remove tail     ;Z28=needle; Z27=scratch_Z27; R13=needle_ptr2;
//; compare data with needle
  VPCMPD        $0,  Z28, Z8,  K4,  K4    //;18C82D78 K4 &= (data==needle)            ;K4=lane_selected; Z8=data; Z28=needle; 0=Eq;
//; advance
  VPADDD        Z13, Z24, K4,  Z24        //;3371623C data_off2 += adv_needle         ;Z24=data_off2; K4=lane_selected; Z13=adv_needle;
  VPSUBD        Z13, Z5,  K4,  Z5         //;9905C7C3 data_len2 -= adv_needle         ;Z5=data_len2; K4=lane_selected; Z13=adv_needle;
  VPSUBD        Z13, Z25, K4,  Z25        //;5A8AB52E needle_len2 -= adv_needle       ;Z25=needle_len2; K4=lane_selected; Z13=adv_needle;
  ADDQ          $4,  R13                  //;5D0D7365 needle_ptr2 += 4                ;R13=needle_ptr2;
//; check needle_loop conditions
  VPCMPD        $1,  Z25, Z11, K3         //;D0432359 K3 := (0<needle_len2)           ;K3=tmp_mask; Z11=0; Z25=needle_len2; 1=LessThen;
  KTESTW        K4,  K3                   //;88EB401D any lanes selected & elegible?  ;K3=tmp_mask; K4=lane_selected;
  JNZ           needle_loop               //;F1339C58 yes, then retry scanning; jump if not zero (ZF = 0);
//; update lanes
  KORW          K1,  K4,  K1              //;123EE41E lane_active |= lane_selected    ;K1=lane_active; K4=lane_selected;
  KANDNW        K2,  K4,  K2              //;32D9FB5F lane_todo &= ~lane_selected     ;K2=lane_todo; K4=lane_selected;
  VMOVDQA32     Z24, K4,  Z2              //;5FA56037 data_off1 := data_off2          ;Z2=data_off1; K4=lane_selected; Z24=data_off2;
  VMOVDQA32     Z5,  K4,  Z3              //;8536472E data_len1 := data_len2          ;Z3=data_len1; K4=lane_selected; Z5=data_len2;
//; advance the scan-offsets with 1 and if there are any lanes still todo, scan those
  VPADDD        Z10, Z2,  K2,  Z2         //;65A7A575 data_off1++                     ;Z2=data_off1; K2=lane_todo; Z10=1;
  VPSUBD        Z10, Z3,  K2,  Z3         //;F7731EA7 data_len1--                     ;Z3=data_len1; K2=lane_todo; Z10=1;
  KTESTW        K2,  K2                   //;D8353CAF any lanes todo?                 ;K2=lane_todo;
  JNZ           scan_start                //;68ACA94C yes, then restart scanning; jump if not zero (ZF = 0);
next:
  NEXT()
//; #endregion bcContainsSubstrCi

//; #region bcContainsSubstrUTF8Ci
TEXT bcContainsSubstrUTF8Ci(SB), NOSPLIT|NOFRAME, $0
  IMM_FROM_DICT(R14)                      //;05667C35 load *[]byte with the provided str into R14
//; load parameter
  MOVQ          (R14),R14                 //;D2647DF0 load needle_ptr                 ;R14=needle_ptr1; R14=needle_slice;
  MOVL          (R14),CX                  //;7DF7F141                                 ;CX=needle_len1; R14=needle_ptr1;
  VPBROADCASTD  CX,  Z6                   //;A2E19B3A bcst needle_len                 ;Z6=needle_len1; CX=needle_len1;
//; restrict lanes to allow fast bail-out
  VPCMPD        $5,  Z6,  Z3,  K1,  K1    //;EE56D9C0 K1 &= (data_len1>=needle_len1)  ;K1=lane_active; Z3=data_len1; Z6=needle_len1; 5=GreaterEq;
  KTESTW        K1,  K1                   //;5746030A any lanes still alive?          ;K1=lane_active;
  JZ            next                      //;B763A908 no, exit; jump if zero (ZF = 1) ;
//; load constants
  VMOVDQU32     bswap32<>(SB),Z22         //;A0BC360A load constant bswap32           ;Z22=bswap32;
  VMOVDQU32     CONST_TAIL_MASK(),Z18     //;7DB21CB0 load tail_mask_data             ;Z18=tail_mask_data;
  VMOVDQU32     CONST_N_BYTES_UTF8(),Z21  //;B323211A load table_n_bytes_utf8         ;Z21=table_n_bytes_utf8;
  VPBROADCASTD  CONSTD_1(),Z10            //;6F57EE92 load constant 1                 ;Z10=1;
  VPXORD        Z11, Z11, Z11             //;81C90120 load constant 0                 ;Z11=0;
//; init variables for scan_loop
  KMOVW         K1,  K2                   //;ECF269E6 lane_todo := lane_active        ;K2=lane_todo; K1=lane_active;
  KXORW         K1,  K1,  K1              //;6F6437B4 lane_active := 0                ;K1=lane_active;
  VPBROADCASTD  4(R14),Z12                //;54CB0C41 bcst alt1 from needle           ;Z12=char1_needle; R14=needle_ptr1;
  VPBROADCASTD  8(R14),Z13                //;EE0650F7 bcst alt2 from needle           ;Z13=char2_needle; R14=needle_ptr1;
  VPBROADCASTD  12(R14),Z14               //;879514D3 bcst alt3 from needle           ;Z14=char3_needle; R14=needle_ptr1;
  VPBROADCASTD  16(R14),Z15               //;A0DE73B0 bcst alt4 from needle           ;Z15=char4_needle; R14=needle_ptr1;
  ADDQ          $20, R14                  //;B6596F07 needle_ptr1 += 20               ;R14=needle_ptr1;
//; scan for the char1_needle in all lane_todo (K2) and accumulate in lane_selected (K4)
scan_start:
  KXORW         K4,  K4,  K4              //;8403FAC0 lane_selected := 0              ;K4=lane_selected;
scan_loop:
  KMOVW         K2,  K3                   //;723D04C9 copy eligible lanes             ;K3=tmp_mask; K2=lane_todo;
  VPGATHERDD    (SI)(Z2*1),K3,  Z8        //;573D089A gather data from end            ;Z8=data; K3=tmp_mask; SI=data_ptr; Z2=data_off1;
//; get tail mask
  VPSRLD        $4,  Z8,  Z26             //;FE5F1413 scratch_Z26 := data>>4          ;Z26=scratch_Z26; Z8=data;
  VPERMD        Z21, Z26, Z27             //;68FECBA0 get n_bytes_data                ;Z27=n_bytes_data; Z26=scratch_Z26; Z21=table_n_bytes_utf8;
  VPERMD        Z18, Z27, Z26             //;6D661522 get tail_mask (data)            ;Z26=scratch_Z26; Z27=n_bytes_data; Z18=tail_mask_data;
//; advance data for lanes that are still todo
  VPADDD        Z27, Z2,  K2,  Z2         //;FBFD5F0A data_off1 += n_bytes_data       ;Z2=data_off1; K2=lane_todo; Z27=n_bytes_data;
  VPSUBD        Z27, Z3,  K2,  Z3         //;28FE1865 data_len1 -= n_bytes_data       ;Z3=data_len1; K2=lane_todo; Z27=n_bytes_data;
  VPANDD.Z      Z8,  Z26, K2,  Z8         //;6EEB77B0 mask data                       ;Z8=data; K2=lane_todo; Z26=scratch_Z26;
//; compare with 4 code-points
  VPCMPD        $0,  Z12, Z8,  K2,  K3    //;6D1378C0 K3 := K2 & (data==char1_needle) ;K3=tmp_mask; K2=lane_todo; Z8=data; Z12=char1_needle; 0=Eq;
  VPCMPD        $0,  Z13, Z8,  K2,  K5    //;FC651EE0 K5 := K2 & (data==char2_needle) ;K5=scratch_K5; K2=lane_todo; Z8=data; Z13=char2_needle; 0=Eq;
  VPCMPD        $0,  Z14, Z8,  K2,  K6    //;D9FE5534 K6 := K2 & (data==char3_needle) ;K6=scratch_K6; K2=lane_todo; Z8=data; Z14=char3_needle; 0=Eq;
  VPCMPD        $0,  Z15, Z8,  K2,  K0    //;D65545B1 K0 := K2 & (data==char4_needle) ;K0=scratch_K0; K2=lane_todo; Z8=data; Z15=char4_needle; 0=Eq;
  KORW          K3,  K5,  K3              //;A903EE01 tmp_mask |= scratch_K5          ;K3=tmp_mask; K5=scratch_K5;
  KORW          K3,  K6,  K3              //;31B58C73 tmp_mask |= scratch_K6          ;K3=tmp_mask; K6=scratch_K6;
  KORW          K3,  K0,  K3              //;A20F03C1 tmp_mask |= scratch_K0          ;K3=tmp_mask; K0=scratch_K0;
//; update lanes with the found stuff
  KANDNW        K2,  K3,  K2              //;1EA864B0 lane_todo &= ~tmp_mask          ;K2=lane_todo; K3=tmp_mask;
  KORW          K4,  K3,  K4              //;A69E7F6D lane_selected |= tmp_mask       ;K4=lane_selected; K3=tmp_mask;
//; determine if we need to continue searching for a matching start code-point
  VPCMPD        $5,  Z6,  Z3,  K2,  K2    //;30061EEA K2 &= (data_len1>=needle_len1)  ;K2=lane_todo; Z3=data_len1; Z6=needle_len1; 5=GreaterEq;
  KTESTW        K2,  K2                   //;67E2F74E any lanes still todo?           ;K2=lane_todo;
  JNZ           scan_loop                 //;677C9F60 jump if not zero (ZF = 0)       ;

//; we are done scanning for the first code-point; test if there are more
  VMOVDQA32     Z2,  Z4                   //;835001A1 data_off2 := data_off1          ;Z4=data_off2; Z2=data_off1;
  VMOVDQA32     Z3,  Z5                   //;31B4F894 data_len2 := data_len1          ;Z5=data_len2; Z3=data_len1;
  CMPL          CX,  $1                   //;2BBD50B8 more than 1 char in needle?     ;CX=needle_len1;
  JZ            needle_loop_done          //;AFDB3970 jump if zero (ZF = 1)           ;
//; test if there is there is sufficient data
  VPCMPD        $6,  Z11, Z3,  K4,  K4    //;C0CF3FA2 K4 &= (data_len1>0)             ;K4=lane_selected; Z3=data_len1; Z11=0; 6=Greater;
  KTESTW        K4,  K4                   //;9AA8B932 any lanes selected?             ;K4=lane_selected;
  JZ            next                      //;31580AD4 no, then exit; jump if zero (ZF = 1);
//; init variables for needle_loop
  VPSUBD        Z10, Z6,  Z7              //;75A315B7 needle_len2 := needle_len1 - 1  ;Z7=needle_len2; Z6=needle_len1; Z10=1;
  MOVQ          R14, R13                  //;92B163CC needle_ptr2 := needle_ptr1      ;R13=needle_ptr2; R14=needle_ptr1;
  KMOVW         K4,  K2                   //;226BBC9E lane_todo := lane_selected      ;K2=lane_todo; K4=lane_selected;
needle_loop:
  KMOVW         K4,  K3                   //;F271B5DF copy eligible lanes             ;K3=tmp_mask; K4=lane_selected;
  VPGATHERDD    (SI)(Z4*1),K3,  Z8        //;2CF4C294 gather data                     ;Z8=data; K3=tmp_mask; SI=data_ptr; Z4=data_off2;
//; advance needle
  VPSUBD        Z10, Z7,  K4,  Z7         //;CAFCD045 needle_len2--                   ;Z7=needle_len2; K4=lane_selected; Z10=1;
//; mask tail data
  VPSRLD        $4,  Z8,  Z26             //;FE5F1413 scratch_Z26 := data>>4          ;Z26=scratch_Z26; Z8=data;
  VPERMD        Z21, Z26, Z27             //;68FECBA0 get n_bytes_data                ;Z27=n_bytes_data; Z26=scratch_Z26; Z21=table_n_bytes_utf8;
  VPERMD        Z18, Z27, Z26             //;488C6CD8 get tail_mask (data)            ;Z26=scratch_Z26; Z27=n_bytes_data; Z18=tail_mask_data;
  VPANDD.Z      Z8,  Z26, K2,  Z8         //;E750B0E2 mask data                       ;Z8=data; K2=lane_todo; Z26=scratch_Z26;
  VPADDD        Z27, Z4,  K4,  Z4         //;4879FB55 data_off2 += n_bytes_data       ;Z4=data_off2; K4=lane_selected; Z27=n_bytes_data;
  VPSUBD        Z27, Z5,  K4,  Z5         //;77CC472F data_len2 -= n_bytes_data       ;Z5=data_len2; K4=lane_selected; Z27=n_bytes_data;
//; compare with 4 code-points
  VPCMPD.BCST   $0,  (R13),Z8,  K4,  K3   //;15105C54 K3 := K4 & (data==[needle_ptr2]);K3=tmp_mask; K4=lane_selected; Z8=data; R13=needle_ptr2; 0=Eq;
  VPCMPD.BCST   $0,  4(R13),Z8,  K4,  K5  //;9C52A210 K5 := K4 & (data==[needle_ptr2+4]);K5=scratch_K5; K4=lane_selected; Z8=data; R13=needle_ptr2; 0=Eq;
  VPCMPD.BCST   $0,  8(R13),Z8,  K4,  K6  //;A8B34D3C K6 := K4 & (data==[needle_ptr2+8]);K6=scratch_K6; K4=lane_selected; Z8=data; R13=needle_ptr2; 0=Eq;
  VPCMPD.BCST   $0,  12(R13),Z8,  K4,  K0  //;343DD0F2 K0 := K4 & (data==[needle_ptr2+12]);K0=scratch_K0; K4=lane_selected; Z8=data; R13=needle_ptr2; 0=Eq;
  ADDQ          $16, R13                  //;5D0D7365 needle_ptr2 += 16               ;R13=needle_ptr2;
  KORW          K3,  K5,  K3              //;1125C81D tmp_mask |= scratch_K5          ;K3=tmp_mask; K5=scratch_K5;
  KORW          K3,  K6,  K3              //;DCB6AFAD tmp_mask |= scratch_K6          ;K3=tmp_mask; K6=scratch_K6;
  KORW          K3,  K0,  K4              //;65791592 lane_selected := scratch_K0 | tmp_mask;K4=lane_selected; K0=scratch_K0; K3=tmp_mask;
//; advance to the next code-point
  VPCMPD        $6,  Z11, Z7,  K4,  K3    //;1185F8E2 K3 := K4 & (needle_len2>0)      ;K3=tmp_mask; K4=lane_selected; Z7=needle_len2; Z11=0; 6=Greater;
  VPCMPD        $2,  Z5,  Z7,  K4,  K4    //;7C50EFFB K4 &= (needle_len2<=data_len2)  ;K4=lane_selected; Z7=needle_len2; Z5=data_len2; 2=LessEq;
  KTESTW        K3,  K3                   //;98CB0D8B ZF := (K3==0); CF := 1          ;K3=tmp_mask;
  JNZ           needle_loop               //;E6065236 jump if not zero (ZF = 0)       ;
//; update lanes
needle_loop_done:
  KORW          K1,  K4,  K1              //;123EE41E lane_active |= lane_selected    ;K1=lane_active; K4=lane_selected;
  KANDNW        K2,  K4,  K2              //;32D9FB5F lane_todo &= ~lane_selected     ;K2=lane_todo; K4=lane_selected;
  VMOVDQA32     Z4,  K4,  Z2              //;5FA56037 data_off1 := data_off2          ;Z2=data_off1; K4=lane_selected; Z4=data_off2;
  VMOVDQA32     Z5,  K4,  Z3              //;8536472E data_len1 := data_len2          ;Z3=data_len1; K4=lane_selected; Z5=data_len2;
//; if there are any lanes still todo, scan those
  KTESTW        K2,  K2                   //;D8353CAF any lanes todo?                 ;K2=lane_todo;
  JNZ           scan_start                //;68ACA94C yes, then restart scanning; jump if not zero (ZF = 0);
next:
  NEXT()
//; #endregion bcContainsSubstrUTF8Ci

//; #region bcContainsPatternCs
TEXT bcContainsPatternCs(SB), NOSPLIT|NOFRAME, $0
  IMM_FROM_DICT(R14)                      //;05667C35 load *[]byte with the provided str into R14
//; load parameter
  MOVQ          (R14),R14                 //;D2647DF0 load needle_ptr                 ;R14=needle_ptr1; R14=needle_slice;
  MOVL          (R14),CX                  //;7DF7F141                                 ;CX=needle_len1; R14=needle_ptr1;
//; restrict lanes to allow fast bail-out
  VPBROADCASTD  CX,  Z6                   //;A2E19B3A bcst needle_len                 ;Z6=needle_len1; CX=needle_len1;
  VPCMPD        $5,  Z6,  Z3,  K1,  K1    //;EE56D9C0 K1 &= (data_len1>=needle_len1)  ;K1=lane_active; Z3=data_len1; Z6=needle_len1; 5=GreaterEq;
  KTESTW        K1,  K1                   //;5746030A any lanes still alive?          ;K1=lane_active;
  JZ            next                      //;B763A908 no, exit; jump if zero (ZF = 1) ;
//; init needle and wildcard pointers
  ADDQ          $4,  R14                  //;B1A93760 needle_ptr1 += 4                ;R14=needle_ptr1;
  MOVQ          R14, R15                  //;1B1C0A5D wildcard_ptr1 := needle_ptr1    ;R15=wildcard_ptr1; R14=needle_ptr1;
  ADDQ          CX,  R15                  //;FC062E0E wildcard_ptr1 += needle_len1    ;R15=wildcard_ptr1; CX=needle_len1;
//; load constants
  VMOVDQU32     bswap32<>(SB),Z22         //;A0BC360A load constant bswap32           ;Z22=bswap32;
  VMOVDQU32     CONST_TAIL_MASK(),Z18     //;7DB21CB0 load tail_mask_data             ;Z18=tail_mask_data;
  VMOVDQU32     CONST_N_BYTES_UTF8(),Z21  //;B323211A load table_n_bytes_utf8         ;Z21=table_n_bytes_utf8;
  VPBROADCASTD  CONSTD_1(),Z10            //;6F57EE92 load constant 1                 ;Z10=1;
  VPBROADCASTD  CONSTD_4(),Z20            //;C8AFBE50 load constant 4                 ;Z20=4;
  VPXORD        Z11, Z11, Z11             //;81C90120 load constant 0                 ;Z11=0;
//; init variables for scan_loop
  KMOVW         K1,  K2                   //;ECF269E6 lane_todo := lane_active        ;K2=lane_todo; K1=lane_active;
  KXORW         K1,  K1,  K1              //;6F6437B4 lane_active := 0                ;K1=lane_active;
  VPBROADCASTB  (R14),Z9                  //;54CB0C41 bcst first char from needle     ;Z9=char1_needle; R14=needle_ptr1;

//; scan for the char1_needle in all lane_todo (K2) and accumulate in lane_selected (K4)
scan_start:
  KXORW         K4,  K4,  K4              //;8403FAC0 lane_selected := 0              ;K4=lane_selected;
scan_loop:
  KMOVW         K2,  K3                   //;723D04C9 copy eligible lanes             ;K3=tmp_mask; K2=lane_todo;
  VPXORD        Z8,  Z8,  Z8              //;CED5BB69 if not cleared 170C9C8F will give unncessary matches;Z8=data;
  VPGATHERDD    (SI)(Z2*1),K3,  Z8        //;573D089A gather data from end            ;Z8=data; K3=tmp_mask; SI=data_ptr; Z2=data_off1;
  VPCMPB        $0,  Z9,  Z8,  K3         //;170C9C8F K3 := (data==char1_needle)      ;K3=tmp_mask; Z8=data; Z9=char1_needle; 0=Eq;
  KTESTQ        K3,  K3                   //;AD0284F2 found any char1_needle?         ;K3=tmp_mask;
  JNZ           scan_found_something      //;4645455C yes, found something!; jump if not zero (ZF = 0);
  VPSUBD        Z20, Z3,  K2,  Z3         //;BF319EDC data_len1 -= 4                  ;Z3=data_len1; K2=lane_todo; Z20=4;
  VPADDD        Z20, Z2,  K2,  Z2         //;B5CB47F3 data_off1 += 4                  ;Z2=data_off1; K2=lane_todo; Z20=4;
scan_found_something_ret:                 //;2CADDCF3 reentry code path with found char1_needle
  VPCMPD        $1,  Z3,  Z11, K2,  K2    //;358E0E6F K2 &= (0<data_len1)             ;K2=lane_todo; Z11=0; Z3=data_len1; 1=LessThen;
  KTESTW        K2,  K2                   //;854AE89B any lanes still todo?           ;K2=lane_todo;
  JNZ           scan_loop                 //;5BB6DC39 yes, then continue scanning; jump if not zero (ZF = 0);
  JMP           scan_done                 //;58F52ADF                                 ;

scan_found_something:
//; calculate skip_count in Z14
  VPMOVM2B      K3,  Z27                  //;E74FDEBD promote 64x bit to 64x byte     ;Z27=skip_count; K3=tmp_mask;
  VPSHUFB       Z22, Z27, Z27             //;4F265F03 reverse byte order              ;Z27=skip_count; Z22=bswap32;
  VPLZCNTD      Z27, Z27                  //;72202F9A count leading zeros             ;Z27=skip_count;
  VPSRLD.Z      $3,  Z27, K2,  Z27        //;6DC91432 divide by 8 yields skip_count   ;Z27=skip_count; K2=lane_todo;
//; advance
  VPCMPD        $4,  Z20, Z27, K2,  K3    //;2846C84C K3 := K2 & (skip_count!=4)      ;K3=tmp_mask; K2=lane_todo; Z27=skip_count; Z20=4; 4=NotEqual;
  VPADDD        Z27, Z2,  K2,  Z2         //;63F1BACC data_off1 += skip_count         ;Z2=data_off1; K2=lane_todo; Z27=skip_count;
  VPSUBD        Z27, Z3,  K2,  Z3         //;8F7F978F data_len1 -= skip_count         ;Z3=data_len1; K2=lane_todo; Z27=skip_count;
//; update masks with the found stuff
  KANDNW        K2,  K3,  K2              //;1EA864B0 lane_todo &= ~tmp_mask          ;K2=lane_todo; K3=tmp_mask;
  KORW          K4,  K3,  K4              //;A69E7F6D lane_selected |= tmp_mask       ;K4=lane_selected; K3=tmp_mask;
  JMP           scan_found_something_ret  //;169A16C1 jump back to where we came from ;

scan_done:                                //;50D019A9 check if the ran out of data
  VPCMPD        $5,  Z6,  Z3,  K4,  K4    //;FA18B497 K4 &= (data_len1>=needle_len1)  ;K4=lane_selected; Z3=data_len1; Z6=needle_len1; 5=GreaterEq;
  KTESTW        K4,  K4                   //;9AA8B932 any lanes selected?             ;K4=lane_selected;
  JZ            next                      //;31580AD4 no, then exit; jump if zero (ZF = 1);
//; init variables for needle_loop
  VMOVDQA32     Z2,  Z24                  //;835001A1 data_off2 := data_off1          ;Z24=data_off2; Z2=data_off1;
  VMOVDQA32     Z3,  Z5                   //;31B4F894 data_len2 := data_len1          ;Z5=data_len2; Z3=data_len1;
  VMOVDQA32     Z6,  Z25                  //;E323C56F needle_len2 := needle_len1      ;Z25=needle_len2; Z6=needle_len1;
  MOVQ          R14, R13                  //;92B163CC needle_ptr2 := needle_ptr1      ;R13=needle_ptr2; R14=needle_ptr1;
  MOVQ          R15, BX                   //;76E7C8F2 wildcard_ptr2 := wildcard_ptr1  ;BX=wildcard_ptr2; R15=wildcard_ptr1;
  KMOVW         K4,  K2                   //;226BBC9E lane_todo := lane_selected      ;K2=lane_todo; K4=lane_selected;
needle_loop:
  KMOVW         K4,  K3                   //;F271B5DF copy eligible lanes             ;K3=tmp_mask; K4=lane_selected;
  VPXORD        Z8,  Z8,  Z8              //;CED5BB69 data := 0                       ;Z8=data;
  VPGATHERDD    (SI)(Z24*1),K3,  Z8       //;2CF4C294 gather data                     ;Z8=data; K3=tmp_mask; SI=data_ptr; Z24=data_off2;
//; load needle and apply tail masks
  VPMINSD       Z20, Z25, Z13             //;7D091557 adv_needle := min(needle_len2, 4);Z13=adv_needle; Z25=needle_len2; Z20=4;
  VPERMD        Z18, Z13, Z27             //;B7D1A978 get tail_mask (needle)          ;Z27=scratch_Z27; Z13=adv_needle; Z18=tail_mask_data;
  VPANDD        Z8,  Z27, Z8              //;5669D792 remove tail from data           ;Z8=data; Z27=scratch_Z27;
  VPANDD.BCST   (R13),Z27, Z28            //;C9F5F9B2 load needle and remove tail     ;Z28=needle; Z27=scratch_Z27; R13=needle_ptr2;
  VPBROADCASTD  (BX),Z27                  //;911BC5F9 load wildcard                   ;Z27=wildcard; BX=wildcard_ptr2;
//; test if a unicode code-points matches a wildcard
  VPANDD.Z      Z27, Z8,  K4,  Z26        //;7A4C6E61 scratch_Z26 := data & wildcard  ;Z26=scratch_Z26; K4=lane_selected; Z8=data; Z27=wildcard;
  VPMOVB2M      Z26, K3                   //;4B555080                                 ;K3=tmp_mask; Z26=scratch_Z26;
  KTESTQ        K3,  K3                   //;14D8E8C5 ZF := (K3==0); CF := 1          ;K3=tmp_mask;
  JNZ           unicode_match             //;C94028E8 jump if not zero (ZF = 0)       ;
//; compare data with needle
//;    Z27|Z8 |Z28  => Z28
//;     0 | 0 | 0      0
//;     0 | 0 | 1      0
//;     0 | 1 | 0      1
//;     0 | 1 | 1      0
//;     1 | 0 | 0      1
//;     1 | 0 | 1      0
//;     1 | 1 | 0      0
//;     1 | 1 | 1      0
  VPTERNLOGD    $0b00010100,Z27, Z8,  Z28 //;A64A5655 compute masked equality         ;Z28=needle; Z8=data; Z27=wildcard;
  VPCMPD        $0,  Z11, Z28, K4,  K4    //;D2F6A32B K4 &= (needle==0)               ;K4=lane_selected; Z28=needle; Z11=0; 0=Eq;
//; advance
  VPADDD        Z13, Z24, K4,  Z24        //;3371623C data_off2 += adv_needle         ;Z24=data_off2; K4=lane_selected; Z13=adv_needle;
  VPSUBD        Z13, Z5,  K4,  Z5         //;9905C7C3 data_len2 -= adv_needle         ;Z5=data_len2; K4=lane_selected; Z13=adv_needle;
  VPSUBD        Z13, Z25, K4,  Z25        //;5A8AB52E needle_len2 -= adv_needle       ;Z25=needle_len2; K4=lane_selected; Z13=adv_needle;
  ADDQ          $4,  R13                  //;5D0D7365 needle_ptr2 += 4                ;R13=needle_ptr2;
  ADDQ          $4,  BX                   //;8A43B166 wildcard_ptr2 += 4              ;BX=wildcard_ptr2;
unicode_match_ret:
//; check needle_loop conditions
  VPCMPD        $1,  Z25, Z11, K3         //;D0432359 K3 := (0<needle_len2)           ;K3=tmp_mask; Z11=0; Z25=needle_len2; 1=LessThen;
  VPCMPD        $2,  Z5,  Z11, K4,  K4    //;1F3D9F3F K4 &= (0<=data_len2)            ;K4=lane_selected; Z11=0; Z5=data_len2; 2=LessEq;
  KTESTW        K4,  K3                   //;88EB401D any lanes selected & elegible?  ;K3=tmp_mask; K4=lane_selected;
  JNZ           needle_loop               //;F1339C58 yes, then retry scanning; jump if not zero (ZF = 0);
//; update lanes
  KORW          K1,  K4,  K1              //;123EE41E lane_active |= lane_selected    ;K1=lane_active; K4=lane_selected;
  KANDNW        K2,  K4,  K2              //;32D9FB5F lane_todo &= ~lane_selected     ;K2=lane_todo; K4=lane_selected;
  VMOVDQA32     Z24, K4,  Z2              //;5FA56037 data_off1 := data_off2          ;Z2=data_off1; K4=lane_selected; Z24=data_off2;
  VMOVDQA32     Z5,  K4,  Z3              //;8536472E data_len1 := data_len2          ;Z3=data_len1; K4=lane_selected; Z5=data_len2;
//; advance the scan-offsets with 1 and if there are any lanes still todo, scan those
  VPADDD        Z10, Z2,  K2,  Z2         //;65A7A575 data_off1++                     ;Z2=data_off1; K2=lane_todo; Z10=1;
  VPSUBD        Z10, Z3,  K2,  Z3         //;F7731EA7 data_len1--                     ;Z3=data_len1; K2=lane_todo; Z10=1;
  KTESTW        K2,  K2                   //;D8353CAF any lanes todo?                 ;K2=lane_todo;
  JNZ           scan_start                //;68ACA94C yes, then restart scanning; jump if not zero (ZF = 0);
next:
  NEXT()
unicode_match:                            //;B1B3AECE a wildcard has matched with a unicode code-point
//; with the wildcard mask, get the number of bytes BEFORE the first wildcard (0, 1, 2, 3)
//; at that position get the number of bytes of the code-point, add these two numbers
//; calculate advance in Z26
  VPSHUFB       Z22, Z27, Z26             //;3F4659FF reverse byte order              ;Z26=scratch_Z26; Z27=wildcard; Z22=bswap32;
  VPLZCNTD      Z26, Z27                  //;7DB21322 count leading zeros             ;Z27=zero_count; Z26=scratch_Z26;
  VPSRLD        $3,  Z27, Z19             //;D7D76764 divide by 8 yields advance      ;Z19=advance; Z27=zero_count;
//; get number of bytes in next code-point
  VPSRLD        $4,  Z8,  Z26             //;E6FE9C45 scratch_Z26 := data>>4          ;Z26=scratch_Z26; Z8=data;
  VPSRLVD       Z27, Z26, Z26             //;F99F8396 scratch_Z26 >>= zero_count      ;Z26=scratch_Z26; Z27=zero_count;
  VPERMD        Z21, Z26, Z26             //;DE232505 get n_bytes_code_point          ;Z26=scratch_Z26; Z21=table_n_bytes_utf8;
  VPADDD        Z19, Z26, Z13             //;D11A93E8 adv_data := scratch_Z26 + advance;Z13=adv_data; Z26=scratch_Z26; Z19=advance;
//; we are only going to test the number of bytes BEFORE the first wildcard
  VPERMD        Z18, Z19, Z26             //;9A394869 get tail_mask data              ;Z26=scratch_Z26; Z19=advance; Z18=tail_mask_data;
  VPANDD        Z26, Z8,  Z8              //;C5A7FCBA data &= scratch_Z26             ;Z8=data; Z26=scratch_Z26;
  VPANDD        Z26, Z28, Z28             //;51343840 needle &= scratch_Z26           ;Z28=needle; Z26=scratch_Z26;
  VPCMPD        $0,  Z8,  Z28, K4,  K4    //;13A45EF9 K4 &= (needle==data)            ;K4=lane_selected; Z28=needle; Z8=data; 0=Eq;
//; advance
  VPADDD        Z10, Z19, Z19             //;BFB2C3DE adv_needle := advance + 1       ;Z19=adv_needle; Z19=advance; Z10=1;
  VPSUBD        Z19, Z25, K4,  Z25        //;B3CDC39C needle_len2 -= adv_needle       ;Z25=needle_len2; K4=lane_selected; Z19=adv_needle;
  VPADDD        Z13, Z24, K4,  Z24        //;AE5AA4CF data_off2 += adv_data           ;Z24=data_off2; K4=lane_selected; Z13=adv_data;
  VPSUBD        Z13, Z5,  K4,  Z5         //;DBC41158 data_len2 -= adv_data           ;Z5=data_len2; K4=lane_selected; Z13=adv_data;
  VMOVD         X19, R12                  //;B10A9DE5 extract GPR adv_needle          ;R12=scratch; Z19=adv_needle;
  ADDQ          R12, R13                  //;34EA6A74 needle_ptr2 += scratch          ;R13=needle_ptr2; R12=scratch;
  ADDQ          R12, BX                   //;8FD33A77 wildcard_ptr2 += scratch        ;BX=wildcard_ptr2; R12=scratch;
  JMP           unicode_match_ret         //;D24820C1                                 ;
//; #endregion bcContainsPatternCs

//; #region bcContainsPatternCi
TEXT bcContainsPatternCi(SB), NOSPLIT|NOFRAME, $0
  IMM_FROM_DICT(R14)                      //;05667C35 load *[]byte with the provided str into R14
//; load parameter
  MOVQ          (R14),R14                 //;D2647DF0 load needle_ptr                 ;R14=needle_ptr1; R14=needle_slice;
  MOVL          (R14),CX                  //;7DF7F141                                 ;CX=needle_len1; R14=needle_ptr1;
//; restrict lanes to allow fast bail-out
  VPBROADCASTD  CX,  Z6                   //;A2E19B3A bcst needle_len                 ;Z6=needle_len1; CX=needle_len1;
  VPCMPD        $5,  Z6,  Z3,  K1,  K1    //;EE56D9C0 K1 &= (data_len1>=needle_len1)  ;K1=lane_active; Z3=data_len1; Z6=needle_len1; 5=GreaterEq;
  KTESTW        K1,  K1                   //;5746030A any lanes still alive?          ;K1=lane_active;
  JZ            next                      //;B763A908 no, exit; jump if zero (ZF = 1) ;
//; init needle and wildcard pointers
  ADDQ          $4,  R14                  //;B1A93760 needle_ptr1 += 4                ;R14=needle_ptr1;
  MOVQ          R14, R15                  //;1B1C0A5D wildcard_ptr1 := needle_ptr1    ;R15=wildcard_ptr1; R14=needle_ptr1;
  ADDQ          CX,  R15                  //;FC062E0E wildcard_ptr1 += needle_len1    ;R15=wildcard_ptr1; CX=needle_len1;
//; load constants
  VPBROADCASTB  CONSTB_32(),Z15           //;5B8F2908 load constant 0b00100000        ;Z15=c_0b00100000;
  VPBROADCASTB  CONSTB_97(),Z16           //;5D5B0014 load constant ASCII a           ;Z16=char_a;
  VPBROADCASTB  CONSTB_122(),Z17          //;8E2ED824 load constant ASCII z           ;Z17=char_z;
  VMOVDQU32     bswap32<>(SB),Z22         //;A0BC360A load constant bswap32           ;Z22=bswap32;
  VMOVDQU32     CONST_TAIL_MASK(),Z18     //;7DB21CB0 load tail_mask_data             ;Z18=tail_mask_data;
  VMOVDQU32     CONST_N_BYTES_UTF8(),Z21  //;B323211A load table_n_bytes_utf8         ;Z21=table_n_bytes_utf8;
  VPBROADCASTD  CONSTD_1(),Z10            //;6F57EE92 load constant 1                 ;Z10=1;
  VPBROADCASTD  CONSTD_4(),Z20            //;C8AFBE50 load constant 4                 ;Z20=4;
  VPXORD        Z11, Z11, Z11             //;81C90120 load constant 0                 ;Z11=0;
//; init variables for scan_loop
  KMOVW         K1,  K2                   //;ECF269E6 lane_todo := lane_active        ;K2=lane_todo; K1=lane_active;
  KXORW         K1,  K1,  K1              //;6F6437B4 lane_active := 0                ;K1=lane_active;
  VPBROADCASTB  (R14),Z9                  //;54CB0C41 bcst first char from needle     ;Z9=char1_needle; R14=needle_ptr1;

//; scan for the char1_needle in all lane_todo (K2) and accumulate in lane_selected (K4)
scan_start:
  KXORW         K4,  K4,  K4              //;8403FAC0 lane_selected := 0              ;K4=lane_selected;
scan_loop:
  KMOVW         K2,  K3                   //;723D04C9 copy eligible lanes             ;K3=tmp_mask; K2=lane_todo;
  VPXORD        Z8,  Z8,  Z8              //;CED5BB69 if not cleared 170C9C8F will give unncessary matches;Z8=data;
  VPGATHERDD    (SI)(Z2*1),K3,  Z8        //;573D089A gather data from end            ;Z8=data; K3=tmp_mask; SI=data_ptr; Z2=data_off1;
//; str_to_upper: IN zmm8; OUT zmm26
  VPCMPB        $5,  Z16, Z8,  K3         //;30E9B9FD K3 := (data>=char_a)            ;K3=tmp_mask; Z8=data; Z16=char_a; 5=GreaterEq;
  VPCMPB        $2,  Z17, Z8,  K3,  K3    //;8CE85BA0 K3 &= (data<=char_z)            ;K3=tmp_mask; Z8=data; Z17=char_z; 2=LessEq;
//; Z15 is 64 bytes with 0b00100000
//;    Z15|Z8 |Z26 => Z26
//;     0 | 0 | 0      0
//;     0 | 0 | 1      0
//;     0 | 1 | 0      1
//;     0 | 1 | 1      1
//;     1 | 0 | 0      0
//;     1 | 0 | 1      0
//;     1 | 1 | 0      1
//;     1 | 1 | 1      0     <= change from lower to upper
  VPMOVM2B      K3,  Z26                  //;ADC21F45 mask with selected chars        ;Z26=scratch_Z26; K3=tmp_mask;
  VPTERNLOGD    $0b01001100,Z15, Z8,  Z26 //;1BB96D97                                 ;Z26=scratch_Z26; Z8=data; Z15=c_0b00100000;
  VPCMPB        $0,  Z9,  Z26, K3         //;170C9C8F K3 := (scratch_Z26==char1_needle);K3=tmp_mask; Z26=scratch_Z26; Z9=char1_needle; 0=Eq;
  KTESTQ        K3,  K3                   //;AD0284F2 found any char1_needle?         ;K3=tmp_mask;
  JNZ           scan_found_something      //;4645455C yes, found something!; jump if not zero (ZF = 0);
  VPSUBD        Z20, Z3,  K2,  Z3         //;BF319EDC data_len1 -= 4                  ;Z3=data_len1; K2=lane_todo; Z20=4;
  VPADDD        Z20, Z2,  K2,  Z2         //;B5CB47F3 data_off1 += 4                  ;Z2=data_off1; K2=lane_todo; Z20=4;
scan_found_something_ret:                 //;2CADDCF3 reentry code path with found char1_needle
  VPCMPD        $1,  Z3,  Z11, K2,  K2    //;358E0E6F K2 &= (0<data_len1)             ;K2=lane_todo; Z11=0; Z3=data_len1; 1=LessThen;
  KTESTW        K2,  K2                   //;854AE89B any lanes still todo?           ;K2=lane_todo;
  JNZ           scan_loop                 //;5BB6DC39 yes, then continue scanning; jump if not zero (ZF = 0);
  JMP           scan_done                 //;58F52ADF                                 ;

scan_found_something:
//; calculate skip_count in Z14
  VPMOVM2B      K3,  Z27                  //;E74FDEBD promote 64x bit to 64x byte     ;Z27=skip_count; K3=tmp_mask;
  VPSHUFB       Z22, Z27, Z27             //;4F265F03 reverse byte order              ;Z27=skip_count; Z22=bswap32;
  VPLZCNTD      Z27, Z27                  //;72202F9A count leading zeros             ;Z27=skip_count;
  VPSRLD.Z      $3,  Z27, K2,  Z27        //;6DC91432 divide by 8 yields skip_count   ;Z27=skip_count; K2=lane_todo;
//; advance
  VPCMPD        $4,  Z20, Z27, K2,  K3    //;2846C84C K3 := K2 & (skip_count!=4)      ;K3=tmp_mask; K2=lane_todo; Z27=skip_count; Z20=4; 4=NotEqual;
  VPADDD        Z27, Z2,  K2,  Z2         //;63F1BACC data_off1 += skip_count         ;Z2=data_off1; K2=lane_todo; Z27=skip_count;
  VPSUBD        Z27, Z3,  K2,  Z3         //;8F7F978F data_len1 -= skip_count         ;Z3=data_len1; K2=lane_todo; Z27=skip_count;
//; update masks with the found stuff
  KANDNW        K2,  K3,  K2              //;1EA864B0 lane_todo &= ~tmp_mask          ;K2=lane_todo; K3=tmp_mask;
  KORW          K4,  K3,  K4              //;A69E7F6D lane_selected |= tmp_mask       ;K4=lane_selected; K3=tmp_mask;
  JMP           scan_found_something_ret  //;169A16C1 jump back to where we came from ;

scan_done:                                //;50D019A9 check if the ran out of data
  VPCMPD        $5,  Z6,  Z3,  K4,  K4    //;FA18B497 K4 &= (data_len1>=needle_len1)  ;K4=lane_selected; Z3=data_len1; Z6=needle_len1; 5=GreaterEq;
  KTESTW        K4,  K4                   //;9AA8B932 any lanes selected?             ;K4=lane_selected;
  JZ            next                      //;31580AD4 no, then exit; jump if zero (ZF = 1);
//; init variables for needle_loop
  VMOVDQA32     Z2,  Z24                  //;835001A1 data_off2 := data_off1          ;Z24=data_off2; Z2=data_off1;
  VMOVDQA32     Z3,  Z5                   //;31B4F894 data_len2 := data_len1          ;Z5=data_len2; Z3=data_len1;
  VMOVDQA32     Z6,  Z25                  //;E323C56F needle_len2 := needle_len1      ;Z25=needle_len2; Z6=needle_len1;
  MOVQ          R14, R13                  //;92B163CC needle_ptr2 := needle_ptr1      ;R13=needle_ptr2; R14=needle_ptr1;
  MOVQ          R15, BX                   //;76E7C8F2 wildcard_ptr2 := wildcard_ptr1  ;BX=wildcard_ptr2; R15=wildcard_ptr1;
  KMOVW         K4,  K2                   //;226BBC9E lane_todo := lane_selected      ;K2=lane_todo; K4=lane_selected;
needle_loop:
  KMOVW         K4,  K3                   //;F271B5DF copy eligible lanes             ;K3=tmp_mask; K4=lane_selected;
  VPXORD        Z8,  Z8,  Z8              //;CED5BB69 data := 0                       ;Z8=data;
  VPGATHERDD    (SI)(Z24*1),K3,  Z8       //;2CF4C294 gather data                     ;Z8=data; K3=tmp_mask; SI=data_ptr; Z24=data_off2;
//; str_to_upper: IN zmm8; OUT zmm26
  VPCMPB        $5,  Z16, Z8,  K3         //;30E9B9FD K3 := (data>=char_a)            ;K3=tmp_mask; Z8=data; Z16=char_a; 5=GreaterEq;
  VPCMPB        $2,  Z17, Z8,  K3,  K3    //;8CE85BA0 K3 &= (data<=char_z)            ;K3=tmp_mask; Z8=data; Z17=char_z; 2=LessEq;
//; Z15 is 64 bytes with 0b00100000
//;    Z15|Z8 |Z26 => Z26
//;     0 | 0 | 0      0
//;     0 | 0 | 1      0
//;     0 | 1 | 0      1
//;     0 | 1 | 1      1
//;     1 | 0 | 0      0
//;     1 | 0 | 1      0
//;     1 | 1 | 0      1
//;     1 | 1 | 1      0     <= change from lower to upper
  VPMOVM2B      K3,  Z26                  //;ADC21F45 mask with selected chars        ;Z26=scratch_Z26; K3=tmp_mask;
  VPTERNLOGD    $0b01001100,Z15, Z8,  Z26 //;1BB96D97                                 ;Z26=scratch_Z26; Z8=data; Z15=c_0b00100000;
//; load needle and apply tail masks
  VPMINSD       Z20, Z25, Z13             //;7D091557 adv_needle := min(needle_len2, 4);Z13=adv_needle; Z25=needle_len2; Z20=4;
  VPERMD        Z18, Z13, Z27             //;B7D1A978 get tail_mask (needle)          ;Z27=scratch_Z27; Z13=adv_needle; Z18=tail_mask_data;
  VPANDD        Z26, Z27, Z8              //;5669D792 remove tail from data           ;Z8=data; Z27=scratch_Z27; Z26=scratch_Z26;
  VPANDD.BCST   (R13),Z27, Z28            //;C9F5F9B2 load needle and remove tail     ;Z28=needle; Z27=scratch_Z27; R13=needle_ptr2;
  VPBROADCASTD  (BX),Z27                  //;911BC5F9 load wildcard                   ;Z27=wildcard; BX=wildcard_ptr2;
//; test if a unicode code-points matches a wildcard
  VPANDD.Z      Z27, Z8,  K4,  Z26        //;7A4C6E61 scratch_Z26 := data & wildcard  ;Z26=scratch_Z26; K4=lane_selected; Z8=data; Z27=wildcard;
  VPMOVB2M      Z26, K3                   //;4B555080                                 ;K3=tmp_mask; Z26=scratch_Z26;
  KTESTQ        K3,  K3                   //;14D8E8C5 ZF := (K3==0); CF := 1          ;K3=tmp_mask;
  JNZ           unicode_match             //;C94028E8 jump if not zero (ZF = 0)       ;
//; compare data with needle
//;    Z27|Z8 |Z28  => Z28
//;     0 | 0 | 0      0
//;     0 | 0 | 1      0
//;     0 | 1 | 0      1
//;     0 | 1 | 1      0
//;     1 | 0 | 0      1
//;     1 | 0 | 1      0
//;     1 | 1 | 0      0
//;     1 | 1 | 1      0
  VPTERNLOGD    $0b00010100,Z27, Z8,  Z28 //;A64A5655 compute masked equality         ;Z28=needle; Z8=data; Z27=wildcard;
  VPCMPD        $0,  Z11, Z28, K4,  K4    //;D2F6A32B K4 &= (needle==0)               ;K4=lane_selected; Z28=needle; Z11=0; 0=Eq;
//; advance
  VPADDD        Z13, Z24, K4,  Z24        //;3371623C data_off2 += adv_needle         ;Z24=data_off2; K4=lane_selected; Z13=adv_needle;
  VPSUBD        Z13, Z5,  K4,  Z5         //;9905C7C3 data_len2 -= adv_needle         ;Z5=data_len2; K4=lane_selected; Z13=adv_needle;
  VPSUBD        Z13, Z25, K4,  Z25        //;5A8AB52E needle_len2 -= adv_needle       ;Z25=needle_len2; K4=lane_selected; Z13=adv_needle;
  ADDQ          $4,  R13                  //;5D0D7365 needle_ptr2 += 4                ;R13=needle_ptr2;
  ADDQ          $4,  BX                   //;8A43B166 wildcard_ptr2 += 4              ;BX=wildcard_ptr2;
unicode_match_ret:
//; check needle_loop conditions
  VPCMPD        $1,  Z25, Z11, K3         //;D0432359 K3 := (0<needle_len2)           ;K3=tmp_mask; Z11=0; Z25=needle_len2; 1=LessThen;
  VPCMPD        $2,  Z5,  Z11, K4,  K4    //;1F3D9F3F K4 &= (0<=data_len2)            ;K4=lane_selected; Z11=0; Z5=data_len2; 2=LessEq;
  KTESTW        K4,  K3                   //;88EB401D any lanes selected & elegible?  ;K3=tmp_mask; K4=lane_selected;
  JNZ           needle_loop               //;F1339C58 yes, then retry scanning; jump if not zero (ZF = 0);
//; update lanes
  KORW          K1,  K4,  K1              //;123EE41E lane_active |= lane_selected    ;K1=lane_active; K4=lane_selected;
  KANDNW        K2,  K4,  K2              //;32D9FB5F lane_todo &= ~lane_selected     ;K2=lane_todo; K4=lane_selected;
  VMOVDQA32     Z24, K4,  Z2              //;5FA56037 data_off1 := data_off2          ;Z2=data_off1; K4=lane_selected; Z24=data_off2;
  VMOVDQA32     Z5,  K4,  Z3              //;8536472E data_len1 := data_len2          ;Z3=data_len1; K4=lane_selected; Z5=data_len2;
//; advance the scan-offsets with 1 and if there are any lanes still todo, scan those
  VPADDD        Z10, Z2,  K2,  Z2         //;65A7A575 data_off1++                     ;Z2=data_off1; K2=lane_todo; Z10=1;
  VPSUBD        Z10, Z3,  K2,  Z3         //;F7731EA7 data_len1--                     ;Z3=data_len1; K2=lane_todo; Z10=1;
  KTESTW        K2,  K2                   //;D8353CAF any lanes todo?                 ;K2=lane_todo;
  JNZ           scan_start                //;68ACA94C yes, then restart scanning; jump if not zero (ZF = 0);
next:
  NEXT()
unicode_match:                            //;B1B3AECE a wildcard has matched with a unicode code-point
//; with the wildcard mask, get the number of bytes BEFORE the first wildcard (0, 1, 2, 3)
//; at that position get the number of bytes of the code-point, add these two numbers
//; calculate advance in Z26
  VPSHUFB       Z22, Z27, Z26             //;3F4659FF reverse byte order              ;Z26=scratch_Z26; Z27=wildcard; Z22=bswap32;
  VPLZCNTD      Z26, Z27                  //;7DB21322 count leading zeros             ;Z27=zero_count; Z26=scratch_Z26;
  VPSRLD        $3,  Z27, Z19             //;D7D76764 divide by 8 yields advance      ;Z19=advance; Z27=zero_count;
//; get number of bytes in next code-point
  VPSRLD        $4,  Z8,  Z26             //;E6FE9C45 scratch_Z26 := data>>4          ;Z26=scratch_Z26; Z8=data;
  VPSRLVD       Z27, Z26, Z26             //;F99F8396 scratch_Z26 >>= zero_count      ;Z26=scratch_Z26; Z27=zero_count;
  VPERMD        Z21, Z26, Z26             //;DE232505 get n_bytes_code_point          ;Z26=scratch_Z26; Z21=table_n_bytes_utf8;
  VPADDD        Z19, Z26, Z13             //;D11A93E8 adv_data := scratch_Z26 + advance;Z13=adv_data; Z26=scratch_Z26; Z19=advance;
//; we are only going to test the number of bytes BEFORE the first wildcard
  VPERMD        Z18, Z19, Z26             //;9A394869 get tail_mask data              ;Z26=scratch_Z26; Z19=advance; Z18=tail_mask_data;
  VPANDD        Z26, Z8,  Z8              //;C5A7FCBA data &= scratch_Z26             ;Z8=data; Z26=scratch_Z26;
  VPANDD        Z26, Z28, Z28             //;51343840 needle &= scratch_Z26           ;Z28=needle; Z26=scratch_Z26;
  VPCMPD        $0,  Z8,  Z28, K4,  K4    //;13A45EF9 K4 &= (needle==data)            ;K4=lane_selected; Z28=needle; Z8=data; 0=Eq;
//; advance
  VPADDD        Z10, Z19, Z19             //;BFB2C3DE adv_needle := advance + 1       ;Z19=adv_needle; Z19=advance; Z10=1;
  VPSUBD        Z19, Z25, K4,  Z25        //;B3CDC39C needle_len2 -= adv_needle       ;Z25=needle_len2; K4=lane_selected; Z19=adv_needle;
  VPADDD        Z13, Z24, K4,  Z24        //;AE5AA4CF data_off2 += adv_data           ;Z24=data_off2; K4=lane_selected; Z13=adv_data;
  VPSUBD        Z13, Z5,  K4,  Z5         //;DBC41158 data_len2 -= adv_data           ;Z5=data_len2; K4=lane_selected; Z13=adv_data;
  VMOVD         X19, R12                  //;B10A9DE5 extract GPR adv_needle          ;R12=scratch; Z19=adv_needle;
  ADDQ          R12, R13                  //;34EA6A74 needle_ptr2 += scratch          ;R13=needle_ptr2; R12=scratch;
  ADDQ          R12, BX                   //;8FD33A77 wildcard_ptr2 += scratch        ;BX=wildcard_ptr2; R12=scratch;
  JMP           unicode_match_ret         //;D24820C1                                 ;
//; #endregion bcContainsPatternCi

//; #region bcContainsPatternUTF8Ci
TEXT bcContainsPatternUTF8Ci(SB), NOSPLIT|NOFRAME, $0
  IMM_FROM_DICT(R14)                      //;05667C35 load *[]byte with the provided str into R14
//; load parameter
  MOVQ          (R14),R14                 //;D2647DF0 load needle_ptr                 ;R14=needle_ptr1; R14=needle_slice;
  MOVL          (R14),CX                  //;7DF7F141                                 ;CX=needle_len1; R14=needle_ptr1;
  VPBROADCASTD  CX,  Z6                   //;A2E19B3A bcst needle_len                 ;Z6=needle_len1; CX=needle_len1;
//; restrict lanes to allow fast bail-out
  VPCMPD        $5,  Z6,  Z3,  K1,  K1    //;EE56D9C0 K1 &= (data_len1>=needle_len1)  ;K1=lane_active; Z3=data_len1; Z6=needle_len1; 5=GreaterEq;
  KTESTW        K1,  K1                   //;5746030A any lanes still alive?          ;K1=lane_active;
  JZ            next                      //;B763A908 no, exit; jump if zero (ZF = 1) ;
  MOVQ          CX,  R8                   //;A83664AE scratch := needle_len1          ;R8=scratch; CX=needle_len1;
  SHLQ          $4,  R8                   //;EDF8DF09 scratch <<= 4                   ;R8=scratch;
  LEAQ          6(R14)(R8*1),R15          //;1EF280F2 wildcard_ptr1 := needle_ptr1 + scratch + 6;R15=wildcard_ptr1; R14=needle_ptr1; R8=scratch;
//; load constants
  VMOVDQU32     bswap32<>(SB),Z22         //;A0BC360A load constant bswap32           ;Z22=bswap32;
  VMOVDQU32     CONST_TAIL_MASK(),Z18     //;7DB21CB0 load tail_mask_data             ;Z18=tail_mask_data;
  VMOVDQU32     CONST_N_BYTES_UTF8(),Z21  //;B323211A load table_n_bytes_utf8         ;Z21=table_n_bytes_utf8;
  VPBROADCASTD  CONSTD_1(),Z10            //;6F57EE92 load constant 1                 ;Z10=1;
  VPXORD        Z11, Z11, Z11             //;81C90120 load constant 0                 ;Z11=0;
//; init variables for scan_loop
  KMOVW         K1,  K2                   //;ECF269E6 lane_todo := lane_active        ;K2=lane_todo; K1=lane_active;
  KXORW         K1,  K1,  K1              //;6F6437B4 lane_active := 0                ;K1=lane_active;
  VPBROADCASTD  4(R14),Z12                //;54CB0C41 bcst alt1 from needle           ;Z12=char1_needle; R14=needle_ptr1;
  VPBROADCASTD  8(R14),Z13                //;EE0650F7 bcst alt2 from needle           ;Z13=char2_needle; R14=needle_ptr1;
  VPBROADCASTD  12(R14),Z14               //;879514D3 bcst alt3 from needle           ;Z14=char3_needle; R14=needle_ptr1;
  VPBROADCASTD  16(R14),Z15               //;A0DE73B0 bcst alt4 from needle           ;Z15=char4_needle; R14=needle_ptr1;
  ADDQ          $20, R14                  //;B6596F07 needle_ptr1 += 20               ;R14=needle_ptr1;
//; scan for the char1_needle in all lane_todo (K2) and accumulate in lane_selected (K4)
scan_start:
  KXORW         K4,  K4,  K4              //;8403FAC0 lane_selected := 0              ;K4=lane_selected;
scan_loop:
  KMOVW         K2,  K3                   //;723D04C9 copy eligible lanes             ;K3=tmp_mask; K2=lane_todo;
  VPGATHERDD    (SI)(Z2*1),K3,  Z8        //;573D089A gather data from end            ;Z8=data; K3=tmp_mask; SI=data_ptr; Z2=data_off1;
//; get tail mask
  VPSRLD        $4,  Z8,  Z26             //;FE5F1413 scratch_Z26 := data>>4          ;Z26=scratch_Z26; Z8=data;
  VPERMD        Z21, Z26, Z27             //;68FECBA0 get n_bytes_data                ;Z27=n_bytes_data; Z26=scratch_Z26; Z21=table_n_bytes_utf8;
  VPERMD        Z18, Z27, Z26             //;6D661522 get tail_mask (data)            ;Z26=scratch_Z26; Z27=n_bytes_data; Z18=tail_mask_data;
//; advance data for lanes that are still todo
  VPADDD        Z27, Z2,  K2,  Z2         //;FBFD5F0A data_off1 += n_bytes_data       ;Z2=data_off1; K2=lane_todo; Z27=n_bytes_data;
  VPSUBD        Z27, Z3,  K2,  Z3         //;28FE1865 data_len1 -= n_bytes_data       ;Z3=data_len1; K2=lane_todo; Z27=n_bytes_data;
  VPANDD.Z      Z8,  Z26, K2,  Z8         //;6EEB77B0 mask data                       ;Z8=data; K2=lane_todo; Z26=scratch_Z26;
//; compare with 4 code-points
  VPCMPD        $0,  Z12, Z8,  K2,  K3    //;6D1378C0 K3 := K2 & (data==char1_needle) ;K3=tmp_mask; K2=lane_todo; Z8=data; Z12=char1_needle; 0=Eq;
  VPCMPD        $0,  Z13, Z8,  K2,  K5    //;FC651EE0 K5 := K2 & (data==char2_needle) ;K5=scratch_K5; K2=lane_todo; Z8=data; Z13=char2_needle; 0=Eq;
  VPCMPD        $0,  Z14, Z8,  K2,  K6    //;D9FE5534 K6 := K2 & (data==char3_needle) ;K6=scratch_K6; K2=lane_todo; Z8=data; Z14=char3_needle; 0=Eq;
  VPCMPD        $0,  Z15, Z8,  K2,  K0    //;D65545B1 K0 := K2 & (data==char4_needle) ;K0=scratch_K0; K2=lane_todo; Z8=data; Z15=char4_needle; 0=Eq;
  KORW          K3,  K5,  K3              //;A903EE01 tmp_mask |= scratch_K5          ;K3=tmp_mask; K5=scratch_K5;
  KORW          K3,  K6,  K3              //;31B58C73 tmp_mask |= scratch_K6          ;K3=tmp_mask; K6=scratch_K6;
  KORW          K3,  K0,  K3              //;A20F03C1 tmp_mask |= scratch_K0          ;K3=tmp_mask; K0=scratch_K0;
//; update lanes with the found stuff
  KANDNW        K2,  K3,  K2              //;1EA864B0 lane_todo &= ~tmp_mask          ;K2=lane_todo; K3=tmp_mask;
  KORW          K4,  K3,  K4              //;A69E7F6D lane_selected |= tmp_mask       ;K4=lane_selected; K3=tmp_mask;
//; determine if we need to continue searching for a matching start code-point
  VPCMPD        $5,  Z6,  Z3,  K2,  K2    //;30061EEA K2 &= (data_len1>=needle_len1)  ;K2=lane_todo; Z3=data_len1; Z6=needle_len1; 5=GreaterEq;
  KTESTW        K2,  K2                   //;67E2F74E any lanes still todo?           ;K2=lane_todo;
  JNZ           scan_loop                 //;677C9F60 jump if not zero (ZF = 0)       ;

//; we are done scanning for the first code-point; test if there are more
  VMOVDQA32     Z2,  Z4                   //;835001A1 data_off2 := data_off1          ;Z4=data_off2; Z2=data_off1;
  VMOVDQA32     Z3,  Z5                   //;31B4F894 data_len2 := data_len1          ;Z5=data_len2; Z3=data_len1;
  CMPL          CX,  $1                   //;2BBD50B8 more than 1 char in needle?     ;CX=needle_len1;
  JZ            needle_loop_done          //;AFDB3970 jump if zero (ZF = 1)           ;
//; test if there is there is sufficient data
  VPCMPD        $6,  Z11, Z3,  K4,  K4    //;C0CF3FA2 K4 &= (data_len1>0)             ;K4=lane_selected; Z3=data_len1; Z11=0; 6=Greater;
  KTESTW        K4,  K4                   //;9AA8B932 any lanes selected?             ;K4=lane_selected;
  JZ            next                      //;31580AD4 no, then exit; jump if zero (ZF = 1);
//; init variables for needle_loop
  VPSUBD        Z10, Z6,  Z7              //;75A315B7 needle_len2 := needle_len1 - 1  ;Z7=needle_len2; Z6=needle_len1; Z10=1;
  MOVQ          R14, R13                  //;92B163CC needle_ptr2 := needle_ptr1      ;R13=needle_ptr2; R14=needle_ptr1;
  MOVQ          R15, BX                   //;15EE7900 wildcard_ptr2 := wildcard_ptr1  ;BX=wildcard_ptr2; R15=wildcard_ptr1;
  KMOVW         K4,  K2                   //;226BBC9E lane_todo := lane_selected      ;K2=lane_todo; K4=lane_selected;
needle_loop:
  KMOVW         K4,  K3                   //;F271B5DF copy eligible lanes             ;K3=tmp_mask; K4=lane_selected;
  VPGATHERDD    (SI)(Z4*1),K3,  Z8        //;2CF4C294 gather data                     ;Z8=data; K3=tmp_mask; SI=data_ptr; Z4=data_off2;
//; advance needle
  VPSUBD        Z10, Z7,  K4,  Z7         //;CAFCD045 needle_len2--                   ;Z7=needle_len2; K4=lane_selected; Z10=1;
//; mask tail data
  VPSRLD        $4,  Z8,  Z26             //;FE5F1413 scratch_Z26 := data>>4          ;Z26=scratch_Z26; Z8=data;
  VPERMD        Z21, Z26, Z27             //;68FECBA0 get n_bytes_data                ;Z27=n_bytes_data; Z26=scratch_Z26; Z21=table_n_bytes_utf8;
  VPERMD        Z18, Z27, Z26             //;488C6CD8 get tail_mask (data)            ;Z26=scratch_Z26; Z27=n_bytes_data; Z18=tail_mask_data;
  VPANDD.Z      Z8,  Z26, K2,  Z8         //;E750B0E2 mask data                       ;Z8=data; K2=lane_todo; Z26=scratch_Z26;
  VPADDD        Z27, Z4,  K4,  Z4         //;4879FB55 data_off2 += n_bytes_data       ;Z4=data_off2; K4=lane_selected; Z27=n_bytes_data;
  VPSUBD        Z27, Z5,  K4,  Z5         //;77CC472F data_len2 -= n_bytes_data       ;Z5=data_len2; K4=lane_selected; Z27=n_bytes_data;
//; compare with 4 code-points
  VPCMPD.BCST   $0,  (R13),Z8,  K4,  K3   //;15105C54 K3 := K4 & (data==[needle_ptr2]);K3=tmp_mask; K4=lane_selected; Z8=data; R13=needle_ptr2; 0=Eq;
  VPCMPD.BCST   $0,  4(R13),Z8,  K4,  K5  //;9C52A210 K5 := K4 & (data==[needle_ptr2+4]);K5=scratch_K5; K4=lane_selected; Z8=data; R13=needle_ptr2; 0=Eq;
  VPCMPD.BCST   $0,  8(R13),Z8,  K4,  K6  //;A8B34D3C K6 := K4 & (data==[needle_ptr2+8]);K6=scratch_K6; K4=lane_selected; Z8=data; R13=needle_ptr2; 0=Eq;
  VPCMPD.BCST   $0,  12(R13),Z8,  K4,  K0  //;343DD0F2 K0 := K4 & (data==[needle_ptr2+12]);K0=scratch_K0; K4=lane_selected; Z8=data; R13=needle_ptr2; 0=Eq;
  ADDQ          $16, R13                  //;5D0D7365 needle_ptr2 += 16               ;R13=needle_ptr2;
  KORW          K3,  K5,  K3              //;1125C81D tmp_mask |= scratch_K5          ;K3=tmp_mask; K5=scratch_K5;
  KMOVW         (BX),K5                   //;3CD32160 load wildcard                   ;K5=scratch_K5; BX=wildcard_ptr2;
  ADDQ          $2,  BX                   //;B9CC45F2 wildcard_ptr2 += 2              ;BX=wildcard_ptr2;
  KANDW         K5,  K4,  K5              //;F6A913D2 scratch_K5 &= lane_selected     ;K5=scratch_K5; K4=lane_selected;
  KORW          K3,  K6,  K3              //;DCB6AFAD tmp_mask |= scratch_K6          ;K3=tmp_mask; K6=scratch_K6;
  KORW          K3,  K0,  K4              //;65791592 lane_selected := scratch_K0 | tmp_mask;K4=lane_selected; K0=scratch_K0; K3=tmp_mask;
  KORW          K4,  K5,  K4              //;4FE420F5 lane_selected |= scratch_K5     ;K4=lane_selected; K5=scratch_K5;
//; advance to the next code-point
  VPCMPD        $6,  Z11, Z7,  K4,  K3    //;1185F8E2 K3 := K4 & (needle_len2>0)      ;K3=tmp_mask; K4=lane_selected; Z7=needle_len2; Z11=0; 6=Greater;
  VPCMPD        $2,  Z5,  Z7,  K4,  K4    //;7C50EFFB K4 &= (needle_len2<=data_len2)  ;K4=lane_selected; Z7=needle_len2; Z5=data_len2; 2=LessEq;
  KTESTW        K3,  K3                   //;98CB0D8B ZF := (K3==0); CF := 1          ;K3=tmp_mask;
  JNZ           needle_loop               //;E6065236 jump if not zero (ZF = 0)       ;
//; update lanes
needle_loop_done:
  KORW          K1,  K4,  K1              //;123EE41E lane_active |= lane_selected    ;K1=lane_active; K4=lane_selected;
  KANDNW        K2,  K4,  K2              //;32D9FB5F lane_todo &= ~lane_selected     ;K2=lane_todo; K4=lane_selected;
  VMOVDQA32     Z4,  K4,  Z2              //;5FA56037 data_off1 := data_off2          ;Z2=data_off1; K4=lane_selected; Z4=data_off2;
  VMOVDQA32     Z5,  K4,  Z3              //;8536472E data_len1 := data_len2          ;Z3=data_len1; K4=lane_selected; Z5=data_len2;
//; if there are any lanes still todo, scan those
  KTESTW        K2,  K2                   //;D8353CAF any lanes todo?                 ;K2=lane_todo;
  JNZ           scan_start                //;68ACA94C yes, then restart scanning; jump if not zero (ZF = 0);
next:
  NEXT()
//; #endregion bcContainsPatternUTF8Ci

//; #region bcIsSubnetOfIP4
//; Determine whether the string at Z2:Z3 is an IP address between the 4 provided bytewise min/max values
//; To prevent parsing of the IP string into an integer, every component is compared with a BCD min/max values
TEXT bcIsSubnetOfIP4(SB), NOSPLIT|NOFRAME, $0
  IMM_FROM_DICT(R14)                      //;05667C35 load *[]byte with the provided str into R14

  VPCMPD.BCST   $6,  CONSTD_6(),Z3,  K1,  K1  //;46C90536 K1 &= (str_len>6); only data larger than 6 is considered;K1=lane_active; Z3=str_len; 6=Greater;
  KTESTW        K1,  K1                   //;39066704 any lane still alive?           ;K1=lane_active;
  JZ            next                      //;47931531 no, exit; jump if zero (ZF = 1) ;

  MOVQ          (R14),R14                 //;D2647DF0 load needle_ptr                 ;R14=needle_ptr; R14=needle_slice;
  VPXORD        Z11, Z11, Z11             //;81C90120 load constant 0                 ;Z11=0;
  VPBROADCASTD  CONSTD_1(),Z10            //;6F57EE92 load constant 1                 ;Z10=1;
  VPBROADCASTD  CONSTD_4(),Z20            //;C8AFBE50 load constant 4                 ;Z20=4;
  VPBROADCASTB  CONSTD_0x2E(),Z21         //;487A092B load constant char_dot          ;Z21=char_dot;
  VPBROADCASTB  CONSTD_48(),Z16           //;62E46916 load constant char_0            ;Z16=char_0;
  VPBROADCASTB  CONSTB_57(),Z17           //;3D8FD928 load constant char_9            ;Z17=char_9;
  VPBROADCASTB  CONSTD_0x0F(),Z19         //;7E33FF0D load constant 0b00001111        ;Z19=0b00001111;
  VMOVDQU32     bswap32<>(SB),Z22         //;2510A88F load constant_bswap32           ;Z22=constant_bswap32;
  VMOVDQU32     CONST_TAIL_MASK(),Z18     //;7DB21CB0 load tail_mask_data             ;Z18=tail_mask_data;

  MOVL          $3,  CX                   //;97E4B0BB compare the first 3 components of IP;CX=counter;
loop:
  KMOVW         K1,  K3                   //;723D04C9 copy eligible lanes             ;K3=tmp_mask; K1=lane_active;
  VPGATHERDD    (SI)(Z2*1),K3,  Z8        //;E4967C89 gather data                     ;Z8=data_msg; K3=tmp_mask; SI=msg_ptr; Z2=str_start;
//; load min and max values for the next component of the IP
  VPBROADCASTD  (R14),Z14                 //;85FE2A68 load min/max BCD values         ;Z14=ip_min; R14=needle_ptr;
  ADDQ          $4,  R14                  //;B2EF9837 needle_ptr += 4                 ;R14=needle_ptr;
  VPSRLD        $4,  Z14, Z15             //;7D831D80 ip_max := ip_min>>4             ;Z15=ip_max; Z14=ip_min;
  VPANDD        Z14, Z19, Z14             //;C8F73FDE ip_min &= 0b00001111            ;Z14=ip_min; Z19=0b00001111;
  VPANDD        Z15, Z19, Z15             //;E5C42B44 ip_max &= 0b00001111            ;Z15=ip_max; Z19=0b00001111;
//; find position of the dot in zmm13, and shift data zmm8 accordingly
  VPSHUFB       Z22, Z8,  Z8              //;4F265F03 reverse byte order              ;Z8=data_msg; Z22=constant_bswap32;
  VPCMPB        $0,  Z21, Z8,  K3         //;FDA19C68 K3 := (data_msg==char_dot)      ;K3=tmp_mask; Z8=data_msg; Z21=char_dot; 0=Eq;
  VPMOVM2B      K3,  Z13                  //;E74FDEBD promote 64x bit to 64x byte     ;Z13=dot_pos; K3=tmp_mask;
  VPLZCNTD      Z13, Z13                  //;72202F9A count leading zeros             ;Z13=dot_pos;
  VPSRLD        $3,  Z13, Z13             //;6DC91432 divide by 8 yields dot_pos      ;Z13=dot_pos;
  VPSUBD        Z13, Z20, Z26             //;BC43621D scratch_Z26 := 4 - dot_pos      ;Z26=scratch_Z26; Z20=4; Z13=dot_pos;
  VPSLLD        $3,  Z26, Z26             //;B533D91C times 8 gives bytes to shift    ;Z26=scratch_Z26;
  VPSRLVD       Z26, Z8,  Z8              //;6D4B355C adjust data                     ;Z8=data_msg; Z26=scratch_Z26;
//; component has length > 0 and < 4
  VPCMPD        $6,  Z11, Z13, K1,  K1    //;DD83DE79 K1 &= (dot_pos>0)               ;K1=lane_active; Z13=dot_pos; Z11=0; 6=Greater;
  VPCMPD        $1,  Z20, Z13, K1,  K1    //;164BDB97 K1 &= (dot_pos<4)               ;K1=lane_active; Z13=dot_pos; Z20=4; 1=LessThen;
//; component length to mask
  VPERMD        Z18, Z13, Z26             //;54D8DBC3 get tail_mask                   ;Z26=scratch_Z26; Z13=dot_pos; Z18=tail_mask_data;
  VPCMPB        $4,  Z26, Z11, K2         //;2F692D99 K2 := (0!=scratch_Z26)          ;K2=ip_component; Z11=0; Z26=scratch_Z26; 4=NotEqual;
//; create mask with numbers in k3
  VPCMPB        $5,  Z16, Z8,  K2,  K3    //;4C1DDB1A K3 := K2 & (data_msg>=char_0)   ;K3=tmp_mask; K2=ip_component; Z8=data_msg; Z16=char_0; 5=GreaterEq;
  VPCMPB        $2,  Z17, Z8,  K3,  K3    //;90E4A177 K3 &= (data_msg<=char_9)        ;K3=tmp_mask; Z8=data_msg; Z17=char_9; 2=LessEq;
//; every character in component should be a number
  KXORQ         K3,  K2,  K3              //;32403AF0 tmp_mask ^= ip_component        ;K3=tmp_mask; K2=ip_component;
  VPMOVM2B      K3,  Z26                  //;E74FDEBD promote 64x bit to 64x byte     ;Z26=scratch_Z26; K3=tmp_mask;
  VPTESTNMD     Z26, Z26, K1,  K1         //;3014812A K1 &= (scratch_Z26==0)          ;K1=lane_active; Z26=scratch_Z26;
//; remaining length should be larger than 1
  VPCMPD        $6,  Z10, Z3,  K1,  K1    //;90F775EC K1 &= (str_len>1)               ;K1=lane_active; Z3=str_len; Z10=1; 6=Greater;
//; remove upper nibble from data zmm8 such that we can compare
  VPANDD        Z8,  Z19, Z8              //;C318FD02 data_msg &= 0b00001111          ;Z8=data_msg; Z19=0b00001111;
  VPCMPD        $5,  Z14, Z8,  K1,  K1    //;982B35DE K1 &= (data_msg>=ip_min)        ;K1=lane_active; Z8=data_msg; Z14=ip_min; 5=GreaterEq;
  VPCMPD        $2,  Z15, Z8,  K1,  K1    //;27BFCA91 K1 &= (data_msg<=ip_max)        ;K1=lane_active; Z8=data_msg; Z15=ip_max; 2=LessEq;
  KTESTW        K1,  K1                   //;50A3F3F1 any lane still alive?           ;K1=lane_active;
  JZ            next                      //;B763A908 no, exit; jump if zero (ZF = 1) ;
//; update length and offset
  VPADDD        Z10, Z13, Z26             //;E66940CD scratch_Z26 := dot_pos + 1      ;Z26=scratch_Z26; Z13=dot_pos; Z10=1;
  VPSUBD        Z26, Z3,  K1,  Z3         //;E060A4BE str_len -= scratch_Z26          ;Z3=str_len; K1=lane_active; Z26=scratch_Z26;
  VPADDD        Z26, Z2,  K1,  Z2         //;8DD591CA str_start += scratch_Z26        ;Z2=str_start; K1=lane_active; Z26=scratch_Z26;

  DECL          CX                        //;18ACCC03 counter--                       ;CX=counter;
  JNZ           loop                      //;6929AA0C another component in IP present?; jump if not zero (ZF = 0);
//; load last component of IP address
  KMOVW         K1,  K3                   //;723D04C9 copy eligible lanes             ;K3=tmp_mask; K1=lane_active;
  VPGATHERDD    (SI)(Z2*1),K3,  Z8        //;E4967C89 gather data                     ;Z8=data_msg; K3=tmp_mask; SI=msg_ptr; Z2=str_start;
//; load min and max values for the last component of the IP
  VPBROADCASTD  (R14),Z14                 //;85FE2A68 load min/max BCD values         ;Z14=ip_min; R14=needle_ptr;
  VPSRLD        $4,  Z14, Z15             //;7D831D80 ip_max := ip_min>>4             ;Z15=ip_max; Z14=ip_min;
  VPANDD        Z14, Z19, Z14             //;C8F73FDE ip_min &= 0b00001111            ;Z14=ip_min; Z19=0b00001111;
  VPANDD        Z15, Z19, Z15             //;E5C42B44 ip_max &= 0b00001111            ;Z15=ip_max; Z19=0b00001111;
//; find position of the dot in zmm13, and shift data zmm8 accordingly; but since there is no dot, use remaining bytes instead
  VPSHUFB       Z22, Z8,  Z8              //;4F265F03 reverse byte order              ;Z8=data_msg; Z22=constant_bswap32;
  VPSUBD        Z3,  Z20, Z26             //;BC43621D scratch_Z26 := 4 - str_len      ;Z26=scratch_Z26; Z20=4; Z3=str_len;
  VPSLLD        $3,  Z26, Z26             //;B533D91C times 8 gives bytes to shift    ;Z26=scratch_Z26;
  VPSRLVD       Z26, Z8,  Z8              //;6D4B355C adjust data                     ;Z8=data_msg; Z26=scratch_Z26;
//; component has length > 0 and < 4
  VPCMPD        $6,  Z11, Z3,  K1,  K1    //;C57C0EDA K1 &= (str_len>0)               ;K1=lane_active; Z3=str_len; Z11=0; 6=Greater;
  VPCMPD        $1,  Z20, Z3,  K1,  K1    //;F144CD35 K1 &= (str_len<4)               ;K1=lane_active; Z3=str_len; Z20=4; 1=LessThen;
//; component length to mask
  VPERMD        Z18, Z3,  Z26             //;716E0F84 get tail_mask                   ;Z26=scratch_Z26; Z3=str_len; Z18=tail_mask_data;
  VPCMPB        $4,  Z26, Z11, K2         //;BDEDF5D8 K2 := (0!=scratch_Z26)          ;K2=ip_component; Z11=0; Z26=scratch_Z26; 4=NotEqual;
//; create mask with numbers in k3
  VPCMPB        $5,  Z16, Z8,  K2,  K3    //;7812E56D K3 := K2 & (data_msg>=char_0)   ;K3=tmp_mask; K2=ip_component; Z8=data_msg; Z16=char_0; 5=GreaterEq;
  VPCMPB        $2,  Z17, Z8,  K3,  K3    //;1A6DB788 K3 &= (data_msg<=char_9)        ;K3=tmp_mask; Z8=data_msg; Z17=char_9; 2=LessEq;
//; every character in component should be a number
  KXORQ         K3,  K2,  K3              //;4F099B70 tmp_mask ^= ip_component        ;K3=tmp_mask; K2=ip_component;
  VPMOVM2B      K3,  Z26                  //;E74FDEBD promote 64x bit to 64x byte     ;Z26=scratch_Z26; K3=tmp_mask;
  VPTESTNMD     Z26, Z26, K1,  K1         //;88DAC27C K1 &= (scratch_Z26==0)          ;K1=lane_active; Z26=scratch_Z26;
//; remove upper nibble from data zmm8 such that we can compare
  VPANDD        Z8,  Z19, Z8              //;C318FD02 data_msg &= 0b00001111          ;Z8=data_msg; Z19=0b00001111;
  VPCMPD        $5,  Z14, Z8,  K1,  K1    //;982B35DE K1 &= (data_msg>=ip_min)        ;K1=lane_active; Z8=data_msg; Z14=ip_min; 5=GreaterEq;
  VPCMPD        $2,  Z15, Z8,  K1,  K1    //;27BFCA91 K1 &= (data_msg<=ip_max)        ;K1=lane_active; Z8=data_msg; Z15=ip_max; 2=LessEq;
next:
  NEXT()
//; #endregion bcIsSubnetOfIP4

//; #region bcDfaT6
//; DfaT6 Deterministic Finite Automaton (DFA) with 6-bits lookup-key and unicode wildcard
TEXT bcDfaT6(SB), NOSPLIT|NOFRAME, $0
  IMM_FROM_DICT(R14)                      //;05667C35 load *[]byte with the provided str into R14
  MOVQ          (R14),R14                 //;D2647DF0 load needle_ptr                 ;R14=needle_ptr; R14=needle_slice;
//; load parameters
  VMOVDQU32     (R14),Z21                 //;CAEE2FF0 char_table1 := [needle_ptr]     ;Z21=char_table1; R14=needle_ptr;
  VMOVDQU32     64(R14),Z22               //;E0639585 char_table2 := [needle_ptr+64]  ;Z22=char_table2; R14=needle_ptr;
  VMOVDQU32     128(R14),Z23              //;15D38369 trans_table1 := [needle_ptr+128];Z23=trans_table1; R14=needle_ptr;
  KMOVW         192(R14),K6               //;2C9E73B8 load wildcard enabled flag      ;K6=enabled_flag; R14=needle_ptr;
  VPBROADCASTD  194(R14),Z5               //;803E3CDF load wildcard char-group        ;Z5=wildcard; R14=needle_ptr;
  VPBROADCASTD  198(R14),Z13              //;6891DA5E load accept state               ;Z13=accept_state; R14=needle_ptr;
//; load constants
  VPXORD        Z11, Z11, Z11             //;81C90120 load constant 0                 ;Z11=0;
  VPBROADCASTD  CONSTD_1(),Z10            //;6F57EE92 load constant 1                 ;Z10=1;
  VPADDD        Z10, Z10, Z15             //;92620230 constd_2 := 1 + 1               ;Z15=2; Z10=1;
  VPADDD        Z10, Z15, Z16             //;45FD27E2 constd_3 := 2 + 1               ;Z16=3; Z15=2; Z10=1;
  VPADDD        Z15, Z15, Z20             //;D9A45253 constd_4 := 2 + 2               ;Z20=4; Z15=2;
  VMOVDQU32     CONST_N_BYTES_UTF8(),Z18  //;B323211A load table_n_bytes_utf8         ;Z18=table_n_bytes_utf8;
//; init variables
  KMOVW         K1,  K2                   //;AE3AAD43 lane_todo := lane_active        ;K2=lane_todo; K1=lane_active;
  KXORW         K1,  K1,  K1              //;FA91A63F lane_active := 0                ;K1=lane_active;
  VMOVDQA32     Z10, Z7                   //;77B17C9A start_state is state 1          ;Z7=curr_state; Z10=1;
main_loop:
  KMOVW         K2,  K3                   //;81412269 copy eligible lanes             ;K3=scratch; K2=lane_todo;
  VPXORD        Z8,  Z8,  Z8              //;220F8650 clear stale non-ASCII content   ;Z8=data_msg;
  VPGATHERDD    (SI)(Z2*1),K3,  Z8        //;E4967C89 gather data                     ;Z8=data_msg; K3=scratch; SI=msg_ptr; Z2=str_start;
  VPMOVB2M      Z8,  K5                   //;385A4763 extract non-ASCII mask          ;K5=lane_non-ASCII; Z8=data_msg;
//; determine whether a lane has a non-ASCII code-point
  VPMOVM2B      K5,  Z12                  //;96C10C0D promote 64x bit to 64x byte     ;Z12=scratch_Z12; K5=lane_non-ASCII;
  VPCMPD        $4,  Z12, Z11, K2,  K3    //;92DE265B K3 := K2 & (0!=scratch_Z12); extract lanes with non-ASCII code-points;K3=scratch; K2=lane_todo; Z11=0; Z12=scratch_Z12; 4=NotEqual;
  KTESTW        K6,  K3                   //;BCE8C4F2 feature enabled and non-ASCII present?;K3=scratch; K6=enabled_flag;
  JNZ           skip_wildcard             //;10BF1BFB jump if not zero (ZF = 0)       ;
//; get char-groups
  VPERMI2B      Z22, Z21, Z8              //;872E1226 map data to char_group          ;Z8=data_msg; Z21=char_table1; Z22=char_table2;
  VMOVDQU8      Z11, K5,  Z8              //;2BDE3FA8 set non-ASCII to zero group     ;Z8=data_msg; K5=lane_non-ASCII; Z11=0;
//; handle 1st ASCII in data
  VPCMPD        $5,  Z10, Z3,  K4         //;850DE385 K4 := (str_len>=1)              ;K4=char_valid; Z3=str_len; Z10=1; 5=GreaterEq;
  VPORD         Z8,  Z7,  Z9              //;C09CA74A merge char_group with curr_state into lookup_key;Z9=next_state; Z7=curr_state; Z8=data_msg;
  VPERMB        Z23, Z9,  Z9              //;F0A7B6B3 map lookup_key to next_state    ;Z9=next_state; Z23=trans_table1;
  VMOVDQA32     Z9,  K4,  Z7              //;F3DF61B6 curr_state := next_state        ;Z7=curr_state; K4=char_valid; Z9=next_state;
//; handle 2nd ASCII in data
  VPSRLD        $8,  Z8,  Z8              //;838875D4 data_msg >>= 8                  ;Z8=data_msg;
  VPCMPD        $5,  Z15, Z3,  K4         //;6C217CFD K4 := (str_len>=2)              ;K4=char_valid; Z3=str_len; Z15=2; 5=GreaterEq;
  VPORD         Z8,  Z7,  Z9              //;6FD26853 merge char_group with curr_state into lookup_key;Z9=next_state; Z7=curr_state; Z8=data_msg;
  VPERMB        Z23, Z9,  Z9              //;F0A7B6B3 map lookup_key to next_state    ;Z9=next_state; Z23=trans_table1;
  VMOVDQA32     Z9,  K4,  Z7              //;F3DF61B6 curr_state := next_state        ;Z7=curr_state; K4=char_valid; Z9=next_state;
//; handle 3rd ASCII in data
  VPSRLD        $8,  Z8,  Z8              //;838875D4 data_msg >>= 8                  ;Z8=data_msg;
  VPCMPD        $5,  Z16, Z3,  K4         //;BBDE408E K4 := (str_len>=3)              ;K4=char_valid; Z3=str_len; Z16=3; 5=GreaterEq;
  VPORD         Z8,  Z7,  Z9              //;BCCB1762 merge char_group with curr_state into lookup_key;Z9=next_state; Z7=curr_state; Z8=data_msg;
  VPERMB        Z23, Z9,  Z9              //;F0A7B6B3 map lookup_key to next_state    ;Z9=next_state; Z23=trans_table1;
  VMOVDQA32     Z9,  K4,  Z7              //;F3DF61B6 curr_state := next_state        ;Z7=curr_state; K4=char_valid; Z9=next_state;
//; handle 4th ASCII in data
  VPSRLD        $8,  Z8,  Z8              //;838875D4 data_msg >>= 8                  ;Z8=data_msg;
  VPCMPD        $5,  Z20, Z3,  K4         //;9B0EF476 K4 := (str_len>=4)              ;K4=char_valid; Z3=str_len; Z20=4; 5=GreaterEq;
  VPORD         Z8,  Z7,  Z9              //;42917E87 merge char_group with curr_state into lookup_key;Z9=next_state; Z7=curr_state; Z8=data_msg;
  VPERMB        Z23, Z9,  Z9              //;F0A7B6B3 map lookup_key to next_state    ;Z9=next_state; Z23=trans_table1;
  VMOVDQA32     Z9,  K4,  Z7              //;F3DF61B6 curr_state := next_state        ;Z7=curr_state; K4=char_valid; Z9=next_state;
//; advance 4 bytes (= 4 code-points)
  VPADDD        Z20, Z2,  Z2              //;F381FC8B str_start += 4                  ;Z2=str_start; Z20=4;
  VPSUBD        Z20, Z3,  Z3              //;D71AFBB0 str_len -= 4                    ;Z3=str_len; Z20=4;
tail:
  VPCMPD        $0,  Z7,  Z13, K2,  K3    //;9A003B95 K3 := K2 & (accept_state==curr_state);K3=scratch; K2=lane_todo; Z13=accept_state; Z7=curr_state; 0=Eq;
  VPCMPD        $4,  Z7,  Z11, K2,  K2    //;C4336141 K2 &= (0!=curr_state)           ;K2=lane_todo; Z11=0; Z7=curr_state; 4=NotEqual;
  VPCMPD        $1,  Z3,  Z11, K2,  K2    //;250BE13C K2 &= (0<str_len)               ;K2=lane_todo; Z11=0; Z3=str_len; 1=LessThen;
  KANDNW        K2,  K3,  K2              //;C9EB9B00 lane_todo &= ~scratch           ;K2=lane_todo; K3=scratch;
  KORW          K1,  K3,  K1              //;63AD07E8 lane_active |= scratch          ;K1=lane_active; K3=scratch;
  KTESTW        K2,  K2                   //;3D96F6AD any lane still todo?            ;K2=lane_todo;
  JNZ           main_loop                 //;274B80A2 jump if not zero (ZF = 0)       ;
next:
  NEXT()

skip_wildcard:
//; instead of advancing 4 bytes we advance 1 code-point, and set all non-ascii code-points to the wildcard group
  VPSRLD        $4,  Z8,  Z12             //;FE5F1413 scratch_Z12 := data_msg>>4      ;Z12=scratch_Z12; Z8=data_msg;
  VPERMD        Z18, Z12, Z12             //;68FECBA0 get scratch_Z12                 ;Z12=scratch_Z12; Z18=table_n_bytes_utf8;
//; get char-groups
  VPCMPD        $4,  Z12, Z10, K2,  K3    //;411A6A38 K3 := K2 & (1!=scratch_Z12)     ;K3=scratch; K2=lane_todo; Z10=1; Z12=scratch_Z12; 4=NotEqual;
  VPERMI2B      Z22, Z21, Z8              //;285E91E6 map data to char_group          ;Z8=data_msg; Z21=char_table1; Z22=char_table2;
  VMOVDQA32     Z5,  K3,  Z8              //;D9B3425A set non-ASCII to wildcard group ;Z8=data_msg; K3=scratch; Z5=wildcard;
//; advance 1 code-point
  VPSUBD        Z12, Z3,  Z3              //;8575652C str_len -= scratch_Z12          ;Z3=str_len; Z12=scratch_Z12;
  VPADDD        Z12, Z2,  Z2              //;A7D2A209 str_start += scratch_Z12        ;Z2=str_start; Z12=scratch_Z12;
//; handle 1st code-point in data
  VPCMPD        $5,  Z11, Z3,  K4         //;8DFA55D5 K4 := (str_len>=0)              ;K4=char_valid; Z3=str_len; Z11=0; 5=GreaterEq;
  VPORD         Z8,  Z7,  Z9              //;A73B0AC3 merge char_group with curr_state into lookup_key;Z9=next_state; Z7=curr_state; Z8=data_msg;
  VPERMB        Z23, Z9,  Z9              //;21B4F359 map lookup_key to next_state    ;Z9=next_state; Z23=trans_table1;
  VMOVDQA32     Z9,  K4,  Z7              //;1A66952A curr_state := next_state        ;Z7=curr_state; K4=char_valid; Z9=next_state;
  JMP           tail                      //;E21E4B3D                                 ;
//; #endregion bcDfaT6

//; #region bcDfaT7
//; DfaT7 Deterministic Finite Automaton (DFA) with 7-bits lookup-key and unicode wildcard
TEXT bcDfaT7(SB), NOSPLIT|NOFRAME, $0
  IMM_FROM_DICT(R14)                      //;05667C35 load *[]byte with the provided str into R14
  MOVQ          (R14),R14                 //;D2647DF0 load needle_ptr                 ;R14=needle_ptr; R14=needle_slice;
//; load parameters
  VMOVDQU32     (R14),Z21                 //;CAEE2FF0 char_table1 := [needle_ptr]     ;Z21=char_table1; R14=needle_ptr;
  VMOVDQU32     64(R14),Z22               //;E0639585 char_table2 := [needle_ptr+64]  ;Z22=char_table2; R14=needle_ptr;
  VMOVDQU32     128(R14),Z23              //;15D38369 trans_table1 := [needle_ptr+128];Z23=trans_table1; R14=needle_ptr;
  VMOVDQU32     192(R14),Z24              //;5DE9259D trans_table2 := [needle_ptr+192];Z24=trans_table2; R14=needle_ptr;
  KMOVW         256(R14),K6               //;2C9E73B8 load wildcard enabled flag      ;K6=enabled_flag; R14=needle_ptr;
  VPBROADCASTD  258(R14),Z5               //;803E3CDF load wildcard char-group        ;Z5=wildcard; R14=needle_ptr;
  VPBROADCASTD  262(R14),Z13              //;6891DA5E load accept nodeID              ;Z13=accept_node; R14=needle_ptr;
//; load constants
  VPXORD        Z11, Z11, Z11             //;81C90120 load constant 0                 ;Z11=0;
  VPBROADCASTD  CONSTD_1(),Z10            //;6F57EE92 load constant 1                 ;Z10=1;
  VPADDD        Z10, Z10, Z15             //;92620230 constd_2 := 1 + 1               ;Z15=2; Z10=1;
  VPADDD        Z10, Z15, Z16             //;45FD27E2 constd_3 := 2 + 1               ;Z16=3; Z15=2; Z10=1;
  VPADDD        Z15, Z15, Z20             //;D9A45253 constd_4 := 2 + 2               ;Z20=4; Z15=2;
  VMOVDQU32     CONST_N_BYTES_UTF8(),Z18  //;B323211A load table_n_bytes_utf8         ;Z18=table_n_bytes_utf8;
//; init variables
  KMOVW         K1,  K2                   //;AE3AAD43 lane_todo := lane_active        ;K2=lane_todo; K1=lane_active;
  KXORW         K1,  K1,  K1              //;FA91A63F lane_active := 0                ;K1=lane_active;
  VMOVDQA32     Z10, Z7                   //;77B17C9A start_state is state 1          ;Z7=curr_state; Z10=1;
main_loop:
  KMOVW         K2,  K3                   //;81412269 copy eligible lanes             ;K3=scratch; K2=lane_todo;
  VPXORD        Z8,  Z8,  Z8              //;220F8650 clear stale non-ASCII content   ;Z8=data_msg;
  VPGATHERDD    (SI)(Z2*1),K3,  Z8        //;E4967C89 gather data                     ;Z8=data_msg; K3=scratch; SI=msg_ptr; Z2=str_start;
  VPMOVB2M      Z8,  K5                   //;385A4763 extract non-ASCII mask          ;K5=lane_non-ASCII; Z8=data_msg;
//; determine whether a lane has a non-ASCII code-point
  VPMOVM2B      K5,  Z12                  //;96C10C0D promote 64x bit to 64x byte     ;Z12=scratch_Z12; K5=lane_non-ASCII;
  VPCMPD        $4,  Z12, Z11, K2,  K3    //;92DE265B K3 := K2 & (0!=scratch_Z12); extract lanes with non-ASCII code-points;K3=scratch; K2=lane_todo; Z11=0; Z12=scratch_Z12; 4=NotEqual;
  KTESTW        K6,  K3                   //;BCE8C4F2 feature enabled and non-ASCII present?;K3=scratch; K6=enabled_flag;
  JNZ           skip_wildcard             //;10BF1BFB jump if not zero (ZF = 0)       ;
//; get char-groups
  VPERMI2B      Z22, Z21, Z8              //;872E1226 map data to char_group          ;Z8=data_msg; Z21=char_table1; Z22=char_table2;
  VMOVDQU8      Z11, K5,  Z8              //;2BDE3FA8 set non-ASCII to zero group     ;Z8=data_msg; K5=lane_non-ASCII; Z11=0;
//; handle 1st ASCII in data
  VPCMPD        $5,  Z10, Z3,  K4         //;850DE385 K4 := (str_len>=1)              ;K4=char_valid; Z3=str_len; Z10=1; 5=GreaterEq;
  VPORD         Z8,  Z7,  Z9              //;C09CA74A merge char_group with curr_state into lookup_key;Z9=next_state; Z7=curr_state; Z8=data_msg;
  VPERMI2B      Z24, Z23, Z9              //;F0A7B6B3 map lookup_key to next_state    ;Z9=next_state; Z23=trans_table1; Z24=trans_table2;
  VMOVDQA32     Z9,  K4,  Z7              //;F3DF61B6 curr_state := next_state        ;Z7=curr_state; K4=char_valid; Z9=next_state;
//; handle 2nd ASCII in data
  VPSRLD        $8,  Z8,  Z8              //;838875D4 data_msg >>= 8                  ;Z8=data_msg;
  VPCMPD        $5,  Z15, Z3,  K4         //;6C217CFD K4 := (str_len>=2)              ;K4=char_valid; Z3=str_len; Z15=2; 5=GreaterEq;
  VPORD         Z8,  Z7,  Z9              //;6FD26853 merge char_group with curr_state into lookup_key;Z9=next_state; Z7=curr_state; Z8=data_msg;
  VPERMI2B      Z24, Z23, Z9              //;F0A7B6B3 map lookup_key to next_state    ;Z9=next_state; Z23=trans_table1; Z24=trans_table2;
  VMOVDQA32     Z9,  K4,  Z7              //;F3DF61B6 curr_state := next_state        ;Z7=curr_state; K4=char_valid; Z9=next_state;
//; handle 3rd ASCII in data
  VPSRLD        $8,  Z8,  Z8              //;838875D4 data_msg >>= 8                  ;Z8=data_msg;
  VPCMPD        $5,  Z16, Z3,  K4         //;BBDE408E K4 := (str_len>=3)              ;K4=char_valid; Z3=str_len; Z16=3; 5=GreaterEq;
  VPORD         Z8,  Z7,  Z9              //;BCCB1762 merge char_group with curr_state into lookup_key;Z9=next_state; Z7=curr_state; Z8=data_msg;
  VPERMI2B      Z24, Z23, Z9              //;F0A7B6B3 map lookup_key to next_state    ;Z9=next_state; Z23=trans_table1; Z24=trans_table2;
  VMOVDQA32     Z9,  K4,  Z7              //;F3DF61B6 curr_state := next_state        ;Z7=curr_state; K4=char_valid; Z9=next_state;
//; handle 4th ASCII in data
  VPSRLD        $8,  Z8,  Z8              //;838875D4 data_msg >>= 8                  ;Z8=data_msg;
  VPCMPD        $5,  Z20, Z3,  K4         //;9B0EF476 K4 := (str_len>=4)              ;K4=char_valid; Z3=str_len; Z20=4; 5=GreaterEq;
  VPORD         Z8,  Z7,  Z9              //;42917E87 merge char_group with curr_state into lookup_key;Z9=next_state; Z7=curr_state; Z8=data_msg;
  VPERMI2B      Z24, Z23, Z9              //;F0A7B6B3 map lookup_key to next_state    ;Z9=next_state; Z23=trans_table1; Z24=trans_table2;
  VMOVDQA32     Z9,  K4,  Z7              //;F3DF61B6 curr_state := next_state        ;Z7=curr_state; K4=char_valid; Z9=next_state;
//; advance 4 bytes (= 4 code-points)
  VPADDD        Z20, Z2,  Z2              //;F381FC8B str_start += 4                  ;Z2=str_start; Z20=4;
  VPSUBD        Z20, Z3,  Z3              //;D71AFBB0 str_len -= 4                    ;Z3=str_len; Z20=4;
tail:
  VPCMPD        $0,  Z7,  Z13, K2,  K3    //;9A003B95 K3 := K2 & (accept_node==curr_state);K3=scratch; K2=lane_todo; Z13=accept_node; Z7=curr_state; 0=Eq;
  VPCMPD        $4,  Z7,  Z11, K2,  K2    //;C4336141 K2 &= (0!=curr_state)           ;K2=lane_todo; Z11=0; Z7=curr_state; 4=NotEqual;
  VPCMPD        $1,  Z3,  Z11, K2,  K2    //;250BE13C K2 &= (0<str_len)               ;K2=lane_todo; Z11=0; Z3=str_len; 1=LessThen;
  KANDNW        K2,  K3,  K2              //;C9EB9B00 lane_todo &= ~scratch           ;K2=lane_todo; K3=scratch;
  KORW          K1,  K3,  K1              //;63AD07E8 lane_active |= scratch          ;K1=lane_active; K3=scratch;
  KTESTW        K2,  K2                   //;3D96F6AD any lane still todo?            ;K2=lane_todo;
  JNZ           main_loop                 //;274B80A2 jump if not zero (ZF = 0)       ;
next:
  NEXT()

skip_wildcard:
//; instead of advancing 4 bytes we advance 1 code-point, and set all non-ascii code-points to the wildcard group
  VPSRLD        $4,  Z8,  Z12             //;FE5F1413 scratch_Z12 := data_msg>>4      ;Z12=scratch_Z12; Z8=data_msg;
  VPERMD        Z18, Z12, Z12             //;68FECBA0 get scratch_Z12                 ;Z12=scratch_Z12; Z18=table_n_bytes_utf8;
//; get char-groups
  VPCMPD        $4,  Z12, Z10, K2,  K3    //;411A6A38 K3 := K2 & (1!=scratch_Z12)     ;K3=scratch; K2=lane_todo; Z10=1; Z12=scratch_Z12; 4=NotEqual;
  VPERMI2B      Z22, Z21, Z8              //;285E91E6 map data to char_group          ;Z8=data_msg; Z21=char_table1; Z22=char_table2;
  VMOVDQA32     Z5,  K3,  Z8              //;D9B3425A set non-ASCII to wildcard group ;Z8=data_msg; K3=scratch; Z5=wildcard;
//; advance 1 code-point
  VPSUBD        Z12, Z3,  Z3              //;8575652C str_len -= scratch_Z12          ;Z3=str_len; Z12=scratch_Z12;
  VPADDD        Z12, Z2,  Z2              //;A7D2A209 str_start += scratch_Z12        ;Z2=str_start; Z12=scratch_Z12;
//; handle 1st code-point in data
  VPCMPD        $5,  Z11, Z3,  K4         //;850DE385 K4 := (str_len>=0)              ;K4=char_valid; Z3=str_len; Z11=0; 5=GreaterEq;
  VPORD         Z8,  Z7,  Z9              //;C09CA74A merge char_group with curr_state into lookup_key;Z9=next_state; Z7=curr_state; Z8=data_msg;
  VPERMI2B      Z24, Z23, Z9              //;F0A7B6B3 map lookup_key to next_state    ;Z9=next_state; Z23=trans_table1; Z24=trans_table2;
  VMOVDQA32     Z9,  K4,  Z7              //;F3DF61B6 curr_state := next_state        ;Z7=curr_state; K4=char_valid; Z9=next_state;
  JMP           tail                      //;E21E4B3D                                 ;
//; #endregion bcDfaT7

//; #region bcDfaT8
//; DfaT8 Deterministic Finite Automaton (DFA) with 8-bits lookup-key
TEXT bcDfaT8(SB), NOSPLIT|NOFRAME, $0
  IMM_FROM_DICT(R14)                      //;05667C35 load *[]byte with the provided str into R14
  MOVQ          (R14),R14                 //;D2647DF0 load needle_ptr                 ;R14=needle_ptr; R14=needle_slice;
//; load parameters
  VMOVDQU32     (R14),Z21                 //;CAEE2FF0 char_table1 := [needle_ptr]     ;Z21=char_table1; R14=needle_ptr;
  VMOVDQU32     64(R14),Z22               //;E0639585 char_table2 := [needle_ptr+64]  ;Z22=char_table2; R14=needle_ptr;
  VMOVDQU32     128(R14),Z23              //;15D38369 trans_table1 := [needle_ptr+128];Z23=trans_table1; R14=needle_ptr;
  VMOVDQU32     192(R14),Z24              //;5DE9259D trans_table2 := [needle_ptr+192];Z24=trans_table2; R14=needle_ptr;
  VMOVDQU32     256(R14),Z25              //;BE3AEA52 trans_table3 := [needle_ptr+256];Z25=trans_table3; R14=needle_ptr;
  VMOVDQU32     320(R14),Z26              //;C346A0C9 trans_table4 := [needle_ptr+320];Z26=trans_table4; R14=needle_ptr;
  KMOVW         384(R14),K6               //;2C9E73B8 load wildcard enabled flag      ;K6=enabled_flag; R14=needle_ptr;
  VPBROADCASTD  386(R14),Z5               //;803E3CDF load wildcard char-group        ;Z5=wildcard; R14=needle_ptr;
  VPBROADCASTD  390(R14),Z13              //;E6CE5A10 load accept nodeID              ;Z13=accept_node; R14=needle_ptr;
//; load constants
  VPXORD        Z11, Z11, Z11             //;81C90120 load constant 0                 ;Z11=0;
  VPBROADCASTD  CONSTD_1(),Z10            //;6F57EE92 load constant 1                 ;Z10=1;
  VPADDD        Z10, Z10, Z15             //;92620230 constd_2 := 1 + 1               ;Z15=2; Z10=1;
  VPADDD        Z10, Z15, Z16             //;45FD27E2 constd_3 := 2 + 1               ;Z16=3; Z15=2; Z10=1;
  VPADDD        Z15, Z15, Z20             //;D9A45253 constd_4 := 2 + 2               ;Z20=4; Z15=2;
  VMOVDQU32     CONST_N_BYTES_UTF8(),Z18  //;B323211A load table_n_bytes_utf8         ;Z18=table_n_bytes_utf8;
//; init variables
  KMOVW         K1,  K2                   //;AE3AAD43 lane_todo := lane_active        ;K2=lane_todo; K1=lane_active;
  KXORW         K1,  K1,  K1              //;FA91A63F lane_active := 0                ;K1=lane_active;
  VMOVDQA32     Z10, Z7                   //;77B17C9A start_state is state 1          ;Z7=curr_state; Z10=1;
main_loop:
  KMOVW         K2,  K3                   //;81412269 copy eligible lanes             ;K3=scratch; K2=lane_todo;
  VPXORD        Z8,  Z8,  Z8              //;220F8650 clear stale non-ASCII content   ;Z8=data_msg;
  VPGATHERDD    (SI)(Z2*1),K3,  Z8        //;E4967C89 gather data                     ;Z8=data_msg; K3=scratch; SI=msg_ptr; Z2=str_start;
  VPMOVB2M      Z8,  K5                   //;385A4763 extract non-ASCII mask          ;K5=lane_non-ASCII; Z8=data_msg;
//; determine whether a lane has a non-ASCII code-point
  VPMOVM2B      K5,  Z12                  //;96C10C0D promote 64x bit to 64x byte     ;Z12=scratch_Z12; K5=lane_non-ASCII;
  VPCMPD        $4,  Z12, Z11, K2,  K3    //;92DE265B K3 := K2 & (0!=scratch_Z12); extract lanes with non-ASCII code-points;K3=scratch; K2=lane_todo; Z11=0; Z12=scratch_Z12; 4=NotEqual;
  KTESTW        K6,  K3                   //;BCE8C4F2 feature enabled and non-ASCII present?;K3=scratch; K6=enabled_flag;
  JNZ           skip_wildcard             //;10BF1BFB jump if not zero (ZF = 0)       ;
//; get char-groups
  VPMOVB2M      Z8,  K3                   //;23A1705D extract non-ASCII mask          ;K3=scratch; Z8=data_msg;
  VPERMI2B      Z22, Z21, Z8              //;872E1226 map data to char_group          ;Z8=data_msg; Z21=char_table1; Z22=char_table2;
  VMOVDQU8      Z11, K3,  Z8              //;2BDE3FA8 set non-ASCII to zero group     ;Z8=data_msg; K3=scratch; Z11=0;
//; handle 1st ASCII in data
  VPCMPD        $5,  Z10, Z3,  K4         //;850DE385 K4 := (str_len>=1)              ;K4=char_valid; Z3=str_len; Z10=1; 5=GreaterEq;
  VPORD         Z8,  Z7,  Z9              //;C09CA74A merge char_group with curr_state into lookup_key;Z9=next_state; Z7=curr_state; Z8=data_msg;
  VPMOVB2M      Z9,  K3                   //;5ABFD6B8 extract sign for merging        ;K3=scratch; Z9=next_state;
  VMOVDQA32     Z9,  Z17                  //;9B3CF590 alt2_lut8 := next_state         ;Z17=alt2_lut8; Z9=next_state;
  VPERMI2B      Z26, Z25, Z9              //;53BE6E94 map lookup_key to next_state    ;Z9=next_state; Z25=trans_table3; Z26=trans_table4;
  VPERMI2B      Z24, Z23, Z17             //;C82BB72B map lookup_key to next_state    ;Z17=alt2_lut8; Z23=trans_table1; Z24=trans_table2;
  VMOVDQU8      Z9,  K3,  Z17             //;86B7DFF1 alt2_lut8 := next_state         ;Z17=alt2_lut8; K3=scratch; Z9=next_state;
  VMOVDQA32     Z17, K4,  Z7              //;F9049BA0 curr_state := alt2_lut8         ;Z7=curr_state; K4=char_valid; Z17=alt2_lut8;
//; handle 2nd ASCII in data
  VPSRLD        $8,  Z8,  Z8              //;838875D4 data_msg >>= 8                  ;Z8=data_msg;
  VPCMPD        $5,  Z15, Z3,  K4         //;6C217CFD K4 := (str_len>=2)              ;K4=char_valid; Z3=str_len; Z15=2; 5=GreaterEq;
  VPORD         Z8,  Z7,  Z9              //;C09CA74A merge char_group with curr_state into lookup_key;Z9=next_state; Z7=curr_state; Z8=data_msg;
  VPMOVB2M      Z9,  K3                   //;565C3FAD extract sign for merging        ;K3=scratch; Z9=next_state;
  VMOVDQA32     Z9,  Z17                  //;9B3CF590 alt2_lut8 := next_state         ;Z17=alt2_lut8; Z9=next_state;
  VPERMI2B      Z26, Z25, Z9              //;53BE6E94 map lookup_key to next_state    ;Z9=next_state; Z25=trans_table3; Z26=trans_table4;
  VPERMI2B      Z24, Z23, Z17             //;C82BB72B map lookup_key to next_state    ;Z17=alt2_lut8; Z23=trans_table1; Z24=trans_table2;
  VMOVDQU8      Z9,  K3,  Z17             //;86B7DFF1 alt2_lut8 := next_state         ;Z17=alt2_lut8; K3=scratch; Z9=next_state;
  VMOVDQA32     Z17, K4,  Z7              //;F9049BA0 curr_state := alt2_lut8         ;Z7=curr_state; K4=char_valid; Z17=alt2_lut8;
//; handle 3rd ASCII in data
  VPSRLD        $8,  Z8,  Z8              //;838875D4 data_msg >>= 8                  ;Z8=data_msg;
  VPCMPD        $5,  Z16, Z3,  K4         //;BBDE408E K4 := (str_len>=3)              ;K4=char_valid; Z3=str_len; Z16=3; 5=GreaterEq;
  VPORD         Z8,  Z7,  Z9              //;C09CA74A merge char_group with curr_state into lookup_key;Z9=next_state; Z7=curr_state; Z8=data_msg;
  VPMOVB2M      Z9,  K3                   //;44C2F748 extract sign for merging        ;K3=scratch; Z9=next_state;
  VMOVDQA32     Z9,  Z17                  //;9B3CF590 alt2_lut8 := next_state         ;Z17=alt2_lut8; Z9=next_state;
  VPERMI2B      Z26, Z25, Z9              //;53BE6E94 map lookup_key to next_state    ;Z9=next_state; Z25=trans_table3; Z26=trans_table4;
  VPERMI2B      Z24, Z23, Z17             //;C82BB72B map lookup_key to next_state    ;Z17=alt2_lut8; Z23=trans_table1; Z24=trans_table2;
  VMOVDQU8      Z9,  K3,  Z17             //;86B7DFF1 alt2_lut8 := next_state         ;Z17=alt2_lut8; K3=scratch; Z9=next_state;
  VMOVDQA32     Z17, K4,  Z7              //;F9049BA0 curr_state := alt2_lut8         ;Z7=curr_state; K4=char_valid; Z17=alt2_lut8;
//; handle 4th ASCII in data
  VPSRLD        $8,  Z8,  Z8              //;838875D4 data_msg >>= 8                  ;Z8=data_msg;
  VPCMPD        $5,  Z20, Z3,  K4         //;9B0EF476 K4 := (str_len>=4)              ;K4=char_valid; Z3=str_len; Z20=4; 5=GreaterEq;
  VPORD         Z8,  Z7,  Z9              //;C09CA74A merge char_group with curr_state into lookup_key;Z9=next_state; Z7=curr_state; Z8=data_msg;
  VPMOVB2M      Z9,  K3                   //;BC53D421 extract sign for merging        ;K3=scratch; Z9=next_state;
  VMOVDQA32     Z9,  Z17                  //;9B3CF590 alt2_lut8 := next_state         ;Z17=alt2_lut8; Z9=next_state;
  VPERMI2B      Z26, Z25, Z9              //;53BE6E94 map lookup_key to next_state    ;Z9=next_state; Z25=trans_table3; Z26=trans_table4;
  VPERMI2B      Z24, Z23, Z17             //;C82BB72B map lookup_key to next_state    ;Z17=alt2_lut8; Z23=trans_table1; Z24=trans_table2;
  VMOVDQU8      Z9,  K3,  Z17             //;86B7DFF1 alt2_lut8 := next_state         ;Z17=alt2_lut8; K3=scratch; Z9=next_state;
  VMOVDQA32     Z17, K4,  Z7              //;F9049BA0 curr_state := alt2_lut8         ;Z7=curr_state; K4=char_valid; Z17=alt2_lut8;
//; advance 4 bytes (= 4 code-points)
  VPADDD        Z20, Z2,  Z2              //;F381FC8B str_start += 4                  ;Z2=str_start; Z20=4;
  VPSUBD        Z20, Z3,  Z3              //;D71AFBB0 str_len -= 4                    ;Z3=str_len; Z20=4;
tail:
  VPCMPD        $0,  Z7,  Z13, K2,  K3    //;9A003B95 K3 := K2 & (accept_node==curr_state);K3=scratch; K2=lane_todo; Z13=accept_node; Z7=curr_state; 0=Eq;
  VPCMPD        $4,  Z7,  Z11, K2,  K2    //;C4336141 K2 &= (0!=curr_state)           ;K2=lane_todo; Z11=0; Z7=curr_state; 4=NotEqual;
  VPCMPD        $1,  Z3,  Z11, K2,  K2    //;250BE13C K2 &= (0<str_len)               ;K2=lane_todo; Z11=0; Z3=str_len; 1=LessThen;
  KANDNW        K2,  K3,  K2              //;C9EB9B00 lane_todo &= ~scratch           ;K2=lane_todo; K3=scratch;
  KORW          K1,  K3,  K1              //;63AD07E8 lane_active |= scratch          ;K1=lane_active; K3=scratch;
  KTESTW        K2,  K2                   //;3D96F6AD any lane still todo?            ;K2=lane_todo;
  JNZ           main_loop                 //;274B80A2 jump if not zero (ZF = 0)       ;
next:
  NEXT()

skip_wildcard:
//; instead of advancing 4 bytes we advance 1 code-point, and set all non-ascii code-points to the wildcard group
  VPSRLD        $4,  Z8,  Z12             //;FE5F1413 scratch_Z12 := data_msg>>4      ;Z12=scratch_Z12; Z8=data_msg;
  VPERMD        Z18, Z12, Z12             //;68FECBA0 get scratch_Z12                 ;Z12=scratch_Z12; Z18=table_n_bytes_utf8;
//; get char-groups
  VPCMPD        $4,  Z12, Z10, K2,  K3    //;411A6A38 K3 := K2 & (1!=scratch_Z12)     ;K3=scratch; K2=lane_todo; Z10=1; Z12=scratch_Z12; 4=NotEqual;
  VPERMI2B      Z22, Z21, Z8              //;285E91E6 map data to char_group          ;Z8=data_msg; Z21=char_table1; Z22=char_table2;
  VMOVDQA32     Z5,  K3,  Z8              //;D9B3425A set non-ASCII to wildcard group ;Z8=data_msg; K3=scratch; Z5=wildcard;
//; advance 1 code-point
  VPSUBD        Z12, Z3,  Z3              //;8575652C str_len -= scratch_Z12          ;Z3=str_len; Z12=scratch_Z12;
  VPADDD        Z12, Z2,  Z2              //;A7D2A209 str_start += scratch_Z12        ;Z2=str_start; Z12=scratch_Z12;
//; handle 1st code-point in data
  VPCMPD        $5,  Z11, Z3,  K4         //;BFA0A870 K4 := (str_len>=0)              ;K4=char_valid; Z3=str_len; Z11=0; 5=GreaterEq;
  VPORD         Z8,  Z7,  Z9              //;C09CA74A merge char_group with curr_state into lookup_key;Z9=next_state; Z7=curr_state; Z8=data_msg;
  VPMOVB2M      Z9,  K3                   //;5ABFD6B8 extract sign for merging        ;K3=scratch; Z9=next_state;
  VMOVDQA32     Z9,  Z17                  //;9B3CF590 alt2_lut8 := next_state         ;Z17=alt2_lut8; Z9=next_state;
  VPERMI2B      Z26, Z25, Z9              //;53BE6E94 map lookup_key to next_state    ;Z9=next_state; Z25=trans_table3; Z26=trans_table4;
  VPERMI2B      Z24, Z23, Z17             //;C82BB72B map lookup_key to next_state    ;Z17=alt2_lut8; Z23=trans_table1; Z24=trans_table2;
  VMOVDQU8      Z9,  K3,  Z17             //;86B7DFF1 alt2_lut8 := next_state         ;Z17=alt2_lut8; K3=scratch; Z9=next_state;
  VMOVDQA32     Z17, K4,  Z7              //;F9049BA0 curr_state := alt2_lut8         ;Z7=curr_state; K4=char_valid; Z17=alt2_lut8;
  JMP           tail                      //;E21E4B3D                                 ;
//; #endregion bcDfaT8

//; #region bcDfaT6Z
//; DfaT6Z Deterministic Finite Automaton (DFA) with 6-bits lookup-key and Zero length remaining assertion
TEXT bcDfaT6Z(SB), NOSPLIT|NOFRAME, $0
  IMM_FROM_DICT(R14)                      //;05667C35 load *[]byte with the provided str into R14
  MOVQ          (R14),R14                 //;D2647DF0 load needle_ptr                 ;R14=needle_ptr; R14=needle_slice;
//; load parameters
  VMOVDQU32     (R14),Z21                 //;CAEE2FF0 char_table1 := [needle_ptr]     ;Z21=char_table1; R14=needle_ptr;
  VMOVDQU32     64(R14),Z22               //;E0639585 char_table2 := [needle_ptr+64]  ;Z22=char_table2; R14=needle_ptr;
  VMOVDQU32     128(R14),Z23              //;15D38369 trans_table1 := [needle_ptr+128];Z23=trans_table1; R14=needle_ptr;
  KMOVW         192(R14),K6               //;2C9E73B8 load wildcard enabled flag      ;K6=enabled_flag; R14=needle_ptr;
  VPBROADCASTD  194(R14),Z5               //;803E3CDF load wildcard char-group        ;Z5=wildcard; R14=needle_ptr;
  VPBROADCASTD  198(R14),Z13              //;E6CE5A10 load accept state               ;Z13=accept_state; R14=needle_ptr;
  KMOVQ         202(R14),K3               //;B925FEF8 load RLZ states                 ;K3=scratch; R14=needle_ptr;
  VPMOVM2B      K3,  Z14                  //;40FAB4CE promote 64x bit to 64x byte     ;Z14=rlz_states; K3=scratch;
//; load constants
  VPXORD        Z11, Z11, Z11             //;81C90120 load constant 0                 ;Z11=0;
  VPBROADCASTD  CONSTD_1(),Z10            //;6F57EE92 load constant 1                 ;Z10=1;
  VPADDD        Z10, Z10, Z15             //;92620230 constd_2 := 1 + 1               ;Z15=2; Z10=1;
  VPADDD        Z10, Z15, Z16             //;45FD27E2 constd_3 := 2 + 1               ;Z16=3; Z15=2; Z10=1;
  VPADDD        Z15, Z15, Z20             //;D9A45253 constd_4 := 2 + 2               ;Z20=4; Z15=2;
  VMOVDQU32     CONST_N_BYTES_UTF8(),Z18  //;B323211A load table_n_bytes_utf8         ;Z18=table_n_bytes_utf8;
//; init variables
  KMOVW         K1,  K2                   //;AE3AAD43 lane_todo := lane_active        ;K2=lane_todo; K1=lane_active;
  KXORW         K1,  K1,  K1              //;FA91A63F lane_active := 0                ;K1=lane_active;
  VMOVDQA32     Z10, Z7                   //;77B17C9A start_state is state 1          ;Z7=curr_state; Z10=1;
main_loop:
  VPXORD        Z6,  Z6,  Z6              //;7B026700 rlz_state := 0                  ;Z6=rlz_state;
  KMOVW         K2,  K3                   //;81412269 copy eligible lanes             ;K3=scratch; K2=lane_todo;
  VPXORD        Z8,  Z8,  Z8              //;220F8650 clear stale non-ASCII content   ;Z8=data_msg;
  VPGATHERDD    (SI)(Z2*1),K3,  Z8        //;E4967C89 gather data                     ;Z8=data_msg; K3=scratch; SI=msg_ptr; Z2=str_start;
  VPMOVB2M      Z8,  K5                   //;385A4763 extract non-ASCII mask          ;K5=lane_non-ASCII; Z8=data_msg;
//; determine whether a lane has a non-ASCII code-point
  VPMOVM2B      K5,  Z12                  //;96C10C0D promote 64x bit to 64x byte     ;Z12=scratch_Z12; K5=lane_non-ASCII;
  VPCMPD        $4,  Z12, Z11, K2,  K3    //;92DE265B K3 := K2 & (0!=scratch_Z12); extract lanes with non-ASCII code-points;K3=scratch; K2=lane_todo; Z11=0; Z12=scratch_Z12; 4=NotEqual;
  KTESTW        K6,  K3                   //;BCE8C4F2 feature enabled and non-ASCII present?;K3=scratch; K6=enabled_flag;
  JNZ           skip_wildcard             //;10BF1BFB jump if not zero (ZF = 0)       ;
//; get char-groups
  VPERMI2B      Z22, Z21, Z8              //;872E1226 map data to char_group          ;Z8=data_msg; Z21=char_table1; Z22=char_table2;
  VMOVDQU8      Z11, K5,  Z8              //;2BDE3FA8 set non-ASCII to zero group     ;Z8=data_msg; K5=lane_non-ASCII; Z11=0;
//; handle 1st ASCII in data
  VPCMPD        $5,  Z10, Z3,  K4         //;89485A8A K4 := (str_len>=1)              ;K4=char_valid; Z3=str_len; Z10=1; 5=GreaterEq;
  VPCMPD        $0,  Z10, Z3,  K5         //;A23A5A84 K5 := (str_len==1)              ;K5=lane_non-ASCII; Z3=str_len; Z10=1; 0=Eq;
  VPORD         Z8,  Z7,  Z9              //;C09CA74A merge char_group with curr_state into lookup_key;Z9=next_state; Z7=curr_state; Z8=data_msg;
  VPERMB        Z23, Z9,  Z9              //;F0A7B6B3 map lookup_key to next_state    ;Z9=next_state; Z23=trans_table1;
  VMOVDQA32     Z9,  K4,  Z7              //;F3DF61B6 curr_state := next_state        ;Z7=curr_state; K4=char_valid; Z9=next_state;
  VMOVDQA32     Z9,  K5,  Z6              //;8EFED6E5 rlz_state := next_state         ;Z6=rlz_state; K5=lane_non-ASCII; Z9=next_state;
//; handle 2nd ASCII in data
  VPSRLD        $8,  Z8,  Z8              //;838875D4 data_msg >>= 8                  ;Z8=data_msg;
  VPCMPD        $5,  Z15, Z3,  K4         //;12B1EB36 K4 := (str_len>=2)              ;K4=char_valid; Z3=str_len; Z15=2; 5=GreaterEq;
  VPCMPD        $0,  Z15, Z3,  K5         //;47BF9EE9 K5 := (str_len==2)              ;K5=lane_non-ASCII; Z3=str_len; Z15=2; 0=Eq;
  VPORD         Z8,  Z7,  Z9              //;C09CA74A merge char_group with curr_state into lookup_key;Z9=next_state; Z7=curr_state; Z8=data_msg;
  VPERMB        Z23, Z9,  Z9              //;F0A7B6B3 map lookup_key to next_state    ;Z9=next_state; Z23=trans_table1;
  VMOVDQA32     Z9,  K4,  Z7              //;F3DF61B6 curr_state := next_state        ;Z7=curr_state; K4=char_valid; Z9=next_state;
  VMOVDQA32     Z9,  K5,  Z6              //;8EFED6E5 rlz_state := next_state         ;Z6=rlz_state; K5=lane_non-ASCII; Z9=next_state;
//; handle 3rd ASCII in data
  VPSRLD        $8,  Z8,  Z8              //;838875D4 data_msg >>= 8                  ;Z8=data_msg;
  VPCMPD        $5,  Z16, Z3,  K4         //;6E26712A K4 := (str_len>=3)              ;K4=char_valid; Z3=str_len; Z16=3; 5=GreaterEq;
  VPCMPD        $0,  Z16, Z3,  K5         //;91BAEA96 K5 := (str_len==3)              ;K5=lane_non-ASCII; Z3=str_len; Z16=3; 0=Eq;
  VPORD         Z8,  Z7,  Z9              //;C09CA74A merge char_group with curr_state into lookup_key;Z9=next_state; Z7=curr_state; Z8=data_msg;
  VPERMB        Z23, Z9,  Z9              //;F0A7B6B3 map lookup_key to next_state    ;Z9=next_state; Z23=trans_table1;
  VMOVDQA32     Z9,  K4,  Z7              //;F3DF61B6 curr_state := next_state        ;Z7=curr_state; K4=char_valid; Z9=next_state;
  VMOVDQA32     Z9,  K5,  Z6              //;8EFED6E5 rlz_state := next_state         ;Z6=rlz_state; K5=lane_non-ASCII; Z9=next_state;
//; handle 4th ASCII in data
  VPSRLD        $8,  Z8,  Z8              //;838875D4 data_msg >>= 8                  ;Z8=data_msg;
  VPCMPD        $5,  Z20, Z3,  K4         //;CFBDCA00 K4 := (str_len>=4)              ;K4=char_valid; Z3=str_len; Z20=4; 5=GreaterEq;
  VPCMPD        $0,  Z20, Z3,  K5         //;2154FFD7 K5 := (str_len==4)              ;K5=lane_non-ASCII; Z3=str_len; Z20=4; 0=Eq;
  VPORD         Z8,  Z7,  Z9              //;C09CA74A merge char_group with curr_state into lookup_key;Z9=next_state; Z7=curr_state; Z8=data_msg;
  VPERMB        Z23, Z9,  Z9              //;F0A7B6B3 map lookup_key to next_state    ;Z9=next_state; Z23=trans_table1;
  VMOVDQA32     Z9,  K4,  Z7              //;F3DF61B6 curr_state := next_state        ;Z7=curr_state; K4=char_valid; Z9=next_state;
  VMOVDQA32     Z9,  K5,  Z6              //;8EFED6E5 rlz_state := next_state         ;Z6=rlz_state; K5=lane_non-ASCII; Z9=next_state;
//; advance 4 bytes (= 4 code-points)
  VPADDD        Z20, Z2,  Z2              //;F381FC8B str_start += 4                  ;Z2=str_start; Z20=4;
  VPSUBD        Z20, Z3,  Z3              //;D71AFBB0 str_len -= 4                    ;Z3=str_len; Z20=4;
tail:
  VPCMPD        $0,  Z7,  Z13, K2,  K3    //;9A003B95 K3 := K2 & (accept_state==curr_state);K3=scratch; K2=lane_todo; Z13=accept_state; Z7=curr_state; 0=Eq;
  VPERMB        Z14, Z6,  Z12             //;F1661DA9 map RLZ states to 0xFF          ;Z12=scratch_Z12; Z6=rlz_state; Z14=rlz_states;
  VPSLLD.Z      $24, Z12, K2,  Z12        //;7352EFC4 scratch_Z12 <<= 24              ;Z12=scratch_Z12; K2=lane_todo;
  VPMOVD2M      Z12, K4                   //;6832FF1A extract RLZ mask                ;K4=char_valid; Z12=scratch_Z12;
  VPCMPD        $4,  Z7,  Z11, K2,  K2    //;C4336141 K2 &= (0!=curr_state)           ;K2=lane_todo; Z11=0; Z7=curr_state; 4=NotEqual;
  VPCMPD        $1,  Z3,  Z11, K2,  K2    //;250BE13C K2 &= (0<str_len)               ;K2=lane_todo; Z11=0; Z3=str_len; 1=LessThen;
  KORW          K3,  K4,  K3              //;24142563 scratch |= char_valid           ;K3=scratch; K4=char_valid;
  KANDNW        K2,  K3,  K2              //;C9EB9B00 lane_todo &= ~scratch           ;K2=lane_todo; K3=scratch;
  KORW          K1,  K3,  K1              //;63AD07E8 lane_active |= scratch          ;K1=lane_active; K3=scratch;
  KTESTW        K2,  K2                   //;3D96F6AD any lane still todo?            ;K2=lane_todo;
  JNZ           main_loop                 //;274B80A2 jump if not zero (ZF = 0)       ;
next:
  NEXT()

skip_wildcard:
//; instead of advancing 4 bytes we advance 1 code-point, and set all non-ascii code-points to the wildcard group
  VPSRLD        $4,  Z8,  Z12             //;FE5F1413 scratch_Z12 := data_msg>>4      ;Z12=scratch_Z12; Z8=data_msg;
  VPERMD        Z18, Z12, Z12             //;68FECBA0 get scratch_Z12                 ;Z12=scratch_Z12; Z18=table_n_bytes_utf8;
//; get char-groups
  VPCMPD        $4,  Z12, Z10, K2,  K3    //;411A6A38 K3 := K2 & (1!=scratch_Z12)     ;K3=scratch; K2=lane_todo; Z10=1; Z12=scratch_Z12; 4=NotEqual;
  VPERMI2B      Z22, Z21, Z8              //;285E91E6 map data to char_group          ;Z8=data_msg; Z21=char_table1; Z22=char_table2;
  VMOVDQA32     Z5,  K3,  Z8              //;D9B3425A set non-ASCII to wildcard group ;Z8=data_msg; K3=scratch; Z5=wildcard;
//; advance 1 code-point
  VPSUBD        Z12, Z3,  Z3              //;8575652C str_len -= scratch_Z12          ;Z3=str_len; Z12=scratch_Z12;
  VPADDD        Z12, Z2,  Z2              //;A7D2A209 str_start += scratch_Z12        ;Z2=str_start; Z12=scratch_Z12;
//; handle 1st code-point in data
  VPCMPD        $5,  Z11, Z3,  K4         //;89485A8A K4 := (str_len>=0)              ;K4=char_valid; Z3=str_len; Z11=0; 5=GreaterEq;
  VPCMPD        $0,  Z11, Z3,  K5         //;A23A5A84 K5 := (str_len==0)              ;K5=lane_non-ASCII; Z3=str_len; Z11=0; 0=Eq;
  VPORD         Z8,  Z7,  Z9              //;C09CA74A merge char_group with curr_state into lookup_key;Z9=next_state; Z7=curr_state; Z8=data_msg;
  VPERMB        Z23, Z9,  Z9              //;F0A7B6B3 map lookup_key to next_state    ;Z9=next_state; Z23=trans_table1;
  VMOVDQA32     Z9,  K4,  Z7              //;F3DF61B6 curr_state := next_state        ;Z7=curr_state; K4=char_valid; Z9=next_state;
  VMOVDQA32     Z9,  K5,  Z6              //;8EFED6E5 rlz_state := next_state         ;Z6=rlz_state; K5=lane_non-ASCII; Z9=next_state;
  JMP           tail                      //;E21E4B3D                                 ;
//; #endregion bcDfaT6Z

//; #region bcDfaT7Z
//; DfaT7Z Deterministic Finite Automaton (DFA) with 7-bits lookup-key and Zero length remaining assertion
TEXT bcDfaT7Z(SB), NOSPLIT|NOFRAME, $0
  IMM_FROM_DICT(R14)                      //;05667C35 load *[]byte with the provided str into R14
  MOVQ          (R14),R14                 //;D2647DF0 load needle_ptr                 ;R14=needle_ptr; R14=needle_slice;
//; load parameters
  VMOVDQU32     (R14),Z21                 //;CAEE2FF0 char_table1 := [needle_ptr]     ;Z21=char_table1; R14=needle_ptr;
  VMOVDQU32     64(R14),Z22               //;E0639585 char_table2 := [needle_ptr+64]  ;Z22=char_table2; R14=needle_ptr;
  VMOVDQU32     128(R14),Z23              //;15D38369 trans_table1 := [needle_ptr+128];Z23=trans_table1; R14=needle_ptr;
  VMOVDQU32     192(R14),Z24              //;5DE9259D trans_table2 := [needle_ptr+192];Z24=trans_table2; R14=needle_ptr;
  KMOVW         256(R14),K6               //;2C9E73B8 load wildcard enabled flag      ;K6=enabled_flag; R14=needle_ptr;
  VPBROADCASTD  258(R14),Z5               //;803E3CDF load wildcard char-group        ;Z5=wildcard; R14=needle_ptr;
  VPBROADCASTD  262(R14),Z13              //;E6CE5A10 load accept state               ;Z13=accept_state; R14=needle_ptr;
  KMOVQ         266(R14),K3               //;B925FEF8 load RLZ states                 ;K3=scratch; R14=needle_ptr;
  VPMOVM2B      K3,  Z14                  //;40FAB4CE promote 64x bit to 64x byte     ;Z14=rlz_states; K3=scratch;
//; load constants
  VPBROADCASTD  CONSTD_1(),Z10            //;6F57EE92 load constant 1                 ;Z10=1;
  VPXORD        Z11, Z11, Z11             //;81C90120 load constant 0                 ;Z11=0;
  VPADDD        Z10, Z10, Z15             //;92620230 constd_2 := 1 + 1               ;Z15=2; Z10=1;
  VPADDD        Z10, Z15, Z16             //;45FD27E2 constd_3 := 2 + 1               ;Z16=3; Z15=2; Z10=1;
  VPADDD        Z15, Z15, Z20             //;D9A45253 constd_4 := 2 + 2               ;Z20=4; Z15=2;
  VMOVDQU32     CONST_N_BYTES_UTF8(),Z18  //;B323211A load table_n_bytes_utf8         ;Z18=table_n_bytes_utf8;
//; init variables
  KMOVW         K1,  K2                   //;AE3AAD43 lane_todo := lane_active        ;K2=lane_todo; K1=lane_active;
  KXORW         K1,  K1,  K1              //;FA91A63F lane_active := 0                ;K1=lane_active;
  VMOVDQA32     Z10, Z7                   //;77B17C9A start_state is state 1          ;Z7=curr_state; Z10=1;
main_loop:
  VPXORD        Z6,  Z6,  Z6              //;7B026700 rlz_state := 0                  ;Z6=rlz_state;
  KMOVW         K2,  K3                   //;81412269 copy eligible lanes             ;K3=scratch; K2=lane_todo;
  VPXORD        Z8,  Z8,  Z8              //;220F8650 clear stale non-ASCII content   ;Z8=data_msg;
  VPGATHERDD    (SI)(Z2*1),K3,  Z8        //;E4967C89 gather data                     ;Z8=data_msg; K3=scratch; SI=msg_ptr; Z2=str_start;
  VPMOVB2M      Z8,  K5                   //;385A4763 extract non-ASCII mask          ;K5=lane_non-ASCII; Z8=data_msg;
//; determine whether a lane has a non-ASCII code-point
  VPMOVM2B      K5,  Z12                  //;96C10C0D promote 64x bit to 64x byte     ;Z12=scratch_Z12; K5=lane_non-ASCII;
  VPCMPD        $4,  Z12, Z11, K2,  K3    //;92DE265B K3 := K2 & (0!=scratch_Z12); extract lanes with non-ASCII code-points;K3=scratch; K2=lane_todo; Z11=0; Z12=scratch_Z12; 4=NotEqual;
  KTESTW        K6,  K3                   //;BCE8C4F2 feature enabled and non-ASCII present?;K3=scratch; K6=enabled_flag;
  JNZ           skip_wildcard             //;10BF1BFB jump if not zero (ZF = 0)       ;
//; get char-groups
  VPERMI2B      Z22, Z21, Z8              //;872E1226 map data to char_group          ;Z8=data_msg; Z21=char_table1; Z22=char_table2;
  VMOVDQU8      Z11, K5,  Z8              //;2BDE3FA8 set non-ASCII to zero group     ;Z8=data_msg; K5=lane_non-ASCII; Z11=0;
//; handle 1st ASCII in data
  VPCMPD        $5,  Z10, Z3,  K4         //;89485A8A K4 := (str_len>=1)              ;K4=char_valid; Z3=str_len; Z10=1; 5=GreaterEq;
  VPCMPD        $0,  Z10, Z3,  K5         //;A23A5A84 K5 := (str_len==1)              ;K5=lane_non-ASCII; Z3=str_len; Z10=1; 0=Eq;
  VPORD         Z8,  Z7,  Z9              //;C09CA74A merge char_group with curr_state into lookup_key;Z9=next_state; Z7=curr_state; Z8=data_msg;
  VPERMI2B      Z24, Z23, Z9              //;F0A7B6B3 map lookup_key to next_state    ;Z9=next_state; Z23=trans_table1; Z24=trans_table2;
  VMOVDQA32     Z9,  K4,  Z7              //;F3DF61B6 curr_state := next_state        ;Z7=curr_state; K4=char_valid; Z9=next_state;
  VMOVDQA32     Z9,  K5,  Z6              //;8EFED6E5 rlz_state := next_state         ;Z6=rlz_state; K5=lane_non-ASCII; Z9=next_state;
//; handle 2nd ASCII in data
  VPSRLD        $8,  Z8,  Z8              //;838875D4 data_msg >>= 8                  ;Z8=data_msg;
  VPCMPD        $5,  Z15, Z3,  K4         //;12B1EB36 K4 := (str_len>=2)              ;K4=char_valid; Z3=str_len; Z15=2; 5=GreaterEq;
  VPCMPD        $0,  Z15, Z3,  K5         //;47BF9EE9 K5 := (str_len==2)              ;K5=lane_non-ASCII; Z3=str_len; Z15=2; 0=Eq;
  VPORD         Z8,  Z7,  Z9              //;C09CA74A merge char_group with curr_state into lookup_key;Z9=next_state; Z7=curr_state; Z8=data_msg;
  VPERMI2B      Z24, Z23, Z9              //;F0A7B6B3 map lookup_key to next_state    ;Z9=next_state; Z23=trans_table1; Z24=trans_table2;
  VMOVDQA32     Z9,  K4,  Z7              //;F3DF61B6 curr_state := next_state        ;Z7=curr_state; K4=char_valid; Z9=next_state;
  VMOVDQA32     Z9,  K5,  Z6              //;8EFED6E5 rlz_state := next_state         ;Z6=rlz_state; K5=lane_non-ASCII; Z9=next_state;
//; handle 3rd ASCII in data
  VPSRLD        $8,  Z8,  Z8              //;838875D4 data_msg >>= 8                  ;Z8=data_msg;
  VPCMPD        $5,  Z16, Z3,  K4         //;6E26712A K4 := (str_len>=3)              ;K4=char_valid; Z3=str_len; Z16=3; 5=GreaterEq;
  VPCMPD        $0,  Z16, Z3,  K5         //;91BAEA96 K5 := (str_len==3)              ;K5=lane_non-ASCII; Z3=str_len; Z16=3; 0=Eq;
  VPORD         Z8,  Z7,  Z9              //;C09CA74A merge char_group with curr_state into lookup_key;Z9=next_state; Z7=curr_state; Z8=data_msg;
  VPERMI2B      Z24, Z23, Z9              //;F0A7B6B3 map lookup_key to next_state    ;Z9=next_state; Z23=trans_table1; Z24=trans_table2;
  VMOVDQA32     Z9,  K4,  Z7              //;F3DF61B6 curr_state := next_state        ;Z7=curr_state; K4=char_valid; Z9=next_state;
  VMOVDQA32     Z9,  K5,  Z6              //;8EFED6E5 rlz_state := next_state         ;Z6=rlz_state; K5=lane_non-ASCII; Z9=next_state;
//; handle 4th ASCII in data
  VPSRLD        $8,  Z8,  Z8              //;838875D4 data_msg >>= 8                  ;Z8=data_msg;
  VPCMPD        $5,  Z20, Z3,  K4         //;CFBDCA00 K4 := (str_len>=4)              ;K4=char_valid; Z3=str_len; Z20=4; 5=GreaterEq;
  VPCMPD        $0,  Z20, Z3,  K5         //;2154FFD7 K5 := (str_len==4)              ;K5=lane_non-ASCII; Z3=str_len; Z20=4; 0=Eq;
  VPORD         Z8,  Z7,  Z9              //;C09CA74A merge char_group with curr_state into lookup_key;Z9=next_state; Z7=curr_state; Z8=data_msg;
  VPERMI2B      Z24, Z23, Z9              //;F0A7B6B3 map lookup_key to next_state    ;Z9=next_state; Z23=trans_table1; Z24=trans_table2;
  VMOVDQA32     Z9,  K4,  Z7              //;F3DF61B6 curr_state := next_state        ;Z7=curr_state; K4=char_valid; Z9=next_state;
  VMOVDQA32     Z9,  K5,  Z6              //;8EFED6E5 rlz_state := next_state         ;Z6=rlz_state; K5=lane_non-ASCII; Z9=next_state;
//; advance 4 bytes (= 4 code-points)
  VPADDD        Z20, Z2,  Z2              //;F381FC8B str_start += 4                  ;Z2=str_start; Z20=4;
  VPSUBD        Z20, Z3,  Z3              //;D71AFBB0 str_len -= 4                    ;Z3=str_len; Z20=4;
tail:
  VPCMPD        $0,  Z7,  Z13, K2,  K3    //;9A003B95 K3 := K2 & (accept_state==curr_state);K3=scratch; K2=lane_todo; Z13=accept_state; Z7=curr_state; 0=Eq;
  VPERMB        Z14, Z6,  Z12             //;F1661DA9 map RLZ states to 0xFF          ;Z12=scratch_Z12; Z6=rlz_state; Z14=rlz_states;
  VPSLLD.Z      $24, Z12, K2,  Z12        //;7352EFC4 scratch_Z12 <<= 24              ;Z12=scratch_Z12; K2=lane_todo;
  VPMOVD2M      Z12, K4                   //;6832FF1A extract RLZ mask                ;K4=char_valid; Z12=scratch_Z12;
  VPCMPD        $4,  Z7,  Z11, K2,  K2    //;C4336141 K2 &= (0!=curr_state)           ;K2=lane_todo; Z11=0; Z7=curr_state; 4=NotEqual;
  VPCMPD        $1,  Z3,  Z11, K2,  K2    //;250BE13C K2 &= (0<str_len)               ;K2=lane_todo; Z11=0; Z3=str_len; 1=LessThen;
  KORW          K3,  K4,  K3              //;24142563 scratch |= char_valid           ;K3=scratch; K4=char_valid;
  KANDNW        K2,  K3,  K2              //;C9EB9B00 lane_todo &= ~scratch           ;K2=lane_todo; K3=scratch;
  KORW          K1,  K3,  K1              //;63AD07E8 lane_active |= scratch          ;K1=lane_active; K3=scratch;
  KTESTW        K2,  K2                   //;3D96F6AD any lane still todo?            ;K2=lane_todo;
  JNZ           main_loop                 //;274B80A2 jump if not zero (ZF = 0)       ;
next:
  NEXT()

skip_wildcard:
//; instead of advancing 4 bytes we advance 1 code-point, and set all non-ascii code-points to the wildcard group
  VPSRLD        $4,  Z8,  Z12             //;FE5F1413 scratch_Z12 := data_msg>>4      ;Z12=scratch_Z12; Z8=data_msg;
  VPERMD        Z18, Z12, Z12             //;68FECBA0 get scratch_Z12                 ;Z12=scratch_Z12; Z18=table_n_bytes_utf8;
//; get char-groups
  VPCMPD        $4,  Z12, Z10, K2,  K3    //;411A6A38 K3 := K2 & (1!=scratch_Z12)     ;K3=scratch; K2=lane_todo; Z10=1; Z12=scratch_Z12; 4=NotEqual;
  VPERMI2B      Z22, Z21, Z8              //;285E91E6 map data to char_group          ;Z8=data_msg; Z21=char_table1; Z22=char_table2;
  VMOVDQA32     Z5,  K3,  Z8              //;D9B3425A set non-ASCII to wildcard group ;Z8=data_msg; K3=scratch; Z5=wildcard;
//; advance 1 code-point
  VPSUBD        Z12, Z3,  Z3              //;8575652C str_len -= scratch_Z12          ;Z3=str_len; Z12=scratch_Z12;
  VPADDD        Z12, Z2,  Z2              //;A7D2A209 str_start += scratch_Z12        ;Z2=str_start; Z12=scratch_Z12;
//; handle 1st code-point in data
  VPCMPD        $5,  Z11, Z3,  K4         //;7C3C9240 K4 := (str_len>=0)              ;K4=char_valid; Z3=str_len; Z11=0; 5=GreaterEq;
  VPCMPD        $0,  Z11, Z3,  K5         //;6843E9F0 K5 := (str_len==0)              ;K5=lane_non-ASCII; Z3=str_len; Z11=0; 0=Eq;
  VPORD         Z8,  Z7,  Z9              //;C09CA74A merge char_group with curr_state into lookup_key;Z9=next_state; Z7=curr_state; Z8=data_msg;
  VPERMI2B      Z24, Z23, Z9              //;F0A7B6B3 map lookup_key to next_state    ;Z9=next_state; Z23=trans_table1; Z24=trans_table2;
  VMOVDQA32     Z9,  K4,  Z7              //;F3DF61B6 curr_state := next_state        ;Z7=curr_state; K4=char_valid; Z9=next_state;
  VMOVDQA32     Z9,  K5,  Z6              //;8EFED6E5 rlz_state := next_state         ;Z6=rlz_state; K5=lane_non-ASCII; Z9=next_state;
  JMP           tail                      //;E21E4B3D                                 ;
//; #endregion bcDfaT7Z

//; #region bcDfaT8Z
//; DfaT8Z Deterministic Finite Automaton 8-bits with Zero length remaining assertion
TEXT bcDfaT8Z(SB), NOSPLIT|NOFRAME, $0
  IMM_FROM_DICT(R14)                      //;05667C35 load *[]byte with the provided str into R14
  MOVQ          (R14),R14                 //;D2647DF0 load needle_ptr                 ;R14=needle_ptr; R14=needle_slice;
//; load parameters
  VMOVDQU32     (R14),Z21                 //;CAEE2FF0 char_table1 := [needle_ptr]     ;Z21=char_table1; R14=needle_ptr;
  VMOVDQU32     64(R14),Z22               //;E0639585 char_table2 := [needle_ptr+64]  ;Z22=char_table2; R14=needle_ptr;
  VMOVDQU32     128(R14),Z23              //;15D38369 trans_table1 := [needle_ptr+128];Z23=trans_table1; R14=needle_ptr;
  VMOVDQU32     192(R14),Z24              //;5DE9259D trans_table2 := [needle_ptr+192];Z24=trans_table2; R14=needle_ptr;
  VMOVDQU32     256(R14),Z25              //;BE3AEA52 trans_table3 := [needle_ptr+256];Z25=trans_table3; R14=needle_ptr;
  VMOVDQU32     320(R14),Z26              //;C346A0C9 trans_table4 := [needle_ptr+320];Z26=trans_table4; R14=needle_ptr;
  KMOVW         384(R14),K6               //;2C9E73B8 load wildcard enabled flag      ;K6=enabled_flag; R14=needle_ptr;
  VPBROADCASTD  386(R14),Z5               //;803E3CDF load wildcard char-group        ;Z5=wildcard; R14=needle_ptr;
  VPBROADCASTD  390(R14),Z13              //;E6CE5A10 load accept state               ;Z13=accept_state; R14=needle_ptr;
  KMOVQ         394(R14),K3               //;B925FEF8 load RLZ states                 ;K3=scratch; R14=needle_ptr;
  VPMOVM2B      K3,  Z14                  //;40FAB4CE promote 64x bit to 64x byte     ;Z14=rlz_states; K3=scratch;
//; load constants
  VPXORD        Z11, Z11, Z11             //;81C90120 load constant 0                 ;Z11=0;
  VPBROADCASTD  CONSTD_1(),Z10            //;6F57EE92 load constant 1                 ;Z10=1;
  VPADDD        Z10, Z10, Z15             //;92620230 constd_2 := 1 + 1               ;Z15=2; Z10=1;
  VPADDD        Z10, Z15, Z16             //;45FD27E2 constd_3 := 2 + 1               ;Z16=3; Z15=2; Z10=1;
  VPADDD        Z15, Z15, Z20             //;D9A45253 constd_4 := 2 + 2               ;Z20=4; Z15=2;
  VMOVDQU32     CONST_N_BYTES_UTF8(),Z18  //;B323211A load table_n_bytes_utf8         ;Z18=table_n_bytes_utf8;
//; init variables
  KMOVW         K1,  K2                   //;AE3AAD43 lane_todo := lane_active        ;K2=lane_todo; K1=lane_active;
  KXORW         K1,  K1,  K1              //;FA91A63F lane_active := 0                ;K1=lane_active;
  VMOVDQA32     Z10, Z7                   //;77B17C9A start_state is state 1          ;Z7=curr_state; Z10=1;
main_loop:
  VPXORD        Z6,  Z6,  Z6              //;7B026700 rlz_state := 0                  ;Z6=rlz_state;
  KMOVW         K2,  K3                   //;81412269 copy eligible lanes             ;K3=scratch; K2=lane_todo;
  VPXORD        Z8,  Z8,  Z8              //;220F8650 clear stale non-ASCII content   ;Z8=data_msg;
  VPGATHERDD    (SI)(Z2*1),K3,  Z8        //;E4967C89 gather data                     ;Z8=data_msg; K3=scratch; SI=msg_ptr; Z2=str_start;
  VPMOVB2M      Z8,  K5                   //;385A4763 extract non-ASCII mask          ;K5=lane_non-ASCII; Z8=data_msg;
//; determine whether a lane has a non-ASCII code-point
  VPMOVM2B      K5,  Z12                  //;96C10C0D promote 64x bit to 64x byte     ;Z12=scratch_Z12; K5=lane_non-ASCII;
  VPCMPD        $4,  Z12, Z11, K2,  K3    //;92DE265B K3 := K2 & (0!=scratch_Z12); extract lanes with non-ASCII code-points;K3=scratch; K2=lane_todo; Z11=0; Z12=scratch_Z12; 4=NotEqual;
  KTESTW        K6,  K3                   //;BCE8C4F2 feature enabled and non-ASCII present?;K3=scratch; K6=enabled_flag;
  JNZ           skip_wildcard             //;10BF1BFB jump if not zero (ZF = 0)       ;
//; get char-groups
  VPERMI2B      Z22, Z21, Z8              //;872E1226 map data to char_group          ;Z8=data_msg; Z21=char_table1; Z22=char_table2;
  VMOVDQU8      Z11, K5,  Z8              //;2BDE3FA8 set non-ASCII to zero group     ;Z8=data_msg; K5=lane_non-ASCII; Z11=0;
//; handle 1st ASCII in data
  VPCMPD        $5,  Z10, Z3,  K4         //;89485A8A K4 := (str_len>=1)              ;K4=char_valid; Z3=str_len; Z10=1; 5=GreaterEq;
  VPCMPD        $0,  Z10, Z3,  K5         //;A23A5A84 K5 := (str_len==1)              ;K5=lane_non-ASCII; Z3=str_len; Z10=1; 0=Eq;
  VPORD         Z8,  Z7,  Z9              //;C09CA74A merge char_group with curr_state into lookup_key;Z9=next_state; Z7=curr_state; Z8=data_msg;
  VPMOVB2M      Z9,  K3                   //;5ABFD6B8 extract sign for merging        ;K3=scratch; Z9=next_state;
  VMOVDQA32     Z9,  Z17                  //;9B3CF590 alt2_lut8 := next_state         ;Z17=alt2_lut8; Z9=next_state;
  VPERMI2B      Z26, Z25, Z9              //;53BE6E94 map lookup_key to next_state    ;Z9=next_state; Z25=trans_table3; Z26=trans_table4;
  VPERMI2B      Z24, Z23, Z17             //;C82BB72B map lookup_key to next_state    ;Z17=alt2_lut8; Z23=trans_table1; Z24=trans_table2;
  VMOVDQU8      Z9,  K3,  Z17             //;86B7DFF1 alt2_lut8 := next_state         ;Z17=alt2_lut8; K3=scratch; Z9=next_state;
  VMOVDQA32     Z17, K4,  Z7              //;F9049BA0 curr_state := alt2_lut8         ;Z7=curr_state; K4=char_valid; Z17=alt2_lut8;
  VMOVDQA32     Z17, K5,  Z6              //;948A0E75 rlz_state := alt2_lut8          ;Z6=rlz_state; K5=lane_non-ASCII; Z17=alt2_lut8;
//; handle 2nd ASCII in data
  VPSRLD        $8,  Z8,  Z8              //;838875D4 data_msg >>= 8                  ;Z8=data_msg;
  VPCMPD        $5,  Z15, Z3,  K4         //;12B1EB36 K4 := (str_len>=2)              ;K4=char_valid; Z3=str_len; Z15=2; 5=GreaterEq;
  VPCMPD        $0,  Z15, Z3,  K5         //;47BF9EE9 K5 := (str_len==2)              ;K5=lane_non-ASCII; Z3=str_len; Z15=2; 0=Eq;
  VPORD         Z8,  Z7,  Z9              //;C09CA74A merge char_group with curr_state into lookup_key;Z9=next_state; Z7=curr_state; Z8=data_msg;
  VPMOVB2M      Z9,  K3                   //;5ABFD6B8 extract sign for merging        ;K3=scratch; Z9=next_state;
  VMOVDQA32     Z9,  Z17                  //;9B3CF590 alt2_lut8 := next_state         ;Z17=alt2_lut8; Z9=next_state;
  VPERMI2B      Z26, Z25, Z9              //;53BE6E94 map lookup_key to next_state    ;Z9=next_state; Z25=trans_table3; Z26=trans_table4;
  VPERMI2B      Z24, Z23, Z17             //;C82BB72B map lookup_key to next_state    ;Z17=alt2_lut8; Z23=trans_table1; Z24=trans_table2;
  VMOVDQU8      Z9,  K3,  Z17             //;86B7DFF1 alt2_lut8 := next_state         ;Z17=alt2_lut8; K3=scratch; Z9=next_state;
  VMOVDQA32     Z17, K4,  Z7              //;F9049BA0 curr_state := alt2_lut8         ;Z7=curr_state; K4=char_valid; Z17=alt2_lut8;
  VMOVDQA32     Z17, K5,  Z6              //;948A0E75 rlz_state := alt2_lut8          ;Z6=rlz_state; K5=lane_non-ASCII; Z17=alt2_lut8;
//; handle 3rd ASCII in data
  VPSRLD        $8,  Z8,  Z8              //;838875D4 data_msg >>= 8                  ;Z8=data_msg;
  VPCMPD        $5,  Z16, Z3,  K4         //;6E26712A K4 := (str_len>=3)              ;K4=char_valid; Z3=str_len; Z16=3; 5=GreaterEq;
  VPCMPD        $0,  Z16, Z3,  K5         //;2154FFD7 K5 := (str_len==3)              ;K5=lane_non-ASCII; Z3=str_len; Z16=3; 0=Eq;
  VPORD         Z8,  Z7,  Z9              //;C09CA74A merge char_group with curr_state into lookup_key;Z9=next_state; Z7=curr_state; Z8=data_msg;
  VPMOVB2M      Z9,  K3                   //;5ABFD6B8 extract sign for merging        ;K3=scratch; Z9=next_state;
  VMOVDQA32     Z9,  Z17                  //;9B3CF590 alt2_lut8 := next_state         ;Z17=alt2_lut8; Z9=next_state;
  VPERMI2B      Z26, Z25, Z9              //;53BE6E94 map lookup_key to next_state    ;Z9=next_state; Z25=trans_table3; Z26=trans_table4;
  VPERMI2B      Z24, Z23, Z17             //;C82BB72B map lookup_key to next_state    ;Z17=alt2_lut8; Z23=trans_table1; Z24=trans_table2;
  VMOVDQU8      Z9,  K3,  Z17             //;86B7DFF1 alt2_lut8 := next_state         ;Z17=alt2_lut8; K3=scratch; Z9=next_state;
  VMOVDQA32     Z17, K4,  Z7              //;F9049BA0 curr_state := alt2_lut8         ;Z7=curr_state; K4=char_valid; Z17=alt2_lut8;
  VMOVDQA32     Z17, K5,  Z6              //;948A0E75 rlz_state := alt2_lut8          ;Z6=rlz_state; K5=lane_non-ASCII; Z17=alt2_lut8;
//; handle 4th ASCII in data
  VPSRLD        $8,  Z8,  Z8              //;838875D4 data_msg >>= 8                  ;Z8=data_msg;
  VPCMPD        $5,  Z20, Z3,  K4         //;CFBDCA00 K4 := (str_len>=4)              ;K4=char_valid; Z3=str_len; Z20=4; 5=GreaterEq;
  VPCMPD        $0,  Z20, Z3,  K5         //;95E6ECB7 K5 := (str_len==4)              ;K5=lane_non-ASCII; Z3=str_len; Z20=4; 0=Eq;
  VPORD         Z8,  Z7,  Z9              //;C09CA74A merge char_group with curr_state into lookup_key;Z9=next_state; Z7=curr_state; Z8=data_msg;
  VPMOVB2M      Z9,  K3                   //;5ABFD6B8 extract sign for merging        ;K3=scratch; Z9=next_state;
  VMOVDQA32     Z9,  Z17                  //;9B3CF590 alt2_lut8 := next_state         ;Z17=alt2_lut8; Z9=next_state;
  VPERMI2B      Z26, Z25, Z9              //;53BE6E94 map lookup_key to next_state    ;Z9=next_state; Z25=trans_table3; Z26=trans_table4;
  VPERMI2B      Z24, Z23, Z17             //;C82BB72B map lookup_key to next_state    ;Z17=alt2_lut8; Z23=trans_table1; Z24=trans_table2;
  VMOVDQU8      Z9,  K3,  Z17             //;86B7DFF1 alt2_lut8 := next_state         ;Z17=alt2_lut8; K3=scratch; Z9=next_state;
  VMOVDQA32     Z17, K4,  Z7              //;F9049BA0 curr_state := alt2_lut8         ;Z7=curr_state; K4=char_valid; Z17=alt2_lut8;
  VMOVDQA32     Z17, K5,  Z6              //;948A0E75 rlz_state := alt2_lut8          ;Z6=rlz_state; K5=lane_non-ASCII; Z17=alt2_lut8;
//; advance 4 bytes (= 4 code-points)
  VPADDD        Z20, Z2,  Z2              //;F381FC8B str_start += 4                  ;Z2=str_start; Z20=4;
  VPSUBD        Z20, Z3,  Z3              //;D71AFBB0 str_len -= 4                    ;Z3=str_len; Z20=4;
tail:
  VPCMPD        $0,  Z7,  Z13, K2,  K3    //;9A003B95 K3 := K2 & (accept_state==curr_state);K3=scratch; K2=lane_todo; Z13=accept_state; Z7=curr_state; 0=Eq;
  VPERMB        Z14, Z6,  Z12             //;F1661DA9 map RLZ states to 0xFF          ;Z12=scratch_Z12; Z6=rlz_state; Z14=rlz_states;
  VPSLLD.Z      $24, Z12, K2,  Z12        //;7352EFC4 scratch_Z12 <<= 24              ;Z12=scratch_Z12; K2=lane_todo;
  VPMOVD2M      Z12, K4                   //;6832FF1A extract RLZ mask                ;K4=char_valid; Z12=scratch_Z12;
  VPCMPD        $4,  Z7,  Z11, K2,  K2    //;C4336141 K2 &= (0!=curr_state)           ;K2=lane_todo; Z11=0; Z7=curr_state; 4=NotEqual;
  VPCMPD        $1,  Z3,  Z11, K2,  K2    //;250BE13C K2 &= (0<str_len)               ;K2=lane_todo; Z11=0; Z3=str_len; 1=LessThen;
  KORW          K3,  K4,  K3              //;24142563 scratch |= char_valid           ;K3=scratch; K4=char_valid;
  KANDNW        K2,  K3,  K2              //;C9EB9B00 lane_todo &= ~scratch           ;K2=lane_todo; K3=scratch;
  KORW          K1,  K3,  K1              //;63AD07E8 lane_active |= scratch          ;K1=lane_active; K3=scratch;
  KTESTW        K2,  K2                   //;3D96F6AD any lane still todo?            ;K2=lane_todo;
  JNZ           main_loop                 //;274B80A2 jump if not zero (ZF = 0)       ;
next:
  NEXT()

skip_wildcard:
//; instead of advancing 4 bytes we advance 1 code-point, and set all non-ascii code-points to the wildcard group
  VPSRLD        $4,  Z8,  Z12             //;FE5F1413 scratch_Z12 := data_msg>>4      ;Z12=scratch_Z12; Z8=data_msg;
  VPERMD        Z18, Z12, Z12             //;68FECBA0 get scratch_Z12                 ;Z12=scratch_Z12; Z18=table_n_bytes_utf8;
//; get char-groups
  VPCMPD        $4,  Z12, Z10, K2,  K3    //;411A6A38 K3 := K2 & (1!=scratch_Z12)     ;K3=scratch; K2=lane_todo; Z10=1; Z12=scratch_Z12; 4=NotEqual;
  VPERMI2B      Z22, Z21, Z8              //;285E91E6 map data to char_group          ;Z8=data_msg; Z21=char_table1; Z22=char_table2;
  VMOVDQA32     Z5,  K3,  Z8              //;D9B3425A set non-ASCII to wildcard group ;Z8=data_msg; K3=scratch; Z5=wildcard;
//; advance 1 code-point
  VPSUBD        Z12, Z3,  Z3              //;8575652C str_len -= scratch_Z12          ;Z3=str_len; Z12=scratch_Z12;
  VPADDD        Z12, Z2,  Z2              //;A7D2A209 str_start += scratch_Z12        ;Z2=str_start; Z12=scratch_Z12;
//; handle 1st code-point in data
  VPCMPD        $5,  Z11, Z3,  K4         //;A17DDD33 K4 := (str_len>=0)              ;K4=char_valid; Z3=str_len; Z11=0; 5=GreaterEq;
  VPCMPD        $0,  Z11, Z3,  K5         //;9AA6077F K5 := (str_len==0)              ;K5=lane_non-ASCII; Z3=str_len; Z11=0; 0=Eq;
  VPORD         Z8,  Z7,  Z9              //;C09CA74A merge char_group with curr_state into lookup_key;Z9=next_state; Z7=curr_state; Z8=data_msg;
  VPMOVB2M      Z9,  K3                   //;5ABFD6B8 extract sign for merging        ;K3=scratch; Z9=next_state;
  VMOVDQA32     Z9,  Z17                  //;9B3CF590 alt2_lut8 := next_state         ;Z17=alt2_lut8; Z9=next_state;
  VPERMI2B      Z26, Z25, Z9              //;53BE6E94 map lookup_key to next_state    ;Z9=next_state; Z25=trans_table3; Z26=trans_table4;
  VPERMI2B      Z24, Z23, Z17             //;C82BB72B map lookup_key to next_state    ;Z17=alt2_lut8; Z23=trans_table1; Z24=trans_table2;
  VMOVDQU8      Z9,  K3,  Z17             //;86B7DFF1 alt2_lut8 := next_state         ;Z17=alt2_lut8; K3=scratch; Z9=next_state;
  VMOVDQA32     Z17, K4,  Z7              //;F9049BA0 curr_state := alt2_lut8         ;Z7=curr_state; K4=char_valid; Z17=alt2_lut8;
  VMOVDQA32     Z17, K5,  Z6              //;948A0E75 rlz_state := alt2_lut8          ;Z6=rlz_state; K5=lane_non-ASCII; Z17=alt2_lut8;
  JMP           tail                      //;E21E4B3D                                 ;
//; #endregion bcDfaT8Z

//; #region bcDfaLZ
//; DfaLZ Deterministic Finite Automaton(DFA) with unlimited capacity (Large) and Remaining Length Zero Assertion (RLZA)
TEXT bcDfaLZ(SB), NOSPLIT|NOFRAME, $0
  IMM_FROM_DICT(R14)                      //;05667C35 load *[]byte with the provided str into R14
  MOVQ          (R14),R14                 //;D2647DF0 load needle_ptr                 ;R14=needle_ptr; R14=needle_slice;
//; load parameters
  MOVL          (R14),R8                  //;6AD2EA95 load n_states                   ;R8=n_states; R14=needle_ptr;
  ADDQ          $4,  R14                  //;3259F7B2 init state_offset               ;R14=needle_ptr;
//; test for special situation with DFA ->s0 -$> s1
  MOVL          R8,  R15                  //;97339D56 scratch := n_states             ;R15=scratch; R8=n_states;
  INCL          R15                       //;91D62E05 scratch++                       ;R15=scratch;
  JNZ           normal_operation          //;19338985 if result==0, then special situation; jump if not zero (ZF = 0);
  VPTESTNMD     Z3,  Z3,  K1,  K1         //;29B38DE0 K1 &= (str_len==0)              ;K1=lane_active; Z3=str_len;
  JMP           next                      //;E5E69BC1                                 ;
normal_operation:
//; test if start state is accepting
  TESTL         R8,  R8                   //;637F12FC are there more than 0 states?   ;R8=n_states;
  JLE           next                      //;AEE3942A no, then there is only an accept state; jump if less or equal ((ZF = 1) or (SF neq OF));
//; load constants
  VMOVDQU32     CONST_TAIL_MASK(),Z18     //;7DB21CB0 load tail_mask_data             ;Z18=tail_mask_data;
  VMOVDQU32     CONST_N_BYTES_UTF8(),Z21  //;B323211A load table_n_bytes_utf8         ;Z21=table_n_bytes_utf8;
  VPXORD        Z11, Z11, Z11             //;81C90120 load constant 0                 ;Z11=0;
  VPBROADCASTD  CONSTD_1(),Z10            //;6F57EE92 load constant 1                 ;Z10=1;
  VPBROADCASTD  CONSTD_4(),Z20            //;C8AFBE50 load constant 4                 ;Z20=4;
  VPBROADCASTD  CONSTD_0x3FFFFFFF(),Z17   //;EF9E72D4 load flags_mask                 ;Z17=flags_mask;
  VMOVDQU32     bswap32<>(SB),Z12         //;A0BC360A load constant bswap32           ;Z12=bswap32;
//; init variables before main loop
  VPCMPD        $1,  Z3,  Z11, K1,  K2    //;95727519 K2 := K1 & (0<str_len)          ;K2=lane_todo; K1=lane_active; Z11=0; Z3=str_len; 1=LessThen;
  KXORW         K1,  K1,  K1              //;C1A15D64 lane_active := 0                ;K1=lane_active;
  VMOVDQA32     Z10, Z7                   //;77B17C9A curr_state := 1                 ;Z7=curr_state; Z10=1;
main_loop:
  KMOVW         K2,  K3                   //;81412269 copy eligible lanes             ;K3=scratch; K2=lane_todo;
  VPGATHERDD    (SI)(Z2*1),K3,  Z8        //;E4967C89 gather data                     ;Z8=data_msg; K3=scratch; SI=msg_ptr; Z2=str_start;
//; init variables before states loop
  VPXORD        Z6,  Z6,  Z6              //;E4D2E400 next_state := 0                 ;Z6=next_state;
  VMOVDQA32     Z10, Z5                   //;A30F50D2 state_id := 1                   ;Z5=state_id; Z10=1;
  MOVL          R8,  CX                   //;B08178D1 init state_counter              ;CX=state_counter; R8=n_states;
  MOVQ          R14, R13                  //;F0D423D2 init state_offset               ;R13=state_offset; R14=needle_ptr;
//; get number of bytes in code-point
  VPSRLD        $4,  Z8,  Z26             //;FE5F1413 scratch_Z26 := data_msg>>4      ;Z26=scratch_Z26; Z8=data_msg;
  VPERMD        Z21, Z26, Z22             //;68FECBA0 get n_bytes_data                ;Z22=n_bytes_data; Z26=scratch_Z26; Z21=table_n_bytes_utf8;
//; remove tail from data
  VPERMD        Z18, Z22, Z19             //;E5886CFE get tail_mask (data)            ;Z19=tail_mask; Z22=n_bytes_data; Z18=tail_mask_data;
  VPANDD.Z      Z8,  Z19, K2,  Z8         //;BF3EB085 mask data                       ;Z8=data_msg; K2=lane_todo; Z19=tail_mask;
//; transform data such that we can compare
  VPSHUFB       Z12, Z8,  Z8              //;964815FF toggle endiannes                ;Z8=data_msg; Z12=bswap32;
  VPSUBD        Z22, Z20, Z26             //;43F001E9 scratch_Z26 := 4 - n_bytes_data ;Z26=scratch_Z26; Z20=4; Z22=n_bytes_data;
  VPSLLD        $3,  Z26, Z26             //;22D27D9F scratch_Z26 <<= 3               ;Z26=scratch_Z26;
  VPSRLVD       Z26, Z8,  Z8              //;C0B21528 data_msg >>= scratch_Z26        ;Z8=data_msg; Z26=scratch_Z26;
//; advance one code-point
  VPSUBD        Z22, Z3,  Z3              //;CB5D370F str_len -= n_bytes_data         ;Z3=str_len; Z22=n_bytes_data;
  VPADDD        Z22, Z2,  Z2              //;DEE2A990 str_start += n_bytes_data       ;Z2=str_start; Z22=n_bytes_data;
loop_states:
  VPCMPD        $0,  Z7,  Z5,  K2,  K4    //;F998800A K4 := K2 & (state_id==curr_state);K4=state_matched; K2=lane_todo; Z5=state_id; Z7=curr_state; 0=Eq;
  VPADDD        Z5,  Z10, Z5              //;ED016003 state_id++                      ;Z5=state_id; Z10=1;
  KTESTW        K4,  K4                   //;43122CE8 did any states match?           ;K4=state_matched;
  JZ            skip_edges                //;6DE8E146 no, skip the loop with edges; jump if zero (ZF = 1);
  MOVL          4(R13),DX                 //;CA7C9CE3 load number of edges            ;DX=edge_counter; R13=state_offset;
  ADDQ          $8,  R13                  //;729CC51F state_offset += 8               ;R13=state_offset;
loop_edges:
  VPCMPUD.BCST  $5,  (R13),Z8,  K4,  K3   //;510F046E K3 := K4 & (data_msg>=[state_offset]);K3=trans_matched; K4=state_matched; Z8=data_msg; R13=state_offset; 5=GreaterEq;
  VPCMPUD.BCST  $2,  4(R13),Z8,  K3,  K3  //;59D7E2CF K3 &= (data_msg<=[state_offset+4]);K3=scratch; Z8=data_msg; R13=state_offset; 2=LessEq;
  VPBROADCASTD  8(R13),K3,  Z6            //;789252A5 update next_state               ;Z6=next_state; K3=trans_matched; R13=state_offset;
  ADDQ          $12, R13                  //;9997E3C9 state_offset += 12              ;R13=state_offset;
  DECL          DX                        //;F5ED8DBE edge_counter--                  ;DX=edge_counter;
  JNZ           loop_edges                //;314C4D30 jump if not zero (ZF = 0)       ;
  JMP           loop_edges_done           //;D662BEEB                                 ;
skip_edges:
  MOVL          (R13),DX                  //;33839A60 load total bytes of edges       ;DX=edge_counter; R13=state_offset;
  ADDQ          DX,  R13                  //;2E22DACA state_offset += edge_counter    ;R13=state_offset; DX=edge_counter;
loop_edges_done:
  DECL          CX                        //;D33A44D5 state_counter--                 ;CX=state_counter;
  JNZ           loop_states               //;CFB42829 jump if not zero (ZF = 0)       ;

//; test the RLZ condition
  VPMOVD2M      Z6,  K3                   //;E2246D80 retrieve RLZ bit                ;K3=scratch; Z6=next_state;
  VPCMPD        $0,  Z3,  Z11, K3,  K5    //;CF75D163 K5 := K3 & (0==str_len)         ;K5=rlz_condition; K3=scratch; Z11=0; Z3=str_len; 0=Eq;
//; test accept contition
  VPSLLD        $1,  Z6,  Z26             //;185F151B shift accept-bit into most sig pos;Z26=scratch_Z26; Z6=next_state;
  VPMOVD2M      Z26, K3                   //;38627E18 retrieve accept bit             ;K3=scratch; Z26=scratch_Z26;
//; update lane_todo and lane_active
  KORW          K5,  K3,  K3              //;D1E8D8B6 scratch |= rlz_condition        ;K3=scratch; K5=rlz_condition;
  KANDNW        K2,  K3,  K2              //;1C70ECDA lane_todo &= ~scratch           ;K2=lane_todo; K3=scratch;
  KORW          K1,  K3,  K1              //;E320A3B2 lane_active |= scratch          ;K1=lane_active; K3=scratch;
//; determine if there is more data to process
  VPCMPUD       $4,  Z6,  Z11, K2,  K2    //;7D6781E6 K2 &= (0!=next_state)           ;K2=lane_todo; Z11=0; Z6=next_state; 4=NotEqual;
  VPANDD        Z6,  Z17, Z7              //;17DDB755 curr_state := flags_mask & next_state;Z7=curr_state; Z17=flags_mask; Z6=next_state;
  VPCMPD        $1,  Z3,  Z11, K2,  K2    //;7668811F K2 &= (0<str_len)               ;K2=lane_todo; Z11=0; Z3=str_len; 1=LessThen;
  KTESTW        K2,  K2                   //;3D96F6AD any lane still todo?            ;K2=lane_todo;
  JNZ           main_loop                 //;274B80A2 jump if not zero (ZF = 0)       ;
next:
  NEXT()
//; #endregion bcDfaLZ

//; #endregion string methods

// LOWER/UPPER functions
// --------------------------------------------------

/*
TEXT bcslower(SB), NOSPLIT|NOFRAME, $0
TEXT bcsupper(SB), NOSPLIT|NOFRAME, $0
*/
#include "evalbc_strcase.h"

// bcsadjustsize adjusts buffer sizes before calling `bcallocstr` for LOWER/UPPER purposes.
//
// There are two reasons for that:
// 1. LOWER/UPPER writes data with VPSCATTERDD, thus we need a 4-byte padding.
// 2. There are exactly 20 cases when LOWER/UPPER would produce more
//    UTF-8 bytes than input. Fortunately, all the cases are the same:
//    a 2-byte input char is translated into a 3-byte char.
//
// Thus, in the worst case -- if all N input chars are 2-byte ones -- the
// output has N + N/2 + 4 bytes.
//
// Input/output:
// - Z2/Z3 (uint64)
TEXT bcsadjustsize(SB), NOSPLIT|NOFRAME, $0
    VPBROADCASTQ CONSTQ_4(), Z6
    VPSRLQ  $1, Z2, Z4
    VPSRLQ  $1, Z3, Z5
    VPADDQ  Z4, Z2, Z2
    VPADDQ  Z5, Z3, Z3
    VPADDQ  Z6, Z2, Z2
    VPADDQ  Z6, Z3, Z3
    NEXT()

// APPROX_COUNT_DISTINCT
// --------------------------------------------------

/*
TEXT bcaggapproxcount(SB), NOSPLIT|NOFRAME, $0
TEXT bcaggapproxcountmerge(SB), NOSPLIT|NOFRAME, $0

TEXT bcaggslotapproxcount(SB), NOSPLIT|NOFRAME, $0
TEXT bcaggslotapproxcountmerge(SB), NOSPLIT|NOFRAME, $0
*/
#include "evalbc_approxcount.h"

// this is the 'unimplemented!' op
TEXT bctrap(SB), NOSPLIT|NOFRAME, $0
  BYTE $0xCC
  RET

// chacha8 random initialization vector
DATA  chachaiv<>+0(SB)/4, $0x9722F977  // XOR'd with length for real IV
DATA  chachaiv<>+4(SB)/4, $0x3320646e
DATA  chachaiv<>+8(SB)/4, $0x79622d32
DATA  chachaiv<>+12(SB)/4, $0x6b206574
DATA  chachaiv<>+16(SB)/4, $0x058A60F5
DATA  chachaiv<>+20(SB)/4, $0xB25F6FB1
DATA  chachaiv<>+24(SB)/4, $0x1FEFA3D9
DATA  chachaiv<>+28(SB)/4, $0xB9D8F520
DATA  chachaiv<>+32(SB)/4, $0xB415DBCC
DATA  chachaiv<>+36(SB)/4, $0x34B70366
DATA  chachaiv<>+40(SB)/4, $0x3F4DBB4D
DATA  chachaiv<>+44(SB)/4, $0xCBB67392
DATA  chachaiv<>+48(SB)/4, $0x61707865
DATA  chachaiv<>+52(SB)/4, $0x143BE9F6
DATA  chachaiv<>+56(SB)/4, $0xDA97A1A8
DATA  chachaiv<>+60(SB)/4, $0x6F0E9495
GLOBL chachaiv<>(SB), RODATA|NOPTR, $64

DATA permute64+0x00(SB)/8, $0
DATA permute64+0x08(SB)/8, $2
DATA permute64+0x10(SB)/8, $4
DATA permute64+0x18(SB)/8, $6
DATA permute64+0x20(SB)/8, $1
DATA permute64+0x28(SB)/8, $3
DATA permute64+0x30(SB)/8, $5
DATA permute64+0x38(SB)/8, $7
GLOBL permute64(SB), RODATA|NOPTR, $64

// byte position to index
DATA byteidx<>+0(SB)/1, $0
DATA byteidx<>+1(SB)/1, $1
DATA byteidx<>+2(SB)/1, $2
DATA byteidx<>+3(SB)/1, $3
DATA byteidx<>+4(SB)/1, $4
DATA byteidx<>+5(SB)/1, $5
DATA byteidx<>+6(SB)/1, $6
DATA byteidx<>+7(SB)/1, $7
DATA byteidx<>+8(SB)/1, $8
DATA byteidx<>+9(SB)/1, $9
DATA byteidx<>+10(SB)/1, $10
DATA byteidx<>+11(SB)/1, $11
DATA byteidx<>+12(SB)/1, $12
DATA byteidx<>+13(SB)/1, $13
DATA byteidx<>+14(SB)/1, $14
DATA byteidx<>+15(SB)/1, $15
GLOBL byteidx<>(SB), RODATA|NOPTR, $16
