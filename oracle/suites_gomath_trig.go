package main

// Differential coverage for the trigonometric, inverse-trigonometric and base-10
// logarithm routines `promql/functions.go` reaches through `simpleFloatFunc`:
// sin, cos, tan, asin, acos, atan and log10.
//
// Seven suites rather than one, following gocompat/{exp,log,pow}: same in/out
// shape, but a per-function fixture means a failure report names the function
// rather than burying it among six others.
//
// Why every one of these needs pinning rather than delegating to libm — measured,
// not assumed. Comparing Swift's libm against Go over 2,000,052 inputs per
// function (structured boundaries plus random values across the whole exponent
// range) gave:
//
//	Abs    0 differ        Sin      466,199 differ (23%)
//	Ceil   0 differ        Cos      573,768 differ (29%)
//	Floor  0 differ        Tan      817,377 differ (41%)
//	Sqrt   0 differ        Asin   1,338,076 differ (67%)
//	                       Acos   1,258,393 differ (63%)
//	                       Atan     296,632 differ (15%)
//	                       Log10  1,294,745 differ (65%)
//
// So `Abs`/`Ceil`/`Floor`/`Sqrt` keep using Swift's — they are hardware
// instructions either side — and the seven below are transcribed from Go's own
// source. `haveArchSin` and its siblings are true only on s390x, so the portable
// Go is what runs on arm64 and amd64.
//
// Part of the divergence is just the NaN payload (Go's math.NaN() is
// 0x7FF8000000000001, Swift's Double.nan is 0x7FF8000000000000), which is why the
// corpora carry NaN and out-of-domain inputs explicitly. Most of it is genuine
// one-ULP disagreement on ordinary finite arguments.
//
// The corpora are seeded-deterministic and every case travels as a 16-hex-digit
// bit pattern: encoding/json refuses NaN, a decimal round trip is not bit-exact,
// and the NaN payload is part of the contract here.

import (
	"fmt"
	"math"
	"math/rand"
)

// trigCorpus builds the shared input set: structured boundaries that matter to
// all seven, plus a deterministic random sample.
//
// `extra` carries the per-function boundaries and harvested fusion witnesses.
func trigCorpus(seed int64, randomCount int, extra []float64) []float64 {
	out := []float64{}
	out = append(out, extra...)

	// Zeros and signs — sin/tan/atan/asin all `return x` for ±0, so the sign of
	// zero is a contract.
	out = append(out, 0, math.Copysign(0, -1))

	// Specials. Sin/Tan/Atan return the argument's own NaN payload; Cos returns
	// Go's. Both are pinned by including several distinct payloads.
	out = append(out,
		math.Inf(1), math.Inf(-1),
		math.NaN(),
		math.Float64frombits(0x7FF8000000000000), // Swift's Double.nan payload
		math.Float64frombits(0x7FF0000000000002), // Prometheus's StaleNaN
		math.Float64frombits(0xFFF8000000000001), // negative quiet NaN
	)

	// The Pi/4 octant boundaries, which decide `j` and therefore which polynomial
	// runs. Each is straddled, because landing exactly on a boundary and landing
	// one ULP either side take different branches.
	for k := 0; k <= 16; k++ {
		v := float64(k) * math.Pi / 4
		out = append(out, v, -v,
			math.Nextafter(v, math.Inf(1)), math.Nextafter(v, math.Inf(-1)),
			-math.Nextafter(v, math.Inf(1)), -math.Nextafter(v, math.Inf(-1)))
	}

	// reduceThreshold = 2**29, the Payne-Hanek switchover. Straddled, and then
	// sampled above it, because trigReduce is a completely different code path
	// that the Pi/4 corpus above never reaches.
	const reduceThreshold = float64(1 << 29)
	out = append(out, reduceThreshold,
		math.Nextafter(reduceThreshold, math.Inf(1)),
		math.Nextafter(reduceThreshold, math.Inf(-1)),
		-reduceThreshold,
		math.Nextafter(-reduceThreshold, math.Inf(1)),
		math.Nextafter(-reduceThreshold, math.Inf(-1)))

	// trigReduce's `bitshift == 0` path: `(exp+61) % 64 == 0` means exp is
	// 3, 67, 131, ... and the three limb shifts become a shift by 64, which is 0
	// in Go and in Swift's `>>` but the identity in Swift's `&>>`. Hit every
	// reachable exponent of that family.
	for exp := 3; exp < 971; exp += 64 {
		v := math.Ldexp(1.5, exp)
		out = append(out, v, -v, math.Ldexp(1.9999999999999998, exp))
	}

	// Powers of two across the whole exponent range, both signs.
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
		switch i % 5 {
		case 0:
			// Dense in the first few periods, where the Pi/4 split runs.
			out = append(out, (r.Float64()*2-1)*4*math.Pi)
		case 1:
			// [-1, 1], the asin/acos domain and atan's xatan range.
			out = append(out, r.Float64()*2-1)
		case 2:
			// Uniform over bit patterns: reaches every exponent, including the
			// huge arguments that only trigReduce handles.
			out = append(out, math.Float64frombits(r.Uint64()))
		case 3:
			// Log-uniform over a wide but finite range.
			out = append(out, (r.Float64()*2-1)*math.Pow(2, float64(r.Intn(120)-60)))
		case 4:
			// Above reduceThreshold specifically.
			out = append(out, (r.Float64()*2-1)*math.Pow(2, float64(r.Intn(40)+29)))
		}
	}
	return out
}

