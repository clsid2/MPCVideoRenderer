#include "../convert/st2084.hlsl"

Texture2D tex : register(t0);
SamplerState samp : register(s0);

struct PS_INPUT
{
	float4 Pos : SV_POSITION;
	float2 Tex : TEXCOORD;
};

cbuffer HDRParamsConstantBuffer : register(b0)
{
	float MasteringMinLuminanceNits;
	float MasteringMaxLuminanceNits;
	float maxCLL;
	float maxFALL;
	float displayMaxNits;
	uint selection; // 1 = ACES, 2 = Reinhard, 3 = Habel, 4 = Möbius, 5 = BT2390, 6 = ST 2094-10, 7 = Angry
	uint useMeasured; // MEASURED variant only: take the peak and average from the per-frame measurement
	float paddingHDR;
};

// maxCLL and maxFALL as used by the tone mapping. They start as the values from the metadata and
// may be replaced by the per-frame measurement (see main).
static float gMaxCLL;
static float gMaxFALL;
static float gMinNits;

#ifdef MEASURED
// [1] = { raw peak, raw average, fast peak, smoothed average }, [2] = { raw min, min, slow peak PQ, slow peak },
// all in nits. Written by cs_hdr_resolve.hlsl
StructuredBuffer<float4> measured : register(t1);
#endif

cbuffer DolbyConstants : register(b1)
{
	float ChromaWeight;
	float SaturationGain;
	float TrimSlope;
	float TrimOffset;
	float TrimPower;
	uint L2Enabled;
	float L2Padding[2];
};

float3 ACESFilmTonemap(float3 color)
{
	// Constants used in the ACES Filmic tone mapping
	static float A = 2.51f;
	static float B = 0.03f;
	static float C = 2.43f;
	static float D = 0.59f;
	static float E = 0.14f;

	// Apply the ACES RRT + ODT
	color = (color * (A * color + B)) / (color * (C * color + D) + E);

	return color;
}

float3 ReinhardTonemap(float3 color)
{
	return color / (1.0 + color);
}

float3 HabelTonemap(float3 color)
{
	float A = 0.15, B = 0.50, C = 0.10, D = 0.20, E = 0.02, F = 0.30;
	return ((color * (A * color + C * B) + D * E) / (color * (A * color + B) + D * F)) - E / F;
}

float3 MobiusTonemap(float3 color)
{
	static float epsilon = 1e-6;
	float maxL = displayMaxNits;
	return color / (1.0 + color / (maxL + epsilon));
}

float MaxRGB(float3 c)
{
	return max(c.r, max(c.g, c.b));
}

// A color whose brightest channel is over the display peak, although its luminance was mapped
// to Yout, which is not.  The largest channel is brought to the display peak by fading the color
// towards a gray of its own luminance, after giving up part of that luminance: all of it kept
// (kOvershootLuma = 1) turns bright colors pale early, none of it (0) is a plain scaling down.
static const float kOvershootLuma = 0.4f;

float3 FitToDisplay(float3 color, float Yout)
{
	const float D = displayMaxNits;
	const float M = MaxRGB(color);
	if (M <= D || Yout <= 0.0f)
		return color;
	const float Yt = lerp(Yout * D / M, Yout, kOvershootLuma);
	color *= Yt / Yout;
	const float M2 = M * Yt / Yout;
	const float k = (M2 > Yt) ? saturate((D - Yt) / (M2 - Yt)) : 1.0f;
	return Yt + (color - Yt) * k;
}

// The curve of BT.2390 and of ST 2094-10 maps the luminance, and the three channels are scaled by
// what that gives, so a saturated color keeps its brightness.  Where one of its channels would
// then pass the display peak the color fades towards white until it fits.
float3 ApplyCurve(float3 color, float fromLuma, float Y)
{
	if (Y <= 0.000001f)
		return color;
	return FitToDisplay(color * (fromLuma / Y), fromLuma);
}

