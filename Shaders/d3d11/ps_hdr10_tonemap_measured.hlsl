// Variant of ps_hdr10_tonemap.hlsl that can take the peak and average brightness from the
// per-frame measurement (cs_hdr_hist.hlsl + cs_hdr_resolve.hlsl). Needs shader model 5.0.
#define MEASURED 1
#include "ps_hdr10_tonemap.hlsl"