// emitUnary writes one case per DISTINCT input bit pattern. Deduplication is by
// bits rather than by value so that +0 and -0, and NaNs with different payloads,
// are all kept.
func emitUnary(e *emitter, prefix string, xs []float64, f func(float64) float64) {
	seen := map[uint64]bool{}
	n := 0
	for _, x := range xs {
		b := math.Float64bits(x)
		if seen[b] {
			continue
		}
		seen[b] = true
		e.emit(fmt.Sprintf("%s/%d", prefix, n), fbits(x), fbits(f(x)))
		n++
	}
}

// --------------------------------------------------------------- gocompat/sin

func genGoSin(e *emitter) {
	emitUnary(e, "sin", trigCorpus(20260809, 4000, sinCosWitnesses()), math.Sin)
}

// --------------------------------------------------------------- gocompat/cos

func genGoCos(e *emitter) {
	emitUnary(e, "cos", trigCorpus(20260810, 4000, sinCosWitnesses()), math.Cos)
}

// sinCosWitnesses are the harvested fusion witnesses for sin and cos.
//
// Go's arm64 output fuses every add in these two functions: the three
// subtractions of the Pi/4 argument reduction, `1.0 - 0.5*zz`, both six-term
// Cephes polynomials, and both final accumulations. "It is fused" is a claim, and
// a claim needs a failing case to be a tested one — so each fusion was unfused on
// its own and 12,000,000 inputs were searched for a result that changed.
//
// Sorted into three groups, which is worth recording because re-deriving it is
// expensive:
//
//   - **Provably unobservable**: `y*PI4A` and `y*PI4B`. `y` is an integer below
//     2**30 and the two constants carry only 22 and 21 significant bits, so both
//     products fit in 53 bits exactly. That is precisely what splitting Pi/4 into
//     three parts is *for*. `y*PI4C` is full precision and therefore is not exact
//     — the witnesses below are for that one.
//   - **Unobservable in a 12,000,000-input search**: the first three terms of both
//     polynomials (`_sin[0..2]`, `_cos[0..2]`) and `1.0 - 0.5*zz`. The leading
//     terms are diluted below the final rounding, exactly as in
//     `gocompat/log`'s polynomial chains.
//   - **Observable**: `y*PI4C`, the last two terms of each polynomial, and both
//     final accumulations. Witnessed below.
//
// Without these the corpus passes with `y*PI4C` unfused, which is a silent
// one-ULP error on every argument large enough to need the reduction.
func sinCosWitnesses() []float64 {
	out := []float64{}
	for _, b := range []uint64{
		// z = ((x - y*PI4A) - y*PI4B) - y*PI4C — the third subtraction only.
		0x4198f244e3fecbc0, 0x41baa7cb34275260, 0xc1b95cea678daa7a,
		// _sin[3]*zz + _sin[4]
		0xc0a25a9f06a0813e, 0x63ac16c21bb1eff6, 0x3fe2eaaa131e487e, 0xc02774125c46f4f1,
		// _sin[4]*zz + _sin[5]
		0x41876a3e214db330, 0x4020fd08dfb8d5db, 0xc207360f01e395c0, 0x40d1f90d1a3332c4,
		// y = z + (z*zz)*poly
		0x420a7a61862122a2, 0x419c65071a3fa0d8, 0x4194c955ef083790, 0x401e04fb82b13119,
		// _cos[3]*zz + _cos[4]
		0xc024e7049f9fb198, 0xc1dcfc62a5930a92, 0xbfe871d4d10590ec,
		// _cos[4]*zz + _cos[5]
		0x3fead75080ee4f36, 0xc1c3479f58f93ec8, 0x3fedb404efd55d9c, 0x4132bbdbff3a240e,
		// y = (1 - 0.5*zz) + (zz*zz)*poly
		0xbfeba0e5b4b6fce6, 0xc228122bcbef77d0, 0x422911bea4642dcc, 0xc01c26e9c0ad842a,
	} {
		out = append(out, math.Float64frombits(b))
	}
	return out
}