float BT2390Curve(float nits, float safeMaxCLL)
{
	// Convert peaks and current pixel luminance to PQ space
	float maxCLL_PQ = LinearToST2084(safeMaxCLL, 10000.0f).x;
	float target_PQ = LinearToST2084(displayMaxNits, 10000.0f).x;
	float E1 = min(LinearToST2084(nits, 10000.0f).x, maxCLL_PQ);

	// Calculate BT.2390 Knee Start (KS) point
	float KS = 1.5 * target_PQ - 0.5 * maxCLL_PQ;
	KS = max(0.0, KS); // Knee Start cannot be negative

	float E2 = E1;

	// Apply the Hermite Spline roll-off if the pixel is brighter than the Knee
	if (E1 > KS)
	{
		// max(1e-6, ...) prevents division by zero if maxCLL_PQ happens to equal KS
		float T = (E1 - KS) / max(1e-6, maxCLL_PQ - KS);
		float T2 = T * T;
		float T3 = T2 * T;

		E2 = (2.0 * T3 - 3.0 * T2 + 1.0) * KS +
			 (T3 - 2.0 * T2 + T) * (maxCLL_PQ - KS) +
			 (-2.0 * T3 + 3.0 * T2) * target_PQ;
	}

	// Convert the tone-mapped PQ value back to linear light
	return ST2084ToLinear(E2, 10000.0f).x;
}

float3 BT2390Tonemap(float3 color)
{
	//Safe Metadata Fallbacks (Fixes black screens on bad video files)
	float safeMaxCLL = gMaxCLL;
	if (safeMaxCLL <= 10.0f)
		safeMaxCLL = MasteringMaxLuminanceNits;
	if (safeMaxCLL <= 10.0f)
		safeMaxCLL = 1000.0f; // Ultimate safety fallback
	// Optimization: Skip processing if display is brighter than the content
	if (displayMaxNits >= safeMaxCLL)
		return color;

	// Avoid division by zero on pure black pixels
	const float M = MaxRGB(color);
	if (M <= 0.000001)
		return color;

	const float Y = 0.2627 * color.r + 0.6780 * color.g + 0.0593 * color.b;
	return ApplyCurve(color, BT2390Curve(Y, safeMaxCLL), Y);
}

float pl_smoothstep(float edge0, float edge1, float x)
{
	float t = clamp((x - edge0) / (edge1 - edge0), 0.0f, 1.0f);
	return t * t * (3.0f - 2.0f * t);
}

