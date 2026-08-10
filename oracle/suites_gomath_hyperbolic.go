package main

// Differential coverage for the hyperbolic and inverse-hyperbolic routines
// `promql/functions.go` reaches through `simpleFloatFunc` — sinh, cosh, tanh,
// asinh, acosh, atanh — and for `math.Log1p`, which three of them are built on
// and which has no PromQL wrapper of its own.
//
// Seven suites rather than one, following gocompat/{exp,log,pow} and the trig
// block: same in/out shape, but a per-function fixture means a failure report
// names the function instead of burying it among six others.
//
// Why every one of these needs pinning rather than delegating to libm — measured,
// not assumed. Comparing Swift's libm against Go over 1,921,867 distinct inputs
// per function (every branch boundary of all seven, straddled; every power of two
// from 2**-1074 to 2**1023; subnormals; and a seeded random sample over the whole
// exponent range) gave:
//
//	Sinh    472,471 differ (24.6%)      Asinh    166,942 differ ( 8.7%)
//	Cosh    260,500 differ (13.6%)      Acosh  1,334,959 differ (69.5%)
//	Tanh    103,074 differ ( 5.4%)      Atanh    968,192 differ (50.4%)
//	                                    Log1p    346,161 differ (18.0%)
//
// Acosh's and Atanh's totals are dominated by the out-of-domain NaN payload —
// Go's NaN() is 0x7FF8000000000001, Swift's Double.nan is 0x7FF8000000000000 —
// but 27,509 and 64,610 genuine one-ULP disagreements survive stripping that out.
// Tanh is the mildest of the seven and still differs on one input in nineteen.
// `haveArchSinh` and its six siblings are true only on s390x, so the portable Go
// is what runs on arm64 and amd64.
//
// The corpora are seeded-deterministic and every case travels as a 16-hex-digit
// bit pattern: encoding/json refuses NaN, a decimal round trip is not bit-exact,
// and the NaN payload is part of the contract here.

import (
	"math"
	"math/rand"
)