// tanWitnesses are the harvested fusion witnesses for tan's rational.
//
// Six of tan's eight fused sites are observable and are witnessed here. The two
// that are not are both spellings of the denominator's leading term: Go emits
// `fma(z, z, _tanQ[1])` for the source's `zz + _tanQ[1]`, recomputing the square
// **unrounded** even though the rounded `zz` sits in a register — and neither
// using the rounded `zz` nor an unfused `z*z + _tanQ[1]` changes a single result
// in 12,000,000 inputs. The port still spells it the way the disassembly does,
// because being unobservable *by search* is not the same as being equivalent, and
// `xatan`'s identical site IS observable (see atanWitnesses).
func tanWitnesses() []float64 {
	out := []float64{}
	for _, b := range []uint64{
		// _tanP[0]*zz + _tanP[1]
		0xc266fd047cf1c1e0, 0xbfea9f24e720d3ba, 0x4010702725a73dcc, 0x4021678a37424745,
		// ...*zz + _tanP[2]
		0x42f880fde21d6918, 0xc01c32d181fc0b5e, 0x423f2361c6e0eb34, 0xc15d2eb543db95c4,
		// ...*zz + _tanQ[2]
		0xbfeb9e67b903bfda, 0xc14f7b1548bd61c0, 0xc0211875177f00c0, 0xc00e368d71394f08,
		// ...*zz + _tanQ[3]
		0xd678492fca0e1e7f, 0x3fe797f21357531c, 0x418177412c317658,
		// ...*zz + _tanQ[4]
		0xc1d8c4504ae91ea4, 0x549a7950093d84f4, 0x41f26f71674edfde, 0x40df4bb460e1d4b8,
		// y = z + z*(num/den)
		0xbfef9b0e02de75aa, 0x4002396c80fb481e, 0x3ff09e430058de65, 0x3fcb571c8cf731d8,
	} {
		out = append(out, math.Float64frombits(b))
	}
	return out
}

// atanWitnesses are the harvested fusion witnesses for xatan, reached by atan,
// asin and acos alike.
//
// All eleven of xatan's fused sites are observable, which makes it the most
// fusion-sensitive routine in this file. Note the fifth group: the source writes
// the denominator's leading term as `z + Q0` where `z = x*x`, and Go emits
// `fma(x, x, Q0)`, recomputing the square unrounded. That **is** observable here —
// `0xbfe1383384b20da8` distinguishes it both from using the rounded `z` and from
// an unfused `x*x + Q0` — unlike `tan`'s structurally identical site.
func atanWitnesses() []float64 {
	out := []float64{}
	for _, b := range []uint64{
		// P0*z + P1
		0x3fe18caaa754de26,
		// ...*z + P2
		0x3fe12202938c5af6, 0xbfe3c07aabfd75c8, 0x3fe03b880f7da4e2, 0x3fe39c1baa609d86,
		// ...*z + P3
		0x3fe3e5aa927a633e, 0xbfdea2dcb179b624, 0x3fe4cc46fd6510c8,
		// ...*z + P4
		0xbfdcff9cfda4c3a8, 0x3feae03497d049dc, 0xbfdd0bd465090fdc, 0x3feaf12722f75de4,
		// den = fma(x, x, Q0) — the unrounded recomputation.
		0xbfe1383384b20da8,
		// ...*z + Q1
		0x3fe118a0fc99bc16, 0xbfeb5be5d58fae8c, 0xbfe0f49642ed512e, 0x3fe4a8546f3fd820,
		// ...*z + Q2
		0xbfe48ed0c9641912, 0x3fe4ec549cfe19fa, 0xbfe17852712a562e, 0x3fe1634b708d5ffe,
		// ...*z + Q3
		0x3fdb0d67e91cd8a7, 0x3fda39b30708e5ac, 0x3fe49a58459c3344, 0xbfdd69c5a8da8758,
		// ...*z + Q4
		0xbfd726cb082c592c, 0xbfe12dd1934c7a39,
		// z = x*r + x
		0xbfedcf105ff2f44e, 0x3fe11ec0be64c74e, 0xbfeae395c5781dc8,
		// asin's Sqrt(1 - x*x)
		0xbfef9b0e02de75aa, 0xbfe78ae022a6b798, 0xbfefa740eba26fae, 0xbfeff0ad66d0c77e,
	} {
		out = append(out, math.Float64frombits(b))
	}
	return out
}