// --- ST 2094-10 EETF Tone Mapping Function
float3 ST209410Tonemap(float3 color)
{
	if (displayMaxNits >= gMaxCLL || gMaxCLL - gMinNits < 1.0f)
		return color; // nothing to map, or a flat frame

	float src_min = LinearToST2084(gMinNits, 10000.0f).x;
	float src_max = LinearToST2084(gMaxCLL, 10000.0f).x;
	float src_avg = LinearToST2084(gMaxFALL, 10000.0f).x;
	float dst_min = LinearToST2084(0.0f, 10000.0f).x;
	float dst_max = LinearToST2084(displayMaxNits, 10000.0f).x;

	const float min_knee = 0.1f;
	const float max_knee = 0.8f;
	const float def_knee = 0.4f;
	const float knee_adaptation = 0.4f;

	const float src_knee_min = lerp(src_min, src_max, min_knee);
	const float src_knee_max = lerp(src_min, src_max, max_knee);
	const float dst_knee_min = lerp(dst_min, dst_max, min_knee);
	const float dst_knee_max = lerp(dst_min, dst_max, max_knee);

	float src_knee = (gMaxFALL > 0.0f) ? src_avg : lerp(src_min, src_max, def_knee);
	src_knee = clamp(src_knee, src_knee_min, src_knee_max);

	float target = (src_knee - src_min) / (src_max - src_min);
	float adapted = lerp(dst_min, dst_max, target);

	float tuning = 1.0f - pl_smoothstep(max_knee, def_knee, target) * pl_smoothstep(min_knee, def_knee, target);
	float adaptation = lerp(knee_adaptation, 1.0f, tuning);

	float dst_knee = lerp(src_knee, adapted, adaptation);
	dst_knee = clamp(dst_knee, dst_knee_min, dst_knee_max);

	float out_src_knee = ST2084ToLinear(src_knee, 10000.0f).x;
	float out_dst_knee = ST2084ToLinear(dst_knee, 10000.0f).x;

	float x1 = gMinNits;
	float x3 = gMaxCLL;
	float x2 = out_src_knee;

	float y1 = 0.0f;
	float y3 = displayMaxNits;
	float y2 = out_dst_knee;

	// Build the 3x3 cmat array
	float m00 = x2 * x3 * (y2 - y3);
	float m01 = x1 * x3 * (y3 - y1);
	float m02 = x1 * x2 * (y1 - y2);
	float m10 = x3 * y3 - x2 * y2;
	float m11 = x1 * y1 - x3 * y3;
	float m12 = x2 * y2 - x1 * y1;
	float m20 = x3 - x2;
	float m21 = x1 - x3;
	float m22 = x2 - x1;

	float coef0 = m00 * y1 + m01 * y2 + m02 * y3;
	float coef1 = m10 * y1 + m11 * y2 + m12 * y3;
	float coef2 = m20 * y1 + m21 * y2 + m22 * y3;

	float k = 1.0f / (x3 * y3 * (x1 - x2) + x2 * y2 * (x3 - x1) + x1 * y1 * (x2 - x3));

	float c1 = k * coef0;
	float c2 = k * coef1;
	float c3 = k * coef2;

	// The curve is only defined between the three points it was put through
	const float M = MaxRGB(color);
	if (M <= 0.000001f)
		return color;
	const float Y = 0.2627 * color.r + 0.6780 * color.g + 0.0593 * color.b;
	const float xY = clamp(Y, x1, x3);
	const float fromLuma = max((c1 + c2 * xY) / (1.0f + c3 * xY), 0.0f);

	// as for BT.2390: a color that is too bright fades towards white
	return ApplyCurve(color, fromLuma, Y);
}

float3 RGB_to_ICTCP(float3 rgb_nits)
{
	float3 lms;
	lms.x = (1688.0f * rgb_nits.x + 2146.0f * rgb_nits.y + 262.0f * rgb_nits.z) / 4096.0f;
	lms.y = (683.0f * rgb_nits.x + 2951.0f * rgb_nits.y + 462.0f * rgb_nits.z) / 4096.0f;
	lms.z = (99.0f * rgb_nits.x + 309.0f * rgb_nits.y + 3688.0f * rgb_nits.z) / 4096.0f;

	lms.x = LinearToST2084(lms.x, 10000.0f).x;
	lms.y = LinearToST2084(lms.y, 10000.0f).x;
	lms.z = LinearToST2084(lms.z, 10000.0f).x;

	float3 ictcp;
	ictcp.x = (2048.0f * lms.x + 2048.0f * lms.y) / 4096.0f;
	ictcp.y = (6610.0f * lms.x - 13613.0f * lms.y + 7003.0f * lms.z) / 4096.0f;
	ictcp.z = (17933.0f * lms.x - 17390.0f * lms.y - 543.0f * lms.z) / 4096.0f;

	return ictcp;
}

float3 ICTCP_to_RGB(float3 ictcp)
{
	float3 lms;
	lms.x = 1.0f * ictcp.x + 0.00860904f * ictcp.y + 0.11102963f * ictcp.z;
	lms.y = 1.0f * ictcp.x - 0.00860904f * ictcp.y - 0.11102963f * ictcp.z;
	lms.z = 1.0f * ictcp.x + 0.56003134f * ictcp.y - 0.32062717f * ictcp.z;

	lms.x = ST2084ToLinear(lms.x, 10000.0f).x;
	lms.y = ST2084ToLinear(lms.y, 10000.0f).x;
	lms.z = ST2084ToLinear(lms.z, 10000.0f).x;

	float3 rgb_nits;
	rgb_nits.x = 3.43660669f * lms.x - 2.50645212f * lms.y + 0.06984542f * lms.z;
	rgb_nits.y = -0.79132956f * lms.x + 1.98360045f * lms.y - 0.19227090f * lms.z;
	rgb_nits.z = -0.02594990f * lms.x - 0.09891371f * lms.y + 1.12486361f * lms.z;

	return rgb_nits;
}