// hyperbolicCorpus builds the shared input set: the branch boundaries of all
// seven routines, straddled, plus a deterministic random sample.
//
// `extra` carries the per-function boundaries and harvested fusion witnesses.
func hyperbolicCorpus(seed int64, randomCount int, extra []float64) []float64 {
	out := []float64{}
	out = append(out, extra...)

	// Zeros and signs — Sinh, Tanh, Asinh, Atanh and Log1p all return the
	// argument for ±0, so the sign of zero is a contract. Cosh(±0) is 1.
	out = append(out, 0, math.Copysign(0, -1))

	// Specials. Sinh/Tanh/Asinh keep the argument's own NaN payload; Acosh,
	// Atanh and Log1p replace it with Go's, and Cosh clears the sign bit first.
	out = append(out,
		math.Inf(1), math.Inf(-1),
		math.NaN(),
		math.Float64frombits(0x7FF8000000000000), // Swift's Double.nan payload
		math.Float64frombits(0x7FF0000000000002), // Prometheus's StaleNaN
		math.Float64frombits(0xFFF8000000000001), // negative quiet NaN
	)

	// Every branch boundary in the seven functions, straddled on both sides and in
	// both signs: landing exactly on one and landing one ULP away take different
	// paths.
	bounds := []float64{
		0.5, 21, // sinh: series / (ex-1/ex)/2 / Exp(x)/2
		0.625,              // tanh: rational / 1-2/(exp(2z)+1)
		44.014845965556525, // tanh: 0.5*MAXLOG, above which it is exactly ±1
		1, 2,               // acosh's domain edge and its log/log1p split;
		// asinh's 2; atanh's ±1
		0.5,                    // atanh's two log1p forms
		268435456,              // 2**28: asinh's and acosh's Large
		3.7252902984619141e-09, // 2**-28: asinh's and atanh's NearZero
		0.41421356237309503,    // log1p's Sqrt2M1
		-0.29289321881345248,   // log1p's Sqrt2HalfM1
		1.862645149230957e-09,  // log1p's Small, 2**-29
		5.5511151231257827e-17, // log1p's Tiny, 2**-54
		9007199254740992,       // log1p's Two53
		-1,                     // log1p(-1) = -Inf; atanh(-1) = -Inf
		709.78271289338397,     // Exp overflows just above here, so Sinh/Cosh do
		710,
	}
	for _, v := range bounds {
		for _, s := range []float64{v, -v} {
			out = append(out, s,
				math.Nextafter(s, math.Inf(1)), math.Nextafter(s, math.Inf(-1)))
		}
	}

	// Powers of two across the whole exponent range, both signs, and 1.5x each.
	for exp := -60; exp <= 60; exp++ {
		v := math.Ldexp(1, exp)
		out = append(out, v, -v, v*1.5, -v*1.5)
	}

	// Subnormals and the extremes.
	out = append(out,
		math.SmallestNonzeroFloat64, -math.SmallestNonzeroFloat64,
		math.MaxFloat64, -math.MaxFloat64,
		math.Float64frombits(0x000FFFFFFFFFFFFF), // largest subnormal
		math.Float64frombits(0x0010000000000000), // smallest normal
	)

	r := rand.New(rand.NewSource(seed))
	for i := 0; i < randomCount; i++ {
		switch i % 6 {
		case 0:
			// [-1, 1): atanh's and log1p's most interesting region, and where
			// tanh's and sinh's rationals run.
			out = append(out, r.Float64()*2-1)
		case 1:
			// [-4, 4): straddles sinh's 0.5 and tanh's 0.625 densely.
			out = append(out, (r.Float64()*2-1)*4)
		case 2:
			// Uniform over bit patterns: reaches every exponent, including the
			// magnitudes where only the Exp-based branches run.
			out = append(out, math.Float64frombits(r.Uint64()))
		case 3:
			// Log-uniform over a wide but finite range.
			out = append(out, (r.Float64()*2-1)*math.Pow(2, float64(r.Intn(120)-60)))
		case 4:
			// [0, 40): acosh's log1p/log split and sinh's two Exp branches.
			out = append(out, r.Float64()*40)
		case 5:
			// Near ±1 from below, where atanh's and acosh's cancellation lives.
			out = append(out, math.Copysign(
				1-math.Pow(2, -float64(r.Intn(53)))*r.Float64(),
				float64(1-2*r.Intn(2))))
		}
	}
	return out
}

// fromBits is the harvested-witness spelling used throughout this file: fusion
// witnesses are only meaningful as exact bit patterns.
func fromBits(bits ...uint64) []float64 {
	out := make([]float64, 0, len(bits))
	for _, b := range bits {
		out = append(out, math.Float64frombits(b))
	}
	return out
}