// --------------------------------------------------------------- gocompat/tan

func genGoTan(e *emitter) {
	// tan's own boundary is `zz > 1e-14`, i.e. |z| > 1e-7, below which the
	// polynomial is skipped entirely and `y = z`. Straddle it, and reach it
	// through arguments that reduce to a tiny z — the multiples of Pi/4 above
	// already do, but explicit tiny arguments make it unmissable.
	extra := tanWitnesses()
	extra = append(extra, 1e-7, -1e-7, 1e-8, -1e-8, 1e-6, -1e-6)
	extra = append(extra, math.Nextafter(1e-7, math.Inf(1)), math.Nextafter(1e-7, math.Inf(-1)))
	// Near the singularities at odd multiples of Pi/2, where `-1/y` runs.
	for k := 1; k <= 15; k += 2 {
		v := float64(k) * math.Pi / 2
		extra = append(extra, v, -v,
			math.Nextafter(v, math.Inf(1)), math.Nextafter(v, math.Inf(-1)))
	}
	emitUnary(e, "tan", trigCorpus(20260811, 4000, extra), math.Tan)
}

// -------------------------------------------------------- gocompat/asin, acos

// asinCorpus is confined to [-1, 1] plus the out-of-domain and special inputs,
// because everything else returns NaN by the same branch and would just pad the
// fixture.
func asinCorpus(seed int64) []float64 {
	// xatan's witnesses reach asin and acos through both of their quotients.
	out := atanWitnesses()
	out = append(out, []float64{
		0, math.Copysign(0, -1), 1, -1,
		math.Nextafter(1, math.Inf(-1)), math.Nextafter(-1, math.Inf(1)),
		// Out of domain: `x > 1` returns Go's NaN(), payload included.
		math.Nextafter(1, math.Inf(1)), math.Nextafter(-1, math.Inf(-1)),
		1.5, -1.5, 2, -2, math.MaxFloat64, -math.MaxFloat64,
		math.Inf(1), math.Inf(-1), math.NaN(),
		math.Float64frombits(0x7FF8000000000000),
		// asin's own branch boundary: `x > 0.7` picks Pi/2 - satan(temp/x) over
		// satan(x/temp).
		0.7, -0.7, math.Nextafter(0.7, math.Inf(1)), math.Nextafter(0.7, math.Inf(-1)),
		// satan's boundaries, reachable through asin's two quotients.
		0.66, -0.66, math.Nextafter(0.66, math.Inf(1)),
		// tan(3*pi/8), satan's upper branch.
		2.41421356237309504880,
		math.SmallestNonzeroFloat64, -math.SmallestNonzeroFloat64,
	}...)
	// Dense in the domain, where the answer is not NaN.
	r := rand.New(rand.NewSource(seed))
	for i := 0; i < 3000; i++ {
		out = append(out, r.Float64()*2-1)
		// Concentrated near ±1, where Sqrt(1 - x*x) loses precision.
		out = append(out, math.Copysign(1-math.Pow(2, -float64(r.Intn(53)))*r.Float64(),
			float64(1-2*r.Intn(2))))
	}
	// Every power of two in the domain.
	for exp := -60; exp <= 0; exp++ {
		v := math.Ldexp(1, exp)
		out = append(out, v, -v)
	}
	return out
}

func genGoAsin(e *emitter) {
	emitUnary(e, "asin", asinCorpus(20260812), math.Asin)
}

