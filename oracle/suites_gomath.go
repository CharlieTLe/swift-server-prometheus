package main

// Differential coverage for the math routines `promql` reaches that Swift's
// standard library and libm do **not** reproduce.
//
// Five suites, one per surface, because each has its own in/out shape (one
// fixture file holds one shape — see docs/HANDOFF.md §4):
//
//	gocompat/exp                math.Exp — arm64 assembly, fused, sibling of Exp2
//	gocompat/pow                math.Pow — Go's own algorithm, not libm's
//	gocompat/mod                math.Mod — Go's Ldexp subtraction loop, not fmod
//	gocompat/minmax             math.Min and math.Max — arm64 FMIN/FMAX assembly
//	gocompat/ldexp              math.Ldexp — Pow's and Mod's reassembly step
//	gocompat/duration-seconds   time.Duration.Seconds()
//
// Why each of these needs pinning rather than delegating:
//
//   - Exp is assembly on arm64 (haveArchExp, math/exp_asm.go) and evaluates its
//     polynomial with FMADDD, so it rounds once per term where libm rounds twice.
//     Exactly the Exp2 story, docs/PORTING.md quirk 0.
//   - Min/Max are assembly too (haveArchMax/haveArchMin, math/dim_asm.go), and the
//     assembly's raw-bits ±Inf short-circuit runs BEFORE NaN handling. So
//     math.Max(+Inf, NaN) is +Inf on arm64 and NaN in the portable Go. FMAXD is
//     ARM's FMAX, which propagates NaN — not FMAXNM, and not libm's fmax, both of
//     which return the non-NaN operand. The corpus pins the NaN payload and the
//     operand order that selects it.
//   - Pow is pure Go everywhere but s390x and shares nothing with libm's pow but
//     the special-case table.
//   - Duration.Seconds() splits into whole seconds plus a nanosecond remainder.
//     That is not float64(d)/1e9: the two disagree on ~25% of random int64 inputs.
//
// Floats travel as 16-hex-digit bit patterns throughout: encoding/json refuses
// NaN outright, a decimal round trip is not bit-exact, and NaN *payloads* are the
// contract for the Min/Max suite.

import (
	"fmt"
	"math"
	"math/rand"
	"time"
)

// ------------------------------------------------------------- gocompat/log