// ------------------------------------------------------------- fusion witnesses
//
// Go's arm64 output fuses **thirty-six** sites across these seven functions.
// `cosh` and `atanh` have none: every product in them is immediately divided, so
// there is no add to fuse into.
//
// "It is fused" is a claim, and a claim needs a failing case to be a tested one.
// Each site was unfused on its own and diffed against Go over 34,000,052 inputs
// (14,000,052 broad plus 20,000,000 aimed at the branches the broad pass reached
// least). Nineteen of the thirty-six are observable and are witnessed below;
// seventeen are not, and they sort into three groups worth recording because
// re-deriving them is expensive:
//
//   - **Provably unobservable** (4). `log1p`'s `x - x*x*0.5`, because the
//     multiplier is a power of two and `|x| < 2**-29` on that branch keeps `x*x`
//     far from subnormal, so the halving is exact either way. And the three
//     `k*Ln2Hi` products (log1p.go:188, :194, :202), because `Ln2Hi` carries only
//     32 significant bits and |k| <= 1075 — exactly the argument that applies to
//     `gocompat/log` (PORTING.md quirk 30), and exactly what the hi/lo split of
//     ln2 is *for*.
//   - **Unreachable** (1). log1p.go:192's `f - R` needs `iu == 0 && k == 0`, and
//     `iu == 0` after the reduction implies `u == 1.0`, which implies
//     `|x| <= 2**-53` — but `|x| < 2**-29` has already returned at log1p.go:141.
//     Its sibling `f == 0 && k == 0` (log1p.go:185's `return 0`) is dead for the
//     same reason. Both were zero across all 34,000,052 inputs, and unlike the
//     rest that is because the code never runs, not because the difference hides.
//   - **Diluted below the final rounding** (12). Every one of them is a *leading*
//     polynomial term, and observability falls off monotonically along each chain:
//     `sinh`'s numerator goes 0, 122, 25,280 witnesses from first term to last,
//     its denominator 0, 5, 4,426; `tanh`'s 0, 2, 1,545 and 0, 122, 10,513;
//     and the six adds of `log1p`'s seven-term `Lp` chain go 0, 0, 0, 0, 8, 315. So the two
//     unrounded recomputations in `sinh` and `tanh` — `sq + Q2` and
//     `s + tanhQ[0]` — are invisible **because they are the first term of their
//     chain**, where `xatan`'s structurally identical site is the *only* term and
//     is loudly observable (PORTING.md quirk 39). No witness found is a fact about
//     the search, not a licence to simplify: the port spells all thirty-six the
//     way the disassembly does.

// sinhWitnesses covers the two observable numerator terms and the two observable
// denominator terms. All are in |x| <= 0.5, sinh's rational branch.
func sinhWitnesses() []float64 {
	return fromBits(
		// (P3*sq+P2)*sq + P1
		0x3fdcd0342600dce0, 0x3fd86e2231a1e8d0, 0xbfdb6f00402fa54e,
		0x3fdc558ce0d35ec8, 0xbfdeed69f9dc1890,
		// ...*sq + P0
		0xbfd5988b419b57fe, 0x3fd029d56cec91a0, 0x3fde154087f3a8d0,
		0x3fdae779f8ce901c, 0xbfd16de416c64d00,
		// (sq+Q2)*sq + Q1
		0x3fdb9b3ce4e22738, 0x3fdbc731ccf182ce, 0x3fc38db99f13db58,
		0xbfdbf6b18e6bf140, 0xbfd5f2921e189d1e,
		// ...*sq + Q0
		0xbfd0a7e712807224, 0xbfd8fbf27252e7cc, 0xbfd42c07f524edf4,
		0x3fd1ae09e747adbc, 0xbfddd0d2839b1fd0,
	)
}

// tanhWitnesses covers the two observable numerator terms and the two observable
// denominator terms. All are in |x| < 0.625, tanh's rational branch.
func tanhWitnesses() []float64 {
	return fromBits(
		// tanhP[0]*s + tanhP[1]
		0x3fde6d0b7c08f488, 0x3fd9897ebcf72f20,
		// ...*s + tanhP[2]
		0xbfe10b966aaaf9be, 0x3fd7158875dac6b0, 0x3fdb2fec719d394c,
		0x3fdfc82fa6b2b650, 0xbfe271ac545d319f,
		// (s+tanhQ[0])*s + tanhQ[1]
		0xbfe37002b68070be, 0x3fe0aa6454638bea, 0x3fe22200166662b8,
		0x3fe2c6e8e3feb4e0, 0xbfe3372f7c187bf0,
		// ...*s + tanhQ[2]
		0xbfe3877e81136e47, 0x3fe0db3a44d957bc, 0xbfe2cec6b443a1e0,
		0xbfdf297dfa6138e6, 0x3fdf2488e9d30878,
	)
}

