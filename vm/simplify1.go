//go:build !genrewrite

// code generated by genrewrite.go; DO NOT EDIT

package vm

import "github.com/SnellerInc/sneller/date"

func rewrite1(p *prog, v *value) (*value, bool) {
	switch v.op {
	case smergemem: /* mergemem */
		if len(v.args) == 1 {
			// (mergemem x) -> x
			if x := v.args[0]; true {
				return x, true
			}
		}
	case sand: /* and.k */
		if len(v.args) == 2 {
			// (and.k x (init)) -> x
			if x := v.args[0]; true {
				if _tmp19 := v.args[1]; _tmp19.op == sinit {
					return x, true
				}
			}
			// (and.k _ f:(false)) -> f
			if f := v.args[1]; f.op == skfalse {
				return f, true
			}
			// (and.k f:(false) _) -> f
			if f := v.args[0]; f.op == skfalse {
				return f, true
			}
			// (and.k x x) -> x
			if x := v.args[0]; true {
				if x == v.args[1] {
					return x, true
				}
			}
			// (and.k (init) x) -> x
			if _tmp20 := v.args[0]; _tmp20.op == sinit {
				if x := v.args[1]; true {
					return x, true
				}
			}
		}
	case sor: /* or.k */
		if len(v.args) == 2 {
			// (or.k t:(init) _) -> t
			if t := v.args[0]; t.op == sinit {
				return t, true
			}
			// (or.k _ t:(init)) -> t
			if t := v.args[1]; t.op == sinit {
				return t, true
			}
			// (or.k (false) x) -> x
			if _tmp21 := v.args[0]; _tmp21.op == skfalse {
				if x := v.args[1]; true {
					return x, true
				}
			}
			// (or.k x (false)) -> x
			if x := v.args[0]; true {
				if _tmp22 := v.args[1]; _tmp22.op == skfalse {
					return x, true
				}
			}
			// (or.k x x) -> x
			if x := v.args[0]; true {
				if x == v.args[1] {
					return x, true
				}
			}
		}
	case snand: /* nand.k */
		if len(v.args) == 2 {
			// (nand.k t:(init) _) -> (false)
			if t := v.args[0]; t.op == sinit {
				return /* clobber v */ p.setssa(v, skfalse, nil), true
			}
			// (nand.k _ f:(false)) -> f
			if f := v.args[1]; f.op == skfalse {
				return f, true
			}
			// (nand.k (false) x) -> x
			if _tmp23 := v.args[0]; _tmp23.op == skfalse {
				if x := v.args[1]; true {
					return x, true
				}
			}
			// (nand.k x x) -> (false)
			if x := v.args[0]; true {
				if x == v.args[1] {
					return /* clobber v */ p.setssa(v, skfalse, nil), true
				}
			}
		}
	case sxor: /* xor.k */
		if len(v.args) == 2 {
			// (xor.k (false) x) -> x
			if _tmp24 := v.args[0]; _tmp24.op == skfalse {
				if x := v.args[1]; true {
					return x, true
				}
			}
			// (xor.k t:(init) x) -> (nand.k x t)
			if t := v.args[0]; t.op == sinit {
				if x := v.args[1]; true {
					return /* clobber v */ p.setssa(v, snand, nil, x, t), true
				}
			}
			// (xor.k x (false)) -> x
			if x := v.args[0]; true {
				if _tmp25 := v.args[1]; _tmp25.op == skfalse {
					return x, true
				}
			}
			// (xor.k x t:(init)) -> (nand.k x t)
			if x := v.args[0]; true {
				if t := v.args[1]; t.op == sinit {
					return /* clobber v */ p.setssa(v, snand, nil, x, t), true
				}
			}
			// (xor.k x x) -> (false)
			if x := v.args[0]; true {
				if x == v.args[1] {
					return /* clobber v */ p.setssa(v, skfalse, nil), true
				}
			}
		}
	case sxnor: /* xnor.k */
		if len(v.args) == 2 {
			// (xnor.k x x) -> (init)
			if x := v.args[0]; true {
				if x == v.args[1] {
					return p.values[0], true
				}
			}
			// (xnor.k f (init)) -> f
			if f := v.args[0]; true {
				if _tmp26 := v.args[1]; _tmp26.op == sinit {
					return f, true
				}
			}
			// (xnor.k (init) f) -> f
			if _tmp27 := v.args[0]; _tmp27.op == sinit {
				if f := v.args[1]; true {
					return f, true
				}
			}
			// (xnor.k f (false)) -> (nand.k f (init))
			if f := v.args[0]; true {
				if _tmp28 := v.args[1]; _tmp28.op == skfalse {
					return /* clobber v */ p.setssa(v, snand, nil, f, p.values[0]), true
				}
			}
			// (xnor.k (false) f) -> (nand.k f (init))
			if _tmp29 := v.args[0]; _tmp29.op == skfalse {
				if f := v.args[1]; true {
					return /* clobber v */ p.setssa(v, snand, nil, f, p.values[0]), true
				}
			}
		}
	case scmpeqf: /* cmpeq.f */
		if len(v.args) == 3 {
			// (cmpeq.f x x k) -> k
			if x := v.args[0]; true {
				if x == v.args[1] {
					if k := v.args[2]; true {
						return k, true
					}
				}
			}
		}
	case scmpeqi: /* cmpeq.i */
		if len(v.args) == 3 {
			// (cmpeq.i x x k) -> k
			if x := v.args[0]; true {
				if x == v.args[1] {
					if k := v.args[2]; true {
						return k, true
					}
				}
			}
		}
	case scmplef: /* cmple.f */
		if len(v.args) == 3 {
			// (cmple.f x x k) -> k
			if x := v.args[0]; true {
				if x == v.args[1] {
					if k := v.args[2]; true {
						return k, true
					}
				}
			}
		}
	case scmplei: /* cmple.i */
		if len(v.args) == 3 {
			// (cmple.i x x k) -> k
			if x := v.args[0]; true {
				if x == v.args[1] {
					if k := v.args[2]; true {
						return k, true
					}
				}
			}
		}
	case scmpgef: /* cmpge.f */
		if len(v.args) == 3 {
			// (cmpge.f x x k) -> k
			if x := v.args[0]; true {
				if x == v.args[1] {
					if k := v.args[2]; true {
						return k, true
					}
				}
			}
		}
	case scmpgei: /* cmpge.i */
		if len(v.args) == 3 {
			// (cmpge.i x x k) -> k
			if x := v.args[0]; true {
				if x == v.args[1] {
					if k := v.args[2]; true {
						return k, true
					}
				}
			}
		}
	case scvtktoi: /* cvt.k@i */
		if len(v.args) == 2 {
			// (cvt.k@i (init) _) -> (broadcast.i 1)
			if _tmp30 := v.args[0]; _tmp30.op == sinit {
				return /* clobber v */ p.setssa(v, sbroadcasti, 1), true
			}
			// (cvt.k@i (false) _) -> (broadcast.i 0)
			if _tmp31 := v.args[0]; _tmp31.op == skfalse {
				return /* clobber v */ p.setssa(v, sbroadcasti, 0), true
			}
		}
	case scvtktof: /* cvt.k@f */
		if len(v.args) == 2 {
			// (cvt.k@f (init) _) -> (broadcast.f 1)
			if _tmp32 := v.args[0]; _tmp32.op == sinit {
				return /* clobber v */ p.setssa(v, sbroadcastf, 1), true
			}
			// (cvt.k@f (false) _) -> (broadcast.f 0)
			if _tmp33 := v.args[0]; _tmp33.op == skfalse {
				return /* clobber v */ p.setssa(v, sbroadcastf, 0), true
			}
		}
	case scvtitok: /* cvt.i@k */
		if len(v.args) == 2 {
			// (cvt.i@k _tmp0:(broadcast.i imm) k) -> (and.k "p.choose(imm != 0)" k)
			if _tmp0 := v.args[0]; _tmp0.op == sbroadcasti {
				if k := v.args[1]; true {
					if imm := toi64(_tmp0.imm); true {
						return /* clobber v */ p.setssa(v, sand, nil, p.choose(imm != 0), k), true
					}
				}
			}
		}
	case sconcatstr2: /* concat2.str */
		if len(v.args) == 3 {
			// (concat2.str x _tmp1:(literal "") k), "p.mask(x) == k" -> x
			if x := v.args[0]; true {
				if _tmp1 := v.args[1]; _tmp1.op == sliteral {
					if k := v.args[2]; true {
						if _tmp1.imm == "" {
							if p.mask(x) == k {
								return x, true
							}
						}
					}
				}
			}
			// (concat2.str x _tmp2:(concat2.str y z _) k1) -> (concat3.str x y z k1)
			if x := v.args[0]; true {
				if _tmp2 := v.args[1]; _tmp2.op == sconcatstr2 {
					if k1 := v.args[2]; true {
						if y := _tmp2.args[0]; true {
							if z := _tmp2.args[1]; true {
								return /* clobber v */ p.setssa(v, sconcatstr3, nil, x, y, z, k1), true
							}
						}
					}
				}
			}
			// (concat2.str _tmp3:(concat2.str x y _) z k1) -> (concat3.str x y z k1)
			if _tmp3 := v.args[0]; _tmp3.op == sconcatstr2 {
				if z := v.args[1]; true {
					if k1 := v.args[2]; true {
						if x := _tmp3.args[0]; true {
							if y := _tmp3.args[1]; true {
								return /* clobber v */ p.setssa(v, sconcatstr3, nil, x, y, z, k1), true
							}
						}
					}
				}
			}
		}
	case sconcatstr3: /* concat3.str */
		if len(v.args) == 4 {
			// (concat3.str _tmp4:(literal "") x y k) -> (concat2.str x y k)
			if _tmp4 := v.args[0]; _tmp4.op == sliteral {
				if x := v.args[1]; true {
					if y := v.args[2]; true {
						if k := v.args[3]; true {
							if _tmp4.imm == "" {
								return /* clobber v */ p.setssa(v, sconcatstr2, nil, x, y, k), true
							}
						}
					}
				}
			}
			// (concat3.str x y _tmp5:(literal "") k) -> (concat2.str x y k)
			if x := v.args[0]; true {
				if y := v.args[1]; true {
					if _tmp5 := v.args[2]; _tmp5.op == sliteral {
						if k := v.args[3]; true {
							if _tmp5.imm == "" {
								return /* clobber v */ p.setssa(v, sconcatstr2, nil, x, y, k), true
							}
						}
					}
				}
			}
			// (concat3.str x _tmp6:(literal "") y k) -> (concat2.str x y k)
			if x := v.args[0]; true {
				if _tmp6 := v.args[1]; _tmp6.op == sliteral {
					if y := v.args[2]; true {
						if k := v.args[3]; true {
							if _tmp6.imm == "" {
								return /* clobber v */ p.setssa(v, sconcatstr2, nil, x, y, k), true
							}
						}
					}
				}
			}
		}
	case sconcatstr4: /* concat4.str */
		if len(v.args) == 5 {
			// (concat4.str x y z _tmp7:(literal "") k) -> (concat3.str x y z k)
			if x := v.args[0]; true {
				if y := v.args[1]; true {
					if z := v.args[2]; true {
						if _tmp7 := v.args[3]; _tmp7.op == sliteral {
							if k := v.args[4]; true {
								if _tmp7.imm == "" {
									return /* clobber v */ p.setssa(v, sconcatstr3, nil, x, y, z, k), true
								}
							}
						}
					}
				}
			}
		}
	case sstorev: /* store.z */
		if len(v.args) == 3 {
			// (store.z mem ov k:(false) slot), "ov != k" -> (store.z mem k k slot)
			if mem := v.args[0]; true {
				if ov := v.args[1]; true {
					if k := v.args[2]; k.op == skfalse {
						if slot := v.imm.(int); true {
							if ov != k {
								return /* clobber v */ p.setssa(v, sstorev, slot, mem, k, k), true
							}
						}
					}
				}
			}
		}
	case svk: /* vk */
		if len(v.args) == 2 {
			// (vk val k), "p.mask(v) == k" -> val
			if val := v.args[0]; true {
				if k := v.args[1]; true {
					if p.mask(v) == k {
						return val, true
					}
				}
			}
		}
	case sfloatk: /* floatk */
		if len(v.args) == 2 {
			// (floatk f k), "p.mask(f) == k" -> f
			if f := v.args[0]; true {
				if k := v.args[1]; true {
					if p.mask(f) == k {
						return f, true
					}
				}
			}
		}
	case sblendv: /* blendv */
		if len(v.args) == 3 {
			// (blendv _ y (init)) -> y
			if y := v.args[1]; true {
				if _tmp34 := v.args[2]; _tmp34.op == sinit {
					return y, true
				}
			}
			// (blendv x _ (false)) -> x
			if x := v.args[0]; true {
				if _tmp35 := v.args[2]; _tmp35.op == skfalse {
					return x, true
				}
			}
		}
	case sblendint: /* blendint */
		if len(v.args) == 3 {
			// (blendint x _ (false)) -> x
			if x := v.args[0]; true {
				if _tmp36 := v.args[2]; _tmp36.op == skfalse {
					return x, true
				}
			}
			// (blendint _ y (init)) -> y
			if y := v.args[1]; true {
				if _tmp37 := v.args[2]; _tmp37.op == sinit {
					return y, true
				}
			}
		}
	case sblendfloat: /* blendfloat */
		if len(v.args) == 3 {
			// (blendfloat _ y (init)) -> y
			if y := v.args[1]; true {
				if _tmp38 := v.args[2]; _tmp38.op == sinit {
					return y, true
				}
			}
			// (blendfloat x _ (false)) -> x
			if x := v.args[0]; true {
				if _tmp39 := v.args[2]; _tmp39.op == skfalse {
					return x, true
				}
			}
		}
	case sblendstr: /* blendstr */
		if len(v.args) == 3 {
			// (blendstr _ y (init)) -> y
			if y := v.args[1]; true {
				if _tmp40 := v.args[2]; _tmp40.op == sinit {
					return y, true
				}
			}
			// (blendstr x _ (false)) -> x
			if x := v.args[0]; true {
				if _tmp41 := v.args[2]; _tmp41.op == skfalse {
					return x, true
				}
			}
		}
	case saddf: /* add.f */
		if len(v.args) == 3 {
			// (add.f f _tmp8:(broadcast.f imm) k) -> (add.imm.f f k imm)
			if f := v.args[0]; true {
				if _tmp8 := v.args[1]; _tmp8.op == sbroadcastf {
					if k := v.args[2]; true {
						if imm := tof64(_tmp8.imm); true {
							return /* clobber v */ p.setssa(v, saddimmf, imm, f, k), true
						}
					}
				}
			}
			// (add.f _tmp9:(broadcast.f imm) f k) -> (add.imm.f f k imm)
			if _tmp9 := v.args[0]; _tmp9.op == sbroadcastf {
				if f := v.args[1]; true {
					if k := v.args[2]; true {
						if imm := tof64(_tmp9.imm); true {
							return /* clobber v */ p.setssa(v, saddimmf, imm, f, k), true
						}
					}
				}
			}
		}
	case saddimmf: /* add.imm.f */
		if len(v.args) == 2 {
			// (add.imm.f f _ 0) -> f
			if f := v.args[0]; true {
				if tof64(v.imm) == 0 {
					return f, true
				}
			}
		}
	case saddimmi: /* add.imm.i */
		if len(v.args) == 2 {
			// (add.imm.i i _ 0) -> i
			if i := v.args[0]; true {
				if toi64(v.imm) == 0 {
					return i, true
				}
			}
		}
	case ssubf: /* sub.f */
		if len(v.args) == 3 {
			// (sub.f f _tmp10:(broadcast.f imm) k) -> (sub.imm.f f k imm)
			if f := v.args[0]; true {
				if _tmp10 := v.args[1]; _tmp10.op == sbroadcastf {
					if k := v.args[2]; true {
						if imm := tof64(_tmp10.imm); true {
							return /* clobber v */ p.setssa(v, ssubimmf, imm, f, k), true
						}
					}
				}
			}
			// (sub.f _tmp11:(broadcast.f imm) f k) -> (rsub.imm.f f k imm)
			if _tmp11 := v.args[0]; _tmp11.op == sbroadcastf {
				if f := v.args[1]; true {
					if k := v.args[2]; true {
						if imm := tof64(_tmp11.imm); true {
							return /* clobber v */ p.setssa(v, srsubimmf, imm, f, k), true
						}
					}
				}
			}
		}
	case ssubimmf: /* sub.imm.f */
		if len(v.args) == 2 {
			// (sub.imm.f f _ 0) -> f
			if f := v.args[0]; true {
				if tof64(v.imm) == 0 {
					return f, true
				}
			}
		}
	case ssubimmi: /* sub.imm.i */
		if len(v.args) == 2 {
			// (sub.imm.i i _ 0) -> i
			if i := v.args[0]; true {
				if toi64(v.imm) == 0 {
					return i, true
				}
			}
		}
	case srsubimmf: /* rsub.imm.f */
		if len(v.args) == 2 {
			// (rsub.imm.f f k 0) -> (neg.f f k)
			if f := v.args[0]; true {
				if k := v.args[1]; true {
					if tof64(v.imm) == 0 {
						return /* clobber v */ p.setssa(v, snegf, nil, f, k), true
					}
				}
			}
		}
	case srsubimmi: /* rsub.imm.i */
		if len(v.args) == 2 {
			// (rsub.imm.i i k 0) -> (neg.i i k)
			if i := v.args[0]; true {
				if k := v.args[1]; true {
					if toi64(v.imm) == 0 {
						return /* clobber v */ p.setssa(v, snegi, nil, i, k), true
					}
				}
			}
		}
	case smulf: /* mul.f */
		if len(v.args) == 3 {
			// (mul.f f _tmp12:(broadcast.f imm) k) -> (mul.imm.f f k imm)
			if f := v.args[0]; true {
				if _tmp12 := v.args[1]; _tmp12.op == sbroadcastf {
					if k := v.args[2]; true {
						if imm := tof64(_tmp12.imm); true {
							return /* clobber v */ p.setssa(v, smulimmf, imm, f, k), true
						}
					}
				}
			}
			// (mul.f _tmp13:(broadcast.f imm) f k) -> (mul.imm.f f k imm)
			if _tmp13 := v.args[0]; _tmp13.op == sbroadcastf {
				if f := v.args[1]; true {
					if k := v.args[2]; true {
						if imm := tof64(_tmp13.imm); true {
							return /* clobber v */ p.setssa(v, smulimmf, imm, f, k), true
						}
					}
				}
			}
		}
	case smulimmf: /* mul.imm.f */
		if len(v.args) == 2 {
			// (mul.imm.f f _ 1) -> f
			if f := v.args[0]; true {
				if tof64(v.imm) == 1 {
					return f, true
				}
			}
		}
	case smulimmi: /* mul.imm.i */
		if len(v.args) == 2 {
			// (mul.imm.i i _ 1) -> i
			if i := v.args[0]; true {
				if toi64(v.imm) == 1 {
					return i, true
				}
			}
		}
	case sdivf: /* div.f */
		if len(v.args) == 3 {
			// (div.f f _tmp14:(broadcast.f imm) k) -> (div.imm.f f k imm)
			if f := v.args[0]; true {
				if _tmp14 := v.args[1]; _tmp14.op == sbroadcastf {
					if k := v.args[2]; true {
						if imm := tof64(_tmp14.imm); true {
							return /* clobber v */ p.setssa(v, sdivimmf, imm, f, k), true
						}
					}
				}
			}
			// (div.f _tmp15:(broadcast.f imm) f k) -> (rdiv.imm.f f k imm)
			if _tmp15 := v.args[0]; _tmp15.op == sbroadcastf {
				if f := v.args[1]; true {
					if k := v.args[2]; true {
						if imm := tof64(_tmp15.imm); true {
							return /* clobber v */ p.setssa(v, srdivimmf, imm, f, k), true
						}
					}
				}
			}
		}
	case sorimmi: /* or.imm.i */
		if len(v.args) == 2 {
			// (or.imm.i i _ 0) -> i
			if i := v.args[0]; true {
				if toi64(v.imm) == 0 {
					return i, true
				}
			}
		}
	case ssllimmi: /* sll.imm.i */
		if len(v.args) == 2 {
			// (sll.imm.i i _ 0) -> i
			if i := v.args[0]; true {
				if toi64(v.imm) == 0 {
					return i, true
				}
			}
		}
	case ssraimmi: /* sra.imm.i */
		if len(v.args) == 2 {
			// (sra.imm.i i _ 0) -> i
			if i := v.args[0]; true {
				if toi64(v.imm) == 0 {
					return i, true
				}
			}
		}
	case ssrlimmi: /* srl.imm.i */
		if len(v.args) == 2 {
			// (srl.imm.i i _ 0) -> i
			if i := v.args[0]; true {
				if toi64(v.imm) == 0 {
					return i, true
				}
			}
		}
	case saggandk: /* aggand.k */
		if len(v.args) == 3 {
			// (aggand.k mem _ (false) _) -> mem
			if mem := v.args[0]; true {
				if _tmp42 := v.args[2]; _tmp42.op == skfalse {
					return mem, true
				}
			}
		}
	case saggork: /* aggor.k */
		if len(v.args) == 3 {
			// (aggor.k mem _ (false) _) -> mem
			if mem := v.args[0]; true {
				if _tmp43 := v.args[2]; _tmp43.op == skfalse {
					return mem, true
				}
			}
		}
	case saggsumf: /* aggsum.f */
		if len(v.args) == 3 {
			// (aggsum.f mem _ (false) _) -> mem
			if mem := v.args[0]; true {
				if _tmp44 := v.args[2]; _tmp44.op == skfalse {
					return mem, true
				}
			}
		}
	case saggsumi: /* aggsum.i */
		if len(v.args) == 3 {
			// (aggsum.i mem _ (false) _) -> mem
			if mem := v.args[0]; true {
				if _tmp45 := v.args[2]; _tmp45.op == skfalse {
					return mem, true
				}
			}
		}
	case saggminf: /* aggmin.f */
		if len(v.args) == 3 {
			// (aggmin.f mem _ (false) _) -> mem
			if mem := v.args[0]; true {
				if _tmp46 := v.args[2]; _tmp46.op == skfalse {
					return mem, true
				}
			}
		}
	case saggmini: /* aggmin.i */
		if len(v.args) == 3 {
			// (aggmin.i mem _ (false) _) -> mem
			if mem := v.args[0]; true {
				if _tmp47 := v.args[2]; _tmp47.op == skfalse {
					return mem, true
				}
			}
		}
	case saggmaxf: /* aggmax.f */
		if len(v.args) == 3 {
			// (aggmax.f mem _ (false) _) -> mem
			if mem := v.args[0]; true {
				if _tmp48 := v.args[2]; _tmp48.op == skfalse {
					return mem, true
				}
			}
		}
	case saggmaxi: /* aggmax.i */
		if len(v.args) == 3 {
			// (aggmax.i mem _ (false) _) -> mem
			if mem := v.args[0]; true {
				if _tmp49 := v.args[2]; _tmp49.op == skfalse {
					return mem, true
				}
			}
		}
	case saggmints: /* aggmin.ts */
		if len(v.args) == 3 {
			// (aggmin.ts mem _ (false) _) -> mem
			if mem := v.args[0]; true {
				if _tmp50 := v.args[2]; _tmp50.op == skfalse {
					return mem, true
				}
			}
		}
	case saggmaxts: /* aggmax.ts */
		if len(v.args) == 3 {
			// (aggmax.ts mem _ (false) _) -> mem
			if mem := v.args[0]; true {
				if _tmp51 := v.args[2]; _tmp51.op == skfalse {
					return mem, true
				}
			}
		}
	case saggandi: /* aggand.i */
		if len(v.args) == 3 {
			// (aggand.i mem _ (false) _) -> mem
			if mem := v.args[0]; true {
				if _tmp52 := v.args[2]; _tmp52.op == skfalse {
					return mem, true
				}
			}
		}
	case saggori: /* aggor.i */
		if len(v.args) == 3 {
			// (aggor.i mem _ (false) _) -> mem
			if mem := v.args[0]; true {
				if _tmp53 := v.args[2]; _tmp53.op == skfalse {
					return mem, true
				}
			}
		}
	case saggxori: /* aggxor.i */
		if len(v.args) == 3 {
			// (aggxor.i mem _ (false) _) -> mem
			if mem := v.args[0]; true {
				if _tmp54 := v.args[2]; _tmp54.op == skfalse {
					return mem, true
				}
			}
		}
	case saggcount: /* aggcount */
		if len(v.args) == 2 {
			// (aggcount mem (false) _) -> mem
			if mem := v.args[0]; true {
				if _tmp55 := v.args[1]; _tmp55.op == skfalse {
					return mem, true
				}
			}
		}
	case saggslotandk: /* aggslotand.k */
		if len(v.args) == 4 {
			// (aggslotand.k mem _ _ (false) _) -> mem
			if mem := v.args[0]; true {
				if _tmp56 := v.args[3]; _tmp56.op == skfalse {
					return mem, true
				}
			}
		}
	case saggslotork: /* aggslotor.k */
		if len(v.args) == 4 {
			// (aggslotor.k mem _ _ (false) _) -> mem
			if mem := v.args[0]; true {
				if _tmp57 := v.args[3]; _tmp57.op == skfalse {
					return mem, true
				}
			}
		}
	case saggslotminf: /* aggslotmin.f */
		if len(v.args) == 4 {
			// (aggslotmin.f mem _ _ (false) _) -> mem
			if mem := v.args[0]; true {
				if _tmp58 := v.args[3]; _tmp58.op == skfalse {
					return mem, true
				}
			}
		}
	case saggslotmini: /* aggslotmin.i */
		if len(v.args) == 4 {
			// (aggslotmin.i mem _ _ (false) _) -> mem
			if mem := v.args[0]; true {
				if _tmp59 := v.args[3]; _tmp59.op == skfalse {
					return mem, true
				}
			}
		}
	case saggslotmaxf: /* aggslotmax.f */
		if len(v.args) == 4 {
			// (aggslotmax.f mem _ _ (false) _) -> mem
			if mem := v.args[0]; true {
				if _tmp60 := v.args[3]; _tmp60.op == skfalse {
					return mem, true
				}
			}
		}
	case saggslotmaxi: /* aggslotmax.i */
		if len(v.args) == 4 {
			// (aggslotmax.i mem _ _ (false) _) -> mem
			if mem := v.args[0]; true {
				if _tmp61 := v.args[3]; _tmp61.op == skfalse {
					return mem, true
				}
			}
		}
	case saggslotmints: /* aggslotmin.ts */
		if len(v.args) == 4 {
			// (aggslotmin.ts mem _ _ (false) _) -> mem
			if mem := v.args[0]; true {
				if _tmp62 := v.args[3]; _tmp62.op == skfalse {
					return mem, true
				}
			}
		}
	case saggslotmaxts: /* aggslotmax.ts */
		if len(v.args) == 4 {
			// (aggslotmax.ts mem _ _ (false) _) -> mem
			if mem := v.args[0]; true {
				if _tmp63 := v.args[3]; _tmp63.op == skfalse {
					return mem, true
				}
			}
		}
	case saggslotandi: /* aggslotand.i */
		if len(v.args) == 4 {
			// (aggslotand.i mem _ _ (false) _) -> mem
			if mem := v.args[0]; true {
				if _tmp64 := v.args[3]; _tmp64.op == skfalse {
					return mem, true
				}
			}
		}
	case saggslotori: /* aggslotor.i */
		if len(v.args) == 4 {
			// (aggslotor.i mem _ _ (false) _) -> mem
			if mem := v.args[0]; true {
				if _tmp65 := v.args[3]; _tmp65.op == skfalse {
					return mem, true
				}
			}
		}
	case saggslotxori: /* aggslotxor.i */
		if len(v.args) == 4 {
			// (aggslotxor.i mem _ _ (false) _) -> mem
			if mem := v.args[0]; true {
				if _tmp66 := v.args[3]; _tmp66.op == skfalse {
					return mem, true
				}
			}
		}
	case saggslotcount: /* aggslotcount */
		if len(v.args) == 3 {
			// (aggslotcount mem _ (false) _) -> mem
			if mem := v.args[0]; true {
				if _tmp67 := v.args[2]; _tmp67.op == skfalse {
					return mem, true
				}
			}
		}
	case sboxint: /* boxint */
		if len(v.args) == 2 {
			// (boxint _tmp16:(broadcast.i lit) _) -> (literal lit)
			if _tmp16 := v.args[0]; _tmp16.op == sbroadcasti {
				if lit := toi64(_tmp16.imm); true {
					return /* clobber v */ p.setssa(v, sliteral, lit), true
				}
			}
		}
	case sboxfloat: /* boxfloat */
		if len(v.args) == 2 {
			// (boxfloat _tmp17:(broadcast.f lit) _) -> (literal lit)
			if _tmp17 := v.args[0]; _tmp17.op == sbroadcastf {
				if lit := tof64(_tmp17.imm); true {
					return /* clobber v */ p.setssa(v, sliteral, lit), true
				}
			}
		}
	case sboxts: /* boxts */
		if len(v.args) == 2 {
			// (boxts _tmp18:(broadcast.ts lit) _), "ts := date.UnixMicro(int64(lit)); true" -> (literal ts)
			if _tmp18 := v.args[0]; _tmp18.op == sbroadcastts {
				if lit := toi64(_tmp18.imm); true {
					if ts := date.UnixMicro(int64(lit)); true {
						return /* clobber v */ p.setssa(v, sliteral, ts), true
					}
				}
			}
		}
	case saggapproxcount: /* aggapproxcount */
		if len(v.args) == 2 {
			// (aggapproxcount mem (false) _) -> mem
			if mem := v.args[0]; true {
				if _tmp68 := v.args[1]; _tmp68.op == skfalse {
					return mem, true
				}
			}
		}
	case saggapproxcountpartial: /* aggapproxcount.partial */
		if len(v.args) == 2 {
			// (aggapproxcount.partial mem (false) _) -> mem
			if mem := v.args[0]; true {
				if _tmp69 := v.args[1]; _tmp69.op == skfalse {
					return mem, true
				}
			}
		}
	case saggapproxcountmerge: /* aggapproxcount.merge */
		if len(v.args) == 2 {
			// (aggapproxcount.merge mem (false) _) -> mem
			if mem := v.args[0]; true {
				if _tmp70 := v.args[1]; _tmp70.op == skfalse {
					return mem, true
				}
			}
		}
	case saggslotapproxcount: /* aggslotapproxcount */
		if len(v.args) == 4 {
			// (aggslotapproxcount mem _ _ (false) _) -> mem
			if mem := v.args[0]; true {
				if _tmp71 := v.args[3]; _tmp71.op == skfalse {
					return mem, true
				}
			}
		}
	case saggslotapproxcountpartial: /* aggslotapproxcount.partial */
		if len(v.args) == 4 {
			// (aggslotapproxcount.partial mem _ _ (false) _) -> mem
			if mem := v.args[0]; true {
				if _tmp72 := v.args[3]; _tmp72.op == skfalse {
					return mem, true
				}
			}
		}
	case saggslotapproxcountmerge: /* aggslotapproxcount.merge */
		if len(v.args) == 4 {
			// (aggslotapproxcount.merge mem _ _ (false) _) -> mem
			if mem := v.args[0]; true {
				if _tmp73 := v.args[3]; _tmp73.op == skfalse {
					return mem, true
				}
			}
		}
	}
	return v, false
}