// genGoLog pins math.Log over its **whole domain**.
//
// The gocompat/log2 suite already exercises Log, but only through Log2, which
// calls it on a Frexp fraction in [0.5, 1). That confines the argument reduction
// to k ∈ {0, -1} and keeps the polynomial terms small, which is why 2,350 log2
// cases passed against an *unfused* transcription of Go's log while
// Log(5.2063069815873524) was one ULP out. Pow computes Exp(yf * Log(x)) on the
// raw x, so the gap was reachable — a pow case found it.
func genGoLog(e *emitter) {
	seen := map[float64]bool{}
	emit := func(v float64) {
		if seen[v] {
			return
		}
		seen[v] = true
		e.emit(fmt.Sprintf("lg/%d", len(seen)-1), fbits(v), fbits(math.Log(v)))
	}

	// The case pow found, and its neighbours.
	for _, v := range []float64{math.Float64frombits(0x4014d342232b6aa7)} {
		emit(v)
		emit(math.Nextafter(v, math.Inf(1)))
		emit(math.Nextafter(v, math.Inf(-1)))
	}

	// Harvested fusion witnesses. Go's arm64 output for math.log fuses seven
	// expressions, and most of them are unobservable: the two polynomial chains
	// and `hfsq + R` do not change a single result in 30,000,000 random inputs,
	// and `k*Ln2Hi` is *provably* exact (Ln2Hi has only 32 significant bits and
	// |k| <= 1075), which is the reason for the hi/lo split in the first place.
	//
	// Two are observable but rare — `R = s2*t1Poly + t2` at about 3 per million
	// and `inner = s*(hfsq+R) + k*Ln2Lo` at about 12 per million — so a corpus
	// this size would miss them by chance. These are witnesses found by a
	// 30,000,000-case search comparing each expression fused against unfused, and
	// they are committed so that unfusing either one fails loudly. Without them
	// the "it is fused" claim in GoMath.log would be untested for those two.
	for _, bits := range []uint64{
		// R = s2*t1Poly + t2
		0x46480fce9f8d5beb, 0x3f8496a4dabfdc6c, 0x3ff4761fd6cd09f1,
		0x40063b306cb9a559, 0x404701fde16885e3, 0x1f670970d00a674a,
		0x3d19934d2ccdb218, 0x3fe5d2e7c83c6d40, 0x3fa5a94c048764a3,
		0x3fc58428761e6d28, 0x404402f6a2e82652, 0x3fd9086d636bbe7c,
		// inner = s*(hfsq+R) + k*Ln2Lo
		0x22e69d83a39d9448, 0x47d4a91e2bfa972e, 0x2fa422025e519954,
		0x4076696fdbd24a12, 0x4b29f0e974decf67, 0x3b24e7ed6a8cbf6e,
		0x2202f0a4f860048e, 0x3fe64c0c29c7c9de, 0x4be4d970984b8103,
		0x3f66770f2e24e496, 0x400419bb8bd7e9a7, 0x3f9b5f67c128df17,
	} {
		emit(math.Float64frombits(bits))
	}

	// Across the whole exponent range, so every k is exercised — the part log2
	// structurally cannot reach.
	r := rand.New(rand.NewSource(20260809))
	for exp := -1074; exp <= 1023; exp++ {
		v := math.Ldexp(1, exp)
		emit(v)
		emit(math.Nextafter(v, math.Inf(1)))
		emit(math.Nextafter(v, math.Inf(-1)))
		// Two random mantissas per binade.
		emit(math.Ldexp(1+r.Float64(), exp))
		emit(math.Ldexp(1+r.Float64(), exp))
	}

	// The sqrt(2)/2 reduction boundary, where f1 *= 2 and ki-- fire.
	sqrt2Half := math.Sqrt2 / 2
	for exp := -40; exp <= 40; exp++ {
		v := math.Ldexp(sqrt2Half, exp)
		emit(v)
		emit(math.Nextafter(v, math.Inf(1)))
		emit(math.Nextafter(v, math.Inf(-1)))
	}

	// Near 1, where f is tiny and the reassembly cancels hardest.
	emit(1)
	for i := 1; i <= 300; i++ {
		emit(1 + float64(i)*0x1p-52)
		emit(1 - float64(i)*0x1p-53)
	}

	// Small integers and the ordinary range.
	for i := 1; i <= 1000; i++ {
		emit(float64(i))
		emit(1 / float64(i))
	}

	// Special cases, including the negative branch — which returns math.NaN()
	// (payload 1), not the hardware default NaN (payload 0). log2's corpus takes
	// Abs of everything, so it never reaches this.
	for _, v := range []float64{
		0, math.Copysign(0, -1), -1, -1e300, -math.SmallestNonzeroFloat64,
		math.NaN(), math.Inf(1), math.Inf(-1),
		math.MaxFloat64, math.SmallestNonzeroFloat64,
	} {
		emit(v)
	}
}

// ------------------------------------------------------------- gocompat/exp

func genGoExp(e *emitter) {
	seen := map[float64]bool{}
	emit := func(v float64) {
		if seen[v] {
			return
		}
		seen[v] = true
		e.emit(fmt.Sprintf("e/%d", len(seen)-1), fbits(v), fbits(math.Exp(v)))
	}

	// The thresholds from exp_arm64.s, and their immediate neighbours: Overflow
	// (returns +Inf), Underflow (returns 0), and NearZero = 2**-28 (returns 1+x).
	overflow := 7.09782712893383973096e+02
	underflow := -7.45133219101941108420e+02
	nearZero := math.Float64frombits(0x3e30000000000000)
	for _, v := range []float64{overflow, underflow, nearZero, -nearZero} {
		emit(v)
		emit(math.Nextafter(v, math.Inf(1)))
		emit(math.Nextafter(v, math.Inf(-1)))
	}

	// The argument-reduction boundary: k = trunc(Log2e*x ± 0.5), so the flip
	// happens where Log2e*x lands on a half-integer.
	log2e := 1.44269504088896338700e+00
	for i := -1074; i <= 1024; i += 7 {
		k := float64(i) + 0.5
		v := k / log2e
		emit(v)
		emit(math.Nextafter(v, math.Inf(1)))
		emit(math.Nextafter(v, math.Inf(-1)))
	}

	// Integers and half-integers across the useful range.
	for i := -746; i <= 710; i++ {
		emit(float64(i))
		emit(float64(i) + 0.5)
	}

	// The subnormal results, where the inlined Ldexp needs its 2**-52 scaling.
	for i := 0; i < 200; i++ {
		emit(-708.0 - float64(i)*0.2)
	}

	// What Pow actually feeds Exp: yf*Log(x) for |yf| <= 0.5.
	r := rand.New(rand.NewSource(20260809))
	for i := 0; i < 400; i++ {
		x := math.Ldexp(1+r.Float64(), r.Intn(200)-100)
		yf := r.Float64() - 0.5
		emit(yf * math.Log(x))
	}

	// Zeros, NaN, the infinities.
	for _, v := range []float64{
		0, math.Copysign(0, -1), math.NaN(), math.Inf(1), math.Inf(-1),
		math.SmallestNonzeroFloat64, -math.SmallestNonzeroFloat64,
	} {
		emit(v)
	}

	// A deterministic sweep.
	for i := 0; i < 1200; i++ {
		emit(float64(i)/1200.0*1460.0 - 750.0)
	}
}