// log1pWitnesses are for the seven observable sites *inside* log1p, reached
// directly. The same seven sites are witnessed again through asinh, acosh and
// atanh below, because each of those calls log1p on a different sub-domain and a
// witness for one is not a witness for another.
func log1pWitnesses() []float64 {
	return fromBits(
		// Lp2 term — the first add of the Lp chain that is observable at all.
		0x3fda66f9677bc89c, 0x3fdb6c5752fe85cc, 0x3fdae16089654b48,
		0xbfd36ee26dff4687, 0xbfd2d286e226d328,
		// Lp1 term
		0xbfd0d4383c1a5516, 0x3fbb1c5f27352840, 0x3fd95c8f5b2211b0,
		0xbfd69ce6de9f8ccc, 0x4012ea9159681831,
		// hfsq+R with hfsq recomputed unrounded, k == 0 (log1p.go:200)
		0xbfcc2f4f1240da38, 0xbfcc10a0734c8330, 0x3fd82db731e303ec,
		0x3fd1ae09e747adbc, 0x3fd57cc3d1040a38,
		// hfsq - s*(hfsq+R), k == 0 — the outer hfsq is the ROUNDED one here
		0x3fd9985a882ea4fc, 0x3fd75c1b7e00aef8, 0x3fd8de46f1a1a498,
		0x3fd18cdad56d0cc0, 0x3fd8b49d16955984,
		// hfsq+R unrounded, k != 0 (log1p.go:202) — witnessed apart from the
		// k == 0 spelling, which is the point of having both.
		0x3ffebab2e67aa494, 0x3fdbe89f90a25f50, 0xbfd4cb500fdb8a6e,
		0x3fdb585bd67b6362, 0xbfe3b3bf7bedb700,
		// (k*Ln2Lo + c) + s*(hfsq+R)
		0x40363f297ce8edd0, 0x3fe17cce5d66e3f4, 0xbfe42e8150e29082,
		0x3ff8e743c44882a0, 0x3fdaa2f5e3eec72c,
		// hfsq - inner with the OUTER hfsq unrounded too, k != 0 — the site that
		// no reading of the Go source produces, and the loudest of the seven.
		0x433a35b25212fa40, 0x3fe256c89a565794, 0xbfd76ebcc476da90,
		0xbfd6545ffc0077e2, 0xbfd309f785da8e26,
	)
}

// asinhWitnesses covers asinh's own two fused sites plus the log1p sites reached
// through its default branch.
func asinhWitnesses() []float64 {
	return fromBits(
		// 1 + x*x under the Sqrt, the 2 < x <= 2**28 branch. Note the numerator's
		// x*x on the *same source line* of the default branch is NOT fused; only
		// the one under the Sqrt is.
		0x4005e5693944899e, 0xc00f0d7ce013329a, 0xc0058ddc57727b43,
		0xc005992d44e2de56, 0xc0058d8991612bb8,
		// 1 + x*x under the Sqrt, the default branch
		0xbfeffffff3581a7a, 0xbff2b5204da79844, 0xbfeffffb907d616e,
		0xbff0dd26ad8148e4, 0x3feb145c9358b7f8,
		// log1p's Lp2 and Lp1 terms, through asinh
		0x3fd264a2110b3950, 0xbfd31b5edb17d97d,
		0xbfceb60a3ba74940, 0x3fd8fe24f2d625d0, 0xbfdcffab9770fa48,
		0x3fd85d256f51a198, 0x3ff2d897c6fb70ee,
		// log1p's hfsq+R (k == 0) and hfsq - s*(hfsq+R)
		0x3fd5c1cdf3472d24, 0x3fc9628f1a2a8df0, 0xbfd0106f8e6487ae,
		0x3fcc8f3993ebcd80, 0x3fd50771e7e20248,
		0xbfd2f4cc68177708, 0x3fd26179e33d1330, 0x3fd210b8f6d383d0,
		0xbfd522de92f98544,
		// log1p's k != 0 sites. The four 0x3fefffffff... values sit one to eight
		// ULP below 1, which is where asinh's `x*x/(1+Sqrt(1+x*x))` lands log1p
		// closest to its reduction boundary.
		0xbfeffffffffffff8, 0x3feffffffffffff9, 0xbfefd1825cc0607e,
		0x3feffffffffffff8, 0xbfeffffffffffff9,
		0x3ff316beb87e82c8, 0xbff39b02d8fc54ec,
		0x3fdbc9f2ccfd8f04, 0x3feffffffff5f361, 0x3fefffffff8bed43,
		0xbfeffffffffff925,
	)
}