func genGoAcos(e *emitter) {
	// Acos is `Pi/2 - Asin(x)`, so the same corpus; kept as its own suite because
	// the subtraction is a rounding of its own and a shared fixture would not say
	// which side moved.
	emitUnary(e, "acos", asinCorpus(20260813), math.Acos)
}

// -------------------------------------------------------------- gocompat/atan

func genGoAtan(e *emitter) {
	out := atanWitnesses()
	out = append(out, []float64{
		0, math.Copysign(0, -1),
		// satan's two branch boundaries.
		0.66, -0.66, math.Nextafter(0.66, math.Inf(1)), math.Nextafter(0.66, math.Inf(-1)),
		2.41421356237309504880, -2.41421356237309504880,
		math.Nextafter(2.41421356237309504880, math.Inf(1)),
		math.Nextafter(2.41421356237309504880, math.Inf(-1)),
		1, -1,
		math.Inf(1), math.Inf(-1), math.NaN(),
		math.Float64frombits(0x7FF8000000000000),
		math.MaxFloat64, -math.MaxFloat64,
		math.SmallestNonzeroFloat64, -math.SmallestNonzeroFloat64,
	}...)
	r := rand.New(rand.NewSource(20260814))
	for i := 0; i < 4000; i++ {
		switch i % 4 {
		case 0:
			out = append(out, r.Float64()*2-1)
		case 1:
			// Straddling both branch boundaries densely.
			out = append(out, r.Float64()*3)
			out = append(out, -r.Float64()*3)
		case 2:
			out = append(out, math.Float64frombits(r.Uint64()))
		case 3:
			out = append(out, (r.Float64()*2-1)*math.Pow(2, float64(r.Intn(120)-60)))
		}
	}
	for exp := -60; exp <= 60; exp++ {
		v := math.Ldexp(1, exp)
		out = append(out, v, -v, v*1.5, -v*1.5)
	}
	emitUnary(e, "atan", out, math.Atan)
}

// ------------------------------------------------------------- gocompat/log10

func genGoLog10(e *emitter) {
	// Log10 is `Log(x) * (1/Ln10)`, and `1/Ln10` is a Go untyped constant folded
	// at arbitrary precision: the naive Swift `1.0 / 2.302585092994046` is one ULP
	// low. So the exact powers of ten are the cases that matter most — that is
	// where a wrong constant shows up as a non-integer result.
	out := []float64{
		0, math.Copysign(0, -1), 1, -1,
		math.Inf(1), math.Inf(-1), math.NaN(),
		math.Float64frombits(0x7FF8000000000000),
		math.SmallestNonzeroFloat64, math.MaxFloat64,
		math.Float64frombits(0x000FFFFFFFFFFFFF),
		math.Float64frombits(0x0010000000000000),
	}
	// Every exactly representable power of ten, and its neighbours.
	for k := -323; k <= 308; k++ {
		v, err := parseFloatExp(k)
		if err != nil {
			continue
		}
		out = append(out, v,
			math.Nextafter(v, math.Inf(1)), math.Nextafter(v, math.Inf(-1)))
	}
	// Powers of two, which are where Log's own argument reduction changes k.
	for exp := -1074; exp <= 1023; exp += 7 {
		out = append(out, math.Ldexp(1, exp))
	}
	r := rand.New(rand.NewSource(20260815))
	for i := 0; i < 3000; i++ {
		switch i % 3 {
		case 0:
			out = append(out, r.Float64()*100)
		case 1:
			out = append(out, math.Abs(math.Float64frombits(r.Uint64())))
		case 2:
			out = append(out, r.Float64()*math.Pow(10, float64(r.Intn(600)-300)))
		}
	}
	// Negatives, which are NaN — and whose payload is Go's, from Log.
	for i := 0; i < 20; i++ {
		out = append(out, -float64(i)-0.5)
	}
	emitUnary(e, "log10", out, math.Log10)
}

// parseFloatExp returns 10**k as the float64 nearest to it, or an error when k is
// outside the representable range. Uses strconv rather than math.Pow so the value
// is the correctly rounded decimal power, which is what a PromQL user writing
// `1e-7` gets.
func parseFloatExp(k int) (float64, error) {
	var v float64
	if _, err := fmt.Sscanf(fmt.Sprintf("1e%d", k), "%g", &v); err != nil {
		return 0, err
	}
	if math.IsInf(v, 0) || v == 0 {
		return 0, fmt.Errorf("1e%d is not finite and non-zero", k)
	}
	return v, nil
}