float3 ApplyL2Trim(float3 linearRGB)
{
	float3 ictcp = RGB_to_ICTCP(linearRGB);
	float originalI = ictcp.x;

	ictcp.x = max(ictcp.x * TrimSlope + TrimOffset, 0.0f);
	ictcp.x = pow(ictcp.x, max(TrimPower, 0.1f));

	float saturationFactor = max(SaturationGain, 0.0f);
	float highlightWeight = saturate(originalI * 2.0f);

	float targetSaturationForHighlights = 1.0;
	float effectiveSaturation = lerp(saturationFactor, targetSaturationForHighlights, highlightWeight * (1.0 - ChromaWeight));

	ictcp.yz *= effectiveSaturation;

	return ICTCP_to_RGB(ictcp);
}

float4 DolbyVisionTrims(float4 color)
{
	color = LinearToST2084(color, 10000.0f);

	color = pow((color * TrimSlope) + TrimOffset, TrimPower);

	color.rgb = max(color.rgb, 0.00001);

	float Y = 0.2627f * color.r + 0.6780f * color.g + 0.0593f * color.b;

	color = color * pow((1.0 + ChromaWeight) * color / Y, SaturationGain);

	color = ST2084ToLinear(color, 10000.0f);

	return color;
}

// ---- Models that take the measured peak ---------------------------------------------------------
// BT.2390 and Angry: identity below a knee, so a moving peak only moves the shoulder.  ACES,
// Reinhard, Hable and Mobius normalize the whole picture by the peak; they keep using the file's
// metadata.

// Angry: the gray curve.  It is the Hermite spline of BT.2390, in PQ, with two
// differences from the way BT.2390 is used above.
//   The knee is 1.5 * PQ(display peak) - 0.5, which is BT.2390's formula with the source range taken
//   as the whole of PQ and not as the content: 23 nits for a 200 nit display, 75 for 400, 182 for
//   700.  It follows the display and not the content, so the picture below the highlights is the
//   same whatever is on screen.
//   The spline is flat at max(content peak, 4000 nits).  For dimmer content its end value is raised
//   until the content peak lands on the display peak, which leaves the curve with some slope there
//   instead of pressing the top of the range flat.
// Against 640 gray patches of the reference renderer (ten combinations of display and content peak)
// this is 0.8% rms, which is the noise of that capture.
struct AngrySpline
{
	float knee;   // PQ
	float width;  // PQ, from the knee to where the spline is flat
	float end;    // PQ value it reaches there
	float top;    // PQ of the display peak
	bool identity;
};

static const float kSplineFlatAtNits = 4000.0f;

AngrySpline MakeAngrySpline()
{
	AngrySpline s;
	s.identity = (displayMaxNits >= gMaxCLL);
	s.top = LinearToST2084(displayMaxNits, 10000.0f).x;
	s.knee = max(1.5f * s.top - 0.5f, 0.0f);
	s.width = LinearToST2084(max(gMaxCLL, kSplineFlatAtNits), 10000.0f).x - s.knee;
	s.end = s.top;
	if (gMaxCLL < kSplineFlatAtNits)
	{
		// the value at the content peak is linear in the end value, so it can be solved for
		const float t = (LinearToST2084(gMaxCLL, 10000.0f).x - s.knee) / s.width;
		const float t2 = t * t;
		const float t3 = t2 * t;
		s.end = (s.top - (2.0f * t3 - 3.0f * t2 + 1.0f) * s.knee - (t3 - 2.0f * t2 + t) * s.width) / (-2.0f * t3 + 3.0f * t2);
	}
	return s;
}