// acoshWitnesses covers acosh's own two fused sites plus the log1p sites reached
// through its 1 < x <= 2 branch. Every value is in the domain, x >= 1.
func acoshWitnesses() []float64 {
	return fromBits(
		// x*x - 1, the 2 < x < 2**28 branch (an FNMSUBD)
		0x400052d9060257f4, 0x400060c2535b0850, 0x400032e4db2c5c50,
		0x40001160ed8e8d8e, 0x400155a554b4b93c,
		// 2*t + t*t under the Sqrt, the 1 < x <= 2 branch
		0x3ffebfca70e84440, 0x3ff4d98fb21ec880, 0x3ffefa4cb3e24d68,
		0x3ffca14fa87ea18e, 0x3ffdb7fee7574ea8,
		// log1p's Lp1 term, through acosh
		0x3ffa59f035353658, 0x3ffb20c411ffff7c, 0x3ff8388b6b201047,
		// log1p's hfsq+R (k == 0) and hfsq - s*(hfsq+R)
		0x3ff0d8ee5a04a6f8, 0x3ff08d55e430843c, 0x3ff06952808e6bc4,
		0x3ff095dfa5e3f548, 0x3ff0c91ae558a560,
		0x3ff0bfc986e5e5c4, 0x3ff077f4da03f62d, 0x3ff0f5472ac27524,
		0x3ff04dc924b13a42, 0x3ff055ada4ddd544,
		// log1p's k != 0 sites
		0x3ff0f94003bbc540, 0x3ff107201dd26c9c, 0x3ff976c0a5527b97,
		0x3ff82f175deb4d80, 0x3ff6fe1f586c5e58,
		0x3ff8984e11f6fb48, 0x3ff9e5f3c5baf81c, 0x3ff1b3625a848e0c,
		0x3ff81764161d2154, 0x3ffae6c42ac37054,
		0x3ff63fd8e8568884, 0x3ff7f55775f35150, 0x3ff1732e3992e464,
		0x3ff63b62b6c7bf00, 0x3ff7db9895ce06a4,
	)
}

// atanhWitnesses are entirely log1p's sites: atanh itself fuses nothing. Every
// value is in the domain, |x| <= 1.
func atanhWitnesses() []float64 {
	return fromBits(
		// log1p's Lp2 and Lp1 terms
		0x3fde18162257d36a,
		0x3fc37e86b813e288, 0x3fc7b6b186941cf0, 0xbfcb0e7a67c299b0,
		0x3fc26efac339f578, 0xbfc0a9f82be12cfc,
		// hfsq+R (k == 0) and hfsq - s*(hfsq+R)
		0xbfc4b0bb8bfdff24, 0xbfa86068a2f1f2e0, 0xbfba9a4420b178c8,
		0x3fc411aa95f677f0, 0x3fc41bccfa205db8,
		0xbfc54fe79ee50a0c, 0x3fc17a07a6c89628, 0xbfc1f37c77231220,
		0xbfc16d5ab44aa692,
		// the k != 0 sites
		0xbfeffff9e550a5e8, 0xbfdb03241fce1562, 0x3fc98381a1965ff0,
		0x3fcc6d9d90efca22, 0x3fcacfdc2e57a078,
		0x3fc7c6f2183fdec0, 0xbfc782340e829f98, 0x3fdd7f21e23853dc,
		0x3fd89eaaddf32f80, 0xbfe60a7c0c827dea,
		0x3feae80ce1ad38b0, 0x3fee7a91b28e682d, 0x3feac5e46f342ff0,
		0x3fe60280228748f8, 0xbfc9ab4c7458d178,
	)
}