// ------------------------------------------------------------- gocompat/pow

type twoFloatIn struct {
	X string `json:"x"`
	Y string `json:"y"`
}

func genGoPow(e *emitter) {
	seen := map[[2]float64]bool{}
	emit := func(x, y float64) {
		k := [2]float64{x, y}
		if seen[k] {
			return
		}
		seen[k] = true
		e.emit(fmt.Sprintf("p/%d", len(seen)-1),
			twoFloatIn{X: fbits(x), Y: fbits(y)}, fbits(math.Pow(x, y)))
	}

	nan := math.NaN()
	inf := math.Inf(1)
	ninf := math.Inf(-1)
	// math.Copysign, not -1*0.0: an untyped constant product has no sign, so
	// `-1 * 0.0` is +0 in Go. HANDOFF §3.
	nzero := math.Copysign(0, -1)

	// Every entry of Pow's own special-case list, in the order the doc comment
	// gives them, with both signs of zero and both odd and even integer
	// exponents where that matters.
	specials := []float64{
		0, nzero, 1, -1, 2, -2, 3, -3, 0.5, -0.5, 1.5, -1.5,
		2.5, -2.5, inf, ninf, nan, math.MaxFloat64, -math.MaxFloat64,
		math.SmallestNonzeroFloat64, -math.SmallestNonzeroFloat64,
		// 2**53 is where isOddInt's guard trips; 2**63 is where the large-yi
		// branch takes over.
		9007199254740992, 9007199254740991, -9007199254740992,
		9223372036854775808, -9223372036854775808, 4611686018427387904,
		1e308, 1e-308, 1e16, 1e17,
	}
	for _, x := range specials {
		for _, y := range specials {
			emit(x, y)
		}
	}

	// Negative bases with integer and non-integer exponents — the `yf != 0 &&
	// x < 0` NaN branch, and its odd/even sign selection just above it.
	for _, x := range []float64{-1.5, -2, -3, -0.5, -8, -1e100} {
		for i := -20; i <= 20; i++ {
			emit(x, float64(i))
			emit(x, float64(i)+0.5)
			emit(x, float64(i)+0.25)
		}
	}

	// The xe overflow guard inside the squaring loop: |x| far from 1 with a large
	// integer exponent drives Frexp's exponent past ±2**12 before the loop ends.
	for _, x := range []float64{1e-300, 1e300, 2, 0.5, 1.0000001, 0.9999999} {
		for _, y := range []float64{
			1e3, 1e6, 1e12, 1e15, 1e18, -1e3, -1e6, -1e12, -1e18,
			4503599627370496, 9007199254740992,
		} {
			emit(x, y)
		}
	}

	// Results that land exactly on the overflow, underflow and subnormal
	// boundaries of the final Ldexp.
	for _, y := range []float64{
		1023, 1024, 1025, -1022, -1023, -1074, -1075, -1076,
		1023.5, -1074.5,
	} {
		emit(2, y)
		emit(-2, y)
		emit(0.5, y)
	}

	// The y == ±0.5 Sqrt shortcuts, which skip the loop entirely.
	for i := 0; i < 60; i++ {
		v := math.Ldexp(1+float64(i)/60.0, i-30)
		emit(v, 0.5)
		emit(v, -0.5)
	}

	// Realistic PromQL: small integer and fractional exponents over ordinary
	// magnitudes, which is what `^` and duration expressions produce.
	r := rand.New(rand.NewSource(20260809))
	for i := 0; i < 3000; i++ {
		x := math.Ldexp(1+r.Float64(), r.Intn(120)-60)
		if r.Intn(4) == 0 {
			x = -x
		}
		var y float64
		switch r.Intn(4) {
		case 0:
			y = float64(r.Intn(41) - 20)
		case 1:
			y = float64(r.Intn(41)-20) + 0.5
		case 2:
			y = r.Float64()*20 - 10
		default:
			y = math.Ldexp(1+r.Float64(), r.Intn(20)-10)
		}
		emit(x, y)
	}
}