float AngryCurve(AngrySpline s, float nits)
{
	if (s.identity)
		return nits;
	const float e = LinearToST2084(nits, 10000.0f).x;
	if (e <= s.knee)
		return nits;
	const float t = saturate((e - s.knee) / s.width);
	const float t2 = t * t;
	const float t3 = t2 * t;
	const float h = (2.0f * t3 - 3.0f * t2 + 1.0f) * s.knee + (t3 - 2.0f * t2 + t) * s.width + (-2.0f * t3 + 3.0f * t2) * s.end;
	return ST2084ToLinear(min(h, s.top), 10000.0f).x;
}

// Angry: the color model of the reference renderer this model follows, found by
// measuring its output over some 280 color patches.  Three steps, all in BT.2020 linear light.
//
//  1. a hue-preserving color S: every channel is scaled by curve(N) / N, where
//         N = Y^(1-w) * M^w,   w = s^4,   Y luminance, M largest channel, s = 1 - smallest / largest
//     so N is the luminance up to about half saturation and the largest channel for a pure color.
//     A saturated color of little luminance (blue, red) is compressed before it reaches the peak.
//  2. a per-channel color PC: the curve applied to each of L, M and S of the BT.2100 cone space.
//     That one drifts in hue as the eye expects of something very bright: blue towards cyan, red
//     towards orange, and everything towards white.
//  3. the two are mixed, 17% of PC while S fits the display and more of it the further S would
//     overshoot: mu = 0.17 + 0.83 * (1 - rho^-2), rho = largest channel of S / display peak.
//     What is still over the peak is scaled down.  There is no fade towards gray at the peak.
//
// With the reference's color controls off this leaves 2.4 nits rms over 223 patches (200 nit
// display, 1000 nit frame; its capture noise is about 1).  Its default "desaturation control" is
// followed by a fade towards a gray of the color's own luminance,
//     k = 0.415 * (1 - D / content peak) * (mean channel / D) ^ 1.29
// where the middle factor is how much of the range is being compressed at all, so a display as
// bright as the content fades nothing.  Over 55 colors at each of four display peaks, 200 to 1000
// nits, that is 2.4, 1.6, 1.5 and 0.5% of the display peak.  The reference judged the overshoot on
// BT.709 channels, its output there; here it is the BT.2020 channels that have to fit.
static const float kLmsShare = 0.17f;
static const float kFadeGain = 0.415f;
static const float kFadePower = 1.29f;
static const float3x3 kRgbToLms = float3x3(
	0.412109375f, 0.523925781f, 0.063964844f,
	0.166748047f, 0.720458984f, 0.112792969f,
	0.024169922f, 0.075439453f, 0.900390625f);
static const float3x3 kLmsToRgb = float3x3(
	 3.436606694f, -2.506452119f,  0.069845424f,
	-0.791329556f,  1.983600452f, -0.192270896f,
	-0.025949900f, -0.098913715f,  1.124863614f);

float3 AngryTonemap(float3 color)
{
	const float M = MaxRGB(color);
	if (M <= 0.000001f)
		return color;
	const float Y = 0.2627f * color.r + 0.6780f * color.g + 0.0593f * color.b;
	{
		const float D = displayMaxNits;
		const float s = saturate(1.0f - min(color.r, min(color.g, color.b)) / M);
		const float s2 = s * s;
		const float N = Y * pow(max(M / Y, 1.0f), s2 * s2);
		const AngrySpline curve = MakeAngrySpline();
		const float3 S = color * (AngryCurve(curve, N) / N);

		const float3 lms = max(mul(kRgbToLms, color), 0.0f);
		const float3 PC = max(mul(kLmsToRgb, float3(AngryCurve(curve, lms.x), AngryCurve(curve, lms.y), AngryCurve(curve, lms.z))), 0.0f);

		const float rho = max(MaxRGB(S) / D, 1.0f);
		const float mu = kLmsShare + (1.0f - kLmsShare) * (1.0f - 1.0f / (rho * rho));
		color = max(lerp(S, PC, mu), 0.0f);

		{
			const float compress = saturate(1.0f - D / gMaxCLL); // nothing to compress, nothing to fade
			const float Yout = 0.2627f * color.r + 0.6780f * color.g + 0.0593f * color.b;
			const float k = min(kFadeGain * compress * pow(max((color.r + color.g + color.b) / (3.0f * D), 0.0f), kFadePower), 1.0f);
			color = Yout + (color - Yout) * (1.0f - k);
		}

		const float m = MaxRGB(color);
		return (m > D) ? color * (D / m) : color;
	}
}