// -------------------------------------------------------------- gocompat/sinh

func genGoSinh(e *emitter) {
	extra := sinhWitnesses()
	// Sinh's own boundaries, densely: 0.5 picks the rational over (ex-1/ex)/2, and
	// 21 picks Exp(x)/2 over that. Both are exactly representable, so landing on
	// them is reachable from a PromQL literal.
	extra = append(extra, 0.5, 21, 0.25, 0.75, 20.5, 21.5, 22)
	// Where Exp overflows, and so where Sinh does.
	extra = append(extra, 709, 710, 711, 745, -745, 1e300)
	emitUnary(e, "sinh", hyperbolicCorpus(20260816, 4200, extra), math.Sinh)
}

// -------------------------------------------------------------- gocompat/cosh

func genGoCosh(e *emitter) {
	// Cosh fuses nothing and has one branch. It is here because it inherits
	// GoMath.exp wholesale — 13.6% of inputs differ from libm's cosh — and because
	// `Abs(x)` clearing a NaN's sign bit is a contract worth pinning.
	extra := []float64{0.5, 21, 20.5, 21.5, 22, 709, 710, 711, -709, -710, 1e300}
	emitUnary(e, "cosh", hyperbolicCorpus(20260817, 4200, extra), math.Cosh)
}

// -------------------------------------------------------------- gocompat/tanh

func genGoTanh(e *emitter) {
	extra := tanhWitnesses()
	// 0.625 splits the rational from 1-2/(exp(2z)+1); 0.5*MAXLOG is where the
	// answer becomes exactly ±1 without any arithmetic at all.
	extra = append(extra, 0.625, 0.6, 0.65, 44.014845965556525, 44, 45, 88, 89)
	extra = append(extra, math.Nextafter(44.014845965556525, math.Inf(1)),
		math.Nextafter(44.014845965556525, math.Inf(-1)))
	emitUnary(e, "tanh", hyperbolicCorpus(20260818, 4200, extra), math.Tanh)
}

// ------------------------------------------------------------- gocompat/asinh

func genGoAsinh(e *emitter) {
	extra := asinhWitnesses()
	// asinh's three interior boundaries: 2**-28, 2, 2**28.
	extra = append(extra, 2, 2.5, 1.9, 268435456, 268435457, 268435455,
		3.7252902984619141e-09, 1e-9, 1e-8)
	emitUnary(e, "asinh", hyperbolicCorpus(20260819, 4200, extra), math.Asinh)
}

// ------------------------------------------------------------- gocompat/acosh
//
// acosh's domain is [1, +Inf), so it gets a corpus of its own: feeding it the
// shared one would spend most of the fixture on the single `x < 1` branch.

func acoshCorpus(seed int64) []float64 {
	out := acoshWitnesses()
	out = append(out, []float64{
		// The domain edge, and out of domain — which is Go's NaN(), payload
		// included, and is 98% of where libm's acosh disagrees.
		1, math.Nextafter(1, math.Inf(1)), math.Nextafter(1, math.Inf(-1)),
		0, math.Copysign(0, -1), 0.5, -1, -2, -math.MaxFloat64, math.Inf(-1),
		math.NaN(), math.Float64frombits(0x7FF8000000000000),
		// The log1p/log split at 2, and the Large cutoff at 2**28.
		2, math.Nextafter(2, math.Inf(1)), math.Nextafter(2, math.Inf(-1)),
		268435456, 268435455, 268435457,
		math.Inf(1), math.MaxFloat64,
	}...)
	// Dense just above 1, where `Sqrt(2*t+t*t)` with t = x-1 cancels hardest.
	r := rand.New(rand.NewSource(seed))
	for i := 0; i < 2600; i++ {
		out = append(out, 1+math.Pow(2, -float64(r.Intn(53)))*r.Float64())
		out = append(out, 1+r.Float64())    // the log1p branch
		out = append(out, 2+r.Float64()*40) // the log branch
		out = append(out, r.Float64()*math.Pow(2, float64(r.Intn(80))))
	}
	// Every power of two in the domain, plus 1.5x.
	for exp := 0; exp <= 60; exp++ {
		v := math.Ldexp(1, exp)
		out = append(out, v, v*1.5)
	}
	return out
}