// ------------------------------------------------------------- gocompat/mod

func genGoMod(e *emitter) {
	seen := map[[2]float64]bool{}
	emit := func(x, y float64) {
		k := [2]float64{x, y}
		if seen[k] {
			return
		}
		seen[k] = true
		e.emit(fmt.Sprintf("m/%d", len(seen)-1),
			twoFloatIn{X: fbits(x), Y: fbits(y)}, fbits(math.Mod(x, y)))
	}

	nan := math.NaN()
	inf := math.Inf(1)
	ninf := math.Inf(-1)
	nzero := math.Copysign(0, -1)

	// The special cases: Mod(±Inf, y) and Mod(x, 0) are NaN, Mod(x, ±Inf) is x.
	specials := []float64{
		0, nzero, 1, -1, 2, -2, 0.5, -0.5, 3, -3, inf, ninf, nan,
		math.MaxFloat64, -math.MaxFloat64,
		math.SmallestNonzeroFloat64, -math.SmallestNonzeroFloat64,
	}
	for _, x := range specials {
		for _, y := range specials {
			emit(x, y)
		}
	}

	// Sign handling: the result takes x's sign, and y is used as |y|.
	for _, x := range []float64{7, -7, 7.5, -7.5} {
		for _, y := range []float64{3, -3, 2.5, -2.5, 0.1, -0.1} {
			emit(x, y)
		}
	}

	// The loop's length is the binade distance between x and y, so a large ratio
	// is the interesting shape — and where a naive fmod substitution would still
	// agree but a wrong Ldexp would not.
	for _, ex := range []int{0, 10, 40, 100, 500, 1000} {
		for _, ey := range []int{0, -10, -40, -100, -500, -1000} {
			emit(math.Ldexp(1.7182818, ex), math.Ldexp(1.4142136, ey))
		}
	}

	// Subnormal operands, where Frexp's normalize step matters.
	for i := 1; i <= 8; i++ {
		emit(math.SmallestNonzeroFloat64*float64(i)*1e3, math.SmallestNonzeroFloat64*float64(i))
		emit(1, math.SmallestNonzeroFloat64*float64(i))
	}

	// Exact multiples, where the remainder is an exact zero and its sign is the
	// observable part.
	for _, x := range []float64{6, -6, 1024, -1024} {
		for _, y := range []float64{2, -2, 3, -3, 0.5} {
			emit(x, y)
		}
	}

	r := rand.New(rand.NewSource(20260809))
	for i := 0; i < 3000; i++ {
		x := math.Ldexp(1+r.Float64(), r.Intn(200)-100)
		y := math.Ldexp(1+r.Float64(), r.Intn(200)-100)
		if r.Intn(2) == 0 {
			x = -x
		}
		if r.Intn(2) == 0 {
			y = -y
		}
		emit(x, y)
	}
}

// ---------------------------------------------------------- gocompat/minmax

type minMaxOut struct {
	Min string `json:"min"`
	Max string `json:"max"`
}