float4 main(PS_INPUT input) : SV_Target
{
	gMaxCLL = maxCLL;
	gMaxFALL = maxFALL;
	gMinNits = MasteringMinLuminanceNits;
#ifdef MEASURED
	if (useMeasured && (selection == 5 || selection == 7))
	{
		// measured[1].z is 0 until a frame has been measured, and the file's metadata stands in
		// until then.  Never below the display's own peak: nothing needs compressing in that case.
		// The other models are as they were and keep using the metadata: their curve is global,
		// so a moving peak would move the whole picture.
		const float peak = measured[1].z;
		if (peak > 0.0f)
		{
			gMaxCLL = clamp(peak, displayMaxNits, 10000.0f);
		}
	}
#endif

	// Sample texture and convert from PQ to linear
	float4 color = tex.Sample(samp, input.Tex);
	color = saturate(color);
	color = ST2084ToLinear(color, 10000.0f); // Convert PQ to Linear space

	if (L2Enabled)
	{
		color = DolbyVisionTrims(color);
	}

	if (selection == 5)
	{
		color.rgb = BT2390Tonemap(color.rgb); // Apply BT.2390 EETF Tone Mapping
		color = LinearToST2084(color, 10000.0f);
		return float4(color.rgb, color.a);
	}

	if (selection == 6)
	{
		color.rgb = ST209410Tonemap(color.rgb); // Apply ST.2094-10 EETF Tone Mapping
		color = LinearToST2084(color, 10000.0f);
		return float4(color.rgb, color.a);
	}

	if (selection == 7)
	{
		// the peak is the measured one if there is one, MaxCLL from the file otherwise
		if (gMaxCLL <= 10.0f)
			gMaxCLL = (MasteringMaxLuminanceNits > 10.0f) ? MasteringMaxLuminanceNits : 1000.0f;
		gMaxCLL = max(gMaxCLL, displayMaxNits);
		color.rgb = AngryTonemap(color.rgb);
		color = LinearToST2084(color, 10000.0f);
		return float4(color.rgb, color.a);
	}

	float baseLum = max(displayMaxNits, MasteringMaxLuminanceNits);
	float effectiveMaxLum = min(baseLum, gMaxCLL);
	float fallAdjustment = min(baseLum / gMaxFALL, 1.0);

	// Apply global normalization *before tone mapping*
	color.rgb *= (1.0f / effectiveMaxLum);
	color.rgb = saturate(color.rgb);
	color.rgb *= fallAdjustment;

	// Select the tone mapping function based on `selection`
	if (selection == 1)
	{
		color.rgb = ACESFilmTonemap(color.rgb); // Apply ACES Tone Mapping
	}
	else if (selection == 2)
	{
		color.rgb = ReinhardTonemap(color.rgb); // Apply Reinhard Tone Mapping
	}
	else if (selection == 3)
	{
		color.rgb = HabelTonemap(color.rgb); // Apply Habel Tone Mapping
	}
	else if (selection == 4)
	{
		color.rgb = MobiusTonemap(color.rgb); // Apply Möbius Tone Mapping
	}
	else
	{
		color.rgb = ACESFilmTonemap(color.rgb); // Default fallback to ACES
	}

	// Scale to display peak brightness after tone mapping
	color.rgb *= displayMaxNits;

	// Convert back from linear to PQ color space
	color = LinearToST2084(color, 10000.0f); // Convert Linear to PQ

	return float4(color.rgb, color.a); // Final output
}