func genGoAcosh(e *emitter) {
	emitUnary(e, "acosh", acoshCorpus(20260820), math.Acosh)
}

// ------------------------------------------------------------- gocompat/atanh
//
// atanh's domain is [-1, 1], so it too gets its own corpus.

func atanhCorpus(seed int64) []float64 {
	out := atanhWitnesses()
	out = append(out, []float64{
		0, math.Copysign(0, -1),
		// ±1 are ±Inf; one ULP outside is Go's NaN().
		1, -1,
		math.Nextafter(1, math.Inf(-1)), math.Nextafter(-1, math.Inf(1)),
		math.Nextafter(1, math.Inf(1)), math.Nextafter(-1, math.Inf(-1)),
		1.5, -1.5, 2, -2, math.MaxFloat64, -math.MaxFloat64,
		math.Inf(1), math.Inf(-1), math.NaN(),
		math.Float64frombits(0x7FF8000000000000),
		// atanh's own interior boundaries: NearZero = 2**-28 and 0.5, which picks
		// between its two log1p forms.
		0.5, -0.5, math.Nextafter(0.5, math.Inf(1)), math.Nextafter(0.5, math.Inf(-1)),
		3.7252902984619141e-09, -3.7252902984619141e-09,
		math.Nextafter(3.7252902984619141e-09, math.Inf(1)),
		math.Nextafter(3.7252902984619141e-09, math.Inf(-1)),
		math.SmallestNonzeroFloat64, -math.SmallestNonzeroFloat64,
	}...)
	r := rand.New(rand.NewSource(seed))
	for i := 0; i < 2600; i++ {
		out = append(out, r.Float64()*2-1)
		// Concentrated near ±1, where 1-x cancels and the result grows without
		// bound.
		out = append(out, math.Copysign(
			1-math.Pow(2, -float64(r.Intn(53)))*r.Float64(),
			float64(1-2*r.Intn(2))))
	}
	// Every power of two in the domain, both signs.
	for exp := -60; exp <= 0; exp++ {
		v := math.Ldexp(1, exp)
		out = append(out, v, -v)
	}
	return out
}

func genGoAtanh(e *emitter) {
	emitUnary(e, "atanh", atanhCorpus(20260821), math.Atanh)
}

// ------------------------------------------------------------- gocompat/log1p
//
// log1p has no PromQL wrapper; it is pinned because asinh, acosh and atanh are
// all built on it, and because its reduction is the most branch-dense routine in
// this file. Its own corpus, because the interesting inputs are the ones near -1
// and near 0 rather than the ones the shared corpus supplies.