func genGoMinMax(e *emitter) {
	n := 0
	emit := func(x, y float64) {
		e.emit(fmt.Sprintf("mm/%d", n),
			twoFloatIn{X: fbits(x), Y: fbits(y)},
			minMaxOut{Min: fbits(math.Min(x, y)), Max: fbits(math.Max(x, y))})
		n++
	}

	// No dedup here: the key would have to be the bit patterns, since distinct
	// NaN payloads are equal under == and never equal under it at the same time.
	// The corpus is generated once from fixed lists, so it is deterministic
	// regardless.
	nan := math.NaN() // 0x7ff8000000000001, Go's uvnan
	qnanHi := math.Float64frombits(0x7ff8000000000abc)
	qnanNeg := math.Float64frombits(0xfff8000000000def)
	// Signalling NaNs: the quiet bit is clear. Prometheus's own stale marker is
	// one of these, which is why the branch is not hypothetical.
	snan := math.Float64frombits(0x7ff0000000000001)
	staleNaN := math.Float64frombits(0x7ff0000000000002)
	snanNeg := math.Float64frombits(0xfff0000000000003)

	values := []float64{
		0, math.Copysign(0, -1), 1, -1, 2, -2, 0.5, -0.5,
		math.Inf(1), math.Inf(-1),
		nan, qnanHi, qnanNeg, snan, staleNaN, snanNeg,
		math.MaxFloat64, -math.MaxFloat64,
		math.SmallestNonzeroFloat64, -math.SmallestNonzeroFloat64,
	}
	for _, x := range values {
		for _, y := range values {
			emit(x, y)
		}
	}

	r := rand.New(rand.NewSource(20260809))
	for i := 0; i < 2000; i++ {
		emit(math.Ldexp(1+r.Float64(), r.Intn(200)-100)*float64(1-2*r.Intn(2)),
			math.Ldexp(1+r.Float64(), r.Intn(200)-100)*float64(1-2*r.Intn(2)))
	}
}

// ----------------------------------------------------------- gocompat/ldexp

type ldexpIn struct {
	Frac string `json:"frac"`
	Exp  int    `json:"exp"`
}

func genGoLdexp(e *emitter) {
	n := 0
	emit := func(frac float64, exp int) {
		e.emit(fmt.Sprintf("l/%d", n),
			ldexpIn{Frac: fbits(frac), Exp: exp}, fbits(math.Ldexp(frac, exp)))
		n++
	}

	fracs := []float64{
		0, math.Copysign(0, -1), 0.5, -0.5, 1, -1, 0.75, -0.75,
		math.Nextafter(1, 2), math.Nextafter(0.5, 0),
		math.Inf(1), math.Inf(-1), math.NaN(),
		math.MaxFloat64, -math.MaxFloat64,
		math.SmallestNonzeroFloat64, -math.SmallestNonzeroFloat64,
		// A subnormal, which sends ldexp through math.normalize first.
		math.Ldexp(1, -1040), -math.Ldexp(1, -1040),
	}
	// The exponents that straddle every branch: the -1075 underflow, the -1022
	// denormal entry, and the 1023 overflow.
	exps := []int{
		0, 1, -1, 52, 53, -52, -53,
		-1021, -1022, -1023, -1074, -1075, -1076, -1077,
		1022, 1023, 1024, 1025,
		2000, -2000, 1 << 20, -(1 << 20),
	}
	for _, f := range fracs {
		for _, x := range exps {
			emit(f, x)
		}
	}

	r := rand.New(rand.NewSource(20260809))
	for i := 0; i < 1500; i++ {
		emit(math.Ldexp(1+r.Float64(), r.Intn(120)-60)*float64(1-2*r.Intn(2)), r.Intn(2400)-1200)
	}
}

// ------------------------------------------------- gocompat/duration-seconds

type durationSecondsIn struct {
	// Decimal, as a string: an int64 outside ±2**53 is not safely a JSON number.
	Nanos string `json:"nanos"`
}

func genGoDurationSeconds(e *emitter) {
	n := 0
	emit := func(nanos int64) {
		e.emit(fmt.Sprintf("ds/%d", n),
			durationSecondsIn{Nanos: fmt.Sprintf("%d", nanos)},
			fbits(time.Duration(nanos).Seconds()))
		n++
	}

	for _, v := range []int64{
		0, 1, -1, 999999999, -999999999, 1000000000, -1000000000,
		math.MaxInt64, math.MinInt64, math.MaxInt64 - 1, math.MinInt64 + 1,
		int64(time.Minute), int64(time.Hour), 90 * int64(time.Minute),
		int64(5 * time.Millisecond), int64(30 * time.Second),
	} {
		emit(v)
	}

	// A quarter of random int64s disagree between the split and float64(d)/1e9,
	// so a plain random sweep is the strongest control this suite can have.
	r := rand.New(rand.NewSource(20260809))
	for i := 0; i < 5000; i++ {
		emit(int64(r.Uint64()))
	}
	// Realistic query ranges and steps, where the two forms agree — so a
	// regression cannot hide behind only-implausible inputs failing.
	for i := 0; i < 2000; i++ {
		emit(int64(r.Intn(1<<31)) * int64(time.Millisecond))
	}
}