func log1pCorpus(seed int64) []float64 {
	out := log1pWitnesses()
	out = append(out, []float64{
		0, math.Copysign(0, -1),
		// -1 is -Inf; below -1 is Go's NaN(), which is also what a NaN argument
		// comes back as — `x < -1 || IsNaN(x)` share one return.
		-1, math.Nextafter(-1, math.Inf(1)), math.Nextafter(-1, math.Inf(-1)),
		-1.5, -2, -math.MaxFloat64, math.Inf(-1),
		math.NaN(), math.Float64frombits(0x7FF8000000000000),
		math.Inf(1), math.MaxFloat64,
		// The four constants that pick the branch. Sqrt2M1 and Sqrt2HalfM1 are the
		// values Go compiles from the decimal literals, NOT the hex in upstream's
		// own comments, which are two and one ULP off respectively.
		0.41421356237309503, -0.29289321881345248,
		math.Nextafter(0.41421356237309503, math.Inf(1)),
		math.Nextafter(0.41421356237309503, math.Inf(-1)),
		math.Nextafter(-0.29289321881345248, math.Inf(1)),
		math.Nextafter(-0.29289321881345248, math.Inf(-1)),
		1.862645149230957e-09, -1.862645149230957e-09, // Small, 2**-29
		5.5511151231257827e-17, -5.5511151231257827e-17, // Tiny, 2**-54
		9007199254740992, 9007199254740993, 9007199254740991, // Two53
		math.SmallestNonzeroFloat64, -math.SmallestNonzeroFloat64,
		math.Float64frombits(0x000FFFFFFFFFFFFF),
		math.Float64frombits(0x0010000000000000),
	}...)

	// f == 0 with k != 0: x = 2**k - 1 exactly, which is log1p.go:187's branch and
	// the only path that reads `c` without the polynomial.
	for k := -60; k <= 60; k++ {
		v := math.Ldexp(1, k) - 1
		out = append(out, v, math.Nextafter(v, math.Inf(1)), math.Nextafter(v, math.Inf(-1)))
	}

	// `u` carrying the mantissa of Sqrt(2) EXACTLY, and one ULP either side.
	// log1p.go:171's `iu < 0x0006a09e667f3bcd` is the only reader of that
	// constant, and relaxing it to `<=` is invisible unless some input lands
	// precisely on it — a negative control found the first corpus green with the
	// comparison flipped. The `absx >= Two53` path makes this exact and needs no
	// searching: there `u = x`, so ldexp(Sqrt2, k) for k >= 53 has the wanted
	// mantissa by construction.
	sqrt2 := 1.4142135623730951 // math.Sqrt2, i.e. mantissa 0x6a09e667f3bcd
	for _, m := range []float64{
		sqrt2,
		math.Nextafter(sqrt2, math.Inf(1)),
		math.Nextafter(sqrt2, math.Inf(-1)),
	} {
		for k := 53; k <= 1000; k += 7 {
			out = append(out, math.Ldexp(m, k))
		}
		// And the `absx < Two53` reduction path, where `u = 1.0 + x` may not round
		// back to the value asked for. Filtered rather than reasoned about: keep
		// only the candidates that really do land on the target mantissa.
		for k := -40; k <= 52; k++ {
			x := math.Ldexp(m, k) - 1
			for _, cand := range []float64{
				x, math.Nextafter(x, math.Inf(1)), math.Nextafter(x, math.Inf(-1)),
			} {
				if math.Float64bits(1.0+cand)&0x000fffffffffffff ==
					math.Float64bits(m)&0x000fffffffffffff {
					out = append(out, cand)
				}
			}
		}
	}

	r := rand.New(rand.NewSource(seed))
	for i := 0; i < 2000; i++ {
		switch i % 5 {
		case 0:
			out = append(out, r.Float64()*2-1)
		case 1:
			// The k != 0 reduction with a live correction term.
			out = append(out, math.Ldexp(r.Float64()*2-1, r.Intn(60)-30))
		case 2:
			// |f| < 2**-20, log1p.go:190's division-free R. Needs 1+x within
			// 2**-20 of a power of two, which is not the same as x being near one.
			k := r.Intn(60) - 30
			out = append(out, math.Ldexp(1, k)-1+math.Ldexp(r.Float64()*2-1, k-20))
		case 3:
			out = append(out, math.Float64frombits(r.Uint64()))
		case 4:
			// Just inside Small, where the k != 0 reduction begins.
			out = append(out, math.Copysign(
				math.Ldexp(1, -29)*(1+r.Float64()*1e6), float64(1-2*r.Intn(2))))
		}
	}
	// Every power of two, both signs, and 1.5x.
	for exp := -60; exp <= 60; exp++ {
		v := math.Ldexp(1, exp)
		out = append(out, v, -v, v*1.5, -v*1.5)
	}
	return out
}

func genGoLog1p(e *emitter) {
	emitUnary(e, "log1p", log1pCorpus(20260822), math.Log1p)
}
